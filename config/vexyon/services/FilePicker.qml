pragma Singleton

import QtQuick
import Quickshell

// ============================================================================
//  FilePicker — the Vexyon file manager as the file chooser of the whole
//  system. Whoever needs a file or a folder (an app through the desktop
//  portal → vexyon-portal, AirDrop, a script) runs `vexyon-pick`, which:
//    1. makes a FIFO at $XDG_RUNTIME_DIR/vexyon-pick/<id> and waits on it;
//    2. asks the shell: `qs ipc call vexyon pick <id> <json>` (shell.qml),
//       which opens a file manager window in pick mode (FileManager.qml:
//       pickMode file | files | folder | save, title, start folder, name,
//       filters);
//    3. reads the answer this singleton writes there: {"ok":true,"paths":[…]}
//       or {"ok":false} (cancelled, window closed).
//  Nothing runs between requests: no service, no watcher. The write is
//  bounded (timeout) so a requester that went away can never leave a
//  process blocked on its FIFO.
// ============================================================================
Singleton {
    id: root

    // vexyon-pick was stopped (the app withdrew its request): the window
    // with that id closes without answering (FileManager.qml listens).
    signal withdrawn(string id)

    function validId(id) { return typeof id === "string" && /^[A-Za-z0-9._-]{1,64}$/.test(id); }

    // paths: array of absolute paths, or null when cancelled.
    function reply(id, paths) {
        if (!root.validId(id)) return;
        var json = JSON.stringify(paths ? { ok: true, paths: paths } : { ok: false });
        var fifo = Quickshell.env("XDG_RUNTIME_DIR") + "/vexyon-pick/" + id;
        Quickshell.execDetached(["timeout", "10", "sh", "-c",
            '[ -p "$2" ] && printf "%s\\n" "$1" > "$2"', "sh", json, fifo]);
    }

    // The IPC request (shell.qml) → the window's initial properties.
    function options(json) {
        var o = {};
        try { o = JSON.parse(json) || {}; } catch (e) { o = {}; }
        var mode = ["file", "files", "folder", "save"].indexOf(o.mode) !== -1 ? o.mode : "file";
        var dir = typeof o.dir === "string" && o.dir.charAt(0) === "/" ? o.dir : Quickshell.env("HOME");
        var filters = [];
        if (Array.isArray(o.filters))
            for (var i = 0; i < o.filters.length && i < 32; i++) {
                var f = o.filters[i];
                if (f && typeof f.name === "string" && Array.isArray(f.patterns))
                    filters.push({ name: f.name, patterns: f.patterns.filter(function(p) { return typeof p === "string"; }) });
            }
        var cur = typeof o.filter === "number" && o.filter >= 0 && o.filter < filters.length ? o.filter : (filters.length ? 0 : -1);
        return {
            pickMode: mode,
            pickTitle: typeof o.title === "string" ? o.title : "",
            pickName: typeof o.name === "string" ? o.name : "",
            pickFilters: filters,
            pickFilter: cur,
            cwd: dir
        };
    }
}
