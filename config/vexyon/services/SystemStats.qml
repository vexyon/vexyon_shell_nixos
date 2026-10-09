pragma Singleton

import QtQuick
import Quickshell
import Quickshell.Io

// ============================================================================
//  SystemStats — live CPU / memory / disk usage, temperatures and network
//  throughput. One shared poll drives every monitor widget so N copies on the
//  bar cost a single subprocess every tick. Cheap, dependency-light (procfs +
//  coreutils; temps via /sys/class/hwmon, sensors optional).
//
//  GPU TEMPERATURE POLICY (iGPU-only mandate): gpuTemp reads the integrated
//  GPU's hwmon (amdgpu/i915). A discrete Nvidia reading, if any, is exposed
//  separately as nvidiaTemp and marked informational — the active GPU is the
//  iGPU; the shell never implies the dGPU is in use.
// ============================================================================
Singleton {
    id: root

    property int  cpuPercent: 0
    property int  cpuUser: 0        // user+nice share
    property int  cpuSystem: 0      // system+irq share
    property int  memPercent: 0
    property int  memUsedMb: 0
    property int  memTotalMb: 0
    property int  diskPercent: 0
    property int  cpuTemp: 0        // °C, 0 = unavailable
    property int  gpuTemp: 0        // integrated GPU °C, 0 = unavailable
    property int  nvidiaTemp: 0     // discrete (informational only), 0 = none
    property real netDownKbs: 0     // KB/s
    property real netUpKbs: 0

    // previous cpu jiffies / net bytes for delta calc
    property var _prevCpu: null
    property var _prevNet: null
    property double _prevT: 0

    // Refcount de consumidores (pastillas monitor de la barra y panel
    // sysMonitor — el panel solo se abre desde una pastilla, así que con
    // barras sin widgets de monitor el dato no lo muestra NADIE y el poll
    // no corre). Los deltas (_prevCpu/_prevNet) viven en el singleton:
    // re-abrir no pierde el estado y el primer valor tras re-registrar sale
    // como siempre.
    property int watchers: 0
    // Aparte, lo que cuesta más que leer /proc y solo hace falta si alguien lo
    // ENSEÑA: el disco (`df`: el uso de un sistema de ficheros no está en
    // ningún fichero de /proc) y las temperaturas (leer el hwmon de una dGPU
    // AMD en reposo la DESPIERTA — en un portátil híbrido eso es batería).
    // Pastillas de disco/temperatura y el panel suben estos además de
    // `watchers`; las de CPU/RAM/red no.
    property int diskWatchers: 0
    property int tempWatchers: 0

    // CPU, memoria y red: /proc leído DENTRO del proceso (FileView), sin
    // lanzar nada. Antes era un bash con cat/grep/tail/df/dirname cada 2 s
    // (~8 procesos por segundo con la barra por defecto).
    FileView { id: statFv; path: "/proc/stat"; blockLoading: true; printErrors: false }
    FileView { id: memFv; path: "/proc/meminfo"; blockLoading: true; printErrors: false }
    FileView { id: netFv; path: "/proc/net/dev"; blockLoading: true; printErrors: false }

    Timer {
        interval: 2000; running: root.watchers > 0; repeat: true; triggeredOnStart: true
        onTriggered: root.tick()
    }

    // ---- disco: `df` solo con consumidores de disco --------------------------
    Process {
        id: dfProc
        command: ["df", "-P", "/"]
        stdout: StdioCollector {
            onStreamFinished: {
                var l = this.text.trim().split("\n");
                var f = (l[l.length - 1] || "").trim().split(/\s+/);
                if (f.length >= 5) root.diskPercent = parseInt(f[4]) || 0;
            }
        }
    }

    // ---- temperaturas: los hwmon se buscan UNA vez (al aparecer el primer
    // consumidor) y luego se leen en el propio proceso ------------------------
    property var _tempFiles: []          // [{ name, path }]
    onTempWatchersChanged: if (tempWatchers > 0) hwmonScan.running = true
    Process {
        id: hwmonScan
        command: ["bash", "-c",
            "for f in /sys/class/hwmon/hwmon*/temp1_input; do [ -e \"$f\" ] || continue; " +
            "printf '%s\\t%s\\n' \"$(cat \"${f%/*}/name\" 2>/dev/null)\" \"$f\"; done"]
        stdout: StdioCollector {
            onStreamFinished: {
                var out = [], lines = this.text.split("\n");
                for (var i = 0; i < lines.length; i++) {
                    var t = lines[i].indexOf("\t");
                    if (t > 0) out.push({ name: lines[i].substring(0, t).toLowerCase(), path: lines[i].substring(t + 1) });
                }
                root._tempFiles = out;
                root.readTemps();
            }
        }
    }
    Instantiator {
        id: tempViews
        model: root._tempFiles
        delegate: FileView {
            required property var modelData
            path: modelData.path
            blockLoading: true
            printErrors: false
        }
    }

    function tick() {
        statFv.reload(); memFv.reload(); netFv.reload();
        root.parse(statFv.text(), memFv.text(), netFv.text());
        if (root.diskWatchers > 0 && !dfProc.running) dfProc.running = true;
        if (root.tempWatchers > 0) root.readTemps();
    }

    function readTemps() {
        var cpuT = 0, gpuT = 0, nvT = 0;
        for (var k = 0; k < tempViews.count; k++) {
            var fv = tempViews.objectAt(k);
            if (!fv) continue;
            fv.reload();
            var nm = root._tempFiles[k].name;
            var val = Math.round((parseInt(fv.text()) || 0) / 1000);
            if (val <= 0) continue;
            if (nm.indexOf("coretemp") !== -1 || nm.indexOf("k10temp") !== -1 || nm.indexOf("zenpower") !== -1 || nm.indexOf("cpu") !== -1) {
                if (cpuT === 0) cpuT = val;
            } else if (nm.indexOf("amdgpu") !== -1 || nm.indexOf("i915") !== -1 || nm.indexOf("intel") !== -1) {
                if (gpuT === 0) gpuT = val;
            } else if (nm.indexOf("nvidia") !== -1) {
                if (nvT === 0) nvT = val;
            }
        }
        root.cpuTemp = cpuT;
        root.gpuTemp = gpuT;
        root.nvidiaTemp = nvT;
    }

    function parse(stat, mem, netdev) {
        var nowT = Date.now() / 1000;
        var dt = root._prevT > 0 ? Math.max(0.001, nowT - root._prevT) : 2.0;
        root._prevT = nowT;

        // ---- CPU ----
        var cpuLine = (stat.split("\n")[0] || "").trim();
        var f = cpuLine.split(/\s+/);           // cpu user nice system idle iowait irq softirq steal
        if (f.length >= 5 && f[0] === "cpu") {
            var idle = parseInt(f[4]) + (parseInt(f[5]) || 0);   // idle + iowait
            var user = (parseInt(f[1]) || 0) + (parseInt(f[2]) || 0);            // user + nice
            var sys = (parseInt(f[3]) || 0) + (parseInt(f[6]) || 0) + (parseInt(f[7]) || 0); // system+irq+softirq
            var total = 0;
            for (var i = 1; i < f.length; i++) total += parseInt(f[i]) || 0;
            if (root._prevCpu) {
                var dTotal = total - root._prevCpu.total;
                var dIdle = idle - root._prevCpu.idle;
                if (dTotal > 0) {
                    root.cpuPercent = Math.max(0, Math.min(100, Math.round(100 * (dTotal - dIdle) / dTotal)));
                    root.cpuUser = Math.max(0, Math.min(100, Math.round(100 * (user - root._prevCpu.user) / dTotal)));
                    root.cpuSystem = Math.max(0, Math.min(100, Math.round(100 * (sys - root._prevCpu.sys) / dTotal)));
                }
            }
            root._prevCpu = { total: total, idle: idle, user: user, sys: sys };
        }

        // ---- MEM ----
        var mt = mem.match(/MemTotal:\s+(\d+)/);
        var ma = mem.match(/MemAvailable:\s+(\d+)/);
        if (mt && ma) {
            var totalKb = parseInt(mt[1]), availKb = parseInt(ma[1]);
            root.memTotalMb = Math.round(totalKb / 1024);
            root.memUsedMb = Math.round((totalKb - availKb) / 1024);
            root.memPercent = Math.round(100 * (totalKb - availKb) / totalKb);
        }

        // ---- NET (sum all non-loopback interfaces) ----
        var netLines = netdev.split("\n").slice(2);   // 2 header lines
        var rx = 0, tx = 0;
        for (var n = 0; n < netLines.length; n++) {
            var l = netLines[n].trim();
            if (l === "" || l.indexOf("lo:") === 0) continue;
            var parts = l.split(/[:\s]+/);
            // iface rx_bytes ... (col1) ... tx_bytes (col9)
            if (parts.length >= 10) { rx += parseInt(parts[1]) || 0; tx += parseInt(parts[9]) || 0; }
        }
        if (root._prevNet) {
            root.netDownKbs = Math.max(0, (rx - root._prevNet.rx) / dt / 1024);
            root.netUpKbs = Math.max(0, (tx - root._prevNet.tx) / dt / 1024);
        }
        root._prevNet = { rx: rx, tx: tx };
    }

    // pretty KB/s -> string
    function fmtSpeed(kbs) {
        if (kbs >= 1024) return (kbs / 1024).toFixed(1) + " MB/s";
        return Math.round(kbs) + " KB/s";
    }
}
