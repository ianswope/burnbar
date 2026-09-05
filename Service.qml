import QtQuick
import Quickshell
import Quickshell.Io

// Burn Bar service. Owns three jobs: run the cloud-agent collector on a cadence,
// republish whatever history.json currently says, and poll the local Ollama
// runner for live inference load. All extraction logic lives in bin/ — this file
// never parses a transcript and never talks HTTP itself.
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
  // When the usage record behind each limits list was written, and what it
  // said about itself ("Sign-in expired", "Waiting for auth"). A percentage
  // without its timestamp is how an 8-hour-old 0% got presented as live.
  property real claudeLimitsUpdatedAt: 0
  property real codexLimitsUpdatedAt: 0
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
  property real generatedAt: 0
  property int bucketMinutes: 15
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
  readonly property string collectorPath:
    String(Qt.resolvedUrl("bin/burnbar-collect")).replace("file://", "")
  readonly property string localStatusPath:
    String(Qt.resolvedUrl("bin/burnbar-local-status")).replace("file://", "")
  readonly property string localControlPath:
    String(Qt.resolvedUrl("bin/burnbar-local-control")).replace("file://", "")

  // ── local intelligence (Ollama) ────────────────────────────────────────────
  // Cloud burn is history reconstructed from transcripts; local burn is a live
  // vital sign with no persistent record anywhere. So the service keeps its own
  // rolling ring of load samples — that ring IS the local half of the strip.
  property bool localOnline: false
  property bool localActive: false
  property real localLoad: 0
  property real localCpu: 0
  property real localGpu: 0
  property int localModelCount: 0
  property string localModel: ""
  property string localBackend: "none"
  property string localError: ""
  property var localModels: []
  property var localModelDetails: []
  property var localHistory: []
  // Power draw ring, same length and cadence as the load ring, so the panel can
  // trace watts over the same seconds the lane shows load.
  property var localPowerHistory: []
  property real localPeakLoad: 0
  property real localPeakPowerW: 0
  property int localPulse: 0
  property bool localReady: false
  property real localSampledAt: 0
  property string localVersion: ""
  property string localGpuName: ""
  property real localPowerW: 0
  property real localPowerLimitW: 0
  property real localTempC: 0
  property real localVramUsedMb: 0
  property real localVramTotalMb: 0
  property real localVramModelsMb: 0
  property real localClockMhz: 0
  property real localClockMaxMhz: 0
  property real localFanPct: 0

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

  readonly property int localRefreshMs: boundedInt("localRefreshMs", 1500, 500, 10000)
  readonly property real localThreshold: Math.max(1, Number(setting("localThreshold", 8)) || 8)
  // Local cells cover far less wall-clock than the cloud cells; that is on
  // purpose. Local load is a now-signal, not a budget.
  readonly property int localCells: boundedInt("localCells", 9, 4, 20)

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

  // -1 means "unknown": the record is stale, or the matching window has rolled
  // over. A gauge must show nothing rather than a confident 0%.
  function limitPercent(limits, needle, updatedAt) {
    if (limitsStale(updatedAt)) return -1
    var pick = null
    for (var i = 0; i < limits.length; i++) {
      var label = String(limits[i].label || "")
      if (label.toLowerCase().indexOf(needle) >= 0) { pick = limits[i]; break }
    }
    if (!pick && limits.length) pick = limits[0]
    if (!pick || limitExpired(pick)) return -1
    return Number(pick.percent || 0)
  }

  // Weekly is the limit that actually bites on both plans.
  readonly property real claudeWeekly: limitPercent(claudeLimits, "weekly", claudeLimitsUpdatedAt)
  readonly property real codexWeekly: limitPercent(codexLimits, "weekly", codexLimitsUpdatedAt)

  function collect() {
    if (collector.running) return
    collector.command = ["python3", root.collectorPath,
      "--window", String(root.windowMinutes),
      "--buckets", String(root.bucketCount)]
    collector.running = true
    watchdog.restart()
  }

  Process {
    id: collector
    stderr: SplitParser {
      onRead: data => { if (String(data).trim() !== "") root.lastError = String(data).slice(0, 240) }
    }
    onExited: function(code) {
      watchdog.stop()
      if (code === 0) {
        root.lastError = ""
        root.collectorBroken = false
      } else {
        // 127 is "command not found" — almost always a missing python3.
        root.lastError = code === 127
          ? "python3 not found — Burn Bar needs it to read agent usage"
          : (root.lastError || ("collector exited " + code))
        root.collectorBroken = true
      }
      historyFile.reload()
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
    root.claudeLimitsUpdatedAt = Number(c.limitsUpdatedAt || 0)
    root.codexLimitsUpdatedAt = Number(x.limitsUpdatedAt || 0)
    root.claudeLimitsStatus = String(c.limitsStatus || "")
    root.codexLimitsStatus = String(x.limitsStatus || "")
    root.claudeByModel = c.byModel || ({})
    root.claudeSplit = c.split || ({})
    root.codexSplit = x.split || ({})
    root.claudeTurns = Number(c.turns || 0)
    root.codexTurns = Number(x.turns || 0)
    root.claudeFirstAt = Number(c.firstAt || 0)
    root.claudeLastAt = Number(c.lastAt || 0)
    root.codexFirstAt = Number(x.firstAt || 0)
    root.codexLastAt = Number(x.lastAt || 0)
    root.claudePeakAt = Number(c.peakAt || 0)
    root.codexPeakAt = Number(x.peakAt || 0)
    root.ready = true

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
    limitsRefresher.command = ["omarchy-agent-usage-update", "--limits-only", "claude", "codex"]
    limitsRefresher.running = true
    limitsWatchdog.restart()
  }

  Process {
    id: limitsRefresher
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

  // ── local runner probe ─────────────────────────────────────────────────────
  // burnbar-local-status sleeps ~200ms sampling /proc for runner CPU ticks, so
  // it must never be re-entered; the running guard is load-bearing, not defensive.
  function pollLocal() {
    if (!localProbe.running) localProbe.running = true
  }

  function applyLocal(raw) {
    var data
    try {
      data = JSON.parse(String(raw || ""))
      if (!data || typeof data !== "object") throw new Error("not an object")
    } catch (e) {
      root.localOnline = false
      root.localActive = false
      root.localLoad = 0
      root.localModelCount = 0
      root.localModel = ""
      root.localBackend = "none"
      root.localError = "Unreadable local status"
      root.localPowerW = 0
      root.localSampledAt = Date.now()
      root.pushLocalSample(0)
      return
    }

    root.localOnline = data.online === true
    root.localLoad = Math.max(0, Math.min(100, Number(data.load || 0)))
    root.localCpu = Math.max(0, Math.min(100, Number(data.cpu || 0)))
    root.localGpu = Math.max(0, Math.min(100, Number(data.gpu || 0)))
    root.localActive = root.localOnline
      && (data.active === true || root.localLoad >= root.localThreshold)
    root.localModelCount = Number(data.modelCount || 0)
    root.localModel = String(data.model || "").slice(0, 128)
    root.localBackend = String(data.backend || "none").slice(0, 32)
    root.localModels = Array.isArray(data.models) ? data.models : []
    root.localModelDetails = Array.isArray(data.modelDetails) ? data.modelDetails : []
    root.localError = String(data.error || "").slice(0, 240)
    root.localVersion = String(data.version || "").slice(0, 32)
    root.localGpuName = String(data.gpuName || "").slice(0, 64)
    root.localPowerW = Math.max(0, Number(data.powerW || 0))
    root.localPowerLimitW = Math.max(0, Number(data.powerLimitW || 0))
    root.localTempC = Math.max(0, Number(data.tempC || 0))
    root.localVramUsedMb = Math.max(0, Number(data.vramUsedMb || 0))
    root.localVramTotalMb = Math.max(0, Number(data.vramTotalMb || 0))
    root.localVramModelsMb = Math.max(0, Number(data.vramModelsMb || 0))
    root.localClockMhz = Math.max(0, Number(data.clockMhz || 0))
    root.localClockMaxMhz = Math.max(0, Number(data.clockMaxMhz || 0))
    root.localFanPct = Math.max(0, Number(data.fanPct || 0))
    root.localReady = true
    root.localSampledAt = Date.now()
    root.pushLocalSample(root.localOnline ? root.localLoad : 0)
  }

  // Newest sample lands at index 0 — the widget draws local time flowing
  // rightward away from the core, mirroring how Codex reads.
  function pushLocalSample(value) {
    var ring = root.localHistory.slice(0, Math.max(0, root.localCells - 1))
    ring.unshift(Number(value) || 0)
    var previous = root.localHistory.length ? Number(root.localHistory[0]) : 0
    root.localHistory = ring
    var power = root.localPowerHistory.slice(0, Math.max(0, root.localCells - 1))
    power.unshift(root.localOnline ? root.localPowerW : 0)
    root.localPowerHistory = power
    root.localPeakLoad = Math.max(root.localPeakLoad, Number(value) || 0)
    root.localPeakPowerW = Math.max(root.localPeakPowerW, root.localPowerW)
    // A pulse means the runner just got busier, not merely that it is busy —
    // otherwise a steady 90% load would strobe the widget forever.
    if (value > previous + 2 && value >= root.localThreshold) root.localPulse++
  }

  Process {
    id: localProbe
    command: ["python3", root.localStatusPath, "--threshold", String(root.localThreshold)]
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: root.applyLocal(text)
    }
    onExited: function(code) { if (code !== 0) root.applyLocal("") }
  }

  Timer {
    interval: root.localRefreshMs
    running: true
    repeat: true
    triggeredOnStart: true
    onTriggered: root.pollLocal()
  }
}
