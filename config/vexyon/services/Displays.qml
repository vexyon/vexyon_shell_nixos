pragma Singleton

import QtQuick
import Quickshell
import Quickshell.Io
import qs.services

// ============================================================================
//  Displays — monitor topology + saved display profiles.
//
//  Reads live monitor state from `hyprctl monitors -j`, and the saved profiles
//  from shell.json `displays`. A profile bundles a per-monitor config map keyed
//  by connector name. Changes apply live (`hyprctl eval 'hl.monitor({…})'`) AND
//  persist to Config so the bridge writes them into vexyon-monitors.lua (they
//  survive a restart). Monitor config never selects a GPU — the session is
//  pinned to the iGPU via vexyon-gpu.lua (AQ_DRM_DEVICES), so nothing here can
//  wake the dGPU.
//
//  Profile auto-detect: each profile stores a `fingerprint` (sorted connector
//  names). When the connected hardware fingerprint equals a profile's, that
//  profile "matches" and is auto-applied.
// ============================================================================
Singleton {
    id: root

    // live monitors: [{ name, make, model, desc, width, height, refresh, scale,
    //                   transform, vrr, x, y, disabled, modes:[{res,refresh,label}] }]
    property var monitors: []
    property bool ready: false
    property string _lastAutoApplied: ""

    signal monitorsChanged2()

    // -------- transform / vrr / scale option tables (UI + validation) --------
    readonly property var transforms: [
        { v: 0, l: I18n.t("Normal") }, { v: 1, l: "90°" }, { v: 2, l: "180°" }, { v: 3, l: "270°" },
        { v: 4, l: I18n.t("Flipped") }, { v: 5, l: I18n.t("Flipped 90°") }, { v: 6, l: I18n.t("Flipped 180°") }, { v: 7, l: I18n.t("Flipped 270°") }
    ]
    readonly property var vrrModes: [
        { v: 0, l: I18n.t("Off") }, { v: 1, l: I18n.t("On") }, { v: 2, l: I18n.t("Fullscreen only") }
    ]
    readonly property var scalePresets: [
        { v: 1.0, l: "1.0×" }, { v: 1.25, l: "1.25×" }, { v: 1.5, l: "1.5×" },
        { v: 1.75, l: "1.75×" }, { v: 2.0, l: "2.0×" }, { v: 2.5, l: "2.5×" }, { v: 3.0, l: "3.0×" }
    ]
    readonly property var bitdepths: [ { v: 8, l: "8 bits (SDR)" }, { v: 10, l: "10 bits (HDR/WCG)" } ]

    // ======================= live monitor reading ==========================
    Process {
        id: lister
        command: ["bash", "-c", "hyprctl monitors -j"]
        stdout: StdioCollector {
            onStreamFinished: {
                try {
                    var arr = JSON.parse(this.text);
                    var out = [];
                    for (var i = 0; i < arr.length; i++) {
                        var m = arr[i];
                        var modes = [];
                        var am = m.availableModes || [];
                        for (var j = 0; j < am.length; j++) {
                            // "1920x1080@60.00Hz" -> res "1920x1080", refresh 60
                            var mt = am[j].match(/^(\d+x\d+)@([\d.]+)Hz$/);
                            if (!mt) continue;
                            var rf = Math.round(parseFloat(mt[2]) * 100) / 100;
                            modes.push({ res: mt[1], refresh: rf, label: mt[1] + " @ " + (Math.round(rf * 100) / 100) + " Hz" });
                        }
                        out.push({
                            name: m.name,
                            make: m.make || "",
                            model: m.model || m.name,
                            desc: (m.make ? m.make + " " : "") + (m.model || ""),
                            width: m.width, height: m.height,
                            refresh: Math.round(m.refreshRate * 100) / 100,
                            scale: m.scale,
                            transform: m.transform || 0,
                            vrr: m.vrr === true ? 1 : 0,
                            x: m.x, y: m.y,
                            disabled: m.disabled === true,
                            modes: modes
                        });
                    }
                    root.monitors = out;
                    root.ready = true;
                    root.monitorsChanged2();
                    root.autoApply();
                } catch (e) { console.warn("[Displays] parse failed:", e); }
            }
        }
    }
    function refresh() { lister.running = true; }
    Component.onCompleted: refresh()

    // ======================= profiles (shell.json) =========================
    function profiles() { return Config.get("displays", "profiles", []) || []; }
    function activeName() { return Config.get("displays", "activeProfile", ""); }
    function formatByModel() { return Config.get("displays", "formatByModel", false); }

    function getProfile(name) {
        var ps = root.profiles();
        for (var i = 0; i < ps.length; i++) if (ps[i].name === name) return ps[i];
        return null;
    }
    function activeProfile() { return root.getProfile(root.activeName()); }

    // connector fingerprint of the currently-connected hardware
    function fingerprint() {
        var names = [];
        for (var i = 0; i < root.monitors.length; i++) names.push(root.monitors[i].name);
        names.sort();
        return names.join("|");
    }

    // the saved profile (name) whose fingerprint matches current hardware, or ""
    function matchedName() {
        var fp = root.fingerprint();
        if (fp === "") return "";
        var ps = root.profiles();
        for (var i = 0; i < ps.length; i++) if (ps[i].fingerprint === fp) return ps[i].name;
        return "";
    }

    // display label for a monitor per the "format" toggle
    function displayLabel(mon) {
        return root.formatByModel() ? (mon.model !== "" ? mon.model : mon.name) : mon.name;
    }

    // effective config for a monitor: stored (active profile) OR derived from live
    function monCfg(monName) {
        var p = root.activeProfile();
        if (p && p.monitors && p.monitors[monName]) {
            var c = p.monitors[monName];
            return {
                enabled: c.enabled !== false,
                resolution: c.resolution, refresh: c.refresh, scale: c.scale,
                transform: c.transform || 0, vrr: c.vrr || 0,
                x: c.x || 0, y: c.y || 0, bitdepth: c.bitdepth || 8
            };
        }
        // derive from live
        var m = root.monitorByName(monName);
        if (!m) return null;
        return {
            enabled: !m.disabled,
            resolution: m.width + "x" + m.height, refresh: m.refresh, scale: m.scale,
            transform: m.transform, vrr: m.vrr, x: m.x, y: m.y, bitdepth: 8
        };
    }

    function monitorByName(name) {
        for (var i = 0; i < root.monitors.length; i++) if (root.monitors[i].name === name) return root.monitors[i];
        return null;
    }

    // ======================= monitor call + apply ==========================
    // Build the hl.monitor(...) Lua call from a config object. Mirrors
    // lua_monitor_call() in the bridge so live-apply and persisted config
    // agree (hyprctl keyword is dead on Lua roots: "keyword can't work with
    // non-legacy parsers. Use eval.").
    function monCall(name, c) {
        if (c.enabled === false)
            return 'hl.monitor({ output = "' + name + '", disabled = true })';
        var s = 'hl.monitor({ output = "' + name + '"'
              + ', mode = "' + c.resolution + "@" + c.refresh + '"'
              + ', position = "' + (c.x || 0) + "x" + (c.y || 0) + '"'
              + ', scale = "' + root.fmtScale(c.scale) + '"'
              + ", transform = " + (c.transform || 0)
              + ", vrr = " + (c.vrr || 0);
        if ((c.bitdepth || 8) === 10) s += ", bitdepth = 10";
        return s + " })";
    }
    function fmtScale(s) {
        var n = Number(s);
        if (!isFinite(n) || n <= 0) return "1";
        // trim trailing zeros: 1 -> "1", 1.25 -> "1.25"
        return (Math.round(n * 1000000) / 1000000).toString();
    }

    Process { id: applier }
    function applyLive(name, c) {
        applier.command = ["hyprctl", "eval", root.monCall(name, c)];
        applier.running = true;
    }

    // ======================= profile mutation ==============================
    function _writeProfiles(ps) { Config.set("displays", "profiles", ps); }

    // ensure a default profile exists so edits have a home; seed from live hw
    function ensureProfile() {
        if (root.profiles().length > 0 && root.activeName() !== "") return;
        if (!root.ready || root.monitors.length === 0) return;
        if (root.profiles().length === 0) root.createProfile(I18n.t("Default"));
        else if (root.activeName() === "") Config.set("displays", "activeProfile", root.profiles()[0].name);
    }

    function createProfile(name) {
        var mons = {};
        for (var i = 0; i < root.monitors.length; i++) {
            var m = root.monitors[i];
            mons[m.name] = {
                enabled: !m.disabled,
                resolution: m.width + "x" + m.height, refresh: m.refresh, scale: m.scale,
                transform: m.transform, vrr: m.vrr, x: m.x, y: m.y, bitdepth: 8
            };
        }
        var p = { name: name, fingerprint: root.fingerprint(), monitors: mons };
        var ps = root.profiles().slice();
        // replace if a profile with this name already exists
        var replaced = false;
        for (var k = 0; k < ps.length; k++) if (ps[k].name === name) { ps[k] = p; replaced = true; }
        if (!replaced) ps.push(p);
        root._writeProfiles(ps);
        Config.set("displays", "activeProfile", name);
    }

    function deleteProfile(name) {
        var ps = root.profiles().filter(function(p) { return p.name !== name; });
        root._writeProfiles(ps);
        if (root.activeName() === name)
            Config.set("displays", "activeProfile", ps.length > 0 ? ps[0].name : "");
    }

    function setActive(name) {
        Config.set("displays", "activeProfile", name);
        root.applyProfile(name);
    }

    // ======================= confirm / revert (10s safety) =================
    //  Un cambio de monitor (resolución, refresco, escala, posición, transform,
    //  VRR, bits) se aplica EN VIVO al instante pero queda "a prueba": arranca
    //  una cuenta atrás de 10s. Si el usuario no confirma, se revierte solo a la
    //  última config que funcionaba (patrón GNOME/Windows — evita quedarse con
    //  una pantalla inutilizable). El estado previo se guarda antes del PRIMER
    //  cambio de la tanda; cambios encadenados dentro de la ventana reinician el
    //  contador pero conservan el snapshot original.
    property bool pendingRevert: false
    property int  revertSeconds: 10
    property var  _revertProfiles: null   // copia de profiles() antes del 1er cambio
    property string _revertActive: ""     // activeProfile antes del 1er cambio

    Timer {
        id: revertTimer
        interval: 1000; repeat: true; running: root.pendingRevert
        onTriggered: {
            root.revertSeconds -= 1;
            if (root.revertSeconds <= 0) root.revertChange();
        }
    }

    function _beginPending() {
        if (root.pendingRevert) { root.revertSeconds = 10; return; } // reinicia el contador
        root._revertProfiles = JSON.parse(JSON.stringify(root.profiles()));
        root._revertActive = root.activeName();
        root.revertSeconds = 10;
        root.pendingRevert = true;
    }
    function confirmChange() {
        // el usuario acepta: ya está persistido/aplicado, solo cerramos la ventana
        root.pendingRevert = false;
        root._revertProfiles = null;
    }
    function revertChange() {
        if (!root.pendingRevert) return;
        root.pendingRevert = false;
        if (root._revertProfiles !== null) {
            Config.set("displays", "profiles", root._revertProfiles);
            if (root._revertActive !== root.activeName())
                Config.set("displays", "activeProfile", root._revertActive);
            // re-aplica en vivo la config buena (todos los monitores del perfil)
            root.applyProfile(root._revertActive);
            root._revertProfiles = null;
        }
    }

    // write one field of one monitor in the active profile, persist + apply live
    function setMonitorField(monName, key, value) {
        var o = {}; o[key] = value;
        root.setMonitorFields(monName, o);
    }

    // write several fields of one monitor at once (single persist + apply)
    function setMonitorFields(monName, fields) {
        root.ensureProfile();
        root._beginPending();   // snapshot del estado bueno + arranca/reinicia la cuenta atrás
        var ps = root.profiles().slice();
        var an = root.activeName();
        for (var i = 0; i < ps.length; i++) {
            if (ps[i].name !== an) continue;
            var p = JSON.parse(JSON.stringify(ps[i]));
            if (!p.monitors) p.monitors = {};
            if (!p.monitors[monName]) p.monitors[monName] = root.monCfg(monName) || {};
            for (var key in fields) p.monitors[monName][key] = fields[key];
            ps[i] = p;
            root._writeProfiles(ps);
            root.applyLive(monName, p.monitors[monName]);
            return;
        }
    }

    // apply every monitor in a profile live
    function applyProfile(name) {
        var p = root.getProfile(name);
        if (!p || !p.monitors) return;
        for (var mn in p.monitors) root.applyLive(mn, p.monitors[mn]);
    }

    // auto-apply the profile matching current hardware (once per fingerprint)
    function autoApply() {
        var mn = root.matchedName();
        if (mn === "") return;
        var fp = root.fingerprint();
        if (root._lastAutoApplied === fp) return;
        root._lastAutoApplied = fp;
        if (root.activeName() !== mn) Config.set("displays", "activeProfile", mn);
        root.applyProfile(mn);
    }
}
