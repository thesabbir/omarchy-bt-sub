import QtQuick
import Quickshell
import Quickshell.Io
import Quickshell.Services.Pipewire
import qs.Commons
import qs.Commons as Commons
import qs.Ui

// Bluetooth speaker as subwoofer (driven by the bundled bin/bt-sub).
// Left click: panel (on/off, volume, bass level, delay, crossover).
// Right click: quick on/off. Scroll: bass level.
// Shown only while a Bluetooth speaker is connected or the sub is on.
Panel {
  id: root
  moduleName: "sabbir.bt-sub"
  ipcTarget: "sabbir.bt-sub"

  readonly property string script: decodeURIComponent(Qt.resolvedUrl("bin/bt-sub").toString().replace(/^file:\/\//, ""))
  readonly property var nodes: Pipewire.nodes ? Pipewire.nodes.values : []

  function findNode(pred) {
    for (var i = 0; i < nodes.length; i++)
      if (nodes[i] && pred(nodes[i])) return nodes[i]
    return null
  }

  readonly property var subSink: findNode(function(n) { return n.name === "bt_sub" })
  readonly property var btSink: findNode(function(n) {
    return n.isSink && !n.isStream && String(n.name).indexOf("bluez_output.") === 0
  })
  readonly property bool subOn: subSink !== null
  readonly property string speaker: btSink ? String(btSink.description || btSink.nickname || "Bluetooth speaker") : ""
  // Device names come from the device; keep markup out of Omarchy's tooltip.
  readonly property string speakerSafe: speaker.replace(/[<>&]/g, "")

  readonly property real masterVolume: subSink && subSink.audio ? subSink.audio.volume : 0
  readonly property bool masterMuted: subSink && subSink.audio ? subSink.audio.muted : false
  readonly property real bassVolume: btSink && btSink.audio ? btSink.audio.volume : 0
  readonly property bool bassMuted: btSink && btSink.audio ? btSink.audio.muted : false

  property real delay: 0.2
  property int crossover: 200
  property bool busy: false
  property bool calibrating: false

  PwObjectTracker { objects: [root.subSink, root.btSink].filter(function(n) { return n !== null }) }

  function pct(v) { return Math.round(v * 100) + "%" }
  function setVolume(node, v) {
    if (node && node.audio) node.audio.volume = Math.max(0, Math.min(1, v))
  }
  function toggleSub() {
    if (toggleProc.running) return
    busy = true
    toggleProc.running = true
  }
  function refreshSettings() { if (!settingsProc.running) settingsProc.running = true }

  onOpenedChanged: if (opened) refreshSettings()

  Process {
    id: toggleProc
    command: [root.script, "toggle"]
    onExited: root.busy = false
  }

  Process {
    id: calibrateProc
    command: [root.script, "calibrate"]
    onExited: { root.calibrating = false; root.refreshSettings() }
  }

  Process {
    id: settingsProc
    command: ["sh", "-c", "\"$0\" delay; \"$0\" crossover", root.script]
    stdout: StdioCollector {
      onStreamFinished: {
        var lines = String(text).trim().split("\n")
        var d = parseFloat(lines[0]), c = parseInt(lines[1])
        if (!isNaN(d)) root.delay = d
        if (!isNaN(c)) root.crossover = c
      }
    }
  }

  // Debounce slider drags into one bt-sub call.
  Timer {
    id: delayApply
    interval: 120
    onTriggered: Quickshell.execDetached([root.script, "delay", root.delay.toFixed(3)])
  }
  Timer {
    id: crossoverApply
    interval: 120
    onTriggered: Quickshell.execDetached([root.script, "crossover", String(root.crossover)])
  }

  visible: subOn || btSink !== null
  implicitWidth: button.implicitWidth
  implicitHeight: button.implicitHeight

  BarIconButton {
    id: button
    anchors.fill: parent
    bar: root.bar
    text: root.subOn ? "󰓃" : "󰓄"
    active: root.subOn
    activeColor: Color.accent
    dimmed: !root.subOn
    tooltipText: root.opened ? "" : (root.subOn
      ? "BT Sub on (" + root.speakerSafe + ") · bass " + root.pct(root.bassVolume)
      : "BT Sub off")
    onPressed: function(b) {
      if (b === Qt.RightButton) root.toggleSub()
      else root.toggle()
    }
    onWheelMoved: function(delta) {
      root.setVolume(root.btSink, root.bassVolume + (delta > 0 ? 0.05 : -0.05))
    }
  }

  component Label: Text {
    textFormat: Text.PlainText
    color: root.bar ? root.bar.foreground : Commons.Color.foreground
    font.family: root.bar ? root.bar.fontFamily : Style.font.family
    font.pixelSize: Style.font.body
    elide: Text.ElideRight
  }

  component Section: Column {
    id: section
    property string title
    property string value
    width: parent.width
    spacing: Style.space(6)
    Item {
      width: parent.width
      height: header.implicitHeight
      PanelSectionHeader {
        id: header
        text: section.title
        foreground: root.bar.foreground
        fontFamily: root.bar.fontFamily
      }
      PanelSectionHeader {
        anchors.right: parent.right
        text: section.value
        foreground: root.bar.foreground
        fontFamily: root.bar.fontFamily
      }
    }
  }

  KeyboardPanel {
    id: panel
    anchorItem: button
    owner: root
    bar: root.bar
    open: root.opened
    focusTarget: panel.loadedContent
    contentWidth: panel.fittedContentWidth(Style.space(320))
    contentHeight: panel.fittedContentHeight(panel.loadedContentHeight)

    content: PanelKeyCatcher {
      anchors.fill: parent
      implicitHeight: column.implicitHeight
      onCloseRequested: root.close()
      onTabRequested: function(direction) { root.switchPanel(direction) }

      Column {
        id: column
        anchors.left: parent.left
        anchors.right: parent.right
        anchors.top: parent.top
        spacing: Style.space(14)

        Item {
          width: parent.width
          height: Math.max(titleCol.implicitHeight, powerSwitch.implicitHeight)
          Column {
            id: titleCol
            anchors.left: parent.left
            anchors.right: powerSwitch.left
            anchors.rightMargin: Style.space(10)
            anchors.verticalCenter: parent.verticalCenter
            spacing: Style.space(2)
            Label { width: parent.width; text: "Bluetooth Subwoofer"; font.bold: true }
            Label {
              width: parent.width
              opacity: 0.6
              font.pixelSize: Style.font.bodySmall
              text: root.speaker !== "" ? root.speaker : "No Bluetooth speaker connected"
            }
          }
          ToggleSwitch {
            id: powerSwitch
            anchors.right: parent.right
            anchors.verticalCenter: parent.verticalCenter
            checked: root.subOn
            busy: root.busy
            interactive: !root.busy && (root.subOn || root.btSink !== null)
            foreground: root.bar.foreground
            onToggled: root.toggleSub()
          }
        }

        Section {
          title: "Volume"
          value: root.subOn ? (root.masterMuted ? "Muted" : root.pct(root.masterVolume)) : "—"
          opacity: root.subOn ? 1 : 0.5
          PanelSlider {
            bar: root.bar
            width: parent.width
            value: root.masterVolume
            enabled: root.subOn
            opacity: root.masterMuted ? 0.5 : 1
            onMoved: function(v) { root.setVolume(root.subSink, v) }
            onRightClicked: if (root.subSink && root.subSink.audio) root.subSink.audio.muted = !root.masterMuted
          }
        }

        Section {
          title: "Bass level"
          value: root.btSink ? (root.bassMuted ? "Muted" : root.pct(root.bassVolume)) : "—"
          opacity: root.btSink ? 1 : 0.5
          PanelSlider {
            bar: root.bar
            width: parent.width
            value: root.bassVolume
            enabled: root.btSink !== null
            opacity: root.bassMuted ? 0.5 : 1
            onMoved: function(v) { root.setVolume(root.btSink, v) }
            onRightClicked: if (root.btSink && root.btSink.audio) root.btSink.audio.muted = !root.bassMuted
          }
        }

        Section {
          title: "Delay (sync)"
          value: Math.round(root.delay * 1000) + " ms"
          PanelSlider {
            bar: root.bar
            width: parent.width
            minimum: 0
            maximum: 0.5
            step: 0.005
            value: root.delay
            onMoved: function(v) { root.delay = Math.round(v * 200) / 200; delayApply.restart() }
          }
          Button {
            width: parent.width
            text: root.calibrating ? "Listening…" : "Auto-sync with microphone"
            iconText: "󰍬"
            bordered: true
            enabled: root.subOn && !root.calibrating
            opacity: enabled ? 1 : 0.5
            foreground: root.bar.foreground
            fontFamily: root.bar.fontFamily
            fontSize: Style.font.bodySmall
            onClicked: { root.calibrating = true; calibrateProc.running = true }
          }
        }

        Section {
          title: "Crossover"
          value: root.crossover + " Hz"
          PanelSlider {
            bar: root.bar
            width: parent.width
            minimum: 50
            maximum: 200
            step: 5
            value: root.crossover
            onMoved: function(v) { root.crossover = Math.round(v / 5) * 5; crossoverApply.restart() }
          }
        }
      }
    }
  }
}
