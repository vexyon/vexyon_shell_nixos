pragma Singleton

import QtQuick
import Quickshell
import Quickshell.Io
import qs.services

// ============================================================================
//  Wallpaper — single source of truth for setting the desktop background via
//  swww. Centralizes: swww-daemon ensure, apply-with-transition, error capture
//  (swww img via execDetached used to fail SILENTLY — no exit code, no stderr),
//  saved-wallpaper restore on startup, and the transition-style selection that
//  Settings (P4/P5) reads & writes. One reused Process keeps memory flat.
// ============================================================================
Singleton {
    id: root

    // Currently-applied wallpaper path (mirrors Config behavior.wallpaper).
    property string current: Config.get("behavior", "wallpaper", "")
    // Last swww failure (empty when ok) — surfaced by the picker.
    property string lastError: ""
    property bool applying: false
    // Resolved image FILE of the applied wallpaper (sentinel included: the
    // generator's printed PNG). Consumed by the lock screen's blurred backdrop.
    property string lastImage: ""

    // ---- fondo por defecto (procedural, a juego con el tema) --------------
    // Sentinel persistido en behavior.wallpaper en vez de una ruta: mientras
    // esté seleccionado, el fondo se regenera al cambiar de tema. Una ruta
    // normal (elección manual del usuario) NUNCA se toca al cambiar de tema.
    readonly property string defaultId: "vexyon:default"
    readonly property bool isDefault: root.current === root.defaultId
    // Generador (cachea por tema+resolución; imprime la ruta del PNG). Ruta
    // absoluta: el PATH de un qs relanzado no incluye ~/.local/bin (S34).
    // VEXYON_BIN_DIR: en NixOS los helpers viven en el store, no en $HOME. Sin
    // la variable se usa la ruta de Arch de siempre.
    readonly property string genBin: {
        var d = Quickshell.env("VEXYON_BIN_DIR");
        var base = (d && d !== "") ? d : Quickshell.env("HOME") + "/.config/vexyon/bin";
        return base + "/vexyon-wallpaper-gen";
    }

    // Selectable transition styles. `id` is what we persist in
    // behavior.wallpaperTransition; `swww` is the flag set passed to swww img.
    // Kept here so both the picker and Settings share one list.
    readonly property var transitions: [
        { id: "fade",  label: I18n.t("Fade"),            swww: ["--transition-type", "fade"] },
        { id: "grow",  label: I18n.t("Grow from center"), swww: ["--transition-type", "grow", "--transition-pos", "center"] },
        { id: "wipe",  label: I18n.t("Sweep"),            swww: ["--transition-type", "wipe", "--transition-angle", "30"] },
        { id: "wave",  label: I18n.t("Wave (dissolve)"),  swww: ["--transition-type", "wave"] },
        { id: "outer", label: I18n.t("Close to center"),   swww: ["--transition-type", "outer", "--transition-pos", "center"] },
        { id: "none",  label: I18n.t("Instant"),        swww: ["--transition-type", "none"] }
    ]

    function transitionId() {
        return Config.get("behavior", "wallpaperTransition", "grow");
    }
    function setTransition(id) { Config.set("behavior", "wallpaperTransition", id); }

    // Build the swww flag list for a transition id (falls back to grow).
    function transitionFlags(id) {
        for (var i = 0; i < transitions.length; i++)
            if (transitions[i].id === id) return transitions[i].swww;
        return transitions[1].swww; // grow
    }

    // Apply `path` (or the defaultId sentinel). `kind` optional (defaults to
    // the saved transition); pass "none" for the boot-time restore so login
    // doesn't animate.
    function apply(path, kind) {
        if (!path || path === "") return;
        var id = (kind === undefined || kind === null || kind === "") ? transitionId() : kind;
        var flags = transitionFlags(id).join(" ");
        root.applying = true;
        root.lastError = "";
        // Resolve the image: the sentinel runs the generator (cached: ~20ms;
        // fresh: ~0.3s) and uses the printed path; a normal path is quoted
        // safely for bash by escaping single quotes.
        var resolve;
        if (path === root.defaultId) {
            // Se ejecuta DIRECTO, sin `python3` delante: en NixOS el helper del
            // store es el WRAPPER de bash que genera wrapProgram (el .py real
            // está detrás), así que `python3 <wrapper>` moría con SyntaxError y
            // el fondo por defecto no se generaba nunca. Invocarlo por su
            // shebang funciona en los dos sitios — en Arch el fichero
            // desplegado es el propio script Python y ya es ejecutable.
            resolve = "IMG=$('" + root.genBin + "') && [ -s \"$IMG\" ] " +
                      "|| { echo 'vexyon-wallpaper-gen failed' >&2; exit 1; }; ";
        } else {
            resolve = "IMG='" + String(path).replace(/'/g, "'\\''") + "'; ";
        }
        // Resolve the wallpaper daemon binary: prefer swww, fall back to awww
        // (the "An answer to your Wayland Wallpaper Woes" fork — CLI-compatible,
        // ships /usr/bin/awww + awww-daemon and only *provides* swww with no
        // swww binary). Ensure the daemon is up, then set the image.
        proc.command = ["bash", "-c",
            resolve +
            "BIN=$(command -v swww || command -v awww); " +
            "DAEMON=$(command -v swww-daemon || command -v awww-daemon); " +
            "if [ -z \"$BIN\" ]; then echo 'swww/awww no instalado' >&2; exit 127; fi; " +
            "if ! \"$BIN\" query >/dev/null 2>&1; then " +
            "  \"$DAEMON\" >/dev/null 2>&1 & disown; " +
            "  for i in $(seq 1 40); do \"$BIN\" query >/dev/null 2>&1 && break; sleep 0.1; done; " +
            "fi; " +
            "echo \"$IMG\"; exec \"$BIN\" img \"$IMG\" " + flags +
            " --transition-fps 60 --transition-duration 0.6"];
        proc.running = true;
        // Persist selection immediately (atomic; the sentinel persists as-is,
        // so "default" survives reboots and keeps tracking the theme).
        // current updates on success.
        Config.set("behavior", "wallpaper", path);
    }

    // Regenerate + re-apply on theme switch, ONLY while the default wallpaper
    // is selected. A user-picked image never re-applies here. Guarded until
    // the boot restore ran so startup doesn't double-apply.
    Connections {
        target: Theme
        function onActiveIdChanged() {
            if (!root._restored || !Config.ready) return;
            if (Config.get("behavior", "wallpaper", "") === root.defaultId)
                root.apply(root.defaultId);
        }
    }

    Process {
        id: proc
        stdout: StdioCollector { id: outCollector }
        stderr: StdioCollector { id: errCollector }
        onExited: function(exitCode, exitStatus) {
            root.applying = false;
            if (exitCode === 0) {
                root.current = Config.get("behavior", "wallpaper", root.current);
                root.lastError = "";
                // first line = the resolved $IMG echoed by the apply script
                var img = outCollector.text.trim().split("\n")[0];
                if (img !== "") root.lastImage = img;
            } else {
                root.lastError = errCollector.text.trim() || ("swww exit " + exitCode);
                console.warn("[Wallpaper] swww failed exit=" + exitCode + " stderr=" + root.lastError);
                // Surface it (the picker has usually closed by now).
                Quickshell.execDetached(["bash", "-c",
                    "command -v notify-send >/dev/null 2>&1 && " +
                    "notify-send -a Vexyon -u critical '" + I18n.t("Wallpaper") + "' " +
                    "'" + I18n.t("Could not apply (swww). Is swww installed and the daemon active?") + "' || true"]);
            }
        }
    }

    // Restore the saved wallpaper once at startup (no animation). swww loses
    // its image across a daemon restart / relogin, so nothing showed it before.
    // Must wait for Config to finish its async file load — reading it in a plain
    // Component.onCompleted returned "" (Config not ready yet), so the restore
    // never fired. Runs exactly once, the first time Config.ready is true.
    property bool _restored: false
    function _maybeRestore() {
        if (root._restored || !Config.ready) return;
        root._restored = true;
        var saved = Config.get("behavior", "wallpaper", "");
        if (saved && saved !== "") {
            restoreTimer.start();
        }
    }
    Component.onCompleted: root._maybeRestore()
    Connections {
        target: Config
        function onReadyChanged() { root._maybeRestore(); }
        function onChanged() { root._maybeRestore(); }
    }
    // Small delay so swww-daemon (exec-once) has a moment to come up.
    Timer {
        id: restoreTimer
        interval: 800; repeat: false
        onTriggered: root.apply(Config.get("behavior", "wallpaper", ""), "none")
    }
}
