import QtQuick
import QtQuick.Controls
import QtQuick.Layouts
import Quickshell
import Quickshell.Io
import qs.Commons
import qs.Ui

// Detail view for Burn Bar. The bar answers "is something burning right now";
// this answers "what, how much, how close am I to the wall" — and, for the
// local runner, "which model, and keep it warm".
Panel {
  id: panel
  moduleName: "nixfred.burnbar"
  manageIpc: false

  required property var widget
  readonly property var svc: widget.svc

  readonly property color foreground: widget.bar ? widget.bar.foreground : Color.foreground
  readonly property color dim: Qt.darker(foreground, 1.5)
  readonly property string fontFamily: widget.bar ? widget.bar.fontFamily : Style.font.family

  function switchPanel(direction) {
    if (widget.bar && typeof widget.bar.switchPanelFrom === "function")
      return widget.bar.switchPanelFrom(widget, direction)
    return false
  }

  // "in 2d 4h" reads faster than a timestamp when the only question you have is
  // how long until the quota comes back.
  function untilText(iso) {
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

  // ── local model control ───────────────────────────────────────────────────
  // The bar can only ever show that a local model is thinking. Doing something
  // about it — warming one, evicting one — belongs here, one click away.
  property var localOptions: []
  property string selectedModel: ""
  property bool localBusy: false
  property string localNote: ""

  readonly property color localState: !(svc && svc.localOnline) ? Color.urgent
    : (svc && svc.localActive) ? widget.localHot : "#35f28b"

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
          description: [panel.plainText(m.parameters, 64), panel.plainText(m.quantization, 64)]
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

  KeyboardPanel {
    anchorItem: panel.widget.anchorItem
    owner: panel.widget
    bar: panel.widget.bar
    open: panel.opened
    focusTarget: keyCatcher
    contentWidth: fittedContentWidth(Style.space(400))
    contentHeight: fittedContentHeight(content.implicitHeight, Style.space(620))

    PanelKeyCatcher {
      id: keyCatcher
      anchors.fill: parent
      blocked: modelPicker.popupOpen
      onCloseRequested: panel.widget.close()
      onTabRequested: direction => panel.switchPanel(direction)
      onTextKey: function(text) {
        if (text === "r" || text === "R") {
          if (panel.svc) { panel.svc.collect(); panel.svc.pollLocal() }
          panel.refreshLocalModels()
        }
      }

      Flickable {
        anchors.fill: parent
        contentWidth: width
        contentHeight: content.implicitHeight
        clip: true
        boundsBehavior: Flickable.StopAtBounds

        ColumnLayout {
          id: content
          width: parent.width
          spacing: Style.space(12)

          PanelHero {
            Layout.fillWidth: true
            title: panel.svc
              ? panel.widget.compact(panel.svc.claudeTotal + panel.svc.codexTotal)
              : "--"
            meta: "tokens burned · last "
              + Math.round((panel.svc ? panel.svc.windowMinutes : 360) / 60) + "h"
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
          }

          // Side-by-side totals, colour-matched to their side of the strip so the
          // panel and the bar teach each other.
          RowLayout {
            Layout.fillWidth: true
            spacing: Style.space(8)

            Repeater {
              // Three tiles, same order as the bar reads left to right. The local
              // tile deliberately shows a percentage, not a token count: nobody
              // is billed for it, and pretending otherwise would put free
              // compute on the same scale as metered spend.
              model: [
                {
                  name: "CLAUDE",
                  accent: panel.widget.claudeHot,
                  value: panel.svc ? panel.widget.compact(panel.svc.claudeTotal) : "--",
                  sub: (panel.svc ? panel.svc.claudeSessions : 0) + " sessions"
                },
                {
                  name: "CODEX",
                  accent: panel.widget.codexHot,
                  value: panel.svc ? panel.widget.compact(panel.svc.codexTotal) : "--",
                  sub: (panel.svc ? panel.svc.codexSessions : 0) + " sessions"
                },
                {
                  name: "LOCAL",
                  accent: panel.localState,
                  value: !(panel.svc && panel.svc.localOnline) ? "off"
                    : Math.round(panel.svc.localLoad) + "%",
                  sub: !(panel.svc && panel.svc.localOnline) ? "ollama down"
                    : (panel.svc.localModelCount > 0
                        ? panel.svc.localModelCount + " warm" : "no model warm")
                }
              ]
              delegate: Rectangle {
                required property var modelData
                Layout.fillWidth: true
                implicitHeight: Style.space(70)
                radius: Style.cornerRadius
                color: Util.alpha(modelData.accent, 0.10)
                border.width: 1
                border.color: Util.alpha(modelData.accent, 0.30)

                Column {
                  anchors.centerIn: parent
                  spacing: 2
                  Text {
                    anchors.horizontalCenter: parent.horizontalCenter
                    text: modelData.value
                    textFormat: Text.PlainText
                    color: modelData.accent
                    font.family: panel.fontFamily
                    font.bold: true
                    font.pixelSize: Style.font.title
                  }
                  Text {
                    anchors.horizontalCenter: parent.horizontalCenter
                    text: modelData.name
                    textFormat: Text.PlainText
                    color: panel.foreground
                    font.family: panel.fontFamily
                    font.pixelSize: Style.font.caption
                  }
                  Text {
                    anchors.horizontalCenter: parent.horizontalCenter
                    text: modelData.sub
                    textFormat: Text.PlainText
                    color: panel.dim
                    font.family: panel.fontFamily
                    font.pixelSize: Style.font.caption
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
              spacing: 3

              RowLayout {
                Layout.fillWidth: true
                Text {
                  text: modelData.agent + " · " + modelData.limit.label
                  textFormat: Text.PlainText
                  color: panel.foreground
                  font.family: panel.fontFamily
                  font.pixelSize: Style.font.bodySmall
                }
                Item { Layout.fillWidth: true }
                Text {
                  text: Math.round(Number(modelData.limit.percent) * 100) + "%  ·  resets "
                    + panel.untilText(modelData.limit.resetsAt)
                  textFormat: Text.PlainText
                  color: panel.dim
                  font.family: panel.fontFamily
                  font.pixelSize: Style.font.caption
                }
              }

              Rectangle {
                Layout.fillWidth: true
                implicitHeight: Style.space(6)
                radius: height / 2
                color: Util.alpha(panel.foreground, 0.10)

                Rectangle {
                  anchors.left: parent.left
                  anchors.verticalCenter: parent.verticalCenter
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
              Layout.fillWidth: true
              Text {
                text: panel.prettyModel(modelData.id)
                textFormat: Text.PlainText
                color: panel.foreground
                font.family: panel.fontFamily
                font.pixelSize: Style.font.bodySmall
              }
              Item { Layout.fillWidth: true }
              Text {
                text: panel.widget.compact(modelData.tokens)
                textFormat: Text.PlainText
                color: panel.widget.claudeHot
                font.family: panel.fontFamily
                font.bold: true
                font.pixelSize: Style.font.bodySmall
              }
            }
          }

          PanelSectionHeader {
            Layout.fillWidth: true
            text: "LOCAL INTELLIGENCE"
            foreground: panel.foreground
            fontFamily: panel.fontFamily
          }

          RowLayout {
            Layout.fillWidth: true
            Text {
              text: !(panel.svc && panel.svc.localOnline) ? "Ollama offline"
                : (panel.svc.localActive ? "Deep inference" : "Ready & idle")
              textFormat: Text.PlainText
              color: panel.foreground
              font.family: panel.fontFamily
              font.pixelSize: Style.font.bodySmall
            }
            Item { Layout.fillWidth: true }
            Text {
              text: panel.svc
                ? Math.round(panel.svc.localLoad) + "%  " + String(panel.svc.localBackend).toUpperCase()
                : "--"
              textFormat: Text.PlainText
              color: panel.localState
              font.family: panel.fontFamily
              font.bold: true
              font.pixelSize: Style.font.bodySmall
            }
          }

          Rectangle {
            Layout.fillWidth: true
            implicitHeight: Style.space(8)
            radius: height / 2
            color: Util.alpha(panel.foreground, 0.10)
            Rectangle {
              anchors.left: parent.left
              anchors.verticalCenter: parent.verticalCenter
              height: parent.height
              radius: height / 2
              width: parent.width * Math.max(0.02, Math.min(1,
                (panel.svc && panel.svc.localOnline ? panel.svc.localLoad : 0) / 100))
              color: panel.localState
              Behavior on width { NumberAnimation { duration: 280; easing.type: Easing.OutCubic } }
            }
          }

          Text {
            Layout.fillWidth: true
            text: panel.svc && panel.svc.localModel !== ""
              ? "resident: " + panel.svc.localModel
              : (panel.svc && panel.svc.localError !== "" ? panel.svc.localError
                : "no model resident in memory")
            textFormat: Text.PlainText
            color: panel.dim
            font.family: panel.fontFamily
            font.pixelSize: Style.font.caption
            wrapMode: Text.WordWrap
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
              enabled: !panel.localBusy && panel.svc && panel.svc.localOnline
                && panel.selectedModel !== ""
              onClicked: panel.runLocalAction("load")
            }
            Button {
              text: "Unload"
              enabled: !panel.localBusy && panel.svc && panel.svc.localOnline
                && panel.selectedModel !== ""
              onClicked: panel.runLocalAction("unload")
            }
            Item { Layout.fillWidth: true }
            PanelActionButton {
              iconText: "󰑐"
              tooltipText: "Refresh everything"
              foreground: panel.foreground
              fontFamily: panel.fontFamily
              onClicked: {
                panel.refreshLocalModels()
                if (panel.svc) { panel.svc.collect(); panel.svc.pollLocal() }
              }
            }
          }

          Text {
            Layout.fillWidth: true
            visible: panel.localNote !== ""
            text: panel.localNote
            textFormat: Text.PlainText
            color: panel.localState
            font.family: panel.fontFamily
            font.pixelSize: Style.font.caption
            wrapMode: Text.WordWrap
          }

          PanelSeparator { Layout.fillWidth: true; foreground: panel.foreground }

          Text {
            Layout.fillWidth: true
            text: (panel.svc && panel.svc.lastError !== "" ? panel.svc.lastError + "\n" : "")
              + "Claude ◄ now ► Codex  ║  Local  ·  colour is heat, height echoes it\n"
              + "Cloud lanes are tokens per bucket · local lane is runner load per second\n"
              + "Inner columns are weekly quota  ·  violet core is the Ollama reactor\n"
              + "Left click: details  ·  Middle: refresh now  ·  R: refresh"
            textFormat: Text.PlainText
            color: panel.svc && panel.svc.lastError !== "" ? "#ef4444" : panel.dim
            font.family: panel.fontFamily
            font.pixelSize: Style.font.caption
            wrapMode: Text.WordWrap
            horizontalAlignment: Text.AlignHCenter
          }
        }
      }
    }
  }
}
