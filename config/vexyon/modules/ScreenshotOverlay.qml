import QtQuick
import Quickshell
import Quickshell.Io
import Quickshell.Wayland
import Quickshell.Hyprland
import qs.services

// ============================================================================
//  ScreenshotOverlay — the Vexyon interactive snipping tool. A themed
//  full-screen layer over the focused monitor: drag a box (or reuse the last
//  one), Space to capture, Esc to cancel. Everything outside the selection is
//  dimmed; the selection carries an accent border, corner handles and a live
//  size readout — consistent with the rest of the shell, not a bare crosshair.
//
//  The actual grab/save/copy/notify is delegated to `vexyon-screenshot grab`
//  (single source of truth for the file logic); we only unmap ourselves first
//  so grim never captures the overlay, and pass it the chosen geometry in grim
//  global coordinates (local + focused-monitor offset). The bash side persists
//  the box to ~/.cache/vexyon/last-crop, which we read back on open so repeated
//  shots default to the same region until the user drags a new one.
// ============================================================================
PanelWindow {
    id: win

    readonly property bool shown: Panels.screenshot === true
    function cancel() { Panels.close("screenshot"); }

    // focused Hyprland monitor drives which screen we cover + the global offset
    readonly property var mon: Hyprland.focusedMonitor
    readonly property int offX: mon ? mon.x : 0
    readonly property int offY: mon ? mon.y : 0
    screen: {
        var scs = Quickshell.screens;
        if (mon) for (var i = 0; i < scs.length; i++) if (scs[i].name === mon.name) return scs[i];
        return scs.length > 0 ? scs[0] : null;
    }

    visible: win.shown
    WlrLayershell.namespace: "vexyon-screenshot"
    WlrLayershell.layer: WlrLayer.Overlay
    WlrLayershell.exclusiveZone: -1
    WlrLayershell.keyboardFocus: win.shown ? WlrKeyboardFocus.Exclusive : WlrKeyboardFocus.None
    color: "transparent"
    anchors { top: true; bottom: true; left: true; right: true }

    // ---- selection state (screen-local px) ---------------------------------
    property real selX: 0
    property real selY: 0
    property real selW: 0
    property real selH: 0
    property bool hasSel: false
    readonly property bool validSel: hasSel && selW >= 5 && selH >= 5

    // drag bookkeeping
    property bool dragging: false
    property bool moving: false
    property real anchorX: 0
    property real anchorY: 0
    property real grabDX: 0
    property real grabDY: 0

    // Clampa contra las dimensiones de PANTALLA, no de la ventana: al abrir,
    // el last-crop puede llegar (cat async) ANTES del layout del PanelWindow
    // (win.width/height aún 500x500 implícitos) y clampar contra eso movía y
    // recortaba la caja restaurada. El overlay siempre cubre la pantalla
    // entera, así que la pantalla es la referencia correcta en todo momento.
    function clampSel() {
        var w = win.screen ? win.screen.width  : win.width;
        var h = win.screen ? win.screen.height : win.height;
        selW = Math.min(selW, w);
        selH = Math.min(selH, h);
        selX = Math.max(0, Math.min(w - selW, selX));
        selY = Math.max(0, Math.min(h - selH, selY));
    }

    // Read the last crop back so the overlay opens pre-selected on that box.
    // The file holds a grim geom "X,Y WxH" in GLOBAL coords; subtract the
    // current monitor offset to get screen-local px. A Process is used (not a
    // FileView) so the read is reliable on demand — FileView.text() right after
    // an async reload() returns stale/empty.
    Process {
        id: lastCropProc
        command: ["cat", Quickshell.env("HOME") + "/.cache/vexyon/last-crop"]
        stdout: StdioCollector {
            onStreamFinished: {
                var m = this.text.trim().match(/^(-?\d+),(-?\d+)\s+(\d+)x(\d+)$/);
                if (m) {
                    win.selX = parseInt(m[1]) - win.offX;
                    win.selY = parseInt(m[2]) - win.offY;
                    win.selW = parseInt(m[3]);
                    win.selH = parseInt(m[4]);
                    win.hasSel = true;
                    win.clampSel();
                } else {
                    win.hasSel = false;
                    win.selX = win.selY = win.selW = win.selH = 0;
                }
            }
        }
    }

    onShownChanged: {
        if (shown) {
            win.dragging = false; win.moving = false;
            win.hasSel = false;
            win.selX = win.selY = win.selW = win.selH = 0;
            lastCropProc.running = true;   // async; pre-selects the last box if any
            keyItem.forceActiveFocus();
        }
    }

    function capture() {
        if (!win.validSel) return;
        var gx = Math.round(win.selX + win.offX);
        var gy = Math.round(win.selY + win.offY);
        var gw = Math.round(win.selW);
        var gh = Math.round(win.selH);
        var geom = gx + "," + gy + " " + gw + "x" + gh;
        Panels.close("screenshot");          // unmap first so grim skips us
        // El PATH de qs puede no llevar ~/.local/bin (p.ej. lanzado por
        // Hyprland con PATH pelado): resolver el script con fallbacks en vez
        // de fallar en silencio tras habernos desmapeado. geom = solo
        // "X,Y WxH" (dígitos/coma/espacio/x), seguro entre comillas simples.
        var home = Quickshell.env("HOME");
        Quickshell.execDetached(["bash", "-c",
            "s=$(command -v vexyon-screenshot) || s=" + home + "/.local/bin/vexyon-screenshot; " +
            "[ -x \"$s\" ] || s=" + home + "/.config/vexyon/bin/vexyon-screenshot; " +
            "exec \"$s\" grab '" + geom + "'"]);
    }

    // ---- dim everything except the selection (four side rectangles) --------
    readonly property color dimColor: Qt.rgba(0, 0, 0, 0.55)
    Rectangle {   // full dim when there is no selection yet
        anchors.fill: parent
        color: win.dimColor
        visible: !win.hasSel
    }
    Item {
        anchors.fill: parent
        visible: win.hasSel
        Rectangle { color: win.dimColor; x: 0; y: 0; width: parent.width; height: Math.max(0, win.selY) }
        Rectangle { color: win.dimColor; x: 0; y: win.selY + win.selH
                    width: parent.width; height: Math.max(0, parent.height - (win.selY + win.selH)) }
        Rectangle { color: win.dimColor; x: 0; y: win.selY; width: Math.max(0, win.selX); height: win.selH }
        Rectangle { color: win.dimColor; x: win.selX + win.selW; y: win.selY
                    width: Math.max(0, parent.width - (win.selX + win.selW)); height: win.selH }
    }

    // ---- selection frame + handles + size readout --------------------------
    Item {
        id: frame
        visible: win.hasSel
        x: win.selX; y: win.selY; width: win.selW; height: win.selH

        Rectangle {
            anchors.fill: parent
            color: "transparent"
            border.width: 2
            border.color: Theme.accent
            radius: 2
        }
        // faint accent wash so the live region reads as "picked"
        Rectangle { anchors.fill: parent; color: Theme.accent; opacity: 0.06 }

        // corner handles
        Repeater {
            model: [ { hx: 0, hy: 0 }, { hx: 1, hy: 0 }, { hx: 0, hy: 1 }, { hx: 1, hy: 1 } ]
            delegate: Rectangle {
                required property var modelData
                width: 10; height: 10; radius: 3
                color: Theme.accent
                border.width: 2; border.color: Theme.onAccent
                x: modelData.hx * (frame.width - width)
                y: modelData.hy * (frame.height - height)
            }
        }

        // live size readout pill, hugging the selection's top-left just outside
        Rectangle {
            id: sizeTag
            visible: win.selW >= 5 && win.selH >= 5
            radius: Theme.radius
            color: Theme.base
            border.width: 1; border.color: Theme.surface0
            width: sizeText.implicitWidth + 16
            height: sizeText.implicitHeight + 10
            y: frame.y > height + 6 ? -height - 6 : 6
            x: 0
            Text {
                id: sizeText
                anchors.centerIn: parent
                text: Math.round(win.selW) + " × " + Math.round(win.selH)
                color: Theme.text
                font.family: Theme.fontFamily
                font.pixelSize: Theme.fontSize - 1
                font.bold: true
            }
        }
    }

    // ---- drag/move input ---------------------------------------------------
    MouseArea {
        id: ma
        anchors.fill: parent
        cursorShape: Qt.CrossCursor
        acceptedButtons: Qt.LeftButton | Qt.RightButton
        hoverEnabled: false
        onPressed: function(mouse) {
            keyItem.forceActiveFocus();
            if (mouse.button === Qt.RightButton) { win.cancel(); return; }
            var inside = win.hasSel && mouse.x >= win.selX && mouse.x <= win.selX + win.selW
                                    && mouse.y >= win.selY && mouse.y <= win.selY + win.selH;
            if (inside) {
                win.moving = true;
                win.grabDX = mouse.x - win.selX;
                win.grabDY = mouse.y - win.selY;
            } else {
                win.dragging = true;
                win.anchorX = mouse.x;
                win.anchorY = mouse.y;
                win.selX = mouse.x; win.selY = mouse.y; win.selW = 0; win.selH = 0;
                win.hasSel = true;
            }
        }
        onPositionChanged: function(mouse) { win.feedPoint(mouse.x, mouse.y); }
        onReleased: function(mouse) {
            if (win.dragging && (win.selW < 5 || win.selH < 5)) win.hasSel = false;
            win.dragging = false;
            win.moving = false;
        }
    }

    // Un único camino para actualizar la selección durante el gesto: lo
    // alimentan tanto los eventos de motion reales como el poll de abajo.
    function feedPoint(lx, ly) {
        if (win.dragging) {
            win.selX = Math.min(win.anchorX, lx);
            win.selY = Math.min(win.anchorY, ly);
            win.selW = Math.abs(lx - win.anchorX);
            win.selH = Math.abs(ly - win.anchorY);
        } else if (win.moving) {
            win.selX = Math.max(0, Math.min(win.width - win.selW, lx - win.grabDX));
            win.selY = Math.max(0, Math.min(win.height - win.selH, ly - win.grabDY));
        }
    }

    // Poll del cursor global mientras hay gesto con el botón pulsado. Mismo
    // quirk que el marquee del FileManager (S39): con puntero ABSOLUTO
    // (tablet SPICE/QEMU) Hyprland no entrega motion al cliente durante el
    // grab implícito — sin el poll, el rectángulo solo se materializa al
    // soltar. cursorpos da coords GLOBALES; se restan las del monitor.
    Process {
        id: curPoll
        command: ["hyprctl", "cursorpos", "-j"]
        stdout: StdioCollector {
            onStreamFinished: {
                try {
                    var p = JSON.parse(this.text);
                    win.feedPoint(p.x - win.offX, p.y - win.offY);
                } catch (e) {}
            }
        }
    }
    Timer {
        interval: 40; repeat: true
        running: win.shown && (win.dragging || win.moving)
        onTriggered: if (!curPoll.running) curPoll.running = true
    }

    // ---- hint bar ----------------------------------------------------------
    Rectangle {
        anchors.horizontalCenter: parent.horizontalCenter
        anchors.bottom: parent.bottom
        anchors.bottomMargin: 48
        radius: Theme.radius + 6
        color: Theme.base
        border.width: 1; border.color: Theme.surface0
        width: hintRow.implicitWidth + 40
        height: hintRow.implicitHeight + 22
        opacity: 0.96

        Row {
            id: hintRow
            anchors.centerIn: parent
            spacing: 16
            Text {
                anchors.verticalCenter: parent.verticalCenter
                text: Icons.crop + I18n.t("  Drag to select")
                color: Theme.subtext0; font.family: Theme.fontFamily; font.pixelSize: Theme.fontSize - 1
            }
            Rectangle { width: 1; height: hintRow.height * 0.6; color: Theme.overlay0; anchors.verticalCenter: parent.verticalCenter }
            Text {
                anchors.verticalCenter: parent.verticalCenter
                text: I18n.t("Space to capture")
                color: win.validSel ? Theme.accent : Theme.overlay2
                font.family: Theme.fontFamily; font.pixelSize: Theme.fontSize - 1; font.bold: true
            }
            Rectangle { width: 1; height: hintRow.height * 0.6; color: Theme.overlay0; anchors.verticalCenter: parent.verticalCenter }
            Text {
                anchors.verticalCenter: parent.verticalCenter
                text: I18n.t("Esc to cancel")
                color: Theme.subtext0; font.family: Theme.fontFamily; font.pixelSize: Theme.fontSize - 1
            }
        }
    }

    // ---- keyboard ----------------------------------------------------------
    Item {
        id: keyItem
        anchors.fill: parent
        focus: win.shown
        Keys.onPressed: function(event) {
            if (event.key === Qt.Key_Escape) { win.cancel(); event.accepted = true; }
            else if (event.key === Qt.Key_Space || event.key === Qt.Key_Return || event.key === Qt.Key_Enter) {
                win.capture(); event.accepted = true;
            }
        }
    }
}
