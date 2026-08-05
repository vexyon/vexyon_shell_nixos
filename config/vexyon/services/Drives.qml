pragma Singleton

import QtQuick
import Quickshell
import Quickshell.Io

// ============================================================================
//  Drives — unidades extraíbles (pendrives, SSD/HDD USB) vía udisks2, el mismo
//  servicio de sistema que usan Nautilus/Dolphin/Thunar. udisks2 es
//  D-Bus-activado: no se habilita nada, arranca solo cuando se le llama.
//
//  100% EVENT-DRIVEN, CERO POLLING:
//   * `udisksctl monitor` es una suscripción a las señales de D-Bus de udisks2
//     (InterfacesAdded/Removed y PropertiesChanged). Bloquea en el socket; no
//     hay temporizador periódico en ninguna parte de este fichero.
//   * Cada línea recibida = un cambio real: re-enumeramos. El único Timer es un
//     debounce ONE-SHOT (un enchufe emite varias señales seguidas), disparado
//     por evento, nunca repetitivo.
//   * El monitor corre SOLO mientras hay una ventana del gestor abierta
//     (refcount ref()/unref(), el mismo patrón de Time/Media): con el gestor
//     cerrado no queda ningún proceso vivo.
//
//  Enumerar: ObjectManager.GetManagedObjects de udisks2 en JSON (`busctl`, de
//  systemd, ya presente). Montar/desmontar: `udisksctl`, el cliente propio de
//  udisks2 — su acción polkit `filesystem-mount` es allow_active=yes, así que
//  la sesión local activa monta sin contraseña y NO hace falta regla nueva.
// ============================================================================
Singleton {
    id: root

    // [{ obj, dev, label, size, mount, ejectable }] — solo extraíbles montables
    property var devices: []
    property string lastError: ""
    // Recalculada la lista (enchufe/extracción/montaje). El gestor la escucha
    // para salir de un directorio cuyo dispositivo ha desaparecido.
    signal changed()

    // ---- ciclo de vida: el monitor vive mientras haya gestores abiertos ----
    property int watchers: 0
    function ref() {
        root.watchers++;
        if (root.watchers === 1) monitor.running = true;
        enumerate();
    }
    function unref() {
        root.watchers = Math.max(0, root.watchers - 1);
        if (root.watchers === 0) monitor.running = false;
    }

    function isMounted(path) {
        for (var i = 0; i < root.devices.length; i++)
            if (root.devices[i].mount === path) return true;
        return false;
    }
    // ¿`p` está dentro de algún dispositivo todavía montado?
    function contains(p) {
        for (var i = 0; i < root.devices.length; i++) {
            var m = root.devices[i].mount;
            if (m !== "" && (p === m || p.indexOf(m + "/") === 0)) return true;
        }
        return false;
    }

    // ---- montar / desmontar -------------------------------------------------
    // `cb` (opcional) recibe el punto de montaje cuando la lista ya lo refleja.
    // Es un callback por llamada, no una señal: con varias ventanas del gestor
    // abiertas solo navega la que pidió el montaje.
    property var pendingObj: ""
    property var pendingCb: null
    function mount(dev, obj, cb) {
        root.lastError = "";
        root.pendingObj = obj;
        root.pendingCb = cb || null;
        mounter.command = ["udisksctl", "mount", "-b", dev];
        mounter.running = true;
    }
    function unmount(dev) {
        root.lastError = "";
        unmounter.command = ["udisksctl", "unmount", "-b", dev];
        unmounter.running = true;
    }

    // ---- enumeración --------------------------------------------------------
    property bool enumQueued: false
    function enumerate() {
        if (lister.running) { root.enumQueued = true; return; }
        lister.running = true;
    }

    // Byte-array de D-Bus ('ay', terminado en NUL) -> string. Vía
    // percent-encoding para que las etiquetas con acentos/UTF-8 no se rompan.
    function ayToString(v) {
        if (!v || !v.data) return "";
        var a = v.data, s = "";
        for (var i = 0; i < a.length && a[i] !== 0; i++)
            s += "%" + (a[i] < 16 ? "0" : "") + a[i].toString(16);
        try { return decodeURIComponent(s); } catch (e) { return ""; }
    }
    function prop(iface, name) {
        return (iface && iface[name] !== undefined) ? iface[name].data : undefined;
    }
    function fmtSize(b) {
        if (!b) return "";
        var u = ["B", "KB", "MB", "GB", "TB"], i = 0, v = b;
        while (v >= 1024 && i < u.length - 1) { v /= 1024; i++; }
        return (i === 0 || v >= 10 ? Math.round(v) : v.toFixed(1)) + " " + u[i];
    }

    function parseObjects(text) {
        var objs = JSON.parse(text).data[0];
        // Primero las unidades físicas: el filtro de extraíble vive ahí.
        var drives = {};
        for (var p in objs) {
            var d = objs[p]["org.freedesktop.UDisks2.Drive"];
            if (!d) continue;
            drives[p] = {
                removable: prop(d, "Removable") === true,
                bus: prop(d, "ConnectionBus") || "",
                ejectable: prop(d, "Ejectable") === true,
                name: ((prop(d, "Vendor") || "") + " " + (prop(d, "Model") || "")).trim()
            };
        }
        var out = [];
        for (var q in objs) {
            var o = objs[q];
            var b = o["org.freedesktop.UDisks2.Block"];
            var f = o["org.freedesktop.UDisks2.Filesystem"];
            // Sin interfaz Filesystem no hay nada que montar (discos enteros con
            // tabla de particiones, swap, zram... quedan fuera solos).
            if (!b || !f) continue;
            if (prop(b, "HintIgnore") === true) continue;
            if (prop(b, "HintSystem") === true) continue;
            var dr = drives[prop(b, "Drive") || ""];
            if (!dr) continue;                       // sin unidad física detrás
            if (!dr.removable && dr.bus !== "usb") continue;

            var dev = ayToString(b.Device);
            var mps = (f.MountPoints && f.MountPoints.data) || [];
            var label = prop(b, "IdLabel") || prop(b, "HintName") || dr.name
                        || dev.split("/").pop();
            out.push({
                obj: q,
                dev: dev,
                label: label,
                size: fmtSize(prop(b, "Size")),
                mount: mps.length > 0 ? ayToString({ data: mps[0] }) : "",
                ejectable: dr.ejectable
            });
        }
        out.sort(function(a, b2) { return a.dev < b2.dev ? -1 : 1; });
        return out;
    }

    Process {
        id: lister
        command: ["busctl", "--system", "--json=short", "call",
                  "org.freedesktop.UDisks2", "/org/freedesktop/UDisks2",
                  "org.freedesktop.DBus.ObjectManager", "GetManagedObjects"]
        stdout: StdioCollector {
            onStreamFinished: {
                try { root.devices = root.parseObjects(this.text); }
                catch (e) {
                    // udisks2 ausente o respuesta inesperada: lista vacía, sin ruido
                    // repetido y sin reintentos en bucle.
                    root.devices = [];
                    console.warn("[Drives] udisks2 enumerate failed:", e);
                }
                root.changed();
                // Navegar al dispositivo recién montado (petición pendiente).
                if (root.pendingObj !== "") {
                    for (var i = 0; i < root.devices.length; i++) {
                        var d = root.devices[i];
                        if (d.obj !== root.pendingObj || d.mount === "") continue;
                        var cb = root.pendingCb;
                        root.pendingObj = ""; root.pendingCb = null;
                        if (cb) cb(d.mount);
                        break;
                    }
                }
            }
        }
        onExited: if (root.enumQueued) { root.enumQueued = false; root.enumerate(); }
    }

    // Suscripción a las señales de D-Bus de udisks2. stdbuf -oL: sin él glib
    // bloquearía la salida en buffer al no ser un tty y los eventos llegarían
    // tarde o a ráfagas.
    Process {
        id: monitor
        command: ["stdbuf", "-oL", "udisksctl", "monitor"]
        stdout: SplitParser {
            onRead: function(line) {
                // No hace falta interpretar la línea: cualquier señal que cite un
                // objeto de udisks2 significa "algo cambió" y la verdad se relee
                // entera del ObjectManager. Las dos líneas de cabecera del
                // monitor no citan ninguna y se ignoran solas.
                if (line.indexOf("/org/freedesktop/UDisks2") < 0) return;
                enumDebounce.restart();
            }
        }
        // Si muere (udisks2 no instalado), NO se reintenta: un respawn
        // automático sería un bucle caliente disfrazado de evento.
        onExited: function(code) {
            if (root.watchers > 0)
                console.warn("[Drives] udisksctl monitor exited (" + code + ") — hotplug live updates off");
        }
    }
    // One-shot: un enchufe emite varias señales seguidas y se re-enumera una vez.
    Timer {
        id: enumDebounce
        interval: 120
        onTriggered: root.enumerate()
    }

    Process {
        id: mounter
        stderr: StdioCollector {
            onStreamFinished: if (this.text !== "") root.lastError = this.text.trim()
        }
        onExited: function(code) {
            if (code !== 0) { root.pendingObj = ""; root.pendingCb = null; }
            root.enumerate();
        }
    }
    Process {
        id: unmounter
        stderr: StdioCollector {
            onStreamFinished: if (this.text !== "") root.lastError = this.text.trim()
        }
        onExited: root.enumerate()
    }
}
