# 0088. Run keys separate caller and trigger coordinates

Date: 2026-10-31

Status: accepted

## Context

A public producer probe showed that two different agents given the same addressed
caller key derive one workflow identity. It also constructed an empty full key
that the complete generated queue decoder rejected. RunKey exported its unchecked
constructor and domain/store interfaces discarded it into Text.

Two real PostgreSQL regressions then accepted two jobs each but obtained only one
workflow identity: equal addressed caller keys across agents, and integration
coordinates `a:b`/`c` versus `a`/`b:c`. The native integration envelope explicitly
owns an opaque application message id. Reinterpreting it as a UUID or rejecting
its separators would discard valid input instead of fixing the delimiter join.

## Decision

RunKey is a private, nonempty opaque native workflow coordinate with exact string
codecs and no Generic, Num or IsString construction. Checked restoration accepts
the native protocol's nonempty text. Structurally nonempty prefixes support pure
owner-versioned factories; canonical native UUID capture preserves exact child
workflow ids. Run acceptance, lifecycle refusals, their SQL statements and status
joins retain RunKey rather than unwrapping it inside domain/store APIs.

The addressed trigger's caller RequestKey is a separate private nonempty string.
It preserves established Unicode, whitespace and control-character values. The
HTTP API's existing 1..200/no-control RequestKey remains a distinct type with its
own policy. An empty addressed key refuses at CLI parsing before configuration,
stdin or database work. A caller key is never accepted as a full run coordinate.

Commit structured JSON fields under explicit protocol versions:

- Stream keys use `stream-run-v2:` and `shikigami.stream-run/2`, retaining agent
  and the external activity id in separate fields.
- Integration keys use `event-run-v2:` and `shikigami.integration-run/2`, retaining
  agent, selected route and native opaque message id separately.
- Addressed keys use `addressed-run-v2:` and `shikigami.addressed-run/2`, retaining
  agent, route and either an explicit caller key or the default payload.
- Scheduled keys use `schedule-run-v2:` and `shikigami.scheduled-run/2`, retaining
  agent and due time separately.
- One-off CLI keys use `cli-run-v2:` and `shikigami.cli-run/2`, retaining agent
  and a fresh native UUIDv4 invocation nonce. Do not allocate an unused Kioku
  session id as a request nonce.

The existing versioned digest and native run-job workflow-id adapter own the
rendering. HTTP v2 key bytes and structured delegation child UUIDs remain
unchanged. Delegated jobs capture the same canonical child UUID directly;
execution-operation key bytes remain unchanged. Queue envelopes and valid opaque
key codecs retain their existing shapes. Trigger inbox/send atomicity, native
message redelivery deduplication and same-build recovery remain mandatory.

These are technical runtime deduplication/attribution coordinates consumed by
Keiro, not allocated application entity ids or TypeID-v7 allocations. The native
envelope remains the authority for external message identity; broker offsets
remain delivery metadata.

## Alternatives rejected

A raw caller key cannot serve as a globally scoped workflow identity. Adding
another delimiter leaves the same ambiguous coordinate problem. Restricting
valid agent/message strings hides it and forks the native contract. A random id
for every delivery destroys retry deduplication. Reusing a Kioku session id as a
nonce mixes unrelated ownership without creating a real session. An unchecked
constructor or Generic instance would reopen empty-key admission.

## Consequences

Fresh stream, integration, addressed, scheduled and one-off CLI identities change
under ADR-27's confirmed unused first-release baseline. There is no old-key factory
fallback or populated cross-build replay promise. Native helper-reference facts
can remain unchanged while producer identity meaning changes; a neutral differ
report does not establish old queue/timer/input compatibility. Subsequent deployed
evolution follows ordinary workflow versioning rules.

Retain the before probe and failed database regressions. Qualify distinct accepted
coordinates, stable redelivery, complete queue/codecs, typed SQL restore and private
construction before accepting this candidate. The full scalar/allocated-identity
census and final Linux/runtime qualification remain open.

## References

[ADR-27](0027-the-first-release-establishes-one-clean-durable-baseline.md),
[ADR-86](0086-versioned-structured-coordinates-identify-delegated-and-http-runs.md),
[ADR-87](0087-agent-values-retain-checked-meaning-and-separate-compatibility-scopes.md),
[workflow versioning](../workflow-versioning.md),
[ExecPlan 107](../plans/107-adopt-current-haskell-and-service-architecture-practices.md),
[the retained producer probe](../evidence/keiro-0.22/trigger-key-before-probe.json),
[the failed database controls](../evidence/keiro-0.22/trigger-key-before-regressions.txt),
and [the scalar standard](mori://shinzui/keiro-runtime-patterns/docs/architecture-domain-newtypes-and-typeids).
The native envelope belongs to `mori://shinzui/keiro`, at
`keiro-core/src/Keiro/Integration/Event.hs`; its artifact-level source URI is pending.
