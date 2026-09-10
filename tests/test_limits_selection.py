"""Choosing between two sources of plan limits.

Grok has no stock Omarchy probe, so agents/usage/grok.json is written once and
then frozen, while ~/.grok/logs/unified.jsonl keeps moving. Preferring the
record whenever it merely had a limits array pinned Grok's weekly figure to
whatever it said the day that file appeared, and showed an already-reset
window as a confident 0%.
"""
import ast
import unittest
from pathlib import Path

REPO = Path(__file__).resolve().parents[1]
HOUR = 3600_000
NOW = 1_789_000_000_000  # 2026-09-10, between PAST and OPEN below


def load():
    """Pull the two pure helpers out of the collector without collecting."""
    tree = ast.parse((REPO / "bin" / "burnbar-collect").read_text())
    want = {"window_open", "pick_limits", "parse_iso_ms"}
    body = [n for n in tree.body
            if isinstance(n, (ast.Import, ast.ImportFrom))
            or (isinstance(n, ast.FunctionDef) and n.name in want)]
    ns = {}
    exec(compile(ast.Module(body=body, type_ignores=[]), "<limits>", "exec"), ns)
    return ns


def limit(resets):
    return [{"label": "Weekly (7-day)", "percent": 0.4, "resetsAt": resets}]


OPEN = "2026-12-31T00:00:00+00:00"
PAST = "2026-01-01T00:00:00+00:00"


class WindowOpenTests(unittest.TestCase):
    def setUp(self):
        self.ns = load()

    def test_a_future_reset_is_open(self):
        self.assertTrue(self.ns["window_open"](limit(OPEN), NOW))

    def test_a_past_reset_is_closed(self):
        self.assertFalse(self.ns["window_open"](limit(PAST), NOW))

    def test_no_limits_is_closed(self):
        for value in ([], None):
            self.assertFalse(self.ns["window_open"](value, NOW))

    def test_an_undated_limit_cannot_be_judged_so_counts_as_open(self):
        self.assertTrue(self.ns["window_open"]([{"label": "x", "percent": 0.1}], NOW))

    def test_one_open_window_keeps_the_whole_set_open(self):
        both = limit(PAST) + limit(OPEN)
        self.assertTrue(self.ns["window_open"](both, NOW))


class PickLimitsTests(unittest.TestCase):
    def setUp(self):
        self.ns = load()
        self.pick = lambda c: self.ns["pick_limits"](c, NOW)

    def test_the_frozen_record_no_longer_shadows_the_live_log(self):
        """The actual bug: a stale record with a reset window used to win
        purely by being first and non-empty."""
        record = (limit(PAST), NOW - 200 * HOUR, "")
        log = (limit(OPEN), NOW - 300 * HOUR, "")
        chosen = self.pick([record, log])
        self.assertEqual(chosen[0], limit(OPEN), "an open window must beat a reset one")

    def test_between_two_open_windows_the_newer_measurement_wins(self):
        older = (limit(OPEN), NOW - 50 * HOUR, "older")
        newer = (limit(OPEN), NOW - 1 * HOUR, "newer")
        self.assertEqual(self.pick([older, newer])[2], "newer")
        self.assertEqual(self.pick([newer, older])[2], "newer")

    def test_between_two_reset_windows_the_newer_measurement_wins(self):
        older = (limit(PAST), NOW - 50 * HOUR, "older")
        newer = (limit(PAST), NOW - 1 * HOUR, "newer")
        self.assertEqual(self.pick([older, newer])[2], "newer")

    def test_an_empty_source_is_skipped_not_preferred(self):
        empty = ([], 0, "")
        log = (limit(OPEN), NOW - 10 * HOUR, "log")
        self.assertEqual(self.pick([empty, log])[2], "log")

    def test_nothing_usable_returns_none(self):
        self.assertIsNone(self.pick([([], 0, ""), ([], 0, "")]))
        self.assertIsNone(self.pick([]))


if __name__ == "__main__":
    unittest.main()
