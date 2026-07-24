import hashlib
import json
import os
import pathlib
import subprocess
import tempfile
import unittest


ROOT = pathlib.Path(__file__).resolve().parents[1]
QA_GATE = ROOT / "scripts" / "qa-gate.sh"
TICKET_SCAN = ROOT / "scripts" / "ticket-scan.sh"


class Phase5ShellTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.base = pathlib.Path(self.temp.name)
        self.home = self.base / "home"
        self.home.mkdir()
        self.env = {
            **os.environ,
            "HOME": str(self.home),
            "HERMES_TASK_RUN_DIR": str(self.base / "task-runs"),
            "HERMES_TICKET_DIR": str(self.base / "tickets"),
            "HERMES_REQUESTS_DIR": str(self.base / "requests"),
            "HERMES_LEARNINGS_FILE": str(self.base / "hermes-learnings.md"),
            "HERMES_TICKET_LOCK": str(self.base / "ticket-scan.lock"),
            "HERMES_ALERT_STATE": str(self.base / "alerts"),
        }

    def tearDown(self):
        self.temp.cleanup()

    def run_cmd(self, *argv, check=True):
        return subprocess.run(
            argv,
            cwd=ROOT,
            env=self.env,
            capture_output=True,
            text=True,
            check=check,
            timeout=20,
        )

    def init_git_repo(self):
        repo = self.base / "repo"
        repo.mkdir()
        self.run_cmd("git", "init", "-q", str(repo))
        self.run_cmd("git", "-C", str(repo), "config", "user.name", "Phase Five Test")
        self.run_cmd("git", "-C", str(repo), "config", "user.email", "phase5@example.invalid")
        (repo / "README.md").write_text("baseline\n", encoding="utf-8")
        self.run_cmd("git", "-C", str(repo), "add", "README.md")
        self.run_cmd("git", "-C", str(repo), "commit", "-qm", "chore: baseline")
        return repo

    def test_qa_gate_registers_baseline_and_passes_concrete_checks(self):
        repo = self.init_git_repo()
        request_id = "delivery-1"
        request_file = self.base / "request.json"
        request_file.write_text(json.dumps({
            "request_id": request_id,
            "correlation_id": f"{request_id}:0",
            "title": "Phase 5 delivery",
            "working_directory": str(repo),
            "qa_checks": [
                {"type": "commit_advanced"},
                {"type": "clean_worktree"},
                {"type": "file_exists", "value": "READY"},
                {"type": "command_exit_zero", "value": "test -s READY"},
            ],
        }), encoding="utf-8")
        task_dir = pathlib.Path(self.env["HERMES_TASK_RUN_DIR"]) / request_id
        task_dir.mkdir(parents=True)
        stored_request = task_dir / "request.json"
        stored_request.write_bytes(request_file.read_bytes())
        (task_dir / "state.json").write_text(json.dumps({
            "request_id": request_id,
            "status": "queued",
            "queued_at": "2026-07-24T00:00:00Z",
            "request_sha256": hashlib.sha256(stored_request.read_bytes()).hexdigest(),
        }), encoding="utf-8")
        self.run_cmd("bash", str(QA_GATE), "register", "--request-file", str(request_file))
        registered = json.loads((task_dir / "state.json").read_text(encoding="utf-8"))
        self.assertEqual(registered["status"], "registered")
        self.assertEqual(registered["queued_at"], "2026-07-24T00:00:00Z")
        self.assertNotIn("dispatched_at", registered)
        self.run_cmd(
            "bash", str(QA_GATE), "transition",
            "--request-id", request_id, "--status", "dispatched",
        )
        dispatched = json.loads((task_dir / "state.json").read_text(encoding="utf-8"))
        self.assertEqual(dispatched["status"], "dispatched")
        self.assertTrue(dispatched["dispatched_at"])

        (repo / "READY").write_text("ready\n", encoding="utf-8")
        self.run_cmd("git", "-C", str(repo), "add", "READY")
        self.run_cmd("git", "-C", str(repo), "commit", "-qm", "feat: finish delivery")
        result = self.run_cmd(
            "bash", str(QA_GATE), "run", "--request-id", request_id
        )
        payload = json.loads(result.stdout)
        self.assertEqual(payload["status"], "qa_pass")
        self.assertTrue(all(check["passed"] for check in payload["checks"]))

    def test_ticket_scanner_only_claims_report_only_allowed_agents(self):
        ticket_dir = pathlib.Path(self.env["HERMES_TICKET_DIR"])
        ticket_dir.mkdir()
        ticket = ticket_dir / "ticket-0001.md"
        ticket.write_text(
            "---\n"
            "id: ticket-0001\n"
            "status: fresh\n"
            "created: 2026-07-24T00:00:00Z\n"
            'owner: ""\n'
            "priority: medium\n"
            "mode: report-only\n"
            "agent: ezekiel\n"
            "---\n\n"
            "## Goal\nAudit the dispatch ward.\n\n"
            "## Acceptance Criteria\n- [ ] Report written\n\n"
            "## Stop Conditions\n- Do not mutate external state\n\n"
            "## Results\n",
            encoding="utf-8",
        )
        result = self.run_cmd("bash", str(TICKET_SCAN), "scan")
        payload = json.loads(result.stdout)
        self.assertEqual(payload["claimed"], 1)
        self.assertIn("status: claimed", ticket.read_text(encoding="utf-8"))
        requests = list(pathlib.Path(self.env["HERMES_REQUESTS_DIR"]).glob("*.json"))
        self.assertEqual(len(requests), 1)
        request = json.loads(requests[0].read_text(encoding="utf-8"))
        self.assertEqual(request["type"], "ticket")
        self.assertEqual(request["approval_policy"], "no_deploy")
        self.assertEqual(request["qa_checks"], [{"type": "result_present"}])
        self.assertIn("--result-file", request["task"])


if __name__ == "__main__":
    unittest.main()
