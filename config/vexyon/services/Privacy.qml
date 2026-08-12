pragma Singleton

import QtQuick
import Quickshell
import Quickshell.Io

// Privacy indicator: is the microphone or camera currently being captured by an
// application? Mic via PipeWire source-outputs; camera via an open /dev/video*
// handle. Screen-share detection is left out (needs portal introspection).
Singleton {
    id: root

    property bool micInUse: false
    property bool camInUse: false
    readonly property bool active: micInUse || camInUse

    // Refcount de consumidores (widgets de privacidad instanciados). Sin
    // ninguno, el poll de pactl/fuser no corre — no gastar CPU en un dato
    // que nada muestra. triggeredOnStart => primer dato inmediato al añadirse.
    property int watchers: 0

    Timer { interval: 2000; running: root.watchers > 0; repeat: true; triggeredOnStart: true; onTriggered: poller.running = true }

    Process {
        id: poller
        command: ["bash", "-c",
            "m=$(pactl list source-outputs 2>/dev/null | grep -c 'Source Output #'); " +
            "c=0; for d in /dev/video*; do [ -e \"$d\" ] || continue; " +
              "fuser \"$d\" >/dev/null 2>&1 && c=1; done; echo \"$m $c\""]
        stdout: StdioCollector {
            onStreamFinished: {
                var p = this.text.trim().split(/\s+/);
                root.micInUse = (parseInt(p[0]) || 0) > 0;
                root.camInUse = (parseInt(p[1]) || 0) > 0;
            }
        }
    }
}
