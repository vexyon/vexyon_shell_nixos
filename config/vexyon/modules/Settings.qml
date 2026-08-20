import QtQuick
import QtQuick.Layouts
import QtQuick.Dialogs
import QtQuick.Effects
import Quickshell
import Quickshell.Io
import Quickshell.Hyprland
import qs.services
import qs.components

// ============================================================================
//  Settings — full DankMaterialShell-style settings window: a header bar, a
//  LEFT sidebar (profile card + search + categorized collapsible nav with an
//  accent-filled active pill) and a RIGHT scroll area of content pages. This is
//  the real home for theme/keybind/appearance config; the Control Center only
//  keeps the compact quick toggles and links here.
// ============================================================================
FloatingWindow {
    id: win
    visible: Panels.settings
    title: "vexyon-settings"
    implicitWidth: 1100
    implicitHeight: 760
    color: Theme.base

    // currently-selected content page id
    property string current: "theme"
    // per-section collapse map (title -> true means collapsed)
    property var collapsed: ({})
    property string query: ""

    // widget-manager grouping selection: { sectionName: [ids] }
    property var wmSel: ({})
    function wmSelected(sec) { return win.wmSel[sec] || []; }
    function wmIsSel(sec, id) { return win.wmSelected(sec).indexOf(id) !== -1; }
    function wmToggleSel(sec, id) {
        var cur = win.wmSelected(sec).slice();
        var i = cur.indexOf(id);
        if (i === -1) cur.push(id); else cur.splice(i, 1);
        var m = Object.assign({}, win.wmSel); m[sec] = cur; win.wmSel = m;
    }
    function wmClearSel(sec) { var m = Object.assign({}, win.wmSel); m[sec] = []; win.wmSel = m; }
    function wmGroup(sec) {
        var ids = win.wmSelected(sec);
        if (ids.length >= 2) { WidgetRegistry.groupWidgets(sec, ids); win.wmClearSel(sec); }
    }
    // human-readable child summary for a group entry
    function wmGroupSummary(entry) {
        if (!entry || !entry.children) return "";
        var names = [];
        for (var i = 0; i < entry.children.length; i++)
            names.push(WidgetRegistry.meta(entry.children[i].type).name);
        return names.join(" · ");
    }

    // Labels here are ENGLISH SOURCE KEYS; every render/measure/search site runs
    // them through I18n.t() so the tree localizes live. Do NOT translate them in
    // place — that would break the lookup.
    readonly property var sections: [
        { "title": "Personalization", "icon": Icons.palette, "items": [
            { "id": "wallpaper",  "label": "Wallpaper",           "icon": Icons.image },
            { "id": "theme",      "label": "Theme & colors",      "icon": Icons.palette },
            { "id": "store",      "label": "Theme store",         "icon": Icons.download },
            { "id": "typography", "label": "Typography & motion", "icon": Icons.typography }
        ] },
        { "title": "Bar", "icon": Icons.sliders, "items": [
            { "id": "barsettings", "label": "Bar settings", "icon": Icons.sliders },
            { "id": "barwidgets",  "label": "Bar widgets",  "icon": Icons.grid },
            { "id": "workspaces",  "label": "Workspaces",   "icon": Icons.desktop }
        ] },
        { "title": "Virtualization", "icon": Icons.desktop, "items": [
            { "id": "virtualization", "label": "Virtualization", "icon": Icons.desktop }
        ] },
        { "title": "System", "icon": Icons.gear, "items": [
            { "id": "audio",    "label": "Audio",              "icon": Icons.volumeHigh },
            { "id": "network",  "label": "Network",            "icon": Icons.wifi },
            { "id": "displays", "label": "Displays",           "icon": Icons.desktop },
            { "id": "keybinds", "label": "Keyboard shortcuts", "icon": Icons.keyboard },
            { "id": "behavior", "label": "Behavior",           "icon": Icons.gear },
            { "id": "about",    "label": "About Vexyon",       "icon": Icons.info }
        ] }
    ]

    // Ancho del sidebar = etiqueta de nav más ancha + cromo (icono, sangrías,
    // márgenes), en vez de un ancho fijo generoso que apretaba el panel de
    // contenido. Mide con TextMetrics las cabeceras (negrita) y los ítems.
    TextMetrics { id: navMetrics; font.family: Theme.fontFamily }
    function navLabelMaxWidth() {
        var m = 0;
        for (var s = 0; s < win.sections.length; s++) {
            navMetrics.font.pixelSize = Theme.fontSize - 1; navMetrics.font.bold = true;
            navMetrics.text = I18n.t(win.sections[s].title);
            if (navMetrics.advanceWidth > m) m = navMetrics.advanceWidth;
            navMetrics.font.bold = false;
            var items = win.sections[s].items;
            for (var i = 0; i < items.length; i++) {
                navMetrics.text = I18n.t(items[i].label);
                if (navMetrics.advanceWidth > m) m = navMetrics.advanceWidth;
            }
        }
        return m;
    }

    function isOpen(title) { return win.collapsed[title] !== true; }
    function toggleSection(title) {
        var c = Object.assign({}, win.collapsed);
        c[title] = !(c[title] === true ? true : false);
        win.collapsed = c;
    }
    function matches() {
        var q = win.query.toLowerCase().trim();
        var out = [];
        for (var s = 0; s < win.sections.length; s++) {
            var items = win.sections[s].items;
            for (var i = 0; i < items.length; i++)
                if (I18n.t(items[i].label).toLowerCase().indexOf(q) !== -1) out.push(items[i]);
        }
        return out;
    }
    function pageTitle(id) {
        var map = { "wallpaper": "Wallpaper", "theme": "Theme & colors",
                    "store": "Theme store",
                    "typography": "Typography & motion", "keybinds": "Keyboard shortcuts",
                    "barsettings": "Bar settings",
                    "barwidgets": "Bar widgets", "workspaces": "Workspaces",
                    "audio": "Audio",
                    "network": "Network", "displays": "Displays",
                    "behavior": "Behavior",
                    "virtualization": "Virtualization",
                    "about": "About Vexyon" };
        return I18n.t(map[id] || id);
    }

    property string host: ""
    Process {
        id: hostProc
        command: ["uname", "-n"]
        stdout: StdioCollector { onStreamFinished: win.host = this.text.trim() }
    }
    onVisibleChanged: {
        if (visible) { hostProc.running = true; monNames.running = true; }
        // Cierre EXTERNO (Super+Q/killactive): el compositor cierra el toplevel
        // y Qt escribe visible=false por debajo del binding, sin pasar por
        // Panels. Sin este resync, Panels.settings queda en true y volver a
        // ponerlo a true no emite señal → la ventana no se puede reabrir.
        else if (Panels.settings) Panels.settings = false;
    }

    // The settings window is a real Hyprland toplevel (class org.quickshell,
    // title "vexyon-settings"). We deliberately DO NOT force it to float/center:
    // it tiles and is managed exactly like any other window (terminal, browser…),
    // so Super+Shift+F fullscreen, tiling, moving and Super+W float-toggle all
    // apply to it uniformly. implicitWidth/Height below are just the size it
    // takes when it happens to be floating.

    // "add widget" modal target section ("" = closed)
    property string addTarget: ""
    property string modalQuery: ""
    onAddTargetChanged: modalQuery = ""

    function catalogMatches() {
        var q = win.modalQuery.toLowerCase().trim();
        var out = [];
        // visibleCatalog, no catalog: los widgets tras un interruptor apagado
        // (p.ej. la pastilla de VMs sin Virtualización activada) no deben
        // poder añadirse a la barra.
        var cat = WidgetRegistry.visibleCatalog;
        for (var i = 0; i < cat.length; i++) {
            var c = cat[i];
            if (q === "" || c.name.toLowerCase().indexOf(q) !== -1 || c.desc.toLowerCase().indexOf(q) !== -1)
                out.push(c);
        }
        return out;
    }

    // palette-role options for workspace color pickers
    readonly property var roleOptions: [
        { v: "primary", l: I18n.t("Primary") }, { v: "secondary", l: I18n.t("Secondary") },
        { v: "surface", l: I18n.t("Surface") }, { v: "error", l: "Error" }, { v: "none", l: I18n.t("None") }
    ]

    // monitor names for "assigned screen"
    property var monitors: []
    Process {
        id: monNames
        command: ["bash", "-c", "hyprctl monitors -j | jq -r '.[].name'"]
        stdout: StdioCollector {
            onStreamFinished: {
                var a = this.text.trim().split("\n").filter(function(x) { return x.trim() !== ""; });
                win.monitors = a;
            }
        }
    }

    // ---------------- reusable setting controls (file-wide) ----------------
    // ---- Virtualización: utilidades de la página ---------------------------
    //  Copiar al portapapeles: mismo mecanismo exacto que ya usa el panel de
    //  monitor del sistema (wl-copy vía execDetached), no uno nuevo.
    // ¿ya hay una pastilla de VMs en alguna sección de la barra? Evita ofrecer
    // "añadir a la barra" cuando ya está puesta (y evita duplicarla).
    function vmWidgetOnBar() {
        var secs = ["left", "center", "right"];
        for (var s = 0; s < secs.length; s++) {
            var list = WidgetRegistry.section(secs[s]);
            for (var i = 0; i < list.length; i++) {
                if (list[i].type === "vm") return true;
                if (list[i].type === "group" && list[i].children) {
                    var ch = list[i].children;
                    for (var c = 0; c < ch.length; c++) if (ch[c].type === "vm") return true;
                }
            }
        }
        return false;
    }

    function copyText(t) {
        Quickshell.execDetached(["bash", "-c", "printf %s " + JSON.stringify("" + t) + " | wl-copy"]);
    }

    // Una fila de la lista de requisitos: verde con check si está, rojo/ámbar
    // con aspa si falta. GRANULAR a propósito — el usuario tiene que ver QUÉ
    // pieza le falta, no un "no funciona" global.
    component ReqRow: RowLayout {
        id: rr
        property bool ok: false
        property bool optional: false
        property string label: ""
        property string note: ""
        // Mientras la sonda no ha contestado NO se pinta nada en rojo: un aspa
        // roja antes de comprobar dice "te falta" cuando en realidad es "aún no
        // lo sé", que es peor que no decir nada.
        property bool pending: false
        Layout.fillWidth: true
        spacing: 10
        Text {
            Layout.alignment: Qt.AlignTop
            Layout.topMargin: 2
            Layout.preferredWidth: 16
            text: rr.pending ? "\u00b7\u00b7\u00b7" : (rr.ok ? Icons.check : Icons.close)
            color: rr.pending ? Theme.overlay1
                 : rr.ok ? Theme.green : (rr.optional ? Theme.yellow : Theme.red)
            font.family: Theme.fontFamily
            font.pixelSize: Theme.fontSize
        }
        ColumnLayout {
            Layout.fillWidth: true
            spacing: 1
            Text {
                Layout.fillWidth: true
                text: rr.label
                color: Theme.text
                wrapMode: Text.Wrap
                font.family: Theme.fontFamily
                font.pixelSize: Theme.fontSize - 1
            }
            Text {
                Layout.fillWidth: true
                visible: rr.note !== ""
                text: rr.note
                color: Theme.subtext0
                wrapMode: Text.Wrap
                font.family: Theme.fontFamily
                font.pixelSize: Theme.fontSize - 3
            }
        }
        Text {
            Layout.alignment: Qt.AlignTop
            Layout.topMargin: 2
            visible: rr.optional
            text: I18n.t("optional")
            color: Theme.overlay2
            font.family: Theme.fontFamily
            font.pixelSize: Theme.fontSize - 3
        }
    }

    // Bloque de código copiable. `tone` pinta el borde: "add" (verde) para lo
    // que se PEGA TAL CUAL como bloque nuevo, "merge" (ámbar) para lo que hay
    // que FUNDIR con listas que el usuario ya tiene. Esa distinción es la
    // manera más probable de que alguien se cargue su configuración con un
    // copia-pega, así que se ve a la primera.
    component CodeBlock: Rectangle {
        id: cb
        property string code: ""
        property string tone: "plain"    // "add" | "merge" | "plain"
        Layout.fillWidth: true
        implicitHeight: cbCol.implicitHeight + 20
        radius: Theme.radius
        color: Theme.crust
        border.width: cb.tone === "plain" ? 1 : 2
        border.color: cb.tone === "add" ? Theme.green
                    : cb.tone === "merge" ? Theme.yellow : Theme.surface2
        ColumnLayout {
            id: cbCol
            anchors.left: parent.left
            anchors.right: parent.right
            anchors.verticalCenter: parent.verticalCenter
            anchors.leftMargin: 12
            anchors.rightMargin: 8
            spacing: 6
            RowLayout {
                Layout.fillWidth: true
                spacing: 8
                Text {
                    Layout.fillWidth: true
                    text: cb.code
                    color: Theme.text
                    wrapMode: Text.NoWrap
                    font.family: Theme.fontFamily
                    font.pixelSize: Theme.fontSize - 2
                }
                IconButton {
                    Layout.alignment: Qt.AlignTop
                    icon: Icons.copy
                    onClicked: win.copyText(cb.code)
                }
            }
        }
    }

    // Rótulo grande de "PARTE A / PARTE B" con su explicación.
    component PartLabel: ColumnLayout {
        id: pl
        property string tag: ""
        property string title: ""
        property string body: ""
        property color tone: Theme.green
        Layout.fillWidth: true
        Layout.topMargin: 10
        spacing: 4
        RowLayout {
            Layout.fillWidth: true
            spacing: 8
            Rectangle {
                Layout.alignment: Qt.AlignVCenter
                implicitWidth: tagTxt.implicitWidth + 14
                implicitHeight: 22
                radius: 6
                color: pl.tone
                Text {
                    id: tagTxt
                    anchors.centerIn: parent
                    text: pl.tag
                    color: Theme.crust
                    font.family: Theme.fontFamily
                    font.pixelSize: Theme.fontSize - 3
                    font.bold: true
                }
            }
            Text {
                Layout.fillWidth: true
                text: pl.title
                color: Theme.text
                wrapMode: Text.Wrap
                font.family: Theme.fontFamily
                font.pixelSize: Theme.fontSize
                font.bold: true
            }
        }
        Text {
            Layout.fillWidth: true
            visible: pl.body !== ""
            text: pl.body
            color: Theme.subtext0
            wrapMode: Text.Wrap
            font.family: Theme.fontFamily
            font.pixelSize: Theme.fontSize - 2
        }
    }

    component SsHeader: Text {
        Layout.fillWidth: true
        Layout.topMargin: 8
        color: Theme.subtext1
        font.family: Theme.fontFamily
        font.pixelSize: Theme.fontSize - 1
        font.bold: true
    }

    // ---- controles de opciones por-instancia (Gestor de widgets, patrón DMS)
    //  A diferencia de SsToggle/SsSlider (atados a Config sect/clave), estos
    //  son "tontos": reciben el valor actual y emiten edited(v); el llamador
    //  escribe la prop de la instancia vía WidgetRegistry.setProp.
    component WmToggle: RowLayout {
        id: wmt
        property string label: ""
        property bool checked: false
        signal edited(bool v)
        Layout.fillWidth: true
        spacing: 8
        Text { Layout.fillWidth: true; text: wmt.label; color: Theme.subtext1; font.family: Theme.fontFamily; font.pixelSize: Theme.fontSize - 2 }
        Toggle { checked: wmt.checked; onToggled: function(v) { wmt.edited(v) } }
    }

    component WmSlider: ColumnLayout {
        id: wms
        property string label: ""
        property real min: 0
        property real max: 100
        property real step: 1
        property real value: 0
        property string suffix: " px"
        signal edited(real v)
        Layout.fillWidth: true
        spacing: 2
        RowLayout {
            Layout.fillWidth: true
            Text { Layout.fillWidth: true; text: wms.label; color: Theme.subtext1; font.family: Theme.fontFamily; font.pixelSize: Theme.fontSize - 2 }
            Text { text: Math.round(wms.value) + wms.suffix; color: Theme.subtext0; font.family: Theme.fontFamily; font.pixelSize: Theme.fontSize - 2 }
        }
        Slider {
            Layout.fillWidth: true
            value: (wms.value - wms.min) / Math.max(0.0001, wms.max - wms.min)
            onMoved: function(v) {
                var raw = wms.min + v * (wms.max - wms.min);
                wms.edited(Math.round(raw / wms.step) * wms.step);
            }
        }
    }

    component SsToggle: Rectangle {
        property string label: ""
        property string sect: "bar"
        property string k: ""
        property bool def: false
        Layout.fillWidth: true
        Layout.preferredHeight: 46
        radius: Theme.radius
        color: Theme.surface0
        RowLayout {
            anchors.fill: parent; anchors.leftMargin: 14; anchors.rightMargin: 12
            Text { Layout.fillWidth: true; text: label; color: Theme.text; font.family: Theme.fontFamily; font.pixelSize: Theme.fontSize }
            Toggle { checked: Config.get(sect, k, def); onToggled: function(v) { Config.set(sect, k, v) } }
        }
    }

    component SsSlider: Rectangle {
        property string label: ""
        property string sect: "bar"
        property string k: ""
        property real min: 0
        property real max: 1
        property real def: 0.5
        property real step: 0.01
        property string suffix: ""
        property bool showReset: false
        property real resetTo: def
        readonly property real cur: Config.get(sect, k, def)
        function fmt(v) { return step >= 1 ? Math.round(v) + suffix : (Math.round(v / step) * step).toFixed(2) + suffix; }
        Layout.fillWidth: true
        Layout.preferredHeight: 58
        radius: Theme.radius
        color: Theme.surface0
        ColumnLayout {
            anchors.fill: parent; anchors.leftMargin: 14; anchors.rightMargin: 12; anchors.topMargin: 8; anchors.bottomMargin: 8
            spacing: 2
            RowLayout {
                Layout.fillWidth: true
                Text { Layout.fillWidth: true; text: label; color: Theme.text; font.family: Theme.fontFamily; font.pixelSize: Theme.fontSize }
                Text { text: fmt(cur); color: Theme.subtext0; font.family: Theme.fontFamily; font.pixelSize: Theme.fontSize - 1 }
                IconButton {
                    visible: showReset; icon: Icons.refresh; iconSize: Theme.fontSize - 1; implicitWidth: 24; implicitHeight: 24
                    onClicked: Config.set(sect, k, resetTo)
                }
            }
            Slider {
                Layout.fillWidth: true
                value: (cur - min) / Math.max(0.0001, (max - min))
                onMoved: function(v) {
                    var raw = min + v * (max - min);
                    var snapped = Math.round(raw / step) * step;
                    Config.set(sect, k, step >= 1 ? Math.round(snapped) : Math.round(snapped * 100) / 100);
                }
            }
        }
    }

    // segmented single-choice selector. options = [{ v, l }]
    component SsSeg: ColumnLayout {
        property string label: ""
        property string sect: "bar"
        property string k: ""
        property var options: []
        property var def: ""
        Layout.fillWidth: true
        spacing: 6
        Text { visible: label !== ""; text: label; color: Theme.text; font.family: Theme.fontFamily; font.pixelSize: Theme.fontSize }
        Flow {
            Layout.fillWidth: true
            spacing: 6
            Repeater {
                model: options
                delegate: Rectangle {
                    required property var modelData
                    readonly property bool sel: Config.get(sect, k, def) === modelData.v
                    width: segTxt.implicitWidth + 24; height: 32
                    radius: Theme.radius
                    color: sel ? Theme.accent : (segMa.containsMouse ? Theme.surface2 : Theme.surface0)
                    border.width: sel ? 0 : 1
                    border.color: Theme.surface2
                    Text {
                        id: segTxt
                        anchors.centerIn: parent
                        text: modelData.l
                        color: parent.sel ? Theme.onAccent : Theme.text
                        font.family: Theme.fontFamily; font.pixelSize: Theme.fontSize - 2
                    }
                    MouseArea {
                        id: segMa; anchors.fill: parent; hoverEnabled: true
                        cursorShape: Qt.PointingHandCursor
                        onClicked: Config.set(sect, k, modelData.v)
                    }
                }
            }
        }
    }

    // text input bound to a config key (commits on Enter / focus-out).
    component SsText: Rectangle {
        property string label: ""
        property string sect: "behavior"
        property string k: ""
        property string def: ""
        property string placeholder: ""
        Layout.fillWidth: true
        Layout.preferredHeight: 64
        radius: Theme.radius
        color: Theme.surface0
        ColumnLayout {
            anchors.fill: parent; anchors.leftMargin: 14; anchors.rightMargin: 12; anchors.topMargin: 8; anchors.bottomMargin: 8
            spacing: 4
            Text { text: label; color: Theme.text; font.family: Theme.fontFamily; font.pixelSize: Theme.fontSize }
            Rectangle {
                Layout.fillWidth: true; Layout.preferredHeight: 30
                radius: Theme.radius - 2
                color: Theme.mantle
                border.width: 1; border.color: sf.activeFocus ? Theme.accent : Theme.surface2
                TextInput {
                    id: sf
                    anchors.fill: parent; anchors.leftMargin: 10; anchors.rightMargin: 10
                    verticalAlignment: TextInput.AlignVCenter
                    clip: true
                    text: Config.get(sect, k, def)
                    color: Theme.text
                    selectionColor: Theme.accent
                    font.family: Theme.fontFamily; font.pixelSize: Theme.fontSize - 1
                    onEditingFinished: if (text !== Config.get(sect, k, def)) Config.set(sect, k, text)
                    Text {
                        anchors.verticalCenter: parent.verticalCenter
                        visible: sf.text === ""
                        text: placeholder
                        color: Theme.overlay1
                        font: sf.font
                    }
                }
            }
        }
    }

    // generic dropdown: options=[{v,l}], current value, emits picked(v)
    component DropSelect: ColumnLayout {
        id: ds
        property string label: ""
        property var options: []
        property var current: null
        property int maxVisible: 7
        property bool open: false
        signal picked(var v)
        function curLabel() {
            for (var i = 0; i < ds.options.length; i++)
                if (ds.options[i].v === ds.current) return ds.options[i].l;
            return "—";
        }
        Layout.fillWidth: true
        spacing: 4
        Text { visible: ds.label !== ""; text: ds.label; color: Theme.subtext1; font.family: Theme.fontFamily; font.pixelSize: Theme.fontSize - 2 }
        Rectangle {
            Layout.fillWidth: true
            Layout.preferredHeight: 36
            radius: Theme.radius
            color: Theme.surface0
            border.width: 1; border.color: ds.open ? Theme.accent : Theme.surface2
            RowLayout {
                anchors.fill: parent; anchors.leftMargin: 12; anchors.rightMargin: 10; spacing: 8
                Text { Layout.fillWidth: true; text: ds.curLabel(); color: Theme.text; font.family: Theme.fontFamily; font.pixelSize: Theme.fontSize - 1; elide: Text.ElideRight }
                Text { text: ds.open ? Icons.chevronDown : Icons.chevronRight; color: Theme.subtext0; font.family: Theme.fontFamily; font.pixelSize: Theme.fontSize - 3 }
            }
            MouseArea { anchors.fill: parent; cursorShape: Qt.PointingHandCursor; onClicked: ds.open = !ds.open }
        }
        Rectangle {
            visible: ds.open
            Layout.fillWidth: true
            Layout.preferredHeight: Math.min(ds.options.length, ds.maxVisible) * 32 + 8
            radius: Theme.radius
            color: Theme.mantle
            border.width: 1; border.color: Theme.surface2
            ListView {
                anchors.fill: parent; anchors.margins: 4
                clip: true
                model: ds.options
                boundsBehavior: Flickable.StopAtBounds
                delegate: Rectangle {
                    required property var modelData
                    readonly property bool sel: modelData.v === ds.current
                    width: ListView.view.width; height: 32
                    radius: Theme.radius - 2
                    color: sel ? Qt.rgba(Theme.accent.r, Theme.accent.g, Theme.accent.b, 0.2) : (dsMa.containsMouse ? Theme.surface1 : "transparent")
                    RowLayout {
                        anchors.fill: parent; anchors.leftMargin: 10; anchors.rightMargin: 8; spacing: 8
                        Text { Layout.fillWidth: true; text: modelData.l; color: parent.parent.sel ? Theme.accent : Theme.text; font.family: Theme.fontFamily; font.pixelSize: Theme.fontSize - 2; elide: Text.ElideRight }
                        Text { visible: parent.parent.sel; text: Icons.check; color: Theme.accent; font.family: Theme.fontFamily; font.pixelSize: Theme.fontSize - 3 }
                    }
                    MouseArea { id: dsMa; anchors.fill: parent; hoverEnabled: true; cursorShape: Qt.PointingHandCursor
                        onClicked: { ds.picked(modelData.v); ds.open = false; } }
                }
            }
        }
    }

    // Content fills the real toplevel window; Hyprland manages the frame,
    // rounding and float/move/tile behavior (see vexyon-rules.lua).
    Rectangle {
        id: winCard
        anchors.fill: parent
        color: Theme.base

        ColumnLayout {
            anchors.fill: parent
            spacing: 0

            // ---- header ----
            RowLayout {
                Layout.fillWidth: true
                Layout.preferredHeight: 56
                Layout.leftMargin: 20
                Layout.rightMargin: 14
                spacing: 12
                Text {
                    text: Icons.gear
                    color: Theme.accent
                    font.family: Theme.fontFamily
                    font.pixelSize: Theme.fontSize + 5
                }
                Text {
                    text: I18n.t("Settings")
                    color: Theme.text
                    font.family: Theme.fontFamily
                    font.pixelSize: Theme.fontSize + 6
                    font.bold: true
                }
                Item { Layout.fillWidth: true }
                IconButton { icon: Icons.close; onClicked: Panels.close("settings") }
            }

            Rectangle { Layout.fillWidth: true; Layout.preferredHeight: 1; color: Theme.surface1 }

            // ---- body: sidebar + content ----
            RowLayout {
                Layout.fillWidth: true
                Layout.fillHeight: true
                spacing: 0

                // ======== SIDEBAR ========
                ColumnLayout {
                    // Ancho INTRÍNSECO: la etiqueta de nav más ancha + cromo
                    // (icono + sangría + spacing + margen). Se PINEA con min =
                    // pref = max para que el ancho no lo dicte el hijo más ancho
                    // (el texto de perfil "Clic: cambiar foto…", la búsqueda…):
                    // sin fijar el máximo, el minimumWidth implícito de esos
                    // hijos estiraba el sidebar hasta ~50% del panel. Con el tope,
                    // esos hijos (todos con elide/fillWidth) se recortan solos.
                    // navW se recalcula IMPERATIVAMENTE (no binding): la medición
                    // muta navMetrics (text/font) mientras lo lee → un binding
                    // sobre ella se auto-invalida y QML detecta binding loop.
                    id: sideCol
                    property real navW: 66
                    function updateNavW() { navW = Math.round(win.navLabelMaxWidth()) + 66; }
                    Component.onCompleted: updateNavW()
                    Connections { target: I18n; function onLangChanged() { sideCol.updateNavW(); } }
                    Connections { target: Theme; function onFontSizeChanged() { sideCol.updateNavW(); } }
                    Layout.fillWidth: false
                    Layout.minimumWidth: navW
                    Layout.preferredWidth: navW
                    Layout.maximumWidth: navW
                    Layout.fillHeight: true
                    Layout.margins: 16
                    spacing: 12

                    // profile card
                    RowLayout {
                        Layout.fillWidth: true
                        spacing: 12
                        // avatar clicable → elegir foto (overlay de cámara al hover)
                        Item {
                            Layout.preferredWidth: 48; Layout.preferredHeight: 48
                            Avatar { anchors.fill: parent; size: 48; fallbackScale: 0.42 }
                            Rectangle {
                                anchors.fill: parent
                                radius: width / 2
                                color: Qt.rgba(0, 0, 0, 0.5)
                                visible: avaMa.containsMouse
                                Text {
                                    anchors.centerIn: parent
                                    text: Icons.pencil
                                    color: "#ffffff"; font.family: Theme.fontFamily; font.pixelSize: 16
                                }
                            }
                            MouseArea {
                                id: avaMa
                                anchors.fill: parent
                                hoverEnabled: true
                                cursorShape: Qt.PointingHandCursor
                                acceptedButtons: Qt.LeftButton | Qt.RightButton
                                onClicked: function(m) {
                                    if (m.button === Qt.RightButton) Profile.clearAvatar();
                                    else avatarPicker.open();
                                }
                            }
                        }
                        ColumnLayout {
                            Layout.fillWidth: true
                            spacing: 0
                            Text {
                                text: Quickshell.env("USER") || "user"
                                color: Theme.text
                                font.family: Theme.fontFamily
                                font.pixelSize: Theme.fontSize + 2
                                font.bold: true
                            }
                            Text {
                                text: win.host !== "" ? win.host : "vexyon"
                                color: Theme.subtext0
                                font.family: Theme.fontFamily
                                font.pixelSize: Theme.fontSize - 2
                                elide: Text.ElideRight
                                Layout.fillWidth: true
                            }
                            Text {
                                text: I18n.t("Click: change photo · Right: remove")
                                color: Theme.overlay1
                                font.family: Theme.fontFamily
                                font.pixelSize: Theme.fontSize - 4
                                Layout.fillWidth: true; elide: Text.ElideRight
                            }
                        }
                    }

                    // selector de foto de perfil (portal xdg / QtQuick.Dialogs)
                    FileDialog {
                        id: avatarPicker
                        title: I18n.t("Choose profile photo")
                        nameFilters: [I18n.t("Images (*.png *.jpg *.jpeg *.webp *.bmp *.gif)")]
                        onAccepted: Profile.setAvatar(selectedFile)
                    }

                    // search
                    Rectangle {
                        Layout.fillWidth: true
                        Layout.preferredHeight: 36
                        radius: Theme.radius
                        color: Theme.surface0
                        border.width: searchInput.activeFocus ? 1 : 0
                        border.color: Theme.accent
                        RowLayout {
                            anchors.fill: parent
                            anchors.leftMargin: 12
                            anchors.rightMargin: 10
                            spacing: 8
                            Text {
                                text: Icons.search
                                color: Theme.subtext0
                                font.family: Theme.fontFamily
                                font.pixelSize: Theme.fontSize
                            }
                            TextInput {
                                id: searchInput
                                Layout.fillWidth: true
                                clip: true
                                color: Theme.text
                                font.family: Theme.fontFamily
                                font.pixelSize: Theme.fontSize
                                selectionColor: Theme.accent
                                verticalAlignment: TextInput.AlignVCenter
                                onTextChanged: win.query = text
                                Text {
                                    anchors.verticalCenter: parent.verticalCenter
                                    visible: searchInput.text === ""
                                    text: I18n.t("Search…")
                                    color: Theme.overlay1
                                    font: searchInput.font
                                }
                            }
                        }
                    }

                    // nav
                    Flickable {
                        Layout.fillWidth: true
                        Layout.fillHeight: true
                        contentHeight: navCol.implicitHeight
                        clip: true
                        boundsBehavior: Flickable.StopAtBounds

                        ColumnLayout {
                            id: navCol
                            width: parent.width
                            spacing: 2

                            // sectioned view (no search)
                            Repeater {
                                model: win.query.trim() === "" ? win.sections : []
                                delegate: ColumnLayout {
                                    required property var modelData
                                    Layout.fillWidth: true
                                    spacing: 2

                                    // section header
                                    Rectangle {
                                        Layout.fillWidth: true
                                        Layout.preferredHeight: 34
                                        radius: Theme.radius
                                        color: hdrMa.containsMouse ? Theme.surface0 : "transparent"
                                        RowLayout {
                                            anchors.fill: parent
                                            anchors.leftMargin: 8
                                            anchors.rightMargin: 8
                                            spacing: 10
                                            Text {
                                                text: modelData.icon
                                                color: Theme.subtext1
                                                font.family: Theme.fontFamily
                                                font.pixelSize: Theme.fontSize
                                                Layout.preferredWidth: 18
                                                horizontalAlignment: Text.AlignHCenter
                                            }
                                            Text {
                                                Layout.fillWidth: true
                                                text: I18n.t(modelData.title)
                                                color: Theme.subtext1
                                                font.family: Theme.fontFamily
                                                font.pixelSize: Theme.fontSize - 1
                                                font.bold: true
                                            }
                                            Text {
                                                text: win.isOpen(modelData.title) ? Icons.chevronDown : Icons.chevronRight
                                                color: Theme.overlay2
                                                font.family: Theme.fontFamily
                                                font.pixelSize: Theme.fontSize - 2
                                            }
                                        }
                                        MouseArea {
                                            id: hdrMa
                                            anchors.fill: parent
                                            hoverEnabled: true
                                            cursorShape: Qt.PointingHandCursor
                                            onClicked: win.toggleSection(modelData.title)
                                        }
                                    }

                                    // section items
                                    Repeater {
                                        model: win.isOpen(modelData.title) ? modelData.items : []
                                        delegate: Rectangle {
                                            required property var modelData
                                            readonly property bool sel: win.current === modelData.id
                                            Layout.fillWidth: true
                                            Layout.preferredHeight: 32
                                            Layout.leftMargin: 10
                                            radius: Theme.radius
                                            color: sel ? Theme.accent
                                                       : (itemMa.containsMouse ? Theme.surface1 : "transparent")
                                            RowLayout {
                                                anchors.fill: parent
                                                anchors.leftMargin: 10
                                                anchors.rightMargin: 8
                                                spacing: 10
                                                Text {
                                                    text: modelData.icon
                                                    color: parent.parent.sel ? Theme.onAccent : Theme.subtext0
                                                    font.family: Theme.fontFamily
                                                    font.pixelSize: Theme.fontSize
                                                    Layout.preferredWidth: 18
                                                    horizontalAlignment: Text.AlignHCenter
                                                }
                                                Text {
                                                    Layout.fillWidth: true
                                                    text: I18n.t(modelData.label)
                                                    color: parent.parent.sel ? Theme.onAccent : Theme.text
                                                    font.family: Theme.fontFamily
                                                    font.pixelSize: Theme.fontSize - 1
                                                    elide: Text.ElideRight
                                                }
                                            }
                                            MouseArea {
                                                id: itemMa
                                                anchors.fill: parent
                                                hoverEnabled: true
                                                cursorShape: Qt.PointingHandCursor
                                                onClicked: win.current = modelData.id
                                            }
                                        }
                                    }
                                }
                            }

                            // flat filtered view (searching)
                            Repeater {
                                model: win.query.trim() === "" ? [] : win.matches()
                                delegate: Rectangle {
                                    required property var modelData
                                    readonly property bool sel: win.current === modelData.id
                                    Layout.fillWidth: true
                                    Layout.preferredHeight: 32
                                    radius: Theme.radius
                                    color: sel ? Theme.accent
                                               : (fMa.containsMouse ? Theme.surface1 : "transparent")
                                    RowLayout {
                                        anchors.fill: parent
                                        anchors.leftMargin: 10
                                        anchors.rightMargin: 8
                                        spacing: 10
                                        Text {
                                            text: modelData.icon
                                            color: parent.parent.sel ? Theme.onAccent : Theme.subtext0
                                            font.family: Theme.fontFamily
                                            font.pixelSize: Theme.fontSize
                                            Layout.preferredWidth: 18
                                            horizontalAlignment: Text.AlignHCenter
                                        }
                                        Text {
                                            Layout.fillWidth: true
                                            text: I18n.t(modelData.label)
                                            color: parent.parent.sel ? Theme.onAccent : Theme.text
                                            font.family: Theme.fontFamily
                                            font.pixelSize: Theme.fontSize - 1
                                            elide: Text.ElideRight
                                        }
                                    }
                                    MouseArea {
                                        id: fMa
                                        anchors.fill: parent
                                        hoverEnabled: true
                                        cursorShape: Qt.PointingHandCursor
                                        onClicked: win.current = modelData.id
                                    }
                                }
                            }
                        }
                    }
                }

                Rectangle { Layout.preferredWidth: 1; Layout.fillHeight: true; color: Theme.surface1 }

                // ======== CONTENT ========
                ColumnLayout {
                    Layout.fillWidth: true
                    Layout.fillHeight: true
                    Layout.margins: 22
                    spacing: 16

                    Text {
                        text: win.pageTitle(win.current)
                        color: Theme.text
                        font.family: Theme.fontFamily
                        font.pixelSize: Theme.fontSize + 5
                        font.bold: true
                    }

                    Loader {
                        Layout.fillWidth: true
                        Layout.fillHeight: true
                        sourceComponent: win.current === "theme" ? cmpTheme
                                       : win.current === "store" ? cmpStore
                                       : win.current === "typography" ? cmpType
                                       : win.current === "keybinds" ? cmpKeys
                                       : win.current === "wallpaper" ? cmpWall
                                       : win.current === "barsettings" ? cmpBarSettings
                                       : win.current === "barwidgets" ? cmpWidgetManager
                                       : win.current === "workspaces" ? cmpWorkspaces
                                       : win.current === "audio" ? cmpAudio
                                       : win.current === "network" ? cmpNetwork
                                       : win.current === "displays" ? cmpDisplays
                                       : win.current === "behavior" ? cmpBehavior
                                       : win.current === "virtualization" ? cmpVirt
                                       : cmpAbout
                    }
                }
            }
        }

        // ---------------- add-widget modal ----------------
        Rectangle {
            id: addModal
            anchors.fill: parent
            visible: win.addTarget !== ""
            color: Qt.rgba(0, 0, 0, 0.5)
            z: 100
            MouseArea { anchors.fill: parent; onClicked: win.addTarget = "" }

            Rectangle {
                anchors.centerIn: parent
                width: 480; height: Math.min(600, win.height - 80)
                radius: Theme.radius + 4
                color: Theme.mantle
                border.width: 1; border.color: Theme.surface2
                MouseArea { anchors.fill: parent /* swallow */ }

                ColumnLayout {
                    anchors.fill: parent
                    anchors.margins: 18
                    spacing: 12

                    RowLayout {
                        Layout.fillWidth: true
                        Text {
                            Layout.fillWidth: true
                            text: I18n.t("Add widget · ") + (win.addTarget === "left" ? I18n.t("Left") : win.addTarget === "center" ? I18n.t("Center") : I18n.t("Right"))
                            color: Theme.text; font.family: Theme.fontFamily; font.pixelSize: Theme.fontSize + 3; font.bold: true
                        }
                        IconButton { icon: Icons.close; onClicked: win.addTarget = "" }
                    }

                    // search
                    Rectangle {
                        Layout.fillWidth: true; Layout.preferredHeight: 36
                        radius: Theme.radius; color: Theme.surface0
                        border.width: modalSearch.activeFocus ? 1 : 0; border.color: Theme.accent
                        RowLayout {
                            anchors.fill: parent; anchors.leftMargin: 12; anchors.rightMargin: 10; spacing: 8
                            Text { text: Icons.search; color: Theme.subtext0; font.family: Theme.fontFamily; font.pixelSize: Theme.fontSize }
                            TextInput {
                                id: modalSearch
                                Layout.fillWidth: true; clip: true
                                color: Theme.text; font.family: Theme.fontFamily; font.pixelSize: Theme.fontSize
                                selectionColor: Theme.accent; verticalAlignment: TextInput.AlignVCenter
                                text: win.modalQuery
                                onTextChanged: win.modalQuery = text
                                Text { anchors.verticalCenter: parent.verticalCenter; visible: modalSearch.text === ""; text: I18n.t("Search widget…"); color: Theme.overlay1; font: modalSearch.font }
                            }
                        }
                    }

                    // catalog list
                    Flickable {
                        Layout.fillWidth: true; Layout.fillHeight: true
                        contentHeight: catCol.implicitHeight; clip: true
                        boundsBehavior: Flickable.StopAtBounds
                        ColumnLayout {
                            id: catCol
                            width: parent.width
                            spacing: 6
                            Repeater {
                                model: win.catalogMatches()
                                delegate: Rectangle {
                                    id: catRow
                                    required property var modelData
                                    Layout.fillWidth: true
                                    Layout.preferredHeight: 52
                                    radius: Theme.radius; color: Theme.surface0
                                    RowLayout {
                                        anchors.fill: parent; anchors.leftMargin: 12; anchors.rightMargin: 10; spacing: 12
                                        Rectangle {
                                            Layout.preferredWidth: 32; Layout.preferredHeight: 32; radius: 8; color: Theme.surface2
                                            Text { anchors.centerIn: parent; text: catRow.modelData.icon; color: Theme.accent; font.family: Theme.fontFamily; font.pixelSize: Theme.fontSize + 1 }
                                        }
                                        ColumnLayout {
                                            Layout.fillWidth: true; spacing: 0
                                            Text { text: catRow.modelData.name; color: Theme.text; font.family: Theme.fontFamily; font.pixelSize: Theme.fontSize - 1; font.bold: true; elide: Text.ElideRight; Layout.fillWidth: true }
                                            Text { text: catRow.modelData.desc; color: Theme.subtext0; font.family: Theme.fontFamily; font.pixelSize: Theme.fontSize - 4; elide: Text.ElideRight; Layout.fillWidth: true }
                                        }
                                        Rectangle {
                                            Layout.preferredWidth: 30; Layout.preferredHeight: 30; radius: 15
                                            color: addBtnMa.containsMouse ? Theme.accent2 : Theme.accent
                                            Text { anchors.centerIn: parent; text: Icons.plus; color: Theme.onAccent; font.family: Theme.fontFamily; font.pixelSize: Theme.fontSize }
                                            MouseArea {
                                                id: addBtnMa; anchors.fill: parent; hoverEnabled: true; cursorShape: Qt.PointingHandCursor
                                                onClicked: WidgetRegistry.addWidget(win.addTarget, catRow.modelData.type)
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

        // ---------------- page components ----------------
        Component { id: cmpTheme; ThemeSwitcher {} }
        Component { id: cmpKeys;  KeybindEditor {} }

        // ======================= BAR SETTINGS PAGE =======================
        Component {
            id: cmpBarSettings
            Flickable {
                contentHeight: bsCol.implicitHeight
                clip: true
                boundsBehavior: Flickable.StopAtBounds
                ColumnLayout {
                    id: bsCol
                    width: parent.width
                    spacing: 10

                    // ---- Position ----
                    SsSeg { label: I18n.t("Position"); k: "position"; def: "top"
                        options: [ { v: "top", l: I18n.t("Up") }, { v: "bottom", l: I18n.t("Down") },
                                   { v: "left", l: I18n.t("Left") }, { v: "right", l: I18n.t("Right") } ] }

                    // ---- Assigned screens ----
                    SsHeader { text: I18n.t("Assigned display") }
                    Text {
                        Layout.fillWidth: true; wrapMode: Text.WordWrap
                        text: I18n.t("No selection = all displays.")
                        color: Theme.subtext0; font.family: Theme.fontFamily; font.pixelSize: Theme.fontSize - 3
                    }
                    Flow {
                        Layout.fillWidth: true; spacing: 6
                        Repeater {
                            model: win.monitors
                            delegate: Rectangle {
                                required property var modelData
                                readonly property var scr: Config.get("bar", "screens", [])
                                readonly property bool on: scr.indexOf(modelData) !== -1
                                width: mTxt.implicitWidth + 24; height: 32; radius: Theme.radius
                                color: on ? Theme.accent : Theme.surface0
                                border.width: on ? 0 : 1; border.color: Theme.surface2
                                Text { id: mTxt; anchors.centerIn: parent; text: modelData; color: parent.on ? Theme.onAccent : Theme.text; font.family: Theme.fontFamily; font.pixelSize: Theme.fontSize - 2 }
                                MouseArea {
                                    anchors.fill: parent; cursorShape: Qt.PointingHandCursor
                                    onClicked: {
                                        var a = Config.get("bar", "screens", []).slice();
                                        var i = a.indexOf(modelData);
                                        if (i === -1) a.push(modelData); else a.splice(i, 1);
                                        Config.set("bar", "screens", a);
                                    }
                                }
                            }
                        }
                    }

                    // ---- Visibility ----
                    SsHeader { text: I18n.t("Visibility") }
                    SsToggle { label: I18n.t("Auto-hide"); k: "autoHide"; def: false }
                    SsToggle { label: I18n.t("Exclusive zone (reserve space)"); k: "exclusiveZone"; def: true }
                    SsToggle { label: I18n.t("Maximize detection (flush bar)"); k: "maximizeDetect"; def: false }

                    // ---- Spacing ----
                    SsHeader { text: I18n.t("Space") }
                    SsSlider { label: I18n.t("Edge spacing"); k: "edgeGap"; min: 0; max: 24; def: 6; step: 1; suffix: " px" }
                    SsSlider { label: I18n.t("Bar size"); k: "barSize"; min: 24; max: 64; def: 38; step: 1; suffix: " px" }
                    SsSlider { label: I18n.t("Inner padding"); k: "padding"; min: 2; max: 24; def: 8; step: 1; suffix: " px"; showReset: true; resetTo: 8 }
                    SsSlider { label: I18n.t("Side margin"); k: "marginSides"; min: 0; max: 32; def: 8; step: 1; suffix: " px" }

                    // ---- Background layer (behind the widget pills) ----
                    SsHeader { text: I18n.t("Bar background layer") }
                    // def 1.0 = mismo fallback que usa la barra al pintar; con
                    // def 0.0 el slider mostraba un valor que no era el real
                    SsSlider { label: I18n.t("Background opacity"); k: "bgOpacity"; min: 0.0; max: 1.0; def: 1.0; step: 0.02 }
                    // (el toggle "Background blur"/bar.bgBlur se retiró: duplicaba
                    // "Bar blur"/appearance.barBlur, que es el que aplica el bridge)
                    SsSlider { label: I18n.t("Spacing between pills"); k: "pillGap"; min: 0; max: 20; def: 4; step: 1; suffix: " px" }

                    // ---- Transparency ----
                    SsHeader { text: I18n.t("Transparency") }
                    SsSlider { label: I18n.t("Widget transparency"); k: "widgetTransparency"; min: 0.2; max: 1.0; def: 1.0; step: 0.02 }

                    // ---- Scale ----
                    SsHeader { text: I18n.t("Scale") }
                    SsSlider { label: I18n.t("Typography size"); k: "fontScale"; min: 0.7; max: 1.5; def: 1.0; step: 0.05 }
                    SsSlider { label: I18n.t("Icon scale"); k: "iconScale"; min: 0.7; max: 1.6; def: 1.0; step: 0.05 }

                    // ---- Corners & background ----
                    SsHeader { text: I18n.t("Corners and background") }
                    SsSlider { label: I18n.t("Corner radius"); k: "cornerRadius"; min: 0; max: 24; def: 12; step: 1; suffix: " px" }
                    SsSeg { label: I18n.t("Background style"); k: "backgroundStyle"; def: "solid"
                        options: [ { v: "solid", l: I18n.t("Solid") }, { v: "transparent", l: I18n.t("Transparent") } ] }

                    // ---- Tray tint ----
                    SsHeader { text: I18n.t("Tray icon tint") }
                    SsSeg { k: "trayTint"; def: "none"
                        options: [ { v: "none", l: I18n.t("None") }, { v: "mono", l: I18n.t("Monochrome") },
                                   { v: "primary", l: I18n.t("Primary") }, { v: "secondary", l: I18n.t("Secondary") } ] }

                    // ---- Borders / outline / shadow ----
                    SsHeader { text: I18n.t("Border, outline and shadow") }
                    SsToggle { label: I18n.t("Bar border"); k: "border"; def: false }
                    SsToggle { label: I18n.t("Outline on widgets"); k: "widgetOutline"; def: false }
                    SsSeg { label: I18n.t("Shadow"); k: "shadow"; def: "none"
                        options: [ { v: "none", l: I18n.t("None") }, { v: "subtle", l: I18n.t("Subtle") }, { v: "strong", l: I18n.t("Strong") } ] }

                    // ---- Scroll wheel ----
                    SsHeader { text: I18n.t("Scroll wheel") }
                    SsToggle { label: I18n.t("Scroll to switch workspace"); k: "scrollWheel"; def: true }
                    SsSeg { label: I18n.t("Scroll axis"); k: "scrollAxis"; def: "workspace"
                        options: [ { v: "none", l: I18n.t("None") }, { v: "workspace", l: I18n.t("Workspace") } ] }

                    Item { Layout.preferredHeight: 8 }
                }
            }
        }

        // ==================== WIDGET MANAGER PAGE ====================
        Component {
            id: cmpWidgetManager
            Flickable {
                id: wmFlick
                // mientras se arrastra una fila, el scroll de la página se
                // desactiva para que el gesto vertical mueva la fila y no
                // haga scroll (la fuente real del "arrastre no va").
                property bool rowDragging: false
                interactive: !rowDragging
                contentHeight: wmCol.implicitHeight
                clip: true
                boundsBehavior: Flickable.StopAtBounds
                ColumnLayout {
                    id: wmCol
                    width: parent.width
                    spacing: 14

                    RowLayout {
                        Layout.fillWidth: true
                        Text {
                            Layout.fillWidth: true; wrapMode: Text.WordWrap
                            text: I18n.t("Drag the handle (⋮) to reorder. The gear configures each instance; the eye hides it; the X removes it. Check 2+ widgets (circle) and press «Group» to combine them into a pill.")
                            color: Theme.subtext0; font.family: Theme.fontFamily; font.pixelSize: Theme.fontSize - 1
                        }
                        Rectangle {
                            Layout.preferredWidth: rsRow.implicitWidth + 24; Layout.preferredHeight: 32
                            radius: Theme.radius; color: rsMa.containsMouse ? Theme.surface2 : Theme.surface0
                            border.width: 1; border.color: Theme.surface2
                            RowLayout { id: rsRow; anchors.centerIn: parent; spacing: 6
                                Text { text: Icons.refresh; color: Theme.subtext1; font.family: Theme.fontFamily; font.pixelSize: Theme.fontSize - 2 }
                                Text { text: I18n.t("Reset all"); color: Theme.text; font.family: Theme.fontFamily; font.pixelSize: Theme.fontSize - 2 }
                            }
                            MouseArea { id: rsMa; anchors.fill: parent; hoverEnabled: true; cursorShape: Qt.PointingHandCursor; onClicked: WidgetRegistry.resetAll() }
                        }
                    }

                    Repeater {
                        model: [ { s: "left", l: I18n.t("Left section") }, { s: "center", l: I18n.t("Center section") }, { s: "right", l: I18n.t("Right section") } ]
                        delegate: ColumnLayout {
                            id: secCol
                            required property var modelData
                            readonly property var list: WidgetRegistry.section(secCol.modelData.s)
                            // ---- estado de reordenación por arrastre + opciones inline ----
                            readonly property int pitch: 60          // 54 fila + 6 hueco
                            property string expandedId: ""
                            property real expandedExtra: 0
                            property int dragIdx: -1
                            property int dropIdx: -1
                            onExpandedIdChanged: if (expandedId === "") expandedExtra = 0
                            function idxOf(wid) {
                                for (var i = 0; i < secCol.list.length; i++)
                                    if (secCol.list[i].id === wid) return i;
                                return -1;
                            }
                            // y de reposo de la fila i (deja hueco bajo la fila expandida)
                            function slotY(i) {
                                var y = i * secCol.pitch;
                                if (secCol.expandedId !== "" && secCol.dragIdx < 0) {
                                    var ei = secCol.idxOf(secCol.expandedId);
                                    if (ei >= 0 && i > ei) y += secCol.expandedExtra;
                                }
                                return y;
                            }
                            // y visible durante un arrastre: las demás filas se apartan
                            // hacia el hueco de inserción (slots animados, como DMS)
                            function displayY(i) {
                                if (secCol.dragIdx < 0 || i === secCol.dragIdx) return secCol.slotY(i);
                                var vi = i < secCol.dragIdx ? i : i - 1;
                                if (vi >= secCol.dropIdx) vi += 1;
                                return vi * secCol.pitch;
                            }
                            Layout.fillWidth: true
                            spacing: 6

                            RowLayout {
                                Layout.fillWidth: true
                                Text { Layout.fillWidth: true; text: secCol.modelData.l; color: Theme.subtext1; font.family: Theme.fontFamily; font.pixelSize: Theme.fontSize; font.bold: true }
                                // Agrupar (visible con 2+ widgets seleccionados)
                                Rectangle {
                                    readonly property int n: win.wmSelected(secCol.modelData.s).length
                                    visible: n >= 2
                                    Layout.preferredWidth: grpRow.implicitWidth + 22; Layout.preferredHeight: 28
                                    radius: Theme.radius; color: grpMa.containsMouse ? Theme.accent2 : Theme.accent
                                    RowLayout { id: grpRow; anchors.centerIn: parent; spacing: 6
                                        Text { text: Icons.bars; color: Theme.onAccent; font.family: Theme.fontFamily; font.pixelSize: Theme.fontSize - 3 }
                                        Text { text: I18n.t("Group (") + parent.parent.n + ")"; color: Theme.onAccent; font.family: Theme.fontFamily; font.pixelSize: Theme.fontSize - 3; font.bold: true }
                                    }
                                    MouseArea { id: grpMa; anchors.fill: parent; hoverEnabled: true; cursorShape: Qt.PointingHandCursor; onClicked: win.wmGroup(secCol.modelData.s) }
                                }
                                IconButton { icon: Icons.refresh; iconSize: Theme.fontSize - 1; implicitWidth: 26; implicitHeight: 26; onClicked: { win.wmClearSel(secCol.modelData.s); WidgetRegistry.resetSection(secCol.modelData.s) } }
                            }

                            // ---- lista de filas con posicionamiento absoluto (drag DMS) ----
                            Item {
                                id: listBox
                                Layout.fillWidth: true
                                implicitHeight: secCol.list.length > 0
                                    ? secCol.list.length * secCol.pitch - 6 + (secCol.dragIdx < 0 ? secCol.expandedExtra : 0)
                                    : 0
                                Behavior on implicitHeight { NumberAnimation { duration: Theme.dur(160); easing.type: Theme.easing } }

                                Repeater {
                                    model: secCol.list
                                    delegate: Rectangle {
                                        id: rowItem
                                        required property var modelData
                                        required property int index
                                        readonly property string sect: secCol.modelData.s
                                        readonly property var m: WidgetRegistry.meta(rowItem.modelData.type)
                                        readonly property bool hidden: rowItem.modelData.hidden === true
                                        readonly property bool isGroup: rowItem.modelData.type === "group"
                                        readonly property bool selected: win.wmIsSel(rowItem.sect, rowItem.modelData.id)
                                        readonly property bool expanded: secCol.expandedId === rowItem.modelData.id
                                        readonly property bool dragging: secCol.dragIdx === rowItem.index
                                        readonly property bool hasOptions: ["applauncher", "clock", "spacer", "focusedwindow", "media", "group"].indexOf(rowItem.modelData.type) !== -1

                                        width: listBox.width
                                        height: 54 + (expanded && optLoader.item ? optLoader.item.implicitHeight + 14 : 0)
                                        onHeightChanged: if (expanded) secCol.expandedExtra = height - 54
                                        z: dragging ? 100 : 1
                                        clip: true
                                        radius: Theme.radius
                                        // "coger y arrastrar" visible: al PULSAR el asidero la fila ya
                                        // se levanta un poco (la coges); al arrastrar se eleva más y
                                        // proyecta sombra (va en tu mano, por encima del resto).
                                        scale: dragging ? 1.04 : (dragArea.pressed ? 1.015 : 1.0)
                                        layer.enabled: dragging
                                        layer.effect: MultiEffect {
                                            shadowEnabled: true
                                            shadowBlur: 0.9
                                            shadowColor: Qt.rgba(0, 0, 0, 0.45)
                                            shadowVerticalOffset: 6
                                        }
                                        color: rowItem.isGroup ? Qt.rgba(Theme.accent.r, Theme.accent.g, Theme.accent.b, 0.10)
                                               : rowItem.selected ? Theme.surface1 : Theme.surface0
                                        border.width: (rowItem.isGroup || rowItem.dragging) ? 1 : 0
                                        border.color: rowItem.dragging ? Theme.accent : Qt.rgba(Theme.accent.r, Theme.accent.g, Theme.accent.b, 0.4)
                                        opacity: rowItem.hidden ? 0.55 : 1.0

                                        Behavior on height { NumberAnimation { duration: Theme.dur(150); easing.type: Theme.easing } }
                                        Behavior on scale { NumberAnimation { duration: Theme.dur(120); easing.type: Theme.easing } }
                                        Behavior on y { enabled: !rowItem.dragging; NumberAnimation { duration: Theme.dur(160); easing.type: Theme.easing } }

                                        Binding {
                                            target: rowItem
                                            property: "y"
                                            value: secCol.displayY(rowItem.index)
                                            when: !rowItem.dragging
                                            restoreMode: Binding.RestoreNone
                                        }
                                        onYChanged: {
                                            if (rowItem.dragging)
                                                secCol.dropIdx = Math.max(0, Math.min(secCol.list.length - 1, Math.round(rowItem.y / secCol.pitch)));
                                        }

                                        RowLayout {
                                            anchors.top: parent.top
                                            anchors.left: parent.left
                                            anchors.right: parent.right
                                            anchors.leftMargin: 10; anchors.rightMargin: 8
                                            height: 54
                                            spacing: 10

                                            // círculo de selección (para agrupar) — solo hojas
                                            Rectangle {
                                                visible: !rowItem.isGroup
                                                Layout.preferredWidth: 20; Layout.preferredHeight: 20; radius: 10
                                                color: rowItem.selected ? Theme.accent : "transparent"
                                                border.width: 2; border.color: rowItem.selected ? Theme.accent : Theme.overlay1
                                                Text { anchors.centerIn: parent; visible: rowItem.selected; text: Icons.check; color: Theme.onAccent; font.family: Theme.fontFamily; font.pixelSize: Theme.fontSize - 5 }
                                                MouseArea { anchors.fill: parent; cursorShape: Qt.PointingHandCursor; onClicked: win.wmToggleSel(rowItem.sect, rowItem.modelData.id) }
                                            }
                                            Item { visible: rowItem.isGroup; Layout.preferredWidth: 20; Layout.preferredHeight: 20 }

                                            // asidero de arrastre: SOLO este agarre reordena (el resto de
                                            // la fila deja hacer scroll a la página). preventStealing +
                                            // wmFlick.rowDragging garantizan que el gesto no se lo lleve el
                                            // Flickable.
                                            MouseArea {
                                                id: dragArea
                                                Layout.preferredWidth: 24; Layout.fillHeight: true
                                                preventStealing: true
                                                cursorShape: (dragArea.pressed || rowItem.dragging) ? Qt.ClosedHandCursor : Qt.OpenHandCursor
                                                // Arrastre MANUAL en vez de MouseArea.drag: el drag de Qt sólo
                                                // arranca tras >=2 eventos de movimiento (el 1º fija la referencia
                                                // y el 2º mide el delta), así que un movimiento rápido de ratón
                                                // real —o el puntero absoluto de la VM— que llega como un ÚNICO
                                                // evento de gran delta NUNCA iniciaba el gesto. Aquí arrancamos en
                                                // el PRIMER onPositionChanged (cualquier delta) y movemos la fila a
                                                // mano, robusto ante cualquier patrón de eventos.
                                                property real grabY: 0     // puntero en coords de listBox al pulsar
                                                property real baseRowY: 0  // rowItem.y al pulsar
                                                onPressed: function(mouse) {
                                                    dragArea.grabY = dragArea.mapToItem(listBox, mouse.x, mouse.y).y;
                                                    dragArea.baseRowY = rowItem.y;
                                                }
                                                onPositionChanged: function(mouse) {
                                                    if (!wmFlick.rowDragging) {
                                                        // primer movimiento -> arranca el arrastre
                                                        secCol.expandedId = "";
                                                        secCol.dragIdx = rowItem.index;
                                                        secCol.dropIdx = rowItem.index;
                                                        wmFlick.rowDragging = true;
                                                    }
                                                    var curY = dragArea.mapToItem(listBox, mouse.x, mouse.y).y;
                                                    var ny = dragArea.baseRowY + (curY - dragArea.grabY);
                                                    rowItem.y = Math.max(-secCol.pitch / 2, Math.min(listBox.height, ny));
                                                    // onYChanged (arriba) recalcula secCol.dropIdx.
                                                }
                                                onReleased: {
                                                    if (!wmFlick.rowDragging) return;  // click sin mover
                                                    var from = secCol.dragIdx, to = secCol.dropIdx;
                                                    secCol.dragIdx = -1; secCol.dropIdx = -1;
                                                    wmFlick.rowDragging = false;
                                                    if (to >= 0 && to !== from)
                                                        WidgetRegistry.reorder(rowItem.sect, rowItem.modelData.id, to);
                                                }
                                                Text { anchors.centerIn: parent; text: Icons.dragHandle; color: rowItem.dragging ? Theme.accent : Theme.overlay1; font.family: Theme.fontFamily; font.pixelSize: Theme.fontSize }
                                            }

                                            // icono
                                            Rectangle {
                                                Layout.preferredWidth: 34; Layout.preferredHeight: 34; radius: 8
                                                color: Theme.surface2
                                                Text { anchors.centerIn: parent; text: rowItem.m.icon; color: Theme.accent; font.family: Theme.fontFamily; font.pixelSize: Theme.fontSize + 1 }
                                            }
                                            // nombre + descripción (los grupos resumen sus hijos)
                                            ColumnLayout {
                                                Layout.fillWidth: true; spacing: 0
                                                Text { text: rowItem.m.name; color: Theme.text; font.family: Theme.fontFamily; font.pixelSize: Theme.fontSize - 1; font.bold: true; elide: Text.ElideRight; Layout.fillWidth: true }
                                                Text {
                                                    text: rowItem.isGroup ? win.wmGroupSummary(rowItem.modelData) : rowItem.m.desc
                                                    color: rowItem.isGroup ? Theme.accent : Theme.subtext0
                                                    font.family: Theme.fontFamily; font.pixelSize: Theme.fontSize - 4; elide: Text.ElideRight; Layout.fillWidth: true
                                                }
                                            }
                                            // opciones por instancia (engranaje, patrón DMS more_vert)
                                            IconButton {
                                                visible: rowItem.hasOptions
                                                icon: Icons.gear
                                                iconColor: rowItem.expanded ? Theme.accent : Theme.subtext0
                                                iconSize: Theme.fontSize; implicitWidth: 30; implicitHeight: 30
                                                onClicked: secCol.expandedId = rowItem.expanded ? "" : rowItem.modelData.id
                                            }
                                            // desagrupar (solo grupos)
                                            IconButton {
                                                visible: rowItem.isGroup
                                                icon: Icons.arrowsH; iconColor: Theme.accent
                                                iconSize: Theme.fontSize; implicitWidth: 30; implicitHeight: 30
                                                onClicked: WidgetRegistry.ungroup(rowItem.sect, rowItem.modelData.id)
                                            }
                                            // ocultar/mostrar
                                            IconButton {
                                                icon: rowItem.hidden ? Icons.eyeSlash : Icons.eye
                                                iconColor: rowItem.hidden ? Theme.overlay2 : Theme.text
                                                iconSize: Theme.fontSize; implicitWidth: 30; implicitHeight: 30
                                                onClicked: WidgetRegistry.toggleHidden(rowItem.sect, rowItem.modelData.id)
                                            }
                                            // eliminar
                                            IconButton {
                                                icon: Icons.close; iconColor: Theme.subtext0; hoverColor: Qt.rgba(Theme.red.r, Theme.red.g, Theme.red.b, 0.25)
                                                iconSize: Theme.fontSize; implicitWidth: 30; implicitHeight: 30
                                                onClicked: WidgetRegistry.removeWidget(rowItem.sect, rowItem.modelData.id)
                                            }
                                        }

                                        // ---- área de opciones expandida ----
                                        Loader {
                                            id: optLoader
                                            active: rowItem.expanded
                                            visible: active
                                            anchors.top: parent.top; anchors.topMargin: 54
                                            anchors.left: parent.left; anchors.right: parent.right
                                            anchors.leftMargin: 74; anchors.rightMargin: 16
                                            sourceComponent: {
                                                switch (rowItem.modelData.type) {
                                                case "applauncher":   return oApplauncher;
                                                case "clock":         return oClock;
                                                case "spacer":        return oSpacer;
                                                case "focusedwindow": return oFocused;
                                                case "media":         return oMedia;
                                                case "group":         return oGroup;
                                                default:              return null;
                                                }
                                            }
                                        }

                                        Component { id: oApplauncher
                                            ColumnLayout {
                                                anchors.left: parent ? parent.left : undefined
                                                anchors.right: parent ? parent.right : undefined
                                                spacing: 6
                                                readonly property string curIcon: rowItem.modelData.icon !== undefined ? rowItem.modelData.icon : "grid"
                                                Text {
                                                    text: I18n.t("Pill icon")
                                                    color: Theme.subtext1; font.family: Theme.fontFamily; font.pixelSize: Theme.fontSize - 2
                                                }
                                                Flow {
                                                    Layout.fillWidth: true
                                                    spacing: 8
                                                    Repeater {
                                                        model: WidgetRegistry.launcherIconChoices
                                                        delegate: Rectangle {
                                                            required property var modelData
                                                            readonly property bool sel: modelData.key === curIcon
                                                            width: 40; height: 40; radius: Theme.radius
                                                            color: sel ? Theme.accent : (chipMa.containsMouse ? Theme.surface2 : Theme.surface0)
                                                            border.width: 1
                                                            border.color: sel ? Theme.accent : Theme.surface2
                                                            LauncherIcon {
                                                                anchors.centerIn: parent
                                                                iconKey: modelData.key
                                                                pixel: Theme.fontSize + 3
                                                                tint: sel ? Theme.onAccent : Theme.text
                                                            }
                                                            MouseArea {
                                                                id: chipMa
                                                                anchors.fill: parent; hoverEnabled: true; cursorShape: Qt.PointingHandCursor
                                                                onClicked: WidgetRegistry.setProp(rowItem.sect, rowItem.modelData.id, "icon", modelData.key)
                                                            }
                                                        }
                                                    }
                                                }
                                            }
                                        }
                                        Component { id: oClock
                                            ColumnLayout {
                                                anchors.left: parent ? parent.left : undefined
                                                anchors.right: parent ? parent.right : undefined
                                                spacing: 4
                                                WmToggle {
                                                    label: I18n.t("Show date")
                                                    checked: rowItem.modelData.showDate !== undefined ? rowItem.modelData.showDate : true
                                                    onEdited: function(v) { WidgetRegistry.setProp(rowItem.sect, rowItem.modelData.id, "showDate", v) }
                                                }
                                                WmToggle {
                                                    label: I18n.t("Show seconds")
                                                    checked: rowItem.modelData.showSeconds === true
                                                    onEdited: function(v) { WidgetRegistry.setProp(rowItem.sect, rowItem.modelData.id, "showSeconds", v) }
                                                }
                                            }
                                        }
                                        Component { id: oSpacer
                                            ColumnLayout {
                                                anchors.left: parent ? parent.left : undefined
                                                anchors.right: parent ? parent.right : undefined
                                                WmSlider {
                                                    label: I18n.t("Width")
                                                    min: 4; max: 160; step: 2
                                                    value: rowItem.modelData.width !== undefined ? rowItem.modelData.width : 24
                                                    onEdited: function(v) { WidgetRegistry.setProp(rowItem.sect, rowItem.modelData.id, "width", v) }
                                                }
                                            }
                                        }
                                        Component { id: oFocused
                                            ColumnLayout {
                                                anchors.left: parent ? parent.left : undefined
                                                anchors.right: parent ? parent.right : undefined
                                                WmSlider {
                                                    label: I18n.t("Max title width")
                                                    min: 100; max: 600; step: 10
                                                    value: rowItem.modelData.maxWidth !== undefined ? rowItem.modelData.maxWidth : 260
                                                    onEdited: function(v) { WidgetRegistry.setProp(rowItem.sect, rowItem.modelData.id, "maxWidth", v) }
                                                }
                                            }
                                        }
                                        Component { id: oMedia
                                            ColumnLayout {
                                                anchors.left: parent ? parent.left : undefined
                                                anchors.right: parent ? parent.right : undefined
                                                WmToggle {
                                                    label: I18n.t("Show track title")
                                                    checked: rowItem.modelData.showLabel !== undefined ? rowItem.modelData.showLabel : true
                                                    onEdited: function(v) { WidgetRegistry.setProp(rowItem.sect, rowItem.modelData.id, "showLabel", v) }
                                                }
                                            }
                                        }
                                        Component { id: oGroup
                                            ColumnLayout {
                                                anchors.left: parent ? parent.left : undefined
                                                anchors.right: parent ? parent.right : undefined
                                                WmSlider {
                                                    label: I18n.t("Group inner spacing")
                                                    min: 0; max: 24; step: 1
                                                    value: rowItem.modelData.groupGap !== undefined ? rowItem.modelData.groupGap : 8
                                                    onEdited: function(v) { WidgetRegistry.setProp(rowItem.sect, rowItem.modelData.id, "groupGap", v) }
                                                }
                                            }
                                        }
                                    }
                                }
                            }

                            // botón añadir widget
                            Rectangle {
                                Layout.fillWidth: true; Layout.preferredHeight: 40
                                radius: Theme.radius
                                color: addMa.containsMouse ? Theme.surface1 : "transparent"
                                border.width: 1; border.color: Theme.surface2
                                RowLayout { anchors.centerIn: parent; spacing: 8
                                    Text { text: Icons.plus; color: Theme.accent; font.family: Theme.fontFamily; font.pixelSize: Theme.fontSize }
                                    Text { text: I18n.t("Add widget"); color: Theme.text; font.family: Theme.fontFamily; font.pixelSize: Theme.fontSize - 1 }
                                }
                                MouseArea { id: addMa; anchors.fill: parent; hoverEnabled: true; cursorShape: Qt.PointingHandCursor; onClicked: win.addTarget = secCol.modelData.s }
                            }
                        }
                    }
                    Item { Layout.preferredHeight: 8 }
                }
            }
        }

        // ==================== WORKSPACE SETTINGS PAGE ====================
        Component {
            id: cmpWorkspaces
            Flickable {
                contentHeight: wsCol.implicitHeight
                clip: true
                boundsBehavior: Flickable.StopAtBounds
                ColumnLayout {
                    id: wsCol
                    width: parent.width
                    spacing: 10

                    SsHeader { text: I18n.t("Behavior") }
                    SsToggle { label: I18n.t("Numbered workspaces"); sect: "workspaces"; k: "numbered"; def: true }
                    SsToggle { label: I18n.t("Workspace names"); sect: "workspaces"; k: "showNames"; def: false }
                    SsToggle { label: I18n.t("Show applications in the workspace"); sect: "workspaces"; k: "showApps"; def: false }
                    SsToggle { label: I18n.t("Follow the monitor focus"); sect: "workspaces"; k: "followMonitor"; def: false }
                    SsToggle { label: I18n.t("Show only occupied workspaces"); sect: "workspaces"; k: "onlyOccupied"; def: true }
                    SsToggle { label: I18n.t("Invert scroll direction"); sect: "workspaces"; k: "invertScroll"; def: false }

                    SsHeader { text: I18n.t("Workspace margin") }
                    SsSlider { label: I18n.t("Show at least N workspaces"); sect: "workspaces"; k: "minCount"; min: 0; max: 10; def: 0; step: 1 }

                    SsHeader { text: I18n.t("Appearance") }
                    SsSeg { label: I18n.t("Focused color"); sect: "workspaces"; k: "focusedColor"; def: "primary"; options: win.roleOptions }
                    SsSeg { label: I18n.t("Occupied color"); sect: "workspaces"; k: "occupiedColor"; def: "surface"; options: win.roleOptions }
                    SsSeg { label: I18n.t("Unfocused color"); sect: "workspaces"; k: "unfocusedColor"; def: "none"; options: win.roleOptions }
                    SsSeg { label: I18n.t("Urgent color"); sect: "workspaces"; k: "urgentColor"; def: "error"; options: win.roleOptions }
                    SsToggle { label: I18n.t("Border on the focused workspace"); sect: "workspaces"; k: "focusedBorder"; def: false }

                    Item { Layout.preferredHeight: 8 }
                }
            }
        }

        // ---- Audio: output/input device selection + volume ----
        Component {
            id: cmpAudio
            Flickable {
                id: audioFlick
                contentHeight: auCol.implicitHeight
                clip: true
                boundsBehavior: Flickable.StopAtBounds

                property string defaultSink: ""
                property string defaultSource: ""
                ListModel { id: sinkModel }
                ListModel { id: sourceModel }

                function refresh() { audioLister.running = true; }
                Component.onCompleted: refresh()

                Process {
                    id: audioLister
                    command: ["bash", "-c",
                        "echo SINKDEF; pactl get-default-sink; " +
                        "echo SOURCEDEF; pactl get-default-source; " +
                        "echo SINKS; pactl -f json list sinks; " +
                        "echo SOURCES; pactl -f json list sources"]
                    stdout: StdioCollector {
                        onStreamFinished: {
                            var t = this.text;
                            function section(name, next) {
                                var a = t.indexOf(name + "\n");
                                if (a < 0) return "";
                                a += name.length + 1;
                                var b = next ? t.indexOf(next + "\n", a) : t.length;
                                return t.substring(a, b < 0 ? t.length : b);
                            }
                            audioFlick.defaultSink = section("SINKDEF", "SOURCEDEF").trim();
                            audioFlick.defaultSource = section("SOURCEDEF", "SINKS").trim();
                            sinkModel.clear(); sourceModel.clear();
                            function niceName(d, n) {
                                return (d && d !== "" && d !== "(null)") ? d : n;
                            }
                            try {
                                var sinks = JSON.parse(section("SINKS", "SOURCES"));
                                for (var i = 0; i < sinks.length; i++)
                                    sinkModel.append({ nm: sinks[i].name, desc: niceName(sinks[i].description, sinks[i].name) });
                            } catch (e) {}
                            try {
                                var srcs = JSON.parse(section("SOURCES", null));
                                for (var j = 0; j < srcs.length; j++) {
                                    if (srcs[j].name && srcs[j].name.indexOf(".monitor") !== -1) continue;
                                    sourceModel.append({ nm: srcs[j].name, desc: niceName(srcs[j].description, srcs[j].name) });
                                }
                            } catch (e2) {}
                        }
                    }
                }
                Process { id: setSink; onExited: audioFlick.refresh() }
                Process { id: setSource; onExited: audioFlick.refresh() }

                ColumnLayout {
                    id: auCol
                    width: parent.width
                    spacing: 16

                    // master output volume
                    ColumnLayout {
                        Layout.fillWidth: true
                        spacing: 6
                        RowLayout {
                            Layout.fillWidth: true
                            Text { text: I18n.t("Output volume"); color: Theme.text; font.family: Theme.fontFamily; font.pixelSize: Theme.fontSize; Layout.fillWidth: true }
                            Text { text: Audio.percent + "%"; color: Theme.subtext0; font.family: Theme.fontFamily; font.pixelSize: Theme.fontSize - 1 }
                        }
                        RowLayout {
                            Layout.fillWidth: true
                            spacing: 10
                            IconButton {
                                icon: Audio.muted ? Icons.volumeMute : Icons.volumeHigh
                                iconColor: Audio.muted ? Theme.overlay2 : Theme.text
                                onClicked: Audio.toggleMute()
                            }
                            Slider {
                                Layout.fillWidth: true
                                value: Audio.volume
                                onMoved: function(v) { Audio.setVolume(v) }
                            }
                        }
                    }

                    // output devices
                    Text { text: I18n.t("Output device"); color: Theme.subtext1; font.family: Theme.fontFamily; font.pixelSize: Theme.fontSize - 1; font.bold: true }
                    ColumnLayout {
                        Layout.fillWidth: true
                        spacing: 6
                        Repeater {
                            model: sinkModel
                            delegate: Rectangle {
                                required property var model
                                readonly property bool active: model.nm === audioFlick.defaultSink
                                Layout.fillWidth: true
                                Layout.preferredHeight: 46
                                radius: Theme.radius
                                color: active ? Qt.rgba(Theme.accent.r, Theme.accent.g, Theme.accent.b, 0.18) : Theme.surface0
                                border.width: active ? 1 : 0
                                border.color: Theme.accent
                                RowLayout {
                                    anchors.fill: parent; anchors.leftMargin: 14; anchors.rightMargin: 12; spacing: 10
                                    Text {
                                        text: active ? Icons.check : Icons.volumeHigh
                                        color: active ? Theme.accent : Theme.subtext0
                                        font.family: Theme.fontFamily; font.pixelSize: Theme.fontSize
                                        Layout.preferredWidth: 18
                                    }
                                    Text {
                                        Layout.fillWidth: true
                                        text: model.desc
                                        color: Theme.text
                                        font.family: Theme.fontFamily; font.pixelSize: Theme.fontSize - 1
                                        elide: Text.ElideRight
                                    }
                                }
                                MouseArea {
                                    anchors.fill: parent
                                    cursorShape: Qt.PointingHandCursor
                                    onClicked: { setSink.command = ["pactl", "set-default-sink", model.nm]; setSink.running = true; }
                                }
                            }
                        }
                    }

                    Rectangle { Layout.fillWidth: true; Layout.preferredHeight: 1; color: Theme.surface1 }

                    // mic volume
                    ColumnLayout {
                        Layout.fillWidth: true
                        spacing: 6
                        visible: Mic.present
                        RowLayout {
                            Layout.fillWidth: true
                            Text { text: I18n.t("Microphone volume"); color: Theme.text; font.family: Theme.fontFamily; font.pixelSize: Theme.fontSize; Layout.fillWidth: true }
                            Text { text: Mic.percent + "%"; color: Theme.subtext0; font.family: Theme.fontFamily; font.pixelSize: Theme.fontSize - 1 }
                        }
                        RowLayout {
                            Layout.fillWidth: true
                            spacing: 10
                            IconButton {
                                icon: Mic.muted ? Icons.micOff : Icons.microphone
                                iconColor: Mic.muted ? Theme.overlay2 : Theme.text
                                onClicked: Mic.toggleMute()
                            }
                            Slider {
                                Layout.fillWidth: true
                                value: Mic.volume
                                onMoved: function(v) { Mic.setVolume(v) }
                            }
                        }
                    }

                    // input devices
                    Text { visible: sourceModel.count > 0; text: I18n.t("Input device"); color: Theme.subtext1; font.family: Theme.fontFamily; font.pixelSize: Theme.fontSize - 1; font.bold: true }
                    ColumnLayout {
                        Layout.fillWidth: true
                        spacing: 6
                        Repeater {
                            model: sourceModel
                            delegate: Rectangle {
                                required property var model
                                readonly property bool active: model.nm === audioFlick.defaultSource
                                Layout.fillWidth: true
                                Layout.preferredHeight: 46
                                radius: Theme.radius
                                color: active ? Qt.rgba(Theme.accent.r, Theme.accent.g, Theme.accent.b, 0.18) : Theme.surface0
                                border.width: active ? 1 : 0
                                border.color: Theme.accent
                                RowLayout {
                                    anchors.fill: parent; anchors.leftMargin: 14; anchors.rightMargin: 12; spacing: 10
                                    Text {
                                        text: active ? Icons.check : Icons.microphone
                                        color: active ? Theme.accent : Theme.subtext0
                                        font.family: Theme.fontFamily; font.pixelSize: Theme.fontSize
                                        Layout.preferredWidth: 18
                                    }
                                    Text {
                                        Layout.fillWidth: true
                                        text: model.desc
                                        color: Theme.text
                                        font.family: Theme.fontFamily; font.pixelSize: Theme.fontSize - 1
                                        elide: Text.ElideRight
                                    }
                                }
                                MouseArea {
                                    anchors.fill: parent
                                    cursorShape: Qt.PointingHandCursor
                                    onClicked: { setSource.command = ["pactl", "set-default-source", model.nm]; setSource.running = true; }
                                }
                            }
                        }
                    }
                    Item { Layout.fillHeight: true }
                }
            }
        }

        // ---- Network: wifi toggle + AP list + ethernet status ----
        Component {
            id: cmpNetwork
            Flickable {
                id: netFlick
                contentHeight: netCol.implicitHeight
                clip: true
                boundsBehavior: Flickable.StopAtBounds

                property bool wifiOn: false
                property bool wifiHw: true
                property string ethLine: ""
                ListModel { id: apModel }

                function refresh() { netLister.running = true; }
                Component.onCompleted: refresh()

                Process {
                    id: netLister
                    command: ["bash", "-c",
                        "echo WIFI; nmcli -t -f WIFI radio 2>/dev/null; " +
                        "echo ETH; nmcli -t -f TYPE,STATE,CONNECTION device status 2>/dev/null | grep '^ethernet'; " +
                        "echo APS; nmcli -t -f IN-USE,SSID,SIGNAL,SECURITY device wifi list 2>/dev/null"]
                    stdout: StdioCollector {
                        onStreamFinished: {
                            var t = this.text;
                            function sec(n, nx) { var a=t.indexOf(n+"\n"); if(a<0)return ""; a+=n.length+1; var b=nx?t.indexOf(nx+"\n",a):t.length; return t.substring(a,b<0?t.length:b); }
                            netFlick.wifiOn = sec("WIFI","ETH").trim() === "enabled";
                            netFlick.ethLine = sec("ETH","APS").trim();
                            apModel.clear();
                            var lines = sec("APS", null).split("\n");
                            for (var i = 0; i < lines.length; i++) {
                                var l = lines[i].trim(); if (l === "") continue;
                                // fields colon-separated; SSID may contain escaped colons but keep simple
                                var parts = l.split(":");
                                var inUse = parts[0] === "*";
                                var ssid = parts[1] || "";
                                var sig = parts[2] || "0";
                                var sec2 = parts.slice(3).join(":") || "";
                                if (ssid === "") continue;
                                apModel.append({ ssid: ssid, sig: parseInt(sig) || 0, secure: sec2 !== "" && sec2 !== "--", inUse: inUse });
                            }
                        }
                    }
                }
                Process { id: wifiToggle; onExited: netFlick.refresh() }
                Process { id: wifiConnect; onExited: netFlick.refresh() }

                ColumnLayout {
                    id: netCol
                    width: parent.width
                    spacing: 14

                    // wifi master toggle
                    Rectangle {
                        Layout.fillWidth: true
                        Layout.preferredHeight: 48
                        radius: Theme.radius
                        color: Theme.surface0
                        RowLayout {
                            anchors.fill: parent; anchors.leftMargin: 14; anchors.rightMargin: 12; spacing: 10
                            Text { text: Icons.wifi; color: netFlick.wifiOn ? Theme.accent : Theme.subtext0; font.family: Theme.fontFamily; font.pixelSize: Theme.fontSize + 2; Layout.preferredWidth: 20 }
                            Text { Layout.fillWidth: true; text: "Wi-Fi"; color: Theme.text; font.family: Theme.fontFamily; font.pixelSize: Theme.fontSize }
                            Toggle {
                                checked: netFlick.wifiOn
                                onToggled: function(v) { wifiToggle.command = ["nmcli", "radio", "wifi", v ? "on" : "off"]; wifiToggle.running = true; }
                            }
                        }
                    }

                    // ethernet status
                    Rectangle {
                        Layout.fillWidth: true
                        Layout.preferredHeight: 48
                        radius: Theme.radius
                        color: Theme.surface0
                        RowLayout {
                            anchors.fill: parent; anchors.leftMargin: 14; anchors.rightMargin: 12; spacing: 10
                            Text { text: Icons.ethernet; color: Network.kind === "ethernet" ? Theme.accent : Theme.subtext0; font.family: Theme.fontFamily; font.pixelSize: Theme.fontSize + 2; Layout.preferredWidth: 20 }
                            Text { text: "Ethernet"; color: Theme.text; font.family: Theme.fontFamily; font.pixelSize: Theme.fontSize }
                            Item { Layout.fillWidth: true }
                            Text {
                                readonly property bool econn: netFlick.ethLine.indexOf(":connected:") !== -1 || netFlick.ethLine.indexOf("connected") !== -1
                                text: econn ? I18n.t("Connected") : I18n.t("Disconnected")
                                color: econn ? Theme.green : Theme.subtext0
                                font.family: Theme.fontFamily; font.pixelSize: Theme.fontSize - 1
                            }
                        }
                    }

                    RowLayout {
                        Layout.fillWidth: true
                        Text { Layout.fillWidth: true; text: I18n.t("Wi-Fi networks"); color: Theme.subtext1; font.family: Theme.fontFamily; font.pixelSize: Theme.fontSize - 1; font.bold: true }
                        IconButton { icon: Icons.refresh; onClicked: netFlick.refresh() }
                    }

                    Text {
                        visible: apModel.count === 0
                        Layout.fillWidth: true
                        text: netFlick.wifiOn ? I18n.t("Searching networks…") : I18n.t("Wi-Fi disabled or no adapter.")
                        color: Theme.subtext0
                        font.family: Theme.fontFamily; font.pixelSize: Theme.fontSize - 1
                    }

                    Repeater {
                        model: apModel
                        delegate: Rectangle {
                            required property var model
                            Layout.fillWidth: true
                            Layout.preferredHeight: 46
                            radius: Theme.radius
                            color: model.inUse ? Qt.rgba(Theme.accent.r, Theme.accent.g, Theme.accent.b, 0.18) : Theme.surface0
                            border.width: model.inUse ? 1 : 0
                            border.color: Theme.accent
                            RowLayout {
                                anchors.fill: parent; anchors.leftMargin: 14; anchors.rightMargin: 12; spacing: 10
                                Text {
                                    text: model.sig > 66 ? Icons.wifi : model.sig > 33 ? Icons.wifi : Icons.wifi
                                    color: model.inUse ? Theme.accent : Theme.subtext0
                                    font.family: Theme.fontFamily; font.pixelSize: Theme.fontSize; Layout.preferredWidth: 18
                                }
                                ColumnLayout {
                                    Layout.fillWidth: true
                                    spacing: 0
                                    Text { text: model.ssid; color: Theme.text; font.family: Theme.fontFamily; font.pixelSize: Theme.fontSize - 1; elide: Text.ElideRight; Layout.fillWidth: true }
                                    Text { text: (model.secure ? "Protegida · " : "Abierta · ") + model.sig + "%"; color: Theme.subtext0; font.family: Theme.fontFamily; font.pixelSize: Theme.fontSize - 4 }
                                }
                                Text { visible: model.secure; text: Icons.lock; color: Theme.overlay2; font.family: Theme.fontFamily; font.pixelSize: Theme.fontSize - 2 }
                            }
                            MouseArea {
                                anchors.fill: parent
                                enabled: !model.inUse
                                cursorShape: Qt.PointingHandCursor
                                onClicked: { wifiConnect.command = ["nmcli", "device", "wifi", "connect", model.ssid]; wifiConnect.running = true; }
                            }
                        }
                    }
                    Item { Layout.fillHeight: true }
                }
            }
        }

        // ==================== DISPLAYS / PANTALLAS PAGE ====================
        Component {
            id: cmpDisplays
            Flickable {
                id: dispFlick
                contentHeight: dispCol.implicitHeight
                clip: true
                boundsBehavior: Flickable.StopAtBounds
                Component.onCompleted: Displays.refresh()

                property bool creating: false

                // profile-name options for the dropdown
                function profileOpts() {
                    var ps = Displays.profiles(); var o = [];
                    for (var i = 0; i < ps.length; i++) o.push({ v: ps[i].name, l: ps[i].name });
                    if (o.length === 0) o.push({ v: "", l: I18n.t("(no profile)") });
                    return o;
                }

                ColumnLayout {
                    id: dispCol
                    width: parent.width
                    spacing: 12

                    // ===================== PROFILES =====================
                    SsHeader { text: I18n.t("Display profiles") }
                    RowLayout {
                        Layout.fillWidth: true
                        spacing: 8
                        DropSelect {
                            Layout.fillWidth: true
                            options: dispFlick.profileOpts()
                            current: Displays.activeName()
                            onPicked: function(v) { if (v !== "") Displays.setActive(v); }
                        }
                        IconButton {
                            icon: Icons.plus; iconSize: Theme.fontSize + 1; implicitWidth: 36; implicitHeight: 36
                            hoverColor: Theme.surface2
                            onClicked: { dispFlick.creating = true; newProfileInput.text = ""; newProfileInput.forceActiveFocus(); }
                        }
                        IconButton {
                            icon: Icons.trash; iconColor: Theme.subtext0
                            hoverColor: Qt.rgba(Theme.red.r, Theme.red.g, Theme.red.b, 0.25)
                            iconSize: Theme.fontSize + 1; implicitWidth: 36; implicitHeight: 36
                            enabled: Displays.activeName() !== ""
                            opacity: enabled ? 1 : 0.35
                            onClicked: Displays.deleteProfile(Displays.activeName())
                        }
                    }

                    // match indicator
                    RowLayout {
                        Layout.fillWidth: true
                        spacing: 6
                        readonly property string matched: Displays.matchedName()
                        Text {
                            text: parent.matched !== "" ? Icons.check : Icons.info
                            color: parent.matched !== "" ? Theme.green : Theme.subtext0
                            font.family: Theme.fontFamily; font.pixelSize: Theme.fontSize - 1
                        }
                        Text {
                            Layout.fillWidth: true
                            text: parent.matched !== "" ? (I18n.t("Matches profile: ") + parent.matched)
                                                        : I18n.t("The connected hardware doesn't match any saved profile.")
                            color: parent.matched !== "" ? Theme.green : Theme.subtext0
                            font.family: Theme.fontFamily; font.pixelSize: Theme.fontSize - 2
                            wrapMode: Text.WordWrap
                        }
                    }

                    // inline create form
                    Rectangle {
                        visible: dispFlick.creating
                        Layout.fillWidth: true
                        Layout.preferredHeight: 48
                        radius: Theme.radius
                        color: Theme.surface0
                        border.width: 1; border.color: Theme.surface2
                        RowLayout {
                            anchors.fill: parent; anchors.leftMargin: 12; anchors.rightMargin: 8; spacing: 8
                            TextInput {
                                id: newProfileInput
                                Layout.fillWidth: true; clip: true
                                color: Theme.text; font.family: Theme.fontFamily; font.pixelSize: Theme.fontSize
                                selectionColor: Theme.accent; verticalAlignment: TextInput.AlignVCenter
                                onAccepted: if (text.trim() !== "") { Displays.createProfile(text.trim()); dispFlick.creating = false; }
                                Text { anchors.verticalCenter: parent.verticalCenter; visible: newProfileInput.text === ""; text: I18n.t("New profile name…"); color: Theme.overlay1; font: newProfileInput.font }
                            }
                            Rectangle {
                                Layout.preferredWidth: 74; Layout.preferredHeight: 30; radius: Theme.radius
                                color: saveMa.containsMouse ? Theme.accent2 : Theme.accent
                                Text { anchors.centerIn: parent; text: I18n.t("Save"); color: Theme.onAccent; font.family: Theme.fontFamily; font.pixelSize: Theme.fontSize - 2; font.bold: true }
                                MouseArea { id: saveMa; anchors.fill: parent; hoverEnabled: true; cursorShape: Qt.PointingHandCursor
                                    onClicked: if (newProfileInput.text.trim() !== "") { Displays.createProfile(newProfileInput.text.trim()); dispFlick.creating = false; } }
                            }
                            IconButton { icon: Icons.close; onClicked: dispFlick.creating = false }
                        }
                    }

                    // ===================== TOOLBAR =====================
                    RowLayout {
                        Layout.fillWidth: true
                        Layout.topMargin: 4
                        spacing: 10
                        // Snap toggle
                        RowLayout {
                            spacing: 6
                            Text { text: I18n.t("Snap edges"); color: Theme.text; font.family: Theme.fontFamily; font.pixelSize: Theme.fontSize - 1 }
                            Toggle { checked: Config.get("displays", "snap", true); onToggled: function(v) { Config.set("displays", "snap", v); } }
                        }
                        Item { Layout.fillWidth: true }
                        // format toggle Name/Model
                        Text { text: I18n.t("Format:"); color: Theme.subtext1; font.family: Theme.fontFamily; font.pixelSize: Theme.fontSize - 2 }
                        Repeater {
                            model: [ { v: false, l: I18n.t("Name") }, { v: true, l: I18n.t("Model") } ]
                            delegate: Rectangle {
                                required property var modelData
                                readonly property bool sel: Config.get("displays", "formatByModel", false) === modelData.v
                                width: fmtTxt.implicitWidth + 20; height: 30; radius: Theme.radius
                                color: sel ? Theme.accent : (fmtMa.containsMouse ? Theme.surface2 : Theme.surface0)
                                border.width: sel ? 0 : 1; border.color: Theme.surface2
                                Text { id: fmtTxt; anchors.centerIn: parent; text: modelData.l; color: parent.sel ? Theme.onAccent : Theme.text; font.family: Theme.fontFamily; font.pixelSize: Theme.fontSize - 2 }
                                MouseArea { id: fmtMa; anchors.fill: parent; hoverEnabled: true; cursorShape: Qt.PointingHandCursor; onClicked: Config.set("displays", "formatByModel", modelData.v) }
                            }
                        }
                    }

                    // ===================== ARRANGEMENT CANVAS =====================
                    SsHeader { text: I18n.t("Arrangement") }
                    Rectangle {
                        id: canvas
                        Layout.fillWidth: true
                        Layout.preferredHeight: 220
                        radius: Theme.radius + 2
                        color: Theme.surface0
                        border.width: 1; border.color: Theme.surface2
                        clip: true

                        readonly property var mons: Displays.monitors
                        readonly property int pad: 16
                        // `hyprctl monitors -j` da width/height del MODO del panel, SIN
                        // aplicar la rotación: un monitor a 90°/270° sigue diciendo
                        // 1920x1080 aunque ocupe 1080x1920 en el escritorio (medido en
                        // la torre: DP-2 transform=3 -> hyprctl 1920x1080, superficie
                        // real 1080x1920). Por eso el rectángulo salía tumbado y el
                        // arrastre/imán calculaba con la huella equivocada. Los
                        // transforms IMPARES (1=90°, 3=270°, 5/7 sus volteados)
                        // intercambian los ejes; los pares (0/2/4/6) no.
                        function rotated(name) {
                            var c = Displays.monCfg(name);
                            return ((c ? (c.transform || 0) : 0) % 2) === 1;
                        }
                        function lw(m) { return Math.max(1, Math.round((rotated(m.name) ? m.height : m.width) / m.scale)); }
                        function lh(m) { return Math.max(1, Math.round((rotated(m.name) ? m.width : m.height) / m.scale)); }
                        function px(name) { var c = Displays.monCfg(name); return c ? (c.x || 0) : 0; }
                        function py(name) { var c = Displays.monCfg(name); return c ? (c.y || 0) : 0; }
                        readonly property real minX: {
                            var v = 0, first = true;
                            for (var i = 0; i < mons.length; i++) { var x = px(mons[i].name); if (first || x < v) { v = x; first = false; } }
                            return first ? 0 : v;
                        }
                        readonly property real minY: {
                            var v = 0, first = true;
                            for (var i = 0; i < mons.length; i++) { var y = py(mons[i].name); if (first || y < v) { v = y; first = false; } }
                            return first ? 0 : v;
                        }
                        readonly property real spanW: {
                            var mx = 1;
                            for (var i = 0; i < mons.length; i++) { var e = px(mons[i].name) + lw(mons[i]) - minX; if (e > mx) mx = e; }
                            return mx;
                        }
                        readonly property real spanH: {
                            var mx = 1;
                            for (var i = 0; i < mons.length; i++) { var e = py(mons[i].name) + lh(mons[i]) - minY; if (e > mx) mx = e; }
                            return mx;
                        }
                        readonly property real k: Math.min((width - pad * 2) / spanW, (height - pad * 2) / spanH, 0.22)

                        Text {
                            anchors.centerIn: parent
                            visible: canvas.mons.length === 0
                            text: I18n.t("Detecting monitors…")
                            color: Theme.subtext0; font.family: Theme.fontFamily; font.pixelSize: Theme.fontSize - 1
                        }

                        Repeater {
                            model: canvas.mons
                            delegate: Rectangle {
                                id: box
                                required property var modelData
                                readonly property real lwv: canvas.lw(modelData)
                                readonly property real lhv: canvas.lh(modelData)
                                property real lx: canvas.px(modelData.name)
                                property real ly: canvas.py(modelData.name)
                                width: Math.max(28, lwv * canvas.k)
                                height: Math.max(20, lhv * canvas.k)
                                x: canvas.pad + (lx - canvas.minX) * canvas.k
                                y: canvas.pad + (ly - canvas.minY) * canvas.k
                                radius: 6
                                color: modelData.name === Displays.activeName() ? Theme.surface2 : Theme.surface1
                                border.width: 2
                                border.color: dragMa.drag.active ? Theme.accent2 : Theme.accent

                                ColumnLayout {
                                    anchors.centerIn: parent
                                    spacing: 0
                                    Text {
                                        Layout.alignment: Qt.AlignHCenter
                                        text: Displays.displayLabel(box.modelData)
                                        color: Theme.text; font.family: Theme.fontFamily; font.pixelSize: Theme.fontSize - 2; font.bold: true
                                    }
                                    Text {
                                        Layout.alignment: Qt.AlignHCenter
                                        // la resolución tal y como se ve en pantalla: girada
                                        // si el monitor lo está (si no, el rótulo diría
                                        // 1920×1080 dentro de una caja alta y estrecha)
                                        text: canvas.rotated(box.modelData.name)
                                            ? (box.modelData.height + "×" + box.modelData.width)
                                            : (box.modelData.width + "×" + box.modelData.height)
                                        color: Theme.subtext0; font.family: Theme.fontFamily; font.pixelSize: Theme.fontSize - 4
                                    }
                                }

                                MouseArea {
                                    id: dragMa
                                    anchors.fill: parent
                                    cursorShape: Qt.SizeAllCursor
                                    drag.target: box
                                    drag.axis: Drag.XAndYAxis
                                    onReleased: {
                                        // px -> logical coords
                                        var nx = canvas.minX + (box.x - canvas.pad) / canvas.k;
                                        var ny = canvas.minY + (box.y - canvas.pad) / canvas.k;
                                        // snap edges to other monitors (logical units)
                                        if (Config.get("displays", "snap", true)) {
                                            var thr = 60;
                                            for (var i = 0; i < canvas.mons.length; i++) {
                                                var o = canvas.mons[i]; if (o.name === box.modelData.name) continue;
                                                var ox = canvas.px(o.name), oy = canvas.py(o.name);
                                                var ow = canvas.lw(o), oh = canvas.lh(o);
                                                if (Math.abs(nx - (ox + ow)) < thr) nx = ox + ow;       // attach right
                                                else if (Math.abs((nx + box.lwv) - ox) < thr) nx = ox - box.lwv; // attach left
                                                if (Math.abs(ny - oy) < thr) ny = oy;                   // top-align
                                                else if (Math.abs(ny - (oy + oh)) < thr) ny = oy + oh;  // attach below
                                                else if (Math.abs((ny + box.lhv) - oh - oy) < thr) ny = oy + oh - box.lhv;
                                            }
                                        }
                                        nx = Math.round(nx); ny = Math.round(ny);
                                        Displays.setMonitorFields(box.modelData.name, { x: nx, y: ny });
                                        // restore position bindings (drag broke box.x/y)
                                        box.x = Qt.binding(function() { return canvas.pad + (box.lx - canvas.minX) * canvas.k; });
                                        box.y = Qt.binding(function() { return canvas.pad + (box.ly - canvas.minY) * canvas.k; });
                                    }
                                }
                            }
                        }
                    }
                    Text {
                        Layout.fillWidth: true
                        text: I18n.t("Drag the monitors to set their relative position.")
                        color: Theme.subtext0; font.family: Theme.fontFamily; font.pixelSize: Theme.fontSize - 3
                        wrapMode: Text.WordWrap
                    }

                    // ===================== PER-MONITOR CARDS =====================
                    SsHeader { text: I18n.t("Monitors") }
                    Repeater {
                        model: Displays.monitors
                        delegate: Rectangle {
                            id: monCard
                            required property var modelData
                            readonly property var c: Displays.monCfg(modelData.name) || ({})
                            property bool expanded: false
                            property bool compExpanded: false
                            Layout.fillWidth: true
                            Layout.preferredHeight: cardCol.implicitHeight + 24
                            radius: Theme.radius + 2
                            color: Theme.surface0
                            border.width: 1; border.color: Theme.surface2

                            function modeOpts() {
                                var o = []; var ms = monCard.modelData.modes;
                                for (var i = 0; i < ms.length; i++) o.push({ v: ms[i].res + "@" + ms[i].refresh, l: ms[i].label });
                                return o;
                            }

                            ColumnLayout {
                                id: cardCol
                                anchors.fill: parent
                                anchors.margins: 12
                                spacing: 10

                                // header
                                RowLayout {
                                    Layout.fillWidth: true
                                    spacing: 10
                                    Text { text: Icons.desktop; color: Theme.accent; font.family: Theme.fontFamily; font.pixelSize: Theme.fontSize + 4 }
                                    ColumnLayout {
                                        Layout.fillWidth: true; spacing: 0
                                        Text { text: Displays.displayLabel(monCard.modelData); color: Theme.text; font.family: Theme.fontFamily; font.pixelSize: Theme.fontSize + 1; font.bold: true }
                                        Text {
                                            text: (monCard.modelData.make !== "" ? monCard.modelData.make + " · " : "")
                                                  + monCard.c.resolution + "@" + monCard.c.refresh + " · " + monCard.c.scale + "×"
                                            color: Theme.subtext0; font.family: Theme.fontFamily; font.pixelSize: Theme.fontSize - 3
                                        }
                                    }
                                    // enable toggle
                                    Toggle {
                                        checked: monCard.c.enabled !== false
                                        onToggled: function(v) { Displays.setMonitorField(monCard.modelData.name, "enabled", v); }
                                    }
                                    IconButton {
                                        icon: monCard.expanded ? Icons.chevronDown : Icons.chevronRight
                                        iconSize: Theme.fontSize; implicitWidth: 30; implicitHeight: 30
                                        onClicked: monCard.expanded = !monCard.expanded
                                    }
                                }

                                // expanded controls
                                ColumnLayout {
                                    Layout.fillWidth: true
                                    visible: monCard.expanded
                                    enabled: monCard.c.enabled !== false
                                    opacity: enabled ? 1 : 0.4
                                    spacing: 10

                                    DropSelect {
                                        label: I18n.t("Resolution and refresh")
                                        options: monCard.modeOpts()
                                        current: monCard.c.resolution + "@" + monCard.c.refresh
                                        onPicked: function(v) {
                                            var p = v.split("@");
                                            Displays.setMonitorFields(monCard.modelData.name, { resolution: p[0], refresh: Number(p[1]) });
                                        }
                                    }
                                    RowLayout {
                                        Layout.fillWidth: true; spacing: 10
                                        DropSelect {
                                            Layout.fillWidth: true
                                            label: I18n.t("Scale")
                                            options: Displays.scalePresets
                                            current: monCard.c.scale
                                            onPicked: function(v) { Displays.setMonitorField(monCard.modelData.name, "scale", v); }
                                        }
                                        DropSelect {
                                            Layout.fillWidth: true
                                            label: I18n.t("Transform")
                                            options: Displays.transforms
                                            current: monCard.c.transform || 0
                                            onPicked: function(v) { Displays.setMonitorField(monCard.modelData.name, "transform", v); }
                                        }
                                    }
                                    DropSelect {
                                        label: I18n.t("Variable refresh rate (VRR)")
                                        options: Displays.vrrModes
                                        current: monCard.c.vrr || 0
                                        onPicked: function(v) { Displays.setMonitorField(monCard.modelData.name, "vrr", v); }
                                    }

                                    // Workspace "de casa" de este monitor. Se guarda
                                    // por descripción EDID (no por conector), así que
                                    // sigue al monitor aunque cambie de puerto.
                                    DropSelect {
                                        label: I18n.t("Default workspace")
                                        options: Displays.workspaceOptions()
                                        current: Displays.defaultWorkspaceFor(monCard.modelData)
                                        onPicked: function(v) { Displays.setDefaultWorkspace(monCard.modelData, v); }
                                    }
                                    Text {
                                        Layout.fillWidth: true
                                        text: I18n.t("Assigning a number already used by another monitor moves it here.")
                                        color: Theme.subtext0
                                        font.family: Theme.fontFamily
                                        font.pixelSize: Theme.fontSize - 3
                                        wrapMode: Text.WordWrap
                                    }

                                    // compositor sub-section
                                    Rectangle {
                                        Layout.fillWidth: true
                                        Layout.preferredHeight: 34
                                        radius: Theme.radius
                                        color: compMa.containsMouse ? Theme.surface1 : "transparent"
                                        RowLayout {
                                            anchors.fill: parent; anchors.leftMargin: 4; anchors.rightMargin: 6; spacing: 8
                                            Text { text: monCard.compExpanded ? Icons.chevronDown : Icons.chevronRight; color: Theme.subtext0; font.family: Theme.fontFamily; font.pixelSize: Theme.fontSize - 3 }
                                            Text { Layout.fillWidth: true; text: I18n.t("Compositor settings"); color: Theme.subtext1; font.family: Theme.fontFamily; font.pixelSize: Theme.fontSize - 1; font.bold: true }
                                        }
                                        MouseArea { id: compMa; anchors.fill: parent; hoverEnabled: true; cursorShape: Qt.PointingHandCursor; onClicked: monCard.compExpanded = !monCard.compExpanded }
                                    }
                                    DropSelect {
                                        visible: monCard.compExpanded
                                        label: I18n.t("Color depth")
                                        options: Displays.bitdepths
                                        current: monCard.c.bitdepth || 8
                                        onPicked: function(v) { Displays.setMonitorField(monCard.modelData.name, "bitdepth", v); }
                                    }
                                }
                            }
                        }
                    }
                    Item { Layout.preferredHeight: 8 }
                }
            }
        }

        // ---- Theme Store: install curated community palettes ----
        Component {
            id: cmpStore
            ColumnLayout {
                spacing: 12

                Text {
                    Layout.fillWidth: true
                    wrapMode: Text.WordWrap
                    text: I18n.t("Install extra palettes from the catalog. Once installed they're added to the theme engine and appear in «Theme & colors».")
                    color: Theme.subtext0
                    font.family: Theme.fontFamily
                    font.pixelSize: Theme.fontSize - 1
                }

                Flickable {
                    Layout.fillWidth: true
                    Layout.fillHeight: true
                    contentHeight: storeGrid.implicitHeight
                    clip: true
                    boundsBehavior: Flickable.StopAtBounds

                    GridLayout {
                        id: storeGrid
                        width: parent.width
                        columns: 2
                        columnSpacing: 12
                        rowSpacing: 12

                        Repeater {
                            model: Theme.storeThemes
                            delegate: Rectangle {
                                required property var modelData
                                readonly property bool installed: Theme.isInstalled(modelData.id)
                                readonly property bool active: Theme.activeId === modelData.id
                                Layout.fillWidth: true
                                Layout.preferredHeight: 132
                                radius: Theme.radius + 2
                                color: Theme.surface0
                                border.width: active ? 2 : 1
                                border.color: active ? Theme.accent : Theme.surface2

                                ColumnLayout {
                                    anchors.fill: parent
                                    anchors.margins: 14
                                    spacing: 10

                                    RowLayout {
                                        Layout.fillWidth: true
                                        spacing: 6
                                        ColumnLayout {
                                            Layout.fillWidth: true
                                            spacing: 1
                                            Text {
                                                text: modelData.name
                                                color: Theme.text
                                                font.family: Theme.fontFamily
                                                font.pixelSize: Theme.fontSize + 1
                                                font.bold: true
                                                elide: Text.ElideRight
                                                Layout.fillWidth: true
                                            }
                                            Text {
                                                text: (modelData.author || "vexyon") + (modelData.dark === false ? " · claro" : " · oscuro")
                                                color: Theme.subtext0
                                                font.family: Theme.fontFamily
                                                font.pixelSize: Theme.fontSize - 3
                                                elide: Text.ElideRight
                                                Layout.fillWidth: true
                                            }
                                        }
                                        // remove (installed, non-active only)
                                        Rectangle {
                                            visible: parent.parent.parent.installed && !parent.parent.parent.active
                                            Layout.preferredWidth: 26; Layout.preferredHeight: 26
                                            radius: 13
                                            color: rmMa.containsMouse ? Theme.red : "transparent"
                                            Text {
                                                anchors.centerIn: parent
                                                text: Icons.trash
                                                color: rmMa.containsMouse ? Theme.onAccent : Theme.subtext0
                                                font.family: Theme.fontFamily
                                                font.pixelSize: Theme.fontSize - 1
                                            }
                                            MouseArea {
                                                id: rmMa
                                                anchors.fill: parent
                                                hoverEnabled: true
                                                cursorShape: Qt.PointingHandCursor
                                                onClicked: Theme.removeTheme(modelData.id)
                                            }
                                        }
                                    }

                                    // swatch preview
                                    RowLayout {
                                        Layout.fillWidth: true
                                        spacing: 6
                                        Repeater {
                                            model: [ modelData.colors.base, modelData.colors.surface0,
                                                     modelData.colors.text, modelData.colors.accent ]
                                            delegate: Rectangle {
                                                required property var modelData
                                                Layout.preferredWidth: 30; Layout.preferredHeight: 30
                                                radius: 8
                                                color: modelData
                                                border.width: 1; border.color: Qt.rgba(1,1,1,0.08)
                                            }
                                        }
                                        Item { Layout.fillWidth: true }
                                    }

                                    // action button
                                    Rectangle {
                                        Layout.fillWidth: true
                                        Layout.preferredHeight: 32
                                        radius: Theme.radius
                                        readonly property bool isActive: parent.parent.active
                                        readonly property bool isInstalled: parent.parent.installed
                                        color: isActive ? Theme.surface2
                                             : (actMa.containsMouse ? Theme.accent2 : (isInstalled ? Theme.surface1 : Theme.accent))
                                        Text {
                                            anchors.centerIn: parent
                                            text: parent.isActive ? I18n.t("Active") : (parent.isInstalled ? I18n.t("Apply") : I18n.t("Install"))
                                            color: parent.isActive ? Theme.subtext0
                                                 : (parent.isInstalled && !actMa.containsMouse ? Theme.text : Theme.onAccent)
                                            font.family: Theme.fontFamily
                                            font.pixelSize: Theme.fontSize - 1
                                            font.bold: true
                                        }
                                        MouseArea {
                                            id: actMa
                                            anchors.fill: parent
                                            enabled: !parent.isActive
                                            hoverEnabled: true
                                            cursorShape: parent.isActive ? Qt.ArrowCursor : Qt.PointingHandCursor
                                            onClicked: {
                                                if (parent.isInstalled) Theme.apply(modelData.id);
                                                else Theme.installTheme(modelData.id);
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

        Component {
            id: cmpWall
            ColumnLayout {
                spacing: 16
                Text {
                    Layout.fillWidth: true
                    wrapMode: Text.WordWrap
                    text: I18n.t("The wallpaper browser opens as a full-screen layer with the carousel gallery and the color palette.")
                    color: Theme.subtext0
                    font.family: Theme.fontFamily
                    font.pixelSize: Theme.fontSize
                }
                Rectangle {
                    Layout.preferredWidth: 220
                    Layout.preferredHeight: 42
                    radius: Theme.radius
                    color: wallMa.containsMouse ? Theme.accent2 : Theme.accent
                    RowLayout {
                        anchors.centerIn: parent
                        spacing: 8
                        Text { text: Icons.image; color: Theme.onAccent; font.family: Theme.fontFamily; font.pixelSize: Theme.fontSize + 1 }
                        Text { text: I18n.t("Open wallpaper browser"); color: Theme.onAccent; font.family: Theme.fontFamily; font.pixelSize: Theme.fontSize; font.bold: true }
                    }
                    MouseArea {
                        id: wallMa
                        anchors.fill: parent
                        hoverEnabled: true
                        cursorShape: Qt.PointingHandCursor
                        onClicked: { Panels.settings = false; Panels.open("wallpaper"); }
                    }
                }

                // ---- transition style (P4) ----
                Rectangle { Layout.fillWidth: true; Layout.preferredHeight: 1; color: Theme.surface2 }
                Text {
                    text: I18n.t("Wallpaper change transition")
                    color: Theme.text; font.family: Theme.fontFamily; font.pixelSize: Theme.fontSize; font.bold: true
                }
                Text {
                    Layout.fillWidth: true; wrapMode: Text.WordWrap
                    text: I18n.t("Animation style swww uses when applying a new wallpaper. Saved in shell.json (behavior.wallpaperTransition).")
                    color: Theme.subtext0; font.family: Theme.fontFamily; font.pixelSize: Theme.fontSize - 1
                }
                DropSelect {
                    Layout.preferredWidth: 300
                    label: I18n.t("Style")
                    options: {
                        var o = [];
                        for (var i = 0; i < Wallpaper.transitions.length; i++)
                            o.push({ v: Wallpaper.transitions[i].id, l: Wallpaper.transitions[i].label });
                        return o;
                    }
                    current: Wallpaper.transitionId()
                    onPicked: function(v) { Wallpaper.setTransition(v); }
                }
                // preview the chosen transition on the current wallpaper
                Rectangle {
                    Layout.preferredWidth: 220
                    Layout.preferredHeight: 38
                    radius: Theme.radius
                    visible: Wallpaper.current !== ""
                    color: prevMa.containsMouse ? Theme.surface1 : Theme.surface0
                    border.width: 1; border.color: Theme.surface2
                    RowLayout {
                        anchors.centerIn: parent; spacing: 8
                        Text { text: Icons.image; color: Theme.accent; font.family: Theme.fontFamily; font.pixelSize: Theme.fontSize }
                        Text { text: I18n.t("Test transition"); color: Theme.text; font.family: Theme.fontFamily; font.pixelSize: Theme.fontSize - 1 }
                    }
                    MouseArea {
                        id: prevMa
                        anchors.fill: parent
                        hoverEnabled: true
                        cursorShape: Qt.PointingHandCursor
                        onClicked: Wallpaper.apply(Wallpaper.current)
                    }
                }

                Item { Layout.fillHeight: true }
            }
        }

        // ---------------- Comportamiento (behavior + Hyprland layout) ----------------
        Component {
            id: cmpBehavior
            Flickable {
                contentHeight: behCol.implicitHeight
                clip: true
                boundsBehavior: Flickable.StopAtBounds
                ColumnLayout {
                    id: behCol
                    width: parent.width
                    spacing: 12

                    SsHeader { text: I18n.t("Language").toUpperCase() }
                    DropSelect {
                        label: I18n.t("Interface language")
                        options: [ { v: "en", l: "English" }, { v: "es", l: "Español" } ]
                        current: I18n.lang
                        onPicked: function(v) { I18n.setLang(v); }
                    }

                    SsHeader { text: I18n.t("KEYBOARD") }
                    DropSelect {
                        label: I18n.t("Keyboard layout")
                        // Distribuciones XKB (código = xkb layout); aplicado en vivo
                        // por el bridge (input:kb_layout) y persistido en shell.json.
                        options: [
                            { v: "ara", l: "Arabic" },
                            { v: "am",  l: "Armenian" },
                            { v: "az",  l: "Azerbaijani" },
                            { v: "by",  l: "Belarusian" },
                            { v: "be",  l: "Belgian" },
                            { v: "ba",  l: "Bosnian" },
                            { v: "bg",  l: "Bulgarian" },
                            { v: "cn",  l: "Chinese" },
                            { v: "hr",  l: "Croatian" },
                            { v: "cz",  l: "Czech" },
                            { v: "dk",  l: "Danish" },
                            { v: "nl",  l: "Dutch" },
                            { v: "gb",  l: "English (UK)" },
                            { v: "us",  l: "English (US)" },
                            { v: "ee",  l: "Estonian" },
                            { v: "fi",  l: "Finnish" },
                            { v: "fr",  l: "French" },
                            { v: "ca",  l: "French (Canada)" },
                            { v: "ch",  l: "German (Switzerland)" },
                            { v: "de",  l: "German" },
                            { v: "ge",  l: "Georgian" },
                            { v: "gr",  l: "Greek" },
                            { v: "il",  l: "Hebrew" },
                            { v: "hu",  l: "Hungarian" },
                            { v: "is",  l: "Icelandic" },
                            { v: "in",  l: "Indian" },
                            { v: "ie",  l: "Irish" },
                            { v: "it",  l: "Italian" },
                            { v: "jp",  l: "Japanese" },
                            { v: "kz",  l: "Kazakh" },
                            { v: "kr",  l: "Korean" },
                            { v: "lv",  l: "Latvian" },
                            { v: "lt",  l: "Lithuanian" },
                            { v: "mk",  l: "Macedonian" },
                            { v: "mt",  l: "Maltese" },
                            { v: "no",  l: "Norwegian" },
                            { v: "ir",  l: "Persian" },
                            { v: "pl",  l: "Polish" },
                            { v: "pt",  l: "Portuguese" },
                            { v: "br",  l: "Portuguese (Brazil)" },
                            { v: "ro",  l: "Romanian" },
                            { v: "ru",  l: "Russian" },
                            { v: "rs",  l: "Serbian" },
                            { v: "sk",  l: "Slovak" },
                            { v: "si",  l: "Slovenian" },
                            { v: "es",  l: "Spanish" },
                            { v: "latam", l: "Spanish (Latin America)" },
                            { v: "se",  l: "Swedish" },
                            { v: "th",  l: "Thai" },
                            { v: "tr",  l: "Turkish" },
                            { v: "ua",  l: "Ukrainian" },
                            { v: "vn",  l: "Vietnamese" }
                        ]
                        current: Config.get("behavior", "keyboardLayout", "us")
                        onPicked: function(v) { Config.set("behavior", "keyboardLayout", v); }
                    }

                    SsHeader { text: I18n.t("DEFAULT APPLICATIONS") }
                    SsText {
                        label: I18n.t("Web browser")
                        sect: "behavior"; k: "defaultBrowser"; def: "auto"
                        placeholder: I18n.t("auto (detects Brave→Chrome→Zen→Firefox)")
                    }

                    SsHeader { text: I18n.t("WINDOWS AND FOCUS") }
                    SsToggle { label: I18n.t("Focus follows mouse"); sect: "behavior"; k: "focusFollowsMouse"; def: true }
                    SsSlider { label: I18n.t("Inner spacing (gaps_in)"); sect: "layout"; k: "gapsIn";  min: 0; max: 40; def: 4;  step: 1; suffix: " px" }
                    SsSlider { label: I18n.t("Outer spacing (gaps_out)"); sect: "layout"; k: "gapsOut"; min: 0; max: 60; def: 10; step: 1; suffix: " px" }
                    SsSlider { label: I18n.t("Border thickness");              sect: "layout"; k: "borderSize";   min: 0; max: 8;  def: 2;  step: 1; suffix: " px" }
                    SsSlider { label: I18n.t("Window rounding (Hyprland)"); sect: "layout"; k: "roundingHypr"; min: 0; max: 24; def: 12; step: 1; suffix: " px" }
                    SsSlider { label: I18n.t("Number of workspaces");  sect: "layout"; k: "workspaceCount"; min: 1; max: 10; def: 10; step: 1 }

                    SsHeader { text: I18n.t("FOLDERS") }
                    SsText { label: I18n.t("Wallpapers folder"); sect: "behavior"; k: "wallpaperDir";  def: "~/Pictures/Wallpapers"; placeholder: "~/Pictures/Wallpapers" }
                    SsText { label: I18n.t("Screenshots folder");           sect: "behavior"; k: "screenshotDir"; def: "~/Pictures/Screenshots"; placeholder: "~/Pictures/Screenshots" }

                    Text {
                        Layout.fillWidth: true; Layout.topMargin: 4; wrapMode: Text.WordWrap
                        text: I18n.t("Focus/gaps/border/rounding/workspace changes are written to shell.json and the bridge regenerates the Hyprland config instantly.")
                        color: Theme.overlay2; font.family: Theme.fontFamily; font.pixelSize: Theme.fontSize - 2
                    }
                    Item { Layout.fillHeight: true }
                }
            }
        }

        Component {
            id: cmpType
            Flickable {
                contentHeight: typeCol.implicitHeight
                clip: true
                boundsBehavior: Flickable.StopAtBounds
                ColumnLayout {
                    id: typeCol
                    width: parent.width
                    spacing: 18

                    // font size
                    ColumnLayout {
                        Layout.fillWidth: true
                        spacing: 6
                        RowLayout {
                            Layout.fillWidth: true
                            Text { text: I18n.t("Font size"); color: Theme.text; font.family: Theme.fontFamily; font.pixelSize: Theme.fontSize; Layout.fillWidth: true }
                            Text { text: Theme.fontSize + " px"; color: Theme.subtext0; font.family: Theme.fontFamily; font.pixelSize: Theme.fontSize - 1 }
                        }
                        Slider {
                            Layout.fillWidth: true
                            value: (Theme.fontSize - 10) / 10
                            onMoved: function(v) { Config.set("appearance", "fontSize", Math.round(10 + v * 10)) }
                        }
                    }

                    // corner radius
                    ColumnLayout {
                        Layout.fillWidth: true
                        spacing: 6
                        RowLayout {
                            Layout.fillWidth: true
                            Text { text: I18n.t("Corner radius"); color: Theme.text; font.family: Theme.fontFamily; font.pixelSize: Theme.fontSize; Layout.fillWidth: true }
                            Text { text: Theme.radius + " px"; color: Theme.subtext0; font.family: Theme.fontFamily; font.pixelSize: Theme.fontSize - 1 }
                        }
                        Slider {
                            Layout.fillWidth: true
                            value: Theme.radius / 24
                            onMoved: function(v) { Config.set("appearance", "cornerRadius", Math.round(v * 24)) }
                        }
                    }

                    // animation speed
                    ColumnLayout {
                        Layout.fillWidth: true
                        spacing: 6
                        RowLayout {
                            Layout.fillWidth: true
                            Text { text: I18n.t("Animation speed"); color: Theme.text; font.family: Theme.fontFamily; font.pixelSize: Theme.fontSize; Layout.fillWidth: true }
                            Text { text: Theme.animSpeed.toFixed(1) + "×"; color: Theme.subtext0; font.family: Theme.fontFamily; font.pixelSize: Theme.fontSize - 1 }
                        }
                        Slider {
                            Layout.fillWidth: true
                            value: (Theme.animSpeed - 0.3) / 1.7
                            fillColor: Theme.yellow
                            onMoved: function(v) { Config.set("appearance", "animationSpeed", Math.round((0.3 + v * 1.7) * 10) / 10) }
                        }
                    }

                    Rectangle { Layout.fillWidth: true; Layout.preferredHeight: 1; color: Theme.surface1 }

                    // toggles
                    RowLayout {
                        Layout.fillWidth: true
                        Text { text: I18n.t("Elevation shadows"); color: Theme.text; font.family: Theme.fontFamily; font.pixelSize: Theme.fontSize; Layout.fillWidth: true }
                        Toggle { checked: Theme.elevation; onToggled: function(v) { Config.set("appearance", "elevation", v) } }
                    }
                    RowLayout {
                        Layout.fillWidth: true
                        Text { text: I18n.t("Bar blur"); color: Theme.text; font.family: Theme.fontFamily; font.pixelSize: Theme.fontSize; Layout.fillWidth: true }
                        Toggle { checked: Theme.barBlur; onToggled: function(v) { Config.set("appearance", "barBlur", v) } }
                    }
                    RowLayout {
                        Layout.fillWidth: true
                        ColumnLayout {
                            Layout.fillWidth: true; spacing: 0
                            Text { text: I18n.t("Animated blobs in panels"); color: Theme.text; font.family: Theme.fontFamily; font.pixelSize: Theme.fontSize }
                            Text { text: I18n.t("Color orbs in the background (GPU cost)"); color: Theme.subtext0; font.family: Theme.fontFamily; font.pixelSize: Theme.fontSize - 3 }
                        }
                        Toggle { checked: Theme.panelBlobs; onToggled: function(v) { Config.set("appearance", "panelBlobs", v) } }
                    }

                    Rectangle { Layout.fillWidth: true; Layout.preferredHeight: 1; color: Theme.surface1 }

                    // Cursor. Un puñado de temas normales, ninguno con logo ni
                    // marca: los ids salen de CURSOR_THEMES en el bridge, que
                    // es quien los aplica (hl.env en el generado + `hyprctl
                    // setcursor` para que se vea sin cerrar sesión) y quien los
                    // lleva al greeter, igual que el tema de colores.
                    SsHeader { text: I18n.t("CURSOR") }
                    DropSelect {
                        label: I18n.t("Cursor theme")
                        options: [
                            { v: "default", l: I18n.t("Default (black arrow)") },
                            { v: "pretty", l: I18n.t("Pretty (white)") },
                            { v: "black", l: I18n.t("Rounded black") },
                            { v: "dmz", l: I18n.t("Classic white") },
                            { v: "capitaine", l: I18n.t("Slate grey") }
                        ]
                        current: Config.get("appearance", "cursorTheme", "pretty")
                        onPicked: function(v) { Config.set("appearance", "cursorTheme", v); }
                    }
                }
            }
        }

        // ==================== Virtualización ====================
        //  Interruptor + comprobación GRANULAR de requisitos + instrucciones de
        //  instalación PROPIAS DE LA PLATAFORMA, verificadas contra la fuente
        //  real (nixpkgs 26.05 en el store de esta máquina y la base de datos
        //  oficial de paquetes de Arch). Ver PROJECT_STATE.md para dónde se
        //  comprobó cada nombre.
        Component {
            id: cmpVirt
            Flickable {
                contentHeight: virtCol.implicitHeight
                clip: true
                boundsBehavior: Flickable.StopAtBounds

                // La sonda corre AL ABRIR ESTA PÁGINA, no antes: es el único
                // sitio del shell donde hace falta, y así con la página cerrada
                // no se ejecuta nada. `Vm.prime()` (y no `detect()` a secas)
                // porque recuerda la petición si Config aún no ha parseado
                // shell.json y se reintenta sola — ver el comentario en Vm.qml.
                //  ⚠️ NO sirve `onVisibleChanged` aquí: la `visible` de un Item
                //  dentro de una ventana NO cambia cuando la ventana se muestra
                //  u oculta, así que ese handler no dispara nunca (probado).
                Component.onCompleted: Vm.prime()

                ColumnLayout {
                    id: virtCol
                    width: parent.width
                    spacing: 12

                    // ---------- interruptor ----------
                    Rectangle {
                        Layout.fillWidth: true
                        implicitHeight: swCol.implicitHeight + 26
                        radius: Theme.radius
                        color: Theme.surface0
                        ColumnLayout {
                            id: swCol
                            anchors.left: parent.left
                            anchors.right: parent.right
                            anchors.verticalCenter: parent.verticalCenter
                            anchors.leftMargin: 14
                            anchors.rightMargin: 12
                            spacing: 4
                            RowLayout {
                                Layout.fillWidth: true
                                spacing: 10
                                Text {
                                    Layout.fillWidth: true
                                    text: I18n.t("Enable virtualization")
                                    color: Theme.text
                                    font.family: Theme.fontFamily
                                    font.pixelSize: Theme.fontSize
                                }
                                Toggle {
                                    checked: Config.get("virtualization", "enabled", false)
                                    onToggled: function(v) {
                                        Config.set("virtualization", "enabled", v);
                                        if (v) Vm.detect();
                                    }
                                }
                            }
                            Text {
                                Layout.fillWidth: true
                                text: I18n.t("Off by default. While it is off, nothing related to virtual machines is loaded: no process, no bar widget, no launcher entry, no memory used.")
                                color: Theme.subtext0
                                wrapMode: Text.Wrap
                                font.family: Theme.fontFamily
                                font.pixelSize: Theme.fontSize - 2
                            }
                        }
                    }

                    // Todo lo de abajo solo tiene sentido con el interruptor puesto.
                    ColumnLayout {
                        Layout.fillWidth: true
                        visible: Vm.enabled
                        spacing: 12

                        // ---------- estado global ----------
                        Rectangle {
                            Layout.fillWidth: true
                            implicitHeight: stCol.implicitHeight + 24
                            radius: Theme.radius
                            color: Vm.requirementsMet
                                   ? Qt.rgba(Theme.green.r, Theme.green.g, Theme.green.b, 0.12)
                                   : Qt.rgba(Theme.yellow.r, Theme.yellow.g, Theme.yellow.b, 0.12)
                            border.width: 1
                            border.color: Vm.requirementsMet ? Theme.green : Theme.yellow
                            RowLayout {
                                id: stCol
                                anchors.left: parent.left
                                anchors.right: parent.right
                                anchors.verticalCenter: parent.verticalCenter
                                anchors.leftMargin: 14
                                anchors.rightMargin: 12
                                spacing: 10
                                Text {
                                    text: Vm.requirementsMet ? Icons.check : Icons.info
                                    color: Vm.requirementsMet ? Theme.green : Theme.yellow
                                    font.family: Theme.fontFamily
                                    font.pixelSize: Theme.fontSize + 4
                                }
                                Text {
                                    Layout.fillWidth: true
                                    text: !Vm.detected ? I18n.t("Checking…")
                                        : Vm.requirementsMet ? I18n.t("Requirements met — virtual machines are ready to use.")
                                        : I18n.t("Something is missing. The list below shows exactly what.")
                                    color: Theme.text
                                    wrapMode: Text.Wrap
                                    font.family: Theme.fontFamily
                                    font.pixelSize: Theme.fontSize - 1
                                }
                                IconButton { icon: Icons.refresh; onClicked: Vm.detect() }
                            }
                        }

                        // ---------- comprobación granular ----------
                        SsHeader { text: I18n.t("COMPONENTS") }
                        ColumnLayout {
                            Layout.fillWidth: true
                            spacing: 9
                            ReqRow {
                                pending: !Vm.detected
                                ok: Vm.has.virsh
                                label: I18n.t("virsh — the libvirt command line client")
                                note: I18n.t("Everything the shell does with VMs goes through it.")
                            }
                            ReqRow {
                                pending: !Vm.detected
                                ok: Vm.has.qemu
                                label: I18n.t("QEMU — the emulator that actually runs the VMs")
                            }
                            ReqRow {
                                pending: !Vm.detected
                                ok: Vm.has.libvirtd
                                label: I18n.t("libvirtd is running and answering on qemu:///system")
                                note: Vm.has.libvirtd ? "" : I18n.t("The service may be stopped, or your user may not be allowed to talk to it yet.")
                            }
                            ReqRow {
                                pending: !Vm.detected
                                ok: Vm.has.grpLibvirt
                                label: I18n.t("Your user is in the libvirt group")
                                note: Vm.has.grpLibvirt ? "" : I18n.t("Group membership only takes effect after you log out and back in.")
                            }
                            ReqRow {
                                pending: !Vm.detected
                                ok: Vm.has.grpKvm
                                label: I18n.t("Your user is in the kvm group")
                                note: Vm.has.grpKvm ? "" : I18n.t("Group membership only takes effect after you log out and back in.")
                            }
                            ReqRow {
                                pending: !Vm.detected
                                ok: Vm.has.kvmdev
                                label: I18n.t("/dev/kvm is readable and writable — hardware acceleration works")
                            }
                            ReqRow {
                                pending: !Vm.detected
                                ok: Vm.has.viewer
                                optional: true
                                label: I18n.t("virt-viewer — opens the VM's graphical display")
                                note: Vm.has.viewer ? "" : I18n.t("Without it you can still use the text console, but not the graphical display.")
                            }
                            ReqRow {
                                pending: !Vm.detected
                                ok: Vm.has.swtpm
                                optional: true
                                label: I18n.t("swtpm — emulated TPM, needed by Windows 11 guests")
                            }
                            ReqRow {
                                pending: !Vm.detected
                                ok: Vm.has.virtiofs
                                optional: true
                                label: I18n.t("virtiofsd — needed for shared folders")
                                note: Vm.has.virtiofs ? "" : I18n.t("Without it, a VM that has a shared folder will refuse to start.")
                            }
                            ReqRow {
                                pending: !Vm.detected
                                ok: Vm.has.uefi
                                optional: true
                                label: I18n.t("UEFI firmware is available for guests")
                                note: I18n.t("Reported by the hypervisor itself. Without it, only BIOS guests can boot.")
                            }
                        }

                        // ---------- instrucciones por plataforma ----------
                        SsHeader { text: I18n.t("SETUP FOR YOUR SYSTEM"); visible: Vm.detected }
                        Text {
                            Layout.fillWidth: true
                            text: Vm.osName !== "" ? (I18n.t("Detected system") + ": " + Vm.osName) : ""
                            visible: text !== ""
                            color: Theme.subtext0
                            wrapMode: Text.Wrap
                            font.family: Theme.fontFamily
                            font.pixelSize: Theme.fontSize - 2
                        }

                        // ======== NixOS ========
                        ColumnLayout {
                            Layout.fillWidth: true
                            visible: Vm.detected && Vm.platform === "nixos"
                            spacing: 6

                            Text {
                                Layout.fillWidth: true
                                text: I18n.t("These go in your configuration.nix. They come in TWO parts and they are NOT interchangeable — read the label on each one before pasting.")
                                color: Theme.text
                                wrapMode: Text.Wrap
                                font.family: Theme.fontFamily
                                font.pixelSize: Theme.fontSize - 1
                            }

                            PartLabel {
                                tag: I18n.t("PART A")
                                tone: Theme.green
                                title: I18n.t("Paste this as a NEW block")
                                body: I18n.t("Nobody normally has these attributes already, so pasting the whole block is safe. Put it anywhere at the top level of configuration.nix.")
                            }
                            CodeBlock {
                                tone: "add"
                                code: "virtualisation.libvirtd = {\n"
                                    + "  enable = true;\n"
                                    + "  qemu = {\n"
                                    + "    package = pkgs.qemu_kvm;\n"
                                    + "    runAsRoot = true;\n"
                                    + "    swtpm.enable = true;\n"
                                    + "  };\n"
                                    + "};"
                            }
                            Text {
                                Layout.fillWidth: true
                                text: I18n.t("Note: do NOT add a qemu.ovmf line. That submodule was removed — NixOS now refuses to build if you set it, because every OVMF/UEFI image shipped with QEMU is already available by default. It is why UEFI already shows as available above.")
                                color: Theme.subtext0
                                wrapMode: Text.Wrap
                                font.family: Theme.fontFamily
                                font.pixelSize: Theme.fontSize - 3
                            }

                            PartLabel {
                                tag: I18n.t("PART B")
                                tone: Theme.yellow
                                title: I18n.t("ADD these to lists you ALREADY have")
                                body: I18n.t("Do NOT paste these as new blocks. Nix does not merge two definitions of the same attribute in one file: a second environment.systemPackages or extraGroups makes the build fail with \"attribute already defined\". Open the lists you already have and add the entries inside them.")
                            }
                            Text {
                                Layout.fillWidth: true
                                text: I18n.t("Inside your existing environment.systemPackages, add:")
                                color: Theme.text
                                wrapMode: Text.Wrap
                                font.family: Theme.fontFamily
                                font.pixelSize: Theme.fontSize - 2
                            }
                            CodeBlock { tone: "merge"; code: "virt-viewer" }
                            Text {
                                Layout.fillWidth: true
                                text: I18n.t("Inside your existing users.users.<your-name>.extraGroups, add:")
                                color: Theme.text
                                wrapMode: Text.Wrap
                                font.family: Theme.fontFamily
                                font.pixelSize: Theme.fontSize - 2
                            }
                            CodeBlock { tone: "merge"; code: "\"libvirtd\" \"kvm\"" }

                            Text {
                                Layout.fillWidth: true
                                text: I18n.t("Only if you want shared folders, also add this as a NEW attribute:")
                                color: Theme.text
                                wrapMode: Text.Wrap
                                font.family: Theme.fontFamily
                                font.pixelSize: Theme.fontSize - 2
                            }
                            CodeBlock {
                                tone: "add"
                                code: "virtualisation.libvirtd.qemu.vhostUserPackages = [ pkgs.virtiofsd ];"
                            }

                            PartLabel {
                                tag: I18n.t("THEN")
                                tone: Theme.blue
                                title: I18n.t("Rebuild, then log out and back in")
                                body: I18n.t("The rebuild brings up libvirtd. Group membership only reaches your session at login, so a rebuild alone is not enough.")
                            }
                            CodeBlock { code: "sudo nixos-rebuild switch" }
                            Text {
                                Layout.fillWidth: true
                                text: I18n.t("If your configuration is a flake, use your usual flake command instead (for example: sudo nixos-rebuild switch --flake /etc/nixos#your-hostname).")
                                color: Theme.subtext0
                                wrapMode: Text.Wrap
                                font.family: Theme.fontFamily
                                font.pixelSize: Theme.fontSize - 3
                            }
                        }

                        // ======== Arch / CachyOS ========
                        ColumnLayout {
                            Layout.fillWidth: true
                            visible: Vm.detected && Vm.platform === "arch"
                            spacing: 6

                            Text {
                                Layout.fillWidth: true
                                text: I18n.t("Run these three commands, then log out and back in.")
                                color: Theme.text
                                wrapMode: Text.Wrap
                                font.family: Theme.fontFamily
                                font.pixelSize: Theme.fontSize - 1
                            }
                            PartLabel {
                                tag: "1"
                                tone: Theme.green
                                title: I18n.t("Install the packages")
                                body: I18n.t("All five are in the official repositories. dnsmasq is what provides DHCP for libvirt's default NAT network — without it new VMs get no address.")
                            }
                            CodeBlock {
                                tone: "add"
                                code: "sudo pacman -S --needed libvirt qemu-desktop virt-viewer swtpm dnsmasq"
                            }
                            PartLabel {
                                tag: "2"
                                tone: Theme.green
                                title: I18n.t("Start the libvirt socket")
                                body: I18n.t("The socket activates the daemon on demand, so nothing runs until something asks for it.")
                            }
                            CodeBlock { tone: "add"; code: "sudo systemctl enable --now libvirtd.socket" }
                            PartLabel {
                                tag: "3"
                                tone: Theme.yellow
                                title: I18n.t("Add yourself to the groups")
                                body: I18n.t("On Arch the group is called libvirt (not libvirtd). -aG appends, so your existing groups are kept — do not leave out the a.")
                            }
                            CodeBlock { tone: "merge"; code: "sudo usermod -aG libvirt,kvm $USER" }
                            Text {
                                Layout.fillWidth: true
                                text: I18n.t("Only if you want shared folders, also install:")
                                color: Theme.text
                                wrapMode: Text.Wrap
                                font.family: Theme.fontFamily
                                font.pixelSize: Theme.fontSize - 2
                            }
                            CodeBlock { tone: "add"; code: "sudo pacman -S --needed virtiofsd" }
                            Text {
                                Layout.fillWidth: true
                                text: I18n.t("Group membership only takes effect after you log out and back in.")
                                color: Theme.subtext0
                                wrapMode: Text.Wrap
                                font.family: Theme.fontFamily
                                font.pixelSize: Theme.fontSize - 3
                            }
                        }

                        // ======== plataforma desconocida ========
                        ColumnLayout {
                            Layout.fillWidth: true
                            visible: Vm.detected && Vm.platform === "unknown"
                            spacing: 6
                            Text {
                                Layout.fillWidth: true
                                text: I18n.t("This system was not recognised, so no package names are shown — guessing them would be worse than nothing. Install the following components the way your distribution does it:")
                                color: Theme.text
                                wrapMode: Text.Wrap
                                font.family: Theme.fontFamily
                                font.pixelSize: Theme.fontSize - 1
                            }
                            Repeater {
                                model: [
                                    I18n.t("libvirt (the daemon and the virsh client)"),
                                    I18n.t("QEMU with KVM support"),
                                    I18n.t("virt-viewer — for the graphical display"),
                                    I18n.t("swtpm — only if you want emulated TPM"),
                                    I18n.t("virtiofsd — only if you want shared folders"),
                                    I18n.t("dnsmasq — for libvirt's default NAT network"),
                                    I18n.t("Enable the libvirt daemon or its socket"),
                                    I18n.t("Add your user to the libvirt and kvm groups, then log out and back in")
                                ]
                                delegate: RowLayout {
                                    required property var modelData
                                    Layout.fillWidth: true
                                    spacing: 8
                                    Text {
                                        Layout.alignment: Qt.AlignTop
                                        text: "•"
                                        color: Theme.overlay2
                                        font.family: Theme.fontFamily
                                        font.pixelSize: Theme.fontSize - 1
                                    }
                                    Text {
                                        Layout.fillWidth: true
                                        text: modelData
                                        color: Theme.subtext1
                                        wrapMode: Text.Wrap
                                        font.family: Theme.fontFamily
                                        font.pixelSize: Theme.fontSize - 2
                                    }
                                }
                            }
                        }

                        // ---------- atajos ----------
                        SsHeader { text: I18n.t("OPEN") }
                        Text {
                            Layout.fillWidth: true
                            text: I18n.t("The VM manager is also in the app launcher, as \"Virtual machines\".")
                            color: Theme.subtext0
                            wrapMode: Text.Wrap
                            font.family: Theme.fontFamily
                            font.pixelSize: Theme.fontSize - 2
                        }
                        RowLayout {
                            Layout.fillWidth: true
                            spacing: 8
                            Rectangle {
                                implicitWidth: vmOpenTxt.implicitWidth + 24
                                implicitHeight: 34
                                radius: Theme.radius
                                color: vmOpenMa.containsMouse ? Theme.surface2 : Theme.surface1
                                Behavior on color { ColorAnimation { duration: Theme.dur(120) } }
                                Text {
                                    id: vmOpenTxt
                                    anchors.centerIn: parent
                                    text: I18n.t("Open the VM manager")
                                    color: Theme.text
                                    font.family: Theme.fontFamily
                                    font.pixelSize: Theme.fontSize - 1
                                }
                                MouseArea {
                                    id: vmOpenMa
                                    anchors.fill: parent
                                    hoverEnabled: true
                                    cursorShape: Qt.PointingHandCursor
                                    onClicked: { Panels.settings = false; Panels.open("vmManager"); }
                                }
                            }
                            Rectangle {
                                visible: !win.vmWidgetOnBar()
                                implicitWidth: vmAddTxt.implicitWidth + 24
                                implicitHeight: 34
                                radius: Theme.radius
                                color: vmAddMa.containsMouse ? Theme.surface2 : Theme.surface1
                                Behavior on color { ColorAnimation { duration: Theme.dur(120) } }
                                Text {
                                    id: vmAddTxt
                                    anchors.centerIn: parent
                                    text: I18n.t("Add the VM widget to the bar")
                                    color: Theme.text
                                    font.family: Theme.fontFamily
                                    font.pixelSize: Theme.fontSize - 1
                                }
                                MouseArea {
                                    id: vmAddMa
                                    anchors.fill: parent
                                    hoverEnabled: true
                                    cursorShape: Qt.PointingHandCursor
                                    onClicked: WidgetRegistry.addWidget("right", "vm")
                                }
                            }
                        }
                        Text {
                            Layout.fillWidth: true
                            text: I18n.t("The bar widget only shows up while at least one VM is running; with none running it is not on the bar at all.")
                            color: Theme.subtext0
                            wrapMode: Text.Wrap
                            font.family: Theme.fontFamily
                            font.pixelSize: Theme.fontSize - 3
                        }
                    }

                    Item { Layout.fillHeight: true }
                }
            }
        }

        Component {
            id: cmpAbout
            ColumnLayout {
                spacing: 10
                RowLayout {
                    spacing: 12
                    Text { text: Icons.info; color: Theme.accent; font.family: Theme.fontFamily; font.pixelSize: Theme.fontSize + 10 }
                    ColumnLayout {
                        spacing: 2
                        Text { text: "Vexyon Shell"; color: Theme.text; font.family: Theme.fontFamily; font.pixelSize: Theme.fontSize + 4; font.bold: true }
                        Text { text: I18n.t("Active theme: ") + Theme.activeId; color: Theme.subtext0; font.family: Theme.fontFamily; font.pixelSize: Theme.fontSize - 1 }
                    }
                }
                Text {
                    Layout.fillWidth: true
                    Layout.topMargin: 8
                    wrapMode: Text.WordWrap
                    text: I18n.t("Desktop shell for Hyprland built with Quickshell — easy to customize, made for you.")
                    color: Theme.subtext0
                    font.family: Theme.fontFamily
                    font.pixelSize: Theme.fontSize
                }
                Text {
                    Layout.topMargin: 4
                    text: I18n.t("Version") + " 1.1"
                    color: Theme.subtext0
                    font.family: Theme.fontFamily
                    font.pixelSize: Theme.fontSize - 1
                }
                Item { Layout.fillHeight: true }
            }
        }
    }
}
