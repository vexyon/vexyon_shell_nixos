pragma Singleton

import QtQuick
import Quickshell
import Quickshell.Io
import qs.services

// ============================================================================
//  AirDrop — the optional module "airdrop" (Settings → Modules): send and
//  receive files with nearby iPhones, iPads and Macs. Everything goes through
//  bin/vexyon-airdrop, which drives the upstream `omdrop` command (radio:
//  omdrop-owl; command and receiver: omdrop). See that script's header.
//
//  Nothing of AirDrop runs until the user turns it on: the radio (root,
//  through pkexec) and the receiver (a user unit) exist only while this
//  computer is visible, and omdrop's own timer turns them off at the end of
//  the window.
//
//  CERO SONDEO. The state is read when the bar pill is created, when the
//  panel or Settings → AirDrop opens, after every action, and ONCE when the
//  window is due to end (a one-shot timer set from `remaining`). Looking for
//  nearby devices runs only while the panel's device list is open.
//
//  ⚠️ Lazy: only the AirDrop pill, panel and Settings page touch this
//  singleton, and none of them exists with the module off. Everyone else asks
//  `Modules.airdropOn`.
// ============================================================================
Singleton {
    id: root

    // ---- state (omdrop status --json) ---------------------------------------
    property bool ready: false
    property bool installed: true
    property bool receiving: false
    property var radioVisible: null       // true / false / null (radio missing)
    property int remaining: -1            // seconds left in a timed window
    property string mode: "off"           // timed | once | forever | off
    property string name: ""
    property string dir: ""
    property string reason: ""            // why the radio last stopped
    property string visibility: "everyone"
    property int senders: 0
    // Visible to nearby devices right now.
    readonly property bool on: root.receiving
    // When the window ends (ms since the epoch), 0 = no end.
    property real endsAt: 0

    // ---- actions in flight ----------------------------------------------------
    property string busy: ""              // "on" | "off" | "dir" | "visibility" | "senders"
    property string error: ""

    // ---- what Settings and the panel show about the hardware ----------------
    //  { installed, version, host, helper, wifi, driver, profile, mode,
    //    allowUntested, doctor: { ready, missing: [{ id, say }] } | null }
    property var info: null
    readonly property bool infoLoading: infoProc.running
    readonly property var problems: root.info && root.info.doctor && root.info.doctor.missing
        ? root.info.doctor.missing.filter(function(m) { return m.id !== "service"; })
                                  .map(function(m) { return { id: m.id, say: root.say(m.say) }; }) : []
    // Wi-Fi goes away while visible (exclusive / active-monitor profiles).
    readonly property bool takesWifi: root.info !== null && (root.info.mode === "exclusive" || root.info.mode === "active-monitor")
    readonly property string hostName: root.info && root.info.host ? root.info.host : root.name

    // The radio's most common answers, in the shell's language. omdrop and
    // omdrop-owl speak English; anything not listed here is shown as they say it.
    function say(t) {
        var m;
        if (!t) return "";
        if (/^This computer has no Wi-Fi interface that omdrop-owl can use|^omdrop-discoverable: no Wi-Fi interface to run AWDL on/.test(t))
            return I18n.t("This computer has no Wi-Fi card AirDrop can use.");
        if (/^(omdrop-discoverable: )?Wi-Fi isn't connected/.test(t))
            return I18n.t("Connect to Wi-Fi first: with this Wi-Fi card, AirDrop shares the channel of your Wi-Fi network.");
        if ((m = t.match(/^(?:omdrop-discoverable: )?[Yy]our Wi-Fi network is on (\S+) MHz/)))
            return I18n.t("Your Wi-Fi network is on %1 MHz, but AirDrop can only share channel 6, 44 or 149 with it. Moving the router to one of those channels makes this work.").arg(m[1]);
        if ((m = t.match(/^(?:omdrop-discoverable: )?omdrop-owl hasn't been tested on this computer's Wi-Fi \(([^)]*)\)/)))
            return I18n.t("AirDrop has not been tested with this Wi-Fi card (%1) yet, so it stays off for it. To try it anyway: on NixOS set services.omdrop-owl.allowUntested = true and rebuild; on Arch put 1 in /etc/omdrop/allow-untested.").arg(m[1]);
        return t;
    }

    // ---- known senders (Contacts Only) ----------------------------------------
    property var senderList: []

    // ---- nearby devices --------------------------------------------------------
    property bool scanning: false         // the panel's device list is open
    property var peers: []                // [{ mac, rssi, name }]
    readonly property bool peersRunning: peersProc.running

    // ---- sending ---------------------------------------------------------------
    property string sendMac: ""
    property string sendName: ""
    property string sendLine: ""          // omdrop's last progress sentence
    property string sendResult: ""        // "" | "ok" | "failed"
    readonly property bool sending: sendProc.running

    readonly property string bin: {
        var d = Quickshell.env("VEXYON_BIN_DIR");
        var base = (d && d !== "") ? d : Quickshell.env("HOME") + "/.config/vexyon/bin";
        return base + "/vexyon-airdrop";
    }

    // The window length the panel offers, in minutes (0 = until turned off).
    readonly property int minutes: Config.get("airdrop", "minutes", 10)
    function setMinutes(m) { Config.set("airdrop", "minutes", m); }

    // ---- reading ---------------------------------------------------------------
    property bool _primed: false
    function prime() { if (!root._primed) { root._primed = true; root.refresh(); } }
    function refresh() {
        if (statusProc.running) { root._again = true; return; }
        statusProc.running = true;
    }
    property bool _again: false

    function loadInfo() { if (!infoProc.running) infoProc.running = true; }
    function loadSenders() { if (!sendersProc.running) sendersProc.running = true; }

    function _parseStatus(text) {
        var d = null;
        try { d = JSON.parse(text.trim()); } catch (e) { d = null; }
        if (!d) return;
        if (d.installed === false) {
            root.installed = false;
            root.receiving = false;
            root.ready = true;
            return;
        }
        root.installed = true;
        root.receiving = d.receiving === true;
        root.radioVisible = d.visible === null || d.visible === undefined ? null : d.visible === true;
        root.remaining = (typeof d.remaining === "number") ? d.remaining : -1;
        root.mode = d.mode || "off";
        root.name = d.name || "";
        root.dir = d.dir || "";
        root.reason = d.reason || "";
        root.visibility = d.visibility === "contacts" ? "contacts" : "everyone";
        root.senders = d.senders || 0;
        root.endsAt = root.receiving && root.remaining > 0 ? Date.now() + root.remaining * 1000 : 0;
        // The one re-read a timed window needs: just after it ends.
        if (root.receiving && root.remaining > 0) {
            endTimer.interval = root.remaining * 1000 + 3000;
            endTimer.restart();
        } else {
            endTimer.stop();
        }
        root.ready = true;
    }

    Timer { id: endTimer; repeat: false; onTriggered: root.refresh() }

    Process {
        id: statusProc
        command: ["bash", root.bin, "status", "--json"]
        stdout: StdioCollector { onStreamFinished: root._parseStatus(this.text) }
        onExited: function(code) {
            if (code !== 0 && !root.ready) root.ready = true;
            if (root._again) { root._again = false; statusProc.running = true; }
        }
    }

    Process {
        id: infoProc
        command: ["bash", root.bin, "info"]
        stdout: StdioCollector {
            onStreamFinished: {
                try { root.info = JSON.parse(this.text.trim()); } catch (e) { root.info = null; }
                if (root.info && root.info.installed === false) root.installed = false;
            }
        }
    }

    // ---- turning on and off ------------------------------------------------------
    function turnOn(minutes) {
        if (root.busy !== "") return;
        var m = (minutes === undefined) ? root.minutes : minutes;
        root._run("on", ["on", m > 0 ? String(m) : "forever"]);
    }
    function turnOff() {
        if (root.busy !== "") return;
        root.stopScan();
        root._run("off", ["off"]);
    }
    function toggle() { if (root.on) root.turnOff(); else root.turnOn(); }

    function setVisibility(v) { root._run("visibility", ["visibility", v]); }
    function pickDir() { root._run("dir", ["dir", "--pick"]); }
    function addSender(id) { root._run("senders", ["senders", "add", id]); }
    function removeSender(id) { root._run("senders", ["senders", "remove", id]); }

    function _run(what, args) {
        if (actionProc.running) return;
        root.error = "";
        root.busy = what;
        actionProc.what = what;
        actionProc.command = ["bash", root.bin].concat(args);
        actionProc.running = true;
    }

    Process {
        id: actionProc
        property string what: ""
        stderr: StdioCollector { id: actionErr }
        onExited: function(code) {
            var what = actionProc.what;
            root.busy = "";
            // A cancelled folder chooser (exit 1, nothing said) is an answer.
            var msg = actionErr.text.split("\n").map(function(l) { return l.trim(); })
                                    .filter(function(l) { return l !== "" && l.indexOf("Failed to connect to") !== 0; });
            if (code !== 0 && msg.length > 0) root.error = root.say(msg[msg.length - 1]);
            if (what === "on" && code !== 0) root.loadInfo();
            if (what === "senders") root.loadSenders();
            root.refresh();
            if (what === "on" && code === 0 && root._scanAfterOn) { root._scanAfterOn = false; root._startPeers(); }
            else root._scanAfterOn = false;
        }
    }

    Process {
        id: sendersProc
        command: ["bash", root.bin, "senders", "list", "--json"]
        stdout: StdioCollector {
            onStreamFinished: {
                try { root.senderList = JSON.parse(this.text.trim()) || []; } catch (e) { root.senderList = []; }
            }
        }
    }

    // ---- nearby devices ------------------------------------------------------------
    //  `omdrop peers --json -n --stream`: one JSON object per device, the moment
    //  it answers with its name. A lookup ends by itself; while the list stays
    //  open it is asked again after a short pause. Closing the list stops it
    //  (omdrop takes the Bluetooth advert down with it).
    property bool _scanAfterOn: false
    function scan() {
        root.scanning = true;
        root.peers = [];
        if (!root.on) {
            // Only a visible computer hears anyone: turn it on first, as on an iPhone.
            root._scanAfterOn = true;
            root.turnOn();
            return;
        }
        root._startPeers();
    }
    function stopScan() {
        root.scanning = false;
        root._scanAfterOn = false;
        rescan.stop();
        if (peersProc.running) peersProc.running = false;
    }
    function _startPeers() {
        if (!root.scanning || peersProc.running) return;
        peersProc.running = true;
    }
    function _addPeer(p) {
        if (!p || !p.mac) return;
        var list = root.peers.slice(), found = false;
        for (var i = 0; i < list.length; i++) {
            if (list[i].mac === p.mac) {
                list[i] = { mac: p.mac, rssi: p.rssi, name: p.name || list[i].name };
                found = true;
            }
        }
        if (!found) list.push({ mac: p.mac, rssi: p.rssi, name: p.name || "" });
        root.peers = list;
    }

    Process {
        id: peersProc
        command: ["bash", root.bin, "peers", "--json", "-n", "--stream"]
        stdout: SplitParser {
            onRead: function(line) {
                try { root._addPeer(JSON.parse(line)); } catch (e) {}
            }
        }
        stderr: StdioCollector { id: peersErr }
        onExited: function(code) {
            if (code !== 0 && code !== 143 && root.scanning) {
                var msg = peersErr.text.trim().split("\n");
                if (msg.length > 0 && msg[msg.length - 1] !== "") root.error = root.say(msg[msg.length - 1]);
            }
            if (root.scanning && root.on) rescan.restart();
        }
    }
    Timer { id: rescan; interval: 3000; repeat: false; onTriggered: root._startPeers() }

    // ---- sending ---------------------------------------------------------------
    //  `omdrop send --pick --to MAC`: omdrop opens the file chooser (desktop
    //  portal), then reports in sentences ("Asking them to accept it...",
    //  "Sent photo.jpg (…)"). A cancelled chooser exits 1 without a word.
    function sendTo(mac, name) {
        if (sendProc.running) return;
        root.error = "";
        root.sendMac = mac;
        root.sendName = name || "";
        root.sendLine = "";
        root.sendResult = "";
        sendProc.command = ["bash", root.bin, "send", "--pick", "--to", mac];
        sendProc.running = true;
    }
    function cancelSend() { if (sendProc.running) sendProc.running = false; }

    Process {
        id: sendProc
        stdout: SplitParser { onRead: function(line) { if (line.trim() !== "") root.sendLine = line.trim(); } }
        stderr: SplitParser { onRead: function(line) { if (line.trim() !== "") root.sendLine = line.trim(); } }
        onExited: function(code) {
            if (code === 0) root.sendResult = "ok";
            else if (code === 1 && root.sendLine === "") { root.sendResult = ""; root.sendMac = ""; }
            else root.sendResult = "failed";
        }
    }
}
