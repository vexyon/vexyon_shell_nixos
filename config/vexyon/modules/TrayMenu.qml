import QtQuick
import QtQuick.Effects
import Quickshell
import Quickshell.Wayland
import Quickshell.Hyprland
import Quickshell.Widgets
import qs.services

// ============================================================================
//  TrayMenu — themed renderer for a system-tray item's OWN DBusMenu. Opened by
//  right-clicking a tray icon (Panels.openTrayMenu records the item's menu
//  handle + where to hang the card). We do NOT build a hardcoded menu: a
//  QsMenuOpener walks the app's real menu and we draw whatever it exposes —
//  labels, separators, disabled items, checkboxes/radios, icons and submenus.
//  Selecting an entry calls entry.triggered(), which sends the DBusMenu event
//  the app defined (so its "Quit" really quits, etc.).
//
//  Submenus use a level stack: the root card is always shown; hovering a row
//  with children pushes its handle into `subs`, and a new card flies out beside
//  it. Styling follows the bar's theme tokens.
// ============================================================================
PanelWindow {
    id: win

    readonly property bool shown: Panels.trayMenu === true
    function close() { Panels.closeTrayMenu() }

    // submenu handles beyond the root (subs[0] = level 1, subs[1] = level 2, …)
    property var subs: []
    onShownChanged: subs = []

    // parentLevel: level of the card the row lives in (0 = root). The child
    // opens as level parentLevel+1, replacing any deeper levels.
    function openChild(parentLevel, handle) {
        win.subs = win.subs.slice(0, parentLevel).concat([handle]);
    }
    function collapseBelow(parentLevel) {
        if (win.subs.length > parentLevel) win.subs = win.subs.slice(0, parentLevel);
    }

    screen: {
        var scs = Quickshell.screens;
        for (var i = 0; i < scs.length; i++)
            if (scs[i].name === Panels.trayMenuScreen) return scs[i];
        return scs.length > 0 ? scs[0] : null;
    }

    visible: win.shown
    WlrLayershell.namespace: "vexyon-traymenu"
    WlrLayershell.layer: WlrLayer.Overlay
    WlrLayershell.exclusiveZone: -1
    WlrLayershell.keyboardFocus: WlrKeyboardFocus.None
    color: "transparent"
    anchors { top: true; bottom: true; left: true; right: true }

    // mismo hueco barra→card que AnchoredPanel (regla DMS: max(4, edgeGap));
    // trayMenuEdge ya es el borde visual de la barra (Panels.stripEdge)
    readonly property real gap: Math.max(4, Theme.barMarginTop)
    readonly property bool bottomBar: Panels.trayMenuBarPos === "bottom"
    readonly property bool sideBar: Panels.trayMenuBarPos === "left" || Panels.trayMenuBarPos === "right"
    readonly property bool rightBar: Panels.trayMenuBarPos === "right"

    // click-away dismiss
    MouseArea {
        anchors.fill: parent
        acceptedButtons: Qt.LeftButton | Qt.RightButton
        onClicked: win.close()
    }

    // ---- one menu column (root or a submenu level) ------------------------
    component MenuCard: Rectangle {
        id: card
        property var handle          // qs::menu::QsMenuHandle for this level
        property int level: 0

        width: Math.max(170, Math.min(340, col.implicitWidth + 12))
        height: col.implicitHeight + 10
        radius: Theme.radius + 2
        color: Theme.base
        border.width: 1
        border.color: Theme.surface0

        opacity: 0
        scale: 0.97
        Component.onCompleted: { opacity = 1; scale = 1; }
        Behavior on opacity { NumberAnimation { duration: Theme.dur(110) } }
        Behavior on scale { NumberAnimation { duration: Theme.dur(110); easing.type: Easing.OutCubic } }

        layer.enabled: Theme.elevation
        layer.effect: MultiEffect {
            shadowEnabled: true
            shadowColor: Qt.rgba(0, 0, 0, 0.5)
            shadowBlur: 0.5
            shadowVerticalOffset: 4
            autoPaddingEnabled: true
        }

        QsMenuOpener {
            id: opener
            menu: card.handle
        }

        Column {
            id: col
            x: 6; y: 5
            width: card.width - 12
            spacing: 1

            Repeater {
                model: opener.children ? opener.children.values : []
                delegate: Item {
                    id: rowItem
                    required property var modelData     // QsMenuEntry
                    readonly property bool sep: modelData && modelData.isSeparator === true
                    readonly property bool dis: modelData && modelData.enabled === false
                    readonly property bool hasKids: modelData && modelData.hasChildren === true
                    width: col.width
                    height: sep ? 9 : 28

                    // separator
                    Rectangle {
                        visible: rowItem.sep
                        anchors.verticalCenter: parent.verticalCenter
                        anchors.left: parent.left; anchors.right: parent.right
                        anchors.leftMargin: 6; anchors.rightMargin: 6
                        height: 1
                        color: Theme.surface2
                    }

                    // row body
                    Rectangle {
                        visible: !rowItem.sep
                        anchors.fill: parent
                        radius: Theme.radius
                        color: (rowMa.containsMouse && !rowItem.dis) ? Theme.surface1 : "transparent"

                        Row {
                            anchors.left: parent.left; anchors.right: parent.right
                            anchors.verticalCenter: parent.verticalCenter
                            anchors.leftMargin: 8; anchors.rightMargin: 8
                            spacing: 8

                            // checkbox (buttonType 1) / radio (buttonType 2)
                            Rectangle {
                                anchors.verticalCenter: parent.verticalCenter
                                visible: rowItem.modelData && rowItem.modelData.buttonType !== undefined
                                         && rowItem.modelData.buttonType !== 0
                                width: 15; height: 15
                                radius: rowItem.modelData && rowItem.modelData.buttonType === 2 ? 8 : 3
                                border.width: 1
                                border.color: Theme.overlay1
                                color: "transparent"
                                Rectangle {
                                    anchors.centerIn: parent
                                    width: 9; height: 9
                                    radius: parent.radius - 2
                                    color: Theme.accent
                                    visible: rowItem.modelData && rowItem.modelData.checkState === 2
                                }
                            }

                            // app-provided icon (not themeable)
                            IconImage {
                                anchors.verticalCenter: parent.verticalCenter
                                visible: (rowItem.modelData && rowItem.modelData.icon || "") !== ""
                                width: 16; height: 16
                                source: rowItem.modelData ? rowItem.modelData.icon : ""
                            }

                            Text {
                                anchors.verticalCenter: parent.verticalCenter
                                width: parent.width - x - (kidArrow.visible ? 18 : 0)
                                text: rowItem.modelData ? rowItem.modelData.text : ""
                                color: rowItem.dis ? Theme.overlay1 : Theme.text
                                font.family: Theme.fontFamily
                                font.pixelSize: Theme.fontSize - 1
                                elide: Text.ElideRight
                            }

                            Text {
                                id: kidArrow
                                anchors.verticalCenter: parent.verticalCenter
                                visible: rowItem.hasKids
                                text: Icons.chevronRight
                                color: Theme.subtext0
                                font.family: Theme.fontFamily
                                font.pixelSize: Theme.fontSize - 2
                            }
                        }

                        MouseArea {
                            id: rowMa
                            anchors.fill: parent
                            hoverEnabled: true
                            enabled: !rowItem.dis
                            cursorShape: Qt.PointingHandCursor
                            onEntered: {
                                if (rowItem.hasKids)
                                    win.openChild(card.level, rowItem.modelData.menu || rowItem.modelData);
                                else
                                    win.collapseBelow(card.level);
                            }
                            onClicked: {
                                if (rowItem.hasKids) return;   // submenus open on hover
                                if (rowItem.modelData && typeof rowItem.modelData.triggered === "function")
                                    rowItem.modelData.triggered();
                                win.close();
                            }
                        }
                    }
                }
            }
        }
    }

    // root level anchored to the icon; submenu levels fly out to the side
    Row {
        id: levelRow
        spacing: 2

        readonly property real baseX: {
            if (win.sideBar)
                return win.rightBar ? Panels.trayMenuEdge - implicitWidth - win.gap
                                    : Panels.trayMenuEdge + win.gap;
            return Math.max(win.gap, Math.min(win.width - implicitWidth - win.gap, Panels.trayMenuX));
        }
        readonly property real baseY: {
            if (win.sideBar)
                return Math.max(win.gap, Math.min(win.height - implicitHeight - win.gap, Panels.trayMenuX));
            return win.bottomBar ? Panels.trayMenuEdge - implicitHeight - win.gap
                                 : Panels.trayMenuEdge + win.gap;
        }
        x: baseX
        y: baseY

        MenuCard { handle: Panels.trayMenuHandle; level: 0 }
        Repeater {
            model: win.subs
            delegate: MenuCard {
                required property int index
                required property var modelData
                handle: modelData
                level: index + 1
            }
        }
    }

    HyprlandFocusGrab {
        active: win.shown
        windows: [ win ].concat(Panels.barWindows)
        onCleared: win.close()
    }
}
