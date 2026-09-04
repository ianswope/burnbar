import QtQuick
import Quickshell
import qs.Commons
import qs.Ui

// Burn Bar — one live thermal instrument for every model you run.
//
//   CLAUDE ◄── time ──┤ now ├── time ──► CODEX  ║  LOCAL ──► seconds
//
// Claude burns on the left and Codex on the right, both with their newest
// bucket against the shared centre line, so the divider is always "now" and the
// two cloud agents read as one instrument instead of two adjacent widgets.
// Local intelligence (Ollama) is bolted on the right behind a hard rule, in a
// deliberately narrower lane: it measures something else entirely — live runner
// load per second, not tokens per quarter hour — and must never be mistaken for
// a third column of the same scale.
//
// This is a heat map first: COLOUR carries the magnitude, on a per-agent ramp
// that runs cold ember → agent identity → amber → white-hot. Height is only a
// secondary swell (72%→100%) so the strip has a living profile instead of
// reading as a flat gradient bar. Cells are centred vertically, which makes it
// a glowing core rather than bars standing on a floor.
//
// Motion is data, never decoration:
//   · ember flicker      scales with a cell's own heat — cold coals sit still
//   · impact shockwave   fires outward from the now line when new burn lands
//   · rising sparks      density and speed follow total energy across all three
//   · idle drift         a slow travelling swell, so calm never looks broken
//   · fault              hard red, no idle animation, so an outage cannot hide
BarWidget {
  id: root
  moduleName: "nixfred.burnbar"

  property var anchorItem: button

  readonly property var svc: bar && bar.shell ? bar.shell.serviceFor(moduleName) : null
  readonly property bool ready: svc ? svc.ready : false
  readonly property var buckets: svc ? svc.buckets : []

  readonly property int configuredWidth: Math.max(110, Math.min(400, Number(setting("width", 158)) || 158))
  readonly property int cellCount: Math.max(6, Math.min(32, Number(setting("bars", 12)) || 12))
  readonly property int localCells: Math.max(4, Math.min(20, Number(setting("localCells", 9)) || 9))
  readonly property bool showGauges: setting("showGauges", true) !== false
  readonly property bool showLocal: setting("showLocal", true) !== false
  readonly property bool emberFlicker: setting("emberFlicker", true) !== false
  readonly property bool sparks: setting("sparks", true) !== false

  implicitWidth: vertical ? barSize : Style.spaceReal(configuredWidth)
  implicitHeight: vertical ? Style.spaceReal(configuredWidth) : barSize

  // ── zones ─────────────────────────────────────────────────────────────────
  // The widget is three instruments in one slot, so each gets a tinted plate
  // and a coloured baseline in its own identity hue. Hovering a zone names it
  // and reports only that agent — a single blended tooltip made you do the
  // arithmetic of working out which number belonged to which lane.
  readonly property int zoneNone: -1
  readonly property int zoneClaude: 0
  readonly property int zoneCodex: 1
  readonly property int zoneLocal: 2

  property int hoverZone: zoneNone
  // The bar only offers a tooltip to a target that reports itself hovered, and
  // our own overlay takes the hover away from WidgetButton's MouseArea — so
  // this widget becomes the tooltip target in its place.
  readonly property bool tooltipHovered: zoneHover.containsMouse && visible

  function zoneAccent(zone) {
    if (zone === zoneCodex) return codexHot
    if (zone === zoneLocal) return showLocal && !localOnline ? urgent : localHot
    return claudeHot
  }

  function zoneTooltip(zone) {
    if (!svc) return "Burn Bar — starting up"
    if (broken && zone !== zoneLocal)
      return "CLOUD FAULT — " + (svc.lastError || "collector failed")
    var hours = Math.round((svc.windowMinutes || 360) / 60)
    if (zone === zoneClaude)
      return "CLAUDE  ·  " + compact(svc.claudeTotal) + " tokens / last " + hours + "h"
        + "\nnow " + compact(svc.claudeLatest) + " this bucket  ·  " + svc.claudeSessions + " sessions"
        + "\nweekly quota " + Math.round(svc.claudeWeekly * 100) + "%"
    if (zone === zoneCodex)
      return "CODEX  ·  " + compact(svc.codexTotal) + " tokens / last " + hours + "h"
        + "\nnow " + compact(svc.codexLatest) + " this bucket  ·  " + svc.codexSessions + " sessions"
        + "\nweekly quota " + Math.round(svc.codexWeekly * 100) + "%"
    if (zone === zoneLocal)
      return "LOCAL  ·  " + (!svc.localOnline
          ? "Ollama offline" + (svc.localError !== "" ? "\n" + svc.localError : "")
          : (svc.localActive ? "inferencing " : "idle ") + Math.round(svc.localLoad) + "%"
            + "  ·  " + String(svc.localBackend).toUpperCase()
            + "\n" + (svc.localModel !== "" ? svc.localModel : "no model resident")
            + "\n" + svc.localModelCount + " model(s) warm")
    return ""
  }

  function updateZone(x) {
    var zone = graph.zoneAt(x - graph.x)
    if (zone === hoverZone) return
    hoverZone = zone
    // showTooltip re-checks tooltipHovered on this widget, so a stale request
    // from a pointer that has already left resolves to nothing.
    if (bar) bar.showTooltip(root, zoneTooltip(zone))
  }

  function setting(name, fallback) {
    var value = settings ? settings[name] : undefined
    return value === undefined || value === null ? fallback : value
  }

  function syncServiceSettings() { if (svc) svc.settings = settings || ({}) }
  onSvcChanged: syncServiceSettings()
  onSettingsChanged: syncServiceSettings()

  // ── heat ramps ────────────────────────────────────────────────────────────
  // All three agents converge on the same amber/white at the top end, because
  // hot is hot — a maxed-out local runner and a maxed-out Claude burst should
  // look equally alarming. Identity lives in the cold and mid stops: Claude
  // burns orange, Codex burns teal, local burns violet. Three hues that stay
  // separable at 3px wide and in every Omarchy theme.
  readonly property color claudeCold: "#4A2113"
  readonly property color claudeWarm: "#C4542A"
  readonly property color claudeHot:  "#FF8A4B"

  readonly property color codexCold: "#0C3E33"
  readonly property color codexWarm: "#12977A"
  readonly property color codexHot:  "#2BE8B0"

  readonly property color localCold: "#241046"
  readonly property color localWarm: "#7A3BE0"
  readonly property color localHot:  "#C79BFF"

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
    if (root.broken) return Qt.rgba(urgent.r, urgent.g, urgent.b, 1)
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
  function claudeLevel(i) {
    var b = root.buckets
    if (!b || !b.length) return 0
    var idx = b.length - root.cellCount + i
    return root.norm(idx >= 0 && idx < b.length ? Number(b[idx].claude || 0) : 0, root.claudeRef)
  }

  // Codex mirrors it: newest sits against the divider and time runs rightward.
  function codexLevel(i) {
    var b = root.buckets
    if (!b || !b.length) return 0
    var idx = b.length - 1 - i
    return root.norm(idx >= 0 && idx < b.length ? Number(b[idx].codex || 0) : 0, root.codexRef)
  }

  // Local is already a percentage, so it needs no reference peak — but it does
  // need the same gamma, or a 40% GPU would read cooler than a small token blip
  // sitting right next to it.
  function localLevel(i) {
    var h = svc ? svc.localHistory : []
    if (!h || !h.length) return 0
    var v = i < h.length ? Number(h[i] || 0) : 0
    if (!(v > 0)) return 0
    return Math.min(1, Math.pow(v / 100, 0.55))
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

  // ── state ─────────────────────────────────────────────────────────────────
  readonly property bool broken: svc ? svc.collectorBroken : false
  readonly property bool localOnline: svc ? svc.localOnline : false
  readonly property bool localActive: svc ? svc.localActive : false
  readonly property real localLoad: svc ? svc.localLoad : 0

  // Nothing burning is a real and common state, and a dead-flat widget reads as
  // broken. A slow travelling swell keeps the strip alive without inventing
  // data. A fault must never animate like a calm idle strip — that is how a
  // total outage hides in plain sight.
  readonly property bool idle: !broken && (!ready
    || ((svc ? svc.claudeLatest : 0) <= 0 && (svc ? svc.codexLatest : 0) <= 0))

  // One number for "how hard is this machine working right now", across all
  // three agents. Drives every global effect: under-glow, sparks, frame rate.
  readonly property real energy: root.broken ? 0 : Math.max(
      root.claudeLevel(root.cellCount - 1),
      root.codexLevel(0),
      root.showLocal && root.localOnline ? root.localLevel(0) : 0)

  readonly property color energyColor: root.broken ? urgent
    : root.mix(root.mix(root.claudeHot, root.codexHot, 0.5), root.localHot,
               root.showLocal && root.localActive ? 0.45 : 0.12)

  // ── ember motion ──────────────────────────────────────────────────────────
  // Driven by a 20fps timer rather than a frame-rate NumberAnimation: with up to
  // 80 cells each re-deriving colour from the phase, 60fps would be three times
  // the property churn for flicker nobody can see.
  // Two phases, both wrapped at exactly 2π — and EVERY consumer reads them at a
  // whole-number harmonic (×1, ×2, ×3). That is what makes the wrap invisible:
  // sin(k·(φ+2π)) === sin(k·φ) only when k is an integer. Reading the same phase
  // at ×1.7 or ×0.35 puts a hard discontinuity in the shimmer every time it
  // wraps, which is exactly the visual restart this replaced — the strip
  // appeared to loop every 1.65s because that is how long the wrap took.
  property real emberPhase: 0
  // Idle drift needs a period measured in tens of seconds, not one second, so it
  // gets its own slow phase instead of a fractional harmonic of the fast one.
  property real driftPhase: 0

  Timer {
    // 20fps while something is burning, 5fps when nothing is: the idle swell is
    // a slow drift and does not need frame-accurate updates on battery.
    readonly property bool resting: root.idle && !root.localActive
    interval: resting ? 200 : 50
    running: root.emberFlicker && root.visible && !root.broken
    repeat: true
    onTriggered: {
      // Steps are scaled by interval so neither phase changes speed when the
      // frame rate drops — only the smoothness changes.
      root.emberPhase = (root.emberPhase + (resting ? 0.56 : 0.14)) % (Math.PI * 2)
      root.driftPhase = (root.driftPhase + (resting ? 0.050 : 0.0125)) % (Math.PI * 2)
    }
  }

  property real claudeFlash: 0
  property real codexFlash: 0
  property real localFlash: 0

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
  SequentialAnimation {
    id: localImpact
    NumberAnimation { target: root; property: "localFlash"; to: 1; duration: 80; easing.type: Easing.OutQuad }
    NumberAnimation { target: root; property: "localFlash"; to: 0; duration: 620; easing.type: Easing.OutCubic }
  }

  Connections {
    target: root.svc
    function onClaudePulseChanged() { claudeImpact.restart() }
    function onCodexPulseChanged() { codexImpact.restart() }
    function onLocalPulseChanged() { localImpact.restart() }
  }

  // ── one lane of thermal cells ─────────────────────────────────────────────
  // An inline component so Claude, Codex and Local are literally the same
  // instrument with different inputs — when the visual language changes it
  // changes in one place, which is how the three lanes stay readable as one
  // widget instead of drifting into three dialects.
  component ThermalLane: Item {
    id: lane

    property int count: 12
    property color cold: "#000000"
    property color warm: "#888888"
    property color hot: "#ffffff"
    // function(index) → 0..1. Reading svc state inside it keeps the binding
    // live; QML tracks property reads through the call.
    property var levelAt: null
    // true when index 0 is the OLDEST sample (Claude); false when index 0 is
    // the newest (Codex, Local).
    property bool newestLast: true
    property real flash: 0
    property real phaseSign: 1

    readonly property real slot: width / Math.max(1, count)
    readonly property real cellWidth: Math.max(1, slot - Style.spaceReal(1))

    Repeater {
      model: lane.count
      delegate: Item {
        id: cell
        required property int index

        readonly property real level: lane.levelAt ? lane.levelAt(index) : 0
        // 1 = newest. Everything visual leans on this: recency is what makes
        // the lane read as a comet tail pointing at now.
        readonly property real recency: lane.count <= 1 ? 1
          : (lane.newestLast ? index / (lane.count - 1) : 1 - index / (lane.count - 1))
        readonly property bool live: lane.newestLast ? index === lane.count - 1 : index === 0

        // Hot cells flicker harder — cold coals sit still, a live fire does not.
        // ×2 and ×3 against the same phase: two harmonics that beat against each
        // other into something that never repeats obviously, and both survive
        // the 2π wrap untouched. The per-cell offset is what stops the lane
        // pulsing as one block.
        readonly property real flicker: root.emberFlicker
          ? Math.sin(root.emberPhase * 2 + index * 0.8 * lane.phaseSign) * 0.06 * level
            + Math.sin(root.emberPhase * 3 - index * 0.4 * lane.phaseSign) * 0.035 * level
          : 0
        readonly property real idleSwell: root.idle && !root.broken
          ? 0.06 + Math.sin(root.driftPhase + index * 0.42 * lane.phaseSign) * 0.05 : 0

        readonly property real heatLevel: Math.max(0,
          level + flicker + lane.flash * recency * recency * 0.25 + idleSwell)
        readonly property color tint: root.heat(heatLevel, lane.cold, lane.warm, lane.hot)

        width: lane.cellWidth
        height: lane.height
        x: index * lane.slot
        anchors.verticalCenter: parent.verticalCenter

        // Height is the secondary channel: a 72%→100% swell that gives the lane
        // a profile without stealing the story from colour.
        readonly property real cellHeight:
          lane.height * (0.72 + 0.28 * Math.min(1, cell.heatLevel))

        // Bloom: a wider, softer ghost behind the cell. A cheap fake glow that
        // costs one rectangle instead of a blur pass.
        Rectangle {
          anchors.centerIn: parent
          width: parent.width + Style.spaceReal(3)
          height: cell.cellHeight + Style.spaceReal(3)
          radius: Style.spaceReal(2)
          color: cell.tint
          border.width: 0
          opacity: Math.pow(cell.level, 1.6) * 0.42 * (0.4 + 0.6 * cell.recency)
            + lane.flash * cell.recency * cell.recency * 0.45
          Behavior on height { NumberAnimation { duration: 420; easing.type: Easing.OutCubic } }
        }

        Rectangle {
          anchors.centerIn: parent
          width: parent.width
          height: cell.cellHeight
          radius: Style.spaceReal(1)
          color: cell.tint
          // Age fades toward the outer edge.
          opacity: 0.58 + 0.42 * cell.recency
          // Rectangle.border.width defaults to 1, not 0. Left implicit it
          // outlines every cell and the lane reads as a hollow comb.
          border.width: 0
          Behavior on height { NumberAnimation { duration: 420; easing.type: Easing.OutCubic } }
        }

        // Hot core: a thin white-hot filament that only appears once a cell is
        // genuinely hot, so the top of the scale has somewhere left to go.
        Rectangle {
          anchors.centerIn: parent
          width: Math.max(1, parent.width * 0.42)
          height: cell.cellHeight * 0.42
          radius: width / 2
          color: root.whiteHot
          border.width: 0
          opacity: Math.max(0, cell.heatLevel - 0.55) * 1.5
        }

        // The live cell breathes continuously between samples so the lane never
        // looks frozen at collector granularity. It rides on its own overlay so
        // it can never leak a border onto the fill.
        Rectangle {
          visible: cell.live && !root.idle && !root.broken
          anchors.centerIn: parent
          width: parent.width
          height: cell.cellHeight
          radius: Style.spaceReal(1)
          color: "transparent"
          border.color: root.whiteHot
          border.width: Style.spaceReal(1)
          opacity: 0
          SequentialAnimation on opacity {
            running: cell.live && !root.idle && !root.broken
            loops: Animation.Infinite
            NumberAnimation { to: 0.55; duration: 900; easing.type: Easing.InOutQuad }
            NumberAnimation { to: 0.0; duration: 900; easing.type: Easing.InOutQuad }
          }
        }
      }
    }
  }

  // ── a quota column ────────────────────────────────────────────────────────
  component QuotaGauge: Item {
    id: gauge
    property real percent: 0
    property color accent: "#ffffff"

    Rectangle {
      anchors.fill: parent
      radius: width / 2
      color: Util.alpha(gauge.accent, 0.14)
      border.width: 0
    }
    Rectangle {
      anchors.bottom: parent.bottom
      anchors.horizontalCenter: parent.horizontalCenter
      width: parent.width
      radius: width / 2
      height: Math.max(1, parent.height * Math.min(1, gauge.percent))
      color: root.gaugeColor(gauge.percent)
      border.width: 0
      Behavior on height { NumberAnimation { duration: 900; easing.type: Easing.OutCubic } }
      Behavior on color { ColorAnimation { duration: 400 } }

      // Quota nearly gone gets its own heartbeat — you should not have to read
      // a number to learn you are about to be cut off.
      SequentialAnimation on opacity {
        running: gauge.percent >= 0.9
        loops: Animation.Infinite
        NumberAnimation { to: 0.35; duration: 700; easing.type: Easing.InOutQuad }
        NumberAnimation { to: 1.0; duration: 700; easing.type: Easing.InOutQuad }
      }
    }
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
    // Tooltips are driven per zone from the hover overlay below, which owns the
    // pointer; leaving text here as well would race two tooltips for one slot.
    tooltipText: ""

    // ── under-glow ──────────────────────────────────────────────────────────
    // The whole widget sits on a bed of light that brightens with total energy.
    // It is the only element that spans all three lanes, and it is what makes a
    // busy machine visible from across the room without reading a single cell.
    Rectangle {
      anchors.centerIn: parent
      width: graph.width + Style.spaceReal(10)
      height: Math.max(Style.spaceReal(6), graph.height * 0.5)
      radius: height / 2
      color: root.energyColor
      border.width: 0
      opacity: 0.05 + 0.20 * Math.pow(root.energy, 1.4)
        + 0.12 * Math.max(root.claudeFlash, Math.max(root.codexFlash, root.localFlash))
      Behavior on opacity { NumberAnimation { duration: 300 } }
    }

    Item {
      id: graph
      anchors.centerIn: parent
      width: parent.width - Style.space(6)
      height: Math.max(Style.space(12), Math.round(parent.height * 0.62))

      readonly property int gaugeWidth: root.showGauges ? Style.space(3) : 0
      readonly property int gaugeGap: root.showGauges ? Style.space(3) : 0
      readonly property int dividerWidth: Style.space(3)
      // The local lane gets a quarter of the strip, never a third. It is a
      // supporting instrument: the cloud agents are what costs money.
      readonly property real localWidth: root.showLocal ? Math.round(width * 0.25) : 0
      readonly property int ruleWidth: root.showLocal ? Style.space(4) : 0
      readonly property real cloudWidth:
        width - localWidth - ruleWidth - 2 * (gaugeWidth + gaugeGap) - dividerWidth
      readonly property real sideWidth: Math.max(1, cloudWidth / 2)

      // Zone spans, used for both the tinted plates and hit-testing. Derived
      // from the same numbers that lay the lanes out, so a plate can never
      // drift out from under the instrument it is naming.
      readonly property real claudeZoneWidth:
        gaugeWidth + gaugeGap + sideWidth + dividerWidth / 2
      readonly property real codexZoneWidth:
        dividerWidth / 2 + sideWidth + gaugeGap + gaugeWidth + ruleWidth / 2
      readonly property real localZoneStart: claudeZoneWidth + codexZoneWidth
      readonly property real localZoneWidth: Math.max(0, width - localZoneStart)

      function zoneAt(x) {
        if (x < claudeZoneWidth) return root.zoneClaude
        if (!root.showLocal || x < localZoneStart) return root.zoneCodex
        return root.zoneLocal
      }

      // Tinted plates: the cheapest possible answer to "where does Claude end
      // and Codex begin". Always faintly on, so the three sections are legible
      // at a glance; brighter under the pointer, so hovering confirms which one
      // the tooltip is talking about.
      Repeater {
        model: [
          { zone: root.zoneClaude, from: 0, span: graph.claudeZoneWidth, on: true },
          { zone: root.zoneCodex, from: graph.claudeZoneWidth, span: graph.codexZoneWidth, on: true },
          { zone: root.zoneLocal, from: graph.localZoneStart, span: graph.localZoneWidth, on: root.showLocal }
        ]
        delegate: Item {
          required property var modelData
          visible: modelData.on && modelData.span > 0
          x: modelData.from
          width: modelData.span
          height: graph.height + Style.spaceReal(4)
          anchors.verticalCenter: parent.verticalCenter

          readonly property bool hovered: root.hoverZone === modelData.zone
          readonly property color accent: root.zoneAccent(modelData.zone)

          Rectangle {
            anchors.fill: parent
            radius: Style.spaceReal(3)
            color: parent.accent
            border.width: 0
            opacity: parent.hovered ? 0.16 : 0.055
            Behavior on opacity { NumberAnimation { duration: 160 } }
          }

          // Identity baseline. Three different colours sitting on the same
          // floor is what turns one strip into three labelled sections.
          Rectangle {
            anchors.bottom: parent.bottom
            anchors.horizontalCenter: parent.horizontalCenter
            width: parent.width - Style.spaceReal(3)
            height: Style.spaceReal(1.5)
            radius: height / 2
            color: parent.accent
            border.width: 0
            opacity: parent.hovered ? 1.0 : 0.45
            Behavior on opacity { NumberAnimation { duration: 160 } }
          }
        }
      }

      // Claude weekly fuel gauge — far left, outermost.
      QuotaGauge {
        id: claudeGauge
        visible: root.showGauges
        width: graph.gaugeWidth
        height: parent.height
        anchors.left: parent.left
        anchors.verticalCenter: parent.verticalCenter
        percent: Math.min(1, root.svc ? root.svc.claudeWeekly : 0)
        accent: root.claudeHot
      }

      ThermalLane {
        id: claudeLane
        width: graph.sideWidth
        height: parent.height
        anchors.left: root.showGauges ? claudeGauge.right : parent.left
        anchors.leftMargin: graph.gaugeGap
        anchors.verticalCenter: parent.verticalCenter
        count: root.cellCount
        cold: root.claudeCold; warm: root.claudeWarm; hot: root.claudeHot
        newestLast: true
        flash: root.claudeFlash
        phaseSign: 1
        levelAt: function(i) { return root.claudeLevel(i) }
      }

      // ── the now line ────────────────────────────────────────────────────────
      Item {
        id: divider
        width: graph.dividerWidth
        height: parent.height
        anchors.left: claudeLane.right
        anchors.verticalCenter: parent.verticalCenter

        Rectangle {
          anchors.centerIn: parent
          width: Style.spaceReal(1.5)
          height: parent.height + Style.spaceReal(3)
          radius: width / 2
          color: root.bar ? root.bar.barForeground : Color.foreground
          border.width: 0
          opacity: 0.38 + 0.55 * Math.max(root.claudeFlash, root.codexFlash)
        }

        // Filament caps: two bright points that mark the exact instant of now.
        Repeater {
          model: 2
          delegate: Rectangle {
            required property int index
            width: Style.spaceReal(2.5)
            height: width
            radius: width / 2
            anchors.horizontalCenter: parent.horizontalCenter
            y: index === 0 ? -Style.spaceReal(2) : parent.height - height + Style.spaceReal(2)
            color: root.energyColor
            border.width: 0
            opacity: 0.35 + 0.5 * root.energy
            scale: 1 + 0.6 * Math.max(root.claudeFlash, root.codexFlash)
          }
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

      ThermalLane {
        id: codexLane
        width: graph.sideWidth
        height: parent.height
        anchors.left: divider.right
        anchors.verticalCenter: parent.verticalCenter
        count: root.cellCount
        cold: root.codexCold; warm: root.codexWarm; hot: root.codexHot
        newestLast: false
        flash: root.codexFlash
        phaseSign: -1
        levelAt: function(i) { return root.codexLevel(i) }
      }

      // Shockwaves: a bright band that rides outward from the now line along
      // each lane when that agent lands new burn. This is the movement you see
      // from the corner of your eye — it means tokens just left the building.
      Rectangle {
        id: claudeWave
        visible: root.claudeFlash > 0.01
        width: Style.spaceReal(3)
        height: graph.height
        radius: width / 2
        color: root.claudeHot
        border.width: 0
        anchors.verticalCenter: parent.verticalCenter
        x: claudeLane.x + claudeLane.width * (1 - root.claudeFlash) - width / 2
        opacity: root.claudeFlash * 0.55
      }
      Rectangle {
        id: codexWave
        visible: root.codexFlash > 0.01
        width: Style.spaceReal(3)
        height: graph.height
        radius: width / 2
        color: root.codexHot
        border.width: 0
        anchors.verticalCenter: parent.verticalCenter
        x: codexLane.x + codexLane.width * root.codexFlash - width / 2
        opacity: root.codexFlash * 0.55
      }

      // Codex weekly fuel gauge — the right bookend of the cloud instrument.
      QuotaGauge {
        id: codexGauge
        visible: root.showGauges
        width: graph.gaugeWidth
        height: parent.height
        anchors.left: codexLane.right
        anchors.leftMargin: graph.gaugeGap
        anchors.verticalCenter: parent.verticalCenter
        percent: Math.min(1, root.svc ? root.svc.codexWeekly : 0)
        accent: root.codexHot
      }

      // ── the hard rule ───────────────────────────────────────────────────────
      // Everything left of this line is metered cloud spend in tokens per
      // bucket. Everything right of it is free local compute in percent per
      // second. Different money, different clock, different scale — so they get
      // a wall between them rather than a gap you might read as a pause.
      Item {
        id: localRule
        visible: root.showLocal
        width: graph.ruleWidth
        height: parent.height
        anchors.left: root.showGauges ? codexGauge.right : codexLane.right
        anchors.verticalCenter: parent.verticalCenter

        Rectangle {
          anchors.centerIn: parent
          width: 1
          height: parent.height + Style.spaceReal(4)
          color: root.bar ? root.bar.barForeground : Color.foreground
          border.width: 0
          opacity: 0.22
        }
      }

      // ── local intelligence lane ─────────────────────────────────────────────
      Item {
        id: localZone
        visible: root.showLocal
        width: graph.localWidth
        height: parent.height
        anchors.left: localRule.right
        anchors.verticalCenter: parent.verticalCenter

        readonly property color state: !root.localOnline ? root.urgent
          : root.localActive ? root.localHot : "#35f28b"
        readonly property real core: Math.max(Style.spaceReal(4),
          Math.min(width * 0.34, parent.height * 0.62))

        // Reactor core — the one glyph in the widget, and the only thing that
        // can say "offline" out loud. Red ring means Ollama is not answering;
        // green means it is warm and waiting; violet means it is thinking.
        Item {
          id: reactor
          width: localZone.core
          height: width
          anchors.left: parent.left
          anchors.verticalCenter: parent.verticalCenter

          // Halo — pushed out by inference load, so the core visibly inflates
          // when a local model is chewing.
          Rectangle {
            anchors.centerIn: parent
            width: parent.width * (1.05 + 0.45 * Math.min(1, root.localLoad / 100))
            height: width
            radius: width / 2
            color: localZone.state
            border.width: 0
            opacity: root.localActive ? 0.30 : 0.14
            Behavior on width { NumberAnimation { duration: 320; easing.type: Easing.OutCubic } }
            Behavior on opacity { NumberAnimation { duration: 240 } }
          }

          Rectangle {
            id: coreDot
            anchors.centerIn: parent
            width: parent.width * 0.66
            height: width
            radius: width / 2
            color: localZone.state
            border.width: 0
            Behavior on color { ColorAnimation { duration: 260 } }

            SequentialAnimation on scale {
              running: root.localActive && root.visible
              loops: Animation.Infinite
              NumberAnimation { to: 1.16; duration: 480; easing.type: Easing.InOutSine }
              NumberAnimation { to: 0.94; duration: 480; easing.type: Easing.InOutSine }
            }
            // Offline is a fault, and faults strobe rather than breathe.
            SequentialAnimation on opacity {
              running: !root.localOnline && root.visible
              loops: Animation.Infinite
              NumberAnimation { to: 0.25; duration: 620; easing.type: Easing.InOutQuad }
              NumberAnimation { to: 1.0; duration: 620; easing.type: Easing.InOutQuad }
            }
          }

          // Hollow centre, so the core reads as a reactor and not a dot.
          Rectangle {
            anchors.centerIn: parent
            width: parent.width * 0.28
            height: width
            radius: width / 2
            color: root.bar ? root.bar.background : Color.background
            border.width: 0
            opacity: 0.9
          }

          // Ignition ring on a load surge.
          Rectangle {
            anchors.centerIn: parent
            width: parent.width * (0.7 + root.localFlash * 1.5)
            height: width
            radius: width / 2
            color: "transparent"
            border.width: Style.spaceReal(1)
            border.color: root.localHot
            opacity: root.localFlash * 0.9
          }
        }

        ThermalLane {
          id: localLane
          anchors.left: reactor.right
          anchors.leftMargin: Style.spaceReal(2)
          anchors.right: parent.right
          height: parent.height
          anchors.verticalCenter: parent.verticalCenter
          count: root.localCells
          cold: root.localCold; warm: root.localWarm; hot: root.localHot
          newestLast: false
          flash: root.localFlash
          phaseSign: -1
          // Offline drops the lane to nothing rather than freezing the last
          // reading, which would be a lie that looks like data.
          levelAt: function(i) { return root.localOnline ? root.localLevel(i) : 0 }
        }
      }

      // ── sparks ──────────────────────────────────────────────────────────────
      // Embers lifting off the strip. Count is fixed; visibility, speed and
      // brightness all ride on total energy, so an idle machine emits nothing
      // and a hammered one throws a column of them. GPU-side animations, so
      // this costs no property churn on the QML side.
      Repeater {
        model: root.sparks ? 7 : 0
        delegate: Rectangle {
          id: spark
          required property int index

          readonly property real seed: (index * 0.37) % 1
          width: Style.spaceReal(1)
          height: width
          radius: width / 2
          color: index % 3 === 0 ? root.whiteHot : root.energyColor
          border.width: 0
          x: graph.width * (0.10 + 0.80 * seed)
          visible: root.energy > 0.12 && !root.broken
          opacity: 0

          SequentialAnimation {
            running: spark.visible && root.visible
            loops: Animation.Infinite
            PauseAnimation { duration: Math.round(120 + spark.seed * 1600) }
            ParallelAnimation {
              NumberAnimation {
                target: spark; property: "y"
                from: graph.height * 0.62; to: -graph.height * 0.30
                // Each spark rises at its own rate. Identical durations made all
                // seven re-sync into one visible pulse, which read as a loop.
                duration: Math.round((1300 + spark.seed * 1400) - 600 * root.energy)
                easing.type: Easing.OutQuad
              }
              SequentialAnimation {
                NumberAnimation {
                  target: spark; property: "opacity"; to: 0.30 + 0.55 * root.energy
                  duration: 160
                }
                NumberAnimation { target: spark; property: "opacity"; to: 0; duration: 900 }
              }
            }
          }
        }
      }
    }

    // ── zone hover ──────────────────────────────────────────────────────────
    // Buttons only ever carry one tooltip, and this widget is three
    // instruments — so the pointer is read here and the bar's tooltip is driven
    // by hand with whatever lane the cursor is actually over. Clicks are not
    // accepted, so they fall straight through to the button underneath.
    MouseArea {
      id: zoneHover
      anchors.fill: parent
      acceptedButtons: Qt.NoButton
      hoverEnabled: true
      onPositionChanged: root.updateZone(mouseX)
      onEntered: root.updateZone(mouseX)
      onExited: {
        root.hoverZone = root.zoneNone
        if (root.bar) root.bar.hideTooltip(root)
      }
    }

    onPressed: function(code) {
      // The button hides its own tooltip on press, but ours is registered
      // against the widget, so it has to be dismissed by hand or it hangs over
      // the panel that just opened. Clearing the zone re-arms the next hover.
      if (root.bar) root.bar.hideTooltip(root)
      root.hoverZone = root.zoneNone
      if (code === Qt.MiddleButton) { if (root.svc) { root.svc.collect(); root.svc.pollLocal() } }
      else root.toggle()
    }
  }

  readonly property bool opened: panel.opened
  function open() { panel.controller.show(); if (svc) { svc.collect(); svc.pollLocal() } }
  function close() { panel.controller.hide() }
  function toggle() { opened ? close() : open() }
  function closeForPopoutSwitch() { close() }
  readonly property bool popoutSwitchClosing: false

  BurnPanel {
    id: panel
    widget: root
  }
}
