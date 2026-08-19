pragma Singleton

import QtQuick
import Quickshell
import Quickshell.Io

// Network status via NetworkManager (nmcli). Polled; lightweight.
Singleton {
    id: root

    property string kind: "disconnected"   // "wifi" | "ethernet" | "disconnected"
    property string name: ""                // SSID or connection name
    property int strength: 0                // wifi signal 0-100

    // ---- WiFi scan list (populated on demand for the network drill-down) ---
    property var wifiList: []               // [{ ssid, signal, security, active }]
    property bool wifiEnabled: true
    property bool scanning: false
    property bool ethernetUp: false

    Process {
        id: scanQuery
        command: ["bash", "-c",
            "nmcli radio wifi 2>/dev/null; echo '###'; " +
            "nmcli -t -f IN-USE,SIGNAL,SECURITY,SSID device wifi list 2>/dev/null"]
        stdout: StdioCollector { onStreamFinished: { root.scanning = false; root.parseScan(this.text); } }
    }
    function refreshWifi() { root.scanning = true; scanQuery.running = true; }
    function parseScan(txt) {
        var parts = txt.split("###");
        root.wifiEnabled = ((parts[0] || "").trim() === "enabled");
        var lines = (parts[1] || "").trim().split("\n");
        var out = [];
        var seen = {};
        for (var i = 0; i < lines.length; i++) {
            var ln = lines[i].trim();
            if (ln === "") continue;
            // fields are colon-separated; SSID may itself contain colons → take first 3, rest = ssid
            var f = ln.split(":");
            if (f.length < 4) continue;
            var inUse = f[0] === "*";
            var sig = parseInt(f[1]) || 0;
            var sec = f[2] || "";
            var ssid = f.slice(3).join(":");
            if (ssid === "" || seen[ssid]) continue;
            seen[ssid] = true;
            out.push({ ssid: ssid, signal: sig, security: sec, active: inUse });
        }
        out.sort(function(a, b) { return b.signal - a.signal; });
        root.wifiList = out;
    }
    function toggleWifi() {
        Quickshell.execDetached(["bash", "-c", "nmcli radio wifi " + (root.wifiEnabled ? "off" : "on")]);
    }

    // ---- dispositivos físicos (para el panel de red estilo radar) ----------
    property string wifiDevice: ""          // p.ej. wlan0 ("" = sin hardware wifi)
    property string ethDevice: ""           // p.ej. eno1
    property bool ethUp: false              // eth con conexión activa
    property string wifiSsid: ""            // SSID activo aunque haya eth
    property int wifiSignal: 0

    // devQuery fusionado en `query` (una sola tabla de dispositivos alimenta
    // ambos parsers) — mitad de forks por tick, mismos datos.
    function parseDevs(txt) {
        var lines = txt.trim().split("\n");
        var wd = "", ed = "", eu = false;
        for (var i = 0; i < lines.length; i++) {
            var f = lines[i].split(":");
            if (f.length < 3) continue;
            if (f[1] === "wifi" && wd === "") wd = f[0];
            if (f[1] === "ethernet") {
                if (ed === "") ed = f[0];
                if (f[2] === "connected") { ed = f[0]; eu = true; }
            }
        }
        root.wifiDevice = wd; root.ethDevice = ed; root.ethUp = eu;
    }

    // ---- redes guardadas (para saber si un SSID pedirá contraseña) ---------
    property var savedNetworks: []
    Process {
        id: savedQuery
        command: ["bash", "-c", "nmcli -t -f NAME connection show 2>/dev/null | grep -v '^lo$'"]
        stdout: StdioCollector {
            onStreamFinished: {
                var t = this.text.trim();
                root.savedNetworks = t ? t.split("\n") : [];
            }
        }
    }
    function refreshSaved() { savedQuery.running = true; }

    // ---- info de la conexión activa (IP / velocidad / MAC / banda) ---------
    property var activeInfo: ({})           // { ip, mac, speed, freq }
    Process {
        id: infoQuery
        command: ["bash", "-c",
            "DEV=$(nmcli -t -f DEVICE,STATE device status 2>/dev/null | awk -F: '$2==\"connected\"{print $1; exit}'); " +
            "[ -z \"$DEV\" ] && exit 0; " +
            "nmcli -t -f GENERAL.HWADDR,IP4.ADDRESS device show \"$DEV\" 2>/dev/null | sed 's/^GENERAL.HWADDR:/mac=/; s/^IP4.ADDRESS\\[1\\]:/ip=/' | grep '='; " +
            "SPD=$(cat /sys/class/net/$DEV/speed 2>/dev/null); [ -n \"$SPD\" ] && [ \"$SPD\" != \"-1\" ] && echo \"speed=${SPD} Mb/s\"; " +
            "FREQ=$(nmcli -t -f IN-USE,FREQ device wifi 2>/dev/null | awk -F: '$1==\"*\"{print $2; exit}'); [ -n \"$FREQ\" ] && echo \"freq=$FREQ\""]
        stdout: StdioCollector {
            onStreamFinished: {
                var out = {};
                var lines = this.text.trim().split("\n");
                for (var i = 0; i < lines.length; i++) {
                    var eq = lines[i].indexOf("=");
                    if (eq > 0) out[lines[i].substring(0, eq)] = lines[i].substring(eq + 1);
                }
                root.activeInfo = out;
            }
        }
    }
    function refreshInfo() { infoQuery.running = true; }

    // ---- conexión con resultado (para el hold-to-connect del radar) --------
    property string connectingId: ""        // ssid/dispositivo en proceso
    property string failedId: ""            // último intento fallido
    Timer { id: failClear; interval: 4000; onTriggered: root.failedId = "" }
    Process {
        id: connectProc
        property string targetId: ""
        property string targetSsid: ""      // no-"" = borrar credencial si falla
        onExited: function(exitCode, exitStatus) {
            if (exitCode !== 0) {
                root.failedId = connectProc.targetId;
                failClear.restart();
                if (connectProc.targetSsid !== "")
                    Quickshell.execDetached(["bash", "-c",
                        "nmcli connection delete " + JSON.stringify(connectProc.targetSsid) + " 2>/dev/null"]);
            }
            root.connectingId = "";
            query.running = true;
            root.refreshSaved();
        }
    }
    function connectWifi(ssid, password) {
        if (!ssid || root.connectingId !== "") return;
        root.connectingId = ssid; root.failedId = "";
        connectProc.targetId = ssid;
        connectProc.targetSsid = ssid;
        connectProc.command = password && password !== ""
            ? ["nmcli", "device", "wifi", "connect", ssid, "password", password]
            : ["nmcli", "device", "wifi", "connect", ssid];
        connectProc.running = true;
    }
    function disconnectWifi() {
        if (root.wifiDevice !== "")
            Quickshell.execDetached(["nmcli", "device", "disconnect", root.wifiDevice]);
    }
    function connectEth() {
        if (root.ethDevice !== "" && root.connectingId === "") {
            root.connectingId = root.ethDevice; root.failedId = "";
            connectProc.targetId = root.ethDevice; connectProc.targetSsid = "";
            connectProc.command = ["nmcli", "device", "connect", root.ethDevice];
            connectProc.running = true;
        }
    }
    function disconnectEth() {
        if (root.ethDevice !== "")
            Quickshell.execDetached(["nmcli", "device", "disconnect", root.ethDevice]);
    }

    // Un ÚNICO spawn por tick: la tabla completa de dispositivos (sección 1)
    // alimenta parseDevs Y de ella se deriva en QML la línea TYPE:CONNECTION
    // del primer dispositivo conectado que `parse` siempre recibió — los dos
    // parsers quedan intactos y el resultado es byte-idéntico al de los dos
    // procesos anteriores. Antes: 2 bash + 3 nmcli cada 5s; ahora 1 bash + 2.
    Process {
        id: query
        command: ["bash", "-c",
            "nmcli -t -f DEVICE,TYPE,STATE,CONNECTION device status 2>/dev/null; " +
            "echo '###'; " +
            // SIGNAL:SSID for the active wifi
            "nmcli -t -f IN-USE,SIGNAL,SSID device wifi 2>/dev/null | awk -F: '$1==\"*\"{print $2\":\"$3; exit}'"]
        running: true
        stdout: StdioCollector { onStreamFinished: root.parseAll(this.text) }
    }
    function parseAll(txt) {
        var parts = txt.split("###");
        var devTable = (parts[0] || "").trim();
        var wifi = (parts[1] || "").trim();
        root.parseDevs(devTable);   // ignora el 4º campo (CONNECTION) — usa 0..2
        // primer dispositivo conectado -> "TYPE:CONNECTION" (el nombre de la
        // conexión puede llevar ':' — se re-une igual que hacía el awk)
        var dev = "";
        var lines = devTable.split("\n");
        for (var i = 0; i < lines.length; i++) {
            var f = lines[i].split(":");
            if (f.length >= 4 && f[2] === "connected") { dev = f[1] + ":" + f.slice(3).join(":"); break; }
        }
        root.parse(dev + "\n###\n" + wifi);
    }

    Timer { interval: 5000; running: true; repeat: true; onTriggered: query.running = true }

    function parse(txt) {
        var parts = txt.split("###");
        var dev = (parts[0] || "").trim();
        var wifi = (parts[1] || "").trim();
        root.ethernetUp = txt.indexOf("ethernet:") !== -1;
        // SSID activo independiente de cuál sea la conexión primaria
        if (wifi !== "") {
            var wj = wifi.indexOf(":");
            root.wifiSignal = parseInt(wifi.substring(0, wj)) || 0;
            root.wifiSsid = wifi.substring(wj + 1) || "";
        } else { root.wifiSsid = ""; root.wifiSignal = 0; }
        if (dev === "") {
            root.kind = "disconnected"; root.name = ""; root.strength = 0;
            return;
        }
        var di = dev.indexOf(":");
        var type = di >= 0 ? dev.substring(0, di) : dev;
        var conn = di >= 0 ? dev.substring(di + 1) : "";
        if (type === "wifi") {
            root.kind = "wifi";
            if (wifi !== "") {
                var wi = wifi.indexOf(":");
                root.strength = parseInt(wifi.substring(0, wi)) || 0;
                root.name = wifi.substring(wi + 1) || conn;
            } else { root.name = conn; root.strength = 0; }
        } else if (type === "ethernet") {
            root.kind = "ethernet"; root.name = conn; root.strength = 100;
        } else {
            root.kind = "ethernet"; root.name = conn; root.strength = 100;
        }
    }
}
