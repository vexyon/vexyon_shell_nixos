import QtQuick
import Quickshell
import qs.services
import qs.components

// ============================================================================
//  BarWidget — the pill host for one bar entry. Renders its inner content via
//  WidgetView (kept in a separate file so we never instantiate BarWidget inside
//  BarWidget — Quickshell rejects recursive component use). A "group" entry
//  ({ type:"group", children:[…] }) draws ONE pill wrapping a Row of child
//  WidgetViews, giving a combined pill without any recursion.
//
//  Font/icon scale live in WidgetView; per-widget outline and transparency are
//  applied here so the whole catalog obeys the Bar settings uniformly.
// ============================================================================
Rectangle {
    id: host

    property string type: ""
    property var cfg: ({})
    property bool vertical: false
    property string section: "left"
    property string barPos: "top"
    property string screenName: ""
    // geometría de sección para el anclaje por zonas (ver Panels.openAt)
    property Item sectionItem: null
    property string sectionAlign: "center"
    property bool sectionSplit: false

    readonly property real widgetAlpha: Config.get("bar", "widgetTransparency", 1.0)
    readonly property bool isGroup: type === "group"
    readonly property bool structural: type === "spacer" || type === "separator"
    readonly property bool outline: Config.get("bar", "widgetOutline", false) && !structural && !isGroup

    // Each non-structural entry (incl. groups) is its own rounded rect —
    // DMS BasePill anatomy: moderate corner radius (NOT a full capsule),
    // surface-token background, hover brightens the fill.
    // Orientation-aware: the pill's FIXED side is always the bar's cross axis
    // (thickness) and the content side grows along the bar's main axis, so a
    // vertical bar gets uniform-width pills stacked in a column.
    readonly property bool isPill: !structural
    // Pastilla REDONDA compacta del lanzador (paridad con el LauncherButton de
    // DMS: contenido cuadrado solo-icono → la pastilla mide grosor × grosor y
    // el radio la cierra en círculo). Solo el applauncher SUELTO; dentro de un
    // grupo la pastilla del grupo manda.
    readonly property bool roundPill: isPill && type === "applauncher"
    readonly property int  pad: isPill ? 12 : 0
    readonly property int  pillThick: Theme.barHeight - 10
    readonly property bool hovered: hover.hovered

    // Hide the whole pill when the inner content hides itself. Reads the
    // WidgetView's `selfHide` (own property) — NOT `visible`, whose READ value
    // is the effective visibility (includes ancestors): with the pill hidden
    // on the first frame, parent and child would lock each other invisible.
    visible: !(content.item && content.item.selfHide === true)

    implicitWidth: roundPill ? pillThick
        : vertical
        ? (isPill ? pillThick : (content.item ? content.item.implicitWidth : 4))
        : (content.item ? content.item.implicitWidth : 20) + pad * 2
    implicitHeight: roundPill ? pillThick
        : vertical
        ? (content.item ? content.item.implicitHeight : 20) + pad * 2
        : (isPill ? pillThick : (content.item ? content.item.implicitHeight : 4))
    radius: roundPill ? pillThick / 2
        : isPill ? Math.min(Theme.radius, Math.min(implicitWidth, implicitHeight) / 2) : 0
    color: {
        if (!isPill) return "transparent";
        var c = hovered ? Theme.surface2 : Theme.surface1;
        return Qt.rgba(c.r, c.g, c.b, (hovered ? Math.max(0.5, 0.72 * widgetAlpha) : 0.72 * widgetAlpha));
    }
    border.width: (isPill && outline) ? 1 : 0
    border.color: Qt.rgba(Theme.overlay0.r, Theme.overlay0.g, Theme.overlay0.b, 0.5)
    Behavior on color { ColorAnimation { duration: Theme.dur(160) } }

    // "se aprieta la pastilla entera": al pulsar el fondo clicable del widget
    // suelto, TODA la pastilla se encoge un poco (en grupos el feedback lo
    // pinta cada zona dentro de WidgetView).
    readonly property bool contentPressed: !isGroup && content.item && content.item.pillPressed === true
    scale: contentPressed ? 0.96 : 1.0
    Behavior on scale { NumberAnimation { duration: Theme.dur(90); easing.type: Theme.easing } }

    HoverHandler { id: hover; enabled: host.isPill }

    Loader {
        id: content
        // Un widget suelto LLENA la pastilla (todo el área es clicable vía el
        // fondo de WidgetView); un grupo se centra a su tamaño implícito y son
        // sus hijos los que llenan el eje transversal (una zona por sub-widget).
        anchors.fill: host.isGroup ? undefined : parent
        anchors.centerIn: host.isGroup ? parent : undefined
        sourceComponent: host.isGroup ? cGroup : cSingle
    }

    // ---- single widget ----
    Component {
        id: cSingle
        WidgetView {
            type: host.type
            cfg: host.cfg
            vertical: host.vertical
            section: host.section
            barPos: host.barPos
            screenName: host.screenName
            sectionItem: host.sectionItem
            sectionAlign: host.sectionAlign
            sectionSplit: host.sectionSplit
        }
    }

    // ---- group: child WidgetViews inside this one pill, flowing along the
    //      bar's main axis (Row on a horizontal bar, column on a vertical one)
    Component {
        id: cGroup
        Grid {
            readonly property int gGap: host.cfg && host.cfg.groupGap !== undefined ? host.cfg.groupGap : 8
            columns: host.vertical ? 1 : 99
            columnSpacing: gGap
            rowSpacing: gGap
            horizontalItemAlignment: Grid.AlignHCenter
            verticalItemAlignment: Grid.AlignVCenter
            Repeater {
                model: host.cfg && host.cfg.children ? host.cfg.children : []
                delegate: WidgetView {
                    required property var modelData
                    type: modelData.type
                    cfg: modelData
                    vertical: host.vertical
                    section: host.section
                    barPos: host.barPos
                    screenName: host.screenName
                    sectionItem: host.sectionItem
                    sectionAlign: host.sectionAlign
                    sectionSplit: host.sectionSplit
                    inGroup: true
                    // Cada sub-widget llena el eje transversal de la pastilla del
                    // grupo, así su zona clicable es toda su columna/fila (no solo
                    // el icono) y las zonas quedan divididas por widget.
                    width: host.vertical ? host.pillThick : implicitWidth
                    height: host.vertical ? implicitHeight : host.pillThick
                }
            }
        }
    }
}
