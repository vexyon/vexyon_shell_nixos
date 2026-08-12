import QtQuick
import QtQuick.Layouts
import Quickshell
import Quickshell.Wayland
import Quickshell.Hyprland
import qs.services
import qs.components

// ============================================================================
//  Power menu — Super+X. Lock / Suspend / Reboot / Power Off / Restart GUI /
//  Log Out. Overlay, dim backdrop, click-outside / Esc to dismiss.
//
//  Keyboard: ←/→ (and ↑/↓) move the selection, Enter/Space activate it,
//  Esc closes. The selection also follows the mouse so both stay in sync.
// ============================================================================
PanelWindow {
    id: win
    // Monitor con el foco al abrir (lo fija Panels.toggle/open).
    screen: Panels.screenFor(Panels.anchorScreen)
    visible: Panels.powermenu

    WlrLayershell.namespace: "vexyon-powermenu"
    WlrLayershell.layer: WlrLayer.Overlay
    WlrLayershell.keyboardFocus: visible ? WlrKeyboardFocus.Exclusive : WlrKeyboardFocus.None
    color: "transparent"
    anchors { top: true; bottom: true; left: true; right: true }

    function run(cmd) {
        Panels.close("powermenu");
        if (cmd === "@lock") { Lock.lock(); return; }
        if (cmd === "@restart-shell") {
            // relaunch the Vexyon shell only; setsid so the new instance
            // survives the kill of the one that spawned it.
            Quickshell.execDetached(["bash", "-c",
                "qs -p \"$HOME/.config/vexyon\" kill; sleep 0.4; " +
                "setsid qs -p \"$HOME/.config/vexyon\" >/dev/null 2>&1 &"]);
            return;
        }
        // suspend/reboot/poweroff/logout — a polkit rule (49-vexyon-power.rules)
        // grants the login1 power actions to `wheel` so systemctl succeeds even
        // though execDetached runs the command outside the active session.
        Quickshell.execDetached(["bash", "-c", cmd]);
    }

    readonly property var actions: [
        { icon: Icons.lock,    label: "Lock",        cmd: "@lock" },
        { icon: Icons.suspend, label: "Suspend",     cmd: "systemctl suspend" },
        { icon: Icons.reboot,  label: "Reboot",      cmd: "systemctl reboot" },
        { icon: Icons.power,   label: "Power Off",   cmd: "systemctl poweroff" },
        { icon: Icons.refresh, label: "Restart GUI", cmd: "@restart-shell" },
        // Lua-root dispatch form (classic `hyprctl dispatch exit` is rejected
        // under hyprland.lua roots).
        { icon: Icons.logout,  label: "Log Out",     cmd: "hyprctl dispatch 'hl.dsp.exit()'" }
    ]

    // keyboard selection index; reset to first card each time the menu opens
    property int selected: 0
    onVisibleChanged: if (visible) { selected = 0; keyScope.forceActiveFocus(); }

    Rectangle {
        anchors.fill: parent
        color: "#000000aa"
        opacity: win.visible ? 1 : 0
        Behavior on opacity { NumberAnimation { duration: Theme.dur(160) } }
        MouseArea { anchors.fill: parent; onClicked: Panels.close("powermenu") }
    }

    // focus scope: owns keyboard nav for the whole overlay
    FocusScope {
        id: keyScope
        anchors.fill: parent
        focus: win.visible
        Keys.onLeftPressed:  win.selected = (win.selected - 1 + win.actions.length) % win.actions.length
        Keys.onRightPressed: win.selected = (win.selected + 1) % win.actions.length
        Keys.onUpPressed:    win.selected = (win.selected - 1 + win.actions.length) % win.actions.length
        Keys.onDownPressed:  win.selected = (win.selected + 1) % win.actions.length
        Keys.onEscapePressed: Panels.close("powermenu")
        Keys.onReturnPressed: win.run(win.actions[win.selected].cmd)
        Keys.onEnterPressed:  win.run(win.actions[win.selected].cmd)
        Keys.onSpacePressed:  win.run(win.actions[win.selected].cmd)

        RowLayout {
            anchors.centerIn: parent
            spacing: 18
            opacity: win.visible ? 1 : 0
            scale: win.visible ? 1 : 0.94
            Behavior on opacity { NumberAnimation { duration: Theme.dur(180); easing.type: Theme.easing } }
            Behavior on scale { NumberAnimation { duration: Theme.dur(180); easing.type: Theme.easing } }

            Repeater {
                model: win.actions
                delegate: Card {
                    id: card
                    required property var modelData
                    required property int index
                    // "active" = highlighted by mouse hover OR keyboard selection
                    readonly property bool active: hov.containsMouse || win.selected === index
                    Layout.preferredWidth: 132
                    Layout.preferredHeight: 132
                    color: active ? Theme.surface1 : Theme.surface0
                    border.width: active ? 2 : 1
                    border.color: active ? Theme.accent : Theme.overlay0
                    Behavior on color { ColorAnimation { duration: Theme.dur(120) } }
                    scale: active ? 1.04 : 1.0
                    Behavior on scale { NumberAnimation { duration: Theme.dur(120); easing.type: Theme.easing } }

                    ColumnLayout {
                        anchors.centerIn: parent
                        spacing: 14
                        Text {
                            Layout.alignment: Qt.AlignHCenter
                            text: card.modelData.icon
                            color: card.active ? Theme.accent : Theme.text
                            font.family: Theme.fontFamily
                            font.pixelSize: 40
                        }
                        Text {
                            Layout.alignment: Qt.AlignHCenter
                            text: I18n.t(card.modelData.label)
                            color: card.active ? Theme.text : Theme.subtext1
                            font.family: Theme.fontFamily
                            font.pixelSize: Theme.fontSize
                        }
                    }

                    MouseArea {
                        id: hov
                        anchors.fill: parent
                        hoverEnabled: true
                        cursorShape: Qt.PointingHandCursor
                        // hover moves the keyboard selection here too
                        onContainsMouseChanged: if (containsMouse) win.selected = card.index
                        onClicked: win.run(card.modelData.cmd)
                    }
                }
            }
        }
    }

    HyprlandFocusGrab {
        active: win.visible
        windows: [ win ]
        onCleared: Panels.close("powermenu")
    }
}
