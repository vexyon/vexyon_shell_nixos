import QtQuick
import QtQuick.Layouts
import Quickshell
import qs.services
import qs.components

// ============================================================================
//  WeatherPanel — anchored dropdown from the weather bar widget. Shows the
//  current temperature + condition, a month calendar on the left, an hourly
//  forecast as a connected timeline, and stat rings (wind / humidity / rain /
//  feels-like) along the bottom. Data from the Weather service (wttr.in j1).
// ============================================================================
AnchoredPanel {
    id: wp
    panelKey: "weatherPanel"
    ns: "vexyon-weather"
    panelWidth: 760
    accentColor: Theme.blue

    onShownChanged: if (shown && !Weather.ok) Weather.refresh()

    content: Component {
        ColumnLayout {
            id: body
            width: wp.panelWidth - wp.contentMargin * 2
            spacing: 16
            property real introHeader: 1
            property real introContent: 1

            // ---- reusable stat ring ----
            component StatRing: ColumnLayout {
                property real value: 0        // 0-100
                property string center: ""
                property string caption: ""
                property color ringColor: Theme.accent
                spacing: 4
                Layout.fillWidth: true
                Canvas {
                    Layout.alignment: Qt.AlignHCenter
                    width: 64; height: 64
                    property real v: Math.max(0, Math.min(100, parent.value))
                    property color rc: parent.ringColor
                    onVChanged: requestPaint()
                    onRcChanged: requestPaint()
                    Component.onCompleted: requestPaint()
                    onPaint: {
                        var ctx = getContext("2d");
                        ctx.reset();
                        var cx = width / 2, cy = height / 2, r = 26;
                        ctx.lineWidth = 5; ctx.lineCap = "round";
                        ctx.beginPath();
                        ctx.arc(cx, cy, r, 0, Math.PI * 2);
                        ctx.strokeStyle = Qt.rgba(Theme.overlay0.r, Theme.overlay0.g, Theme.overlay0.b, 0.5);
                        ctx.stroke();
                        if (v > 0) {
                            ctx.beginPath();
                            ctx.arc(cx, cy, r, -Math.PI / 2, -Math.PI / 2 + Math.PI * 2 * (v / 100));
                            ctx.strokeStyle = rc;
                            ctx.stroke();
                        }
                    }
                    Text {
                        anchors.centerIn: parent
                        text: parent.parent.center; color: Theme.text
                        font.family: Theme.fontFamily; font.pixelSize: Theme.fontSize - 1; font.bold: true
                    }
                }
                Text {
                    Layout.alignment: Qt.AlignHCenter
                    text: parent.caption; color: Theme.subtext0
                    font.family: Theme.fontFamily; font.pixelSize: Theme.fontSize - 4
                }
            }

            // ================= TOP ROW (fase introHeader) =================
            RowLayout {
                Layout.fillWidth: true
                spacing: 18
                opacity: body.introHeader
                transform: Translate { y: 16 * (1 - body.introHeader) }

                // calendar
                Rectangle {
                    Layout.preferredWidth: 250
                    Layout.alignment: Qt.AlignTop
                    implicitHeight: calCol.implicitHeight + 24
                    radius: Theme.radius; color: Theme.surface0
                    ColumnLayout { id: calCol; anchors.fill: parent; anchors.margins: 12; MiniCalendar { Layout.fillWidth: true } }
                }

                // hourly timeline
                ColumnLayout {
                    Layout.fillWidth: true
                    Layout.alignment: Qt.AlignVCenter
                    spacing: 8
                    Text {
                        text: Weather.ok ? (Weather.area !== "" ? Weather.area : I18n.t("Forecast")) : I18n.t("No weather data")
                        color: Theme.subtext1; font.family: Theme.fontFamily; font.pixelSize: Theme.fontSize - 1
                    }
                    Item {
                        Layout.fillWidth: true
                        implicitHeight: 92
                        // connecting line behind the glyphs
                        Rectangle {
                            anchors.left: parent.left; anchors.right: parent.right
                            anchors.leftMargin: 20; anchors.rightMargin: 20
                            y: 44; height: 2; radius: 1
                            color: Qt.rgba(Theme.overlay0.r, Theme.overlay0.g, Theme.overlay0.b, 0.6)
                        }
                        Row {
                            anchors.fill: parent
                            Repeater {
                                model: Weather.hourly
                                delegate: Column {
                                    required property var modelData
                                    width: Math.max(1, parent.width / Math.max(1, Weather.hourly.length))
                                    spacing: 4
                                    Text {
                                        anchors.horizontalCenter: parent.horizontalCenter
                                        text: modelData.time; color: Theme.subtext0
                                        font.family: Theme.fontFamily; font.pixelSize: Theme.fontSize - 4
                                    }
                                    Text {
                                        anchors.horizontalCenter: parent.horizontalCenter
                                        text: modelData.glyph
                                        color: modelData.sunny ? Theme.yellow : Theme.blue
                                        font.family: Theme.fontFamily; font.pixelSize: Theme.fontSize + 4
                                    }
                                    Text {
                                        anchors.horizontalCenter: parent.horizontalCenter
                                        text: modelData.temp + "°"; color: Theme.text
                                        font.family: Theme.fontFamily; font.pixelSize: Theme.fontSize - 2; font.bold: true
                                    }
                                }
                            }
                        }
                        Text {
                            anchors.centerIn: parent
                            visible: Weather.hourly.length === 0
                            text: "—"; color: Theme.overlay2
                            font.family: Theme.fontFamily; font.pixelSize: Theme.fontSize + 6
                        }
                    }
                }

                // big current temp
                ColumnLayout {
                    Layout.preferredWidth: 130
                    Layout.alignment: Qt.AlignVCenter
                    spacing: 0
                    Text {
                        Layout.alignment: Qt.AlignRight
                        text: (Weather.ok ? Weather.temp : "--") + "°"
                        color: Theme.text; font.family: Theme.fontFamily; font.pixelSize: 52; font.bold: true
                    }
                    Text {
                        Layout.alignment: Qt.AlignRight
                        Layout.preferredWidth: 130; horizontalAlignment: Text.AlignRight
                        text: Weather.condition; color: Theme.subtext0
                        font.family: Theme.fontFamily; font.pixelSize: Theme.fontSize - 1
                        wrapMode: Text.WordWrap
                    }
                }
            }

            Rectangle { Layout.fillWidth: true; height: 1; color: Theme.overlay0; opacity: 0.4 }

            // ================= STAT RINGS (fase introContent) =================
            RowLayout {
                Layout.fillWidth: true
                spacing: 12
                opacity: body.introContent
                transform: Translate { y: 18 * (1 - body.introContent) }
                StatRing { value: Math.min(100, Weather.windKmph); center: Weather.windKmph + ""; caption: I18n.t("WIND km/h"); ringColor: Theme.teal }
                StatRing { value: Weather.humidity; center: Weather.humidity + "%"; caption: I18n.t("HUMIDITY"); ringColor: Theme.blue }
                StatRing { value: Weather.rainChance; center: Weather.rainChance + "%"; caption: I18n.t("RAIN"); ringColor: Theme.mauve }
                StatRing { value: Math.min(100, Math.max(0, Weather.feelsLike + 10)); center: Weather.feelsLike + "°"; caption: I18n.t("FEELS LIKE"); ringColor: Theme.peach }
            }
        }
    }
}
