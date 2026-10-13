"""Grok plans: named from the billing log, and a change of plan is not a gift.

Fred, 2026-10-12: SuperGrok Plus to Heavy moved the weekly figure from 14% to 8%
with the reset date untouched. The same week had been re-expressed against a
bigger pool; 2.2.1's gift-reset detector read the fall as a wiped meter and
re-based the week on the upgrade, so Grok showed 1% of its clock gone and "8x
over pace" with 71% of the week behind it. These tests are that afternoon.
"""
import ast
import datetime
import json
import tempfile
import unittest
from pathlib import Path

REPO = Path(__file__).resolve().parents[1]
HOUR = 3600_000
DAY = 24 * HOUR
END = "2026-10-15T03:10:03.312033+00:00"


def ms(iso):
    return int(datetime.datetime.fromisoformat(iso.replace("Z", "+00:00")).timestamp() * 1000)


T_CHANGE = ms("2026-10-13T00:58:06Z")
NOW = ms("2026-10-13T01:20:00Z")


def load(log=None, now=NOW):
    tree = ast.parse((REPO / "bin" / "burnbar-collect").read_text())
    want_fn = {"grok_billing_entries", "grok_tier_short", "grok_tier_from_log", "grok_plan_change",
               "parse_ts", "parse_iso_ms", "window_ms_for", "recent_rate_per_hour", "pace_for",
               "local_midnight_ms", "norm_percent", "window_id", "burndown_series", "gift_reset_at"}
    want_const = {"MALFORMED", "GROK_BILLING", "GROK_TIER_RANK", "RATE_WINDOW_MS", "RATE_MIN_SPAN_MS",
                  "DAILY_MIN_WINDOW_MS", "SAMPLE_MAX_AGE_MS", "FUTURE_SLACK_MS", "SERIES_MAX_POINTS",
                  "GIFT_MIN_DROP", "GIFT_ID_SLACK_MS", "MAX_TOKENS"}
    body = [n for n in tree.body
            if isinstance(n, (ast.Import, ast.ImportFrom))
            or (isinstance(n, ast.FunctionDef) and n.name in want_fn)
            or (isinstance(n, ast.Assign) and getattr(n.targets[0], "id", "") in want_const)]
    ns = {"now_ms": now, "PACE": {"samples": {}, "next": []}, "GROK_LOG": log or Path("/nonexistent/unified.jsonl")}
    exec(compile(ast.Module(body=body, type_ignores=[]), "<plan>", "exec"), ns)
    return ns


def log_with(rows):
    """rows: (iso ts, tier or None, percent). Plus a junk line and a stranger."""
    lines = ["not json at all", json.dumps({"ts": "2026-10-02T00:00:00Z", "msg": "something else"})]
    for ts, tier, pct in rows:
        ctx = {"config": {"creditUsagePercent": pct, "currentPeriod": {"end": END}}}
        if tier:
            ctx["subscriptionTier"] = tier
        lines.append(json.dumps({"ts": ts, "msg": "billing: fetched credits config", "ctx": ctx}))
    path = Path(tempfile.mkdtemp()) / "unified.jsonl"
    path.write_text("\n".join(lines) + "\n")
    return path


PLUS, HEAVY = "SuperGrok Plus", "SuperGrok Heavy"


class PlanFromLogTests(unittest.TestCase):
    def test_plus_to_heavy_is_named_dated_and_called_an_upgrade(self):
        ns = load(log_with([("2026-10-12T14:18:35.100Z", PLUS, 14.0), ("2026-10-12T14:18:36.200Z", PLUS, 14.0),
                            ("2026-10-13T00:58:06.269Z", HEAVY, 8.0), ("2026-10-13T01:17:37.269Z", HEAVY, 9.0)]))
        t = ns["grok_tier_from_log"]()
        self.assertEqual((t["label"], t["short"], t["from"], t["fromShort"], t["direction"]),
                         (HEAVY, "Heavy", PLUS, "Plus", "up"))
        self.assertEqual(t["since"], ns["parse_ts"]("2026-10-13T00:58:06.269Z"))

    def test_heavy_to_plus_is_a_downgrade(self):
        ns = load(log_with([("2026-10-12T00:00:00Z", HEAVY, 8.0), ("2026-10-13T00:00:00Z", PLUS, 9.0)]))
        self.assertEqual(ns["grok_tier_from_log"]()["direction"], "down")

    def test_a_plan_that_never_changed_has_no_change(self):
        ns = load(log_with([("2026-10-12T00:00:00Z", HEAVY, 8.0), ("2026-10-13T00:00:00Z", HEAVY, 9.0)]))
        t = ns["grok_tier_from_log"]()
        self.assertEqual((t["short"], t["from"]), ("Heavy", ""))
        self.assertIsNone(ns["grok_plan_change"](t, [{"resetsAt": END}], NOW))

    def test_a_name_nobody_has_seen_is_shown_as_written_and_a_change_is_still_noticed(self):
        ns = load(log_with([("2026-10-12T00:00:00Z", HEAVY, 8.0), ("2026-10-13T00:00:00Z", "SuperGrok Ultra", 4.0)]))
        t = ns["grok_tier_from_log"]()
        self.assertEqual((t["label"], t["short"], t["from"], t["direction"]), ("SuperGrok Ultra", "Ultra", HEAVY, ""))

    def test_flipping_back_dates_the_change_from_the_latest_run(self):
        ns = load(log_with([("2026-10-10T00:00:00Z", HEAVY, 8.0), ("2026-10-11T00:00:00Z", PLUS, 9.0),
                            ("2026-10-13T00:00:00Z", HEAVY, 4.0)]))
        t = ns["grok_tier_from_log"]()
        self.assertEqual((t["from"], t["direction"], t["since"]), (PLUS, "up", ns["parse_ts"]("2026-10-13T00:00:00Z")))

    def test_a_snapshot_without_a_plan_does_not_end_the_run(self):
        ns = load(log_with([("2026-10-10T00:00:00Z", PLUS, 8.0), ("2026-10-11T00:00:00Z", None, 9.0),
                            ("2026-10-12T00:00:00Z", PLUS, 9.0)]))
        self.assertEqual(ns["grok_tier_from_log"]()["from"], "")

    def test_no_plan_anywhere_or_no_log_is_nothing_not_a_guess(self):
        self.assertEqual(load(log_with([("2026-10-12T00:00:00Z", None, 8.0)]))["grok_tier_from_log"](), {})
        self.assertEqual(load()["grok_tier_from_log"](), {})

    def test_short_names(self):
        short = load()["grok_tier_short"]
        self.assertEqual([short(x) for x in (HEAVY, PLUS, "SuperGrok", "GrokLite", "Heavy", "")],
                         ["Heavy", "Plus", "SuperGrok", "Lite", "Heavy", ""])

    def test_only_a_change_inside_this_weeks_window_is_worth_saying(self):
        ns = load(log_with([("2026-10-02T00:00:00Z", PLUS, 3.0), ("2026-10-13T00:58:06Z", HEAVY, 8.0)]))
        t = ns["grok_tier_from_log"]()
        limits = [{"resetsAt": END}]
        got = ns["grok_plan_change"](t, limits, NOW)
        self.assertEqual((got["from"], got["to"], got["direction"], got["at"]), ("Plus", "Heavy", "up", T_CHANGE))
        # last week's change belongs to last week's numbers, and the future is not a change
        self.assertIsNone(ns["grok_plan_change"](dict(t, since=ms("2026-10-05T00:00:00Z")), limits, NOW))
        self.assertIsNone(ns["grok_plan_change"](dict(t, since=NOW + HOUR), limits, NOW))
        self.assertIsNone(ns["grok_plan_change"](t, [], NOW))


class PlanRebaseTests(unittest.TestCase):
    KEY = "grok|Weekly (7-day)"

    def pace(self, samples, used, rebase_at=0):
        ns = load()
        resets = ns["window_id"](ms(END))
        ns["PACE"]["samples"][self.KEY] = [(t, p, resets) for t, p in samples]
        row = {"label": "Weekly (7-day)", "percent": used, "resetsAt": END}
        return ns["pace_for"](row, self.KEY, False, rebase_at), resets

    SAMPLES = [(NOW - 3 * DAY, 0.11), (T_CHANGE - 10 * HOUR, 0.14), (T_CHANGE + 3000, 0.08), (NOW - 5 * 60_000, 0.09)]

    def test_the_upgrade_keeps_the_whole_week(self):
        p, resets = self.pace(self.SAMPLES, 0.09, rebase_at=T_CHANGE)
        self.assertEqual(p["giftAt"], 0)
        self.assertEqual(p["rebaseAt"], T_CHANGE)
        self.assertEqual(p["windowMs"], 7 * DAY)
        # 4d 22h of a 7d week is gone: about 70% of the clock, 9% of the pool.
        self.assertAlmostEqual(p["elapsed"], 0.703, places=2)
        self.assertLess(p["ratio"], 0.2)

    def test_the_burndown_forgets_the_old_pool_and_never_exceeds_the_new_figure(self):
        p, _ = self.pace(self.SAMPLES, 0.09, rebase_at=T_CHANGE)
        self.assertTrue(all(y <= 0.09 + 1e-9 for _, y in p["series"]), p["series"])
        self.assertGreater(p["series"][0][0], 0.6)

    def test_without_the_rebase_the_same_samples_read_as_a_gift_which_is_what_shipped(self):
        p, _ = self.pace(self.SAMPLES, 0.09)
        self.assertGreater(p["giftAt"], 0)
        self.assertLess(p["elapsed"], 0.05)

    def test_a_change_from_before_the_window_is_ignored(self):
        p, _ = self.pace(self.SAMPLES, 0.09, rebase_at=ms("2026-10-05T00:00:00Z"))
        self.assertEqual(p["rebaseAt"], 0)
        self.assertEqual(p["windowMs"] + (p["fullWindowMs"] - p["windowMs"]), 7 * DAY)

    def test_a_real_gift_after_the_plan_change_is_still_a_gift(self):
        later = [(T_CHANGE + 3000, 0.08), (T_CHANGE + HOUR, 0.30), (NOW - 5 * 60_000, 0.30)]
        p, _ = self.pace(later, 0.0, rebase_at=T_CHANGE)
        self.assertEqual(p["giftAt"], NOW)
        self.assertEqual(p["windowMs"], ms(END) // 60_000 * 60_000 - NOW)


if __name__ == "__main__":
    unittest.main()
