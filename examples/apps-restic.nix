{ apps }:
{ config, lib, ... }:

# Enable the Apps exports before importing this module. The upstream example
# owns the reader preparation and cleanup hooks; all jobs remain manual-only.
let
  names = [
    "vaultwarden-a"
    "vaultwarden-b"
    "livesync-a"
    "livesync-b"
  ];
  checks =
    name:
    let
      backup = config.services.restic.backups.${name};
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
        timerConfig = null;
        createWrapper = false;
      };
    in
    {
      "${name}-structure" = destination // {
        checkOpts = [ ];
      };
      "${name}-full" = destination // {
        checkOpts = [ "--read-data" ];
      };
    };
in
{
  imports = [ (apps + "/examples/native-restic.nix") ];

  services.restic.backups = lib.mkMerge (map checks names);
}
