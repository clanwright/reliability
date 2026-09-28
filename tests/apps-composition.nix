{ pkgs, apps }:

let
  lib = pkgs.lib;
  names = [
    "vaultwarden-a"
    "vaultwarden-b"
    "livesync-a"
    "livesync-b"
  ];
  checkNames = lib.concatMap (name: [
    "${name}-structure"
    "${name}-full"
  ]) names;
  allNames = names ++ checkNames;
  fixture =
    exports:
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
        }
        // lib.optionalAttrs exports { export.enable = true; };
        vaultwarden = {
          domain = "vault.example.invalid";
        }
        // lib.optionalAttrs exports { export.enable = true; };
      };
      machines.fixture = {
        imports = lib.optional exports (import ../examples/apps-restic.nix { inherit apps; });
        nixpkgs.hostPlatform = "x86_64-linux";
        boot.isContainer = true;
        system.stateVersion = "25.11";
        sops.age.keyFile = "/var/lib/fixture-sops/age-key.txt";
        services.restic.backups = lib.optionalAttrs exports {
          vaultwarden-a = {
            environmentFile = "/run/backup-secrets/fixture-backend-env";
            rcloneConfigFile = "/run/backup-secrets/fixture-rclone-config";
            rcloneOptions.transfers = "2";
            extraOptions = [ "s3.region=fixture-region" ];
          };
        };
      };
    }).config.nixosConfigurations.fixture.config;
  cfg = fixture true;
  disabled = fixture false;
  backups = cfg.services.restic.backups;
  service = name: cfg.systemd.services."restic-backups-${name}";
  command = name: builtins.head (service name).serviceConfig.ExecStart;
  input = name: "/var/cache/restic-backups-${name}/apps-input";
  producer =
    name:
    if lib.hasPrefix "vaultwarden-" name then
      cfg.system.build.appsVaultwardenExport
    else
      cfg.system.build.appsLiveSyncExport;
  exportNames = [
    "apps-export-vaultwarden"
    "apps-export-livesync"
  ];
  has = set: name: builtins.hasAttr name set;
  report = {
    appsRevision = apps.rev;
    appsSource = toString apps;
    machinePlatform = cfg.nixpkgs.hostPlatform.system;
    acceptance = "evaluated public composition; no application capture, upload or semantic restore executed";
    backups = lib.genAttrs names (name: {
      inherit (backups.${name})
        paths
        repositoryFile
        passwordFile
        environmentFile
        rcloneConfigFile
        rcloneOptions
        extraOptions
        timerConfig
        createWrapper
        ;
      producerCommand = "${producer name}/bin/prepare-reader";
      readerMaxAgeSeconds = 86400;
      cache = (service name).environment.RESTIC_CACHE_DIR;
      inherit ((service name).serviceConfig)
        TimeoutStartSec
        TimeoutStopSec
        KillMode
        CacheDirectory
        CacheDirectoryMode
        User
        ;
    });
    checks = lib.genAttrs checkNames (name: {
      inherit (backups.${name})
        repositoryFile
        passwordFile
        environmentFile
        rcloneConfigFile
        rcloneOptions
        extraOptions
        checkOpts
        paths
        timerConfig
        createWrapper
        ;
      command = command name;
    });
    exports = lib.genAttrs exportNames (name: {
      inherit (cfg.systemd.services.${name}.serviceConfig)
        User
        StateDirectory
        StateDirectoryMode
        RuntimeDirectory
        RuntimeDirectoryMode
        ;
    });
    defaultsOff = true;
  };
in
assert apps.rev == "af0d564cc388aa21e71e0efa4a622d3d11396ea5";
assert lib.all (item: item.assertion) cfg.assertions;
assert lib.all (item: item.assertion) disabled.assertions;
assert builtins.attrNames backups == lib.sort builtins.lessThan allNames;
assert lib.all (name: has cfg.systemd.services "restic-backups-${name}") allNames;
assert lib.all (
  name:
  (service name).serviceConfig.CacheDirectory == "restic-backups-${name}"
  && (service name).serviceConfig.CacheDirectoryMode == "0700"
  && (service name).serviceConfig.User == backups.${name}.user
  && (service name).environment.RESTIC_REPOSITORY_FILE == backups.${name}.repositoryFile
  && (service name).environment.RESTIC_PASSWORD_FILE == backups.${name}.passwordFile
) allNames;
assert lib.all (name: !has cfg.systemd.timers "restic-backups-${name}") allNames;
assert lib.all (
  name:
  backups.${name}.timerConfig == null
  && !backups.${name}.createWrapper
  && !backups.${name}.initialize
  && backups.${name}.pruneOpts == [ ]
) allNames;
assert lib.all (
  name:
  backups.${name}.paths == [ (input name) ]
  &&
    lib.hasInfix
      (builtins.unsafeDiscardStringContext "${producer name}/bin/prepare-reader --max-age 86400")
      backups.${name}.backupPrepareCommand
  && builtins.hasContext backups.${name}.backupPrepareCommand
  && lib.hasInfix "mkdir -m 700" backups.${name}.backupPrepareCommand
  && lib.hasInfix (input name) backups.${name}.backupPrepareCommand
  && lib.hasInfix (input name) backups.${name}.backupCleanupCommand
  && (service name).environment.RESTIC_CACHE_DIR == "/var/cache/restic-backups-${name}/cache"
  && (service name).serviceConfig.TimeoutStartSec == "2h"
  && (service name).serviceConfig.TimeoutStopSec == "2min"
  && (service name).serviceConfig.KillMode == "control-group"
  && lib.hasInfix " backup " (command name)
) names;
assert builtins.length (lib.unique (map (name: backups.${name}.repositoryFile) names)) == 4;
assert builtins.length (lib.unique (map (name: backups.${name}.passwordFile) names)) == 4;
assert lib.all (
  name:
  lib.hasPrefix "/run/" backups.${name}.repositoryFile
  && lib.hasPrefix "/run/" backups.${name}.passwordFile
) allNames;
assert lib.all (
  name:
  lib.all
    (
      suffix:
      let
        check = backups."${name}-${suffix}";
      in
      check.repositoryFile == backups.${name}.repositoryFile
      && check.repository == backups.${name}.repository
      && check.passwordFile == backups.${name}.passwordFile
      && check.package == backups.${name}.package
      && check.environmentFile == backups.${name}.environmentFile
      && check.rcloneConfigFile == backups.${name}.rcloneConfigFile
      && check.rcloneOptions == backups.${name}.rcloneOptions
      && check.rcloneConfig == backups.${name}.rcloneConfig
      && check.extraOptions == backups.${name}.extraOptions
      && check.user == backups.${name}.user
      && check.paths == [ ]
      && check.runCheck
      && check.backupPrepareCommand == null
      && check.backupCleanupCommand == null
      && check.checkOpts == (if suffix == "full" then [ "--read-data" ] else [ ])
      && lib.hasInfix " check " (command "${name}-${suffix}")
      && builtins.hasContext (command "${name}-${suffix}")
    )
    [
      "structure"
      "full"
    ]
) names;
assert lib.all
  (
    name:
    (service name).serviceConfig.EnvironmentFile == "/run/backup-secrets/fixture-backend-env"
    && (service name).environment.RCLONE_CONFIG == "/run/backup-secrets/fixture-rclone-config"
    && (service name).environment.RCLONE_TRANSFERS == "2"
    && lib.hasInfix "s3.region=fixture-region" (command name)
  )
  [
    "vaultwarden-a"
    "vaultwarden-a-structure"
    "vaultwarden-a-full"
  ];
assert lib.all (
  name:
  has cfg.systemd.services name
  && !has cfg.systemd.timers name
  && cfg.systemd.services.${name}.serviceConfig.User == "root"
  && cfg.systemd.services.${name}.serviceConfig.StateDirectoryMode == "0700"
  && cfg.systemd.services.${name}.serviceConfig.RuntimeDirectoryMode == "0700"
) exportNames;
assert lib.all (
  name: !has disabled.systemd.services name && !has disabled.systemd.timers name
) exportNames;
assert !(has disabled.system.build "appsVaultwardenExport");
assert !(has disabled.system.build "appsLiveSyncExport");
assert disabled.services.restic.backups == { };
assert !(has cfg.clanwright "reliability");
pkgs.runCommand "reliability-apps-composition"
  {
    # This is evaluation evidence, not a build or retention of x86 application
    # closures on an ARM builder. Command contexts are asserted above.
    report = builtins.unsafeDiscardStringContext (builtins.toJSON report);
    passAsFile = [ "report" ];
  }
  ''
    mkdir -p "$out"
    cp "$reportPath" "$out/report.json"
  ''
