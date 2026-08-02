import QtQuick
import QtQuick.Layouts
import Quickshell
import qs.services
import qs.components

// ============================================================================
//  NetworkPanel — presentación estilo DankMaterialShell (ControlCenter/
//  Details/NetworkDetail.qml): cabecera con título + selector segmentado
//  Ethernet / Wi-Fi / Bluetooth (solo hardware presente) + acciones; el
//  cuerpo es una lista de TARJETAS redondeadas — la activa con borde de
//  acento — con icono según señal, nombre y línea de estado ("Conectada ·
//  Guardada · 85%"). Estados dedicados: Wi-Fi apagada (icono grande + botón
//  píldora "Activar"), escaneando (spinner), conectando (spinner en la fila).
//  La contraseña se pide INLINE expandiendo la tarjeta (en vez del modal de
//  DMS — menos ventanas flotantes, mismo flujo).
//
//  Backend SIN cambios: services/Network.qml (nmcli) y services/Bluetooth.
//  Sustituye al port del radar de ilyamiro (S12/S13) — solo cambia la
//  presentación/layout.
// ============================================================================
AnchoredPanel {
    id: np
    panelKey: "networkPanel"
    ns: "vexyon-network"
    panelWidth: 440
    contentMargin: 18
    accentColor: Theme.blue

    content: Component {
        Item {
            id: body
            width: np.panelWidth - np.contentMargin * 2
            implicitHeight: col.implicitHeight

            property real introHeader: 1
            property real introContent: 1

            // ---- pestaña activa (sigue Panels.networkInitTab del widget) ----
            readonly property bool ethPresent: Network.ethDevice !== ""
            readonly property bool wifiPresent: Network.wifiDevice !== ""
            readonly property bool btPresent: Bluetooth.present
            property string mode: {
                var m = Panels.networkInitTab;
                if (m === "bt" && !btPresent) m = "wifi";
                if (m === "wifi" && !wifiPresent) m = ethPresent ? "eth" : (btPresent ? "bt" : "wifi");
                if (m === "eth" && !ethPresent) m = wifiPresent ? "wifi" : (btPresent ? "bt" : "eth");
                return m;
            }
            // acento por pestaña (los blobs del AnchoredPanel lo siguen)
            property color panelAccent: mode === "bt" ? Theme.mauve : Theme.blue

            // ssid con la tarjeta de contraseña expandida ("" = ninguna)
            property string pwSsid: ""

            // refresco al abrir (y al cambiar de pestaña wifi)
            Component.onCompleted: {
                Network.refreshSaved();
                Network.refreshInfo();
                if (body.wifiPresent) Network.refreshWifi();
            }
            onModeChanged: {
                body.pwSsid = "";
                if (mode === "wifi") { Network.refreshWifi(); Network.refreshSaved(); }
                if (mode === "eth") Network.refreshInfo();
            }

            function isSaved(ssid) { return Network.savedNetworks.indexOf(ssid) !== -1; }

            // wifiEnabled solo se refresca al escanear — tras tocar la radio,
            // re-escanear con retraso (el rfkill tarda un instante)
            Timer { id: radioResync; interval: 900; onTriggered: Network.refreshWifi() }
            function toggleRadio() { Network.toggleWifi(); radioResync.restart(); }

            ColumnLayout {
                id: col
                width: parent.width
                spacing: 12

                // =================== CABECERA (patrón DMS) ===================
                RowLayout {
                    Layout.fillWidth: true
                    spacing: 10
                    opacity: body.introHeader
                    transform: Translate { y: 12 * (1 - body.introHeader) }

                    Text {
                        text: I18n.t("Network")
                        color: Theme.text
                        font.family: Theme.fontFamily
                        font.pixelSize: Theme.fontSize + 4
                        font.bold: true
                    }
                    Item { Layout.fillWidth: true }

                    // selector segmentado Ethernet / Wi-Fi / BT (solo hw real)
                    Rectangle {
                        Layout.preferredWidth: segRow.implicitWidth + 8
                        Layout.preferredHeight: 30
                        radius: 15
                        color: Theme.surface0
                        border.width: 1
                        border.color: Theme.surface2
                        RowLayout {
                            id: segRow
                            anchors.centerIn: parent
                            spacing: 2
                            SegBtn { tab: "eth"; glyph: Icons.ethernet; label: "Ethernet"; present: body.ethPresent }
                            SegBtn { tab: "wifi"; glyph: Icons.wifi; label: "Wi-Fi"; present: body.wifiPresent }
                            SegBtn { tab: "bt"; glyph: Icons.bluetooth; label: "Bluetooth"; present: body.btPresent }
                        }
                    }

                    // acción por pestaña: refrescar (wifi) / escanear (bt)
                    IconButton {
                        visible: body.mode === "wifi" && Network.wifiEnabled
                        icon: Icons.refresh
                        iconColor: Network.scanning ? Theme.blue : Theme.subtext0
                        iconSize: Theme.fontSize
                        implicitWidth: 30; implicitHeight: 30
                        onClicked: Network.refreshWifi()
                        RotationAnimator on rotation {
                            running: Network.scanning
                            loops: Animation.Infinite
                            from: 0; to: 360; duration: 1000
                        }
                    }
                    IconButton {
                        visible: body.mode === "bt" && Bluetooth.enabled
                        icon: Icons.refresh
                        iconColor: Bluetooth.discovering ? Theme.mauve : Theme.subtext0
                        iconSize: Theme.fontSize
                        implicitWidth: 30; implicitHeight: 30
                        onClicked: Bluetooth.scan()
                        RotationAnimator on rotation {
                            running: Bluetooth.discovering
                            loops: Animation.Infinite
                            from: 0; to: 360; duration: 1000
                        }
                    }
                    // interruptor de radio (wifi / bt)
                    Toggle {
                        visible: body.mode !== "eth"
                        checked: body.mode === "wifi" ? Network.wifiEnabled : Bluetooth.enabled
                        onToggled: body.mode === "wifi" ? body.toggleRadio() : Bluetooth.toggle()
                    }
                }

                // ======================= CONTENIDO ==========================
                Item {
                    Layout.fillWidth: true
                    // eth = altura natural (tarjeta + info); wifi/bt = lista alta
                    Layout.preferredHeight: body.mode === "eth" ? ethCol.implicitHeight : 380
                    opacity: body.introContent
                    transform: Translate { y: 16 * (1 - body.introContent) }

                    // ---------- Wi-Fi APAGADA (estado DMS "wifi off") --------
                    ColumnLayout {
                        anchors.centerIn: parent
                        spacing: 14
                        visible: body.mode === "wifi" && !Network.wifiEnabled
                        Text {
                            Layout.alignment: Qt.AlignHCenter
                            text: Icons.noNetwork
                            color: Theme.overlay1
                            font.family: Theme.fontFamily
                            font.pixelSize: 46
                        }
                        Text {
                            Layout.alignment: Qt.AlignHCenter
                            text: I18n.t("Wi-Fi is off")
                            color: Theme.text
                            font.family: Theme.fontFamily
                            font.pixelSize: Theme.fontSize + 2
                            font.bold: true
                        }
                        Rectangle {
                            Layout.alignment: Qt.AlignHCenter
                            width: enableLbl.implicitWidth + 36; height: 36
                            radius: 18
                            color: enableMa.containsMouse
                                   ? Qt.rgba(Theme.blue.r, Theme.blue.g, Theme.blue.b, 0.28)
                                   : Qt.rgba(Theme.blue.r, Theme.blue.g, Theme.blue.b, 0.16)
                            Behavior on color { ColorAnimation { duration: Theme.dur(150) } }
                            Text {
                                id: enableLbl
                                anchors.centerIn: parent
                                text: I18n.t("Enable Wi-Fi")
                                color: Theme.blue
                                font.family: Theme.fontFamily
                                font.pixelSize: Theme.fontSize
                                font.bold: true
                            }
                            MouseArea {
                                id: enableMa
                                anchors.fill: parent
                                hoverEnabled: true
                                cursorShape: Qt.PointingHandCursor
                                onClicked: body.toggleRadio()
                            }
                        }
                    }

                    // ---------- Wi-Fi ESCANEANDO sin resultados --------------
                    Text {
                        anchors.centerIn: parent
                        visible: body.mode === "wifi" && Network.wifiEnabled
                                 && Network.scanning && Network.wifiList.length === 0
                        text: Icons.refresh
                        color: Theme.overlay1
                        font.family: Theme.fontFamily
                        font.pixelSize: 42
                        RotationAnimator on rotation {
                            running: visible
                            loops: Animation.Infinite
                            from: 0; to: 360; duration: 1000
                        }
                    }

                    // ---------- Wi-Fi: LISTA de tarjetas (patrón DMS) --------
                    Flickable {
                        anchors.fill: parent
                        visible: body.mode === "wifi" && Network.wifiEnabled
                                 && !(Network.scanning && Network.wifiList.length === 0)
                        contentHeight: wifiCol.implicitHeight
                        clip: true
                        boundsBehavior: Flickable.StopAtBounds

                        ColumnLayout {
                            id: wifiCol
                            width: parent.width
                            spacing: 8

                            Repeater {
                                // conectada primero, luego por señal (orden DMS)
                                model: {
                                    var l = Network.wifiList.slice();
                                    l.sort(function(a, b) {
                                        if (a.active !== b.active) return a.active ? -1 : 1;
                                        return b.signal - a.signal;
                                    });
                                    return l;
                                }
                                delegate: Rectangle {
                                    id: wrow
                                    required property var modelData
                                    // active viene del último escaneo; wifiSsid es el
                                    // estado vivo (poll 5s) — cubre conexiones recientes
                                    readonly property bool connected: modelData.active
                                                                      || modelData.ssid === Network.wifiSsid
                                    readonly property bool connecting: Network.connectingId === modelData.ssid
                                    readonly property bool failed: Network.failedId === modelData.ssid
                                    readonly property bool secured: (modelData.security || "") !== ""
                                    readonly property bool saved: body.isSaved(modelData.ssid)
                                    readonly property bool pwOpen: body.pwSsid === modelData.ssid
                                    onPwOpenChanged: if (pwOpen) { pwField.text = ""; pwField.forceActiveFocus(); }

                                    Layout.fillWidth: true
                                    implicitHeight: wrowCol.implicitHeight + 20
                                    radius: Theme.radius
                                    color: wMa.containsMouse
                                           ? Qt.rgba(Theme.blue.r, Theme.blue.g, Theme.blue.b, 0.10)
                                           : Theme.surface0
                                    border.width: connected ? 2 : 1
                                    border.color: failed ? Theme.red
                                                  : connected ? Theme.blue
                                                  : Qt.rgba(Theme.overlay0.r, Theme.overlay0.g, Theme.overlay0.b, 0.5)
                                    Behavior on color { ColorAnimation { duration: Theme.dur(120) } }
                                    Behavior on border.color { ColorAnimation { duration: Theme.dur(200) } }
                                    Behavior on implicitHeight { NumberAnimation { duration: Theme.dur(180); easing.type: Theme.easing } }
                                    clip: true

                                    MouseArea {
                                        id: wMa
                                        anchors.fill: parent
                                        hoverEnabled: true
                                        cursorShape: Qt.PointingHandCursor
                                        onClicked: {
                                            if (wrow.connected || wrow.connecting) return;
                                            // tras un fallo, reabrir contraseña aunque esté
                                            // "guardada" (p.ej. quedó sin secrets)
                                            if (wrow.secured && (!wrow.saved || wrow.failed)) {
                                                body.pwSsid = wrow.pwOpen ? "" : wrow.modelData.ssid;
                                            } else {
                                                Network.connectWifi(wrow.modelData.ssid, "");
                                            }
                                        }
                                    }

                                    ColumnLayout {
                                        id: wrowCol
                                        anchors.left: parent.left
                                        anchors.right: parent.right
                                        anchors.top: parent.top
                                        anchors.margins: 10
                                        spacing: 8

                                        RowLayout {
                                            Layout.fillWidth: true
                                            spacing: 10

                                            // icono según señal (spinner si conectando)
                                            Text {
                                                text: wrow.connecting ? Icons.refresh : Icons.wifi
                                                color: wrow.failed ? Theme.red
                                                       : wrow.connecting ? Theme.peach
                                                       : wrow.connected ? Theme.blue
                                                       : wrow.modelData.signal >= 50 ? Theme.text : Theme.overlay1
                                                font.family: Theme.fontFamily
                                                font.pixelSize: Theme.fontSize + 3
                                                opacity: wrow.connecting || wrow.connected || wrow.modelData.signal >= 25 ? 1.0 : 0.55
                                                RotationAnimator on rotation {
                                                    running: wrow.connecting
                                                    loops: Animation.Infinite
                                                    from: 0; to: 360; duration: 1000
                                                }
                                            }

                                            ColumnLayout {
                                                Layout.fillWidth: true
                                                spacing: 1
                                                Text {
                                                    Layout.fillWidth: true
                                                    text: wrow.modelData.ssid
                                                    color: wrow.connected ? Theme.blue : Theme.text
                                                    font.family: Theme.fontFamily
                                                    font.pixelSize: Theme.fontSize
                                                    font.bold: wrow.connected
                                                    elide: Text.ElideRight
                                                }
                                                // línea de estado estilo DMS
                                                Text {
                                                    Layout.fillWidth: true
                                                    text: {
                                                        var bits = [];
                                                        if (wrow.failed) bits.push(I18n.t("Connection error"));
                                                        else if (wrow.connecting) bits.push(I18n.t("Connecting…"));
                                                        else if (wrow.connected) bits.push(I18n.t("Connected (network)"));
                                                        else bits.push(wrow.secured ? I18n.t("Protected") : I18n.t("Open (network)"));
                                                        if (wrow.saved && !wrow.connected) bits.push(I18n.t("Saved"));
                                                        bits.push(wrow.modelData.signal + "%");
                                                        return bits.join(" · ");
                                                    }
                                                    color: wrow.failed ? Theme.red
                                                           : wrow.connecting ? Theme.peach
                                                           : wrow.saved && !wrow.connected ? Theme.blue
                                                           : Theme.subtext0
                                                    font.family: Theme.fontFamily
                                                    font.pixelSize: Theme.fontSize - 4
                                                    elide: Text.ElideRight
                                                }
                                            }

                                            // candado en protegidas no guardadas
                                            Text {
                                                visible: wrow.secured && !wrow.saved && !wrow.connected
                                                text: "󰌾"
                                                color: Theme.overlay1
                                                font.family: Theme.fontFamily
                                                font.pixelSize: Theme.fontSize - 1
                                            }
                                            // desconectar (solo la activa)
                                            IconButton {
                                                visible: wrow.connected
                                                icon: Icons.close
                                                iconColor: Theme.subtext0
                                                hoverColor: Qt.rgba(Theme.red.r, Theme.red.g, Theme.red.b, 0.2)
                                                iconSize: Theme.fontSize - 1
                                                implicitWidth: 26; implicitHeight: 26
                                                onClicked: Network.disconnectWifi()
                                            }
                                        }

                                        // ---- contraseña inline (tarjeta expandida) ----
                                        RowLayout {
                                            Layout.fillWidth: true
                                            visible: wrow.pwOpen
                                            spacing: 8
                                            Rectangle {
                                                Layout.fillWidth: true
                                                Layout.preferredHeight: 30
                                                radius: Theme.radius - 2
                                                color: Theme.mantle
                                                border.width: 1
                                                border.color: pwField.activeFocus ? Theme.blue : Theme.surface2
                                                TextInput {
                                                    id: pwField
                                                    anchors.fill: parent
                                                    anchors.leftMargin: 10
                                                    anchors.rightMargin: 10
                                                    verticalAlignment: TextInput.AlignVCenter
                                                    echoMode: TextInput.Password
                                                    color: Theme.text
                                                    font.family: Theme.fontFamily
                                                    font.pixelSize: Theme.fontSize - 1
                                                    clip: true
                                                    onAccepted: {
                                                        Network.connectWifi(wrow.modelData.ssid, text);
                                                        body.pwSsid = "";
                                                    }
                                                    Text {
                                                        anchors.verticalCenter: parent.verticalCenter
                                                        visible: pwField.text === ""
                                                        text: I18n.t("Password")
                                                        color: Theme.overlay1
                                                        font: pwField.font
                                                    }
                                                }
                                            }
                                            Rectangle {
                                                Layout.preferredWidth: connLbl.implicitWidth + 22
                                                Layout.preferredHeight: 30
                                                radius: 15
                                                color: connMa.containsMouse ? Theme.accent2 : Theme.accent
                                                Text {
                                                    id: connLbl
                                                    anchors.centerIn: parent
                                                    text: I18n.t("Connect")
                                                    color: Theme.onAccent
                                                    font.family: Theme.fontFamily
                                                    font.pixelSize: Theme.fontSize - 2
                                                    font.bold: true
                                                }
                                                MouseArea {
                                                    id: connMa
                                                    anchors.fill: parent
                                                    hoverEnabled: true
                                                    cursorShape: Qt.PointingHandCursor
                                                    onClicked: {
                                                        Network.connectWifi(wrow.modelData.ssid, pwField.text);
                                                        body.pwSsid = "";
                                                    }
                                                }
                                            }
                                        }
                                    }
                                }
                            }

                            // sin resultados tras escanear
                            Text {
                                Layout.alignment: Qt.AlignHCenter
                                Layout.topMargin: 20
                                visible: Network.wifiList.length === 0 && !Network.scanning
                                text: I18n.t("No networks — tap refresh")
                                color: Theme.overlay1
                                font.family: Theme.fontFamily
                                font.pixelSize: Theme.fontSize - 1
                            }
                        }
                    }

                    // -------------------- ETHERNET ---------------------------
                    ColumnLayout {
                        id: ethCol
                        anchors.top: parent.top
                        anchors.left: parent.left
                        anchors.right: parent.right
                        visible: body.mode === "eth"
                        spacing: 8

                        // tarjeta del enlace (activa con borde acento, DMS wired)
                        Rectangle {
                            Layout.fillWidth: true
                            implicitHeight: ethRow.implicitHeight + 20
                            radius: Theme.radius
                            color: ethMa.containsMouse && !Network.ethUp
                                   ? Qt.rgba(Theme.blue.r, Theme.blue.g, Theme.blue.b, 0.10)
                                   : Theme.surface0
                            border.width: Network.ethUp ? 2 : 1
                            border.color: Network.ethUp ? Theme.blue
                                          : Qt.rgba(Theme.overlay0.r, Theme.overlay0.g, Theme.overlay0.b, 0.5)
                            Behavior on border.color { ColorAnimation { duration: Theme.dur(200) } }
                            MouseArea { id: ethMa; anchors.fill: parent; hoverEnabled: true }

                            RowLayout {
                                id: ethRow
                                anchors.left: parent.left
                                anchors.right: parent.right
                                anchors.verticalCenter: parent.verticalCenter
                                anchors.margins: 10
                                spacing: 10
                                Text {
                                    text: Icons.ethernet
                                    color: Network.ethUp ? Theme.blue : Theme.overlay1
                                    font.family: Theme.fontFamily
                                    font.pixelSize: Theme.fontSize + 3
                                }
                                ColumnLayout {
                                    Layout.fillWidth: true
                                    spacing: 1
                                    Text {
                                        text: Network.ethDevice !== "" ? Network.ethDevice : "Ethernet"
                                        color: Network.ethUp ? Theme.blue : Theme.text
                                        font.family: Theme.fontFamily
                                        font.pixelSize: Theme.fontSize
                                        font.bold: Network.ethUp
                                    }
                                    Text {
                                        text: Network.connectingId === Network.ethDevice ? I18n.t("Connecting…")
                                              : Network.ethUp ? I18n.t("Connected") : I18n.t("Disconnected")
                                        color: Network.connectingId === Network.ethDevice ? Theme.peach
                                               : Network.ethUp ? Theme.subtext0 : Theme.overlay1
                                        font.family: Theme.fontFamily
                                        font.pixelSize: Theme.fontSize - 4
                                    }
                                }
                                // conectar / desconectar
                                Rectangle {
                                    Layout.preferredWidth: ethBtnLbl.implicitWidth + 22
                                    Layout.preferredHeight: 28
                                    radius: 14
                                    color: Network.ethUp
                                           ? (ethBtnMa.containsMouse ? Qt.rgba(Theme.red.r, Theme.red.g, Theme.red.b, 0.25) : Qt.rgba(Theme.red.r, Theme.red.g, Theme.red.b, 0.14))
                                           : (ethBtnMa.containsMouse ? Qt.rgba(Theme.blue.r, Theme.blue.g, Theme.blue.b, 0.28) : Qt.rgba(Theme.blue.r, Theme.blue.g, Theme.blue.b, 0.16))
                                    Behavior on color { ColorAnimation { duration: Theme.dur(150) } }
                                    Text {
                                        id: ethBtnLbl
                                        anchors.centerIn: parent
                                        text: Network.ethUp ? I18n.t("Disconnect") : I18n.t("Connect")
                                        color: Network.ethUp ? Theme.red : Theme.blue
                                        font.family: Theme.fontFamily
                                        font.pixelSize: Theme.fontSize - 3
                                        font.bold: true
                                    }
                                    MouseArea {
                                        id: ethBtnMa
                                        anchors.fill: parent
                                        hoverEnabled: true
                                        cursorShape: Qt.PointingHandCursor
                                        onClicked: {
                                            if (Network.ethUp) Network.disconnectEth();
                                            else Network.connectEth();
                                            Network.refreshInfo();
                                        }
                                    }
                                }
                            }
                        }

                        // detalles de la conexión activa (IP / MAC / velocidad)
                        Rectangle {
                            Layout.fillWidth: true
                            visible: Network.ethUp && (Network.activeInfo.ip !== undefined
                                     || Network.activeInfo.mac !== undefined
                                     || Network.activeInfo.speed !== undefined)
                            implicitHeight: infoCol.implicitHeight + 20
                            radius: Theme.radius
                            color: Theme.surface0
                            border.width: 1
                            border.color: Qt.rgba(Theme.overlay0.r, Theme.overlay0.g, Theme.overlay0.b, 0.5)
                            ColumnLayout {
                                id: infoCol
                                anchors.left: parent.left
                                anchors.right: parent.right
                                anchors.top: parent.top
                                anchors.margins: 10
                                spacing: 4
                                InfoRow { label: "IP";        value: Network.activeInfo.ip || "" }
                                InfoRow { label: "MAC";       value: Network.activeInfo.mac || "" }
                                InfoRow { label: I18n.t("Speed"); value: Network.activeInfo.speed || "" }
                            }
                        }
                        Item { Layout.fillHeight: true }
                    }

                    // -------------------- BLUETOOTH ---------------------------
                    ColumnLayout {
                        anchors.fill: parent
                        visible: body.mode === "bt"
                        spacing: 8

                        // BT apagado (mismo patrón que wifi off)
                        ColumnLayout {
                            Layout.alignment: Qt.AlignHCenter
                            Layout.topMargin: 60
                            visible: !Bluetooth.enabled
                            spacing: 14
                            Text {
                                Layout.alignment: Qt.AlignHCenter
                                text: Icons.bluetooth
                                color: Theme.overlay1
                                font.family: Theme.fontFamily
                                font.pixelSize: 46
                            }
                            Text {
                                Layout.alignment: Qt.AlignHCenter
                                text: I18n.t("Bluetooth is off")
                                color: Theme.text
                                font.family: Theme.fontFamily
                                font.pixelSize: Theme.fontSize + 2
                                font.bold: true
                            }
                            Rectangle {
                                Layout.alignment: Qt.AlignHCenter
                                width: btOnLbl.implicitWidth + 36; height: 36
                                radius: 18
                                color: btOnMa.containsMouse
                                       ? Qt.rgba(Theme.mauve.r, Theme.mauve.g, Theme.mauve.b, 0.28)
                                       : Qt.rgba(Theme.mauve.r, Theme.mauve.g, Theme.mauve.b, 0.16)
                                Text {
                                    id: btOnLbl
                                    anchors.centerIn: parent
                                    text: I18n.t("Enable Bluetooth")
                                    color: Theme.mauve
                                    font.family: Theme.fontFamily
                                    font.pixelSize: Theme.fontSize
                                    font.bold: true
                                }
                                MouseArea {
                                    id: btOnMa
                                    anchors.fill: parent
                                    hoverEnabled: true
                                    cursorShape: Qt.PointingHandCursor
                                    onClicked: Bluetooth.toggle()
                                }
                            }
                        }

                        Flickable {
                            Layout.fillWidth: true
                            Layout.fillHeight: true
                            visible: Bluetooth.enabled
                            contentHeight: btCol.implicitHeight
                            clip: true
                            boundsBehavior: Flickable.StopAtBounds
                            ColumnLayout {
                                id: btCol
                                width: parent.width
                                spacing: 8
                                Repeater {
                                    model: Bluetooth.devices
                                    delegate: Rectangle {
                                        id: brow
                                        required property var modelData
                                        readonly property bool bconn: modelData.connected === true
                                        Layout.fillWidth: true
                                        implicitHeight: btRowL.implicitHeight + 20
                                        radius: Theme.radius
                                        color: bMa.containsMouse
                                               ? Qt.rgba(Theme.mauve.r, Theme.mauve.g, Theme.mauve.b, 0.10)
                                               : Theme.surface0
                                        border.width: bconn ? 2 : 1
                                        border.color: bconn ? Theme.mauve
                                                      : Qt.rgba(Theme.overlay0.r, Theme.overlay0.g, Theme.overlay0.b, 0.5)
                                        MouseArea {
                                            id: bMa
                                            anchors.fill: parent
                                            hoverEnabled: true
                                            cursorShape: Qt.PointingHandCursor
                                            onClicked: if (!brow.bconn) Bluetooth.connectDevice(brow.modelData)
                                        }
                                        RowLayout {
                                            id: btRowL
                                            anchors.left: parent.left
                                            anchors.right: parent.right
                                            anchors.verticalCenter: parent.verticalCenter
                                            anchors.margins: 10
                                            spacing: 10
                                            Text {
                                                text: Icons.bluetooth
                                                color: brow.bconn ? Theme.mauve : Theme.overlay1
                                                font.family: Theme.fontFamily
                                                font.pixelSize: Theme.fontSize + 3
                                            }
                                            ColumnLayout {
                                                Layout.fillWidth: true
                                                spacing: 1
                                                Text {
                                                    Layout.fillWidth: true
                                                    text: Bluetooth.deviceLabel(brow.modelData)
                                                    color: brow.bconn ? Theme.mauve : Theme.text
                                                    font.family: Theme.fontFamily
                                                    font.pixelSize: Theme.fontSize
                                                    font.bold: brow.bconn
                                                    elide: Text.ElideRight
                                                }
                                                Text {
                                                    text: brow.bconn ? I18n.t("Connected") : (brow.modelData.paired ? I18n.t("Paired") : I18n.t("Available"))
                                                    color: brow.bconn ? Theme.subtext0 : Theme.overlay1
                                                    font.family: Theme.fontFamily
                                                    font.pixelSize: Theme.fontSize - 4
                                                }
                                            }
                                        }
                                    }
                                }
                                Text {
                                    Layout.alignment: Qt.AlignHCenter
                                    Layout.topMargin: 20
                                    visible: Bluetooth.devices.length === 0
                                    text: Bluetooth.discovering ? I18n.t("Searching devices…") : I18n.t("No devices — tap scan")
                                    color: Theme.overlay1
                                    font.family: Theme.fontFamily
                                    font.pixelSize: Theme.fontSize - 1
                                }
                            }
                        }
                    }
                }
            }

            // ---- piezas locales ------------------------------------------------
            component SegBtn: Rectangle {
                property string tab: ""
                property string glyph: ""
                property string label: ""
                property bool present: true
                readonly property bool sel: body.mode === tab
                visible: present
                implicitWidth: segIn.implicitWidth + 18
                implicitHeight: 26
                radius: 13
                color: sel ? (tab === "bt" ? Theme.mauve : Theme.blue) : "transparent"
                Behavior on color { ColorAnimation { duration: Theme.dur(160) } }
                RowLayout {
                    id: segIn
                    anchors.centerIn: parent
                    spacing: 5
                    Text {
                        text: parent.parent.glyph
                        color: parent.parent.sel ? Theme.onAccent : Theme.subtext0
                        font.family: Theme.fontFamily
                        font.pixelSize: Theme.fontSize - 3
                    }
                    Text {
                        visible: parent.parent.sel
                        text: parent.parent.label
                        color: Theme.onAccent
                        font.family: Theme.fontFamily
                        font.pixelSize: Theme.fontSize - 3
                        font.bold: true
                    }
                }
                MouseArea {
                    anchors.fill: parent
                    cursorShape: Qt.PointingHandCursor
                    onClicked: Panels.networkInitTab = parent.tab
                }
            }

            component InfoRow: RowLayout {
                property string label: ""
                property string value: ""
                visible: value !== ""
                Layout.fillWidth: true
                Text {
                    text: parent.label
                    color: Theme.overlay1
                    font.family: Theme.fontFamily
                    font.pixelSize: Theme.fontSize - 3
                    Layout.preferredWidth: 80
                }
                Text {
                    Layout.fillWidth: true
                    text: parent.value
                    color: Theme.subtext1
                    font.family: Theme.fontFamily
                    font.pixelSize: Theme.fontSize - 3
                    elide: Text.ElideRight
                }
            }
        }
    }
}
