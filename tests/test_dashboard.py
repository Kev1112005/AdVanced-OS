import pathlib
import subprocess
import unittest


ROOT = pathlib.Path(__file__).resolve().parents[1]
DASHBOARD = ROOT / "public" / "index.html"


class DashboardTruthTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.source = DASHBOARD.read_text(encoding="utf-8")
        cls.script = cls.source.split("  <script>\n", 1)[1].split(
            "\n  </script>", 1
        )[0]

    def test_inline_javascript_has_valid_syntax(self):
        checked = subprocess.run(
            ["node", "--check"],
            input=self.script,
            capture_output=True,
            text=True,
            timeout=5,
        )
        self.assertEqual(checked.returncode, 0, checked.stderr)

    def test_demo_mode_is_explicit_and_never_inferred_from_live_failures(self):
        self.assertIn("const EXPLICIT_DEMO =", self.script)
        self.assertIn("demo:EXPLICIT_DEMO", self.script)
        self.assertNotIn("registry.demo_recommended", self.script)
        self.assertNotRegex(self.script, r"state\.demo\s*=")
        self.assertIn("DEGRADED ·", self.script)
        self.assertIn("No trusted status snapshot", self.script)
        self.assertIn("Demo mode is read-only; no live action was sent", self.script)
        self.assertIn("if (!state.demo) return true;", self.script)
        self.assertIn("$('#sealBtn').disabled = state.demo;", self.script)

    def test_partial_refreshes_are_independent_bounded_and_preserve_last_known_slices(self):
        self.assertIn("refreshGeneration", self.script)
        self.assertIn("state.refreshController.abort()", self.script)
        self.assertIn("const SLICE_TIMEOUT_MS = 4000;", self.script)
        self.assertIn("const controller = new AbortController();", self.script)
        self.assertIn("timedOut ? 'request timed out'", self.script)
        self.assertIn("function applySliceResult(result, generation)", self.script)
        self.assertIn("applySliceResult(result, generation);", self.script)
        self.assertIn("requestRender();", self.script)
        self.assertIn(
            "if (generation !== state.refreshGeneration) return;", self.script
        )
        self.assertIn(
            "state.slices[result.name] = {...previous, attempted:true, ok:false",
            self.script,
        )
        self.assertNotIn(
            "state.orders = Array.isArray(orders) ? orders : []", self.script
        )
        self.assertIn("[STALE · live capture unavailable]", self.script)
        self.assertIn("generation !== state.liveGeneration", self.script)

    def test_ticket_and_qa_reviews_expose_complete_bounded_evidence(self):
        self.assertIn('id="ticketReviewModal"', self.source)
        self.assertIn('id="ticketReviewResult"', self.source)
        self.assertIn("ticket.results ||", self.script)
        self.assertIn("Inspect full QA evidence", self.source)
        self.assertIn("check.detail || 'No detail recorded'", self.script)
        self.assertIn("Captured report", self.script)
        self.assertIn("function reconcileTicketReview(tickets)", self.script)
        self.assertIn("ticketSignature(current) !== state.reviewTicketSignature", self.script)
        self.assertIn("ticket?.review_version", self.script)
        self.assertIn("function validReviewVersion(value)", self.script)
        self.assertIn("review_version:ticket.review_version", self.script)
        self.assertIn("if (result.status === 409)", self.script)
        self.assertNotIn(
            "onclick=\"reviewTicket(", self.source
        )
        review_dialog = self.source.split(
            '<dialog id="ticketReviewModal"', 1
        )[1].split("</dialog>", 1)[0]
        self.assertIn("Accept Result", review_dialog)
        self.assertIn(">Block</button>", review_dialog)

    def test_dynamic_action_ids_use_validated_data_attributes(self):
        self.assertIn('data-dashboard-action="cancel-order"', self.source)
        self.assertIn('data-dashboard-action="review-ticket"', self.source)
        self.assertIn(
            'data-dashboard-action="review-deployment"', self.source
        )
        self.assertIn("validActionId(id)", self.script)
        self.assertNotRegex(
            self.source,
            r'onclick="[^"]*\$\{',
        )
        self.assertNotRegex(
            self.source,
            r'onclick="(?:cancelOrder|decideDeployment|reviewTicket)\(',
        )

    def test_global_stop_release_depends_only_on_known_global_stop(self):
        toggle = self.script.split(
            "async function toggleGlobalStop()", 1
        )[1].split("function ask(", 1)[0]
        self.assertIn("const stop = globalStopState();", toggle)
        self.assertIn("const stopped = stop.known && stop.value;", toggle)
        self.assertNotIn("TRIPPED", toggle)
        self.assertIn("globalStopOverride", self.script)
        stop_state = self.script.split(
            "function globalStopState()", 1
        )[1].split("function setControlFeedback(", 1)[0]
        self.assertIn("state.slices.status?.ok", stop_state)
        self.assertIn("circuit?.global_stop_valid === true", stop_state)
        self.assertNotIn("snapshotStale()", stop_state)
        self.assertIn(
            "state.globalStopOverride?.value ?? circuit?.global_stop",
            stop_state,
        )
        status_setter = self.script.split(
            "['status','/api/status'", 1
        )[1].split("['orders','/api/dispatch/pending'", 1)[0]
        self.assertIn("state.globalStopOverride = null;", status_setter)
        self.assertNotIn("Date.parse(value.generated_at", status_setter)
        self.assertIn("Emergency seal action failed:", self.script)

    def test_order_form_has_truthful_fixed_controls_and_accessible_dialogs(self):
        self.assertNotIn('id="orderModel"', self.source)
        self.assertNotIn('id="orderApproval"', self.source)
        self.assertIn("Fixed safety policy:", self.source)
        self.assertIn("Only the typed QA fields below are enforced", self.source)
        self.assertIn(
            'aria-labelledby="orderModalTitle" aria-describedby="orderModalDesc"',
            self.source,
        )
        self.assertIn(
            'aria-labelledby="ticketReviewTitle" '
            'aria-describedby="ticketReviewIntro"',
            self.source,
        )
        self.assertIn(
            'aria-labelledby="deploymentReviewTitle" '
            'aria-describedby="deploymentReviewIntro"',
            self.source,
        )
        self.assertIn('aria-label="Cancel queued order ${esc(', self.source)
        self.assertIn("function restoreFocus(", self.script)
        self.assertIn("restoreFocus(restore, '#phase-five')", self.script)
        self.assertIn("Mission Control is a desktop control surface.", self.source)

    def test_recent_order_agent_and_submit_regressions_remain_fixed(self):
        self.assertIn('onsubmit="submitOrder(event)"', self.source)
        self.assertIn('id="submitOrderBtn"', self.source)
        self.assertNotIn('id="submitOrder"', self.source)
        self.assertIn(
            "const orderSelection = $('#orderModal').open ? "
            "orderSelect.value : '';",
            self.script,
        )
        self.assertIn("function registeredAgents()", self.script)
        self.assertIn("const canIssueOrder = !state.demo && agents.length > 0;", self.script)
        self.assertIn("if (!canIssueOrder && $('#orderModal').open) closeOrderModal();", self.script)
        self.assertIn("$('#issueTop').disabled = !canIssueOrder;", self.script)
        self.assertIn("$('#issueOrderPanel').disabled = !canIssueOrder;", self.script)
        self.assertIn("$('#submitOrderBtn').disabled = !canIssueOrder;", self.script)
        open_modal = self.script.split(
            "function openOrderModal()", 1
        )[1].split("function closeOrderModal()", 1)[0]
        self.assertIn("if (!registeredAgents().length)", open_modal)
        submit = self.script.split(
            "async function submitOrder(event)", 1
        )[1].split("async function cancelOrder(", 1)[0]
        self.assertIn("if (!selected)", submit)
        self.assertIn("registeredAgents().length === 0", submit)

    def test_unchanged_lists_preserve_nodes_focus_and_disclosure_state(self):
        self.assertIn("function replaceHTML(key, element, signature, html)", self.script)
        self.assertIn("if (state.renderKeys[key] === signature) return false;", self.script)
        for key in (
            "orders", "events", "providers", "deployments",
            "qa-runs", "tickets", "learnings",
        ):
            self.assertRegex(self.script, rf"replaceHTML\(\s*'{key}'")

    def test_vox_is_single_flight_and_agent_controls_fail_closed(self):
        self.assertIn("if (!allowLiveMutation() || state.voxSending) return;", self.script)
        self.assertIn("state.voxSending = true;", self.script)
        self.assertIn("state.voxSending = false;", self.script)
        self.assertIn("$('#liveName').textContent = 'No agent';", self.script)
        self.assertIn("$('#agentSelect').disabled = true;", self.script)
        self.assertIn('id="interruptAgent"', self.source)
        self.assertIn("Unavailable until cooperative halt is implemented", self.source)
        self.assertNotIn("confirmAgentAction('interrupt')", self.source)

    def test_deployment_decisions_require_complete_current_review(self):
        dialog = self.source.split(
            '<dialog id="deploymentReviewModal"', 1
        )[1].split("</dialog>", 1)[0]
        for field in ("Repository", "Ref", "Requested by", "Summary", "Checks", "Rollback"):
            self.assertIn(field, dialog)
        self.assertIn("function reconcileDeploymentReview(deployments)", self.script)
        self.assertIn("deploymentSignature(current) !== state.reviewDeploymentSignature", self.script)
        self.assertIn("if (!state.slices.deployments?.ok)", self.script)
        self.assertIn("Deployment state is unavailable.", self.script)
        deployment_slice = self.script.split(
            "['deployments','/api/deployments'", 1
        )[1].split("['taskRuns','/api/task-runs", 1)[0]
        self.assertIn("Array.isArray(value.deployments)", deployment_slice)
        self.assertIn("typeof value.degraded === 'boolean'", deployment_slice)
        self.assertIn("Array.isArray(value.errors)", deployment_slice)
        self.assertIn("state.deployments = value.deployments;", deployment_slice)
        self.assertNotIn("Array.isArray, value =>", deployment_slice)
        self.assertIn(
            "result.name === 'deployments' && result.value.degraded",
            self.script,
        )
        self.assertIn("ok:false", self.script)


if __name__ == "__main__":
    unittest.main()
