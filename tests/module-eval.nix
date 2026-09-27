{
  pkgs,
  self,
  nixosSystem,
}:

let
  lib = pkgs.lib;
  evaluated = nixosSystem {
    system = "x86_64-linux";
    modules = [
      self.nixosModules.default
      ./fixtures-recovery.nix
      ({ pkgs, ... }: {
        boot.isContainer = true;
        system.stateVersion = "25.11";
        clanwright.recovery.units.notes = {
          contractVersion = 1;
          formatVersion = "notes-v1";
          stateRefs = [ "notes-state" ];
          captureCommand = "${pkgs.coreutils}/bin/true";
          validateCommand = "${pkgs.coreutils}/bin/true";
        };
        clanwright.reliability = {
          enable = true;
          selectedUnits = [ "notes" ];
          metricsFile = "/var/lib/node_exporter/textfile_collector/reliability.prom";
          destinations = {
            primary = {
              repository = "/tmp/reliability-test-primary";
              passwordFile = "/run/secrets/reliability-primary";
              expectedRepositoryId = "synthetic-primary-id";
            };
            second = {
              repository = "s3:example.invalid/test";
              passwordFile = "/run/secrets/reliability-second";
              environmentFile = "/run/secrets/reliability-second-env";
              expectedRepositoryId = "synthetic-second-id";
            };
          };
          policy = {
            maintenanceEnabled = true;
            maintenanceDeletionCeiling = 2;
          };
        };
      })
    ];
  };
  cfg = evaluated.config;
  disabled = nixosSystem {
    system = "x86_64-linux";
    modules = [
      self.nixosModules.default
      { system.stateVersion = "25.11"; }
    ];
  };
  services = cfg.systemd.services;
  timers = cfg.systemd.timers;
  has = set: id: builtins.hasAttr id set;
  safe = lib.all (item: item.assertion) cfg.assertions;
in
assert safe;
assert has services "clanwright-reliability-capture";
assert has services "clanwright-reliability-status";
assert has timers "clanwright-reliability-status";
assert lib.hasInfix "--metrics-file /var/lib/node_exporter/textfile_collector/reliability.prom"
  services.clanwright-reliability-status.serviceConfig.ExecStart;
assert services.clanwright-reliability-capture.serviceConfig.PrivateNetwork;
assert
  services.clanwright-reliability-capture.serviceConfig.CapabilityBoundingSet == [
    "CAP_DAC_READ_SEARCH"
    "CAP_DAC_OVERRIDE"
    "CAP_CHOWN"
    "CAP_FOWNER"
    "CAP_SETUID"
    "CAP_SETGID"
    "CAP_KILL"
  ];
assert has services "clanwright-reliability-backup-primary";
assert has services "clanwright-reliability-backup-second";
assert has services "clanwright-reliability-check-primary";
assert has services "clanwright-reliability-read-check-primary";
assert has services "clanwright-reliability-restore-check-primary";
assert !(has services "clanwright-reliability-maintenance-primary");
assert !(has timers "clanwright-reliability-maintenance-primary");
assert has timers "clanwright-reliability-capture";
assert has timers "clanwright-reliability-backup-primary";
assert has timers "clanwright-reliability-read-check-second";
assert lib.length services.clanwright-reliability-capture.unitConfig.OnSuccess == 2;
assert !(services.clanwright-reliability-restore-check-primary.serviceConfig.PrivateNetwork);
assert
  services.clanwright-reliability-restore-check-primary.serviceConfig.CapabilityBoundingSet == [
    "CAP_CHOWN"
    "CAP_SETUID"
    "CAP_SETGID"
    "CAP_FOWNER"
    "CAP_DAC_OVERRIDE"
    "CAP_DAC_READ_SEARCH"
  ];
assert !(has disabled.config.systemd.services "clanwright-reliability-capture");
pkgs.runCommand "reliability-module-eval" { } ''
  touch "$out"
''
