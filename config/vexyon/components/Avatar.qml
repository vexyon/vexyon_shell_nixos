import QtQuick
import Quickshell
import Quickshell.Widgets
import qs.services

// ============================================================================
//  Avatar — círculo de perfil reutilizable. Muestra la foto del usuario
//  (Profile.url) recortada en círculo si está configurada y carga bien; si no,
//  cae a la inicial del usuario. Usado en el lock screen y en las tarjetas de
//  perfil (Ajustes, QuickSettings, LockScreen).
// ============================================================================
Item {
    id: a

    property int size: 48
    property string fallbackText: (Quickshell.env("USER") || "?").charAt(0).toUpperCase()
    property color fallbackColor: Theme.accent
    property color bg: Theme.surface2
    property color borderColor: Theme.accent
    property int borderWidth: 2
    property real fallbackScale: 0.42   // tamaño de la inicial relativo al círculo

    implicitWidth: size
    implicitHeight: size

    // círculo con recorte real (ClippingRectangle recorta al radio)
    ClippingRectangle {
        anchors.fill: parent
        radius: width / 2
        color: a.bg

        Text {
            anchors.centerIn: parent
            visible: !avatarImg.showing
            text: a.fallbackText
            color: a.fallbackColor
            font.family: Theme.fontFamily
            font.pixelSize: Math.round(a.size * a.fallbackScale)
            font.bold: true
        }
        Image {
            id: avatarImg
            anchors.fill: parent
            readonly property bool showing: Profile.hasAvatar && status === Image.Ready
            source: Profile.url
            visible: showing
            fillMode: Image.PreserveAspectCrop
            asynchronous: true
            cache: false
            sourceSize.width: a.size * 2
            sourceSize.height: a.size * 2
        }
    }
    // aro de borde por encima (ClippingRectangle no dibuja borde)
    Rectangle {
        anchors.fill: parent
        radius: width / 2
        color: "transparent"
        border.width: a.borderWidth
        border.color: a.borderColor
        Behavior on border.color { ColorAnimation { duration: Theme.dur(300) } }
    }
}
