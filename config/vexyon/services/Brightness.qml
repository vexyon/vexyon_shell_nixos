pragma Singleton

import QtQuick
import Quickshell
import Quickshell.Io

// Screen backlight via brightnessctl. Also the backend the Control Center slider
// writes to. Falls back gracefully if no backlight device exists (VMs).
Singleton {
    id: root

    property int percent: 100
    property bool available: true

    Process {
        id: reader
        command: ["bash", "-c",
            "brightnessctl -m 2>/dev/null | awk -F, '{print $4}' | tr -d '%'"]
        running: true
        stdout: StdioCollector {
            onStreamFinished: {
                var s = this.text.trim();
                if (s === "") { root.available = false; return; }
                var v = parseInt(s);
                if (!isNaN(v)) { root.percent = v; root.available = true; }
            }
        }
    }

    // Solo re-sondear mientras exista backlight: en escritorios/VMs la primera
    // lectura marca available=false y el poll (spawn de bash+awk cada 3s) se
    // apaga para siempre — un backlight no aparece en caliente.
    Timer {
        interval: 3000; running: root.available; repeat: true
        onTriggered: reader.running = true
    }

    function set(p) {
        p = Math.max(1, Math.min(100, Math.round(p)));
        root.percent = p;
        Quickshell.execDetached(["brightnessctl", "set", p + "%"]);
    }
    function step(delta) { set(root.percent + delta); }
}
