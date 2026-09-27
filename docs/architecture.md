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
