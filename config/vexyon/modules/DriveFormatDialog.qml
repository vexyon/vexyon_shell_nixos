import QtQuick
import QtQuick.Layouts
import Quickshell
import Quickshell.Io
import qs.services
import qs.components

// ============================================================================
//  DriveFormatDialog — "Format drive…" in the File Manager.
//
//  Erases an external drive (USB stick, USB disk) and leaves it with one
//  partition: a name, a format (exFAT by default: it works on Windows, macOS
//  and Linux), and a button that has to be pressed twice. The work is done by
//  `vexyon-format` through udisks2; it refuses anything that is not an
//  external drive, whatever is passed. Which formats this system can make is
//  asked once when the dialog opens (`vexyon-format --can`), nothing stays
//  running afterwards.
// ============================================================================
Card {
    id: dlg

    required property string disk            // udisks object of the whole drive
    property string startLabel: ""
    signal closeRequested()
    signal starting()                         // about to erase: leave the drive
    signal formatted(string dev, string obj, string label)

    readonly property var drive: Drives.driveOf(dlg.disk)
    readonly property var types: [
        { id: "exfat", name: "exFAT", max: 15, bytes: false,
          desc: I18n.t("Works on Windows, macOS and Linux. Best for USB sticks and external drives.") },
        { id: "vfat", name: "FAT32", max: 11, bytes: true,
          desc: I18n.t("For older devices (TVs, car stereos, consoles). Files up to 4 GB.") },
        { id: "ntfs", name: "NTFS", max: 32, bytes: false,
          desc: I18n.t("For Windows. macOS can only read it.") },
        { id: "ext4", name: "ext4", max: 16, bytes: true,
          desc: I18n.t("Linux only.") }
    ]
    property string type: "exfat"
    property string label: dlg.startLabel
    property var can: ({})                    // { exfat: { ok, need }, … } from --can
    property bool armed: false
    property bool busy: false
    property string error: ""

    readonly property string bin: {
        var d = Quickshell.env("VEXYON_BIN_DIR");
        var base = (d && d !== "") ? d : Quickshell.env("HOME") + "/.config/vexyon/bin";
        return base + "/vexyon-format";
    }
    function typeOf(id) {
        for (var i = 0; i < dlg.types.length; i++) if (dlg.types[i].id === id) return dlg.types[i];
        return dlg.types[0];
    }
    function available(id) { return !dlg.can[id] || dlg.can[id].ok; }
    function utf8Len(s) { return encodeURIComponent(s).replace(/%[0-9A-F]{2}/g, "x").length; }
    // FAT32 names: upper case, without the characters FAT does not allow.
    function cleanLabel(s, id) {
        s = s.trim();
        if (id === "vfat") s = s.toUpperCase().replace(/[*?.,;:\/\\|+=<>\[\]"]/g, "");
        return s;
    }
    function labelError() {
        var t = dlg.typeOf(dlg.type), s = dlg.cleanLabel(dlg.label, dlg.type);
        var n = t.bytes ? dlg.utf8Len(s) : s.length;
        return n > t.max ? I18n.t("The name is too long for %1 (%2 characters at most).").arg(t.name).arg(t.max) : "";
    }
    // vexyon-format's reasons are English sentences; the ones that carry a
    // detail are translated around it.
    function reason(e) {
        var m;
        if (/target is busy/.test(e)) return I18n.t("A program is still using the drive. Close it and try again.");
        if ((m = /^Could not erase the drive: (.*)$/.exec(e))) return I18n.t("Could not erase the drive: %1").arg(m[1]);
        if ((m = /^Could not create the file system: (.*)$/.exec(e))) return I18n.t("Could not create the file system: %1").arg(m[1]);
        if ((m = /^This drive holds (.*), which the system is using\.$/.exec(e))) return I18n.t("This drive holds %1, which the system is using.").arg(m[1]);
        return e !== "" ? I18n.t(e) : I18n.t("The drive could not be formatted.");
    }
    function close() { if (!dlg.busy) dlg.closeRequested(); }
    function confirm() {
        if (dlg.busy || !dlg.drive) return;
        if (!dlg.available(dlg.type)) return;
        var le = dlg.labelError();
        if (le !== "") { dlg.error = le; return; }
        if (!dlg.armed) { dlg.armed = true; dlg.error = ""; disarm.restart(); return; }
        disarm.stop();
        dlg.armed = false;
        dlg.busy = true;
        dlg.error = "";
        dlg.starting();
        fmtProc.label = dlg.cleanLabel(dlg.label, dlg.type);
        fmtProc.command = [dlg.bin, dlg.disk, dlg.type, fmtProc.label];
        fmtProc.running = true;
    }

    // The second press has to come soon after the first one.
    Timer { id: disarm; interval: 4000; onTriggered: dlg.armed = false }

    Process {
        id: canProc
        command: [dlg.bin, "--can"]
        stdout: StdioCollector {
            onStreamFinished: {
                try { dlg.can = JSON.parse(this.text); } catch (e) { dlg.can = {}; }
                if (!dlg.available(dlg.type))
                    for (var i = 0; i < dlg.types.length; i++)
                        if (dlg.available(dlg.types[i].id)) { dlg.type = dlg.types[i].id; break; }
            }
        }
    }
    Process {
        id: fmtProc
        property string label: ""
        stdout: StdioCollector { id: fmtOut }
        stderr: StdioCollector { id: fmtErr }
        onExited: function(code) {
            dlg.busy = false;
            if (code === 0) {
                var l = fmtOut.text.trim().split("\n");
                dlg.formatted(l[0] || "", l[1] || "", fmtProc.label);
                return;
            }
            dlg.error = dlg.reason(fmtErr.text.trim().split("\n").pop());
        }
    }
    Component.onCompleted: { canProc.running = true; nameIn.forceActiveFocus(); nameIn.selectAll(); }

    width: 460
    implicitHeight: col.implicitHeight + 40
    color: Theme.base
    radius: Theme.radius + 4
    MouseArea { anchors.fill: parent }  // swallow clicks

    ColumnLayout {
        id: col
        anchors.fill: parent
        anchors.margins: 20
        spacing: 12

        RowLayout {
            Layout.fillWidth: true
            Text { text: Icons.drive; color: Theme.accent; font.family: Theme.fontFamily; font.pixelSize: Theme.fontSize + 3 }
            Text {
                Layout.fillWidth: true
                text: I18n.t("Format drive")
                color: Theme.text; font.family: Theme.fontFamily; font.pixelSize: Theme.fontSize + 2; font.bold: true
            }
            IconButton { icon: Icons.close; visible: !dlg.busy; onClicked: dlg.close() }
        }
        Text {
            Layout.fillWidth: true
            text: dlg.drive ? dlg.drive.name + "  ·  " + dlg.drive.size + "  ·  " + dlg.drive.dev
                            : I18n.t("This drive is no longer connected.")
            color: dlg.drive ? Theme.subtext0 : Theme.red
            font.family: Theme.fontFamily; font.pixelSize: Theme.fontSize - 1
            elide: Text.ElideRight
        }
        Text {
            Layout.fillWidth: true
            text: I18n.t("Everything on this drive will be erased.")
            color: Theme.red
            wrapMode: Text.WordWrap
            font.family: Theme.fontFamily; font.pixelSize: Theme.fontSize - 1; font.bold: dlg.armed
        }

        Text {
            text: I18n.t("Name")
            color: Theme.overlay2; font.family: Theme.fontFamily; font.pixelSize: Theme.fontSize - 2
        }
        Rectangle {
            Layout.fillWidth: true
            Layout.preferredHeight: 36
            radius: Theme.radius
            color: Theme.surface0
            border.width: nameIn.activeFocus ? 1 : 0
            border.color: Theme.accent
            TextInput {
                id: nameIn
                anchors.fill: parent
                anchors.leftMargin: 12
                anchors.rightMargin: 12
                verticalAlignment: TextInput.AlignVCenter
                clip: true
                enabled: !dlg.busy
                color: Theme.text
                font.family: Theme.fontFamily
                font.pixelSize: Theme.fontSize
                selectionColor: Theme.accent
                maximumLength: dlg.typeOf(dlg.type).max
                text: dlg.startLabel
                onTextChanged: { dlg.label = text; dlg.error = ""; dlg.armed = false; }
                Keys.onPressed: function(ev) {
                    if (ev.key === Qt.Key_Escape) { dlg.close(); ev.accepted = true; }
                }
                onAccepted: dlg.confirm()
            }
        }

        Text {
            text: I18n.t("Format")
            color: Theme.overlay2; font.family: Theme.fontFamily; font.pixelSize: Theme.fontSize - 2
        }
        Repeater {
            model: dlg.types
            delegate: Rectangle {
                id: opt
                required property var modelData
                readonly property bool ok: dlg.available(modelData.id)
                readonly property bool sel: dlg.type === modelData.id
                Layout.fillWidth: true
                Layout.preferredHeight: optCol.implicitHeight + 14
                radius: Theme.radius
                color: sel ? Qt.alpha(Theme.accent, 0.18) : (optMa.containsMouse && ok ? Theme.surface1 : Theme.surface0)
                border.width: sel ? 1 : 0
                border.color: Theme.accent
                opacity: ok ? 1 : 0.6
                ColumnLayout {
                    id: optCol
                    anchors.left: parent.left; anchors.right: parent.right
                    anchors.verticalCenter: parent.verticalCenter
                    anchors.leftMargin: 12; anchors.rightMargin: 12
                    spacing: 2
                    RowLayout {
                        Layout.fillWidth: true
                        Text {
                            text: opt.modelData.name
                            color: Theme.text; font.family: Theme.fontFamily; font.pixelSize: Theme.fontSize - 1; font.bold: true
                        }
                        Item { Layout.fillWidth: true }
                        Text {
                            visible: opt.sel
                            text: Icons.check
                            color: Theme.accent; font.family: Theme.fontFamily; font.pixelSize: Theme.fontSize - 1
                        }
                    }
                    Text {
                        Layout.fillWidth: true
                        text: opt.ok ? opt.modelData.desc
                              : I18n.t("Not available: %1 is missing. Re-run the Vexyon installer (Arch) or rebuild (NixOS).").arg(dlg.can[opt.modelData.id].need)
                        color: opt.ok ? Theme.subtext0 : Theme.red
                        wrapMode: Text.WordWrap
                        font.family: Theme.fontFamily; font.pixelSize: Theme.fontSize - 3
                    }
                }
                MouseArea {
                    id: optMa
                    anchors.fill: parent
                    hoverEnabled: true
                    enabled: opt.ok && !dlg.busy
                    cursorShape: Qt.PointingHandCursor
                    onClicked: { dlg.type = opt.modelData.id; dlg.error = ""; dlg.armed = false; }
                }
            }
        }

        Text {
            Layout.fillWidth: true
            visible: dlg.error !== "" || dlg.busy
            text: dlg.busy ? I18n.t("Formatting… Do not unplug the drive.") : dlg.error
            color: dlg.busy ? Theme.subtext0 : Theme.red
            wrapMode: Text.WordWrap
            font.family: Theme.fontFamily; font.pixelSize: Theme.fontSize - 2
        }

        RowLayout {
            Layout.fillWidth: true
            spacing: 10
            Item { Layout.fillWidth: true }
            Rectangle {
                Layout.preferredWidth: 100; Layout.preferredHeight: 36
                radius: Theme.radius
                visible: !dlg.busy
                color: cancelMa.containsMouse ? Theme.surface2 : Theme.surface1
                Text { anchors.centerIn: parent; text: I18n.t("Cancel"); color: Theme.text; font.family: Theme.fontFamily; font.pixelSize: Theme.fontSize - 1 }
                MouseArea { id: cancelMa; anchors.fill: parent; hoverEnabled: true; cursorShape: Qt.PointingHandCursor; onClicked: dlg.close() }
            }
            Rectangle {
                Layout.preferredWidth: okTxt.implicitWidth + 28; Layout.preferredHeight: 36
                radius: Theme.radius
                opacity: dlg.busy || !dlg.drive ? 0.6 : 1
                color: okMa.containsMouse && !dlg.busy ? Qt.lighter(Theme.red, 1.15) : Theme.red
                Text {
                    id: okTxt
                    anchors.centerIn: parent
                    text: dlg.busy ? I18n.t("Formatting…")
                          : dlg.armed ? I18n.t("Press again to erase it")
                          : I18n.t("Erase and format")
                    color: Theme.onAccent; font.family: Theme.fontFamily; font.pixelSize: Theme.fontSize - 1; font.bold: true
                }
                MouseArea { id: okMa; anchors.fill: parent; hoverEnabled: true; enabled: !dlg.busy; cursorShape: Qt.PointingHandCursor; onClicked: dlg.confirm() }
            }
        }
    }
}
