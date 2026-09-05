# Changelog

## 1.3.2 — 2026-09-05

Adversarial bug hunt (Codex, gpt-6-astra, read-only) over 1.3.1. Seventeen
findings, every one verified against the code or by execution before it was
fixed. In severity order:

### Fixed
- **A refreshed record could give an old Claude figure a fresh timestamp.**
  Omarchy's Claude collector re-stamps its record with *cached* limits when
  the probe fails or the sign-in has lapsed, so 1.3.1's staleness check —
  keyed on the record's `updatedAt` — would have called an eight-hour-old 0%
  fresh again the moment anything rewrote the file. The collector now reads
  `fetchedAtMs` from Omarchy's probe cache, which only a successful probe
  writes, and uses that as the measurement time (`limitsMeasuredAt`). A
  silent fallback (`retryAdvised`) surfaces as "last probe failed, showing
  last known".
- **Quickshell emits no `exited()` for a command that cannot start.** Verified
  on 0.3.1: a missing binary flips `running` back to false and nothing else.
  So the 1.1 promise that a missing `python3` shows a fault was never true,
  and 1.3.1's exit-127 guard on the limits refresh never fired. Every process
  now tracks whether it ever started and treats a start failure as a fault:
  the strip goes red for a missing runtime, the limits refresh gives up
  instead of retrying every cycle, and a model action hands the buttons back.
- **The limits watchdog only killed the wrapper.** `omarchy-agent-usage-update`
  backgrounds one subshell per collector and waits; a SIGTERM to it orphaned
  the probes. It now runs under `setsid` in its own process group and the
  wrapper's trap tears the whole group down.
- **A weekly figure was never substituted with a session one.** `limitPercent`
  fell back to the first limit when no label matched "weekly"; a record with
  only a session window read as an 80% weekly quota. No match is now unknown.
- **Percentages are normalised one by one.** `null` read as 0%, `"bad"` raised
  past the JSON guard and aborted both agents' collection, `"NaN"` wrote a
  file the widget could not parse, and a raw `-1` reached the panel as
  `-100%`. Anything that is not a finite 0..1 fraction is now -1 (unknown)
  in the collector, the panel treats -1 as unknown, and the writer refuses
  NaN.
- **One malformed transcript record no longer aborts collection.** Valid JSON
  with the wrong shape (`"input_tokens": "unknown"`, `"info": "bad"`) raised
  outside the JSON guard and did so again on every run. Extractors now treat
  the whole record as untrusted and skip it.
- **A successful refresh's re-collect was dropped** if a scan was already in
  flight (which had read the old records). Pending collects now coalesce and
  run once the current scan exits.
- **A zero exit no longer clears the fault before the file is validated.** An
  unparseable or shapeless history.json now sets the fault; the fault clears
  only after a snapshot has been applied.
- **A failed local sample invalidates every current reading.** The error path
  used to keep GPU load, VRAM, clocks, temperature, version and the resident
  model list on screen under an OFFLINE header.
- **Local processes have deadlines.** Probe 15s, model list 15s, model action
  3 minutes; each cleans up its own state when it fires.
- **Unrelated GPU work is not inference.** With no model resident the lane
  reads the runner's CPU only and never goes "active". A game beside an idle
  resident model still reads as load; the runner cannot say more.
- **A displayed tooltip now follows the data.** Hover text is a binding, so a
  tooltip left open through a rollover, a new sample or a collector failure
  updates under the pointer instead of keeping its first sentence.
- **`bucketMinutes` was an int.** `windowMinutes / bars` is fractional for
  most settings (100 / 12 = 8.33) and every rate silently used the rounded
  width. Now real; the panel floor is 15 seconds, not a minute.
- **"1 HOUR" covered 31 minutes.** Two 30-minute buckets including the partial
  newest one; the rate now takes enough buckets to cover a full trailing hour.
  Chart hour labels keep their fixed spacing.
- **An equal-length rewrite of a transcript was never rescanned.** The cache
  resumed at EOF when the size matched; equal size with a new mtime is now a
  rewrite.
- **`localThreshold` is clamped 1–50 like the manifest says.** A stray 101
  meant "never inferencing".
- **A missing temperature sensor no longer reads "cool".**

## 1.3.1 — 2026-09-05

### Fixed
- **Claude plan limits showed 0% for hours.** Burn Bar only ever copied the
  limits out of the records `omarchy-agent-usage-update` writes, and nothing
  in Burn Bar kept those records fresh. When the agents panel stopped
  refreshing them, an 8-hour-old record with every Claude limit at 0.0 was
  presented as live, with "resets in now" for a window that had rolled over
  hours earlier. Burn Bar now runs
  `omarchy-agent-usage-update --limits-only claude codex` on its own timer
  (`limitsRefreshSec`, default 300), on panel open, on `R`, and on middle
  click, with a 60s watchdog; the collector's own 15s probe cache keeps that
  cheap.
- **A number nobody can vouch for is withheld, not shown as 0%.** The
  collector now carries each usage record's own `updatedAt` and status text.
  A limit whose reset time has passed reads "window rolled over · awaiting
  refresh" with the percentage withheld; a record older than three refresh
  intervals is flagged stale under the PLAN LIMITS header with its timestamp,
  and any status the record carries ("Sign-in expired", "Waiting for auth")
  is shown there too. The weekly quota columns on the strip go empty and dim
  for an unknown value instead of drawing a green sliver, and their tooltip
  says "unknown · record from 4:12 PM".
- `untilText` no longer says "now" for a time in the past.

## 1.3.0 — 2026-09-04

### Added
- **Cockpit panel.** Two columns at 860px, fitted height, no scrolling — the
  whole instrument in one glance.
- Cloud: burn-over-time chart (Claude up, Codex down, heat-ramp coloured, hour
  labels, breathing live column), tokens-per-minute at three horizons, token
  mix (input / cache-write / output) with cache-read volume and the % the
  cache absorbed, plan limits with both countdown and wall-clock reset time,
  Claude spend by model with share bars, peak-at and last-activity per agent.
- Local: GPU name, backend and Ollama version; GPU load, power draw, temp,
  VRAM used/total with the models' share, SM clock, sample age; load and power
  traces; resident models with params, quant, family, VRAM, context and
  "evicts in" from `expires_at`.
- `burnbar-local-status` returns per-model detail, Ollama version and
  nvidia-smi telemetry (fields the board does not expose read as 0 and hide).
- `burnbar-collect` carries an input / cache-write / output / cache-read split
  per point, plus turns, first/last activity and peak time per agent.

## 1.2.0 — 2026-09-04

### Added
- **Local intelligence lane.** The `io.github.nixfred.local-intelligence` plugin
  is folded in: a reactor core plus a violet strip of live Ollama runner load,
  right of a hard rule. Widget grew 114 → 158, and local takes a quarter of the
  strip rather than a third — free local compute must not read at the same
  weight as metered cloud spend.
- Local model control in the detail panel: pick any installed model and warm it
  into memory or evict it, plus a LOCAL tile and live load bar.
- **Per-section identity and hover.** Each of the three sections carries a
  tinted plate and a baseline in its own hue (Claude orange, Codex teal, local
  violet). Hovering names the section and shows a tooltip for that agent alone,
  instead of one blended tooltip you had to mentally split.
- Sizzle, all of it data-driven: rising sparks whose speed follows total energy,
  an impact shockwave riding outward from the now line, a white-hot core
  filament on genuinely hot cells, an under-glow that brightens with total
  burn, and filament caps on the now line.

### Changed
- The three lanes are now one inline `ThermalLane` component instead of two
  copy-pasted Repeaters, so the visual language cannot drift between agents.
- Weekly quota gauges moved inside the cloud lanes to bookend them, making room
  for local on the outer right.

## 1.1.0 — 2026-09-03

### Changed
- **Collector ported from TypeScript/bun to Python 3 (stdlib only).** `bun` is
  not an Omarchy dependency, so on a stock install the plugin silently rendered
  nothing. Omarchy depends on `uwsm` and `kitty`, both of which depend on
  `python`, so `python3` is always present.
- Collector reads only the appended tail of a grown transcript instead of
  re-parsing the whole file. Warm run 1.4s → ~120ms.
- Widget narrowed to 114 (144px rendered) with 12 cells per agent.

### Fixed
- **Cell count and bucket count could disagree.** The widget drew 16 cells while
  the collector produced 24 buckets, so the strip covered four hours while the
  tooltip advertised six. Both now default to 12 with the same clamp.
- Collector path is resolved from the component's own directory instead of a
  hardcoded plugin id, so a cloned or renamed install still works.
- A failed or missing collector now shows a visible fault state and a tooltip
  reason. Previously the idle animation made a total outage look healthy.
- Added a 30s collector watchdog. A wedged run used to freeze the strip forever,
  because `collect()` refuses to start while one is already running.
- The impact pulse was swallowed on every bucket rollover, because the live
  value resets toward zero when the window advances.
- Ember flicker drops from 20fps to 5fps while idle.

## 1.0.0 — 2026-09-03

Initial release. Mirrored thermal heat map of Claude and Codex token burn with
weekly plan-quota gauges.
