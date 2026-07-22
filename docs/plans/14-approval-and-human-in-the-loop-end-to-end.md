---
id: 14
slug: approval-and-human-in-the-loop-end-to-end
title: "Approval and human-in-the-loop end to end"
kind: exec-plan
created_at: 2026-07-08T20:14:28Z
intention: "intention_01kx1tygnxenvarsw91bjsy19r"
master_plan: "docs/masterplans/2-production-reality-de-stub-the-runtime-behavior-and-integration-path.md"
---

# Approval and human-in-the-loop end to end

This ExecPlan is a living document. The sections Progress, Surprises & Discoveries,
Decision Log, and Outcomes & Retrospective must be kept up to date as work proceeds.


## Purpose / Big Picture

shikigami's durable approval machinery is real and tested — a workflow can park on a
keiro "awakeable" (a durable promise), journal the notification, arm a deterministic
deadline timer, and resume when someone answers — but in production nobody can ever
answer, and nobody is ever asked. The worker wires `defaultApprovalEnv`, whose policy
always answers "no approval required" and whose notify hooks are no-ops
(`shikigami-core/src/Shikigami/Agent/Approval.hs:91-98`, wired at
`shikigami-core/src/Shikigami/Worker.hs:204`). `resolveApproval`
(`Approval.hs:117-122`) exists but no HTTP endpoint or CLI command calls it. A Flow
parked on `awaitAcknowledgement` therefore notifies nobody and can only time out
(fallback 900 seconds, `shikigami-core/src/Shikigami/Agent/Workflow.hs:312-314`).

After this plan, an operator can declare (via environment configuration) that certain
sink kinds require human approval. When such an agent runs, the workflow parks, a real
notification is posted through an existing sink — a danwa conversation message or a
kizashi signal — containing a human-readable prompt and a resolution token, and a human
resolves it from the terminal:

```bash
cabal run shikigami -- resolve-approval 7f3c...uuid --approve
```

The parked workflow then resumes on the worker's next resume pass and dispatches (or,
on `--reject`, suppresses) the sink. Timeouts still work exactly as tested today. The
approval *semantics* (awakeable + journaled notify step + deterministic UUIDv5 deadline
timer) are already proven by `shikigami-core/test/Shikigami/AgentWorkflowSpec.hs`
(Approval group, lines 335-386; Deadline group, lines 387-432) — this plan reuses them
untouched and supplies the three missing production pieces: a real policy, a real
notification path, and a real resolution path.


## Progress

- [ ] Milestone 1: `Shikigami.Agent.Approval.Policy` module — `ApprovalPolicy`,
      `resolveApprovalPolicy` (env-driven), `policyApprovalEnv` with danwa/kizashi
      `postAsk`; unit tests for policy parsing and the requiresApproval gate.
- [ ] Milestone 2: worker wiring — `WorkerEnv` carries the policy; `agentRunDeps` uses
      `policyApprovalEnv` and the policy deadline; loud startup log of the active
      policy; integration test with a warp stub capturing the danwa ask.
- [ ] Milestone 3: `resolve-approval` CLI command calling `resolveApproval`; round-trip
      test (park → capture token → CLI-style resolve → resume → sink dispatched).
- [ ] Milestone 4: manual end-to-end transcript against a running worker recorded in
      this plan.


## Surprises & Discoveries

(None yet.)


## Decision Log

- Decision: Approval policy comes from environment configuration
  (`SHIKIGAMI_APPROVAL_REQUIRE`, `SHIKIGAMI_APPROVAL_CHANNEL`,
  `SHIKIGAMI_APPROVAL_DEADLINE_SECONDS`) and lives behind a small `ApprovalPolicy`
  record and one `requiresApprovalFor` function — not in the Dhall agent schema yet.
  Rationale: plan 33 owns identity, memory policy, and enablement, not approval policy.
  Keeping approval configuration behind one small pure interface still permits a
  future, explicitly scoped schema plan to replace the source without changing the
  machinery. Environment configuration follows the config idiom established by plan
  13.
  Date: 2026-07-08
- Decision: The notification path reuses existing sink clients — danwa
  (`Shikigami.Sink.Danwa`) for `ViaDanwa`, kizashi (`Shikigami.Sink.KizashiClient`)
  for `ViaKizashi` — rather than introducing a new notification channel.
  Rationale: the `ApprovalChannel` type already enumerates exactly these two
  (`Approval.hs:59-63`); both clients are already configured in `WorkerEnv`; and
  `SignalType` already has an `AgentRequest` constructor
  (`shikigami-api/src/Shikigami/Api/Agent.hs:21-29`) that is semantically "an agent
  asks a human for something".
  Date: 2026-07-08
- Decision: This plan hard-depends on
  `docs/plans/22-outbound-authentication-for-sink-clients.md` and sends both danwa and
  kizashi approval asks through its `SinkHttp`.
  Rationale: approval asks are production outbound calls. Sending them through the old
  raw clients would bypass the credential, timeout, and connection-manager policy that
  plan 22 establishes and would leave a second HTTP path for later contributors to
  reconcile.
  Date: 2026-07-22
- Decision: The resolution path is a CLI command (`resolve-approval <token>
  --approve/--reject`), not an HTTP endpoint.
  Rationale: shikigami has no HTTP server today and MasterPlan 6 (operations) owns
  introducing one; a CLI command is the minimum honest resolution path, uses the same
  `PG_CONNECTION_STRING` access every other command uses, and exercises the exact
  `resolveApproval` function an HTTP handler would later call. The token round-trip is
  clean because `AwakeableId` is a newtype over `UUID` with exported constructor and
  `awakeableIdText = UUID.toText` (`keiro/src/Keiro/Workflow/Awakeable.hs:119-131`), so
  the CLI parses the printed token with `Data.UUID.fromText`.
  Date: 2026-07-08
- Decision: A `postAsk` delivery failure crashes the notify step (throws), rather than
  being swallowed.
  Rationale: `awaitApproval` wraps `recordPark`+`postAsk` in the journaled step
  `<name>:notify` (`Approval.hs:107-114`); a throw before the journal append means the
  notify is retried on the next resume pass, so the ask is at-least-once. Swallowing
  the failure would recreate exactly the silent-stub problem this MasterPlan exists to
  remove.
  Date: 2026-07-08
- Decision: When no approval policy is configured, the worker keeps
  `defaultApprovalEnv` (auto-approve) but logs it loudly at startup.
  Rationale: approval-off must stay the safe default for existing deployments and CI;
  the failure mode being fixed is *silence*, not permissiveness.
  Date: 2026-07-08


## Outcomes & Retrospective

(To be filled during and after implementation.)


## Context and Orientation

Orientation for a reader new to this repository. shikigami (repo root
`/Users/shinzui/Keikaku/bokuno/shikigami`) runs declared agents as durable **keiro
workflows**: each lifecycle step (`open-session`, `recall`, `run-behavior`,
`dispatch-sinks`, `record`, `complete`) is journaled in Postgres so a crashed run
replays instead of re-executing (`shikigami-core/src/Shikigami/Agent/Workflow.hs`).
The worker (`shikigami-core/src/Shikigami/Worker.hs`) runs four loops: the pgmq queue
drainer, a **resume worker** that re-drives parked workflows
(`runResumeWorker`, lines 86-101), an outbox publisher, and a timer worker.

Key vocabulary:

- An **awakeable** is keiro's durable promise: `awakeableNamed` allocates an id inside
  a workflow and returns an await action; the workflow suspends until some external
  caller invokes `signalAwakeable` with a payload, which appends a journal entry so the
  next resume pass completes the await. `AwakeableId` is a UUID newtype
  (`/Users/shinzui/Keikaku/bokuno/keiro/keiro/src/Keiro/Workflow/Awakeable.hs:119`).
- **Approval machinery** (`shikigami-core/src/Shikigami/Agent/Approval.hs`):
  `awaitApproval env stepName request deadline` allocates an awakeable, runs a
  journaled `<stepName>:notify` step that calls `recordPark` and `postAsk`, optionally
  arms a deadline timer whose `TimerId` is a deterministic UUIDv5 over
  workflow-name/id/generation/step (`Approval.hs:174-180`) so replays cannot arm
  duplicates, then awaits. The timer's fire action (`approvalTimeoutFireAction`,
  `Approval.hs:124-142`) signals `TimedOut`. `resolveApproval appEnv aid decision`
  (`Approval.hs:117-122`) is the external completion: it signals the awakeable and
  returns whether anything was resolved.
- **Where approval is consulted**: `approveSinks` in `Agent/Workflow.hs:220-246` asks
  `requiresApproval env (AgentIdentity agent) kind output` per declared sink; on
  `ApprovalRequired` it parks via `awaitApproval` under the journaled step name
  `approval:<SinkKindText>:<ordinal>`; `Rejected`/`TimedOut` drop the sink,
  `Approved` keeps it. Flows park through the same machinery via
  `awaitAcknowledgement` (`shikigami-core/src/Shikigami/Flow/Acknowledgement.hs:22-30`)
  with the deadline defaulting to 900 seconds (`Agent/Workflow.hs:312-314`).
- **The stub being replaced**: `defaultApprovalEnv` (`Approval.hs:91-98`) answers
  `ApprovalNotRequired` always and no-ops `recordPark`/`postAsk`. The worker installs
  it at `Worker.hs:204` and sets `deadline = Nothing` at `Worker.hs:205`.
- **ApprovalEnv** (`Approval.hs:84-89`) is the seam this plan fills:

```haskell
data ApprovalEnv = ApprovalEnv
  { currentSession :: !SessionId,
    requiresApproval :: !(AgentIdentity -> SinkKind -> Value -> IO ApprovalRequirement),
    recordPark :: !(SessionId -> AwakeableId -> ApprovalRequest -> IO ()),
    postAsk :: !(ApprovalChannel -> ApprovalRequest -> AwakeableId -> IO ())
  }
```

- **Sink clients available for notification**: danwa (a conversation service; client in
  `shikigami-core/src/Shikigami/Sink/Danwa.hs`, config `DanwaConfig { baseUrl,
  agentParticipant }` in `Sink/Config.hs`) and kizashi (a signal/notification service;
  `postSignal :: KizashiConfig -> CreateSignalReq -> IO (Either Text SignalResponse)`
  in `Sink/KizashiClient.hs:57-65`, request DTO in `Sink/Wire.hs:56-67`).
- **SinkKind** names for the policy variable: `KawaDigest`, `KizashiSignal`,
  `ReiAction`, `DanwaConversation`, `ChannelEgress` — the `sinkKindText` renderings in
  `shikigami-core/src/Shikigami/Sink/Permission.hs:43-49`.

The proven tests to imitate: `AgentWorkflowSpec.hs:485-496` builds a test `ApprovalEnv`
whose `recordPark` captures the `AwakeableId` into an `IORef`; the Approval test cases
(lines 337-386) park a run, call `resolveApproval`, then drive
`resumeWorkflowsOnce defaultWorkflowResumeOptions (agentRunRegistry deps)` and assert
the sink outbox row appears exactly once (approve) or never (reject). The Deadline
cases (lines 389-432) fire the timer via `runWorkflowTimerWorker` with
`approvalTimeoutFireAction` and assert an answer that arrives first wins.


## Plan of Work

Four milestones: the policy module, the worker wiring, the resolution CLI, and the
end-to-end demonstration.

### Milestone 1 — ApprovalPolicy and the notifying ApprovalEnv

Scope: a new module `shikigami-core/src/Shikigami/Agent/Approval/Policy.hs` (add to
`exposed-modules` in `shikigami-core.cabal`). At the end, a policy can be parsed from
the environment and turned into a fully functional `ApprovalEnv` — testable without a
worker.

The policy record and resolver (following plan 13's config idiom — typed record, one
`lookupEnv` resolver returning `Either Text`, loud description function):

```haskell
data ApprovalPolicy = ApprovalPolicy
  { requireFor :: !(Set SinkKind),
    channel :: !ApprovalChannel,
    deadline :: !(Maybe NominalDiffTime)
  }

resolveApprovalPolicy :: IO (Either Text (Maybe ApprovalPolicy))
describeApprovalPolicy :: Maybe ApprovalPolicy -> Text
```

`resolveApprovalPolicy` reads:

- `SHIKIGAMI_APPROVAL_REQUIRE` — comma-separated `sinkKindText` names
  (e.g. `KawaDigest,KizashiSignal`). Unset or empty means `Nothing` (no policy,
  auto-approve). An unknown name is `Left` listing the valid names.
- `SHIKIGAMI_APPROVAL_CHANNEL` — `danwa` (default) or `kizashi`.
- `SHIKIGAMI_APPROVAL_DEADLINE_SECONDS` — optional positive integer; parse failure is
  `Left`.

The env builder:

```haskell
policyApprovalEnv :: ApprovalPolicy -> SinkHttp -> DanwaConfig -> KizashiConfig -> SessionId -> ApprovalEnv
```

with these behaviors:

- `requiresApproval identity kind output`: if `kind` is in `requireFor`, return
  `ApprovalRequired ApprovalRequest { prompt, context = output, channel }` where the
  prompt names the agent and sink kind, e.g.
  `"Agent 'heartbeat' wants to dispatch a KawaDigest sink. Approve?"`. Otherwise
  `ApprovalNotRequired`. Pure decision, IO only for signature compatibility.
- `recordPark sid aid req`: one loud stderr line —
  `[approval] parked session=<sid> token=<uuid> prompt=<prompt>`. The durable record
  of the park already exists (keiro's awakeable row plus the journaled notify step);
  this plan does not add a bespoke table.
- `postAsk channel req aid`: render a human-facing ask that MUST embed the token:

```text
APPROVAL REQUIRED: Agent 'heartbeat' wants to dispatch a KawaDigest sink. Approve?
Context: {"summary":"noop-summary produced a fixed digest","verb":"heartbeat.tick"}
Token: 7f3c9a12-...-uuid
Resolve with: shikigami resolve-approval 7f3c9a12-...-uuid --approve   (or --reject "reason")
```

  For `ViaDanwa`: add a small helper to `shikigami-core/src/Shikigami/Sink/Danwa.hs` —
  `postText :: ClientEnv -> DanwaConfig -> Text -> IO (Either Text Text)` — factored from the
  existing `postToFreshConversation` (lines 59-92: start a `"thread"` conversation as
  `agentParticipant cfg`, join, post the message, return the message id). The existing
  function pattern-matches on the `DanwaConversation` sink variant only to satisfy its
  current caller; the new helper takes the rendered text directly so the approval path
  does not fabricate a fake `Sink` value. Call it as
  `postText (danwaClientEnv sinkHttp) danwaConfig renderedAsk`.
  For `ViaKizashi`: build a `CreateSignalReq` directly (`Sink/Wire.hs:56-67`) with
  `actor` = the agent name from the prompt context, `recipient = defaultRecipient` of
  the `KizashiConfig`, `source = "shinzui/shikigami"`, `signalType = AgentRequest`,
  `priority = High`, `importance = 80`, `intent` = the prompt, and
  `contextTags = ["approval:" <> awakeableIdText aid]`; post with
  `postSignal (kizashiHttp sinkHttp)`.
  In both channels a `Left`/error result is rethrown via
  `ioError . userError` so the journaled notify step fails and is retried on resume
  (see Decision Log).

Tests (new `shikigami-core/test/Shikigami/ApprovalPolicySpec.hs`, registered in
`test/Main.hs`): policy parsing happy/edge cases via `setEnv`/`unsetEnv` (run them in
one sequential test group since the process environment is global), and a pure check
that `requiresApproval` gates by kind. Acceptance: `cabal test all` green.

### Milestone 2 — Wire the policy into the worker

Scope: the production worker consults the policy. `shikigami-core/src/Shikigami/Worker.hs`:
add `approvalPolicy :: !(Maybe ApprovalPolicy)` to `WorkerEnv` (lines 55-63); in
`agentRunDeps` (lines 194-206) replace `approval = Approval.defaultApprovalEnv` and
`deadline = Nothing` with:

```haskell
approval = case approvalPolicy env of
  Nothing -> Approval.defaultApprovalEnv
  Just policy -> Policy.policyApprovalEnv policy (sinkHttp env) (danwa env) (kizashi env),
deadline = Policy.deadline =<< approvalPolicy env
```

In `shikigami-cli/src/Shikigami/Cli/Commands/Worker.hs` (`runWorkerCmd`): call
`resolveApprovalPolicy`; `Left` is fatal (stderr + `exitFailure`, same shape as plan
13's provider errors); log `describeApprovalPolicy` unconditionally:

```text
[shikigami.worker] approval policy: none — all sinks auto-approved
[shikigami.worker] approval policy: require=[KawaDigest] channel=danwa deadline=3600s
```

Note the flow path needs no extra wiring: `runFlowBehavior` already threads
`approval deps sid` and `deadline deps` into the flow runtime
(`Agent/Workflow.hs:299-314`), so a configured policy automatically gives
`awaitAcknowledgement` a real notifier and a real (non-fallback) deadline.

Integration test (extend `AgentWorkflowSpec` or the new spec): start a tiny warp stub
(the test suite already depends on `wai`/`warp`, see the test stanza of
`shikigami-core.cabal`) that records any `POST` it receives and answers the danwa
conversation/message JSON shapes used by `Danwa.Client` (imitate the existing danwa
stub usage in the repo's tests if present; otherwise answer
`{"conversationId":"conv_test"}` / `{"messageId":"msg_test"}` style bodies matching
`Danwa.Conversation.Api.ConversationResponse` and `Danwa.Message.Api.MessageResponse`).
Build deps with `policyApprovalEnv` requiring `SKawaDigest` over the stub's base URL,
run the standard `heartbeat` test agent, and assert: the workflow suspends; the stub
captured exactly one ask whose body contains the awakeable token text; and after
`resolveApproval` + `resumeWorkflowsOnce` the outbox holds one sink row (mirroring
lines 337-363 of the existing spec).

### Milestone 3 — The resolve-approval CLI

Scope: new command module
`shikigami-cli/src/Shikigami/Cli/Commands/ResolveApproval.hs` and registration in
`shikigami-cli/src/Shikigami/Cli.hs` (add a `ResolveApproval` constructor to `Command`,
a `command "resolve-approval" ...` branch to the parser, and a `run` clause).

CLI shape:

```bash
shikigami resolve-approval TOKEN --approve
shikigami resolve-approval TOKEN --reject "not in business hours"
```

Implementation: parse `TOKEN` with `Data.UUID.fromText` (invalid → stderr + exit 1);
wrap as `AwakeableId` (constructor exported, `Keiro.Workflow.Awakeable`); build the
decision — `Approved (object ["approved" .= True, "via" .= ("cli" :: Text)])` or
`Rejected reason`; connect the store exactly as `EnqueueRun` does
(`getEnv "PG_CONNECTION_STRING"`, `withStore (defaultConnectionSettings connStr)`),
build `AppEnv` with `Kioku.App.noopTracer`; call
`resolveApproval appEnv aid decision`. Print `resolved: true` and exit 0 when it
returns `True`; print `resolved: false (unknown or already-resolved token)` and exit 1
on `False`. Note `resolveApproval` only signals the awakeable — the running worker's
resume loop (`runResumeWorker`, polling continuously) picks the workflow up within a
second or two; the CLI does not drive the resume itself.

Test: extend the Milestone 2 integration test to resolve through a helper that goes
through the same token-text round-trip the CLI performs (render the captured
`AwakeableId` with `awakeableIdText`, re-parse with `UUID.fromText`, resolve) so the
string round-trip is covered without spawning a subprocess.

### Milestone 4 — End-to-end demonstration

Scope: no code; a manual transcript proving the loop against a live worker, recorded
into this plan's Surprises & Discoveries when executed. Steps are in Concrete Steps
below. Acceptance: a human at a terminal sees the ask (in the danwa stub log or a real
danwa), resolves it, and watches the worker log the workflow complete and the sink
outbox publish.


## Concrete Steps

All commands from `/Users/shinzui/Keikaku/bokuno/shikigami` inside `nix develop`.

Build and test loop (used after every milestone):

```bash
cabal build all
cabal test all
```

Milestone 1: create `shikigami-core/src/Shikigami/Agent/Approval/Policy.hs`; add the
`postText` helper to `shikigami-core/src/Shikigami/Sink/Danwa.hs`; add
`shikigami-core/test/Shikigami/ApprovalPolicySpec.hs`; register both in the cabal file
and `test/Main.hs`.

Milestone 2: edit `shikigami-core/src/Shikigami/Worker.hs` (WorkerEnv, agentRunDeps)
and `shikigami-cli/src/Shikigami/Cli/Commands/Worker.hs`; extend the integration
tests.

Milestone 3: create `shikigami-cli/src/Shikigami/Cli/Commands/ResolveApproval.hs`;
edit `shikigami-cli/src/Shikigami/Cli.hs`; add the command to
`shikigami-cli/shikigami-cli.cabal` `other-modules` if listed there.

Milestone 4 — end-to-end, three terminals, local database prepared with
`just create-database`:

```bash
# terminal 1 — the worker with an approval policy
export PG_CONNECTION_STRING="host=$PGHOST dbname=$PGDATABASE user=$(id -un)"
export SHIKIGAMI_APPROVAL_REQUIRE=KawaDigest
export SHIKIGAMI_APPROVAL_CHANNEL=danwa
export SHIKIGAMI_APPROVAL_DEADLINE_SECONDS=3600
cabal run shikigami -- worker --agents agents/ --danwa-url http://localhost:8080
```

```text
[worker] loaded 4 agents
[shikigami.worker] approval policy: require=[KawaDigest] channel=danwa deadline=3600s
[shikigami.worker] starting; draining shikigami_run_jobs
```

```bash
# terminal 2 — trigger the heartbeat agent (its sink is a KawaDigest)
export PG_CONNECTION_STRING="host=$PGHOST dbname=$PGDATABASE user=$(id -un)"
cabal run shikigami -- enqueue-run heartbeat
```

Terminal 1 then shows the park and the posted ask (via the danwa message, and the
`[approval] parked session=... token=<uuid> ...` line). Copy the token.

```bash
# terminal 3 — resolve
export PG_CONNECTION_STRING="host=$PGHOST dbname=$PGDATABASE user=$(id -un)"
cabal run shikigami -- resolve-approval <token-uuid> --approve
```

```text
resolved: true
```

Within a couple of seconds terminal 1 logs
`[shikigami.worker] agent=heartbeat workflow completed` and the outbox publisher
delivers the digest. Re-running the same `resolve-approval` command prints
`resolved: false (unknown or already-resolved token)` and exits 1 — resolution is
one-shot.

Repeat with `--reject "testing rejection"` on a fresh enqueue: the workflow completes
but no sink outbox row is published (the worker log shows completion without a kawa
POST; `SELECT count(*)` on the outbox, or the test-level assertion, confirms).


## Validation and Acceptance

Automated: `cabal test all` must stay green, including (a) the existing Approval and
Deadline groups in `AgentWorkflowSpec.hs:335-432`, byte-for-byte untouched — this plan
must not alter `awaitApproval`, `resolveApproval`, the `approval:<kind>:<ordinal>` and
`:notify` step names, or the timer id derivation; (b) new `ApprovalPolicySpec` parsing
cases; (c) the new integration case asserting the danwa-stub-captured ask body contains
the awakeable token and that approve→one outbox row / reject→zero rows.

Manual acceptance is Milestone 4's transcript: enqueue → park with visible ask
containing a token → CLI approve → resume → sink dispatched exactly once; and the
reject and timeout variants (for timeout, set
`SHIKIGAMI_APPROVAL_DEADLINE_SECONDS=5`, enqueue, do not resolve, and observe the
worker's timer loop fire the timeout and the run complete with the sink suppressed).

Failure-mode checks: `SHIKIGAMI_APPROVAL_REQUIRE=Bogus` makes the worker exit 1 naming
the valid kinds; killing danwa (wrong `--danwa-url`) makes the notify step fail and the
run retry rather than silently proceeding — visible as repeated
`[shikigami.worker] ... (retry)` lines, never a completed run with an undelivered ask.


## Idempotence and Recovery

The notify step is journaled: a crash after posting but before journaling re-posts the
ask on resume (at-least-once; a duplicate ask is annoying but safe, and both asks carry
the same token because `awakeableNamed` is replay-stable for the same step). The
deadline timer is deterministic (UUIDv5 over workflow identity + step,
`Approval.hs:174-180`), so replays cannot arm duplicates. `resolveApproval` is
one-shot; re-running the CLI is safe and reports `false`. All code changes are additive
(new module, new command, two record fields); rollback is `git checkout` of the touched
files. No migration is involved.


## Interfaces and Dependencies

New interfaces (module paths are repository-relative):

```haskell
-- shikigami-core/src/Shikigami/Agent/Approval/Policy.hs (new)
data ApprovalPolicy = ApprovalPolicy
  { requireFor :: !(Data.Set.Set Shikigami.Sink.Permission.SinkKind),
    channel :: !Shikigami.Agent.Approval.ApprovalChannel,
    deadline :: !(Maybe Data.Time.NominalDiffTime)
  }
resolveApprovalPolicy :: IO (Either Data.Text.Text (Maybe ApprovalPolicy))
describeApprovalPolicy :: Maybe ApprovalPolicy -> Data.Text.Text
policyApprovalEnv ::
  ApprovalPolicy ->
  Shikigami.Sink.Auth.SinkHttp ->
  Shikigami.Sink.Config.DanwaConfig ->
  Shikigami.Sink.Config.KizashiConfig ->
  Kioku.Id.SessionId ->
  Shikigami.Agent.Approval.ApprovalEnv

-- shikigami-core/src/Shikigami/Sink/Danwa.hs (added helper)
postText :: Servant.Client.ClientEnv -> Shikigami.Sink.Config.DanwaConfig -> Data.Text.Text -> IO (Either Data.Text.Text Data.Text.Text)

-- shikigami-cli/src/Shikigami/Cli/Commands/ResolveApproval.hs (new)
runResolveApproval :: String -> Bool -> Maybe String -> IO ()   -- token, approve?, reject reason
```

Existing interfaces consumed (all verified in-tree):

```haskell
Shikigami.Agent.Approval.ApprovalEnv (..)                             -- Approval.hs:84-89
Shikigami.Agent.Approval.resolveApproval :: AppEnv -> AwakeableId -> ApprovalDecision -> IO Bool  -- Approval.hs:117
Shikigami.Agent.Approval.ApprovalDecision (Approved | Rejected | TimedOut)                        -- Approval.hs:65-70
Keiro.Workflow.Awakeable.AwakeableId (AwakeableId)                    -- constructor exported, Awakeable.hs:52,119
Keiro.Workflow.Awakeable.awakeableIdText :: AwakeableId -> Text       -- Awakeable.hs:130
Shikigami.Sink.KizashiClient.postSignal :: HttpEnv -> KizashiConfig -> CreateSignalReq -> IO (Either Text SignalResponse)
Shikigami.Sink.Wire.CreateSignalReq (..)                              -- Wire.hs:56-67
Shikigami.Sink.Permission.sinkKindText :: SinkKind -> Text            -- Permission.hs:43-49
Shikigami.Api.Agent.SignalType (AgentRequest)                         -- Api/Agent.hs:21-29
Kioku.App.noopTracer, Kioku.App.AppEnv (..)
Kiroku.Store.Connection (withStore, defaultConnectionSettings)
```

Hard dependency: `docs/plans/22-outbound-authentication-for-sink-clients.md` defines
`SinkHttp`, `HttpEnv`, the authenticated danwa `ClientEnv`, and the final `postSignal`
signature consumed above. Soft dependency: plan 13 defines the typed environment
resolver and loud startup-description convention reused by `resolveApprovalPolicy`.

No new package dependencies: `uuid` (via keiro), `containers`, `danwa-client`, and
`optparse-applicative` (CLI) are already in scope. Coordinate the additive worker-startup
edits with plans 13, 15, and 16; plan 13 also edits `Cli/Commands/Worker.hs`, so keep each
plan's additions in separate, clearly named blocks in `runWorkerCmd`.


## Revision Notes

- 2026-07-22: Removed the nonexistent approval-policy dependency on plan 33 and made
  plan 22 a hard dependency. Approval notifications now consume authenticated
  `SinkHttp` clients instead of introducing an unauthenticated parallel path.
