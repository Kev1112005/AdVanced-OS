import importlib.util
import json
import os
import pathlib
import tempfile
import unittest


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
                "id": "codex", "name": "Codex", "type": "codex",
                "transport": "local_tmux", "scope": "local",
            }],
            "agents": [{
                "id": "codex-azrael", "name": "Azrael", "provider_id": "codex",
                "session": "codex-azrael", "role": "Build", "model": "provider default",
                "restart_command": ["codex"],
            }],
        }), encoding="utf-8")
        self.paths["status"].write_text(json.dumps({
            "workers": [{
                "name": "Azrael", "session": "codex-azrael", "status": "active",
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

    def test_registry_overlays_live_status(self):
        registry = mission_control.load_provider_registry()
        self.assertEqual(registry["agents"][0]["status"], "active")
        self.assertEqual(registry["agents"][0]["model"], "test-model")
        self.assertEqual(registry["providers"][0]["counts"], {"total": 1, "online": 1, "active": 1})
        self.assertFalse(registry["demo_recommended"])

    def test_structured_order_is_persisted_for_the_serial_consumer(self):
        code, response = mission_control.create_dispatch(json.dumps({
            "agent": "codex-azrael",
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
        self.assertEqual(request["agent"], "codex-azrael")
        self.assertEqual(request["provider_id"], "codex")
        self.assertIn("# Reinforce the ward", request["task"])
        self.assertIn("- Tests pass", request["task"])

    def test_paused_agent_rejects_new_orders(self):
        code, _ = mission_control.control_agent(json.dumps({
            "agent": "codex-azrael", "action": "pause",
        }).encode())
        self.assertEqual(code, 200)
        code, response = mission_control.create_dispatch(json.dumps({
            "agent": "codex-azrael", "title": "Held order", "prompt": "Do not deliver yet.",
        }).encode())
        self.assertEqual(code, 409)
        self.assertIn("paused", response["error"])

    def test_cancel_removes_only_the_target_order(self):
        code, created = mission_control.create_dispatch(json.dumps({
            "agent": "codex-azrael", "title": "Withdraw me", "prompt": "Temporary task.",
        }).encode())
        self.assertEqual(code, 200)
        code, response = mission_control.cancel_dispatch(json.dumps({
            "request_id": created["request_id"],
        }).encode())
        self.assertEqual((code, response["status"]), (200, "cancelled"))
        self.assertFalse((self.paths["requests"] / f"{created['request_id']}.json").exists())

    def test_deployment_decision_is_written_as_explicit_operator_state(self):
        code, response = mission_control.deployment_decision(json.dumps({
            "deployment_id": "release-482", "decision": "approve", "reason": "Checks green",
        }).encode())
        self.assertEqual((code, response["status"]), (200, "approve"))
        record = json.loads((self.paths["approvals"] / "release-482.json").read_text())
        self.assertEqual(record["decision"], "approve")
        self.assertEqual(record["reason"], "Checks green")

    def test_global_stop_blocks_and_then_releases_dispatch(self):
        code, response = mission_control.global_stop_control(json.dumps({
            "action": "engage", "reason": "Test emergency seal",
        }).encode())
        self.assertEqual((code, response["status"]), (200, "stopped"))
        self.assertTrue(self.paths["stop"].exists())

        code, response = mission_control.create_dispatch(json.dumps({
            "agent": "codex-azrael", "title": "Blocked order", "prompt": "Remain queued.",
        }).encode())
        self.assertEqual(code, 423)
        self.assertIn("sealed", response["error"])

        code, response = mission_control.global_stop_control(json.dumps({
            "action": "release",
        }).encode())
        self.assertEqual((code, response["status"]), (200, "running"))
        self.assertFalse(self.paths["stop"].exists())


if __name__ == "__main__":
    unittest.main()
