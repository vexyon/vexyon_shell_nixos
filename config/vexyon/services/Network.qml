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
            "FREQ=$(nmcli -t -f IN-USE,FREQ device wifi list --rescan no 2>/dev/null | awk -F: '$1==\"*\"{print $2; exit}'); [ -n \"$FREQ\" ] && echo \"freq=$FREQ\""]
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

    // ---- DNS de la conexión activa (selector del panel de red) -------------
    //  POR CONEXIÓN, no global: se guarda en el perfil de NM de la conexión
    //  activa del dispositivo (la Wi-Fi de casa puede ir por Cloudflare y la
    //  del bar seguir en automático) y viaja con ese perfil. Nada global en
    //  NetworkManager.conf, nada que pida root.
    //  Leer: `device show` = los servidores que el dispositivo USA (vengan de
    //  DHCP/RA o del perfil) + `connection show` = lo que pide el perfil.
    //  Aplicar: `connection modify` + `device reapply`, que mete el cambio en
    //  la conexión viva SIN desactivarla (medido: ~20 ms, sigue "connected").
    //  Solo si NM rechaza el reapply se reactiva con `connection up` (corte de
    //  unos segundos) y el panel lo dice. Sin sondeo: se lee al abrir el
    //  panel, al cambiar de pestaña/conexión y tras aplicar.
    readonly property var dnsPresets: [
        { id: "auto",       v4: [], v6: [] },
        { id: "cloudflare", v4: ["1.1.1.1", "1.0.0.1"],         v6: ["2606:4700:4700::1111", "2606:4700:4700::1001"] },
        { id: "google",     v4: ["8.8.8.8", "8.8.4.4"],         v6: ["2001:4860:4860::8888", "2001:4860:4860::8844"] },
        { id: "quad9",      v4: ["9.9.9.9", "149.112.112.112"], v6: ["2620:fe::fe", "2620:fe::9"] }
    ]
    // { dev, uuid, name, active4, active6, cfg4, cfg6, ignore, v6ok, preset }
    property var dns: ({})
    property string dnsState: ""            // "" | applying | reconnecting | applied | reconnected | error
    property string dnsError: ""

    Process {
        id: dnsQuery
        property string dev: ""
        command: ["bash", "-c",
            "nmcli -t -f GENERAL.CONNECTION,GENERAL.CON-UUID,IP4.DNS,IP6.DNS device show \"$1\" 2>/dev/null; " +
            "u=$(nmcli -g GENERAL.CON-UUID device show \"$1\" 2>/dev/null); " +
            "[ -n \"$u\" ] && nmcli -t -f ipv4.dns,ipv4.ignore-auto-dns,ipv6.dns,ipv6.method connection show \"$u\" 2>/dev/null",
            "vxdns", dnsQuery.dev]
        stdout: StdioCollector { onStreamFinished: root.parseDns(dnsQuery.dev, this.text) }
    }
    function refreshDns(dev) {
        if (!dev) { root.dns = ({}); return; }
        dnsQuery.dev = dev;
        dnsQuery.running = true;
    }
    function parseDns(dev, txt) {
        // multiline terse: "CAMPO:valor" — el valor puede llevar ':' (IPv6,
        // nombres), así que se corta solo en el primero
        var d = { dev: dev, uuid: "", name: "", active4: [], active6: [], cfg4: [], cfg6: [],
                  ignore: false, v6ok: true, preset: "auto" };
        var lines = txt.split("\n");
        for (var i = 0; i < lines.length; i++) {
            var c = lines[i].indexOf(":");
            if (c <= 0) continue;
            var k = lines[i].substring(0, c), v = lines[i].substring(c + 1).trim();
            if (k === "GENERAL.CONNECTION") d.name = v;
            else if (k === "GENERAL.CON-UUID") d.uuid = v;
            else if (k.indexOf("IP4.DNS") === 0 && v !== "") d.active4.push(v);
            else if (k.indexOf("IP6.DNS") === 0 && v !== "") d.active6.push(v);
            else if (k === "ipv4.dns" && v !== "") d.cfg4 = v.split(",");
            else if (k === "ipv6.dns" && v !== "") d.cfg6 = v.split(",");
            else if (k === "ipv4.ignore-auto-dns") d.ignore = (v === "yes");
            // NM rechaza ipv6.dns con method ignore/disabled (probado): sin
            // IPv6 en el perfil, solo se toca IPv4
            else if (k === "ipv6.method") d.v6ok = (v !== "ignore" && v !== "disabled");
        }
        if (d.ignore || d.cfg4.length > 0 || d.cfg6.length > 0) {
            d.preset = "custom";
            for (var p = 1; p < root.dnsPresets.length; p++)
                if (root.dnsPresets[p].v4.join(",") === d.cfg4.join(",")) d.preset = root.dnsPresets[p].id;
        }
        root.dns = d;
    }

    Process {
        id: dnsApply
        // Salida: 2 = el perfil no se pudo modificar (dirección no válida,
        // permisos) -> nada cambió; 3 = el perfil cambió pero ni reapply ni
        // reactivar lo aplicaron. Por stdout, en orden: "reconnect" justo
        // antes de reactivar (corte breve; el panel lo enseña mientras dura)
        // y "err:<mensaje de nmcli>" si algo falla.
        property bool reconnected: false
        command: ["true"]
        stdout: SplitParser {
            onRead: function(line) {
                if (line === "reconnect") { dnsApply.reconnected = true; root.dnsState = "reconnecting"; }
                else if (line.indexOf("err:") === 0) root.dnsError = line.substring(4).replace(/^Error:\s*/, "");
            }
        }
        onExited: function(code) {
            if (code === 0) { root.dnsError = ""; root.dnsState = dnsApply.reconnected ? "reconnected" : "applied"; }
            else root.dnsState = "error";
            root.refreshDns(root.dns.dev);
        }
    }
    // v4/v6: listas de servidores; ambas vacías = automático (DHCP/RA).
    // Con servidores propios se ignoran los automáticos de LAS DOS familias:
    // si no, los que anuncia el router por IPv6 seguirían colándose y la
    // elección no mandaría. Sin servidores IPv6 en la lista, IPv6 no lleva
    // DNS propio (los de IPv4 resuelven también AAAA).
    function setDns(v4, v6) {
        var d = root.dns;
        if (!d.uuid || !d.dev || dnsApply.running) return;
        var auto = v4.length === 0 && v6.length === 0;
        root.dnsState = "applying"; root.dnsError = ""; dnsApply.reconnected = false;
        dnsApply.command = ["bash", "-c",
            "u=$1 d=$2 v4=$3 v6=$4 ig=$5 six=$6; " +
            "set -- connection modify \"$u\" ipv4.dns \"$v4\" ipv4.ignore-auto-dns \"$ig\"; " +
            "[ \"$six\" = 1 ] && set -- \"$@\" ipv6.dns \"$v6\" ipv6.ignore-auto-dns \"$ig\"; " +
            "o=$(nmcli \"$@\" 2>&1) || { echo \"err:${o##*$'\\n'}\"; exit 2; }; " +
            "nmcli device reapply \"$d\" >/dev/null 2>&1 && exit 0; " +
            "echo reconnect; o=$(nmcli connection up \"$u\" 2>&1 >/dev/null) && exit 0; echo \"err:${o##*$'\\n'}\"; exit 3",
            "vxdns", d.uuid, d.dev, v4.join(","), (d.v6ok ? v6 : []).join(","),
            auto ? "no" : "yes", d.v6ok ? "1" : "0"];
        dnsApply.running = true;
    }

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
    //
    // ⚠️ `--rescan no` es obligatorio desde la fusión. `nmcli device wifi` a
    // secas usa --rescan auto: si el último escaneo tiene >30 s PIDE uno y
    // espera hasta 15 s (nmcli devices.c, timeout_msec = 15000). Antes la tabla
    // de dispositivos salía de su propio proceso (~ms); al fusionarla quedó
    // detrás de ese escaneo, y hasta que acaba wifiDevice/ethDevice siguen ""
    // y el panel solo enseña Bluetooth. La señal de la red activa sale de la
    // caché de NM; el escaneo de verdad lo pide el panel (refreshWifi). Va con
    // `list` explícito: `device wifi --rescan no` lo rechaza nmcli (rc 2).
    Process {
        id: query
        command: ["bash", "-c",
            "nmcli -t -f DEVICE,TYPE,STATE,CONNECTION device status 2>/dev/null; " +
            "echo '###'; " +
            // SIGNAL:SSID for the active wifi
            "nmcli -t -f IN-USE,SIGNAL,SSID device wifi list --rescan no 2>/dev/null | awk -F: '$1==\"*\"{print $2\":\"$3; exit}'"]
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
