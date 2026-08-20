pragma Singleton

import QtQuick
import Quickshell
import Quickshell.Services.Pipewire

// Default audio sink (output) volume/mute. UI never touches Pipewire directly.
Singleton {
    id: root

    readonly property PwNode sink: Pipewire.defaultAudioSink
    readonly property bool ready: sink !== null && sink.audio !== null
    readonly property real volume: ready ? sink.audio.volume : 0
    readonly property bool muted: ready ? sink.audio.muted : false
    readonly property int percent: Math.round(volume * 100)

    // Available output devices (real sinks, not stream nodes) for the
    // audio-output drill-down. Tracked so their volume/description stay live.
    readonly property var sinks: Pipewire.ready && Pipewire.nodes && Pipewire.nodes.values
        ? Pipewire.nodes.values.filter(function(n) { return n && n.audio && n.isSink && !n.isStream; })
        : []
    readonly property string sinkName: root.nodeLabel(root.sink)

    // Streams de reproducción (sink-inputs) para la pestaña "Streams" del
    // panel de volumen — nodos de app, no dispositivos.
    readonly property var streams: Pipewire.ready && Pipewire.nodes && Pipewire.nodes.values
        ? Pipewire.nodes.values.filter(function(n) { return n && n.audio && n.isSink && n.isStream; })
        : []

    function streamLabel(n) {
        if (!n) return "";
        if (n.properties && n.properties["application.name"]) return n.properties["application.name"];
        return n.description || n.nickname || n.name || "";
    }

    function nodeLabel(n) {
        if (!n) return "";
        return n.description || n.nickname || n.name || "";
    }
    function isDefaultSink(n) { return n && root.sink && n.id === root.sink.id; }
    function setSink(n) { if (n) Pipewire.preferredDefaultAudioSink = n; }

    // Binding the default sink + every candidate sink so audio.* is valid.
    PwObjectTracker { objects: [Pipewire.defaultAudioSink].concat(root.sinks).concat(root.streams) }

    function setVolume(v) {
        if (!ready) return;
        sink.audio.volume = Math.max(0, Math.min(1, v));
    }
    function step(delta) { setVolume(volume + delta); }
    function toggleMute() { if (ready) sink.audio.muted = !sink.audio.muted; }
}
