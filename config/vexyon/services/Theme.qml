pragma Singleton

import QtQuick
import Quickshell
import Quickshell.Io
import qs.services

// ============================================================================
//  Theme — live design tokens. Every visual property any module needs is read
//  from here, never hardcoded. Switching a theme updates these properties in
//  place, so all QML bindings react instantly (zero restart).
//
//  Colors come from the active palette file under
//  ~/.local/share/vexyon/themes/<id>.json. Geometry/typography tokens come from
//  shell.json 'appearance'/'bar', with optional per-theme overrides.
// ============================================================================
Singleton {
    id: root

    readonly property string homeDir: Quickshell.env("HOME")
    readonly property string themesDir: homeDir + "/.local/share/vexyon/themes"

    readonly property string activeId: Config.get("theme", "active", "crimson-voltage")
    readonly property string palettePath: themesDir + "/" + activeId + ".json"

    // ---- raw palette data (parsed from the active theme file) -------------
    property var palette: ({})
    property var meta: ({})   // { id, name, dark }

    // =======================================================================
    //  COLOR TOKENS  (fallbacks = a safe dark theme so UI never renders blank)
    // =======================================================================
    readonly property color base:     pc("base",     "#0d0d12")
    readonly property color mantle:   pc("mantle",   "#0a0a0e")
    readonly property color crust:    pc("crust",    "#070709")
    readonly property color text:     pc("text",     "#e6e6ef")
    readonly property color subtext0: pc("subtext0", "#a6a6c0")
    readonly property color subtext1: pc("subtext1", "#c2c2d6")
    readonly property color surface0: pc("surface0", "#16161d")
    readonly property color surface1: pc("surface1", "#20202a")
    readonly property color surface2: pc("surface2", "#2b2b38")
    readonly property color overlay0: pc("overlay0", "#3a3a4a")
    readonly property color overlay1: pc("overlay1", "#4c4c60")
    readonly property color overlay2: pc("overlay2", "#6a6a82")
    readonly property color accent:   pc("accent",   "#e11d48")
    readonly property color accent2:  pc("accent2",  "#f43f5e")
    readonly property color red:      pc("red",      "#f38ba8")
    readonly property color green:    pc("green",    "#a6e3a1")
    readonly property color yellow:   pc("yellow",   "#f9e2af")
    readonly property color blue:     pc("blue",     "#89b4fa")
    readonly property color peach:    pc("peach",    "#fab387")
    readonly property color mauve:    pc("mauve",    "#cba6f7")
    readonly property color teal:     pc("teal",     "#94e2d5")
    readonly property color pink:     pc("pink",     "#f5c2e7")

    // Contrast color to place text on top of the accent.
    readonly property color onAccent: pc("onAccent", meta.dark === false ? "#ffffff" : "#0b0b0f")

    // =======================================================================
    //  GEOMETRY / TYPOGRAPHY / MOTION TOKENS  (shell.json, theme may override)
    // =======================================================================
    readonly property int    radius:          numOverride("radius", Config.get("appearance", "cornerRadius", 12))
    readonly property bool   barBlur:          Config.get("appearance", "barBlur", true)
    readonly property string fontFamily:       fontOverride("family", Config.get("appearance", "fontFamily", "JetBrainsMono Nerd Font"))
    readonly property int    fontSize:         fontOverride("size", Config.get("appearance", "fontSize", 13))
    readonly property real   animSpeed:        Config.get("appearance", "animationSpeed", 1.0)
    readonly property bool   elevation:        Config.get("appearance", "elevation", true)
    // Blobs/orbes animados en el fondo de los paneles anclados (coste GPU) —
    // desactivable en Ajustes → Tipografía y movimiento.
    readonly property bool   panelBlobs:       Config.get("appearance", "panelBlobs", true)

    // Ajustes escribe bar.barSize/bar.edgeGap (bar.height/marginTop son los
    // nombres antiguos, solo fallback) — leer aquí las claves nuevas para que
    // todo consumidor siga el valor que la GUI realmente cambia.
    readonly property int    barHeight:      Config.get("bar", "barSize", Config.get("bar", "height", 38))
    readonly property int    barMarginTop:   Config.get("bar", "edgeGap", Config.get("bar", "marginTop", 6))

    // Standard easing + duration helpers so every module animates consistently.
    readonly property int    easing: Easing.OutCubic
    function dur(ms) { return Math.max(1, Math.round(ms / Math.max(0.05, root.animSpeed))); }

    // =======================================================================
    //  Palette loading
    // =======================================================================
    FileView {
        id: paletteFile
        path: root.palettePath
        watchChanges: true
        onFileChanged: reload()
        onLoaded: root.parsePalette()
    }

    function parsePalette() {
        try {
            var txt = paletteFile.text();
            if (!txt || txt.trim() === "") return;
            var p = JSON.parse(txt);
            root.palette = p.colors || {};
            root.meta = { id: p.id || root.activeId, name: p.name || root.activeId, dark: p.dark !== false,
                          radius: p.radius, font: p.font };
            // Terminal (Ghostty/Fish/fastfetch) theming is regenerated by the
            // bridge daemon on theme change — see vexyon-bridge.py.
        } catch (e) {
            console.warn("[Theme] failed to parse palette:", root.palettePath, e);
        }
    }

    // palette color lookup with fallback
    function pc(key, fallback) {
        return (root.palette && root.palette[key]) ? root.palette[key] : fallback;
    }
    function numOverride(key, fallback) {
        return (root.meta && root.meta[key] !== undefined && root.meta[key] !== null) ? root.meta[key] : fallback;
    }
    function fontOverride(key, fallback) {
        return (root.meta && root.meta.font && root.meta.font[key] !== undefined) ? root.meta.font[key] : fallback;
    }

    // =======================================================================
    //  Instant theme switching (called by the Control Center switcher)
    // =======================================================================
    function apply(id) {
        // Persist first (atomic), then the activeId binding updates palettePath,
        // FileView reloads, and every token property re-evaluates -> live update.
        Config.set("theme", "active", id);
    }

    // =======================================================================
    //  Theme discovery for the switcher UI (id, name, dark, swatch colors)
    // =======================================================================
    property var available: []

    Process {
        id: lister
        command: ["bash", "-c",
            "shopt -s nullglob; jq -s '[.[] | {id, name, dark, colors: {base: .colors.base, surface0: .colors.surface0, accent: .colors.accent, text: .colors.text}}]' " +
            root.themesDir + "/*.json 2>/dev/null"]
        stdout: StdioCollector {
            onStreamFinished: {
                try {
                    var arr = JSON.parse(this.text);
                    if (Array.isArray(arr)) root.available = arr;
                } catch (e) { console.warn("[Theme] theme list parse failed:", e); }
            }
        }
    }

    function refreshThemes() { lister.running = true; }

    // =======================================================================
    //  THEME STORE — curated catalog of extra themes shipped under
    //  ~/.local/share/vexyon/store/catalog.json. "Installing" writes the
    //  selected palette into themesDir/<id>.json so the live engine + switcher
    //  pick it up (via refreshThemes). Structured so a remote catalog could
    //  drop in later by pointing storeDir at a synced/downloaded file.
    // =======================================================================
    readonly property string storeDir: homeDir + "/.local/share/vexyon/store"
    property var storeThemes: []          // [{id,name,author,dark,colors}]

    FileView {
        id: catalogFile
        path: root.storeDir + "/catalog.json"
        watchChanges: true
        onFileChanged: reload()
        onLoaded: {
            try {
                var c = JSON.parse(catalogFile.text());
                root.storeThemes = (c && Array.isArray(c.themes)) ? c.themes : [];
            } catch (e) { console.warn("[Theme] store catalog parse failed:", e); }
        }
    }

    // is a theme id already present in the active themes dir?
    function isInstalled(id) {
        for (var i = 0; i < root.available.length; i++)
            if (root.available[i].id === id) return true;
        return false;
    }

    Process {
        id: installer
        onExited: root.refreshThemes()
    }

    function installTheme(id) {
        installer.command = ["bash", "-c",
            "mkdir -p '" + root.themesDir + "' && " +
            "jq -c --arg id '" + id + "' '.themes[] | select(.id==$id) | {id,name,dark,colors,radius,font}' '" +
            root.storeDir + "/catalog.json' > '" + root.themesDir + "/" + id + ".json'"];
        installer.running = true;
    }

    // remove an installed store theme (never the active one; bundled stay).
    Process { id: remover; onExited: root.refreshThemes() }
    function removeTheme(id) {
        if (id === root.activeId) return;
        remover.command = ["rm", "-f", root.themesDir + "/" + id + ".json"];
        remover.running = true;
    }

    Component.onCompleted: refreshThemes()
}
