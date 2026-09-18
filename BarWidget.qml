import QtQuick
import Quickshell
import Quickshell.Io
import qs.Commons
import qs.Ui

// Burn Bar — one live thermal instrument for every model this machine runs.
//
//   CLAUDE ◄── time ──┤ now ├── time ──► CODEX  │  GROK ──►  ║  GPU ──► seconds
//
// Lanes appear only for agents this machine actually uses. Claude burns on
// the left and Codex on the right, both with their newest bucket against the
// shared centre line, so the divider is always "now". Grok (Grok Build / CLI
// under ~/.grok) rides after Codex when it is present, or takes a side of
// the pair when Codex is not. Local intelligence — Ollama on a compute GPU —
// stays bolted on the right behind a hard rule, and is omitted entirely when
// no NVIDIA / AMD / Jetson GPU is detected. Intel iGPU does not count.
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

  function boundedInt(name, fallback, low, high) {
    var n = parseInt(String(setting(name, fallback)), 10)
    if (!isFinite(n)) n = fallback
    return Math.max(low, Math.min(high, n))
  }
  // One clamp — the service's — so the strip can never draw a different
  // number of cells than the collector made buckets (bars: 0 used to read as
  // 12 here and 6 there). The fallback only matters before the service binds.
  // `bars` is the FLOOR for granularity, not the whole story. A strip
  // stretched across an ultrawide has room for far more, finer cells, and a
  // lane of twelve 33px blocks reads as a bar chart rather than a heat map.
  readonly property int baseBars: boundedInt("bars", 12, 6, 240)
  // `bars` is what the strip asks for, not what it insists on. On a crowded bar
  // it sheds cells down to this before it asks any neighbour for room: a
  // shorter window is a smaller loss than a lane that will not fit. The strip
  // is the glance; the cockpit still holds the whole window either way.
  readonly property int minBars: 6
  readonly property int cellCount: svc ? svc.bucketCount : baseBars
  // One cell plus its gap. Below this the lane smears; above it, it blocks up.
  readonly property real cellPitch: Math.max(2, Style.spaceReal(6))
  // Quantised to 4 so a pixel of drift does not re-run the collector. Reads
  // lane width, never cellCount, so this cannot feed back into itself.
  readonly property int adaptiveCells: {
    var lane = graph ? graph.sideWidth : 0
    if (!isFinite(lane) || lane <= 0) return baseBars
    var want = Math.round(Math.round(lane / cellPitch) / 4) * 4
    return Math.max(minBars, Math.min(240, want))
  }
  onAdaptiveCellsChanged: pushBuckets()
  function pushBuckets() {
    if (svc && svc.requestedBuckets !== undefined && svc.requestedBuckets !== adaptiveCells)
      svc.requestedBuckets = adaptiveCells
  }
  readonly property int localCells: svc ? svc.localCells : boundedInt("localCells", 9, 4, 20)
  // Presence comes from the collector. Until the first snapshot lands the
  // strip stays empty rather than inventing Claude/Codex/Grok lanes that
  // this machine may not use.
  readonly property bool showClaude: svc ? svc.claudePresent : false
  readonly property bool showCodex: svc ? svc.codexPresent : false
  readonly property bool showGrok: svc ? svc.grokPresent : false
  readonly property int cloudAgents: (showClaude ? 1 : 0) + (showCodex ? 1 : 0) + (showGrok ? 1 : 0) + (showKimi ? 1 : 0)
  readonly property bool grokExtra: showGrok && showClaude && showCodex
  readonly property bool grokAsRight: showGrok && showClaude && !showCodex
  readonly property bool grokAsLeft: showGrok && !showClaude && showCodex
  // Kimi Code has no transcript store of its own: it rides in Claude's, and the
  // model id is the only thing that separates them. The lane stays hidden until
  // a Kimi-model turn actually appears, so a machine that has never run it sees
  // no change at all. It sits beside Grok as a second narrow band.
  readonly property bool showKimi: svc ? svc.kimiPresent : false
  readonly property bool kimiExtra: showKimi && showClaude && showCodex
  // The narrowest strip that still gives every cell a whole pixel and a gap.
  // A configured width below it is raised rather than honoured: overlapping
  // cells are a heat map of nothing.
  readonly property int minWidthForCells: {
    var n = Math.max(1, cloudAgents)
    // minBars, not cellCount: cellCount is derived from the width this number
    // helps decide, and reading it here would close the loop. It is minBars
    // rather than baseBars because this is the floor — the narrowest the strip
    // can be drawn, not the width it would like. Using baseBars held 136px on a
    // crowded bar and refused to yield the last 26 of them, which is the whole
    // complaint: it should shed cells before it hoards width.
    var cloudNeed = (2 * n * minBars + 3 + (showGauges ? 6 * n : 0) + (showLocal ? 4 : 0)) / (showLocal ? 0.75 : 1)
    var localNeed = showLocal ? (2 * localCells + 6) * 4 : 0
    return Math.max(110, Math.ceil(Math.max(cloudNeed, localNeed)) + 6)
  }
  // What the strip would LIKE: `bars` cells at a readable pitch plus the
  // furniture. minWidthForCells is what it can survive on. The gap between the
  // two is the space it is willing to hand back when the bar is busy.
  readonly property int comfortWidth: {
    var n = Math.max(1, cloudAgents)
    var cloudNeed = (2 * n * baseBars + 3 + (showGauges ? 6 * n : 0) + (showLocal ? 4 : 0)) / (showLocal ? 0.75 : 1)
    var localNeed = showLocal ? (2 * localCells + 6) * 4 : 0
    return Math.max(minWidthForCells, Math.ceil(Math.max(cloudNeed, localNeed)) + 6)
  }
  readonly property int configuredWidth: Math.max(minWidthForCells, boundedInt("width", 158, 110, 400))
  readonly property bool showGauges: setting("showGauges", true) !== false
  // Local settings stay in the plugin schema so a GPU box can be pointed at,
  // but the lane itself only appears when a compute GPU was actually found.
  readonly property bool showLocal: setting("showLocal", true) !== false && (svc ? svc.hasComputeGpu : false)
  readonly property bool emberFlicker: setting("emberFlicker", true) !== false
  readonly property bool sparks: setting("sparks", true) !== false

  // ── elastic width ─────────────────────────────────────────────────────────
  // The bar's sections do not negotiate: each is a Row pinned to its own edge
  // (or, for the centre, hung off the anchor module) and nothing hands out the
  // room left between them. So the strip claims it by hand, the way beatdeck
  // does on the left: measure where the neighbouring section begins, subtract
  // what the siblings in our own row still need, and take the rest. `width` is
  // the floor — the narrowest the strip will go, and its fixed size with the
  // fill turned off — and `maxWidth` the ceiling.
  //
  // Loop-safe because no input depends on our own width. Which edge of ours
  // is fixed depends on where the widget sits:
  //   · left row, or centre row after the anchor    → our LEFT edge is pinned
  //     by the siblings before us; we grow rightward to the next section.
  //   · right row, or centre row before the anchor  → our RIGHT edge is pinned
  //     (the row hangs from the right); we grow leftward.
  //   · centre row with no anchor                   → the whole row is centred;
  //     it can grow until either end meets a neighbouring section.
  //   · we are the anchor                           → we sit on the centre line
  //     and grow both ways, bounded by the tighter side.
  // Siblings in our own row are measured by implicitWidth, never by position:
  // their x moves when we grow, the space they need does not.
  readonly property bool stretch: setting("stretch", true) !== false
  readonly property int maxWidth: Math.max(configuredWidth, boundedInt("maxWidth", 2400, 110, 4000))
  readonly property int stretchGap: boundedInt("stretchGap", 14, 0, 200)

  // Device pixels. Seeded at the preferred width; measureStretch then
  // replaces it with a fair share of the hole to the centre section.
  readonly property real preferredWidth: Style.spaceReal(configuredWidth)
  property real stretchedWidth: preferredWidth
  readonly property real stripWidth: stretch && !vertical
    ? Math.max(0, stretchedWidth)
    : preferredWidth

  implicitWidth: vertical ? barSize : stripWidth
  implicitHeight: vertical ? Style.spaceReal(configuredWidth) : barSize
  // Bloom/glow is drawn larger than the slot; clip so it cannot paint
  // through the temperature and clock in the next section.
  clip: true

  function sameModule(a, b) {
    var x = String(a || ""), y = String(b || "")
    if (bar && typeof bar.canonicalWidgetId === "function") {
      x = String(bar.canonicalWidgetId(x) || x)
      y = String(bar.canonicalWidgetId(y) || y)
    }
    return x !== "" && x === y
  }

  function slotStretches(item) {
    // Now Playing (beatdeck) exposes `stretch` and `stretchedWidth`. Either
    // means it is filling the same hole we are; we split with it.
    if (!item || item === root) return false
    if (item.vertical === true) return false
    if (item.stretch === false) return false
    if (item.stretch === true) return true
    return typeof item.stretchedWidth === "number"
  }

  // What a partner will actually take. Beatdeck publishes `stretchMaxWidth`
  // and drops it to its minimum when nothing is playing; treating that as a
  // fair half would leave the gap it gave up sitting empty.
  function slotCap(item) {
    var n = Number(item && item.stretchMaxWidth)
    return isFinite(n) && n > 0 ? Style.spaceReal(n) : Infinity
  }

  function slotMinWidth(item) {
    var n = Number(item && item.stretchMinWidth)
    if (isFinite(n) && n > 0) return n
    n = Number(item && item.configuredWidth)
    if (isFinite(n) && n > 0) return n
    return 96
  }

  function measureStretch() {
    if (!stretch || vertical || !bar || !Array.isArray(bar.moduleSlots)) return

    var maximum = Style.spaceReal(maxWidth)
    var gap = Style.spaceReal(stretchGap)
    var ourMin = Math.max(80, minWidthForCells)
    var origin
    try {
      origin = mapToItem(null, 0, 0)
    } catch (e) {
      return
    }
    if (!origin) return

    // Centre bound is screen x, not implicitWidth: weather has painted at
    // 68px with an implicitWidth of 0. Hidden indicators sit on the same x.
    var centreLeft = -1
    var trailing = 0
    var partnerX = -1
    var partnerMin = 0
    var partnerCap = Infinity
    var nPartners = 0

    for (var i = 0; i < bar.moduleSlots.length; i++) {
      var slot = bar.moduleSlots[i]
      if (!slot || !slot.activeItem) continue
      if (slot.activeItem === root) continue

      var point
      try {
        point = slot.mapToItem(null, 0, 0)
      } catch (e2) {
        continue
      }
      if (!point) continue

      if (slot.region === "center") {
        if (point.x + 1 < origin.x) continue
        if (centreLeft < 0 || point.x < centreLeft) centreLeft = point.x
      } else if (slot.region === "left") {
        if (point.x > origin.x && slot.activeItem.visible)
          trailing += Math.max(0, Number(slot.implicitWidth) || 0)
        else if (point.x < origin.x) {
          var name = String(slot.moduleName || "")
          var peer = slotStretches(slot.activeItem)
            || name.indexOf("beatdeck") >= 0
            || name.indexOf("nowplaying") >= 0
            || name.indexOf("now-playing") >= 0
          if (!peer) continue
          // Immediate predecessor that also fills: share from ITS left
          // edge (stable) not from our x (which it controls).
          if (point.x >= partnerX) {
            nPartners = 1
            partnerX = point.x
            partnerMin = slotMinWidth(slot.activeItem)
            partnerCap = slotCap(slot.activeItem)
          }
        }
      }
    }

    var boundary = centreLeft
    if (boundary < 0) {
      var barPoint
      try {
        barPoint = bar.mapToItem(null, 0, 0)
      } catch (e3) {
        return
      }
      if (!barPoint) return
      boundary = barPoint.x + bar.width
    }

    var holeStart = partnerX >= 0 ? partnerX : origin.x
    var hole = boundary - holeStart - trailing - gap
    var next
    if (partnerX >= 0 && nPartners > 0) {
      // Split the hole with the preceding stretcher (Now Playing).
      // Beatdeck sizes itself as (hole - our implicitWidth), so reporting
      // the fair share here is what makes the two converge instead of
      // one eating the other. Independent of our current x/width.
      var n = nPartners + 1
      var extra = hole - ourMin - partnerMin
      if (extra < 0)
        next = hole * ourMin / Math.max(1, ourMin + partnerMin)
      else if (hole < Style.spaceReal(comfortWidth) + partnerMin) {
        // Crowded: the gap cannot seat this strip comfortably AND the partner,
        // so stop bidding for it. Drop to the floor and let the neighbour have
        // the rest. Splitting the leftover down the middle is only fair when
        // there is enough of it to make both of us usable; below that it is
        // just hoarding, and a shorter window costs less than a cramped bar.
        next = ourMin
      } else {
        next = ourMin + extra / n
        // The partner has capped itself under its share — it is yielding.
        // Take the room it will not use rather than leaving it blank.
        if (partnerCap < Infinity && partnerCap < hole - next)
          next = hole - partnerCap
      }
      next = Math.min(next, hole - partnerMin)
    } else {
      next = hole
    }
    next = Math.round(Math.max(0, Math.min(maximum, next)))
    // First-frame mapToItem can report the bar origin (x≈0, bound≈0) before
    // slots exist; applying that would collapse the strip to 0px.
    if (boundary < origin.x + 24 && partnerX < 0) return
    if (next < 40 && stretchedWidth > 80) return
    if (Math.abs(next - stretchedWidth) >= 1) stretchedWidth = next
  }

  onStretchChanged: measureStretch()
  onConfiguredWidthChanged: measureStretch()
  onMaxWidthChanged: measureStretch()
  onStretchGapChanged: measureStretch()
  onXChanged: measureStretch()
  onBarChanged: measureStretch()
  Component.onCompleted: { measureStretch(); pushBuckets() }

  Connections {
    target: root.bar
    ignoreUnknownSignals: true
    // A plugin added to or removed from any section reassigns moduleSlots.
    function onModuleSlotsChanged() { settleTimer.restart() }
    function onWidthChanged() { settleTimer.restart() }
    function onBarConfigChanged() { settleTimer.restart() }
  }

  // Slots register before they have been laid out, so measure once the frame
  // has settled rather than on the register itself.
  Timer {
    id: settleTimer
    interval: 60
    repeat: false
    onTriggered: root.measureStretch()
  }

  // Safety net for the geometry changes QML gives no signal for: a
  // neighbour's label growing, the tray gaining an icon, a font or scale
  // change mid-session. Cheap next to the ember animation already running.
  Timer {
    interval: 500
    running: root.stretch && !root.vertical && root.visible
    repeat: true
    onTriggered: root.measureStretch()
  }

  // ── zones ─────────────────────────────────────────────────────────────────
  // The widget is three instruments in one slot, so each gets a tinted plate
  // and a coloured baseline in its own identity hue. Hovering a zone names it
  // and reports only that agent — a single blended tooltip made you do the
  // arithmetic of working out which number belonged to which lane.
  readonly property int zoneNone: -1
  readonly property int zoneClaude: 0
  readonly property int zoneCodex: 1
  readonly property int zoneGrok: 2
  readonly property int zoneLocal: 3
  readonly property int zoneKimi: 4

  property int hoverZone: zoneNone
  // The bar only offers a tooltip to a target that reports itself hovered, and
  // our own overlay takes the hover away from WidgetButton's MouseArea — so
  // this widget becomes the tooltip target in its place.
  readonly property bool tooltipHovered: zoneHover.containsMouse && visible

  function zoneAccent(zone) {
    if (zone === zoneCodex) return codexHot
    if (zone === zoneKimi) return kimiHot
    if (zone === zoneGrok) return grokHot
    if (zone === zoneLocal) return showLocal && !localOnline ? urgent : localHot
    return claudeHot
  }

  // A weekly figure the service could not vouch for reads as unknown, with
  // the age of the record behind it, never as a confident 0%.
  function quotaText(percent, updatedAt) {
    if (percent < 0) {
      var t = Number(updatedAt) || 0
      return t > 0 ? "unknown  ·  measured " + Qt.formatTime(new Date(t), "h:mm AP") : "unknown"
    }
    return Math.round(percent * 100) + "%"
  }

  // "6h", "1h40m", "30m" — never a window rounded to the nearest hour.
  function windowLabel(minutes) {
    var m = Math.round(Number(minutes) || 0)
    var h = Math.floor(m / 60), r = m % 60
    return h > 0 ? (r > 0 ? h + "h" + r + "m" : h + "h") : m + "m"
  }

  function zoneTooltip(zone) {
    if (!svc) return "Burn Bar — starting up"
    if (broken && zone !== zoneLocal)
      return "CLOUD FAULT — " + (svc.lastError || "collector failed")
    var span = windowLabel(svc.windowMinutes || 360)
    if (zone === zoneClaude)
      return "CLAUDE  ·  " + compact(svc.claudeTotal) + " tokens / last " + span
        + "\nnow " + compact(svc.claudeLatest) + " this bucket  ·  " + svc.claudeSessions + " sessions"
        + "\nweekly quota " + quotaText(svc.claudeWeekly, svc.claudeLimitsMeasuredAt)
    if (zone === zoneCodex)
      return "CODEX  ·  " + compact(svc.codexTotal) + " tokens / last " + span
        + "\nnow " + compact(svc.codexLatest) + " this bucket  ·  " + svc.codexSessions + " sessions"
        + "\nweekly quota " + quotaText(svc.codexWeekly, svc.codexLimitsMeasuredAt)
    if (zone === zoneKimi)
      return "KIMI  ·  " + compact(svc.kimiTotal) + " tokens / last " + span
        + "\nnow " + compact(svc.kimiLatest) + " this bucket  ·  " + svc.kimiSessions + " sessions"
        + "\n" + (svc.kimiPlanTier !== "" ? svc.kimiPlanTier + " plan" : "plan unknown")
        + "  ·  Kimi publishes no quota"
    if (zone === zoneGrok)
      return "GROK  ·  " + compact(svc.grokTotal) + " tokens / last " + span
        + "\nnow " + compact(svc.grokLatest) + " this bucket  ·  " + svc.grokSessions + " sessions"
        + "\nweekly quota " + quotaText(svc.grokWeekly, svc.grokLimitsMeasuredAt)
        + (svc.grokLimitsStatus !== "" ? "\n" + svc.grokLimitsStatus : "")
    if (zone === zoneLocal)
      return svc.localHost.toUpperCase() + "  ·  " + (!svc.localOnline
          ? "Ollama offline" + (svc.localError !== "" ? "\n" + svc.localError : "")
          : (svc.localActive ? "inferencing " : "idle ") + Math.round(svc.localLoad) + "%"
            + "  ·  " + String(svc.localBackend).toUpperCase()
            + "\n" + (svc.localModel !== "" ? svc.localModel : "no model resident")
            + "\n" + svc.localModelCount + " model(s) warm")
        + (svc.localTokensAvailable
            ? "\n" + compact(svc.localTokensTotal) + " tokens / last " + span
              + "  ·  " + Math.round(svc.offloadShare * 100) + "% offloaded from frontier"
            : "")
    return ""
  }

  // Bound, not computed once at zone entry: a tooltip left open while the
  // quota rolls over, a fresh sample lands, or the collector fails has to
  // change under the pointer. showTooltip re-checks tooltipHovered on this
  // widget, so a stale request from a pointer that has already left resolves
  // to nothing.
  readonly property string hoverText: hoverZone === zoneNone ? "" : zoneTooltip(hoverZone)
  onHoverTextChanged: if (hoverZone !== zoneNone && bar) bar.showTooltip(root, hoverText)

  function updateZone(x) {
    var zone = graph.zoneAt(x - graph.x)
    if (zone === hoverZone) return
    hoverZone = zone
  }

  function setting(name, fallback) {
    var value = settings ? settings[name] : undefined
    return value === undefined || value === null ? fallback : value
  }

  function syncServiceSettings() { if (svc) svc.settings = settings || ({}) }
  onSvcChanged: syncServiceSettings()
  onSettingsChanged: syncServiceSettings()

  // ── theme palette ─────────────────────────────────────────────────────────
  // The shell's Color singleton keeps only five roles (foreground, background,
  // accent, urgent, muted) and discards the rest of the theme, so read
  // colors.toml directly for the named hues the heat ramps need. Five of the
  // installed themes ship no colors.toml at all; those fall through to the
  // built-in ramp below, which is why every stop keeps a literal base.
  readonly property bool themeColors: setting("themeColors", true) !== false
  readonly property string themePalettePath:
    (Quickshell.env("XDG_STATE_HOME") || Quickshell.env("HOME") + "/.local/state")
      + "/omarchy/current/theme/colors.toml"
  property var themePalette: ({})

  function parsePalette(raw) {
    var out = {}
    var lines = String(raw || "").split("\n")
    for (var i = 0; i < lines.length; i++) {
      var m = lines[i].match(/^\s*([A-Za-z0-9_]+)\s*=\s*["']?(#[0-9A-Fa-f]{6})/)
      if (m) out[m[1]] = m[2]
    }
    return out
  }

  // 0..1, or -1 for a grey with no hue to borrow.
  function hexHue(hex) {
    var r = parseInt(hex.substr(1, 2), 16) / 255
    var g = parseInt(hex.substr(3, 2), 16) / 255
    var b = parseInt(hex.substr(5, 2), 16) / 255
    var mx = Math.max(r, g, b), mn = Math.min(r, g, b), d = mx - mn
    if (d === 0) return -1
    var h
    if (mx === r) h = ((g - b) / d) % 6
    else if (mx === g) h = (b - r) / d + 2
    else h = (r - g) / d + 4
    h /= 6
    return h < 0 ? h + 1 : h
  }

  // Hue from the theme, saturation and lightness from our own ramp. Taking the
  // theme colour whole turns the strip pastel on the muted themes and it stops
  // reading as heat; taking only the hue re-tints with the desktop while the
  // embers keep their glow.
  function themed(base, key, fallbackKey) {
    if (!themeColors) return base
    var hex = themePalette[key] || (fallbackKey ? themePalette[fallbackKey] : "")
    if (!hex) return base
    var h = hexHue(hex)
    if (h < 0) return base
    return Qt.hsla(h, base.hslSaturation, base.hslLightness, 1)
  }

  FileView {
    path: root.themePalettePath
    watchChanges: true
    printErrors: false
    onFileChanged: reload()
    onLoaded: root.themePalette = root.parsePalette(text())
    onLoadFailed: root.themePalette = ({})
  }

  // ── heat ramps ────────────────────────────────────────────────────────────
  // Cloud + local converge on the same amber/white at the top end, because
  // hot is hot. Identity lives in the cold and mid stops: Claude orange,
  // Codex teal, Grok rose, local violet — separable at 3px in every theme.
  // Each stop keeps its literal as the base the theme hue is applied to.
  readonly property color baseClaudeCold: "#4A2113"
  readonly property color baseClaudeWarm: "#C4542A"
  readonly property color baseClaudeHot:  "#FF8A4B"
  readonly property color claudeCold: themed(baseClaudeCold, "orange", "yellow")
  readonly property color claudeWarm: themed(baseClaudeWarm, "orange", "yellow")
  readonly property color claudeHot:  themed(baseClaudeHot,  "orange", "yellow")

  readonly property color baseCodexCold: "#0C3E33"
  readonly property color baseCodexWarm: "#12977A"
  readonly property color baseCodexHot:  "#2BE8B0"
  readonly property color codexCold: themed(baseCodexCold, "green", "cyan")
  readonly property color codexWarm: themed(baseCodexWarm, "green", "cyan")
  readonly property color codexHot:  themed(baseCodexHot,  "green", "cyan")

  readonly property color baseGrokCold: "#3F1428"
  readonly property color baseGrokWarm: "#C43B7A"
  readonly property color baseGrokHot:  "#FF6BB4"
  readonly property color grokCold: themed(baseGrokCold, "magenta", "red")
  readonly property color grokWarm: themed(baseGrokWarm, "magenta", "red")
  readonly property color grokHot:  themed(baseGrokHot,  "magenta", "red")

  readonly property color baseKimiCold: "#0B2E3F"
  readonly property color baseKimiWarm: "#1E7FA8"
  readonly property color baseKimiHot:  "#4FD6FF"
  readonly property color kimiCold: themed(baseKimiCold, "cyan", "blue")
  readonly property color kimiWarm: themed(baseKimiWarm, "cyan", "blue")
  readonly property color kimiHot:  themed(baseKimiHot,  "cyan", "blue")

  readonly property color baseLocalCold: "#241046"
  readonly property color baseLocalWarm: "#7A3BE0"
  readonly property color baseLocalHot:  "#C79BFF"
  readonly property color localCold: themed(baseLocalCold, "blue", "accent")
  readonly property color localWarm: themed(baseLocalWarm, "blue", "accent")
  readonly property color localHot:  themed(baseLocalHot,  "blue", "accent")

  readonly property color baseEmberAmber: "#FFC46B"
  readonly property color emberAmber: themed(baseEmberAmber, "yellow", "orange")
  // The convergence point is deliberately near-white; its saturation is low
  // enough that borrowing a hue would not be visible, so it stays literal.
  readonly property color whiteHot: "#FFF6EC"

  // Quota and temperature ramps read literally: green/yellow/red mean the same
  // thing in every theme, and there is no identity to preserve.
  readonly property color gaugeGood: themeColors && themePalette["green"]
    ? themePalette["green"] : "#22c55e"
  readonly property color gaugeWarn: themeColors && themePalette["yellow"]
    ? themePalette["yellow"] : "#facc15"
  readonly property color okGreen: themeColors && themePalette["green"]
    ? themePalette["green"] : "#35f28b"

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
  // `faulted` is per lane: a dead cloud collector reddens the cloud lanes and
  // nothing else. Local telemetry has its own probe and its own truth.
  function heat(level, cold, warm, hot, faulted) {
    if (faulted === undefined ? root.broken : faulted) return Qt.rgba(urgent.r, urgent.g, urgent.b, 1)
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
  readonly property real grokRef: Math.max(svc ? svc.grokPeak : 0, scaleFloor)
  readonly property real kimiRef: Math.max(svc ? svc.kimiPeak : 0, scaleFloor)

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

  // Grok rides after Codex: oldest→newest left to right, same token scale.
  function grokLevel(i) {
    var b = root.buckets
    if (!b || !b.length) return 0
    var idx = b.length - root.cellCount + i
    return root.norm(idx >= 0 && idx < b.length ? Number(b[idx].grok || 0) : 0, root.grokRef)
  }

  // Kimi rides after Grok on the same token scale.
  function kimiLevel(i) {
    var b = root.buckets
    if (!b || !b.length) return 0
    var idx = b.length - root.cellCount + i
    return root.norm(idx >= 0 && idx < b.length ? Number(b[idx].kimi || 0) : 0, root.kimiRef)
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
    if (percent >= 0.75) return gaugeWarn
    return gaugeGood
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
    || ((!showClaude || (svc ? svc.claudeLatest : 0) <= 0)
        && (!showCodex || (svc ? svc.codexLatest : 0) <= 0)
        && (!showGrok || (svc ? svc.grokLatest : 0) <= 0)))

  // One number for "how hard is this machine working right now", across all
  // three agents. Drives every global effect: under-glow, sparks, frame rate.
  readonly property real energy: Math.max(
      root.broken || !root.showClaude ? 0 : root.claudeLevel(root.cellCount - 1),
      root.broken || !root.showCodex ? 0 : root.codexLevel(0),
      root.broken || !root.showGrok ? 0 : root.grokLevel(root.cellCount - 1),
      root.broken || !root.showKimi ? 0 : root.kimiLevel(root.cellCount - 1),
      root.showLocal && root.localOnline ? root.localLevel(0) : 0)

  readonly property color energyColor: root.broken ? urgent
    : root.mix(root.mix(root.mix(root.claudeHot, root.codexHot, 0.5), root.grokHot, 0.35),
               root.localHot, root.showLocal && root.localActive ? 0.45 : 0.12)

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
  property real grokFlash: 0
  property real kimiFlash: 0
  property real localFlash: 0
  // Wave position gets its own monotonic 0→1. The flash value (up in 90 ms,
  // down over 700) is brightness only; driving position from it sent the
  // band racing outward and then drifting back toward the divider as it faded.
  property real claudeWave: 0
  property real codexWave: 0
  property real grokWave: 0

  ParallelAnimation {
    id: claudeImpact
    NumberAnimation { target: root; property: "claudeWave"; from: 0; to: 1; duration: 790; easing.type: Easing.OutCubic }
    SequentialAnimation {
      NumberAnimation { target: root; property: "claudeFlash"; to: 1; duration: 90; easing.type: Easing.OutQuad }
      NumberAnimation { target: root; property: "claudeFlash"; to: 0; duration: 700; easing.type: Easing.OutCubic }
    }
  }
  ParallelAnimation {
    id: codexImpact
    NumberAnimation { target: root; property: "codexWave"; from: 0; to: 1; duration: 790; easing.type: Easing.OutCubic }
    SequentialAnimation {
      NumberAnimation { target: root; property: "codexFlash"; to: 1; duration: 90; easing.type: Easing.OutQuad }
      NumberAnimation { target: root; property: "codexFlash"; to: 0; duration: 700; easing.type: Easing.OutCubic }
    }
  }
  ParallelAnimation {
    id: grokImpact
    NumberAnimation { target: root; property: "grokWave"; from: 0; to: 1; duration: 790; easing.type: Easing.OutCubic }
    SequentialAnimation {
      NumberAnimation { target: root; property: "grokFlash"; to: 1; duration: 90; easing.type: Easing.OutQuad }
      NumberAnimation { target: root; property: "grokFlash"; to: 0; duration: 700; easing.type: Easing.OutCubic }
    }
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
    function onGrokPulseChanged() { grokImpact.restart() }
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
    // Which instrument's fault this lane shows. Cloud lanes follow the
    // collector; the local lane never does.
    property bool faulted: root.broken

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

        // Motion (flicker, idle drift, impact) rides on top of the sample.
        // Colour reads the sum. Height reads the sample through an eased
        // Behavior and the motion through a plain scale — so a 5 Hz flicker
        // step never restarts a 420 ms height animation on every cell, which
        // is what kept two rectangles per cell animating continuously while
        // the strip was supposedly idle.
        readonly property real motion: flicker + lane.flash * recency * recency * 0.25 + idleSwell
        readonly property real heatLevel: Math.max(0, level + motion)
        readonly property color tint: root.heat(heatLevel, lane.cold, lane.warm, lane.hot, lane.faulted)

        width: lane.cellWidth
        height: lane.height
        x: index * lane.slot
        anchors.verticalCenter: parent.verticalCenter

        // Height is the secondary channel: a 72%→100% swell that gives the lane
        // a profile without stealing the story from colour.
        readonly property real cellHeight:
          lane.height * (0.72 + 0.28 * Math.min(1, cell.level))
        readonly property real motionScale: Math.max(0.6, Math.min(1.3, 1 + 0.28 * cell.motion))

        // Bloom: a wider, softer ghost behind the cell. A cheap fake glow that
        // costs one rectangle instead of a blur pass.
        Rectangle {
          id: bloom
          anchors.centerIn: parent
          width: parent.width + Style.spaceReal(3)
          height: cell.cellHeight + Style.spaceReal(3)
          radius: Style.spaceReal(2)
          color: cell.tint
          border.width: 0
          opacity: Math.pow(cell.level, 1.6) * 0.42 * (0.4 + 0.6 * cell.recency)
            + lane.flash * cell.recency * cell.recency * 0.45
          transform: Scale { origin.x: bloom.width / 2; origin.y: bloom.height / 2; yScale: cell.motionScale }
          Behavior on height { NumberAnimation { duration: 420; easing.type: Easing.OutCubic } }
        }

        Rectangle {
          id: body
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
          transform: Scale { origin.x: body.width / 2; origin.y: body.height / 2; yScale: cell.motionScale }
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
          id: liveRing
          visible: cell.live && !root.idle && !lane.faulted && root.visible
          anchors.centerIn: parent
          width: parent.width
          height: cell.cellHeight
          radius: Style.spaceReal(1)
          color: "transparent"
          border.color: root.whiteHot
          border.width: Style.spaceReal(1)
          opacity: 0
          SequentialAnimation on opacity {
            running: liveRing.visible
            loops: Animation.Infinite
            onRunningChanged: if (!running) liveRing.opacity = 0
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
    // Negative means the service would not vouch for the number: the record
    // is stale or its window rolled over. An unknown gauge is an empty,
    // dimmer track — not a green sliver that reads as "0% used".
    readonly property bool unknown: percent < 0

    Rectangle {
      anchors.fill: parent
      radius: width / 2
      color: Util.alpha(gauge.accent, gauge.unknown ? 0.06 : 0.14)
      border.width: 0
      Behavior on color { ColorAnimation { duration: 400 } }
    }
    Rectangle {
      id: fill
      anchors.bottom: parent.bottom
      anchors.horizontalCenter: parent.horizontalCenter
      width: parent.width
      radius: width / 2
      height: gauge.unknown ? 0 : Math.max(1, parent.height * Math.min(1, gauge.percent))
      visible: !gauge.unknown
      color: root.gaugeColor(gauge.percent)
      border.width: 0
      Behavior on height { NumberAnimation { duration: 900; easing.type: Easing.OutCubic } }
      Behavior on color { ColorAnimation { duration: 400 } }

      // Quota nearly gone gets its own heartbeat — you should not have to read
      // a number to learn you are about to be cut off. Gated on the gauge
      // actually being on screen, and the fill is restored to full when the
      // beat stops so a quota that drops under 90% mid-pulse is not left dim.
      SequentialAnimation on opacity {
        running: !gauge.unknown && gauge.percent >= 0.9 && gauge.visible && root.visible
        loops: Animation.Infinite
        onRunningChanged: if (!running) fill.opacity = 1
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
    fixedWidth: root.stripWidth
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
        + 0.12 * Math.max(root.claudeFlash, Math.max(root.codexFlash, Math.max(root.grokFlash, root.localFlash)))
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
      readonly property int grokSep: Style.space(2)
      readonly property bool showDivider: (root.showClaude && root.showCodex) || root.grokAsRight
      readonly property int gaugeCount: root.showGauges ? root.cloudAgents : 0
      readonly property real gaugesSpace: gaugeCount * (gaugeWidth + gaugeGap)
      readonly property real dividerSpace: showDivider ? dividerWidth : 0
      // `graph.grokSep`, qualified: the separator Item below is `id: grokSep`,
      // and an id outranks a property of the same name in scope resolution.
      // Unqualified, this bound an Item into a real and made the whole chain
      // below (inner → sideWidth → every lane width) NaN.
      readonly property real grokSepSpace: root.grokExtra ? graph.grokSep : 0
      readonly property real kimiSepSpace: root.kimiExtra ? graph.grokSep : 0
      readonly property real inner: Math.max(1, width - localWidth - ruleWidth
        - gaugesSpace - dividerSpace - grokSepSpace - kimiSepSpace)
      readonly property real extraGrokW: root.grokExtra
        ? Math.max(Style.space(10), Math.round(inner * 0.16)) : 0
      // Kimi takes the same narrow band as Grok. Every term here is 0 while the
      // lane is hidden, so a strip without Kimi lays out exactly as before.
      readonly property real extraKimiW: root.kimiExtra
        ? Math.max(Style.space(10), Math.round(inner * 0.16)) : 0
      readonly property real pairInner: Math.max(1, inner - extraGrokW - extraKimiW)
      readonly property real sideWidth: root.cloudAgents <= 1 ? pairInner
        : Math.max(1, pairInner / 2)
      readonly property real claudeLaneWidth: !root.showClaude ? 0
        : root.cloudAgents === 1 ? pairInner : sideWidth
      readonly property real codexLaneWidth: !root.showCodex ? 0
        : root.cloudAgents === 1 ? pairInner : sideWidth
      readonly property real grokLaneWidth: !root.showGrok ? 0
        : root.cloudAgents === 1 ? pairInner
        : root.grokExtra ? extraGrokW
        : sideWidth
      readonly property real kimiLaneWidth: !root.showKimi ? 0
        : root.cloudAgents === 1 ? pairInner
        : root.kimiExtra ? extraKimiW
        : sideWidth

      // Zone spans, used for both the tinted plates and hit-testing. Derived
      // from the same numbers that lay the lanes out, so a plate can never
      // drift out from under the instrument it is naming.
      readonly property real claudeGaugeSpace: root.showGauges && root.showClaude ? gaugeWidth + gaugeGap : 0
      readonly property real codexGaugeSpace: root.showGauges && root.showCodex ? gaugeGap + gaugeWidth : 0
      readonly property real grokGaugeSpace: root.showGauges && root.showGrok ? gaugeGap + gaugeWidth : 0
      readonly property real kimiGaugeSpace: root.showGauges && root.showKimi ? gaugeGap + gaugeWidth : 0
      readonly property real claudeZoneWidth:
        claudeGaugeSpace + claudeLaneWidth + (showDivider ? dividerWidth / 2 : 0)
      readonly property real codexZoneWidth:
        (showDivider ? dividerWidth / 2 : 0) + codexLaneWidth + codexGaugeSpace
      readonly property real grokZoneStart: claudeZoneWidth + codexZoneWidth
      readonly property real grokZoneWidth:
        grokSepSpace + grokLaneWidth + grokGaugeSpace
      readonly property real kimiZoneStart: grokZoneStart + grokZoneWidth
      readonly property real kimiZoneWidth:
        kimiSepSpace + kimiLaneWidth + kimiGaugeSpace + ruleWidth / 2
      readonly property real localZoneStart: kimiZoneStart + kimiZoneWidth
      readonly property real localZoneWidth: Math.max(0, width - localZoneStart)

      function zoneAt(x) {
        if (root.showClaude && x < claudeZoneWidth) return root.zoneClaude
        if (root.showCodex && x < grokZoneStart) return root.zoneCodex
        if (root.showGrok && x < kimiZoneStart) return root.zoneGrok
        if (root.showKimi && (!root.showLocal || x < localZoneStart)) return root.zoneKimi
        if (root.showLocal) return root.zoneLocal
        if (root.showKimi) return root.zoneKimi
        if (root.showGrok) return root.zoneGrok
        if (root.showCodex) return root.zoneCodex
        return root.showClaude ? root.zoneClaude : root.zoneNone
      }

      // Tinted plates: the cheapest possible answer to "where does Claude end
      // and Codex begin". Always faintly on, so the three sections are legible
      // at a glance; brighter under the pointer, so hovering confirms which one
      // the tooltip is talking about.
      Repeater {
        model: [
          { zone: root.zoneClaude, from: 0, span: graph.claudeZoneWidth, on: root.showClaude },
          { zone: root.zoneCodex, from: graph.claudeZoneWidth, span: graph.codexZoneWidth, on: root.showCodex },
          { zone: root.zoneGrok, from: graph.grokZoneStart, span: graph.grokZoneWidth, on: root.showGrok },
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
        visible: root.showGauges && root.showClaude
        width: visible ? graph.gaugeWidth : 0
        height: parent.height
        anchors.left: parent.left
        anchors.verticalCenter: parent.verticalCenter
        percent: root.svc ? Math.min(1, root.svc.claudeWeekly) : -1
        accent: root.claudeHot
      }

      ThermalLane {
        id: claudeLane
        visible: root.showClaude
        width: graph.claudeLaneWidth
        height: parent.height
        anchors.left: claudeGauge.right
        anchors.leftMargin: claudeGauge.visible ? graph.gaugeGap : 0
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
        visible: graph.showDivider
        width: graph.showDivider ? graph.dividerWidth : 0
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
        visible: root.showCodex
        width: graph.codexLaneWidth
        height: parent.height
        anchors.left: divider.right
        anchors.verticalCenter: parent.verticalCenter
        count: root.cellCount
        cold: root.codexCold; warm: root.codexWarm; hot: root.codexHot
        newestLast: root.cloudAgents === 1
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
        x: claudeLane.x + claudeLane.width * (1 - root.claudeWave) - width / 2
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
        x: codexLane.x + codexLane.width * root.codexWave - width / 2
        opacity: root.codexFlash * 0.55
      }

      // Codex weekly fuel gauge — the right bookend of the mirrored pair.
      QuotaGauge {
        id: codexGauge
        visible: root.showGauges && root.showCodex
        width: visible ? graph.gaugeWidth : 0
        height: parent.height
        anchors.left: codexLane.right
        anchors.leftMargin: visible ? graph.gaugeGap : 0
        anchors.verticalCenter: parent.verticalCenter
        percent: root.svc ? Math.min(1, root.svc.codexWeekly) : -1
        accent: root.codexHot
      }

      // Soft sep before Grok so the mirrored Claude/Codex instrument stays whole.
      Item {
        id: grokSeparator
        visible: root.grokExtra
        width: root.grokExtra ? graph.grokSep : 0
        height: parent.height
        anchors.left: codexGauge.right
        anchors.verticalCenter: parent.verticalCenter
        Rectangle {
          anchors.centerIn: parent
          width: 1
          height: parent.height * 0.7
          color: root.grokHot
          border.width: 0
          opacity: 0.28
        }
      }

      ThermalLane {
        id: grokLane
        visible: root.showGrok
        width: graph.grokLaneWidth
        height: parent.height
        anchors.left: grokSeparator.right
        anchors.verticalCenter: parent.verticalCenter
        count: root.cellCount
        cold: root.grokCold; warm: root.grokWarm; hot: root.grokHot
        newestLast: true
        flash: root.grokFlash
        phaseSign: 1
        levelAt: function(i) { return root.grokLevel(i) }
      }

      Item {
        id: kimiSeparator
        visible: root.kimiExtra
        width: root.kimiExtra ? graph.grokSep : 0
        height: parent.height
        anchors.left: root.showGauges && root.showGrok ? grokGauge.right : grokLane.right
        anchors.verticalCenter: parent.verticalCenter
      }

      ThermalLane {
        id: kimiLane
        visible: root.showKimi
        width: graph.kimiLaneWidth
        height: parent.height
        anchors.left: kimiSeparator.right
        anchors.verticalCenter: parent.verticalCenter
        count: root.cellCount
        cold: root.kimiCold; warm: root.kimiWarm; hot: root.kimiHot
        newestLast: true
        flash: root.kimiFlash
        phaseSign: 1
        levelAt: function(i) { return root.kimiLevel(i) }
      }

      QuotaGauge {
        id: kimiGauge
        // Kimi publishes no quota, so this reads as unknown rather than 0%.
        visible: root.showGauges && root.showKimi
        width: visible ? graph.gaugeWidth : 0
        height: parent.height
        anchors.left: kimiLane.right
        anchors.leftMargin: visible ? graph.gaugeGap : 0
        anchors.verticalCenter: parent.verticalCenter
        percent: -1
        accent: root.kimiHot
      }

      Rectangle {
        id: grokWave
        visible: root.grokFlash > 0.01
        width: Style.spaceReal(3)
        height: graph.height
        radius: width / 2
        color: root.grokHot
        border.width: 0
        anchors.verticalCenter: parent.verticalCenter
        x: grokLane.x + grokLane.width * root.grokWave - width / 2
        opacity: root.grokFlash * 0.55
      }

      QuotaGauge {
        id: grokGauge
        visible: root.showGauges && root.showGrok
        width: visible ? graph.gaugeWidth : 0
        height: parent.height
        anchors.left: grokLane.right
        anchors.leftMargin: visible ? graph.gaugeGap : 0
        anchors.verticalCenter: parent.verticalCenter
        percent: root.svc ? Math.min(1, root.svc.grokWeekly) : -1
        accent: root.grokHot
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
        anchors.left: root.showGauges ? grokGauge.right : grokLane.right
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
          : root.localActive ? root.localHot : root.okGreen
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

            // Both loops are gated on the lane actually being shown, and each
            // puts its property back when it stops — a stopped animation
            // leaves whatever value it was mid-way through.
            SequentialAnimation on scale {
              running: root.localActive && root.visible && root.showLocal
              loops: Animation.Infinite
              onRunningChanged: if (!running) coreDot.scale = 1
              NumberAnimation { to: 1.16; duration: 480; easing.type: Easing.InOutSine }
              NumberAnimation { to: 0.94; duration: 480; easing.type: Easing.InOutSine }
            }
            // Offline is a fault, and faults strobe rather than breathe.
            SequentialAnimation on opacity {
              running: !root.localOnline && root.visible && root.showLocal
              loops: Animation.Infinite
              onRunningChanged: if (!running) coreDot.opacity = 1
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
          faulted: false
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
      if (code === Qt.MiddleButton) { if (root.svc) { root.svc.refreshLimits(); root.svc.collect(); root.svc.pollLocal() } }
      else root.toggle()
    }
  }

  readonly property bool opened: panel.opened
  function open() { panel.controller.show(); if (svc) { svc.refreshLimits(); svc.collect(); svc.pollLocal() } }
  function close() { panel.controller.hide() }
  function toggle() { opened ? close() : open() }
  function closeForPopoutSwitch() { close() }
  readonly property bool popoutSwitchClosing: false

  BurnPanel {
    id: panel
    widget: root
  }
}
