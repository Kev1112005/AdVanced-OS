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

    def test_partial_refreshes_preserve_last_known_slices(self):
        self.assertIn("refreshGeneration", self.script)
        self.assertIn("state.refreshController.abort()", self.script)
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
            'data-dashboard-action="deployment-decision"', self.source
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
        )[1].split("async function decideDeployment", 1)[0]
        self.assertIn("const stop = globalStopState();", toggle)
        self.assertIn("const stopped = stop.known && stop.value;", toggle)
        self.assertNotIn("TRIPPED", toggle)
        self.assertIn("globalStopOverride", self.script)
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
        self.assertIn('aria-label="Cancel queued order ${esc(', self.source)
        self.assertIn("function restoreFocus(", self.script)
        self.assertIn("restoreFocus(restore, '#phase-five')", self.script)

    def test_recent_order_agent_and_submit_regressions_remain_fixed(self):
        self.assertIn('onsubmit="submitOrder(event)"', self.source)
        self.assertIn('id="submitOrderBtn"', self.source)
        self.assertNotIn('id="submitOrder"', self.source)
        self.assertIn(
            "const orderSelection = $('#orderModal').open ? "
            "orderSelect.value : '';",
            self.script,
        )


if __name__ == "__main__":
    unittest.main()
