import QtQuick
import QtQuick.Layouts
import Quickshell
import Quickshell.Wayland
import qs.services
import qs.components

// ============================================================================
//  Calculator — Super+Shift+C. Basic arithmetic only: + − × ÷, decimals and
//  brackets, typed or clicked.
//
//  Lives behind a LazyLoader in shell.qml (active = Panels.calculator): while
//  closed there is no window and no object at all. Opens on the FOCUSED
//  monitor via Panels.openScreen, which Panels.toggle/open fix AT OPEN TIME —
//  the same mechanism as the launcher and power menu, not a binding to
//  focusedScreen().
//
//  Keyboard: digits . + - * / ( ) — Enter or = evaluates, Backspace deletes,
//  Delete clears, Esc closes. Click outside also closes.
//  The expression is evaluated by a small recursive-descent parser below,
//  never by eval(): typed text is data, not code.
// ============================================================================
PanelWindow {
    id: win
    screen: Panels.openScreen
    WlrLayershell.namespace: "vexyon-calculator"
    WlrLayershell.layer: WlrLayer.Overlay
    WlrLayershell.keyboardFocus: WlrKeyboardFocus.Exclusive
    color: "transparent"
    anchors { top: true; bottom: true; left: true; right: true }

    property string expr: ""          // what is being typed (display symbols)
    property string history: ""       // last evaluated expression, "12 × 3 ="
    property string error: ""
    property bool justEvaluated: false
    property bool shown: false
    Component.onCompleted: { shown = true; keyScope.forceActiveFocus(); }

    readonly property var ops: ["+", "−", "×", "÷"]
    function isOp(c) { return ops.indexOf(c) !== -1; }

    // ---- input ---------------------------------------------------------
    function input(c) {
        win.error = "";
        if (win.expr.length >= 64) return;
        var last = win.expr.slice(-1);
        if (win.isOp(c)) {
            if (win.justEvaluated) win.justEvaluated = false;      // keep going from the result
            if (win.expr === "" || last === "(") {
                if (c === "−") win.expr += c;                      // leading / bracketed negative
                return;
            }
            // two operators in a row: the new one replaces the old, except
            // a minus after × or ÷ (3 × −2)
            if (win.isOp(last)) {
                if (c === "−" && (last === "×" || last === "÷")) { win.expr += c; return; }
                win.expr = win.expr.slice(0, -1);
                if (win.isOp(win.expr.slice(-1))) win.expr = win.expr.slice(0, -1);
            }
            win.expr += c;
            return;
        }
        if (win.justEvaluated) { win.expr = ""; win.justEvaluated = false; }   // a digit starts afresh
        last = win.expr.slice(-1);
        if (last === ")" && c !== ")") return;                       // "(2)3" is not a thing
        if (c === ".") {
            var m = win.expr.match(/[0-9.]*$/);
            if (m && m[0].indexOf(".") !== -1) return;              // one point per number
            if (m === null || m[0] === "") c = "0.";
        } else if (c === ")") {
            var open = (win.expr.match(/\(/g) || []).length - (win.expr.match(/\)/g) || []).length;
            if (open <= 0 || win.isOp(last) || last === "(") return;
        } else if (c === "(") {
            if (/[0-9.)]/.test(last)) return;                       // no implicit ×
        }
        win.expr += c;
    }
    function backspace() { win.error = ""; win.justEvaluated = false; win.expr = win.expr.slice(0, -1); }
    function clear() { win.error = ""; win.expr = ""; win.history = ""; win.justEvaluated = false; }

    // ---- evaluation ------------------------------------------------------
    // expr := term (('+'|'-') term)* ; term := factor (('*'|'/') factor)* ;
    // factor := ('+'|'-') factor | '(' expr ')' | number
    function evaluate(s) {
        var t = s.replace(/×/g, "*").replace(/÷/g, "/").replace(/−/g, "-");
        var i = 0;
        function peek() { return t.charAt(i); }
        function number() {
            var m = /^[0-9]*\.?[0-9]+|^[0-9]+\.?/.exec(t.substring(i));
            if (!m) throw "syntax";
            i += m[0].length;
            return parseFloat(m[0]);
        }
        function factor() {
            var c = peek();
            if (c === "-") { i++; return -factor(); }
            if (c === "+") { i++; return factor(); }
            if (c === "(") {
                i++;
                var v = sum();
                if (peek() !== ")") throw "syntax";
                i++;
                return v;
            }
            return number();
        }
        function product() {
            var v = factor();
            for (;;) {
                var c = peek();
                if (c === "*") { i++; v *= factor(); }
                else if (c === "/") { i++; var d = factor(); if (d === 0) throw "div0"; v /= d; }
                else return v;
            }
        }
        function sum() {
            var v = product();
            for (;;) {
                var c = peek();
                if (c === "+") { i++; v += product(); }
                else if (c === "-") { i++; v -= product(); }
                else return v;
            }
        }
        var r = sum();
        if (i < t.length || !isFinite(r)) throw "syntax";
        return r;
    }
    function format(v) {
        var s = String(Number(v.toPrecision(12)));      // 0.1 + 0.2 -> 0.3
        return s.replace("-", "−");
    }
    // unclosed brackets are closed for you, a trailing operator is ignored
    function withClosedBrackets(s) {
        while (s !== "" && win.isOp(s.slice(-1))) s = s.slice(0, -1);
        var open = (s.match(/\(/g) || []).length - (s.match(/\)/g) || []).length;
        for (var k = 0; k < open; k++) s += ")";
        return s;
    }
    // live result under the expression while typing ("" if not computable yet)
    readonly property string preview: {
        if (win.justEvaluated || win.expr === "" || !/[+−×÷]/.test(win.expr.replace(/^−/, ""))) return "";
        try { return win.format(win.evaluate(win.withClosedBrackets(win.expr))); } catch (e) { return ""; }
    }
    function equals() {
        if (win.expr === "" || win.justEvaluated) return;
        var s = win.withClosedBrackets(win.expr);
        try {
            var r = win.format(win.evaluate(s));
            win.history = s + " =";
            win.expr = r;
            win.justEvaluated = true;
            win.error = "";
        } catch (e) {
            win.error = e === "div0" ? I18n.t("Can't divide by zero") : I18n.t("Invalid expression");
        }
    }

    // ---- surface -----------------------------------------------------------
    Rectangle {
        anchors.fill: parent
        color: Qt.rgba(0, 0, 0, 0.35)
        opacity: win.shown ? 1 : 0
        Behavior on opacity { NumberAnimation { duration: Theme.dur(140) } }
        MouseArea { anchors.fill: parent; onClicked: Panels.close("calculator") }
    }

    FocusScope {
        id: keyScope
        anchors.fill: parent
        focus: true
        Keys.onPressed: function(e) {
            var tx = e.text;
            if (e.key === Qt.Key_Escape) Panels.close("calculator");
            else if (e.key === Qt.Key_Return || e.key === Qt.Key_Enter || tx === "=") win.equals();
            else if (e.key === Qt.Key_Backspace) win.backspace();
            else if (e.key === Qt.Key_Delete) win.clear();
            else if (/^[0-9]$/.test(tx) || tx === "(" || tx === ")") win.input(tx);
            else if (tx === "." || tx === ",") win.input(".");
            else if (tx === "+") win.input("+");
            else if (tx === "-") win.input("−");
            else if (tx === "*" || tx === "x" || tx === "X") win.input("×");
            else if (tx === "/") win.input("÷");
            else return;
            e.accepted = true;
        }

        Card {
            id: card
            anchors.centerIn: parent
            width: 320
            height: col.implicitHeight + 32
            opacity: win.shown ? 1 : 0
            scale: win.shown ? 1 : 0.94
            Behavior on opacity { NumberAnimation { duration: Theme.dur(160); easing.type: Theme.easing } }
            Behavior on scale { NumberAnimation { duration: Theme.dur(160); easing.type: Theme.easing } }
            // clicks on the card must not reach the close-on-outside backdrop
            MouseArea { anchors.fill: parent }

            ColumnLayout {
                id: col
                anchors.left: parent.left
                anchors.right: parent.right
                anchors.top: parent.top
                anchors.margins: 16
                spacing: 12

                RowLayout {
                    Layout.fillWidth: true
                    Text {
                        Layout.fillWidth: true
                        text: I18n.t("Calculator")
                        color: Theme.text
                        font.family: Theme.fontFamily
                        font.pixelSize: Theme.fontSize + 1
                        font.bold: true
                    }
                    IconButton {
                        icon: Icons.close
                        iconColor: Theme.subtext0
                        iconSize: Theme.fontSize - 1
                        implicitWidth: 26; implicitHeight: 26
                        onClicked: Panels.close("calculator")
                    }
                }

                // display: history / expression / live result or error
                Rectangle {
                    Layout.fillWidth: true
                    Layout.preferredHeight: 96
                    radius: Theme.radius
                    color: Theme.mantle
                    border.width: 1
                    border.color: Qt.rgba(Theme.overlay0.r, Theme.overlay0.g, Theme.overlay0.b, 0.5)
                    ColumnLayout {
                        anchors.fill: parent
                        anchors.margins: 12
                        spacing: 2
                        Text {
                            Layout.fillWidth: true
                            horizontalAlignment: Text.AlignRight
                            elide: Text.ElideLeft
                            text: win.history
                            color: Theme.overlay2
                            font.family: Theme.fontFamily
                            font.pixelSize: Theme.fontSize - 2
                        }
                        Text {
                            Layout.fillWidth: true
                            Layout.fillHeight: true
                            horizontalAlignment: Text.AlignRight
                            verticalAlignment: Text.AlignVCenter
                            elide: Text.ElideLeft
                            text: win.expr === "" ? "0" : win.expr
                            color: win.justEvaluated ? Theme.accentFg : Theme.text
                            font.family: Theme.fontFamily
                            font.pixelSize: Theme.fontSize + 13
                            font.bold: win.justEvaluated
                        }
                        Text {
                            Layout.fillWidth: true
                            horizontalAlignment: Text.AlignRight
                            elide: Text.ElideLeft
                            text: win.error !== "" ? win.error : (win.preview !== "" ? "= " + win.preview : " ")
                            color: win.error !== "" ? Theme.red : Theme.subtext0
                            font.family: Theme.fontFamily
                            font.pixelSize: Theme.fontSize - 2
                        }
                    }
                }

                GridLayout {
                    Layout.fillWidth: true
                    columns: 4
                    rowSpacing: 8
                    columnSpacing: 8
                    Repeater {
                        model: ["C", "(", ")", "÷",
                                "7", "8", "9", "×",
                                "4", "5", "6", "−",
                                "1", "2", "3", "+",
                                "⌫", "0", ".", "="]
                        delegate: Rectangle {
                            id: key
                            required property string modelData
                            readonly property bool op: win.isOp(modelData) || modelData === "(" || modelData === ")"
                            readonly property bool eq: modelData === "="
                            readonly property bool fn: modelData === "C" || modelData === "⌫"
                            Layout.fillWidth: true
                            Layout.preferredHeight: 48
                            radius: Theme.radius
                            color: eq ? (keyMa.containsMouse ? Theme.accent2 : Theme.accent)
                                 : keyMa.pressed ? Theme.surface2
                                 : keyMa.containsMouse ? Theme.surface2
                                 : op || fn ? Theme.surface1 : Theme.surface0
                            border.width: eq ? 0 : 1
                            border.color: Qt.rgba(Theme.overlay0.r, Theme.overlay0.g, Theme.overlay0.b, 0.45)
                            scale: keyMa.pressed ? 0.95 : 1
                            Behavior on color { ColorAnimation { duration: Theme.dur(100) } }
                            Behavior on scale { NumberAnimation { duration: Theme.dur(80) } }
                            Text {
                                anchors.centerIn: parent
                                text: key.modelData
                                color: key.eq ? Theme.onAccent
                                     : key.modelData === "C" ? Theme.red
                                     : key.op ? Theme.accentFg : Theme.text
                                font.family: Theme.fontFamily
                                font.pixelSize: Theme.fontSize + 4
                                font.bold: key.eq || key.op
                            }
                            MouseArea {
                                id: keyMa
                                anchors.fill: parent
                                hoverEnabled: true
                                cursorShape: Qt.PointingHandCursor
                                onClicked: {
                                    var k = key.modelData;
                                    if (k === "=") win.equals();
                                    else if (k === "C") win.clear();
                                    else if (k === "⌫") win.backspace();
                                    else win.input(k);
                                    keyScope.forceActiveFocus();
                                }
                            }
                        }
                    }
                }
            }
        }
    }
}
