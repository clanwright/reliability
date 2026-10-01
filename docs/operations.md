# Operations

The [generic example](../examples/restic.nix) configures two independent
repositories over prepared files under `/srv/backup-input`, with separate
structural and full-data checks. Prepare consistent application exports first;
ordinary file copying of a live database does not establish recovery.
The [README](../README.md#inputs-and-acceptance) identifies the authoritative test
cohort and acceptance limits.

## Importing the Apps composition

Import the Reliability repository path, including its relative package files,
rather than copying only the example. The consumer supplies its Apps module
and enables both export selections. The composition reads public
`system.build.appsVaultwardenExport` and `system.build.appsLiveSyncExport`;
it takes no `apps` argument and imports no Apps example.

The following expression shows consumer Clan wiring with `apps` and
`reliability` inputs. Select a producer exposing the public export contract;
consumer adoption and activation remain separate actions. All installation
values below are fake placeholders:

```nix
{ inputs, directory }:
let apps = inputs.apps;
in apps.inputs.clan-core.lib.clan {
  self = {
    inputs = apps.inputs // {
      inherit apps;
      nixpkgs = apps.inputs.apps-nixpkgs;
    };
    outPath = directory;
  };
  inherit directory;
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
    obsidian = { domain = "notes.example.invalid"; export.enable = true; };
    vaultwarden = { domain = "vault.example.invalid"; export.enable = true; };
  };
  machines.fixture = {
    imports = [
      (import (inputs.reliability + "/examples/apps-restic.nix") {
        observe = true;
        admissionMaxAgeSeconds = 64800;
        arrivalMaxAgeSeconds = 86400;
        metricsDirectory = "/var/lib/prometheus-node-exporter-text-files";
      })
    ];
    nixpkgs.hostPlatform = "x86_64-linux";
    system.stateVersion = "25.11";
    sops.age.keyFile = "/var/lib/fixture-sops/age-key.txt";
    security.acme.certs."notes.example.invalid".webroot = "/var/lib/acme/acme-challenge";
    security.acme.certs."vault.example.invalid".webroot = "/var/lib/acme/acme-challenge";
    # Configure four repository/password paths and runtime backend credentials.
  };
}
```

Every active physical certificate also needs an explicit consumer-selected
native ACME challenge in `security.acme.certs.<certificateId>`: choose exactly
one of `webroot`, `dnsProvider`, `listenHTTP` or `s3Bucket`. Apps supplies no
implicit challenge. The local fixture selects webroot for its two fake
certificates. HTTP routing
and actual issuance require separately authorized consumer verification;
local composition checks realize neither.

Enable `clanwright.apps.machines.<machine>.obsidian.export.enable` and
`clanwright.apps.machines.<machine>.vaultwarden.export.enable` in the existing
Apps configuration. Both exports are required. Application enablement alone
starts neither export jobs nor backup timers. Configure each destination's
repository and protected runtime credential paths, and schedule captures
separately from delivery. The four backup jobs and eight check jobs are manual
by default, with initialization, pruning and direct wrappers disabled.

Omit constructor arguments for the baseline (`observe = false`, admission
86400 seconds). With observation enabled, admission defaults to 64800 seconds;
arrival defaults to 86400 seconds. Admission must be positive and no greater
than 86400; arrival must be positive and at least admission. Preparation calls
Apps `prepare-reader` once with the selected age. Baseline and observed
compositions retain independent schedules and consumer overrides.
Preserve configured destinations, credentials, schedules and retained trusted
validator closures, then evaluate before separately authorized activation.

## Local checks and executable outputs

The default package/app runs pinned Restic. The observer package exposes
`restic-capture-observe`; the composition builds it against each backup's final
Restic package. It has no runtime executable fallback. To inspect the packages
and run the host's local checks:

```sh
nix run --no-write-lock-file . -- version
nix build --no-write-lock-file --no-link .#capture-observation
nix run --no-write-lock-file .#local-ci
```

Local verification includes Nix formatting and canonical Linux configuration
evaluation from
Darwin, the actual baseline/observed Apps composition, temporary real Restic
repositories and Prometheus exposition/rule checks. Save readable output and
whole/stage durations under ignored `.work`. On an approved native ARM Linux
builder, select the same relevant checks explicitly:

```sh
nix build --no-write-lock-file --no-link \
  .#checks.aarch64-linux.module-eval \
  .#checks.aarch64-linux.apps-composition \
  .#checks.aarch64-linux.capture-observation \
  .#checks.aarch64-linux.capture-alerts
```

Use `x86_64-linux` names on a native x86 builder. These commands do not activate
services or operate real destinations. No hosted CI or VM/QEMU test is used.
An explicitly approved ephemeral Apps override must use `--no-write-lock-file`
and be recorded with its exact revision; its result does not change or certify
the committed dependency combination.

Local verification does not certify native manager execution, same-host
semantic validation or ACME routing/issuance. Required unobserved runtime
cases are centralized in the [PREDEPLOY matrix](#required-predeployment-proof).
Use the committed [flake.lock](../flake.lock) for the authoritative test cohort;
an ephemeral override does not qualify another dependency combination.

The generic example may be imported as a standalone NixOS module and provides
native `restic-primary` inspection wrappers. The Apps composition disables
wrappers so backup input preparation stays inside the native service lifecycle.

## Captures, readers and delivery

The following templates are for separately authorized installations or
disposable recovery environments. Capture each application independently:

```sh
sudo systemctl start apps-export-vaultwarden.service
sudo systemctl start apps-export-livesync.service
```

After complete captures are available, start the four native backup services
only with backup-writer authorization and provisioned repositories:

```sh
sudo systemctl start restic-backups-vaultwarden-a.service
sudo systemctl start restic-backups-vaultwarden-b.service
sudo systemctl start restic-backups-livesync-a.service
sudo systemctl start restic-backups-livesync-b.service
```

Each job prepares an independent reader under its root-owned `0700`
disk-backed cache directory. `apps-input` and `cache` are siblings. Native
start/stop timeouts are two hours/two minutes; cleanup follows process
teardown. Do not read the publisher's `current` pointer or remove a reader
while any Restic process still uses it.

Preparation claims a newly created input with a small current-invocation flag
in the existing native Restic `RuntimeDirectory`. Full readers stay on disk.
Cleanup requires that regular, non-symlink flag and removes it only after
reader deletion succeeds. A foreign, unclaimed or leftover input is preserved
and the operation fails; the next attempt refuses it. Interruption before
claim creation or a cleanup error can require operator review. Establish
ownership and confirmed process termination before any separately authorized
cleanup; do not automatically adopt or delete such a leftover.

For a disposable reader test, choose the retained matching `EXPORT_PACKAGE`
and an absolute, existing empty root-owned `0700` `READER_DIRECTORY`:

```sh
sudo "$EXPORT_PACKAGE/bin/prepare-reader" --max-age 86400 "$READER_DIRECTORY"
```

Use 64800 instead for observed-default admission. Preparation checks original
capture-start age before and after copying. Failed preparation can leave
partial files; do not use them. A failed capture can leave the last good
capture admissible only within its original age budget. Neither admission
nor a timeout guarantees arrival through a slow destination or outage.
Record capture IDs/times, invocation exit status, immutable snapshot ID and
upload completion independently for each destination.

Exit 3 can retain a partial snapshot with readable metadata and a passing
repository check. Only exit 0 reaches the observation success hook. The
observer requires exactly one snapshot matching the invocation tag and exact
input path, dumps its `export.json`, and checks schema, app/format, ordered
capture times and arrival age from original capture start. Selecting `latest`
or re-uploading an old capture cannot establish successful fresh delivery.
Cleanup and failure hooks are not success signals.

## Off-host monitoring

Observation creates the administrator-controlled metrics directory; it does
not enable node exporter or configure Prometheus. Integrate the collector in
the consumer's exporter configuration and scrape it from an independent host:

```nix
services.prometheus.exporters.node = {
  enable = true;
  enabledCollectors = [ "textfile" ];
  extraFlags = [
    "--collector.textfile.directory=/var/lib/prometheus-node-exporter-text-files"
  ];
};
```

Use the same directory as the composition. Configure approved network access,
matching scrape labels and independent alert delivery. Import the public
[capture alert group](../examples/capture-alerts.nix) from the repository path:

```nix
{ inputs, pkgs, ... }:
let
  captureRules = import (inputs.reliability + "/examples/capture-alerts.nix") {
    job = "reliability";
    instance = "fixture.invalid:9100";
    warningAgeSeconds = 64800;
    criticalAgeSeconds = 86400;
    observationMaxAgeSeconds = 14400;
    attemptGracePeriod = "2h5m";
  };
in {
  services.prometheus.ruleFiles = [
    (pkgs.writeText "capture-alerts.json" (builtins.toJSON {
      groups = [ captureRules ];
    }))
  ];
}
```

Replace the fake instance with the consumer's scrape identity. Observation age
must match the delivery schedule: the rule default is 900 seconds, while the
four-hour example also needs a compatible schedule. Target/missing-series
alerts have five-minute grace. The failed-attempt rule uses elapsed time since
the latest pending status event, with default grace `2h5m`; each new retry
resets that event's grace intentionally. Keep the Prometheus duration syntax.
Capture warning/critical defaults are 64800/86400 seconds.

| Metric (labels `app`, `destination`) | Meaning |
| --- | --- |
| `reliability_capture_attempt_success` | 0 before preparation; 1 after successful observation and final status publication |
| `reliability_capture_attempt_seconds` | Timestamp of the latest status event, pending or complete |
| `reliability_capture_started_seconds` | Original capture start from verified repository metadata |
| `reliability_capture_completed_seconds` | Capture completion from that metadata |
| `reliability_capture_observation_seconds` | Successful metadata observation time |
| `reliability_capture_snapshot_info` | Value 1 with immutable `snapshot_id` and `capture_id` labels |

The observer exposes `start APP DESTINATION METRICS_DIRECTORY` and
`observe APP DESTINATION FORMAT MAX_AGE INPUT METRICS_DIRECTORY INVOCATION
[RESTIC_OPTIONS...]`. Invoke them through the composed native hooks: `start`
fails closed before preparation, and `observe` relies on successful backup
provenance. The observer supplies neither a backup runner nor semantic validation.

Pending status marks preparation, not actual Restic start. `observe` does not
reset pending status/time on entry. Failures preserve prior successful
metadata; before the first success those series are absent. Metadata and final
status writes are separate: verified metadata may be published before a final
status failure, while the latest attempt stays 0 and the native unit fails.
Treat that attempt as uncertified. Successful completion writes 1 and its
completion-event time. Observation does not detect later repository loss
without another repository operation. Verify target-loss and alert delivery
independently during commissioning.

## Retained trusted validation closures

Before disabling, removing or upgrading an application, retain its matching
export/validator package. Set the installable variables to the pinned
consumer's `config.system.build.appsVaultwardenExport` and
`config.system.build.appsLiveSyncExport`. Persistent output links in a separate
recovery environment protect their full closures from garbage collection:

```sh
mkdir -p "$RECOVERY_ROOT"
nix build --out-link "$RECOVERY_ROOT/vaultwarden" "$VAULTWARDEN_EXPORT_INSTALLABLE"
nix build --out-link "$RECOVERY_ROOT/livesync" "$LIVESYNC_EXPORT_INSTALLABLE"
```

Use an absolute persistent `RECOVERY_ROOT` outside temporary test storage.
Keep links and pinned configuration for all retained formats. Restored
`validatorStorePath` is provenance, not an executable selector or GC root.
After independently restoring each pair to disposable root-owned storage,
use the matching retained trusted package:

```sh
sudo "$RECOVERY_ROOT/vaultwarden/bin/validate" "$VAULTWARDEN_RESTORED_ARTIFACT"
sudo "$RECOVERY_ROOT/livesync/bin/validate" "$LIVESYNC_RESTORED_ARTIFACT"
```

Follow the public Apps recovery/isolation procedure for that exact retained
release. Do not apply a later same-host procedure to an unqualified older
input. Use a disposable native Linux environment meeting the owner's
systemd/cgroup prerequisites. Restored trees and parents must be
administrator-controlled and quiescent, without nested mounts or unsafe
links/special files. Semantic failure, timeout or cancellation retain the
reported root-only scratch and logs. After the wrapper explicitly confirms
teardown, an administrator may remove that exact scratch without reboot.
Unconfirmed handoff/teardown retains scratch and the admission barrier; follow
the matching Apps manual-recovery procedure, without automatic retry or
removal. Reboot is not normal cleanup. Never validate production directories.

## Required predeployment proof

The following actual manager and same-host cases are **not observed and required
before deployment**. They are not covered by local source, build, rendered-hook
or ordinary process checks. Collect one shared evidence set for the exact
producer revisions and consumer composition. Apps owns application capture
and semantic proof; Primitives owns generic database-helper proof. Reliability
reuses their evidence without duplicating either suite. This matrix does
not authorize deployment, service execution, new infrastructure or privilege
changes. Local verification uses the existing native builder; do not create a
privileged runner, VM/test host or credential/privilege/isolation workaround
to fill these cases. Their absence does not block source delivery.

| Owner | Required actual-runtime cases | Required boundary evidence |
| --- | --- | --- |
| Consumer | Per-certificate native ACME challenge routing and issuance | Each active physical certificate has its selected challenge and successful routing/issuance evidence; pure composition does not prove certificate delivery |
| Reliability | Successful and failed preparation; upload error and exit 3; cancellation during preparation/upload and `postStart` | Native unit result, exact invocation/snapshot provenance and pending/success status; unsuccessful or cancelled attempts are not certified |
| Reliability | Stop, timeout, TERM/KILL and surviving descendants | All reader processes and descendants stop **before** disk-backed reader deletion; cleanup order is observed through the actual manager |
| Reliability | Small ownership-flag `RuntimeDirectory` lifetime | Root ownership/mode, current invocation ID, flag creation/removal and manager directory teardown; no flag from another attempt grants deletion authority |
| Reliability | Cleanup error followed by next attempt; unclaimed/foreign leftovers; concurrent destinations a/b | Record failed deletion and retained input; the runtime flag may disappear during native teardown. The next attempt refuses leftovers, foreign input is preserved and each destination's reader remains independent |
| Apps | Effective database peer/identity, private file descriptors, database sockets and ports | Capture uses its explicit effective DB/socket/port and private output descriptor. Disposable validation is confined to its isolated database, without production access or unintended descriptors |
| Apps | Initially active and inactive applications; quiescence and resumption | Prior activity is recorded before any app mutation; failure before that record grants no restoration/cleanup authority. Writer quiescence covers capture and automatic activation paths, original activity is restored and inactive applications are not accidentally started |
| Apps | Capture commit/current-pointer publication and reader acquisition overlapping publication/next prepare/reclamation; bounded two-producer overlap | Precommit failure preserves the prior complete export; completed atomic commit keeps the new complete export selected after late unit/status failure. Pointer-aware finalization never deletes selected data. Source reclamation follows completed independent reader acquisition; no third producer-sized payload, including temporary producer workspace, is allocated before successful reclaim |
| Apps | Full-attempt admission, retained trusted same-host validation confinement/resource limits, TERM/KILL, uncertain teardown and representative application continuity | Admission spans the full attempt; actual confinement and resource bounds apply to retained validation. Representative app behavior remains usable after successful, failed or cancelled validation; uncertain teardown preserves the admission barrier/scratch and prevents unsafe retry or unconfirmed continuation |

The two-producer bound covers producer payload trees, not total host storage.
Budget independent reader copies, wrapper/validator scratch and filesystem
overhead separately.

Retain exact revisions, rendered configuration, logs, whole/stage durations,
capture/invocation/snapshot IDs, process-stop and cleanup ordering, validation
results and explicit `pass`, `fail` or `unknown` outcomes. Unexecuted or
uncertain cases remain open predeployment requirements. Reuse unchanged
passing local evidence without relabeling it runtime acceptance.

## Commissioning and four independent monthly drills

Review stable sources and valuable exclusions first. Provision repositories
and runtime credentials separately; initialization remains an explicit
operator action. Evaluate before authorizing activation. Record successful,
failed and interrupted captures, prior stopped-service behavior, replacement
while readers are active, independent destination failure/retry and freshness
rejection. Preserve configuration/revisions, whole/stage durations, logs,
capture and snapshot identities and trusted closure provenance without secrets.

Run structural and full-data checks independently for each backup job. Check
services use suffixes `-structure` and `-full`, for example:

```sh
sudo systemctl start restic-backups-vaultwarden-a-structure.service
sudo systemctl start restic-backups-vaultwarden-a-full.service
```

Repeat for `vaultwarden-b`, `livesync-a` and `livesync-b`. For manual inspection
of an operator-approved repository, set `RESTIC_REPOSITORY`, a protected
`RESTIC_PASSWORD_FILE` and the approved backend environment. Use the matching
pinned Restic; these commands are not production actions run by local checks:

```sh
restic snapshots
restic check
restic check --read-data
restic ls "$SNAPSHOT_ID"
restic cat snapshot "$SNAPSHOT_ID"
restic dump "$SNAPSHOT_ID" "$SNAPSHOT_EXPORT_PATH"
sudo install -d -m 0700 "$RESTORE_ROOT"
sudo restic restore "$SNAPSHOT_ID" --target "$RESTORE_ROOT"
```

Select an immutable snapshot with retained exact exit-0 invocation evidence.
With observation, retain its successful observation and invocation provenance;
select the recorded `snapshot_id`, not `latest`. Inspect its exact metadata
path and set `SNAPSHOT_EXPORT_PATH`. Use a fresh absolute disposable root-owned
`RESTORE_ROOT` and the approved root Restic environment. Never overwrite
production or an earlier drill. Structural/full-data checks do not replace
application validation.

Perform a separately authorized monthly restore and semantic drill for each
pair, using the retained trusted closure and owner isolation procedure:

| Pair | Status | Snapshot ID | Capture ID | Capture/upload/drill times | Trusted closure | Logs/scratch |
| --- | --- | --- | --- | --- | --- | --- |
| Vaultwarden / a | pending | — | — | — | — | — |
| Vaultwarden / b | pending | — | — | — | — | — |
| LiveSync / a | pending | — | — | — | — | — |
| LiveSync / b | pending | — | — | — | — | — |

Record repository identity, invocation exit provenance, restored capture
start/completion, upload completion, drill start/end/duration, restore/check/
validation results, pinned configuration and scratch teardown outcome. Replace
rows only with evidence from that month's drill. Use `pass`, `fail` or
`unknown`; uncertain selection, validation or teardown does not satisfy
acceptance. Preserve failed/uncertain scratch. A pass for one pair covers
neither another pair nor monitoring acceptance.

## Retained recovery points and retention

Changing this composition does not convert, delete or certify snapshots.
Preserve historical repositories, credentials, configuration and compatible
pinned Restic/validation closures. Inspect and restore historical recovery
points before retiring an older recovery path. Preserve state and closure
roots before disabling exports or removing a selection; retained historical
formats need their matching application/database versions. Test database-major
migrations separately and never relabel old artifacts.

No automatic forget/prune policy is configured. Inspect each repository and
snapshot grouping before reviewing a proposed policy with a dry run:

```sh
restic snapshots
restic forget --dry-run --keep-daily 7 --keep-weekly 4 --keep-monthly 12
```

This previews a possible policy. Real forget/prune needs separate approval
after destination-specific recovery evidence. Provider version-history
lifecycle is a separate decision; see [security](security.md). Documentation
authorizes no initialization, deletion, production restore, deployment,
provider, credential or secret mutation.
