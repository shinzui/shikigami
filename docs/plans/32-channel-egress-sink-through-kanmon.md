---
id: 32
slug: channel-egress-sink-through-kanmon
title: "Channel egress sink through kanmon"
kind: exec-plan
created_at: 2026-07-08T20:14:28Z
intention: "intention_01kx1tyzqcerzv4ysbktgr9sw9"
master_plan: "docs/masterplans/7-platform-feature-completion-egress-schema-memory-lifecycle-delegation.md"
---

# Channel egress sink through kanmon

This ExecPlan is a living document. The sections Progress, Surprises & Discoveries,
Decision Log, and Outcomes & Retrospective must be kept up to date as work proceeds.


## Purpose / Big Picture

Today a shikigami agent can only produce *internal* outputs: a kawa digest, a kizashi signal,
a rei action, or a danwa conversation. The architecture spec's C12 contract
(docs/initial-spec.md:334-338) promises a fifth sink — channel egress — that lets a declared
agent **act back on the outside world** (reply to an Intercom conversation, answer a Zendesk
ticket) through kanmon's egress API, with kanmon holding the provider credentials so shikigami
never does. That sink does not exist: the `Sink` union in schema/Agent.dhall:43-57 and its
Haskell mirror in shikigami-api/src/Shikigami/Api/Agent.hs:68-83 have four variants, and only
the permission enum reserves a slot for it (`SChannelEgress`,
shikigami-core/src/Shikigami/Sink/Permission.hs:30, commented "reserved... (IR-3)").

After this plan, an agent manifest can declare

```dhall
, sinks = [ A.Sink.ChannelEgress { channel = "intercom", action = "reply", conversationKey = None Text } ]
```

and when the agent runs, the worker POSTs the behavior's output to kanmon's egress endpoint
`POST /channels/intercom/actions/reply`, gated by the same permission check as every other
sink, delivered through the same durable outbox, and idempotent under retry. The observable
proof is hermetic: a new `stub-kanmon` CLI command (the same pattern as the existing
`stub-kawa`) serves kanmon's real wire contract locally, and an end-to-end run shows the
delivery, the dedup on retry, and a denial for an ungranted agent. Because the stub mirrors
kanmon's actual implemented API (verified in the kanmon repo — see Context), swapping to the
real service later is a base-URL and token change with no schema change.


## Progress

Use a checklist to summarize granular steps. Every stopping point must be documented here,
even if it requires splitting a partially completed task into two ("done" vs. "remaining").
This section must always reflect the actual current state of the work.

- [ ] M1: add the `ChannelEgress` alternative to the `Sink` union in schema/Agent.dhall and mirror it in Shikigami.Api.Agent; extend `sinkKindOf`.
- [ ] M1: add the proof manifest `agents/proof/channel-reply.dhall`; `cabal run shikigami -- validate` accepts it and all existing manifests still validate.
- [ ] M2: add `postJSONWith` (header-capable POST) to Shikigami.Sink.Http; add `KanmonConfig` to Shikigami.Sink.Config.
- [ ] M2: new module Shikigami.Sink.KanmonClient (`buildEgressRequest`, `postEgress`); pure request-shape unit tests in shikigami-core/test/Main.hs.
- [ ] M3: dispatcher arm in Shikigami.Sink.runSink; `kanmon` field on `SinkContext`, `AgentRunDeps`, `WorkerEnv`; `--kanmon-url`/`--kanmon-token` worker flags; grant-table entry for the proof agent.
- [ ] M4: new module Shikigami.Sink.KanmonStub + `stub-kanmon` CLI command; WAI-level stub tests.
- [ ] M4: end-to-end proof — enqueue-run against the worker + stub-kanmon; delivered, deduplicated on re-dispatch, denied for `intruder`.
- [ ] Docs: add ChannelEgress to docs/user/sinks.md and the sink list in docs/user/writing-agents.md.


## Surprises & Discoveries

Document unexpected behaviors, bugs, optimizations, or insights discovered during
implementation. Provide concise evidence.

- (Authoring-time) Kanmon's egress API is already implemented, not just specified: the route
  and semantics live at `/Users/shinzui/Keikaku/bokuno/kanmon/kanmon-core/src/Kanmon/Http.hs:134`
  (`("POST", ["channels", channelId, "actions", action]) -> handleEgressRoute ...`) and
  `Kanmon/Egress.hs` (request/response bodies, 401/403 mapping, idempotency). This plan
  therefore pins the *real* wire contract rather than a provisional one; the stub-first
  approach is kept only because kanmon is a separate service outside shikigami's dev stack.


## Decision Log

Record every decision made while working on the plan.

- Decision: The Dhall variant is
  `ChannelEgress : { channel : Text, action : Text, conversationKey : Optional Text }`. This
  settles the spec's Open Question 4 (docs/initial-spec.md:942-944, "conversation key +
  destination + the egress action"): `channel` is the destination (kanmon's channel id, e.g.
  `"intercom"` — kanmon resolves it via `find (\ci -> ci.provider == channelId)`), `action` is
  the declared egress action (must be in the channel instance's `egress` list or kanmon
  returns 404), and `conversationKey` is an optional *static* destination key. When
  `conversationKey` is `None`, the key is resolved dynamically at dispatch time: first from a
  `conversation_key` string field in the behavior's output object, else from the trigger
  activity's `subject.subjectId` when the trigger payload parses as an `ActivityEnvelope`.
  Rationale: kanmon's `EgressActionRequest` requires a `conversation_key`, but a reply agent
  almost always answers *the conversation that triggered it* — forcing a static key would make
  the sink useless for the primary use case, while allowing only a dynamic key would prevent
  fixed-destination agents (e.g. always post to an ops channel). The remaining request fields
  are derived, not declared: `content` from the output (its `reply`/`content`/`summary` string
  field, falling back to compact JSON — the same convention as `renderLearning` in
  Shikigami/Agent/Run.hs:177-184), `idempotency_key` from the deterministic
  `mkSourceEventId` shape `agent:runId:ordinal` (Shikigami/Sink/Types.hs:59-61), and
  `triggering_activity_id` from the trigger activity's `activityId` when available.
  Date: 2026-07-08

- Decision: Build the client against kanmon's real wire contract and prove it against a local
  `stub-kanmon` command in this repo (the KawaStub pattern), not against a live kanmon.
  Rationale: kanmon exists (kanmon-core implements the endpoint) but is not part of this
  repo's process-compose stack; a local stub keeps `cabal run` + `cabal test` hermetic. The
  stub mirrors the verified contract byte-for-byte (same route, same snake_case body, same
  `{activity_id, verb}` response, same 401/403/404 mapping, same idempotency on
  `idempotency_key`), so the later swap is `--kanmon-url` pointing at the real service. No
  schema or client change.
  Date: 2026-07-08

- Decision: Authentication is a config-supplied static bearer token
  (`KanmonConfig.bearerToken :: Maybe Text`) sent as `Authorization: Bearer <token>`; minting
  real per-agent tokens is out of scope and owned by
  docs/plans/22-outbound-authentication-for-sink-clients.md (MasterPlan 4).
  Rationale: kanmon's verifier is currently a config token map
  (`Kanmon.Egress.Config.EgressAuthConfig` / `configVerifier`) explicitly designed to be
  swapped for real shomei JWKS verification with no kanmon change; mirroring that interim
  shape here means plan 22 swaps one seam (`postJSONWith` header construction), not two.
  This plan only adds the mechanical header capability to Shikigami.Sink.Http (additive
  `postJSONWith`; the existing `postJSON` is untouched).
  Date: 2026-07-08

- Decision: Permission gating reuses the existing static `defaultGrantTable` stub
  (Permission.hs:53-61) by granting `SChannelEgress` to the proof agent only; the
  database-backed table is owned by docs/plans/21-database-backed-sink-permission-grants.md
  (MasterPlan 4) behind the unchanged `checkGrant` signature.
  Rationale: `SChannelEgress` is already enumerated in `SinkKind`, so no vocabulary change is
  needed anywhere in the gate; duplicating plan 21's table here would create a merge conflict
  for no proof value.
  Date: 2026-07-08


## Outcomes & Retrospective

Summarize outcomes, gaps, and lessons learned at major milestones or at completion.
Compare the result against the original purpose.

(To be filled during and after implementation.)


## Context and Orientation

This section assumes no prior repository knowledge. Shikigami (this repo,
/Users/shinzui/Keikaku/bokuno/shikigami) is a declared-agent runtime: an agent is a typed
Dhall value (schema at `schema/Agent.dhall`), and when a trigger fires, a worker runs the
agent's behavior and dispatches its declared *sinks* (output destinations). A "sink" is one
alternative of the Dhall `Sink` union (schema/Agent.dhall:43-57), mirrored one-for-one by the
Haskell type `Sink` in shikigami-api/src/Shikigami/Api/Agent.hs:68-83 (the mirror must match
the Dhall alternative and field names exactly or Dhall decoding fails at runtime).

The dispatch path has two halves. At run time, the durable agent-run workflow
(shikigami-core/src/Shikigami/Agent/Workflow.hs) does not call sink endpoints directly: it
journals a "sink intent" and enqueues it on keiro's transactional outbox
(`enqueueSinkIntents`, Workflow.hs:386-440). A separate worker loop (`runOutboxPublisher`,
shikigami-core/src/Shikigami/Worker.hs:103-112) drains the outbox and calls
`publishSinkIntent` (Workflow.hs:561-583), which finally invokes the dispatcher
`Shikigami.Sink.dispatch` (shikigami-core/src/Shikigami/Sink.hs:39-47). `dispatch` computes
the sink's permission kind via `sinkKindOf` (Sink.hs:31-36), gates it with
`checkGrant :: AgentIdentity -> SinkKind -> IO (Either Denied ())`
(shikigami-core/src/Shikigami/Sink/Permission.hs:65-71, a static allow-list stub keyed by
agent name), and on grant routes to the per-variant handler in `runSink` (Sink.hs:51-65).
Each handler uses a small config record from shikigami-core/src/Shikigami/Sink/Config.hs
(`KawaConfig`, `KizashiConfig`, `DanwaConfig`) carried in `SinkContext`
(shikigami-core/src/Shikigami/Sink/Types.hs:29-38), and the HTTP POSTs go through the shared
helper `postJSON` (shikigami-core/src/Shikigami/Sink/Http.hs:31-51 — note it supports no
custom request headers today).

"Kanmon" (関門, /Users/shinzui/Keikaku/bokuno/kanmon — discoverable via
`mori registry show kanmon --full`) is the platform's bidirectional channel runtime: it
normalizes inbound provider webhooks into Activity Envelopes, and its *egress* half lets an
authorized caller act on an external conversation. Its egress API is implemented (not merely
specified) in kanmon-core:

- Route: `POST /channels/{channelId}/actions/{action}` (Kanmon/Http.hs:134). 404 for an
  unknown channel or an action not in the channel instance's declared `egress` list; 400 for
  a malformed body.
- Request body (`Kanmon.Egress.EgressActionRequest`, snake_case wire keys):
  `{"conversation_key": Text, "content": Text, "idempotency_key": Text?, "triggering_activity_id": Text?}`.
- Auth: `Authorization: Bearer <token>` verified by a `ShomeiVerifier` (today a config token
  map, later real shomei); missing/bad token → 401 `{"error":"unauthenticated"}`.
- Authorization: per-destination — the verified subject must be granted the
  `conversation_key` (instance grants or a local grant table); otherwise 403
  `{"error":"forbidden"}` (Kanmon/Egress/Authz.hs).
- Success: 200 `{"activity_id": <uuid>, "verb": "<provider>.reply_sent"}`; kanmon calls the
  provider, publishes the reply envelope, and records idempotency on
  `(provider, idempotency_key)` so a retried POST with the same key returns the same
  `activity_id` without re-sending (Kanmon/Egress.hs:100-135).

Shikigami's role per C12 (docs/initial-spec.md:334-338, :642-643, :902-904): construct the
egress call and present its identity; **never** hold provider credentials and never name an
arbitrary destination — kanmon enforces the destination authorization.

The precedent this plan follows is the kawa stub: shikigami-core/src/Shikigami/Sink/KawaStub.hs
is a warp/wai app imitating the real kawa doorway (route, idempotency map, response shape),
exposed as the `stub-kawa` CLI command (shikigami-cli/src/Shikigami/Cli/Commands/StubKawa.hs,
wired in shikigami-cli/src/Shikigami/Cli.hs). The `stub-kanmon` command mirrors this exactly.

Terms: the "outbox" is keiro's transactional at-least-once delivery table (a sink send is
first stored in the same transaction as the workflow journal, then published by a loop);
"idempotency key" is the deduplication key that makes retried deliveries harmless; a
"grant" is an (agent, sink-kind) permission entry.


## Plan of Work

The work proceeds in four milestones. Everything is additive; no existing sink's behavior
changes.

### Milestone 1 — The `ChannelEgress` declaration surface

Scope: an agent manifest can declare the sink and it decodes; nothing dispatches yet. In
schema/Agent.dhall, add a fifth alternative to the `Sink` union (after `DanwaConversation`):

```dhall
| ChannelEgress :
    { channel : Text                    -- kanmon channel id, e.g. "intercom"
    , action : Text                     -- declared egress action, e.g. "reply"
    , conversationKey : Optional Text   -- static destination; None = resolve from payload/output
    }
```

Mirror it in shikigami-api/src/Shikigami/Api/Agent.hs by adding a constructor to `Sink`:

```haskell
| ChannelEgress {channel :: !Text, action :: !Text, conversationKey :: !(Maybe Text)}
```

(the module already uses `DuplicateRecordFields`-style overlapping selectors across `Sink`
constructors — `subjectType`, `source`, `topic` — so the new field names are safe). In
shikigami-core/src/Shikigami/Sink.hs extend `sinkKindOf` with
`ChannelEgress {} -> SChannelEgress` — `SChannelEgress` already exists
(Permission.hs:25-31), so `SinkKind` does not change. GHC's incomplete-pattern warnings will
point at every other `case` over `Sink` that needs an arm (at minimum `runSink`, handled in
M3 — until then give it a temporary `Failed "ChannelEgress not wired"` arm so the build stays
green and honest).

Create the proof manifest `agents/proof/channel-reply.dhall`:

```dhall
let A = ../../schema/Agent.dhall

in  A.Agent::{
    , name = "channel-reply"
    , description = "Proof agent: replies to the triggering external conversation via kanmon egress"
    , behavior =
        A.Behavior.ShikumiProgram
          { task = "noop-summary"
          , preferEnrichment = False
          , grounding = None Text
          , enabledBy = None Text
          }
    , trigger = A.Trigger.Event { eventType = "channel.intercom.message-received" }
    , sinks =
        [ A.Sink.ChannelEgress
            { channel = "intercom", action = "reply", conversationKey = None Text }
        ]
    }
```

Acceptance: `cabal run shikigami -- validate agents/proof/channel-reply.dhall` prints the
decoded manifest and `OK: 1 agent parsed.`; `cabal run shikigami -- validate
agents/heartbeat.dhall` is byte-identical to before (proving the union extension is
backward-compatible).

### Milestone 2 — `KanmonConfig` and the `KanmonClient`

Scope: a pure, unit-testable client for kanmon's wire contract. In
shikigami-core/src/Shikigami/Sink/Http.hs add an additive helper (keep `postJSON` untouched):

```haskell
postJSONWith :: (ToJSON a) => [(HeaderName, ByteString)] -> Text -> a -> IO (Either Text LBS.ByteString)
```

identical to `postJSON` except the extra headers are appended to `requestHeaders` (content
type stays). In shikigami-core/src/Shikigami/Sink/Config.hs add:

```haskell
data KanmonConfig = KanmonConfig
  { baseUrl :: !Text,            -- e.g. "http://localhost:8090"
    bearerToken :: !(Maybe Text) -- interim static token; plan 22 owns real minting
  }
  deriving stock (Eq, Show)
```

New module shikigami-core/src/Shikigami/Sink/KanmonClient.hs with three pieces. First the wire
types (snake_case, matching Kanmon.Egress exactly — write the ToJSON/FromJSON instances by
hand or with field-label modifiers so the keys are `conversation_key`, `content`,
`idempotency_key`, `triggering_activity_id`, `activity_id`, `verb`). Second the pure builder:

```haskell
buildEgressRequest ::
  Sink ->                      -- the ChannelEgress variant (crash-free: callers match first)
  Text ->                      -- idempotency key (mkSourceEventId of the SinkContext)
  Maybe ActivityEnvelope ->    -- the trigger activity, when the payload parses as one
  Value ->                     -- the behavior output
  Either Text EgressActionRequest
```

which resolves `conversation_key` per the Decision Log (declared key, else output
`conversation_key` field, else the activity's `subject.subjectId`, else
`Left "channel egress: no conversation key"`), resolves `content` (output's
`reply`/`content`/`summary` string field, else compact JSON), and sets
`triggering_activity_id` from the activity's `activityId`. Third the sender:

```haskell
postEgress :: KanmonConfig -> Text -> Text -> EgressActionRequest -> IO (Either Text EgressActionResponse)
```

which POSTs to `<baseUrl>/channels/<channel>/actions/<action>` via `postJSONWith` with the
bearer header when configured, decodes the 200 body, and renders non-2xx as
`Left` (the outbox publisher maps `Failed` to a retry, so 5xx retries and the idempotency key
makes that safe; a 403 is also a `Left`, which retries — acceptable at-least-once behavior,
noted for plan 19's delivery-truth work).

Acceptance: pure unit tests in shikigami-core/test/Main.hs assert (a) declared-key,
output-key, and subject-fallback resolution; (b) the JSON encoding uses the exact snake_case
keys; (c) missing key yields `Left`. `cabal test shikigami-core` passes.

### Milestone 3 — Dispatcher arm and configuration plumbing

Scope: a granted `ChannelEgress` sink actually sends. Add `kanmon :: !KanmonConfig` to
`SinkContext` (Sink/Types.hs:29-38), to `AgentRunDeps` (Workflow.hs:79-89), and to
`WorkerEnv` (Worker.hs:55-63); thread it in `agentRunDeps` (Worker.hs:194-206) and in
`publishSinkIntent`'s `SinkContext` construction (Workflow.hs:566-578). The `SinkIntent`
payload already carries the full `Sink` and `output` values, so most of the wire is in place;
what is missing is the trigger activity (source of `triggering_activity_id` and the
subject-id fallback key). Extend the internal `SinkIntent` record (Workflow.hs:96-104) with
`triggeringActivity :: !(Maybe ActivityEnvelope)` — an additive `Maybe` field, so
already-enqueued intents decode as `Nothing` — populated in `buildSinkIntent` (and left
`Nothing` in `prepareSinkIntent`'s flow/conversation path) by parsing the job's
`triggerPayload` as an `ActivityEnvelope`. Mirror it as
`triggeringActivity :: !(Maybe ActivityEnvelope)` on `SinkContext` so the handler can reach
it.

Replace M1's placeholder arm in `runSink` (Sink.hs:51-65):

```haskell
ChannelEgress {} ->
  case buildEgressRequest sink (mkSourceEventId ctx) (triggeringActivity ctx) output of
    Left e -> pure (Failed e)
    Right req -> do
      r <- postEgress (kanmon ctx) channel action req
      pure (either Failed (Delivered . activity_id) r)
```

Add worker CLI flags `--kanmon-url` (default `http://localhost:8090`) and `--kanmon-token`
(optional) in shikigami-cli/src/Shikigami/Cli.hs and Commands/Worker.hs, mirroring
`--kawa-url`. Grant the proof agent in `defaultGrantTable` (Permission.hs:53-61): add
`("channel-reply", Set.fromList [SChannelEgress])`. Do not grant anyone else — the denial
proof relies on that.

Acceptance: `cabal build all` clean; the M4 end-to-end scenario is now wired end to end.

### Milestone 4 — `stub-kanmon` and the living-loop proof

Scope: a hermetic, observable end-to-end demonstration plus regression tests. New module
shikigami-core/src/Shikigami/Sink/KanmonStub.hs modeled line-for-line on KawaStub.hs: a wai
`Application` handling `POST /channels/{channel}/actions/{action}` that (a) checks
`Authorization: Bearer <token>` when a token is configured (else accepts), returning 401 on
mismatch; (b) returns 404 unless the channel/action pair is in a small configured allow list
(default: `intercom`/`reply`); (c) keeps an in-memory `IORef (Map (Text, Text) Text)` from
`(channel, idempotency_key)` to the minted activity id, returning the stored id on a
duplicate; (d) responds 200 `{"activity_id": ..., "verb": "conversation.reply_sent"}` and
logs one line per accepted action. Expose `runStubKanmon :: StubKanmonOptions -> IO ()` and
wire a `stub-kanmon` CLI command (`--port`, `--token`) in Cli.hs +
Commands/StubKanmon.hs, following StubKawa.hs.

Tests, in shikigami-core/test/Main.hs (WAI level, `testWithApplication`, like the existing
kawa stub tests): 200 + dedup on repeated `idempotency_key`; 401 with a wrong token; 404 for
an undeclared action. And one database-backed test in
shikigami-core/test/Shikigami/AgentWorkflowSpec.hs style using
`withShikigamiMigratedDatabase`: run the agent-run workflow for `channel-reply`, assert the
journal records a `dispatch-sinks` result with kind `SChannelEgress` and outcome
`Delivered "outbox:..."`, then drive `publishSinkIntent` against the stub and assert the stub
received exactly one action; re-publish the same outbox row and assert the stub's map still
has one entry (idempotency). A second workflow run for an ungranted agent (`intruder` is
already the conventional name) asserts `DeniedOutcome`.

Acceptance: the Concrete Steps transcript below reproduces exactly.


## Concrete Steps

All commands run from the repo root `/Users/shinzui/Keikaku/bokuno/shikigami`, inside the Nix
dev shell (`nix develop` provides ghc, cabal, dhall, just, and a Postgres toolchain). The
database-backed pieces need `just create-database` once (idempotent).

Step 1 — baseline before edits:

```bash
cabal build all
cabal run shikigami -- validate agents/heartbeat.dhall
```

Expected: the decoded `AgentDecl` for heartbeat and `OK: 1 agent parsed.`.

Step 2 — after M1:

```bash
cabal run shikigami -- validate agents/proof/channel-reply.dhall
```

Expected (shape):

```text
AgentDecl {name = "channel-reply", ..., sinks = [ChannelEgress {channel = "intercom", action = "reply", conversationKey = Nothing}]}
OK: 1 agent parsed.
```

Step 3 — after M2/M3, build and unit-test:

```bash
cabal build all
cabal test shikigami-core
```

Expected: all suites pass, including the new `KanmonClient` request-shape assertions.

Step 4 — after M4, the end-to-end proof. Terminal 1, the stub:

```bash
cabal run shikigami -- stub-kanmon --port 8090 --token proof-token
```

Terminal 2, the worker (DB env comes from the dev shell; `PG_CONNECTION_STRING` must be set
as for any worker run):

```bash
cabal run shikigami -- worker --agents agents/proof --kanmon-url http://localhost:8090 --kanmon-token proof-token
```

Terminal 3, enqueue a run whose payload carries a conversation key:

```bash
cabal run shikigami -- enqueue-run channel-reply --payload '{"conversation_key":"conv-42","text":"customer asked for an update"}'
```

Expected: terminal 1 logs one accepted action for `intercom/reply` with
`conversation_key=conv-42` and prints the minted activity id; terminal 2 logs the workflow
completing and the outbox publish succeeding. Re-running the same `enqueue-run` command
re-uses the same idempotency key path only if the same run id is replayed — to observe dedup
directly, kill and restart the worker mid-publish or re-run the M4 test, which asserts the
stub's idempotency map holds a single entry after a double publish.

Step 5 — regression:

```bash
cabal test all
```

Expected: green, including the workflow-level Delivered/Denied/dedup assertions.


## Validation and Acceptance

Acceptance is behavioral. Given `agents/proof/channel-reply.dhall` (a `ChannelEgress` sink,
channel `intercom`, action `reply`, no static key), the static grant
`channel-reply → {SChannelEgress}`, and `stub-kanmon` on port 8090 with token `proof-token`:

1. Enqueuing a run with payload `{"conversation_key":"conv-42", ...}` results in the stub
   receiving `POST /channels/intercom/actions/reply` with body
   `{"conversation_key":"conv-42","content":...,"idempotency_key":"channel-reply:<runId>:0",...}`
   and the run's journal recording `Delivered "outbox:..."` for kind `SChannelEgress`.
2. Publishing the same outbox message twice results in exactly one provider-visible action:
   the stub's `(channel, idempotency_key)` map has one entry and both publishes return the
   same `activity_id`.
3. An agent without the grant gets `DeniedOutcome` with reason
   `agent 'intruder' is not granted ChannelEgress`, the run does not fail, and nothing is
   POSTed (the existing denied-sink contract: logged, skipped, recorded).
4. A wrong `--kanmon-token` yields 401 from the stub, surfaced as a `Failed` outcome, which
   the outbox publisher retries (observable as repeated stub 401 log lines) — proving errors
   are not swallowed.
5. All prior manifests validate unchanged: `cabal run shikigami -- validate
   agents/heartbeat.dhall` output is identical to the pre-change baseline.

Exact test commands: `cabal test shikigami-core` (unit + WAI stub tests; hermetic) and
`cabal test all` (includes the `withShikigamiMigratedDatabase`-backed workflow tests, which
require the dev-shell Postgres and `just create-database`).


## Idempotence and Recovery

Every edit is additive (a new union alternative with mirrored constructor, a new config
field, new modules, a new CLI command); re-applying the steps is a no-op, and agents that do
not declare `ChannelEgress` are untouched. The dispatch path inherits the existing outbox
semantics: the intent is journaled and enqueued transactionally, so a crash between journal
and publish re-publishes on recovery, and the deterministic idempotency key
(`agent:runId:ordinal`) makes the re-send harmless at kanmon (and at the stub). If M3's
`SinkContext` change breaks a call site, the compiler lists every constructor site — fix them
all before proceeding; there is no partial-wiring hazard because the M1 placeholder arm keeps
`runSink` total. Rollback: revert the dispatcher arm to the placeholder and remove the sink
from manifests; the schema alternative can remain (unused alternatives are inert).


## Interfaces and Dependencies

Owned and defined by this plan (all in this repo):

- `schema/Agent.dhall` — the `ChannelEgress` alternative on `Sink` (shape in the Decision Log).
- `Shikigami.Api.Agent` (shikigami-api) —
  `ChannelEgress {channel :: !Text, action :: !Text, conversationKey :: !(Maybe Text)}` on `Sink`.
- `Shikigami.Sink.Http` — `postJSONWith :: ToJSON a => [(HeaderName, ByteString)] -> Text -> a -> IO (Either Text LBS.ByteString)` (additive; `postJSON` unchanged).
- `Shikigami.Sink.Config` — `data KanmonConfig = KanmonConfig {baseUrl :: !Text, bearerToken :: !(Maybe Text)}`.
- `Shikigami.Sink.KanmonClient` — `EgressActionRequest`/`EgressActionResponse` wire types
  (snake_case keys matching Kanmon.Egress),
  `buildEgressRequest :: Sink -> Text -> Maybe ActivityEnvelope -> Value -> Either Text EgressActionRequest`,
  `postEgress :: KanmonConfig -> Text -> Text -> EgressActionRequest -> IO (Either Text EgressActionResponse)`.
- `Shikigami.Sink` — `sinkKindOf (ChannelEgress {}) = SChannelEgress`; the `runSink` arm.
- `Shikigami.Sink.KanmonStub` — `StubKanmonOptions`, `stubKanmonApplication`, `runStubKanmon`;
  CLI command `stub-kanmon --port N [--token T]`.
- `Shikigami.Sink.Types` / `Shikigami.Agent.Workflow` / `Shikigami.Worker` / CLI — the
  `kanmon :: KanmonConfig` plumbing and `--kanmon-url`/`--kanmon-token` flags; the additive
  `triggeringActivity :: Maybe ActivityEnvelope` on the internal `SinkIntent` and on
  `SinkContext`.

Consumed contracts (external, verified in source — do not redefine):

- Kanmon egress wire contract: route `POST /channels/{channelId}/actions/{action}`; body and
  response per `/Users/shinzui/Keikaku/bokuno/kanmon/kanmon-core/src/Kanmon/Egress.hs:46-71`;
  status mapping per `Kanmon/Http.hs:160-186` (200/400/401/403/404); idempotency on
  `(provider, idempotency_key)`. Locate kanmon via `mori registry show kanmon --full`.
- `Shikigami.Sink.Permission.checkGrant` — signature frozen; the grant *storage* is swapped by
  docs/plans/21-database-backed-sink-permission-grants.md (MasterPlan 4).
- Outbound auth header *values* — owned by
  docs/plans/22-outbound-authentication-for-sink-clients.md (MasterPlan 4); this plan only
  supplies the static-token seam.
- keiro outbox (`Keiro.Outbox.enqueueOutboxTx`, `publishClaimedOutbox`) — already in use by
  every sink; unchanged.

Build/test toolchain: Nix dev shell; `cabal build all`; `cabal test all`;
`just create-database` for the Postgres-backed tests
(`Shikigami.Migrations.TestSupport.withShikigamiMigratedDatabase :: (Text -> IO a) -> IO a`).
