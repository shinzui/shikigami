# Current first-release domain qualification

Plan 93; accepted pre-reset source `88d4b3e`; qualified 2026-10-30.
The four unused-service facts are recorded in the plan and ADR-27. No developer
DB was changed. The strict differ exits 1 and preserves every breaking finding in
[first-release-reset-diff.json](first-release-reset-diff.json), with the separate
[replay report](first-release-reset-replay.json). This is the new first-release
baseline; it is not permission to reset deployed history.

## Executed evidence

- Whole consuming build, all seven packages and enabled test components: passed.
- Core pure: 539 passed; core PostgreSQL: 373 passed, serially (104.90 seconds).
- Queue producer/consumer/route/reconciled DLQ subset: 13 passed.
- Generated service conformance: every assertion passed, including all four
  aggregate behavior contracts, structural enum laws and three nominal bindings.
- RunEvidence domain report: missing/pending/duplicate/stale/failed all empty;
  honest unverified guards remain unverified. No solver uncertainty is relabelled.
- Diagram suite: 6 passed, including complete atlas validation and checked-in
  artifact comparison. `just domain-diagrams` regenerates both documents.
- Strict Language 6 check, binding explanation, deny-warnings, exact current
  inspection and unchanged second scaffold: passed. Scaffold changed zero files.

## Current consumer decisions

The ten-member workspace is enumerated in
[the domain inventory](../../architecture/shikigami-domain-inventory.md).
ExecutionLifecycle, WorkerSessionLifecycle and ObjectiveLifecycle now carry the
actual application newtypes through command/event/register fields. Their total
Text isomorphisms have empty, technical-coordinate and Unicode fixtures.
These are technical identities: no TypeID parser or generator is substituted.
Generated initial bindings seed the exact empty wrapper. Current application
admission still validates the authority and relational identity before a write.

`RunTriggerKind` and `RunRouteKind` are exhaustive structural enums used directly
by the generated queue. Their old Aeson spellings are retained. The two application
Text conversion functions are removed; both directions of the binding pattern
match every constructor. Conformance checks every generated shape and fixture.
There is no enum-valued lifecycle guard: lifecycle phases are vertices. Therefore
no enum-equality fold segment, arbitrary enum guard, or false proof was added.

Every existing transition guard/write is generated-owned. No transition hole or
custom transducer adapter remains to replace with mapped construction. The three
nominal register initials are declared and exercised. No register constructs a
rich mapped value from a scalar or clears one independently, so no scalar
write-lift is declared. Current rich protected payload writes remain SQL authority
inside their accepted transaction, not a pure transducer function.

Ordered lineage is already a required `List Text` in the actual run-job queue;
the independent wire test proves order and repeated values. There is no declared
public integration contract with a list consumer: external Danwa and sink HTTP
protocols remain hand-owned. No Kafka publisher, process manager, reaction runner,
date, text-set, ID-keyed map, or unrestricted byte codec consumer was invented.
Fixed-length digests and refined names are not total bindings over unrestricted
bytes/Text. Opaque upstream identities and rejecting parsers remain explicit.

`RunJobs.domainCodec` now has one complete schema-version-1 envelope and no
upcasters. The current producer and consumer move together. Required nullable
execution fields must be present; absent current fields and obsolete envelopes
reject. FRIC-9 remains a real released queue-generator limitation: optional top-level
fields are not lowered by the generated queue codec. The small application wrapper
therefore owns current required/nullable fields, while the generated payload codec
owns its declared fields. No historical reader remains to work around that limit.

AgentRun's seven and DanwaConversation's two obsolete patch selections are gone
from production bodies and declarations. Current step and child labels remain.
Real non-Skill inline conversations and actual workspace selection remain runtime
choices. Synthetic patch-mechanism recovery tests remain for future evolution.
Native PostgreSQL coverage includes current crash/replay, child completion,
cancellation, stale authority, committed response loss and exact receipt recovery.

## Wire, fold, replay and snapshots

The independent execution-event golden still encodes identity as a JSON string
and decodes to the application newtype. Full service conformance crosses every
private event codec and checks forward/replay register equality and independent
accepted/rejected histories. All current aggregate edges emit exactly one event;
there is no multi-event in-flight pagination/truncation consumer. Runtime hydration
uses released structured Keiro errors; no partial state fallback is introduced.

[Fold identities](current-fold-identities.json) compare every declaration with
`88d4b3e`: the three new nominal consumers change their own fold; RunEvidence is
unchanged. All four EventStream definitions use `Never` and `stateCodec = Nothing`.
No aggregate snapshot cache exists to admit or corrupt, so a fabricated stale-cache
fallback test would not exercise production. Workflow journals remain real and
same-build native recovery passed. Post-deployment snapshot adoption must qualify
its actual codec, discriminator and corrupt/stale fallback before enabling it.

## Catalog authority and remaining operational owners

The guarded protocol, retained late rollback sites and indexed lock order are
qualified in [guarded-execution-protocol.md](guarded-execution-protocol.md).
The validated shared catalog preserves every owner's projection set; rich
execution/evidence payloads are LiveOnly, PreserveAndReconcile and cannot be
reconstructed from lifecycle events. No destructive replay is claimed.
Catalog startup and bound writers are existing production consumers; online
rebuild/generation/SQL-contract operations and their administrative exposure are
reviewed with plan 106's operations owner. Delivery/freshness and transient caller
policy are reviewed with plan 94. Those evidence obligations stay pending until
their owning children execute them; this document does not certify those children.

## Regeneration and source tooling

The consuming code imports no `Keiro.Dsl.*` library module. AST record additions,
located frontend/index construction, ordinal persistence and composition of DSL
planning APIs therefore have no application caller. The pinned released CLI owns
those boundaries. All ten members explicitly declare Language 6; CI checks exact
version and truthful candidate metadata. The collocated idiomatic-v2 ledger and
complete Cabal fragment are reconciled, with hand-owned exports accounted for.
The second scaffold preserved filled bindings/holes and changed no source bytes.
Strict breaking reports were written before the differ's failing exit. Generated
modules were edited only by the released scaffolder.

The complete source-derived atlas includes the four persisted aggregates and the
only hand-authored Keiki machine, the diagram-only at-risk flow. Its documented
state-changing-epsilon exception is restricted to that non-event-source diagram;
all persisted aggregates retain default validation. The OpenTelemetry workflow
has a separate static workflow diagram, not an unlisted Keiki transducer. No
sequential/feedback transducer pipeline exists to migrate to checked composition.
