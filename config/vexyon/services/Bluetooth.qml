pragma Singleton

import QtQuick
import Quickshell
import Quickshell.Bluetooth

// Bluetooth adapter state. `present` is false when there is no adapter, so the
// UI hides the control entirely rather than showing a dead icon.
Singleton {
    id: root

    readonly property var adapter: Bluetooth.defaultAdapter
    readonly property bool present: adapter !== null
    readonly property bool enabled: present && adapter.enabled
    // number of currently-connected devices
    readonly property int connectedCount: {
        if (!present) return 0;
        var n = 0;
        var devs = Bluetooth.devices ? Bluetooth.devices.values : [];
        for (var i = 0; i < devs.length; i++)
            if (devs[i] && devs[i].connected) n++;
        return n;
    }
    readonly property string firstDeviceName: {
        if (!present) return "";
        var devs = Bluetooth.devices ? Bluetooth.devices.values : [];
        for (var i = 0; i < devs.length; i++)
            if (devs[i] && devs[i].connected) return devs[i].name || "";
        return "";
    }

    // Full device list for the Bluetooth drill-down.
    readonly property var devices: Bluetooth.devices ? Bluetooth.devices.values : []
    readonly property bool discovering: present && adapter.discovering

    function toggle() { if (present) adapter.enabled = !adapter.enabled; }
    function scan(on) { if (present) adapter.discovering = (on === undefined ? !adapter.discovering : on); }
    function connectDevice(d) {
        if (!d) return;
        if (d.connected) d.disconnect(); else d.connect();
    }
    function deviceLabel(d) { return d ? (d.name || d.deviceName || d.address || "?") : ""; }
}
