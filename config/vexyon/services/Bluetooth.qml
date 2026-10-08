pragma Singleton

import QtQuick
import Quickshell
import Quickshell.Bluetooth as QsBt
import qs.services

// Bluetooth adapter state. `present` is false when there is no adapter, so the
// UI hides the control entirely rather than showing a dead icon.
//
// Optional module (Settings → Modules → Bluetooth). While it is off this
// session, QsBt.Bluetooth is never touched: that object is the BlueZ D-Bus
// client, and touching it asks D-Bus for org.bluez — an activation request
// for a bluetooth.service the boot left off on purpose.
Singleton {
    id: root

    readonly property bool moduleOn: Modules.bluetoothOn
    // Known to be off (not just "status not read yet"), for UI wording.
    readonly property bool moduleOff: Modules.ready && !Modules.bluetoothOn
    readonly property var adapter: root.moduleOn ? QsBt.Bluetooth.defaultAdapter : null
    readonly property bool present: adapter !== null
    readonly property bool enabled: present && adapter.enabled
    // number of currently-connected devices
    readonly property int connectedCount: {
        if (!present) return 0;
        var n = 0;
        var devs = QsBt.Bluetooth.devices ? QsBt.Bluetooth.devices.values : [];
        for (var i = 0; i < devs.length; i++)
            if (devs[i] && devs[i].connected) n++;
        return n;
    }
    readonly property string firstDeviceName: {
        if (!present) return "";
        var devs = QsBt.Bluetooth.devices ? QsBt.Bluetooth.devices.values : [];
        for (var i = 0; i < devs.length; i++)
            if (devs[i] && devs[i].connected) return devs[i].name || "";
        return "";
    }

    // Full device list for the Bluetooth drill-down.
    readonly property var devices: root.moduleOn && QsBt.Bluetooth.devices ? QsBt.Bluetooth.devices.values : []
    readonly property bool discovering: present && adapter.discovering

    function toggle() { if (present) adapter.enabled = !adapter.enabled; }
    function scan(on) { if (present) adapter.discovering = (on === undefined ? !adapter.discovering : on); }
    function connectDevice(d) {
        if (!d) return;
        if (d.connected) d.disconnect(); else d.connect();
    }
    function deviceLabel(d) { return d ? (d.name || d.deviceName || d.address || "?") : ""; }
}
