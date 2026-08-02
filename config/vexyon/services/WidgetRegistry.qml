pragma Singleton

import QtQuick
import Quickshell
import Quickshell.Io
import qs.services

// ============================================================================
//  WidgetRegistry — single source of truth for the bar's widget catalog and
//  the per-section widget layout. The bar renders whatever this exposes; the
//  Settings widget-manager mutates it. All layout state lives in shell.json at
//  bar.widgets = { left:[], center:[], right:[] }, each entry being an instance
//  { type, id, hidden?, <widget-specific props> }. Multiple copies of a type
//  are allowed (id keeps them distinct).
// ============================================================================
Singleton {
    id: root

    // ---- catalog: every widget type the user can place on the bar ----------
    // group is purely for the "add widget" modal's visual grouping.
    readonly property var catalog: [
        // core / existing
        { type: "applauncher",   name: I18n.t("App launcher"),       desc: I18n.t("Opens the app launcher"),        icon: Icons.grid,        group: "Esenciales" },
        { type: "workspaces",    name: I18n.t("Workspaces"),    desc: I18n.t("Workspace indicator"),        icon: Icons.grid,        group: "Esenciales" },
        { type: "clock",         name: I18n.t("Clock"),                  desc: I18n.t("Time and date"),                            icon: Icons.clock,       group: "Esenciales" },
        { type: "focusedwindow", name: I18n.t("Focused window"),       desc: I18n.t("Active window title"),             icon: Icons.window,      group: "Esenciales" },
        { type: "volume",        name: I18n.t("Volume"),                desc: I18n.t("Volume level (scroll to change)"),   icon: Icons.volumeHigh,  group: "Sistema" },
        { type: "brightness",    name: I18n.t("Brightness"),                 desc: I18n.t("Screen brightness"),                   icon: Icons.brightness,  group: "Sistema" },
        { type: "battery",       name: I18n.t("Battery"),                desc: I18n.t("Battery level (laptops)"),           icon: Icons.battery,     group: "Sistema" },
        { type: "network",       name: I18n.t("Network"),                    desc: I18n.t("Wi-Fi/Ethernet network status"),            icon: Icons.wifi,        group: "Sistema" },
        { type: "bluetooth",     name: "Bluetooth",              desc: I18n.t("Bluetooth status"),                     icon: Icons.bluetooth,   group: "Sistema" },
        { type: "microphone",    name: I18n.t("Microphone"),              desc: I18n.t("Mute/unmute microphone"),             icon: Icons.microphone,  group: "Sistema" },
        { type: "power",         name: I18n.t("Power menu"),      desc: I18n.t("Power off / reboot / log out"),      icon: Icons.power,       group: "Sistema" },
        { type: "controlcenter", name: I18n.t("Control center"),      desc: I18n.t("Opens the control center"),               icon: Icons.sliders,     group: "Sistema" },
        // new widgets
        { type: "weather",       name: I18n.t("Weather"),                  desc: I18n.t("Condition and temperature"),                 icon: Icons.cloud,       group: I18n.t("Information") },
        { type: "notifications", name: I18n.t("Notifications"),         desc: I18n.t("Notification center + do not disturb"),  icon: Icons.bell,        group: I18n.t("Information") },
        { type: "idleinhibitor", name: I18n.t("Inhibit idle"),    desc: I18n.t("Prevents suspend/screen off"),   icon: Icons.coffee,      group: "Sistema" },
        { type: "media",         name: I18n.t("Media controls"),   desc: I18n.t("Current player playback"),     icon: Icons.play,        group: I18n.t("Information") },
        { type: "clipboard",     name: I18n.t("Clipboard"),           desc: I18n.t("Clipboard history"),              icon: Icons.clipboard,   group: "Utilidades" },
        { type: "cpu",           name: I18n.t("CPU usage"),             desc: I18n.t("CPU usage percentage"),                icon: Icons.microchip,   group: I18n.t("Monitors") },
        { type: "memory",        name: I18n.t("Memory usage"),         desc: I18n.t("RAM used percentage"),                 icon: Icons.server,      group: I18n.t("Monitors") },
        { type: "disk",          name: I18n.t("Disk usage"),           desc: I18n.t("Space used on /"),                      icon: Icons.drive,       group: I18n.t("Monitors") },
        { type: "cputemp",       name: I18n.t("CPU temperature"),     desc: I18n.t("CPU temperature"),                   icon: Icons.thermometer, group: I18n.t("Monitors") },
        { type: "gputemp",       name: I18n.t("GPU temperature"),     desc: I18n.t("Integrated GPU temperature"),         icon: Icons.thermometer, group: I18n.t("Monitors") },
        { type: "netspeed",      name: I18n.t("Network speed"),       desc: I18n.t("Live up/down"),                 icon: Icons.arrowDown,   group: I18n.t("Monitors") },
        { type: "systemtray",    name: I18n.t("System tray"),    desc: I18n.t("System tray icons"),        icon: Icons.inbox,       group: "Sistema" },
        { type: "privacy",       name: I18n.t("Privacy indicator"),desc: I18n.t("Microphone/camera/screen in use"),        icon: Icons.shield,      group: "Sistema" },
        { type: "vpn",           name: "VPN",                    desc: I18n.t("VPN status/quick connect"),           icon: Icons.shield,      group: "Sistema" },
        { type: "capslock",      name: I18n.t("Caps Lock"),             desc: I18n.t("Caps Lock indicator"),                 icon: Icons.arrowUp,     group: "Utilidades" },
        { type: "keyboardlayout",name: I18n.t("Keyboard layout"),desc: I18n.t("Active layout + switch"),            icon: Icons.language,    group: "Utilidades" },
        { type: "notes",         name: I18n.t("Notes"),                  desc: I18n.t("Quick access to notes"),                   icon: Icons.stickyNote,  group: "Utilidades" },
        { type: "colorpicker",   name: I18n.t("Color picker"),      desc: I18n.t("Color picker"),                    icon: Icons.eyeDropper,  group: "Utilidades" },
        { type: "sysupdate",     name: I18n.t("System update"),desc: I18n.t("Checks for updates"),             icon: Icons.download,    group: "Utilidades" },
        { type: "appsdock",      name: I18n.t("Active apps / Dock"),    desc: I18n.t("Open and pinned apps"),                icon: Icons.bars,        group: "Utilidades" },
        { type: "spacer",        name: I18n.t("Spacer"),             desc: I18n.t("Configurable empty space"),              icon: Icons.arrowsH,     group: I18n.t("Layout") },
        { type: "separator",     name: I18n.t("Separator"),              desc: I18n.t("Visual divider between widgets"),            icon: Icons.dragHandle,  group: I18n.t("Layout") }
    ]

    function meta(type) {
        // "group" is created by selecting widgets, not from the add-widget
        // catalog, so it lives here rather than in `catalog`.
        if (type === "group")
            return { type: "group", name: I18n.t("Group"), desc: I18n.t("Combined pill of several widgets"), icon: Icons.bars, group: I18n.t("Layout") };
        for (var i = 0; i < root.catalog.length; i++)
            if (root.catalog[i].type === type) return root.catalog[i];
        return { type: type, name: type, desc: "", icon: Icons.grid, group: I18n.t("Other") };
    }

    // ---- icono configurable de la pastilla del lanzador de apps -----------
    // El widget "applauncher" es la pastilla que dispara el launcher; su icono
    // se elige por instancia (cfg.icon = una de estas claves). El selector vive
    // en el gestor de widgets; la barra lo resuelve con launcherGlyph().
    readonly property var launcherIconChoices: [
        { key: "grid",     glyph: Icons.grid,        label: I18n.t("Grid") },
        { key: "bars",     glyph: Icons.bars,        label: I18n.t("Menu") },
        { key: "search",   glyph: Icons.search,      label: I18n.t("Search") },
        { key: "star",     glyph: Icons.star,        label: I18n.t("Star") },
        { key: "sliders",  glyph: Icons.sliders,     label: I18n.t("Sliders") },
        { key: "home",     glyph: Icons.home,        label: I18n.t("Home") },
        // logos (como el launcher de DMS): distro auto-detectada, Hyprland y
        // la marca Vexyon. "distro" puede resolverse a imagen (launcherImage)
        // y "vexyon" se dibuja como marca propia — LauncherIcon.qml decide.
        { key: "distro",   glyph: root.distroGlyph,  label: I18n.t("Distro logo") },
        { key: "hyprland", glyph: "",          label: "Hyprland" },
        { key: "vexyon",   glyph: "",                label: "Vexyon" }
    ]
    function launcherGlyph(key) {
        if (key === "vexyon") return "";   // marca dibujada, no glifo
        for (var i = 0; i < root.launcherIconChoices.length; i++)
            if (root.launcherIconChoices[i].key === key) return root.launcherIconChoices[i].glyph;
        return Icons.grid;
    }
    // Ruta de imagen (source de Image) cuando la distro no tiene glifo Nerd
    // Font (p.ej. CachyOS → svg del sistema, colorizada al tema al pintarla).
    function launcherImage(key) { return key === "distro" ? root.distroImage : ""; }

    // ---- detección del logo de la distro (una vez, /etc/os-release) --------
    // Igual que el SystemLogo de DMS: ID con glifo NF conocido → glifo; si no,
    // LOGO → imagen (cachyos.svg especial-caseado como DMS, resto vía
    // Quickshell.iconPath); si no, primer ID_LIKE con glifo; fallback Tux.
    property string distroGlyph: "\u{f033d}"   // Tux (nf-md-linux)
    property string distroImage: ""
    readonly property var _distroNF: ({
        arch: "\u{f08c7}", archcraft: "", debian: "\u{f08da}",
        fedora: "\u{f08db}", ubuntu: "\u{f0548}", manjaro: "\u{f160a}",
        endeavouros: "", nixos: "\u{f1105}", gentoo: "\u{f08e8}",
        opensuse: "", "opensuse-tumbleweed": "",
        "opensuse-leap": "", artix: "", "void": "",
        guix: ""
    })
    Process {
        id: osProbe
        running: true
        command: ["bash", "-c",
            ". /etc/os-release 2>/dev/null; printf '%s|%s|%s' \"${ID:-}\" \"${ID_LIKE:-}\" \"${LOGO:-}\""]
        stdout: StdioCollector {
            onStreamFinished: {
                var parts = this.text.trim().split("|");
                var id   = (parts[0] || "").toLowerCase();
                var like = (parts[1] || "").toLowerCase();
                var logo = (parts[2] || "").trim();
                if (root._distroNF[id]) { root.distroGlyph = root._distroNF[id]; return; }
                if (logo === "cachyos") { root.distroGlyph = ""; root.distroImage = "file:///usr/share/icons/cachyos.svg"; return; }
                if (logo !== "") {
                    var p = Quickshell.iconPath(logo, true);
                    if (p && p !== "") { root.distroGlyph = ""; root.distroImage = p; return; }
                }
                var lks = like.split(/\s+/);
                for (var i = 0; i < lks.length; i++)
                    if (root._distroNF[lks[i]]) { root.distroGlyph = root._distroNF[lks[i]]; return; }
                // sin match: se queda el Tux por defecto
            }
        }
    }

    // ---- default layout — replicates the DankMaterialShell default bar ----
    // Left: launcher · workspaces · focused window. Center: media · clock ·
    // weather. Right: tray · clipboard · cpu · ram · notifications · battery ·
    // control center. Ungrouped (DMS pills stand alone); the P6 group feature
    // stays available from the widget manager for users who want clusters.
    readonly property var defaults: ({
        "left":   [ { type: "applauncher" },
                    { type: "workspaces" },
                    { type: "focusedwindow" } ],
        "center": [ { type: "media" },
                    { type: "clock" },
                    { type: "weather" } ],
        "right":  [ { type: "systemtray" },
                    { type: "clipboard" },
                    { type: "cpu" },
                    { type: "memory" },
                    { type: "notifications" },
                    { type: "battery" },
                    { type: "controlcenter" } ]
    })

    // Give every entry a stable id so instances stay distinct across reorders.
    // IMPORTANT: ids for un-stamped entries must be DETERMINISTIC (type +
    // position), not random — section() re-stamps on every call, and a random
    // id would differ between the UI's snapshot and the later setProp/move
    // lookup, silently missing the target until the layout is persisted.
    // Group entries ({ type:"group", children:[…] }) also get their children
    // id-stamped so nested instances stay addressable.
    function withIds(list) {
        var out = [];
        for (var i = 0; i < list.length; i++) {
            var e = JSON.parse(JSON.stringify(list[i]));
            if (!e.id) e.id = e.type + "-d" + i;
            if (e.type === "group" && e.children) {
                for (var c = 0; c < e.children.length; c++)
                    if (!e.children[c].id)
                        e.children[c].id = e.children[c].type + "-d" + i + "c" + c;
            }
            out.push(e);
        }
        return out;
    }

    // Current layout for a section, always id-stamped.
    function section(name) {
        var w = Config.get("bar", "widgets", null);
        var raw = (w && w[name]) ? w[name] : (root.defaults[name] || []);
        return withIds(raw);
    }

    // Persist the whole widgets object after mutating one section.
    function _writeSection(name, list) {
        var w = Config.get("bar", "widgets", null);
        var obj = w ? JSON.parse(JSON.stringify(w)) : {
            left: withIds(root.defaults.left),
            center: withIds(root.defaults.center),
            right: withIds(root.defaults.right)
        };
        obj[name] = list;
        Config.set("bar", "widgets", obj);
    }

    function newId(type) { return type + "-" + Math.random().toString(36).slice(2, 8); }

    function addWidget(sectionName, type) {
        var list = section(sectionName);
        list.push({ type: type, id: newId(type) });
        _writeSection(sectionName, list);
    }

    function removeWidget(sectionName, id) {
        var list = section(sectionName).filter(function(e) { return e.id !== id; });
        _writeSection(sectionName, list);
    }

    function toggleHidden(sectionName, id) {
        var list = section(sectionName);
        for (var i = 0; i < list.length; i++)
            if (list[i].id === id) list[i].hidden = !(list[i].hidden === true);
        _writeSection(sectionName, list);
    }

    // Move within a section by index delta (-1 up, +1 down in the list order).
    function move(sectionName, id, delta) {
        var list = section(sectionName);
        var idx = -1;
        for (var i = 0; i < list.length; i++) if (list[i].id === id) { idx = i; break; }
        if (idx < 0) return;
        var to = idx + delta;
        if (to < 0 || to >= list.length) return;
        var tmp = list[idx]; list[idx] = list[to]; list[to] = tmp;
        _writeSection(sectionName, list);
    }

    // Reorder to an explicit index (used by drag-drop).
    function reorder(sectionName, id, toIndex) {
        var list = section(sectionName);
        var idx = -1;
        for (var i = 0; i < list.length; i++) if (list[i].id === id) { idx = i; break; }
        if (idx < 0) return;
        var item = list.splice(idx, 1)[0];
        toIndex = Math.max(0, Math.min(list.length, toIndex));
        list.splice(toIndex, 0, item);
        _writeSection(sectionName, list);
    }

    // Update a widget instance's config prop (e.g. spacer width).
    function setProp(sectionName, id, key, value) {
        var list = section(sectionName);
        for (var i = 0; i < list.length; i++)
            if (list[i].id === id) list[i][key] = value;
        _writeSection(sectionName, list);
    }

    // ---- grouping ---------------------------------------------------------
    // Combine >=2 instance ids in a section into a single "grupo" pill that
    // hosts them as children. Generic (any N leaf widgets), opt-in, reversible
    // via ungroup(), and persisted like any other entry. The group takes the
    // slot of the earliest selected widget; child order follows section order.
    // Groups don't nest (a selected group is ignored).
    function groupWidgets(sectionName, ids) {
        if (!ids || ids.length < 2) return;
        var list = section(sectionName);
        var picked = [], firstIdx = -1;
        for (var i = 0; i < list.length; i++) {
            if (ids.indexOf(list[i].id) !== -1 && list[i].type !== "group") {
                if (firstIdx === -1) firstIdx = i;
                picked.push(list[i]);
            }
        }
        if (picked.length < 2) return;
        // rest = everything not picked (keeps groups + unselected widgets)
        var rest = [], insertAt = 0;
        for (var j = 0; j < list.length; j++) {
            var isPicked = (ids.indexOf(list[j].id) !== -1 && list[j].type !== "group");
            if (j < firstIdx && !isPicked) insertAt++;
            if (!isPicked) rest.push(list[j]);
        }
        rest.splice(insertAt, 0, { type: "group", id: newId("group"), children: picked });
        _writeSection(sectionName, rest);
    }

    // Dissolve a group back into its child widgets, in place.
    function ungroup(sectionName, groupId) {
        var list = section(sectionName), out = [];
        for (var i = 0; i < list.length; i++) {
            if (list[i].id === groupId && list[i].type === "group") {
                var ch = list[i].children || [];
                for (var c = 0; c < ch.length; c++) out.push(ch[c]);
            } else out.push(list[i]);
        }
        _writeSection(sectionName, out);
    }

    function resetSection(sectionName) { _writeSection(sectionName, withIds(root.defaults[sectionName] || [])); }

    function resetAll() {
        Config.set("bar", "widgets", {
            left: withIds(root.defaults.left),
            center: withIds(root.defaults.center),
            right: withIds(root.defaults.right)
        });
    }
}
