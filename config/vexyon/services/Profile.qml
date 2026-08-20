pragma Singleton

import QtQuick
import Quickshell
import Quickshell.Io
import qs.services

// ============================================================================
//  Profile — the user's configurable avatar (foto de perfil).
//
//  No usamos AccountsService (no está instalado): la fuente de verdad es
//  shell.json `profile.avatar` (ruta absoluta). setAvatar() copia la imagen
//  elegida a una ruta propia y estable dentro de ~/.config/vexyon y además la
//  espeja en ~/.face (convención freedesktop, por si algún día hay
//  AccountsService/greeter que la lea). Cada copia usa un nombre único
//  (avatar-<epoch>) para que el Image de QML recargue sin problemas de caché.
//
//  Lo consumen el componente Avatar (lock screen + tarjetas de perfil).
// ============================================================================
Singleton {
    id: root

    readonly property string homeDir: Quickshell.env("HOME")
    readonly property string path: Config.get("profile", "avatar", "")
    readonly property bool hasAvatar: path !== ""
    readonly property string url: path === "" ? "" : ("file://" + path)

    function shq(x) { return "'" + String(x).replace(/'/g, "'\\''") + "'"; }

    // src: file URL o ruta; copia + persiste + espeja ~/.face
    function setAvatar(src) {
        var s = String(src).replace(/^file:\/\//, "");
        if (s === "") return;
        var dest = root.homeDir + "/.config/vexyon/avatar-" + Date.now();
        copyProc.pendingDest = dest;
        copyProc.command = ["bash", "-c",
            "set -e; " +
            "rm -f " + shq(root.homeDir + "/.config/vexyon/avatar-*") + " 2>/dev/null || true; " +
            "cp -f " + shq(s) + " " + shq(dest) + "; " +
            "cp -f " + shq(dest) + " " + shq(root.homeDir + "/.face") + " 2>/dev/null || true; " +
            "echo ok"];
        copyProc.running = true;
    }

    function clearAvatar() {
        Config.set("profile", "avatar", "");
        Quickshell.execDetached(["bash", "-c",
            "rm -f " + shq(root.homeDir + "/.config/vexyon/avatar-*") + " " +
            shq(root.homeDir + "/.face") + " 2>/dev/null || true"]);
    }

    Process {
        id: copyProc
        property string pendingDest: ""
        stdout: StdioCollector {
            onStreamFinished: {
                if (this.text.indexOf("ok") !== -1)
                    Config.set("profile", "avatar", copyProc.pendingDest);
                else
                    console.warn("[Profile] copy failed:", this.text);
            }
        }
    }
}
