import QtQuick
import QtQuick.Controls
import Quickshell
import Quickshell.Wayland
import Quickshell.Hyprland
import Quickshell.Widgets
import qs.services
import qs.components

// ============================================================================
//  App Launcher — fuzzy search over desktop entries, DankMaterialShell/ilyamiro
//  style. Toggled by Super+A (global -> Panels.launcher). No blur (popups).
//
//  Robustness: the app list is a REACTIVE binding on DesktopEntries — it rebuilds
//  whenever entries (re)load, so opening the launcher before the entry scan
//  finishes no longer shows an empty list (the old one-shot snapshot bug).
// ============================================================================
PanelWindow {
    id: win
    visible: Panels.launcher

    WlrLayershell.namespace: "vexyon-launcher"
    WlrLayershell.layer: WlrLayer.Overlay
    // ignore the bar's exclusive zone so this surface spans the FULL output.
    // Otherwise the bar's reserved strip shrinks the surface and the panel
    // (anchors.horizontalCenter / top+13%) centres against the partial area,
    // landing off-centre — and the offset flips with bar edge (top/bottom vs
    // left/right) and resolution. With the full output the centring is against
    // live current geometry, correct on any resolution. Same mechanism every
    // other full-screen overlay uses (WallpaperPicker/Onboarding/OSD/…).
    WlrLayershell.exclusiveZone: -1
    WlrLayershell.keyboardFocus: visible ? WlrKeyboardFocus.Exclusive : WlrKeyboardFocus.None
    color: "transparent"

    anchors { top: true; bottom: true; left: true; right: true }

    // ---- reactive source of truth: rebuilds on every entry (re)load ----
    readonly property var allApps: DesktopEntries.applications ? DesktopEntries.applications.values : []
    onAllAppsChanged: win.rebuild()

    property var results: []
    property int selected: 0

    // columnas actuales del grid (misma fórmula que su cellWidth: ancho/108)
    function gridCols() { return Math.max(1, Math.floor(grid.width / 108)); }

    // view mode ("list" | "grid"), persisted; and a transient reveal of hidden apps
    property string viewMode: Config.get("launcher", "viewMode", "list")
    property bool showHidden: false

    // ---- per-app overrides (hidden / custom name / custom icon), keyed by
    // desktop-entry id and persisted under launcher.overrides in shell.json ----
    function appKey(e) { return e ? (e.id || e.name || "") : ""; }
    function ov(e) {
        var o = Config.get("launcher", "overrides", null) || ({});
        return o[win.appKey(e)] || ({});
    }
    function dispName(e) { var o = win.ov(e); return (o.name && o.name !== "") ? o.name : (e ? (e.name || "") : ""); }
    function dispIcon(e) { var o = win.ov(e); return (o.icon && o.icon !== "") ? o.icon : (e ? e.icon : ""); }
    function isHidden(e) { return win.ov(e).hidden === true; }
    function setOverride(e, key, val) {
        var all = JSON.parse(JSON.stringify(Config.get("launcher", "overrides", null) || ({})));
        var k = win.appKey(e);
        if (!all[k]) all[k] = {};
        all[k][key] = val;
        Config.set("launcher", "overrides", all);
    }
    function setViewMode(m) { win.viewMode = m; Config.set("launcher", "viewMode", m); }

    // ---- context menu + edit dialog state ----
    property var ctxEntry: null
    property real ctxX: 0
    property real ctxY: 0
    property bool ctxOpen: false
    property bool editOpen: false
    function openCtx(entry, gx, gy) { win.ctxEntry = entry; win.ctxX = gx; win.ctxY = gy; win.ctxOpen = true; }
    function openEdit(entry) {
        win.ctxEntry = entry; win.ctxOpen = false;
        editName.text = win.dispName(entry);
        editIcon.text = win.ov(entry).icon || (entry ? entry.icon : "");
        win.editOpen = true;
    }

    // fzf-ish subsequence test: are all chars of q present in order in s?
    function subseq(q, s) {
        var i = 0;
        for (var j = 0; j < s.length && i < q.length; j++)
            if (s.charCodeAt(j) === q.charCodeAt(i)) i++;
        return i === q.length;
    }

    function rebuild() {
        var q = search.text.trim().toLowerCase();
        var apps = win.allApps;
        var scored = [];
        for (var i = 0; i < apps.length; i++) {
            var a = apps[i];
            if (!a || a.noDisplay) continue;
            if (win.isHidden(a) && !win.showHidden) continue;   // user-hidden app
            var name = win.dispName(a).toLowerCase();           // honor custom name
            if (name === "") continue;
            if (q === "") { scored.push({ e: a, s: 100, n: name }); continue; }

            var gen = (a.genericName || "").toLowerCase();
            var comment = (a.comment || "").toLowerCase();
            var kw = "";
            try { kw = (a.keywords || []).join(" ").toLowerCase(); } catch (e) { kw = ""; }
            var exe = (a.command || a.execString || "").toLowerCase();

            var score = -1;
            if (name === q) score = 0;
            else if (name.startsWith(q)) score = 1;
            else if ((" " + name).indexOf(" " + q) !== -1) score = 2;   // word start
            else if (name.indexOf(q) !== -1) score = 3;
            else if (gen.indexOf(q) !== -1) score = 4;
            else if (kw.indexOf(q) !== -1) score = 5;
            else if (comment.indexOf(q) !== -1) score = 6;
            else if (exe.indexOf(q) !== -1) score = 7;
            else if (win.subseq(q, name)) score = 8;                    // fuzzy last
            if (score >= 0) scored.push({ e: a, s: score, n: name });
        }
        // sort by score then name
        scored.sort(function(x, y) {
            if (x.s !== y.s) return x.s - y.s;
            return x.n < y.n ? -1 : (x.n > y.n ? 1 : 0);
        });
        var out = [];
        for (var k = 0; k < scored.length; k++) out.push(scored[k].e);
        win.results = out;
        win.selected = 0;
        list.positionViewAtBeginning();
    }

    function launch(entry) {
        if (!entry) return;
        try { entry.execute(); }
        catch (e) { Quickshell.execDetached({ command: entry.command, workingDirectory: entry.workingDirectory }); }
        Panels.close("launcher");
    }

    onVisibleChanged: {
        if (visible) { search.text = ""; win.rebuild(); search.forceActiveFocus(); }
        else { win.ctxOpen = false; win.editOpen = false; win.showHidden = false; }
    }

    // Dim backdrop; click outside the panel to dismiss.
    Rectangle {
        anchors.fill: parent
        color: "#00000077"
        opacity: win.visible ? 1 : 0
        Behavior on opacity { NumberAnimation { duration: Theme.dur(150) } }
        MouseArea { anchors.fill: parent; onClicked: Panels.close("launcher") }
    }

    // ---- panel ----
    Card {
        id: panel
        // TRUE centring on both axes. The old recipe was
        // horizontalCenter + top + topMargin: parent.height * 0.13 — that is a
        // 13%-from-the-top placement, never a vertical centring, so the panel
        // sat high by (height/2 - 0.13*height - panelH/2) px on EVERY output
        // (measured: 130px off on 1920x1080, 263 on 2560x1440, 440 on a
        // 1080x1920 vertical, 322 on the 2560x1600 laptop) and the error grew
        // with screen height / aspect. centerIn resolves against the live
        // parent geometry (the contentItem, which spans the whole output thanks
        // to exclusiveZone: -1 above), so it re-centres on any resolution,
        // aspect ratio, scale change or monitor hotplug — no hardcoded pixels.
        anchors.centerIn: parent
        width: Math.min(640, parent.width - 80)
        height: Math.min(540, parent.height - 160)
        color: Theme.base
        radius: Theme.radius + 6

        opacity: win.visible ? 1 : 0
        scale: win.visible ? 1 : 0.97
        Behavior on opacity { NumberAnimation { duration: Theme.dur(160); easing.type: Theme.easing } }
        Behavior on scale { NumberAnimation { duration: Theme.dur(160); easing.type: Theme.easing } }

        Column {
            anchors.fill: parent
            anchors.margins: 16
            spacing: 12

            // ---- search field ----
            Rectangle {
                width: parent.width
                height: 46
                radius: Theme.radius
                color: Theme.surface0
                border.width: 1
                border.color: search.activeFocus ? Theme.accent : Theme.overlay0
                Behavior on border.color { ColorAnimation { duration: Theme.dur(120) } }

                Row {
                    anchors.fill: parent
                    anchors.leftMargin: 14
                    anchors.rightMargin: 12
                    spacing: 10
                    Text {
                        anchors.verticalCenter: parent.verticalCenter
                        text: Icons.search
                        font.family: Theme.fontFamily
                        font.pixelSize: Theme.fontSize + 2
                        color: search.activeFocus ? Theme.accent : Theme.subtext0
                    }
                    TextField {
                        id: search
                        anchors.verticalCenter: parent.verticalCenter
                        width: parent.width - 40 - countBadge.width - viewBtn.width - hidBtn.width - 34
                        placeholderText: I18n.t("Search applications…")
                        color: Theme.text
                        placeholderTextColor: Theme.overlay2
                        font.family: Theme.fontFamily
                        font.pixelSize: Theme.fontSize + 1
                        background: null
                        onTextChanged: win.rebuild()
                        // En grid, ↑/↓ saltan una FILA (± columnas) y ←/→ un
                        // item dentro de la fila, sin envolver a la fila
                        // anterior/siguiente (consistente con el clamp de la
                        // lista, que tampoco envuelve). En lista, ←/→ quedan
                        // para el cursor del texto (accepted=false).
                        Keys.onDownPressed: {
                            if (win.viewMode === "grid") {
                                var c = win.gridCols();
                                if (win.selected + c < win.results.length) win.selected += c;
                                else if (Math.floor(win.selected / c) < Math.floor((win.results.length - 1) / c))
                                    win.selected = win.results.length - 1;   // fila de abajo más corta → último
                            } else {
                                win.selected = Math.min(win.selected + 1, win.results.length - 1);
                            }
                        }
                        Keys.onUpPressed: {
                            if (win.viewMode === "grid") {
                                var c = win.gridCols();
                                if (win.selected - c >= 0) win.selected -= c;
                            } else {
                                win.selected = Math.max(win.selected - 1, 0);
                            }
                        }
                        Keys.onLeftPressed: function(event) {
                            if (win.viewMode === "grid") {
                                if (win.selected % win.gridCols() > 0) win.selected--;
                            } else {
                                event.accepted = false;   // lista: cursor del TextField
                            }
                        }
                        Keys.onRightPressed: function(event) {
                            if (win.viewMode === "grid") {
                                var c = win.gridCols();
                                if (win.selected % c < c - 1 && win.selected + 1 < win.results.length)
                                    win.selected++;
                            } else {
                                event.accepted = false;
                            }
                        }
                        Keys.onReturnPressed: win.launch(win.results[win.selected])
                        Keys.onEnterPressed: win.launch(win.results[win.selected])
                        Keys.onEscapePressed: Panels.close("launcher")
                    }
                    // toggle hidden apps visibility
                    IconButton {
                        id: hidBtn
                        anchors.verticalCenter: parent.verticalCenter
                        icon: win.showHidden ? Icons.eye : Icons.eyeSlash
                        iconColor: win.showHidden ? Theme.accent : Theme.subtext0
                        iconSize: Theme.fontSize; implicitWidth: 30; implicitHeight: 30
                        onClicked: { win.showHidden = !win.showHidden; win.rebuild(); }
                    }
                    // list <-> grid view toggle
                    IconButton {
                        id: viewBtn
                        anchors.verticalCenter: parent.verticalCenter
                        icon: win.viewMode === "grid" ? Icons.list : Icons.grid
                        iconColor: Theme.text
                        iconSize: Theme.fontSize; implicitWidth: 30; implicitHeight: 30
                        onClicked: win.setViewMode(win.viewMode === "grid" ? "list" : "grid")
                    }
                    // result count badge
                    Rectangle {
                        id: countBadge
                        anchors.verticalCenter: parent.verticalCenter
                        width: countTxt.implicitWidth + 16
                        height: 22
                        radius: 11
                        color: Theme.surface2
                        visible: win.results.length > 0
                        Text {
                            id: countTxt
                            anchors.centerIn: parent
                            text: win.results.length
                            color: Theme.subtext1
                            font.family: Theme.fontFamily
                            font.pixelSize: Theme.fontSize - 3
                        }
                    }
                }
            }

            // ---- results (list or grid) ----
            Item {
                id: resultsArea
                width: parent.width
                height: parent.height - 46 - 12 - 22 - 8

                // LIST VIEW
                ListView {
                    id: list
                    anchors.fill: parent
                    visible: win.viewMode !== "grid"
                    clip: true
                    model: win.results
                    currentIndex: win.selected
                    boundsBehavior: Flickable.StopAtBounds
                    spacing: 2

                    onCurrentIndexChanged: positionViewAtIndex(currentIndex, ListView.Contain)

                    delegate: Rectangle {
                        id: row
                        required property int index
                        required property var modelData
                        readonly property bool sel: index === win.selected
                        readonly property bool hiddenApp: win.isHidden(row.modelData)
                        width: list.width
                        height: 54
                        radius: Theme.radius
                        color: sel ? Qt.rgba(Theme.accent.r, Theme.accent.g, Theme.accent.b, 0.16) : "transparent"
                        opacity: hiddenApp ? 0.5 : 1.0

                        // selection accent bar
                        Rectangle {
                            anchors.left: parent.left
                            anchors.verticalCenter: parent.verticalCenter
                            width: 3
                            height: row.sel ? 28 : 0
                            radius: 2
                            color: Theme.accent
                            Behavior on height { NumberAnimation { duration: Theme.dur(120); easing.type: Theme.easing } }
                        }

                        MouseArea {
                            anchors.fill: parent
                            hoverEnabled: true
                            acceptedButtons: Qt.LeftButton | Qt.RightButton
                            cursorShape: Qt.PointingHandCursor
                            onPositionChanged: win.selected = row.index
                            onClicked: function(m) {
                                if (m.button === Qt.RightButton) {
                                    var p = row.mapToItem(panel, m.x, m.y);
                                    win.openCtx(row.modelData, p.x, p.y);
                                } else win.launch(row.modelData);
                            }
                        }

                        Row {
                            anchors.fill: parent
                            anchors.leftMargin: 14
                            anchors.rightMargin: 14
                            spacing: 14

                            IconImage {
                                anchors.verticalCenter: parent.verticalCenter
                                implicitSize: 38
                                source: Quickshell.iconPath(win.dispIcon(row.modelData), "application-x-executable")
                            }
                            Column {
                                anchors.verticalCenter: parent.verticalCenter
                                width: parent.width - 90
                                spacing: 1
                                Text {
                                    text: win.dispName(row.modelData)
                                    color: Theme.text
                                    font.family: Theme.fontFamily
                                    font.pixelSize: Theme.fontSize
                                    font.bold: row.sel
                                    elide: Text.ElideRight
                                    width: parent.width
                                }
                                Text {
                                    text: row.modelData.genericName || row.modelData.comment || ""
                                    visible: text !== ""
                                    color: Theme.subtext0
                                    font.family: Theme.fontFamily
                                    font.pixelSize: Theme.fontSize - 3
                                    elide: Text.ElideRight
                                    width: parent.width
                                }
                            }
                        }
                        // hidden badge
                        Text {
                            anchors.right: parent.right; anchors.rightMargin: 14
                            anchors.verticalCenter: parent.verticalCenter
                            visible: row.hiddenApp
                            text: Icons.eyeSlash; color: Theme.overlay2
                            font.family: Theme.fontFamily; font.pixelSize: Theme.fontSize - 2
                        }
                    }
                }

                // GRID VIEW
                GridView {
                    id: grid
                    anchors.fill: parent
                    visible: win.viewMode === "grid"
                    clip: true
                    model: win.results
                    currentIndex: win.selected
                    boundsBehavior: Flickable.StopAtBounds
                    cellWidth: Math.floor(width / Math.max(1, Math.floor(width / 108)))
                    cellHeight: 104
                    onCurrentIndexChanged: positionViewAtIndex(currentIndex, GridView.Contain)

                    delegate: Item {
                        id: cell
                        required property int index
                        required property var modelData
                        readonly property bool sel: index === win.selected
                        readonly property bool hiddenApp: win.isHidden(cell.modelData)
                        width: grid.cellWidth
                        height: grid.cellHeight
                        opacity: hiddenApp ? 0.5 : 1.0

                        Rectangle {
                            anchors.centerIn: parent
                            width: parent.width - 8
                            height: parent.height - 8
                            radius: Theme.radius
                            color: cell.sel ? Qt.rgba(Theme.accent.r, Theme.accent.g, Theme.accent.b, 0.16)
                                   : cellMa.containsMouse ? Theme.surface0 : "transparent"
                            border.width: cell.sel ? 1 : 0
                            border.color: Theme.accent

                            Column {
                                anchors.centerIn: parent
                                spacing: 8
                                IconImage {
                                    anchors.horizontalCenter: parent.horizontalCenter
                                    implicitSize: 46
                                    source: Quickshell.iconPath(win.dispIcon(cell.modelData), "application-x-executable")
                                }
                                Text {
                                    anchors.horizontalCenter: parent.horizontalCenter
                                    width: cell.width - 16
                                    horizontalAlignment: Text.AlignHCenter
                                    text: win.dispName(cell.modelData)
                                    color: Theme.text
                                    font.family: Theme.fontFamily
                                    font.pixelSize: Theme.fontSize - 3
                                    font.bold: cell.sel
                                    elide: Text.ElideRight
                                    maximumLineCount: 1
                                }
                            }
                        }
                        MouseArea {
                            id: cellMa
                            anchors.fill: parent
                            hoverEnabled: true
                            acceptedButtons: Qt.LeftButton | Qt.RightButton
                            cursorShape: Qt.PointingHandCursor
                            onPositionChanged: win.selected = cell.index
                            onClicked: function(m) {
                                if (m.button === Qt.RightButton) {
                                    var p = cell.mapToItem(panel, m.x, m.y);
                                    win.openCtx(cell.modelData, p.x, p.y);
                                } else win.launch(cell.modelData);
                            }
                        }
                    }
                }

                // empty / loading state (shared)
                Column {
                    anchors.centerIn: parent
                    spacing: 8
                    visible: win.results.length === 0
                    Text {
                        anchors.horizontalCenter: parent.horizontalCenter
                        text: win.allApps.length === 0 ? Icons.refresh : Icons.search
                        color: Theme.overlay2
                        font.family: Theme.fontFamily
                        font.pixelSize: Theme.fontSize + 10
                    }
                    Text {
                        anchors.horizontalCenter: parent.horizontalCenter
                        text: win.allApps.length === 0 ? I18n.t("Loading applications…")
                              : (search.text.trim() !== "" ? I18n.t("No results for «") + search.text.trim() + "»"
                                                           : I18n.t("No applications"))
                        color: Theme.overlay2
                        font.family: Theme.fontFamily
                        font.pixelSize: Theme.fontSize
                    }
                }
            }

            // ---- footer hint ----
            Item {
                width: parent.width
                height: 22
                Row {
                    anchors.left: parent.left
                    anchors.verticalCenter: parent.verticalCenter
                    spacing: 14
                    Text { text: I18n.t("↑↓ navigate"); color: Theme.overlay1; font.family: Theme.fontFamily; font.pixelSize: Theme.fontSize - 4 }
                    Text { text: I18n.t("↵ open"); color: Theme.overlay1; font.family: Theme.fontFamily; font.pixelSize: Theme.fontSize - 4 }
                    Text { text: I18n.t("esc close"); color: Theme.overlay1; font.family: Theme.fontFamily; font.pixelSize: Theme.fontSize - 4 }
                }
                Text {
                    anchors.right: parent.right
                    anchors.verticalCenter: parent.verticalCenter
                    text: win.allApps.length + " aplicaciones"
                    color: Theme.overlay1
                    font.family: Theme.fontFamily
                    font.pixelSize: Theme.fontSize - 4
                }
            }
        }

        // ================= right-click context menu =================
        MouseArea {
            anchors.fill: parent
            visible: win.ctxOpen
            acceptedButtons: Qt.LeftButton | Qt.RightButton
            onClicked: win.ctxOpen = false
        }
        Rectangle {
            id: ctxMenu
            visible: win.ctxOpen
            width: 190
            height: ctxCol.implicitHeight + 12
            x: Math.max(8, Math.min(win.ctxX, panel.width - width - 8))
            y: Math.max(8, Math.min(win.ctxY, panel.height - height - 8))
            radius: Theme.radius
            color: Theme.mantle
            border.width: 1; border.color: Theme.surface2
            Column {
                id: ctxCol
                anchors { left: parent.left; right: parent.right; top: parent.top; margins: 6 }
                spacing: 2
                // Editar
                Rectangle {
                    width: parent.width; height: 36; radius: Theme.radius - 2
                    color: ctxEditMa.containsMouse ? Theme.surface1 : "transparent"
                    Row {
                        anchors.fill: parent; anchors.leftMargin: 12; spacing: 10
                        Text { anchors.verticalCenter: parent.verticalCenter; text: Icons.pencil; color: Theme.text; font.family: Theme.fontFamily; font.pixelSize: Theme.fontSize - 1 }
                        Text { anchors.verticalCenter: parent.verticalCenter; text: I18n.t("Edit"); color: Theme.text; font.family: Theme.fontFamily; font.pixelSize: Theme.fontSize - 1 }
                    }
                    MouseArea { id: ctxEditMa; anchors.fill: parent; hoverEnabled: true; cursorShape: Qt.PointingHandCursor; onClicked: win.openEdit(win.ctxEntry) }
                }
                // Ocultar / Mostrar
                Rectangle {
                    readonly property bool hid: win.isHidden(win.ctxEntry)
                    width: parent.width; height: 36; radius: Theme.radius - 2
                    color: ctxHideMa.containsMouse ? Theme.surface1 : "transparent"
                    Row {
                        anchors.fill: parent; anchors.leftMargin: 12; spacing: 10
                        Text { anchors.verticalCenter: parent.verticalCenter; text: parent.parent.hid ? Icons.eye : Icons.eyeSlash; color: Theme.text; font.family: Theme.fontFamily; font.pixelSize: Theme.fontSize - 1 }
                        Text { anchors.verticalCenter: parent.verticalCenter; text: parent.parent.hid ? I18n.t("Show") : I18n.t("Hide"); color: Theme.text; font.family: Theme.fontFamily; font.pixelSize: Theme.fontSize - 1 }
                    }
                    MouseArea {
                        id: ctxHideMa; anchors.fill: parent; hoverEnabled: true; cursorShape: Qt.PointingHandCursor
                        onClicked: { win.setOverride(win.ctxEntry, "hidden", !win.isHidden(win.ctxEntry)); win.ctxOpen = false; win.rebuild(); }
                    }
                }
            }
        }

        // ===================== edit dialog =========================
        Rectangle {
            id: editOverlay
            visible: win.editOpen
            anchors.fill: parent
            radius: panel.radius
            color: Qt.rgba(Theme.base.r, Theme.base.g, Theme.base.b, 0.97)
            MouseArea { anchors.fill: parent }   // swallow clicks behind the dialog

            Column {
                anchors.centerIn: parent
                width: parent.width - 90
                spacing: 16

                Row {
                    spacing: 14
                    IconImage {
                        anchors.verticalCenter: parent.verticalCenter
                        implicitSize: 44
                        source: Quickshell.iconPath(editIcon.text !== "" ? editIcon.text : (win.ctxEntry ? win.ctxEntry.icon : ""), "application-x-executable")
                    }
                    Text {
                        anchors.verticalCenter: parent.verticalCenter
                        text: I18n.t("Edit application")
                        color: Theme.text; font.family: Theme.fontFamily; font.pixelSize: Theme.fontSize + 4; font.bold: true
                    }
                }

                // name field
                Column {
                    width: parent.width; spacing: 5
                    Text { text: I18n.t("Display name"); color: Theme.subtext1; font.family: Theme.fontFamily; font.pixelSize: Theme.fontSize - 2 }
                    Rectangle {
                        width: parent.width; height: 40; radius: Theme.radius
                        color: Theme.surface0; border.width: 1; border.color: editName.activeFocus ? Theme.accent : Theme.overlay0
                        TextField {
                            id: editName
                            anchors.fill: parent; anchors.leftMargin: 12; anchors.rightMargin: 12
                            verticalAlignment: TextInput.AlignVCenter
                            color: Theme.text; placeholderTextColor: Theme.overlay2
                            placeholderText: win.ctxEntry ? (win.ctxEntry.name || "") : ""
                            font.family: Theme.fontFamily; font.pixelSize: Theme.fontSize
                            background: null
                        }
                    }
                }
                // icon field
                Column {
                    width: parent.width; spacing: 5
                    Text { text: I18n.t("Icon (icon theme name, e.g. firefox)"); color: Theme.subtext1; font.family: Theme.fontFamily; font.pixelSize: Theme.fontSize - 2 }
                    Rectangle {
                        width: parent.width; height: 40; radius: Theme.radius
                        color: Theme.surface0; border.width: 1; border.color: editIcon.activeFocus ? Theme.accent : Theme.overlay0
                        TextField {
                            id: editIcon
                            anchors.fill: parent; anchors.leftMargin: 12; anchors.rightMargin: 12
                            verticalAlignment: TextInput.AlignVCenter
                            color: Theme.text; placeholderTextColor: Theme.overlay2
                            placeholderText: win.ctxEntry ? (win.ctxEntry.icon || "") : ""
                            font.family: Theme.fontFamily; font.pixelSize: Theme.fontSize
                            background: null
                        }
                    }
                }

                // buttons
                Row {
                    spacing: 10
                    Rectangle {
                        width: 110; height: 40; radius: Theme.radius
                        color: saveMa.containsMouse ? Theme.accent2 : Theme.accent
                        Text { anchors.centerIn: parent; text: I18n.t("Save"); color: Theme.onAccent; font.family: Theme.fontFamily; font.pixelSize: Theme.fontSize; font.bold: true }
                        MouseArea {
                            id: saveMa; anchors.fill: parent; hoverEnabled: true; cursorShape: Qt.PointingHandCursor
                            onClicked: {
                                win.setOverride(win.ctxEntry, "name", editName.text);
                                win.setOverride(win.ctxEntry, "icon", editIcon.text);
                                win.editOpen = false; win.rebuild();
                            }
                        }
                    }
                    Rectangle {
                        width: 130; height: 40; radius: Theme.radius
                        color: resetMa.containsMouse ? Theme.surface2 : Theme.surface0
                        border.width: 1; border.color: Theme.surface2
                        Text { anchors.centerIn: parent; text: I18n.t("Reset"); color: Theme.text; font.family: Theme.fontFamily; font.pixelSize: Theme.fontSize }
                        MouseArea {
                            id: resetMa; anchors.fill: parent; hoverEnabled: true; cursorShape: Qt.PointingHandCursor
                            onClicked: {
                                win.setOverride(win.ctxEntry, "name", "");
                                win.setOverride(win.ctxEntry, "icon", "");
                                editName.text = ""; editIcon.text = "";
                                win.editOpen = false; win.rebuild();
                            }
                        }
                    }
                    Rectangle {
                        width: 110; height: 40; radius: Theme.radius
                        color: cancelMa.containsMouse ? Theme.surface2 : "transparent"
                        border.width: 1; border.color: Theme.surface2
                        Text { anchors.centerIn: parent; text: I18n.t("Cancel"); color: Theme.subtext1; font.family: Theme.fontFamily; font.pixelSize: Theme.fontSize }
                        MouseArea { id: cancelMa; anchors.fill: parent; hoverEnabled: true; cursorShape: Qt.PointingHandCursor; onClicked: win.editOpen = false }
                    }
                }
            }
        }
    }

    // click-outside dismissal via hyprland focus grab (keeps popup modal)
    HyprlandFocusGrab {
        active: win.visible
        windows: [ win ]
        onCleared: Panels.close("launcher")
    }
}
