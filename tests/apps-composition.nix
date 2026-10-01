{ pkgs, apps }:

let
  lib = pkgs.lib;
  fixture = import ./apps-fixture.nix { inherit apps; };
  baseline = fixture { };
  observed = fixture { observe = true; };
  names = [
    "vaultwarden-a"
    "vaultwarden-b"
    "livesync-a"
    "livesync-b"
  ];
  suffixes = [
    "structure"
    "full"
  ];
  checkNames = lib.concatMap (name: map (suffix: "${name}-${suffix}") suffixes) names;
  allNames = names ++ checkNames;
  metrics = "/var/lib/prometheus-node-exporter-text-files";
  invocationTag = "--tag=reliability-invocation:\${INVOCATION_ID}";
  backup = cfg: name: cfg.services.restic.backups.${name};
  service = cfg: name: cfg.systemd.services."restic-backups-${name}";
  command = cfg: name: builtins.head (service cfg name).serviceConfig.ExecStart;
  input = name: "/var/cache/restic-backups-${name}/apps-input";
  producer =
    cfg: name:
    if lib.hasPrefix "vaultwarden-" name then
      cfg.system.build.appsVaultwardenExport
    else
      cfg.system.build.appsLiveSyncExport;
  contains = expected: actual: lib.hasInfix (builtins.unsafeDiscardStringContext expected) actual;
  fixturePkgs = import apps.inputs.apps-nixpkgs { system = "x86_64-linux"; };
  hookJob = backup baseline "vaultwarden-a";
  knownHookContexts = builtins.attrNames (
    builtins.getContext (
      fixturePkgs.runtimeShell
      + toString fixturePkgs.coreutils
      + toString (producer baseline "vaultwarden-a")
    )
  );
  knownContexts =
    text:
    lib.all (path: builtins.elem path knownHookContexts) (
      builtins.attrNames (builtins.getContext text)
    );
  # Execute the evaluated hooks with only their machine paths, host tooling and
  # public producer replaced. This proves filesystem/process behavior, not Apps
  # capture, database consistency or system-manager cancellation/lifetime.
  renderHook =
    text:
    builtins.replaceStrings
      [
        fixturePkgs.runtimeShell
        (toString fixturePkgs.coreutils)
        "${producer baseline "vaultwarden-a"}/bin/prepare-reader"
        (input "vaultwarden-a")
        "/run/restic-backups-vaultwarden-a"
      ]
      [
        pkgs.runtimeShell
        (toString pkgs.coreutils)
        ''"$fixtureProducer"''
        ''"$reader"''
        "$runtime"
      ]
      (builtins.unsafeDiscardStringContext text);
  plainModule =
    settings:
    (import ../examples/apps-restic.nix settings) {
      config = observed;
      inherit lib;
      pkgs = fixturePkgs;
    };
  valid = settings: lib.all (item: item.assertion) (plainModule settings).assertions;
  invalid =
    settings:
    lib.any (item: !item.assertion && lib.hasInfix "Apps capture" item.message)
      (plainModule ({ observe = true; } // settings)).assertions;
  customSettings = {
    observe = true;
    admissionMaxAgeSeconds = 43200;
    arrivalMaxAgeSeconds = 64800;
    metricsDirectory = "/var/lib/fixture-metrics";
  };
  custom = plainModule customSettings;
  customPrepare =
    (builtins.head custom.services.restic.backups.contents).vaultwarden-a.backupPrepareCommand;
  customUnit = builtins.elemAt custom.systemd.services.restic-backups-vaultwarden-a.contents 1;
  customBaseline = plainModule { admissionMaxAgeSeconds = 3600; };
  customBaselinePrepare =
    (builtins.head customBaseline.services.restic.backups.contents).vaultwarden-a.backupPrepareCommand;
  nativeContracts =
    age: cfg:
    lib.all (item: item.assertion) cfg.assertions
    && builtins.attrNames cfg.services.restic.backups == lib.sort builtins.lessThan allNames
    && lib.all (
      name:
      let
        job = backup cfg name;
        unit = service cfg name;
      in
      job.timerConfig == null
      && !job.createWrapper
      && !job.initialize
      && job.pruneOpts == [ ]
      && !builtins.hasAttr "restic-backups-${name}" cfg.systemd.timers
      && unit.serviceConfig.CacheDirectory == "restic-backups-${name}"
      && unit.serviceConfig.CacheDirectoryMode == "0700"
      && unit.serviceConfig.User == "root"
      && unit.serviceConfig.User == job.user
      && unit.environment.RESTIC_REPOSITORY_FILE == job.repositoryFile
      && unit.environment.RESTIC_PASSWORD_FILE == job.passwordFile
      && lib.hasPrefix "/run/" job.repositoryFile
      && lib.hasPrefix "/run/" job.passwordFile
    ) allNames
    && lib.all (
      name:
      let
        job = backup cfg name;
        unit = service cfg name;
      in
      job.paths == [ (input name) ]
      && unit.serviceConfig.RuntimeDirectory == "restic-backups-${name}"
      && contains "${producer cfg name}/bin/prepare-reader --max-age ${lib.escapeShellArg (toString age)}" job.backupPrepareCommand
      && builtins.hasContext job.backupPrepareCommand
      && lib.hasInfix "set -euo pipefail" job.backupPrepareCommand
      && lib.hasInfix "umask 077" job.backupPrepareCommand
      && lib.hasInfix "set -euo pipefail" job.backupCleanupCommand
      && lib.hasInfix "mkdir -m 700" job.backupPrepareCommand
      && lib.hasInfix (input name) job.backupPrepareCommand
      && lib.hasInfix (input name) job.backupCleanupCommand
      && lib.hasInfix "backupPrepareCommand" unit.preStart
      && builtins.hasContext unit.preStart
      && lib.hasInfix "backupCleanupCommand" unit.postStop
      && unit.environment.RESTIC_CACHE_DIR == "/var/cache/restic-backups-${name}/cache"
      && unit.serviceConfig.TimeoutStartSec == "2h"
      && unit.serviceConfig.TimeoutStopSec == "2min"
      && unit.serviceConfig.KillMode == "control-group"
      && unit.serviceConfig.SendSIGKILL
      && lib.hasPrefix (lib.getExe job.package) (command cfg name)
      && lib.hasInfix " backup " (command cfg name)
      && builtins.length unit.serviceConfig.ExecStart == 1
    ) names
    && builtins.length (lib.unique (map (name: (backup cfg name).repositoryFile) names)) == 4
    && builtins.length (lib.unique (map (name: (backup cfg name).passwordFile) names)) == 4
    && lib.all (
      name:
      lib.all (
        suffix:
        let
          job = backup cfg name;
          check = backup cfg "${name}-${suffix}";
        in
        lib.all (attr: check.${attr} == job.${attr}) [
          "repository"
          "repositoryFile"
          "passwordFile"
          "package"
          "environmentFile"
          "rcloneConfigFile"
          "rcloneOptions"
          "rcloneConfig"
          "extraOptions"
          "user"
        ]
        && check.paths == [ ]
        && check.runCheck
        && check.backupPrepareCommand == null
        && check.backupCleanupCommand == null
        && check.checkOpts == (if suffix == "full" then [ "--read-data" ] else [ ])
        && lib.hasInfix " check " (command cfg "${name}-${suffix}")
        && lib.hasPrefix (lib.getExe job.package) (command cfg "${name}-${suffix}")
        && builtins.hasContext (command cfg "${name}-${suffix}")
      ) suffixes
    ) names
    &&
      lib.all
        (
          name:
          let
            unit = service cfg name;
          in
          unit.serviceConfig.EnvironmentFile == "/run/backup-secrets/fixture-backend-env"
          && unit.environment.RCLONE_CONFIG == "/run/backup-secrets/fixture-rclone-config"
          && unit.environment.RCLONE_TRANSFERS == "2"
          && lib.hasInfix "s3.region=fixture-region" (command cfg name)
        )
        [
          "vaultwarden-a"
          "vaultwarden-a-structure"
          "vaultwarden-a-full"
        ];
  observedContracts =
    name:
    let
      app = if lib.hasPrefix "vaultwarden-" name then "vaultwarden" else "livesync";
      destination = lib.last (lib.splitString "-" name);
      format = if app == "vaultwarden" then "vaultwarden-pg18-files-v1" else "livesync-couchdb3-v1";
      unit = service observed name;
      job = backup observed name;
      prepareParts = lib.splitString "backupPrepareCommand" unit.preStart;
      unitText = observed.systemd.units."restic-backups-${name}.service".text;
      starts = lib.filter (line: lib.hasPrefix "ExecStart=" line) (lib.splitString "\n" unitText);
    in
    job.extraBackupArgs == [ invocationTag ]
    && lib.hasInfix invocationTag (command observed name)
    && builtins.length starts == 1
    && lib.hasInfix invocationTag (builtins.head starts)
    && !(lib.hasInfix "--tag=reliability-invocation:$$" (builtins.head starts))
    && unit.serviceConfig.SuccessExitStatus == [ ]
    && builtins.length prepareParts == 2
    && lib.hasInfix (lib.escapeShellArgs [
      "start"
      app
      destination
      metrics
    ]) (builtins.head prepareParts)
    && lib.hasInfix (lib.escapeShellArgs [
      "observe"
      app
      destination
      format
      "86400"
      (input name)
      metrics
    ]) unit.postStart
    && contains "${
      import ../packages/capture-observation.nix {
        pkgs = import apps.inputs.apps-nixpkgs { system = "x86_64-linux"; };
        restic = job.package;
      }
    }/bin/restic-capture-observe" unit.postStart
    && !(lib.hasInfix "RESTIC_OBSERVER_RESTIC" unit.postStart)
    && lib.hasInfix ''"$INVOCATION_ID"'' unit.postStart
    && builtins.hasContext unit.postStart;
  report = {
    acceptance = "evaluated public Apps composition and native NixOS services; no capture, upload or semantic restore executed";
    machinePlatform = baseline.nixpkgs.hostPlatform.system;
    fullClanConfigurations = 2;
    jobs = names;
    checks = checkNames;
    baseline = {
      observation = false;
      readerMaxAgeSeconds = 86400;
    };
    observed = {
      admissionMaxAgeSeconds = 64800;
      arrivalMaxAgeSeconds = 86400;
      packageOverride = true;
    };
    custom = {
      admissionMaxAgeSeconds = 43200;
      arrivalMaxAgeSeconds = 64800;
      metricsDirectory = "/var/lib/fixture-metrics";
    };
    nativeHooksAndCommandContexts = true;
    backendAndPackagePropagation = true;
    unsafeParameterCasesRejected = true;
    readerOwnershipFilesystemProcesses = true;
  };
in
assert nativeContracts 86400 baseline;
assert nativeContracts 64800 observed;
assert knownContexts hookJob.backupPrepareCommand;
assert knownContexts hookJob.backupCleanupCommand;
assert lib.all (
  name:
  let
    job = backup baseline name;
    unit = service baseline name;
  in
  job.extraBackupArgs == [ ]
  && !(lib.hasInfix "restic-capture-observe" unit.preStart)
  && !(lib.hasInfix "restic-capture-observe" unit.postStart)
) names;
assert !builtins.elem "d ${metrics} 0755 root root - -" baseline.systemd.tmpfiles.rules;
assert lib.all observedContracts names;
assert (backup observed "vaultwarden-a").package.pname == "fixture-restic";
assert lib.hasInfix (lib.escapeShellArgs [
  "--option"
  "s3.region=fixture-region"
  "--option"
  "s3.connections=2"
]) (service observed "vaultwarden-a").postStart;
assert builtins.elem "d ${metrics} 0755 root root - -" observed.systemd.tmpfiles.rules;
assert !observed.services.prometheus.exporters.node.enable;
assert valid { };
assert valid { observe = true; };
assert valid {
  observe = true;
  admissionMaxAgeSeconds = 43200;
  arrivalMaxAgeSeconds = 64800;
};
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
assert valid customSettings;
assert lib.hasInfix "prepare-reader --max-age ${lib.escapeShellArg "43200"}" customPrepare;
assert lib.hasInfix (lib.escapeShellArgs [
  "observe"
  "vaultwarden"
  "a"
  "vaultwarden-pg18-files-v1"
  "64800"
  (input "vaultwarden-a")
  "/var/lib/fixture-metrics"
]) customUnit.postStart;
assert lib.hasInfix (lib.escapeShellArgs [
  "start"
  "vaultwarden"
  "a"
  "/var/lib/fixture-metrics"
]) customUnit.preStart.content;
assert builtins.elem "d /var/lib/fixture-metrics 0755 root root - -" custom.systemd.tmpfiles.rules;
assert valid { admissionMaxAgeSeconds = 3600; };
assert lib.hasInfix "prepare-reader --max-age ${lib.escapeShellArg "3600"}" customBaselinePrepare;
assert !(valid { admissionMaxAgeSeconds = 0; });
assert invalid { arrivalMaxAgeSeconds = "86400"; };
assert invalid { metricsDirectory = 1; };
assert invalid { metricsDirectory = "relative/metrics"; };
pkgs.runCommand "reliability-apps-composition"
  {
    report = builtins.toJSON report;
    prepareHook = renderHook hookJob.backupPrepareCommand;
    terminationPrepareHook =
      builtins.replaceStrings [ "${pkgs.coreutils}/bin/mkdir" ] [ ''"$mkdirTerminator"'' ]
        (renderHook hookJob.backupPrepareCommand);
    cleanupHook = renderHook hookJob.backupCleanupCommand;
    passAsFile = [
      "report"
      "prepareHook"
      "terminationPrepareHook"
      "cleanupHook"
    ];
    nativeBuildInputs = [ pkgs.coreutils ];
  }
  ''
    export LC_ALL=C
    test "$(id -u)" -ne 0
    work="$TMPDIR/reliability-reader-hooks"
    export reader="$work/reader" runtime="$work/runtime"
    export fixtureProducer="$work/fixture-producer"
    current=11111111111111111111111111111111
    older=22222222222222222222222222222222
    export INVOCATION_ID="$current"
    prepare() { ${pkgs.runtimeShell} "$prepareHookPath"; }
    cleanup() { ${pkgs.runtimeShell} "$cleanupHookPath"; }
    fail_expected() {
      if "$@" > "$work/expected-error.log" 2>&1; then
        printf 'Expected hook failure: %s\n' "$*" >&2
        exit 1
      fi
    }
    reset_fixture() {
      if test -d "$work"; then chmod -R u+rwx "$work"; fi
      rm -rf -- "$work"
      mkdir -p "$runtime"
      export INVOCATION_ID="$current" FIXTURE_FAIL=0
      cat > "$fixtureProducer" <<'PRODUCER'
    #!${pkgs.runtimeShell}
    set -euo pipefail
    test "$1" = --max-age
    test "$2" = 86400
    printf 'fixture payload\n' > "$3/payload"
    if test "$FIXTURE_FAIL" = 1; then exit 7; fi
    PRODUCER
      chmod 700 "$fixtureProducer"
    }
    owned_claim="$runtime/reader-owned-$current"
    reset_fixture
    mkdir "$reader"
    printf 'foreign payload\n' > "$reader/payload"
    fail_expected prepare
    fail_expected cleanup
    test "$(cat "$reader/payload")" = 'foreign payload'
    test ! -e "$owned_claim"
    printf 'PASS foreign reader refused and preserved\n'

    reset_fixture
    ln -s "$work/missing-target" "$reader"
    fail_expected prepare
    fail_expected cleanup
    test -L "$reader"
    test "$(readlink "$reader")" = "$work/missing-target"
    printf 'PASS dangling foreign reader refused and preserved\n'

    reset_fixture
    prepare
    test -f "$owned_claim" && test ! -L "$owned_claim"
    test "$(stat -c %a "$owned_claim")" = 600
    test "$(stat -c %a "$reader")" = 700
    test "$(cat "$reader/payload")" = 'fixture payload'
    cleanup
    test ! -e "$reader" && test ! -e "$owned_claim"
    printf 'PASS owned successful reader removed before claim\n'

    reset_fixture
    export FIXTURE_FAIL=1
    fail_expected prepare
    test -f "$owned_claim" && test -f "$reader/payload"
    cleanup
    test ! -e "$reader" && test ! -e "$owned_claim"
    printf 'PASS owned partial producer failure cleaned\n'

    reset_fixture
    prepare
    rm "$owned_claim"
    fail_expected cleanup
    test -f "$reader/payload"
    printf 'PASS missing claim preserves reader\n'

    reset_fixture
    prepare
    export INVOCATION_ID="$older"
    fail_expected cleanup
    fail_expected prepare
    test -f "$reader/payload" && test -f "$owned_claim"
    test ! -e "$runtime/reader-owned-$older"
    printf 'PASS another invocation cannot own old reader\n'

    reset_fixture
    prepare
    mv "$owned_claim" "$work/real-claim"
    ln -s "$work/real-claim" "$owned_claim"
    fail_expected cleanup
    test -f "$reader/payload" && test -L "$owned_claim"
    printf 'PASS symlink claim rejected\n'

    reset_fixture
    export INVOCATION_ID=invalid
    fail_expected prepare
    test ! -e "$reader"
    mkdir "$reader"
    fail_expected cleanup
    test -d "$reader"
    printf 'PASS invalid invocation fails before mutation\n'

    reset_fixture
    rmdir "$runtime"
    fail_expected prepare
    test -d "$reader" && test ! -e "$reader/payload"
    fail_expected cleanup
    test -d "$reader"
    printf 'PASS claim creation failure preserves unclaimed reader\n'

    reset_fixture
    export mkdirTerminator="$work/mkdir-terminate-parent"
    cat > "$mkdirTerminator" <<'TERMINATOR'
    #!${pkgs.runtimeShell}
    set -euo pipefail
    ${pkgs.coreutils}/bin/mkdir "$@"
    # Send TERM before returning to claim creation, then terminate this helper.
    # Descendant lifetime/reaping belongs to the system-manager acceptance gate.
    kill -TERM "$PPID"
    kill -TERM "$$"
    TERMINATOR
    chmod 700 "$mkdirTerminator"
    terminationStatus=0
    ${pkgs.runtimeShell} "$terminationPrepareHookPath" > "$work/expected-error.log" 2>&1 || terminationStatus=$?
    test "$terminationStatus" -eq 143
    test -d "$reader" && test ! -e "$owned_claim"
    test ! -e "$reader/payload"
    fail_expected cleanup
    test -d "$reader" && test ! -e "$owned_claim"
    export INVOCATION_ID="$older"
    fail_expected prepare
    fail_expected cleanup
    test -d "$reader" && test ! -e "$owned_claim"
    test ! -e "$runtime/reader-owned-$older"
    printf 'PASS TERM before ownership evidence preserves reader and blocks next invocation\n'

    reset_fixture
    prepare
    chmod 500 "$reader"
    fail_expected cleanup
    case "$(cat "$work/expected-error.log")" in
      *'Permission denied'*) ;;
      *) printf 'Expected a real permission failure\n' >&2; exit 1 ;;
    esac
    test -f "$reader/payload" && test -f "$owned_claim"
    export INVOCATION_ID="$older"
    fail_expected prepare
    fail_expected cleanup
    test -f "$reader/payload" && test -f "$owned_claim"
    test ! -e "$runtime/reader-owned-$older"
    printf 'PASS real removal failure blocks next invocation and preserves old claim\n'

    reset_fixture
    export INVOCATION_ID=invalid
    cleanup
    printf 'PASS absent reader cleanup is harmless\n'
    mkdir -p "$out"
    cp "$reportPath" "$out/report.json"
  ''
