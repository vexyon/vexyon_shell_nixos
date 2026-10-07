import QtQuick

// Concave (inverted) corner: a size×size square filled with `color` except
// for a quarter disc, so a flush bar melts into the screen edge. Plain
// Rectangle border trick (no Canvas, no Shapes): a transparent rounded rect
// whose INNER edge is the arc, clipped to the square. Painted once by the
// scene graph like any other Rectangle.
//
// The filled corner is the top-left one; `rotation` 90/180/270 moves it to
// top-right/bottom-right/bottom-left (multiples of 90 keep the clip a
// scissor rect).
Item {
    id: cc
    property int size: 12
    property color color: "black"

    width: size
    height: size
    clip: true

    Rectangle {
        // inner radius (radius - border) = size, centred on the far corner
        x: -cc.size
        y: -cc.size
        width: cc.size * 4
        height: cc.size * 4
        radius: cc.size * 2
        color: "transparent"
        border.width: cc.size
        border.color: cc.color
    }
}
