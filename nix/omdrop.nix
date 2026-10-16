# omdrop — the AirDrop command and receiver (github.com/netmojo-systems/omdrop-plugin),
# for Vexyon's AirDrop module. Its radio half, omdrop-owl, comes from its own
# flake (flake.nix → inputs.omdrop-owl; nix/module.nix enables it).
#
# Upstream is an Omarchy plugin: a directory with manifest.json whose
# bin/omdrop finds everything relative to itself. It is installed as such a
# directory, unmodified except for what NixOS needs:
#   - one PATH line at the top of bin/omdrop: its tools, pkexec's setuid
#     wrapper, and vexyon/ — stand-ins for the Omarchy commands it calls
#     (notifications, browser, terminal) and for pacman's vercmp, all of them
#     vexyon-omdrop-compat, and heif-convert (libheif's heif-dec today: an
#     iPhone's HEIC photo goes on the clipboard as a JPEG). It re-runs itself
#     from systemd user units, so the PATH has to live in the script, not in
#     a wrapper;
#   - the receiver's user unit: this python instead of /usr/bin/python3, and a
#     PATH for its start checks and openssl;
#   - libkeyutils by store path (the 1Password identity cache).
# The directory sits under …/plugins/omdrop: omdrop's setup only refreshes
# its ~/.local/bin/omdrop link when the old target looks like a plugin, which
# is what lets an update replace a link into an older store path.
{
  lib,
  stdenvNoCC,
  fetchFromGitHub,
  python3,
  glib,
  bash,
  coreutils,
  findutils,
  gnugrep,
  gnused,
  gawk,
  iproute2,
  systemd,
  util-linux,
  procps,
  openssl,
  keyutils,
  wl-clipboard,
  xdg-utils,
  xdg-user-dirs,
  libheif,
  shared-mime-info,
  desktop-file-utils,
  hostname-debian,
  vexyon,
}:

let
  python = python3.withPackages (ps: [
    ps.libarchive-c # the receiver's one import outside the standard library
    ps.pygobject3 # pick.py: the file chooser, through the desktop portal
  ]);

  runtimePath = lib.makeBinPath [
    python
    bash
    coreutils
    findutils
    gnugrep
    gnused
    gawk
    iproute2
    systemd
    util-linux
    procps
    openssl
    wl-clipboard
    xdg-utils
    xdg-user-dirs
    shared-mime-info
    desktop-file-utils
    hostname-debian
  ];

  compat = "${vexyon}/bin/vexyon-omdrop-compat";
in
stdenvNoCC.mkDerivation {
  pname = "omdrop";
  version = "0.16.4";

  src = fetchFromGitHub {
    owner = "netmojo-systems";
    repo = "omdrop-plugin";
    rev = "95ee625fd63e0eb9061f1d08c8116231d0f2a303"; # release 0.16.4
    hash = "sha256-zMiALreWLVTM7OIUITuZAgH+R+AoJOIyngCK0vNT+FE=";
  };

  # patchShebangs gives the .py helpers this python.
  nativeBuildInputs = [ python ];

  dontConfigure = true;
  dontBuild = true;

  installPhase = ''
    runHook preInstall

    plugin=$out/plugins/omdrop
    mkdir -p $plugin
    cp -r manifest.json bin share docs skills LICENSE README.md $plugin/

    # Stand-ins for the Omarchy commands omdrop calls; only its PATH has them.
    mkdir -p $plugin/vexyon
    for c in notification-send launch-browser default-terminal; do
      printf '#!${bash}/bin/bash\nexec ${compat} %s "$@"\n' "$c" > $plugin/vexyon/omarchy-$c
    done
    printf '#!${bash}/bin/bash\nexec ${compat} vercmp "$@"\n' > $plugin/vexyon/vercmp
    # libheif 1.23 calls it heif-dec; omdrop asks for its old name.
    printf '#!${bash}/bin/bash\nexec ${libheif.bin}/bin/heif-dec "$@"\n' > $plugin/vexyon/heif-convert
    chmod 755 $plugin/vexyon/*

    substituteInPlace $plugin/bin/omdrop \
      --replace-fail 'PROJ="$(cd "$(dirname "$SELF")/.." && pwd)"' \
'PROJ="$(cd "$(dirname "$SELF")/.." && pwd)"
# Vexyon (NixOS): its tools, the setuid pkexec, and the Omarchy stand-ins.
export PATH="$PROJ/vexyon:/run/wrappers/bin:${runtimePath}:$PATH"
export GI_TYPELIB_PATH="${glib.out}/lib/girepository-1.0''${GI_TYPELIB_PATH:+:$GI_TYPELIB_PATH}"' \
      --replace-fail '[[ -e /usr/lib/libkeyutils.so.1 ]]' \
                     '[[ -e ${keyutils.lib}/lib/libkeyutils.so.1 ]]'

    substituteInPlace $plugin/bin/identity.py \
      --replace-fail "ctypes.CDLL('libkeyutils.so.1'" \
                     "ctypes.CDLL('${keyutils.lib}/lib/libkeyutils.so.1'"

    substituteInPlace $plugin/share/airdrop-receiver.service \
      --replace-fail 'ExecStart=/usr/bin/python3 ' 'ExecStart=${python}/bin/python3 ' \
      --replace-fail '[Service]' '[Service]
Environment=PATH=${runtimePath}:/run/current-system/sw/bin'

    patchShebangs $plugin/bin

    mkdir -p $out/bin
    ln -s $plugin/bin/omdrop $out/bin/omdrop

    runHook postInstall
  '';

  meta = {
    description = "AirDrop with nearby Apple devices: the omdrop command and receiver";
    homepage = "https://github.com/netmojo-systems/omdrop-plugin";
    license = lib.licenses.mit;
    platforms = lib.platforms.linux;
    mainProgram = "omdrop";
  };
}
