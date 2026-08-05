pragma Singleton

import QtQuick
import Quickshell

// Session-lock state. Kept separate from Panels (lock is modal & security-
// sensitive, not a toggle popup). Super+L and the power menu set locked=true.
Singleton {
    id: root
    property bool locked: false
    function lock() { root.locked = true; }
    function unlock() { root.locked = false; }
}
