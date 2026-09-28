# Security and recovery boundaries

Each destination is an independent encrypted Restic repository. Keep its
password and backend credentials in runtime files outside the Nix store. Do
not put secret values or credential-bearing repository URLs in Nix source,
logs, or status output. Preserve recovery credentials independently of the
protected host and its backup stores.

The native Restic backup services do not create a consistent application
snapshot by themselves. In the generic example, `/srv/backup-input` must contain
completed exports or other stable files before either job reads it. A successful
Restic backup can still contain incomplete application data. Verify a disposable
restore and application behavior from each destination, with no production writes, public
ingress, or outgoing application actions. A production restore requires a
separate approved procedure.

Apps v0.4.0 publishes only after cleanup and service resumption. Its reader
preparation copies the completed capture under a shared lock and checks age
before and after copying. Each destination's independent copy remains its
input until all Restic processes have stopped; only then may the job clean it
up. Do not back up the publisher's `current` pointer. A timer dependency is
not a reader-lifetime guarantee.

Preserve the pinned validation closure for each retained format independently
of restored `export.json`. Its `validatorStorePath` is provenance, not a GC
root or a trusted executable selection. The released validator uses root only
for the disposable isolation handoff, then runs as UID 65534 with Bubblewrap
environment, capability, file-descriptor, and network isolation, including a
store-backed `/bin/sh`. It requires a local Linux system manager and cgroup v2
in the same namespaces. Successful validation cleans only a known-empty
cgroup. On a failed or uncertain teardown, retain the printed scratch path;
reboot the disposable host before any manual removal. Upstream release evidence
supports the matched repository integration; it does not establish acceptance
of a real destination installation.

Automatic repository initialization and pruning are disabled in the example.
Restic retention governs logical snapshots and reachable repository objects;
provider object versioning can retain older object versions after a writer
changes the current repository view. Versioning is not Object Lock or an
account-admin compromise boundary. Provider lifecycle rules must not expire
current Restic objects, which can remain referenced by recent snapshots.
Test a repository-consistent historical recovery before enabling expiry of
noncurrent versions. No provider setting is changed by this repository's
local checks.

Track export capture age, backup/upload success, snapshot age, structural
check, full-data read, and application restore separately for each destination.
Re-uploading old data does not refresh its capture age. A check cannot
establish application consistency, and local status cannot detect a host that
stopped reporting; external monitoring is required.

The optional observed composition reads destination metadata only after the
native backup succeeds and associates it with that invocation's exact snapshot.
Readable `export.json`, a current snapshot and a passing repository check alone
do not establish a complete backup: exit 3 can retain a partial snapshot.
Success textfiles retain the prior successful observation when a later attempt
fails. Alert on unsuccessful attempts, missing series, stale capture and
observation times, and an unavailable off-host scrape target. Local textfiles
cannot prove the host is reachable or detect later repository loss without a
new repository operation.

Keep the textfile directory administrator-controlled. Metrics contain app and
destination labels, capture IDs, snapshot IDs and times, but no repository
locations or credentials; protect their exposure according to the installation's
monitoring policy. Never select a validator executable from restored metadata.
Monthly drills restore each pair independently to root-owned disposable `0700`
storage and use the matching trusted retained closure. A failed or uncertain
validation retains scratch and requires the documented disposable-host reboot
before manual removal. The owner excluded further local-machine and
virtual-machine testing from issue 2's delivery scope. Native runtime and
four-pair semantic recovery acceptance remain unverified and must not be
inferred from this release or previously reused evidence.
