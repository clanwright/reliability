{
  description = "Native Restic recovery checks for NixOS";

  inputs.nixpkgs.url = "github:NixOS/nixpkgs/8d5d270900d3fc75655ea2d9d248b234f6631439";
  inputs.apps.url = "github:clanwright/apps/aa63cbe9f73b1af6360499cedef326e813da700b";

  outputs =
    {
      self,
      nixpkgs,
      apps,
    }:
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
          capture-observation = import ./packages/capture-observation.nix {
            inherit pkgs;
            restic = pkgs.restic;
          };
          local-ci = pkgs.writeShellApplication {
            name = "local-ci";
            derivationArgs = {
              preferLocalBuild = true;
              allowSubstitutes = false;
            };
            text = ''
              nix flake check --no-write-lock-file path:${self}
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
        pkgs: system: {
          format = pkgs.runCommand "reliability-format" { nativeBuildInputs = [ pkgs.nixfmt ]; } ''
            find ${self} -type f -name '*.nix' -exec nixfmt --check {} +
            touch "$out"
          '';
          package = self.packages.${system}.default;
          apps-composition = import ./tests/apps-composition.nix {
            inherit pkgs apps;
          };
          capture-observation = import ./tests/capture-observation.nix { inherit pkgs; };
          capture-alerts = import ./tests/capture-alerts.nix { inherit pkgs; };
          module-eval = import ./tests/module-eval.nix {
            inherit pkgs;
            nixosSystem = nixpkgs.lib.nixosSystem;
          };
        }
      );
    };
}
