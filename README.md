# Reliability

Reliability is a small Nix flake for using [Restic](https://restic.net/) with
NixOS. It is developed in [clanwright/reliability](https://github.com/clanwright/reliability)
and licensed under [MIT](LICENSE). `packages.default` provides the pinned
`pkgs.restic`, and `apps.default` runs that Restic executable. The repository
also supplies a NixOS example using the native `services.restic.backups` module.

Start with [the native configuration example](examples/restic.nix). The
[architecture](docs/architecture.md) explains what the example does and where
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
compatibility work in [Reliability issue 1](https://github.com/clanwright/reliability/issues/1).
Primitives and Apps retain ownership of their contracts and handlers; this
flake does not consume them.

Local checks use disposable repositories. They do not establish a deployed
backup or a usable application recovery point at either destination.
