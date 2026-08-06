import QtQuick
import QtQuick.Controls
import QtQuick.Layouts
import Quickshell
import Quickshell.Io
import Quickshell.Wayland
import Quickshell.Services.Greetd

// ============================================================================
//  Vexyon Greeter — greetd greeter as a standalone Quickshell config.
//
//  Runs BEFORE any user session exists: launched by greetd as the `greeter`
//  user inside a minimal kiosk Hyprland (see hyprland-greeter.lua). It must
//  not depend on the logged-in user's config/bridge — theme and default user
//  come from static snapshots in /etc/greetd/vexyon-greeter/ written by
//  install.sh (re-sync any time with `vexyon-greeter-sync-theme`).
//
//  Visual language mirrors the lock screen (modules/LockScreen.qml): gradient
//  over orbiting colour blobs + faint rings, big idle clock that gives way to
//  avatar + animated password pill on input, bottom pills (session selector,
//  hostname), corner power menu.
//
//  Auth flow (Quickshell.Services.Greetd):
//    createSession(user) → authMessage(responseRequired) → respond(password)
//    → readyToLaunch → launch(session Exec, env, quit=true) → qs exits →
//    hyprland-greeter.lua wrapper exits the kiosk compositor → greetd starts
//    the real session.
// ============================================================================
ShellRoot {
    id: root

    // Snapshots MUTABLES (theme.json, greeter.json). En Arch conviven con el
    // código en /etc/greetd/vexyon-greeter; en NixOS el código vive en el store
    // (solo lectura) y el estado en /var/lib/vexyon-greeter, así que la ruta
    // llega por entorno. El valor por defecto es el de Arch: sin la variable,
    // el comportamiento es idéntico al de siempre.
    readonly property string cfgDir: {
        var d = Quickshell.env("VEXYON_GREETER_STATE_DIR");
        return (d && d !== "") ? d : "/etc/greetd/vexyon-greeter";
    }

    // ---- theme: embedded crimson-voltage fallback + static snapshot --------
    property var pal: ({
        "base": "#0d0d12", "mantle": "#0a0a0e", "crust": "#070709",
        "text": "#ececf2", "subtext0": "#9a9aae", "subtext1": "#c4c4d2",
        "surface0": "#16161e", "surface1": "#20202c", "surface2": "#2c2c3a",
        "overlay0": "#3a3a4c", "overlay1": "#50505f", "overlay2": "#6e6e82",
        "accent": "#e11d48", "accent2": "#fb7185", "onAccent": "#ffffff",
        "red": "#ff5470", "green": "#4ade80", "yellow": "#fbbf24",
        "blue": "#60a5fa", "peach": "#fb923c", "mauve": "#c084fc",
        "teal": "#2dd4bf", "pink": "#f472b6"
    })
    // Qt.color: los tokens llegan como string hex; los consumidores usan .r/.g/.b
    function pc(name) { return Qt.color(root.pal[name] || "#ff00ff"); }
    readonly property string fontFamily: "JetBrainsMono Nerd Font"

    // ---- i18n: English default, snapshot-driven like the theme --------------
    // El greeter corre como el usuario `greeter` ANTES de la sesión: no puede
    // leer el shell.json del usuario ni el I18n del shell. install.sh y
    // vexyon-greeter-sync-theme copian appearance.language a greeter.json
    // ("lang"); aquí solo hace falta el puñado de cadenas propias del greeter,
    // con las MISMAS claves/traducciones que services/I18n.qml.
    property string lang: "en"
    readonly property var _es: ({
        "Enter your password": "Introduce la contraseña",
        "Verifying…": "Verificando…",
        "Wrong password": "Contraseña incorrecta",
        "Restart": "Reiniciar",
        "Power Off": "Apagar",
        "greetd unavailable (GREETD_SOCK?)": "greetd no disponible (GREETD_SOCK?)",
        "greetd error": "Error de greetd"
    })
    function t(s) { return root.lang === "es" && root._es[s] ? root._es[s] : s; }

    FileView {
        path: root.cfgDir + "/theme.json"
        onLoaded: {
            try {
                var j = JSON.parse(text());
                if (j && j.colors) {
                    var merged = {};
                    for (var k in root.pal) merged[k] = root.pal[k];
                    for (var c in j.colors) merged[c] = j.colors[c];
                    root.pal = merged;
                }
            } catch (e) { console.warn("[GREET] theme.json parse failed:", e); }
        }
    }

    // ---- greeter.json: default user + language (seeded by install.sh) ------
    property string defaultUser: ""
    FileView {
        path: root.cfgDir + "/greeter.json"
        onLoaded: {
            try {
                var j = JSON.parse(text());
                if (j && j.user) root.defaultUser = j.user;
                if (j && j.lang === "es") root.lang = "es";
            } catch (e) { console.warn("[GREET] greeter.json parse failed:", e); }
        }
    }

    // ---- wayland sessions --------------------------------------------------
    //  sessions = [{ name, exec }]; sessionIdx cycles via the bottom pill.
    //  Los .desktop de sesión están en /usr/share en Arch y en
    //  /run/current-system/sw/share en NixOS; XDG_DATA_DIRS (dos puntos como
    //  separador) cubre además perfiles y home-manager. Se recorren todos y el
    //  resultado va por `sort -u`, así que una ruta repetida no duplica la
    //  entrada en el selector y un directorio inexistente simplemente no casa.
    property var sessions: []
    property int sessionIdx: 0
    readonly property var session: sessions.length > 0 ? sessions[Math.min(sessionIdx, sessions.length - 1)] : null
    Process {
        id: sessionScan
        running: true
        command: ["sh", "-c",
            "IFS=:; set -f; " +
            "for d in ${XDG_DATA_DIRS:-/usr/share} /usr/share /run/current-system/sw/share; do " +
            "  set +f; unset IFS; " +
            "  for f in \"$d\"/wayland-sessions/*.desktop; do " +
            "    [ -f \"$f\" ] || continue; " +
            "    n=$(grep -m1 '^Name=' \"$f\" | cut -d= -f2-); " +
            "    e=$(grep -m1 '^Exec=' \"$f\" | cut -d= -f2-); " +
            "    [ -n \"$e\" ] && printf '%s\\t%s\\n' \"${n:-$e}\" \"$e\"; " +
            "  done; " +
            "  IFS=:; set -f; " +
            "done | sort -u"]
        stdout: StdioCollector {
            onStreamFinished: {
                var out = [];
                var lines = this.text.trim().split("\n");
                for (var i = 0; i < lines.length; i++) {
                    var p = lines[i].split("\t");
                    if (p.length === 2 && p[1] !== "")
                        out.push({ name: p[0], exec: p[1] });
                }
                root.sessions = out;
                // prefer Vexyon (vexyon-start wrapper), else plain Hyprland
                var pick = -1;
                for (var s = 0; s < out.length; s++) {
                    var n = out[s].name.toLowerCase();
                    if (n === "vexyon") { pick = s; break; }
                    if (pick < 0 && n === "hyprland") pick = s;
                }
                if (pick >= 0) root.sessionIdx = pick;
                console.log("[GREET] sessions:", JSON.stringify(out));
            }
        }
    }

    // ---- hostname (env HOSTNAME no existe fuera de shells interactivas) ----
    property string hostname: "linux"
    FileView {
        path: "/etc/hostname"
        onLoaded: { var t = text().trim(); if (t !== "") root.hostname = t; }
    }

    // ---- clock --------------------------------------------------------------
    property string timeStr: ""
    property string dateStr: ""
    Timer {
        interval: 1000; running: true; repeat: true; triggeredOnStart: true
        onTriggered: {
            var d = new Date();
            root.timeStr = Qt.formatDateTime(d, "HH:mm");
            // fecha con el idioma del greeter, no el locale del sistema
            root.dateStr = d.toLocaleDateString(Qt.locale(root.lang === "es" ? "es_ES" : "en_US"), "ddd d MMM");
        }
    }

    // ---- auth state ----------------------------------------------------------
    property bool busy: false
    property string errorText: ""
    property string pendingPw: ""

    function attempt(user, pw) {
        if (root.busy || user === "" || pw === "") return;
        if (!Greetd.available) {
            root.errorText = root.t("greetd unavailable (GREETD_SOCK?)");
            return;
        }
        console.log("[GREET] createSession user=" + user);
        root.busy = true;
        root.errorText = "";
        root.pendingPw = pw;
        Greetd.createSession(user);
    }

    Connections {
        target: Greetd
        function onAuthMessage(message, error, responseRequired, echoResponse) {
            console.log("[GREET] authMessage '" + message + "' error=" + error
                        + " responseRequired=" + responseRequired + " echo=" + echoResponse);
            if (responseRequired) {
                // password prompt (echo off) — answer with the typed password
                Greetd.respond(root.pendingPw);
            }
        }
        function onAuthFailure(message) {
            console.log("[GREET] authFailure: " + message);
            root.busy = false;
            root.pendingPw = "";
            root.errorText = root.t("Wrong password");
        }
        function onReadyToLaunch() {
            var s = root.session;
            var exec = s ? s.exec : "Hyprland";
            console.log("[GREET] readyToLaunch → " + exec);
            // greetd une la lista con espacios y la ejecuta bajo SU `sh -lc`
            // (source_profile) — pasar el Exec del .desktop tal cual. NO
            // envolverlo en otro /bin/sh: el sh interior recibiría solo la
            // primera palabra como script ("exec" a secas sale con éxito al
            // instante → la sesión se abría y cerraba en el mismo segundo).
            Greetd.launch([exec],
                          ["XDG_SESSION_TYPE=wayland",
                           "XDG_CURRENT_DESKTOP=Hyprland",
                           "XDG_SESSION_DESKTOP=hyprland"],
                          true);
        }
        function onError(error) {
            console.log("[GREET] error: " + error);
            root.busy = false;
            root.pendingPw = "";
            root.errorText = root.t("greetd error");
        }
    }

    // ============================ UI ==========================================
    Variants {
        model: Quickshell.screens

        PanelWindow {
            id: win
            required property var modelData
            screen: modelData
            readonly property bool primary: {
                var scs = Quickshell.screens;
                return scs.length === 0 || scs[0] === win.modelData;
            }

            WlrLayershell.namespace: "vexyon-greeter"
            WlrLayershell.layer: WlrLayer.Top
            WlrLayershell.keyboardFocus: WlrKeyboardFocus.Exclusive
            anchors { top: true; bottom: true; left: true; right: true }
            exclusionMode: ExclusionMode.Ignore
            color: root.pc("crust")

            // ui state: false = clock face, true = auth revealed
            property bool inputActive: false
            readonly property bool authenticating: root.busy
            readonly property bool failed: root.errorText !== ""
            readonly property string statusText:
                failed ? root.errorText
                       : authenticating ? root.t("Verifying…")
                       : inputActive ? root.t("Enter your password")
                       : "Vexyon"

            function refocus() { pwField.forceActiveFocus(); }

            MouseArea {
                anchors.fill: parent
                acceptedButtons: Qt.LeftButton | Qt.RightButton
                onPressed: function(m) {
                    win.inputActive = true;
                    win.refocus();
                    m.accepted = false;
                }
            }

            // the layer surface takes a moment to map; retry focus like the lock
            Timer {
                interval: 60; repeat: true; running: win.primary
                property int tries: 0
                onTriggered: {
                    win.refocus();
                    if (pwField.activeFocus || ++tries > 16) running = false;
                }
            }

            // ---- background: gradient + orbiting blobs + faint rings --------
            Rectangle {
                anchors.fill: parent
                gradient: Gradient {
                    GradientStop { position: 0.0; color: root.pc("mantle") }
                    GradientStop { position: 1.0; color: root.pc("crust") }
                }
            }

            Item {
                anchors.fill: parent
                property real ang: 0
                NumberAnimation on ang {
                    from: 0; to: Math.PI * 2; duration: 90000
                    loops: Animation.Infinite; running: true
                }
                Rectangle {
                    width: parent.width * 0.8; height: width; radius: width / 2
                    x: (parent.width / 2 - width / 2) + Math.cos(parent.ang * 2) * 200
                    y: (parent.height / 2 - height / 2) + Math.sin(parent.ang * 2) * 150
                    opacity: win.inputActive ? 0.05 : 0.10
                    color: root.pc("accent")
                    Behavior on opacity { NumberAnimation { duration: 600 } }
                }
                Rectangle {
                    width: parent.width * 0.9; height: width; radius: width / 2
                    x: (parent.width / 2 - width / 2) + Math.sin(parent.ang * 1.5) * -200
                    y: (parent.height / 2 - height / 2) + Math.cos(parent.ang * 1.5) * -150
                    opacity: win.inputActive ? 0.04 : 0.07
                    color: root.pc("blue")
                    Behavior on opacity { NumberAnimation { duration: 600 } }
                }
                Repeater {
                    model: 4
                    Rectangle {
                        required property int index
                        anchors.centerIn: parent
                        anchors.verticalCenterOffset: -40
                        width: 400 + index * 220
                        height: width
                        radius: width / 2
                        color: "transparent"
                        border.width: 1
                        border.color: win.failed ? root.pc("red") : root.pc("text")
                        opacity: win.failed ? (0.10 - index * 0.02)
                                 : win.inputActive ? 0.02 : (0.04 - index * 0.01)
                        Behavior on border.color { ColorAnimation { duration: 600 } }
                        Behavior on opacity { NumberAnimation { duration: 600 } }
                    }
                }
            }

            // ---- CLOCK FACE (idle) ------------------------------------------
            ColumnLayout {
                anchors.centerIn: parent
                anchors.verticalCenterOffset: win.inputActive ? -140 : -40
                spacing: 2
                opacity: win.inputActive ? 0 : 1
                scale: win.inputActive ? 0.92 : 1
                visible: opacity > 0.01
                Behavior on anchors.verticalCenterOffset { NumberAnimation { duration: 500; easing.type: Easing.OutExpo } }
                Behavior on opacity { NumberAnimation { duration: 350 } }
                Behavior on scale { NumberAnimation { duration: 400; easing.type: Easing.OutBack } }

                Text {
                    Layout.alignment: Qt.AlignHCenter
                    text: root.timeStr
                    color: root.pc("text")
                    font.family: root.fontFamily
                    font.pixelSize: 132
                    font.bold: true
                }
                Text {
                    Layout.alignment: Qt.AlignHCenter
                    text: root.dateStr
                    color: root.pc("subtext0")
                    font.family: root.fontFamily
                    font.pixelSize: 19
                    font.bold: true
                }
            }

            // ---- AUTH MODULE (revealed on input) -----------------------------
            RowLayout {
                anchors.centerIn: parent
                anchors.verticalCenterOffset: win.inputActive ? -30 : 40
                spacing: 28
                opacity: win.inputActive ? 1 : 0
                scale: win.inputActive ? 1 : 0.92
                visible: opacity > 0.01
                Behavior on anchors.verticalCenterOffset { NumberAnimation { duration: 500; easing.type: Easing.OutExpo } }
                Behavior on opacity { NumberAnimation { duration: 350 } }
                Behavior on scale { NumberAnimation { duration: 400; easing.type: Easing.OutBack } }

                // avatar (user initial)
                Rectangle {
                    Layout.alignment: Qt.AlignVCenter
                    width: 150; height: 150; radius: 75
                    color: Qt.rgba(root.pc("surface0").r, root.pc("surface0").g, root.pc("surface0").b, 0.5)
                    border.width: 3
                    border.color: win.failed ? root.pc("red")
                                  : win.authenticating ? root.pc("peach")
                                  : Qt.rgba(root.pc("text").r, root.pc("text").g, root.pc("text").b, 0.5)
                    Behavior on border.color { ColorAnimation { duration: 300 } }
                    Text {
                        anchors.centerIn: parent
                        text: (userField.text || "?").charAt(0).toUpperCase()
                        color: root.pc("accent")
                        font.family: root.fontFamily
                        font.pixelSize: 60
                        font.bold: true
                    }
                }

                ColumnLayout {
                    Layout.alignment: Qt.AlignVCenter
                    spacing: 14

                    // editable username (prefilled from greeter.json)
                    TextInput {
                        id: userField
                        text: root.defaultUser
                        color: root.pc("text")
                        font.family: root.fontFamily
                        font.pixelSize: 26
                        font.bold: true
                        selectionColor: root.pc("accent")
                        enabled: !root.busy
                        KeyNavigation.tab: pwField
                        onAccepted: win.refocus()
                        Rectangle {
                            anchors.top: parent.bottom
                            anchors.topMargin: 2
                            width: parent.width; height: 1
                            color: parent.activeFocus ? root.pc("accent") : "transparent"
                        }
                    }

                    // status row: glyph chip + status text
                    RowLayout {
                        spacing: 10
                        Rectangle {
                            width: 34; height: 34; radius: 17
                            color: win.failed ? Qt.rgba(root.pc("red").r, root.pc("red").g, root.pc("red").b, 0.2)
                                   : win.authenticating ? Qt.rgba(root.pc("peach").r, root.pc("peach").g, root.pc("peach").b, 0.2)
                                   : Qt.rgba(root.pc("accent").r, root.pc("accent").g, root.pc("accent").b, 0.15)
                            border.width: 1
                            border.color: win.failed ? root.pc("red")
                                          : win.authenticating ? root.pc("peach") : root.pc("accent")
                            Behavior on color { ColorAnimation { duration: 300 } }
                            Behavior on border.color { ColorAnimation { duration: 300 } }
                            Text {
                                anchors.centerIn: parent
                                text: win.authenticating ? "󰌿" : "󰌾"
                                font.family: root.fontFamily
                                font.pixelSize: 16
                                color: win.failed ? root.pc("red")
                                       : win.authenticating ? root.pc("peach") : root.pc("accent")
                            }
                        }
                        Text {
                            text: win.statusText
                            color: win.failed ? root.pc("red")
                                   : win.authenticating ? root.pc("peach") : root.pc("subtext1")
                            font.family: root.fontFamily
                            font.pixelSize: 13
                            font.letterSpacing: 1.5
                            Behavior on color { ColorAnimation { duration: 300 } }
                        }
                    }

                    // password pill — hidden field + animated dots (lock look)
                    Rectangle {
                        Layout.preferredWidth: 300
                        Layout.preferredHeight: 60
                        radius: 30
                        clip: true
                        color: win.failed ? Qt.rgba(root.pc("red").r, root.pc("red").g, root.pc("red").b, 0.1)
                               : Qt.rgba(root.pc("surface0").r, root.pc("surface0").g, root.pc("surface0").b, 0.5)
                        border.width: 2
                        border.color: win.failed ? root.pc("red")
                                      : win.authenticating ? root.pc("peach")
                                      : pwField.text.length > 0 ? root.pc("accent")
                                      : Qt.rgba(root.pc("text").r, root.pc("text").g, root.pc("text").b, 0.10)
                        Behavior on color { ColorAnimation { duration: 250 } }
                        Behavior on border.color { ColorAnimation { duration: 250 } }
                        scale: win.failed ? 1.04 : win.authenticating ? 0.98 : 1.0
                        Behavior on scale { NumberAnimation { duration: 300; easing.type: Easing.OutBack } }

                        transform: Translate { id: shakeT; x: 0 }
                        SequentialAnimation {
                            id: shakeAnim
                            running: win.failed
                            NumberAnimation { target: shakeT; property: "x"; from: 0; to: -9; duration: 110; easing.type: Easing.InOutSine }
                            NumberAnimation { target: shakeT; property: "x"; from: -9; to: 9; duration: 110; easing.type: Easing.InOutSine }
                            NumberAnimation { target: shakeT; property: "x"; from: 9; to: 0; duration: 110; easing.type: Easing.InOutSine }
                        }

                        TextField {
                            id: pwField
                            anchors.fill: parent
                            opacity: 0
                            echoMode: TextInput.Password
                            enabled: !root.busy
                            focus: true
                            onAccepted: {
                                root.attempt(userField.text, text);
                                text = "";
                            }
                            onTextChanged: {
                                if (text.length > 0) win.inputActive = true;
                                if (root.errorText !== "") root.errorText = "";
                            }
                            Keys.onEscapePressed: { text = ""; win.inputActive = false; }
                        }

                        Row {
                            anchors.centerIn: parent
                            spacing: 8
                            Repeater {
                                model: pwField.text.length
                                Rectangle {
                                    width: 12; height: 12; radius: 6
                                    color: win.failed ? root.pc("red")
                                           : win.authenticating ? root.pc("peach") : root.pc("text")
                                    Behavior on color { ColorAnimation { duration: 200 } }
                                    NumberAnimation on scale { from: 0.2; to: 1; duration: 150; easing.type: Easing.OutBack }
                                }
                            }
                        }
                        Text {
                            anchors.centerIn: parent
                            visible: pwField.text.length === 0 && !win.authenticating
                            text: "••••••"
                            color: root.pc("overlay1")
                            font.family: root.fontFamily
                            font.pixelSize: 20
                        }
                    }
                }
            }

            // ---- BOTTOM PILLS: session selector + hostname -------------------
            RowLayout {
                anchors.bottom: parent.bottom
                anchors.bottomMargin: 40
                anchors.horizontalCenter: parent.horizontalCenter
                spacing: 14

                // session selector — click cycles through wayland sessions
                GreetPill {
                    glyph: ""
                    label: root.session ? root.session.name : "Hyprland"
                    clickable: root.sessions.length > 1
                    onTapped: root.sessionIdx = (root.sessionIdx + 1) % root.sessions.length
                }
                GreetPill {
                    glyph: "󰒋"
                    label: root.hostname
                }
            }

            // ---- POWER MENU (corner) -----------------------------------------
            property bool powerOpen: false

            Rectangle {
                anchors.right: parent.right
                anchors.bottom: powerBtn.top
                anchors.rightMargin: 40
                anchors.bottomMargin: 14
                width: 240
                height: win.powerOpen ? powerCol.implicitHeight + 20 : 0
                radius: 18
                clip: true
                opacity: win.powerOpen ? 1 : 0
                color: Qt.rgba(root.pc("surface0").r, root.pc("surface0").g, root.pc("surface0").b, 0.96)
                border.width: 1
                border.color: Qt.rgba(root.pc("accent").r, root.pc("accent").g, root.pc("accent").b, 0.25)
                Behavior on height { NumberAnimation { duration: 320; easing.type: Easing.OutExpo } }
                Behavior on opacity { NumberAnimation { duration: 220 } }

                ColumnLayout {
                    id: powerCol
                    anchors { top: parent.top; left: parent.left; right: parent.right; topMargin: 10 }
                    spacing: 4
                    PowerRow { glyph: "󰜉"; label: root.t("Restart");   tint: root.pc("blue"); cmd: ["systemctl", "reboot"] }
                    PowerRow { glyph: "󰐥"; label: root.t("Power Off"); tint: root.pc("red");  cmd: ["systemctl", "poweroff"] }
                }
            }

            Rectangle {
                id: powerBtn
                anchors.right: parent.right
                anchors.bottom: parent.bottom
                anchors.margins: 40
                width: 52; height: 52; radius: 26
                color: win.powerOpen ? root.pc("surface2")
                       : Qt.rgba(root.pc("surface0").r, root.pc("surface0").g, root.pc("surface0").b, 0.4)
                border.width: 1
                border.color: win.powerOpen ? root.pc("text")
                              : Qt.rgba(root.pc("text").r, root.pc("text").g, root.pc("text").b, 0.15)
                Behavior on color { ColorAnimation { duration: 200 } }
                Behavior on border.color { ColorAnimation { duration: 200 } }
                scale: pbMa.pressed ? 0.9 : pbMa.containsMouse ? 1.08 : 1.0
                Behavior on scale { NumberAnimation { duration: 200; easing.type: Easing.OutBack } }
                Text {
                    anchors.centerIn: parent
                    text: "󰐥"
                    font.family: root.fontFamily
                    font.pixelSize: 22
                    color: win.powerOpen ? root.pc("red") : pbMa.containsMouse ? root.pc("text") : root.pc("subtext0")
                }
                MouseArea {
                    id: pbMa
                    anchors.fill: parent
                    hoverEnabled: true
                    onClicked: { win.powerOpen = !win.powerOpen; if (!win.powerOpen) win.refocus(); }
                }
            }

            Component.onCompleted: if (win.primary) win.refocus()

            // ---- inline reusable pieces (lock InfoPill / PowerRow) ----------
            component GreetPill: Rectangle {
                property string glyph: ""
                property string label: ""
                property bool clickable: false
                signal tapped()
                implicitHeight: 46
                implicitWidth: gpRow.implicitWidth + 34
                radius: 23
                color: gpMa.containsMouse && clickable
                       ? Qt.rgba(root.pc("surface1").r, root.pc("surface1").g, root.pc("surface1").b, 0.6)
                       : Qt.rgba(root.pc("surface0").r, root.pc("surface0").g, root.pc("surface0").b, 0.4)
                border.width: 1
                border.color: gpMa.containsMouse && clickable ? root.pc("accent")
                              : Qt.rgba(root.pc("text").r, root.pc("text").g, root.pc("text").b, 0.08)
                scale: gpMa.containsMouse && clickable ? 1.05 : 1.0
                Behavior on scale { NumberAnimation { duration: 200; easing.type: Easing.OutExpo } }
                Behavior on color { ColorAnimation { duration: 200 } }
                Behavior on border.color { ColorAnimation { duration: 200 } }
                RowLayout {
                    id: gpRow
                    anchors.centerIn: parent
                    spacing: 8
                    // visible-gate: an empty glyph must not keep its RowLayout
                    // slot — the phantom 8px spacing pushed the label off-centre
                    // (session pill has no icon)
                    Text { visible: text !== ""; text: glyph; font.family: root.fontFamily; font.pixelSize: 18; color: root.pc("accent") }
                    Text { text: label; font.family: root.fontFamily; font.pixelSize: 14; font.bold: true; color: root.pc("text") }
                }
                MouseArea {
                    id: gpMa
                    anchors.fill: parent
                    hoverEnabled: true
                    cursorShape: parent.clickable ? Qt.PointingHandCursor : Qt.ArrowCursor
                    onClicked: if (parent.clickable) parent.tapped()
                }
            }

            component PowerRow: Rectangle {
                property string glyph: ""
                property string label: ""
                property color tint: root.pc("text")
                property var cmd: []
                Layout.fillWidth: true
                Layout.preferredHeight: 46
                Layout.leftMargin: 10
                Layout.rightMargin: 10
                radius: 12
                color: prMa.containsMouse ? Qt.rgba(tint.r, tint.g, tint.b, 0.12) : "transparent"
                Behavior on color { ColorAnimation { duration: 180 } }
                RowLayout {
                    anchors.fill: parent
                    anchors.leftMargin: 16
                    anchors.rightMargin: 16
                    Text { text: glyph; font.family: root.fontFamily; font.pixelSize: 18
                           color: prMa.containsMouse ? tint : Qt.rgba(tint.r, tint.g, tint.b, 0.7) }
                    Item { Layout.fillWidth: true }
                    Text { text: label; font.family: root.fontFamily; font.pixelSize: 15; font.bold: true
                           color: prMa.containsMouse ? tint : Qt.rgba(tint.r, tint.g, tint.b, 0.7) }
                }
                MouseArea {
                    id: prMa
                    anchors.fill: parent
                    hoverEnabled: true
                    onClicked: { win.powerOpen = false; Quickshell.execDetached(cmd); }
                }
            }
        }
    }
}
