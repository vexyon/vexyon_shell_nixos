pragma Singleton

import QtQuick
import Quickshell
import qs.services

// OSD state for the transient volume/brightness/mic indicator (rendered by
// modules/OsdOverlay.qml). Shown explicitly by the multimedia GlobalShortcuts
// and, DMS-style, by ANY server-side change (headset volume wheel, AVRCP,
// wpctl from a terminal) via the Connections below — no polling, pure events.
Singleton {
    id: root

    // "volume" | "brightness" | "mic"
    property string kind: "volume"
    property bool shown: false

    // Swallow the property-change burst while PipeWire/brightnessctl initialise
    // at login, so the OSD never flashes on session start.
    property bool armed: false
    Timer { interval: 3000; running: true; onTriggered: root.armed = true }

    Timer { id: hideTimer; interval: 2500; onTriggered: root.shown = false }

    // Panels whose sliders write volume/brightness — while one is open the
    // slider itself is the feedback, popping the OSD on top would be noise.
    readonly property bool suppressed: Panels.quickSettings || Panels.volumePanel
                                       || Panels.batteryPanel || Panels.settings

    function show(what) {
        if (root.suppressed) return;
        root.kind = what;
        root.shown = true;
        hideTimer.restart();
    }
    function hide() { hideTimer.stop(); root.shown = false; }

    // External volume/mute changes (any origin) pop the OSD too.
    Connections {
        target: Audio.sink !== null ? Audio.sink.audio : null
        function onVolumeChanged() { if (root.armed) root.show("volume"); }
        function onMutedChanged()  { if (root.armed) root.show("volume"); }
    }
    Connections {
        target: Mic.source !== null ? Mic.source.audio : null
        function onMutedChanged() { if (root.armed) root.show("mic"); }
    }
    Connections {
        target: Brightness
        function onPercentChanged() { if (root.armed) root.show("brightness"); }
    }
}
