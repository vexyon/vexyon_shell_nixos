-- Vexyon greeter — kiosk Hyprland config for greetd (Lua, Hyprland >= 0.55)
--
-- Runs the Quickshell greeter and exits the compositor when it quits —
-- Greetd.launch(..., quit=true) makes qs exit after posting start_session,
-- and greetd then starts the real user session on this VT.
--
-- DOS directorios, a propósito:
--   VEXYON_GREETER_QML    de dónde sale el greeter (código, inmutable)
--   VEXYON_GREETER_STATE  dónde viven los snapshots MUTABLES (tema, idioma,
--                         teclado, pin de GPU) que se reescriben en caliente
-- En Arch los dos son /etc/greetd/vexyon-greeter y no cambia nada. En NixOS el
-- código vive en el store (solo lectura) y el estado en /var/lib/vexyon-greeter;
-- el módulo sustituye estas dos constantes al construir el paquete.
local QML   = "/etc/greetd/vexyon-greeter"
local STATE = "/etc/greetd/vexyon-greeter"

hl.monitor({ output = "", mode = "preferred", position = "auto", scale = "1" })

-- Fragmentos GENERADOS, cargados por ruta absoluta (antes eran require(), que
-- resuelve relativo a este fichero — imposible cuando el fichero está en el
-- store y los fragmentos en /var/lib). pcall: en una instalación recién hecha
-- puede que aún no exista alguno, y eso no debe tumbar la pantalla de login.
--   vexyon-gpu.lua  pin de GPU compartido con la sesión (install.sh lo genera,
--                   vexyon-gpu-hotplug lo reescribe en hotplugs iGPU/dGPU)
--   input.lua       kb_layout = behavior.keyboardLayout del usuario; la
--                   contraseña debe teclearse con la misma distribución que en
--                   la sesión (lo escribe vexyon-greeter-sync-theme)
pcall(dofile, STATE .. "/vexyon-gpu.lua")

-- Defectos que vienen del SISTEMA por entorno (los exporta el módulo de NixOS
-- desde su propia config; en Arch no están definidos y se cae a lo de siempre).
-- Son solo el defecto: si el usuario elige otra cosa en Ajustes, los ficheros
-- generados del estado se cargan DESPUÉS y mandan ellos.
local function env_or(name, fallback)
    local v = os.getenv(name)
    if v == nil or v == "" then return fallback end
    return v
end

-- Teclado: la contraseña del login tiene que teclearse con la MISMA
-- distribución que el TTY y la sesión, o el usuario no puede entrar.
local kb_layout  = env_or("VEXYON_KB_LAYOUT", "us")
local kb_variant = env_or("VEXYON_KB_VARIANT", "")

-- Cursor: el greeter enseña el mismo que la sesión (cursor.lua lo re-sincroniza
-- con la elección real del usuario en cuanto el bridge corre una vez).
local cursor_theme = env_or("VEXYON_CURSOR_THEME", "")
if cursor_theme ~= "" then
    hl.env("XCURSOR_THEME", cursor_theme)
    hl.env("XCURSOR_SIZE", "24")
end

hl.config({
    input = {
        kb_layout = kb_layout,     -- por defecto; input.lua lo pisa si existe
        kb_variant = kb_variant,
    },

    misc = {
        disable_hyprland_logo = true,
        disable_splash_rendering = true,
        force_default_wallpaper = 0,
    },

    decoration = {
        blur = { enabled = false },
        shadow = { enabled = false },
    },

    animations = {
        enabled = false,
    },
})

-- DESPUÉS del hl.config de arriba: los hl.config se acumulan y el último gana,
-- así que el teclado generado tiene que llegar el último.
pcall(dofile, STATE .. "/input.lua")
-- Cursor elegido por el usuario (lo escribe el bridge en cada cambio). Igual
-- que input.lua: llega el último para pisar el defecto del entorno.
pcall(dofile, STATE .. "/cursor.lua")

-- greeter surface + compositor lifetime tied to qs. La forma clásica
-- `hyprctl dispatch exit` NO funciona en roots Lua.
hl.on("hyprland.start", function()
    hl.exec_cmd("sh -c \"qs -p " .. QML .. "; hyprctl dispatch 'hl.dsp.exit()'\"")
end)
