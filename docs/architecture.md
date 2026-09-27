# Architecture and ownership

Reliability consumes recovery-unit declarations supplied through the neutral
`clanwright.recovery.units` NixOS option. The contract owner is Primitives
([issue 1](https://github.com/clanwright/primitives/issues/1)); application
producers are owned by Apps ([issue 3](https://github.com/clanwright/apps/issues/3)).
The schema and application handlers are external dependencies, so this project
does not duplicate their production declarations or their implementation.

Each selected unit has a stable ID, contract version, application-owned stored
format version, native Clan state references, a capture executable, and an
isolated validation executable. The capture handler receives an empty output
directory and succeeds only when a complete, stable copy exists and application
cleanup has completed. The validation handler receives restored unit data and
must verify it using disposable local state. The application owner defines the
artifact layout, consistency mechanism, restore order, and supported stored
formats. Reliability identifies and dispatches units without application-specific
file paths, table checks, or provider rules. Contract version and stored format
version have different owners and cannot be used interchangeably. Reliability
reserves `reliability-manifest.json` inside each unit artifact for the generation,
capture time, unit ID, and format version. It does not automatically record the
owner's release provenance.

Reliability stages a complete capture generation before uploading it to
independent destinations. The capture time, unit ID, generation, and format
identify a recovery point. Delayed upload does not make old captured data fresh.
A failed unit capture cannot publish a complete generation. Destination failures
are reported separately; one successful destination cannot certify another.
Each destination has its own operation lock, so a slow upload need not block
work for another destination. An upload leases its source generation until it
finishes. After a newer capture succeeds, older unleased local generations are
removed; a recovered destination uploads the newest complete capture rather
than a backlog of missed generations. A failed capture preserves the prior
current generation. Repository snapshots remain governed by retention, not by
local generation cleanup.
Native Clan state remains the inventory of protected paths; the recovery
contract groups those existing state entries without a second path registry.

The installation owns unit selection, repository locations, policy, runtime
secret bindings, alert routing, and deployment. Enabling an application does
not implicitly select or transmit its state. The installation must account for
each valuable application as selected or explicitly waived. Reliability does
not initialize, deploy, or restore production data without a separate operator
action. See [operations](operations.md) for the lifecycle.

## Compatibility across releases

A unit ID is a logical recovery identity, independent of a host name. Removing
or disabling its producer must not erase existing snapshots or make maintenance
silently discard its lineage. The operator retains a compatible, pinned
application validation and restore handler closure, configuration, and relevant
application/database versions for every stored format kept by retention.
Unknown unit IDs, unsupported contract versions, and unsupported
stored formats must fail clearly. An upgrade requires a recovery drill with the
new or pinned handler before relying on older snapshots; a successful backup
command alone does not prove that a historical format remains restorable.

Primitives and Apps releases are prerequisites for official consumer
integration. This repository can test its generic interface with disposable
fixture units while those releases are pending. Fixture compatibility is not
evidence that either upstream application can be recovered.
