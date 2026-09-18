"""A withheld plan limit must say what to do, not only what is wrong.

The usage record already carries the remedy (`authHelpText`, e.g. "Run
`claude auth login` ..."). Burn Bar showed only `usageStatusText`, so a lapsed
login rendered a blank row with no way to act on it.
"""
import ast
import json
import tempfile
import unittest
from pathlib import Path

REPO = Path(__file__).resolve().parents[1]
SRC = (REPO / "bin" / "burnbar-collect").read_text()


class LimitsHelpTests(unittest.TestCase):
    def test_limits_help_is_read_from_the_record(self):
        tree = ast.parse(SRC)
        fn = next((n for n in tree.body
                   if isinstance(n, ast.FunctionDef) and n.name == "limits_help"), None)
        self.assertIsNotNone(fn, "limits_help() should exist")
        with tempfile.TemporaryDirectory() as tmp:
            usage = Path(tmp)
            (usage / "claude.json").write_text(json.dumps(
                {"authHelpText": "Run `claude auth login` to restore authoritative usage."}))
            ns = {"json": json, "USAGE_DIR": usage}
            exec(compile(ast.Module(body=[fn], type_ignores=[]), "<h>", "exec"), ns)
            self.assertIn("claude auth login", ns["limits_help"]("claude"))

    def test_a_missing_or_broken_record_yields_an_empty_string(self):
        tree = ast.parse(SRC)
        fn = next(n for n in tree.body
                  if isinstance(n, ast.FunctionDef) and n.name == "limits_help")
        with tempfile.TemporaryDirectory() as tmp:
            usage = Path(tmp)
            (usage / "broken.json").write_text("{ not json")
            (usage / "list.json").write_text("[]")
            ns = {"json": json, "USAGE_DIR": usage}
            exec(compile(ast.Module(body=[fn], type_ignores=[]), "<h>", "exec"), ns)
            for agent in ("absent", "broken", "list"):
                self.assertEqual(ns["limits_help"](agent), "")

    def test_limits_for_still_returns_three_values(self):
        """pick_limits and grok_limits_from_log both unpack three. Widening
        limits_for broke the Grok path once; keep that shape pinned."""
        for name in ("limits_for", "grok_limits_from_log"):
            fn = next(n for n in ast.parse(SRC).body
                      if isinstance(n, ast.FunctionDef) and n.name == name)
            returns = [n for n in ast.walk(fn)
                       if isinstance(n, ast.Return) and isinstance(n.value, ast.Tuple)]
            self.assertTrue(returns, name + " should return tuples")
            for r in returns:
                self.assertEqual(len(r.value.elts), 3,
                                 name + " must keep returning three values")

    def test_every_agent_payload_sets_limits_help(self):
        self.assertEqual(SRC.count('agent_payload["limitsHelp"]'), 4,
                         "claude/codex, grok-unavailable, grok-chosen and kimi")


if __name__ == "__main__":
    unittest.main()
