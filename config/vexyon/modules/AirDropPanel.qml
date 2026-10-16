import QtQuick
import QtQuick.Layouts
import Quickshell
import qs.services
import qs.components

// ============================================================================
//  AirDropPanel — AirDrop colgando de su pastilla de barra (módulo "airdrop").
//
//  Lo mismo que el AirDrop de un iPhone, en un panel: el interruptor de
//  visible (con el nombre que verán los Apple: el hostname), cuánto tiempo,
//  para quién (Todos / Solo contactos), enviar a un dispositivo cercano y
//  dónde se guardan los ficheros recibidos. El resto (lista de contactos,
//  tarjeta Wi-Fi, qué falta) vive en Ajustes → AirDrop.
//
//  Solo existe mientras está abierto (LazyLoader en shell.qml). CERO SONDEO:
//  relee el estado al abrirse y tras cada acción. La búsqueda de dispositivos
//  corre solo mientras su lista está abierta y se para al cerrar el panel.
// ============================================================================
AnchoredPanel {
    id: ap
    panelKey: "airdropPanel"
    ns: "vexyon-airdrop"
    panelWidth: 380
    accentColor: Theme.blue

    Component.onCompleted: {
        AirDrop.prime();
        AirDrop.refresh();
        if (AirDrop.info === null) AirDrop.loadInfo();
    }
    Component.onDestruction: AirDrop.stopScan()
    onShownChanged: if (!shown) AirDrop.stopScan()

    readonly property bool turning: AirDrop.busy === "on" || AirDrop.busy === "off"

    function statusLine() {
        if (AirDrop.busy === "on") return I18n.t("Turning on… (the radio takes a few seconds)");
        if (AirDrop.busy === "off") return I18n.t("Turning off…");
        if (!AirDrop.on) return I18n.t("Not visible to nearby devices");
        if (AirDrop.radioVisible === false) return I18n.t("Receiving, but the radio is not announcing this computer");
        if (AirDrop.mode === "once") return I18n.t("Until one file arrives");
        if (AirDrop.endsAt > 0) return I18n.t("Visible until %1").arg(Qt.formatTime(new Date(AirDrop.endsAt), "HH:mm"));
        return I18n.t("Until you turn it off");
    }

    readonly property var durations: [
        { v: 10, l: I18n.t("10 min") },
        { v: 30, l: I18n.t("30 min") },
        { v: 60, l: I18n.t("1 hour") },
        { v: 0,  l: I18n.t("Until I turn it off") }
    ]

    function homeless(p) {
        var h = Quickshell.env("HOME");
        return p.indexOf(h) === 0 ? "~" + p.slice(h.length) : p;
    }

    content: Component {
        ColumnLayout {
            id: body
            width: ap.panelWidth - ap.contentMargin * 2
            spacing: 10
            property real introHeader: 1
            property real introContent: 1

            // ---- cabecera ----
            RowLayout {
                Layout.fillWidth: true
                spacing: 10
                opacity: body.introHeader
                transform: Translate { y: 14 * (1 - body.introHeader) }
                Text {
                    text: Icons.airdrop; color: ap.accentColor
                    font.family: Theme.fontFamily; font.pixelSize: Theme.fontSize + 4
                }
                Text {
                    Layout.fillWidth: true
                    text: "AirDrop"; color: Theme.text
                    font.family: Theme.fontFamily; font.pixelSize: Theme.fontSize + 2
                    font.bold: true
                }
                IconButton {
                    icon: Icons.gear
                    onClicked: { ap.close(); Panels.openSettingsAt("airdrop"); }
                }
            }

            // ---- no instalado ----
            Notice {
                visible: !AirDrop.installed
                tint: Theme.red
                text: I18n.t("AirDrop is not installed. Run the Vexyon installer again (on NixOS: rebuild your system).")
            }

            // ---- lo que impide encenderlo (de `omdrop doctor`) ----
            Notice {
                visible: AirDrop.installed && !AirDrop.on && AirDrop.problems.length > 0
                tint: Theme.yellow
                text: AirDrop.problems.length > 0 ? AirDrop.problems[0].say : ""
                action: I18n.t("Details")
                onActed: { ap.close(); Panels.openSettingsAt("airdrop"); }
            }

            // ---- interruptor principal ----
            Rectangle {
                Layout.fillWidth: true
                visible: AirDrop.installed
                opacity: body.introContent
                implicitHeight: mainRow.implicitHeight + 24
                radius: Theme.radius
                color: Theme.surface0
                border.width: 1
                border.color: AirDrop.on ? ap.accentColor : Theme.overlay0
                Behavior on border.color { ColorAnimation { duration: Theme.dur(140) } }

                RowLayout {
                    id: mainRow
                    anchors.left: parent.left; anchors.right: parent.right
                    anchors.verticalCenter: parent.verticalCenter
                    anchors.leftMargin: 12; anchors.rightMargin: 12
                    spacing: 10
                    ColumnLayout {
                        Layout.fillWidth: true
                        spacing: 2
                        Text {
                            Layout.fillWidth: true
                            text: I18n.t("Visible as %1").arg(AirDrop.hostName !== "" ? AirDrop.hostName : "…")
                            color: Theme.text; elide: Text.ElideRight
                            font.family: Theme.fontFamily; font.pixelSize: Theme.fontSize
                            font.bold: true
                        }
                        Text {
                            Layout.fillWidth: true
                            text: ap.statusLine()
                            color: AirDrop.on && AirDrop.radioVisible !== false ? ap.accentColor : Theme.subtext0
                            wrapMode: Text.WordWrap
                            font.family: Theme.fontFamily; font.pixelSize: Theme.fontSize - 3
                        }
                    }
                    Toggle {
                        checked: AirDrop.on
                        opacity: ap.turning ? 0.5 : 1
                        enabled: !ap.turning
                        onToggled: function(v) {
                            if (v) AirDrop.turnOn(); else AirDrop.turnOff();
                            // Toggle se pone el valor él mismo; manda AirDrop.on.
                            checked = Qt.binding(function() { return AirDrop.on; });
                        }
                    }
                }
            }

            // ---- cuánto tiempo ----
            Flow {
                Layout.fillWidth: true
                visible: AirDrop.installed
                opacity: body.introContent
                spacing: 6
                Repeater {
                    model: ap.durations
                    delegate: Chip {
                        required property var modelData
                        label: modelData.l
                        on: AirDrop.minutes === modelData.v
                        onClicked: {
                            AirDrop.setMinutes(modelData.v);
                            // Visible ya: la ventana se rehace con el tiempo nuevo.
                            if (AirDrop.on) AirDrop.turnOn(modelData.v);
                        }
                    }
                }
            }

            // ---- para quién: se elige en Ajustes → AirDrop (Todos es lo normal;
            // Solo contactos es una lista opcional de Apple IDs) ----
            Text {
                Layout.fillWidth: true
                visible: AirDrop.installed && AirDrop.visibility === "contacts" && AirDrop.senders > 0
                text: Icons.users + "  " + I18n.t("Only the people on your AirDrop list can send you files (Settings → AirDrop).")
                color: Theme.subtext0; wrapMode: Text.WordWrap
                opacity: body.introContent
                font.family: Theme.fontFamily; font.pixelSize: Theme.fontSize - 3
            }
            Text {
                Layout.fillWidth: true
                visible: AirDrop.installed && AirDrop.visibility === "contacts" && AirDrop.senders === 0
                text: I18n.t("Your contacts list is empty, so nobody can send you anything. Add people in Settings → AirDrop.")
                color: Theme.yellow; wrapMode: Text.WordWrap
                font.family: Theme.fontFamily; font.pixelSize: Theme.fontSize - 3
            }
            Text {
                Layout.fillWidth: true
                visible: AirDrop.installed && AirDrop.takesWifi
                text: I18n.t("With this Wi-Fi card, Wi-Fi disconnects while you are visible and comes back when AirDrop turns off.")
                color: Theme.subtext0; wrapMode: Text.WordWrap
                font.family: Theme.fontFamily; font.pixelSize: Theme.fontSize - 3
            }
            Text {
                Layout.fillWidth: true
                visible: AirDrop.error !== ""
                text: AirDrop.error
                color: Theme.red; wrapMode: Text.WordWrap
                font.family: Theme.fontFamily; font.pixelSize: Theme.fontSize - 3
            }

            Rectangle { Layout.fillWidth: true; Layout.preferredHeight: 1; color: Theme.surface2; visible: AirDrop.installed }

            // ---- enviar ----
            RowLayout {
                Layout.fillWidth: true
                visible: AirDrop.installed
                opacity: body.introContent
                spacing: 8
                Text {
                    Layout.fillWidth: true
                    text: I18n.t("Send to a nearby device")
                    color: Theme.text
                    wrapMode: Text.WordWrap      // en español no cabe en una línea junto al botón
                    font.family: Theme.fontFamily; font.pixelSize: Theme.fontSize - 1
                    font.bold: true
                }
                Chip {
                    label: AirDrop.scanning ? I18n.t("Stop") : I18n.t("Find devices")
                    on: AirDrop.scanning
                    onClicked: if (AirDrop.scanning) AirDrop.stopScan(); else AirDrop.scan()
                }
            }
            Text {
                Layout.fillWidth: true
                visible: AirDrop.installed && AirDrop.scanning && AirDrop.peers.length === 0
                text: AirDrop.busy === "on" ? I18n.t("Turning AirDrop on first: only a visible computer hears anyone…")
                    : I18n.t("Looking… On an iPhone, open the share sheet and tap AirDrop so it can be found.")
                color: Theme.subtext0; wrapMode: Text.WordWrap
                font.family: Theme.fontFamily; font.pixelSize: Theme.fontSize - 3
            }
            Repeater {
                model: AirDrop.scanning || AirDrop.sendMac !== "" ? AirDrop.peers : []
                delegate: Rectangle {
                    id: peerRow
                    required property var modelData
                    readonly property bool target: AirDrop.sendMac === modelData.mac
                    Layout.fillWidth: true
                    implicitHeight: peerCol.implicitHeight + 16
                    radius: Theme.radius
                    color: peerMa.containsMouse && !AirDrop.sending ? Theme.surface1 : Theme.surface0
                    MouseArea {
                        id: peerMa
                        anchors.fill: parent
                        hoverEnabled: true
                        cursorShape: AirDrop.sending ? Qt.ArrowCursor : Qt.PointingHandCursor
                        enabled: !AirDrop.sending
                        onClicked: AirDrop.sendTo(peerRow.modelData.mac, peerRow.modelData.name)
                    }
                    RowLayout {
                        anchors.left: parent.left; anchors.right: parent.right
                        anchors.verticalCenter: parent.verticalCenter
                        anchors.leftMargin: 12; anchors.rightMargin: 8
                        spacing: 8
                        Text {
                            text: Icons.send; color: ap.accentColor
                            font.family: Theme.fontFamily; font.pixelSize: Theme.fontSize - 1
                        }
                        ColumnLayout {
                            id: peerCol
                            Layout.fillWidth: true
                            spacing: 1
                            Text {
                                Layout.fillWidth: true
                                text: peerRow.modelData.name !== "" ? peerRow.modelData.name
                                      : I18n.t("Unnamed device") + " · " + peerRow.modelData.mac.slice(-5)
                                color: Theme.text; elide: Text.ElideRight
                                font.family: Theme.fontFamily; font.pixelSize: Theme.fontSize - 1
                            }
                            Text {
                                Layout.fillWidth: true
                                visible: peerRow.target && (AirDrop.sendLine !== "" || AirDrop.sendResult !== "")
                                text: AirDrop.sendResult === "ok" ? Icons.check + "  " + AirDrop.sendLine : AirDrop.sendLine
                                color: AirDrop.sendResult === "failed" ? Theme.red
                                     : AirDrop.sendResult === "ok" ? Theme.green : Theme.subtext0
                                wrapMode: Text.WordWrap
                                font.family: Theme.fontFamily; font.pixelSize: Theme.fontSize - 3
                            }
                        }
                        IconButton {
                            visible: peerRow.target && AirDrop.sending
                            icon: Icons.close; iconSize: Theme.fontSize - 2
                            implicitWidth: 24; implicitHeight: 24
                            onClicked: AirDrop.cancelSend()
                        }
                    }
                }
            }

            // ---- dónde se guarda lo recibido ----
            RowLayout {
                Layout.fillWidth: true
                visible: AirDrop.installed
                opacity: body.introContent
                spacing: 8
                Text {
                    text: Icons.folder; color: Theme.subtext0
                    font.family: Theme.fontFamily; font.pixelSize: Theme.fontSize - 1
                }
                Text {
                    Layout.fillWidth: true
                    text: I18n.t("Received files go to %1").arg(AirDrop.dir !== "" ? ap.homeless(AirDrop.dir) : "…")
                    color: Theme.subtext0; elide: Text.ElideMiddle
                    font.family: Theme.fontFamily; font.pixelSize: Theme.fontSize - 3
                }
                Chip {
                    label: I18n.t("Change")
                    onClicked: AirDrop.pickDir()
                }
            }
        }
    }

    // ---- piezas ---------------------------------------------------------------
    component Chip: Rectangle {
        id: chip
        property string label: ""
        property bool on: false
        signal clicked()
        implicitWidth: chipTxt.implicitWidth + 22
        implicitHeight: 28
        radius: Theme.radius
        color: chip.on ? ap.accentColor : (chipMa.containsMouse ? Theme.surface2 : Theme.surface1)
        Behavior on color { ColorAnimation { duration: Theme.dur(120) } }
        Text {
            id: chipTxt
            anchors.centerIn: parent
            text: chip.label
            color: chip.on ? Theme.onAccent : Theme.text
            font.family: Theme.fontFamily; font.pixelSize: Theme.fontSize - 2
        }
        MouseArea {
            id: chipMa
            anchors.fill: parent
            hoverEnabled: true
            cursorShape: Qt.PointingHandCursor
            onClicked: chip.clicked()
        }
    }

    component Notice: Rectangle {
        id: nt
        property color tint: Theme.yellow
        property string text: ""
        property string action: ""
        signal acted()
        Layout.fillWidth: true
        implicitHeight: ntRow.implicitHeight + 18
        radius: Theme.radius
        color: Qt.rgba(nt.tint.r, nt.tint.g, nt.tint.b, 0.12)
        border.width: 1
        border.color: Qt.rgba(nt.tint.r, nt.tint.g, nt.tint.b, 0.5)
        RowLayout {
            id: ntRow
            anchors.left: parent.left; anchors.right: parent.right
            anchors.verticalCenter: parent.verticalCenter
            anchors.leftMargin: 12; anchors.rightMargin: 8
            spacing: 8
            Text {
                Layout.fillWidth: true
                text: nt.text
                color: Theme.text; wrapMode: Text.WordWrap
                font.family: Theme.fontFamily; font.pixelSize: Theme.fontSize - 3
            }
            Chip {
                visible: nt.action !== ""
                label: nt.action
                onClicked: nt.acted()
            }
        }
    }
}
