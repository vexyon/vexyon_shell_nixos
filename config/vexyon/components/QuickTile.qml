import QtQuick
import QtQuick.Layouts
import qs.services

// DankMaterialShell-style quick toggle tile: rounded square icon + title +
// subtitle. Active tiles fill with the accent. Used in the QuickSettings grid.
Rectangle {
    id: tile
    property string icon: ""
    property string title: ""
    property string subtitle: ""
    property bool active: false
    property bool interactive: true
    signal clicked()
    signal secondaryClicked()

    // Always fill its layout cell and never let a long title inflate the tile's
    // implicit width: without this, in a multi-column GridLayout the columns'
    // intrinsic widths summed past the content box and the tiles spilled out of
    // the panel's rounded edge (clipped flat by the card). preferredWidth 1 +
    // fillWidth makes the layout distribute the available width evenly instead,
    // and the inner labels elide within the bounded cell.
    Layout.fillWidth: true
    Layout.preferredWidth: 1

    implicitHeight: 62
    radius: Theme.radius + 2
    color: active ? Theme.accent : Theme.surface0
    Behavior on color { ColorAnimation { duration: Theme.dur(140) } }
    border.width: active ? 0 : 1
    border.color: Theme.overlay0

    readonly property color fg: active ? Theme.onAccent : Theme.text
    readonly property color fg2: active ? Qt.rgba(Theme.onAccent.r, Theme.onAccent.g, Theme.onAccent.b, 0.7)
                                        : Theme.subtext0

    RowLayout {
        anchors.fill: parent
        anchors.leftMargin: 10
        anchors.rightMargin: 12
        spacing: 10

        Rectangle {
            Layout.alignment: Qt.AlignVCenter
            Layout.preferredWidth: 38; Layout.preferredHeight: 38; radius: 11
            color: tile.active ? Qt.rgba(Theme.onAccent.r, Theme.onAccent.g, Theme.onAccent.b, 0.16)
                               : Theme.surface2
            Text {
                anchors.centerIn: parent
                text: tile.icon
                color: tile.fg
                font.family: Theme.fontFamily
                font.pixelSize: Theme.fontSize + 3
            }
        }

        ColumnLayout {
            Layout.fillWidth: true
            spacing: 0
            Text {
                Layout.fillWidth: true
                text: tile.title
                color: tile.fg
                font.family: Theme.fontFamily
                font.pixelSize: Theme.fontSize - 1
                font.bold: true
                elide: Text.ElideRight
            }
            Text {
                Layout.fillWidth: true
                visible: tile.subtitle !== ""
                text: tile.subtitle
                color: tile.fg2
                font.family: Theme.fontFamily
                font.pixelSize: Theme.fontSize - 4
                elide: Text.ElideRight
            }
        }
    }

    MouseArea {
        anchors.fill: parent
        enabled: tile.interactive
        hoverEnabled: true
        cursorShape: Qt.PointingHandCursor
        acceptedButtons: Qt.LeftButton | Qt.RightButton
        onPressed: tile.scale = 0.97
        onReleased: tile.scale = 1.0
        onCanceled: tile.scale = 1.0
        onClicked: function(m) { if (m.button === Qt.RightButton) tile.secondaryClicked(); else tile.clicked(); }
    }

    Behavior on scale { NumberAnimation { duration: Theme.dur(90) } }
}
