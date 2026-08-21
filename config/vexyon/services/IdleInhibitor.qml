pragma Singleton

import QtQuick
import Quickshell
import Quickshell.Io

// Idle inhibitor toggle. When active, holds a systemd idle+sleep inhibitor lock
// (a long-lived `systemd-inhibit … sleep infinity` child) so the session won't
// idle-suspend or blank. Toggling off kills the child, releasing the lock.
Singleton {
    id: root
    property bool active: false

    Process {
        id: holder
        command: ["systemd-inhibit", "--what=idle:sleep",
                  "--who=Vexyon", "--why=Manual inhibition", "sleep", "infinity"]
        running: false
    }

    function toggle() { setActive(!root.active); }
    function setActive(v) {
        root.active = v;
        holder.running = v;    // starting spawns the lock; stopping kills the child
    }
}
