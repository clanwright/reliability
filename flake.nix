{
  description = "Native Restic recovery checks for NixOS";

  inputs.nixpkgs.url = "github:NixOS/nixpkgs/8d5d270900d3fc75655ea2d9d248b234f6631439";

  outputs =
    { self, nixpkgs }:
    let
      systems = [
        "aarch64-darwin"
        "aarch64-linux"
        "x86_64-linux"
      ];
      forAllSystems =
        f: nixpkgs.lib.genAttrs systems (system: f (import nixpkgs { inherit system; }) system);
    in
    {
      packages = forAllSystems (
        pkgs: system: {
          restic = pkgs.restic;
          default = pkgs.restic;
          local-ci = pkgs.writeShellApplication {
            name = "local-ci";
            runtimeInputs = [ pkgs.nixVersions.nix_2_35 ];
            text = ''
              nix flake check --no-write-lock-file path:${self}
              nix build --no-write-lock-file --no-link path:${self}#default
            '';
          };
        }
      );
      apps = forAllSystems (
        _: system: {
          default = {
            type = "app";
            program = "${self.packages.${system}.default}/bin/restic";
            meta.description = "Run Restic";
          };
          local-ci = {
            type = "app";
            program = "${self.packages.${system}.local-ci}/bin/local-ci";
            meta.description = "Run local Reliability checks";
          };
        }
      );
      checks = forAllSystems (
        pkgs: system:
        {
          package = self.packages.${system}.default;
          runtime-integration = import ./tests/restic-integration.nix { inherit pkgs; };
        }
        // nixpkgs.lib.optionalAttrs pkgs.stdenv.hostPlatform.isLinux {
          module-eval = import ./tests/module-eval.nix {
            inherit pkgs;
            nixosSystem = nixpkgs.lib.nixosSystem;
          };
        }
      );
    };
}
