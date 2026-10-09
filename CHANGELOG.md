# Changelog

All notable changes to Vexyon. The same file is kept in both repositories:
[vexyon_shell](https://github.com/vexyon/vexyon_shell) (Arch Linux / CachyOS)
and [vexyon_shell_nixos](https://github.com/vexyon/vexyon_shell_nixos)
(NixOS). Releases before 3.0 were not recorded here; their history is in
`PROJECT_STATE.md` and the git log.

## [Unreleased]

### Fixed

- **File Manager: copy/paste between two windows.** Copied or cut files were
  kept in a property of the window they were copied in, so a second window
  (or any other program) had nothing to paste. They now go to the system
  clipboard as `text/uri-list` (served by `wl-copy`), and paste reads whatever
  the clipboard holds: files from another Vexyon window or process, from
  Nautilus, Thunar, Dolphin or a browser. Ctrl+C / Ctrl+X / Ctrl+V / Ctrl+A,
  multi-selection, folders (recursive), cut = move (the source is removed only
  after a complete move), cut items shown dimmed in every window.

### Added

- **File Manager: user folders at their real paths.** Desktop, Documents,
  Downloads, Pictures, Music and Videos come from `user-dirs.dirs`, so
  translated folders (`~/Documentos`, `~/Bilder`…) are found; never by English
  names. A folder created later shows up on its own. `xdg-user-dirs` is
  installed by both installers.
- **File Manager: folder icons.** A symbol on top of the folder artwork for the
  user folders, and *Customize Folder Icon* for any folder: 260 symbols in 19
  categories (from the Nerd Font the shell already ships — no icon pack),
  search in English and Spanish, live preview, reset; or a local SVG/PNG, of
  which only a sanitised copy is ever loaded. Theme-aware contrast in dark and
  light themes, grid and list. Icons follow renames and moves made in Vexyon
  and renames made by other programs (same file system).
- **File Manager: sidebar bookmarks.** *Add to Sidebar* (right-click, Ctrl+D)
  or drag folders between the sidebar rows; reorder by dragging; *Remove from
  Sidebar* never touches the folder. Stored in the GTK bookmarks file shared
  with GTK file dialogs, Nautilus and Thunar; existing bookmarks are kept.
- **File Manager: pasting never overwrites.** A name that already exists is
  skipped and the card offers **Keep both**; pasting into the same folder
  makes "name (copy)"; a folder is never copied into itself; errors (missing
  source, read-only destination, permissions) are shown on the card.

### Changed

- **Much lower idle cost, same features.** With the default bar the shell
  used to start about 6 processes a second (a bash pipeline every 2 s for the
  CPU/RAM pills); it now starts none: CPU, memory and network are read from
  `/proc` inside the shell. Measured in the lab (same machine, 120 s idle,
  default config): processes started 720 → 0, shell CPU time 6.12 s → 0.31 s.
  With every monitor pill on the bar (disk, temperatures, network, VPN, Caps
  Lock, brightness): 537 → 54 processes in 30 s. Refresh rates are unchanged.
  - Disk usage (`df`) and temperatures are read only while a disk or
    temperature pill, or the system monitor, shows them. Temperatures no
    longer wake an idle AMD dGPU when nothing displays them.
  - Brightness: `brightnessctl` runs once to find the backlight; the level is
    then read from sysfs every 3 s (it used to cost ~80 processes a minute on
    every laptop). Changes made outside the shell still show the OSD.
  - Network state (`nmcli` every 5 s) is polled only while the network pill,
    Quick Settings, the network panel or the Settings network page is open;
    before, it kept polling all session once anything had looked at it.
  - Keyboard layout follows Hyprland's own events instead of a 4 s poll; the
    Caps Lock LED is read inside the shell (and found again if the keyboard
    is unplugged and plugged back).
  - The VPN pill, the system monitor's process list: fewer processes per
    refresh (no `bash`/`grep`/`head` around the real command).
  - The bridge (`vexyon-bridge`) waits for changes to `shell.json` with
    inotify instead of checking it twice a second; it falls back to the old
    check if inotify is not available.
  - Settings builds its page on first open instead of at login.
- **README screenshots are WebP** (1.3 MB instead of 19 MB). On NixOS the
  flake source is downloaded and stored with every update, so this is what it
  saves on disk and download each time.

### Removed

- Dead code: 12 unused translations, three unused functions (`Audio.nodeVolume`,
  `Vm.reboot_`, `Vm.setUsbRedir`), compiled Python caches that were committed
  by mistake (`.gitignore` added), and a calendar-panel animation that never
  moved anything (it read `parent` inside a `Translate`, which has none) but
  kept running while the panel was open.

## [3.0.0] — 2026-10-08

### Added

- **Settings → Modules.** Virtual machines, Bluetooth and screen recording
  are optional modules: installed and on by default, each with a switch, its
  current state, the state it will have after the next restart, and when the
  change applies.
  - Virtual machines and Bluetooth have background services. Turning one off
    keeps its services from starting at the next boot (systemd start
    conditions decided once per boot by `vexyon-modules.service`); nothing
    running is stopped mid-session. Packages, VMs, disks, networks and
    Bluetooth pairings are kept, so turning it back on needs no download and
    no command.
  - Screen recording has no service and applies at once.
  - The switch asks for the admin password through polkit; the only thing it
    can do is record that choice (`vexyon-modules`, action
    `org.vexyon.modules.set`).
  - Services used by other installed software (virt-manager,
    cockpit-machines, GNOME, Plasma, Blueman…) are never stopped; only
    Vexyon's part is hidden, and the card says why.
- **Out-of-the-box installation.** The Arch installer and the NixOS module
  now install and configure everything every feature needs:
  - virtual machines: libvirt, QEMU, virt-viewer, swtpm, virtiofsd, UEFI
    firmware, dnsmasq, the libvirt daemon, the user's libvirt group, libvirt's
    default NAT network, and the firewall integration (NixOS firewall
    exceptions for `virbr*`; libvirt's iptables backend on Arch when Docker or
    ufw is installed);
  - Bluetooth (BlueZ), screen recording (wf-recorder), the color picker
    (hyprpicker), `pactl`, `fuser`, the update counter (`checkupdates`, Arch),
    and NetworkManager on Arch when no other network manager is active.
- `AGENTS.md` / `CLAUDE.md` with the project's permanent rules, including the
  out-of-the-box policy and the README policy.
- NixOS: a VM test of the module gating across four real boots
  (`nix/tests/modules-gating.nix`, flake output
  `tests.<system>.modules-gating`).

### Changed

- The screen recorder's default shortcut is **Super+Shift+V** (was
  Super+Shift+R). Existing installs still on the old default are moved once,
  only if Super+Shift+V is free.
- Settings → Virtualization and Settings → Screen recording start with the
  module's card and no longer show installation recipes; when something is
  missing they say how to recover (re-run the installer / rebuild) and what no
  installer can do (turning on VT-x / AMD-V in the firmware).
- The VM manager no longer requires the `kvm` group (libvirt runs QEMU itself);
  it requires `/dev/kvm` to exist.
- Starting a VM first starts the libvirt networks it uses, and marking a VM to
  start with the computer also marks its networks. A network's dnsmasq now
  runs only when a VM needs it, and a VM no longer fails to start because its
  network was stopped (for example the `default` network on NixOS, or after an
  OVA import).
- The Bluetooth quick-settings tile says "Module off" and opens Settings →
  Modules when the Bluetooth module is off.
- About shows version 3.0. The NixOS package version is 3.0.0.

### Upgrading from 2.x

- If the old Settings → Virtualization switch was off, the Virtual machines
  module starts off too (turn it on in Settings → Modules, then restart).
  Everything else starts on. The same applies to the screen-recording switch,
  which keeps its old value.
- **Arch:** `git pull`, run `./install.sh` again, reboot.
- **NixOS:** update the flake input, `nixos-rebuild switch`, reboot. The old
  configuration lines Vexyon 2.x asked for (`virtualisation.libvirtd`,
  `virt-viewer`, the `libvirtd` group, firewall lines) can be deleted; they
  keep working if left in.
