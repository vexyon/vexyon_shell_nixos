import QtQuick
import QtQuick.Layouts
import qs.services
import qs.components

// Browse bundled themes with live swatches; click applies instantly (zero
// restart) via Theme.apply -> writes shell.json -> every token rebinds live.
// Above them, the bar STYLE (form only: BarStyles.apply writes bar.* keys the
// same way). Two independent choices: a style never changes a colour.
Flickable {
    id: root
    contentHeight: page.implicitHeight + 20
    clip: true
    boundsBehavior: Flickable.StopAtBounds

    Component.onCompleted: Theme.refreshThemes()

    component Header: Text {
        Layout.fillWidth: true
        Layout.topMargin: 4
        color: Theme.subtext1
        font.family: Theme.fontFamily
        font.pixelSize: Theme.fontSize - 1
        font.bold: true
    }

    ColumnLayout {
    id: page
    width: root.width
    spacing: 10

    Header { text: I18n.t("Bar style") }
    Text {
        Layout.fillWidth: true
        wrapMode: Text.WordWrap
        text: I18n.t("Shape and spacing only; colors always come from the theme.")
        color: Theme.subtext0
        font.family: Theme.fontFamily
        font.pixelSize: Theme.fontSize - 3
    }

    GridLayout {
        Layout.fillWidth: true
        columns: Math.max(1, Math.min(BarStyles.ids.length, Math.floor(root.width / 200)))
        columnSpacing: 10
        rowSpacing: 10

        Repeater {
            model: BarStyles.ids
            delegate: Card {
                id: sc
                required property var modelData
                readonly property var p: BarStyles.presets[modelData]
                readonly property bool active: modelData === BarStyles.active
                Layout.fillWidth: true
                Layout.preferredHeight: 128
                color: Theme.surface0
                border.width: active ? 2 : 1
                border.color: active ? Theme.accent : Theme.overlay0
                elevated: false

                MouseArea {
                    anchors.fill: parent
                    cursorShape: Qt.PointingHandCursor
                    onClicked: BarStyles.apply(sc.modelData)
                }

                ColumnLayout {
                    anchors.fill: parent
                    anchors.margins: 12
                    spacing: 6

                    // miniatura: la parte de arriba de un escritorio con la
                    // barra dibujada a partir de los MISMOS valores del preset
                    // (escala 1/2) y en los tokens del tema activo
                    Rectangle {
                        id: mini
                        Layout.fillWidth: true
                        Layout.preferredHeight: 36
                        radius: 6
                        // "escritorio" en un tono medio para que la barra (base)
                        // y sus huecos se lean en temas claros y oscuros
                        color: Theme.overlay0
                        clip: true
                        readonly property real k: 0.5
                        readonly property int bh: Math.round(sc.p.barSize * k)
                        readonly property int gap: Math.round(sc.p.edgeGap * k)
                        readonly property int side: Math.round(sc.p.marginSides * k)
                        readonly property int rad: Math.round(Math.min(sc.p.cornerRadius, sc.p.barSize / 2) * k)
                        readonly property color bg: Qt.rgba(Theme.base.r, Theme.base.g, Theme.base.b, sc.p.bgOpacity)
                        readonly property bool flatW: sc.p.widgetShape === "flat"
                        readonly property int fil: sc.p.edgeFillets ? Math.round(Theme.radius * k) : 0
                        readonly property int ipad: Math.round(sc.p.padding * k)

                        // franja continua (todo menos islas)
                        Rectangle {
                            id: strip
                            visible: !sc.p.islands
                            x: mini.side; y: mini.gap
                            width: mini.width - 2 * mini.side; height: mini.bh
                            radius: mini.rad
                            color: mini.bg
                            border.width: sc.p.border ? (sc.p.borderColor === "accent" ? 1.5 : 1) : 0
                            border.color: sc.p.borderColor === "accent" ? Theme.accent : Theme.overlay0
                        }
                        ConcaveCorner {
                            visible: mini.fil > 0
                            size: mini.fil; color: mini.bg
                            x: strip.x; y: strip.y + strip.height
                        }
                        ConcaveCorner {
                            visible: mini.fil > 0
                            size: mini.fil; color: mini.bg; rotation: 90
                            x: strip.x + strip.width - size; y: strip.y + strip.height
                        }

                        // tres secciones: inicio (workspaces + 1), centro (1), fin (3)
                        Repeater {
                            model: [ { a: "start", n: 2 }, { a: "center", n: 1 }, { a: "end", n: 3 } ]
                            delegate: Item {
                                id: ms
                                required property var modelData
                                readonly property int unit: mini.flatW ? 9 : 18
                                readonly property int sgap: Math.max(2, Math.round(sc.p.pillGap * mini.k) + 1)
                                readonly property int wsW: sc.p.workspaceStyle === "dot" ? 15 : 22
                                width: (ms.modelData.a === "start" ? ms.wsW + ms.sgap : 0)
                                       + ms.modelData.n * ms.unit + (ms.modelData.n - 1) * ms.sgap
                                height: mini.bh
                                y: mini.gap
                                x: ms.modelData.a === "start" ? mini.side + mini.ipad
                                 : ms.modelData.a === "end" ? mini.width - mini.side - mini.ipad - width
                                 : (mini.width - width) / 2

                                // isla hoja (misma regla que BarSection)
                                Rectangle {
                                    visible: sc.p.islands
                                    readonly property int big: mini.rad
                                    readonly property int small: Math.round(mini.rad / 4)
                                    x: -mini.ipad; width: parent.width + 2 * mini.ipad; height: parent.height
                                    color: mini.bg
                                    topLeftRadius: ms.modelData.a === "end" ? small : big
                                    bottomRightRadius: ms.modelData.a === "end" ? small : big
                                    topRightRadius: ms.modelData.a === "start" ? small : big
                                    bottomLeftRadius: ms.modelData.a === "start" ? small : big
                                }
                                Row {
                                    anchors.verticalCenter: parent.verticalCenter
                                    spacing: ms.sgap
                                    // workspaces: píldora con tres puntos o puntos sueltos
                                    Row {
                                        visible: ms.modelData.a === "start"
                                        anchors.verticalCenter: parent.verticalCenter
                                        spacing: 2
                                        Repeater {
                                            model: 3
                                            delegate: Rectangle {
                                                id: mws
                                                required property int index
                                                readonly property bool dot: sc.p.workspaceStyle === "dot"
                                                width: dot ? (mws.index === 0 ? 7 : 3) : (mws.index === 0 ? 10 : 5)
                                                height: dot ? 3 : 5
                                                radius: height / 2
                                                anchors.verticalCenter: parent.verticalCenter
                                                color: mws.index === 0 ? Theme.accent : Theme.surface2
                                            }
                                        }
                                    }
                                    Repeater {
                                        model: ms.modelData.n
                                        delegate: Item {
                                            id: mw
                                            required property int index
                                            width: ms.unit
                                            height: mini.bh
                                            Rectangle {   // pastilla o nada (plano)
                                                visible: !mini.flatW
                                                anchors.centerIn: parent
                                                width: parent.width; height: Math.max(4, mini.bh - 5)
                                                radius: Math.min(mini.rad, height / 2) || 2
                                                color: Theme.surface1
                                            }
                                            Rectangle {   // el "icono"
                                                anchors.centerIn: parent
                                                width: 5; height: 5; radius: 2.5
                                                color: Theme.accentFg
                                            }
                                            Rectangle {   // separador
                                                visible: sc.p.separators && (mw.index > 0 || ms.modelData.a === "start")
                                                width: 1; height: Math.round(mini.bh * 0.5)
                                                anchors.verticalCenter: parent.verticalCenter
                                                x: -Math.round((ms.sgap + 1) / 2)
                                                color: Theme.overlay0
                                            }
                                        }
                                    }
                                }
                            }
                        }
                    }

                    RowLayout {
                        Layout.fillWidth: true
                        Text {
                            Layout.fillWidth: true
                            text: I18n.t(BarStyles.names[sc.modelData])
                            color: Theme.text
                            font.family: Theme.fontFamily
                            font.pixelSize: Theme.fontSize
                            font.bold: true
                            elide: Text.ElideRight
                        }
                        Text {
                            visible: sc.active
                            text: ""
                            color: Theme.accent
                            font.family: Theme.fontFamily
                            font.pixelSize: Theme.fontSize
                        }
                    }
                    Text {
                        Layout.fillWidth: true
                        Layout.fillHeight: true
                        text: I18n.t(BarStyles.descriptions[sc.modelData])
                        color: Theme.subtext0
                        wrapMode: Text.WordWrap
                        elide: Text.ElideRight
                        maximumLineCount: 2
                        font.family: Theme.fontFamily
                        font.pixelSize: Theme.fontSize - 3
                    }
                }
            }
        }
    }

    Header { text: I18n.t("Color theme"); Layout.topMargin: 10 }

    GridLayout {
        id: grid
        Layout.fillWidth: true
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
}
