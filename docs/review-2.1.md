# Outside review of 2.0, and what was done with it

Before 2.1 shipped, the whole plugin (7,800 lines of QML and Python) went to two
models that had no hand in writing it: **Grok 4.6** (through the Grok CLI, read
only) and **Kimi k3** (`k3-256k` on Kimi's coding API). Same brief for both:
find real defects, critique the UI, and explain how you would build the guidance
feature. Kimi reviewed the code after a first cut of the guidance existed, so it
reviewed that too.

Their output was treated as suggestions, not instructions. Every item below was
checked against the code before anything changed.

**Result: 22 distinct defects fixed, 4 of them found by both reviewers, 2
findings rejected.**

## Defects fixed

Found by Grok 4.6:

1. **The local GPU lane painted over Kimi's lane** whenever both were on. It was
   anchored to Grok's edge, and Kimi is laid out after Grok, while the tooltip
   still named Kimi. Live on the author's machine.
2. A Grok billing record with no usage figure published a confident, green
   **0%**. It is unknown now, and no row is shown.
3. A Grok session record with no token total read as zero, which would have
   billed a prompt's **whole context** instead of its growth. Latent: 0 of 787
   records on the author's machine lacked it.
4. The cockpit header counted Kimi's tokens but not its turns, sessions, rates
   or last-active time. *(also found by k3)*
5. A machine with **only Codex** drew its lane backwards. *(also found by k3)*
6. Kimi burning alone still ran the idle animation and hid the live ring. *(also
   found by k3)*
7. Kimi's tooltip said "Kimi publishes no quota" while its monthly gauge sat
   beside it.
8. "cache read ... % of input" divided by input plus output.
9. **Every on-pace sub was told to "stop in 23h".** Fixed by asking whether
   today's share really runs out today, not by the reviewer's suggested rule
   (only when over pace), because a sub that is under pace overall but burning
   hard right now still needs its stop time.
10. "Square again in 40h" could be printed with the reset 10 hours away.
11. A measured 0% drew a one-pixel sliver that read as usage.
12. Kimi's limits were treated as a never-stale snapshot if a flag was missing.
13. A headline rounding to "100%" sat over a badge still saying "slow down".
    Fixed by making 99.5% count as spent, where the reviewer suggested flooring
    the number.
14. Grok's quota in the tooltip gave no hint it was a snapshot. It now says when
    it was taken. The reviewer wanted the gauge blanked once the snapshot aged;
    that is the bug 1.15 fixed (Grok's row vanished for days), so it stays
    visible and labelled instead.

Found by Kimi k3:

15. **A date in 1970**, in the guidance written that same afternoon: a plan
    99.6% spent in the last hour of its week is "ahead" of the clock, so its
    come-back time was never set.
16. Every quota row on every card was torn down and rebuilt **once a second**
    while the panel was open.
17. A collector run against a slow remote meter host could take 69 seconds; the
    watchdog killed it at 30 and published nothing. Now 75.
18. Kimi's lane never flashed on new burn: it had the property and nothing that
    drove it.
19. Kimi's lane had no tinted plate or baseline.
20. A corrupted journal cache raised outside any guard and took every lane down.
21. The badge said "1.0x OVER" inside the 5% grace where the panel refused to
    print a multiplier. One definition of "over" everywhere now.
22. A Grok snapshot that had been used since still printed an exact banked
    figure. Both reviewers wanted it hidden. It is kept, marked `~`, labelled
    "used since", judged at the moment it was measured, and needs a 25% margin
    before it is ever suggested: hiding it would blank Grok most of the time.

## Rejected

- **Compute the pace ratio from the first second of a window** (Grok). A ratio
  over a sliver of elapsed time is noise: 1% of a plan used in the first ten
  minutes of a week is "60x over". One percent of the window stays the floor.
- **Raise a fault when history.json fails to load** (k3). The collector writes
  it atomically, so a miss is momentary, and a collector that cannot write
  already raises its own fault on exit. This would only flash a false alarm.

## Guidance: what came from the reviewers

Adopted:

- The what-to-do line sits **directly under the card's name**, above the big
  number. Both reviewers said this independently.
- The bar badge speaks **words, not multipliers** (Grok): `REST 8H`, `SPENT`.
- "**In the bank**" as the phrase for banked time (Grok).
- "**If you stop**" on every come-back time (k3): it assumes no further burn,
  and read while still working it is wrong within minutes.
- **Urgency is about the calendar, not the window** (k3): 15% of a month is four
  and a half days, and crying wolf that early gets the chip ignored.
- **Do not tell someone to switch to the sub they are already using** (Grok).
- A sub that is the current pick keeps the job down to half the threshold (k3),
  and a **session window about to fill** blocks a sub, not only a full one (k3).
- **The clocks hold while tokens are leaving** (k3's observation that a live
  clock over a stale percentage ratchets up and then jumps back). Its suggested
  fix was to extrapolate usage from the measured rate; that would keep the clock
  falling for two hours after you stopped, which is the opposite of what the
  feature promises, so the clock is simply held at the last measurement instead.
- Rate labels that cannot be read as totals, a reset label on the burndown, a
  flip control that names where it goes.

Not adopted, because the owner asked for the opposite: cutting token mix and
by-model from the card ("everything about it in one large card"), moving the
local GPU to its own page, trimming SETUP ("all options available across all
features"), and reducing the glow reasons.

Kept from the original design over both reviewers' alternatives: ranking by
**room** (plan left over clock left), which needs no bonus term for
use-it-or-lose-it because it climbs on its own as a reset nears.
