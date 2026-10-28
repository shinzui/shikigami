---
id: 83
slug: recover-durable-model-and-tool-turns-with-composed-policies
title: "Recover durable model and tool turns with composed policies"
kind: exec-plan
created_at: 2026-10-10T23:32:15Z
master_plan: "docs/masterplans/14-deliver-adaptive-autonomous-objectives-with-durable-workers.md"
intention: "intention_01m4m2pjz6es9v9aqq5jq9c4ee"
provenance:
  created_by:
    model: "gpt-6-astra"
    harness: "codex-cli"
    at: 2026-10-10T23:32:15Z
  reviews:
    - model: "claude-fable-5-1"
      harness: "claude-code"
      at: 2026-10-22T01:19:09Z
      verdict: "comments"
      note: "Skill/Conversation/Approval symbols verified; ADR 0030 approval child and ADR 0022 receipt split not cited for M2/M3"
  revisions:
    - model: "claude-fable-5-1"
      harness: "claude-code"
      at: 2026-10-22T01:19:09Z
      mode: "update"
      note: "Cite ADR 0030 for the approval child binding and ADR 0022 for the submit/observe receipt split"
    - model: "gpt-6.1-sol"
      harness: "codex-cli"
      at: 2026-10-28T05:35:00Z
      mode: "implement"
      note: "Build durable accepted operations and recovery on the accepted root and selection boundaries"
---

# Recover durable model and tool turns with composed policies

This ExecPlan is a living document. The sections Progress, Surprises & Discoveries,
Decision Log, and Outcomes & Retrospective must be kept up to date as work proceeds.
If durable project context changes, update or create ADRs in docs/adr/ in the same change.


## Purpose / Big Picture


Resume a Skill or conversation from its accepted model/tool history after a crash, preserving policy decisions, usage, and one logical terminal result. Fulfill [IR-14](../improvement-requests/record-durable-model-tool-turns-and-compose-harness-policies.md). Hard dependencies are `docs/plans/81-enforce-root-resource-reservations-across-durable-work.md` and `docs/plans/82-pin-governed-execution-settings-for-agent-assignments.md`. Continuing-session operations integrate later through plan 84; they are not a prerequisite for this independently testable harness.


## Progress


- [x] Milestone 1: Versioned execution snapshots, protected payloads and atomic accepted operations. Sixteen PostgreSQL cases prove reconstruction, exact continuation/tool data, protected reads, bounded inspection, immutable retries, races, full transaction rollback, cancellation/unknown handling, terminal validation and catalog fencing. Full build and conformance pass.
- [ ] Milestone 2: Composed policies, individually accepted tools and bound durable permissions.
- [ ] Milestone 3: Resumable driver and fenced submit/observe executor integrated with runs and conversations.
- [ ] Milestone 4: Recovery qualification and bounded operator inspection.

Milestone 2 is partially implemented: immutable tool bindings and response-position
validation, monotonic policy composition, context views with provenance, accounted
bounded repair operations, and parked permissions through the existing approval
child are implemented. The runner prepares trusted operation coordinates and
rechecks live tool bindings, expiry, stop/cutoff and fresh authorization. It does
not dispatch without the fenced attempt boundary still owned by milestone 3.
Recorded model-assisted summaries now consume ordinary accepted model attempts
and retain source/outcome provenance across restart. Shared operator configuration
and monotonic agent overrides now feed new frozen admissions. Class-specific
uncertainty recovery and full production qualification remain open.

The next checkpoint implements the fenced submit/observe primitives and worker
route: reservation plus queue acceptance, claim generation/expiry, conditional
start, atomic outcome/cursor/accounting, pre-dispatch refusal with accounted retry,
retained late receipts, partial-billing reconciliation and protected current-wake
publication. The real HTTP and native-tool executor paths consume those primitives.
Observation deadlines use the existing timer dispatcher and an explicit generation.
The automatic driver is now a callable, registered workflow with bounded decision
generations, accepted-reference queue repair, replay-window reconstruction and
the existing bound Approval child. The agent-run leaf Skill branch now admits and awaits this driver behind a real
workflow patch. The conversation Skill branch now adopts the same child behind
its own patch, with durable ingress acceptance and unchanged atomic reply ownership.
The database-free command uses explicit ephemeral recording with the same pure
policies. The durable one-off command drives only its accepted child through the
fenced executor after releasing the parent lease.
Recorded summaries are accepted and replayed through that driver. Milestones 2
and 3 remain open.

Implementation baseline: `a156a6f`. Plans 81 and 82 are Complete. ADR 0051/0052 define the accepted root/selection and partial-billing contracts.


## Surprises & Discoveries


The catalog boundary supports captured live projection data and a registered
immediate query over a process-local transaction. The execution store now binds
both to the one generated catalog; its readers refuse an offline projection.
The existing evidence factory was changed to preserve unrelated projection sets.
The resource owner already has `execution_operations`; transcript operations use
the distinct `execution_transcript_operations` table and correlate by operation id.

The migration recipe itself executed backticks in an unquoted template comment,
embedding schema-check output into SQL. This recurred after the EP-2 failure.
[FRIC-10](../friction-log/10-migration-template-executes-the-schema-check-inside-sql.md)
and the separately affected EP-2 occurrence
[FRIC-11](../friction-log/11-selection-migration-inherited-executable-output-from-the-recipe-comment.md)
are resolved: the recipe comment no longer substitutes a command, and an isolated
generation probe emits only SQL comments. Applied migration bytes were unchanged.


The compatibility gate rejected adding an attempt table to the established
projection group: changing its target set also changes persisted query and rebuild
identities. Preserve those identities by adding a `dispatches` column to the
already-owned operation table. Each logical operation stores at most 1,000 attempt
records, indexed lookups project one record, and a nominal ReadCommitted transaction
lock protects global attempt-id collision checks across roots. The original catalog
read/write fence now covers attempts without another projection boundary. This is
an implementation layout change, not a compatibility waiver.

Generic tools cannot infer zero invoice cost from their recovery class. Their
immutable binding defaults to unreported invoice cost, which stays unknown and
cannot satisfy a finite invoice ceiling. A trusted non-invoiced factory may declare
zero. Tool model-token usage is enforced at zero by refusing nested LLM operations
through a global provider registry. Rich tool results preserve structured data and
opaque extensions, including accepted-message references, before lease cleanup.

## Decision Log

2026-10-28: One Settei harness setting feeds workers, conversations and one-off
commands. Agent overrides remain optional and historical JSON omits their absent
default. New admission narrows and freezes policy; matching snapshots bypass
new policy evaluation. Database-free execution shares pure policy rules and has
an explicitly nonresumable in-memory recording. Foreground durable execution
drives a single accepted child and never drains another run's queue messages.
[ADR 0059](../adr/0059-harness-policy-is-frozen-at-admission-and-shared-with-ephemeral-execution.md)
and the [operations guide](../operations/durable-execution.md) record the contract.

2026-10-28: Conversation ingress acknowledges a matching durable admission or
recorded next-message wake separately from reply completion. Duplicate current
input observes the accepted turn; new unaccepted input keeps backpressure.
Both message and timer wakes publish through a fixed-generation transaction.
Replay context format 2 explicitly marks the current request, leaving earlier
turns independently compactable; format 1 retains its old codec and anchor.
[ADR 0058](../adr/0058-conversation-acceptance-and-wakes-retain-their-generation.md)
records these boundaries. [FRIC-12](../friction-log/12-awakeable-repair-requires-an-explicit-publishing-generation-transaction.md)
records the dependency interface detour: the public convenience signal repairs
into the current generation, requiring composition of public transaction hooks
to retain the publishing generation.


2026-10-10: Use a separate checked execution authority with Shikigami-owned replay records and atomic outcome/progress/resource settlement. Keep the existing terminal memory/sink/reply owners. Long work uses durable submission and observation so workflow concurrency is not a proxy for executor capacity.

2026-10-27: Establish the storage contract before wiring the policy/driver.
Versioned payloads, identity-bound replay permits, catalog-fenced queries and the
atomic acceptance boundary are recorded in
[ADR 0053](../adr/0053-execution-lifecycle-and-protected-replay-share-an-atomic-boundary.md).
The same normalized call facts used by selection/decision evidence accompany a
model outcome. A known transport stop with unknown billing keeps the EP-1 partial
settlement semantics. Unknown execution effects retain their cursor and active
reservation. Terminal success validates the accepted reply against pinned policy.


2026-10-28: Keep permission state on its existing accepted operation row, within
the execution catalog target and checked Park/Resume command transaction. No
second approval scheduler/table is needed. The persisted public review id is
stable across driver generations and resolves only through the existing approval
child and opaque-token library path. Additive optional policy/snapshot/operation
fields omit absent values so format-1 payload digests and old journal bytes stay
stable. Required compaction content refuses overflow instead of truncating signed
continuations or orphaning tool observations. ADR 0053 records these constraints.

2026-10-28: Keep dispatch state under the original operation target rather than
changing persisted catalog identities. A safe pre-dispatch retry keeps the logical
operation key and spends a fresh actual attempt. An expired dispatched claim holds
its cursor and unknown effect; late receipts are fenced observations and only
explicit retained-receipt reconciliation advances it. Prepared blocking/streaming
handlers share an atomic terminal hook and admit one invocation. Actual terminal
HTTP errors release active capacity while retaining unknown billing. Current wake
publication is separate from the immutable attempt fingerprint and observation
timers append only to their recorded generation. Technical driver ids use stable
UUIDv5 values instead of resource keys containing Keiro separators. These decisions
and the remaining production-driver boundary are recorded in
[ADR 0054](../adr/0054-execution-attempts-own-dispatch-fences-and-generation-wakes.md).

2026-10-28: A new execution-driver family rotates after each bounded decision or
observation. Lost queue delivery reuses the accepted actual attempt; no callback
runs in its workflow lease. The latest accepted model-facing input bounds replay
reconstruction while raw accepted payloads remain retained. Approval waits keep
their child generation until resolution, and fresh authority still gates the
subsequent submission. Identity-bound control writes can settle undispatched work
or reconcile retained facts after revocation without exposing protected replay.
[ADR 0055](../adr/0055-execution-drivers-rotate-around-accepted-work.md) records
these constraints. Existing parent bodies have not yet adopted the driver.

2026-10-28: Optional summaries are accepted `ModelSummary` operations, counted
against the existing model-turn and actual-attempt allowances. Protected model
inputs add optional predecessor/source/accepted-summary provenance without
changing historical format-1 bytes. The driver reuses a committed summary for its
exact source digest. Summary requests have no tools; invalid summary results fail
without dispatching tools or resampling indefinitely. Required source overflow
refuses explicitly. [ADR 0056](../adr/0056-context-summaries-are-accepted-accounted-model-operations.md)
records the context-versus-authority boundary.

2026-10-28: New leaf Skill parents freeze assignment input/menu once and await
the registered execution child behind `shikigami-durable-execution-v1`. A matching
existing assignment bypasses Skill loading and menu description. Pending work
requires its exact live binding; completed results read protected storage without
provider lookup. Existing memory/session/sink owners retain their labels and
codecs, and session completion records the pinned model id directly. Native menu
description is separate from trusted accepted-operation preparation. Unused driver
wakes are cancelled. [ADR 0057](../adr/0057-skill-parents-admit-frozen-assignments-and-await-execution-children.md)
records these boundaries. Conversation and ephemeral/configuration/recovery work
remain open.

## Outcomes & Retrospective


Milestone 1 establishes the storage contract consumed by the remaining runner and
driver work. `Execution.Transcript`, `Execution.Store`, `Execution.Policy.Types`
and the terminal validator own application codecs, protected payload admission,
operation identity and atomic outcome/cursor/accounting. The checked
`ExecutionLifecycle` and `execution_lookup` share the existing catalog. ADR 0053
records the durable boundary. Production model/tool recovery remains in milestones
2–4; the existing coarse Skill loop has not been replaced by this checkpoint.

Validation from `a156a6f`, using the existing isolated Cabal project for the
baseline Kikan paths, passed:

```bash
cabal build --project-file=.dev/mp13.cabal.project all
cabal test --project-file=.dev/mp13.cabal.project shikigami-core-test shikigami-core-postgres-test shikigami-agent-test shikigami-server-test shikigami-workers-test --test-show-details=direct --test-options='--num-threads=1'
cabal test --project-file=.dev/mp13.cabal.project shikigami-core-test shikigami-core-postgres-test --test-show-details=direct --test-options='--num-threads=1'
just migration-schema-isolation
just keiro-gate a156a6f
git diff --check
```

The first full run passed 476 core, 276 PostgreSQL, 37 agent, 63 server and 98
worker cases. After the fenced read boundary, the final affected suites passed
476 core and 277 PostgreSQL cases, including all 16 transcript cases. The complete
gate passed check, inspection, deterministic generation, generated behavioral
witnesses/read-model conformance and diff: all 15 findings are additive and
`breaking: false`. The full build passed after the final reader changes. No bounds
or dependency pins changed; APIs were checked against the selected released
Keiro 0.18.0.0 and Baikai 0.7.2.0 sources after Mori discovery.

The rollback fixture refuses after protected outcome, cursor, call facts and root
settlement writes. It proves all of those writes and the lifecycle append roll
back, then the same expected revision succeeds. FRIC-10/FRIC-11 are resolved by
the recipe fix and isolated generation probe; no applied SQL was edited.


The policy/tool checkpoint passed the complete suites: 485 core, 281 PostgreSQL,
37 agent, 63 server and 98 worker cases. The new cases cover immutable individual
tool acceptance and duplicate outcomes, the real approval child/token resolution
path with conflicting/wrong tokens, fresh authorization refusal after approval,
permission timeout and expiry at preparation, accounted repair exhaustion, strict
policy overrides and context compaction. Both typed and dynamic leased tools
retain fresh exact-action guards. The complete gate against `1d79998` passed with
no findings and `breaking: false`. This is partial milestone-2 evidence;
agent/operator configuration and recorded summaries still remain.

The full build and migration schema isolation pass. The fenced executor checkpoint
passed 490 core, 294 PostgreSQL, 37 agent,
63 server and 98 worker cases. The complete gate against `93829c4` passes with
`breaking: false`. Its one advisory fold warning is the new unresolved-observation
self-transition; regeneration changes the fold fingerprint so cached snapshots are
invalidated automatically. Generated behavioral witnesses and historical fixture
suites pass. The registered execution projection/query identities are unchanged.

New evidence covers actual queue acceptance rollback, racing attempt ids across
different roots, one claim/start under duplicate delivery, expiry before and after
dispatch, late receipts, retained-fact reconciliation, no double billing/counters,
real HTTP prepared dispatch, a lost wake repaired after restart/revocation without
another request, native rich output committed before cleanup, unknown tool invoice
cost versus an explicit no-invoice declaration, finite invoice refusal before queue
acceptance, current-wake rotation and an old observation timer that cannot journal
into its successor. Queue v4 has frozen v1–v3 readers and refuses historical route
escalation. Runtime and operator output do not expose wake tokens or replay bodies.

These are executor primitives and explicit-route evidence. The production driver,
parent workflow patches, output-summary integration, class-specific recovery wiring
and configuration remain open; neither milestone 2 nor 3 is marked complete.

The callable driver checkpoint passes all 34 focused `ExecutionTranscript`
PostgreSQL cases. Four new driver cases qualify lost queue delivery/restart with
one actual attempt, exact two-tool positional replay, cancellation without a
provider call, and Approval child restart followed by fresh authority refusal
before tool submission. The full gate against `12c4d06` passes, with one additive
new-workflow finding and unchanged stored-data replay. Parent patches, summaries,
configuration and class-specific recovery remain open; this checkpoint does not
close milestone 3. The full build and complete suites pass: 490 core, 298
PostgreSQL, 37 agent, 63 server and 98 worker cases.

The summary checkpoint passes 492 core and 300 PostgreSQL cases, including
restart immediately after summary acceptance, exact accepted-summary references,
ordinary attempt accounting, a tool-requesting summary that dispatches no tool,
historical model-input bytes, and explicit oversized-summary-source refusal.
The complete gate against `d3f24e8` passes with no findings and `breaking: false`.
A final provenance check also refuses an accepted summary with unsupported source
provenance rather than resampling it; the affected execution suites pass after
that change. The full build passes. This closes the recorded-summary portion of
milestone 2; configuration, parent
workflow adoption and remaining recovery qualification are still open.

The agent-parent checkpoint passes the complete suites: 493 core, 303 PostgreSQL,
37 agent, 63 server and 98 worker cases. The full build passes. The complete gate
against `d373cb3` reports one additive `WorkflowEvolutionGuardAdded` finding and
`breaking: false`; the guard contains the entire declared body change. New cases
qualify frozen Skill/menu admission, existing-snapshot reuse after Skill retirement,
accepted output after provider retirement, a retained pending binding under changed
defaults, refusal of a retired pending binding before IO, and menu-lease release
before a no-tool model call. Driver completion leaves no unused pending awakeable.
Five explicit old-patch fixtures retain coarse lease/retry and selection-step
crash coverage; production options activate the new branch. Conversation adoption,
configuration/ephemeral policy and recovery-class qualification still prevent
milestones 2 and 3 from closing.

The conversation checkpoint passes 496 core, 303 PostgreSQL, 37 agent, 63 server
and 98 worker cases. It qualifies accepted ingress redelivery without model IO,
two driver-backed conversation turns with retained root/selection/session,
completed replay after provider retirement, chronological frozen history,
one reply per turn, and both historical and new stale idle timers leaving the
successor journal untouched. Context and summary fixtures preserve the format-2
request marker and historical format-1 bytes. Configuration, ephemeral/one-off
adoption, class-specific recovery and operator inspection remain open; milestones
2 and 3 are not complete. The full build passes. The complete gate against
`7c3ed06` passes with one additive `WorkflowEvolutionGuardAdded` finding and
`breaking: false`.

The policy/one-off checkpoint passes 503 core, 303 PostgreSQL and 37 agent cases;
the unchanged server and worker suites pass 63 and 98 cases. Configuration
fixtures qualify file/environment/CLI precedence, strict bounds, Dhall overrides
and omitted historical defaults. Ephemeral fixtures cover bounded repair, rich
tool observations, denied/human callbacks, an uncertain effect invoked once, and
ordinary model ceilings. The real parent/HTTP fixture now uses the production
foreground driver. Snapshot reuse ignores a newly invalid process policy and
does not reload input or tools. The full build and complete gate against
`c8561ae` pass; the gate reports no findings and `breaking: false`. Remaining
class-specific recovery and inspection prevent milestone completion.

## Context and Orientation


`shikigami-core/src/Shikigami/Behavior/Skill.hs` performs its loop in `runSkillWith`/`runToolPath`; `appendToolResult` combines dispatch with in-memory context updates. `Behavior/Run.hs` supplies a default eight-turn ceiling and transient retry behavior. `Agent/Workflow.hs` journals ordinary execution as one `run-behavior-v2` step; `Agent/Conversation.hs` does the same in `processRotatingTurn` and loads prior turns inside that step. `finishSuccessfulRun` and `recordAssistantTurnAndEnqueueReply` already own terminal integration and must continue to do so.

A replay transcript is the complete accepted sequence needed to reconstruct execution; semantic memory is a relevance-ranked optional input and call evidence is an audit observation. They cannot substitute for each other. `Attestation/Evidence.hs` uses an IORef collector and ordinal correlation, so it cannot be the transcript store. Baikai Response has no supported JSON codec and Context, Options and ModelCallEvidence are encode-only. Define versioned Shikigami records rather than invent upstream decoders. Mori-located dependency source belongs to `mori://shinzui/baikai`; source artifact handles are pending.

[ADR 0010](../adr/0010-run-evidence-lifecycle-and-payloads-have-one-atomic-boundary.md) requires atomic lifecycle/payload evidence and respects encode-only records. [ADR 0025](../adr/0025-capability-overlays-are-requests-for-additive-model-tools.md) pins provider leases and currently permits only observation overlays durably. [ADR 0036](../adr/0036-external-agent-actions-require-fresh-exact-authorization.md) keeps fresh action checks; a harness permission is a local admission result, never a reusable external proof. [ADR 0015](../adr/0015-a-kioku-write-answers-on-two-layers-and-a-journaled-step-keeps-its-bytes.md) preserves journal bytes and separates storage failure from domain refusal. [ADR 0030](../adr/0030-an-approval-request-is-a-durable-child-workflow.md) makes each approval a dedicated `shikigami.approval` child keyed by a stable `ReviewRequestId` with a journaled run-local policy snapshot; milestone 2's permission binding extends that child rather than adding a second approval path. [ADR 0022](../adr/0022-the-journal-ends-at-enqueue-and-receipts-own-delivery-truth.md) separates journaled decisions from delivery receipts; milestone 3's submit/observe executor follows the same split, with the workflow journaling accepted work and the executor's claim and outcome rows owning what actually happened.

The repository is a Cabal multi-package Haskell service. `shikigami-core` owns domain behavior and store adapters; `shikigami-workers` owns queue, resume and timer processes; `shikigami-server` owns operator commands. `shikigami-migrations/sql-migrations/manifest` owns append-only SQL ordering. `shikigami-core/test-postgres/Main.hs` registers tests using `Shikigami.Migrations.TestSupport.withShikigamiMigratedSuite`, which supplies isolated disposable PostgreSQL databases. Register new modules and tests in the owning Cabal file and test entry point; generated files under `Generated/` are regenerated, never hand-edited.


## Plan of Work


### Milestone 1: Establish the durable execution and operation contract

Create `shikigami-core/src/Shikigami/Execution/Transcript.hs`, `Execution/Store.hs` and an execution lifecycle declaration under `domain/`. Use the checked aggregate/catalog pattern from `Attestation/EvidenceStore.hs` for authoritative lifecycle transitions and atomic query rows. Admit one stable execution id per run or conversation assignment. Snapshot loaded Skill instructions, initial recalled input, pinned execution selection, capability descriptor identities, policy version/configuration and payload digests before use.

Accept each logical model request, tool operation and model-assisted summary under a stable operation id and immutable request fingerprint. A model response containing several tools records each tool's position within that committed response as persisted data; no identity derives from a retry-local counter or a provider-assigned id alone. Actual transport retries get separate attempt ids from plan 81. Store versioned application-owned assistant text, tool call name/arguments/id, tool observations, finish reasons and supported continuation facts. Reject unsupported/corrupt versions before dispatch.

Keep sensitive replay bodies in an access-controlled application payload table, referenced by digest/id from operational state; ordinary operator output shows metadata only. Set a bounded per-operation payload size and explicit oversized-payload refusal. Permit only runtime/authorized replay reads, exclude credentials and authorization proofs, and retain every payload needed by a live execution or handoff. A completed outcome, its next-progress cursor, normalized evidence facts and resource settlement must commit together through transaction-level hooks. Preserve raw provider evidence separately and correlate it without creating a second run-evidence lifecycle. Prove fault rollback and fresh-connection reconstruction in `ExecutionTranscriptSpec`.

### Milestone 2: Split policy evaluation from external dispatch

Create `Execution/Policy.hs` and `Execution/Runner.hs`. Policies consume validated durable state and produce context views, admission constraints or proposed work; the runner owns IO and records it. Compose in a fixed order: terminal/cancellation/cutoff checks; hard scope/model/permission constraints; output validation; resource reservation; context selection/compaction; dispatch with a final fresh authority check. A context view cannot override an earlier denial. Validate terminal output before marking success; a configured bounded repair consumes ordinary attempts and ends with a visible validation failure when exhausted. A pending human decision parks the same operation and does not consume a new logical turn. Adapt `shikigami-core/src/Shikigami/Agent/Approval/Workflow.hs` and `Agent/Approval.hs` rather than introducing another approval system. Persist a permission request binding the execution id, logical operation id/fingerprint, exact requested scope, policy version and expiry to one `ReviewRequestId`. The parent driver uses the existing approval child and authorized opaque-token resolution through `shikigami-server/src/Shikigami/Server/Command/ResolveApproval.hs`; a public review id alone never authorizes a response. Accept/deny resolves the bound request once; identical repeats converge, conflicting or expired resolutions return a bounded refusal. Never expose tokens in ordinary inspection or logs. On wake, load the recorded decision, ensure its binding still matches, then recheck current lifecycle, root limits and fresh exact external authorization. Generation rotation must preserve the permission binding and publish only the current wake token. Test the real resolution command/library path, duplicate and conflicting decisions, wrong token, expiry, restart and authority revocation.

Export defaults and supported agent/operator overrides within admitted profile limits, preserving simple one-completion Skills. Compaction changes only the model-facing view and records truncation/summary provenance; accepted facts, pending messages and ledger totals remain. Model-assisted compaction is itself a recorded model operation. Replace bundled tool dispatch with individually accepted tools and outcome commits. Reacquire exact pinned capability revisions for unfinished tools only. Define recovery by operation class: repeat observation with a new accounted attempt when safe; retry idempotent effects with the same logical key; otherwise reconcile or expose `UnresolvedOperation`. Never label an unobserved external effect cancelled or exactly-once.

Run policy fixtures with compaction, tool denial, exhausted resources, changed offered tools and a held human approval. Revocation after approval must still prevent the protected callback. A failed release of a provider lease cannot erase committed outcomes.

### Milestone 3: Integrate a resumable execution driver with both lifecycles

Add a checked execution-driver workflow under `Execution/Workflow.hs`, register it in `Workflow/Registry.hs`, and pass runtime dependencies through `AgentRunDeps`. A driver advances one bounded accepted operation phase per generation and returns/parks durably. Long external calls use a durable submit/observe job boundary with stable operation/attempt keys: persist accepted work, release the workflow advance, and let a separately bounded executor publish outcomes. Reuse existing queue infrastructure; do not hold a workflow lease while waiting on a long process. Short provider execution must still have explicit timeouts and attempt ownership, not an unbounded callback. Fault-inject the submission/observation gap before promoting this driver. The durable queue payload names an already accepted operation and prepared attempt; duplicate delivery does not itself allocate another attempt. Atomically claim that attempt with owner, monotonic claim generation and expiry, then conditionally record dispatch-start before external IO. Only that claim generation may advance the operation or commit its outcome. Redelivery while claimed observes/retries later; a dispatch-start record whose owner disappears becomes uncertain, not automatically redispatched. A replacement first applies the operation-class reconciliation policy. A genuinely safe new transport retry allocates a new attempt and resource reservation while preserving the logical operation/idempotency key. Queue visibility or claim expiry alone cannot authorize another uncertain mutation. Fencing prevents stale completion from advancing state; retain a late receipt as reconciliation evidence rather than discarding a potentially real effect. Couple claim/outcome checks to resource settlement so stale completions cannot release another owner's reservation. Test two executors receiving the same queue entry, expired claims before and after dispatch-start, and a late former owner's completion.

Patch both existing agent-run and conversation bodies to start/await the execution driver, keeping old coarse behavior for old journals. A parked human decision suspends the driver and parent rather than throwing a transient behavior retry. A terminal execution rejoins existing memory/session/sink or atomic conversation-reply ownership, keyed by the same execution outcome. Rotation retains execution, root, selection, pending approval and cursor references. Restrict conversation tools to capabilities already admitted for that lifecycle; this change alone does not enable overlays or mutation.

The durable `shikigami-agent/src/Shikigami/Agent/Command/AgentRun.hs` uses this path. Database-free `Command/RunBehavior.hs` explicitly uses ephemeral recording and makes no restart guarantee; foreground launches remain separate. Follow [workflow versioning](../workflow-versioning.md) for every durable-body change. Keep old journal populations on real old branches behind newly declared patch ids; preserve result codecs. Add declarations to `domain/shikigami.keiro-workspace`, regenerate the runtime and conformance artifacts, and union new workflow patch sets in `shikigami-core/src/Shikigami/Workflow/Versioning.hs`. Long-lived workflows restore a seed first, use static labels within each generation, rotate with `continueAsNew`, and republish generation-owned wake references. Do not invoke the pre-v1 reset exception without separately proving all four documented empty-population conditions. Default this plan to compatible evolution.

### Milestone 4: Qualify recovery and provide bounded inspection

Add operator `executions inspect EXECUTION --json` support with state, progress, denied/cancelled/unknown operations and protected payload references. Document policy overrides and a composed-policy example in a new `docs/operations/durable-execution.md`. Extend core/PostgreSQL and conversation fixtures, plus one-off tests. Include hooks for a coordination tool that commits an accepted message then loses the response; plan 84 supplies the real implementation, but the harness must already prove reuse of a committed operation outcome and preservation of an opaque accepted-message reference.


## Concrete Steps


Run from the repository root in the existing development environment; if native tools are unavailable, enter `nix develop` first. PostgreSQL tests own disposable databases and must not be pointed at production. Capture a baseline before implementation, then run the following after each applicable milestone:

```bash
MP14_BASE=$(git rev-parse HEAD)
cabal build all
cabal test shikigami-core-test shikigami-core-postgres-test shikigami-agent-test shikigami-server-test --test-show-details=direct
just migration-schema-isolation
```

The build and tests must exit zero; tests report all cases passed. These are future implementation checks, not results of creating this plan. Add the named new test groups before using their success as evidence. If domain or workflow contracts change, scaffold with the checked workspace, stage/commit generated artifacts so the existing regeneration check compares the intended baseline, then run:

```bash
just keiro-gate "$MP14_BASE"
```

The gate must report no unexplained breaking change and generated conformance must pass. Record actual commands, baseline revision and bounded evidence in the living sections. Dependency source lookup starts with Mori; no new dependency bound is selected here. Before a later bound, pin or workaround change, verify the authoritative registry and upstream release tags as well as the Mori-located source.


## Validation and Acceptance


Use `DurableExecutionSpec` with deterministic provider and tool counters. Crash after acceptance, external success, outcome commit and terminal commit; restart with fresh process-local state. Completed outcomes never dispatch again. Safe retries reuse the logical key but record each actual attempt; unsafe effects remain unresolved. Compare final context, policy decisions, usage, one session result, declared memory writes and sink intents with uninterrupted execution. Repeat for a conversation and assert one assistant reply. Duplicate executor delivery permits only one claim to dispatch; expired dispatch-start claims stay uncertain until operation-class reconciliation, and late stale completions cannot advance state or double-settle resources. A corrupted transcript or changed pinned binding fails before IO. Budget exhaustion remains after compaction and restart, and concurrent proposals cannot overspend. Park/approve/deny across restart and revoke external authority before dispatch. Historical and new workflow populations pass replay/evolution tests. Plan 84 additionally closes IR-14 acceptance 8 with actual continuing messages; do not mark that integration case satisfied by the fake alone.


## Idempotence and Recovery


Use additive, schema-qualified migrations created through `just new-migration`; never edit an applied migration or upstream private tables. Re-running migrations and accepted commands must converge. Retain payloads and deduplication records referenced by live executions, idle sessions, pending handoffs or unresolved effects; terminal workflow GC is not permission to delete them. Roll forward after introducing a journal patch, because an older binary cannot serve its new branch. A storage or authority failure stops admission and preserves recorded work; retry with the same logical identities, not a newly minted root. At completion, distill durable storage/interface decisions into local ADRs under the contract in `agents/skills/exec-plan/ADR.md`.


## Interfaces and Dependencies


This plan owns execution transcript codecs, operation state, driver workflow, policy configuration and bounded executor submit/observe contract. It consumes root `OperationId`/`AttemptId` and settlement hooks from plan 81 and `ExecutionSelection` from plan 82. Expose `acceptOperation`, `recordOutcomeAndAdvance`, `loadExecution`, `reconcileOperation`, and `runExecution` with typed accepted/conflict/parked/unresolved/terminal results; no raw upstream Response decoder. Pending instruction references are opaque correlation until plan 84 resolves their mailbox authority. `docs/plans/75-persist-decision-call-evidence-across-retries-and-restarts.md` owns typed-decision evidence; integrate normalized compliance facts without replacing it. Plan 84 and plan 87 consume retained execution references. Mutating repository effects remain denied until independently owned IR-11 supplies an admitted recovery/fencing provider.
