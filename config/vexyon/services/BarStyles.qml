pragma Singleton

import QtQuick
import Quickshell
import qs.services

// ============================================================================
//  BarStyles — FORM presets for the bar: height, spacing, rounding, pill vs
//  flat widgets, per-section islands, separators, border, transparency,
//  workspace indicator shape. Static data, nothing else: applying a style
//  writes its keys into shell.json 'bar' in ONE Config.setSection, and the bar
//  picks them up through the same Config bindings it has always had (the
//  bridge sees the same file change it already watches). No timer, process or
//  watcher of its own; while a style is in use nothing here runs.
//
//  ORTHOGONAL to themes: a preset never holds a colour. Where a style wants
//  emphasis it names a palette ROLE (borderColor: "accent") and Theme
//  resolves it, so every style works under every theme.
//
//  Every preset sets the SAME keys, so switching style never leaves a key from
//  the previous one behind. Keys outside this list (position, screens,
//  auto-hide, exclusive zone, scroll, tray tint, font/icon scale, the widget
//  layout itself) are the user's and no style touches them. Tweaks made in
//  Bar settings after picking a style stay on top of it.
// ============================================================================
Singleton {
    id: root

    readonly property string active: Config.get("bar", "style", "default")

    // display order in Settings
    readonly property var ids: ["default", "hyde", "jakoolit", "ryoku"]

    readonly property var names: ({
        "default":  "Default",
        "hyde":     "Islands",
        "jakoolit": "Bordered",
        "ryoku":    "Rail"
    })
    readonly property var descriptions: ({
        "default":  "Floating bar, rounded pills.",
        "hyde":     "Leaf-cornered islands per section (HyDE-like).",
        "jakoolit": "Continuous bar, accent border, separators (JaKooLit-like).",
        "ryoku":    "Flush edge rail, flat widgets, dot workspaces (Ryoku-like)."
    })

    readonly property var presets: ({
        // the shipped look (= seed shell.json): nothing changes for anyone who
        // never opens the selector
        "default": {
            barSize: 38, edgeGap: 6, marginSides: 8, padding: 8, pillGap: 4,
            cornerRadius: 12, backgroundStyle: "solid", bgOpacity: 1.0,
            border: false, borderColor: "subtle", shadow: "none",
            widgetShape: "pill", widgetOutline: false, widgetTransparency: 1.0,
            islands: false, separators: false, workspaceStyle: "pill",
            edgeFillets: false
        },
        // one floating island behind each section, asymmetric "leaf" corners,
        // flat widgets inside; translucent so the existing bar blur shows
        "hyde": {
            barSize: 40, edgeGap: 6, marginSides: 10, padding: 12, pillGap: 2,
            cornerRadius: 16, backgroundStyle: "solid", bgOpacity: 0.82,
            border: false, borderColor: "subtle", shadow: "none",
            widgetShape: "flat", widgetOutline: false, widgetTransparency: 1.0,
            islands: true, separators: false, workspaceStyle: "pill",
            edgeFillets: false
        },
        // one continuous compact strip with an accent outline and thin
        // separators between modules
        "jakoolit": {
            barSize: 34, edgeGap: 4, marginSides: 4, padding: 6, pillGap: 9,
            cornerRadius: 10, backgroundStyle: "solid", bgOpacity: 0.94,
            border: true, borderColor: "accent", shadow: "none",
            widgetShape: "flat", widgetOutline: false, widgetTransparency: 1.0,
            islands: false, separators: true, workspaceStyle: "pill",
            edgeFillets: false
        },
        // edge-to-edge rail fused with the screen edge (concave fillets),
        // generous padding, flat widgets, dot workspaces
        "ryoku": {
            barSize: 40, edgeGap: 0, marginSides: 0, padding: 16, pillGap: 6,
            cornerRadius: 0, backgroundStyle: "solid", bgOpacity: 1.0,
            border: false, borderColor: "subtle", shadow: "none",
            widgetShape: "flat", widgetOutline: false, widgetTransparency: 1.0,
            islands: false, separators: false, workspaceStyle: "dot",
            edgeFillets: true
        }
    })

    function apply(id) {
        var p = root.presets[id];
        if (!p) return;
        var bar = JSON.parse(JSON.stringify(Config.get("bar") || {}));
        for (var k in p) bar[k] = p[k];
        bar.style = id;
        Config.setSection("bar", bar);
    }
}
