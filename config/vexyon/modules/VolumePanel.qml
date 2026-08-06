import QtQuick
import QtQuick.Layouts
import Quickshell
import qs.services
import qs.components

// ============================================================================
//  VolumePanel — port 1:1 del VolumePopup de ilyamiro (450x700):
//  orbe héroe con relleno de onda (Canvas) + texto recortado por la onda,
//  slider maestro al lado, pestañas Salidas/Entradas/Streams con píldora
//  deslizante, y lista de nodos (tarjeta activa colapsada en color de acento,
//  resto con botón mute + slider propio). Backend = Pipewire vía Audio/Mic
//  (ilyamiro usa scripts pactl; aquí escribimos node.audio directamente).
// ============================================================================
AnchoredPanel {
    id: vp
    panelKey: "volumePanel"
    ns: "vexyon-volume"
    panelWidth: 450
    contentMargin: 25
    accentColor: Theme.blue

    content: Component {
        Item {
            id: body
            width: vp.panelWidth - vp.contentMargin * 2
            implicitHeight: 650

            property real introHeader: 1
            property real introContent: 1

            // pestaña activa — el widget que abre fija la inicial (mic → entradas)
            property string activeTab: Panels.volumeInitTab
            readonly property color tabColor: activeTab === "outputs" ? Theme.blue
                                            : activeTab === "inputs" ? Theme.mauve
                                            : Theme.green
            property color panelAccent: tabColor

            // ---- estado del héroe (dispositivo por defecto de la pestaña) ----
            // apps: ilyamiro muestra el volumen maestro de salida
            readonly property var heroSvc: activeTab === "inputs" ? Mic : Audio
            readonly property string activeName: activeTab === "inputs"
                ? (Mic.ready ? Mic.nodeLabel(Mic.source) : I18n.t("No device"))
                : (Audio.ready ? Audio.nodeLabel(Audio.sink) : I18n.t("No device"))
            readonly property string activeDesc: activeTab === "apps"
                ? I18n.t("Master output volume")
                : (heroSvc.ready ? (activeTab === "inputs" ? Mic.source.name : Audio.sink.name) : "")
            readonly property bool activeMute: heroSvc.muted
            property bool draggingMaster: false
            property int dragVol: 0
            readonly property int activeVol: draggingMaster ? dragVol : heroSvc.percent

            // =================================================================
            //  HÉROE: orbe + slider maestro
            // =================================================================
            Item {
                id: heroRow
                width: parent.width
                height: 150
                opacity: body.introHeader
                transform: Translate { y: 30 * (1 - body.introHeader) }

                RowLayout {
                    anchors.fill: parent
                    spacing: 25

                    // ---- el orbe ----
                    Item {
                        Layout.preferredWidth: 130
                        Layout.preferredHeight: 130
                        scale: masterOrbMa.pressed ? 0.95 : (masterOrbMa.containsMouse ? 1.05 : 1.0)
                        Behavior on scale { NumberAnimation { duration: Theme.dur(400); easing.type: Easing.OutBack } }

                        // anillo exterior pulsante (borde)
                        Rectangle {
                            id: pulseRing
                            anchors.centerIn: parent
                            width: parent.width + 15
                            height: width
                            radius: width / 2
                            color: "transparent"
                            border.color: body.activeMute ? Theme.red : body.tabColor
                            border.width: 3
                            z: -2
                            property real pulseOp: 0.0
                            property real pulseSc: 1.0
                            opacity: body.activeMute ? 0.0 : pulseOp
                            scale: pulseSc
                            Timer {
                                interval: 45
                                running: vp.shown && !body.activeMute
                                repeat: true
                                onTriggered: {
                                    var time = Date.now() / 1000;
                                    pulseRing.pulseOp = 0.3 + Math.sin(time * 2.5) * 0.15;
                                    pulseRing.pulseSc = 1.02 + Math.cos(time * 3.0) * 0.02;
                                }
                            }
                        }

                        // anillo de fondo sólido que respira
                        Rectangle {
                            anchors.centerIn: parent
                            width: parent.width + 40
                            height: width
                            radius: width / 2
                            color: body.activeMute ? Theme.red : body.tabColor
                            opacity: body.activeMute ? 0.3 : 0.15
                            z: -1
                            Behavior on color { ColorAnimation { duration: 300 } }
                            SequentialAnimation on scale {
                                loops: Animation.Infinite; running: vp.shown
                                NumberAnimation { to: masterOrbMa.containsMouse ? 1.15 : 1.1; duration: masterOrbMa.containsMouse ? 800 : 2000; easing.type: Easing.InOutSine }
                                NumberAnimation { to: 1.0; duration: masterOrbMa.containsMouse ? 800 : 2000; easing.type: Easing.InOutSine }
                            }
                        }

                        // núcleo con relleno de onda
                        Rectangle {
                            id: centralCore
                            anchors.fill: parent
                            radius: width / 2
                            color: Theme.base
                            border.color: body.activeMute ? Theme.red : Qt.lighter(body.tabColor, 1.1)
                            border.width: 2
                            clip: true
                            Behavior on border.color { ColorAnimation { duration: 300 } }

                            Canvas {
                                id: orbWave
                                anchors.fill: parent
                                property real wavePhase: 0.0
                                NumberAnimation on wavePhase {
                                    running: vp.shown && body.activeVol > 0 && body.activeVol < 100
                                    loops: Animation.Infinite
                                    from: 0; to: Math.PI * 2; duration: 1200
                                }
                                onWavePhaseChanged: requestPaint()
                                Connections {
                                    target: body
                                    function onActiveVolChanged() { orbWave.requestPaint() }
                                    function onActiveMuteChanged() { orbWave.requestPaint() }
                                    function onTabColorChanged() { orbWave.requestPaint() }
                                }
                                onPaint: {
                                    var ctx = getContext("2d");
                                    ctx.clearRect(0, 0, width, height);
                                    if (body.activeVol <= 0) return;
                                    var fillRatio = body.activeVol / 100.0;
                                    var r = width / 2;
                                    var fillY = height * (1.0 - fillRatio);
                                    ctx.save();
                                    ctx.beginPath();
                                    ctx.arc(r, r, r, 0, 2 * Math.PI);
                                    ctx.clip();
                                    ctx.beginPath();
                                    ctx.moveTo(0, fillY);
                                    if (fillRatio < 0.99) {
                                        var waveAmp = 8 * Math.sin(fillRatio * Math.PI);
                                        var cp1y = fillY + Math.sin(wavePhase) * waveAmp;
                                        var cp2y = fillY + Math.cos(wavePhase + Math.PI) * waveAmp;
                                        ctx.bezierCurveTo(width * 0.33, cp2y, width * 0.66, cp1y, width, fillY);
                                        ctx.lineTo(width, height);
                                        ctx.lineTo(0, height);
                                    } else {
                                        ctx.lineTo(width, 0);
                                        ctx.lineTo(width, height);
                                        ctx.lineTo(0, height);
                                    }
                                    ctx.closePath();
                                    var grad = ctx.createLinearGradient(0, 0, 0, height);
                                    if (body.activeMute) {
                                        grad.addColorStop(0, Qt.lighter(Theme.red, 1.15).toString());
                                        grad.addColorStop(1, Theme.red.toString());
                                    } else {
                                        grad.addColorStop(0, Qt.lighter(body.tabColor, 1.15).toString());
                                        grad.addColorStop(1, body.tabColor.toString());
                                    }
                                    ctx.fillStyle = grad;
                                    ctx.globalAlpha = 1.0;
                                    ctx.fill();
                                    ctx.restore();
                                }
                            }

                            // texto doble: base + recortado por la onda (contraste)
                            Text {
                                anchors.centerIn: parent
                                font.family: Theme.fontFamily
                                font.weight: Font.Black
                                font.pixelSize: 30
                                color: body.activeMute ? Theme.red : Theme.text
                                text: body.activeMute ? I18n.t("MUTE") : body.activeVol + "%"
                                Behavior on color { ColorAnimation { duration: 200 } }
                            }
                            Item {
                                id: waveClipItem
                                anchors.bottom: parent.bottom
                                anchors.left: parent.left
                                anchors.right: parent.right
                                property real fillRatio: body.activeVol / 100.0
                                property real waveAmp: fillRatio < 0.99 ? 8 * Math.sin(fillRatio * Math.PI) : 0
                                property real waveCenterOffset: 0.375 * waveAmp * (Math.sin(orbWave.wavePhase) - Math.cos(orbWave.wavePhase))
                                property real baseClipHeight: parent.height * fillRatio
                                height: Math.min(parent.height, Math.max(0, baseClipHeight - waveCenterOffset))
                                clip: true
                                visible: body.activeVol > 0
                                Text {
                                    x: waveClipItem.width / 2 - width / 2
                                    y: (centralCore.height / 2) - (height / 2) - (centralCore.height - waveClipItem.height)
                                    font.family: Theme.fontFamily
                                    font.weight: Font.Black
                                    font.pixelSize: 30
                                    color: Theme.crust
                                    text: body.activeMute ? I18n.t("MUTE") : body.activeVol + "%"
                                }
                            }
                        }

                        MouseArea {
                            id: masterOrbMa
                            anchors.fill: parent
                            hoverEnabled: true
                            cursorShape: Qt.PointingHandCursor
                            onClicked: body.heroSvc.toggleMute()
                        }
                    }

                    // ---- nombre + slider maestro ----
                    ColumnLayout {
                        Layout.fillWidth: true
                        Layout.fillHeight: true
                        spacing: 10

                        ColumnLayout {
                            spacing: 2
                            Text {
                                Layout.fillWidth: true; elide: Text.ElideRight
                                font.family: Theme.fontFamily; font.weight: Font.Black; font.pixelSize: 19
                                color: Theme.text
                                text: body.activeName
                            }
                            Text {
                                Layout.fillWidth: true; elide: Text.ElideRight
                                font.family: Theme.fontFamily; font.pixelSize: 12
                                color: Theme.subtext0
                                text: body.activeDesc
                            }
                        }

                        Item { Layout.fillHeight: true }

                        Item {
                            Layout.fillWidth: true
                            Layout.preferredHeight: 24

                            Rectangle {
                                anchors.fill: parent; radius: 12
                                color: "#0dffffff"; border.color: "#1affffff"; border.width: 1
                                clip: true
                                Rectangle {
                                    height: parent.height
                                    width: parent.width * (Math.min(100, body.activeVol) / 100)
                                    radius: 12
                                    opacity: body.activeMute ? 0.3 : (masterSliderMa.containsMouse ? 1.0 : 0.85)
                                    Behavior on opacity { NumberAnimation { duration: 200 } }
                                    Behavior on width { enabled: !body.draggingMaster; NumberAnimation { duration: 300; easing.type: Easing.OutQuint } }
                                    gradient: Gradient {
                                        orientation: Gradient.Horizontal
                                        GradientStop { position: 0.0; color: body.activeMute ? Theme.surface2 : body.tabColor; Behavior on color { ColorAnimation { duration: 300 } } }
                                        GradientStop { position: 1.0; color: body.activeMute ? Qt.lighter(Theme.surface2, 1.15) : Qt.lighter(body.tabColor, 1.25); Behavior on color { ColorAnimation { duration: 300 } } }
                                    }
                                }
                            }
                            MouseArea {
                                id: masterSliderMa
                                anchors.fill: parent; hoverEnabled: true; cursorShape: Qt.PointingHandCursor
                                onPressed: function(mouse) { body.draggingMaster = true; updateVol(mouse.x); }
                                onPositionChanged: function(mouse) { if (pressed) updateVol(mouse.x); }
                                onReleased: body.draggingMaster = false
                                function updateVol(mx) {
                                    var pct = Math.max(0, Math.min(100, Math.round((mx / width) * 100)));
                                    body.dragVol = pct;
                                    if (pct > 0 && body.activeMute) body.heroSvc.toggleMute();
                                    body.heroSvc.setVolume(pct / 100);
                                }
                            }
                        }
                    }
                }
            }

            // =================================================================
            //  PESTAÑAS con píldora deslizante
            // =================================================================
            Rectangle {
                id: tabsBar
                anchors.top: heroRow.bottom
                anchors.topMargin: 20
                width: parent.width
                height: 54
                radius: 14
                color: "#0dffffff"
                border.color: "#1affffff"
                border.width: 1
                opacity: body.introHeader
                transform: Translate { y: 20 * (1 - body.introHeader) }

                Rectangle {
                    width: (parent.width - 2) / 3
                    height: parent.height - 2
                    y: 1
                    radius: 10
                    x: body.activeTab === "outputs" ? 1
                     : body.activeTab === "inputs" ? width + 1
                     : (width * 2) + 1
                    Behavior on x { NumberAnimation { duration: Theme.dur(500); easing.type: Easing.OutBack; easing.overshoot: 1.1 } }
                    gradient: Gradient {
                        orientation: Gradient.Horizontal
                        GradientStop { position: 0.0; color: body.tabColor; Behavior on color { ColorAnimation { duration: 400 } } }
                        GradientStop { position: 1.0; color: Qt.lighter(body.tabColor, 1.15); Behavior on color { ColorAnimation { duration: 400 } } }
                    }
                }

                RowLayout {
                    anchors.fill: parent
                    spacing: 0
                    Repeater {
                        model: [
                            { tabId: "outputs", icon: "󰓃", label: I18n.t("Outputs") },
                            { tabId: "inputs",  icon: "󰍬", label: I18n.t("Inputs") },
                            { tabId: "apps",    icon: "󰎆", label: I18n.t("Streams") }
                        ]
                        delegate: Item {
                            required property var modelData
                            Layout.fillWidth: true
                            Layout.fillHeight: true
                            RowLayout {
                                anchors.centerIn: parent
                                spacing: 8
                                Text {
                                    font.family: Theme.fontFamily; font.pixelSize: 17
                                    color: body.activeTab === modelData.tabId ? Theme.crust : (tabMa.containsMouse ? Theme.text : Theme.subtext0)
                                    text: modelData.icon
                                    Behavior on color { ColorAnimation { duration: 200 } }
                                }
                                Text {
                                    font.family: Theme.fontFamily; font.weight: Font.Black; font.pixelSize: 12
                                    color: body.activeTab === modelData.tabId ? Theme.crust : (tabMa.containsMouse ? Theme.text : Theme.subtext0)
                                    text: modelData.label
                                    Behavior on color { ColorAnimation { duration: 200 } }
                                }
                            }
                            MouseArea {
                                id: tabMa
                                anchors.fill: parent; hoverEnabled: true; cursorShape: Qt.PointingHandCursor
                                onClicked: body.activeTab = modelData.tabId
                            }
                        }
                    }
                }
            }

            // =================================================================
            //  LISTA DE NODOS
            // =================================================================
            Item {
                anchors.top: tabsBar.bottom
                anchors.topMargin: 20
                anchors.bottom: parent.bottom
                width: parent.width
                opacity: body.introContent
                transform: Translate { y: 20 * (1 - body.introContent) }

                ListView {
                    id: contentList
                    anchors.fill: parent
                    spacing: 12
                    clip: true
                    boundsBehavior: Flickable.StopAtBounds

                    add: Transition {
                        NumberAnimation { property: "opacity"; from: 0; to: 1; duration: 400; easing.type: Easing.OutQuint }
                        NumberAnimation { property: "scale"; from: 0.9; to: 1; duration: 400; easing.type: Easing.OutBack }
                    }
                    displaced: Transition {
                        SpringAnimation { property: "y"; spring: 3; damping: 0.2; mass: 0.2 }
                    }

                    model: body.activeTab === "outputs" ? Audio.sinks
                         : body.activeTab === "inputs" ? Mic.sources
                         : Audio.streams

                    // estado vacío
                    Item {
                        width: contentList.width; height: contentList.height
                        visible: contentList.count === 0
                        ColumnLayout {
                            anchors.centerIn: parent
                            spacing: 10
                            Text { Layout.alignment: Qt.AlignHCenter; font.family: Theme.fontFamily; font.pixelSize: 32; color: Theme.surface2; text: "󰖁" }
                            Text { Layout.alignment: Qt.AlignHCenter; font.family: Theme.fontFamily; font.pixelSize: 13; color: Theme.overlay0; text: I18n.t("No active streams") }
                        }
                    }

                    delegate: Rectangle {
                        id: delegateRoot
                        required property var modelData
                        required property int index

                        width: contentList.width

                        // intro escalonada por fila
                        property bool isLoaded: false
                        Timer {
                            running: vp.shown
                            interval: 40 + (index * 40)
                            onTriggered: delegateRoot.isLoaded = true
                        }
                        opacity: isLoaded ? 1.0 : 0.0
                        transform: Translate { y: delegateRoot.isLoaded ? 0 : 15 }
                        Behavior on opacity { NumberAnimation { duration: 500; easing.type: Easing.OutQuint } }

                        readonly property bool nodeReady: modelData && modelData.audio !== null
                        readonly property int nodeVol: nodeReady ? Math.round(modelData.audio.volume * 100) : 0
                        readonly property bool nodeMute: nodeReady ? modelData.audio.muted : false
                        readonly property string nodeTitle: body.activeTab === "apps"
                            ? Audio.streamLabel(modelData) : Audio.nodeLabel(modelData)

                        // el nodo activo por defecto colapsa su fila de slider
                        property bool isActiveNode: body.activeTab !== "apps"
                            && (body.activeTab === "outputs" ? Audio.isDefaultSink(modelData) : Mic.isDefaultSource(modelData))
                        height: isActiveNode ? 60 : 100
                        Behavior on height { NumberAnimation { duration: 400; easing.type: Easing.OutQuint } }

                        radius: 14
                        property bool isHovered: cardMa.containsMouse && !isActiveNode
                        color: isActiveNode ? body.tabColor : (isHovered ? "#0affffff" : "#05ffffff")
                        border.color: isActiveNode ? body.tabColor : "#1affffff"
                        border.width: isActiveNode ? 2 : 1
                        Behavior on border.color { ColorAnimation { duration: 300 } }
                        Behavior on color { ColorAnimation { duration: 300 } }

                        MouseArea {
                            id: cardMa
                            anchors.fill: parent
                            hoverEnabled: body.activeTab !== "apps"
                            cursorShape: body.activeTab !== "apps" ? Qt.PointingHandCursor : Qt.ArrowCursor
                            onClicked: {
                                if (body.activeTab === "apps" || delegateRoot.isActiveNode) return;
                                if (body.activeTab === "outputs") Audio.setSink(delegateRoot.modelData);
                                else Mic.setSource(delegateRoot.modelData);
                            }
                        }

                        ColumnLayout {
                            anchors.fill: parent
                            anchors.leftMargin: 16
                            anchors.rightMargin: 16
                            anchors.topMargin: 12
                            anchors.bottomMargin: delegateRoot.isActiveNode ? 12 : 16
                            spacing: 12

                            // fila superior: icono + textos
                            RowLayout {
                                Layout.fillWidth: true
                                spacing: 12
                                Text {
                                    font.family: Theme.fontFamily; font.pixelSize: 21
                                    color: delegateRoot.isActiveNode ? Theme.crust : Theme.text
                                    Behavior on color { ColorAnimation { duration: 200 } }
                                    text: {
                                        if (body.activeTab === "inputs") return "󰍬";
                                        if (body.activeTab === "apps") return "󰎆";
                                        var d = delegateRoot.nodeTitle.toLowerCase();
                                        if (d.indexOf("headset") !== -1 || d.indexOf("headphones") !== -1 || d.indexOf("auricular") !== -1) return "󰋎";
                                        return "󰓃";
                                    }
                                }
                                ColumnLayout {
                                    Layout.fillWidth: true
                                    spacing: 2
                                    Text {
                                        Layout.fillWidth: true; elide: Text.ElideRight
                                        font.family: Theme.fontFamily; font.weight: Font.Bold; font.pixelSize: 13
                                        color: delegateRoot.isActiveNode ? Theme.crust : Theme.text
                                        text: delegateRoot.nodeTitle
                                    }
                                    Text {
                                        Layout.fillWidth: true; elide: Text.ElideRight
                                        font.family: Theme.fontFamily; font.pixelSize: 11
                                        color: delegateRoot.isActiveNode ? Qt.darker(Theme.crust, 1.5) : Theme.subtext0
                                        text: delegateRoot.isActiveNode ? I18n.t("Active by default") : (delegateRoot.modelData ? delegateRoot.modelData.name : "")
                                    }
                                }
                            }

                            // fila inferior: mute + slider (oculta en el nodo activo)
                            RowLayout {
                                Layout.fillWidth: true
                                spacing: 15
                                visible: !delegateRoot.isActiveNode
                                opacity: delegateRoot.isActiveNode ? 0.0 : 1.0
                                Behavior on opacity { NumberAnimation { duration: 200 } }

                                Rectangle {
                                    Layout.preferredWidth: 32; Layout.preferredHeight: 32; radius: 16
                                    color: muteMa.containsMouse ? "#1affffff" : "transparent"
                                    border.color: muteMa.containsMouse ? (delegateRoot.nodeMute ? Theme.overlay0 : body.tabColor) : "transparent"
                                    Behavior on color { ColorAnimation { duration: 150 } }
                                    Text {
                                        anchors.centerIn: parent
                                        font.family: Theme.fontFamily; font.pixelSize: 17
                                        color: delegateRoot.nodeMute ? Theme.overlay0 : Theme.subtext0
                                        text: delegateRoot.nodeMute || delegateRoot.nodeVol === 0 ? "󰖁" : (delegateRoot.nodeVol > 50 ? "󰕾" : "󰖀")
                                        Behavior on color { ColorAnimation { duration: 200 } }
                                    }
                                    MouseArea {
                                        id: muteMa
                                        anchors.fill: parent; hoverEnabled: true; cursorShape: Qt.PointingHandCursor
                                        onClicked: if (delegateRoot.nodeReady) delegateRoot.modelData.audio.muted = !delegateRoot.modelData.audio.muted
                                    }
                                }

                                Item {
                                    Layout.fillWidth: true
                                    Layout.preferredHeight: 14
                                    Rectangle {
                                        anchors.fill: parent; radius: 7
                                        color: "#0dffffff"; border.color: "#1affffff"; border.width: 1
                                        clip: true
                                        Rectangle {
                                            height: parent.height
                                            width: parent.width * (Math.min(100, delegateRoot.nodeVol) / 100)
                                            radius: 7
                                            opacity: delegateRoot.nodeMute ? 0.3 : (volSliderMa.containsMouse ? 0.7 : 0.4)
                                            Behavior on opacity { NumberAnimation { duration: 200 } }
                                            Behavior on width { enabled: !volSliderMa.pressed; NumberAnimation { duration: 300; easing.type: Easing.OutQuint } }
                                            gradient: Gradient {
                                                orientation: Gradient.Horizontal
                                                GradientStop { position: 0.0; color: delegateRoot.nodeMute ? Theme.surface2 : body.tabColor; Behavior on color { ColorAnimation { duration: 300 } } }
                                                GradientStop { position: 1.0; color: delegateRoot.nodeMute ? Qt.lighter(Theme.surface2, 1.15) : Qt.lighter(body.tabColor, 1.25); Behavior on color { ColorAnimation { duration: 300 } } }
                                            }
                                        }
                                    }
                                    MouseArea {
                                        id: volSliderMa
                                        anchors.fill: parent; hoverEnabled: true; cursorShape: Qt.PointingHandCursor
                                        onPressed: function(mouse) { updateVol(mouse.x); }
                                        onPositionChanged: function(mouse) { if (pressed) updateVol(mouse.x); }
                                        function updateVol(mx) {
                                            if (!delegateRoot.nodeReady) return;
                                            var pct = Math.max(0, Math.min(100, Math.round((mx / width) * 100)));
                                            if (pct > 0 && delegateRoot.nodeMute) delegateRoot.modelData.audio.muted = false;
                                            delegateRoot.modelData.audio.volume = pct / 100;
                                        }
                                    }
                                }

                                Text {
                                    Layout.preferredWidth: 35
                                    font.family: Theme.fontFamily; font.weight: Font.Bold; font.pixelSize: 11
                                    color: Theme.subtext0
                                    text: delegateRoot.nodeVol + "%"
                                    horizontalAlignment: Text.AlignRight
                                }
                            }
                        }
                    }
                }
            }
        }
    }
}
