{
  lib,
  stdenvNoCC,
  makeWrapper,
  bash,
  coreutils,
  findutils,
  gnugrep,
  gnused,
  util-linux,
  procps,
  jq,
  python3,
  grim,
  wl-clipboard,
  libnotify,
  xdg-utils,
  glib,
  hyprland,
  quickshell,
}:

let
  # El generador de fondos es Pillow puro; el resto de helpers son bash.
  pythonEnv = python3.withPackages (ps: [ ps.pillow ]);

  # PATH horneado en los wrappers. Los helpers los invocan Hyprland (binds),
  # udev (hotplug) y Quickshell (Process), entornos donde el PATH del usuario
  # no está garantizado — en Arch eso lo tapa `vexyon-start`, aquí se resuelve
  # de raíz.
  runtimeBin = lib.makeBinPath [
    bash
    coreutils
    findutils
    gnugrep
    gnused
    util-linux # flock, en el handler de hotplug
    procps # pgrep, idem
    jq
    pythonEnv
    grim
    wl-clipboard
    libnotify
    xdg-utils
    glib # gsettings, para el color-scheme del portal
    hyprland # hyprctl / start-hyprland
    quickshell # qs
  ];

  # Dónde vive el estado MUTABLE del greeter. /etc no sirve en NixOS: lo
  # gestiona Nix y son symlinks de solo lectura, pero el bridge reescribe el
  # tema ahí en cada cambio y vexyon-gpu-hotplug el pin de GPU. Constante a
  # propósito, no una opción del módulo: nadie necesita moverlo.
  greeterStateDir = "/var/lib/vexyon-greeter";
in
stdenvNoCC.mkDerivation (finalAttrs: {
  pname = "vexyon-shell";
  version = "0.1.0";

  src = lib.cleanSourceWith {
    src = ../.;
    filter =
      path: type:
      let
        rel = lib.removePrefix (toString ../. + "/") (toString path);
        top = lib.head (lib.splitString "/" rel);
      in
      !(lib.elem top [
        ".git"
        ".nixos-vm"
        "assets"
      ])
      && !(lib.hasSuffix ".pyc" rel)
      && baseNameOf path != "__pycache__";
  };

  nativeBuildInputs = [ makeWrapper ];

  dontConfigure = true;
  dontBuild = true;

  installPhase = ''
    runHook preInstall

    share=$out/share/vexyon

    # --- código QML del shell -------------------------------------------
    # Va al store, NO a ~/.config: en Arch conviven porque ahí el árbol
    # desplegado es a la vez código y config; aquí solo shell.json es del
    # usuario y el resto es inmutable.
    install -d $share/qml
    cp -r config/vexyon/shell.qml config/vexyon/components \
          config/vexyon/modules config/vexyon/services $share/qml/

    # --- greeter ---------------------------------------------------------
    install -d $share/greeter
    install -Dm644 config/greeter/shell.qml $share/greeter/shell.qml
    # El kiosco apunta al QML del store y al estado mutable de /var/lib. Las
    # dos constantes son las dos primeras líneas `local ... = "..."`.
    substitute config/greeter/hyprland-greeter.lua $share/greeter/hyprland.lua \
      --replace-fail 'local QML   = "/etc/greetd/vexyon-greeter"' \
                     "local QML   = \"$share/greeter\"" \
      --replace-fail 'local STATE = "/etc/greetd/vexyon-greeter"' \
                     'local STATE = "${greeterStateDir}"'
    # Paleta de arranque del greeter: si /var/lib aún no tiene snapshot, el
    # módulo copia esta.
    install -Dm644 config/greeter/theme.json $share/greeter/theme.json

    # --- raíces Lua de Hyprland -------------------------------------------
    # Se SIEMBRAN en ~/.config/hypr (no se enlazan): hyprland.lua hace
    # require() de los fragmentos que el bridge regenera, y esos son del
    # usuario. Van TODOS los .lua del repo, no solo los estáticos: hyprland.lua
    # los require() incondicionalmente, así que si vexyon-keybinds.lua o
    # vexyon-settings.lua faltan en el primer arranque, la config Lua aborta a
    # medias — Hyprland levanta, pero hyprland.start no llega a dispararse y la
    # sesión se queda sin shell. Los del repo son la semilla; el bridge los
    # reescribe en cuanto corre.
    install -d $share/hypr
    for f in config/hypr/*.lua; do
      install -Dm644 "$f" "$share/hypr/$(basename "$f")"
    done

    # --- datos de siembra -------------------------------------------------
    install -d $share/seed
    install -Dm644 config/vexyon/shell.json $share/seed/shell.json
    cp -r share/vexyon/themes share/vexyon/store share/vexyon/defaults $share/seed/

    # --- PAM y polkit (el módulo los consume; no se instalan desde aquí) ---
    install -Dm644 config/pam/vexyon $share/pam/vexyon
    install -Dm644 config/polkit/49-vexyon-power.rules \
      $share/polkit/49-vexyon-power.rules

    # --- helpers ----------------------------------------------------------
    install -d $out/bin
    for f in config/vexyon/bin/*; do
      install -Dm755 "$f" "$out/bin/$(basename "$f")"
    done
    install -Dm755 config/vexyon/bridge/vexyon-bridge.py $out/bin/vexyon-bridge

    patchShebangs $out/bin

    for f in $out/bin/*; do
      wrapProgram "$f" \
        --prefix PATH : "${runtimeBin}" \
        --set-default VEXYON_SHARE "$share" \
        --set-default VEXYON_BIN_DIR "$out/bin" \
        --set-default VEXYON_GREETER_STATE_DIR "${greeterStateDir}"
    done

    runHook postInstall
  '';

  passthru = {
    inherit greeterStateDir;
  };

  meta = {
    description = "Vexyon desktop shell for Hyprland, built on Quickshell";
    homepage = "https://github.com/vexyon/vexyon-shell";
    license = lib.licenses.mit;
    platforms = lib.platforms.linux;
  };
})
