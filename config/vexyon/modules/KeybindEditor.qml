import QtQuick
import QtQuick.Layouts
import Quickshell
import Quickshell.Io
import qs.services
import qs.components

// Keybind editor: list every action, click its combo to rebind (captures the
// next key chord), detects conflicts, remove any bind, or add a brand-new one
// (built-in shell action, custom command, or a raw Hyprland dispatcher).
// Saving writes shell.json -> the bridge regenerates the Hyprland keybind file
// + reloads. The schema already stores keybinds as a flat list, so add/remove
// is a plain array mutation; the bridge emits a line per entry by action type.
Item {
    id: root

    // editable working copy of the keybinds
    property var binds: []
    property int capturingIndex: -1
    property string conflictMsg: ""

    // ---- built-in shell actions (Quickshell GlobalShortcuts, action="global") ----
    // These are the only valid `global` names — they must match the
    // GlobalShortcut{ name: ... } declared in shell.qml. Free-form `global`
    // binds would point at a shortcut that doesn't exist, so adding is limited
    // to this set; exec/dispatch stay free-form.
    readonly property var builtins: [
        { arg: "launcher",      label: I18n.t("Open app launcher") },
        { arg: "filemanager",   label: I18n.t("Open file manager") },
        { arg: "controlcenter", label: I18n.t("Open control center") },
        { arg: "wallpaper",     label: I18n.t("Wallpaper picker") },
        { arg: "powermenu",     label: I18n.t("Power menu") },
        { arg: "lock",          label: I18n.t("Lock screen") },
        { arg: "screenshot",    label: I18n.t("Screenshot") },
        { arg: "themeswitcher", label: I18n.t("Switch theme (quick)") }
    ]
    function builtinLabel(arg) {
        for (var i = 0; i < builtins.length; i++) if (builtins[i].arg === arg) return builtins[i].label;
        return arg;
    }

    // ---- add-form draft state ----
    property bool adding: false
    property string draftType: "exec"   // "global" | "exec" | "dispatch"
    property string draftArg: ""
    property string draftDesc: ""
    property var draftMods: []
    property string draftKey: ""
    property bool capturingDraft: false
    readonly property bool draftHasCombo: draftKey !== ""
    readonly property var draftConflict: draftHasCombo ? findConflict(-1, draftMods, draftKey) : null
    readonly property bool draftArgOk: draftType === "global" ? draftArg !== "" : draftArg.trim() !== ""
    readonly property bool draftValid: draftHasCombo && draftArgOk && !draftConflict

    function syncFromConfig() {
        root.binds = JSON.parse(JSON.stringify(Config.keybinds));
    }
    Component.onCompleted: syncFromConfig()
    Connections { target: Config; function onChanged() {
        if (root.capturingIndex === -1 && !root.adding) root.syncFromConfig();
    } }

    // ---- helpers ----
    function comboLabel(mods, key) {
        var m = (mods || []).slice();
        m.push(prettyKey(key));
        return m.join(" + ");
    }
    function prettyKey(k) {
        var map = { "left": "←", "right": "→", "up": "↑", "down": "↓", "Print": "PrtSc",
                    "XF86AudioRaiseVolume": "Vol +", "XF86AudioLowerVolume": "Vol −",
                    "XF86AudioMute": "Mute", "XF86AudioMicMute": "Mic Mute",
                    "XF86MonBrightnessUp": "Bright +", "XF86MonBrightnessDown": "Bright −",
                    "XF86AudioPlay": "Play", "XF86AudioPause": "Pause",
                    "XF86AudioNext": "Next", "XF86AudioPrev": "Prev" };
        return map[k] || k;
    }
    function comboKey(mods, key) {
        return (mods || []).slice().sort().join("+") + "|" + key;
    }
    function findConflict(idx, mods, key) {
        var ck = comboKey(mods, key);
        for (var i = 0; i < root.binds.length; i++) {
            if (i === idx) continue;
            if (comboKey(root.binds[i].mods, root.binds[i].key) === ck) return root.binds[i];
        }
        return null;
    }
    // Qt key event -> Hyprland key name
    function keyName(event) {
        var k = event.key;
        if (k >= Qt.Key_A && k <= Qt.Key_Z) return String.fromCharCode("A".charCodeAt(0) + (k - Qt.Key_A));
        if (k >= Qt.Key_0 && k <= Qt.Key_9) return String.fromCharCode("0".charCodeAt(0) + (k - Qt.Key_0));
        if (k >= Qt.Key_F1 && k <= Qt.Key_F12) return "F" + (k - Qt.Key_F1 + 1);
        switch (k) {
            case Qt.Key_Left: return "left";
            case Qt.Key_Right: return "right";
            case Qt.Key_Up: return "up";
            case Qt.Key_Down: return "down";
            case Qt.Key_Print: return "Print";
            case Qt.Key_Space: return "space";
            case Qt.Key_Return:
            case Qt.Key_Enter: return "Return";
            case Qt.Key_Tab: return "Tab";
            case Qt.Key_Backspace: return "BackSpace";
            case Qt.Key_Comma: return "comma";
            case Qt.Key_Period: return "period";
            case Qt.Key_Slash: return "slash";
            // multimedia keys -> XF86 names so a captured combo regenerates
            // the same bind the defaults ship with
            case Qt.Key_VolumeUp: return "XF86AudioRaiseVolume";
            case Qt.Key_VolumeDown: return "XF86AudioLowerVolume";
            case Qt.Key_VolumeMute: return "XF86AudioMute";
            case Qt.Key_MicMute: return "XF86AudioMicMute";
            case Qt.Key_MonBrightnessUp: return "XF86MonBrightnessUp";
            case Qt.Key_MonBrightnessDown: return "XF86MonBrightnessDown";
            case Qt.Key_MediaPlay: return "XF86AudioPlay";
            case Qt.Key_MediaPause: return "XF86AudioPause";
            case Qt.Key_MediaTogglePlayPause: return "XF86AudioPlay";
            case Qt.Key_MediaNext: return "XF86AudioNext";
            case Qt.Key_MediaPrevious: return "XF86AudioPrev";
        }
        if (event.text && event.text.trim() !== "") return event.text.toUpperCase();
        return "";
    }
    function modsFrom(event) {
        var m = [];
        if (event.modifiers & Qt.MetaModifier) m.push("SUPER");
        if (event.modifiers & Qt.ControlModifier) m.push("CTRL");
        if (event.modifiers & Qt.AltModifier) m.push("ALT");
        if (event.modifiers & Qt.ShiftModifier) m.push("SHIFT");
        return m;
    }
    function isModifierKey(k) {
        return k === Qt.Key_Meta || k === Qt.Key_Super_L || k === Qt.Key_Super_R
            || k === Qt.Key_Control || k === Qt.Key_Alt || k === Qt.Key_Shift
            || k === Qt.Key_AltGr || k === Qt.Key_CapsLock;
    }

    function commit(idx, mods, key) {
        var b = JSON.parse(JSON.stringify(root.binds));
        b[idx].mods = mods;
        b[idx].key = key;
        root.binds = b;
        Config.setSection("keybinds", b);   // -> bridge regenerates + hyprctl reload
    }
    function startCapture(idx) { root.conflictMsg = ""; root.capturingIndex = idx; root.capturingDraft = false; capture.forceActiveFocus(); }
    function cancelCapture() { root.capturingIndex = -1; root.conflictMsg = ""; }

    // ---- remove ----
    function removeBind(idx) {
        var b = JSON.parse(JSON.stringify(root.binds));
        b.splice(idx, 1);
        root.binds = b;
        Config.setSection("keybinds", b);
    }

    // ---- add ----
    function openAdd() {
        root.adding = true;
        root.draftType = "exec";
        root.draftArg = "";
        root.draftDesc = "";
        root.draftMods = [];
        root.draftKey = "";
        root.conflictMsg = "";
        cmdField.text = "";
        descField.text = "";
    }
    function cancelAdd() { root.adding = false; root.capturingDraft = false; }
    function startDraftCapture() { root.capturingDraft = true; root.capturingIndex = -1; capture.forceActiveFocus(); }

    function slug(s) {
        return (s || "").toLowerCase().replace(/[^a-z0-9]+/g, "-").replace(/^-+|-+$/g, "");
    }
    function uniqueId(base) {
        var b = base && base !== "" ? base : "bind";
        var exists = function(id) { for (var i = 0; i < root.binds.length; i++) if (root.binds[i].id === id) return true; return false; };
        if (!exists(b)) return b;
        var n = 2;
        while (exists(b + "-" + n)) n++;
        return b + "-" + n;
    }
    function saveDraft() {
        if (!root.draftValid) return;
        var arg = root.draftType === "global" ? root.draftArg : root.draftArg.trim();
        var desc = root.draftDesc.trim();
        if (desc === "") desc = root.draftType === "global" ? builtinLabel(arg) : arg;
        var base = root.draftType === "global" ? arg : slug(desc);
        var entry = {
            id: uniqueId(base),
            mods: root.draftMods.slice(),
            key: root.draftKey,
            action: root.draftType,
            arg: arg,
            desc: desc,
            category: root.draftType === "global" ? "Vexyon" : I18n.t("Custom")
        };
        var b = JSON.parse(JSON.stringify(root.binds));
        b.push(entry);
        root.binds = b;
        Config.setSection("keybinds", b);
        root.adding = false;
        root.capturingDraft = false;
    }

    function resetDefaults() {
        defaultsReader.running = true;
    }

    Process {
        id: defaultsReader
        command: ["cat", Quickshell.env("HOME") + "/.local/share/vexyon/defaults/keybinds.json"]
        stdout: StdioCollector {
            onStreamFinished: {
                try {
                    var arr = JSON.parse(this.text);
                    if (Array.isArray(arr)) { root.binds = arr; Config.setSection("keybinds", arr); }
                } catch (e) { console.warn("[KeybindEditor] reset parse failed:", e); }
            }
        }
    }

    // Hidden capture surface: focused while rebinding or defining a new bind's
    // combo, eats the chord.
    Item {
        id: capture
        focus: root.capturingIndex !== -1 || root.capturingDraft
        Keys.onPressed: function(event) {
            if (root.capturingIndex === -1 && !root.capturingDraft) return;
            event.accepted = true;
            if (event.key === Qt.Key_Escape) {
                if (root.capturingDraft) root.capturingDraft = false;
                else root.cancelCapture();
                return;
            }
            if (isModifierKey(event.key)) return; // wait for the non-modifier key
            var key = keyName(event);
            if (key === "") return;
            var mods = modsFrom(event);
            if (root.capturingDraft) {
                // set the draft combo unconditionally; conflict is shown live and
                // blocks Save (draftValid), same idea as row rebind but non-modal.
                root.draftMods = mods;
                root.draftKey = key;
                root.capturingDraft = false;
                return;
            }
            var conflict = root.findConflict(root.capturingIndex, mods, key);
            if (conflict) {
                root.conflictMsg = "\"" + root.comboLabel(mods, key) + "\"" + I18n.t(" already bound to: ") + conflict.desc;
                return; // don't commit a conflicting bind
            }
            root.commit(root.capturingIndex, mods, key);
            root.capturingIndex = -1;
        }
    }

    // reusable styled text field (command / description input)
    component FieldBox: Rectangle {
        property alias text: input.text
        property string placeholder: ""
        Layout.fillWidth: true
        Layout.preferredHeight: 34
        radius: Theme.radius
        color: Theme.surface1
        border.width: input.activeFocus ? 1 : 0
        border.color: Theme.accent
        TextInput {
            id: input
            anchors.fill: parent; anchors.leftMargin: 10; anchors.rightMargin: 10
            verticalAlignment: TextInput.AlignVCenter
            clip: true
            color: Theme.text
            selectionColor: Theme.accent
            font.family: Theme.fontFamily; font.pixelSize: Theme.fontSize - 1
            Text {
                anchors.verticalCenter: parent.verticalCenter
                visible: input.text === ""
                text: parent.parent.placeholder
                color: Theme.overlay1
                font: input.font
            }
        }
    }

    ColumnLayout {
        anchors.fill: parent
        spacing: 8

        // header row with add + reset
        RowLayout {
            Layout.fillWidth: true
            spacing: 8
            Text {
                Layout.fillWidth: true
                text: root.capturingIndex !== -1 ? I18n.t("Press a key combination…  (Esc to cancel)") : I18n.t("Click a shortcut to rebind")
                color: root.capturingIndex !== -1 ? Theme.accent : Theme.subtext0
                font.family: Theme.fontFamily
                font.pixelSize: Theme.fontSize - 1
            }
            // Add
            Rectangle {
                Layout.preferredWidth: addRow.implicitWidth + 20
                Layout.preferredHeight: 28
                radius: Theme.radius
                color: ama.containsMouse ? Qt.rgba(Theme.accent.r, Theme.accent.g, Theme.accent.b, 0.9) : Theme.accent
                Row {
                    id: addRow
                    anchors.centerIn: parent
                    spacing: 6
                    Text { text: Icons.plus; color: Theme.onAccent; font.family: Theme.fontFamily; font.pixelSize: Theme.fontSize - 2; anchors.verticalCenter: parent.verticalCenter }
                    Text { text: I18n.t("Add shortcut"); color: Theme.onAccent; font.family: Theme.fontFamily; font.pixelSize: Theme.fontSize - 2; anchors.verticalCenter: parent.verticalCenter }
                }
                MouseArea {
                    id: ama
                    anchors.fill: parent
                    hoverEnabled: true
                    cursorShape: Qt.PointingHandCursor
                    onClicked: root.adding ? root.cancelAdd() : root.openAdd()
                }
            }
            // Reset
            Rectangle {
                Layout.preferredWidth: reset.implicitWidth + 20
                Layout.preferredHeight: 28
                radius: Theme.radius
                color: rma.containsMouse ? Theme.surface2 : Theme.surface1
                Text {
                    id: reset
                    anchors.centerIn: parent
                    text: I18n.t("Reset to defaults")
                    color: Theme.text
                    font.family: Theme.fontFamily
                    font.pixelSize: Theme.fontSize - 2
                }
                MouseArea {
                    id: rma
                    anchors.fill: parent
                    hoverEnabled: true
                    cursorShape: Qt.PointingHandCursor
                    onClicked: root.resetDefaults()
                }
            }
        }

        Text {
            Layout.fillWidth: true
            visible: root.conflictMsg !== ""
            text: "⚠ " + root.conflictMsg
            color: Theme.red
            wrapMode: Text.WordWrap
            font.family: Theme.fontFamily
            font.pixelSize: Theme.fontSize - 2
        }

        // ---- add form ----
        Rectangle {
            Layout.fillWidth: true
            visible: root.adding
            radius: Theme.radius
            color: Theme.surface0
            border.width: 1
            border.color: Theme.surface2
            implicitHeight: addForm.implicitHeight + 24

            ColumnLayout {
                id: addForm
                anchors.left: parent.left; anchors.right: parent.right; anchors.top: parent.top
                anchors.margins: 12
                spacing: 10

                Text {
                    text: I18n.t("New shortcut")
                    color: Theme.text; font.bold: true
                    font.family: Theme.fontFamily; font.pixelSize: Theme.fontSize
                }

                // action-type selector
                RowLayout {
                    Layout.fillWidth: true
                    spacing: 8
                    Repeater {
                        model: [
                            { t: "exec",     l: I18n.t("Command") },
                            { t: "global",   l: I18n.t("Built-in action") },
                            { t: "dispatch", l: I18n.t("Hyprland dispatch") }
                        ]
                        delegate: Rectangle {
                            required property var modelData
                            Layout.fillWidth: true
                            Layout.preferredHeight: 32
                            radius: Theme.radius
                            readonly property bool sel: root.draftType === modelData.t
                            color: sel ? Theme.accent : (tma.containsMouse ? Theme.surface2 : Theme.surface1)
                            Text {
                                anchors.centerIn: parent
                                text: parent.modelData.l
                                color: parent.sel ? Theme.onAccent : Theme.text
                                font.family: Theme.fontFamily; font.pixelSize: Theme.fontSize - 2
                            }
                            MouseArea {
                                id: tma
                                anchors.fill: parent; hoverEnabled: true; cursorShape: Qt.PointingHandCursor
                                onClicked: { root.draftType = parent.modelData.t; root.draftArg = ""; cmdField.text = ""; }
                            }
                        }
                    }
                }

                // built-in action chips
                Flow {
                    Layout.fillWidth: true
                    visible: root.draftType === "global"
                    spacing: 6
                    Repeater {
                        model: root.builtins
                        delegate: Rectangle {
                            required property var modelData
                            height: 30
                            width: bl.implicitWidth + 22
                            radius: Theme.radius
                            readonly property bool sel: root.draftArg === modelData.arg
                            color: sel ? Theme.accent : (bma.containsMouse ? Theme.surface2 : Theme.surface1)
                            Text {
                                id: bl
                                anchors.centerIn: parent
                                text: parent.modelData.label
                                color: parent.sel ? Theme.onAccent : Theme.text
                                font.family: Theme.fontFamily; font.pixelSize: Theme.fontSize - 2
                            }
                            MouseArea {
                                id: bma
                                anchors.fill: parent; hoverEnabled: true; cursorShape: Qt.PointingHandCursor
                                onClicked: {
                                    root.draftArg = parent.modelData.arg;
                                    if (root.draftDesc.trim() === "") { root.draftDesc = parent.modelData.label; descField.text = parent.modelData.label; }
                                }
                            }
                        }
                    }
                }

                // command / dispatch input
                FieldBox {
                    id: cmdField
                    visible: root.draftType !== "global"
                    onTextChanged: root.draftArg = text
                    placeholder: root.draftType === "exec"
                        ? I18n.t("Command to run (e.g. firefox)")
                        : I18n.t("Hyprland dispatcher (e.g. movetoworkspace 3)")
                }

                // description
                FieldBox {
                    id: descField
                    onTextChanged: root.draftDesc = text
                    placeholder: I18n.t("Description (optional)")
                }

                // key combo capture + save/cancel
                RowLayout {
                    Layout.fillWidth: true
                    spacing: 8
                    Rectangle {
                        Layout.preferredHeight: 32
                        Layout.preferredWidth: Math.max(120, dcombo.implicitWidth + 24)
                        radius: Theme.radius
                        color: root.capturingDraft ? Theme.accent : Theme.surface2
                        border.width: 1
                        border.color: root.capturingDraft ? Theme.accent
                            : (root.draftConflict ? Theme.red : (root.draftHasCombo ? Theme.accent : Theme.overlay0))
                        Text {
                            id: dcombo
                            anchors.centerIn: parent
                            text: root.capturingDraft ? "…"
                                : (root.draftHasCombo ? root.comboLabel(root.draftMods, root.draftKey) : I18n.t("Assign combo"))
                            color: root.capturingDraft ? Theme.onAccent : Theme.text
                            font.family: Theme.fontFamily; font.pixelSize: Theme.fontSize - 2; font.bold: true
                        }
                        MouseArea {
                            anchors.fill: parent; cursorShape: Qt.PointingHandCursor
                            onClicked: root.startDraftCapture()
                        }
                    }
                    Item { Layout.fillWidth: true }
                    Rectangle {
                        Layout.preferredHeight: 32; Layout.preferredWidth: 84
                        radius: Theme.radius
                        color: cma.containsMouse ? Theme.surface2 : Theme.surface1
                        Text { anchors.centerIn: parent; text: I18n.t("Cancel"); color: Theme.text; font.family: Theme.fontFamily; font.pixelSize: Theme.fontSize - 2 }
                        MouseArea { id: cma; anchors.fill: parent; hoverEnabled: true; cursorShape: Qt.PointingHandCursor; onClicked: root.cancelAdd() }
                    }
                    Rectangle {
                        Layout.preferredHeight: 32; Layout.preferredWidth: 84
                        radius: Theme.radius
                        opacity: root.draftValid ? 1 : 0.4
                        color: sma.containsMouse && root.draftValid ? Qt.rgba(Theme.accent.r, Theme.accent.g, Theme.accent.b, 0.9) : Theme.accent
                        Text { anchors.centerIn: parent; text: I18n.t("Save"); color: Theme.onAccent; font.family: Theme.fontFamily; font.pixelSize: Theme.fontSize - 2; font.bold: true }
                        MouseArea { id: sma; anchors.fill: parent; hoverEnabled: true; cursorShape: root.draftValid ? Qt.PointingHandCursor : Qt.ArrowCursor; onClicked: root.saveDraft() }
                    }
                }

                Text {
                    Layout.fillWidth: true
                    visible: root.draftConflict !== null
                    text: I18n.t("⚠ That combo is already used by: ") + (root.draftConflict ? root.draftConflict.desc : "")
                    color: Theme.red; wrapMode: Text.WordWrap
                    font.family: Theme.fontFamily; font.pixelSize: Theme.fontSize - 2
                }
            }
        }

        ListView {
            Layout.fillWidth: true
            Layout.fillHeight: true
            clip: true
            model: root.binds
            spacing: 4
            boundsBehavior: Flickable.StopAtBounds

            delegate: Rectangle {
                required property int index
                required property var modelData
                width: ListView.view.width
                height: 46
                radius: Theme.radius
                color: index === root.capturingIndex ? Theme.surface1 : Theme.surface0

                RowLayout {
                    anchors.fill: parent
                    anchors.leftMargin: 12
                    anchors.rightMargin: 12
                    spacing: 10

                    Column {
                        Layout.fillWidth: true
                        Text {
                            text: I18n.t(modelData.desc || modelData.id)
                            color: Theme.text
                            font.family: Theme.fontFamily
                            font.pixelSize: Theme.fontSize - 1
                            elide: Text.ElideRight
                            width: parent.width
                        }
                        Text {
                            text: I18n.t(modelData.category || "")
                            color: Theme.overlay2
                            font.family: Theme.fontFamily
                            font.pixelSize: Theme.fontSize - 4
                        }
                    }

                    Rectangle {
                        Layout.preferredHeight: 28
                        Layout.preferredWidth: comboText.implicitWidth + 22
                        radius: Theme.radius
                        color: index === root.capturingIndex ? Theme.accent : Theme.surface2
                        border.width: 1
                        border.color: index === root.capturingIndex ? Theme.accent : Theme.overlay0

                        Text {
                            id: comboText
                            anchors.centerIn: parent
                            text: index === root.capturingIndex ? "…" : root.comboLabel(modelData.mods, modelData.key)
                            color: index === root.capturingIndex ? Theme.onAccent : Theme.text
                            font.family: Theme.fontFamily
                            font.pixelSize: Theme.fontSize - 2
                            font.bold: true
                        }
                        MouseArea {
                            anchors.fill: parent
                            cursorShape: Qt.PointingHandCursor
                            onClicked: root.startCapture(index)
                        }
                    }

                    // remove
                    Rectangle {
                        Layout.preferredHeight: 28
                        Layout.preferredWidth: 28
                        radius: Theme.radius
                        color: dma.containsMouse ? Qt.rgba(Theme.red.r, Theme.red.g, Theme.red.b, 0.18) : "transparent"
                        Text {
                            anchors.centerIn: parent
                            text: Icons.trash
                            color: dma.containsMouse ? Theme.red : Theme.overlay2
                            font.family: Theme.fontFamily
                            font.pixelSize: Theme.fontSize - 1
                        }
                        MouseArea {
                            id: dma
                            anchors.fill: parent
                            hoverEnabled: true
                            cursorShape: Qt.PointingHandCursor
                            onClicked: root.removeBind(index)
                        }
                    }
                }
            }
        }
    }
}
