import QtQuick
import Quickshell
import qs.Commons
import qs.Ui

BarWidget {
  id: root
  moduleName: "io.github.dki.tugboat"
  readonly property bool opened: panelLoader.item ? panelLoader.item.opened === true : false
  readonly property bool popoutSwitchClosing: panelLoader.item ? panelLoader.item.popoutSwitchClosing === true : false
  function open() { if (panelLoader.item) panelLoader.item.open() }
  function close() { if (panelLoader.item) panelLoader.item.close() }
  function toggle() { if (panelLoader.item) panelLoader.item.toggle() }
  function closeForPopoutSwitch() { if (panelLoader.item) panelLoader.item.closeForPopoutSwitch() }
  function injectPanel() {
    if (!panelLoader.item) return
    panelLoader.item.bar = root.bar
    panelLoader.item.anchorItem = button
    panelLoader.item.hostWidget = root
    panelLoader.item.settings = root.settings
  }
  implicitWidth: button.implicitWidth
  implicitHeight: button.implicitHeight
  onBarChanged: injectPanel()
  onSettingsChanged: injectPanel()
  Loader {
    id: panelLoader
    active: true
    source: Qt.resolvedUrl("Panel.qml")
    visible: false
    onLoaded: { root.injectPanel(); Qt.callLater(root.injectPanel) }
  }
  WidgetButton {
    id: button
    anchors.fill: parent
    bar: root.bar
    // The popout is anchored to this button. Keep its geometry stable while
    // the live count/speed label changes, otherwise a right-aligned bar moves
    // the anchor and makes the open panel jump sideways.
    fixedWidth: Style.space(144)
    text: panelLoader.item ? panelLoader.item.barLabel : "󰇚"
    tooltipText: "Tugboat"
    onPressed: function(mouseButton) { if (mouseButton === Qt.LeftButton) root.toggle() }
  }
}
