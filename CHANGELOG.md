# Changelog

All notable changes to Vexyon. The same file is kept in both repositories:
[vexyon_shell](https://github.com/vexyon/vexyon_shell) (Arch Linux / CachyOS)
and [vexyon_shell_nixos](https://github.com/vexyon/vexyon_shell_nixos)
(NixOS). Releases before 3.0 were not recorded here; their history is in
`PROJECT_STATE.md` and the git log.

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
