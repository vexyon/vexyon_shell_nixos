import QtQuick
import QtQuick.Layouts
import Quickshell.Widgets
import qs.services
import qs.components

// ============================================================================
//  MediaPanel — rediseño "cover hero" (S19; variaciones A/B/C documentadas en
//  PROJECT_STATE.md). La carátula es la cabecera de la tarjeta, fundida hacia
//  `base` con un degradado sobre el que viven título/artista y un chip con la
//  fuente MPRIS; debajo, scrubber fino con tiempos y transporte centrado con
//  play circular en acento. Sin carátula: fondo degradado + icono de nota.
//
//  Backend MPRIS (services/Media.qml) SIN cambios — solo presentación.
// ============================================================================
AnchoredPanel {
    id: mp
    panelKey: "mediaPlayer"
    ns: "vexyon-media"
    panelWidth: 400
    contentMargin: 0          // el cover llega al borde de la tarjeta
    accentColor: Theme.green

    content: Component {
        ColumnLayout {
            id: body
            width: mp.panelWidth
            spacing: 0
            property real introHeader: 1
            property real introContent: 1

            // Este contenido (slider + tiempos) es el único consumidor de la
            // posición MPRIS: mientras exista (panel abierto), Media emite el
            // refresco de posición cada 1s; cerrado, ni un tick.
            Component.onCompleted: Media.watchers++
            Component.onDestruction: Media.watchers--

            // ================= COVER HERO (fase introHeader) =================
            Item {
                id: hero
                Layout.fillWidth: true
                Layout.preferredHeight: 220
                opacity: body.introHeader

                // carátula a sangre (o fondo degradado si no hay), recortada al
                // radio de la tarjeta: el clip de QML es rectangular, así que
                // sin esto la esquina superior pinta CUADRADA por encima del
                // borde redondeado del AnchoredPanel (radius = Theme.radius+8).
                // El redondeo inferior del recorte queda oculto bajo el
                // degradado hacia base.
                ClippingRectangle {
                    anchors.fill: parent
                    radius: Theme.radius + 8
                    color: "transparent"
                    Image {
                        id: cover
                        anchors.fill: parent
                        source: Media.artUrl
                        fillMode: Image.PreserveAspectCrop
                        asynchronous: true
                        visible: status === Image.Ready && Media.artUrl !== ""
                    }
                    Rectangle {
                        anchors.fill: parent
                        visible: !cover.visible
                        gradient: Gradient {
                            GradientStop { position: 0.0; color: Qt.rgba(Theme.green.r, Theme.green.g, Theme.green.b, 0.16) }
                            GradientStop { position: 1.0; color: Theme.base }
                        }
                        Text {
                            anchors.centerIn: parent
                            anchors.verticalCenterOffset: -20
                            text: Icons.music
                            color: Qt.rgba(Theme.green.r, Theme.green.g, Theme.green.b, 0.5)
                            font.family: Theme.fontFamily
                            font.pixelSize: 64
                        }
                    }
                }

                // degradado de lectura: transparente → base (funde con la tarjeta)
                Rectangle {
                    anchors.fill: parent
                    gradient: Gradient {
                        GradientStop { position: 0.35; color: "transparent" }
                        GradientStop { position: 1.0; color: Theme.base }
                    }
                }

                // chip de fuente (identity MPRIS) arriba a la derecha
                Rectangle {
                    anchors.top: parent.top
                    anchors.right: parent.right
                    anchors.margins: 12
                    visible: Media.identity !== ""
                    width: srcRow.implicitWidth + 18
                    height: 24
                    radius: 12
                    color: Qt.rgba(Theme.base.r, Theme.base.g, Theme.base.b, 0.72)
                    border.width: 1
                    border.color: Qt.rgba(Theme.overlay0.r, Theme.overlay0.g, Theme.overlay0.b, 0.5)
                    RowLayout {
                        id: srcRow
                        anchors.centerIn: parent
                        spacing: 5
                        Text { text: Icons.music; color: Theme.green; font.family: Theme.fontFamily; font.pixelSize: Theme.fontSize - 5 }
                        Text {
                            text: Media.identity
                            color: Theme.subtext1
                            font.family: Theme.fontFamily
                            font.pixelSize: Theme.fontSize - 4
                        }
                    }
                }

                // título / artista sobre el degradado
                ColumnLayout {
                    anchors.left: parent.left
                    anchors.right: parent.right
                    anchors.bottom: parent.bottom
                    anchors.leftMargin: 18
                    anchors.rightMargin: 18
                    anchors.bottomMargin: 8
                    spacing: 2
                    Text {
                        Layout.fillWidth: true
                        text: Media.present ? (Media.title || I18n.t("Untitled")) : I18n.t("Nothing playing")
                        color: Theme.text
                        font.family: Theme.fontFamily
                        font.pixelSize: Theme.fontSize + 5
                        font.bold: true
                        elide: Text.ElideRight
                        maximumLineCount: 1
                    }
                    Text {
                        Layout.fillWidth: true
                        visible: Media.artist !== ""
                        text: Media.artist
                        color: Theme.subtext1
                        font.family: Theme.fontFamily
                        font.pixelSize: Theme.fontSize
                        elide: Text.ElideRight
                        maximumLineCount: 1
                    }
                }
            }

            // ================= CUERPO (fase introContent) ====================
            ColumnLayout {
                Layout.fillWidth: true
                Layout.leftMargin: 18
                Layout.rightMargin: 18
                Layout.topMargin: 10
                Layout.bottomMargin: 18
                spacing: 12
                opacity: body.introContent
                transform: Translate { y: 14 * (1 - body.introContent) }

                // ---- scrubber ----
                ColumnLayout {
                    Layout.fillWidth: true
                    visible: Media.present
                    spacing: 2
                    Slider {
                        Layout.fillWidth: true
                        value: Media.progress
                        fillColor: Theme.green
                        onMoved: function(v) { Media.seekTo(v); }
                    }
                    RowLayout {
                        Layout.fillWidth: true
                        Text { text: Media.fmtTime(Media.position); color: Theme.subtext0; font.family: Theme.fontFamily; font.pixelSize: Theme.fontSize - 3 }
                        Item { Layout.fillWidth: true }
                        Text { text: Media.fmtTime(Media.length); color: Theme.subtext0; font.family: Theme.fontFamily; font.pixelSize: Theme.fontSize - 3 }
                    }
                }

                // ---- transporte ----
                RowLayout {
                    Layout.alignment: Qt.AlignHCenter
                    spacing: 22
                    IconButton {
                        icon: Icons.stepBack
                        iconSize: Theme.fontSize + 5
                        implicitWidth: 42; implicitHeight: 42
                        enabled: Media.present
                        onClicked: Media.previous()
                    }
                    Rectangle {
                        Layout.preferredWidth: 56; Layout.preferredHeight: 56
                        radius: 28
                        color: Theme.green
                        scale: ppMa.pressed ? 0.92 : ppMa.containsMouse ? 1.05 : 1.0
                        Behavior on scale { NumberAnimation { duration: Theme.dur(90) } }
                        Text {
                            anchors.centerIn: parent
                            text: Media.playing ? Icons.pause : Icons.play
                            color: Theme.crust
                            font.family: Theme.fontFamily
                            font.pixelSize: Theme.fontSize + 9
                        }
                        MouseArea {
                            id: ppMa
                            anchors.fill: parent
                            hoverEnabled: true
                            cursorShape: Qt.PointingHandCursor
                            enabled: Media.present
                            onClicked: Media.toggle()
                        }
                    }
                    IconButton {
                        icon: Icons.stepForward
                        iconSize: Theme.fontSize + 5
                        implicitWidth: 42; implicitHeight: 42
                        enabled: Media.present
                        onClicked: Media.next()
                    }
                }
            }
        }
    }
}
