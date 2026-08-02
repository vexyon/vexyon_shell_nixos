import QtQuick
import qs.services

// A tappable icon (Nerd Font glyph) with hover highlight and press feedback.
Rectangle {
    id: btn

    property string icon: ""
    property int iconSize: Theme.fontSize + 3
    property color iconColor: Theme.text
    property color hoverColor: Theme.surface2
    property real radiusFactor: 0.6
    property alias containsMouse: ma.containsMouse
    signal clicked()
    signal rightClicked()
    signal wheel(real delta)

    implicitWidth: 30
    implicitHeight: 30
    radius: Theme.radius * radiusFactor
    color: ma.containsMouse ? hoverColor : "transparent"
    Behavior on color { ColorAnimation { duration: Theme.dur(120); easing.type: Theme.easing } }

    scale: ma.pressed ? 0.9 : 1.0
    Behavior on scale { NumberAnimation { duration: Theme.dur(90); easing.type: Theme.easing } }

    Text {
        anchors.centerIn: parent
        text: btn.icon
        color: btn.iconColor
        font.family: Theme.fontFamily
        font.pixelSize: btn.iconSize
    }

    MouseArea {
        id: ma
        anchors.fill: parent
        hoverEnabled: true
        cursorShape: Qt.PointingHandCursor
        acceptedButtons: Qt.LeftButton | Qt.RightButton
        onClicked: function(mouse) {
            if (mouse.button === Qt.RightButton) btn.rightClicked();
            else btn.clicked();
        }
        onWheel: function(w) { btn.wheel(w.angleDelta.y); }
    }
}
