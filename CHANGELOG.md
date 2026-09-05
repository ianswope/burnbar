# Changelog

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
