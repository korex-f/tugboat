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
  property var mediaTransfers: []
  property bool mediaPickerVisible: false
  property string mediaUrl: ""
  property string mediaTitle: ""
  property var mediaFormats: []
  property string selectedMediaFormat: "best"
  property bool mediaIsPlaylist: false
  property int mediaPlaylistCount: 0
  property string errorText: "Starting aria2…"
  property string browserPayload: ""
  property bool settingsVisible: false
  property bool detailsVisible: false
  property var selectedTransfer: null
  property bool ariaOnline: false
  property bool advancedVisible: false
  property bool restartingAria: false
  property string selectedGid: ""
  property bool shortcutsVisible: false
  property int settingsFocusIndex: -1
  property var ariaInfo: ({ port: "—", authenticated: false, autoStart: false, version: "aria2" })
  property bool busy: false
  property var previousStatus: ({})
  property bool statusInitialized: false
  property var previousMediaStatus: ({})
  property bool mediaStatusInitialized: false
  property string pluginVersion: ""
  readonly property color fg: bar ? bar.foreground : Color.foreground
  readonly property color muted: Qt.darker(fg, 1.5)
  readonly property color accent: Color.accent
  readonly property color surface: Style.normalFillFor(fg, accent, Color.urgent)
  readonly property color raisedSurface: Style.selectedFillFor(fg, accent, Color.urgent)
  readonly property var surfaceBorder: Border.controlSpec("normal", fg, accent)
  readonly property string fontFamily: bar ? bar.fontFamily : Style.font.family
  readonly property var allTransfers: transfers.concat(mediaTransfers)
  readonly property int downloadCount: allTransfers.length
  readonly property int activeCount: allTransfers.filter(function(x) { return x.status === "active" }).length
  readonly property int pausedCount: allTransfers.filter(function(x) { return x.status === "paused" }).length
  readonly property int clearableCount: allTransfers.filter(function(x) { return x.status === "complete" || x.status === "error" }).length
  readonly property int aggregateSpeed: allTransfers.reduce(function(n, x) { return n + Number(x.downloadSpeed || 0) }, 0)
  readonly property bool textInputActive: addField.activeFocus || browserPayloadArea.activeFocus || detailsArea.activeFocus
  property string speedLimitValue: "0"
  readonly property var speedLimitOptions: [{ label: "Unlimited", value: "0" }, { label: "256 KiB/s", value: "256" }, { label: "512 KiB/s", value: "512" }, { label: "1 MiB/s", value: "1024" }, { label: "2 MiB/s", value: "2048" }, { label: "5 MiB/s", value: "5120" }, { label: "10 MiB/s", value: "10240" }]

  function pathFromUrl(url) {
    var value = String(url || "")
    return value.indexOf("file://") === 0 ? decodeURIComponent(value.substring(7)) : value
  }
  function ctl(args) { return ["python3", pathFromUrl(Qt.resolvedUrl("scripts/tugboatctl"))].concat(args) }
  function mediaCtl(args) { return ["python3", pathFromUrl(Qt.resolvedUrl("scripts/tugboat-media.py"))].concat(args) }
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
    if (item.bittorrent && item.bittorrent.info && item.bittorrent.info.name) return item.bittorrent.info.name
    if (item.files && item.files.length && item.files[0].path) return String(item.files[0].path).split("/").pop()
    return item.gid
  }
  function typeLabel(item) { return item.bittorrent ? "TORRENT" : (item.cloud ? "CLOUD" : (item.media ? "VIDEO" : "HTTP")) }
  function stateLabel(item) { return item.status === "active" ? "DOWNLOADING" : String(item.status || "waiting").toUpperCase() }
  function itemMeta(item) {
    var eta = itemEta(item)
    var seeds = item.bittorrent ? " · " + Number(item.numSeeders || 0) + " seeds" : ""
    return percent(item) + "% · " + humanSpeed(Number(item.downloadSpeed || 0)) + " · " + (eta || "ETA —") + seeds
  }
  function openFolder(item) {
    var path = item.files && item.files.length ? String(item.files[0].path || "") : ""
    var slash = path.lastIndexOf("/")
    if (slash > 0) Qt.openUrlExternally("file://" + path.substring(0, slash))
    else root.notify("Folder unavailable", "This download has no local file path yet.", "low")
  }
  function copySource(item) {
    var uris = item.files && item.files.length ? item.files[0].uris : []
    var source = uris && uris.length ? String(uris[0].uri || "") : ""
    if (!source) { root.notify("Source unavailable", "aria2 did not retain a copyable source for this item.", "low"); return }
    Quickshell.execDetached(["bash", "-c", "printf %s " + Util.shellQuote(source) + " | wl-copy"])
    root.notify("Source copied", root.itemName(item), "low")
  }
  function refresh() {
    // Status polling is intentionally quiet: replacing a Repeater model with
    // identical fresh JSON objects makes every card briefly re-delegate.
    // Avoid overlapping requests as action completion and the timer can land
    // in the same event turn.
    if (!statusProc.running) { statusProc.command = ctl(["status"]); statusProc.running = true }
    if (!mediaStatusProc.running) { mediaStatusProc.command = mediaCtl(["status"]); mediaStatusProc.running = true }
  }
  function replaceTransfers(next, media) {
    var current = media ? root.mediaTransfers : root.transfers
    if (JSON.stringify(current) === JSON.stringify(next)) return
    if (media) root.mediaTransfers = next
    else root.transfers = next
    root.syncQueue()
  }
  function syncQueue() {
    // Keep delegates alive while aria2 updates speed and byte counters. A
    // Repeater over a freshly concatenated JS array tears down every card;
    // this model only updates the payload role of the affected card.
    var next = root.transfers.concat(root.mediaTransfers)
    var wanted = ({})
    for (var i = 0; i < next.length; i++) wanted[next[i].gid] = next[i]
    for (var j = queueModel.count - 1; j >= 0; j--) {
      var existing = queueModel.get(j)
      if (!wanted[existing.gid]) queueModel.remove(j)
    }
    for (var k = 0; k < next.length; k++) {
      var item = next[k], index = -1
      for (var n = 0; n < queueModel.count; n++) if (queueModel.get(n).gid === item.gid) { index = n; break }
      if (index < 0) queueModel.append({ gid: item.gid, payload: item })
      else if (JSON.stringify(queueModel.get(index).payload) !== JSON.stringify(item)) queueModel.setProperty(index, "payload", item)
    }
    if (queueModel.count === 0) selectedGid = ""
    else if (selectedGid !== "" && queueIndexFor(selectedGid) < 0) selectedGid = ""
  }
  function queueIndexFor(gid) {
    for (var i = 0; i < queueModel.count; i++) if (queueModel.get(i).gid === gid) return i
    return -1
  }
  function selectedTransfer() {
    var index = queueIndexFor(selectedGid)
    return index >= 0 ? queueModel.get(index).payload : null
  }
  function moveQueueSelection(delta) {
    if (queueModel.count === 0) return
    var index = queueIndexFor(selectedGid)
    if (index < 0) index = delta > 0 ? 0 : queueModel.count - 1
    else index = Math.max(0, Math.min(queueModel.count - 1, index + delta))
    selectedGid = queueModel.get(index).gid
    Qt.callLater(function() { keepSelectedQueueRowVisible(index) })
  }
  function keepSelectedQueueRowVisible(index) {
    var item = queueRepeater.itemAt(index)
    if (!item) return
    var top = item.y, bottom = top + item.height
    if (top < queueScroll.contentY) queueScroll.contentY = top
    else if (bottom > queueScroll.contentY + queueScroll.height) queueScroll.contentY = bottom - queueScroll.height
  }
  function toggleSelectedTransfer() {
    var item = selectedTransfer()
    if (item) doAction(item.status === "active" ? "pause" : "resume", item.gid)
  }
  function removeSelectedTransfer() {
    var item = selectedTransfer()
    if (item) doAction("remove", item.gid)
  }
  function provision() {
    var port = settings && settings.rpcPort ? String(settings.rpcPort) : "0"
    var directory = settings && settings.downloadDirectory ? String(settings.downloadDirectory) : "~/Downloads"
    var args = ["ensure", "--port", port, "--directory", directory]
    if (!settings || settings.autoStart !== false) args.push("--auto-start")
    provisionProc.command = ctl(args); provisionProc.running = true
  }
  function resumeAll() { actionProc.command = ctl(["action", "resume-all"]); actionProc.running = true; mediaActionProc.command = mediaCtl(["action", "resume-all"]); mediaActionProc.running = true }
  function clearFinished() { actionProc.command = ctl(["action", "clear-finished"]); actionProc.running = true; mediaActionProc.command = mediaCtl(["action", "clear-finished"]); mediaActionProc.running = true }
  function doAction(action, gid) {
    if (String(gid || "").indexOf("yt:") === 0) { mediaActionProc.command = mediaCtl(["action", action, String(gid).substring(3)]); mediaActionProc.running = true; return }
    var args = ["action", action]
    if (action === "limit") args.push("--limit", gid || "0")
    else if (gid) args.push(gid)
    actionProc.command = ctl(args); actionProc.running = true
  }
  function addRawUrl(value) { addProc.command = ctl(["add", value]); addProc.running = true }
  function addUrl() {
    var value = addField.text.trim(); if (!value) return
    if (value.indexOf("cloud:") === 0) { startCloud(value.substring(6)); addField.text = ""; return }
    mediaInspectProc.command = mediaCtl(["inspect", value]); mediaInspectProc.running = true; mediaUrl = value; addField.text = ""
  }
  function startCloud(source) {
    var directory = settings && settings.downloadDirectory ? String(settings.downloadDirectory) : "~/Downloads"
    mediaStartProc.command = mediaCtl(["cloud", source, "--directory", directory]); mediaStartProc.running = true
  }
  function startMedia() {
    var directory = settings && settings.downloadDirectory ? String(settings.downloadDirectory) : "~/Downloads"
    var args = ["start", mediaUrl, "--title", mediaTitle, "--format", selectedMediaFormat, "--directory", directory]
    if (mediaIsPlaylist) args.push("--playlist")
    mediaStartProc.command = mediaCtl(args); mediaStartProc.running = true
  }
  function addTorrent(file) { addProc.command = ctl(["add", "--torrent", file]); addProc.running = true }
  function connect(browser) { browserPayload = ""; browserProc.command = ctl(["browser", "--browser", browser]); browserProc.running = true }
  function refreshAriaInfo() { if (!ariaInfoProc.running) { ariaInfoProc.command = ctl(["info"]); ariaInfoProc.running = true } }
  function restartAria() { if (restartingAria) return; restartingAria = true; restartAriaProc.command = ctl(["restart"]); restartAriaProc.running = true }
  function setAutoStart(enabled) { if (!autoStartProc.running) { autoStartProc.command = ctl(["auto-start", enabled ? "on" : "off"]); autoStartProc.running = true } }
  function openPluginConfig() {
    var path = Quickshell.env("HOME") + "/.config/omarchy/shell.json"
    Quickshell.execDetached(["omarchy-launch-floating-terminal-with-presentation", "nvim " + Util.shellQuote(path)])
  }
  function notify(title, body, urgency) { notifyProc.command = ["notify-send", "-a", "Tugboat", "-u", urgency || "normal", title, body]; notifyProc.running = true }
  function open() { root.controller.show(); refresh() }
  function resetSettingsView() {
    settingsVisible = false
    detailsVisible = false
    advancedVisible = false
    browserPayload = ""
    settingsScroll.contentY = 0
  }
  function scrollSettings(amount) {
    var maximum = Math.max(0, settingsScroll.contentHeight - settingsScroll.height)
    settingsScroll.contentY = Math.max(0, Math.min(maximum, settingsScroll.contentY + amount))
  }
  function closeSettingsView() { settingsVisible = false; detailsVisible = false; browserPayload = ""; settingsFocusIndex = -1 }
  function openSettings() { settingsVisible = true; detailsVisible = false; refreshAriaInfo() }
  function focusSettingsControl(direction) {
    var controls = [openConfig, rcloneConfigButton, autoStartButton, restartAriaButton, advancedButton, chromeConnectButton, firefoxConnectButton]
    if (controls.length === 0) return
    settingsFocusIndex = (settingsFocusIndex + direction + controls.length) % controls.length
    controls[settingsFocusIndex].forceActiveFocus()
  }
  function activateSettingsFocus() {
    var controls = [openConfig, rcloneConfigButton, autoStartButton, restartAriaButton, advancedButton, chromeConnectButton, firefoxConnectButton]
    if (settingsFocusIndex >= 0 && settingsFocusIndex < controls.length && controls[settingsFocusIndex].enabled)
      controls[settingsFocusIndex].clicked()
  }
  function close() { resetSettingsView(); root.controller.hide() }
  function toggle() { if (root.opened) close(); else open() }
  function closeForPopoutSwitch() { close() }
  function switchPanel(direction) { return bar && typeof bar.switchPanelFrom === "function" ? bar.switchPanelFrom(hostWidget || root, direction) : false }

  Component.onCompleted: { provision(); refreshAriaInfo(); mediaDependencyProc.command = mediaCtl(["check"]); mediaDependencyProc.running = true; manifestVersionProc.command = ["cat", pathFromUrl(Qt.resolvedUrl("manifest.json"))]; manifestVersionProc.running = true }
  onOpenedChanged: if (!opened) resetSettingsView()
  Timer { interval: 1500; running: true; repeat: true; onTriggered: root.refresh() }
  ListModel { id: queueModel }
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
        if (root.statusInitialized && !was && item.status === "active")
          root.notify("Download started", root.itemName(item), "low")
        if (root.statusInitialized && was && was !== item.status && item.status === "complete")
          root.notify("Download complete", root.itemName(item), "normal")
        if (root.statusInitialized && was && was !== item.status && item.status === "error")
          root.notify("Download failed", root.itemName(item) + ": " + (item.errorMessage || "aria2 error"), "critical")
      }
      var statusMap={}; for (var j=0; j<next.length; j++) statusMap[next[j].gid]=next[j].status
      root.previousStatus=statusMap; root.statusInitialized=true; root.replaceTransfers(next, false); root.ariaOnline=r.ok; root.errorText=r.ok ? "" : (r.error || "aria2 is unavailable")
      root.barLabel = root.activeCount ? "󰇚 " + root.activeCount + " " + root.humanSpeed(root.aggregateSpeed) : "󰇚"
    }}
  }
  Process { id: mediaDependencyProc; stdout: StdioCollector { waitForEnd: true; onStreamFinished: { var r=JSON.parse(text); if (!r.ok) root.errorText=r.error } } }
  Process { id: manifestVersionProc; stdout: StdioCollector { waitForEnd: true; onStreamFinished: { try { var data=JSON.parse(text); root.pluginVersion=String(data.version || "") } catch (e) { root.pluginVersion="" } } } }
  Process { id: mediaStatusProc; stdout: StdioCollector { waitForEnd: true; onStreamFinished: { var r=JSON.parse(text); var next=r.items || []; for (var i=0; i<next.length; i++) { var item=next[i], was=root.previousMediaStatus[item.gid]; if (root.mediaStatusInitialized && !was && item.status === "active") root.notify("Video download started", root.itemName(item), "low"); if (root.mediaStatusInitialized && was && was !== item.status && item.status === "complete") root.notify("Video download complete", root.itemName(item), "normal"); if (root.mediaStatusInitialized && was && was !== item.status && item.status === "error") root.notify("Video download failed", root.itemName(item) + ": " + (item.errorMessage || "yt-dlp error"), "critical") }; var statuses={}; for (var j=0; j<next.length; j++) statuses[next[j].gid]=next[j].status; root.previousMediaStatus=statuses; root.mediaStatusInitialized=true; root.replaceTransfers(next, true) } } }
  Process { id: mediaInspectProc; stdout: StdioCollector { waitForEnd: true; onStreamFinished: { var r=JSON.parse(text); if (!r.ok) { root.errorText=r.error; return }; if (!r.media) { root.addRawUrl(root.mediaUrl); return }; root.mediaTitle=r.title; root.mediaIsPlaylist=Boolean(r.playlist); root.mediaPlaylistCount=Number(r.entryCount || 0); root.mediaFormats=[{id:"best",label:"Highest available quality"},{id:"audio",label:"Audio only"}].concat(r.formats || []); root.selectedMediaFormat="best"; root.mediaPickerVisible=true } } }
  Process { id: mediaStartProc; stdout: StdioCollector { waitForEnd: true; onStreamFinished: { var r=JSON.parse(text); root.errorText=r.ok ? "" : r.error; root.mediaPickerVisible=false; root.refresh() } } }
  Process { id: mediaActionProc; stdout: StdioCollector { waitForEnd: true; onStreamFinished: { var r=JSON.parse(text); root.errorText=r.ok ? "" : r.error; root.refresh() } } }
  Process { id: addProc; stdout: StdioCollector { waitForEnd: true; onStreamFinished: { var r=JSON.parse(text); root.errorText=r.ok ? "" : r.error; root.refresh() } } }
  Process { id: actionProc; stdout: StdioCollector { waitForEnd: true; onStreamFinished: { var r=JSON.parse(text); root.errorText=r.ok ? "" : r.error; root.refresh() } } }
  Process { id: browserProc; stdout: StdioCollector { waitForEnd: true; onStreamFinished: { var r=JSON.parse(text); root.browserPayload=r.ok ? JSON.stringify(r.config, null, 2) : r.error } } }
  Process { id: ariaInfoProc; stdout: StdioCollector { waitForEnd: true; onStreamFinished: { var r=JSON.parse(text); if (r.ok) root.ariaInfo=r } } }
  Process { id: restartAriaProc; stdout: StdioCollector { waitForEnd: true; onStreamFinished: { var r=JSON.parse(text); root.restartingAria=false; root.errorText=r.ok ? "" : (r.error || "Could not restart aria2"); root.refresh(); root.refreshAriaInfo() } } }
  Process { id: autoStartProc; stdout: StdioCollector { waitForEnd: true; onStreamFinished: { var r=JSON.parse(text); root.errorText=r.ok ? "" : (r.error || "Could not change auto-start"); root.refreshAriaInfo() } } }
  Process { id: notifyProc }

  KeyboardPanel {
    id: panel
    anchorItem: root.anchorItem
    owner: root.hostWidget || root
    bar: root.bar
    open: root.opened
    focusTarget: keys
    contentWidth: panel.fittedContentWidth(Style.space(520))
    contentHeight: panel.fittedContentHeight(mainContent.measuredHeight)
    PanelKeyCatcher {
      id: keys
      anchors.fill: parent
      clip: true
      blocked: root.textInputActive
      onCloseRequested: { if (root.settingsVisible || root.detailsVisible) root.closeSettingsView(); else root.close() }
      onTabRequested: function(d) { if (root.settingsVisible) root.focusSettingsControl(d); else root.switchPanel(d) }
      onMoveRequested: function(dx, dy) {
        if (root.textInputActive || dy === 0) return
        if (root.settingsVisible) root.scrollSettings(dy * Style.space(42))
        else root.moveQueueSelection(dy)
      }
      onDeleteRequested: { if (!root.textInputActive && !root.settingsVisible && !root.detailsVisible) root.removeSelectedTransfer() }
      onActivateRequested: { if (root.settingsVisible) root.activateSettingsFocus() }
      onTextKey: function(text) {
        if (root.textInputActive) return
        if (root.shortcutsVisible) { if (text === "?" || text === "q") root.shortcutsVisible = false; return }
        if (text === "?") { root.shortcutsVisible = true; return }
        if (root.settingsVisible) {
          if (text === "q") root.closeSettingsView()
          else if (text === "g") settingsScroll.contentY = 0
          else if (text === "G") settingsScroll.contentY = Math.max(0, settingsScroll.contentHeight - settingsScroll.height)
          return
        }
        if (root.detailsVisible) return
        if (text === "a") { addField.forceActiveFocus(); return }
        if (text === "p") { root.toggleSelectedTransfer(); return }
        if (text === "r") { root.refresh(); return }
        if (text === "c") { root.clearFinished(); return }
        if (text === "s") { root.openSettings(); return }
      }
      Column {
        id: mainContent
        width: parent.width
        spacing: Style.space(10)
        property real measuredHeight: {
          var total = 0, visibleCount = 0
          for (var i = 0; i < children.length; i++) {
            if (children[i].visible) { total += children[i].height; visibleCount++ }
          }
          return total + Math.max(0, visibleCount - 1) * spacing
        }
        Item {
          width: parent.width; height: Style.space(50)
          Row {
            anchors.left: parent.left; anchors.top: parent.top; spacing: Style.space(8)
            Text { text: "󰇚"; color: root.accent; font.family: root.fontFamily; font.pixelSize: Style.font.title }
            Text { text: "Tugboat"; color: root.fg; font.family: root.fontFamily; font.pixelSize: Style.font.title; font.bold: true }
            Text { text: root.ariaOnline ? "● aria2 online" : "● aria2 offline"; color: root.ariaOnline ? root.accent : Color.urgent; font.family: root.fontFamily; font.pixelSize: Style.font.caption; anchors.verticalCenter: parent.verticalCenter }
          }
          Row {
            anchors.right: parent.right; anchors.top: parent.top; spacing: Style.space(4)
            Text { text: "↓ " + root.humanSpeed(root.aggregateSpeed); color: root.fg; font.family: root.fontFamily; font.bold: true }
            PanelActionButton { iconText: "󰒓"; tooltipText: "Settings"; onClicked: root.openSettings() }
          }
          Text { anchors.left: parent.left; anchors.bottom: parent.bottom; text: root.downloadCount + " download" + (root.downloadCount === 1 ? "" : "s") + " · " + root.pausedCount + " paused"; color: root.muted; font.family: root.fontFamily; font.pixelSize: Style.font.caption }
        }
        PanelSeparator { foreground: root.fg }
        Text { visible: root.errorText !== ""; width: parent.width; text: root.errorText; textFormat: Text.PlainText; color: Color.urgent; wrapMode: Text.WordWrap }
        Row {
          width: parent.width; spacing: Style.space(6)
          TextField { id: addField; width: parent.width - addButton.width - Style.space(6); placeholderText: "Paste URL, magnet, or cloud:remote:path"; onAccepted: root.addUrl(); Keys.onEscapePressed: root.close() }
          Button { id: addButton; iconText: "＋"; text: "Add"; onClicked: root.addUrl() }
        }
        Text { text: "Drop a .torrent anywhere in this panel"; color: root.muted; font.family: root.fontFamily; font.pixelSize: Style.font.caption }
        Rectangle {
          visible: root.mediaPickerVisible
          width: parent.width
          height: visible ? (root.mediaIsPlaylist ? Style.space(92) : Style.space(72)) : 0
          radius: Style.cornerRadius
          color: root.surface
          Column {
            anchors.fill: parent; anchors.margins: Style.space(8); spacing: Style.space(5)
            Text { width: parent.width; text: root.mediaTitle; textFormat: Text.PlainText; color: root.fg; elide: Text.ElideRight }
            Text { visible: root.mediaIsPlaylist; width: parent.width; text: root.mediaPlaylistCount + " videos · saves in a numbered playlist folder"; textFormat: Text.PlainText; color: root.muted; font.family: root.fontFamily; font.pixelSize: Style.font.caption; elide: Text.ElideRight }
            Row { spacing: Style.space(6)
              ComboBox { id: mediaFormatPicker; width: Style.space(210); model: root.mediaFormats; textRole: "label"; onActivated: root.selectedMediaFormat = root.mediaFormats[currentIndex].id }
              Button { text: "Download"; onClicked: root.startMedia() }
              Button { text: "Cancel"; onClicked: root.mediaPickerVisible=false }
            }
          }
        }
        PanelSeparator { foreground: root.fg }
        Row {
          width: parent.width; spacing: Style.space(5)
          PanelActionButton { enabled: root.downloadCount > 0; iconText: "󰏤"; tooltipText: "Pause all"; onClicked: root.doAction("pause-all") }
          PanelActionButton { enabled: root.downloadCount > 0; iconText: "󰐎"; tooltipText: "Resume all"; onClicked: root.resumeAll() }
          PanelActionButton { enabled: root.downloadCount > 0; iconText: "󰑐"; tooltipText: "Refresh queue"; onClicked: root.refresh() }
          Item { width: 1; height: 1 }
          Button { visible: root.clearableCount > 0; text: "Clear " + root.clearableCount; tooltipText: "Clear completed and failed items"; onClicked: root.clearFinished() }
        }
        PanelSeparator { foreground: root.fg }
        Flickable {
          id: queueScroll
          visible: queueModel.count > 0
          width: parent.width
          height: Math.min(queueList.implicitHeight, Style.space(300))
          contentWidth: width
          contentHeight: queueList.implicitHeight
          clip: true
          boundsBehavior: Flickable.StopAtBounds
          Column {
            id: queueList
            width: queueScroll.width
            spacing: Style.space(10)
            Repeater {
              id: queueRepeater
              model: queueModel
              delegate: BorderSurface {
            required property var payload
            property var modelData: payload
            width: queueList.width; height: Style.space(96); radius: Style.space(5)
            color: root.selectedGid === modelData.gid ? root.raisedSurface : root.surface
            borderSpec: root.selectedGid === modelData.gid ? Border.controlSpec("selected", root.fg, root.accent) : root.surfaceBorder
            Column { anchors.left: parent.left; anchors.right: actions.left; anchors.verticalCenter: parent.verticalCenter; anchors.margins: Style.space(10); spacing: Style.space(5)
              Row { width: parent.width; spacing: Style.space(7)
                Text { width: parent.width - typeBadge.implicitWidth - Style.space(7); text: root.itemName(modelData); textFormat: Text.PlainText; color: root.fg; elide: Text.ElideRight; font.bold: true }
                BorderSurface { id: typeBadge; implicitWidth: typeText.implicitWidth + Style.space(8); implicitHeight: typeText.implicitHeight + Style.space(3); radius: Style.space(3); color: root.raisedSurface
                  Text { id: typeText; anchors.centerIn: parent; text: root.typeLabel(modelData); color: root.muted; font.family: root.fontFamily; font.pixelSize: Style.font.caption; font.bold: true }
                }
              }
              Text { width: parent.width; text: root.itemMeta(modelData); textFormat: Text.PlainText; color: root.muted; font.family: root.fontFamily; font.pixelSize: Style.font.caption; elide: Text.ElideRight }
              Rectangle { width: parent.width; height: Style.space(5); radius: height / 2; color: root.raisedSurface
                Rectangle { width: parent.width * root.percent(modelData) / 100; height: parent.height; radius: parent.radius; color: root.accent }
              }
              Text { text: root.stateLabel(modelData); textFormat: Text.PlainText; color: modelData.status === "error" ? Color.urgent : root.muted; font.family: root.fontFamily; font.pixelSize: Style.font.caption; font.bold: true }
            }
            Row { id: actions; anchors.right: parent.right; anchors.rightMargin: Style.space(8); anchors.verticalCenter: parent.verticalCenter; spacing: Style.space(2)
              PanelActionButton {
                iconText: modelData.status === "active" ? "󰏤" : "󰐎"
                tooltipText: modelData.status === "active" ? "Pause download" : "Resume download"
                focusable: true
                onClicked: root.doAction(modelData.status === "active" ? "pause" : "resume", modelData.gid)
              }
              PanelActionButton { iconText: "⋯"; tooltipText: "More actions"; onClicked: transferMenu.open() }
              Menu {
                id: transferMenu
                MenuItem { text: "Open containing folder"; onTriggered: root.openFolder(modelData) }
                MenuItem { text: "Copy source URL"; onTriggered: root.copySource(modelData) }
                MenuItem { text: "Details"; onTriggered: { root.selectedTransfer = modelData; root.detailsVisible = true } }
                MenuSeparator {}
                MenuItem { text: "Remove from Tugboat"; onTriggered: root.doAction("remove", modelData.gid) }
              }
            }
          }
        }
          }
        }
        Column {
          visible: root.downloadCount === 0 && root.errorText === ""
          width: parent.width; spacing: Style.space(3)
          Text { text: "Nothing downloading"; color: root.fg; font.family: root.fontFamily; font.pixelSize: Style.font.body; font.bold: true }
          Text { text: "Paste a link, magnet, or drop a .torrent to get started."; color: root.muted; font.family: root.fontFamily; font.pixelSize: Style.font.caption; wrapMode: Text.WordWrap; width: parent.width }
        }
        PanelSeparator { foreground: root.fg }
        Item {
          width: parent.width; height: Style.space(24)
          Text { anchors.left: parent.left; anchors.verticalCenter: parent.verticalCenter; text: "Speed limit"; color: root.muted; font.family: root.fontFamily; font.pixelSize: Style.font.caption }
          Dropdown {
            anchors.right: parent.right; anchors.verticalCenter: parent.verticalCenter
            width: Style.space(168); showLabel: false; rowHeight: Style.space(24); popupRowHeight: Style.space(26)
            foreground: root.fg; background: Color.popups.background; fontFamily: root.fontFamily
            options: root.speedLimitOptions; value: root.speedLimitValue
            onChanged: function(value) { root.speedLimitValue = value; root.doAction("limit", value) }
          }
        }
        Text { text: "j/k select  s settings  ? help"; color: root.muted; font.family: root.fontFamily; font.pixelSize: Style.font.caption }
      }
      DropArea { anchors.fill: parent; z: 0; onDropped: function(drop) { if (drop.urls.length) root.addTorrent(root.pathFromUrl(drop.urls[0])) } }
      Rectangle {
        visible: root.settingsVisible || root.detailsVisible
        anchors.fill: parent; z: 5; color: Color.popups.background
        Item {
          anchors.fill: parent; anchors.margins: Style.space(14)
          Row {
            id: settingsHeader
            anchors.top: parent.top; width: parent.width; height: Style.space(28)
            Text { text: root.detailsVisible ? "Download details" : "Tugboat settings"; color: root.fg; font.family: root.fontFamily; font.pixelSize: Style.font.title; font.bold: true }
            Item { width: parent.width - closeSettings.width - parent.children[0].implicitWidth; height: 1 }
            PanelActionButton { id: closeSettings; iconText: "󰅖"; tooltipText: "Close"; onClicked: root.closeSettingsView() }
          }
          PanelSeparator { anchors.top: settingsHeader.bottom; foreground: root.fg }
          Flickable {
            id: settingsScroll
            anchors.top: settingsHeader.bottom; anchors.topMargin: Style.space(8)
            anchors.bottom: parent.bottom; anchors.left: parent.left; anchors.right: parent.right
            contentWidth: width; contentHeight: settingsContent.implicitHeight + Style.space(12)
            clip: true; interactive: true; flickableDirection: Flickable.VerticalFlick; boundsBehavior: Flickable.StopAtBounds
            WheelHandler {
              onWheel: function(event) {
                var delta = event.pixelDelta.y !== 0 ? event.pixelDelta.y : event.angleDelta.y / 120 * Style.space(36)
                root.scrollSettings(-delta)
                event.accepted = true
              }
            }
            Column {
              id: settingsContent
              x: Style.space(4); y: Style.space(6); width: parent.width - Style.space(8); spacing: Style.space(7)
              visible: root.settingsVisible
              PanelSectionHeader { text: "DOWNLOADS"; foreground: root.fg }
              Text { text: "Download directory"; color: root.fg; font.family: root.fontFamily; font.pixelSize: Style.font.body }
              Item { width: parent.width; height: Style.space(24)
                Text { anchors.left: parent.left; anchors.verticalCenter: parent.verticalCenter; text: settings && settings.downloadDirectory ? settings.downloadDirectory : "~/Downloads"; textFormat: Text.PlainText; color: root.muted; font.family: root.fontFamily; font.pixelSize: Style.font.caption; elide: Text.ElideMiddle; width: parent.width - openConfig.width - Style.space(8) }
                Button { id: openConfig; anchors.right: parent.right; anchors.verticalCenter: parent.verticalCenter; text: "Open config"; bordered: true; focusable: true; foreground: root.fg; fontFamily: root.fontFamily; fontSize: Style.font.caption; horizontalPadding: Style.space(6); verticalPadding: Style.space(3); onClicked: { root.settingsFocusIndex = 0; root.openPluginConfig() } }
              }
              Text { text: "Applies when aria2 is provisioned."; width: parent.width; wrapMode: Text.WordWrap; color: root.muted; font.family: root.fontFamily; font.pixelSize: Style.font.caption }
              PanelSeparator { foreground: root.fg }
              PanelSectionHeader { text: "CLOUD FOLDERS"; foreground: root.fg }
              Text { text: "Set up an rclone remote in a terminal, then add cloud:remote:path above. Example: cloud:onedrive:Shared/Folder."; width: parent.width; wrapMode: Text.WordWrap; color: root.muted; font.family: root.fontFamily; font.pixelSize: Style.font.caption }
              Button { id: rcloneConfigButton; text: "Configure rclone"; bordered: true; focusable: true; foreground: root.fg; fontFamily: root.fontFamily; fontSize: Style.font.caption; horizontalPadding: Style.space(6); verticalPadding: Style.space(3); onClicked: { root.settingsFocusIndex = 1; Quickshell.execDetached(["omarchy-launch-floating-terminal-with-presentation", "rclone config"]) } }
              PanelSeparator { foreground: root.fg }
              PanelSectionHeader { text: "ARIA2"; foreground: root.fg }
              Item { width: parent.width; height: Style.space(24)
                Text { anchors.left: parent.left; anchors.verticalCenter: parent.verticalCenter; text: "Status"; color: root.fg; font.family: root.fontFamily; font.pixelSize: Style.font.body }
                Text { anchors.right: parent.right; anchors.verticalCenter: parent.verticalCenter; text: root.ariaOnline ? "● Online" : "● Offline"; color: root.ariaOnline ? root.accent : Color.urgent; font.family: root.fontFamily; font.pixelSize: Style.font.caption }
              }
              Column { width: parent.width; spacing: Style.space(5)
                Item { width: parent.width; height: Style.space(24)
                  Text { anchors.left: parent.left; anchors.verticalCenter: parent.verticalCenter; text: "Start automatically"; color: root.fg; font.family: root.fontFamily; font.pixelSize: Style.font.body }
                  Button { id: autoStartButton; anchors.right: parent.right; anchors.verticalCenter: parent.verticalCenter; text: root.ariaInfo.autoStart ? "On" : "Off"; tooltipText: "Toggle aria2 session auto-start"; focusable: true; fontFamily: root.fontFamily; fontSize: Style.font.caption; horizontalPadding: Style.space(6); verticalPadding: Style.space(3); onClicked: { root.settingsFocusIndex = 2; root.setAutoStart(!root.ariaInfo.autoStart) } }
                }
                Item { width: parent.width; height: Style.space(24)
                  Button { id: restartAriaButton; anchors.right: parent.right; anchors.verticalCenter: parent.verticalCenter; iconText: "󰑐"; iconSpinning: root.restartingAria; text: root.restartingAria ? "Restarting aria2…" : "Restart aria2"; bordered: true; focusable: true; fontFamily: root.fontFamily; fontSize: Style.font.caption; horizontalPadding: Style.space(6); verticalPadding: Style.space(3); enabled: !root.restartingAria; opacity: root.restartingAria ? 0.5 : 1; onClicked: { root.settingsFocusIndex = 3; root.restartAria() } }
                }
              }
              Button { id: advancedButton; text: (root.advancedVisible ? "▾" : "▸") + " Advanced"; focusable: true; fontFamily: root.fontFamily; fontSize: Style.font.caption; horizontalPadding: Style.space(6); verticalPadding: Style.space(3); onClicked: { root.settingsFocusIndex = 4; root.advancedVisible = !root.advancedVisible } }
              Column { visible: root.advancedVisible; width: parent.width; spacing: Style.space(4)
                Item { width: parent.width; height: Style.space(22)
                  Text { anchors.left: parent.left; anchors.verticalCenter: parent.verticalCenter; text: "RPC port"; color: root.muted; font.family: root.fontFamily; font.pixelSize: Style.font.caption }
                  Text { anchors.right: parent.right; anchors.verticalCenter: parent.verticalCenter; text: root.ariaInfo.port || "—"; textFormat: Text.PlainText; color: root.muted; font.family: root.fontFamily; font.pixelSize: Style.font.caption }
                }
                Item { width: parent.width; height: Style.space(22)
                  Text { anchors.left: parent.left; anchors.verticalCenter: parent.verticalCenter; text: "RPC authentication"; color: root.muted; font.family: root.fontFamily; font.pixelSize: Style.font.caption }
                  Text { anchors.right: parent.right; anchors.verticalCenter: parent.verticalCenter; text: root.ariaInfo.authenticated ? "Enabled" : "Unavailable"; color: root.muted; font.family: root.fontFamily; font.pixelSize: Style.font.caption }
                }
              }
              PanelSeparator { foreground: root.fg }
              PanelSectionHeader { text: "BROWSER INTEGRATION"; foreground: root.fg }
              Item { width: parent.width; height: Style.space(28)
                Text { anchors.left: parent.left; anchors.verticalCenter: parent.verticalCenter; text: "Chromium browsers"; color: root.fg; font.family: root.fontFamily; font.pixelSize: Style.font.body }
                Button { id: chromeConnectButton; anchors.right: parent.right; anchors.verticalCenter: parent.verticalCenter; text: "Connect"; focusable: true; fontFamily: root.fontFamily; fontSize: Style.font.caption; horizontalPadding: Style.space(6); verticalPadding: Style.space(3); onClicked: { root.settingsFocusIndex = 5; root.connect("chrome") } }
              }
              Item { width: parent.width; height: Style.space(28)
                Text { anchors.left: parent.left; anchors.verticalCenter: parent.verticalCenter; text: "Firefox-based browsers"; color: root.fg; font.family: root.fontFamily; font.pixelSize: Style.font.body }
                Button { id: firefoxConnectButton; anchors.right: parent.right; anchors.verticalCenter: parent.verticalCenter; text: "Connect"; focusable: true; fontFamily: root.fontFamily; fontSize: Style.font.caption; horizontalPadding: Style.space(6); verticalPadding: Style.space(3); onClicked: { root.settingsFocusIndex = 6; root.connect("firefox") } }
              }
              Text { text: "Connect opens the extension store and local setup payload."; width: parent.width; wrapMode: Text.WordWrap; color: root.muted; font.family: root.fontFamily; font.pixelSize: Style.font.caption }
              TextArea { id: browserPayloadArea; visible: root.browserPayload !== ""; width: parent.width; height: visible ? Style.space(92) : 0; readOnly: true; text: root.browserPayload; textFormat: TextEdit.PlainText; wrapMode: TextEdit.WrapAnywhere; selectByMouse: true; Keys.onEscapePressed: root.closeSettingsView() }
              PanelSeparator { foreground: root.fg }
              PanelSectionHeader { text: "ABOUT"; foreground: root.fg }
              Text { text: root.pluginVersion ? "Tugboat " + root.pluginVersion : "Tugboat"; color: root.muted; font.family: root.fontFamily; font.pixelSize: Style.font.caption }
              Text { text: root.ariaInfo.version || "aria2"; textFormat: Text.PlainText; color: root.muted; font.family: root.fontFamily; font.pixelSize: Style.font.caption }
              Text { text: "j/k scroll  esc back  ? help"; color: root.muted; font.family: root.fontFamily; font.pixelSize: Style.font.caption }
              Item { width: 1; height: Style.space(24) }
            }
            TextArea { id: detailsArea; visible: root.detailsVisible; width: parent.width; height: visible ? Math.max(Style.space(240), implicitHeight) : 0; readOnly: true; text: root.selectedTransfer ? JSON.stringify(root.selectedTransfer, null, 2) : ""; textFormat: TextEdit.PlainText; wrapMode: TextEdit.WrapAnywhere; selectByMouse: true; Keys.onEscapePressed: root.closeSettingsView() }
            // Keep the wheel target above buttons and text controls. It does
            // not accept clicks, so normal Settings actions remain clickable.
            MouseArea {
              anchors.fill: parent
              z: 10
              acceptedButtons: Qt.NoButton
              onWheel: function(wheel) {
                var delta = wheel.pixelDelta.y !== 0 ? wheel.pixelDelta.y : wheel.angleDelta.y / 120 * Style.space(36)
                root.scrollSettings(-delta)
                wheel.accepted = true
              }
            }
          }
        }
      }
      BorderSurface {
        visible: root.shortcutsVisible
        z: 10
        anchors.centerIn: parent
        width: Math.min(parent.width - Style.space(32), Style.space(350))
        height: shortcutsText.implicitHeight + Style.space(24)
        radius: Style.space(5)
        color: Color.popups.background
        borderSpec: root.surfaceBorder
        Text {
          id: shortcutsText
          anchors.fill: parent
          anchors.margins: Style.space(12)
          text: root.settingsVisible
            ? "SHORTCUTS\n\nj / k   scroll down / up\ng / G   top / bottom\nTab     next action\nEnter   activate action\nEsc, q  back\n?       close help"
            : "SHORTCUTS\n\na       add link\nj / k   select download\np       pause / resume selected\nx       remove selected\nr       refresh\nc       clear finished\ns       settings\n?       close help"
          color: root.fg
          font.family: root.fontFamily
          font.pixelSize: Style.font.caption
          lineHeight: 1.3
        }
      }
    }
  }
}
