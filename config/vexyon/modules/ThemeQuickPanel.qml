import QtQuick
import QtQuick.Layouts
import qs.services
import qs.components

// ============================================================================
//  ThemeQuickPanel — lightweight theme switcher (Super+Alt+T). NOT the full
//  Ajustes → Tema y colores page: a compact popup listing every installed
//  theme with a live swatch, click (or ↑/↓ + Enter) to apply instantly via the
//  same Theme.apply() the Settings page uses. Stays open after applying so the
//  user can try several; Esc closes. It's the one panel whose look changes with
//  the active theme — expected and fine.
// ============================================================================
AnchoredPanel {
    id: tq
    panelKey: "themeQuick"
    ns: "vexyon-themequick"
    panelWidth: 320
    accentColor: Theme.accent

    property int selIndex: 0
    //  Holding ↑/↓ used to lag and jump back. Three causes: every row eased its
    //  colour over 100 ms while key repeat moves every ~30 ms (the highlight was
    //  always behind); nothing scrolled the list to the selection; and with the
    //  pointer resting on the list, each row scrolled under it fired onEntered
    //  and pulled the selection back to that row. Now the selection is drawn at
    //  once, the list follows it, and only a REAL pointer move selects by hover.
    property point _lastPointer: Qt.point(-1, -1)
    function select(i) {
        var n = Theme.available.length;
        if (n === 0) return;
        tq.selIndex = Math.max(0, Math.min(n - 1, i));
    }

    onShownChanged: {
        if (shown) {
            tq._lastPointer = Qt.point(-1, -1);
            Theme.refreshThemes();
            // start the selection on the active theme
            var av = Theme.available;
            for (var i = 0; i < av.length; i++) if (av[i].id === Theme.activeId) { tq.selIndex = i; break; }
        }
    }

    content: Component {
        ColumnLayout {
            id: body
            width: tq.panelWidth - tq.contentMargin * 2
            spacing: 10
            property real introHeader: 1
            property real introContent: 1

            Component.onCompleted: keyCatcher.forceActiveFocus()

            RowLayout {
                Layout.fillWidth: true
                spacing: 10
                opacity: body.introHeader
                transform: Translate { y: 14 * (1 - body.introHeader) }
                Text { text: Icons.palette; color: tq.accentColor; font.family: Theme.fontFamily; font.pixelSize: Theme.fontSize + 4 }
                Text {
                    Layout.fillWidth: true
                    text: I18n.t("Theme"); color: Theme.text
                    font.family: Theme.fontFamily; font.pixelSize: Theme.fontSize + 2; font.bold: true
                }
            }

            ListView {
                id: list
                Layout.fillWidth: true
                Layout.preferredHeight: Math.min(Theme.available.length * 52, 380)
                opacity: body.introContent
                clip: true
                spacing: 6
                model: Theme.available
                currentIndex: tq.selIndex
                highlightFollowsCurrentItem: false
                boundsBehavior: Flickable.StopAtBounds
                // the selection always in view, without an animation to wait for
                Connections {
                    target: tq
                    function onSelIndexChanged() { list.positionViewAtIndex(tq.selIndex, ListView.Contain); }
                }

                delegate: Rectangle {
                    id: trow
                    required property int index
                    required property var modelData
                    readonly property bool isActive: modelData.id === Theme.activeId
                    readonly property bool selected: index === tq.selIndex
                    width: ListView.view.width
                    height: 46
                    radius: Theme.radius
                    color: rma.containsMouse || selected ? Theme.surface1 : Theme.surface0
                    border.width: isActive ? 2 : (selected ? 1 : 0)
                    border.color: isActive ? Theme.accent : Theme.overlay0

                    RowLayout {
                        anchors.fill: parent
                        anchors.leftMargin: 12
                        anchors.rightMargin: 12
                        spacing: 10

                        // swatch row (base / surface0 / accent)
                        Row {
                            spacing: 4
                            Repeater {
                                model: [ trow.modelData.colors.base, trow.modelData.colors.surface0, trow.modelData.colors.accent ]
                                delegate: Rectangle {
                                    required property var modelData
                                    width: 18; height: 18; radius: 5
                                    color: modelData || "#000000"
                                    border.width: 1; border.color: Qt.rgba(1, 1, 1, 0.12)
                                }
                            }
                        }
                        Text {
                            Layout.fillWidth: true
                            text: trow.modelData.name || trow.modelData.id
                            color: Theme.text
                            font.family: Theme.fontFamily; font.pixelSize: Theme.fontSize
                            font.bold: trow.isActive
                            elide: Text.ElideRight
                        }
                        Text {
                            visible: trow.isActive
                            text: Icons.check; color: Theme.accent
                            font.family: Theme.fontFamily; font.pixelSize: Theme.fontSize
                        }
                    }

                    MouseArea {
                        id: rma
                        anchors.fill: parent; hoverEnabled: true; cursorShape: Qt.PointingHandCursor
                        // a row that scrolls under a still pointer is not a choice
                        onPositionChanged: function(mouse) {
                            var g = rma.mapToGlobal(mouse.x, mouse.y);
                            if (g.x === tq._lastPointer.x && g.y === tq._lastPointer.y) return;
                            var first = tq._lastPointer.x < 0;
                            tq._lastPointer = Qt.point(g.x, g.y);
                            if (!first) tq.select(trow.index);
                        }
                        onClicked: Theme.apply(trow.modelData.id)
                    }
                }
            }

            // invisible key catcher: ↑/↓ move the selection, Enter applies, Esc closes
            Item {
                id: keyCatcher
                focus: true
                Keys.onPressed: function(event) {
                    var n = Theme.available.length;
                    if (n === 0) return;
                    // held keys stop at the ends instead of wrapping round and round
                    if (event.key === Qt.Key_Down)      { tq.select(event.isAutoRepeat ? tq.selIndex + 1 : (tq.selIndex + 1) % n); event.accepted = true; }
                    else if (event.key === Qt.Key_Up)   { tq.select(event.isAutoRepeat ? tq.selIndex - 1 : (tq.selIndex - 1 + n) % n); event.accepted = true; }
                    else if (event.key === Qt.Key_Home) { tq.select(0); event.accepted = true; }
                    else if (event.key === Qt.Key_End)  { tq.select(n - 1); event.accepted = true; }
                    else if (event.key === Qt.Key_Return || event.key === Qt.Key_Enter || event.key === Qt.Key_Space) {
                        Theme.apply(Theme.available[tq.selIndex].id); event.accepted = true;
                    } else if (event.key === Qt.Key_Escape) { tq.close(); event.accepted = true; }
                }
            }
        }
    }
}
