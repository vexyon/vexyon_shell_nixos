pragma Singleton

import QtQuick
import Quickshell
import Quickshell.Hyprland
import qs.services

// Central toggle bus for shell popups/overlays. The bar buttons and the global
// keyboard shortcuts flip these; each module binds its visibility here. Keeps
// modules decoupled — nobody reaches into anybody else.
Singleton {
    id: root

    property bool launcher: false
    property bool settings: false
    property bool wallpaper: false
    property bool powermenu: false
    property bool screenshot: false
    // anchored dropdown panels (open below their bar widget)
    property bool weatherPanel: false
    property bool quickSettings: false
    property bool notifCenter: false
    property bool sysMonitor: false
    property bool mediaPlayer: false
    property bool volumePanel: false
    property bool networkPanel: false
    property bool batteryPanel: false
    property bool calendarPanel: false
    property bool clipboardPanel: false
    property bool themeQuick: false

    // pestaña inicial que el widget pide antes de abrir (ilyamiro: toggle
    // volume / toggle network wifi|bt)
    property string volumeInitTab: "outputs"
    property string networkInitTab: "wifi"

    // ---- anchoring state (shared by every anchored dropdown panel) ---------
    //  A widget calls openAt() which records where in the bar it lives; the
    //  panel window reads these to place its card hanging off that widget,
    //  clamped to the screen edge. anchorX is the widget's centre ALONG the
    //  bar's main axis (X for top/bottom, Y for left/right); anchorEdge is the
    //  widget edge on the perpendicular axis the panel drops from.
    property real  anchorX: 0
    property real  anchorEdge: 0
    property string anchorScreen: "" // screen name the trigger lives on
    property string anchorBarPos: "top"
    property var   anchorItem: null  // widget que abrió el panel (para toggle)
    // cómo interpreta el panel anchorX sobre el eje principal de la barra:
    // "center" = anchorX es el centro del card; "start"/"end" = anchorX es el
    // borde inicial/final del card (alineado al borde de la sección).
    property string anchorAlign: "center"

    // ---- bar windows registry ----------------------------------------------
    //  Las barras se registran para que los paneles anclados las incluyan en
    //  su HyprlandFocusGrab: sin esto, el mismo click que abre el panel (el
    //  release cae en la barra, fuera del grab) lo limpia y el panel se abre
    //  y se cierra en el acto.
    property var barWindows: []
    function registerBar(w) {
        var a = root.barWindows.slice();
        if (a.indexOf(w) === -1) { a.push(w); root.barWindows = a; }
    }
    function unregisterBar(w) {
        var a = root.barWindows.slice();
        var i = a.indexOf(w);
        if (i !== -1) { a.splice(i, 1); root.barWindows = a; }
    }

    // ---- borde visual de la barra (eje transversal, coords de pantalla) ----
    //  ÚNICA fuente de verdad del borde del que cuelgan los paneles anclados.
    //  ⚠️ Regresión S25/S30: el borde se tomaba del bounding box del WIDGET
    //  (item.mapToItem), pero las pastillas miden barHeight-10 y van centradas
    //  → su borde queda ~5px DENTRO de la barra, así que el "gap" configurado
    //  quedaba comido (8 configurados = ~3 visibles) y además variaba según el
    //  alto de cada widget. toggleFallback, en cambio, ya usaba el borde de la
    //  franja → dos referencias distintas, y cada retoque de la constante
    //  rompía la otra ruta. Ahora TODAS las rutas usan esta función.
    function stripEdge(scr, bp) {
        var strip = Theme.barHeight + Theme.barMarginTop;
        if (scr && bp === "right")  return scr.width - strip;
        if (scr && bp === "bottom") return scr.height - strip;
        return strip;   // top y left
    }

    // barWindow: la PanelWindow de la barra que contiene el widget. mapToItem
    // (null) da coordenadas DE ESA VENTANA; para barras bottom/right la
    // ventana no arranca en (0,0) de la pantalla, así que se suma su offset.
    //
    // Anclaje por ZONAS (Session 26): un widget ancla su panel al borde de SU
    // sección de barra — sección izquierda → borde izquierdo de la sección,
    // centro → centrado en la sección, derecha → borde derecho — para que todos
    // los paneles de un cluster abran alineados. EXCEPCIÓN: si la sección
    // contiene un espaciador/separador (subgrupos visuales), cada widget
    // vuelve a anclar bajo sí mismo (sectionSplit true → per-widget).
    function openAt(name, item, screenName, barPos, barWindow, sectionItem, sectionAlign, sectionSplit) {
        var bp = barPos || "top";
        var offX = 0, offY = 0;
        var scr = null;
        var scs = Quickshell.screens;
        for (var i = 0; i < scs.length; i++)
            if (scs[i].name === screenName) { scr = scs[i]; break; }
        if (barWindow && scr) {
            if (bp === "right")  offX = scr.width - barWindow.width;
            if (bp === "bottom") offY = scr.height - barWindow.height;
        }
        var zone = sectionItem !== undefined && sectionItem !== null && sectionSplit !== true;
        var ref = zone ? sectionItem : item;          // de quién se toma el eje principal
        var align = zone && (sectionAlign === "start" || sectionAlign === "end")
            ? sectionAlign : "center";
        if (bp === "left" || bp === "right") {
            root.anchorX = (align === "start" ? ref.mapToItem(null, 0, 0).y
                          : align === "end"   ? ref.mapToItem(null, 0, ref.height).y
                          : ref.mapToItem(null, 0, ref.height / 2).y) + offY;
        } else {
            root.anchorX = (align === "start" ? ref.mapToItem(null, 0, 0).x
                          : align === "end"   ? ref.mapToItem(null, ref.width, 0).x
                          : ref.mapToItem(null, ref.width / 2, 0).x) + offX;
        }
        // eje transversal: SIEMPRE el borde visual de la barra, no el del widget
        root.anchorEdge = stripEdge(scr, bp);
        root.anchorScreen = screenName || "";
        root.anchorBarPos = bp;
        root.anchorAlign = align;
        root.anchorItem = item;
        root.open(name);
    }

    // ---- pantalla ENFOCADA (fuente ÚNICA para todo el shell) ----------------
    //  El monitor donde está el usuario SEGÚN EL COMPOSITOR, que no es lo mismo
    //  que el monitor bajo el PUNTERO: si se cambia de monitor por teclado
    //  (Super+N, movefocus) el ratón se queda donde estaba. Una superficie que
    //  no declara `screen` la coloca el compositor bajo el PUNTERO, así que
    //  aparece en el monitor equivocado — medido en la torre de 3 pantallas.
    //  Por eso TODA superficie del shell fija su `screen` con esto.
    //  Hyprland.focusedMonitor es una propiedad reactiva alimentada por eventos
    //  del compositor: cero sondeo.
    function focusedScreen() {
        var scs = Quickshell.screens;
        var fm = Hyprland.focusedMonitor;
        if (fm) for (var i = 0; i < scs.length; i++)
            if (scs[i].name === fm.name) return scs[i];
        return scs.length > 0 ? scs[0] : null;
    }

    // Pantalla en la que se abrió la última superficie NO anclada (launcher,
    // power menu, selector de fondos, onboarding, diálogo de monitores).
    //  ⚠️ Por qué una propiedad y no `screen: Panels.focusedScreen()` directo:
    //  un binding a una FUNCIÓN no se re-evalúa cuando cambia el foco, así que
    //  la ventana se quedaba con la pantalla que tuviera al crearse y acababa
    //  bajo el puntero (medido: seguía fallando con el binding a función). Se
    //  fija AL ABRIR, exactamente igual que anchorScreen — que es el mecanismo
    //  que ya se sabe que funciona. No es un mecanismo nuevo: misma idea, misma
    //  fuente (focusedScreen()).
    property var openScreen: null

    // Paneles anclados: los que cuelgan de una pastilla de la barra. Al abrirlos
    // SIN clic (atajo de teclado, IPC) no hay widget que aporte pantalla, así
    // que hay que anclarlos al monitor enfocado en vez de reusar el anclaje
    // viejo (que dejaba el panel en el monitor de la última vez).
    readonly property var anchoredPanels: [
        "weatherPanel", "quickSettings", "notifCenter", "sysMonitor", "mediaPlayer",
        "volumePanel", "networkPanel", "batteryPanel", "calendarPanel",
        "clipboardPanel", "themeQuick"
    ]

    // Abre/cierra un panel anclado desde un atajo de teclado (sin widget que
    // lo ancle): lo cuelga del extremo final de la barra en el monitor ENFOCADO.
    function toggleFallback(name) {
        if (root[name] === true) { root[name] = false; return; }
        var scr = root.focusedScreen();
        if (scr) {
            var bp = Config.get("bar", "position", "top");
            if (bp === "left" || bp === "right") {
                root.anchorAlign = "start";
                root.anchorX = 8;    // main axis = Y: pegado al inicio de la barra
            } else {
                root.anchorAlign = "end";
                root.anchorX = scr.width - 8;
            }
            root.anchorEdge = stripEdge(scr, bp);   // misma referencia que openAt
            root.anchorScreen = scr.name;
            root.anchorBarPos = bp;
            root.anchorItem = null;
        }
        root.open(name);
    }
    // ---- system-tray native context menu ----------------------------------
    //  Right-clicking a tray icon opens that app's OWN DBusMenu, rendered
    //  themed by TrayMenu.qml. We only carry the menu handle + where to hang
    //  the card; TrayMenu reads these like an AnchoredPanel reads anchorX/Edge.
    property bool  trayMenu: false
    property var   trayMenuHandle: null   // qs::menu::QsMenuHandle of the item
    property real  trayMenuX: 0           // main-axis: card start edge (screen coords)
    property real  trayMenuEdge: 0        // cross-axis edge to drop the card from
    property string trayMenuScreen: ""
    property string trayMenuBarPos: "top"
    function openTrayMenu(handle, item, screenName, barPos, barWindow) {
        var bp = barPos || "top";
        var offX = 0, offY = 0, scr = null;
        var scs = Quickshell.screens;
        for (var i = 0; i < scs.length; i++)
            if (scs[i].name === screenName) { scr = scs[i]; break; }
        if (barWindow && scr) {
            if (bp === "right")  offX = scr.width - barWindow.width;
            if (bp === "bottom") offY = scr.height - barWindow.height;
        }
        if (bp === "left" || bp === "right") {
            root.trayMenuX = item.mapToItem(null, 0, 0).y + offY;              // card top = icon top
        } else {
            root.trayMenuX = item.mapToItem(null, 0, 0).x + offX;              // card left = icon left
        }
        // eje transversal: borde visual de la barra (misma referencia que openAt)
        root.trayMenuEdge = stripEdge(scr, bp);
        root.trayMenuScreen = screenName || "";
        root.trayMenuBarPos = bp;
        root.trayMenuHandle = handle;
        closeAll();               // never both a panel and a tray menu open
        root.trayMenu = true;
    }
    function closeTrayMenu() { root.trayMenu = false; root.trayMenuHandle = null; }

    // File manager instances are dynamic FloatingWindows spawned by shell.qml
    // (one per Super+E); they never lived in the popup set and need no state here.

    function toggle(name) {
        // Un panel anclado abierto sin clic (IPC, atajo) no tiene widget que le
        // dé pantalla: se ancla al monitor enfocado en vez de heredar el
        // anclaje de la vez anterior.
        if (root.anchoredPanels.indexOf(name) !== -1) { root.toggleFallback(name); return; }
        var was = root[name];
        closeAll();
        if (!was) root.openScreen = root.focusedScreen();   // se abre -> fijar pantalla
        root[name] = !was;
    }
    function open(name) { closeAll(); root.openScreen = root.focusedScreen(); root[name] = true; }
    function close(name) { root[name] = false; }
    function closeAll() {
        root.launcher = false;
        // settings is a real toplevel window (FloatingWindow), NOT a modal
        // popup — like the file manager it lives OUTSIDE the mutually-exclusive
        // popup set, so opening a widget panel never dismisses it. It closes
        // only via its own X button or Win+Q. (Bug: closeAll used to zero it,
        // so any bar-widget popup killed an open settings window.)
        root.wallpaper = false;
        root.powermenu = false;
        root.weatherPanel = false;
        root.quickSettings = false;
        root.notifCenter = false;
        root.sysMonitor = false;
        root.mediaPlayer = false;
        root.volumePanel = false;
        root.networkPanel = false;
        root.batteryPanel = false;
        root.calendarPanel = false;
        root.clipboardPanel = false;
        root.themeQuick = false;
        root.trayMenu = false;
        // screenshot is modal & self-managing; not force-closed here
    }
}
