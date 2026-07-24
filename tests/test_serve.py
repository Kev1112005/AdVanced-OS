import importlib.util
import json
import os
import pathlib
import subprocess
import tempfile
import threading
import unittest
import urllib.request


ROOT = pathlib.Path(__file__).resolve().parents[1]
SPEC = importlib.util.spec_from_file_location("mission_control", ROOT / "server" / "serve.py")
mission_control = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(mission_control)


class MissionControlTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        base = pathlib.Path(self.temp.name)
        self.paths = {
            "registry": base / "providers.json",
            "status": base / "status.json",
            "events": base / "events.log",
            "requests": base / "requests",
            "paused": base / "paused",
            "approvals": base / "approvals",
            "deployments": base / "deployments",
            "stop": base / "stop",
        }
        self.paths["registry"].write_text(json.dumps({
            "version": 1,
            "providers": [{
                "id": "hermes", "name": "Hermes", "type": "hermes",
                "transport": "local_tmux", "scope": "local",
            }],
            "agents": [{
                "id": "azrael", "name": "Azrael", "provider_id": "hermes",
                "session": "hermes", "role": "Orchestrator", "model": "DeepSeek V4 Flash",
                "restart_command": ["hermes", "--yolo"],
            }],
        }), encoding="utf-8")
        self.paths["status"].write_text(json.dumps({
            "workers": [{
                "name": "Azrael", "session": "hermes", "status": "active",
                "model": "test-model", "project": "AdVanced OS",
            }]
        }), encoding="utf-8")

        mission_control.PROVIDER_FILE = str(self.paths["registry"])
        mission_control.STATUS_FILE = str(self.paths["status"])
        mission_control.EVENT_LOG = str(self.paths["events"])
        mission_control.REQ_DIR = str(self.paths["requests"])
        mission_control.PAUSE_DIR = str(self.paths["paused"])
        mission_control.APPROVAL_DIR = str(self.paths["approvals"])
        mission_control.DEPLOY_DIR = str(self.paths["deployments"])
        self.old_stop = os.environ.get("HERMES_STOP_FILE")
        os.environ["HERMES_STOP_FILE"] = str(self.paths["stop"])

    def tearDown(self):
        if self.old_stop is None:
            os.environ.pop("HERMES_STOP_FILE", None)
        else:
            os.environ["HERMES_STOP_FILE"] = self.old_stop
        self.temp.cleanup()

    def write_deployment_request(self, deployment_id):
        self.paths["deployments"].mkdir(parents=True, exist_ok=True)
        path = self.paths["deployments"] / f"{deployment_id}.json"
        path.write_text(json.dumps({
            "id": deployment_id,
            "title": "Release candidate",
            "summary": "All checks passed",
            "risk": "medium",
            "created_at": "2026-07-24T00:00:00Z",
        }), encoding="utf-8")
        return path

    def test_registry_overlays_live_status(self):
        registry = mission_control.load_provider_registry()
        self.assertEqual(registry["agents"][0]["status"], "active")
        self.assertEqual(registry["agents"][0]["model"], "test-model")
        self.assertEqual(registry["providers"][0]["counts"], {"total": 1, "online": 1, "active": 1})
        self.assertFalse(registry["demo_recommended"])

    def test_production_registry_maps_azrael_to_primary_hermes(self):
        registry = json.loads((ROOT / "config" / "providers.json").read_text(encoding="utf-8"))
        azrael = next(agent for agent in registry["agents"] if agent["name"] == "Azrael")
        self.assertEqual(azrael["id"], "azrael")
        self.assertEqual(azrael["provider_id"], "hermes")
        self.assertEqual(azrael["session"], "hermes")
        self.assertEqual(azrael["model"], "DeepSeek V4 Flash")
        self.assertEqual(azrael["restart_command"][0], "hermes")

    def test_providers_endpoint_serves_registered_agents(self):
        server = mission_control.ThreadingHTTPServer(("127.0.0.1", 0), mission_control.Handler)
        thread = threading.Thread(target=server.serve_forever, daemon=True)
        thread.start()
        try:
            with urllib.request.urlopen(
                f"http://127.0.0.1:{server.server_port}/api/providers", timeout=2
            ) as response:
                registry = json.load(response)
            self.assertEqual(response.status, 200)
            self.assertEqual(registry["agents"][0]["id"], "azrael")
            self.assertEqual(registry["agents"][0]["provider_id"], "hermes")
        finally:
            server.shutdown()
            server.server_close()
            thread.join(timeout=2)

    def test_structured_order_is_persisted_for_the_serial_consumer(self):
        code, response = mission_control.create_dispatch(json.dumps({
            "agent": "azrael",
            "title": "Reinforce the ward",
            "repository": "Kev1112005/AdVanced-OS",
            "branch": "agent/ward",
            "priority": "high",
            "prompt": "Implement the provider adapter.",
            "acceptance_criteria": ["Tests pass", "Open a draft PR"],
            "approval_policy": "confirm_deploy",
        }).encode())
        self.assertEqual(code, 200)
        request = json.loads((self.paths["requests"] / f"{response['request_id']}.json").read_text())
        self.assertEqual(request["agent"], "hermes")
        self.assertEqual(request["provider_id"], "hermes")
        self.assertIn("# Reinforce the ward", request["task"])
        self.assertIn("- Tests pass", request["task"])

    def test_paused_agent_rejects_new_orders(self):
        code, _ = mission_control.control_agent(json.dumps({
            "agent": "azrael", "action": "pause",
        }).encode())
        self.assertEqual(code, 200)
        code, response = mission_control.create_dispatch(json.dumps({
            "agent": "azrael", "title": "Held order", "prompt": "Do not deliver yet.",
        }).encode())
        self.assertEqual(code, 409)
        self.assertIn("paused", response["error"])

    def test_cancel_removes_only_the_target_order(self):
        code, created = mission_control.create_dispatch(json.dumps({
            "agent": "azrael", "title": "Withdraw me", "prompt": "Temporary task.",
        }).encode())
        self.assertEqual(code, 200)
        code, response = mission_control.cancel_dispatch(json.dumps({
            "request_id": created["request_id"],
        }).encode())
        self.assertEqual((code, response["status"]), (200, "cancelled"))
        self.assertFalse((self.paths["requests"] / f"{created['request_id']}.json").exists())

    def test_deployment_decision_is_written_as_explicit_operator_state(self):
        self.write_deployment_request("release-482")
        code, response = mission_control.deployment_decision(json.dumps({
            "deployment_id": "release-482", "decision": "approve", "reason": "Checks green",
        }).encode())
        self.assertEqual((code, response["status"]), (200, "approve"))
        self.assertFalse(response["idempotent"])
        record = json.loads((self.paths["approvals"] / "release-482.json").read_text())
        self.assertEqual(record["decision"], "approve")
        self.assertEqual(record["reason"], "Checks green")

        code, response = mission_control.deployment_decision(json.dumps({
            "deployment_id": "release-482", "decision": "approve",
        }).encode())
        self.assertEqual((code, response["idempotent"]), (200, True))

        code, response = mission_control.deployment_decision(json.dumps({
            "deployment_id": "release-482", "decision": "deny", "reason": "Changed my mind",
        }).encode())
        self.assertEqual(code, 409)
        self.assertIn("already has decision", response["error"])
        unchanged = json.loads((self.paths["approvals"] / "release-482.json").read_text())
        self.assertEqual(unchanged["decision"], "approve")

    def test_deployment_decision_requires_a_durable_request(self):
        code, response = mission_control.deployment_decision(json.dumps({
            "deployment_id": "missing-release", "decision": "approve",
        }).encode())
        self.assertEqual(code, 404)
        self.assertIn("not found", response["error"])

    def test_deployment_decision_uses_the_shared_strict_id_contract(self):
        code, response = mission_control.deployment_decision(json.dumps({
            "deployment_id": "release:482", "decision": "approve",
        }).encode())
        self.assertEqual(code, 400)
        self.assertIn("deployment id", response["error"])

    def test_deployment_decision_fails_closed_on_invalid_request_state(self):
        for deployment_id, content in (
            ("empty-request", "{}"),
            ("corrupt-request", "{not-json"),
        ):
            with self.subTest(deployment_id=deployment_id):
                request = self.write_deployment_request(deployment_id)
                request.write_text(content, encoding="utf-8")
                code, response = mission_control.deployment_decision(json.dumps({
                    "deployment_id": deployment_id,
                    "decision": "approve",
                }).encode())
                self.assertEqual(code, 409)
                self.assertIn("deployment request", response["error"])
                self.assertFalse(
                    (self.paths["approvals"] / f"{deployment_id}.json").exists()
                )

    def test_deployment_decision_never_replaces_invalid_approval_state(self):
        for deployment_id, content in (
            ("empty-approval", "{}"),
            ("corrupt-approval", "{not-json"),
        ):
            with self.subTest(deployment_id=deployment_id):
                self.write_deployment_request(deployment_id)
                self.paths["approvals"].mkdir(parents=True, exist_ok=True)
                approval = self.paths["approvals"] / f"{deployment_id}.json"
                approval.write_text(content, encoding="utf-8")
                code, response = mission_control.deployment_decision(json.dumps({
                    "deployment_id": deployment_id,
                    "decision": "approve",
                }).encode())
                self.assertEqual(code, 409)
                self.assertIn("deployment decision", response["error"])
                self.assertEqual(approval.read_text(encoding="utf-8"), content)

    def test_global_stop_blocks_and_then_releases_dispatch(self):
        code, response = mission_control.global_stop_control(json.dumps({
            "action": "engage", "reason": "Test emergency seal",
        }).encode())
        self.assertEqual((code, response["status"]), (200, "stopped"))
        self.assertTrue(self.paths["stop"].exists())

        code, response = mission_control.create_dispatch(json.dumps({
            "agent": "azrael", "title": "Blocked order", "prompt": "Remain queued.",
        }).encode())
        self.assertEqual(code, 423)
        self.assertIn("sealed", response["error"])

        code, response = mission_control.global_stop_control(json.dumps({
            "action": "release",
        }).encode())
        self.assertEqual((code, response["status"]), (200, "running"))
        self.assertFalse(self.paths["stop"].exists())


class DeployApprovalScriptTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.base = pathlib.Path(self.temp.name)
        self.deployments = self.base / "deployments"
        self.approvals = self.base / "approvals"
        self.events = self.base / "events.log"
        self.script = ROOT / "scripts" / "deploy-approval.sh"
        self.env = {
            **os.environ,
            "HERMES_DEPLOY_REQUEST_DIR": str(self.deployments),
            "HERMES_APPROVAL_DIR": str(self.approvals),
            "HERMES_EVENT_LOG": str(self.events),
            "HERMES_DEPLOY_NOTIFY": "0",
            "USER": "Kevin",
        }

    def tearDown(self):
        self.temp.cleanup()

    def run_script(self, *args, extra_env=None):
        return subprocess.run(
            ["bash", str(self.script), *args],
            capture_output=True,
            text=True,
            env={**self.env, **(extra_env or {})},
            timeout=5,
        )

    def test_request_approval_and_gate_check_are_durable(self):
        created = self.run_script(
            "request",
            "--id", "release-9000",
            "--title", "AdVanced OS release",
            "--summary", "CI green; no schema changes",
            "--repository", "Kev1112005/AdVanced-OS",
            "--ref", "main@abc123",
            "--risk", "low",
            "--checks", "8 tests passed",
            "--rollback", "Revert merge commit",
        )
        self.assertEqual(created.returncode, 0, created.stderr)
        self.assertIn("approve deploy release-9000", created.stdout)
        request = json.loads((self.deployments / "release-9000.json").read_text())
        self.assertEqual(request["status"], "pending")
        self.assertEqual(request["risk"], "low")

        pending = self.run_script("check", "--id", "release-9000")
        self.assertEqual(pending.returncode, 1)
        self.assertEqual(json.loads(pending.stdout)["status"], "pending")

        approved = self.run_script(
            "decide",
            "--id", "release-9000",
            "--decision", "approve",
            "--by", "Kevin via Discord",
        )
        self.assertEqual(approved.returncode, 0, approved.stderr)
        self.assertFalse(json.loads(approved.stdout)["idempotent"])

        repeated = self.run_script(
            "decide",
            "--id", "release-9000",
            "--decision", "approve",
            "--by", "Kevin via Discord",
        )
        self.assertEqual(repeated.returncode, 0, repeated.stderr)
        self.assertTrue(json.loads(repeated.stdout)["idempotent"])

        check = self.run_script("check", "--id", "release-9000")
        self.assertEqual(check.returncode, 0, check.stderr)
        self.assertEqual(json.loads(check.stdout)["decision"], "approve")

        conflict = self.run_script(
            "decide",
            "--id", "release-9000",
            "--decision", "deny",
            "--reason", "conflicting decision",
        )
        self.assertEqual(conflict.returncode, 5)
        decision = json.loads((self.approvals / "release-9000.json").read_text())
        self.assertEqual(decision["decision"], "approve")

    def test_denial_blocks_the_gate(self):
        created = self.run_script(
            "request",
            "--id", "release-denied",
            "--title", "Risky release",
            "--summary", "Schema migration requires review",
            "--risk", "high",
        )
        self.assertEqual(created.returncode, 0, created.stderr)
        denied = self.run_script(
            "decide",
            "--id", "release-denied",
            "--decision", "deny",
            "--reason", "Rollback plan is incomplete",
            "--by", "Kevin via Discord",
        )
        self.assertEqual(denied.returncode, 0, denied.stderr)

        check = self.run_script("check", "--id", "release-denied")
        self.assertEqual(check.returncode, 2)
        record = json.loads(check.stdout)
        self.assertEqual(record["decision"], "deny")
        self.assertEqual(record["reason"], "Rollback plan is incomplete")

    def test_shell_and_mission_control_reject_the_same_unsafe_id(self):
        created = self.run_script(
            "request",
            "--id", "release:482",
            "--title", "Invalid identifier",
            "--summary", "Must not create state",
        )
        self.assertEqual(created.returncode, 3)
        self.assertFalse((self.deployments / "release:482.json").exists())

    def test_installed_symlink_resolves_the_shared_helper(self):
        installed = self.base / "installed" / "deploy-approval.sh"
        installed.parent.mkdir()
        installed.symlink_to(self.script)
        created = subprocess.run(
            [
                "bash",
                str(installed),
                "request",
                "--id",
                "release-symlink",
                "--title",
                "Installed command",
                "--summary",
                "Resolve the helper from the checkout",
            ],
            capture_output=True,
            text=True,
            env=self.env,
            timeout=5,
        )
        self.assertEqual(created.returncode, 0, created.stderr)
        self.assertTrue((self.deployments / "release-symlink.json").exists())

    def test_corrupt_approval_fails_closed_without_overwrite(self):
        created = self.run_script(
            "request",
            "--id", "release-corrupt",
            "--title", "Corrupt state test",
            "--summary", "Must remain blocked",
        )
        self.assertEqual(created.returncode, 0, created.stderr)
        self.approvals.mkdir(parents=True, exist_ok=True)
        approval = self.approvals / "release-corrupt.json"
        approval.write_text("{}", encoding="utf-8")

        decided = self.run_script(
            "decide",
            "--id", "release-corrupt",
            "--decision", "approve",
        )
        self.assertEqual(decided.returncode, 3)
        self.assertIn("deployment decision", decided.stderr)
        self.assertEqual(approval.read_text(encoding="utf-8"), "{}")

        checked = self.run_script("check", "--id", "release-corrupt")
        self.assertEqual(checked.returncode, 3)
        self.assertEqual(json.loads(checked.stdout)["status"], "invalid")

    def test_request_succeeds_when_discord_notification_fails(self):
        binary_dir = self.base / "bin"
        binary_dir.mkdir()
        hermes = binary_dir / "hermes"
        hermes.write_text("#!/usr/bin/env bash\nexit 1\n", encoding="utf-8")
        hermes.chmod(0o755)

        created = self.run_script(
            "request",
            "--id", "release-notify-retry",
            "--title", "Notification retry",
            "--summary", "The durable request is authoritative",
            extra_env={
                "HERMES_DEPLOY_NOTIFY": "1",
                "HERMES_DEPLOY_APPROVAL_TARGET": "discord:test-channel",
                "PATH": f"{binary_dir}:{os.environ['PATH']}",
            },
        )
        self.assertEqual(created.returncode, 0, created.stderr)
        self.assertTrue((self.deployments / "release-notify-retry.json").exists())
        self.assertIn("request pending", created.stdout)
        self.assertIn("request release-notify-retry is durable", created.stderr)

    def test_documented_smoke_test_uses_isolated_state(self):
        setup = (
            ROOT / "docs" / "setup" / "deployment-approval.md"
        ).read_text(encoding="utf-8")
        smoke_test = setup.split(
            "# Exercise request formatting with isolated state", 1
        )[1]
        self.assertIn("HERMES_DEPLOY_REQUEST_DIR=", smoke_test)
        self.assertIn("HERMES_APPROVAL_DIR=", smoke_test)


if __name__ == "__main__":
    unittest.main()
