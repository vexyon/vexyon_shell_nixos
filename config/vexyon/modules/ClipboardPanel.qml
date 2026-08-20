import QtQuick
import QtQuick.Layouts
import Quickshell
import Quickshell.Io
import qs.services
import qs.components

// ============================================================================
//  ClipboardPanel — themed clipboard-history dropdown backed by cliphist (the
//  same store daemon started at Hyprland exec-once: `wl-paste --watch cliphist
//  store`). Lists past entries, click copies one back to the clipboard, trash
//  removes it, and a footer wipes the whole history. Replaces the old widget
//  action that shelled out to `ghostty -e … fzf …` (fzf isn't a dependency, so
//  it silently did nothing). All theme-token driven.
// ============================================================================
AnchoredPanel {
    id: cp
    panelKey: "clipboardPanel"
    ns: "vexyon-clipboard"
    panelWidth: 460
    accentColor: Theme.teal

    property var entries: []           // [{ id, preview }]
    property bool loaded: false

    onShownChanged: if (shown) cp.refresh()
    function refresh() { listProc.running = true; }

    // cliphist list -> "<id>\t<preview>" lines
    Process {
        id: listProc
        command: ["cliphist", "list"]
        stdout: StdioCollector {
            onStreamFinished: {
                var out = [];
                var lines = this.text.split("\n");
                for (var i = 0; i < lines.length; i++) {
                    var ln = lines[i];
                    if (ln.trim() === "") continue;
                    var tab = ln.indexOf("\t");
                    var id = tab === -1 ? ln.trim() : ln.substring(0, tab).trim();
                    var preview = tab === -1 ? "" : ln.substring(tab + 1);
                    if (!/^\d+$/.test(id)) continue;
                    out.push({ id: id, preview: preview });
                }
                cp.entries = out;
                cp.loaded = true;
            }
        }
    }

    // id is pure digits, so passing it on the command line is injection-safe.
    function copyEntry(id) {
        Quickshell.execDetached(["bash", "-c", "printf '%s' " + id + " | cliphist decode | wl-copy"]);
        cp.close();
    }
    Process { id: delProc; onExited: cp.refresh() }
    function deleteEntry(id) {
        delProc.command = ["bash", "-c", "printf '%s' " + id + " | cliphist delete"];
        delProc.running = true;
    }
    Process { id: wipeProc; onExited: cp.refresh() }
    function wipeAll() { wipeProc.command = ["cliphist", "wipe"]; wipeProc.running = true; }

    content: Component {
        ColumnLayout {
            id: body
            width: cp.panelWidth - cp.contentMargin * 2
            spacing: 12
            property real introHeader: 1
            property real introContent: 1

            // header
            RowLayout {
                Layout.fillWidth: true
                spacing: 10
                opacity: body.introHeader
                transform: Translate { y: 16 * (1 - body.introHeader) }
                Text {
                    text: Icons.clipboard; color: cp.accentColor
                    font.family: Theme.fontFamily; font.pixelSize: Theme.fontSize + 4
                }
                Text {
                    Layout.fillWidth: true
                    text: I18n.t("Clipboard"); color: Theme.text
                    font.family: Theme.fontFamily; font.pixelSize: Theme.fontSize + 2; font.bold: true
                }
                Text {
                    text: cp.entries.length + (cp.entries.length === 1 ? I18n.t(" item") : I18n.t(" items"))
                    color: Theme.subtext0; font.family: Theme.fontFamily; font.pixelSize: Theme.fontSize - 3
                }
            }

            // empty state
            Text {
                Layout.fillWidth: true
                visible: cp.loaded && cp.entries.length === 0
                opacity: body.introContent
                text: I18n.t("No history yet.\nCopy something (Ctrl+C) and it'll appear here.")
                color: Theme.overlay2; wrapMode: Text.WordWrap
                horizontalAlignment: Text.AlignHCenter
                font.family: Theme.fontFamily; font.pixelSize: Theme.fontSize - 1
                Layout.topMargin: 8; Layout.bottomMargin: 8
            }

            // history list
            ListView {
                id: list
                visible: cp.entries.length > 0
                opacity: body.introContent
                Layout.fillWidth: true
                Layout.preferredHeight: Math.min(cp.entries.length * 50, 360)
                clip: true
                spacing: 6
                model: cp.entries
                boundsBehavior: Flickable.StopAtBounds

                delegate: Rectangle {
                    id: row
                    required property int index
                    required property var modelData
                    width: ListView.view.width
                    height: 44
                    radius: Theme.radius
                    color: rowMa.containsMouse ? Theme.surface1 : Theme.surface0
                    Behavior on color { ColorAnimation { duration: Theme.dur(100) } }

                    RowLayout {
                        anchors.fill: parent
                        anchors.leftMargin: 12
                        anchors.rightMargin: 8
                        spacing: 10

                        Text {
                            text: Icons.copy; color: Theme.overlay2
                            font.family: Theme.fontFamily; font.pixelSize: Theme.fontSize - 1
                        }
                        Text {
                            Layout.fillWidth: true
                            text: row.modelData.preview
                            color: Theme.text
                            font.family: Theme.fontFamily; font.pixelSize: Theme.fontSize - 1
                            elide: Text.ElideRight; maximumLineCount: 1
                        }
                        // per-entry delete
                        Rectangle {
                            Layout.preferredWidth: 28; Layout.preferredHeight: 28
                            radius: Theme.radius
                            color: delMa.containsMouse ? Qt.rgba(Theme.red.r, Theme.red.g, Theme.red.b, 0.18) : "transparent"
                            Text {
                                anchors.centerIn: parent; text: Icons.trash
                                color: delMa.containsMouse ? Theme.red : Theme.overlay2
                                font.family: Theme.fontFamily; font.pixelSize: Theme.fontSize - 2
                            }
                            MouseArea {
                                id: delMa
                                anchors.fill: parent; hoverEnabled: true; cursorShape: Qt.PointingHandCursor
                                onClicked: cp.deleteEntry(row.modelData.id)
                            }
                        }
                    }

                    MouseArea {
                        id: rowMa
                        anchors.fill: parent
                        hoverEnabled: true
                        cursorShape: Qt.PointingHandCursor
                        // sits below the delete button's MouseArea, so trash wins its area
                        onClicked: cp.copyEntry(row.modelData.id)
                        z: -1
                    }
                }
            }

            // footer: wipe all
            Rectangle {
                Layout.fillWidth: true
                Layout.preferredHeight: 34
                visible: cp.entries.length > 0
                opacity: body.introContent
                radius: Theme.radius
                color: wipeMa.containsMouse ? Qt.rgba(Theme.red.r, Theme.red.g, Theme.red.b, 0.16) : Theme.surface0
                border.width: 1; border.color: Theme.surface2
                Row {
                    anchors.centerIn: parent
                    spacing: 8
                    Text { anchors.verticalCenter: parent.verticalCenter; text: Icons.trash; color: Theme.red; font.family: Theme.fontFamily; font.pixelSize: Theme.fontSize - 2 }
                    Text { anchors.verticalCenter: parent.verticalCenter; text: I18n.t("Clear history"); color: Theme.red; font.family: Theme.fontFamily; font.pixelSize: Theme.fontSize - 2 }
                }
                MouseArea {
                    id: wipeMa
                    anchors.fill: parent; hoverEnabled: true; cursorShape: Qt.PointingHandCursor
                    onClicked: cp.wipeAll()
                }
            }
        }
    }
}
