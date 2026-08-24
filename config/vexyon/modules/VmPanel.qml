import QtQuick
import QtQuick.Layouts
import qs.services
import qs.components

// ============================================================================
//  VmPanel — control EN VIVO de las máquinas virtuales encendidas, colgando de
//  la pastilla de barra.
//
//  Por qué existe: la ventana del display de la VM se abre con virt-viewer y se
//  deja LIMPIA, sin barra de herramientas alrededor (al revés que VirtualBox).
//  Ese cromo que VirtualBox mete encima de la VM vive aquí: pausar, reanudar,
//  apagar, forzar el apagado, reiniciar y conectar/desconectar la red, sin
//  ensuciar la ventana de la VM.
//
//  Colocación consciente del foco, tema y animaciones: todo heredado de
//  AnchoredPanel, igual que los otros nueve paneles de barra. Nada nuevo.
//
//  CERO SONDEO: relee al abrirse y tras cada acción (Vm.actionDone → Vm.refresh
//  → refreshed). Ningún Timer.
// ============================================================================
AnchoredPanel {
    id: vp
    panelKey: "vmPanel"
    ns: "vexyon-vm"
    panelWidth: 360
    accentColor: Theme.mauve

    // VM que controla el panel. Con varias encendidas el usuario elige arriba.
    property string current: ""

    function pickDefault() {
        var r = Vm.runningVms;
        for (var i = 0; i < r.length; i++) if (r[i].name === vp.current) return;
        vp.current = r.length > 0 ? r[0].name : "";
    }

    onShownChanged: {
        if (!shown) return;
        // Si la pastilla no llegó a arrancar la sonda (panel abierto por IPC o
        // atajo antes de que exista el widget), arrancarla ahora: `has.viewer`
        // decide si se ofrece "Abrir pantalla".
        Vm.prime();
        Vm.refresh();
        if (vp.current !== "") Vm.loadDetail(vp.current);
    }
    onCurrentChanged: if (vp.shown && vp.current !== "") Vm.loadDetail(vp.current)

    Connections {
        target: Vm
        function onRefreshed() { vp.pickDefault(); }
    }

    // Confirmación para lo irreversible, igual que en el gestor: el usuario ya
    // se ha comido un `virsh reset` sin querer.
    property var confirm: null
    function ask(title, body, label, act) {
        vp.confirm = { title: title, body: body, label: label, act: act };
    }

    readonly property var sel: {
        for (var i = 0; i < Vm.vms.length; i++) if (Vm.vms[i].name === vp.current) return Vm.vms[i];
        return null;
    }

    content: Component {
        ColumnLayout {
            id: body
            width: vp.panelWidth - vp.contentMargin * 2
            spacing: 10
            property real introHeader: 1
            property real introContent: 1

            // ---- cabecera ----
            RowLayout {
                Layout.fillWidth: true
                spacing: 10
                opacity: body.introHeader
                transform: Translate { y: 14 * (1 - body.introHeader) }
                Text {
                    text: Icons.desktop; color: vp.accentColor
                    font.family: Theme.fontFamily; font.pixelSize: Theme.fontSize + 4
                }
                Text {
                    Layout.fillWidth: true
                    text: I18n.t("Virtual machines"); color: Theme.text
                    font.family: Theme.fontFamily; font.pixelSize: Theme.fontSize + 2
                    font.bold: true
                }
                IconButton {
                    icon: Icons.sliders
                    onClicked: { vp.close(); Panels.open("vmManager"); }
                }
            }

            // ---- selector, solo si hay más de una encendida ----
            Flow {
                Layout.fillWidth: true
                visible: Vm.runningVms.length > 1
                opacity: body.introContent
                spacing: 6
                Repeater {
                    model: Vm.runningVms
                    delegate: Rectangle {
                        required property var modelData
                        readonly property bool on: modelData.name === vp.current
                        implicitWidth: Math.min(pickTxt.implicitWidth + 20, body.width)
                        implicitHeight: 28
                        radius: Theme.radius
                        color: on ? vp.accentColor : (pMa.containsMouse ? Theme.surface2 : Theme.surface0)
                        border.width: 1
                        border.color: on ? vp.accentColor : Theme.overlay0
                        Behavior on color { ColorAnimation { duration: Theme.dur(120) } }
                        Text {
                            id: pickTxt
                            anchors.centerIn: parent
                            width: Math.min(implicitWidth, parent.width - 16)
                            text: modelData.name
                            color: parent.on ? Theme.onAccent : Theme.text
                            font.family: Theme.fontFamily; font.pixelSize: Theme.fontSize - 2
                            elide: Text.ElideRight
                            horizontalAlignment: Text.AlignHCenter
                        }
                        MouseArea {
                            id: pMa
                            anchors.fill: parent; hoverEnabled: true; cursorShape: Qt.PointingHandCursor
                            onClicked: vp.current = modelData.name
                        }
                    }
                }
            }

            // ---- tarjeta de la VM elegida ----
            Rectangle {
                Layout.fillWidth: true
                implicitHeight: card.implicitHeight + 24
                visible: vp.sel !== null
                opacity: body.introContent
                radius: Theme.radius
                color: Theme.surface0
                border.width: 1; border.color: Theme.overlay0

                ColumnLayout {
                    id: card
                    anchors.left: parent.left; anchors.right: parent.right
                    anchors.verticalCenter: parent.verticalCenter
                    anchors.leftMargin: 12; anchors.rightMargin: 12
                    spacing: 8

                    RowLayout {
                        Layout.fillWidth: true
                        spacing: 8
                        Rectangle {
                            width: 9; height: 9; radius: 4.5
                            color: vp.sel && vp.sel.state === "running" ? Theme.green : Theme.yellow
                        }
                        Text {
                            Layout.fillWidth: true
                            text: vp.sel ? vp.sel.name : ""
                            color: Theme.text; elide: Text.ElideRight
                            font.family: Theme.fontFamily; font.pixelSize: Theme.fontSize
                            font.bold: true
                        }
                        Text {
                            text: vp.sel ? (vp.sel.state === "running" ? I18n.t("Running") : I18n.t("Paused")) : ""
                            color: Theme.subtext0
                            font.family: Theme.fontFamily; font.pixelSize: Theme.fontSize - 3
                        }
                    }
                    Text {
                        Layout.fillWidth: true
                        text: vp.sel ? (vp.sel.vcpus + " vCPU · "
                              + (vp.sel.curMemKib >= 1048576
                                 ? (vp.sel.curMemKib / 1048576).toFixed(1) + " GiB"
                                 : Math.round(vp.sel.curMemKib / 1024) + " MiB")) : ""
                        color: Theme.subtext0; elide: Text.ElideRight
                        font.family: Theme.fontFamily; font.pixelSize: Theme.fontSize - 3
                    }

                    // ---- abrir ----
                    Flow {
                        Layout.fillWidth: true
                        spacing: 6
                        VmBtn {
                            visible: Vm.has.viewer
                            glyph: Icons.desktop; label: I18n.t("Display"); tint: Theme.blue
                            onClicked: { Vm.openViewer(vp.current); vp.close(); }
                        }
                        VmBtn {
                            glyph: Icons.bars; label: I18n.t("Console"); tint: Theme.mauve
                            onClicked: { Vm.openConsole(vp.current); vp.close(); }
                        }
                    }

                    Rectangle { Layout.fillWidth: true; Layout.preferredHeight: 1; color: Theme.surface2 }

                    // ---- medios en vivo: CD y USB -----------------------------
                    //  Esto es el equivalente del menú "Dispositivos" de
                    //  VirtualBox, que allí vive en la barra de la ventana de la
                    //  VM. Aquí vive en la barra del shell PRECISAMENTE para que
                    //  la ventana de la VM se quede limpia.
                    Text {
                        Layout.fillWidth: true
                        visible: cdRow.visibleChildren.length > 0 || Vm.detail.usbdevs.length > 0
                        text: I18n.t("Devices")
                        color: Theme.subtext0
                        font.family: Theme.fontFamily; font.pixelSize: Theme.fontSize - 3
                        font.bold: true
                    }
                    Flow {
                        id: cdRow
                        Layout.fillWidth: true
                        spacing: 6
                        Repeater {
                            model: Vm.detail.disks.filter(function(d) { return d.device === "cdrom"; })
                            delegate: VmBtn {
                                required property var modelData
                                glyph: Icons.archive
                                tint: Theme.mauve
                                label: modelData.path === "" ? I18n.t("CD empty") : I18n.t("Eject CD")
                                enabled: !Vm.busy && modelData.path !== ""
                                onClicked: Vm.ejectCd(vp.current, modelData.target)
                            }
                        }
                        Repeater {
                            model: Vm.detail.usbdevs
                            delegate: VmBtn {
                                required property var modelData
                                glyph: Icons.close
                                tint: Theme.peach
                                label: I18n.t("Release ") + Vm.usbLabel(modelData.vendor, modelData.product)
                                enabled: !Vm.busy
                                onClicked: Vm.detachUsb(vp.current, modelData.vendor, modelData.product)
                            }
                        }
                    }

                    // ---- portapapeles compartido ------------------------------
                    RowLayout {
                        Layout.fillWidth: true
                        spacing: 8
                        Text {
                            Layout.fillWidth: true
                            text: I18n.t("Shared clipboard")
                            color: Theme.subtext1; elide: Text.ElideRight
                            font.family: Theme.fontFamily; font.pixelSize: Theme.fontSize - 2
                        }
                        Toggle {
                            checked: Vm.clipboardOn
                            onToggled: function(v) { Vm.setClipboard(vp.current, v); }
                        }
                    }
                    Text {
                        Layout.fillWidth: true
                        visible: !Vm.hasSpiceAgent || Vm.clipboardOn
                        text: !Vm.hasSpiceAgent
                              ? I18n.t("This VM has no SPICE agent channel — add it in the manager, then restart the VM.")
                              : I18n.t("Applies on next boot, and needs spice-vdagent running inside the guest.")
                        color: Theme.yellow; wrapMode: Text.Wrap
                        font.family: Theme.fontFamily; font.pixelSize: Theme.fontSize - 4
                    }

                    Rectangle { Layout.fillWidth: true; Layout.preferredHeight: 1; color: Theme.surface2 }

                    // ---- control en vivo ----
                    Flow {
                        Layout.fillWidth: true
                        spacing: 6
                        VmBtn {
                            visible: vp.sel && vp.sel.state === "running"
                            glyph: Icons.pause; label: I18n.t("Pause"); tint: Theme.yellow
                            enabled: !Vm.busy
                            onClicked: Vm.suspend(vp.current)
                        }
                        VmBtn {
                            visible: vp.sel && vp.sel.state === "paused"
                            glyph: Icons.play; label: I18n.t("Resume"); tint: Theme.green
                            enabled: !Vm.busy
                            onClicked: Vm.resume(vp.current)
                        }
                        VmBtn {
                            glyph: Icons.power; label: I18n.t("Shut down")
                            enabled: !Vm.busy
                            onClicked: Vm.shutdown(vp.current)
                        }
                        VmBtn {
                            glyph: Icons.wifi; label: I18n.t("Connect"); tint: Theme.green
                            enabled: !Vm.busy && vp.sel && vp.sel.state === "running"
                            onClicked: Vm.setLink(vp.current, true)
                        }
                        VmBtn {
                            glyph: Icons.noNetwork; label: I18n.t("Disconnect"); tint: Theme.peach
                            enabled: !Vm.busy && vp.sel && vp.sel.state === "running"
                            onClicked: Vm.setLink(vp.current, false)
                        }
                        // ---- destructivas: confirmación obligatoria ----
                        VmBtn {
                            glyph: Icons.power; label: I18n.t("Force off"); tint: Theme.red; danger: true
                            enabled: !Vm.busy
                            onClicked: vp.ask(I18n.t("Force off?"),
                                I18n.t("Cuts power to the VM as if you pulled the plug. Unsaved work inside the guest is lost."),
                                I18n.t("Force off"), function() { Vm.destroy_(vp.current); })
                        }
                        VmBtn {
                            glyph: Icons.reboot; label: I18n.t("Hard reset"); tint: Theme.red; danger: true
                            enabled: !Vm.busy && vp.sel && vp.sel.state === "running"
                            onClicked: vp.ask(I18n.t("Hard reset?"),
                                I18n.t("Resets the VM immediately, without letting the guest shut down. Unsaved work inside the guest is lost."),
                                I18n.t("Hard reset"), function() { Vm.reset_(vp.current); })
                        }
                    }
                }
            }

            Text {
                Layout.fillWidth: true
                visible: Vm.lastError !== ""
                text: Vm.lastError; color: Theme.red; wrapMode: Text.Wrap
                font.family: Theme.fontFamily; font.pixelSize: Theme.fontSize - 3
            }
            Text {
                Layout.fillWidth: true
                visible: Vm.lastNote !== ""
                text: I18n.t(Vm.lastNote); color: Theme.yellow; wrapMode: Text.Wrap
                font.family: Theme.fontFamily; font.pixelSize: Theme.fontSize - 3
            }

            // ---- confirmación en línea (el panel no puede abrir otra ventana) ----
            Rectangle {
                Layout.fillWidth: true
                visible: vp.confirm !== null
                implicitHeight: confCol.implicitHeight + 24
                radius: Theme.radius
                color: Qt.rgba(Theme.red.r, Theme.red.g, Theme.red.b, 0.12)
                border.width: 1; border.color: Theme.red
                ColumnLayout {
                    id: confCol
                    anchors.left: parent.left; anchors.right: parent.right
                    anchors.verticalCenter: parent.verticalCenter
                    anchors.leftMargin: 12; anchors.rightMargin: 12
                    spacing: 6
                    Text {
                        Layout.fillWidth: true
                        text: vp.confirm ? vp.confirm.title : ""
                        color: Theme.red; wrapMode: Text.Wrap; font.bold: true
                        font.family: Theme.fontFamily; font.pixelSize: Theme.fontSize - 1
                    }
                    Text {
                        Layout.fillWidth: true
                        text: vp.confirm ? vp.confirm.body : ""
                        color: Theme.subtext0; wrapMode: Text.Wrap
                        font.family: Theme.fontFamily; font.pixelSize: Theme.fontSize - 3
                    }
                    Flow {
                        Layout.fillWidth: true
                        spacing: 6
                        layoutDirection: Qt.RightToLeft
                        VmBtn {
                            label: vp.confirm ? vp.confirm.label : ""
                            tint: Theme.red; danger: true
                            onClicked: {
                                var a = vp.confirm ? vp.confirm.act : null;
                                vp.confirm = null;
                                if (a) a();
                            }
                        }
                        VmBtn { label: I18n.t("Cancel"); onClicked: vp.confirm = null }
                    }
                }
            }
        }
    }

    // Botón compacto del panel — mismo lenguaje visual que el resto del shell.
    component VmBtn : Rectangle {
        id: vb
        property string glyph: ""
        property string label: ""
        property color tint: Theme.text
        property bool danger: false
        property bool enabled: true
        signal clicked()
        implicitHeight: 28
        implicitWidth: vbRow.implicitWidth + 18
        radius: Theme.radius
        opacity: vb.enabled ? 1 : 0.4
        color: !vb.enabled ? Theme.surface1
             : vbMa.pressed ? Theme.surface2
             : vbMa.containsMouse ? (vb.danger ? Qt.rgba(Theme.red.r, Theme.red.g, Theme.red.b, 0.2) : Theme.surface2)
             : Theme.surface1
        border.width: vb.danger ? 1 : 0
        border.color: Theme.red
        Behavior on color { ColorAnimation { duration: Theme.dur(120) } }
        scale: vbMa.pressed && vb.enabled ? 0.95 : 1
        Behavior on scale { NumberAnimation { duration: Theme.dur(90); easing.type: Theme.easing } }
        RowLayout {
            id: vbRow
            anchors.centerIn: parent
            spacing: 6
            Text {
                visible: vb.glyph !== ""
                text: vb.glyph; color: vb.tint
                font.family: Theme.fontFamily; font.pixelSize: Theme.fontSize - 1
            }
            Text {
                visible: vb.label !== ""
                text: vb.label; color: vb.danger ? Theme.red : Theme.text
                font.family: Theme.fontFamily; font.pixelSize: Theme.fontSize - 2
            }
        }
        MouseArea {
            id: vbMa
            anchors.fill: parent; hoverEnabled: true
            enabled: vb.enabled
            cursorShape: Qt.PointingHandCursor
            onClicked: vb.clicked()
        }
    }
}
