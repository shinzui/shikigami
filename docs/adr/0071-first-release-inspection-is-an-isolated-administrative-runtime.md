# 0071. First-release inspection is an isolated administrative runtime

Date: 2026-10-30

Status: accepted

## Context

The user confirmed Shikigami remains unused and requested comprehensive Keiro 0.22 adoption. MasterPlan 16 previously excluded HTTP inspection and live feeds and required preserving old histories. ADR-27 already permits a clean first-release baseline; that policy applies to this initiative. Operational visibility is now an intended first-release capability, not merely a dependency compiling successfully.

## Decision

Adopt the released CLI catalogs and administrative HTTP/live-feed surfaces for runtime capabilities Shikigami actually owns. Host them with explicit administrative authentication and authorization, loopback defaults, dedicated bounded inspection connections, finite network/database/delivery budgets, schema checks and bracketed cleanup. Mutations remain deliberately enabled, previewed/confirmed and audited through their owning public APIs. Browser Origin/CORS policy is additional protection, never authentication.

Application aggregate displays contain safe lifecycle metadata, never rich protected replay bodies or snapshot-codec output by default. No inspection-only work belongs on command hot paths. The server may host durable database inspection; Shibuya live metrics belong to the worker holding the actual AppHandle. Neither a duplicate runtime nor invented cross-process metrics is permitted. Compose already allocated surfaces and preserve their distinct snapshot/event-tail protocols. Join feed/listener workers before releasing pools.

The shared transport is the public `shikigami-core:inspection` Cabal component,
compiled from `shikigami-core/inspection/`. It depends on the main domain library,
with no reverse edge. Server and workers opt into this component; the one-off
agent does not. This is a component-level serving boundary inside the existing
seven packages, not permission for the core main library to acquire WAI,
inspection providers or queue interpreters. Pure display descriptions and Settei
settings remain in the main domain library. The architecture tests enforce both
the original lightweight main-library budget and this selected component boundary.

Browser read authority covers lifecycle facts and process metrics. Native Kiroku
provider discovery truthfully disables raw browsing, dead letters and event tails;
raw journals and PGMQ message browsing are also outside this display grant. The
trusted local CLI retains native operator operations. HTTP mutation authority is
a distinct secret credential plus explicit enablement; native JSON confirmation,
preview, schema policy and audit remain required. HTTP permanent stream deletion
is refused because no application erasure-decision hook is mounted. Shibuya
control remains disabled.

This expands ADR-21 and ADR-38's operational scope without changing their schema, mutation, resource-aware resume, retention or live-only payload constraints. ADR-27's first-release exception remains in force: unused historical readers and patch branches are not required. This decision authorizes implementation design, not deployment or database deletion, and is implemented by the optional hosting component and native listener/socket
fixtures. Exact qualification limits remain in the evidence and operator runbook.

## Alternatives rejected

A CLI-only plan leaves applicable released inspection unadopted despite the user's explicit comprehensive scope. Hosting everything in the HTTP process misrepresents worker-local state. Reusing worker pools for slow browser clients couples inspection lifetime to production progress. Rendering snapshot bodies risks disclosure and conflates persistence with display.

## Consequences

Plan 106 owns host allocation, catalog displays, protocol/policy tests and operator documentation. Plan 94 supplies actual process-local metrics lifetime. Plan 95 qualifies their integration and database interference. Missing process-manager descriptors are honest when no compiled reaction manager exists; ordinary workflows are not relabeled to fill a catalog.

## References

- [MasterPlan 16](../masterplans/16-upgrade-shikigami-to-keiro-0-22-and-retire-superseded-runtime-workarounds.md)
- [ADR-27](0027-the-first-release-establishes-one-clean-durable-baseline.md)
- [ADR-38](0038-runtime-startup-and-maintenance-share-validated-owners.md)
- `mori://shinzui/keiro/okf/adrs/concepts/ADR-28`
- `mori://shinzui/keiro/okf/adrs/concepts/ADR-54`
- `mori://shinzui/keiro-runtime-patterns/docs/inspection-hosting-and-browser-access`
- `mori://shinzui/keiro-runtime-patterns/docs/inspection-bounded-live-feeds`
