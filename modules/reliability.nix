{
  config,
  lib,
  options,
  pkgs,
  ...
}:

let
  inherit (lib)
    mkEnableOption
    mkIf
    mkOption
    types
    ;
  cfg = config.clanwright.reliability;
  recoveryAvailable = lib.hasAttrByPath [ "clanwright" "recovery" "units" ] options;
  recoveryUnits = if recoveryAvailable then config.clanwright.recovery.units else { };
  validId = id: builtins.match "[a-z][a-z0-9-]*" id != null;
  executable =
    command:
    if builtins.isString command then
      command
    else if builtins.isList command && command != [ ] && builtins.isString (builtins.head command) then
      builtins.head command
    else
      "";
  selected = lib.genAttrs cfg.selectedUnits (id: recoveryUnits.${id} or { });
  runtimeUnits = lib.mapAttrs (_: unit: {
    inherit (unit)
      contractVersion
      formatVersion
      captureCommand
      validateCommand
      ;
  }) selected;
  runtimeDestinations = lib.mapAttrs (
    _: destination:
    {
      inherit (destination) repository passwordFile;
    }
    // lib.optionalAttrs (destination.environmentFile != null) {
      inherit (destination) environmentFile;
    }
    // lib.optionalAttrs (destination.rcloneConfigFile != null) {
      inherit (destination) rcloneConfigFile;
    }
    // lib.optionalAttrs (destination.expectedRepositoryId != null) {
      inherit (destination) expectedRepositoryId;
    }
    // lib.optionalAttrs (destination.maintenancePolicyFingerprint != null) {
      inherit (destination) maintenancePolicyFingerprint;
    }
  ) cfg.destinations;
  runtimePolicy = {
    inherit (cfg.policy)
      captureTimeoutSeconds
      backupTimeoutSeconds
      checkTimeoutSeconds
      restoreTimeoutSeconds
      maxStagingBytes
      warningAgeHours
      criticalAgeHours
      maintenanceEnabled
      maintenanceCommissioned
      maintenanceDeletionCeiling
      maintenanceMinimumSnapshotsPerUnit
      retention
      ;
  };
  runtimeConfig = pkgs.writeText "clanwright-reliability.json" (
    builtins.toJSON {
      stateDirectory = cfg.stateDirectory;
      units = runtimeUnits;
      destinations = runtimeDestinations;
      policy = runtimePolicy;
    }
  );
  package = pkgs.callPackage ../nix/package.nix {
    bubblewrap = if pkgs.stdenv.hostPlatform.isLinux then pkgs.bubblewrap else null;
  };
  command =
    action: destination:
    "${package}/bin/reliability --config ${runtimeConfig} ${action}"
    + lib.optionalString (destination != null) " ${destination}"
    + lib.optionalString (
      action == "status" && cfg.metricsFile != null
    ) " --metrics-file ${cfg.metricsFile}";
  service = description: action: destination: privateNetwork: {
    inherit description;
    serviceConfig = {
      Type = "oneshot";
      ExecStart = command action destination;
      User = "root";
      StateDirectory = "clanwright-reliability";
      StateDirectoryMode = "0700";
      WorkingDirectory = cfg.stateDirectory;
      UMask = "0077";
      TimeoutStartSec = "3h";
      NoNewPrivileges = true;
      PrivateDevices = true;
      PrivateTmp = true;
      PrivateNetwork = privateNetwork;
      ProtectSystem = "strict";
      ProtectHome = true;
      ProtectKernelTunables = true;
      ProtectKernelModules = true;
      ProtectControlGroups = true;
      LockPersonality = true;
      RestrictSUIDSGID = true;
      CapabilityBoundingSet =
        if action == "capture" then
          [
            "CAP_DAC_READ_SEARCH"
            "CAP_DAC_OVERRIDE"
            "CAP_CHOWN"
            "CAP_FOWNER"
            "CAP_SETUID"
            "CAP_SETGID"
            "CAP_KILL"
          ]
        else if action == "restore-check" then
          [
            "CAP_CHOWN"
            "CAP_SETUID"
            "CAP_SETGID"
            "CAP_FOWNER"
            "CAP_DAC_OVERRIDE"
            "CAP_DAC_READ_SEARCH"
          ]
        else
          "";
      ReadWritePaths = [
        cfg.stateDirectory
      ]
      ++ lib.optionals (action == "capture") cfg.captureWritablePaths
      ++ lib.optional (action == "restore-check") "/var/tmp"
      ++ lib.optional (action == "status" && cfg.metricsFile != null) (builtins.dirOf cfg.metricsFile);
    };
  };
  destinations = builtins.attrNames cfg.destinations;
  backupName = id: "clanwright-reliability-backup-${id}";
  checkName = id: "clanwright-reliability-check-${id}";
  readCheckName = id: "clanwright-reliability-read-check-${id}";
  restoreName = id: "clanwright-reliability-restore-check-${id}";
  maintenanceName = id: "clanwright-reliability-maintenance-${id}";
in
{
  options.clanwright.reliability = {
    enable = mkEnableOption "the standalone Clanwright reliability executor";
    selectedUnits = mkOption {
      type = types.listOf types.str;
      default = [ ];
      description = "Stable public recovery unit IDs supplied by Primitives or another contract producer.";
    };
    stateDirectory = mkOption {
      type = types.str;
      default = "/var/lib/clanwright-reliability";
      description = "Private local generation and evidence directory.";
    };
    captureWritablePaths = mkOption {
      type = types.listOf types.str;
      default = [ ];
      description = "Explicit non-secret host paths native owner capture hooks must write; empty by default.";
    };
    metricsFile = mkOption {
      type = types.nullOr types.str;
      default = null;
      description = "Optional absolute node-exporter textfile path for sanitized backup status metrics.";
    };
    destinations = mkOption {
      default = { };
      type = types.attrsOf (
        types.submodule {
          options = {
            repository = mkOption {
              type = types.str;
              description = "Credential-free Restic repository location.";
            };
            passwordFile = mkOption {
              type = types.str;
              description = "Absolute runtime path to the Restic password file.";
            };
            environmentFile = mkOption {
              type = types.nullOr types.str;
              default = null;
              description = "Optional runtime AWS environment path.";
            };
            rcloneConfigFile = mkOption {
              type = types.nullOr types.str;
              default = null;
              description = "Optional runtime rclone configuration path.";
            };
            expectedRepositoryId = mkOption {
              type = types.nullOr types.str;
              default = null;
              description = "Commissioned Restic repository ID required for maintenance.";
            };
            maintenancePolicyFingerprint = mkOption {
              type = types.nullOr types.str;
              default = null;
              description = "Reviewed scope and retention fingerprint for this destination.";
            };
          };
        }
      );
      description = "Independent backup destinations and runtime-only credential paths.";
    };
    policy = {
      captureTimeoutSeconds = mkOption {
        type = types.ints.positive;
        default = 3600;
      };
      backupTimeoutSeconds = mkOption {
        type = types.ints.positive;
        default = 7200;
      };
      checkTimeoutSeconds = mkOption {
        type = types.ints.positive;
        default = 7200;
      };
      restoreTimeoutSeconds = mkOption {
        type = types.ints.positive;
        default = 7200;
      };
      maxStagingBytes = mkOption {
        type = types.ints.positive;
        default = 10737418240;
      };
      warningAgeHours = mkOption {
        type = types.ints.positive;
        default = 18;
      };
      criticalAgeHours = mkOption {
        type = types.ints.positive;
        default = 24;
      };
      maintenanceEnabled = mkOption {
        type = types.bool;
        default = false;
      };
      maintenanceCommissioned = mkOption {
        type = types.bool;
        default = false;
      };
      maintenanceDeletionCeiling = mkOption {
        type = types.ints.unsigned;
        default = 0;
      };
      maintenanceMinimumSnapshotsPerUnit = mkOption {
        type = types.ints.positive;
        default = 2;
      };
      retention = {
        keepWithin = mkOption {
          type = types.str;
          default = "7d";
        };
        keepWithinDaily = mkOption {
          type = types.str;
          default = "1m";
        };
        keepWithinWeekly = mkOption {
          type = types.str;
          default = "3m";
        };
        keepWithinMonthly = mkOption {
          type = types.str;
          default = "1y";
        };
      };
    };
  };

  config = mkIf cfg.enable {
    assertions = [
      {
        assertion = recoveryAvailable;
        message = "Reliability requires a separately imported clanwright.recovery.units contract producer.";
      }
      {
        assertion =
          cfg.selectedUnits != [ ]
          && lib.all validId cfg.selectedUnits
          && lib.length cfg.selectedUnits == lib.length (lib.unique cfg.selectedUnits);
        message = "Reliability selectedUnits must be nonempty, unique, safe stable IDs.";
      }
      {
        assertion = lib.all (id: builtins.hasAttr id recoveryUnits) cfg.selectedUnits;
        message = "Reliability selectedUnits must exist in clanwright.recovery.units.";
      }
      {
        assertion = lib.all (
          unit:
          (unit.contractVersion or null) == 1
          && (unit.formatVersion or "") != ""
          && lib.hasPrefix "/" (executable (unit.captureCommand or ""))
          && lib.hasPrefix "/nix/store/" (executable (unit.validateCommand or ""))
        ) (builtins.attrValues selected);
        message = "Reliability recovery units need contract v1, a format, an absolute capture executable and a store-backed validator.";
      }
      {
        assertion = cfg.stateDirectory == "/var/lib/clanwright-reliability";
        message = "Reliability currently requires its dedicated systemd StateDirectory.";
      }
      {
        assertion = lib.all (path: lib.hasPrefix "/" path && path != "/") cfg.captureWritablePaths;
        message = "Reliability capture writable paths must be explicit absolute non-root paths.";
      }
      {
        assertion =
          cfg.metricsFile == null
          || (lib.hasPrefix "/" cfg.metricsFile && builtins.dirOf cfg.metricsFile != "/");
        message = "Reliability metricsFile must be an absolute path below a dedicated directory.";
      }
      {
        assertion = cfg.destinations != { } && lib.all validId destinations;
        message = "Reliability requires at least one destination with a safe stable ID.";
      }
      {
        assertion = lib.all (
          destination:
          lib.hasPrefix "/" destination.passwordFile
          && (destination.environmentFile == null || lib.hasPrefix "/" destination.environmentFile)
          && (destination.rcloneConfigFile == null || lib.hasPrefix "/" destination.rcloneConfigFile)
          && (
            lib.hasPrefix "/" destination.repository
            || lib.hasPrefix "s3:" destination.repository
            || lib.hasPrefix "rclone:" destination.repository
          )
          && builtins.match ".*[@?#].*" destination.repository == null
        ) (builtins.attrValues cfg.destinations);
        message = "Reliability destinations need absolute runtime credential paths and credential-free local/S3/rclone repository locations.";
      }
      {
        assertion = cfg.policy.warningAgeHours < cfg.policy.criticalAgeHours;
        message = "Reliability warning age must be below critical age.";
      }
      {
        assertion =
          !cfg.policy.maintenanceEnabled
          || (
            cfg.policy.maintenanceDeletionCeiling > 0
            && lib.all (destination: destination.expectedRepositoryId != null) (
              builtins.attrValues cfg.destinations
            )
            && (
              !cfg.policy.maintenanceCommissioned
              || lib.all (destination: destination.maintenancePolicyFingerprint != null) (
                builtins.attrValues cfg.destinations
              )
            )
          );
        message = "Reliability maintenance planning requires a deletion ceiling and repository IDs; scheduled maintenance additionally requires reviewed per-destination fingerprints.";
      }
      {
        assertion = !cfg.policy.maintenanceCommissioned || cfg.policy.maintenanceEnabled;
        message = "Reliability maintenance cannot be commissioned while disabled.";
      }
    ];

    users.groups.reliability-validator = { };
    users.users.reliability-validator = {
      isSystemUser = true;
      group = "reliability-validator";
      description = "Unprivileged offline recovery validator";
    };

    systemd.services = {
      clanwright-reliability-capture =
        (service "Capture complete recovery generation" "capture" null true)
        // {
          unitConfig.OnSuccess = map (id: "${backupName id}.service") destinations;
        };
      clanwright-reliability-status = service "Publish recovery freshness status" "status" null true;
    }
    // lib.genAttrs' destinations (
      id:
      lib.nameValuePair (backupName id) (service "Upload recovery generation to ${id}" "backup" id false)
    )
    // lib.genAttrs' destinations (
      id: lib.nameValuePair (checkName id) (service "Check recovery repository ${id}" "check" id false)
    )
    // lib.genAttrs' destinations (
      id:
      lib.nameValuePair (readCheckName id) (
        service "Read all recovery data from ${id}" "check" "${id} --read-data" false
      )
    )
    // lib.genAttrs' destinations (
      id:
      lib.nameValuePair (restoreName id) (
        service "Restore and validate recovery from ${id}" "restore-check" id false
      )
    )
    // lib.optionalAttrs (cfg.policy.maintenanceEnabled && cfg.policy.maintenanceCommissioned) (
      lib.genAttrs' destinations (
        id:
        lib.nameValuePair (maintenanceName id) (
          service "Commissioned recovery maintenance for ${id}" "maintenance-run" id false
        )
      )
    );

    systemd.timers = {
      clanwright-reliability-capture = {
        wantedBy = [ "timers.target" ];
        timerConfig = {
          OnCalendar = "*-*-* 00,12:00:00";
          Persistent = true;
          RandomizedDelaySec = "15m";
        };
      };
      clanwright-reliability-status = {
        wantedBy = [ "timers.target" ];
        timerConfig = {
          OnBootSec = "5m";
          OnUnitInactiveSec = "5m";
        };
      };
    }
    // lib.genAttrs' destinations (
      id:
      lib.nameValuePair (backupName id) {
        wantedBy = [ "timers.target" ];
        timerConfig = {
          OnBootSec = "30m";
          OnUnitInactiveSec = "1h";
          RandomizedDelaySec = "10m";
        };
      }
    )
    // lib.genAttrs' destinations (
      id:
      lib.nameValuePair (checkName id) {
        wantedBy = [ "timers.target" ];
        timerConfig = {
          OnCalendar = "Sun *-*-* 04:00:00";
          Persistent = true;
          RandomizedDelaySec = "1h";
        };
      }
    )
    // lib.genAttrs' destinations (
      id:
      lib.nameValuePair (restoreName id) {
        wantedBy = [ "timers.target" ];
        timerConfig = {
          OnCalendar = "*-*-01 05:00:00";
          Persistent = true;
          RandomizedDelaySec = "2h";
        };
      }
    )
    // lib.genAttrs' destinations (
      id:
      lib.nameValuePair (readCheckName id) {
        wantedBy = [ "timers.target" ];
        timerConfig = {
          OnCalendar = "*-*-01 04:00:00";
          Persistent = true;
          RandomizedDelaySec = "2h";
        };
      }
    )
    // lib.optionalAttrs (cfg.policy.maintenanceEnabled && cfg.policy.maintenanceCommissioned) (
      lib.genAttrs' destinations (
        id:
        lib.nameValuePair (maintenanceName id) {
          wantedBy = [ "timers.target" ];
          timerConfig = {
            OnCalendar = "Mon *-*-* 06:00:00";
            Persistent = true;
            RandomizedDelaySec = "1h";
          };
        }
      )
    );
  };
}
