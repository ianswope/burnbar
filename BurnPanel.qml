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
// local runner in watts, degrees and megabytes. Different money, different
// units, so they never share a column.
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

  readonly property int panelWidth: Style.space(880)
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
    if (ms <= 0) return "now"
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
  readonly property real bucketMinutes: svc ? Math.max(1, svc.bucketMinutes) : 30
  readonly property real windowMinutes: svc ? svc.windowMinutes : 360
  readonly property int hourBuckets: Math.max(1, Math.round(60 / bucketMinutes))

  // Tokens per minute over the last N buckets. The newest bucket is partial,
  // so "now" divides by the minutes actually elapsed inside it rather than the
  // full bucket width — otherwise the live rate reads a fraction of the truth.
  function rate(agent, bucketsBack) {
    void panel.tick
    var b = panel.buckets
    if (!b || !b.length) return 0
    var sum = 0
    var n = Math.min(bucketsBack, b.length)
    for (var i = 0; i < n; i++) sum += Number(b[b.length - 1 - i][agent] || 0)
    var newestT = Number(b[b.length - 1].t || 0)
    var elapsedInNewest = Math.max(1, Math.min(panel.bucketMinutes, (Date.now() - newestT) / 60000))
    var minutes = (n - 1) * panel.bucketMinutes + elapsedInNewest
    return sum / Math.max(1, minutes)
  }

  function splitTotal(split) {
    return Number(split.input || 0) + Number(split.cacheWrite || 0) + Number(split.output || 0)
  }
  function cacheSavings(split) {
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
    : localActive ? widget.localHot : "#35f28b"
  readonly property color powerColor: "#FFC46B"

  function plainText(value, limit) {
    return String(value || "").slice(0, limit).replace(/[<>&]/g, function(character) {
      return character === "<" ? "‹" : character === ">" ? "›" : "＆"
    }).replace(/[\u0000-\u001f\u007f]/g, " ")
  }

  function refreshLocalModels() {
    if (listProc.running || !svc) return
    listProc.command = ["python3", svc.localControlPath, "list"]
    listProc.running = true
  }

  function refreshAll() {
    refreshLocalModels()
    if (svc) { svc.collect(); svc.pollLocal() }
  }

  function runLocalAction(action) {
    if (localBusy || selectedModel === "" || !svc) return
    localBusy = true
    localNote = (action === "load" ? "Warming " : "Unloading ") + selectedModel + "…"
    actionProc.command = ["python3", svc.localControlPath, action, selectedModel]
    actionProc.running = true
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
      if (panel.selectedModel === "" && options.length > 0) panel.selectedModel = options[0].value
    } catch (e) {
      panel.localNote = "Could not read installed models"
    }
  }

  Process {
    id: listProc
    stdout: StdioCollector { waitForEnd: true; onStreamFinished: panel.parseLocalModels(text) }
  }

  Process {
    id: actionProc
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: {
        try {
          var result = JSON.parse(String(text || ""))
          panel.localNote = panel.plainText(result.ok ? result.message : result.error, 384)
        } catch (e) { panel.localNote = "Ollama action failed" }
      }
    }
    onExited: {
      panel.localBusy = false
      // Ollama reports a model as resident a beat after the call returns.
      settleTimer.restart()
    }
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
          meta: "tokens billed · last " + Math.round(panel.windowMinutes / 60) + "h  ·  "
            + ((panel.svc ? panel.svc.claudeTurns + panel.svc.codexTurns : 0)) + " turns  ·  "
            + ((panel.svc ? panel.svc.claudeSessions + panel.svc.codexSessions : 0)) + " sessions"
          detail: panel.svc
            ? panel.widget.compact(panel.rate("claude", 1) + panel.rate("codex", 1)) + "/min now  ·  "
              + panel.widget.compact(panel.rate("claude", panel.hourBuckets) + panel.rate("codex", panel.hourBuckets)) + "/min last hour  ·  "
              + "active " + panel.agoText(Math.max(panel.svc.claudeLastAt, panel.svc.codexLastAt))
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
                  target: panel.svc ? panel.svc.claudeTotal + panel.svc.codexTotal : 0
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

        // ── three tiles, same order as the bar ───────────────────────────────
        RowLayout {
          Layout.fillWidth: true
          spacing: Style.space(8)
          opacity: panel.reveal
          transform: Translate { y: (1 - panel.reveal) * 8 }

          Repeater {
            model: [
              {
                name: "CLAUDE",
                accent: panel.widget.claudeHot,
                value: panel.svc ? panel.svc.claudeTotal : 0,
                format: panel.widget.compact,
                sub: panel.svc
                  ? panel.svc.claudeTurns + " turns · " + panel.svc.claudeSessions + " sessions · "
                    + panel.widget.compact(panel.rate("claude", 1)) + "/min"
                  : "",
                sub2: panel.svc
                  ? "peak " + panel.widget.compact(panel.svc.claudePeak) + " at " + panel.clockText(panel.svc.claudePeakAt)
                    + " · active " + panel.agoText(panel.svc.claudeLastAt)
                  : ""
              },
              {
                name: "CODEX",
                accent: panel.widget.codexHot,
                value: panel.svc ? panel.svc.codexTotal : 0,
                format: panel.widget.compact,
                sub: panel.svc
                  ? panel.svc.codexTurns + " turns · " + panel.svc.codexSessions + " sessions · "
                    + panel.widget.compact(panel.rate("codex", 1)) + "/min"
                  : "",
                sub2: panel.svc
                  ? "peak " + panel.widget.compact(panel.svc.codexPeak) + " at " + panel.clockText(panel.svc.codexPeakAt)
                    + " · active " + panel.agoText(panel.svc.codexLastAt)
                  : ""
              },
              {
                name: "LOCAL",
                accent: panel.localState,
                value: panel.localOnline ? panel.svc.localLoad : 0,
                format: function(v) { return panel.localOnline ? Math.round(v) + "%" : "off" },
                sub: !panel.localOnline ? "ollama not answering"
                  : (panel.svc.localActive ? "inferencing" : "idle")
                    + " · " + panel.svc.localModelCount + " warm"
                    + (panel.svc.localPowerW > 0 ? " · " + panel.svc.localPowerW.toFixed(1) + " W" : ""),
                sub2: !panel.localOnline ? (panel.svc ? panel.svc.localError : "")
                  : "peak " + Math.round(panel.svc.localPeakLoad) + "% · "
                    + panel.svc.localPeakPowerW.toFixed(0) + " W this session"
              }
            ]
            delegate: Rectangle {
              required property var modelData
              Layout.fillWidth: true
              implicitHeight: Style.space(76)
              radius: Style.cornerRadius
              color: Util.alpha(modelData.accent, 0.10)
              border.width: 1
              border.color: Util.alpha(modelData.accent, 0.30)

              ColumnLayout {
                anchors.fill: parent
                anchors.margins: Style.space(9)
                spacing: 1
                RowLayout {
                  Layout.fillWidth: true
                  Counter {
                    target: modelData.value
                    format: modelData.format
                    color: modelData.accent
                    font.bold: true
                    font.pixelSize: Style.font.display
                  }
                  Item { Layout.fillWidth: true }
                  Caption { text: modelData.name; color: panel.foreground; font.bold: true }
                }
                Caption { text: modelData.sub; Layout.fillWidth: true }
                Caption { text: modelData.sub2; Layout.fillWidth: true }
              }
            }
          }
        }

        // ── the two columns ──────────────────────────────────────────────────
        // Explicit geometry. See the file comment for why this is not a RowLayout.
        Item {
          id: columns
          Layout.fillWidth: true
          implicitHeight: Math.max(cloudCol.implicitHeight, localCol.implicitHeight)
          readonly property int leftWidth: Math.round((width - panel.columnGap) * 0.55)
          readonly property int rightWidth: width - panel.columnGap - leftWidth

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
                text: "BURN OVER TIME  ·  " + Math.round(panel.bucketMinutes) + " MIN BUCKETS"
                foreground: panel.foreground
                fontFamily: panel.fontFamily
                elide: Text.ElideRight
              }
              Caption { text: "▲ " + panel.widget.compact(panel.svc ? panel.svc.claudePeak : 0); color: panel.widget.claudeHot; font.bold: true }
              Caption { text: "▼ " + panel.widget.compact(panel.svc ? panel.svc.codexPeak : 0); color: panel.widget.codexHot; font.bold: true }
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
                  readonly property real cl: Math.min(1, Math.pow(c / chart.claudeRef, 0.6))
                  readonly property real xl: Math.min(1, Math.pow(x_ / chart.codexRef, 0.6))
                  readonly property bool live: index === chart.n - 1
                  readonly property real grow: panel.wipe(index, chart.n)
                  readonly property real barWidth: Math.max(2, chart.slot - 3)
                  x: index * chart.slot
                  width: chart.slot
                  height: chart.height

                  Rectangle {
                    y: chart.mid - height
                    anchors.horizontalCenter: parent.horizontalCenter
                    width: col.barWidth
                    height: Math.max(col.c > 0 ? 2 : 0, (chart.mid - 3) * col.cl) * col.grow
                    radius: 2
                    color: panel.widget.heat(col.cl, panel.widget.claudeCold, panel.widget.claudeWarm, panel.widget.claudeHot)
                    opacity: 0.55 + 0.45 * (col.index / Math.max(1, chart.n - 1))
                    Behavior on height { NumberAnimation { duration: 320; easing.type: Easing.OutCubic } }
                  }
                  Rectangle {
                    y: chart.mid + 1
                    anchors.horizontalCenter: parent.horizontalCenter
                    width: col.barWidth
                    height: Math.max(col.x_ > 0 ? 2 : 0, (chart.mid - 3) * col.xl) * col.grow
                    radius: 2
                    color: panel.widget.heat(col.xl, panel.widget.codexCold, panel.widget.codexWarm, panel.widget.codexHot)
                    opacity: 0.55 + 0.45 * (col.index / Math.max(1, chart.n - 1))
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
                    // Hour marks, with the last one or two suppressed so they
                    // never crowd the "now" label.
                    visible: col.live || (col.index % panel.hourBuckets === 0 && col.index <= chart.n - 3)
                    anchors.bottom: parent.bottom
                    anchors.horizontalCenter: parent.horizontalCenter
                    text: col.live ? "now" : Qt.formatTime(new Date(Number(col.b ? col.b.t : 0)), "h AP")
                    font.pixelSize: Style.font.caption - 1
                    font.bold: col.live
                    color: col.live ? panel.foreground : panel.dim
                    elide: Text.ElideNone
                  }
                }
              }
            }

            // Rates: tokens per minute, three horizons, both agents.
            GridLayout {
              Layout.fillWidth: true
              columns: 4
              columnSpacing: Style.space(8)
              rowSpacing: 2
              Caption { text: "RATE  ·  TOKENS / MIN"; font.bold: true; Layout.fillWidth: true }
              Caption { text: "NOW"; font.bold: true; Layout.preferredWidth: Style.space(58); horizontalAlignment: Text.AlignRight }
              Caption { text: "1 HOUR"; font.bold: true; Layout.preferredWidth: Style.space(58); horizontalAlignment: Text.AlignRight }
              Caption { text: Math.round(panel.windowMinutes / 60) + " HOURS"; font.bold: true; Layout.preferredWidth: Style.space(58); horizontalAlignment: Text.AlignRight }

              Body { text: "Claude"; color: panel.widget.claudeHot; Layout.fillWidth: true }
              Counter { target: panel.rate("claude", 1); format: panel.widget.compact; color: panel.foreground; font.bold: true; font.pixelSize: Style.font.bodySmall; Layout.preferredWidth: Style.space(58); horizontalAlignment: Text.AlignRight }
              Counter { target: panel.rate("claude", panel.hourBuckets); format: panel.widget.compact; color: panel.foreground; font.pixelSize: Style.font.bodySmall; Layout.preferredWidth: Style.space(58); horizontalAlignment: Text.AlignRight }
              Counter { target: panel.rate("claude", panel.buckets.length); format: panel.widget.compact; color: panel.foreground; font.pixelSize: Style.font.bodySmall; Layout.preferredWidth: Style.space(58); horizontalAlignment: Text.AlignRight }

              Body { text: "Codex"; color: panel.widget.codexHot; Layout.fillWidth: true }
              Counter { target: panel.rate("codex", 1); format: panel.widget.compact; color: panel.foreground; font.bold: true; font.pixelSize: Style.font.bodySmall; Layout.preferredWidth: Style.space(58); horizontalAlignment: Text.AlignRight }
              Counter { target: panel.rate("codex", panel.hourBuckets); format: panel.widget.compact; color: panel.foreground; font.pixelSize: Style.font.bodySmall; Layout.preferredWidth: Style.space(58); horizontalAlignment: Text.AlignRight }
              Counter { target: panel.rate("codex", panel.buckets.length); format: panel.widget.compact; color: panel.foreground; font.pixelSize: Style.font.bodySmall; Layout.preferredWidth: Style.space(58); horizontalAlignment: Text.AlignRight }
            }

            PanelSectionHeader {
              Layout.fillWidth: true
              text: "TOKEN MIX  ·  INPUT / CACHE WRITE / OUTPUT"
              foreground: panel.foreground
              fontFamily: panel.fontFamily
              elide: Text.ElideRight
            }

            // What you paid for, by kind — and how much the cache absorbed
            // that never hit the bill. That second number is the one people
            // never think to look at and always want once they have seen it.
            Repeater {
              model: [
                { name: "Claude", accent: panel.widget.claudeHot, split: panel.svc ? panel.svc.claudeSplit : ({}) },
                { name: "Codex", accent: panel.widget.codexHot, split: panel.svc ? panel.svc.codexSplit : ({}) }
              ]
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
                      + " · saved " + Math.round(panel.cacheSavings(modelData.split) * 100) + "%"
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
              text: "PLAN LIMITS"
              foreground: panel.foreground
              fontFamily: panel.fontFamily
            }

            Repeater {
              model: {
                var out = []
                var c = panel.svc ? panel.svc.claudeLimits : []
                var x = panel.svc ? panel.svc.codexLimits : []
                for (var i = 0; i < c.length; i++)
                  out.push({ agent: "Claude", accent: panel.widget.claudeHot, limit: c[i] })
                for (var j = 0; j < x.length; j++)
                  out.push({ agent: "Codex", accent: panel.widget.codexHot, limit: x[j] })
                return out
              }
              delegate: ColumnLayout {
                required property var modelData
                Layout.fillWidth: true
                spacing: 2

                RowLayout {
                  Layout.fillWidth: true
                  spacing: Style.space(6)
                  Body { text: modelData.agent; color: modelData.accent; Layout.preferredWidth: Style.space(48) }
                  Body { text: modelData.limit.label; Layout.fillWidth: true }
                  Caption {
                    text: "resets in " + panel.untilText(modelData.limit.resetsAt)
                      + "  ·  " + panel.dayClockText(modelData.limit.resetsAt)
                  }
                  Body {
                    text: Math.round(Number(modelData.limit.percent) * 100) + "%"
                    color: panel.widget.gaugeColor(Number(modelData.limit.percent))
                    font.bold: true
                    Layout.preferredWidth: Style.space(34)
                    horizontalAlignment: Text.AlignRight
                  }
                }
                Gauge {
                  fraction: Number(modelData.limit.percent)
                  accent: panel.widget.gaugeColor(Number(modelData.limit.percent))
                }
              }
            }

            PanelSectionHeader {
              Layout.fillWidth: true
              text: "CLAUDE BY MODEL"
              foreground: panel.foreground
              fontFamily: panel.fontFamily
              visible: modelRepeater.count > 0
            }

            Repeater {
              id: modelRepeater
              model: panel.sortedModels(panel.svc ? panel.svc.claudeByModel : ({}))
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
          }

          // ════ LOCAL ═════════════════════════════════════════════════════════
          ColumnLayout {
            id: localCol
            x: columns.leftWidth + panel.columnGap
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
                  text: "LOCAL INTELLIGENCE  ·  " + (!panel.localOnline ? "OFFLINE"
                    : panel.localActive ? "INFERENCING" : "IDLE")
                  color: panel.localState
                  font.bold: true
                }
                Caption {
                  Layout.fillWidth: true
                  text: panel.svc
                    ? (panel.svc.localGpuName !== "" ? panel.svc.localGpuName.replace("NVIDIA GeForce ", "") : "no NVIDIA GPU")
                      + "  ·  " + String(panel.svc.localBackend).toUpperCase()
                      + (panel.svc.localVersion !== "" ? "  ·  ollama " + panel.svc.localVersion : "")
                    : ""
                }
              }
            }

            // GPU telemetry, two across so every tile has room for its unit
            // and sub-line. A metric the board does not expose reads as 0 and
            // the tile hides its bar rather than drawing a full or empty one.
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
                caption: "POWER DRAW"
                value: panel.svc ? panel.svc.localPowerW : 0
                format: function(v) { return v > 0 ? v.toFixed(1) : "--" }
                unit: "W"
                sub: panel.svc && panel.svc.localPowerLimitW > 0
                  ? "limit " + Math.round(panel.svc.localPowerLimitW) + " W"
                  : "peak " + (panel.svc ? panel.svc.localPeakPowerW.toFixed(1) : 0) + " W this session"
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
                  : (panel.svc && panel.svc.localTempC >= 85 ? "throttle territory"
                    : panel.svc && panel.svc.localTempC >= 70 ? "warm" : "cool")
                fraction: panel.svc && panel.svc.localTempC > 0 ? panel.svc.localTempC / 95 : -1
                accent: panel.svc && panel.svc.localTempC >= 85 ? Color.urgent
                  : panel.svc && panel.svc.localTempC >= 70 ? "#facc15" : panel.widget.localHot
              }
              StatTile {
                caption: "VRAM"
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
                caption: "SM CLOCK"
                value: panel.svc ? panel.svc.localClockMhz : 0
                format: function(v) { return v > 0 ? String(Math.round(v)) : "--" }
                unit: "MHz"
                sub: panel.svc && panel.svc.localClockMaxMhz > 0
                  ? "boost ceiling " + Math.round(panel.svc.localClockMaxMhz) + " MHz" : ""
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
              caption: "LOAD  ·  LAST " + ((panel.svc ? panel.svc.localCells * panel.svc.localRefreshMs / 1000 : 0).toFixed(0)) + "S"
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
              text: "RESIDENT MODELS  ·  " + (panel.svc ? panel.svc.localModelCount : 0) + " IN VRAM"
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
              model: panel.svc ? panel.svc.localModelDetails : []
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
                         modelData.sizeVram > 0 ? (Number(modelData.sizeVram) / 1073741824).toFixed(1) + " GB vram" : "",
                         modelData.contextLength > 0 ? panel.widget.compact(modelData.contextLength) + " ctx" : ""]
                    .filter(Boolean).join("  ·  ")
                }
              }
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
              : "Claude ◄ now ► Codex  ║  Local  ·  colour is heat  ·  cloud is tokens per bucket, local is runner load per second"
            color: panel.svc && panel.svc.lastError !== "" ? Color.urgent : panel.dim
          }
          Caption {
            text: "collected " + panel.agoText(panel.svc ? panel.svc.generatedAt : 0)
              + "  ·  R refresh  ·  Esc close"
          }
        }
      }
    }
  }
}
