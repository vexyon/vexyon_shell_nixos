import QtQuick
import QtQuick.Layouts
import Quickshell
import Quickshell.Io
import qs.services
import qs.components

// ============================================================================
//  SystemMonitorPanel — anchored dropdown from the CPU/GPU/temp widgets.
//  Cabecera = rejilla "LiquidSquare" portada 1:1 de quickactions/SystemUsage
//  de ilyamiro: CPU/RAM/TEMP arriba + DISCO/RED abajo, cada celda con relleno
//  líquido ondulante (Canvas, fase compartida) y texto doble (claro fuera,
//  crust dentro del líquido, recortado por la onda), tonos mauve escalonados.
//  Debajo se conserva la lista de procesos de Vexyon (kill / copiar PID /
//  copiar comando) — ilyamiro no tiene equivalente de lista de procesos.
// ============================================================================
AnchoredPanel {
    id: sm
    panelKey: "sysMonitor"
    ns: "vexyon-sysmonitor"
    panelWidth: 480
    accentColor: Theme.mauve

    property var procs: []
    onShownChanged: { if (shown) { psProc.running = true; diskProc.running = true; poll.start(); } else poll.stop(); }

    // texto "usado / total" del disco (df sobre $HOME, como ilyamiro)
    property string diskText: "…"
    Process {
        id: diskProc
        command: ["bash", "-c", "df -h ~ | awk 'NR==2{printf(\"%s / %s\", $3, $2)}'"]
        stdout: StdioCollector { onStreamFinished: sm.diskText = this.text.trim() }
    }

    Timer { id: poll; interval: 2500; repeat: true; onTriggered: psProc.running = true }
    Process {
        id: psProc
        command: ["bash", "-c", "ps -eo pid,pcpu,pmem,comm --sort=-pcpu --no-headers 2>/dev/null | head -12"]
        stdout: StdioCollector {
            onStreamFinished: {
                var lines = this.text.trim().split("\n");
                var out = [];
                for (var i = 0; i < lines.length; i++) {
                    var p = lines[i].trim().split(/\s+/);
                    if (p.length < 4) continue;
                    out.push({ pid: p[0], cpu: parseFloat(p[1]) || 0, mem: parseFloat(p[2]) || 0, name: p.slice(3).join(" ") });
                }
                sm.procs = out;
            }
        }
    }
    function killPid(pid) { Quickshell.execDetached(["bash", "-c", "kill " + pid]); psProc.running = true; }
    function copy(text) { Quickshell.execDetached(["bash", "-c", "printf %s " + JSON.stringify("" + text) + " | wl-copy"]); }
    function copyCmd(pid) { Quickshell.execDetached(["bash", "-c", "ps -p " + pid + " -o args= | tr -d '\\n' | wl-copy"]); }

    content: Component {
        ColumnLayout {
            id: body
            width: sm.panelWidth - sm.contentMargin * 2
            spacing: 12
            property real introHeader: 1
            property real introContent: 1

            // el panel muestra SystemStats mientras está abierto — refcount
            // propio por si algún día se abre sin pastillas monitor en la barra
            Component.onCompleted: SystemStats.watchers++
            Component.onDestruction: SystemStats.watchers--

            // fase de onda compartida por todas las celdas (ilyamiro globalWavePhase)
            property real wavePhase: 0.0
            NumberAnimation on wavePhase {
                from: 0; to: Math.PI * 2; duration: 1800; loops: Animation.Infinite; running: sm.shown
            }

            // valores suavizados (800ms OutQuint, como ilyamiro)
            property real cpuVal: SystemStats.cpuPercent / 100
            Behavior on cpuVal { NumberAnimation { duration: 800; easing.type: Easing.OutQuint } }
            property real ramVal: SystemStats.memPercent / 100
            Behavior on ramVal { NumberAnimation { duration: 800; easing.type: Easing.OutQuint } }
            property real tempVal: Math.max(0, Math.min(1, SystemStats.cpuTemp / 100))
            Behavior on tempVal { NumberAnimation { duration: 800; easing.type: Easing.OutQuint } }
            property real diskVal: SystemStats.diskPercent / 100
            Behavior on diskVal { NumberAnimation { duration: 800; easing.type: Easing.OutQuint } }

            function fmtKbs(k) {
                if (k <= 0 || isNaN(k)) return "0 B/s";
                if (k < 1024) return k.toFixed(1) + " KB/s";
                return (k / 1024).toFixed(1) + " MB/s";
            }

            // ---- celda con relleno líquido (LiquidSquare de ilyamiro) ----
            component LiquidSquare: Item {
                id: ls
                property real value: 0.0
                property color colorFill: Theme.mauve
                property string icon: ""
                property string title: ""
                property string valueText: ""
                property string subText: ""
                default property alias childItems: customContent.data

                property real fillRatio: Math.max(0.0, Math.min(1.0, ls.value))
                property real fillY: height * (1.0 - ls.fillRatio)
                property real waveAmp: (ls.fillRatio < 0.99 && ls.fillRatio > 0.01) ? 6 * Math.sin(ls.fillRatio * Math.PI) : 0
                property real waveCenterOffset: 0.375 * ls.waveAmp * (Math.sin(body.wavePhase) - Math.cos(body.wavePhase))

                Rectangle {
                    anchors.fill: parent
                    radius: 12
                    color: Theme.surface0
                    border.color: Qt.rgba(Theme.text.r, Theme.text.g, Theme.text.b, 0.08)
                    border.width: 1
                }

                Canvas {
                    id: fluidCanvas
                    anchors.fill: parent
                    onPaint: {
                        var ctx = getContext("2d");
                        ctx.clearRect(0, 0, width, height);
                        if (ls.value <= 0) return;
                        ctx.save();
                        var r = 12;
                        ctx.beginPath();
                        ctx.moveTo(r, 0);
                        ctx.lineTo(width - r, 0);
                        ctx.quadraticCurveTo(width, 0, width, r);
                        ctx.lineTo(width, height - r);
                        ctx.quadraticCurveTo(width, height, width - r, height);
                        ctx.lineTo(r, height);
                        ctx.quadraticCurveTo(0, height, 0, height - r);
                        ctx.lineTo(0, r);
                        ctx.quadraticCurveTo(0, 0, r, 0);
                        ctx.closePath();
                        ctx.clip();
                        ctx.beginPath();
                        ctx.moveTo(0, ls.fillY);
                        if (ls.waveAmp > 0) {
                            var cp1y = ls.fillY + Math.sin(body.wavePhase) * ls.waveAmp;
                            var cp2y = ls.fillY + Math.cos(body.wavePhase + Math.PI) * ls.waveAmp;
                            ctx.bezierCurveTo(width * 0.33, cp2y, width * 0.66, cp1y, width, ls.fillY);
                            ctx.lineTo(width, height);
                            ctx.lineTo(0, height);
                        } else {
                            ctx.lineTo(width, ls.fillY);
                            ctx.lineTo(width, height);
                            ctx.lineTo(0, height);
                        }
                        ctx.closePath();
                        var grad = ctx.createLinearGradient(0, 0, 0, height);
                        grad.addColorStop(0, Qt.lighter(ls.colorFill, 1.25).toString());
                        grad.addColorStop(1, ls.colorFill.toString());
                        ctx.fillStyle = grad;
                        ctx.globalAlpha = 0.95;
                        ctx.fill();
                        ctx.restore();
                    }
                    Connections {
                        target: body
                        enabled: sm.shown && ls.value > 0
                        function onWavePhaseChanged() { fluidCanvas.requestPaint(); }
                    }
                }

                // texto base (fuera del líquido)
                Item {
                    anchors.fill: parent
                    anchors.margins: 12
                    Text {
                        id: baseIcon
                        anchors.top: parent.top; anchors.left: parent.left
                        font.family: Theme.fontFamily; font.pixelSize: 15
                        color: Theme.subtext0; text: ls.icon
                    }
                    Text {
                        anchors.verticalCenter: baseIcon.verticalCenter; anchors.right: parent.right
                        font.family: Theme.fontFamily; font.bold: true; font.pixelSize: 10
                        color: Theme.subtext0; text: ls.title
                    }
                    Text {
                        anchors.bottom: parent.bottom; anchors.left: parent.left; anchors.bottomMargin: 4
                        font.family: Theme.fontFamily; font.bold: true; font.pixelSize: 11
                        color: Theme.subtext0; text: ls.subText
                    }
                    Text {
                        anchors.bottom: parent.bottom; anchors.right: parent.right
                        font.family: Theme.fontFamily; font.weight: Font.Black; font.pixelSize: 22
                        color: Theme.text; text: ls.valueText
                    }
                }

                // texto crust recortado por la onda (dentro del líquido)
                Item {
                    id: waveClipBox
                    anchors.bottom: parent.bottom
                    anchors.left: parent.left
                    anchors.right: parent.right
                    height: Math.min(parent.height, Math.max(0, (parent.height * ls.fillRatio) - ls.waveCenterOffset))
                    clip: true
                    visible: ls.value > 0
                    Item {
                        anchors.bottom: parent.bottom
                        anchors.left: parent.left
                        anchors.right: parent.right
                        height: ls.height
                        anchors.margins: 12
                        Text {
                            id: filledIcon
                            anchors.top: parent.top; anchors.left: parent.left
                            font.family: Theme.fontFamily; font.pixelSize: 15
                            color: Qt.rgba(Theme.crust.r, Theme.crust.g, Theme.crust.b, 0.7); text: ls.icon
                        }
                        Text {
                            anchors.verticalCenter: filledIcon.verticalCenter; anchors.right: parent.right
                            font.family: Theme.fontFamily; font.bold: true; font.pixelSize: 10
                            color: Qt.rgba(Theme.crust.r, Theme.crust.g, Theme.crust.b, 0.7); text: ls.title
                        }
                        Text {
                            anchors.bottom: parent.bottom; anchors.left: parent.left; anchors.bottomMargin: 4
                            font.family: Theme.fontFamily; font.bold: true; font.pixelSize: 11
                            color: Theme.crust; text: ls.subText
                        }
                        Text {
                            anchors.bottom: parent.bottom; anchors.right: parent.right
                            font.family: Theme.fontFamily; font.weight: Font.Black; font.pixelSize: 22
                            color: Theme.crust; text: ls.valueText
                        }
                    }
                }

                Item {
                    id: customContent
                    anchors.fill: parent
                    anchors.margins: 12
                    z: 10
                }
            }

            // ---- rejilla líquida: CPU / RAM / TEMP + DISCO / RED ----
            ColumnLayout {
                Layout.fillWidth: true
                spacing: 10
                opacity: body.introHeader
                transform: Translate { y: 20 * (1 - body.introHeader) }

                RowLayout {
                    Layout.fillWidth: true
                    spacing: 10
                    LiquidSquare {
                        Layout.fillWidth: true; Layout.preferredHeight: 92
                        value: body.cpuVal
                        colorFill: Qt.lighter(Theme.mauve, 1.4)
                        icon: ""; title: I18n.t("CPU")
                        valueText: Math.round(body.cpuVal * 100) + "%"
                    }
                    LiquidSquare {
                        Layout.fillWidth: true; Layout.preferredHeight: 92
                        value: body.ramVal
                        colorFill: Qt.lighter(Theme.mauve, 1.2)
                        icon: ""; title: I18n.t("RAM")
                        valueText: (SystemStats.memUsedMb / 1024).toFixed(1) + "G"
                    }
                    LiquidSquare {
                        Layout.fillWidth: true; Layout.preferredHeight: 92
                        value: body.tempVal
                        colorFill: Theme.mauve
                        icon: ""; title: I18n.t("TEMP")
                        valueText: SystemStats.cpuTemp > 0 ? SystemStats.cpuTemp + "°" : "—"
                    }
                }
                RowLayout {
                    Layout.fillWidth: true
                    spacing: 10
                    LiquidSquare {
                        Layout.fillWidth: true; Layout.preferredHeight: 92
                        value: body.diskVal
                        colorFill: Qt.darker(Theme.mauve, 1.2)
                        icon: ""; title: I18n.t("DISK")
                        subText: sm.diskText
                        valueText: Math.round(body.diskVal * 100) + "%"
                    }
                    LiquidSquare {
                        Layout.fillWidth: true; Layout.preferredHeight: 92
                        value: 0.12
                        colorFill: Qt.darker(Theme.mauve, 1.4)
                        icon: "󰤨"; title: I18n.t("NETWORK")
                        ColumnLayout {
                            anchors.centerIn: parent
                            spacing: 6
                            RowLayout {
                                spacing: 10
                                Text { text: ""; font.family: Theme.fontFamily; font.pixelSize: 13; color: Theme.green }
                                Text { text: body.fmtKbs(SystemStats.netDownKbs); color: Theme.text; font.family: Theme.fontFamily; font.pixelSize: 13; font.bold: true }
                            }
                            RowLayout {
                                spacing: 10
                                Text { text: ""; font.family: Theme.fontFamily; font.pixelSize: 13; color: Theme.peach }
                                Text { text: body.fmtKbs(SystemStats.netUpKbs); color: Theme.text; font.family: Theme.fontFamily; font.pixelSize: 13; font.bold: true }
                            }
                        }
                    }
                }
            }

            Rectangle { Layout.fillWidth: true; height: 1; color: Theme.overlay0; opacity: 0.4 }

            // ---- process list header ----
            RowLayout {
                Layout.fillWidth: true
                Text { Layout.fillWidth: true; text: I18n.t("Processes"); color: Theme.subtext1; font.family: Theme.fontFamily; font.pixelSize: Theme.fontSize - 1; font.bold: true }
                Text { text: I18n.t("CPU"); color: Theme.overlay2; font.family: Theme.fontFamily; font.pixelSize: Theme.fontSize - 3; Layout.preferredWidth: 44; horizontalAlignment: Text.AlignRight }
                Text { text: I18n.t("RAM"); color: Theme.overlay2; font.family: Theme.fontFamily; font.pixelSize: Theme.fontSize - 3; Layout.preferredWidth: 44; horizontalAlignment: Text.AlignRight }
                Item { Layout.preferredWidth: 96 }
            }

            // ---- process rows (fase introContent) ----
            ColumnLayout {
                Layout.fillWidth: true; spacing: 4
                opacity: body.introContent
                transform: Translate { y: 18 * (1 - body.introContent) }
                Repeater {
                    model: sm.procs
                    delegate: Rectangle {
                        id: prow
                        required property var modelData
                        Layout.fillWidth: true; Layout.preferredHeight: 34
                        radius: Theme.radius - 2; color: prMa.containsMouse ? Theme.surface0 : "transparent"
                        MouseArea { id: prMa; anchors.fill: parent; hoverEnabled: true }
                        RowLayout {
                            anchors.fill: parent; anchors.leftMargin: 10; anchors.rightMargin: 8; spacing: 6
                            Text {
                                Layout.fillWidth: true; text: prow.modelData.name; color: Theme.text
                                font.family: Theme.fontFamily; font.pixelSize: Theme.fontSize - 2; elide: Text.ElideRight
                            }
                            Text { text: prow.modelData.cpu.toFixed(1); color: prow.modelData.cpu > 40 ? Theme.red : Theme.subtext0; font.family: Theme.fontFamily; font.pixelSize: Theme.fontSize - 3; Layout.preferredWidth: 44; horizontalAlignment: Text.AlignRight }
                            Text { text: prow.modelData.mem.toFixed(1); color: Theme.subtext0; font.family: Theme.fontFamily; font.pixelSize: Theme.fontSize - 3; Layout.preferredWidth: 44; horizontalAlignment: Text.AlignRight }
                            // actions (visible on hover)
                            Row {
                                Layout.preferredWidth: 96; spacing: 2; opacity: prMa.containsMouse ? 1 : 0.25
                                Behavior on opacity { NumberAnimation { duration: Theme.dur(120) } }
                                IconButton { icon: "#"; iconSize: Theme.fontSize - 3; implicitWidth: 28; implicitHeight: 28; onClicked: sm.copy(prow.modelData.pid) }
                                IconButton { icon: Icons.clipboard; iconSize: Theme.fontSize - 3; implicitWidth: 28; implicitHeight: 28; onClicked: sm.copyCmd(prow.modelData.pid) }
                                IconButton { icon: Icons.close; iconColor: Theme.red; iconSize: Theme.fontSize - 3; implicitWidth: 28; implicitHeight: 28; onClicked: sm.killPid(prow.modelData.pid) }
                            }
                        }
                    }
                }
            }
        }
    }
}
