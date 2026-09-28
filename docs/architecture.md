# Architecture and ownership

The flake exposes the pinned `pkgs.restic` as its default package and app. It
does not implement a backup runtime or a NixOS module. The
[example](../examples/restic.nix) composes NixOS's existing
`services.restic.backups` declarations for two independent destinations. Each
has its own repository and runtime credential paths. Native systemd services
perform the backups; separate jobs run structural and full-data checks. The
example does not initialize repositories or configure automatic pruning.

The installation chooses source paths, schedules, destinations, credentials,
monitoring, and deployment. The example expects `/srv/backup-input` to contain
stable, prepared files. Neither this repository nor the NixOS Restic module
automatically connects native Clan state hooks or produces application exports.
Back up a live database only through a consistent application-owned export or
another proven integration; copying its live data directory as ordinary files
does not establish a recoverable database. Application-specific preparation,
restore order, and semantic validation remain with the application owner and
operator. This repository provides no app-specific glue.

The former executor's recovery-unit declarations, staged generations, commit
ledger, validator sandbox, maintenance gates, and custom metrics are absent.
The old contract is not compatible with the native example. Existing snapshots
remain in their original repositories and must be inspected with compatible,
pinned Restic and restored through a deliberate migration procedure. A new
native backup is a new recovery stream; it does not import or certify the old
one. See [operations](operations.md) before switching an installation.

Passing module evaluation and a real Restic test against disposable local data
shows that the example and basic file backup path work. It does not prove
application-consistent exports, successful access to production destinations,
or restoration of an application. Each destination needs its own operational
evidence.

## Released native Apps composition

[Apps v0.4.0](https://github.com/clanwright/apps/blob/v0.4.0/docs/recovery.md)
owns exports, failure and cancellation behavior, reader preparation, freshness
metadata, and executable semantic validation. Per-app `export.enable` is off
by default. Enabling it exposes unscheduled
`apps-export-vaultwarden.service` and `apps-export-livesync.service`; ordinary
application enablement starts neither exports nor backup timers. Cleanup and
production service resumption finish before a complete capture is published
under `/var/lib/clanwright-app-exports/{vaultwarden,livesync}`.
Failure before publication preserves the previous capture. A later reclamation
failure can report service failure while the newly completed capture remains
usable; record the service result and journal as well as metadata.

Restic must not read the publisher's `current` directory directly.
`system.build.appsVaultwardenExport` and `system.build.appsLiveSyncExport`
provide `prepare-reader`, which copies a capture into an independent reader
directory. It holds a shared publisher lock only while copying and checks age
before and after the copy; missing, future-dated, or stale captures fail. Once
prepared, each destination owns its copy for the entire Restic process
lifetime. Publisher replacement cannot alter another destination's reader.
Reader cleanup follows process teardown, and the Restic cache is a sibling of
the input so cache exclusion cannot exclude the backup itself. Native
`Requires`/`After` ordering supplies startup ordering, not an ongoing source
lease. Capture production and destination preparation remain separate jobs;
one destination's slow upload, failure, or retry does not pause production.

The reader preserves `export.json` schema 1 with `appId`, `captureId`,
`captureStartedAt`, `captureCompletedAt` (integer Unix seconds), `formatVersion`,
and `validatorStorePath`. Capture time, upload time, and Restic snapshot time
are separate facts. Re-uploading an old capture does not make it fresh. After
a failed export, the last good capture is usable only while it passes the
configured admission-age limit; a slow destination can receive it later.
`validatorStorePath` records provenance; it is neither
permission to execute a restored path nor a Nix garbage-collection root.

Reliability's [Apps example](../examples/apps-restic.nix) imports the upstream
public composition directly and adds separate structural and full-data check
jobs for both applications, requiring both export selections to be enabled.
Reliability owns evaluation and transport acceptance of that composition,
not application capture or validation code. The consumer owns destinations,
schedules, retention, credentials, monitoring, deployment, and preservation of
the pinned validation closure. Primitives participates only if a concrete
shared contract requirement appears.

The released validator performs a root-to-unprivileged isolation handoff using
a transient systemd service. It needs a disposable native Linux environment
with a local system manager and cgroup v2; it must not validate production
directories. Restic structural and full-data checks do not prove semantic
recovery. Repository integration uses our matched composition evaluation and
the exact released upstream lifecycle and semantic recovery evidence. A real
installation still needs destination-specific commissioning, described in
[operations](operations.md).
