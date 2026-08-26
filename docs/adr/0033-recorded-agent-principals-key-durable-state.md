# 0033. Recorded agent principals key durable state

Date: 2026-08-26

Status: accepted


## Context

An agent declaration name used to perform two incompatible jobs. It was a mutable address used
to select a declaration, and it was also the durable subject written into queued work, Kioku
sessions and memories, sink grants, and outbound authorship. Renaming a declaration therefore
lost memory and permission continuity even when the principal directory said the old and new
presentations were the same agent.

Resolving the name again later does not repair this. A run may wait in a queue, a workflow may
replay after deployment, and a sink intent may publish long after admission. A later name lookup
can select a replacement subject, while copying a parent's identity into delegated work falsely
attributes the child. Durable work needs the exact identity admitted at its own boundary.

Existing Kioku history was written under name-derived scopes. Kioku is an event-sourced upstream
system and exposes no supported scope rewrite. Updating its projection tables would be undone by
replay, while copying memories into a new scope would duplicate append-only facts. Shikigami must
retain that history without taking ownership of Kioku's storage.

Directory-disabled development also remains supported. Treating its self-asserted names as
directory-verified principals would make production and compatibility authority
indistinguishable, so the two modes require distinct durable representations.


## Decision

**Names and handles locate agents; a recorded agent identity identifies durable work and keys its
state.** Fresh admission resolves a declaration through the local principal-directory snapshot
and records either `VerifiedIdentity agent_...` or an explicit `CompatibilityIdentity`. A third
`UnresolvedLegacyIdentity` state exists only to decode pre-change `RunJob` and `SinkIntent` bytes.
It must be promoted once at the next admission or publish boundary before any new effect.

Verified identity is immutable for the life of the admitted work. It supplies the queued input,
Kioku scope and actor, session lineage, grant subject, sink intent, lifecycle recheck, and outbound
actor or author. Delayed and replayed work uses that recorded principal; it never substitutes a
current handle match. A delegated child is admitted independently and records the child's
principal, while the parent relationship remains lineage rather than identity inheritance.

Configured directory operation fails closed. Fresh admission and legacy promotion require an
active principal, and publish-time lifecycle checks address the exact recorded principal. A
verified grant lookup uses only `(principal_id, sink_kind)` and never falls back to a null-principal
name row. Directory-disabled operation uses a visibly self-asserted compatibility identity and
the separate `(agent_name, sink_kind)` compatibility key.

Legacy memory continuity is metadata at the Shikigami boundary. The
`shikigami.agent_scope_aliases` table maps a verified principal to accepted legacy agent-name
scopes and permits one owner per legacy name. Verified recall queries the principal scope and its
aliases through Kioku's public APIs, merges by stable memory id, orders deterministically, and
applies the requested limit after deduplication. Shikigami neither rewrites nor copies Kioku
events or projections.

`shikigami agents sync` owns reconciliation because it can join the current directory, legacy
Kioku namespaces, and grant evidence. Exact joins may reconcile automatically; renamed history
requires an explicit `LEGACY_NAME=agent_...` mapping. Missing, stale, invalid, conflicting, and
multiply claimed mappings are reported, left unchanged, and make the command fail.

Outbound attribution changes only contracts that already possess an actor or author field: Kawa
`Actor.id`, Kizashi `actor`, and Danwa `PostMessageRequest.author`. Danwa's configured participant
remains transport/session configuration. Shikigami does not invent identity fields in ReiAction
or Kanmon payloads and does not rewrite inbound human authorship.


## Alternatives rejected

**Continue keying durable state by declaration name.** Rejected because an ordinary presentation
rename would remain a state fork, and queued or replayed work could change subject after
admission.

**Resolve the declaration name at each effect boundary.** Rejected because mutable lookup can
substitute a different principal. Lifecycle may be refreshed, but identity must be rechecked by
the exact recorded principal.

**Use one nullable or optional principal without explicit identity states.** Rejected because
missing legacy bytes, directory-disabled compatibility, and verified directory authority have
different safety properties. Conflating them invites fallbacks that silently upgrade
self-assertion to verified authority.

**Copy the parent's identity to delegated children.** Rejected because delegation records
ancestry, not subject equivalence. It would key child memory and authorship to the supervisor.

**Rewrite Kioku projections or copy legacy memories.** Rejected because projection SQL is not a
supported durability boundary and copying append-only history creates duplicate facts. Alias
metadata plus composed public reads preserves one authoritative history.

**Force every grant row to have a principal.** Rejected because explicit directory-disabled
development is a supported compatibility mode. Partial unique keys keep compatibility bounded
without allowing verified lookup to fall through to it.


## Consequences

A presentation rename retains verified memory, grants, lineage, and outbound authorship when the
directory principal remains unchanged. Operators must explicitly reconcile a renamed legacy
scope, and the mapping is idempotent and auditable. Ambiguous or malformed evidence stops the
sync command instead of guessing.

Every fresh durable producer must carry a resolved identity, and every consumer must refuse an
unresolved legacy identity until its designated one-time promotion boundary. Hand-written
additive codecs preserve old queue and outbox bytes while making new identity explicit.

Grant storage has two intentionally disjoint uniqueness domains. Verified rows survive
presentation changes because the principal is the key; compatibility rows remain name-keyed and
cannot satisfy verified checks. Lifecycle changes still take effect at admission and publish,
but a handle rename cannot change the subject of already admitted work.

Recall performs one public Kioku query per accepted scope before deduplication. The additional
reads are the cost of retaining legacy history without corrupting upstream ownership. Alias
growth is operator-controlled and one legacy name can never fan out to multiple principals.


## References

* [`docs/plans/54-key-durable-agent-state-by-meibo-principal.md`](../plans/54-key-durable-agent-state-by-meibo-principal.md)
  — implementation plan and acceptance evidence.
* [ADR 0011](0011-defaulted-agent-fields-preserve-journal-codec-compatibility.md) — additive
  durable codecs for old workflow values.
* [ADR 0014](0014-a-run-job-declares-its-route-rather-than-being-guessed.md) — durable input is
  recorded instead of re-derived later.
* [ADR 0021](0021-operator-verbs-wrap-the-owning-library.md) — reconciliation stays at the owning
  operator boundary.
* [ADR 0022](0022-the-journal-ends-at-enqueue-and-receipts-own-delivery-truth.md) — delayed publish
  and terminal non-send evidence.
* [ADR 0024](0024-a-configured-principal-directory-fails-closed-to-its-last-valid-snapshot.md) —
  directory admission and lifecycle policy.
* `mori://shinzui/kioku/packages/kioku-api` and
  `mori://shinzui/kioku/packages/kioku-core` — supported memory, session, and recall boundary.
* `mori://shinzui/meibo` — canonical principal and lifecycle owner.
* `mori://shinzui/danwa` — outbound message-author contract.
