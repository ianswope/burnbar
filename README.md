# Burn Bar

An Omarchy bar widget that renders Claude and Codex token spend as a live
thermal heat map.

Claude burns on the left, Codex on the right, and the newest bucket for **both**
sits against the centre divider — so the divider is always "now" and time
radiates outward. The two agents read as one instrument instead of two widgets
that happen to be adjacent.

Colour carries the token count, on a ramp that runs cold ember → agent colour →
amber → white-hot. Both agents converge on the same white at the top, because a
maxed-out burst should look equally alarming whoever caused it. Height is only a
secondary swell (72%→100%) so the strip has a profile without stealing the story
from colour.

The two thin columns on the outer edges measure something different entirely —
percent of the weekly plan limit — and are drawn in a deliberately different
visual language so the two scales are never confused. They pulse above 90%.

## Where the numbers come from

`bin/burnbar-collect.ts` reads the raw transcripts, the only place per-turn token
deltas with timestamps actually live:

- **Claude** — `~/.claude/projects/**/*.jsonl`, assistant lines carry
  `message.usage`. The same message is re-serialized up to 3× as it streams, so
  `message.id` is the mandatory dedupe key. Counts fresh input + cache writes +
  output; cache *reads* are excluded as the cheap path that would swamp the graph.
- **Codex** — `~/.codex/sessions/YYYY/MM/DD/rollout-*.jsonl`, `event_msg` lines
  where `payload.type === "token_count"` carry `info.last_token_usage`, already a
  per-turn delta.
- **Limits** — read straight off the records `omarchy-agent-usage-update` keeps in
  `~/.local/state/omarchy/agents/usage/`.

Output goes to `~/.local/state/omarchy/burnbar/history.json`. State deliberately
never lives inside the plugin directory: a plugin writing in its own dir makes
Omarchy rebuild every plugin service.

Scanning is incremental — transcripts are append-only, so a file whose size and
mtime are unchanged replays its cached contribution. Cold run ~1.4s, warm ~70ms,
which is what makes a 5-second refresh reasonable.

## Settings

| Key | Default | Meaning |
|---|---|---|
| `width` | 168 | Widget width in px |
| `bars` | 16 | Cells per agent |
| `windowMinutes` | 360 | How far back the strip reaches |
| `refreshIntervalSec` | 5 | Collector cadence |
| `showGauges` | true | Weekly quota columns on the outer edges |
| `emberFlicker` | true | Live flicker on hot cells |

Left click opens the detail panel, middle click forces a refresh.
