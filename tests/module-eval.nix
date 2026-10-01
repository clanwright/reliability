{
  pkgs,
  nixosSystem,
}:

let
  lib = pkgs.lib;
  cfg =
    (nixosSystem {
      system = "x86_64-linux";
      modules = [
        ../examples/restic.nix
        {
          boot.isContainer = true;
          system.stateVersion = "25.11";
        }
      ];
    }).config;
  backups = cfg.services.restic.backups;
  services = cfg.systemd.services;
  timers = cfg.systemd.timers;
  has = set: name: builtins.hasAttr name set;
  names = [
    "primary"
    "secondary"
    "primary-structure"
    "secondary-structure"
    "primary-full"
    "secondary-full"
  ];
  backupNames = [
    "primary"
    "secondary"
  ];
  checkNames = [
    "primary-structure"
    "secondary-structure"
    "primary-full"
    "secondary-full"
  ];
  service = name: services."restic-backups-${name}";
  command = name: builtins.head ((service name).serviceConfig.ExecStart);
in
assert lib.all (item: item.assertion) cfg.assertions;
assert builtins.length (builtins.attrNames backups) == builtins.length names;
assert lib.all (
  name:
  has backups name && has services "restic-backups-${name}" && has timers "restic-backups-${name}"
) names;
assert lib.all (name: !backups.${name}.initialize && backups.${name}.pruneOpts == [ ]) names;
assert lib.all (name: backups.${name}.paths == [ "/srv/backup-input" ]) backupNames;
assert lib.all (name: backups.${name}.paths == [ ] && backups.${name}.runCheck) checkNames;
assert lib.all (name: backups.${name}.checkOpts == [ ]) [
  "primary-structure"
  "secondary-structure"
];
assert lib.all (name: backups.${name}.checkOpts == [ "--read-data" ]) [
  "primary-full"
  "secondary-full"
];
assert backups.primary.repository != backups.secondary.repository;
assert backups.primary.passwordFile != backups.secondary.passwordFile;
assert backups.primary.environmentFile != backups.secondary.environmentFile;
assert lib.all (
  name:
  lib.hasPrefix "/run/" backups.${name}.passwordFile
  && lib.hasPrefix "/run/" backups.${name}.environmentFile
) names;
assert lib.all (
  name: (service name).serviceConfig.EnvironmentFile == backups.${name}.environmentFile
) names;
assert lib.all (
  name: (service name).environment.RESTIC_PASSWORD_FILE == backups.${name}.passwordFile
) names;
assert lib.all (name: builtins.length ((service name).serviceConfig.ExecStart) == 1) names;
assert lib.all (name: lib.hasInfix " backup " (command name)) backupNames;
assert lib.all (name: lib.hasInfix " check " (command name)) checkNames;
assert lib.all (name: !(lib.hasInfix "--read-data" (command name))) [
  "primary-structure"
  "secondary-structure"
];
assert lib.all (name: lib.hasInfix "--read-data" (command name)) [
  "primary-full"
  "secondary-full"
];
assert lib.all (
  name:
  timers."restic-backups-${name}".timerConfig.OnCalendar == backups.${name}.timerConfig.OnCalendar
) names;
assert
  builtins.length (lib.unique (map (name: backups.${name}.timerConfig.OnCalendar) names))
  == builtins.length names;
assert lib.all (
  name: builtins.any (pkg: pkg.name == "restic-${name}") cfg.environment.systemPackages
) backupNames;
pkgs.runCommand "reliability-native-module-eval" { } ''
  touch "$out"
''
