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
---

# Recover durable model and tool turns with composed policies

This ExecPlan is a living document. The sections Progress, Surprises & Discoveries,
Decision Log, and Outcomes & Retrospective must be kept up to date as work proceeds.
If durable project context changes, update or create ADRs in docs/adr/ in the same change.


## Purpose / Big Picture


Resume a Skill or conversation from its accepted model/tool history after a crash, preserving policy decisions, usage, and one logical terminal result. Fulfill [IR-14](../improvement-requests/record-durable-model-tool-turns-and-compose-harness-policies.md). Hard dependencies are `docs/plans/81-enforce-root-resource-reservations-across-durable-work.md` and `docs/plans/82-pin-governed-execution-settings-for-agent-assignments.md`. Continuing-session operations integrate later through plan 84; they are not a prerequisite for this independently testable harness.


## Progress


Implementation has not started. Seed unchecked milestone entries when implementation begins.


## Surprises & Discoveries


None recorded during implementation.


## Decision Log


2026-10-10: Use a separate checked execution authority with Shikigami-owned replay records and atomic outcome/progress/resource settlement. Keep the existing terminal memory/sink/reply owners. Long work uses durable submission and observation so workflow concurrency is not a proxy for executor capacity.


## Outcomes & Retrospective


To be filled during implementation. Do not claim request completion until every acceptance case below, including stated external integration gates, has evidence.


## Context and Orientation


`shikigami-core/src/Shikigami/Behavior/Skill.hs` performs its loop in `runSkillWith`/`runToolPath`; `appendToolResult` combines dispatch with in-memory context updates. `Behavior/Run.hs` supplies a default eight-turn ceiling and transient retry behavior. `Agent/Workflow.hs` journals ordinary execution as one `run-behavior-v2` step; `Agent/Conversation.hs` does the same in `processRotatingTurn` and loads prior turns inside that step. `finishSuccessfulRun` and `recordAssistantTurnAndEnqueueReply` already own terminal integration and must continue to do so.

A replay transcript is the complete accepted sequence needed to reconstruct execution; semantic memory is a relevance-ranked optional input and call evidence is an audit observation. They cannot substitute for each other. `Attestation/Evidence.hs` uses an IORef collector and ordinal correlation, so it cannot be the transcript store. Baikai Response has no supported JSON codec and Context, Options and ModelCallEvidence are encode-only. Define versioned Shikigami records rather than invent upstream decoders. Mori-located dependency source belongs to `mori://shinzui/baikai`; source artifact handles are pending.

[ADR 0010](../adr/0010-run-evidence-lifecycle-and-payloads-have-one-atomic-boundary.md) requires atomic lifecycle/payload evidence and respects encode-only records. [ADR 0025](../adr/0025-capability-overlays-are-requests-for-additive-model-tools.md) pins provider leases and currently permits only observation overlays durably. [ADR 0036](../adr/0036-external-agent-actions-require-fresh-exact-authorization.md) keeps fresh action checks; a harness permission is a local admission result, never a reusable external proof. [ADR 0015](../adr/0015-a-kioku-write-answers-on-two-layers-and-a-journaled-step-keeps-its-bytes.md) preserves journal bytes and separates storage failure from domain refusal.

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
