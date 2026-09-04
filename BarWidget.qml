import QtQuick
import Quickshell
import qs.Commons
import qs.Ui

// Burn Bar — a live thermal strip of agent token spend.
//
// Claude burns on the left, Codex on the right, and the newest bucket for BOTH
// sits against the centre divider. Time radiates outward, so the divider is
// always "now" and the two agents read as one instrument rather than two
// widgets that happen to be adjacent.
//
// This is a heat map first: COLOUR carries the token count, on a ramp that runs
// cold ember → agent colour → amber → white-hot. Height is only a secondary
// swell (72%→100%) so the strip has a living profile instead of reading as a
// flat gradient bar. Cells are centred vertically, which makes it a glowing core
// rather than bars standing on a floor.
//
// The two thin columns on the outer edges measure something different entirely —
// percent of the weekly plan limit — and are drawn in a deliberately different
// visual language so the two scales are never confused.
BarWidget {
  id: root
  moduleName: "nixfred.burnbar"

  property var anchorItem: button

  readonly property var svc: bar && bar.shell ? bar.shell.serviceFor(moduleName) : null
  readonly property bool ready: svc ? svc.ready : false
  readonly property var buckets: svc ? svc.buckets : []

  readonly property int configuredWidth: Math.max(90, Math.min(320, Number(setting("width", 168)) || 168))
  readonly property int cellCount: Math.max(6, Math.min(32, Number(setting("bars", 16)) || 16))
  readonly property bool showGauges: setting("showGauges", true) !== false
  readonly property bool emberFlicker: setting("emberFlicker", true) !== false

  implicitWidth: vertical ? barSize : Style.spaceReal(configuredWidth)
  implicitHeight: vertical ? Style.spaceReal(configuredWidth) : barSize

  function setting(name, fallback) {
    var value = settings ? settings[name] : undefined
    return value === undefined || value === null ? fallback : value
  }

  function syncServiceSettings() { if (svc) svc.settings = settings || ({}) }
  onSvcChanged: syncServiceSettings()
  onSettingsChanged: syncServiceSettings()

  // ── heat ramp ─────────────────────────────────────────────────────────────
  // Both agents converge on the same amber/white at the top end, because hot is
  // hot — a maxed-out Codex burst and a maxed-out Claude burst should look
  // equally alarming. Identity lives in the cold and mid stops.
  readonly property color claudeCold: "#4A2113"
  readonly property color claudeWarm: "#C4542A"
  readonly property color claudeHot:  "#FF8A4B"

  readonly property color codexCold: "#0C3E33"
  readonly property color codexWarm: "#12977A"
  readonly property color codexHot:  "#2BE8B0"

  readonly property color emberAmber: "#FFC46B"
  readonly property color whiteHot:   "#FFF6EC"

  readonly property color urgent: Color.urgent

  function mix(a, b, t) {
    var u = Math.max(0, Math.min(1, t))
    return Qt.rgba(a.r + (b.r - a.r) * u,
                   a.g + (b.g - a.g) * u,
                   a.b + (b.b - a.b) * u,
                   a.a + (b.a - a.a) * u)
  }

  // cold → warm → hot → amber → white. Four segments, deliberately uneven: most
  // of the resolution sits in the low-mid where day-to-day burn actually lives.
  function heat(level, cold, warm, hot) {
    var l = Math.max(0, Math.min(1, level))
    if (l < 0.30) return mix(cold, warm, l / 0.30)
    if (l < 0.62) return mix(warm, hot, (l - 0.30) / 0.32)
    if (l < 0.86) return mix(hot, emberAmber, (l - 0.62) / 0.24)
    return mix(emberAmber, whiteHot, (l - 0.86) / 0.14)
  }

  // ── scale ─────────────────────────────────────────────────────────────────
  // A power curve, not a log one. Log flatters idleness — a 1k-token blip would
  // read half as hot as a 1M-token burst and the strip would look busy when it
  // is not. ^0.45 keeps small burns visible without lying about magnitude.
  readonly property real scaleFloor: 150000
  readonly property real claudeRef: Math.max(svc ? svc.claudePeak : 0, scaleFloor)
  readonly property real codexRef: Math.max(svc ? svc.codexPeak : 0, scaleFloor)

  function norm(tokens, reference) {
    if (!(tokens > 0)) return 0
    return Math.min(1, Math.pow(tokens / Math.max(1, reference), 0.45))
  }

  // Claude reads oldest→newest left to right, ending at the divider.
  function claudeAt(i) {
    var b = root.buckets
    if (!b || !b.length) return 0
    var idx = b.length - root.cellCount + i
    return idx >= 0 && idx < b.length ? Number(b[idx].claude || 0) : 0
  }

  // Codex mirrors it: newest sits against the divider and time runs rightward.
  function codexAt(i) {
    var b = root.buckets
    if (!b || !b.length) return 0
    var idx = b.length - 1 - i
    return idx >= 0 && idx < b.length ? Number(b[idx].codex || 0) : 0
  }

  function compact(n) {
    var v = Number(n) || 0
    if (v >= 1e9) return (v / 1e9).toFixed(1) + "B"
    if (v >= 1e6) return (v / 1e6).toFixed(1) + "M"
    if (v >= 1e3) return (v / 1e3).toFixed(0) + "k"
    return String(Math.round(v))
  }

  function gaugeColor(percent) {
    if (percent >= 0.9) return urgent
    if (percent >= 0.75) return "#facc15"
    return "#22c55e"
  }

  // ── ember motion ──────────────────────────────────────────────────────────
  // Driven by a 20fps timer rather than a frame-rate NumberAnimation: with up to
  // 64 cells each re-deriving colour from the phase, 60fps would be three times
  // the property churn for flicker nobody can see.
  property real emberPhase: 0
  Timer {
    interval: 50
    running: root.emberFlicker && root.visible
    repeat: true
    onTriggered: root.emberPhase = (root.emberPhase + 0.19) % (Math.PI * 2)
  }

  // Nothing burning is a real and common state, and a dead-flat widget reads as
  // broken. A slow travelling swell keeps the strip alive without inventing data.
  readonly property bool idle: !ready
    || ((svc ? svc.claudeLatest : 0) <= 0 && (svc ? svc.codexLatest : 0) <= 0)

  property real claudeFlash: 0
  property real codexFlash: 0

  SequentialAnimation {
    id: claudeImpact
    NumberAnimation { target: root; property: "claudeFlash"; to: 1; duration: 90; easing.type: Easing.OutQuad }
    NumberAnimation { target: root; property: "claudeFlash"; to: 0; duration: 700; easing.type: Easing.OutCubic }
  }
  SequentialAnimation {
    id: codexImpact
    NumberAnimation { target: root; property: "codexFlash"; to: 1; duration: 90; easing.type: Easing.OutQuad }
    NumberAnimation { target: root; property: "codexFlash"; to: 0; duration: 700; easing.type: Easing.OutCubic }
  }

  Connections {
    target: root.svc
    function onClaudePulseChanged() { claudeImpact.restart() }
    function onCodexPulseChanged() { codexImpact.restart() }
  }

  WidgetButton {
    id: button
    anchors.fill: parent
    bar: root.bar
    text: ""
    labelVisible: false
    hasVisualContent: true
    fixedWidth: root.configuredWidth
    active: false
    useActiveColor: false
    tooltipText: !root.ready
      ? "Burn Bar — waiting for first sample"
      : "Claude " + root.compact(root.svc.claudeTotal) + "  ·  Codex " + root.compact(root.svc.codexTotal)
        + "\nlast " + Math.round((root.svc ? root.svc.windowMinutes : 360) / 60) + "h"
        + "  ·  weekly " + Math.round(root.svc.claudeWeekly * 100) + "% / " + Math.round(root.svc.codexWeekly * 100) + "%"

    Item {
      id: graph
      anchors.centerIn: parent
      width: parent.width - Style.space(6)
      height: Math.max(Style.space(12), Math.round(parent.height * 0.62))

      readonly property int gaugeWidth: root.showGauges ? Style.space(3) : 0
      readonly property int gaugeGap: root.showGauges ? Style.space(3) : 0
      readonly property int dividerWidth: Style.space(3)
      readonly property real sideWidth: Math.max(1,
        (width - dividerWidth - 2 * (gaugeWidth + gaugeGap)) / 2)
      readonly property real slot: sideWidth / root.cellCount
      readonly property real cellWidth: Math.max(1, slot - Style.spaceReal(1))

      // Claude weekly fuel gauge — far left, outermost.
      Item {
        id: claudeGauge
        visible: root.showGauges
        width: graph.gaugeWidth
        height: parent.height
        anchors.left: parent.left
        anchors.verticalCenter: parent.verticalCenter

        Rectangle {
          anchors.fill: parent
          radius: width / 2
          color: Util.alpha(root.claudeHot, 0.14)
        }
        Rectangle {
          anchors.bottom: parent.bottom
          anchors.horizontalCenter: parent.horizontalCenter
          width: parent.width
          radius: width / 2
          height: Math.max(1, parent.height * Math.min(1, root.svc ? root.svc.claudeWeekly : 0))
          color: root.gaugeColor(root.svc ? root.svc.claudeWeekly : 0)
          Behavior on height { NumberAnimation { duration: 900; easing.type: Easing.OutCubic } }
          Behavior on color { ColorAnimation { duration: 400 } }

          // Quota nearly gone gets its own heartbeat — you should not have to
          // read a number to learn you are about to be cut off.
          SequentialAnimation on opacity {
            running: (root.svc ? root.svc.claudeWeekly : 0) >= 0.9
            loops: Animation.Infinite
            NumberAnimation { to: 0.35; duration: 700; easing.type: Easing.InOutQuad }
            NumberAnimation { to: 1.0; duration: 700; easing.type: Easing.InOutQuad }
          }
        }
      }

      // ── Claude thermal cells ────────────────────────────────────────────────
      Item {
        id: claudeCells
        width: graph.sideWidth
        height: parent.height
        anchors.left: root.showGauges ? claudeGauge.right : parent.left
        anchors.leftMargin: graph.gaugeGap
        anchors.verticalCenter: parent.verticalCenter

        Repeater {
          model: root.cellCount
          delegate: Item {
            id: ccell
            required property int index

            readonly property real tokens: root.claudeAt(index)
            // 0 at the outer edge, 1 against the divider: newest is brightest.
            readonly property real recency: root.cellCount <= 1 ? 1 : index / (root.cellCount - 1)
            readonly property real level: root.norm(tokens, root.claudeRef)
            readonly property bool live: index === root.cellCount - 1

            // Hot cells flicker harder — cold coals sit still, a live fire does not.
            readonly property real flicker: root.emberFlicker
              ? Math.sin(root.emberPhase * 1.7 + index * 0.8) * 0.06 * level
                + Math.sin(root.emberPhase * 3.1 - index * 0.4) * 0.035 * level
              : 0
            readonly property real idleSwell: root.idle
              ? 0.06 + Math.sin(root.emberPhase * 0.35 + index * 0.42) * 0.05 : 0

            readonly property real heatLevel: Math.max(0,
              level + flicker + root.claudeFlash * recency * recency * 0.25 + idleSwell)

            width: graph.cellWidth
            height: parent.height
            x: index * graph.slot
            anchors.verticalCenter: parent.verticalCenter

            // Height is the secondary channel: a 60%→100% swell that gives the
            // strip a profile without stealing the story from colour.
            readonly property real cellHeight:
              parent.height * (0.72 + 0.28 * Math.min(1, ccell.heatLevel))

            // Bloom: a wider, softer ghost behind the cell. A cheap fake glow
            // that costs one rectangle instead of a blur pass.
            Rectangle {
              anchors.centerIn: parent
              width: parent.width + Style.spaceReal(3)
              height: ccell.cellHeight + Style.spaceReal(3)
              radius: Style.spaceReal(2)
              color: root.heat(ccell.heatLevel, root.claudeCold, root.claudeWarm, root.claudeHot)
              opacity: Math.pow(ccell.level, 1.6) * 0.42 * (0.4 + 0.6 * ccell.recency)
                + root.claudeFlash * ccell.recency * ccell.recency * 0.45
              Behavior on height { NumberAnimation { duration: 420; easing.type: Easing.OutCubic } }
            }

            Rectangle {
              anchors.centerIn: parent
              width: parent.width
              height: ccell.cellHeight
              radius: Style.spaceReal(1)
              color: root.heat(ccell.heatLevel, root.claudeCold, root.claudeWarm, root.claudeHot)
              // Age fades toward the outer edge, so the strip reads as a comet
              // tail pointing at now.
              opacity: 0.58 + 0.42 * ccell.recency
              // Rectangle.border.width defaults to 1, not 0. Left implicit it
              // outlines every cell and the strip reads as a hollow comb.
              border.width: 0
              Behavior on height { NumberAnimation { duration: 420; easing.type: Easing.OutCubic } }
            }

            // The live cell breathes continuously between collector samples so
            // the strip never looks frozen at 5-second granularity. It rides on
            // its own overlay so it can never leak a border onto the fill.
            Rectangle {
              visible: ccell.live && !root.idle
              anchors.centerIn: parent
              width: parent.width
              height: ccell.cellHeight
              radius: Style.spaceReal(1)
              color: "transparent"
              border.color: root.whiteHot
              border.width: Style.spaceReal(1)
              opacity: 0
              SequentialAnimation on opacity {
                running: ccell.live && !root.idle
                loops: Animation.Infinite
                NumberAnimation { to: 0.55; duration: 900; easing.type: Easing.InOutQuad }
                NumberAnimation { to: 0.0; duration: 900; easing.type: Easing.InOutQuad }
              }
            }
          }
        }
      }

      // ── the now line ────────────────────────────────────────────────────────
      Item {
        id: divider
        width: graph.dividerWidth
        height: parent.height
        anchors.horizontalCenter: parent.horizontalCenter
        anchors.verticalCenter: parent.verticalCenter

        Rectangle {
          anchors.centerIn: parent
          width: Style.spaceReal(1.5)
          height: parent.height + Style.spaceReal(3)
          radius: width / 2
          color: root.bar ? root.bar.barForeground : Color.foreground
          opacity: 0.38 + 0.55 * Math.max(root.claudeFlash, root.codexFlash)
        }

        // Impact rings: one flick outward per side when new burn lands.
        Rectangle {
          anchors.centerIn: parent
          width: Style.spaceReal(3) + root.claudeFlash * Style.spaceReal(10)
          height: width
          radius: width / 2
          color: "transparent"
          border.width: Style.spaceReal(1)
          border.color: root.claudeHot
          opacity: root.claudeFlash * 0.85
        }
        Rectangle {
          anchors.centerIn: parent
          width: Style.spaceReal(3) + root.codexFlash * Style.spaceReal(10)
          height: width
          radius: width / 2
          color: "transparent"
          border.width: Style.spaceReal(1)
          border.color: root.codexHot
          opacity: root.codexFlash * 0.85
        }
      }

      // ── Codex thermal cells — mirrored, newest against the divider ──────────
      Item {
        id: codexCells
        width: graph.sideWidth
        height: parent.height
        anchors.left: divider.right
        anchors.verticalCenter: parent.verticalCenter

        Repeater {
          model: root.cellCount
          delegate: Item {
            id: xcell
            required property int index

            readonly property real tokens: root.codexAt(index)
            readonly property real recency: root.cellCount <= 1 ? 1 : 1 - index / (root.cellCount - 1)
            readonly property real level: root.norm(tokens, root.codexRef)
            readonly property bool live: index === 0

            readonly property real flicker: root.emberFlicker
              ? Math.sin(root.emberPhase * 1.7 - index * 0.8) * 0.06 * level
                + Math.sin(root.emberPhase * 3.1 + index * 0.4) * 0.035 * level
              : 0
            readonly property real idleSwell: root.idle
              ? 0.06 + Math.sin(root.emberPhase * 0.35 - index * 0.42) * 0.05 : 0

            readonly property real heatLevel: Math.max(0,
              level + flicker + root.codexFlash * recency * recency * 0.25 + idleSwell)

            width: graph.cellWidth
            height: parent.height
            x: index * graph.slot
            anchors.verticalCenter: parent.verticalCenter

            readonly property real cellHeight:
              parent.height * (0.72 + 0.28 * Math.min(1, xcell.heatLevel))

            Rectangle {
              anchors.centerIn: parent
              width: parent.width + Style.spaceReal(3)
              height: xcell.cellHeight + Style.spaceReal(3)
              radius: Style.spaceReal(2)
              color: root.heat(xcell.heatLevel, root.codexCold, root.codexWarm, root.codexHot)
              opacity: Math.pow(xcell.level, 1.6) * 0.42 * (0.4 + 0.6 * xcell.recency)
                + root.codexFlash * xcell.recency * xcell.recency * 0.45
              Behavior on height { NumberAnimation { duration: 420; easing.type: Easing.OutCubic } }
            }

            Rectangle {
              anchors.centerIn: parent
              width: parent.width
              height: xcell.cellHeight
              radius: Style.spaceReal(1)
              color: root.heat(xcell.heatLevel, root.codexCold, root.codexWarm, root.codexHot)
              opacity: 0.58 + 0.42 * xcell.recency
              border.width: 0
              Behavior on height { NumberAnimation { duration: 420; easing.type: Easing.OutCubic } }
            }

            Rectangle {
              visible: xcell.live && !root.idle
              anchors.centerIn: parent
              width: parent.width
              height: xcell.cellHeight
              radius: Style.spaceReal(1)
              color: "transparent"
              border.color: root.whiteHot
              border.width: Style.spaceReal(1)
              opacity: 0
              SequentialAnimation on opacity {
                running: xcell.live && !root.idle
                loops: Animation.Infinite
                NumberAnimation { to: 0.55; duration: 900; easing.type: Easing.InOutQuad }
                NumberAnimation { to: 0.0; duration: 900; easing.type: Easing.InOutQuad }
              }
            }
          }
        }
      }

      // Codex weekly fuel gauge — far right, outermost.
      Item {
        id: codexGauge
        visible: root.showGauges
        width: graph.gaugeWidth
        height: parent.height
        anchors.right: parent.right
        anchors.verticalCenter: parent.verticalCenter

        Rectangle {
          anchors.fill: parent
          radius: width / 2
          color: Util.alpha(root.codexHot, 0.14)
        }
        Rectangle {
          anchors.bottom: parent.bottom
          anchors.horizontalCenter: parent.horizontalCenter
          width: parent.width
          radius: width / 2
          height: Math.max(1, parent.height * Math.min(1, root.svc ? root.svc.codexWeekly : 0))
          color: root.gaugeColor(root.svc ? root.svc.codexWeekly : 0)
          Behavior on height { NumberAnimation { duration: 900; easing.type: Easing.OutCubic } }
          Behavior on color { ColorAnimation { duration: 400 } }

          SequentialAnimation on opacity {
            running: (root.svc ? root.svc.codexWeekly : 0) >= 0.9
            loops: Animation.Infinite
            NumberAnimation { to: 0.35; duration: 700; easing.type: Easing.InOutQuad }
            NumberAnimation { to: 1.0; duration: 700; easing.type: Easing.InOutQuad }
          }
        }
      }
    }

    onPressed: function(code) {
      if (code === Qt.MiddleButton) { if (root.svc) root.svc.collect() }
      else root.toggle()
    }
  }

  readonly property bool opened: panel.opened
  function open() { panel.controller.show(); if (svc) svc.collect() }
  function close() { panel.controller.hide() }
  function toggle() { opened ? close() : open() }
  function closeForPopoutSwitch() { close() }
  readonly property bool popoutSwitchClosing: false

  BurnPanel {
    id: panel
    widget: root
  }

}
