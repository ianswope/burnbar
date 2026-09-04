# Burn Bar

An Omarchy bar widget that renders every model you run — Claude, Codex and
local Ollama — as one live thermal instrument in a single bar slot.

```
CLAUDE ◄── time ──┤ now ├── time ──► CODEX  ║  LOCAL ──► seconds
```

Claude burns on the left, Codex on the right, and the newest bucket for **both**
sits against the centre divider — so the divider is always "now" and time
radiates outward. The two agents read as one instrument instead of two widgets
that happen to be adjacent.

Colour carries the token count, on a ramp that runs cold ember → agent colour →
amber → white-hot. Both agents converge on the same white at the top, because a
maxed-out burst should look equally alarming whoever caused it. Height is only a
secondary swell (72%→100%) so the strip has a profile without stealing the story
from colour.

The two thin columns bookending the cloud lanes measure something different
entirely — percent of the weekly plan limit — and are drawn in a deliberately
different visual language so the two scales are never confused. They pulse
above 90%.

## Three sections, one slot

Right of a hard rule sits the **local intelligence** lane: a reactor core plus a
violet strip of live Ollama runner load. It is deliberately narrower than a
third of the widget, because free local compute must never read at the same
weight as metered cloud spend — and it is on a different clock entirely
(percent per second, not tokens per quarter hour).

Each section carries a tinted plate and a baseline in its own identity hue —
Claude orange, Codex teal, local violet — so the three instruments are legible
at a glance. Hovering a section brightens it and shows a tooltip for **that
agent only**: totals, the current bucket, session count and weekly quota for the
cloud lanes; state, load, backend, resident model and warm-model count for local.

Motion is data, never decoration:

| Effect | Means |
|---|---|
| Ember flicker | scales with each cell's own heat — cold coals sit still |
| Impact shockwave | a band riding outward from the now line: new burn just landed |
| Rising sparks | density and speed follow total energy across all three agents |
| Reactor pulse | a local model is inferencing; the halo inflates with load |
| Idle drift | a slow travelling swell, so calm never looks broken |
| Solid red | fault. No idle animation, so an outage cannot hide |

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
- **Local** — `bin/burnbar-local-status` asks Ollama's `/api/ps` what is resident
  and samples runner CPU ticks from `/proc` plus `nvidia-smi`/`rocm-smi` for GPU
  utilisation. Nothing about local load is persisted anywhere, so the service
  keeps its own rolling ring of samples — that ring *is* the local lane.
  `bin/burnbar-local-control` lists installed models and warms or evicts one
  (`keep_alive: -1` / `keep_alive: 0`) from the detail panel.

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
numbers from them. Its only network traffic is to your own Ollama endpoint
(`OLLAMA_HOST`, default `http://127.0.0.1:11434`) to read and control local
models; nothing leaves the machine. Read `SECURITY.md` before
installing.

## Tests

```sh
./tests/test.sh
```

Validates the manifest, asserts cell count equals bucket count and local cell
count equals ring length, runs the Ollama URL/JSON hardening unit tests, checks
that the local probe degrades to a clean offline object, and runs the collector
against a synthetic fixture that checks `message.id` dedupe, cache-read
exclusion, Codex delta math, cache idempotency, and the tail read.

## Settings

| Key | Default | Meaning |
|---|---|---|
| `width` | 158 | Widget width in px |
| `bars` | 12 | Cells per cloud agent (the collector makes exactly this many buckets) |
| `windowMinutes` | 360 | How far back the cloud lanes reach |
| `refreshIntervalSec` | 5 | Collector cadence |
| `showGauges` | true | Weekly quota columns bookending the cloud lanes |
| `showLocal` | true | Show the local intelligence lane |
| `localCells` | 9 | Cells in the local lane (= length of the sample ring) |
| `localRefreshMs` | 1500 | Local runner poll interval |
| `localThreshold` | 8 | Runner load above this counts as actively inferencing |
| `emberFlicker` | true | Live flicker on hot cells |
| `sparks` | true | Rising embers while anything is burning |

Left click opens the detail panel — cloud totals, every plan limit with its
reset countdown, Claude spend by model, and local model control (warm a model
into memory or evict it). Middle click forces a refresh of everything; `R` does
the same inside the panel.
