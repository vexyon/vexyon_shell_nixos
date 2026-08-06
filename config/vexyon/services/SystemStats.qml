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
    // no corre). Con widgets en barra (default) es idéntico a antes. Los
    // deltas (_prevCpu/_prevNet) viven en el singleton: re-abrir no pierde
    // el estado y el primer valor tras re-registrar sale como siempre.
    property int watchers: 0

    Timer {
        interval: 2000; running: root.watchers > 0; repeat: true; triggeredOnStart: true
        onTriggered: poller.running = true
    }

    Process {
        id: poller
        command: ["bash", "-c",
            "echo CPU; cat /proc/stat | grep '^cpu '; " +
            "echo MEM; cat /proc/meminfo | grep -E '^(MemTotal|MemAvailable):'; " +
            "echo DISK; df -P / | tail -1; " +
            "echo NET; cat /proc/net/dev | tail -n +3; " +
            "echo CPUTEMP; for f in /sys/class/hwmon/hwmon*/temp1_input; do " +
              "n=$(cat $(dirname $f)/name 2>/dev/null); " +
              "echo \"$n $(cat $f 2>/dev/null)\"; done"]
        stdout: StdioCollector { onStreamFinished: root.parse(this.text) }
    }

    function _sec(t, name, next) {
        var a = t.indexOf(name + "\n");
        if (a < 0) return "";
        a += name.length + 1;
        var b = next ? t.indexOf(next + "\n", a) : t.length;
        return t.substring(a, b < 0 ? t.length : b);
    }

    function parse(t) {
        var nowT = Date.now() / 1000;
        var dt = root._prevT > 0 ? Math.max(0.001, nowT - root._prevT) : 2.0;
        root._prevT = nowT;

        // ---- CPU ----
        var cpuLine = root._sec(t, "CPU", "MEM").trim();
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
        var mem = root._sec(t, "MEM", "DISK");
        var mt = mem.match(/MemTotal:\s+(\d+)/);
        var ma = mem.match(/MemAvailable:\s+(\d+)/);
        if (mt && ma) {
            var totalKb = parseInt(mt[1]), availKb = parseInt(ma[1]);
            root.memTotalMb = Math.round(totalKb / 1024);
            root.memUsedMb = Math.round((totalKb - availKb) / 1024);
            root.memPercent = Math.round(100 * (totalKb - availKb) / totalKb);
        }

        // ---- DISK ----
        var disk = root._sec(t, "DISK", "NET").trim().split(/\s+/);
        if (disk.length >= 5) root.diskPercent = parseInt(disk[4]) || 0;

        // ---- NET (sum all non-loopback interfaces) ----
        var netLines = root._sec(t, "NET", "CPUTEMP").split("\n");
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

        // ---- TEMPS ----
        var temps = root._sec(t, "CPUTEMP", null).split("\n");
        var cpuT = 0, gpuT = 0, nvT = 0;
        for (var k = 0; k < temps.length; k++) {
            var tl = temps[k].trim(); if (tl === "") continue;
            var sp = tl.lastIndexOf(" ");
            var nm = tl.substring(0, sp).trim().toLowerCase();
            var val = Math.round((parseInt(tl.substring(sp + 1)) || 0) / 1000);
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

    // pretty KB/s -> string
    function fmtSpeed(kbs) {
        if (kbs >= 1024) return (kbs / 1024).toFixed(1) + " MB/s";
        return Math.round(kbs) + " KB/s";
    }
}
