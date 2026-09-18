"""Kimi Code writes into Claude's transcripts, so only the model id separates them.

Kimi speaks the Anthropic API. Run through Claude Code it lands in
~/.claude/projects/**/*.jsonl exactly like Claude's own turns, and before this
split its spend was counted as Claude's — the one number that says how close
the wall is.
"""
import json
import os
import subprocess
import sys
import tempfile
import time
import unittest
from pathlib import Path

REPO = Path(__file__).resolve().parents[1]
COLLECT = REPO / "bin" / "burnbar-collect"


def turn(ts_ms, model, output_tokens):
    return json.dumps({
        "timestamp": time.strftime("%Y-%m-%dT%H:%M:%S", time.gmtime(ts_ms / 1000)) + ".000Z",
        "message": {"id": f"msg_{model}_{output_tokens}", "model": model,
                    "usage": {"input_tokens": 10, "cache_creation_input_tokens": 0,
                              "output_tokens": output_tokens, "cache_read_input_tokens": 0}},
    })


class KimiSplitTests(unittest.TestCase):
    def collect(self, transcript_lines):
        """Run the real collector against a throwaway HOME and return its payload."""
        tmp = tempfile.mkdtemp()
        home = Path(tmp) / "home"
        proj = home / ".claude" / "projects" / "sandbox"
        proj.mkdir(parents=True)
        (proj / "session.jsonl").write_text("\n".join(transcript_lines) + "\n")
        env = dict(os.environ,
                   HOME=str(home),
                   XDG_STATE_HOME=str(Path(tmp) / "state"),
                   XDG_CACHE_HOME=str(Path(tmp) / "cache"))
        # No key here: the plan probe must not reach the network from a test.
        env.pop("KIMI_API_KEY", None)
        subprocess.run([sys.executable, str(COLLECT), "--no-local"],
                       env=env, check=True, timeout=120,
                       stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        out = Path(tmp) / "state" / "omarchy" / "burnbar" / "history.json"
        return json.loads(out.read_text())

    def test_a_kimi_turn_is_not_billed_to_claude(self):
        now = time.time() * 1000
        d = self.collect([turn(now - 60_000, "claude-opus-5", 100),
                          turn(now - 50_000, "kimi-k2-turbo-preview", 700)])
        self.assertEqual(d["claude"]["total"], 110, "claude keeps only its own turn")
        self.assertEqual(d["kimi"]["total"], 710, "kimi's turn lands in kimi")
        self.assertTrue(d["presence"]["kimi"])
        self.assertEqual(d["kimi"]["byModel"], {"kimi-k2-turbo-preview": 710})

    def test_a_machine_that_never_ran_kimi_shows_no_kimi_lane(self):
        now = time.time() * 1000
        d = self.collect([turn(now - 60_000, "claude-opus-5", 100)])
        self.assertFalse(d["presence"]["kimi"], "no Kimi turn means no Kimi lane")
        self.assertEqual(d["kimi"]["total"], 0)
        self.assertEqual(d["claude"]["total"], 110, "claude is untouched by the split")

    def test_kimi_gets_its_own_bucket_column(self):
        now = time.time() * 1000
        d = self.collect([turn(now - 60_000, "kimi-k2-turbo-preview", 700)])
        self.assertIn("kimi", d["buckets"][0])
        self.assertEqual(sum(b["kimi"] for b in d["buckets"]), 710)
        self.assertEqual(sum(b["claude"] for b in d["buckets"]), 0)

    def test_no_quota_is_claimed_for_kimi(self):
        """Kimi answers 404 on every usage endpoint and sends no rate-limit
        headers, so an empty limits list is the honest answer."""
        now = time.time() * 1000
        d = self.collect([turn(now - 60_000, "kimi-k2-turbo-preview", 700)])
        self.assertEqual(d["kimi"]["limits"], [])
        self.assertFalse(d["kimi"]["limitsLive"])
        self.assertIn("no quota", d["kimi"]["limitsStatus"])

    def test_moonshot_ids_count_as_kimi_too(self):
        now = time.time() * 1000
        d = self.collect([turn(now - 60_000, "moonshot-v1-128k", 300)])
        self.assertEqual(d["kimi"]["total"], 310)
        self.assertEqual(d["claude"]["total"], 0)


if __name__ == "__main__":
    unittest.main()
