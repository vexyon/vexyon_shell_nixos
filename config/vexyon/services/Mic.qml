pragma Singleton

import QtQuick
import Quickshell
import Quickshell.Services.Pipewire

// Default audio source (microphone) volume/mute. UI never touches Pipewire directly.
Singleton {
    id: root

    readonly property PwNode source: Pipewire.defaultAudioSource
    readonly property bool ready: source !== null && source.audio !== null
    readonly property bool present: source !== null
    readonly property real volume: ready ? source.audio.volume : 0
    readonly property bool muted: ready ? source.audio.muted : false
    readonly property int percent: Math.round(volume * 100)

    // Available input devices for the microphone drill-down.
    readonly property var sources: Pipewire.ready && Pipewire.nodes && Pipewire.nodes.values
        ? Pipewire.nodes.values.filter(function(n) { return n && n.audio && !n.isSink && !n.isStream; })
        : []
    readonly property string sourceName: root.nodeLabel(root.source)

    function nodeLabel(n) {
        if (!n) return "";
        return n.description || n.nickname || n.name || "";
    }
    function isDefaultSource(n) { return n && root.source && n.id === root.source.id; }
    function setSource(n) { if (n) Pipewire.preferredDefaultAudioSource = n; }

    PwObjectTracker { objects: [Pipewire.defaultAudioSource].concat(root.sources) }

    function setVolume(v) {
        if (!ready) return;
        source.audio.volume = Math.max(0, Math.min(1, v));
    }
    function step(delta) { setVolume(volume + delta); }
    function toggleMute() { if (ready) source.audio.muted = !source.audio.muted; }
}
