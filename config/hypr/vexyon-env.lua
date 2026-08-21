-- ============================================================================
--  VEXYON — ENVIRONMENT
--  Wayland/Qt/toolkit env only. GPU selection does NOT live here: it is
--  machine-specific and GENERATED into vexyon-gpu.lua (install.sh detects
--  the topology; vexyon-gpu-hotplug re-decides it on display hotplug).
-- ============================================================================

-- --- Wayland / Qt / toolkit ---
hl.env("QT_QPA_PLATFORM", "wayland")
hl.env("QT_QPA_PLATFORMTHEME", "qt6ct")
hl.env("QT_WAYLAND_DISABLE_WINDOWDECORATION", "1")
hl.env("QT_AUTO_SCREEN_SCALE_FACTOR", "1")
hl.env("MOZ_ENABLE_WAYLAND", "1")
hl.env("ELECTRON_OZONE_PLATFORM_HINT", "auto")
hl.env("XDG_CURRENT_DESKTOP", "Hyprland")
hl.env("XDG_SESSION_TYPE", "wayland")
hl.env("XDG_SESSION_DESKTOP", "Hyprland")
hl.env("GDK_BACKEND", "wayland,x11")

-- --- Cursor ---
hl.env("XCURSOR_SIZE", "24")
hl.env("HYPRCURSOR_SIZE", "24")

-- --- Vexyon paths ---
hl.env("WALLPAPER_DIR", "~/Pictures/Wallpapers")
