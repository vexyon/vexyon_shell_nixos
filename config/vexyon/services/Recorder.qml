pragma Singleton

import QtQuick
import Quickshell
import Quickshell.Io
import Quickshell.Hyprland
import qs.services

// ============================================================================
//  Recorder — screen recording through `wf-recorder`. The ONLY door between
//  the shell and the recorder: the picker, the bar indicator and the Settings
//  page all read from here, and nobody else starts a recording.
//
//  Backend: wf-recorder, installed by Vexyon itself (install.sh on Arch, the
//  NixOS module) like every other dependency since 3.0. Settings → Screen
//  recording still detects it, so a broken install says what is missing.
//  Video comes from the compositor's screencopy protocol (the same one grim
//  uses for screenshots), sound from PipeWire through its PulseAudio server
//  (pipewire-pulse, already a shell dependency).
//
//  The switch is the "Screen recording" module (Settings → Modules,
//  services/Modules.qml). It is a session module: no service behind it, so
//  it applies at once.
//
//  ZERO COST WITH THE MODULE OFF — the rule above everything:
//   * No Process here has `running: true`. Each starts from a function, and
//     every public function returns early when `enabled` is false.
//   * No Timer at all. `recording` IS the recorder process's running state;
//     the bar indicator binds to it, so it appears when the process starts and
//     disappears when it exits — no polling. Elapsed seconds come from the
//     shared Time clock, which only ticks per second while someone (the
//     indicator, while it exists) holds a Time.ssWatchers reference.
//   * The places that must not create this singleton while the module is off
//     (bar, widget catalog, launcher, shell.qml, Settings) ask Modules first:
//     `Modules.recorderOn && Recorder.x` stops at the first operand, so the
//     singleton is never touched. Same rule as Vm.
// ============================================================================
Singleton {
    id: root

    // ---- switch and options (shell.json "recording") -------------------------
    //  `enabled` mirrors the module; `recording.enabled` stays the key in
    //  shell.json, so a choice made before 3.0 is kept.
    readonly property bool enabled: Modules.recorderOn
    readonly property string audio: Config.get("recording", "audio", "system")   // none | system | mic
    readonly property string format: Config.get("recording", "format", "mp4")    // mp4 | mkv
    readonly property string dir: Config.get("recording", "dir", "~/Videos/Recordings")
    readonly property string dirPath: root.dir.replace(/^~(?=\/|$)/, Quickshell.env("HOME"))
    readonly property string ext: root.format === "mkv" ? "mkv" : "mp4"

    // ---- detection (Settings page and picker) --------------------------------
    property bool detected: false
    property var has: ({ recorder: false, audio: false, pulse: false })
    property string version: ""
    property string osId: ""
    property string osLike: ""
    property string osName: ""
    // Same short list as Vm.platform: only families whose package names were
    // checked get package names; anything else gets the generic list.
    readonly property string platform: {
        var id = root.osId.toLowerCase();
        var like = " " + root.osLike.toLowerCase() + " ";
        if (id === "nixos") return "nixos";
        if (id === "arch" || id === "cachyos" || id === "endeavouros" || id === "manjaro"
            || id === "artix" || like.indexOf(" arch ") !== -1) return "arch";
        return "unknown";
    }
    readonly property bool ready: root.detected && root.has.recorder
    // Sound needs wf-recorder built with audio AND a PulseAudio-compatible
    // server to talk to. Without either, recordings are video only.
    readonly property bool soundOk: root.has.audio && root.has.pulse

    function detect() {
        if (!root.enabled) return;
        detector.running = true;
    }
    // Same race as Vm.prime(): a caller can run before Config has parsed
    // shell.json, while `enabled` still reads false. Remember the request and
    // serve it when `enabled` flips — a property change, not a timer.
    property bool _primeWanted: false
    function prime() {
        root._primeWanted = true;
        if (root.enabled && !detector.running) root.detect();
    }
    onEnabledChanged: {
        if (root.enabled && root._primeWanted) root.detect();
        // Switched off mid-recording: finish the file properly first.
        if (!root.enabled && proc.running) root.stop();
    }

    // ---- recording state ------------------------------------------------------
    readonly property bool recording: proc.running
    property bool stopping: false
    property double startedAt: 0       // ms epoch, set when wf-recorder is launched
    property string file: ""           // file being written
    property string target: ""         // "DP-1" or the region geometry
    property string lastFile: ""
    property string lastError: ""
    property var _err: []

    // Current shortcut, as the user has it in shell.json (it can be remapped).
    readonly property string shortcut: {
        var k = Config.keybinds;
        for (var i = 0; i < k.length; i++) {
            if (k[i].action !== "global" || k[i].arg !== "recorder") continue;
            var m = (k[i].mods || []).map(function(x) { return x.charAt(0) + x.slice(1).toLowerCase(); });
            return m.concat([k[i].key]).join("+");
        }
        return "";
    }

    function elapsed(nowMs) {
        if (root.startedAt <= 0) return "00:00";
        var s = Math.max(0, Math.floor((nowMs - root.startedAt) / 1000));
        var h = Math.floor(s / 3600), m = Math.floor((s % 3600) / 60);
        s = s % 60;
        var mm = (m < 10 ? "0" : "") + m, ss = (s < 10 ? "0" : "") + s;
        return h > 0 ? h + ":" + mm + ":" + ss : mm + ":" + ss;
    }

    // ---- actions -----------------------------------------------------------
    function focusedOutput() {
        var fm = Hyprland.focusedMonitor;
        if (fm) return fm.name;
        var scs = Quickshell.screens;
        return scs.length > 0 ? scs[0].name : "";
    }
    function startOutput(name) { if (name) root._launch(["-o", name], name); }
    // geom = "X,Y WxH" in global layout coordinates (what the region overlay
    // and grim use). wf-recorder finds the monitor that contains it.
    function startRegion(geom) {
        if (/^-?\d+,-?\d+ \d+x\d+$/.test(geom)) root._launch(["-g", geom], geom);
    }
    // Stop = close the recorder's stdin. The wrapper turns that EOF into a
    // clean SIGINT (see _script). The same EOF happens if the shell dies or
    // reloads, so wf-recorder never outlives it.
    function stop() {
        if (!proc.running || root.stopping) return;
        root.stopping = true;
        proc.stdinEnabled = false;
    }

    function _launch(args, label) {
        if (!root.enabled || proc.running) return;
        root.lastError = ""; root.lastFile = ""; root.file = "";
        root.startedAt = 0; root.stopping = false; root._err = [];
        root.target = label;
        var a = args.slice();
        // One source at a time: wf-recorder takes a single audio device.
        // The names are the PulseAudio defaults, so they follow whatever
        // output/input is current in the volume panel. The backend is named
        // explicitly: on a build that also has PipeWire audio the default
        // could differ, and there @DEFAULT_MONITOR@ means nothing.
        if (root.audio !== "none" && root.soundOk)
            a.push("--audio-backend=pulse",
                   "--audio=" + (root.audio === "mic" ? "@DEFAULT_SOURCE@" : "@DEFAULT_MONITOR@"));
        var base = "Recording_" + Qt.formatDateTime(new Date(), "yyyy-MM-dd_HH-mm-ss");
        proc.command = ["bash", "-c", root._script, "vexyon-record", root.dirPath, base, root.ext].concat(a);
        proc.stdinEnabled = true;
        proc.running = true;
    }

    function _notify(title, body) {
        Quickshell.execDetached(["notify-send", "-a", "Vexyon", "-i", "com.github.mohelm97.screenrecorder", title, body]);
    }

    // The wrapper around wf-recorder. Arguments: dir, base name, extension,
    // then wf-recorder's own options. stdout carries @@ lines for the shell.
    //
    //  * The file name never clashes: Recording_<date>[-N].<ext>.
    //  * The short sleep lets the compositor unmap the picker/region overlay
    //    first, so neither appears in the first frame.
    //  * STOP: wf-recorder's stdin is /dev/null; OUR stdin is a pipe from the
    //    shell. A watcher waits for EOF on it (Recorder.stop() closes it; a
    //    dead or reloading shell closes it too) and sends SIGINT.
    //  * wf-recorder writes the MP4/MKV trailer from its encoder thread as soon
    //    as SIGINT arrives, but its main thread only returns on the NEXT frame
    //    from the compositor — captures are damage-driven, so on an idle
    //    monitor that frame may never come (seen live: the file was complete
    //    and the process still waiting). libx264 prints its "kb/s:" summary
    //    when the encoder is freed, which is after the file is closed; once
    //    that line is in the log the process is ended. A 10 s cap ends it in
    //    any case: nothing may keep running after a stop.
    readonly property string _script: [
        'd=$1; b=$2; x=$3; shift 3',
        'mkdir -p -- "$d" || { printf "@@ERR\\tCannot create %s\\n" "$d"; printf "@@DONE\\t3\\n"; exit 3; }',
        'f="$d/$b.$x"; n=2',
        'while [ -e "$f" ]; do f="$d/$b-$n.$x"; n=$((n + 1)); done',
        'log=$(mktemp "${XDG_RUNTIME_DIR:-/tmp}/vexyon-rec.XXXXXX") || exit 3',
        'exec 2>/dev/null 3<&0',
        'sleep 0.15',
        'wf-recorder -y -f "$f" "$@" </dev/null 2>"$log" &',
        'p=$!',
        'printf "@@START\\t%s\\n" "$f"',
        '{',
        '  while read -r -u 3 _; do :; done',
        '  kill -INT "$p" || exit 0',
        '  i=0',
        '  while kill -0 "$p" && [ "$i" -lt 100 ]; do',
        '    if grep -q "kb/s:" "$log"; then sleep 0.3; break; fi',
        '    sleep 0.1; i=$((i + 1))',
        '  done',
        '  kill -KILL "$p"',
        // the wrapper itself was killed (shell reload): nobody else will clean up
        '  kill -0 $$ || rm -f "$log"',
        '} &',
        'w=$!',
        'exec 3<&-',
        'wait "$p"; rc=$?',
        'kill "$w"',
        'if [ "$rc" -ne 0 ] && grep -q "kb/s:" "$log"; then rc=0; fi',
        'if [ "$rc" -ne 0 ]; then',
        '  grep -v -e "^ " -e "^Setting codec" -e "^Using video filter" -e "^selected region" "$log" | tail -n 3 | sed "s/^/@@ERR\\t/"',
        'fi',
        'rm -f "$log"',
        'printf "@@DONE\\t%s\\n" "$rc"',
        'exit "$rc"'
    ].join("\n")

    Process {
        id: proc
        stdout: SplitParser {
            onRead: function(line) {
                var t = line.indexOf("\t");
                var tag = t > 0 ? line.slice(0, t) : line, val = t > 0 ? line.slice(t + 1) : "";
                if (tag === "@@START") { root.file = val; root.startedAt = Date.now(); }
                else if (tag === "@@ERR") { var e = root._err.slice(); e.push(val); root._err = e; }
            }
        }
        onExited: function(code, status) {
            root.stopping = false;
            if (code === 0 && root.file !== "") {
                root.lastFile = root.file;
                root._notify(I18n.t("Recording saved"), root.file);
            } else {
                root.lastError = root._err.length > 0 ? root._err.join("\n")
                    : I18n.t("wf-recorder stopped unexpectedly (exit code %1).").arg(code);
                root._notify(I18n.t("Recording failed"), root.lastError);
            }
        }
    }

    Process {
        id: detector
        command: ["bash", "-c",
            "export LC_ALL=C; " +
            "if command -v wf-recorder >/dev/null 2>&1; then echo recorder=1; " +
            "  echo \"version=$(wf-recorder -v 2>/dev/null | head -n 1)\"; " +
            // the -a/--audio[=DEVICE] line is only in builds with audio
            // support (--audio-backend is listed either way)
            "  wf-recorder -h 2>/dev/null | grep -q -- '--audio\\[' && echo audio=1 || echo audio=0; " +
            "else echo recorder=0; echo audio=0; fi; " +
            // pipewire-pulse (or PulseAudio) listening for this user
            "{ [ -S \"${XDG_RUNTIME_DIR:-/run/user/$(id -u)}/pulse/native\" ] || [ -n \"$PULSE_SERVER\" ]; } " +
            "  && echo pulse=1 || echo pulse=0; " +
            ". /etc/os-release 2>/dev/null; " +
            "echo \"os=${ID:-}\"; echo \"oslike=${ID_LIKE:-}\"; echo \"osname=${PRETTY_NAME:-${NAME:-}}\""]
        stdout: StdioCollector {
            onStreamFinished: {
                var m = {}, ls = this.text.split("\n");
                for (var i = 0; i < ls.length; i++) {
                    var e = ls[i].indexOf("=");
                    if (e > 0) m[ls[i].slice(0, e)] = ls[i].slice(e + 1).trim();
                }
                root.has = { recorder: m.recorder === "1", audio: m.audio === "1", pulse: m.pulse === "1" };
                root.version = m.version || "";
                root.osId = m.os || "";
                root.osLike = m.oslike || "";
                root.osName = m.osname || "";
                root.detected = true;
            }
        }
    }

    // A region picked in the overlay (ScreenshotOverlay in record mode).
    Connections {
        target: Panels
        function onRegionPicked(geom) { root.startRegion(geom); }
    }
}
