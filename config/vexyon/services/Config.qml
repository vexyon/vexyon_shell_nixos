pragma Singleton

import QtQuick
import Quickshell
import Quickshell.Io

// ============================================================================
//  Config — single source of truth for shell.json.
//  Every module reads runtime settings from here; nothing hardcodes values.
//  Writes are atomic (FileView.atomicWrites default) and re-read via watch.
// ============================================================================
Singleton {
    id: root

    readonly property string homeDir: Quickshell.env("HOME")
    readonly property string configPath: homeDir + "/.config/vexyon/shell.json"

    // Parsed shell.json. Never mutate in place without calling save().
    property var data: ({})
    property bool ready: false

    signal changed()

    // ---- convenience typed accessors (with sane fallbacks) ----------------
    readonly property var theme:      data.theme      || ({})
    readonly property var appearance: data.appearance || ({})
    readonly property var bar:        data.bar        || ({})
    readonly property var layout:     data.layout     || ({})
    readonly property var behavior:   data.behavior   || ({})
    readonly property var keybinds:   data.keybinds   || []

    FileView {
        id: file
        path: root.configPath
        watchChanges: true
        onFileChanged: reload()
        onLoaded: root.parseNow()
    }

    // Última escritura propia. El watch de FileView también dispara con
    // nuestros propios setText; si esa relectura llegara tarde (tras otro
    // set()) reasignaría root.data con contenido viejo y el siguiente set()
    // clonaría datos obsoletos — cambios "que no persisten". Si el texto es
    // exactamente lo último que escribimos, data ya está al día: no reparsear.
    property string _lastWritten: ""

    function parseNow() {
        try {
            var txt = file.text();
            if (!txt || txt.trim() === "") return;
            if (txt === root._lastWritten) { root.ready = true; return; }
            root.data = JSON.parse(txt);
            root.ready = true;
            root.changed();
        } catch (e) {
            console.warn("[Config] failed to parse shell.json:", e);
        }
    }

    // Read a nested value: get("appearance", "cornerRadius", 12)
    function get(section, key, fallback) {
        var s = root.data[section];
        if (s === undefined || s === null) return fallback;
        if (key === undefined) return s;
        return (s[key] === undefined) ? fallback : s[key];
    }

    // Set a nested value and persist atomically. set("theme","active","amoled")
    function set(section, key, value) {
        var d = JSON.parse(JSON.stringify(root.data)); // deep clone
        if (d[section] === undefined || d[section] === null) d[section] = {};
        d[section][key] = value;
        root.data = d;
        save();
        root.changed();
    }

    // Replace a whole section (e.g. the keybinds array) and persist.
    function setSection(section, value) {
        var d = JSON.parse(JSON.stringify(root.data));
        d[section] = value;
        root.data = d;
        save();
        root.changed();
    }

    function save() {
        // atomicWrites is on by default -> temp file + rename, no corruption.
        root._lastWritten = JSON.stringify(root.data, null, 2) + "\n";
        file.setText(root._lastWritten);
    }
}
