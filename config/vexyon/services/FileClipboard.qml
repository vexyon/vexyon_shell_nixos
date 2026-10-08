pragma Singleton

import QtQuick
import Quickshell
import qs.services

// ============================================================================
//  FileClipboard — files on the SYSTEM clipboard, for every File Manager
//  window at once.
//
//  The bug this replaces: Ctrl+C stored the selection in a property of the
//  window it was pressed in, so a second window — or any other program — had
//  nothing to paste. Now Ctrl+C / Ctrl+X hand the files to the Wayland
//  clipboard (`vexyon-fm-helper clip-set`: text/uri-list served by wl-copy,
//  which outlives the window), and Ctrl+V reads whatever the clipboard holds
//  right now (`clip-get`): files copied in another Vexyon window, in another
//  Vexyon process, in Nautilus, Thunar, Dolphin…
//
//  This singleton only remembers the LAST state it saw, for the status bar,
//  the "Paste" menu entry and the dimmed look of cut items. It is refreshed on
//  request — our own copy/cut, a window opening, a context menu opening, a
//  paste — never by polling, so text copied in another program shows up at
//  the next of those moments.
// ============================================================================
Singleton {
    id: root

    property string mode: ""        // "copy" | "cut" | "" (no files)
    property var paths: []
    property var cutSet: ({})       // path -> true: shown dimmed
    property string error: ""
    property bool _probing: false

    function _apply(r) {
        if (!r || r.error) {
            root.mode = ""; root.paths = []; root.cutSet = ({});
            return;
        }
        root.mode = r.mode || "";
        root.paths = r.paths || [];
        var s = {};
        if (root.mode === "cut")
            for (var i = 0; i < root.paths.length; i++) s[root.paths[i]] = true;
        root.cutSet = s;
    }

    function _set(kind, list, cb) {
        if (!list || !list.length) return;
        root.error = "";
        FmHelper.run(["clip-set", kind].concat(list), function(r, code) {
            if (!r || r.error || code !== 0) {
                root.error = (r && r.error) ? r.error : I18n.t("The clipboard is not available.");
                if (cb) cb(false);
                return;
            }
            root._apply(r);
            if (cb) cb(true);
        });
    }
    function copy(list, cb) { root._set("copy", list, cb); }
    function cut(list, cb)  { root._set("cut", list, cb); }

    //  Re-read the clipboard (coalesced: one probe at a time is plenty).
    function probe() {
        if (root._probing) return;
        root._probing = true;
        FmHelper.run(["clip-get"], function(r) { root._probing = false; root._apply(r); });
    }

    //  For a paste: always the clipboard as it is NOW, never the remembered
    //  state. cb({ mode, paths, foreign }).
    function fetch(cb) {
        FmHelper.run(["clip-get"], function(r) {
            root._apply(r);
            cb(r && !r.error ? r : { mode: "", paths: [], foreign: 0 });
        });
    }

    //  A cut has been pasted: its files are on their way out of the place the
    //  clipboard points to. Take it off the clipboard (only if it is still that
    //  cut) so a second paste cannot trip over missing files.
    function consumed() {
        root.mode = ""; root.paths = []; root.cutSet = ({});
        FmHelper.run(["clip-done"], null);
    }
}
