import QtQuick
import Quickshell
import Quickshell.Io
import Quickshell.Services.Mpris
import qs.Commons
import qs.Ui
import "Model.js" as Model

Panel {
  id: root
  moduleName: "cucu0628.dashboard"
  ipcTarget: "cucu0628.dashboard"
  manageIpc: false

  property var anchorItem: null
  property var hostWidget: null
  property int currentView: 0
  property date today: new Date()
  property int viewYear: today.getFullYear()
  property int viewMonth: today.getMonth()
  property real cpuUsage: 0
  property real memoryUsage: 0
  property real diskUsage: 0
  property var weather: null
  property var forecast: []
  property real latitude: NaN
  property real longitude: NaN
  property string weatherLocation: ""
  property real sampledPosition: 0
  property string selectedPlayerKey: ""
  property bool settingsOpen: false

  readonly property var barIdentity: hostWidget || root
  readonly property color foreground: bar ? bar.foreground : Color.foreground
  readonly property string fontFamily: bar ? bar.fontFamily : Style.font.family
  readonly property var players: Mpris.players ? Mpris.players.values : []
  readonly property var sourcePlayers: {
    var direct = []
    for (var i = 0; i < players.length; i++) {
      var candidate = players[i]
      if (candidate && String(candidate.dbusName || "").toLowerCase().indexOf("playerctld") === -1)
        direct.push(candidate)
    }
    return direct.length > 0 ? direct : players
  }
  readonly property var player: {
    for (var i = 0; i < sourcePlayers.length; i++)
      if (playerKey(sourcePlayers[i]) === selectedPlayerKey) return sourcePlayers[i]
    for (var j = 0; j < sourcePlayers.length; j++)
      if (sourcePlayers[j] && sourcePlayers[j].isPlaying) return sourcePlayers[j]
    return sourcePlayers.length > 0 ? sourcePlayers[0] : null
  }
  readonly property var sourceOptions: {
    var options = []
    for (var i = 0; i < sourcePlayers.length; i++) {
      var source = sourcePlayers[i]
      options.push({ value: playerKey(source), label: playerLabel(source) })
    }
    return options
  }
  readonly property real appVolume: player && player.volumeSupported ? player.volume : 0
  readonly property bool seekAvailable: player && player.canSeek && player.positionSupported
    && player.lengthSupported && player.length > 0
  readonly property real trackPosition: seekAvailable ? Math.max(0, Math.min(sampledPosition, player.length)) : 0
  readonly property real trackLength: seekAvailable ? player.length : 1
  readonly property var calendarCells: Model.monthCells(viewYear, viewMonth, today)

  onPlayerChanged: Qt.callLater(function() {
    root.sampledPosition = root.player && root.player.positionSupported ? root.player.position : 0
  })

  function open() {
    today = new Date()
    viewYear = today.getFullYear()
    viewMonth = today.getMonth()
    settingsOpen = false
    if (downloads.phase === "done" || downloads.phase === "error") downloads.reset()
    refreshSystem()
    weatherFile.reload()
    controller.show()
  }

  onCurrentViewChanged: if (currentView !== 1) settingsOpen = false

  // A blank field, or one matching what is already stored, means "no change".
  // TextField emits editingFinished on focus loss and on teardown as well as
  // after a real edit, so without this a panel being destroyed can commit an
  // empty value and overwrite the saved folder.
  function commitTargetDir(value) {
    var next = String(value || "").trim()
    if (next === "" || next === downloads.targetDir) {
      dirField.text = downloads.targetDir
      return
    }
    if (downloads.audioOnly) downloads.audioDir = next
    else downloads.videoDir = next
    downloads.saveSettings()
  }

  function close() { controller.hide() }
  function toggle() { opened ? close() : open() }

  function switchPanel(direction) {
    if (bar && typeof bar.switchPanelFrom === "function")
      return bar.switchPanelFrom(barIdentity, direction)
    return false
  }

  function moveMonth(delta) {
    var next = Model.stepMonth(viewYear, viewMonth, delta)
    viewYear = next.year
    viewMonth = next.month
  }

  function refreshSystem() {
    if (!systemProcess.running) systemProcess.running = true
  }

  function mediaAction(action) {
    if (!player) return
    if (action === "previous" && player.canGoPrevious) player.previous()
    else if (action === "next" && player.canGoNext) player.next()
    else if (action === "playPause") {
      if (player.isPlaying && player.canPause) player.pause()
      else if (!player.isPlaying && player.canPlay) player.play()
      else if (player.canTogglePlaying) player.togglePlaying()
    }
  }

  function playerKey(source) {
    if (!source) return ""
    return String(source.dbusName || source.desktopEntry || source.identity || "")
  }

  function playerLabel(source) {
    if (!source) return "Media source"
    var identity = String(source.identity || source.desktopEntry || "Media source")
    var title = String(source.trackTitle || "")
    return title && title !== identity ? identity + " - " + title : identity
  }

  function selectPlayer(key) {
    selectedPlayerKey = String(key || "")
  }

  function seekTo(value) {
    if (!seekAvailable || !player) return
    sampledPosition = Math.max(0, Math.min(Number(value), player.length))
    player.position = sampledPosition
  }

  function setAppVolume(value) {
    if (!player || !player.volumeSupported) return
    player.volume = Math.max(0, Math.min(1, Number(value)))
  }

  function formatDuration(seconds) {
    var value = Math.max(0, Math.floor(Number(seconds) || 0))
    var minutes = Math.floor(value / 60)
    var remainder = value % 60
    return minutes + ":" + (remainder < 10 ? "0" : "") + remainder
  }

  function loadWeather() {
    if (isNaN(latitude) || isNaN(longitude) || weatherProcess.running) return
    var url = "https://api.open-meteo.com/v1/forecast?latitude=" + encodeURIComponent(latitude)
      + "&longitude=" + encodeURIComponent(longitude)
      + "&current=temperature_2m,apparent_temperature,relative_humidity_2m,wind_speed_10m,weather_code,is_day"
      + "&daily=weather_code,temperature_2m_max,temperature_2m_min&forecast_days=5&timezone=auto"
    weatherProcess.command = ["curl", "-fsS", "--max-time", "8", url]
    weatherProcess.running = true
  }

  function parseWeatherLocation(raw) {
    try {
      var data = JSON.parse(String(raw || "{}"))
      latitude = Number(data.latitude)
      longitude = Number(data.longitude)
      weatherLocation = String(data.name || "")
      loadWeather()
    } catch (e) {}
  }

  component LabelText: Text {
    color: root.foreground
    font.family: root.fontFamily
    font.pixelSize: Style.font.body
  }

  component MutedText: Text {
    color: Qt.darker(root.foreground, 1.5)
    font.family: root.fontFamily
    font.pixelSize: Style.font.bodySmall
  }

  component Card: BorderSurface {
    color: Style.normalFillFor(root.foreground, Color.accent)
    borderSpec: Border.controlSpec("normal", root.foreground, Color.accent)
    radius: Style.cornerRadius
    padding: Style.space(14)
  }

  component SystemMetric: Item {
    property string label: ""
    property string icon: ""
    property real value: 0
    width: Style.space(210)
    height: Style.space(58)

    Row {
      anchors.left: parent.left
      anchors.right: parent.right
      topPadding: Style.space(2)
      spacing: Style.space(7)
      OpticalGlyph {
        width: Style.space(18)
        height: Style.space(18)
        anchors.verticalCenter: parent.verticalCenter
        text: icon
        color: root.foreground
        fontFamily: root.fontFamily
        fontSize: Style.font.title
      }
      MutedText { anchors.verticalCenter: parent.verticalCenter; text: label; font.letterSpacing: 1; font.bold: true }
      LabelText {
        anchors.verticalCenter: parent.verticalCenter
        width: parent.width - Style.space(80)
        horizontalAlignment: Text.AlignRight
        text: Math.round(value) + "%"
        font.pixelSize: Style.font.title
        font.bold: true
      }
    }

    Rectangle {
      anchors.left: parent.left
      anchors.right: parent.right
      anchors.bottom: parent.bottom
      height: Style.space(7)
      radius: Style.cornerRadius > 0 ? height / 2 : 0
      color: Qt.rgba(root.foreground.r, root.foreground.g, root.foreground.b, 0.12)
      Rectangle {
        width: parent.width * Math.max(0, Math.min(1, value / 100))
        height: parent.height
        radius: parent.radius
        color: Style.selectedStateColor(root.foreground, Color.accent)
        Behavior on width { NumberAnimation { duration: 250; easing.type: Easing.OutCubic } }
      }
    }
  }

  Download {
    id: downloads
    player: root.player
  }

  Timer {
    // Clear a finished download so the media view returns to normal on its own.
    // Failures stay put until dismissed — they carry yt-dlp's message.
    interval: 6000
    running: downloads.phase === "done"
    onTriggered: downloads.reset()
  }

  FileView {
    id: weatherFile
    path: Quickshell.env("HOME") + "/.local/state/omarchy/settings/weather.json"
    watchChanges: true
    printErrors: false
    onLoaded: root.parseWeatherLocation(text())
    onFileChanged: reload()
  }

  Process {
    id: systemProcess
    command: ["bash", "-lc", "read _ u n s i w irq sirq st _ < /proc/stat; t1=$((u+n+s+i+w+irq+sirq+st)); z1=$((i+w)); sleep 0.25; read _ u n s i w irq sirq st _ < /proc/stat; t2=$((u+n+s+i+w+irq+sirq+st)); z2=$((i+w)); cpu=$((100*((t2-t1)-(z2-z1))/(t2-t1))); mem=$(awk '/MemTotal/{t=$2}/MemAvailable/{a=$2}END{printf \"%.0f\",100*(t-a)/t}' /proc/meminfo); disk=$(df -P / | awk 'NR==2{gsub(/%/,\"\",$5);print $5}'); printf '%s %s %s\\n' \"$cpu\" \"$mem\" \"$disk\""]
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: {
        var values = String(text || "").trim().split(/\s+/)
        if (values.length < 3) return
        root.cpuUsage = Number(values[0])
        root.memoryUsage = Number(values[1])
        root.diskUsage = Number(values[2])
      }
    }
  }

  Process {
    id: weatherProcess
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: {
        try {
          var data = JSON.parse(String(text || "{}"))
          root.weather = data.current || null
          var days = []
          var daily = data.daily || {}
          for (var i = 0; daily.time && i < daily.time.length; i++) {
            days.push({
              date: daily.time[i],
              code: daily.weather_code[i],
              high: Math.round(daily.temperature_2m_max[i]),
              low: Math.round(daily.temperature_2m_min[i])
            })
          }
          root.forecast = days
        } catch (e) {}
      }
    }
  }

  Timer {
    interval: 3000
    running: root.opened
    repeat: true
    triggeredOnStart: true
    onTriggered: root.refreshSystem()
  }

  Timer {
    interval: 500
    running: root.opened && root.seekAvailable
    repeat: true
    triggeredOnStart: true
    onTriggered: {
      if (!seekSlider.dragging && !overviewSeekSlider.dragging && root.player)
        root.sampledPosition = root.player.position
    }
  }

  Timer {
    interval: 15 * 60 * 1000
    running: true
    repeat: true
    onTriggered: root.loadWeather()
  }

  SystemClock {
    precision: SystemClock.Minutes
    onDateChanged: root.today = date
  }

  KeyboardPanel {
    id: dashboardPanel
    anchorItem: root.anchorItem
    owner: root.barIdentity
    bar: root.bar
    open: root.opened
    centerOnBar: true
    focusTarget: keyCatcher
    contentWidth: dashboardPanel.fittedContentWidth(Style.space(760))
    contentHeight: dashboardPanel.fittedContentHeight(Style.space(520))

    PanelKeyCatcher {
      id: keyCatcher
      anchors.fill: parent
      // Let the directory field have every key, including the h/j/k/l this
      // catcher otherwise eats as navigation.
      blocked: dirField.activeFocus
      onCloseRequested: {
        if (root.settingsOpen) root.settingsOpen = false
        else if (downloads.phase === "confirm") downloads.dismiss()
        else root.close()
      }
      onReturnRequested: if (downloads.phase === "confirm") downloads.confirm()
      onTabRequested: function(direction) { root.switchPanel(direction) }

      Column {
        anchors.fill: parent
        spacing: Style.space(14)

        Row {
          id: tabs
          width: parent.width
          height: Style.space(34)
          spacing: Style.space(8)

          Repeater {
            model: ["OVERVIEW", "MEDIA", "WEATHER"]
            Rectangle {
              required property string modelData
              required property int index
              width: (tabs.width - tabs.spacing * 2) / 3
              height: tabs.height
              radius: Style.cornerRadius
              color: root.currentView === index
                ? Style.selectedFillFor(root.foreground, Color.accent)
                : (tabMouse.containsMouse ? Style.hoverFillFor(root.foreground, Color.accent) : "transparent")
              border.width: root.currentView === index ? Style.spacing.hairline : 0
              border.color: Style.selectedBorderFor(root.foreground, Color.accent)
              LabelText {
                anchors.centerIn: parent
                text: modelData
                font.pixelSize: Style.font.bodySmall
                font.bold: root.currentView === index
                font.letterSpacing: 1
              }
              MouseArea {
                id: tabMouse
                anchors.fill: parent
                hoverEnabled: true
                cursorShape: Qt.PointingHandCursor
                onClicked: root.currentView = index
              }
            }
          }
        }

        Rectangle {
          width: parent.width
          height: Style.spacing.hairline
          color: root.foreground
          opacity: 0.12
        }

        Item {
          width: parent.width
          height: parent.height - tabs.height - Style.space(29)

          Column {
            visible: root.currentView === 0
            anchors.fill: parent
            spacing: Style.space(14)

            Row {
              width: parent.width
              height: parent.height - Style.space(126)
              spacing: Style.space(14)

              Card {
                width: Style.space(450)
                height: parent.height

                Column {
                  anchors.fill: parent
                  anchors.margins: parent.contentLeftInset
                  spacing: Style.space(7)

                  Row {
                    width: parent.width
                    height: Style.space(42)
                    Column {
                      width: parent.width - monthNavigation.implicitWidth
                      spacing: Style.space(1)
                      LabelText {
                        text: Qt.formatDate(new Date(root.viewYear, root.viewMonth, 1), "MMMM yyyy")
                        font.pixelSize: Style.font.heading
                        font.bold: true
                      }
                      MutedText {
                        text: Qt.formatDate(root.today, "dddd, MMMM d").toUpperCase()
                        font.pixelSize: Style.font.caption
                        font.letterSpacing: 1
                      }
                    }
                    Row {
                      id: monthNavigation
                      anchors.verticalCenter: parent.verticalCenter
                      spacing: Style.space(2)
                      PanelActionButton {
                        size: Style.space(28)
                        iconText: "󰅁"
                        foreground: root.foreground
                        fontFamily: root.fontFamily
                        tooltipText: "Previous month"
                        onClicked: root.moveMonth(-1)
                      }
                      PanelActionButton {
                        size: Style.space(28)
                        iconText: "󰅂"
                        foreground: root.foreground
                        fontFamily: root.fontFamily
                        tooltipText: "Next month"
                        onClicked: root.moveMonth(1)
                      }
                    }
                  }

                  Grid {
                    width: parent.width
                    columns: 7
                    rowSpacing: Style.space(3)
                    columnSpacing: Style.space(3)
                    Repeater {
                      model: ["MON", "TUE", "WED", "THU", "FRI", "SAT", "SUN"]
                      MutedText {
                        required property string modelData
                        width: (parent.width - Style.space(18)) / 7
                        height: Style.space(20)
                        text: modelData
                        horizontalAlignment: Text.AlignHCenter
                        verticalAlignment: Text.AlignVCenter
                        font.pixelSize: Style.font.caption
                        font.letterSpacing: 1
                      }
                    }
                    Repeater {
                      model: root.calendarCells
                      Rectangle {
                        required property var modelData
                        width: (parent.width - Style.space(18)) / 7
                        height: Style.space(32)
                        radius: Style.cornerRadius
                        color: modelData.today ? Style.selectedFillFor(root.foreground, Color.accent) : "transparent"
                        border.width: modelData.today ? Style.spacing.hairline : 0
                        border.color: Style.selectedBorderFor(root.foreground, Color.accent)
                        LabelText {
                          anchors.centerIn: parent
                          text: modelData.day
                          color: modelData.inMonth
                            ? (modelData.weekend ? Qt.darker(root.foreground, 1.4) : root.foreground)
                            : Qt.darker(root.foreground, 2.1)
                          font.bold: modelData.today
                        }
                      }
                    }
                  }
                }
              }

              Card {
                width: parent.width - Style.space(464)
                height: parent.height
                Column {
                  anchors.fill: parent
                  anchors.margins: parent.contentLeftInset
                  spacing: Style.space(8)

                  MutedText {
                    width: parent.width
                    text: "NOW PLAYING"
                    horizontalAlignment: Text.AlignHCenter
                    font.letterSpacing: 1
                  }

                  BorderSurface {
                    width: Style.space(118)
                    height: Style.space(118)
                    anchors.horizontalCenter: parent.horizontalCenter
                    radius: Style.cornerRadius
                    color: Style.normalFillFor(root.foreground, Color.accent)
                    borderSpec: Border.controlSpec("normal", root.foreground, Color.accent)
                    Image {
                      id: overviewAlbumArt
                      anchors.fill: parent
                      anchors.margins: Style.space(2)
                      source: root.player && root.player.trackArtUrl ? root.player.trackArtUrl : ""
                      fillMode: Image.PreserveAspectCrop
                      visible: source !== ""
                      asynchronous: true
                    }
                    LabelText { anchors.centerIn: parent; visible: !overviewAlbumArt.visible; text: "󰝚"; font.pixelSize: 42 }
                  }

                  LabelText {
                    width: parent.width
                    text: root.player ? (root.player.trackTitle || "Unknown title") : "Nothing playing"
                    horizontalAlignment: Text.AlignHCenter
                    font.bold: true
                    elide: Text.ElideRight
                  }
                  MutedText {
                    width: parent.width
                    text: root.player ? (root.player.trackArtist || root.player.identity || "") : "Start a media player"
                    horizontalAlignment: Text.AlignHCenter
                    elide: Text.ElideRight
                  }
                  Column {
                    width: parent.width
                    spacing: Style.space(1)
                    MutedText {
                      width: parent.width
                      horizontalAlignment: Text.AlignRight
                      text: root.seekAvailable
                        ? root.formatDuration(overviewSeekSlider.dragging ? overviewSeekSlider.liveValue : root.trackPosition)
                          + " / " + root.formatDuration(root.trackLength)
                        : "--:-- / --:--"
                      font.pixelSize: Style.font.caption
                    }
                    PanelSlider {
                      id: overviewSeekSlider
                      width: parent.width
                      bar: root.bar
                      minimum: 0
                      maximum: root.trackLength
                      step: 5
                      knobSize: 0
                      value: root.trackPosition
                      enabled: root.seekAvailable
                      opacity: enabled ? 1 : 0.35
                      onReleased: function(value) { root.seekTo(value) }
                    }
                  }
                  Row {
                    anchors.horizontalCenter: parent.horizontalCenter
                    spacing: Style.space(10)
                    PanelActionButton { size: Style.space(34); fontSize: Style.font.icon; iconText: "󰒮"; foreground: root.foreground; fontFamily: root.fontFamily; enabled: root.player && root.player.canGoPrevious; onClicked: root.mediaAction("previous") }
                    PanelActionButton { size: Style.space(34); fontSize: Style.font.iconLarge; iconText: root.player && root.player.isPlaying ? "󰏤" : "󰐊"; foreground: root.foreground; fontFamily: root.fontFamily; enabled: !!root.player; onClicked: root.mediaAction("playPause") }
                    PanelActionButton { size: Style.space(34); fontSize: Style.font.icon; iconText: "󰒭"; foreground: root.foreground; fontFamily: root.fontFamily; enabled: root.player && root.player.canGoNext; onClicked: root.mediaAction("next") }
                  }
                }
              }
            }

            Card {
              width: parent.width
              height: Style.space(112)
              Column {
                anchors.fill: parent
                anchors.margins: parent.contentLeftInset
                spacing: Style.space(8)
                MutedText { text: "SYSTEM STATUS"; font.letterSpacing: 1 }
                Row {
                  width: parent.width
                  spacing: Style.space(24)
                  SystemMetric { width: (parent.width - parent.spacing * 2) / 3; label: "CPU"; icon: "󰍛"; value: root.cpuUsage }
                  SystemMetric { width: (parent.width - parent.spacing * 2) / 3; label: "MEMORY"; icon: "󰘚"; value: root.memoryUsage }
                  SystemMetric { width: (parent.width - parent.spacing * 2) / 3; label: "DISK"; icon: "󰋊"; value: root.diskUsage }
                }
              }
            }
          }

          Item {
            id: mediaView
            visible: root.currentView === 1
            anchors.fill: parent

            // Settings and confirmation take over the whole view rather than
            // pushing the player down: the panel's height is fixed, and the
            // media column already uses nearly all of it.
            readonly property bool overlayOpen: root.settingsOpen || downloads.phase === "confirm"

            Column {
              width: Math.min(parent.width, Style.space(560))
              anchors.centerIn: parent
              spacing: Style.space(10)
              visible: !mediaView.overlayOpen
              Column {
                visible: root.sourcePlayers.length > 1
                width: Math.min(parent.width, Style.space(430))
                height: visible ? Style.space(44) : 0
                anchors.horizontalCenter: parent.horizontalCenter
                spacing: Style.space(4)
                MutedText {
                  width: parent.width
                  text: "SOURCE"
                  font.pixelSize: Style.font.caption
                  font.letterSpacing: 1
                  horizontalAlignment: Text.AlignHCenter
                }
                Row {
                  id: sourceSelector
                  width: parent.width
                  height: Style.spacing.controlHeight
                  spacing: Style.space(5)
                  Repeater {
                    model: root.sourceOptions
                    BorderSurface {
                      id: sourceButton
                      required property var modelData
                      readonly property bool selected: root.playerKey(root.player) === String(modelData.value)
                      width: (sourceSelector.width - sourceSelector.spacing * Math.max(0, root.sourceOptions.length - 1))
                        / Math.max(1, root.sourceOptions.length)
                      height: sourceSelector.height
                      radius: Style.cornerRadius
                      color: selected
                        ? Style.selectedFillFor(root.foreground, Color.accent)
                        : (sourceMouse.containsMouse ? Style.hoverFillFor(root.foreground, Color.accent) : Style.normalFillFor(root.foreground, Color.accent))
                      borderSpec: Border.controlSpec(selected ? "selected" : (sourceMouse.containsMouse ? "hover-cursor" : "normal"), root.foreground, Color.accent)

                      LabelText {
                        anchors.fill: parent
                        anchors.leftMargin: sourceButton.contentLeftInset + Style.space(8)
                        anchors.rightMargin: sourceButton.contentRightInset + Style.space(8)
                        text: sourceButton.modelData.label
                        horizontalAlignment: Text.AlignHCenter
                        verticalAlignment: Text.AlignVCenter
                        font.pixelSize: Style.font.bodySmall
                        font.bold: sourceButton.selected
                        elide: Text.ElideRight
                      }

                      MouseArea {
                        id: sourceMouse
                        anchors.fill: parent
                        hoverEnabled: true
                        cursorShape: Qt.PointingHandCursor
                        onClicked: root.selectPlayer(sourceButton.modelData.value)
                      }
                    }
                  }
                }
              }
              BorderSurface {
                width: Style.space(160)
                height: Style.space(160)
                anchors.horizontalCenter: parent.horizontalCenter
                radius: Style.cornerRadius
                color: Style.normalFillFor(root.foreground, Color.accent)
                borderSpec: Border.controlSpec("normal", root.foreground, Color.accent)
                Image { id: mediaAlbumArt; anchors.fill: parent; anchors.margins: Style.space(3); source: root.player && root.player.trackArtUrl ? root.player.trackArtUrl : ""; fillMode: Image.PreserveAspectCrop; visible: source !== ""; asynchronous: true }
                LabelText { anchors.centerIn: parent; visible: !mediaAlbumArt.visible; text: "󰝚"; font.pixelSize: 56 }
              }
              Column {
                width: parent.width
                spacing: Style.space(4)
                LabelText { width: parent.width; text: root.player ? (root.player.trackTitle || "Unknown title") : "Nothing playing"; horizontalAlignment: Text.AlignHCenter; font.pixelSize: Style.font.heading; font.bold: true; elide: Text.ElideRight }
                MutedText { width: parent.width; text: root.player ? (root.player.trackArtist || root.player.identity || "") : "Start a media player"; horizontalAlignment: Text.AlignHCenter; font.pixelSize: Style.font.body; elide: Text.ElideRight }
                MutedText { width: parent.width; text: root.player ? (root.player.trackAlbum || "") : ""; horizontalAlignment: Text.AlignHCenter; visible: text !== ""; elide: Text.ElideRight }
              }
              Row {
                anchors.horizontalCenter: parent.horizontalCenter
                spacing: Style.space(14)
                PanelActionButton { size: Style.space(38); fontSize: Style.font.icon; iconText: "󰒮"; foreground: root.foreground; fontFamily: root.fontFamily; enabled: root.player && root.player.canGoPrevious; onClicked: root.mediaAction("previous") }
                PanelActionButton { size: Style.space(38); fontSize: Style.font.display; iconText: root.player && root.player.isPlaying ? "󰏤" : "󰐊"; foreground: root.foreground; fontFamily: root.fontFamily; enabled: !!root.player; onClicked: root.mediaAction("playPause") }
                PanelActionButton { size: Style.space(38); fontSize: Style.font.icon; iconText: "󰒭"; foreground: root.foreground; fontFamily: root.fontFamily; enabled: root.player && root.player.canGoNext; onClicked: root.mediaAction("next") }

                // Visual break between "control the player" and "act on the track".
                Item { width: Style.space(8); height: Style.space(1) }

                PanelActionButton {
                  size: Style.space(38)
                  fontSize: Style.font.icon
                  iconText: downloads.phase === "downloading" ? "󰜺" : "󰇚"
                  foreground: root.foreground
                  hoverColor: downloads.phase === "downloading" ? Color.urgent : root.foreground
                  fontFamily: root.fontFamily
                  // Stays clickable when the track cannot be resolved so the
                  // click can report why — a dead button explains nothing.
                  enabled: downloads.phase !== "probing"
                  opacity: downloads.target.ok || downloads.phase === "downloading" ? 1 : 0.45
                  tooltipText: downloads.phase === "downloading"
                    ? "Cancel download"
                    : downloads.target.ok
                      ? (downloads.audioOnly ? "Download audio" : "Download video")
                        + (downloads.target.kind === "search" ? " — matched by search" : "")
                      : downloads.target.reason
                  onClicked: downloads.phase === "downloading" ? downloads.cancelDownload() : downloads.start()
                }
                PanelActionButton {
                  size: Style.space(38)
                  fontSize: Style.font.icon
                  iconText: "󰒓"
                  tooltipText: "Download settings"
                  foreground: root.foreground
                  fontFamily: root.fontFamily
                  onClicked: root.settingsOpen = true
                }
              }

              // Only present while something is happening, so the resting
              // layout is unchanged.
              Column {
                width: parent.width
                spacing: Style.space(3)
                visible: downloads.phase !== "idle" && downloads.phase !== "confirm"

                Row {
                  width: parent.width
                  spacing: Style.space(8)
                  MutedText {
                    text: downloads.phase === "probing" ? "CHECKING"
                      : downloads.phase === "downloading" ? (downloads.audioOnly ? "DOWNLOADING AUDIO" : "DOWNLOADING VIDEO")
                      : downloads.phase === "done" ? "SAVED"
                      : "FAILED"
                    color: downloads.phase === "error" ? Color.urgent : Qt.darker(root.foreground, 1.5)
                    font.pixelSize: Style.font.caption
                    font.letterSpacing: 1
                  }
                  MutedText {
                    width: parent.width - Style.space(150)
                    horizontalAlignment: Text.AlignRight
                    elide: Text.ElideMiddle
                    font.pixelSize: Style.font.caption
                    text: {
                      if (downloads.phase === "downloading") {
                        var parts = [Math.round(downloads.percent) + "%"]
                        if (downloads.speed > 0) parts.push(downloads.formatBytes(downloads.speed) + "/s")
                        var eta = downloads.formatEta(downloads.eta)
                        if (eta !== "") parts.push("ETA " + eta)
                        return parts.join("   ")
                      }
                      if (downloads.phase === "done") return downloads.filePath
                      if (downloads.phase === "error") return downloads.errorText
                      return downloads.pendingLabel
                    }
                  }
                  PanelActionButton {
                    size: Style.space(16)
                    fontSize: Style.font.caption
                    iconText: "󰅖"
                    tooltipText: "Dismiss"
                    visible: downloads.phase === "done" || downloads.phase === "error"
                    foreground: root.foreground
                    fontFamily: root.fontFamily
                    onClicked: downloads.dismiss()
                  }
                }

                Rectangle {
                  width: parent.width
                  height: Style.space(4)
                  visible: downloads.phase === "downloading"
                  radius: Style.cornerRadius > 0 ? height / 2 : 0
                  color: Qt.rgba(root.foreground.r, root.foreground.g, root.foreground.b, 0.12)
                  Rectangle {
                    width: parent.width * Math.max(0, Math.min(1, downloads.percent / 100))
                    height: parent.height
                    radius: parent.radius
                    color: Style.selectedStateColor(root.foreground, Color.accent)
                    Behavior on width { NumberAnimation { duration: 250; easing.type: Easing.OutCubic } }
                  }
                }
              }

              Column {
                width: parent.width
                spacing: Style.space(2)
                Row {
                  width: parent.width
                  MutedText { text: "POSITION"; font.pixelSize: Style.font.caption; font.letterSpacing: 1 }
                  MutedText {
                    width: parent.width - Style.space(70)
                    horizontalAlignment: Text.AlignRight
                    text: root.formatDuration(seekSlider.dragging ? seekSlider.liveValue : root.trackPosition)
                      + " / " + root.formatDuration(root.seekAvailable ? root.trackLength : 0)
                    font.pixelSize: Style.font.caption
                  }
                }
                PanelSlider {
                  id: seekSlider
                  width: parent.width
                  bar: root.bar
                  minimum: 0
                  maximum: root.trackLength
                  step: 5
                  knobSize: 0
                  value: root.trackPosition
                  enabled: root.seekAvailable
                  opacity: enabled ? 1 : 0.35
                  onReleased: function(value) { root.seekTo(value) }
                }
              }

              Column {
                width: parent.width
                spacing: Style.space(2)
                Row {
                  width: parent.width
                  MutedText { text: "APP VOLUME"; font.pixelSize: Style.font.caption; font.letterSpacing: 1 }
                  MutedText {
                    width: parent.width - Style.space(88)
                    horizontalAlignment: Text.AlignRight
                    text: Math.round((volumeSlider.dragging ? volumeSlider.liveValue : root.appVolume) * 100) + "%"
                    font.pixelSize: Style.font.caption
                  }
                }
                PanelSlider {
                  id: volumeSlider
                  width: parent.width
                  bar: root.bar
                  minimum: 0
                  maximum: 1
                  step: 0.05
                  knobSize: 0
                  value: root.appVolume
                  enabled: !!root.player && root.player.volumeSupported
                  opacity: enabled ? 1 : 0.35
                  onMoved: function(value) { root.setAppVolume(value) }
                }
              }
            }

            Column {
              visible: root.settingsOpen
              width: Math.min(parent.width, Style.space(470))
              anchors.centerIn: parent
              spacing: Style.space(12)

              Row {
                width: parent.width
                spacing: Style.space(6)
                PanelActionButton {
                  size: Style.space(26)
                  anchors.verticalCenter: parent.verticalCenter
                  iconText: "󰅁"
                  tooltipText: "Back to player"
                  foreground: root.foreground
                  fontFamily: root.fontFamily
                  onClicked: root.settingsOpen = false
                }
                LabelText {
                  anchors.verticalCenter: parent.verticalCenter
                  text: "DOWNLOAD SETTINGS"
                  font.pixelSize: Style.font.bodySmall
                  font.bold: true
                  font.letterSpacing: 1
                }
              }

              PanelSeparator { foreground: root.foreground }

              Column {
                width: parent.width
                spacing: Style.space(6)
                PanelSectionHeader { text: "WHAT TO DOWNLOAD"; foreground: root.foreground; fontFamily: root.fontFamily }
                ButtonGroup {
                  width: parent.width
                  options: [{ value: "audio", label: "Audio only" }, { value: "video", label: "Audio + video" }]
                  value: downloads.audioOnly ? "audio" : "video"
                  foreground: root.foreground
                  accent: Color.accent
                  fontFamily: root.fontFamily
                  onChanged: function(mode) {
                    downloads.audioOnly = mode === "audio"
                    downloads.saveSettings()
                    // The folder field follows targetDir on its own.
                  }
                }
              }

              Column {
                width: parent.width
                spacing: Style.space(6)
                PanelSectionHeader {
                  text: downloads.audioOnly ? "AUDIO FOLDER" : "VIDEO FOLDER"
                  foreground: root.foreground
                  fontFamily: root.fontFamily
                }
                TextField {
                  id: dirField
                  width: parent.width
                  placeholderText: downloads.audioOnly ? "~/Music" : "~/Videos"
                  foreground: root.foreground
                  accent: Color.accent
                  font.family: root.fontFamily
                  // Each mode keeps its own folder. targetDir flips with the mode
                  // and also changes when the settings file loads or another
                  // monitor's panel edits it, so the field follows it whenever the
                  // user is not mid-edit. Binding `text` directly would not work:
                  // typing into a TextField breaks a declarative binding.
                  readonly property string storedDir: downloads.targetDir
                  onStoredDirChanged: if (!activeFocus) text = storedDir
                  onVisibleChanged: if (visible && !activeFocus) text = downloads.targetDir
                  Component.onCompleted: text = downloads.targetDir
                  onEditingFinished: root.commitTargetDir(text)
                  Keys.onEscapePressed: {
                    text = downloads.targetDir
                    focus = false
                  }
                }
                MutedText {
                  width: parent.width
                  text: "Saves to " + downloads.resolvedTargetDir
                  font.pixelSize: Style.font.caption
                  elide: Text.ElideMiddle
                }
              }

              Toggle {
                width: parent.width
                label: "Confirm before downloading"
                description: "Show what yt-dlp resolved and wait for approval. Off means downloads start on the first click, including matches found by search."
                checked: downloads.confirmFirst
                foreground: root.foreground
                accent: Color.accent
                fontFamily: root.fontFamily
                onClicked: {
                  downloads.confirmFirst = !downloads.confirmFirst
                  downloads.saveSettings()
                }
              }

              PanelSeparator { foreground: root.foreground }

              Column {
                width: parent.width
                spacing: Style.space(5)
                PanelSectionHeader { text: "YT-DLP"; foreground: root.foreground; fontFamily: root.fontFamily }
                Row {
                  width: parent.width
                  spacing: Style.space(8)
                  Column {
                    width: parent.width - Style.space(96)
                    anchors.verticalCenter: parent.verticalCenter
                    spacing: Style.space(1)
                    LabelText {
                      width: parent.width
                      text: downloads.ytdlpVersion !== "" ? downloads.ytdlpVersion : "checking…"
                      font.pixelSize: Style.font.bodySmall
                      font.bold: true
                    }
                    MutedText {
                      width: parent.width
                      text: downloads.ytdlpBinary
                      font.pixelSize: Style.font.caption
                      elide: Text.ElideMiddle
                    }
                  }
                  Button {
                    anchors.verticalCenter: parent.verticalCenter
                    text: downloads.updating ? "…" : "Update"
                    bordered: true
                    foreground: root.foreground
                    accent: Color.accent
                    fontFamily: root.fontFamily
                    // A packaged build refuses to self-update; the result line
                    // below reports that rather than the button hiding it.
                    enabled: !downloads.updating && !downloads.busy
                    opacity: enabled ? 1 : 0.45
                    onClicked: downloads.updateBinary()
                  }
                }
                MutedText {
                  width: parent.width
                  visible: downloads.updateResult !== ""
                  text: downloads.updateResult
                  wrapMode: Text.WordWrap
                  font.pixelSize: Style.font.caption
                }
              }
            }

            Column {
              visible: downloads.phase === "confirm"
              width: Math.min(parent.width, Style.space(490))
              anchors.centerIn: parent
              spacing: Style.space(10)

              MutedText {
                width: parent.width
                text: downloads.audioOnly ? "DOWNLOAD AUDIO?" : "DOWNLOAD AUDIO + VIDEO?"
                horizontalAlignment: Text.AlignHCenter
                font.pixelSize: Style.font.caption
                font.letterSpacing: 1
              }

              Card {
                width: parent.width
                height: confirmDetails.implicitHeight + Style.space(28)
                Column {
                  id: confirmDetails
                  anchors.left: parent.left
                  anchors.right: parent.right
                  anchors.verticalCenter: parent.verticalCenter
                  anchors.leftMargin: parent.contentLeftInset
                  anchors.rightMargin: parent.contentRightInset
                  spacing: Style.space(4)

                  LabelText {
                    width: parent.width
                    text: downloads.probeTitle !== "" ? downloads.probeTitle : downloads.pendingLabel
                    font.bold: true
                    wrapMode: Text.WordWrap
                    maximumLineCount: 2
                    elide: Text.ElideRight
                  }
                  MutedText {
                    width: parent.width
                    visible: text !== ""
                    text: downloads.probeUploader
                    font.pixelSize: Style.font.bodySmall
                    elide: Text.ElideRight
                  }
                  MutedText {
                    width: parent.width
                    visible: text !== ""
                    font.pixelSize: Style.font.caption
                    text: [downloads.probeDuration,
                           downloads.audioOnly ? "" : downloads.probeResolution,
                           downloads.probeSize].filter(function(part) { return String(part) !== "" }).join("   ·   ")
                  }
                  MutedText {
                    width: parent.width
                    visible: text !== ""
                    text: downloads.probeUrl !== "" ? downloads.probeUrl : downloads.pendingUrl
                    font.pixelSize: Style.font.caption
                    elide: Text.ElideMiddle
                  }
                }
              }

              MutedText {
                width: parent.width
                visible: downloads.pendingKind === "search"
                color: Color.urgent
                wrapMode: Text.WordWrap
                font.pixelSize: Style.font.caption
                // Brave and every other Chromium browser publish no URL over
                // MPRIS, so this is the best guess from the track tags.
                text: "No address from the player — found by searching “" + downloads.pendingLabel + "”. Check it is the right one."
              }
              MutedText {
                width: parent.width
                visible: downloads.playlistCount > 1
                wrapMode: Text.WordWrap
                font.pixelSize: Style.font.caption
                text: "This is item 1 of a " + downloads.playlistCount + "-item playlist. Only this one will be fetched."
              }
              MutedText {
                width: parent.width
                visible: downloads.probeIsLive
                color: Color.urgent
                wrapMode: Text.WordWrap
                font.pixelSize: Style.font.caption
                text: "Live stream — the download keeps running until you cancel it."
              }
              MutedText {
                width: parent.width
                horizontalAlignment: Text.AlignHCenter
                font.pixelSize: Style.font.caption
                text: "→ " + downloads.resolvedTargetDir
                elide: Text.ElideMiddle
              }

              Row {
                anchors.horizontalCenter: parent.horizontalCenter
                spacing: Style.space(10)
                Button {
                  iconText: "󰇚"
                  text: "Download"
                  bordered: true
                  foreground: root.foreground
                  accent: Color.accent
                  fontFamily: root.fontFamily
                  onClicked: downloads.confirm()
                }
                Button {
                  text: "Cancel"
                  bordered: true
                  foreground: root.foreground
                  accent: Color.accent
                  fontFamily: root.fontFamily
                  onClicked: downloads.dismiss()
                }
              }
            }
          }

          Item {
            visible: root.currentView === 2
            anchors.fill: parent
            Column {
              width: Math.min(parent.width, Style.space(650))
              anchors.centerIn: parent
              spacing: Style.space(28)
              Row {
                anchors.horizontalCenter: parent.horizontalCenter
                spacing: Style.space(28)
                LabelText { text: root.weather ? Model.weatherIcon(root.weather.weather_code, root.weather.is_day) : "󰖐"; font.pixelSize: 86; anchors.verticalCenter: parent.verticalCenter }
                Column {
                  anchors.verticalCenter: parent.verticalCenter
                  spacing: Style.space(5)
                  LabelText { text: root.weather ? Math.round(root.weather.temperature_2m) + "°C" : "--°C"; font.pixelSize: 56; font.bold: true }
                  MutedText { text: root.weatherLocation.toUpperCase(); font.letterSpacing: 1 }
                }
              }
              Row {
                anchors.horizontalCenter: parent.horizontalCenter
                spacing: Style.space(56)
                Column {
                  spacing: Style.space(4)
                  MutedText { text: "FEELS"; font.letterSpacing: 1 }
                  LabelText { text: root.weather ? Math.round(root.weather.apparent_temperature) + "°C" : "--"; font.pixelSize: Style.font.title }
                }
                Column {
                  spacing: Style.space(4)
                  MutedText { text: "WIND"; font.letterSpacing: 1 }
                  LabelText { text: root.weather ? Math.round(root.weather.wind_speed_10m) + " km/h" : "--"; font.pixelSize: Style.font.title }
                }
                Column {
                  spacing: Style.space(4)
                  MutedText { text: "HUMIDITY"; font.letterSpacing: 1 }
                  LabelText { text: root.weather ? Math.round(root.weather.relative_humidity_2m) + "%" : "--"; font.pixelSize: Style.font.title }
                }
              }
              Rectangle { width: parent.width; height: Style.spacing.hairline; color: root.foreground; opacity: 0.12 }
              Row {
                width: parent.width
                spacing: Style.space(8)
                Repeater {
                  model: root.forecast
                  Card {
                    required property var modelData
                    width: (parent.width - parent.spacing * Math.max(0, root.forecast.length - 1)) / Math.max(1, root.forecast.length)
                    height: Style.space(135)
                    Column {
                      anchors.centerIn: parent
                      spacing: Style.space(8)
                      MutedText { anchors.horizontalCenter: parent.horizontalCenter; text: Model.dayLabel(modelData.date); font.letterSpacing: 1 }
                      LabelText { anchors.horizontalCenter: parent.horizontalCenter; text: Model.weatherIcon(modelData.code, 1); font.pixelSize: Style.font.displayLarge }
                      Row {
                        anchors.horizontalCenter: parent.horizontalCenter
                        spacing: Style.space(7)
                        LabelText { text: modelData.high + "°"; font.bold: true }
                        MutedText { text: modelData.low + "°" }
                      }
                    }
                  }
                }
              }
            }
          }
        }
      }
    }
  }
}
