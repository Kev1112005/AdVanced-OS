import json
import os
import pathlib
import subprocess
import tempfile
import time
import unittest


ROOT = pathlib.Path(__file__).resolve().parents[1]
PIPELINE_INIT = ROOT / "scripts" / "pipeline-init.sh"
PIPELINE_ADVANCE = ROOT / "scripts" / "pipeline-advance.sh"
LANE = ROOT / "scripts" / "dispatch-lane.sh"


class PipelineSafetyTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.base = pathlib.Path(self.temp.name)
        self.home = self.base / "home"
        self.home.mkdir()
        self.requests = self.base / "requests"
        self.pipelines = self.base / "pipelines"
        self.fake_log = self.base / "tmux.log"
        self.bin = self.base / "bin"
        self.bin.mkdir()
        tmux = self.bin / "tmux"
        tmux.write_text(
            "#!/usr/bin/env bash\n"
            'printf "%s\\n" "$*" >> "$FAKE_TMUX_LOG"\n'
            '[[ "${1:-}" == capture-pane ]] && printf "completed report\\n❯\\n"\n'
            "exit 0\n",
            encoding="utf-8",
        )
        tmux.chmod(0o755)
        self.env = {
            **os.environ,
            "HOME": str(self.home),
            "PATH": f"{self.bin}:{os.environ['PATH']}",
            "HERMES_REQUESTS_DIR": str(self.requests),
            "HERMES_PIPELINE_DIR": str(self.pipelines),
            "HERMES_DISPATCH_LANE_FILE": str(self.base / "lane.json"),
            "HERMES_DISPATCH_LANE_LOCK": str(self.base / "lane.lock"),
            "HERMES_EVENT_LOG": str(self.base / "events.log"),
            "HERMES_ALERT_STATE": str(self.base / "alerts"),
            "HERMES_PIPELINE_MIN_WORK": "0",
            "HERMES_PIPELINE_CAPTURE_DELAY": "0",
            "FAKE_TMUX_LOG": str(self.fake_log),
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
            timeout=20,
            check=check,
        )

    def initialize_delivered_research(self):
        pipeline_id = self.run_cmd(
            "bash", str(PIPELINE_INIT), "Safety", "Inspect the pipeline"
        ).stdout.strip()
        pipeline = self.pipelines / pipeline_id
        request_id = f"{pipeline_id}-research"
        request = self.requests / f"{request_id}.json"
        self.run_cmd("bash", str(LANE), "acquire", "--request-file", str(request))
        self.run_cmd(
            "bash", str(LANE), "transition", "--request-id", request_id,
            "--status", "active",
        )
        request.unlink()
        research = pipeline / "research"
        (research / "sent_at").write_text(
            "2026-07-24T00:00:00Z\n", encoding="utf-8"
        )
        return pipeline_id, pipeline

    def test_pipeline_uses_stable_stage_ids_and_concurrent_advance_is_single(self):
        pipeline_id, pipeline = self.initialize_delivered_research()
        processes = [
            subprocess.Popen(
                ["bash", str(PIPELINE_ADVANCE)],
                cwd=ROOT,
                env=self.env,
                stdout=subprocess.PIPE,
                stderr=subprocess.PIPE,
                text=True,
            )
            for _ in range(2)
        ]
        for process in processes:
            process.communicate(timeout=20)
            self.assertEqual(process.returncode, 0)
        self.assertEqual((pipeline / "state").read_text().strip(), "scaffolding")
        requests = list(self.requests.glob("*.json"))
        self.assertEqual([path.name for path in requests], [f"{pipeline_id}-scaffold.json"])
        payload = json.loads(requests[0].read_text(encoding="utf-8"))
        self.assertEqual(payload["request_id"], f"{pipeline_id}-scaffold")
        self.assertFalse(pathlib.Path(self.env["HERMES_DISPATCH_LANE_FILE"]).exists())

    def test_publish_failure_recovers_from_transitioned_state(self):
        pipeline_id, pipeline = self.initialize_delivered_research()
        self.requests.rmdir()
        self.requests.write_text("temporarily unavailable", encoding="utf-8")
        first = self.run_cmd("bash", str(PIPELINE_ADVANCE), check=False)
        self.assertEqual((pipeline / "state").read_text().strip(), "scaffolding")
        self.assertEqual(first.returncode, 0)
        self.assertFalse((self.base / f"{pipeline_id}-scaffold.json").exists())

        self.requests.unlink()
        self.requests.mkdir()
        self.run_cmd("bash", str(PIPELINE_ADVANCE))
        expected = self.requests / f"{pipeline_id}-scaffold.json"
        self.assertTrue(expected.exists())
        self.assertEqual(len(list(self.requests.glob("*.json"))), 1)


if __name__ == "__main__":
    unittest.main()
