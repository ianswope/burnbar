import QtQuick
import QtQuick.Controls
import QtQuick.Layouts
import Quickshell
import Quickshell.Io
import qs.Commons
import qs.Ui

// Detail view for Burn Bar. The bar answers "is something burning right now";
// this is the cockpit: what, how much, how fast, how close to the wall, and
// what the GPU is doing about it — all in one glance, never a scroll.
//
// Two columns, hard split. Left is metered cloud spend in tokens; right is the
// Ollama box (nano, a Jetson on the tailnet) in watts, degrees and megabytes.
// Different money, different units, so they never share a column.
//
// Column widths are set explicitly from the content width, never through the
// layout engine's own preferred-size negotiation: a RowLayout whose children
// size themselves from the row's width is a binding loop, and the first
// version of this panel shipped with the left column bleeding under the right.
Panel {
  id: panel
  moduleName: "nixfred.burnbar"
  manageIpc: false

  required property var widget
  readonly property var svc: widget.svc

  readonly property color foreground: widget.bar ? widget.bar.foreground : Color.foreground
  readonly property color dim: Qt.darker(foreground, 1.5)
  readonly property color faint: Util.alpha(foreground, 0.10)
  readonly property string fontFamily: widget.bar ? widget.bar.fontFamily : Style.font.family

  // Identity for the About line. The manifest is the single source of truth
  // for all three, so bumping a version or moving the repo is one edit there.
  // Constants are a fallback for when the registry is not reachable.
  // The registry is the nice path, but a widget hosted by a REPLACEMENT bar
  // gets a service-less facade with no pluginRegistry hanging off it, and the
  // version then vanished from the About line with nothing to say why — the
  // repo and site only survived because they have literal fallbacks. The
  // manifest sits next to this file and is always readable, so read that and
  // treat the registry as a bonus rather than a requirement.
  property var manifestFromDisk: ({})
  readonly property var pluginManifest: {
    var reg = widget && widget.bar && widget.bar.shell ? widget.bar.shell.pluginRegistry : null
    var fromRegistry = reg && reg.installedPlugins
      ? (reg.installedPlugins[panel.moduleName] || null) : null
    return fromRegistry || manifestFromDisk
  }

  FileView {
    path: String(Qt.resolvedUrl("manifest.json")).replace(/^file:\/\//, "")
    watchChanges: true
    printErrors: false
    onFileChanged: reload()
    onLoaded: {
      try { panel.manifestFromDisk = JSON.parse(text()) || ({}) }
      catch (e) { panel.manifestFromDisk = ({}) }
    }
    onLoadFailed: panel.manifestFromDisk = ({})
  }
  readonly property string pluginVersion: pluginManifest && pluginManifest.version
    ? String(pluginManifest.version) : ""
  readonly property string repoUrl: pluginManifest && pluginManifest.repository
    ? String(pluginManifest.repository) : "https://github.com/nixfred/burnbar"
  readonly property string homeUrl: pluginManifest && pluginManifest.homepage
    ? String(pluginManifest.homepage) : "https://nixfred.com"

  // Width is the remedy, never height: a panel that does not fit is clipped,
  // not scrolled, so the data simply disappears with nothing to say it has.
  // Five cloud cards with a quota bar each, rather than four without: the row
  // was already tight at 1360 and a bar needs width to read as a bar.
  readonly property int panelWidth: Style.space(1480)
  readonly property int columnGap: Style.space(20)

  // Relative times ("3m ago", "evicts in 4m") go stale the moment they are
  // drawn; a 1s tick re-evaluates every binding that reads it.
  property int tick: 0
  Timer { interval: 1000; running: panel.opened; repeat: true; onTriggered: panel.tick++ }

  // ── entrance ──────────────────────────────────────────────────────────────
  // Everything grows into place on open: bars wipe left→right, numbers count
  // up, sections rise a few pixels as they fade in. Data-driven motion after
  // that — the live column breathes, bars ease to new values, a pulse flashes
  // the chart when the collector lands new burn.
  property real reveal: 0
  property int counterEpoch: 0
  property real chartFlash: 0

  NumberAnimation {
    id: revealAnim
    target: panel; property: "reveal"
    from: 0; to: 1; duration: 720; easing.type: Easing.OutCubic
  }
  SequentialAnimation {
    id: chartImpact
    NumberAnimation { target: panel; property: "chartFlash"; to: 1; duration: 80 }
    NumberAnimation { target: panel; property: "chartFlash"; to: 0; duration: 700; easing.type: Easing.OutCubic }
  }
  Connections {
    target: panel.svc
    function onClaudePulseChanged() { if (panel.opened) chartImpact.restart() }
    function onCodexPulseChanged() { if (panel.opened) chartImpact.restart() }
    function onGrokPulseChanged() { if (panel.opened) chartImpact.restart() }
  }

  // Left→right stagger for a row of n bars.
  function wipe(i, n) {
    return Math.max(0, Math.min(1, panel.reveal * 1.5 - (i / Math.max(1, n)) * 0.5))
  }

  onOpenedChanged: {
    if (opened) {
      reveal = 0
      revealAnim.restart()
      counterEpoch++
      refreshLocalModels()
    }
  }

  function switchPanel(direction) {
    if (widget.bar && typeof widget.bar.switchPanelFrom === "function")
      return widget.bar.switchPanelFrom(widget, direction)
    return false
  }

  // ── formatting ────────────────────────────────────────────────────────────
  function untilText(iso) {
    void panel.tick
    var t = Date.parse(String(iso || ""))
    if (!isFinite(t)) return "--"
    var ms = t - Date.now()
    if (ms <= 0) return "rolled over"
    var mins = Math.floor(ms / 60000)
    var days = Math.floor(mins / 1440)
    var hours = Math.floor((mins % 1440) / 60)
    if (days > 0) return days + "d " + hours + "h"
    if (hours > 0) return hours + "h " + (mins % 60) + "m"
    return mins + "m"
  }

  function agoText(ms) {
    void panel.tick
    var t = Number(ms) || 0
    if (t <= 0) return "never"
    var s = Math.max(0, (Date.now() - t) / 1000)
    if (s < 60) return Math.round(s) + "s ago"
    if (s < 3600) return Math.round(s / 60) + "m ago"
    return (s / 3600).toFixed(1) + "h ago"
  }

  function clockText(ms) {
    var t = Number(ms) || 0
    return t > 0 ? Qt.formatTime(new Date(t), "h:mm AP") : "--"
  }

  function dayClockText(iso) {
    var t = Date.parse(String(iso || ""))
    return isFinite(t) ? Qt.formatDateTime(new Date(t), "ddd h:mm AP") : "--"
  }

  function prettyModel(id) {
    return String(id || "")
      .replace("claude-", "")
      .replace(/-\d{8}$/, "")
      .replace(/-/g, " ")
  }

  function sortedModels(byModel) {
    var out = []
    for (var k in byModel) out.push({ id: k, tokens: Number(byModel[k] || 0) })
    out.sort(function(a, b) { return b.tokens - a.tokens })
    return out
  }

  function gb(mb) { return (Number(mb || 0) / 1024).toFixed(1) }

  // ── derived cloud metrics ─────────────────────────────────────────────────
  readonly property var buckets: svc ? svc.buckets : []
  readonly property real bucketMinutes: svc ? Math.max(0.25, svc.bucketMinutes) : 30
  readonly property real windowMinutes: svc ? svc.windowMinutes : 360

  // Rates come from the collector's exact trailing sums — tokens in the last
  // 5 and 60 minutes from timestamped points — and the exact window total.
  // No bucket arithmetic: two 30-minute buckets called "1 HOUR" covered 31 to
  // 61 minutes depending on the clock, and a one-minute denominator floor
  // read 90 tokens in a 30-second bucket as 90/min.
  function trailing5(agent) {
    if (!svc) return 0
    return agent === "claude" ? svc.claudeTrailing5
      : agent === "codex" ? svc.codexTrailing5
      : agent === "grok" ? svc.grokTrailing5
      : agent === "kimi" ? svc.kimiTrailing5
      : svc.localTokensTrailing5
  }
  function trailing60(agent) {
    if (!svc) return 0
    return agent === "claude" ? svc.claudeTrailing60
      : agent === "codex" ? svc.codexTrailing60
      : agent === "grok" ? svc.grokTrailing60
      : agent === "kimi" ? svc.kimiTrailing60
      : svc.localTokensTrailing60
  }
  function windowTotal(agent) {
    if (!svc) return 0
    return agent === "claude" ? svc.claudeTotal
      : agent === "codex" ? svc.codexTotal
      : agent === "grok" ? svc.grokTotal
      : agent === "kimi" ? svc.kimiTotal
      : svc.localTokensTotal
  }
  function rateNow(agent) { return trailing5(agent) / 5 }
  function rateHour(agent) { return trailing60(agent) / 60 }
  function rateWindow(agent) { return windowTotal(agent) / Math.max(1, windowMinutes) }
  readonly property bool localTokens: svc ? svc.localTokensAvailable : false
  readonly property bool showClaude: widget.showClaude
  readonly property bool showCodex: widget.showCodex
  readonly property bool showGrok: widget.showGrok
  readonly property bool showKimi: widget.showKimi
  // The lane needs burn to draw; a plan row only needs a plan. Kimi's tier
  // comes back from /me, so the subscription is known before a single token
  // has gone through it.
  // One builder for the note under a plan limit, so the standalone caption and
  // the line under an agent's rows can never disagree about whether a figure is
  // trustworthy. Empty text means the record is healthy and needs no comment.
  function limitNote(updatedAt, status, help, live, info) {
    void panel.tick
    if (!svc) return { text: "", urgent: false }
    var stale = svc.limitsStale(updatedAt, live)
    var aged = svc.limitsSnapshotAged(updatedAt, live)
    var quiet = !stale && !aged && status === ""
      && !(svc.limitsRefreshUnavailable && live)
    if (quiet) return { text: "", urgent: false }
    var parts = []
    if (status !== "") parts.push(status)
    // Only when a figure is actually withheld: the remedy is noise otherwise.
    if (status !== "" && String(help || "") !== "") parts.push(help)
    var t = Number(updatedAt) || 0
    if (t > 0) parts.push((aged ? "snapshot measured " : "measured ")
      + Qt.formatDateTime(new Date(t), "ddd h:mm AP") + (stale ? "  ·  stale" : ""))
    else parts.push("no measurement time")
    if (svc.limitsRefreshUnavailable && live)
      parts.push("omarchy-agent-usage-update not found, cannot refresh")
    return { text: parts.join("  ·  "),
             urgent: stale || (status !== "" && info !== true) }
  }

  readonly property bool showKimiPlan: showKimi || (svc ? svc.kimiPlanTier !== "" : false)
  readonly property bool showLocal: widget.showLocal
  // The box's name, as the user configured it: what the panel calls the
  // lane wherever it used to say "local". Always known, even offline.
  readonly property string boxName: svc ? svc.localHost : "localhost"
  readonly property string boxLabel: boxName.toUpperCase()
  readonly property real offload: svc ? svc.offloadShare : 0
  function topModel(byModel) {
    var rows = sortedModels(byModel)
    return rows.length ? rows[0].id : ""
  }
  // "30" for whole minutes, "8.3" for fractional buckets.
  function bucketLabel(minutes) {
    var m = Number(minutes) || 0
    return m === Math.round(m) ? String(Math.round(m)) : m.toFixed(1)
  }
  // At most this many rows in a list that can grow without bound. The panel
  // never scrolls; a 30-model install must not push the footer off screen.
  readonly property int maxRows: 6

  function splitTotal(split) {
    return Number(split.input || 0) + Number(split.cacheWrite || 0) + Number(split.output || 0)
  }
  // Cache reads as a share of everything the model touched. It is a token
  // share, not money: cache hits are billed too, at a lower rate.
  function cacheShare(split) {
    var billed = splitTotal(split)
    var read = Number(split.cacheRead || 0)
    return billed + read > 0 ? read / (billed + read) : 0
  }

  // ── local model control ───────────────────────────────────────────────────
  property var localOptions: []
  property string selectedModel: ""
  property bool localBusy: false
  property string localNote: ""

  readonly property bool localOnline: svc ? svc.localOnline : false
  readonly property bool localActive: svc ? svc.localActive : false
  readonly property color localState: !localOnline ? Color.urgent
    : localActive ? widget.localHot : widget.okGreen
  readonly property color powerColor: widget.emberAmber

  function plainText(value, limit) {
    return String(value || "").slice(0, limit).replace(/[<>&]/g, function(character) {
      return character === "<" ? "‹" : character === ">" ? "›" : "＆"
    }).replace(/[\u0000-\u001f\u007f]/g, " ")
  }

  function refreshLocalModels() {
    if (!panel.showLocal || listProc.running || !svc) return
    listProc.command = ["python3", svc.localControlPath, "--url", svc.ollamaUrl, "--host", svc.localHost, "list"]
    listProc.launched = false
    listProc.running = true
    listWatchdog.restart()
  }

  function refreshAll() {
    refreshLocalModels()
    if (svc) { svc.refreshLimits(); svc.collect(); svc.pollLocal() }
  }

  function runLocalAction(action) {
    if (localBusy || selectedModel === "" || !svc) return
    localBusy = true
    localNote = (action === "load" ? "Warming " : "Unloading ") + selectedModel + "…"
    actionProc.command = ["python3", svc.localControlPath, "--url", svc.ollamaUrl, "--host", svc.localHost, action, selectedModel]
    actionProc.launched = false
    actionProc.running = true
    actionWatchdog.restart()
  }

  function parseLocalModels(raw) {
    try {
      var data = JSON.parse(String(raw || ""))
      if (!Array.isArray(data.models)) throw new Error("Invalid model list")
      var options = []
      for (var i = 0; i < Math.min(data.models.length, 128); i++) {
        var m = data.models[i]
        var name = String(m.name || "").slice(0, 256)
        if (name === "") continue
        options.push({
          value: name,
          label: panel.plainText(name, 256) + (m.loaded ? "  • warm" : ""),
          description: [panel.plainText(m.parameters, 64), panel.plainText(m.quantization, 64),
                        m.size > 0 ? (Number(m.size) / 1073741824).toFixed(1) + " GB" : ""]
            .filter(Boolean).join(" · ")
        })
      }
      panel.localOptions = options
      // Reconcile the selection against every list, not just the first: a
      // model removed outside the panel stayed selected and actionable.
      var stillThere = false
      for (var k = 0; k < options.length; k++) if (options[k].value === panel.selectedModel) stillThere = true
      if (!stillThere) panel.selectedModel = options.length > 0 ? options[0].value : ""
    } catch (e) {
      panel.localNote = "Could not read installed models"
    }
  }

  // Quickshell emits no exited() for a command that could not start (no
  // python3): running just flips back to false. Each process tracks whether
  // it ever started so a failed launch still clears busy state and says why.
  Process {
    id: listProc
    property bool launched: false
    stdout: StdioCollector { waitForEnd: true; onStreamFinished: panel.parseLocalModels(text) }
    onStarted: launched = true
    onRunningChanged: if (!running && !launched) { listWatchdog.stop(); panel.localNote = "python3 not found" }
    onExited: listWatchdog.stop()
  }
  Timer {
    id: listWatchdog
    interval: 15000
    repeat: false
    onTriggered: if (listProc.running) { listProc.signal(15); panel.localNote = "Model list timed out" }
  }

  Process {
    id: actionProc
    property bool launched: false
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: {
        try {
          var result = JSON.parse(String(text || ""))
          panel.localNote = panel.plainText(result.ok ? result.message : result.error, 384)
        } catch (e) { panel.localNote = "Ollama action failed" }
      }
    }
    onStarted: launched = true
    onRunningChanged: if (!running && !launched) { actionWatchdog.stop(); panel.localBusy = false; panel.localNote = "python3 not found" }
    onExited: {
      actionWatchdog.stop()
      panel.localBusy = false
      // Ollama reports a model as resident a beat after the call returns.
      settleTimer.restart()
    }
  }
  // Warming a model on the Jetson takes 35-60 s, plus the cache drop before
  // it; three minutes is the budget before the buttons are handed back.
  Timer {
    id: actionWatchdog
    interval: 180000
    repeat: false
    onTriggered: if (actionProc.running) { actionProc.signal(15); panel.localNote = "Ollama action timed out after 3 minutes" }
  }

  Timer {
    id: settleTimer
    interval: 500
    repeat: false
    onTriggered: {
      panel.refreshLocalModels()
      if (panel.svc) panel.svc.pollLocal()
    }
  }

  // ── reusable pieces ───────────────────────────────────────────────────────
  component Caption: Text {
    textFormat: Text.PlainText
    color: panel.dim
    font.family: panel.fontFamily
    font.pixelSize: Style.font.caption
    elide: Text.ElideRight
  }
  // Dim like the rest of the footer, so it reads as provenance rather than a
  // control; underlined on hover so it is still discoverably clickable.
  component Link: Text {
    id: linkText
    property string url: ""
    textFormat: Text.PlainText
    color: linkArea.containsMouse ? panel.foreground : panel.dim
    font.family: panel.fontFamily
    font.pixelSize: Style.font.caption
    font.underline: linkArea.containsMouse
    elide: Text.ElideRight
    MouseArea {
      id: linkArea
      anchors.fill: parent
      hoverEnabled: true
      cursorShape: Qt.PointingHandCursor
      onClicked: if (linkText.url !== "") Quickshell.execDetached(["xdg-open", linkText.url])
    }
  }
  component Body: Text {
    textFormat: Text.PlainText
    color: panel.foreground
    font.family: panel.fontFamily
    font.pixelSize: Style.font.bodySmall
    elide: Text.ElideRight
  }

  // A number that counts up to its target when the panel opens and eases to
  // every new value after that.
  component Counter: Text {
    id: counter
    property real target: 0
    property real shown: 0
    property var format: null
    textFormat: Text.PlainText
    font.family: panel.fontFamily
    text: format ? format(shown) : String(Math.round(shown))
    Behavior on shown {
      id: counterMotion
      NumberAnimation { duration: 800; easing.type: Easing.OutCubic }
    }
    onTargetChanged: shown = target
    Component.onCompleted: { counterMotion.enabled = false; shown = target; counterMotion.enabled = true }
    Connections {
      target: panel
      function onCounterEpochChanged() {
        counterMotion.enabled = false
        counter.shown = 0
        counterMotion.enabled = true
        counter.shown = counter.target
      }
    }
  }

  // Caption over a big number over a thin fill bar. The whole right column is
  // built from these, so every GPU metric reads the same way.
  component StatTile: Rectangle {
    id: tile
    property string caption: ""
    property real value: 0
    property var format: null
    property string unit: ""
    property string sub: ""
    // 0..1 fills the bar; negative hides it (for metrics with no ceiling).
    property real fraction: -1
    property color accent: panel.foreground

    Layout.fillWidth: true
    implicitHeight: Style.space(66)
    radius: Style.cornerRadius
    color: Util.alpha(tile.accent, 0.07)
    border.width: 1
    border.color: Util.alpha(tile.accent, 0.22)

    ColumnLayout {
      anchors.fill: parent
      anchors.margins: Style.space(8)
      spacing: 1
      Caption { text: tile.caption; font.bold: true; Layout.fillWidth: true }
      RowLayout {
        Layout.fillWidth: true
        spacing: Style.space(3)
        Counter {
          target: tile.value
          format: tile.format
          color: tile.accent
          font.pixelSize: Style.font.title
          font.bold: true
        }
        Caption { text: tile.unit; Layout.alignment: Qt.AlignBaseline; Layout.fillWidth: true }
      }
      Caption { text: tile.sub; Layout.fillWidth: true }
      Rectangle {
        Layout.fillWidth: true
        visible: tile.fraction >= 0
        implicitHeight: Style.space(3)
        radius: height / 2
        color: panel.faint
        Rectangle {
          height: parent.height
          radius: height / 2
          width: parent.width * Math.max(0, Math.min(1, tile.fraction)) * panel.reveal
          color: tile.accent
          Behavior on width { NumberAnimation { duration: 320; easing.type: Easing.OutCubic } }
        }
      }
    }
  }

  // A row of thin bars from a ring of samples, newest on the right — the same
  // orientation as the cloud chart, so time reads one way across the panel.
  component Trace: ColumnLayout {
    id: trace
    property string caption: ""
    property string valueText: ""
    property var samples: []        // newest first
    property real max: 100
    property color accent: panel.foreground
    spacing: 3
    Layout.fillWidth: true

    RowLayout {
      Layout.fillWidth: true
      Caption { text: trace.caption; font.bold: true; Layout.fillWidth: true }
      Caption { text: trace.valueText; color: trace.accent; font.bold: true }
    }
    Item {
      id: traceArea
      Layout.fillWidth: true
      implicitHeight: Style.space(26)
      readonly property int n: trace.samples ? trace.samples.length : 0
      readonly property real slot: n > 0 ? width / n : width
      Rectangle {
        anchors.bottom: parent.bottom
        width: parent.width
        height: 1
        color: panel.faint
      }
      Repeater {
        model: traceArea.n
        delegate: Rectangle {
          required property int index
          readonly property real v: Math.max(0, Math.min(1,
            Number(trace.samples[traceArea.n - 1 - index] || 0) / Math.max(1, trace.max)))
          x: index * traceArea.slot
          width: Math.max(1, traceArea.slot - 2)
          anchors.bottom: parent.bottom
          height: Math.max(2, traceArea.height * v * panel.wipe(index, traceArea.n))
          radius: 1
          color: trace.accent
          opacity: 0.35 + 0.65 * (index / Math.max(1, traceArea.n - 1))
          Behavior on height { NumberAnimation { duration: 260; easing.type: Easing.OutCubic } }
        }
      }
    }
  }

  // Thin horizontal gauge that wipes in on open and eases on change.
  component Gauge: Rectangle {
    id: gauge
    property real fraction: 0
    property color accent: panel.foreground
    Layout.fillWidth: true
    implicitHeight: Style.space(5)
    radius: height / 2
    color: panel.faint
    Rectangle {
      anchors.left: parent.left
      height: parent.height
      radius: height / 2
      width: parent.width * Math.max(0, Math.min(1, gauge.fraction)) * panel.reveal
      color: gauge.accent
      Behavior on width { NumberAnimation { duration: 500; easing.type: Easing.OutCubic } }
    }
  }

  KeyboardPanel {
    id: kpanel
    anchorItem: panel.widget.anchorItem
    owner: panel.widget
    bar: panel.widget.bar
    open: panel.opened
    focusTarget: keyCatcher
    contentWidth: fittedContentWidth(panel.panelWidth)
    // Never a Flickable in here: the cap is the screen, and everything below
    // is sized to fit inside it.
    contentHeight: fittedContentHeight(content.implicitHeight, Style.space(960))

    PanelKeyCatcher {
      id: keyCatcher
      anchors.fill: parent
      blocked: modelPicker.popupOpen
      onCloseRequested: panel.widget.close()
      onTabRequested: direction => panel.switchPanel(direction)
      onTextKey: function(text) {
        if (text === "r" || text === "R") panel.refreshAll()
      }

      ColumnLayout {
        id: content
        width: parent.width
        spacing: Style.space(10)

        // ── hero ─────────────────────────────────────────────────────────────
        PanelHero {
          Layout.fillWidth: true
          title: ""
          // "burned", not "billed": this figure deliberately leaves cache
          // reads out, and those are billed too, at a lower rate.
          meta: "frontier tokens burned · last " + panel.widget.windowLabel(panel.windowMinutes) + "  ·  "
            + ((panel.svc
              ? (panel.showClaude ? panel.svc.claudeTurns : 0)
                + (panel.showCodex ? panel.svc.codexTurns : 0)
                + (panel.showGrok ? panel.svc.grokTurns : 0) : 0)) + " turns  ·  "
            + ((panel.svc
              ? (panel.showClaude ? panel.svc.claudeSessions : 0)
                + (panel.showCodex ? panel.svc.codexSessions : 0)
                + (panel.showGrok ? panel.svc.grokSessions : 0) : 0)) + " sessions"
            + (panel.showLocal && panel.localTokens ? "  ·  " + Math.round(panel.offload * 100) + "% kept on " + panel.boxName : "")
          detail: panel.svc
            ? panel.widget.compact(
                (panel.showClaude ? panel.rateNow("claude") : 0)
                + (panel.showCodex ? panel.rateNow("codex") : 0)
                + (panel.showGrok ? panel.rateNow("grok") : 0)) + "/min last 5m  ·  "
              + panel.widget.compact(
                (panel.showClaude ? panel.rateHour("claude") : 0)
                + (panel.showCodex ? panel.rateHour("codex") : 0)
                + (panel.showGrok ? panel.rateHour("grok") : 0)) + "/min last hour  ·  "
              + "active " + panel.agoText(Math.max(
                panel.showClaude ? panel.svc.claudeLastAt : 0,
                panel.showCodex ? panel.svc.codexLastAt : 0,
                panel.showGrok ? panel.svc.grokLastAt : 0))
            : ""
          foreground: panel.widget.claudeHot
          fontFamily: panel.fontFamily
          iconComponent: Component {
            Item {
              implicitWidth: Style.space(112)
              implicitHeight: Style.space(34)
              RowLayout {
                anchors.fill: parent
                spacing: Style.space(6)
                Text {
                  text: "󰈸"
                  textFormat: Text.PlainText
                  color: panel.widget.claudeHot
                  font.family: panel.fontFamily
                  font.pixelSize: Style.font.display
                  // The flame flickers with live burn, like the bar.
                  opacity: 0.75 + 0.25 * Math.sin(panel.widget.emberPhase * 2)
                }
                Counter {
                  target: panel.svc
                    ? (panel.showClaude ? panel.svc.claudeTotal : 0)
                      + (panel.showCodex ? panel.svc.codexTotal : 0)
                      + (panel.showGrok ? panel.svc.grokTotal : 0) : 0
                  format: panel.widget.compact
                  color: panel.widget.claudeHot
                  font.pixelSize: Style.font.displayLarge
                  font.bold: true
                }
              }
            }
          }
          trailingControl: Component {
            PanelActionButton {
              iconText: "󰑐"
              tooltipText: "Refresh everything (R)"
              foreground: panel.foreground
              fontFamily: panel.fontFamily
              onClicked: panel.refreshAll()
            }
          }
        }

        // ── agent tiles, same order as the bar (Claude/Codex/Grok + local) ─
        RowLayout {
          Layout.fillWidth: true
          spacing: Style.space(8)
          opacity: panel.reveal
          transform: Translate { y: (1 - panel.reveal) * 8 }

          // A fixed model of three keys. A model built as a fresh array of
          // values was replaced on every tick, which destroyed and recreated
          // the tiles — and a recreated Counter initialises straight to its
          // target, so the count-up never showed.
          Repeater {
            model: ["claude", "codex", "grok", "kimi", "local"]
            delegate: Rectangle {
              id: tile
              required property string modelData
              readonly property bool isClaude: modelData === "claude"
              readonly property bool isCodex: modelData === "codex"
              readonly property bool isGrok: modelData === "grok"
              readonly property bool isKimi: modelData === "kimi"
              readonly property bool isCloud: isClaude || isCodex || isGrok || isKimi
              readonly property var s: panel.svc
              readonly property color accent: isClaude ? panel.widget.claudeHot
                : isCodex ? panel.widget.codexHot
                : isGrok ? panel.widget.grokHot
                : isKimi ? panel.widget.kimiHot : panel.localState
              // Cloud tiles lead with tokens. Local leads with tokens when the
              // journal gives them; otherwise it falls back to live load.
              readonly property real value: !s ? 0 : isClaude ? s.claudeTotal
                : isCodex ? s.codexTotal
                : isGrok ? s.grokTotal
                : isKimi ? s.kimiTotal
                : panel.localTokens ? s.localTokensTotal : (panel.localOnline ? s.localLoad : 0)
              readonly property var format: (isCloud || panel.localTokens) ? panel.widget.compact
                : function(v) { return panel.localOnline ? Math.round(v) + "%" : "off" }
              readonly property string sub: {
                void panel.tick
                if (!s) return ""
                if (isClaude) return s.claudeTurns + " turns · " + s.claudeSessions + " sessions · "
                  + panel.widget.compact(panel.rateNow("claude")) + "/min"
                if (isCodex) return s.codexTurns + " turns · " + s.codexSessions + " sessions · "
                  + panel.widget.compact(panel.rateNow("codex")) + "/min"
                if (isGrok) return s.grokTurns + " turns · " + s.grokSessions + " sessions · "
                  + panel.widget.compact(panel.rateNow("grok")) + "/min"
                if (isKimi) return s.kimiTurns + " turns · " + s.kimiSessions + " sessions · "
                  + panel.widget.compact(panel.rateNow("kimi")) + "/min"
                if (panel.localTokens) return Math.round(panel.offload * 100) + "% offloaded · "
                  + s.localTokensTurns + " turns · " + panel.widget.compact(panel.rateNow("local")) + "/min"
                if (!panel.localOnline) return "ollama not answering"
                return (s.localActive ? "inferencing" : "idle") + " · " + s.localModelCount + " warm"
                  + (s.localPowerW > 0 ? " · " + s.localPowerW.toFixed(1) + " W" : "")
              }
              readonly property string sub2: {
                void panel.tick
                if (!s) return ""
                if (isClaude) return "peak " + panel.widget.compact(s.claudePeak) + " at " + panel.clockText(s.claudePeakAt)
                  + " · active " + panel.agoText(s.claudeLastAt)
                if (isCodex) return "peak " + panel.widget.compact(s.codexPeak) + " at " + panel.clockText(s.codexPeakAt)
                  + " · active " + panel.agoText(s.codexLastAt)
                if (isGrok) return "peak " + panel.widget.compact(s.grokPeak) + " at " + panel.clockText(s.grokPeakAt)
                  + " · active " + panel.agoText(s.grokLastAt)
                if (isKimi) return "peak " + panel.widget.compact(s.kimiPeak) + " at " + panel.clockText(s.kimiPeakAt)
                  + " · active " + panel.agoText(s.kimiLastAt)
                if (!panel.localOnline) return s.localError
                var live = (s.localActive ? "inferencing " : "idle ") + Math.round(s.localLoad) + "% · " + s.localModelCount + " warm"
                if (panel.localTokens) return live + " · active " + panel.agoText(s.localTokensLastAt)
                return live + " · peak " + Math.round(s.localPeakLoad) + "% · " + s.localPeakPowerW.toFixed(0) + " W"
              }

              // The quota that actually bites, per agent. Kimi meters by the
              // month; the rest by the week. -1 means withheld — stale, expired
              // or never read — and is drawn as "—", never as a confident 0%.
              readonly property real quota: {
                void panel.tick
                if (!s || !isCloud) return -1
                return isClaude ? s.claudeWeekly
                  : isCodex ? s.codexWeekly
                  : isGrok ? s.grokWeekly
                  : s.kimiMonthly
              }
              readonly property string quotaLabel: isClaude || isCodex || isGrok
                ? "weekly" : "monthly"

              visible: (isClaude && panel.showClaude) || (isCodex && panel.showCodex)
                || (isGrok && panel.showGrok) || (isKimi && panel.showKimiPlan)
                || (!isCloud && panel.showLocal)
              Layout.fillWidth: visible
              Layout.preferredWidth: visible ? -1 : 0
              implicitHeight: visible ? Style.space(isCloud ? 94 : 76) : 0
              radius: Style.cornerRadius
              color: Util.alpha(tile.accent, 0.10)
              border.width: 1
              border.color: Util.alpha(tile.accent, 0.30)

              ColumnLayout {
                anchors.fill: parent
                anchors.margins: Style.space(9)
                spacing: 1
                RowLayout {
                  Layout.fillWidth: true
                  Counter {
                    target: tile.value
                    format: tile.format
                    color: tile.accent
                    font.bold: true
                    font.pixelSize: Style.font.display
                  }
                  Item { Layout.fillWidth: true }
                  Caption { text: tile.isCloud ? tile.modelData.toUpperCase() : panel.boxLabel; color: panel.foreground; font.bold: true }
                }
                Caption { text: tile.sub; Layout.fillWidth: true }
                Caption { text: tile.sub2; Layout.fillWidth: true }

                // How close this agent is to its wall, on the row you look at
                // first. Local has no quota, so it keeps the shorter card.
                Item { visible: tile.isCloud; Layout.fillWidth: true; implicitHeight: Style.space(3) }
                RowLayout {
                  visible: tile.isCloud
                  Layout.fillWidth: true
                  spacing: Style.space(6)
                  Caption {
                    text: tile.quotaLabel
                    color: panel.dim
                  }
                  Gauge {
                    fraction: tile.quota >= 0 ? tile.quota : 0
                    accent: tile.quota >= 0 ? panel.widget.gaugeColor(tile.quota) : panel.dim
                    Layout.alignment: Qt.AlignVCenter
                  }
                  Caption {
                    text: tile.quota >= 0 ? Math.round(tile.quota * 100) + "%" : "—"
                    color: tile.quota >= 0 ? panel.widget.gaugeColor(tile.quota) : panel.dim
                    font.bold: true
                    Layout.preferredWidth: Style.space(30)
                    horizontalAlignment: Text.AlignRight
                  }
                }
              }
            }
          }
        }

        // ── the two columns ──────────────────────────────────────────────────
        // Explicit geometry. See the file comment for why this is not a RowLayout.
        Item {
          id: columns
          Layout.fillWidth: true
          implicitHeight: Math.max(cloudCol.implicitHeight, cloudDetailCol.implicitHeight,
            panel.showLocal ? localCol.implicitHeight : 0)
          // Three columns, so the cloud side stops being one tall stack. On a
          // 1080p screen that stack ran off the bottom and took CLAUDE BY
          // MODEL, the status line and the About row with it.
          readonly property int gaps: panel.showLocal ? panel.columnGap * 2 : panel.columnGap
          readonly property int usable: Math.max(1, width - gaps)
          readonly property int leftWidth: panel.showLocal
            ? Math.round(usable * 0.37) : Math.round(usable * 0.52)
          readonly property int midWidth: panel.showLocal
            ? Math.round(usable * 0.35) : usable - leftWidth
          readonly property int rightWidth: panel.showLocal
            ? usable - leftWidth - midWidth : 0
          readonly property int midX: leftWidth + panel.columnGap
          readonly property int rightX: midX + midWidth + panel.columnGap

          // ════ CLOUD ═════════════════════════════════════════════════════════
          ColumnLayout {
            id: cloudCol
            x: 0
            width: columns.leftWidth
            spacing: Style.space(8)
            opacity: panel.reveal
            transform: Translate { y: (1 - panel.reveal) * 10 }

            RowLayout {
              Layout.fillWidth: true
              PanelSectionHeader {
                Layout.fillWidth: true
                text: "BURN OVER TIME  ·  " + panel.bucketLabel(panel.bucketMinutes) + " MIN BUCKETS"
                foreground: panel.foreground
                fontFamily: panel.fontFamily
                elide: Text.ElideRight
              }
              Caption { visible: panel.showClaude; text: "▲ " + panel.widget.compact(panel.svc ? panel.svc.claudePeak : 0); color: panel.widget.claudeHot; font.bold: true }
              Caption { visible: panel.showCodex; text: "▼ " + panel.widget.compact(panel.svc ? panel.svc.codexPeak : 0); color: panel.widget.codexHot; font.bold: true }
              Caption { visible: panel.showGrok; text: "◆ " + panel.widget.compact(panel.svc ? panel.svc.grokPeak : 0); color: panel.widget.grokHot; font.bold: true }
            }

            // Mirrored bars around a midline: Claude rises, Codex falls, both
            // coloured on the heat ramp the bar uses — so the panel and the
            // strip teach each other. Newest on the right, like every trace.
            Item {
              id: chart
              Layout.fillWidth: true
              implicitHeight: Style.space(132)
              clip: true
              readonly property int labelBand: Style.space(14)
              readonly property real plotHeight: height - labelBand
              readonly property real mid: plotHeight / 2
              readonly property int n: panel.buckets.length
              readonly property real slot: n > 0 ? width / n : width
              readonly property real claudeRef: Math.max(1, panel.svc ? panel.svc.claudePeak : 1)
              readonly property real codexRef: Math.max(1, panel.svc ? panel.svc.codexPeak : 1)
              readonly property real grokRef: Math.max(1, panel.svc ? panel.svc.grokPeak : 1)

              Rectangle {
                y: chart.mid
                width: parent.width
                height: 1
                color: Util.alpha(panel.foreground, 0.25)
              }

              Repeater {
                model: chart.n
                delegate: Item {
                  id: col
                  required property int index
                  readonly property var b: panel.buckets[index]
                  readonly property real c: Number(b ? b.claude : 0)
                  readonly property real x_: Number(b ? b.codex : 0)
                  readonly property real g: Number(b ? b.grok : 0)
                  readonly property real cl: Math.min(1, Math.pow(c / chart.claudeRef, 0.6))
                  readonly property real xl: Math.min(1, Math.pow(x_ / chart.codexRef, 0.6))
                  readonly property real gl: Math.min(1, Math.pow(g / chart.grokRef, 0.6))
                  readonly property bool live: index === chart.n - 1
                  readonly property real grow: panel.wipe(index, chart.n)
                  readonly property real barWidth: Math.max(2, chart.slot - 3)
                  x: index * chart.slot
                  width: chart.slot
                  height: chart.height

                  Rectangle {
                    visible: panel.showClaude
                    y: chart.mid - height
                    anchors.horizontalCenter: parent.horizontalCenter
                    width: col.barWidth
                    height: Math.max(col.c > 0 ? 2 : 0, (chart.mid - 3) * col.cl) * col.grow
                    radius: 2
                    color: panel.widget.heat(col.cl, panel.widget.claudeCold, panel.widget.claudeWarm, panel.widget.claudeHot)
                    opacity: 0.55 + 0.45 * (col.index / Math.max(1, chart.n - 1))
                    Behavior on height { NumberAnimation { duration: 320; easing.type: Easing.OutCubic } }
                  }
                  // Grok takes the up-bars when Claude is not on this machine.
                  Rectangle {
                    visible: panel.showGrok && !panel.showClaude
                    y: chart.mid - height
                    anchors.horizontalCenter: parent.horizontalCenter
                    width: col.barWidth
                    height: Math.max(col.g > 0 ? 2 : 0, (chart.mid - 3) * col.gl) * col.grow
                    radius: 2
                    color: panel.widget.heat(col.gl, panel.widget.grokCold, panel.widget.grokWarm, panel.widget.grokHot)
                    opacity: 0.55 + 0.45 * (col.index / Math.max(1, chart.n - 1))
                    Behavior on height { NumberAnimation { duration: 320; easing.type: Easing.OutCubic } }
                  }
                  Rectangle {
                    visible: panel.showCodex
                    y: chart.mid + 1
                    anchors.horizontalCenter: parent.horizontalCenter
                    width: col.barWidth
                    height: Math.max(col.x_ > 0 ? 2 : 0, (chart.mid - 3) * col.xl) * col.grow
                    radius: 2
                    color: panel.widget.heat(col.xl, panel.widget.codexCold, panel.widget.codexWarm, panel.widget.codexHot)
                    opacity: 0.55 + 0.45 * (col.index / Math.max(1, chart.n - 1))
                    Behavior on height { NumberAnimation { duration: 320; easing.type: Easing.OutCubic } }
                  }
                  // Grok rides as a thin rose filament on the midline so the
                  // Claude▲ / Codex▼ mirror stays intact — only when Claude
                  // already owns the up-bars.
                  Rectangle {
                    visible: panel.showGrok && panel.showClaude
                    anchors.horizontalCenter: parent.horizontalCenter
                    y: chart.mid - height / 2
                    width: Math.max(2, col.barWidth * 0.42)
                    height: Math.max(col.g > 0 ? 2 : 0, (chart.mid - 4) * col.gl * 0.55) * col.grow
                    radius: width / 2
                    color: panel.widget.heat(col.gl, panel.widget.grokCold, panel.widget.grokWarm, panel.widget.grokHot)
                    opacity: 0.70 + 0.30 * (col.index / Math.max(1, chart.n - 1))
                    Behavior on height { NumberAnimation { duration: 320; easing.type: Easing.OutCubic } }
                  }
                  // Live column breathes, same as the live cell on the bar, and
                  // flashes when the collector lands new burn.
                  Rectangle {
                    id: liveFrame
                    visible: col.live
                    anchors.horizontalCenter: parent.horizontalCenter
                    width: col.barWidth
                    height: chart.plotHeight
                    radius: 2
                    color: Util.alpha(panel.widget.whiteHot, panel.chartFlash * 0.25)
                    border.width: 1
                    border.color: panel.widget.whiteHot
                    property real breathe: 0
                    opacity: Math.min(1, breathe + panel.chartFlash)
                    SequentialAnimation on breathe {
                      running: col.live && panel.opened
                      loops: Animation.Infinite
                      NumberAnimation { to: 0.45; duration: 900; easing.type: Easing.InOutQuad }
                      NumberAnimation { to: 0.06; duration: 900; easing.type: Easing.InOutQuad }
                    }
                  }
                  Caption {
                    // Hour marks on the bucket that starts each hour, with the
                    // minutes shown when that bucket does not start on the
                    // hour itself (a :30 grid used to label 7:30 as "7 PM").
                    // The last one or two are suppressed so they never crowd
                    // the "now" label.
                    readonly property real t: Number(col.b ? col.b.t : 0)
                    readonly property bool onHour: t > 0 && (t % 3600000) < panel.bucketMinutes * 60000
                    visible: col.live || (onHour && col.index <= chart.n - 3)
                    anchors.bottom: parent.bottom
                    anchors.horizontalCenter: parent.horizontalCenter
                    text: col.live ? "now" : Qt.formatTime(new Date(t), (t % 3600000) === 0 ? "h AP" : "h:mm AP")
                    font.pixelSize: Style.font.caption - 1
                    font.bold: col.live
                    color: col.live ? panel.foreground : panel.dim
                    elide: Text.ElideNone
                  }
                }
              }
            }

            PanelSectionHeader {
              Layout.fillWidth: true
              text: "PLAN LIMITS"
              foreground: panel.foreground
              fontFamily: panel.fontFamily
            }

            // The note behind an agent's limits, when the record is not to be
            // trusted: written too long ago, carrying a status ("Waiting for
            // auth"), or unrefreshable. "" when the record is healthy.
            //
            // An agent with limit rows carries its note under them, so the
            // name is printed once. Only an agent with no rows at all — Kimi,
            // which publishes a tier and no quota — gets a labelled line of
            // its own. Grok used to appear twice for exactly this reason.
            Repeater {
              model: {
                void panel.tick
                var out = []
                if (!panel.svc) return out
                var rows = []
                if (panel.showClaude)
                  rows.push({ agent: "Claude", accent: panel.widget.claudeHot, limits: panel.svc.claudeLimits,
                    updatedAt: panel.svc.claudeLimitsMeasuredAt, status: panel.svc.claudeLimitsStatus, help: panel.svc.claudeLimitsHelp,
                    live: panel.svc.claudeLimitsLive })
                if (panel.showCodex)
                  rows.push({ agent: "Codex", accent: panel.widget.codexHot, limits: panel.svc.codexLimits,
                    updatedAt: panel.svc.codexLimitsMeasuredAt, status: panel.svc.codexLimitsStatus, help: panel.svc.codexLimitsHelp,
                    live: panel.svc.codexLimitsLive })
                if (panel.showGrok)
                  rows.push({ agent: "Grok", accent: panel.widget.grokHot, limits: panel.svc.grokLimits,
                    updatedAt: panel.svc.grokLimitsMeasuredAt, status: panel.svc.grokLimitsStatus, help: panel.svc.grokLimitsHelp,
                    live: panel.svc.grokLimitsLive })
                // Kimi has no limits array at all: the caption carries its tier
                // and says plainly that Kimi publishes no quota, so the row
                // exists without pretending to a percentage.
                if (panel.showKimiPlan)
                  rows.push({ agent: "Kimi", accent: panel.widget.kimiHot, limits: panel.svc.kimiLimits,
                    updatedAt: panel.svc.kimiLimitsMeasuredAt, status: panel.svc.kimiLimitsStatus, help: panel.svc.kimiLimitsHelp,
                    live: panel.svc.kimiLimitsLive, info: panel.svc.kimiLimitsInfo })
                for (var i = 0; i < rows.length; i++) {
                  var r = rows[i]
                  // No record and nothing to say: this agent is simply not
                  // in use here. Do not nag about it.
                  if (r.limits.length === 0 && r.status === "") continue
                  // An agent with rows of its own carries the note under them;
                  // printing it here too is what made Grok read as two agents.
                  if (r.limits.length > 0) continue
                  var note = panel.limitNote(r.updatedAt, r.status, r.help, r.live, r.info)
                  if (note.text === "") continue
                  r.text = note.text
                  r.urgent = note.urgent
                  out.push(r)
                }
                return out
              }
              delegate: RowLayout {
                required property var modelData
                Layout.fillWidth: true
                spacing: Style.space(6)
                Body { text: modelData.agent; color: modelData.accent; Layout.preferredWidth: Style.space(48) }
                Caption {
                  text: modelData.text
                  color: modelData.urgent === false ? panel.dim : Color.urgent
                  Layout.fillWidth: true
                }
              }
            }

            Repeater {
              model: {
                var out = []
                var c = panel.svc ? panel.svc.claudeLimits : []
                var x = panel.svc ? panel.svc.codexLimits : []
                var g = panel.svc ? panel.svc.grokLimits : []
                var cAt = panel.svc ? panel.svc.claudeLimitsMeasuredAt : 0
                var xAt = panel.svc ? panel.svc.codexLimitsMeasuredAt : 0
                var gAt = panel.svc ? panel.svc.grokLimitsMeasuredAt : 0
                var cLive = panel.svc ? panel.svc.claudeLimitsLive : true
                var xLive = panel.svc ? panel.svc.codexLimitsLive : true
                var gLive = panel.svc ? panel.svc.grokLimitsLive : false
                var km = panel.svc ? panel.svc.kimiLimits : []
                var kAt = panel.svc ? panel.svc.kimiLimitsMeasuredAt : 0
                var kLive = panel.svc ? panel.svc.kimiLimitsLive : true
                if (panel.showClaude)
                  for (var i = 0; i < c.length; i++)
                    out.push({ agent: "Claude", accent: panel.widget.claudeHot, limit: c[i], updatedAt: cAt, live: cLive })
                if (panel.showCodex)
                  for (var j = 0; j < x.length; j++)
                    out.push({ agent: "Codex", accent: panel.widget.codexHot, limit: x[j], updatedAt: xAt, live: xLive })
                if (panel.showGrok)
                  for (var k = 0; k < g.length; k++)
                    out.push({ agent: "Grok", accent: panel.widget.grokHot, limit: g[k], updatedAt: gAt, live: gLive })
                if (panel.showKimiPlan)
                  for (var q = 0; q < km.length; q++)
                    out.push({ agent: "Kimi", accent: panel.widget.kimiHot, limit: km[q], updatedAt: kAt, live: kLive })
                // The note belongs under the rows it describes, on the last of
                // them, so the agent's name is printed exactly once.
                for (var n = 0; n < out.length; n++) out[n].note = ""
                var seen = {}
                for (var m = out.length - 1; m >= 0; m--) {
                  if (seen[out[m].agent]) continue
                  seen[out[m].agent] = true
                  var note = panel.limitNote(out[m].updatedAt,
                    out[m].agent === "Claude" ? (panel.svc ? panel.svc.claudeLimitsStatus : "")
                    : out[m].agent === "Codex" ? (panel.svc ? panel.svc.codexLimitsStatus : "")
                    : out[m].agent === "Kimi" ? (panel.svc ? panel.svc.kimiLimitsStatus : "")
                    : (panel.svc ? panel.svc.grokLimitsStatus : ""),
                    out[m].agent === "Claude" ? (panel.svc ? panel.svc.claudeLimitsHelp : "")
                    : out[m].agent === "Codex" ? (panel.svc ? panel.svc.codexLimitsHelp : "")
                    : out[m].agent === "Kimi" ? (panel.svc ? panel.svc.kimiLimitsHelp : "")
                    : (panel.svc ? panel.svc.grokLimitsHelp : ""),
                    out[m].live,
                    out[m].agent === "Kimi" ? (panel.svc ? panel.svc.kimiLimitsInfo : false) : false)
                  out[m].note = note.text
                  out[m].noteUrgent = note.urgent
                }
                return out
              }
              delegate: ColumnLayout {
                id: limitRow
                required property var modelData
                Layout.fillWidth: true
                spacing: 2

                // A window whose reset time has passed is over; the figure
                // describes a period that is finished. A record older than
                // the staleness bound may describe anything. Either way the
                // percentage is withheld, not shown as a live 0%.
                readonly property bool expired: {
                  void panel.tick
                  return panel.svc ? panel.svc.limitExpired(modelData.limit) : false
                }
                readonly property bool stale: {
                  void panel.tick
                  return panel.svc ? panel.svc.limitsStale(modelData.updatedAt, modelData.live) : true
                }
                // The collector marks a figure it could not read as -1; that
                // is unknown too, not -100%.
                readonly property bool unknown: expired || stale || !(Number(modelData.limit.percent) >= 0)
                readonly property real fraction: unknown ? 0 : Number(modelData.limit.percent)

                RowLayout {
                  Layout.fillWidth: true
                  spacing: Style.space(6)
                  Body { text: modelData.agent; color: modelData.accent; Layout.preferredWidth: Style.space(48) }
                  Body { text: modelData.limit.label; Layout.fillWidth: true }
                  Caption {
                    text: limitRow.expired
                      ? "window rolled over  ·  awaiting refresh"
                      : "resets in " + panel.untilText(modelData.limit.resetsAt)
                        + "  ·  " + panel.dayClockText(modelData.limit.resetsAt)
                    color: limitRow.expired ? Color.urgent : panel.dim
                  }
                  Body {
                    text: limitRow.unknown ? "—" : Math.round(Number(modelData.limit.percent) * 100) + "%"
                    color: limitRow.unknown ? panel.dim : panel.widget.gaugeColor(Number(modelData.limit.percent))
                    font.bold: true
                    Layout.preferredWidth: Style.space(34)
                    horizontalAlignment: Text.AlignRight
                  }
                }
                Gauge {
                  fraction: limitRow.fraction
                  accent: limitRow.unknown ? panel.dim : panel.widget.gaugeColor(Number(modelData.limit.percent))
                }
                // Why this agent's figures are or are not to be trusted, under
                // the rows it applies to rather than as a second agent above.
                Caption {
                  visible: String(modelData.note || "") !== ""
                  Layout.fillWidth: true
                  Layout.leftMargin: Style.space(48) + Style.space(6)
                  text: modelData.note || ""
                  color: modelData.noteUrgent === true ? Color.urgent : panel.dim
                  elide: Text.ElideRight
                }
              }
            }
          }

          // ════ CLOUD DETAIL ══════════════════════════════════════════════════
          // Rates, mix and per-model bars. Its own column purely so the cloud
          // side is two short stacks instead of one that overruns the screen.
          ColumnLayout {
            id: cloudDetailCol
            x: columns.midX
            width: columns.midWidth
            spacing: Style.space(8)
            opacity: panel.reveal
            transform: Translate { y: (1 - panel.reveal) * 10 }

            // Rates: tokens per minute, three horizons, both agents.
            GridLayout {
              Layout.fillWidth: true
              columns: 4
              columnSpacing: Style.space(8)
              rowSpacing: 2
              Caption { text: "RATE  ·  TOKENS / MIN"; font.bold: true; Layout.fillWidth: true }
              Caption { text: "5 MIN"; font.bold: true; Layout.preferredWidth: Style.space(58); horizontalAlignment: Text.AlignRight }
              Caption { text: "1 HOUR"; font.bold: true; Layout.preferredWidth: Style.space(58); horizontalAlignment: Text.AlignRight }
              Caption { text: panel.widget.windowLabel(panel.windowMinutes).toUpperCase(); font.bold: true; Layout.preferredWidth: Style.space(58); horizontalAlignment: Text.AlignRight }

              Body { visible: panel.showClaude; text: "Claude"; color: panel.widget.claudeHot; Layout.fillWidth: true }
              Counter { visible: panel.showClaude; target: panel.rateNow("claude"); format: panel.widget.compact; color: panel.foreground; font.bold: true; font.pixelSize: Style.font.bodySmall; Layout.preferredWidth: Style.space(58); horizontalAlignment: Text.AlignRight }
              Counter { visible: panel.showClaude; target: panel.rateHour("claude"); format: panel.widget.compact; color: panel.foreground; font.pixelSize: Style.font.bodySmall; Layout.preferredWidth: Style.space(58); horizontalAlignment: Text.AlignRight }
              Counter { visible: panel.showClaude; target: panel.rateWindow("claude"); format: panel.widget.compact; color: panel.foreground; font.pixelSize: Style.font.bodySmall; Layout.preferredWidth: Style.space(58); horizontalAlignment: Text.AlignRight }

              Body { visible: panel.showCodex; text: "Codex"; color: panel.widget.codexHot; Layout.fillWidth: true }
              Counter { visible: panel.showCodex; target: panel.rateNow("codex"); format: panel.widget.compact; color: panel.foreground; font.bold: true; font.pixelSize: Style.font.bodySmall; Layout.preferredWidth: Style.space(58); horizontalAlignment: Text.AlignRight }
              Counter { visible: panel.showCodex; target: panel.rateHour("codex"); format: panel.widget.compact; color: panel.foreground; font.pixelSize: Style.font.bodySmall; Layout.preferredWidth: Style.space(58); horizontalAlignment: Text.AlignRight }
              Counter { visible: panel.showCodex; target: panel.rateWindow("codex"); format: panel.widget.compact; color: panel.foreground; font.pixelSize: Style.font.bodySmall; Layout.preferredWidth: Style.space(58); horizontalAlignment: Text.AlignRight }

              Body { visible: panel.showGrok; text: "Grok"; color: panel.widget.grokHot; Layout.fillWidth: true }
              Counter { visible: panel.showGrok; target: panel.rateNow("grok"); format: panel.widget.compact; color: panel.foreground; font.bold: true; font.pixelSize: Style.font.bodySmall; Layout.preferredWidth: Style.space(58); horizontalAlignment: Text.AlignRight }
              Counter { visible: panel.showGrok; target: panel.rateHour("grok"); format: panel.widget.compact; color: panel.foreground; font.pixelSize: Style.font.bodySmall; Layout.preferredWidth: Style.space(58); horizontalAlignment: Text.AlignRight }
              Counter { visible: panel.showGrok; target: panel.rateWindow("grok"); format: panel.widget.compact; color: panel.foreground; font.pixelSize: Style.font.bodySmall; Layout.preferredWidth: Style.space(58); horizontalAlignment: Text.AlignRight }

              Body { visible: panel.showLocal && panel.localTokens; text: panel.boxName; color: panel.widget.localHot; Layout.fillWidth: true }
              Counter { visible: panel.showLocal && panel.localTokens; target: panel.rateNow("local"); format: panel.widget.compact; color: panel.foreground; font.bold: true; font.pixelSize: Style.font.bodySmall; Layout.preferredWidth: Style.space(58); horizontalAlignment: Text.AlignRight }
              Counter { visible: panel.showLocal && panel.localTokens; target: panel.rateHour("local"); format: panel.widget.compact; color: panel.foreground; font.pixelSize: Style.font.bodySmall; Layout.preferredWidth: Style.space(58); horizontalAlignment: Text.AlignRight }
              Counter { visible: panel.showLocal && panel.localTokens; target: panel.rateWindow("local"); format: panel.widget.compact; color: panel.foreground; font.pixelSize: Style.font.bodySmall; Layout.preferredWidth: Style.space(58); horizontalAlignment: Text.AlignRight }
            }

            PanelSectionHeader {
              Layout.fillWidth: true
              text: "TOKEN MIX  ·  INPUT / CACHE WRITE / OUTPUT"
              foreground: panel.foreground
              fontFamily: panel.fontFamily
              elide: Text.ElideRight
            }

            // What burned, by kind — and how much of everything the model
            // touched came out of the cache instead. That second number is the
            // one people never think to look at and always want once they
            // have seen it. It is a token share; cache hits still cost money.
            Repeater {
              model: {
                var rows = []
                if (panel.showClaude)
                  rows.push({ name: "Claude", accent: panel.widget.claudeHot, split: panel.svc ? panel.svc.claudeSplit : ({}) })
                if (panel.showCodex)
                  rows.push({ name: "Codex", accent: panel.widget.codexHot, split: panel.svc ? panel.svc.codexSplit : ({}) })
                if (panel.showGrok)
                  rows.push({ name: "Grok", accent: panel.widget.grokHot, split: panel.svc ? panel.svc.grokSplit : ({}) })
                // Local: evaluated prompt as "in", generated as "out", the
                // reused prefix as the cache read. There is no cache write.
                if (panel.showLocal && panel.localTokens)
                  rows.push({ name: panel.boxName, accent: panel.widget.localHot, split: panel.svc.localTokensSplit })
                return rows
              }
              delegate: ColumnLayout {
                required property var modelData
                readonly property real total: Math.max(1, panel.splitTotal(modelData.split))
                Layout.fillWidth: true
                spacing: 2
                RowLayout {
                  Layout.fillWidth: true
                  spacing: Style.space(6)
                  Body { text: modelData.name; color: modelData.accent; Layout.preferredWidth: Style.space(48) }
                  Caption {
                    Layout.fillWidth: true
                    text: "in " + panel.widget.compact(modelData.split.input || 0)
                      + " · cache-w " + panel.widget.compact(modelData.split.cacheWrite || 0)
                      + " · out " + panel.widget.compact(modelData.split.output || 0)
                  }
                  Caption {
                    text: "cache read " + panel.widget.compact(modelData.split.cacheRead || 0)
                      + " · " + Math.round(panel.cacheShare(modelData.split) * 100) + "% of all input"
                    color: modelData.accent
                    font.bold: true
                  }
                }
                Item {
                  Layout.fillWidth: true
                  implicitHeight: Style.space(7)
                  Rectangle { anchors.fill: parent; radius: height / 2; color: panel.faint }
                  Row {
                    id: mixRow
                    anchors.fill: parent
                    readonly property real grow: panel.reveal
                    Rectangle {
                      height: parent.height
                      width: parent.width * Number(modelData.split.input || 0) / total * mixRow.grow
                      color: Util.alpha(modelData.accent, 0.45)
                      Behavior on width { NumberAnimation { duration: 500; easing.type: Easing.OutCubic } }
                    }
                    Rectangle {
                      height: parent.height
                      width: parent.width * Number(modelData.split.cacheWrite || 0) / total * mixRow.grow
                      color: Util.alpha(modelData.accent, 0.75)
                      Behavior on width { NumberAnimation { duration: 500; easing.type: Easing.OutCubic } }
                    }
                    Rectangle {
                      height: parent.height
                      width: parent.width * Number(modelData.split.output || 0) / total * mixRow.grow
                      color: modelData.accent
                      Behavior on width { NumberAnimation { duration: 500; easing.type: Easing.OutCubic } }
                    }
                  }
                }
              }
            }

            PanelSectionHeader {
              Layout.fillWidth: true
              text: "CLAUDE BY MODEL"
              foreground: panel.foreground
              fontFamily: panel.fontFamily
              visible: panel.showClaude && modelRepeater.count > 0
            }

            Repeater {
              id: modelRepeater
              readonly property var rows: panel.showClaude
                ? panel.sortedModels(panel.svc ? panel.svc.claudeByModel : ({})) : []
              model: rows.slice(0, panel.maxRows)
              delegate: RowLayout {
                required property var modelData
                readonly property real share: panel.svc && panel.svc.claudeTotal > 0
                  ? modelData.tokens / panel.svc.claudeTotal : 0
                Layout.fillWidth: true
                spacing: Style.space(8)
                Body { text: panel.prettyModel(modelData.id); Layout.preferredWidth: Style.space(110) }
                Gauge { fraction: share; accent: panel.widget.claudeHot }
                Caption { text: Math.round(share * 100) + "%"; Layout.preferredWidth: Style.space(30); horizontalAlignment: Text.AlignRight }
                Body { text: panel.widget.compact(modelData.tokens); color: panel.widget.claudeHot; font.bold: true; Layout.preferredWidth: Style.space(44); horizontalAlignment: Text.AlignRight }
              }
            }
            Caption {
              visible: modelRepeater.rows.length > panel.maxRows
              text: "+ " + (modelRepeater.rows.length - panel.maxRows) + " more, smaller"
              Layout.fillWidth: true
            }

            PanelSectionHeader {
              Layout.fillWidth: true
              text: "GROK BY MODEL"
              foreground: panel.foreground
              fontFamily: panel.fontFamily
              visible: panel.showGrok && grokModelRepeater.count > 0
            }

            Repeater {
              id: grokModelRepeater
              readonly property var rows: panel.showGrok
                ? panel.sortedModels(panel.svc ? panel.svc.grokByModel : ({})) : []
              model: rows.slice(0, panel.maxRows)
              delegate: RowLayout {
                required property var modelData
                readonly property real share: panel.svc && panel.svc.grokTotal > 0
                  ? modelData.tokens / panel.svc.grokTotal : 0
                Layout.fillWidth: true
                spacing: Style.space(8)
                Body { text: panel.prettyModel(modelData.id); Layout.preferredWidth: Style.space(110) }
                Gauge { fraction: share; accent: panel.widget.grokHot }
                Caption { text: Math.round(share * 100) + "%"; Layout.preferredWidth: Style.space(30); horizontalAlignment: Text.AlignRight }
                Body { text: panel.widget.compact(modelData.tokens); color: panel.widget.grokHot; font.bold: true; Layout.preferredWidth: Style.space(44); horizontalAlignment: Text.AlignRight }
              }
            }
            Caption {
              visible: grokModelRepeater.rows.length > panel.maxRows
              text: "+ " + (grokModelRepeater.rows.length - panel.maxRows) + " more, smaller"
              Layout.fillWidth: true
            }
          }

          // ════ LOCAL ═════════════════════════════════════════════════════════
          ColumnLayout {
            id: localCol
            visible: panel.showLocal
            x: columns.rightX
            width: columns.rightWidth
            spacing: Style.space(8)
            opacity: panel.reveal
            transform: Translate { y: (1 - panel.reveal) * 10 }

            RowLayout {
              Layout.fillWidth: true
              spacing: Style.space(8)
              // Reactor glyph, same language as the bar.
              Item {
                implicitWidth: Style.space(26)
                implicitHeight: Style.space(26)
                Rectangle {
                  anchors.centerIn: parent
                  width: parent.width * (0.8 + 0.3 * Math.min(1, (panel.svc ? panel.svc.localLoad : 0) / 100))
                  height: width; radius: width / 2
                  color: panel.localState; opacity: panel.localActive ? 0.30 : 0.14
                  Behavior on width { NumberAnimation { duration: 320 } }
                }
                Rectangle {
                  anchors.centerIn: parent
                  width: parent.width * 0.58; height: width; radius: width / 2
                  color: panel.localState
                  Behavior on color { ColorAnimation { duration: 260 } }
                  SequentialAnimation on scale {
                    running: panel.localActive && panel.opened
                    loops: Animation.Infinite
                    NumberAnimation { to: 1.14; duration: 480; easing.type: Easing.InOutSine }
                    NumberAnimation { to: 0.94; duration: 480; easing.type: Easing.InOutSine }
                  }
                }
                Rectangle {
                  anchors.centerIn: parent
                  width: parent.width * 0.24; height: width; radius: width / 2
                  color: panel.widget.bar ? panel.widget.bar.background : Color.background
                }
              }
              ColumnLayout {
                Layout.fillWidth: true
                spacing: 0
                Caption {
                  Layout.fillWidth: true
                  text: panel.boxLabel + "  ·  " + (!panel.localOnline ? "OFFLINE" : panel.localActive ? "INFERENCING" : "IDLE")
                  color: panel.localState
                  font.bold: true
                }
                // Residency came over HTTP; the hardware line comes over ssh
                // and can be missing on its own. Say which, in red, rather
                // than showing a board full of zeros.
                Caption {
                  Layout.fillWidth: true
                  color: panel.svc && panel.localOnline && panel.svc.localTelemetryError !== "" ? Color.urgent : panel.dim
                  text: !panel.svc ? ""
                    : panel.localOnline && panel.svc.localTelemetryError !== ""
                      ? "no hardware telemetry  ·  " + panel.svc.localTelemetryError
                        + (panel.svc.localVersion !== "" ? "  ·  ollama " + panel.svc.localVersion : "")
                      : (panel.svc.localGpuName !== "" ? panel.svc.localGpuName : "no telemetry yet")
                        + "  ·  " + String(panel.svc.localBackend).toUpperCase()
                        + (panel.svc.localVersion !== "" ? "  ·  ollama " + panel.svc.localVersion : "")
                }
              }
            }

            // ── local tokens and the offload share ─────────────────────────
            // The headline of this column: how much burned here instead of at
            // a frontier model, in the same unit as the cloud tiles, and what
            // share of everything that burned that was.
            PanelSectionHeader {
              Layout.fillWidth: true
              text: panel.localTokens
                ? panel.boxLabel + " TOKENS  ·  " + Math.round(panel.offload * 100) + "% OFFLOADED FROM FRONTIER"
                : panel.boxLabel + " TOKENS  ·  NO RECORD"
              foreground: panel.foreground
              fontFamily: panel.fontFamily
              elide: Text.ElideRight
            }
            Gauge {
              visible: panel.localTokens
              fraction: panel.offload
              accent: panel.widget.localHot
            }
            Caption {
              Layout.fillWidth: true
              wrapMode: Text.WordWrap
              elide: Text.ElideNone
              color: panel.localTokens ? panel.dim : Color.urgent
              text: {
                void panel.tick
                var s = panel.svc
                if (!s) return ""
                if (!panel.localTokens) return s.localTokensReason !== ""
                  ? s.localTokensReason
                  : "the Ollama journal is not readable from this account"
                var sp = s.localTokensSplit || {}
                var top = panel.topModel(s.localTokensByModel)
                return panel.widget.compact(s.localTokensTotal) + " tokens burned on " + panel.boxName + " · "
                  + s.localTokensTurns + " turns · prompt " + panel.widget.compact(sp.input || 0)
                  + " · generated " + panel.widget.compact(sp.output || 0)
                  + " · cached " + panel.widget.compact(sp.cacheRead || 0)
                  + (top !== "" ? " · mostly " + panel.plainText(top, 48) : "")
              }
            }

            // Jetson telemetry, two across so every tile has room for its
            // unit and sub-line. A metric the board does not expose reads as
            // 0 and the tile hides its bar rather than drawing a full or
            // empty one.
            GridLayout {
              Layout.fillWidth: true
              columns: 2
              columnSpacing: Style.space(6)
              rowSpacing: Style.space(6)

              StatTile {
                caption: "GPU LOAD"
                value: panel.svc ? panel.svc.localGpu : 0
                unit: "%"
                sub: "runner cpu " + (panel.svc ? Math.round(panel.svc.localCpu) : 0) + "%"
                fraction: panel.svc ? panel.svc.localGpu / 100 : 0
                accent: panel.localState
              }
              StatTile {
                // VDD_IN: the whole board at the barrel jack. The CPU/GPU/CV
                // rail is the part inference moves, so it rides underneath.
                caption: "POWER DRAW"
                value: panel.svc ? panel.svc.localPowerW : 0
                format: function(v) { return v > 0 ? v.toFixed(1) : "--" }
                unit: "W"
                sub: (panel.svc && panel.svc.localGpuRailW > 0 ? "cpu/gpu rail " + panel.svc.localGpuRailW.toFixed(1) + " W · " : "")
                  + (panel.svc && panel.svc.localPowerLimitW > 0
                    ? "limit " + Math.round(panel.svc.localPowerLimitW) + " W"
                    : "peak " + (panel.svc ? panel.svc.localPeakPowerW.toFixed(1) : 0) + " W")
                fraction: panel.svc && panel.svc.localPowerLimitW > 0
                  ? panel.svc.localPowerW / panel.svc.localPowerLimitW
                  : (panel.svc && panel.svc.localPeakPowerW > 0 ? panel.svc.localPowerW / panel.svc.localPeakPowerW : -1)
                accent: panel.powerColor
              }
              StatTile {
                caption: "TEMPERATURE"
                value: panel.svc ? panel.svc.localTempC : 0
                format: function(v) { return v > 0 ? String(Math.round(v)) : "--" }
                unit: "°C"
                sub: panel.svc && panel.svc.localFanPct > 0 ? "fan " + Math.round(panel.svc.localFanPct) + "%"
                  : (!panel.svc || panel.svc.localTempC <= 0 ? "no sensor reading"
                    : panel.svc.localTempC >= 85 ? "throttle territory"
                    : panel.svc.localTempC >= 70 ? "warm" : "cool")
                fraction: panel.svc && panel.svc.localTempC > 0 ? panel.svc.localTempC / 95 : -1
                accent: panel.svc && panel.svc.localTempC >= 85 ? Color.urgent
                  : panel.svc && panel.svc.localTempC >= 70 ? panel.widget.gaugeWarn : panel.widget.localHot
              }
              StatTile {
                // Unified memory: the GPU and the OS draw from the same 8 GB.
                caption: "MEMORY  ·  UNIFIED"
                value: panel.svc ? panel.svc.localVramUsedMb / 1024 : 0
                format: function(v) { return panel.svc && panel.svc.localVramTotalMb > 0 ? v.toFixed(1) : "--" }
                unit: "/ " + (panel.svc ? panel.gb(panel.svc.localVramTotalMb) : "--") + " GB"
                sub: panel.svc && panel.svc.localVramTotalMb > 0
                  ? "models " + panel.gb(panel.svc.localVramModelsMb) + " GB · free "
                    + panel.gb(panel.svc.localVramTotalMb - panel.svc.localVramUsedMb) + " GB"
                  : ""
                fraction: panel.svc && panel.svc.localVramTotalMb > 0 ? panel.svc.localVramUsedMb / panel.svc.localVramTotalMb : -1
                accent: panel.widget.localHot
              }
              StatTile {
                caption: "GPU CLOCK"
                value: panel.svc ? panel.svc.localClockMhz : 0
                format: function(v) { return v > 0 ? String(Math.round(v)) : "--" }
                unit: "MHz"
                sub: panel.svc && panel.svc.localClockMaxMhz > 0
                  ? "ceiling " + Math.round(panel.svc.localClockMaxMhz) + " MHz" : ""
                fraction: panel.svc && panel.svc.localClockMaxMhz > 0 ? panel.svc.localClockMhz / panel.svc.localClockMaxMhz : -1
                accent: panel.widget.localHot
              }
              StatTile {
                caption: "WARM MODELS"
                value: panel.svc ? panel.svc.localModelCount : 0
                unit: panel.svc && panel.svc.localModelCount === 1 ? "model" : "models"
                sub: panel.svc && panel.svc.localSampledAt > 0
                  ? "sampled " + panel.agoText(panel.svc.localSampledAt)
                    + " · every " + (panel.svc.localRefreshMs / 1000).toFixed(1) + "s"
                  : "no sample yet"
                fraction: -1
                accent: panel.localState
              }
            }

            Trace {
              // The span the ring actually covers, from its own timestamps —
              // polls skip while a probe runs and refreshes add early samples.
              caption: "LOAD  ·  LAST " + Math.round((panel.svc ? panel.svc.localSpanMs : 0) / 1000) + "S"
              valueText: (panel.svc ? Math.round(panel.svc.localLoad) : 0) + "%  ·  peak " + (panel.svc ? Math.round(panel.svc.localPeakLoad) : 0) + "%"
              samples: panel.svc ? panel.svc.localHistory : []
              max: 100
              accent: panel.localState
            }
            Trace {
              caption: "POWER DRAW"
              valueText: (panel.svc ? panel.svc.localPowerW.toFixed(1) : "0") + " W  ·  peak " + (panel.svc ? panel.svc.localPeakPowerW.toFixed(1) : "0") + " W"
              samples: panel.svc ? panel.svc.localPowerHistory : []
              max: panel.svc && panel.svc.localPowerLimitW > 0 ? panel.svc.localPowerLimitW : Math.max(1, panel.svc ? panel.svc.localPeakPowerW : 1)
              accent: panel.powerColor
            }

            PanelSectionHeader {
              Layout.fillWidth: true
              // "loaded", not "in memory": /api/ps lists CPU-resident models
              // too, and each row says how much GPU memory it actually holds.
              text: "RESIDENT MODELS  ·  " + (panel.svc ? panel.svc.localModelCount : 0) + " LOADED"
              foreground: panel.foreground
              fontFamily: panel.fontFamily
            }

            Caption {
              visible: residentRepeater.count === 0
              text: panel.localOnline ? "nothing warm — pick a model below and load it" : (panel.svc ? panel.svc.localError : "")
              Layout.fillWidth: true
              wrapMode: Text.WordWrap
              elide: Text.ElideNone
            }

            Repeater {
              id: residentRepeater
              readonly property var rows: panel.svc ? panel.svc.localModelDetails : []
              model: rows.slice(0, panel.maxRows)
              delegate: ColumnLayout {
                required property var modelData
                Layout.fillWidth: true
                spacing: 1
                RowLayout {
                  Layout.fillWidth: true
                  Body { text: panel.plainText(modelData.name, 64); color: panel.widget.localHot; font.bold: true; Layout.fillWidth: true }
                  Caption {
                    // "evicts in 4m" is the number that matters: it is when the
                    // next request pays the load cost again.
                    text: modelData.expiresAt && Date.parse(String(modelData.expiresAt)) - Date.now() > 315360000000
                      ? "pinned" : "evicts in " + panel.untilText(modelData.expiresAt)
                  }
                }
                Caption {
                  Layout.fillWidth: true
                  text: [panel.plainText(modelData.parameters, 16), panel.plainText(modelData.quantization, 16),
                         panel.plainText(modelData.family, 16),
                         modelData.sizeVram > 0 ? (Number(modelData.sizeVram) / 1073741824).toFixed(1) + " GB gpu" : "",
                         modelData.contextLength > 0 ? panel.widget.compact(modelData.contextLength) + " ctx" : ""]
                    .filter(Boolean).join("  ·  ")
                }
              }
            }
            Caption {
              visible: residentRepeater.rows.length > panel.maxRows
              text: "+ " + (residentRepeater.rows.length - panel.maxRows) + " more resident"
              Layout.fillWidth: true
            }

            PanelSectionHeader {
              Layout.fillWidth: true
              text: "MODEL CONTROL  ·  " + panel.localOptions.length + " INSTALLED"
              foreground: panel.foreground
              fontFamily: panel.fontFamily
            }

            SearchableDropdown {
              id: modelPicker
              Layout.fillWidth: true
              label: "Installed Ollama model"
              placeholderText: "Choose a model…"
              fontFamily: panel.fontFamily
              options: panel.localOptions
              value: panel.selectedModel
              onChanged: function(value) { panel.selectedModel = value }
            }

            RowLayout {
              Layout.fillWidth: true
              spacing: Style.space(8)
              Button {
                text: panel.localBusy ? "Working…" : "Load & keep warm"
                enabled: !panel.localBusy && panel.localOnline && panel.selectedModel !== ""
                onClicked: panel.runLocalAction("load")
              }
              Button {
                text: "Unload"
                enabled: !panel.localBusy && panel.localOnline && panel.selectedModel !== ""
                onClicked: panel.runLocalAction("unload")
              }
              Item { Layout.fillWidth: true }
            }

            Caption {
              Layout.fillWidth: true
              visible: panel.localNote !== ""
              text: panel.localNote
              color: panel.localState
              wrapMode: Text.WordWrap
              elide: Text.ElideNone
            }
          }
        }

        PanelSeparator { Layout.fillWidth: true; foreground: panel.foreground }

        RowLayout {
          Layout.fillWidth: true
          spacing: Style.space(12)
          Caption {
            Layout.fillWidth: true
            text: panel.svc && panel.svc.lastError !== "" ? panel.svc.lastError
              : (panel.showClaude ? "Claude" : "")
                + (panel.showClaude && panel.showCodex ? " ◄ now ► " : "")
                + (panel.showCodex ? "Codex" : "")
                + (panel.showGrok ? ((panel.showClaude || panel.showCodex) ? "  │ Grok" : "Grok") : "")
                + (panel.showLocal ? "  ║  " + panel.boxName : "")
                + "  ·  colour is heat"
                + (panel.showLocal ? "  ·  cloud is tokens per bucket, " + panel.boxName + " is load per second" : "")
            color: panel.svc && panel.svc.lastError !== "" ? Color.urgent : panel.dim
          }
          Caption {
            text: "collected " + panel.agoText(panel.svc ? panel.svc.generatedAt : 0)
              + "  ·  R refresh  ·  Esc close"
          }
        }

        // About: version, source, site. Out of the way at the foot of the
        // panel, but always there — you should never have to open a file to
        // learn which Burn Bar you are looking at.
        RowLayout {
          Layout.fillWidth: true
          spacing: Style.space(6)
          Caption {
            text: "Burn Bar" + (panel.pluginVersion !== "" ? "  v" + panel.pluginVersion : "")
          }
          Caption { text: "·"; visible: panel.repoUrl !== "" }
          Link {
            visible: panel.repoUrl !== ""
            text: panel.repoUrl.replace(/^https?:\/\//, "")
            url: panel.repoUrl
          }
          Caption { text: "·"; visible: panel.homeUrl !== "" }
          Link {
            visible: panel.homeUrl !== ""
            text: panel.homeUrl.replace(/^https?:\/\//, "")
            url: panel.homeUrl
          }
          Item { Layout.fillWidth: true }
        }
      }
    }
  }
}
