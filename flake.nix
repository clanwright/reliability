{
  description = "Standalone Clanwright reliability executor";

  inputs.nixpkgs.url = "github:NixOS/nixpkgs/c27cdad491a991b11ed731760aa2ef8db0cb0410";

  outputs =
    { self, nixpkgs }:
    let
      systems = [
        "aarch64-darwin"
        "x86_64-linux"
      ];
      forAllSystems =
        f: nixpkgs.lib.genAttrs systems (system: f (import nixpkgs { inherit system; }) system);
    in
    {
      nixosModules.default = import ./modules/reliability.nix;
      packages = forAllSystems (
        pkgs: system:
        let
          reliability = pkgs.callPackage ./nix/package.nix {
            bubblewrap = if pkgs.stdenv.hostPlatform.isLinux then pkgs.bubblewrap else null;
          };
        in
        {
          inherit reliability;
          default = reliability;
          local-ci = pkgs.writeShellApplication {
            name = "local-ci";
            runtimeInputs = [ pkgs.nix ];
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
            program = "${self.packages.${system}.default}/bin/reliability";
            meta.description = "Run the Reliability backup executor";
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
          runtime-integration =
            pkgs.runCommand "reliability-runtime-integration"
              {
                nativeBuildInputs = [
                  pkgs.python3
                  pkgs.restic
                ];
              }
              ''
                export HOME="$TMPDIR"
                export PYTHONDONTWRITEBYTECODE=1
                python3 -m unittest discover -s ${self}/tests -p test_runtime.py -v
                touch "$out"
              '';
        }
        // nixpkgs.lib.optionalAttrs pkgs.stdenv.hostPlatform.isLinux {
          module-eval = import ./tests/module-eval.nix {
            inherit pkgs self;
            nixosSystem = nixpkgs.lib.nixosSystem;
          };
          validator-isolation =
            let
              validator = pkgs.writeShellScript "reliability-validator-smoke" ''
                set -eu
                test "$(${pkgs.coreutils}/bin/id -u)" -ne 0
                read -r marker < /input/marker
                test "$marker" = expected
                test ! -e /build/host-sentinel
                test ! -e /etc/passwd
                test -z "''${RELIABILITY_SECRET-}"
                if printf changed >> /input/marker 2>/dev/null; then
                  exit 1
                fi
                printf scratch > /tmp/scratch
                test -s /tmp/scratch
                mapfile -t routes < /proc/net/route
                test "''${#routes[@]}" -le 1
              '';
            in
            pkgs.runCommand "reliability-validator-isolation"
              {
                nativeBuildInputs = [ pkgs.bubblewrap ];
              }
              ''
                mkdir -p input
                printf 'expected\n' > input/marker
                printf hidden > host-sentinel
                export RELIABILITY_SECRET=must-not-leak
                bwrap --unshare-all --die-with-parent --new-session \
                  --ro-bind /nix/store /nix/store \
                  --ro-bind "$PWD/input" /input \
                  --tmpfs /tmp --dev /dev --proc /proc --clearenv \
                  ${validator}
                touch "$out"
              '';
        }
      );
    };
}
