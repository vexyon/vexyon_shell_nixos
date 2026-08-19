import QtQuick
import QtQuick.Effects
import qs.services

// ============================================================================
//  LauncherIcon — icono de la pastilla del lanzador de apps (y sus chips en
//  el gestor de widgets). Resuelve la clave cfg.icon a una de tres formas:
//   - glifo Nerd Font (iconos clásicos, logo de Hyprland, distros con glifo)
//   - imagen del sistema colorizada al tema (distros sin glifo NF, p.ej.
//     CachyOS → /usr/share/icons/cachyos.svg, como hace el launcher de DMS)
//   - marca Vexyon dibujada (la misma "V" en caja redondeada del Onboarding)
//  Todo tintado con `tint` para que respete la paleta activa de la pastilla.
// ============================================================================
Item {
    id: root
    property string iconKey: "grid"
    property real pixel: 15              // tamaño de fuente del glifo
    property color tint: Theme.text

    readonly property bool isVexyon: iconKey === "vexyon"
    readonly property string img: isVexyon ? "" : WidgetRegistry.launcherImage(iconKey)
    readonly property string glyph: (isVexyon || img !== "") ? "" : WidgetRegistry.launcherGlyph(iconKey)

    // mismo footprint (28px) que el component Glyph de WidgetView, para que
    // la métrica de la pastilla no cambie respecto a los iconos clásicos
    implicitWidth: 28
    implicitHeight: 28

    Text {
        visible: root.glyph !== ""
        anchors.centerIn: parent
        text: root.glyph
        color: root.tint
        font.family: Theme.fontFamily
        font.pixelSize: root.pixel
    }

    Image {
        visible: root.img !== ""
        anchors.centerIn: parent
        width: Math.round(root.pixel * 1.2)
        height: width
        source: root.img
        sourceSize: Qt.size(64, 64)
        smooth: true
        // colorización plana al tinte del tema (mismo truco que SystemLogo de
        // DMS): el logo hereda la paleta en vez de sus colores de fábrica
        layer.enabled: true
        layer.effect: MultiEffect {
            colorization: 1
            colorizationColor: root.tint
            brightness: 0.5   // mismo ajuste que el SystemLogo de DMS
        }
    }

    Rectangle {
        visible: root.isVexyon
        anchors.centerIn: parent
        width: Math.round(root.pixel * 1.15)
        height: width
        radius: Math.max(3, Math.round(width * 0.25))
        color: "transparent"
        border.width: Math.max(1, Math.round(root.pixel / 12))
        border.color: root.tint
        Text {
            anchors.centerIn: parent
            text: "V"
            color: root.tint
            font.family: Theme.fontFamily
            font.pixelSize: Math.max(8, Math.round(root.pixel * 0.62))
            font.bold: true
        }
    }
}
