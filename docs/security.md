# Security and recovery boundaries

Each destination is an independent encrypted Restic repository. Keep its
password and backend credentials in runtime files outside the Nix store. Do
not put secret values or credential-bearing repository URLs in Nix source,
logs, or status output. Preserve recovery credentials independently of the
protected host and its backup stores.

The native Restic backup services do not create a consistent application
snapshot by themselves. `/srv/backup-input` must contain completed exports or
other stable files before either job reads it. A successful Restic backup can
still contain incomplete application data. Verify a disposable restore and
application behavior from each destination, with no production writes, public
ingress, or outgoing application actions. A production restore requires a
separate approved procedure.

Automatic repository initialization and pruning are disabled in the example.
Restic retention governs logical snapshots and reachable repository objects;
provider object versioning can retain older object versions after a writer
changes the current repository view. Versioning is not Object Lock or an
account-admin compromise boundary. Provider lifecycle rules must not expire
current Restic objects, which can remain referenced by recent snapshots.
Test a repository-consistent historical recovery before enabling expiry of
noncurrent versions. No provider setting is changed by this repository's
local checks.

Track backup success, snapshot age, structural check, full-data read, and
application restore separately for each destination. A check cannot establish
application consistency, and local status cannot detect a host that stopped
reporting; external monitoring is required.
