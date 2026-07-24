import hashlib
import json
import os
import pathlib
import subprocess
import tempfile
import time
import unittest


ROOT = pathlib.Path(__file__).resolve().parents[1]
GLOBAL_STOP = ROOT / "scripts" / "global-stop.sh"
LANE = ROOT / "scripts" / "dispatch-lane.sh"
CONSUMER = ROOT / "scripts" / "dispatch-consumer.sh"
QA_GATE = ROOT / "scripts" / "qa-gate.sh"


class DispatchSafetyTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.base = pathlib.Path(self.temp.name)
        self.home = self.base / "home"
        self.home.mkdir()
        self.requests = self.base / "requests"
        self.requests.mkdir()
        self.task_runs = self.base / "task-runs"
        self.events = self.base / "events.log"
        self.notifications = self.base / "notifications.log"
        self.marker = self.base / "notifications.marker"
        self.status = self.base / "status.json"
        self.stop = self.base / "state" / "stop"
        self.lane = self.base / "state" / "dispatch-lane.json"
        self.dispatch_lock = self.base / "locks" / "canonical-dispatch.lock"
        self.fake_log = self.base / "tmux.log"
        self.fake_count = self.base / "tmux-send-count"
        self.bin = self.base / "bin"
        self.bin.mkdir()
        fake_tmux = self.bin / "tmux"
        fake_tmux.write_text(
            "#!/usr/bin/env bash\n"
            "set -euo pipefail\n"
            'printf "%s\\n" "$*" >> "$FAKE_TMUX_LOG"\n'
            'case "${1:-}" in\n'
            "  has-session|new-session) exit 0 ;;\n"
            "  capture-pane) printf '%s\\n' \"${FAKE_TMUX_CAPTURE:-❯}\"; exit 0 ;;\n"
            "  send-keys)\n"
            "    count=0\n"
            '    [[ -f "$FAKE_TMUX_COUNT" ]] && count="$(cat "$FAKE_TMUX_COUNT")"\n'
            "    count=$((count + 1))\n"
            '    printf "%s\\n" "$count" > "$FAKE_TMUX_COUNT"\n'
            '    [[ "$count" == "${FAKE_TMUX_FAIL_SEND_AT:-0}" ]] && exit 1\n'
            "    exit 0 ;;\n"
            "esac\n"
            "exit 0\n",
            encoding="utf-8",
        )
        fake_tmux.chmod(0o755)
        self.cost_log = self.base / "cost.csv"
        self.config = self.base / "circuit-breaker.yaml"
        self.write_config(cap=20)
        self.provider_file = self.base / "providers.json"
        self.provider_file.write_text(
            json.dumps({"agents": [{
                "id": "worker",
                "name": "Worker",
                "session": "worker",
                "provider_id": "test",
            }]}),
            encoding="utf-8",
        )
        self.env = {
            **os.environ,
            "HOME": str(self.home),
            "PATH": f"{self.bin}:{os.environ['PATH']}",
            "HERMES_REQUESTS_DIR": str(self.requests),
            "HERMES_TASK_RUN_DIR": str(self.task_runs),
            "HERMES_TICKET_DIR": str(self.base / "tickets"),
            "HERMES_TICKET_LOCK": str(self.base / "locks" / "tickets.lock"),
            "HERMES_LEARNINGS_FILE": str(self.base / "learnings.md"),
            "HERMES_STOP_FILE": str(self.stop),
            "HERMES_DISPATCH_LANE_FILE": str(self.lane),
            "HERMES_DISPATCH_LANE_LOCK": str(self.base / "locks" / "lane.lock"),
            "HERMES_DISPATCH_LOCK": str(self.dispatch_lock),
            "HERMES_CIRCUIT_BREAKER_CONFIG": str(self.config),
            "HERMES_EVENT_LOG": str(self.events),
            "HERMES_NOTIF_LOG": str(self.notifications),
            "HERMES_NOTIF_MARKER": str(self.marker),
            "HERMES_STATUS_FILE": str(self.status),
            "HERMES_PROVIDER_FILE": str(self.provider_file),
            "HERMES_PIPELINE_DIR": str(self.base / "pipelines"),
            "HERMES_PAUSED_AGENTS_DIR": str(self.base / "paused"),
            "HERMES_ALERT_STATE": str(self.base / "alerts"),
            "HERMES_DISPATCH_SUBMIT_DELAY": "0",
            "HERMES_DISPATCH_TRANSPORT_TIMEOUT": "2",
            "HERMES_DISPATCH_TASK_DIR": str(self.base / "dispatch-tasks"),
            "FAKE_TMUX_LOG": str(self.fake_log),
            "FAKE_TMUX_COUNT": str(self.fake_count),
            "FAKE_TMUX_CAPTURE": "❯",
        }

    def tearDown(self):
        self.temp.cleanup()

    def write_config(self, cap):
        self.config.write_text(
            "weekly_usd: " + str(cap) + "\n"
            f'log_file: "{self.cost_log}"\n'
            "max: 3\n"
            f'flag_file: "{self.stop}"\n'
            "warn_at_pct: 50\n"
            "alert_at_pct: 75\n"
            "critical_at_pct: 90\n"
            "cron_failure_threshold: 3\n",
            encoding="utf-8",
        )

    def run_cmd(self, *argv, check=True, env=None):
        return subprocess.run(
            argv,
            cwd=ROOT,
            env=env or self.env,
            text=True,
            capture_output=True,
            timeout=20,
            check=check,
        )

    def write_order(self, request_id, *, qa_required=True, request_type="order"):
        request = {
            "request_id": request_id,
            "correlation_id": f"{request_id}:0",
            "agent": "worker",
            "agent_id": "worker",
            "title": request_id,
            "task": f"perform {request_id}",
            "priority": "normal",
            "type": request_type,
            "qa_required": qa_required,
            "qa_checks": [{"type": "result_present"}],
            "created_at": "2026-07-24T00:00:00Z",
        }
        path = self.requests / f"{request_id}.json"
        path.write_text(json.dumps(request, indent=2) + "\n", encoding="utf-8")
        return path, request

    def send_count(self):
        if not self.fake_count.exists():
            return 0
        return int(self.fake_count.read_text(encoding="utf-8"))

    def test_global_stop_never_expires_and_status_is_valid_json(self):
        result = self.run_cmd(
            "bash", str(GLOBAL_STOP), "set", 'Kevin said "hold"\nnow'
        )
        self.assertIn("STOPPED", result.stdout)
        old = time.time() - 3 * 24 * 3600
        os.utime(self.stop, (old, old))
        status = self.run_cmd("bash", str(GLOBAL_STOP), "status")
        payload = json.loads(status.stdout)
        self.assertEqual(payload["status"], "STOPPED")
        self.assertEqual(payload["reason"], 'Kevin said "hold" now')
        self.assertTrue(self.stop.exists())
        self.assertEqual(
            self.run_cmd("bash", str(GLOBAL_STOP), "check").returncode, 0
        )
        self.run_cmd("bash", str(GLOBAL_STOP), "clear")
        self.assertFalse(self.stop.exists())

    def test_lane_is_exact_non_expiring_and_uses_canonical_lock_override(self):
        request_path, _ = self.write_order("lane-one")
        self.run_cmd("bash", str(LANE), "acquire", "--request-file", str(request_path))
        old = time.time() - 30 * 24 * 3600
        os.utime(self.lane, (old, old))
        status = json.loads(self.run_cmd("bash", str(LANE), "status").stdout)
        self.assertEqual(status["request_id"], "lane-one")
        wrong = self.run_cmd(
            "bash", str(LANE), "release", "--request-id", "lane-two",
            "--reason", "qa_terminal", check=False,
        )
        self.assertNotEqual(wrong.returncode, 0)
        self.assertTrue(self.lane.exists())
        self.run_cmd(
            "bash", str(LANE), "release", "--request-id", "lane-one",
            "--reason", "qa_terminal",
        )
        self.assertFalse(self.lane.exists())
        self.run_cmd("bash", str(CONSUMER))
        self.assertTrue(self.dispatch_lock.exists())

    def test_server_boolean_dispatches_once_and_closes_global_lane(self):
        request_path, _ = self.write_order("boolean-order")
        self.run_cmd("bash", str(CONSUMER))
        self.assertFalse(request_path.exists())
        self.assertEqual(self.send_count(), 3)
        state = json.loads(
            (self.task_runs / "boolean-order" / "state.json").read_text()
        )
        self.assertEqual(state["status"], "dispatched")
        self.assertEqual(json.loads(self.lane.read_text())["status"], "active")

        second, _ = self.write_order("second-order")
        self.run_cmd("bash", str(CONSUMER))
        self.assertTrue(second.exists())
        self.assertEqual(self.send_count(), 3)

    def test_busy_is_backpressure_and_never_deletes(self):
        request_path, _ = self.write_order("busy-order")
        busy_env = {**self.env, "FAKE_TMUX_CAPTURE": "Thinking"}
        for _ in range(6):
            self.run_cmd("bash", str(CONSUMER), env=busy_env)
        self.assertTrue(request_path.exists())
        self.assertEqual(self.send_count(), 0)
        self.assertFalse(self.lane.exists())

    def test_breaker_is_rechecked_immediately_before_send(self):
        request_path, _ = self.write_order("over-cap")
        self.cost_log.write_text(
            "timestamp,correlation_id,model,input_tokens,output_tokens,cache_read,"
            "cache_write,cost_usd,task\n"
            f"{time.strftime('%Y-%m-%dT%H:%M:%SZ', time.gmtime())},cap:0,test,"
            "0,0,0,0,25.00,test\n",
            encoding="utf-8",
        )
        self.run_cmd("bash", str(CONSUMER))
        self.assertTrue(request_path.exists())
        self.assertEqual(self.send_count(), 0)
        self.assertFalse(self.lane.exists())

    def test_transport_failure_is_uncertain_and_never_retried(self):
        request_path, _ = self.write_order("uncertain-order")
        fail_env = {**self.env, "FAKE_TMUX_FAIL_SEND_AT": "2"}
        self.run_cmd("bash", str(CONSUMER), env=fail_env)
        self.assertFalse(request_path.exists())
        self.assertTrue((self.requests / ".uncertain" / request_path.name).exists())
        state = json.loads(
            (self.task_runs / "uncertain-order" / "state.json").read_text()
        )
        self.assertEqual(state["status"], "dispatch_uncertain")
        self.assertEqual(json.loads(self.lane.read_text())["status"], "uncertain")
        count = self.send_count()
        self.run_cmd("bash", str(CONSUMER), env=fail_env)
        self.assertEqual(self.send_count(), count)

    def test_completionless_task_and_malformed_request_are_visible_and_held(self):
        legacy, _ = self.write_order(
            "legacy-task", qa_required=False, request_type="task"
        )
        malformed = self.requests / "broken.json"
        malformed.write_text('{"request_id":', encoding="utf-8")
        self.run_cmd("bash", str(CONSUMER))
        self.assertTrue(legacy.exists())
        self.assertEqual(self.send_count(), 0)
        self.assertEqual(
            len(list((self.requests / ".invalid").glob("broken.json.*"))), 1
        )
        self.assertIn("held", self.notifications.read_text(encoding="utf-8"))

    def test_idle_poll_delivers_notifications_and_refreshes_status(self):
        self.notifications.write_text(
            "2026-07-24T00:00:00Z|info|test|idle notification\n",
            encoding="utf-8",
        )
        self.run_cmd("bash", str(CONSUMER))
        self.assertEqual(self.marker.read_text(encoding="utf-8").strip(), "1")
        self.assertTrue(self.status.exists())

    def test_qa_registration_hash_and_baseline_are_immutable(self):
        repo = self.base / "repo"
        repo.mkdir()
        self.run_cmd("git", "init", "-q", str(repo))
        self.run_cmd("git", "-C", str(repo), "config", "user.name", "Test")
        self.run_cmd("git", "-C", str(repo), "config", "user.email", "test@example.invalid")
        (repo / "README").write_text("one\n", encoding="utf-8")
        self.run_cmd("git", "-C", str(repo), "add", "README")
        self.run_cmd("git", "-C", str(repo), "commit", "-qm", "initial")

        request_path, request = self.write_order("hash-order")
        request["working_directory"] = str(repo)
        request_path.write_text(json.dumps(request, indent=2) + "\n", encoding="utf-8")
        first = json.loads(self.run_cmd(
            "bash", str(QA_GATE), "register", "--request-file", str(request_path)
        ).stdout)
        baseline = first["baseline_head"]
        (repo / "README").write_text("two\n", encoding="utf-8")
        self.run_cmd("git", "-C", str(repo), "add", "README")
        self.run_cmd("git", "-C", str(repo), "commit", "-qm", "second")
        second = json.loads(self.run_cmd(
            "bash", str(QA_GATE), "register", "--request-file", str(request_path)
        ).stdout)
        self.assertEqual(second["baseline_head"], baseline)

        request["title"] = "tampered"
        request_path.write_text(json.dumps(request, indent=2) + "\n", encoding="utf-8")
        rejected = self.run_cmd(
            "bash", str(QA_GATE), "register", "--request-file", str(request_path),
            check=False,
        )
        self.assertNotEqual(rejected.returncode, 0)
        stored_hash = hashlib.sha256(
            (self.task_runs / "hash-order" / "request.json").read_bytes()
        ).hexdigest()
        self.assertEqual(second["request_sha256"], stored_hash)


if __name__ == "__main__":
    unittest.main()
