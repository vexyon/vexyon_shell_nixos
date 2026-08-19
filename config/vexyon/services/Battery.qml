pragma Singleton

import QtQuick
import Quickshell
import Quickshell.Services.UPower

// Laptop battery state via UPower. `present` is false on desktops -> bar hides it.
Singleton {
    id: root

    readonly property UPowerDevice dev: UPower.displayDevice
    readonly property bool present: dev !== null && dev.isLaptopBattery
    // UPowerDevice.percentage is a 0.0–1.0 fraction, NOT 0–100.
    readonly property int percent: dev !== null ? Math.max(0, Math.min(100, Math.round(dev.percentage * 100))) : 0
    readonly property int stateEnum: dev !== null ? dev.state : 0
    readonly property bool charging: stateEnum === UPowerDeviceState.Charging
                                     || stateEnum === UPowerDeviceState.FullyCharged
    readonly property bool full: stateEnum === UPowerDeviceState.FullyCharged
    // seconds; 0 when not applicable
    readonly property real timeToEmpty: dev !== null ? dev.timeToEmpty : 0
    readonly property real timeToFull: dev !== null ? dev.timeToFull : 0
}
