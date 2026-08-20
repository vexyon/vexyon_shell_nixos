import QtQuick
import QtQuick.Layouts
import qs.services
import qs.components

// ============================================================================
//  CalendarPanel — port 1:1 del CalendarPopup de ilyamiro (1450x750), el
//  "dashboard" que abre el reloj: hub central de reloj respirando en 3D
//  (levitación + balanceo pitch/yaw/roll, HH:mm gigante + :ss en acento con
//  pulso por segundo, fecha), órbita elíptica punteada con la previsión
//  horaria en píldoras 3D (la hora actual resaltada y a escala 1.4), ala
//  izquierda calendario de cristal (mes navegable con hoy en acento), ala
//  derecha meteo (selector de día ‹ › con spin 3D de la órbita, temperatura
//  gigante que cuenta con glow rojo/azul según sube/baja, 4 medidores
//  circulares VIENTO/HUMEDAD/LLUVIA/SENSACIÓN) y glifo meteorológico gigante
//  en parallax de fondo. Colores dirigidos por la hora del día (mañana/
//  tarde/noche) como ilyamiro. Backend: Time + Weather (forecast 3 días).
//  Diferencia consciente: sin sección de agenda inferior (sin backend de
//  agenda en Vexyon — diferido).
// ============================================================================
AnchoredPanel {
    id: cp
    panelKey: "calendarPanel"
    ns: "vexyon-calendar"
    panelWidth: screen ? Math.min(1450, screen.width - 60) : 1450
    contentMargin: 0
    accentColor: Theme.mauve

    onShownChanged: if (shown && !Weather.ok) Weather.refresh()

    content: Component {
        Item {
            id: body
            width: cp.panelWidth
            implicitHeight: 700

            property real introContent: 1
            // submenú: vista de ayuda de atajos superpuesta sobre el dashboard
            property bool showKeybinds: false

            // El reloj del panel muestra ":ss" — mientras el contenido exista
            // (solo con el panel abierto: Loader de AnchoredPanel) exige el
            // tick de 1s de Time; cerrado, Time vuelve al tick por minuto.
            Component.onCompleted: Time.ssWatchers++
            Component.onDestruction: Time.ssWatchers--

            // atajos agrupados por categoría, leídos de Config.keybinds
            function keybindGroups() {
                var kb = Config.keybinds || [];
                var order = [], byCat = {};
                for (var i = 0; i < kb.length; i++) {
                    var c = kb[i].category || I18n.t("Other");
                    if (byCat[c] === undefined) { byCat[c] = []; order.push(c); }
                    byCat[c].push(kb[i]);
                }
                var out = [];
                for (var j = 0; j < order.length; j++) out.push({ cat: order[j], binds: byCat[order[j]] });
                return out;
            }
            function comboText(b) {
                return (b.mods || []).concat([b.key]).join(" + ");
            }

            // ---- colores por hora del día (ilyamiro) ------------------------
            readonly property color timeColor: {
                var h = Time.now.getHours();
                if (h >= 5 && h < 12) return Theme.peach;
                if (h >= 12 && h < 17) return Qt.lighter(Theme.blue, 1.08);
                if (h >= 17 && h < 21) return Theme.mauve;
                return Theme.blue;
            }
            readonly property color timeAccent: {
                var h = Time.now.getHours();
                if (h >= 5 && h < 12) return Theme.yellow;
                if (h >= 12 && h < 17) return Theme.teal;
                if (h >= 17 && h < 21) return Theme.pink;
                return Theme.mauve;
            }
            readonly property color textAccent: Qt.tint(timeAccent, Qt.rgba(Theme.text.r, Theme.text.g, Theme.text.b, 0.35))
            property color panelAccent: timeColor

            // ---- pulso por segundo ----
            property real secondPulse: 1.0
            NumberAnimation on secondPulse { id: pulseReset; to: 1.0; duration: 600; easing.type: Easing.OutQuint; running: false }
            Connections {
                target: Time
                function onNowChanged() {
                    body.secondPulse = 1.06;
                    pulseReset.start();
                }
            }

            // ---- vista meteo + transición spin 3D ----
            property int weatherView: 0
            property int targetWeatherView: 0
            property real weatherContentOpacity: 1.0
            property real weatherContentOffset: 0.0
            property int weatherAnimDirection: 1
            property real transitionSpin: 0.0
            property real transitionScale: 1.0

            readonly property var fc: Weather.forecast
            readonly property var curFc: fc.length > weatherView ? fc[weatherView] : null
            readonly property color activeWeatherHex: curFc ? (curFc.sunny ? Theme.yellow : Qt.lighter(Theme.blue, 1.1)) : Theme.mauve
            readonly property int activeHourIndex: Math.floor(Time.now.getHours() / 3)

            function setWeatherView(v) {
                if (fc.length === 0) return;
                var nv = ((v % fc.length) + fc.length) % fc.length;
                if (nv === targetWeatherView || weatherTransitionAnim.running) return;
                weatherAnimDirection = nv > targetWeatherView ? 1 : -1;
                targetWeatherView = nv;
                weatherTransitionAnim.start();
            }
            SequentialAnimation {
                id: weatherTransitionAnim
                ParallelAnimation {
                    NumberAnimation { target: body; property: "weatherContentOpacity"; to: 0.0; duration: 250; easing.type: Easing.InSine }
                    NumberAnimation { target: body; property: "weatherContentOffset"; to: -40 * body.weatherAnimDirection; duration: 250; easing.type: Easing.InSine }
                    NumberAnimation { target: body; property: "transitionSpin"; to: 180 * body.weatherAnimDirection; duration: 300; easing.type: Easing.InBack }
                    NumberAnimation { target: body; property: "transitionScale"; to: 0.8; duration: 300; easing.type: Easing.InCubic }
                }
                ScriptAction {
                    script: {
                        body.weatherView = body.targetWeatherView;
                        body.weatherContentOffset = 40 * body.weatherAnimDirection;
                        body.transitionSpin = -180 * body.weatherAnimDirection;
                    }
                }
                ParallelAnimation {
                    NumberAnimation { target: body; property: "weatherContentOpacity"; to: 1.0; duration: 350; easing.type: Easing.OutSine }
                    NumberAnimation { target: body; property: "weatherContentOffset"; to: 0.0; duration: 350; easing.type: Easing.OutSine }
                    NumberAnimation { target: body; property: "transitionSpin"; to: 0.0; duration: 400; easing.type: Easing.OutBack }
                    NumberAnimation { target: body; property: "transitionScale"; to: 1.0; duration: 400; easing.type: Easing.OutCubic }
                }
            }

            // temperatura con contador y glow según dirección
            readonly property real targetTemp: fc.length > targetWeatherView && fc[targetWeatherView] ? fc[targetWeatherView].temp : 0
            property real displayedTemp: targetTemp
            Behavior on displayedTemp { NumberAnimation { id: tempAnim; duration: 800; easing.type: Easing.OutQuart } }
            readonly property color tempGlowColor: {
                if (!tempAnim.running) return Theme.text;
                if (targetTemp > displayedTemp) return Theme.red;
                if (targetTemp < displayedTemp) return Theme.blue;
                return Theme.text;
            }

            // ---- calendario (mes navegable, lunes primero) ----
            property int monthOffset: 0
            property var calendarDays: buildMonth(0)
            property string monthName: ""
            function setMonthOffset(o) {
                monthOffset = o;
                calendarDays = buildMonth(o);
            }
            function buildMonth(o) {
                var now = new Date();
                var first = new Date(now.getFullYear(), now.getMonth() + o, 1);
                monthName = first.toLocaleDateString(I18n.locale, "MMMM yyyy");
                var startDow = (first.getDay() + 6) % 7;   // lunes = 0
                var daysInMonth = new Date(first.getFullYear(), first.getMonth() + 1, 0).getDate();
                var prevDays = new Date(first.getFullYear(), first.getMonth(), 0).getDate();
                var out = [];
                for (var i = 0; i < 42; i++) {
                    var dayNum, current = true;
                    if (i < startDow) { dayNum = prevDays - startDow + 1 + i; current = false; }
                    else if (i - startDow + 1 > daysInMonth) { dayNum = i - startDow + 1 - daysInMonth; current = false; }
                    else dayNum = i - startDow + 1;
                    var today = o === 0 && current && dayNum === now.getDate();
                    out.push({ dayNum: dayNum, isCurrentMonth: current, isToday: today });
                }
                return out;
            }

            // =================================================================
            //  GLIFO METEOROLÓGICO GIGANTE (parallax de fondo)
            // =================================================================
            Text {
                anchors.centerIn: parent
                anchors.verticalCenterOffset: -30
                text: body.curFc ? body.curFc.glyph : ""
                font.family: Theme.fontFamily
                font.pixelSize: 600
                color: body.activeWeatherHex
                opacity: (0.04 + 0.01 * Math.sin(cp.orbit * 4)) * body.weatherContentOpacity * body.introContent
                z: 0
                Behavior on color { ColorAnimation { duration: 1500 } }
                property real drift: 0
                SequentialAnimation on drift {
                    loops: Animation.Infinite; running: cp.shown
                    NumberAnimation { to: -20; duration: 6000; easing.type: Easing.InOutSine }
                    NumberAnimation { to: 0; duration: 6000; easing.type: Easing.InOutSine }
                }
                transform: [
                    Translate { y: parent.drift },
                    Translate { x: body.weatherContentOffset * 2 }
                ]
            }

            // =================================================================
            //  HUB CENTRAL: reloj respirando + órbita horaria 3D
            // =================================================================
            Item {
                id: centralHub
                anchors.centerIn: parent
                anchors.verticalCenterOffset: -30
                width: 1; height: 1
                z: 5
                opacity: body.introContent
                scale: 0.85 + (0.15 * body.introContent)

                property real levitation: 0
                SequentialAnimation on levitation {
                    loops: Animation.Infinite; running: cp.shown
                    NumberAnimation { to: -15; duration: 4000; easing.type: Easing.InOutSine }
                    NumberAnimation { to: 0; duration: 4000; easing.type: Easing.InOutSine }
                }
                property real orbitBreath: 1.0
                SequentialAnimation on orbitBreath {
                    loops: Animation.Infinite; running: cp.shown
                    NumberAnimation { to: 1.035; duration: 3500; easing.type: Easing.InOutSine }
                    NumberAnimation { to: 1.0; duration: 3500; easing.type: Easing.InOutSine }
                }
                property real pitchBreath: 0
                SequentialAnimation on pitchBreath {
                    loops: Animation.Infinite; running: cp.shown
                    NumberAnimation { to: 3.5; duration: 4200; easing.type: Easing.InOutSine }
                    NumberAnimation { to: -3.5; duration: 4200; easing.type: Easing.InOutSine }
                }
                property real yawBreath: 0
                SequentialAnimation on yawBreath {
                    loops: Animation.Infinite; running: cp.shown
                    NumberAnimation { to: 2.5; duration: 5100; easing.type: Easing.InOutSine }
                    NumberAnimation { to: -2.5; duration: 5100; easing.type: Easing.InOutSine }
                }
                property real rollBreath: 0
                SequentialAnimation on rollBreath {
                    loops: Animation.Infinite; running: cp.shown
                    NumberAnimation { to: 1.5; duration: 5800; easing.type: Easing.InOutSine }
                    NumberAnimation { to: -1.5; duration: 5800; easing.type: Easing.InOutSine }
                }
                transform: [
                    Translate { y: centralHub.levitation },
                    Rotation { axis { x: 1; y: 0; z: 0 } angle: centralHub.pitchBreath },
                    Rotation { axis { x: 0; y: 1; z: 0 } angle: centralHub.yawBreath },
                    Rotation { axis { x: 0; y: 0; z: 1 } angle: centralHub.rollBreath }
                ]

                // radios de la órbita (encogen si el panel es estrecho)
                readonly property real orbRx: Math.max(250, body.width / 2 - 420)
                readonly property real orbRy: 140

                // elipse punteada
                Canvas {
                    id: orbitCanvas
                    z: -10
                    x: -400; y: -200
                    width: 800; height: 400
                    opacity: 0.25
                    scale: centralHub.orbitBreath
                    Component.onCompleted: requestPaint()
                    onPaint: {
                        var ctx = getContext("2d");
                        ctx.clearRect(0, 0, width, height);
                        ctx.beginPath();
                        var rx = Math.min(centralHub.orbRx, 380), ry = centralHub.orbRy;
                        for (var i = 0; i <= Math.PI * 2; i += 0.05) {
                            var xx = width / 2 + Math.cos(i) * rx;
                            var yy = height / 2 + Math.sin(i) * ry;
                            if (i === 0) ctx.moveTo(xx, yy); else ctx.lineTo(xx, yy);
                        }
                        ctx.strokeStyle = body.textAccent;
                        ctx.lineWidth = 1.5;
                        ctx.setLineDash([4, 10]);
                        ctx.stroke();
                    }
                }

                // reloj núcleo
                ColumnLayout {
                    anchors.centerIn: parent
                    spacing: 0
                    z: 0
                    scale: 0.95 + (0.05 * body.secondPulse)

                    RowLayout {
                        Layout.alignment: Qt.AlignHCenter
                        spacing: 2
                        Text {
                            text: Qt.formatTime(Time.now, "HH:mm")
                            font.family: Theme.fontFamily
                            font.weight: Font.Black
                            font.pixelSize: 84
                            color: Theme.text
                            style: Text.Outline; styleColor: Qt.rgba(Theme.crust.r, Theme.crust.g, Theme.crust.b, 0.4)
                        }
                        Text {
                            text: Qt.formatTime(Time.now, ":ss")
                            font.family: Theme.fontFamily
                            font.weight: Font.Bold
                            font.pixelSize: 32
                            color: body.textAccent
                            Layout.alignment: Qt.AlignBottom
                            Layout.bottomMargin: 15
                            opacity: body.secondPulse > 1.02 ? 1.0 : 0.6
                            style: Text.Outline; styleColor: Qt.rgba(Theme.crust.r, Theme.crust.g, Theme.crust.b, 0.4)
                            Behavior on color { ColorAnimation { duration: 1000 } }
                        }
                    }
                    Text {
                        Layout.alignment: Qt.AlignHCenter
                        text: Time.now.toLocaleDateString(I18n.locale, "dddd, d MMMM")
                        font.family: Theme.fontFamily
                        font.weight: Font.Bold
                        font.pixelSize: 16
                        color: Theme.subtext0
                        opacity: 0.9
                    }
                }

                // órbita horaria 3D
                Item {
                    anchors.fill: parent
                    opacity: body.weatherContentOpacity
                    scale: body.transitionScale
                    transform: Translate { x: body.weatherContentOffset * 1.5 }

                    Repeater {
                        id: hourRepeater
                        model: body.curFc && body.curFc.hourly ? body.curFc.hourly.slice(0, 8) : []

                        delegate: Item {
                            id: hourPill
                            required property var modelData
                            required property int index

                            property bool isToday: body.weatherView === 0
                            property bool isHighlighted: isToday && index === body.activeHourIndex
                            property real rx: centralHub.orbRx * centralHub.orbitBreath
                            property real ry: centralHub.orbRy * centralHub.orbitBreath
                            property int relIdx: isToday ? (index - body.activeHourIndex) : index
                            property real targetAngleDeg: isToday ? (65 + (relIdx * 30)) : (index * (360 / Math.max(1, hourRepeater.count)))
                            property real orbitOffset: isToday ? 0 : (cp.orbit * (180 / Math.PI) * -1.5)
                            property real osc: isToday ? (Math.sin(cp.orbit * 10 + index) * 5) : 0
                            property real rad: (targetAngleDeg + orbitOffset + osc + body.transitionSpin) * (Math.PI / 180)

                            x: Math.cos(rad) * rx - width / 2
                            y: Math.sin(rad) * ry - height / 2
                            z: Math.sin(rad) * 100
                            scale: isHighlighted ? 1.4 : (isToday ? (0.95 + 0.20 * Math.sin(rad)) : (0.90 + 0.25 * Math.sin(rad)))
                            opacity: isHighlighted ? 1.0 : (isToday ? (0.7 + 0.3 * ((Math.sin(rad) + 1) / 2)) : (0.65 + 0.35 * ((Math.sin(rad) + 1) / 2)))
                            width: 56; height: 95

                            Rectangle {
                                anchors.fill: parent
                                radius: 28
                                color: hourPill.isHighlighted ? body.textAccent : (hrMa.containsMouse ? Theme.surface2 : Theme.surface0)
                                border.color: hourPill.isHighlighted ? "transparent" : (hrMa.containsMouse ? body.textAccent : Theme.surface1)
                                border.width: 1
                                Behavior on color { ColorAnimation { duration: 200 } }

                                ColumnLayout {
                                    anchors.centerIn: parent
                                    spacing: 4
                                    Text {
                                        Layout.alignment: Qt.AlignHCenter
                                        text: hourPill.modelData.time
                                        font.family: Theme.fontFamily; font.weight: Font.Bold; font.pixelSize: 12
                                        color: hourPill.isHighlighted ? Theme.base : (hrMa.containsMouse ? Theme.text : Theme.overlay1)
                                    }
                                    Text {
                                        Layout.alignment: Qt.AlignHCenter
                                        text: hourPill.modelData.glyph
                                        font.family: Theme.fontFamily; font.pixelSize: 18
                                        color: hourPill.isHighlighted ? Theme.base : (hourPill.modelData.sunny ? Theme.yellow : Theme.text)
                                    }
                                    Text {
                                        Layout.alignment: Qt.AlignHCenter
                                        text: hourPill.modelData.temp + "°"
                                        font.family: Theme.fontFamily; font.weight: Font.Black; font.pixelSize: 14
                                        color: hourPill.isHighlighted ? Theme.base : Theme.text
                                    }
                                }
                            }
                            MouseArea { id: hrMa; anchors.fill: parent; hoverEnabled: true; cursorShape: Qt.PointingHandCursor }
                        }
                    }
                }
            }

            // =================================================================
            //  ALA IZQUIERDA: calendario de cristal
            // =================================================================
            Rectangle {
                id: calendarRect
                anchors.left: parent.left
                anchors.top: parent.top
                anchors.margins: 40
                width: 320
                height: 420
                color: Qt.rgba(Theme.surface0.r, Theme.surface0.g, Theme.surface0.b, 0.2)
                radius: 14
                border.color: Qt.rgba(Theme.surface1.r, Theme.surface1.g, Theme.surface1.b, 0.4)
                border.width: 1
                z: 10
                opacity: body.introContent
                transform: Translate { x: -40 * (1.0 - body.introContent) }

                ColumnLayout {
                    anchors.fill: parent
                    anchors.margins: 25
                    spacing: 15

                    RowLayout {
                        Layout.fillWidth: true

                        Rectangle {
                            Layout.preferredWidth: 32; Layout.preferredHeight: 32; radius: 16
                            color: homeMa.containsMouse ? Theme.surface1 : "transparent"
                            opacity: body.monthOffset !== 0 ? 1.0 : 0.0
                            visible: opacity > 0
                            Behavior on opacity { NumberAnimation { duration: 200 } }
                            Text { anchors.centerIn: parent; text: "󰋜"; font.family: Theme.fontFamily; color: Theme.text; font.pixelSize: 14 }
                            MouseArea {
                                id: homeMa; anchors.fill: parent; hoverEnabled: body.monthOffset !== 0
                                cursorShape: Qt.PointingHandCursor
                                onClicked: if (body.monthOffset !== 0) body.setMonthOffset(0)
                            }
                        }
                        Rectangle {
                            Layout.preferredWidth: 32; Layout.preferredHeight: 32; radius: 16
                            color: prevMa.containsMouse ? Theme.surface1 : "transparent"
                            Text { anchors.centerIn: parent; text: "󰅁"; font.family: Theme.fontFamily; color: Theme.text; font.pixelSize: 16 }
                            MouseArea { id: prevMa; anchors.fill: parent; hoverEnabled: true; cursorShape: Qt.PointingHandCursor; onClicked: body.setMonthOffset(body.monthOffset - 1) }
                        }
                        Text {
                            Layout.fillWidth: true
                            text: body.monthName.toUpperCase()
                            font.family: Theme.fontFamily
                            font.weight: Font.Black
                            font.pixelSize: 15
                            fontSizeMode: Text.Fit
                            minimumPixelSize: 8
                            color: Theme.text
                            horizontalAlignment: Text.AlignHCenter
                        }
                        Rectangle {
                            Layout.preferredWidth: 32; Layout.preferredHeight: 32; radius: 16
                            color: nextMa.containsMouse ? Theme.surface1 : "transparent"
                            Text { anchors.centerIn: parent; text: "󰅂"; font.family: Theme.fontFamily; color: Theme.text; font.pixelSize: 16 }
                            MouseArea { id: nextMa; anchors.fill: parent; hoverEnabled: true; cursorShape: Qt.PointingHandCursor; onClicked: body.setMonthOffset(body.monthOffset + 1) }
                        }
                    }

                    RowLayout {
                        Layout.fillWidth: true
                        Repeater {
                            model: [I18n.t("Mo"), I18n.t("Tu"), I18n.t("We"), I18n.t("Th"), I18n.t("Fr"), I18n.t("Sa"), I18n.t("Su")]
                            Text {
                                required property string modelData
                                Layout.fillWidth: true
                                text: modelData
                                font.family: Theme.fontFamily
                                font.weight: Font.Black
                                font.pixelSize: 13
                                color: Theme.overlay0
                                horizontalAlignment: Text.AlignHCenter
                            }
                        }
                    }

                    GridLayout {
                        Layout.fillWidth: true
                        Layout.fillHeight: true
                        columns: 7
                        rowSpacing: 6
                        columnSpacing: 6

                        Repeater {
                            model: body.calendarDays
                            Rectangle {
                                required property var modelData
                                Layout.fillWidth: true
                                Layout.fillHeight: true
                                color: modelData.isToday ? body.textAccent : (dayMa.containsMouse ? Qt.rgba(Theme.surface2.r, Theme.surface2.g, Theme.surface2.b, 0.4) : "transparent")
                                radius: 10
                                scale: dayMa.containsMouse ? 1.2 : 1.0
                                border.color: modelData.isToday ? Theme.surface0 : (dayMa.containsMouse ? Theme.overlay0 : "transparent")
                                border.width: modelData.isToday || dayMa.containsMouse ? 1 : 0
                                Behavior on color { ColorAnimation { duration: 150 } }
                                Behavior on scale { NumberAnimation { duration: 250; easing.type: Easing.OutBack } }
                                Text {
                                    anchors.centerIn: parent
                                    text: parent.modelData.dayNum
                                    font.family: Theme.fontFamily
                                    font.weight: parent.modelData.isToday ? Font.Black : Font.Bold
                                    font.pixelSize: 13
                                    color: parent.modelData.isToday ? Theme.base : (parent.modelData.isCurrentMonth ? Theme.text : Theme.surface2)
                                    Behavior on color { ColorAnimation { duration: 200 } }
                                }
                                MouseArea { id: dayMa; anchors.fill: parent; hoverEnabled: true }
                            }
                        }
                    }
                }
            }

            // =================================================================
            //  ALA DERECHA: meteo orgánica flotante
            // =================================================================
            Item {
                anchors.right: parent.right
                anchors.top: parent.top
                anchors.margins: 40
                width: 320
                height: 420
                z: 10
                opacity: body.introContent
                transform: Translate { x: 40 * (1.0 - body.introContent) }

                ColumnLayout {
                    anchors.fill: parent
                    spacing: 20

                    RowLayout {
                        Layout.fillWidth: true
                        spacing: 20
                        MouseArea {
                            id: wPrevMa
                            Layout.preferredWidth: 30; Layout.preferredHeight: 30; hoverEnabled: true
                            cursorShape: Qt.PointingHandCursor
                            onClicked: body.setWeatherView(body.targetWeatherView - 1)
                            property real pulseOffset: 0
                            SequentialAnimation on pulseOffset {
                                loops: Animation.Infinite; running: cp.shown
                                NumberAnimation { to: -3; duration: 1000; easing.type: Easing.InOutSine }
                                NumberAnimation { to: 0; duration: 1000; easing.type: Easing.InOutSine }
                            }
                            Text {
                                anchors.centerIn: parent; text: "󰅁"; font.family: Theme.fontFamily; font.pixelSize: 18
                                color: wPrevMa.containsMouse ? body.textAccent : Theme.overlay1
                                transform: Translate { x: wPrevMa.containsMouse ? -5 : wPrevMa.pulseOffset }
                            }
                        }
                        Text {
                            Layout.fillWidth: true
                            horizontalAlignment: Text.AlignHCenter
                            text: body.curFc ? body.curFc.dayFull.toUpperCase() : I18n.t("LOADING…")
                            font.family: Theme.fontFamily
                            font.weight: Font.Black
                            font.pixelSize: 15
                            fontSizeMode: Text.Fit
                            minimumPixelSize: 8
                            color: Theme.text
                        }
                        MouseArea {
                            id: wNextMa
                            Layout.preferredWidth: 30; Layout.preferredHeight: 30; hoverEnabled: true
                            cursorShape: Qt.PointingHandCursor
                            onClicked: body.setWeatherView(body.targetWeatherView + 1)
                            property real pulseOffset: 0
                            SequentialAnimation on pulseOffset {
                                loops: Animation.Infinite; running: cp.shown
                                NumberAnimation { to: 3; duration: 1000; easing.type: Easing.InOutSine }
                                NumberAnimation { to: 0; duration: 1000; easing.type: Easing.InOutSine }
                            }
                            Text {
                                anchors.centerIn: parent; text: "󰅂"; font.family: Theme.fontFamily; font.pixelSize: 18
                                color: wNextMa.containsMouse ? body.textAccent : Theme.overlay1
                                transform: Translate { x: wNextMa.containsMouse ? 5 : wNextMa.pulseOffset }
                            }
                        }
                    }

                    ColumnLayout {
                        Layout.alignment: Qt.AlignRight
                        spacing: -5
                        Text {
                            Layout.alignment: Qt.AlignRight
                            text: Math.round(body.displayedTemp) + "°"
                            font.family: Theme.fontFamily
                            font.weight: Font.Black
                            font.pixelSize: 84
                            color: body.tempGlowColor
                            style: Text.Outline
                            styleColor: tempAnim.running ? Qt.rgba(body.tempGlowColor.r, body.tempGlowColor.g, body.tempGlowColor.b, 0.5) : Qt.rgba(Theme.crust.r, Theme.crust.g, Theme.crust.b, 0.4)
                            Behavior on color { ColorAnimation { duration: 300 } }
                        }
                        Text {
                            Layout.alignment: Qt.AlignRight
                            Layout.maximumWidth: 320
                            horizontalAlignment: Text.AlignRight
                            text: body.curFc ? body.curFc.desc : ""
                            font.family: Theme.fontFamily
                            font.weight: Font.Bold
                            font.pixelSize: 15
                            wrapMode: Text.WordWrap
                            color: body.textAccent
                            Behavior on color { ColorAnimation { duration: 1000 } }
                            opacity: body.weatherContentOpacity
                            transform: Translate { x: body.weatherContentOffset }
                        }
                    }

                    Item { Layout.fillHeight: true }

                    // 4 medidores circulares
                    RowLayout {
                        Layout.fillWidth: true
                        Layout.alignment: Qt.AlignHCenter
                        spacing: 8

                        Repeater {
                            model: 4
                            Item {
                                id: gaugeWrapper
                                required property int index
                                Layout.fillWidth: true
                                Layout.preferredHeight: 100
                                scale: gaugeMa.containsMouse ? 1.15 : 1.0
                                Behavior on scale { NumberAnimation { duration: 250; easing.type: Easing.OutBack } }

                                property var fday: body.fc.length > body.targetWeatherView ? body.fc[body.targetWeatherView] : null
                                property string gaugeIcon: index === 0 ? "󰖝" : index === 1 ? "󰖌" : index === 2 ? "󰖗" : "󰔏"
                                property string gaugeLbl: index === 0 ? I18n.t("WIND") : index === 1 ? I18n.t("HUMIDITY") : index === 2 ? I18n.t("RAIN") : I18n.t("FEELS")
                                property string gaugeVal: fday ? (
                                    index === 0 ? fday.wind + "km/h" :
                                    index === 1 ? fday.humidity + "%" :
                                    index === 2 ? fday.pop + "%" :
                                    fday.feelsLike + "°") : ""
                                property real gaugeFill: fday ? (
                                    index === 0 ? Math.min(1.0, fday.wind / 80.0) :
                                    index === 1 ? fday.humidity / 100.0 :
                                    index === 2 ? fday.pop / 100.0 :
                                    Math.max(0.0, Math.min(1.0, (fday.feelsLike + 15) / 55.0))) : 0.0

                                ColumnLayout {
                                    anchors.centerIn: parent
                                    spacing: 6

                                    Item {
                                        Layout.alignment: Qt.AlignHCenter
                                        Layout.preferredWidth: 60
                                        Layout.preferredHeight: 60

                                        Rectangle {
                                            anchors.fill: parent
                                            radius: width / 2
                                            color: body.textAccent
                                            opacity: gaugeMa.containsMouse ? 0.3 : 0.0
                                            Behavior on opacity { NumberAnimation { duration: 200 } }
                                        }
                                        Canvas {
                                            id: gaugeCanvas
                                            anchors.fill: parent
                                            rotation: -90
                                            property real animProgress: gaugeWrapper.gaugeFill
                                            Behavior on animProgress { NumberAnimation { duration: 1000; easing.type: Easing.OutExpo } }
                                            onAnimProgressChanged: requestPaint()
                                            Component.onCompleted: requestPaint()
                                            onPaint: {
                                                var ctx = getContext("2d");
                                                ctx.clearRect(0, 0, width, height);
                                                var r = width / 2;
                                                ctx.beginPath();
                                                ctx.arc(r, r, r - 4, 0, 2 * Math.PI);
                                                ctx.strokeStyle = Qt.rgba(Theme.text.r, Theme.text.g, Theme.text.b, 0.1);
                                                ctx.lineWidth = 3;
                                                ctx.stroke();
                                                if (animProgress > 0) {
                                                    ctx.beginPath();
                                                    ctx.arc(r, r, r - 4, 0, animProgress * 2 * Math.PI);
                                                    var grad = ctx.createLinearGradient(0, 0, width, height);
                                                    grad.addColorStop(0, body.timeAccent.toString());
                                                    grad.addColorStop(1, Theme.blue.toString());
                                                    ctx.strokeStyle = grad;
                                                    ctx.lineWidth = 4;
                                                    ctx.lineCap = "round";
                                                    ctx.stroke();
                                                }
                                            }
                                        }
                                        Text {
                                            anchors.centerIn: parent
                                            text: gaugeWrapper.gaugeVal
                                            font.family: Theme.fontFamily
                                            font.weight: Font.Black
                                            font.pixelSize: 11
                                            color: Theme.text
                                        }
                                    }

                                    RowLayout {
                                        Layout.alignment: Qt.AlignHCenter
                                        spacing: 4
                                        Text {
                                            text: gaugeWrapper.gaugeIcon
                                            font.family: Theme.fontFamily
                                            font.pixelSize: 12
                                            color: gaugeMa.containsMouse ? body.textAccent : Theme.overlay0
                                            Behavior on color { ColorAnimation { duration: 200 } }
                                        }
                                        Text {
                                            text: gaugeWrapper.gaugeLbl
                                            font.family: Theme.fontFamily
                                            font.weight: Font.Bold
                                            font.pixelSize: 10
                                            color: Theme.overlay0
                                        }
                                    }
                                }
                                MouseArea { id: gaugeMa; anchors.fill: parent; hoverEnabled: true }
                            }
                        }
                    }
                }
            }

            // =================================================================
            //  SUBMENÚ: fila de acciones abajo-centro
            //  (power / ajustes de la shell / ayuda de atajos)
            // =================================================================
            RowLayout {
                anchors.horizontalCenter: parent.horizontalCenter
                anchors.bottom: parent.bottom
                anchors.bottomMargin: 30
                spacing: 12
                z: 20
                opacity: body.introContent * (body.showKeybinds ? 0.0 : 1.0)
                visible: opacity > 0.01
                Repeater {
                    model: [
                        { l: I18n.t("Power"),    g: Icons.power,    act: "power" },
                        { l: I18n.t("Settings"),         g: Icons.gear,     act: "settings" },
                        { l: I18n.t("Keyboard shortcuts"), g: Icons.keyboard, act: "keybinds" }
                    ]
                    delegate: Rectangle {
                        required property var modelData
                        Layout.preferredHeight: 40
                        Layout.preferredWidth: subRow.implicitWidth + 30
                        radius: Theme.radius
                        color: subMa.containsMouse ? Theme.surface1 : Qt.rgba(Theme.surface0.r, Theme.surface0.g, Theme.surface0.b, 0.55)
                        border.width: 1
                        border.color: subMa.containsMouse ? body.textAccent : Qt.rgba(Theme.surface1.r, Theme.surface1.g, Theme.surface1.b, 0.5)
                        Behavior on color { ColorAnimation { duration: Theme.dur(140) } }
                        RowLayout {
                            id: subRow
                            anchors.centerIn: parent
                            spacing: 9
                            Text { text: modelData.g; color: subMa.containsMouse ? body.textAccent : Theme.text; font.family: Theme.fontFamily; font.pixelSize: Theme.fontSize + 2 }
                            Text { text: modelData.l; color: Theme.text; font.family: Theme.fontFamily; font.pixelSize: Theme.fontSize - 1; font.bold: true }
                        }
                        MouseArea {
                            id: subMa
                            anchors.fill: parent; hoverEnabled: true; cursorShape: Qt.PointingHandCursor
                            onClicked: {
                                if (modelData.act === "keybinds") { body.showKeybinds = true; return; }
                                cp.close();
                                if (modelData.act === "settings") Panels.settings = true;
                                else Panels.open("powermenu");
                            }
                        }
                    }
                }
            }

            // =================================================================
            //  VISTA DE AYUDA DE ATAJOS (overlay, solo lectura)
            // =================================================================
            Rectangle {
                anchors.fill: parent
                z: 40
                visible: body.showKeybinds
                color: Theme.base
                radius: Theme.radius + 8

                ColumnLayout {
                    anchors.fill: parent
                    anchors.margins: 40
                    spacing: 18

                    // cabecera: volver + título
                    RowLayout {
                        Layout.fillWidth: true
                        spacing: 14
                        Rectangle {
                            Layout.preferredWidth: 40; Layout.preferredHeight: 40; radius: 20
                            color: backMa.containsMouse ? Theme.surface1 : Theme.surface0
                            Behavior on color { ColorAnimation { duration: Theme.dur(140) } }
                            Text { anchors.centerIn: parent; text: Icons.back; color: Theme.text; font.family: Theme.fontFamily; font.pixelSize: Theme.fontSize + 2 }
                            MouseArea { id: backMa; anchors.fill: parent; hoverEnabled: true; cursorShape: Qt.PointingHandCursor; onClicked: body.showKeybinds = false }
                        }
                        Text { text: I18n.t("Keyboard shortcuts"); color: Theme.text; font.family: Theme.fontFamily; font.weight: Font.Black; font.pixelSize: 22 }
                        Item { Layout.fillWidth: true }
                        Text {
                            text: (Config.keybinds ? Config.keybinds.length : 0) + I18n.t(" shortcuts")
                            color: Theme.overlay1; font.family: Theme.fontFamily; font.pixelSize: Theme.fontSize - 1
                        }
                    }
                    Rectangle { Layout.fillWidth: true; height: 1; color: Theme.surface1; opacity: 0.5 }

                    // lista agrupada por categoría, en 2 columnas
                    Flickable {
                        Layout.fillWidth: true; Layout.fillHeight: true
                        contentHeight: kbFlow.implicitHeight
                        clip: true
                        boundsBehavior: Flickable.StopAtBounds
                        Grid {
                            id: kbFlow
                            width: parent.width
                            columns: 2
                            columnSpacing: 40
                            rowSpacing: 22
                            Repeater {
                                model: body.keybindGroups()
                                delegate: ColumnLayout {
                                    required property var modelData
                                    width: (kbFlow.width - kbFlow.columnSpacing) / 2
                                    spacing: 6
                                    Text {
                                        text: I18n.t(modelData.cat).toUpperCase()
                                        color: body.textAccent; font.family: Theme.fontFamily
                                        font.weight: Font.Black; font.pixelSize: Theme.fontSize - 2
                                    }
                                    Repeater {
                                        model: modelData.binds
                                        delegate: RowLayout {
                                            required property var modelData
                                            Layout.fillWidth: true
                                            spacing: 12
                                            Text {
                                                Layout.fillWidth: true
                                                text: I18n.t(modelData.desc || modelData.id)
                                                color: Theme.subtext1; font.family: Theme.fontFamily; font.pixelSize: Theme.fontSize - 1
                                                elide: Text.ElideRight
                                            }
                                            Rectangle {
                                                Layout.preferredHeight: 26
                                                Layout.preferredWidth: comboLbl.implicitWidth + 18
                                                radius: Theme.radius - 2
                                                color: Theme.surface1
                                                border.width: 1; border.color: Theme.overlay0
                                                Text {
                                                    id: comboLbl
                                                    anchors.centerIn: parent
                                                    text: body.comboText(modelData)
                                                    color: Theme.text; font.family: Theme.fontFamily; font.pixelSize: Theme.fontSize - 2; font.bold: true
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
}
