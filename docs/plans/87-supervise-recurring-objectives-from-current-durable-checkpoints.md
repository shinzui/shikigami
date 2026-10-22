---
id: 87
slug: supervise-recurring-objectives-from-current-durable-checkpoints
title: "Supervise recurring objectives from current durable checkpoints"
kind: exec-plan
created_at: 2026-10-10T23:32:16Z
master_plan: "docs/masterplans/14-deliver-adaptive-autonomous-objectives-with-durable-workers.md"
intention: "intention_01m4m2pjz6es9v9aqq5jq9c4ee"
provenance:
  created_by:
    model: "gpt-6-astra"
    harness: "codex-cli"
    at: 2026-10-10T23:32:16Z
  reviews:
    - model: "claude-fable-5-1"
      harness: "claude-code"
      at: 2026-10-22T01:19:09Z
      verdict: "comments"
      note: "Scheduler/Timer symbols and 100-row dispatcher verified; Keiro ADR-7 handle resolves; IR-13 stated as hard dep while acceptance treats it as completion gate"
  revisions:
    - model: "claude-fable-5-1"
      harness: "claude-code"
      at: 2026-10-22T01:19:09Z
      mode: "update"
      note: "IR-13 provider is a completion gate, not a start gate"
---

# Supervise recurring objectives from current durable checkpoints

This ExecPlan is a living document. The sections Progress, Surprises & Discoveries,
Decision Log, and Outcomes & Retrospective must be kept up to date as work proceeds.
If durable project context changes, update or create ADRs in docs/adr/ in the same change.


## Purpose / Big Picture


Maintain an explicitly authorized ongoing objective across bounded cycles without duplicate workers or stale scheduled instructions. Fulfill [IR-18](../improvement-requests/support-recurring-objective-supervision.md). A successful cycle leaves the mandate active; expiry, revocation or cancellation stops new admission while preserving uncertain effects. The hard dependency is `docs/plans/85-adapt-durable-delivery-through-validated-coordinator-decisions.md` and its transitive foundations. A delivered IR-13 checkpoint provider is a completion gate: the mandate store and wake coalescing can be built against a fixture checkpoint adapter, but this child cannot be marked Complete until real objective checkpoints come from IR-13. Plan 86 is a soft dependency for reuse of its coding fixture; recurrence can be qualified independently with governed read-only evidence.


## Progress


Implementation has not started. Seed unchecked milestone entries when implementation begins.


## Surprises & Discoveries


None recorded during implementation.


## Decision Log


2026-10-10: Keep recurrence an explicit optional phase after finite coordinator mechanics. Reuse the timer/event runtime and persist desired wakes with checkpoints; wake payloads name current-state records and never become authority.


## Outcomes & Retrospective


To be filled during implementation. Do not claim request completion until every acceptance case below, including stated external integration gates, has evidence.


## Context and Orientation


`shikigami-workers/src/Shikigami/Trigger/Scheduler.hs` supplies `shikigamiTimerFallback`, `scheduleFireAction` and `armNextRun`; `Trigger/Timer.hs` owns the bounded shared timer pass. Core `Trigger/Schedule.hs` defines existing catch-up semantics and `Trigger/Enqueue.hs` provides durable enqueue identities. Cron alone knows no ongoing objective, watermark, ownership or expiry. A mandate is the durable admission record authorizing recurrence; a watermark records the last accepted evidence item for each source. A wakeup is only a hint to read current authoritative state.

[ADR 0016](../adr/0016-a-cron-agent-runs-about-now-not-once-per-missed-minute.md) keeps missed ticks from becoming work debt. [ADR 0018](../adr/0018-a-workflow-that-ends-is-re-keyed-by-epoch.md) keeps completed workflow identities from swallowing new work. [ADR 0038](../adr/0038-runtime-startup-and-maintenance-share-validated-owners.md) establishes one timer dispatcher and shared workflow registry. The Mori-discovered [Keiro ADR-7](mori://shinzui/keiro/okf/adrs/concepts/ADR-7) assigns timer completion to its arming generation; a stale re-fire must never advance a newer cycle.

The repository is a Cabal multi-package Haskell service. `shikigami-core` owns domain behavior and store adapters; `shikigami-workers` owns queue, resume and timer processes; `shikigami-server` owns operator commands. `shikigami-migrations/sql-migrations/manifest` owns append-only SQL ordering. `shikigami-core/test-postgres/Main.hs` registers tests using `Shikigami.Migrations.TestSupport.withShikigamiMigratedSuite`, which supplies isolated disposable PostgreSQL databases. Register new modules and tests in the owning Cabal file and test entry point; generated files under `Generated/` are regenerated, never hand-edited.


## Plan of Work


### Milestone 1: Admit and control an explicit recurring mandate

Create `shikigami-core/src/Shikigami/Mandate/Types.hs`, `Mandate/Store.hs`, and a checked mandate lifecycle declaration. Store objective reference, revision, current owner/fence, admitted authority/scope, cadence and next due, bounded evidence-source descriptors, per-source watermarks, last cycle, root reference, expiry, stop condition and unresolved operation references. Require explicit recurring admission, positive bounded cadence and finite expiry/resource envelope. Ordinary finite objectives and installed Skills create no mandate.

Add operator commands `mandates create`, `mandates inspect MANDATE --json`, `mandates update` and `mandates cancel` under `shikigami-server/src/Shikigami/Server/Command/`, with current authorization, expected revision and caller operation id. A schedule extension or wider scope requires new authority. Pure/store tests refuse duplicate conflicting creates, stale edits, unauthorized extension and missing root; successful retry returns the same admitted mandate.

### Milestone 2: Coalesce events and timers around current state

Implement `Mandate/Workflow.hs` with adapters for a continuing coordinator and a fresh cycle run. Both receive stable mandate/checkpoint ids and reread current objective instructions, assignments, owner and unresolved work. Under a mandate lock accept event/timer wake ids into one active cycle; store later wake hints for bounded reconciliation. Derive cycle identities from durable mandate state rather than current wall time or model text. Process a configured maximum number of new source events per cycle. Use monotonic source sequence/cursor plus a tie-break identity; timestamps alone cannot deduplicate evidence.

Atomically commit watermark advancement, accepted logical progress references and next-due/desired-wake intent. When IR-13 is a separate transactional owner, persist an idempotent progress intent and wait for its accepted receipt before consuming the watermark; recover a lost acknowledgement by the same operation key. Reconcile desired wake intents through the existing timer owner. Add an explicit mandate kind to `shikigamiTimerFallback`, retaining the single 100-row dispatcher; do not create another cron loop. Each timer carries mandate/cycle revision and arming generation, not an authoritative old prompt.

Test a crash between checkpoint commit and timer installation, duplicate event and timer during an active cycle, and replacement instructions before an old timer fires. Resume must converge on current state, not recreate old assignments. Event notifications improve latency; a timer backstop repairs missed delivery.

### Milestone 3: Stop admission honestly and retain useful idle state

A successful ongoing cycle remains active and schedules within its admitted cadence. A no-delta cycle creates no worker, audit or repeated user notification; record a bounded observation and exponential backoff capped at the authorized maximum interval and expiry. A relevant event can wake useful work earlier within admission policy. All cycles and fresh runs propagate the same root reservations and usage.

Finite completion, stop condition, expiry, authority revocation and cancellation close new admission before new session/model/tool work. Reconcile already accepted effects and retain unresolved operations; do not pretend cancellation killed an external process. Disable/release owned timers through their public owner, and make all late events check stopped state so they cannot revive a mandate. Lease replacement increases the fence but cannot justify unsafe write handoff; reuse session/workspace reconciliation.

Register the workflow and active patch sets centrally, and retain cycle/checkpoint/transcript references required by live mandates independently of terminal workflow GC. Inspection shows last cycle, watermark, owner, next due, stop reason and unknown work. Add `docs/operations/recurring-objectives.md` showing explicit finite versus ongoing admission. Follow [workflow versioning](../workflow-versioning.md) for every durable-body change. Keep old journal populations on real old branches behind newly declared patch ids; preserve result codecs. Add declarations to `domain/shikigami.keiro-workspace`, regenerate the runtime and conformance artifacts, and union new workflow patch sets in `shikigami-core/src/Shikigami/Workflow/Versioning.hs`. Long-lived workflows restore a seed first, use static labels within each generation, rotate with `continueAsNew`, and republish generation-owned wake references. Do not invoke the pre-v1 reset exception without separately proving all four documented empty-population conditions. Default this plan to compatible evolution.


## Concrete Steps


Run from the repository root in the existing development environment; if native tools are unavailable, enter `nix develop` first. PostgreSQL tests own disposable databases and must not be pointed at production. Capture a baseline before implementation, then run the following after each applicable milestone:

```bash
MP14_BASE=$(git rev-parse HEAD)
cabal build all
cabal test shikigami-core-test shikigami-core-postgres-test shikigami-workers-test shikigami-server-test --test-show-details=direct
just migration-schema-isolation
```

The build and tests must exit zero; tests report all cases passed. These are future implementation checks, not results of creating this plan. Add the named new test groups before using their success as evidence. If domain or workflow contracts change, scaffold with the checked workspace, stage/commit generated artifacts so the existing regeneration check compares the intended baseline, then run:

```bash
just keiro-gate "$MP14_BASE"
```

The gate must report no unexplained breaking change and generated conformance must pass. Record actual commands, baseline revision and bounded evidence in the living sections. Dependency source lookup starts with Mori; no new dependency bound is selected here. Before a later bound, pin or workaround change, verify the authoritative registry and upstream release tags as well as the Mori-located source.


## Validation and Acceptance


Add `MandateSpec`, PostgreSQL `MandateStoreSpec` and worker `MandateTimerSpec` alongside `SchedulerSpec` and `TimerRecoverySpec`. Use a controllable fixture clock and real store/timer boundaries. A successful ongoing first cycle retains the mandate and next due, while equivalent finite completion has no mandate. Duplicate timer/event wakes accept one cycle; restart after progress but before timer installation preserves the watermark and repairs the wake. Current instructions supersede a stale scheduled revision. Separate expiry, revoke and cancel trials admit no new work, preserve unknown effects and ignore late wake revival. Several no-delta cycles produce zero duplicate workers/audits/notifications; a new source item resumes useful work once. Root usage never resets across fresh-run cycles or compaction. Actual objective checkpoints come from IR-13 before this child is complete; a fixture-only adapter cannot close that integration gate. This supplies UC-1 acceptance 5 without requiring publication or indefinite authorization.


## Idempotence and Recovery


Use additive, schema-qualified migrations created through `just new-migration`; never edit an applied migration or upstream private tables. Re-running migrations and accepted commands must converge. Retain payloads and deduplication records referenced by live executions, idle sessions, pending handoffs or unresolved effects; terminal workflow GC is not permission to delete them. Roll forward after introducing a journal patch, because an older binary cannot serve its new branch. A storage or authority failure stops admission and preserves recorded work; retry with the same logical identities, not a newly minted root. At completion, distill durable storage/interface decisions into local ADRs under the contract in `agents/skills/exec-plan/ADR.md`.


## Interfaces and Dependencies


This plan owns mandate fields, state transitions, wake/cycle ids, watermark/backoff semantics, mandate timer kind and inspection/control surface. It consumes IR-13 current objective/checkpoint state, plan 85's bounded coordinator cycle and acceptance contract, plan 84 worker events/fences, plan 83 execution history and plan 81 root accounting. It does not own general task state, session mailboxes, a new scheduler or another adaptive proposal engine. Expose `admitMandate`, `acceptWake`, `commitCycleProgress`, `stopMandate` and `inspectMandate` as typed commands with immutable operation keys and version checks. Preserve the existing timer claim-token and generation contracts rather than updating private timer rows. The terminal state rejects all future admission even if a stale schedule continues to fire.
