import QtQuick
import QtQuick.Layouts
import Quickshell
import Quickshell.Wayland
import qs.services
import qs.components

// ============================================================================
//  MonitorRevertDialog — ventana de confirmación con cuenta atrás tras un
//  cambio de configuración de monitor. El cambio ya se aplicó en vivo; si el
//  usuario no confirma en 10s, Displays revierte solo a la última config buena
//  (patrón GNOME/Windows: evita quedarse con una pantalla inutilizable).
//  Se muestra por ENCIMA de todo (capa Overlay, ignora zonas exclusivas) para
//  que sea visible aunque Ajustes se cierre. Enter confirma, Esc revierte.
// ============================================================================
PanelWindow {
    id: win
    visible: Displays.pendingRevert

    WlrLayershell.namespace: "vexyon-monitor-revert"
    WlrLayershell.layer: WlrLayer.Overlay
    WlrLayershell.exclusiveZone: -1
    WlrLayershell.keyboardFocus: visible ? WlrKeyboardFocus.Exclusive : WlrKeyboardFocus.None
    color: "transparent"
    anchors { top: true; bottom: true; left: true; right: true }

    // dim de fondo (no captura el click-away a propósito: forzar una decisión)
    Rectangle {
        anchors.fill: parent
        color: Qt.rgba(0, 0, 0, 0.45)
    }

    Item {
        anchors.fill: parent
        focus: win.visible
        Keys.onReturnPressed: Displays.confirmChange()
        Keys.onEnterPressed: Displays.confirmChange()
        Keys.onEscapePressed: Displays.revertChange()
    }

    Card {
        anchors.centerIn: parent
        width: 440
        implicitHeight: col.implicitHeight + 44
        color: Theme.base
        radius: Theme.radius + 4

        ColumnLayout {
            id: col
            anchors.fill: parent
            anchors.margins: 24
            spacing: 16

            RowLayout {
                Layout.fillWidth: true
                spacing: 12
                Text {
                    text: Icons.desktop
                    color: Theme.accent
                    font.family: Theme.fontFamily
                    font.pixelSize: Theme.fontSize + 6
                }
                Text {
                    Layout.fillWidth: true
                    text: I18n.t("Keep this display configuration?")
                    color: Theme.text
                    font.family: Theme.fontFamily
                    font.pixelSize: Theme.fontSize + 2
                    font.bold: true
                    wrapMode: Text.WordWrap
                }
            }

            Text {
                Layout.fillWidth: true
                text: I18n.t("Will revert to the previous configuration in ")
                      + Displays.revertSeconds + " s si no confirmas."
                color: Theme.subtext0
                font.family: Theme.fontFamily
                font.pixelSize: Theme.fontSize - 1
                wrapMode: Text.WordWrap
            }

            // barra de cuenta atrás
            Rectangle {
                Layout.fillWidth: true
                Layout.preferredHeight: 6
                radius: 3
                color: Theme.surface2
                Rectangle {
                    height: parent.height
                    radius: 3
                    width: parent.width * (Displays.revertSeconds / 10.0)
                    color: Theme.accent
                    Behavior on width { NumberAnimation { duration: 900; easing.type: Easing.Linear } }
                }
            }

            RowLayout {
                Layout.fillWidth: true
                Layout.topMargin: 4
                spacing: 10
                Item { Layout.fillWidth: true }
                Rectangle {
                    Layout.preferredWidth: 130; Layout.preferredHeight: 40
                    radius: Theme.radius
                    color: revMa.containsMouse ? Theme.surface2 : Theme.surface1
                    Text {
                        anchors.centerIn: parent
                        text: I18n.t("Revert")
                        color: Theme.text
                        font.family: Theme.fontFamily; font.pixelSize: Theme.fontSize
                    }
                    MouseArea {
                        id: revMa
                        anchors.fill: parent; hoverEnabled: true; cursorShape: Qt.PointingHandCursor
                        onClicked: Displays.revertChange()
                    }
                }
                Rectangle {
                    Layout.preferredWidth: 150; Layout.preferredHeight: 40
                    radius: Theme.radius
                    color: keepMa.containsMouse ? Theme.accent2 : Theme.accent
                    Text {
                        anchors.centerIn: parent
                        text: I18n.t("Keep (") + Displays.revertSeconds + ")"
                        color: Theme.onAccent
                        font.family: Theme.fontFamily; font.pixelSize: Theme.fontSize; font.bold: true
                    }
                    MouseArea {
                        id: keepMa
                        anchors.fill: parent; hoverEnabled: true; cursorShape: Qt.PointingHandCursor
                        onClicked: Displays.confirmChange()
                    }
                }
            }
        }
    }
}
