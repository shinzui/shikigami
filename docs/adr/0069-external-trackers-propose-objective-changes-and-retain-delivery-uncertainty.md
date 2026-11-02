# 0069. External trackers propose objective changes and retain delivery uncertainty

Date: 2026-10-29

Status: accepted; provider-neutral implementation qualified, Rei integration pending

## Context

People may plan work in Rei or another tracker while Shikigami executes an objective
across runs. External records do not carry Shikigami's assignment epochs, accepted
operations or integrated acceptance evidence. A copied status cannot replace those
facts. External APIs also differ in conditional writes, ordering and retry guarantees.

The Rei source inspected at `515c6c0c6dd0527eb7184825d8bb75acdbde68ec` exposes a
v2 HTTP API. Its intention read model includes a stream position but is projected
asynchronously. Its action endpoint generates a new action ID per request and accepts
no caller idempotency key. A local receipt cannot close the crash window between a
remote append and acknowledgement persistence.

## Decision

Keep objective execution state authoritative in Shikigami. A versioned binding links
an objective to a resource under a configured connection incarnation, provider revision
and explicit field policy. A passive external reference grants neither network nor
objective authority. Binding admission requires objective permission and connection-use
permission; external actor labels do not become local principals.

External edits are retained observations and proposals. Applying one uses the existing
objective command owner, current permission and exact expected local revision. The
decision, objective change, receipt and resulting publication intents share one
transaction. Initial binding never overwrites local content. Stale local or external
bases produce visible conflicts. Completion remains evidence-validated; external
completion, deletion or reopening cannot silently complete, delete or revive local work.

The objective commit records immutable, bounded publication payloads for active
bindings in the same transaction. Network dispatch occurs afterward under current export
authority. A delivery receipt is independent of the objective status and transport queue.
Pausing, detaching or changing a mapping preserves outstanding attempt and receipt facts.
Bindings and publications retain a digest of the configured endpoint, account and provider contract. Current composition must match that digest before network access. Old and new incarnations can coexist for reconciliation. Connection replacement uses a new incarnation; it cannot reset old source versions or
redirect an accepted publication to a different remote account.

Providers declare and prove their capabilities. Unknown effects never retry merely
because a local lease expires. Safe redispatch requires a still-valid remote deduplication
guarantee or proof of non-application with no surviving request. Otherwise quarantine
the operation and retain Unknown until authorized reconciliation establishes an outcome.
Retiring a transport row into quarantine acknowledges quarantine only, not delivery.
An empty eventually consistent read cannot prove an action did not happen.

The first concrete adapter binds existing Rei intentions, observes note guidance as
instructions proposals, retains lifecycle observations, and publishes attributable
progress summaries as actions. It does not automatically create, complete or reopen
intentions. An outbound attribution marker is not an idempotency key. Unknown append
results remain quarantined; remote action evidence or explicit audited attestation may
resolve them without sending another action. Attestation is a typed, idempotent command
with explicit operator reconciliation permission, immutable publication/attempt identity,
expected receipt revision and an exact remote receipt whose resource and payload have
been verified through the provider. It records the authenticated actor and reason and
distinguishes operator-attested delivery from provider proof. Neither a marker nor a
free-text assertion suffices; attestation cannot prove non-application or authorize
resend. Suppression of future sends preserves any existing Unknown outcome. Credentials and manager lifetimes remain
at process boundaries, and runtime integration never shells out to a CLI.

## Alternatives rejected

Replacing the local store would require every tracker to implement fencing and durable
execution semantics. Bidirectional last-write-wins would erase instructions or evidence.
Treating remote completion as local acceptance would bypass integrated checks. Retrying
non-idempotent appends after timeout would create duplicate actions. A mock-only adapter
test would fail to prove the actual provider's semantics.

## Consequences

The shared engine, concrete Rei adapter and supported API/CLI qualification are separate
children of MasterPlan 18. The shared engine owns production dispatch and reconciliation
transitions as well as receipts; process loops only schedule that engine. Both publication
and post-success outbox reconciliation route by destination, so quarantine cannot be
interpreted by the legacy sink handler as delivery. The engine is tested with strong and weak deterministic
providers; Rei is additionally tested against its real disposable API server, including
lost responses and projection lag. The provider-neutral implementation declares a separate preserved tracker projection group, with one writer per target. Both the objective and tracker projections consume the same ObjectiveLifecycle source and execute under both catalog fences in one append transaction. A technical tracker event does not advance the objective semantic revision. Proposal application uses an actor-pinned callback through the existing objective command owner; it cannot write objective rows independently or change public command fingerprints.

Publication records retain their original timestamp, full request digest and destination fence. Attempt claims are separate from immutable provider attempts, so claim renewal cannot change a replayed request. Receipt lookup uses a protected typed command result; dispatch barriers and the latest export base use bounded indexed queries independently of the public inspection limit. [Provider-neutral qualification](../evidence/plan-103/qualification.json) passes 22 focused unit cases, 34 PostgreSQL cases, the broader package regression, complete build and 177 native conformance checks. The technical event adds a fold-surface warning without changing existing registers or old-event folding; generated fingerprints invalidate native snapshots automatically. The concrete Rei adapter and public serving gate remain pending.
MasterPlan 17's no-Rei feature and acceptance gate remain independently useful.

## References

- [MasterPlan 18](../masterplans/18-integrate-durable-objectives-with-external-trackers-through-provider-neutral-contracts-and-rei.md)
- [ADR 0022](0022-the-journal-ends-at-enqueue-and-receipts-own-delivery-truth.md)
- [ADR 0067](0067-objective-checkpoints-use-assignment-scoped-preconditions.md)
- [ADR 0068](0068-objective-creation-has-authority-before-association.md)
- `mori://shinzui/rei/okf/adrs/concepts/ADR-53`
- `mori://shinzui/rei/okf/adrs/concepts/ADR-62`
- `mori://shinzui/rei`, project-relative
  `rei-api-contract/src/Rei/Intention/Api.hs`,
  `rei-api-contract/src/Rei/Intention/Wire.hs` and
  `rei-api/src/Rei/Intention/WriteHandler.hs` (artifact-level source URIs pending).
