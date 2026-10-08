pragma Singleton

import QtQuick
import Quickshell
import Quickshell.Io
import qs.services

// ============================================================================
//  Vm — fachada de libvirt/QEMU sobre `virsh`. ÚNICA puerta del shell hacia la
//  virtualización: el gestor, el panel de barra y la página de Ajustes leen de
//  aquí y nadie más lanza un `virsh`.
//
//  COSTE CERO CON EL INTERRUPTOR APAGADO — la regla que manda sobre todo:
//   * NINGÚN Process de este fichero lleva `running: true`. Todos arrancan
//     desde una función, y TODA función pública sale por la puerta de atrás
//     si `enabled` es false. Con el interruptor apagado este singleton es un
//     puñado de propiedades en RAM y nada más: ni proceso, ni socket, ni fichero.
//   * NO HAY NINGÚN Timer. Ni de sondeo ni de rebote. El estado se relee por
//     PETICIÓN: al abrir el gestor, al abrir el panel de barra, al terminar
//     cualquier acción del usuario y con el botón de recargar. Es el mismo
//     criterio que Drives (que sí tiene monitor porque udisks2 ofrece señales
//     de D-Bus gratis) pero sin suscripción: aquí no se abre ninguna.
//   * El interruptor vive en shell.json (`virtualization.enabled`, por defecto
//     false). Los puntos que NO deben instanciar este singleton cuando está
//     apagado (catálogo de widgets, lanzador, shell.qml) leen Config
//     DIRECTAMENTE en vez de mirar `Vm.enabled` — si preguntaran aquí, el mero
//     hecho de preguntar crearía el singleton. Ver PROJECT_STATE.md.
//
//  UNA SOLA LECTURA POR REFRESCO: `refresh()` lanza UN bash que emite el estado
//  entero (dominios + redes + pool) en secciones @@; parsearlo en QML es
//  gratis comparado con encadenar procesos desde aquí. Mismo patrón que el
//  poller de SystemStats.
//
//  ⚠️ `-c qemu:///system` SIEMPRE, explícito. La URI por DEFECTO de virsh para
//  un usuario normal es `qemu:///session` (medido en esta máquina: `virsh uri`
//  → qemu:///session), que es OTRO hipervisor, con otros dominios y sin red
//  NAT. Omitirlo hace que el shell mire un sitio vacío mientras las VMs reales
//  viven en el de sistema.
// ============================================================================
Singleton {
    id: root

    // ---- interruptor -------------------------------------------------------
    readonly property bool enabled: Config.get("virtualization", "enabled", false) === true

    readonly property string uri: "qemu:///system"
    // Prefijo común de toda invocación. LC_ALL=C: las etiquetas de `dominfo`
    // (State:, Max memory:…) son las que se parsean, y aunque virsh no las
    // traduce hoy, fijar el locale quita la dependencia de que siga así.
    readonly property string sh: "export LC_ALL=C; V='virsh -c " + root.uri + "'; "

    // Editor del XML de dominio. Filtro puro stdin->stdout en python3 (que ya
    // es dependencia del shell por el bridge), así no hace falta ni `virsh
    // edit` interactivo ni sed sobre XML. Misma resolución de ruta que
    // Wallpaper.genBin: VEXYON_BIN_DIR en NixOS, ~/.config/vexyon/bin en Arch.
    readonly property string xmlBin: {
        var d = Quickshell.env("VEXYON_BIN_DIR");
        var base = (d && d !== "") ? d : Quickshell.env("HOME") + "/.config/vexyon/bin";
        return base + "/vexyon-vm-xml";
    }
    // Fragmento reusable: config PERSISTENTE de un dominio por la tubería del
    // editor y de vuelta a libvirt.
    //  ⚠️ `--inactive` NO es opcional. `virsh dumpxml` a secas devuelve la
    //  config VIVA de un dominio encendido, que incluye cosas de tiempo de
    //  ejecución (alias, direcciones PCI asignadas, vnetN…). Redefinir eso
    //  congelaría datos de esta ejecución en la definición persistente.
    //  Medido: con la VM encendida, `dumpxml` y `dumpxml --inactive` dan
    //  resultados DISTINTOS tras editar la persistente.
    function editXml(name, args) {
        return "$V dumpxml --inactive " + q(name) + " | " + q(root.xmlBin) + " " + args
             + " | $V define /dev/stdin >/dev/null";
    }

    // ---- estado (siempre en caché; se relee por petición) -------------------
    // [{ name, state, maxMemKib, curMemKib, vcpus, autostart, uuid }]
    property var vms: []
    // [{ name, state, autostart, persistent }]
    property var networks: []
    // estado del pool de almacenamiento por defecto ("" = no existe)
    property string poolState: ""
    // [{ name, created, state }] del dominio pedido en snapshots()
    property var snapshots: []
    property string snapshotsOf: ""

    // ---- hardware de UNA VM (la seleccionada en el gestor) -----------------
    //  Se lee de la config PERSISTENTE: es la que se edita. Lo que está vivo
    //  ahora mismo puede diferir, y por eso la UI avisa de "al reiniciar".
    property string detailOf: ""
    property var detail: ({
        disks: [], nics: [], ctrls: [], video: null, cpu: null, boot: [],
        chans: [], fs: [], usbdevs: [], graphics: null, redir: 0,
        desc: "", title: "", firmware: "bios", sound: "", tpm: null
    })
    // ¿tiene el canal del agente SPICE? Sin él NO hay portapapeles compartido
    // ni redimensionado automático del invitado, por mucho que el invitado
    // lleve spice-vdagent instalado.
    //  ¿lleva un TPM 2.0? Windows 11 no pasa de la primera pantalla sin uno:
    //  "El equipo debe admitir TPM 2.0". Se mira la config del dominio, que es
    //  lo único comprobable sin arrancar el invitado.
    readonly property bool hasTpm2: root.detail.tpm !== null
                                 && root.detail.tpm !== undefined
                                 && root.detail.tpm.version === "2.0"
    readonly property bool hasSpiceAgent: {
        for (var i = 0; i < root.detail.chans.length; i++)
            if (root.detail.chans[i].name === "com.redhat.spice.0") return true;
        return false;
    }
    readonly property bool clipboardOn: root.detail.graphics
                                        && root.detail.graphics.clipboard === "yes"

    // Dispositivos USB del anfitrión: [{ vendor, product, label, cls }]
    property var hostUsb: []
    // Puentes de red del anfitrión: ["br0", …]. Se leen de /sys/class/net —
    // un interfaz es un puente si tiene subdirectorio `bridge`. Sin `brctl` ni
    // `bridge-utils`, que no son dependencias del shell.
    property var hostBridges: []
    //  Los puentes del anfitrión a los que tiene sentido enchufar un adaptador
    //  en modo puente. Fuera los de las redes de libvirt (virbrN): engancharse
    //  a uno a pelo se salta la red, y el adaptador se suelta en cuanto esa red
    //  se reinicia. Fuera también los de Docker (docker0, br-<id>).
    readonly property var userBridges: root.hostBridges.filter(function(b) {
        if (b === "docker0" || /^br-[0-9a-f]{12}$/.test(b)) return false;
        for (var i = 0; i < root.networks.length; i++)
            if (root.networks[i].bridge === b) return false;
        return true;
    })
    // Adaptadores de las VMs ENCENDIDAS tal como están ahora:
    // [{ vm, tap, type, source, mac }]. Sale del mismo refresco (un `domiflist`
    // por VM encendida) y es lo que deja decir ANTES de parar o borrar una red
    // qué VMs encendidas se quedarían colgando.
    property var liveNics: []
    // Resultado del diagnóstico de redes (solo a petición, botón en la pestaña
    // de redes): [{ level: "bad"|"warn"|"info", title, detail, fix, net,
    // settings }]. `net` = red con adaptadores que se pueden reenganchar;
    // `settings` = el arreglo está en Ajustes → Virtualización.
    property var netDiag: []
    property bool netDiagRan: false
    readonly property bool netDiagBusy: netDiagProc.running
    readonly property string ovaBin: {
        var d = Quickshell.env("VEXYON_BIN_DIR");
        var base = (d && d !== "") ? d : Quickshell.env("HOME") + "/.config/vexyon/bin";
        return base + "/vexyon-vm-ova";
    }

    property bool busy: false          // hay una acción en vuelo
    property string lastError: ""      // stderr de la última acción fallida
    // Aviso NO fatal: la parte persistente se aplicó pero la del dominio vivo
    // no. No es un error (la acción se guardó), pero el usuario TIENE que
    // enterarse de que no lo verá dentro de la VM hasta reiniciarla.
    property string lastNote: ""
    property string lastAction: ""     // etiqueta legible de esa acción
    // Mensaje de "ha ido bien" (verde). Solo lo ponen las acciones largas: en
    // una que dura un parpadeo el resultado ya se ve en la propia lista.
    property string lastSuccess: ""

    // ---- progreso de las operaciones largas ---------------------------------
    //  Lo llenan las líneas @@PHASE / @@PROG / @@PCT que escriben por STDOUT el
    //  ayudante de OVA y el propio script, leídas SEGÚN LLEGAN con un
    //  SplitParser. NO hay temporizador: lo que empuja cada línea es el dato
    //  que está pasando por la tubería en ese momento.
    property string progPhase: ""      // clave i18n de la fase; "" = nada en vuelo
    property int    progStep: 0        // fase actual (1..progSteps)
    property int    progSteps: 0       // cuántas fases tiene la operación
    property real   progDone: 0        // bytes hechos
    property real   progTotal: 0       // bytes totales (0 = no se sabe)
    property real   progPct: -1        // 0..100 si informa qemu-img; -1 = usar bytes
    readonly property bool progressing: root.progPhase !== ""
    // Fracción 0..1 de la FASE actual, o -1 si esta fase no sabe cuánto queda.
    readonly property real progFraction: {
        if (root.progPct >= 0) return Math.max(0, Math.min(1, root.progPct / 100));
        if (root.progTotal > 0) return Math.max(0, Math.min(1, root.progDone / root.progTotal));
        return -1;
    }
    function _clearProgress() {
        root.progPhase = ""; root.progStep = 0; root.progSteps = 0;
        root.progDone = 0; root.progTotal = 0; root.progPct = -1;
    }
    // Una línea de stdout. Devuelve true si era de progreso (y ya está tratada).
    function _progLine(line) {
        if (line.indexOf("@@") !== 0) return false;
        var f = line.split("\t");
        if (f[0] === "@@PHASE") {
            root.progStep  = parseInt(f[1], 10) || 0;
            root.progSteps = parseInt(f[2], 10) || 0;
            root.progPhase = f[3] || "";
            root.progDone = 0; root.progTotal = 0; root.progPct = -1;
            return true;
        }
        if (f[0] === "@@PROG") {
            root.progDone  = parseFloat(f[1]) || 0;
            root.progTotal = parseFloat(f[2]) || 0;
            root.progPct = -1;
            return true;
        }
        if (f[0] === "@@PCT") { root.progPct = parseFloat(f[1]) || 0; return true; }
        return false;
    }
    // Clave en inglés de cada fase; la traduce quien la pinta. Se guardan aquí
    // y no en la UI porque quien decide las fases es el script, no la ventana.
    function phaseText(key) {
        switch (key) {
        case "download":      return "Copying the disk out of the storage pool…";
        case "convert-vmdk":  return "Converting the disk to VMDK…";
        case "package":       return "Packaging the .ova…";
        case "extract":       return "Unpacking the .ova…";
        case "convert-qcow2": return "Converting the disk to qcow2…";
        case "upload":        return "Copying the disk into the storage pool…";
        case "define":        return "Defining the virtual machine…";
        }
        return key;
    }

    // Se emite cuando `vms`/`networks` acaban de recalcularse.
    signal refreshed()
    // Se emite al terminar una acción del usuario (ok o no). El gestor y el
    // panel lo escuchan para releer: refresco POR EVENTO, no por temporizador.
    signal actionDone(string action, bool ok)

    // ¿hay alguna VM corriendo? — de esto depende que la pastilla de barra
    // exista o no. Es una propiedad DERIVADA de la caché: leerla no lanza nada.
    readonly property var runningVms: root.vms.filter(function(v) { return v.state === "running" || v.state === "paused"; })
    readonly property bool anyRunning: root.runningVms.length > 0

    // ---- detección granular (para la página de Ajustes) --------------------
    //  Cada pieza por separado, nunca "todo o nada": el usuario tiene que ver
    //  QUÉ le falta. `detected` pasa a true cuando la sonda ha contestado.
    property bool detected: false
    property var has: ({
        virsh: false, qemu: false, viewer: false, libvirtd: false,
        grpLibvirt: false, grpKvm: false, kvmdev: false, swtpm: false, uefi: false,
        virtiofs: false
    })
    property string osId: ""
    property string osLike: ""
    property string osName: ""

    // Plataforma para elegir el texto de instalación. Deliberadamente CORTA:
    // solo se reconocen las familias cuyos nombres de paquete se han
    // verificado; cualquier otra cae en "unknown" y recibe la lista genérica
    // de componentes, NUNCA nombres de paquete inventados.
    readonly property string platform: {
        var id = root.osId.toLowerCase();
        var like = " " + root.osLike.toLowerCase() + " ";
        if (id === "nixos") return "nixos";
        if (id === "arch" || id === "cachyos" || id === "endeavouros" || id === "manjaro"
            || id === "artix" || like.indexOf(" arch ") !== -1) return "arch";
        return "unknown";
    }

    // Todo lo IMPRESCINDIBLE está. virt-viewer y swtpm quedan fuera a
    // propósito: sin virt-viewer se sigue pudiendo usar la consola de texto y
    // sin swtpm todo funciona salvo un TPM virtual (Windows 11).
    readonly property bool requirementsMet: root.detected && root.has.virsh && root.has.qemu
                                            && root.has.libvirtd && root.has.grpLibvirt
                                            && root.has.grpKvm && root.has.kvmdev

    // ---- sondas ------------------------------------------------------------
    function detect() {
        if (!root.enabled) return;
        detector.running = true;
    }

    // ¿Se ha leído el estado alguna vez en esta sesión? La pastilla de barra la
    // usa para hacer UNA sola lectura de arranque (una VM puede estar corriendo
    // desde antes de arrancar el shell) y no repetirla en cada reconstrucción
    // de la barra.
    property bool primed: false
    property bool _primeStarted: false
    // Alguien ya ha pedido el arranque, aunque no se pudiera atender todavía.
    property bool _primeWanted: false

    // Arranque de UNA sola vez: lee el estado (por si ya había una VM encendida
    // antes que el shell) y sondea los componentes. Lo segundo hace falta aquí
    // y no solo en Ajustes porque el panel de barra decide con `has.viewer` si
    // ofrecer "Abrir pantalla"; sin sondear, ese botón no saldría nunca aunque
    // virt-viewer esté instalado.
    //
    //  ⚠️ CARRERA CON Config, vista en vivo: quien llama a prime() (la pastilla
    //  de barra al crearse, la página de Ajustes al construirse) puede hacerlo
    //  ANTES de que el FileView de Config haya parseado shell.json. En ese
    //  instante `enabled` todavía es false y una llamada suelta se perdía para
    //  siempre — la página se quedaba en "Comprobando…" con todo sin resolver.
    //  Por eso la petición se RECUERDA (_primeWanted) y se reintenta sola en
    //  cuanto `enabled` pasa a true. No es un temporizador: es la señal de
    //  cambio de la propiedad, que es puro evento.
    function prime() {
        root._primeWanted = true;
        if (root._primeStarted || !root.enabled) return;
        root._primeStarted = true;
        root.refresh();
        root.detect();
    }
    onEnabledChanged: if (root.enabled && root._primeWanted) root.prime()

    property bool _refreshQueued: false
    function refresh() {
        if (!root.enabled) return;
        if (prober.running) { root._refreshQueued = true; return; }
        prober.running = true;
    }

    // Lista de snapshots de un dominio. Se parsea la tabla de `snapshot-list`
    // y NO se llama a `snapshot-info` por cada una: `snapshot-info` NO trae la
    // fecha (medido con libvirt 12.2.0 — sus campos son Name/Domain/Current/
    // State/Location/Parent/Children/Descendants/Metadata). La fecha solo sale
    // en esta tabla, así que además sale gratis: una llamada en vez de N+1.
    //   " snapA   2026-08-20 21:22:01 +0200   running"
    //   $1 = nombre, $NF = estado, lo de en medio = fecha (lleva espacios).
    function snapshots_(name) {
        if (!root.enabled || !name) return;
        root.snapshotsOf = name;
        snapLister.command = ["bash", "-c", root.sh +
            "$V snapshot-list " + q(name) + " 2>/dev/null | tail -n +3 | " +
            "awk 'NF { n=$1; st=$NF; c=\"\"; for (i=2; i<NF; i++) c = c (c==\"\" ? \"\" : \" \") $i; " +
            "printf \"%s\\t%s\\t%s\\n\", n, c, st }'"];
        snapLister.running = true;
    }

    // ======================================================================
    //  RUTAS — expansión y validación
    //
    //  ⚠️ libvirt NO es un shell: una `~` en el XML del dominio se guarda
    //  LITERAL y falla con «Cannot access storage file '~/…': No such file or
    //  directory» (reproducido en la torre). Toda ruta que venga de la UI pasa
    //  por aquí ANTES de tocar libvirt.
    //
    //  Sobre PERMISOS, que es lo que parecía el problema y no lo era: en las
    //  DOS plataformas qemu corre como ROOT por defecto — libvirt trae
    //  `user = "root"` de fábrica (comentado en el qemu.conf que se distribuye,
    //  o sea que manda el valor compilado), y en NixOS `runAsRoot = true` es
    //  además el defecto del módulo. Comprobado en vivo: una ISO dentro de un
    //  $HOME 0700 arranca sin problema con la ruta ABSOLUTA. Lo que fallaba era
    //  solo la `~`. Aun así, si alguien pone qemu a correr como usuario sin
    //  privilegios, esto deja de valer: por eso el error de libvirt se traduce
    //  a algo accionable en vez de enseñarlo en crudo.
    // ======================================================================
    readonly property string homeDir: Quickshell.env("HOME")

    function expandPath(p) {
        var s = String(p === undefined || p === null ? "" : p).trim();
        if (s === "") return "";
        // comillas que el usuario haya pegado sin querer
        if ((s.length > 1) && ((s[0] === '"' && s[s.length - 1] === '"')
                            || (s[0] === "'" && s[s.length - 1] === "'")))
            s = s.slice(1, -1);
        var h = root.homeDir;
        if (s === "~") return h;
        if (s.indexOf("~/") === 0)        return h + s.slice(1);
        if (s.indexOf("$HOME/") === 0)    return h + s.slice(5);
        if (s === "$HOME")                return h;
        if (s.indexOf("${HOME}/") === 0)  return h + s.slice(7);
        if (s === "${HOME}")              return h;
        // una ruta relativa se resuelve contra $HOME: libvirt exige absoluta y
        // "Descargas/x.iso" solo puede querer decir eso.
        if (s.indexOf("/") !== 0) return h + "/" + s;
        return s;
    }

    // Prólogo de shell que comprueba que la ruta existe y se puede leer ANTES
    // de llamar a virsh, y que da un error con la ruta YA RESUELTA. Sin esto el
    // usuario ve el mensaje de libvirt, que repite la ruta sin expandir y
    // despista.
    function pathGuard(resolved, what) {
        return "P=" + q(resolved) + "; " +
               "[ -e \"$P\" ] || { printf '%s' " +
                 q(I18n.t("Not found: ") + resolved) + " >&2; exit 1; }; " +
               "[ -r \"$P\" ] || { printf '%s' " +
                 q(I18n.t("Cannot read: ") + resolved) + " >&2; exit 1; }; ";
    }

    // Traduce el fallo típico de permisos de libvirt a algo que se pueda hacer.
    //  Texto del aviso ámbar: cada línea se traduce por separado y, si trae
    //  "clave\tdetalle", se traduce la clave y el detalle va detrás tal cual.
    function noteText(t) {
        return String(t || "").split("\n").map(function(l) {
            var k = l.indexOf("\t");
            return k === -1 ? I18n.t(l) : I18n.t(l.slice(0, k)) + " " + l.slice(k + 1);
        }).join("\n");
    }
    function humanizeError(t) {
        if (t.indexOf("Cannot access storage file") !== -1
            || t.indexOf("Permission denied") !== -1) {
            return t + "\n\n" + I18n.t("libvirt could not read that file. Its QEMU process usually runs as root and can read anywhere, so this normally means the path is wrong, or QEMU has been configured to run as an unprivileged user. Putting the file in /var/lib/libvirt/images/ always works.");
        }
        return t;
    }

    // Comilla simple para shell: 'x' con los ' internos escapados. Todo nombre
    // que venga de la UI pasa por aquí antes de tocar una línea de comandos.
    function q(s) { return "'" + String(s).replace(/'/g, "'\\''") + "'"; }

    // ---- acciones ----------------------------------------------------------
    //  Todas comparten el mismo Process: una acción cada vez (la UI se
    //  deshabilita mientras `busy`), y al terminar SIEMPRE se relee el estado.
    //  Ese re-refresco es el que hace que la pastilla de barra aparezca o
    //  desaparezca sin que exista ningún temporizador vigilando.
    function run(action, script) {
        if (!root.enabled) return;
        root.lastError = "";
        root.lastNote = "";
        root.lastSuccess = "";
        root._clearProgress();
        root.lastAction = action;
        root.busy = true;
        actor.command = ["bash", "-c", root.sh + script];
        actor.running = true;
    }

    property bool _liveFailed: false
    // Texto que ve el usuario cuando solo falló la parte en caliente. Lo
    // traduce I18n en el punto de uso; aquí se guarda la clave en inglés.
    readonly property string liveFailNote:
        "Saved to the VM's configuration, but it could not be applied to the running VM. It will be there after you restart it."

    // Config PRIMERO y en caliente DESPUÉS, como dos órdenes separadas.
    //  ⚠️ Por qué no `--config --live` en la misma orden (medido en la torre):
    //  si la mitad viva falla, virsh devuelve error y la persistente puede
    //  haberse aplicado igualmente -> el dominio vivo y su definición quedan
    //  DESCUADRADOS, y la siguiente orden falla con "No disk found whose
    //  source path or target is vdb" sobre algo que sí está en la config.
    //  Separándolas, la config manda (si esa falla, se aborta) y la parte viva
    //  es un intento que, si no sale, se AVISA en vez de romper nada.
    function cfgLive(name, cfgCmd, liveCmd) {
        // ⚠️ Si está encendida o no se pregunta AQUÍ, en el shell, con
        // `domstate` — NO con `Vm.isRunning()`. La caché de QML puede estar
        // vacía o ir por detrás (medido: recién arrancado el shell, `vms` aún
        // no se había leído, `isRunning` devolvía false y la mitad EN CALIENTE
        // no llegaba a emitirse: el disco entraba en la config y no aparecía
        // dentro de la VM, sin aviso ninguno).
        return "RUN=0; [ \"$($V domstate " + q(name) + " 2>/dev/null)\" = running ] && RUN=1; " +
               cfgCmd + " --config || exit 1; " +
               "[ \"$RUN\" = 1 ] && { " + liveCmd + " --live 2>/dev/null || printf '@@LIVEFAIL' >&2; }; :";
    }

    // Arrancar. Si `virtualization.openOnStart` está puesto (lo está de fábrica,
    // que es lo que hace VirtualBox y lo que el usuario espera), al terminar se
    // abre la pantalla de la VM.
    //
    //  ⚠️ NO se lanza virt-viewer a la vez que `virsh start`: el dominio tarda
    //  un instante en publicar su puerto SPICE y el visor se cerraría solo. Se
    //  espera DENTRO de la misma orden a que `domdisplay` devuelva una URI, con
    //  un tope de ~10 s. Es una espera acotada y de UNA sola vez dentro de un
    //  proceso que ya existía — NO es un sondeo: no hay Timer, no hay nada
    //  repitiéndose en el shell, y cuando la orden acaba no queda nada vivo.
    property string _startedName: ""
    property bool _startedDgpu: false
    // `onDgpu`: el botón "Iniciar (pantalla en la GPU dedicada)". Abre SIEMPRE
    // la pantalla al terminar (es lo único que cambia respecto a Iniciar), así
    // que espera al display aunque openOnStart esté apagado.
    function start(name, onDgpu) {
        root._startedName = name;
        root._startedDgpu = onDgpu === true;
        var wait = (root.openOnStart || root._startedDgpu)
            ? "; for i in 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15 16 17 18 19 20; do " +
                "d=$($V domdisplay " + q(name) + " 2>/dev/null); " +
                "[ -n \"$d\" ] && break; " +
                "sleep 0.5; done"
            : "";
        root.run("start", "$V start " + q(name) + wait);
    }
    readonly property bool openOnStart: Config.get("virtualization", "openOnStart", true) === true
    function shutdown(name)   { root.run("shutdown", "$V shutdown " + q(name)); }
    function destroy_(name)   { root.run("destroy",  "$V destroy "  + q(name)); }
    function suspend(name)    { root.run("suspend",  "$V suspend "  + q(name)); }
    function resume(name)     { root.run("resume",   "$V resume "   + q(name)); }
    function reset_(name)     { root.run("reset",    "$V reset "    + q(name)); }
    function reboot_(name)    { root.run("reboot",   "$V reboot "   + q(name)); }

    // Borrar = apagar a lo bruto si sigue viva, quitar snapshots y el estado
    // guardado (si no, `undefine` se niega), y borrar el disco solo si se pide.
    // --nvram limpia el varstore de UEFI; sin él undefine falla en VMs EFI.
    function remove(name, alsoDisks) {
        root.run("delete",
            "$V destroy " + q(name) + " >/dev/null 2>&1; " +
            "$V snapshot-list " + q(name) + " --name 2>/dev/null | while read -r s; do " +
              "[ -n \"$s\" ] && $V snapshot-delete " + q(name) + " --snapshotname \"$s\" --metadata >/dev/null 2>&1; done; " +
            "$V managedsave-remove " + q(name) + " >/dev/null 2>&1; " +
            (alsoDisks
              ? "$V domblklist " + q(name) + " --details 2>/dev/null | awk '$1==\"file\" && $2==\"disk\" {print $4}' | while read -r d; do " +
                "[ -n \"$d\" ] && $V vol-delete --pool default \"$(basename \"$d\")\" >/dev/null 2>&1; done; "
              : "") +
            "$V undefine " + q(name) + " --nvram");
    }

    // ---- ajustes en caliente / persistentes --------------------------------
    //  --config: persiste en la definición. --live: aplica a la VM encendida.
    //  Con la VM apagada `--live` falla, así que se manda solo cuando procede.
    function setVcpus(name, n, live) {
        root.run("setvcpus", "$V setvcpus " + q(name) + " " + Math.max(1, n) + " --config"
                 + (live ? " && $V setvcpus " + q(name) + " " + Math.max(1, n) + " --live" : ""));
    }
    // mib -> KiB. setmaxmem solo con la VM apagada; setmem en caliente no puede
    // pasar del máximo, que es justo lo que permite el globo (memballoon).
    function setMaxMem(name, mib) {
        root.run("setmaxmem", "$V setmaxmem " + q(name) + " " + (mib * 1024) + " --config");
    }
    function setMem(name, mib, live) {
        root.run("setmem", "$V setmem " + q(name) + " " + (mib * 1024) + " --config"
                 + (live ? " && $V setmem " + q(name) + " " + (mib * 1024) + " --live" : ""));
    }
    function setAutostart(name, on) {
        root.run("autostart", "$V autostart " + (on ? "" : "--disable ") + q(name));
    }

    // ---- snapshots ---------------------------------------------------------
    function snapCreate(name, snap, desc) {
        root.run("snapshot-create", "$V snapshot-create-as --domain " + q(name)
                 + " --name " + q(snap) + (desc ? " --description " + q(desc) : ""));
    }
    function snapRevert(name, snap) {
        root.run("snapshot-revert", "$V snapshot-revert " + q(name) + " --snapshotname " + q(snap));
    }
    function snapDelete(name, snap) {
        root.run("snapshot-delete", "$V snapshot-delete " + q(name) + " --snapshotname " + q(snap));
    }

    // ======================================================================
    //  Hardware de la VM — todo verificado contra libvirt 12.2.0 en la torre.
    //  Regla general: `--config` persiste, `--live` toca la VM encendida. Se
    //  manda `--live` SOLO si la VM está encendida; con la VM apagada libvirt
    //  rechaza la orden entera, así que mandarlo siempre rompería el caso más
    //  común. `liveFlag()` centraliza esa decisión.
    // ======================================================================
    function isRunning(name) {
        for (var i = 0; i < root.vms.length; i++)
            if (root.vms[i].name === name) return root.vms[i].state === "running";
        return false;
    }
    function liveFlag(name) { return root.isRunning(name) ? " --live" : ""; }

    // ---- leer el hardware de una VM ---------------------------------------
    function loadDetail(name) {
        if (!root.enabled || !name) return;
        root.detailOf = name;
        detailer.command = ["bash", "-c", root.sh +
            "$V dumpxml --inactive " + q(name) + " 2>/dev/null | " + q(root.xmlBin) + " info; " +
            // Tamaño real de cada disco: `domblkinfo` lo sabe para cualquier
            // disco, esté o no en un pool (un `stat` no vale: los ficheros del
            // pool son de root y el directorio es 0711).
            "$V domblklist " + q(name) + " 2>/dev/null | tail -n +3 | awk 'NF {print $1}' | while read -r t; do " +
              "[ -z \"$t\" ] && continue; " +
              "i=$($V domblkinfo " + q(name) + " \"$t\" 2>/dev/null); " +
              "printf '@@DISKSZ\\t%s\\t%s\\t%s\\n' \"$t\" " +
                "\"$(printf '%s' \"$i\" | sed -n 's/^Capacity: *//p')\" " +
                "\"$(printf '%s' \"$i\" | sed -n 's/^Allocation: *//p')\"; done"];
        detailer.running = true;
    }

    // ---- discos ------------------------------------------------------------
    //  El nombre de destino libre (vdb, sdb…) se calcula EN EL PROPIO SHELL
    //  mirando la config persistente Y la viva a la vez, no desde la caché de
    //  QML: la caché puede ir un instante por detrás, y las dos vistas pueden
    //  diferir (medido). Elegir un destino ya ocupado hace fallar el attach.
    //  ⚠️ ESTE ES EL ARREGLO DE "cargo el driver de virtio-win y los discos
    //  SCSI siguen sin aparecer". `virsh attach-disk --targetbus scsi` NO
    //  declara modelo de controladora, así que lo elige libvirt — y elige
    //  **lsilogic**. Medido en esta torre, libvirt 12.2.0, dominio q35 creado
    //  por este mismo shell:
    //
    //      $ virsh attach-disk VM disco.qcow2 sdb --targetbus scsi --config
    //      Disk attached successfully
    //      $ virsh dumpxml --inactive VM | grep "type='scsi'"
    //        <controller type='scsi' index='0' model='lsilogic'/>
    //
    //  Y ahí se juntan las dos mitades del síntoma:
    //
    //    * Windows Server 2022 y Windows 11 NO traen driver del LSI 53C895A
    //      paralelo (Microsoft lo retiró), así que el disco no sale;
    //    * el `vioscsi` de virtio-win, que es el que el usuario carga a mano
    //      en "Cargar controlador", SOLO se engancha a una controladora
    //      **virtio-scsi**. Contra una lsilogic no encuentra nada que
    //      controlar y no dice por qué.
    //
    //  De ahí el "driver cargado, ningún disco": el disco estaba, el driver
    //  estaba, y no casaba la controladora. `createVm` sí declaraba
    //  virtio-scsi; esta vía no. Se igualan.
    //
    //  Solo toca las controladoras autoelegidas (sin modelo o lsilogic): una
    //  que alguien haya puesto a mano se respeta, porque cambiársela a un
    //  invitado ya instalado lo dejaría sin arrancar.
    function scsiGuard(name, bus) {
        if (bus !== "scsi") return "";
        return root.editXml(name, "scsi-virtio") + " || exit 1; ";
    }

    function targetPicker(name, prefix) {
        // ⚠️ `tr '\n' ' '` NO es cosmético: awk saca un nombre por LÍNEA, y sin
        // aplanarlo la comparación `case "$used" in *" vda "*)` no casa nunca
        // (los separadores son saltos, no espacios). Sin esto el picker elegía
        // siempre la primera letra, chocaba con el disco que ya estaba y el
        // attach fallaba en silencio. Medido.
        return "used=\" $({ $V domblklist --inactive " + q(name) + " 2>/dev/null; $V domblklist " + q(name) + " 2>/dev/null; } " +
               "| tail -n +3 | awk '{print $1}' | tr '\\n' ' ') \"; " +
               "T=''; for l in a b c d e f g h i j k l m n o p q r s t u v w x y z; do " +
                 "case \"$used\" in *\" " + prefix + "$l \"*) ;; *) T=\"" + prefix + "$l\"; break;; esac; done; " +
               "[ -z \"$T\" ] && { echo 'no quedan nombres de destino libres' >&2; exit 1; }; ";
    }

    //  Crear + enchufar en una sola acción. El volumen lo crea `vol-create-as`
    //  (libvirtd es root y deja el dueño que espera el qemu de cada distro);
    //  `qemu-img create` no sirve: /var/lib/libvirt/images es root:root 0711.
    function addDisk(name, volName, sizeGb, bus) {
        var file = "/var/lib/libvirt/images/" + volName + ".qcow2";
        var pre = bus === "virtio" ? "vd" : "sd";
        root.run("disk-add",
            root.scsiGuard(name, bus) +
            "$V pool-info default >/dev/null 2>&1 || { " +
              "$V pool-define-as default dir --target /var/lib/libvirt/images >/dev/null 2>&1; " +
              "$V pool-build default >/dev/null 2>&1; $V pool-autostart default >/dev/null 2>&1; }; " +
            "$V pool-start default >/dev/null 2>&1; " +
            "$V vol-create-as default " + q(volName + ".qcow2") + " " + Math.max(1, sizeGb) + "G --format qcow2 || exit 1; " +
            root.targetPicker(name, pre) +
            root.cfgLive(name,
                "$V attach-disk " + q(name) + " " + q(file) + " \"$T\" --driver qemu --subdriver qcow2 --targetbus " + q(bus),
                "$V attach-disk " + q(name) + " " + q(file) + " \"$T\" --driver qemu --subdriver qcow2 --targetbus " + q(bus)));
    }
    // Enchufar un disco que YA existe (un qcow2/raw suelto del usuario).
    function attachExistingDisk(name, rawPath, bus) {
        var path = root.expandPath(rawPath);
        var pre = bus === "virtio" ? "vd" : "sd";
        root.run("disk-attach",
            root.scsiGuard(name, bus) +
            root.pathGuard(path) +
            root.targetPicker(name, pre) +
            root.cfgLive(name,
                "$V attach-disk " + q(name) + " " + q(path) + " \"$T\" --driver qemu --targetbus " + q(bus),
                "$V attach-disk " + q(name) + " " + q(path) + " \"$T\" --driver qemu --targetbus " + q(bus)));
    }
    // Desenchufar SIN borrar el fichero.
    function detachDisk(name, target) {
        root.run("disk-detach",
            root.cfgLive(name,
                "$V detach-disk " + q(name) + " " + q(target),
                "$V detach-disk " + q(name) + " " + q(target)));
    }
    // Desenchufar Y borrar el volumen. Irreversible: la UI lo pide con su
    // propia confirmación, más fuerte que la de desenchufar. El fichero solo
    // se borra si el desenchufe de la CONFIG ha ido bien.
    function detachAndDeleteDisk(name, target, path) {
        root.run("disk-delete",
            root.cfgLive(name,
                "$V detach-disk " + q(name) + " " + q(target),
                "$V detach-disk " + q(name) + " " + q(target)) + "; " +
            "$V vol-delete --pool default " + q(root.baseName(path)) + " >/dev/null 2>&1 " +
            "  || $V vol-delete " + q(path) + " >/dev/null 2>&1 " +
            "  || { echo 'el disco se ha desenchufado, pero el fichero no se pudo borrar' >&2; exit 1; }");
    }
    function baseName(p) { var a = String(p).split("/"); return a[a.length - 1]; }

    // ---- CD / DVD ----------------------------------------------------------
    //  ⚠️ `--eject` necesita `--force` cuando el invitado tiene la bandeja
    //  tomada (medido: "timed out waiting to open tray of 'sda'" con Alpine
    //  arrancado desde el propio CD). Con `--force` sale a la primera.
    function ejectCd(name, target) {
        root.run("cd-eject",
            root.cfgLive(name,
                "$V change-media " + q(name) + " " + q(target) + " --eject --force",
                "$V change-media " + q(name) + " " + q(target) + " --eject --force"));
    }
    function insertCd(name, target, rawIso) {
        var iso = root.expandPath(rawIso);
        root.run("cd-insert",
            root.pathGuard(iso) +
            root.cfgLive(name,
                "$V change-media " + q(name) + " " + q(target) + " --source " + q(iso) + " --insert",
                "$V change-media " + q(name) + " " + q(target) + " --source " + q(iso) + " --insert"));
    }
    // Añadir una unidad óptica a una VM que no tenga ninguna.
    function addCdrom(name, rawIso) {
        var iso = root.expandPath(rawIso);
        var src = iso === "" ? "\"\"" : q(iso);
        root.run("cd-add",
            (iso === "" ? "" : root.pathGuard(iso)) +
            root.targetPicker(name, "sd") +
            root.cfgLive(name,
                "$V attach-disk " + q(name) + " " + src + " \"$T\" --type cdrom --mode readonly --targetbus sata",
                "$V attach-disk " + q(name) + " " + src + " \"$T\" --type cdrom --mode readonly --targetbus sata"));
    }

    // ---- interfaces de red -------------------------------------------------
    //  ⚠️ La MAC se genera AQUÍ y se pasa a las dos llamadas. Sin `--mac`,
    //  `attach-interface` inventa una MAC DISTINTA en cada invocación, así que
    //  la config y el dominio vivo acababan con adaptadores de MAC diferente
    //  (medido: live 52:54:00:fa:70:91 vs config 52:54:00:53:35:77) y luego
    //  quitar el adaptador fallaba con "No interface with MAC address … found".
    //  Prefijo 52:54:00 = el rango que usa QEMU/libvirt.
    //  ⚠️ La red se ARRANCA antes de enganchar nada. Una red definida pero
    //  parada sigue saliendo en `net-list --all` y por tanto en la lista de
    //  esta ventana, pero `attach-interface` contra ella falla con "Network
    //  not active" — que es exactamente el aspecto de "está en la lista y no
    //  me deja volver a ponerla". `createVm` ya lo hacía; esta vía no.
    function addNic(name, netName, model) {
        var mkMac = "MAC=$(printf '52:54:00:%02x:%02x:%02x' " +
                    "$((RANDOM%256)) $((RANDOM%256)) $((RANDOM%256))); ";
        var wake = "$V net-info " + q(netName) + " >/dev/null 2>&1 && " +
                   "$V net-start " + q(netName) + " >/dev/null 2>&1; ";
        var cmd = "$V attach-interface " + q(name) + " network " + q(netName) +
                  " --model " + q(model) + " --mac \"$MAC\"";
        root.run("nic-add", wake + mkMac + root.cfgLive(name, cmd, cmd));
    }
    //  Quitar una interfaz.
    //  ⚠️ ANTES esto pasaba `network` como TIPO, fijo, a `detach-interface`.
    //  `detach-interface <dom> <tipo> --mac <mac>` solo mira las interfaces de
    //  ESE tipo, así que sobre un adaptador en PUENTE contestaba, literalmente:
    //
    //      error: No interface with MAC address 52:54:00:… was found
    //      error: Failed to detach interface
    //
    //  ...con el adaptador ahí listado. Reproducido en la torre y confirmado:
    //  con `bridge` en vez de `network` la misma orden lo quita a la primera.
    //  La MAC nunca estuvo caducada; lo que estaba mal era el tipo.
    //
    //  Se arregla quitando la adivinanza de en medio: `detach-device` recibe el
    //  <interface> EXACTO, sacado del propio dominio en el instante de quitarlo
    //  (`dumpxml` | iface-get <mac>). Así vale para cualquier tipo —network,
    //  bridge, direct, lo que venga— sin tener que enumerarlos, y de paso la
    //  MAC se re-resuelve contra el XML de verdad en vez de fiarse de la caché
    //  de la ventana.
    //
    //  Config y vivo se resuelven POR SEPARADO a propósito: el XML persistente
    //  y el vivo no son el mismo (el vivo trae direcciones PCI asignadas en esta
    //  ejecución), así que cada mitad recorta su propio fragmento.
    function removeNic(name, mac) {
        var X = q(root.xmlBin);
        var cfg = "$V dumpxml --inactive " + q(name) + " | " + X + " iface-get " + q(mac) + " > \"$D/cfg.xml\"";
        var live = "$V dumpxml " + q(name) + " | " + X + " iface-get " + q(mac) + " > \"$D/live.xml\"";
        root.run("nic-del",
            "D=$(mktemp -d) || exit 1; trap 'rm -rf \"$D\"' EXIT; " +
            "RUN=0; [ \"$($V domstate " + q(name) + " 2>/dev/null)\" = running ] && RUN=1; " +
            cfg + " || exit 1; " +
            "$V detach-device " + q(name) + " \"$D/cfg.xml\" --config || exit 1; " +
            "[ \"$RUN\" = 1 ] && { " + live + " && " +
              "$V detach-device " + q(name) + " \"$D/live.xml\" --live 2>/dev/null " +
              "|| printf '@@LIVEFAIL' >&2; }; :");
    }

    // ---- USB del anfitrión --------------------------------------------------
    //  Se listan leyendo /sys directamente: `lsusb` vive en usbutils, que NO
    //  está instalado aquí y NO se va a añadir como dependencia. Los
    //  concentradores (clase 09) se filtran: pasar un hub no tiene sentido.
    function loadHostUsb() {
        if (!root.enabled) return;
        usbLister.running = true;
    }
    // `attach-device` pide un FICHERO, no acepta el XML en la línea de órdenes:
    // se escribe en un temporal que se borra siempre.
    function usbXml(vendor, product) {
        return "<hostdev mode='subsystem' type='usb' managed='yes'>" +
               "<source><vendor id='" + vendor + "'/><product id='" + product + "'/></source>" +
               "</hostdev>";
    }
    function usbDeviceOp(name, vendor, product, verb, action) {
        root.run(action,
            "t=$(mktemp) || exit 1; printf '%s' " + q(root.usbXml(vendor, product)) + " > \"$t\"; " +
            root.cfgLive(name, "$V " + verb + " " + q(name) + " \"$t\"", "$V " + verb + " " + q(name) + " \"$t\"") +
            "; rc=$?; rm -f \"$t\"; exit $rc");
    }
    function attachUsb(name, vendor, product) { root.usbDeviceOp(name, vendor, product, "attach-device", "usb-attach"); }
    function detachUsb(name, vendor, product) { root.usbDeviceOp(name, vendor, product, "detach-device", "usb-detach"); }

    // Etiqueta legible de un USB ya pasado a la VM: se busca en el inventario
    // del anfitrión; si el aparato ya no está enchufado, se enseñan los ids.
    function usbLabel(vendor, product) {
        for (var i = 0; i < root.hostUsb.length; i++)
            if (root.hostUsb[i].vendor === vendor && root.hostUsb[i].product === product)
                return root.hostUsb[i].label;
        return vendor + ":" + product;
    }
    function usbAttached(vendor, product) {
        for (var i = 0; i < root.detail.usbdevs.length; i++)
            if (root.detail.usbdevs[i].vendor === vendor && root.detail.usbdevs[i].product === product)
                return true;
        return false;
    }

    // ---- puentes de red del anfitrión --------------------------------------
    function loadBridges() {
        if (!root.enabled) return;
        bridgeLister.running = true;
    }
    //  Cambiar la red de un adaptador EXISTENTE sin cambiar el adaptador.
    //  ⚠️ Lo que NO hay que hacer (y era lo único que dejaba la ventana):
    //  quitarlo y añadir otro. Eso es OTRA tarjeta — MAC nueva (attach-interface
    //  inventa una), otra ranura PCI, y en el invitado un "eth1"/"Ethernet 2"
    //  nuevo con la configuración vacía.
    //  Aquí cambia SOLO el enganche (`type` + `<source>`), por las dos vías:
    //   * persistente: dumpxml --inactive | nic-network/nic-bridge | define;
    //   * en caliente, si está encendida: `update-device --live` con su propio
    //     <interface> vivo reapuntado (iface-retarget). libvirt mueve el tap de
    //     puente sin desenchufar la tarjeta: misma MAC, mismo modelo, misma
    //     dirección PCI, mismo vnetN.
    //  Y se COMPRUEBA en /sys que el vnetN quedó colgando del puente nuevo.
    //  `kind`: "network" (red de libvirt) o "bridge" (puente del anfitrión).
    function setNicSource(name, mac, kind, target) {
        var X = q(root.xmlBin);
        var net = kind !== "bridge";
        var k = net ? "network" : "bridge";
        root.run("nic-source",
            "D=$(mktemp -d) || exit 1; trap 'rm -rf \"$D\"' EXIT; " +
            //  Una red definida pero parada: el update-device en caliente
            //  fallaría con "network is not active". Se arranca antes, como en
            //  addNic().
            (net ? "$V net-info " + q(target) + " >/dev/null 2>&1 && $V net-start " + q(target) + " >/dev/null 2>&1; " : "") +
            "S=$($V domstate " + q(name) + " 2>/dev/null); " +
            root.editXml(name, "nic-" + k + " " + q(mac) + " " + q(target)) + " || exit 1; " +
            "case \"$S\" in running|paused) ;; *) exit 0;; esac; " +
            "$V dumpxml " + q(name) + " | " + X + " iface-retarget " + q(mac) + " " + k + " " + q(target) + " > \"$D/l.xml\" && " +
            "$V update-device " + q(name) + " \"$D/l.xml\" --live >/dev/null 2>&1 || { printf '@@LIVEFAIL' >&2; exit 0; }; " +
            "tap=$($V domiflist " + q(name) + " 2>/dev/null | awk -v m=" + q(String(mac).toLowerCase()) + " 'NR>2 && tolower($5)==m {print $1}'); " +
            "BR=" + (net ? "$($V net-info " + q(target) + " 2>/dev/null | sed -n 's/^Bridge: *//p')" : q(target)) + "; " +
            "M=$(basename \"$(readlink \"/sys/class/net/$tap/master\" 2>/dev/null)\"); " +
            "[ -n \"$BR\" ] && [ \"$M\" = \"$BR\" ] || " +
              "printf '@@WARN %s\\t%s\\n' 'Saved, but the running adapter is not on the expected bridge:' \"$tap -> ${M:-none} ($BR)\" >&2; :");
    }
    function addBridgeNic(name, br, model) {
        var mkMac = "MAC=$(printf '52:54:00:%02x:%02x:%02x' $((RANDOM%256)) $((RANDOM%256)) $((RANDOM%256))); ";
        var cmd = "$V attach-interface " + q(name) + " bridge " + q(br) +
                  " --model " + q(model) + " --mac \"$MAC\"";
        root.run("nic-add", mkMac + root.cfgLive(name, cmd, cmd));
    }

    // ---- sonido -------------------------------------------------------------
    function setSound(name, model) { root.run("sound", root.editXml(name, "sound " + q(model))); }

    // ---- OVA ----------------------------------------------------------------
    //  ⚠️ `qemu-img` NO puede leer los discos del pool directamente: son
    //  root:root 0600 y /var/lib/libvirt/images es 0711 (medido: "Could not
    //  open …: Permission denied"). El disco se saca y se mete por libvirt, que
    //  sí es root, con `vol-download` / `vol-upload`. Cuesta una copia temporal
    //  pero es la única vía limpia sin pedir privilegios.
    //  PROGRESO (3 fases): la 1 la mide el propio shell haciendo pasar el
    //  vol-download por el medidor; las 2 y 3 las cuenta el ayudante.
    //   ⚠️ `set -o pipefail` es OBLIGATORIO aquí y no está en el preludio
    //   común: sin él el estado de la tubería es el del MEDIDOR, que termina
    //   feliz aunque libvirt haya reventado a mitad, y el .ova saldría
    //   truncado dándose por bueno. Se pone solo en las órdenes de OVA para no
    //   cambiar por debajo el comportamiento de las demás.
    //   ⚠️ Qué forma de vol-download vale se decide ANTES (con vol-info) en
    //   vez de encadenar `a || b`: dentro de una tubería, la primera forma ya
    //   habría escrito bytes al medidor antes de fallar.
    property string _ovaOut: ""
    function exportOva(name, rawPath) {
        var out = root.expandPath(rawPath);
        var src = "";
        for (var i = 0; i < root.detail.disks.length; i++)
            if (root.detail.disks[i].device === "disk") { src = root.detail.disks[i].path; break; }
        if (src === "") { root.lastError = I18n.t("This VM has no hard disk to export."); return; }
        root._ovaOut = out;
        root.run("ova-export",
            "set -o pipefail; " +
            "mkdir -p \"$(dirname " + q(out) + ")\" || exit 1; " +
            "T=$(mktemp -d) || exit 1; trap 'rm -rf \"$T\"' EXIT; " +
            "printf '@@PHASE\\t1\\t3\\tdownload\\n'; " +
            "if $V vol-info --pool default " + q(root.baseName(src)) + " >/dev/null 2>&1; " +
              "then set -- --pool default " + q(root.baseName(src)) + "; else set -- " + q(src) + "; fi; " +
            "TOT=$($V vol-info \"$@\" --bytes 2>/dev/null | sed -n 's/^Allocation: *\\([0-9]*\\).*/\\1/p'); " +
            "[ -z \"$TOT\" ] && TOT=0; " +
            "$V vol-download \"$@\" /dev/stdout | " +
              q(root.ovaBin) + " meter \"$TOT\" - \"$T/disk.qcow2\" || exit 1; " +
            "$V dumpxml --inactive " + q(name) + " > \"$T/dom.xml\" || exit 1; " +
            "VEXYON_PHASE_BASE=1 VEXYON_PHASE_TOTAL=3 " +
              q(root.ovaBin) + " export \"$T/dom.xml\" \"$T/disk.qcow2\" " + q(out) + " \"$T/build\"");
    }

    // Importar va en DOS fases porque hace falta leer lo que dice el OVF antes
    // de poder escribir el XML del dominio:
    //   1) el ayudante extrae, convierte a qcow2 y IMPRIME nombre/RAM/vCPU/disco;
    //   2) con esos datos ya en QML se sube el disco al pool y se define la VM
    //      con el MISMO generador de XML que usa "crear VM".
    property string _ovaName: ""
    function importOva(rawPath, newName, busWanted) {
        if (!root.enabled) return;
        var ova = root.expandPath(rawPath);
        root._ovaName = newName;
        root._ovaBusWanted = busWanted || "auto";
        root.lastError = "";
        root.lastNote = "";
        root.lastSuccess = "";
        root._clearProgress();
        root._ovaFacts = { mem: 1024, cpu: 2, disk: "", tmp: "", bus: "", firmware: "" };
        root.lastAction = "ova-import";
        root.busy = true;
        ovaImporter.command = ["bash", "-c", root.sh +
            root.pathGuard(ova) +
            "T=$(mktemp -d) || exit 1; " +
            "VEXYON_PHASE_BASE=0 VEXYON_PHASE_TOTAL=4 " +
              q(root.ovaBin) + " import " + q(ova) + " " + q(newName) + " \"$T\" || { rm -rf \"$T\"; exit 1; }; " +
            "echo \"@@TMP\t$T\""];
        ovaImporter.running = true;
    }

    // Segunda fase: subir el disco convertido al pool y definir el dominio.
    //  Fases 3 y 4 de 4. La subida pasa por una TUBERÍA CON NOMBRE: `virsh
    //  vol-upload` acepta leer de ella (comprobado en la torre: sube hasta EOF,
    //  no mira el tamaño del fichero), así que el medidor puede contar los
    //  bytes por el camino. Es la única forma de tener progreso real aquí,
    //  porque vol-upload no sabe informar de nada.
    property string _ovaBus: ""
    property string _ovaFirmware: ""
    function _finishOvaImport(mem, vcpus, disk, tmpDir) {
        // run() limpia lastNote, y ahí están los avisos de fidelidad que dejó
        // la fase 1 (lo que el OVA no traslada). Se guardan y se reponen: son
        // justo lo que el usuario tiene que seguir viendo al terminar.
        var keepNote = root.lastNote;
        root.run("ova-define",
            "set -o pipefail; " +
            "printf '@@PHASE\\t3\\t4\\tupload\\n'; " +
            "$V pool-info default >/dev/null 2>&1 || { " +
              "$V pool-define-as default dir --target /var/lib/libvirt/images >/dev/null 2>&1; " +
              "$V pool-build default >/dev/null 2>&1; $V pool-autostart default >/dev/null 2>&1; }; " +
            "$V pool-start default >/dev/null 2>&1; " +
            "CAP=$(qemu-img info " + q(disk) + " | sed -n 's/^virtual size:.*(\\([0-9]*\\) bytes).*/\\1/p' | head -1); " +
            "[ -z \"$CAP\" ] && CAP=" + q("2147483648") + "; " +
            "$V vol-create-as default " + q(root._ovaName + ".qcow2") + " \"$CAP\" --format qcow2 || { rm -rf " + q(tmpDir) + "; exit 1; }; " +
            "SZ=$(stat -c %s " + q(disk) + " 2>/dev/null || echo 0); " +
            "P=" + q(tmpDir) + "/up.fifo; mkfifo \"$P\" || { rm -rf " + q(tmpDir) + "; exit 1; }; " +
            "$V vol-upload --pool default " + q(root._ovaName + ".qcow2") + " \"$P\" & UP=$!; " +
            q(root.ovaBin) + " meter \"$SZ\" " + q(disk) + " \"$P\" || { kill $UP 2>/dev/null; wait $UP 2>/dev/null; rm -rf " + q(tmpDir) + "; exit 1; }; " +
            "wait $UP || { rm -rf " + q(tmpDir) + "; exit 1; }; " +
            "printf '@@PHASE\\t4\\t4\\tdefine\\n'; " +
            "rm -rf " + q(tmpDir) + "; " +
            "t=$(mktemp) || exit 1; cat > \"$t\" <<'VEXYONXML'\n" +
            //  Antes esto era `firmware: "bios"` a pelo y el disco en virtio,
            //  las dos cosas inventadas. Ahora las dos vienen de fuera: la
            //  controladora de lo que declare el .ovf y el firmware de la tabla
            //  de particiones del propio disco (GPT -> UEFI, MBR -> BIOS), que
            //  es lo que de verdad decide si arranca.
            //  ⚠️ El MODELO DE RED también hay que heredarlo del origen, no
            //  solo la controladora del disco. Si el .ovf NO declaraba virtio,
            //  el invitado viene de VirtualBox/VMware y NO tiene driver de
            //  virtio-net dentro: dejarle virtio-net lo deja sin red igual que
            //  a un Windows recién instalado. `osType: "windows"` aquí no
            //  afirma que sea Windows — solo dice "sin drivers de virtio", que
            //  es lo que se sabe de verdad, y e1000e lo entienden los dos.
            root.domainXml({ name: root._ovaName, memMib: mem, vcpus: vcpus,
                             iso: "", firmware: (root._ovaFirmware || "bios"),
                             bus: (root._ovaBus || "sata"), network: "default",
                             osType: (root._ovaBus === "virtio" ? "linux" : "windows") },
                           "/var/lib/libvirt/images/" + root._ovaName + ".qcow2") + "\nVEXYONXML\n" +
            "$V define \"$t\"; rc=$?; rm -f \"$t\"; exit $rc");
        root.lastNote = keepNote;
        // La barra no debe parpadear entre la fase 2 y la 3: el script lo dirá
        // igual en cuanto arranque, pero eso son unos milisegundos en blanco.
        root.progStep = 3; root.progSteps = 4; root.progPhase = "upload";
    }

    // ---- ajustes por XML (todos config-only: piden reinicio) ----------------
    function setBootOrder(name, list) { root.run("boot", root.editXml(name, "boot " + q(list.join(",")))); }
    function setVideo(name, model, vram) { root.run("video", root.editXml(name, "video " + q(model) + " " + q("" + vram) + " 1")); }
    function setCpuTopology(name, sockets, cores, threads) {
        root.run("cpu-topology", root.editXml(name, "cpu " + sockets + " " + cores + " " + threads));
    }
    function setFirmware(name, fw) { root.run("firmware", root.editXml(name, "firmware " + q(fw))); }
    //  TPM 2.0 emulado (swtpm). Es lo que le faltaba a TODA VM creada por el
    //  asistente y la razón exacta de "El equipo debe admitir TPM 2.0".
    function setTpm(name, on) { root.run("tpm", root.editXml(name, "tpm " + (on ? "on" : "off"))); }
    //  Modelo de UNA tarjeta de red. Windows no trae driver de virtio-net.
    function setNicModel(name, mac, model) {
        root.run("nic-model", root.editXml(name, "nic-model " + q(mac) + " " + q(model)));
    }
    function setSpiceAgent(name, on) { root.run("spice-agent", root.editXml(name, "spice-agent " + (on ? "on" : "off"))); }
    function setClipboard(name, on) { root.run("clipboard", root.editXml(name, "clipboard " + (on ? "on" : "off"))); }
    function setUsbRedir(name, n) { root.run("usbredir", root.editXml(name, "usbredir " + n)); }
    function setDescription(name, text) { root.run("desc", root.editXml(name, "desc " + q(text))); }
    function addSharedFolder(name, rawPath, tag) {
        var path = root.expandPath(rawPath);
        root.run("fs-add", root.pathGuard(path) + root.editXml(name, "fs-add " + q(path) + " " + q(tag)));
    }
    function removeSharedFolder(name, tag) { root.run("fs-del", root.editXml(name, "fs-del " + q(tag))); }
    function addController(name, ctype, model) { root.run("controller-add", root.editXml(name, "controller-add " + q(ctype) + " " + q(model))); }

    // Renombrar: libvirt no tiene `rename` para dominios persistentes, así que
    // es undefine + define con el nombre nuevo. El disco NO se toca.
    function renameVm(oldName, newName) {
        root.run("rename",
            "$V dumpxml --inactive " + q(oldName) + " | " + q(root.xmlBin) + " rename " + q(newName) +
            " | $V define /dev/stdin >/dev/null || exit 1; " +
            "$V undefine " + q(oldName) + " --nvram");
    }

    // Clonar. `vol-clone` PRIMERO y solo si va bien se define el dominio: al
    // revés quedaría una VM apuntando a un disco inexistente.
    //  ⚠️ La VM origen tiene que estar APAGADA: con ella encendida qemu tiene
    //  el qcow2 con un write lock y `vol-clone` falla ("Failed to get shared
    //  write lock"). La UI solo ofrece clonar con la VM apagada.
    function cloneVm(name, newName) {
        var src = "", dst = "/var/lib/libvirt/images/" + newName + ".qcow2";
        for (var i = 0; i < root.detail.disks.length; i++)
            if (root.detail.disks[i].device === "disk") { src = root.detail.disks[i].path; break; }
        root.run("clone",
            "$V vol-clone --pool default " + q(root.baseName(src)) + " " + q(newName + ".qcow2") + " || exit 1; " +
            "$V dumpxml --inactive " + q(name) + " | " + q(root.xmlBin) + " clone " + q(newName) +
            " " + q(src + "=" + dst) + " | $V define /dev/stdin >/dev/null");
    }

    // Exportar / importar: el XML del dominio tal cual, que es el formato
    // nativo de libvirt. Nada de OVA/OVF — eso pediría herramientas de fuera.
    function exportVm(name, rawPath) {
        var path = root.expandPath(rawPath);
        root.run("export",
            "mkdir -p \"$(dirname " + q(path) + ")\" || exit 1; " +
            "$V dumpxml --inactive " + q(name) + " > " + q(path));
    }
    function importVm(rawPath) {
        var path = root.expandPath(rawPath);
        root.run("import", root.pathGuard(path) + "$V define " + q(path));
    }

    // ---- redes -------------------------------------------------------------
    //  Arrancar una red parada. Si se paró con VMs encendidas dentro, sus
    //  adaptadores se reenganchan al puente nuevo (ver _netReconnect).
    function netStart(n)     { root.run("net-start",     "$V net-start " + q(n) + " || exit 1; " + root._netReconnect(n)); }
    //  Parar. Las VMs encendidas que la usan se quedan sin red hasta que se
    //  vuelva a arrancar (la ventana lo avisa y dice cuáles ANTES de pedirlo).
    function netStop(n)      { root.run("net-stop",      "$V net-destroy " + q(n)); }
    //  VMs encendidas con algún adaptador en la red `net` (sin repetir), de la
    //  caché del último refresco: es lo que el diálogo enseña antes de parar o
    //  borrar.
    function vmsOnNet(net) {
        var out = [];
        for (var i = 0; i < root.liveNics.length; i++) {
            var n = root.liveNics[i];
            if (n.type === "network" && n.source === net && out.indexOf(n.vm) === -1) out.push(n.vm);
        }
        return out;
    }
    //  Borrar de verdad: parar si está en marcha y quitar la definición.
    //   * Se para SOLO si está activa, y si no se puede parar NO se sigue: con
    //     el `destroy || :` de antes, un fallo dejaba la red viva, transitoria
    //     y con su puente, pero ya sin definición.
    //   * Una red transitoria desaparece entera al pararla: entonces no queda
    //     nada a lo que hacer `undefine`.
    //   * Se COMPRUEBA que el puente ha desaparecido del anfitrión.
    //   * Las VMs encendidas que la usaban conservan el adaptador (misma MAC),
    //     pero ya no cuelga de nada. Se avisó al confirmar; aquí se dice cuáles
    //     quedaron así, no se calla. Si se vuelve a crear una red con el mismo
    //     nombre, createNetwork() las reengancha.
    //
    //  ⚠️ `default` NO SE BORRA DESDE AQUÍ. Es la única red que sale a internet
    //  sin que el usuario configure nada: la crea libvirt al instalarse, es la
    //  que usan todas las VMs nuevas, y las redes propias del shell (host-only,
    //  interna, e incluso una NAT nueva) NO son un recambio — quedan aisladas
    //  o piden encaminamiento a mano. Perderla se nota en TODAS las VMs a la
    //  vez y no hay forma de deshacerlo desde la ventana.
    //
    //  Esto NO es lo que se llevó por delante la red del informe: quitar un
    //  adaptador de una VM pasa por removeNic(), que hace `detach-device` con
    //  el <interface> exacto y no toca ninguna definición de red (comprobado:
    //  `net-list --all` sigue listando `default` activa después). Este botón
    //  era la ÚNICA vía que podía hacerlo, y ahora tampoco puede.
    readonly property string protectedNet: "default"
    function netDelete(n) {
        if (n === root.protectedNet) {
            root.lastError = I18n.t("`default` is libvirt's built-in NAT network — the only one that reaches the internet without extra setup, and the one every new VM uses. It cannot be deleted from here. Stop it instead if you want it out of the way.");
            return;
        }
        root.run("net-delete",
            "I=$($V net-info " + q(n) + ") || exit 1; " +
            "BR=$(printf '%s\\n' \"$I\" | sed -n 's/^Bridge: *//p'); " +
            "printf '%s\\n' \"$I\" | grep -q '^Active: *yes' && { $V net-destroy " + q(n) + " >/dev/null || exit 1; }; " +
            "$V net-info " + q(n) + " >/dev/null 2>&1 && { $V net-undefine " + q(n) + " >/dev/null || exit 1; }; " +
            "[ -n \"$BR\" ] && [ -e \"/sys/class/net/$BR\" ] && " +
              "printf '@@WARN %s\\t%s\\n' 'The network was deleted, but its bridge is still on the host:' \"$BR\" >&2; " +
            "U=$($V list --name 2>/dev/null | while read -r d; do [ -n \"$d\" ] && " +
              "$V domiflist \"$d\" 2>/dev/null | awk -v d=\"$d\" -v n=" + q(n) + " " +
              "'NR>2 && $2==\"network\" && $3==n {printf \"%s (%s) \", d, $5}'; done); " +
            "[ -n \"$U\" ] && printf '@@WARN %s\\t%s\\n' 'These running VMs kept their adapter, but it is connected to nothing until you change its network or create this one again:' \"$U\" >&2; :");
    }

    //  Rehacer `default` si alguna vez falta (borrada desde fuera del shell,
    //  con `virsh net-undefine` o con virt-manager). libvirt reparte su
    //  plantilla en $datadir/libvirt/networks/default.xml; si está, se usa esa
    //  TAL CUAL, que es exactamente la definición original —misma subred
    //  192.168.122.0/24, mismo rango de DHCP— en vez de reconstruirla a mano.
    //  Solo si no aparece se escribe el equivalente, que es esa misma.
    //  La UUID NO se copia: libvirt genera una nueva y así no choca con
    //  ningún resto.
    function netRestoreDefault() {
        root.run("net-restore",
            //  Si ya está, esto es un no-op que además la deja arrancada y en
            //  autoarranque. NADA por stderr: el colector de `run` convierte
            //  cualquier stderr en el cartel rojo de error, aunque salga con 0.
            //  Las VMs encendidas que ya la nombraban se reenganchan (ver
            //  _netReconnect): si la red estaba parada o se rehace aquí, su
            //  puente es nuevo y nace sin ellas.
            "$V net-info default >/dev/null 2>&1 && { " +
              "$V net-start default >/dev/null 2>&1; $V net-autostart default >/dev/null 2>&1; " +
              root._netReconnect("default") + "exit 0; }; " +
            "t=$(mktemp) || exit 1; trap 'rm -f \"$t\"' EXIT; " +
            "for d in /usr/share/libvirt/networks/default.xml " +
                     "/run/current-system/sw/share/libvirt/networks/default.xml " +
                     "/nix/var/nix/profiles/default/share/libvirt/networks/default.xml; do " +
              "[ -r \"$d\" ] && { sed '/<uuid>/d' \"$d\" > \"$t\"; break; }; done; " +
            //  El XML va por un heredoc, igual que en createNetwork(): las
            //  líneas se juntan con \n ESCAPADO, no con saltos reales dentro
            //  de la cadena de QML.
            "[ -s \"$t\" ] || cat > \"$t\" <<'VEXYONNET'\n" +
            "<network>\n" +
            "  <name>default</name>\n" +
            "  <forward mode='nat'/>\n" +
            "  <bridge name='virbr0' stp='on' delay='0'/>\n" +
            "  <ip address='192.168.122.1' netmask='255.255.255.0'>\n" +
            "    <dhcp><range start='192.168.122.2' end='192.168.122.254'/></dhcp>\n" +
            "  </ip>\n" +
            "</network>\n" +
            "VEXYONNET\n" +
            "$V net-define \"$t\" || exit 1; " +
            "$V net-start default || exit 1; " +
            "$V net-autostart default >/dev/null; " +
            root._netReconnect("default"));
    }

    // ---- redes virtuales nuevas ---------------------------------------------
    //  Tres modos, que es lo que de verdad se usa, con los nombres que entiende
    //  cualquiera que venga de VirtualBox:
    //
    //   nat       <forward mode='nat'/> + IP en el anfitrión.  Las VMs salen a
    //             internet a través del anfitrión, que es su puerta de enlace.
    //             Es lo que hace `default`.
    //   hostonly  SIN <forward>, pero CON IP en el anfitrión.  Las VMs se ven
    //             entre ellas y ven al anfitrión; a la calle no salen. libvirt
    //             lo llama "isolated".
    //   internal  SIN <forward> y SIN IP.  libvirt crea el puente y no le pone
    //             dirección a nadie: las VMs se ven entre ellas y NADIE más,
    //             ni siquiera el anfitrión. Sin IP no hay DHCP posible, y no se
    //             genera NINGÚN <ip>.
    //
    //  LA RED Y LA DIRECCIÓN DEL ANFITRIÓN SON DOS COSAS. La red es la subred
    //  (192.168.100.0/24); la del anfitrión es UNA dirección dentro de ella, la
    //  que libvirt le pone al puente. Antes la segunda salía a la fuerza de la
    //  primera (siempre la .1), y en host-only eso le quitaba la .1 justo a lo
    //  que más la quiere: la VM router (pfSense, OPNsense…) que hace de puerta
    //  de enlace del laboratorio — dos máquinas con la misma IP en el mismo
    //  puente. Ahora la del anfitrión se puede escribir, y VACÍA es automática:
    //   * NAT: la .1. Ahí el anfitrión ES la puerta de enlace, como en `default`.
    //   * host-only: la ÚLTIMA útil (.254 en una /24), que deja la .1 libre.
    //  El DHCP (el dnsmasq de libvirt) reparte de la .2 a la última útil SIN la
    //  del anfitrión — partido en dos rangos si cae en medio. La .1 no se
    //  reparte nunca. Se puede apagar para direccionar a mano en los invitados.
    function _ip2n(ip) {
        var p = String(ip).split(".");
        return (((+p[0]) << 24) | ((+p[1]) << 16) | ((+p[2]) << 8) | (+p[3])) >>> 0;
    }
    function _n2ip(n) {
        return [(n >>> 24) & 255, (n >>> 16) & 255, (n >>> 8) & 255, n & 255].join(".");
    }
    //  "a.b.c.d" -> número, o -1 si no es una IPv4 válida.
    function _ipNum(s) {
        var m = /^(\d{1,3})\.(\d{1,3})\.(\d{1,3})\.(\d{1,3})$/.exec(String(s).trim());
        if (!m) return -1;
        for (var i = 1; i <= 4; i++) if (+m[i] > 255) return -1;
        return root._ip2n(m[1] + "." + m[2] + "." + m[3] + "." + m[4]);
    }
    //  255.255.255.0 -> 24.
    function maskBits(m) {
        var n = root._ipNum(m), b = 0;
        if (n < 0) return "";
        while (n & 0x80000000) { b++; n = (n << 1) >>> 0; }
        return String(b);
    }

    //  El plan de direcciones de una red NUEVA, sin tocar nada. Lo usan la
    //  vista previa del diálogo (que lo enseña ANTES de crear) y
    //  createNetwork() (que lo convierte en XML): lo que se ve es lo que se crea.
    //   { error, cidr, netmask, host, ranges: [{ start, end }], dhcp, warnings }
    //  `error` no vacío = no se puede crear; `warnings` avisan pero no bloquean.
    function netPlan(mode, subnet, hostIp, dhcp) {
        var p = { error: "", cidr: "", netmask: "", host: "", ranges: [], dhcp: false, warnings: [] };
        if (mode === "internal") return p;
        var m = /^(\d{1,3}(?:\.\d{1,3}){3})\/(\d{1,2})$/.exec(String(subnet).trim());
        var addr = m ? root._ipNum(m[1]) : -1;
        var bits = m ? parseInt(m[2], 10) : 0;
        //  /8../30: por encima no hay sitio ni para el anfitrión y la difusión,
        //  por debajo es absurdo.
        if (addr < 0 || bits < 8 || bits > 30) {
            p.error = I18n.t("That subnet is not valid. Write it as an address and a prefix, for example 192.168.100.0/24.");
            return p;
        }
        var mask = ((0xFFFFFFFF << (32 - bits)) >>> 0);
        var net = (addr & mask) >>> 0;
        var bcast = (net + Math.pow(2, 32 - bits) - 1) >>> 0;
        p.cidr = root._n2ip(net) + "/" + bits;
        p.netmask = root._n2ip(mask);
        var h;
        if (String(hostIp || "").trim() === "") {
            h = mode === "nat" ? net + 1 : bcast - 1;
        } else {
            h = root._ipNum(hostIp);
            if (h < 0) { p.error = I18n.t("The host address is not a valid IPv4 address."); return p; }
            if (((h & mask) >>> 0) !== net) { p.error = I18n.t("The host address is not inside that network."); return p; }
            if (h === net || h === bcast) { p.error = I18n.t("The host address cannot be the network or the broadcast address."); return p; }
        }
        p.host = root._n2ip(h);
        //  Que se pise con otra red de libvirt. Si esa está ARRANCADA, libvirt
        //  se negaría a arrancar esta ("Network is already in use by interface
        //  virbrN"): no se deja ni intentarlo. Si está parada, se avisa: solo
        //  podrá funcionar una de las dos a la vez. Se pisan si, con la máscara
        //  más corta de las dos, caen en la misma subred.
        for (var i = 0; i < root.networks.length; i++) {
            var o = root.networks[i];
            var oi = root._ipNum(o.ip), om = root._ipNum(o.netmask);
            if (oi < 0 || om < 0) continue;
            var both = (mask & om) >>> 0;
            if (((net & both) >>> 0) !== ((oi & both) >>> 0)) continue;
            var what = o.name + " (" + o.ip + "/" + root.maskBits(o.netmask) + ")";
            if (o.state === "active") {
                p.error = I18n.t("That network overlaps a running libvirt network:") + " " + what;
                return p;
            }
            p.warnings.push(I18n.t("That network overlaps a stopped libvirt network, so only one of them can run at a time:") + " " + what);
        }
        if (mode === "hostonly" && h === net + 1)
            p.warnings.push(I18n.t("The host takes the .1 address. A router or gateway VM on this network usually wants .1 for itself — leave the host address empty to use the last address instead."));
        if (dhcp) {
            var a = net + 2, b = bcast - 1;
            if (h >= a && h <= b) {
                if (h > a) p.ranges.push({ start: root._n2ip(a), end: root._n2ip(h - 1) });
                if (h < b) p.ranges.push({ start: root._n2ip(h + 1), end: root._n2ip(b) });
            } else if (a <= b) {
                p.ranges.push({ start: root._n2ip(a), end: root._n2ip(b) });
            }
            p.dhcp = p.ranges.length > 0;
            if (!p.dhcp) p.warnings.push(I18n.t("This network is too small to hand out addresses, so DHCP stays off."));
        }
        return p;
    }

    function createNetwork(o) {
        if (!root.enabled) return;
        if (!root.validName(o.name)) { root.lastError = I18n.t("That name is not valid. Use letters, digits, dots, dashes or underscores."); return; }
        for (var i = 0; i < root.networks.length; i++)
            if (root.networks[i].name === o.name) { root.lastError = I18n.t("There is already a network with that name."); return; }
        var p = root.netPlan(o.mode, o.subnet, o.hostIp, o.dhcp);
        if (p.error !== "") { root.lastError = p.error; return; }
        var x = [];
        x.push("<network>");
        x.push("  <name>" + root.xmlEsc(o.name) + "</name>");
        if (o.mode === "nat") x.push("  <forward mode='nat'/>");
        x.push("  <bridge stp='on' delay='0'/>");
        if (o.mode !== "internal") {
            x.push("  <ip address='" + p.host + "' netmask='" + p.netmask + "'>");
            if (p.dhcp) {
                x.push("    <dhcp>");
                for (var r = 0; r < p.ranges.length; r++)
                    x.push("      <range start='" + p.ranges[r].start + "' end='" + p.ranges[r].end + "'/>");
                x.push("    </dhcp>");
            }
            x.push("  </ip>");
        }
        x.push("</network>");
        root.run("net-create",
            "t=$(mktemp) || exit 1; trap 'rm -f \"$t\"' EXIT; cat > \"$t\" <<'VEXYONNET'\n" +
            x.join("\n") + "\nVEXYONNET\n" +
            "$V net-define \"$t\" || exit 1; " +
            //  Si no arranca (casi siempre: esa subred ya la usa una interfaz
            //  del anfitrión) se deshace el define. Si no, quedaba una red
            //  definida, parada e inútil que además ocupaba el nombre.
            "$V net-start " + q(o.name) + " || { $V net-undefine " + q(o.name) + " >/dev/null 2>&1; exit 1; }; " +
            ((o.autostart === false) ? "" : "$V net-autostart " + q(o.name) + " >/dev/null; ") +
            //  Con el MISMO nombre que una red borrada con VMs encendidas
            //  dentro, esas VMs la siguen nombrando: se reenganchan.
            root._netReconnect(o.name));
    }

    // ---- reenganchar adaptadores huérfanos ----------------------------------
    //  ⚠️ libvirt NO vuelve a meter en el puente a los adaptadores de las VMs
    //  ENCENDIDAS cuando su red se para y se arranca otra vez, ni cuando se
    //  borra y se crea otra con el mismo nombre. Medido con libvirt 12.2.0: el
    //  puente nuevo nace SIN puertos (NO-CARRIER, DOWN) y los vnetN se quedan
    //  sin `master` — la VM cree que tiene cable y no llega a nadie. Solo un
    //  reinicio de libvirtd los reengancha, y eso pide root.
    //  Tampoco vale un `update-device --live` con el mismo XML: libvirt solo
    //  mueve el tap si cambia el NOMBRE del puente, y una red reiniciada
    //  conserva el suyo (el virbrN queda escrito en su definición).
    //  Lo que sí funciona, sin privilegios: aparcar el adaptador en una red
    //  temporal vacía y devolverlo a la suya — dos `update-device --live` con
    //  su propio <interface> vivo (vexyon-vm-xml iface-retarget). Cada paso
    //  cambia de puente, así que libvirt suelta y vuelve a enganchar el TAP en
    //  el anfitrión; el invitado no se entera: misma MAC, mismo modelo, misma
    //  dirección PCI, mismo vnetN, la tarjeta no se desenchufa. La red temporal
    //  es transitoria, aislada, sin IP ni DHCP, y se destruye al acabar.
    //  Después se COMPRUEBA en /sys que cada vnetN cuelga del puente que toca;
    //  el que no, se avisa en ámbar con su VM y su MAC.
    //  Si no hay VMs encendidas en esa red cuesta un `net-info` y un
    //  `domiflist` por VM encendida, y no toca nada.
    function _netReconnect(n) {
        var X = q(root.xmlBin);
        return "BR=$($V net-info " + q(n) + " 2>/dev/null | sed -n 's/^Bridge: *//p'); " +
            "if [ -n \"$BR\" ]; then " +
              "NICS=$($V list --name 2>/dev/null | while read -r d; do [ -n \"$d\" ] && " +
                "$V domiflist \"$d\" 2>/dev/null | awk -v d=\"$d\" -v n=" + q(n) + " " +
                "'NR>2 && $2==\"network\" && $3==n {print d \"\\t\" $1 \"\\t\" $5}'; done); " +
              "P=''; R=$(mktemp -d) || exit 1; " +
              "while IFS=$'\\t' read -r d tap mac; do [ -z \"$d\" ] && continue; " +
                "[ \"$(basename \"$(readlink \"/sys/class/net/$tap/master\" 2>/dev/null)\")\" = \"$BR\" ] && continue; " +
                "if [ -z \"$P\" ]; then P=vexyon-reconnect-$$; " +
                  "printf \"<network><name>%s</name><bridge stp='off' delay='0'/></network>\\n\" \"$P\" > \"$R/park.xml\"; " +
                  "$V net-create \"$R/park.xml\" >/dev/null 2>&1 || P=-; fi; " +
                "[ \"$P\" != - ] && $V dumpxml \"$d\" > \"$R/live.xml\" 2>/dev/null && " +
                  X + " iface-retarget \"$mac\" network \"$P\" < \"$R/live.xml\" > \"$R/p.xml\" && " +
                  X + " iface-retarget \"$mac\" network " + q(n) + " < \"$R/live.xml\" > \"$R/b.xml\" && " +
                  "$V update-device \"$d\" \"$R/p.xml\" --live >/dev/null 2>&1 && " +
                  "$V update-device \"$d\" \"$R/b.xml\" --live >/dev/null 2>&1; " +
                "[ \"$(basename \"$(readlink \"/sys/class/net/$tap/master\" 2>/dev/null)\")\" = \"$BR\" ] || " +
                  "printf '@@WARN %s\\t%s\\n' 'Could not reconnect a running VM adapter to this network:' \"$d $mac\" >&2; " +
              "done <<< \"$NICS\"; " +
              "case \"$P\" in ''|-) ;; *) $V net-destroy \"$P\" >/dev/null 2>&1;; esac; " +
              "rm -rf \"$R\"; " +
            "fi; ";
    }
    //  Lo mismo a mano, con la red YA arrancada: lo ofrece el diagnóstico cuando
    //  encuentra adaptadores encendidos que no cuelgan de su puente.
    function netReconnect(n) { root.run("net-reconnect", root._netReconnect(n)); }

    // ---- diagnóstico de redes -------------------------------------------------
    //  UNA pasada de solo lectura, a petición (botón "Diagnosticar redes" de la
    //  pestaña de redes). Ni demonio, ni sondeo, ni nada que se quede vigilando:
    //  un bash que vuelca HECHOS y se acaba, y las conclusiones se sacan aquí.
    //  Solo lee: virsh, /sys (puentes y el `master` de cada vnetN), `ip -4
    //  addr`, `systemctl is-active` y, en NixOS, los scripts del cortafuegos,
    //  que viven en el store y los puede leer cualquiera (así se sabe si ya
    //  llevan la excepción para libvirt sin pedir root para `iptables -S`).
    //  Comprueba lo que se ha visto romper:
    //   * vnetN de VMs encendidas que no cuelgan del puente de su red (red
    //     reiniciada o rehecha con ellas dentro) -> botón Reenganchar;
    //   * puente con VMs y sin portadora; IP del anfitrión repetida o subredes
    //     que se pisan; puentes virbrN / vx-* que no son de ninguna red viva;
    //   * br_netfilter, y el cortafuegos que corta el tráfico entre VMs: el
    //     rpfilter estricto de NixOS, la entrada de su cortafuegos nftables
    //     (DHCP/DNS), su filterForward, y fuera de NixOS la política DROP de
    //     Docker o ufw frente a las reglas nftables de libvirt.
    readonly property string _diagScript:
        "echo @@DNET\n" +
        "$V net-list --all --name 2>/dev/null | while read -r n; do [ -z \"$n\" ] && continue\n" +
        "  x=$($V net-dumpxml \"$n\" 2>/dev/null)\n" +
        "  a=$($V net-info \"$n\" 2>/dev/null | sed -n 's/^Active: *//p')\n" +
        "  br=$(printf '%s' \"$x\" | sed -n \"s/.*<bridge name='\\([^']*\\)'.*/\\1/p\" | head -1)\n" +
        "  ip=$(printf '%s' \"$x\" | sed -n \"s/.*<ip address='\\([0-9.]*\\)'.*/\\1/p\" | head -1)\n" +
        "  msk=$(printf '%s' \"$x\" | sed -n \"s/.*<ip[^>]*netmask='\\([0-9.]*\\)'.*/\\1/p\" | head -1)\n" +
        "  printf '%s\\t%s\\t%s\\t%s\\t%s\\n' \"$n\" \"$a\" \"$br\" \"$ip\" \"$msk\"\n" +
        "done\n" +
        "echo @@DIF\n" +
        "$V list --name 2>/dev/null | while read -r d; do [ -z \"$d\" ] && continue\n" +
        "  $V domiflist \"$d\" 2>/dev/null | awk 'NR>2 && NF>=5 {print $1, $2, $3, $5}' | while read -r tap t src mac; do\n" +
        "    printf '%s\\t%s\\t%s\\t%s\\t%s\\t%s\\n' \"$d\" \"$tap\" \"$t\" \"$src\" \"$mac\" \"$(basename \"$(readlink \"/sys/class/net/$tap/master\" 2>/dev/null)\")\"\n" +
        "  done\n" +
        "done\n" +
        "echo @@DBR\n" +
        "for b in /sys/class/net/*/bridge; do [ -d \"$b\" ] || continue; b=${b%/bridge}\n" +
        "  printf '%s\\t%s\\t%s\\n' \"${b##*/}\" \"$(cat \"$b/carrier\" 2>/dev/null || echo 0)\" \"$(ls \"$b/brif\" 2>/dev/null | wc -l)\"\n" +
        "done\n" +
        "echo @@DADDR\n" +
        "ip -4 -o addr show 2>/dev/null | awk '{print $2 \"\\t\" $4}'\n" +
        "echo @@DSYS\n" +
        "printf 'brnf\\t%s\\n' \"$(cat /proc/sys/net/bridge/bridge-nf-call-iptables 2>/dev/null || echo absent)\"\n" +
        "for u in docker ufw firewalld nftables firewall; do printf 'unit\\t%s\\t%s\\n' \"$u\" \"$(systemctl is-active \"$u.service\" 2>/dev/null)\"; done\n" +
        "be=''; for f in /etc/libvirt/network.conf /var/lib/libvirt/network.conf; do [ -r \"$f\" ] || continue\n" +
        "  v=$(sed -n 's/^[[:space:]]*firewall_backend[[:space:]]*=[[:space:]]*\"\\([a-z]*\\)\".*/\\1/p' \"$f\" | tail -1); [ -n \"$v\" ] && be=$v; done\n" +
        "[ -n \"$be\" ] || { command -v nft >/dev/null 2>&1 && be=nftables-default || be=iptables-default; }\n" +
        "printf 'backend\\t%s\\n' \"$be\"\n" +
        "for u in firewall nftables; do\n" +
        "  for p in $(systemctl show -p ExecStart \"$u.service\" 2>/dev/null | grep -o 'path=/nix/store/[^ ;]*' | cut -d= -f2); do\n" +
        "    case \"$p\" in *firewall-start*) k=nixipt;; *nftables-rules*) k=nixnft;; *) continue;; esac\n" +
        "    [ -r \"$p\" ] || continue; printf 'fwfile\\t%s\\n' \"$k\"\n" +
        "    grep -q rpfilter \"$p\" && printf 'fw\\t%s\\trp\\n' \"$k\"\n" +
        "    grep -E 'virbr(\\*|\\+)' \"$p\" | grep -qE 'rpfilter|fib' && printf 'fw\\t%s\\trpexc\\n' \"$k\"\n" +
        "    grep -E 'virbr(\\*|\\+)' \"$p\" | grep -qE 'dport|trusted' && printf 'fw\\t%s\\tinexc\\n' \"$k\"\n" +
        "    grep -q 'chain forward-allow' \"$p\" && printf 'fw\\t%s\\tff\\n' \"$k\"\n" +
        "    grep -E 'virbr(\\*|\\+)' \"$p\" | grep -vE 'dport|fib|rpfilter|trusted' | grep -q accept && printf 'fw\\t%s\\tffexc\\n' \"$k\"\n" +
        "  done\n" +
        "done\n" +
        "[ -r /etc/nftables.conf ] && for k in 'hook input' 'hook forward' 'flush ruleset' virbr; do grep -q \"$k\" /etc/nftables.conf && printf 'fw\\tetcnft\\t%s\\n' \"$k\"; done\n" +
        ":\n";
    function diagnoseNetworks() {
        if (!root.enabled || netDiagProc.running) return;
        netDiagProc.running = true;
    }
    function _diagAnalyze(text) {
        var sec = "", nets = {}, nics = [], brs = {}, addrs = [];
        var sys = { units: {}, fw: {}, fwfile: {} };
        var ls = String(text).split("\n");
        for (var i = 0; i < ls.length; i++) {
            var l = ls[i];
            if (l.indexOf("@@D") === 0) { sec = l.trim(); continue; }
            if (l.trim() === "") continue;
            var f = l.split("\t");
            if (sec === "@@DNET")
                nets[f[0]] = { active: f[1] === "yes", bridge: f[2] || "", ip: f[3] || "", netmask: f[4] || "" };
            else if (sec === "@@DIF")
                nics.push({ vm: f[0], tap: f[1], type: f[2], source: f[3], mac: f[4], master: f[5] || "" });
            else if (sec === "@@DBR")
                brs[f[0]] = { carrier: f[1] === "1", ports: parseInt(f[2], 10) || 0 };
            else if (sec === "@@DADDR") {
                var c = String(f[1] || "").split("/");
                addrs.push({ dev: f[0], ip: c[0], bits: parseInt(c[1], 10) || 32 });
            } else if (sec === "@@DSYS") {
                if (f[0] === "unit") sys.units[f[1]] = f[2] === "active";
                else if (f[0] === "fwfile") sys.fwfile[f[1]] = true;
                else if (f[0] === "fw") sys.fw[f[1] + ":" + f[2]] = true;
                else sys[f[0]] = f[1] || "";
            }
        }
        var out = [];
        function add(level, title, detail, fix, net, settings, cmd) {
            out.push({ level: level, title: title, detail: detail || "", fix: fix || "",
                       net: net || "", settings: settings === true, cmd: cmd || "" });
        }
        //  ¿se pisan a/abits y b/bbits? Con la máscara más corta caen en la misma subred.
        function overlap(a, abits, b, bbits) {
            var x = root._ipNum(a), y = root._ipNum(b);
            if (x < 0 || y < 0) return false;
            var bits = Math.min(abits, bbits);
            var m = bits === 0 ? 0 : ((0xFFFFFFFF << (32 - bits)) >>> 0);
            return ((x & m) >>> 0) === ((y & m) >>> 0);
        }

        // 1) adaptadores de VMs encendidas fuera del puente que les toca,
        //    agrupados por red (y si su puente no tiene portadora, se dice)
        var lost = {};
        for (var j = 0; j < nics.length; j++) {
            var n = nics[j];
            if (n.type === "network") {
                var w = nets[n.source];
                if (!w || !w.active) {
                    add("bad", I18n.t("A running VM is plugged into a network that is not running"),
                        n.vm + " · " + n.mac + " → " + n.source,
                        w ? I18n.t("Start that network: the running VMs on it are plugged back in automatically.")
                          : I18n.t("That network no longer exists. Change the adapter's network in the VM's Network tab, or create a network with that name again."));
                } else if (n.master !== w.bridge) {
                    (lost[n.source] = lost[n.source] || []).push(n.vm + " (" + n.mac + ", " + n.tap + " → "
                        + (n.master !== "" ? n.master : I18n.t("nothing")) + ")");
                }
            } else if (n.type === "bridge" && n.master !== n.source) {
                add("bad", I18n.t("A running VM's bridged adapter is not on its host bridge"),
                    n.vm + " · " + n.mac + " · " + n.tap + " → " + (n.master !== "" ? n.master : I18n.t("nothing"))
                        + " (" + I18n.t("expected") + " " + n.source + ")",
                    I18n.t("Check that the host bridge still exists, then restart the VM."));
            }
        }
        for (var ln in lost) {
            var lb = brs[nets[ln].bridge];
            add("bad", I18n.t("Running VMs are not plugged into the bridge of this network:") + " " + ln,
                lost[ln].join(" · ") + "  ·  " + nets[ln].bridge + ": "
                    + (lb && lb.carrier ? I18n.t("carrier") : I18n.t("no carrier")),
                I18n.t("This happens when a network is stopped or deleted and created again while VMs are running on it. Reconnect plugs the same adapters back in: same MAC, same device inside the guest."),
                ln);
        }

        // 2) direcciones del anfitrión: repetidas o subredes que se pisan
        var names = Object.keys(nets);
        for (var a = 0; a < names.length; a++) {
            var na = nets[names[a]], abits = parseInt(root.maskBits(na.netmask), 10);
            if (na.ip === "" || isNaN(abits)) continue;
            for (var k = 0; k < addrs.length; k++) {
                var ad = addrs[k];
                if (ad.dev === na.bridge || ad.dev === "lo") continue;
                if (ad.ip === na.ip)
                    add("bad", I18n.t("The host address of a network is also used by another interface"),
                        names[a] + " · " + na.ip + " · " + ad.dev,
                        I18n.t("Two interfaces with the same address break routing to the VMs. Give one of them another address."));
                else if (overlap(na.ip, abits, ad.ip, ad.bits))
                    add("warn", I18n.t("A network's subnet overlaps an address range already on this computer"),
                        names[a] + " (" + na.ip + "/" + abits + ") · " + ad.dev + " (" + ad.ip + "/" + ad.bits + ")",
                        I18n.t("libvirt refuses to start a network whose subnet is already routed elsewhere. Use a different subnet for it."));
            }
            for (var b = a + 1; b < names.length; b++) {
                var nb = nets[names[b]], bbits = parseInt(root.maskBits(nb.netmask), 10);
                if (nb.ip === "" || isNaN(bbits)) continue;
                if (overlap(na.ip, abits, nb.ip, bbits))
                    add("warn", I18n.t("Two libvirt networks use overlapping subnets"),
                        names[a] + " (" + na.ip + "/" + abits + ") · " + names[b] + " (" + nb.ip + "/" + bbits + ")",
                        I18n.t("Only one of them can be running at a time. Give one of them another subnet."));
            }
        }

        // 3) br_netfilter y el cortafuegos
        var brnf = sys.brnf === "1";
        if (brnf)
            add("info", I18n.t("br_netfilter is active: traffic between VMs on the same bridge also passes through the host firewall"),
                "net.bridge.bridge-nf-call-iptables = 1",
                I18n.t("Docker, Incus and Kubernetes load it. It is why a firewall rule meant for routed traffic can also cut VM-to-VM traffic."));
        if (root.platform === "nixos") {
            if (sys.fwfile.nixipt && sys.fw["nixipt:rp"] && !sys.fw["nixipt:rpexc"])
                add(brnf ? "bad" : "info",
                    brnf ? I18n.t("NixOS's reverse-path filter drops traffic between VMs")
                         : I18n.t("NixOS's reverse-path filter has no exception for libvirt bridges"),
                    brnf ? I18n.t("Internal networks (the host has no route to them) and a router VM's clients are cut off.")
                         : I18n.t("Fine while br_netfilter is not loaded. Once Docker, Incus or Kubernetes load it, internal networks and router VMs stop working."),
                    I18n.t("The exception is one line in configuration.nix — see Settings → Virtualization → Firewall."), "", true);
            if (sys.fwfile.nixnft) {
                if (!sys.fw["nixnft:inexc"])
                    add("bad", I18n.t("The NixOS nftables firewall drops DHCP and DNS from VMs"),
                        I18n.t("VMs on libvirt networks get no address. libvirt's own nftables rules cannot accept what another table drops."),
                        I18n.t("See Settings → Virtualization → Firewall."), "", true);
                if (sys.fw["nixnft:rp"] && !sys.fw["nixnft:rpexc"] && brnf)
                    add("bad", I18n.t("NixOS's reverse-path filter drops traffic between VMs"),
                        I18n.t("Internal networks (the host has no route to them) and a router VM's clients are cut off."),
                        I18n.t("See Settings → Virtualization → Firewall."), "", true);
                if (sys.fw["nixnft:ff"] && !sys.fw["nixnft:ffexc"])
                    add("bad", I18n.t("networking.firewall.filterForward drops the VMs' forwarded traffic"),
                        I18n.t("NAT to the internet, and with br_netfilter also traffic between VMs, is dropped."),
                        I18n.t("See Settings → Virtualization → Firewall."), "", true);
            }
        } else {
            var who = [];
            if (sys.units.docker) who.push("Docker");
            if (sys.units.ufw) who.push("ufw");
            if (who.length > 0 && String(sys.backend || "").indexOf("nftables") === 0)
                add("bad", I18n.t("libvirt's nftables rules cannot override the DROP policy set by") + " " + who.join(", "),
                    I18n.t("VMs lose DHCP (ufw) and all forwarded traffic: the internet and, with br_netfilter, each other."),
                    I18n.t("Make libvirt write its rules into the same iptables tables: firewall_backend = \"iptables\" in /etc/libvirt/network.conf, then restart libvirtd."),
                    "", root.platform === "arch");
            if (sys.units.nftables && (sys.fw["etcnft:hook input"] || sys.fw["etcnft:hook forward"])
                    && !sys.fw["etcnft:virbr"])
                add("warn", I18n.t("nftables.service filters traffic and has no rule for the libvirt bridges"),
                    I18n.t("If its input or forward chain drops by default, VMs get no address and cannot reach anything."),
                    I18n.t("Allow the libvirt bridges (virbr*) in /etc/nftables.conf: see Settings → Virtualization → Firewall."),
                    "", root.platform === "arch");
            if (sys.units.nftables && sys.fw["etcnft:flush ruleset"])
                add("info", I18n.t("/etc/nftables.conf starts with flush ruleset"),
                    I18n.t("Reloading nftables.service then also deletes the rules of libvirt (and Docker) until they are restarted."),
                    I18n.t("After reloading it, restart libvirtd."));
            if (sys.units.firewalld)
                add("info", I18n.t("firewalld is active"), "",
                    I18n.t("libvirt puts its bridges in firewalld's libvirt zone, which allows DHCP, DNS and forwarding. Nothing to change."));
        }

        // 4) puentes huérfanos: con nombre de libvirt (virbrN) o vx-*, y sin
        //    ninguna red ARRANCADA que sea su dueña
        var owned = {};
        for (var o in nets) if (nets[o].active && nets[o].bridge !== "") owned[nets[o].bridge] = true;
        for (var br in brs)
            if ((/^virbr[0-9]+$/.test(br) || br.indexOf("vx-") === 0) && !owned[br])
                add("warn", I18n.t("Orphaned bridge: no running libvirt network owns it"),
                    br + " · " + brs[br].ports + " " + I18n.t("ports"),
                    I18n.t("Left over from a network that was not shut down cleanly. If nothing else uses it, remove it:"),
                    "", false, "sudo ip link delete " + br);
        return out;
    }
    function netAutostart(n, on) {
        root.run("net-autostart", "$V net-autostart " + (on ? "" : "--disable ") + q(n));
    }
    // Conectar/desconectar la interfaz en caliente (link up/down): lo único que
    // libvirt permite tocar de la red sin reiniciar la VM.
    //  ⚠️ SIN `--live`: `domif-setlink` NO acepta esa opción (medido con
    //  libvirt 12.2.0: "command 'domif-setlink' doesn't support option
    //  --live"). Sus únicas opciones son `--config` y `--print-xml`; sin
    //  ninguna actúa sobre el dispositivo VIVO, que es justo lo que se quiere.
    //  La interfaz se identifica por su MAC (columna 5 de `domiflist`), que es
    //  lo que espera el subcomando.
    function setLink(name, up) {
        root.run("domif-setlink",
            "m=$($V domiflist " + q(name) + " 2>/dev/null | awk 'NR>2 && NF {print $5; exit}'); " +
            "[ -n \"$m\" ] && $V domif-setlink " + q(name) + " \"$m\" " + (up ? "up" : "down"));
    }

    // ---- crear una VM ------------------------------------------------------
    //  Sin virt-install (en nixpkgs vive DENTRO de virt-manager, que arrastra
    //  todo GTK — justo lo que este proyecto evita). Se genera el XML del
    //  dominio y se aplica con `virsh define`.
    //
    //  El DISCO se crea con `virsh vol-create-as`, NO con `qemu-img create`:
    //  /var/lib/libvirt/images es root:root 0711 y un usuario normal no puede
    //  escribir ahí (comprobado en esta máquina). vol-create-as lo crea el
    //  propio libvirtd, que sí es root, y además deja el dueño/permisos que
    //  espera el qemu de CADA distro — con qemu-img habría que adivinarlos.
    //  Ver PROJECT_STATE.md: es la única desviación del guion original.
    //
    //  El pool `default` y la red `default` se aseguran aquí mismo: son la
    //  fontanería de una sola vez de libvirt, no una decisión del usuario.
    function createVm(o) {
        if (!root.enabled) return;
        // La ISO del asistente pasa por la misma expansión que el resto: sin
        // esto una `~/algo.iso` acababa LITERAL en el XML del dominio.
        o.iso = root.expandPath(o.iso);
        var disk = "/var/lib/libvirt/images/" + o.name + ".qcow2";
        var xml = root.domainXml(o, disk);
        // El XML viaja por stdin de `cat` a un temporal del propio bash: así no
        // hay que escribir un fichero desde QML ni escapar el XML en la línea.
        root.run("create",
            // pool por defecto (idempotente: si ya existe, los fallos se tragan)
            "$V pool-info default >/dev/null 2>&1 || { " +
              "$V pool-define-as default dir --target /var/lib/libvirt/images >/dev/null 2>&1; " +
              "$V pool-build default >/dev/null 2>&1; $V pool-autostart default >/dev/null 2>&1; }; " +
            "$V pool-start default >/dev/null 2>&1; " +
            // red por defecto, solo si la VM la pide
            (o.network === "none" ? "" :
              "$V net-info " + q(o.network) + " >/dev/null 2>&1 && " +
              "{ $V net-start " + q(o.network) + " >/dev/null 2>&1; $V net-autostart " + q(o.network) + " >/dev/null 2>&1; }; ") +
            // disco
            (o.iso === "" ? "" : root.pathGuard(o.iso)) +
            "$V vol-create-as default " + q(o.name + ".qcow2") + " " + Math.max(1, o.diskGb) + "G --format qcow2 || exit 1; " +
            // dominio
            "t=$(mktemp) || exit 1; cat > \"$t\" <<'VEXYONXML'\n" + xml + "\nVEXYONXML\n" +
            "$V define \"$t\"; rc=$?; rm -f \"$t\"; exit $rc");
    }

    // ---- qué invitado se va a instalar --------------------------------------
    //  ⚠️ NO ES COSMÉTICO Y NO ES UN "PERFIL". Es lo que decide tres piezas de
    //  hardware que en Windows NO pueden ser las de Linux, y cada una de ellas
    //  se midió rompiendo una instalación real en esta torre:
    //
    //   * CONTROLADORA DEL DISCO. Windows NO trae driver en caja para virtio-
    //     blk ni para virtio-scsi. Con el disco en virtio el instalador de
    //     Windows Server 2022 llega a "¿Dónde quieres instalar Windows?" y la
    //     lista sale VACÍA. Con `sata` (AHCI) lo ve sin cargar nada.
    //   * MODELO DE LA TARJETA DE RED. Tampoco hay driver en caja para
    //     virtio-net: el invitado se queda sin red por NAT Y por puente
    //     (Linux sí lo trae, por eso el mismo `default` funcionaba en Ubuntu y
    //     no en Windows). `e1000e` lo reconoce Windows solo.
    //   * TPM. Windows 11 aborta con "El equipo debe admitir TPM 2.0" si el
    //     dominio no declara ninguno, y el asistente no declaraba ninguno
    //     NUNCA (medido: `virsh dumpxml win11` no tenía la etiqueta <tpm>).
    //
    //  Se pregunta en vez de deducirse a ciegas, y NO se enciende para todos:
    //  un TPM en un invitado Linux es peso muerto, y meter todos los discos en
    //  SATA le quitaría a Linux el rendimiento de virtio, que es la razón por
    //  la que virtio existe.
    //
    //   "linux"    virtio de arriba abajo (lo de siempre)
    //   "windows"  Windows 10 / 8.1 / 7 y Windows Server: sata + e1000e
    //   "win11"    lo anterior MÁS TPM 2.0 y UEFI forzado (Windows 11,
    //              Windows Server 2025 y cualquier cosa que exija TPM)
    function osDiskBus(osType) { return osType === "linux" ? "virtio" : "sata"; }
    function osNicModel(osType) { return osType === "linux" ? "virtio" : "e1000e"; }
    function osNeedsTpm(osType) { return osType === "win11"; }
    //  ⚠️ LA TARJETA GRÁFICA TAMBIÉN DEPENDE DEL INVITADO, y no por rendimiento:
    //  es lo que decide si la pantalla del invitado SIGUE al tamaño de la
    //  ventana. Medido en esta torre con el MISMO invitado (Ubuntu 26.04 en
    //  vivo), el mismo `virt-viewer --auto-resize=always` y spice-vdagent
    //  corriendo dentro en los dos casos:
    //
    //    qxl     -> el anfitrión manda la petición ("main-1:0: sending new
    //               monitors config to guest, monitor #0: 2536x1325"), el
    //               invitado NO la aplica y se queda clavado en 1024x768.
    //    virtio  -> el invitado pasa a 2536x1325, o sea EXACTAMENTE el área de
    //               dibujo de la ventana. Sigue a la ventana al redimensionar.
    //
    //  El motivo: en una sesión Wayland (GNOME, KDE, Hyprland… o sea todo lo
    //  moderno) la vía de spice-vdagent para cambiar de modo es XRandR, que en
    //  Wayland no existe. Con virtio-gpu el cambio de modo llega por el
    //  driver DRM del núcleo y el compositor lo aplica solo.
    //
    //  Y por eso el Ubuntu del usuario SÍ redimensionaba: su dominio ya venía
    //  con `<model type='virtio'>` (comprobado con virsh dumpxml), mientras que
    //  el asistente ponía qxl a todo lo que creaba.
    //
    //  En Windows se queda QXL a propósito: virtio-gpu NO tiene driver en caja
    //  en Windows y ahí el invitado se cae al adaptador básico. QXL es el que
    //  trae driver en las spice-guest-tools, que es la vía de Windows.
    function osVideo(osType) { return osType === "linux" ? "virtio" : "qxl"; }

    //  Adivinar el invitado por el NOMBRE de la ISO. Es solo el valor INICIAL
    //  del selector del asistente: el usuario lo ve y lo puede cambiar antes
    //  de crear nada. Se acierta con los nombres que reparte Microsoft
    //  ("Win11_25H2_Spanish_x64_v2.iso", "SERVER_EVAL_x64FRE_es-es.iso") sin
    //  leer un solo byte del fichero.
    function guessOsType(iso) {
        var f = String(iso || "").toLowerCase().split("/").pop();
        if (f === "") return "linux";
        if (/win.?(11|12)|windows.?(11|12)|server.?202[5-9]/.test(f)) return "win11";
        if (/win|windows|server_eval|_eval_x64/.test(f)) return "windows";
        return "linux";
    }

    // Genera el XML del dominio. Sin aceleración 3D ni passthrough a propósito
    // (fuera de alcance): qxl + spice, que es lo que virt-viewer sabe abrir y
    // funciona con cualquier escritorio por software.
    function domainXml(o, disk) {
        var osType = o.osType || "linux";
        //  Windows 11 EXIGE UEFI con arranque seguro: con BIOS el TPM no le
        //  vale de nada y vuelve a plantarse en los requisitos. Se fuerza aquí
        //  en vez de dejarlo a la casilla del asistente porque no es una
        //  preferencia, es un requisito del invitado.
        var uefi = o.firmware === "uefi" || osType === "win11";
        var mem = Math.max(256, o.memMib);
        var lines = [];
        lines.push("<domain type='kvm'>");
        lines.push("  <name>" + root.xmlEsc(o.name) + "</name>");
        lines.push("  <memory unit='MiB'>" + mem + "</memory>");
        lines.push("  <currentMemory unit='MiB'>" + mem + "</currentMemory>");
        lines.push("  <vcpu>" + Math.max(1, o.vcpus) + "</vcpu>");
        // firmware='efi' = autoselección por los descriptores JSON que trae
        // QEMU. Es la razón por la que NixOS 26.05 pudo retirar el submódulo
        // virtualisation.libvirtd.qemu.ovmf: ya no hay que declarar rutas.
        lines.push("  <os" + (uefi ? " firmware='efi'" : "") + ">");
        lines.push("    <type arch='x86_64' machine='q35'>hvm</type>");
        if (o.iso && o.iso !== "") lines.push("    <boot dev='cdrom'/>");
        lines.push("    <boot dev='hd'/>");
        lines.push("  </os>");
        lines.push("  <features><acpi/><apic/></features>");
        lines.push("  <cpu mode='host-passthrough'/>");
        lines.push("  <clock offset='utc'/>");
        lines.push("  <on_poweroff>destroy</on_poweroff>");
        lines.push("  <on_reboot>restart</on_reboot>");
        lines.push("  <on_crash>destroy</on_crash>");
        lines.push("  <devices>");
        //  ⚠️ LA CONTROLADORA DEL DISCO NO PUEDE IR FIJA A virtio. Iba, y es la
        //  causa de que un Windows 10 importado de un .ova se plantara en
        //  INACCESSIBLE_BOOT_DEVICE: ese Windows trae controladores para la
        //  controladora que tenía en origen (SATA/AHCI o IDE, que es lo que
        //  ponen VirtualBox y VMware) y ninguno para virtio, así que arranca,
        //  no ve el disco de sistema y se para. Al importar se conserva la que
        //  declare el .ovf; aquí solo se traduce a XML de libvirt.
        //  El .ova manda si trae bus declarado; si no, lo decide el invitado
        //  (Windows -> sata, porque no tiene driver de virtio en caja).
        var bus = o.bus || root.osDiskBus(osType);
        var dev = (bus === "virtio") ? "vda" : (bus === "ide" ? "hda" : "sda");
        lines.push("    <disk type='file' device='disk'>");
        lines.push("      <driver name='qemu' type='qcow2'/>");
        lines.push("      <source file='" + root.xmlEsc(disk) + "'/>");
        lines.push("      <target dev='" + dev + "' bus='" + root.xmlEsc(bus) + "'/>");
        lines.push("    </disk>");
        // scsi necesita su controladora declarada; sata e ide las pone q35 solo.
        if (bus === "scsi") lines.push("    <controller type='scsi' model='virtio-scsi'/>");
        if (o.iso && o.iso !== "") {
            lines.push("    <disk type='file' device='cdrom'>");
            lines.push("      <driver name='qemu' type='raw'/>");
            lines.push("      <source file='" + root.xmlEsc(o.iso) + "'/>");
            // sda ya puede estar cogido por el disco duro si NO es virtio
            lines.push("      <target dev='" + (dev === "sda" ? "sdb" : "sda") + "' bus='sata'/>");
            lines.push("      <readonly/>");
            lines.push("    </disk>");
        }
        if (o.network && o.network !== "none") {
            lines.push("    <interface type='network'>");
            lines.push("      <source network='" + root.xmlEsc(o.network) + "'/>");
            //  virtio-net SOLO para invitados con driver en caja. Ver osNicModel().
            lines.push("      <model type='" + root.osNicModel(osType) + "'/>");
            lines.push("    </interface>");
        }
        // serie + consola: sin esto `virsh console` no tiene a qué conectarse
        lines.push("    <serial type='pty'><target port='0'/></serial>");
        lines.push("    <console type='pty'><target type='serial' port='0'/></console>");
        lines.push("    <input type='tablet' bus='usb'/>");
        // Portapapeles de SPICE activado de fábrica; el invitado sigue
        // necesitando spice-vdagent para que funcione de verdad.
        lines.push("    <graphics type='spice' autoport='yes'><listen type='address'/>"
                 + "<image compression='off'/><clipboard copypaste='yes'/></graphics>");
        //  virtio-gpu para Linux, qxl para Windows. Ver osVideo(): de esto
        //  depende que la pantalla del invitado llene la ventana.
        lines.push("    <video><model type='" + root.osVideo(osType) + "' heads='1'/></video>");
        // ⚠️ EL CANAL DEL AGENTE SPICE, que faltaba y sin el cual NO había
        // manera de que funcionara ni el portapapeles compartido ni el
        // redimensionado automático del invitado — por muy bien instalado que
        // estuviera spice-vdagent dentro. Es la causa de raíz de que la
        // pantalla de la VM no llenara la ventana.
        lines.push("    <channel type='spicevmc'>");
        lines.push("      <target type='virtio' name='com.redhat.spice.0'/>");
        lines.push("    </channel>");
        // Dos canales de redirección USB por SPICE (lo que trae virt-manager
        // por defecto): permiten enchufar un USB al invitado desde el visor.
        lines.push("    <redirdev bus='usb' type='spicevmc'/>");
        lines.push("    <redirdev bus='usb' type='spicevmc'/>");
        //  TPM 2.0 emulado por swtpm, SOLO para el invitado que lo exige. El
        //  respaldo `emulator` lo levanta libvirtd por VM; swtpm no tiene que
        //  estar en el PATH del usuario (en NixOS systemd se lo da al servicio).
        if (root.osNeedsTpm(osType)) {
            lines.push("    <tpm model='tpm-crb'>");
            lines.push("      <backend type='emulator' version='2.0'/>");
            lines.push("    </tpm>");
        }
        lines.push("    <memballoon model='virtio'/>");
        lines.push("  </devices>");
        lines.push("</domain>");
        return lines.join("\n");
    }

    function xmlEsc(s) {
        return String(s).replace(/&/g, "&amp;").replace(/</g, "&lt;")
                        .replace(/>/g, "&gt;").replace(/'/g, "&apos;").replace(/"/g, "&quot;");
    }

    // Nombre válido para libvirt Y para un fichero de disco.
    function validName(n) { return /^[A-Za-z0-9][A-Za-z0-9._-]{0,62}$/.test(n); }
    function nameTaken(n) {
        for (var i = 0; i < root.vms.length; i++) if (root.vms[i].name === n) return true;
        return false;
    }

    // ---- abrir la VM ---------------------------------------------------------
    //  El display se abre con virt-viewer COMO PROCESO EXTERNO. El shell NO
    //  dibuja NADA encima: aquí solo hay un execDetached, no hay ninguna
    //  superficie del shell sobre esa ventana. La franja gris con botones que
    //  se veía antes era la BARRA DE CABECERA PROPIA de virt-viewer (GTK), no
    //  nuestra — y solo desaparece en su modo de pantalla completa. Medido:
    //
    //    sin -f  -> cabecera GTK visible, invitado 1024x768 centrado 1:1 en
    //               una ventana de 1896x1012, con márgenes grises a los lados
    //    con -f  -> SIN cabecera, una sola ventana, invitado a pantalla completa
    //    con -k  -> sin cabecera pero abre UNA VENTANA POR MONITOR (tres aquí):
    //               inservible en esta torre, por eso NO se usa kiosco
    //
    //  ABRE EN VENTANA, no a pantalla completa. Antes salía con -f para que no
    //  se viera esa cabecera GTK, pero eso decide por el usuario: la ventana
    //  aparecía ocupándolo todo sin haberlo pedido. Ahora sale como una ventana
    //  normal, que Hyprland embaldosa como a cualquier otra, y a pantalla
    //  completa se pasa con Super+Shift+F cuando se quiera. Quien prefiera lo
    //  de antes tiene la clave `virtualization.viewerFullscreen`.
    //
    //  `--auto-resize=always` es lo que hace que el invitado CAMBIE su
    //  resolución para llenar la ventana en vez de quedarse centrado con
    //  márgenes. Necesita el agente `spice-vdagent` DENTRO del invitado y el
    //  canal `com.redhat.spice.0` en el dominio (Vm.hasSpiceAgent): sin las dos
    //  cosas virt-viewer no puede pedirle nada al invitado. La UI lo dice.
    function openViewer(name, onDgpu) {
        if (!root.enabled || !name) return;
        // Sin virt-viewer, `execDetached` no falla de forma visible: el proceso
        // simplemente no arranca y el usuario ve... nada. Se dice.
        if (root.detected && !root.has.viewer) {
            root.lastError = I18n.t("virt-viewer is not installed, so the VM's display cannot be opened. Use the text console, or install it (see Settings → Virtualization).");
            return;
        }
        var cmd = ["virt-viewer", "-c", root.uri, "-a", "--auto-resize=always",
                   "--hotkeys=" + root.viewerHotkeys];
        if (root.viewerFullscreen) cmd.push("-f");
        cmd.push(name);
        // En la GPU dedicada: el MISMO virt-viewer con las variables que da
        // vexyon-gpu-detect (ver `dgpu`) delante, vía `env`. `env` hace exec,
        // así que la ventana sigue siendo de clase "virt-viewer" y le siguen
        // valiendo la regla del monitor enfocado (bridge) y la apertura en
        // ventana: nada de lo arreglado cambia.
        if (onDgpu === true && root.dgpu.state === "on" && root.dgpu.env.length > 0)
            cmd = ["env"].concat(root.dgpu.env).concat(cmd);
        Quickshell.execDetached(cmd);
    }

    // ---- GPU dedicada para el VISOR (no para la VM) --------------------------
    //  En portátiles híbridos (iGPU + dGPU: Intel/AMD + Nvidia, Intel + AMD,
    //  AMD + AMD…) el gestor ofrece abrir la pantalla con la dGPU. Eso SOLO
    //  elige qué GPU del ANFITRIÓN usa la ventana de virt-viewer; la VM no
    //  recibe ninguna GPU (eso sería passthrough VFIO, descartado a propósito).
    //  Y con el display que crea este gestor (SPICE sin GL) spice-gtk pinta la
    //  pantalla del invitado con cairo en la CPU: medido, el visor no carga
    //  ningún driver de GPU con o sin estas variables. La UI lo dice.
    //
    //  La decisión NO se toma aquí: la toma `vexyon-gpu-detect offload`, el
    //  MISMO script que fija el shell a la iGPU (mismo escaneo de sysfs, mismos
    //  modos). Devuelve state on/off/none, el motivo si está apagada y las
    //  variables que ponen UNA app en la dGPU (el trío de prime-run con el
    //  driver de Nvidia, DRI_PRIME=pci-… con Mesa). Se pregunta UNA vez al
    //  abrir el gestor — sin sondeo: una dGPU solo cambia de estado reiniciando
    //  o cerrando sesión (envycontrol, supergfxctl).
    //   none -> no hay botón (una sola GPU, como la torre)
    //   off  -> botón gris y el motivo debajo
    //   on   -> botón activo
    property var dgpu: ({ state: "none", name: "", why: "", driver: "", env: [] })
    readonly property string gpuBin: {
        var d = Quickshell.env("VEXYON_BIN_DIR");
        var base = (d && d !== "") ? d : Quickshell.env("HOME") + "/.config/vexyon/bin";
        return base + "/vexyon-gpu-detect";
    }
    function detectGpu() {
        if (!root.enabled || gpuProbe.running) return;
        gpuProbe.running = true;
    }
    // En VENTANA por defecto. A pantalla completa se pasa desde el compositor
    // (Super+Shift+F), que es lo mismo que se hace con cualquier otra ventana.
    readonly property bool viewerFullscreen: Config.get("virtualization", "viewerFullscreen", false) === true

    // ---- soltar el ratón y el teclado (Ctrl+Alt) ----------------------------
    //  ⚠️ ESTO NO ES COSMÉTICO Y NO ES UN DEFECTO REDUNDANTE. Sin `--hotkeys`,
    //  su propia página de manual lo dice con todas las letras:
    //
    //     "By default, keyboard shortcuts only work when the guest display
    //      widget does not have focus. Any actions specified in HOTKEYS will
    //      be effective even when the guest display widget has input focus."
    //
    //  O sea: con el foco DENTRO del invitado —que es exactamente cuando hay
    //  agarre y cuando hace falta soltarlo— el atajo de soltar NO se atiende.
    //  De ahí los dos síntomas que se veían:
    //
    //    * en ventana, el puntero solo se liberaba al ARRASTRARLO a otro
    //      monitor: eso mueve el foco fuera del widget del invitado (el foco
    //      sigue al ratón), y solo ENTONCES el atajo empieza a funcionar;
    //    * a pantalla completa no se soltaba NUNCA, porque no hay forma de
    //      quitarle el foco al invitado sin poder mover antes el puntero. La
    //      única salida era apagar la VM a lo bruto.
    //
    //  Descartado que fuera cosa del compositor: Hyprland NO tiene ningún bind
    //  con Ctrl+Alt (medido con `hyprctl binds`: las únicas máscaras que usa
    //  son 0, SUPER, SUPER+SHIFT y SUPER+ALT). Nadie se lo estaba comiendo por
    //  delante; es que virt-viewer no lo escuchaba.
    //
    //  Y la salida de emergencia que trae virt-viewer —su barra flotante de
    //  pantalla completa— aquí NO existe: solo aparece en SU modo de pantalla
    //  completa, y desde la S76 la pantalla completa la pone el compositor, así
    //  que virt-viewer se cree una ventana normal (grande) y nunca la dibuja.
    //  Sin este flag no quedaba ninguna vía de escape.
    //
    //  `ctrl+alt` es la MISMA combinación que el manual documenta como defecto
    //  ("Ctrl_L"+"Alt_L"): no se cambia lo que el usuario ya espera, se hace
    //  que funcione. Se deja configurable por si alguien la quiere en otra
    //  tecla (p. ej. "shift+f12" si el invitado usa Ctrl+Alt para algo).
    //
    //  ⚠️ Ojo al declarar acciones aquí: "hotkeys for which no binding is given
    //  are disabled". Por eso va también `toggle-fullscreen`: la pantalla
    //  completa PROPIA de virt-viewer es la que dibuja su barra flotante, o sea
    //  la salida de emergencia de toda la vida, y dejarla sin atajo la habría
    //  apagado justo al arreglar lo otro. El zoom se queda FUERA a propósito:
    //  `ctrl+plus` y `ctrl+minus` los rechaza el parser ("Invalid hotkey
    //  'ctrl+plus' for 'zoom-in'", medido), y sigue estando en el menú.
    readonly property string viewerHotkeys: Config.get("virtualization", "viewerHotkeys",
        "release-cursor=ctrl+alt,toggle-fullscreen=shift+f11")

    // Consola de texto en ghostty, para VMs sin escritorio gráfico.
    function openConsole(name) {
        if (!root.enabled) return;
        Quickshell.execDetached(["ghostty", "-e", "virsh", "-c", root.uri, "console", name]);
    }

    // ---- cambios de estado que NO vienen de aquí ----------------------------
    //  Apagar el invitado DESDE DENTRO (su propio "shutdown"), que se cuelgue,
    //  o un `virsh destroy` desde otra terminal: nada de eso pasa por el shell,
    //  así que la lista se quedaba diciendo "encendida" para siempre y la
    //  pastilla de la barra no se iba nunca.
    //
    //  Se escucha el MISMO flujo de eventos de libvirt que usa virt-manager
    //  (virConnectDomainEventRegisterAny). `virsh event --loop` es literalmente
    //  su envoltorio de línea de órdenes: el proceso se queda DORMIDO en el
    //  socket de libvirt y solo escribe cuando libvirt le avisa. NO es un
    //  sondeo —no hay temporizador ni nadie preguntando "¿ya?"— y no es un
    //  demonio: solo existe mientras haga falta y se muere solo.
    //
    //  Cuándo hace falta:
    //    * hay alguna VM encendida  -> hay algo que pueda apagarse por su
    //      cuenta, y la pastilla de la barra depende de enterarse;
    //    * hay alguna ventana del gestor abierta -> el usuario está mirando la
    //      lista, y un `virsh start` desde fuera también debe verse.
    //  Cuando no se cumple ninguna de las dos, el proceso NO existe: con el
    //  interruptor apagado el singleton ni se instancia, así que aquí tampoco
    //  hay nada. Coste cero, igual que antes.
    property int watchers: 0
    function addWatcher()    { root.watchers++; }
    function removeWatcher() { root.watchers = Math.max(0, root.watchers - 1); }
    readonly property bool eventsWanted: root.enabled && (root.anyRunning || root.watchers > 0)

    Process {
        id: lifecycle
        // Única excepción a la regla de "ningún Process se arranca solo": este
        // no arranca SIEMPRE, arranca cuando `eventsWanted` dice que sí. Es el
        // enlace mismo con el que se apaga y se enciende.
        running: root.eventsWanted
        command: ["bash", "-c", root.sh + "exec $V event --loop --all"]
        stdout: SplitParser {
            onRead: function(line) {
                // "…: event 'lifecycle' for domain 'x': Stopped Shutdown"
                if (line.indexOf("event '") === -1) return;
                root.refresh();
                if (root.detailOf !== "") root.loadDetail(root.detailOf);
            }
        }
    }

    // ---- procesos ------------------------------------------------------------
    //  NINGUNO lleva running:true. Todos los arranca una función de arriba.

    Process {
        id: prober
        command: ["bash", "-c", root.sh +
            "echo '@@VMS'; " +
            "$V list --all --name 2>/dev/null | while read -r n; do [ -z \"$n\" ] && continue; " +
              "i=$($V dominfo \"$n\" 2>/dev/null); " +
              "printf '%s\\t%s\\t%s\\t%s\\t%s\\t%s\\t%s\\n' \"$n\" " +
                "\"$(printf '%s' \"$i\" | sed -n 's/^State: *//p')\" " +
                "\"$(printf '%s' \"$i\" | sed -n 's/^Max memory: *\\([0-9]*\\).*/\\1/p')\" " +
                "\"$(printf '%s' \"$i\" | sed -n 's/^Used memory: *\\([0-9]*\\).*/\\1/p')\" " +
                "\"$(printf '%s' \"$i\" | sed -n 's/^CPU(s): *//p')\" " +
                "\"$(printf '%s' \"$i\" | sed -n 's/^Autostart: *//p')\" " +
                "\"$(printf '%s' \"$i\" | sed -n 's/^UUID: *//p')\"; done; " +
            // Cada red trae ADEMÁS su modo, su subred y si reparte direcciones:
            // sin eso la pestaña solo podía decir el nombre y si estaba viva, y
            // con varias redes propias eso no distingue nada. Es UN net-dumpxml
            // por red (un puñado), la misma forma que el dominfo por VM de
            // arriba, y se lee con sed como el resto de este fichero.
            "echo '@@NETS'; " +
            "$V net-list --all 2>/dev/null | tail -n +3 | while read -r a b c d e; do " +
              "[ -z \"$a\" ] && continue; " +
              "x=$($V net-dumpxml \"$a\" 2>/dev/null); " +
              "fw=$(printf '%s' \"$x\" | sed -n \"s/.*<forward[^>]*mode='\\([a-z]*\\)'.*/\\1/p\" | head -1); " +
              "ipa=$(printf '%s' \"$x\" | sed -n \"s/.*<ip address='\\([0-9.]*\\)'.*/\\1/p\" | head -1); " +
              "msk=$(printf '%s' \"$x\" | sed -n \"s/.*<ip[^>]*netmask='\\([0-9.]*\\)'.*/\\1/p\" | head -1); " +
              "dh=no; printf '%s' \"$x\" | grep -q '<range ' && dh=yes; " +
              "br=$(printf '%s' \"$x\" | sed -n \"s/.*<bridge name='\\([^']*\\)'.*/\\1/p\" | head -1); " +
              "printf '%s\\t%s\\t%s\\t%s\\t%s\\t%s\\t%s\\t%s\\t%s\\n' " +
                "\"$a\" \"$b\" \"$c\" \"$d\" \"$fw\" \"$ipa\" \"$msk\" \"$dh\" \"$br\"; done; " +
            // Adaptadores de las VMs ENCENDIDAS (vnetN, tipo, red/puente, MAC):
            // un `domiflist` por VM viva, las apagadas no cuestan nada.
            "echo '@@IFS'; " +
            "$V list --name 2>/dev/null | while read -r n; do [ -z \"$n\" ] && continue; " +
              "$V domiflist \"$n\" 2>/dev/null | awk -v d=\"$n\" " +
              "'NR>2 && NF>=5 {print d \"\\t\" $1 \"\\t\" $2 \"\\t\" $3 \"\\t\" $5}'; done; " +
            "echo '@@POOL'; $V pool-info default 2>/dev/null | sed -n 's/^State: *//p'"]
        stdout: StdioCollector {
            onStreamFinished: {
                try { root.parseState(this.text); }
                catch (e) { console.warn("[Vm] parse failed:", e); }
                root.primed = true;
                root.refreshed();
            }
        }
        onExited: if (root._refreshQueued) { root._refreshQueued = false; root.refresh(); }
    }

    function parseState(text) {
        var sec = "", vms = [], nets = [], ifs = [], pool = "";
        var lines = text.split("\n");
        for (var i = 0; i < lines.length; i++) {
            var l = lines[i];
            if (l === "@@VMS" || l === "@@NETS" || l === "@@IFS" || l === "@@POOL") { sec = l; continue; }
            if (l.trim() === "") continue;
            var f = l.split("\t");
            if (sec === "@@VMS" && f.length >= 7) {
                vms.push({
                    name: f[0], state: f[1],
                    maxMemKib: parseInt(f[2], 10) || 0,
                    curMemKib: parseInt(f[3], 10) || 0,
                    vcpus: parseInt(f[4], 10) || 0,
                    autostart: f[5] === "enable",
                    uuid: f[6]
                });
            } else if (sec === "@@NETS" && f.length >= 4) {
                var fw = f[4] || "", ipa = f[5] || "";
                //  Cómo se nombra lo que libvirt NO nombra: sin <forward> hay
                //  dos casos muy distintos y hay que separarlos por el <ip>.
                //  Con IP el anfitrión está en la red (host-only); sin IP no
                //  está nadie más que las VMs (internal).
                var mode = fw !== "" ? fw : (ipa !== "" ? "hostonly" : "internal");
                nets.push({ name: f[0], state: f[1], autostart: f[2] === "yes",
                            persistent: f[3] === "yes", mode: mode,
                            ip: ipa, netmask: f[6] || "", dhcp: (f[7] || "") === "yes",
                            bridge: f[8] || "" });
            } else if (sec === "@@IFS" && f.length >= 5) {
                ifs.push({ vm: f[0], tap: f[1], type: f[2], source: f[3], mac: f[4] });
            } else if (sec === "@@POOL") {
                pool = l.trim();
            }
        }
        vms.sort(function(a, b) { return a.name < b.name ? -1 : (a.name > b.name ? 1 : 0); });
        root.vms = vms;
        root.networks = nets;
        root.liveNics = ifs;
        root.poolState = pool;
    }

    Process {
        id: actor
        // Progreso: se lee LÍNEA A LÍNEA según sale, no al final. Las órdenes
        // que no informan de nada no escriben ninguna @@ y esto no hace nada.
        stdout: SplitParser { onRead: function(line) { root._progLine(line); } }
        stderr: StdioCollector {
            onStreamFinished: {
                var t = this.text.trim();
                if (t === "") return;
                // El marcador lo pone cfgLive() cuando SOLO falló la mitad viva.
                if (t.indexOf("@@LIVEFAIL") !== -1) {
                    root.lastNote = "";      // lo rellena onExited con el texto traducido
                    root.lastError = t.replace(/@@LIVEFAIL/g, "").trim();
                    root._liveFailed = true;
                    if (root.lastError === "") root.lastError = "";
                } else {
                    // Los @@WARN del ayudante de OVA son avisos de FIDELIDAD
                    // (lo que el formato no traslada), no fallos: van al aviso
                    // ámbar, igual que en la importación. Antes caían todos en
                    // el mismo saco y una exportación correcta se anunciaba en
                    // rojo como si hubiera reventado.
                    var warns = [], errs = [], ls = t.split("\n");
                    for (var i = 0; i < ls.length; i++) {
                        if (ls[i].indexOf("@@WARN ") === 0) warns.push(ls[i].slice(7));
                        else if (ls[i].trim() !== "") errs.push(ls[i]);
                    }
                    //  Una línea por aviso. "clave\tdetalle": la clave es una
                    //  frase fija en inglés (la traduce noteText) y el detalle,
                    //  lo concreto (VM, MAC, puente) que no se traduce.
                    if (warns.length > 0) root.lastNote = warns.join("\n");
                    if (errs.length > 0) root.lastError = root.humanizeError(errs.join("\n"));
                }
            }
        }
        onExited: function(code) {
            root.busy = false;
            root._clearProgress();
            // Estado final EXPLÍCITO para las operaciones largas: si tardan
            // minutos, "ha desaparecido la barra" no es una respuesta.
            if (code === 0 && root.lastAction === "ova-export")
                root.lastSuccess = I18n.t("Exported to") + " " + root._ovaOut;
            else if (code === 0 && root.lastAction === "ova-define")
                root.lastSuccess = I18n.t("Imported as") + " " + root._ovaName;
            else if (code !== 0 && (root.lastAction === "ova-export" || root.lastAction === "ova-define")
                     && root.lastError === "")
                root.lastError = I18n.t("The operation failed and nothing was written.");
            if (root._liveFailed) {
                root._liveFailed = false;
                root.lastError = "";
                root.lastNote = root.liveFailNote;
            }
            // Arrancar abre la pantalla, como VirtualBox. Se hace AQUÍ, al
            // terminar la orden (que ya ha esperado a que el dominio publique
            // su display), no al pulsar: lanzarlo antes abría un visor que se
            // cerraba solo.
            if (code === 0 && root.lastAction === "start" && (root.openOnStart || root._startedDgpu))
                root.openViewer(root._startedName, root._startedDgpu);
            root.actionDone(root.lastAction, code === 0);
            // Releer SIEMPRE tras una acción: es el mecanismo por el que la
            // pastilla de barra aparece/desaparece sin ningún temporizador.
            root.refresh();
            if (root.snapshotsOf !== "") root.snapshots_(root.snapshotsOf);
            // El hardware también puede haber cambiado (disco, NIC, CD, USB…):
            // se relee POR EVENTO al terminar la acción, nunca con temporizador.
            if (root.detailOf !== "") root.loadDetail(root.detailOf);
        }
    }

    Process {
        id: snapLister
        stdout: StdioCollector {
            onStreamFinished: {
                var out = [], ls = this.text.split("\n");
                for (var i = 0; i < ls.length; i++) {
                    if (ls[i].trim() === "") continue;
                    var f = ls[i].split("\t");
                    out.push({ name: f[0], created: f[1] || "", state: f[2] || "" });
                }
                root.snapshots = out;
            }
        }
    }

    Process {
        id: detailer
        stdout: StdioCollector {
            onStreamFinished: {
                try { root.parseDetail(this.text); }
                catch (e) { console.warn("[Vm] detail parse failed:", e); }
            }
        }
    }

    function parseDetail(text) {
        var d = { disks: [], nics: [], ctrls: [], video: null, cpu: null, boot: [],
                  chans: [], fs: [], usbdevs: [], graphics: null, redir: 0,
                  desc: "", title: "", firmware: "bios", sound: "", tpm: null };
        var sizes = {};
        var lines = text.split("\n");
        for (var i = 0; i < lines.length; i++) {
            if (lines[i].trim() === "") continue;
            var f = lines[i].split("\t");
            switch (f[0]) {
            case "@@DISK":
                d.disks.push({ target: f[1], bus: f[2], device: f[3], path: f[4],
                               format: f[5], readonly: f[6] === "ro", capacity: 0 });
                break;
            case "@@DISKSZ": sizes[f[1]] = parseInt(f[2], 10) || 0; break;
            case "@@NIC":
                d.nics.push({ mac: f[1], type: f[2], source: f[3], model: f[4], link: f[5] });
                break;
            case "@@CTRL":  d.ctrls.push({ type: f[1], index: f[2], model: f[3] }); break;
            case "@@VIDEO": d.video = { model: f[1], vram: parseInt(f[2], 10) || 0, heads: f[3] }; break;
            case "@@CPU":   d.cpu = { sockets: f[1], cores: f[2], threads: f[3], mode: f[4] }; break;
            case "@@BOOT":  d.boot.push(f[1]); break;
            case "@@FIRMWARE": d.firmware = f[1] === "efi" ? "uefi" : "bios"; break;
            case "@@CHAN":  d.chans.push({ name: f[1], type: f[2] }); break;
            case "@@FS":    d.fs.push({ tag: f[1], source: f[2], driver: f[3], mode: f[4] }); break;
            case "@@USBDEV": d.usbdevs.push({ vendor: f[1], product: f[2] }); break;
            case "@@GRAPHICS": d.graphics = { type: f[1], clipboard: f[2] }; break;
            case "@@TPM":   d.tpm = { model: f[1], backend: f[2], version: f[3] }; break;
            case "@@SOUND": d.sound = f[1] || ""; break;
            case "@@REDIR": d.redir = parseInt(f[1], 10) || 0; break;
            case "@@DESC":  d.desc = f[1] || ""; break;
            case "@@TITLE": d.title = f[1] || ""; break;
            }
        }
        for (var k = 0; k < d.disks.length; k++)
            if (sizes[d.disks[k].target] !== undefined) d.disks[k].capacity = sizes[d.disks[k].target];
        root.detail = d;
    }

    // Inventario USB del anfitrión leyendo /sys — sin `lsusb` (usbutils no está
    // instalado y no se añade como dependencia). Se saltan los hubs (clase 09).
    Process {
        id: usbLister
        command: ["bash", "-c",
            "for dd in /sys/bus/usb/devices/*/; do " +
              "[ -f \"$dd/idVendor\" ] || continue; " +
              "cls=$(cat \"$dd/bDeviceClass\" 2>/dev/null); " +
              "[ \"$cls\" = \"09\" ] && continue; " +
              "v=$(cat \"$dd/idVendor\"); p=$(cat \"$dd/idProduct\"); " +
              "man=$(cat \"$dd/manufacturer\" 2>/dev/null); pr=$(cat \"$dd/product\" 2>/dev/null); " +
              "printf '%s\\t%s\\t%s\\n' \"$v\" \"$p\" \"$(echo $man $pr)\"; " +
            "done 2>/dev/null | sort -u"]
        stdout: StdioCollector {
            onStreamFinished: {
                var out = [], ls = this.text.split("\n");
                for (var i = 0; i < ls.length; i++) {
                    if (ls[i].trim() === "") continue;
                    var f = ls[i].split("\t");
                    if (f.length < 2) continue;
                    var label = (f[2] || "").trim();
                    out.push({ vendor: "0x" + f[0], product: "0x" + f[1],
                               label: label !== "" ? label : (f[0] + ":" + f[1]) });
                }
                root.hostUsb = out;
            }
        }
    }

    Process {
        id: ovaImporter
        stderr: StdioCollector {
            onStreamFinished: {
                var t = this.text.trim();
                if (t === "") return;
                // Los @@WARN del ayudante son avisos de fidelidad, no fallos.
                var warns = [], errs = [], ls = t.split("\n");
                for (var i = 0; i < ls.length; i++) {
                    if (ls[i].indexOf("@@WARN ") === 0) warns.push(ls[i].slice(7));
                    else if (ls[i].trim() !== "") errs.push(ls[i]);
                }
                if (warns.length > 0) root.lastNote = warns.join("\n");   // ver noteText
                if (errs.length > 0) root.lastError = errs.join("\n");
            }
        }
        // Aquí NO vale un StdioCollector: guarda todo y lo entrega al acabar,
        // que es justo cuando el progreso ya no le sirve a nadie. Con el
        // SplitParser las líneas de progreso se ven al vuelo y los datos del
        // OVF se van apuntando según llegan (salen al final, antes del EOF).
        stdout: SplitParser {
            onRead: function(line) {
                if (root._progLine(line)) return;
                var f = line.split("\t");
                if (f[0] === "mem")   root._ovaFacts.mem = parseInt(f[1], 10) || 1024;
                if (f[0] === "vcpus") root._ovaFacts.cpu = parseInt(f[1], 10) || 2;
                if (f[0] === "disk")  root._ovaFacts.disk = f[1];
                if (f[0] === "bus")      root._ovaFacts.bus = f[1] || "";
                if (f[0] === "firmware") root._ovaFacts.firmware = f[1] || "";
                if (f[0] === "@@TMP") root._ovaFacts.tmp = f[1];
            }
        }
        onExited: function(code) {
            root.busy = false;
            if (code !== 0) {
                root._clearProgress();
                if (root.lastError === "")
                    root.lastError = I18n.t("The operation failed and nothing was written.");
                root.actionDone("ova-import", false);
                return;
            }
            var f = root._ovaFacts;
            if (!f || f.disk === "") {
                root._clearProgress();
                root.lastError = I18n.t("The .ova could not be read.");
                root.actionDone("ova-import", false);
                return;
            }
            // La elección del usuario manda sobre lo que diga el .ova; "auto"
            // (lo de fábrica) es "haz lo que diga el .ova".
            root._ovaBus = (root._ovaBusWanted !== "" && root._ovaBusWanted !== "auto")
                           ? root._ovaBusWanted : (f.bus || "sata");
            root._ovaFirmware = f.firmware || "bios";
            root._finishOvaImport(f.mem, f.cpu, f.disk, f.tmp);
        }
    }
    property var _ovaFacts: ({ mem: 1024, cpu: 2, disk: "", tmp: "", bus: "", firmware: "" })
    property string _ovaBusWanted: ""

    Process {
        id: bridgeLister
        command: ["bash", "-c",
            "for n in /sys/class/net/*/; do [ -d \"$n/bridge\" ] && basename \"$n\"; done 2>/dev/null | sort"]
        stdout: StdioCollector {
            onStreamFinished: {
                var out = [], ls = this.text.split("\n");
                for (var i = 0; i < ls.length; i++)
                    if (ls[i].trim() !== "") out.push(ls[i].trim());
                root.hostBridges = out;
            }
        }
    }

    // Diagnóstico de redes: solo cuando se pulsa el botón (diagnoseNetworks).
    Process {
        id: netDiagProc
        command: ["bash", "-c", root.sh + root._diagScript]
        stdout: StdioCollector {
            onStreamFinished: {
                try { root.netDiag = root._diagAnalyze(this.text); }
                catch (e) { console.warn("[Vm] network diagnosis failed:", e); root.netDiag = []; }
                root.netDiagRan = true;
            }
        }
    }

    Process {
        id: gpuProbe
        // con bash delante: una subida por la web de GitHub pierde el +x
        command: ["bash", root.gpuBin, "offload"]
        stdout: StdioCollector {
            onStreamFinished: {
                var m = {}, ls = this.text.split("\n");
                for (var i = 0; i < ls.length; i++) {
                    var e = ls[i].indexOf("=");
                    if (e > 0) m[ls[i].slice(0, e)] = ls[i].slice(e + 1).trim();
                }
                var st = (m.state === "on" || m.state === "off") ? m.state : "none";
                root.dgpu = {
                    state: st, name: m.name || "", why: m.why || "", driver: m.driver || "",
                    env: (m.env || "").split(" ").filter(function(x) { return x.indexOf("=") > 0; })
                };
            }
        }
    }

    Process {
        id: detector
        command: ["bash", "-c",
            "export LC_ALL=C; " +
            "h(){ command -v \"$1\" >/dev/null 2>&1 && echo 1 || echo 0; }; " +
            "echo \"virsh=$(h virsh)\"; " +
            "echo \"qemu=$({ command -v qemu-system-x86_64 || command -v qemu-kvm; } >/dev/null 2>&1 && echo 1 || echo 0)\"; " +
            "echo \"viewer=$(h virt-viewer)\"; " +
            "virsh -c " + root.uri + " version >/dev/null 2>&1 && echo libvirtd=1 || echo libvirtd=0; " +
            "g=\" $(id -nG 2>/dev/null) \"; " +
            "case \"$g\" in *' libvirt '*|*' libvirtd '*) echo grpLibvirt=1;; *) echo grpLibvirt=0;; esac; " +
            "case \"$g\" in *' kvm '*) echo grpKvm=1;; *) echo grpKvm=0;; esac; " +
            "{ [ -r /dev/kvm ] && [ -w /dev/kvm ] && echo kvmdev=1; } || echo kvmdev=0; " +
            // swtpm en NixOS NO está en el PATH del usuario aunque
            // qemu.swtpm.enable esté puesto: se lo inyecta systemd SOLO al
            // servicio (medido: la unidad libvirtd lleva swtpm-0.10.1/bin en su
            // Environment=PATH). Preguntar `command -v swtpm` daría "falta" en
            // un sistema BIEN configurado, así que se mira también la unidad.
            // En Arch swtpm sí es un binario normal en /usr/bin y la primera
            // comprobación basta.
            "{ command -v swtpm >/dev/null 2>&1 || " +
              "systemctl show libvirtd.service --property=Environment 2>/dev/null | grep -q swtpm; } " +
              "&& echo swtpm=1 || echo swtpm=0; " +
            // UEFI de verdad: que el hipervisor DECLARE el firmware efi, no que
            // exista un fichero OVMF suelto en alguna ruta adivinada.
            "virsh -c " + root.uri + " domcapabilities 2>/dev/null | grep -q '<value>efi</value>' " +
              "&& echo uefi=1 || echo uefi=0; " +
            // virtiofsd: sin él, una VM con carpeta compartida NO ARRANCA
            // ("Unable to find a satisfying virtiofsd" — medido en la torre).
            // libvirt lo busca por los descriptores vhost-user, no por el PATH:
            // en NixOS /var/lib/qemu/vhost-user (donde enlaza
            // virtualisation.libvirtd.qemu.vhostUserPackages) y en Arch
            // /usr/share/qemu/vhost-user. El `command -v` cubre instalaciones
            // más simples.
            "{ ls /var/lib/qemu/vhost-user/*.json >/dev/null 2>&1 " +
              "|| ls /usr/share/qemu/vhost-user/*.json >/dev/null 2>&1 " +
              "|| command -v virtiofsd >/dev/null 2>&1; } " +
              "&& echo virtiofs=1 || echo virtiofs=0; " +
            ". /etc/os-release 2>/dev/null; " +
            "echo \"os=${ID:-}\"; echo \"oslike=${ID_LIKE:-}\"; echo \"osname=${PRETTY_NAME:-${NAME:-}}\""]
        stdout: StdioCollector {
            onStreamFinished: {
                var m = {}, ls = this.text.split("\n");
                for (var i = 0; i < ls.length; i++) {
                    var e = ls[i].indexOf("=");
                    if (e > 0) m[ls[i].slice(0, e)] = ls[i].slice(e + 1).trim();
                }
                root.has = {
                    virsh: m.virsh === "1", qemu: m.qemu === "1", viewer: m.viewer === "1",
                    libvirtd: m.libvirtd === "1", grpLibvirt: m.grpLibvirt === "1",
                    grpKvm: m.grpKvm === "1", kvmdev: m.kvmdev === "1",
                    swtpm: m.swtpm === "1", uefi: m.uefi === "1",
                    virtiofs: m.virtiofs === "1"
                };
                root.osId = m.os || "";
                root.osLike = m.oslike || "";
                root.osName = m.osname || "";
                root.detected = true;
            }
        }
    }
}
