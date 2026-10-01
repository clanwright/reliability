{
  observe ? false,
  admissionMaxAgeSeconds ? (if observe then 64800 else 86400),
  arrivalMaxAgeSeconds ? 86400,
  metricsDirectory ? "/var/lib/prometheus-node-exporter-text-files",
}:
{
  config,
  lib,
  pkgs,
  ...
}:

# Enable the Apps exports in the consumer before importing this module.
# Only their public system.build outputs and prepare-reader command are used.
let
  jobs =
    lib.concatMap
      (
        app:
        map
          (destination: {
            inherit app destination;
            name = "${app}-${destination}";
            format = if app == "vaultwarden" then "vaultwarden-pg18-files-v1" else "livesync-couchdb3-v1";
          })
          [
            "a"
            "b"
          ]
      )
      [
        "vaultwarden"
        "livesync"
      ];
  invocationTag = "--tag=reliability-invocation:\${INVOCATION_ID}";
  input = job: "/var/cache/restic-backups-${job.name}/apps-input";
  backupJob = job: {
    "${job.name}" =
      let
        backup = config.services.restic.backups.${job.name};
        producer =
          if job.app == "vaultwarden" then
            config.system.build.appsVaultwardenExport
          else
            config.system.build.appsLiveSyncExport;
      in
      {
        repositoryFile = lib.mkDefault (
          if backup.repository == null then "/run/backup-config/${job.name}-repository" else null
        );
        passwordFile = lib.mkDefault "/run/backup-secrets/${job.name}-password";
        user = lib.mkDefault "root";
        paths = [ (input job) ];
        initialize = false;
        pruneOpts = [ ];
        timerConfig = lib.mkDefault null;
        createWrapper = false;
        backupPrepareCommand = ''
          #!${pkgs.runtimeShell}
          set -euo pipefail
          umask 077
          if [[ ! "''${INVOCATION_ID:-}" =~ ^[0-9a-f]{32}$ ]]; then
            printf 'Apps reader preparation requires a valid native invocation identity\n' >&2
            exit 1
          fi
          claim="/run/restic-backups-${job.name}/reader-owned-$INVOCATION_ID"
          ${pkgs.coreutils}/bin/mkdir -m 700 -- ${lib.escapeShellArg (input job)}
          (set -o noclobber; : > "$claim")
          ${producer}/bin/prepare-reader --max-age ${lib.escapeShellArg (toString admissionMaxAgeSeconds)} ${lib.escapeShellArg (input job)}
        '';
        # Native ExecStopPost also runs after failed preparation. Only the
        # invocation that created and claimed this reader may remove it.
        # Native stop/descendant lifetime proof remains a separate gate.
        backupCleanupCommand = ''
          #!${pkgs.runtimeShell}
          set -euo pipefail
          if [[ ! -e ${lib.escapeShellArg (input job)} && ! -L ${lib.escapeShellArg (input job)} ]]; then
            exit 0
          fi
          if [[ ! "''${INVOCATION_ID:-}" =~ ^[0-9a-f]{32}$ ]]; then
            printf 'Apps reader cleanup refused an unclaimed reader\n' >&2
            exit 1
          fi
          claim="/run/restic-backups-${job.name}/reader-owned-$INVOCATION_ID"
          if [[ ! -f "$claim" || -L "$claim" ]]; then
            printf 'Apps reader cleanup refused an unclaimed reader\n' >&2
            exit 1
          fi
          ${pkgs.coreutils}/bin/rm -rf -- ${lib.escapeShellArg (input job)}
          ${pkgs.coreutils}/bin/rm -f -- "$claim"
        '';
        extraBackupArgs = lib.optional observe invocationTag;
      };
  };
  checks =
    job:
    let
      backup = config.services.restic.backups.${job.name};
      destination = {
        inherit (backup)
          repository
          repositoryFile
          passwordFile
          package
          environmentFile
          rcloneConfigFile
          rcloneOptions
          rcloneConfig
          extraOptions
          user
          ;
        paths = [ ];
        runCheck = true;
        initialize = false;
        pruneOpts = [ ];
        timerConfig = lib.mkDefault null;
        createWrapper = false;
      };
    in
    {
      "${job.name}-structure" = destination // {
        checkOpts = [ ];
      };
      "${job.name}-full" = destination // {
        checkOpts = [ "--read-data" ];
      };
    };
  unit =
    job:
    let
      backup = config.services.restic.backups.${job.name};
      observer = import ../packages/capture-observation.nix {
        inherit pkgs;
        restic = backup.package;
      };
      command = args: lib.escapeShellArgs ([ "${observer}/bin/restic-capture-observe" ] ++ args);
      options = lib.concatMap (option: [
        "--option"
        option
      ]) backup.extraOptions;
    in
    lib.nameValuePair "restic-backups-${job.name}" (
      lib.mkMerge [
        {
          environment.RESTIC_CACHE_DIR = lib.mkForce "/var/cache/restic-backups-${job.name}/cache";
          serviceConfig = {
            Type = "oneshot";
            TimeoutStartSec = "2h";
            TimeoutStopSec = "2min";
            KillMode = "control-group";
            SendSIGKILL = true;
          };
        }
        (lib.optionalAttrs observe {
          # Fail closed before preparing any reader if pending status cannot be written.
          preStart = lib.mkBefore ''
            ${command [
              "start"
              job.app
              job.destination
              metricsDirectory
            ]}
          '';
          # A native oneshot reaches ExecStartPost only after exit-0 backup.
          postStart = ''
            ${
              command [
                "observe"
                job.app
                job.destination
                job.format
                (toString arrivalMaxAgeSeconds)
                (input job)
                metricsDirectory
              ]
            } "$INVOCATION_ID" ${lib.escapeShellArgs options}
          '';
          serviceConfig.SuccessExitStatus = lib.mkForce [ ];
        })
      ]
    );
in
{
  assertions = [
    {
      assertion =
        builtins.isInt admissionMaxAgeSeconds
        && admissionMaxAgeSeconds > 0
        && admissionMaxAgeSeconds <= 86400;
      message = "Apps capture admission age must be a positive integer no greater than this composition's 86400-second policy ceiling.";
    }
  ]
  ++ lib.optionals observe (
    [
      {
        assertion =
          builtins.isInt arrivalMaxAgeSeconds
          && builtins.isInt admissionMaxAgeSeconds
          && arrivalMaxAgeSeconds > 0
          && arrivalMaxAgeSeconds >= admissionMaxAgeSeconds;
        message = "Apps capture arrival age must be a positive integer at least as large as admission age.";
      }
      {
        assertion =
          builtins.isString metricsDirectory && builtins.match "/[A-Za-z0-9_./-]+" metricsDirectory != null;
        message = "Apps capture metrics directory must be an absolute path using letters, digits, slash, dot, underscore or hyphen, without systemd specifiers or whitespace.";
      }
    ]
    ++ map (job: {
      assertion = lib.all (
        cmd: !(lib.hasPrefix "-" cmd)
      ) config.systemd.services."restic-backups-${job.name}".serviceConfig.ExecStart;
      message = "Observed Restic ${job.name} must not ignore ExecStart failures.";
    }) jobs
  );
  services.restic.backups = lib.mkMerge (map backupJob jobs ++ map checks jobs);
  systemd.services = lib.listToAttrs (map unit jobs);
  systemd.tmpfiles.rules = lib.optional observe "d ${metricsDirectory} 0755 root root - -";
}
