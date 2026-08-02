self:
{
  config,
  lib,
  pkgs,
  ...
}:

let
  cfg = config.services.vexyon;
  vexyon = cfg.package;
  stateDir = vexyon.greeterStateDir; # /var/lib/vexyon-greeter

  # Agente polkit y portal: son libexec, no están en el PATH, y sus rutas
  # llevan el hash del store. hyprland.lua las lee del entorno (con la ruta de
  # Arch como defecto), así que se exportan en la sesión.
  polkitAgent = "${pkgs.kdePackages.polkit-kde-agent-1}/libexec/polkit-kde-authentication-agent-1";

  sessionEnv = {
    VEXYON_SHARE = "${vexyon}/share/vexyon";
    VEXYON_BIN_DIR = "${vexyon}/bin";
    VEXYON_QML_ROOT = "${vexyon}/share/vexyon/qml";
    VEXYON_GREETER_STATE_DIR = stateDir;
    VEXYON_POLKIT_AGENT = polkitAgent;
    # xdg-desktop-portal-hyprland lo arranca D-Bus/systemd vía xdg.portal:
    # vacío a propósito para que hyprland.lua NO lo lance por segunda vez.
    VEXYON_XDG_PORTAL_HYPRLAND = "";
  };

  envExports = lib.concatStringsSep "\n" (
    lib.mapAttrsToList (k: v: "export ${k}=${lib.escapeShellArg v}") sessionEnv
  );

  # Entrada de sesión: mismo papel que el vexyon.desktop de Arch, pero el Exec
  # apunta al store y exporta el entorno del port antes de arrancar.
  vexyonSession = pkgs.writeShellScript "vexyon-session" ''
    ${envExports}
    exec ${vexyon}/bin/vexyon-start "$@"
  '';

  sessionDesktop = pkgs.writeTextDir "share/wayland-sessions/vexyon.desktop" ''
    [Desktop Entry]
    Name=Vexyon
    Comment=Vexyon shell on Hyprland
    Exec=${vexyonSession}
    Type=Application
    DesktopNames=Hyprland
    Keywords=vexyon;hyprland;wayland;
  '';

  # Kiosco del greeter. Se exporta el mismo estado para que el greeter QML
  # encuentre theme.json/greeter.json en /var/lib.
  greeterSession = pkgs.writeShellScript "vexyon-greeter-session" ''
    export VEXYON_GREETER_STATE_DIR=${lib.escapeShellArg stateDir}
    exec ${pkgs.hyprland}/bin/Hyprland --config ${vexyon}/share/vexyon/greeter/hyprland.lua
  '';
in
{
  options.services.vexyon = {
    enable = lib.mkEnableOption "the Vexyon desktop shell";

    package = lib.mkOption {
      type = lib.types.package;
      default = self.packages.${pkgs.stdenv.hostPlatform.system}.vexyon-shell;
      defaultText = lib.literalMD "the flake's `vexyon-shell`";
      description = "The Vexyon shell package to use.";
    };

    user = lib.mkOption {
      type = lib.types.str;
      description = ''
        The user Vexyon belongs to. The greeter mirrors this user's theme,
        language and keyboard layout, and owns the mutable greeter state in
        ${stateDir} so the bridge can resync it without privilege escalation.
      '';
      example = "biel";
    };

    greeter.enable = lib.mkOption {
      type = lib.types.bool;
      default = true;
      description = ''
        Enable greetd with the Vexyon greeter as the login screen. The
        equivalent of the Arch installer's VEXYON_GREETER=0 escape hatch is
        setting this to false, which leaves login to whatever else is enabled.
      '';
    };

    gpu.pin = lib.mkOption {
      type = lib.types.bool;
      default = true;
      description = ''
        Install the udev rules that pin the session to the integrated GPU on
        hybrid machines and react to display hotplug. Harmless on single-GPU
        systems: vexyon-gpu-detect elects nothing and no symlink is created.
      '';
    };
  };

  config = lib.mkIf cfg.enable {
    assertions = [
      {
        assertion = config.users.users ? ${cfg.user};
        message = "services.vexyon.user is set to '${cfg.user}', which is not a defined user.";
      }
    ];

    # --- runtime -----------------------------------------------------------
    environment.systemPackages =
      [
        vexyon
        sessionDesktop
      ]
      ++ (with pkgs; [
        quickshell
        jq
        hyprsunset
        ghostty
        fish
        (python3.withPackages (ps: [ ps.pillow ]))
        kdePackages.polkit-kde-agent-1
        cliphist
        wl-clipboard
        grim
        libnotify
        brightnessctl
        fastfetch
        zip
        unzip
        glib
        xdg-utils
        sshfs
        awww
        # qt6: los trae quickshell como dependencia, pero qt6ct es el
        # QT_QPA_PLATFORMTHEME que fija vexyon-env.lua.
        kdePackages.qt6ct
      ]);

    # El .desktop de sesión NO llega solo a /run/current-system/sw: NixOS
    # enlaza una lista corta de subdirectorios de share/ y wayland-sessions no
    # está en ella salvo que haya un display manager de los suyos. El greeter
    # de Vexyon escanea ese directorio, así que hay que pedirlo explícitamente.
    environment.pathsToLink = [ "/share/wayland-sessions" ];

    fonts.packages = with pkgs; [
      nerd-fonts.jetbrains-mono
      noto-fonts
      noto-fonts-color-emoji
      papirus-icon-theme
    ];

    programs.hyprland.enable = true;
    programs.fish.enable = true;

    xdg.portal = {
      enable = true;
      extraPortals = [ pkgs.xdg-desktop-portal-gtk ];
      # xdg-desktop-portal-hyprland lo añade programs.hyprland.
    };

    services.udisks2.enable = true; # medios extraíbles (activado por D-Bus)
    networking.networkmanager.enable = lib.mkDefault true;
    security.polkit.enable = true;
    security.rtkit.enable = true;
    services.pipewire = {
      enable = lib.mkDefault true;
      pulse.enable = lib.mkDefault true;
      wireplumber.enable = lib.mkDefault true;
    };

    # --- PAM: pantalla de bloqueo -----------------------------------------
    # En Arch esto es un fichero copiado a /etc/pam.d/vexyon por el instalador
    # (y reparable con vexyon-lock-pam-setup). Aquí es declarativo: el stack
    # estándar del sistema, que es exactamente lo que hace `include system-auth`.
    security.pam.services.vexyon = { };

    # --- polkit: menú de energía ------------------------------------------
    # Misma regla que 49-vexyon-power.rules, en el formato que espera NixOS.
    security.polkit.extraConfig = ''
      // Vexyon — power menu. El shell lanza suspend/reboot/poweroff
      // desatendido (execDetached hace setsid), así que polkit no puede pedir
      // contraseña por sí mismo: se conceden las acciones de login1 a wheel.
      polkit.addRule(function(action, subject) {
        if (action.id.indexOf("org.freedesktop.login1.") === 0 &&
            subject.isInGroup("wheel")) {
          return polkit.Result.YES;
        }
      });
    '';

    # --- estado mutable del greeter ---------------------------------------
    # El problema central del port: en Arch estos ficheros viven en
    # /etc/greetd/vexyon-greeter y se reescriben en caliente (el bridge escribe
    # theme.json en cada cambio de tema, vexyon-gpu-hotplug el pin de GPU). En
    # NixOS /etc lo gestiona Nix y son symlinks de solo lectura, así que el
    # estado se muda aquí, con el dueño que hace que el bridge siga escribiendo
    # sin sudo — igual que el `install -o $USER` del instalador de Arch.
    systemd.tmpfiles.rules = lib.mkIf cfg.greeter.enable [
      "d ${stateDir} 0755 ${cfg.user} users - -"
      "C+ ${stateDir}/theme.json 0644 ${cfg.user} users - ${vexyon}/share/vexyon/greeter/theme.json"
      "f ${stateDir}/greeter.json 0644 ${cfg.user} users - {\"user\":\"${cfg.user}\",\"lang\":\"en\"}"
      "f ${stateDir}/input.lua 0644 ${cfg.user} users - hl.config({input={kb_layout=\"us\"}})"
      "f ${stateDir}/vexyon-gpu.lua 0644 ${cfg.user} users - -- Vexyon GPU pin (generated at runtime)"
    ];

    # --- greetd + greeter --------------------------------------------------
    # greetd.service es WantedBy=graphical.target, y un sistema sin display
    # manager arranca en multi-user.target — se quedaría inactivo para siempre.
    systemd.defaultUnit = lib.mkIf cfg.greeter.enable "graphical.target";

    services.greetd = lib.mkIf cfg.greeter.enable {
      enable = true;
      settings = {
        terminal.vt = 1;
        default_session = {
          command = "${greeterSession}";
          user = "greeter";
        };
      };
    };

    # --- GPU: pin a la iGPU + hotplug --------------------------------------
    # La regla NO lleva el slot PCI horneado (lo que hace install.sh en Arch):
    # pregunta a vexyon-gpu-detect en cada evento. Así es válida en cualquier
    # máquina, es reproducible, y no caduca si cambia el hardware.
    services.udev.packages = lib.mkIf cfg.gpu.pin [
      (pkgs.writeTextDir "lib/udev/rules.d/90-vexyon-gpu.rules" ''
        SUBSYSTEM=="drm", KERNEL=="card[0-9]*", PROGRAM="${vexyon}/bin/vexyon-gpu-detect is-igpu %k", SYMLINK+="dri/vexyon-igpu"
      '')
      (pkgs.writeTextDir "lib/udev/rules.d/91-vexyon-gpu-hotplug.rules" ''
        ACTION=="change", SUBSYSTEM=="drm", KERNEL=="card[0-9]*", RUN+="${vexyon}/bin/vexyon-gpu-hotplug ${config.users.users.${cfg.user}.home}"
      '')
    ];

    # El usuario necesita video/input para el compositor y el brillo.
    users.users.${cfg.user}.extraGroups = [
      "video"
      "input"
    ];
  };
}
