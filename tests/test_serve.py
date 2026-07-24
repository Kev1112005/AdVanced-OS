import fcntl
import importlib.util
import json
import os
import pathlib
import subprocess
import tempfile
import threading
import unittest
import urllib.error
import urllib.request
from contextlib import contextmanager
from unittest import mock


ROOT = pathlib.Path(__file__).resolve().parents[1]
SPEC = importlib.util.spec_from_file_location("mission_control", ROOT / "server" / "serve.py")
mission_control = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(mission_control)


@contextmanager
def running_server():
    server = mission_control.ThreadingHTTPServer(
        ("127.0.0.1", 0), mission_control.Handler
    )
    thread = threading.Thread(target=server.serve_forever, daemon=True)
    thread.start()
    try:
        yield f"http://127.0.0.1:{server.server_port}"
    finally:
        server.shutdown()
        server.server_close()
        thread.join(timeout=2)


def http_request(base, path, *, data=None, headers=None, method=None):
    request = urllib.request.Request(
        base + path,
        data=data,
        headers=headers or {},
        method=method,
    )
    try:
        response = urllib.request.urlopen(request, timeout=2)
    except urllib.error.HTTPError as error:
        response = error
    body = response.read()
    try:
        payload = json.loads(body)
    except ValueError:
        payload = body.decode("utf-8", "replace")
    return response.status, response.headers, payload


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
            "task_runs": base / "task-runs",
            "tickets": base / "tickets",
            "learnings": base / "hermes-learnings.md",
            "learnings_lock": base / "hermes-learnings.lock",
            "dispatch_lock": base / "dispatch-consumer.lock",
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
        mission_control.TASK_RUN_DIR = str(self.paths["task_runs"])
        mission_control.TICKET_DIR = str(self.paths["tickets"])
        mission_control.LEARNINGS_FILE = str(self.paths["learnings"])
        mission_control.LEARNINGS_LOCK = str(self.paths["learnings_lock"])
        mission_control.DISPATCH_LOCK = str(self.paths["dispatch_lock"])
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

    def test_dashboard_service_shares_the_tmux_socket_namespace(self):
        unit = (ROOT / "config" / "systemd" / "advanced-os-dashboard@.service").read_text(
            encoding="utf-8"
        )
        self.assertIn("PrivateTmp=false", unit)

    def test_order_submit_handler_is_not_shadowed_by_its_button(self):
        dashboard = (ROOT / "public" / "index.html").read_text(encoding="utf-8")
        self.assertIn('onsubmit="submitOrder(event)"', dashboard)
        self.assertIn('id="submitOrderBtn"', dashboard)
        self.assertNotIn('id="submitOrder"', dashboard)

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

    def test_post_rejects_oversized_request_body(self):
        server = mission_control.ThreadingHTTPServer(
            ("127.0.0.1", 0), mission_control.Handler
        )
        thread = threading.Thread(target=server.serve_forever, daemon=True)
        thread.start()
        try:
            request = urllib.request.Request(
                f"http://127.0.0.1:{server.server_port}/api/deploy/decision",
                data=b"x" * (mission_control.MAX_REQUEST_BODY_BYTES + 1),
                method="POST",
                headers={"Content-Type": "application/json"},
            )
            with self.assertRaises(urllib.error.HTTPError) as caught:
                urllib.request.urlopen(request, timeout=2)
            self.assertEqual(caught.exception.code, 413)
        finally:
            server.shutdown()
            server.server_close()
            thread.join(timeout=2)

    def test_post_security_boundary_requires_same_origin_json(self):
        with running_server() as base:
            status, headers, payload = http_request(
                base,
                "/api/learnings",
                data=b'{"text":"cross-site write"}',
                method="POST",
                headers={
                    "Content-Type": "text/plain",
                    "Origin": "https://evil.example",
                    "Sec-Fetch-Site": "cross-site",
                },
            )
            self.assertEqual(status, 403)
            self.assertIn("cross-origin", payload["error"])
            self.assertFalse(self.paths["learnings"].exists())
            self.assertIsNone(headers.get("Access-Control-Allow-Origin"))

            status, _, _ = http_request(
                base,
                "/api/learnings",
                data=b'{"text":"null origin"}',
                method="POST",
                headers={"Content-Type": "application/json", "Origin": "null"},
            )
            self.assertEqual(status, 403)

            status, _, _ = http_request(
                base,
                "/api/learnings",
                data=b'{"text":"malformed origin"}',
                method="POST",
                headers={"Content-Type": "application/json", "Origin": "http://["},
            )
            self.assertEqual(status, 403)

            status, _, payload = http_request(
                base,
                "/api/learnings",
                data=b'{"text":"wrong media type"}',
                method="POST",
                headers={"Content-Type": "text/plain"},
            )
            self.assertEqual(status, 415)
            self.assertIn("application/json", payload["error"])

            origin = base
            status, headers, payload = http_request(
                base,
                "/api/learnings",
                data=b'{"text":"same origin"}',
                method="POST",
                headers={
                    "Content-Type": "application/json; charset=utf-8",
                    "Origin": origin,
                    "Sec-Fetch-Site": "same-origin",
                },
            )
            self.assertEqual((status, payload["status"]), (200, "recorded"))
            self.assertEqual(headers["Access-Control-Allow-Origin"], origin)
            self.assertEqual(headers["Cache-Control"], "no-store")
            self.assertEqual(headers["X-Frame-Options"], "DENY")
            self.assertIn("frame-ancestors 'none'", headers["Content-Security-Policy"])
            self.assertNotEqual(headers.get("Access-Control-Allow-Origin"), "*")

            status, _, payload = http_request(
                base,
                "/api/learnings",
                data=b'{"text":"origin-less CLI"}',
                method="POST",
                headers={"Content-Type": "application/json"},
            )
            self.assertEqual((status, payload["status"]), (200, "recorded"))

    def test_explicit_allowed_origin_is_echoed_not_wildcarded(self):
        origin = "https://trusted.example"
        mission_control.ALLOWED_ORIGINS.add(origin)
        self.addCleanup(mission_control.ALLOWED_ORIGINS.discard, origin)
        with running_server() as base:
            status, headers, payload = http_request(
                base,
                "/api/learnings",
                data=b'{"text":"trusted console"}',
                method="POST",
                headers={
                    "Content-Type": "application/json",
                    "Origin": origin,
                    "Sec-Fetch-Site": "cross-site",
                },
            )
        self.assertEqual((status, payload["status"]), (200, "recorded"))
        self.assertEqual(headers["Access-Control-Allow-Origin"], origin)

    def test_mutations_reject_non_object_json_without_dropping_connection(self):
        functions = (
            mission_control.create_dispatch,
            mission_control.cancel_dispatch,
            mission_control.control_agent,
            mission_control.global_stop_control,
            mission_control.deployment_decision,
            mission_control.send_keys,
            mission_control.clear_session,
            mission_control.review_ticket,
            mission_control.add_learning,
        )
        for function in functions:
            with self.subTest(function=function.__name__):
                code, response = function(b"[]")
                self.assertEqual(code, 400)
                self.assertIn("must be an object", response["error"])

        with running_server() as base:
            status, _, payload = http_request(
                base,
                "/api/learnings",
                data=b"[]",
                method="POST",
                headers={"Content-Type": "application/json"},
            )
        self.assertEqual(status, 400)
        self.assertIn("must be an object", payload["error"])

    def test_integer_query_parameters_are_bounded_and_controlled(self):
        paths = (
            "/api/events?limit=invalid",
            "/api/events?limit=0",
            "/api/events?limit=501",
            "/api/task-runs?limit=invalid",
            "/api/tickets?limit=-1",
            "/api/notifications?limit=999999",
            "/api/agent/session?session=azrael&lines=invalid",
            "/api/agent/session?session=azrael&lines=501",
        )
        with running_server() as base:
            for path in paths:
                with self.subTest(path=path):
                    status, _, payload = http_request(base, path)
                    self.assertEqual(status, 400)
                    self.assertIn("must be", payload["error"])

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
        self.assertTrue(request["qa_required"])
        self.assertEqual(
            [check["type"] for check in request["qa_checks"]],
            ["commit_advanced", "clean_worktree", "branch_matches"],
        )
        self.assertIn("hermes-request.sh qa", request["task"])
        task_run = self.paths["task_runs"] / response["request_id"]
        self.assertEqual(
            json.loads((task_run / "request.json").read_text())["request_id"],
            response["request_id"],
        )
        state = json.loads((task_run / "state.json").read_text())
        self.assertEqual(state["status"], "queued")
        self.assertTrue(state["request_sha256"])
        visible = mission_control.list_task_runs()
        self.assertEqual(visible[0]["status"], "queued")
        self.assertEqual(visible[0]["summary"], "Implement the provider adapter.")

    def test_report_order_requires_a_captured_result(self):
        code, response = mission_control.create_dispatch(json.dumps({
            "agent": "azrael",
            "title": "Research the ward",
            "prompt": "Return a report without changing external state.",
            "qa_mode": "report",
        }).encode())
        self.assertEqual(code, 200)
        request = json.loads(
            (self.paths["requests"] / f"{response['request_id']}.json").read_text()
        )
        self.assertEqual(request["qa_checks"], [{"type": "result_present"}])
        self.assertIn("--result-file", request["task"])

    def test_phase5_task_runs_are_exposed(self):
        run = self.paths["task_runs"] / "run-1"
        run.mkdir(parents=True)
        (run / "request.json").write_text(json.dumps({
            "request_id": "run-1",
            "title": "Verify delivery",
            "agent_id": "azrael",
            "created_at": "2026-07-24T00:00:00Z",
        }), encoding="utf-8")
        (run / "state.json").write_text(json.dumps({
            "status": "dispatched",
            "dispatched_at": "2026-07-24T00:01:00Z",
        }), encoding="utf-8")
        runs = mission_control.list_task_runs()
        self.assertEqual(runs[0]["request_id"], "run-1")
        self.assertEqual(runs[0]["status"], "dispatched")

    def test_new_dispatch_failure_states_are_exposed_without_shape_crashes(self):
        run = self.paths["task_runs"] / "run-failed"
        run.mkdir(parents=True)
        (run / "request.json").write_text(json.dumps({
            "request_id": "run-failed",
            "title": "Failed delivery",
            "agent_id": "azrael",
            "ticket_id": "../unsafe-ticket",
            "created_at": "2026-07-24T00:00:00Z",
        }), encoding="utf-8")
        (run / "state.json").write_text(json.dumps({
            "status": "dispatch_failed",
            "dispatch_failed_at": "2026-07-24T00:02:00Z",
            "last_error": "second Enter failed",
        }), encoding="utf-8")
        (run / "result.json").write_text("[]", encoding="utf-8")

        malformed = self.paths["task_runs"] / "run-malformed"
        malformed.mkdir()
        (malformed / "request.json").write_text("[]", encoding="utf-8")
        (malformed / "state.json").write_text("[]", encoding="utf-8")
        (malformed / "result.json").write_text("[]", encoding="utf-8")

        runs = {
            run["request_id"]: run for run in mission_control.list_task_runs()
        }
        self.assertEqual(runs["run-failed"]["status"], "dispatch_failed")
        self.assertEqual(
            runs["run-failed"]["dispatch_failed_at"], "2026-07-24T00:02:00Z"
        )
        self.assertEqual(runs["run-failed"]["last_error"], "second Enter failed")
        self.assertEqual(runs["run-failed"]["ticket_id"], "")
        self.assertEqual(runs["run-malformed"]["status"], "unknown")

    def test_wrong_shaped_registry_and_status_fail_safely(self):
        self.paths["registry"].write_text("[]", encoding="utf-8")
        self.paths["status"].write_text("[]", encoding="utf-8")
        registry = mission_control.load_provider_registry()
        self.assertEqual(registry["agents"], [])
        self.assertEqual(registry["providers"], [])
        status = mission_control.status_payload()
        self.assertEqual(status["workers"], [])
        self.assertEqual(status["cron_jobs"], [])
        self.assertTrue(status["snapshot_stale"])
        self.assertIn("snapshot_error", status)

    def test_registry_entries_with_unsafe_tmux_targets_are_ignored(self):
        self.paths["registry"].write_text(json.dumps({
            "version": 1,
            "providers": [{"id": "hermes", "name": "Hermes"}],
            "agents": [
                {
                    "id": "unsafe",
                    "name": "Unsafe",
                    "provider_id": "hermes",
                    "session": "hermes:1",
                },
                "not-an-object",
            ],
        }), encoding="utf-8")
        self.assertEqual(mission_control.load_provider_registry()["agents"], [])

    def test_agent_controls_use_the_registered_canonical_tmux_session(self):
        completed = subprocess.CompletedProcess([], 0, stdout="ready\n", stderr="")
        with (
            mock.patch.object(mission_control, "_session_alive", return_value=True),
            mock.patch.object(
                mission_control.subprocess, "run", return_value=completed
            ) as run,
            mock.patch.object(mission_control.time, "sleep"),
        ):
            code, response = mission_control.send_keys(json.dumps({
                "session": "azrael",
                "input": "status",
                "submit": False,
            }).encode())
            self.assertEqual((code, response["session"]), (200, "hermes"))
            self.assertIn(
                ["tmux", "send-keys", "-t", "hermes", "status"],
                [call.args[0] for call in run.call_args_list],
            )

            run.reset_mock()
            code, response = mission_control.clear_session(json.dumps({
                "session": "azrael",
            }).encode())
            self.assertEqual((code, response["session"]), (200, "hermes"))
            self.assertTrue(
                all(
                    call.args[0][3] == "hermes"
                    for call in run.call_args_list
                    if call.args[0][:3] == ["tmux", "send-keys", "-t"]
                )
            )

            run.reset_mock()
            code, response = mission_control.agent_session("azrael", 999)
            self.assertEqual((code, response["session"]), (200, "hermes"))
            self.assertEqual(
                run.call_args.args[0],
                ["tmux", "capture-pane", "-t", "hermes", "-p", "-S", "-500"],
            )

        code, response = mission_control.agent_session("not-registered", 20)
        self.assertEqual(code, 403)
        self.assertIn("provider registry", response["error"])

    def test_agent_session_endpoint_denies_unknown_registry_target(self):
        with running_server() as base:
            status, _, payload = http_request(
                base, "/api/agent/session?session=not-registered&lines=20"
            )
        self.assertEqual(status, 403)
        self.assertIn("provider registry", payload["error"])

    def test_learning_append_is_human_curated_and_visible(self):
        code, response = mission_control.add_learning(json.dumps({
            "text": "Keep QA checks concrete.",
            "tags": "qa,dispatch",
        }).encode())
        self.assertEqual((code, response["status"]), (200, "recorded"))
        learnings = mission_control.list_learnings()
        self.assertEqual(learnings["count"], 1)
        self.assertIn("Keep QA checks concrete.", learnings["entries"][0])

    def test_ticket_requires_operator_review_before_done(self):
        self.paths["tickets"].mkdir(parents=True)
        ticket = self.paths["tickets"] / "ticket-1.md"
        ticket.write_text(
            "---\n"
            "id: ticket-1\n"
            "status: pending_review\n"
            "created: 2026-07-24T00:00:00Z\n"
            "owner: hermes\n"
            "priority: medium\n"
            "mode: report-only\n"
            "---\n\n"
            "## Goal\nReview the ward.\n\n"
            "## Results\nChecks passed.\n",
            encoding="utf-8",
        )
        code, response = mission_control.review_ticket(json.dumps({
            "ticket_id": "ticket-1", "decision": "done",
        }).encode())
        self.assertEqual((code, response["status"]), (200, "done"))
        self.assertIn("status: done", ticket.read_text(encoding="utf-8"))

    def test_ticket_listing_rejects_unsafe_surfaced_id(self):
        self.paths["tickets"].mkdir(parents=True)
        (self.paths["tickets"] / "unsafe.md").write_text(
            "---\n"
            "id: ../../outside\n"
            "status: pending_review\n"
            "---\n\n"
            "## Goal\nDo not surface this identifier.\n",
            encoding="utf-8",
        )
        self.assertEqual(mission_control.list_tickets(), [])

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
        state = json.loads(
            (self.paths["task_runs"] / created["request_id"] / "state.json").read_text()
        )
        self.assertEqual(state["status"], "cancelled")
        self.assertTrue(state["cancelled_at"])

    def test_cancel_returns_conflict_while_serial_consumer_owns_lock(self):
        code, created = mission_control.create_dispatch(json.dumps({
            "agent": "azrael",
            "title": "Do not race",
            "prompt": "Remain durable while the consumer owns the gate.",
        }).encode())
        self.assertEqual(code, 200)
        queue_path = self.paths["requests"] / f"{created['request_id']}.json"
        state_path = (
            self.paths["task_runs"] / created["request_id"] / "state.json"
        )
        with open(self.paths["dispatch_lock"], "a+", encoding="utf-8") as lock:
            fcntl.flock(lock.fileno(), fcntl.LOCK_EX | fcntl.LOCK_NB)
            code, response = mission_control.cancel_dispatch(json.dumps({
                "request_id": created["request_id"],
            }).encode())
            self.assertEqual(code, 409)
            self.assertIn("serial consumer", response["error"])
        self.assertTrue(queue_path.exists())
        self.assertEqual(
            json.loads(state_path.read_text(encoding="utf-8"))["status"], "queued"
        )

    def test_second_cancel_never_relabels_an_absent_queue_item(self):
        code, created = mission_control.create_dispatch(json.dumps({
            "agent": "azrael",
            "title": "Cancel once",
            "prompt": "Only the first cancellation owns this order.",
        }).encode())
        self.assertEqual(code, 200)
        body = json.dumps({"request_id": created["request_id"]}).encode()
        self.assertEqual(mission_control.cancel_dispatch(body)[0], 200)
        code, response = mission_control.cancel_dispatch(body)
        self.assertEqual(code, 404)
        self.assertIn("not found", response["error"])

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

    def test_deployment_listing_skips_wrong_shaped_or_unsafe_records(self):
        self.paths["deployments"].mkdir(parents=True)
        (self.paths["deployments"] / "unsafe:release.json").write_text(
            json.dumps({
                "id": "unsafe:release",
                "title": "Unsafe",
                "summary": "Must not surface",
            }),
            encoding="utf-8",
        )
        (self.paths["deployments"] / "wrong-shape.json").write_text(
            "[]", encoding="utf-8"
        )
        self.write_deployment_request("release-valid")
        self.assertEqual(
            [item["id"] for item in mission_control.list_deployments()],
            ["release-valid"],
        )

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

    def test_status_uses_live_disk_stop_over_stale_snapshot(self):
        self.paths["status"].write_text(json.dumps({
            "generated_at": "2000-01-01T00:00:00Z",
            "circuit_breaker": {
                "status": "PASS",
                "global_stop": False,
                "spend": {"weekly": 0, "cap": 20},
                "depth": {"current": 0, "max": 3},
            },
            "workers": [],
            "cron_jobs": [],
        }), encoding="utf-8")
        self.paths["stop"].write_text("stopped", encoding="utf-8")
        status = mission_control.status_payload()
        self.assertTrue(status["circuit_breaker"]["global_stop"])
        self.assertEqual(status["circuit_breaker"]["status"], "TRIPPED")
        self.assertTrue(status["snapshot_stale"])

        self.paths["stop"].unlink()
        stale_snapshot = json.loads(self.paths["status"].read_text())
        stale_snapshot["circuit_breaker"]["global_stop"] = True
        stale_snapshot["circuit_breaker"]["status"] = "TRIPPED"
        self.paths["status"].write_text(json.dumps(stale_snapshot), encoding="utf-8")
        status = mission_control.status_payload()
        self.assertFalse(status["circuit_breaker"]["global_stop"])
        self.assertEqual(status["circuit_breaker"]["status"], "PASS")

    def test_global_stop_events_require_successful_state_change(self):
        code, response = mission_control.global_stop_control(json.dumps({
            "action": "engage", "reason": "First edge",
        }).encode())
        self.assertEqual((code, response["idempotent"]), (200, False))
        first_events = mission_control.read_events(20)
        self.assertEqual(
            [event["event"] for event in first_events].count("stop"), 1
        )

        code, response = mission_control.global_stop_control(json.dumps({
            "action": "engage", "reason": "Already stopped",
        }).encode())
        self.assertEqual((code, response["idempotent"]), (200, True))
        self.assertEqual(
            [event["event"] for event in mission_control.read_events(20)].count(
                "stop"
            ),
            1,
        )

        failed = subprocess.CompletedProcess([], 1, stdout="", stderr="write failed")
        self.paths["stop"].unlink()
        with mock.patch.object(
            mission_control.subprocess, "run", return_value=failed
        ):
            code, response = mission_control.global_stop_control(json.dumps({
                "action": "engage", "reason": "Must not be logged",
            }).encode())
        self.assertEqual(code, 500)
        self.assertIn("write failed", response["error"])
        self.assertEqual(
            [event["detail"] for event in mission_control.read_events(20)],
            ["First edge"],
        )

    def test_global_stop_subprocess_errors_are_controlled(self):
        with mock.patch.object(
            mission_control.subprocess,
            "run",
            side_effect=subprocess.TimeoutExpired(["bash"], 10),
        ):
            code, response = mission_control.global_stop_control(json.dumps({
                "action": "engage",
            }).encode())
        self.assertEqual(code, 500)
        self.assertIn("failed", response["error"])


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

    def test_request_and_decision_field_limits_fail_closed(self):
        oversized_request = self.run_script(
            "request",
            "--id", "release-oversized",
            "--title", "x" * 161,
            "--summary", "Must not create state",
        )
        self.assertEqual(oversized_request.returncode, 3)
        self.assertIn("field 'title'", oversized_request.stderr)
        self.assertFalse((self.deployments / "release-oversized.json").exists())

        created = self.run_script(
            "request",
            "--id", "release-reason-limit",
            "--title", "Reason limit",
            "--summary", "Must reject an oversized decision",
        )
        self.assertEqual(created.returncode, 0, created.stderr)
        oversized_decision = self.run_script(
            "decide",
            "--id", "release-reason-limit",
            "--decision", "deny",
            "--reason", "x" * 2001,
        )
        self.assertEqual(oversized_decision.returncode, 3)
        self.assertIn("field 'reason'", oversized_decision.stderr)
        self.assertFalse(
            (self.approvals / "release-reason-limit.json").exists()
        )

    def test_list_uses_shared_id_and_record_validation(self):
        created = self.run_script(
            "request",
            "--id", "release-valid",
            "--title", "Valid pending request",
            "--summary", "This request should be listed",
        )
        self.assertEqual(created.returncode, 0, created.stderr)
        self.deployments.joinpath("release:legacy.json").write_text(
            json.dumps({
                "id": "release:legacy",
                "title": "Legacy ID",
                "summary": "Must not be listed",
            }),
            encoding="utf-8",
        )
        self.deployments.joinpath("mismatched.json").write_text(
            json.dumps({
                "id": "different",
                "title": "Mismatched ID",
                "summary": "Must not be listed",
            }),
            encoding="utf-8",
        )

        listed = self.run_script("list")
        self.assertEqual(listed.returncode, 0, listed.stderr)
        self.assertEqual(
            [item["id"] for item in json.loads(listed.stdout)],
            ["release-valid"],
        )

    def test_notify_missing_request_returns_documented_invalid_state(self):
        notified = self.run_script("notify", "--id", "release-missing")
        self.assertEqual(notified.returncode, 3)
        self.assertIn("request not found", notified.stderr)

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
