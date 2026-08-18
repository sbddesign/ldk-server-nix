{
  description = "Nix package and NixOS module for LDK Server, a Lightning node daemon built on LDK Node";

  inputs.nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";

  outputs = { self, nixpkgs }:
    let
      systems = [ "x86_64-linux" "aarch64-linux" "x86_64-darwin" "aarch64-darwin" ];
      forAllSystems = nixpkgs.lib.genAttrs systems;
      pkgsFor = system: import nixpkgs { inherit system; };
    in
    {
      overlays.default = final: prev: {
        ldk-server = final.callPackage ./pkgs/ldk-server.nix { };
      };

      packages = forAllSystems (system:
        let pkgs = pkgsFor system; in
        rec {
          ldk-server = pkgs.callPackage ./pkgs/ldk-server.nix { };
          ldk-server-lsps2 = ldk-server.override { withLsps2 = true; };
          default = ldk-server;
        });

      # Standalone NixOS module. It only depends on vanilla NixOS options
      # (systemd, users, services.tor). Importing this module makes the
      # package from this flake the default for `services.ldk-server.package`.
      nixosModules.ldk-server = { pkgs, lib, ... }: {
        imports = [ ./modules/ldk-server.nix ];
        services.ldk-server.package =
          lib.mkDefault self.packages.${pkgs.stdenv.hostPlatform.system}.ldk-server;
      };
      nixosModules.default = self.nixosModules.ldk-server;

      formatter = forAllSystems (system: (pkgsFor system).nixfmt-rfc-style);
    };
}
