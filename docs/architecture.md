# Architecture and ownership

Reliability composes the upstream NixOS `services.restic.backups` module.
Native systemd services run Restic; separate jobs check repository structure
and read all repository data. The installation owns destinations, runtime
credentials, schedules, monitoring, deployment and retention. The
[README](../README.md#inputs-and-acceptance) identifies the authoritative test
cohort and acceptance boundary.

The [generic example](../examples/restic.nix) expects stable, prepared files
under `/srv/backup-input`. It does not produce application exports or connect
native Clan state hooks. Copying a live database directory does not establish
an application-consistent backup.

## Apps composition

[apps-restic.nix](../examples/apps-restic.nix) is one constructor returning a
NixOS module. It consumes the public consumer-configured
`system.build.appsVaultwardenExport` and `system.build.appsLiveSyncExport`
outputs; it takes no Apps input argument and imports no upstream example.
The consumer enables both exports and imports the corresponding Apps modules.
Application enablement alone schedules neither captures nor backups.

| Constructor option | Default | Meaning |
| --- | --- | --- |
| `observe` | `false` | Enable success-only destination observation |
| `admissionMaxAgeSeconds` | `86400`, or `64800` with observation | Maximum capture-start age during reader preparation |
| `arrivalMaxAgeSeconds` | `86400` | Maximum capture-start age at destination observation |
| `metricsDirectory` | `/var/lib/prometheus-node-exporter-text-files` | Administrator-controlled textfile directory |

Admission is a positive integer no greater than 86400. Arrival is positive
and at least admission. The four backups are `vaultwarden-a`, `vaultwarden-b`,
`livesync-a` and `livesync-b`. Each has independent `-structure` and `-full`
check jobs inheriting its repository, credentials and final Restic package.
The backup job's final `package` is the single Restic authority for backup,
observer and both checks, including consumer overrides.
All twelve jobs are manual by default, without initialization, pruning or
command wrappers. Consumers add schedules explicitly.

Each backup calls the public `prepare-reader` directly with the selected age
once. It copies a completed Apps capture into that job's input and checks age
before and after copying. No appended admission command or patched upstream
hook duplicates this work. Restic must not read the publisher's `current`
pointer. Capture production and destination preparation are independent;
a slow destination does not prevent another reader from preparing its copy.

Readers use a per-job disk-backed `CacheDirectory`, owned by root with mode
`0700`. Its `apps-input` child and Restic `cache` child are siblings, keeping
cache exclusion outside the backup input. Native services use a two-hour
start timeout, two-minute stop timeout and process teardown before reader
cleanup. These settings express the intended lifecycle; evaluation alone
does not prove that lifecycle during cancellation or timeout. Full readers
stay disk-backed; a move into `/run` tmpfs is not accepted for code reduction.

The existing native Restic `RuntimeDirectory` also stores a small ownership flag
named for the current `INVOCATION_ID`. Preparation creates it after successfully
creating the disk-backed input, before calling Apps. Cleanup requires that
current regular flag before deleting an existing input, and removes the flag
only after successful reader removal. A foreign or unclaimed leftover is
preserved with an error; it blocks automatic reuse. Interruption before the
flag is written may leave an unclaimed input for operator review. This guard
establishes invocation ownership; it does not establish process termination.
Actual manager lifetime, cancellation and cleanup behavior remain required
proof in the single [PREDEPLOY matrix](operations.md#required-predeployment-proof).

Apps owns consistency, writer quiescence, complete atomic publication,
preservation of prior activity, reader behavior and retained trusted semantic
validation. A committed complete capture remains selected after a late
unit/status failure; cleanup must not delete selected data. Its bounded
two-producer payload overlap is not a total-host storage cap: independent
reader copies, wrapper/validator scratch and filesystem overhead need separate
budgets. Primitives owns generic database helpers. Reliability
consumes Apps outputs and has no direct Primitives API or schema contract.

## Optional destination observation

The observer package captures each job's final `package` explicitly. It uses
that exact Restic for snapshot selection and metadata reads; there is no
runtime executable fallback. The only observer modes are `start` and
`observe`; metadata checks use one pure validation filter.

Before reader preparation, `start` records attempt success 0 and a status-event
timestamp. Failure to publish that pending state stops preparation. This event
marks the pending phase, not the actual start of Restic. `observe` does not
reset the pending event or timestamp on entry.

Native backups tag snapshots with systemd's invocation ID. Only exit 0 reaches
the success hook; exit 3 can leave a partial snapshot and is not accepted.
The observer requires exactly one snapshot with the exact invocation tag and
input path, dumps that immutable snapshot's `export.json`, and validates
schema 1, matching app/format, capture identity and ordered capture times.
Arrival age is measured from original `captureStartedAt`. Upload and snapshot
time cannot make an old capture fresh.

Validated metadata is published before final attempt status. On completion,
status becomes 1 with its completion-event timestamp. Those writes are not a
transaction: a final status-write failure can leave newly verified metadata
published while the latest attempt remains pending and the native unit fails.
Neither that metadata alone nor a readable snapshot certifies the latest
attempt. Earlier success metadata remains available after a failed attempt.

The alert group measures elapsed time since the latest attempt status event.
A new pending event resets its grace intentionally, including retries; it does
not use a continuous-failure `for` interval. `attemptGracePeriod` remains a
Prometheus duration with default `2h5m`. Capture-age warning/critical defaults
remain 64800/86400 seconds. Observation reads metadata at backup completion;
later repository loss, database consistency and semantic recovery require
separate evidence. See [operations](operations.md) for metrics and drills.
