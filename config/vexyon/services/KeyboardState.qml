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
    // Re-query on Hyprland's own events (no poll): `activelayout` on every
    // switch, `configreloaded` when Settings rewrites the keyboard config, and
    // whenever a consumer appears. The old 4 s "safety poll" (bash + hyprctl +
    // jq + head) repeated what these events already say.
    Connections {
        target: Hyprland
        function onRawEvent(e) {
            if (root.watchers > 0 && (e.name === "activelayout" || e.name === "configreloaded"))
                kbLister.running = true;
        }
    }
    onWatchersChanged: if (watchers > 0) { kbLister.running = true; capsFind.running = true; }

    // ---- caps lock via /sys LED ----
    //  The LED file is looked up when a consumer appears (its inputN number
    //  depends on the keyboard), then read inside the shell every 500 ms — before, every
    //  read was bash + cat + head: 6 processes a second while the lock screen
    //  or a caps/keyboard widget was showing.
    Process {
        id: capsFind
        command: ["bash", "-c", "for f in /sys/class/leds/*capslock*/brightness; do [ -e \"$f\" ] && echo \"$f\" && break; done"]
        stdout: StdioCollector { onStreamFinished: capsFv.path = this.text.trim() }
    }
    FileView { id: capsFv; blockLoading: true; printErrors: false }
    property int _capsMiss: 0
    Timer {
        interval: 500; running: root.watchers > 0; repeat: true; triggeredOnStart: true
        onTriggered: {
            var t = "";
            if (capsFv.path !== "") { capsFv.reload(); t = capsFv.text().trim(); }
            if (t !== "") { root._capsMiss = 0; root.capsOn = (t === "1"); return; }
            // Sin LED, o el teclado se desenchufó y al volver su inputN es
            // otro (el fichero ya no existe → texto vacío): se busca de nuevo
            // cada ~10 s, no en cada tick, como hacía el glob de antes.
            root.capsOn = false;
            if (root._capsMiss++ % 20 === 0 && !capsFind.running) capsFind.running = true;
        }
    }

    // switch to next configured layout
    // switchxkblayout NO existe como dispatcher Lua: bajo el root Lua la cadena
    // hyprlang falla con `')' expected near 'current'`. Sí existe como COMANDO
    // directo de hyprctl, que no pasa por el parser Lua — esa es la vía viva.
    Process { id: kbCycler; command: ["hyprctl", "switchxkblayout", "current", "next"] }
    function cycle() { kbCycler.running = true; kbLister.running = true; }
}
