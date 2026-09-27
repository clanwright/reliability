# Reliability

Reliability is the generic NixOS executor for application recovery units. It is
developed in [clanwright/reliability](https://github.com/clanwright/reliability)
and licensed under [MIT](LICENSE). This repository owns capture orchestration,
encrypted Restic destinations, checks, isolated restore validation, maintenance
guards, and status evidence. It does not own application data formats, provider
accounts, or a production restore procedure.

The public recovery-unit declaration is being developed in
[Primitives issue 1](https://github.com/clanwright/primitives/issues/1).
[Apps issue 3](https://github.com/clanwright/apps/issues/3) will publish the
first application-owned units. Reliability consumes their typed declarations;
Apps and Reliability do not import one another. A standalone user may provide
compatible declarations, while integration with the official modules depends
on their released contract. A declared unit alone does not start a backup;
the installation selects stable unit IDs explicitly.

The [architecture and contract](docs/architecture.md) explain ownership and
compatibility. [Operations](docs/operations.md) covers local verification,
commissioning, checks, and maintenance. [Security and recovery](docs/security.md)
separates Restic retention, provider-protected history, and isolated validation.
No local evaluation establishes a deployed backup or a usable production
recovery point. Those require independent evidence from each destination.
