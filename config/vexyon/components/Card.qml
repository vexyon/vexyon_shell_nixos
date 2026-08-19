import QtQuick
import QtQuick.Effects
import qs.services

// Themed rounded surface with optional soft elevation shadow.
// Blur is never used here (prohibited on popups/windows); only a drop shadow.
Rectangle {
    id: card
    radius: Theme.radius
    color: Theme.surface0
    border.width: Theme.elevation ? 0 : 1
    border.color: Theme.overlay0

    property bool elevated: Theme.elevation
    property color shadowColor: Qt.rgba(0, 0, 0, 0.45)

    layer.enabled: elevated
    layer.effect: MultiEffect {
        shadowEnabled: true
        shadowColor: card.shadowColor
        shadowBlur: 0.55
        shadowVerticalOffset: 4
        autoPaddingEnabled: true
    }
}
