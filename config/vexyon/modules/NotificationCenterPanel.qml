import QtQuick
import QtQuick.Layouts
import Quickshell
import Quickshell.Widgets
import qs.services
import qs.components

// ============================================================================
//  NotificationCenterPanel — anchored dropdown from the notifications widget.
//  Recent notifications (newest first) with per-item dismiss, a Do-Not-Disturb
//  toggle and a clear-all action.
// ============================================================================
AnchoredPanel {
    id: nc
    panelKey: "notifCenter"
    ns: "vexyon-notifications"
    panelWidth: 420
    accentColor: Theme.mauve

    content: Component {
        ColumnLayout {
            id: body
            width: nc.panelWidth - nc.contentMargin * 2
            spacing: 12
            property real introHeader: 1
            property real introContent: 1

            // header (fase introHeader)
            RowLayout {
                Layout.fillWidth: true
                spacing: 10
                opacity: body.introHeader
                transform: Translate { y: 14 * (1 - body.introHeader) }
                Text {
                    Layout.fillWidth: true
                    text: I18n.t("Notifications") + (Notifications.count > 0 ? "  (" + Notifications.count + ")" : "")
                    color: Theme.text; font.family: Theme.fontFamily; font.pixelSize: Theme.fontSize + 2; font.bold: true
                }
                // DND toggle
                RowLayout {
                    spacing: 6
                    Text { text: Notifications.dnd ? Icons.bellOff : Icons.bell; color: Notifications.dnd ? Theme.overlay2 : Theme.subtext1; font.family: Theme.fontFamily; font.pixelSize: Theme.fontSize }
                    Toggle { checked: Notifications.dnd; onToggled: function(v) { Notifications.toggleDnd(); } }
                }
                IconButton {
                    icon: Icons.trash !== undefined ? Icons.trash : Icons.close
                    iconSize: Theme.fontSize; implicitWidth: 28; implicitHeight: 28
                    enabled: Notifications.count > 0
                    onClicked: Notifications.clearAll()
                }
            }
            Rectangle { Layout.fillWidth: true; height: 1; color: Theme.overlay0; opacity: 0.4 }

            // DND banner
            Rectangle {
                Layout.fillWidth: true; visible: Notifications.dnd
                Layout.preferredHeight: 38; radius: Theme.radius
                color: Qt.rgba(Theme.yellow.r, Theme.yellow.g, Theme.yellow.b, 0.14)
                RowLayout {
                    anchors.fill: parent; anchors.leftMargin: 12; spacing: 8
                    Text { text: Icons.bellOff; color: Theme.yellow; font.family: Theme.fontFamily; font.pixelSize: Theme.fontSize }
                    Text { text: I18n.t("Do not disturb on"); color: Theme.subtext1; font.family: Theme.fontFamily; font.pixelSize: Theme.fontSize - 2 }
                }
            }

            // list (cap at 8 shown; column grows the card) — fase introContent
            ColumnLayout {
                Layout.fillWidth: true; spacing: 8
                opacity: body.introContent
                transform: Translate { y: 18 * (1 - body.introContent) }
                Repeater {
                    model: Notifications.list.slice(0, 8)
                    delegate: Rectangle {
                        id: nrow
                        required property var modelData
                        Layout.fillWidth: true
                        implicitHeight: Math.max(56, nrowCol.implicitHeight + 20)
                        radius: Theme.radius; color: Theme.surface0
                        RowLayout {
                            anchors.fill: parent; anchors.margins: 10; spacing: 10
                            // app image / icon
                            Rectangle {
                                Layout.preferredWidth: 36; Layout.preferredHeight: 36; Layout.alignment: Qt.AlignTop
                                radius: 10; color: Theme.surface2; clip: true
                                Image {
                                    anchors.fill: parent; fillMode: Image.PreserveAspectCrop; asynchronous: true
                                    source: nrow.modelData.image || nrow.modelData.appIcon || ""
                                    visible: (nrow.modelData.image || nrow.modelData.appIcon || "") !== ""
                                }
                                Text {
                                    anchors.centerIn: parent
                                    visible: (nrow.modelData.image || nrow.modelData.appIcon || "") === ""
                                    text: Icons.bell; color: Theme.overlay2; font.family: Theme.fontFamily; font.pixelSize: Theme.fontSize + 2
                                }
                            }
                            ColumnLayout {
                                id: nrowCol
                                Layout.fillWidth: true; spacing: 2
                                RowLayout {
                                    Layout.fillWidth: true
                                    Text {
                                        Layout.fillWidth: true
                                        text: nrow.modelData.appName || I18n.t("Notification")
                                        color: Theme.accent; font.family: Theme.fontFamily; font.pixelSize: Theme.fontSize - 3; font.bold: true
                                        elide: Text.ElideRight
                                    }
                                }
                                Text {
                                    Layout.fillWidth: true; visible: (nrow.modelData.summary || "") !== ""
                                    text: nrow.modelData.summary || ""
                                    color: Theme.text; font.family: Theme.fontFamily; font.pixelSize: Theme.fontSize - 1; font.bold: true
                                    elide: Text.ElideRight; maximumLineCount: 1
                                }
                                Text {
                                    Layout.fillWidth: true; visible: (nrow.modelData.body || "") !== ""
                                    text: nrow.modelData.body || ""
                                    color: Theme.subtext0; font.family: Theme.fontFamily; font.pixelSize: Theme.fontSize - 3
                                    wrapMode: Text.WordWrap; maximumLineCount: 3; elide: Text.ElideRight
                                }
                            }
                            IconButton {
                                icon: Icons.close; iconSize: Theme.fontSize - 2; implicitWidth: 24; implicitHeight: 24
                                Layout.alignment: Qt.AlignTop
                                onClicked: Notifications.dismiss(nrow.modelData)
                            }
                        }
                    }
                }
                // empty state
                ColumnLayout {
                    Layout.fillWidth: true; visible: Notifications.count === 0; spacing: 6
                    Layout.topMargin: 10; Layout.bottomMargin: 14
                    Text { Layout.alignment: Qt.AlignHCenter; text: Icons.bell; color: Theme.overlay1; font.family: Theme.fontFamily; font.pixelSize: 30 }
                    Text { Layout.alignment: Qt.AlignHCenter; text: I18n.t("No notifications"); color: Theme.overlay2; font.family: Theme.fontFamily; font.pixelSize: Theme.fontSize - 1 }
                }
            }
        }
    }
}
