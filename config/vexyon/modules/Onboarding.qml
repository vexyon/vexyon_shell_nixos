import QtQuick
import QtQuick.Layouts
import Quickshell
import Quickshell.Wayland
import qs.services
import qs.components

// ============================================================================
//  Onboarding splash — shown ONCE on first boot (shell.json state.firstRun).
//  "Welcome" / "Made by Vexyon" + a few starter keybinds. Dismiss persists the
//  flag so it never shows again.
// ============================================================================
PanelWindow {
    id: win
    visible: Config.ready && Config.get("state", "firstRun", true) === true

    WlrLayershell.namespace: "vexyon-onboarding"
    WlrLayershell.layer: WlrLayer.Overlay
    WlrLayershell.keyboardFocus: visible ? WlrKeyboardFocus.Exclusive : WlrKeyboardFocus.None
    // Ignora zonas exclusivas ajenas (la barra) para cubrir TODA la pantalla,
    // incluida la franja de la barra — si no, el layer-shell encoge el surface
    // bajo la barra y el splash no es realmente a pantalla completa (misma
    // causa que el gap de paneles de S25).
    WlrLayershell.exclusiveZone: -1
    color: "transparent"
    anchors { top: true; bottom: true; left: true; right: true }

    function dismiss() { Config.set("state", "firstRun", false); }

    Rectangle {
        anchors.fill: parent
        gradient: Gradient {
            GradientStop { position: 0.0; color: Qt.rgba(Theme.crust.r, Theme.crust.g, Theme.crust.b, 0.97) }
            GradientStop { position: 1.0; color: Qt.rgba(Theme.mantle.r, Theme.mantle.g, Theme.mantle.b, 0.97) }
        }
    }

    Item {
        anchors.fill: parent
        focus: win.visible
        Keys.onEscapePressed: win.dismiss()
        Keys.onReturnPressed: win.dismiss()
    }

    ColumnLayout {
        anchors.centerIn: parent
        width: 520
        spacing: 26
        opacity: win.visible ? 1 : 0
        Behavior on opacity { NumberAnimation { duration: Theme.dur(400); easing.type: Theme.easing } }

        // logo mark
        Rectangle {
            Layout.alignment: Qt.AlignHCenter
            Layout.preferredWidth: 96; Layout.preferredHeight: 96; radius: 24
            color: "transparent"
            border.width: 3
            border.color: Theme.accent
            Text {
                anchors.centerIn: parent
                text: "V"
                color: Theme.accent
                font.family: Theme.fontFamily
                font.pixelSize: 54
                font.bold: true
            }
        }

        Column {
            Layout.alignment: Qt.AlignHCenter
            spacing: 6
            Text {
                anchors.horizontalCenter: parent.horizontalCenter
                text: I18n.t("Welcome")
                color: Theme.text
                font.family: Theme.fontFamily
                font.pixelSize: 48
                font.bold: true
            }
            Text {
                anchors.horizontalCenter: parent.horizontalCenter
                text: I18n.t("Made by Vexyon")
                color: Theme.subtext0
                font.family: Theme.fontFamily
                font.pixelSize: Theme.fontSize + 2
            }
        }

        // starter keybinds
        GridLayout {
            Layout.alignment: Qt.AlignHCenter
            columns: 2
            columnSpacing: 28
            rowSpacing: 10
            Repeater {
                model: [
                    { k: "Super + A", d: I18n.t("App launcher") },
                    { k: "Super + T", d: I18n.t("Terminal") },
                    { k: "Super + C", d: I18n.t("Control Center") },
                    { k: "Super + E", d: I18n.t("Files") },
                    { k: "Super + X", d: I18n.t("Power menu") },
                    { k: "Super + L", d: I18n.t("Lock") }
                ]
                delegate: RowLayout {
                    required property var modelData
                    spacing: 10
                    Rectangle {
                        radius: Theme.radius - 2
                        color: Theme.surface1
                        implicitHeight: 24
                        implicitWidth: kb.implicitWidth + 16
                        Text {
                            id: kb
                            anchors.centerIn: parent
                            text: modelData.k
                            color: Theme.text
                            font.family: Theme.fontFamily
                            font.pixelSize: Theme.fontSize - 3
                            font.bold: true
                        }
                    }
                    Text {
                        text: modelData.d
                        color: Theme.subtext1
                        font.family: Theme.fontFamily
                        font.pixelSize: Theme.fontSize - 1
                    }
                }
            }
        }

        // language selector (also available afterwards in Settings → Behavior)
        RowLayout {
            Layout.alignment: Qt.AlignHCenter
            Layout.topMargin: 4
            spacing: 8
            Repeater {
                model: I18n.languages
                delegate: Rectangle {
                    required property var modelData
                    readonly property bool sel: I18n.lang === modelData.code
                    implicitWidth: lgt.implicitWidth + 26; implicitHeight: 32
                    radius: 16
                    color: sel ? Theme.accent : (lgm.containsMouse ? Theme.surface2 : Theme.surface1)
                    Behavior on color { ColorAnimation { duration: Theme.dur(120) } }
                    Text {
                        id: lgt
                        anchors.centerIn: parent
                        text: modelData.name
                        color: sel ? Theme.onAccent : Theme.text
                        font.family: Theme.fontFamily
                        font.pixelSize: Theme.fontSize - 1
                        font.bold: sel
                    }
                    MouseArea {
                        id: lgm
                        anchors.fill: parent
                        hoverEnabled: true
                        cursorShape: Qt.PointingHandCursor
                        onClicked: I18n.setLang(modelData.code)
                    }
                }
            }
        }

        // get started button
        Rectangle {
            Layout.alignment: Qt.AlignHCenter
            Layout.topMargin: 8
            implicitWidth: 180; implicitHeight: 44
            radius: Theme.radius
            color: gm.containsMouse ? Theme.accent2 : Theme.accent
            Behavior on color { ColorAnimation { duration: Theme.dur(120) } }
            scale: gm.pressed ? 0.96 : 1.0
            Behavior on scale { NumberAnimation { duration: Theme.dur(90) } }
            Text {
                anchors.centerIn: parent
                text: I18n.t("Get Started")
                color: Theme.onAccent
                font.family: Theme.fontFamily
                font.pixelSize: Theme.fontSize + 1
                font.bold: true
            }
            MouseArea {
                id: gm
                anchors.fill: parent
                hoverEnabled: true
                cursorShape: Qt.PointingHandCursor
                onClicked: win.dismiss()
            }
        }
    }
}
