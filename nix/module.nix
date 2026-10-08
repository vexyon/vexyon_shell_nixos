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

  # --- distribución de teclado del sistema ---------------------------------
  # En Arch esto lo siembra install.sh leyendo la config del OS (X11
  # 00-keyboard.conf, luego vconsole). Aquí el equivalente declarativo se lee
  # del propio `config`, así que el usuario NO tiene que declararlo dos veces.
  #
  # Orden de preferencia (el mismo criterio que install.sh):
  #   1. services.xserver.xkb.layout — el namespace XKB canónico de nixpkgs
  #      26.05 (declarado en nixos/modules/services/x11/xserver.nix; NO es un
  #      alias renombrado). Vale sin activar xserver: es también de donde
  #      NixOS deriva la consola cuando console.useXkbConfig está puesto, y es
  #      lo que declara todo el mundo en un sistema Wayland.
  #   2. console.keyMap — keymap de consola. Su prefijo suele coincidir con el
  #      layout XKB (es, de-latin1 -> de); uk es la excepción (XKB usa gb).
  xkbLayout = config.services.xserver.xkb.layout;
  xkbVariant = config.services.xserver.xkb.variant;
  rawKeyMap = config.console.keyMap;

  keyMapToXkb =
    km:
    let
      base = lib.head (lib.splitString "-" (lib.head (lib.splitString "," km)));
    in
    if base == "uk" then "gb" else base;

  consoleLayout =
    if rawKeyMap != null && builtins.isString rawKeyMap && rawKeyMap != "" then
      keyMapToXkb rawKeyMap
    else
      "";

  # "us" es el defecto de AMBAS opciones, así que un "us" no distingue entre
  # "el usuario quiere US" y "nadie lo ha tocado": se prefiere la primera
  # fuente que diga algo distinto de us, y si ninguna lo dice, us es correcto.
  xkbIsSet = xkbLayout != "" && xkbLayout != "us";
  kbLayout =
    if xkbIsSet then
      xkbLayout
    else if consoleLayout != "" && consoleLayout != "us" then
      consoleLayout
    else
      "us";
  # El variant solo viaja con su layout: si el layout salió de console.keyMap,
  # el variant de xkb no le corresponde.
  kbVariant = if xkbIsSet then xkbVariant else "";

  # --- cursor --------------------------------------------------------------
  # Los ids del selector y el nombre XCursor de cada uno viven en el bridge
  # (CURSOR_THEMES en vexyon-bridge.py); aquí solo se instalan los paquetes que
  # PROVEEN esos nombres, que son assets estáticos (directorios de imágenes en
  # share/icons, ningún proceso). Ninguno puede faltar: si XCURSOR_THEME apunta
  # a un tema que no se resuelve, Hyprland dibuja su cursor EMBEBIDO, que tiene
  # la forma de su logo — que es exactamente lo que no se quiere ver nunca.
  #
  #   Adwaita                adwaita-icon-theme   flecha negra clásica ("Default")
  #   Bibata-Modern-Ice      bibata-cursors       blanca redondeada  ("Pretty")
  #   Bibata-Modern-Classic  bibata-cursors       negra redondeada
  #   Vanilla-DMZ            vanilla-dmz          la blanca clásica de X11
  #   capitaine-cursors      capitaine-cursors    gris pizarra
  cursorPackages = with pkgs; [
    adwaita-icon-theme
    bibata-cursors
    vanilla-dmz
    capitaine-cursors
  ];
  # Defecto de fábrica del greeter, hasta que el bridge copie la elección real
  # del usuario a cursor.lua. Coincide con el seed de shell.json ("pretty").
  defaultCursorTheme = "Bibata-Modern-Ice";

  sessionEnv = {
    VEXYON_SHARE = "${vexyon}/share/vexyon";
    VEXYON_BIN_DIR = "${vexyon}/bin";
    VEXYON_QML_ROOT = "${vexyon}/share/vexyon/qml";
    VEXYON_GREETER_STATE_DIR = stateDir;
    VEXYON_POLKIT_AGENT = polkitAgent;
    # Semilla de teclado para vexyon-seed: solo se usa la PRIMERA vez, si
    # shell.json aún no tiene behavior.keyboardLayout. A partir de ahí manda
    # Ajustes → Comportamiento, igual que en Arch.
    VEXYON_KB_LAYOUT = kbLayout;
    VEXYON_KB_VARIANT = kbVariant;
    # xdg-desktop-portal-hyprland lo arranca D-Bus/systemd vía xdg.portal:
    # vacío a propósito para que hyprland.lua NO lo lance por segunda vez.
    VEXYON_XDG_PORTAL_HYPRLAND = "";
  };

  envExports = lib.concatStringsSep "\n" (
    lib.mapAttrsToList (k: v: "export ${k}=${lib.escapeShellArg v}") sessionEnv
  );

  # Entrada de sesión: mismo papel que el vexyon.desktop de Arch, pero el Exec
  # apunta al store y exporta el entorno del port antes de arrancar.
  # XCursor busca los temas en ~/.icons:/usr/share/icons:/usr/share/pixmaps, y
  # en NixOS /usr/share NO EXISTE: sin esto el tema de cursor se pide por
  # nombre y no lo encuentra nadie. Se fija explícitamente en vez de confiar en
  # que otro módulo lo exporte, e incluye el store del propio paquete de
  # cursores (el greeter corre como otro usuario y no tiene este perfil).
  cursorPathExport = ''
    export XCURSOR_PATH="$HOME/.icons:/run/current-system/sw/share/icons:${
      lib.concatMapStringsSep ":" (p: "${p}/share/icons") cursorPackages
    }"
  '';

  # Lector WebP de Qt (el mismo qt6 de nixpkgs con el que está construido
  # quickshell). quickshell solo trae los plugins de qtbase/qtsvg — PNG, JPEG,
  # GIF, BMP — y el selector de foto de perfil ofrece *.webp: sin esto un
  # avatar WebP no carga y Ajustes / Super+C / bloqueo enseñan solo la
  # inicial. Es lo que en Arch aporta el paquete qt6-imageformats.
  qtPluginExport = ''
    export QT_PLUGIN_PATH="${pkgs.qt6.qtimageformats}/${pkgs.qt6.qtbase.qtPluginPrefix}''${QT_PLUGIN_PATH:+:$QT_PLUGIN_PATH}"
  '';

  # --- módulos opcionales (3.0) ---------------------------------------------
  # Ajustes → Módulos. Cada servicio de un módulo de sistema lleva esta
  # condición: si vexyon-modules.service decidió al arrancar que el módulo va
  # apagado (y nada más lo usa), el servicio, su socket y su activación por
  # D-Bus simplemente NO arrancan. Sin recompilar nada: la decisión se toma
  # en cada arranque leyendo /var/lib/vexyon/modules, que solo escribe el
  # ayudante (root, vía pkexec + polkit) cuando el usuario cambia el
  # interruptor. Lista y no cadena: así se suma a cualquier otra condición.
  moduleGate = id: {
    wants = [ "vexyon-modules.service" ];
    after = [ "vexyon-modules.service" ];
    unitConfig.ConditionPathExists = [ "!/run/vexyon/modules/${id}.gated" ];
  };
  # Todo lo que libvirt arranca solo. machined, el cortafuegos o
  # NetworkManager NO: son compartidos y no se tocan nunca.
  vmServices = [
    "libvirtd"
    "libvirtd-config"
    "libvirt-guests"
    "virtlogd"
    "virtlockd"
    "virt-secret-init-encryption"
  ];
  vmSockets = [
    "libvirtd"
    "libvirtd-ro"
    "libvirtd-admin"
    "virtlogd"
    "virtlogd-admin"
    "virtlockd"
    "virtlockd-admin"
  ];
  libvirtOn = config.virtualisation.libvirtd.enable;
  bluetoothOn = config.hardware.bluetooth.enable;
  fw = config.networking.firewall;
  nft = config.networking.nftables.enable;
  userHome = config.users.users.${cfg.user}.home;

  vexyonSession = pkgs.writeShellScript "vexyon-session" ''
    ${envExports}
    ${cursorPathExport}
    ${qtPluginExport}
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
    # Teclado del kiosco: la contraseña del login TIENE que teclearse con la
    # misma distribución que el TTY y la sesión. El kiosco lo lee de aquí como
    # DEFECTO; si el usuario elige otra en Ajustes, el bridge escribe
    # input.lua en el estado y ese pisa a este (se carga después).
    export VEXYON_KB_LAYOUT=${lib.escapeShellArg kbLayout}
    export VEXYON_KB_VARIANT=${lib.escapeShellArg kbVariant}
    export VEXYON_CURSOR_THEME=${lib.escapeShellArg defaultCursorTheme}
    ${cursorPathExport}
    # start-hyprland, NO el binario pelado: Hyprland >= 0.51 trae este watchdog
    # y avisa en pantalla ("highly advised against") cuando se le lanza sin él
    # — un banner de depuración en la pantalla de login. Es también lo que hace
    # el config.toml de greetd en Arch. Solo relanza el compositor si CASCA; el
    # `hl.dsp.exit()` limpio del kiosco tras el login pasa de largo, así que
    # greetd sigue arrancando la sesión real en este VT.
    exec ${pkgs.hyprland}/bin/start-hyprland -- --config ${vexyon}/share/vexyon/greeter/hyprland.lua
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
    environment.systemPackages = [
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
      # 3.0 — fuera de la caja: lo que pedían las páginas de Ajustes.
      wf-recorder # grabación de pantalla (solo corre mientras se graba)
      hyprpicker # widget selector de color
      pulseaudio # SOLO por `pactl` (Ajustes → Audio, widget de privacidad); ningún demonio
      psmisc # `fuser`, la comprobación de cámara del widget de privacidad
      # Qt6: lo trae quickshell como dependencia propia. NO se instala qt6ct
      # aunque vexyon-env.lua fije QT_QPA_PLATFORMTHEME=qt6ct.
      #
      # Instalarlo aquí no lo hacía funcionar: el plugin de platform theme
      # (lib/qt-6/plugins/platformthemes/libqt6ct.so) solo lo encuentra Qt si
      # QT_PLUGIN_PATH incluye el perfil del sistema, y eso lo cablea el módulo
      # `qt` de NixOS (qt.enable + qt.platformTheme), no `environment.system-
      # Packages`. Sin ese cableado el .so era inalcanzable y el paquete solo
      # aportaba su qt6ct.desktop — "Ajustes de Qt6" en el lanzador, un panel
      # de configuración de bajo nivel entre las apps del usuario.
      #
      # Arch tampoco lo instala (install.sh trae qt6-base/declarative/svg y
      # nada más), así que quitarlo iguala las dos plataformas en vez de
      # separarlas. Si algún día se quiere temar de verdad las apps Qt, el
      # camino es `qt.enable = true; qt.platformTheme = "qt6ct";` — que además
      # exporta la variable por sí solo.
    ])
    # La ventana de las VMs. Solo con libvirt: sin él no hay nada que mirar.
    ++ lib.optional libvirtOn pkgs.virt-viewer
    # Los temas de cursor. Tienen que estar en systemPackages y no solo en el
    # entorno del usuario: en NixOS no hay /usr/share/icons y XCursor resuelve
    # los temas por /run/current-system/sw/share/icons, que es también donde
    # los encuentra el greeter (que corre como otro usuario, sin este perfil).
    ++ cursorPackages;

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

    # --- módulos opcionales (3.0) -------------------------------------------
    # REGLA FUERA DE LA CAJA: `services.vexyon.enable = true;` instala y deja
    # listo todo lo que necesita cada función, sin opciones extra para el
    # usuario. Los módulos opcionales se APAGAN en Ajustes → Módulos, en
    # tiempo de ejecución (sin rebuild): el interruptor solo decide si sus
    # servicios arrancan en el siguiente arranque; los paquetes se quedan.
    # mkDefault en todo: lo que el usuario declare él mismo, manda.

    # Máquinas virtuales: libvirt + QEMU de la arquitectura del equipo, TPM
    # emulado (Windows 11) y virtiofsd (carpetas compartidas). libvirtd sale
    # solo a los 120 s sin uso y lo vuelve a levantar su socket.
    virtualisation.libvirtd = {
      enable = lib.mkDefault true;
      qemu = {
        package = lib.mkDefault pkgs.qemu_kvm;
        swtpm.enable = lib.mkDefault true;
        vhostUserPackages = lib.mkDefault [ pkgs.virtiofsd ];
      };
    };

    # Bluetooth. bluetoothd solo arranca si hay adaptador (condición propia
    # de su unidad).
    hardware.bluetooth.enable = lib.mkDefault true;

    systemd.services = lib.mkMerge [
      {
        # El ayudante, al arrancar, congela en /run el estado de los módulos
        # y decide qué servicios quedan bloqueados. Antes de sysinit.target:
        # los sockets (sockets.target) y bluetooth.target van después. Una
        # sola vez por arranque: nixos-rebuild switch no lo relanza
        # (restartIfChanged = false) y, si se lanza fuera del arranque, no
        # aplica nada — los cambios llegan siempre con el siguiente
        # arranque, nunca a mitad de sesión.
        vexyon-modules = {
          description = "Vexyon modules: apply this boot's module choices";
          wantedBy = [ "sysinit.target" ];
          before = [
            "sysinit.target"
            "shutdown.target"
          ];
          after = [ "local-fs.target" ];
          conflicts = [ "shutdown.target" ];
          unitConfig = {
            DefaultDependencies = false;
            RequiresMountsFor = "/var/lib/vexyon";
          };
          serviceConfig = {
            Type = "oneshot";
            RemainAfterExit = true;
            ExecStart = "${vexyon}/libexec/vexyon/vexyon-modules boot-apply";
          };
          restartIfChanged = false;
        };
      }
      # Las condiciones, solo sobre unidades que existen: con libvirt o
      # Bluetooth apagados en la configuración del usuario no se crean
      # unidades vacías.
      (lib.mkIf libvirtOn (lib.genAttrs vmServices (_: moduleGate "vm")))
      (lib.mkIf bluetoothOn { bluetooth = moduleGate "bluetooth"; })
    ];
    systemd.sockets = lib.mkIf libvirtOn (lib.genAttrs vmSockets (_: moduleGate "vm"));

    # video/input para el compositor y el brillo. libvirtd: las VMs son de
    # este usuario sin contraseña (regla de polkit de libvirt para ese grupo);
    # llega a la sesión en el siguiente inicio.
    users.users.${cfg.user}.extraGroups = [
      "video"
      "input"
    ]
    ++ lib.optional libvirtOn "libvirtd";

    # Red de las VMs sin tocar nada: las excepciones acotadas a los puentes de
    # libvirt (virbr*) que antes había que pegar a mano desde Ajustes →
    # Virtualización. Medidas en la sesión de redes (PROJECT_STATE.md): solo
    # tráfico que ENTRA por un puente de libvirt y no va a este equipo se
    # salta el filtro de ruta inversa; DHCP/DNS de las VMs llegan al dnsmasq
    # de libvirt. El resto del cortafuegos no cambia. types.lines: se suman a
    # las líneas del usuario, no las sustituyen. Sin puentes virbr* (módulo
    # apagado) no casan con nada.
    networking.firewall.extraCommands = lib.mkIf (libvirtOn && fw.enable && !nft) ''
      ip46tables -t mangle -I nixos-fw-rpfilter -i virbr+ -m addrtype ! --dst-type LOCAL -j RETURN
    '';
    networking.firewall.extraReversePathFilterRules = lib.mkIf (libvirtOn && fw.enable && nft) ''
      iifname "virbr*" fib daddr type != local accept
    '';
    networking.firewall.extraInputRules = lib.mkIf (libvirtOn && fw.enable && nft) ''
      iifname "virbr*" udp dport { 53, 67 } accept
      iifname "virbr*" tcp dport 53 accept
    '';
    networking.firewall.extraForwardRules = lib.mkIf (libvirtOn && fw.enable && nft && fw.filterForward) ''
      iifname "virbr*" accept
    '';

    # Migración de una sola vez desde 2.x: el interruptor de virtualización
    # vivía en shell.json (`virtualization.enabled`, false por defecto). Quien
    # lo tenía apagado lo conserva apagado: se le apaga el módulo (que ahora
    # instala libvirt de serie). Quien no tenía shell.json, o lo tenía
    # encendido, se queda con el módulo encendido, que es el defecto de 3.0.
    # Solo se marca hecha si se pudo leer el $HOME (un /home sin montar en la
    # activación del arranque no debe dar la migración por terminada).
    system.activationScripts.vexyonModules = ''
      install -d -m 0755 /var/lib/vexyon /var/lib/vexyon/modules
      if [ ! -e /var/lib/vexyon/modules/.migrated-3.0 ] && [ -d ${lib.escapeShellArg userHome} ]; then
        sj=${lib.escapeShellArg "${userHome}/.config/vexyon/shell.json"}
        if [ -f "$sj" ] && [ ! -L "$sj" ] \
           && ${pkgs.coreutils}/bin/timeout 5 ${pkgs.jq}/bin/jq -e '.virtualization.enabled == false' "$sj" >/dev/null 2>&1; then
          ${vexyon}/libexec/vexyon/vexyon-modules set vm off >/dev/null \
            && echo "vexyon: the Virtual machines module stays off, as it was before 3.0 (Settings → Modules turns it on)"
        fi
        : > /var/lib/vexyon/modules/.migrated-3.0
      fi
    '';

    # --- energía: batería y perfiles ---------------------------------------
    # Los dos widgets de energía del shell son clientes D-Bus de estos dos
    # servicios, y no son un extra opcional como libvirt/qemu:
    #
    #   upower                -> services/Battery.qml, vía
    #                            Quickshell.Services.UPower. Sin él no hay
    #                            displayDevice, `Battery.present` es false y el
    #                            indicador de batería de la barra no existe.
    #   power-profiles-daemon -> modules/BatteryPanel.qml, vía el singleton
    #                            PowerProfiles (la interfaz D-Bus
    #                            org.freedesktop.UPower.PowerProfiles, antes
    #                            net.hadess.PowerProfiles). Sin él la píldora de
    #                            perfiles no puede cambiar nada.
    #
    # Los dos se activan por D-Bus y en reposo no hacen prácticamente nada
    # (~1,6 MB de RSS y 25 ms de CPU medidos), así que declararlos aquí no es
    # bloat: es lo que hace que `services.vexyon.enable = true;` baste, sin que
    # nadie tenga que adivinar qué le falta para que la batería aparezca.
    services.upower.enable = lib.mkDefault true;

    # OJO con power-profiles-daemon: es EXCLUYENTE con tlp, con tlp.pd y con
    # auto-cpufreq, y el módulo de nixpkgs lo hace cumplir con `assertions`, no
    # con una prioridad. Por eso mkDefault a secas NO bastaría: una definición
    # mkDefault sigue siendo una definición, así que en una máquina con TLP el
    # valor seguiría siendo true y el rebuild del usuario reventaría con un
    # error que viene de un módulo que él no ha escrito.
    #
    # La forma idiomática es que el DEFECTO se calcule: el shell pide el
    # demonio solo cuando nadie está usando una alternativa incompatible. Así
    # el caso normal (portátil sin TLP) funciona sin tocar nada, y la elección
    # explícita del usuario gana en los tres sentidos sin conflicto:
    #   - ppd = true forzado  -> mkDefault cede, y el assert de nixpkgs avisa
    #                            si además hay TLP (que es lo correcto).
    #   - ppd = false forzado -> mkDefault cede.
    #   - TLP / auto-cpufreq  -> el shell ni lo pide.
    services.power-profiles-daemon.enable = lib.mkDefault (
      !config.services.tlp.enable && !config.services.tlp.pd.enable && !config.services.auto-cpufreq.enable
    );

    # Y si al final nadie sirve la interfaz, se dice claramente en vez de dejar
    # una píldora de perfiles que no responde (que es justo el síntoma que hubo
    # que depurar). TLP tiene salida propia: services.tlp.pd expone la MISMA
    # interfaz D-Bus, así que el widget funciona igual. auto-cpufreq no tiene
    # equivalente.
    warnings = lib.optional
      (!config.services.power-profiles-daemon.enable && !config.services.tlp.pd.enable)
      ''
        vexyon: nada está sirviendo org.freedesktop.UPower.PowerProfiles, así
        que la píldora de perfiles del panel de batería no podrá cambiar de
        perfil. power-profiles-daemon está desactivado, normalmente porque
        services.tlp o services.auto-cpufreq están activos y son incompatibles.
        Con TLP la solución es `services.tlp.pd.enable = true;`, que expone esa
        misma interfaz. La batería (upower) no se ve afectada.
      '';

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
    # OJO con input.lua y cursor.lua: NO se crean aquí a propósito. Las líneas
    # `f`/`C+` de tmpfiles son crear-si-no-existe (el `+` de `C+` solo cambia
    # cómo desciende en directorios, no sobrescribe un fichero que ya está),
    # así que un input.lua sembrado con un teclado fijo se quedaría congelado
    # para siempre y ningún cambio posterior de la config del sistema llegaría
    # al greeter — que es exactamente el bug que tenía este módulo. Ahora el
    # DEFECTO viaja por entorno desde greeterSession (sigue a la config de
    # NixOS en cada rebuild) y el fichero solo aparece si el usuario elige algo
    # distinto en Ajustes, en cuyo caso el bridge lo escribe y manda él.
    #
    # estado se muda aquí, con el dueño que hace que el bridge siga escribiendo
    # sin sudo — igual que el `install -o $USER` del instalador de Arch.
    systemd.tmpfiles.rules = lib.mkIf cfg.greeter.enable [
      "d ${stateDir} 0755 ${cfg.user} users - -"
      "C+ ${stateDir}/theme.json 0644 ${cfg.user} users - ${vexyon}/share/vexyon/greeter/theme.json"
      "f ${stateDir}/greeter.json 0644 ${cfg.user} users - {\"user\":\"${cfg.user}\",\"lang\":\"en\"}"
      "f ${stateDir}/vexyon-gpu.lua 0644 ${cfg.user} users - -- Vexyon GPU pin (generated at runtime)"
    ];

    # Migración de una sola vez: las versiones anteriores de este módulo
    # SEMBRABAN input.lua con `kb_layout="us"` fijo. Como las líneas de
    # tmpfiles son crear-si-no-existe, ese fichero sobrevive al rebuild y
    # seguiría pisando el teclado bueno — el greeter se quedaría en "us" para
    # siempre en cualquier máquina ya instalada, que es justo el bug.
    #
    # El criterio no puede ser la marca "GENERATED": el helper de sincronía
    # también escribía "us" cuando shell.json no tenía la clave todavía, así
    # que un fichero marcado puede ser igual de rancio. Se borra cuando dice
    # "us" y el sistema NO dice "us" — esa combinación solo puede venir de un
    # defecto viejo, nunca de una elección informada.
    #
    # Y si el usuario SÍ quería "us" en un sistema español, no se pierde nada:
    # en ese caso shell.json lleva la clave, y el bridge vuelve a escribir el
    # fichero en el primer regenerate de la sesión siguiente.
    system.activationScripts.vexyonDropStaleGreeterInput =
      lib.mkIf (cfg.greeter.enable && kbLayout != "us")
        ''
          stale=${stateDir}/input.lua
          if [ -e "$stale" ] && ${pkgs.gnugrep}/bin/grep -q 'kb_layout *= *"us"' "$stale"; then
            rm -f "$stale"
            echo "vexyon: retirado el input.lua rancio del greeter (fijaba us; el sistema usa ${kbLayout})"
          fi
        '';

    # Lo mismo para el cursor: las versiones anteriores escribían aquí
    # `XCURSOR_THEME "default"` cuando la opción era "system", y "default" no
    # es ningún tema instalado — Hyprland caía en su cursor EMBEBIDO, el que
    # tiene forma de su logo, justo en la pantalla de login. El fichero
    # sobrevive al rebuild, así que hay que retirarlo: el bridge escribe el
    # bueno en el primer regenerate de la sesión siguiente y, hasta entonces,
    # el kiosco usa el tema que le llega por entorno. Un cursor.lua nuevo nunca
    # dice "default" (el id "default" del selector se traduce a "Adwaita"), así
    # que la marca no puede confundirse con una elección buena.
    system.activationScripts.vexyonDropStaleGreeterCursor = lib.mkIf cfg.greeter.enable ''
      stale=${stateDir}/cursor.lua
      if [ -e "$stale" ] && ${pkgs.gnugrep}/bin/grep -q 'XCURSOR_THEME", *"default"' "$stale"; then
        rm -f "$stale"
        echo "vexyon: retirado el cursor.lua rancio del greeter (fijaba un tema inexistente; salía el cursor del logo)"
      fi
    '';

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
        ACTION=="change", SUBSYSTEM=="drm", KERNEL=="card[0-9]*", RUN+="${vexyon}/bin/vexyon-gpu-hotplug ${
          config.users.users.${cfg.user}.home
        }"
      '')
    ];
  };
}
