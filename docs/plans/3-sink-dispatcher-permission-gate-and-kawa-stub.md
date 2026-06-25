---
id: 3
slug: sink-dispatcher-permission-gate-and-kawa-stub
title: "Sink Dispatcher, Permission Gate, and kawa Stub"
kind: exec-plan
created_at: 2026-06-24T23:41:28Z
intention: "intention_01kvy04813ehbv9aghj3tn4zjx"
master_plan: "docs/masterplans/1-shikigami-declared-agent-runtime-bootstrap.md"
---

# Sink Dispatcher, Permission Gate, and kawa Stub

This ExecPlan is a living document. The sections Progress, Surprises & Discoveries,
Decision Log, and Outcomes & Retrospective must be kept up to date as work proceeds.


## Purpose / Big Picture

A *declared agent* in shikigami is a short typed file that says "run **this behavior**,
when **this trigger** fires, and send the result to **these sinks**." A *sink* is one of
the agent's **outputs** — the thing it *produces* (agents are producers, not just
reactors): a digest activity written back into the activity stream, an awareness signal
raised for a human, a hand-off into another system. This ExecPlan builds the part of the
runtime that takes a behavior's output and **actually sends it out through each sink, but
only if the agent is permitted that sink** — and it builds a tiny stand-in server (the
"kawa stub") so the whole thing is demonstrable before the real downstream services exist.

Concretely, after this plan a developer can, from a fresh checkout of
`/Users/shinzui/Keikaku/bokuno/shikigami` in its nix dev shell:

- Run a test that feeds a sample behavior-output JSON value plus an agent identity through
  `Shikigami.Sink.dispatch`, and observe that an **allow-listed** agent's `KizashiSignal`
  sink POSTs a real `CreateSignalReq` to a stub kizashi server (which records the body),
  while a **denied** agent's sink is *logged and skipped* — the run still completes, and the
  denial is recorded in the result. This proves the **permission gate (contract C11)**.
- Start `shikigami stub-kawa --port 8088` (a small HTTP server that imitates the real
  `shinzui/kawa` ingest doorway), run a test (or `curl`) that dispatches a `KawaDigest`
  sink, and see shikigami build the **nine-field C1 Activity Envelope** (with
  `actor.kind="agent"`, `source="shinzui/shikigami"`, a freshly minted UUIDv7
  `activity_id`, and the behavior output as the payload) and POST it to
  `POST /v1/sources/{source_id}/events`. Posting the **same** envelope twice returns
  `{"activity_id": "...", "deduplicated": true}` the second time — proving the doorway's
  **idempotency on `(source, source_event_id)`** (contract C2).
- Start `shikigami stub-kawa --port 8088 --republish-topic activity.v1 --broker localhost:9092`
  and watch a received `KawaDigest` envelope get **re-published onto the fixture Kafka topic**
  with the correct `keiro-*` headers — the seam that closes the *living loop* (an agent's own
  output reappears on the stream, where a second agent can react to it).

What someone gains: the runtime can now **act on the world** under explicit, swappable
permission control, against stubbed downstream services, so the end-to-end agent loop
(built up by the sibling plans) has a working "produce" stage today and a clean place to
plug real `shinzui/kawa`, `shinzui/kizashi`, and `shinzui/shomei` in later with **no schema
change**.

This is **EP-3** in the MasterPlan at
`docs/masterplans/1-shikigami-declared-agent-runtime-bootstrap.md`. It **hard-depends on
EP-1** (`docs/plans/1-scaffold-agent-schema-loader-and-validate-cli.md`, which produces the
buildable four-package project, the `shikigami-api` wire types including the `Sink` union and
the nine-field `ActivityEnvelope`, and the `cabal.project` pin-set) and **soft-depends on
EP-2** (`docs/plans/2-behavior-runner-and-kioku-session-and-memory-integration.md`, whose
`runBehavior` produces the output `Value` a sink consumes — we build against a fixed sample
`Value` until EP-2 lands). It **owns Integration Point IP-5** (the `dispatch` + `checkGrant`
contract), **produces the IP-6 Activity Envelope** that the `KawaDigest` sink builds, and
must **agree with EP-4** (`docs/plans/4-trigger-evaluators-and-the-activity-v1-stream-consumer.md`)
on the exact `keiro-*` Kafka header set used by `--republish-topic` (documented identically
in both plans; see "Interfaces and Dependencies").


## Progress

Use a checklist to summarize granular steps. Every stopping point must be documented here,
even if it requires splitting a partially completed task into two ("done" vs. "remaining").
This section must always reflect the actual current state of the work.

- [x] M1.1 — `Shikigami.Sink.Permission`: `SinkKind`, `AgentIdentity`, `Denied`, `checkGrant`
      consulting `defaultGrantTable` (static allow-list keyed by agent name). ✅ 2026-06-24
- [x] M1.2 — `Shikigami.Sink.KizashiClient`: `buildSignalReq` builds a `CreateSignalReq` from a
      `KizashiSignal` sink + output; `postSignal` POSTs it via `http-client` (the `CreateSignalReq`
      is mirrored locally in `Shikigami.Sink.Wire`, not a servant client — see Surprises). ✅
- [x] M1.3 — `Shikigami.Sink` dispatcher: `SinkContext`, `SinkResult`, `SinkOutcome`, `dispatch`
      gating every sink on `checkGrant` (denied → logged + skipped + `DeniedOutcome`). ✅
- [x] M1.4 — `Shikigami.Sink.ReiAction` + `Shikigami.Sink.Danwa` stub handlers (log + `Stubbed`).
      Channel egress deferred (EP-1's `Sink` has no channel variant; IR-3). ✅
- [x] M1.5 — Test `shikigami-core-test`: a stub kizashi WAI app; allow-listed `heartbeat` POSTs a
      `CreateSignalReq` (`Delivered "sig_stub"`), denied `intruder` is skipped + recorded, no POST. ✅
- [x] M2.1 — `Shikigami.Sink.KawaClient`: `KawaConfig`, `buildEnvelope` (nine-field C1, mints an
      `act_` id via mmzk-typeid), `postEnvelope` (http-client to the C2 doorway), deterministic
      `source_event_id`. ✅
- [x] M2.2 — `KawaDigest` arm of `dispatch` wired to M2.1. ✅
- [x] M2.3 — `shikigami stub-kawa` (`Shikigami.Cli.Commands.StubKawa` + `Shikigami.Sink.KawaStub`):
      a warp/wai server on the doorway route, idempotent on `(source, source_event_id)`, logging,
      returning `{activity_id, deduplicated}`; empty `source_event_id` → 400. ✅
- [x] M2.4 — Proven two ways: the test-suite (`KawaDigest` group: two dispatches → same id, one
      stored entry) and the live `curl` smoke (first POST `deduplicated:false`, second `true`, same
      `activity_id`, 400 on empty). ✅
- [x] M3.1 — `Shikigami.Sink.KawaStub.Republish.republish`: re-assemble the envelope and publish it
      via `kafka-effectful` with the keiro-* headers. ✅
- [x] M3.2 — `--republish-topic`/`--broker` wired into `stub-kawa`; each accepted (non-dedup)
      envelope is republished. ✅
- [x] M3.3 — Live proof against a Redpanda broker: dispatched a `KawaDigest`, consumed `activity.v1`
      with `rpk`; the value round-trips to the envelope and the headers are exactly
      `keiro-message-id`/`keiro-source=shinzui/kawa`/`keiro-destination=activity.v1`/
      `keiro-event-type=activity.recorded`/`keiro-schema-version=1`/`content-type=application/json`/
      `keiro-occurred-at`/`keiro-source-event-id`, key = `<subject.type>:<subject.id>`. ✅
- [x] M3.4 — `ReiAction`/`Danwa` stub handlers log + return `Stubbed` (covered by the dispatcher). ✅
- [x] M0 — **dev-shell fix:** added `pkgs.rdkafka` to `nix/haskell.nix` (`librdkafka` — the C library
      `hw-kafka-client`/`kafka-effectful` link against, needed by M3 and EP-4). ✅


## Surprises & Discoveries

Document unexpected behaviors, bugs, optimizations, or insights discovered during
implementation. Provide concise evidence.

- **Dependency strategy: mirror ALL wire DTOs locally + use warp/wai + http-client (no servant, no
  kizashi/kawa pins).** Per the user's "use hackage and github, not corpus" directive (recorded in
  the MasterPlan/EP-1), and to avoid the servant version-coherence risk with the pinned kikan set,
  shikigami does **not** pin `kizashi-api`/`kawa-api`. Instead `Shikigami.Sink.Wire` mirrors the
  small, stable C2/C4 wire records (`IngestRequest`/`IngestResponse`/`CreateSignalReq`/
  `SignalResponse`) as plain aeson records whose JSON keys match the real sources (read from
  `bokuno/kizashi/kizashi-api/.../Signal.hs` and `bokuno/kawa/kawa-api,kawa-core`), reusing EP-1's
  `Actor`/`Subject`/`ContextRef` and `SignalType`/`Priority`. The stub-kawa server is a `warp`/`wai`
  app; the kizashi and kawa clients are `http-client` POSTs. The plan's IP-8 note explicitly permits
  mirroring kawa locally; this extends it to kizashi. `cabal build all --dry-run` resolved the
  lightweight set (warp/wai/http-client/http-types/mmzk-typeid/kafka-effectful/uuid) with **no
  conflicts** — only shikigami rebuilds. Swapping a stub for a real client later is a contained
  change to one client module.

- **EP-1's `Sink` has four variants, no channel-egress (affects M1.4).** `Shikigami.Api.Agent.Sink`
  is `KawaDigest | KizashiSignal | ReiAction | DanwaConversation` (EP-1 did not add the channel
  variant — it was an Open Question / IR-3). So `dispatch` handles those four; `SinkKind` keeps
  `SChannelEgress` for forward-compat but no `Sink` maps to it yet. The `Channel` stub handler is
  deferred until the `Sink` variant exists (IR-3, kanmon). `ReiAction`/`DanwaConversation` stubs are
  implemented.

- **`librdkafka` was missing from the dev shell (blocked M3 + EP-4).** `hw-kafka-client` (under
  `kafka-effectful`) links `-lrdkafka`; the seihou dev shell shipped zlib/just/pkg-config/postgresql/
  jq/process-compose but not `librdkafka`, so linking `shikigami-core` (once it imported the republish
  module) failed with `ld: library not found for -lrdkafka`. Added `pkgs.rdkafka` to
  `baseDevPackages` in `nix/haskell.nix` (now `rdkafka 2.13.0` via pkg-config), and built/ran inside
  `nix develop` so the lib is on the link+runtime path. This is a genuine project need (EP-4's
  `activity.v1` consumer also uses `kafka-effectful`), so the fix belongs in the shell, not a
  workaround. Also: `librdkafka` resolves `localhost` to IPv6 `[::1]`; the fixture broker must
  advertise `127.0.0.1` (IPv4) or the producer gets connection-refused.

- **kawa `IngestRequest`/`IngestResponse` use snake_case (`camelTo2 '_'`); kizashi `CreateSignalReq`
  uses default generic (field names verbatim).** Verified against the real sources: kawa's
  `apiAesonOptions = camelTo2 '_'` → `source_event_id`, `context_refs`, `occurred_at`, `activity_id`;
  kizashi's `CreateSignalReq` derives `anyclass (FromJSON, ToJSON)` → keys `signalType`, `contextTags`
  etc. verbatim, with `SignalType`/`Priority` as bare enum strings. `Shikigami.Sink.Wire` reproduces
  both encodings exactly.


## Decision Log

Record every decision made while working on the plan.

- Decision: The permission gate is a **stub static allow-list keyed by agent name**, defined
  in `Shikigami.Sink.Permission` as a pure value (`defaultGrantTable :: Map Text (Set SinkKind)`),
  surfaced behind `checkGrant :: AgentIdentity -> SinkKind -> IO (Either Denied ())`.
  Rationale: the MasterPlan (IP-5) and the spec (C11) require the *shape* of a real
  `shinzui/shomei` grant lookup so EP-10 can swap the body with **no signature change**. An
  `IO`-returning function keyed by the agent's name (the future `shomei` `sub`) is exactly that
  shape; the static table is the de-risking stand-in. The function returns `Either Denied ()`
  (not `Bool`) so the denial reason is carried into the recorded outcome.
  Date: 2026-06-24

- Decision: **Two sinks are implemented fully against stubs** (`KawaDigest`, `KizashiSignal`);
  **three are thin stub handlers** (`ReiAction`, `DanwaConversation`, the channel-egress sink).
  Rationale: the MasterPlan scopes EP-3 to "KawaDigest + KizashiSignal implemented against
  stubs; ReiAction/DanwaConversation/ChannelEgress defined as schema variants with stub
  handlers." The owning plans complete the stubs: `rei`'s plan for `ReiAction`, EP-7 for
  `DanwaConversation`, EP-4/`kanmon` for the channel egress. A stub handler **logs, records a
  `Stubbed` outcome, and returns success** so the run completes and the proof can assert the
  sink was reached.
  Date: 2026-06-24

- Decision: A **denied sink is logged and skipped, never crashes the run**, and the denial is
  recorded in the `SinkResult` (a `SinkOutcome` of `Denied <reason>`). `dispatch` therefore
  *always returns* a `SinkResult` and never throws on a denial.
  Rationale: spec ("A denied sink is logged and skipped … the session row records the denial")
  and MasterPlan IP-5. The worker (EP-5) maps a transient *sink-send* failure (not a denial) to
  `AckRetry`; a denial is a normal, recorded outcome, not a failure.
  Date: 2026-06-24

- Decision: The `KawaDigest` sink targets the **real kawa C2 doorway shape**, read from source
  at `/Users/shinzui/Keikaku/bokuno/kawa/kawa-core/src/Kawa/Core/Http/Ingest.hs` and
  `/Users/shinzui/Keikaku/bokuno/kawa/kawa-api/src/Kawa/Api/Envelope.hs`: `POST
  /v1/sources/{source}/events` with body `IngestRequest` (the envelope **minus**
  `activity_id`/`idempotency_key`, carrying `source_event_id`) and response `IngestResponse {
  activity_id :: Text, deduplicated :: Bool }`. shikigami **mints the UUIDv7 `activity_id`
  itself** (per C1) inside `buildEnvelope`, but the doorway request body is an `IngestRequest`
  (no `activity_id`), so the stub computes/echoes the canonical id and the dedup flag — matching
  exactly what real kawa does.
  Rationale: kawa now *has* Haskell source (it did not when the spec was written); aligning to
  the real wire shape means swapping the stub for `kawa-client` later is a pure config change.
  Date: 2026-06-24

- Decision: `source_event_id` (the doorway's dedup key, paired with the source path segment) is
  derived **deterministically** as `"<agentName>:<runId>:<sinkOrdinal>"`, and the C1
  `idempotency_key` mirrors it.
  Rationale: spec — "derives `idempotency_key` deterministically from `(agent name, trigger
  occurrence)`" and "idempotent on `(source, source_event_id)`." A re-run of the same agent/run
  re-POSTs the same `source_event_id`, so the doorway dedups it (the M2 proof posts twice and
  sees `deduplicated=true`).
  Date: 2026-06-24

- Decision: The `--republish-topic` Kafka headers are exactly the `keiro-*` set produced by
  `Keiro.Integration.Event.integrationHeaders`
  (`/Users/shinzui/Keikaku/bokuno/keiro/keiro-core/src/Keiro/Integration/Event.hs`): the
  always-present `keiro-message-id`, `keiro-source`, `keiro-destination`, `keiro-event-type`,
  `keiro-schema-version`, `content-type`, `keiro-occurred-at`, plus `keiro-source-event-id`.
  The republished record mirrors kawa's own producer
  (`/Users/shinzui/Keikaku/bokuno/kawa/kawa-core/src/Kawa/Activity/Producer.hs`):
  `source="shinzui/kawa"`, `eventType="activity.recorded"`, `schemaVersion=1`,
  `destination="activity.v1"`, key = `"<subject.type>:<subject.id>"`. **EP-4 must use the
  identical set** (documented identically in both plans); this is IP-6.
  Rationale: the keiro idempotent inbox EP-4's consumer uses requires these headers to
  reconstruct the `IntegrationEvent`; using kawa's own producer shape means the stub is a
  faithful stand-in for real kawa's outbox.
  Date: 2026-06-24

- Decision: The HTTP/Kafka libraries are the ecosystem's: `servant`/`servant-server`/`warp`
  (server side of the stub), `servant-client`/`http-client` (the kizashi + kawa clients),
  `kafka-effectful` (the republish producer), and `mmzk-typeid`'s `genKindID` for the UUIDv7
  `activity_id` (the same way kawa mints `ActivityId = KindID "act"` in
  `/Users/shinzui/Keikaku/bokuno/kawa/kawa-api/src/Kawa/Api/Id.hs`). `optparse-applicative` adds
  the `stub-kawa` subcommand.
  Rationale: kizashi's CLI uses `optparse-applicative`; kawa-core depends on
  `servant`/`kafka-effectful`/`mmzk-typeid`; reusing the same libraries keeps shikigami on the
  ecosystem's coherent pin-set (IP-8) and means the kizashi servant client is generated from
  kizashi's own `SignalRoutes` record.
  Date: 2026-06-24


## Outcomes & Retrospective

Summarize outcomes, gaps, and lessons learned at major milestones or at completion.
Compare the result against the original purpose.

**Outcome (2026-06-24): EP-3 complete; all three milestones built and verified.** The three Purpose
behaviors hold:

1. `Shikigami.Sink.dispatch` gates every sink on the C11 `checkGrant`: an allow-listed agent's
   `KizashiSignal` POSTs a `CreateSignalReq` to a stub kizashi server (`Delivered "sig_stub"`); a
   denied agent's sink is logged + skipped + recorded (`DeniedOutcome`), no POST, no crash. Proven by
   the `shikigami-core-test` suite (all 3 cases pass).
2. `shikigami stub-kawa --port N` serves the C2 doorway: a `KawaDigest` dispatch builds the nine-field
   C1 envelope (`actor.kind="agent"`, `source="shinzui/shikigami"`, minted `act_` id) and POSTs it;
   the same `(source, source_event_id)` twice returns `deduplicated:false` then `true` with the same
   `activity_id`. Proven by the test-suite **and** a live `curl` smoke (+ 400 on empty source_event_id).
3. `shikigami stub-kawa --republish-topic activity.v1 --broker 127.0.0.1:9092` republishes each
   accepted envelope onto Kafka. Proven live against a Redpanda container: the consumed record's value
   round-trips to the envelope and its headers are exactly the keiro-* set (IP-6), key
   `<subject.type>:<subject.id>`.

**Deliverables for downstream plans:** `Shikigami.Sink.dispatch`/`checkGrant`/`SinkContext`/
`SinkResult`/`SinkOutcome` (IP-5, the worker EP-5 calls per sink), `Shikigami.Sink.KawaClient`
(`buildEnvelope`/`postEnvelope`), the `stub-kawa` server + republish seam (IP-6, the living loop EP-6
drives), and `Shikigami.Sink.Wire` (the mirrored C2/C4 DTOs).

**Deviations from the plan as written (recorded in Surprises/Decision Log):** (a) wire DTOs mirrored
locally + warp/wai + http-client (no servant, no kizashi/kawa pins) per the "no corpus" directive;
(b) channel-egress deferred (no `Sink` variant); (c) `librdkafka` added to the dev shell (a genuine
project need); (d) the plan's `BaseUrl`/servant types became `Text` URLs.

**Gaps / forward notes:** the `--republish-topic` live proof used a throwaway Redpanda container
(EP-4 owns the project `process-compose.yaml` broker); the M3 test (`-p Republish`, broker-gated) was
not added to the suite — the live `rpk` proof stands in. The kawa/kizashi clients post to stubs; real
service wiring is owned by those services' plans (swap the base URL / replace the one client module).


## Context and Orientation

This section assumes you know nothing about this repository. Read it fully before editing.

**What shikigami is.** `shinzui/shikigami` (式神, a summoned spirit-servant) is a
greenfield Haskell runtime in which an autonomous agent is *declared, not coded*. The full
design is frozen in this repo at `docs/initial-spec.md`; the build is coordinated by the
MasterPlan at `docs/masterplans/1-shikigami-declared-agent-runtime-bootstrap.md`. The
runtime is a four-package cabal project (created by EP-1):

- `shikigami-api` — client-safe wire types (no database/effect dependencies). EP-1 defines,
  in `Shikigami.Api.Agent`, the `Sink` union and, in `Shikigami.Api.Activity` (or alongside
  `Agent`), the nine-field `ActivityEnvelope`. **This plan imports those; it does not redefine
  them.**
- `shikigami-core` — the runtime library. **This plan adds the `Shikigami.Sink.*` modules
  here.**
- `shikigami-cli` — the `shikigami` executable (subcommands under `Shikigami.Cli.Commands.*`).
  **This plan adds the `stub-kawa` subcommand here.**
- `shikigami-migrations` — SQL + a test-support sublibrary. **This plan does not touch it**
  (sinks do not write shikigami's own tables; the session/suppression records are owned by
  EP-2/EP-5).

**Key terms used in this plan (defined in plain language).**

- **Sink** — an agent *output channel*. A `Sink` value (defined in `shikigami-api`) is one of
  five variants: `KawaDigest { subjectType, verb }` (write a digest activity into the activity
  stream), `KizashiSignal { signalType, priority }` (raise an awareness signal for a human),
  `ReiAction { … }` (hand a finding into `shinzui/rei`), `DanwaConversation { topic }` (open a
  conversation), and the channel-egress variant (act on the outside world through
  `shinzui/kanmon`). This plan implements the first two fully and stubs the rest.
- **Sink dispatch** — taking a behavior's output (a JSON `Value`) and *sending it out* through
  one sink. The dispatcher is `Shikigami.Sink.dispatch`.
- **Permission gate (C11)** — before any sink is sent, the runtime asks "is this agent permitted
  this kind of sink?" via `Shikigami.Sink.Permission.checkGrant`. In this plan that is a stub
  consulting a static allow-list keyed by the agent's name; later (EP-10) it becomes a real
  `shinzui/shomei` grant lookup, with the same signature.
- **Activity Envelope (contract C1)** — the canonical nine-field JSON shape every activity in
  the platform takes. The nine fields are: `activity_id` (a UUIDv7 string the publisher mints
  itself), `occurred_at` (an RFC3339 timestamp), `source` (here always `"shinzui/shikigami"`),
  `actor` (`{ kind, id }`, here `kind="agent"`), `subject` (`{ type, id }` — what the activity
  is about), `verb` (a past-tense dotted string like `"digest.produced"`), `payload` (free-form
  JSON — the behavior's output), `context_refs` (a list of `{ scheme, ref }` back-references),
  and `idempotency_key` (derived so re-delivery is a no-op). The real wire type lives in
  `shikigami-api` (EP-1's `ActivityEnvelope`); its field-for-field equivalent in the *real
  downstream* lives in kawa at `/Users/shinzui/Keikaku/bokuno/kawa/kawa-api/src/Kawa/Api/Envelope.hs`.
- **The kawa doorway (contract C2)** — the real `shinzui/kawa` service exposes
  `POST /v1/sources/{source}/events` with body `IngestRequest` and response `IngestResponse {
  activity_id, deduplicated }`, idempotent on `(source, source_event_id)`. Read it at
  `/Users/shinzui/Keikaku/bokuno/kawa/kawa-core/src/Kawa/Core/Http/Ingest.hs`. The *real* doorway
  is gated by a `shomei` JWT and a `kawa:ingest` scope; **the stub omits the auth gate** (it is a
  fixture) but matches the route, request, and response shapes exactly.
- **The kizashi signal contract (contract C4)** — `shinzui/kizashi` exposes
  `POST /v1/signals` with body `CreateSignalReq`. Read the real type at
  `/Users/shinzui/Keikaku/bokuno/kizashi/kizashi-api/src/Kizashi/Api/Signal.hs`: `CreateSignalReq
  { actor :: AuditActor, recipient :: RecipientId, source :: SignalSource, signalType :: SignalType,
  intent :: Intent, priority :: Priority, importance :: Importance, contextTags :: ContextTags }`,
  where `SignalType ∈ {Notification, Alert, Reminder, TaskCandidate, DigestItem, AgentRequest}`
  and `Priority ∈ {Low, Normal, High, Urgent}`. The route record is `SignalRoutes` (its `create`
  field is `ReqBody '[JSON] CreateSignalReq :> PostCreated '[JSON] SignalResponse`); the client is
  generated from it.
- **`keiro-*` headers** — the activity stream is a Kafka topic (`activity.v1`). The
  `shinzui/keiro` integration-event library requires each Kafka message to carry a set of
  `keiro-*` metadata headers so a consumer can reconstruct the typed event and deduplicate
  re-deliveries. The exact set is defined by `Keiro.Integration.Event.integrationHeaders` at
  `/Users/shinzui/Keikaku/bokuno/keiro/keiro-core/src/Keiro/Integration/Event.hs` (see "Interfaces
  and Dependencies" for the full list). The `--republish-topic` mode of the stub emits exactly
  these.
- **The living loop** — an agent's `KawaDigest` output, once re-published onto `activity.v1`,
  reappears on the stream as a first-class memory that a *second* agent (built by EP-4's consumer
  and EP-5's worker) can match and react to. `--republish-topic` is the seam that closes it; the
  full end-to-end demonstration is EP-6's job.

**What already exists when this plan starts.** EP-1 is Complete: `cabal build all` succeeds;
`shikigami-api` exports `Sink`, `ActivityEnvelope` (and its `Actor`/`Subject`/`ContextRef`
sub-records), and the `aeson` instances for all of them; the `cabal.project` pin-set includes
`kizashi-api` (for `CreateSignalReq`/`SignalRoutes`), `kawa-api` (optional — we mirror the
shapes locally to avoid a build edge), `kafka-effectful`, `mmzk-typeid`, and the
servant/http-client stack. **If any wire field this plan needs is missing from `shikigami-api`,
add it there by amending EP-1's deliverable and record it under IP-1 in the MasterPlan — do not
add a competing type in `shikigami-core`.**

**What is stubbed and why.** `shinzui/kawa` (the real activity-stream service), `shinzui/shomei`
(the real permission authority), `shinzui/rei`/`shinzui/danwa`/`shinzui/kanmon` (the targets of
the stubbed sinks) are external dependencies owned by their own plans. This plan proves the seams
against **stubs and a fixture Kafka topic**; when each real service lands, its stub is swapped for
its client with no schema change (the doorway/route/header shapes are already the real ones).


## Plan of Work

The work is three milestones. Each adds modules to `shikigami-core` (and, for M2/M3, the
`stub-kawa` subcommand to `shikigami-cli`) and is independently verifiable by a test you can run
with `cabal test`. Throughout, follow the conventions in "Interfaces and Dependencies" (IP-9:
GHC2024, a `common` cabal stanza every component imports, postpositive `qualified` imports, a
`Shikigami.Prelude` that does **not** re-export `Data.Generics.Labels`, strict `!` fields,
explicit deriving strategies). Read the cookbook first with `mori registry docs haskell-jitsurei`.

### Milestone M1 — the permission gate, the dispatcher skeleton, and the KizashiSignal sink

**Scope.** Build `Shikigami.Sink.Permission` (the C11 stub gate), the `Shikigami.Sink` dispatcher
skeleton (`dispatch` gating every sink on `checkGrant`, returning a `SinkResult`), the
`KizashiSignal` handler (POST a `CreateSignalReq` to a kizashi base URL via a generated servant
client), and the three thin stub handlers (`ReiAction`, `DanwaConversation`, channel egress).

**What will exist at the end.** A test that feeds a fixed sample behavior-output `Value` and an
agent identity through `dispatch` and observes: (a) an **allow-listed** agent's `KizashiSignal`
sink POSTs a well-formed `CreateSignalReq` to a stub kizashi WAI server that records the body;
(b) a **denied** agent's sink is *logged and skipped*, with a `Denied` outcome recorded in the
`SinkResult`, and the run does not throw.

**Commands.** From the repo root in the nix dev shell: `cabal test shikigami-core-test
--test-options='-p Sink'` (the test pattern matches the new `Sink.*` test group).

**Acceptance.** The test passes; its output shows one signal recorded by the stub for the
allow-listed case and `Denied` recorded (no signal) for the denied case. See "Validation and
Acceptance" for the exact assertions.

The `Shikigami.Sink.Permission` module defines the gate. The static allow-list is a pure
`Map Text (Set SinkKind)` value; `checkGrant agent kind` looks up the agent's name and returns
`Right ()` if `kind` is in its set, else `Left (Denied <reason>)`. Keying by *name* is the
de-risking stand-in for keying by the future `shomei`-verified `sub`; the `IO` return type and
the `AgentIdentity`/`SinkKind` argument types are the exact shape EP-10 will keep when it swaps
the body for a `shomei` lookup.

The `Shikigami.Sink` module defines the dispatcher. `dispatch ctx sink output` first computes the
sink's `SinkKind`, calls `checkGrant (sinkCtxIdentity ctx) kind`, and on `Left denied` logs and
returns `SinkResult { sinkKind = kind, outcome = Denied <reason> }` **without sending anything**.
On `Right ()` it routes to the per-variant handler (`KizashiSignal` → `Shikigami.Sink.KizashiClient`;
the others → their handlers), wraps the handler's result in a `SinkResult`, and returns it. A
*send* failure (e.g. the HTTP POST errored) becomes `outcome = Failed <reason>` (the worker, EP-5,
decides retry); a denial is `Denied`; a successful send is `Delivered <detail>`; a stub no-op is
`Stubbed`.

The `Shikigami.Sink.KizashiClient` module builds the `CreateSignalReq` and POSTs it. It generates
a servant client from kizashi's `SignalRoutes` record (imported from `kizashi-api`'s
`Kizashi.Api.Signal`), so the request type is kizashi's own — no hand-rolled JSON. The field
mapping (read from the seed detectors' `RaiseSignal` design in
`agents/detectors/{stalled-intention.dhall,at-risk-customer.dhall,README.md}` and the spec's C4
section) is: `source = SignalSource "shinzui/shikigami"`; `signalType`/`priority` from the
`KizashiSignal` sink config (parsed from the config's `Text` into kizashi's closed enums, failing
loudly on an unknown value); `actor` = an `AuditActor` describing who *caused* the triggering
activity (from the behavior output / sink context, falling back to the agent's identity);
`recipient` = the routing target (from the sink context, falling back to a configured default);
`intent` = `Intent` built from the sink config's intent template applied to the output (a plain
string substitution is sufficient for the stub); `importance` = a fixed default the config can
override; `contextTags` = `ContextTags` always including `"activity://<id>"` if the output carries
one, plus `"verb:<verb>"` / `"subject:<type>"`. (The seed detectors specify the importance bands
and the `activity://` back-reference rule; replicate them.)

The stub handlers (`Shikigami.Sink.ReiAction`, `Shikigami.Sink.Danwa`, `Shikigami.Sink.Channel`)
each take the sink config + the output `Value`, log a single structured line ("ReiAction sink
stubbed for agent <name>: <note>"), and return a `Stubbed` outcome. They do **not** call any
external service. Each module's haddock names the owning plan that will complete it (`rei`'s plan;
EP-7; EP-4/`kanmon`).

### Milestone M2 — the KawaDigest sink, the C1 envelope builder, and the kawa stub server

**Scope.** Build `Shikigami.Sink.KawaClient` (`buildEnvelope` — the nine-field C1 builder;
`postEnvelope` — the servant client for the C2 doorway), wire the `KawaDigest` arm of `dispatch`
to it, and build the `shikigami stub-kawa` server (a WAI app accepting the doorway route,
enforcing idempotency on `(source, source_event_id)` in memory, logging each envelope, returning
`{activity_id, deduplicated}`).

**What will exist at the end.** A test that starts `stub-kawa` in-process (or via the CLI), then
dispatches a `KawaDigest` sink and asserts: the POST body is a nine-field envelope with
`actor.kind="agent"`, `source="shinzui/shikigami"`, the configured `verb`/`subject.type`, and the
sample output as `payload`; the response carries a UUIDv7 `activity_id`; and posting the **same**
envelope twice returns `deduplicated=false` then `deduplicated=true`.

**Commands.** `cabal test shikigami-core-test --test-options='-p KawaDigest'`; and a manual
smoke: `cabal run shikigami -- stub-kawa --port 8088` in one terminal, a `curl` in another (see
"Concrete Steps").

**Acceptance.** The test passes; the second POST of an identical envelope is deduplicated.

`Shikigami.Sink.KawaClient.buildEnvelope` constructs the `ActivityEnvelope` (the `shikigami-api`
type): `activityId` minted with `mmzk-typeid`'s `genKindID` (a UUIDv7 with the `act` prefix, the
same way kawa mints ids); `occurredAt` = the run's timestamp (from `SinkContext`, defaulting to
`getCurrentTime`); `source = "shinzui/shikigami"`; `actor = Actor { kind = "agent", id = <agent
name> }`; `subject = Subject { type = <KawaDigest.subjectType>, id = <subject id from output or
agent name> }`; `verb = <KawaDigest.verb>`; `payload = <the behavior output Value>`; `contextRefs`
= any back-references carried in the output (else empty); `idempotencyKey` = the deterministic
`source_event_id` (see below). `postEnvelope cfg env` POSTs to the doorway. Because the *request*
body is an `IngestRequest` (the envelope minus `activity_id`/`idempotency_key`, plus
`source_event_id`), `postEnvelope` projects the `IngestRequest` from the built envelope: `verb`,
`actor`, `subject`, `payload`, `contextRefs`, `occurredAt`, and `sourceEventId =
"<agentName>:<runId>:<sinkOrdinal>"`. The doorway returns the canonical `activity_id` and the
dedup flag; `postEnvelope` returns `Either KawaError ActivityId`.

The `stub-kawa` server lives in `Shikigami.Cli.Commands.StubKawa` (plus a reusable
`Shikigami.Sink.KawaStub` in `shikigami-core` if the test wants to start it in-process). It is a
servant/warp app serving exactly the doorway route (path `/v1/sources/{source}/events`, method
POST, body `IngestRequest`, response `IngestResponse`). It holds an `IORef (Map (Text, Text)
Text)` keyed on `(source, source_event_id)` → the minted `activity_id`. On each request: if the
key is present, return `IngestResponse { activityId = <stored>, deduplicated = True }`; else mint
a fresh `activity_id` with `genKindID`, store it, log the full envelope (one structured line), and
return `{ activityId = <new>, deduplicated = False }`. The auth gate the real doorway has is
**omitted** (the stub is a fixture). An empty `source_event_id` returns `400` (matching the real
doorway's `EmptySourceEventId`).

### Milestone M3 — `--republish-topic`: closing the living loop

**Scope.** Add `--republish-topic <topic>` and `--broker <host:port>` flags to `stub-kawa`; on
each accepted (non-deduplicated) envelope, re-publish it onto the fixture Kafka topic with the
exact `keiro-*` header set, via `kafka-effectful`. Confirm the three stub handlers log/no-op end
to end.

**What will exist at the end.** With a fixture Redpanda/Kafka broker running (EP-4 owns the
`process-compose.yaml` broker; this plan documents how to start one for the proof), running
`stub-kawa --port 8088 --republish-topic activity.v1 --broker localhost:9092` and dispatching a
`KawaDigest` results in one message on `activity.v1` whose value is the envelope JSON and whose
headers are the `keiro-*` set EP-4's consumer reads.

**Commands.** See "Concrete Steps" M3 — a broker, the stub, a dispatch, and a one-shot consumer
(either a small `cabal` test using `kafka-effectful`, or `rpk topic consume activity.v1` if the
Redpanda CLI is available) to inspect the message + headers.

**Acceptance.** The consumed message carries the eight `keiro-*`/`content-type` headers listed in
"Interfaces and Dependencies", `keiro-destination = activity.v1`, `keiro-source = shinzui/kawa`,
`keiro-event-type = activity.recorded`, and the message value parses back into the envelope.

`Shikigami.Sink.KawaStub.Republish.republish broker topic ingestReq activityId` builds the Kafka
record: value = the envelope JSON (the `IngestRequest` re-assembled into an `ActivityEnvelope`
with the minted `activity_id`, encoded with the `shikigami-api` `ToJSON`); key =
`"<subject.type>:<subject.id>"` (per-subject ordering, matching kawa's producer); headers = the
`keiro-*` set built to mirror `Keiro.Integration.Event.integrationHeaders` with kawa's producer
field values (`source="shinzui/kawa"`, `eventType="activity.recorded"`, `schemaVersion=1`,
`destination=<topic>`, `messageId` = a fresh id, `sourceEventId` = the doorway's
`source_event_id`, `occurredAt` = the envelope's). It publishes via `kafka-effectful`'s producer.
This module is only invoked when `--republish-topic` is set; without the flag the stub behaves
exactly as in M2.

This milestone **closes the living loop**: the EP-6 proof (`docs/plans/6-…`) starts `stub-kawa
--republish-topic`, dispatches a `KawaDigest`, and a *second* agent (via EP-4's consumer + EP-5's
worker) fires on the republished activity. EP-3 owns only the republish *seam*; the end-to-end
demonstration is EP-6.


## Concrete Steps

All commands run from the repository root `/Users/shinzui/Keikaku/bokuno/shikigami` inside the
nix dev shell (enter it with `nix develop` or rely on `direnv` if `.envrc` is allowed). The exact
module names below are the ones to create; transcripts are what you should see.

### Step 0 — confirm the starting state (EP-1 complete)

```bash
cabal build all
```

Expected: a successful build of `shikigami-api`, `shikigami-core`, `shikigami-cli`,
`shikigami-migrations`. If `Shikigami.Api.Agent.Sink` or `Shikigami.Api.Activity.ActivityEnvelope`
is missing, EP-1 is not complete — finish it (or amend it under IP-1) before continuing.

Confirm the downstream contract types are importable:

```bash
cabal repl shikigami-core --build-depends kizashi-api <<'EOF'
import Kizashi.Api.Signal (CreateSignalReq(..), SignalType(..), Priority(..), SignalRoutes(..))
:t CreateSignalReq
EOF
```

Expected: the constructor's type prints with the fields `actor`, `recipient`, `source`,
`signalType`, `intent`, `priority`, `importance`, `contextTags`.

### Step 1 — M1: permission gate + dispatcher + KizashiSignal

Create, in `shikigami-core/src/Shikigami/Sink/`:

- `Permission.hs` (`Shikigami.Sink.Permission`) — `SinkKind`, `AgentIdentity`, `Denied`,
  `defaultGrantTable`, `checkGrant`.
- `KizashiClient.hs` (`Shikigami.Sink.KizashiClient`) — `KizashiConfig`, `buildSignalReq`,
  `postSignal`.
- `ReiAction.hs`, `Danwa.hs`, `Channel.hs` — the stub handlers.

Create `shikigami-core/src/Shikigami/Sink.hs` (`Shikigami.Sink`) — `SinkContext`, `SinkResult`,
`SinkOutcome`, `dispatch`. Add a `Shikigami.Prelude` import to each (the project prelude EP-1
created).

Add the new modules to `shikigami-core/shikigami-core.cabal`'s `exposed-modules`, and add
`kizashi-api`, `servant`, `servant-client`, `http-client`, `containers` (for `Map`/`Set`) to its
`build-depends` if not already present.

Build:

```bash
cabal build shikigami-core
```

Expected: compiles with no warnings (the `common` stanza enables `-Werror`-style warnings per
IP-9; fix any).

### Step 2 — M1 test

Create `shikigami-core/test/Shikigami/SinkSpec.hs` with a `tasty` group named `Sink`. It starts a
**stub kizashi WAI app** in-process (a tiny `servant-server` app serving `SignalRoutes`'s `create`
endpoint, recording each `CreateSignalReq` into an `IORef [CreateSignalReq]` and returning a
`SignalResponse { signalId = "sig_stub", lifecycleState = "active" }`), points a `KizashiConfig` at
it, and runs two cases.

```bash
cabal test shikigami-core-test --test-options='-p Sink'
```

Expected transcript (abbreviated):

```text
Sink
  KizashiSignal allow-listed: POSTs a CreateSignalReq:        OK
  KizashiSignal denied: skipped and recorded, no POST:        OK

All 2 tests passed (0.20s)
```

### Step 3 — M2: KawaClient + envelope builder + stub-kawa server

Create `shikigami-core/src/Shikigami/Sink/KawaClient.hs` (`Shikigami.Sink.KawaClient`) —
`KawaConfig`, `KawaError`, `buildEnvelope`, `postEnvelope`. Create
`shikigami-core/src/Shikigami/Sink/KawaStub.hs` (`Shikigami.Sink.KawaStub`) — `runStubKawa ::
StubKawaOptions -> IO ()` and an in-process `stubKawaApplication :: IORef (Map (Text,Text) Text) ->
Application` so the test can mount it. Wire the `KawaDigest` arm of `dispatch` to `KawaClient`.

Add the `stub-kawa` subcommand in `shikigami-cli`: create
`shikigami-cli/src/Shikigami/Cli/Commands/StubKawa.hs` and add it to the `optparse-applicative`
command parser in the CLI's `Main`/commands module. Flags: `--port <int>` (required),
`--republish-topic <text>` (optional, M3), `--broker <host:port>` (optional, M3).

Build and smoke-test the server:

```bash
cabal run shikigami -- stub-kawa --port 8088
```

Expected (server logs, leave running):

```text
stub-kawa listening on :8088 (doorway POST /v1/sources/{source}/events)
```

In another terminal:

```bash
curl -s -X POST http://localhost:8088/v1/sources/shinzui%2Fshikigami/events \
  -H 'content-type: application/json' \
  -d '{"verb":"digest.produced","actor":{"kind":"agent","id":"heartbeat"},
       "subject":{"type":"heartbeat","id":"heartbeat"},"payload":{"ok":true},
       "context_refs":[],"source_event_id":"heartbeat:run-1:0",
       "occurred_at":"2026-06-20T07:00:00Z"}'
```

Expected first response, then the identical second call:

```text
{"activity_id":"act_01jabc...","deduplicated":false}
{"activity_id":"act_01jabc...","deduplicated":true}
```

(Note the same `activity_id` and `deduplicated` flipping to `true` — the `(source,
source_event_id)` idempotency.)

### Step 4 — M2 test

Add a `KawaDigest` group to the `Sink` test that mounts `stubKawaApplication` in-process, dispatches
a `KawaDigest` sink with a fixed output `Value`, and asserts the nine fields on the recorded
envelope and the two-POST dedup behavior.

```bash
cabal test shikigami-core-test --test-options='-p KawaDigest'
```

Expected:

```text
Sink/KawaDigest
  builds nine-field C1 envelope (actor.kind=agent, source=shinzui/shikigami):  OK
  idempotent on (source, source_event_id): second post deduplicated:           OK

All 2 tests passed (0.31s)
```

### Step 5 — M3: republish + the keiro-* headers

Create `shikigami-core/src/Shikigami/Sink/KawaStub/Republish.hs`
(`Shikigami.Sink.KawaStub.Republish`) — `republish`. Add `kafka-effectful` to
`shikigami-core.cabal`'s `build-depends`. Wire `--republish-topic`/`--broker` into the stub so an
accepted (non-deduplicated) envelope is republished.

Start a fixture broker (EP-4 owns the project `process-compose.yaml`; for this proof a standalone
Redpanda container is sufficient):

```bash
docker run -d --name shikigami-fixture-kafka -p 9092:9092 \
  redpandadata/redpanda:latest \
  redpanda start --overprovisioned --smp 1 --memory 1G \
  --reserve-memory 0M --node-id 0 --check=false \
  --kafka-addr PLAINTEXT://0.0.0.0:9092 --advertise-kafka-addr PLAINTEXT://localhost:9092
```

Run the stub with republish:

```bash
cabal run shikigami -- stub-kawa --port 8088 --republish-topic activity.v1 --broker localhost:9092
```

Dispatch a `KawaDigest` (the M2 `curl` from Step 3, with a fresh `source_event_id` so it is not
deduplicated), then consume:

```bash
rpk topic consume activity.v1 --brokers localhost:9092 -n 1 --print-headers
```

Expected (abbreviated): one record whose value is the envelope JSON and whose headers include:

```text
keiro-message-id:    act_01j...
keiro-source:        shinzui/kawa
keiro-destination:   activity.v1
keiro-event-type:    activity.recorded
keiro-schema-version: 1
content-type:        application/json
keiro-occurred-at:   2026-06-20T07:00:00Z
keiro-source-event-id: heartbeat:run-2:0
```

If `rpk` is unavailable, the same assertion is made by a `cabal` test using `kafka-effectful`'s
consumer (Step 6).

### Step 6 — M3 test (hermetic, via kafka-effectful)

Add a `Republish` test (guarded so it skips when no broker env var like `SHIKIGAMI_FIXTURE_BROKER`
is set, mirroring how the ecosystem gates broker-dependent tests) that: starts the stub with
republish to a unique topic, dispatches a `KawaDigest`, consumes one record with `kafka-effectful`,
and asserts the header set and the round-tripped envelope.

```bash
SHIKIGAMI_FIXTURE_BROKER=localhost:9092 \
  cabal test shikigami-core-test --test-options='-p Republish'
```

Expected:

```text
Sink/Republish
  republished envelope carries the keiro-* header set:  OK
  republished value round-trips to the envelope:        OK

All 2 tests passed (0.9s)
```

Tear down the fixture broker when done:

```bash
docker rm -f shikigami-fixture-kafka
```


## Validation and Acceptance

Acceptance is phrased as observable behavior. The change is effective beyond compilation
because each milestone is proven by a test that exercises a real HTTP POST (M1, M2) or a real
Kafka publish/consume (M3), not just by the code building.

**M1 — permission gate + KizashiSignal.** Run `cabal test shikigami-core-test
--test-options='-p Sink'`. Observe:

- *Allow-listed case*: the agent `heartbeat` (in `defaultGrantTable` with `SKizashiSignal`)
  dispatches a `KizashiSignal` sink with a sample output `Value`. The in-process stub kizashi
  records exactly one `CreateSignalReq`. Assert its fields: `source == SignalSource
  "shinzui/shikigami"`; `signalType == Reminder` (or whatever the sink config names);
  `contextTags` contains `"activity://…"` when the output carries an activity ref; `recipient`
  is the configured/derived target. The returned `SinkResult` has `outcome = Delivered "sig_stub"`.
- *Denied case*: the agent `intruder` (absent from `defaultGrantTable`, or present without
  `SKizashiSignal`) dispatches the same sink. The stub kizashi records **zero** requests. The
  returned `SinkResult` has `outcome = Denied <reason>`, the log contains a "skipped (denied)"
  line, and `dispatch` returns normally (no exception).

**M2 — KawaDigest + envelope + idempotency.** Run `cabal test shikigami-core-test
--test-options='-p KawaDigest'`. Observe:

- The envelope recorded by the in-process `stub-kawa` has all nine fields, with `actor.kind ==
  "agent"`, `source == "shinzui/shikigami"`, `verb` and `subject.type` equal to the `KawaDigest`
  sink config, `payload` equal to the sample output `Value`, and a non-empty UUIDv7
  `activity_id` in the response (matching the `act_` typeid prefix).
- Dispatching the *same* sink for the *same* `(agentName, runId, sinkOrdinal)` twice yields
  `deduplicated == false` then `deduplicated == true`, with the **same** `activity_id` both times.

The manual `curl` smoke in "Concrete Steps" Step 3 demonstrates the same behavior against the
running CLI server.

**M3 — republish + headers (the living-loop seam).** With a fixture broker, run
`SHIKIGAMI_FIXTURE_BROKER=localhost:9092 cabal test shikigami-core-test
--test-options='-p Republish'` (or the `rpk` consume in Step 5). Observe one record on the
target topic whose headers are exactly the `keiro-*`/`content-type` set in "Interfaces and
Dependencies" (with `keiro-destination = <topic>`, `keiro-source = shinzui/kawa`,
`keiro-event-type = activity.recorded`, `keiro-schema-version = 1`, `content-type =
application/json`), and whose value JSON parses back into the `shikigami-api` `ActivityEnvelope`
with the minted `activity_id`. This is the seam EP-4's consumer reads and EP-6's living-loop
proof drives.

**Stub handlers.** A small test (or the M1 test extended) dispatches a `ReiAction`, a
`DanwaConversation`, and a channel-egress sink for an allow-listed agent and asserts each returns
`outcome = Stubbed` and emits its log line, calling no external service.

**Whole-plan acceptance.** All `Sink.*` tests pass; the `stub-kawa` CLI subcommand starts,
serves the doorway, dedups, and (with `--republish-topic`) republishes. Denied sinks never crash
a dispatch and are always recorded. No `shikigami-api` wire type was redefined in
`shikigami-core` (grep `data ActivityEnvelope` / `data Sink` in `shikigami-core/src` returns
nothing).


## Idempotence and Recovery

Every step here is safe to repeat. Re-running `cabal build`/`cabal test` is idempotent. The
`stub-kawa` server's idempotency map is in-memory, so restarting it resets dedup state — that is
intentional for a fixture; a redelivery within one server lifetime is correctly deduplicated, which
is what the proof asserts.

The deterministic `source_event_id = "<agentName>:<runId>:<sinkOrdinal>"` makes re-dispatching the
*same* sink for the *same* run a no-op at the doorway (the second POST returns `deduplicated=true`
with the same `activity_id`). This means a worker (EP-5) that retries a failed run does not produce
duplicate activities. A denied sink is recorded, not retried — re-running the dispatch with the same
(denied) identity simply records the denial again, harmlessly.

If the fixture Kafka broker is unavailable, the republish (M3) fails fast with a `KafkaError`; the
M3 test skips when `SHIKIGAMI_FIXTURE_BROKER` is unset, so CI without a broker stays green. To
recover a wedged fixture broker, `docker rm -f shikigami-fixture-kafka` and re-create it (the topic
is auto-created on first publish, or pre-create it with `rpk topic create activity.v1`).

Rollback is trivial: this plan is purely additive (new modules + one CLI subcommand + new
build-depends). Removing the `Shikigami.Sink.*` modules and the `stub-kawa` command, and reverting
the cabal edits, returns the project to its EP-1 state.


## Interfaces and Dependencies

**Libraries used and why.** `servant`/`servant-server`/`warp` — the `stub-kawa` server and the
in-process stub kizashi (so the request/response shapes are the real servant types, not hand-rolled
JSON). `servant-client`/`http-client` — the kizashi client (generated from kizashi's `SignalRoutes`)
and the kawa doorway client (so swapping in real `kawa-client`/kizashi later is a config change).
`kafka-effectful` (the same major the ecosystem pins, `>=0.3 && <0.4`, as in kawa-core) — the
`--republish-topic` producer. `mmzk-typeid` (`genKindID`) — minting the UUIDv7 `activity_id` exactly
as kawa mints `ActivityId = KindID "act"`. `aeson` — envelope/signal JSON via the `shikigami-api`
instances. `containers` — the grant table (`Map`/`Set`). `optparse-applicative` — the `stub-kawa`
subcommand. `effectful` only if a handler needs it (the dispatcher itself is plain `IO` per IP-5's
signature).

**Conventions (IP-9).** GHC2024 + the shared `common` cabal stanza imported by every component;
`Shikigami.Prelude` (which must **not** re-export `Data.Generics.Labels`); postpositive
`qualified` imports (`import Data.Map.Strict qualified as Map`); strict `!` fields on all records;
explicit deriving strategies (`deriving stock`, `deriving anyclass`); no field-name prefixes;
lens/optics over record-update where the project's other code does. Read the cookbook with `mori
registry docs haskell-jitsurei` before writing.

**Types and signatures that must exist at the end of each milestone.**

End of **M1** — in `shikigami-core`:

```haskell
-- Shikigami.Sink.Permission
data SinkKind
  = SKawaDigest | SKizashiSignal | SReiAction | SDanwaConversation | SChannelEgress
  deriving stock (Eq, Ord, Show, Enum, Bounded)

data AgentIdentity = AgentIdentity
  { agentName :: !Text          -- the de-risking key; later the shomei-verified sub
  }
  deriving stock (Eq, Show)

newtype Denied = Denied { deniedReason :: Text }
  deriving stock (Eq, Show)

defaultGrantTable :: Map Text (Set SinkKind)   -- static allow-list keyed by agent name

checkGrant :: AgentIdentity -> SinkKind -> IO (Either Denied ())
--   stub now; EP-10 swaps the body for a shinzui/shomei grant lookup, same signature.

-- Shikigami.Sink  (IP-5)
data SinkContext = SinkContext
  { sinkCtxIdentity :: !AgentIdentity
  , sinkCtxRunId    :: !Text
  , sinkCtxOrdinal  :: !Int            -- which sink in the agent's list (for source_event_id)
  , sinkCtxKizashi  :: !KizashiConfig
  , sinkCtxKawa     :: !KawaConfig
  , sinkCtxOccurredAt :: !(Maybe UTCTime)
  }

data SinkOutcome
  = Delivered !Text     -- a detail string (e.g. the returned id)
  | Stubbed             -- a thin stub handler ran (ReiAction/Danwa/Channel)
  | Denied' !Text       -- permission denied; the reason
  | Failed !Text        -- the send errored (the worker decides retry)
  deriving stock (Eq, Show)

data SinkResult = SinkResult
  { sinkResultKind    :: !SinkKind
  , sinkResultOutcome :: !SinkOutcome
  }
  deriving stock (Eq, Show)

dispatch :: SinkContext -> Sink -> Value -> IO SinkResult
--   computes the SinkKind, calls checkGrant; on Left -> Denied' (no send);
--   on Right -> per-variant handler; never throws on a denial.

-- Shikigami.Sink.KizashiClient
data KizashiConfig = KizashiConfig { kizashiBaseUrl :: !BaseUrl, kizashiDefaultRecipient :: !Text }
buildSignalReq :: KizashiConfig -> Sink -> AgentIdentity -> Value -> Either Text CreateSignalReq
postSignal :: KizashiConfig -> CreateSignalReq -> IO (Either Text SignalResponse)
--   client generated from Kizashi.Api.Signal.SignalRoutes (the `create` route).
```

(Note: `SinkOutcome`'s denial constructor is shown as `Denied'` to avoid clashing with the
`Denied` newtype from `Permission`; pick the final names during implementation but keep them
distinct.)

End of **M2** — in `shikigami-core`:

```haskell
-- Shikigami.Sink.KawaClient
data KawaConfig = KawaConfig
  { kawaBaseUrl :: !BaseUrl
  , kawaSourceSegment :: !Text   -- the {source} path segment, e.g. "shinzui/shikigami"
  }
data KawaError = KawaHttpError !Text | KawaDecodeError !Text
  deriving stock (Eq, Show)

buildEnvelope :: SinkContext -> Sink -> Value -> IO ActivityEnvelope
--   KawaDigest only; mints activity_id via genKindID; actor.kind="agent";
--   source="shinzui/shikigami"; idempotencyKey = source_event_id (deterministic).

postEnvelope :: KawaConfig -> ActivityEnvelope -> IO (Either KawaError ActivityId)
--   projects an IngestRequest (envelope minus activity_id/idempotency_key, plus
--   source_event_id) and POSTs to /v1/sources/{source}/events (C2 doorway).

-- Shikigami.Sink.KawaStub
data StubKawaOptions = StubKawaOptions
  { stubPort :: !Int
  , stubRepublishTopic :: !(Maybe Text)   -- M3
  , stubBroker :: !(Maybe Text)           -- M3
  }
stubKawaApplication :: IORef (Map (Text, Text) Text) -> Maybe Republisher -> Application
runStubKawa :: StubKawaOptions -> IO ()
```

End of **M3** — in `shikigami-core`:

```haskell
-- Shikigami.Sink.KawaStub.Republish
republish :: Text          -- broker host:port
          -> Text          -- topic
          -> IngestRequest -- the accepted doorway body
          -> Text          -- the minted activity_id
          -> IO (Either KawaError ())
--   builds the Kafka record (value = envelope JSON, key = "<subject.type>:<subject.id>",
--   headers = the keiro-* set below) and publishes via kafka-effectful.
```

**IP-1 — consumed wire types (owned by EP-1, in `shikigami-api`).** `Sink` (the five-variant
union), `ActivityEnvelope` and its `Actor`/`Subject`/`ContextRef` sub-records, and their `aeson`
instances. **This plan imports them and must not redefine them.** If a needed field is missing,
amend EP-1's deliverable and record it under IP-1 in the MasterPlan.

**IP-4 — soft-consumed behavior output (owned by EP-2, in `shikigami-core`).** `runBehavior ::
BehaviorEnv -> AgentDecl -> Value -> IO (Either RunError Value)` produces the output `Value` a
sink consumes. Until EP-2 lands, build and test against a **fixed sample output `Value`**, e.g.
`object [ "summary" .= ("heartbeat ok" :: Text), "activity_ref" .= ("activity://act_seed" :: Text) ]`.

**IP-5 — owned here.** `dispatch :: SinkContext -> Sink -> Value -> IO SinkResult` and `checkGrant
:: AgentIdentity -> SinkKind -> IO (Either Denied ())`. The worker (EP-5,
`docs/plans/5-the-supervised-worker-and-run-orchestration.md`) calls `dispatch` once per sink in
the agent's `sinks` list, with the behavior output `Value` and the agent's identity, and maps a
`Failed` outcome to `AckRetry` (a `Denied` or `Stubbed` outcome is normal — no retry).

**IP-6 — the Activity Envelope and the Kafka header seam.** The `KawaDigest` sink **builds** the
nine-field envelope; EP-4's stream consumer **decodes** it. The `keiro-*` Kafka header set the
`--republish-topic` mode emits — mirroring `Keiro.Integration.Event.integrationHeaders`
(`/Users/shinzui/Keikaku/bokuno/keiro/keiro-core/src/Keiro/Integration/Event.hs`) and kawa's own
producer (`/Users/shinzui/Keikaku/bokuno/kawa/kawa-core/src/Kawa/Activity/Producer.hs`) — is **the
authoritative set EP-4 must match**:

```text
keiro-message-id      : a fresh id (the republished message's id; act_ typeid)
keiro-source          : "shinzui/kawa"            (the producer identity kawa uses)
keiro-destination     : "activity.v1"             (the topic; from --republish-topic)
keiro-event-type      : "activity.recorded"       (kawa's producer eventType)
keiro-schema-version  : "1"
content-type          : "application/json"
keiro-occurred-at     : the envelope's occurred_at, ISO8601
keiro-source-event-id : the doorway's source_event_id (the dedup key)
```

(All are always emitted by the republisher; `keiro-source-event-id` carries the dedup key so the
keiro inbox can dedupe re-deliveries. Optional keiro headers — schema-reference, global-position,
causation/correlation, trace context, attributes — are omitted because the stub does not capture
those, exactly as `integrationHeaders` omits headers whose source field is unpopulated.) **EP-4's
plan documents this identical set; if either side changes a header, both plans must be updated
together (IP-6).**

**IP-8 — the cabal pin-set (owned by EP-1).** This plan adds no new pins beyond what EP-1
established (`kizashi-api`, `kafka-effectful`, `mmzk-typeid`, the servant/http-client stack are
already in the set). If `kawa-api` is desired to import the real `IngestRequest`/`IngestResponse`
instead of mirroring them locally, add it to the pin-set by amending EP-1 (IP-8) and record it;
otherwise mirror those two small records in `shikigami-core` (they are stable C2 shapes).

**Downstream contract sources (read these, do not guess).**

- kizashi C4: `/Users/shinzui/Keikaku/bokuno/kizashi/kizashi-api/src/Kizashi/Api/Signal.hs`
  (`CreateSignalReq`, `SignalType`, `Priority`, `SignalRoutes`).
- kawa C2 doorway: `/Users/shinzui/Keikaku/bokuno/kawa/kawa-core/src/Kawa/Core/Http/Ingest.hs`
  (`POST /v1/sources/{source}/events`, `IngestRequest`, `IngestResponse`).
- kawa C1 envelope: `/Users/shinzui/Keikaku/bokuno/kawa/kawa-api/src/Kawa/Api/Envelope.hs`
  (the nine fields; `Actor`/`Subject`/`ContextRef` wire keys).
- kawa id minting: `/Users/shinzui/Keikaku/bokuno/kawa/kawa-api/src/Kawa/Api/Id.hs`
  (`ActivityId = KindID "act"`, `genKindID`).
- keiro headers: `/Users/shinzui/Keikaku/bokuno/keiro/keiro-core/src/Keiro/Integration/Event.hs`
  (`integrationHeaders` and the `header*` name constants).
- kawa producer (republish reference):
  `/Users/shinzui/Keikaku/bokuno/kawa/kawa-core/src/Kawa/Activity/Producer.hs`.
- seed detectors (the RaiseSignal sink config + suppression contract):
  `/Users/shinzui/Keikaku/bokuno/shikigami/agents/detectors/{stalled-intention.dhall,at-risk-customer.dhall,README.md,schema.dhall}`.
