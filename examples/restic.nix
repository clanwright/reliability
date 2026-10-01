{ ... }:

# Generic file-backup example for externally prepared stable input.
# Its calendars do not enforce export readiness, capture freshness or reader
# lifetime. The producer must keep the selected files stable until every reader
# finishes; do not replace/remove them merely because a newer export is ready.
# Restic comes from the importing NixOS configuration's package set.
let
  # Placeholder repositories and runtime secret paths; supply both before enabling.
  primary = {
    repository = "/var/lib/example-restic/primary";
    passwordFile = "/run/secrets/example-restic-primary-password";
    environmentFile = "/run/secrets/example-restic-primary-env";
    initialize = false;
    pruneOpts = [ ];
  };
  secondary = {
    repository = "/var/lib/example-restic/secondary";
    passwordFile = "/run/secrets/example-restic-secondary-password";
    environmentFile = "/run/secrets/example-restic-secondary-env";
    initialize = false;
    pruneOpts = [ ];
  };
in
{
  services.restic.backups = {
    primary = primary // {
      # Use only externally prepared files with a supported reader lifetime.
      paths = [ "/srv/backup-input" ];
      timerConfig.OnCalendar = "*-*-* 02:15:00";
    };
    secondary = secondary // {
      paths = [ "/srv/backup-input" ];
      timerConfig.OnCalendar = "*-*-* 03:15:00";
    };

    primary-structure = primary // {
      paths = [ ];
      runCheck = true;
      checkOpts = [ ];
      createWrapper = false;
      timerConfig.OnCalendar = "Sun *-*-* 04:15:00";
    };
    secondary-structure = secondary // {
      paths = [ ];
      runCheck = true;
      checkOpts = [ ];
      createWrapper = false;
      timerConfig.OnCalendar = "Sun *-*-* 05:15:00";
    };

    primary-full = primary // {
      paths = [ ];
      runCheck = true;
      checkOpts = [ "--read-data" ];
      createWrapper = false;
      timerConfig.OnCalendar = "*-*-01 04:30:00";
    };
    secondary-full = secondary // {
      paths = [ ];
      runCheck = true;
      checkOpts = [ "--read-data" ];
      createWrapper = false;
      timerConfig.OnCalendar = "*-*-01 05:30:00";
    };
  };
}
