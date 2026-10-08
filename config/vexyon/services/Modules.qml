pragma Singleton

import QtQuick
import Quickshell
import Quickshell.Io
import qs.services

// ============================================================================
//  Modules — Vexyon's optional modules (Settings → Modules). The ONE place the
//  shell asks whether an optional part is on; nobody else reads the switches.
//
//  Two kinds:
//   * system  — the module has background services (libvirt, BlueZ). The
//               choice is stored by `vexyon-modules set` (root, through
//               pkexec + polkit) and applied by vexyon-modules.service at the
//               NEXT boot, which gates the services with a systemd condition.
//               So there are two states: what this boot runs (`active`) and
//               what the next boot will run (`desired`). The UI follows
//               `active` until the restart: turning a module off never pulls
//               a running VM or a connected headset out from under the user.
//   * session — no service at all (screen recording). Stored in shell.json,
//               applies at once.
//
//  Cost: ONE short `vexyon-modules status` run when the shell starts, and
//  again only after a change or when Settings → Modules opens. No timer, no
//  watcher, no daemon.
//
//  ⚠️ Feature singletons (Vm, Recorder) stay lazy: everything that must not
//  build them while a module is off asks HERE (`vmOn`, `recorderOn`), never
//  `Vm.enabled` / `Recorder.enabled` — asking those would create them.
//
//  Fail-open, like the boot gating: if the helper is missing or broken, a
//  system module reads as on, exactly as before modules existed.
// ============================================================================
Singleton {
    id: root

    // ---- catalog -----------------------------------------------------------
    //  name/desc are English I18n keys; pages translate them at render time.
    //  `page`: the Settings page with the module's own options ("" = none).
    readonly property var catalog: [
        { id: "vm", scope: "system", icon: Icons.desktop, page: "virtualization",
          name: "Virtual machines",
          desc: "The VM manager and its bar widget, with libvirt and QEMU underneath. Turning it off stops libvirt's services at boot; your VMs, disks and networks are kept." },
        { id: "bluetooth", scope: "system", icon: Icons.bluetooth, page: "",
          name: "Bluetooth",
          desc: "Headphones, keyboards, mice and other Bluetooth devices, and the Bluetooth controls in the panels. Turning it off stops the Bluetooth service at boot; paired devices are remembered." },
        { id: "recorder", scope: "session", icon: Icons.record, page: "recording",
          name: "Screen recording",
          desc: "The screen recorder and its bar indicator. Nothing of it runs until you record." }
    ]

    function meta(id) {
        for (var i = 0; i < root.catalog.length; i++)
            if (root.catalog[i].id === id) return root.catalog[i];
        return null;
    }
    function scopeOf(id) { var m = root.meta(id); return m ? m.scope : ""; }

    // ---- state of the system modules (from `vexyon-modules status`) ----------
    property bool ready: false        // the first status answer arrived
    property bool helperOk: false     // ...and it came from a working helper
    property bool booted: false       // this boot was started with modules applied
    property string os: ""            // ID from /etc/os-release, as the helper saw it
    readonly property bool nixos: root.os === "nixos"
    // id -> { desired, applied, gated, shared, available, hardware, consumers[] }
    property var sys: ({})

    // A change in flight (module id, and the value asked for) and the last
    // failure, per module.
    property string busy: ""
    property bool busyTo: false
    property string errorId: ""
    property string error: ""

    // ---- what the rest of the shell reads -----------------------------------
    readonly property bool vmOn: root.active("vm")
    readonly property bool bluetoothOn: root.active("bluetooth")
    // Config first, so nothing reads the default before shell.json is parsed.
    // Default ON: new installs get every module; an older shell.json keeps the
    // value it already has.
    readonly property bool recorderOn: Config.ready && Config.get("recording", "enabled", true) === true

    // On THIS session. Before the first answer a system module reads as off,
    // so nothing optional is built just to be torn down a moment later.
    function active(id) {
        if (id === "recorder") return root.recorderOn;
        if (!root.ready) return false;
        var s = root.sys[id];
        return s ? s.applied : true;
    }
    // What the next boot (system) or this session (session) will have.
    function desired(id) {
        if (id === "recorder") return root.recorderOn;
        var s = root.sys[id];
        return s ? s.desired : true;
    }
    // Saved, but waiting for a restart.
    function pending(id) {
        return root.scopeOf(id) === "system" && root.ready && root.sys[id] !== undefined
            && root.desired(id) !== root.active(id);
    }
    readonly property bool anyPending: {
        for (var i = 0; i < root.catalog.length; i++)
            if (root.pending(root.catalog[i].id)) return true;
        return false;
    }
    function info(id) { return root.sys[id] || null; }

    // ---- changing a module ---------------------------------------------------
    function set(id, on) {
        if (root.busy !== "") return;
        root.error = ""; root.errorId = "";
        if (id === "recorder") {
            Config.set("recording", "enabled", on === true);
            // The bar indicator comes with the feature: without it a running
            // recording would be invisible. It only exists while recording, so
            // adding it changes nothing on the bar the rest of the time.
            if (on && !WidgetRegistry.hasWidget("recorder"))
                WidgetRegistry.addWidgetAt("right", "recorder", 0);
            return;
        }
        if (root.scopeOf(id) !== "system") return;
        root.busy = id;
        root.busyTo = on === true;
        setProc.target = id;
        setProc.command = ["bash", root.bin, "set", id, on ? "on" : "off"];
        setProc.running = true;
    }

    function refresh() {
        if (statusProc.running) { root._again = true; return; }
        statusProc.running = true;
    }
    property bool _again: false

    // Same resolution as the other helpers (Vm.xmlBin, Recorder): VEXYON_BIN_DIR
    // on NixOS, the deployed tree on Arch. `bash` in front: a web upload to
    // GitHub drops the +x bit.
    readonly property string bin: {
        var d = Quickshell.env("VEXYON_BIN_DIR");
        var base = (d && d !== "") ? d : Quickshell.env("HOME") + "/.config/vexyon/bin";
        return base + "/vexyon-modules";
    }

    function _parse(text) {
        var lines = text.split("\n"), next = {}, head = false, booted = false;
        for (var i = 0; i < lines.length; i++) {
            var l = lines[i].trim();
            if (l === "") continue;
            var kv = {}, parts = l.split(" ");
            for (var p = 0; p < parts.length; p++) {
                var e = parts[p].indexOf("=");
                if (e > 0) kv[parts[p].slice(0, e)] = parts[p].slice(e + 1);
            }
            if (parts[0] === "vexyon-modules") { head = true; booted = kv.boot === "1"; root.os = kv.os || ""; continue; }
            if (!kv.id) continue;
            next[kv.id] = {
                desired: kv.desired !== "off",
                applied: kv.applied !== "off",
                gated: kv.gated === "1",
                shared: kv.shared === "1",
                available: kv.available === "1",
                hardware: kv.hardware === "1",
                consumers: (kv.consumers || "").split(",").filter(function(x) { return x !== ""; })
            };
        }
        root.helperOk = head;
        root.booted = booted;
        root.sys = head ? next : ({});
        root.ready = true;
    }

    Process {
        id: statusProc
        command: ["bash", root.bin, "status"]
        // The one read at startup. Everything else is on request.
        running: true
        stdout: StdioCollector { onStreamFinished: root._parse(this.text) }
        onExited: function(code) {
            if (code !== 0) { root.helperOk = false; root.sys = ({}); }
            root.ready = true;
            if (root._again) { root._again = false; statusProc.running = true; }
        }
    }

    Process {
        id: setProc
        property string target: ""
        stderr: StdioCollector { id: setErr }
        onExited: function(code) {
            var id = setProc.target;
            root.busy = "";
            if (code !== 0) {
                root.errorId = id;
                // pkexec: 126 = the password dialog was dismissed, 127 = not
                // authorized (or no authentication agent). Our own codes: 3 =
                // the system part is not installed, 4 = could not save.
                root.error = code === 126 ? I18n.t("Cancelled — nothing was changed.")
                           : code === 127 ? I18n.t("Not authorized — nothing was changed.")
                           : code === 3 ? I18n.t("The system part of Vexyon modules is not installed. Run the Vexyon installer again (on NixOS: rebuild your system).")
                           : (setErr.text.trim() !== "" ? setErr.text.trim().replace(/^vexyon-modules: /, "")
                                                         : I18n.t("The change could not be saved."));
            }
            root.refresh();
        }
    }
}
