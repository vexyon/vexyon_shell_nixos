import QtQuick
import QtQuick.Layouts
import Quickshell
import Quickshell.Io
import qs.services
import qs.components

// ============================================================================
//  BatteryPanel — panel de batería/energía de un portátil. Del BatteryPopup
//  de ilyamiro se conserva SOLO la gestión real de energía: cajas HR:MIN
//  (tiempo restante estimado de batería) con dos puntos pulsantes, anillo
//  de batería Canvas con halo y
//  efectos de carga/descarga al hover, dock de sliders brillo/volumen y
//  píldora de perfiles de energía. La tonalidad de TODO el panel (blobs/
//  anillo/sliders/acento) sigue el estado de la batería: verde=cargando,
//  azul>=70, amarillo>=30, rojo<30.
//  RETIRADO respecto al port original: el centro de notificaciones agrupadas
//  y el dock de acciones de sistema (bloquear/suspender/reiniciar/apagar) +
//  botón de cerrar sesión — no pintan nada en un panel de batería y viven en
//  el centro de notificaciones y el menú de energía. Backend: Battery/
//  Brightness/Audio de Vexyon + powerprofilesctl.
// ============================================================================
AnchoredPanel {
    id: bp
    panelKey: "batteryPanel"
    ns: "vexyon-battery"
    panelWidth: 420
    contentMargin: 0
    accentColor: Theme.blue

    content: Component {
        Item {
            id: body
            width: bp.panelWidth
            implicitHeight: 620

            // ---- estado batería / tonalidad global -------------------------
            readonly property bool hasBattery: Battery.present
            readonly property int batCapacity: hasBattery ? Battery.percent : 100
            readonly property bool isCharging: hasBattery && Battery.charging
            readonly property string batStatus: !hasBattery ? I18n.t("No battery")
                                              : Battery.full ? I18n.t("Charged")
                                              : isCharging ? I18n.t("Charging") : I18n.t("Discharging")

            readonly property color batColorStart: {
                if (isCharging) return Theme.green;
                if (batCapacity >= 70) return Theme.blue;
                if (batCapacity >= 30) return Theme.yellow;
                return Theme.red;
            }
            readonly property color batColorEnd: Qt.lighter(batColorStart, 1.15)
            readonly property color ambientPrimary: batColorStart
            readonly property color ambientSecondary: {
                if (isCharging) return Theme.teal;
                if (batCapacity >= 70) return Theme.mauve;
                if (batCapacity >= 30) return Theme.peach;
                return Qt.darker(Theme.red, 1.3);
            }
            property color panelAccent: ambientPrimary

            property real animCapacity: 0
            Behavior on animCapacity { NumberAnimation { duration: 1200; easing.type: Easing.OutQuint } }
            Component.onCompleted: { animCapacity = batCapacity; introSeq.start(); }
            onBatCapacityChanged: animCapacity = batCapacity
            onAnimCapacityChanged: batCanvas.requestPaint()
            onBatColorStartChanged: batCanvas.requestPaint()

            // ---- perfil de energía -----------------------------------------
            property string powerProfile: "balanced"
            readonly property color profileStart: {
                if (powerProfile === "performance") return Theme.red;
                if (powerProfile === "power-saver") return Theme.green;
                return Theme.blue;
            }
            readonly property color profileEnd: Qt.lighter(profileStart, 1.15)
            Process {
                id: profilePoller
                command: ["bash", "-c", "powerprofilesctl get 2>/dev/null || echo balanced"]
                running: true
                stdout: StdioCollector { onStreamFinished: body.powerProfile = this.text.trim() || "balanced" }
            }

            // ---- estimated battery time remaining (was: /proc/uptime counter) ----
            // Discharging -> UPower TimeToEmpty (the system's own estimate, same
            //   UPower device the % already reads). Charging -> TimeToFull (time
            //   until full), a real number, never a bogus discharge countdown.
            // Full/idle, or estimate not ready (0s: right after boot, or power
            //   draw 0) -> placeholder "--", never a misleading "0:00".
            // Fully reactive off Battery.* (UPower change signals): no Process,
            //   no polling loop — the boxes just re-bind when UPower updates.
            readonly property real remSecs: !hasBattery ? 0
                                          : Battery.full ? 0
                                          : isCharging ? Battery.timeToFull
                                          : Battery.timeToEmpty
            readonly property bool remKnown: remSecs > 0
            readonly property int remHours: remKnown ? Math.floor(remSecs / 3600) : 0
            readonly property int remMins: remKnown ? Math.floor((remSecs % 3600) / 60) : 0

            // ---- intro escalonada (ilyamiro) ----
            property real introTop: 0
            property real introCore: 0
            property real introSliders: 0
            property real introProfiles: 0
            ParallelAnimation {
                id: introSeq
                SequentialAnimation { PauseAnimation { duration: 100 } NumberAnimation { target: body; property: "introTop"; from: 0; to: 1; duration: 800; easing.type: Easing.OutBack; easing.overshoot: 1.0 } }
                SequentialAnimation { PauseAnimation { duration: 250 } NumberAnimation { target: body; property: "introCore"; from: 0; to: 1; duration: 900; easing.type: Easing.OutBack; easing.overshoot: 1.2 } }
                SequentialAnimation { PauseAnimation { duration: 350 } NumberAnimation { target: body; property: "introSliders"; from: 0; to: 1; duration: 800; easing.type: Easing.OutQuart } }
                SequentialAnimation { PauseAnimation { duration: 450 } NumberAnimation { target: body; property: "introProfiles"; from: 0; to: 1; duration: 850; easing.type: Easing.OutBack; easing.overshoot: 0.8 } }
            }

            // ==============================================================
            //  NÚCLEO DE BATERÍA (única columna)
            // ==============================================================
            Item {
                anchors.fill: parent

                // anillos de radar centrados en el núcleo
                Item {
                    anchors.fill: parent
                    Repeater {
                        model: 3
                        Rectangle {
                            required property int index
                            anchors.centerIn: parent
                            anchors.verticalCenterOffset: -70
                            width: 320 + (index * 170)
                            height: width
                            radius: width / 2
                            color: "transparent"
                            border.color: body.ambientSecondary
                            border.width: 1
                            Behavior on border.color { ColorAnimation { duration: 1000 } }
                            opacity: 0.06 - (index * 0.02)
                        }
                    }
                }

                // uptime HR : MIN
                Row {
                    anchors.top: parent.top
                    anchors.left: parent.left
                    anchors.margins: 25
                    spacing: 6
                    transform: Translate { y: -20 * (1.0 - body.introTop) }
                    opacity: body.introTop

                    Rectangle {
                        width: 44; height: 48; radius: 10
                        color: Theme.surface0; border.color: Theme.surface1; border.width: 1
                        Rectangle { anchors.fill: parent; radius: 10; color: body.ambientPrimary; opacity: 0.05; Behavior on color { ColorAnimation { duration: 1000 } } }
                        Column {
                            anchors.centerIn: parent
                            Text {
                                text: body.remKnown ? body.remHours.toString().padStart(2, "0") : "--"
                                font.pixelSize: 17; font.family: Theme.fontFamily; font.weight: Font.Black
                                color: body.ambientPrimary
                                Behavior on color { ColorAnimation { duration: 1000 } }
                                anchors.horizontalCenter: parent.horizontalCenter
                            }
                            Text {
                                text: I18n.t("HR"); font.pixelSize: 8; font.family: Theme.fontFamily; font.weight: Font.Bold
                                color: Theme.subtext0; anchors.horizontalCenter: parent.horizontalCenter
                            }
                        }
                    }
                    Text {
                        anchors.verticalCenter: parent.verticalCenter
                        text: ":"
                        font.pixelSize: 21; font.family: Theme.fontFamily; font.weight: Font.Black
                        color: body.ambientPrimary
                        Behavior on color { ColorAnimation { duration: 1000 } }
                        SequentialAnimation on opacity {
                            loops: Animation.Infinite; running: bp.shown
                            NumberAnimation { to: 0.2; duration: 800; easing.type: Easing.InOutSine }
                            NumberAnimation { to: 1.0; duration: 800; easing.type: Easing.InOutSine }
                        }
                    }
                    Rectangle {
                        width: 44; height: 48; radius: 10
                        color: Theme.surface0; border.color: Theme.surface1; border.width: 1
                        Rectangle { anchors.fill: parent; radius: 10; color: body.ambientSecondary; opacity: 0.05; Behavior on color { ColorAnimation { duration: 1000 } } }
                        Column {
                            anchors.centerIn: parent
                            Text {
                                text: body.remKnown ? body.remMins.toString().padStart(2, "0") : "--"
                                font.pixelSize: 17; font.family: Theme.fontFamily; font.weight: Font.Black
                                color: body.ambientSecondary
                                Behavior on color { ColorAnimation { duration: 1000 } }
                                anchors.horizontalCenter: parent.horizontalCenter
                            }
                            Text {
                                text: "MIN"; font.pixelSize: 8; font.family: Theme.fontFamily; font.weight: Font.Bold
                                color: Theme.subtext0; anchors.horizontalCenter: parent.horizontalCenter
                            }
                        }
                    }
                }

                // núcleo central con anillo de batería
                Item {
                    anchors.fill: parent
                    z: 1
                    opacity: body.introCore
                    transform: Translate { y: 25 * (1 - body.introCore) }
                    scale: 0.9 + (0.1 * body.introCore)

                    // halo exterior
                    Rectangle {
                        anchors.centerIn: centralCore
                        width: centralCore.width + 45
                        height: width
                        radius: width / 2
                        color: centralCore.isDangerState ? Theme.red : body.ambientPrimary
                        opacity: centralCore.isDangerState ? 0.25 : 0.15
                        z: 0
                        Behavior on color { ColorAnimation { duration: 400 } }
                        SequentialAnimation on scale {
                            loops: Animation.Infinite; running: bp.shown
                            NumberAnimation { to: heroMa.containsMouse ? 1.15 : 1.08; duration: heroMa.containsMouse ? 800 : 2000; easing.type: Easing.InOutSine }
                            NumberAnimation { to: 1.0; duration: heroMa.containsMouse ? 800 : 2000; easing.type: Easing.InOutSine }
                        }
                    }

                    Rectangle {
                        id: centralCore
                        width: 260
                        height: width
                        anchors.centerIn: parent
                        anchors.verticalCenterOffset: -70
                        radius: width / 2
                        z: 1
                        property bool isDangerState: body.hasBattery && !body.isCharging && body.batCapacity < 15

                        SequentialAnimation on scale {
                            loops: Animation.Infinite; running: bp.shown
                            NumberAnimation {
                                to: heroMa.containsMouse ? 1.05 : (centralCore.isDangerState ? 1.04 : 1.01)
                                duration: heroMa.containsMouse ? 1200 : (centralCore.isDangerState ? 600 : 2500)
                                easing.type: Easing.InOutSine
                            }
                            NumberAnimation {
                                to: 1.0
                                duration: heroMa.containsMouse ? 1200 : (centralCore.isDangerState ? 600 : 2500)
                                easing.type: Easing.InOutSine
                            }
                        }

                        gradient: Gradient {
                            orientation: Gradient.Vertical
                            GradientStop { position: 0.0; color: Theme.surface0 }
                            GradientStop { position: 1.0; color: Theme.base }
                        }

                        Rectangle {
                            anchors.fill: parent
                            radius: width / 2
                            color: Qt.darker(Theme.red, 1.3)
                            opacity: 0.0
                            SequentialAnimation on opacity {
                                loops: Animation.Infinite; running: centralCore.isDangerState && bp.shown
                                NumberAnimation { to: 0.25; duration: 600; easing.type: Easing.InOutSine }
                                NumberAnimation { to: 0.15; duration: 600; easing.type: Easing.InOutSine }
                            }
                        }

                        Item {
                            id: coreFx
                            anchors.fill: parent

                            property real textPulse: 0.0
                            SequentialAnimation on textPulse {
                                loops: Animation.Infinite; running: bp.shown
                                NumberAnimation { from: 0.0; to: 1.0; duration: 1200; easing.type: Easing.InOutSine }
                                NumberAnimation { from: 1.0; to: 0.0; duration: 1200; easing.type: Easing.InOutSine }
                            }
                            property real pumpPhase: 0.0
                            NumberAnimation on pumpPhase {
                                running: heroMa.containsMouse && body.isCharging
                                loops: Animation.Infinite
                                from: 0.0; to: 1.0; duration: 1200
                                easing.type: Easing.InOutSine
                            }
                            property real dischargePhase: 1.0
                            NumberAnimation on dischargePhase {
                                running: heroMa.containsMouse && !body.isCharging
                                loops: Animation.Infinite
                                from: 1.0; to: 0.0; duration: 1600
                                easing.type: Easing.InOutSine
                            }
                            onPumpPhaseChanged: if (heroMa.containsMouse && body.isCharging) batCanvas.requestPaint()
                            onDischargePhaseChanged: if (heroMa.containsMouse && !body.isCharging) batCanvas.requestPaint()

                            Canvas {
                                id: batCanvas
                                anchors.fill: parent
                                rotation: 180
                                onPaint: {
                                    var ctx = getContext("2d");
                                    ctx.clearRect(0, 0, width, height);
                                    var centerX = width / 2;
                                    var centerY = height / 2;
                                    var radius = (width / 2) - 18;
                                    var endAngle = (body.animCapacity / 100) * 2 * Math.PI;
                                    ctx.lineCap = "round";

                                    ctx.lineWidth = 8;
                                    ctx.beginPath();
                                    ctx.arc(centerX, centerY, radius, 0, 2 * Math.PI);
                                    ctx.strokeStyle = Theme.surface1;
                                    ctx.stroke();

                                    var fillGrad = ctx.createLinearGradient(0, height, width, 0);
                                    fillGrad.addColorStop(0, body.batColorStart.toString());
                                    fillGrad.addColorStop(1, body.batColorEnd.toString());
                                    ctx.globalAlpha = 1.0;
                                    ctx.lineWidth = 14;
                                    ctx.beginPath();
                                    ctx.arc(centerX, centerY, radius, 0, endAngle);
                                    ctx.strokeStyle = fillGrad;
                                    ctx.stroke();

                                    if (heroMa.containsMouse && endAngle > 0.1) {
                                        if (body.isCharging) {
                                            var surgeAngle = coreFx.pumpPhase * (endAngle + 0.6) - 0.3;
                                            if (surgeAngle > 0 && surgeAngle < endAngle) {
                                                var sStart = Math.max(0, surgeAngle - 0.4);
                                                var sEnd = Math.min(endAngle, surgeAngle + 0.4);
                                                ctx.beginPath();
                                                ctx.arc(centerX, centerY, radius, sStart, sEnd);
                                                ctx.lineWidth = 22;
                                                ctx.strokeStyle = body.batColorStart.toString();
                                                ctx.globalAlpha = 0.5 * Math.sin(coreFx.pumpPhase * Math.PI);
                                                ctx.stroke();
                                                sStart = Math.max(0, surgeAngle - 0.2);
                                                sEnd = Math.min(endAngle, surgeAngle + 0.2);
                                                ctx.beginPath();
                                                ctx.arc(centerX, centerY, radius, sStart, sEnd);
                                                ctx.lineWidth = 28;
                                                ctx.strokeStyle = body.batColorEnd.toString();
                                                ctx.globalAlpha = 0.8 * Math.sin(coreFx.pumpPhase * Math.PI);
                                                ctx.stroke();
                                            }
                                            if (coreFx.pumpPhase > 0.7) {
                                                var flarePhase = (coreFx.pumpPhase - 0.7) / 0.3;
                                                var hitX = centerX + Math.cos(endAngle) * radius;
                                                var hitY = centerY + Math.sin(endAngle) * radius;
                                                ctx.beginPath();
                                                ctx.arc(hitX, hitY, 7 + (flarePhase * 15), 0, 2 * Math.PI);
                                                ctx.fillStyle = body.batColorEnd.toString();
                                                ctx.globalAlpha = (1.0 - flarePhase) * 0.6;
                                                ctx.fill();
                                            }
                                        } else {
                                            var drainCenter = coreFx.dischargePhase * endAngle;
                                            for (var d = 0; d < 2; d++) {
                                                var dSpread = 0.2 + (d * 0.15);
                                                var dStart = Math.max(0, drainCenter - dSpread);
                                                var dEnd = Math.min(endAngle, drainCenter + dSpread);
                                                if (dStart < dEnd) {
                                                    ctx.beginPath();
                                                    ctx.arc(centerX, centerY, radius, dStart, dEnd);
                                                    ctx.lineWidth = 14 + (1 - d) * 2;
                                                    ctx.strokeStyle = body.batColorEnd.toString();
                                                    ctx.globalAlpha = 0.2 * Math.sin(coreFx.dischargePhase * Math.PI);
                                                    ctx.stroke();
                                                }
                                            }
                                        }
                                        ctx.globalAlpha = 1.0;
                                    }
                                }
                            }

                            ColumnLayout {
                                anchors.centerIn: parent
                                spacing: -2
                                RowLayout {
                                    Layout.alignment: Qt.AlignHCenter
                                    spacing: 8
                                    Text {
                                        font.family: Theme.fontFamily
                                        font.pixelSize: 26
                                        color: body.batColorStart
                                        text: body.isCharging ? "󰂄" : (body.batCapacity > 20 ? "󰁹" : "󰂃")
                                        Behavior on color { ColorAnimation { duration: 400 } }
                                    }
                                    Text {
                                        font.family: Theme.fontFamily
                                        font.weight: Font.Black
                                        font.pixelSize: 50
                                        color: Theme.text
                                        text: Math.round(body.animCapacity) + "%"
                                    }
                                }
                                Text {
                                    Layout.alignment: Qt.AlignHCenter
                                    font.family: Theme.fontFamily
                                    font.weight: Font.Bold
                                    font.pixelSize: 12
                                    color: body.isCharging
                                        ? Qt.tint(Theme.green, Qt.rgba(1, 1, 1, coreFx.textPulse * 0.4))
                                        : (centralCore.isDangerState ? Qt.tint(Theme.red, Qt.rgba(1, 1, 1, coreFx.textPulse * 0.3)) : Theme.subtext0)
                                    text: body.batStatus.toUpperCase()
                                    Behavior on color { ColorAnimation { duration: 300 } }
                                }
                            }
                        }

                        MouseArea {
                            id: heroMa
                            anchors.fill: parent
                            hoverEnabled: true
                            cursorShape: Qt.PointingHandCursor
                            onEntered: batCanvas.requestPaint()
                            onExited: batCanvas.requestPaint()
                        }
                    }

                    // DOCKS INFERIORES
                    ColumnLayout {
                        anchors.bottom: parent.bottom
                        anchors.left: parent.left
                        anchors.right: parent.right
                        anchors.margins: 25
                        spacing: 15

                        // 1. sliders de hardware
                        Rectangle {
                            Layout.fillWidth: true
                            Layout.preferredHeight: 96
                            radius: 14
                            color: Theme.surface0
                            border.color: Theme.surface1
                            border.width: 1
                            opacity: body.introSliders
                            transform: Translate { y: 20 * (1.0 - body.introSliders) }

                            ColumnLayout {
                                anchors.fill: parent
                                anchors.margins: 14
                                spacing: 12

                                // brillo
                                RowLayout {
                                    Layout.fillWidth: true
                                    spacing: 15
                                    Item {
                                        Layout.preferredWidth: 32
                                        Layout.preferredHeight: 32
                                        Text {
                                            anchors.centerIn: parent
                                            text: Brightness.percent > 66 ? "󰃠" : (Brightness.percent > 33 ? "󰃟" : "󰃞")
                                            font.family: Theme.fontFamily
                                            font.pixelSize: 21
                                            color: body.ambientPrimary
                                            Behavior on color { ColorAnimation { duration: 200 } }
                                        }
                                    }
                                    Item {
                                        Layout.fillWidth: true
                                        Layout.preferredHeight: 18
                                        Rectangle {
                                            anchors.fill: parent
                                            radius: 9
                                            color: Theme.surface1
                                            border.color: Theme.surface2
                                            border.width: 1
                                            clip: true
                                            Rectangle {
                                                height: parent.height
                                                width: parent.width * (Brightness.percent / 100)
                                                radius: 9
                                                opacity: briMa.containsMouse ? 1.0 : 0.85
                                                Behavior on opacity { NumberAnimation { duration: 200 } }
                                                Behavior on width { enabled: !briMa.pressed; NumberAnimation { duration: 200; easing.type: Easing.OutQuint } }
                                                gradient: Gradient {
                                                    orientation: Gradient.Horizontal
                                                    GradientStop { position: 0.0; color: body.batColorStart; Behavior on color { ColorAnimation { duration: 300 } } }
                                                    GradientStop { position: 1.0; color: body.batColorEnd; Behavior on color { ColorAnimation { duration: 300 } } }
                                                }
                                            }
                                        }
                                        MouseArea {
                                            id: briMa
                                            anchors.fill: parent
                                            hoverEnabled: true
                                            cursorShape: Qt.PointingHandCursor
                                            onPressed: function(mouse) { upd(mouse.x); }
                                            onPositionChanged: function(mouse) { if (pressed) upd(mouse.x); }
                                            function upd(mx) {
                                                Brightness.set(Math.max(0, Math.min(100, Math.round((mx / width) * 100))));
                                            }
                                        }
                                    }
                                }

                                // volumen
                                RowLayout {
                                    Layout.fillWidth: true
                                    spacing: 15
                                    Rectangle {
                                        Layout.preferredWidth: 32
                                        Layout.preferredHeight: 32
                                        radius: 16
                                        color: volIconMa.containsMouse ? Theme.surface1 : "transparent"
                                        border.color: volIconMa.containsMouse ? body.profileStart : "transparent"
                                        Behavior on color { ColorAnimation { duration: 150 } }
                                        Text {
                                            anchors.centerIn: parent
                                            text: Audio.muted || Audio.percent === 0 ? "󰖁" : (Audio.percent > 50 ? "󰕾" : "󰖀")
                                            font.family: Theme.fontFamily
                                            font.pixelSize: 21
                                            color: Audio.muted ? Theme.overlay0 : body.profileStart
                                            Behavior on color { ColorAnimation { duration: 200 } }
                                        }
                                        MouseArea {
                                            id: volIconMa
                                            anchors.fill: parent
                                            hoverEnabled: true
                                            cursorShape: Qt.PointingHandCursor
                                            onClicked: Audio.toggleMute()
                                        }
                                    }
                                    Item {
                                        Layout.fillWidth: true
                                        Layout.preferredHeight: 18
                                        Rectangle {
                                            anchors.fill: parent
                                            radius: 9
                                            color: Theme.surface1
                                            border.color: Theme.surface2
                                            border.width: 1
                                            clip: true
                                            Rectangle {
                                                height: parent.height
                                                width: parent.width * Math.min(1, Audio.volume)
                                                radius: 9
                                                opacity: Audio.muted ? 0.5 : (volMa.containsMouse ? 1.0 : 0.85)
                                                Behavior on opacity { NumberAnimation { duration: 200 } }
                                                Behavior on width { enabled: !volMa.pressed; NumberAnimation { duration: 200; easing.type: Easing.OutQuint } }
                                                gradient: Gradient {
                                                    orientation: Gradient.Horizontal
                                                    GradientStop { position: 0.0; color: Audio.muted ? Theme.surface2 : body.profileStart; Behavior on color { ColorAnimation { duration: 300 } } }
                                                    GradientStop { position: 1.0; color: Audio.muted ? Qt.lighter(Theme.surface2, 1.15) : body.profileEnd; Behavior on color { ColorAnimation { duration: 300 } } }
                                                }
                                            }
                                        }
                                        MouseArea {
                                            id: volMa
                                            anchors.fill: parent
                                            hoverEnabled: true
                                            cursorShape: Qt.PointingHandCursor
                                            onPressed: function(mouse) { upd(mouse.x); }
                                            onPositionChanged: function(mouse) { if (pressed) upd(mouse.x); }
                                            function upd(mx) {
                                                var v = Math.max(0, Math.min(1, mx / width));
                                                if (v > 0 && Audio.muted) Audio.toggleMute();
                                                Audio.setVolume(v);
                                            }
                                        }
                                    }
                                }
                            }
                        }

                        // 2. píldora de perfiles de energía
                        Rectangle {
                            Layout.fillWidth: true
                            Layout.preferredHeight: 54
                            radius: 14
                            color: Theme.surface0
                            border.color: Theme.surface1
                            border.width: 1
                            opacity: body.introProfiles
                            transform: Translate { y: 20 * (1.0 - body.introProfiles) }

                            Rectangle {
                                width: (parent.width - 2) / 3
                                height: parent.height - 2
                                y: 1
                                radius: 10
                                x: body.powerProfile === "performance" ? 1
                                 : body.powerProfile === "balanced" ? width + 1
                                 : (width * 2) + 1
                                Behavior on x { NumberAnimation { duration: 400; easing.type: Easing.OutBack; easing.overshoot: 1.2 } }
                                gradient: Gradient {
                                    orientation: Gradient.Horizontal
                                    GradientStop { position: 0.0; color: body.profileStart; Behavior on color { ColorAnimation { duration: 400 } } }
                                    GradientStop { position: 1.0; color: body.profileEnd; Behavior on color { ColorAnimation { duration: 400 } } }
                                }
                            }

                            RowLayout {
                                anchors.fill: parent
                                spacing: 0
                                Repeater {
                                    model: [
                                        { name: "performance", icon: "󰓅", label: I18n.t("Perf.") },
                                        { name: "balanced",    icon: "󰗑", label: I18n.t("Balanced") },
                                        { name: "power-saver", icon: "󰌪", label: I18n.t("Saving") }
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
                                                color: body.powerProfile === modelData.name ? Theme.crust : (profileMa.containsMouse ? Theme.text : Theme.subtext0)
                                                text: modelData.icon
                                                Behavior on color { ColorAnimation { duration: 200 } }
                                            }
                                            Text {
                                                font.family: Theme.fontFamily; font.weight: Font.Black; font.pixelSize: 12
                                                color: body.powerProfile === modelData.name ? Theme.crust : (profileMa.containsMouse ? Theme.text : Theme.subtext0)
                                                text: modelData.label
                                                Behavior on color { ColorAnimation { duration: 200 } }
                                            }
                                        }
                                        MouseArea {
                                            id: profileMa
                                            anchors.fill: parent; hoverEnabled: true; cursorShape: Qt.PointingHandCursor
                                            onClicked: {
                                                body.powerProfile = modelData.name;
                                                Quickshell.execDetached(["powerprofilesctl", "set", modelData.name]);
                                                profilePoller.running = true;
                                            }
                                        }
                                    }
                                }
                            }
                        }
                    }
                }
            }
        }
    }
}
