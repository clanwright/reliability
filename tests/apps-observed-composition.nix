{ pkgs, apps }:

let
  lib = pkgs.lib;
  names = [
    "vaultwarden-a"
    "vaultwarden-b"
    "livesync-a"
    "livesync-b"
  ];
  fixture =
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
      machines.fixture = { pkgs, ... }: {
        imports = [ (import ../examples/apps-observed-restic.nix ({ inherit apps; } // settings)) ];
        nixpkgs.hostPlatform = "x86_64-linux";
        boot.isContainer = true;
        system.stateVersion = "25.11";
        sops.age.keyFile = "/var/lib/fixture-sops/age-key.txt";
        services.restic.backups.vaultwarden-a = {
          package = pkgs.restic.overrideAttrs (_: {
            pname = "fixture-restic";
          });
          environmentFile = "/run/backup-secrets/fixture-backend-env";
          rcloneConfigFile = "/run/backup-secrets/fixture-rclone-config";
          extraOptions = [
            "s3.region=fixture-region"
            "s3.connections=2"
          ];
        };
      };
    }).config.nixosConfigurations.fixture.config;
  cfg = fixture { };
  stricter = fixture {
    admissionMaxAgeSeconds = 43200;
    arrivalMaxAgeSeconds = 64800;
    metricsDirectory = "/var/lib/fixture-metrics";
  };
  backup = name: cfg.services.restic.backups.${name};
  service = name: cfg.systemd.services."restic-backups-${name}";
  invocationTag = "--tag=reliability-invocation:\${INVOCATION_ID}";
  invalid =
    settings:
    lib.any (item: !item.assertion && lib.hasInfix "Apps capture" item.message)
      (fixture settings).assertions;
  report = {
    acceptance = "evaluated public native composition; no service, capture, upload or semantic restore executed";
    appsRevision = apps.rev;
    admissionMaxAgeSeconds = 64800;
    arrivalMaxAgeSeconds = 86400;
    stricterBudgets = {
      admissionMaxAgeSeconds = 43200;
      arrivalMaxAgeSeconds = 64800;
    };
    jobs = lib.genAttrs names (name: {
      inherit ((backup name)) extraBackupArgs;
      inherit ((service name)) preStart postStart postStop;
      inherit ((service name).serviceConfig) ExecStart SuccessExitStatus;
      restic = "${(backup name).package}/bin/restic";
      cache = (service name).environment.RESTIC_CACHE_DIR;
      unitText = cfg.systemd.units."restic-backups-${name}.service".text;
    });
    defaultsOff = true;
  };
in
assert lib.all (item: item.assertion) cfg.assertions;
assert lib.all (item: item.assertion) stricter.assertions;
assert invalid { admissionMaxAgeSeconds = 0; };
assert invalid {
  admissionMaxAgeSeconds = 86401;
  arrivalMaxAgeSeconds = 90000;
};
assert invalid { arrivalMaxAgeSeconds = 0; };
assert invalid {
  admissionMaxAgeSeconds = 64800;
  arrivalMaxAgeSeconds = 64799;
};
assert invalid { admissionMaxAgeSeconds = "64800"; };
assert invalid { metricsDirectory = "/var/lib/fixture metrics"; };
assert invalid { metricsDirectory = "/var/lib/%i"; };
assert lib.all (
  name:
  let
    app = if lib.hasPrefix "vaultwarden-" name then "vaultwarden" else "livesync";
    destination = lib.last (lib.splitString "-" name);
    format = if app == "vaultwarden" then "vaultwarden-pg18-files-v1" else "livesync-couchdb3-v1";
    input = "/var/cache/restic-backups-${name}/apps-input";
    unit = service name;
    prepareParts = lib.splitString "backupPrepareCommand" unit.preStart;
    cmd = builtins.head unit.serviceConfig.ExecStart;
    unitText = cfg.systemd.units."restic-backups-${name}.service".text;
    renderedExecStart = lib.filter (line: lib.hasPrefix "ExecStart=" line) (
      lib.splitString "\n" unitText
    );
  in
  (backup name).extraBackupArgs == [ invocationTag ]
  && lib.hasInfix invocationTag cmd
  && builtins.length renderedExecStart == 1
  && lib.hasInfix invocationTag (builtins.head renderedExecStart)
  && !(lib.hasInfix "--tag=reliability-invocation:$$" (builtins.head renderedExecStart))
  && lib.hasPrefix "${lib.getExe (backup name).package}" cmd
  && lib.hasInfix " backup " cmd
  && builtins.length unit.serviceConfig.ExecStart == 1
  && unit.serviceConfig.SuccessExitStatus == [ ]
  && builtins.length prepareParts == 2
  && lib.hasInfix (lib.escapeShellArgs [
    "start"
    app
    destination
    "/var/lib/prometheus-node-exporter-text-files"
  ]) (builtins.head prepareParts)
  && lib.hasInfix (lib.escapeShellArgs [
    "admit"
    app
    format
    "64800"
    "${input}/export.json"
  ]) (lib.last prepareParts)
  && lib.hasInfix "prepare-reader --max-age 86400" (backup name).backupPrepareCommand
  && lib.hasInfix "backupCleanupCommand" unit.postStop
  && lib.hasInfix input (backup name).backupCleanupCommand
  && lib.hasInfix (builtins.unsafeDiscardStringContext "export RESTIC_OBSERVER_RESTIC=${lib.escapeShellArg "${(backup name).package}/bin/restic"}") unit.postStart
  && lib.hasInfix (lib.escapeShellArgs [
    "observe"
    app
    destination
    format
    "86400"
    input
    "/var/lib/prometheus-node-exporter-text-files"
  ]) unit.postStart
  && lib.hasInfix ''"$INVOCATION_ID"'' unit.postStart
  && builtins.hasContext unit.postStart
  && (backup name).timerConfig == null
  && !builtins.hasAttr "restic-backups-${name}" cfg.systemd.timers
  && !(backup name).initialize
  && (backup name).pruneOpts == [ ]
  && !(backup name).createWrapper
) names;
assert
  builtins.length (lib.unique (map (name: (service name).environment.RESTIC_CACHE_DIR) names)) == 4;
assert
  (service "vaultwarden-a").serviceConfig.EnvironmentFile
  == "/run/backup-secrets/fixture-backend-env";
assert
  (service "vaultwarden-a").environment.RCLONE_CONFIG == "/run/backup-secrets/fixture-rclone-config";
assert lib.hasInfix (lib.escapeShellArgs [
  "--option"
  "s3.region=fixture-region"
  "--option"
  "s3.connections=2"
]) (service "vaultwarden-a").postStart;
assert lib.hasInfix "43200" stricter.systemd.services.restic-backups-vaultwarden-a.preStart;
assert lib.hasInfix "64800" stricter.systemd.services.restic-backups-vaultwarden-a.postStart;
assert builtins.elem "d /var/lib/prometheus-node-exporter-text-files 0755 root root - -"
  cfg.systemd.tmpfiles.rules;
assert builtins.elem "d /var/lib/fixture-metrics 0755 root root - -"
  stricter.systemd.tmpfiles.rules;
assert !cfg.services.prometheus.exporters.node.enable;
pkgs.runCommand "reliability-apps-observed-composition"
  {
    # Evaluate commands and references without retaining application closures.
    report = builtins.unsafeDiscardStringContext (builtins.toJSON report);
    passAsFile = [ "report" ];
  }
  ''
    mkdir -p "$out"
    cp "$reportPath" "$out/report.json"
  ''
