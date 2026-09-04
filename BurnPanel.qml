import QtQuick
import QtQuick.Controls
import QtQuick.Layouts
import Quickshell
import qs.Commons
import qs.Ui

// Detail view for Burn Bar. The bar answers "is something burning right now";
// this answers "what, how much, and how close am I to the wall".
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
      onCloseRequested: panel.widget.close()
      onTabRequested: direction => panel.switchPanel(direction)
      onTextKey: function(text) {
        if (text === "r" || text === "R") { if (panel.svc) panel.svc.collect() }
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
              model: [
                {
                  name: "CLAUDE",
                  accent: panel.widget.claudeHot,
                  total: panel.svc ? panel.svc.claudeTotal : 0,
                  sessions: panel.svc ? panel.svc.claudeSessions : 0
                },
                {
                  name: "CODEX",
                  accent: panel.widget.codexHot,
                  total: panel.svc ? panel.svc.codexTotal : 0,
                  sessions: panel.svc ? panel.svc.codexSessions : 0
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
                    text: panel.widget.compact(modelData.total)
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
                    text: modelData.sessions + " sessions"
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

          PanelSeparator { Layout.fillWidth: true; foreground: panel.foreground }

          Text {
            Layout.fillWidth: true
            text: (panel.svc && panel.svc.lastError !== "" ? panel.svc.lastError + "\n" : "")
              + "Colour is tokens burned · height is the same signal, softened\n"
              + "Newest sits at the centre line · outer columns are weekly quota\n"
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
