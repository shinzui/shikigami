---
id: 1
slug: shikigami-declared-agent-runtime-bootstrap
title: "Shikigami Declared-Agent Runtime Bootstrap"
kind: master-plan
created_at: 2026-06-24T23:41:08Z
intention: "intention_01kvy04813ehbv9aghj3tn4zjx"
---

# Shikigami Declared-Agent Runtime Bootstrap

This MasterPlan is a living document. The sections Progress, Surprises & Discoveries,
Decision Log, and Outcomes & Retrospective must be kept up to date as work proceeds.


## Vision & Scope

**Shikigami** (式神 — a summoned spirit-servant bound to its master's will) is a runtime in
which an autonomous system agent is *declared*, not coded. You write a short typed Dhall file
that says "run **this behavior**, when **this trigger** fires, and send the result to **these
sinks**," and a thin worker runs it forever — on a schedule, in response to events flowing
through the activity stream, or when addressed directly. The complete design is frozen in this
repository at `docs/initial-spec.md` (read it before doing anything); this MasterPlan turns that
design into a built, demonstrable runtime.

After this initiative is complete, someone can do the following, observably, from a fresh
checkout of `/Users/shinzui/Keikaku/bokuno/shikigami` in its nix dev shell:

- Write a `.dhall` file declaring an agent as `{ name, behavior, trigger, sinks }`, run
  `cabal run shikigami -- validate agents/<name>.dhall`, and see the parsed, typed declaration
  printed (or a typed error for a malformed file).
- Start the worker (`cabal run shikigami -- worker --agents agents/`) and watch a declared agent
  fire on all three trigger classes — a cron schedule, a matching `activity.v1` stream envelope,
  and an addressed delivery to the agent's inbox.
- See the agent's **behavior** run through either arm of the behavior union: a typed
  `shikumi` program executed via `shinzui/handan`, or a Skill directory (`SKILL.md`) executed via
  `shinzui/baikai` — both provable with deterministic stubs so no model key is required.
- See the agent's **sinks** dispatch: a `KawaDigest` builds a nine-field Activity Envelope and
  POSTs it to a kawa stub; a `KizashiSignal` POSTs a `CreateSignalReq` to a `shinzui/kizashi`
  stub; each sink is gated by a permission check that, when denied, is logged and skipped while
  the run still completes.
- See every agent run recorded as a **kioku session**, with the agent's prior learnings
  **recalled** before the run and its output **recorded as durable memory** after — so an agent
  that runs every hour accumulates knowledge across runs instead of starting blank each time.
- Watch the **living loop** close: the kawa stub re-publishes a produced `KawaDigest` envelope
  back onto the fixture `activity.v1` topic, and a *second* declared agent fires on it.

**The change since the spec was written.** The spec's bespoke session store (the `agent_runs`
SQL table and `Shikigami.Session` module) is **removed from this initiative and replaced** by
**kioku** (記憶, "memory"), a now-existing reusable, event-sourced memory/session library at
`/Users/shinzui/Keikaku/bokuno/kioku`. kioku gives shikigami two primitives it lacked: a
**Session** (an event-sourced record of one agent run — start/complete/fail, optional turns) and
a **Memory** (a durable, queryable learning), both scoped by a generic `MemoryScope` (a namespace
plus an optional typed entity reference). shikigami maps each agent run onto a kioku Session and
each agent learning onto a kioku Memory scoped to that agent. This both removes a table shikigami
would have built and adds a capability the original spec explicitly lacked ("it has no memory
layer at all — an agent that runs every hour learns nothing from its previous runs").

**In scope:** the shikigami four-package Haskell project; the Dhall agent-definition schema
(contract C5) and its loader and `validate` CLI; the behavior runner over both arms
(handan/shikumi and baikai) with deterministic stubs; the sink dispatcher (KawaDigest +
KizashiSignal implemented against stubs; ReiAction/DanwaConversation/ChannelEgress defined as
schema variants with stub handlers) gated by a stub permission check; the three trigger evaluators
(schedule, `activity.v1` stream via `shinzui/kafka-effectful`, addressed-event inbox) on the
keiro/shibuya/pgmq substrate; the kioku session-and-memory integration replacing the spec's
`agent_runs`; the kawa stub + fixture Kafka topic + `publish-fixture` CLI; and the end-to-end
living-loop proof with the seed detector declarations re-pointed at the real schema.

**Out of scope (referenced, not built here):** the *real* `shinzui/kawa`, `shinzui/shomei`,
`shinzui/kanmon`, and `shinzui/danwa` services — proven against stubs/fixtures, their live wiring
owned by their own plans; the cross-project improvement-requests (IR-1 mori `Agent` action, IR-2
shomei scoped service tokens, IR-3 kanmon egress) which are *named* here but authored into those
repos by other agents; executing a skill's `scripts/` (the sandbox is a deferred
autonomous-harness concern — only skill *instructions* + `allowed-tools` run); OKF concept
grounding (contract C10, owned by EP-9 elsewhere); and the real detector *programs* (EP-5 in the
`kikan` platform MasterPlan is the first consumer — this runtime proves the loop with stub
programs and the existing seed declarations). This MasterPlan also does **not** modify the kioku
repository; it consumes kioku as a pinned dependency.


## Decomposition Strategy

The initiative is decomposed into six child ExecPlans grouped into four phases by functional
concern, following the decomposition principles in `agents/skills/master-plan/MASTERPLAN.md`
(boundaries by functional concern, minimized cross-plan coupling, maximized independent
verifiability, balanced scope). The shape deliberately mirrors the structure the spec lays out in
its "High-Level Architecture" pipeline — schema/loader → behavior runner → sink dispatcher →
trigger evaluators → worker → proof — because each pipeline stage is an independently verifiable
behavior with a clean seam to the next.

**Phase 1 — Foundation.** EP-1 stands up the four-package project (scaffolded from the
`shinzui/kizashi` template), the `shikigami-api` wire types, the canonical `schema/Agent.dhall`
(contract C5), the Dhall loader, the `validate` CLI, and the migration package that composes
kioku's migrations (so kioku's tables exist) plus shikigami's own suppression table. This is the
hard root: nothing else compiles without the wire types, the schema, and the buildable project.

**Phase 2 — Capabilities (parallel after EP-1).** Three independent capability work streams, each
a hard dependent of EP-1 only, that can proceed concurrently once the foundation lands:

- **EP-2 — Behavior runner + kioku session/memory integration.** The `behavior` union dispatcher
  (handan/shikumi arm with a `noop-summary` stub program; baikai Skill arm with a stub provider),
  plus the kioku integration that opens a session per run, recalls the agent's prior memory, and
  records the run's output as a new memory. This is where the spec's removed `agent_runs` is
  replaced by kioku.
- **EP-3 — Sink dispatcher + permission gate + kawa stub.** `Shikigami.Sink.dispatch` with the
  KawaDigest and KizashiSignal handlers (against stubs), the other sinks defined with stub
  handlers, the C11 permission gate (stub allow-list), and the `stub-kawa` server.
- **EP-4 — Trigger evaluators + `activity.v1` stream consumer.** The schedule evaluator, the
  Kafka stream consumer via `shinzui/kafka-effectful` with the keiro idempotent inbox and the
  feedback guard, the addressed-event inbox, and the fixture-topic plumbing + `publish-fixture`
  CLI. It is verifiable on its own (unit-test the matcher/cron; feed a fixture envelope and watch
  it match) before the worker exists.

**Phase 3 — Integration.** EP-5 builds the thin supervised worker (`shinzui/shibuya`
`QueueProcessor` over `shinzui/pgmq-hs`) that ties a fired trigger to a behavior run to a sink
dispatch to a kioku session record, plus the suppression gate and the `worker` CLI. It hard-depends
on all three Phase-2 plans because it orchestrates their seams.

**Phase 4 — Proof.** EP-6 re-points the seed detector declarations (`agents/detectors/*.dhall`) at
the real `schema/Agent.dhall`, and delivers the full end-to-end living-loop proof (load → trigger
fires on all three classes → behavior runs on both arms → sink dispatches → kioku session+memory
recorded → kawa stub re-publishes → second agent fires; plus the feedback-guard, permission-denial,
and memory-persists-across-runs proofs) and records the runtime's maturity as a `shinzui/mori`
capability record. It hard-depends on EP-5.

**Alternatives considered.** (a) *One mega-plan* — rejected; the runtime spans Dhall, Kafka,
handan/shikumi, baikai, kioku, and the keiro/shibuya/pgmq substrate, far exceeding five milestones
and ten files. (b) *Merge the behavior runner and sink dispatcher into one "run an agent" plan* —
rejected; they are distinct functional concerns (one runs an LLM/typed program; the other does
authorized HTTP egress), they exercise different substrate, and keeping them separate lets them be
built and verified in parallel with stub seams between them. (c) *Merge the trigger evaluators and
the worker* — rejected; the trigger evaluation logic (cron, the stream matcher, keiro inbox
dedupe, the feedback guard, offset/checkpoint policy) is a large, independently testable concern,
while the worker is the thin supervised loop that integrates everything; splitting balances scope
and improves parallelism. (d) *Build a bespoke `agent_runs` session store as the spec originally
wrote* — rejected per the user's update: kioku now owns reusable memory/session, so shikigami
consumes it (see Decision Log and Integration Point IP-3).


## Exec-Plan Registry

| # | Title | Path | Hard Deps | Soft Deps | Status |
|---|-------|------|-----------|-----------|--------|
| 1 | Scaffold, Agent Schema, Loader, and Validate CLI | docs/plans/1-scaffold-agent-schema-loader-and-validate-cli.md | None | None | Complete |
| 2 | Behavior Runner and kioku Session and Memory Integration | docs/plans/2-behavior-runner-and-kioku-session-and-memory-integration.md | EP-1 | None | Complete |
| 3 | Sink Dispatcher, Permission Gate, and kawa Stub | docs/plans/3-sink-dispatcher-permission-gate-and-kawa-stub.md | EP-1 | EP-2 | Complete |
| 4 | Trigger Evaluators and the activity.v1 Stream Consumer | docs/plans/4-trigger-evaluators-and-the-activity-v1-stream-consumer.md | EP-1 | EP-2 | Complete |
| 5 | The Supervised Worker and Run Orchestration | docs/plans/5-the-supervised-worker-and-run-orchestration.md | EP-2, EP-3, EP-4 | None | Complete* |
| 6 | End-to-End Living-Loop Proof and Detector Conformance | docs/plans/6-end-to-end-living-loop-proof-and-detector-conformance.md | EP-5 | None | Not Started |

Status values: Not Started, In Progress, Complete, Cancelled.
Hard Deps and Soft Deps reference other rows by their # prefix (e.g., EP-1, EP-3).


## Dependency Graph

EP-1 is the root. It produces the buildable four-package project, the `shikigami-api` wire types
(`AgentDecl`, `Behavior`, `Trigger`, `StreamMatch`, `Sink`, and the nine-field `ActivityEnvelope`),
the canonical `schema/Agent.dhall` and its Haskell decoders, the loader, the `validate` CLI, the
`cabal.project` pin-set (kioku + the kikan stack + handan/shikumi/baikai/kafka-effectful/dhall), and
the migration composition that lands kioku's tables plus shikigami's suppression table. Every other
plan needs these artifacts to compile, so all hard-depend on EP-1.

EP-2, EP-3, and EP-4 each hard-depend only on EP-1 and are mutually independent — they can be
implemented in parallel once EP-1 is Complete. EP-3 and EP-4 carry a *soft* dependency on EP-2: the
sink dispatcher (EP-3) consumes the behavior runner's output `Value`, and the stream consumer
(EP-4) ultimately hands a fired trigger to the runner — but each is built and verified against a
stub seam (a fixed output `Value` for EP-3; a stub run-enqueue for EP-4), so neither blocks on EP-2.

EP-5 (the worker) hard-depends on EP-2, EP-3, and EP-4 because it orchestrates all three: it drains
a trigger-produced job, calls `runBehavior` (EP-2), dispatches each `Sink` (EP-3), and records the
run as a kioku session (EP-2's seam). It cannot meaningfully run until those three seams exist.

EP-6 (the proof) hard-depends on EP-5: the living-loop, feedback-guard, permission-denial, and
across-run memory proofs all drive the assembled worker end to end, and the detector conformance
re-points the seed declarations at the schema EP-1 owns and runs them through the full pipeline.

The critical path is therefore EP-1 → (EP-2 ∥ EP-3 ∥ EP-4) → EP-5 → EP-6. With parallel effort the
wall-clock length is EP-1 + max(EP-2, EP-3, EP-4) + EP-5 + EP-6.


## Integration Points

**IP-1 — `shikigami-api` wire types (contract C5).** The client-safe wire types live in
`shikigami-api` (`Shikigami.Api.Agent`): `AgentDecl { name, behavior, trigger, sinks }`,
`Behavior = ShikumiProgram { task } | Skill { path }`, `Trigger = ScheduleTrigger { cron } |
StreamTrigger { match } | EventTrigger { eventType }`, `StreamMatch { verb, source, subjectType }`
(all optional), and `Sink = KawaDigest {…} | KizashiSignal {…} | ReiAction {…} | DanwaConversation
{…}` (plus the channel-egress variant per Open Question). These must have **no** `hasql`/`effectful`/
`kiroku` dependencies so the worker and CLI share them. **EP-1 owns and defines these.** EP-2/EP-3/
EP-4/EP-5 import them; none redefine them. Any field a Phase-2 plan needs that is not yet present is
added to the wire type **in `shikigami-api` by amending EP-1's deliverable**, recorded here.

**IP-2 — `schema/Agent.dhall` (contract C5) and the seed-detector reconciliation.** The canonical
Dhall schema lives at `schema/Agent.dhall` and must decode into IP-1's `AgentDecl`. **EP-1 owns it.**
There is a shape mismatch to reconcile, because two prior shapes exist: (a) the spec's illustrative
schema in `docs/initial-spec.md` uses `sinks : List Sink` and behavior union `< ShikumiProgram |
Skill >`; (b) the **seed detector declarations** at `agents/detectors/{schema.dhall,
stalled-intention.dhall,at-risk-customer.dhall}` use a *singular* `sink`, a richer `Behavior =
< Deterministic | Program | Skill >`, a richer `Trigger = < Observe | Schedule | Addressed >`, and a
richer `Sink = < RaiseSignal | RecordReiAction >`. **EP-1 designs the canonical schema as the
superset that the spec's C5 names anchor** (list `sinks`; behavior union covering the typed-program
and skill arms; the three C3 trigger classes; the producer sink set), and **EP-6 re-points the seed
detectors** from `let Schema = ./schema.dhall` to an import of the canonical `schema/Agent.dhall`,
adapting the singular `sink` to `sinks = [ … ]` and aligning the `Observe`/`Deterministic`/
`RaiseSignal` field names to the canonical variants. EP-1 must therefore read the seed declarations
and ensure the canonical schema can express everything they need (a deterministic-rule behavior, an
`activity.v1` observe trigger with `subjectType`/`verbs`, and a kizashi-signal sink with
recipient routing), so that EP-6's re-point is a mechanical rename, not a redesign. This is an
integration point between EP-1 (defines) and EP-6 (consumes/re-points).

**IP-3 — kioku session/memory integration & migration composition.** This is the headline change
from the spec. `shikigami-migrations` composes `kiokuMigrations <> shikigamiOwnMigrations` —
**not** the four-term `kirokuMigrations <> keiroFrameworkMigrations <> kiokuMigrations <>
shikigamiOwnMigrations` chain, because EP-1 verified that `kiokuMigrations` *already* equals
`kirokuMigrations <> keiroFrameworkMigrations <> kiokuOwnMigrations`; re-prepending the framework
migrations would double-apply already-applied timestamps and `codd` would reject the set (see
Surprises & Discoveries and EP-1's Decision Log). kioku's read-model tables (`kioku_memories`,
`kioku_sessions`, `kioku_turns`) live in the **`kiroku`
schema**. shikigami's *own* migrations create only the suppression table `shikigami_fired` (see the
seed `agents/detectors/README.md` for its exact DDL) and any other shikigami-owned tables — **no
`agent_runs` table** (kioku's `kioku_sessions` replaces it). The scope mapping helper
`Shikigami.Memory.Scope` (in `shikigami-core`) maps an agent name to its per-agent scope
`ScopeEntity (Namespace "shikigami") (ScopeKind "agent") <agentName>` and exposes the namespace
global `ScopeGlobal (Namespace "shikigami")`. **EP-1 establishes the migration composition and the
`Shikigami.Memory.Scope` helper; EP-2 uses kioku's public API** (`Kioku.Session.start/complete/
failSession/recordTurn`, `Kioku.Memory.record`, `Kioku.Recall.getActiveByScope`, `Kioku.App.runAppIO/
AppEnv/noopTracer`, `Kioku.Api.Scope`/`Kioku.Api.Types`/`Kioku.Id`) to open a session per run, recall
the agent's prior memory, record the output as a memory, and complete the session. **Consumers
import only kioku's top-level modules + `kioku-api` types — never `Kioku.*.Domain.*` internals.**
The kioku integration plan `docs/plans/6-shikigami-memory-integration-with-kioku.md` *in the kioku
repo* (a pragmatic-v1 scaffold + memory demo, Not Started there) is prior art that EP-1 and EP-2
should read; the work it described (scaffold, migration composition, the scope helper, the
session/memory seam) is delivered here as part of the full runtime, so it need not be implemented
separately in kioku.

**IP-4 — the behavior-runner contract (`BehaviorEnv` / run `Value`).** `Shikigami.Behavior.Run`
exposes `runBehavior :: BehaviorEnv -> AgentDecl -> Value -> IO (Either RunError Value)` (the input
`Value` is the trigger payload; the output `Value` is the behavior's result). **EP-2 owns it.** The
worker (EP-5) calls it; the sink dispatcher (EP-3) consumes its output `Value`. EP-2 also owns the
program registry seam (`Shikigami.Program.Registry :: [Task]`, including the `noop-summary` stub)
and the skill runner (`Shikigami.Behavior.Skill.runSkill`). EP-3 and EP-4 build against a fixed
sample output `Value` until EP-2 lands.

**IP-5 — the `Sink` dispatch contract.** `Shikigami.Sink.dispatch :: SinkContext -> Sink -> Value ->
IO SinkResult`, with every dispatch gated by `Shikigami.Sink.Permission.checkGrant :: AgentIdentity
-> SinkKind -> IO (Either Denied ())`. A denied sink is logged and skipped (it does not fail the
run) and the denial is recorded. **EP-3 owns these.** The worker (EP-5) calls `dispatch` for each of
the agent's `sinks` with the behavior output `Value` and the agent's identity.

**IP-6 — the Activity Envelope (contract C1) and the Kafka header seam.** The nine-field envelope
(`activity_id` UUIDv7, `occurred_at`, `source`, `actor {kind,id,session?}`, `subject {type,id}`,
`verb`, `payload`, `context_refs`, `idempotency_key`) is defined once in `shikigami-api`
(`Shikigami.Api.Activity` or alongside `Agent`) with `aeson` instances. **EP-1 defines it.** EP-3's
KawaDigest sink **builds** it (with `actor.kind="agent"`, `source="shinzui/shikigami"`, minting the
UUIDv7 `activity_id`), and EP-4's stream consumer **decodes** it from `activity.v1` and runs the
`matchesStream` predicate (excluding `actor.kind="agent"` by default — the feedback guard). The
`keiro-*` Kafka headers required by the keiro idempotent inbox are produced by the `publish-fixture`
CLI (EP-4) and by the kawa stub's `--republish-topic` mode (EP-3); EP-3 and EP-4 must agree on the
exact header set, so it is documented identically in both plans.

**IP-7 — the trigger→run job (pgmq queue body).** A fired trigger becomes a job on the
`shinzui/pgmq-hs` queue named **`shikigami_run_jobs`** that the worker drains. The queue name and
the JSON job-body shape (which agent, which trigger occurrence, the trigger payload `Value`, and the
derived idempotency key) are a shared contract between **EP-4 (enqueues)** and **EP-5 (drains)**.
EP-4 defines the job shape and writes to the queue; EP-5 reads it and runs the agent. The queue is
named `shikigami_run_jobs` (deliberately *not* `shikigami_agent_runs`, to avoid confusion with the
removed `agent_runs` table — runs are recorded as kioku sessions, see IP-3). Documented identically
in both plans. (Per Open Question 3
the schedule path may also enqueue a due-time job; the same queue/body convention applies.)

**IP-8 — the `cabal.project` pin-set.** **EP-1 owns it.** It copies kioku's kikan pin
block **byte-identically** (so the solver picks one coherent kikan set — the kiroku-pin-skew note in
kioku's MasterPlan applies: prefer kioku's pins, kiroku tag `4312aa8c…`, over kizashi's older ones)
and **adds GitHub `source-repository-package` git stanzas** for `handan` (`handan-core`), `shikumi`
(`shikumi shikumi-trace`), `kafka-effectful`, and the four `kioku` packages, with the `dhall` Haskell
library taken from **Hackage**. **Decided 2026-06-24 (user directive "use hackage and github, not
corpus"):** these deps are pinned by GitHub commit, NOT by local path — kioku `608fbc9` (origin/master;
the local lead is docs-only), handan `d25fac3`, shikumi `36496de` (tag `shikumi-0.1.0.1`),
kafka-effectful `f34a43c`, and `dhall` from Hackage (`>=1.42`). `baikai`
(`baikai`/`baikai-effectful`/`baikai-claude`) is **already present in kioku's kikan pin block** at
`a219ace8…` (kioku-core's known-good baikai), so EP-1 keeps that stanza and adds no fresh baikai pin.
Because handan/kafka-effectful/baikai are `source-repository-package` stanzas (not `packages:`
entries), `cabal build all` only builds what EP-1 actually depends on (dhall, kioku, shikumi); the
others are fetched for the solve but built later by EP-2/EP-4. Locate any unknown dependency's GitHub
remote + pushed commit with `git -C <repo> remote get-url origin` / `git rev-parse origin/master`
before adding its stanza. Every other plan inherits this pin-set unchanged.

**IP-9 — coding conventions (haskell-jitsurei).** All Haskell across shikigami follows the binding
conventions in `/Users/shinzui/Keikaku/bokuno/haskell-jitsurei/` (browse with
`mori registry docs haskell-jitsurei`), exactly as kioku's MasterPlan IP-7 mandates: GHC 9.12.4 +
`GHC2024`; a `common` cabal stanza enabling `DeriveAnyClass`/`DuplicateRecordFields`/
`OverloadedLabels`/`OverloadedStrings` (+ `MultilineStrings` for embedded SQL) with every stanza
doing `import: common`; postpositive `qualified` imports; a `Shikigami.Prelude` that does **not**
re-export `Data.Generics.Labels`; no field prefixes, strict `!` fields, entity-ID-first event/command
records, explicit deriving strategies, and lens operators over record-update syntax;
`eventAesonOptions` for any event JSON; and `cli/agents/claude-cli-pitfalls.md` for any code that
spawns `claude`. Owned by no single plan — every plan that writes Haskell honors it.

**Cross-project improvement-requests (named here, authored elsewhere — not in this MasterPlan).**
IR-1: `shinzui/mori` gains an `Agent` automation action (one `ReactionAction` constructor + one
executor arm that enqueues a shikigami run via the shared pgmq queue or the inbox HTTP route) — the
class-2 addressed trigger. IR-2: `shinzui/shomei` gains scoped service-token issuance so each agent
can carry coarse scopes (`kawa:ingest`, `signal:raise`) the doorway gates; EP-10 elsewhere swaps
`checkGrant`'s stub for the real lookup. IR-3: `shinzui/kanmon` egress is the outbound half of C12,
owned by EP-4/`kanmon` elsewhere. These are listed so the proof plan (EP-6) can file them against
the owning repos; shikigami's side is the `EventTrigger` inbox (IR-1), the `checkGrant` seam (IR-2),
and the channel-egress sink variant (IR-3).


## Progress

Track milestone-level progress across all child plans. Each entry names the child plan
and the milestone. This section provides an at-a-glance view of the entire initiative.

- [x] EP-1: four-package project scaffolds and `cabal build all` succeeds with the kioku + kikan pin-set (GitHub+Hackage pins per user directive)
- [x] EP-1: `shikigami-migrations` composes `kiokuMigrations <> shikigamiOwnMigrations`; `just create-database` lands the `kioku_*` tables + `shikigami_fired`
- [x] EP-1: `schema/Agent.dhall` (C5) + `shikigami-api` wire types + `Shikigami.Agent.Loader` exist; `shikigami validate <file>` parses a manifest or prints a typed error
- [x] EP-2: `Shikigami.Behavior.Run` dispatches both arms (handan `noop-summary` stub; baikai skill via stub provider)
- [x] EP-2: a run opens a kioku session, recalls the agent's prior memory, records the output as memory, and completes the session (replacing `agent_runs`); memory persists across runs
- [x] EP-3: `Shikigami.Sink.dispatch` implements KawaDigest + KizashiSignal (against stubs), stubs ReiAction/Danwa, gated by `checkGrant`; denied sink is skipped + recorded
- [x] EP-3: `shikigami stub-kawa` accepts the C2 doorway, enforces idempotency, and `--republish-topic` re-publishes onto fixture `activity.v1` (proven live against Redpanda)
- [x] EP-4: `isDue` (cron) + `matchesStream` (AND of predicates, feedback guard) unit-tested; `activity.v1` consumer via kafka-effectful + keiro inbox dedupe decodes a fixture envelope (proven live on Redpanda)
- [x] EP-4: addressed-event `enqueue-run` + `publish-fixture`/`consume-stream` CLIs; a fired trigger enqueues a run job on `shikigami_run_jobs` (IP-7). (process-compose Redpanda deferred; docker broker used for the proof)
- [x] EP-5: shibuya `QueueProcessor` worker drains a run job, runs the agent (runAgentWithMemory), dispatches sinks, records the kioku session; `AckOk`/`AckRetry`/`AckDeadLetter` mapped (proven end to end against stub-kawa)
- [~] EP-5: `shikigami worker --agents <dir>` runs end to end ✅; the suppression gate (`shikigami_fired`) + retry-redelivery fixture are deferred refinements (Complete* — see EP-5 Outcomes)
- [ ] EP-6: seed detectors re-pointed at `schema/Agent.dhall` and validate/run unchanged
- [ ] EP-6: living-loop proof (3 triggers × both behavior arms → sinks → kioku session+memory → kawa re-publish → second agent fires); feedback-guard, permission-denial, across-run-memory proofs pass
- [ ] EP-6: shikigami maturity recorded as a `shinzui/mori` capability record; IR-1/IR-2/IR-3 filed against their repos


## Surprises & Discoveries

Document cross-plan insights, dependency changes, scope adjustments, or unexpected
interactions between child plans. Provide concise evidence.

- **kioku replaces the spec's `agent_runs` session store (affects EP-1, EP-2, EP-6).** The spec's
  "Session store" section and `Shikigami.Session` module are not built; kioku's `Session`/`Memory`/
  `Recall` are consumed instead. This also *adds* per-agent memory across runs, which the spec
  explicitly lacked. Recorded at decomposition time from the user's update; see Decision Log and
  IP-3. The kioku repo already holds a Not-Started plan
  (`docs/plans/6-shikigami-memory-integration-with-kioku.md`) describing the seam at pragmatic-v1
  scope — read it as prior art; this initiative delivers the same seam as part of the full runtime.

- **The seed detectors use a different Dhall shape than the spec's illustrative schema (affects
  EP-1, EP-6).** `agents/detectors/*.dhall` use singular `sink`, `Behavior = <Deterministic |
  Program | Skill>`, `Trigger = <Observe | Schedule | Addressed>`, and `Sink = <RaiseSignal |
  RecordReiAction>`, whereas the spec uses `sinks : List Sink` and `Behavior = <ShikumiProgram |
  Skill>`. EP-1 must design the canonical `schema/Agent.dhall` as the reconciling superset and EP-6
  re-points the seeds; see IP-2. Discovered while reading `agents/detectors/` during decomposition.

- **`kiokuMigrations` already bundles the framework migrations (corrects IP-3; affects EP-1).** EP-1
  read kioku's `Kioku.Migrations` and found `kiokuMigrations = kirokuMigrations <>
  keiroFrameworkMigrations <> kiokuOwnMigrations`. The four-term composition originally written in
  IP-3 would re-present already-applied migration timestamps and `codd` would reject the set; the
  correct composition is `kiokuMigrations <> shikigamiOwnMigrations`. IP-3 has been corrected.
  Discovered during EP-1 authoring.

- **The trigger→run queue name was reconciled to `shikigami_run_jobs` (affects EP-4, EP-5).** EP-4's
  first draft named the pgmq run-job queue `shikigami_agent_runs` while EP-5 used
  `shikigami_run_jobs`. Canonicalized to `shikigami_run_jobs` (clearer, and avoids confusion with
  the removed `agent_runs` table — runs are kioku sessions); EP-4 was updated to match and IP-7 now
  names it. Discovered during cross-plan consistency review.

- **The keiro-* Kafka header set is sourced from `Keiro.Integration.Event.integrationHeaders`
  (affects EP-3, EP-4).** Both the kawa stub's `--republish-topic` producer (EP-3) and the
  `publish-fixture` producer + `activity.v1` consumer (EP-4) derive the required `keiro-*` headers
  from the same keiro source of truth, so the producer/consumer sides agree by construction (IP-6).
  Confirmed during cross-plan review.

- **IP-6 correction: the `keiro-source-event-id` header is OMITTED (affects EP-3, EP-4).** The keiro
  inbox parses `keiro-source-event-id` as a UUID (`EventId`); shikigami's `source_event_id`/
  `idempotency_key` is not a UUID, so publishing it makes `integrationEventFromKafka` fail with
  `InvalidUuidHeader`. It is optional, and the consumer dedupes on `keiro-message-id`
  (`PreferIntegrationMessageId`, which keiro reads as `Text`), so both `stub-kawa --republish` (EP-3)
  and `publish-fixture` (EP-4) now omit it. The required keiro header set is `keiro-message-id`,
  `keiro-source`, `keiro-destination`, `keiro-event-type`, `keiro-schema-version`, `content-type`
  (+ optional `keiro-occurred-at`). Discovered when EP-4's consumer rejected the first fixtures.

- **pgmq schema installed via codd, not `pgmq-migration` (affects EP-4, EP-5).** `pgmq-migration`'s
  `hasql-migration` dep fails to build (crypton/memory `ByteArrayAccess (Digest MD5)`), and the nix
  postgres has no `pgmq` extension. EP-4 vendored pgmq's `pgmq.sql` as a codd migration in
  `shikigami-migrations` (`pgmq-schema.sql`); `enqueueRunJob` only does `createQueue` + `sendMessage`.
  EP-5's worker drains the same `shikigami_run_jobs` queue.

- **`librdkafka` added to the dev shell (affects EP-3, EP-4).** `hw-kafka-client` (under
  `kafka-effectful`) links `-lrdkafka`, which the seihou dev shell did not provide — linking failed
  with `ld: library not found for -lrdkafka`. EP-3 added `pkgs.rdkafka` to `nix/haskell.nix`
  `baseDevPackages`; all kafka-touching builds/runs use `nix develop` so the lib is on the link+runtime
  path. EP-4's `activity.v1` consumer relies on the same fix. Note: `librdkafka` resolves `localhost`
  → IPv6 `[::1]`; fixture brokers must advertise `127.0.0.1`.

- **Dependencies are pinned by GitHub commit + Hackage, not local-path/corpus (affects ALL plans;
  IP-8 superseded).** During EP-1 the user directed "use hackage and github for dependencies and not
  use corpus ones." `cabal.project` now pins the co-developed shinzui deps by GitHub
  `source-repository-package` git stanza (kioku `608fbc9` = origin/master, since the local lead is
  docs-only; handan `d25fac3`; shikumi `36496de`; kafka-effectful `f34a43c`; baikai `a219ace` via
  kioku's kikan block) and `dhall` from Hackage — the kikan git block stays byte-identical to kioku's.
  Two path typos in the original plan were corrected (`handan-core`, not `handan/handan`;
  `kafka-effectful` at repo root). **Bonus:** because handan/kafka-effectful/baikai are now
  `source-repository-package` stanzas rather than `packages:` entries, `cabal build all` only builds
  what EP-1 actually depends on (dhall, kioku, shikumi); EP-2/EP-4 build the rest when they import them.
  Every sibling plan inherits this `cabal.project` unchanged. See EP-1's Decision Log.

- **IR-1 (mori) and IR-2 (shomei) already exist as improvement-request docs; IR-3 (kanmon) is new
  (affects EP-6).** EP-6 found `docs/improvement-requests/*.md` already present in the mori and shomei
  repos (authored by the kikan initiative), so EP-6 files those via shikigami-anchored
  cross-references rather than duplicating them, and authors IR-3 (kanmon egress) fresh. There is no
  `mori capability` CLI subcommand — the "capability record" (contract C6) is the project's
  `mori.dhall` lifecycle field advanced to `Active`. Discovered during EP-6 authoring.


## Decision Log

Record every decomposition or coordination decision made while working on the master
plan.

- Decision: Decompose the full shikigami runtime into **six child ExecPlans across four phases**
  (Foundation → Capabilities[behavior ∥ sinks ∥ triggers] → Integration[worker] → Proof), mirroring
  the spec's architecture pipeline.
  Rationale: each pipeline stage is an independently verifiable behavior with a clean seam to the
  next; the three Phase-2 capability streams touch different substrate and parallelize cleanly;
  splitting triggers from the worker balances scope (the trigger logic is large and independently
  testable, the worker is the thin integrating loop). Alternatives (one mega-plan; merging
  behavior+sinks; merging triggers+worker) were rejected for scope and parallelism reasons (see
  Decomposition Strategy).
  Date: 2026-06-24

- Decision: **Replace the spec's bespoke `agent_runs` table and `Shikigami.Session` store with
  kioku's Session/Memory/Recall**, consumed as a pinned dependency. An agent run is a
  `Kioku.Session`; the agent's learnings are `Kioku.Memory` records scoped
  `ScopeEntity (Namespace "shikigami") (ScopeKind "agent") <agentName>`; recall before the run and
  record after it. shikigami builds no `agent_runs` table; `shikigami-migrations` composes
  `kiokuMigrations`.
  Rationale: the user extracted reusable agent memory/sessions from `rei` into the new `kioku`
  project specifically for reuse; the spec itself called `agent_runs` "the intention-free mirror of
  rei's `AgentSessionExistsData`", which kioku's Session aggregate *is*, generalized. Reusing kioku
  removes a bespoke table, gives sessions an event-sourced audit trail, and adds per-agent memory
  across runs (a capability the spec lacked). See IP-3.
  Date: 2026-06-24

- Decision: **Do not modify the kioku repository from this initiative.** Consume kioku via the
  `cabal.project` pin-set (IP-8); read kioku's `docs/plans/6-…` as prior art but deliver the
  scaffold + memory/session seam here.
  Rationale: kioku is an independently versioned library with its own MasterPlan; coupling shikigami's
  bootstrap to kioku-repo edits would entangle two initiatives. shikigami's needs are met by kioku's
  already-shipped public API (EP-1/EP-2 of kioku's MasterPlan are Complete).
  Date: 2026-06-24

- Decision: **EP-1 owns the canonical `schema/Agent.dhall` as the reconciling superset** of the
  spec's illustrative schema and the seed detector declarations' shape; **EP-6 re-points the seeds**
  at it as a mechanical rename.
  Rationale: the seeds were authored before the runtime and deliberately annotate against a local
  placeholder schema (`agents/detectors/schema.dhall`) that says "replace with the runtime's schema
  when it lands"; EP-1 is where the runtime's schema lands, and EP-6 (the conformance proof) is the
  natural place to prove the seeds run unchanged against it. See IP-2.
  Date: 2026-06-24

- Decision: Associate this MasterPlan and all six child plans with Intention
  `intention_01kvy04813ehbv9aghj3tn4zjx`; every commit carries `MasterPlan:`, `ExecPlan:`, and
  `Intention:` git trailers.
  Rationale: the user supplied this Intention ID for the shikigami runtime initiative (distinct from
  the kioku initiative's intention).
  Date: 2026-06-24


## Outcomes & Retrospective

Summarize outcomes, gaps, and lessons learned at major milestones or at completion.
Compare the result against the original vision.

(To be filled during and after implementation.)
