---
id: 34
slug: memory-lifecycle-distillation-retention-and-shared-scope
title: "Memory lifecycle: distillation, retention, and shared scope"
kind: exec-plan
created_at: 2026-07-08T20:14:28Z
intention: "intention_01kx1tyzqcerzv4ysbktgr9sw9"
master_plan: "docs/masterplans/7-platform-feature-completion-egress-schema-memory-lifecycle-delegation.md"
provenance:
  revisions:
    - model: "gpt-6-astra"
      harness: "codex-cli"
      at: 2026-10-28T18:49:50Z
      mode: "update"
      note: "Refresh lifecycle work for principal scopes, shared timer dispatch, host-owned AI and exact bounded-read/retention gates."
    - model: "gpt-6.1-sol"
      harness: "codex-cli"
      at: 2026-11-06T21:09:33Z
      mode: "update"
      note: "Refresh selected Kioku and completed runtime/execution owners while retaining exact bounded lifecycle gates."
    - model: "gpt-6-astra"
      harness: "codex-cli"
      at: 2026-11-06T21:35:46Z
      mode: "update"
      note: "Align lifecycle acceptance with v2 compatibility identities, standalone scheduler and adaptive timer routing."
  reviews:
    - model: "gpt-6-astra"
      harness: "codex-cli"
      at: 2026-10-28T18:49:50Z
      verdict: "comments"
      note: "Author self-review: timer, scope, retention and released-query contracts remain explicit pre-implementation gates."
---

# Memory lifecycle: distillation, retention, and shared scope

This ExecPlan is a living document. Refreshed on 2026-11-06 against `69ac8b25`; implementation remains
Not Started. This body replaces the July implementation instructions, including
the obsolete fifth timer poller and name-derived scope selector.

## Purpose / Big Picture

Make long-term agent memory operational: conversation timers produce consolidated
memories, fallback recall returns a bounded newest-first result, retention archives
only eligible learnings in finite passes, and `memory.scope = Shared` selects the
exact shared bucket within the authorized memory space. Preserve principal identity,
legacy memory continuity, journal replay, and separately owned review evidence.

The observable proof uses real PostgreSQL and controlled Kioku AI runners: fire a
conversation's timer through Shikigami's actual dispatcher, verify consolidated
memory, prove database-side recall bounds, archive eligible old learnings while
protecting review/history records, and show two authorized Shared agents exchanging
learnings without crossing a memory-space boundary. No live model key is needed.

## Progress

The principal/alias, declaration, supervision and shared timer foundations are already
implemented. They do not deliver lifecycle milestones. As of 2026-11-06 there is no
Memory/Policy.hs, general retention/checkpoint store or Kioku timer route in Shikigami.

- [ ] M0: verify the selected contracts and write local fixtures plus the upstream release/adoption matrix.
- [ ] M1: integrate authorized Kioku firing into the shared timer dispatcher with
  host-owned AI configuration, bounded work and supervised operational behavior.
- [ ] M2: database-bounded newest-first fallback recall and bounded alias merging.
- [ ] M3: finite retention passes with explicit eligible ownership, contextful
  archival, stable cursors, concurrency/restart proof and separate enablement.
- [ ] M4: shared learnings with private sessions/distillation, pinned policy and old/new journal acceptance.
- [ ] Closeout: user/operations documentation, full acceptance matrix, ADR updates
  reflecting ADR 0064 and final qualification evidence.

## Surprises & Discoveries

`Agent/Run.hs:recallActiveByScope` currently calls `Recall.getActiveByScope` and
then `take`; returned length is capped but transfer/query work is not.
`recallAgentLearnings` reads the principal scope and every accepted alias,
deduplicates in traversal order and truncates; a newer alias memory can lose to
an older principal memory. This is a concrete gap against ADR 0033's deterministic
merged ordering, not permission to drop accepted legacy history.

`Flow/Capability.hs` has `RememberOptions` for priority, confidence, type and
supersession. `PracticeReview/Memory.hs` writes provisional `MemoryPattern` rows.
The old assumption that this type identifies disposable generic run learnings is
false. General retention must not take ownership of practice-review adjudication.

`Agent/Conversation.hs:recordAssistantTurnAndEnqueueReply` applies
`l1TimerScheduleProjection`, while
`Trigger/Scheduler.hs:shikigamiTimerFallback` handles schedule, execution-observation,
approval, adaptive cutoff and conversation-idle payloads, not Kioku distillation. The shared timer
pass already performs guarded recovery and drains at most 100 rows. A second
unfiltered Kioku worker is not a safe integration strategy.

The selected Kioku 0.12.0.2 source, verified at released commit
`5a62c3ef29cad50543f7bae97126e0431225998d` (tag `v0.12.0.2`), exposes
`newDistillRuntime :: AIRuntime -> Maybe FilePath -> DistillRuntime`,
`testDistillRuntime` and `withTestRunners`. The old self-registering Claude
constructor and writable runtime-function record are gone. Disabled AI is the
default; provider credentials alone are not authority to enable execution.

Kioku 0.12.0.2 has permission-checked pages, fixed metadata and newest-active
metadata lookup. Ordinary memory pages are priority-first, and a newest point
lookup is not a newest-first collection or retention-candidate page. Upstream
`mori://shinzui/kioku/okf/improvement-requests/concepts/IR-2` remains partially
delivered. `scopedScanCandidates` still applies a limit after an unbounded scope
read; copying it does not establish this plan's operational bound.

## Decision Log

- 2026-10-28 follow-up: Resolve scope, retention, alias bounds, timer adapter and
  replay policy in ADR 0064; replace design questions with concrete local tasks
  and exact upstream delivery contracts. Shared does not publish private transcripts
  or distillation, and unmarked historical memory is retained.

- 2026-10-28: Consume existing timer, identity and AI owners. The July fifth-loop,
  zero-argument runtime and `agentScope (name decl)` sketches are superseded.
- 2026-10-28: Introduce M0 as an acceptance gate for the selected integration
  contracts, not as a prerequisite to merely inspect or prepare the work. Do not
  mark M1–M4 complete from compilation or upstream request status.
- 2026-10-28: Keep the age-plus-keep-count retention intent, but require ownership
  exclusions and a finite total pass budget. Separate retention enablement from AI
  distillation so deployments can manage storage with AI disabled.
- 2026-07-08/22 (retained intent): Use controlled AI in tests, enforce bounds in
  PostgreSQL, recall Shared as one exact bucket rather than a union, and preserve
  old memory when declarations change. Historical implementation sketches are
  replaced by the current milestones below.

## Outcomes & Retrospective

No lifecycle implementation or runtime validation was performed in this refresh.
The design holes now have selected contracts in ADR 0064 and executable acceptance
cases below. Missing released upstream behavior remains a delivery dependency;
none of the implementation or acceptance results is claimed complete.

## Context and Orientation

The declaration and bounded `RecallLimit` (1–1000) are in
`shikigami-core/src/Shikigami/Agent/Decl.hs`, mirrored by `schema/Agent.dhall`.
`memory` defaults to AgentScope, limit 10, OnSuccess. `Memory/Scope.hs:agentScope`
takes `ResolvedAgentIdentity`; verified identities are stable Meibo principals,
and compatibility identities are explicitly self-asserted. Accepted old name
scopes live in `Memory/AliasStore.hs`. Do not recompute identity from a mutable name.
[ADR 0087](../adr/0087-agent-values-retain-checked-meaning-and-separate-compatibility-scopes.md)
now defines compatibility scope as `shikigami.agent.v2.` plus the exact-name
commitment, through `Agent/Principal.hs`. Preserve that implementation and checked
`AgentName`; do not reconstruct the old colon/dot sanitizer or infer aliases.
Verified-principal legacy aliases remain explicit. Add `a:b` versus `a.b`, Unicode
and whitespace fixtures proving distinct admitted compatibility scopes, private
sessions and same-build recovery. The earlier first-release namespace reset does
not authorize a new reset or a populated cross-build migration in this plan.

`Memory/Access.hs` owns the current single `shikigamiMemorySpace`, read context and
agent write context. A scope organizes data inside a space; it does not authorize
access. New reads and writes must use Kioku's contextful public boundary. Shared
means `ExactScope sharedScope`, never a namespace-wide query or all memory spaces.

Runtime consumers are `Agent/Run.hs` (recall helpers), `Agent/Workflow.hs`
(session/recall/learning), `Agent/Conversation.hs` (conversation sessions/turns),
`Flow/Capability.hs` (journaled memory and deterministic write IDs), and
`shikigami-agent/src/Shikigami/Agent/Command/AgentRun.hs` (one-off entry point).
Follow current calls from the latter instead of recreating the removed
`runAgentWithMemory` orchestration. Explicit Flow memory and practice-review
memory have their own policies; do not silently reinterpret them as automatic
run learning.

Worker assembly belongs to `shikigami-workers`: `Workers/Command/Worker.hs`,
`Workers/Config.hs`, `Trigger/Timer.hs`, `Trigger/Scheduler.hs`, and `Health/Worker.hs`.
Core owns reusable memory operations, workers own process settings and loops.
The old `shikigami-core/src/Shikigami/Worker.hs` no longer exists.
The standalone `Workers/Command/Scheduler.hs` also drains timers through
`Trigger/Scheduler.hs:runSchedulerTimerWorker`; it must consume the same Kioku
routing/configuration contract. `Health/Supervision.hs` owns loop supervision.
Follow [ADR 0075](../adr/0075-service-composition-has-a-closed-reviewed-module-budget.md)
and `tools/style/module-ownership.json` when adding modules; keep lifecycle behavior
inside Memory and composition inside the existing reviewed worker owners.

Read [ADR 0033](../adr/0033-recorded-agent-principals-key-durable-state.md),
[ADR 0031](../adr/0031-practice-review-adjudication-is-a-logical-memory-transition.md),
[ADR 0015](../adr/0015-a-kioku-write-answers-on-two-layers-and-a-journaled-step-keeps-its-bytes.md),
[ADR 0019](../adr/0019-a-loop-that-stops-stops-the-process.md),
[ADR 0038](../adr/0038-runtime-startup-and-maintenance-share-validated-owners.md),
[ADR 0056](../adr/0056-context-summaries-are-accepted-accounted-model-operations.md)
and [workflow versioning](../workflow-versioning.md). The Kioku owner also documents
host-owned AI execution and memory-space isolation in `mori://shinzui/kioku`,
project-relative `docs/adr/host-owned-ai-execution.md` and
`docs/adr/namespace-is-not-a-security-boundary.md` (artifact-level URIs pending:
the current manifest declares no ADR bundle and registry discovery returned no
matching ADR handle).

Use Mori before dependency lookup. The current project selects Kioku 0.12.0.2, Keiro 0.22.0.0,
Baikai 0.10.0.0 and Shikumi 0.5.1.0 under index
`2026-11-03T12:48:57Z`. Hackage and upstream tag verification on 2026-11-06
confirm the selected Kioku release.
[Plan 92](92-resolve-the-released-keiro-0-22-cohort-and-rehearse-the-composed-migration.md)
and runtime plan 94 are complete. Their cohort/runtime delivery is available,
while the exact bounded-source/read/conditional-retention APIs below still need
producer acceptance. Do not mistake generic pages for this plan's exact contract.

## Plan of Work

### M0 — Establish the selected contracts and owner handoffs

M0 is now verification and fixture work for the decisions below, not an open-ended
design exercise. [ADR 0064](../adr/0064-memory-lifecycle-preserves-session-and-retention-ownership.md)
records the durable choices. Implement the local policy/selector, eligibility and
merge fixtures first; use fake owner interfaces until the specific released read
contracts are available. Do not replace missing owner APIs with projection SQL.

**Scope and policy.** Add a core `Memory/Policy.hs` owner for a versioned
`MemoryPolicySnapshot`: format 1, recorded memory-space id, recorded principal,
learning target (principal or exact global bucket), recall limit and automatic
record policy. It contains no credential or authorization decision. Pin it in a
`memory-policy-v1` step behind `shikigami-memory-lifecycle-v1` in agent and
conversation workflow declarations; absence of the patch keeps the old body.
One-off execution resolves the same value once. Every IO boundary constructs a
fresh authorized context for the pinned space/actor; the snapshot grants nothing.

Session scope and attribution remain principal-based for both AgentScope and
Shared. L1/L2/L3 distillation remains in its source scope. Shared publishes only
automatic agent-run learnings and explicit Flow remember calls, and recalls only
the exact global bucket. It does not publish conversational transcripts or their
distilled private memories. A Shared agent therefore does not automatically recall
its private distillation through the generic Shared recall path. This is a
specified privacy boundary, documented and tested, not an unfinished destination
API. Automatic run recordPolicy does not suppress explicit Flow remember or the
existing conversation-turn transcript protocol; those operations remain explicit.

**Recall.** Request at most N newest metadata rows from each exact accepted scope,
with a fixed request cutoff and `(created_at DESC, memory_id DESC)` ordering.
Read aliases with a SQL limit of 65: up to 64 aliases are supported, and the 65th
causes `AliasScopeLimitExceeded` before any Kioku lookup. Never drop an accepted
alias silently. Query scopes sequentially, deduplicate by stable memory id and
keep a bounded top-N heap ordered by timestamp/id. Fetch content only for the final
N ids through authorized owner reads. Reject conflicting metadata for the same id.
The fallback merge uses O(N) retained candidates and at most 65 metadata scope queries; N stays in
1–1000. A read/context/store failure is a typed run failure, not an empty recall;
only successful empty search across the requested scope set selects recency fallback. Keyword-only recall
remains available when embedding is disabled.

**Retention.** Only automatic run-learning writes produced under the new patch
receive the reserved tag `shikigami.retention.run-learning.v1`. Flow, conversation,
distillation and practice-review writers cannot attach that tag; reject the entire
`shikigami.retention.` prefix in caller-authored extra tags. Metadata must also
match the configured space, Shikigami namespace, MemoryPattern and an exact agent
or global learning scope. Unmarked legacy rows and explicit Flow/review/distilled
memories are protected. No inference from type alone and no automatic backfill.
Use the newest 200 eligible active records **per physical scope** as the keep set;
alias scopes are independent retention buckets, though recall composes them.
The shared global bucket has one shared keep set. Age and keep predicates apply
together, with a default age of 30 days.

The core maintenance pass consumes contextful owner candidate pages. The worker
persists a checkpoint in a new Shikigami-owned
`memory_maintenance_checkpoints` table, keyed by memory space and policy format.
It stores the fixed sweep cutoff, last examined `(created_at, memory_id)` key and
last pass outcome; it stores no content. Each pass attempts at most five pages of
100 candidates or 30 seconds, whichever comes first. One worker uses `pg_try_advisory_xact_lock` for the checkpoint while a pass runs;
a busy lock skips the pass without waiting. Bound each owner query/command to the
smaller of five seconds and the remaining pass budget; archive commands use Kioku's
public contextful boundary on their own transactions. Advance the checkpoint only
after the candidate outcome is known. A crash between archive and checkpoint safely
retries the owner command. A transient error stops the pass without advancing the
failed cursor; after three failed passes park that candidate in a bounded failure
record and advance, exposing it for operator retry. Cap parked failures at 1,000
per space; a full failure store stops maintenance with a visible capacity error,
never discards a failed candidate. The owner archive operation must atomically recheck active state, the exact
eligibility predicate and the newest-K protection before appending an archive fact;
a separate caller read is insufficient. This conditional archival is part of the
required retention handoff, not a guarantee of today's `archiveWithContext`. Exhausting the sweep resets the cursor
and starts a new cutoff on the next hourly sweep; backdated concurrent inserts
behind the cursor are picked up next sweep. No exactly-once counters are inferred
from pre/post reads.

**Upstream deliverables.** These are required producer behaviors, not claims that
these function names already exist. Record adoption in a release matrix under
`docs/evidence/memory-lifecycle/contracts.md` during implementation:

| Consumer | Owning handoff | Required release evidence |
|---|---|---|
| M2 fallback and M1 merge candidates | `mori://shinzui/kioku/okf/improvement-requests/concepts/IR-2` | Contextful exact-space/scope newest-first metadata, N and cutoff, stable timestamp/id tie-break, bounded content-by-id; real SQL plans and isolation tests |
| M3 retention | Same Kioku IR-2 | Reserved-tag/type/scope selection, age AND newest-K exclusion, chronological keyset pages, atomic eligibility/keep-set recheck at archive and authoritative outcomes; concurrency/index evidence |
| M1 per-timer work | `mori://shinzui/kioku` (follow-up under IR-2; owner artifact pending) | Bounded source-turn/candidate reads for all enabled L1/L2/L3 operations, explicit over-limit refusal without watermark advancement, public test runners and retry/defer outcome mapping |
| Adoption | Completed local plan 92 plus the current cohort owner | Current solve/migrations are accepted; only a newly required owner API needs a new verified release/closure handoff |

Plan 34's implementer prepares the producer acceptance fixtures and handoff using
these coordinates. Updating upstream requests or implementing another repository
is separate authorized work; this local plan makes the required delivery concrete
without pretending it has happened. Default distillation limits are five merge
candidates, 256 source turns and 256 KiB of encoded source per operation. Exceeding
a bound parks the work visibly; do not truncate input and advance the watermark.
Tests include the boundary and one unit over it. If current L2/L3 cannot enforce
the same limits, their live enablement waits for that producer delivery.

Implement in this order: M0 local contracts; M2 bounded reads; M4 policy/tag
integration; M3 retention; M1 live distillation. M4 requires M2 acceptance for its
full recall proof, and M3 requires M4's accepted marker-writing behavior. M1 may
land earlier after its own bounded-source/candidate release and M0 adapter proof;
it has no hard dependency on Shared or retention. While a release is missing,
work on the other milestone's pure fixtures/configuration but do not mark its
blocked runtime acceptance complete.

M0 acceptance is the local pure contract/merge fixtures and the filled matrix of
selected-version capabilities versus missing released behavior. It can complete
with named upstream release blockers; it cannot mark M1–M3 accepted.

### M1 — Drive Kioku timers through the shared dispatcher

Extend the existing worker configuration with validated AI feature settings,
credential references, time/work bounds and explicit disabled state. Construct
`AIRuntime` once at startup via the supported Kioku configuration boundary and
build `DistillRuntime` from it. Reject an invalid enabled configuration before
starting loops. No implicit provider registration, hardcoded model, or ambient
credential fallback; workers do not get an interactive session launcher.

Use one shared dispatcher. Route recognized Kioku process-manager names to a
worker-built `TimerRow -> IO (Either StoreError (Maybe EventId))` callback. That
callback runs `fireKiokuTimer` and `applyFireOutcome` under Kioku's lawful `runAppIO`
resource environment with a context provider restricted to the configured space.
The scheduler invokes the callback through IO; it does not cast effect rows or
recreate Kioku writes. All other owners retain their existing fallback handlers, including
`Adaptive.Wake` cutoff timers. Thread the same callback and validated drain limit
through `runSchedulerTimerWorker` and its standalone command composition; leaving
that role on the old unknown-kind fallback could consume Kioku work incorrectly.
Both drain entry points must share the recognized-owner decision and disabled-AI
policy. Test each entry point against mixed-owner rows; adding another poller or
only updating the full worker is insufficient.
Store errors escape as visible failed passes with no invented completion marker.

Use Kioku's public outcome mapping: Completed finalizes, RetryLater reschedules,
FailedPermanently and Deferred park/dead-letter, and NotMine returns control to the
other owner routes without being passed to Kioku's unknown-timer requeue branch.
Apply the Kioku eight-attempt ceiling at its handler boundary before model work;
do not impose it on unrelated workflow sleeps. Disabled distillation parks only
recognized Kioku work with an explicit disabled reason and no model calls. Re-enable
through supported owner resume/requeue with fresh context, never private timer SQL.

When live distillation is enabled, call the existing shared drain with limit **1**
and a 30-second maximum Kioku callback duration. This deliberately trades backlog
throughput for a bounded pass: it avoids claiming a batch whose later callbacks
cannot fit the AI budget. Keep the one-second poll and set timer heartbeat staleness
to 60 seconds. With distillation disabled the existing 100-row fast pass remains.
A timeout cancels the controlled AI operation, uses the owner's retry outcome and
never advances a distillation watermark as success. Cancellation/fencing tests must
prove a late result cannot overwrite a newer accepted outcome; if the provider
cannot honor the required bound, keep that provider disabled. A queued ordinary
timer behind K due distillation rows has at most K bounded callbacks ahead of it;
no unconditional wall-clock SLA is promised under an unbounded incoming backlog.
Publish due-count/oldest-age and duration so operators can see this throughput cost.
Retention runs in its own supervised loop, never as a second generic timer poller.

Add worker integration coverage beside `shikigami-workers/test/Shikigami/TimerRecoverySpec.hs`:
seed a real conversation session/turn, apply the real projection, advance the test
clock, run the actual Shikigami timer pass and assert extraction output and terminal
timer state. Use `testDistillRuntime`/`withTestRunners` from the selected release.
Test mixed timer owners (including adaptive cutoffs), both drain entry points,
duplicate/restarted passes, denied or foreign memory space,
AI-disabled/deferred outcomes, bounded retries, timeout and cancellation. Assert
successful persistence, not just a callback counter. Include L2/L3 routing evidence
before claiming the full pipeline works.

### M2 — Bound and order recall, including aliases

Replace `recallActiveByScope` with the owner-supported, contextful query for active
rows in one exact space/scope, ordered `created_at DESC, memory_id DESC`, limited
in PostgreSQL by the validated recall bound. Preserve the distinction between
ordinary hybrid search ranking and recency fallback; do not replace relevance
search with a recency-only query accidentally. Use the typed refusal/failure behavior in M0; do not turn a failed read into an empty result.

Factor a search-only helper from `recallPriorLearnings` so alias iteration cannot
mix per-scope fallback rows with successful relevance hits. Apply the existing
bounded search contract over the accepted scope set; if the combined successful
result is empty, run the deterministic recency fallback over that same set.
Refusals/errors stop the request. Then implement M0's capped alias enumeration
and sequential top-N metadata merge.
Keep the existing relevance-ranked successful search behavior; the deterministic
newest-first merge is specifically the fallback path. The principal and all
accepted aliases are queried under the same pinned request cutoff. The owner must
return the ordering metadata needed for the merge; Shikigami never reads Kioku
projection tables. Test newer alias rows outranking older principal rows, ties,
duplicate ids and a 65th alias producing an explicit failure without partial data.

M2 is gated by the exact remaining IR-2 collection contract. Generic priority-first
pages and newest-active point lookup are not substitutes. Add the missing operation
upstream through its owning plan/release before consuming it; this plan does not
silently authorize changes to another repository.

PostgreSQL acceptance seeds more than the limit, timestamp ties, different
priorities, overlapping aliases and two spaces. Prove exactly the newest N fallback
rows, no cross-space data, correct deduplication/rename continuity and no unbounded
transfer. Upstream query-plan evidence must accompany the operation; a Haskell
assertion on final list length cannot distinguish `LIMIT` from `take`.

### M3 — Retain eligible learnings in finite passes

Implement M0's exact marker, physical-scope keep set, checkpoint, failure parking
and pass budgets; these choices are fixed by ADR 0064. Add migration and checkpoint
fixtures to the owning migration/core packages. Do not broaden eligibility.

Add a core maintenance operation and worker-owned settings, independently enabled
from AI. Initial policy intent remains age over 30 days AND beyond the newest 200
eligible learnings per agreed scope domain. Validate age, keep count, batch size,
maximum pages/rows per pass and timeout. Apply the M0 ownership exclusions before
selection: practice-review facts, other memory spaces/namespaces, scenes/personas,
unknown legacy ownership and other owners' evidence are not disposable run learning.

Consume released candidate pages with deterministic `(created_at, memory_id)`
keysets, fixed pass cutoff and the owner-supported keep-count predicate. A LIMIT on
a window query does not alone prove bounded database work; require the owner's
index/query-plan evidence. Do not scan all rows locally, issue private Kioku SQL or
use an unbounded offset to skip protected rows. Coordinate outstanding retention
query semantics with IR-2.

Archive through the adopted contextful conditional-retention command with an
authoritative changed/no-op receipt, a truthful maintenance actor and explicit
memory-space authorization. The current `archiveWithContext` identifies the owner
boundary but is insufficient if it lacks the atomic policy recheck; do not emulate
that guard with caller-side SQL or a read followed by an unconditional archive.
Do not use a deprecated legacy wrapper for new writes. Handle both store failure
and domain refusal; count confirmed changes only when the API actually reports
change. Stop at the pass budget and resume deterministically on a later pass.
Use M0's next-sweep handling for backdated inserts and bounded failure parking;
terminal/superseded candidates produce a typed no-op/refusal and advance the cursor. Interruptions and repeat passes must
not duplicate archive facts or falsely report success.

Acceptance seeds more than two batches with ties, recent/protected rows, generic
learning and provisional review records, aliases, another namespace/space and
concurrent inserts. Assert eligible archival, preserved exclusions, finite work,
no skipped tied candidates and restart/idempotence. Tests prove retention can run
with AI disabled and that a failed maintenance branch is visible to supervision.

### M4 — Apply declared scope consistently and preserve replay

Implement the M0 snapshot and selector using the admitted identity. AgentScope
retains principal plus alias recall; Shared selects the exact global bucket.
Automatic run learnings and explicit Flow remember/recall use that selected target.
Session lookup, conversation transcripts and distillation stay principal-scoped.
Exercise the one-off and durable entry points using the same policy owner.

Pin the snapshot behind the named patch before affected session/recall operations.
Old patch branches continue calling the existing principal-only helpers, even if
a declaration now requests Shared. New branches use the pinned target and tag only
automatic run learning as retention eligible. Always/OnSuccess/Never continue to
control automatic result learning; explicit Flow remember and conversation-turn
recording do not inherit that suppression. Practice-review keeps its separate
scope/protocol and is never assigned the retention marker.

Changes to workflows/interpreters follow `docs/workflow-versioning.md`: preserve
old result codecs and deterministic memory IDs, add a real patch when shape or
pending-effect semantics change, update the checked DSL and run the gate. Stable
step names alone do not authorize a changed body. Test a suspended old run against
the new code and a fresh run using Shared, including a manifest change while parked.

Acceptance includes two Shared agents exchanging a learning, AgentScope controls,
verified rename/aliases, compatibility identity, foreign-space refusal, failed-run
record policy and conversation lookup isolation. Exercise both durable execution
and one-off paths rather than only a pure selector.

## Concrete Steps

From the repository root, inspect the current cohort and run commands inside the
Nix development shell. Preserve unrelated in-progress execution work. Use the
actual suite names (PostgreSQL tests are no longer in the unit suite):

```bash
nix develop --command cabal build all
nix develop --command cabal test shikigami-core:shikigami-core-test
nix develop --command cabal test shikigami-workers:shikigami-workers-test --test-options='--num-threads=1'
nix develop --command cabal test shikigami-core:shikigami-core-postgres-test --test-options='--num-threads=1'
```

Place core integration fixtures in `shikigami-core/test-postgres/Shikigami/`,
worker timer fixtures in the worker suite, and register new modules in the relevant
Cabal descriptors/Main. Reuse migration-aware ephemeral database helpers. After
adding `MemoryLifecycle` groups, a focused command is:

```bash
nix develop --command cabal test shikigami-core:shikigami-core-postgres-test --test-options='--num-threads=1 --pattern MemoryLifecycle'
```

At the final accepted implementation revision, run the affected suites and full
regression, then the workflow gate against the actual pre-change baseline:

```bash
nix develop --command cabal test all --test-options='--num-threads=1'
nix develop --command just haskell-conventions
nix develop --command just keiro-gate <pre-change-commit>
git diff --check
```

Document the real validated configuration invocation and a sanitized finite-pass
transcript after its syntax exists; do not copy the old invented `--config` CLI.
Update `docs/user/memory.md`, relevant worker operations documentation and the
MasterPlan registry with actual outcomes. Secrets never appear in example output.

## Validation and Acceptance

M0 contracts, M1 real dispatcher proof, M2 database/alias bounds, M3 protected
finite archival and M4 cross-entry-point isolation/replay must all pass. Disabled
AI still permits storage/keyword recall and independent retention. Existing
scheduler/approval/idle timers, egress, delegation, practice-review and execution
context summaries retain their own behavior. Production claims require operational
retry/timeout/health evidence, not just a successful fake extraction.

## Idempotence and Recovery

Use Kioku's watermark/write/claim protocols and deterministic Shikigami memory IDs;
do not claim exactly-once model invocation across crashes. Replay must return
accepted results without fresh writes. Retention uses finite restartable pages and
owner commands; failures remain visible. Disabling distillation or retention stops
future work without deleting memory. Do not describe restoration of an unbounded
recall path as a safe rollback. After new journal semantics are admitted, roll
forward with retained codecs/patch branches; enabling Shared does not move old data.

## Interfaces and Dependencies

Plan 33 is the satisfied whole-child prerequisite. Plan 54, ADR 0033, existing
worker configuration and plan 65/69 timer ownership are accepted foundations.
M0 verifies the selected implementation contracts; M2/M3 require the specific released Kioku reads.
M4 requires M2 acceptance; M3 requires M4 marker integration. M1 is independent
after M0 and its exact bounded-source/candidate release gates pass. Plans 92/94 and 83–85 are complete. Their accepted cohort, runtime,
execution/session and root-accounting boundaries are regression consumers, not
pending whole-plan blockers. A new upstream API still needs explicit compatible
release/closure qualification.

This child owns memory-target policy integration, bounded recall consumer behavior,
retention eligibility and the Kioku timer adapter. Kioku owns storage, query SQL,
permissions, distillation and archive contracts. Workers own process settings and
maintenance assembly. No private storage mutation, effect-row cast, new identity
resolver or generic timer poller is part of the interface.

## Revision Notes

- 2026-11-06 focused compatibility audit: Retain ADR 0087 v2 identity semantics and
  checked values, cover the standalone scheduler drain and adaptive cutoff timers,
  and require current module-ownership checks. No lifecycle milestone is complete.

- 2026-11-06: Rebase on selected Kioku 0.12.0.2/Keiro 0.22 and completed runtime/execution owners; verify the selected distillation API and still-unbounded source candidate path; preserve the exact missing read/retention and replay contracts without claiming lifecycle delivery.

- 2026-10-28 follow-up: Address the review holes with selected semantics, budgets,
  failure/cursor handling, workflow patch policy and upstream acceptance handoffs.

- 2026-10-28: Replaced stale implementation instructions with current principal,
  contextful Kioku, shared timer and host-owned AI contracts; identified partial
  upstream delivery, unbounded candidate/alias reads, retention evidence hazards,
  shared-session ambiguity and replay gates. No implementation completion claimed.
- 2026-07-08/22/30: Original lifecycle decomposition, server-side bound requirement
  and Kioku IR-2 dependency. Those intentions remain; current milestones supersede
  the old API sketches and package/loop paths.
