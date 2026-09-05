import QtQuick
import QtQuick.Layouts
import Quickshell
import qs.Commons
import qs.Ui

// Detail view for Burn Bar. The bar answers "is something burning right now";
// this is the cockpit: what, how much, how fast and how close to the wall —
// all in one glance, never a scroll.
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

  readonly property int panelWidth: Style.space(560)

  // Relative times ("3m ago", "resets in 4m") go stale the moment they are
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
    }
  }

  // R, the header button, and opening the panel all take the same path: ask
  // Omarchy for fresh plan limits and re-run the collector.
  function refreshAll() {
    if (svc) { svc.refreshLimits(); svc.collect() }
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

  // ── derived metrics ───────────────────────────────────────────────────────
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
    return agent === "claude" ? svc.claudeTrailing5 : svc.codexTrailing5
  }
  function trailing60(agent) {
    if (!svc) return 0
    return agent === "claude" ? svc.claudeTrailing60 : svc.codexTrailing60
  }
  function windowTotal(agent) {
    if (!svc) return 0
    return agent === "claude" ? svc.claudeTotal : svc.codexTotal
  }
  function rateNow(agent) { return trailing5(agent) / 5 }
  function rateHour(agent) { return trailing60(agent) / 60 }
  function rateWindow(agent) { return windowTotal(agent) / Math.max(1, windowMinutes) }
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
            + ((panel.svc ? panel.svc.claudeTurns + panel.svc.codexTurns : 0)) + " turns  ·  "
            + ((panel.svc ? panel.svc.claudeSessions + panel.svc.codexSessions : 0)) + " sessions"
          detail: panel.svc
            ? panel.widget.compact(panel.rateNow("claude") + panel.rateNow("codex")) + "/min last 5m  ·  "
              + panel.widget.compact(panel.rateHour("claude") + panel.rateHour("codex")) + "/min last hour  ·  "
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

        // ── two tiles, same order as the bar ─────────────────────────────────
        RowLayout {
          Layout.fillWidth: true
          spacing: Style.space(8)
          opacity: panel.reveal
          transform: Translate { y: (1 - panel.reveal) * 8 }

          // A fixed model of two keys. A model built as a fresh array of
          // values was replaced on every tick, which destroyed and recreated
          // the tiles — and a recreated Counter initialises straight to its
          // target, so the count-up never showed.
          Repeater {
            model: ["claude", "codex"]
            delegate: Rectangle {
              id: tile
              required property string modelData
              readonly property bool isClaude: modelData === "claude"
              readonly property var s: panel.svc
              readonly property color accent: isClaude ? panel.widget.claudeHot : panel.widget.codexHot
              readonly property real value: !s ? 0 : isClaude ? s.claudeTotal : s.codexTotal
              readonly property var format: panel.widget.compact
              readonly property string sub: {
                void panel.tick
                if (!s) return ""
                if (isClaude) return s.claudeTurns + " turns · " + s.claudeSessions + " sessions · "
                  + panel.widget.compact(panel.rateNow("claude")) + "/min"
                return s.codexTurns + " turns · " + s.codexSessions + " sessions · "
                  + panel.widget.compact(panel.rateNow("codex")) + "/min"
              }
              readonly property string sub2: {
                void panel.tick
                if (!s) return ""
                if (isClaude) return "peak " + panel.widget.compact(s.claudePeak) + " at " + panel.clockText(s.claudePeakAt)
                  + " · active " + panel.agoText(s.claudeLastAt)
                return "peak " + panel.widget.compact(s.codexPeak) + " at " + panel.clockText(s.codexPeakAt)
                  + " · active " + panel.agoText(s.codexLastAt)
              }

              Layout.fillWidth: true
              implicitHeight: Style.space(76)
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
                  Caption { text: tile.modelData.toUpperCase(); color: panel.foreground; font.bold: true }
                }
                Caption { text: tile.sub; Layout.fillWidth: true }
                Caption { text: tile.sub2; Layout.fillWidth: true }
              }
            }
          }
        }

        ColumnLayout {
          Layout.fillWidth: true
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

            Body { text: "Claude"; color: panel.widget.claudeHot; Layout.fillWidth: true }
            Counter { target: panel.rateNow("claude"); format: panel.widget.compact; color: panel.foreground; font.bold: true; font.pixelSize: Style.font.bodySmall; Layout.preferredWidth: Style.space(58); horizontalAlignment: Text.AlignRight }
            Counter { target: panel.rateHour("claude"); format: panel.widget.compact; color: panel.foreground; font.pixelSize: Style.font.bodySmall; Layout.preferredWidth: Style.space(58); horizontalAlignment: Text.AlignRight }
            Counter { target: panel.rateWindow("claude"); format: panel.widget.compact; color: panel.foreground; font.pixelSize: Style.font.bodySmall; Layout.preferredWidth: Style.space(58); horizontalAlignment: Text.AlignRight }

            Body { text: "Codex"; color: panel.widget.codexHot; Layout.fillWidth: true }
            Counter { target: panel.rateNow("codex"); format: panel.widget.compact; color: panel.foreground; font.bold: true; font.pixelSize: Style.font.bodySmall; Layout.preferredWidth: Style.space(58); horizontalAlignment: Text.AlignRight }
            Counter { target: panel.rateHour("codex"); format: panel.widget.compact; color: panel.foreground; font.pixelSize: Style.font.bodySmall; Layout.preferredWidth: Style.space(58); horizontalAlignment: Text.AlignRight }
            Counter { target: panel.rateWindow("codex"); format: panel.widget.compact; color: panel.foreground; font.pixelSize: Style.font.bodySmall; Layout.preferredWidth: Style.space(58); horizontalAlignment: Text.AlignRight }

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
              return [
                { name: "Claude", accent: panel.widget.claudeHot, split: panel.svc ? panel.svc.claudeSplit : ({}) },
                { name: "Codex", accent: panel.widget.codexHot, split: panel.svc ? panel.svc.codexSplit : ({}) }
              ]
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
            text: "PLAN LIMITS"
            foreground: panel.foreground
            fontFamily: panel.fontFamily
          }

          // The record behind each agent's limits, when it is not to be
          // trusted: written too long ago, carrying a status ("Sign-in
          // expired"), or unrefreshable because the Omarchy collector is
          // missing. Silent otherwise — a healthy record needs no caption.
          Repeater {
            model: {
              void panel.tick
              var out = []
              if (!panel.svc) return out
              var rows = [
                { agent: "Claude", accent: panel.widget.claudeHot, limits: panel.svc.claudeLimits,
                  updatedAt: panel.svc.claudeLimitsMeasuredAt, status: panel.svc.claudeLimitsStatus },
                { agent: "Codex", accent: panel.widget.codexHot, limits: panel.svc.codexLimits,
                  updatedAt: panel.svc.codexLimitsMeasuredAt, status: panel.svc.codexLimitsStatus }
              ]
              for (var i = 0; i < rows.length; i++) {
                var r = rows[i]
                // No record and nothing to say: this agent is simply not
                // in use here. Do not nag about it.
                if (r.limits.length === 0 && r.status === "") continue
                var stale = panel.svc.limitsStale(r.updatedAt)
                var parts = []
                if (r.status !== "") parts.push(r.status)
                var t = Number(r.updatedAt) || 0
                if (t > 0) parts.push("measured " + Qt.formatDateTime(new Date(t), "ddd h:mm AP") + (stale ? "  ·  stale" : ""))
                else parts.push("no measurement time")
                if (panel.svc.limitsRefreshUnavailable) parts.push("omarchy-agent-usage-update not found, cannot refresh")
                if (!stale && r.status === "" && !panel.svc.limitsRefreshUnavailable) continue
                r.text = parts.join("  ·  ")
                out.push(r)
              }
              return out
            }
            delegate: RowLayout {
              required property var modelData
              Layout.fillWidth: true
              spacing: Style.space(6)
              Body { text: modelData.agent; color: modelData.accent; Layout.preferredWidth: Style.space(48) }
              Caption { text: modelData.text; color: Color.urgent; Layout.fillWidth: true }
            }
          }

          Repeater {
            model: {
              var out = []
              var c = panel.svc ? panel.svc.claudeLimits : []
              var x = panel.svc ? panel.svc.codexLimits : []
              var cAt = panel.svc ? panel.svc.claudeLimitsMeasuredAt : 0
              var xAt = panel.svc ? panel.svc.codexLimitsMeasuredAt : 0
              for (var i = 0; i < c.length; i++)
                out.push({ agent: "Claude", accent: panel.widget.claudeHot, limit: c[i], updatedAt: cAt })
              for (var j = 0; j < x.length; j++)
                out.push({ agent: "Codex", accent: panel.widget.codexHot, limit: x[j], updatedAt: xAt })
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
                return panel.svc ? panel.svc.limitsStale(modelData.updatedAt) : true
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
            readonly property var rows: panel.sortedModels(panel.svc ? panel.svc.claudeByModel : ({}))
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
        }

        PanelSeparator { Layout.fillWidth: true; foreground: panel.foreground }

        RowLayout {
          Layout.fillWidth: true
          spacing: Style.space(12)
          Caption {
            Layout.fillWidth: true
            text: panel.svc && panel.svc.lastError !== "" ? panel.svc.lastError
              : "Claude ◄ now ► Codex  ·  colour is heat  ·  one cell per bucket, newest against the now line"
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
