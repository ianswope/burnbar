import QtQuick
import Quickshell
import Quickshell.Io

// Burn Bar service. Owns two jobs: run the cloud-agent collector on a cadence
// and republish whatever history.json currently says. All extraction logic
// lives in bin/ — this file never parses a transcript itself.
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
  // When each limits list was actually measured (not when its record was last
  // rewritten — Omarchy re-stamps a record with cached limits when its probe
  // fails), and what the record said about itself ("Sign-in expired"). A
  // percentage without its measurement time is how an 8-hour-old 0% got
  // presented as live.
  property real claudeLimitsMeasuredAt: 0
  property real codexLimitsMeasuredAt: 0
  property string claudeLimitsStatus: ""
  property string codexLimitsStatus: ""
  property var claudeByModel: ({})
  property var claudeSplit: ({})
  property var codexSplit: ({})
  property int claudeTurns: 0
  property int codexTurns: 0
  property real claudeFirstAt: 0
  property real claudeLastAt: 0
  property real codexFirstAt: 0
  property real codexLastAt: 0
  property real claudePeakAt: 0
  property real codexPeakAt: 0
  // Exact trailing sums from the collector — tokens in the last 5 and 60
  // minutes measured from timestamped points, not bucket approximations.
  property real claudeTrailing5: 0
  property real claudeTrailing60: 0
  property real codexTrailing5: 0
  property real codexTrailing60: 0
  property real generatedAt: 0
  // real, not int: windowMinutes / bars is fractional for most settings
  // (100 / 12 = 8.33), and an int here silently rounded every rate.
  property real bucketMinutes: 15
  property bool ready: false
  property string lastError: ""
  // True once a collector run has actually failed, so the widget can show
  // a fault instead of an idle animation that looks healthy.
  property bool collectorBroken: false

  // Bumped every time a fresh sample lands with more burn than the last one.
  // The widget listens for this to fire its impact animation.
  property int claudePulse: 0
  property int codexPulse: 0
  property real lastClaudeLatest: 0
  property real lastCodexLatest: 0
  property real lastBucketT: 0

  readonly property string stateDir: (Quickshell.env("XDG_STATE_HOME")
    || Quickshell.env("HOME") + "/.local/state") + "/omarchy/burnbar"
  readonly property string historyPath: stateDir + "/history.json"
  // Resolved from this component's own location, not a hardcoded plugin id:
  // the directory name changes if the plugin is cloned or renamed.
  // A file URL is not a path: a '#' in the install directory stays '%23' in
  // the URL, and python3 would be handed a file that does not exist.
  function localPath(relative) {
    return decodeURIComponent(String(Qt.resolvedUrl(relative)).replace(/^file:\/\//, ""))
  }
  readonly property string collectorPath: localPath("bin/burnbar-collect")

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
  // Plan limits come from records Omarchy's own collectors write. Nothing
  // else guarantees those records are fresh — the agents panel refreshes them
  // on its own schedule, and when it does not, a 0% written hours ago stays
  // 0%. So Burn Bar asks for them on its own clock.
  readonly property int limitsRefreshSec: boundedInt("limitsRefreshSec", 300, 60, 3600)
  // A record older than three refresh intervals (never under 15 min) is stale.
  readonly property int limitsStaleMs: Math.max(900, 3 * limitsRefreshSec) * 1000
  readonly property int windowMinutes: boundedInt("windowMinutes", 360, 30, 1440)
  // Must match BarWidget.cellCount exactly — the widget draws one cell per
  // bucket, so a mismatch makes the strip cover less time than it claims.
  readonly property int bucketCount: boundedInt("bars", 12, 6, 32)

  // Latest (right-most in time) bucket per agent — what "now" is burning.
  readonly property real claudeLatest: buckets.length ? Number(buckets[buckets.length - 1].claude || 0) : 0
  readonly property real codexLatest: buckets.length ? Number(buckets[buckets.length - 1].codex || 0) : 0

  // Re-evaluated every 30s so a record ages into "stale" and a window rolls
  // into "expired" without waiting for a new sample to arrive.
  property int limitsTick: 0
  Timer { interval: 30000; running: true; repeat: true; onTriggered: root.limitsTick++ }

  // A limit whose reset time has passed describes a window that is over. The
  // number may be right for that window; it says nothing about this one.
  function limitExpired(limit) {
    void root.limitsTick
    var t = Date.parse(String((limit && limit.resetsAt) || ""))
    return isFinite(t) && t <= Date.now()
  }
  function limitsStale(updatedAt) {
    void root.limitsTick
    var t = Number(updatedAt) || 0
    return t <= 0 || Date.now() - t > root.limitsStaleMs
  }

  // -1 means "unknown": the record is stale, the matching window has rolled
  // over, the collector could not read the figure, or there is no window by
  // that name at all. A gauge must show nothing rather than a confident 0%,
  // and a session figure must never stand in for a weekly one.
  function limitPercent(limits, needle, measuredAt) {
    if (limitsStale(measuredAt)) return -1
    for (var i = 0; i < limits.length; i++) {
      var label = String(limits[i].label || "")
      if (label.toLowerCase().indexOf(needle) < 0) continue
      if (limitExpired(limits[i])) return -1
      var p = Number(limits[i].percent)
      return isFinite(p) && p >= 0 ? p : -1
    }
    return -1
  }

  // Weekly is the limit that actually bites on both plans.
  readonly property real claudeWeekly: limitPercent(claudeLimits, "weekly", claudeLimitsMeasuredAt)
  readonly property real codexWeekly: limitPercent(codexLimits, "weekly", codexLimitsMeasuredAt)

  // A collect() asked for while one is running is not dropped: the limits
  // refresh asks for one the moment it lands, and that ask must survive an
  // in-flight scan that read the old records.
  property bool collectPending: false
  property bool lastCollectOk: false
  function collect() {
    if (collector.running) { root.collectPending = true; return }
    root.collectPending = false
    collector.launched = false
    collector.command = ["python3", root.collectorPath,
      "--window", String(root.windowMinutes),
      "--buckets", String(root.bucketCount)]
    collector.running = true
    watchdog.restart()
  }

  Process {
    id: collector
    property bool launched: false
    onStarted: launched = true
    // Quickshell never emits exited() for a command that could not start (no
    // python3, say): running just flips back to false. Verified on 0.3.1.
    // Without this the strip's idle animation would call a missing runtime
    // healthy — the exact silent outage 1.1 claimed to have fixed.
    onRunningChanged: {
      if (running || launched) return
      watchdog.stop()
      root.lastError = "python3 not found — Burn Bar needs it to read agent usage"
      root.collectorBroken = true
    }
    stderr: SplitParser {
      onRead: data => { if (String(data).trim() !== "") root.lastError = String(data).slice(0, 240) }
    }
    onExited: function(code) {
      watchdog.stop()
      root.lastCollectOk = code === 0
      if (code !== 0) {
        root.lastError = root.lastError || ("collector exited " + code)
        root.collectorBroken = true
      }
      // The fault is cleared by apply(), once a snapshot has actually been
      // read and validated — not here, where a zero exit says nothing about
      // whether what it wrote can be parsed.
      historyFile.reload()
      if (root.collectPending) root.collect()
    }
  }

  // A wedged collector would otherwise freeze the strip forever, because
  // collect() refuses to start while one is already running.
  Timer {
    id: watchdog
    interval: 30000
    repeat: false
    onTriggered: {
      if (collector.running) {
        console.warn("burnbar: collector exceeded 30s, killing")
        collector.signal(15)
        root.lastError = "collector timed out"
        root.collectorBroken = true
      }
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

  function fault(message) {
    root.lastError = message
    root.collectorBroken = true
  }

  function num(v) {
    var n = Number(v)
    return isFinite(n) ? n : 0
  }

  function apply(content) {
    var parsed
    try {
      parsed = JSON.parse(String(content || ""))
    } catch (e) {
      fault("Unreadable history file")
      return
    }
    // The whole snapshot is validated before a single property changes. A
    // bucket array containing null used to pass, clear the fault, and then
    // throw inside the first binding that read the newest bucket.
    if (!parsed || !Array.isArray(parsed.buckets) || parsed.buckets.length === 0) {
      fault("History file has no buckets")
      return
    }
    for (var i = 0; i < parsed.buckets.length; i++) {
      var bk = parsed.buckets[i]
      if (!bk || typeof bk !== "object" || !isFinite(Number(bk.t))
          || !isFinite(Number(bk.claude)) || !isFinite(Number(bk.codex))) {
        fault("History file has a malformed bucket")
        return
      }
    }
    var c = parsed.claude
    var x = parsed.codex
    if (!c || typeof c !== "object" || !x || typeof x !== "object") {
      fault("History file is missing an agent")
      return
    }

    try {
      root.buckets = parsed.buckets
      root.generatedAt = num(parsed.generatedAt)
      root.bucketMinutes = num(parsed.bucketMinutes) > 0 ? num(parsed.bucketMinutes) : 15
      root.claudeTotal = num(c.total)
      root.codexTotal = num(x.total)
      root.claudePeak = num(c.peak)
      root.codexPeak = num(x.peak)
      root.claudeSessions = num(c.sessions)
      root.codexSessions = num(x.sessions)
      root.claudeLimits = Array.isArray(c.limits) ? c.limits : []
      root.codexLimits = Array.isArray(x.limits) ? x.limits : []
      root.claudeLimitsMeasuredAt = num(c.limitsMeasuredAt)
      root.codexLimitsMeasuredAt = num(x.limitsMeasuredAt)
      root.claudeLimitsStatus = String(c.limitsStatus || "")
      root.codexLimitsStatus = String(x.limitsStatus || "")
      root.claudeByModel = c.byModel && typeof c.byModel === "object" ? c.byModel : ({})
      root.claudeSplit = c.split && typeof c.split === "object" ? c.split : ({})
      root.codexSplit = x.split && typeof x.split === "object" ? x.split : ({})
      root.claudeTurns = num(c.turns)
      root.codexTurns = num(x.turns)
      root.claudeFirstAt = num(c.firstAt)
      root.claudeLastAt = num(c.lastAt)
      root.codexFirstAt = num(x.firstAt)
      root.codexLastAt = num(x.lastAt)
      root.claudePeakAt = num(c.peakAt)
      root.codexPeakAt = num(x.peakAt)
      root.claudeTrailing5 = num(c.trailing ? c.trailing.m5 : 0)
      root.claudeTrailing60 = num(c.trailing ? c.trailing.m60 : 0)
      root.codexTrailing5 = num(x.trailing ? x.trailing.m5 : 0)
      root.codexTrailing60 = num(x.trailing ? x.trailing.m60 : 0)
    } catch (e) {
      fault("History file could not be applied")
      return
    }
    root.ready = true
    if (root.lastCollectOk) {
      root.lastError = ""
      root.collectorBroken = false
    }

    // Fire an impact pulse only when the live bucket actually grew, so a
    // no-op refresh does not make the widget twitch. On a bucket rollover the
    // live value resets toward zero, so compare against 0 for the new bucket
    // instead of the previous bucket's total — otherwise the first burn of
    // every bucket is silently swallowed.
    var latestT = root.buckets.length ? Number(root.buckets[root.buckets.length - 1].t || 0) : 0
    var rolled = latestT !== root.lastBucketT
    if (rolled) {
      root.lastClaudeLatest = 0
      root.lastCodexLatest = 0
      root.lastBucketT = latestT
    }
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

  // ── plan-limit refresh ─────────────────────────────────────────────────────
  // burnbar-collect only copies limits out of the records that
  // omarchy-agent-usage-update maintains; this is what keeps those records
  // fresh. --limits-only reuses any transcript scan under 15 minutes old and
  // the Claude collector keeps a 15s probe cache, so repeated asks are cheap.
  // Only the two agents Burn Bar draws are requested.
  property bool limitsRefreshUnavailable: false
  function refreshLimits() {
    if (limitsRefresher.running || limitsRefreshUnavailable) return
    limitsRefresher.launched = false
    limitsRefresher.running = true
    limitsWatchdog.restart()
  }

  Process {
    id: limitsRefresher
    property bool launched: false
    // The updater backgrounds one subshell per collector and waits on them, so
    // a SIGTERM to the updater alone would orphan the actual probes. setsid
    // gives the updater its own process group and the trap tears that whole
    // group down; a missing updater still surfaces as exit 127 through wait.
    command: ["bash", "-c",
      "setsid omarchy-agent-usage-update --limits-only claude codex & p=$!; "
      + "trap 'kill -TERM -- -$p 2>/dev/null; exit 143' TERM INT; wait $p"]
    onStarted: launched = true
    onRunningChanged: {
      if (running || launched) return
      // bash itself could not start. Nothing sane is left to try this session.
      limitsWatchdog.stop()
      root.limitsRefreshUnavailable = true
      console.warn("burnbar: could not start the plan-limit refresh; limits will not refresh")
    }
    stderr: SplitParser {
      onRead: data => { var s = String(data).trim(); if (s !== "") console.warn("burnbar: " + s) }
    }
    onExited: function(code) {
      limitsWatchdog.stop()
      if (code === 127) {
        // Not an Omarchy box, or its bin dir is off PATH. Stop asking; the
        // panel shows the record's age instead of a retry every cycle.
        root.limitsRefreshUnavailable = true
        console.warn("burnbar: omarchy-agent-usage-update not found; plan limits will not refresh")
        return
      }
      // Whatever it wrote, fold the records into history.json now rather
      // than on the next collector tick.
      root.collect()
    }
  }

  Timer {
    id: limitsWatchdog
    interval: 60000
    repeat: false
    onTriggered: {
      if (limitsRefresher.running) {
        console.warn("burnbar: usage-update exceeded 60s, killing")
        limitsRefresher.signal(15)
      }
    }
  }

  Timer {
    interval: root.limitsRefreshSec * 1000
    running: true
    repeat: true
    triggeredOnStart: true
    onTriggered: root.refreshLimits()
  }
}
