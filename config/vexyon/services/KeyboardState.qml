pragma Singleton

import QtQuick
import Quickshell
import Quickshell.Io
import Quickshell.Hyprland

// Keyboard layout (active keymap short name) + Caps Lock indicator. Layout comes
// from Hyprland's main keyboard; Caps state from the kernel LED sysfs node.
Singleton {
    id: root

    property string layout: ""     // e.g. "es", "us"
    property bool capsOn: false

    // Refcount de consumidores (widgets capslock/keyboardlayout + la pantalla
    // de bloqueo). Sin ninguno, ni el poll de caps (500ms) ni el de layout
    // corren — el evento activelayout de Hyprland sigue escuchándose gratis.
    property int watchers: 0

    // ---- layout via hyprctl devices ----
    Process {
        id: kbLister
        command: ["bash", "-c",
            "hyprctl devices -j | jq -r '.keyboards[] | select(.main==true) | .active_keymap' 2>/dev/null | head -1"]
        stdout: StdioCollector {
            onStreamFinished: {
                var s = this.text.trim();
                if (s === "" || s === "null") return;
                // shorten "Spanish" / "English (US)" to a 2-letter-ish tag
                var map = { "spanish": "ES", "english (us)": "US", "english": "EN",
                            "catalan": "CA", "french": "FR", "german": "DE" };
                var k = s.toLowerCase();
                root.layout = map[k] || s.substring(0, 3).toUpperCase();
            }
        }
    }
    // re-query on Hyprland layout-change events + a slow safety poll
    Connections {
        target: Hyprland
        function onRawEvent(e) { if (e.name === "activelayout") kbLister.running = true; }
    }
    Timer { interval: 4000; running: root.watchers > 0; repeat: true; triggeredOnStart: true; onTriggered: kbLister.running = true }

    // ---- caps lock via /sys LED ----
    Process {
        id: capsReader
        command: ["bash", "-c", "cat /sys/class/leds/*capslock*/brightness 2>/dev/null | head -1"]
        stdout: StdioCollector { onStreamFinished: root.capsOn = (this.text.trim() === "1"); }
    }
    Timer { interval: 500; running: root.watchers > 0; repeat: true; triggeredOnStart: true; onTriggered: capsReader.running = true }

    // switch to next configured layout
    function cycle() { Hyprland.dispatch("switchxkblayout current next"); kbLister.running = true; }
}
