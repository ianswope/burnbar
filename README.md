# Burn Bar

An Omarchy bar widget that renders every model you run — Claude, Codex and
the Ollama on your Jetson — as one live thermal instrument in a single bar
slot, with a click-to-open cockpit that shows what, how much, how fast, how
close to the plan limit, and what the GPU is doing about it.

![Burn Bar cockpit: cloud spend on the left, the Ollama box on the right](docs/cockpit.png)

Everything in that screenshot is real: 10.5M tokens burned in six hours
across 113 sessions, a cache that served 192.8M reads, and a GPU holding one
warm model at 38 W. Nothing was drawn by hand. (The screenshot predates
1.5.0, when the local column moved to a Jetson; the layout is the same.)

## Install

```sh
omarchy plugin add https://github.com/nixfred/burnbar.git --enable
```

Pick a bar section when asked (it defaults to `center`). Later:

```sh
omarchy plugin update nixfred.burnbar     # pull the latest
omarchy plugin remove nixfred.burnbar     # take it out again
```

Requirements: a stock Omarchy install. `python3` is already there. For the
local lane: an Ollama box you can reach — by default `nano`, a Jetson Orin
Nano on the tailnet — with `ssh nano` logging in without a prompt, and
`./nano/install.sh` run once to put the token meter there (see below). Without
it the lane reads OFFLINE. No Codex? That lane simply stays cold. Horizontal bars only: the strip lays its three lanes across the
bar's length and does not rotate for a left or right bar.

Read [SECURITY.md](SECURITY.md) before installing. Burn Bar opens your Claude
and Codex transcripts to count tokens. It keeps numbers, model names and
message ids from them, never text — and it triggers Omarchy's own usage
collectors, which contact your providers with the sign-ins you already have.

## The strip

![Burn Bar in the Omarchy bar, right of the clock](docs/bar.png)

```
CLAUDE ◄── time ──┤ now ├── time ──► CODEX  ║  NANO ──► seconds
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

Right of a hard rule sits the **local intelligence** lane: a reactor core plus a
violet strip of live load on the Ollama box. It is deliberately narrower than
a third of the widget, because free local compute must never read at the same
weight as metered cloud spend — and it is on a different clock entirely
(percent per second, not tokens per half hour).

Each section carries a tinted plate and a baseline in its own identity hue —
Claude orange, Codex teal, local violet. Hovering a section brightens it and
shows a tooltip for **that agent only**: totals, the current bucket, session
count and weekly quota for the cloud lanes; state, load, backend, resident
model and warm-model count for local.

| Input | Does |
|---|---|
| Hover a section | Tooltip for that agent alone |
| Left click | Opens the cockpit |
| Middle click | Forces a fresh collector run and a local poll |

Motion is data, never decoration:

| Effect | Means |
|---|---|
| Ember flicker | scales with each cell's own heat — cold coals sit still |
| Impact shockwave | a band riding outward from the now line: new burn just landed |
| Rising sparks | density and speed follow total energy across all three agents |
| White-hot filament | a cell that is genuinely at the top of the ramp |
| Reactor pulse | a local model is inferencing; the halo inflates with load |
| Idle drift | a slow travelling swell, so calm never looks broken |
| Solid red | fault. No idle animation, so an outage cannot hide |

## The cockpit

Left click the strip. The panel is two columns at a fixed width, fitted to its
content, and it never scrolls — the whole instrument is one glance. Left is
metered cloud spend in tokens; right is the Ollama box in watts, degrees and
megabytes. Different money, different units, so they never share a column.
Everything grows into place on open, then moves only when the data does.

**Header** — tokens burned in the exact trailing window (fresh input, cache
writes and output; cache reads are left out, and they are billed too, at a
lower rate), turns and sessions across both cloud agents, and a refresh
button.

**Three tiles** — Claude, Codex and nano, each with its own hue: turns,
sessions, tokens per minute, when the peak bucket happened, and how long ago
the agent was last active. The nano tile shows state, warm-model count and
watts, plus the session's peak load and power.

**Cloud column**

- *Burn over time* — Claude grows upward, Codex downward, one bar per bucket,
  coloured on the same heat ramp as the strip. Hour labels underneath, the
  peak of each agent flagged at the top right, and the live bucket breathes
  until the window rolls.
- *Rate* — tokens per minute for each agent over three horizons: the last
  five minutes, the last hour and the whole window, each measured exactly
  from timestamped points rather than from buckets.
- *Token mix* — input, cache write and output per agent, with cache reads on
  their own line and their share of everything the model took in. That is a
  token share, not a cost saving: cache hits are billed too, at a lower rate.
  Cache reads are kept out of the heat map but visible here on purpose.
- *Plan limits* — every limit Omarchy's agent-usage records track (Claude
  session, weekly and any extra weekly buckets; Codex weekly), each with a
  countdown, the wall-clock reset time and a percentage bar. A window whose
  reset time has passed reads "rolled over · awaiting refresh" with the
  percentage withheld, and a record that is stale or carries a status
  ("Sign-in expired") says so under the header, in red.
- *Claude by model* — spend split by model with share bars, so you can see
  which model actually ate the window.

**Local column**

- The box's name and state (NANO · IDLE / INFERENCING / OFFLINE), then the
  board (`Jetson Orin Nano Super`), backend (`TEGRA`) and Ollama version. If
  residency answered but ssh did not, this line turns red and says why —
  never a board full of zeros.
- *Local tokens* — how many tokens burned on the Ollama box over the same
  window, with a gauge for the **offload share**: local tokens as a fraction
  of everything that burned (local + Claude + Codex). Below it, prompt /
  generated counts and the model that did most of the work. The header, the
  LOCAL tile, the RATE and TOKEN MIX rows, and the strip's local tooltip all
  carry the same numbers.
- Six tiles: GPU load with the ollama processes' CPU share, power draw at
  the barrel jack with the CPU/GPU/CV rail underneath, temperature with a
  plain-language state, unified memory used of total with the models' share
  and what is free, GPU clock against its ceiling, and warm-model count with
  sample age and poll interval.
- Load and power traces, one cell per sample: height is intensity, brightness
  is recency. The caption states the span the ring actually covers.
- *Resident models* — everything Ollama currently holds in memory: parameter
  count, quantisation, family, the VRAM each one actually occupies, context
  length, and "evicts in", read from Ollama's own `expires_at`. Long lists
  cap at six rows with a "+ N more" line; so does Claude-by-model.
- *Model control* — pick any installed model and **Load & keep warm**
  (`keep_alive: -1`) or **Unload** (`keep_alive: 0`) without leaving the bar.
  A load first drops the box's page cache over ssh (see "On nano" below);
  embedding-only models are warmed through `/api/embed`, since generate
  refuses them.

Inside the panel `R` forces a refresh and `Esc` closes it. A figure the board
does not expose reads as zero: its bar hides and its value shows as `--`; the
tiles themselves stay, so the column keeps its shape.

## Where the numbers come from

`bin/burnbar-collect` (Python 3, standard library only) reads the raw
transcripts, the only place per-turn token deltas with timestamps actually
live:

- **Claude** — `~/.claude/projects/**/*.jsonl`, assistant lines carry
  `message.usage`. The same message is re-serialized up to 3× as it streams,
  each revision with more output, so `message.id` is the mandatory dedupe key
  and the largest revision is the one that counts. Counts fresh input + cache
  writes + output; cache *reads* are excluded from the heat map as the cheap
  path that would swamp the graph, and carried separately for the token-mix
  line.
- **Codex** — `~/.codex/sessions/YYYY/MM/DD/rollout-*.jsonl`, `event_msg` lines
  where `payload.type === "token_count"` carry `info.total_token_usage`, a
  cumulative counter. Deltas of that counter are what gets counted: a
  rate-limit refresh re-emits the same `last_token_usage` with an unchanged
  total, and counting `last_token_usage` counted it twice (13 times across 130
  rollouts on the development machine).

Two clocks. The strip and chart use grid-aligned buckets so cells march
instead of jittering; the grid holds `bars - 1` whole buckets plus the partial
newest one, so it reaches back a little less than the window. Every headline
number — totals, rates, turns, activity, split, by-model — is computed over
the exact trailing window from the timestamped points, and the 5-minute and
1-hour rates are exact trailing sums too.
- **Limits** — read straight off the records `omarchy-agent-usage-update` keeps
  in `~/.local/state/omarchy/agents/usage/`. Burn Bar keeps those records
  fresh itself by running `omarchy-agent-usage-update --limits-only claude
  codex` every `limitsRefreshSec` seconds and whenever you open the panel,
  because nothing else guarantees they are: 1.3.0 presented an 8-hour-old
  record with every Claude limit at 0% as live. The time each figure was
  *measured* travels with it — read from Omarchy's probe cache, which only a
  successful probe writes, because the record itself is re-stamped with cached
  limits whenever a probe fails — along with the record's status text. A
  figure the service cannot vouch for — measured too long ago, a window whose
  reset time has passed, a value it could not read — is withheld and
  labelled, never shown as 0%.

Every point carries the input / cache-write / output / cache-read split, and the
collector reports turns, first and last activity and the peak bucket per
agent, which is what the cockpit's tiles and token-mix lines are built from.

Output goes to `~/.local/state/omarchy/burnbar/history.json`. State deliberately
never lives inside the plugin directory: a plugin writing in its own dir makes
Omarchy rebuild every plugin service.

Scanning is incremental twice over: a file whose size and mtime are unchanged
replays its cached contribution, and a file that merely grew is read from the
previous byte offset rather than re-parsed whole — but only if the 48 bytes
just before that offset still read the same, so a rewrite that happens to be
longer is not mistaken for an append. Cached points older than the longest
supported window are pruned, cache entries are validated before they are
believed, and one collector at a time holds a lock on the state directory.
Cold run ~2s, warm ~150ms, which is what makes a 5-second refresh reasonable.

**Local** — `bin/burnbar-local-status` asks Ollama's `/api/ps` at `ollamaUrl`
what is resident and `/api/version` which build is running, then runs one
shell snippet over `ssh localHost` that reads the Jetson's sysfs: GPU load
and clock from the nvgpu devfreq node, the gpu thermal zone, the INA3221
power rails (VDD_IN is the board, VDD_CPU_GPU_CV is what inference moves),
the fan PWM, `/proc/meminfo` for the unified memory, and the ollama
processes' CPU ticks sampled 200 ms apart. `nvidia-smi` exists on a Jetson
and answers `[N/A]` to every query; `tegrastats` needs a second per sample;
sysfs is instant and needs no privilege. Either channel can fail alone:
no HTTP is OFFLINE, no ssh is "no hardware telemetry" with the reason.
Nothing about load is persisted anywhere, so the service keeps its own
rolling ring of samples — that ring *is* the local lane and the cockpit's
traces. `bin/burnbar-local-control` lists installed models via `/api/tags`
and `/api/ps` (on panel open, on refresh, and after every action) and warms
or evicts one through `/api/generate` with `keep_alive` — or through
`/api/embed` for a model whose `/api/show` capabilities say it can only
embed. A warm first runs the box's `ollama-prepare.sh` over ssh to drop its
page cache.

**Local tokens** — Ollama persists no per-request token counts anywhere and
exposes no metrics endpoint (0.15.0: `OLLAMA_DEBUG=1` adds only the
prompt-cache slot line). Every response *does* carry `prompt_eval_count` and
`eval_count`, so `nano/ollama-meter.py` sits on Ollama's public port on the
box, forwards everything byte for byte — streams relayed chunk by chunk —
and writes one journal line per request with the counts off the way out:

```
meter ts=1788649667803 path=/api/generate model=llama3.2:3b status=200 prompt=33 eval=53 ms=2744 client=100.101.176.48
```

Whatever asks — this widget, a voice server, `ollama run` — is counted the
same. The collector reads that unit's journal over ssh, incrementally by
cursor with a server-side filter: one round trip per run. Burn is prompt +
generated; cache reads are 0 because Ollama does not report prompt-cache
hits. Only status 200 counts. The offload share is local burn divided by all
burn over the window. If ssh fails or the meter is not installed, the panel
says so in red rather than showing a confident 0.

**On nano** — `./nano/install.sh [host]` installs, over ssh with passwordless
sudo: the `ollama-meter` unit (DynamicUser, `0.0.0.0:11434` → `127.0.0.1:11435`);
`ollama.service.d/zz-burnbar.conf`, which moves Ollama to loopback `:11435`
and sets `OLLAMA_NUM_PARALLEL=1`; and `/etc/sysctl.d/90-burnbar-ollama.conf`
with `vm.min_free_kbytes = 1048576`. The last two exist because the Jetson's
GPU and its page cache share one pool of memory: a model load that needs a
contiguous 1–2 GiB failed with cudaMalloc out-of-memory every time the cache
had grown since boot, and dropping the cache fixed it every time. One
parallel slot cuts the KV allocation five times; the 1 GiB reserve keeps
that much genuinely free, and three model swaps in a row then loaded without
a drop. The rollback is three commands in the script's header.

Python 3 with no third-party imports is deliberate. Omarchy depends on `uwsm`
and `kitty`, both of which depend on `python`, so `python3` is present on every
Omarchy install; `bun` is not an Omarchy dependency and cannot be assumed.
Version 1.0 shipped its collector on bun and rendered nothing on a stock
install, silently. That is why 1.1 exists.

If the collector cannot run, the strip turns solid red and the tooltip says why.
A wedged run is killed by a 30-second watchdog. It never fails silently.

## Privacy

Burn Bar reads your Claude and Codex transcripts to count tokens. From them it
keeps timestamps, token counts, model names and Claude's opaque message ids,
plus the transcript paths it uses as cache keys — never prompt or reply text.
Its own network traffic is to the Ollama box: HTTP to `ollamaUrl` (default
`http://nano:11434`) to read and control models, and ssh to `localHost`
(default `nano`) to read sysfs, the meter's journal and, on a load, to drop
the page cache. The meter on that box logs one line per request — path,
model, status, two token counts, latency and the client address — and never
the prompt or the reply.

It also runs Omarchy's own usage collectors every few minutes to keep the plan
limits fresh. Those are Omarchy's, not Burn Bar's, and the Claude one contacts
Anthropic's usage endpoint with the sign-in Claude Code already saved; Burn
Bar never touches that credential itself. So "nothing leaves the machine" is
not a claim this README makes. Read [SECURITY.md](SECURITY.md) for the full
list before installing.

## Settings

Set from the Omarchy plugin settings UI, or in `shell.json`.

| Key | Default | Meaning |
|---|---|---|
| `width` | 158 | Widget width in px (raised automatically if too narrow for the configured cells) |
| `bars` | 12 | Cells per cloud agent (the collector makes exactly this many buckets) |
| `windowMinutes` | 360 | How far back the cloud lanes and the cockpit chart reach |
| `refreshIntervalSec` | 5 | Collector cadence |
| `limitsRefreshSec` | 300 | How often Omarchy's usage collectors are asked for fresh plan limits (60–3600) |
| `showGauges` | true | Weekly quota columns bookending the cloud lanes |
| `showLocal` | true | Show the local intelligence lane |
| `localCells` | 9 | Cells in the local lane (= length of the sample ring) |
| `localRefreshMs` | 2500 | Poll interval for the Ollama box: one HTTP call and one ssh round trip each (1000–10000) |
| `localThreshold` | 8 | Load above this counts as actively inferencing |
| `ollamaUrl` | `http://nano:11434` | Where Ollama answers — through the meter when it is installed |
| `localHost` | `nano` | ssh alias of the Ollama box, from your ssh config; must log in without a prompt |
| `meterUnit` | `ollama-meter` | The unit on that box whose journal carries one line per request |
| `emberFlicker` | true | Live flicker on hot cells |
| `sparks` | true | Rising embers while anything is burning |

Bucket length is `windowMinutes / bars`, so the defaults give twelve 30-minute
buckets on the strip and the same twelve in the cockpit chart.

## Tests

```sh
./tests/test.sh
```

Validates the manifest, asserts cell count equals bucket count and local cell
count equals ring length, runs the URL/JSON/ssh/sysfs/meter hardening unit
tests, checks that the local probe degrades to a clean offline object without
reaching for ssh, and runs the
collector against a synthetic fixture under a pinned clock: `message.id`
dedupe keeping the final revision, cache-read exclusion, Codex cumulative
deltas and repeated snapshots, the incremental tail read and its fingerprint,
equal-size and longer rewrites, malformed records and cache entries, junk
percentages, plan-limit measurement time, the exact window against the
grid, and the meter journal: counts summed per request, failed requests
skipped, the offload share.

## Changes

See [CHANGELOG.md](CHANGELOG.md). Current version: 1.5.0.

## Credits

Omarchy is [DHH](https://github.com/dhh)'s and Basecamp's desktop; Burn Bar is
a plugin on top of it and claims none of the underlying shell. The local lane
grew out of the earlier `local-intelligence` plugin and absorbed it in 1.2.0;
in 1.5.0 it moved to a Jetson down the hall. Written by Larry and Dex, two
AIs on Fred Nix's laptops, with Fred Nix. MIT.
