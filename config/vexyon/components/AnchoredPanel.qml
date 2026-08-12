import QtQuick
import QtQuick.Effects
import Quickshell
import Quickshell.Wayland
import Quickshell.Hyprland
import qs.services

// ============================================================================
//  AnchoredPanel — reusable dropdown surface that opens directly below (or
//  above, on a bottom bar) the bar widget that triggered it. The widget records
//  where it lives via Panels.openAt(); this window reads Panels.anchorX /
//  anchorEdge / anchorScreen / anchorBarPos and places its card there, clamped
//  to the screen edges. One instance per panel type; `panelKey` binds it to the
//  matching Panels flag and drives dismissal.
//
//  Visual language = ilyamiro popouts (see PROJECT_STATE.md Session 12):
//  radius-20 card on `base` with a 1px surface0 border, two giant low-opacity
//  accent blobs slowly orbiting behind the content, and a STAGED intro
//  (introMain scale/slide/fade → introHeader OutBack → introContent OutExpo).
//  Content components can opt in by declaring:
//    property real introHeader: 1    // animate their header block
//    property real introContent: 1   // animate the rest
//    property color panelAccent      // drive the blob/accent colour (e.g. tabs)
//  Anchoring stays ours (Session 10) — ilyamiro pins popups to fixed slots;
//  opening under the clicked widget is better UX, we keep only their style.
//
//  Usage:
//    AnchoredPanel {
//        panelKey: "weatherPanel"; ns: "vexyon-weather"; panelWidth: 720
//        accentColor: Theme.blue
//        content: Component { Column { ... } }   // defines implicitHeight
//    }
// ============================================================================
PanelWindow {
    id: win

    property string panelKey: ""
    property string ns: "vexyon-panel"
    property real panelWidth: 400
    property color accentColor: Theme.accent
    property alias content: loader.sourceComponent
    // extra breathing room inside the card around the content
    property int contentMargin: 18
    // Hueco visible entre el borde de la barra y el card — ÚNICA fuente de
    // verdad para todos los paneles anclados (no duplicar ni "ajustar" por
    // panel). Regla EXACTA de DankMaterialShell (SettingsData.
    // getPopupTriggerPosition: popupGap = max(4, barSpacing) con popupGapsAuto,
    // el default): nuestro equivalente de barSpacing es bar.edgeGap
    // (Theme.barMarginTop). Se mide desde el BORDE VISUAL de la barra —
    // Panels.anchorEdge ya es ese borde (Panels.stripEdge), no el del widget.
    readonly property real gap: Math.max(4, Theme.barMarginTop)

    readonly property bool shown: panelKey !== "" && Panels[panelKey] === true
    function close() { if (panelKey !== "") Panels.close(panelKey); }

    // resolve the screen the trigger widget lives on (fall back to primary)
    screen: {
        var scs = Quickshell.screens;
        for (var i = 0; i < scs.length; i++)
            if (scs[i].name === Panels.anchorScreen) return scs[i];
        return scs.length > 0 ? scs[0] : null;
    }

    visible: win.shown
    WlrLayershell.namespace: win.ns
    WlrLayershell.layer: WlrLayer.Overlay
    // Sin esto, la exclusive zone de la barra empuja TODA la ventana del panel
    // barStrip px hacia abajo: el card, ya colocado a anchorEdge+gap en coords
    // de ventana, aterrizaba ~44px más abajo en pantalla (el "panel abre
    // demasiado lejos de la barra"). -1 = la capa ignora zonas exclusivas
    // ajenas y ocupa la pantalla completa (bajo la barra), como los popouts DMS.
    WlrLayershell.exclusiveZone: -1
    WlrLayershell.keyboardFocus: win.shown ? WlrKeyboardFocus.OnDemand : WlrKeyboardFocus.None
    color: "transparent"
    anchors { top: true; bottom: true; left: true; right: true }

    // ---- input passthrough over the bar ------------------------------------
    //  The panel window spans the whole screen (dim backdrop), which used to
    //  swallow clicks aimed at the bar: clicking any pill while a panel was
    //  open only dismissed the backdrop and the pill never got the click
    //  ("no responde al primer clic"). Mask the window's input region to
    //  everything EXCEPT the bar strip so bar clicks reach the bar directly.
    readonly property int barStrip: Theme.barHeight + Theme.barMarginTop
    Item {
        id: inputArea
        x: Panels.anchorBarPos === "left" ? win.barStrip : 0
        y: Panels.anchorBarPos === "top" ? win.barStrip : 0
        width: win.width - (win.sideBar ? win.barStrip : 0)
        height: win.height - (win.sideBar ? 0 : win.barStrip)
    }
    mask: Region { item: inputArea }

    // ---- staged intro (ilyamiro VolumePopup ANIMATIONS section) ------------
    property real introMain: 0
    property real introHeader: 0
    property real introContent: 0
    onShownChanged: {
        if (shown) {
            introAnim.restart();
        } else {
            introAnim.stop();
            introMain = 0; introHeader = 0; introContent = 0;
        }
    }
    ParallelAnimation {
        id: introAnim
        NumberAnimation { target: win; property: "introMain"; from: 0; to: 1; duration: Theme.dur(450); easing.type: Easing.OutExpo }
        SequentialAnimation {
            PauseAnimation { duration: Theme.dur(80) }
            NumberAnimation { target: win; property: "introHeader"; from: 0; to: 1; duration: Theme.dur(420); easing.type: Easing.OutBack; easing.overshoot: 1.2 }
        }
        SequentialAnimation {
            PauseAnimation { duration: Theme.dur(160) }
            NumberAnimation { target: win; property: "introContent"; from: 0; to: 1; duration: Theme.dur(450); easing.type: Easing.OutExpo }
        }
    }

    // shared orbit angle for the background blobs (runs only while open AND
    // only if the blobs are enabled — no point spinning an invisible value)
    property real orbit: 0
    NumberAnimation on orbit {
        from: 0; to: Math.PI * 2
        duration: 90000
        loops: Animation.Infinite
        running: win.shown && Theme.panelBlobs
    }

    // ---- placement --------------------------------------------------------
    //  top/bottom bar: card hangs below/above the widget, centred on its X.
    //  left/right bar: card opens beside the bar, centred on the widget's Y.
    readonly property bool bottomBar: Panels.anchorBarPos === "bottom"
    readonly property bool sideBar: Panels.anchorBarPos === "left" || Panels.anchorBarPos === "right"
    readonly property bool rightBar: Panels.anchorBarPos === "right"
    //  Panels.anchorAlign decide qué es anchorX sobre el eje principal:
    //  "center" = centro del card; "start"/"end" = borde inicial/final
    //  (paneles alineados al borde de su sección de barra — Session 26).
    readonly property real cardXRaw: sideBar
        ? (rightBar ? Panels.anchorEdge - panelWidth - gap : Panels.anchorEdge + gap)
        : (Panels.anchorAlign === "start" ? Panels.anchorX
         : Panels.anchorAlign === "end"   ? Panels.anchorX - panelWidth
         : Panels.anchorX - panelWidth / 2)
    readonly property real cardX: Math.max(gap, Math.min(width - panelWidth - gap, cardXRaw))
    readonly property real cardYRaw: sideBar
        ? (Panels.anchorAlign === "start" ? Panels.anchorX
         : Panels.anchorAlign === "end"   ? Panels.anchorX - card.height
         : Panels.anchorX - card.height / 2)
        : (bottomBar ? Panels.anchorEdge - card.height - gap : Panels.anchorEdge + gap)
    readonly property real cardY: Math.max(gap, Math.min(height - card.height - gap, cardYRaw))

    // dim backdrop + click-away dismiss
    Rectangle {
        anchors.fill: parent
        color: "#00000055"
        opacity: win.shown ? 1 : 0
        Behavior on opacity { NumberAnimation { duration: Theme.dur(150) } }
        MouseArea { anchors.fill: parent; onClicked: win.close() }
    }

    Rectangle {
        id: card
        x: win.cardX
        y: win.cardY
        width: win.panelWidth
        height: (loader.item ? loader.item.implicitHeight : 0) + win.contentMargin * 2
        radius: Theme.radius + 8
        color: Theme.base
        border.width: 1
        border.color: Theme.surface0
        clip: true

        // intro: fade + slight scale-up + slide from the anchor edge
        opacity: win.introMain
        scale: 0.95 + 0.05 * win.introMain
        transform: Translate {
            x: win.sideBar ? (win.rightBar ? 20 : -20) * (1 - win.introMain) : 0
            y: win.sideBar ? 0 : (win.bottomBar ? 20 : -20) * (1 - win.introMain)
        }

        layer.enabled: Theme.elevation
        layer.effect: MultiEffect {
            shadowEnabled: true
            shadowColor: Qt.rgba(0, 0, 0, 0.5)
            shadowBlur: 0.6
            shadowVerticalOffset: 6
            autoPaddingEnabled: true
        }

        // ---- orbiting background blobs (plain Rectangles — no blur/shader) --
        //  Contenidos a la SILUETA REDONDEADA del card: el `clip` del card es
        //  rectangular (y con layer.enabled la FBO también), así que los blobs
        //  se colaban en las esquinas redondeadas. Se enmascaran con un rect
        //  redondeado del mismo radio → nunca sobresalen del borde del panel.
        //  Desactivables por rendimiento (Theme.panelBlobs); con ello se apaga
        //  también su animación (running).
        Item {
            id: blobBox
            anchors.fill: parent
            visible: Theme.panelBlobs
            layer.enabled: Theme.panelBlobs
            layer.effect: MultiEffect {
                maskEnabled: true
                maskSource: blobMask
            }
            Rectangle {
                width: card.width * 0.8; height: width; radius: width / 2
                x: (card.width - width) / 2 + Math.cos(win.orbit * 2) * 150
                y: (card.height - height) / 2 + Math.sin(win.orbit * 2) * 100
                opacity: 0.06
                color: win.accentColor
                Behavior on color { ColorAnimation { duration: 800 } }
            }
            Rectangle {
                width: card.width * 0.9; height: width; radius: width / 2
                x: (card.width - width) / 2 + Math.sin(win.orbit * 1.5) * -150
                y: (card.height - height) / 2 + Math.cos(win.orbit * 1.5) * -100
                opacity: 0.04
                color: Qt.lighter(win.accentColor, 1.3)
                Behavior on color { ColorAnimation { duration: 800 } }
            }
        }
        // máscara: rect redondeado igual que el card (radio incluido); sólo su
        // canal alfa se usa, así que el color es indiferente.
        Rectangle {
            id: blobMask
            anchors.fill: parent
            radius: card.radius
            visible: false
            layer.enabled: true
        }

        // FocusScope común a TODOS los paneles anclados: mientras el panel está
        // abierto reclama el foco de teclado del window, así que Escape cierra
        // el panel entero (igual que el clic fuera) sin repetirlo panel a panel.
        // Semántica FocusScope: si el contenido declara su propio item con
        // `focus: true` (p.ej. un campo de búsqueda o contraseña) el foco activo
        // baja a ese hijo, pero un Escape que el hijo NO acepte burbujea de vuelta
        // a este scope. Los TextInput de Qt no consumen Escape, así que un campo
        // activo NO se limita a limpiarse: cierra el panel completo (comportamiento
        // deseado). Paneles que ya gestionan Escape en su contenido — p.ej.
        // ThemeQuickPanel — lo aceptan ellos y este handler no se dispara.
        FocusScope {
            id: contentScope
            anchors.fill: parent
            anchors.margins: win.contentMargin
            focus: win.shown
            Keys.onEscapePressed: win.close()

            Loader {
                id: loader
                anchors.fill: parent
                active: win.visible
            }
        }

        // push the intro phases into content that opts in
        Binding {
            target: loader.item
            when: loader.item !== null && loader.item !== undefined && "introHeader" in loader.item
            property: "introHeader"
            value: win.introHeader
            restoreMode: Binding.RestoreNone
        }
        Binding {
            target: loader.item
            when: loader.item !== null && loader.item !== undefined && "introContent" in loader.item
            property: "introContent"
            value: win.introContent
            restoreMode: Binding.RestoreNone
        }
    }

    // pull a content-driven accent (e.g. per-tab colours) into the blobs
    Binding {
        target: win
        when: loader.item !== null && loader.item !== undefined && "panelAccent" in loader.item
        property: "accentColor"
        value: loader.item ? loader.item.panelAccent : Theme.accent
        restoreMode: Binding.RestoreNone
    }

    // Las ventanas de la barra forman parte del grab: si no, el release del
    // mismo click que abre el panel (cae en la barra) limpiaba el grab y el
    // panel se abría y se cerraba al instante.
    HyprlandFocusGrab {
        active: win.shown
        windows: [ win ].concat(Panels.barWindows)
        onCleared: win.close()
    }
}
