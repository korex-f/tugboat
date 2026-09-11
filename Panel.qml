import QtQuick
import QtQuick.Controls
import Quickshell
import Quickshell.Io
import qs.Commons
import qs.Ui

Panel {
  id: root
  moduleName: "io.github.dki.tugboat"
  manageIpc: false
  property var anchorItem: null
  property var hostWidget: null
  property string barLabel: "󰇚"
  property var transfers: []
  property string errorText: "Starting aria2…"
  property string browserPayload: ""
  property bool busy: false
  property var previousStatus: ({})
  readonly property color fg: bar ? bar.foreground : Color.foreground
  readonly property color muted: Qt.darker(fg, 1.5)
  readonly property string fontFamily: bar ? bar.fontFamily : Style.font.family
  readonly property int activeCount: transfers.filter(function(x) { return x.status === "active" }).length
  readonly property int aggregateSpeed: transfers.reduce(function(n, x) { return n + Number(x.downloadSpeed || 0) }, 0)

  function pathFromUrl(url) {
    var value = String(url || "")
    return value.indexOf("file://") === 0 ? decodeURIComponent(value.substring(7)) : value
  }
  function ctl(args) { return ["python3", pathFromUrl(Qt.resolvedUrl("scripts/tugboatctl"))].concat(args) }
  function humanSpeed(bytes) {
    if (bytes < 1024) return bytes + " B/s"
    if (bytes < 1048576) return Math.round(bytes / 1024) + " KiB/s"
    return (bytes / 1048576).toFixed(1) + " MiB/s"
  }
  function formatDuration(seconds) {
    var remaining = Math.max(0, Math.floor(Number(seconds) || 0))
    var hours = Math.floor(remaining / 3600)
    var minutes = Math.floor((remaining % 3600) / 60)
    var secs = remaining % 60
    if (hours > 0) return hours + "h " + minutes + "m"
    if (minutes > 0) return minutes + "m " + secs + "s"
    return secs + "s"
  }
  function itemEta(item) {
    var remaining = Math.max(0, Number(item.totalLength || 0) - Number(item.completedLength || 0))
    var speed = Number(item.downloadSpeed || 0)
    return remaining > 0 && speed > 0 ? "ETA " + formatDuration(Math.ceil(remaining / speed)) : ""
  }
  function percent(item) {
    var total=Number(item.totalLength || 0); return total ? Math.min(100, Math.round(Number(item.completedLength || 0) * 100 / total)) : 0
  }
  function itemName(item) {
    if (item.files && item.files.length && item.files[0].path) return String(item.files[0].path).split("/").pop()
    if (item.bittorrent && item.bittorrent.info && item.bittorrent.info.name) return item.bittorrent.info.name
    return item.gid
  }
  function refresh() { statusProc.command = ctl(["status"]); statusProc.running = true }
  function provision() {
    var port = settings && settings.rpcPort ? String(settings.rpcPort) : "0"
    var directory = settings && settings.downloadDirectory ? String(settings.downloadDirectory) : "~/Downloads"
    var args = ["ensure", "--port", port, "--directory", directory]
    if (!settings || settings.autoStart !== false) args.push("--auto-start")
    provisionProc.command = ctl(args); provisionProc.running = true
  }
  function doAction(action, gid) {
    var args = ["action", action]
    if (action === "limit") args.push("--limit", gid || "0")
    else if (gid) args.push(gid)
    actionProc.command = ctl(args); actionProc.running = true
  }
  function addUrl() {
    var value = addField.text.trim(); if (!value) return
    addProc.command = ctl(["add", value]); addProc.running = true; addField.text = ""
  }
  function addTorrent(file) { addProc.command = ctl(["add", "--torrent", file]); addProc.running = true }
  function connect(browser) { browserProc.command = ctl(["browser", "--browser", browser]); browserProc.running = true }
  function notify(title, body, urgency) { notifyProc.command = ["notify-send", "-a", "Tugboat", "-u", urgency || "normal", title, body]; notifyProc.running = true }
  function open() { root.controller.show(); refresh() }
  function close() { root.controller.hide() }
  function toggle() { if (root.opened) close(); else open() }
  function closeForPopoutSwitch() { close() }
  function switchPanel(direction) { return bar && typeof bar.switchPanelFrom === "function" ? bar.switchPanelFrom(hostWidget || root, direction) : false }

  Component.onCompleted: provision()
  Timer { interval: 1500; running: root.opened; repeat: true; onTriggered: root.refresh() }
  Process {
    id: provisionProc
    stdout: StdioCollector { waitForEnd: true; onStreamFinished: {
      var r; try { r=JSON.parse(text) } catch(e) { root.errorText="Could not provision aria2"; return }
      root.errorText = r.ok ? "" : (r.error || "aria2 setup failed"); root.refresh()
    }}
  }
  Process {
    id: statusProc
    stdout: StdioCollector { waitForEnd: true; onStreamFinished: {
      var r; try { r=JSON.parse(text) } catch(e) { root.errorText="Invalid aria2 response"; return }
      var next=r.items || []
      for (var i=0; i<next.length; i++) {
        var item=next[i], was=root.previousStatus[item.gid]
        if (was && was !== item.status && item.status === "complete") root.notify("Download complete", root.itemName(item), "normal")
        if (was && was !== item.status && item.status === "error") root.notify("Download failed", root.itemName(item) + ": " + (item.errorMessage || "aria2 error"), "critical")
      }
      var statusMap={}; for (var j=0; j<next.length; j++) statusMap[next[j].gid]=next[j].status
      root.previousStatus=statusMap; root.transfers=next; root.errorText=r.ok ? "" : (r.error || "aria2 is unavailable")
      root.barLabel = root.activeCount ? "󰇚 " + root.activeCount + " " + root.humanSpeed(root.aggregateSpeed) : "󰇚"
    }}
  }
  Process { id: addProc; stdout: StdioCollector { waitForEnd: true; onStreamFinished: { var r=JSON.parse(text); root.errorText=r.ok ? "" : r.error; root.refresh() } } }
  Process { id: actionProc; stdout: StdioCollector { waitForEnd: true; onStreamFinished: { var r=JSON.parse(text); root.errorText=r.ok ? "" : r.error; root.refresh() } } }
  Process { id: browserProc; stdout: StdioCollector { waitForEnd: true; onStreamFinished: { var r=JSON.parse(text); root.browserPayload=r.ok ? JSON.stringify(r.config, null, 2) : r.error } } }
  Process { id: notifyProc }

  KeyboardPanel {
    id: panel
    anchorItem: root.anchorItem
    owner: root.hostWidget || root
    bar: root.bar
    open: root.opened
    focusTarget: keys
    contentWidth: panel.fittedContentWidth(Style.space(520))
    contentHeight: panel.fittedContentHeight(content.implicitHeight)
    PanelKeyCatcher { id: keys; anchors.fill: parent; onCloseRequested: root.close(); onTabRequested: function(d) { root.switchPanel(d) }
      Column {
        id: content
        width: parent.width
        spacing: Style.space(10)
        Text { text: "Downloads"; color: root.fg; font.family: root.fontFamily; font.pixelSize: Style.font.title; font.bold: true }
        Text { visible: root.errorText !== ""; width: parent.width; text: root.errorText; color: Color.urgent; wrapMode: Text.WordWrap }
        Row {
          width: parent.width; spacing: Style.space(6)
          TextField { id: addField; width: parent.width - addButton.width - Style.space(6); placeholderText: "Paste URL or magnet link"; onAccepted: root.addUrl() }
          Button { id: addButton; text: "Add"; onClicked: root.addUrl() }
        }
        Rectangle {
          width: parent.width; height: Style.space(34); radius: Style.cornerRadius; color: Qt.rgba(root.fg.r, root.fg.g, root.fg.b, 0.08)
          Text { anchors.centerIn: parent; text: "Drop a .torrent file here"; color: root.muted; font.family: root.fontFamily }
          DropArea { anchors.fill: parent; onDropped: function(drop) { if (drop.urls.length) root.addTorrent(root.pathFromUrl(drop.urls[0])) } }
        }
        Row {
          spacing: Style.space(8)
          Text { text: root.activeCount + " active · " + root.humanSpeed(root.aggregateSpeed); color: root.muted }
          Button { text: "Pause all"; onClicked: root.doAction("pause-all") }
          Button { text: "Refresh"; onClicked: root.refresh() }
        }
        Row {
          spacing: Style.space(6)
          Text { anchors.verticalCenter: parent.verticalCenter; text: "Limit KiB/s"; color: root.muted }
          TextField { id: limitField; width: Style.space(90); text: settings && settings.globalSpeedLimit ? String(settings.globalSpeedLimit) : "0"; inputMethodHints: Qt.ImhDigitsOnly }
          Button { text: "Apply"; onClicked: { var n=Number(limitField.text); if (isFinite(n) && n >= 0) root.doAction("limit", String(Math.floor(n))) } }
        }
        Repeater {
          model: root.transfers
          delegate: Rectangle {
            required property var modelData
            width: content.width; height: Style.space(76); radius: Style.cornerRadius; color: Qt.rgba(root.fg.r, root.fg.g, root.fg.b, 0.06)
            Column { anchors.left: parent.left; anchors.right: actions.left; anchors.verticalCenter: parent.verticalCenter; anchors.margins: Style.space(8); spacing: 3
              Text { width: parent.width; text: root.itemName(modelData); color: root.fg; elide: Text.ElideRight; font.bold: true }
              Text { text: root.percent(modelData) + "% · " + root.humanSpeed(Number(modelData.downloadSpeed || 0)) + (root.itemEta(modelData) !== "" ? " · " + root.itemEta(modelData) : "") + (modelData.bittorrent ? " · torrent" + (modelData.numSeeders ? " · " + modelData.numSeeders + " seeders" : "") : " · HTTP"); color: root.muted }
              ProgressBar { width: parent.width; value: root.percent(modelData) / 100 }
            }
            Row { id: actions; anchors.right: parent.right; anchors.rightMargin: Style.space(7); anchors.verticalCenter: parent.verticalCenter; spacing: 3
              Button { text: modelData.status === "active" ? "Pause" : "Resume"; onClicked: root.doAction(modelData.status === "active" ? "pause" : "resume", modelData.gid) }
              Button { text: "Remove"; onClicked: root.doAction("remove", modelData.gid) }
            }
          }
        }
        Text { visible: root.transfers.length === 0 && root.errorText === ""; text: "No queued or active downloads."; color: root.muted }
        Row {
          spacing: Style.space(8)
          Button { text: "Connect Chrome"; onClicked: root.connect("chrome") }
          Button { text: "Connect Firefox"; onClicked: root.connect("firefox") }
        }
        TextArea { visible: root.browserPayload !== ""; width: parent.width; height: visible ? Style.space(100) : 0; readOnly: true; text: root.browserPayload; wrapMode: TextEdit.WrapAnywhere; selectByMouse: true }
      }
    }
  }
}
