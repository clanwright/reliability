{
  apps,
  admissionMaxAgeSeconds ? 64800,
  arrivalMaxAgeSeconds ? 86400,
  metricsDirectory ? "/var/lib/prometheus-node-exporter-text-files",
}:
{
  config,
  lib,
  pkgs,
  ...
}:

let
  observer = import ../packages/capture-observation.nix { inherit pkgs; };
  observe = "${observer}/bin/restic-capture-observe";
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
  command = args: lib.escapeShellArgs ([ observe ] ++ args);
  unit =
    job:
    let
      backup = config.services.restic.backups.${job.name};
      input = "/var/cache/restic-backups-${job.name}/apps-input";
      options = lib.concatMap (option: [
        "--option"
        option
      ]) backup.extraOptions;
    in
    lib.nameValuePair "restic-backups-${job.name}" {
      preStart = lib.mkMerge [
        (lib.mkBefore ''
          ${command [
            "start"
            job.app
            job.destination
            metricsDirectory
          ]}
        '')
        (lib.mkAfter ''
          ${command [
            "admit"
            job.app
            job.format
            (toString admissionMaxAgeSeconds)
            "${input}/export.json"
          ]}
        '')
      ];
      # ExecStartPost runs only after native Restic has exited successfully.
      # Its environment supplies the same repository and backend credentials.
      postStart = ''
        export RESTIC_OBSERVER_RESTIC=${lib.escapeShellArg "${backup.package}/bin/restic"}
        ${
          command [
            "observe"
            job.app
            job.destination
            job.format
            (toString arrivalMaxAgeSeconds)
            input
            metricsDirectory
          ]
        } "$INVOCATION_ID" ${lib.escapeShellArgs options}
      '';
      serviceConfig.SuccessExitStatus = lib.mkForce [ ];
    };
in
{
  imports = [ (import ./apps-restic.nix { inherit apps; }) ];

  assertions = [
    {
      assertion =
        builtins.isInt admissionMaxAgeSeconds
        && admissionMaxAgeSeconds > 0
        && admissionMaxAgeSeconds <= 86400;
      message = "Apps capture admission age must be a positive integer no greater than the upstream 86400-second reader ceiling.";
    }
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
  }) jobs;

  services.restic.backups = lib.listToAttrs (
    map (
      job:
      lib.nameValuePair job.name {
        # systemd expands this literal in the native ExecStart argument.
        extraBackupArgs = [ invocationTag ];
      }
    ) jobs
  );
  systemd.services = lib.listToAttrs (map unit jobs);
  systemd.tmpfiles.rules = [ "d ${metricsDirectory} 0755 root root - -" ];
}
