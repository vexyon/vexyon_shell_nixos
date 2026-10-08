pragma Singleton

import QtQuick
import Quickshell
import Quickshell.Services.Pipewire

// Default audio sink (output) volume/mute. UI never touches Pipewire directly.
//
// Volume scale. PipeWire's own volume (node.audio.volume, the % that
// pavucontrol and wpctl show) is cubic: gain = v³. Its bottom 8% is −66 dB…−∞
// and plays as silence; a 16-bit sink outputs only zero samples at ≤6% for
// music-level audio (measured). Every output volume the shell shows or sets
// goes through toNode()/fromNode() instead:
//   - From knee (e/10 = 27.2%) up, it is that same cubic scale, unchanged.
//   - Below the knee it falls linearly in dB down to −60 dB (node 0.1), so 1%
//     is the quietest audible step and only 0% is silence.
//   - Both parts meet with the same slope, so the slider has no kink.
// Inputs (Mic) keep PipeWire's scale.
Singleton {
    id: root

    readonly property PwNode sink: Pipewire.defaultAudioSink
    readonly property bool ready: sink !== null && sink.audio !== null
    readonly property real volume: ready ? fromNode(sink.audio.volume) : 0
    readonly property bool muted: ready ? sink.audio.muted : false
    readonly property int percent: ready ? nodePercent(sink) : 0

    readonly property real lowGain: 0.1             // node volume at the shell's 0+: 0.1³ = −60 dB
    readonly property real knee: Math.E * lowGain   // 0.272: where the dB line is tangent to v³

    // shell scale (0..1) -> PipeWire node volume. Under half a percent (shown
    // as 0%, or float residue of 5% − 5%) is silence, not the −60 dB step.
    function toNode(v) {
        if (!(v >= 0.005)) return 0;
        return v >= knee ? v : lowGain * Math.exp(v / knee);
    }
    // PipeWire node volume -> shell scale. Below −60 dB reads as 0.
    function fromNode(v) {
        if (!(v > lowGain)) return 0;
        return v >= knee ? v : knee * Math.log(v / lowGain);
    }
    function nodeVolume(n) { return n && n.audio ? fromNode(n.audio.volume) : 0; }
    // Only a node at exactly 0 reads 0%.
    function nodePercent(n) {
        if (!n || !n.audio || !(n.audio.volume > 0)) return 0;
        return Math.max(1, Math.round(fromNode(n.audio.volume) * 100));
    }
    function setNodeVolume(n, v) {
        if (n && n.audio) n.audio.volume = toNode(Math.max(0, Math.min(1, v)));
    }

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

    function setVolume(v) { if (ready) setNodeVolume(sink, v); }
    function step(delta) { setVolume(volume + delta); }
    function toggleMute() { if (ready) sink.audio.muted = !sink.audio.muted; }
}
