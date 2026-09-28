# Operations

The [generic NixOS example](../examples/restic.nix) configures two independent
`services.restic.backups` entries over `/srv/backup-input`, with separate
structural and full-data checks. Prepare stable application exports there
through an approved application integration before running a backup. The
example does not wire native Clan state hooks automatically. Do not point it
at a live database directory and assume file copying is consistent.

The [Apps composition](../examples/apps-restic.nix) instead imports the public
Apps v0.4.0 native example directly and adds separate repository check jobs.
It has no timers or direct Restic wrappers. Import it from the installation's
flake scope with the pinned `apps` input:

```nix
imports = [ (import ./examples/apps-restic.nix { inherit apps; }) ];
```

For stricter capture admission and success-only destination observation, opt
into [the observed composition](../examples/apps-observed-restic.nix) instead:

```nix
imports = [
  (import ./examples/apps-observed-restic.nix {
    inherit apps;
    admissionMaxAgeSeconds = 64800;
    arrivalMaxAgeSeconds = 86400;
    metricsDirectory = "/var/lib/prometheus-node-exporter-text-files";
  })
];
```

When migrating from the v0.3 baseline, replace its example import with this
import; it already imports the baseline composition. Preserve the pinned Apps
input, enabled exports, destination configuration, runtime credentials,
schedules and retained validator closures. Evaluate before separately
authorized activation. No snapshots are converted, deleted or newly certified
by changing the import. Capture schedules remain separate from backup schedules.
Admission must be a positive integer no greater than 86400; arrival must be
positive and at least admission. The defaults are 18 hours and 24 hours.
The native reader hook still runs first; the additional check rejects an old
prepared copy without replacing or text-patching preparation or cleanup.

Adapt destinations and runtime credential paths before activation. The Apps
example requires both active selections:
`clanwright.apps.machines.<machine>.obsidian.export.enable = true` and
`clanwright.apps.machines.<machine>.vaultwarden.export.enable = true`.
It composes all four backup jobs; single-app use is not claimed by this example.
Application enablement alone does not run an export or enable backup timers.
The consumer must schedule
captures separately from delivery. A failed export may leave the last good
capture available only within its original admission-age limit.

The flake pins nixpkgs for its Restic package and local checks. The default
package and app run Restic directly. To confirm the pinned executable and run
the checks for this host:

```sh
nix run --no-write-lock-file . -- version
nix run --no-write-lock-file .#local-ci
```

On macOS, `local-ci` runs Darwin checks including `apps-composition`, which
evaluates the actual x86 Clan application configuration without executing its
services. The generic Linux `module-eval` derivation remains Linux-only.
Additional Linux checks can be selected on an approved native ARM builder:

```sh
nix build --no-write-lock-file --no-link .#checks.aarch64-linux.module-eval .#checks.aarch64-linux.runtime-integration
nix build --no-write-lock-file --no-link .#checks.aarch64-linux.apps-composition
nix build --no-write-lock-file --no-link .#checks.aarch64-linux.apps-observed-composition .#checks.aarch64-linux.capture-observation .#checks.aarch64-linux.capture-alerts
nix build --no-write-lock-file --no-link github:clanwright/apps/af0d564cc388aa21e71e0efa4a622d3d11396ea5#checks.aarch64-linux.recovery-runtime
```

Use the corresponding local `x86_64-linux` check names on a native x86 Linux
host; choose the upstream runtime suite that matches the builder's native
architecture.
Local checks use fake data and temporary Restic repositories; they do not run
production backups or commission real destinations. `apps-composition`
evaluates actual x86 Clan application configuration; its ARM check derivation
does not run x86 application services. The Apps `recovery-runtime` command is
an explicitly attributed upstream native ARM suite, not Reliability's own
test. No virtual machine or QEMU test is run by this repository; existing
released upstream outputs may be inspected and cited as evidence.

Adapt and import the example into the installation's NixOS configuration. For
example, after copying it there as `restic.nix`:

```nix
{ ... }: {
  imports = [ ./restic.nix ];
}
```

The generic example creates the standard `restic-backups-primary.service` and
`restic-backups-secondary.service` backup units, with separate check units.
On an activated NixOS host, the upstream module's `restic-primary` wrapper
supplies the configured repository and credential paths for manual Restic
inspection, such as `restic-primary snapshots`. Its existence does not imply
that a backup has run. The [NixOS Restic module](https://github.com/NixOS/nixpkgs/blob/master/nixos/modules/services/backup/restic.nix)
defines these units and wrappers. The Apps example disables wrappers: start its
backup jobs through systemd so reader preparation and cleanup remain in the
native service lifecycle.

## Apps readers and validation

The following are manual templates for a separately authorized installation
or disposable recovery environment; no service is started by reading these
instructions. Capture both applications independently of destination jobs:

```sh
sudo systemctl start apps-export-vaultwarden.service
sudo systemctl start apps-export-livesync.service
```

After captures have completed, the four native delivery services are manually
callable as follows; each service performs freshness admission in its own
reader-preparation hook. This is a separate
backup-writer action requiring authorization and provisioned repositories:

```sh
sudo systemctl start restic-backups-vaultwarden-a.service
sudo systemctl start restic-backups-vaultwarden-b.service
sudo systemctl start restic-backups-livesync-a.service
sudo systemctl start restic-backups-livesync-b.service
```

The matched native backup services use the released `prepare-reader` command.
For a disposable manual reader test, set `EXPORT_PACKAGE` to the retained
Vaultwarden or LiveSync export package, and supply an absolute, existing empty
root-owned `0700` `READER_DIRECTORY`:

```sh
sudo "$EXPORT_PACKAGE/bin/prepare-reader" --max-age 86400 "$READER_DIRECTORY"
```

Use only a successfully prepared reader as input. Do not back up the publisher
root or `current` pointer. Failed preparation can leave partial files; the
owning job removes its reader only after process teardown. Keep its cache in a
sibling directory outside the input. Capture age is checked before and after
copying, conservatively from `captureStartedAt`, not capture completion or
upload time. The `86400`-second admission limit and native service's `2h`
start timeout do not promise arrival within 24 hours of capture start at a
slow destination. A stricter delivery-age policy needs a supported
admission budget and a destination completion check, supplied by the optional
observed example above. Its success observation rejects arrival older than the
configured budget; it cannot guarantee timely delivery through an outage.
Record `export.json` capture ID and capture times alongside each destination's
snapshot ID and upload completion time.

Treat backup completion separately from repository integrity. Restic 0.19.1
[documents exit code 3](https://github.com/restic/restic/blob/v0.19.1/doc/075_scripting.rst)
when a backup cannot read some source data. Such a backup can retain a snapshot
with readable `export.json` while `restic check` passes. The
[snapshot format](https://github.com/restic/restic/blob/v0.19.1/internal/data/snapshot.go)
has no completeness or backup-error flag. Reading metadata from `latest`, or
checking that snapshot's repository, therefore cannot prove complete delivery.
Retain the backup invocation's exact exit status and its association with the
immutable snapshot ID; missing or uncertain provenance stays unknown and must
not be accepted as success.

The observed example adds a success-only `ExecStartPost` hook and enforces
exit-0 success rules; exit 3 cannot run the successful observation. Cleanup and
`postStop` run on failure too and are not success signals. The native backup
tags its snapshot with `reliability-invocation:${INVOCATION_ID}`. The observer
requires exactly one snapshot matching that invocation tag and input path,
then dumps that immutable snapshot's metadata. Schema 1, matching app/format,
valid capture times and arrival age must all pass before success is refreshed.
A success hook still does not independently verify all repository contents or
establish application recovery.

## Off-host capture monitoring

The observed example creates the configured administrator-controlled metrics
directory, but does not enable node exporter or configure Prometheus. Configure
the consumer's node-exporter textfile collector to read that directory, expose
it through the approved monitoring path, and scrape it from an independent
host. Keep alert delivery independent of the protected host. The expected pairs
are `vaultwarden/a`, `vaultwarden/b`, `livesync/a` and `livesync/b`.

On the protected NixOS host, integrate the textfile collector with the
installation's existing exporter configuration:

```nix
services.prometheus.exporters.node = {
  enable = true;
  enabledCollectors = [ "textfile" ];
  extraFlags = [
    "--collector.textfile.directory=/var/lib/prometheus-node-exporter-text-files"
  ];
};
```

Use the same directory as the observed composition. Configure exporter
reachability and its scrape access through the installation's approved network
policy. On the independent Prometheus host, load the
[capture alert group](../examples/capture-alerts.nix), choosing the actual
scrape labels and timing budgets:

```nix
{ pkgs, ... }:
let
  captureRules = import ./examples/capture-alerts.nix {
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

Copy the example into the consumer configuration scope before using that import.
The fake instance is a placeholder, not a reachable target. Configure the
matching scrape job and alert routing separately. The group covers an
unavailable target, missing required metrics for all four pairs, invalid or
future timestamps, overdue unsuccessful attempts, stale observations, and
capture-start age warning/critical thresholds. Target and missing-series
alerts have a five-minute grace. Set observation age for the actual delivery
schedule; the example's default 900 seconds is illustrative, and the four-hour
value above also needs a compatible schedule. The attempt grace must cover
the native two-hour upload timeout plus post-start observation time.

| Metric (labels `app`, `destination`) | Meaning |
| --- | --- |
| `reliability_capture_attempt_success` | 0 at attempt start; 1 only after successful destination observation |
| `reliability_capture_attempt_seconds` | Time of the latest attempt status publication |
| `reliability_capture_started_seconds` | Capture start from successfully observed repository metadata |
| `reliability_capture_completed_seconds` | Capture completion from that metadata |
| `reliability_capture_observation_seconds` | Time that destination metadata was successfully observed |
| `reliability_capture_snapshot_info` | Value 1 with additional `snapshot_id` and `capture_id` labels for the selected immutable snapshot |

A failed attempt leaves its status at 0 and retains the previous successful
capture/observation timestamps. Before the first success those success series
are absent. An active attempt also has status 0: this metric does not immediately
distinguish activity from failure. The alert reports an unsuccessful or
incomplete attempt only after its configured grace. Re-uploading an old capture
does not refresh its capture start.
The success-only observation reads the repository at backup completion; later
repository loss is not detected until another repository operation. Monitor
unsuccessful attempts, missing expected pairs, capture age from start, stale
observations, and off-host scrape `up`/absence separately from repository checks
and monthly semantic drills. Configure thresholds and expected scrape-target
labels for the installation and verify alert delivery during commissioning;
local metrics alone do not establish monitoring acceptance.

## Retained validation closures

Retain each matching command closure before disabling, removing, or upgrading
an application. Set the two installable variables to the pinned installation's
`config.system.build.appsVaultwardenExport` and
`config.system.build.appsLiveSyncExport` outputs. In a separate recovery
environment, these persistent output links protect the full closures from GC:

```sh
mkdir -p "$RECOVERY_ROOT"
nix build --out-link "$RECOVERY_ROOT/vaultwarden" "$VAULTWARDEN_EXPORT_INSTALLABLE"
nix build --out-link "$RECOVERY_ROOT/livesync" "$LIVESYNC_EXPORT_INSTALLABLE"
```

Keep these links and the pinned configuration for as long as their stored
formats remain in retention. Use an absolute persistent `RECOVERY_ROOT` outside
temporary test storage. `validatorStorePath` in restored metadata is
provenance only: do not select an executable from it or assume it roots a
closure. After restoring each of the four app/destination snapshots to a
disposable root-owned directory, use the retained matching package:

```sh
sudo "$RECOVERY_ROOT/vaultwarden/bin/validate" "$VAULTWARDEN_RESTORED_ARTIFACT"
sudo "$RECOVERY_ROOT/livesync/bin/validate" "$LIVESYNC_RESTORED_ARTIFACT"
```

Run validation as root on a disposable native Linux host with its local
systemd system manager, cgroup v2, and the same mount/cgroup namespaces. A
container merely connected to host D-Bus is unsupported. Restored trees and
parents must be administrator-controlled and quiescent, without nested mounts;
symlinks, hard-linked files, and special files are rejected. The wrapper owns
the unprivileged isolation handoff and leaves the source unchanged. On failure,
interruption, timeout, or uncertain teardown, retain its printed root-only
scratch directory and reboot that disposable host before manual removal.

## Acceptance evidence

The released [Apps recovery procedure](https://github.com/clanwright/apps/blob/v0.4.0/docs/recovery.md)
is the source of the application interface. Evidence must retain its release,
the consumer configuration, logs, duration, capture IDs/times, repository and
snapshot IDs, and validator closure provenance without credentials.

All Apps evidence below is bound to v0.4.0 revision
`af0d564cc388aa21e71e0efa4a622d3d11396ea5` and its
[published native example](https://github.com/clanwright/apps/blob/v0.4.0/examples/native-restic.nix).
Reliability's composition check and the reused exact released example's
end-to-end evidence establish repository integration. Reliability did not
rerun those upstream end-to-end tests or commission a real installation.

| Owner | Evidence | Coverage and boundary |
| --- | --- | --- |
| Reliability | `apps-composition` PASS; `.work/apps-v0.4.0/composition-report.json` records both actual application declarations, four backup jobs and eight independent check jobs | Matched composition evaluation; no service execution |
| Reliability | Darwin `local-ci` and ARM Linux package, module, Restic and composition checks PASS; `.work/apps-v0.4.0/local-ci.log`, `linux-checks.log` and `linux-outputs.txt` | File transport, structural/full-data checks and restore; not application semantics |
| Reliability | Issue-2 observed composition evaluation PASS; `.work/issue-2/composition-build.log` | Native hook composition and configuration evaluation; no native lifecycle execution or four-pair semantic recovery |
| Reliability | Issue-2 Darwin `local-ci` and ARM Linux checks PASS; `.work/issue-2/local-ci.log`, `linux-checks.log` and `linux-outputs.txt` | Real temporary Restic metadata observation, malformed/future/expired rejection, unchanged capture age on re-upload, actual exit-3 fixture, Prometheus exposition parsing and 13 alert scenarios; hook execution remains unproven |
| Apps | Exact released ARM `recovery-runtime` output reused; all PASS in `.work/apps-v0.4.0/producer-native-check.log` | Disposable owner recovery suite; selected build reused cache rather than freshly executing |
| Apps | Exact released ARM VM `validator-isolation` output, 111.43 s; `.work/apps-v0.4.0/upstream-isolation-summary.log` | Privileged handoff, cancellation and descendant/isolation behavior; existing release evidence, not rerun here |
| Apps | Exact released `export-runtime` output: full x86 VM on ARM TCG, 344.16 s; `.work/apps-v0.4.0/upstream-export-summary.log` | Native-service lifecycle, both apps, four app/destination snapshots and semantic recovery; emulation explicitly attributed, not native x86 hardware or a Reliability rerun |
| Installation owner | Commission each actual destination and retained validation environment separately | Repository access, source freshness, monitoring, recovery credentials and usable application restore in that installation remain outside repository acceptance |

The already-realised upstream outputs inspected without a new build were
`/nix/store/75cy2q8q9f864xqrvbliyxznjq0i9g66-vm-test-run-apps-export-runtime`
and `/nix/store/9sqlc1d6nld6s5sdwfpia63qlj5wl7i6-vm-test-run-apps-validator-isolation`.
Their existing logs reported the durations above. The matched composition
report came from
`/nix/store/ckzyf987vk9xywjgkr5g3ljfy00x0dl0-reliability-apps-composition/report.json`.
The reused native recovery log came from
`/nix/store/zqqvvv7vzra9z7jkavv57i75z9xpyrpd-clanwright-apps-recovery-runtime/check.log`.

Commissioning must still record successful and failed/interrupted captures,
initially stopped applications, slow readers during replacement, independent
destination failure/retry, and metadata-preserving delivery. Record capture
age independently of upload and snapshot age; test missing, malformed, future
and stale admission, including the last good capture after failure. Keep
structural/full-data integrity evidence separate from disposable semantic
validation of both applications from both repositories. These are installation
acceptance responsibilities, not an additional mandatory native-hardware gate
for the earlier issue-1 repository integration. Issue 2 separately requires
fresh runtime acceptance on a disposable native Linux host as root with its
local systemd manager and cgroup v2. That gate remains pending: root access to
an appropriate test host is currently unavailable. The cached upstream results
above do not complete it. No installation monitoring acceptance or monthly
four-pair drill has been executed by this documentation change.

`disabled-retained` keeps opted-in native export state but withdraws exporters
and command outputs. Turning exports off or selecting `null` does not delete
local state or historical backups. Preserve the matching rooted closure first.
The v0.4.0 formats remain `vaultwarden-pg18-files-v1` and
`livesync-couchdb3-v1`; historical captures without `export.json` can use a
compatible semantic validator but are not automatically admitted as new native
exports. Preserve application/database versions for retained formats and test
database-major migrations separately; do not relabel an old artifact.

## Commissioning and routine checks

1. Review source paths and the application-specific export procedure. Confirm
   exports complete before backup services start. Record excluded valuable
   state explicitly.
2. Provision each encrypted repository and its runtime credentials separately.
   The example sets `initialize = false`, so repository initialization is an
   explicit operator action. Keep credential recovery material off the host.
3. Evaluate the NixOS configuration, then authorize activation separately.
   Observe a completed backup and a current snapshot at **each** destination.
   A success at one destination says nothing about the other.
4. Run a structural check and a full-data read for each repository. Restore
   each to disposable storage and verify application semantics with the
   compatible application handler. Monitor backup age and a stopped host
   externally.

The following Restic commands are templates for an operator-approved
repository. Set `RESTIC_REPOSITORY` to its exact location and
`RESTIC_PASSWORD_FILE` to a protected runtime path before using them. Supply
backend credentials through the approved runtime environment. They are not
run by local checks:

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

Set `SNAPSHOT_ID` to an ID from that repository's snapshot listing, and
inspect its paths before restoring. For an acceptance drill, select an
immutable snapshot with retained evidence that its exact backup invocation
exited 0. In the observed composition, retain the successful observation and
its invocation provenance, and select its `snapshot_id` from
`reliability_capture_snapshot_info`; do not select `latest` merely because it
contains `export.json`. Set `SNAPSHOT_EXPORT_PATH` to the selected snapshot's
exact `export.json` path after inspecting its tree. Supply an absolute,
fresh disposable root-owned `RESTORE_ROOT` and use the approved root Restic
environment for restore; never overwrite production or an existing drill.
`check` tests repository structure; `check --read-data` reads repository data.
Neither substitutes for an application restore. See the
[Restic restore documentation](https://restic.readthedocs.io/en/stable/050_restore.html).

Perform a separately authorized monthly manual drill for each of the four
application/destination pairs. Restore the selected snapshot into disposable
storage and follow the retained-closure validation and isolation instructions
above. Record each pair independently, including failures and incomplete drills:

| Pair | Status | Snapshot ID | Capture ID | Capture/upload/drill times | Trusted closure | Result/logs/scratch |
| --- | --- | --- | --- | --- | --- | --- |
| Vaultwarden / a | pending | — | — | — | — | — |
| Vaultwarden / b | pending | — | — | — | — | — |
| LiveSync / a | pending | — | — | — | — | — |
| LiveSync / b | pending | — | — | — | — | — |

Replace these empty record rows only with evidence from that month's drill.

| Record | Required evidence |
| --- | --- |
| Selection and status | Application/destination pair, repository identity, immutable snapshot ID, exact backup exit-0 provenance, and drill status (`pass`, `fail` or `unknown`) |
| Capture and timing | Restored `export.json` capture ID, capture start/completion, upload completion, drill start/end and duration |
| Recovery | Trusted retained validator closure and pinned configuration, restore/check/validation logs and results, and scratch-directory path and teardown outcome |

Use `unknown` when snapshot provenance, validation or teardown is uncertain;
it does not satisfy acceptance. Retain scratch on failed or uncertain validation
and follow the reboot-before-removal instruction above. Successful delivery or
a drill for one pair does not cover another pair. This procedure defines the
manual evidence to collect; no monthly drill or installation monitoring
acceptance has been executed by documenting it.

## Breaking migration and retention

The old `clanwright.reliability` configuration and `reliability` CLI have no
counterparts in this flake. Preserve the previous repositories, snapshots,
credential paths, and configuration. Keep a compatible pinned Restic version
available for manual access to historical snapshots. Inspect `restic snapshots`
and `restic ls` for each old destination, then restore selected snapshots to
disposable storage and verify their contents and application behavior. Do not
assume the new example reads the former generation ledger or imports old
snapshot lineages. Switch to new native jobs only after the new sources and
restore procedure are understood. No old backup data is removed by this change.

The example leaves `pruneOpts = [ ]`, so no automatic `forget --prune` policy
is configured. For a proposed retention policy, first inspect the exact
repository and its snapshot groups, then run a **dry run** with reviewed
`--keep-*` options, for example:

```sh
restic snapshots
restic forget --dry-run --keep-daily 7 --keep-weekly 4 --keep-monthly 12
```

This only previews a possible policy. Enabling `forget` or `prune` can remove
recovery points and needs separate approval after destination-specific restore
evidence. Provider version-history lifecycle is a separate decision; see
[security and recovery](security.md). No repository initialization, deletion,
restore into production, activation, or provider change is authorized by these
instructions.
