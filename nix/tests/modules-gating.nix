# VM test for Settings → Modules: boots a NixOS VM with ONLY
# `services.vexyon = { enable; user; }` and checks, across four boots, that a
# module turned off is gated at the next boot (by every route), that user data
# survives, that a module shared with other software is never gated, and that
# turning it back on brings everything back with nothing reinstalled.
#
#   nix build .#tests.x86_64-linux.modules-gating           (needs KVM)
#   nix build .#tests.x86_64-linux.modules-gating.driver    (no KVM: then run
#     ./result/bin/nixos-test-driver — QEMU falls back to emulation, ~10 min)
{ self, pkgs }:
let
  vexyon = self.packages.${pkgs.stdenv.hostPlatform.system}.vexyon-shell;
  domXml = pkgs.writeText "vexyon-test-vm.xml" ''
    <domain type='qemu'>
      <name>vexyon-test</name>
      <memory unit='MiB'>64</memory>
      <os><type arch='x86_64'>hvm</type></os>
      <devices>
        <disk type='file' device='disk'>
          <source file='/var/lib/libvirt/images/vexyon-test.qcow2'/>
          <target dev='vda' bus='virtio'/>
        </disk>
      </devices>
    </domain>
  '';
in
pkgs.testers.runNixOSTest {
  name = "vexyon-modules-gating";
  nodes.machine = { lib, ... }: {
    imports = [ self.nixosModules.vexyon ];
    # What a user writes — nothing else about libvirt, Bluetooth or polkit.
    services.vexyon = { enable = true; user = "alice"; greeter.enable = false; };
    users.users.alice = { isNormalUser = true; extraGroups = [ "wheel" ]; };
    # TEST-ONLY adjustments (not part of what is being tested):
    #  - fonts are irrelevant here and would only bloat the VM closure;
    #  - load the bluetooth module so BlueZ's own ConditionPathIsDirectory
    #    passes in a VM without an adapter and our gate is what decides;
    #  - a polkit rule stands in for the admin-password dialog, so the real
    #    pkexec → polkit action → root helper path can run unattended.
    fonts.packages = lib.mkForce [ ];
    boot.kernelModules = [ "bluetooth" ];
    security.polkit.extraConfig = ''
      polkit.addRule(function(action, subject) {
        if (action.id == "org.vexyon.modules.set" && subject.user == "alice")
          return polkit.Result.YES;
      });
    '';
    virtualisation.memorySize = 3072;
    virtualisation.diskSize = 4096;
    #  - without KVM (emulation) boots are slow: give device waits time
    virtualisation.cores = 4;
    boot.kernelParams = [ "systemd.default_device_timeout_sec=900" "systemd.default_timeout_start_sec=900" ];
    documentation.enable = false;
  };
  testScript = ''
    helper = "${vexyon}/libexec/vexyon/vexyon-modules"

    def status():
        out = machine.succeed("vexyon-modules status")
        print(out)
        return out

    def line(out, mod):
        return [l for l in out.splitlines() if l.startswith("id=" + mod + " ")][0]

    # ---------------- boot 1: fresh install, everything on ----------------
    machine.wait_for_unit("multi-user.target")
    machine.succeed("systemctl is-active vexyon-modules.service")
    out = status()
    assert "boot=1" in out
    assert "desired=on applied=on gated=0" in line(out, "vm")
    assert "desired=on applied=on gated=0" in line(out, "bluetooth")
    machine.succeed("systemctl is-active libvirtd.socket virtlogd.socket virtlockd.socket")
    machine.wait_until_succeeds("virsh -c qemu:///system version")
    machine.succeed("systemctl start bluetooth.service && systemctl is-active bluetooth.service")
    # user data that must survive everything below
    machine.succeed("mkdir -p /var/lib/libvirt/images && echo vexyon-data > /var/lib/libvirt/images/vexyon-test.qcow2")
    machine.succeed("virsh -c qemu:///system define ${domXml}")
    # alice is in the libvirtd group (out of the box)
    machine.succeed("id -nG alice | grep -qw libvirtd")

    # a late run (like nixos-rebuild switch) applies nothing mid-session
    machine.succeed("systemctl restart vexyon-modules.service")
    jlog = machine.succeed("journalctl -b -u vexyon-modules.service --no-pager")
    print(jlog)
    assert "nothing applied now" in jlog

    # ---------------- turn both off ----------------
    # the real unprivileged path: alice → bin wrapper → pkexec → polkit action → root copy
    machine.succeed("su - alice -c 'vexyon-modules set vm off'")
    # and root directly (what an installer or activation script does)
    machine.succeed(helper + " set bluetooth off")
    machine.succeed("test -f /var/lib/vexyon/modules/vm.disabled -a -f /var/lib/vexyon/modules/bluetooth.disabled")
    machine.succeed("stat -c '%U %a' /var/lib/vexyon/modules | grep -qx 'root 755'")
    machine.succeed("stat -c '%U %a' /var/lib/vexyon/modules/vm.disabled | grep -qx 'root 644'")
    # alice cannot write the state herself, and the helper refuses garbage
    machine.fail("su - alice -c 'touch /var/lib/vexyon/modules/x'")
    machine.fail(helper + " set libvirtd off")
    machine.fail(helper + " set vm maybe")
    # nothing changes in this session: still running, still on
    machine.succeed("systemctl is-active libvirtd.socket bluetooth.service")
    out = status()
    assert "desired=off applied=on" in line(out, "vm")

    # ---------------- boot 2: gated ----------------
    machine.shutdown()
    machine.start()
    machine.wait_for_unit("multi-user.target")
    out = status()
    assert "desired=off applied=off gated=1" in line(out, "vm")
    assert "desired=off applied=off gated=1" in line(out, "bluetooth")
    for u in ["libvirtd.service", "libvirtd.socket", "libvirtd-ro.socket", "libvirtd-admin.socket",
              "virtlogd.socket", "virtlockd.socket", "libvirt-guests.service", "libvirtd-config.service"]:
        machine.fail("systemctl is-active " + u)
        r = machine.succeed("systemctl show -p ConditionResult --value " + u).strip()
        print(u, "ConditionResult=", r)
    machine.fail("test -S /run/libvirt/libvirt-sock")
    machine.fail("pgrep -x libvirtd"); machine.fail("pgrep -x virtlogd"); machine.fail("pgrep -x dnsmasq")
    # no reactivation: a direct start, a socket client, a D-Bus activation
    machine.succeed("systemctl start libvirtd.service || true")
    machine.fail("systemctl is-active libvirtd.service")
    machine.fail("virsh -c qemu:///system version")
    machine.succeed("busctl call org.freedesktop.DBus /org/freedesktop/DBus org.freedesktop.DBus StartServiceByName su org.bluez 0 || true")
    machine.fail("systemctl is-active bluetooth.service")
    machine.fail("pgrep -x bluetoothd")
    # shared services untouched
    machine.succeed("systemctl is-active polkit.service NetworkManager.service")
    # data kept, packages still installed
    machine.succeed("grep -qx vexyon-data /var/lib/libvirt/images/vexyon-test.qcow2")
    machine.succeed("test -f /var/lib/libvirt/qemu/vexyon-test.xml")
    machine.succeed("command -v virsh virt-viewer wf-recorder")

    # ---------------- boot 3: VM off but shared, Bluetooth back on ----------------
    machine.succeed("install -D -m 755 /dev/null /usr/local/bin/virt-manager")
    machine.succeed("su - alice -c 'vexyon-modules set bluetooth on'")
    machine.shutdown()
    machine.start()
    machine.wait_for_unit("multi-user.target")
    out = status()
    assert "desired=off applied=off gated=0 shared=1" in line(out, "vm")
    assert "consumers=virt-manager" in line(out, "vm")
    assert "desired=on applied=on gated=0" in line(out, "bluetooth")
    machine.wait_until_succeeds("virsh -c qemu:///system version")
    machine.succeed("systemctl start bluetooth.service && systemctl is-active bluetooth.service")

    # ---------------- boot 4: everything back on, nothing reinstalled ----------------
    machine.succeed("rm /usr/local/bin/virt-manager")
    machine.succeed("su - alice -c 'vexyon-modules set vm on'")
    machine.shutdown()
    machine.start()
    machine.wait_for_unit("multi-user.target")
    out = status()
    assert "desired=on applied=on gated=0 shared=0" in line(out, "vm")
    machine.wait_until_succeeds("virsh -c qemu:///system version")
    vms = machine.succeed("virsh -c qemu:///system list --all --name")
    assert "vexyon-test" in vms
    machine.succeed("grep -qx vexyon-data /var/lib/libvirt/images/vexyon-test.qcow2")
    print("ALL GATING CHECKS PASSED")
  '';
}
