#!/usr/bin/env bash
# ============================================================================
#  Vexyon installer
#  Installs dependencies and deploys the shell into the standard locations:
#    config/vexyon  -> ~/.config/vexyon
#    config/hypr    -> ~/.config/hypr        (an existing hyprland.lua is backed up)
#    share/vexyon   -> ~/.local/share/vexyon
#    config/vexyon/bin/* -> ~/.local/bin
#  Idempotent; safe to re-run to update.
#
#  Salida: en pantalla solo un paso por línea (spinner + ✓/✗); el detalle
#  completo de cada comando (pacman incluido) va a /tmp/vexyon-install.log.
#  Si un paso obligatorio falla, el instalador PARA, lo dice en rojo y
#  enseña las últimas líneas del log. ANSI puro — sin dependencias extra.
# ============================================================================
set -Eeuo pipefail

SRC="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# El uploader web de GitHub (drag & drop) QUITA el bit ejecutable — todo llega
# como 100644 venga como venga. Re-asegurar +x ANTES de que nada los invoque,
# acotado a config/vexyon/bin: ese directorio contiene SOLO helpers ejecutables
# (install.sh ejecuta vexyon-gpu-detect directamente desde el repo; el resto se
# despliega con +x vía link_helpers / install -Dm755). Nada más lo necesita:
# QML/confs/JSON se copian como datos y el bridge se invoca con `python3`.
chmod +x "$SRC"/config/vexyon/bin/* 2>/dev/null || true

# --- Log --------------------------------------------------------------------
LOG="/tmp/vexyon-install.log"
if ! { : > "$LOG"; } 2>/dev/null; then
  # p.ej. un run previo con sudo dejó el fichero de root
  LOG="$(mktemp /tmp/vexyon-install.XXXXXX.log)"
fi
{ echo "Vexyon install — $(date)"; uname -a; echo; } >> "$LOG"

# --- Presentación (colores solo en TTY, NO_COLOR respetado) -----------------
if [ -t 1 ] && [ -z "${NO_COLOR:-}" ]; then
  TTY=1
  C_A=$'\033[1;35m'  # acento (magenta Vexyon)
  C_G=$'\033[1;32m'  # éxito
  C_R=$'\033[1;31m'  # error
  C_Y=$'\033[1;33m'  # aviso
  C_D=$'\033[2m'     # secundario
  C_B=$'\033[1m'     # negrita
  C_0=$'\033[0m'
else
  TTY=0
  C_A='' C_G='' C_R='' C_Y='' C_D='' C_B='' C_0=''
fi

WARNINGS=0
SUMMARY=()

note() { printf '  %s·%s %s\n' "$C_D" "$C_0" "$*"; }
ok()   { printf '  %s✓%s %s\n' "$C_G" "$C_0" "$*"; }
warn() {
  printf '  %s!%s %s%s%s\n' "$C_Y" "$C_0" "$C_Y" "$*" "$C_0"
  WARNINGS=$((WARNINGS + 1))
  echo "WARN: $*" >> "$LOG"
}

section() {
  local t=" $* " line n
  n=$(( 56 - ${#t} )); [ "$n" -lt 3 ] && n=3
  line="$(printf '─%.0s' $(seq 1 "$n"))"
  printf '\n%s──%s%s%s%s%s\n' "$C_A" "$C_0$C_B" "$t" "$C_0" "$C_A$line" "$C_0"
  printf '\n===== %s =====\n' "$*" >> "$LOG"
}

die() {
  printf '\n  %s✗ %s%s\n' "$C_R" "$*" "$C_0"
  if [ -s "$LOG" ]; then
    printf '  %sLast log lines:%s\n' "$C_D" "$C_0"
    tail -n 12 "$LOG" | sed "s/^/  ${C_D}│${C_0} /"
  fi
  printf '  %sFull output: %s%s\n' "$C_D" "$LOG" "$C_0"
  exit 1
}

# _run <fatal|soft> <label> <hint-si-falla> <cmd...>
#   Ejecuta cmd con la salida entera en $LOG; en pantalla, spinner + ✓/✗.
#   fatal → die (para el instalador); soft → warn y sigue.
_run() {
  local mode="$1" label="$2" hint="$3" rc=0
  shift 3
  printf '\n>>> %s\n' "$label" >> "$LOG"
  if [ "$TTY" = 1 ]; then
    ( trap - ERR; "$@" ) >> "$LOG" 2>&1 &
    local pid=$! i=0
    local f=('⠋' '⠙' '⠹' '⠸' '⠼' '⠴' '⠦' '⠧' '⠇' '⠏')
    printf '\033[?25l'
    while kill -0 "$pid" 2>/dev/null; do
      printf '\r  %s%s%s %s' "$C_A" "${f[i % 10]}" "$C_0" "$label"
      i=$((i + 1))
      sleep 0.08
    done
    wait "$pid" || rc=$?
    printf '\033[?25h'
    if [ "$rc" -eq 0 ]; then
      printf '\r  %s✓%s %s\n' "$C_G" "$C_0" "$label"
    else
      printf '\r  %s✗%s %s\n' "$C_R" "$C_0" "$label"
    fi
  else
    ( trap - ERR; "$@" ) >> "$LOG" 2>&1 || rc=$?
    if [ "$rc" -eq 0 ]; then printf '  ✓ %s\n' "$label"; else printf '  ✗ %s\n' "$label"; fi
  fi
  if [ "$rc" -ne 0 ]; then
    if [ "$mode" = fatal ]; then
      die "\"$label\" failed (exit $rc)."
    else
      warn "$label failed${hint:+ — $hint}"
    fi
  fi
}
step()     { _run fatal "$1" "" "${@:2}"; }   # obligatorio: si falla, para
try_step() { _run soft "$1" "$2" "${@:3}"; }  # opcional: si falla, avisa y sigue

cleanup() {
  [ -n "${SUDO_PID:-}" ] && kill "$SUDO_PID" 2>/dev/null || true
  [ "$TTY" = 1 ] && printf '\033[?25h' || true
}
trap cleanup EXIT
trap 'st=$?; printf "\n  %s✗ Install aborted (exit %s) at: %s%s\n" "$C_R" "$st" "$BASH_COMMAND" "$C_0"; printf "  %sFull output: %s%s\n" "$C_D" "$LOG" "$C_0"' ERR

# --- Banner -----------------------------------------------------------------
printf '\n'
printf '  %s╭───╮%s\n' "$C_A" "$C_0"
printf '  %s│ V │%s  %sVexyon%s — desktop shell for Hyprland\n' "$C_A" "$C_0" "$C_B" "$C_0"
printf '  %s╰───╯%s  %sinstaller · full log: %s%s\n' "$C_A" "$C_0" "$C_D" "$LOG" "$C_0"

# --- Privileges -------------------------------------------------------------
SUDO_PID=""
if [ "$(id -u)" -ne 0 ]; then
  command -v sudo >/dev/null 2>&1 || die "sudo is required (packages, /etc/pam.d, greetd)."
  printf '\n'
  note "Some steps need administrator rights — sudo may ask for your password now."
  sudo -v || die "sudo authentication failed."
  # Mantener la credencial viva durante pasos largos (pacman en mirror lento)
  ( while sudo -n true 2>/dev/null; do sleep 50; done ) &
  SUDO_PID=$!
fi

# --- Dependencies ----------------------------------------------------------
PKGS=(
  hyprland quickshell jq hyprsunset ghostty fish
  python python-pillow
  qt6-base qt6-declarative qt6-svg
  # xdg-desktop-portal-gtk: backend del portal Settings (fallback declarado en
  # hyprland-portals.conf) — expone org.freedesktop.appearance color-scheme
  # para que apps y navegadores sigan el modo claro/oscuro del tema activo.
  polkit-kde-agent xdg-desktop-portal-hyprland xdg-desktop-portal-gtk
  cliphist wl-clipboard grim libnotify
  networkmanager pipewire wireplumber pipewire-pulse
  brightnessctl ttf-jetbrains-mono-nerd noto-fonts noto-fonts-emoji
  papirus-icon-theme fastfetch
  zip unzip glib2 xdg-utils
  # udisks2: servicio estándar de medios extraíbles (el que usan
  # Nautilus/Dolphin/Thunar). D-Bus-activado: no se habilita nada, arranca
  # solo cuando el gestor de ficheros lo llama. Sin él no hay automontaje
  # de USB/SSD externos con permisos correctos y sin sudo.
  udisks2
  sshfs openssh
)

# Wallpaper daemon: upstream renamed `swww` to `awww` (Arch extra y CachyOS ya
# solo empaquetan awww, que hace Provides=swww). Instalar el que exista para
# soportar mirrors antiguos sin depender del resolvedor de providers.
if command -v pacman >/dev/null 2>&1; then
  if pacman -Si awww >/dev/null 2>&1; then PKGS+=(awww); else PKGS+=(swww); fi
else
  PKGS+=(awww)
fi

section "Dependencies"
if [ "${VEXYON_SKIP_PKGS:-0}" = "1" ]; then
  note "VEXYON_SKIP_PKGS=1 — skipping package install"
elif command -v pacman >/dev/null 2>&1; then
  missing=()
  while IFS= read -r p; do [ -n "$p" ] && missing+=("$p"); done \
    < <(pacman -T "${PKGS[@]}" || true)
  if [ "${#missing[@]}" -eq 0 ]; then
    ok "All ${#PKGS[@]} packages already installed"
    SUMMARY+=("Dependencies: all ${#PKGS[@]} packages already present")
  else
    note "${#missing[@]} of ${#PKGS[@]} packages to install:"
    printf '%s\n' "${missing[*]}" | fold -s -w 62 | sed "s/^/      ${C_D}/;s/\$/${C_0}/"
    step "Installing ${#missing[@]} packages (pacman)" \
      sudo pacman -S --noconfirm --needed "${missing[@]}"
    SUMMARY+=("Dependencies: ${#missing[@]} packages installed (${#PKGS[@]} total)")
  fi
else
  warn "pacman not found — install these manually: ${PKGS[*]}"
fi

# --- System integration -----------------------------------------------------
section "System integration"

# PAM config for the lock screen.
# NOTE: rsync-only deploys never touch /etc, so the lock screen's PAM service
# can go missing there. The file is also shipped into the deploy tree
# (~/.config/vexyon/pam/vexyon) and can be (re)installed any time with the
# helper `vexyon-lock-pam-setup`.
if [ -f "$SRC/config/pam/vexyon" ]; then
  try_step "PAM config for the lock screen (/etc/pam.d/vexyon)" \
    "run 'vexyon-lock-pam-setup' later" \
    sudo install -Dm644 "$SRC/config/pam/vexyon" /etc/pam.d/vexyon
fi

# Polkit rule for the power menu. Sin esto, Suspender/Reiniciar/Apagar fallan
# con "interactive authentication required": el shell lanza el comando
# desatendido (execDetached hace setsid) y polkit no puede pedir contraseña.
# La regla concede las acciones de energía de login1 al grupo `wheel`.
if [ -f "$SRC/config/polkit/49-vexyon-power.rules" ]; then
  try_step "Polkit power rule (/etc/polkit-1/rules.d)" \
    "power menu may ask for a password" \
    sudo install -Dm644 "$SRC/config/polkit/49-vexyon-power.rules" \
      /etc/polkit-1/rules.d/49-vexyon-power.rules
  if ! id -nG "$USER" 2>/dev/null | tr ' ' '\n' | grep -qx wheel; then
    warn "User $USER is not in the 'wheel' group — the power menu will ask for"
    warn "a password. Add it with:  sudo usermod -aG wheel $USER"
  fi
fi

# Notification daemon guard: only one process may own
# org.freedesktop.Notifications. Stop/disable rivals so the Vexyon
# notification service can claim it cleanly.
for svc in mako dunst swaync; do
  if pgrep -x "$svc" >/dev/null 2>&1; then
    warn "Stopping rival notification daemon: $svc"
    pkill -x "$svc" || true
  fi
  systemctl --user disable --now "$svc.service" >/dev/null 2>&1 || true
done

# --- Shell files ------------------------------------------------------------
section "Shell files"
mkdir -p "$HOME/.config/vexyon" "$HOME/.config/hypr" \
         "$HOME/.local/share/vexyon" "$HOME/.local/bin" \
         "$HOME/Pictures/Wallpapers" "$HOME/Pictures/Screenshots"

# Upgrade path: Vexyon used to generate a hyprlang (.conf) config set. Hyprland
# >= 0.55 prefers hyprland.lua and 0.57 drops hyprlang entirely, so retire our
# old .conf files instead of leaving them to rot next to the Lua ones. Only
# files carrying the VEXYON marker (or our generated header) are touched.
retire_conf() {
  local f stamp; stamp=$(date +%s)
  for f in hyprland.conf vexyon-env.conf vexyon-rules.conf vexyon-monitors.conf \
           vexyon-keybinds.conf vexyon-settings.conf vexyon-gpu.conf; do
    [ -f "$HOME/.config/hypr/$f" ] || continue
    grep -qi "vexyon" "$HOME/.config/hypr/$f" 2>/dev/null || continue
    mv "$HOME/.config/hypr/$f" "$HOME/.config/hypr/$f.pre-lua.$stamp"
  done
}
retire_conf
# Same for a non-Vexyon hyprland.lua (Hyprland >= 0.55 prefers .lua when it
# exists, so an alien one would shadow Vexyon's config entirely).
if [ -f "$HOME/.config/hypr/hyprland.lua" ] && \
   ! grep -q "VEXYON" "$HOME/.config/hypr/hyprland.lua" 2>/dev/null; then
  bak="$HOME/.config/hypr/hyprland.lua.pre-vexyon.$(date +%s)"
  warn "Backing up existing hyprland.lua -> $bak"
  cp "$HOME/.config/hypr/hyprland.lua" "$bak"
fi

# Deploy the code tree but PRESERVE the user's shell.json on re-runs: the
# blanket cp would clobber their settings with the repo seed (the seed-if-
# absent guard below never fired because the cp had already replaced it).
deploy_trees() {
  local user_cfg=""
  if [ -s "$HOME/.config/vexyon/shell.json" ]; then
    user_cfg="$(mktemp)"
    cp "$HOME/.config/vexyon/shell.json" "$user_cfg"
  fi
  cp -r "$SRC/config/vexyon/." "$HOME/.config/vexyon/"
  # bytecode cache del working copy del repo — no desplegarlo
  rm -rf "$HOME/.config/vexyon/bridge/__pycache__"
  if [ -n "$user_cfg" ]; then
    mv "$user_cfg" "$HOME/.config/vexyon/shell.json"
  fi
  cp -r "$SRC/config/hypr/."   "$HOME/.config/hypr/"
  cp -r "$SRC/config/fish/."   "$HOME/.config/fish/"
  cp -r "$SRC/share/vexyon/."  "$HOME/.local/share/vexyon/"
  # Seed default config if absent (never overwrite a user's edited one)
  if [ ! -s "$HOME/.config/vexyon/shell.json" ]; then
    cp "$SRC/config/vexyon/shell.json" "$HOME/.config/vexyon/shell.json"
  fi
}
step "Deploying shell to ~/.config and ~/.local/share/vexyon" deploy_trees

link_helpers() {
  local f
  for f in "$HOME/.config/vexyon/bin/"*; do
    [ -f "$f" ] || continue
    chmod +x "$f"
    ln -sf "$f" "$HOME/.local/bin/$(basename "$f")"
  done
  chmod +x "$HOME/.config/vexyon/bridge/vexyon-bridge.py"

  # ~/.local/bin en el PATH de las shells interactivas: el shell objetivo es
  # Fish → fish_add_path en config.fish, idempotente (guard por grep, sin
  # duplicar en re-runs; deploy_trees no pisa config.fish — el repo solo trae
  # conf.d/). Los binds de Hyprland (Super+B) NO pasan por fish: su PATH lo
  # cubre vexyon-start (export al arrancar la sesión).
  local fish_cfg="$HOME/.config/fish/config.fish"
  mkdir -p "$HOME/.config/fish"
  [ -f "$fish_cfg" ] || : > "$fish_cfg"
  if ! grep -Eq 'fish_add_path[^#]*\.local/bin' "$fish_cfg"; then
    printf '\n# Vexyon: helper scripts (~/.local/bin) en PATH\nfish_add_path %s/.local/bin\n' "$HOME" >> "$fish_cfg"
  fi
}
step "Linking helper scripts into ~/.local/bin" link_helpers
SUMMARY+=("Shell deployed to ~/.config/vexyon (existing shell.json preserved)")

# Distribución de teclado: Hyprland NO hereda la elegida en el instalador del
# sistema (por defecto "us"). Si shell.json aún no tiene la clave, sembrarla
# desde la config del OS (X11/localectl o vconsole); a partir de ahí manda
# Ajustes → Comportamiento (behavior.keyboardLayout, aplicada por el bridge).
if ! jq -e '.behavior.keyboardLayout' "$HOME/.config/vexyon/shell.json" >/dev/null 2>&1; then
  kb=""
  if [ -f /etc/X11/xorg.conf.d/00-keyboard.conf ]; then
    kb=$(awk -F'"' 'toupper($0) ~ /XKBLAYOUT/ { print $4; exit }' /etc/X11/xorg.conf.d/00-keyboard.conf | cut -d, -f1)
  fi
  if [ -z "$kb" ] && [ -f /etc/vconsole.conf ]; then
    kb=$(sed -n 's/^XKBLAYOUT=//p' /etc/vconsole.conf | tr -d '"' | cut -d, -f1)
    if [ -z "$kb" ]; then
      # KEYMAP de consola: el prefijo suele coincidir con el layout XKB
      # (es, de-latin1 → de); uk es la excepción (XKB usa gb)
      kb=$(sed -n 's/^KEYMAP=//p' /etc/vconsole.conf | tr -d '"' | cut -d- -f1)
      [ "$kb" = "uk" ] && kb=gb
    fi
  fi
  case "$kb" in
    latam|ara|[a-z][a-z]) : ;;   # códigos XKB plausibles; el resto se descarta
    *) kb="" ;;
  esac
  if [ -n "$kb" ] && [ "$kb" != "us" ]; then
    tmp_kb=$(mktemp)
    if jq --arg kb "$kb" '.behavior.keyboardLayout = $kb' \
         "$HOME/.config/vexyon/shell.json" > "$tmp_kb" 2>/dev/null && [ -s "$tmp_kb" ]; then
      mv "$tmp_kb" "$HOME/.config/vexyon/shell.json"
      note "Keyboard layout seeded from the system: $kb (Settings → Behavior to change)"
    else
      rm -f "$tmp_kb"
    fi
  fi
fi

# Teclas multimedia: instalaciones previas conservan su shell.json (no se
# pisa), así que los binds nuevos de volumen/brillo/media no llegarían nunca.
# Sembrar UNA vez cada bind de categoría "Media" de los defaults cuyo id no
# exista aún — sin tocar nada más y saltando combos que el usuario ya use.
seed_media_keybinds() {
  python3 - "$HOME/.config/vexyon/shell.json" \
             "$HOME/.local/share/vexyon/defaults/keybinds.json" <<'PYEOF'
import json, os, sys
sj, dk = sys.argv[1], sys.argv[2]
cfg = json.load(open(sj))
defaults = json.load(open(dk))
kbs = cfg.setdefault("keybinds", [])
have_ids = {k.get("id") for k in kbs}
combos = {(tuple(sorted(k.get("mods", []))), k.get("key")) for k in kbs}
added = []
for k in defaults:
    if k.get("category") != "Media" or k.get("id") in have_ids:
        continue
    if (tuple(sorted(k.get("mods", []))), k.get("key")) in combos:
        continue  # el usuario ya usa esa tecla para otra cosa
    kbs.append(k)
    added.append(k["id"])
if added:
    tmp = sj + ".tmp"
    with open(tmp, "w") as f:
        json.dump(cfg, f, indent=2, ensure_ascii=False)
        f.write("\n")
    os.replace(tmp, sj)
    print("seeded: " + ", ".join(added))
PYEOF
}
try_step "Seeding multimedia keybinds (volume/brightness/media keys)" \
  "shell.json unreadable — skipped" \
  seed_media_keybinds

# --- Theme & config generation ---------------------------------------------
section "Theme & config generation"

# Pre-genera el fondo por defecto del tema activo para que el primer arranque
# nunca quede sin fondo (el seed behavior.wallpaper = "vexyon:default" hace
# que el servicio Wallpaper lo aplique al entrar en sesión; aquí solo se
# calienta el cache). Fuera de sesión el generador cae a 2560x1440; al primer
# login se regenera a la resolución real del monitor (clave distinta de cache).
try_step "Pre-generating the default wallpaper" \
  "python-pillow missing? — will retry at login" \
  python3 "$HOME/.config/vexyon/bin/vexyon-wallpaper-gen"

try_step "Generating Hyprland keybinds/settings from shell.json" \
  "ok if not in a session yet" \
  python3 "$HOME/.config/vexyon/bridge/vexyon-bridge.py" --oneshot

# --- GPU: pin DINÁMICO del shell a la GPU integrada -------------------------
# Requisito: en híbridas (iGPU + Nvidia) el shell corre SIEMPRE en la iGPU y
# la dGPU duerme; al conectar en caliente un monitor externo cableado a la
# dGPU la sesión reacciona SOLA (sin reboot ni re-login): udev dispara
# vexyon-gpu-hotplug, que levanta el pin y reinicia únicamente el compositor
# (vexyon-start lo relanza dentro de la MISMA sesión de login; el greeter lo
# respawnea greetd). Al desenchufar, el mismo camino vuelve al pin de iGPU.
# La decisión vive en config/vexyon/bin/vexyon-gpu-detect (COMPARTIDA entre
# este instalador y el handler): sysfs, boot_vga/vendor ranking, Nvidia nunca
# candidata, y estado de conectores para el modo actual.
#
# El número /dev/dri/cardN NO es estable entre boots y las rutas by-path
# llevan ':' — ilegal en AQ_DRM_DEVICES (separador). Solución de la wiki de
# Hyprland: regla udev con symlink estable por slot PCI /dev/dri/vexyon-igpu.
#
# El pin es SOLO del entorno de la sesión: prime-run/DRI_PRIME del usuario
# siguen funcionando (prime-run pisa las tres vars de Nvidia por aplicación).
section "GPU"
GPU_LINK="${VEXYON_GPU_LINK:-/dev/dri/vexyon-igpu}"
GPU_RULE=/etc/udev/rules.d/90-vexyon-gpu.rules
GPU_HOT_RULE=/etc/udev/rules.d/91-vexyon-gpu-hotplug.rules
GPU_LUA="$HOME/.config/hypr/vexyon-gpu.lua"
GPU_DETECT="$SRC/config/vexyon/bin/vexyon-gpu-detect"

# NUNCA eval-ear la salida a ciegas: si detect falla (p.ej. sin +x tras un
# upload web, sysfs raro), el subshell hereda el trap ERR (set -E) y su banner
# "✗ Install aborted (exit N)…" sale por STDOUT → eval lo parsearía como
# código ("error de sintaxis cerca de `('" — el crash real reportado).
# Comprobar rc + salida no vacía; el pin de GPU no es critical-path.
gpu_rc=0
gpu_env="$("$GPU_DETECT" env 2>>"$LOG")" || gpu_rc=$?
if [ "$gpu_rc" -eq 0 ] && [ -n "$gpu_env" ]; then
  eval "$gpu_env"   # VEXYON_GPU_MODE/_WHY/_SLOT/_CARD/_NAME/_NVIDIA
  # El conf se escribe ANTES de instalar reglas: el `udevadm trigger` de abajo
  # dispara el handler, que compara contra este conf y sale sin hacer nada.
  "$GPU_DETECT" lua > "$GPU_LUA"
else
  warn "GPU: vexyon-gpu-detect failed (exit $gpu_rc) — GPU pinning skipped, default device selection will be used"
  VEXYON_GPU_MODE=detect-failed
  VEXYON_GPU_WHY="vexyon-gpu-detect failed (exit $gpu_rc)"
  VEXYON_GPU_NVIDIA=0
  {
    echo "-- Vexyon — GPU pin (GENERATED; do not edit — managed by install.sh and"
    echo "-- vexyon-gpu-hotplug, which rewrites it on iGPU/dGPU display hotplug)"
    echo "-- No GPU pin: $VEXYON_GPU_WHY"
  } > "$GPU_LUA"
fi

case "$VEXYON_GPU_MODE" in
  pin|nopin-external)
    install_gpu_dynamic() {
      sudo install -Dm755 "$GPU_DETECT" /usr/local/bin/vexyon-gpu-detect
      sudo install -Dm755 "$SRC/config/vexyon/bin/vexyon-gpu-hotplug" /usr/local/bin/vexyon-gpu-hotplug
      printf 'SUBSYSTEM=="drm", SUBSYSTEMS=="pci", KERNEL=="card[0-9]*", KERNELS=="%s", SYMLINK+="dri/vexyon-igpu"\n' \
        "$VEXYON_GPU_SLOT" | sudo tee "$GPU_RULE" >/dev/null
      # Reacción al hotplug: un cambio de conectores en CUALQUIER card corre
      # el handler (one-shot, con el $HOME del usuario horneado). Sin filtro
      # HOTPLUG: el handler es barato e idempotente, mejor no perder eventos.
      printf 'ACTION=="change", SUBSYSTEM=="drm", KERNEL=="card[0-9]*", RUN+="/usr/local/bin/vexyon-gpu-hotplug %s"\n' \
        "$HOME" | sudo tee "$GPU_HOT_RULE" >/dev/null
      sudo udevadm control --reload
      sudo udevadm trigger /sys/class/drm/"$VEXYON_GPU_CARD"   # crea el symlink ya
      udevadm settle --timeout=5 2>/dev/null || true
      [ -e "$GPU_LINK" ]
    }
    try_step "GPU pin + hotplug handler ($GPU_LINK -> $VEXYON_GPU_NAME @ $VEXYON_GPU_SLOT)" \
      "pin skipped this run" install_gpu_dynamic
    if [ -e "$GPU_LINK" ]; then
      if [ "$VEXYON_GPU_MODE" = pin ]; then
        SUMMARY+=("GPU: shell pinned to the integrated $VEXYON_GPU_NAME GPU ($VEXYON_GPU_SLOT); display hotplug handled by udev")
      else
        note "GPU: a display is connected to the discrete GPU right now — pin lifted for this state"
        SUMMARY+=("GPU: external display on the discrete GPU — pin lifted; reverts automatically on unplug")
      fi
    else
      # sin symlink, un pin dejaría la sesión sin GPU: degradar
      {
        echo "-- Vexyon — GPU pin (GENERATED; do not edit — managed by install.sh and"
        echo "-- vexyon-gpu-hotplug, which rewrites it on iGPU/dGPU display hotplug)"
        echo "-- No GPU pin: udev symlink $GPU_LINK did not appear — pin skipped to avoid a session with no GPU"
      } > "$GPU_LUA"
      SUMMARY+=("GPU: no pin (udev symlink $GPU_LINK did not appear)")
    fi
    ;;
  static-nvidia)
    warn "GPU: displays run on the Nvidia dGPU — iGPU pin skipped (shell will use the dGPU)"
    SUMMARY+=("GPU: no pin ($VEXYON_GPU_WHY)")
    ;;
  static-none)
    warn "GPU: could not identify an integrated GPU — pin skipped"
    SUMMARY+=("GPU: no pin ($VEXYON_GPU_WHY)")
    ;;
  detect-failed)
    # aviso ya emitido arriba; NO tocar reglas udev existentes (el fallo puede
    # ser transitorio y una híbrida ya instalada no debe perder su pin)
    SUMMARY+=("GPU: no pin ($VEXYON_GPU_WHY)")
    ;;
  *)
    note "GPU: single GPU (or none) — no pin needed, no hotplug machinery installed"
    SUMMARY+=("GPU: no pin ($VEXYON_GPU_WHY)")
    ;;
esac
if [[ "$VEXYON_GPU_MODE" == static-* ]]; then
  # reglas rancias de un hardware anterior: fuera (el symlink dejaría de casar
  # y el handler de hotplug no pinta nada en una máquina no híbrida)
  sudo rm -f "$GPU_RULE" "$GPU_HOT_RULE" /usr/local/bin/vexyon-gpu-hotplug
  sudo udevadm control --reload
fi

# --- Greeter (greetd) -------------------------------------------------------
# Pantalla de login gráfica de Vexyon: greetd + Hyprland kiosco + greeter
# Quickshell propio. Corre ANTES de la sesión de usuario (como el usuario
# `greeter`), así que todo lo que necesita vive en /etc/greetd/vexyon-greeter:
#   shell.qml      el greeter (Quickshell.Services.Greetd)
#   hyprland.lua   compositor kiosco que lo lanza (Lua root, Hyprland >= 0.55)
#   theme.json     snapshot estático del tema — propiedad del usuario: el
#                  bridge lo re-sincroniza solo al cambiar de tema (manual:
#                  vexyon-greeter-sync-theme)
#   greeter.json   usuario por defecto
# Desactivable con VEXYON_GREETER=0 (deja el login por TTY/lo que hubiera).
if [ "${VEXYON_GREETER:-1}" != "0" ]; then
  section "Login screen (greetd)"
  if command -v pacman >/dev/null 2>&1; then
    if ! pacman -Q greetd >/dev/null 2>&1; then
      step "Installing greetd (pacman)" sudo pacman -S --noconfirm --needed greetd
    fi
  fi
  # theme snapshot: el tema activo del usuario si existe; si no, el seed
  greeter_theme="$SRC/config/greeter/theme.json"
  active_theme=$(jq -r '.theme.active // empty' "$HOME/.config/vexyon/shell.json" 2>/dev/null || true)
  if [ -n "$active_theme" ] && [ -f "$HOME/.local/share/vexyon/themes/$active_theme.json" ]; then
    greeter_theme="$HOME/.local/share/vexyon/themes/$active_theme.json"
  fi
  # idioma del greeter: el del shell (appearance.language); default inglés
  greeter_lang=$(jq -r '.appearance.language // "en"' "$HOME/.config/vexyon/shell.json" 2>/dev/null || echo en)
  [ "$greeter_lang" = "es" ] || greeter_lang="en"
  # teclado del greeter = el de la sesión (la contraseña debe teclearse igual)
  greeter_kb=$(jq -r '.behavior.keyboardLayout // "us"' "$HOME/.config/vexyon/shell.json" 2>/dev/null || echo us)
  case "$greeter_kb" in latam|ara|[a-z][a-z]) : ;; *) greeter_kb=us ;; esac
  # config.toml de greetd: respeta uno ajeno (backup), instala el de Vexyon
  if [ -f /etc/greetd/config.toml ] && ! grep -q "Vexyon greeter" /etc/greetd/config.toml; then
    warn "Backing up existing /etc/greetd/config.toml -> config.toml.pre-vexyon"
    sudo cp /etc/greetd/config.toml /etc/greetd/config.toml.pre-vexyon
  fi
  install_greeter() {
    # Kiosco en Lua (greetd lanza --config .../hyprland.lua). El fichero va TAL
    # CUAL: el teclado ya no se parchea con sed dentro de él, sino que sale de
    # input.lua, un fragmento generado aparte que el kiosco carga con dofile —
    # igual que el pin de GPU. Así la config del kiosco es inmutable y solo los
    # dos fragmentos generados cambian en caliente.
    sudo install -Dm644 "$SRC/config/greeter/shell.qml" /etc/greetd/vexyon-greeter/shell.qml
    printf -- '-- Vexyon — greeter input (GENERATED by install.sh)\nhl.config({ input = { kb_layout = "%s" } })\n' \
      "$greeter_kb" | sudo tee /etc/greetd/vexyon-greeter/input.lua >/dev/null
    # El kiosco usa el MISMO pin de GPU que la sesión, como fichero APARTE
    # (hyprland-greeter.lua lo requiere): vexyon-gpu-hotplug lo reescribe en
    # caliente sin tocar el resto de la config del kiosco. Siempre existe —
    # en máquinas de una GPU es un comentario informativo.
    sudo install -Dm644 "$GPU_LUA" /etc/greetd/vexyon-greeter/vexyon-gpu.lua
    # Restos de instalaciones anteriores a la migración Lua: ya no los lee nadie
    sudo rm -f /etc/greetd/vexyon-greeter/hyprland.conf \
               /etc/greetd/vexyon-greeter/vexyon-gpu.conf
    sudo install -Dm644 "$SRC/config/greeter/hyprland-greeter.lua" \
      /etc/greetd/vexyon-greeter/hyprland.lua
    # theme.json queda PROPIEDAD DEL USUARIO (el dir sigue siendo de root):
    # así el bridge lo re-sincroniza solo en cada cambio de tema, sin sudo y
    # sin demonios nuevos. Solo contiene colores; el greeter lo parsea con
    # fallback, un contenido raro como mucho re-colorea el login.
    sudo install -Dm644 -o "$USER" "$greeter_theme" /etc/greetd/vexyon-greeter/theme.json
    printf '{ "user": "%s", "lang": "%s" }\n' "$USER" "$greeter_lang" | sudo tee /etc/greetd/vexyon-greeter/greeter.json >/dev/null
    sudo install -Dm644 "$SRC/config/greetd/config.toml" /etc/greetd/config.toml
    # Sesión Vexyon: vexyon-start en un PATH de sistema (el Exec= de un .desktop
    # de sesión no puede depender de ~/.local/bin) + entrada en wayland-sessions
    # para que el greeter la ofrezca. vexyon-start pasa por start-hyprland
    # (watchdog de Hyprland >= 0.51) — sin el aviso de binario lanzado a pelo.
    sudo install -Dm755 "$SRC/config/vexyon/bin/vexyon-start" /usr/local/bin/vexyon-start
    sudo install -Dm644 "$SRC/config/greetd/vexyon.desktop" /usr/share/wayland-sessions/vexyon.desktop
  }
  step "Installing greeter files (/etc/greetd, wayland-sessions)" install_greeter
  # greetd sustituye a getty en el VT1 (Conflicts=getty@tty1 en su unit).
  # Si tenías autologin en tty1, deja de aplicar: el login pasa por el greeter.
  step "Enabling greetd.service" sudo systemctl enable greetd.service
  SUMMARY+=("Login screen: greetd enabled — the Vexyon greeter appears on next boot")
else
  note "VEXYON_GREETER=0 — login screen left untouched"
fi

# --- Summary ----------------------------------------------------------------
section "Done"
for s in "${SUMMARY[@]}"; do ok "$s"; done
if command -v fish >/dev/null 2>&1 && [ "${SHELL##*/}" != "fish" ]; then
  note "Fish is installed. Set it as your login shell with:  chsh -s $(command -v fish)"
fi
if [ "$WARNINGS" -gt 0 ]; then
  warn "$WARNINGS warning(s) above — details in $LOG"
fi

printf '\n  %sNext steps%s\n' "$C_B" "$C_0"
note 'Reboot — the Vexyon login screen appears; pick the "Vexyon" session and log in.'
note "Or start it from a TTY with:  vexyon-start"
if [ "${VEXYON_GPU_NVIDIA:-0}" = 1 ] && [ "${VEXYON_GPU_MODE:-}" = pin ]; then
  note "Verify the iGPU pin afterwards:  nvidia-smi  (no Hyprland/quickshell process expected)"
fi
printf '\n  %sFull install log: %s%s\n\n' "$C_D" "$LOG" "$C_0"
