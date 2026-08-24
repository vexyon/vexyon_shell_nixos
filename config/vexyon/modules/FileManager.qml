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
//  drag-and-drop para mover, cortar/copiar/pegar y renombrar.
//  A real toplevel window (not an overlay).
// ============================================================================
FloatingWindow {
    id: fm
    // Instancia dinámica: shell.qml crea una NUEVA por cada Super+E
    // (fmFactory.createObject). Nace visible y se autodestruye al cerrarse.
    visible: true
    title: "Vexyon Files"
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
    readonly property string trashRoot: home + "/.local/share/Trash"
    readonly property string trashDir: trashRoot + "/files"
    readonly property bool inTrash: cwd === trashDir || cwd.indexOf(trashDir + "/") === 0

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
        var p = fm.cwd.replace(/\/+$/, "");
        var parent = p.substring(0, p.lastIndexOf("/"));
        if (parent === "") parent = "/";
        navigate(parent);
    }
    function refresh() { lister.running = true; }

    // Acciones del menú contextual. Vive en el ROOT (no en el delegate del
    // menú) para que la acción sobreviva a la destrucción del delegate que
    // la disparó — ver el comentario del onClicked del menú.
    function ctxAction(act, e, sel) {
        switch (act) {
        case "open":       fm.open(e); break;
        case "rename":     fm.startRename(); break;
        case "cut":        fm.cutSelected(); break;
        case "copy":       fm.copySelected(); break;
        case "paste":      fm.paste(); break;
        case "extract":    fm.extract(e.path); break;
        case "compress":   fm.compress(e.path); break;
        case "trash":      fm.trashPaths(sel.length ? sel : [e.path]); break;
        case "restore":    fm.restorePaths(sel.length ? sel : [e.path]); break;
        case "delforever": fm.deleteForeverPaths(sel.length ? sel : [e.path]); break;
        case "emptytrash": fm.emptyArmed = true; fm.emptyTrash(); break;
        case "newfolder":  fm.newFolder(); break;
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
        onExited: fm.refresh()
        stdout: StdioCollector {}
        stderr: StdioCollector {
            onStreamFinished: if (this.text.trim() !== "") console.warn("[FileManager] op:", this.text.trim())
        }
    }
    function fmtBytes(b) {
        if (!b || b <= 0) return "0 B";
        var u = ["B", "KiB", "MiB", "GiB", "TiB"], i = 0, v = b;
        while (v >= 1024 && i < u.length - 1) { v /= 1024; i++; }
        return (i === 0 || v >= 10 ? Math.round(v) : v.toFixed(1)) + " " + u[i];
    }

    function runOp(script) {
        opProc.command = ["bash", "-c", script];
        opProc.running = true;
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
    }

    //  kind = "copy" | "move".  Devuelve false si no había nada que hacer.
    function startXfer(kind, paths, destDir) {
        var use = [];
        for (var i = 0; i < paths.length; i++) {
            var p = paths[i];
            if (p === destDir || destDir.indexOf(p + "/") === 0) continue;   // dentro de sí mismo
            if (kind === "move" && p.substring(0, p.lastIndexOf("/")) === destDir) continue;
            use.push(p);
        }
        if (!use.length) return false;
        var id = ++fm._jobSeq;
        var cmd = [fm.xferBin, kind, destDir];
        for (var k = 0; k < use.length; k++) cmd.push(use[k]);
        fm._jobCmd[id] = cmd;
        jobModel.append({ jobId: id, kind: kind, destName: fm.basename(destDir) || "/",
                          phase: "scan", total: 0, done: 0, files: 0, idx: 0,
                          file: "", copied: 0, skipped: 0, errors: 0, errMsg: "" });
        return true;
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
        case "@@ERR":
            jobModel.setProperty(r, "errors", jobModel.get(r).errors + 1);
            if (jobModel.get(r).errMsg === "")
                jobModel.setProperty(r, "errMsg", (f[1] || "") + ": " + (f[2] || ""));
            break;
        case "@@DONE":
            jobModel.setProperty(r, "copied", parseInt(f[1], 10) || 0);
            break;
        }
    }
    function _jobExit(id, code) {
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
        fm.refresh();
    }

    //  Un proceso por trabajo. El Instantiator solo crea y destruye al añadir o
    //  quitar filas; actualizar el progreso de una fila NO lo reconstruye.
    Instantiator {
        model: jobModel
        delegate: Process {
            required property int jobId
            command: fm.jobCmd(jobId)
            running: true
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
        }
    }

    function open(entry) {
        if (entry.isDir) navigate(entry.path);
        else Quickshell.execDetached(["xdg-open", entry.path]);
    }

    // Enviar a la papelera. SOLO gio trash (nada de fallback a rm: si gio
    // falla, mejor no borrar nada que borrar definitivamente en silencio).
    function trashPaths(paths) {
        if (!paths.length) return;
        var cmd = "gio trash";
        for (var i = 0; i < paths.length; i++) cmd += " " + shq(paths[i]);
        fm.clearSelection();
        runOp(cmd);
    }
    // Borrado definitivo desde la vista de papelera: quita files/NOMBRE y su
    // info/NOMBRE.trashinfo. Más adentro de un dir trasheado: rm normal.
    function deleteForeverPaths(paths) {
        if (!paths.length) return;
        var script = "";
        for (var i = 0; i < paths.length; i++) {
            var p = paths[i];
            var parent = p.substring(0, p.lastIndexOf("/"));
            script += "rm -rf -- " + shq(p) + "; ";
            if (parent === fm.trashDir)
                script += "rm -f -- " + shq(fm.trashRoot + "/info/" + basename(p) + ".trashinfo") + "; ";
        }
        fm.clearSelection();
        runOp(script);
    }
    // Restaurar: lee Path= del .trashinfo (URL-encoded), lo decodifica y mueve
    // de vuelta sin machacar (sufijo .restaurado-N si el destino ya existe).
    function restorePaths(paths) {
        if (!paths.length) return;
        var script = 'T=' + shq(fm.trashRoot) + '\n' +
            'restore_one() {\n' +
            '  name="$1"; info="$T/info/$name.trashinfo"\n' +
            '  [ -f "$info" ] || return 0\n' +
            '  enc="$(grep -m1 \'^Path=\' "$info" | cut -d= -f2-)"\n' +
            '  orig="$(printf \'%b\' "${enc//\\%/\\\\x}")"\n' +
            '  case "$orig" in /*) : ;; *) orig="/$orig" ;; esac\n' +
            '  mkdir -p "$(dirname "$orig")"\n' +
            '  dest="$orig"; n=1\n' +
            '  while [ -e "$dest" ]; do dest="$orig.restaurado-$n"; n=$((n+1)); done\n' +
            '  mv -- "$T/files/$name" "$dest" && rm -f -- "$info"\n' +
            '}\n';
        for (var i = 0; i < paths.length; i++) {
            var p = paths[i];
            if (p.substring(0, p.lastIndexOf("/")) !== fm.trashDir) continue; // solo primer nivel
            script += "restore_one " + shq(basename(p)) + "\n";
        }
        fm.clearSelection();
        runOp(script);
    }
    // Vaciar papelera con confirmación en dos clicks (el segundo antes de 3s).
    property bool emptyArmed: false
    Timer { id: emptyArmTimer; interval: 3000; onTriggered: fm.emptyArmed = false }
    function emptyTrash() {
        if (!fm.emptyArmed) { fm.emptyArmed = true; emptyArmTimer.restart(); return; }
        fm.emptyArmed = false;
        fm.clearSelection();
        // NO `gio trash --empty`: el backend trash: de gio necesita gvfsd
        // (falla con "Operation not supported" sin él). Vaciar a mano files/
        // + info/ es el layout estándar de freedesktop y no depende de gvfs.
        runOp('T=' + shq(fm.trashRoot) + '; ' +
              'find "$T/files" "$T/info" -mindepth 1 -maxdepth 1 -exec rm -rf -- {} + 2>/dev/null; true');
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

    // ---- cortar / copiar / pegar (portapapeles interno) --------------------
    property var clipPaths: []
    property string clipMode: ""   // "copy" | "cut"
    function cutSelected() { var l = selectedList(); if (l.length) { fm.clipPaths = l; fm.clipMode = "cut"; } }
    function copySelected() { var l = selectedList(); if (l.length) { fm.clipPaths = l; fm.clipMode = "copy"; } }
    function paste() {
        if (!fm.clipPaths.length) return;
        var kind = fm.clipMode === "cut" ? "move" : "copy";
        fm.startXfer(kind, fm.clipPaths, fm.cwd);
        if (fm.clipMode === "cut") { fm.clipPaths = []; fm.clipMode = ""; }
    }

    // ---- renombrar ---------------------------------------------------------
    property bool renameOpen: false
    property string renamePath: ""
    property string renameText: ""
    function startRename() {
        var l = selectedList();
        if (l.length !== 1) return;
        fm.renamePath = l[0];
        fm.renameText = basename(l[0]);
        fm.renameOpen = true;
    }
    function submitRename() {
        var t = fm.renameText.trim();
        if (t === "" || t.indexOf("/") !== -1 || t === basename(fm.renamePath)) { fm.renameOpen = false; return; }
        var dir = fm.renamePath.substring(0, fm.renamePath.lastIndexOf("/"));
        runOp("mv -n -- " + shq(fm.renamePath) + " " + shq(dir + "/" + t));
        fm.renameOpen = false;
        fm.clearSelection();
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
    function newFolder() {
        runOp('d=' + shq(fm.cwd) + '; n=' + shq(I18n.t("New folder")) + '; t="$d/$n"; i=2; ' +
              'while [ -e "$t" ]; do t="$d/$n $i"; i=$((i+1)); done; mkdir -p "$t"');
    }

    Process {
        id: lister
        command: ["bash", "-c",
            "find " + fm.shq(fm.cwd) + " -maxdepth 1 -mindepth 1 -printf '%y\\t%f\\n' 2>/dev/null | sort -t$'\\t' -k1,1 -k2,2f"]
        stdout: StdioCollector {
            onStreamFinished: {
                var out = [];
                var lines = this.text.split("\n");
                for (var i = 0; i < lines.length; i++) {
                    var l = lines[i];
                    if (l.trim() === "") continue;
                    var tab = l.indexOf("\t");
                    if (tab < 0) continue;
                    var type = l.substring(0, tab);
                    var name = l.substring(tab + 1);
                    if (name.charAt(0) === "." && !fm.showHidden) continue; // hide dotfiles
                    var isDir = (type === "d");
                    out.push({ name: name, isDir: isDir, path: fm.cwd + "/" + name });
                }
                fm.entries = out;
            }
        }
    }

    Component.onCompleted: { refresh(); refreshVolumes(); Drives.ref(); fmKeys.forceActiveFocus(); }
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
        else fm.destroy();
    }

    readonly property var places: [
        { icon: Icons.home,      label: I18n.t("Home"),      path: home },
        { icon: Icons.documents, label: I18n.t("Documents"), path: home + "/Documents" },
        { icon: Icons.download,  label: I18n.t("Downloads"), path: home + "/Downloads" },
        { icon: Icons.image,     label: I18n.t("Pictures"),  path: home + "/Pictures" },
        { icon: Icons.video,     label: I18n.t("Videos"),    path: home + "/Videos" },
        { icon: Icons.music,     label: I18n.t("Music"),     path: home + "/Music" }
    ]

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
    function showCtx(x, y, entry) { fm.ctxEntry = entry; fm.ctxX = x; fm.ctxY = y; fm.ctxOpen = true; }

    // ---- drag-and-drop state ----
    property string dropTarget: ""   // path de la carpeta bajo el cursor durante el drag
    // file:// URI RFC-correcta: cada segmento percent-encoded, "/" intactos.
    function pathToUri(p) { return "file://" + p.split("/").map(encodeURIComponent).join("/"); }
    function uriToPath(u) {
        var s = u.toString();
        if (s.indexOf("file://") !== 0) return "";
        return decodeURIComponent(s.slice(7).split("?")[0].split("#")[0]);
    }

    RowLayout {
        anchors.fill: parent
        spacing: 0

        // ================= SIDEBAR =================
        Rectangle {
            Layout.preferredWidth: 190
            Layout.fillHeight: true
            color: Theme.mantle

            ColumnLayout {
                id: sideCol
                anchors.fill: parent
                anchors.margins: 10
                spacing: 4

                Text {
                    text: I18n.t("Places")
                    color: Theme.overlay2
                    font.family: Theme.fontFamily
                    font.pixelSize: Theme.fontSize - 3
                    Layout.bottomMargin: 4
                }

                Repeater {
                    model: fm.places
                    delegate: Rectangle {
                        required property var modelData
                        readonly property string dropPath: modelData.path
                        Layout.fillWidth: true
                        Layout.preferredHeight: 34
                        radius: Theme.radius
                        color: fm.dropTarget === modelData.path ? Theme.surface2
                               : fm.cwd === modelData.path ? Theme.accent
                               : (pm.containsMouse ? Theme.surface1 : "transparent")
                        border.width: fm.dropTarget === modelData.path ? 2 : 0
                        border.color: Theme.accent
                        Behavior on color { ColorAnimation { duration: Theme.dur(100) } }
                        RowLayout {
                            anchors.fill: parent
                            anchors.leftMargin: 10
                            spacing: 10
                            Text {
                                text: modelData.icon
                                color: fm.cwd === modelData.path ? Theme.onAccent : Theme.subtext0
                                font.family: Theme.fontFamily
                                font.pixelSize: Theme.fontSize + 1
                                Layout.preferredWidth: 18
                            }
                            Text {
                                Layout.fillWidth: true
                                text: modelData.label
                                color: fm.cwd === modelData.path ? Theme.onAccent : Theme.text
                                font.family: Theme.fontFamily
                                font.pixelSize: Theme.fontSize - 1
                            }
                        }
                        MouseArea {
                            id: pm
                            anchors.fill: parent
                            hoverEnabled: true
                            cursorShape: Qt.PointingHandCursor
                            onClicked: fm.navigate(modelData.path)
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
                    visible: Drives.devices.length > 0
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
                            cursorShape: Qt.PointingHandCursor
                            z: -1
                            onClicked: {
                                if (devRow.mounted) fm.navigate(modelData.mount);
                                else Drives.mount(modelData.dev, modelData.obj,
                                                  function(mp) { fm.navigate(mp); });
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

                Item { Layout.fillHeight: true }

                // Trash (soltar un drag encima = enviar a la papelera, como Nautilus)
                Rectangle {
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
                            text: fm.cwd.replace(fm.home, "~")
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
                        opacity: fm.clipMode === "cut" && fm.clipPaths.indexOf(modelData.path) !== -1 ? 0.5 : 1
                        RowLayout {
                            anchors.fill: parent
                            anchors.leftMargin: 14
                            anchors.rightMargin: 14
                            spacing: 12
                            Text {
                                text: fm.mimeGlyph(modelData)
                                color: fm.mimeColor(modelData)
                                font.family: Theme.fontFamily
                                font.pixelSize: Theme.fontSize + 4
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
                            opacity: fm.clipMode === "cut" && fm.clipPaths.indexOf(modelData.path) !== -1 ? 0.5 : 1
                            ColumnLayout {
                                anchors.centerIn: parent
                                width: parent.width - 12
                                spacing: 6
                                Text {
                                    Layout.alignment: Qt.AlignHCenter
                                    text: fm.mimeGlyph(modelData)
                                    color: fm.mimeColor(modelData)
                                    font.family: Theme.fontFamily
                                    font.pixelSize: Math.round(44 * fm.zoom)
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
                        dragCopy = false; leftHeld = false; fm.dropTarget = "";
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
                    // o un destino del sidebar (places/volúmenes/papelera).
                    function updateDropTarget(mx, my) {
                        var i = viewAt(mx, my);
                        if (i >= 0) {
                            var e = fm.entries[i];
                            fm.dropTarget = (e.isDir && !fm.isSelected(e.path)) ? e.path : "";
                            return;
                        }
                        var sp = selArea.mapToItem(sideCol, mx, my);
                        var ch = sideCol.childAt(sp.x, sp.y);
                        fm.dropTarget = (ch && ch.dropPath !== undefined && ch.dropPath !== fm.cwd) ? ch.dropPath : "";
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
                            text: fm.selCount === 1 ? fm.basename(fm.selectedList()[0] || "") : fm.selCount + I18n.t(" items")
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
                    required property string errMsg

                    readonly property bool live: phase === "scan" || phase === "run"
                    // -1 = todavía no se sabe cuánto hay (recuento) -> barra
                    // indeterminada, que es honesto; nada de porcentajes falsos.
                    readonly property real frac: total > 0 ? Math.max(0, Math.min(1, done / total)) : -1
                    readonly property color tint: phase === "err" ? Theme.red
                                                : phase === "warn" ? Theme.yellow
                                                : phase === "ok" ? Theme.green : Theme.accent

                    Layout.fillWidth: true
                    Layout.preferredHeight: cardCol.implicitHeight + 14
                    color: Qt.rgba(card.tint.r, card.tint.g, card.tint.b, 0.12)

                    //  Lo que sale bien y sin sorpresas se quita solo a los 4 s.
                    //  Lo que tenga saltados o fallos SE QUEDA hasta que el
                    //  usuario lo cierre: eso no puede desaparecer sin que se
                    //  haya leído. Es un disparo único por tarjeta, no un sondeo.
                    Timer {
                        interval: 4000
                        running: card.phase === "ok"
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
                        if (fm.clipPaths.length) s += "  •  " + fm.clipPaths.length + (fm.clipMode === "cut" ? I18n.t(" to move") : I18n.t(" to copy"));
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
            if (fm.remoteFormOpen || fm.renameOpen) return;
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
                else if (fm.selCount > 0) fm.clearSelection();
                else fm.goUp();
                event.accepted = true;
            } else if (event.key === Qt.Key_Delete) {
                var l = fm.selectedList();
                if (l.length) { fm.inTrash ? fm.deleteForeverPaths(l) : fm.trashPaths(l); }
                event.accepted = true;
            } else if (event.key === Qt.Key_F2) {
                fm.startRename(); event.accepted = true;
            } else if (event.key === Qt.Key_Backspace) {
                fm.goBack(); event.accepted = true;
            } else if (ctrl && event.key === Qt.Key_A) {
                fm.selectAll(); event.accepted = true;
            } else if (ctrl && event.key === Qt.Key_H) {
                fm.showHidden = !fm.showHidden; fm.refresh(); event.accepted = true;
            } else if (ctrl && event.key === Qt.Key_C) {
                fm.copySelected(); event.accepted = true;
            } else if (ctrl && event.key === Qt.Key_X) {
                fm.cutSelected(); event.accepted = true;
            } else if (ctrl && event.key === Qt.Key_V) {
                if (!fm.inTrash) fm.paste(); event.accepted = true;
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
        x: Math.min(fm.ctxX, fm.width - width - 8)
        y: Math.min(fm.ctxY, fm.height - height - 8)
        width: 210
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
                    if (fm.inTrash) {
                        if (fm.ctxEntry) return [
                            { label: I18n.t("Restore") + suf, act: "restore" },
                            { label: I18n.t("Delete permanently") + suf, act: "delforever", danger: true }
                        ];
                        return [{ label: I18n.t("Empty trash"), act: "emptytrash", danger: true }];
                    }
                    if (!fm.ctxEntry) {
                        var bg = [{ label: I18n.t("New folder"), act: "newfolder" }];
                        if (fm.clipPaths.length) bg.push({ label: I18n.t("Paste (") + fm.clipPaths.length + ")", act: "paste" });
                        bg.push({ label: I18n.t("Select all"), act: "selectall" });
                        bg.push({ label: fm.showHidden ? I18n.t("Hide hidden files") : I18n.t("Show hidden files"), act: "togglehidden" });
                        bg.push({ label: I18n.t("Properties"), act: "props" });
                        return bg;
                    }
                    var items = [];
                    if (n === 1) {
                        items.push({ label: I18n.t("Open"), act: "open" });
                        items.push({ label: I18n.t("Rename"), act: "rename" });
                    }
                    items.push({ label: I18n.t("Cut") + suf, act: "cut" });
                    items.push({ label: I18n.t("Copy") + suf, act: "copy" });
                    if (n === 1) {
                        if (/\.zip$/i.test(fm.ctxEntry.name)) items.push({ label: I18n.t("Extract here"), act: "extract" });
                        else items.push({ label: I18n.t("Compress to .zip"), act: "compress" });
                    }
                    items.push({ label: I18n.t("Properties") + suf, act: "props" });
                    items.push({ label: I18n.t("Move to Trash") + suf, act: "trash", danger: true });
                    return items;
                }
                delegate: Rectangle {
                    required property var modelData
                    Layout.fillWidth: true
                    Layout.preferredHeight: 32
                    radius: Theme.radius - 2
                    color: im.containsMouse ? Theme.surface2 : "transparent"
                    Text {
                        anchors.fill: parent
                        anchors.leftMargin: 12
                        verticalAlignment: Text.AlignVCenter
                        text: modelData.label
                        color: modelData.danger ? Theme.red : Theme.text
                        font.family: Theme.fontFamily
                        font.pixelSize: Theme.fontSize - 1
                    }
                    MouseArea {
                        id: im
                        anchors.fill: parent
                        hoverEnabled: true
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
                            var sel = fm.selectedList();
                            fm.ctxOpen = false;
                            Qt.callLater(function() { fm.ctxAction(act, e, sel); });
                        }
                    }
                }
            }
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
                    Text { text: Icons.pencil; color: Theme.accent; font.family: Theme.fontFamily; font.pixelSize: Theme.fontSize + 3 }
                    Text { Layout.fillWidth: true; text: I18n.t("Rename"); color: Theme.text; font.family: Theme.fontFamily; font.pixelSize: Theme.fontSize + 2; font.bold: true }
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
                        onTextChanged: fm.renameText = text
                        Keys.onPressed: function(ev) {
                            if (ev.key === Qt.Key_Escape) { fm.renameOpen = false; ev.accepted = true; }
                        }
                        onAccepted: fm.submitRename()
                        Component.onCompleted: {
                            forceActiveFocus();
                            // preselecciona el nombre sin la extensión
                            var dot = text.lastIndexOf(".");
                            select(0, dot > 0 ? dot : text.length);
                        }
                    }
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
                        Text { anchors.centerIn: parent; text: I18n.t("Rename"); color: Theme.onAccent; font.family: Theme.fontFamily; font.pixelSize: Theme.fontSize - 1; font.bold: true }
                        MouseArea { id: renOkMa; anchors.fill: parent; hoverEnabled: true; cursorShape: Qt.PointingHandCursor; onClicked: fm.submitRename() }
                    }
                }
            }
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
