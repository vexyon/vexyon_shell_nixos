import QtQuick
import QtQuick.Layouts
import QtQuick.Controls
import Quickshell
import Quickshell.Io
import qs.services
import qs.components

// ============================================================================
//  Vexyon File Manager — Super+E. Nautilus-like: places sidebar + list/grid
//  view, breadcrumb nav, open (xdg-open), native trash (gio) con restaurar/
//  vaciar, ZIP compress/extract, multi-selección (marquee + Ctrl/Shift),
//  drag-and-drop para mover, cortar/copiar/pegar (portapapeles del SISTEMA,
//  entre ventanas y programas: FileClipboard), renombrar, marcadores en la
//  barra lateral (Places) e iconos de carpeta (FolderIcons).
//  A real toplevel window (not an overlay).
// ============================================================================
FloatingWindow {
    id: fm
    // Instancia dinámica: shell.qml crea una NUEVA por cada Super+E
    // (fmFactory.createObject). Nace visible y se autodestruye al cerrarse.
    visible: true
    title: fm.picking ? (fm.pickTitle !== "" ? I18n.t(fm.pickTitle) : I18n.t("Choose a file")) : "Vexyon Files"
    implicitWidth: 920
    implicitHeight: 600
    color: Theme.base

    readonly property string home: Quickshell.env("HOME")
    property string cwd: home
    property var entries: []
    // Grid es la vista por defecto en cada arranque; el toggle solo dura la
    // sesión (decisión S60: la persistencia en shell.json no sobrevivía).
    property bool gridMode: true
    property bool showHidden: false
    property var backStack: []
    property var fwdStack: []
    // Zoom de la cuadrícula (Ctrl+rueda, como Nautilus). Solo grid: la lista
    // tiene fila fija de 40px (itemRect la hardcodea).
    property real zoom: 1.0

    // ---- selección múltiple (map path -> true) -----------------------------
    property var selection: ({})
    property int selCount: 0
    property int anchorIndex: -1
    function isSelected(p) { return fm.selection[p] === true; }
    function clearSelection() { fm.selection = ({}); fm.selCount = 0; }
    function setSelectionPaths(paths) {
        var m = {};
        for (var i = 0; i < paths.length; i++) m[paths[i]] = true;
        fm.selection = m; fm.selCount = paths.length;
    }
    function toggleSelect(p) {
        var m = Object.assign({}, fm.selection);
        if (m[p]) delete m[p]; else m[p] = true;
        fm.selection = m; fm.selCount = Object.keys(m).length;
    }
    function selectRange(a, b) {
        var lo = Math.max(0, Math.min(a, b)), hi = Math.min(fm.entries.length - 1, Math.max(a, b));
        var paths = [];
        for (var i = lo; i <= hi; i++) paths.push(fm.entries[i].path);
        fm.setSelectionPaths(paths);
    }
    function selectAll() {
        var paths = [];
        for (var i = 0; i < fm.entries.length; i++) paths.push(fm.entries[i].path);
        fm.setSelectionPaths(paths);
    }
    // en orden de vista (para operar sobre la selección)
    function selectedList() {
        var out = [];
        for (var i = 0; i < fm.entries.length; i++)
            if (fm.selection[fm.entries[i].path]) out.push(fm.entries[i].path);
        return out;
    }

    // ---- papelera ----------------------------------------------------------
    //  "Papelera" es la de TODAS las unidades montadas, como en Nautilus: lo que
    //  se borra en otro disco va, por la especificación freedesktop, a la
    //  papelera de ese disco ($montaje/.Trash-UID o $montaje/.Trash/UID), y la
    //  vista de la papelera (trashDir) lista todas juntas. Restaurar, borrar y
    //  vaciar funcionan en cada una. En un disco EXTERNO (USB) no se usa
    //  papelera: se pregunta y se borra definitivamente (trashPaths).
    readonly property string trashRoot: home + "/.local/share/Trash"
    readonly property string trashDir: trashRoot + "/files"
    readonly property bool inTrash: cwd === trashDir || cwd.indexOf(trashDir + "/") === 0
                                    || /\/\.Trash(-\d+|\/\d+)\/files(\/|$)/.test(cwd)
    function isTrashFilesDir(d) { return d === fm.trashDir || /\/\.Trash(-\d+|\/\d+)\/files$/.test(d); }
    // bash: `roots` imprime la carpeta files/ de cada papelera existente.
    // /proc/self/mounts escapa los espacios como \040; printf %b los deshace.
    readonly property string trashRootsSh:
        'roots() { { printf "%s\\n" ' + shq(fm.trashDir) + '; uid=$(id -u); ' +
        'while read -r _ m t _; do case "$t" in proc|sysfs|devtmpfs|devpts|tmpfs|cgroup|cgroup2|securityfs|pstore|bpf|' +
        'debugfs|tracefs|mqueue|hugetlbfs|configfs|fusectl|efivarfs|autofs|ramfs|nsfs|overlay|squashfs|binfmt_misc|' +
        'rpc_pipefs) continue;; esac; m=$(printf "%b" "$m"); ' +
        'for d in "$m/.Trash-$uid" "$m/.Trash/$uid"; do [ -d "$d/files" ] && printf "%s\\n" "$d/files"; done; ' +
        'done < /proc/self/mounts; } | sort -u; }; '

    function navigate(path, pushHistory) {
        if (pushHistory === undefined) pushHistory = true;
        if (pushHistory && fm.cwd !== path) { fm.backStack = fm.backStack.concat([fm.cwd]); fm.fwdStack = []; }
        fm.cwd = path;
        fm.clearSelection();
        fm.anchorIndex = -1;
        lister.running = true;
    }
    function goBack() {
        if (fm.backStack.length === 0) return;
        var p = fm.backStack[fm.backStack.length - 1];
        fm.backStack = fm.backStack.slice(0, -1);
        fm.fwdStack = fm.fwdStack.concat([fm.cwd]);
        navigate(p, false);
    }
    function goForward() {
        if (fm.fwdStack.length === 0) return;
        var p = fm.fwdStack[fm.fwdStack.length - 1];
        fm.fwdStack = fm.fwdStack.slice(0, -1);
        fm.backStack = fm.backStack.concat([fm.cwd]);
        navigate(p, false);
    }
    function goUp() {
        if (fm.cwd === fm.trashDir) return;
        var p = fm.cwd.replace(/\/+$/, "");
        var parent = p.substring(0, p.lastIndexOf("/"));
        if (parent === "") parent = "/";
        navigate(fm.isTrashFilesDir(parent) ? fm.trashDir : parent);   // la papelera de otro disco: a la vista común
    }
    function refresh() { lister.running = true; }

    // Acciones del menú contextual. Vive en el ROOT (no en el delegate del
    // menú) para que la acción sobreviva a la destrucción del delegate que
    // la disparó — ver el comentario del onClicked del menú.
    function ctxAction(act, e, sel, side, drv) {
        switch (act) {
        case "open":       fm.open(e); break;
        case "rename":     fm.startRename(); break;
        case "cut":        fm.cutSelected(); break;
        case "copy":       fm.copySelected(); break;
        case "paste":      fm.paste(fm.cwd); break;
        case "pasteinto":  fm.paste(e.path); break;
        case "bookmark":   fm.addToSidebar(sel.length ? sel : [e.path]); break;
        case "bookmarkcwd": fm.addToSidebar([fm.cwd]); break;
        case "unbookmark": Places.remove(e ? e.path : fm.cwd); break;
        case "foldericon": fm.openIconPicker(e ? e.path : fm.cwd); break;
        // barra lateral (quitar un marcador NUNCA toca la carpeta)
        case "sideopen":   fm.navigate(side.path); break;
        case "sideicon":   fm.openIconPicker(side.path); break;
        case "bmup":       Places.move(side.path, side.index - 1); break;
        case "bmdown":     Places.move(side.path, side.index + 1); break;
        case "bmremove":   Places.remove(side.path); break;
        // dispositivos
        case "drvopen":
            if (drv.mount !== "") fm.navigate(drv.mount);
            else Drives.mount(drv.dev, drv.obj, function(mp) { fm.navigate(mp); });
            break;
        case "drvunmount":
            if (Drives.contains(fm.cwd) && Drives.deviceFor(fm.cwd).dev === drv.dev) fm.navigate(fm.home);
            Drives.unmount(drv.dev);
            break;
        case "drvformat":  fm.openFormat(drv.disk, drv.label); break;
        case "extract":    fm.extract(e.path); break;
        case "compress":   fm.compress(e.path); break;
        case "trash":      fm.trashPaths(sel.length ? sel : [e.path]); break;
        case "restore":    fm.restorePaths(sel.length ? sel : [e.path]); break;
        case "delforever": fm.deleteForeverPaths(sel.length ? sel : [e.path]); break;
        case "emptytrash": fm.emptyArmed = true; fm.emptyTrash(); break;
        case "newfolder":  fm.newFolder(); break;
        case "newfile":    fm.newFile(); break;
        case "selectall":  fm.selectAll(); break;
        case "togglehidden": fm.showHidden = !fm.showHidden; fm.refresh(); break;
        case "props":      fm.showProperties(sel.length ? sel : (e ? [e.path] : [])); break;
        }
    }

    function shq(s) { return "'" + String(s).replace(/'/g, "'\\''") + "'"; }
    function basename(p) { return p.substring(p.lastIndexOf("/") + 1); }

    // Runner único de operaciones de fichero: al terminar, refresca la vista
    // (sin carreras de Timer — el refresh llega cuando la operación acabó).
    Process {
        id: opProc
        property var after: null          // callback opcional de runOp, al terminar
        // `after(code, out, err)`: quien lo necesite (crear, borrar) ve cómo
        // acabó; el resto lo ignora.
        onExited: function(code) {
            var f = opProc.after;
            opProc.after = null;
            fm.refresh();
            if (f) f(code, opOut.text, opErr.text);
        }
        stdout: StdioCollector { id: opOut }
        stderr: StdioCollector {
            id: opErr
            onStreamFinished: if (this.text.trim() !== "") console.warn("[FileManager] op:", this.text.trim())
        }
    }
    function fmtBytes(b) {
        if (!b || b <= 0) return "0 B";
        var u = ["B", "KiB", "MiB", "GiB", "TiB"], i = 0, v = b;
        while (v >= 1024 && i < u.length - 1) { v /= 1024; i++; }
        return (i === 0 || v >= 10 ? Math.round(v) : v.toFixed(1)) + " " + u[i];
    }

    function runOp(script, after) {
        opProc.after = after || null;
        opProc.command = ["bash", "-c", script];
        opProc.running = true;
    }

    //  Algo que Vexyon ha renombrado o movido conserva su icono de carpeta y
    //  su marcador. Solo se llama al ayudante si de verdad hay algo que mover.
    function followMove(from, to) {
        FolderIcons.moved(from, to);
        Places.moved(from, to);
    }

    // ======================================================================
    //  TRANSFERENCIAS CON PROGRESO
    // ======================================================================
    //  Antes copiar y mover eran `cp -rn` / `mv -n` por `runOp`, y no había
    //  manera de saber si aquello seguía vivo: coreutils no informa de nada.
    //  Ahora lo hace `vexyon-fm-xfer`, que va diciendo por dónde va.
    //
    //  ⚠️ LAS TRES RUTAS LENTAS SON LA MISMA RUTA. Copiar a un disco externo,
    //  copiar por SFTP y copiar entre particiones se parecen mucho porque, para
    //  quien copia, son lo mismo: una ruta del sistema de ficheros. El SFTP de
    //  este gestor se monta con **sshfs** (ver más abajo), o sea un FUSE, así
    //  que no hay ninguna "ruta de red" aparte a la que haya que dar progreso
    //  por su lado. Un solo mecanismo cubre las tres.
    //
    //  Cada operación es un TRABAJO independiente con su propio proceso y su
    //  propia tarjeta: dos arrastres seguidos se ven y se siguen por separado,
    //  no se pisan.
    readonly property string xferBin: {
        var d = Quickshell.env("VEXYON_BIN_DIR");
        var base = (d && d !== "") ? d : fm.home + "/.config/vexyon/bin";
        return base + "/vexyon-fm-xfer";
    }
    property int _jobSeq: 0
    property var _jobCmd: ({})          // id -> argv (no reactivo: se lee una vez)
    property var _jobInfo: ({})         // id -> { kind, dest, srcs, conflicts[] }
    function jobCmd(id) { return fm._jobCmd[id] || []; }

    ListModel { id: jobModel }

    function _jobRow(id) {
        for (var i = 0; i < jobModel.count; i++)
            if (jobModel.get(i).jobId === id) return i;
        return -1;
    }
    function dismissJob(id) {
        var r = fm._jobRow(id);
        if (r !== -1) jobModel.remove(r);
        delete fm._jobCmd[id];
        delete fm._jobInfo[id];
        delete fm._jobExited[id];
    }

    //  Un aviso suelto en la misma franja que las transferencias (portapapeles
    //  vacío, marcador repetido…). Sin proceso detrás: kind "note".
    function notice(text, isError) {
        if (!text) return;
        var id = ++fm._jobSeq;
        jobModel.append({ jobId: id, kind: "note", destName: "", phase: isError ? "err" : "note",
                          total: 0, done: 0, files: 0, idx: 0, file: "", copied: 0,
                          skipped: 0, errors: 0, conflicts: 0, errMsg: text });
    }

    //  kind = "copy" | "move".  Devuelve false si no había nada que hacer.
    //  keepBoth: lo que ya exista en el destino se copia/mueve con un nombre
    //  nuevo ("foto (copia).jpg") en vez de saltarse. Pegar en la MISMA carpeta
    //  de origen siempre duplica así (lo decide el ayudante).
    function startXfer(kind, paths, destDir, keepBoth) {
        var use = [], self = 0;
        for (var i = 0; i < paths.length; i++) {
            var p = paths[i];
            if (p === destDir || destDir.indexOf(p + "/") === 0) { self++; continue; }   // dentro de sí mismo
            if (kind === "move" && p.substring(0, p.lastIndexOf("/")) === destDir) continue;
            use.push(p);
        }
        if (self > 0) fm.notice(I18n.t("A folder can't be copied or moved into itself."), true);
        if (!use.length) return false;
        var id = ++fm._jobSeq;
        var cmd = [fm.xferBin, kind, "--copy-word", I18n.t("copy")];
        if (keepBoth) cmd.push("--keep-both");
        cmd.push(destDir);
        for (var k = 0; k < use.length; k++) cmd.push(use[k]);
        fm._jobCmd[id] = cmd;
        fm._jobInfo[id] = { kind: kind, dest: destDir, srcs: use, conflicts: [] };
        jobModel.append({ jobId: id, kind: kind, destName: fm.basename(destDir) || "/",
                          phase: "scan", total: 0, done: 0, files: 0, idx: 0,
                          file: "", copied: 0, skipped: 0, errors: 0, conflicts: 0, errMsg: "" });
        return true;
    }
    //  "Conservar ambos" de una tarjeta: lo que se saltó por existir ya, otra
    //  vez, con nombre nuevo.
    function keepBoth(id) {
        var j = fm._jobInfo[id];
        if (!j || !j.conflicts.length) return;
        var kind = j.kind, dest = j.dest, srcs = j.conflicts.slice();
        fm.dismissJob(id);
        fm.startXfer(kind, srcs, dest, true);
    }

    //  Una línea del ayudante. Se leen SEGÚN LLEGAN (SplitParser), no al final:
    //  un StdioCollector guardaría todo hasta que el proceso muriese, que es
    //  justo cuando el progreso ya no le sirve a nadie.
    function _jobLine(id, line) {
        var r = fm._jobRow(id);
        if (r === -1 || line.indexOf("@@") !== 0) return;
        var f = line.split("\t");
        switch (f[0]) {
        case "@@TOTAL":
            jobModel.setProperty(r, "total", parseInt(f[1], 10) || 0);
            jobModel.setProperty(r, "files", parseInt(f[2], 10) || 0);
            jobModel.setProperty(r, "phase", "run");
            break;
        case "@@FILE":
            jobModel.setProperty(r, "idx", parseInt(f[1], 10) || 0);
            jobModel.setProperty(r, "file", f[3] || "");
            break;
        case "@@PROG":
            jobModel.setProperty(r, "done", parseInt(f[1], 10) || 0);
            jobModel.setProperty(r, "total", parseInt(f[2], 10) || 0);
            break;
        case "@@SKIP":
            jobModel.setProperty(r, "skipped", jobModel.get(r).skipped + 1);
            break;
        case "@@CONFLICT":
            if (fm._jobInfo[id]) fm._jobInfo[id].conflicts.push(f[1] || "");
            jobModel.setProperty(r, "conflicts", jobModel.get(r).conflicts + 1);
            break;
        case "@@ERR":
            jobModel.setProperty(r, "errors", jobModel.get(r).errors + 1);
            if (jobModel.get(r).errMsg === "")
                jobModel.setProperty(r, "errMsg", (f[1] || "") + ": "
                    + (f[2] === "@self" ? I18n.t("A folder can't be copied or moved into itself.") : (f[2] || "")));
            break;
        case "@@DONE":
            jobModel.setProperty(r, "copied", parseInt(f[1], 10) || 0);
            break;
        }
    }
    property var _jobExited: ({})
    function _jobExit(id, code) {
        fm._jobExited[id] = true;
        var r = fm._jobRow(id);
        if (r === -1) return;
        var j = jobModel.get(r);
        //  El estado final se dice SIEMPRE, salga bien o mal: la tarjeta no
        //  desaparece sin más ni en un caso ni en el otro.
        if (j.errors > 0 || code > 1)     jobModel.setProperty(r, "phase", "err");
        else if (j.skipped > 0)           jobModel.setProperty(r, "phase", "warn");
        else                              jobModel.setProperty(r, "phase", "ok");
        if (code > 1 && j.errMsg === "")
            jobModel.setProperty(r, "errMsg", I18n.t("The transfer could not be started."));
        // Lo movido se lleva su icono de carpeta y su marcador (el ayudante
        // comprueba que el origen ya no está y el destino sí).
        var info = fm._jobInfo[id];
        if (info && info.kind === "move")
            for (var i = 0; i < info.srcs.length; i++)
                fm.followMove(info.srcs[i], info.dest + "/" + fm.basename(info.srcs[i]));
        fm.refresh();
    }

    //  Un proceso por trabajo. El Instantiator solo crea y destruye al añadir o
    //  quitar filas; actualizar el progreso de una fila NO lo reconstruye.
    Instantiator {
        model: jobModel
        delegate: Process {
            required property int jobId
            command: fm.jobCmd(jobId)
            running: command.length > 0          // los avisos ("note") no tienen proceso
            stdout: SplitParser { onRead: function(line) { fm._jobLine(jobId, line); } }
            stderr: StdioCollector {
                onStreamFinished: {
                    var t = this.text.trim();
                    if (t === "") return;
                    var r = fm._jobRow(jobId);
                    if (r !== -1 && jobModel.get(r).errMsg === "")
                        jobModel.setProperty(r, "errMsg", t.split("\n")[0]);
                }
            }
            onExited: function(code) { fm._jobExit(jobId, code); }
            // Si el ayudante ni arranca (no está, sin permiso de ejecución) no
            // hay `exited`: la tarjeta lo dice en vez de quedarse "calculando".
            onRunningChanged: if (!running) {
                var id = jobId;
                Qt.callLater(function() { fm._jobNoStart(id); });
            }
        }
    }
    function _jobNoStart(id) {
        var r = fm._jobRow(id);
        if (r === -1 || jobModel.get(r).phase !== "scan" || fm._jobExited[id]) return;
        jobModel.setProperty(r, "phase", "err");
        jobModel.setProperty(r, "errMsg", I18n.t("The transfer could not be started."));
    }

    function open(entry) {
        if (entry.isDir) navigate(entry.path);
        else if (fm.picking) {
            // selector: abrir un fichero = elegirlo; al guardar, toma su nombre
            if (fm.pickMode === "save") fm.pickName = entry.name;
            else if (fm.pickMode !== "folder") {
                if (!fm.isSelected(entry.path)) fm.setSelectionPaths([entry.path]);
                fm.acceptPick();
            }
        }
        else if (fm.pickImageFor !== "") {
            // eligiendo la imagen de un icono de carpeta: abrir = usarla
            if (/\.(svg|png)$/i.test(entry.name)) fm.useImage(entry.path);
            else fm.notice(I18n.t("Choose an SVG or PNG image."), false);
        }
        else Quickshell.execDetached(["xdg-open", entry.path]);
    }

    // Enviar a la papelera. SOLO gio trash (nada de fallback a rm: si gio
    // falla, mejor no borrar nada que borrar definitivamente en silencio).
    // Lo que gio no puede llevar a ninguna papelera (un disco sin una en la
    // que se pueda escribir) se ofrece borrar definitivamente, preguntando.
    // Lo que está en un disco externo (USB) no va a la papelera: se pregunta
    // y se borra definitivamente.
    function trashPaths(paths) {
        if (!paths.length) return;
        var ext = [], local = [], drive = "";
        for (var i = 0; i < paths.length; i++) {
            var d = Drives.deviceFor(paths[i]);
            if (d) { ext.push(paths[i]); if (drive === "") drive = d.label; }
            else local.push(paths[i]);
        }
        fm.clearSelection();
        if (local.length) {
            var script = "set --";
            for (var j = 0; j < local.length; j++) script += " " + shq(local[j]);
            script += '; i=0; for p in "$@"; do gio trash -- "$p" 2>/dev/null || echo "@@NOTRASH $i"; i=$((i+1)); done';
            runOp(script, function(code, out) {
                var failed = [], lines = out.split("\n");
                for (var k = 0; k < lines.length; k++) {
                    var m = lines[k].match(/^@@NOTRASH (\d+)$/);
                    if (m && local[+m[1]] !== undefined) failed.push(local[+m[1]]);
                }
                if (failed.length) fm.askDeleteForever(failed, "notrash", "");
            });
        }
        if (ext.length) fm.askDeleteForever(ext, "external", drive);
    }

    // ---- borrar definitivamente, preguntando --------------------------------
    property bool delOpen: false
    property var delPaths: []
    property string delReason: ""       // "external" | "notrash" | "shift"
    property string delDrive: ""
    function askDeleteForever(paths, reason, drive) {
        if (fm.delOpen) { fm.delPaths = fm.delPaths.concat(paths); return; }   // ya preguntando: se suman
        fm.delPaths = paths;
        fm.delReason = reason;
        fm.delDrive = drive;
        fm.delOpen = true;
    }
    function confirmDeleteForever() {
        var script = "";
        for (var i = 0; i < fm.delPaths.length; i++) script += "rm -rf -- " + shq(fm.delPaths[i]) + "; ";
        fm.delOpen = false;
        fm.delPaths = [];
        fm.clearSelection();
        if (script !== "") runOp(script);
    }
    onDelOpenChanged: if (!delOpen) fmKeys.forceActiveFocus()

    // Borrado definitivo desde la vista de papelera: quita files/NOMBRE y su
    // info/NOMBRE.trashinfo, en la papelera de la unidad que sea. Más adentro
    // de un dir trasheado: rm normal.
    function deleteForeverPaths(paths) {
        if (!paths.length) return;
        var script = "";
        for (var i = 0; i < paths.length; i++) {
            var p = paths[i];
            var parent = p.substring(0, p.lastIndexOf("/"));
            script += "rm -rf -- " + shq(p) + "; ";
            if (fm.isTrashFilesDir(parent))
                script += "rm -f -- " + shq(parent.replace(/\/files$/, "") + "/info/" + basename(p) + ".trashinfo") + "; ";
        }
        fm.clearSelection();
        runOp(script);
    }
    // Restaurar: lee Path= del .trashinfo (URL-encoded), lo decodifica y mueve
    // de vuelta sin machacar (sufijo .restaurado-N si el destino ya existe).
    // En la papelera de otro disco Path= es relativo a la raíz de ese disco.
    function restorePaths(paths) {
        if (!paths.length) return;
        var script =
            'restore_one() {\n' +
            '  F="$1"; name="$2"; T="${F%/files}"; info="$T/info/$name.trashinfo"\n' +
            '  [ -f "$info" ] || return 0\n' +
            '  enc="$(grep -m1 \'^Path=\' "$info" | cut -d= -f2-)"\n' +
            '  orig="$(printf \'%b\' "${enc//\\%/\\\\x}")"\n' +
            '  case "$orig" in\n' +
            '    /*) : ;;\n' +
            '    *) case "$T" in\n' +
            '         */.Trash-[0-9]*) orig="${T%/.Trash-*}/$orig" ;;\n' +
            '         */.Trash/[0-9]*) orig="${T%/.Trash/*}/$orig" ;;\n' +
            '         *) orig="/$orig" ;;\n' +
            '       esac ;;\n' +
            '  esac\n' +
            '  mkdir -p "$(dirname "$orig")"\n' +
            '  dest="$orig"; n=1\n' +
            '  while [ -e "$dest" ]; do dest="$orig.restaurado-$n"; n=$((n+1)); done\n' +
            '  mv -- "$F/$name" "$dest" && rm -f -- "$info"\n' +
            '}\n';
        for (var i = 0; i < paths.length; i++) {
            var p = paths[i];
            var parent = p.substring(0, p.lastIndexOf("/"));
            if (!fm.isTrashFilesDir(parent)) continue;                     // solo primer nivel
            script += "restore_one " + shq(parent) + " " + shq(basename(p)) + "\n";
        }
        fm.clearSelection();
        runOp(script);
    }
    // Vaciar papelera con confirmación en dos clicks (el segundo antes de 3s).
    // Vacía las de todas las unidades montadas, como la vista las enseña.
    property bool emptyArmed: false
    Timer { id: emptyArmTimer; interval: 3000; onTriggered: fm.emptyArmed = false }
    function emptyTrash() {
        if (!fm.emptyArmed) { fm.emptyArmed = true; emptyArmTimer.restart(); return; }
        fm.emptyArmed = false;
        fm.clearSelection();
        // NO `gio trash --empty`: el backend trash: de gio necesita gvfsd
        // (falla con "Operation not supported" sin él). Vaciar a mano files/
        // + info/ es el layout estándar de freedesktop y no depende de gvfs.
        runOp(fm.trashRootsSh +
              'roots | while IFS= read -r F; do ' +
              'find "$F" "${F%/files}/info" -mindepth 1 -maxdepth 1 -exec rm -rf -- {} + 2>/dev/null; done; true');
    }

    // Mover (drag-and-drop). Nunca machaca un destino existente: lo salta y lo
    // dice, igual que hacía `mv -n`.
    function movePaths(paths, destDir) {
        fm.clearSelection();
        fm.startXfer("move", paths, destDir);
    }
    // Copiar (Ctrl+drag, como Nautilus). Tampoco machaca nada.
    function copyPaths(paths, destDir) {
        fm.clearSelection();
        fm.startXfer("copy", paths, destDir);
    }

    // ---- cortar / copiar / pegar: portapapeles DEL SISTEMA -----------------
    //  Antes vivía en dos propiedades de ESTA ventana (clipPaths/clipMode): otra
    //  ventana del gestor —u otro programa— veía un portapapeles vacío. Ahora
    //  Ctrl+C/X dejan los ficheros en el portapapeles de Wayland
    //  (FileClipboard → text/uri-list servido por wl-copy) y Ctrl+V lee lo que
    //  haya EN ESE MOMENTO, venga de donde venga. El motor de copia es el mismo
    //  de siempre (vexyon-fm-xfer: progreso, nunca machaca).
    function cutSelected() { var l = selectedList(); if (l.length) FileClipboard.cut(l, fm._clipDone); }
    function copySelected() { var l = selectedList(); if (l.length) FileClipboard.copy(l, fm._clipDone); }
    function _clipDone(ok) { if (!ok) fm.notice(FileClipboard.error, true); }
    function paste(destDir) {
        if (fm.inTrash) return;
        FileClipboard.fetch(function(r) {
            if (!r.paths.length) {
                fm.notice(r.foreign > 0 ? I18n.t("Only local files can be pasted here.")
                                        : I18n.t("There are no files on the clipboard."), false);
                return;
            }
            var cut = r.mode === "cut";
            fm.startXfer(cut ? "move" : "copy", r.paths, destDir);
            // Un "cortar" se pega UNA vez: fuera del portapapeles, que sus
            // ficheros ya no están donde él dice.
            if (cut) FileClipboard.consumed();
            if (r.foreign > 0) fm.notice(I18n.t("Items that are not local files were left out: ") + r.foreign, false);
        });
    }

    // ---- diálogo de nombre: renombrar, carpeta nueva, fichero nuevo -------
    property bool renameOpen: false
    property string nameMode: "rename"   // "rename" | "newfolder" | "newfile"
    property string renamePath: ""       // rename: el elemento; new*: la carpeta donde crear
    property string renameText: ""
    property string nameError: ""
    property string pendingSelect: ""    // seleccionar en cuanto el listado lo traiga
    function openNameDialog(mode, path, text) {
        fm.nameMode = mode;
        fm.renamePath = path;
        fm.renameText = text;
        fm.nameError = "";
        fm.renameOpen = true;
    }
    function startRename() {
        var l = selectedList();
        if (l.length !== 1) return;
        fm.openNameDialog("rename", l[0], basename(l[0]));
    }
    function submitRename() {
        var t = fm.renameText.trim();
        var renaming = fm.nameMode === "rename";
        if (renaming && t === basename(fm.renamePath)) { fm.renameOpen = false; return; }
        if (t === "") { fm.nameError = I18n.t("Type a name."); return; }
        if (t.indexOf("/") !== -1 || t === "." || t === "..") { fm.nameError = I18n.t("A name cannot contain “/” or be “.” or “..”."); return; }
        var dir = renaming ? fm.renamePath.substring(0, fm.renamePath.lastIndexOf("/")) : fm.renamePath;
        if (dir === fm.cwd && fm.cwdNames[t] === true) { fm.nameError = I18n.t("“%1” already exists here.").arg(t); return; }
        var to = (dir === "/" ? "" : dir) + "/" + t;
        fm.renameOpen = false;
        fm.clearSelection();
        if (renaming) {
            var from = fm.renamePath;
            runOp("mv -n -- " + shq(from) + " " + shq(to), function() { fm.followMove(from, to); });
            return;
        }
        // mkdir sin -p y `set -C` (noclobber): si algo apareció con ese nombre
        // entretanto, falla en vez de pisarlo.
        var script = fm.nameMode === "newfolder" ? "mkdir -- " + shq(to) : "set -C; : > " + shq(to);
        fm.pendingSelect = to;
        runOp(script, function(code, out, err) {
            if (code !== 0) {
                fm.pendingSelect = "";
                fm.notice(I18n.t("Could not create “%1”: %2").arg(t).arg(err.trim().split("\n").pop() || code), true);
            }
        });
    }
    onRenameOpenChanged: if (!renameOpen) fmKeys.forceActiveFocus()

    // ---- propiedades (como el diálogo Properties de Nautilus, versión mínima) ----
    property bool propOpen: false
    property var propRows: []      // [{ k, v }]
    property string propTitle: ""
    function showProperties(paths) {
        if (!paths.length) paths = [fm.cwd];
        propProc.pendingPaths = paths;
        var script;
        if (paths.length === 1)
            script = "stat -c '%A|%.19y' -- " + shq(paths[0]) + "; du -sh -- " + shq(paths[0]) + " 2>/dev/null | cut -f1";
        else {
            script = "du -shc --";
            for (var i = 0; i < paths.length; i++) script += " " + shq(paths[i]);
            script += " 2>/dev/null | tail -1 | cut -f1";
        }
        propProc.command = ["bash", "-c", script];
        propProc.running = true;
    }
    Process {
        id: propProc
        property var pendingPaths: []
        stdout: StdioCollector {
            onStreamFinished: {
                var lines = this.text.split("\n");
                var ps = propProc.pendingPaths;
                var rows = [];
                if (ps.length === 1) {
                    var p = ps[0];
                    var isDir = false;
                    if (p === fm.cwd) isDir = true;
                    else for (var i = 0; i < fm.entries.length; i++)
                        if (fm.entries[i].path === p) { isDir = fm.entries[i].isDir; break; }
                    var st = (lines[0] || "").split("|");
                    fm.propTitle = fm.basename(p) || "/";
                    rows.push({ k: I18n.t("Type"), v: isDir ? I18n.t("Folder") : I18n.t("File") });
                    rows.push({ k: I18n.t("Size"), v: lines[1] || "—" });
                    rows.push({ k: I18n.t("Modified"), v: st[1] || "—" });
                    rows.push({ k: I18n.t("Permissions"), v: st[0] || "—" });
                    rows.push({ k: I18n.t("Location"), v: p.substring(0, p.lastIndexOf("/")) || "/" });
                } else {
                    fm.propTitle = ps.length + I18n.t(" items");
                    rows.push({ k: I18n.t("Size"), v: lines[0] || "—" });
                    rows.push({ k: I18n.t("Location"), v: fm.cwd });
                }
                fm.propRows = rows;
                fm.propOpen = true;
            }
        }
    }
    onPropOpenChanged: if (!propOpen) fmKeys.forceActiveFocus()

    function compress(path) {
        var name = basename(path);
        runOp("cd " + shq(fm.cwd) + " && zip -r " + shq(name + ".zip") + " " + shq(name));
    }
    function extract(path) {
        runOp("cd " + shq(fm.cwd) + " && unzip -o " + shq(path) + " -d " + shq(path.replace(/\.zip$/i, "")));
    }
    // Crear carpeta / fichero: primero se pide el nombre (el mismo diálogo de
    // renombrar), con uno libre propuesto y seleccionado. Nada se crea con un
    // nombre por defecto que luego haya que ir a buscar.
    function freeName(base, ext) {
        var n = base + ext, i = 2;
        while (fm.cwdNames[n] === true) { n = base + " " + i + ext; i++; }
        return n;
    }
    function newFolder() {
        if (fm.inTrash) return;
        fm.openNameDialog("newfolder", fm.cwd, fm.freeName(I18n.t("New folder"), ""));
    }
    function newFile() {
        if (fm.inTrash) return;
        fm.openNameDialog("newfile", fm.cwd, fm.freeName(I18n.t("New document"), ".txt"));
    }

    //  %D:%i (dispositivo:inodo) de cada carpeta: si alguien la renombró o
    //  movió FUERA de Vexyon, su icono personalizado la reconoce igual
    //  (FolderIcons.adopt). Sale del mismo `find`, sin coste extra.
    Process {
        id: lister
        // En la vista de la papelera: las de todas las unidades, con la carpeta
        // real de cada elemento como 4.º campo.
        command: ["bash", "-c", fm.cwd === fm.trashDir
            ? fm.trashRootsSh + "roots | while IFS= read -r r; do find \"$r\" -maxdepth 1 -mindepth 1 -printf '%y\\t%D:%i\\t%f\\t%h\\n'; done 2>/dev/null | sort -t$'\\t' -k1,1 -k3,3f"
            : "find " + fm.shq(fm.cwd) + " -maxdepth 1 -mindepth 1 -printf '%y\\t%D:%i\\t%f\\n' 2>/dev/null | sort -t$'\\t' -k1,1 -k3,3f"]
        stdout: StdioCollector {
            onStreamFinished: {
                var out = [], names = {};
                var lines = this.text.split("\n");
                var base = fm.cwd === "/" ? "" : fm.cwd;
                for (var i = 0; i < lines.length; i++) {
                    var l = lines[i];
                    if (l.trim() === "") continue;
                    var tab = l.indexOf("\t");
                    var tab2 = tab < 0 ? -1 : l.indexOf("\t", tab + 1);
                    if (tab2 < 0) continue;
                    var type = l.substring(0, tab);
                    var name = l.substring(tab2 + 1), dir = base;
                    if (fm.cwd === fm.trashDir) {                       // papelera común: 4.º campo = carpeta
                        var tab3 = l.indexOf("\t", tab2 + 1);
                        if (tab3 > 0) { name = l.substring(tab2 + 1, tab3); dir = l.substring(tab3 + 1); }
                    }
                    names[name] = true;
                    if (name.charAt(0) === "." && !fm.showHidden) continue; // hide dotfiles
                    var isDir = (type === "d");
                    if (!fm.pickShows(name, isDir)) continue;            // selector: filtro / solo carpetas
                    out.push({ name: name, isDir: isDir, path: dir + "/" + name,
                               id: isDir ? l.substring(tab + 1, tab2) : "" });
                }
                fm.entries = out;
                fm.cwdNames = names;
                FolderIcons.adopt(out);
                if (fm.pendingSelect !== "") {
                    for (var k = 0; k < out.length; k++) {
                        if (out[k].path !== fm.pendingSelect) continue;
                        fm.setSelectionPaths([out[k].path]);
                        fm.anchorIndex = k;
                        listView.positionViewAtIndex(k, ListView.Contain);
                        gridView.positionViewAtIndex(k, GridView.Contain);
                        break;
                    }
                    fm.pendingSelect = "";
                }
            }
        }
    }

    //  Lugares, iconos y portapapeles se leen al abrir cada ventana (y tras
    //  cada cambio hecho desde Vexyon): lo que otro programa cambie aparece en
    //  la siguiente ventana. Ni vigilantes ni sondeos.
    Component.onCompleted: {
        refresh(); refreshVolumes(); Drives.ref(); fmKeys.forceActiveFocus();
        Places.refresh(); FolderIcons.refresh(); FileClipboard.probe();
    }
    // El monitor de udisks2 vive mientras haya gestores abiertos (refcount).
    Component.onDestruction: Drives.unref()

    // Extracción segura: si el dispositivo que estábamos navegando se ha
    // desmontado o desenchufado, volvemos a casa en vez de quedarnos en una
    // ruta muerta. Se dispara por evento, al recalcularse la lista.
    Connections {
        target: Drives
        function onChanged() {
            var inMedia = fm.cwd.indexOf("/run/media/") === 0 || fm.cwd.indexOf("/media/") === 0;
            if (inMedia && !Drives.contains(fm.cwd)) fm.navigate(fm.home);
            refreshVolumes();
        }
    }
    onVisibleChanged: {
        if (visible) { refresh(); refreshVolumes(); fmKeys.forceActiveFocus(); }
        // Cierre (Super+Q/killactive o botón de la ventana): Qt pone
        // visible=false — la instancia dinámica se autodestruye. destroy()
        // difiere el borrado real, así que es seguro desde este handler.
        // Cerrar un selector sin elegir = cancelar (quien espera, lo sabe).
        else {
            if (fm.picking && !fm.pickDone) { fm.pickDone = true; FilePicker.reply(fm.pickId, null); }
            fm.destroy();
        }
    }

    // Theme-driven, per-type Nerd Font glyphs. Monochrome glyphs tinted from the
    // active palette so the whole file manager reads as one themed surface and
    // shifts colour with the rest of the shell (no fixed Papirus stock colours).
    function extOf(entry) {
        var dot = entry.name.lastIndexOf(".");
        return dot > 0 ? entry.name.substring(dot + 1).toLowerCase() : "";
    }
    function mimeGlyph(entry) {
        if (entry.isDir) return Icons.folder;
        var e = fm.extOf(entry);
        if (["png","jpg","jpeg","gif","webp","bmp","svg","ico"].indexOf(e) !== -1) return Icons.image;
        if (["mp4","mkv","webm","mov","avi","flv"].indexOf(e) !== -1) return Icons.video;
        if (["mp3","flac","wav","ogg","m4a","opus"].indexOf(e) !== -1) return Icons.music;
        if (["zip","tar","gz","xz","bz2","7z","rar"].indexOf(e) !== -1) return Icons.archive;
        if (["txt","md","pdf","doc","docx","odt","rtf"].indexOf(e) !== -1) return Icons.documents;
        return Icons.file;
    }
    function mimeColor(entry) {
        if (entry.isDir) return Theme.accent;
        var e = fm.extOf(entry);
        if (["png","jpg","jpeg","gif","webp","bmp","svg","ico"].indexOf(e) !== -1) return Theme.blue;
        if (["mp4","mkv","webm","mov","avi","flv"].indexOf(e) !== -1) return Theme.mauve;
        if (["mp3","flac","wav","ogg","m4a","opus"].indexOf(e) !== -1) return Theme.green;
        if (["zip","tar","gz","xz","bz2","7z","rar"].indexOf(e) !== -1) return Theme.peach;
        if (["txt","md","pdf","doc","docx","odt","rtf"].indexOf(e) !== -1) return Theme.teal;
        if (["json","js","ts","css","html","xml","py","sh","c","cpp","h","qml","rs","go","conf","ini"].indexOf(e) !== -1) return Theme.yellow;
        return Theme.subtext1;
    }

    // ---- mounted volumes (lsblk) for the sidebar ----
    property var volumes: []
    Process {
        id: volLister
        command: ["bash", "-c",
            "lsblk -J -o PATH,SIZE,MOUNTPOINT,LABEL,TYPE 2>/dev/null"]
        stdout: StdioCollector {
            onStreamFinished: {
                var out = [];
                function walk(nodes) {
                    if (!nodes) return;
                    for (var i = 0; i < nodes.length; i++) {
                        var n = nodes[i];
                        var mp = n.mountpoint;
                        // Un extraíble montado ya sale en "Devices" (udisks2): no
                        // se duplica aquí. Se filtra por lo que udisks2 conoce de
                        // verdad, así que si no estuviera disponible el volumen
                        // seguiría apareciendo en esta lista como hasta ahora.
                        if (mp && mp !== "[SWAP]" && mp.indexOf("/boot") !== 0
                            && !Drives.isMounted(mp)) {
                            var label = n.label && n.label !== "" ? n.label
                                      : (mp === "/" ? "System" : mp.split("/").pop());
                            out.push({ label: label, size: n.size || "", path: mp });
                        }
                        if (n.children) walk(n.children);
                    }
                }
                try { walk(JSON.parse(this.text).blockdevices); }
                catch (e) { console.warn("[FileManager] lsblk parse failed:", e); }
                fm.volumes = out;
            }
        }
    }
    function refreshVolumes() { volLister.running = true; }

    // ---- SFTP remote connections (sshfs) ----------------------------------
    // A remote is mounted with sshfs into ~/.cache/vexyon/remote/<name> and then
    // browsed with the exact same navigation as a local folder. Saved endpoints
    // live in shell.json (remotes.list); passwords are never stored — prompted
    // each connect via the form.
    readonly property string remoteDir: home + "/.cache/vexyon/remote"
    property var remotes: Config.get("remotes", "list", []) || []
    property var mounted: ({})
    property bool remoteFormOpen: false
    property string fName: ""
    property string fHost: ""
    property string fPort: "22"
    property string fUser: ""
    property string fPass: ""
    property string fPath: ""
    property bool remoteBusy: false
    property string remoteError: ""
    onRemoteFormOpenChanged: if (!remoteFormOpen) fmKeys.forceActiveFocus()

    function openRemoteForm() {
        fm.fName = ""; fm.fHost = ""; fm.fPort = "22"; fm.fUser = "";
        fm.fPass = ""; fm.fPath = ""; fm.remoteError = ""; fm.remoteFormOpen = true;
    }
    function openRemoteFormFor(r) {
        fm.fName = r.name; fm.fHost = r.host; fm.fPort = r.port || "22";
        fm.fUser = r.user; fm.fPass = ""; fm.fPath = r.path || "";
        fm.remoteError = ""; fm.remoteFormOpen = true;
    }
    function saveRemote() {
        var list = (Config.get("remotes", "list", []) || []).slice();
        var out = [];
        for (var i = 0; i < list.length; i++) if (list[i].name !== fm.fName) out.push(list[i]);
        out.push({ name: fm.fName, host: fm.fHost, port: fm.fPort, user: fm.fUser, path: fm.fPath });
        Config.set("remotes", "list", out);
        fm.remotes = out;
    }
    function forgetRemote(name) {
        var list = (Config.get("remotes", "list", []) || []).slice();
        var out = [];
        for (var i = 0; i < list.length; i++) if (list[i].name !== name) out.push(list[i]);
        Config.set("remotes", "list", out);
        fm.remotes = out;
    }
    // called by the form's Conectar button
    function submitRemote() {
        if (fm.fName === "" || fm.fHost === "" || fm.fUser === "") {
            fm.remoteError = I18n.t("Name, host and user are required."); return;
        }
        fm.saveRemote();
        var mp = fm.remoteDir + "/" + fm.fName;
        var target = fm.fUser + "@" + fm.fHost + ":" + (fm.fPath !== "" ? fm.fPath : "/home/" + fm.fUser);
        fm.remoteBusy = true; fm.remoteError = "";
        mountProc.pendingName = fm.fName; mountProc.pendingMp = mp;
        mountProc.command = ["bash", "-c",
            "mkdir -p " + shq(mp) + "; printf '%s\\n' " + shq(fm.fPass) +
            " | sshfs " + shq(target) + " " + shq(mp) +
            " -o password_stdin,StrictHostKeyChecking=no,UserKnownHostsFile=/dev/null,reconnect,ServerAliveInterval=15,port=" + fm.fPort + " 2>&1"];
        mountProc.running = true;
    }
    function connectSaved(r) { fm.openRemoteFormFor(r); }
    function disconnectRemote(name) {
        var mp = fm.remoteDir + "/" + name;
        unmountProc.pendingName = name;
        unmountProc.command = ["bash", "-c",
            "fusermount3 -u " + shq(mp) + " 2>/dev/null || fusermount -u " + shq(mp) + " 2>/dev/null || umount " + shq(mp) + " 2>/dev/null"];
        unmountProc.running = true;
    }
    function isMounted(name) { return fm.mounted[name] === true; }

    Process {
        id: mountProc
        property string pendingName: ""
        property string pendingMp: ""
        stdout: StdioCollector {
            onStreamFinished: {
                mountCheck.savedName = mountProc.pendingName;
                mountCheck.savedMp = mountProc.pendingMp;
                mountCheck.savedErr = this.text.trim();
                mountCheck.command = ["bash", "-c", "mount | grep -q " + fm.shq(" " + mountProc.pendingMp + " ") + " && echo OK || echo FAIL"];
                mountCheck.running = true;
            }
        }
    }
    Process {
        id: mountCheck
        property string savedName: ""
        property string savedMp: ""
        property string savedErr: ""
        stdout: StdioCollector {
            onStreamFinished: {
                fm.remoteBusy = false;
                if (this.text.trim() === "OK") {
                    var m = Object.assign({}, fm.mounted); m[mountCheck.savedName] = true; fm.mounted = m;
                    fm.remoteFormOpen = false;
                    fm.navigate(mountCheck.savedMp);
                } else {
                    fm.remoteError = mountCheck.savedErr !== "" ? mountCheck.savedErr : I18n.t("Couldn't connect to the server.");
                }
            }
        }
    }
    Process {
        id: unmountProc
        property string pendingName: ""
        onExited: {
            var m = Object.assign({}, fm.mounted); delete m[unmountProc.pendingName]; fm.mounted = m;
            if (fm.cwd.indexOf(fm.remoteDir + "/" + unmountProc.pendingName) === 0) fm.navigate(fm.home);
        }
    }

    // ---- context menu state ----
    property bool ctxOpen: false
    property real ctxX: 0
    property real ctxY: 0
    property var ctxEntry: null   // null => menú de fondo (área vacía)
    property var ctxSide: null    // fila de la barra lateral: { path, bookmark, index, missing }
    property var ctxDrive: null   // dispositivo de la barra lateral: { dev, obj, disk, mount }
    function showCtx(x, y, entry) {
        fm.ctxSide = null; fm.ctxDrive = null;
        fm.ctxEntry = entry; fm.ctxX = x; fm.ctxY = y; fm.ctxOpen = true;
        FileClipboard.probe();    // ¿hay algo que pegar? (puede venir de otro programa)
    }
    function showSideCtx(x, y, path, isBookmark, index, missing) {
        fm.ctxEntry = null; fm.ctxDrive = null;
        fm.ctxSide = { path: path, bookmark: isBookmark, index: index, missing: missing };
        fm.ctxX = x; fm.ctxY = y; fm.ctxOpen = true;
    }
    function showDriveCtx(x, y, d) {
        fm.ctxEntry = null; fm.ctxSide = null;
        fm.ctxDrive = { dev: d.dev || "", obj: d.obj || "", disk: d.disk, mount: d.mount || "", label: d.fsLabel || "" };
        fm.ctxX = x; fm.ctxY = y; fm.ctxOpen = true;
    }

    // ---- formatear una unidad externa (DriveFormatDialog + vexyon-format) ----
    readonly property var rawDrives: Drives.drives.filter(function(d) { return !d.readable; })
    property bool fmtOpen: false
    property string fmtDisk: ""
    property string fmtLabel: ""
    function openFormat(disk, label) {
        fm.fmtDisk = disk;
        fm.fmtLabel = label || "";
        fm.fmtOpen = true;
    }
    onFmtOpenChanged: if (!fmtOpen) fmKeys.forceActiveFocus()
    //  Antes de borrar: salir de la unidad si esta ventana está dentro (las
    //  demás ventanas salen solas cuando Drives deja de verla montada).
    function leaveDisk(disk) {
        var d = Drives.deviceFor(fm.cwd);
        if (d && d.disk === disk) fm.navigate(fm.home);
    }
    function driveFormatted(dev, obj, label) {
        fm.fmtOpen = false;
        var dr = Drives.driveOf(fm.fmtDisk);
        fm.notice(I18n.t("“%1” is formatted and ready.").arg(label !== "" ? label : (dr ? dr.name : dev)), false);
        if (dev !== "" && obj !== "") Drives.mount(dev, obj, function(mp) { fm.navigate(mp); });
    }

    // ---- marcadores de la barra lateral ------------------------------------
    property int bmDragFrom: -1      // marcador que se está reordenando
    property int bmInsert: -1        // hueco de inserción bajo el cursor (-1: ninguno)
    //  Hay un arrastre de carpetas en curso (de esta ventana o de fuera): la
    //  sección de marcadores se enseña aunque esté vacía, para poder soltar.
    readonly property bool folderDragActive: (selArea.dragging && fm.selectionAllDirs()) || sideDrop.containsDrag

    function entryOf(path) {
        for (var i = 0; i < fm.entries.length; i++)
            if (fm.entries[i].path === path) return fm.entries[i];
        return null;
    }
    function selectionAllDirs() {
        var l = fm.selectedList();
        if (!l.length) return false;
        for (var i = 0; i < l.length; i++) {
            var e = fm.entryOf(l[i]);
            if (!e || !e.isDir) return false;
        }
        return true;
    }
    //  y (coordenadas de bmCol) -> { slot: hueco de inserción, into: carpeta }.
    //  La franja central de una fila es "dentro de esa carpeta"; los bordes,
    //  "entre filas".
    function bookmarkHit(y, allowInto) {
        var n = bmRep.count;
        for (var i = 0; i < n; i++) {
            var it = bmRep.itemAt(i);
            if (!it || y >= it.y + it.height) continue;
            var rel = (y - it.y) / it.height;
            if (allowInto && rel >= 0.25 && rel <= 0.75 && !it.missing) return { slot: -1, into: it.path };
            return { slot: rel < 0.5 ? i : i + 1, into: "" };
        }
        return { slot: n, into: "" };
    }
    function finishBookmarkReorder() {
        var from = fm.bmDragFrom, to = fm.bmInsert;
        fm.bmDragFrom = -1; fm.bmInsert = -1;
        if (from < 0 || to < 0 || to === from || to === from + 1) return;
        var b = Places.bookmarks[from];
        if (b) Places.move(b.path, to > from ? to - 1 : to);
    }
    //  "Añadir a la barra lateral": solo carpetas, sin duplicados (lo
    //  comprueba el ayudante contra el fichero real). Nunca crea enlaces ni
    //  toca la carpeta.
    function addToSidebar(paths, at) {
        var dirs = [], files = 0;
        for (var i = 0; i < paths.length; i++) {
            var e = fm.entryOf(paths[i]);
            if (e && !e.isDir) files++;
            else dirs.push(paths[i]);
        }
        if (!dirs.length) { fm.notice(I18n.t("Only folders can be added to the sidebar."), false); return; }
        Places.add(dirs, at, function(added, rejected) {
            if (!rejected.length && !files) return;
            var why = rejected.length ? rejected[0].why : "notdir";
            fm.notice(why === "duplicate" || why === "builtin" ? I18n.t("Already in the sidebar.")
                    : why === "notdir" ? I18n.t("Only folders can be added to the sidebar.")
                    : I18n.t("That folder can't be added to the sidebar."), false);
        });
    }

    // ---- selector de ficheros del sistema ------------------------------------
    //  El MISMO gestor hace de diálogo de abrir/guardar para todo el sistema:
    //  las apps (portal xdg, servicio vexyon-portal), AirDrop y cualquier
    //  script llegan por `vexyon-pick`, que pide una ventana con
    //  `qs ipc call vexyon pick <id> <json>` (shell.qml) y espera la respuesta
    //  que FilePicker.reply() le deja en su FIFO. Cerrar la ventana = cancelar.
    property string pickMode: ""        // "" | "file" | "files" | "folder" | "save"
    property string pickId: ""
    property string pickTitle: ""
    property string pickName: ""        // save: nombre propuesto
    property var pickFilters: []        // [{ name, patterns: ["*.png", …] }]
    property int pickFilter: -1         // índice en pickFilters; -1 = todos los ficheros
    property bool pickDone: false
    property bool pickArmed: false      // save: confirmar que se reemplaza
    property var cwdNames: ({})         // todos los nombres de cwd, también los que oculta el filtro
    readonly property bool picking: fm.pickMode !== ""
    readonly property string pickAcceptLabel: fm.pickMode === "save" ? I18n.t("Save")
        : fm.pickMode === "folder" ? I18n.t("Select") : I18n.t("Open")
    onPickFilterChanged: if (fm.picking) fm.refresh()

    // glob ("*.png", "*.[jJ]pg") -> RegExp, sin distinguir mayúsculas
    function globRe(g) {
        var r = "";
        for (var i = 0; i < g.length; i++) {
            var c = g.charAt(i);
            if (c === "*") r += ".*";
            else if (c === "?") r += ".";
            else if (c === "[") { var j = g.indexOf("]", i); if (j > i) { r += g.substring(i, j + 1); i = j; } else r += "\\["; }
            else r += c.replace(/[.+^${}()|\\\/]/g, "\\$&");
        }
        return new RegExp("^" + r + "$", "i");
    }
    function pickShows(name, isDir) {
        if (!fm.picking) return true;
        if (fm.pickMode === "folder") return isDir;
        if (isDir || fm.pickFilter < 0 || fm.pickFilter >= fm.pickFilters.length) return true;
        var pats = fm.pickFilters[fm.pickFilter].patterns || [];
        if (pats.length === 0) return true;
        for (var i = 0; i < pats.length; i++) if (fm.globRe(pats[i]).test(name)) return true;
        return false;
    }
    function acceptPick() {
        if (!fm.picking || fm.pickDone) return;
        var out = [], i;
        if (fm.pickMode === "folder") {
            for (i = 0; i < fm.entries.length; i++)
                if (fm.selection[fm.entries[i].path] && fm.entries[i].isDir) { out.push(fm.entries[i].path); break; }
            if (out.length === 0) out.push(fm.cwd);
        } else if (fm.pickMode === "save") {
            var name = fm.pickName.trim();
            if (name === "" || name.indexOf("/") !== -1) { fm.notice(I18n.t("Type a file name."), true); return; }
            if (fm.cwdNames[name] === true && !fm.pickArmed) {
                fm.pickArmed = true;
                fm.notice(I18n.t("“%1” already exists. Press Save again to replace it.").arg(name), true);
                return;
            }
            out.push((fm.cwd === "/" ? "" : fm.cwd) + "/" + name);
        } else {
            for (i = 0; i < fm.entries.length; i++)
                if (fm.selection[fm.entries[i].path] && !fm.entries[i].isDir) out.push(fm.entries[i].path);
            if (out.length === 0) { fm.notice(I18n.t("Select a file first."), true); return; }
            if (fm.pickMode === "file") out = [out[0]];
        }
        fm.finishPick(out);
    }
    function finishPick(paths) {
        if (fm.pickDone) return;
        fm.pickDone = true;
        FilePicker.reply(fm.pickId, paths);
        fm.visible = false;
    }
    function cancelPick() { fm.finishPick(null); }
    onPickNameChanged: fm.pickArmed = false
    // quien pedía ya no espera (la app retiró la petición): cerrar sin responder
    Connections {
        target: fm.picking ? FilePicker : null
        function onWithdrawn(id) { if (id === fm.pickId) { fm.pickDone = true; fm.visible = false; } }
    }

    // ---- icono de carpeta ----------------------------------------------------
    property bool iconPickOpen: false
    property string iconPickPath: ""
    //  Elegir una imagen propia: el selector se cierra y el PROPIO gestor sirve
    //  para buscarla (doble clic en un .svg/.png). Esc o "Cancelar" vuelven.
    property string pickImageFor: ""
    property string pickReturnDir: ""
    function openIconPicker(path) { fm.iconPickPath = path; fm.iconPickOpen = true; }
    function startImagePick(path) {
        fm.iconPickOpen = false;
        fm.pickImageFor = path;
        fm.pickReturnDir = fm.cwd;
        var pics = Places.dirs.PICTURES;
        if (pics && pics.exists) fm.navigate(pics.path);
    }
    function endImagePick(reopen) {
        var p = fm.pickImageFor, back = fm.pickReturnDir;
        fm.pickImageFor = ""; fm.pickReturnDir = "";
        if (back !== "" && back !== fm.cwd) fm.navigate(back);
        if (reopen && p !== "") fm.openIconPicker(p);
    }
    function useImage(file) {
        var target = fm.pickImageFor;
        FolderIcons.setImage(target, file, function(ok, err) {
            if (ok) fm.endImagePick(false);
            else fm.notice(I18n.t("That image can't be used: ") + err, true);
        });
    }
    onIconPickOpenChanged: if (!iconPickOpen) fmKeys.forceActiveFocus()

    // ---- drag-and-drop state ----
    property string dropTarget: ""   // path de la carpeta bajo el cursor durante el drag
    // file:// URI RFC-correcta: cada segmento percent-encoded, "/" intactos.
    function pathToUri(p) { return "file://" + p.split("/").map(encodeURIComponent).join("/"); }
    function uriToPath(u) {
        var s = u.toString();
        if (s.indexOf("file://") !== 0) return "";
        return decodeURIComponent(s.slice(7).split("?")[0].split("#")[0]);
    }

    // ---- fila de la barra lateral (lugares y marcadores) ---------------------
    //  Clic: abrir. Botón derecho: menú (abrir, icono, mover, quitar). Arrastrar
    //  un MARCADOR arriba/abajo lo reordena (la línea de inserción lo enseña).
    //  `dropPath` la convierte en destino de arrastres de ficheros (mover dentro).
    Component {
        id: sideRowCmp
        Rectangle {
            id: row
            required property var modelData
            required property int index
            readonly property bool isBookmark: modelData.key === undefined
            readonly property string path: modelData.path
            readonly property bool missing: modelData.exists === false
            readonly property string dropPath: missing ? "" : path
            readonly property bool current: fm.cwd === path
            readonly property string glyph: {
                if (row.missing) return Icons.folder;
                // Home conserva su casa de siempre salvo que se le elija otra cosa
                if (modelData.key === "HOME" && FolderIcons.customId(row.path) === "") return Icons.home;
                return FolderIcons.sidebarGlyph(row.path) || Icons.folder;
            }
            property bool wasDrag: false

            Layout.fillWidth: true
            Layout.preferredHeight: 34
            radius: Theme.radius
            color: fm.dropTarget === path ? Theme.surface2
                   : current ? Theme.accent
                   : (rowMa.containsMouse ? Theme.surface1 : "transparent")
            border.width: fm.dropTarget === path ? 2 : 0
            border.color: Theme.accent
            opacity: row.isBookmark && fm.bmDragFrom === row.index ? 0.45 : (row.missing ? 0.7 : 1)
            Behavior on color { ColorAnimation { duration: Theme.dur(100) } }

            RowLayout {
                anchors.fill: parent
                anchors.leftMargin: 10
                anchors.rightMargin: 8
                spacing: 10
                Text {
                    text: row.glyph
                    color: row.current ? Theme.onAccent : Theme.subtext0
                    font.family: FolderIcons.symbolFont
                    font.pixelSize: Theme.fontSize + 1
                    horizontalAlignment: Text.AlignHCenter
                    Layout.preferredWidth: 18
                }
                Text {
                    Layout.fillWidth: true
                    text: row.modelData.label
                    color: row.current ? Theme.onAccent : (row.missing ? Theme.overlay2 : Theme.text)
                    font.family: Theme.fontFamily
                    font.pixelSize: Theme.fontSize - 1
                    font.italic: row.missing
                    elide: Text.ElideRight
                }
            }
            MouseArea {
                id: rowMa
                anchors.fill: parent
                hoverEnabled: true
                acceptedButtons: Qt.LeftButton | Qt.RightButton
                // el desplazable no se queda el gesto de reordenar
                preventStealing: row.isBookmark
                cursorShape: fm.bmDragFrom >= 0 ? Qt.ClosedHandCursor : Qt.PointingHandCursor
                property real py: 0
                onPressed: function(mouse) {
                    fmKeys.forceActiveFocus();
                    fm.ctxOpen = false;
                    row.wasDrag = false;
                    if (mouse.button === Qt.RightButton) {
                        var pt = rowMa.mapToItem(null, mouse.x, mouse.y);
                        fm.showSideCtx(pt.x, pt.y, row.path, row.isBookmark, row.index, row.missing);
                        return;
                    }
                    py = mouse.y;
                }
                onPositionChanged: function(mouse) {
                    if (!pressed || !row.isBookmark || !(mouse.buttons & Qt.LeftButton)) return;
                    if (fm.bmDragFrom < 0 && Math.abs(mouse.y - py) < 6) return;
                    row.wasDrag = true;
                    fm.bmDragFrom = row.index;
                    var p = rowMa.mapToItem(bmCol, mouse.x, mouse.y);
                    fm.bmInsert = fm.bookmarkHit(p.y, false).slot;
                }
                onReleased: if (fm.bmDragFrom >= 0) fm.finishBookmarkReorder()
                onCanceled: { fm.bmDragFrom = -1; fm.bmInsert = -1; }
                onClicked: function(mouse) {
                    if (mouse.button !== Qt.LeftButton || row.wasDrag) return;
                    if (row.missing) { fm.notice(I18n.t("This folder no longer exists."), false); return; }
                    fm.navigate(row.path);
                }
            }
        }
    }

    RowLayout {
        anchors.fill: parent
        spacing: 0

        // ================= SIDEBAR =================
        //  Lugares (Home + carpetas XDG reales), marcadores, volúmenes,
        //  dispositivos y remotos van en un desplazable: con muchos marcadores
        //  la columna crece sin empujar la papelera fuera de la ventana.
        Rectangle {
            id: sidebar
            Layout.preferredWidth: 190
            Layout.fillHeight: true
            color: Theme.mantle

            ColumnLayout {
                anchors.fill: parent
                anchors.margins: 10
                spacing: 4

                Flickable {
                    id: sideFlick
                    Layout.fillWidth: true
                    Layout.fillHeight: true
                    contentWidth: width
                    contentHeight: sideCol.implicitHeight
                    clip: true
                    boundsBehavior: Flickable.StopAtBounds
                    interactive: contentHeight > height

                    ColumnLayout {
                        id: sideCol
                        width: sideFlick.width
                        spacing: 4

                        Text {
                            text: I18n.t("Places")
                            color: Theme.overlay2
                            font.family: Theme.fontFamily
                            font.pixelSize: Theme.fontSize - 3
                            Layout.bottomMargin: 4
                        }

                        // Home + las carpetas de usuario en sus rutas CONFIGURADAS
                        // (user-dirs.dirs: ~/Documentos, ~/Bilder…), nunca adivinadas
                        // por su nombre en inglés.
                        Repeater {
                            model: Places.builtin
                            delegate: sideRowCmp
                        }

                        // ---- Marcadores (los del usuario; fichero de marcadores GTK) ----
                        //  SOLTAR una carpeta entre dos filas (o en el hueco vacío) la
                        //  añade aquí; encima de una fila, la mueve dentro, como en
                        //  cualquier otro lugar. Arrastrar un marcador lo reordena.
                        Item {
                            id: bmBox
                            Layout.fillWidth: true
                            Layout.topMargin: visible ? 6 : 0
                            visible: Places.bookmarks.length > 0 || fm.folderDragActive
                            implicitHeight: bmCol.implicitHeight

                            ColumnLayout {
                                id: bmCol
                                width: parent.width
                                spacing: 4
                                Text {
                                    text: I18n.t("Bookmarks")
                                    color: Theme.overlay2
                                    font.family: Theme.fontFamily
                                    font.pixelSize: Theme.fontSize - 3
                                    Layout.bottomMargin: 4
                                }
                                Repeater {
                                    id: bmRep
                                    model: Places.bookmarks
                                    delegate: sideRowCmp
                                }
                                // hueco donde soltar cuando aún no hay marcadores
                                Rectangle {
                                    visible: Places.bookmarks.length === 0
                                    Layout.fillWidth: true
                                    Layout.preferredHeight: 34
                                    radius: Theme.radius
                                    color: fm.dropTarget === "::bookmark" ? Qt.alpha(Theme.accent, 0.18) : "transparent"
                                    border.width: 1
                                    border.color: Qt.alpha(Theme.accent, fm.dropTarget === "::bookmark" ? 0.9 : 0.45)
                                    Text {
                                        anchors.fill: parent
                                        anchors.leftMargin: 10
                                        anchors.rightMargin: 6
                                        verticalAlignment: Text.AlignVCenter
                                        text: I18n.t("Drop a folder here")
                                        color: Theme.subtext0
                                        font.family: Theme.fontFamily
                                        font.pixelSize: Theme.fontSize - 3
                                        elide: Text.ElideRight
                                    }
                                }
                            }

                            // línea de inserción (soltar o reordenar)
                            Rectangle {
                                visible: fm.bmInsert >= 0 && Places.bookmarks.length > 0
                                x: 4
                                width: parent.width - 8
                                height: 3
                                radius: 1.5
                                color: Theme.accent
                                z: 5
                                y: {
                                    var n = bmRep.count, k = fm.bmInsert;
                                    if (n === 0 || k < 0) return 0;
                                    var it = bmRep.itemAt(Math.min(k, n - 1));
                                    if (!it) return 0;
                                    return (k < n ? it.y - 2 : it.y + it.height + 1) - height / 2 + 1;
                                }
                            }
                        }
                        // ---- Volumes (mounted drives) ----
                        Text {
                            visible: fm.volumes.length > 0
                            text: I18n.t("Volumes")
                            color: Theme.overlay2
                            font.family: Theme.fontFamily
                            font.pixelSize: Theme.fontSize - 3
                            Layout.topMargin: 10
                            Layout.bottomMargin: 4
                        }
                        Repeater {
                            model: fm.volumes
                            delegate: Rectangle {
                                required property var modelData
                                readonly property string dropPath: modelData.path
                                Layout.fillWidth: true
                                Layout.preferredHeight: 40
                                radius: Theme.radius
                                color: fm.dropTarget === modelData.path ? Theme.surface2
                                : fm.cwd === modelData.path ? Theme.accent
                                : (vm.containsMouse ? Theme.surface1 : "transparent")
                                border.width: fm.dropTarget === modelData.path ? 2 : 0
                                border.color: Theme.accent
                                Behavior on color { ColorAnimation { duration: Theme.dur(100) } }
                                RowLayout {
                                    anchors.fill: parent
                                    anchors.leftMargin: 10
                                    anchors.rightMargin: 8
                                    spacing: 10
                                    Text {
                                        text: Icons.drive
                                        color: fm.cwd === modelData.path ? Theme.onAccent : Theme.subtext0
                                        font.family: Theme.fontFamily
                                        font.pixelSize: Theme.fontSize + 1
                                        Layout.preferredWidth: 18
                                    }
                                    ColumnLayout {
                                        Layout.fillWidth: true
                                        spacing: 0
                                        Text {
                                            Layout.fillWidth: true
                                            text: modelData.label
                                            color: fm.cwd === modelData.path ? Theme.onAccent : Theme.text
                                            font.family: Theme.fontFamily
                                            font.pixelSize: Theme.fontSize - 1
                                            elide: Text.ElideRight
                                        }
                                        Text {
                                            Layout.fillWidth: true
                                            text: modelData.size
                                            color: fm.cwd === modelData.path ? Theme.onAccent : Theme.overlay2
                                            font.family: Theme.fontFamily
                                            font.pixelSize: Theme.fontSize - 4
                                            elide: Text.ElideRight
                                        }
                                    }
                                }
                                MouseArea {
                                    id: vm
                                    anchors.fill: parent
                                    hoverEnabled: true
                                    cursorShape: Qt.PointingHandCursor
                                    onClicked: fm.navigate(modelData.path)
                                }
                            }
                        }

                        // ---- Devices (unidades extraíbles, udisks2 en vivo) ----
                        // Mismo delegado visual que Volumes; añade botón de expulsar y,
                        // si no está montado, el click monta y entra.
                        Text {
                            visible: Drives.devices.length > 0 || fm.rawDrives.length > 0
                            text: I18n.t("Devices")
                            color: Theme.overlay2
                            font.family: Theme.fontFamily
                            font.pixelSize: Theme.fontSize - 3
                            Layout.topMargin: 10
                            Layout.bottomMargin: 4
                        }
                        Repeater {
                            model: Drives.devices
                            delegate: Rectangle {
                                id: devRow
                                required property var modelData
                                readonly property bool mounted: modelData.mount !== ""
                                readonly property string dropPath: modelData.mount
                                Layout.fillWidth: true
                                Layout.preferredHeight: 40
                                radius: Theme.radius
                                color: (mounted && fm.dropTarget === modelData.mount) ? Theme.surface2
                                : (mounted && fm.cwd === modelData.mount) ? Theme.accent
                                : (dvm.containsMouse ? Theme.surface1 : "transparent")
                                border.width: (mounted && fm.dropTarget === modelData.mount) ? 2 : 0
                                border.color: Theme.accent
                                Behavior on color { ColorAnimation { duration: Theme.dur(100) } }
                                RowLayout {
                                    anchors.fill: parent
                                    anchors.leftMargin: 10
                                    anchors.rightMargin: 8
                                    spacing: 10
                                    Text {
                                        text: Icons.drive
                                        color: fm.cwd === modelData.mount ? Theme.onAccent
                                        : devRow.mounted ? Theme.green : Theme.subtext0
                                        font.family: Theme.fontFamily
                                        font.pixelSize: Theme.fontSize + 1
                                        Layout.preferredWidth: 18
                                    }
                                    ColumnLayout {
                                        Layout.fillWidth: true
                                        spacing: 0
                                        Text {
                                            Layout.fillWidth: true
                                            text: modelData.label
                                            color: fm.cwd === modelData.mount ? Theme.onAccent : Theme.text
                                            font.family: Theme.fontFamily
                                            font.pixelSize: Theme.fontSize - 1
                                            elide: Text.ElideRight
                                        }
                                        Text {
                                            Layout.fillWidth: true
                                            text: modelData.size
                                            color: fm.cwd === modelData.mount ? Theme.onAccent : Theme.overlay2
                                            font.family: Theme.fontFamily
                                            font.pixelSize: Theme.fontSize - 4
                                            elide: Text.ElideRight
                                        }
                                    }
                                    // Expulsar: solo con el dispositivo montado
                                    Rectangle {
                                        Layout.preferredWidth: 20; Layout.preferredHeight: 20
                                        radius: 10
                                        visible: devRow.mounted
                                        color: ejMa.containsMouse ? Theme.red : "transparent"
                                        Text {
                                            anchors.centerIn: parent
                                            text: Icons.close
                                            color: ejMa.containsMouse ? Theme.onAccent : Theme.subtext0
                                            font.family: Theme.fontFamily; font.pixelSize: Theme.fontSize - 3
                                        }
                                        MouseArea {
                                            id: ejMa
                                            anchors.fill: parent; hoverEnabled: true; cursorShape: Qt.PointingHandCursor
                                            onClicked: {
                                                // salir del dispositivo antes de desmontar
                                                if (Drives.contains(fm.cwd)) fm.navigate(fm.home);
                                                Drives.unmount(modelData.dev);
                                            }
                                        }
                                    }
                                }
                                MouseArea {
                                    id: dvm
                                    anchors.fill: parent
                                    hoverEnabled: true
                                    acceptedButtons: Qt.LeftButton | Qt.RightButton
                                    cursorShape: Qt.PointingHandCursor
                                    z: -1
                                    onClicked: function(mouse) {
                                        if (mouse.button === Qt.RightButton) {
                                            var pt = dvm.mapToItem(null, mouse.x, mouse.y);
                                            fm.showDriveCtx(pt.x, pt.y, devRow.modelData);
                                            return;
                                        }
                                        if (devRow.mounted) fm.navigate(modelData.mount);
                                        else Drives.mount(modelData.dev, modelData.obj,
                                        function(mp) { fm.navigate(mp); });
                                    }
                                }
                            }
                        }
                        // Unidades sin nada que abrir (sin formato, cifradas, un
                        // sistema de ficheros desconocido): el clic ofrece formatearlas.
                        Repeater {
                            model: fm.rawDrives
                            delegate: Rectangle {
                                id: rawRow
                                required property var modelData
                                Layout.fillWidth: true
                                Layout.preferredHeight: 40
                                radius: Theme.radius
                                color: rawMa.containsMouse ? Theme.surface1 : "transparent"
                                Behavior on color { ColorAnimation { duration: Theme.dur(100) } }
                                RowLayout {
                                    anchors.fill: parent
                                    anchors.leftMargin: 10
                                    anchors.rightMargin: 8
                                    spacing: 10
                                    Text {
                                        text: Icons.drive
                                        color: Theme.yellow
                                        font.family: Theme.fontFamily
                                        font.pixelSize: Theme.fontSize + 1
                                        Layout.preferredWidth: 18
                                    }
                                    ColumnLayout {
                                        Layout.fillWidth: true
                                        spacing: 0
                                        Text {
                                            Layout.fillWidth: true
                                            text: rawRow.modelData.name
                                            color: Theme.text
                                            font.family: Theme.fontFamily
                                            font.pixelSize: Theme.fontSize - 1
                                            elide: Text.ElideRight
                                        }
                                        Text {
                                            Layout.fillWidth: true
                                            text: rawRow.modelData.size + " · " + I18n.t("Not readable")
                                            color: Theme.overlay2
                                            font.family: Theme.fontFamily
                                            font.pixelSize: Theme.fontSize - 4
                                            elide: Text.ElideRight
                                        }
                                    }
                                }
                                MouseArea {
                                    id: rawMa
                                    anchors.fill: parent
                                    hoverEnabled: true
                                    acceptedButtons: Qt.LeftButton | Qt.RightButton
                                    cursorShape: Qt.PointingHandCursor
                                    onClicked: function(mouse) {
                                        if (mouse.button === Qt.RightButton) {
                                            var pt = rawMa.mapToItem(null, mouse.x, mouse.y);
                                            fm.showDriveCtx(pt.x, pt.y, { disk: rawRow.modelData.obj });
                                            return;
                                        }
                                        fm.openFormat(rawRow.modelData.obj, "");
                                    }
                                }
                            }
                        }

                        // ---- Remoto (SFTP connections) ----
                        RowLayout {
                            Layout.fillWidth: true
                            Layout.topMargin: 10
                            Text {
                                Layout.fillWidth: true
                                text: I18n.t("Remote")
                                color: Theme.overlay2
                                font.family: Theme.fontFamily
                                font.pixelSize: Theme.fontSize - 3
                            }
                            Rectangle {
                                Layout.preferredWidth: 22; Layout.preferredHeight: 22
                                radius: 6
                                color: addRemoteMa.containsMouse ? Theme.accent : Theme.surface1
                                Text { anchors.centerIn: parent; text: Icons.plus; color: addRemoteMa.containsMouse ? Theme.onAccent : Theme.subtext0; font.family: Theme.fontFamily; font.pixelSize: Theme.fontSize - 2 }
                                MouseArea { id: addRemoteMa; anchors.fill: parent; hoverEnabled: true; cursorShape: Qt.PointingHandCursor; onClicked: fm.openRemoteForm() }
                            }
                        }
                        Repeater {
                            model: fm.remotes
                            delegate: Rectangle {
                                required property var modelData
                                readonly property bool conn: fm.isMounted(modelData.name)
                                Layout.fillWidth: true
                                Layout.preferredHeight: 34
                                radius: Theme.radius
                                color: fm.cwd === (fm.remoteDir + "/" + modelData.name) ? Theme.accent
                                : (rmtMa.containsMouse ? Theme.surface1 : "transparent")
                                RowLayout {
                                    anchors.fill: parent; anchors.leftMargin: 10; anchors.rightMargin: 6; spacing: 8
                                    Text {
                                        text: Icons.ethernet
                                        color: fm.cwd === (fm.remoteDir + "/" + modelData.name) ? Theme.onAccent
                                        : (conn ? Theme.green : Theme.subtext0)
                                        font.family: Theme.fontFamily; font.pixelSize: Theme.fontSize; Layout.preferredWidth: 16
                                    }
                                    Text {
                                        Layout.fillWidth: true
                                        text: modelData.name
                                        color: fm.cwd === (fm.remoteDir + "/" + modelData.name) ? Theme.onAccent : Theme.text
                                        font.family: Theme.fontFamily; font.pixelSize: Theme.fontSize - 1
                                        elide: Text.ElideRight
                                    }
                                    Rectangle {
                                        Layout.preferredWidth: 20; Layout.preferredHeight: 20
                                        radius: 10
                                        visible: rmtMa.containsMouse || conn
                                        color: actMa.containsMouse ? (conn ? Theme.red : Theme.surface2) : "transparent"
                                        Text {
                                            anchors.centerIn: parent
                                            text: conn ? Icons.close : Icons.trash
                                            color: Theme.subtext0
                                            font.family: Theme.fontFamily; font.pixelSize: Theme.fontSize - 3
                                        }
                                        MouseArea {
                                            id: actMa
                                            anchors.fill: parent; hoverEnabled: true; cursorShape: Qt.PointingHandCursor
                                            onClicked: conn ? fm.disconnectRemote(modelData.name) : fm.forgetRemote(modelData.name)
                                        }
                                    }
                                }
                                MouseArea {
                                    id: rmtMa
                                    anchors.fill: parent
                                    hoverEnabled: true
                                    cursorShape: Qt.PointingHandCursor
                                    z: -1
                                    onClicked: conn ? fm.navigate(fm.remoteDir + "/" + modelData.name) : fm.connectSaved(modelData)
                                }
                            }
                        }

                    }
                }

                // Trash (soltar un drag encima = enviar a la papelera, como Nautilus).
                // Fija abajo, fuera del desplazable.
                Rectangle {
                    id: trashRow
                    readonly property string dropPath: "::trash"
                    Layout.fillWidth: true
                    Layout.preferredHeight: 34
                    radius: Theme.radius
                    color: fm.dropTarget === "::trash" ? Qt.alpha(Theme.red, 0.25)
                    : fm.inTrash ? Theme.accent : (tm.containsMouse ? Theme.surface1 : "transparent")
                    border.width: fm.dropTarget === "::trash" ? 2 : 0
                    border.color: Theme.red
                    RowLayout {
                        anchors.fill: parent; anchors.leftMargin: 10; spacing: 10
                        Text { text: Icons.trash; color: fm.dropTarget === "::trash" ? Theme.red : fm.inTrash ? Theme.onAccent : Theme.subtext0; font.family: Theme.fontFamily; font.pixelSize: Theme.fontSize + 1; Layout.preferredWidth: 18 }
                        Text { Layout.fillWidth: true; text: I18n.t("Trash"); color: fm.inTrash ? Theme.onAccent : Theme.text; font.family: Theme.fontFamily; font.pixelSize: Theme.fontSize - 1 }
                    }
                    MouseArea {
                        id: tm; anchors.fill: parent; hoverEnabled: true; cursorShape: Qt.PointingHandCursor
                        onClicked: fm.navigate(fm.trashDir)
                    }
                }
            }

            // Drops ENTRANTES sobre la barra lateral (otra ventana del gestor,
            // Nautilus, un navegador…): entre marcadores = añadir marcador
            // (solo carpetas: lo comprueba el ayudante); encima de un lugar =
            // copiar ahí, como en la vista.
            DropArea {
                id: sideDrop
                anchors.fill: parent
                keys: ["text/uri-list"]
                function target(x, y) {
                    var fp = sideDrop.mapToItem(sideFlick, x, y);
                    if (fp.x < 0 || fp.y < 0 || fp.x >= sideFlick.width || fp.y >= sideFlick.height)
                        return { into: "", slot: -1 };
                    var bp = sideDrop.mapToItem(bmBox, x, y);
                    if (bmBox.visible && bp.y >= -2 && bp.y <= bmBox.height + 2) {
                        var hit = fm.bookmarkHit(bp.y, true);
                        return hit.into !== "" ? { into: hit.into, slot: -1 } : { into: "", slot: hit.slot };
                    }
                    var sp = sideDrop.mapToItem(sideCol, x, y);
                    var ch = sideCol.childAt(sp.x, sp.y);
                    return { into: (ch && ch.dropPath !== undefined && ch.dropPath !== "") ? ch.dropPath : "", slot: -1 };
                }
                onPositionChanged: function(drag) {
                    var t = sideDrop.target(drag.x, drag.y);
                    fm.bmInsert = t.slot;
                    fm.dropTarget = t.into !== "" ? t.into : (t.slot >= 0 ? "::bookmark" : "");
                }
                onExited: { fm.bmInsert = -1; fm.dropTarget = ""; }
                onDropped: function(drop) {
                    var t = sideDrop.target(drop.x, drop.y);
                    fm.bmInsert = -1;
                    fm.dropTarget = "";
                    var paths = [];
                    for (var i = 0; i < drop.urls.length; i++) {
                        var p = fm.uriToPath(drop.urls[i]);
                        if (p !== "") paths.push(p);
                    }
                    if (!paths.length) return;
                    // la acción es COPIA para el origen: nunca borra nada suyo
                    if (t.slot >= 0) { fm.addToSidebar(paths, t.slot); drop.accept(Qt.CopyAction); }
                    else if (t.into !== "") { fm.copyPaths(paths, t.into); drop.accept(Qt.CopyAction); }
                }
            }
        }

        // ================= MAIN =================
        ColumnLayout {
            Layout.fillWidth: true
            Layout.fillHeight: true
            spacing: 0

            // ---- toolbar ----
            Rectangle {
                Layout.fillWidth: true
                Layout.preferredHeight: 48
                color: Theme.surface0
                RowLayout {
                    anchors.fill: parent
                    anchors.leftMargin: 10
                    anchors.rightMargin: 10
                    spacing: 6
                    IconButton { icon: Icons.back; iconColor: fm.backStack.length ? Theme.text : Theme.overlay0; onClicked: fm.goBack() }
                    IconButton { icon: Icons.forward; iconColor: fm.fwdStack.length ? Theme.text : Theme.overlay0; onClicked: fm.goForward() }
                    IconButton { icon: Icons.up; onClicked: fm.goUp() }
                    IconButton { icon: Icons.refresh; onClicked: fm.refresh() }

                    Rectangle {
                        Layout.fillWidth: true
                        Layout.preferredHeight: 32
                        radius: Theme.radius
                        color: Theme.base
                        Text {
                            anchors.fill: parent
                            anchors.leftMargin: 12
                            verticalAlignment: Text.AlignVCenter
                            text: fm.cwd === fm.trashDir ? I18n.t("Trash") : fm.cwd.replace(fm.home, "~")
                            color: Theme.subtext1
                            font.family: Theme.fontFamily
                            font.pixelSize: Theme.fontSize - 1
                            elide: Text.ElideMiddle
                        }
                    }

                    // Restaurar selección (solo en la papelera)
                    Rectangle {
                        visible: fm.inTrash && fm.selCount > 0
                        Layout.preferredHeight: 32
                        Layout.preferredWidth: restLabel.implicitWidth + 24
                        radius: Theme.radius
                        color: restMa.containsMouse ? Theme.accent : Theme.surface1
                        Text {
                            id: restLabel
                            anchors.centerIn: parent
                            text: I18n.t("Restore (") + fm.selCount + ")"
                            color: restMa.containsMouse ? Theme.onAccent : Theme.text
                            font.family: Theme.fontFamily; font.pixelSize: Theme.fontSize - 2
                        }
                        MouseArea { id: restMa; anchors.fill: parent; hoverEnabled: true; cursorShape: Qt.PointingHandCursor; onClicked: fm.restorePaths(fm.selectedList()) }
                    }
                    // Vaciar papelera (dos clicks: armar + confirmar)
                    Rectangle {
                        visible: fm.inTrash
                        Layout.preferredHeight: 32
                        Layout.preferredWidth: etLabel.implicitWidth + 24
                        radius: Theme.radius
                        color: fm.emptyArmed ? Theme.red : (etMa.containsMouse ? Theme.surface2 : Theme.surface1)
                        Text {
                            id: etLabel
                            anchors.centerIn: parent
                            text: fm.emptyArmed ? I18n.t("Empty? Confirm") : I18n.t("Empty trash")
                            color: fm.emptyArmed ? Theme.base : Theme.text
                            font.family: Theme.fontFamily; font.pixelSize: Theme.fontSize - 2
                            font.bold: fm.emptyArmed
                        }
                        MouseArea { id: etMa; anchors.fill: parent; hoverEnabled: true; cursorShape: Qt.PointingHandCursor; onClicked: fm.emptyTrash() }
                    }

                    IconButton { visible: !fm.inTrash; icon: Icons.plus; onClicked: fm.newFolder() }
                    IconButton {
                        icon: fm.gridMode ? Icons.list : Icons.grid
                        onClicked: fm.gridMode = !fm.gridMode
                    }
                }
            }

            // ---- selector de ficheros del sistema ----
            Rectangle {
                visible: fm.picking
                Layout.fillWidth: true
                Layout.preferredHeight: pickRow.implicitHeight + 16
                color: Qt.alpha(Theme.accent, 0.14)
                RowLayout {
                    id: pickRow
                    anchors.left: parent.left; anchors.right: parent.right
                    anchors.verticalCenter: parent.verticalCenter
                    anchors.leftMargin: 14
                    anchors.rightMargin: 10
                    spacing: 10
                    Text {
                        text: fm.pickMode === "save" ? Icons.download : fm.pickMode === "folder" ? Icons.folder : Icons.file
                        color: Theme.accent; font.family: Theme.fontFamily; font.pixelSize: Theme.fontSize + 1
                    }
                    Text {
                        Layout.fillWidth: fm.pickMode !== "save"
                        Layout.maximumWidth: fm.pickMode === "save" ? 220 : -1
                        // El título lo pone quien pide (una app, omdrop): se traduce si es
                        // uno conocido ("Open", "Save received files to"…), si no tal cual.
                        text: fm.pickTitle !== "" ? I18n.t(fm.pickTitle)
                            : fm.pickMode === "save" ? I18n.t("Save as")
                            : fm.pickMode === "folder" ? I18n.t("Choose a folder")
                            : fm.pickMode === "files" ? I18n.t("Choose files") : I18n.t("Choose a file")
                        color: Theme.text
                        font.family: Theme.fontFamily
                        font.pixelSize: Theme.fontSize - 2
                        font.bold: true
                        elide: Text.ElideRight
                    }
                    // nombre al guardar
                    Rectangle {
                        visible: fm.pickMode === "save"
                        Layout.fillWidth: true
                        Layout.preferredHeight: 30
                        radius: Theme.radius - 2
                        color: Theme.mantle
                        border.width: 1; border.color: pickNameIn.activeFocus ? Theme.accent : Theme.surface2
                        TextInput {
                            id: pickNameIn
                            anchors.fill: parent; anchors.leftMargin: 10; anchors.rightMargin: 10
                            verticalAlignment: TextInput.AlignVCenter
                            clip: true
                            text: fm.pickName
                            onTextEdited: fm.pickName = text
                            onAccepted: fm.acceptPick()
                            color: Theme.text
                            selectionColor: Theme.accent
                            font.family: Theme.fontFamily; font.pixelSize: Theme.fontSize - 1
                            Keys.onEscapePressed: fmKeys.forceActiveFocus()
                        }
                    }
                    // filtro de la app (cicla; el último es "todos los ficheros")
                    Rectangle {
                        visible: fm.pickMode !== "folder" && fm.pickFilters.length > 0
                        Layout.preferredHeight: 28
                        Layout.preferredWidth: Math.min(200, pickFilterTxt.implicitWidth + 24)
                        radius: Theme.radius
                        color: pickFilterMa.containsMouse ? Theme.surface2 : Theme.surface1
                        Text {
                            id: pickFilterTxt
                            anchors.centerIn: parent
                            width: Math.min(implicitWidth, 176)
                            elide: Text.ElideRight
                            text: fm.pickFilter >= 0 && fm.pickFilter < fm.pickFilters.length
                                  ? fm.pickFilters[fm.pickFilter].name : I18n.t("All files")
                            color: Theme.text; font.family: Theme.fontFamily; font.pixelSize: Theme.fontSize - 2
                        }
                        MouseArea {
                            id: pickFilterMa; anchors.fill: parent; hoverEnabled: true; cursorShape: Qt.PointingHandCursor
                            onClicked: fm.pickFilter = fm.pickFilter + 1 >= fm.pickFilters.length ? -1 : fm.pickFilter + 1
                        }
                    }
                    Rectangle {
                        Layout.preferredHeight: 28
                        Layout.preferredWidth: pickNo.implicitWidth + 24
                        radius: Theme.radius
                        color: pickNoMa.containsMouse ? Theme.surface2 : Theme.surface1
                        Text { id: pickNo; anchors.centerIn: parent; text: I18n.t("Cancel"); color: Theme.text; font.family: Theme.fontFamily; font.pixelSize: Theme.fontSize - 2 }
                        MouseArea { id: pickNoMa; anchors.fill: parent; hoverEnabled: true; cursorShape: Qt.PointingHandCursor; onClicked: fm.cancelPick() }
                    }
                    Rectangle {
                        Layout.preferredHeight: 28
                        Layout.preferredWidth: pickOk.implicitWidth + 24
                        radius: Theme.radius
                        color: pickOkMa.containsMouse ? Qt.lighter(Theme.accent, 1.1) : Theme.accent
                        Text { id: pickOk; anchors.centerIn: parent; text: fm.pickAcceptLabel; color: Theme.onAccent; font.family: Theme.fontFamily; font.pixelSize: Theme.fontSize - 2; font.bold: true }
                        MouseArea { id: pickOkMa; anchors.fill: parent; hoverEnabled: true; cursorShape: Qt.PointingHandCursor; onClicked: fm.acceptPick() }
                    }
                }
            }

            // ---- eligiendo la imagen de un icono de carpeta ----
            Rectangle {
                visible: fm.pickImageFor !== ""
                Layout.fillWidth: true
                Layout.preferredHeight: 40
                color: Qt.alpha(Theme.accent, 0.14)
                RowLayout {
                    anchors.fill: parent
                    anchors.leftMargin: 14
                    anchors.rightMargin: 10
                    spacing: 10
                    Text { text: Icons.image; color: Theme.accent; font.family: Theme.fontFamily; font.pixelSize: Theme.fontSize + 1 }
                    Text {
                        Layout.fillWidth: true
                        text: I18n.t("Double-click an SVG or PNG image to use it as the icon of ")
                              + "\u201c" + fm.basename(fm.pickImageFor) + "\u201d"
                        color: Theme.text
                        font.family: Theme.fontFamily
                        font.pixelSize: Theme.fontSize - 2
                        elide: Text.ElideMiddle
                    }
                    Rectangle {
                        Layout.preferredHeight: 28
                        Layout.preferredWidth: pickCancel.implicitWidth + 24
                        radius: Theme.radius
                        color: pickCancelMa.containsMouse ? Theme.surface2 : Theme.surface1
                        Text { id: pickCancel; anchors.centerIn: parent; text: I18n.t("Cancel"); color: Theme.text; font.family: Theme.fontFamily; font.pixelSize: Theme.fontSize - 2 }
                        MouseArea { id: pickCancelMa; anchors.fill: parent; hoverEnabled: true; cursorShape: Qt.PointingHandCursor; onClicked: fm.endImagePick(true) }
                    }
                }
            }

            // ---- content ----
            Item {
                id: contentArea
                Layout.fillWidth: true
                Layout.fillHeight: true

                // LIST view (delegados pasivos: el input vive en selArea)
                ListView {
                    id: listView
                    anchors.fill: parent
                    visible: !fm.gridMode
                    clip: true
                    model: fm.entries
                    boundsBehavior: Flickable.StopAtBounds
                    delegate: Rectangle {
                        required property var modelData
                        required property int index
                        width: listView.width
                        height: 40
                        color: fm.isSelected(modelData.path) ? Qt.alpha(Theme.accent, 0.22)
                               : (selArea.hoverIdx === index ? Theme.surface0 : "transparent")
                        border.width: fm.dropTarget === modelData.path ? 2
                                      : (fm.isSelected(modelData.path) ? 1 : 0)
                        border.color: fm.dropTarget === modelData.path ? Theme.accent
                                      : Qt.alpha(Theme.accent, 0.6)
                        opacity: FileClipboard.cutSet[modelData.path] === true ? 0.5 : 1
                        RowLayout {
                            anchors.fill: parent
                            anchors.leftMargin: 14
                            anchors.rightMargin: 14
                            spacing: 12
                            FolderGlyph {
                                glyph: fm.mimeGlyph(modelData)
                                glyphColor: fm.mimeColor(modelData)
                                pixelSize: Theme.fontSize + 4
                                emblem: modelData.isDir ? FolderIcons.emblemFor(modelData.path) : null
                                Layout.preferredWidth: 24
                                horizontalAlignment: Text.AlignHCenter
                            }
                            Text {
                                Layout.fillWidth: true
                                text: modelData.name
                                color: Theme.text
                                font.family: Theme.fontFamily
                                font.pixelSize: Theme.fontSize - 1
                                elide: Text.ElideRight
                            }
                        }
                    }
                }

                // GRID view
                GridView {
                    id: gridView
                    anchors.fill: parent
                    visible: fm.gridMode
                    clip: true
                    cellWidth: Math.round(120 * fm.zoom)
                    cellHeight: Math.round(108 * fm.zoom)
                    model: fm.entries
                    boundsBehavior: Flickable.StopAtBounds
                    delegate: Item {
                        required property var modelData
                        required property int index
                        width: gridView.cellWidth
                        height: gridView.cellHeight
                        Rectangle {
                            anchors.fill: parent
                            anchors.margins: 6
                            radius: Theme.radius
                            color: fm.isSelected(modelData.path) ? Qt.alpha(Theme.accent, 0.22)
                                   : (selArea.hoverIdx === index ? Theme.surface0 : "transparent")
                            border.width: fm.dropTarget === modelData.path ? 2
                                          : (fm.isSelected(modelData.path) ? 1 : 0)
                            border.color: fm.dropTarget === modelData.path ? Theme.accent
                                          : Qt.alpha(Theme.accent, 0.6)
                            opacity: FileClipboard.cutSet[modelData.path] === true ? 0.5 : 1
                            ColumnLayout {
                                anchors.centerIn: parent
                                width: parent.width - 12
                                spacing: 6
                                FolderGlyph {
                                    Layout.alignment: Qt.AlignHCenter
                                    glyph: fm.mimeGlyph(modelData)
                                    glyphColor: fm.mimeColor(modelData)
                                    pixelSize: Math.round(44 * fm.zoom)
                                    emblem: modelData.isDir ? FolderIcons.emblemFor(modelData.path) : null
                                }
                                Text {
                                    Layout.fillWidth: true
                                    horizontalAlignment: Text.AlignHCenter
                                    text: modelData.name
                                    color: Theme.text
                                    font.family: Theme.fontFamily
                                    font.pixelSize: Theme.fontSize - 3
                                    elide: Text.ElideRight
                                    maximumLineCount: 2
                                    wrapMode: Text.Wrap
                                }
                            }
                        }
                    }
                }

                // empty state
                Text {
                    anchors.centerIn: parent
                    visible: fm.entries.length === 0
                    text: fm.inTrash ? I18n.t("The trash is empty") : I18n.t("Empty folder")
                    color: Theme.overlay2
                    font.family: Theme.fontFamily
                    font.pixelSize: Theme.fontSize
                }

                // =============== INPUT ÚNICO DE LA VISTA ===============
                // Un MouseArea encima de ambas vistas concentra selección,
                // marquee, drag-and-drop y menú contextual. La rueda pasa a la
                // vista de debajo (MouseArea sin onWheel no consume wheel).
                MouseArea {
                    id: selArea
                    anchors.fill: parent
                    hoverEnabled: true
                    preventStealing: true
                    acceptedButtons: Qt.LeftButton | Qt.RightButton | Qt.BackButton | Qt.ForwardButton
                    cursorShape: dragging ? (dragCopy ? Qt.DragCopyCursor : Qt.DragMoveCursor)
                                 : (hoverIdx >= 0 ? Qt.PointingHandCursor : Qt.ArrowCursor)

                    property int hoverIdx: -1
                    property real pressX: 0
                    property real pressY: 0
                    // ancla del marquee en coords de CONTENIDO (sobrevive al autoscroll)
                    property real pressCY: 0
                    property int pressIdx: -1
                    property bool marquee: false
                    property bool dragging: false
                    property bool dragCopy: false      // Ctrl en el drop = copiar (Nautilus)
                    property bool deferSingle: false   // click en item ya seleccionado: colapsa al soltar
                    property bool marqueeAdd: false
                    property bool cancelled: false     // Esc a mitad de gesto: ignora el resto del press
                    property bool leftHeld: false      // botón izquierdo retenido (gesto en curso)
                    property bool sawMotion: false     // motion real recibido durante el press
                    property bool lastCtrl: false      // último estado conocido de Ctrl (de eventos reales)
                    // Punto actual del gesto en coords del área. NO usar mouseX/mouseY
                    // para pintar ghost/band: en la VM (tablet SPICE) Hyprland NO
                    // entrega motion al cliente mientras el botón está pulsado, así
                    // que esas propiedades se congelan. gx/gy se alimentan de eventos
                    // reales Y de un poll de `hyprctl cursorpos` (ver curPoll).
                    property real gx: 0
                    property real gy: 0
                    // Offset global→área derivado de la POSICIÓN REAL DE LA VENTANA
                    // (hyprctl clients), nunca de las coords del evento de press: un
                    // press con coords rancias (pasa con input inyectado) calibraría
                    // un offset corrupto y el gesto operaría sobre items equivocados.
                    property real gOffX: 0
                    property real gOffY: 0
                    property bool gOffValid: false
                    property bool anchored: false      // origen re-validado contra el compositor
                    property var marqueeBase: ({})
                    // rect del marquee (coords del área)
                    property real mqX: 0
                    property real mqY: 0
                    property real mqW: 0
                    property real mqH: 0

                    function cancelDrag() {
                        marquee = false; dragging = false; deferSingle = false;
                        dragCopy = false; leftHeld = false; fm.dropTarget = ""; fm.bmInsert = -1;
                    }
                    // ---- handoff a drag Wayland REAL (cruzar el borde de la ventana) ----
                    // El gesto interno solo mueve/copia DENTRO de la ventana; en cuanto
                    // el cursor la abandona, arrancamos un drag de plataforma
                    // (wl_data_device vía QDrag) exportando text/uri-list como COPIA,
                    // que es lo que esperan apps nativas y navegadores para un drop
                    // de fichero. A partir del start_drag el drag lo PINTA Y LO ENRUTA
                    // EL COMPOSITOR, así que cruza a cualquier otra ventana;
                    // `cancelled = true` deja el resto del press interno mudo.
                    //
                    // platformDrag: handoff pedido (solo lo limpia dragFinished, para
                    // que el robo de grab del compositor no lo resetee a mitad).
                    // platformStarted: QDrag ya lanzado (guard callback vs. temporizador).
                    property bool platformDrag: false
                    property bool platformStarted: false
                    function outsideWindow(lx, ly) {
                        var wp = mapToItem(null, lx, ly);
                        return wp.x < 0 || wp.y < 0 || wp.x >= fm.width || wp.y >= fm.height;
                    }
                    function startExternalDrag() {
                        if (platformDrag) return;
                        platformDrag = true;
                        cancelled = true;
                        fm.dropTarget = "";
                        xdndProxy.Drag.mimeData = ({
                            "text/uri-list": fm.selectedList().map(fm.pathToUri).join("\r\n") + "\r\n"
                        });
                        // icono del drag = snapshot del ghost interno (async, ~1 frame).
                        // Si el grab no arranca —o su callback no llega— el guard lanza
                        // el drag igualmente sin icono: nunca se queda esperando imagen.
                        if (dragGhost.grabToImage(function(result) {
                                xdndProxy.Drag.imageSource = result.url;
                                selArea.beginPlatformDrag();
                            })) dragIconGuard.restart();
                        else beginPlatformDrag();
                    }
                    function beginPlatformDrag() {
                        if (!platformDrag || platformStarted) return;
                        platformStarted = true;
                        dragIconGuard.stop();
                        dragging = false;                   // esconde el ghost interno
                        // fuera del stack del callback de grabToImage antes de bloquear
                        Qt.callLater(activatePlatformDrag);
                    }
                    function activatePlatformDrag() {
                        // Poner `Drag.active = true` con dragType Automatic es LO QUE
                        // crea el QDrag y emite wl_data_device.start_drag (verificado
                        // con WAYLAND_DEBUG en Qt 6.11 + Hyprland). `Drag.startDrag()`
                        // SIN active previo es un no-op con warning "startDrag() drag
                        // must be active" — ese fue el bug de S60: el handoff se
                        // llamaba, pero jamás salía un drag de plataforma.
                        // La asignación BLOQUEA en un event loop anidado hasta el drop.
                        xdndProxy.Drag.active = true;
                    }
                    // Avance del gesto (marquee o drag) con un punto nuevo. Lo llaman
                    // tanto los eventos reales de motion como el poll del cursor.
                    function gestureMove(lx, ly, ctrlHeld) {
                        gx = lx; gy = ly;
                        if (!marquee && !dragging) {
                            if (Math.abs(lx - pressX) + Math.abs(ly - pressY) < 5) return;
                            if (pressIdx >= 0 && fm.selCount > 0) dragging = true;
                            else if (pressIdx < 0) marquee = true;
                        }
                        if (marquee) applyMarquee(lx, ly);
                        else if (dragging) {
                            dragCopy = ctrlHeld;
                            // ¿el cursor ha salido de la VENTANA? (el sidebar y la
                            // papelera siguen siendo destinos internos, están dentro)
                            if (outsideWindow(lx, ly)) {
                                startExternalDrag();
                                return;
                            }
                            updateDropTarget(lx, ly);
                        }
                    }
                    function onWindowPos(wx, wy) {
                        var ao = selArea.mapToItem(null, 0, 0);   // offset del área dentro de la ventana
                        gOffX = wx + ao.x; gOffY = wy + ao.y;
                        gOffValid = true;
                    }
                    function onCursorPoll(gxg, gyg) {
                        if (!leftHeld || cancelled || !gOffValid) return;
                        var lx = gxg - gOffX, ly = gyg - gOffY;
                        // Salir de la ventana durante un drag dispara el handoff SIEMPRE,
                        // incluso con motion real: el compositor siempre sabe dónde está
                        // el cursor, así que el handoff no depende de que Qt nos entregue
                        // motion fuera de la superficie. Sin coste: este poll ya corría.
                        if (dragging && outsideWindow(lx, ly)) { startExternalDrag(); return; }
                        // El resto del poll SOLO alimenta el gesto cuando el compositor
                        // retiene el motion (VM/puntero absoluto). Con motion real
                        // entregado, sobra y —con varias instancias del FM con el mismo
                        // título— podría operar con el origen de OTRA ventana.
                        if (sawMotion) return;
                        if (!anchored) {
                            // Si el press llegó con coords rancias (injection), el punto
                            // real del compositor manda: re-ancla origen e índice para
                            // que el gesto no arrastre un item que nunca se pisó.
                            if (Math.abs(lx - pressX) + Math.abs(ly - pressY) > 12) {
                                pressX = lx; pressY = ly;
                                pressCY = ly + contentYOf();
                                pressIdx = viewAt(lx, ly);
                            }
                            anchored = true;
                        }
                        gestureMove(lx, ly, lastCtrl);
                    }
                    function contentYOf() { return (fm.gridMode ? gridView : listView).contentY; }

                    function viewAt(x, y) {
                        if (x < 0 || y < 0 || x >= width || y >= height) return -1;
                        var v = fm.gridMode ? gridView : listView;
                        return v.indexAt(x + v.contentX, y + v.contentY);
                    }
                    // rect en coords del área del item i (layouts fijos: fila 40px / celda 120x108)
                    function itemRect(i) {
                        if (fm.gridMode) {
                            var cols = Math.max(1, Math.floor(gridView.width / gridView.cellWidth));
                            return { x: (i % cols) * gridView.cellWidth - gridView.contentX,
                                     y: Math.floor(i / cols) * gridView.cellHeight - gridView.contentY,
                                     w: gridView.cellWidth, h: gridView.cellHeight };
                        }
                        return { x: 0, y: i * 40 - listView.contentY, w: listView.width, h: 40 };
                    }
                    function applyMarquee(mx, my) {
                        // ancla en coords de contenido: si la vista autoscrollea, el
                        // origen del rectángulo viaja con los items (como Nautilus)
                        var py = pressCY - contentYOf();
                        mqX = Math.min(pressX, mx); mqY = Math.min(py, my);
                        mqW = Math.abs(mx - pressX); mqH = Math.abs(my - py);
                        var m = Object.assign({}, marqueeBase);
                        for (var i = 0; i < fm.entries.length; i++) {
                            var r = itemRect(i);
                            if (r.x < mqX + mqW && r.x + r.w > mqX && r.y < mqY + mqH && r.y + r.h > mqY)
                                m[fm.entries[i].path] = true;
                        }
                        fm.selection = m;
                        fm.selCount = Object.keys(m).length;
                    }
                    // Durante un drag de items: carpeta bajo el cursor en la vista,
                    // o un destino del sidebar (places/marcadores/volúmenes/papelera).
                    // Entre dos marcadores (o en el hueco vacío) el destino es
                    // "::bookmark": soltar AÑADE un marcador, nunca mueve ni copia.
                    function updateDropTarget(mx, my) {
                        fm.bmInsert = -1;
                        var i = viewAt(mx, my);
                        if (i >= 0) {
                            var e = fm.entries[i];
                            fm.dropTarget = (e.isDir && !fm.isSelected(e.path)) ? e.path : "";
                            return;
                        }
                        var tp = selArea.mapToItem(trashRow, mx, my);
                        if (tp.x >= 0 && tp.y >= 0 && tp.x < trashRow.width && tp.y < trashRow.height) {
                            fm.dropTarget = "::trash";
                            return;
                        }
                        // solo la parte VISIBLE del desplazable
                        var fp = selArea.mapToItem(sideFlick, mx, my);
                        if (fp.x < 0 || fp.y < 0 || fp.x >= sideFlick.width || fp.y >= sideFlick.height) {
                            fm.dropTarget = "";
                            return;
                        }
                        var bp = selArea.mapToItem(bmBox, mx, my);
                        if (bmBox.visible && bp.y >= -2 && bp.y <= bmBox.height + 2) {
                            var hit = fm.bookmarkHit(bp.y, true);
                            if (hit.into !== "") { fm.dropTarget = hit.into !== fm.cwd ? hit.into : ""; return; }
                            if (fm.selectionAllDirs()) { fm.dropTarget = "::bookmark"; fm.bmInsert = hit.slot; return; }
                            fm.dropTarget = "";
                            return;
                        }
                        var sp = selArea.mapToItem(sideCol, mx, my);
                        var ch = sideCol.childAt(sp.x, sp.y);
                        fm.dropTarget = (ch && ch.dropPath !== undefined && ch.dropPath !== "" && ch.dropPath !== fm.cwd) ? ch.dropPath : "";
                    }

                    onPressed: function(mouse) {
                        fmKeys.forceActiveFocus();
                        fm.ctxOpen = false;
                        // botones laterales del ratón: historial (Nautilus)
                        if (mouse.button === Qt.BackButton) { fm.goBack(); return; }
                        if (mouse.button === Qt.ForwardButton) { fm.goForward(); return; }
                        pressX = mouse.x; pressY = mouse.y;
                        pressCY = mouse.y + contentYOf();
                        pressIdx = viewAt(mouse.x, mouse.y);
                        marquee = false; dragging = false; deferSingle = false; dragCopy = false;
                        cancelled = false; sawMotion = false;
                        gx = mouse.x; gy = mouse.y;
                        gOffValid = false; anchored = false;
                        lastCtrl = (mouse.modifiers & Qt.ControlModifier) !== 0;
                        leftHeld = (mouse.button === Qt.LeftButton);
                        if (leftHeld) winPosProc.running = true;
                        fm.dropTarget = "";

                        if (mouse.button === Qt.RightButton) {
                            if (pressIdx >= 0) {
                                var p = fm.entries[pressIdx].path;
                                if (!fm.isSelected(p)) { fm.setSelectionPaths([p]); fm.anchorIndex = pressIdx; }
                            }
                            var pt = selArea.mapToItem(null, mouse.x, mouse.y);
                            fm.showCtx(pt.x, pt.y, pressIdx >= 0 ? fm.entries[pressIdx] : null);
                            return;
                        }
                        if (pressIdx < 0) {
                            marqueeAdd = (mouse.modifiers & Qt.ControlModifier) !== 0;
                            marqueeBase = marqueeAdd ? Object.assign({}, fm.selection) : ({});
                            if (!marqueeAdd) fm.clearSelection();
                            return;
                        }
                        var path = fm.entries[pressIdx].path;
                        if (mouse.modifiers & Qt.ShiftModifier) {
                            fm.selectRange(fm.anchorIndex < 0 ? pressIdx : fm.anchorIndex, pressIdx);
                        } else if (mouse.modifiers & Qt.ControlModifier) {
                            fm.toggleSelect(path);
                            fm.anchorIndex = pressIdx;
                        } else if (!fm.isSelected(path)) {
                            fm.setSelectionPaths([path]);
                            fm.anchorIndex = pressIdx;
                        } else {
                            deferSingle = true;   // ya seleccionado: puede ser drag de grupo
                        }
                    }
                    onPositionChanged: function(mouse) {
                        if (!pressed) { hoverIdx = viewAt(mouse.x, mouse.y); return; }
                        if (cancelled) return;
                        sawMotion = true;
                        lastCtrl = (mouse.modifiers & Qt.ControlModifier) !== 0;
                        gestureMove(mouse.x, mouse.y, lastCtrl);
                    }
                    // El compositor cancela el grab al arrancar el drag Wayland (y en
                    // cualquier robo de grab): estado interno siempre a limpio.
                    onCanceled: cancelDrag()
                    onReleased: function(mouse) {
                        if (mouse.button !== Qt.LeftButton) return;
                        leftHeld = false;
                        if (cancelled) { cancelled = false; return; }
                        if (dragging) {
                            var copy = (mouse.modifiers & Qt.ControlModifier) !== 0;
                            if (fm.dropTarget === "::trash") fm.trashPaths(fm.selectedList());
                            else if (fm.dropTarget === "::bookmark") fm.addToSidebar(fm.selectedList(), fm.bmInsert);
                            else if (fm.dropTarget !== "") {
                                if (copy) fm.copyPaths(fm.selectedList(), fm.dropTarget);
                                else fm.movePaths(fm.selectedList(), fm.dropTarget);
                            }
                        } else if (!marquee && deferSingle && pressIdx >= 0 && pressIdx < fm.entries.length) {
                            fm.setSelectionPaths([fm.entries[pressIdx].path]);
                            fm.anchorIndex = pressIdx;
                        }
                        cancelDrag();
                        hoverIdx = viewAt(mouse.x, mouse.y);
                    }
                    // Ctrl+rueda: zoom de la cuadrícula (Nautilus). Sin Ctrl, la
                    // rueda sigue hacia la vista de debajo (accepted = false).
                    onWheel: function(wheel) {
                        if ((wheel.modifiers & Qt.ControlModifier) && fm.gridMode) {
                            var step = wheel.angleDelta.y > 0 ? 0.1 : -0.1;
                            fm.zoom = Math.max(0.6, Math.min(1.8, fm.zoom + step));
                            wheel.accepted = true;
                        } else wheel.accepted = false;
                    }
                    onDoubleClicked: function(mouse) {
                        if (mouse.button !== Qt.LeftButton) return;
                        deferSingle = false;
                        var i = viewAt(mouse.x, mouse.y);
                        if (i >= 0) fm.open(fm.entries[i]);
                    }
                    onExited: hoverIdx = -1
                }

                // Poll del cursor global mientras hay un gesto de botón izquierdo.
                // Necesario porque en la VM (puntero absoluto SPICE) Hyprland deja
                // de entregar motion al cliente durante el grab implícito: sin esto
                // el marquee/drag solo recibe UN punto justo antes del release
                // (funcionaba la selección, pero el rectángulo nunca se veía).
                Process {
                    id: curProc
                    command: ["hyprctl", "cursorpos", "-j"]
                    stdout: StdioCollector {
                        onStreamFinished: {
                            try {
                                var p = JSON.parse(this.text);
                                selArea.onCursorPoll(p.x, p.y);
                            } catch (e) {}
                        }
                    }
                }
                // Posición global de la ventana del FM (una consulta por gesto).
                Process {
                    id: winPosProc
                    command: ["hyprctl", "clients", "-j"]
                    stdout: StdioCollector {
                        onStreamFinished: {
                            try {
                                var cs = JSON.parse(this.text);
                                // Varias instancias comparten título: elegimos la más
                                // recientemente ENFOCADA (focusHistoryID mínimo) — la
                                // del gesto, porque el press le acaba de dar el foco.
                                var best = null;
                                for (var i = 0; i < cs.length; i++) {
                                    if (cs[i].title !== fm.title) continue;
                                    if (best === null || cs[i].focusHistoryID < best.focusHistoryID) best = cs[i];
                                }
                                if (best) selArea.onWindowPos(best.at[0], best.at[1]);
                            } catch (e) {}
                        }
                    }
                }
                Timer {
                    interval: 40; repeat: true
                    running: selArea.leftHeld && !selArea.cancelled
                    onTriggered: if (!curProc.running) curProc.running = true
                }

                // Autoscroll cerca de los bordes durante marquee o drag (Nautilus).
                Timer {
                    interval: 30; repeat: true
                    running: (selArea.marquee || selArea.dragging)
                             && (selArea.gy < 28 || selArea.gy > selArea.height - 28)
                             && selArea.gx >= 0 && selArea.gx <= selArea.width
                    onTriggered: {
                        var v = fm.gridMode ? gridView : listView;
                        var maxY = Math.max(0, v.contentHeight - v.height);
                        var d = selArea.gy < 28 ? -16 : 16;
                        var ny = Math.max(0, Math.min(maxY, v.contentY + d));
                        if (ny === v.contentY) return;
                        v.contentY = ny;
                        if (selArea.marquee) selArea.applyMarquee(selArea.gx, selArea.gy);
                        else selArea.updateDropTarget(selArea.gx, selArea.gy);
                    }
                }

                // marquee: rectángulo de goma tintado con el acento del tema
                Rectangle {
                    visible: selArea.marquee
                    x: selArea.mqX; y: selArea.mqY
                    width: selArea.mqW; height: selArea.mqH
                    color: Qt.alpha(Theme.accent, 0.12)
                    border.width: 1
                    border.color: Qt.alpha(Theme.accent, 0.65)
                    radius: Theme.radius
                    z: 60
                }

                // Proxy del drag Wayland saliente: Item sin geometría al que va
                // atado el QDrag de plataforma (mimeData/imagen se rellenan en
                // startExternalDrag). Solo COPIA: el origen nunca borra nada.
                Item {
                    id: xdndProxy
                    Drag.dragType: Drag.Automatic
                    Drag.supportedActions: Qt.CopyAction
                    Drag.proposedAction: Qt.CopyAction
                    Drag.onDragFinished: {
                        selArea.platformDrag = false;
                        selArea.platformStarted = false;
                        selArea.cancelDrag();
                    }
                }
                // Red de seguridad del icono: si el callback de grabToImage no
                // llega, el drag de plataforma sale igual (sin icono) en vez de
                // quedarse a medias. One-shot por gesto, no es un poll.
                Timer {
                    id: dragIconGuard
                    interval: 120
                    onTriggered: selArea.beginPlatformDrag()
                }

                // Drops ENTRANTES de otras apps (u otra instancia del FM): un
                // text/uri-list con file:// se copia a la carpeta actual.
                DropArea {
                    anchors.fill: parent
                    keys: ["text/uri-list"]
                    onDropped: function(drop) {
                        var paths = [];
                        for (var i = 0; i < drop.urls.length; i++) {
                            var p = fm.uriToPath(drop.urls[i]);
                            // no copiarse encima: drops originados en ESTA carpeta
                            if (p !== "" && p.substring(0, p.lastIndexOf("/")) !== fm.cwd) paths.push(p);
                        }
                        if (paths.length > 0) { fm.copyPaths(paths, fm.cwd); drop.accept(Qt.CopyAction); }
                    }
                }

                // ghost del drag: sigue al cursor con el nº de items arrastrados;
                // con Ctrl (copiar) enseña un "+" verde, como el badge de Nautilus
                Rectangle {
                    id: dragGhost
                    visible: selArea.dragging
                    x: selArea.gx + 14
                    y: selArea.gy + 10
                    radius: Theme.radius
                    color: Theme.surface1
                    border.width: 1
                    border.color: selArea.dragCopy ? Theme.green : Theme.accent
                    width: ghostRow.implicitWidth + 20
                    height: ghostRow.implicitHeight + 12
                    opacity: 0.92
                    z: 50
                    RowLayout {
                        id: ghostRow
                        anchors.centerIn: parent
                        spacing: 8
                        Text {
                            visible: selArea.dragCopy
                            text: "+"
                            color: Theme.green
                            font.family: Theme.fontFamily; font.pixelSize: Theme.fontSize + 2; font.bold: true
                        }
                        Text { text: Icons.file; color: selArea.dragCopy ? Theme.green : Theme.accent; font.family: Theme.fontFamily; font.pixelSize: Theme.fontSize + 1 }
                        Text {
                            text: fm.dropTarget === "::bookmark" ? I18n.t("Add to Sidebar")
                                  : fm.selCount === 1 ? fm.basename(fm.selectedList()[0] || "") : fm.selCount + I18n.t(" items")
                            color: Theme.text
                            font.family: Theme.fontFamily
                            font.pixelSize: Theme.fontSize - 1
                        }
                    }
                }
            }

            // ---- transferencias en curso ----
            //  Van justo encima de la barra de estado, en la ventana donde se
            //  lanzaron: se ven sin buscarlas y no tapan el contenido. NO son un
            //  diálogo — se puede seguir navegando, seleccionando y lanzando más
            //  copias mientras corren, y cada una tiene su propia tarjeta.
            Repeater {
                model: jobModel
                delegate: Rectangle {
                    id: card
                    required property int index
                    required property int jobId
                    required property string kind
                    required property string destName
                    required property string phase
                    required property real total
                    required property real done
                    required property int files
                    required property int idx
                    required property string file
                    required property int copied
                    required property int skipped
                    required property int errors
                    required property int conflicts
                    required property string errMsg

                    readonly property bool live: phase === "scan" || phase === "run"
                    // -1 = todavía no se sabe cuánto hay (recuento) -> barra
                    // indeterminada, que es honesto; nada de porcentajes falsos.
                    readonly property real frac: total > 0 ? Math.max(0, Math.min(1, done / total)) : -1
                    readonly property color tint: phase === "err" ? Theme.red
                                                : phase === "warn" ? Theme.yellow
                                                : phase === "ok" ? Theme.green
                                                : phase === "note" ? Theme.blue : Theme.accent

                    Layout.fillWidth: true
                    Layout.preferredHeight: cardCol.implicitHeight + 14
                    color: Qt.rgba(card.tint.r, card.tint.g, card.tint.b, 0.12)

                    //  Lo que sale bien y sin sorpresas se quita solo a los 4 s.
                    //  Lo que tenga saltados o fallos SE QUEDA hasta que el
                    //  usuario lo cierre: eso no puede desaparecer sin que se
                    //  haya leído. Es un disparo único por tarjeta, no un sondeo.
                    Timer {
                        interval: card.phase === "note" ? 6000 : 4000
                        running: card.phase === "ok" || card.phase === "note"
                        onTriggered: fm.dismissJob(card.jobId)
                    }

                    ColumnLayout {
                        id: cardCol
                        anchors.left: parent.left; anchors.right: parent.right
                        anchors.verticalCenter: parent.verticalCenter
                        anchors.leftMargin: 14; anchors.rightMargin: 8
                        spacing: 4

                        RowLayout {
                            Layout.fillWidth: true
                            spacing: 8
                            Text {
                                Layout.fillWidth: true
                                elide: Text.ElideMiddle
                                color: Theme.text
                                font.family: Theme.fontFamily
                                font.pixelSize: Theme.fontSize - 3
                                text: {
                                    if (card.kind === "note") return card.errMsg;
                                    if (card.phase === "scan")
                                        return (card.kind === "move" ? I18n.t("Moving to ") : I18n.t("Copying to "))
                                               + card.destName + " — " + I18n.t("working out how much there is…");
                                    if (card.phase === "run") {
                                        var head = (card.kind === "move" ? I18n.t("Moving to ") : I18n.t("Copying to ")) + card.destName;
                                        if (card.files > 1) head += "  ·  " + card.idx + "/" + card.files;
                                        if (card.file !== "") head += "  ·  " + card.file;
                                        return head;
                                    }
                                    if (card.phase === "err")
                                        return I18n.t("Transfer failed") + " — " + card.errMsg;
                                    if (card.phase === "warn")
                                        return I18n.t("Finished, but some items already existed and were left alone: ") + card.skipped;
                                    return (card.kind === "move" ? I18n.t("Moved ") : I18n.t("Copied "))
                                           + card.copied + I18n.t(" to ") + card.destName;
                                }
                            }
                            Text {
                                visible: card.live && card.frac >= 0
                                color: Theme.subtext0
                                font.family: Theme.fontFamily
                                font.pixelSize: Theme.fontSize - 3
                                text: fm.fmtBytes(card.done) + " / " + fm.fmtBytes(card.total)
                                      + "   " + Math.round(card.frac * 100) + " %"
                            }
                            // "Conservar ambos": lo que se saltó por existir ya, otra
                            // vez con nombre nuevo ("foto (copia).jpg"). Nunca machaca.
                            Rectangle {
                                visible: card.phase === "warn" && card.conflicts > 0
                                Layout.preferredHeight: 24
                                Layout.preferredWidth: keepBothText.implicitWidth + 20
                                radius: Theme.radius - 2
                                color: keepBothMa.containsMouse ? Theme.surface2 : Theme.surface1
                                Text {
                                    id: keepBothText
                                    anchors.centerIn: parent
                                    text: I18n.t("Keep both")
                                    color: Theme.text
                                    font.family: Theme.fontFamily
                                    font.pixelSize: Theme.fontSize - 3
                                }
                                MouseArea { id: keepBothMa; anchors.fill: parent; hoverEnabled: true; cursorShape: Qt.PointingHandCursor; onClicked: fm.keepBoth(card.jobId) }
                            }
                            IconButton {
                                visible: !card.live
                                icon: Icons.close
                                iconColor: card.tint
                                onClicked: fm.dismissJob(card.jobId)
                            }
                        }
                        Rectangle {
                            visible: card.live
                            Layout.fillWidth: true
                            Layout.preferredHeight: 5
                            radius: 2.5
                            color: Theme.surface1
                            Rectangle {
                                height: parent.height
                                radius: parent.radius
                                width: card.frac >= 0 ? parent.width * card.frac : parent.width
                                color: card.frac >= 0 ? Theme.accent : Theme.surface2
                                Behavior on width { NumberAnimation { duration: Theme.dur(120) } }
                            }
                        }
                    }
                }
            }

            // ---- status bar ----
            Rectangle {
                Layout.fillWidth: true
                Layout.preferredHeight: 26
                color: Theme.surface0
                Text {
                    anchors.fill: parent
                    anchors.leftMargin: 14
                    verticalAlignment: Text.AlignVCenter
                    text: {
                        var s = fm.entries.length + I18n.t(" items");
                        if (fm.selCount === 1) s += "  •  " + fm.basename(fm.selectedList()[0] || "");
                        else if (fm.selCount > 1) s += "  •  " + fm.selCount + I18n.t(" selected");
                        if (FileClipboard.paths.length)
                            s += "  •  " + FileClipboard.paths.length + (FileClipboard.mode === "cut" ? I18n.t(" to move") : I18n.t(" to copy"));
                        return s;
                    }
                    color: Theme.subtext0
                    font.family: Theme.fontFamily
                    font.pixelSize: Theme.fontSize - 3
                }
            }
        }
    }

    // ---- teclado (Esc sube un nivel, Supr a papelera, F2 renombra, etc.) ----
    Item {
        id: fmKeys
        focus: true
        Keys.onPressed: function(event) {
            if (fm.remoteFormOpen || fm.renameOpen || fm.iconPickOpen || fm.delOpen || fm.fmtOpen) return;
            if (fm.propOpen) {
                if (event.key === Qt.Key_Escape || event.key === Qt.Key_Return) { fm.propOpen = false; event.accepted = true; }
                return;
            }
            var ctrl = (event.modifiers & Qt.ControlModifier) !== 0;
            if (event.key === Qt.Key_Escape) {
                if (selArea.dragging || selArea.marquee) {                       // cancela el drag (Nautilus)
                    if (selArea.marquee) {                                        // el band vuelve a la selección previa
                        fm.selection = Object.assign({}, selArea.marqueeBase);
                        fm.selCount = Object.keys(fm.selection).length;
                    }
                    selArea.cancelled = selArea.pressed;
                    selArea.cancelDrag();
                }
                else if (fm.ctxOpen) fm.ctxOpen = false;
                else if (fm.pickImageFor !== "") fm.endImagePick(true);
                else if (fm.selCount > 0) fm.clearSelection();
                else if (fm.picking) fm.cancelPick();
                else fm.goUp();
                event.accepted = true;
            } else if (event.key === Qt.Key_Delete) {
                var l = fm.selectedList();
                if (l.length) {
                    if (fm.inTrash) fm.deleteForeverPaths(l);
                    else if (event.modifiers & Qt.ShiftModifier) { fm.clearSelection(); fm.askDeleteForever(l, "shift", ""); }  // Mayús+Supr (Nautilus)
                    else fm.trashPaths(l);
                }
                event.accepted = true;
            } else if (event.key === Qt.Key_F2) {
                fm.startRename(); event.accepted = true;
            } else if (event.key === Qt.Key_Backspace) {
                fm.goBack(); event.accepted = true;
            } else if (ctrl && (event.modifiers & Qt.ShiftModifier) && event.key === Qt.Key_N) {
                fm.newFolder(); event.accepted = true;            // Ctrl+Shift+N (Nautilus)
            } else if (ctrl && event.key === Qt.Key_A) {
                fm.selectAll(); event.accepted = true;
            } else if (ctrl && event.key === Qt.Key_H) {
                fm.showHidden = !fm.showHidden; fm.refresh(); event.accepted = true;
            } else if (ctrl && event.key === Qt.Key_C) {
                fm.copySelected(); event.accepted = true;
            } else if (ctrl && event.key === Qt.Key_X) {
                fm.cutSelected(); event.accepted = true;
            } else if (ctrl && event.key === Qt.Key_V) {
                if (!fm.inTrash) fm.paste(fm.cwd); event.accepted = true;
            } else if (ctrl && event.key === Qt.Key_D) {
                // Ctrl+D (Nautilus): la carpeta seleccionada —o esta— a la barra lateral
                if (!fm.inTrash) fm.addToSidebar(fm.selCount > 0 ? fm.selectedList() : [fm.cwd]);
                event.accepted = true;
            } else if ((event.key === Qt.Key_Return || event.key === Qt.Key_Enter) && fm.picking
                       && (fm.pickMode === "folder" || fm.pickMode === "save" || fm.selCount > 1)) {
                // selector: Intro = aceptar (con un solo fichero, abrirlo ya lo elige)
                var one = fm.selectedList();
                if (fm.pickMode === "folder" && one.length === 1) {
                    for (var k = 0; k < fm.entries.length; k++)
                        if (fm.entries[k].path === one[0] && fm.entries[k].isDir && fm.entries[k].path !== fm.cwd) { fm.navigate(one[0]); one = null; break; }
                }
                if (one !== null) fm.acceptPick();
                event.accepted = true;
            } else if (event.key === Qt.Key_Return || event.key === Qt.Key_Enter) {
                var s = fm.selectedList();
                if (s.length === 1)
                    for (var i = 0; i < fm.entries.length; i++)
                        if (fm.entries[i].path === s[0]) { fm.open(fm.entries[i]); break; }
                event.accepted = true;
            }
        }
    }

    // ---- context menu ----
    MouseArea {
        anchors.fill: parent
        visible: fm.ctxOpen
        acceptedButtons: Qt.LeftButton | Qt.RightButton
        onPressed: fm.ctxOpen = false
    }
    Card {
        visible: fm.ctxOpen
        x: Math.max(8, Math.min(fm.ctxX, fm.width - width - 8))
        y: Math.max(8, Math.min(fm.ctxY, fm.height - height - 8))
        // tan ancho como la etiqueta más larga (en español las hay largas)
        width: Math.max(210, menuCol.implicitWidth + 8)
        implicitHeight: menuCol.implicitHeight + 8
        color: Theme.surface1
        radius: Theme.radius
        z: 100

        ColumnLayout {
            id: menuCol
            anchors.fill: parent
            anchors.margins: 4
            spacing: 0
            Repeater {
                model: {
                    var n = Math.max(1, fm.selCount);
                    var suf = n > 1 ? " (" + n + ")" : "";
                    var clipN = FileClipboard.paths.length;
                    var pasteLabel = clipN ? I18n.t("Paste (") + clipN + ")" : I18n.t("Paste");
                    // dispositivo de la barra lateral
                    if (fm.ctxDrive) {
                        var dv = [];
                        if (fm.ctxDrive.dev !== "") {
                            dv.push({ label: I18n.t("Open"), act: "drvopen" });
                            if (fm.ctxDrive.mount !== "") dv.push({ label: I18n.t("Unmount"), act: "drvunmount" });
                        }
                        dv.push({ label: I18n.t("Format drive…"), act: "drvformat", danger: true });
                        return dv;
                    }
                    // fila de la barra lateral
                    if (fm.ctxSide) {
                        var sd = fm.ctxSide, side = [];
                        if (!sd.missing) {
                            side.push({ label: I18n.t("Open"), act: "sideopen" });
                            side.push({ label: I18n.t("Customize Folder Icon…"), act: "sideicon" });
                        }
                        if (sd.bookmark) {
                            if (sd.index > 0) side.push({ label: I18n.t("Move up"), act: "bmup" });
                            if (sd.index < Places.bookmarks.length - 1) side.push({ label: I18n.t("Move down"), act: "bmdown" });
                            side.push({ label: I18n.t("Remove from Sidebar"), act: "bmremove" });
                        }
                        return side;
                    }
                    if (fm.inTrash) {
                        if (fm.ctxEntry) return [
                            { label: I18n.t("Restore") + suf, act: "restore" },
                            { label: I18n.t("Delete permanently") + suf, act: "delforever", danger: true }
                        ];
                        return [{ label: I18n.t("Empty trash"), act: "emptytrash", danger: true }];
                    }
                    if (!fm.ctxEntry) {
                        var bg = [{ label: I18n.t("New folder"), act: "newfolder" },
                                  { label: I18n.t("New file"), act: "newfile" }];
                        bg.push({ label: pasteLabel, act: "paste", disabled: clipN === 0 });
                        bg.push({ label: I18n.t("Select all"), act: "selectall" });
                        bg.push({ label: fm.showHidden ? I18n.t("Hide hidden files") : I18n.t("Show hidden files"), act: "togglehidden" });
                        if (!Places.inSidebar(fm.cwd)) bg.push({ label: I18n.t("Add to Sidebar"), act: "bookmarkcwd" });
                        bg.push({ label: I18n.t("Customize Folder Icon…"), act: "foldericon" });
                        bg.push({ label: I18n.t("Properties"), act: "props" });
                        return bg;
                    }
                    var isDir = fm.ctxEntry.isDir;
                    var items = [];
                    if (n === 1) {
                        items.push({ label: I18n.t("Open"), act: "open" });
                        items.push({ label: I18n.t("Rename"), act: "rename" });
                    }
                    items.push({ label: I18n.t("Cut") + suf, act: "cut" });
                    items.push({ label: I18n.t("Copy") + suf, act: "copy" });
                    if (n === 1 && isDir)
                        items.push({ label: I18n.t("Paste into Folder"), act: "pasteinto", disabled: clipN === 0 });
                    if (n === 1) {
                        if (/\.zip$/i.test(fm.ctxEntry.name)) items.push({ label: I18n.t("Extract here"), act: "extract" });
                        else items.push({ label: I18n.t("Compress to .zip"), act: "compress" });
                    }
                    // carpetas: barra lateral e icono (un marcador es solo una
                    // línea en el fichero de marcadores: quitarlo no toca nada)
                    if (n === 1 && isDir) {
                        if (Places.isBookmarked(fm.ctxEntry.path)) items.push({ label: I18n.t("Remove from Sidebar"), act: "unbookmark" });
                        else if (!Places.isBuiltin(fm.ctxEntry.path)) items.push({ label: I18n.t("Add to Sidebar"), act: "bookmark" });
                        items.push({ label: I18n.t("Customize Folder Icon…"), act: "foldericon" });
                    } else if (n > 1 && fm.selectionAllDirs()) {
                        items.push({ label: I18n.t("Add to Sidebar") + suf, act: "bookmark" });
                    }
                    items.push({ label: I18n.t("Properties") + suf, act: "props" });
                    var allExt = true, tgt = fm.selCount > 0 ? fm.selectedList() : [fm.ctxEntry.path];
                    for (var x = 0; x < tgt.length; x++) if (!Drives.contains(tgt[x])) allExt = false;
                    items.push({ label: (allExt ? I18n.t("Delete permanently") : I18n.t("Move to Trash")) + suf, act: "trash", danger: true });
                    return items;
                }
                delegate: Rectangle {
                    required property var modelData
                    Layout.fillWidth: true
                    Layout.preferredHeight: 32
                    implicitWidth: itemLabel.implicitWidth + 28
                    radius: Theme.radius - 2
                    color: im.containsMouse && !modelData.disabled ? Theme.surface2 : "transparent"
                    Text {
                        id: itemLabel
                        anchors.fill: parent
                        anchors.leftMargin: 12
                        verticalAlignment: Text.AlignVCenter
                        text: modelData.label
                        color: modelData.disabled ? Theme.overlay1 : (modelData.danger ? Theme.red : Theme.text)
                        font.family: Theme.fontFamily
                        font.pixelSize: Theme.fontSize - 1
                    }
                    MouseArea {
                        id: im
                        anchors.fill: parent
                        hoverEnabled: true
                        enabled: !modelData.disabled
                        cursorShape: Qt.PointingHandCursor
                        onClicked: {
                            // DIFERIR la acción: mutar aquí estado del que
                            // depende el model del Repeater (showHidden,
                            // selección, clipboard…) re-evalúa el menú y
                            // destruye ESTE delegate en mitad del handler —
                            // todo lo posterior muere con "ReferenceError:
                            // fm is not defined" (p.ej. el refresh() de
                            // togglehidden nunca corría). Qt.callLater
                            // ejecuta la acción fuera de la vida del delegate.
                            var act = modelData.act;
                            var e = fm.ctxEntry;
                            var side = fm.ctxSide;
                            var drv = fm.ctxDrive;
                            var sel = fm.selectedList();
                            fm.ctxOpen = false;
                            Qt.callLater(function() { fm.ctxAction(act, e, sel, side, drv); });
                        }
                    }
                }
            }
        }
    }

    // ---- diálogo "Personalizar icono de carpeta" ----
    Rectangle {
        anchors.fill: parent
        visible: fm.iconPickOpen
        color: "#000000"
        opacity: fm.iconPickOpen ? 0.5 : 0
        Behavior on opacity { NumberAnimation { duration: Theme.dur(120) } }
        MouseArea { anchors.fill: parent; onClicked: fm.iconPickOpen = false }
    }
    Loader {
        anchors.centerIn: parent
        active: fm.iconPickOpen
        z: 210
        sourceComponent: FolderIconPicker {
            path: fm.iconPickPath
            maxWidth: fm.width - 40
            maxHeight: fm.height - 40
            onCloseRequested: fm.iconPickOpen = false
            onChooseImage: fm.startImagePick(fm.iconPickPath)
        }
    }

    // ---- diálogo de renombrar ----
    Rectangle {
        anchors.fill: parent
        visible: fm.renameOpen
        color: "#000000"
        opacity: fm.renameOpen ? 0.5 : 0
        Behavior on opacity { NumberAnimation { duration: Theme.dur(120) } }
        MouseArea { anchors.fill: parent; onClicked: fm.renameOpen = false }
    }
    Loader {
        anchors.centerIn: parent
        active: fm.renameOpen
        sourceComponent: renameCmp
        z: 210
    }
    Component {
        id: renameCmp
        Card {
            width: 380
            implicitHeight: renCol.implicitHeight + 40
            color: Theme.base
            radius: Theme.radius + 4
            MouseArea { anchors.fill: parent }  // swallow clicks

            ColumnLayout {
                id: renCol
                anchors.fill: parent
                anchors.margins: 20
                spacing: 12

                RowLayout {
                    Layout.fillWidth: true
                    Text {
                        text: fm.nameMode === "newfolder" ? Icons.folder : fm.nameMode === "newfile" ? Icons.file : Icons.pencil
                        color: Theme.accent; font.family: Theme.fontFamily; font.pixelSize: Theme.fontSize + 3
                    }
                    Text {
                        Layout.fillWidth: true
                        text: fm.nameMode === "newfolder" ? I18n.t("New folder") : fm.nameMode === "newfile" ? I18n.t("New file") : I18n.t("Rename")
                        color: Theme.text; font.family: Theme.fontFamily; font.pixelSize: Theme.fontSize + 2; font.bold: true
                    }
                    IconButton { icon: Icons.close; onClicked: fm.renameOpen = false }
                }

                Rectangle {
                    Layout.fillWidth: true
                    Layout.preferredHeight: 36
                    radius: Theme.radius
                    color: Theme.surface0
                    border.width: renIn.activeFocus ? 1 : 0
                    border.color: Theme.accent
                    TextInput {
                        id: renIn
                        anchors.fill: parent
                        anchors.leftMargin: 12
                        anchors.rightMargin: 12
                        verticalAlignment: TextInput.AlignVCenter
                        clip: true
                        color: Theme.text
                        font.family: Theme.fontFamily
                        font.pixelSize: Theme.fontSize
                        selectionColor: Theme.accent
                        text: fm.renameText
                        onTextChanged: { fm.renameText = text; fm.nameError = ""; }
                        Keys.onPressed: function(ev) {
                            if (ev.key === Qt.Key_Escape) { fm.renameOpen = false; ev.accepted = true; }
                        }
                        onAccepted: fm.submitRename()
                        Component.onCompleted: {
                            forceActiveFocus();
                            // preselecciona el nombre sin la extensión (una carpeta, entero)
                            var dot = fm.nameMode === "newfolder" ? -1 : text.lastIndexOf(".");
                            select(0, dot > 0 ? dot : text.length);
                        }
                    }
                }
                Text {
                    Layout.fillWidth: true
                    visible: fm.nameError !== ""
                    text: fm.nameError
                    color: Theme.red
                    wrapMode: Text.WordWrap
                    font.family: Theme.fontFamily
                    font.pixelSize: Theme.fontSize - 2
                }

                RowLayout {
                    Layout.fillWidth: true
                    spacing: 10
                    Item { Layout.fillWidth: true }
                    Rectangle {
                        Layout.preferredWidth: 100; Layout.preferredHeight: 36
                        radius: Theme.radius
                        color: renCancelMa.containsMouse ? Theme.surface2 : Theme.surface1
                        Text { anchors.centerIn: parent; text: I18n.t("Cancel"); color: Theme.text; font.family: Theme.fontFamily; font.pixelSize: Theme.fontSize - 1 }
                        MouseArea { id: renCancelMa; anchors.fill: parent; hoverEnabled: true; cursorShape: Qt.PointingHandCursor; onClicked: fm.renameOpen = false }
                    }
                    Rectangle {
                        Layout.preferredWidth: 110; Layout.preferredHeight: 36
                        radius: Theme.radius
                        color: renOkMa.containsMouse ? Theme.accent2 : Theme.accent
                        Text { anchors.centerIn: parent; text: fm.nameMode === "rename" ? I18n.t("Rename") : I18n.t("Create"); color: Theme.onAccent; font.family: Theme.fontFamily; font.pixelSize: Theme.fontSize - 1; font.bold: true }
                        MouseArea { id: renOkMa; anchors.fill: parent; hoverEnabled: true; cursorShape: Qt.PointingHandCursor; onClicked: fm.submitRename() }
                    }
                }
            }
        }
    }

    // ---- diálogo de borrar definitivamente ----
    Rectangle {
        anchors.fill: parent
        visible: fm.delOpen
        color: "#000000"
        opacity: fm.delOpen ? 0.5 : 0
        Behavior on opacity { NumberAnimation { duration: Theme.dur(120) } }
        MouseArea { anchors.fill: parent; onClicked: fm.delOpen = false }
    }
    Loader {
        anchors.centerIn: parent
        active: fm.delOpen
        sourceComponent: delCmp
        z: 210
    }
    Component {
        id: delCmp
        Card {
            width: 420
            implicitHeight: delCol.implicitHeight + 40
            color: Theme.base
            radius: Theme.radius + 4
            MouseArea { anchors.fill: parent }  // swallow clicks
            // Intro borra, Esc cancela
            focus: true
            Component.onCompleted: forceActiveFocus()
            Keys.onPressed: function(ev) {
                if (ev.key === Qt.Key_Escape) { fm.delOpen = false; ev.accepted = true; }
                else if (ev.key === Qt.Key_Return || ev.key === Qt.Key_Enter) { fm.confirmDeleteForever(); ev.accepted = true; }
            }

            ColumnLayout {
                id: delCol
                anchors.fill: parent
                anchors.margins: 20
                spacing: 12
                readonly property int n: fm.delPaths.length
                readonly property string one: n === 1 ? "“" + fm.basename(fm.delPaths[0]) + "”" : ""

                RowLayout {
                    Layout.fillWidth: true
                    Text { text: Icons.trash; color: Theme.red; font.family: Theme.fontFamily; font.pixelSize: Theme.fontSize + 3 }
                    Text { Layout.fillWidth: true; text: I18n.t("Delete permanently?"); color: Theme.text; font.family: Theme.fontFamily; font.pixelSize: Theme.fontSize + 2; font.bold: true }
                    IconButton { icon: Icons.close; onClicked: fm.delOpen = false }
                }
                Text {
                    Layout.fillWidth: true
                    wrapMode: Text.WordWrap
                    color: Theme.text
                    font.family: Theme.fontFamily
                    font.pixelSize: Theme.fontSize - 1
                    text: fm.delReason === "external"
                          ? (delCol.n === 1
                             ? I18n.t("%1 is on an external drive (%2). Files deleted there do not go to the Trash: they are deleted permanently.").arg(delCol.one).arg(fm.delDrive)
                             : I18n.t("%1 items are on an external drive (%2). Files deleted there do not go to the Trash: they are deleted permanently.").arg(delCol.n).arg(fm.delDrive))
                        : fm.delReason === "notrash"
                          ? (delCol.n === 1
                             ? I18n.t("%1 cannot be moved to the Trash: its drive has no trash folder you can use. Delete it permanently?").arg(delCol.one)
                             : I18n.t("%1 items cannot be moved to the Trash: their drive has no trash folder you can use. Delete them permanently?").arg(delCol.n))
                        : (delCol.n === 1
                           ? I18n.t("%1 will be deleted permanently.").arg(delCol.one)
                           : I18n.t("%1 items will be deleted permanently.").arg(delCol.n))
                }
                Text {
                    Layout.fillWidth: true
                    text: I18n.t("This cannot be undone.")
                    color: Theme.red
                    font.family: Theme.fontFamily
                    font.pixelSize: Theme.fontSize - 2
                }
                RowLayout {
                    Layout.fillWidth: true
                    spacing: 10
                    Item { Layout.fillWidth: true }
                    Rectangle {
                        Layout.preferredWidth: 100; Layout.preferredHeight: 36
                        radius: Theme.radius
                        color: delCancelMa.containsMouse ? Theme.surface2 : Theme.surface1
                        Text { anchors.centerIn: parent; text: I18n.t("Cancel"); color: Theme.text; font.family: Theme.fontFamily; font.pixelSize: Theme.fontSize - 1 }
                        MouseArea { id: delCancelMa; anchors.fill: parent; hoverEnabled: true; cursorShape: Qt.PointingHandCursor; onClicked: fm.delOpen = false }
                    }
                    Rectangle {
                        Layout.preferredWidth: delOkTxt.implicitWidth + 28; Layout.preferredHeight: 36
                        radius: Theme.radius
                        color: delOkMa.containsMouse ? Qt.lighter(Theme.red, 1.15) : Theme.red
                        Text { id: delOkTxt; anchors.centerIn: parent; text: I18n.t("Delete permanently"); color: Theme.onAccent; font.family: Theme.fontFamily; font.pixelSize: Theme.fontSize - 1; font.bold: true }
                        MouseArea { id: delOkMa; anchors.fill: parent; hoverEnabled: true; cursorShape: Qt.PointingHandCursor; onClicked: fm.confirmDeleteForever() }
                    }
                }
            }
        }
    }

    // ---- diálogo de formatear una unidad ----
    Rectangle {
        anchors.fill: parent
        visible: fm.fmtOpen
        color: "#000000"
        opacity: fm.fmtOpen ? 0.5 : 0
        Behavior on opacity { NumberAnimation { duration: Theme.dur(120) } }
        MouseArea { anchors.fill: parent; onClicked: if (fmtLoader.item) fmtLoader.item.close() }
    }
    Loader {
        id: fmtLoader
        anchors.centerIn: parent
        active: fm.fmtOpen
        z: 210
        sourceComponent: DriveFormatDialog {
            disk: fm.fmtDisk
            startLabel: fm.fmtLabel
            onCloseRequested: fm.fmtOpen = false
            onStarting: fm.leaveDisk(fm.fmtDisk)
            onFormatted: function(dev, obj, label) { fm.driveFormatted(dev, obj, label); }
        }
    }

    // ---- diálogo de propiedades ----
    Rectangle {
        anchors.fill: parent
        visible: fm.propOpen
        color: "#000000"
        opacity: fm.propOpen ? 0.5 : 0
        Behavior on opacity { NumberAnimation { duration: Theme.dur(120) } }
        MouseArea { anchors.fill: parent; onClicked: fm.propOpen = false }
    }
    Loader {
        anchors.centerIn: parent
        active: fm.propOpen
        z: 210
        sourceComponent: Card {
            width: 420
            implicitHeight: propCol.implicitHeight + 40
            color: Theme.base
            radius: Theme.radius + 4
            MouseArea { anchors.fill: parent }  // swallow clicks

            ColumnLayout {
                id: propCol
                anchors.fill: parent
                anchors.margins: 20
                spacing: 12

                RowLayout {
                    Layout.fillWidth: true
                    Text { text: Icons.info; color: Theme.accent; font.family: Theme.fontFamily; font.pixelSize: Theme.fontSize + 3 }
                    Text {
                        Layout.fillWidth: true
                        text: fm.propTitle
                        color: Theme.text
                        font.family: Theme.fontFamily; font.pixelSize: Theme.fontSize + 2; font.bold: true
                        elide: Text.ElideMiddle
                    }
                    IconButton { icon: Icons.close; onClicked: fm.propOpen = false }
                }

                Repeater {
                    model: fm.propRows
                    delegate: RowLayout {
                        required property var modelData
                        Layout.fillWidth: true
                        spacing: 12
                        Text {
                            Layout.preferredWidth: 110
                            text: modelData.k
                            color: Theme.overlay2
                            font.family: Theme.fontFamily; font.pixelSize: Theme.fontSize - 1
                        }
                        Text {
                            Layout.fillWidth: true
                            text: modelData.v
                            color: Theme.text
                            font.family: Theme.fontFamily; font.pixelSize: Theme.fontSize - 1
                            elide: Text.ElideMiddle
                        }
                    }
                }

                RowLayout {
                    Layout.fillWidth: true
                    Item { Layout.fillWidth: true }
                    Rectangle {
                        Layout.preferredWidth: 100; Layout.preferredHeight: 36
                        radius: Theme.radius
                        color: propCloseMa.containsMouse ? Theme.accent2 : Theme.accent
                        Text { anchors.centerIn: parent; text: I18n.t("Close"); color: Theme.onAccent; font.family: Theme.fontFamily; font.pixelSize: Theme.fontSize - 1; font.bold: true }
                        MouseArea { id: propCloseMa; anchors.fill: parent; hoverEnabled: true; cursorShape: Qt.PointingHandCursor; onClicked: fm.propOpen = false }
                    }
                }
            }
        }
    }

    // ---- SFTP connection form ----
    Rectangle {
        anchors.fill: parent
        visible: fm.remoteFormOpen
        color: "#000000"
        opacity: fm.remoteFormOpen ? 0.5 : 0
        Behavior on opacity { NumberAnimation { duration: Theme.dur(120) } }
        MouseArea { anchors.fill: parent; onClicked: fm.remoteFormOpen = false }
    }
    Loader {
        anchors.centerIn: parent
        active: fm.remoteFormOpen
        sourceComponent: remoteFormCmp
    }
    Component {
        id: remoteFormCmp
        Card {
            width: 420
            implicitHeight: formCol.implicitHeight + 40
            color: Theme.base
            radius: Theme.radius + 4
            z: 200
            MouseArea { anchors.fill: parent }  // swallow clicks

            ColumnLayout {
                id: formCol
                anchors.fill: parent
                anchors.margins: 20
                spacing: 12

                RowLayout {
                    Layout.fillWidth: true
                    Text { text: Icons.ethernet; color: Theme.accent; font.family: Theme.fontFamily; font.pixelSize: Theme.fontSize + 3 }
                    Text { Layout.fillWidth: true; text: I18n.t("Remote connection (SFTP)"); color: Theme.text; font.family: Theme.fontFamily; font.pixelSize: Theme.fontSize + 2; font.bold: true }
                    IconButton { icon: Icons.close; onClicked: fm.remoteFormOpen = false }
                }

                Repeater {
                    model: [
                        { key: "fName", label: I18n.t("Name"),       ph: I18n.t("My server"),    pw: false },
                        { key: "fHost", label: I18n.t("Host"),         ph: "192.168.1.10",   pw: false },
                        { key: "fPort", label: I18n.t("Port"),       ph: "22",             pw: false },
                        { key: "fUser", label: I18n.t("User"),      ph: I18n.t("user"),        pw: false },
                        { key: "fPass", label: I18n.t("Password"),   ph: "••••••••",       pw: true  },
                        { key: "fPath", label: I18n.t("Remote path"),  ph: "/home/user",  pw: false }
                    ]
                    delegate: ColumnLayout {
                        required property var modelData
                        Layout.fillWidth: true
                        spacing: 3
                        Text { text: modelData.label; color: Theme.subtext1; font.family: Theme.fontFamily; font.pixelSize: Theme.fontSize - 2 }
                        Rectangle {
                            Layout.fillWidth: true
                            Layout.preferredHeight: 36
                            radius: Theme.radius
                            color: Theme.surface0
                            border.width: fieldIn.activeFocus ? 1 : 0
                            border.color: Theme.accent
                            TextInput {
                                id: fieldIn
                                anchors.fill: parent
                                anchors.leftMargin: 12
                                anchors.rightMargin: 12
                                verticalAlignment: TextInput.AlignVCenter
                                clip: true
                                color: Theme.text
                                font.family: Theme.fontFamily
                                font.pixelSize: Theme.fontSize
                                selectionColor: Theme.accent
                                echoMode: modelData.pw ? TextInput.Password : TextInput.Normal
                                text: fm[modelData.key]
                                onTextChanged: fm[modelData.key] = text
                                Text {
                                    anchors.verticalCenter: parent.verticalCenter
                                    visible: fieldIn.text === ""
                                    text: modelData.ph
                                    color: Theme.overlay1
                                    font: fieldIn.font
                                }
                            }
                        }
                    }
                }

                Text {
                    Layout.fillWidth: true
                    visible: fm.remoteError !== ""
                    text: fm.remoteError
                    color: Theme.red
                    wrapMode: Text.WordWrap
                    font.family: Theme.fontFamily
                    font.pixelSize: Theme.fontSize - 2
                }

                RowLayout {
                    Layout.fillWidth: true
                    Layout.topMargin: 4
                    spacing: 10
                    Item { Layout.fillWidth: true }
                    Rectangle {
                        Layout.preferredWidth: 100; Layout.preferredHeight: 38
                        radius: Theme.radius
                        color: cancelMa.containsMouse ? Theme.surface2 : Theme.surface1
                        Text { anchors.centerIn: parent; text: I18n.t("Cancel"); color: Theme.text; font.family: Theme.fontFamily; font.pixelSize: Theme.fontSize }
                        MouseArea { id: cancelMa; anchors.fill: parent; hoverEnabled: true; cursorShape: Qt.PointingHandCursor; onClicked: fm.remoteFormOpen = false }
                    }
                    Rectangle {
                        Layout.preferredWidth: 120; Layout.preferredHeight: 38
                        radius: Theme.radius
                        color: fm.remoteBusy ? Theme.surface2 : (connMa.containsMouse ? Theme.accent2 : Theme.accent)
                        Text { anchors.centerIn: parent; text: fm.remoteBusy ? I18n.t("Connecting…") : I18n.t("Connect"); color: Theme.onAccent; font.family: Theme.fontFamily; font.pixelSize: Theme.fontSize; font.bold: true }
                        MouseArea { id: connMa; anchors.fill: parent; enabled: !fm.remoteBusy; hoverEnabled: true; cursorShape: Qt.PointingHandCursor; onClicked: fm.submitRemote() }
                    }
                }
            }
        }
    }
}
