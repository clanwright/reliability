# Reliability

Reliability is a small Nix flake for using [Restic](https://restic.net/) with
NixOS. It is developed in [clanwright/reliability](https://github.com/clanwright/reliability)
and licensed under [MIT](LICENSE). `packages.default` provides the pinned
`pkgs.restic`, and `apps.default` runs that Restic executable. The repository
also supplies a NixOS example using the native `services.restic.backups` module.

Start with [the native configuration example](examples/restic.nix). The
[Apps composition example](examples/apps-restic.nix) imports the released
application-owned native Restic integration for Vaultwarden and LiveSync.
The optional [observed Apps composition](examples/apps-observed-restic.nix)
adds stricter capture admission, success-only destination metadata observation
and Prometheus textfile metrics. [Operations](docs/operations.md) explains its
off-host monitoring setup and four independent monthly manual recovery drills.
The [architecture](docs/architecture.md) explains what the example does and where
application consistency belongs. [Operations](docs/operations.md) contains
verification, commissioning, restore, and retention commands.
[Security and recovery](docs/security.md) covers credentials, independent
destinations, and recovery limits.

This is a breaking change from the former custom executor. There is no
`nixosModules.default`, `clanwright.reliability` option tree, or `reliability`
CLI. Existing repositories and snapshots are not converted or deleted. Keep
their credentials, configuration, and a compatible pinned Restic available
until their recovery points have been inspected and restored successfully.
The owner-approved redesign supersedes this repository's recovery-unit
compatibility work in [Reliability issue 1](https://github.com/clanwright/reliability/issues/1#issuecomment-5858246892).
Apps owns consistent exports, reader preparation, and the semantic recovery
procedure. Reliability owns the matched Restic composition, bounded metadata
observation and checks.
Primitives participates only if a concrete shared contract is needed.

Apps v0.4.0 (`af0d564cc388aa21e71e0efa4a622d3d11396ea5`) publishes the
[native recovery interface](https://github.com/clanwright/apps/blob/v0.4.0/docs/recovery.md)
requested in [Apps issue 4](https://github.com/clanwright/apps/issues/4).
Application enablement does not schedule exports or backups. Repository
integration evidence combines our matched composition check with the exact
released upstream end-to-end outputs; it does not establish commissioning at
real destinations. See [operations](docs/operations.md) for the evidence and
installation procedure.

Local checks use disposable repositories. They do not establish a deployed
backup or a usable application recovery point at either destination.
The owner accepted issue 2's implementation and documented manual procedure
without further local-machine or virtual-machine testing. Native service
execution and four-pair semantic recovery were not verified by this release;
installation commissioning remains separate.
