pragma Singleton

import QtQuick
import Quickshell
import qs.services

// ============================================================================
//  Places — the File Manager sidebar's locations, shared by every window.
//
//  * Built-in places: Home plus the standard folders found by their NAME in
//    $HOME, in the shell's language — Desktop, Documents, Downloads,
//    Pictures, Music, Videos in English; Escritorio, Documentos, Descargas,
//    Imágenes, Música, Vídeos in Spanish. Each row shows the folder's real
//    name and opens that folder; a missing one is not listed. Switching the
//    language renames, moves or creates nothing: the rows of the other
//    language just stop showing until such a folder exists. (user-dirs.dirs
//    is not used for this: it can point somewhere else than the folder the
//    user actually has.) The folders are created ONCE per user by
//    initUserDirs(), in the language picked at the first start.
//  * Bookmarks: the GTK bookmarks file (~/.config/gtk-3.0/bookmarks), the one
//    GTK file choosers, Nautilus, Thunar and Nemo already use. Adding one
//    writes a line there — no symlink, nothing inside the folder — and
//    removing one deletes that line only, never the folder. Existing lines,
//    including ones Vexyon cannot show (sftp://, smb://), are kept.
//
//  Read when a File Manager window opens and after every change made here, so
//  all windows of this shell see a change at once; edits made by another
//  program show up at the next window open. No watcher, no polling.
// ============================================================================
Singleton {
    id: root

    readonly property string home: Quickshell.env("HOME")
    property var dirs: ({})          // user-dirs.dirs: XDG key -> { path, exists }
    property var std: []             // standard folders by name: [{ key, path, name }]
    property var bookmarks: []       // [{ path, label, exists }]
    property bool ready: false
    property bool _loading: false
    property bool _again: false

    //  The default symbol of each user folder (FolderIcons catalog ids).
    readonly property var xdgIcons: ({
        DESKTOP: "monitor", DOCUMENTS: "file-document", DOWNLOAD: "download",
        PICTURES: "image", MUSIC: "music", VIDEOS: "play",
        TEMPLATES: "pencil-ruler", PUBLICSHARE: "share-variant", PROJECTS: "code-braces"
    })

    //  path -> XDG key, for the default emblem of a folder anywhere it shows:
    //  the folders found by name and the ones user-dirs.dirs names.
    readonly property var byPath: {
        var m = {};
        for (var k in root.dirs) m[root.dirs[k].path] = k;
        for (var i = 0; i < root.std.length; i++) m[root.std[i].path] = root.std[i].key;
        return m;
    }

    //  Built-in sidebar rows: Home, then the standard folders that exist, under
    //  their real name.
    readonly property var builtin: {
        var out = [{ key: "HOME", path: root.home, label: I18n.t("Home"), exists: true }];
        for (var i = 0; i < root.std.length; i++)
            out.push({ key: root.std[i].key, path: root.std[i].path, label: root.std[i].name, exists: true });
        return out;
    }
    //  A standard folder's path (the one shown in the sidebar), or "".
    function stdPath(key) {
        for (var i = 0; i < root.std.length; i++) if (root.std[i].key === key) return root.std[i].path;
        var d = root.dirs[key];
        return (d && d.exists) ? d.path : "";
    }

    function basename(p) { var s = p.replace(/\/+$/, ""); return s.substring(s.lastIndexOf("/") + 1) || "/"; }
    function isBuiltin(p) {
        if (p === root.home) return true;
        for (var i = 0; i < root.std.length; i++) if (root.std[i].path === p) return true;
        return false;
    }
    function isBookmarked(p) {
        for (var i = 0; i < root.bookmarks.length; i++)
            if (root.bookmarks[i].path === p) return true;
        return false;
    }
    function inSidebar(p) { return root.isBuiltin(p) || root.isBookmarked(p); }

    function _apply(r) {
        if (!r || r.error) return;
        root.dirs = r.dirs || ({});
        root.std = r.std || [];
        root.bookmarks = r.bookmarks || [];
        root.ready = true;
    }
    //  Every call says the shell's language: it decides which folder names
    //  are the standard ones.
    function _run(args, cb) { FmHelper.run(["--lang", I18n.lang].concat(args), cb); }

    //  The language changed: the standard folders are others now. One read,
    //  only if the sidebar was ever loaded.
    Connections {
        target: I18n
        function onLangChanged() { if (root.ready) root.refresh(); }
    }

    function refresh() {
        if (root._loading) { root._again = true; return; }
        root._loading = true;
        root._run(["places"], function(r) {
            root._loading = false;
            root._apply(r);
            if (root._again) { root._again = false; root.refresh(); }
        });
    }

    //  cb(added, rejected, ok): rejected = [{ path, why }] with why one of
    //  "notdir", "builtin", "duplicate", "invalid"; ok false = the helper
    //  did not answer (nothing was added), never a silent no-op.
    function add(paths, at, cb) {
        if (!paths || !paths.length) return;
        var args = ["bm-add"];
        if (at !== undefined && at !== null && at >= 0) args.push("--at", String(at));
        root._run(args.concat(paths), function(r, code) {
            root._apply(r);
            var ok = !!r && !r.error && code === 0;
            if (cb) cb(r && r.added ? r.added : [], r && r.rejected ? r.rejected : [], ok);
        });
    }
    function remove(path) { root._run(["bm-remove", path], root._apply); }
    //  Vexyon renamed or moved `from`: bookmarks of it (or of folders inside
    //  it) follow, keeping their place and label.
    function moved(from, to) {
        for (var i = 0; i < root.bookmarks.length; i++) {
            var p = root.bookmarks[i].path;
            if (p === from || p.indexOf(from + "/") === 0) {
                root._run(["bm-moved", from, to], root._apply);
                return;
            }
        }
    }
    function move(path, index) { root._run(["bm-move", path, String(index)], root._apply); }

    //  The user folders (Desktop/Escritorio, Downloads/Descargas…), created
    //  ONCE per user and never again: shell.qml calls this as soon as the
    //  welcome screen is closed — so in the language picked there — or, on an
    //  install that already went past it, at the first start of this version.
    //  The helper leaves an existing user-dirs.dirs alone and stops
    //  xdg-user-dirs-update from recreating or renaming them later. The mark
    //  (state.userDirsInit) is only set once the helper has answered, so a
    //  failed run is tried again at the next start, not on a timer.
    property bool _initRunning: false
    function initUserDirs() {
        if (root._initRunning || Config.get("state", "userDirsInit", false) === true) return;
        root._initRunning = true;
        FmHelper.run(["user-dirs-init", I18n.lang], function(r, code) {
            root._initRunning = false;
            if (code !== 0 || !r) return;
            //  Folders made just now: the shell's own folders go inside them
            //  (~/Imágenes/Capturas de pantalla in Spanish), unless the user
            //  already picked other ones (anything but the seed's value).
            var sd = r.shellDirs || {};
            var keys = [["behavior", "wallpaperDir", "~/Pictures/Wallpapers", sd.wallpapers],
                        ["behavior", "screenshotDir", "~/Pictures/Screenshots", sd.screenshots],
                        ["recording", "dir", "~/Videos/Recordings", sd.recordings]];
            for (var i = 0; i < keys.length; i++) {
                var k = keys[i];
                if (k[3] && Config.get(k[0], k[1], k[2]) === k[2]) Config.set(k[0], k[1], k[3]);
            }
            Config.set("state", "userDirsInit", true);
            if (root.ready) root.refresh();
        });
    }
}
