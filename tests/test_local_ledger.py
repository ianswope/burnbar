"""Local work that never reaches Ollama's journal still counts as offloaded.

On gus the fast hooks moved from Ollama to local-ai (TabbyAPI) and recall
embeddings moved to the NPU. Neither writes a journal line, so the offload share
fell while more work ran locally. Their callers now append one line per request
to local-usage.jsonl, and the collector adds those points to the local lane.
"""
import json
import os
import subprocess
import tempfile
import unittest
from pathlib import Path

REPO = Path(__file__).resolve().parents[1]
NOW_MS = 1_789_300_000_000


def record(**fields):
    return json.dumps(fields) + "\n"


class LocalLedgerTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.home = Path(self.tmp.name)
        self.state = self.home / "state"
        self.ledger = self.state / "omarchy" / "burnbar" / "local-usage.jsonl"
        self.ledger.parent.mkdir(parents=True)

    def tearDown(self):
        self.tmp.cleanup()

    def collect(self):
        env = dict(os.environ, HOME=str(self.home), XDG_STATE_HOME=str(self.state),
                   XDG_CACHE_HOME=str(self.home / "cache"), GROK_HOME=str(self.home / ".grok"),
                   BURNBAR_NOW_MS=str(NOW_MS), BURNBAR_NO_LOCAL="1")
        env.pop("BURNBAR_LOCAL_LEDGER", None)
        subprocess.run(["python3", str(REPO / "bin" / "burnbar-collect"), "--window", "360"],
                       env=env, check=True, capture_output=True, timeout=30)
        return json.loads((self.state / "omarchy" / "burnbar" / "history.json").read_text())

    def test_local_ai_and_npu_lines_count_and_junk_is_skipped(self):
        self.ledger.write_text(
            record(ts=NOW_MS - 60_000, source="local-ai", model="Qwen3.5-9B", prompt=800, output=64, estimated=True)
            + record(ts=NOW_MS - 30_000, source="npu", model="nomic-embed-text-v1.5", prompt=12, output=0)
            + "not json\n"
            + "[1, 2]\n"
            + record(ts="soon", source="npu", prompt=5, output=0)
            + record(ts=NOW_MS, source="npu", prompt=-5, output=1)
            + record(ts=NOW_MS, prompt=5, output=5)
            + record(ts=NOW_MS, source="npu", prompt=True, output=0)
            + record(ts=NOW_MS - 7 * 3600_000, source="local-ai", model="old", prompt=999, output=1)
            + '{"ts": %d, "source": "npu", "prompt": 70' % NOW_MS)   # half-written, no newline
        data = self.collect()
        local = data["local"]
        self.assertEqual(local["total"], 876)
        self.assertEqual(local["byModel"], {"local-ai:Qwen3.5-9B": 864, "npu:nomic-embed-text-v1.5": 12})
        self.assertEqual(local["split"]["input"], 812)
        self.assertEqual(local["split"]["output"], 64)
        self.assertEqual(data["offloadShare"], 1)

    def test_appended_lines_are_picked_up_on_the_next_run(self):
        self.ledger.write_text(record(ts=NOW_MS - 60_000, source="npu", model="m", prompt=10, output=0))
        self.assertEqual(self.collect()["local"]["total"], 10)
        with self.ledger.open("a") as fh:
            fh.write(record(ts=NOW_MS - 1_000, source="local-ai", model="q", prompt=20, output=5))
        self.assertEqual(self.collect()["local"]["total"], 35)

    def test_no_ledger_is_zero_not_a_crash(self):
        self.assertEqual(self.collect()["local"]["total"], 0)


if __name__ == "__main__":
    unittest.main()
