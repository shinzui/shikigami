---
id: 54
slug: key-durable-agent-state-by-meibo-principal
title: "Key durable agent state by Meibo principal"
kind: exec-plan
created_at: 2026-08-19T04:20:16Z
intention: "intention_01m0c3z1v8evbv3qpv0dncc05e"
master_plan: "docs/masterplans/4-identity-and-trust-grants-outbound-auth-and-agent-lifecycle-control.md"
---

# Key durable agent state by Meibo principal

This ExecPlan is a living document. Keep Progress, Surprises & Discoveries, Decision Log,
and Outcomes & Retrospective current as work proceeds. If implementation changes a durable
architectural rule, distill it into `docs/adr/` before completing the plan.


## Purpose / Big Picture

Today a declaration name is both an address and a durable identity. It selects an agent, names
the Kioku memory scope, keys outbound grants, identifies a queued run, and becomes downstream
authorship. Renaming an agent therefore loses continuity even when the organizational directory
says it is the same agent.

After this plan, Shikigami resolves a declaration name once at admission and records an immutable
Meibo agent principal such as `agent_01jf2m0c3z1v8evbv3qpv0dncc`. That recorded identity travels
with the durable run, keys new memory and grants, and supplies outbound attribution. Names and
handles locate an agent; a principal identifies it. Directory-disabled development remains
available through an explicit compatibility identity that cannot be confused with a
directory-verified principal.

Existing Kioku history is retained without rewriting dependency-owned event projections. A
Shikigami-owned alias table maps a verified principal to its legacy name scopes, and recall reads
the principal scope plus accepted aliases. This makes an explicit rename retain history without
copying memories.

The observable acceptance is a rename: run an agent, record memory and a grant, change its
presentation name while retaining the same principal, restart Shikigami, then show that recall,
permission, and outbound authorship still follow that principal.

This plan implements
[`IR-9`](../improvement-requests/key-agent-continuity-by-meibo-principal.md), canonically
`mori://shinzui/shikigami/okf/improvement-requests/concepts/IR-9`.


## Progress

- [x] (2026-08-26T16:22:34Z) Refreshed the plan against the landed directory, current ADRs,
      seven-package tree, Kioku 0.5.0.0, durable workflow rules, and actual sink/CLI boundaries.
- [x] (2026-08-26T16:22:34Z) Confirmed plan 23 is complete and `Shikigami.Directory` supplies the
      cached projection and lifecycle admission seam.
- [x] (2026-08-26T16:22:34Z) Cleared the dependency gate: this plan consumes the local cached
      projection and Kioku 0.5.0.0 public APIs; it needs no Meibo or Shomei package pin.
- [x] (2026-08-26T16:22:34Z) Established a green baseline with
      `nix develop -c cabal build all --dry-run` and `nix develop -c cabal test all -j1`.
- [x] (2026-08-26T18:08:00Z) M1: defined verified, compatibility, and legacy-unresolved agent identities; recorded identity
      on every fresh `RunJob`; decode old jobs compatibly; promote a legacy job once at admission.
- [x] (2026-08-26T18:08:00Z) M2: keyed Kioku scopes and access contexts by recorded identity, used the supported contextful
      session/memory/recall APIs, and remove Shikigami's Kioku deprecation warnings.
- [x] (2026-08-26T17:38:08Z) M3: added the legacy-scope alias schema/store, principal-plus-alias
      recall with post-merge deduplication, and `agents sync` discovery plus repeatable explicit
      `--alias LEGACY_NAME=agent_...` reconciliation that leaves ambiguous mappings untouched.
- [x] (2026-08-26T17:38:08Z) M4: made verified grants unique and addressable by principal,
      retained only null-principal name-keyed compatibility grants, and changed operator
      grant/revoke to resolve identity under the configured directory before writing.
- [x] (2026-08-26T17:38:08Z) M5: carried recorded identity through `SinkIntent`, promoted old
      intents once before publish, rechecked exact-principal lifecycle and grants, and attributed
      Kawa, Kizashi, and Danwa output to the durable identity.
- [x] (2026-08-26T18:00:39Z) M6: proved the workflow edits replay-neutral with
      `just keiro-gate 08c27cb`, passed the warning-focused build, full suite, and migration
      apply/replay checks, captured the disposable rename proof, and recorded ADR 0033.


## Surprises & Discoveries

- The prerequisite is already complete. Plan 23 landed `Shikigami.Directory`, including an
  atomically refreshed snapshot that rejects duplicate normalized handles and duplicate principal
  ids before either can enter the hot path. Runtime resolution therefore has exact, missing, or
  unavailable outcomes; ambiguity is a snapshot-load failure, not a successful lookup result.

- No Meibo dependency is required. The runtime intentionally consumes a narrow cached projection
  owned by `Shikigami.Directory`, rather than importing the Meibo client or domain packages.
  `mori://shinzui/meibo` still has no Hackage release or upstream tag, but that fact no longer
  gates this plan.

- Kioku is pinned at 0.5.0.0, not 0.4.1.0. The release exists on Hackage and upstream tag
  `v0.5.0.0` resolves to commit `cb5f35e`. Its `PrincipalRef` and scope rules admit Meibo
  `agent_…` identifiers verbatim.

- Kioku is event sourced and exposes no supported re-key or re-scope operation. Directly updating
  its read-model rows would be overwritten by projection replay. Its public
  `Memory.getActiveRowsInNamespace` and explicit recall APIs are sufficient to discover and read
  old scopes, so Shikigami can own aliases without mutating dependency state.

- The migration executable is deliberately pg-migrate-only. ADR 0032 keeps its configuration
  boundary narrow, and ADR 0021 requires operator verbs to wrap the state owner's supported
  library. The existing `shikigami agents sync` command is the correct reconciliation boundary.

- Directory-disabled development and fresh seed grants make a globally `NOT NULL` principal key
  incorrect. Verified rows need principal uniqueness; compatibility rows need a distinct,
  visibly name-keyed uniqueness rule.

- The inbound Danwa `AddressedMessage.author` is consumed human authorship, not an outbound field.
  ReiAction and Kanmon payloads have no actor field. The real outbound identity fields are Kawa
  `Actor.id`, Kizashi `actor`, and Danwa `PostMessageRequest.author`.

- `RunJob` is already journaled as `ingest-job`. A backward-compatible optional identity member
  can preserve old bytes while fresh jobs carry identity; the workflow may consume it without
  changing step names, types, or order. This still requires the repository's Keiro gate.

- The pre-change baseline is green across every selected suite. In particular,
  `shikigami-core-test` passed 568 tests, `shikigami-server-test` passed 43, and
  `shikigami-client-test` passed 3.

- Delegated work cannot inherit the parent's recorded identity. That made both specialist child
  sessions appear to be the supervisor. The delegation boundary now admits the target declaration
  and persists that exact child identity on the child `RunJob`; lineage still records the parent
  relationship independently.

- `just keiro-gate` runs `git diff --exit-code -- shikigami-core/src` after deterministic
  scaffolding. Workflow-body changes therefore have to be staged before the gate can distinguish
  them from generated drift; the gate is run on the staged milestone immediately before commit.

- Kioku's public contextful turn helper cannot share the SQL transaction that atomically appends
  the assistant turn, workflow journal event, and sink outbox row. The conversation path therefore
  uses Kioku's public session command/event stream with `runCommandWithSqlEvents`; the command
  still records the admitted identity and Kioku's inline projection in the one existing
  transaction.

- Alias discovery can use the public Kioku namespace query without learning Kioku's tables.
  Principal-bearing grant rows are also useful identity evidence after a presentation rename;
  null-principal grant names require either an exact current handle join or explicit `--alias`.
  Duplicate explicit claims are accumulated and reported before any alias row is written.

- One schema boundary can safely introduce aliases and the grant partial indexes together. The
  migration preserves every existing grant row, adds no Kioku mutation, applies on a fresh
  database, and replays as a no-op through the repository migration harness.

- Malformed explicit alias input initially remained outside the discovered candidate set. A
  malformed mapping for a name that also had an exact current-directory join could therefore be
  reported invalid while automatic reconciliation inserted the alias. Explicit invalid input now
  blocks every other claim for that legacy name, and a disposable-database regression proves that
  it writes no row.


## Decision Log

- Decision: consume the landed local directory projection and add no Meibo/Shomei source package.
  Rationale: identity admission only needs the principal text and lifecycle already supplied by
  `Shikigami.Directory`; a direct client would duplicate plan 23's ownership and introduce an
  unnecessary release gate.
  Date: 2026-08-26

- Decision: represent durable identity as a sum of `VerifiedIdentity AgentPrincipal`,
  `CompatibilityIdentity Text`, and `UnresolvedLegacyIdentity`.
  Rationale: configured operation must distinguish directory-verified identity from the explicit
  directory-disabled development path. The third state exists only to decode old `RunJob` and
  `SinkIntent` bytes and is promoted before fresh durable work continues.
  Date: 2026-08-26

- Decision: resolve identity once when fresh work is admitted, persist it on `RunJob`, and recheck
  lifecycle by the exact recorded principal rather than by the mutable declaration name.
  Rationale: replay, delayed queues, and delegated children must retain the admitted subject even
  if directory presentation changes later. Falling back from a recorded principal to a handle
  would silently switch identities.
  Date: 2026-08-26

- Decision: admit a delegation target as its own subject and persist the child's identity on the
  child job; never copy the parent's identity into the child.
  Rationale: delegation establishes ancestry, not identity equivalence. Copying the parent
  principal causes the child's memory, session, and authorship to be attributed to the wrong
  subject.
  Date: 2026-08-26

- Decision: preserve old queue and journal bytes with a hand-written additive codec.
  Rationale: omitting `UnresolvedLegacyIdentity` on encode and defaulting a missing member on
  decode keeps frozen legacy fixtures stable. Newly produced jobs must never use the unresolved
  state. This follows ADR 0011 and ADR 0014.
  Date: 2026-08-26

- Decision: key Kioku access and new scopes by the recorded identity and migrate every Shikigami
  call to the supported contextful APIs in this plan.
  Rationale: a real principal is now available, and keeping deprecated wrappers would preserve the
  very self-asserted write path this plan replaces.
  Date: 2026-08-26

- Decision: preserve legacy history with a Shikigami-owned alias table and composed public Kioku
  reads; do not rewrite or copy Kioku data.
  Rationale: direct read-model SQL violates the dependency boundary and is not durable under
  projection replay, while copying append-only memories creates duplicates. One legacy scope may
  belong to at most one principal.
  Date: 2026-08-26

- Decision: extend `shikigami agents sync` for grant and alias reconciliation; do not add a
  `shikigami-migrate` verb.
  Rationale: reconciliation composes directory, Shikigami tables, and supported Kioku reads. The
  migration executable remains the direct `DATABASE_URL`/pg-migrate adapter defined by ADR 0032.
  Date: 2026-08-26

- Decision: use partial uniqueness for grants instead of forcing every row to have a principal.
  Rationale: configured work is keyed by `(principal_id, sink_kind)` while explicit disabled-mode
  compatibility remains keyed by `(agent_name, sink_kind)`. Neither path may fall through to the
  other.
  Date: 2026-08-26

- Decision: change only outbound schemas that already possess an author or actor field.
  Rationale: principal attribution belongs in Kawa, Kizashi, and Danwa fields Shikigami produces;
  inventing fields for ReiAction/Kanmon or rewriting inbound human authorship would exceed IR-9
  and change upstream contracts.
  Date: 2026-08-26

- Decision: do not add a workflow patch unless implementation changes a journal step's name,
  type, order, or prior-run behavior.
  Rationale: the identity is an additive, backward-compatible member of an already journaled
  input. Legacy jobs take an explicit compatibility promotion path. This is the input-driven
  compatibility pattern documented by ADR 0011, but `just keiro-gate` remains mandatory evidence.
  Date: 2026-08-26

- Decision: an invalid explicit alias mapping is authoritative negative evidence for its legacy
  name during that sync invocation.
  Rationale: operator input must never be reported invalid while a lower-priority automatic join
  mutates the same name. The command leaves the alias untouched and exits non-zero so the operator
  can correct the mapping deliberately.
  Date: 2026-08-26


## Outcomes & Retrospective

The implementation makes admitted identity one durable value from queue to output. Fresh work
records a verified principal or explicit compatibility identity; old jobs and sink intents retain
their frozen bytes and take one bounded promotion path. Kioku sessions, memory, recall, grants,
delegated children, delayed publish, and Kawa/Kizashi/Danwa attribution now consume that recorded
value. Presentation names remain selectors and audit evidence, not durable keys.

The refresh removed three unsafe implementation directions before code changed: a new direct
Meibo dependency, SQL mutation of Kioku projections, and an operator command in the migration
executable. The landed design instead uses the local directory projection, public Kioku 0.5.0.0
APIs, Shikigami-owned metadata aliases, disjoint verified/compatibility grant indexes, and the
existing `agents sync` boundary. The late invalid-mapping audit also closed the only case where
bad explicit input could have coincided with an automatic alias write.

The workflow proof was replay-neutral. `just keiro-gate 08c27cb` accepted the staged workflow
changes without a patch id: step names, types, order, generated modules, and prior-run behavior
remain compatible. `nix develop -c cabal build all --enable-tests -j1` passed. The repository-wide
test command passed all suites, including 575 core tests, 46 server tests, 81 worker tests, 29
one-off agent tests, 15 API tests, 3 client tests, the Keiro conformance suite, and both migration
suites. Fresh migration apply plus replay passed, and the repository-scoped deprecation search
found no production use of Kioku's legacy memory/session/recall wrappers.

The rename proof uses a fresh migrated PostgreSQL database for every database-backed case. The
core restart case writes the legacy memory and alias, converts the grant to principal ownership,
updates its presentation from `heartbeat` to `heartbeat-renamed`, closes the first store, opens a
new store on the same database, and asserts recall plus the grant still resolve as
`agent_heartbeat`. The sink-delivery case separately asserts that the admitted outbox identity and
Kioku session actor are `agent_heartbeat` before a lifecycle refresh, and the Kizashi case inspects
the actual request actor.

```text
$ nix develop -c cabal test shikigami-server-test -j1 --test-show-details=direct \
    --test-option=-p \
    --test-option='/explicit rename aliases/ || /invalid explicit mapping/'
explicit rename aliases are idempotent and missing mappings remain untouched: OK
an invalid explicit mapping blocks automatic reconciliation for that name:    OK
All 2 tests passed

$ nix develop -c cabal test shikigami-core-test -j1 --test-show-details=direct \
    --test-option=-p \
    --test-option='/presentation rename/ || /pause before publish/ || /verified principal agent_heartbeat/'
a presentation rename retains the principal-keyed grant:                              OK
pause before publish records a terminal non-send without HTTP:                          OK
verified principal agent_heartbeat is the Kizashi actor:                              OK
reopening storage after a presentation rename retains agent_heartbeat recall and grant: OK
All 4 tests passed
```

The asserted sequence is:

1. `heartbeat` is admitted as `VerifiedIdentity agent_heartbeat`.
2. Its Kioku scope, session actor, run lineage, and verified grant key are
   `agent_heartbeat`.
3. `old-heartbeat=agent_heartbeat` inserts one alias and a repeat reports it present.
4. The grant presentation changes to `heartbeat-renamed` without changing its principal.
5. After reopening storage, legacy recall and the `KawaDigest` grant still succeed for
   `agent_heartbeat`.
6. A built Kizashi request carries `actor = agent_heartbeat`; delayed publish also retains the
   same recorded identity for exact-principal lifecycle enforcement.

[ADR 0033](../adr/0033-recorded-agent-principals-key-durable-state.md) records the resulting rule.


## Context and Orientation

Shikigami is a seven-package Haskell project. `shikigami-core` owns domain behavior and durable
Keiro workflows; `shikigami-api`, `shikigami-client`, and `shikigami-server` own public/operator
surfaces; `shikigami-workers` owns consumers and schedulers; `shikigami-agent` owns the portable
one-off runtime; and `shikigami-migrations` owns pg-migrate schema assets.

All build and test commands run inside the Nix development shell. Never inspect `/nix/store` to
find dependency code; use Mori's registry and the registered source checkout.

### Current identity seams

- `shikigami-core/src/Shikigami/Directory.hs` owns the cached directory projection. It exposes
  `PrincipalRecord`, `consultLifecycle`, `lifecycleAdmission`, `lookupPrincipal`, and disabled
  mode. Its snapshot loader rejects duplicate normalized handles and principal ids atomically.
- `shikigami-core/src/Shikigami/Agent/RunJob.hs` is the queued and journaled run request. Every
  fresh producer records an `AgentIdentity`; the worker promotes missing legacy identity once.
- `Shikigami.Memory.Scope` and `Shikigami.Memory.Access` derive Kioku scope, principal reference,
  and context from the resolved recorded identity. Production call sites use contextful Kioku
  APIs; deprecated wrappers remain only in fixtures that intentionally seed old rows.
- `shikigami.sink_grants` has disjoint partial unique keys for verified principal rows and
  null-principal compatibility rows. Verified permission checks never fall through to names.
- `Shikigami.Sink.Intent` persists `AgentIdentity` with a hand-written legacy codec. Enqueue and
  publish consume the recorded value, and publish rechecks lifecycle by exact principal.
- Agent, conversation, flow, and delegation paths consume the journaled identity. Delegated
  children are admitted independently and retain parentage only in lineage.

### Governing local ADRs

- [`ADR 0011`](../adr/0011-defaulted-agent-fields-preserve-journal-codec-compatibility.md):
  defaulted fields preserve journal codec compatibility.
- [`ADR 0014`](../adr/0014-a-run-job-declares-its-route-rather-than-being-guessed.md): queued
  jobs declare durable routing data rather than re-deriving it.
- [`ADR 0015`](../adr/0015-a-kioku-write-answers-on-two-layers-and-a-journaled-step-keeps-its-bytes.md):
  Kioku writes have domain and persistence answers while journaled bytes remain stable.
- [`ADR 0021`](../adr/0021-operator-verbs-wrap-the-owning-library.md): operator commands use the
  owning library rather than private state mutation.
- [`ADR 0022`](../adr/0022-the-journal-ends-at-enqueue-and-receipts-own-delivery-truth.md): the
  journal/outbox delivery boundary stays intact.
- [`ADR 0024`](../adr/0024-a-configured-principal-directory-fails-closed-to-its-last-valid-snapshot.md):
  configured directory operation fails closed; disabled mode is explicit.
- [`ADR 0027`](../adr/0027-the-first-release-establishes-one-clean-durable-baseline.md): the first
  release owns a clean baseline, without weakening the current wire-compatibility tests.
- [`ADR 0032`](../adr/0032-the-migration-cli-keeps-a-dedicated-configuration-boundary.md): the
  migration CLI remains a narrow pg-migrate adapter.

Read [`docs/workflow-versioning.md`](../workflow-versioning.md) before changing any file below
`Shikigami.Agent` or `Shikigami.Flow`. Run the Keiro compatibility gate against the plan-refresh
commit after every workflow-body change.

### Upstream contracts

Kioku is `mori://shinzui/kioku`, with packages including
`mori://shinzui/kioku/packages/kioku-api` and
`mori://shinzui/kioku/packages/kioku-core`. The repository pins released version 0.5.0.0.
`Kioku.Api.Access.mkPrincipalRef` accepts Meibo agent ids; `Kioku.Memory`, `Kioku.Session`, and
`Kioku.Recall` expose the contextful public operations this plan uses. There is no supported
re-scope mutation.

Meibo is `mori://shinzui/meibo`. Shikigami does not import it in this plan: the directory cache
is the local contract. Danwa is `mori://shinzui/danwa`; its current outbound request has a single
text `author`, while its local participant setting remains conversation transport state.


## Plan of Work

### Milestone 1 — Make recorded identity a durable input

Create `Shikigami.Agent.Principal` with a strict `AgentPrincipal` newtype, validation for the
`agent_…` shape and Kioku-safe principal reference, and an `AgentIdentity` sum distinguishing
verified, compatibility, and unresolved legacy values. Follow the repository record-field
convention: direct field names, strict fields, explicit derivation.

Add `identity :: AgentIdentity` to `RunJob`. Replace its generic JSON derivation with a codec that
omits unresolved legacy identity and decodes a missing member as unresolved, preserving the frozen
legacy bytes. Update all fresh producers to supply either a verified identity returned by
directory admission or a compatibility identity only when the directory is disabled. At the
worker boundary, promote a pre-upgrade unresolved job once, then dispatch and journal the promoted
job. A configured legacy promotion that cannot resolve fails closed.

Delegated children record the target identity admitted at the delegation boundary; they never
inherit the parent identity or re-resolve the target after the child job has been journaled. Agent
and conversation workflows read identity from `ingest-job`. Tests cover JSON vectors,
configured/disabled admission, replay after directory changes, and delegation.

### Milestone 2 — Key supported Kioku access by recorded identity

Change `agentScope`, `agentActor`, and write-context construction to accept `AgentIdentity`.
Verified identity uses the Meibo principal text verbatim for scope and actor. Compatibility uses a
visible, Kioku-safe `shikigami.agent.<name>` value. Unresolved legacy identity is rejected before a
new Kioku effect.

Move session and memory writes to `startWithContext`, `recordWithContext`, and the corresponding
contextful complete/fail/turn operations. Replace `legacyRecall` with explicit `RecallQuery` and
`RecallTarget`. Preserve the distinct read and write authorization contexts. Include agent,
conversation, flow, delegation, and practice-review paths found by the compiler and deprecation
search.

Acceptance is a verified session/memory pair carrying the same principal, compatibility values
remaining visibly self-asserted, exact replay behavior, and no Shikigami call site warning on a
deprecated Kioku memory/session/recall wrapper.

### Milestone 3 — Alias legacy recall without mutating Kioku

Add a migration for `shikigami.agent_scope_aliases` with `principal_id`, `legacy_agent_name`, and
audit timestamps. Make `(principal_id, legacy_agent_name)` unique and make a legacy name belong to
at most one principal. The table contains mapping metadata only; Kioku remains authoritative for
memory events and projections.

Add a small Shikigami store for aliases. For verified recall, query the exact principal scope plus
all accepted legacy scopes using supported Kioku recall calls, merge results by stable memory id,
apply deterministic ordering, and enforce the requested limit after deduplication. Compatibility
recall uses only its compatibility/name scope.

Extend `shikigami agents sync` to discover legacy agent scopes through
`Memory.getActiveRowsInNamespace`, combine them with legacy grant names, and reconcile exact
current directory joins. Support an explicit `LEGACY_NAME=agent_…` mapping for renamed handles.
Report missing, conflicting, and multiply claimed mappings without changing them; exit non-zero
when any remain. Repeat runs must not add duplicate aliases or duplicate recall results.

### Milestone 4 — Make grants principal-first with bounded compatibility

Migrate `shikigami.sink_grants` away from one global name primary key. Enforce a partial unique key
on `(principal_id, sink_kind)` for verified rows and a partial unique key on
`(agent_name, sink_kind)` where `principal_id IS NULL` for compatibility rows. Retain
`agent_name` as presentation and reconciliation evidence.

Change grant/revoke/check operations to accept recorded `AgentIdentity`. In configured mode,
grant and revoke resolve the operator's declaration selector once and store/query the principal.
In directory-disabled mode they explicitly use the compatibility key. A verified lookup never
falls back to a same-named compatibility row, and compatibility is refused when the directory is
configured.

Extend existing Postgres tests for grant, revoke, paging, sync, rename continuity, principal
conflicts, and disabled compatibility.

### Milestone 5 — Preserve identity through outbound delivery

Replace `SinkIntent`'s loose optional principal with recorded `AgentIdentity` while keeping its
legacy wire fixture decodable. Fresh intents always carry verified or compatibility identity;
legacy missing identity is promoted before a publish attempt.

The sink permission gate and lifecycle check consume the intent's recorded identity. A configured
verified recheck addresses the exact principal and never substitutes a handle match. Set Kawa
`Actor.id`, Kizashi `actor`, and Danwa `PostMessageRequest.author` to the durable identity text.
Keep Danwa's configured local participant for join/session transport. Do not change inbound
`AddressedMessage.author`, ReiAction, or Kanmon schemas.

Tests freeze the compatible intent codec, show a directory rename between enqueue and publish,
show exact-principal pause/refusal, and inspect each real outbound payload.

### Milestone 6 — Prove durability and the rename

Keep existing workflow step names, types, and order. If implementation cannot do so, stop and add
a patch id in `domain/` before continuing. Run `just keiro-gate <plan-refresh-commit>` after the
workflow edits, then run the full suite, migration smoke tests, and a warning-focused build.

Run the demonstration against a disposable database: create/seed a verified agent, record memory
and a grant, reconcile any legacy alias, change only its presentation name, restart, then prove
recall, grant, run lineage, and outbound author retain the same principal. Paste the command/output
transcript into Outcomes & Retrospective, omitting secrets and irrelevant logs.

Finally create or update an ADR capturing the durable rule: names locate agents; recorded
identities key state; configured operation fails closed; disabled compatibility is explicit; and
legacy history is aliased at the Shikigami boundary rather than rewritten in Kioku.


## Concrete Steps

Run every command from the repository root:

```bash
cd /Users/shinzui/Keikaku/bokuno/shikigami
```

The pre-change baseline recorded during refresh was:

```bash
nix develop -c cabal build all --dry-run
nix develop -c cabal test all -j1
```

Both completed successfully on 2026-08-26. After each milestone, use focused package tests and
then the full build. The final checks are:

```bash
nix develop -c cabal build all --enable-tests
nix develop -c cabal test all -j1
just keiro-gate <plan-refresh-commit>
git diff --check
```

Use the repository migration harness rather than hand-editing the database:

```bash
nix develop -c cabal test shikigami-migrations-test
nix develop -c cabal test shikigami-migrations-smoke
```

Inspect remaining deprecated Kioku calls with a repository-scoped search:

```bash
rg -n 'legacyRecall|Session\.(start|complete|failSession|recordTurn)|Memory\.record' \
  shikigami-core shikigami-workers shikigami-agent
```

The final rename transcript must show:

1. The principal admitted on the first run.
2. The memory scope, session actor, and verified grant key using that principal.
3. The explicit alias result for any pre-plan name-keyed history.
4. A presentation rename with the principal unchanged.
5. A post-restart recall and grant decision using the same principal.
6. Kawa, Kizashi, or Danwa output authored by that same principal.


## Validation and Acceptance

The implementation is accepted when all six IR-9 outcomes are observable:

1. One run's queued input, session, memory scope, grant subject, lineage, and outbound author agree
   on one `agent_…` principal.
2. Changing presentation and restarting leaves addressing, recall, and grants working because the
   principal is unchanged.
3. Explicit reconciliation aliases legacy scope once, without copying memories or duplicating
   recall results.
4. Missing and conflicting mappings are reported, left untouched, and make sync fail.
5. Replay, delayed publish, and delegated children retain the identity recorded at admission even
   when the directory changes.
6. Configured operation refuses unresolved, paused, deactivated, substituted, or compatibility
   identities, while directory-disabled development remains usable and visibly self-asserted.

Repository acceptance additionally requires every selected Cabal suite to pass, migration apply
and replay to pass, `just keiro-gate` to accept the workflow changes, no unintentional wire fixture
change, and no remaining Shikigami use of deprecated Kioku session/memory/recall wrappers.


## Idempotence and Recovery

The alias table and grant reconciliation use conflict-aware inserts/updates. Repeating
`shikigami agents sync` produces the same mappings and counts, and unresolved cases remain
unmodified and visible. Recall deduplicates by Kioku memory identity so an accidental repeated
alias cannot duplicate a result.

The schema migration is forward-only and must be tested from an empty database and from the
previous schema with name-keyed seed rows. It drops no grant data and never edits Kioku-owned
tables. If a migration cannot establish its partial uniqueness because existing rows conflict, it
must fail and name the conflict; the operator resolves it through `shikigami agents sync` or an
explicit data decision before retrying.

Legacy `RunJob` and `SinkIntent` payloads remain decodable. An unresolved legacy value may be
promoted once at an admission/publish boundary but may not initiate a new memory write or outbound
effect directly. This makes restart recovery explicit instead of treating missing identity as a
fresh verified decision.


## Interfaces and Dependencies

`Shikigami.Agent.Principal` will export the concrete names settled during implementation, with
this semantic surface:

```haskell
newtype AgentPrincipal = AgentPrincipal {value :: Text}

data AgentIdentity
  = VerifiedIdentity !AgentPrincipal
  | CompatibilityIdentity !Text
  | UnresolvedLegacyIdentity

data ResolvedAgentIdentity
  = VerifiedAgent !AgentPrincipal
  | CompatibilityAgent !Text

mkAgentPrincipal :: Text -> Either Text AgentPrincipal
principalText :: AgentPrincipal -> Text
identityText :: AgentIdentity -> Either Text Text
meiboPrincipal :: AgentIdentity -> Maybe AgentPrincipal
resolveAgentIdentity :: AgentIdentity -> Either Text ResolvedAgentIdentity
principalRefFor :: ResolvedAgentIdentity -> PrincipalRef
principalScopeText :: ResolvedAgentIdentity -> Text
```

The final implementation may choose more precise helper names, but it must preserve the three
states and must not expose a partial conversion from unresolved identity.

`Shikigami.Memory.Scope.agentScope` and access-context constructors accept
`ResolvedAgentIdentity`, not a declaration name or unresolved legacy value. `RunJob` and
`SinkIntent` each carry one strict `AgentIdentity`. Directory admission returns a recorded
identity, while exact-principal lifecycle recheck accepts one.

The alias store owns principal-to-legacy-name mappings. It uses public Kioku APIs only:
`Memory.getActiveRowsInNamespace` for discovery and explicit `RecallQuery`/`RecallTarget` for
reads. No code in this plan imports a private Kioku module or updates a Kioku table.

No new upstream package is added. Kioku remains the released 0.5.0.0 cohort pin. Meibo and Danwa
are referenced canonically as `mori://shinzui/meibo` and `mori://shinzui/danwa`; the runtime
contracts used here are already represented by local projection or pinned Danwa packages.


## Revision note (2026-08-26)

Refreshed immediately before implementation as requested. The original plan predated the landed
directory, local ADR corpus, seventh package, Kioku 0.5.0.0 pin, consolidated sink intent, and
final migration CLI boundary. This revision removes the obsolete Meibo/Shomei pin gate, replaces
unsafe Kioku projection rewrites with Shikigami-owned aliases, preserves old durable codecs,
makes disabled compatibility explicit, corrects the actual outbound attribution fields, and adds
the mandatory workflow-versioning proof.
