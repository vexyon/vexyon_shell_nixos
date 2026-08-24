import QtQuick
import QtQuick.Layouts
import QtQuick.Dialogs
import Quickshell
import Quickshell.Io
import qs.services
import qs.components

// ============================================================================
//  VmManager — gestor de máquinas virtuales (libvirt/QEMU). Ventana normal
//  (FloatingWindow), no una capa: Hyprland la coloca y la ordena como a
//  cualquier otra ventana. Es el TERCER FloatingWindow del árbol, tras Ajustes
//  y el gestor de ficheros.
//
//  MONITOR ENFOCADO: un cliente Wayland NO elige salida para un toplevel xdg
//  (medido en la S71: pedir `screen` no sirve de nada). Lo que sí hace falta —y
//  ya está puesto para TODA ventana del shell— es la regla
//  `workspace = "unset"` sobre `class = "org.quickshell"` que emite el bridge:
//  apaga `misc:initial_workspace_tracking` para el shell, y sin ella la PRIMERA
//  ventana xdg del proceso aterriza en el monitor del LOGIN en vez de en el
//  enfocado. Esta ventana la hereda por su clase, sin tocar nada.
//
//  RESPONSIVE DE VERDAD: el usuario embaldosa a mano (media pantalla, un
//  cuarto, el monitor vertical de 1080×1920, Super+Shift+F a pantalla
//  completa). Aquí no hay ni un tamaño en píxeles asumido:
//   * dos paneles (lista | detalle) por encima de `narrowW`, UN panel con
//     navegación atrás por debajo — la lista y el detalle nunca compiten por
//     un ancho que no existe.
//   * las barras de acciones son `Flow`, no `Row`: los botones bajan de línea
//     en vez de salirse o recortarse.
//   * todo el contenido largo vive dentro de un Flickable con `clip`.
//   * los diálogos miden `min(deseado, ventana - margen)` en LOS DOS ejes y
//     su cuerpo también rueda.
//
//  CERO SONDEO: no hay ningún Timer. Se relee al abrir la ventana, al terminar
//  cualquier acción (Vm.actionDone) y con el botón de recargar. Nada más.
// ============================================================================
FloatingWindow {
    id: vm
    visible: Panels.vmManager
    title: "Vexyon VM"
    implicitWidth: 1080
    implicitHeight: 720
    color: Theme.base

    // ---- puntos de ruptura -------------------------------------------------
    readonly property bool narrow: width < 760
    readonly property bool tiny: width < 460
    readonly property int listW: Math.round(Math.max(190, Math.min(300, width * 0.28)))

    property string selected: ""
    // en modo estrecho: false = se ve la lista, true = se ve el detalle
    property bool showDetail: false
    // pestaña del detalle
    property string tab: "overview"

    readonly property var sel: {
        for (var i = 0; i < Vm.vms.length; i++) if (Vm.vms[i].name === vm.selected) return Vm.vms[i];
        return null;
    }

    function pick(name) {
        vm.selected = name;
        vm.showDetail = true;
        if (vm.tab === "snapshots") Vm.snapshots_(name);
        else Vm.loadDetail(name);
    }

    // ---- diálogo genérico de campos ---------------------------------------
    //  Un solo diálogo reutilizable en vez de seis casi iguales (añadir disco,
    //  renombrar, clonar, carpeta compartida, insertar ISO…). `fields` es
    //  [{ key, label, value, numeric, placeholder }] y `act` recibe un objeto
    //  { key: valorEscrito }.
    property var prompt: null
    function ask2(title, note, fields, label, act) {
        vm.prompt = { title: title, note: note, fields: fields, label: label, act: act };
    }
    //  Nombre legible del modo de una red. `hostonly`/`internal` no son
    //  palabras de libvirt: las deduce Vm mirando si hay <forward> y si hay
    //  <ip>, porque libvirt no las distingue por sí mismo.
    //  Modo de una red por su nombre, mirando la lista que ya tiene el servicio.
    //  ¿sigue estando la red `default`? Se mira la lista que ya trae el
    //  servicio; `net-list --all` incluye también las paradas, así que esto
    //  significa "no existe la definición", no "está apagada".
    //  Modelo con el que se crean los adaptadores NUEVOS (los dos botones de
    //  "Añadir adaptador", en red gestionada y en puente). Antes iba fijo a
    //  virtio, que en Windows es un adaptador sin driver.
    property string newNicModel: "virtio"
    readonly property bool hasDefaultNet: {
        for (var i = 0; i < Vm.networks.length; i++)
            if (Vm.networks[i].name === Vm.protectedNet) return true;
        return false;
    }
    function netModeOf(name) {
        for (var i = 0; i < Vm.networks.length; i++)
            if (Vm.networks[i].name === name) return Vm.networks[i].mode;
        return "nat";        // no está en la lista: el rótulo de siempre
    }
    function netModeLabel(m) {
        switch (m) {
        case "nat":      return I18n.t("NAT (out to the internet)");
        case "hostonly": return I18n.t("Host-only");
        case "internal": return I18n.t("Internal");
        case "route":    return I18n.t("Routed");
        case "bridge":   return I18n.t("Bridged");
        case "open":     return I18n.t("Open");
        }
        return m;
    }
    //  255.255.255.0 -> 24. Solo para enseñarlo compacto junto a la dirección.
    function maskBits(m) {
        var p = String(m || "").split("."), n = 0;
        if (p.length !== 4) return "";
        for (var i = 0; i < 4; i++) {
            var b = parseInt(p[i], 10) || 0;
            while (b) { n += b & 1; b >>>= 1; }
        }
        return n;
    }

    function fmtBytes(b) {
        if (!b) return "—";
        var u = ["B", "KiB", "MiB", "GiB", "TiB"], i = 0, v = b;
        while (v >= 1024 && i < u.length - 1) { v /= 1024; i++; }
        return (i === 0 || v >= 10 ? Math.round(v) : v.toFixed(1)) + " " + u[i];
    }
    // Cifra corta de la derecha de la barra de progreso. Con bytes se enseñan
    // LOS DOS (hechos y totales) además del porcentaje: en una copia de 9 GB
    // saber que van 3,2 GB dice mucho más que un 35 % a secas.
    readonly property string progDetail: {
        if (Vm.progPct >= 0) return Math.round(Vm.progPct) + " %";
        if (Vm.progTotal > 0)
            return vm.fmtBytes(Vm.progDone) + " / " + vm.fmtBytes(Vm.progTotal)
                 + "   " + Math.round(Vm.progFraction * 100) + " %";
        if (Vm.progDone > 0) return vm.fmtBytes(Vm.progDone);
        return "";
    }

    // Aviso reutilizable: la VM está encendida y esto no se aplica en caliente.
    readonly property bool running: vm.sel && vm.sel.state === "running"

    onTabChanged: {
        if (vm.selected === "") return;
        if (vm.tab === "snapshots") Vm.snapshots_(vm.selected);
        else Vm.loadDetail(vm.selected);
        if (vm.tab === "devices") Vm.loadHostUsb();
    }

    //  Mientras esta ventana está abierta, el servicio escucha los eventos de
    //  libvirt (ver Vm.eventsWanted): así la lista se entera de lo que pase
    //  fuera del shell — apagar el invitado desde dentro, un `virsh destroy`
    //  desde otra terminal, un cuelgue. Se suelta al cerrar, y si no queda
    //  ninguna VM encendida el proceso que escucha desaparece.
    property bool _watching: false
    function _watch(on) {
        if (on === vm._watching) return;
        vm._watching = on;
        if (on) Vm.addWatcher(); else Vm.removeWatcher();
    }
    Component.onDestruction: vm._watch(false)

    onVisibleChanged: {
        if (visible) {
            Vm.prime();      // recuerda la petición si Config aún no está lista
            vm._watch(true);
            Vm.refresh();
            if (vm.selected !== "") Vm.loadDetail(vm.selected);
        } else {
            vm._watch(false);
            // Cerrar (botón X o Super+Q): Qt pone visible=false. Resincronizar
            // el bus de paneles, si no `Panels.vmManager` queda en true y la
            // ventana no vuelve a abrirse (mismo arreglo que Ajustes).
            if (Panels.vmManager) Panels.vmManager = false;
            vm.confirm = null;
            vm.creating = false;
            vm.prompt = null;
        }
    }

    // Al terminar cualquier acción: si la VM seleccionada ha desaparecido
    // (borrada), soltar la selección. POR EVENTO, no por temporizador.
    Connections {
        target: Vm
        function onRefreshed() {
            if (vm.selected !== "" && !Vm.nameTaken(vm.selected)) {
                vm.selected = "";
                vm.showDetail = false;
            }
            if (vm.selected === "" && !vm.narrow && Vm.vms.length > 0) {
                vm.selected = Vm.vms[0].name;
                Vm.loadDetail(vm.selected);
            }
        }
        function onActionDone(action, ok) {
            if (ok && action === "create") { vm.creating = false; vm.selected = vm.newName; }
            // Tras renombrar, la VM vieja ya no existe: soltar la selección para
            // que onRefreshed elija la primera y no se quede apuntando a un
            // nombre muerto.
            if (ok && (action === "rename")) { vm.selected = ""; vm.showDetail = false; }
        }
    }

    // ---- estado de los diálogos -------------------------------------------
    //  `confirm` = null o { title, body, danger, label, act }. TODA acción
    //  destructiva (apagado forzado, reinicio en frío, borrar VM, borrar
    //  snapshot) pasa obligatoriamente por aquí: el usuario ya se ha llevado un
    //  `virsh reset` por delante sin querer.
    property var confirm: null
    function ask(title, body, label, danger, act) {
        vm.confirm = { title: title, body: body, label: label, danger: danger, act: act };
    }

    property bool creating: false
    property string newName: ""

    function stateColor(s) {
        return s === "running" ? Theme.green
             : s === "paused"  ? Theme.yellow
             : s === "shut off" ? Theme.overlay2 : Theme.subtext0;
    }
    function stateLabel(s) {
        return s === "running"  ? I18n.t("Running")
             : s === "paused"   ? I18n.t("Paused")
             : s === "shut off" ? I18n.t("Shut off")
             : s === "crashed"  ? I18n.t("Crashed") : s;
    }
    function fmtMem(kib) {
        if (!kib) return "—";
        var mib = Math.round(kib / 1024);
        return mib >= 1024 ? (mib / 1024).toFixed(mib % 1024 === 0 ? 0 : 1) + " GiB" : mib + " MiB";
    }

    // ---- botón de acción reutilizable -------------------------------------
    //  Mide su propio texto: sin anchos fijos, así una etiqueta traducida más
    //  larga (ES) no se recorta nunca.
    component ActBtn : Rectangle {
        id: ab
        property string glyph: ""
        property string label: ""
        property color tint: Theme.text
        property bool danger: false
        property bool enabled: true
        signal clicked()
        implicitHeight: 32
        implicitWidth: abRow.implicitWidth + 22
        radius: Theme.radius
        opacity: ab.enabled ? 1 : 0.4
        color: !ab.enabled ? Theme.surface0
             : abMa.pressed ? Theme.surface2
             : abMa.containsMouse ? (ab.danger ? Qt.rgba(Theme.red.r, Theme.red.g, Theme.red.b, 0.18) : Theme.surface1)
             : Theme.surface0
        border.width: 1
        border.color: ab.danger && abMa.containsMouse ? Theme.red : Theme.overlay0
        Behavior on color { ColorAnimation { duration: Theme.dur(120) } }
        scale: abMa.pressed && ab.enabled ? 0.96 : 1
        Behavior on scale { NumberAnimation { duration: Theme.dur(90); easing.type: Theme.easing } }
        RowLayout {
            id: abRow
            anchors.centerIn: parent
            spacing: 7
            Text {
                visible: ab.glyph !== ""
                text: ab.glyph; color: ab.tint
                font.family: Theme.fontFamily; font.pixelSize: Theme.fontSize
            }
            Text {
                visible: ab.label !== ""
                text: ab.label; color: ab.danger ? Theme.red : Theme.text
                font.family: Theme.fontFamily; font.pixelSize: Theme.fontSize - 1
            }
        }
        MouseArea {
            id: abMa
            anchors.fill: parent; hoverEnabled: true
            enabled: ab.enabled
            cursorShape: Qt.PointingHandCursor
            onClicked: ab.clicked()
        }
    }

    // Cabecera de sección dentro de una pestaña.
    component Sec : Text {
        Layout.fillWidth: true
        Layout.topMargin: 8
        color: Theme.subtext1
        font.family: Theme.fontFamily
        font.pixelSize: Theme.fontSize - 2
        font.bold: true
    }

    // Aviso en línea. `tone`: "info" (gris) o "warn" (ámbar, con icono) — se
    // usa para todo lo que necesita algo del INVITADO o no se aplica en vivo,
    // que es justo lo que no puede quedar implícito.
    component Note : RowLayout {
        id: nt
        property string text: ""
        property string tone: "info"
        Layout.fillWidth: true
        spacing: 8
        Text {
            Layout.alignment: Qt.AlignTop
            visible: nt.tone === "warn"
            text: Icons.info
            color: Theme.yellow
            font.family: Theme.fontFamily
            font.pixelSize: Theme.fontSize - 2
        }
        Text {
            Layout.fillWidth: true
            text: nt.text
            color: nt.tone === "warn" ? Theme.yellow : Theme.subtext0
            wrapMode: Text.Wrap
            font.family: Theme.fontFamily
            font.pixelSize: Theme.fontSize - 3
        }
    }

    // ---- campo de texto reutilizable ---------------------------------------
    component Field : Rectangle {
        id: fld
        property string label: ""
        property alias text: fi.text
        property string placeholder: ""
        property bool numeric: false
        property bool valid: true
        // "" = campo normal; "file"/"folder"/"save" añaden un botón de examinar
        // que abre el MISMO tipo de diálogo que ya usa Ajustes para el avatar
        // (QtQuick.Dialogs), no un selector propio.
        property string pick: ""
        // Qué tipo de fichero busca este campo: "iso" | "disk" | "ova" | "xml".
        // Solo sirve para acotar lo que enseña el selector; el campo se sigue
        // pudiendo escribir a mano y admite cualquier ruta.
        property string pickKind: ""
        Layout.fillWidth: true
        implicitHeight: 56
        radius: Theme.radius
        color: Theme.surface0
        border.width: 1
        border.color: !fld.valid ? Theme.red : (fi.activeFocus ? Theme.accent : Theme.overlay0)
        Behavior on border.color { ColorAnimation { duration: Theme.dur(120) } }
        ColumnLayout {
            anchors.fill: parent
            anchors.leftMargin: 12; anchors.rightMargin: 12
            anchors.topMargin: 7; anchors.bottomMargin: 7
            spacing: 1
            Text {
                text: fld.label; color: Theme.subtext0
                font.family: Theme.fontFamily; font.pixelSize: Theme.fontSize - 3
            }
            RowLayout {
                Layout.fillWidth: true
                Layout.fillHeight: true
                spacing: 6
                TextInput {
                    id: fi
                    Layout.fillWidth: true
                    Layout.fillHeight: true
                    color: Theme.text
                    font.family: Theme.fontFamily; font.pixelSize: Theme.fontSize
                    selectionColor: Theme.accent
                    selectedTextColor: Theme.onAccent
                    clip: true
                    verticalAlignment: TextInput.AlignVCenter
                    validator: fld.numeric ? intVal : null
                    Text {
                        anchors.verticalCenter: parent.verticalCenter
                        visible: fi.text === ""
                        text: fld.placeholder; color: Theme.overlay1
                        font: fi.font
                    }
                }
                IconButton {
                    visible: fld.pick !== ""
                    Layout.alignment: Qt.AlignVCenter
                    icon: fld.pick === "folder" ? Icons.folder : Icons.documents
                    iconColor: Theme.subtext0
                    implicitWidth: 26; implicitHeight: 26
                    onClicked: vm.openPicker(fld)
                }
            }
        }
    }

    // ---- selector de ficheros --------------------------------------------
    //  Escribir rutas a mano era la fuente de todo el problema de la `~`. Con
    //  el selector la ruta llega SIEMPRE absoluta y existente.
    //  `selectedFile` es una URL file:// — hay que quitarle el esquema antes de
    //  que la vea libvirt.
    property var pickTarget: null

    // Filtros por tipo de campo, para no hacer rebuscar entre todo el disco.
    // Las extensiones van en minúscula Y mayúscula a propósito: el diálogo NO
    // nativo de Qt casa los comodines respetando mayúsculas, y una ISO bajada
    // de una web perfectamente puede llamarse `.ISO`.
    // La última entrada es SIEMPRE "todos los ficheros": una imagen con un
    // nombre raro tiene que poder elegirse igual.
    function pickFilters(kind) {
        var all = I18n.t("All files") + " (*)";
        switch (kind) {
        case "iso":
            return [ I18n.t("Disk images") + " (*.iso *.ISO *.img *.IMG)",
                     I18n.t("ISO images") + " (*.iso *.ISO)", all ];
        case "disk":
            return [ I18n.t("Disk images")
                     + " (*.qcow2 *.QCOW2 *.img *.IMG *.raw *.RAW *.vmdk *.VMDK *.vdi *.VDI *.qed *.vhd *.vhdx)",
                     all ];
        case "ova":
            return [ I18n.t("Virtual machine archives") + " (*.ova *.OVA)", all ];
        case "xml":
            return [ I18n.t("libvirt domain XML") + " (*.xml *.XML)", all ];
        default:
            return [ all ];
        }
    }

    function openPicker(field) {
        vm.pickTarget = field;
        if (field.pick === "folder") { folderPicker.open(); return; }
        filePicker.nameFilters = vm.pickFilters(field.pickKind);
        filePicker.fileMode = field.pick === "save" ? FileDialog.SaveFile : FileDialog.OpenFile;
        filePicker.open();
    }
    function urlToPath(u) {
        var s = decodeURIComponent(String(u));
        return s.indexOf("file://") === 0 ? s.slice(7) : s;
    }
    FileDialog {
        id: filePicker
        title: I18n.t("Choose a file")
        onAccepted: if (vm.pickTarget) vm.pickTarget.text = vm.urlToPath(selectedFile)
    }
    FolderDialog {
        id: folderPicker
        title: I18n.t("Choose a folder")
        onAccepted: if (vm.pickTarget) vm.pickTarget.text = vm.urlToPath(selectedFolder)
    }
    IntValidator { id: intVal; bottom: 1; top: 999999 }

    // ---- selector segmentado (firmware, red…) ------------------------------
    component Segmented : Flow {
        id: seg
        property var options: []      // [{ key, label }]
        property string value: ""
        signal picked(string key)
        spacing: 6
        Repeater {
            model: seg.options
            delegate: Rectangle {
                required property var modelData
                readonly property bool on: modelData.key === seg.value
                implicitWidth: segTxt.implicitWidth + 22
                implicitHeight: 30
                radius: Theme.radius
                color: on ? Theme.accent : (sMa.containsMouse ? Theme.surface2 : Theme.surface0)
                border.width: 1
                border.color: on ? Theme.accent : Theme.overlay0
                Behavior on color { ColorAnimation { duration: Theme.dur(120) } }
                Text {
                    id: segTxt
                    anchors.centerIn: parent
                    text: modelData.label
                    color: parent.on ? Theme.onAccent : Theme.text
                    font.family: Theme.fontFamily; font.pixelSize: Theme.fontSize - 2
                }
                MouseArea {
                    id: sMa
                    anchors.fill: parent; hoverEnabled: true; cursorShape: Qt.PointingHandCursor
                    onClicked: seg.picked(modelData.key)
                }
            }
        }
    }

    // ======================================================================
    //  Cuerpo
    // ======================================================================
    Rectangle {
        anchors.fill: parent
        color: Theme.base

        ColumnLayout {
            anchors.fill: parent
            spacing: 0

            // ---------------- cabecera ----------------
            Rectangle {
                Layout.fillWidth: true
                Layout.preferredHeight: 52
                color: Theme.mantle
                RowLayout {
                    anchors.fill: parent
                    anchors.leftMargin: 14; anchors.rightMargin: 10
                    spacing: 10

                    // atrás (solo en estrecho, viendo el detalle)
                    IconButton {
                        visible: vm.narrow && vm.showDetail
                        icon: Icons.back
                        onClicked: vm.showDetail = false
                    }
                    Text {
                        text: Icons.desktop; color: Theme.accent
                        font.family: Theme.fontFamily; font.pixelSize: Theme.fontSize + 5
                        visible: !(vm.narrow && vm.showDetail)
                    }
                    Text {
                        Layout.fillWidth: true
                        text: (vm.narrow && vm.showDetail && vm.selected !== "")
                              ? vm.selected : I18n.t("Virtual machines")
                        color: Theme.text
                        font.family: Theme.fontFamily; font.pixelSize: Theme.fontSize + 3
                        font.bold: true
                        elide: Text.ElideRight
                    }
                    // Indicador de trabajo en curso: sustituye a cualquier
                    // tentación de sondear "¿ya?" con un temporizador.
                    Text {
                        visible: Vm.busy
                        text: I18n.t("Working…"); color: Theme.subtext0
                        font.family: Theme.fontFamily; font.pixelSize: Theme.fontSize - 2
                    }
                    IconButton {
                        icon: Icons.plus
                        iconColor: Theme.accent
                        onClicked: { vm.newName = ""; vm.creating = true; }
                    }
                    IconButton {
                        icon: Icons.archive
                        onClicked: vm.ask2(I18n.t("Import a VM from an .ova"),
                            I18n.t("Reads a VirtualBox/VMware .ova. Its disk is converted to qcow2 and a new VM is defined. Network, sound and USB are approximated — check them before the first boot."),
                            [ { key: "path", label: I18n.t("Path to the .ova file"), pick: "file", pickKind: "ova", value: "" },
                              { key: "name", label: I18n.t("Name for the new VM"), value: "imported" },
                              { key: "bus", label: I18n.t("Disk controller"), value: "auto",
                                choices: [
                                  { key: "auto", label: I18n.t("From the .ova (recommended)"),
                                    note: I18n.t("Keeps the controller the .ova declares. This is what the guest already has drivers for.") },
                                  { key: "sata", label: I18n.t("SATA") },
                                  { key: "ide",  label: I18n.t("IDE") },
                                  { key: "virtio", label: I18n.t("virtio (fastest, needs drivers)"),
                                    note: I18n.t("Fastest, but a guest without virtio storage drivers will not boot — Windows shows INACCESSIBLE_BOOT_DEVICE. Inject the drivers first.") } ] } ],
                            I18n.t("Import"),
                            function(v) {
                                if (v.path !== "" && v.name !== "" && Vm.validName(v.name) && !Vm.nameTaken(v.name))
                                    Vm.importOva(v.path, v.name, v.bus);
                            })
                    }
                    IconButton {
                        icon: Icons.up
                        onClicked: vm.ask2(I18n.t("Import a VM definition"),
                            I18n.t("Defines a VM from a libvirt domain XML file. The disks it refers to must already exist."),
                            [ { key: "path", label: I18n.t("Path to the .xml file"), pick: "file", pickKind: "xml",
                                value: Quickshell.env("HOME") + "/" } ],
                            I18n.t("Import"),
                            function(v) { if (v.path !== "") Vm.importVm(v.path); })
                    }
                    IconButton { icon: Icons.refresh; onClicked: Vm.refresh() }
                    IconButton { icon: Icons.close; onClicked: Panels.close("vmManager") }
                }
            }
            Rectangle { Layout.fillWidth: true; Layout.preferredHeight: 1; color: Theme.surface1 }

            // ---------------- progreso de una operación larga ----------------
            //  Importar o exportar un .ova mueve gigabytes y tarda minutos: sin
            //  esto se pulsa el botón y la ventana se queda quieta, sin decir si
            //  va, por dónde va ni cuánto falta.
            //
            //  Vive AQUÍ, en la cabecera de la ventana donde se lanzó la
            //  operación, y NO es un diálogo: no tapa nada, no roba el foco y se
            //  puede seguir mirando el resto del gestor (y cerrar la ventana: la
            //  operación no la lleva la ventana, la lleva el servicio, así que
            //  sigue y al volver a abrir el progreso sigue ahí).
            //
            //  Todo lo que enseña viene de las líneas que escribe la propia
            //  operación mientras copia. NO hay temporizador ni nadie mirando
            //  cuánto ha crecido un fichero.
            Rectangle {
                Layout.fillWidth: true
                Layout.preferredHeight: visible ? progCol.implicitHeight + 18 : 0
                visible: Vm.progressing
                color: Qt.rgba(Theme.accent.r, Theme.accent.g, Theme.accent.b, 0.12)
                ColumnLayout {
                    id: progCol
                    anchors.fill: parent
                    anchors.leftMargin: 14; anchors.rightMargin: 14
                    anchors.topMargin: 9;   anchors.bottomMargin: 9
                    spacing: 6
                    RowLayout {
                        Layout.fillWidth: true
                        spacing: 10
                        Text {
                            Layout.fillWidth: true
                            text: (Vm.progSteps > 0
                                   ? I18n.t("Step") + " " + Vm.progStep + "/" + Vm.progSteps + " · " : "")
                                  + I18n.t(Vm.phaseText(Vm.progPhase))
                            color: Theme.text
                            font.family: Theme.fontFamily; font.pixelSize: Theme.fontSize - 2
                            elide: Text.ElideRight
                        }
                        Text {
                            text: vm.progDetail
                            color: Theme.subtext0
                            font.family: Theme.fontFamily; font.pixelSize: Theme.fontSize - 2
                        }
                    }
                    // Determinada cuando la fase sabe cuánto queda. Cuando no lo
                    // sabe se deja una franja apagada a lo ancho: es honesto, y
                    // desde luego mejor que inventarse un porcentaje.
                    Rectangle {
                        Layout.fillWidth: true
                        Layout.preferredHeight: 6
                        radius: 3
                        color: Theme.surface1
                        Rectangle {
                            height: parent.height
                            radius: parent.radius
                            width: Vm.progFraction >= 0 ? parent.width * Vm.progFraction : parent.width
                            color: Vm.progFraction >= 0 ? Theme.accent : Theme.surface2
                            Behavior on width { NumberAnimation { duration: 140 } }
                        }
                    }
                }
            }

            // ---------------- operación larga terminada BIEN ----------------
            //  Contrapunto de la banda roja: una exportación que tarda cinco
            //  minutos tiene que decir "ya está, y está aquí", no simplemente
            //  dejar de enseñar la barra.
            Rectangle {
                Layout.fillWidth: true
                Layout.preferredHeight: visible ? okTxt.implicitHeight + 16 : 0
                visible: Vm.lastSuccess !== ""
                color: Qt.rgba(Theme.green.r, Theme.green.g, Theme.green.b, 0.14)
                RowLayout {
                    anchors.fill: parent
                    anchors.leftMargin: 14; anchors.rightMargin: 8
                    spacing: 8
                    Text {
                        id: okTxt
                        Layout.fillWidth: true
                        text: Vm.lastSuccess; color: Theme.green
                        font.family: Theme.fontFamily; font.pixelSize: Theme.fontSize - 2
                        wrapMode: Text.Wrap
                    }
                    IconButton { icon: Icons.close; iconColor: Theme.green; onClicked: Vm.lastSuccess = "" }
                }
            }

            // ---------------- error de la última acción ----------------
            Rectangle {
                Layout.fillWidth: true
                Layout.preferredHeight: visible ? errTxt.implicitHeight + 16 : 0
                visible: Vm.lastError !== ""
                color: Qt.rgba(Theme.red.r, Theme.red.g, Theme.red.b, 0.14)
                RowLayout {
                    anchors.fill: parent
                    anchors.leftMargin: 14; anchors.rightMargin: 8
                    spacing: 8
                    Text {
                        id: errTxt
                        Layout.fillWidth: true
                        text: Vm.lastError; color: Theme.red
                        font.family: Theme.fontFamily; font.pixelSize: Theme.fontSize - 2
                        wrapMode: Text.Wrap
                    }
                    IconButton { icon: Icons.close; iconColor: Theme.red; onClicked: Vm.lastError = "" }
                }
            }

            // ---------------- aviso "guardado, pero no en caliente" ----------------
            //  NO es un error: la config se guardó. Distinto color y distinto
            //  texto justamente para que no se confunda con un fallo.
            Rectangle {
                Layout.fillWidth: true
                Layout.preferredHeight: visible ? noteTxt.implicitHeight + 16 : 0
                visible: Vm.lastNote !== ""
                color: Qt.rgba(Theme.yellow.r, Theme.yellow.g, Theme.yellow.b, 0.14)
                RowLayout {
                    anchors.fill: parent
                    anchors.leftMargin: 14; anchors.rightMargin: 8
                    spacing: 8
                    Text {
                        id: noteTxt
                        Layout.fillWidth: true
                        text: I18n.t(Vm.lastNote); color: Theme.yellow
                        font.family: Theme.fontFamily; font.pixelSize: Theme.fontSize - 2
                        wrapMode: Text.Wrap
                    }
                    IconButton { icon: Icons.close; iconColor: Theme.yellow; onClicked: Vm.lastNote = "" }
                }
            }

            // ---------------- contenido ----------------
            RowLayout {
                Layout.fillWidth: true
                Layout.fillHeight: true
                spacing: 0

                // ---- lista de VMs ----
                Item {
                    Layout.fillHeight: true
                    Layout.preferredWidth: vm.narrow ? -1 : vm.listW
                    Layout.fillWidth: vm.narrow
                    visible: !vm.narrow || !vm.showDetail

                    ColumnLayout {
                        anchors.fill: parent
                        spacing: 0

                        // libvirt no responde / falta algo
                        Item {
                            Layout.fillWidth: true
                            Layout.fillHeight: true
                            visible: Vm.detected && !Vm.requirementsMet
                            ColumnLayout {
                                anchors.centerIn: parent
                                width: Math.min(parent.width - 32, 380)
                                spacing: 10
                                Text {
                                    Layout.fillWidth: true
                                    text: Icons.info; color: Theme.yellow
                                    font.family: Theme.fontFamily; font.pixelSize: Theme.fontSize + 10
                                    horizontalAlignment: Text.AlignHCenter
                                }
                                Text {
                                    Layout.fillWidth: true
                                    text: I18n.t("libvirt is not ready on this system.")
                                    color: Theme.text; wrapMode: Text.Wrap
                                    horizontalAlignment: Text.AlignHCenter
                                    font.family: Theme.fontFamily; font.pixelSize: Theme.fontSize
                                }
                                Text {
                                    Layout.fillWidth: true
                                    text: I18n.t("Open Settings → Virtualization for the exact setup steps for your system.")
                                    color: Theme.subtext0; wrapMode: Text.Wrap
                                    horizontalAlignment: Text.AlignHCenter
                                    font.family: Theme.fontFamily; font.pixelSize: Theme.fontSize - 2
                                }
                                ActBtn {
                                    Layout.alignment: Qt.AlignHCenter
                                    glyph: Icons.gear; label: I18n.t("Open Settings")
                                    onClicked: { Panels.close("vmManager"); Panels.openSettingsAt("virtualization"); }
                                }
                            }
                        }

                        // lista vacía
                        Item {
                            Layout.fillWidth: true
                            Layout.fillHeight: true
                            visible: Vm.requirementsMet && Vm.vms.length === 0
                            ColumnLayout {
                                anchors.centerIn: parent
                                width: Math.min(parent.width - 32, 320)
                                spacing: 10
                                Text {
                                    Layout.fillWidth: true
                                    text: Icons.desktop; color: Theme.overlay1
                                    font.family: Theme.fontFamily; font.pixelSize: Theme.fontSize + 14
                                    horizontalAlignment: Text.AlignHCenter
                                }
                                Text {
                                    Layout.fillWidth: true
                                    text: I18n.t("No virtual machines yet")
                                    color: Theme.subtext0; wrapMode: Text.Wrap
                                    horizontalAlignment: Text.AlignHCenter
                                    font.family: Theme.fontFamily; font.pixelSize: Theme.fontSize - 1
                                }
                                ActBtn {
                                    Layout.alignment: Qt.AlignHCenter
                                    glyph: Icons.plus; label: I18n.t("Create a VM")
                                    tint: Theme.accent
                                    onClicked: { vm.newName = ""; vm.creating = true; }
                                }
                            }
                        }

                        ListView {
                            Layout.fillWidth: true
                            Layout.fillHeight: true
                            visible: Vm.vms.length > 0
                            clip: true
                            spacing: 4
                            topMargin: 8; bottomMargin: 8
                            leftMargin: 8; rightMargin: 8
                            model: Vm.vms
                            boundsBehavior: Flickable.StopAtBounds

                            delegate: Rectangle {
                                id: vrow
                                required property var modelData
                                readonly property bool isSel: modelData.name === vm.selected
                                width: ListView.view.width - 16
                                height: 54
                                radius: Theme.radius
                                color: isSel ? Theme.accent
                                     : (vMa.containsMouse ? Theme.surface1 : Theme.surface0)
                                Behavior on color { ColorAnimation { duration: Theme.dur(120) } }

                                RowLayout {
                                    anchors.fill: parent
                                    anchors.leftMargin: 12; anchors.rightMargin: 12
                                    spacing: 10
                                    Rectangle {
                                        Layout.alignment: Qt.AlignVCenter
                                        width: 9; height: 9; radius: 4.5
                                        color: vm.stateColor(vrow.modelData.state)
                                    }
                                    ColumnLayout {
                                        Layout.fillWidth: true
                                        spacing: 1
                                        Text {
                                            Layout.fillWidth: true
                                            text: vrow.modelData.name
                                            color: vrow.isSel ? Theme.onAccent : Theme.text
                                            font.family: Theme.fontFamily; font.pixelSize: Theme.fontSize - 1
                                            font.bold: true
                                            elide: Text.ElideRight
                                        }
                                        Text {
                                            Layout.fillWidth: true
                                            text: vm.stateLabel(vrow.modelData.state) + " · "
                                                  + vrow.modelData.vcpus + " vCPU · "
                                                  + vm.fmtMem(vrow.modelData.maxMemKib)
                                            color: vrow.isSel ? Theme.onAccent : Theme.subtext0
                                            font.family: Theme.fontFamily; font.pixelSize: Theme.fontSize - 3
                                            elide: Text.ElideRight
                                            opacity: vrow.isSel ? 0.85 : 1
                                        }
                                    }
                                }
                                MouseArea {
                                    id: vMa
                                    anchors.fill: parent; hoverEnabled: true; cursorShape: Qt.PointingHandCursor
                                    onClicked: vm.pick(vrow.modelData.name)
                                }
                            }
                        }
                    }
                }

                Rectangle {
                    Layout.preferredWidth: 1
                    Layout.fillHeight: true
                    color: Theme.surface1
                    visible: !vm.narrow
                }

                // ---- detalle ----
                Item {
                    Layout.fillWidth: true
                    Layout.fillHeight: true
                    visible: !vm.narrow || vm.showDetail

                    // sin selección (solo puede pasar en ancho)
                    Text {
                        anchors.centerIn: parent
                        visible: vm.sel === null
                        text: I18n.t("Select a virtual machine")
                        color: Theme.overlay2
                        font.family: Theme.fontFamily; font.pixelSize: Theme.fontSize
                    }

                    ColumnLayout {
                        anchors.fill: parent
                        anchors.margins: 14
                        spacing: 12
                        visible: vm.sel !== null

                        // ---- barra de acciones: Flow, no Row ----
                        Flow {
                            Layout.fillWidth: true
                            spacing: 6

                            ActBtn {
                                glyph: Icons.play; label: I18n.t("Start")
                                tint: Theme.green
                                enabled: !Vm.busy && vm.sel && vm.sel.state === "shut off"
                                onClicked: Vm.start(vm.selected)
                            }
                            ActBtn {
                                glyph: Icons.pause; label: I18n.t("Pause")
                                tint: Theme.yellow
                                enabled: !Vm.busy && vm.sel && vm.sel.state === "running"
                                onClicked: Vm.suspend(vm.selected)
                            }
                            ActBtn {
                                glyph: Icons.play; label: I18n.t("Resume")
                                tint: Theme.green
                                visible: vm.sel && vm.sel.state === "paused"
                                enabled: !Vm.busy
                                onClicked: Vm.resume(vm.selected)
                            }
                            ActBtn {
                                glyph: Icons.power; label: I18n.t("Shut down")
                                enabled: !Vm.busy && vm.sel && (vm.sel.state === "running" || vm.sel.state === "paused")
                                onClicked: Vm.shutdown(vm.selected)
                            }
                            // ---- destructivas: SIEMPRE con confirmación ----
                            ActBtn {
                                glyph: Icons.power; label: I18n.t("Force off")
                                danger: true; tint: Theme.red
                                enabled: !Vm.busy && vm.sel && vm.sel.state !== "shut off"
                                onClicked: vm.ask(I18n.t("Force off?"),
                                    I18n.t("Cuts power to the VM as if you pulled the plug. Unsaved work inside the guest is lost."),
                                    I18n.t("Force off"), true, function() { Vm.destroy_(vm.selected); })
                            }
                            ActBtn {
                                glyph: Icons.reboot; label: I18n.t("Hard reset")
                                danger: true; tint: Theme.red
                                enabled: !Vm.busy && vm.sel && vm.sel.state === "running"
                                onClicked: vm.ask(I18n.t("Hard reset?"),
                                    I18n.t("Resets the VM immediately, without letting the guest shut down. Unsaved work inside the guest is lost."),
                                    I18n.t("Hard reset"), true, function() { Vm.reset_(vm.selected); })
                            }
                        }

                        // ---- abrir la VM ----
                        Flow {
                            Layout.fillWidth: true
                            spacing: 6
                            ActBtn {
                                glyph: Icons.desktop; label: I18n.t("Open display")
                                tint: Theme.blue
                                // Sin virt-viewer NO se rompe nada: el botón
                                // desaparece y queda la consola de texto.
                                visible: Vm.has.viewer
                                enabled: vm.sel && vm.sel.state !== "shut off"
                                onClicked: Vm.openViewer(vm.selected)
                            }
                            ActBtn {
                                glyph: Icons.bars; label: I18n.t("Text console")
                                tint: Theme.mauve
                                enabled: vm.sel && vm.sel.state !== "shut off"
                                onClicked: Vm.openConsole(vm.selected)
                            }
                        }

                        // ---- pestañas ----
                        //  `Flow` para que en una ventana estrecha bajen de
                        //  línea en vez de apretarse; más aire alrededor y
                        //  pastillas más altas, que era la queja.
                        Flow {
                            Layout.fillWidth: true
                            Layout.topMargin: 4
                            Layout.bottomMargin: 4
                            spacing: 8
                            Repeater {
                                model: [
                                    { k: "overview",  l: I18n.t("Overview") },
                                    { k: "system",    l: I18n.t("System") },
                                    { k: "storage",   l: I18n.t("Storage") },
                                    { k: "network",   l: I18n.t("Network") },
                                    { k: "devices",   l: I18n.t("Devices") },
                                    { k: "snapshots", l: I18n.t("Snapshots") },
                                    { k: "networks",  l: I18n.t("Host networks") }
                                ]
                                delegate: Rectangle {
                                    required property var modelData
                                    readonly property bool on: vm.tab === modelData.k
                                    implicitWidth: tTxt.implicitWidth + 28
                                    implicitHeight: 34
                                    radius: Theme.radius
                                    color: on ? Theme.surface2 : (tMa.containsMouse ? Theme.surface1 : "transparent")
                                    Text {
                                        id: tTxt
                                        anchors.centerIn: parent
                                        text: modelData.l
                                        color: parent.on ? Theme.text : Theme.subtext0
                                        font.family: Theme.fontFamily
                                        font.pixelSize: Theme.fontSize - 2
                                        font.bold: parent.on
                                    }
                                    MouseArea {
                                        id: tMa
                                        anchors.fill: parent; hoverEnabled: true; cursorShape: Qt.PointingHandCursor
                                        onClicked: {
                                            vm.tab = modelData.k;
                                            if (modelData.k === "snapshots") Vm.snapshots_(vm.selected);
                                        }
                                    }
                                }
                            }
                        }

                        // ---- cuerpo de la pestaña (siempre rueda) ----
                        Flickable {
                            Layout.fillWidth: true
                            Layout.fillHeight: true
                            contentHeight: tabBody.implicitHeight
                            clip: true
                            boundsBehavior: Flickable.StopAtBounds

                            ColumnLayout {
                                id: tabBody
                                width: parent.width
                                spacing: 10

                                // ======== resumen ========
                                ColumnLayout {
                                    Layout.fillWidth: true
                                    visible: vm.tab === "overview"
                                    spacing: 8
                                    Repeater {
                                        model: vm.sel ? [
                                            { l: I18n.t("State"),      v: vm.stateLabel(vm.sel.state) },
                                            { l: I18n.t("vCPUs"),      v: "" + vm.sel.vcpus },
                                            { l: I18n.t("Max memory"), v: vm.fmtMem(vm.sel.maxMemKib) },
                                            { l: I18n.t("Memory in use"), v: vm.fmtMem(vm.sel.curMemKib) },
                                            { l: I18n.t("Autostart"),  v: vm.sel.autostart ? I18n.t("On") : I18n.t("Off") },
                                            { l: "UUID",               v: vm.sel.uuid }
                                        ] : []
                                        delegate: RowLayout {
                                            required property var modelData
                                            Layout.fillWidth: true
                                            spacing: 10
                                            Text {
                                                Layout.preferredWidth: Math.min(150, tabBody.width * 0.4)
                                                text: modelData.l; color: Theme.subtext0
                                                font.family: Theme.fontFamily; font.pixelSize: Theme.fontSize - 1
                                                elide: Text.ElideRight
                                            }
                                            Text {
                                                Layout.fillWidth: true
                                                text: modelData.v; color: Theme.text
                                                font.family: Theme.fontFamily; font.pixelSize: Theme.fontSize - 1
                                                elide: Text.ElideRight
                                            }
                                        }
                                    }
                                    RowLayout {
                                        Layout.fillWidth: true
                                        Layout.topMargin: 4
                                        spacing: 10
                                        Text {
                                            Layout.fillWidth: true
                                            text: I18n.t("Start this VM when the host boots")
                                            color: Theme.subtext0; wrapMode: Text.Wrap
                                            font.family: Theme.fontFamily; font.pixelSize: Theme.fontSize - 1
                                        }
                                        Toggle {
                                            checked: vm.sel ? vm.sel.autostart : false
                                            onToggled: function(v) { Vm.setAutostart(vm.selected, v); }
                                        }
                                    }
                                    Sec { text: I18n.t("NOTES") }
                                    RowLayout {
                                        Layout.fillWidth: true
                                        spacing: 8
                                        Field {
                                            id: descField
                                            label: I18n.t("Description")
                                            placeholder: Vm.detail.desc !== "" ? Vm.detail.desc : I18n.t("What this VM is for…")
                                        }
                                        ActBtn {
                                            Layout.alignment: Qt.AlignBottom
                                            Layout.bottomMargin: 12
                                            glyph: Icons.check; label: I18n.t("Save")
                                            enabled: !Vm.busy
                                            onClicked: { Vm.setDescription(vm.selected, descField.text); descField.text = ""; }
                                        }
                                    }

                                    Sec { text: I18n.t("MANAGE") }
                                    Flow {
                                        Layout.fillWidth: true
                                        spacing: 6
                                        ActBtn {
                                            glyph: Icons.pencil; label: I18n.t("Rename")
                                            enabled: !Vm.busy && !vm.running
                                            onClicked: vm.ask2(I18n.t("Rename this VM"),
                                                I18n.t("Only the VM's name changes; its disks keep their current file names."),
                                                [ { key: "name", label: I18n.t("New name"), value: vm.selected } ],
                                                I18n.t("Rename"),
                                                function(v) {
                                                    if (v.name !== "" && v.name !== vm.selected && Vm.validName(v.name) && !Vm.nameTaken(v.name))
                                                        Vm.renameVm(vm.selected, v.name);
                                                })
                                        }
                                        ActBtn {
                                            glyph: Icons.copy; label: I18n.t("Clone")
                                            enabled: !Vm.busy && !vm.running
                                            onClicked: vm.ask2(I18n.t("Clone this VM"),
                                                I18n.t("Makes a full copy of the disk and defines a new VM with its own identity."),
                                                [ { key: "name", label: I18n.t("Name for the copy"), value: vm.selected + "-copy" } ],
                                                I18n.t("Clone"),
                                                function(v) {
                                                    if (v.name !== "" && Vm.validName(v.name) && !Vm.nameTaken(v.name))
                                                        Vm.cloneVm(vm.selected, v.name);
                                                })
                                        }
                                        ActBtn {
                                            glyph: Icons.archive; label: I18n.t("Export as .ova")
                                            tint: Theme.teal
                                            enabled: !Vm.busy && !vm.running
                                            onClicked: vm.ask2(I18n.t("Export this VM as an .ova"),
                                                I18n.t("An .ova can be opened by VirtualBox and VMware. The disk is converted to VMDK, which takes a while and needs free space for a temporary copy."),
                                                [ { key: "path", label: I18n.t("Save to"), pick: "save", pickKind: "ova",
                                                    value: Quickshell.env("HOME") + "/" + vm.selected + ".ova" } ],
                                                I18n.t("Export"),
                                                function(v) { if (v.path !== "") Vm.exportOva(vm.selected, v.path); })
                                        }
                                        ActBtn {
                                            glyph: Icons.download; label: I18n.t("Export XML")
                                            enabled: !Vm.busy
                                            onClicked: vm.ask2(I18n.t("Export this VM's definition"),
                                                I18n.t("Writes libvirt's domain XML. It describes the VM, not its disk."),
                                                [ { key: "path", label: I18n.t("Save to"), pick: "save", pickKind: "xml",
                                                    value: Quickshell.env("HOME") + "/" + vm.selected + ".xml" } ],
                                                I18n.t("Export"),
                                                function(v) { if (v.path !== "") Vm.exportVm(vm.selected, v.path); })
                                        }
                                    }
                                    Note {
                                        visible: vm.running
                                        tone: "warn"
                                        text: I18n.t("Renaming and cloning need the VM shut off — while it runs, QEMU holds a write lock on the disk image.")
                                    }

                                    ActBtn {
                                        Layout.topMargin: 8
                                        glyph: Icons.trash; label: I18n.t("Delete VM")
                                        danger: true; tint: Theme.red
                                        enabled: !Vm.busy
                                        onClicked: vm.ask(I18n.t("Delete this VM?"),
                                            I18n.t("Removes the VM definition, its snapshots and its disk image. This cannot be undone."),
                                            I18n.t("Delete"), true, function() { Vm.remove(vm.selected, true); })
                                    }
                                }

                                // ======== sistema ========
                                ColumnLayout {
                                    Layout.fillWidth: true
                                    visible: vm.tab === "system"
                                    spacing: 10

                                    Note {
                                        visible: vm.running
                                        text: I18n.t("This VM is running. Memory and vCPUs apply live where libvirt allows it; everything else on this page takes effect on next boot.")
                                    }

                                    Sec { text: I18n.t("MEMORY AND CPU") }
                                    RowLayout {
                                        Layout.fillWidth: true
                                        spacing: 8
                                        Field {
                                            id: hwMem
                                            label: I18n.t("Memory (MiB)")
                                            numeric: true
                                            placeholder: vm.sel ? "" + Math.round(vm.sel.maxMemKib / 1024) : "2048"
                                        }
                                        ActBtn {
                                            Layout.alignment: Qt.AlignBottom
                                            Layout.bottomMargin: 12
                                            glyph: Icons.check; label: I18n.t("Apply")
                                            enabled: !Vm.busy && hwMem.text !== ""
                                            onClicked: {
                                                var mib = parseInt(hwMem.text, 10);
                                                if (vm.running) Vm.setMem(vm.selected, mib, true);
                                                else Vm.setMaxMem(vm.selected, mib);
                                                hwMem.text = "";
                                            }
                                        }
                                    }
                                    Note {
                                        visible: vm.running
                                        tone: "warn"
                                        text: I18n.t("While running, memory can only move within its current maximum. Shut the VM down to raise the maximum.")
                                    }
                                    RowLayout {
                                        Layout.fillWidth: true
                                        spacing: 8
                                        Field {
                                            id: hwCpu
                                            label: I18n.t("vCPUs")
                                            numeric: true
                                            placeholder: vm.sel ? "" + vm.sel.vcpus : "2"
                                        }
                                        ActBtn {
                                            Layout.alignment: Qt.AlignBottom
                                            Layout.bottomMargin: 12
                                            glyph: Icons.check; label: I18n.t("Apply")
                                            enabled: !Vm.busy && hwCpu.text !== ""
                                            onClicked: {
                                                Vm.setVcpus(vm.selected, parseInt(hwCpu.text, 10), vm.running);
                                                hwCpu.text = "";
                                            }
                                        }
                                    }

                                    Sec { text: I18n.t("CPU TOPOLOGY") }
                                    Note { text: I18n.t("Sockets × cores × threads must equal the vCPU count. Leave at 0 to let libvirt decide.") }
                                    RowLayout {
                                        Layout.fillWidth: true
                                        spacing: 8
                                        Field { id: topoS; label: I18n.t("Sockets"); numeric: true
                                                placeholder: Vm.detail.cpu && Vm.detail.cpu.sockets !== "" ? Vm.detail.cpu.sockets : "0" }
                                        Field { id: topoC; label: I18n.t("Cores"); numeric: true
                                                placeholder: Vm.detail.cpu && Vm.detail.cpu.cores !== "" ? Vm.detail.cpu.cores : "0" }
                                        Field { id: topoT; label: I18n.t("Threads"); numeric: true
                                                placeholder: Vm.detail.cpu && Vm.detail.cpu.threads !== "" ? Vm.detail.cpu.threads : "0" }
                                        ActBtn {
                                            Layout.alignment: Qt.AlignBottom
                                            Layout.bottomMargin: 12
                                            glyph: Icons.check; label: I18n.t("Apply")
                                            enabled: !Vm.busy
                                            onClicked: Vm.setCpuTopology(vm.selected,
                                                parseInt(topoS.text || "0", 10) || 0,
                                                parseInt(topoC.text || "0", 10) || 0,
                                                parseInt(topoT.text || "0", 10) || 0)
                                        }
                                    }

                                    Sec { text: I18n.t("FIRMWARE") }
                                    Segmented {
                                        Layout.fillWidth: true
                                        value: Vm.detail.firmware
                                        options: [ { key: "bios", label: "BIOS" }, { key: "uefi", label: "UEFI" } ]
                                        onPicked: function(k) {
                                            if (k === Vm.detail.firmware) return;
                                            vm.ask(I18n.t("Change firmware?"),
                                                I18n.t("A guest installed under one firmware usually will not boot under the other. Only change this on a VM you have not installed yet."),
                                                I18n.t("Change"), true, function() { Vm.setFirmware(vm.selected, k); });
                                        }
                                    }

                                    Sec { text: I18n.t("BOOT ORDER") }
                                    Note { text: I18n.t("The VM tries each entry in order. Use the arrows to reorder.") }
                                    Repeater {
                                        model: Vm.detail.boot
                                        delegate: RowLayout {
                                            required property var modelData
                                            required property int index
                                            Layout.fillWidth: true
                                            spacing: 8
                                            Text {
                                                Layout.preferredWidth: 20
                                                text: (index + 1) + "."
                                                color: Theme.subtext0
                                                font.family: Theme.fontFamily; font.pixelSize: Theme.fontSize - 1
                                            }
                                            Text {
                                                Layout.fillWidth: true
                                                text: modelData === "hd" ? I18n.t("Hard disk")
                                                    : modelData === "cdrom" ? I18n.t("Optical drive")
                                                    : modelData === "network" ? I18n.t("Network (PXE)") : modelData
                                                color: Theme.text
                                                font.family: Theme.fontFamily; font.pixelSize: Theme.fontSize - 1
                                            }
                                            ActBtn {
                                                glyph: Icons.arrowUp; enabled: !Vm.busy && index > 0
                                                onClicked: {
                                                    var l = Vm.detail.boot.slice();
                                                    var t = l[index]; l[index] = l[index - 1]; l[index - 1] = t;
                                                    Vm.setBootOrder(vm.selected, l);
                                                }
                                            }
                                            ActBtn {
                                                glyph: Icons.arrowDown
                                                enabled: !Vm.busy && index < Vm.detail.boot.length - 1
                                                onClicked: {
                                                    var l = Vm.detail.boot.slice();
                                                    var t = l[index]; l[index] = l[index + 1]; l[index + 1] = t;
                                                    Vm.setBootOrder(vm.selected, l);
                                                }
                                            }
                                            ActBtn {
                                                glyph: Icons.close; danger: true; tint: Theme.red
                                                enabled: !Vm.busy && Vm.detail.boot.length > 1
                                                onClicked: {
                                                    var l = Vm.detail.boot.slice();
                                                    l.splice(index, 1);
                                                    Vm.setBootOrder(vm.selected, l);
                                                }
                                            }
                                        }
                                    }
                                    Flow {
                                        Layout.fillWidth: true
                                        spacing: 6
                                        Repeater {
                                            model: [ { k: "hd", l: I18n.t("Hard disk") },
                                                     { k: "cdrom", l: I18n.t("Optical drive") },
                                                     { k: "network", l: I18n.t("Network (PXE)") } ]
                                            delegate: ActBtn {
                                                required property var modelData
                                                glyph: Icons.plus
                                                label: modelData.l
                                                enabled: !Vm.busy && Vm.detail.boot.indexOf(modelData.k) === -1
                                                onClicked: {
                                                    var l = Vm.detail.boot.slice();
                                                    l.push(modelData.k);
                                                    Vm.setBootOrder(vm.selected, l);
                                                }
                                            }
                                        }
                                    }
                                }

                                // ======== almacenamiento ========
                                ColumnLayout {
                                    Layout.fillWidth: true
                                    visible: vm.tab === "storage"
                                    spacing: 10

                                    Sec { text: I18n.t("CONTROLLERS") }
                                    Flow {
                                        Layout.fillWidth: true
                                        spacing: 6
                                        Repeater {
                                            model: Vm.detail.ctrls.filter(function(c) { return c.type !== "pci" && c.type !== "usb"; })
                                            delegate: Rectangle {
                                                required property var modelData
                                                implicitWidth: cTxt.implicitWidth + 20
                                                implicitHeight: 26
                                                radius: Theme.radius
                                                color: Theme.surface0
                                                border.width: 1; border.color: Theme.overlay0
                                                Text {
                                                    id: cTxt
                                                    anchors.centerIn: parent
                                                    text: modelData.type + (modelData.model !== "" ? " · " + modelData.model : "")
                                                          + " #" + modelData.index
                                                    color: Theme.subtext1
                                                    font.family: Theme.fontFamily; font.pixelSize: Theme.fontSize - 3
                                                }
                                            }
                                        }
                                    }
                                    Flow {
                                        Layout.fillWidth: true
                                        spacing: 6
                                        ActBtn {
                                            glyph: Icons.plus; label: I18n.t("Add virtio-SCSI controller")
                                            enabled: !Vm.busy
                                            onClicked: Vm.addController(vm.selected, "scsi", "virtio-scsi")
                                        }
                                    }

                                    //  ⚠️ El "cargo el driver y sigue sin salir ningún
                                    //  disco" tenía DOS mitades, y las dos se dicen aquí:
                                    //
                                    //   1. `virsh attach-disk --targetbus scsi` no declara
                                    //      modelo y libvirt elegía **lsilogic**, para la
                                    //      que ni Windows ni virtio-win tienen driver
                                    //      (vioscsi solo se engancha a virtio-scsi). Eso ya
                                    //      está arreglado: Vm.scsiGuard fuerza virtio-scsi
                                    //      antes de enchufar cualquier disco SCSI.
                                    //   2. virtio-blk y virtio-scsi NECESITAN el driver de
                                    //      virtio-win, que NO viene en el ISO de Windows y
                                    //      hay que descargar aparte. Sin él no hay nada que
                                    //      cargar en "Cargar controlador", por mucho que se
                                    //      abra esa pantalla. SATA no necesita nada.
                                    Note {
                                        text: I18n.t("Windows has no built-in driver for virtio or virtio-SCSI disks. Put the system disk on SATA and the installer sees it with no driver at all. To use virtio you must first download the separate virtio-win ISO, add it as a second optical drive here, and load vioscsi (or viostor) from it in the installer's \"Load driver\" screen — it is not on the Windows ISO.")
                                    }

                                    Sec { text: I18n.t("DISKS") }
                                    Repeater {
                                        model: Vm.detail.disks.filter(function(d) { return d.device === "disk"; })
                                        delegate: Rectangle {
                                            required property var modelData
                                            Layout.fillWidth: true
                                            implicitHeight: dkCol.implicitHeight + 16
                                            radius: Theme.radius
                                            color: Theme.surface0
                                            border.width: 1; border.color: Theme.overlay0
                                            ColumnLayout {
                                                id: dkCol
                                                anchors.left: parent.left; anchors.right: parent.right
                                                anchors.verticalCenter: parent.verticalCenter
                                                anchors.leftMargin: 12; anchors.rightMargin: 12
                                                spacing: 4
                                                RowLayout {
                                                    Layout.fillWidth: true
                                                    spacing: 8
                                                    Text {
                                                        text: Icons.drive; color: Theme.blue
                                                        font.family: Theme.fontFamily; font.pixelSize: Theme.fontSize
                                                    }
                                                    Text {
                                                        Layout.fillWidth: true
                                                        text: modelData.target + "  ·  " + modelData.bus
                                                              + "  ·  " + vm.fmtBytes(modelData.capacity)
                                                              + (modelData.format !== "" ? "  ·  " + modelData.format : "")
                                                        color: Theme.text
                                                        font.family: Theme.fontFamily; font.pixelSize: Theme.fontSize - 1
                                                        font.bold: true
                                                        elide: Text.ElideRight
                                                    }
                                                }
                                                Text {
                                                    Layout.fillWidth: true
                                                    text: modelData.path
                                                    color: Theme.subtext0
                                                    font.family: Theme.fontFamily; font.pixelSize: Theme.fontSize - 3
                                                    elide: Text.ElideMiddle
                                                }
                                                Flow {
                                                    Layout.fillWidth: true
                                                    spacing: 6
                                                    ActBtn {
                                                        glyph: Icons.close; label: I18n.t("Detach")
                                                        enabled: !Vm.busy
                                                        onClicked: vm.ask(I18n.t("Detach this disk?"),
                                                            I18n.t("The disk is removed from the VM. The image file is kept and can be attached again later."),
                                                            I18n.t("Detach"), false,
                                                            function() { Vm.detachDisk(vm.selected, modelData.target); })
                                                    }
                                                    ActBtn {
                                                        glyph: Icons.trash; label: I18n.t("Detach and delete file")
                                                        danger: true; tint: Theme.red
                                                        enabled: !Vm.busy
                                                        onClicked: vm.ask(I18n.t("Delete this disk image?"),
                                                            I18n.t("The disk is detached AND its image file is erased from disk. Everything stored on it is lost. This cannot be undone."),
                                                            I18n.t("Delete image"), true,
                                                            function() { Vm.detachAndDeleteDisk(vm.selected, modelData.target, modelData.path); })
                                                    }
                                                }
                                            }
                                        }
                                    }
                                    Flow {
                                        Layout.fillWidth: true
                                        spacing: 6
                                        ActBtn {
                                            glyph: Icons.plus; label: I18n.t("New disk"); tint: Theme.accent
                                            enabled: !Vm.busy
                                            onClicked: vm.ask2(I18n.t("Add a new disk"),
                                                I18n.t("Creates a new qcow2 image in libvirt's default pool and attaches it."),
                                                [ { key: "name", label: I18n.t("Image name"), value: vm.selected + "-disk2" },
                                                  { key: "size", label: I18n.t("Size (GiB)"), value: "10", numeric: true },
                                                  { key: "bus",  label: I18n.t("Bus (virtio / sata / scsi)"), value: "virtio" } ],
                                                I18n.t("Create and attach"),
                                                function(v) { Vm.addDisk(vm.selected, v.name, parseInt(v.size, 10) || 10, v.bus || "virtio"); })
                                        }
                                        ActBtn {
                                            glyph: Icons.folder; label: I18n.t("Attach existing image")
                                            enabled: !Vm.busy
                                            onClicked: vm.ask2(I18n.t("Attach an existing image"),
                                                I18n.t("Point at a qcow2 or raw image already on disk."),
                                                [ { key: "path", label: I18n.t("Path to the image"), value: "", pick: "file", pickKind: "disk" },
                                                  { key: "bus",  label: I18n.t("Bus (virtio / sata / scsi)"), value: "virtio" } ],
                                                I18n.t("Attach"),
                                                function(v) { if (v.path !== "") Vm.attachExistingDisk(vm.selected, v.path, v.bus || "virtio"); })
                                        }
                                    }

                                    Sec { text: I18n.t("OPTICAL DRIVES") }
                                    Repeater {
                                        model: Vm.detail.disks.filter(function(d) { return d.device === "cdrom"; })
                                        delegate: Rectangle {
                                            required property var modelData
                                            Layout.fillWidth: true
                                            implicitHeight: cdCol.implicitHeight + 16
                                            radius: Theme.radius
                                            color: Theme.surface0
                                            border.width: 1; border.color: Theme.overlay0
                                            ColumnLayout {
                                                id: cdCol
                                                anchors.left: parent.left; anchors.right: parent.right
                                                anchors.verticalCenter: parent.verticalCenter
                                                anchors.leftMargin: 12; anchors.rightMargin: 12
                                                spacing: 4
                                                RowLayout {
                                                    Layout.fillWidth: true
                                                    spacing: 8
                                                    Text {
                                                        text: Icons.archive; color: Theme.mauve
                                                        font.family: Theme.fontFamily; font.pixelSize: Theme.fontSize
                                                    }
                                                    Text {
                                                        Layout.fillWidth: true
                                                        text: modelData.target + "  ·  "
                                                              + (modelData.path === "" ? I18n.t("Empty") : modelData.path)
                                                        color: Theme.text
                                                        font.family: Theme.fontFamily; font.pixelSize: Theme.fontSize - 1
                                                        elide: Text.ElideMiddle
                                                    }
                                                }
                                                Flow {
                                                    Layout.fillWidth: true
                                                    spacing: 6
                                                    ActBtn {
                                                        glyph: Icons.archive; label: I18n.t("Insert ISO")
                                                        tint: Theme.mauve
                                                        enabled: !Vm.busy
                                                        onClicked: vm.ask2(I18n.t("Insert an ISO"), "",
                                                            [ { key: "iso", label: I18n.t("Path to an .iso file"), value: "", pick: "file", pickKind: "iso" } ],
                                                            I18n.t("Insert"),
                                                            function(v) { if (v.iso !== "") Vm.insertCd(vm.selected, modelData.target, v.iso); })
                                                    }
                                                    ActBtn {
                                                        glyph: Icons.close; label: I18n.t("Eject")
                                                        enabled: !Vm.busy && modelData.path !== ""
                                                        onClicked: Vm.ejectCd(vm.selected, modelData.target)
                                                    }
                                                    ActBtn {
                                                        glyph: Icons.trash; label: I18n.t("Remove drive")
                                                        danger: true; tint: Theme.red
                                                        enabled: !Vm.busy
                                                        onClicked: vm.ask(I18n.t("Remove this optical drive?"),
                                                            I18n.t("The drive is removed from the VM. No file is deleted."),
                                                            I18n.t("Remove"), false,
                                                            function() { Vm.detachDisk(vm.selected, modelData.target); })
                                                    }
                                                }
                                            }
                                        }
                                    }
                                    ActBtn {
                                        glyph: Icons.plus; label: I18n.t("Add optical drive")
                                        enabled: !Vm.busy
                                        onClicked: vm.ask2(I18n.t("Add an optical drive"),
                                            I18n.t("Leave the path empty to add an empty drive."),
                                            [ { key: "iso", label: I18n.t("Path to an .iso file (optional)"), value: "", pick: "file", pickKind: "iso" } ],
                                            I18n.t("Add"),
                                            function(v) { Vm.addCdrom(vm.selected, v.iso); })
                                    }
                                }

                                // ======== red de la VM ========
                                ColumnLayout {
                                    Layout.fillWidth: true
                                    visible: vm.tab === "network"
                                    spacing: 10

                                    onVisibleChanged: if (visible) Vm.loadBridges()

                                    Sec { text: I18n.t("NETWORK ADAPTERS") }
                                    Repeater {
                                        model: Vm.detail.nics
                                        delegate: Rectangle {
                                            required property var modelData
                                            Layout.fillWidth: true
                                            implicitHeight: nicCol.implicitHeight + 16
                                            radius: Theme.radius
                                            color: Theme.surface0
                                            border.width: 1; border.color: Theme.overlay0
                                            ColumnLayout {
                                                id: nicCol
                                                anchors.left: parent.left; anchors.right: parent.right
                                                anchors.verticalCenter: parent.verticalCenter
                                                anchors.leftMargin: 12; anchors.rightMargin: 12
                                                spacing: 4
                                                RowLayout {
                                                    Layout.fillWidth: true
                                                    spacing: 8
                                                    Rectangle {
                                                        width: 9; height: 9; radius: 4.5
                                                        color: modelData.link === "down" ? Theme.overlay2 : Theme.green
                                                    }
                                                    Text {
                                                        Layout.fillWidth: true
                                                        //  ⚠️ NO poner "NAT" fijo porque el tipo de interfaz
                                                        //  sea `network`: eso es el tipo de ENGANCHE, no lo que
                                                        //  la red hace. Con redes propias (host-only, interna)
                                                        //  todas salían rotuladas "NAT", que es justo lo
                                                        //  contrario de lo que son. Se mira el modo de LA RED.
                                                        text: modelData.source + "  ·  " + modelData.model
                                                              + "  ·  " + (modelData.type === "network"
                                                                           ? vm.netModeLabel(vm.netModeOf(modelData.source))
                                                                           : modelData.type)
                                                        color: Theme.text
                                                        font.family: Theme.fontFamily; font.pixelSize: Theme.fontSize - 1
                                                        font.bold: true
                                                        elide: Text.ElideRight
                                                    }
                                                }
                                                Text {
                                                    Layout.fillWidth: true
                                                    text: modelData.mac
                                                    color: Theme.subtext0
                                                    font.family: Theme.fontFamily; font.pixelSize: Theme.fontSize - 3
                                                }
                                                //  ⚠️ EL MODELO DE LA TARJETA, que antes no se podía
                                                //  ni ver ni cambiar y estaba fijo en virtio para
                                                //  todo el mundo. Windows NO trae driver en caja
                                                //  para virtio-net: el adaptador sale como
                                                //  desconocido en el Administrador de dispositivos
                                                //  y el invitado se queda SIN RED — por NAT y por
                                                //  puente igual, que es justo lo que se veía. Linux
                                                //  sí lo trae, de ahí que la misma red `default`
                                                //  funcionara en Ubuntu y no en Windows.
                                                Segmented {
                                                    Layout.fillWidth: true
                                                    value: modelData.model
                                                    options: [ { key: "virtio", label: "virtio-net" },
                                                               { key: "e1000e", label: "e1000e" },
                                                               { key: "rtl8139", label: "rtl8139" } ]
                                                    onPicked: function(k) {
                                                        if (k !== modelData.model)
                                                            Vm.setNicModel(vm.selected, modelData.mac, k);
                                                    }
                                                }
                                                Text {
                                                    Layout.fillWidth: true
                                                    visible: modelData.model === "virtio"
                                                    text: I18n.t("virtio-net has no built-in Windows driver. On a Windows guest switch to e1000e, or install NetKVM from the virtio-win ISO inside the guest. Linux has virtio-net built in and should stay on it.")
                                                    color: Theme.subtext0; wrapMode: Text.Wrap
                                                    font.family: Theme.fontFamily; font.pixelSize: Theme.fontSize - 3
                                                }
                                                Flow {
                                                    Layout.fillWidth: true
                                                    spacing: 6
                                                    ActBtn {
                                                        glyph: Icons.wifi; label: I18n.t("Connect"); tint: Theme.green
                                                        enabled: !Vm.busy && vm.running
                                                        onClicked: Vm.setLink(vm.selected, true)
                                                    }
                                                    ActBtn {
                                                        glyph: Icons.noNetwork; label: I18n.t("Disconnect"); tint: Theme.peach
                                                        enabled: !Vm.busy && vm.running
                                                        onClicked: Vm.setLink(vm.selected, false)
                                                    }
                                                    ActBtn {
                                                        glyph: Icons.trash; label: I18n.t("Remove")
                                                        danger: true; tint: Theme.red
                                                        enabled: !Vm.busy
                                                        onClicked: vm.ask(I18n.t("Remove this network adapter?"),
                                                            I18n.t("The VM loses this network interface."),
                                                            I18n.t("Remove"), true,
                                                            function() { Vm.removeNic(vm.selected, modelData.mac); })
                                                    }
                                                }
                                            }
                                        }
                                    }
                                    Sec { text: I18n.t("ADD AN ADAPTER") }
                                    Text {
                                        Layout.fillWidth: true
                                        text: I18n.t("Card model for the new adapter"); color: Theme.subtext0
                                        font.family: Theme.fontFamily; font.pixelSize: Theme.fontSize - 2
                                    }
                                    Segmented {
                                        Layout.fillWidth: true
                                        value: vm.newNicModel
                                        options: [ { key: "virtio", label: I18n.t("virtio-net (Linux)") },
                                                   { key: "e1000e", label: I18n.t("e1000e (Windows)") },
                                                   { key: "rtl8139", label: "rtl8139" } ]
                                        onPicked: function(k) { vm.newNicModel = k; }
                                    }

                                    Sec { text: I18n.t("BRIDGED MODE") }
                                    Note {
                                        text: I18n.t("A bridged adapter puts the VM directly on your physical network, with its own address from your router. It needs a bridge that already exists on this computer — the shell does not create one, because that reconfigures host networking.")
                                    }
                                    Note {
                                        visible: Vm.hostBridges.length === 0 && Vm.platform === "nixos"
                                        tone: "warn"
                                        text: I18n.t("No bridge found. On NixOS create one with, for example:") + "  networking.bridges.br0.interfaces = [ \"eth0\" ];"
                                    }
                                    Note {
                                        visible: Vm.hostBridges.length === 0 && Vm.platform === "arch"
                                        tone: "warn"
                                        text: I18n.t("No bridge found. On Arch create one with your network manager, for example:") + "  nmcli con add type bridge ifname br0"
                                    }
                                    Flow {
                                        Layout.fillWidth: true
                                        spacing: 6
                                        Repeater {
                                            model: Vm.hostBridges
                                            delegate: ActBtn {
                                                required property var modelData
                                                glyph: Icons.plus
                                                label: I18n.t("Add adapter on ") + modelData
                                                tint: Theme.teal
                                                enabled: !Vm.busy
                                                onClicked: Vm.addBridgeNic(vm.selected, modelData, vm.newNicModel)
                                            }
                                        }
                                    }

                                    Note {
                                        tone: "warn"
                                        text: I18n.t("Connect/Disconnect acts on the live adapter only and is not remembered across a restart — libvirt 12.2.0 rejects --live on this command, so it is applied to the running device directly.")
                                    }
                                    Flow {
                                        Layout.fillWidth: true
                                        spacing: 6
                                        Repeater {
                                            model: Vm.networks
                                            delegate: ActBtn {
                                                required property var modelData
                                                glyph: Icons.plus
                                                label: I18n.t("Add adapter on ") + modelData.name
                                                enabled: !Vm.busy
                                                onClicked: Vm.addNic(vm.selected, modelData.name, vm.newNicModel)
                                            }
                                        }
                                    }
                                }

                                // ======== dispositivos ========
                                ColumnLayout {
                                    Layout.fillWidth: true
                                    visible: vm.tab === "devices"
                                    spacing: 10

                                    // El inventario USB se relee al ENTRAR en la
                                    // pestaña. `onTabChanged` de la ventana solo
                                    // cubre los cambios de pestaña; esto cubre
                                    // además el caso de que la pestaña ya fuera
                                    // la activa al construirse la vista.
                                    onVisibleChanged: if (visible) Vm.loadHostUsb()

                                    Sec { text: I18n.t("DISPLAY") }
                                    Segmented {
                                        Layout.fillWidth: true
                                        value: Vm.detail.video ? Vm.detail.video.model : "qxl"
                                        options: [ { key: "qxl", label: "QXL" },
                                                   { key: "virtio", label: "virtio-gpu" },
                                                   { key: "vga", label: "VGA" } ]
                                        onPicked: function(k) { Vm.setVideo(vm.selected, k, k === "qxl" ? 65536 : 0); }
                                    }
                                    //  ⚠️ ESTA ELECCIÓN ES LA QUE DECIDE SI LA PANTALLA
                                    //  DEL INVITADO LLENA LA VENTANA, y no es cuestión de
                                    //  rendimiento. Medido aquí con el mismo invitado
                                    //  (Ubuntu 26.04 en vivo) y spice-vdagent corriendo
                                    //  dentro en los dos casos: con qxl el invitado se
                                    //  queda clavado en 1024x768 aunque el anfitrión le
                                    //  mande la petición; con virtio-gpu pasa a 2536x1325,
                                    //  que es exactamente el área de dibujo de la ventana.
                                    Note { text: I18n.t("On a Linux guest, virtio-gpu is what makes the display follow the window size. QXL cannot do it in a Wayland session — spice-vdagent changes the mode through XRandR, which Wayland does not have.") }
                                    Note {
                                        visible: Vm.detail.video && Vm.detail.video.model !== "virtio"
                                        text: I18n.t("For a Windows guest keep QXL: virtio-gpu has no built-in Windows driver, and QXL is the one the SPICE guest tools bring a driver for.")
                                    }
                                    Note {
                                        visible: Vm.detail.video && Vm.detail.video.model === "virtio"
                                        tone: "warn"
                                        text: I18n.t("Windows has no built-in driver for virtio-gpu — a Windows guest falls back to the basic adapter at a fixed resolution. Use QXL there.")
                                    }

                                    //  ⚠️ EL TPM QUE FALTABA. Windows 11 aborta su
                                    //  comprobación de requisitos con "El equipo debe
                                    //  admitir TPM 2.0" si el dominio no declara uno, y
                                    //  el asistente no ponía NINGUNO (medido: el
                                    //  `virsh dumpxml` de la win11 creada aquí no tenía
                                    //  la etiqueta <tpm>). El firmware ya estaba bien:
                                    //  con UEFI, `firmware='efi'` a secas resuelve al
                                    //  cargador con arranque seguro y libvirt añade
                                    //  <smm state='on'/> sola (comprobado en esta torre).
                                    //  O sea: lo único que faltaba era esto.
                                    Sec { text: I18n.t("TPM") }
                                    RowLayout {
                                        Layout.fillWidth: true
                                        spacing: 10
                                        Text {
                                            Layout.fillWidth: true
                                            text: I18n.t("Emulated TPM 2.0")
                                            color: Theme.text; wrapMode: Text.Wrap
                                            font.family: Theme.fontFamily; font.pixelSize: Theme.fontSize - 1
                                        }
                                        Toggle {
                                            checked: Vm.hasTpm2
                                            enabled: !Vm.busy
                                            opacity: enabled ? 1 : 0.5
                                            onToggled: function(v) { Vm.setTpm(vm.selected, v); }
                                        }
                                    }
                                    Note {
                                        text: I18n.t("Windows 11 refuses to install without a 2.0 TPM. It is emulated by swtpm on this computer, so nothing is installed inside the guest. Windows 11 also needs UEFI firmware, which is set in the System tab.")
                                    }
                                    Note {
                                        visible: Vm.detected && !Vm.has.swtpm
                                        tone: "warn"
                                        text: I18n.t("swtpm is not installed on this computer. Without it the TPM cannot be emulated and a VM with one will refuse to start.")
                                    }
                                    Note {
                                        visible: Vm.hasTpm2 && Vm.detail.firmware !== "uefi"
                                        tone: "warn"
                                        text: I18n.t("This VM has a TPM but is set to BIOS firmware. Windows 11 needs both, and it will still report the machine as unsupported until the firmware is UEFI.")
                                    }

                                    Sec { text: I18n.t("AUDIO") }
                                    Segmented {
                                        Layout.fillWidth: true
                                        value: Vm.detail.sound === "" ? "none" : Vm.detail.sound
                                        options: [ { key: "ich9", label: "Intel HD (ich9)" },
                                                   { key: "ac97", label: "AC97" },
                                                   { key: "none", label: I18n.t("No sound card") } ]
                                        onPicked: function(k) { Vm.setSound(vm.selected, k); }
                                    }

                                    Sec { text: I18n.t("CLIPBOARD AND AUTO-RESIZE") }
                                    RowLayout {
                                        Layout.fillWidth: true
                                        spacing: 10
                                        Text {
                                            Layout.fillWidth: true
                                            text: I18n.t("SPICE guest agent channel")
                                            color: Theme.text; wrapMode: Text.Wrap
                                            font.family: Theme.fontFamily; font.pixelSize: Theme.fontSize - 1
                                        }
                                        Toggle {
                                            checked: Vm.hasSpiceAgent
                                            onToggled: function(v) { Vm.setSpiceAgent(vm.selected, v); }
                                        }
                                    }
                                    RowLayout {
                                        Layout.fillWidth: true
                                        spacing: 10
                                        Text {
                                            Layout.fillWidth: true
                                            text: I18n.t("Share clipboard with the guest")
                                            color: Theme.text; wrapMode: Text.Wrap
                                            font.family: Theme.fontFamily; font.pixelSize: Theme.fontSize - 1
                                        }
                                        Toggle {
                                            checked: Vm.clipboardOn
                                            onToggled: function(v) { Vm.setClipboard(vm.selected, v); }
                                        }
                                    }
                                    //  ⚠️ ESTO NO ES UN FALLO DEL SHELL Y NO SE VA A
                                    //  FALSEAR. Que la pantalla del invitado siga al
                                    //  tamaño de la ventana lo hace el AGENTE DE DENTRO
                                    //  del invitado, no el anfitrión: virt-viewer pide el
                                    //  cambio de resolución por el canal
                                    //  `com.redhat.spice.0` y quien lo atiende y llama al
                                    //  servidor gráfico es spice-vdagent. Sin agente no
                                    //  hay a quién pedírselo y la imagen se queda a su
                                    //  resolución fija con bandas negras.
                                    //
                                    //  Por eso Ubuntu redimensiona y Arch, Ryoku y Windows
                                    //  no: Ubuntu Desktop trae spice-vdagent instalado de
                                    //  serie, los otros no. Es la ÚNICA diferencia — el
                                    //  lado del anfitrión (SPICE, el canal, `virt-viewer
                                    //  --auto-resize=always`) ya está puesto en las cuatro.
                                    //
                                    //  Lo único que puede hacer el shell es DECIR QUÉ
                                    //  FALTA, con el nombre exacto del paquete de cada
                                    //  invitado, en vez de dejarlo indescifrable.
                                    Note {
                                        tone: Vm.hasSpiceAgent ? "info" : "warn"
                                        text: I18n.t("Needs spice-vdagent installed and running INSIDE the guest. Without it neither the shared clipboard nor the display resizing to fill the window can work — the host side alone is not enough.")
                                    }
                                    //  ⚠️ SON DOS CONDICIONES, NO UNA, y las dos hacen
                                    //  falta. Se midieron por separado en esta torre:
                                    //
                                    //   * sin agente (Ryoku en vivo): el canal sale
                                    //     state='disconnected' y no pasa nada;
                                    //   * con agente pero con qxl (Ubuntu 26.04 en vivo):
                                    //     el canal sale 'connected', el anfitrión manda
                                    //     "monitor #0: 2536x1325" y el invitado NO lo
                                    //     aplica: sigue en 1024x768;
                                    //   * con agente y virtio-gpu: 2536x1325, o sea la
                                    //     ventana entera.
                                    //
                                    //  Y por eso el Ubuntu del usuario ya redimensionaba:
                                    //  cumple las dos (trae spice-vdagent y su dominio ya
                                    //  venía con virtio-gpu).
                                    Note {
                                        text: I18n.t("Two things are needed and both are guest-side or hardware-side: the agent below, and a virtio-gpu display for Linux guests (Devices → Display). With QXL the guest never applies the resize, even with the agent running.")
                                    }
                                    Note {
                                        text: I18n.t("Ubuntu Desktop ships the agent and its VM already used virtio-gpu, which is why only Ubuntu guests resized out of the box. New VMs made here now pick the right display for the guest automatically.")
                                    }
                                    Note {
                                        text: I18n.t("Debian / Ubuntu:") + "  sudo apt install spice-vdagent"
                                    }
                                    Note {
                                        text: I18n.t("Arch / Ryoku Linux:") + "  sudo pacman -S spice-vdagent"
                                              + "  ·  sudo systemctl enable --now spice-vdagentd"
                                    }
                                    Note {
                                        text: I18n.t("Fedora / RHEL:") + "  sudo dnf install spice-vdagent"
                                    }
                                    //  En Windows el equivalente NO está en virtio-win: va
                                    //  en spice-guest-tools, que es otra descarga distinta
                                    //  y hasta ahora no se nombraba en ninguna parte de la
                                    //  ventana. De ahí que en Windows no hubiera ni pista
                                    //  de qué instalar.
                                    Note {
                                        text: I18n.t("Windows: install spice-guest-tools inside the guest. It is a separate download from the virtio-win ISO used for the disk and network drivers, and it also brings the QXL display driver.")
                                    }

                                    Sec { text: I18n.t("USB PASSTHROUGH") }
                                    Note {
                                        tone: "warn"
                                        text: I18n.t("While a device is passed through it belongs to the VM and stops working on this computer. Do not pass through the keyboard or mouse you are using.")
                                    }
                                    Repeater {
                                        model: Vm.detail.usbdevs
                                        delegate: RowLayout {
                                            required property var modelData
                                            Layout.fillWidth: true
                                            spacing: 8
                                            Text {
                                                Layout.fillWidth: true
                                                text: Vm.usbLabel(modelData.vendor, modelData.product)
                                                color: Theme.text; elide: Text.ElideRight
                                                font.family: Theme.fontFamily; font.pixelSize: Theme.fontSize - 1
                                            }
                                            ActBtn {
                                                glyph: Icons.close; label: I18n.t("Detach")
                                                danger: true; tint: Theme.red
                                                enabled: !Vm.busy
                                                onClicked: Vm.detachUsb(vm.selected, modelData.vendor, modelData.product)
                                            }
                                        }
                                    }
                                    RowLayout {
                                        Layout.fillWidth: true
                                        spacing: 8
                                        Text {
                                            Layout.fillWidth: true
                                            text: I18n.t("Devices on this computer")
                                            color: Theme.subtext0
                                            font.family: Theme.fontFamily; font.pixelSize: Theme.fontSize - 2
                                        }
                                        ActBtn { glyph: Icons.refresh; onClicked: Vm.loadHostUsb() }
                                    }
                                    Repeater {
                                        model: Vm.hostUsb
                                        delegate: RowLayout {
                                            required property var modelData
                                            Layout.fillWidth: true
                                            spacing: 8
                                            Text {
                                                Layout.fillWidth: true
                                                text: modelData.label
                                                color: Theme.subtext1; elide: Text.ElideRight
                                                font.family: Theme.fontFamily; font.pixelSize: Theme.fontSize - 2
                                            }
                                            ActBtn {
                                                glyph: Icons.plus; label: I18n.t("Pass through")
                                                enabled: !Vm.busy && !Vm.usbAttached(modelData.vendor, modelData.product)
                                                onClicked: vm.ask(I18n.t("Pass this device to the VM?"),
                                                    modelData.label + "\n\n" + I18n.t("It will stop working on this computer until you detach it again."),
                                                    I18n.t("Pass through"), true,
                                                    function() { Vm.attachUsb(vm.selected, modelData.vendor, modelData.product); })
                                            }
                                        }
                                    }

                                    Sec { text: I18n.t("SHARED FOLDERS") }
                                    Note {
                                        tone: "warn"
                                        text: I18n.t("Shared folders use virtiofs. The host side is set up here, but the guest must mount the tag itself — nothing appears inside the guest automatically. The VM also needs shared memory, which is added for you.")
                                    }
                                    // ⚠️ Sin virtiofsd en el ANFITRIÓN, una VM con
                                    // carpeta compartida NO ARRANCA. Añadir una
                                    // aquí dejaría la VM sin poder encenderse, así
                                    // que el botón se apaga y se dice qué instalar.
                                    Note {
                                        visible: Vm.detected && !Vm.has.virtiofs
                                        tone: "warn"
                                        text: I18n.t("virtiofsd is not installed on this computer. A VM with a shared folder will refuse to start without it, so this is disabled.")
                                    }
                                    Note {
                                        visible: Vm.detected && !Vm.has.virtiofs && Vm.platform === "nixos"
                                        text: "virtualisation.libvirtd.qemu.vhostUserPackages = [ pkgs.virtiofsd ];"
                                    }
                                    Note {
                                        visible: Vm.detected && !Vm.has.virtiofs && Vm.platform === "arch"
                                        text: "sudo pacman -S --needed virtiofsd"
                                    }
                                    Repeater {
                                        model: Vm.detail.fs
                                        delegate: RowLayout {
                                            required property var modelData
                                            Layout.fillWidth: true
                                            spacing: 8
                                            ColumnLayout {
                                                Layout.fillWidth: true
                                                spacing: 0
                                                Text {
                                                    Layout.fillWidth: true
                                                    text: modelData.tag
                                                    color: Theme.text; font.bold: true; elide: Text.ElideRight
                                                    font.family: Theme.fontFamily; font.pixelSize: Theme.fontSize - 1
                                                }
                                                Text {
                                                    Layout.fillWidth: true
                                                    text: modelData.source
                                                    color: Theme.subtext0; elide: Text.ElideMiddle
                                                    font.family: Theme.fontFamily; font.pixelSize: Theme.fontSize - 3
                                                }
                                            }
                                            ActBtn {
                                                glyph: Icons.trash; label: I18n.t("Remove")
                                                danger: true; tint: Theme.red
                                                enabled: !Vm.busy
                                                onClicked: Vm.removeSharedFolder(vm.selected, modelData.tag)
                                            }
                                        }
                                    }
                                    Repeater {
                                        model: Vm.detail.fs.length > 0 ? [ Vm.detail.fs[0].tag ] : []
                                        delegate: Note {
                                            required property var modelData
                                            text: I18n.t("Inside the guest, mount it with:") + "  sudo mount -t virtiofs " + modelData + " /mnt"
                                        }
                                    }
                                    ActBtn {
                                        glyph: Icons.plus; label: I18n.t("Add shared folder")
                                        enabled: !Vm.busy && Vm.has.virtiofs
                                        onClicked: vm.ask2(I18n.t("Share a folder with the guest"),
                                            I18n.t("The tag is the name the guest mounts, not a path."),
                                            [ { key: "path", label: I18n.t("Folder on this computer"), value: Quickshell.env("HOME"), pick: "folder" },
                                              { key: "tag",  label: I18n.t("Tag the guest will mount"), value: "share" } ],
                                            I18n.t("Share"),
                                            function(v) { if (v.path !== "" && v.tag !== "") Vm.addSharedFolder(vm.selected, v.path, v.tag); })
                                    }
                                }

                                // ======== snapshots ========
                                ColumnLayout {
                                    Layout.fillWidth: true
                                    visible: vm.tab === "snapshots"
                                    spacing: 8

                                    RowLayout {
                                        Layout.fillWidth: true
                                        spacing: 8
                                        Field { id: snapName; label: I18n.t("Snapshot name"); placeholder: "snap1" }
                                        ActBtn {
                                            Layout.alignment: Qt.AlignBottom
                                            Layout.bottomMargin: 12
                                            glyph: Icons.plus; label: I18n.t("Create")
                                            tint: Theme.accent
                                            enabled: !Vm.busy && snapName.text !== ""
                                            onClicked: { Vm.snapCreate(vm.selected, snapName.text, ""); snapName.text = ""; }
                                        }
                                    }

                                    Text {
                                        Layout.fillWidth: true
                                        visible: Vm.snapshots.length === 0
                                        text: I18n.t("No snapshots")
                                        color: Theme.overlay2
                                        font.family: Theme.fontFamily; font.pixelSize: Theme.fontSize - 1
                                    }

                                    Repeater {
                                        model: Vm.snapshots
                                        delegate: Rectangle {
                                            required property var modelData
                                            Layout.fillWidth: true
                                            implicitHeight: snapCol.implicitHeight + 16
                                            radius: Theme.radius
                                            color: Theme.surface0
                                            border.width: 1; border.color: Theme.overlay0
                                            ColumnLayout {
                                                id: snapCol
                                                anchors.left: parent.left; anchors.right: parent.right
                                                anchors.verticalCenter: parent.verticalCenter
                                                anchors.leftMargin: 12; anchors.rightMargin: 12
                                                spacing: 6
                                                Text {
                                                    Layout.fillWidth: true
                                                    text: modelData.name; color: Theme.text
                                                    font.family: Theme.fontFamily; font.pixelSize: Theme.fontSize - 1
                                                    font.bold: true; elide: Text.ElideRight
                                                }
                                                Text {
                                                    Layout.fillWidth: true
                                                    visible: modelData.created !== ""
                                                    text: modelData.created; color: Theme.subtext0
                                                    font.family: Theme.fontFamily; font.pixelSize: Theme.fontSize - 3
                                                    elide: Text.ElideRight
                                                }
                                                Flow {
                                                    Layout.fillWidth: true
                                                    spacing: 6
                                                    ActBtn {
                                                        glyph: Icons.back; label: I18n.t("Restore")
                                                        tint: Theme.blue
                                                        enabled: !Vm.busy
                                                        onClicked: vm.ask(I18n.t("Restore this snapshot?"),
                                                            I18n.t("The VM goes back to the state saved in this snapshot. Everything changed since then is lost."),
                                                            I18n.t("Restore"), true,
                                                            function() { Vm.snapRevert(vm.selected, modelData.name); })
                                                    }
                                                    ActBtn {
                                                        glyph: Icons.trash; label: I18n.t("Delete")
                                                        danger: true; tint: Theme.red
                                                        enabled: !Vm.busy
                                                        onClicked: vm.ask(I18n.t("Delete this snapshot?"),
                                                            I18n.t("The snapshot is removed permanently. The VM itself is not touched."),
                                                            I18n.t("Delete"), true,
                                                            function() { Vm.snapDelete(vm.selected, modelData.name); })
                                                    }
                                                }
                                            }
                                        }
                                    }
                                }

                                // ======== redes ========
                                ColumnLayout {
                                    Layout.fillWidth: true
                                    visible: vm.tab === "networks"
                                    spacing: 8
                                    Text {
                                        Layout.fillWidth: true
                                        text: I18n.t("libvirt networks on this host. `default` is the NAT network new VMs use. A VM can sit on several at once — add one adapter per network in the Network tab.")
                                        color: Theme.subtext0; wrapMode: Text.Wrap
                                        font.family: Theme.fontFamily; font.pixelSize: Theme.fontSize - 2
                                    }
                                    //  Quitar un adaptador NUNCA toca una red: Vm.removeNic hace
                                    //  `detach-device` con el <interface> exacto de ESA VM. Se dice
                                    //  aquí porque es justo lo que se sospechó que había borrado
                                    //  `default`, y no fue eso (`net-list --all` la seguía
                                    //  listando activa después de quitar el adaptador).
                                    Note {
                                        text: I18n.t("Removing an adapter in a VM's Network tab only detaches that VM's interface — it never deletes the network itself, so the network stays here for every other VM.")
                                    }
                                    //  Red de rescate: si `default` falta (borrada desde fuera del
                                    //  shell, con virsh o con virt-manager) las VMs se quedan sin
                                    //  ninguna salida a internet y no había forma de recuperarla
                                    //  desde aquí. Solo aparece cuando de verdad falta.
                                    Note {
                                        visible: !vm.hasDefaultNet
                                        tone: "warn"
                                        text: I18n.t("The `default` NAT network is missing from this host. Without it VMs have no route to the internet — host-only and internal networks are local-only. It can be recreated with libvirt's original definition (192.168.122.0/24 with DHCP).")
                                    }
                                    ActBtn {
                                        visible: !vm.hasDefaultNet
                                        glyph: Icons.plus; label: I18n.t("Restore the default network")
                                        tint: Theme.teal
                                        enabled: !Vm.busy
                                        onClicked: Vm.netRestoreDefault()
                                    }
                                    Flow {
                                        Layout.fillWidth: true
                                        spacing: 6
                                        ActBtn {
                                            glyph: Icons.plus; label: I18n.t("New network")
                                            tint: Theme.accent
                                            enabled: !Vm.busy
                                            onClicked: vm.ask2(I18n.t("Create a virtual network"),
                                                I18n.t("A new libvirt network. VMs join it by adding an adapter on it, and a VM can be on several networks at once."),
                                                [ { key: "name", label: I18n.t("Name"), value: "" },
                                                  { key: "mode", label: I18n.t("What this network can reach"), value: "nat",
                                                    choices: [
                                                      { key: "nat", label: I18n.t("NAT (out to the internet)"),
                                                        note: I18n.t("VMs reach the outside world through this computer, and each other. Same idea as `default`.") },
                                                      { key: "hostonly", label: I18n.t("Host-only"),
                                                        note: I18n.t("VMs reach each other and this computer, but have no route out.") },
                                                      { key: "internal", label: I18n.t("Internal"),
                                                        note: I18n.t("VMs reach only each other. Not even this computer is on the network, so there is no address range and no DHCP.") } ] },
                                                  { key: "subnet", label: I18n.t("Address range"), value: "192.168.100.0/24",
                                                    placeholder: "192.168.100.0/24" },
                                                  { key: "dhcp", label: I18n.t("Hand out addresses (DHCP)"), value: "yes",
                                                    choices: [
                                                      { key: "yes", label: I18n.t("Yes"),
                                                        note: I18n.t("libvirt hands out addresses on this network.") },
                                                      { key: "no", label: I18n.t("No"),
                                                        note: I18n.t("You set the addresses inside each guest yourself.") } ] } ],
                                                I18n.t("Create"),
                                                function(v) {
                                                    Vm.createNetwork({ name: v.name, mode: v.mode, subnet: v.subnet,
                                                                       dhcp: v.dhcp === "yes", autostart: true });
                                                })
                                        }
                                    }
                                    Repeater {
                                        model: Vm.networks
                                        delegate: Rectangle {
                                            required property var modelData
                                            Layout.fillWidth: true
                                            implicitHeight: netCol.implicitHeight + 16
                                            radius: Theme.radius
                                            color: Theme.surface0
                                            border.width: 1; border.color: Theme.overlay0
                                            ColumnLayout {
                                                id: netCol
                                                anchors.left: parent.left; anchors.right: parent.right
                                                anchors.verticalCenter: parent.verticalCenter
                                                anchors.leftMargin: 12; anchors.rightMargin: 12
                                                spacing: 6
                                                RowLayout {
                                                    Layout.fillWidth: true
                                                    spacing: 8
                                                    Rectangle {
                                                        width: 9; height: 9; radius: 4.5
                                                        color: modelData.state === "active" ? Theme.green : Theme.overlay2
                                                    }
                                                    Text {
                                                        Layout.fillWidth: true
                                                        text: modelData.name; color: Theme.text
                                                        font.family: Theme.fontFamily; font.pixelSize: Theme.fontSize - 1
                                                        font.bold: true; elide: Text.ElideRight
                                                    }
                                                    Text {
                                                        text: modelData.state === "active" ? I18n.t("Active") : I18n.t("Inactive")
                                                        color: Theme.subtext0
                                                        font.family: Theme.fontFamily; font.pixelSize: Theme.fontSize - 3
                                                    }
                                                }
                                                //  Qué es cada red de un vistazo: sin esto,
                                                //  con varias redes propias la lista solo
                                                //  decía nombres y no distinguía nada.
                                                Text {
                                                    Layout.fillWidth: true
                                                    text: vm.netModeLabel(modelData.mode)
                                                          + (modelData.ip !== "" ? "  ·  " + modelData.ip + "/" + vm.maskBits(modelData.netmask) : "")
                                                          + "  ·  " + (modelData.dhcp ? I18n.t("DHCP on") : I18n.t("DHCP off"))
                                                    color: Theme.subtext0; wrapMode: Text.Wrap
                                                    font.family: Theme.fontFamily; font.pixelSize: Theme.fontSize - 3
                                                }
                                                Flow {
                                                    Layout.fillWidth: true
                                                    spacing: 6
                                                    ActBtn {
                                                        glyph: Icons.play; label: I18n.t("Start")
                                                        tint: Theme.green
                                                        enabled: !Vm.busy && modelData.state !== "active"
                                                        onClicked: Vm.netStart(modelData.name)
                                                    }
                                                    ActBtn {
                                                        glyph: Icons.power; label: I18n.t("Stop")
                                                        tint: Theme.peach
                                                        enabled: !Vm.busy && modelData.state === "active"
                                                        onClicked: Vm.netStop(modelData.name)
                                                    }
                                                    ActBtn {
                                                        glyph: modelData.autostart ? Icons.check : Icons.close
                                                        label: I18n.t("Autostart")
                                                        tint: modelData.autostart ? Theme.green : Theme.overlay2
                                                        enabled: !Vm.busy
                                                        onClicked: Vm.netAutostart(modelData.name, !modelData.autostart)
                                                    }
                                                    //  ⚠️ `default` NO se borra. Es la única red que
                                                    //  sale a internet sin configurar nada, la usan
                                                    //  todas las VMs nuevas, y las redes propias del
                                                    //  shell (host-only, interna, NAT nueva) NO la
                                                    //  sustituyen: quedan aisladas. Perderla se nota
                                                    //  en TODAS las VMs a la vez y desde aquí no
                                                    //  había forma de deshacerlo. Vm.netDelete lo
                                                    //  rechaza también por su cuenta.
                                                    ActBtn {
                                                        glyph: Icons.trash; label: I18n.t("Delete")
                                                        danger: true; tint: Theme.red
                                                        enabled: !Vm.busy && modelData.name !== Vm.protectedNet
                                                        onClicked: vm.ask(I18n.t("Delete this network?"),
                                                            I18n.t("The network is stopped and its definition removed. Any VM with an adapter on it loses that connection until you point the adapter somewhere else."),
                                                            I18n.t("Delete"), true,
                                                            function() { Vm.netDelete(modelData.name); })
                                                    }
                                                    Text {
                                                        visible: modelData.name === Vm.protectedNet
                                                        text: I18n.t("Built in — cannot be deleted")
                                                        color: Theme.subtext0
                                                        font.family: Theme.fontFamily; font.pixelSize: Theme.fontSize - 3
                                                    }
                                                }
                                            }
                                        }
                                    }
                                }
                            }
                        }
                    }
                }
            }
        }

        // ==================== diálogo: crear VM ====================
        Rectangle {
            anchors.fill: parent
            visible: vm.creating
            color: "#000000aa"
            MouseArea { anchors.fill: parent; onClicked: vm.creating = false }

            Card {
                anchors.centerIn: parent
                // Responsive en LOS DOS ejes: nunca más grande que la ventana.
                width: Math.min(parent.width - 28, 560)
                height: Math.min(parent.height - 28, createCol.implicitHeight + 28)
                MouseArea { anchors.fill: parent }   // no cerrar al pinchar dentro

                Flickable {
                    anchors.fill: parent
                    anchors.margins: 14
                    contentHeight: createCol.implicitHeight
                    clip: true
                    boundsBehavior: Flickable.StopAtBounds

                    ColumnLayout {
                        id: createCol
                        width: parent.width
                        spacing: 10

                        Text {
                            Layout.fillWidth: true
                            text: I18n.t("New virtual machine"); color: Theme.text
                            font.family: Theme.fontFamily; font.pixelSize: Theme.fontSize + 2
                            font.bold: true
                        }

                        Field {
                            id: cName
                            label: I18n.t("Name")
                            placeholder: "debian-13"
                            valid: cName.text === "" || (Vm.validName(cName.text) && !Vm.nameTaken(cName.text))
                        }
                        Text {
                            Layout.fillWidth: true
                            visible: cName.text !== "" && !cName.valid
                            text: Vm.nameTaken(cName.text)
                                  ? I18n.t("A VM with that name already exists.")
                                  : I18n.t("Letters, digits, dot, dash and underscore only.")
                            color: Theme.red; wrapMode: Text.Wrap
                            font.family: Theme.fontFamily; font.pixelSize: Theme.fontSize - 3
                        }

                        // En estrecho se apilan; en ancho van en fila.
                        GridLayout {
                            Layout.fillWidth: true
                            columns: createCol.width < 380 ? 1 : 3
                            columnSpacing: 8
                            rowSpacing: 8
                            Field { id: cMem;  label: I18n.t("Memory (MiB)"); numeric: true; text: "2048" }
                            Field { id: cCpu;  label: I18n.t("vCPUs");        numeric: true; text: "2" }
                            Field { id: cDisk; label: I18n.t("Disk (GiB)");   numeric: true; text: "20" }
                        }

                        Text {
                            Layout.fillWidth: true
                            text: I18n.t("Boot ISO (optional)"); color: Theme.subtext0
                            font.family: Theme.fontFamily; font.pixelSize: Theme.fontSize - 2
                        }
                        Field { id: cIso; label: I18n.t("Path to an .iso file"); pick: "file"; pickKind: "iso"
                                placeholder: Quickshell.env("HOME") + "/…/linux.iso" }

                        //  ⚠️ ESTE SELECTOR NO ES UNA ETIQUETA. De él salen la
                        //  controladora del disco, el modelo de la tarjeta de
                        //  red y si hay TPM — las tres cosas que hacían que una
                        //  VM de Windows creada aquí no viera su disco, no
                        //  tuviera red y no pasara de la pantalla de requisitos.
                        //  Ver Vm.osDiskBus / osNicModel / osNeedsTpm.
                        //
                        //  Se rellena solo con el nombre de la ISO (`touched`
                        //  deja de seguirlo en cuanto el usuario elige a mano,
                        //  para no pisarle la elección si luego cambia la ISO).
                        Text {
                            Layout.fillWidth: true
                            text: I18n.t("Guest operating system"); color: Theme.subtext0
                            font.family: Theme.fontFamily; font.pixelSize: Theme.fontSize - 2
                        }
                        Segmented {
                            id: cOs
                            property bool touched: false
                            Layout.fillWidth: true
                            value: "linux"
                            options: [ { key: "linux",   label: I18n.t("Linux") },
                                       { key: "windows", label: I18n.t("Windows 10 / Server") },
                                       { key: "win11",   label: I18n.t("Windows 11") } ]
                            onPicked: function(k) { cOs.touched = true; cOs.value = k; }
                            Connections {
                                target: cIso
                                function onTextChanged() {
                                    if (!cOs.touched) cOs.value = Vm.guessOsType(cIso.text);
                                }
                            }
                        }
                        Text {
                            Layout.fillWidth: true
                            visible: cOs.value !== "linux"
                            text: cOs.value === "win11"
                                  ? I18n.t("Windows 11: the disk goes on SATA and the network card is e1000e (Windows has no built-in virtio driver for either), plus a 2.0 TPM and UEFI, which its setup refuses to continue without.")
                                  : I18n.t("Windows: the disk goes on SATA and the network card is e1000e. Windows has no built-in virtio driver for either, so with virtio the installer shows no disk and the guest gets no network.")
                            color: Theme.subtext0; wrapMode: Text.Wrap
                            font.family: Theme.fontFamily; font.pixelSize: Theme.fontSize - 3
                        }
                        Text {
                            Layout.fillWidth: true
                            visible: cOs.value === "win11" && Vm.detected && !Vm.has.swtpm
                            text: I18n.t("swtpm is not installed on this computer, so the TPM cannot be emulated and the VM will fail to start. Install it first (see Settings → Virtualization).")
                            color: Theme.red; wrapMode: Text.Wrap
                            font.family: Theme.fontFamily; font.pixelSize: Theme.fontSize - 3
                        }

                        Text {
                            Layout.fillWidth: true
                            text: I18n.t("Firmware"); color: Theme.subtext0
                            font.family: Theme.fontFamily; font.pixelSize: Theme.fontSize - 2
                        }
                        Segmented {
                            id: cFw
                            Layout.fillWidth: true
                            //  Windows 11 NO admite BIOS: exige UEFI con arranque
                            //  seguro además del TPM. Se muestra fijado en UEFI y
                            //  Vm.domainXml lo impone igualmente, para que no
                            //  dependa de que el selector esté sincronizado.
                            value: cOs.value === "win11" ? "uefi" : "bios"
                            options: [ { key: "bios", label: "BIOS" }, { key: "uefi", label: "UEFI" } ]
                            onPicked: function(k) { if (cOs.value !== "win11") cFw.value = k; }
                        }
                        Text {
                            Layout.fillWidth: true
                            visible: cOs.value === "win11"
                            text: I18n.t("Windows 11 requires UEFI, so the firmware is fixed here.")
                            color: Theme.subtext0; wrapMode: Text.Wrap
                            font.family: Theme.fontFamily; font.pixelSize: Theme.fontSize - 3
                        }
                        Text {
                            Layout.fillWidth: true
                            visible: cFw.value === "uefi" && Vm.detected && !Vm.has.uefi
                            text: I18n.t("This host does not report UEFI firmware support; the VM may fail to start.")
                            color: Theme.yellow; wrapMode: Text.Wrap
                            font.family: Theme.fontFamily; font.pixelSize: Theme.fontSize - 3
                        }

                        Text {
                            Layout.fillWidth: true
                            text: I18n.t("Network"); color: Theme.subtext0
                            font.family: Theme.fontFamily; font.pixelSize: Theme.fontSize - 2
                        }
                        Segmented {
                            id: cNet
                            Layout.fillWidth: true
                            value: "default"
                            options: {
                                var o = [];
                                for (var i = 0; i < Vm.networks.length; i++)
                                    o.push({ key: Vm.networks[i].name, label: Vm.networks[i].name });
                                if (o.length === 0) o.push({ key: "default", label: "default (NAT)" });
                                o.push({ key: "none", label: I18n.t("No network") });
                                return o;
                            }
                            onPicked: function(k) { cNet.value = k; }
                        }

                        Flow {
                            Layout.fillWidth: true
                            Layout.topMargin: 4
                            spacing: 6
                            layoutDirection: Qt.RightToLeft
                            ActBtn {
                                glyph: Icons.check; label: I18n.t("Create")
                                tint: Theme.accent
                                enabled: !Vm.busy && cName.text !== "" && cName.valid
                                         && cMem.text !== "" && cCpu.text !== "" && cDisk.text !== ""
                                onClicked: {
                                    vm.newName = cName.text;
                                    Vm.createVm({
                                        name: cName.text,
                                        memMib: parseInt(cMem.text, 10),
                                        vcpus: parseInt(cCpu.text, 10),
                                        diskGb: parseInt(cDisk.text, 10),
                                        iso: cIso.text.trim(),
                                        firmware: cFw.value,
                                        osType: cOs.value,
                                        network: cNet.value
                                    });
                                }
                            }
                            ActBtn { label: I18n.t("Cancel"); onClicked: vm.creating = false }
                        }
                    }
                }
            }
        }

        // ==================== diálogo genérico de campos ====================
        //  Uno solo para "disco nuevo", "renombrar", "clonar", "carpeta
        //  compartida", "insertar ISO"… en vez de cinco tarjetas casi iguales.
        //  Responsive en los dos ejes, igual que el de crear VM.
        Rectangle {
            anchors.fill: parent
            visible: vm.prompt !== null
            color: "#000000aa"
            MouseArea { anchors.fill: parent; onClicked: vm.prompt = null }

            Card {
                anchors.centerIn: parent
                width: Math.min(parent.width - 28, 520)
                height: Math.min(parent.height - 28, promptCol.implicitHeight + 28)
                MouseArea { anchors.fill: parent }

                Flickable {
                    anchors.fill: parent
                    anchors.margins: 14
                    contentHeight: promptCol.implicitHeight
                    clip: true
                    boundsBehavior: Flickable.StopAtBounds

                    ColumnLayout {
                        id: promptCol
                        width: parent.width
                        spacing: 10

                        Text {
                            Layout.fillWidth: true
                            text: vm.prompt ? vm.prompt.title : ""
                            color: Theme.text; wrapMode: Text.Wrap
                            font.family: Theme.fontFamily; font.pixelSize: Theme.fontSize + 2
                            font.bold: true
                        }
                        Text {
                            Layout.fillWidth: true
                            visible: vm.prompt && vm.prompt.note !== ""
                            text: vm.prompt ? vm.prompt.note : ""
                            color: Theme.subtext0; wrapMode: Text.Wrap
                            font.family: Theme.fontFamily; font.pixelSize: Theme.fontSize - 2
                        }

                        //  Un campo con `choices` sale como botonera en vez de
                        //  como caja de texto. Es lo MENOS que hacía falta para
                        //  poder pedir el modo de una red y el sí/no del DHCP
                        //  sin inventarse un diálogo aparte para cada cosa: la
                        //  botonera ya existe (Segmented) y el valor se lee por
                        //  el mismo sitio (`.text`) que el de los campos.
                        Repeater {
                            id: promptFields
                            model: vm.prompt ? vm.prompt.fields : []
                            delegate: Loader {
                                id: pfLoader
                                required property var modelData
                                required property int index
                                property string text: ""        // lo que lee Aceptar
                                Layout.fillWidth: true
                                sourceComponent: (modelData.choices !== undefined
                                                  && modelData.choices !== null) ? choiceField : textField

                                Component {
                                    id: textField
                                    Field {
                                        label: pfLoader.modelData.label
                                        numeric: pfLoader.modelData.numeric === true
                                        pick: pfLoader.modelData.pick || ""
                                        pickKind: pfLoader.modelData.pickKind || ""
                                        placeholder: pfLoader.modelData.placeholder || ""
                                        Component.onCompleted: text = pfLoader.modelData.value || ""
                                        onTextChanged: pfLoader.text = text
                                    }
                                }
                                Component {
                                    id: choiceField
                                    ColumnLayout {
                                        spacing: 4
                                        Text {
                                            text: pfLoader.modelData.label; color: Theme.subtext0
                                            font.family: Theme.fontFamily; font.pixelSize: Theme.fontSize - 3
                                        }
                                        Segmented {
                                            Layout.fillWidth: true
                                            options: pfLoader.modelData.choices
                                            value: pfLoader.text
                                            onPicked: function(k) { pfLoader.text = k; }
                                        }
                                        Text {
                                            Layout.fillWidth: true
                                            visible: text !== ""
                                            text: {
                                                var c = pfLoader.modelData.choices;
                                                for (var i = 0; i < c.length; i++)
                                                    if (c[i].key === pfLoader.text) return c[i].note || "";
                                                return "";
                                            }
                                            color: Theme.subtext0; wrapMode: Text.Wrap
                                            font.family: Theme.fontFamily; font.pixelSize: Theme.fontSize - 3
                                        }
                                        Component.onCompleted: pfLoader.text = pfLoader.modelData.value || ""
                                    }
                                }
                            }
                        }

                        Flow {
                            Layout.fillWidth: true
                            Layout.topMargin: 4
                            spacing: 6
                            layoutDirection: Qt.RightToLeft
                            ActBtn {
                                glyph: Icons.check
                                label: vm.prompt ? vm.prompt.label : ""
                                tint: Theme.accent
                                enabled: !Vm.busy
                                onClicked: {
                                    var vals = {}, f = vm.prompt ? vm.prompt.fields : [];
                                    for (var i = 0; i < f.length; i++) {
                                        var it = promptFields.itemAt(i);
                                        vals[f[i].key] = it ? String(it.text).trim() : "";
                                    }
                                    var a = vm.prompt ? vm.prompt.act : null;
                                    vm.prompt = null;
                                    if (a) a(vals);
                                }
                            }
                            ActBtn { label: I18n.t("Cancel"); onClicked: vm.prompt = null }
                        }
                    }
                }
            }
        }

        // ==================== diálogo: confirmación ====================
        //  Toda acción irreversible pasa por aquí. El botón peligroso NO es el
        //  que tiene el foco por defecto y va marcado en rojo.
        Rectangle {
            anchors.fill: parent
            visible: vm.confirm !== null
            color: "#000000aa"
            MouseArea { anchors.fill: parent; onClicked: vm.confirm = null }

            Card {
                anchors.centerIn: parent
                width: Math.min(parent.width - 28, 420)
                height: Math.min(parent.height - 28, confCol.implicitHeight + 32)
                MouseArea { anchors.fill: parent }

                ColumnLayout {
                    id: confCol
                    anchors.left: parent.left; anchors.right: parent.right
                    anchors.top: parent.top
                    anchors.margins: 16
                    spacing: 10

                    RowLayout {
                        Layout.fillWidth: true
                        spacing: 10
                        Text {
                            text: Icons.info
                            color: (vm.confirm && vm.confirm.danger) ? Theme.red : Theme.yellow
                            font.family: Theme.fontFamily; font.pixelSize: Theme.fontSize + 6
                        }
                        Text {
                            Layout.fillWidth: true
                            text: vm.confirm ? vm.confirm.title : ""
                            color: Theme.text; wrapMode: Text.Wrap
                            font.family: Theme.fontFamily; font.pixelSize: Theme.fontSize + 1
                            font.bold: true
                        }
                    }
                    Text {
                        Layout.fillWidth: true
                        text: vm.confirm ? vm.confirm.body : ""
                        color: Theme.subtext0; wrapMode: Text.Wrap
                        font.family: Theme.fontFamily; font.pixelSize: Theme.fontSize - 1
                    }
                    Text {
                        Layout.fillWidth: true
                        visible: vm.selected !== ""
                        text: vm.selected
                        color: Theme.overlay2; elide: Text.ElideRight
                        font.family: Theme.fontFamily; font.pixelSize: Theme.fontSize - 2
                    }
                    Flow {
                        Layout.fillWidth: true
                        Layout.topMargin: 4
                        spacing: 6
                        layoutDirection: Qt.RightToLeft
                        ActBtn {
                            label: vm.confirm ? vm.confirm.label : ""
                            danger: vm.confirm ? vm.confirm.danger === true : false
                            tint: Theme.red
                            onClicked: {
                                var a = vm.confirm ? vm.confirm.act : null;
                                vm.confirm = null;
                                if (a) a();
                            }
                        }
                        ActBtn { label: I18n.t("Cancel"); onClicked: vm.confirm = null }
                    }
                }
            }
        }
    }
}
