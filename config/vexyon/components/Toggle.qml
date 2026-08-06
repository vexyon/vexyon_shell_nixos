import QtQuick
import qs.services

// Themed on/off switch. Emits toggled(bool).
Rectangle {
    id: root
    property bool checked: false
    signal toggled(bool value)

    implicitWidth: 44
    implicitHeight: 24
    radius: height / 2
    color: checked ? Theme.accent : Theme.surface2
    Behavior on color { ColorAnimation { duration: Theme.dur(140) } }

    Rectangle {
        id: knob
        width: 18; height: 18; radius: 9
        color: checked ? Theme.onAccent : Theme.text
        anchors.verticalCenter: parent.verticalCenter
        x: root.checked ? root.width - width - 3 : 3
        Behavior on x { NumberAnimation { duration: Theme.dur(140); easing.type: Theme.easing } }
    }

    MouseArea {
        anchors.fill: parent
        cursorShape: Qt.PointingHandCursor
        onClicked: { root.checked = !root.checked; root.toggled(root.checked); }
    }
}
