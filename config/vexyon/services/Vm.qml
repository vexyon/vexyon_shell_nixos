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
        desc: "", title: "", firmware: "bios", sound: ""
    })
    // ¿tiene el canal del agente SPICE? Sin él NO hay portapapeles compartido
    // ni redimensionado automático del invitado, por mucho que el invitado
    // lleve spice-vdagent instalado.
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
    function start(name) {
        root._startedName = name;
        var wait = root.openOnStart
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
    function addNic(name, netName, model) {
        var mkMac = "MAC=$(printf '52:54:00:%02x:%02x:%02x' " +
                    "$((RANDOM%256)) $((RANDOM%256)) $((RANDOM%256))); ";
        var cmd = "$V attach-interface " + q(name) + " network " + q(netName) +
                  " --model " + q(model) + " --mac \"$MAC\"";
        root.run("nic-add", mkMac + root.cfgLive(name, cmd, cmd));
    }
    function removeNic(name, mac) {
        root.run("nic-del",
            root.cfgLive(name,
                "$V detach-interface " + q(name) + " network --mac " + q(mac),
                "$V detach-interface " + q(name) + " network --mac " + q(mac)));
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
    // Cambiar una interfaz YA existente a puente (o de vuelta a red gestionada)
    // no tiene subcomando en virsh: se edita el XML del dominio.
    function setNicBridge(name, mac, br)  { root.run("nic-bridge",  root.editXml(name, "nic-bridge " + q(mac) + " " + q(br))); }
    function setNicNetwork(name, mac, net) { root.run("nic-network", root.editXml(name, "nic-network " + q(mac) + " " + q(net))); }
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
    function exportOva(name, rawPath) {
        var out = root.expandPath(rawPath);
        var src = "";
        for (var i = 0; i < root.detail.disks.length; i++)
            if (root.detail.disks[i].device === "disk") { src = root.detail.disks[i].path; break; }
        if (src === "") { root.lastError = I18n.t("This VM has no hard disk to export."); return; }
        root.run("ova-export",
            "mkdir -p \"$(dirname " + q(out) + ")\" || exit 1; " +
            "T=$(mktemp -d) || exit 1; " +
            "$V vol-download --pool default " + q(root.baseName(src)) + " \"$T/disk.qcow2\" " +
              "|| $V vol-download " + q(src) + " \"$T/disk.qcow2\" || { rm -rf \"$T\"; exit 1; }; " +
            "$V dumpxml --inactive " + q(name) + " > \"$T/dom.xml\" || { rm -rf \"$T\"; exit 1; }; " +
            q(root.ovaBin) + " export \"$T/dom.xml\" \"$T/disk.qcow2\" " + q(out) + " \"$T/build\"; " +
            "rc=$?; rm -rf \"$T\"; exit $rc");
    }

    // Importar va en DOS fases porque hace falta leer lo que dice el OVF antes
    // de poder escribir el XML del dominio:
    //   1) el ayudante extrae, convierte a qcow2 y IMPRIME nombre/RAM/vCPU/disco;
    //   2) con esos datos ya en QML se sube el disco al pool y se define la VM
    //      con el MISMO generador de XML que usa "crear VM".
    property string _ovaName: ""
    function importOva(rawPath, newName) {
        if (!root.enabled) return;
        var ova = root.expandPath(rawPath);
        root._ovaName = newName;
        root.lastError = "";
        root.lastNote = "";
        root.lastAction = "ova-import";
        root.busy = true;
        ovaImporter.command = ["bash", "-c", root.sh +
            root.pathGuard(ova) +
            "T=$(mktemp -d) || exit 1; " +
            q(root.ovaBin) + " import " + q(ova) + " " + q(newName) + " \"$T\" || { rm -rf \"$T\"; exit 1; }; " +
            "echo \"@@TMP\t$T\""];
        ovaImporter.running = true;
    }

    // Segunda fase: subir el disco convertido al pool y definir el dominio.
    function _finishOvaImport(mem, vcpus, disk, tmpDir) {
        root.run("ova-define",
            "$V pool-info default >/dev/null 2>&1 || { " +
              "$V pool-define-as default dir --target /var/lib/libvirt/images >/dev/null 2>&1; " +
              "$V pool-build default >/dev/null 2>&1; $V pool-autostart default >/dev/null 2>&1; }; " +
            "$V pool-start default >/dev/null 2>&1; " +
            "CAP=$(qemu-img info " + q(disk) + " | sed -n 's/^virtual size:.*(\\([0-9]*\\) bytes).*/\\1/p' | head -1); " +
            "[ -z \"$CAP\" ] && CAP=" + q("2147483648") + "; " +
            "$V vol-create-as default " + q(root._ovaName + ".qcow2") + " \"$CAP\" --format qcow2 || { rm -rf " + q(tmpDir) + "; exit 1; }; " +
            "$V vol-upload --pool default " + q(root._ovaName + ".qcow2") + " " + q(disk) + " || { rm -rf " + q(tmpDir) + "; exit 1; }; " +
            "rm -rf " + q(tmpDir) + "; " +
            "t=$(mktemp) || exit 1; cat > \"$t\" <<'VEXYONXML'\n" +
            root.domainXml({ name: root._ovaName, memMib: mem, vcpus: vcpus,
                             iso: "", firmware: "bios", network: "default" },
                           "/var/lib/libvirt/images/" + root._ovaName + ".qcow2") + "\nVEXYONXML\n" +
            "$V define \"$t\"; rc=$?; rm -f \"$t\"; exit $rc");
    }

    // ---- ajustes por XML (todos config-only: piden reinicio) ----------------
    function setBootOrder(name, list) { root.run("boot", root.editXml(name, "boot " + q(list.join(",")))); }
    function setVideo(name, model, vram) { root.run("video", root.editXml(name, "video " + q(model) + " " + q("" + vram) + " 1")); }
    function setCpuTopology(name, sockets, cores, threads) {
        root.run("cpu-topology", root.editXml(name, "cpu " + sockets + " " + cores + " " + threads));
    }
    function setFirmware(name, fw) { root.run("firmware", root.editXml(name, "firmware " + q(fw))); }
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
    function netStart(n)     { root.run("net-start",     "$V net-start " + q(n)); }
    function netStop(n)      { root.run("net-stop",      "$V net-destroy " + q(n)); }
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

    // Genera el XML del dominio. Sin aceleración 3D ni passthrough a propósito
    // (fuera de alcance): qxl + spice, que es lo que virt-viewer sabe abrir y
    // funciona con cualquier escritorio por software.
    function domainXml(o, disk) {
        var uefi = o.firmware === "uefi";
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
        lines.push("    <disk type='file' device='disk'>");
        lines.push("      <driver name='qemu' type='qcow2'/>");
        lines.push("      <source file='" + root.xmlEsc(disk) + "'/>");
        lines.push("      <target dev='vda' bus='virtio'/>");
        lines.push("    </disk>");
        if (o.iso && o.iso !== "") {
            lines.push("    <disk type='file' device='cdrom'>");
            lines.push("      <driver name='qemu' type='raw'/>");
            lines.push("      <source file='" + root.xmlEsc(o.iso) + "'/>");
            lines.push("      <target dev='sda' bus='sata'/>");
            lines.push("      <readonly/>");
            lines.push("    </disk>");
        }
        if (o.network && o.network !== "none") {
            lines.push("    <interface type='network'>");
            lines.push("      <source network='" + root.xmlEsc(o.network) + "'/>");
            lines.push("      <model type='virtio'/>");
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
        lines.push("    <video><model type='qxl' heads='1'/></video>");
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
    //  `--auto-resize=always` es lo que hace que el invitado CAMBIE su
    //  resolución para llenar la ventana en vez de quedarse centrado con
    //  márgenes. Necesita el agente `spice-vdagent` DENTRO del invitado y el
    //  canal `com.redhat.spice.0` en el dominio (Vm.hasSpiceAgent): sin las dos
    //  cosas virt-viewer no puede pedirle nada al invitado. La UI lo dice.
    function openViewer(name) {
        if (!root.enabled || !name) return;
        // Sin virt-viewer, `execDetached` no falla de forma visible: el proceso
        // simplemente no arranca y el usuario ve... nada. Se dice.
        if (root.detected && !root.has.viewer) {
            root.lastError = I18n.t("virt-viewer is not installed, so the VM's display cannot be opened. Use the text console, or install it (see Settings → Virtualization).");
            return;
        }
        var cmd = ["virt-viewer", "-c", root.uri, "-a", "--auto-resize=always"];
        if (root.viewerFullscreen) cmd.push("-f");
        cmd.push(name);
        Quickshell.execDetached(cmd);
    }
    // Pantalla completa limpia por defecto: es la única forma de que
    // virt-viewer no pinte su barra de cabecera encima del invitado.
    readonly property bool viewerFullscreen: Config.get("virtualization", "viewerFullscreen", true) === true

    // Consola de texto en ghostty, para VMs sin escritorio gráfico.
    function openConsole(name) {
        if (!root.enabled) return;
        Quickshell.execDetached(["ghostty", "-e", "virsh", "-c", root.uri, "console", name]);
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
            "echo '@@NETS'; " +
            "$V net-list --all 2>/dev/null | tail -n +3 | while read -r a b c d e; do " +
              "[ -z \"$a\" ] && continue; printf '%s\\t%s\\t%s\\t%s\\n' \"$a\" \"$b\" \"$c\" \"$d\"; done; " +
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
        var sec = "", vms = [], nets = [], pool = "";
        var lines = text.split("\n");
        for (var i = 0; i < lines.length; i++) {
            var l = lines[i];
            if (l === "@@VMS" || l === "@@NETS" || l === "@@POOL") { sec = l; continue; }
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
                nets.push({ name: f[0], state: f[1], autostart: f[2] === "yes", persistent: f[3] === "yes" });
            } else if (sec === "@@POOL") {
                pool = l.trim();
            }
        }
        vms.sort(function(a, b) { return a.name < b.name ? -1 : (a.name > b.name ? 1 : 0); });
        root.vms = vms;
        root.networks = nets;
        root.poolState = pool;
    }

    Process {
        id: actor
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
                    root.lastError = root.humanizeError(t);
                }
            }
        }
        onExited: function(code) {
            root.busy = false;
            if (root._liveFailed) {
                root._liveFailed = false;
                root.lastError = "";
                root.lastNote = root.liveFailNote;
            }
            // Arrancar abre la pantalla, como VirtualBox. Se hace AQUÍ, al
            // terminar la orden (que ya ha esperado a que el dominio publique
            // su display), no al pulsar: lanzarlo antes abría un visor que se
            // cerraba solo.
            if (code === 0 && root.lastAction === "start" && root.openOnStart)
                root.openViewer(root._startedName);
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
                  desc: "", title: "", firmware: "bios", sound: "" };
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
                if (warns.length > 0) root.lastNote = warns.join(" ");
                if (errs.length > 0) root.lastError = errs.join("\n");
            }
        }
        stdout: StdioCollector {
            onStreamFinished: {
                var mem = 1024, cpu = 2, disk = "", tmp = "";
                var ls = this.text.split("\n");
                for (var i = 0; i < ls.length; i++) {
                    var f = ls[i].split("\t");
                    if (f[0] === "mem")   mem = parseInt(f[1], 10) || 1024;
                    if (f[0] === "vcpus") cpu = parseInt(f[1], 10) || 2;
                    if (f[0] === "disk")  disk = f[1];
                    if (f[0] === "@@TMP") tmp = f[1];
                }
                root._ovaFacts = { mem: mem, cpu: cpu, disk: disk, tmp: tmp };
            }
        }
        onExited: function(code) {
            root.busy = false;
            if (code !== 0) {
                root.actionDone("ova-import", false);
                return;
            }
            var f = root._ovaFacts;
            if (!f || f.disk === "") {
                root.lastError = I18n.t("The .ova could not be read.");
                root.actionDone("ova-import", false);
                return;
            }
            root._finishOvaImport(f.mem, f.cpu, f.disk, f.tmp);
        }
    }
    property var _ovaFacts: null

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
