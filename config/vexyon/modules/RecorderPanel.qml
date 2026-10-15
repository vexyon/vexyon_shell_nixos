import QtQuick
import QtQuick.Layouts
import Quickshell
import Quickshell.Wayland
import Quickshell.Hyprland
import qs.services
import qs.components

// ============================================================================
//  RecorderPanel — what to record. Opened by the recorder shortcut
//  (Super+R by default; Super+Shift+V in 3.0, Super+Shift+R before), the launcher entry or Settings.
//
//  Lives behind a LazyLoader in shell.qml (active = Panels.recorder AND the
//  Screen recording switch): while closed there is no window and no object.
//  Opens on the FOCUSED monitor via Panels.openScreen, like the calculator.
//
//  One tile per monitor (named with the workspace it shows), "Window" and
//  "Region". A monitor tile starts recording that monitor at once; Window
//  lists the windows on screen and records the chosen one's area; Region
//  hands over to the screenshot selector in record mode (Panels.recordRegion),
//  whose result comes back through Panels.regionPicked. Sound, size and frame
//  rate are chips saved in shell.json ("recording"). While a recording runs
//  the card shows it and offers Stop instead. Keyboard: ←/→ (or Tab) choose,
//  Enter records, W = window, R = region, Esc closes (or goes back).
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
    readonly property int tileCount: win.screensList.length + 2     // + Window + Region
    readonly property int windowTile: win.screensList.length
    readonly property int regionTile: win.screensList.length + 1
    // Window step: the windows on screen right now (Recorder.recordableWindows),
    // read when the step opens — Hyprland answers over its socket, no process.
    property bool pickingWindow: false
    property var windowsList: []
    property int wsel: 0
    function workspaceOf(name) {
        var ms = Hyprland.monitors.values;
        for (var i = 0; i < ms.length; i++)
            if (ms[i].name === name && ms[i].activeWorkspace) return ms[i].activeWorkspace.name;
        return "";
    }
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
        } else if (i === win.windowTile) {
            Recorder.refreshWindows();
            win.wsel = 0;
            win.pickingWindow = true;
            win.reloadWindows();
        } else {
            win.close();
            Panels.recordRegion = true;
        }
    }
    function reloadWindows() { win.windowsList = Recorder.recordableWindows(); }
    // The IPC reply lands a moment after refreshWindows(): re-read on it.
    Connections {
        target: win.pickingWindow ? Hyprland : null
        function onRawEvent(e) { win.reloadWindows(); }
    }
    Timer {
        // one-shot: Hyprland's reply to refreshToplevels() has arrived by now
        interval: 250; running: win.pickingWindow; onTriggered: win.reloadWindows()
    }
    function pickWindow(i) {
        if (i < 0 || i >= win.windowsList.length) return;
        var t = win.windowsList[i].toplevel;
        win.close();
        Recorder.startWindow(t);
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
            if (win.pickingWindow) {
                var n = win.windowsList.length;
                if (e.key === Qt.Key_Escape || e.key === Qt.Key_Backspace) win.pickingWindow = false;
                else if (e.key === Qt.Key_Return || e.key === Qt.Key_Enter) win.pickWindow(win.wsel);
                else if (n > 0 && (e.key === Qt.Key_Down || e.key === Qt.Key_Tab || e.key === Qt.Key_Right)) win.wsel = (win.wsel + 1) % n;
                else if (n > 0 && (e.key === Qt.Key_Up || e.key === Qt.Key_Backtab || e.key === Qt.Key_Left)) win.wsel = (win.wsel + n - 1) % n;
                else return;
                e.accepted = true;
                return;
            }
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
            else if (e.key === Qt.Key_R) win.activate(win.regionTile);
            else if (e.key === Qt.Key_W) win.activate(win.windowTile);
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

                // ---------- step 2: which window ----------
                ColumnLayout {
                    Layout.fillWidth: true
                    visible: Recorder.ready && !Recorder.recording && win.pickingWindow
                    spacing: 8
                    RowLayout {
                        Layout.fillWidth: true
                        spacing: 8
                        IconButton {
                            icon: Icons.back
                            iconColor: Theme.subtext0
                            iconSize: Theme.fontSize - 1
                            implicitWidth: 26; implicitHeight: 26
                            onClicked: win.pickingWindow = false
                        }
                        Text {
                            Layout.fillWidth: true
                            text: I18n.t("WHICH WINDOW")
                            color: Theme.subtext1
                            font.family: Theme.fontFamily
                            font.pixelSize: Theme.fontSize - 2
                            font.bold: true
                        }
                    }
                    Text {
                        Layout.fillWidth: true
                        visible: win.windowsList.length === 0
                        text: I18n.t("No window on screen right now. Only windows on a workspace that is showing can be recorded.")
                        color: Theme.subtext0
                        wrapMode: Text.Wrap
                        font.family: Theme.fontFamily
                        font.pixelSize: Theme.fontSize - 2
                    }
                    Repeater {
                        model: win.windowsList
                        delegate: Rectangle {
                            required property var modelData
                            required property int index
                            Layout.fillWidth: true
                            implicitHeight: 42
                            radius: Theme.radius
                            color: wrowMa.containsMouse ? Theme.surface2 : Theme.surface1
                            border.width: win.wsel === index ? 2 : 0
                            border.color: Theme.accent
                            RowLayout {
                                anchors.fill: parent
                                anchors.leftMargin: 12; anchors.rightMargin: 12
                                spacing: 10
                                Text {
                                    text: Icons.window
                                    color: win.wsel === index ? Theme.accent : Theme.subtext0
                                    font.family: Theme.fontFamily
                                    font.pixelSize: Theme.fontSize
                                }
                                ColumnLayout {
                                    Layout.fillWidth: true
                                    spacing: 0
                                    Text {
                                        Layout.fillWidth: true
                                        text: modelData.cls !== "" ? modelData.cls : modelData.title
                                        color: Theme.text
                                        elide: Text.ElideRight
                                        font.family: Theme.fontFamily
                                        font.pixelSize: Theme.fontSize - 1
                                        font.bold: true
                                    }
                                    Text {
                                        Layout.fillWidth: true
                                        visible: modelData.title !== "" && modelData.cls !== ""
                                        text: modelData.title
                                        color: Theme.subtext0
                                        elide: Text.ElideRight
                                        font.family: Theme.fontFamily
                                        font.pixelSize: Theme.fontSize - 3
                                    }
                                }
                                Text {
                                    text: modelData.rect.w + " × " + modelData.rect.h
                                    color: Theme.subtext0
                                    font.family: Theme.fontFamily
                                    font.pixelSize: Theme.fontSize - 3
                                }
                            }
                            MouseArea {
                                id: wrowMa
                                anchors.fill: parent
                                hoverEnabled: true
                                cursorShape: Qt.PointingHandCursor
                                onEntered: win.wsel = index
                                onClicked: win.pickWindow(index)
                            }
                        }
                    }
                    Text {
                        Layout.fillWidth: true
                        text: I18n.t("The window's area is recorded as it is when you start: keep the window there, and anything placed over it is recorded too.")
                        color: Theme.overlay2
                        wrapMode: Text.Wrap
                        font.family: Theme.fontFamily
                        font.pixelSize: Theme.fontSize - 3
                    }
                }

                // ---------- choose what to record ----------
                ColumnLayout {
                    Layout.fillWidth: true
                    visible: Recorder.ready && !Recorder.recording && !win.pickingWindow
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
                                // the workspace it shows: recording a screen IS recording
                                // whatever workspace is on it
                                sub: (win.workspaceOf(modelData.name) !== ""
                                      ? I18n.t("Workspace %1").arg(win.workspaceOf(modelData.name)) + " · " : "")
                                     + modelData.width + "×" + modelData.height
                                badge: modelData.name === win.focusedName ? I18n.t("This screen") : ""
                                aspect: modelData.height > 0 ? modelData.width / modelData.height : 16 / 9
                                onPicked: win.activate(index)
                                onPointedAt: win.sel = index
                            }
                        }
                        Tile {
                            selected: win.sel === win.windowTile
                            title: I18n.t("Window")
                            sub: I18n.t("Pick one")
                            glyph: Icons.window
                            onPicked: win.activate(win.windowTile)
                            onPointedAt: win.sel = win.windowTile
                        }
                        Tile {
                            selected: win.sel === win.regionTile
                            title: I18n.t("Region")
                            sub: I18n.t("Drag a box")
                            glyph: Icons.crop
                            onPicked: win.activate(win.regionTile)
                            onPointedAt: win.sel = win.regionTile
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
                    ChipRow {
                        key: "audio"; value: Recorder.audio; dim: !Recorder.soundOk
                        options: [
                            { v: "none",   l: I18n.t("No sound") },
                            { v: "system", l: I18n.t("System sound") },
                            { v: "mic",    l: I18n.t("Microphone") },
                            { v: "both",   l: I18n.t("System + microphone") }
                        ]
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
                        Layout.topMargin: 4
                        text: I18n.t("QUALITY")
                        color: Theme.subtext1
                        font.family: Theme.fontFamily
                        font.pixelSize: Theme.fontSize - 2
                        font.bold: true
                    }
                    ChipRow {
                        key: "resolution"; value: Recorder.resolution
                        options: [
                            { v: "native", l: I18n.t("Native size") },
                            { v: "1440",   l: "1440p" },
                            { v: "1080",   l: "1080p" },
                            { v: "720",    l: "720p" }
                        ]
                    }
                    ChipRow {
                        key: "fps"; value: Recorder.fps
                        options: [
                            { v: "auto", l: I18n.t("Screen rate") },
                            { v: "60",   l: "60 fps" },
                            { v: "30",   l: "30 fps" }
                        ]
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
                        text: I18n.t("←/→ choose · Enter record · W window · R region · Esc close")
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

    // A row of choices saved in shell.json ("recording" section).
    component ChipRow: Flow {
        id: cr
        property string key: ""
        property string value: ""
        property bool dim: false
        property var options: []
        Layout.fillWidth: true
        spacing: 6
        Repeater {
            model: cr.options
            delegate: Rectangle {
                required property var modelData
                readonly property bool on: cr.value === modelData.v
                width: chipTxt.implicitWidth + 24
                height: 30
                radius: Theme.radius
                opacity: !cr.dim || modelData.v === "none" ? 1 : 0.45
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
                    onClicked: Config.set("recording", cr.key, modelData.v)
                }
            }
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
