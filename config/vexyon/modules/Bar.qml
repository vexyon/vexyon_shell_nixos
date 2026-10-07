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
        // ---- form keys of the bar styles (services/BarStyles.qml). Defaults
        //      = the original look; nothing below runs unless a style sets them.
        // islas: el fondo se pinta por SECCIÓN (detrás de cada BarSection) en
        // vez de a lo largo de toda la barra
        readonly property bool islands: Config.get("bar", "islands", false)
        // borde en el rol de acento del tema (2px) en vez del sutil overlay0
        readonly property bool accentBorder: Config.get("bar", "borderColor", "subtle") === "accent"
        // esquinas cóncavas que funden una barra a ras con el borde de la
        // pantalla. Solo tienen sentido pegadas al borde: sin hueco ni margen
        // lateral; si el usuario los cambia, desaparecen solas.
        readonly property int fillet: (Config.get("bar", "edgeFillets", false) && bar.edgeGap === 0
                                       && (!bar.horizontal || bar.sideMargin === 0)) ? Theme.radius : 0

        // only show on selected monitors (empty list = all)
        readonly property bool onThisScreen: {
            if (!bar.screensCfg || bar.screensCfg.length === 0) return true;
            return bar.screensCfg.indexOf(bar.modelData.name) !== -1;
        }

        // maximize detection (a fullscreen window flushes the bar)
        property bool maximized: false
        // special workspace (scratchpad, Super+S) abierto en ESTE monitor.
        // Evento `activespecial>>NOMBRE,MONITOR` al abrir, `>>,MONITOR` al cerrar.
        property bool specialOpen: false
        Connections {
            target: Hyprland
            function onRawEvent(e) {
                if (e.name === "fullscreen") bar.maximized = (e.data === "1" || e.data === 1);
                else if (e.name === "activespecial") {
                    var d = String(e.data);
                    var c = d.lastIndexOf(",");
                    if (d.substring(c + 1) === bar.modelData.name) bar.specialOpen = c > 0;
                }
            }
        }
        readonly property bool flush: bar.maxDetect && bar.maximized

        // Scratchpad sobre una ventana en pantalla completa: Hyprland vuelve a
        // PINTAR la capa Top pero no le da el puntero. Su mouseMoveUnified
        // descarta una superficie Top bajo el cursor si el monitor tiene
        // fullscreen exclusivo y la capa no lleva LAYER_FLAG_ABOVE_FULLSCREEN, y
        // CMonitor::setSpecialWorkspace BORRA ese flag en todas las capas del
        // monitor al abrir el special — barra visible pero muerta. Overlay
        // siempre recibe input y set_layer a Overlay pone el flag. Solo mientras
        // dure esa combinación; al cerrar el special vuelve a Top y el
        // fullscreen la tapa como siempre. Todo por eventos, sin sondeo.
        readonly property bool overFullscreen: {
            var m = Hyprland.monitorFor(bar.modelData);
            return bar.specialOpen && !!(m && m.activeWorkspace && m.activeWorkspace.hasFullscreen);
        }

        readonly property int effGap: bar.flush ? 0 : bar.edgeGap
        readonly property int effRadius: bar.flush ? 0 : bar.cornerRadius
        readonly property bool effBorder: bar.showBorder && !bar.flush
        readonly property int borderW: bar.effBorder ? (bar.accentBorder ? 2 : 1) : 0
        readonly property color borderC: bar.accentBorder ? Theme.accent
            : Qt.rgba(Theme.overlay0.r, Theme.overlay0.g, Theme.overlay0.b, 0.4)
        // DMS-style default: the bar has a visible background layer and the
        // widget pills sit on it as lighter rounded rects (0 still gives
        // floating pills for anyone who prefers the old look).
        // bar.backgroundStyle === "transparent" (Ajustes → Estilo de fondo)
        // suprime la capa por completo — antes la clave se escribía pero nadie
        // la leía (control muerto en Ajustes).
        readonly property real bgAlpha: bar.bgStyle === "transparent" ? 0.0 : Config.get("bar", "bgOpacity", 1.0)

        // auto-hide reveal
        property bool revealed: false
        readonly property bool hiddenNow: bar.autoHide && !bar.revealed && !Panels.quickSettings && !Panels.launcher
        // cuánto se desliza al ocultarse: la franja entera menos la rendija que
        // queda para volver a sacarla con el ratón. La rendija era solo el hueco
        // al borde (edgeGap); una barra a ras (edgeGap 0, p.ej. el estilo Rail)
        // se quedaba sin nada que señalar y no volvía a salir: mínimo 2 px.
        readonly property int hideBy: bar.barSize - Math.max(0, 2 - bar.effGap)

        WlrLayershell.namespace: "vexyon-bar"
        WlrLayershell.layer: bar.overFullscreen ? WlrLayer.Overlay : WlrLayer.Top
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
        // las esquinas cóncavas cuelgan FUERA de la franja: la ventana crece
        // `fillet` px hacia dentro, la zona exclusiva NO (las ventanas siguen
        // pegando a la franja) y la máscara deja pasar el input de esa tira.
        implicitHeight: bar.horizontal ? (bar.barSize + bar.effGap + bar.fillet) : 0
        implicitWidth: bar.horizontal ? 0 : (bar.barSize + bar.effGap + bar.fillet)
        exclusiveZone: (bar.autoHide || !bar.wantExclusive) ? 0 : (bar.barSize + bar.effGap)
        mask: bar.fillet > 0 ? stripMask : null
        Region {
            id: stripMask
            x: bar.pos === "right" ? bar.fillet : 0
            y: bar.pos === "bottom" ? bar.fillet : 0
            width: bar.horizontal ? bar.width : bar.barSize + bar.effGap
            height: bar.horizontal ? bar.barSize + bar.effGap : bar.height
        }

        // ---- content -------------------------------------------------------
        Item {
            id: content
            anchors.fill: parent
            // slide off-screen when auto-hidden (leave a sliver)
            transform: Translate {
                x: bar.hiddenNow && bar.pos === "left" ? -bar.hideBy : bar.hiddenNow && bar.pos === "right" ? bar.hideBy : 0
                y: bar.hiddenNow && bar.pos === "top" ? -bar.hideBy : bar.hiddenNow && bar.pos === "bottom" ? bar.hideBy : 0
                Behavior on x { NumberAnimation { duration: Theme.dur(180); easing.type: Theme.easing } }
                Behavior on y { NumberAnimation { duration: Theme.dur(180); easing.type: Theme.easing } }
            }

            // inner margins toward the screen edge
            anchors.topMargin:    bar.pos === "top" ? bar.effGap : bar.pos === "bottom" ? bar.fillet : 0
            anchors.bottomMargin: bar.pos === "bottom" ? bar.effGap : bar.pos === "top" ? bar.fillet : 0
            anchors.leftMargin:   bar.pos === "left" ? bar.effGap : bar.pos === "right" ? bar.fillet
                                : (bar.horizontal ? bar.sideMargin : 0)
            anchors.rightMargin:  bar.pos === "right" ? bar.effGap : bar.pos === "left" ? bar.fillet
                                : (bar.horizontal ? bar.sideMargin : 0)

            // ===== background bar layer =====================================
            //  Sits behind the row of widget pills, spanning the bar's full
            //  length. Theme-token coloured; opacity is a live Barra setting
            //  (0 = pills float on nothing, 1 = solid bar matching pills).
            //  Optional blur via the vexyon-bar layerrule (appearance.barBlur,
            //  emitida por el bridge en vexyon-settings.lua).
            Rectangle {
                id: bgLayer
                anchors.fill: parent
                radius: bar.effRadius
                color: Qt.rgba(Theme.base.r, Theme.base.g, Theme.base.b, bar.flush ? 1.0 : bar.bgAlpha)
                // con islas el fondo lo pintan las secciones (salvo a ras por
                // pantalla completa, que vuelve a la franja sólida)
                visible: (!bar.islands && (bar.bgAlpha > 0.001 || bar.effBorder)) || bar.flush
                border.width: bar.borderW
                border.color: bar.borderC
                Behavior on color { ColorAnimation { duration: Theme.dur(200) } }

                layer.enabled: bar.shadow !== "none" && Theme.elevation && bar.bgAlpha > 0.05
                layer.effect: MultiEffect {
                    shadowEnabled: true
                    shadowBlur: bar.shadow === "strong" ? 1.0 : 0.5
                    shadowColor: Qt.rgba(0, 0, 0, bar.shadow === "strong" ? 0.55 : 0.3)
                    shadowVerticalOffset: 2
                }
            }

            // esquinas cóncavas en los dos extremos del lado interior de la
            // franja (hijas de `content`, así se ocultan/deslizan con ella).
            // Loader inactivo = ni se crean si el estilo no las usa.
            Loader {
                anchors.fill: parent
                active: bar.fillet > 0
                visible: !bar.flush && !bar.hiddenNow
                sourceComponent: Item {
                    ConcaveCorner {
                        size: bar.fillet
                        color: bgLayer.color
                        x: bar.pos === "left" ? parent.width : bar.pos === "right" ? -size : 0
                        y: bar.pos === "top" ? parent.height : bar.pos === "bottom" ? -size : 0
                        rotation: bar.pos === "bottom" ? 270 : bar.pos === "right" ? 90 : 0
                    }
                    ConcaveCorner {
                        size: bar.fillet
                        color: bgLayer.color
                        x: bar.pos === "left" ? parent.width : bar.pos === "right" ? -size : parent.width - size
                        y: bar.pos === "top" ? parent.height : bar.pos === "bottom" ? -size : parent.height - size
                        rotation: bar.pos === "top" ? 90 : bar.pos === "left" ? 270 : 180
                    }
                }
            }

            HoverHandler { onHoveredChanged: if (bar.autoHide) bar.revealed = hovered }

            WheelHandler {
                enabled: bar.scrollWheel && bar.scrollAxis === "workspace"
                acceptedDevices: PointerDevice.Mouse | PointerDevice.TouchPad
                onWheel: function(e) {
                    var down = e.angleDelta.y < 0;
                    if (bar.invertScroll) down = !down;
                    // Forma Lua: la cadena hyprlang "workspace e+1" muere en el
                    // root Lua con `')' expected near 'e'` (silenciosa desde el
                    // shell). Hyprland.dispatch(s) manda `dispatch <s>`, que el
                    // compositor evalúa como `return hl.dispatch(<s>)`.
                    Hyprland.dispatch(down ? 'hl.dsp.focus({ workspace = "e+1" })'
                                          : 'hl.dsp.focus({ workspace = "e-1" })');
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
    //  the bar's background layer sits behind them all) — except with
    //  bar.islands, where the section draws the bar background itself.
    component BarSection: Item {
        id: seg
        required property var win
        required property string sec
        required property string groupAlign
        // reactive: re-reads when Config.data changes
        readonly property var items: WidgetRegistry.barSection(sec)

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
        // bar.separators: línea fina entre widgets contiguos. Va ANTES de cada
        // widget que tenga otro widget visible antes en la sección — los que se
        // auto-ocultan (bandeja vacía, media sin reproductor) se saltan, y junto
        // a un espaciador/separador del usuario no se pinta.
        readonly property bool separators: Config.get("bar", "separators", false)
        function prevShown(i) {
            for (var j = i - 1; j >= 0; j--) {
                var it = rep.itemAt(j) as BarWidget;
                if (it && it.shown) return !it.structural;
            }
            return false;
        }

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

        // isla (bar.islands): el fondo de la barra recortado a esta sección —
        // todo el grosor de la franja, `pad` más allá de los widgets en el eje
        // principal. Esquinas "hoja": la sección inicial redondea dos esquinas
        // opuestas, la final las otras dos (espejo), la central las cuatro.
        // Loader inactivo = sin islas no se crea nada.
        Loader {
            active: seg.win.islands
            visible: !seg.win.flush && (seg.win.bgAlpha > 0.001 || seg.win.effBorder)
                     && (seg.win.horizontal ? grid.implicitWidth : grid.implicitHeight) > 0
            x: seg.win.horizontal ? -seg.win.pad : (seg.width - width) / 2
            y: seg.win.horizontal ? (seg.height - height) / 2 : -seg.win.pad
            width: seg.win.horizontal ? seg.width + 2 * seg.win.pad : seg.parent.width
            height: seg.win.horizontal ? seg.parent.height : seg.height + 2 * seg.win.pad
            sourceComponent: Rectangle {
                readonly property int big: Math.min(seg.win.cornerRadius, Math.round(seg.win.barSize / 2))
                readonly property int small: Math.round(big / 4)
                topLeftRadius: seg.groupAlign === "end" ? small : big
                bottomRightRadius: seg.groupAlign === "end" ? small : big
                topRightRadius: seg.groupAlign === "start" ? small : big
                bottomLeftRadius: seg.groupAlign === "start" ? small : big
                color: Qt.rgba(Theme.base.r, Theme.base.g, Theme.base.b, seg.win.bgAlpha)
                border.width: seg.win.borderW
                border.color: seg.win.borderC
                Behavior on color { ColorAnimation { duration: Theme.dur(200) } }

                layer.enabled: seg.win.shadow !== "none" && Theme.elevation && seg.win.bgAlpha > 0.05
                layer.effect: MultiEffect {
                    shadowEnabled: true
                    shadowBlur: seg.win.shadow === "strong" ? 1.0 : 0.5
                    shadowColor: Qt.rgba(0, 0, 0, seg.win.shadow === "strong" ? 0.55 : 0.3)
                    shadowVerticalOffset: 2
                }
            }
        }

        GridLayout {
            id: grid
            anchors.centerIn: parent
            flow: win.horizontal ? GridLayout.LeftToRight : GridLayout.TopToBottom
            rows: win.horizontal ? 1 : Math.max(1, seg.items.length)
            columns: win.horizontal ? Math.max(1, seg.items.length) : 1
            rowSpacing: seg.pillGap
            columnSpacing: seg.pillGap

            Repeater {
                id: rep
                model: seg.items
                delegate: BarWidget {
                    id: bw
                    required property var modelData
                    required property int index
                    type: modelData.type
                    cfg: modelData
                    vertical: !win.horizontal
                    section: seg.sec
                    barPos: win.pos
                    screenName: win.modelData.name
                    sectionItem: seg
                    sectionAlign: seg.groupAlign
                    sectionSplit: seg.hasSplit
                    sepBefore: seg.separators && !bw.structural && seg.prevShown(bw.index)
                    sepGap: seg.pillGap
                    Layout.alignment: Qt.AlignVCenter | Qt.AlignHCenter
                    // hidden widgets keep their reserved slot but render blank
                    opacity: modelData.hidden === true ? 0 : 1
                    enabled: modelData.hidden !== true
                }
            }
        }
    }
}
