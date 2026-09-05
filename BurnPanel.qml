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

  readonly property int panelWidth: Style.space(860)
  readonly property int columnGap: Style.space(18)

  // Relative times ("3m ago", "evicts in 4m") go stale the moment they are
  // drawn; a 5s tick re-evaluates every binding that reads it.
  property int tick: 0
  Timer { interval: 5000; running: panel.opened; repeat: true; onTriggered: panel.tick++ }

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
    if (days > 0) return "in " + days + "d " + hours + "h"
    if (hours > 0) return "in " + hours + "h " + (mins % 60) + "m"
    return "in " + mins + "m"
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
  function pct(a, b) { return b > 0 ? Math.round(Number(a) / Number(b) * 100) : 0 }

  // ── derived cloud metrics ─────────────────────────────────────────────────
  readonly property var buckets: svc ? svc.buckets : []
  readonly property real bucketMinutes: svc ? Math.max(1, svc.bucketMinutes) : 30
  readonly property real windowMinutes: svc ? svc.windowMinutes : 360

  // Tokens per minute over the last N buckets. The newest bucket is partial,
  // so "now" divides by the minutes actually elapsed inside it rather than the
  // full bucket width — otherwise the live rate reads a fraction of the truth.
  function rate(agent, bucketsBack) {
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

  onOpenedChanged: if (opened) refreshLocalModels()

  // ── reusable pieces ───────────────────────────────────────────────────────
  // Caption over a big number over a thin fill bar. The whole right column is
  // built from these, so every GPU metric reads the same way.
  component StatTile: Rectangle {
    id: tile
    property string caption: ""
    property string value: "--"
    property string unit: ""
    property string sub: ""
    // 0..1 fills the bar; negative hides it (for metrics with no ceiling).
    property real fraction: -1
    property color accent: panel.foreground

    Layout.fillWidth: true
    implicitHeight: Style.space(58)
    radius: Style.cornerRadius
    color: Util.alpha(tile.accent, 0.07)
    border.width: 1
    border.color: Util.alpha(tile.accent, 0.22)

    ColumnLayout {
      anchors.fill: parent
      anchors.margins: Style.space(8)
      spacing: 2
      Text {
        text: tile.caption
        textFormat: Text.PlainText
        color: panel.dim
        font.family: panel.fontFamily
        font.pixelSize: Style.font.caption
        font.bold: true
      }
      RowLayout {
        spacing: Style.space(3)
        Text {
          text: tile.value
          textFormat: Text.PlainText
          color: tile.accent
          font.family: panel.fontFamily
          font.pixelSize: Style.font.title
          font.bold: true
        }
        Text {
          text: tile.unit
          textFormat: Text.PlainText
          color: panel.dim
          font.family: panel.fontFamily
          font.pixelSize: Style.font.caption
          Layout.alignment: Qt.AlignBaseline
        }
        Item { Layout.fillWidth: true }
        Text {
          text: tile.sub
          textFormat: Text.PlainText
          color: panel.dim
          font.family: panel.fontFamily
          font.pixelSize: Style.font.caption
          elide: Text.ElideRight
          Layout.maximumWidth: Style.space(80)
        }
      }
      Rectangle {
        Layout.fillWidth: true
        visible: tile.fraction >= 0
        implicitHeight: Style.space(3)
        radius: height / 2
        color: panel.faint
        Rectangle {
          height: parent.height
          radius: height / 2
          width: parent.width * Math.max(0, Math.min(1, tile.fraction))
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
      Text {
        text: trace.caption
        textFormat: Text.PlainText
        color: panel.dim
        font.family: panel.fontFamily
        font.pixelSize: Style.font.caption
        font.bold: true
      }
      Item { Layout.fillWidth: true }
      Text {
        text: trace.valueText
        textFormat: Text.PlainText
        color: trace.accent
        font.family: panel.fontFamily
        font.pixelSize: Style.font.caption
        font.bold: true
      }
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
          height: Math.max(2, traceArea.height * v)
          radius: 1
          color: trace.accent
          opacity: 0.35 + 0.65 * (index / Math.max(1, traceArea.n - 1))
          Behavior on height { NumberAnimation { duration: 260; easing.type: Easing.OutCubic } }
        }
      }
    }
  }

  component Caption: Text {
    textFormat: Text.PlainText
    color: panel.dim
    font.family: panel.fontFamily
    font.pixelSize: Style.font.caption
  }
  component Body: Text {
    textFormat: Text.PlainText
    color: panel.foreground
    font.family: panel.fontFamily
    font.pixelSize: Style.font.bodySmall
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
    contentHeight: fittedContentHeight(content.implicitHeight, Style.space(940))

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
          title: panel.svc
            ? panel.widget.compact(panel.svc.claudeTotal + panel.svc.codexTotal)
            : "--"
          meta: "tokens billed · last " + Math.round(panel.windowMinutes / 60) + "h  ·  "
            + ((panel.svc ? panel.svc.claudeTurns + panel.svc.codexTurns : 0)) + " turns  ·  "
            + ((panel.svc ? panel.svc.claudeSessions + panel.svc.codexSessions : 0)) + " sessions"
          detail: panel.svc
            ? "burning " + panel.widget.compact(panel.rate("claude", 1) + panel.rate("codex", 1)) + "/min now"
              + "  ·  " + panel.widget.compact(panel.rate("claude", Math.round(60 / panel.bucketMinutes))
                                             + panel.rate("codex", Math.round(60 / panel.bucketMinutes))) + "/min over the hour"
              + "  ·  last activity " + panel.agoText(Math.max(panel.svc.claudeLastAt, panel.svc.codexLastAt))
            : ""
          foreground: panel.widget.claudeHot
          fontFamily: panel.fontFamily
          iconComponent: Component {
            Text {
              text: "󰈸"
              textFormat: Text.PlainText
              color: panel.widget.claudeHot
              font.family: panel.fontFamily
              font.pixelSize: Style.font.display
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

          Repeater {
            model: [
              {
                name: "CLAUDE",
                accent: panel.widget.claudeHot,
                value: panel.svc ? panel.widget.compact(panel.svc.claudeTotal) : "--",
                sub: panel.svc
                  ? panel.svc.claudeTurns + " turns · " + panel.svc.claudeSessions + " sessions"
                  : "",
                sub2: panel.svc
                  ? "peak " + panel.widget.compact(panel.svc.claudePeak) + " at " + panel.clockText(panel.svc.claudePeakAt)
                    + " · last " + panel.agoText(panel.svc.claudeLastAt)
                  : ""
              },
              {
                name: "CODEX",
                accent: panel.widget.codexHot,
                value: panel.svc ? panel.widget.compact(panel.svc.codexTotal) : "--",
                sub: panel.svc
                  ? panel.svc.codexTurns + " turns · " + panel.svc.codexSessions + " sessions"
                  : "",
                sub2: panel.svc
                  ? "peak " + panel.widget.compact(panel.svc.codexPeak) + " at " + panel.clockText(panel.svc.codexPeakAt)
                    + " · last " + panel.agoText(panel.svc.codexLastAt)
                  : ""
              },
              {
                name: "LOCAL",
                accent: panel.localState,
                value: !panel.localOnline ? "off" : Math.round(panel.svc.localLoad) + "%",
                sub: !panel.localOnline ? "ollama not answering"
                  : (panel.svc.localActive ? "inferencing" : "idle")
                    + " · " + panel.svc.localModelCount + " warm",
                sub2: !panel.localOnline ? (panel.svc ? panel.svc.localError : "")
                  : (panel.svc.localPowerW > 0 ? panel.svc.localPowerW.toFixed(1) + " W · " : "")
                    + "peak " + Math.round(panel.svc.localPeakLoad) + "% this session"
              }
            ]
            delegate: Rectangle {
              required property var modelData
              Layout.fillWidth: true
              implicitHeight: Style.space(74)
              radius: Style.cornerRadius
              color: Util.alpha(modelData.accent, 0.10)
              border.width: 1
              border.color: Util.alpha(modelData.accent, 0.30)

              ColumnLayout {
                anchors.fill: parent
                anchors.margins: Style.space(8)
                spacing: 1
                RowLayout {
                  Layout.fillWidth: true
                  Text {
                    text: modelData.value
                    textFormat: Text.PlainText
                    color: modelData.accent
                    font.family: panel.fontFamily
                    font.bold: true
                    font.pixelSize: Style.font.display
                  }
                  Item { Layout.fillWidth: true }
                  Text {
                    text: modelData.name
                    textFormat: Text.PlainText
                    color: panel.foreground
                    font.family: panel.fontFamily
                    font.bold: true
                    font.pixelSize: Style.font.caption
                  }
                }
                Caption { text: modelData.sub; Layout.fillWidth: true; elide: Text.ElideRight }
                Caption { text: modelData.sub2; Layout.fillWidth: true; elide: Text.ElideRight }
              }
            }
          }
        }

        // ── the two columns ──────────────────────────────────────────────────
        RowLayout {
          id: columns
          Layout.fillWidth: true
          spacing: panel.columnGap
          readonly property int leftWidth: Math.round((width - panel.columnGap) * 0.56)
          readonly property int rightWidth: width - panel.columnGap - leftWidth

          // ════ CLOUD ═════════════════════════════════════════════════════════
          ColumnLayout {
            Layout.preferredWidth: columns.leftWidth
            Layout.maximumWidth: columns.leftWidth
            Layout.alignment: Qt.AlignTop
            spacing: Style.space(8)

            PanelSectionHeader {
              Layout.fillWidth: true
              text: "BURN OVER TIME  ·  " + Math.round(panel.bucketMinutes) + " MIN BUCKETS"
              foreground: panel.foreground
              fontFamily: panel.fontFamily
            }

            // Mirrored bars around a midline: Claude rises, Codex falls, both
            // coloured on the heat ramp the bar uses — so the panel and the
            // strip teach each other. Newest on the right, like every trace.
            Item {
              id: chart
              Layout.fillWidth: true
              implicitHeight: Style.space(124)
              readonly property int labelBand: Style.space(14)
              readonly property real plotHeight: height - labelBand
              readonly property real mid: plotHeight / 2
              readonly property int n: panel.buckets.length
              readonly property real slot: n > 0 ? width / n : width
              readonly property real claudeRef: Math.max(1, panel.svc ? panel.svc.claudePeak : 1)
              readonly property real codexRef: Math.max(1, panel.svc ? panel.svc.codexPeak : 1)
              readonly property int labelEvery: Math.max(1, Math.round(60 / panel.bucketMinutes))

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
                  x: index * chart.slot
                  width: chart.slot
                  height: chart.height

                  Rectangle {
                    anchors.bottom: parent.top
                    anchors.bottomMargin: -chart.mid
                    anchors.horizontalCenter: parent.horizontalCenter
                    width: Math.max(2, chart.slot - 3)
                    height: Math.max(col.c > 0 ? 2 : 0, (chart.mid - 2) * col.cl)
                    radius: 2
                    color: panel.widget.heat(col.cl, panel.widget.claudeCold, panel.widget.claudeWarm, panel.widget.claudeHot)
                    opacity: 0.55 + 0.45 * (col.index / Math.max(1, chart.n - 1))
                    Behavior on height { NumberAnimation { duration: 320; easing.type: Easing.OutCubic } }
                  }
                  Rectangle {
                    y: chart.mid + 1
                    anchors.horizontalCenter: parent.horizontalCenter
                    width: Math.max(2, chart.slot - 3)
                    height: Math.max(col.x_ > 0 ? 2 : 0, (chart.mid - 2) * col.xl)
                    radius: 2
                    color: panel.widget.heat(col.xl, panel.widget.codexCold, panel.widget.codexWarm, panel.widget.codexHot)
                    opacity: 0.55 + 0.45 * (col.index / Math.max(1, chart.n - 1))
                    Behavior on height { NumberAnimation { duration: 320; easing.type: Easing.OutCubic } }
                  }
                  // Live column breathes, same as the live cell on the bar.
                  Rectangle {
                    visible: col.live
                    anchors.horizontalCenter: parent.horizontalCenter
                    width: Math.max(2, chart.slot - 3)
                    height: chart.plotHeight
                    radius: 2
                    color: "transparent"
                    border.width: 1
                    border.color: panel.widget.whiteHot
                    SequentialAnimation on opacity {
                      running: col.live && panel.opened
                      loops: Animation.Infinite
                      NumberAnimation { to: 0.45; duration: 900; easing.type: Easing.InOutQuad }
                      NumberAnimation { to: 0.05; duration: 900; easing.type: Easing.InOutQuad }
                    }
                  }
                  Caption {
                    visible: col.index % chart.labelEvery === 0 || col.live
                    anchors.bottom: parent.bottom
                    anchors.horizontalCenter: parent.horizontalCenter
                    text: col.live ? "now" : Qt.formatTime(new Date(Number(col.b ? col.b.t : 0)), "h AP")
                    font.pixelSize: Style.font.caption - 1
                    color: col.live ? panel.foreground : panel.dim
                  }
                }
              }

              Caption {
                anchors.left: parent.left
                anchors.top: parent.top
                text: "▲ Claude  peak " + panel.widget.compact(panel.svc ? panel.svc.claudePeak : 0)
                color: panel.widget.claudeHot
              }
              Caption {
                anchors.left: parent.left
                anchors.bottom: parent.bottom
                anchors.bottomMargin: chart.labelBand
                text: "▼ Codex  peak " + panel.widget.compact(panel.svc ? panel.svc.codexPeak : 0)
                color: panel.widget.codexHot
              }
            }

            // Rates: tokens per minute, three horizons, both agents.
            GridLayout {
              Layout.fillWidth: true
              columns: 4
              columnSpacing: Style.space(6)
              rowSpacing: 2
              Caption { text: "RATE /MIN"; font.bold: true }
              Caption { text: "NOW"; font.bold: true; Layout.alignment: Qt.AlignRight }
              Caption { text: "1 HOUR"; font.bold: true; Layout.alignment: Qt.AlignRight }
              Caption { text: Math.round(panel.windowMinutes / 60) + " HOURS"; font.bold: true; Layout.alignment: Qt.AlignRight }

              Body { text: "Claude"; color: panel.widget.claudeHot }
              Body { text: panel.widget.compact(panel.rate("claude", 1)); Layout.alignment: Qt.AlignRight; font.bold: true }
              Body { text: panel.widget.compact(panel.rate("claude", Math.round(60 / panel.bucketMinutes))); Layout.alignment: Qt.AlignRight }
              Body { text: panel.widget.compact(panel.rate("claude", panel.buckets.length)); Layout.alignment: Qt.AlignRight }

              Body { text: "Codex"; color: panel.widget.codexHot }
              Body { text: panel.widget.compact(panel.rate("codex", 1)); Layout.alignment: Qt.AlignRight; font.bold: true }
              Body { text: panel.widget.compact(panel.rate("codex", Math.round(60 / panel.bucketMinutes))); Layout.alignment: Qt.AlignRight }
              Body { text: panel.widget.compact(panel.rate("codex", panel.buckets.length)); Layout.alignment: Qt.AlignRight }
            }

            PanelSectionHeader {
              Layout.fillWidth: true
              text: "TOKEN MIX  ·  INPUT / CACHE WRITE / OUTPUT"
              foreground: panel.foreground
              fontFamily: panel.fontFamily
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
                  Body { text: modelData.name; color: modelData.accent; Layout.preferredWidth: Style.space(52) }
                  Caption {
                    text: "in " + panel.widget.compact(modelData.split.input || 0)
                      + "  ·  cache-w " + panel.widget.compact(modelData.split.cacheWrite || 0)
                      + "  ·  out " + panel.widget.compact(modelData.split.output || 0)
                  }
                  Item { Layout.fillWidth: true }
                  Caption {
                    text: "cache read " + panel.widget.compact(modelData.split.cacheRead || 0)
                      + "  ·  saved " + Math.round(panel.cacheSavings(modelData.split) * 100) + "%"
                    color: modelData.accent
                  }
                }
                Item {
                  Layout.fillWidth: true
                  implicitHeight: Style.space(7)
                  Rectangle { anchors.fill: parent; radius: height / 2; color: panel.faint }
                  Row {
                    anchors.fill: parent
                    Rectangle {
                      height: parent.height
                      width: parent.width * Number(modelData.split.input || 0) / total
                      color: Util.alpha(modelData.accent, 0.45)
                    }
                    Rectangle {
                      height: parent.height
                      width: parent.width * Number(modelData.split.cacheWrite || 0) / total
                      color: Util.alpha(modelData.accent, 0.75)
                    }
                    Rectangle {
                      height: parent.height
                      width: parent.width * Number(modelData.split.output || 0) / total
                      color: modelData.accent
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
                  Body { text: modelData.agent; color: modelData.accent; Layout.preferredWidth: Style.space(52) }
                  Body { text: modelData.limit.label }
                  Item { Layout.fillWidth: true }
                  Caption {
                    text: Math.round(Number(modelData.limit.percent) * 100) + "%  ·  resets "
                      + panel.untilText(modelData.limit.resetsAt)
                      + "  ·  " + Qt.formatDateTime(new Date(Date.parse(String(modelData.limit.resetsAt || ""))), "ddd h:mm AP")
                  }
                }

                Rectangle {
                  Layout.fillWidth: true
                  implicitHeight: Style.space(5)
                  radius: height / 2
                  color: panel.faint
                  Rectangle {
                    anchors.left: parent.left
                    height: parent.height
                    radius: height / 2
                    width: parent.width * Math.max(0, Math.min(1, Number(modelData.limit.percent)))
                    color: panel.widget.gaugeColor(Number(modelData.limit.percent))
                    Behavior on width { NumberAnimation { duration: 500; easing.type: Easing.OutCubic } }
                  }
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
                Body { text: panel.prettyModel(modelData.id); Layout.preferredWidth: Style.space(150); elide: Text.ElideRight }
                Rectangle {
                  Layout.fillWidth: true
                  implicitHeight: Style.space(5)
                  radius: height / 2
                  color: panel.faint
                  Rectangle {
                    height: parent.height
                    radius: height / 2
                    width: parent.width * share
                    color: panel.widget.claudeHot
                  }
                }
                Caption { text: Math.round(share * 100) + "%"; Layout.preferredWidth: Style.space(30); horizontalAlignment: Text.AlignRight }
                Body { text: panel.widget.compact(modelData.tokens); color: panel.widget.claudeHot; font.bold: true; Layout.preferredWidth: Style.space(46); horizontalAlignment: Text.AlignRight }
              }
            }
          }

          // ════ LOCAL ═════════════════════════════════════════════════════════
          ColumnLayout {
            Layout.preferredWidth: columns.rightWidth
            Layout.maximumWidth: columns.rightWidth
            Layout.alignment: Qt.AlignTop
            spacing: Style.space(8)

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
                }
                Rectangle {
                  anchors.centerIn: parent
                  width: parent.width * 0.58; height: width; radius: width / 2
                  color: panel.localState
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
                Text {
                  text: "LOCAL INTELLIGENCE  ·  " + (!panel.localOnline ? "OFFLINE"
                    : panel.localActive ? "INFERENCING" : "IDLE")
                  textFormat: Text.PlainText
                  color: panel.localState
                  font.family: panel.fontFamily
                  font.pixelSize: Style.font.caption
                  font.bold: true
                }
                Caption {
                  Layout.fillWidth: true
                  elide: Text.ElideRight
                  text: panel.svc
                    ? (panel.svc.localGpuName !== "" ? panel.svc.localGpuName.replace("NVIDIA GeForce ", "") : "no NVIDIA GPU")
                      + "  ·  " + String(panel.svc.localBackend).toUpperCase()
                      + (panel.svc.localVersion !== "" ? "  ·  ollama " + panel.svc.localVersion : "")
                    : ""
                }
              }
            }

            // GPU telemetry. A metric the board does not expose reads as 0 and
            // the tile hides its bar rather than drawing a full or empty one.
            GridLayout {
              Layout.fillWidth: true
              columns: 3
              columnSpacing: Style.space(6)
              rowSpacing: Style.space(6)

              StatTile {
                caption: "GPU LOAD"
                value: panel.svc ? String(Math.round(panel.svc.localGpu)) : "--"
                unit: "%"
                sub: "cpu " + (panel.svc ? Math.round(panel.svc.localCpu) : 0) + "%"
                fraction: panel.svc ? panel.svc.localGpu / 100 : 0
                accent: panel.localState
              }
              StatTile {
                caption: "POWER"
                value: panel.svc && panel.svc.localPowerW > 0 ? panel.svc.localPowerW.toFixed(1) : "--"
                unit: "W"
                sub: panel.svc && panel.svc.localPowerLimitW > 0
                  ? "of " + Math.round(panel.svc.localPowerLimitW) + " W"
                  : "peak " + (panel.svc ? panel.svc.localPeakPowerW.toFixed(0) : 0) + " W"
                fraction: panel.svc && panel.svc.localPowerLimitW > 0
                  ? panel.svc.localPowerW / panel.svc.localPowerLimitW
                  : (panel.svc && panel.svc.localPeakPowerW > 0 ? panel.svc.localPowerW / panel.svc.localPeakPowerW : -1)
                accent: "#FFC46B"
              }
              StatTile {
                caption: "TEMP"
                value: panel.svc && panel.svc.localTempC > 0 ? String(Math.round(panel.svc.localTempC)) : "--"
                unit: "°C"
                sub: panel.svc && panel.svc.localFanPct > 0 ? "fan " + Math.round(panel.svc.localFanPct) + "%" : ""
                fraction: panel.svc ? panel.svc.localTempC / 95 : -1
                accent: panel.svc && panel.svc.localTempC >= 85 ? Color.urgent
                  : panel.svc && panel.svc.localTempC >= 70 ? "#facc15" : panel.widget.localHot
              }
              StatTile {
                caption: "VRAM"
                value: panel.svc && panel.svc.localVramTotalMb > 0 ? panel.gb(panel.svc.localVramUsedMb) : "--"
                unit: "/ " + (panel.svc ? panel.gb(panel.svc.localVramTotalMb) : "--") + " GB"
                sub: panel.svc && panel.svc.localVramModelsMb > 0 ? "models " + panel.gb(panel.svc.localVramModelsMb) + " GB" : ""
                fraction: panel.svc && panel.svc.localVramTotalMb > 0 ? panel.svc.localVramUsedMb / panel.svc.localVramTotalMb : -1
                accent: panel.widget.localHot
              }
              StatTile {
                caption: "SM CLOCK"
                value: panel.svc && panel.svc.localClockMhz > 0 ? String(Math.round(panel.svc.localClockMhz)) : "--"
                unit: "MHz"
                sub: panel.svc && panel.svc.localClockMaxMhz > 0 ? "max " + Math.round(panel.svc.localClockMaxMhz) : ""
                fraction: panel.svc && panel.svc.localClockMaxMhz > 0 ? panel.svc.localClockMhz / panel.svc.localClockMaxMhz : -1
                accent: panel.widget.localHot
              }
              StatTile {
                caption: "SAMPLED"
                value: panel.svc && panel.svc.localSampledAt > 0
                  ? String(Math.round(Math.max(0, Date.now() - panel.svc.localSampledAt + panel.tick * 0) / 1000)) : "--"
                unit: "s ago"
                sub: "every " + (panel.svc ? (panel.svc.localRefreshMs / 1000).toFixed(1) : "--") + "s"
                fraction: -1
                accent: panel.dim
              }
            }

            Trace {
              caption: "LOAD  ·  last " + ((panel.svc ? panel.svc.localCells * panel.svc.localRefreshMs / 1000 : 0).toFixed(0)) + "s"
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
              accent: "#FFC46B"
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
                  Body { text: panel.plainText(modelData.name, 64); color: panel.widget.localHot; font.bold: true; elide: Text.ElideRight; Layout.fillWidth: true }
                  Caption {
                    // "evicts in 4m" is the number that matters: it is when the
                    // next request pays the load cost again.
                    text: modelData.expiresAt && Date.parse(String(modelData.expiresAt)) - Date.now() > 315360000000
                      ? "pinned" : "evicts " + panel.untilText(modelData.expiresAt)
                  }
                }
                Caption {
                  Layout.fillWidth: true
                  elide: Text.ElideRight
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
              text: "MODEL CONTROL"
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
              Caption {
                text: panel.localOptions.length + " installed"
              }
            }

            Caption {
              Layout.fillWidth: true
              visible: panel.localNote !== ""
              text: panel.localNote
              color: panel.localState
              wrapMode: Text.WordWrap
            }
          }
        }

        PanelSeparator { Layout.fillWidth: true; foreground: panel.foreground }

        RowLayout {
          Layout.fillWidth: true
          Caption {
            text: panel.svc && panel.svc.lastError !== "" ? panel.svc.lastError
              : "Claude ◄ now ► Codex  ║  Local  ·  colour is heat  ·  cloud is tokens per bucket, local is runner load per second"
            color: panel.svc && panel.svc.lastError !== "" ? Color.urgent : panel.dim
            Layout.fillWidth: true
            elide: Text.ElideRight
          }
          Caption {
            text: "collected " + panel.agoText(panel.svc ? panel.svc.generatedAt : 0)
              + "  ·  click: panel  ·  middle: refresh  ·  R: refresh  ·  Esc: close"
          }
        }
      }
    }
  }
}
