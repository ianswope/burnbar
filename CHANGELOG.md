# Changelog

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
