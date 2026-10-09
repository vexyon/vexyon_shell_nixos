pragma Singleton

import QtQuick
import Quickshell
import Quickshell.Io

// Screen backlight via brightnessctl. Also the backend the Control Center slider
// writes to. Falls back gracefully if no backlight device exists (VMs).
//
// Reading costs no process: brightnessctl runs ONCE to say which device it
// drives (and its maximum); from then on the current value is that device's
// sysfs `brightness` file, read inside the shell every 3 s — same cadence as
// before, so a change made outside the shell (Fn keys handled by firmware,
// another tool) still pops the OSD. Before, each tick was bash + brightnessctl
// + awk + tr: ~80 processes a minute on every laptop. Writing still goes
// through brightnessctl (it handles permissions via logind).
Singleton {
    id: root

    property int percent: 100
    property bool available: true
    property int _max: 0

    Process {
        id: probe
        command: ["brightnessctl", "-m"]
        running: true
        stdout: StdioCollector {
            onStreamFinished: {
                // device,class,current,percent%,max
                var f = this.text.trim().split("\n")[0].split(",");
                var max = parseInt(f[4]);
                if (f.length < 5 || !(max > 0)) { root.available = false; return; }
                root._max = max;
                root.percent = parseInt(f[3]) || root.percent;
                sysFv.path = "/sys/class/" + f[1] + "/" + f[0] + "/brightness";
                root.available = true;
            }
        }
        onExited: function(code) { if (code !== 0 && root._max === 0) root.available = false; }
    }

    FileView { id: sysFv; blockLoading: true; printErrors: false }

    // Solo mientras exista backlight: en escritorios/VMs la primera lectura
    // marca available=false y no hay nada que mirar (un backlight no aparece
    // en caliente).
    Timer {
        interval: 3000; running: root.available && root._max > 0; repeat: true
        onTriggered: {
            sysFv.reload();
            var v = parseInt(sysFv.text());
            if (!isNaN(v)) root.percent = Math.round(100 * v / root._max);
        }
    }

    function set(p) {
        p = Math.max(1, Math.min(100, Math.round(p)));
        root.percent = p;
        Quickshell.execDetached(["brightnessctl", "set", p + "%"]);
    }
    function step(delta) { set(root.percent + delta); }
}
