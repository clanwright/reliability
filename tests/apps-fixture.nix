{ apps }:
settings:
(apps.inputs.clan-core.lib.clan {
  self = {
    inputs = apps.inputs // {
      inherit apps;
      nixpkgs = apps.inputs.apps-nixpkgs;
    };
    outPath = ../.;
  };
  directory = ../.;
  imports = [ apps.clanModules.default ];
  clanwright.apps.machines.fixture = {
    installation = {
      publicIPv4 = "192.0.2.10";
      certificateEmail = "fixture@example.invalid";
      privateIngress = {
        destinationIPv4 = "100.64.0.10";
        trustedInterfaces = [ "tailscale0" ];
      };
    };
    obsidian = {
      domain = "notes.example.invalid";
      export.enable = true;
    };
    vaultwarden = {
      domain = "vault.example.invalid";
      export.enable = true;
    };
  };
  machines.fixture = { pkgs, lib, ... }: {
    imports = [ (import ../examples/apps-restic.nix settings) ];
    security.acme.certs."notes.example.invalid".webroot = "/var/lib/acme/acme-challenge";
    security.acme.certs."vault.example.invalid".webroot = "/var/lib/acme/acme-challenge";
    nixpkgs.hostPlatform = "x86_64-linux";
    boot.isContainer = true;
    system.stateVersion = "25.11";
    sops.age.keyFile = "/var/lib/fixture-sops/age-key.txt";
    services.restic.backups.vaultwarden-a = {
      package = lib.mkIf (settings.observe or false) (
        pkgs.restic.overrideAttrs (_: {
          pname = "fixture-restic";
        })
      );
      environmentFile = "/run/backup-secrets/fixture-backend-env";
      rcloneConfigFile = "/run/backup-secrets/fixture-rclone-config";
      rcloneOptions.transfers = "2";
      extraOptions = [
        "s3.region=fixture-region"
        "s3.connections=2"
      ];
    };
  };
}).config.nixosConfigurations.fixture.config
