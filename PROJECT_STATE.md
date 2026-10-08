# PROJECT_STATE

> **Merge note:** there was no `PROJECT_STATE.md` in the uploaded repo when
> these sessions started, so this file holds only their entries (newest
> first). If you keep a local `PROJECT_STATE.md`, paste these sections into it
> instead of replacing it. The same entries are in both trees (`vexyon_shell`
> for Arch/CachyOS and `vexyon_shell_nixos` for NixOS).

## Session: VM manager — open a VM's display on the dedicated GPU (hybrid laptops)

### Files changed

| file | what |
|---|---|
| `config/vexyon/bin/vexyon-gpu-detect` | new `offload` subcommand (same block in both trees) |
| `config/vexyon/services/Vm.qml` | `dgpu` + `detectGpu()`; `start(name, onDgpu)`, `openViewer(name, onDgpu)` |
| `config/vexyon/modules/VmManager.qml` | two buttons + the explanation line; probe once when the manager opens |
| `config/vexyon/services/I18n.qml` | ES strings (11) |

**Byte-identical across trees:**
- `Vm.qml`, `VmManager.qml` and `I18n.qml` are `cmp`-identical, as before.
- `vexyon-gpu-detect` gets the same `offload` block in both trees. The two
  files still differ only where they already did: the NixOS-only `is-igpu`
  subcommand, its header lines, and the usage line.

**Not touched:** the bar panel (`VmPanel.qml`), whose "Display" button keeps
the normal launch; the bridge; `install.sh`; the Nix module.

### Read this first: what the button does, and what it does not

- **It only chooses which host GPU the viewer window (`virt-viewer`) may use.**
  The VM gets no GPU. That would be VFIO passthrough, which this project rules
  out; nothing about the domain or the guest changes.
- **Measured before building:** for the VMs this manager creates (SPICE without
  GL; `<graphics type='spice'>` has no `<gl enable='yes'/>`), the viewer does
  not use any GPU at all.
  - Setup: real QEMU 10.2.4 (qxl, SPICE, no GL), real `remote-viewer`
    (virt-viewer 11.0, spice-gtk 0.42) under Wayland.
  - The guest displayed fine. All 52 frames were `wl_shm` (CPU) buffers, and
    no GL/EGL/GPU driver library was mapped into the process.
  - Re-run with exactly the variables `prime-run` sets, plus `DRI_PRIME=1`:
    identical.
  - The source agrees: spice-gtk switches to its GL widget only when the server
    sends a GL scanout (SPICE GL); otherwise it paints with cairo.
- **So with these VMs the difference may be none,** and the UI says so. It can
  only matter for a domain the user defined with SPICE GL, where the viewer
  composes with GL. Not testable here (no GPU).
- **The user decided to build it anyway** (asked explicitly this session). The
  wording below is chosen so it doesn't promise more than that.

### UI wording (exact)

Only on hybrid machines. With no dGPU nothing is added: no button, no line.

| element | EN | ES |
|---|---|---|
| next to **Start** | Start (display on dedicated GPU) | Iniciar (pantalla en la GPU dedicada) |
| next to **Open display** | Open display on dedicated GPU | Abrir pantalla en la GPU dedicada |
| line under them, dGPU on | Dedicated GPU (NVIDIA): only the window that shows the VM uses it; the VM itself gets no GPU. VMs without 3D, like the ones created here, are drawn on the CPU either way, so the difference may be none. | GPU dedicada (NVIDIA): solo la usa la ventana que muestra la VM; … |
| line, dGPU off (amber) | Dedicated GPU is currently disabled: \<reason\>. Only the normal start is available. | La GPU dedicada está desactivada: \<motivo\>. … |

**Reasons:** envycontrol is in integrated mode · supergfxctl is in Integrated
mode · supergfxctl has reserved it for passthrough, Vfio mode · it is bound to
vfio-pci, reserved for passthrough · no graphics driver is loaded for it.

**Button states:** with the dGPU off both buttons are visible but greyed, and a
click does nothing. With it on they follow the same rules as Start / Open
display (Start only when shut off; Open display only when running).

### Detection: reused, not a second detector

`vexyon-gpu-detect offload` runs **after the same sysfs scan and the same
mode decision** that pin the shell to the iGPU. It does not touch `env`, `lua`
or `is-igpu`: 72 outputs were compared against the committed script on every
test layout, all byte-identical.

| `vexyon-gpu-detect` mode | `offload` state | UI |
|---|---|---|
| `pin`, `nopin-external` (iGPU candidate + another GPU) | **on** | both buttons active |
| `static-single`, and the only GPU is an iGPU candidate, but a dGPU is known to be off | **off** | greyed + reason |
| `static-single` otherwise (one GPU, e.g. RTX-only tower) | none | nothing |
| `static-nvidia` (Nvidia drives the displays: MUX dGPU mode, desktop) | none | nothing; the dGPU already is the main GPU |
| `static-none` | none | nothing |

**"on": which card is the dGPU.** Any DRM card that isn't the elected iGPU;
with several, the Nvidia one, otherwise the one with the most VRAM. Not
"Nvidia exists": a lone Nvidia is `static-single` → none.

**"off": how a switched-off dGPU is found.** Only checked when the remaining
GPU is an iGPU candidate:
1. A PCI display-class device (`0x03xxxx`) with no DRM card: bound to
   `vfio-pci`, or its driver blacklisted.
2. `envycontrol --query` = `integrated`, or `supergfxctl -g` =
   `Integrated` / `Vfio`. Both run with `timeout 3`, and only if the tool is
   installed.
   - In integrated mode these tools **remove the dGPU from the PCI bus**, so
     sysfs has no trace of it. Only they know it exists.
   - **Limit:** a dGPU removed by some other means looks exactly like a
     single-GPU machine, so no button appears. That is the honest answer to
     "if the detection can reliably determine this".

**How to put one app on the dGPU** (`env=`): the same mechanisms the project
already relies on. `install.sh`/`vexyon-gpu-detect` say the session pin leaves
"prime-run/DRI_PRIME" working per app.
- **Proprietary Nvidia driver:** the trio `prime-run` sets,
  `__NV_PRIME_RENDER_OFFLOAD=1 __VK_LAYER_NV_optimus=NVIDIA_only __GLX_VENDOR_LIBRARY_NAME=nvidia`.
  The pin mode sets these three the other way for the session; per app they
  are overridden.
- **Any Mesa driver** (amdgpu, radeon, i915, xe, nouveau):
  `DRI_PRIME=pci-<domain_bus_dev_fn>` of that card.
- `prime-run` itself is **not** hard-coded: the project never installs it
  (Arch's optional `nvidia-prime`; NixOS has `nvidia-offload` only with
  `hardware.nvidia.prime.offload.enableOffloadCmd`). The decision stays in
  `vexyon-gpu-detect`.

**Launch:** `env <vars> virt-viewer <same args as before>`.
- `env` execs, so the window is still class `virt-viewer`. The bridge's
  `vexyon-virt-viewer-unset-initial-ws` rule (focused monitor, not DP-1) still
  matches, and it still opens windowed (`-f` only with
  `virtualization.viewerFullscreen`).
- "Start (display on dedicated GPU)" always opens the display when the VM is
  up, even with `virtualization.openOnStart` off. It uses the same bounded wait
  for `domdisplay` as Start.

**Cost:** one `bash vexyon-gpu-detect offload` each time the VM manager window
opens (`Vm.detectGpu()` in `onVisibleChanged`). No daemon, no timer: a dGPU
only changes state across a reboot or logout (envycontrol, supergfxctl). It is
run through `bash` because a GitHub web upload drops the `+x` bit.

### Verification

**Static, both trees.** `vexyon-gpu-detect offload` against fake sysfs trees,
through the script's own `VEXYON_GPU_SYS` override plus the new
`VEXYON_PCI_SYS`. Same results in both trees:

| layout | mode | offload |
|---|---|---|
| RTX 5080 only (the tower) | static-single | **none** |
| RTX 5080 only + envycontrol/supergfxctl claiming integrated | static-single | **none** (guard) |
| Intel + NVIDIA (proprietary) | pin | on, NVIDIA, Nvidia trio |
| Intel + NVIDIA (nouveau) | pin | on, `DRI_PRIME=pci-0000_01_00_0` |
| AMD APU + NVIDIA | pin | on, NVIDIA, Nvidia trio |
| Intel + AMD dGPU | pin | on, AMD, `DRI_PRIME=pci-0000_03_00_0` |
| AMD + AMD (no boot_vga; APU found by smaller VRAM) | pin | on, AMD dGPU, `DRI_PRIME` |
| Intel + Intel Arc (xe) | pin | on, Intel, `DRI_PRIME` |
| Intel + NVIDIA, monitor on the dGPU | nopin-external | on |
| NVIDIA bound to vfio-pci | static-single | off, no-driver / vfio-pci |
| NVIDIA with no driver | static-single | off, no-driver |
| dGPU removed + envycontrol `integrated` | static-single | off, envycontrol-integrated |
| dGPU removed + supergfxctl `Integrated` / `Vfio` / `Hybrid` | static-single | off / off / none |
| dGPU removed, no switcher | static-single | none (limit above) |
| MUX dGPU mode (NVIDIA boot_vga) | static-nvidia | none |

`bash -n` passes in both trees. qmllint (Qt 6.11.2, `qs.*` tree), old vs new:
same warning counts for `Vm.qml`, `VmManager.qml` and `I18n.qml`.

**Live** (cloud container, **not the tower**): real libvirtd 12.2.0 + QEMU
10.2.4 (TCG) with a throwaway domain `vexyon-throwaway-gpu`, deleted afterwards.
**Ryoku2 was never touched.** Real shell on headless sway, opened through the
launcher with real key presses; buttons clicked with real pointer events.
- **No GPU** (this container has none → `static-single`, the same path as the
  single-GPU tower): only **Start** and **Open display**, no line.
- **Normal Start, after the change:** VM running, `virt-viewer` with the same
  arguments as before and no offload variables, `app_id` `virt-viewer`,
  `fullscreen_mode` 0.
- **Fake Intel+NVIDIA layout** → both buttons and the line. "Open display on
  dedicated GPU" → `virt-viewer` (same arguments) with the Nvidia trio in its
  environment, class `virt-viewer`, windowed.
- **Fake Intel+AMD layout, `openOnStart` off** → "Start (display on dedicated
  GPU)" started the VM and opened the display with
  `DRI_PRIME=pci-0000_03_00_0`, tiled next to the manager.
- **Fake vfio layout** → greyed buttons + amber reason; clicking the greyed
  button launched nothing.
- **Fake removed dGPU + envycontrol shim, in Spanish** → greyed + "envycontrol
  está en modo integrada".
- **Test-only shims, all in the scratch copy, none in the repos:**
  - the KVM-device and libvirt/kvm group checks were forced to pass (the
    container has no `/dev/kvm`);
  - fake sysfs trees;
  - a fake `envycontrol`.

### Not verified (needs a real hybrid laptop)

- Real dGPU offload: whether the viewer actually lands on the dGPU, power-up
  and power-down, cross-GPU buffer sharing.
- Real `envycontrol --query` / `supergfxctl -g` output. The shims print their
  documented values.
- Hyprland itself: sway was used. The focused-monitor rule is untouched and the
  window class is unchanged, which is what it matches on.
- **This tower** (RTX 5080 only): its `static-single` path was checked with the
  fake RTX-only layout and the GPU-less container, not on the tower.
- **Arch:** checked statically only (no pacman here). Its files are identical
  to NixOS except for the pre-existing `is-igpu` lines.

### To check on a hybrid laptop

1. Open the VM manager. The two "dedicated GPU" buttons and the line should
   appear, naming the dGPU.
2. Click "Open display on dedicated GPU" for a running VM. In another terminal,
   `tr '\0' '\n' < /proc/$(pgrep -n virt-viewer)/environ | grep -E 'PRIME|NV_|GLX'`
   should show the offload variables.
3. `envycontrol -s integrated` (or `supergfxctl -m Integrated`), reboot or log
   in again, and reopen the manager: greyed buttons with the reason.

---

## Session: built-in screen recorder (wf-recorder, native Quickshell UI, Super+Shift+R)

### Files changed

Byte-identical in both trees unless noted.

| file | what |
|---|---|
| `config/vexyon/services/Recorder.qml` | **new**, the only door to the recorder: switch, detection, start/stop, wrapper script |
| `config/vexyon/modules/RecorderPanel.qml` | **new**, the picker: one tile per monitor + Region, sound choice, Stop while recording |
| `config/vexyon/modules/ScreenshotOverlay.qml` | record mode: the existing region selector hands the box to the recorder |
| `config/vexyon/modules/WidgetView.qml` | `recorder` bar indicator (elapsed time + stop), click = stop |
| `config/vexyon/services/WidgetRegistry.qml` | catalog entry `recorder` (only offered with the switch on), `barSection()`, `addWidgetAt()`, `hasWidget()` |
| `config/vexyon/modules/Bar.qml` | one line: sections come from `WidgetRegistry.barSection()` |
| `config/vexyon/modules/Settings.qml` | new page **Recording → Screen recording** |
| `config/vexyon/services/Panels.qml` | `recorder`, `recordRegion`, `signal regionPicked` |
| `config/vexyon/shell.qml` | `GlobalShortcut "recorder"` + `LazyLoader` for the picker |
| `config/vexyon/modules/Launcher.qml` | "Screen recorder" entry (switch on only) + **pre-existing search bug fixed** (below) |
| `config/vexyon/modules/KeybindEditor.qml` | "Screen recording: open / stop" in the bindable shell actions |
| `config/vexyon/services/Icons.qml` | `record`, `stop` glyphs |
| `config/vexyon/services/I18n.qml` | ES strings (62) |
| `config/vexyon/shell.json`, `share/vexyon/defaults/keybinds.json` | `recorder` keybind; seed gets `"recording": {"enabled": false}` |
| NixOS `config/vexyon/bin/vexyon-seed` | `LATE` += `recorder` |
| Arch `install.sh` | `LATE` += `recorder` (and the step label) |

**Not touched, on purpose:** `nix/module.nix`, `nix/package.nix` and the
`install.sh` package list. wf-recorder is an opt-in host prerequisite exactly
like libvirt/QEMU, not a shell dependency. The Nix package and `install.sh`
already copy `services/`, `modules/` and `config/vexyon/` wholesale, so the two
new files ship with no packaging change.

### Backend: wf-recorder, and what "PipeWire" really means here

**Chosen: `wf-recorder` 0.6.0** (latest upstream tag; HEAD has only docs/packaging
commits since). Small CLI, FFmpeg libraries for encoding, built for wlroots-style
compositors, already packaged on both platforms. Alternatives looked at:
- **gpu-screen-recorder:** monitor capture needs its KMS helper with
  `cap_sys_admin` (a NixOS module / setcap), and its portal mode shows a picker
  dialog on every start. Heavier, and not a plain opt-in package.
- **wl-screenrec:** VA-API only, no software fallback.
- **OBS:** a GUI app, the opposite of this feature.

**Capture path, verified in the sources, not assumed:**
- **Video does NOT go through the portal or PipeWire.** wf-recorder 0.6.0 speaks
  only `wlr-screencopy-unstable-v1` (`proto/meson.build`). Hyprland main (0.56,
  `CMakeLists.txt`) still serves it, next to `ext-image-copy-capture`. It is the
  same protocol `grim` uses for Vexyon's screenshots, and the one
  xdg-desktop-portal-hyprland itself uses to feed PipeWire for screen sharing.
  Going direct skips the portal's share-picker dialog and one copy.
- **Sound goes through PipeWire,** via its PulseAudio server (`pipewire-pulse`,
  already a dependency on both platforms: `services.pipewire.pulse` in the
  module, `pipewire-pulse` in `install.sh`). Arch builds wf-recorder against
  libpulse only; nixpkgs builds both PulseAudio and PipeWire backends (checked
  with `ldd`). The shell always passes `--audio-backend=pulse`, which works on
  both and keeps `@DEFAULT_MONITOR@` meaningful.
- **Hyprland permissions:** screencopy is only gated when
  `ecosystem:enforce_permissions` is on (default **off**, `ConfigValues.cpp`).
  Vexyon doesn't turn it on. A user who does needs a screencopy allow rule for
  wf-recorder, as for grim.

**Region selection needs no `slurp`.** The shell already has its own region
selector (`ScreenshotOverlay`). It now has a record mode (`Panels.recordRegion`);
Enter hands the `X,Y WxH` global geometry to `Recorder.startRegion` through
`Panels.regionPicked`.

**Package names:**

| | package | verified how |
|---|---|---|
| NixOS | `wf-recorder` (nixos-26.05: 0.6.0) | built/fetched from `channels.nixos.org/nixos-26.05`; binary run; `ldd` shows libpulse + libpipewire |
| Arch | `wf-recorder` (extra, 0.6.0-1; deps include libpulse; slurp optional) | the archlinux.org package page as indexed by web search. **The environment's network policy blocks archlinux.org and every Arch mirror, so the database itself could not be queried.** Docker images were tried as a source of `extra.db`: the official and CachyOS images ship empty `/var/lib/pacman/sync`. |
| Arch, sound only | `pipewire-pulse` (extra) | same, archlinux.org page via search |

### How a recording runs (and stops)

`Recorder._launch()` runs ONE `bash -c` wrapper as a Quickshell `Process`:
`bash -c <script> vexyon-record <dir> <Recording_date> <mp4|mkv> <wf-recorder args>`.
- **Arguments:**
  - monitor: `-o NAME`; region: `-g "X,Y WxH"`.
  - sound: `--audio-backend=pulse --audio=@DEFAULT_MONITOR@` (system) or
    `@DEFAULT_SOURCE@` (mic), only when detection says sound works.
  - Always `-y` plus a name that never clashes (`Recording_<date>[-N].<ext>`),
    so wf-recorder never stops to ask anything.
- **`recording` IS `Process.running`.** The indicator binds to it: it appears
  when the process starts and goes away when it exits. No timer, no polling.
- **Stop = close the wrapper's stdin** (`Process.stdinEnabled = false`). A
  watcher in the wrapper waits for EOF on that pipe and sends wf-recorder
  SIGINT (its graceful path: it writes the trailer).
- **Shell death or reload stops it too.** Quickshell's `Process` destructor
  SIGKILLs the wrapper, and a crashed shell closes the pipe. Either way the
  watcher gets EOF, so a recording never outlives the shell, and orphaned
  watchers clean up the temp log themselves.
- **Found live, handled:** after SIGINT wf-recorder writes and closes the file
  from its encoder thread at once, but its main thread only returns on the
  *next* screencopy frame. Captures are damage-driven, so on an idle monitor
  that frame may never come. A bare `wf-recorder` stayed alive indefinitely on
  a static screen, with the file already complete.
  - libx264 prints its `kb/s:` summary when the encoder is freed, which happens
    after the file is closed.
  - The watcher waits for that line, then ends the process. A 10 s cap ends it
    regardless.
  - Hyprland source agrees: copy-with-damage frames wait for the monitor to
    render (`ScreenshareFrame.cpp`).
- **Defaults:** the codec is wf-recorder's (libx264 superfast/crf 20, yuv420p,
  AAC 48 kHz). Odd region sizes are fine: 601×301 came out 600×300. Rotated
  monitors come out upright (wf-recorder applies the output transform).

### Detection and setup instructions (same pattern as the VM manager)

**Probe:** `Recorder.detect()`, one bash.
- `command -v wf-recorder`, plus its version.
- Audio support compiled in: the `-a, --audio[=DEVICE]` help line. Note that
  `--audio-backend` is listed even in builds without audio, so it can't be the
  test.
- PulseAudio socket: `$XDG_RUNTIME_DIR/pulse/native` or `$PULSE_SERVER`.
- `/etc/os-release`.

**When it runs:** only when the Settings page or the picker opens, or when the
switch goes on. `prime()` survives the Config-not-parsed-yet race, as
`Vm.prime()` does.

**Instructions:** shown only when something is missing, chosen from
`/etc/os-release` with the same short platform list as `Vm.platform`.
- **NixOS:** "PART A: nothing to paste as a new block" (said explicitly, so the
  VM page's two-part format still reads right). Then "PART B: ADD to a list you
  ALREADY have": `wf-recorder` inside the existing
  `environment.systemPackages`, in amber, repeating the
  "attribute already defined" warning, plus a Home Manager `home.packages`
  note. Then THEN: `sudo nixos-rebuild switch` (+ flake note); no logout needed.
- **NixOS, sound missing:** "CHANGE the line you already have":
  `services.pipewire.pulse.enable = true;`. The module already defaults it on,
  so a missing server means the user set it false somewhere, and a second
  definition would conflict.
- **Arch/CachyOS:** `sudo pacman -S --needed wf-recorder`. If sound is missing,
  also `sudo pacman -S --needed pipewire-pulse` and
  `systemctl --user enable --now pipewire-pulse.socket`.
- **Unknown system:** the generic component list, no package names.

### Zero cost with the switch off

`recording.enabled` defaults to **false** (in the seed, and the code default).
With it off:
- **Shell:** the picker's `LazyLoader` is inactive. The shortcut reads Config
  first and goes to Settings → Screen recording without touching `Recorder`.
- **Bar:** `WidgetRegistry.barSection()` drops `recorder` entries, so the bar
  doesn't even create the pill's slot. Its position in shell.json is kept for
  when the switch comes back on.
- **Widget catalog and launcher:** they read Config, not `Recorder`.
- **Settings:** the page's whole body is a `Loader` (not `visible`), so opening
  the page with the switch off does not create `Recorder`. That is stricter
  than the VM page, whose `Vm.prime()` creates `Vm`.

With it on but idle there is no process and no timer. The bar has an empty
`Item` per bar whose inner `Loader` is inactive until a recording starts.

**Proven at runtime** with test-only `console.log` lines in a scratch copy (not
in the repos):

| state | what the log showed |
|---|---|
| fresh start, switch off | nothing: no singleton, no bar slot, no picker, no child process |
| Settings page opened, switch off | still no `Recorder` |
| switch on | singleton + one empty slot per bar; no content until recording |
| recording | content created on all 3 bars; on stop, destroyed on all 3 |
| switch turned off | slots destroyed on all bars; launcher search "record" → no results; shortcut → Settings page |
| restart with switch off, `recorder` still in the bar layout | zero recorder objects, zero processes |

Within one session, a `Recorder` that was created stays: QML singletons are
never destroyed. It is a few properties and two idle `Process` objects with no
process, the same as `Vm`.

**Elapsed time:** from the shared `Time` clock. The indicator holds
`Time.ssWatchers` only while it exists, so the clock ticks per second during a
recording and drops back to per-minute afterwards.

### Bar indicator

- Catalog type `recorder`, offered only with the switch on.
- Turning the switch on adds it once at the start of the right section (if it
  is not on the bar already): without it there would be no sign a recording is
  running. It is invisible except while recording, so this changes nothing on
  the bar otherwise. If removed, Settings offers "Add the recording indicator
  to the bar".
- While recording it shows: red dot, `MM:SS` (or `H:MM:SS`), a stop square.
  Clicking the pill stops. "Saving…" shows while the file is finished.
- Vertical bars stack it.

### Keybind: Super+Shift+R

**Collision check:** Super+Shift+R is in no Vexyon default and not in the seed
shell.json.
- Super+Shift is used for C (calculator), F (fullscreen, seed only), S, the
  arrows and the workspace numbers. Mouse binds are Super+mouse buttons.
- Hyprland ships no built-in binds.
- **No collision, so no question raised.**

**Behaviour:** recording → stop. Region overlay open → cancel it. Otherwise
toggle the picker. With the switch off it opens Settings → Screen recording
(like Super+V).

**Registration:** the defaults + seed carry
`{"id":"recorder","mods":["SUPER","SHIFT"],"key":"R","action":"global","arg":"recorder"}`.
- The real bridge `build_keybinds_lua` emits
  `hl.bind("SUPER + SHIFT + R", hl.dsp.global("quickshell:recorder"))`.
- It is listed in the keybind editor's actions, and shows in the keybind guide
  (calendar panel), which lists `Config.keybinds`.
- `LATE` seeding was run on copies: added once to an existing shell.json, and
  skipped when the user already had Super+Shift+R.

### Settings → Recording → Screen recording

1. **Switch,** with its zero-cost text.
2. **Status card** (green/amber, refresh button) and the granular component list.
3. **Setup for your system** (only if something is missing).
4. **Options:**
   - Sound: No sound / System sound / Microphone. One source at a time:
     wf-recorder takes a single audio device; mixing both would need a
     combined PipeWire source.
   - Format: MP4 / MKV, both H.264 + AAC.
   - Folder: default `~/Videos/Recordings`, next to `~/Pictures/Screenshots`.
5. **Open:** the current shortcut, read from shell.json; "Open the recorder";
   the "add indicator" button when needed; the last file or last error.

### Pre-existing bug fixed in passing: launcher search

`Launcher.qml` did `(a.command || a.execString || "").toLowerCase()`.
- In Quickshell 0.3.0 `DesktopEntry.command` is a `QVector<QString>` (a list),
  so this threw for every desktop entry and **any typed query aborted
  `rebuild()`**: the list never filtered. Seen in the log as
  `TypeError: Property 'toLowerCase' of object libreoffice,--impress`.
- It has been there since the first upload, and it hid the new
  "Screen recorder" entry from search.
- Now `String(...)`. Same matching, no throw. Verified: "record" → only
  "Screen recorder".

### Verified live (cloud container, NOT the user's machine)

**Setup:**
- Real wf-recorder 0.6.0 (nixos-26.05).
- Real PipeWire 1.6.6 + WirePlumber + pipewire-pulse.
- The real shell (quickshell 0.3.0, Mesa llvmpipe) on headless sway with
  HEADLESS-1 1920×1080, **HEADLESS-2 1080×1920 portrait (transform 90)** and
  HEADLESS-3.
- A test-only fake Hyprland IPC for monitor offsets and focus.
- Every click was a real pointer event (persistent `zwlr_virtual_pointer_v1`
  helper). Every key was a real `wtype` key event.
- Sound was identified by tone: 880 Hz played on the "speakers" sink, 440 Hz
  fed into a test mic.

**Detection** (by clicks in Settings):
- wf-recorder missing → red ✗ and the setup section.
- Ubuntu → generic list.
- NixOS and CachyOS (`ID_LIKE=arch`), set through a test-only os-release
  override, → their own texts, each also with sound missing.
- Installed → green "ready (wf-recorder 0.6.0)", setup hidden.

**Recordings** (all decode fully; packet DTS strictly increasing):

| target | how chosen | sound | stop | result |
|---|---|---|---|---|
| HEADLESS-3 | Enter in the picker | system | click on the bar indicator | MP4 1920×1080, AAC; tone 880 Hz |
| HEADLESS-2 (portrait) | click on its tile | mic | Stop button in the reopened picker | MKV 1080×1920, upright; 440 Hz |
| region 601×301 on HEADLESS-2 | real drag in the overlay, Enter | | Super+Shift+R on a static screen | 600×300 with the right content; wf-recorder gone in 0.12 s |
| HEADLESS-1 | → key in the picker, Enter (Spanish, Catppuccin Latte) | mic | | |
| HEADLESS-2 | | No sound | | video-only file |

**Indicator:**
- Appeared on all three bars, portrait included, the moment recording started.
- Showed the right elapsed time (00:08 at ~9 s, counted from the click).
- Disappeared on stop.
- Frame 0 of every file is clean: the picker/overlay is unmapped first.

**Stops** (wf-recorder exit after the action):
- bar click 0.15 s; picker Stop 0.15 s; shortcut 0.12 s;
- **switch turned off mid-recording 0.25 s** (file finished);
- **shell hot-reload mid-recording ~2 s** (MKV complete);
- **`kill -9` of the shell mid-recording 0.24 s** (MP4 complete with its index).
- After each: no wf-recorder, no wrapper, no temp file.
- Standalone, on a static screen with no shell, the stdin-EOF stop took
  0.32 s where plain SIGINT never returned.

**Notifications and errors:**
- "Recording saved" with path and icon reached the notification center (Vexyon
  has no popups).
- An unwritable folder (`/proc/vexyon-nope`, typed into the field) →
  "Recording failed: Cannot create …" in Settings and as a notification;
  nothing left running.

**Launcher:** the entry exists only with the switch on, and Enter opens the
picker on the focused monitor.

**Keybind:** sway has no Hyprland global-shortcut protocol. A test sway bind on
the real Super+Shift+R key ran the `onPressed` body, copied verbatim from
shell.qml at test time. Result: picker on the focused monitor, stop while
recording, Settings with the switch off.

### Static only

- **Arch (no pacman here):** the 15 shared files are `cmp`-identical to NixOS.
  `bash -n` passes on `install.sh`, `vexyon-seed` and the wrapper script
  extracted from `Recorder.qml`.
- **qmllint** (Qt 6.11.2, `qs.*` tree), old vs new for every changed file: no
  new warning type.
  - The extra counts are the existing classes: unqualified access, `Loader.item`
    typed as QObject, `GlobalShortcut` unresolved (no Hyprland plugin for lint),
    Process `onExited` typing.
  - `Recorder.qml` has only the last of those.

### Not verified here

- Real Hyprland (no GPU in the container): its screencopy path, its damage
  timing, and the global shortcut through Hyprland itself.
- The permission prompt with `enforce_permissions` on.
- Your monitors, including the real DP-2 portrait, and fractional scales.
- CPU load of software x264 at your resolutions.

### Known limits (MVP, by design)

- One audio source at a time.
- One monitor (or one region inside one monitor) per recording; wf-recorder
  can't span outputs.
- No pause, no editing, no streaming, no webcam overlay.
- Frame rate is variable, damage-driven: an idle screen records few frames.
  That is normal for wf-recorder and keeps files small.

### To check by hand on the tower

1. Settings → Recording → Screen recording: turn it on. It should show the NixOS
   / Arch lines until wf-recorder is installed, then green after the refresh
   button.
2. Super+Shift+R on each monitor, including DP-2. Pick "This screen", wait,
   press Super+Shift+R again. Play the file (`mpv ~/Videos/Recordings/…`).
3. Super+Shift+R → R → drag a box → Enter. Stop from the bar indicator.
4. Try System sound and Microphone, and check that the file has sound.
5. After stopping: `pgrep -x wf-recorder` prints nothing. For the shell, use the
   `/proc/*/exe` recipe: there is still exactly one quickshell.
6. Turn the switch off: the indicator and the launcher entry are gone.

---

## Session: DNS selector, Vexyon fastfetch greeting, Super+Shift+C calculator

### Files changed

Byte-identical in both trees unless noted.

| file | task |
|---|---|
| `config/vexyon/services/Network.qml` | DNS: read + apply (`dnsPresets`, `refreshDns`, `setDns`) |
| `config/vexyon/modules/NetworkPanel.qml` | DNS card under the Wi-Fi / Ethernet tab |
| `config/vexyon/modules/Calculator.qml` | **new**, the calculator |
| `config/vexyon/services/Panels.qml` | `calculator` flag (part of the `closeAll()` set) |
| `config/vexyon/shell.qml` | `GlobalShortcut "calculator"` + `LazyLoader` |
| `config/vexyon/modules/KeybindEditor.qml` | "Open calculator" added to the bindable shell actions |
| `config/vexyon/modules/Settings.qml` | Behavior → Terminal: greeting choice |
| `config/vexyon/services/I18n.qml` | ES strings for all three |
| `config/vexyon/shell.json`, `share/vexyon/defaults/keybinds.json` | `calculator` keybind |
| `config/vexyon/bridge/vexyon-bridge.py` | fastfetch config + generated fish greeting. Same change set in both trees; the files differ elsewhere, so it was patched, not copied. |
| `config/fish/conf.d/vexyon-greeting.fish` | **deleted in both trees.** The bridge generates it now. When uploading, delete `config/fish/` on GitHub too. |
| NixOS `config/vexyon/bin/vexyon-seed` | `LATE` += `calculator` |
| Arch `install.sh` | `LATE` += `calculator`; the `cp config/fish` line removed (the directory no longer exists) |

No new daemon, process, poll or dependency. The calculator is pure QML,
fastfetch was already installed, and DNS uses the `nmcli` the module already
calls.

### Prerequisite: Wi-Fi module

- The `--rescan no` fix from the earlier session is present and identical in
  both trees (`Network.qml` lines with `device wifi list --rescan no`).
- **Live, with real NetworkManager 1.56:** the quick-settings tile and the
  network panel showed the connected device and its DHCP address
  immediately.
- **Not testable here:** a real Wi-Fi radio (none in the container), so the
  Wi-Fi tab itself was not clicked.

### Task 1: DNS selector

**Per connection, not global.** It writes `ipv4.dns`/`ipv6.dns` +
`ipv{4,6}.ignore-auto-dns` into the NetworkManager **profile of the active
connection** on the current tab's device (Wi-Fi tab → active Wi-Fi, Ethernet
tab → wired). So home Wi-Fi can use Cloudflare while café Wi-Fi stays
automatic, and the choice follows that profile. Nothing global
(`NetworkManager.conf`), and no root needed beyond what NM's polkit already
grants for editing connections. The card says so: "Only for this connection:
\<name\>".

**Choices:**

| choice | IPv4 | IPv6 |
|---|---|---|
| Automatic | from DHCP | from RA |
| Cloudflare | 1.1.1.1, 1.0.0.1 | 2606:4700:4700::1111, ::1001 |
| Google | 8.8.8.8, 8.8.4.4 | 2001:4860:4860::8888, ::8844 |
| Quad9 | 9.9.9.9, 149.112.112.112 | 2620:fe::fe, 2620:fe::9 |
| Custom | free list, spaces/commas, validated in the panel | (same list) |

**Shows what is really in use:** `nmcli device show <dev>` (`IP4.DNS`/`IP6.DNS`)
in the card header. That works the same with `dns=default` (NixOS default,
resolvconf) and with systemd-resolved.

**Commands** (each verified against real NM 1.56 before writing code):
1. `nmcli connection modify <uuid> ipv4.dns "<list>" ipv4.ignore-auto-dns yes|no [ipv6.dns … ipv6.ignore-auto-dns …]`
2. `nmcli device reapply <dev>`: applies to the **live** connection without
   deactivating it. Measured ~20 ms; the device stays `100 (connected)`; no
   reactivation.
3. Only if NM refuses the reapply: `nmcli connection up <uuid>` (a short
   drop). The panel shows "Reconnecting to apply DNS…" while that happens,
   then "DNS updated (reconnected)".
4. Errors from `nmcli` (invalid address, permissions) are shown in red. A
   failed `modify` changes nothing.

**IPv6:**
- A non-automatic choice ignores the automatic DNS of **both** families.
  Otherwise the router's RA DNS would keep leaking past the choice.
- IPv6 servers are set only if the list has some. IPv4 servers resolve AAAA
  too.
- NM **rejects** `ipv6.dns` when `ipv6.method` is `disabled` or `ignore`
  (tested: "this property is not allowed for method=…"). For such profiles
  only IPv4 is touched, and the card says "IPv6 off, IPv4 only".

**Cost:** read on demand (panel open, tab or connection change, after
applying). No new timer or poll.

**Verified live (cloud container, NOT the user's machine).** Setup: real NM
1.56 + **systemd-resolved** + dnsmasq (DHCP DNS 10.77.0.53), all in a private
network/mount namespace (the container's `/etc` and `/run` untouched). The
real shell was driven by real pointer and keyboard events. Results:
- **Opening:** control centre → Ethernet tile → panel → DNS card
  "Automatic · In use: 10.77.0.53".
- **Cloudflare:** `resolvectl dns` → `1.1.1.1 1.0.0.1`; NM still connected,
  same active connection; "DNS updated, without reconnecting".
- **Custom, typed:** "9.9.9.9 2620:fe::fe" → `resolvectl` 9.9.9.9; profile
  has both families. An invalid "1.2.3.400" was rejected in the panel and
  the profile left untouched. Custom via the Apply button works too.
- **Forced reapply failure** (test-only `nmcli` wrapper): the
  reconnect path ran, showed its status, and Google ended up live.
- **Restore:** "Automatic" → profile back to empty lists +
  `ignore-auto-dns no`, exactly as before; `resolvectl` back to 10.77.0.53.
- **Light theme** (Catppuccin Latte): the card reads fine.

**Test-only shims:**
- The sandbox veth reports TYPE `veth`, which the panel (rightly) ignores. A
  wrapper relabelled it `ethernet` in the device table only; every DNS
  command went to the real nmcli.
- **IPv6 could not be tested on the wire:** this container's kernel has no
  IPv6 (no `AF_INET6`). IPv6 was verified at profile level (stored by NM,
  shown in `IP6.DNS`), not by resolved.

### Task 2: Vexyon fastfetch on terminal open

**What was there:**
- The bridge already generated a themed `~/.config/vexyon/fastfetch.jsonc`
  (custom fields, theme colours, but fastfetch's stock small **distro**
  logo).
- A static `config/fish/conf.d/vexyon-greeting.fish` ran it once per
  terminal.
- **On Arch** `install.sh` copied that file. **On NixOS nothing installed
  it** (not the package, not `vexyon-seed`), so a clean NixOS home never ran
  fastfetch.
- The separator line rendered as `──�`: fastfetch's auto length repeats the
  3-byte `─` by bytes and cuts the last one.

**Now (through the existing bridge generation, both OSes):**
- **`fastfetch.jsonc`** (still `~/.config/vexyon/`):
  - Logo: a Vexyon "V" emblem + `v e x y o n` wordmark, inline `"data"` logo
    with `$1`/`$2` = theme `accent`/`accent2`, 15 columns wide like the old
    small logo.
  - Separator uses an explicit `times` = width of `user@host`, so no broken
    character.
  - Disk limited to `/`.
  - **`packages` removed**: that is the expensive probe; it walks the Nix
    profiles on NixOS.
- **`~/.config/fish/conf.d/vexyon-greeting.fish`** is now **generated** by the
  bridge (written in `regenerate_terminal`, i.e. on every `shell.json` change
  and at session start; Arch's `install.sh --oneshot` too). It follows
  `behavior.terminalGreeting`, set in **Settings → Behavior → Terminal**:
  - `vexyon` (default): `fastfetch --config ~/.config/vexyon/fastfetch.jsonc`
  - `own`: plain `fastfetch`, i.e. the user's own
    `~/.config/fastfetch/config.jsonc`, or fastfetch's default. **Vexyon
    never writes `~/.config/fastfetch/`.**
  - `off`: no greeting.
  - A `fish_greeting` defined in `~/.config/fish/config.fish` always wins
    (fish reads `conf.d/` first).
- **Unchanged:** once per new terminal (`VEXYON_GREETED`), interactive
  shells only.

**Startup cost** (same container; real fish 4.7.1 + fastfetch 2.63.1):
- **fastfetch alone** (median of 20): old config **88.6 ms** → new **8.7 ms**.
  With `--stat`, `packages` alone took ~291 ms on its cold first run.
- **Time to the first fish prompt** (pty harness answering fish's terminal
  queries like a terminal; median of 10):

| greeting | first prompt |
|---|---|
| off | 39 ms |
| new Vexyon greeting | 59 ms (+20 ms) |
| previous greeting + old config | 143 ms |

**Verified live:**
- Super+T in the headless session opened a real **Ghostty 1.3.1** showing
  the Vexyon emblem in the theme's colours. Crimson and Gruvbox were both
  checked.
- Clicking each Terminal option in Settings and regenerating gave:
  - **Off:** prompt only.
  - **My fastfetch config:** the user's own file is shown, and its md5 was
    unchanged afterwards.
  - **Vexyon:** back to the emblem.
  - A `fish_greeting` in `config.fish` overrode it.
- **Test caveats:**
  - Only the bridge's terminal step (`regenerate_terminal`) was run on each
    saved `shell.json`. The whole daemon wasn't, because its greeter sync
    writes system paths.
  - fastfetch resolves its config dir from the passwd home unless
    `XDG_CONFIG_HOME` is set, so the test home had to set it. On a real
    login HOME is the passwd home.

### Task 3: Super+Shift+C calculator

**Keybind collision check:**
- Super+Shift+C is **not** used by any Vexyon default.
- The only `C` bind is Super+C (control centre).
- The Super+Shift set is S (scratchpad), the arrows (swap) and the workspace
  numbers.
- Hyprland ships no built-in binds; Vexyon generates them all. **No
  collision, so no question raised.**
- An existing user who already put something on Super+Shift+C keeps it. The
  late-keybind seeding (`vexyon-seed` / `install.sh`, `LATE`) skips
  occupied combos.

**Registration** (the existing mechanism):
- `{"id":"calculator","mods":["SUPER","SHIFT"],"key":"C","action":"global","arg":"calculator"}`
  in the defaults and the seed.
- The bridge emits
  `hl.bind("SUPER + SHIFT + C", hl.dsp.global("quickshell:calculator"))`,
  checked by running the real `build_keybinds_lua`.
- `GlobalShortcut "calculator"` → `Panels.toggle("calculator")`.
- Listed in the keybind editor's actions, so it can be remapped.

**Placement:** `screen: Panels.openScreen`, which `Panels.toggle` sets from
`focusedScreen()` **at open time**. This is the launcher/power-menu
mechanism, not a binding to a function.

**Lazy loading:**
- `LazyLoader { active: Panels.calculator; Calculator {} }`.
- Proven at runtime with test-only log lines in a scratch copy: nothing is
  created at shell (re)load, it is created on open (on the focused monitor)
  and destroyed on close, every time.

**UI and input:**
- Basic arithmetic: + − × ÷, decimals, brackets, live "= result" preview.
- Evaluated by a small recursive-descent parser, **never `eval`**. Unclosed
  brackets are closed for you, and 0.1+0.2 shows 0.3.
- Keyboard: digits . , + - * / x ( ), Enter/= evaluate, Backspace, Delete
  clears, Esc closes. Mouse: every key on the pad. Click-outside closes.
- Theme tokens throughout. ES strings added.

**Verified live (real key and pointer events):**
- **Keyboard:** typed `12*(3+4)-5/2` → preview 81.5 → Enter 81.5; `+0.5` →
  82; `7/0` → "Can't divide by zero"; Backspace + numpad Enter → 1.75.
- **Mouse:** C 7 × 6 = → 42.
- **Esc and click-outside both close it.**
- **Monitors:** focus moved by clicking workspaces on HEADLESS-1's bar
  (pointer left there). The calculator opened on HEADLESS-1, on the
  **portrait HEADLESS-2** and on HEADLESS-3, each time on the focused
  monitor.
- **Themes:** Crimson Voltage, Catppuccin Latte, Gruvbox Dark.
- **Hotkey hop emulated:** sway can't do Hyprland's global-shortcut
  protocol, so a test sway bind on Super+Shift+C triggered the same
  `Panels.toggle("calculator")` through a scratch-copy driver.

### Static only

- **Arch (no pacman):** the shared files are `cmp`-identical to NixOS. Both
  bridges carry identical change sets and parse. `bash -n` passes on
  `install.sh` and `vexyon-seed`.
- **qmllint:** no new type or property errors in the changed files. Only the
  "unqualified access" and Process `onExited` typing classes the codebase
  already has.

### Known, pre-existing, left as is

- `PowerMenu.qml`'s backdrop `#000000aa` is fully transparent: QML reads
  8-digit hex as `#AARRGGBB`. The calculator uses `Qt.rgba`.
- In the network panel's Ethernet card, the Disconnect button sits mid-row.

### To check by hand on the tower

1. **DNS:** open the network panel on your Wi-Fi and pick Cloudflare. Check
   `resolvectl status` or `nmcli dev show`, then pick Automatic.
2. **Terminal:** Super+T shows the Vexyon emblem. Try Settings → Behavior →
   Terminal → Off / My fastfetch config.
3. **Calculator:** Super+Shift+C on each monitor; type a sum and press Enter,
   then Esc.

---

## Session: bar styles (Default / Islands / Bordered / Rail), pure Quickshell

Selectable bar **styles**: form only, orthogonal to colour themes. Three new
styles plus the existing look as **Default**. Nothing changes for anyone who
doesn't open the selector: the Default style was compared pixel-for-pixel
against the pre-change bar (see Verified).

### Files changed (byte-identical in both trees)

| file | what |
|---|---|
| `services/BarStyles.qml` (new) | the 4 presets (static data) + `apply(id)` |
| `components/ConcaveCorner.qml` (new) | inverted corner for the Rail style (plain `Rectangle` border trick, no Canvas/Shapes) |
| `modules/Bar.qml` | islands, border colour role, edge corners + input mask, auto-hide sliver |
| `modules/BarWidget.qml` | flat widget shape, automatic separators |
| `modules/WidgetView.qml` | dot workspace indicator |
| `modules/ThemeSwitcher.qml` | "Bar style" row above the colour themes |
| `services/I18n.qml` | 10 ES strings |

No new dependency, process, timer, watcher or store. No change to the bridge,
`install.sh`, the Nix package (it copies whole `components/`, `modules/`,
`services/`) or `vexyon-seed`.

### How styles are structured and kept orthogonal

- **A style is a set of `bar.*` keys**, nothing else. `BarStyles.presets` holds
  four static objects. `BarStyles.apply(id)` copies the current `bar` section,
  overlays the preset's keys, sets `bar.style = id`, and writes it with **one**
  `Config.setSection("bar", …)`.
- **No colour values in any preset.** Where a style wants emphasis it names a
  palette **role** (`borderColor: "accent"`), and `Bar.qml` resolves it through
  `Theme`. Every style therefore follows every theme, including light ones.
- **Every preset sets the same keys**, so switching never leaves a key from the
  previous style behind.
- **Never touched by a style:** position, screens, auto-hide, exclusive zone,
  maximize detection, scroll, tray tint, font/icon scale, the widget layout.
  Verified: switching style kept position/auto-hide/maximize-detect as set.
- **Tweaks made in Bar settings after picking a style stay on top of it.** The
  card stays marked active. Picking **Default** writes the shipped values back
  (the seed `shell.json`), so earlier hand-tuned spacing is replaced. That's
  intentional ("restore the shipped look"), but worth knowing.
- **Widgets are not duplicated per style.** The same `BarWidget`/`WidgetView`
  read a few keys. Style-only decorations (islands, corners, separators) sit
  behind inactive `Loader`s, so a style that doesn't use them creates nothing.

**Keys.** Existing keys used by presets: `barSize`, `edgeGap`, `marginSides`,
`padding`, `pillGap`, `cornerRadius`, `backgroundStyle`, `bgOpacity`, `border`,
`shadow`, `widgetOutline`, `widgetTransparency`.

New keys (absent = default = the original look):

| key | values | effect |
|---|---|---|
| `style` | `default` / `hyde` / `jakoolit` / `ryoku` | which card is marked active (informational) |
| `widgetShape` | `pill` / `flat` | flat: no pill at rest, a rounded veil on hover, same hit area |
| `islands` | bool | the bar background is drawn per section instead of full length |
| `separators` | bool | thin `overlay0` line between visible neighbours in a section |
| `borderColor` | `subtle` / `accent` | subtle: 1 px `overlay0`@0.4 (as before); accent: 2 px `Theme.accent` |
| `workspaceStyle` | `pill` / `dot` | dot: 8 px dots, focused one elongated, no numbers |
| `edgeFillets` | bool | concave corners where a flush bar meets the screen edge |

### What each style changes

| | Default | Islands (HyDE-like) | Bordered (JaKooLit-like) | Rail (Ryoku-like) |
|---|---|---|---|---|
| bar size / edge gap / side margin | 38 / 6 / 8 | 40 / 6 / 10 | 34 / 4 / 4 | 40 / 0 / 0 |
| padding / gap between widgets | 8 / 4 | 12 / 2 | 6 / 9 | 16 / 6 |
| corner radius | 12 | 16 (leaf) | 10 | 0 |
| background | solid, opacity 1.0 | one island per section, 0.82 | continuous, 0.94 | continuous, 1.0 |
| border | none | none | 2 px accent | none |
| widgets | pills | flat | flat + separators | flat |
| workspaces | pills | pills | pills | dots |
| extra | | | | concave corners at both ends |

Style details:
- **Islands, leaf corners:** the start section rounds top-left and
  bottom-right, the end section mirrors it, the centre rounds all four. Each
  island spans the bar's thickness and extends `padding` past its widgets.
  Measured on screen: big corners 11 px inset, small 1 px, exactly as designed.
  The existing bar blur (`appearance.barBlur`, bridge layer rule with
  `ignore_alpha 0.2`) blurs the islands and not the gaps.
- **Rail, concave corners:** corner size = `Theme.radius`. The window grows by
  that much inward. The **exclusive zone does not**: windows still tile against
  the rail, and an input mask (`Region`) makes the corner strip click-through.
  The corners only draw when the bar really is flush (edge gap 0 and, for
  horizontal bars, side margin 0); change either and they disappear. They are
  hidden while auto-hidden or flushed by fullscreen.
- **Separators** skip widgets that hide themselves (empty tray, no media,
  no battery) and are never drawn next to a user spacer/separator.
- **Dot workspaces:** the hit area stays the pill's (22 px thick, half the gap
  on each side). The pill is kept when the user enabled workspace names or app
  icons. Colours come from the existing workspace role settings.
- **Vertical bars** (left/right) get the same shapes rotated: corners,
  separators, island corners and dots.

### Persistence and regeneration path

Card click → `BarStyles.apply(id)` → `Config.setSection("bar", …)` → one atomic
`shell.json` write → `Config.data` changes → every `Config.get("bar", …)`
binding in `Bar`/`BarWidget`/`WidgetView`/`Theme` re-evaluates. This is the
same event-driven path the Bar settings page already uses.

The bridge sees the same file change it already watches. It doesn't read
`bar.*` (only `appearance.barBlur`), so nothing regenerates on the Hyprland
side, and nothing needs to. A style costs one write when chosen and nothing
while in use.

### Fixed in passing (needed by Rail)

**Auto-hide could never come back on a flush bar.** The reveal hover area was
only the edge-gap sliver (`edgeGap` px), so with `edgeGap` 0, as in Rail or
any user who set it, the hidden bar had nothing left to hover.
- The hide distance is now `barSize - max(0, 2 - edgeGap)`, keeping at least
  a 2 px sliver.
- Bars with a gap of 2 px or more slide exactly as before.
- Verified: Rail + auto-hide hides, reveals on hover at y=1 with its corners,
  and hides again.

### Settings

**Theme & colors** now opens with **Bar style**: four cards, each with a
miniature drawn from the preset's own values at ½ scale in the active theme's
tokens, a name, a one-line description and the active check mark. **Color
theme** follows with the existing grid. EN + ES strings.

### Verified (in a cloud container, NOT on the user's machine)

**Setup:** the real shell on headless sway with three outputs:
- HEADLESS-1 1920×1080
- HEADLESS-2 rotated 90°, so 1080×1920 portrait
- HEADLESS-3 1920×1080

Plus a wallpaper, and a fake Hyprland IPC that answers dispatches by really
moving workspace focus and emitting the events.

**Real clicks now work in the test setup.** The "clicks could not be verified"
limit in earlier sessions was a harness artefact: each `wlrctl` call created
and destroyed its own pointer device, so the seat's pointer capability flapped
and the client never held a `wl_pointer` when the button arrived. A test-only
persistent `zwlr_virtual_pointer_v1` client (scratchpad, stdlib Python, not in
the repos) delivers enter/press/release/wheel, confirmed in a server-side
protocol trace. **Every action below was a real pointer event**, no IPC or test
driver:

- **Settings opened by clicking:** control-centre pill → gear.
- **All 24 style × theme combinations, switched by clicking cards:** 4 styles ×
  Crimson Voltage, Catppuccin Latte, Rosé Pine Dawn, Tokyo Night, Gruvbox Dark
  and White. Every switch was a click except Crimson Voltage + Default, which
  is the startup state. Each was captured on all three monitors and
  `shell.json` checked after every click. Every style follows every theme,
  light ones included.
- **Hover:** flat widgets show the veil on hover.
- **Workspace clicks:** a click on workspace 2 dispatched
  `hl.dsp.focus({ workspace = 2 })` and the indicator followed. In dot mode, a
  click 8 px below a dot (outside it, inside the hit area) focused it.
- **Wheel on the bar** dispatched `workspace "e+1"` and the indicator moved.
- **Panels:**
  - **Islands:** the clock opens the calendar centred under the centre
    island.
  - **Rail, top:** the control centre opens Quick Settings right-aligned
    under the rail. The clock on the **portrait** monitor opens the calendar
    there.
  - **Rail, bottom:** the same panels open above the rail on HEADLESS-3 and on
    the portrait monitor.
  - Focus-aware placement code (`Panels.openAt`/`stripEdge`) is untouched and
    reads no new key. The taller Rail window only adds to the cross axis, which
    `stripEdge` takes from `barSize + edgeGap` as before.
- **Rail corner strip is click-through:** a test window on the Bottom layer
  under it received the click at y=46 (corner strip). It received nothing at
  y=20 (rail). The workspace usable area starts at y=40 on all three outputs,
  so the exclusive zone is unchanged.
- **Positions:** bottom (Rail) and left (Rail, Islands, Bordered) chosen by
  clicking Bar settings → Position. Corners, leaf islands, horizontal
  separators and vertical dots all render correctly, including on the portrait
  monitor.
- **Fullscreen flush with Islands** (maximize detection on): a solid flush
  strip while fullscreen, islands again after.
- **Default style = old bar:** pixel diff of all three bars against the
  pre-change code with the seed config. The only differences were live numbers
  (CPU 9%→10% shifting one pill; the clock's minute). After cycling through
  every style and back to Default, every form key equals the seed.
- **Logs:** no QML warnings from the changed files.
- **qmllint** (Qt 6.11.2, `qs.*` module tree):
  - `BarStyles.qml` and `ConcaveCorner.qml` are clean.
  - The changed files add only the "Unqualified access" class the codebase
    already has throughout (outer ids used inside delegates/Loader
    components).
  - No type or property errors.
- **Arch:** checked only statically (no pacman). The 7 files are
  `cmp`-identical to the NixOS tree, and `install.sh` copies `config/vexyon/`
  wholesale.
- **Not verified here:**
  - Real Hyprland: no GPU, so the island blur and Hyprland's own layer
    handling of a window taller than its exclusive zone are untested (sway
    handles it correctly).
  - Keyboard-opened panels on the focused monitor: global shortcuts don't
    exist in sway, and quickshell IPC can't bind here. That code is unchanged.
  - Your monitors and scales.

### Known, pre-existing, left as is

- `CalendarPanel.qml:196` logs `Unable to assign [undefined] to double` when
  the calendar opens. A `Translate` reads `parent.drift`, and a transform has
  no `parent`. It is unrelated to styles and was not touched.
- In a fullscreen-flushed or vertical bar, `marginSides` doesn't apply (the
  existing rule), so Islands' end islands touch the screen edge on left/right
  bars. Same as the full-length background always did.

### To check by hand on the tower

1. Settings → Theme & colors: click each Bar style card on each monitor,
   including the portrait one.
2. With Islands, check the blur behind the islands and none in the gaps.
3. With Rail:
   - check the corners on all three monitors;
   - click a window right under a corner;
   - turn auto-hide on and off.
4. Open Quick Settings and the calendar from the bar, and by shortcut on a
   non-primary monitor, in each style.
5. Pick Default to return to the shipped look.

---

## Session: add all Omarchy themes

### Prerequisite checked first

The bar-theming fix is in place in both trees, byte-identical:
- `Theme.accentFg`/`accent2Fg` exist.
- `WidgetView.qml` reads them in 32 places, with no `peach`/`mauve`/`teal`
  leftovers.
- The bar was re-rendered for every new theme below.

### Source

**Omarchy v4.0.4**, the latest release tag at the time: commit `c668141e9c42`,
2026-09-14, repository `basecamp/omarchy` (default branch `quattro`).

- **Palette:** each theme's `themes/<name>/colors.toml`.
- **Published window border:** `hyprland_active_border` in that file, or the
  theme's own `themes/<name>/hyprland.lua` where it ships one.
- **Per-theme link:**
  `https://github.com/basecamp/omarchy/blob/v4.0.4/themes/<name>/colors.toml`
- **How it was read:** a read-only shallow clone of that public repo into the
  session scratchpad. The GitHub API, tarballs and jsDelivr were blocked, and a
  directory listing was needed to find every theme. No git was used on either
  Vexyon repo.

v4.0.4 ships **22 themes**. Its manual's gallery lists 19: Last Horizon,
Lupine and Solitude are in `themes/` but not yet in the gallery.

### Added: 14 themes

Each is a new `share/vexyon/themes/<id>.json`, identical in both trees.
Display names follow Omarchy's own `omarchy-theme-list` title-casing.

| id | name | mode | accent | accent2 |
|---|---|---|---|---|
| ethereal | Ethereal | dark | `#7d82d9` | `#c2c4f0` |
| flexoki-light | Flexoki Light | light | `#205ea6` | `#4385be` |
| hackerman | Hackerman | dark | `#82fb9c` | `#2ec27e` |
| last-horizon | Last Horizon | dark | `#b59790` | `#e2dddc` |
| lumon | Lumon | dark | `#8bc9eb` | `#f2fcff` |
| lupine | Lupine | light | `#3264eb` | `#5482ff` |
| matte-black | Matte Black | dark | `#e68e0d` | `#f59e0b` |
| miasma | Miasma | dark | `#78824b` | `#78824b` |
| osaka-jade | Osaka Jade | dark | `#509475` | `#acd4cf` |
| retro-82 | Retro 82 | dark | `#faa968` | `#faa968` |
| ristretto | Ristretto | dark | `#f38d70` | `#f8a788` |
| solitude | Solitude | dark | `#798186` | `#cacccc` |
| vantablack | Vantablack | dark | `#8d8d8d` | `#8d8d8d` |
| white | White | light | `#6e6e6e` | `#1a1a1a` |

### Already present: not duplicated

| Omarchy | Vexyon | how it differs |
|---|---|---|
| catppuccin | catppuccin-mocha (bundled) | Omarchy uses a blue accent, Vexyon mauve |
| catppuccin-latte | catppuccin-latte (bundled) | blue accent vs mauve |
| gruvbox | gruvbox-dark (bundled) | Omarchy's is the Gruvbox **Material** variant (fg `#d4be98`, accent `#7daea3`) |
| kanagawa | kanagawa-wave (bundled) | Omarchy accent = its foreground `#dcd7ba` |
| rose-pine | rose-pine-dawn (bundled) | Omarchy's rose-pine is the light Dawn variant, accent foam `#56949f` vs rose |
| tokyo-night | tokyo-night (bundled) | same accent, different text tier |
| nord | nord (theme store) | accent `#81a1c1` vs `#88c0d0` |
| everforest | everforest (theme store) | accent `#7fbbb3` vs `#a7c080` |

Same families under the same names. Vexyon's versions were kept, and
Omarchy's variants were not added as near-duplicates. If you want
Omarchy-exact variants of any of these (e.g. Gruvbox Material), that's a
separate decision.

### How Omarchy's palette maps onto the existing 23 keys

**Every value is copied verbatim** from the theme's Omarchy files, lowercased
to match the existing files' style. Nothing is mixed, computed or approximated.
A provenance check confirmed all 14 × 24 values trace back to the source.

| Vexyon key | Omarchy key |
|---|---|
| base / mantle / crust | background / dark_background / darker_background |
| surface0 / surface1 / surface2 | lighter_background / selection / muted |
| overlay0, overlay1, overlay2 | dark_foreground |
| text | foreground |
| subtext1, subtext0 | light_foreground |
| accent | accent |
| red / green / yellow / blue | red / green / yellow / blue |
| peach | orange (missing in three themes → yellow, Omarchy's own fallback) |
| mauve | bright_magenta |
| teal | cyan |
| pink | magenta |
| accent2 | the end colour of the published active-border gradient if the theme has one (Hackerman, Last Horizon, Solitude), else `bright_blue` |
| onAccent | `background` or `foreground`, whichever has more contrast on `accent` |

Notes on the mapping:
- **Why it holds:** Omarchy's Catppuccin lines up exactly with Catppuccin's
  canonical tiers through this mapping.
- **`accent2`:** Omarchy sets `blue` = its accent, so `bright_blue` is the
  accent's own bright companion. With this rule, Lumon's and Retro 82's
  `accent2` is exactly their published border colour.
- **Light theme:** `dark` is `mode == "dark"`.
- **Structure:** the same 23 keys and the same file format as the existing
  themes; the JSON serialization reproduces existing files byte-for-byte.
- **One optional key:** Lupine's `accent2` (`#5482ff`) is 2.55:1 on the bar
  pill, so it gets `accent2Fg` = its own published `cyan` `#0c67de` (3.82,
  same blue family). No other new theme uses the optional keys.

**i18n:** none needed. Theme names are shown verbatim (`modelData.name`)
everywhere, and no existing theme name is in `I18n.qml`.

**Other files:**
- **README:** the "6 bundled themes" line (stale since 12) now says 26, in
  both trees.
- **No code changes.**

### Verified (in a cloud container, NOT on the user's machine)

**Bar, Quick Settings panel, OSD, power menu and lock screen** were rendered
for all 14 themes on the real shell: headless sway, quickshell 0.3.0, Qt GL on
llvmpipe, a fake Hyprland IPC, and real PipeWire with a null sink.
- Themes were switched through `Theme.apply()`.
- The OSD was triggered by real `wpctl set-volume` changes.
- Panels and the lock screen were opened through a test-only command file
  added to a **scratch copy** of `shell.qml`. It is not in the repos, and it
  calls the same `Panels.toggle`/`Lock.lock`.
- Every surface shows its theme's published colours and stays legible, light
  themes (Flexoki Light, Lupine, White) included. No QML errors.
- **Clicks could not be verified:** neither `wlrctl` nor sway's
  `seat cursor press` delivered button events in headless sway, confirmed with
  a Wayland protocol trace. Real clicks remain to be tested on the tower.

**Window borders** (Hyprland can't run here: no GPU):
- The real bridge `build_settings_lua()` output for each theme, rendered as a
  colour visualisation. Active is always clearly distinct from inactive.
- **Exact match to Omarchy's published active border:** Retro 82, Miasma and
  Vantablack (solid accent), and Solitude (its gradient). Last Horizon's
  inactive border also matches exactly (`#584e51aa`).
- **Published end colour reproduced:** Hackerman, Last Horizon and Lumon.
  Vexyon's gradient always starts at `accent`.
- **Everywhere else:** Vexyon's accent→accent2 gradient where Omarchy draws a
  solid accent. Inactive borders follow Vexyon's `surface1`+`aa` rule rather
  than Omarchy's `#595959aa`. That is the existing border rule, intentionally
  not restructured.

**Greeter:**
- The bridge's `sync_greeter_theme` produced byte-identical snapshots for
  14/14 new themes.
- The manual `vexyon-greeter-sync-theme` matched too.
- The real greeter QML renders Flexoki Light and Hackerman from the synced
  snapshot.

**Trees:** both have identical theme sets (26 files each, `md5sum` diff
empty), the same store catalog and the same README line.
- **Arch:** checked only statically (no pacman). `install.sh` copies
  `share/vexyon` on install.
- **NixOS:** new theme files are seeded copy-if-absent, and changed ones are
  refreshed once per build by `vexyon-seed`.

### Contrast caveats (published values kept, nothing invented)

- **Date text** (accent on the bar pill, small text) is under 4.5:1 for:
  Ethereal 4.36, Last Horizon 4.03, Lupine 3.68, White 3.37, Solitude 3.33,
  Osaka Jade 3.31 and Miasma 3.11. Bar icons in every new theme are ≥3.11:1.
- **Flexoki Light `accent2`** `#4385be` is 2.81:1 (memory and upload icons,
  active states). Its published palette has no darker same-hue colour.
- **Miasma** labels are 3.67:1 and its focused-workspace number 3.86:1.
  Omarchy's Miasma is deliberately muted.
- **Single-accent themes:** Miasma, Retro 82 and Vantablack have
  `accent2 == accent` in Omarchy's palette. Their bar "active" states don't
  change colour, and their borders are solid, exactly as published.

### To check by hand on the tower

Pick each new theme in the switcher, open Quick Settings, change the volume,
lock, and check window borders, including on the portrait monitor.

---

## Session: bar widgets didn't adapt to the theme (only a tonal shift)

### Files changed

Byte-identical in both trees:
- `config/vexyon/services/Theme.qml`: two optional tokens, `accentFg` and `accent2Fg`
- `config/vexyon/modules/WidgetView.qml`: bar icon colour sourcing (26 one-line swaps plus one comment)
- `share/vexyon/themes/{catppuccin-frappe,catppuccin-latte,crimson-voltage,rose-pine-dawn,solarized-light}.json`: new optional keys (plus Dawn `onAccent`)
- `share/vexyon/store/catalog.json`: the same keys for `dracula`, `solarized-dark` and `nord-light`

NixOS only:
- `config/vexyon/bin/vexyon-seed`: refreshes bundled themes and the catalog once per package build (see below). Arch has no seed: `install.sh` already overwrites `share/vexyon`.

No new mechanism, dependency, process or runtime cost: two `pc()` lookups and static JSON.

### How theme tokens reach the bar

Theme JSON `colors` → `Theme.qml` (`pc(key, fallback)`, reactive to the
`FileView` on `~/.local/share/vexyon/themes/<id>.json`) → `Theme.*` color
properties, read by bindings:
- `Bar.qml`: background in `base`.
- `BarWidget.qml`: pill fill in `surface1`/`surface2`, outline in `overlay0`.
- `WidgetView.qml`: every icon, label and workspace pill.

### Diagnosis

- **No hardcoded colours and no broken token flow.** Every bar colour was
  already a `Theme.*` token and switching was live.
- **The problem was which tokens.** Every icon rested on `Theme.text`. The
  monitor glyphs used the fixed hue slots `peach`, `mauve`, `teal`, `green`,
  `yellow` and `blue`, which are the same orange/purple/teal in every theme.
  The theme's accent appeared in only two tiny places: the focused workspace
  and the date. So every dark theme rendered as "near-black bar + grey pills +
  near-white icons", shifted only in tint.
- **Known-good examples:** the OSD (icon and level bar in `accent`), panels
  (`AnchoredPanel`'s accent blobs) and the launcher and lock screen (14–15
  accent uses each) already carried each theme's identity through its accent.

### Palette structure

The 23 existing roles were enough: every theme has distinct `accent`/`accent2`
hues. One real limitation surfaced:
- **`accent` serves two jobs:** a fill (focused-workspace pill with
  `onAccent`, panel blobs, OSD bar) and a foreground (icons and text on a
  surface). Light themes' canonical accents are tuned as fills and fail as
  foreground on the bar's pills: Rosé Pine Dawn 2.18:1, Solarized Light 2.59,
  Latte `accent2` 2.02.
- **Extended the existing structure** the way `onAccent` already works:
  optional `accentFg`/`accent2Fg` keys, falling back to `accent`/`accent2`.
  Fills keep the canonical colour.
- **Variant rule:** same hue, perceptual lightness (OKLCH) moved away from the
  pill until `accentFg` reaches ≥4.5:1 (it is also the date text) and
  `accent2Fg` ≥3:1 (icons only, WCAG non-text).
- **Only the themes that fail define them:**

| theme | key | canonical → Fg | contrast on pill |
|---|---|---|---|
| Catppuccin Frappé | accentFg | `#ca9ee6` → `#dcaff8` | 3.79 → 4.58 |
| Catppuccin Latte | accentFg / accent2Fg | `#8839ef` → `#761ad8` / `#7287fd` → `#5566d9` | 3.43 → 4.57 / 2.02 → 3.10 |
| Crimson Voltage | accentFg | `#e11d48` → `#f53858` | 3.65 → 4.56 |
| Rosé Pine Dawn | accentFg / accent2Fg | `#d7827e` → `#9a4b49` / `#907aa9` → `#8b76a4` | 2.18 → 4.63 / 2.90 → 3.08 |
| Solarized Light | accentFg / accent2Fg | `#268bd2` → `#03629c` / `#2aa198` → `#028880` | 2.59 → 4.58 / 2.23 → 3.06 |
| store: Dracula | accentFg | `#bd93f9` → `#c096fc` | 4.46 → 4.61 |
| store: Solarized Dark | accentFg | `#268bd2` → `#46a6ef` | 3.30 → 4.60 |
| store: Nord Light | accentFg / accent2Fg | `#5e81ac` → `#456690` / `#81a1c1` → `#6483a1` | 3.12 → 4.57 / 2.09 → 3.07 |

Rosé Pine Dawn `onAccent` also changed, `#464261` → `#312d4b` (same hue). The
focused-workspace number on the rose fill goes from 3.34 to 4.59.

### What changed in the bar (`WidgetView.qml`)

Rule, also commented in the file:
- **Resting icon:** `accentFg`.
- **Open / active / unread / connected:** `accent2Fg`, previously `accent`.
- **Off / muted:** `overlay2` (unchanged).
- **Real status:** `red`/`green`/`yellow` (unchanged).
- **Text:** `text`/`subtext*` (unchanged).
- **Fills:** unchanged (focused-workspace `accent` + `onAccent`, pills
  `surface1/2`).

Widgets that were neutral-only or on fixed hue slots and now follow the theme:
- **Base components** `Glyph`/`Pill` (default icon colour), which covers
  clipboard, notes, colour picker, keyboard layout and any future widget.
- **Explicit colours replaced:** launcher logo, volume, mic, network,
  bluetooth, notifications, control centre, power, idle inhibitor, battery
  (normal), weather (`blue`), media prev/play/next, CPU (`peach`), memory
  (`mauve`), disk (`teal`), CPU/GPU temperature normal (`yellow`/`green`),
  net speed arrows (`green`/`peach`), tray tint primary/secondary, and the
  clock's date.

### NixOS adaptation: `vexyon-seed`

- **Why:** the seed is copy-if-absent, so on an already-seeded `$HOME` the
  updated theme JSONs (and any future palette fix) never arrived. Icons would
  have followed the accent through the fallback, but the light themes would
  have kept their unreadable 2.2–2.6:1 foreground.
- **What it does now:** it refreshes `seed/themes/*.json` and
  `seed/store/catalog.json` **once per package build**, keyed on the
  `VEXYON_SHARE` store path recorded in `~/.local/share/vexyon/.seeded-from`.
  That matches Arch, where `install.sh` overwrites them on each install.
- **What it leaves alone:** store-installed themes and `shell.json`. Edits made
  between rebuilds are not reverted on every login.

### Verified (in a cloud container, NOT on the user's machine)

- **Real shell on headless sway** (quickshell 0.3.0, Qt GL on llvmpipe, Nerd
  Font installed, fake Hyprland IPC), with a 1920×1080 landscape and a
  **1080×1920 portrait** output.
- **All 12 bundled themes**, switched live through `shell.json`
  `theme.active` (the same path `Theme.apply()` uses) and captured with grim,
  **before and after**:
  - Before: every dark theme showed the same neutral bar.
  - After: each bar is clearly its theme's colour (amoled cyan, Catppuccin
    mauve, Crimson red, Gruvbox yellow and orange, Kanagawa and Tokyo blue,
    Rosé Pine rose, Solarized blue and teal), including on the portrait output.
  - Light themes (Latte, Dawn, Solarized) are readable.
  - Done with a crowded 17-widget test bar and with the default layout.
  - No QML errors.
- **Contrast**, all 12 bundled + 7 store themes, measured on the actually
  composited pill colour: every bar icon ≥3:1, the date ≥4.5:1, clock text
  ≥5:1. **0 failures.**
- **Greeter:** the bridge's `sync_greeter_theme` and the manual
  `vexyon-greeter-sync-theme` both still produce a snapshot byte-identical to
  the theme file. `load_theme` still parses. The real greeter QML renders
  correctly from the synced Rosé Pine Dawn snapshot. The greeter needed no
  change: it reads keys by name and ignores the new ones.
- **`vexyon-seed`:** simulated rebuild from a read-only fake store. Bundled
  themes and the catalog were refreshed and writable, the store-installed theme
  and `shell.json` were untouched, and a second login on the same build kept a
  user edit.
- **Static checks:** `qmllint` with a `qs.*` module tree shows no new warnings
  in `Theme.qml`, `WidgetView.qml`, `BarWidget.qml` or `Bar.qml`.
  `bash -n vexyon-seed` passes.
- **Arch:** cannot run here (no pacman). Its files are `cmp`-identical to the
  NixOS tree, and `install.sh` already overwrites `share/vexyon` (themes and
  catalog) on install.
- **Not verified:**
  - Your monitors.
  - Real clicks.
  - The highlight colour in a live open/unread state. It is the same
    expression shape as before, swapped token only.

### Known, pre-existing, left as is

- **Solarized Light / Nord Light focused-workspace number:** 3.68 / 4.03:1.
  Their `onAccent` is already white on a mid-tone accent fill, so only pure
  black or a darker fill (which changes the theme) would reach 4.5.
- **Status `green`/`yellow` on light themes:** Latte 2.12/1.66, Dawn
  2.62/1.72, Solarized 2.26. Canonical palette values, shown only in transient
  states (charging, VPN up, VM running/paused, updates, caps lock).
- **Portrait layout:** with a very crowded bar, the centre section overlaps the
  right section on the 1080 px portrait screen. Layout, not colour, and present
  before. The default layout is fine.
- **Log warning:** `Theme.qml` logs `Binding loop detected for property
  "activeId"` once per theme switch, both before and after this change.
- **Similar themes:** the three dark Catppuccin flavours share their accent
  family, and Tokyo Night / Kanagawa share a blue accent. They differ in
  background, text and secondary accent. That is the palettes themselves.
- **Store themes installed before this change** keep their old JSON
  (`installTheme` writes them once). Reinstall Dracula, Solarized Dark or Nord
  Light from the store to get the new keys.

### To check by hand on the tower

Switch through the themes in Control Centre and look at the bar on DP-1, DP-3
and the portrait DP-2. Open Quick Settings, or get an unread notification, to
see the `accent2Fg` highlight. Log in to the greeter once after switching to a
light theme.

---

## Session: three pre-2.0 bugs (Wi-Fi module, bar over fullscreen + scratchpad, pixelated launcher icons)

### Files changed (byte-identical in both trees)

- `config/vexyon/services/Network.qml`: Bug 1
- `config/vexyon/modules/Bar.qml`: Bug 2
- `config/vexyon/modules/Launcher.qml`: Bug 3 (3 × `IconImage` → `AppIcon`, dropped the now-unused `Quickshell.Widgets` import)
- `config/vexyon/components/AppIcon.qml`: **new**, Bug 3

No new daemons, processes, polls or dependencies. Nothing in the fixes is
distro-specific, so the Arch files are straight copies of the NixOS ones.

---

### Bug 1: Wi-Fi section dead, only Bluetooth shows

**Symptom:** the network panel only offers the Bluetooth tab. The Wi-Fi tab is
shown only when `Network.wifiDevice !== ""` and Ethernet only when
`Network.ethDevice !== ""`. Bluetooth comes from D-Bus (`Quickshell.Bluetooth`),
so it is unaffected by anything nmcli-related.

**Root cause: the earlier "merge two nmcli processes" optimisation.** Before
it, the device table (`nmcli -t -f DEVICE,TYPE,STATE device status`, which
feeds `parseDevs` → `wifiDevice`/`ethDevice`) ran in its own `devQuery`
process and returned in milliseconds. The merge folded it into `query`,
whose second command was `nmcli … device wifi` with no flags. That defaults
to `--rescan auto`: if the last scan is older than 30 s it requests a new one
and **waits up to 15 s** (`src/nmcli/devices.c`: `rescan_cutoff_msec = now - 30 s`,
`timeout_msec = 15000`). `StdioCollector` only fires when the whole command
ends, so the device table is now held hostage by a Wi-Fi scan. Until it
finishes, `wifiDevice` and `ethDevice` stay `""` and the panel shows only
Bluetooth. The old "byte-identical output" check was right about the output
but never looked at latency. The 5 s poll also ended up forcing a real Wi-Fi
scan roughly every 30 s.

**When it regressed:** the merged `query` is already in the NixOS repo's first
upload (`690193e`, 2026-08-12). In the Arch repo, the 2026-08-12 upload
(`a279dd7`) still had the separate `devQuery`, and the merge arrives in the
2026-08-19 upload (`9b485c0`). `Network.qml` has not changed in either tree
since then.

**Lua migration check:** the network module makes no `Hyprland.dispatch` or
`hyprctl` calls. All nmcli calls are argv arrays or `bash -c` strings, so the
`')' expected near` failure class can't apply.

**Fix:** the poll's Wi-Fi query is now
`nmcli -t -f IN-USE,SIGNAL,SSID device wifi list --rescan no`, and the
one-shot FREQ lookup in `infoQuery` uses the same flags. The active AP's
signal and SSID come from NM's cache. Real scans are still requested where
the user asks for them: the panel's `refreshWifi()` / refresh button keeps
`--rescan auto`. The `list` subcommand is required: real nmcli 1.56 rejects
`device wifi --rescan no` with rc 2.

**Verified (in a cloud container, NOT on the user's machine):**
- Real NetworkManager 1.56.0 (nixos-26.05) running sandboxed in its own
  network namespace with a veth: the new query is **byte-identical** to the
  old one (`cmp`). `device wifi list --rescan no` is accepted (rc 0). Terse
  output is not localized (`nmcli` source: PARSABLE skips gettext, and `radio
  wifi` forces terse), so a Spanish locale is not a factor.
- The edited `Network.qml` was loaded in quickshell 0.3.0 against that real NM
  and parses it correctly (`kind`, `name` with an escaped `\:`).
- **Timing (simulated):** there was no Wi-Fi radio available, so an `nmcli`
  shim reproduced the documented rescan wait (8 s) plus a fake `wlan0`. The
  original `Network.qml` kept `wifiDevice` empty for about 9–10 s. The edited
  one had `wifiDevice=wlan0` within the first second.
- **Not verified:** listing, connecting and disconnecting against a real Wi-Fi
  card, and clicking through the panel. If the Wi-Fi tab is *still* missing on
  the machine after this change, the remaining cause is environmental: run
  `nmcli -t -f DEVICE,TYPE,STATE device status` in the session. Empty output or
  "NetworkManager is not running" produces exactly the same Bluetooth-only
  panel, because both device fields stay empty.

---

### Bug 2: bar visible but dead over a fullscreen window with the scratchpad (Super+S) open

**Root cause (Hyprland, read from current `main` source):**
- `CInputManager::mouseMoveUnified` (InputManager.cpp): when the monitor has an
  exclusive-fullscreen window (`HAS_EXCLUSIVE_FULLSCREEN` is also true via
  `hasFullscreen(PMONITOR)` while a special workspace is open), a **Top-layer**
  surface under the cursor is discarded unless it carries
  `LAYER_FLAG_ABOVE_FULLSCREEN`. The pointer then goes to the fullscreen window
  or the scratchpad window instead.
- `CMonitor::setSpecialWorkspace` (output/Monitor.cpp) **clears**
  `LAYER_FLAG_ABOVE_FULLSCREEN` on every layer of the monitor when a special
  workspace opens.
- The renderer still draws Top layers over the open special workspace. Result:
  the bar is visible but never receives the pointer.
- Overlay layers are always hit-tested first ("overlays are above
  fullscreen"), and committing `set_layer(OVERLAY)` sets the flag
  (`CLayerSurface::onCommit`).
- This is the same family as the earlier `exclusiveZone: -1` overlay findings:
  every other shell surface (all `AnchoredPanel`s, launcher, power menu, …) is
  already Overlay. The bar was the only Top-layer surface.

**Fix (`Bar.qml`):** the existing raw-event `Connections` now also tracks
`activespecial>>NAME,MON` (open) and `>>,MON` (close) for the bar's own
monitor. The bar uses
`WlrLayershell.layer: overFullscreen ? Overlay : Top`, where
`overFullscreen = specialOpen && Hyprland.monitorFor(screen).activeWorkspace.hasFullscreen`.
It is event-driven only, with no polling. Quickshell forwards a runtime
`layer` change as a live `set_layer` request. Closing the scratchpad returns
the bar to Top, and Hyprland hides it under the fullscreen window exactly as
before. Without fullscreen, nothing changes.

**Verified:**
- The real full shell (this tree) ran on headless sway with quickshell 0.3.0,
  with a fake Hyprland IPC socket emitting the real event formats taken from
  the Hyprland source. `WAYLAND_DEBUG` showed:
  - `fullscreen>>1` alone: no layer change.
  - Scratchpad opened over fullscreen: `zwlr_layer_surface_v1.set_layer(3)` (Overlay).
  - Scratchpad closed: `set_layer(2)` (Top).
  - Scratchpad opened without fullscreen: no layer change.
- **Not verified:** clicking the bar under real Hyprland with a fullscreen
  window. Hyprland cannot run in that container (no GPU or DRM), and
  `hyprctl layers`/`clients` were not available. The input-routing conclusion
  comes from reading Hyprland's source, not from live inspection.

---

### Bug 3: some launcher icons pixelated at 1.25 / 1.5 scale

**What it was NOT:** the launcher's `IconImage` already requests DPR-correct
sizes. Measured: Qt asks the icon provider for 58 device px at 1.25 and 69 at
1.5 for the 46 px grid icons. SVG icons (nearly all of Papirus-Dark) are
always crisp.

**Root cause: a Qt 6.11 `QIconLoaderEngine::entryForSize` bug, triggered by
fractional scaling:**
- When any output is fractional, Qt's app-wide DPR becomes the integer
  `wl_output` scale (2). `scaledPixmap` uses `qCeil(dpr)` as the directory
  scale, so no normal (Scale=1) directory can match exactly any more, and Qt
  falls back to its distance heuristic.
- hicolor's `256x256/apps` is `Type=Scalable MinSize=64`, so it scores a
  perfect distance of 0.
- The loop then lets a later, *too-small* Threshold dir (16/22/24 px, which
  get a positive distance) overwrite that perfect score.
- Net effect: an app shipping hicolor PNGs such as {16, 32, 48, 256} with no
  128 px gets its **16 px** PNG stretched to 58–69 px. At 1.0 the exact-match
  path picks 48 px, which is why it only shows up under fractional scaling.
- It also hits monitors at 1.0 whenever *another* output is fractional,
  because the DPR is app-wide.
- A Python port of the Qt loop reproduces every measured pick exactly.

**Fix:** new `components/AppIcon.qml`, used for the three launcher icons. It
is a plain `IconImage` that, **only** when the delivered pixmap is smaller
than its on-screen size, re-requests once at 130 logical px. That is ≥260 px
for Qt, outside the 64..256 range that triggers the bug. The retry also turns
on mipmapping so the larger asset is downscaled without aliasing. Icons that
were fine keep exactly their previous request size and texture, so there is
no blanket upscaling. Extra memory is limited to the affected icons, each
capped by its largest real asset (about 256 KB for a 256 px PNG). The latch
resets when the icon source changes.

**Verified (real Qt Wayland fractional scaling on headless sway with Qt's
OpenGL renderer on llvmpipe, physical pixels captured with grim):**
- Before → after sharpness (edge energy) for a {16,32,48,64,256} icon:
  8.8 → 50.2 at 1.25 and 6.3 → 49.7 at 1.5. Visually, a blurred blob becomes
  a legible icon.
- The SVG, Papirus (firefox, steam), multi-size-with-128 and absolute-path
  icons render byte-for-byte the same score before and after (no regression).
- `qmllint` (Qt 6.11.2, with a `qs.*` module tree): no new warnings in any
  changed file, `AppIcon.qml` is clean, and a negative control confirmed the
  lint really type-checks it.
- **Not verified:** your DP-1/DP-2/DP-3 at 1.25/1.5. No scale settings were
  changed on your machine, so nothing needs restoring.

**Known limits:**
- Icons whose *largest* asset is 48–64 px (e.g. Wine `{16,32,48}`) stay soft
  at 1.25/1.5. There are no more pixels to use, and no request size can fix
  that.
- After switching back to 1.0 within the same session, an icon that needed the
  retry keeps the larger mipmapped request until its source changes. It
  renders fine, just marginally softer.
- Other `IconImage` users (bar taskbar/dock in `WidgetView.qml`, `TrayMenu.qml`)
  go through the same Qt code path and could hit the same bug. They were left
  alone to stay in scope; switching them to `AppIcon` would be a one-word
  change each.

---

### Verification honesty summary

| | Live on the user's machine | Done in this session |
|---|---|---|
| Bug 1 | ✗ | Real NM 1.56 + quickshell 0.3.0 parse test; simulated rescan timing |
| Bug 2 | ✗ | Real shell on sway + fake Hyprland IPC (`set_layer` traced); Hyprland source |
| Bug 3 | ✗ | Real Qt Wayland fractional scaling, GL path, pixel captures before/after |
| Arch tree | ✗ (no pacman) | Files `cmp`-identical to the NixOS tree; `qmllint` clean |

None of the three fixes was clicked or hovered on real hardware. Before
tagging 2.0, these four checks need to be done by hand on the tower:

1. Open the network panel and connect and disconnect a Wi-Fi network.
2. Fullscreen a window, press Super+S, and click and hover the bar.
3. Set one output to 1.25 and then 1.5, open the launcher, and look for any
   icon that was blocky before. Restore the original scale afterwards.
4. Confirm a single quickshell instance with the `/proc/*/exe` recipe
   (`pgrep -x quickshell` doesn't match under the Nix wrapper).
