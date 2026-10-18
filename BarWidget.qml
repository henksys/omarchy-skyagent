import QtQuick
import qs.Ui

BarWidget {
  id: root
  moduleName: "io.github.henksys.skyagent"

  readonly property var panelItem: panelLoader.item
  readonly property bool opened: panelItem ? panelItem.opened === true : false
  readonly property string agentState: panelItem ? String(panelItem.agentState || "idle") : "idle"

  function injectPanel() {
    var target = panelLoader.item
    if (!target) return
    if ("bar" in target) target.bar = root.bar
    if ("hostWidget" in target) target.hostWidget = root
    if ("anchorItem" in target) target.anchorItem = button
  }

  function open() {
    if (panelItem) panelItem.open()
  }

  function close() {
    if (panelItem) panelItem.close()
  }

  function togglePanel() {
    if (opened) close()
    else open()
  }

  implicitWidth: button.implicitWidth
  implicitHeight: button.implicitHeight

  onBarChanged: injectPanel()

  Loader {
    id: panelLoader
    active: true
    source: Qt.resolvedUrl("Panel.qml")
    visible: false
    onLoaded: {
      root.injectPanel()
      Qt.callLater(root.injectPanel)
    }
  }

  BarIconButton {
    id: button
    anchors.fill: parent
    bar: root.bar
    text: {
      if (root.agentState === "listening") return "󰍬"
      if (root.agentState === "transcribing" || root.agentState === "thinking") return "󰔟"
      if (root.agentState === "speaking") return "󰕾"
      if (root.agentState === "error") return "󰅚"
      return "󰖝"
    }
    active: root.agentState !== "idle"
    tooltipText: "SkyAgent — click to chat · hold F10 to talk"
    onPressed: function(buttonCode) {
      if (buttonCode === Qt.LeftButton) root.togglePanel()
    }
  }
}
