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

`bin/burnbar-collect` (Python 3, standard library only) reads the raw transcripts, the only place per-turn token
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

Scanning is incremental twice over: a file whose size and mtime are unchanged
replays its cached contribution, and a file that merely grew is read from the
previous byte offset rather than re-parsed whole. Cold run ~2s, warm ~120ms,
which is what makes a 5-second refresh reasonable.

Python 3 with no third-party imports is deliberate. Omarchy depends on `uwsm`
and `kitty`, both of which depend on `python`, so `python3` is present on every
Omarchy install; `bun` is not an Omarchy dependency and cannot be assumed.

If the collector cannot run, the strip turns solid red and the tooltip says why.
It never fails silently.

## Privacy

Burn Bar reads your Claude and Codex transcripts to count tokens, and keeps only
numbers from them. It makes no network requests. Read `SECURITY.md` before
installing.

## Tests

```sh
./tests/test.sh
```

Validates the manifest, asserts cell count equals bucket count, and runs the
collector against a synthetic fixture that checks `message.id` dedupe, cache-read
exclusion, Codex delta math, cache idempotency, and the tail read.

## Settings

| Key | Default | Meaning |
|---|---|---|
| `width` | 114 | Widget width in px |
| `bars` | 12 | Cells per agent (the collector makes exactly this many buckets) |
| `windowMinutes` | 360 | How far back the strip reaches |
| `refreshIntervalSec` | 5 | Collector cadence |
| `showGauges` | true | Weekly quota columns on the outer edges |
| `emberFlicker` | true | Live flicker on hot cells |

Left click opens the detail panel, middle click forces a refresh.
