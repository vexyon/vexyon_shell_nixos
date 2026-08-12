import QtQuick
import QtQuick.Layouts
import QtQuick.Effects
import Quickshell
import Quickshell.Wayland
import Quickshell.Services.Pam
import qs.services
import qs.components

// ============================================================================
//  Lock screen — ext_session_lock_v1 via WlSessionLock. PAM-authenticated.
//  Locked by Super+L or the power menu (Lock.locked = true).
//
//  Visual design inspired by Caelestia Shell's lock: blurred one-shot capture
//  of the screen behind a central rounded card that morphs in from a spinning
//  lock-glyph square, then reveals a two-tone clock, date, avatar and a pill
//  password input. Reimplemented on Vexyon's Theme tokens + I18n (no Caelestia
//  code or hardcoded colours). Kept INTEGRATED (a WlSessionLock child of the
//  shell driven by Lock.locked + PamContext config "vexyon").
//
//  Input model (fixes the "Enter never unlocked" bug): NO TextField. The old
//  field lived inside a container with `visible: opacity > 0.01` that started
//  invisible — forceActiveFocus() on an invisible item is a no-op, so the
//  field never had focus, typing went nowhere and onAccepted never fired.
//  Now an ALWAYS-VISIBLE focused Item handles Keys.onPressed and feeds a
//  plain string buffer (same approach Caelestia uses), so keystrokes work
//  from the first frame with zero focus choreography.
// ============================================================================
WlSessionLock {
    id: lock
    locked: Lock.locked

    property string errorText: ""
    property bool busy: false

    // NOTE: the PAM auth logic lives on the SURFACE (surface.attempt), not here,
    // because PamContext (`pam`) is scoped inside the WlSessionLockSurface — a
    // function declared on this WlSessionLock root cannot see `pam` and threw
    // "ReferenceError: pam is not defined" on every submit (old Bug 2).

    WlSessionLockSurface {
        id: surface
        color: "transparent"

        // typed-but-not-submitted password. Cleared on submit/Escape.
        property string buffer: ""

        // Card morph progress: 0 = small lock-glyph square, 1 = full card. The
        // card's width/height/radius are LIVE bindings off this + cardW/cardH
        // (below), never captured animation endpoints — so if the surface
        // geometry arrives late or changes (output hotplug / resolution change)
        // the card recomputes and re-centres instead of freezing at a stale/zero
        // size. initAnim drives it 0->1, unlockAnim 1->0.
        property real reveal: 0
        readonly property bool authenticating: lock.busy
        readonly property bool failed: lock.errorText !== ""
        readonly property bool unlocking: unlockAnim.running

        // final card geometry (Caelestia sizes its card off the screen height)
        readonly property int cardW: Math.min(500, Math.round(width * 0.45))
        readonly property int cardH: Math.min(720, Math.round(height * 0.8))

        // Kick off PAM auth. Defined HERE (not on `lock`) so it can see `pam`,
        // which is scoped to this surface. See the note on the WlSessionLock root.
        function attempt(pw) {
            if (lock.busy || surface.unlocking || pw === "") return;
            lock.busy = true;
            lock.errorText = "";
            surface.buffer = "";
            pam.pending = pw;
            // start() returns false when PAM can't even begin — e.g. the
            // /etc/pam.d/vexyon service file is missing. In that case NO
            // completed/error signal fires, so we must clear busy ourselves,
            // otherwise input stays disabled forever.
            var ok = pam.start();
            if (!ok) {
                lock.busy = false;
                lock.errorText = I18n.t("PAM unavailable (missing /etc/pam.d/vexyon)");
                pam.pending = "";
            }
        }

        // ---- keyboard: always-visible handler feeding the buffer ------------
        Item {
            id: keys
            anchors.fill: parent
            focus: true
            // the lock surface can steal/rearrange focus while mapping; always
            // pull it back — this item is the only focus target on the surface
            onActiveFocusChanged: if (!activeFocus) forceActiveFocus()
            Keys.onPressed: function(event) {
                event.accepted = true;
                if (lock.busy || surface.unlocking) return;
                if (event.key === Qt.Key_Enter || event.key === Qt.Key_Return) {
                    surface.attempt(surface.buffer);
                } else if (event.key === Qt.Key_Escape) {
                    surface.buffer = "";
                    lock.errorText = "";
                } else if (event.key === Qt.Key_Backspace) {
                    surface.buffer = (event.modifiers & Qt.ControlModifier)
                        ? "" : surface.buffer.slice(0, -1);
                } else if (event.text !== "" && !/[\x00-\x1F\x7F-\x9F]/.test(event.text)) {
                    surface.buffer += event.text;
                    if (lock.errorText !== "") lock.errorText = "";
                }
            }
        }

        // retry focus for the first ~1s while the surface finishes mapping
        Timer {
            id: focusRetry
            interval: 60; repeat: true; running: true
            property int tries: 0
            onTriggered: {
                keys.forceActiveFocus();
                if (keys.activeFocus || ++tries > 16) running = false;
            }
        }

        // any click returns focus to the key handler (paranoia)
        MouseArea {
            anchors.fill: parent
            acceptedButtons: Qt.LeftButton | Qt.RightButton
            onPressed: function(m) { keys.forceActiveFocus(); m.accepted = false; }
        }

        // PAM authentication context. Reads the current user's password.
        // Lives inside the surface because the WlSessionLock default property
        // is the single `surface` component — it cannot hold sibling objects.
        PamContext {
            id: pam
            config: "vexyon"
            property string pending: ""

            onResponseRequiredChanged: {
                if (responseRequired) respond(pending);
            }
            onCompleted: function(result) {
                lock.busy = false;
                if (result === PamResult.Success) {
                    lock.errorText = "";
                    unlockAnim.start();   // morph out, then Lock.unlock()
                } else {
                    lock.errorText = I18n.t("Wrong password");
                    shakeAnim.restart();
                }
                pending = "";
            }
            onError: function(e) {
                console.warn("[LockScreen] PAM error:", e);
                lock.busy = false;
                lock.errorText = I18n.t("Authentication error");
                pending = "";
                shakeAnim.restart();
            }
        }

        // ---- background: blurred wallpaper + scrim --------------------------
        //  Caelestia blurs a live screen capture; here we blur the WALLPAPER
        //  image instead (Wallpaper.lastImage — resolved even for the
        //  vexyon:default sentinel). Same look, works on any GPU (ScreencopyView
        //  delivered black frames under llvmpipe) and never exposes window
        //  contents on the lock screen. Fallback: theme gradient.
        Item {
            id: bg
            anchors.fill: parent
            opacity: 0
            Rectangle {
                anchors.fill: parent
                gradient: Gradient {
                    GradientStop { position: 0.0; color: Theme.mantle }
                    GradientStop { position: 1.0; color: Theme.crust }
                }
            }
            Image {
                anchors.fill: parent
                source: Wallpaper.lastImage !== "" ? "file://" + Wallpaper.lastImage : ""
                visible: status === Image.Ready
                fillMode: Image.PreserveAspectCrop
                asynchronous: true
                // quarter-res source: cheaper blur, invisible under blurMax 48
                sourceSize.width: Math.ceil(surface.width / 4)
                layer.enabled: true
                layer.effect: MultiEffect {
                    autoPaddingEnabled: false
                    blurEnabled: true
                    blur: 1
                    blurMax: 48
                }
            }
            // scrim: asegura contraste de la tarjeta sobre cualquier fondo/tema
            Rectangle {
                anchors.fill: parent
                color: Qt.rgba(Theme.crust.r, Theme.crust.g, Theme.crust.b, 0.45)
            }
        }

        // ---- central card ---------------------------------------------------
        Item {
            id: card
            readonly property int iconSize: 132
            anchors.centerIn: parent
            // live bindings: interpolate glyph-square -> full card by `reveal`
            // against the CURRENT surface geometry (fixes late/stale-geometry
            // decentering — the card tracks cardW/cardH even mid-animation).
            width: card.iconSize + (surface.cardW - card.iconSize) * surface.reveal
            height: card.iconSize + (surface.cardH - card.iconSize) * surface.reveal
            scale: 0
            rotation: 180

            Rectangle {
                anchors.fill: parent
                radius: (card.iconSize / 4) + (36 - card.iconSize / 4) * surface.reveal
                color: Qt.rgba(Theme.base.r, Theme.base.g, Theme.base.b, 0.94)
                border.width: 1
                border.color: Qt.rgba(Theme.accent.r, Theme.accent.g, Theme.accent.b, 0.22)
            }

            // lock glyph shown while the card is still the small square
            Text {
                id: lockIcon
                anchors.centerIn: parent
                rotation: 180
                text: "󰌾"
                font.family: Theme.fontFamily
                font.pixelSize: 64
                color: Theme.accent
            }

            // ---- card content (clock / date / avatar / input / message) -----
            ColumnLayout {
                id: content
                anchors.fill: parent
                anchors.topMargin: 40
                anchors.bottomMargin: 32
                anchors.leftMargin: 32
                anchors.rightMargin: 32
                spacing: 0
                opacity: 0
                scale: 0.7
                visible: opacity > 0.01

                // two-tone clock: hours in accent, minutes in accent2
                RowLayout {
                    Layout.alignment: Qt.AlignHCenter
                    spacing: 10
                    Text {
                        text: Time.hh
                        color: Theme.accent
                        font.family: Theme.fontFamily
                        font.pixelSize: Math.round(surface.cardH * 0.16)
                        font.bold: true
                    }
                    Text {
                        text: Time.mm
                        color: Theme.accent2
                        font.family: Theme.fontFamily
                        font.pixelSize: Math.round(surface.cardH * 0.16)
                        font.bold: true
                    }
                }

                // full date, shell-language locale (same rule as the bar/panels)
                Text {
                    Layout.alignment: Qt.AlignHCenter
                    Layout.topMargin: 2
                    text: Time.now.toLocaleDateString(I18n.locale, "dddd • d MMM").toUpperCase()
                    color: Theme.subtext0
                    font.family: Theme.fontFamily
                    font.pixelSize: Theme.fontSize + 2
                    font.bold: true
                    font.letterSpacing: 2
                }

                Item { Layout.fillHeight: true }

                Avatar {
                    Layout.alignment: Qt.AlignHCenter
                    size: Math.round(surface.cardW * 0.4)
                    fallbackScale: 0.4
                    bg: Qt.rgba(Theme.surface0.r, Theme.surface0.g, Theme.surface0.b, 0.6)
                    borderWidth: 3
                    borderColor: surface.failed ? Theme.red
                                 : surface.authenticating ? Theme.peach
                                 : Qt.rgba(Theme.accent.r, Theme.accent.g, Theme.accent.b, 0.6)
                }

                Item { Layout.fillHeight: true }

                // ---- password pill: glyph | dots/placeholder | enter arrow --
                Rectangle {
                    id: pinPill
                    Layout.alignment: Qt.AlignHCenter
                    Layout.preferredWidth: Math.round(surface.cardW * 0.82)
                    Layout.preferredHeight: 56
                    radius: height / 2
                    clip: true
                    color: surface.failed ? Qt.rgba(Theme.red.r, Theme.red.g, Theme.red.b, 0.10)
                           : Qt.rgba(Theme.surface0.r, Theme.surface0.g, Theme.surface0.b, 0.8)
                    border.width: 2
                    border.color: surface.failed ? Theme.red
                                  : surface.authenticating ? Theme.peach
                                  : surface.buffer.length > 0 ? Theme.accent
                                  : Qt.rgba(Theme.text.r, Theme.text.g, Theme.text.b, 0.10)
                    Behavior on color { ColorAnimation { duration: Theme.dur(250) } }
                    Behavior on border.color { ColorAnimation { duration: Theme.dur(250) } }

                    transform: Translate { id: shakeT; x: 0 }
                    SequentialAnimation {
                        id: shakeAnim
                        NumberAnimation { target: shakeT; property: "x"; from: 0; to: -9; duration: 110; easing.type: Easing.InOutSine }
                        NumberAnimation { target: shakeT; property: "x"; from: -9; to: 9; duration: 110; easing.type: Easing.InOutSine }
                        NumberAnimation { target: shakeT; property: "x"; from: 9; to: 0; duration: 110; easing.type: Easing.InOutSine }
                    }

                    RowLayout {
                        anchors.fill: parent
                        anchors.leftMargin: 20
                        anchors.rightMargin: 8
                        spacing: 12

                        Text {
                            text: surface.authenticating ? "󰌿" : "󰌾"
                            font.family: Theme.fontFamily
                            font.pixelSize: 18
                            color: surface.failed ? Theme.red
                                   : surface.authenticating ? Theme.peach : Theme.subtext0
                        }

                        // dots while typing, placeholder text when empty
                        Item {
                            Layout.fillWidth: true
                            Layout.fillHeight: true
                            clip: true
                            Row {
                                anchors.centerIn: parent
                                spacing: 8
                                Repeater {
                                    model: surface.buffer.length
                                    Rectangle {
                                        width: 11; height: 11; radius: 5.5
                                        anchors.verticalCenter: parent.verticalCenter
                                        color: surface.failed ? Theme.red : Theme.text
                                        NumberAnimation on scale { from: 0.2; to: 1; duration: Theme.dur(150); easing.type: Easing.OutBack }
                                    }
                                }
                            }
                            Text {
                                anchors.centerIn: parent
                                visible: surface.buffer.length === 0
                                text: surface.authenticating ? I18n.t("Verifying…")
                                                             : I18n.t("Enter your password")
                                color: surface.authenticating ? Theme.peach : Theme.overlay1
                                font.family: Theme.fontFamily
                                font.pixelSize: Theme.fontSize
                            }
                        }

                        // enter button — lights up in accent when there is input
                        Rectangle {
                            Layout.alignment: Qt.AlignVCenter
                            width: 40; height: 40; radius: 20
                            color: surface.buffer.length > 0 ? Theme.accent
                                   : Qt.rgba(Theme.surface2.r, Theme.surface2.g, Theme.surface2.b, 0.7)
                            scale: enterMa.pressed ? 0.88 : enterMa.containsMouse ? 1.06 : 1.0
                            Behavior on color { ColorAnimation { duration: Theme.dur(200) } }
                            Behavior on scale { NumberAnimation { duration: Theme.dur(200); easing.type: Easing.OutBack } }
                            Text {
                                anchors.centerIn: parent
                                text: "󰁔"
                                font.family: Theme.fontFamily
                                font.pixelSize: 18
                                color: surface.buffer.length > 0 ? Theme.onAccent : Theme.overlay2
                            }
                            MouseArea {
                                id: enterMa
                                anchors.fill: parent
                                hoverEnabled: true
                                onClicked: surface.attempt(surface.buffer)
                            }
                        }
                    }
                }

                // state message: PAM error (red) or caps-lock warning
                Text {
                    Layout.alignment: Qt.AlignHCenter
                    Layout.topMargin: 14
                    Layout.preferredHeight: implicitHeight
                    text: surface.failed ? lock.errorText
                          : KeyboardState.capsOn ? I18n.t("Caps Lock is on") : " "
                    color: surface.failed ? Theme.red : Theme.subtext1
                    font.family: Theme.fontFamily
                    font.pixelSize: Theme.fontSize - 1
                    Behavior on color { ColorAnimation { duration: Theme.dur(200) } }
                }

                // status pills (keyboard layout / battery / weather) — INSIDE
                // the card so they fade and morph with the rest of the module
                RowLayout {
                    Layout.alignment: Qt.AlignHCenter
                    Layout.topMargin: 16
                    spacing: 12

                    InfoPill {
                        glyph: "󰌌"
                        label: (KeyboardState.layout || "us").toUpperCase()
                                     + (KeyboardState.capsOn ? "  ⇪" : "")
                    }
                    InfoPill {
                        visible: Battery.present
                        glyph: Battery.charging ? "󰂄" : (Battery.percent < 20 ? "󰂃" : "󰁹")
                        label: Battery.percent + "%"
                        tint: Battery.charging ? Theme.green
                              : Battery.percent < 20 ? Theme.red
                              : Battery.percent < 40 ? Theme.peach : Theme.text
                    }
                    InfoPill {
                        visible: Weather.ok
                        glyph: Weather.icon
                        label: Weather.temp + "°C"
                    }
                }
            }
        }

        // ---- entry: glyph square spins in, then morphs into the card --------
        SequentialAnimation {
            id: initAnim
            running: true
            ParallelAnimation {
                NumberAnimation { target: bg; property: "opacity"; to: 1; duration: Theme.dur(450); easing.type: Easing.OutQuad }
                NumberAnimation { target: card; property: "scale"; to: 1; duration: Theme.dur(450); easing.type: Easing.OutBack }
                NumberAnimation { target: card; property: "rotation"; from: 180; to: 360; duration: Theme.dur(450); easing.type: Easing.InOutQuad }
            }
            ParallelAnimation {
                NumberAnimation { target: lockIcon; property: "opacity"; to: 0; duration: Theme.dur(250) }
                NumberAnimation { target: lockIcon; property: "rotation"; from: 180; to: 360; duration: Theme.dur(400); easing.type: Easing.OutQuad }
                NumberAnimation { target: surface; property: "reveal"; to: 1; duration: Theme.dur(450); easing.type: Easing.OutExpo }
                NumberAnimation { target: content; property: "opacity"; to: 1; duration: Theme.dur(320) }
                NumberAnimation { target: content; property: "scale"; to: 1; duration: Theme.dur(400); easing.type: Easing.OutExpo }
            }
        }

        // ---- exit (PAM success): card shrinks back to the glyph, bg fades ---
        //  STRICTLY sequential: the content must be fully invisible BEFORE the
        //  card geometry animates. Resizing while the ColumnLayout is still
        //  visible made it re-lay out mid-fade — the clock/avatar visibly
        //  jumped instead of dissolving.
        SequentialAnimation {
            id: unlockAnim
            ParallelAnimation {
                NumberAnimation { target: content; property: "opacity"; to: 0; duration: Theme.dur(180) }
                NumberAnimation { target: content; property: "scale"; to: 0.92; duration: Theme.dur(180) }
            }
            ParallelAnimation {
                NumberAnimation { target: lockIcon; property: "opacity"; to: 1; duration: Theme.dur(280) }
                NumberAnimation { target: surface; property: "reveal"; to: 0; duration: Theme.dur(350); easing.type: Easing.OutExpo }
            }
            ParallelAnimation {
                NumberAnimation { target: card; property: "scale"; to: 0; duration: Theme.dur(300); easing.type: Easing.InBack }
                NumberAnimation { target: bg; property: "opacity"; to: 0; duration: Theme.dur(300); easing.type: Easing.InQuad }
            }
            ScriptAction { script: Lock.unlock() }
        }

        // ---- POWER MENU (corner) ----
        property bool powerOpen: false

        Rectangle {
            id: powerMenu
            anchors.right: parent.right
            anchors.bottom: powerBtn.top
            anchors.rightMargin: 40
            anchors.bottomMargin: 14
            width: 240
            height: surface.powerOpen ? powerCol.implicitHeight + 20 : 0
            radius: 18
            clip: true
            opacity: surface.powerOpen ? 1 : 0
            color: Qt.rgba(Theme.surface0.r, Theme.surface0.g, Theme.surface0.b, 0.96)
            border.width: 1
            border.color: Qt.rgba(Theme.accent.r, Theme.accent.g, Theme.accent.b, 0.25)
            Behavior on height { NumberAnimation { duration: Theme.dur(320); easing.type: Easing.OutExpo } }
            Behavior on opacity { NumberAnimation { duration: Theme.dur(220) } }

            ColumnLayout {
                id: powerCol
                anchors { top: parent.top; left: parent.left; right: parent.right; topMargin: 10 }
                spacing: 4
                PowerRow { glyph: "󰜉"; label: I18n.t("Restart");   tint: Theme.blue;  cmd: ["systemctl", "reboot"] }
                PowerRow { glyph: "󰒲"; label: I18n.t("Suspend");   tint: Theme.accent; cmd: ["systemctl", "suspend"] }
                PowerRow { glyph: "󰐥"; label: I18n.t("Power Off"); tint: Theme.red;   cmd: ["systemctl", "poweroff"] }
            }
        }

        Rectangle {
            id: powerBtn
            anchors.right: parent.right
            anchors.bottom: parent.bottom
            anchors.margins: 40
            width: 52; height: 52; radius: 26
            opacity: bg.opacity
            color: surface.powerOpen ? Theme.surface2
                   : Qt.rgba(Theme.surface0.r, Theme.surface0.g, Theme.surface0.b, 0.4)
            border.width: 1
            border.color: surface.powerOpen ? Theme.text
                          : Qt.rgba(Theme.text.r, Theme.text.g, Theme.text.b, 0.15)
            Behavior on color { ColorAnimation { duration: Theme.dur(200) } }
            Behavior on border.color { ColorAnimation { duration: Theme.dur(200) } }
            scale: pbMa.pressed ? 0.9 : pbMa.containsMouse ? 1.08 : 1.0
            Behavior on scale { NumberAnimation { duration: Theme.dur(200); easing.type: Easing.OutBack } }
            Text {
                anchors.centerIn: parent
                text: "󰐥"
                font.family: Theme.fontFamily
                font.pixelSize: 22
                color: surface.powerOpen ? Theme.red : pbMa.containsMouse ? Theme.text : Theme.subtext0
            }
            MouseArea {
                id: pbMa
                anchors.fill: parent
                hoverEnabled: true
                onClicked: { surface.powerOpen = !surface.powerOpen; keys.forceActiveFocus(); }
            }
        }

        // la superficie muestra layout de teclado + caps ⇪ → mantener vivo el
        // poll de KeyboardState solo mientras está bloqueado
        Component.onCompleted: {
            KeyboardState.watchers++;
            keys.forceActiveFocus();
        }
        Component.onDestruction: KeyboardState.watchers--

        // ---- inline reusable pieces ----
        component InfoPill: Rectangle {
            property string glyph: ""
            property string label: ""
            property color tint: Theme.text
            implicitHeight: 46
            implicitWidth: pillRow.implicitWidth + 34
            radius: 23
            color: pillMa.containsMouse ? Qt.rgba(Theme.surface1.r, Theme.surface1.g, Theme.surface1.b, 0.6)
                   : Qt.rgba(Theme.surface0.r, Theme.surface0.g, Theme.surface0.b, 0.4)
            border.width: 1
            border.color: pillMa.containsMouse ? Theme.accent
                          : Qt.rgba(Theme.text.r, Theme.text.g, Theme.text.b, 0.08)
            scale: pillMa.containsMouse ? 1.05 : 1.0
            Behavior on scale { NumberAnimation { duration: Theme.dur(200); easing.type: Easing.OutExpo } }
            Behavior on color { ColorAnimation { duration: Theme.dur(200) } }
            Behavior on border.color { ColorAnimation { duration: Theme.dur(200) } }
            RowLayout {
                id: pillRow
                anchors.centerIn: parent
                spacing: 8
                // visible-gate: empty glyph must not keep its spacing slot
                // (same off-centre bug as the greeter's session pill)
                Text { visible: text !== ""; text: glyph; font.family: Theme.fontFamily; font.pixelSize: 18; color: tint }
                Text { text: label; font.family: Theme.fontFamily; font.pixelSize: 14; font.bold: true; color: Theme.text }
            }
            MouseArea { id: pillMa; anchors.fill: parent; hoverEnabled: true }
        }

        component PowerRow: Rectangle {
            property string glyph: ""
            property string label: ""
            property color tint: Theme.text
            property var cmd: []
            Layout.fillWidth: true
            Layout.preferredHeight: 46
            Layout.leftMargin: 10
            Layout.rightMargin: 10
            radius: 12
            color: prMa.containsMouse ? Qt.rgba(tint.r, tint.g, tint.b, 0.12) : "transparent"
            Behavior on color { ColorAnimation { duration: Theme.dur(180) } }
            RowLayout {
                anchors.fill: parent
                anchors.leftMargin: 16
                anchors.rightMargin: 16
                Text { text: glyph; font.family: Theme.fontFamily; font.pixelSize: 18
                       color: prMa.containsMouse ? tint : Qt.rgba(tint.r, tint.g, tint.b, 0.7) }
                Item { Layout.fillWidth: true }
                Text { text: label; font.family: Theme.fontFamily; font.pixelSize: 15; font.bold: true
                       color: prMa.containsMouse ? tint : Qt.rgba(tint.r, tint.g, tint.b, 0.7) }
            }
            MouseArea {
                id: prMa
                anchors.fill: parent
                hoverEnabled: true
                onClicked: { surface.powerOpen = false; Quickshell.execDetached(cmd); }
            }
        }
    }

}
