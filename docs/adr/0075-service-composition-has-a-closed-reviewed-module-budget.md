# 0075. Service composition has a closed reviewed module budget

Date: 2026-10-30

Status: accepted

## Context

Concept-owned code had accumulated in generic namespaces: execution/session
bindings in DomainBindings, a UUID-name byte encoder in Id.Name, and consumer,
inspection and supervision behavior below Workers. Core still exposed an unused
milestone placeholder. These locations obscure ownership and do not satisfy the
current vertical-slice and cross-cutting-module guides.

The generic cross-cutting guide's closed list also omits real shared composition
that this service already deliberately owns: the resource-aware application
interpreter, one configuration/role loader, five-family workflow startup, neutral
logging/trace context, SDK resource acquisition and leaf CLI configuration/version
adapters. ADR-3, ADR-32, ADR-38 and ADR-71 establish these boundaries and their
package budgets. Moving them into one business concept would give that concept
ownership of unrelated roles, or duplicate precedence, recovery or resource
lifetimes.

## Decision

Place actual concept behavior in its concept vertical. Integration.ConsumerRuntime
owns the bracketed Shibuya consumer application; Health.Supervision owns fail-fast
loop health; Inspection.Consumer and Inspection.Server own the administrative host
bridges. Their tests move with them. Execution.Bindings and WorkerSession.Bindings
own their respective nominal mappings. Use Diagrams for the real shared diagram
renderer. Remove Core and Id.Name: the former has no consumer, and the latter's
small, unchanged UTF-8 encoder belongs in the allowed Prelude.

Keep a closed, machine-readable service composition list in
[the module policy](../../tools/style/module-ownership.json). The checker separates
known concept namespaces, producer-owned shared generated output and individually
reviewed composition modules. Unknown technical roots, new unlisted helpers,
placeholder Core, Id/Store buckets and misleading module headers fail the check.
The policy does not permit hand edits to generated code or prove business
ownership merely from a filename; the generation gate and semantic review remain.

The following are explicit service-specific extensions to the generic closed
cross-cutting list, rather than claims that the upstream list already names them:

- App, App.Config.Load, App.Role and App.Version interpret the actual resource row
  and one settings/build-identity boundary. Runtime and Workflow.Registry/Versioning
  compose validated startup, recovery and declared patch ownership for all five
  workflow families under ADR-38.
- Log/Correlation and the neutral Telemetry.Metrics/TraceContext modules serve
  every concept. SDK acquisition and sampling remain in serving roles, including
  Server.Telemetry and the workers' Telemetry/Sampler. Server.RequestLog wraps the
  HTTP perimeter. These do not put exporters or listeners into light libraries.
- Workers.Shutdown owns process-wide quiescence and joined resource release.
  Workers.Registry/Config/Subscription compose their concept workers; they do not
  absorb delivery, inspection or health behavior.
- Role command parsers, the API's OpenApi/Problem protocols, and leaf client or
  migration configuration/payload/version adapters keep their declared package
  budgets. In particular, a leaf version/configuration helper does not import core
  to avoid maintaining a small local adapter. The exact current modules are listed;
  there is no blanket permission for arbitrary Server.*, Workers.* or Client.*.

A new technical namespace needs an owning rationale and policy update in the same
change. Routine additions inside an already approved role still add their exact
module to the list. A real new concept belongs in the domain-root list with its
implementation; neither list is a technology catch-all or a reason to create a
placeholder module.

ExecPlan 108 adds the implemented `FormatVersion` value owner alongside the
existing shared `StateRevision` value owner. It owns only the closed, nominally
scoped numeric protocol selector and its exact JSON codec. Execution, worker
session and compliance contracts select their own scopes; this module performs
no protocol dispatch, migration, storage or runtime composition. The domain-root
entry is for that concrete value contract, not a general serialization bucket.

ExecPlan 108 also adds `Duration`, which owns scoped nonnegative time spans and
explicit clock lowering, and `RuntimePolicy`, which owns the closed manifest
strictness and default-model requirements with their historical boolean codecs.
These are concrete value contracts; they contain no runtime dispatch, loading,
storage, or service composition. Configured positive budget bounds remain with
the configuration owner, while an exhausted remaining approval wait retains zero.

## Durable identity consequences

Moving the nominal binding/fixture/initial symbols changes generated source and
two conservative fold fingerprints. Preserve the native NominalBindingChanged,
NominalFixturesChanged, NominalInitialChanged and AggFoldSurfaceChanged warnings
and the affected replay report; do not call the move replay-neutral. The conversion
bodies, initial values, canonical identities, binding versions and fixtures remain
unchanged. Rebuild every consumer and run the complete nominal/codec/replay and
application scenarios.

All four aggregates use Never with no state codec. No snapshot-bearing application
consumer is introduced to manufacture an invalidation case. This is the unused
first-release candidate under ADR-27, with fresh provisioning and same-build
recovery qualification; it is not a populated-deployment upgrade promise. Subsequent
changes must still follow the normal evolution and workflow-versioning gates.

## Alternatives rejected

Keeping generic buckets merely to preserve Haskell symbol paths leaves the actual
ownership defect and an unnecessary pre-release compatibility shim. Copying one
supervisor, loader, registry or SDK lifetime into every concept creates competing
owners. Treating every role namespace as automatically allowed makes a closed list
ineffective. Rewriting the frozen producer standard or forging its generated
headers would misstate the source being adopted.

## Consequences

Module movement changes Haskell imports, not delivery, cleanup, authentication or
identity bytes. The shared name encoder retains its existing ASCII and Unicode
vectors. The checker prevents accidental technical namespaces while package tests
retain sibling and light-library dependency budgets. The finite local exceptions
remain visible for review; future changes cannot cite this record as permission to
add arbitrary composition behavior.

## References

[Package architecture](../architecture/packages.md),
[ADR-3](0003-a-seventh-package-keeps-one-off-agent-runs-light.md),
[ADR-32](0032-the-migration-cli-keeps-a-dedicated-configuration-boundary.md),
[ADR-38](0038-runtime-startup-and-maintenance-share-validated-owners.md),
[ADR-71](0071-first-release-inspection-is-an-isolated-administrative-runtime.md),
[the cross-cutting guide](mori://shinzui/keiro-runtime-patterns/docs/architecture-cross-cutting-modules),
[the vertical-slice guide](mori://shinzui/keiro-runtime-patterns/docs/architecture-vertical-slice-modules),
and [ExecPlan 107](../plans/107-adopt-current-haskell-and-service-architecture-practices.md).
