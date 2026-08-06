import QtQuick
import QtQuick.Layouts
import Quickshell
import qs.services
import qs.components

// Browse bundled themes with live swatches; click applies instantly (zero
// restart) via Theme.apply -> writes shell.json -> every token rebinds live.
Flickable {
    id: root
    contentHeight: grid.implicitHeight + 20
    clip: true
    boundsBehavior: Flickable.StopAtBounds

    Component.onCompleted: Theme.refreshThemes()

    GridLayout {
        id: grid
        width: root.width
        columns: Math.max(1, Math.floor(root.width / 200))
        columnSpacing: 10
        rowSpacing: 10

        Repeater {
            model: Theme.available
            delegate: Card {
                id: swatch
                required property var modelData
                readonly property bool active: modelData.id === Theme.activeId
                Layout.fillWidth: true
                Layout.preferredHeight: 92
                color: Theme.surface0
                border.width: active ? 2 : 1
                border.color: active ? Theme.accent : Theme.overlay0
                elevated: false

                MouseArea {
                    anchors.fill: parent
                    cursorShape: Qt.PointingHandCursor
                    onClicked: Theme.apply(swatch.modelData.id)
                }

                ColumnLayout {
                    anchors.fill: parent
                    anchors.margins: 12
                    spacing: 8

                    RowLayout {
                        Layout.fillWidth: true
                        Text {
                            Layout.fillWidth: true
                            text: swatch.modelData.name || swatch.modelData.id
                            color: Theme.text
                            font.family: Theme.fontFamily
                            font.pixelSize: Theme.fontSize
                            font.bold: true
                            elide: Text.ElideRight
                        }
                        Text {
                            visible: swatch.active
                            text: ""
                            color: Theme.accent
                            font.family: Theme.fontFamily
                            font.pixelSize: Theme.fontSize
                        }
                    }

                    // preview swatch row
                    Row {
                        spacing: 6
                        Repeater {
                            model: [ swatch.modelData.colors.base,
                                     swatch.modelData.colors.surface0,
                                     swatch.modelData.colors.text,
                                     swatch.modelData.colors.accent ]
                            delegate: Rectangle {
                                required property var modelData
                                width: 26; height: 26; radius: 6
                                color: modelData || "#000000"
                                border.width: 1
                                border.color: Qt.rgba(1, 1, 1, 0.12)
                            }
                        }
                    }
                }
            }
        }
    }
}
