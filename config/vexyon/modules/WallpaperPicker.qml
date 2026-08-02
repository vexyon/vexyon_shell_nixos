import QtQuick
import QtQuick.Layouts
import Quickshell
import Quickshell.Io
import Quickshell.Wayland
import Quickshell.Hyprland
import qs.services
import qs.components

// ============================================================================
//  Wallpaper picker — Super+Alt+W. ilyamiro-inspired: a horizontal carousel of
//  SKEWED parallelogram tiles, the centered one full-size, neighbours slanted
//  and dimmed, with a floating toolbar (search) above. Applies live via swww.
//  No blur (popup).
// ============================================================================
PanelWindow {
    id: win
    visible: Panels.wallpaper

    WlrLayershell.namespace: "vexyon-wallpaper"
    WlrLayershell.layer: WlrLayer.Overlay
    // ignore the bar's exclusive zone so the dim backdrop covers the FULL screen
    // including the bar strip (otherwise the reserved zone shrinks this surface
    // and the raw wallpaper shows through un-dimmed behind the bar). Same
    // mechanism every other full-screen overlay uses (Onboarding/OSD/…).
    WlrLayershell.exclusiveZone: -1
    WlrLayershell.keyboardFocus: visible ? WlrKeyboardFocus.OnDemand : WlrKeyboardFocus.None
    color: "transparent"
    anchors { top: true; bottom: true; left: true; right: true }

    readonly property string dir: {
        var d = Config.get("behavior", "wallpaperDir", "~/Pictures/Wallpapers");
        return d.replace("~", Quickshell.env("HOME"));
    }

    // tile geometry + slant
    readonly property int tileW: 300
    readonly property int tileH: 460
    readonly property real skew: -0.18   // x-shear factor -> parallelogram lean

    property var files: []
    property string query: ""

    // Preview del fondo por defecto (PNG generado para el tema activo) — lo
    // resuelve genPrev al abrir el picker. Ruta distinta por tema+resolución,
    // así el cache de Image nunca sirve el preview de otro tema.
    property string defaultPreview: ""

    // filtered view of the file list (by filename substring). The "default"
    // sentinel tile leads the carousel; searching filters it like a file
    // named "vexyon".
    readonly property var shown: {
        var q = query.toLowerCase().trim();
        var list = ("vexyon".indexOf(q) !== -1) ? [Wallpaper.defaultId] : [];
        if (q === "") return list.concat(files);
        return list.concat(files.filter(function(p) {
            return p.substring(p.lastIndexOf("/") + 1).toLowerCase().indexOf(q) !== -1;
        }));
    }

    function refresh() { lister.running = true; genPrev.running = true; }

    // Genera (o sirve del cache) el PNG del tema activo para el preview.
    Process {
        id: genPrev
        command: ["python3", Wallpaper.genBin]
        stdout: StdioCollector {
            onStreamFinished: {
                var p = this.text.trim();
                if (p !== "") win.defaultPreview = p;
            }
        }
    }

    // apply the currently-centered wallpaper (keyboard Enter path)
    function applyCurrent() {
        var i = carousel.currentIndex;
        if (i >= 0 && i < win.shown.length) { win.apply(win.shown[i]); Panels.close("wallpaper"); }
    }

    function apply(path) {
        // Delegate to the Wallpaper service: ensures swww-daemon is up, applies
        // the user's chosen transition, and captures swww's exit/stderr (the old
        // execDetached path failed silently). Service also persists the choice.
        Wallpaper.apply(path);
    }

    Process {
        id: lister
        command: ["bash", "-c",
            "find '" + win.dir + "' -maxdepth 1 -type f \\( -iname '*.jpg' -o -iname '*.jpeg' " +
            "-o -iname '*.png' -o -iname '*.webp' -o -iname '*.bmp' \\) 2>/dev/null | sort"]
        stdout: StdioCollector {
            onStreamFinished: {
                var lines = this.text.split("\n").filter(function(l) { return l.trim() !== ""; });
                win.files = lines;
            }
        }
    }

    onVisibleChanged: if (visible) { refresh(); query = ""; }

    // ---- dim backdrop ----
    Rectangle {
        anchors.fill: parent
        color: "#000000"
        opacity: win.visible ? 0.72 : 0
        Behavior on opacity { NumberAnimation { duration: Theme.dur(180) } }
        MouseArea { anchors.fill: parent; onClicked: Panels.close("wallpaper") }
    }

    // ---- keyboard nav (arrows move, Enter applies, Esc closes) ----
    Item {
        anchors.fill: parent
        focus: win.visible
        Keys.onLeftPressed: carousel.decrementCurrentIndex()
        Keys.onRightPressed: carousel.incrementCurrentIndex()
        Keys.onEscapePressed: Panels.close("wallpaper")
        Keys.onReturnPressed: win.applyCurrent()
        Keys.onEnterPressed: win.applyCurrent()
    }

    // ---- content column: floating toolbar + carousel ----
    ColumnLayout {
        anchors.fill: parent
        anchors.topMargin: 90
        anchors.bottomMargin: 70
        spacing: 0
        opacity: win.visible ? 1 : 0
        Behavior on opacity { NumberAnimation { duration: Theme.dur(200); easing.type: Theme.easing } }

        // floating toolbar
        Card {
            Layout.alignment: Qt.AlignHCenter
            Layout.preferredWidth: 520
            Layout.preferredHeight: 48
            color: Theme.mantle
            radius: 24
            RowLayout {
                anchors.fill: parent
                anchors.leftMargin: 18
                anchors.rightMargin: 10
                spacing: 12
                Text {
                    text: Icons.image
                    color: Theme.accent
                    font.family: Theme.fontFamily
                    font.pixelSize: Theme.fontSize + 2
                }
                Text {
                    text: I18n.t("Wallpapers")
                    color: Theme.text
                    font.family: Theme.fontFamily
                    font.pixelSize: Theme.fontSize
                    font.bold: true
                }
                Rectangle { Layout.preferredWidth: 1; Layout.preferredHeight: 22; color: Theme.surface2 }
                Text {
                    text: Icons.search
                    color: Theme.subtext0
                    font.family: Theme.fontFamily
                    font.pixelSize: Theme.fontSize
                }
                TextInput {
                    id: searchInput
                    Layout.fillWidth: true
                    clip: true
                    color: Theme.text
                    font.family: Theme.fontFamily
                    font.pixelSize: Theme.fontSize
                    selectionColor: Theme.accent
                    verticalAlignment: TextInput.AlignVCenter
                    onTextChanged: win.query = text
                    Text {
                        anchors.verticalCenter: parent.verticalCenter
                        visible: searchInput.text === ""
                        text: I18n.t("Search…")
                        color: Theme.overlay1
                        font: searchInput.font
                    }
                }
                Text {
                    text: win.shown.length + (win.shown.length === 1 ? " img" : " imgs")
                    color: Theme.overlay2
                    font.family: Theme.fontFamily
                    font.pixelSize: Theme.fontSize - 3
                }
                IconButton { icon: Icons.close; onClicked: Panels.close("wallpaper") }
            }
        }

        // carousel
        ListView {
            id: carousel
            Layout.fillWidth: true
            Layout.fillHeight: true
            Layout.topMargin: 8
            orientation: ListView.Horizontal
            model: win.shown
            spacing: 4
            clip: false
            cacheBuffer: win.tileW * 6
            highlightRangeMode: ListView.StrictlyEnforceRange
            preferredHighlightBegin: width / 2 - win.tileW / 2
            preferredHighlightEnd: width / 2 + win.tileW / 2
            snapMode: ListView.SnapToItem
            boundsBehavior: Flickable.StopAtBounds
            highlightMoveDuration: Theme.dur(220)

            delegate: Item {
                id: tile
                required property int index
                required property var modelData
                readonly property string path: modelData
                readonly property bool isDefault: path === Wallpaper.defaultId
                readonly property string baseName: isDefault
                    ? "Vexyon — " + I18n.t("Theme default")
                    : path.substring(path.lastIndexOf("/") + 1)
                readonly property bool cur: ListView.isCurrentItem

                width: win.tileW
                height: carousel.height
                z: cur ? 2 : 1
                scale: cur ? 1.0 : 0.9
                opacity: cur ? 1.0 : 0.7
                Behavior on scale { NumberAnimation { duration: Theme.dur(220); easing.type: Theme.easing } }
                Behavior on opacity { NumberAnimation { duration: Theme.dur(220) } }

                // sheared frame (parallelogram)
                Item {
                    id: frame
                    anchors.centerIn: parent
                    width: win.tileW
                    height: win.tileH
                    transform: Matrix4x4 {
                        matrix: Qt.matrix4x4(1, win.skew, 0, 0,
                                             0, 1,        0, 0,
                                             0, 0,        1, 0,
                                             0, 0,        0, 1)
                    }

                    Rectangle {
                        anchors.fill: parent
                        color: Theme.surface0
                        clip: true
                        border.width: tile.cur ? 3 : 1
                        border.color: tile.cur ? Theme.accent : Theme.overlay0

                        Image {
                            anchors.fill: parent
                            anchors.margins: tile.cur ? 3 : 1
                            source: tile.isDefault
                                ? (win.defaultPreview !== "" ? "file://" + win.defaultPreview : "")
                                : "file://" + tile.path
                            fillMode: Image.PreserveAspectCrop
                            asynchronous: true
                            sourceSize.width: 520
                            cache: true
                        }
                    }
                }

                // filename label (current tile only), un-sheared
                Rectangle {
                    anchors.horizontalCenter: parent.horizontalCenter
                    anchors.bottom: parent.bottom
                    anchors.bottomMargin: (carousel.height - win.tileH) / 2 - 34
                    visible: tile.cur
                    width: label.implicitWidth + 24
                    height: 28
                    radius: 14
                    color: Theme.mantle
                    Text {
                        id: label
                        anchors.centerIn: parent
                        text: tile.baseName
                        color: Theme.text
                        font.family: Theme.fontFamily
                        font.pixelSize: Theme.fontSize - 2
                    }
                }

                MouseArea {
                    anchors.centerIn: parent
                    width: win.tileW
                    height: win.tileH
                    cursorShape: Qt.PointingHandCursor
                    onClicked: {
                        if (tile.cur) { win.apply(tile.path); Panels.close("wallpaper"); }
                        else carousel.currentIndex = tile.index;
                    }
                }
            }
        }
    }

    // empty state
    Text {
        anchors.centerIn: parent
        visible: win.visible && win.shown.length === 0
        text: I18n.t("No images in ") + win.dir + I18n.t("  —  add wallpapers there")
        color: Theme.overlay2
        font.family: Theme.fontFamily
        font.pixelSize: Theme.fontSize
    }

    HyprlandFocusGrab {
        active: win.visible
        windows: [ win ]
        onCleared: Panels.close("wallpaper")
    }
}
