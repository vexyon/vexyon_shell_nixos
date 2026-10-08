# AGENTS.md — working on Vexyon

Instructions for anyone (person or AI agent) changing Vexyon. They are
permanent: they apply to every task, on both repositories, unless the owner
explicitly says otherwise for that task. `CLAUDE.md` imports this file.

## The two repositories

| repo | platform | installs with |
|---|---|---|
| `vexyon_shell` | Arch Linux / CachyOS | `install.sh` (pacman, systemd, sudo) |
| `vexyon_shell_nixos` | NixOS | `flake.nix` → `nix/module.nix` + `nix/package.nix` |

- The shell is ONE codebase. Every file under `config/vexyon/` (QML,
  services, `shell.json` seed, `bin/vexyon-modules`), `config/polkit/` and
  `share/vexyon/` must be **byte-identical** in both repos, except the files
  that are platform-specific on purpose: `config/vexyon/bin/vexyon-seed`
  (NixOS only), the bridge, `vexyon-start`, the GPU helpers, the greeter
  files, the `config/hypr/` seeds, `Wallpaper.qml`/`WallpaperPicker.qml`.
  Check before committing (from the parent directory):

  ```bash
  for f in $(cd vexyon_shell && git ls-files config share); do
    [ -f "vexyon_shell_nixos/$f" ] && ! cmp -s "vexyon_shell/$f" "vexyon_shell_nixos/$f" && echo "DIFF $f"
  done
  ```

  The only `DIFF` lines allowed are the platform-specific files above.
- Platform-specific code only where a platform really differs. Never fork a
  large implementation between the repos.
- `PROJECT_STATE.md` is the same file in both repos. Every task adds one
  entry at the top (newest first): what changed, why, how it was verified,
  and what was NOT verified. Never rewrite older entries.
- `CHANGELOG.md` is the same file in both repos. Add to it; never rewrite a
  released version's entry.

## PERMANENT POLICY: out of the box

VEXYON OUT-OF-THE-BOX POLICY Every Vexyon feature must ship together with all required dependencies and system integration. A successful Vexyon installation must produce a fully functional shell without manual package installation, systemd commands or hand-editing system configuration. Optional features must be controllable through Vexyon Settings. Disabling them must prevent unnecessary exclusive runtime services from starting at the next boot while keeping the feature ready to be enabled again without reinstalling dependencies. This is a permanent design and acceptance requirement for every future Vexyon feature on both NixOS and Arch/CachyOS.

In practice, for every feature you add or change:

- Its packages go into BOTH installers: `PKGS`/`MOD_PKGS` in `install.sh`
  and `environment.systemPackages` / the right NixOS option in
  `nix/module.nix`. Package names are checked against the distribution,
  never guessed.
- Its services are enabled by the installer (Arch) / declared by the module
  (NixOS). Respect what the user already configured: a masked unit stays
  masked; on NixOS use `lib.mkDefault` so the user's own value wins.
- Group membership, polkit rules, firewall exceptions and default networks it
  needs are set up by the installer / module, not explained in a Settings page.
- If something cannot be installed (firmware settings such as VT-x, missing
  hardware), the feature detects it and says so plainly in its Settings page.
  Never claim something works when it cannot.
- Settings pages show what is missing and how to recover (re-run the
  installer / rebuild), not installation recipes.

## PERMANENT POLICY: README

PERMANENT POLICY: If Vexyon's installation changes, its GitHub README.md MUST be updated in the same development task. No exceptions.

That covers installation steps, dependencies, configuration, system
integration, commands, module behaviour and the version. The NixOS README
documents this contract and must keep it working:

1. add the flake input `vexyon.url = "github:vexyon/vexyon_shell_nixos";`
2. import `vexyon.nixosModules.vexyon`
3. `services.vexyon = { enable = true; user = "username"; };`
4. `sudo nixos-rebuild switch --flake ...`

The Arch README documents the installer contract (`git clone` → `./install.sh`
→ reboot) and what the installer sets up.

## Optional modules (Settings → Modules)

Classification — every feature is one of:

- **Core** (cannot be turned off): bar, launcher, panels, notifications, lock
  screen, greeter, wallpaper, clipboard history, night light, audio
  (PipeWire), networking (NetworkManager), power (UPower,
  power-profiles-daemon), udisks2, GPU pinning, the bridge.
- **Optional module**: a substantial feature, usually with its own
  background services. Today: `vm` (libvirt/QEMU), `bluetooth` (BlueZ) —
  system scope, applied at the next boot — and `recorder` (screen recording) —
  session scope, applied at once, no service.
- **On demand**: runs only while used, nothing resident (calculator,
  screenshots, color picker, file transfers, OVA import/export, weather
  fetch, `wf-recorder` while recording).

Do not invent modules for tiny features, and do not add daemons. How a system
module works (read `config/vexyon/bin/vexyon-modules` first):

- Desired state: `/var/lib/vexyon/modules/<id>.disabled` (root, 0644; dir
  0755). Written ONLY by `vexyon-modules set`, which the shell reaches through
  `pkexec` and the polkit action `org.vexyon.modules.set` (admin password).
  The shell itself never gets more privilege than that one validated call.
- Applied state: `vexyon-modules.service` runs `boot-apply` once per boot,
  before `sysinit.target`, and writes `/run/vexyon/modules/`. Started later
  (rebuild, re-run installer) it does nothing: changes take effect at the
  next boot, never mid-session. Nothing running is ever stopped.
- Gating: every unit of a module carries
  `ConditionPathExists=!/run/vexyon/modules/<id>.gated` plus
  `Wants=`/`After=vexyon-modules.service` (NixOS: `moduleGate` in
  `nix/module.nix`; Arch: `write_gate` in `install.sh`). A gated unit does not
  start by any route: boot, socket, D-Bus activation, dependency.
- Shared services are never gated: if other installed software uses the
  service (`module_consumers` in the helper), the module only hides Vexyon's
  part. Never gate services shared with the rest of the system (polkit,
  NetworkManager, PipeWire, systemd-machined, firewalls, `dnsmasq.service`).
- Failure means "on": no snapshot, no helper → nothing is gated.
- In QML, ask `Modules` (`Modules.vmOn`, `Modules.bluetoothOn`,
  `Modules.recorderOn`), never the feature singleton (`Vm.enabled`,
  `Recorder.enabled`): asking the singleton instantiates it.

Adding a new optional module means ALL of: a `catalog` entry in
`services/Modules.qml`; for a system module, the id in `MODULES`,
`module_unit`, `module_hardware` and `module_consumers` in
`bin/vexyon-modules`, its units in `vmServices`/`vmSockets`-style lists in
`nix/module.nix` and in `install.sh`; Spanish strings in `I18n.qml`; the
README tables; a `PROJECT_STATE.md` entry with the resource cost measured
on/off.

## No bloat

- Turning a module off must remove its exclusive runtime processes: no
  polling, no watchers, no resident helpers. Packages stay installed — the
  target is runtime CPU/RAM, not disk.
- No new `Timer` that polls; no `running: true` Process that stays alive.
  Read state on request (page opened, action finished), or subscribe to
  events that already exist.

## Versions

The version lives in four places; change them together:
`modules/Settings.qml` (About: `"3.0"`), `nix/package.nix` (`version =
"3.0.0"`), `install.sh` (`VEXYON_VERSION`), the README badge — plus a
`CHANGELOG.md` entry.

## Strings and code style

- UI strings are English keys passed to `I18n.t()`; add the Spanish
  translation to `services/I18n.qml` in the same change.
- Match the surrounding code: comment density, naming, the language of the
  comments around your change.

## Testing

- Run what can run: `bash -n` and `shellcheck` for scripts,
  `systemd-analyze verify` for units, `nix-instantiate --parse`, a full NixOS
  evaluation of the module and `nix build` of the package, the QML under a
  headless compositor. Anything touching modules or boot units: the NixOS VM
  test in `vexyon_shell_nixos` (`nix build .#tests.x86_64-linux.modules-gating`,
  or build `.driver` and run `result/bin/nixos-test-driver` without KVM). Say exactly what was verified and what was not; do not
  claim runtime results on hardware or a platform you could not test.
- Never test destructively on the owner's machine: do not restart the
  compositor or the session, do not kill the terminal, do not touch the
  owner's existing VMs (notably `Ryoku2`) — create a temporary test VM when a
  VM is needed and delete it afterwards.
