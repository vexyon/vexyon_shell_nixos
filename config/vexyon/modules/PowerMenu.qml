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
    visible: Panels.powermenu

    // Monitor ENFOCADO (no el del puntero): sin `screen` el compositor coloca
    // la capa bajo el ratón, que con navegación por teclado NO es donde está
    // el usuario. Fuente única en Panels.focusedScreen().
    screen: Panels.openScreen || Panels.focusedScreen()
    WlrLayershell.namespace: "vexyon-powermenu"
    WlrLayershell.layer: WlrLayer.Overlay
    WlrLayershell.keyboardFocus: visible ? WlrKeyboardFocus.Exclusive : WlrKeyboardFocus.None
    color: "transparent"
    anchors { top: true; bottom: true; left: true; right: true }

    function run(cmd) {
        Panels.close("powermenu");
        if (cmd === "@lock") { Lock.lock(); return; }
        if (cmd === "@restart-shell") {
            // Reinicio EN SITIO dentro de la MISMA sesión de login: se deja el
            // flag que el bucle de vexyon-start ya vigila y se le manda SIGTERM
            // a Hyprland; el bucle lo relanza y se relee la config entera
            // (incluidos los workspaces por monitor, que no basta con
            // `hyprctl reload` porque los existentes no se mueven solos).
            // Es EXACTAMENTE la vía que ya usa vexyon-gpu-hotplug — mecanismo
            // reutilizado, no inventado.
            //
            // ⚠️ Lo de antes (`qs -p "$HOME/.config/vexyon" kill` + relanzar)
            // daba por hecho que el shell vive en ~/.config/vexyon: cierto en
            // Arch, FALSO en NixOS, donde corre desde /nix/store y ese
            // directorio ni siquiera tiene shell.qml. Por eso "no hacía nada".
            //
            // El pid NO se resuelve con `pgrep -x Hyprland`: en NixOS el
            // binario es un wrapper y su comm es ".Hyprland-wrapp", así que
            // -x no casa con nada (verificado en esta máquina). Se usa el
            // MISMO matcher doble que vexyon-gpu-hotplug, que ya contempla
            // ese caso.
            Quickshell.execDetached(["bash", "-c",
                'f="${XDG_RUNTIME_DIR:-/run/user/$(id -u)}/vexyon-gpu-restart"; : > "$f"; ' +
                'p=$({ pgrep -x Hyprland || true; pgrep -f "/bin/[.]?Hyprland" || true; } ' +
                '2>/dev/null | sort -un | head -1); ' +
                '[ -n "$p" ] && kill -TERM "$p"']);
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
