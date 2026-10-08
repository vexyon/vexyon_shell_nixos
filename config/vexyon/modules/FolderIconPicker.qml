import QtQuick
import QtQuick.Layouts
import Quickshell
import qs.services
import qs.components

// ============================================================================
//  FolderIconPicker — "Customize Folder Icon" in the File Manager.
//
//  The library is FolderIcons.catalog (Material Design glyphs of the Nerd Font
//  the shell already ships), grouped in categories and searchable in English
//  and in the UI language. The preview is the real folder artwork with the
//  chosen symbol on it, in the current theme. Apply stores the choice
//  (vexyon-fm-helper icon-set); Reset goes back to the default (the XDG
//  folder's symbol, or none); "Image…" lets the File Manager pick a local
//  SVG/PNG, which the helper sanitises before it is ever shown.
// ============================================================================
Card {
    id: picker

    required property string path
    property real maxWidth: 620
    property real maxHeight: 600
    signal closeRequested()
    signal chooseImage()

    property string query: ""
    property string cat: ""                  // "" = all categories
    property string selected: {
        var c = FolderIcons.customId(picker.path);
        return c.indexOf("md:") === 0 ? c.substring(3) : "";
    }
    property string hovered: ""
    property bool busy: false
    property string error: ""

    readonly property string folderName: {
        var s = picker.path.replace(/\/+$/, "");
        return s.substring(s.lastIndexOf("/") + 1) || "/";
    }
    readonly property string customId: FolderIcons.customId(picker.path)
    readonly property string defaultId: FolderIcons.defaultId(picker.path)
    readonly property var results: FolderIcons.search(picker.query, picker.cat)
    readonly property var preview: picker.selected !== ""
                                   ? FolderIcons.render("md:" + picker.selected, "")
                                   : FolderIcons.emblemFor(picker.path)

    function labelOf(id) {
        var e = FolderIcons.byId[id];
        return e ? I18n.t(e.label) + "  ·  " + I18n.t(FolderIcons.catLabel(e.cat)) : "";
    }
    function apply() {
        if (picker.selected === "" || picker.busy) return;
        picker.busy = true;
        picker.error = "";
        FolderIcons.set(picker.path, picker.selected, function(ok, err) {
            picker.busy = false;
            if (ok) picker.closeRequested();
            else picker.error = err !== "" ? I18n.t(err) : I18n.t("The icon could not be saved.");
        });
    }
    function reset() {
        if (picker.busy) return;
        picker.busy = true;
        FolderIcons.reset(picker.path, function() { picker.busy = false; picker.closeRequested(); });
    }

    width: Math.min(620, picker.maxWidth)
    implicitHeight: Math.min(picker.maxHeight, 640)
    color: Theme.base
    radius: Theme.radius + 4
    MouseArea { anchors.fill: parent }   // swallow clicks

    ColumnLayout {
        anchors.fill: parent
        anchors.margins: 20
        spacing: 10

        // ---- the folder, as it will look -----------------------------------
        RowLayout {
            Layout.fillWidth: true
            spacing: 14
            Rectangle {
                Layout.preferredWidth: 84
                Layout.preferredHeight: 84
                radius: Theme.radius
                color: Theme.surface0
                FolderGlyph {
                    anchors.fill: parent
                    anchors.topMargin: Math.round((parent.height - implicitHeight) / 2)
                    glyph: Icons.folder
                    glyphColor: Theme.accent
                    pixelSize: 60
                    inkCentered: true
                    emblem: picker.preview
                }
            }
            ColumnLayout {
                Layout.fillWidth: true
                spacing: 2
                Text {
                    text: I18n.t("Customize Folder Icon")
                    color: Theme.text
                    font.family: Theme.fontFamily
                    font.pixelSize: Theme.fontSize + 2
                    font.bold: true
                }
                Text {
                    Layout.fillWidth: true
                    text: picker.folderName
                    color: Theme.subtext1
                    font.family: Theme.fontFamily
                    font.pixelSize: Theme.fontSize - 1
                    elide: Text.ElideMiddle
                }
                Text {
                    Layout.fillWidth: true
                    text: picker.customId !== "" ? I18n.t("Custom icon")
                          : picker.defaultId !== "" ? I18n.t("Default icon of this folder")
                          : I18n.t("No icon yet")
                    color: Theme.overlay2
                    font.family: Theme.fontFamily
                    font.pixelSize: Theme.fontSize - 3
                }
            }
            IconButton { icon: Icons.close; onClicked: picker.closeRequested() }
        }

        // ---- search -------------------------------------------------------------
        Rectangle {
            Layout.fillWidth: true
            Layout.preferredHeight: 34
            radius: Theme.radius
            color: Theme.surface0
            border.width: searchIn.activeFocus ? 1 : 0
            border.color: Theme.accent
            RowLayout {
                anchors.fill: parent
                anchors.leftMargin: 12
                anchors.rightMargin: 12
                spacing: 8
                Text { text: Icons.search; color: Theme.overlay2; font.family: Theme.fontFamily; font.pixelSize: Theme.fontSize - 1 }
                TextInput {
                    id: searchIn
                    Layout.fillWidth: true
                    verticalAlignment: TextInput.AlignVCenter
                    clip: true
                    color: Theme.text
                    font.family: Theme.fontFamily
                    font.pixelSize: Theme.fontSize - 1
                    selectionColor: Theme.accent
                    onTextChanged: picker.query = text
                    Keys.onPressed: function(ev) {
                        if (ev.key === Qt.Key_Escape) { picker.closeRequested(); ev.accepted = true; }
                    }
                    onAccepted: {
                        if (picker.selected === "" && picker.results.length === 1) picker.selected = picker.results[0].id;
                        picker.apply();
                    }
                    Component.onCompleted: forceActiveFocus()
                    Text {
                        anchors.verticalCenter: parent.verticalCenter
                        visible: searchIn.text === ""
                        text: I18n.t("Search icons")
                        color: Theme.overlay1
                        font: searchIn.font
                    }
                }
            }
        }

        // ---- categories ---------------------------------------------------------
        Flow {
            Layout.fillWidth: true
            spacing: 5
            Repeater {
                model: [{ id: "", label: "All" }].concat(FolderIcons.categories)
                delegate: Rectangle {
                    required property var modelData
                    readonly property bool on: picker.cat === modelData.id
                    width: chipText.implicitWidth + 18
                    height: 24
                    radius: 12
                    color: on ? Theme.accent : (chipMa.containsMouse ? Theme.surface2 : Theme.surface1)
                    Text {
                        id: chipText
                        anchors.centerIn: parent
                        text: I18n.t(modelData.label)
                        color: parent.on ? Theme.onAccent : Theme.text
                        font.family: Theme.fontFamily
                        font.pixelSize: Theme.fontSize - 3
                    }
                    MouseArea {
                        id: chipMa
                        anchors.fill: parent
                        hoverEnabled: true
                        cursorShape: Qt.PointingHandCursor
                        onClicked: picker.cat = modelData.id
                    }
                }
            }
        }

        // ---- the icons --------------------------------------------------------------
        Rectangle {
            Layout.fillWidth: true
            Layout.fillHeight: true
            Layout.minimumHeight: 110
            radius: Theme.radius
            color: Theme.mantle
            GridView {
                id: grid
                anchors.fill: parent
                anchors.margins: 6
                clip: true
                cellWidth: Math.floor(width / Math.max(1, Math.floor(width / 52)))
                cellHeight: 50
                boundsBehavior: Flickable.StopAtBounds
                model: picker.results
                delegate: Item {
                    required property var modelData
                    width: grid.cellWidth
                    height: grid.cellHeight
                    readonly property bool on: picker.selected === modelData.id
                    Rectangle {
                        anchors.fill: parent
                        anchors.margins: 3
                        radius: Theme.radius - 2
                        color: parent.on ? Qt.alpha(Theme.accent, 0.22)
                               : (iconMa.containsMouse ? Theme.surface1 : "transparent")
                        border.width: parent.on ? 1 : 0
                        border.color: Theme.accent
                        Text {
                            anchors.centerIn: parent
                            text: FolderIcons.glyphChar(modelData.glyph)
                            color: parent.parent.on ? Theme.accent : Theme.text
                            font.family: FolderIcons.symbolFont
                            font.pixelSize: 22
                        }
                    }
                    MouseArea {
                        id: iconMa
                        anchors.fill: parent
                        hoverEnabled: true
                        cursorShape: Qt.PointingHandCursor
                        onEntered: picker.hovered = modelData.id
                        onExited: if (picker.hovered === modelData.id) picker.hovered = ""
                        onClicked: picker.selected = modelData.id
                        onDoubleClicked: { picker.selected = modelData.id; picker.apply(); }
                    }
                }
            }
            Text {
                anchors.centerIn: parent
                visible: picker.results.length === 0
                text: I18n.t("No icons match")
                color: Theme.overlay2
                font.family: Theme.fontFamily
                font.pixelSize: Theme.fontSize - 1
            }
        }

        Text {
            Layout.fillWidth: true
            text: picker.hovered !== "" ? picker.labelOf(picker.hovered)
                  : picker.selected !== "" ? picker.labelOf(picker.selected)
                  : picker.results.length + I18n.t(" icons")
            color: Theme.subtext0
            font.family: Theme.fontFamily
            font.pixelSize: Theme.fontSize - 3
            elide: Text.ElideRight
        }
        Text {
            Layout.fillWidth: true
            visible: picker.error !== ""
            text: picker.error
            color: Theme.red
            wrapMode: Text.WordWrap
            font.family: Theme.fontFamily
            font.pixelSize: Theme.fontSize - 2
        }

        // ---- actions ----------------------------------------------------------------
        RowLayout {
            Layout.fillWidth: true
            spacing: 8
            Rectangle {
                Layout.preferredHeight: 34
                Layout.preferredWidth: imgText.implicitWidth + 26
                radius: Theme.radius
                color: imgMa.containsMouse ? Theme.surface2 : Theme.surface1
                Text { id: imgText; anchors.centerIn: parent; text: I18n.t("Image…"); color: Theme.text; font.family: Theme.fontFamily; font.pixelSize: Theme.fontSize - 2 }
                MouseArea { id: imgMa; anchors.fill: parent; hoverEnabled: true; cursorShape: Qt.PointingHandCursor; onClicked: picker.chooseImage() }
            }
            Rectangle {
                visible: picker.customId !== ""
                Layout.preferredHeight: 34
                Layout.preferredWidth: resetText.implicitWidth + 26
                radius: Theme.radius
                color: resetMa.containsMouse ? Theme.surface2 : Theme.surface1
                Text { id: resetText; anchors.centerIn: parent; text: I18n.t("Reset to default"); color: Theme.text; font.family: Theme.fontFamily; font.pixelSize: Theme.fontSize - 2 }
                MouseArea { id: resetMa; anchors.fill: parent; hoverEnabled: true; cursorShape: Qt.PointingHandCursor; onClicked: picker.reset() }
            }
            Item { Layout.fillWidth: true }
            Rectangle {
                Layout.preferredHeight: 34
                Layout.preferredWidth: cancelText.implicitWidth + 30
                radius: Theme.radius
                color: cancelMa.containsMouse ? Theme.surface2 : Theme.surface1
                Text { id: cancelText; anchors.centerIn: parent; text: I18n.t("Cancel"); color: Theme.text; font.family: Theme.fontFamily; font.pixelSize: Theme.fontSize - 1 }
                MouseArea { id: cancelMa; anchors.fill: parent; hoverEnabled: true; cursorShape: Qt.PointingHandCursor; onClicked: picker.closeRequested() }
            }
            Rectangle {
                readonly property bool can: picker.selected !== "" && !picker.busy
                Layout.preferredHeight: 34
                Layout.preferredWidth: applyText.implicitWidth + 34
                radius: Theme.radius
                color: !can ? Theme.surface2 : (applyMa.containsMouse ? Theme.accent2 : Theme.accent)
                Text { id: applyText; anchors.centerIn: parent; text: I18n.t("Apply"); color: parent.can ? Theme.onAccent : Theme.overlay2; font.family: Theme.fontFamily; font.pixelSize: Theme.fontSize - 1; font.bold: true }
                MouseArea { id: applyMa; anchors.fill: parent; enabled: parent.can; hoverEnabled: true; cursorShape: Qt.PointingHandCursor; onClicked: picker.apply() }
            }
        }
    }
}
