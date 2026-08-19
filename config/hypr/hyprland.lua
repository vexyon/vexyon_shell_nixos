-- ============================================================================
--  ██╗   ██╗███████╗██╗  ██╗██╗   ██╗ ██████╗ ███╗   ██╗
--  ██║   ██║██╔════╝╚██╗██╔╝╚██╗ ██╔╝██╔═══██╗████╗  ██║
--  ██║   ██║█████╗   ╚███╔╝  ╚████╔╝ ██║   ██║██╔██╗ ██║
--  ╚██╗ ██╔╝██╔══╝   ██╔██╗   ╚██╔╝  ██║   ██║██║╚██╗██║
--   ╚████╔╝ ███████╗██╔╝ ██╗   ██║   ╚██████╔╝██║ ╚████║
--    ╚═══╝  ╚══════╝╚═╝  ╚═╝   ╚═╝    ╚═════╝ ╚═╝  ╚═══╝
--  VEXYON — a custom Wayland shell (this marker line tells install.sh the file
--  is ours; without it every re-run would back it up again). Keybinds & numeric
--  settings are GENERATED from ~/.config/vexyon/shell.json by the bridge
--  daemon — do not edit those here.
-- ============================================================================

-- ---- Monitors (auto; override in ~/.config/hypr/vexyon-monitors.lua) --------
hl.monitor({ output = "", mode = "preferred", position = "auto", scale = "1" })
require("vexyon-monitors")

-- ---- Environment (Wayland/Qt) -----------------------------------------------
require("vexyon-env")

-- ---- Generated GPU pin (install.sh detects the topology and pins the shell
--      to the integrated GPU; vexyon-gpu-hotplug rewrites it live when a
--      display crosses the iGPU/dGPU boundary; informational on single-GPU) --
require("vexyon-gpu")

-- ---- Generated numeric settings (gaps, border, rounding, blur) -------------
require("vexyon-settings")

-- ---- Window & layer rules (blur discipline) --------------------------------
require("vexyon-rules")

-- ---- Generated keybinds (from shell.json) ----------------------------------
require("vexyon-keybinds")

-- ============================================================================
--  STATIC LOOK & FEEL  (colors/opacity handled by Quickshell; these are the
--  compositor-level bits Quickshell can't own)
-- ============================================================================
hl.config({
    general = {
        layout = "dwindle",
        resize_on_border = true,
        -- col.active_border / col.inactive_border viven en el GENERADO
        -- vexyon-settings.lua (paleta del tema activo). No ponerlos aquí: los
        -- hl.config se acumulan y este bloque se evalúa DESPUÉS del require —
        -- pisaría el valor del bridge (última asignación gana).
        allow_tearing = false,
    },

    decoration = {
        active_opacity = 1.0,
        inactive_opacity = 1.0,
        shadow = {
            enabled = true,
            range = 18,
            render_power = 3,
            color = "rgba(00000055)",
        },
    },

    dwindle = {
        preserve_split = true,
        smart_split = false,
    },

    master = {
        new_status = "master",
    },

    misc = {
        disable_hyprland_logo = true,
        disable_splash_rendering = true,
        force_default_wallpaper = 0,
        focus_on_activate = true,
        animate_manual_resizes = true,
        key_press_enables_dpms = true,
        -- Si el proceso del shell (quickshell) muere o recarga su config MIENTRAS
        -- la sesión está bloqueada, Hyprland deja la sesión en el fallback
        -- "lockscreen app died" y el usuario queda ATRAPADO (no puede volver al
        -- shell). Con esto el shell puede re-adquirir el ext-session-lock y
        -- soltarlo al desbloquear en lugar de estrangular la sesión. Red de
        -- seguridad para el bloqueo (Bug 2).
        allow_session_lock_restore = true,
    },

    input = {
        -- kb_layout y follow_mouse viven en el GENERADO vexyon-settings.lua
        -- (Ajustes → Comportamiento). No ponerlos aquí: este bloque se evalúa
        -- DESPUÉS del require y pisaría el valor del bridge.
        sensitivity = 0,
        touchpad = {
            natural_scroll = true,
            disable_while_typing = true,
        },
    },

    animations = {
        enabled = true,
    },
})

-- Touchpad workspace-swipe gesture lives in the generated vexyon-keybinds.lua
-- as: hl.gesture({ fingers = 3, direction = "horizontal", action = "workspace" })

-- ============================================================================
--  ANIMATIONS  (GPU-accelerated, tuned for fluidity without CPU spikes)
-- ============================================================================
hl.curve("vexyonEase",   { type = "bezier", points = { { 0.16, 1 },   { 0.3, 1 }  } })
hl.curve("vexyonSnap",   { type = "bezier", points = { { 0.34, 1.56 }, { 0.64, 1 } } })
hl.curve("vexyonSmooth", { type = "bezier", points = { { 0.4, 0 },    { 0.2, 1 }  } })

hl.animation({ leaf = "windows",          enabled = true, speed = 4, bezier = "vexyonEase",   style = "popin 6%" })
hl.animation({ leaf = "windowsOut",       enabled = true, speed = 4, bezier = "vexyonSmooth", style = "popin 6%" })
hl.animation({ leaf = "windowsMove",      enabled = true, speed = 4, bezier = "vexyonEase" })
hl.animation({ leaf = "border",           enabled = true, speed = 6, bezier = "default" })
hl.animation({ leaf = "fade",             enabled = true, speed = 4, bezier = "vexyonSmooth" })
hl.animation({ leaf = "workspaces",       enabled = true, speed = 5, bezier = "vexyonEase",   style = "slide" })
hl.animation({ leaf = "specialWorkspace", enabled = true, speed = 5, bezier = "vexyonEase",   style = "slidevert" })
hl.animation({ leaf = "layers",           enabled = true, speed = 4, bezier = "vexyonSmooth", style = "fade" })

-- ============================================================================
--  AUTOSTART  (fires once per compositor start; verified NOT re-fired by
--  `hyprctl reload` — Phase 0)
-- ============================================================================
hl.on("hyprland.start", function()
    -- Bridge daemon: keeps shell.json <-> Hyprland keybinds/settings in sync.
    -- En NixOS el bridge vive en el store y llega por PATH como `vexyon-bridge`;
    -- en Arch no existe ese binario y se cae al fichero desplegado en $HOME.
    hl.exec_cmd("sh -c 'command -v vexyon-bridge >/dev/null 2>&1 && exec vexyon-bridge || exec python3 \"$HOME/.config/vexyon/bridge/vexyon-bridge.py\"'")

    -- The Vexyon shell itself (bar, launcher, control center, notifications...).
    -- El QML es CÓDIGO: en Arch se despliega en ~/.config/vexyon (por defecto),
    -- en NixOS vive en el store de solo lectura y solo shell.json queda en $HOME.
    hl.exec_cmd("sh -c 'exec qs -p \"${VEXYON_QML_ROOT:-$HOME/.config/vexyon}/shell.qml\"'")

    -- Wallpaper daemon.
    -- swww fue renombrado a awww upstream; lanzar el daemon que exista
    hl.exec_cmd("bash -c 'exec \"$(command -v swww-daemon || command -v awww-daemon)\"'")

    -- Brightness / color-temperature backend (modern Hyprland: no wlr-gamma-control).
    hl.exec_cmd("hyprsunset")

    -- Polkit authentication agent (for privileged actions).
    -- Ni el agente ni el portal están en el PATH: son libexec. La ruta es
    -- /usr/lib en Arch pero en NixOS lleva el hash del store dentro, así que
    -- se toma de una variable de entorno cuyo DEFECTO es la ruta de Arch
    -- (el módulo de NixOS las exporta en la sesión). El guard -x evita dejar
    -- un proceso muerto en el log cuando la ruta no existe.
    hl.exec_cmd("sh -c 'p=\"${VEXYON_POLKIT_AGENT:-/usr/lib/polkit-kde-authentication-agent-1}\"; [ -x \"$p\" ] && exec \"$p\"'")

    -- XDG desktop portal for screensharing/file dialogs.
    -- En NixOS lo arranca D-Bus/systemd por xdg.portal, así que allí la
    -- variable se deja vacía a propósito y este exec no hace nada.
    hl.exec_cmd("sh -c 'p=\"${VEXYON_XDG_PORTAL_HYPRLAND-/usr/lib/xdg-desktop-portal-hyprland}\"; [ -n \"$p\" ] && [ -x \"$p\" ] && exec \"$p\"'")

    -- Clipboard history collector.
    hl.exec_cmd("wl-paste --watch cliphist store")
end)
