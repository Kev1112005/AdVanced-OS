import os
import pathlib
import subprocess
import tempfile
import unittest


ROOT = pathlib.Path(__file__).resolve().parents[1]
SETUP = ROOT / "scripts" / "phase5-setup.sh"


class Phase5SetupTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.base = pathlib.Path(self.temp.name)
        self.script_dir = self.base / "runtime-scripts"
        self.config_dir = self.base / "runtime-config"
        self.script_dir.mkdir()
        self.config_dir.mkdir()
        self.env = {
            **os.environ,
            "HOME": str(self.base / "home"),
            "HERMES_SCRIPT_DIR": str(self.script_dir),
            "HERMES_CONFIG_DIR": str(self.config_dir),
            "HERMES_TICKET_DIR": str(self.base / "tickets"),
            "HERMES_TICKET_LOCK": str(self.base / "tickets.lock"),
            "HERMES_LEARNINGS_FILE": str(self.base / "learnings.md"),
            "MISSION_CONTROL_PORT": "1",
        }

    def tearDown(self):
        self.temp.cleanup()

    def run_setup(self, command, *, check=True):
        return subprocess.run(
            ["bash", str(SETUP), command],
            cwd=ROOT,
            env=self.env,
            text=True,
            capture_output=True,
            timeout=20,
            check=check,
        )

    def test_install_preflights_all_targets_before_first_mutation(self):
        conflict = self.script_dir / "ticket-scan.sh"
        conflict.write_text("operator-owned\n", encoding="utf-8")
        result = self.run_setup("install", check=False)
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(conflict.read_text(encoding="utf-8"), "operator-owned\n")
        self.assertEqual(list(self.script_dir.iterdir()), [conflict])
        self.assertEqual(list(self.config_dir.iterdir()), [])

    def test_status_reports_exact_config_link(self):
        self.run_setup("install")
        result = self.run_setup("status", check=False)
        config_target = self.config_dir / "circuit-breaker.yaml"
        self.assertTrue(config_target.is_symlink())
        self.assertEqual(
            config_target.resolve(),
            ROOT / "config" / "circuit-breaker.yaml",
        )
        self.assertIn(f"ok      {config_target}", result.stdout)


if __name__ == "__main__":
    unittest.main()
