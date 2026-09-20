"""Grok: an absent figure is unknown, never zero.

Both cases came out of an outside review (Grok 4.6 and Kimi k3 agreed on the
first one, 2026-09-20). Neither was biting on the machine it was found on, which
is exactly why they need a test: nothing else would ever have noticed.
"""
import ast
import json
import tempfile
import unittest
from pathlib import Path

REPO = Path(__file__).resolve().parents[1]


def load(**extra):
    tree = ast.parse((REPO / "bin" / "burnbar-collect").read_text())
    want_fn = {"grok_limits_from_log", "grok_points_from_updates", "parse_ts", "norm_percent", "count"}
    want_const = {"MAX_TOKENS", "MALFORMED"}
    body = [n for n in tree.body
            if isinstance(n, (ast.Import, ast.ImportFrom))
            or (isinstance(n, ast.FunctionDef) and n.name in want_fn)
            or (isinstance(n, ast.Assign) and getattr(n.targets[0], "id", "") in want_const)]
    ns = {"prune": lambda pts: pts, "grok_model_for": lambda path: "grok"}
    ns.update(extra)
    exec(compile(ast.Module(body=body, type_ignores=[]), "<grok>", "exec"), ns)
    return ns


def log_with(config):
    tmp = Path(tempfile.mkdtemp()) / "unified.jsonl"
    tmp.write_text(json.dumps({"ts": "2026-09-20T12:00:00Z", "msg": "billing: fetched credits config",
                               "ctx": {"config": config}}) + "\n")
    return tmp


class GrokUnknownTests(unittest.TestCase):
    def test_a_billing_config_with_no_usage_figure_is_unknown_not_zero_percent(self):
        path = log_with({"currentPeriod": {"end": "2026-09-27T00:00:00Z"}})
        limits, _, _ = load(GROK_LOG=path)["grok_limits_from_log"]()
        self.assertEqual(limits[0]["percent"], -1.0)

    def test_a_real_zero_is_still_zero(self):
        path = log_with({"creditUsagePercent": 0, "currentPeriod": {"end": "2026-09-27T00:00:00Z"}})
        limits, _, _ = load(GROK_LOG=path)["grok_limits_from_log"]()
        self.assertEqual(limits[0]["percent"], 0.0)

    def test_the_percentage_is_read_on_groks_own_scale(self):
        path = log_with({"creditUsagePercent": 37, "currentPeriod": {"end": "2026-09-27T00:00:00Z"}})
        limits, _, _ = load(GROK_LOG=path)["grok_limits_from_log"]()
        self.assertAlmostEqual(limits[0]["percent"], 0.37, places=6)

    def test_a_record_with_no_token_total_does_not_bill_the_whole_context(self):
        # Burn for a prompt is max(totalTokens) - min(totalTokens). A record that
        # carries the promptId but no total used to read as 0, dragging the
        # minimum to 0 and billing the entire context instead of the growth.
        rows = [
            {"params": {"_meta": {"promptId": "p1", "turnStartMs": 1_789_900_000_000, "totalTokens": 50_000}}},
            {"params": {"_meta": {"promptId": "p1", "turnStartMs": 1_789_900_001_000}}},
            {"params": {"_meta": {"promptId": "p1", "turnStartMs": 1_789_900_002_000, "totalTokens": None}}},
            {"params": {"_meta": {"promptId": "p1", "turnStartMs": 1_789_900_003_000, "totalTokens": 52_500}}},
        ]
        tmp = Path(tempfile.mkdtemp()) / "updates.jsonl"
        tmp.write_text("\n".join(json.dumps(r) for r in rows) + "\n")
        points = load()["grok_points_from_updates"](tmp)
        self.assertEqual(len(points), 1)
        self.assertEqual(points[0][1], 2_500)


if __name__ == "__main__":
    unittest.main()
