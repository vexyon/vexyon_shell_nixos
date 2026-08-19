import QtQuick
import qs.services

// Minimal themed slider. value in [0,1]. Emits moved(v) live while dragging.
Item {
    id: root
    property real value: 0.5
    property color fillColor: Theme.accent
    signal moved(real v)

    implicitHeight: 20
    implicitWidth: 160

    Rectangle {
        id: track
        anchors.verticalCenter: parent.verticalCenter
        width: parent.width
        height: 6
        radius: 3
        color: Theme.surface2

        Rectangle {
            width: Math.max(handle.width / 2, root.value * parent.width)
            height: parent.height
            radius: 3
            color: root.fillColor
        }
    }

    Rectangle {
        id: handle
        width: 16; height: 16; radius: 8
        color: Theme.text
        border.width: 2
        border.color: root.fillColor
        anchors.verticalCenter: parent.verticalCenter
        x: Math.max(0, Math.min(root.width - width, root.value * root.width - width / 2))
        scale: ma.pressed ? 1.15 : 1.0
        Behavior on scale { NumberAnimation { duration: Theme.dur(80) } }
    }

    MouseArea {
        id: ma
        anchors.fill: parent
        anchors.margins: -6
        cursorShape: Qt.PointingHandCursor
        function apply(mx) {
            var v = Math.max(0, Math.min(1, mx / root.width));
            root.value = v;
            root.moved(v);
        }
        onPressed: function(m) { apply(m.x) }
        onPositionChanged: function(m) { if (pressed) apply(m.x) }
    }
}
