{
  description = "Vexyon — desktop shell for Hyprland (Quickshell)";

  inputs.nixpkgs.url = "github:NixOS/nixpkgs/nixos-26.05";

  outputs =
    { self, nixpkgs }:
    let
      systems = [ "x86_64-linux" "aarch64-linux" ];
      forAllSystems = f: nixpkgs.lib.genAttrs systems (s: f nixpkgs.legacyPackages.${s});
    in
    {
      packages = forAllSystems (pkgs: rec {
        vexyon-shell = pkgs.callPackage ./nix/package.nix { };
        default = vexyon-shell;
      });

      nixosModules = {
        vexyon = import ./nix/module.nix self;
        default = self.nixosModules.vexyon;
      };

      # `nix flake check` construye esto; el módulo se prueba de verdad en la
      # VM (nixos-rebuild), no aquí.
      checks = forAllSystems (pkgs: {
        inherit (self.packages.${pkgs.stdenv.hostPlatform.system}) vexyon-shell;
      });

      # Prueba en VM de Ajustes → Módulos (arranques reales, ver el fichero).
      # Fuera de `checks` a propósito: necesita KVM, o mucha paciencia sin él.
      tests = forAllSystems (pkgs: {
        modules-gating = import ./nix/tests/modules-gating.nix { inherit self pkgs; };
      });

      devShells = forAllSystems (pkgs: {
        default = pkgs.mkShell {
          packages = with pkgs; [ quickshell hyprland jq python3 ];
        };
      });

      formatter = forAllSystems (pkgs: pkgs.nixfmt);
    };
}
