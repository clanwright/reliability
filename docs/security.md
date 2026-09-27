# Security and recovery boundaries

Each destination is an independent encrypted Restic repository with its own
runtime credential paths. Configuration and status must contain no secret
values or credential-bearing repository URLs. Capture handlers do not receive
repository credentials. Restored data and validators run in an isolated local
environment without production database access, public ingress, or external
network actions. Validation only assesses a disposable recovery copy;
production restoration is a separately authorized operator procedure.
The restore orchestrator uses a privileged service to stage data, then launches
the owner validator as the unprivileged `reliability-validator` account inside
`bubblewrap`. The validator sees its restored unit read-only at `/input`, a
writable scratch directory at `/tmp`, and the Nix store. Its environment is
cleared and the sandbox has no external network access. This handoff still
needs a Linux runtime acceptance test with the released application handlers.
Validators that need to import or modify data copy it from `/input` into `/tmp`.
Captured units contain regular files and directories; symlinks are rejected.

Restic retention governs logical snapshots and reachable repository objects.
Provider object versioning may retain earlier versions after a compromised
writer alters or deletes the current view. These are separate controls:
Restic maintenance does not prove provider history is recoverable, and
versioning alone is neither Object Lock nor an account-admin compromise
boundary. The writer's need to remove current objects for lock cleanup means
writer and maintenance job separation is operational, not proof against a
compromised host. Recovery authority and repository passwords must be
recoverable independently of that host and its backup stores.

Provider lifecycle rules must preserve old versions for a demonstrated
historical recovery window. They must never age-expire current Restic objects:
an old object can still be referenced by a recent snapshot. Before activating
noncurrent-version expiry, restore a repository-consistent historical view
into an isolated location and test it. Object versions, delete markers,
prune/repack behavior, and cost need provider-specific acceptance. Do not
claim equivalent deletion protection at a second provider without a separate
test. No provider setting or lifecycle policy is changed by this repository's
local checks.

The health signals are distinct: a complete local capture, a committed backup
at each destination, repository structural check, full data read, isolated
semantic restore, and maintenance outcome. Freshness uses capture time, not
upload or timer time. Local status does not detect a dead host on its own;
an external monitor must alert when evidence stops arriving.
