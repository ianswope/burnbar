"""Budget pace: am I over, and will I make it to the reset?

On budget means even pace across the window. These are the pure pieces of that
arithmetic, pulled out of the collector and run against fixed clocks, because
the interesting cases (a blown window, the first minute of a window, a reset
inside the rate samples) are exactly the ones that are awkward to reproduce by
waiting for real usage to happen.
"""
import ast
import datetime
import unittest
from pathlib import Path

REPO = Path(__file__).resolve().parents[1]
HOUR = 3600_000
DAY = 86400_000
NOW = 1_789_900_000_000  # 2026-09-20 in UTC


def load(now_ms=NOW):
    """The pace helpers, with the module-level clock and sample store faked."""
    tree = ast.parse((REPO / "bin" / "burnbar-collect").read_text())
    want_fn = {"window_ms_for", "recent_rate_per_hour", "pace_for", "parse_iso_ms",
               "local_midnight_ms", "norm_percent", "window_id"}
    want_const = {"RATE_WINDOW_MS", "RATE_MIN_SPAN_MS", "DAILY_MIN_WINDOW_MS",
                  "SAMPLE_MAX_AGE_MS", "FUTURE_SLACK_MS", "MALFORMED"}
    body = [n for n in tree.body
            if isinstance(n, (ast.Import, ast.ImportFrom))
            or (isinstance(n, ast.FunctionDef) and n.name in want_fn)
            or (isinstance(n, ast.Assign)
                and getattr(n.targets[0], "id", "") in want_const)]
    ns = {"now_ms": now_ms, "PACE": {"samples": {}, "next": []}}
    exec(compile(ast.Module(body=body, type_ignores=[]), "<pace>", "exec"), ns)
    return ns


def iso(ms):
    return datetime.datetime.fromtimestamp(ms / 1000, datetime.timezone.utc).isoformat()


class WindowLengthTests(unittest.TestCase):
    def setUp(self):
        self.ns = load()

    def test_the_label_carries_the_length_when_the_provider_states_it(self):
        self.assertEqual(self.ns["window_ms_for"]("Session (5-hour)", NOW, 0), 5 * HOUR)
        self.assertEqual(self.ns["window_ms_for"]("Weekly (7-day)", NOW, 0), 7 * DAY)

    def test_a_month_is_the_calendar_month_before_the_reset_not_thirty_days(self):
        # Reset on 1 March 2027: the window that ends there began 1 February,
        # which is 28 days, not 30.
        march = int(datetime.datetime(2027, 3, 1, tzinfo=datetime.timezone.utc).timestamp() * 1000)
        self.assertEqual(self.ns["window_ms_for"]("Monthly (total)", march, 0), 28 * DAY)
        # And a leap February is 29.
        leap = int(datetime.datetime(2028, 3, 1, tzinfo=datetime.timezone.utc).timestamp() * 1000)
        self.assertEqual(self.ns["window_ms_for"]("Monthly (total)", leap, 0), 29 * DAY)

    def test_an_unlabelled_window_is_measured_from_the_previous_reset(self):
        self.assertEqual(self.ns["window_ms_for"]("Quota", NOW + DAY, NOW - 2 * DAY), 3 * DAY)

    def test_an_unlabelled_window_with_no_history_is_unknown_not_a_guess(self):
        self.assertEqual(self.ns["window_ms_for"]("Quota", NOW + DAY, 0), 0)


class RateTests(unittest.TestCase):
    def setUp(self):
        self.ns = load()

    def rate(self, points):
        return self.ns["recent_rate_per_hour"]([(t, p, 1) for t, p in points])

    def test_a_straight_line_is_its_slope_per_hour(self):
        r = self.rate([(NOW - 2 * HOUR, 0.10), (NOW - HOUR, 0.20), (NOW, 0.30)])
        self.assertAlmostEqual(r, 0.10, places=6)

    def test_one_sample_cannot_be_a_rate(self):
        self.assertIsNone(self.rate([(NOW, 0.4)]))

    def test_two_ticks_seconds_apart_cannot_be_a_rate(self):
        self.assertIsNone(self.rate([(NOW - 5_000, 0.40), (NOW, 0.41)]))

    def test_a_percentage_that_went_down_is_a_reset_not_a_negative_burn(self):
        self.assertIsNone(self.rate([(NOW - 2 * HOUR, 0.90), (NOW, 0.05)]))

    def test_samples_older_than_the_rate_window_are_not_part_of_the_rate(self):
        # The old point would halve the slope if it counted.
        r = self.rate([(NOW - 20 * HOUR, 0.0), (NOW - HOUR, 0.50), (NOW, 0.60)])
        self.assertAlmostEqual(r, 0.10, places=6)


class WindowIdTests(unittest.TestCase):
    """The jitter that stopped every rate from forming, 2026-09-20."""

    def test_the_same_window_stated_with_jitter_is_one_window(self):
        ns = load()
        base = NOW + 6 * DAY
        ids = {ns["window_id"](base + ms) for ms in (0, 53, 407, 828, 950)}
        self.assertEqual(len(ids), 1)

    def test_windows_a_minute_apart_stay_different(self):
        ns = load()
        base = NOW + 6 * DAY
        self.assertNotEqual(ns["window_id"](base), ns["window_id"](base + 60_000))


class PaceTests(unittest.TestCase):
    def row(self, pct, resets_ms, label="Weekly (7-day)"):
        return {"label": label, "percent": pct, "resetsAt": iso(resets_ms)}

    def test_on_pace_is_one(self):
        ns = load()
        # Half the week gone, half the allowance spent.
        p = ns["pace_for"](self.row(0.5, NOW + 3.5 * DAY), "claude|w", True)
        self.assertAlmostEqual(p["ratio"], 1.0, places=3)
        self.assertAlmostEqual(p["elapsed"], 0.5, places=3)

    def test_a_blown_window_reports_no_allowance_and_recovers_only_at_the_reset(self):
        ns = load()
        # Rounded, because a window is identified to the minute: providers
        # re-state the same reset with millisecond jitter.
        resets = ns["window_id"](NOW + 6 * DAY)
        p = ns["pace_for"](self.row(1.0, resets), "codex|w", True)
        self.assertGreater(p["ratio"], 1.0)
        self.assertEqual(p["allowancePerHour"], 0.0)
        # Nothing but time fixes 100%: back on pace exactly at the reset.
        self.assertEqual(p["backOnPaceAt"], resets)

    def test_half_spent_early_comes_back_on_pace_midway_through_the_window(self):
        ns = load()
        resets = ns["window_id"](NOW + 6 * DAY)
        p = ns["pace_for"](self.row(0.5, resets), "claude|w", True)
        self.assertGreater(p["ratio"], 1.0)
        # reset - L*(1-p) = reset - 3.5 days
        self.assertEqual(p["backOnPaceAt"], int(resets - 3.5 * DAY))

    def test_the_first_moments_of_a_window_hold_the_ratio_rather_than_divide_by_zero(self):
        ns = load()
        p = ns["pace_for"](self.row(0.01, NOW + 7 * DAY - 60_000), "claude|w", True)
        self.assertEqual(p["ratio"], -1)          # withheld, not infinite
        self.assertGreaterEqual(p["elapsed"], 0)  # but elapsed is still known

    def test_a_window_already_past_its_reset_carries_no_pace(self):
        ns = load()
        p = ns["pace_for"](self.row(0.4, NOW - HOUR), "claude|w", True)
        self.assertEqual(p["windowMs"], 0)
        self.assertEqual(p["ratio"], -1)

    def test_a_missing_percentage_carries_no_pace(self):
        ns = load()
        p = ns["pace_for"]({"label": "Weekly (7-day)", "percent": -1,
                            "resetsAt": iso(NOW + DAY)}, "claude|w", True)
        self.assertEqual(p["ratio"], -1)
        self.assertEqual(p["allowancePerHour"], -1)

    def test_a_snapshot_row_gets_a_ratio_but_never_a_rate(self):
        # Grok logs its figure once per launch: enough for "are you over",
        # never enough for "at this rate".
        ns = load()
        ns["PACE"]["samples"]["grok|w"] = [(NOW - 2 * HOUR, 0.10, 1), (NOW, 0.30, 1)]
        p = ns["pace_for"](self.row(0.30, NOW + 3.5 * DAY), "grok|w", False)
        self.assertGreater(p["ratio"], 0)
        self.assertEqual(p["ratePerHour"], -1)
        self.assertEqual(p["projected"], -1)

    def test_at_this_rate_projects_past_the_reset_and_names_the_dry_moment(self):
        ns = load()
        # Samples belong to a window by its rounded id, which is what lets a
        # rate form at all: keyed on the raw value, Claude's jitter put 56
        # different windows inside one second and no two samples ever matched.
        resets = ns["window_id"](NOW + 10 * HOUR)
        # 40% gone and burning 10 points an hour: 6 hours of headroom, 10 to go.
        ns["PACE"]["samples"]["claude|w"] = [
            (NOW - 2 * HOUR, 0.20, resets), (NOW - HOUR, 0.30, resets), (NOW, 0.40, resets)]
        p = ns["pace_for"](self.row(0.40, resets), "claude|w", True)
        self.assertAlmostEqual(p["ratePerHour"], 0.10, places=6)
        # 2 places, not 3: rounding the reset down to its minute shortens the
        # window by up to 60s, which moves the projection in the third decimal.
        self.assertAlmostEqual(p["projected"], 1.40, places=2)
        self.assertAlmostEqual((p["dryAt"] - NOW) / HOUR, 6.0, places=3)

    def test_a_rate_that_still_lands_inside_the_window_names_no_dry_moment(self):
        ns = load()
        resets = ns["window_id"](NOW + 10 * HOUR)
        ns["PACE"]["samples"]["claude|w"] = [
            (NOW - 2 * HOUR, 0.10, resets), (NOW, 0.12, resets)]
        p = ns["pace_for"](self.row(0.12, resets), "claude|w", True)
        self.assertLess(p["projected"], 1.0)
        self.assertEqual(p["dryAt"], 0)

    def test_a_five_hour_window_has_no_daily_budget(self):
        ns = load()
        p = ns["pace_for"](self.row(0.5, NOW + HOUR, "Session (5-hour)"), "claude|s", True)
        self.assertEqual(p["todayUsed"], -1)
        self.assertEqual(p["todayAllowance"], -1)
        self.assertFalse(p["overDaily"])


if __name__ == "__main__":
    unittest.main()
