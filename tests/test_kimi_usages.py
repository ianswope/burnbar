"""Kimi's real quota comes from GET /usages — plural.

/usage is a 404, which is how this was first written off as unavailable. The
payload carries two different measures of the same five-hour span: a request
window that actually cuts you off, and a credit ratio. Only one of them should
reach the panel.
"""
import ast
import unittest
from pathlib import Path

REPO = Path(__file__).resolve().parents[1]
SRC = (REPO / "bin" / "burnbar-collect").read_text()


def load(*names):
    tree = ast.parse(SRC)
    ns = {}
    for n in tree.body:
        if isinstance(n, ast.FunctionDef) and n.name in names:
            exec(compile(ast.Module(body=[n], type_ignores=[]), "<u>", "exec"), ns)
    return ns


LIVE = {
    "limits": [{"window": {"duration": 300, "timeUnit": "TIME_UNIT_MINUTE"},
                "detail": {"limit": "100", "used": "8", "remaining": "92",
                           "resetTime": "2026-09-19T02:43:48.125750Z"}}],
    "usages": {"limit_5h": {"used_ratio": 0, "reset_time": "2026-09-19T02:43:47Z"},
               "limit_month_total": {"used_ratio": 0.0025, "reset_time": "2026-10-19T00:00:00Z"},
               "limit_month_code": {"used_ratio": 0, "reset_time": "2026-10-19T00:00:00Z"}}}


class KimiUsagesTests(unittest.TestCase):
    def setUp(self):
        self.ns = load("kimi_limits_from_usages", "kimi_window_label")
        self.parse = self.ns["kimi_limits_from_usages"]

    def test_the_real_payload_becomes_three_rows(self):
        rows = self.parse(LIVE)
        self.assertEqual([r["label"] for r in rows],
                         ["Session (5-hour)", "Monthly (total)", "Monthly (code)"])

    def test_the_request_window_wins_the_five_hour_row(self):
        """8 of 100 requests is the binding figure; the 0% credit ratio for the
        same span must not be printed as a second 5-hour row."""
        rows = self.parse(LIVE)
        five = [r for r in rows if "5-hour" in r["label"]]
        self.assertEqual(len(five), 1, "exactly one five-hour row")
        self.assertAlmostEqual(five[0]["percent"], 0.08)
        self.assertTrue(five[0]["resetsAt"].startswith("2026-09-19T02:43:48"))

    def test_monthly_credit_ratio_is_carried_through(self):
        rows = {r["label"]: r for r in self.parse(LIVE)}
        self.assertAlmostEqual(rows["Monthly (total)"]["percent"], 0.0025)
        self.assertEqual(rows["Monthly (total)"]["resetsAt"], "2026-10-19T00:00:00Z")

    def test_minutes_fold_into_hours(self):
        label = self.ns["kimi_window_label"]
        self.assertEqual(label({"duration": 300, "timeUnit": "TIME_UNIT_MINUTE"}), "5-hour")
        self.assertEqual(label({"duration": 90, "timeUnit": "TIME_UNIT_MINUTE"}), "90-minute")
        self.assertEqual(label({}), "")

    def test_percentages_are_clamped_and_junk_is_dropped(self):
        rows = self.parse({"limits": [
            {"window": {"duration": 300, "timeUnit": "TIME_UNIT_MINUTE"},
             "detail": {"limit": "100", "used": "250", "resetTime": "x"}},
            {"window": {"duration": 60, "timeUnit": "TIME_UNIT_MINUTE"},
             "detail": {"limit": "0", "used": "5"}},
            {"detail": {"limit": "10", "used": "1"}},
            "not a dict",
        ], "usages": {"limit_month_total": {"used_ratio": "nonsense"}}})
        self.assertEqual(len(rows), 1, "only the usable window survives")
        self.assertEqual(rows[0]["percent"], 1.0, "over-limit clamps to 100%")

    def test_an_empty_or_broken_payload_yields_nothing(self):
        for bad in ({}, {"limits": None, "usages": None}, {"usages": {"limit_5h": None}}):
            self.assertEqual(self.parse(bad), [])


if __name__ == "__main__":
    unittest.main()
