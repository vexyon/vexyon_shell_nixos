import QtQuick
import qs.services

// ============================================================================
//  FolderGlyph — a File Manager item glyph (folder or file type), with the
//  folder's symbol composited on the folder body when it has one
//  (FolderIcons.emblemFor). Drop-in for the plain Text it replaces: same font,
//  colour and size, so no layout moves.
//
//  The symbol takes its colour from the theme (FolderIcons.inkOn: onAccent,
//  or base/text when that would not contrast with the folder colour), so it
//  stays readable on dark and light themes and with any accent, and re-tints
//  live with the rest of the shell. A custom image sits on a small disc of the
//  theme's base colour for the same reason.
// ============================================================================
Item {
    id: root

    property string glyph: ""
    property color glyphColor: Theme.accent
    property real pixelSize: Theme.fontSize
    property var emblem: null                    // { glyph } | { image } | null
    property int horizontalAlignment: Text.AlignLeft
    //  Centre the glyph's INK in the item (the folder glyph is wider than its
    //  advance, so plain centring leans right). For standalone previews.
    property bool inkCentered: false

    implicitWidth: base.implicitWidth
    implicitHeight: base.implicitHeight

    Text {
        id: base
        x: root.inkCentered ? root.width / 2 - (root.ink.x + root.ink.w / 2) * root.pixelSize : 0
        width: root.inkCentered ? implicitWidth : root.width
        height: root.height
        text: root.glyph
        color: root.glyphColor
        font.family: Theme.fontFamily
        font.pixelSize: root.pixelSize
        horizontalAlignment: root.inkCentered ? Text.AlignLeft : root.horizontalAlignment
    }

    // ---- the folder body, from the measured ink of the folder glyph ----------
    readonly property var ink: FolderIcons.folderInk
    readonly property real _ox: root.inkCentered ? base.x
                                : root.horizontalAlignment === Text.AlignHCenter
                                ? (root.width - root.ink.adv * root.pixelSize) / 2 : 0
    readonly property real _bx: root._ox + root.ink.x * root.pixelSize
    readonly property real _by: root.ink.y * root.pixelSize
    readonly property real _bw: root.ink.w * root.pixelSize
    readonly property real _bh: root.ink.h * root.pixelSize
    //  Centre of the front panel: below the tab, a little under the middle.
    readonly property real _cx: root._bx + root._bw / 2
    readonly property real _cy: root._by + root._bh * 0.58
    //  A bit larger at list/sidebar sizes, where every pixel of symbol counts.
    readonly property real _s: Math.max(7, root._bh * (0.52 + Math.max(0, 28 - root.pixelSize) * 0.008))

    Text {
        visible: root.emblem !== null && root.emblem.glyph !== undefined
        x: root._cx - width / 2
        y: root._cy - height / 2
        width: root._s
        height: root._s
        horizontalAlignment: Text.AlignHCenter
        verticalAlignment: Text.AlignVCenter
        text: visible ? root.emblem.glyph : ""
        color: FolderIcons.inkOn(root.glyphColor)
        font.family: FolderIcons.symbolFont
        font.pixelSize: Math.round(root._s)
    }

    Rectangle {
        visible: root.emblem !== null && root.emblem.image !== undefined
        width: Math.round(root._s * 1.18)
        height: width
        radius: width / 2
        x: root._cx - width / 2
        y: root._cy - height / 2
        color: Qt.alpha(Theme.base, 0.92)
        border.width: 1
        border.color: Qt.alpha(Theme.text, 0.18)
        Image {
            anchors.centerIn: parent
            width: Math.round(parent.width * 0.74)
            height: width
            source: parent.visible ? root.emblem.image : ""
            sourceSize.width: width
            sourceSize.height: height
            fillMode: Image.PreserveAspectFit
            asynchronous: true
            smooth: true
            mipmap: true
        }
    }
}
