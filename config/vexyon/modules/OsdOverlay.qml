import QtQuick
import Quickshell
import Quickshell.Wayland
import qs.services

// ============================================================================
//  OsdOverlay — transient volume/brightness/mic pill, bottom-center of the
//  screen. Placement copies DankMaterialShell's OSD (centered, small margin
//  off the bottom edge, above everything, auto-hide + fade/scale exit); the
//  visual language is pure Vexyon: Theme tokens only, AnchoredPanel card look
//  (base bg, 1px surface0 border, Theme.radius). State lives in services/Osd;
//  this file only renders it.
// ============================================================================
Variants {
    model: Quickshell.screens

    PanelWindow {
        id: win

        required property var modelData
        screen: modelData

        readonly property bool showing: Osd.shown
        // keep the surface mapped through the exit animation, unmap when done
        visible: card.opacity > 0.01

        WlrLayershell.namespace: "vexyon-osd"
        WlrLayershell.layer: WlrLayer.Overlay
        WlrLayershell.exclusiveZone: -1
        WlrLayershell.keyboardFocus: WlrKeyboardFocus.None
        color: "transparent"

        // bottom-center, DMS-style margin; sit above the bar when it's bottom
        anchors.bottom: true
        margins.bottom: 12 + (Config.get("bar", "position", "top") === "bottom"
                              ? Theme.barHeight + Theme.barMarginTop : 0)

        implicitWidth: 300
        implicitHeight: 52

        readonly property bool isVol: Osd.kind === "volume"
        readonly property bool isBri: Osd.kind === "brightness"
        readonly property bool isMuted: isVol ? Audio.muted : (isBri ? false : Mic.muted)
        readonly property int  value: isVol ? Audio.percent : (isBri ? Brightness.percent : Mic.percent)
        readonly property string glyph: {
            if (isBri) return Icons.brightness;
            if (isVol) return Audio.muted ? Icons.volumeMute
                       : (Audio.percent < 40 ? Icons.volumeLow : Icons.volumeHigh);
            return Mic.muted ? Icons.micOff : Icons.microphone;
        }

        Rectangle {
            id: card
            anchors.fill: parent
            radius: Theme.radius + 8
            color: Theme.base
            border.width: 1
            border.color: Theme.surface0

            opacity: win.showing ? 1 : 0
            scale: win.showing ? 1 : 0.92
            Behavior on opacity { NumberAnimation { duration: Theme.dur(180); easing.type: Theme.easing } }
            Behavior on scale   { NumberAnimation { duration: Theme.dur(180); easing.type: Theme.easing } }

            Row {
                anchors.verticalCenter: parent.verticalCenter
                anchors.left: parent.left
                anchors.leftMargin: 18
                anchors.right: parent.right
                anchors.rightMargin: 16
                spacing: 12

                Text {
                    id: icon
                    anchors.verticalCenter: parent.verticalCenter
                    width: 20
                    horizontalAlignment: Text.AlignHCenter
                    text: win.glyph
                    color: win.isMuted ? Theme.overlay2 : Theme.accent
                    font.family: Theme.fontFamily
                    font.pixelSize: Theme.fontSize + 4
                }

                Rectangle {
                    id: track
                    anchors.verticalCenter: parent.verticalCenter
                    width: parent.width - icon.width - valueText.width - parent.spacing * 2
                    height: 6
                    radius: 3
                    color: Theme.surface1

                    Rectangle {
                        anchors.left: parent.left
                        anchors.verticalCenter: parent.verticalCenter
                        width: parent.width * Math.max(0, Math.min(1, win.value / 100))
                        height: parent.height
                        radius: parent.radius
                        color: win.isMuted ? Theme.overlay0 : Theme.accent
                        Behavior on width { NumberAnimation { duration: Theme.dur(120); easing.type: Theme.easing } }
                    }
                }

                Text {
                    id: valueText
                    anchors.verticalCenter: parent.verticalCenter
                    width: Math.max(38, implicitWidth)
                    horizontalAlignment: Text.AlignRight
                    text: win.isMuted ? I18n.t("Muted") : win.value + "%"
                    color: win.isMuted ? Theme.overlay2 : Theme.text
                    font.family: Theme.fontFamily
                    font.pixelSize: Theme.fontSize - 1
                    font.bold: true
                }
            }
        }
    }
}
