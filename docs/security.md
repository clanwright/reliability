# Security and recovery boundaries

Each destination is an independent encrypted Restic repository. Keep its
password and backend credentials in runtime files outside the Nix store.
Do not put secret values or credential-bearing URLs in source, logs or status
output. Preserve recovery credentials independently of the protected host
and backup stores. Provider, DNS, deployment, backup-writer, restore, prune,
credential and secret mutations require explicit owner authorization.

A successful file backup does not establish application consistency. The
generic example requires completed exports or other stable files. Apps owns
consistent complete publication, reader preparation, prior service activity
and semantic validation. Each destination reads its independent root-owned
`0700` disk-backed reader; cache data stays outside the input. Do not back up
the publisher's `current` pointer. Reader cleanup follows native process
teardown; ordering dependencies alone do not prove a reader lifetime.
Cleanup additionally requires a current-invocation ownership flag in the
existing native Restic runtime directory. Unclaimed or foreign disk input is
preserved with an error and cannot be automatically reused. The small runtime
flag is not durable evidence and does not prove that reader processes stopped.
Actual manager lifetime, stop-before-delete and retained same-host confinement
are required cases in the single
[PREDEPLOY matrix](operations.md#required-predeployment-proof).

Retain the trusted matching Apps validation closure and pinned configuration
for every retained format. Restored `validatorStorePath` records provenance;
it is neither an executable-selection authority nor a garbage-collection
root. Never execute a path selected by restored metadata. Validation uses the
Apps procedure matching the retained release, on disposable,
administrator-controlled Linux storage with no production writes, public
ingress or outgoing application actions. Preserve scratch and logs after a
failed or interrupted validation. Manual removal requires explicit teardown
confirmation; unknown handoff/teardown preserves both scratch and admission
barrier. Follow the matching owner's isolation and manual-recovery procedure,
without automatic retry, deletion or reboot. The authoritative test cohort
and acceptance limits are described in
[README](../README.md#inputs-and-acceptance).

Automatic initialization and pruning are disabled in the Apps composition.
Restic retention governs logical snapshots and reachable objects. Provider
versioning may preserve prior object versions, but is not Object Lock or a
boundary against an account administrator. Lifecycle rules must not expire
current Restic objects still referenced by recent snapshots. Test a
repository-consistent historical recovery before approving expiry of
noncurrent versions; each destination needs independent recovery evidence.

Track capture age, upload success, structural integrity, full-data reads and
semantic restores separately. Re-uploading old data does not refresh capture
age. Exit 3 can retain a partial snapshot even with readable metadata and a
passing repository check. Successful observation requires exact exit-0
invocation provenance, snapshot identity and original capture age.

Keep the textfile directory administrator-controlled. Metrics expose app and
destination labels, capture IDs, snapshot IDs and times, without repository
locations or credentials. Protect their exposure through the monitoring
policy. A pending attempt records 0 before preparation; successful observation
records 1 only after metadata publication. Separate writes can expose verified
metadata while final status publication fails, leaving the latest attempt
uncertified and the native unit failed.

Off-host scraping and independent alert delivery are required to detect a
stopped host. Alert on missing series, failed/overdue attempts, stale capture
and observation times and unavailable targets. Metadata observation does not
continuously test repository contents. Monthly drills restore all four pairs
independently with retained trusted validators; a pass for one pair does not
cover another. [Operations](operations.md) provides the manual procedure.
