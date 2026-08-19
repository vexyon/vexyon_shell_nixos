//@ pragma UseQApplication
//@ pragma IconTheme Papirus-Dark
// ============================================================================
//  Vexyon — shell entry point. Wires every layer together. Modules never talk
//  to the system directly; they read tokens from Theme and state from services.
// ============================================================================
import QtQuick
import Quickshell
import Quickshell.Hyprland
import Quickshell.Io
import qs.services
import qs.modules

ShellRoot {
    id: shell

    // External control surface: `qs -p <shell.qml> ipc call vexyon <fn>`.
    // Handy for scripting and for panel toggles from outside the shell.
    IpcHandler {
        target: "vexyon"
        function lock() { Lock.lock() }
        function unlock() { Lock.unlock() }
        function toggle(name: string) { Panels.toggle(name) }
        function theme(id: string) { Theme.apply(id) }
        // Config desde fuera SIN tocar shell.json a mano (el watch de FileView
        // no aguanta sustituciones externas repetidas; Config.set sí es fiable).
        // Coerción: "true"/"false" -> bool, numérico -> number, resto string.
        function set(section: string, key: string, value: string): void {
            var v = value;
            if (value === "true") v = true;
            else if (value === "false") v = false;
            else if (value !== "" && !isNaN(Number(value))) v = Number(value);
            Config.set(section, key, v);
        }
    }

    // Silence the reload popup; the bridge/hyprctl reload is expected churn.
    Connections {
        target: Quickshell
        function onReloadCompleted() { Quickshell.inhibitReloadPopup() }
        function onReloadFailed(err) { Quickshell.inhibitReloadPopup() }
    }

    // Force the core singletons to instantiate at startup.
    Component.onCompleted: {
        console.log("[Vexyon] shell loaded. active theme:", Theme.activeId);
        // Touch Wallpaper so its singleton instantiates now -> startup restore
        // of the saved background runs (swww loses its image across relogin).
        console.log("[Vexyon] wallpaper:", Wallpaper.current);
    }

    // ---- Global keyboard shortcuts (Hyprland binds them via quickshell:<name>) ----
    GlobalShortcut { appid: "quickshell"; name: "launcher";      onPressed: Panels.toggle("launcher") }
    GlobalShortcut { appid: "quickshell"; name: "controlcenter"; onPressed: Panels.toggleFallback("quickSettings") }
    GlobalShortcut { appid: "quickshell"; name: "wallpaper";     onPressed: Panels.toggle("wallpaper") }
    GlobalShortcut { appid: "quickshell"; name: "powermenu";     onPressed: Panels.toggle("powermenu") }
    GlobalShortcut { appid: "quickshell"; name: "lock";          onPressed: Lock.lock() }
    GlobalShortcut { appid: "quickshell"; name: "screenshot";    onPressed: Panels.open("screenshot") }
    GlobalShortcut { appid: "quickshell"; name: "themeswitcher"; onPressed: Panels.toggleFallback("themeQuick") }
    // Super+E: cada pulsación abre una instancia NUEVA e independiente del
    // gestor de archivos (se cierra con Super+Q; la instancia se autodestruye).
    Component { id: fmFactory; FileManager {} }
    GlobalShortcut { appid: "quickshell"; name: "filemanager";   onPressed: fmFactory.createObject(shell) }

    // ---- Multimedia keys (XF86*) — bound by the bridge with bindl/bindel so
    // they work while locked and repeat when held. Volume/mic go through the
    // existing PipeWire services, brightness through brightnessctl, media
    // through the in-process MPRIS service (covers headset buttons too).
    // Explicit Osd.show() covers edge presses that change nothing (e.g. volume
    // already at 100%); server-side changes also pop it via Osd's Connections.
    GlobalShortcut { appid: "quickshell"; name: "volumeUp";       onPressed: { Audio.step(0.05);      Osd.show("volume"); } }
    GlobalShortcut { appid: "quickshell"; name: "volumeDown";     onPressed: { Audio.step(-0.05);     Osd.show("volume"); } }
    GlobalShortcut { appid: "quickshell"; name: "volumeMute";     onPressed: { Audio.toggleMute();    Osd.show("volume"); } }
    GlobalShortcut { appid: "quickshell"; name: "micMute";        onPressed: { Mic.toggleMute();      Osd.show("mic"); } }
    GlobalShortcut { appid: "quickshell"; name: "brightnessUp";   onPressed: { Brightness.step(5);    Osd.show("brightness"); } }
    GlobalShortcut { appid: "quickshell"; name: "brightnessDown"; onPressed: { Brightness.step(-5);   Osd.show("brightness"); } }
    GlobalShortcut { appid: "quickshell"; name: "mediaPlayPause"; onPressed: Media.toggle() }
    GlobalShortcut { appid: "quickshell"; name: "mediaPause";     onPressed: Media.pause() }
    GlobalShortcut { appid: "quickshell"; name: "mediaNext";      onPressed: Media.next() }
    GlobalShortcut { appid: "quickshell"; name: "mediaPrev";      onPressed: Media.previous() }

    // ---- Layers ----
    Bar {}
    Launcher {}
    QuickSettingsPanel {}
    WeatherPanel {}
    NotificationCenterPanel {}
    SystemMonitorPanel {}
    MediaPanel {}
    VolumePanel {}
    NetworkPanel {}
    BatteryPanel {}
    CalendarPanel {}
    ClipboardPanel {}
    ThemeQuickPanel {}
    Settings {}
    TrayMenu {}
    PowerMenu {}
    LockScreen {}
    WallpaperPicker {}
    // Onboarding: solo existe durante el primer arranque — misma condición
    // que su `visible` de siempre. Tras dismiss (firstRun=false) el Loader lo
    // destruye y ese árbol no vuelve a ocupar RAM nunca.
    LazyLoader {
        active: Config.ready && Config.get("state", "firstRun", true) === true
        Onboarding {}
    }
    ScreenshotOverlay {}
    MonitorRevertDialog {}
    OsdOverlay {}
}
