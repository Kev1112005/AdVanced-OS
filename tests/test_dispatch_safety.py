import hashlib
import json
import os
import pathlib
import shutil
import subprocess
import tempfile
import time
import unittest
import fcntl
import uuid


ROOT = pathlib.Path(__file__).resolve().parents[1]
GLOBAL_STOP = ROOT / "scripts" / "global-stop.sh"
LANE = ROOT / "scripts" / "dispatch-lane.sh"
CONSUMER = ROOT / "scripts" / "dispatch-consumer.sh"
QA_GATE = ROOT / "scripts" / "qa-gate.sh"
CIRCUIT_BREAKER = ROOT / "scripts" / "circuit-breaker.sh"


def contract_hash(value):
    encoded = json.dumps(
        value,
        ensure_ascii=False,
        sort_keys=True,
        separators=(",", ":"),
    ).encode("utf-8")
    return hashlib.sha256(encoded).hexdigest()


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
        self.stop_lock = self.base / "locks" / "global-stop.lock"
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
            "HERMES_STOP_LOCK": str(self.stop_lock),
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

    def test_invalid_stop_nodes_fail_closed(self):
        self.stop.parent.mkdir(parents=True)
        self.stop.mkdir()
        status = json.loads(
            self.run_cmd("bash", str(GLOBAL_STOP), "status").stdout
        )
        self.assertEqual(status["status"], "STOPPED")
        self.assertTrue(status["invalid"])
        blocked = self.run_cmd(
            "bash", str(CIRCUIT_BREAKER), "check",
            "--correlation-id", "invalid-stop:0",
            "--config", str(self.config),
            check=False,
        )
        self.assertEqual(blocked.returncode, 1)
        self.stop.rmdir()

        self.stop.symlink_to(self.base / "does-not-exist")
        self.assertEqual(
            self.run_cmd("bash", str(GLOBAL_STOP), "check").returncode, 0
        )
        blocked = self.run_cmd(
            "bash", str(CIRCUIT_BREAKER), "check",
            "--correlation-id", "dangling-stop:0",
            "--config", str(self.config),
            check=False,
        )
        self.assertEqual(blocked.returncode, 1)
        self.stop.unlink()
        self.assertNotEqual(
            self.run_cmd(
                "bash", str(GLOBAL_STOP), "check", check=False
            ).returncode,
            0,
        )

    def test_global_stop_mutations_serialize_and_server_lock_does_not_recurse(self):
        self.stop_lock.parent.mkdir(parents=True, exist_ok=True)
        with self.stop_lock.open("a+", encoding="utf-8") as lock:
            fcntl.flock(lock.fileno(), fcntl.LOCK_EX)
            setter = subprocess.Popen(
                ["bash", str(GLOBAL_STOP), "set", "serialized"],
                cwd=ROOT,
                env=self.env,
                text=True,
                stdout=subprocess.PIPE,
                stderr=subprocess.PIPE,
            )
            time.sleep(0.15)
            self.assertIsNone(setter.poll())
            fcntl.flock(lock.fileno(), fcntl.LOCK_UN)
            setter.communicate(timeout=5)
            self.assertEqual(setter.returncode, 0)
            self.assertTrue(self.stop.exists())

            fcntl.flock(lock.fileno(), fcntl.LOCK_EX)
            clearer = subprocess.Popen(
                ["bash", str(GLOBAL_STOP), "clear"],
                cwd=ROOT,
                env=self.env,
                text=True,
                stdout=subprocess.PIPE,
                stderr=subprocess.PIPE,
            )
            time.sleep(0.15)
            self.assertIsNone(clearer.poll())
            fcntl.flock(lock.fileno(), fcntl.LOCK_UN)
            clearer.communicate(timeout=5)
            self.assertEqual(clearer.returncode, 0)
            self.assertFalse(self.stop.exists())

            fcntl.flock(lock.fileno(), fcntl.LOCK_EX)
            held_env = {**self.env, "HERMES_STOP_LOCK_HELD": "1"}
            result = self.run_cmd(
                "bash", str(GLOBAL_STOP), "set", "server-owned lock",
                env=held_env,
            )
            self.assertEqual(result.returncode, 0)
            self.assertTrue(self.stop.exists())
            self.run_cmd("bash", str(GLOBAL_STOP), "clear", env=held_env)
            fcntl.flock(lock.fileno(), fcntl.LOCK_UN)

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
        held, _ = self.write_order("lock-held")
        self.dispatch_lock.parent.mkdir(parents=True, exist_ok=True)
        with self.dispatch_lock.open("w", encoding="utf-8") as lock:
            fcntl.flock(lock.fileno(), fcntl.LOCK_EX | fcntl.LOCK_NB)
            self.run_cmd("bash", str(CONSUMER))
            self.assertTrue(held.exists())
            self.assertEqual(self.send_count(), 0)

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
        tmux_log = self.fake_log.read_text(encoding="utf-8")
        self.assertIn(
            "send-keys -t worker -l -- perform boolean-order",
            tmux_log,
        )

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

    def test_stop_arriving_during_registration_blocks_final_send(self):
        repo = self.base / "race-repo"
        repo.mkdir()
        request_path, request = self.write_order("registration-race")
        request["working_directory"] = str(repo)
        request_path.write_text(json.dumps(request), encoding="utf-8")
        preflight_marker = self.base / "git-preflight-started"
        fake_git = self.bin / "git"
        fake_git.write_text(
            "#!/usr/bin/env bash\n"
            "set -euo pipefail\n"
            'if [[ ! -e "$PREFLIGHT_MARKER" ]]; then\n'
            '  touch "$PREFLIGHT_MARKER"\n'
            "  sleep 1\n"
            "fi\n"
            'case "$*" in\n'
            '  *"rev-parse HEAD"*) printf "%040d\\n" 1 ;;\n'
            '  *"branch --show-current"*) echo main ;;\n'
            "esac\n",
            encoding="utf-8",
        )
        fake_git.chmod(0o755)
        race_env = {**self.env, "PREFLIGHT_MARKER": str(preflight_marker)}
        process = subprocess.Popen(
            ["bash", str(CONSUMER)],
            cwd=ROOT,
            env=race_env,
            text=True,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
        )
        deadline = time.monotonic() + 5
        while not preflight_marker.exists() and time.monotonic() < deadline:
            time.sleep(0.02)
        self.assertTrue(preflight_marker.exists())
        self.stop.parent.mkdir(parents=True, exist_ok=True)
        self.stop.write_text("reason: race stop\n", encoding="utf-8")
        process.communicate(timeout=10)
        self.assertEqual(process.returncode, 0)
        self.assertTrue(request_path.exists())
        self.assertEqual(self.send_count(), 0)
        self.assertFalse(self.lane.exists())
        state = json.loads(
            (self.task_runs / "registration-race" / "state.json").read_text()
        )
        self.assertEqual(state["status"], "registered")

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
        completion = self.requests / "uncertain-completion.json"
        completion.write_text(json.dumps({
            "request_id": "uncertain-completion",
            "correlation_id": "uncertain-order:1",
            "agent": "hermes",
            "task": "uncertain-order",
            "type": "qa",
            "priority": "normal",
            "result": "Operator-confirmed completion after uncertain transport.",
        }), encoding="utf-8")
        self.run_cmd("bash", str(CONSUMER), env=fail_env)
        self.assertFalse(self.lane.exists())
        result = json.loads(
            (self.task_runs / "uncertain-order" / "result.json").read_text()
        )
        self.assertEqual(result["source_status"], "dispatch_uncertain")

    def test_terminal_qa_completion_releases_the_exact_lane(self):
        self.write_order("qa-terminal")
        self.run_cmd("bash", str(CONSUMER))
        self.assertTrue(self.lane.exists())
        completion = {
            "request_id": "qa-completion",
            "correlation_id": "qa-terminal:1",
            "agent": "hermes",
            "task": "qa-terminal",
            "type": "qa",
            "priority": "normal",
            "result": "The requested report is complete.",
            "created_at": "2026-07-24T00:01:00Z",
        }
        (self.requests / "qa-completion.json").write_text(
            json.dumps(completion, indent=2) + "\n", encoding="utf-8"
        )
        self.run_cmd("bash", str(CONSUMER))
        self.assertFalse(self.lane.exists())
        result = json.loads(
            (self.task_runs / "qa-terminal" / "result.json").read_text()
        )
        self.assertEqual(result["status"], "qa_pass")

    def test_lane_less_terminal_completion_reconciles_crash_after_release(self):
        self.write_order("qa-release-crash")
        self.run_cmd("bash", str(CONSUMER))
        sent = self.send_count()
        completion_path = self.requests / "aaa-release-completion.json"
        completion_id = "release-completion"
        completion_path.write_text(json.dumps({
            "request_id": completion_id,
            "correlation_id": "qa-release-crash:1",
            "agent": "hermes",
            "task": "qa-release-crash",
            "type": "qa",
            "priority": "normal",
            "result": "Terminal result committed before cleanup crash.",
        }), encoding="utf-8")
        self.run_cmd(
            "bash", str(QA_GATE), "run",
            "--request-id", "qa-release-crash",
            "--completion-file", str(completion_path),
        )
        self.run_cmd(
            "bash", str(LANE), "release",
            "--request-id", "qa-release-crash",
            "--reason", "qa_terminal",
        )
        self.assertFalse(self.lane.exists())

        task_request = (
            self.task_runs / "qa-release-crash" / "request.json"
        ).read_bytes()
        original = self.requests / "qa-release-crash.json"
        original.write_bytes(task_request)
        uncertain_dir = self.requests / ".uncertain"
        uncertain_dir.mkdir()
        uncertain = uncertain_dir / "qa-release-crash.json"
        uncertain.write_bytes(task_request)
        retry_dir = self.requests / ".retries"
        retry_dir.mkdir()
        retries = [
            retry_dir / f"qa-{completion_id}",
            retry_dir / f"qa-lane-{completion_id}",
            retry_dir / f"qa-release-{completion_id}",
        ]
        for marker in retries:
            marker.touch()

        self.run_cmd("bash", str(CONSUMER))
        self.assertEqual(self.send_count(), sent)
        self.assertFalse(self.lane.exists())
        self.assertFalse(completion_path.exists())
        self.assertFalse(original.exists())
        self.assertFalse(uncertain.exists())
        self.assertTrue(all(not marker.exists() for marker in retries))
        state = json.loads(
            (self.task_runs / "qa-release-crash" / "state.json").read_text()
        )
        self.assertEqual(state["status"], "qa_pass")

    def test_registered_delivery_cannot_complete_or_release_lane(self):
        request_path, _ = self.write_order("registered-only")
        self.run_cmd(
            "bash", str(LANE), "acquire", "--request-file", str(request_path)
        )
        self.run_cmd(
            "bash", str(QA_GATE), "register", "--request-file", str(request_path)
        )
        completion_path = self.requests / "aaa-completion.json"
        completion_path.write_text(json.dumps({
            "request_id": "registered-completion",
            "correlation_id": "registered-only:1",
            "agent": "hermes",
            "task": "registered-only",
            "type": "qa",
            "priority": "normal",
            "result": "premature",
        }), encoding="utf-8")
        direct = self.run_cmd(
            "bash", str(QA_GATE), "run",
            "--request-id", "registered-only",
            "--completion-file", str(completion_path),
            check=False,
        )
        self.assertNotEqual(direct.returncode, 0)
        self.run_cmd("bash", str(CONSUMER))
        self.assertTrue(completion_path.exists())
        self.assertTrue(self.lane.exists())
        self.assertFalse(
            (self.task_runs / "registered-only" / "result.json").exists()
        )
        state = json.loads(
            (self.task_runs / "registered-only" / "state.json").read_text()
        )
        self.assertEqual(state["status"], "registered")

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
        stored_request = json.loads(
            (self.task_runs / "hash-order" / "request.json").read_text()
        )
        self.assertEqual(second["request_sha256"], contract_hash(stored_request))

    def test_canonical_contract_accepts_minified_unicode_request(self):
        request_path, request = self.write_order("unicode-order")
        request["title"] = "Café Ω"
        request_path.write_text(
            json.dumps(request, ensure_ascii=False, separators=(",", ":")),
            encoding="utf-8",
        )
        registered = json.loads(self.run_cmd(
            "bash", str(QA_GATE), "register", "--request-file", str(request_path)
        ).stdout)
        self.assertEqual(registered["request_sha256"], contract_hash(request))
        self.run_cmd(
            "bash", str(QA_GATE), "transition",
            "--request-id", "unicode-order", "--status", "dispatched",
        )
        completion = self.base / "unicode-completion.json"
        completion.write_text(
            json.dumps({"result": "Unicode delivery complete."}),
            encoding="utf-8",
        )
        result = self.run_cmd(
            "bash", str(QA_GATE), "run",
            "--request-id", "unicode-order",
            "--completion-file", str(completion),
        )
        self.assertEqual(json.loads(result.stdout)["status"], "qa_pass")

    def test_existing_immutable_result_reconciles_state_report_and_ticket(self):
        ticket_dir = self.base / "tickets"
        ticket_dir.mkdir()
        ticket = ticket_dir / "ORD-RECONCILE.md"
        ticket.write_text(
            "---\nid: ORD-RECONCILE\nstatus: in_progress\n---\n\n# Reconcile\n",
            encoding="utf-8",
        )
        request_path, request = self.write_order("reconcile-order")
        request["source_ticket"] = str(ticket)
        request_path.write_text(json.dumps(request), encoding="utf-8")
        registered = json.loads(self.run_cmd(
            "bash", str(QA_GATE), "register", "--request-file", str(request_path)
        ).stdout)
        self.run_cmd(
            "bash", str(QA_GATE), "transition",
            "--request-id", "reconcile-order", "--status", "dispatched",
        )
        task_dir = self.task_runs / "reconcile-order"
        immutable = {
            "request_id": "reconcile-order",
            "correlation_id": "reconcile-order:0",
            "status": "qa_pass",
            "checked_at": "2026-07-24T01:00:00Z",
            "checks": [{"type": "result_present", "passed": True}],
            "request_sha256": registered["request_sha256"],
            "source_status": "dispatched",
        }
        (task_dir / "result.json").write_text(
            json.dumps(immutable, indent=2) + "\n", encoding="utf-8"
        )
        completion = self.base / "reconcile-completion.json"
        completion.write_text(
            json.dumps({"result": "Recovered report body."}),
            encoding="utf-8",
        )
        self.run_cmd(
            "bash", str(QA_GATE), "run",
            "--request-id", "reconcile-order",
            "--completion-file", str(completion),
        )
        state = json.loads((task_dir / "state.json").read_text())
        self.assertEqual(state["status"], "qa_pass")
        self.assertIn(
            "Recovered report body.",
            (task_dir / "result.md").read_text(encoding="utf-8"),
        )
        ticket_text = ticket.read_text(encoding="utf-8")
        self.assertIn("status: pending_review", ticket_text)
        self.assertIn("Recovered report body.", ticket_text)

    @unittest.skipUnless(shutil.which("tmux"), "tmux is not installed")
    def test_real_tmux_literal_send_preserves_shell_metacharacters(self):
        socket = f"advanced-os-{uuid.uuid4().hex}"
        session = "literal-test"
        payload = "literal $HOME; [x] * ?"
        try:
            subprocess.run(
                ["tmux", "-L", socket, "new-session", "-d", "-s", session, "cat"],
                check=True,
                timeout=5,
            )
            subprocess.run(
                ["tmux", "-L", socket, "send-keys", "-t", session,
                 "-l", "--", payload],
                check=True,
                timeout=5,
            )
            subprocess.run(
                ["tmux", "-L", socket, "send-keys", "-t", session, "Enter"],
                check=True,
                timeout=5,
            )
            time.sleep(0.1)
            captured = subprocess.run(
                ["tmux", "-L", socket, "capture-pane", "-t", session, "-p"],
                check=True,
                text=True,
                capture_output=True,
                timeout=5,
            ).stdout
            self.assertIn(payload, captured)
        finally:
            subprocess.run(
                ["tmux", "-L", socket, "kill-server"],
                check=False,
                stdout=subprocess.DEVNULL,
                stderr=subprocess.DEVNULL,
                timeout=5,
            )


if __name__ == "__main__":
    unittest.main()
