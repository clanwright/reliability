# Reliability

Reliability is a small [MIT-licensed](LICENSE) Nix flake for native
[Restic](https://restic.net/) backups on NixOS. The default package and app
provide pinned Restic. `packages.capture-observation` provides the bounded
`restic-capture-observe` metadata observer; `packages.local-ci` and
`apps.local-ci` provide local verification.

The [generic example](examples/restic.nix) backs up prepared files to two
independent repositories. The [Apps composition](examples/apps-restic.nix)
uses public application export outputs for four independent backup jobs and
eight structural/full-data checks. Its optional `observe` setting adds
invocation-bound destination metadata and Prometheus textfile metrics.
Jobs in the Apps composition are manual by default, with repository
initialization, pruning and direct command wrappers disabled.

[Architecture](docs/architecture.md) describes the composition and ownership.
[Operations](docs/operations.md) contains imports, local checks, monitoring,
commissioning, four independent monthly restore drills and retention commands.
[Security and recovery](docs/security.md) describes credentials and isolation.

## Inputs and acceptance

[flake.lock](flake.lock) is the authoritative test cohort, including the Apps
producer and its declared dependencies. The fixture exercises the public
consumer-configured export contract; changing its inputs changes no consumer
input or deployed service. Consumers select a compatible Apps producer and
explicit native ACME challenges for each physical certificate.

Local checks cover Nix formatting, canonical Linux configuration evaluation,
Apps composition, temporary real Restic repositories and Prometheus parsing
and alerts. Preserve exact revisions, readable logs and whole/stage durations
under ignored `.work`. Local evidence does not establish actual native manager
execution or same-host application recovery. The single
[PREDEPLOY matrix](docs/operations.md#required-predeployment-proof) records
required runtime cases and their unobserved boundary before deployment.

Apps owns consistent complete publication, writer quiescence, preservation of
prior service activity, independent readers and retained trusted semantic
validation. Reliability owns native Restic transport, invocation-bound
metadata observation and repository checks. It has no direct Primitives API
or schema dependency. File backup and repository checks do not establish
application consistency or semantic recovery. Each application/destination
pair needs separately authorized commissioning and monthly recovery drills.
