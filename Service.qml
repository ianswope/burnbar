import QtQuick
import Quickshell
import Quickshell.Io

// Burn Bar service. Owns exactly two jobs: run the collector on a cadence, and
// republish whatever history.json currently says. All extraction logic lives in
// bin/burnbar-collect.ts — this file never parses a transcript.
Item {
  id: root

  property var settings: ({})

  property var buckets: []
  property real claudeTotal: 0
  property real codexTotal: 0
  property real claudePeak: 0
  property real codexPeak: 0
  property int claudeSessions: 0
  property int codexSessions: 0
  property var claudeLimits: []
  property var codexLimits: []
  property var claudeByModel: ({})
  property real generatedAt: 0
  property int bucketMinutes: 15
  property bool ready: false
  property string lastError: ""

  // Bumped every time a fresh sample lands with more burn than the last one.
  // The widget listens for this to fire its impact animation.
  property int claudePulse: 0
  property int codexPulse: 0
  property real lastClaudeLatest: 0
  property real lastCodexLatest: 0

  readonly property string stateDir: (Quickshell.env("XDG_STATE_HOME")
    || Quickshell.env("HOME") + "/.local/state") + "/omarchy/burnbar"
  readonly property string historyPath: stateDir + "/history.json"
  readonly property string collectorPath: Quickshell.env("HOME")
    + "/.config/omarchy/plugins/nixfred.burnbar/bin/burnbar-collect.ts"

  function setting(name, fallback) {
    var value = settings ? settings[name] : undefined
    return value === undefined || value === null ? fallback : value
  }

  function boundedInt(name, fallback, low, high) {
    var n = parseInt(String(setting(name, fallback)), 10)
    if (!isFinite(n)) n = fallback
    return Math.max(low, Math.min(high, n))
  }

  readonly property int intervalSec: boundedInt("refreshIntervalSec", 5, 5, 600)
  readonly property int windowMinutes: boundedInt("windowMinutes", 360, 30, 1440)
  // Must match BarWidget.cellCount exactly — the widget draws one cell per
  // bucket, so a mismatch makes the strip cover less time than it claims.
  readonly property int bucketCount: boundedInt("bars", 12, 6, 32)

  // Latest (right-most in time) bucket per agent — what "now" is burning.
  readonly property real claudeLatest: buckets.length ? Number(buckets[buckets.length - 1].claude || 0) : 0
  readonly property real codexLatest: buckets.length ? Number(buckets[buckets.length - 1].codex || 0) : 0

  function limitPercent(limits, needle) {
    for (var i = 0; i < limits.length; i++) {
      var label = String(limits[i].label || "")
      if (label.toLowerCase().indexOf(needle) >= 0) return Number(limits[i].percent || 0)
    }
    return limits.length ? Number(limits[0].percent || 0) : 0
  }

  // Weekly is the limit that actually bites on both plans.
  readonly property real claudeWeekly: limitPercent(claudeLimits, "weekly")
  readonly property real codexWeekly: limitPercent(codexLimits, "weekly")

  function collect() {
    if (collector.running) return
    collector.command = ["bun", root.collectorPath,
      "--window", String(root.windowMinutes),
      "--buckets", String(root.bucketCount)]
    collector.running = true
  }

  Process {
    id: collector
    stderr: SplitParser {
      onRead: data => { if (String(data).trim() !== "") root.lastError = String(data).slice(0, 240) }
    }
    onExited: function(code) {
      if (code === 0) root.lastError = ""
      historyFile.reload()
    }
  }

  FileView {
    id: historyFile
    path: root.historyPath
    watchChanges: true
    printErrors: false
    onFileChanged: reload()
    onLoaded: root.apply(text())
    onLoadFailed: root.ready = false
  }

  function apply(content) {
    var parsed
    try {
      parsed = JSON.parse(String(content || ""))
    } catch (e) {
      root.lastError = "Unreadable history file"
      return
    }
    if (!parsed || !Array.isArray(parsed.buckets)) return

    root.buckets = parsed.buckets
    root.generatedAt = Number(parsed.generatedAt || 0)
    root.bucketMinutes = Number(parsed.bucketMinutes || 15)

    var c = parsed.claude || {}
    var x = parsed.codex || {}
    root.claudeTotal = Number(c.total || 0)
    root.codexTotal = Number(x.total || 0)
    root.claudePeak = Number(c.peak || 0)
    root.codexPeak = Number(x.peak || 0)
    root.claudeSessions = Number(c.sessions || 0)
    root.codexSessions = Number(x.sessions || 0)
    root.claudeLimits = Array.isArray(c.limits) ? c.limits : []
    root.codexLimits = Array.isArray(x.limits) ? x.limits : []
    root.claudeByModel = c.byModel || ({})
    root.ready = true

    // Fire an impact pulse only when the live bucket actually grew, so a
    // no-op refresh does not make the widget twitch.
    if (root.claudeLatest > root.lastClaudeLatest) root.claudePulse++
    if (root.codexLatest > root.lastCodexLatest) root.codexPulse++
    root.lastClaudeLatest = root.claudeLatest
    root.lastCodexLatest = root.codexLatest
  }

  Timer {
    interval: root.intervalSec * 1000
    running: true
    repeat: true
    triggeredOnStart: true
    onTriggered: root.collect()
  }
}
