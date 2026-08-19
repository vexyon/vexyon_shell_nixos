import QtQuick
import QtQuick.Layouts
import QtQuick.Effects
import Quickshell
import Quickshell.Io
import Quickshell.Hyprland
import Quickshell.Widgets
import Quickshell.Services.SystemTray
import qs.services
import qs.components

// ============================================================================
//  WidgetView — renders ONE bar widget's inner content (icon/label/etc.) with
//  NO pill chrome. BarWidget wraps this in a pill; a group places several of
//  these in a Row. Kept in its own file so BarWidget never instantiates itself
//  (Quickshell rejects recursive component use at load time).
// ============================================================================
Item {
    id: view

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
    // true cuando este WidgetView es un sub-widget dentro de una pastilla de
    // grupo: su zona pinta su propio hover (la pastilla entera no basta).
    property bool inGroup: false

    readonly property real fscale: Config.get("bar", "fontScale", 1.0)
    readonly property real iscale: Config.get("bar", "iconScale", 1.0)
    readonly property int  wFont: Math.max(7, Math.round(Theme.fontSize * fscale))
    readonly property int  wIcon: Math.max(9, Math.round((Theme.fontSize + 2) * iscale))
    readonly property bool structural: type === "spacer" || type === "separator"
    // grosor real de la barra (cross axis; Theme.barHeight sigue bar.barSize)
    readonly property int  barThick: Theme.barHeight

    implicitWidth: ld.item ? ld.item.implicitWidth : 20
    implicitHeight: ld.item ? ld.item.implicitHeight : (structural ? 4 : 22)
    // Un widget se auto-oculta exponiendo `selfHide` (property propia). NO se
    // usa `visible` del delegado: en QML la LECTURA de visible es la
    // visibilidad EFECTIVA (incluye ancestros) — con la pill oculta en el
    // primer frame (p.ej. Mpris tarda un tick en registrar) padre e hijo se
    // bloqueaban mutuamente en invisible para siempre.
    readonly property bool selfHide: ld.item ? ld.item.selfHide === true : false
    visible: !selfHide

    // Open an anchored dropdown panel hanging off this widget. QsWindow.window
    // = la ventana de la barra (para traducir coords de ventana a pantalla).
    // Si ESTE widget ya tiene ese panel abierto, el click lo cierra (toggle);
    // otro widget que comparta panel (p.ej. mic/volumen) solo lo re-ancla.
    function openPanel(name) {
        if (Panels[name] === true && Panels.anchorItem === view) {
            Panels.close(name);
            return;
        }
        Panels.openAt(name, view, view.screenName, view.barPos, QsWindow.window,
                      view.sectionItem, view.sectionAlign, view.sectionSplit);
    }

    // ---- Acción "de pastilla" -------------------------------------------------
    // Qué hace un click en el CUERPO de la pastilla (no sobre un sub-control).
    // Toda la pastilla es clicable, no solo el glifo; en un grupo cada sub-widget
    // recibe su propia zona (fondo por instancia) que dispara SU acción. Los
    // sub-controles (transporte de media, ítems de workspaces/tray, rueda/click
    // derecho del icono) van ENCIMA de este fondo y siguen capturando lo suyo.
    readonly property var _primaryTypes: ({
        applauncher:1, clock:1, volume:1, brightness:1, battery:1, network:1,
        bluetooth:1, microphone:1, power:1, controlcenter:1, weather:1,
        notifications:1, idleinhibitor:1, media:1, clipboard:1, cpu:1, memory:1,
        disk:1, cputemp:1, gputemp:1, vpn:1, keyboardlayout:1, notes:1,
        colorpicker:1, sysupdate:1
    })
    readonly property bool hasPrimaryAction: _primaryTypes[type] === 1
    function primaryAction(button) {
        var right = button === Qt.RightButton;
        switch (type) {
        case "applauncher":   Panels.toggle("launcher"); break;
        case "clock":         if (!right) openPanel("calendarPanel"); break;
        case "volume":        if (right) Audio.toggleMute(); else { Panels.volumeInitTab = "outputs"; openPanel("volumePanel"); } break;
        case "brightness":    Brightness.step(right ? -5 : 5); break;
        case "battery":       openPanel("batteryPanel"); break;
        case "network":       Panels.networkInitTab = Network.kind === "ethernet" ? "eth" : "wifi"; openPanel("networkPanel"); break;
        case "bluetooth":     if (right) Bluetooth.toggle(); else { Panels.networkInitTab = "bt"; openPanel("networkPanel"); } break;
        case "microphone":    if (right) Mic.toggleMute(); else { Panels.volumeInitTab = "inputs"; openPanel("volumePanel"); } break;
        case "power":         Panels.toggle("powermenu"); break;
        case "controlcenter": openPanel("quickSettings"); break;
        case "vpn":           openPanel("quickSettings"); break;
        case "weather":       openPanel("weatherPanel"); break;
        case "notifications": if (right) Notifications.toggleDnd(); else { Notifications.clear(); openPanel("notifCenter"); } break;
        case "idleinhibitor": IdleInhibitor.toggle(); break;
        case "media":         openPanel("mediaPlayer"); break;
        case "clipboard":     openPanel("clipboardPanel"); break;
        case "cpu": case "memory": case "disk": case "cputemp": case "gputemp": openPanel("sysMonitor"); break;
        case "keyboardlayout": KeyboardState.cycle(); break;
        case "notes":         Quickshell.execDetached(["bash", "-c", "ghostty -e bash -c '${EDITOR:-nano} ~/notes.md' || true"]); break;
        case "colorpicker":   Quickshell.execDetached(["bash", "-c", "command -v hyprpicker >/dev/null && hyprpicker -a || true"]); break;
        case "sysupdate":     Quickshell.execDetached(["bash", "-c", "ghostty -e bash -c 'sudo pacman -Syu; read -p \"Enter to close\"' || true"]); break;
        }
    }

    // workspace-appearance palette role resolver (shared by workspaces widget)
    function roleColor(name, fallback) {
        switch (name) {
        case "primary":   return Theme.accent;
        case "secondary": return Theme.accent2;
        case "surface":   return Theme.surface2;
        case "error":     return Theme.red;
        case "none":      return "transparent";
        default:          return fallback;
        }
    }

    // Fondo clicable de la pastilla/celda: cubre TODO el WidgetView (que a su vez
    // llena la pastilla en un widget suelto, o su celda en un grupo). Va DEBAJO
    // del Loader de contenido, así los sub-controles reales (transporte de media,
    // ítems de workspaces/tray) capturan lo suyo y el resto del área dispara la
    // acción del widget. Sólo activo si el tipo tiene acción primaria.
    // La pastilla suelta ya se aclara entera al hover (BarWidget); dentro de un
    // grupo cada zona pinta su propio hover/press aquí.
    readonly property bool pillPressed: bg.pressed
    MouseArea {
        id: bg
        anchors.fill: parent
        enabled: view.hasPrimaryAction && !view.structural
        visible: enabled
        hoverEnabled: enabled
        acceptedButtons: Qt.LeftButton | Qt.RightButton
        cursorShape: Qt.PointingHandCursor
        onClicked: function(mouse) {
            // un delegado puede exponer pillAction() si necesita estado propio
            // (p.ej. sysupdate relanza su Process); si no, acción central.
            if (ld.item && typeof ld.item.pillAction === "function")
                ld.item.pillAction(mouse.button);
            else
                view.primaryAction(mouse.button);
        }
        onWheel: function(w) {
            var up = w.angleDelta.y > 0;
            if (view.type === "volume")          Audio.step(up ? 0.05 : -0.05);
            else if (view.type === "brightness") Brightness.step(up ? 5 : -5);
            else w.accepted = false;
        }
        // hover/press de la zona de un sub-widget dentro de un grupo
        Rectangle {
            anchors.fill: parent
            visible: view.inGroup && (bg.containsMouse || bg.pressed)
            radius: Math.min(Theme.radius, Math.min(width, height) / 2)
            color: Theme.surface2
            opacity: bg.pressed ? 0.85 : 0.5
            Behavior on opacity { NumberAnimation { duration: Theme.dur(100); easing.type: Theme.easing } }
        }
    }

    Loader {
        id: ld
        anchors.centerIn: parent
        sourceComponent:
              view.type === "applauncher"    ? cApplauncher
            : view.type === "workspaces"     ? cWorkspaces
            : view.type === "clock"          ? cClock
            : view.type === "focusedwindow"  ? cFocused
            : view.type === "volume"         ? cVolume
            : view.type === "brightness"     ? cBrightness
            : view.type === "battery"        ? cBattery
            : view.type === "network"        ? cNetwork
            : view.type === "bluetooth"      ? cBluetooth
            : view.type === "microphone"     ? cMic
            : view.type === "power"          ? cPower
            : view.type === "controlcenter"  ? cControl
            : view.type === "weather"        ? cWeather
            : view.type === "notifications"  ? cNotif
            : view.type === "idleinhibitor"  ? cIdle
            : view.type === "media"          ? cMedia
            : view.type === "clipboard"      ? cClipboard
            : view.type === "cpu"            ? cCpu
            : view.type === "memory"         ? cMem
            : view.type === "disk"           ? cDisk
            : view.type === "cputemp"        ? cCpuTemp
            : view.type === "gputemp"        ? cGpuTemp
            : view.type === "netspeed"       ? cNetSpeed
            : view.type === "systemtray"     ? cTray
            : view.type === "privacy"        ? cPrivacy
            : view.type === "vpn"            ? cVpn
            : view.type === "capslock"       ? cCaps
            : view.type === "keyboardlayout" ? cKbLayout
            : view.type === "notes"          ? cNotes
            : view.type === "colorpicker"    ? cColorPicker
            : view.type === "sysupdate"      ? cSysUpdate
            : view.type === "appsdock"       ? cAppsDock
            : view.type === "spacer"         ? cSpacer
            : view.type === "separator"      ? cSeparator
            : cUnknown
    }

    // ---- DMS clock: parell de dígits d'amplada fixa (no salta en canviar) --
    component ClockDigits : Row {
        id: cd
        property string value: ""
        spacing: 0
        Repeater {
            model: 2
            delegate: Text {
                required property int index
                text: cd.value.length > index ? cd.value.charAt(index) : ""
                color: Theme.text
                font.family: Theme.fontFamily
                font.pixelSize: view.wFont
                font.bold: true
                width: Math.round(view.wFont * 0.6)
                horizontalAlignment: Text.AlignHCenter
            }
        }
    }

    // ---- glifo pasivo (sin MouseArea ni hover propio) ----------------------
    //  Sustituye a IconButton en los widgets cuya ÚNICA interacción es la
    //  acción primaria: el click/hover lo pone el fondo de la pastilla (bg),
    //  así se ilumina la pastilla entera y no un cuadrado alrededor del icono.
    //  Mismo footprint (28px) que el IconButton que reemplaza.
    component Glyph : Item {
        property string icon: ""
        property color iconColor: Theme.text
        property bool selfHide: false
        implicitWidth: 28
        implicitHeight: 28
        Text {
            anchors.centerIn: parent
            text: parent.icon
            color: parent.iconColor
            font.family: Theme.fontFamily
            font.pixelSize: view.wIcon
        }
    }

    // ---- reusable label (icon glyph + text) --------------------------------
    //  Horizontal bar: glyph y texto en fila. Barra vertical: apilados en
    //  columna (texto pequeño bajo el icono) para caber en el grosor.
    component Pill : Grid {
        property string glyph: ""
        property string label: ""
        property color glyphColor: Theme.text
        property color labelColor: Theme.subtext0
        property int labelSize: view.wFont - 1
        columns: view.vertical ? 1 : 2
        columnSpacing: 5
        rowSpacing: 0
        horizontalItemAlignment: Grid.AlignHCenter
        verticalItemAlignment: Grid.AlignVCenter
        Text {
            visible: parent.glyph !== ""
            text: parent.glyph
            color: parent.glyphColor
            font.family: Theme.fontFamily
            font.pixelSize: view.wIcon
        }
        Text {
            visible: parent.label !== ""
            text: parent.label
            color: parent.labelColor
            font.family: Theme.fontFamily
            font.pixelSize: view.vertical ? Math.min(parent.labelSize, view.wFont - 3) : parent.labelSize
        }
    }

    // ======================= WIDGET COMPONENTS =============================

    Component { id: cUnknown
        Text { text: "?"; color: Theme.overlay2; font.family: Theme.fontFamily; font.pixelSize: view.wFont }
    }

    Component { id: cApplauncher
        LauncherIcon {
            // icono por instancia: cfg.icon (clave) → glifo/logo; def. "grid"
            iconKey: view.cfg && view.cfg.icon ? view.cfg.icon : "grid"
            pixel: view.wIcon
            tint: Panels.launcher ? Theme.accent : Theme.text
        }
    }

    // --------------------------- WORKSPACES --------------------------------
    Component {
        id: cWorkspaces
        Item {
            id: wsw
            // OJO: key ha de ser undefined (no null) para que get() devuelva la
            // sección entera; con null devolvía s[null] => {} y TODOS los
            // ajustes de workspaces caían a sus defaults en silencio.
            readonly property var wc: Config.get("workspaces") || ({})
            function wcget(k, d) { return wsw.wc[k] === undefined ? d : wsw.wc[k]; }

            readonly property int focusedId: Hyprland.focusedWorkspace ? Hyprland.focusedWorkspace.id : 1
            readonly property bool followMon: wcget("followMonitor", false)
            readonly property int curMon: Hyprland.focusedMonitor ? Hyprland.focusedMonitor.id : -1

            readonly property var existing: {
                var s = [];
                var vals = Hyprland.workspaces.values;
                for (var i = 0; i < vals.length; i++) {
                    var w = vals[i];
                    if (!w || w.id <= 0) continue;
                    if (wsw.followMon && wsw.curMon >= 0 && w.monitor && w.monitor.id !== wsw.curMon) continue;
                    if (s.indexOf(w.id) === -1) s.push(w.id);
                }
                return s;
            }
            readonly property var wsList: {
                var occ = wsw.existing.slice();
                var onlyOcc = wsw.wcget("onlyOccupied", true);
                if (occ.indexOf(wsw.focusedId) === -1) occ.push(wsw.focusedId);
                var minN = wsw.wcget("minCount", 0);
                var mx = 0;
                for (var j = 0; j < occ.length; j++) mx = Math.max(mx, occ[j]);
                if (!onlyOcc) { for (var n = 1; n <= Math.max(minN, mx + 1); n++) if (occ.indexOf(n) === -1) occ.push(n); }
                else { for (var m = 1; m <= minN; m++) if (occ.indexOf(m) === -1) occ.push(m);
                       occ.push(mx + 1); }
                occ.sort(function(a, b) { return a - b; });
                var out = [];
                for (var k = 0; k < occ.length; k++) if (out.indexOf(occ[k]) === -1) out.push(occ[k]);
                return out;
            }
            function isExisting(id) { return wsw.existing.indexOf(id) !== -1; }
            function wsName(id) {
                var vals = Hyprland.workspaces.values;
                for (var i = 0; i < vals.length; i++) if (vals[i] && vals[i].id === id) return vals[i].name || ("" + id);
                return "" + id;
            }
            // urgent real de Hyprland (evento `urgent` del socket2, que quickshell
            // ya refleja en HyprlandWorkspace.urgent y limpia al enfocar). La
            // lectura de .urgent dentro del binding registra la dependencia.
            function isUrgent(id) {
                var vals = Hyprland.workspaces.values;
                for (var i = 0; i < vals.length; i++) if (vals[i] && vals[i].id === id) return vals[i].urgent === true;
                return false;
            }
            // apps del workspace: appId de cada toplevel (reactivo — workspace/
            // appId/values son properties con notify que el binding rastrea)
            function appsOf(id) {
                var out = [];
                var vals = Hyprland.toplevels.values;
                for (var i = 0; i < vals.length; i++) {
                    var t = vals[i];
                    if (!t || !t.workspace || t.workspace.id !== id) continue;
                    var cls = (t.wayland && t.wayland.appId) ? t.wayland.appId
                              : (t.lastIpcObject && t.lastIpcObject["class"]) ? t.lastIpcObject["class"] : "";
                    if (cls !== "") out.push(cls);
                }
                return out;
            }
            function appIconSource(cls) {
                var entry = DesktopEntries.heuristicLookup(cls);
                if (entry && entry.icon) return Quickshell.iconPath(entry.icon, "application-x-executable");
                return Quickshell.iconPath(cls.toLowerCase(), "application-x-executable");
            }

            implicitWidth: wsRow.implicitWidth
            implicitHeight: wsRow.implicitHeight

            GridLayout {
                id: wsRow
                anchors.centerIn: parent
                // fila en barra horizontal (columns -1 = sin límite), columna
                // única en barra vertical
                columns: view.vertical ? 1 : -1
                rowSpacing: 6
                columnSpacing: 6
                Repeater {
                    model: wsw.wsList
                    delegate: Rectangle {
                        id: ws
                        required property var modelData
                        readonly property int wsId: modelData
                        readonly property bool focused: wsw.focusedId === wsId
                        readonly property bool occupied: wsw.isExisting(wsId)
                        readonly property bool showName: wsw.wcget("showNames", false)
                        readonly property bool numbered: wsw.wcget("numbered", true)
                        // workspaces.showApps: iconos de las apps abiertas dentro de la píldora
                        readonly property var appIcons: wsw.wcget("showApps", false) ? wsw.appsOf(wsId) : []
                        readonly property bool hasApps: appIcons.length > 0
                        // workspaces.urgentColor: resalta el workspace con una ventana urgent
                        readonly property bool urgent: !focused && wsw.isUrgent(wsId)

                        // el pill enfocado crece a lo largo del eje de la barra;
                        // con iconos de apps crece lo que pida el contenido
                        implicitHeight: view.vertical
                            ? (hasApps ? Math.max(focused ? 30 : 22, wsContent.implicitHeight + 14) : (focused ? 30 : 22))
                            : 22
                        implicitWidth: view.vertical ? 22
                            : (hasApps ? Math.max(focused ? 30 : 22, wsContent.implicitWidth + 14)
                               : (focused ? Math.max(30, wsLabel.implicitWidth + 16) : 22))
                        radius: 11
                        Layout.alignment: Qt.AlignHCenter | Qt.AlignVCenter
                        color: focused ? view.roleColor(wsw.wcget("focusedColor", "primary"), Theme.accent)
                               : urgent ? view.roleColor(wsw.wcget("urgentColor", "error"), Theme.red)
                               : occupied ? view.roleColor(wsw.wcget("occupiedColor", "surface"), Theme.surface2)
                               : view.roleColor(wsw.wcget("unfocusedColor", "none"), "transparent")
                        border.width: (focused && wsw.wcget("focusedBorder", false)) ? 2
                                      : (!focused && !occupied) ? 1 : 0
                        border.color: (focused && wsw.wcget("focusedBorder", false)) ? Theme.accent2 : Theme.overlay0
                        opacity: (focused || occupied || urgent) ? 1.0 : 0.6
                        Behavior on implicitWidth { NumberAnimation { duration: Theme.dur(180); easing.type: Theme.easing } }
                        Behavior on implicitHeight { NumberAnimation { duration: Theme.dur(180); easing.type: Theme.easing } }
                        Behavior on color { ColorAnimation { duration: Theme.dur(160) } }

                        Grid {
                            id: wsContent
                            anchors.centerIn: parent
                            // iconos en fila en barra horizontal, en columna en vertical.
                            // OJO: si columns > nº de ítems visibles, Grid infla
                            // implicitWidth con un columnSpacing fantasma (+4px) y el
                            // contenido queda ~2px a la izquierda del centro de la
                            // píldora — columns ha de ser el recuento EXACTO.
                            columns: view.vertical ? 1
                                : Math.max(1, (wsLabel.visible ? 1 : 0) + ws.appIcons.length)
                            horizontalItemAlignment: Grid.AlignHCenter
                            verticalItemAlignment: Grid.AlignVCenter
                            columnSpacing: 4
                            rowSpacing: 4

                            Text {
                                id: wsLabel
                                visible: ws.numbered || ws.showName
                                text: ws.showName ? wsw.wsName(ws.wsId) : ws.wsId
                                color: (ws.focused || ws.urgent) ? Theme.onAccent : ws.occupied ? Theme.subtext1 : Theme.overlay2
                                font.family: Theme.fontFamily
                                font.pixelSize: view.wFont - 3
                                font.bold: ws.focused
                            }
                            Repeater {
                                model: ws.appIcons
                                delegate: IconImage {
                                    required property var modelData
                                    implicitSize: 14
                                    source: wsw.appIconSource(modelData)
                                }
                            }
                        }
                        MouseArea {
                            anchors.fill: parent
                            cursorShape: Qt.PointingHandCursor
                            // Forma Lua (la cadena hyprlang "workspace N" no parsea)
                            onClicked: Hyprland.dispatch("hl.dsp.focus({ workspace = " + ws.wsId + " })")
                        }
                    }
                }
            }
        }
    }

    // ----------------------------- CLOCK -----------------------------------
    //  Estil DMS: dígits d'amplada fixa (0.6×font per dígit, sense salts),
    //  separador «•» en overlay, data en color d'accent. Per-instància:
    //  cfg.showDate (def. true), cfg.showSeconds (def. false).
    Component {
        id: cClock
        Item {
            id: clockMa
            readonly property bool showDate: view.cfg && view.cfg.showDate !== undefined ? view.cfg.showDate : true
            readonly property bool showSeconds: view.cfg && view.cfg.showSeconds === true

            // Con :ss visible este reloj exige el tick de 1s de Time; sin él,
            // Time duerme hasta el borde de minuto. Registro idempotente
            // (guard ssReg): el binding inicial puede disparar el changed
            // ANTES de onCompleted y no debe contar doble.
            property bool ssReg: false
            function syncSsReg() {
                if (showSeconds && !ssReg) { Time.ssWatchers++; ssReg = true; }
                else if (!showSeconds && ssReg) { Time.ssWatchers--; ssReg = false; }
            }
            onShowSecondsChanged: syncSsReg()
            Component.onCompleted: syncSsReg()
            Component.onDestruction: if (ssReg) Time.ssWatchers--
            implicitWidth: clockLd.item ? clockLd.item.implicitWidth : 20
            implicitHeight: clockLd.item ? clockLd.item.implicitHeight : 20

            Loader {
                id: clockLd
                anchors.centerIn: parent
                sourceComponent: view.vertical ? clkVert : clkHoriz
            }

            Component {
                id: clkHoriz
                Row {
                    spacing: 7
                    Row {
                        spacing: 0
                        anchors.verticalCenter: parent.verticalCenter
                        ClockDigits { value: Time.hh }
                        Text { text: ":"; color: Theme.text; font.family: Theme.fontFamily; font.pixelSize: view.wFont; font.bold: true }
                        ClockDigits { value: Time.mm }
                        Text { visible: clockMa.showSeconds; text: ":"; color: Theme.text; font.family: Theme.fontFamily; font.pixelSize: view.wFont; font.bold: true }
                        ClockDigits { visible: clockMa.showSeconds; value: Time.ss }
                    }

                    Text {
                        visible: clockMa.showDate
                        anchors.verticalCenter: parent.verticalCenter
                        text: "•"; color: Theme.overlay0
                        font.family: Theme.fontFamily; font.pixelSize: view.wFont - 2
                    }
                    Text {
                        visible: clockMa.showDate
                        anchors.verticalCenter: parent.verticalCenter
                        text: Time.date; color: Theme.accent
                        font.family: Theme.fontFamily; font.pixelSize: view.wFont - 1
                    }
                }
            }
            // barra vertical: HH sobre MM (patrón DMS); sin fecha — no cabe
            Component {
                id: clkVert
                Column {
                    spacing: 0
                    // los ClockDigits comparten ancho fijo (2 × 0.6×font) — ya
                    // quedan alineados sin anchors (prohibidos en positioners)
                    ClockDigits { value: Time.hh }
                    ClockDigits { value: Time.mm }
                    ClockDigits { visible: clockMa.showSeconds; value: Time.ss }
                }
            }
        }
    }

    // ------------------------- FOCUSED WINDOW ------------------------------
    Component {
        id: cFocused
        Text {
            readonly property var tl: Hyprland.activeToplevel
            text: tl && tl.title ? tl.title : (tl && tl.lastIpcObject ? (tl.lastIpcObject.class || "") : "")
            // un título horizontal no cabe en una barra vertical — se oculta
            readonly property bool selfHide: text === "" || view.vertical
            color: Theme.subtext1
            font.family: Theme.fontFamily
            font.pixelSize: view.wFont - 1
            elide: Text.ElideRight
            maximumLineCount: 1
            // per-instància: cfg.maxWidth (def. 260)
            width: Math.min(implicitWidth, view.cfg && view.cfg.maxWidth !== undefined ? view.cfg.maxWidth : 260)
        }
    }

    Component { id: cVolume
        Glyph {
            icon: Audio.muted || Audio.percent === 0 ? Icons.volumeMute
                  : Audio.percent < 50 ? Icons.volumeLow : Icons.volumeHigh
            iconColor: Audio.muted ? Theme.overlay2 : Theme.text
        }
    }

    Component { id: cBrightness
        Glyph {
            selfHide: !Brightness.available
            icon: Icons.brightness
        }
    }

    Component { id: cBattery
        Pill {
            readonly property bool selfHide: !Battery.present
            glyph: Battery.charging ? Icons.charging : Battery.percent <= 15 ? Icons.batteryLow : Icons.battery
            glyphColor: Battery.percent <= 15 && !Battery.charging ? Theme.red : Battery.charging ? Theme.green : Theme.text
            label: Battery.percent + "%"
            labelSize: view.wFont - 2
        }
    }

    Component { id: cNetwork
        Glyph {
            icon: Network.kind === "wifi" ? Icons.wifi : Network.kind === "ethernet" ? Icons.ethernet : Icons.noNetwork
            iconColor: Network.kind === "disconnected" ? Theme.overlay2 : Theme.text
        }
    }

    Component { id: cBluetooth
        Glyph {
            selfHide: !Bluetooth.present
            icon: Icons.bluetooth
            iconColor: !Bluetooth.enabled ? Theme.overlay2 : Bluetooth.connectedCount > 0 ? Theme.accent : Theme.text
        }
    }

    Component { id: cMic
        Glyph {
            selfHide: !Mic.present
            icon: Mic.muted ? Icons.micOff : Icons.microphone
            iconColor: Mic.muted ? Theme.overlay2 : Theme.text
        }
    }

    Component { id: cPower
        Glyph {
            icon: Icons.power
            iconColor: Panels.powermenu ? Theme.red : Theme.text
        }
    }

    Component { id: cControl
        Glyph {
            icon: Icons.sliders
            iconColor: Panels.quickSettings ? Theme.accent : Theme.text
        }
    }

    Component { id: cWeather
        Pill {
            readonly property bool selfHide: !Weather.ok
            glyph: Icons.cloud; glyphColor: Theme.blue
            label: Weather.ok ? (Weather.temp + "°") : ""
        }
    }

    Component { id: cNotif
        Glyph {
            icon: Notifications.dnd ? Icons.bellOff : Icons.bell
            iconColor: Notifications.dnd ? Theme.overlay2 : Notifications.unread > 0 ? Theme.accent : Theme.text
        }
    }

    Component { id: cIdle
        Glyph {
            icon: Icons.coffee
            iconColor: IdleInhibitor.active ? Theme.accent : Theme.overlay2
        }
    }

    Component {
        id: cMedia
        // El fondo de la pastilla (bg) abre el panel en cualquier punto libre;
        // los botones de transporte, ENCIMA, capturan sus propios clicks (son
        // sub-controles reales, no solo decoración).
        Grid {
            readonly property bool selfHide: !Media.present
            columns: view.vertical ? 1 : 99
            columnSpacing: 4
            rowSpacing: 4
            horizontalItemAlignment: Grid.AlignHCenter
            verticalItemAlignment: Grid.AlignVCenter
            IconButton { icon: Icons.stepBack; iconSize: view.wFont - 1; implicitWidth: 22; implicitHeight: 22; onClicked: Media.previous() }
            IconButton { icon: Media.playing ? Icons.pause : Icons.play; iconColor: Theme.accent; iconSize: view.wFont; implicitWidth: 22; implicitHeight: 22; onClicked: Media.toggle() }
            IconButton { icon: Icons.stepForward; iconSize: view.wFont - 1; implicitWidth: 22; implicitHeight: 22; onClicked: Media.next() }
            Text {
                // per-instància: cfg.showLabel (def. true); sense títol en vertical
                visible: (view.cfg && view.cfg.showLabel !== undefined ? view.cfg.showLabel : true) && !view.vertical
                text: Media.label; color: Theme.subtext0
                font.family: Theme.fontFamily; font.pixelSize: view.wFont - 2
                elide: Text.ElideRight; maximumLineCount: 1
                width: Math.min(implicitWidth, 180)
            }
        }
    }

    Component { id: cClipboard
        Glyph { icon: Icons.clipboard }
    }

    // monitor widgets: pasivos — el fondo de la pastilla abre sysMonitor.
    // Cada instancia refcuenta en SystemStats: sin ninguna, el poll de 2s
    // no corre (nada lo muestra).
    component MonPill: Pill {
        property bool selfHide: false
        Component.onCompleted: SystemStats.watchers++
        Component.onDestruction: SystemStats.watchers--
    }
    Component { id: cCpu
        MonPill { glyph: Icons.microchip; glyphColor: Theme.peach; label: SystemStats.cpuPercent + "%" }
    }
    Component { id: cMem
        MonPill { glyph: Icons.server; glyphColor: Theme.mauve; label: SystemStats.memPercent + "%" }
    }
    Component { id: cDisk
        MonPill { glyph: Icons.drive; glyphColor: Theme.teal; label: SystemStats.diskPercent + "%" }
    }
    Component { id: cCpuTemp
        MonPill { selfHide: SystemStats.cpuTemp <= 0; glyph: Icons.thermometer
               glyphColor: SystemStats.cpuTemp >= 80 ? Theme.red : Theme.yellow
               label: SystemStats.cpuTemp + "°" }
    }
    Component { id: cGpuTemp
        MonPill { selfHide: SystemStats.gpuTemp <= 0; glyph: Icons.thermometer
               glyphColor: SystemStats.gpuTemp >= 85 ? Theme.red : Theme.green
               label: SystemStats.gpuTemp + "°" }
    }
    Component {
        id: cNetSpeed
        Grid {
            // también lee SystemStats (velocidad de red) — mismo refcount
            Component.onCompleted: SystemStats.watchers++
            Component.onDestruction: SystemStats.watchers--
            columns: view.vertical ? 1 : 2
            columnSpacing: 6
            rowSpacing: 2
            horizontalItemAlignment: Grid.AlignHCenter
            verticalItemAlignment: Grid.AlignVCenter
            Row {
                spacing: 2
                Text { anchors.verticalCenter: parent.verticalCenter; text: Icons.arrowDown; color: Theme.green; font.family: Theme.fontFamily; font.pixelSize: view.wFont - 2 }
                Text { anchors.verticalCenter: parent.verticalCenter; text: SystemStats.fmtSpeed(SystemStats.netDownKbs); color: Theme.subtext0; font.family: Theme.fontFamily; font.pixelSize: view.wFont - 3 }
            }
            Row {
                spacing: 2
                Text { anchors.verticalCenter: parent.verticalCenter; text: Icons.arrowUp; color: Theme.peach; font.family: Theme.fontFamily; font.pixelSize: view.wFont - 2 }
                Text { anchors.verticalCenter: parent.verticalCenter; text: SystemStats.fmtSpeed(SystemStats.netUpKbs); color: Theme.subtext0; font.family: Theme.fontFamily; font.pixelSize: view.wFont - 3 }
            }
        }
    }

    // --------------------------- SYSTEM TRAY -------------------------------
    Component {
        id: cTray
        Grid {
            columns: view.vertical ? 1 : 99
            columnSpacing: 6
            rowSpacing: 6
            horizontalItemAlignment: Grid.AlignHCenter
            verticalItemAlignment: Grid.AlignVCenter
            readonly property bool selfHide: !(SystemTray.items && SystemTray.items.values.length > 0)
            readonly property string tint: Config.get("bar", "trayTint", "none")
            Repeater {
                model: SystemTray.items ? SystemTray.items.values : []
                // Each icon is its own hover cell (like DMS) so per-app feedback
                // reads within the shared tray pill. Left-click = default
                // activation; middle = secondary activation; right = the app's
                // OWN DBusMenu, rendered themed by TrayMenu (Panels.openTrayMenu).
                delegate: Rectangle {
                    id: trayItem
                    required property var modelData
                    width: 24; height: 24
                    radius: Theme.radius
                    color: trayMa.containsMouse ? Theme.surface1 : "transparent"
                    Behavior on color { ColorAnimation { duration: Theme.dur(120) } }

                    IconImage {
                        id: trayIcon
                        anchors.centerIn: parent
                        width: 18; height: 18
                        source: trayItem.modelData.icon
                        visible: parent.parent.tint === "none"
                    }
                    MultiEffect {
                        anchors.centerIn: parent
                        width: 18; height: 18
                        source: trayIcon
                        visible: parent.parent.tint !== "none"
                        colorization: 1.0
                        colorizationColor: parent.parent.tint === "primary" ? Theme.accent
                                         : parent.parent.tint === "secondary" ? Theme.accent2
                                         : Theme.text
                        brightness: 0.0
                    }
                    MouseArea {
                        id: trayMa
                        anchors.fill: parent
                        hoverEnabled: true
                        cursorShape: Qt.PointingHandCursor
                        acceptedButtons: Qt.LeftButton | Qt.MiddleButton | Qt.RightButton
                        onClicked: function(m) {
                            var d = trayItem.modelData;
                            if (m.button === Qt.RightButton) {
                                if (d.hasMenu && d.menu)
                                    Panels.openTrayMenu(d.menu, trayItem, view.screenName, view.barPos, QsWindow.window);
                                else
                                    d.activate();
                            } else if (m.button === Qt.MiddleButton) {
                                d.secondaryActivate();
                            } else {
                                // onlyMenu items have no activation — show their menu
                                if (d.onlyMenu && d.hasMenu && d.menu)
                                    Panels.openTrayMenu(d.menu, trayItem, view.screenName, view.barPos, QsWindow.window);
                                else
                                    d.activate();
                            }
                        }
                    }
                }
            }
        }
    }

    Component { id: cPrivacy
        Grid {
            readonly property bool selfHide: !Privacy.active
            Component.onCompleted: Privacy.watchers++
            Component.onDestruction: Privacy.watchers--
            columns: view.vertical ? 1 : 2
            columnSpacing: 4
            rowSpacing: 4
            horizontalItemAlignment: Grid.AlignHCenter
            verticalItemAlignment: Grid.AlignVCenter
            Text { visible: Privacy.micInUse; text: Icons.microphone; color: Theme.red; font.family: Theme.fontFamily; font.pixelSize: view.wIcon }
            Text { visible: Privacy.camInUse; text: Icons.video; color: Theme.red; font.family: Theme.fontFamily; font.pixelSize: view.wIcon }
        }
    }

    // ------------------------------ VPN ------------------------------------
    Component {
        id: cVpn
        Item {
            id: vpnw
            property bool connected: false
            property bool detected: false
            implicitWidth: vpnBtn.implicitWidth; implicitHeight: 28
            readonly property bool selfHide: !detected
            Timer { interval: 6000; running: true; repeat: true; triggeredOnStart: true; onTriggered: vpnProc.running = true }
            Process {
                id: vpnProc
                command: ["bash", "-c",
                    "nmcli -t -f TYPE,STATE connection show --active 2>/dev/null | grep -qE '^(vpn|wireguard):' && echo up && exit; " +
                    "ip -brief link show type wireguard 2>/dev/null | grep -q . && echo up && exit; " +
                    "nmcli -t -f TYPE connection show 2>/dev/null | grep -qE '^(vpn|wireguard)$' && echo down || echo none"]
                stdout: StdioCollector {
                    onStreamFinished: {
                        var s = this.text.trim();
                        vpnw.connected = (s === "up");
                        vpnw.detected = (s !== "none");
                    }
                }
            }
            Glyph {
                id: vpnBtn
                icon: Icons.shield
                iconColor: vpnw.connected ? Theme.green : Theme.overlay2
            }
        }
    }

    Component { id: cCaps
        Text {
            readonly property bool selfHide: !KeyboardState.capsOn
            text: "A"; color: Theme.yellow
            font.family: Theme.fontFamily; font.pixelSize: view.wFont; font.bold: true
            Component.onCompleted: KeyboardState.watchers++
            Component.onDestruction: KeyboardState.watchers--
        }
    }

    Component { id: cKbLayout
        Pill {
            glyph: Icons.language
            label: KeyboardState.layout
            Component.onCompleted: KeyboardState.watchers++
            Component.onDestruction: KeyboardState.watchers--
        }
    }

    Component { id: cNotes
        Glyph { icon: Icons.stickyNote }
    }

    Component { id: cColorPicker
        Glyph { icon: Icons.eyeDropper }
    }

    Component {
        id: cSysUpdate
        Item {
            id: upw
            property int count: 0
            implicitWidth: upRow.implicitWidth; implicitHeight: upRow.implicitHeight
            Timer { interval: 1800000; running: true; repeat: true; triggeredOnStart: true; onTriggered: upProc.running = true }
            Process {
                id: upProc
                command: ["bash", "-c", "command -v checkupdates >/dev/null && checkupdates 2>/dev/null | wc -l || echo 0"]
                stdout: StdioCollector { onStreamFinished: upw.count = parseInt(this.text.trim()) || 0 }
            }
            Pill {
                id: upRow
                glyph: Icons.download
                glyphColor: upw.count > 0 ? Theme.yellow : Theme.overlay2
                label: upw.count > 0 ? ("" + upw.count) : ""
                labelSize: view.wFont - 2
            }
            // acción con estado propio (relanza el chequeo): la invoca el
            // fondo clicable de la pastilla en lugar de primaryAction().
            function pillAction(button) {
                upProc.running = true;
                Quickshell.execDetached(["bash", "-c", "ghostty -e bash -c 'sudo pacman -Syu; read -p \"Enter to close\"' || true"]);
            }
        }
    }

    // ------------------------- APPS DOCK (best-effort) ---------------------
    Component {
        id: cAppsDock
        Grid {
            id: dock
            columns: view.vertical ? 1 : 99
            columnSpacing: 4
            rowSpacing: 4
            horizontalItemAlignment: Grid.AlignHCenter
            verticalItemAlignment: Grid.AlignVCenter
            ListModel { id: dockModel }
            // Event-driven: la lista de clases solo cambia al abrir/cerrar/
            // mover ventanas — los eventos de Hyprland ya llegan por el socket
            // que Quickshell escucha. Coalescing de 250ms para ráfagas. Antes:
            // hyprctl+jq cada 3s pasara lo que pasara; mismo dato, más fresco.
            Component.onCompleted: dockProc.running = true
            Timer { id: dockDebounce; interval: 250; onTriggered: dockProc.running = true }
            Connections {
                target: Hyprland
                function onRawEvent(event) {
                    switch (event.name) {
                    case "openwindow": case "closewindow": case "movewindow":
                        dockDebounce.restart(); break;
                    }
                }
            }
            Process {
                id: dockProc
                command: ["bash", "-c", "hyprctl clients -j | jq -r '[.[]|.class]|unique|.[]' 2>/dev/null"]
                stdout: StdioCollector {
                    onStreamFinished: {
                        dockModel.clear();
                        var lines = this.text.trim().split("\n");
                        for (var i = 0; i < lines.length; i++) { var c = lines[i].trim(); if (c !== "") dockModel.append({ cls: c }); }
                    }
                }
            }
            Repeater {
                model: dockModel
                delegate: IconImage {
                    required property var model
                    width: 20; height: 20
                    source: Quickshell.iconPath(model.cls.toLowerCase(), true)
                    MouseArea {
                        anchors.fill: parent; cursorShape: Qt.PointingHandCursor
                        // Forma Lua; el selector "class:<x>" sí lo entiende hl.focus
                        onClicked: Hyprland.dispatch('hl.dsp.focus({ window = "class:' + model.cls + '" })')
                    }
                }
            }
        }
    }

    // ------------------------- STRUCTURAL ----------------------------------
    // estructurales: su eje largo sigue el eje principal de la barra
    Component {
        id: cSpacer
        Item {
            readonly property int span: view.cfg && view.cfg.width !== undefined ? view.cfg.width : 24
            implicitWidth: view.vertical ? 4 : span
            implicitHeight: view.vertical ? span : 4
        }
    }
    Component {
        id: cSeparator
        Rectangle {
            implicitWidth: view.vertical ? view.barThick - 16 : 1
            implicitHeight: view.vertical ? 1 : view.barThick - 16
            color: Theme.overlay0
            opacity: 0.5
        }
    }
}
