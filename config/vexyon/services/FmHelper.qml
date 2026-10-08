pragma Singleton

import QtQuick
import Quickshell
import Quickshell.Io

// ============================================================================
//  FmHelper — runs `vexyon-fm-helper` for the File Manager services
//  (FileClipboard, Places, FolderIcons).
//
//  One short-lived process per call, created for that call and destroyed when
//  it has answered: two windows asking at the same moment never share (and
//  never clobber) a Process. The helper prints one line of JSON; the callback
//  gets it parsed (or null) plus the exit code. Nothing runs between calls.
// ============================================================================
Singleton {
    id: root

    // Same resolution as the other helpers: VEXYON_BIN_DIR on NixOS (store
    // wrapper with its PATH baked in), the deployed tree on Arch.
    readonly property string bin: {
        var d = Quickshell.env("VEXYON_BIN_DIR");
        var base = (d && d !== "") ? d : Quickshell.env("HOME") + "/.config/vexyon/bin";
        return base + "/vexyon-fm-helper";
    }

    function run(args, cb) {
        var p = runner.createObject(root, { command: [root.bin].concat(args), cb: cb || null });
        if (p) p.running = true;
    }

    Component {
        id: runner
        Process {
            id: proc
            property var cb: null
            property string out: ""
            property bool gotOut: false
            property bool gotExit: false
            property int code: -1
            property bool done: false

            stdout: StdioCollector {
                onStreamFinished: { proc.out = this.text; proc.gotOut = true; proc.finish(); }
            }
            onExited: function(c) { proc.code = c; proc.gotExit = true; proc.finish(); }
            // A binary that cannot start never emits `exited`: `running` just
            // drops back to false. Answer anyway, or the caller waits forever.
            // (A normal exit has emitted `exited` by the time this runs.)
            onRunningChanged: if (!running) {
                var self = proc;
                Qt.callLater(function() {
                    if (self.done || self.gotExit) return;
                    self.gotOut = true; self.gotExit = true; self.code = 127;
                    self.finish();
                });
            }

            function finish() {
                if (proc.done || !proc.gotOut || !proc.gotExit) return;
                proc.done = true;
                var obj = null;
                var lines = proc.out.trim().split("\n");
                try { obj = JSON.parse(lines[lines.length - 1] || "null"); } catch (e) { obj = null; }
                if (proc.cb) {
                    // The caller may be a window that has closed meanwhile.
                    try { proc.cb(obj, proc.code); } catch (e) { console.warn("[FmHelper]", e); }
                }
                // later, not now: the check above may still be queued
                proc.destroy(1000);
            }
        }
    }
}
