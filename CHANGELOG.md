# Changelog

All notable changes to Vexyon. The same file is kept in both repositories:
[vexyon_shell](https://github.com/vexyon/vexyon_shell) (Arch Linux / CachyOS)
and [vexyon_shell_nixos](https://github.com/vexyon/vexyon_shell_nixos)
(NixOS). Releases before 3.0 were not recorded here; their history is in
`PROJECT_STATE.md` and the git log.

## [Unreleased]

### Changed

- **VM graphics (phase 3).** Display → 3D acceleration sets, per Linux VM,
  what "Start with 3D acceleration" uses: OpenGL through virgl, or OpenGL +
  Vulkan through Venus (experimental), with blob resources and a host
  memory window (1–8 GiB) in its advanced options; still a one-off start
  that leaves the saved VM untouched. Windows guests are told plainly that
  there is no 3D for them here (the experimental viogpu3d/Triton driver
  needs a patched host library and test-signed drivers) and pointed to GPU
  passthrough. New GPU passthrough (VFIO) section: it lists the GPUs and
  offers only one that does not drive this computer's display and has its
  own IOMMU group, with its HDMI audio; with one GPU, or the IOMMU off, it
  says why it is not offered. Before starting a VM with a passed GPU,
  Vexyon checks that no program here holds it and names the ones that do.
  Video memory can be set for QXL (16–64 MiB), VGA, VMware SVGA and Bochs
  (up to 256 MiB); VMware SVGA and Bochs are new display choices.

- **VM guest tools without manual steps (phase 2).** The guest tools disc
  (virtio-win 0.1.285: virtio drivers, QXL display driver, SPICE agent and
  QEMU guest agent in one `virtio-win-guest-tools.exe`) now ships with
  Vexyon: NixOS through the new option `services.vexyon.vm.guestTools`
  (default on), Arch through the installer, which downloads the official
  ISO and checks its SHA-256. Windows VMs are born with it in a second CD
  drive; any VM gets it with one button in Display → Guest tools, which
  also names the two Linux packages. New VMs get the QEMU guest agent and
  WebDAV channels; switches for the agent channels and file dropping are in
  the Display section's advanced options. The clipboard says what it
  carries (text and images), and Shared folders says plainly that SPICE
  cannot copy files with Ctrl+C/Ctrl+V and what works instead: dragging
  onto the VM window, virtiofs folders (Linux), or a WebDAV share from the
  VM window. Fixed: a VM whose definition libvirt refused left its new disk
  behind, so a retry with the same name failed.

- **VM manager reorganized, nothing removed.** A summary card (state, OS,
  RAM, CPU, disk, network) with Start/Resume, Pause, Shut down and the
  display as main buttons; Force off, Hard reset, the text console and
  Start with 3D in a quieter row. Sections like VirtualBox's — General,
  System, Display, Storage, Network, Ports and USB, Shared folders,
  Snapshots — each with the basics first and an "Advanced options" fold
  (CPU topology, firmware, boot order and TPM; storage controllers; network
  card model, MAC, IPs). Host networks moved to a header button. Expert mode
  (remembered) opens every fold and shows the VM's libvirt XML — editable,
  refused if its name or UUID changes — and the QEMU command line. The
  creation wizard asks name, OS, ISO, RAM, CPU, disk and network (NAT by
  default); "Advanced" has firmware, TPM, chipset (Q35/i440FX), disk bus
  and network card model. The guest OS is recorded in the VM's metadata for
  the summary. Fixed: after creating a VM its tabs showed the previously
  selected VM's hardware.

- **VM networking, phase 1: Bridged and Private NAT with port forwarding,
  without touching anything.** Each adapter now has a mode: NAT (default),
  Bridged or Private NAT + port forwarding (or any other libvirt network).
  Bridged is a libvirt network Vexyon makes itself (`vexyon-lan`, macvtap on
  the wired card that has the default route), created or re-pointed when a
  VM starts: the host's own connection is never reconfigured, and Docker
  and the firewall do not see it; this computer cannot reach its own
  bridged VMs (a macvtap limit, said in the UI). On Wi-Fi only, without a
  cable or without a wired card, Bridged is shown unavailable with the
  reason and Private NAT as the alternative. Private NAT uses passt
  (VirtualBox-style NAT): forwarded ports are edited in the adapter card,
  reachable from this computer always and from others only if your
  firewall allows it. Each adapter's advanced options show the card model,
  the MAC (editable with the VM off, or random) and its IP addresses. The
  old "create a bridge yourself" recipes are gone.
- **Arch: libvirt's iptables firewall backend is now always set** (unless
  you set one yourself), so installing Docker or ufw later no longer cuts
  the VMs' NAT; `passt` is installed, and `iptables` only if no `iptables`
  command exists.

- **AirDrop: newer upstream releases.** omdrop 0.16.4 → 0.18.12 and
  omdrop-owl → release 0.3.0 (the newest of its line; from 0.4 it is
  "Owly", a rewrite with its own system service that Vexyon does not
  integrate yet). Arch: the installer now also installs what omdrop's
  receiver imports (`python-libarchive-c`, `keyutils`); NixOS: the receiver
  check uses the packaged Python and libkeyutils. New
  `tools/update-airdrop-pins` in each repository moves both pins to the
  newest compatible releases and checks the result, so they stay
  reproducible (pinned) without going stale.

### Fixed

- **Theme switcher (Super+Alt+T) lagged when an arrow key was held.** The
  list scrolled with ListView's default follow animation (about half a row
  per key repeat), so the selection left the view and the list kept moving
  after the key was released; every row also eased its colour over 100 ms.
  The list now jumps to the selection, the highlight is instant, a held key
  stops at the ends, Home/End work, and a row scrolled under a resting
  pointer no longer steals the selection.
- **Bar widgets that did not work.** *System update* ran `sudo pacman -Syu`
  on NixOS too (and its counter could never count there): on NixOS it now
  updates the flake in `/etc/nixos` (or the channel) and shows no counter.
  *GPU temperature* was always hidden on desktops whose only GPU is an
  NVIDIA card: it now reads that card through `nvidia-smi` when there is no
  integrated-GPU sensor, and only while the card is awake. *VPN* promised
  "quick connect" but opened Quick Settings: a click now connects or
  disconnects the NetworkManager VPN. *Notes* needed `nano` (not installed
  on Arch): it uses `$EDITOR` or the first editor found, else the default
  app. *Color picker* now says which colour it copied.

- **Bookmarks could not be added at all** (right-click *Add to Sidebar* or
  dragging a folder). Since the user-folders change, `vexyon-fm-helper
  bm-add`/`bm-move` unpacked `user_dirs()` as a tuple it no longer was and
  died with a traceback, so nothing was added and nothing was said. Fixed,
  and a helper that does not answer now shows "The sidebar could not be
  updated." While a folder is dragged a "Drop a folder here" slot appears
  at the end of the bookmarks (before, only a few pixels between rows
  counted, and the middle of a row moved the folder into it).
- **"Downloads" opened ~/Descargas in an English shell.** The sidebar took
  the user folders from `user-dirs.dirs` and named them by role. It now
  finds them by their real name in your home, in the shell's language
  (Desktop, Documents, Downloads, Pictures, Music, Videos; Escritorio,
  Documentos, Descargas, Imágenes, Música, Vídeos/Videos), shows that name
  and opens that folder. Changing the language renames nothing; folders of
  the other language just stop showing.
- **File manager lost operations and showed stale folders.** Starting a
  file operation while another ran, or listing a folder while another was
  being listed, was silently dropped (one process each); they now queue,
  and a listing that comes back for a folder you already left is ignored.

- **Black screen when a video goes fullscreen in Brave/Vivaldi/Chrome.**
  With Hyprland's AutoHDR (`render:cm_auto_hdr`, on by default) the
  fullscreen window is offered an HDR image description over Wayland's
  color-management protocol; Chromium takes it, Hyprland switches the
  monitor to HDR, the HDR infoframe changes and the NVIDIA driver does a
  full modeset — the screen goes black. The bridge now emits a window rule
  with `no_auto_hdr` for Chromium-based browsers only (classes from their
  `.desktop` names, case-insensitive, `--user-data-dir` and web apps
  included) in `vexyon-settings.lua`, so it reaches existing installs —
  on Hyprland 0.56 or newer, where `no_auto_hdr` exists (older versions
  skip it). AutoHDR keeps working for mpv, games and everything else.
- **The "HDR" setting did not turn HDR on.** Settings → Displays only had a
  colour-depth selector ("10 bits (HDR/WCG)"), which sets `bitdepth` and
  leaves the monitor in sRGB. There is now an HDR switch per monitor
  (`cm = "hdr"`, always with 10 bits) with SDR brightness and saturation;
  monitors whose EDID declares no HDR say so and keep the switch off. The
  depth selector is just "8 bits / 10 bits".
- **Display changes that did not apply until a reload.** `hl.monitor()`
  merges into the rule the output already has, so leaving a field out kept
  the old value: going back to 8 bits did nothing live. Bit depth (and the
  colour mode, once chosen) are now always written out.

- **Settings → Displays: a monitor turned off vanished and could not be
  turned back on.** The page read `hyprctl monitors -j`, which lists only
  enabled monitors, so the switched-off one left the list, its profile
  stopped matching ("The connected hardware doesn't match any saved
  profile"), and since the profile kept it off it went dark after every
  login (on at the login screen, off once logged in). It now reads
  `hyprctl monitors all -j` (Hyprland's own `FALLBACK` output hidden): a
  monitor that is off stays listed, says "Off" and has its switch. Turning
  on a monitor with no saved mode (off since login, reported as 0x0) gives
  it its largest mode at its highest refresh, to the right of the others.
  The last monitor that is on can no longer be turned off. Applying a
  profile, and the 10-second revert, applied only its first monitor (one
  `hyprctl` at a time, the rest were dropped); all of them now go in one
  call. A saved mode that makes no sense is asked for as `preferred`, in
  the shell and in the bridge's `vexyon-monitors.lua`.
- **English shell, Spanish words.** The file manager's sidebar named the
  user folders after the folder on disk, so an English shell over
  `~/Escritorio` showed "Escritorio". They are named by what they are, in
  the shell's language (Desktop/Escritorio, Documents/Documentos…); the
  folders themselves are not renamed. The display-change dialog said
  "…in 8 s si no confirmas" in English; it now has a proper sentence in
  each language.
- **NixOS: "pkexec must be setuid root" (AirDrop, Settings → Modules).**
  Recent nixpkgs no longer installs `/run/wrappers/bin/pkexec` unless
  `security.polkit.enablePkexecWrapper` is set; only the store's pkexec,
  without setuid, was left, so AirDrop's radio and the module switches could
  not become root. The NixOS module now sets it (`mkDefault`, only where the
  option exists). Settings → AirDrop names this case ("This NixOS has no
  setuid pkexec…") instead of "reinstall polkit", and Settings → Modules no
  longer reports it as "Not authorized".
- **File choosers failed: "No file chooser is available … Could not activate
  remote peer 'org.freedesktop.portal.Desktop': startup job failed".**
  Since xdg-desktop-portal 1.21 the portal's unit is
  `Requisite=graphical-session.target`, and nothing in a greetd →
  `vexyon-start` → Hyprland session started that target (Hyprland exports
  its environment but does not start it), so every portal request — file
  choosers, screen sharing, the dark-mode setting — failed. The shell now
  starts `vexyon-session.target` (BindsTo `graphical-session.target`, like
  `sway-session.target`) once it is up, and `vexyon-start` stops
  `graphical-session.target` when the compositor exits (only if this
  session started it), so nothing bound to it outlives the display.
  Installed by `install.sh` (`/etc/systemd/user`) and the NixOS module
  (`systemd.user.targets.vexyon-session`).
- **AirDrop: "pkexec must be setuid root"** when turning visibility on or
  looking for devices. `vexyon-airdrop` now checks whether pkexec can become
  root and why not — not found, not setuid, on a `nosuid` mount, or the
  session has `no_new_privs` — and says so in the panel and in a new
  Settings → AirDrop row. Under `no_new_privs` the root-needing commands
  (`on`, `off`, `peers`, `send`) are re-run as a transient unit of the
  user's systemd manager (`systemd-run --user`), which does not inherit it;
  polkit still decides. AirDrop's *Change* folder no longer depends on the
  desktop portal: omdrop asks the Vexyon file manager (`OMDROP_PICKER`).
- **Headset on one side after login, again** (Corsair HS80 MAX, a 2.4 GHz
  USB dongle). The login-time mixer write was not enough: the dongle can
  apply it late or lose it after PipeWire suspends the idle device. The same
  write is now also made when playback starts on the default output (its
  first link turns active — an event, nothing polled), at most once every
  20 s. Values are written back unchanged: inaudible, balance kept.
- **Screenshots showed the selector.** The saved image could carry the
  corner handles, the border and the accent tint of the selection: the
  overlay was unmapped right before grim ran and Hyprland's layer fade was
  still drawing it. Now, on Space, the overlay hides everything it draws
  while staying on screen (fully transparent), waits for that empty frame to
  be shown, captures, and only then closes. The selection looks the same
  while dragging. Region recordings start the same clean way.
- **VMs: the dedicated-GPU button did nothing.** It only moved the
  viewer window to the dGPU, and the VMs the manager creates draw no 3D, so
  nothing changed — and in dGPU-only (MUX) mode it was not even shown. It is
  now **Start with 3D acceleration** (see Added).
- **Sound from one side only after login** (reported on a hybrid laptop
  until the volume was moved). Once per output and per session, as soon as
  its channel volumes are known, the shell now makes the same mixer write a
  volume change makes: a side left at zero is brought to the level of the
  other, otherwise the same values a hair down and back (a deliberate balance
  is kept, never louder). The OSD ignores it.
- **The screen recorder could not record system sound and the microphone
  together.** New *System + microphone* choice (see Added).
- **VM manager: a failed Start passed for a success.** The command waited
  10 s for a display that never came and exited 0, so the error was hidden
  and the viewer opened on a stopped VM; it now stops at the error.
- **User folders were created at install time, in English.** The installers
  made `~/Pictures/Wallpapers` and `~/Pictures/Screenshots` (NixOS: at every
  login), and the file manager ran `xdg-user-dirs-update` in the system
  language. Now the shell creates them once, in its own language (see
  Changed).
- The shipped `config/hypr/vexyon-keybinds.lua` seed lacked eleven binds
  (VM manager, calculator, recorder, fullscreen, theme switcher, media keys);
  regenerated from the default `shell.json`. The bridge rewrites it at login
  anyway, so only the first seconds of a first session were affected.

- **File Manager: copy/paste between two windows.** Copied or cut files were
  kept in a property of the window they were copied in, so a second window
  (or any other program) had nothing to paste. They now go to the system
  clipboard as `text/uri-list` (served by `wl-copy`), and paste reads whatever
  the clipboard holds: files from another Vexyon window or process, from
  Nautilus, Thunar, Dolphin or a browser. Ctrl+C / Ctrl+X / Ctrl+V / Ctrl+A,
  multi-selection, folders (recursive), cut = move (the source is removed only
  after a complete move), cut items shown dimmed in every window.

### Added

- **Format a USB drive from the file manager.** Right-click a USB stick or
  disk under *Devices* → *Format drive…*; a drive with nothing readable on it
  (blank, encrypted, an unknown file system) is listed there as *Not
  readable* and opens the same dialog. A name and a format — exFAT (default),
  FAT32, NTFS or ext4, each with one line on where it works — and *Erase and
  format*, pressed twice. `vexyon-format` does it through udisks2: a new
  partition table (MBR up to 2 TiB, GPT above) and one partition, then the
  drive is mounted and opened. It refuses anything that is not a USB or
  removable drive, or that holds a system mount or active swap. udisks'
  `tear-down` option is not used — it asks for the administrator password
  even with nothing in fstab — so what is mounted or unlocked on the drive
  is unmounted and locked first, as you; formatting then needs only
  `modify-device`, which the active session has without a password. Arch:
  `install.sh` installs `exfatprogs`, `dosfstools` and `ntfsprogs` (each only
  if its `mkfs` is missing; `ntfs-3g` on mirrors from before the split). NixOS:
  udisks already carries its own `mkfs` tools.
- **The Vexyon file manager is the file chooser of every app.** A browser's
  *Upload* or *Save as*, GTK apps and Flatpaks get a Vexyon file manager
  window in pick mode (open one or several files, choose a folder, save with
  a name; the app's file-type filters; replacing a file asks first; Esc or
  closing cancels). `vexyon-portal` is an xdg-desktop-portal FileChooser
  backend, D-Bus-activated only when an app asks and gone 30 s later;
  `vexyon-pick` asks the running shell (`qs ipc call vexyon pick`) and waits
  on a FIFO; the portal configuration puts it first with
  `xdg-desktop-portal-gtk` as the fallback, which it hands the request to by
  itself when the shell is not running. The session exports
  `GTK_USE_PORTAL=1` so GTK 3 apps and Firefox use the portal.
- **AirDrop** (new optional module, Settings → Modules → AirDrop, on by
  default). Send and receive files with nearby iPhones, iPads and Macs from a
  new bar button (left click: its panel; right click: visible / not
  visible): visible for 10 minutes, 30 minutes, an hour or until turned off,
  to Everyone or Contacts Only, under this computer's **host name**. The
  panel finds nearby devices (names arrive as they answer) and sends files
  picked in the desktop's file chooser, with progress and cancel. Received
  files go to the Downloads folder in the shell's language, onto the
  clipboard and into the notification center. Settings → AirDrop shows the
  Wi-Fi card and how AirDrop runs on it, what is missing, the Contacts Only
  list and the folder. Built on two upstream projects, pinned and installed
  by Vexyon: omdrop-owl (the AWDL radio, through OWL, for Wi-Fi cards
  without Apple's chip) and omdrop 0.16.4 (command and receiver). A session
  module: nothing runs until AirDrop is turned on, and only while visible.
  Its bar button is in the default layout and added once to existing ones;
  it can be moved or removed like any widget, and disappears with the
  module off.
- **Notification center: clicking a notification runs its default action**
  (for example, opening a file AirDrop received). Notifications without one
  behave as before.

- **VMs: Start with 3D acceleration.** A Linux guest's graphics are drawn
  on the dedicated GPU of a hybrid laptop, or on the main GPU when it already
  is the dedicated one (MUX in dGPU mode, desktop with one NVIDIA):
  virtio-gpu with virgl, QEMU rendering on that GPU's render node through an
  egl-headless display while the usual SPICE window shows the frames.
  Transient (`virsh create`): only that start uses it, the VM's saved
  definition does not change, and a plain Start is as before. Windows guests
  have no 3D driver for virtio-gpu. The installers let QEMU open the NVIDIA
  device nodes it needs (`cgroup_device_acl`; only with the NVIDIA driver,
  never over a value you set).
- **Screen recording: what, how and sound.** Record a whole screen (the tile
  names the workspace it shows), one window (its area on screen when you
  start) or a region; at native size or scaled down to 1440p/1080p/720p; at
  the screen's own rate or a fixed 60/30 fps; with system sound, the
  microphone, or **system + microphone** in one track. The mix is a null sink
  and two loopbacks loaded into the running PipeWire only while recording,
  and removed when it ends — also if the shell dies mid-recording.

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

- **New folder / new file ask for the name.** They used to create "New
  folder" and leave you to find it and rename it. Now a dialog asks first
  (a free name is suggested and selected), says when the name exists or is
  not valid, and the new item is selected and scrolled to. The background
  menu gained *New file*; Ctrl+Shift+N makes a folder.
- **One Trash for every drive.** Files deleted on another internal drive go,
  as before, to that drive's own trash folder (`.Trash-UID`: moving them home
  would copy them), but **Trash** now lists all of them together with the
  home trash; *Restore* puts each one back on its drive and *Empty trash*
  empties them all. On an external drive (USB) deleting no longer drops the
  file into a hidden `.Trash-1000` on the stick: the file manager says it
  will be deleted permanently and asks first. When a drive has no usable
  trash, it asks before deleting permanently instead of failing. Shift+Delete
  deletes permanently, after asking.
- **AirDrop: who can send is chosen in Settings only.** The panel lost its
  Everyone / Contacts Only chips (it shows one line while Contacts Only is
  on). Settings explains that Contacts Only is optional and needs no Mac or
  Contacts app: it is a list of Apple ID emails or phone numbers kept there.
- **Screen recording is on Super+R** (was Super+Shift+V). Existing
  installs are moved once, only while Super+R is free; a later choice of
  your own is never undone. Super+Shift+C opens the calculator, as before.
- **User folders are created once, in the shell's language**, when the
  welcome screen is closed: Desktop/Documents/Downloads… in English,
  Escritorio/Documentos/Descargas… in Spanish (xdg-user-dirs' own names), plus
  the wallpaper, screenshot and recording folders inside them. An install
  that already went past the welcome screen gets them at its next start, in
  its current language. Never again after that, never over an existing
  `user-dirs.dirs`, and `user-dirs.conf` (`enabled=False`) keeps
  `xdg-user-dirs-update` from recreating or renaming them.

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
