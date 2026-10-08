pragma Singleton

import QtQuick
import Quickshell
import qs.services

// ============================================================================
//  Places — the File Manager sidebar's locations, shared by every window.
//
//  * Built-in places: Home plus the XDG user folders (Desktop, Documents,
//    Downloads, Pictures, Music, Videos) at the paths the user's
//    user-dirs.dirs configures — ~/Documentos, ~/Bilder… — never guessed from
//    English names. If that file does not exist yet, the helper runs
//    `xdg-user-dirs-update` once (the standard tool every desktop runs), which
//    creates only what is missing.
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
    property var dirs: ({})          // XDG key -> { path, exists }
    property var bookmarks: []       // [{ path, label, exists }]
    property bool ready: false
    property bool _loading: false
    property bool _again: false

    //  The XDG folders the sidebar shows, in this order (Nautilus's).
    readonly property var sidebarKeys: ["DESKTOP", "DOCUMENTS", "DOWNLOAD", "PICTURES", "MUSIC", "VIDEOS"]

    //  The default symbol of each user folder (FolderIcons catalog ids).
    readonly property var xdgIcons: ({
        DESKTOP: "monitor", DOCUMENTS: "file-document", DOWNLOAD: "download",
        PICTURES: "image", MUSIC: "music", VIDEOS: "play",
        TEMPLATES: "pencil-ruler", PUBLICSHARE: "share-variant", PROJECTS: "code-braces"
    })

    //  path -> XDG key, for the default emblem of a folder anywhere it shows.
    readonly property var byPath: {
        var m = {};
        for (var k in root.dirs) m[root.dirs[k].path] = k;
        return m;
    }

    //  Built-in sidebar rows: Home, then the user folders that exist.
    readonly property var builtin: {
        var out = [{ key: "HOME", path: root.home, label: I18n.t("Home"), exists: true }];
        for (var i = 0; i < root.sidebarKeys.length; i++) {
            var d = root.dirs[root.sidebarKeys[i]];
            if (d && d.exists)
                out.push({ key: root.sidebarKeys[i], path: d.path, label: root.basename(d.path), exists: true });
        }
        return out;
    }

    function basename(p) { var s = p.replace(/\/+$/, ""); return s.substring(s.lastIndexOf("/") + 1) || "/"; }
    function isBuiltin(p) {
        if (p === root.home) return true;
        return root.byPath[p] !== undefined;
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
        root.bookmarks = r.bookmarks || [];
        root.ready = true;
    }

    function refresh() {
        if (root._loading) { root._again = true; return; }
        root._loading = true;
        FmHelper.run(["places"], function(r) {
            root._loading = false;
            root._apply(r);
            if (root._again) { root._again = false; root.refresh(); }
        });
    }

    //  cb(added, rejected): rejected = [{ path, why }] with why one of
    //  "notdir", "builtin", "duplicate", "invalid".
    function add(paths, at, cb) {
        if (!paths || !paths.length) return;
        var args = ["bm-add"];
        if (at !== undefined && at !== null && at >= 0) args.push("--at", String(at));
        FmHelper.run(args.concat(paths), function(r) {
            root._apply(r);
            if (cb) cb(r && r.added ? r.added : [], r && r.rejected ? r.rejected : []);
        });
    }
    function remove(path) { FmHelper.run(["bm-remove", path], root._apply); }
    //  Vexyon renamed or moved `from`: bookmarks of it (or of folders inside
    //  it) follow, keeping their place and label.
    function moved(from, to) {
        for (var i = 0; i < root.bookmarks.length; i++) {
            var p = root.bookmarks[i].path;
            if (p === from || p.indexOf(from + "/") === 0) {
                FmHelper.run(["bm-moved", from, to], root._apply);
                return;
            }
        }
    }
    function move(path, index) { FmHelper.run(["bm-move", path, String(index)], root._apply); }
}
