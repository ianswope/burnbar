"""On a crowded bar the strip gives up space instead of bidding for it.

Fred, 2026-09-12: "When the bar gets crowded this plugin needs to give up more
space." Measured on gus first: 34 widgets on a 1600px bar, and Burn Bar sat at
148px claiming `ourMin + extra/2` of the gap whether or not it could use it.

Two things had to change together, and a test for either alone would pass while
the strip still hoarded:

  1. The width floor is what the strip needs at its LEAST detailed (minBars),
     not at its preferred detail (baseBars). Using baseBars pinned the floor at
     136px and refused to yield the last 26.
  2. Splitting the leftover evenly is only fair when there is enough of it.
     When the gap cannot seat comfortWidth AND the partner, the strip drops to
     its floor rather than taking half of a gap neither of them can use.

Lowering the floor alone did nothing: the share formula simply absorbed the
26px it freed and the strip stayed at 148. That is why the yield branch is
asserted here too.
"""
import ast
import math
import re
import unittest
from pathlib import Path

REPO = Path(__file__).resolve().parents[1]
SRC = (REPO / "BarWidget.qml").read_text()


def need(bars, agents=3, gauges=True, local=True, local_cells=9):
    """The formula both minWidthForCells and comfortWidth use, differing only
    in which bar count they are handed."""
    n = max(1, agents)
    cloud = (2 * n * bars + 3 + (6 * n if gauges else 0) + (4 if local else 0)) / (0.75 if local else 1)
    ln = (2 * local_cells + 6) * 4 if local else 0
    return max(110, math.ceil(max(cloud, ln)) + 6)


class CrowdedBarYieldTests(unittest.TestCase):
    def test_the_floor_is_computed_from_the_least_detailed_strip(self):
        """minWidthForCells must read minBars. Reading baseBars makes the floor
        the preferred width, which is the bug."""
        block = re.search(r"minWidthForCells:\s*\{.*?\n  \}", SRC, re.S)
        self.assertIsNotNone(block, "minWidthForCells not found")
        body = block.group(0)
        self.assertIn("minBars", body, "the floor must be built from minBars")
        self.assertNotRegex(
            body, r"\*\s*n\s*\*\s*baseBars",
            "the floor must not be built from baseBars — that is comfortWidth")

    def test_comfort_is_built_from_the_preferred_bar_count(self):
        block = re.search(r"comfortWidth:\s*\{.*?\n  \}", SRC, re.S)
        self.assertIsNotNone(block, "comfortWidth not found")
        self.assertIn("baseBars", block.group(0))

    def test_the_floor_really_is_lower_than_comfort(self):
        """Otherwise there is nothing to hand back."""
        floor, comfort = need(6), need(12)
        self.assertLess(floor, comfort)
        self.assertGreaterEqual(comfort - floor, 20,
                                "too little slack to be worth yielding")

    def test_the_floor_never_goes_below_the_legibility_clamp(self):
        for bars in (6, 8, 12, 24, 240):
            self.assertGreaterEqual(need(bars), 110)

    def test_a_lone_agent_still_gets_a_sane_floor(self):
        for agents in (1, 2, 3):
            self.assertGreaterEqual(need(6, agents=agents), 110)

    def test_the_strip_stops_bidding_when_the_gap_cannot_seat_both(self):
        """The yield branch: below comfort + partnerMin, take ourMin and let the
        neighbour have the rest."""
        self.assertRegex(
            SRC, r"hole\s*<\s*Style\.spaceReal\(comfortWidth\)\s*\+\s*partnerMin",
            "no crowded-gap test before the even split")
        split = SRC.index("next = ourMin + extra / n")
        yield_at = SRC.index("Style.spaceReal(comfortWidth) + partnerMin")
        self.assertLess(yield_at, split,
                        "the crowded case must be decided BEFORE the even split")

    def test_cells_may_shed_below_the_preferred_count(self):
        """adaptiveCells must floor at minBars, not baseBars, or the strip can
        never narrow past its preferred detail."""
        block = re.search(r"adaptiveCells:\s*\{.*?\n  \}", SRC, re.S)
        self.assertIsNotNone(block)
        self.assertRegex(block.group(0), r"Math\.max\(\s*minBars\s*,")

    def test_minBars_is_the_schema_minimum(self):
        """A floor below what `bars` allows would be unreachable and a lie."""
        self.assertRegex(SRC, r"readonly property int minBars:\s*6")
        self.assertRegex(SRC, r'boundedInt\("bars",\s*12,\s*6,')


if __name__ == "__main__":
    unittest.main()
