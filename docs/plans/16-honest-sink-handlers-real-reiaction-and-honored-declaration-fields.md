---
id: 16
slug: honest-sink-handlers-real-reiaction-and-honored-declaration-fields
title: "Honest sink handlers: real ReiAction and honored declaration fields"
kind: exec-plan
created_at: 2026-07-08T20:14:28Z
intention: "intention_01kx1tygnxenvarsw91bjsy19r"
master_plan: "docs/masterplans/2-production-reality-de-stub-the-runtime-behavior-and-integration-path.md"
---

# Honest sink handlers: real ReiAction and honored declaration fields

This ExecPlan is a living document. The sections Progress, Surprises & Discoveries,
Decision Log, and Outcomes & Retrospective must be kept up to date as work proceeds.


## Purpose / Big Picture

Three of shikigami's declared-sink features lie to their operators today.

First, a `ReiAction` sink — "hand this finding to shinzui/rei as an action on an
intention" — is a pure logging no-op that returns a `Stubbed` outcome
(`shikigami-core/src/Shikigami/Sink/ReiAction.hs:16-22`,
`shikigami-core/src/Shikigami/Sink.hs:62`), and the outbox publisher counts anything
non-`Failed` as `PublishSucceeded`
(`shikigami-core/src/Shikigami/Agent/Workflow.hs:581-583`). Findings destined for rei
therefore vanish while every ledger says "delivered."

Second, two declaration fields are silently ignored:
`KizashiSignal.recipientFrom` (a `SubjectOwner | AreaOwner | Actor` routing strategy,
`shikigami-api/src/Shikigami/Api/Agent.hs:35-37,75`) is never read — `buildSignalReq`
uses only `defaultRecipient` (`shikigami-core/src/Shikigami/Sink/KizashiClient.hs:22-45`)
— and `DanwaConversation.topic` is never read
(`shikigami-core/src/Shikigami/Sink/Danwa.hs:24-31`). An operator writing these fields
gets typed, validated Dhall that does nothing.

After this plan: a `ReiAction` dispatch with no rei endpoint configured **fails
loudly** — `PublishFailed`, visible outbox retries, never fake success — and a new
Settei `sinks.rei.base_url` setting enables a real HTTP client when rei grows a callable API (it
has none today; verified below). `recipientFrom = Actor` actually routes the kizashi
signal to the triggering activity's actor; `SubjectOwner`/`AreaOwner` declarations are
rejected at `validate` time unless they carry a `defaultRecipient` (there is no
ownership directory to resolve them against yet), and dispatch logs when it falls back.
`topic` becomes visible: a fresh danwa conversation opens with the declared topic as
the first line of its opening message. Nothing a manifest declares is silently ignored
any more — it is either honored or rejected up front.


## Progress

- [x] (2026-07-31) Prerequisites: plans 36, 37, and 47 complete; sink modules follow the
      six-package boundary and `ReiConfig` comes from the shared Settei application config.
- [x] (2026-07-31) Milestone 1: `sinks.rei.base_url` declared (no default);
      `runReiAction` fails with a message naming the intention and the key when
      unconfigured, and POSTs a `ReiActionReq` carrying the deterministic dedup key when
      configured; `Stubbed` is deprecated and no longer produced. `SinkHonestySpec` covers
      unconfigured, configured, refused, and denied, plus the outcome→outbox mapping on
      both sides.
- [x] (2026-07-31) Milestone 2: `Shikigami.Sink.Recipient` owns strategy resolution and
      precedence; `resolvedRecipient` threaded from both intent builders through
      `SinkIntent`/`SinkContext` into `buildSignalReq`; `Actor` honored; unresolvable
      strategies warn at dispatch. `SinkIntent` encodes with `omitNothingFields`, so the
      pinned pre-upgrade bytes still hold unchanged.
- [x] (2026-07-31) Milestone 3: `topic` opens a fresh danwa conversation;
      `Shikigami.Sink.Validate.sinkDeclarationErrors` refuses a directory strategy with no
      `defaultRecipient` and the `validate` command exits 1 with it; every shipped manifest
      re-validated.
- [ ] Optional live observation (worker + database, watching the outbox retry a real
      ReiAction failure): not performed. The equivalent is asserted in tests — see
      Outcomes.


## Surprises & Discoveries

- Implementation (2026-07-31): **`SinkIntent` is duplicated, and the duplication is a live
  data-loss hazard rather than an aesthetic one.** `Shikigami.Agent.Workflow` and
  `Shikigami.Flow.SinkOutbox` each define their own copy, because the flow module cannot
  import the workflow module without a cycle — and `publishSinkIntent` decodes rows
  enqueued by *both* using the workflow's copy. A field added to one and not the other is
  therefore silently dropped in transit: the flow path would have journaled a resolved
  recipient that the publisher never saw. Adding `resolvedRecipient` to both is the fix
  here; **`Shikigami.WireCompatSpec` now asserts the two encoders produce identical bytes**,
  so the next divergence is a test failure instead of a lost field.
  **Plan 27 inherits this** as a concrete, tested-in-place reason to consolidate.

- Implementation (2026-07-31): **the additive-field change needed `omitNothingFields`, and
  that is a better guarantee than editing the fixture.** `WireCompatSpec` pins the exact
  pre-upgrade bytes of a `SinkIntent`, so adding a `Maybe` field would have changed the
  encoder (aeson emits `"resolvedRecipient":null` by default) and forced the fixture to be
  rewritten — which would have quietly discarded the evidence it exists to preserve.
  Encoding with `omitNothingFields` instead makes an intent that resolved nothing
  *byte-identical* to one written before the field existed. **Any later plan adding a field
  to a journaled or outboxed record should do the same** rather than update the pinned
  bytes.

- Implementation (2026-07-31): **`Shikigami.Agent.Workflow.enqueueSinkIntentStep` is dead
  code.** It is exported and duplicates `Shikigami.Flow.SinkOutbox`'s function, but nothing
  calls it — the flow path uses the SinkOutbox one and the conversation path uses
  `prepareSinkIntent` directly. It was updated in lockstep here rather than deleted,
  because deleting an exported function is a decision for the plan that owns this module's
  shape. **Plan 27 should remove it.**

- Implementation (2026-07-31): the plan's fixture-revalidation loop expects everything
  except `agents/broken.dhall` to pass. **`agents/detectors/schema.dhall` also fails, and
  always did** — it is a retired tombstone documenting the superseded seed schema, and it is
  a record *type* rather than a manifest, so `validate` rejects it on the Dhall annotation
  before any sink check runs. Not a regression and not a sink error; recorded so the next
  person running that loop does not go looking.

  ```text
  OK   agents/triage-note.dhall
  FAIL agents/broken.dhall              (deliberate load-failure fixture)
  FAIL agents/detectors/schema.dhall    (retired tombstone; a record type, not a manifest)
  ```

- Implementation (2026-07-31): the live worker observation in Concrete Steps was **not
  performed** — it needs a migrated database and a scratch manifest, and everything it
  would show is asserted more precisely in tests: that an unconfigured `ReiAction` yields
  `Failed`, and that `Failed` is exactly what leaves an outbox row unpublished. What the
  live run would add is only the visual of the publisher retrying, which is keiro's
  behavior rather than this plan's.


## Decision Log

- Decision: Encode `SinkIntent` with `omitNothingFields` rather than updating the pinned
  pre-upgrade byte fixture.
  Rationale: an intent that resolved no recipient is then byte-identical to one written
  before the field existed, so the existing evidence stays literally true and the additive
  change is provably a non-event on the wire. Rewriting the fixture would have discarded
  the thing it exists to protect. Costs one deliberate encoding choice, documented at both
  copies of the record.
  Date: 2026-07-31
- Decision: Put strategy resolution in a new `Shikigami.Sink.Recipient` rather than in the
  kizashi client or inline in the workflow, and give it the precedence function the client
  calls.
  Rationale: resolution needs the trigger activity (workflow-side) and application needs
  the sink and configs (client-side), so the logic would otherwise be split across two
  modules with the rule written twice. One module owning strategy, precedence, and the
  warning means the agent-run path and the flow path cannot drift, and
  `Shikigami.Sink.Validate` has an obvious neighbour.
  Date: 2026-07-31
- Decision: Assert that the two `SinkIntent` copies encode identically, and export the flow
  path's copy solely to make that possible.
  Rationale: the publisher decodes both with one of the two records, so divergence loses
  data silently. A test is the cheapest thing that turns the next divergence into a build
  failure, and it costs one export documented as test-only. Consolidation remains plan 27's.
  Date: 2026-07-31
- Decision: `ReiAction` fails loudly by default instead of gaining a speculative
  client, with the real client gated behind the Settei `sinks.rei.base_url` setting.
  Rationale: rei (verify with `mori registry show rei --full`; source at
  `/Users/shinzui/Keikaku/bokuno/rei-project/rei`) is a CLI application — packages
  `rei-cli` and `rei-core`, event-sourced over hasql/pgmq — with **no HTTP server**
  (no servant/warp/wai in either cabal file; `http-client` appears only as an outbound
  dependency). There is nothing to call over the network today. Faking success is the
  bug this MasterPlan removes; failing into the outbox's retry/dead-letter path makes
  the gap visible and self-healing the day an endpoint exists. The stable Settei key and
  wire DTO are defined now so enabling the client later is configuration, not surgery;
  no plan-local URL flag is added.
  Date: 2026-07-08
- Decision: Keep the `Stubbed` constructor of `SinkOutcome`
  (`shikigami-core/src/Shikigami/Sink/Types.hs:42-48`) but stop producing it.
  Rationale: `SinkResult` values are journaled (the `dispatch-sinks` step records them,
  `Agent/Workflow.hs:398-401`) and replay decodes them with `FromJSON`
  (`Agent/Workflow.hs:407-410`); deleting the constructor would break replay of
  historical journals. Mark it deprecated in a comment; removal belongs to a future
  journal-migration plan under MasterPlan 5.
  Date: 2026-07-08
- Decision: Resolve `recipientFrom` at intent-build time (inside
  `Agent/Workflow.hs`, where the `RunJob` and its trigger activity are in scope) and
  carry the result as a new optional `resolvedRecipient` field on the journaled
  `SinkIntent`, rather than resolving inside the kizashi client.
  Rationale: the client (`buildSignalReq`) receives only the sink, identity, and
  output — the actor of the triggering activity is simply not available there
  (`KizashiClient.hs:22-45`). The workflow *does* hold the `RunJob` whose
  `triggerPayload` is (or wraps) the `ActivityEnvelope` with `actor.id`
  (`shikigami-api/src/Shikigami/Api/Activity.hs`; the decode-with-synthetic-fallback
  pattern already exists at `Agent/Workflow.hs:324-342`). An `aeson`
  generically-derived `FromJSON` treats a missing `Maybe` field as `Nothing`, so adding
  `resolvedRecipient :: Maybe Text` decodes old outbox/journal rows safely — an
  additive, replay-compatible change (see the compat test in Milestone 2).
  Date: 2026-07-08
- Decision: `SubjectOwner` and `AreaOwner` are *not* resolved at runtime; declarations
  using them must carry `defaultRecipient`, enforced by `validate`, and dispatch logs
  the fallback.
  Rationale: resolving "who owns this subject/area" requires an ownership directory
  that does not exist anywhere in the platform yet (kizashi's C4 contract takes a
  concrete `recipient` string, `Sink/Wire.hs:56-67`). Inventing recipients would be a
  new silent lie. Rejecting at validate time (the option offered by the architecture
  review) is chosen for the unresolvable strategies, while `Actor` — whose data is in
  hand — is implemented. The seed manifest `agents/triage-note.dhall` already declares
  `SubjectOwner` *with* `defaultRecipient = Some "person:nadeem"`, so it stays valid.
  Date: 2026-07-08
- Decision: `topic` is honored as the first line of the opening message of a *fresh*
  danwa conversation (`"[<topic>]"` prefix line), not as a conversation attribute.
  Rationale: danwa's domain has no conversation topic — its own API module says so
  ("there is no @topic@",
  `/Users/shinzui/Keikaku/bokuno/danwa/danwa-api/src/Danwa/Conversation/Api.hs:3`;
  `StartConversationRequest` is `{startedBy, kind, parentConversationId}`, lines
  139-148). The honest choices were reject-at-validate or make it visible in-band;
  in-band is chosen because the field has real declarative value (a human reading the
  thread sees what it is about) and rejecting would break the existing
  `conversationDecl` fixtures. Replies into an existing thread ignore topic by design —
  the thread already has context.
  Date: 2026-07-08


## Outcomes & Retrospective

Complete as of 2026-07-31. Three commits: `038f12c` (ReiAction), `1e90491`
(`recipientFrom`), `5993a06` (`topic` and validation).

**What is no longer a lie.** A `ReiAction` sink reports what happened: with no endpoint it
fails and the outbox row stays claimable, with one it really POSTs. `recipientFrom = Actor`
routes to the triggering activity's actor; the two strategies that need an ownership
directory nobody has either warn at dispatch or are refused at validate time. A
`DanwaConversation`'s `topic` opens the thread it describes. Nothing a manifest declares is
now accepted and discarded.

**The acceptance criteria, and how each was checked.**

1. *No fake success.* `SinkHonestySpec` asserts an unconfigured `ReiAction` yields
   `Failed`, and — separately — that `Failed` is the one outcome that leaves an outbox row
   unpublished. Both halves, because either alone would have missed the original bug.
2. *Real client path.* A warp stub captures the POST and the assertion covers
   `intentionId`, `note`, the output, and the deterministic `sourceEventId`
   (`heartbeat:run-1:0`), which is what lets a retry re-POST an identical body.
3. *`Actor` routing.* Resolution is tested from an envelope, precedence is tested through
   `buildSignalReq`, and the end-to-end case captures a real `CreateSignalReq` whose
   `recipient` is the actor rather than the declared default.
4. *Old rows still decode.* Two ways: a pre-upgrade row decodes with `resolvedRecipient =
   Nothing`, and the pinned pre-upgrade bytes still round-trip **unchanged**, because
   `omitNothingFields` made the addition invisible on the wire.
5. *`topic` visible.* The danwa stub's captured message is `"[support]\nfresh thread text"`
   for a fresh conversation, unprefixed for a reply, and unchanged for an empty topic.
6. *Validation gate.* Six pure cases plus a real CLI run: a manifest with
   `SubjectOwner` and no default exits 1 with the specific error, and every shipped
   manifest was re-validated (see Surprises for the two pre-existing failures).
7. 190 tests across seven suites, `-j1`, including the untouched replay and
   outbox-stability cases.

**Not done:** the optional live worker observation, for the reason in Surprises.

**What this leaves for the plans that follow.** Plan 19 now has truthful failures to manage
rather than fabricated successes, which was this plan's whole contribution to it. Plan 22
gets settled client shapes to wrap with authentication, including `ReiActionReq` and the
`Maybe Text` on `buildSignalReq`. Plan 27 gets a concrete, tested reason to consolidate:
the duplicated `SinkIntent`, its dead-code twin `enqueueSinkIntentStep`, and a byte-equality
test that will fail the moment the two drift again.

**What was harder than the plan expected**, and worth carrying: the additive-field change
looked mechanical and was not, because the field had to reach two separately-defined
records and a pinned byte fixture. The instinct to edit the fixture would have been wrong;
changing the encoder so the fixture stayed true was both less work and a stronger claim.


## Context and Orientation

How a sink dispatch works in this repository
(`/Users/shinzui/Keikaku/bokuno/shikigami`), end to end. When an agent run's behavior
succeeds, the durable workflow journals one `SinkIntent` per granted sink and enqueues
it on keiro's transactional **outbox** (step `dispatch-sinks`,
`shikigami-core/src/Shikigami/Agent/Workflow.hs:386-441`; `SinkIntent` record at lines
96-104). The worker's outbox publisher loop (`Shikigami/Worker.hs:103-112`) later
claims each row and calls `publishSinkIntent` (`Agent/Workflow.hs:561-583`), which
decodes the intent and calls `dispatch` (`shikigami-core/src/Shikigami/Sink.hs:39-47`):
permission gate (`checkGrant`), then the per-variant handler in `runSink`
(`Sink.hs:50-65`). The handler's `SinkOutcome` maps to the outbox verdict at
`Agent/Workflow.hs:581-583`: `Failed → PublishFailed` (keiro retries the row; repeated
failures surface via the publish options' failure ceiling), anything else →
`PublishSucceeded` (row marked published forever).

The dishonest pieces:

- `runSink`'s `ReiAction` branch: `Stubbed <$ runReiActionStub ...` (`Sink.hs:62`);
  `runReiActionStub` logs one line and returns a detail string
  (`Sink/ReiAction.hs:16-22`). `Stubbed` is not `Failed`, so the outbox says
  delivered.
- `buildSignalReq` (`Sink/KizashiClient.hs:22-45`) binds every `KizashiSignal` field
  *except* `recipientFrom`; the recipient is `fromMaybe fallbackRecipient mrec` where
  `fallbackRecipient` is `KizashiConfig.defaultRecipient`
  (`Sink/Config.hs:12-16`).
- `runDanwa` (`Sink/Danwa.hs:24-31`) matches `DanwaConversation {}` without binding
  `topic`; a fresh conversation is started by `postToFreshConversation`
  (lines 59-92) with `kind = "thread"` and the rendered output as the only message.

Supporting types you will touch:

- `SinkContext` (`shikigami-core/src/Shikigami/Sink/Types.hs:29-38`) — per-dispatch
  context handed to handlers; carries identity, run id, ordinal, the three endpoint
  configs, optional danwa target, timestamp.
- `SinkOutcome`/`SinkResult` (`Sink/Types.hs:42-55`) — journaled JSON; see Decision
  Log about `Stubbed`.
- Sink configs (`Sink/Config.hs`) — `KizashiConfig`, `KawaConfig`, `DanwaConfig`;
  constructed in `shikigami-cli/src/Shikigami/Cli/Commands/Worker.hs:39-41` from CLI
  flags declared in `shikigami-cli/src/Shikigami/Cli.hs:139-150`. NOTE: plan 22
  (`docs/plans/22-outbound-authentication-for-sink-clients.md`, MasterPlan 4) will add
  credential fields to this same module — keep this plan's additions to a separate,
  clearly-named record so the merge is trivial.
- HTTP helper: `postJSON` in `shikigami-core/src/Shikigami/Sink/Http.hs` (used by the
  kizashi client) — reuse it for the rei client.
- `validate` CLI: `shikigami-cli/src/Shikigami/Cli/Commands/Validate.hs:15-33` — loads
  a manifest, currently validates only skill directories.
- Trigger activity access pattern: `activityFromJob`
  (`Agent/Workflow.hs:324-328`) decodes `RunJob.triggerPayload` as an
  `ActivityEnvelope`, falling back to a synthetic envelope; `ActivityEnvelope.actor`
  has `Actor { kind, id, session }` (`shikigami-api/src/Shikigami/Api/Activity.hs`).

Terms: the **outbox** is keiro's exactly-once-ish delivery table — rows are enqueued in
the same transaction as the journal append and later claimed/published by a background
loop; a row whose publish fails stays claimable and is retried, so `PublishFailed` is
visible and self-healing rather than lost. **rei** is a personal
intentions/actions/habits system; an "intention" is its goal entity, and `ReiAction`
declares "record this agent finding as an action against intention X".


## Plan of Work

### Milestone 1 — ReiAction stops lying

Scope: after this milestone a `ReiAction` dispatch either really POSTs somewhere or
really fails; the word `Stubbed` no longer appears in fresh journals.

Edits:

- `shikigami-core/src/Shikigami/Sink/Config.hs`: add

```haskell
newtype ReiConfig = ReiConfig
  { baseUrl :: !(Maybe Text)  -- Nothing = no rei endpoint exists/configured
  }
```

- `shikigami-core/src/Shikigami/Sink/Types.hs`: add `rei :: !ReiConfig` to
  `SinkContext`.
- `shikigami-core/src/Shikigami/Sink/Wire.hs`: add the rei command DTO (defined now,
  consumed when rei grows an ingestion endpoint):

```haskell
data ReiActionReq = ReiActionReq
  { intentionId :: !Text,
    note :: !Text,
    output :: !Value,
    sourceEventId :: !Text
  }
```

- Replace `shikigami-core/src/Shikigami/Sink/ReiAction.hs`'s stub with
  `runReiAction :: ReiConfig -> SinkContext -> Sink -> Value -> IO (Either Text Text)`:
  `baseUrl = Nothing` → `Left "ReiAction sink 'intention <id>' not delivered: no rei
  endpoint is configured (rei exposes no callable API yet; configure
  sink.rei.base_url when one exists)"`; `Just url` → `postJSON (url <> "/v1/agent-actions")`
  with a `ReiActionReq` (dedup key from the existing `mkSourceEventId ctx`,
  `Sink/Types.hs:59-61`), mapping transport errors to `Left`.
- `shikigami-core/src/Shikigami/Sink.hs:62`: the branch becomes
  `ReiAction {} -> either Failed Delivered <$> runReiAction (rei ctx) ctx sink output`.
- Wiring: `Worker.WorkerEnv` gains `rei :: !ReiConfig`; `publishSinkIntent`'s
  `SinkContext` construction (`Agent/Workflow.hs:566-579`) and `AgentRunDeps` gain the
  config; declare the setting and its optional legacy binding in plan 37's Settei
  composition root. Tests constructing deps
  (`AgentWorkflowSpec.testDepsWithAgents` etc.) pass `ReiConfig Nothing`.

Tests (new `shikigami-core/test/Shikigami/SinkHonestySpec.hs`): `dispatch` on a
`ReiAction` sink for a granted agent (`heartbeat` has `SReiAction` in the grant table,
`Sink/Permission.hs:55-58`) with `ReiConfig Nothing` yields
`SinkResult SReiAction (Failed ...)`; with a local warp stub as `baseUrl`, yields
`Delivered` and the stub captured a `ReiActionReq` with the right `intentionId` and
dedup key. Assert `publishSinkIntent`-level mapping too: `Failed → PublishFailed`
(construct an `OutboxRow` around an encoded intent, or unit-test the outcome mapping
directly).

Acceptance: `cabal test all` green; running the worker without `sinks.rei.base_url` and
enqueuing an agent with a `ReiAction` sink shows repeated
`[sink]`-failure/outbox-retry lines instead of the old
`[sink] ReiAction stubbed ...` success.

### Milestone 2 — recipientFrom becomes real

Scope: `Actor` routing works; nothing else silently changes.

Edits, upstream to downstream:

- `Agent/Workflow.hs`: add `resolvedRecipient :: !(Maybe Text)` to `SinkIntent`
  (lines 96-104). In `buildSinkIntent` (lines 420-440) and `prepareSinkIntent`
  (lines 475-514), compute it for `KizashiSignal` sinks:

```haskell
resolveRecipient :: RecipientFrom -> Maybe ActivityEnvelope -> Maybe Text
resolveRecipient Actor (Just env) = Just (actorId (actor env))
resolveRecipient _ _ = Nothing   -- SubjectOwner/AreaOwner: no directory yet
```

  using the already-present `activityFromJob`-style decode of the trigger payload
  (`buildSinkIntent` has `job` in scope; `prepareSinkIntent` — the flow path via
  `enqueueSinkIntentStep` — receives no job today, so add a
  `Maybe ActivityEnvelope`/`Maybe Text` parameter threaded from
  `Shikigami.Flow.Capability.runSink`'s `SinkEnv`, which the flow runner builds from
  the job at `Agent/Workflow.hs:316-322`).
- `Sink/Types.hs`: add `recipientOverride :: !(Maybe Text)` to `SinkContext`;
  `publishSinkIntent` copies `resolvedRecipient` into it.
- `Sink/KizashiClient.hs` `buildSignalReq`: recipient precedence becomes
  `recipientOverride ctx` (pass the context or the override into the function —
  today it takes config+sink+identity+output; extend the signature with
  `Maybe Text`), then the sink's `defaultRecipient`, then the config fallback. When
  the sink declares `SubjectOwner`/`AreaOwner` and the override is `Nothing`, emit one
  stderr line: `[sink] KizashiSignal recipientFrom=SubjectOwner is not resolvable
  (no ownership directory); using declared defaultRecipient`.

Compat test (mandatory): decode a raw JSON `SinkIntent` *without* the
`resolvedRecipient` key via `Aeson.eitherDecode` and assert it parses with `Nothing` —
this is what guarantees journaled/outboxed rows written before this plan still replay
(aeson's generic `FromJSON` treats missing `Maybe` fields as optional). Behavior
tests: `buildSignalReq` with an override uses it; `Actor` intent-building resolves the
fixture envelope's `actor.id` (use `fixtures/envelope.json`); `SubjectOwner` falls
back to the declared default.

Acceptance: `cabal test all` green, including untouched replay tests
(`AgentWorkflowSpec.hs:50-114` — the "one stable outbox row" assertions prove the
intent change didn't disturb ids or step recording).

### Milestone 3 — topic honored, unresolvable declarations rejected

Scope: the last silent fields become visible or invalid.

Edits:

- `Sink/Danwa.hs`: bind `topic` in `runDanwa`; `postToFreshConversation` prepends
  `"[" <> topic <> "]\n"` to the message content when topic is non-empty. Replies to
  an existing `DanwaTarget` are unchanged.
- The validation command component in `shikigami-server`: after the existing skill check, validate sinks: for each
  `KizashiSignal` with `recipientFrom` of `SubjectOwner` or `AreaOwner` and
  `defaultRecipient = Nothing`, print
  `validate: sink error: recipientFrom=<strategy> requires defaultRecipient (no
  ownership directory exists to resolve it)` and exit non-zero. Factor the check as a
  pure function `sinkDeclarationErrors :: AgentDecl -> [Text]` in
  `shikigami-core` (new small module or `Shikigami.Sink.Permission` neighbor
  `Shikigami.Sink.Validate`) so tests hit it directly and a future server-side
  validator reuses it.
- Re-validate every fixture: `agents/*.dhall`, `agents/detectors/*.dhall`,
  `agents/proof/*.dhall` must still pass (`triage-note` declares `SubjectOwner` with a
  default — passes by design).

Tests: pure `sinkDeclarationErrors` cases (offending declaration → one error; the
`triage-note` shape → none); a danwa-stub capture asserting the fresh-conversation
opening message starts with `[support]` for the `conversationDecl` fixture topic
(`AgentWorkflowSpec.hs:604-609` shows the fixture uses `topic = "support"`).

Acceptance transcript:

```bash
cabal run shikigami -- validate agents/triage-note.dhall
```

```text
OK: 1 agent parsed.
```

and a deliberately broken manifest (temporary file with `SubjectOwner` and
`defaultRecipient = None Text`) exits 1 with the sink error above.


## Concrete Steps

All from `/Users/shinzui/Keikaku/bokuno/shikigami` in `nix develop`; after each
milestone:

```bash
cabal build all
cabal test all
```

Milestone 1 files: `shikigami-core/src/Shikigami/Sink/Config.hs`,
`Sink/Types.hs`, `Sink/Wire.hs`, `Sink/ReiAction.hs`, `Sink.hs`,
`shikigami-core/src/Shikigami/Worker.hs`,
`shikigami-core/src/Shikigami/Agent/Workflow.hs` (SinkContext construction in
`publishSinkIntent`, `AgentRunDeps`), the worker composition component in
`shikigami-workers`, and the server-owned command dispatcher from plan 36, plus new
`shikigami-core/test/Shikigami/SinkHonestySpec.hs` (+ `test/Main.hs`, cabal). Expect
`AgentWorkflowSpec`'s `testDeps*` helpers to need the extra `ReiConfig Nothing`
field — the compiler will list them.

Milestone 2 files: `Agent/Workflow.hs` (SinkIntent, buildSinkIntent,
prepareSinkIntent, publishSinkIntent), `Flow/Capability.hs` +
`Flow/SinkOutbox.hs` (thread the resolved recipient parameter),
`Sink/Types.hs`, `Sink/KizashiClient.hs`, tests.

Milestone 3 files: `Sink/Danwa.hs`, new `Shikigami/Sink/Validate.hs`, a validation command
component in `shikigami-server`, and tests. Then re-validate fixtures:

```bash
for f in agents/*.dhall agents/detectors/*.dhall agents/proof/*.dhall; do
  cabal run -v0 shikigami -- validate "$f" >/dev/null && echo "OK $f" || echo "FAIL $f"
done
```

Expected: every existing manifest prints `OK` except `agents/broken.dhall`, which is a
deliberate load-failure fixture and must keep failing for its original reason.

Live observation of the loud failure (optional, needs the local database from
`just create-database`): start the worker with a checked Settei config that omits
`sinks.rei.base_url`, then `enqueue-run heartbeat`
(heartbeat is granted `SReiAction`; give it a ReiAction sink in a scratch copy of the
manifest), and watch the outbox publisher log the publish failure on each pass instead
of announcing success once.


## Validation and Acceptance

The plan is accepted when all of the following are observable:

1. No fake success: with no `sinks.rei.base_url` setting, a `ReiAction` dispatch produces
   `SinkResult SReiAction (Failed …)` and `publishSinkIntent` returns `PublishFailed`
   (asserted in `SinkHonestySpec`); the outbox row remains unpublished and is retried
   — verifiable live as repeated publisher log lines, and in tests via
   `Keiro.Outbox.listOutbox` state.
2. Real client path: with `sinks.rei.base_url` pointing at a stub through the worker's
   checked Settei source, the captured POST body is a
   `ReiActionReq` carrying the declared `intentionId`, `note`, the behavior output,
   and the deterministic `sourceEventId` — retries of the same run send the same key.
3. `Actor` routing: an intent built from a job whose trigger payload is
   `fixtures/envelope.json` produces a `CreateSignalReq.recipient` equal to that
   envelope's `actor.id`; `SubjectOwner`/`AreaOwner` fall back to the declared default
   with the logged warning.
4. Old rows still decode: the missing-field `SinkIntent` decode test passes.
5. `topic` visible: the fresh-conversation opening message begins with the declared
   topic in brackets (danwa-stub capture test).
6. Validation gate: a `SubjectOwner`-without-default manifest fails `validate` with
   the specific error; all shipped fixtures still validate.
7. `cabal test all` fully green, including the untouched replay/outbox-stability cases
   in `AgentWorkflowSpec`.


## Idempotence and Recovery

All schema-shaped changes are additive `Maybe` fields on JSON records that are
journaled or outboxed — old rows decode (tested), and new rows written by this code
decode under old code only if a rollback also reverts no consumer, so treat rollback as
all-or-nothing per milestone (`git checkout` of the touched files before any new rows
matter in production; there is no production deployment yet, per the parent
MasterPlan). The rei client uses the existing deterministic `sourceEventId` dedup key,
so outbox retries and workflow replays re-POST the same key and a future rei endpoint
can dedup exactly as kawa's doorway does. `validate` is read-only. Re-running any test
or fixture-validation loop is safe.


## Portfolio Reconciliation (2026-07-30)

This plan hard-depends on plans 36, 37, and 47. It owns truthful handler results only; plan
19 owns terminal/transient outbox accounting and Keiro IR-3 supplies the missing terminal
rejection outcome. Preserve existing decoders until plan 47's SinkIntent and workflow fixtures
prove compatibility.


## Interfaces and Dependencies

New/changed interfaces (repository-relative paths):

```haskell
-- shikigami-core/src/Shikigami/Sink/Config.hs
newtype ReiConfig = ReiConfig { baseUrl :: !(Maybe Data.Text.Text) }

-- shikigami-core/src/Shikigami/Sink/Types.hs
data SinkContext = SinkContext
  { identity :: !AgentIdentity, runId :: !Text, ordinal :: !Int,
    kizashi :: !KizashiConfig, kawa :: !KawaConfig, danwa :: !DanwaConfig,
    rei :: !ReiConfig,
    danwaTarget :: !(Maybe DanwaTarget),
    recipientOverride :: !(Maybe Text),
    occurredAt :: !(Maybe Data.Time.UTCTime)
  }

-- shikigami-core/src/Shikigami/Sink/Wire.hs
data ReiActionReq = ReiActionReq
  { intentionId :: !Text, note :: !Text, output :: !Data.Aeson.Value, sourceEventId :: !Text }

-- shikigami-core/src/Shikigami/Sink/ReiAction.hs
runReiAction :: ReiConfig -> SinkContext -> Shikigami.Api.Agent.Sink -> Data.Aeson.Value -> IO (Either Text Text)

-- shikigami-core/src/Shikigami/Sink/KizashiClient.hs
buildSignalReq :: KizashiConfig -> Maybe Text -> Shikigami.Agent.Decl.Sink -> AgentIdentity -> Data.Aeson.Value -> Either Text CreateSignalReq

-- shikigami-core/src/Shikigami/Sink/Validate.hs (new)
sinkDeclarationErrors :: Shikigami.Agent.Decl.AgentDecl -> [Data.Text.Text]

-- shikigami-core/src/Shikigami/Sink/Recipient.hs (new; not in the original plan)
resolveRecipient :: RecipientFrom -> Maybe ActivityEnvelope -> Maybe Text
resolveSinkRecipient :: Sink -> Maybe ActivityEnvelope -> Maybe Text
recipientFor :: Text -> Maybe Text -> Maybe Text -> Text   -- fallback, resolved, declared
unresolvableRecipientWarning :: Sink -> Maybe Text -> Maybe Text
```

As implemented, `SinkIntent` gained `resolvedRecipient :: Maybe Text` in **both**
`Shikigami.Agent.Workflow` and `Shikigami.Flow.SinkOutbox`, both encoded with
`omitNothingFields`, and `enqueueSinkIntentStep`/`prepareSinkIntent` in both modules take a
`Maybe Text` between `danwaTarget` and `sink`. `Shikigami.Api.Agent` no longer exists —
plan 36 renamed it to `Shikigami.Agent.Decl` (and `Shikigami.Api.Activity` to
`Shikigami.Activity`); the paths above are corrected.

Consumed, verified in-tree interfaces:

```haskell
Shikigami.Sink.Http.postJSON                                   -- existing HTTP helper (kizashi client uses it)
Shikigami.Sink.Types.mkSourceEventId :: SinkContext -> Text     -- Types.hs:59-61 (dedup key)
Shikigami.Api.Agent.Sink (ReiAction { intentionId, note }, KizashiSignal { recipientFrom, defaultRecipient, ... }, DanwaConversation { topic })
Shikigami.Api.Agent.RecipientFrom (SubjectOwner | AreaOwner | Actor)   -- Api/Agent.hs:35-37
Shikigami.Api.Activity.ActivityEnvelope / Actor                 -- actor.id for Actor routing
Keiro.Outbox.PublishOutcome (PublishSucceeded | PublishFailed ...)     -- mapping at Agent/Workflow.hs:581-583
```

External facts this plan depends on (verified 2026-07-08): rei has no HTTP API
(`/Users/shinzui/Keikaku/bokuno/rei-project/rei` — application-type project,
`rei-cli`/`rei-core`, no server packages); danwa conversations have no topic attribute
(`/Users/shinzui/Keikaku/bokuno/danwa/danwa-api/src/Danwa/Conversation/Api.hs:3,139-148`).
Hard dependencies: plans 36 and 37. No new package dependencies. Independent of plans
13/14/15 except for shared additive edits to `WorkerEnv`/`AgentRunDeps` — coordinate merges
mechanically. Cross-MasterPlan notes: plan 22 extends `Sink/Config.hs` with
credentials after this plan's request/client shapes settle (keep `ReiConfig`
self-contained); plan 19 (MasterPlan 3) lands after this plan and owns retry/dead-letter
policy for failed publishes — this plan only makes the failure real.


## Revision Notes

- 2026-07-31: Implemented; all three milestones complete. Two departures from the plan as
  written, both in the Decision Log: strategy resolution lives in a new
  `Shikigami.Sink.Recipient` rather than split between the workflow and the kizashi client,
  and `SinkIntent` encodes with `omitNothingFields` so the pinned pre-upgrade byte fixture
  stayed true instead of being rewritten. Recorded the duplicated `SinkIntent` as a live
  data-loss hazard now guarded by a byte-equality test, the dead
  `Agent.Workflow.enqueueSinkIntentStep`, the pre-existing
  `agents/detectors/schema.dhall` validation failure, and the optional live worker
  observation that was not run. Corrected the stale `Shikigami.Api.*` module paths in
  Interfaces to plan 36's names.

- 2026-07-22: Recorded this plan as the sink-path predecessor of plans 22 and 19.
  Authentication wraps the settled client shapes, and delivery truth consumes the
  settled handler outcomes.
- 2026-07-22: Replaced the plan-local `--rei-url` configuration path with the shared
  Settei application config and made plans 36/37 explicit prerequisites.
