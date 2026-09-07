# Shikigami (式神) — Declared-Agent Runtime — Architecture Spec

> Historical pre-implementation design. The repository now contains the runtime;
> feature support and commands are documented in the [README](../README.md) and
> [user guide](user/README.md). Statements below describe the original proposal.

## Status

Architecture spec, pre-implementation. This document is the design of `shinzui/shikigami` (式神 —
a summoned spirit-servant bound to its master's will, dispatched to observe and act on the master's
behalf): a small runtime in which an **autonomous system agent** is *declared*, not coded. You write
a file that says "run **this behavior**, when **this trigger** fires, and send the result to **these
sinks**," and the runtime executes it for you — forever, on a schedule, in response to events flowing
through the stream, or when addressed directly.

It is a design document, **not yet an implementation** — there is no `.cabal` file or Haskell source
in this repository yet. It is authored *before the build MasterPlan is generated*, so that the API
and abstractions can be validated against frozen contracts and a thin end-to-end proof before any
production code is written. Decisions here are settled against source-verified facts and the
cross-cutting contracts owned in `shinzui/kikan`; open questions are collected at the end.

The work that produced this spec is row **EP-6** in the platform-evolution MasterPlan
(`shinzui/kikan` at `docs/masterplans/2-platform-evolution-from-spines-to-a-living-ai-native-organization.md`)
and its de-risking ExecPlan (`shinzui/kikan` at
`docs/plans/13-custom-agent-platform-define-and-run-agents-over-the-stream.md`). The contracts this
runtime owns or consumes (C5, C3, C2, C1, C4, C9, C11, C12) are frozen in
`shinzui/kikan/docs/architecture/evolution/contracts.md`; this spec **references** them by number and
does not redefine them.

## Goals

- Let anyone stand up a new autonomous agent by writing a short **declarative `.dhall` file** — not
  by building and deploying a bespoke service.
- Define **what a declared agent *is*** as a typed, validatable Dhall schema (contract **C5**):
  `{ name, behavior, trigger, sinks }`.
- Support a **behavior union** — an agent's behavior is *either* a typed `shikumi` Program (run via
  `shinzui/handan`) *or* a Skill (a directory following the Agent Skills specification, run directly
  through `shinzui/baikai`).
- Support **all three trigger classes** (contract **C3**): a schedule, an `activity.v1` stream
  pattern (observe), and an addressed delivery to the agent's `shikigami` inbox (coordinate /
  interact).
- Treat **agents as producers, not just reactors**: the sink set can write a digest activity back
  into `shinzui/kawa`, raise a `shinzui/kizashi` signal, hand off to `shinzui/rei`, open/attach a
  `shinzui/danwa` conversation, and **act back on the outside world** through a `shinzui/kanmon`
  channel egress.
- Record every agent run as an observable **session** in Shikigami's own store.
- Build a **thin worker** on already-existing substrate (`shinzui/keiro`, `shinzui/shibuya`,
  `shinzui/pgmq-hs`, `shinzui/handan`/`shinzui/shikumi`, `shinzui/baikai`, `shinzui/kafka-effectful`)
  — never re-implement a queue, an outbox, a session store, or an LLM runner that the substrate
  already provides.
- Establish trust at every sink via a **`shinzui/shomei` permission grant** (contract **C11**).
- Close the **living loop**: an agent's digest activity reappears on the published stream as a
  first-class memory that a *second* agent (or a human, or the intelligence layer) reacts to.

## Non-Goals

- **Not an extension of `shinzui/rei`/Ren.** `rei` is the home of *intention-bound collaborator
  agents* (an agent working *with one human on one specific intention*, with delegation and review).
  Shikigami is the home of *autonomous system agents* (acting on behalf of *no single human's
  particular task*). This spec does **not** touch `rei`.
- **Not an extension of `shinzui/handan`.** `handan` is a deliberately stateless one-shot CLI for
  typed judgments; it stays the **program library** Shikigami composes, unmodified.
- **Not a re-implementation of a queue, an outbox, an LLM runner, or a session store** — those are
  substrate and are reused.
- **Not the owner of the intelligence layer's detector *programs*.** Shikigami ships the *runtime and
  schema*; EP-5 (the intelligence layer) is the **first consumer**, shipping the first real detector
  programs as declared agents on this runtime. This runtime proves the loop with trivial / stub
  programs.
- **Not a sandbox for executable skill `scripts/`.** A skill that runs executable code needs a
  sandbox; that is deferred to the autonomous-harness execution mode and is **not built here** (a
  forward note only). Skill *instructions* (how-to) run; `scripts/` execution does not.
- **Not the home of OKF concept grounding.** A skill's *instructions* (how-to) are deliberately
  distinct from **OKF grounding** (knowledge / what-things-mean — contract C10); the two are never
  conflated.
- **Not the owner of `shinzui/kawa`, `shinzui/shomei`, `shinzui/mori`, or `shinzui/kanmon`.** Those
  seams are referenced and proven against stubs/fixtures; their real wiring is owned by their own
  plans.

## Core Idea

**Summon an autonomous agent by declaring it as `behavior` + `trigger` + `sinks`, bound to a
`shinzui/shomei` identity, and let a thin worker run it forever.**

An agent is a declaration, not a program you deploy:

```text
behavior  = what the agent does        (a typed shikumi Program, OR a Skill run via baikai)
trigger   = when it does it            (a schedule, an activity.v1 stream pattern, or an addressed delivery)
sinks     = what it produces           (kawa digest, kizashi signal, rei action, danwa conversation, channel egress)
identity  = under whose authority      (a shinzui/shomei identity; each sink is gated by a grant)
```

Instead of asking "which bespoke service do I build to automate this coordination?", the question
becomes:

```text
Which behavior runs, on which trigger, producing which sinks — and is this agent permitted each sink?
```

The payoff is the manifesto's third "10x": routine coordination that used to require a department's
worth of status meetings, handoffs, and follow-ups now runs itself as a handful of declared agents,
while humans keep judgment, creativity, and strategy.

## Example

A declared agent `stall-watch` watches the activity stream for a stalling initiative and raises an
awareness signal:

```text
trigger:  Stream  match { verb = "intention.declared" }   -- observe the river (C3 class 1)
behavior: Skill   path "agents/skills/triage-note"        -- follow instructions, via baikai
sink:     KizashiSignal { signalType = "TaskCandidate", priority = "Normal" }   -- raise awareness (C4)
```

When such an activity arrives on `activity.v1`, the agent fires, drives a `baikai` completion from the
skill's instructions, and raises a `shinzui/kizashi` signal — produced by no human, written by no
bespoke service, just a declared agent doing its job. If instead the finding concerns a *specific
intention*, the same agent could carry a `ReiAction` sink and hand the finding into `rei`'s context
under its `shomei` identity (never touching `rei`'s store).

## High-Level Architecture

```text
Agent declarations  (agents/*.dhall, schema/Agent.dhall)
  |
  | loaded + validated by Shikigami.Agent.Loader (dhall library)
  v
Triggers  (three classes — C3)
  | Schedule  : cron evaluator                       (Shikigami.Trigger.Schedule)
  | Stream    : activity.v1 Kafka consumer + matcher (Shikigami.Trigger.Stream, kafka-effectful)
  | Event     : public integration event or addressed run queue
  v
Worker  (shibuya QueueProcessor over pgmq-hs, on the keiro idempotent inbox)
  |
  | on fire: run behavior, dispatch sinks, record a session
  v
Behavior runner  (Shikigami.Behavior.Run — dispatches on the behavior union)
  | ShikumiProgram arm -> handan Runtime.runProgramWith (typed path; shikumi Program i o)
  | Skill arm          -> baikai: load SKILL.md -> Context -> completeRequest + tool loop
  v
Sink dispatcher  (Shikigami.Sink — each sink gated by Shikigami.Sink.Permission, C11)
  | KawaDigest         -> POST kawa /v1/sources/{source_id}/events   (C2 doorway shape)
  | KizashiSignal      -> POST kizashi /v1/signals                   (C4)
  | ReiAction          -> rei command API under the agent's shomei identity (C5 bridge)
  | DanwaConversation  -> open/attach a danwa conversation           (EP-7)
  | ChannelEgress      -> kanmon egress API, per-destination authorized (C12)
  v
Session store  (agent_runs table; Shikigami.Session — mirrors rei's session shape, intention-free)
  |
  | a KawaDigest sink writes back into kawa -> reappears on activity.v1 -> a second agent reacts
  v
The living loop closes (the system feeds itself).
```

The guiding rule is **keep the runtime thin.** Shikigami is the *seams* — a schema, a loader, a
trigger evaluator, a behavior runner, a sink dispatcher, and a small worker — wired onto substrate
that already exists. Wherever a step tempts you to build something the substrate already provides (a
queue, an outbox, a session store, an LLM runner), use the substrate instead.

## Technology Stack & Ecosystem Alignment

All choices are grounded in already-built libraries registered in `shinzui/mori` and in the
`shinzui/kizashi` scaffolding template (verified: four-package layout, `flake.nix` wrapping
`github:shinzui/haskell-nix-dev` at GHC 9.12.4, a `cabal.project` with internal-dep
`source-repository-package` stanzas, a `Justfile`, and a test-support sublibrary spinning up
ephemeral PostgreSQL via `ephemeral-pg` + `codd`).

| Concern | Choice | Source in ecosystem |
| --- | --- | --- |
| Language / compiler | GHC 9.12.4, `GHC2024` | flake wraps `github:shinzui/haskell-nix-dev` |
| Effect system | `effectful` (dynamic dispatch) | keiro, shibuya, handan |
| Agent declaration schema | **Dhall** (typed, non-Turing config; the `dhall` Haskell lib for the loader) | mori already uses Dhall (`mori.dhall`) |
| Typed program runtime (behavior arm 1) | `shinzui/handan` (`Handan.Runtime`, `Handan.Task`) wrapping `shinzui/shikumi` (`Program i o` GADT, `runProgram`) | `bokuno/handan`, `bokuno/shikumi` |
| Skill runtime (behavior arm 2) | `shinzui/baikai` (`completeRequest`, `Context`, `Tool`, `appendToolResult`) | `bokuno/baikai` |
| Stream trigger consumer | `shinzui/kafka-effectful` (direct; **not** `shibuya-kafka-adapter`) | `bokuno/kafka-effectful` |
| Integration-event backbone (C9) | `shinzui/keiro` (`IntegrationEvent`, idempotent inbox `Keiro.Inbox.Kafka`) | `bokuno/keiro` |
| Supervised queue worker | `shinzui/shibuya` (`Shibuya.App.runApp`, `QueueProcessor`, `AckDecision`) | `bokuno/shibuya-project` |
| Message queue | `shinzui/pgmq-hs` (`pgmq-hasql`: `sendMessage`, `readMessage`) | `bokuno/pgmq-hs` |
| Signal sink (C4) | `shinzui/kizashi` (`POST /v1/signals`, `CreateSignalReq`) | `bokuno/kizashi` |
| Digest sink / stream (C2/C3) | `shinzui/kawa` (NOT YET BUILT — spec only; proven against a stub + fixture topic) | `bokuno/kawa` |
| Trust boundary (C11) | `shinzui/shomei` (referenced; stub grant until EP-10) | `bokuno/shomei` |
| Channel egress (C12) | `shinzui/kanmon` (referenced; the outbound half of C12) | `bokuno/kanmon` |
| DB access / migrations | `hasql` + `codd` (kizashi template) | kizashi, keiro |
| IDs | UUIDv7 for `activity_id` (C1); typeid prefixes for local rows | memory spine |
| Testing | `tasty` + `hedgehog`; ephemeral Postgres via `shinzui/ephemeral-pg` | kizashi template |
| HTTP / CLI | `servant`/`servant-server`; `optparse-applicative` | standards |

### Why a *new* project, not an extension (source-verified)

These facts were confirmed against source during planning and are load-bearing:

1. **`rei`'s agent machinery is intention-coupled and its executor is a stub** — so it cannot be
   reused as code, only the pattern. Evidence:
   `Rei.Modules.AgentSchedule.Domain.Types.ScheduleScope = IntentionScoped !IntentionId | ChildrenOf
   !IntentionId | WorkspaceWide` and `EventTrigger = OnBlockerDeclared | OnDelegationCompleted |
   OnReviewRequested | OnIntentionStalled !Int` (every scope and trigger speaks *intention*
   vocabulary), and `handleAgentTask` in `…/AgentSchedule/Queue/Handler.hs` prints "(execution not
   yet implemented)". Shikigami borrows the *pattern* (event-sourced state machine + PGMQ worker +
   trigger abstraction + session record) and builds its **own thin worker**; it does not lift or
   generalize `rei`'s code. A future refactor *may* extract an intention-free agent-runtime library
   shared by both `rei` and Shikigami — follow-on, not a prerequisite. This is contract **C5**.
2. **`mori` has no agent invocation today** (`grep -ri handan` over `bokuno/mori-project/mori/` is
   empty). The `Agent` automation action is net-new (an improvement-request against mori; see
   Cross-Project Requirements).
3. **`kawa` has no Haskell source yet** (`bokuno/kawa` has zero `.hs` files). Kawa sinks are proven
   against a stub; the live service is an external dependency owned by EP-2 and kawa's roadmap.
4. **`shibuya-kafka-adapter` drops the `keiro-*` headers the keiro inbox needs** (contract C3 caveat),
   so Shikigami consumes `activity.v1` with `shinzui/kafka-effectful` directly.
5. **`shinzui/kizashi`'s project structure is the scaffolding template** (four packages; flake;
   `cabal.project`; `Justfile` with `create-database`/`migrate`/`new-migration`; a test-support
   sublibrary `withKizashiMigratedDatabase :: (Text -> IO a) -> IO a`). Shikigami mirrors all of it.

## Domain Model

Concrete types are illustrative (final field sets settle during implementation). The wire types live
in `shikigami-api` (client-safe, no `hasql`/`effectful`/`kiroku` deps), so the worker and the CLI
share them.

### The declared agent (contract C5)

```haskell
-- shikigami-api : Shikigami.Api.Agent
data AgentDecl = AgentDecl
  { name :: Text, behavior :: Behavior, trigger :: Trigger, sinks :: [Sink] }

-- behavior is a UNION — not everything needs a typed program:
data Behavior = ShikumiProgram { task :: Text }   -- typed path, via handan/shikumi
              | Skill { path :: FilePath }         -- skill directory (SKILL.md), via baikai

-- trigger is one of C3's three classes:
data Trigger = ScheduleTrigger { cron :: Text }            -- C3 class 1 (schedule)
             | StreamTrigger  { match :: StreamMatch }      -- C3 class 1 (observe activity.v1)
             | EventTrigger   { eventType :: Text }         -- C3 class 2/3 (addressed delivery)
data StreamMatch = StreamMatch
  { verb :: Maybe Text, source :: Maybe Text, subjectType :: Maybe Text }  -- AND of present predicates

-- sinks treat agents as producers, not just reactors:
data Sink = KawaDigest        { subjectType :: Text, verb :: Text }   -- write a digest activity into kawa
          | KizashiSignal     { signalType :: Text, priority :: Text } -- raise an awareness signal
          | ReiAction         { note :: Text }                        -- hand off to rei (record an action)
          | DanwaConversation { topic :: Text }                       -- open/attach a conversation
          -- (the channel egress sink — C12's outbound half — is described under Open Questions /
          --  Cross-Project Requirements; its concrete config carries a conversation key + destination.)
```

> The illustrative `ReiAction { note }` field is a placeholder: the real `ReiAction` carries the
> **target intention id** (see "The `rei`/Ren ↔ `shikigami` boundary"). The illustrative
> `KizashiSignal`/`KawaDigest` configs are exactly the fields the worker needs to build the request.

### The Activity Envelope (contract C1 — owned by the memory spine, *referenced*)

Every activity an agent produces is one Activity Envelope — the canonical nine-field shape, defined
in full at `shinzui/kikan/docs/architecture/spines/memory.md` and frozen as **C1**:

```text
activity_id     : UUIDv7 string (the publisher mints it itself — C1; no synchronous kawa round-trip)
occurred_at     : RFC3339 timestamp, e.g. "2026-06-20T07:00:00Z"
source          : "shinzui/shikigami" for this runtime's output (internal mori identity)
actor           : { kind: "human"|"agent"|"service", id: string, session: string? }
subject         : { type: string, id: string }   -- what the activity is about
verb            : past-tense dotted string, e.g. "digest.produced" / "heartbeat.tick"
payload         : free-form JSON body (the behavior's output)
context_refs    : [ { scheme, ref } ]   -- back-references (e.g. activity://, signal://)
idempotency_key : derived from (source, source_event_id) so re-delivery is a no-op
```

**An agent's own output carries `actor.kind: "agent"`** so the rest of the system can tell
agent-produced memory from human memory, and so detectors avoid feedback loops (they exclude
`actor.kind: "agent"` by default — C3). Shikigami's worker mints the envelope's UUIDv7 `activity_id`
itself (C1) and derives `idempotency_key` deterministically from `(agent name, trigger occurrence)`.

### The agent-run session (mirrored from `rei`, intention-free)

Shikigami records each agent *run* as a **session** of its own shape — conceptually mirroring `rei`'s
`Rei.Modules.AgentSession.Domain.Types.AgentSessionExistsData` (`{ sessionId, agentId, focusType,
intentionId?, previousSessionId?, status, startedAt, completedAt?, modelUsed?, summary? }`) **minus
the intention fields** (`intentionId`, `focusType` are intention vocabulary):

```haskell
-- shikigami-core : Shikigami.Session
data AgentRun = AgentRun
  { runId       :: RunId
  , agentName   :: Text
  , status      :: RunStatus       -- Started | Completed | Failed
  , startedAt   :: UTCTime
  , completedAt :: Maybe UTCTime
  , modelUsed   :: Maybe Text
  , summary     :: Maybe Text
  }
```

A row is inserted at run start and updated at completion. A crash mid-run leaves a `status = Started`
row — the recovery signal. The worker never deletes session rows, so the run history is an audit
trail. Sessions/memory live in Shikigami's **own** store, joined to `rei` **only** through
`activity.v1` (never a shared table or a direct read).

## Contracts (owned in `shinzui/kikan`, referenced here)

Shikigami **owns** C5 and the agent-inbox side of C3; it **consumes** the rest. All are frozen in
`shinzui/kikan/docs/architecture/evolution/contracts.md`; this runtime references them by number and
never redefines them.

- **C5 — The agent-definition schema.** *Owned by Shikigami.* `{ name, behavior, trigger, sinks }`,
  `behavior` a `< ShikumiProgram | Skill >` union, `trigger` one of C3's three classes, `sinks`
  treating agents as producers. Acceptance test named by the contract: "re-express the intelligence
  layer's detectors as declared agents" (delivered by EP-5, the first consumer).
- **C3 — Agent triggering: three classes + the `activity.v1` observe seam.** *Observe seam consumed;
  agent-inbox owned.* (1) **Observe** (whole-river): bind `activity.v1`, keyed by `subject`, decoded
  as one envelope shape, via keiro's idempotent Kafka inbox; consumers bind this one topic, never raw
  per-service topics; exclude `actor.kind: "agent"` by default (feedback guard). (2) **Coordinate**
  (addressed, internal): a `kizashi` `AgentRequest`, a `mori` `Agent` action, or a `rei` delegation
  reaches the agent through the run queue, bypassing `activity.v1`. (3) **Interact** (addressed,
  external): a producer-owned public integration-event topic, such as Danwa's
  `danwa.message-addressed.v1`, triggers the bound agent by matching `Trigger.Event.eventType`.
  Consumers never read another service's database, private event store, read models, or outbox
  tables. The invariant: *"every action is remembered," not "every trigger is delivered through
  memory"* — `kawa` records the trigger in parallel when needed.
- **C2 — The verification boundary (kawa doorway / native publish).** *Consumed.* The `KawaDigest`
  sink targets the doorway shape `POST /v1/sources/{source_id}/events`, idempotent on
  `(source, source_event_id)`. Proven against a stub until kawa ships.
- **C1 — The Activity Envelope.** *Consumed.* The nine-field shape; the publisher mints the UUIDv7
  `activity_id` itself. Owned by the memory spine; Shikigami constructs envelopes, never redefines the
  shape.
- **C4 — The `shinzui/kizashi` signal contract.** *Consumed.* `POST /v1/signals` with `CreateSignalReq`
  (`actor`, `recipient`, `source`, `signalType ∈ {Notification, Alert, Reminder, TaskCandidate,
  DigestItem, AgentRequest}`, `intent`, `priority ∈ {Low, Normal, High, Urgent}`, `importance`,
  `contextTags`). Raisers set `source` to their own identity and include an `activity://<id>`
  back-reference.
- **C9 — The integration-event backbone.** *Consumed.* `Keiro.Integration.Event.IntegrationEvent`
  over Redpanda through a durable outbox / idempotent inbox; the stream trigger reconstructs the
  `IntegrationEvent` via `Keiro.Inbox.Kafka.integrationEventFromKafka` and dedupes via
  `Keiro.Inbox.runInboxTransaction`.
- **C11 — The trust boundary (`shinzui/shomei`).** *Consumed.* Each sink is gated by an explicit
  permission grant tied to the agent's `shomei` identity; the `ReiAction` sink uses shomei's `act` /
  actor claim for on-behalf-of attribution. Fine-grained per-agent-per-sink grants stay in a local
  grant table keyed by the verified `sub`; coarse scopes live in `shomei`. Proven with a stub grant
  until EP-10.
- **C12 — Channels and the `shinzui/kanmon` runtime.** *Consumed (the egress half).* The channel
  egress sink lets a declared agent **act back on the outside world** through `kanmon`'s egress API,
  authorized per destination by `shomei`. `kanmon` holds the provider credentials and is the only
  thing that calls a provider; Shikigami never holds provider credentials and never names an arbitrary
  destination. A channel-inbound event is C3 class 3.
- **C10 — The concept-grounding contract.** *Referenced for separation only.* A skill's *instructions*
  are distinct from OKF *grounding*; the three input axes are **behavior** (program OR skill) × **OKF
  knowledge grounding** × the **trigger/sink wiring**. Grounding is owned by EP-9.

## The Dhall agent-definition schema (C5)

The schema describes an agent as `{ name, behavior, trigger, sinks }`. It lives at
`schema/Agent.dhall` and is imported by every agent manifest.

```dhall
-- schema/Agent.dhall (illustrative shape — author the real one against Dhall's type system)
let Trigger =
      < Schedule : { cron : Text }
      | Stream : { match : { verb : Optional Text, source : Optional Text, subjectType : Optional Text } }
      | Event : { eventType : Text }
      >

-- behavior is a UNION: a typed shikumi Program (via handan) OR a Skill (via baikai).
let Behavior =
      < ShikumiProgram : { task : Text }   -- names a handan/shikumi task in the program registry
      | Skill : { path : Text }            -- a skill directory (SKILL.md + scripts/references/assets)
      >

let Sink =
      < KawaDigest : { subjectType : Text, verb : Text }       -- write a digest activity into kawa
      | KizashiSignal : { signalType : Text, priority : Text } -- raise an awareness signal
      | ReiAction : { note : Text }                            -- hand off to rei (record an action)
      | DanwaConversation : { topic : Text }                   -- open/attach a conversation
      >

let Agent =
      { name : Text
      , behavior : Behavior   -- shikumi Program (typed) OR Skill (instructions, run via baikai)
      , trigger : Trigger
      , sinks : List Sink
      }

in  { Trigger, Behavior, Sink, Agent }
```

### The behavior union — two paths

1. **A `shikumi` Program** (run via `shinzui/handan`) names a typed `handan`/`shikumi` task in the
   program registry. This is the path for *structured, typed, evaluable/optimizable* work: schemas,
   validation, ensembles, an eval harness.
2. **A Skill** — a directory following the **Agent Skills specification**
   (`https://agentskills.io/specification`), **run directly through `shinzui/baikai`** (NOT through
   `shikumi`/`handan`). This is the lightweight path for the many agents that are "follow these
   instructions, maybe call these tools" rather than a typed pipeline. The portfolio already has this
   format (`agents/skills/*/SKILL.md`, scaffolded by `shinzui/seihou` — this repo's own
   `exec-plan`/`master-plan` skills are examples); skills are *reused, not invented*, and the Agent
   Skills spec is the open standard those follow.

A **skill** is a directory `skill-name/` containing at minimum a `SKILL.md` (YAML frontmatter + a
Markdown instruction body), plus optional `scripts/` (executable code), `references/` (docs loaded on
demand), and `assets/` (templates/data). The `SKILL.md` frontmatter fields are:

- `name` (REQUIRED, 1–64 chars, lowercase alphanumeric + hyphens, no leading/trailing/consecutive
  hyphens, **must match the parent directory name**);
- `description` (REQUIRED, 1–1024 chars; says *what* the skill does AND *when* to use it,
  keyword-rich);
- optional `license`, `compatibility` (≤500 chars; environment requirements), `metadata`
  (string→string map), and `allowed-tools` (space-separated pre-approved tools, e.g. `Bash(git:*)
  Read`; experimental).

The body is Markdown with no format restrictions; keep it under ~500 lines / <5000 tokens and push
detail into `references/`. **Progressive disclosure** governs loading: the metadata (~100 tokens) is
known up front, the full `SKILL.md` body is loaded on activation, and `scripts/`/`references/`/
`assets/` are loaded only as needed. A skill validates with `skills-ref validate ./my-skill`
(`github.com/agentskills/agentskills`).

A skill's *instructions* (the `SKILL.md` how-to) are deliberately **distinct from OKF grounding** (the
*knowledge* an agent loads to understand what things mean — contract C10). The three input axes for
any agent are therefore: **behavior** (program OR skill) × **OKF knowledge grounding** (distinct from
skill instructions) × the **trigger/sink wiring**. Do not conflate a skill's instructions with its
grounding.

### Sample manifests

Both behavior kinds are declared the same way — only the `behavior` variant differs. A
**program-agent** (the typed path) names a registered `shikumi` task:

```dhall
-- agents/heartbeat.dhall — a program-agent (behavior = ShikumiProgram)
let A = ./schema/Agent.dhall
in  A.Agent::{
    , name = "heartbeat"
    , behavior = A.Behavior.ShikumiProgram { task = "noop-summary" }
    , trigger = A.Trigger.Schedule { cron = "* * * * *" }
    , sinks = [ A.Sink.KawaDigest { subjectType = "heartbeat", verb = "heartbeat.tick" } ]
    }
```

A **skill-agent** (the lightweight path) points `behavior` at a skill *directory* instead — no task
registry entry, no typed program; the runtime drives a `baikai` completion from the skill's `SKILL.md`:

```dhall
-- agents/triage-note.dhall — a skill-agent (behavior = Skill)
let A = ./schema/Agent.dhall
in  A.Agent::{
    , name = "triage-note"
    , behavior = A.Behavior.Skill { path = "agents/skills/triage-note" }
    , trigger = A.Trigger.Stream
        { match = { verb = Some "ticket.received", source = None Text, subjectType = None Text } }
    , sinks = [ A.Sink.KizashiSignal { signalType = "TaskCandidate", priority = "Normal" } ]
    }
```

> Note: another agent will author the concrete `agents/`/`agents/detectors/*.dhall` declarations into
> this repo. This spec defines the *schema and the worked shapes* they conform to; it does not create
> those files.

### The sink set — agents as producers

The sink variants are deliberately broad because **agents are producers, not just reactors** (C5): a
sink may write a digest activity back into `kawa` (`KawaDigest`), raise a `kizashi` signal
(`KizashiSignal`), hand off to `rei` by recording an action against an intention (`ReiAction`),
attach/open a `danwa` conversation (`DanwaConversation`), or **act on a channel** through `kanmon`'s
egress (the outbound half of C12 — the one sink that lets an agent act back on the outside world).

This runtime *implements* `KawaDigest` and `KizashiSignal` fully (against stubs where the target
service is not yet built) and *defines* the others as schema variants whose handlers are thin stubs to
be completed by their owning plans (EP-7 for danwa; `rei` for `ReiAction`; EP-4/`kanmon` for the
channel egress).

The `ReiAction` variant is special: it is the **rei-handoff sink**, the explicit designed bridge from
a `shikigami` (system) agent into `rei`'s (intention-bound) context (C5; "How `rei`/Ren and
`shikigami` interact" in `target-architecture.md`). Because `shikigami` and `rei` are **different
bounded contexts that never call each other's internals**, this sink targets **a specific intention**
and records the action / opens the delegation through `rei`'s **command API under the agent's
`shinzui/shomei` identity** (using shomei's `act` / actor claim for on-behalf-of attribution),
**never** by touching `rei`'s store. Its sink config therefore carries the **target intention id** (the
illustrative schema's bare `note` field is a placeholder; the real `ReiAction` adds an intention
reference).

## The loader

The loader lives in `shikigami-core` as
`Shikigami.Agent.Loader.loadAgent :: FilePath -> IO (Either LoadError AgentDecl)`, using the Haskell
`dhall` library's `Dhall.input`/`Dhall.auto` to decode the file into a Haskell `AgentDecl` record
(defined in `shikigami-api` as `Shikigami.Api.Agent.AgentDecl` so the worker and CLI share it,
including decoding the `behavior` union).

```haskell
-- shikigami-core : Shikigami.Agent.Loader
loadAgent :: FilePath -> IO (Either LoadError AgentDecl)
```

The CLI subcommand `validate` (in `shikigami-cli`, module `Shikigami.Cli.Commands.Validate`) calls
`loadAgent` and pretty-prints the record or a typed error. For a skill-agent, `validate` additionally
checks that the skill `path` exists and that its `SKILL.md` frontmatter is well-formed (mirroring
`skills-ref validate`: a REQUIRED `name` matching the directory and a REQUIRED `description`).

```text
$ cabal run shikigami -- validate agents/heartbeat.dhall
AgentDecl
  { name = "heartbeat"
  , behavior = ShikumiProgram { task = "noop-summary" }
  , trigger = ScheduleTrigger { cron = "* * * * *" }
  , sinks = [ KawaDigest { subjectType = "heartbeat", verb = "heartbeat.tick" } ]
  }
OK: 1 agent parsed.
```

A malformed file exits non-zero with a typed error (e.g. `LoadError: ... expected a record ...`).

## The three triggers (contract C3)

### Schedule (C3 class 1 — the clock)

`Shikigami.Trigger.Schedule` answers "is it time to fire?":

```haskell
Shikigami.Trigger.Schedule.isDue :: Cron -> UTCTime -> Bool
```

Reuse the cron parsing that `rei` already uses if available as a library, or a small cron crate.
Drive it with a timer loop, or — preferred, to reuse substrate — enqueue a due-time message onto a
`pgmq-hs` queue and let the shibuya worker pull it.

### Stream (C3 class 1 — observe `activity.v1`)

`Shikigami.Trigger.Stream` is a Kafka consumer using `shinzui/kafka-effectful` **directly** (the C3
header-drop caveat: `shibuya-kafka-adapter` drops the `keiro-*` headers the inbox needs). It binds to
the **one** `activity.v1` topic (never raw per-service topics), reconstructs the `IntegrationEvent` and
Activity Envelope, dedupes via the keiro idempotent inbox, and evaluates each loaded agent's `Stream`
match predicate:

```haskell
-- shikigami-core : Shikigami.Trigger.Stream
subscribeActivityStream :: StreamConfig -> (ActivityEnvelope -> IO ()) -> IO ()
matchesStream :: StreamMatch -> ActivityEnvelope -> Bool
--   AND of present predicates (verb/source/subjectType, all optional);
--   excludes actor.kind="agent" by default (the C3 feedback guard) unless the agent opts in.
```

The dedupe/reconstruct seam (C9):

```haskell
Keiro.Inbox.Kafka.integrationEventFromKafka
  :: KafkaInboundRecord -> Either KafkaDecodeError (IntegrationEvent, KafkaDeliveryRef)
Keiro.Inbox.runInboxTransaction
  :: ... -> InboxDedupePolicy -> IntegrationEvent -> Maybe KafkaDeliveryRef
  -> (IntegrationEvent -> Tx.Transaction a) -> Eff es (Either InboxError (InboxResult a))
```

Until real kawa publishes `activity.v1`, use a **fixture topic**: a Redpanda/Kafka broker (run via the
project's `process-compose.yaml`, mirroring how kizashi runs its postgres) and a `shikigami
publish-fixture <envelope.json>` CLI subcommand that publishes a single envelope with the correct
`keiro-*` headers so the inbox accepts it.

### Event (C3 classes 2/3 — addressed delivery)

An `EventTrigger { eventType }` declares an agent to run "when invoked by an external event" — the
**addressed** classes. These reach the agent by matching a public integration event with
`consume-events`, or by directly enqueueing a run job, bypassing `activity.v1`. The public-topic path
is for service-owned contracts such as Danwa's `danwa.message-addressed-to-agent` events on
`danwa.message-addressed.v1`; the direct queue path is for commands that already know the recipient.
The invocation produces an agent run + session row. Shikigami must not read another service's
database, private event store, read models, or outbox tables.

## The behavior runner (the new surface)

`Shikigami.Behavior.Run` dispatches on the `behavior` union to one of **two execution paths**.
Everything downstream (sinks, sessions) is shared between the two arms.

```haskell
-- shikigami-core : Shikigami.Behavior.Run
runBehavior :: BehaviorEnv -> AgentDecl -> Value -> IO (Either RunError Value)
--   ShikumiProgram arm -> Handan.Runtime.runProgramWith  (typed path)
--   Skill arm          -> baikai: load SKILL.md -> Context -> completeRequest + appendToolResult loop
runSkill :: Model -> SkillDir -> Value -> IO (Either RunError Value)   -- Shikigami.Behavior.Skill
```

### The shikumi-program arm (the typed path)

Looks up the named task in a program registry (`Shikigami.Program.Registry :: [Task]`, mirroring
`Handan.Registry`), constructs a `Handan.Runtime` once at startup via `newRuntime`, and runs the
task's program via `runProgramWith`:

```haskell
Handan.Runtime.newRuntime     :: IO Runtime
Handan.Runtime.runProgramWith :: Runtime -> Program i o -> i -> IO (Either ShikumiError o)
Shikigami.Program.Registry.programRegistry :: [Task]   -- includes the "noop-summary" stub task
```

For de-risking, register a single deterministic stub task `noop-summary` whose program returns a fixed
JSON body using `shikumi`'s `Embed` constructor — *no LLM call yet*, so the loop is provable without a
model provider configured. EP-5's real detectors use `Predict`. The `Task` shape is `handan`'s
existential record: `data Task = forall i o. Task { taskName :: Text, taskKind :: TaskKind, taskParse
:: ArgMap -> Either Text i, taskRun :: Runtime -> i -> IO Envelope, ... }`. The `shikumi` `Program i
o` GADT carries combinators `Predict`, `Compose`, `FMap`, `Map`, `Validate`, `Embed`, … with runner
`runProgram :: (LLM :> es, Error ShikumiError :> es) => Program i o -> i -> Eff es o`.

### The skill arm (the lightweight path — via `shinzui/baikai`, NOT `handan`)

Loads the skill's `SKILL.md` from the declared directory, builds a `baikai`
`Baikai.Context.Context{ systemPrompt, messages, tools }` whose `systemPrompt`/`messages` carry the
skill's Markdown instructions (plus any `references/`/`assets/` pulled in by progressive disclosure as
the run needs them), maps the skill's `allowed-tools` to `baikai` tool definitions, and calls
`completeRequest`:

```haskell
Baikai.completeRequest :: Model -> Context -> Options -> IO Response
Baikai.Stream.streamRequest :: Model -> Context -> Options -> Stream IO AssistantMessageEvent
Baikai.Tool.Tool{ name, description, parameters }   -- parameters is a JSON-Schema Value
Baikai.Tool.ToolChoice
Baikai.Context.appendToolResult :: Context -> Response -> (ToolCall -> IO ToolResult) -> IO Context
Baikai.Context.appendToolResultText :: ...
```

When the skill uses tools, the arm runs a **tool-use loop**: after each response, dispatch the model's
tool calls and fold the results back with `appendToolResult ctx resp dispatcher` (or
`appendToolResultText`), then call `completeRequest` again until the model stops requesting tools. The
final completion is handed to the sinks exactly as a program's output is. A `baikai` provider must be
registered in `Baikai.Provider`'s registry (a stub provider suffices for CI, so the proof runs without
a model key — exactly as `noop-summary` runs without one).

**Sandbox note:** a skill that executes `scripts/` (executable code) needs a sandbox; that ties to the
**deferred autonomous-harness execution mode** and is **not built here** (a forward note — the skill
proof uses instructions + `allowed-tools` only, no `scripts/` execution).

## The sink dispatcher

`Shikigami.Sink.dispatch` builds and dispatches each sink; each dispatch is gated by a permission
check (C11):

```haskell
-- shikigami-core : Shikigami.Sink
dispatch :: SinkContext -> Sink -> Value -> IO SinkResult

-- KawaDigest builds the nine-field C1 envelope (actor.kind="agent", source="shinzui/shikigami",
-- verb/subject.type from the sink config, payload = the behavior's output) and POSTs to the doorway:
Shikigami.Sink.KawaClient.postEnvelope :: KawaConfig -> ActivityEnvelope -> IO (Either KawaError ActivityId)
--   endpoint shape: POST /v1/sources/{source_id}/events ; base URL configurable (stub now, real kawa later)
```

- **KawaDigest** → `POST /v1/sources/{source_id}/events` (C2 doorway shape).
- **KizashiSignal** → `POST /v1/signals` with `CreateSignalReq` (C4); the worker generates a client
  from `shinzui/kizashi`'s servant routes.
- **ReiAction** → `rei`'s command API under the agent's `shomei` identity, against a target intention
  (C5 bridge; handler stubbed here, completed by `rei`'s plan).
- **DanwaConversation** → open/attach a `danwa` conversation (handler stubbed here, completed by EP-7).
- **Channel egress** (C12) → `kanmon`'s egress API, per-destination authorized by `shomei` (handler
  stubbed here, completed by EP-4/`kanmon`).

### Permission gate (C11)

```haskell
-- shikigami-core : Shikigami.Sink.Permission
data SinkKind = SKawaDigest | SKizashiSignal | SReiAction | SDanwaConversation  -- (+ SChannelEgress)
checkGrant :: AgentIdentity -> SinkKind -> IO (Either Denied ())   -- stub now; shomei lookup under EP-10
```

For de-risking this calls a stub that consults a static allow-list keyed by agent name; the seam is
shaped exactly so EP-10 can swap the stub for a real `shomei` grant lookup. A denied sink is **logged
and skipped** (it does not crash the run), and the session row records the denial. Fine-grained
per-agent-per-sink grants stay in a local grant table keyed by the verified `sub`; coarse scopes
(`kawa:ingest`, `signal:raise`) live in `shomei` and are gated with `requireScope`.

## The session store

The session record lives in `shikigami-migrations` (a SQL table `agent_runs`) and `Shikigami.Session`
(`Shikigami.Session.AgentRun`), mirroring `rei`'s `AgentSessionExistsData` minus the intention fields:

```sql
-- shikigami-migrations/sql-migrations/<timestamp>-agent-runs.sql
create table agent_runs
  ( run_id        text primary key
  , agent_name    text        not null
  , status        text        not null   -- 'started' | 'completed' | 'failed'
  , started_at    timestamptz not null
  , completed_at  timestamptz
  , model_used    text
  , summary       text
  );
```

```haskell
Shikigami.Session.recordRunStart    :: AgentRun -> Session ()
Shikigami.Session.recordRunComplete :: RunId -> RunStatus -> Maybe Text -> Session ()
```

Each run inserts a row at start; on completion it updates `completed_at`/`status`/`summary`. The
test-support sublibrary `Shikigami.Migrations.TestSupport.withShikigamiMigratedDatabase :: (Text -> IO
a) -> IO a` mirrors kizashi's `withKizashiMigratedDatabase` (it composes `kirokuMigrations`,
`keiroFrameworkMigrations`, and the embedded shikigami SQL via `codd` over an `ephemeral-pg` cluster).

## The worker

A long-running worker built on the `keiro`/`shibuya`/`pgmq-hs` substrate (the same primitives
`kizashi` and `rei` run on). Given a directory of agent files, it evaluates each agent's trigger and,
when it fires, runs the agent's behavior and dispatches its sinks, recording each run as a session.

- **Supervision:** `shinzui/shibuya` (`Shibuya.App.runApp`, `QueueProcessor`, `Handler`) returning an
  `AckDecision` of `AckOk | AckRetry | AckDeadLetter | AckHalt`. A transient sink failure returns
  `AckRetry` (retried with backoff); a permanent failure returns `AckDeadLetter`.
- **Queue:** `shinzui/pgmq-hs` (`pgmq-hasql`: `sendMessage :: QueueName -> MessageBody -> Session
  MessageId`, `readMessage :: QueueName -> Int32 -> Session (Maybe Message)`) carries due-time and
  invocation jobs.
- **Stream consumer:** `shinzui/kafka-effectful` directly (per the C3 header-drop caveat), deduped via
  the keiro idempotent inbox.

CLI surface (the `shikigami` executable, `optparse-applicative`):

```text
shikigami validate <file>                         -- parse + validate an agent manifest
shikigami worker --agents <dir> [--kawa-url <u>] [--kizashi-url <u>] [--danwa-url <u>] [--danwa-agent <participant>]
shikigami stub-kawa --port <p> [--republish-topic activity.v1 --broker <h:p>]
shikigami publish-fixture <envelope.json>         -- publish one envelope with keiro-* headers
shikigami consume-stream --agents <dir> [--topic activity.v1] [--broker <h:p>]
shikigami consume-events --agents <dir> [--topic danwa.message-addressed.v1] [--broker <h:p>]
```

The **kawa stub** (`shikigami stub-kawa`) is a ~30-line server accepting `POST
/v1/sources/{source_id}/events`, returning `{ "activity_id": "<uuid>", "deduplicated": false }`,
enforcing idempotency on `(source, source_event_id)`, and logging each received envelope so a test can
assert on it. With `--republish-topic` it re-publishes a received `KawaDigest` envelope onto the
fixture `activity.v1` topic (exactly what real kawa's outbox will do per C3), closing the living loop.

## Package / Module Layout

Four packages mirroring `shinzui/kizashi`:

```text
shikigami/
  cabal.project          -- with-compiler ghc-9.12.4; source-repository-package stanzas for internal deps
  flake.nix              -- wraps github:shinzui/haskell-nix-dev (GHC 9.12.4)
  Justfile               -- create-database / migrate / new-migration
  process-compose.yaml   -- postgres + a Redpanda/Kafka broker (fixture topic)
  schema/Agent.dhall     -- the C5 agent-definition schema
  agents/                -- declared agents (authored separately, incl. agents/detectors/*.dhall)
    skills/<name>/SKILL.md   -- skill behaviors (Agent Skills spec)

  shikigami-api/         -- wire types (client-safe): AgentDecl, Behavior, Trigger, Sink, ActivityEnvelope
                         --   module Shikigami.Api.Agent
  shikigami-core/        -- the runtime:
                         --   Shikigami.Agent.Loader        (dhall -> AgentDecl)
                         --   Shikigami.Trigger.Schedule    (cron evaluator)
                         --   Shikigami.Trigger.Stream      (activity.v1 via kafka-effectful + matcher)
                         --   Shikigami.Behavior.Run        (dispatch on the behavior union)
                         --   Shikigami.Behavior.Skill      (baikai skill runner + tool loop)
                         --   Shikigami.Program.Registry    ([Task], incl. noop-summary stub)
                         --   Shikigami.Sink                (dispatcher)
                         --   Shikigami.Sink.KawaClient     (postEnvelope to the doorway shape)
                         --   Shikigami.Sink.Permission     (checkGrant; stub now, shomei under EP-10)
                         --   Shikigami.Session             (AgentRun; recordRunStart/Complete)
  shikigami-cli/         -- executable `shikigami` with subcommands (Shikigami.Cli.Commands.*)
  shikigami-migrations/  -- agent_runs SQL + test-support sublibrary (withShikigamiMigratedDatabase)
```

Scaffold from the kizashi template: copy `flake.nix`, `cabal.project`, `Justfile`,
`process-compose.yaml`, `.envrc`, and `nix/`; rename `kizashi-*` → `shikigami-*`; keep the internal-dep
`source-repository-package` stanzas (`keiki`, `keiro`, `keiro-core`, `kiroku-store`, `shibuya-core`,
`pgmq-hs` family, `ephemeral-pg`, `codd`) and **add** stanzas for `handan-core`, `shikumi`, `baikai`,
and `kafka-effectful`. Locate any unknown dependency's on-disk path with `mori registry show <name>
--full` before adding its stanza.

## API Surface

### `shikigami-api`

```haskell
-- Shikigami.Api.Agent
data AgentDecl  = AgentDecl { name :: Text, behavior :: Behavior, trigger :: Trigger, sinks :: [Sink] }
data Behavior   = ShikumiProgram { task :: Text } | Skill { path :: FilePath }
data Trigger    = ScheduleTrigger { cron :: Text }
                | StreamTrigger  { match :: StreamMatch }
                | EventTrigger   { eventType :: Text }
data StreamMatch= StreamMatch { verb :: Maybe Text, source :: Maybe Text, subjectType :: Maybe Text }
data Sink       = KawaDigest { subjectType :: Text, verb :: Text }
                | KizashiSignal { signalType :: Text, priority :: Text }
                | ReiAction { note :: Text }              -- real config carries the target intention id
                | DanwaConversation { topic :: Text }
-- ActivityEnvelope mirrors the nine-field C1 shape; actor.kind = "agent" for all agent-produced output.
```

### `shikigami-core`

```haskell
-- Shikigami.Agent.Loader
loadAgent :: FilePath -> IO (Either LoadError AgentDecl)

-- Shikigami.Trigger.Schedule
isDue :: Cron -> UTCTime -> Bool

-- Shikigami.Trigger.Stream
subscribeActivityStream :: StreamConfig -> (ActivityEnvelope -> IO ()) -> IO ()
matchesStream :: StreamMatch -> ActivityEnvelope -> Bool   -- AND of present predicates; excludes actor.kind="agent"

-- Shikigami.Behavior.Run / Shikigami.Behavior.Skill
runBehavior :: BehaviorEnv -> AgentDecl -> Value -> IO (Either RunError Value)
runSkill    :: Model -> SkillDir -> Value -> IO (Either RunError Value)

-- Shikigami.Program.Registry
programRegistry :: [Task]                                  -- includes "noop-summary"

-- Shikigami.Sink / KawaClient / Permission
dispatch     :: SinkContext -> Sink -> Value -> IO SinkResult
postEnvelope :: KawaConfig -> ActivityEnvelope -> IO (Either KawaError ActivityId)
checkGrant   :: AgentIdentity -> SinkKind -> IO (Either Denied ())

-- Shikigami.Session
recordRunStart    :: AgentRun -> Session ()
recordRunComplete :: RunId -> RunStatus -> Maybe Text -> Session ()
```

### Substrate consumed (unchanged, used as a library)

```haskell
-- handan / shikumi (ShikumiProgram arm)
Handan.Runtime.newRuntime     :: IO Runtime
Handan.Runtime.runProgramWith :: Runtime -> Program i o -> i -> IO (Either ShikumiError o)
Shikumi.Program.runProgram    :: (LLM :> es, Error ShikumiError :> es) => Program i o -> i -> Eff es o

-- baikai (Skill arm)
Baikai.completeRequest        :: Model -> Context -> Options -> IO Response
Baikai.Context.appendToolResult :: Context -> Response -> (ToolCall -> IO ToolResult) -> IO Context

-- keiro (C9 inbox), shibuya (worker), pgmq-hs (queue), kizashi (C4 sink)
Keiro.Inbox.runInboxTransaction :: ...
Keiro.Inbox.Kafka.integrationEventFromKafka :: KafkaInboundRecord -> Either KafkaDecodeError (IntegrationEvent, KafkaDeliveryRef)
Shibuya.App.runApp :: ...    -- QueueProcessor / Handler / AckDecision { AckOk | AckRetry | AckDeadLetter | AckHalt }
Pgmq.sendMessage :: QueueName -> MessageBody -> Session MessageId
Pgmq.readMessage :: QueueName -> Int32 -> Session (Maybe Message)
-- kizashi: POST /v1/signals, CreateSignalReq { actor, recipient, source, signalType, intent, priority, importance, contextTags }
```

## The `rei`/Ren ↔ `shikigami` boundary (two bounded contexts, never each other's internals)

Shikigami (autonomous stream agents, acting on behalf of *no single human's task*) and `shinzui/rei`/
Ren (intention-bound collaborator agents, working *with one human on one intention*) are **different
bounded contexts**. They **never call each other's internals**. They meet only at three loosely
coupled, designed seams (C5; "How `rei`/Ren and `shikigami` interact" in `target-architecture.md`):

- **`shikigami` → `rei` (the explicit handoff bridge — the `ReiAction` sink).** When a finding
  concerns a *specific intention*, the agent records a `rei` action (or opens a `rei`/Ren delegation)
  **against a specific target intention**, invoked through `rei`'s **command API** under the agent's
  `shinzui/shomei` identity (shomei's `act` / actor claim for on-behalf-of attribution). It **NEVER**
  reads or writes `rei`'s store directly. The `ReiAction` sink config therefore carries the **target
  intention id** (not just the free-text `note` shown in the illustrative schema). This runtime
  *defines* the variant and stubs its handler; the real `rei` command-API call is completed by `rei`'s
  plan — but the contract is fixed here: command API + shomei `act` claim, never the store.
- **`rei` → `shikigami` (observe via the stream).** `rei` publishes its agent work — sessions,
  actions, delegations, reviews, blockers — as **`rei.v1`** integration events; `shinzui/kawa`
  normalizes them onto **`activity.v1`**; `shikigami` agents observe them as ordinary activities (the
  same `Stream` trigger). A *"delegation running too long"* detector matches `rei`-sourced
  `activity.v1` envelopes and raises a `KizashiSignal` (or, if the finding concerns the intention, the
  `ReiAction` bridge). `shikigami` learns nothing about `rei`'s internals; it sees only the normalized
  stream.
- **Sessions and memory live in separate stores.** `shikigami` records its own agent sessions (the
  `agent_runs` table) and memory in its own store; `rei` keeps its `agent_session` aggregate. The two
  are joined **only** through `activity.v1` — never a shared table or a direct read. A future shared
  intention-free agent-runtime library (enabling a unified "what are all agents doing now" view) is
  explicit **follow-on work, not this runtime**.

## Cross-Project Requirements (improvement-requests, authored elsewhere)

This runtime composes existing services and proves their seams against stubs/fixtures. Two seams
require **additive, net-new** changes in *other* repos. Those changes are **not** authored here; this
section *names* them so the de-risking ExecPlan can list them as improvement-requests for the owning
repos (authored by other agents into those repos).

### IR-1 — `shinzui/mori`: an `Agent` automation action

`mori` is the project registry/graph plus an automation engine that watches version-control events,
matches rules, and runs actions. Its action type is `Mori.Automation.Types.ReactionAction` (today
`RunCommand | EmitEvent | Notify | Schedule | Signal` — **there is no agent/LLM action**; verified,
`grep -ri handan` over the mori project is empty). The improvement-request is to wire repository
events into agent runs (C3 class 2), additively:

```haskell
-- mori-core : Mori.Automation.Types  (add one constructor)
data ReactionAction = RunCommand ... | EmitEvent ... | Notify ... | Schedule ... | Signal ...
                    | Agent !AgentAction
data AgentAction = AgentAction { agentName :: Text, payload :: Maybe Value }

-- mori-core : Mori.Automation.Executor  (add one dispatch arm)
-- executeAction (Agent action) = executeAgent action
executeAgent :: AgentAction -> IO ReactionResult
--   enqueues a Shikigami run via the shared pgmq-hs agent-run queue (preferred — reuses substrate,
--   keeps mori from depending on Shikigami being reachable synchronously) OR POSTs the inbox HTTP route.
```

Keep the mori edit minimal and additive (one constructor, one dispatch arm, one `executeAgent`
function) so mori's existing behavior is untouched; mark it in mori's changelog and cite C5. On the
Shikigami side, the corresponding inbox is the `EventTrigger` path (the `POST /v1/agents/{name}/runs`
route or the shared queue). **This IR is authored into the `shinzui/mori` repo by another agent, not
here.**

### IR-2 — `shinzui/shomei`: agent sink permission grants

`shomei` (C11) already models `AuthClaims` with `scopes :: Set Scope`, `roles :: Set Role`, and
`actor` (the `act` claim for on-behalf-of attribution), plus `requireScope`/`requireRole` and JWKS
verification. The **only gap** is that the built-in login/session workflow issues tokens with *empty*
scopes (identity, not capability). The improvement-request is a **scoped service-token issuance** path
(reusing the existing `signAccessToken` / `buildClaims` seam) so each declared agent can carry coarse
scopes (`kawa:ingest`, `signal:raise`, …) the doorway gates with `requireScope`. Fine-grained,
per-agent-per-sink permissions stay in Shikigami's local grant table keyed by the verified `sub`;
agents use the `act` claim for on-behalf-of attribution on the `ReiAction` bridge. EP-10 wires the
real grant lookup that replaces `Shikigami.Sink.Permission.checkGrant`'s stub. **This IR is authored
into the `shinzui/shomei` repo by another agent, not here.**

> A third, channel-egress seam (C12) against `shinzui/kanmon` follows the same shape (the agent's
> channel-egress sink calls `kanmon`'s egress API, per-destination authorized by `shomei`); it is
> owned by EP-4/`kanmon` and is named here only as the outbound half of the sink set.

## Conformance & De-risking

This spec is validated *before the build* by frozen contracts in `shinzui/kikan` and a thin
end-to-end proof. The proof and conformance artifacts live in `shinzui/kikan`, not in this repo:

- **Frozen contracts.** C5 (owned), C3, C2, C1, C4, C9, C11, C12, C10 in
  `shinzui/kikan/docs/architecture/evolution/contracts.md` — this spec references them by number and
  does not redefine them.
- **The agent-loop proof (in `shinzui/kikan`).** A thin worker **stub + fixtures** prove the whole
  loop: load a Dhall agent → a trigger fires (schedule *and* stream *and* addressed event) → the
  behavior runs (both arms: a `noop-summary` shikumi program *and* a `triage-note` skill via a stub
  `baikai` provider) → a sink dispatches (`KawaDigest` to the kawa stub, `KizashiSignal` to a kizashi
  stub) → a session row is recorded. The living-loop proof: the kawa stub re-publishes a `KawaDigest`
  envelope onto the fixture `activity.v1` topic and a second agent fires on it. The feedback-guard
  proof: an envelope with `actor.kind: "agent"` fires nothing. The permission proof: a revoked grant
  causes the sink to be skipped with a recorded denial.
- **The contract's own acceptance test (C5).** "Re-express the intelligence layer's detectors as
  declared agents" — delivered by EP-5 (the first consumer). This runtime's contribution is to make
  the schema *capable* of expressing a detector (a `Stream` trigger + a `shikumi`/`handan` program or
  skill + a `KizashiSignal` sink), which the proof demonstrates.
- **The capability map (C6).** This runtime's maturity is recorded as a `shinzui/mori` capability
  record (`spec` → `active` as the build lands), updated by the de-risking ExecPlan.

Because real `kawa`, `shomei`, `mori`'s `Agent` action, and `kanmon` egress are external dependencies,
the proof targets their **endpoint/contract shapes** against stubs/fixtures; when each lands, the stub
is swapped for its client with **no schema change**.

## Open Questions

1. **Schedule evaluator source.** Reuse `rei`'s cron parsing as a library if it is exposed, or pull a
   small cron crate. Settle when scaffolding `Shikigami.Trigger.Schedule`.
2. **Schedule drive mechanism.** Timer loop vs. enqueue-a-due-time-message onto `pgmq-hs` and let the
   shibuya worker pull it (preferred, to reuse substrate). Confirm during the worker proof.
3. **Additional addressed-delivery transports.** The implemented paths are public integration-event
   topics (`consume-events`) and the shared `pgmq-hs` run queue (`enqueue-run`). Add new transports
   only when they preserve service boundaries and do not read another service's database.
4. **The channel-egress sink's concrete schema.** The exact `Sink` variant config for the C12 outbound
   half (conversation key + destination + the egress action), aligned with `kanmon`'s egress API.
   Pin with EP-4/`kanmon`.
5. **`ReiAction` config shape.** The real variant must carry the target intention id (and possibly a
   delegation-vs-action discriminator); pin with `rei`'s owning plan.
6. **Local grant table shape (C11).** The schema of the per-agent-per-sink grant table keyed by the
   verified `sub`, and how it reconciles with `shomei`'s coarse scopes. Pin with EP-10 / IR-2.
7. **Stream consumer offset/checkpoint policy.** How `Shikigami.Trigger.Stream` checkpoints offsets
   against the keiro inbox dedupe so a restart neither double-fires nor loses position. Confirm in the
   stream proof.
8. **Provider registration for the skill arm in CI.** A stub `Baikai.Provider` for deterministic CI
   vs. a real model behind a key. Default to the stub provider (mirrors `noop-summary` running without
   a key).
