import QtQuick
import QtQuick.Layouts
import QtQuick.Effects
import Quickshell
import Quickshell.Wayland
import Quickshell.Hyprland
import qs.services
import qs.components

// ============================================================================
//  Top/side bar. One per (selected) monitor. Fully data-driven: position,
//  spacing, transparency, scaling, corners, border, shadow, scroll behaviour
//  and the widget layout itself all come from shell.json 'bar', applied live
//  via Config — zero restart. Three segments (left / center / right) each host
//  a reorderable list of widgets from WidgetRegistry.
// ============================================================================
Variants {
    model: Quickshell.screens

    PanelWindow {
        id: bar
        required property var modelData
        screen: modelData

        // ---- resolved settings (all live via Config bindings) --------------
        readonly property string pos: Config.get("bar", "position", "top")
        readonly property bool horizontal: pos === "top" || pos === "bottom"
        readonly property int barSize: Config.get("bar", "barSize", Config.get("bar", "height", 38))
        readonly property int edgeGap: Config.get("bar", "edgeGap", Config.get("bar", "marginTop", 6))
        readonly property int sideMargin: Config.get("bar", "marginSides", 8)
        readonly property int pad: Config.get("bar", "padding", 8)
        readonly property string bgStyle: Config.get("bar", "backgroundStyle", "solid")
        readonly property bool showBorder: Config.get("bar", "border", false)
        readonly property string shadow: Config.get("bar", "shadow", "none")
        readonly property int cornerRadius: Config.get("bar", "cornerRadius", Theme.radius)
        readonly property bool scrollWheel: Config.get("bar", "scrollWheel", true)
        readonly property string scrollAxis: Config.get("bar", "scrollAxis", "workspace")
        // key undefined (no null): con null get() devolvía s[null] => el toggle
        // "Invertir dirección de desplazamiento" nunca surtía efecto
        readonly property bool invertScroll: (Config.get("workspaces") || {}).invertScroll === true
        readonly property bool maxDetect: Config.get("bar", "maximizeDetect", false)
        readonly property bool autoHide: Config.get("bar", "autoHide", false)
        readonly property bool wantExclusive: Config.get("bar", "exclusiveZone", true)
        readonly property var screensCfg: Config.get("bar", "screens", [])

        // only show on selected monitors (empty list = all)
        readonly property bool onThisScreen: {
            if (!bar.screensCfg || bar.screensCfg.length === 0) return true;
            return bar.screensCfg.indexOf(bar.modelData.name) !== -1;
        }

        // maximize detection (a fullscreen window flushes the bar)
        property bool maximized: false
        Connections {
            target: Hyprland
            function onRawEvent(e) {
                if (e.name === "fullscreen") bar.maximized = (e.data === "1" || e.data === 1);
            }
        }
        readonly property bool flush: bar.maxDetect && bar.maximized

        readonly property int effGap: bar.flush ? 0 : bar.edgeGap
        readonly property int effRadius: bar.flush ? 0 : bar.cornerRadius
        readonly property bool effBorder: bar.showBorder && !bar.flush

        // auto-hide reveal
        property bool revealed: false
        readonly property bool hiddenNow: bar.autoHide && !bar.revealed && !Panels.quickSettings && !Panels.launcher

        WlrLayershell.namespace: "vexyon-bar"
        WlrLayershell.layer: WlrLayer.Top
        color: "transparent"
        visible: bar.onThisScreen

        // El blur de la barra (appearance.barBlur) lo aplica el BRIDGE vía
        // decoration:blur + layerrule sobre el namespace vexyon-bar; aquí no
        // hay nada que hacer (la clave bar.bgBlur antigua estaba muerta: sin
        // UI y con la gramática de layerrule sin verificar).
        Component.onCompleted: {
            // los paneles anclados incluyen la barra en su focus grab
            Panels.registerBar(bar);
        }
        Component.onDestruction: Panels.unregisterBar(bar)

        // ---- anchoring + size per position --------------------------------
        anchors {
            top: bar.pos !== "bottom"
            bottom: bar.pos !== "top"
            left: bar.pos !== "right"
            right: bar.pos !== "left"
        }
        implicitHeight: bar.horizontal ? (bar.barSize + bar.effGap) : 0
        implicitWidth: bar.horizontal ? 0 : (bar.barSize + bar.effGap)
        exclusiveZone: (bar.autoHide || !bar.wantExclusive) ? 0 : (bar.barSize + bar.effGap)

        // ---- content -------------------------------------------------------
        Item {
            id: content
            anchors.fill: parent
            // slide off-screen when auto-hidden (leave a sliver)
            transform: Translate {
                x: bar.hiddenNow && bar.pos === "left" ? -(bar.barSize) : bar.hiddenNow && bar.pos === "right" ? bar.barSize : 0
                y: bar.hiddenNow && bar.pos === "top" ? -(bar.barSize) : bar.hiddenNow && bar.pos === "bottom" ? bar.barSize : 0
                Behavior on x { NumberAnimation { duration: Theme.dur(180); easing.type: Theme.easing } }
                Behavior on y { NumberAnimation { duration: Theme.dur(180); easing.type: Theme.easing } }
            }

            // inner margins toward the screen edge
            anchors.topMargin:    bar.pos === "top" ? bar.effGap : 0
            anchors.bottomMargin: bar.pos === "bottom" ? bar.effGap : 0
            anchors.leftMargin:   bar.pos === "left" ? bar.effGap : (bar.horizontal ? bar.sideMargin : 0)
            anchors.rightMargin:  bar.pos === "right" ? bar.effGap : (bar.horizontal ? bar.sideMargin : 0)

            // ===== background bar layer =====================================
            //  Sits behind the row of widget pills, spanning the bar's full
            //  length. Theme-token coloured; opacity is a live Barra setting
            //  (0 = pills float on nothing, 1 = solid bar matching pills).
            //  Optional blur via the vexyon-bar layerrule (appearance.barBlur,
            //  emitida por el bridge en vexyon-settings.lua).
            Rectangle {
                id: bgLayer
                anchors.fill: parent
                // DMS-style default: the bar has a visible background layer and
                // the widget pills sit on it as lighter rounded rects (0 still
                // gives floating pills for anyone who prefers the old look).
                // bar.backgroundStyle === "transparent" (Ajustes → Estilo de
                // fondo) suprime la capa por completo — antes la clave se
                // escribía pero nadie la leía (control muerto en Ajustes).
                readonly property real bgOpacity: bar.bgStyle === "transparent"
                    ? 0.0 : Config.get("bar", "bgOpacity", 1.0)
                radius: bar.effRadius
                color: Qt.rgba(Theme.base.r, Theme.base.g, Theme.base.b, bar.flush ? 1.0 : bgOpacity)
                visible: bgOpacity > 0.001 || bar.effBorder || bar.flush
                border.width: bar.effBorder ? 1 : 0
                border.color: Qt.rgba(Theme.overlay0.r, Theme.overlay0.g, Theme.overlay0.b, 0.4)
                Behavior on color { ColorAnimation { duration: Theme.dur(200) } }

                layer.enabled: bar.shadow !== "none" && Theme.elevation && bgLayer.bgOpacity > 0.05
                layer.effect: MultiEffect {
                    shadowEnabled: true
                    shadowBlur: bar.shadow === "strong" ? 1.0 : 0.5
                    shadowColor: Qt.rgba(0, 0, 0, bar.shadow === "strong" ? 0.55 : 0.3)
                    shadowVerticalOffset: 2
                }
            }

            HoverHandler { onHoveredChanged: if (bar.autoHide) bar.revealed = hovered }

            WheelHandler {
                enabled: bar.scrollWheel && bar.scrollAxis === "workspace"
                acceptedDevices: PointerDevice.Mouse | PointerDevice.TouchPad
                onWheel: function(e) {
                    var down = e.angleDelta.y < 0;
                    if (bar.invertScroll) down = !down;
                    Hyprland.dispatch(down ? "workspace e+1" : "workspace e-1");
                }
            }

            // ============ segments ============
            BarSection { win: bar; sec: "left";   groupAlign: "start" }
            BarSection { win: bar; sec: "center"; groupAlign: "center" }
            BarSection { win: bar; sec: "right";  groupAlign: "end" }
        }
    }

    // ---- one bar segment: a transparent row/column of independent widget ---
    //  pills. No group backing (the pills carry their own capsule styling and
    //  the bar's background layer sits behind them all).
    component BarSection: Item {
        id: seg
        required property var win
        required property string sec
        required property string groupAlign
        // reactive: re-reads when Config.data changes
        readonly property var items: WidgetRegistry.section(sec)

        // Un espaciador/separador dentro de la sección la parte en subgrupos
        // visuales: los paneles anclados vuelven al anclaje por-widget en vez
        // de alinearse al borde de la sección (ver Panels.openAt).
        readonly property bool hasSplit: {
            for (var i = 0; i < items.length; i++)
                if (items[i].type === "spacer" || items[i].type === "separator") return true;
            return false;
        }

        visible: items.length > 0

        // gap between adjacent pills (live setting)
        readonly property int pillGap: Config.get("bar", "pillGap", 4)

        // Position within the content item. Anchors are swapped via states +
        // AnchorChanges (NOT plain bindings to undefined): when the bar
        // position changes live, bindings re-evaluate in arbitrary order and
        // can transiently pin both axes (e.g. horizontalCenter + right),
        // leaving sections misplaced. AnchorChanges applies the swap
        // atomically.
        states: [
            State {
                name: "horizontal"
                when: seg.win.horizontal
                AnchorChanges {
                    target: seg
                    anchors.verticalCenter: seg.parent.verticalCenter
                    anchors.horizontalCenter: seg.groupAlign === "center" ? seg.parent.horizontalCenter : undefined
                    anchors.left: seg.groupAlign === "start" ? seg.parent.left : undefined
                    anchors.right: seg.groupAlign === "end" ? seg.parent.right : undefined
                    anchors.top: undefined
                    anchors.bottom: undefined
                }
            },
            State {
                name: "vertical"
                when: !seg.win.horizontal
                AnchorChanges {
                    target: seg
                    anchors.horizontalCenter: seg.parent.horizontalCenter
                    anchors.verticalCenter: seg.groupAlign === "center" ? seg.parent.verticalCenter : undefined
                    anchors.top: seg.groupAlign === "start" ? seg.parent.top : undefined
                    anchors.bottom: seg.groupAlign === "end" ? seg.parent.bottom : undefined
                    anchors.left: undefined
                    anchors.right: undefined
                }
            }
        ]
        anchors.leftMargin:  (win.horizontal && groupAlign === "start") ? win.pad : 0
        anchors.rightMargin: (win.horizontal && groupAlign === "end") ? win.pad : 0
        anchors.topMargin:    (!win.horizontal && groupAlign === "start") ? win.pad : 0
        anchors.bottomMargin: (!win.horizontal && groupAlign === "end") ? win.pad : 0

        implicitWidth: grid.implicitWidth
        implicitHeight: grid.implicitHeight

        GridLayout {
            id: grid
            anchors.centerIn: parent
            flow: win.horizontal ? GridLayout.LeftToRight : GridLayout.TopToBottom
            rows: win.horizontal ? 1 : Math.max(1, seg.items.length)
            columns: win.horizontal ? Math.max(1, seg.items.length) : 1
            rowSpacing: seg.pillGap
            columnSpacing: seg.pillGap

            Repeater {
                model: seg.items
                delegate: BarWidget {
                    required property var modelData
                    type: modelData.type
                    cfg: modelData
                    vertical: !win.horizontal
                    section: seg.sec
                    barPos: win.pos
                    screenName: win.modelData.name
                    sectionItem: seg
                    sectionAlign: seg.groupAlign
                    sectionSplit: seg.hasSplit
                    Layout.alignment: Qt.AlignVCenter | Qt.AlignHCenter
                    // hidden widgets keep their reserved slot but render blank
                    opacity: modelData.hidden === true ? 0 : 1
                    enabled: modelData.hidden !== true
                }
            }
        }
    }
}
