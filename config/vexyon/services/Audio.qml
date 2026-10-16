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
        ? Pipewire.nodes.values.filter(function(n) { return n && n.audio && n.isSink && !n.isStream && !root.isRecorderNode(n); })
        : []
    readonly property string sinkName: root.nodeLabel(root.sink)

    // Streams de reproducción (sink-inputs) para la pestaña "Streams" del
    // panel de volumen — nodos de app, no dispositivos.
    readonly property var streams: Pipewire.ready && Pipewire.nodes && Pipewire.nodes.values
        ? Pipewire.nodes.values.filter(function(n) { return n && n.audio && n.isSink && n.isStream && !root.isRecorderNode(n); })
        : []
    // The recorder's temporary "system + microphone" mix (Recorder._script):
    // a null sink and two loopbacks that exist only while recording. Not
    // devices or apps the user should see or pick in the volume panel.
    function isRecorderNode(n) { return !!n && !!n.name && n.name.indexOf("vexyon_rec_") === 0; }

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

    // ---- sound from one side only after boot ----------------------------------
    //  Reported on a hybrid laptop (NixOS): after login only one side played
    //  until the volume was moved once. Moving it makes PipeWire rewrite the
    //  device's mixer for EVERY channel — and that is what the restored state
    //  lacked: either a side restored at zero, or an amplifier that only takes
    //  its setting on a mixer write. So, once per output and per session, as
    //  soon as its channel volumes are known, the shell does that write itself:
    //   * a side at (near) zero while another plays → every channel to the
    //     level of the one that plays (that is not a balance anyone picks);
    //   * otherwise the same per-channel values a hair down and straight back,
    //     so a deliberate balance is kept. Never louder than before.
    //  Muted or at 0 it is left alone. No timer runs except the one-shot that
    //  lets the OSD ignore the echo of these writes (`settling`).
    //
    //  Not enough on its own (reported again with a Corsair HS80 MAX, a 2.4 GHz
    //  USB dongle): the volume keys fix it although Quickshell's `volume`
    //  setter keeps the channels' RATIO — so PipeWire's channel volumes were
    //  never uneven; the dongle simply had not applied the mixer, and it can
    //  lose it again after the write at login (headset linking up later, the
    //  device resumed after PipeWire suspended it while idle). So the same
    //  write is made again whenever playback STARTS on the default output
    //  (its first link turns active: an event, nothing polled), at most once
    //  every 20 s. The values written back are the ones read: inaudible.
    property int _settledId: -1
    property bool settling: false
    property var _settleOff: null       // phase 1 written, waiting for PipeWire to confirm it
    property var _settleFinal: null     // what phase 2 writes back
    property var _settleNode: null      // the output both phases write to
    onSinkChanged: root._settle()
    Connections {
        target: root.sink
        function onReadyChanged() { root._settle(); }
    }
    Connections {
        target: root.ready ? root.sink.audio : null
        function onVolumesChanged() { root._settle(); }
    }
    PwNodeLinkTracker { id: sinkLinks; node: root.sink }
    // A link group's state is only kept up to date while it is bound.
    PwObjectTracker { objects: sinkLinks.linkGroups }
    readonly property bool playing: {
        var gs = sinkLinks.linkGroups;
        for (var i = 0; i < gs.length; i++) if (gs[i] && gs[i].state === PwLinkState.Active) return true;
        return false;
    }
    property real _lastNudge: 0
    onPlayingChanged: {
        if (!root.playing || !root.ready) return;
        var now = Date.now();
        if (now - root._lastNudge < 20000) return;
        root._lastNudge = now;
        root._settle(true);
    }

    function _settle(force) {
        if (!root.ready || !root.sink.ready) return;
        var a = root.sink.audio, vs = a.volumes;
        if (root._settleFinal !== null) {
            //  Phase 2 only once PipeWire reports phase 1: written back to
            //  back, Quickshell drops the second write (it matches the value
            //  it still holds) and nothing reaches the mixer (measured).
            //  (Another output became the default meanwhile: the timer
            //  finishes the first one; this one is settled after that.)
            if (root.sink !== root._settleNode) return;
            var hit = vs && vs.length === root._settleOff.length;
            for (var k = 0; hit && k < vs.length; k++) hit = Math.abs(vs[k] - root._settleOff[k]) < 0.002;
            if (hit) root._settleFinish();
            return;
        }
        if (root.sink.id === root._settledId && force !== true) return;
        if (!vs || vs.length === 0) return;        // not known yet: wait for volumesChanged
        root._settledId = root.sink.id;
        var hi = 0, lo = 1;
        for (var i = 0; i < vs.length; i++) { hi = Math.max(hi, vs[i]); lo = Math.min(lo, vs[i]); }
        if (a.muted || !(hi > 0)) return;
        //  Per-channel writes (`volumes`), never `volume`: Quickshell's
        //  `volume` setter scales the channels to a new AVERAGE, keeping their
        //  ratio — on [0.5, 0] it gave [1.0, 0] (measured): louder, still one-sided.
        var even = vs.length > 1 && lo < 0.01 && hi > 0.05;
        var fin = [], off = [];
        for (var j = 0; j < vs.length; j++) {
            fin.push(even ? hi : vs[j]);
            off.push(Math.max(0, fin[j] - 0.01));
        }
        root.settling = true;
        root._settleOff = off;
        root._settleFinal = fin;
        root._settleNode = root.sink;
        a.volumes = off;
        settleEnd.restart();                     // phase 2 anyway if no confirmation in 1 s
    }
    function _settleFinish() {
        if (root._settleFinal === null) return;
        var fin = root._settleFinal, node = root._settleNode;
        root._settleFinal = null;
        root._settleOff = null;
        root._settleNode = null;
        if (node && node.ready && node.audio) node.audio.volumes = fin;
        settleEnd.restart();                     // `settling` ends 1 s after the last write
        root._settle();                          // an output that became default meanwhile
    }
    Timer {
        id: settleEnd
        interval: 1000
        onTriggered: {
            if (root._settleFinal !== null) root._settleFinish();
            else root.settling = false;
        }
    }
}
