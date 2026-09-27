# Operations

The [native NixOS example](../examples/restic.nix) configures two independent
`services.restic.backups` entries over `/srv/backup-input`, with separate
structural and full-data checks. Prepare stable application exports there
through an approved application integration before running a backup. The
example does not wire native Clan state hooks automatically. Do not point it
at a live database directory and assume file copying is consistent.

The flake pins nixpkgs for its Restic package and local checks. The default
package and app run Restic directly. To confirm the pinned executable and run
the checks for this host:

```sh
nix run --no-write-lock-file . -- version
nix run --no-write-lock-file .#local-ci
```

On macOS, `local-ci` checks the Darwin outputs; it does not run NixOS module
evaluation. Run the Linux gate on an approved native ARM Linux builder or host:

```sh
nix build --no-write-lock-file --no-link .#checks.aarch64-linux.module-eval .#checks.aarch64-linux.runtime-integration
```

Use the corresponding `x86_64-linux` check names on a native x86 Linux host.
Local checks use fake data and temporary Restic repositories; they do not run
production backups or prove Apps runtime acceptance. No virtual machine or
QEMU test is required by this repository.

Adapt and import the example into the installation's NixOS configuration. For
example, after copying it there as `restic.nix`:

```nix
{ ... }: {
  imports = [ ./restic.nix ];
}
```

The example creates the standard `restic-backups-primary.service` and
`restic-backups-secondary.service` backup units, with separate check units.
On an activated NixOS host, the upstream module's `restic-primary` wrapper
supplies the configured repository and credential paths for manual Restic
inspection, such as `restic-primary snapshots`. Its existence does not imply
that a backup has run. The [NixOS Restic module](https://github.com/NixOS/nixpkgs/blob/master/nixos/modules/services/backup/restic.nix)
defines these units and wrappers.

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
restic restore "$SNAPSHOT_ID" --target /path/to/disposable-restore
```

Set `SNAPSHOT_ID` to an ID from that repository's snapshot listing, and
inspect its paths before restoring.
`check` tests repository structure; `check --read-data` reads repository data.
Neither substitutes for an application restore. See the
[Restic restore documentation](https://restic.readthedocs.io/en/stable/050_restore.html).

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
