import QtQuick
import QtQuick.Layouts
import Quickshell
import Quickshell.Wayland
import qs.services
import qs.components

// ============================================================================
//  RecorderPanel — what to record. Opened by the recorder shortcut
//  (Super+Shift+V by default; Super+Shift+R before 3.0), the launcher entry or Settings.
//
//  Lives behind a LazyLoader in shell.qml (active = Panels.recorder AND the
//  Screen recording switch): while closed there is no window and no object.
//  Opens on the FOCUSED monitor via Panels.openScreen, like the calculator.
//
//  One tile per monitor plus "Region". A monitor tile starts recording that
//  monitor at once; Region hands over to the screenshot selector in record
//  mode (Panels.recordRegion), whose result comes back through
//  Panels.regionPicked. While a recording runs the card shows it and offers
//  Stop instead. Keyboard: ←/→ (or Tab) choose, Enter records, R = region,
//  Esc closes.
// ============================================================================
PanelWindow {
    id: win
    screen: Panels.openScreen
    WlrLayershell.namespace: "vexyon-recorder"
    WlrLayershell.layer: WlrLayer.Overlay
    WlrLayershell.keyboardFocus: WlrKeyboardFocus.Exclusive
    color: "transparent"
    anchors { top: true; bottom: true; left: true; right: true }

    property bool shown: false
    readonly property var screensList: Quickshell.screens
    readonly property int tileCount: win.screensList.length + 1     // + Region
    property string focusedName: ""
    property int sel: 0

    Component.onCompleted: {
        win.focusedName = Recorder.focusedOutput();
        for (var i = 0; i < win.screensList.length; i++)
            if (win.screensList[i].name === win.focusedName) win.sel = i;
        Recorder.prime();
        Time.ssWatchers++;             // elapsed time while a recording runs
        win.shown = true;
        keyScope.forceActiveFocus();
    }
    Component.onDestruction: Time.ssWatchers--

    function close() { Panels.close("recorder"); }
    function activate(i) {
        if (!Recorder.ready || Recorder.recording) return;
        if (i < win.screensList.length) {
            var name = win.screensList[i].name;
            Recorder.startOutput(name);
            win.close();
        } else {
            win.close();
            Panels.recordRegion = true;
        }
    }
    function stopNow() { Recorder.stop(); win.close(); }

    // ---- surface -----------------------------------------------------------
    Rectangle {
        anchors.fill: parent
        color: Qt.rgba(0, 0, 0, 0.35)
        opacity: win.shown ? 1 : 0
        Behavior on opacity { NumberAnimation { duration: Theme.dur(140) } }
        MouseArea { anchors.fill: parent; onClicked: win.close() }
    }

    FocusScope {
        id: keyScope
        anchors.fill: parent
        focus: true
        Keys.onPressed: function(e) {
            if (e.key === Qt.Key_Escape) win.close();
            else if (Recorder.recording) {
                if (e.key === Qt.Key_Return || e.key === Qt.Key_Enter) win.stopNow();
                else return;
            }
            else if (e.key === Qt.Key_Return || e.key === Qt.Key_Enter) win.activate(win.sel);
            else if (e.key === Qt.Key_Right || e.key === Qt.Key_Down || e.key === Qt.Key_Tab)
                win.sel = (win.sel + 1) % win.tileCount;
            else if (e.key === Qt.Key_Left || e.key === Qt.Key_Up || e.key === Qt.Key_Backtab)
                win.sel = (win.sel + win.tileCount - 1) % win.tileCount;
            else if (e.key === Qt.Key_R) win.activate(win.tileCount - 1);
            else return;
            e.accepted = true;
        }

        Card {
            id: card
            anchors.centerIn: parent
            // room for every tile on one row (132 px + 8 px gap each), within the screen
            width: Math.min(parent.width - 40, Math.max(440, win.tileCount * 140 - 8 + 32))
            height: col.implicitHeight + 32
            opacity: win.shown ? 1 : 0
            scale: win.shown ? 1 : 0.94
            Behavior on opacity { NumberAnimation { duration: Theme.dur(160); easing.type: Theme.easing } }
            Behavior on scale { NumberAnimation { duration: Theme.dur(160); easing.type: Theme.easing } }
            // clicks on the card must not reach the close-on-outside backdrop
            MouseArea { anchors.fill: parent }

            ColumnLayout {
                id: col
                anchors.left: parent.left
                anchors.right: parent.right
                anchors.top: parent.top
                anchors.margins: 16
                spacing: 12

                RowLayout {
                    Layout.fillWidth: true
                    spacing: 10
                    Text {
                        text: Icons.record
                        color: Theme.red
                        font.family: Theme.fontFamily
                        font.pixelSize: Theme.fontSize
                    }
                    Text {
                        Layout.fillWidth: true
                        text: I18n.t("Screen recording")
                        color: Theme.text
                        font.family: Theme.fontFamily
                        font.pixelSize: Theme.fontSize + 1
                        font.bold: true
                    }
                    IconButton {
                        icon: Icons.close
                        iconColor: Theme.subtext0
                        iconSize: Theme.fontSize - 1
                        implicitWidth: 26; implicitHeight: 26
                        onClicked: win.close()
                    }
                }

                // ---------- still probing ----------
                Text {
                    visible: !Recorder.detected
                    text: I18n.t("Checking…")
                    color: Theme.subtext0
                    font.family: Theme.fontFamily
                    font.pixelSize: Theme.fontSize - 1
                }

                // ---------- backend missing ----------
                ColumnLayout {
                    Layout.fillWidth: true
                    visible: Recorder.detected && !Recorder.ready
                    spacing: 10
                    Text {
                        Layout.fillWidth: true
                        text: I18n.t("wf-recorder is not installed, so nothing can be recorded yet. Settings → Screen recording shows how to install it on this system.")
                        color: Theme.text
                        wrapMode: Text.Wrap
                        font.family: Theme.fontFamily
                        font.pixelSize: Theme.fontSize - 1
                    }
                    PanelButton {
                        label: I18n.t("Open Settings")
                        onClicked: { win.close(); Panels.openSettingsAt("recording"); }
                    }
                }

                // ---------- recording in progress ----------
                ColumnLayout {
                    Layout.fillWidth: true
                    visible: Recorder.recording
                    spacing: 10
                    RowLayout {
                        Layout.fillWidth: true
                        spacing: 10
                        Text {
                            text: Icons.record
                            color: Theme.red
                            font.family: Theme.fontFamily
                            font.pixelSize: Theme.fontSize - 2
                        }
                        Text {
                            Layout.fillWidth: true
                            text: (Recorder.stopping ? I18n.t("Saving…") : I18n.t("Recording in progress"))
                                  + "  ·  " + Recorder.target
                            color: Theme.text
                            elide: Text.ElideRight
                            font.family: Theme.fontFamily
                            font.pixelSize: Theme.fontSize - 1
                        }
                        Text {
                            text: Recorder.elapsed(Time.now.getTime())
                            color: Theme.text
                            font.family: Theme.fontFamily
                            font.pixelSize: Theme.fontSize
                            font.bold: true
                        }
                    }
                    PanelButton {
                        label: Icons.stop + "  " + I18n.t("Stop recording")
                        danger: true
                        enabled: !Recorder.stopping
                        onClicked: win.stopNow()
                    }
                }

                // ---------- choose what to record ----------
                ColumnLayout {
                    Layout.fillWidth: true
                    visible: Recorder.ready && !Recorder.recording
                    spacing: 10

                    Text {
                        text: I18n.t("WHAT TO RECORD")
                        color: Theme.subtext1
                        font.family: Theme.fontFamily
                        font.pixelSize: Theme.fontSize - 2
                        font.bold: true
                    }
                    Flow {
                        id: tiles
                        Layout.fillWidth: true
                        spacing: 8
                        Repeater {
                            model: win.screensList
                            delegate: Tile {
                                required property var modelData
                                required property int index
                                selected: win.sel === index
                                title: modelData.name
                                sub: modelData.width + " × " + modelData.height
                                badge: modelData.name === win.focusedName ? I18n.t("This screen") : ""
                                aspect: modelData.height > 0 ? modelData.width / modelData.height : 16 / 9
                                onPicked: win.activate(index)
                                onPointedAt: win.sel = index
                            }
                        }
                        Tile {
                            selected: win.sel === win.tileCount - 1
                            title: I18n.t("Region")
                            sub: I18n.t("Drag a box")
                            glyph: Icons.crop
                            onPicked: win.activate(win.tileCount - 1)
                            onPointedAt: win.sel = win.tileCount - 1
                        }
                    }

                    Text {
                        Layout.topMargin: 4
                        text: I18n.t("SOUND")
                        color: Theme.subtext1
                        font.family: Theme.fontFamily
                        font.pixelSize: Theme.fontSize - 2
                        font.bold: true
                    }
                    Flow {
                        Layout.fillWidth: true
                        spacing: 6
                        Repeater {
                            model: [
                                { v: "none",   l: I18n.t("No sound") },
                                { v: "system", l: I18n.t("System sound") },
                                { v: "mic",    l: I18n.t("Microphone") }
                            ]
                            delegate: Rectangle {
                                required property var modelData
                                readonly property bool on: Recorder.audio === modelData.v
                                width: chipTxt.implicitWidth + 24
                                height: 30
                                radius: Theme.radius
                                opacity: Recorder.soundOk || modelData.v === "none" ? 1 : 0.45
                                color: on ? Theme.accent : (chipMa.containsMouse ? Theme.surface2 : Theme.surface1)
                                Text {
                                    id: chipTxt
                                    anchors.centerIn: parent
                                    text: modelData.l
                                    color: parent.on ? Theme.onAccent : Theme.text
                                    font.family: Theme.fontFamily
                                    font.pixelSize: Theme.fontSize - 2
                                }
                                MouseArea {
                                    id: chipMa
                                    anchors.fill: parent
                                    hoverEnabled: true
                                    cursorShape: Qt.PointingHandCursor
                                    onClicked: Config.set("recording", "audio", modelData.v)
                                }
                            }
                        }
                    }
                    Text {
                        Layout.fillWidth: true
                        visible: !Recorder.soundOk
                        text: I18n.t("Sound can't be recorded on this system yet, so recordings will be silent. Settings → Screen recording says what is missing.")
                        color: Theme.yellow
                        wrapMode: Text.Wrap
                        font.family: Theme.fontFamily
                        font.pixelSize: Theme.fontSize - 3
                    }

                    Text {
                        Layout.fillWidth: true
                        Layout.topMargin: 2
                        text: I18n.t("Saved to") + " " + Recorder.dir + "  ·  " + Recorder.ext.toUpperCase()
                        color: Theme.subtext0
                        elide: Text.ElideMiddle
                        font.family: Theme.fontFamily
                        font.pixelSize: Theme.fontSize - 3
                    }
                    Text {
                        Layout.fillWidth: true
                        text: I18n.t("←/→ choose · Enter record · R region · Esc close")
                        color: Theme.overlay2
                        wrapMode: Text.Wrap
                        font.family: Theme.fontFamily
                        font.pixelSize: Theme.fontSize - 3
                    }
                }
            }
        }
    }

    // A monitor (or Region) tile: a miniature of the screen's shape, its name
    // and size. The miniature keeps the real aspect, so a portrait monitor
    // reads as portrait.
    component Tile: Rectangle {
        id: tile
        property bool selected: false
        property string title: ""
        property string sub: ""
        property string badge: ""
        property string glyph: ""
        property real aspect: 16 / 9
        signal picked()
        signal pointedAt()
        width: 132
        height: 118
        radius: Theme.radius
        color: tileMa.containsMouse ? Theme.surface2 : Theme.surface1
        border.width: tile.selected ? 2 : 1
        border.color: tile.selected ? Theme.accent : Theme.surface2

        Item {
            id: thumbBox
            anchors.top: parent.top
            anchors.topMargin: 12
            anchors.horizontalCenter: parent.horizontalCenter
            width: 96; height: 54
            Rectangle {
                anchors.centerIn: parent
                width: tile.glyph !== "" ? 72 : (tile.aspect >= 96 / 54 ? 96 : 54 * tile.aspect)
                height: tile.glyph !== "" ? 46 : (tile.aspect >= 96 / 54 ? 96 / tile.aspect : 54)
                radius: 4
                color: tile.glyph !== "" ? "transparent" : Theme.mantle
                border.width: tile.glyph !== "" ? 2 : 1
                border.color: tile.selected ? Theme.accent : Theme.overlay0
                Text {
                    anchors.centerIn: parent
                    visible: tile.glyph !== ""
                    text: tile.glyph
                    color: tile.selected ? Theme.accent : Theme.subtext0
                    font.family: Theme.fontFamily
                    font.pixelSize: Theme.fontSize + 2
                }
            }
        }
        Column {
            anchors.top: thumbBox.bottom
            anchors.topMargin: 8
            anchors.horizontalCenter: parent.horizontalCenter
            spacing: 1
            Text {
                anchors.horizontalCenter: parent.horizontalCenter
                text: tile.title
                color: Theme.text
                font.family: Theme.fontFamily
                font.pixelSize: Theme.fontSize - 2
                font.bold: true
            }
            Text {
                anchors.horizontalCenter: parent.horizontalCenter
                text: tile.badge !== "" ? tile.badge : tile.sub
                color: tile.badge !== "" ? Theme.accent : Theme.subtext0
                font.family: Theme.fontFamily
                font.pixelSize: Theme.fontSize - 4
            }
        }
        MouseArea {
            id: tileMa
            anchors.fill: parent
            hoverEnabled: true
            cursorShape: Qt.PointingHandCursor
            onEntered: tile.pointedAt()
            onClicked: tile.picked()
        }
    }

    component PanelButton: Rectangle {
        id: pb
        property string label: ""
        property bool danger: false
        signal clicked()
        implicitWidth: pbTxt.implicitWidth + 28
        implicitHeight: 34
        radius: Theme.radius
        opacity: pb.enabled ? 1 : 0.5
        color: pb.danger ? (pbMa.containsMouse ? Qt.darker(Theme.red, 1.1) : Theme.red)
                         : (pbMa.containsMouse ? Theme.surface2 : Theme.surface1)
        Text {
            id: pbTxt
            anchors.centerIn: parent
            text: pb.label
            color: pb.danger ? Theme.crust : Theme.text
            font.family: Theme.fontFamily
            font.pixelSize: Theme.fontSize - 1
        }
        MouseArea {
            id: pbMa
            anchors.fill: parent
            hoverEnabled: true
            cursorShape: Qt.PointingHandCursor
            onClicked: pb.clicked()
        }
    }
}
