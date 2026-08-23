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

Shikigami can currently publish a kawa digest, a kizashi signal, a rei action, or a danwa
conversation. It cannot act back on the external conversation that caused an agent to run.
The architecture's C12 contract promises that fifth path: a declared `ChannelEgress` sink
sends a reply through Kanmon, which owns the Intercom or Zendesk provider credential and
enforces destination authorization. Shikigami authenticates only to Kanmon and never learns
the provider credential.

After this plan is implemented, an agent can declare:

```dhall
A.Sink.ChannelEgress
  { channel = "intercom"
  , action = "reply_to_conversation"
  , conversationKey = None Text
  }
```

For a granted agent, the existing durable sink-intent publisher will POST the behavior
output to `POST /channels/intercom/actions/reply_to_conversation`. A static declared
conversation key wins; otherwise the key comes from a top-level `conversation_key` in the
behavior output, then from the triggering activity's subject id. The deterministic sink
source-event id becomes Kanmon's idempotency key. The workflow journal continues to say only
that the sink was `Enqueued`; the delivery receipt becomes `Delivered` only after Kanmon
acknowledges the request and retains Kanmon's returned activity id.

The primary proof is hermetic. A Shikigami-owned `stub-kanmon` serves the exact current
Kanmon route and JSON shapes, checks the configured bearer token and destination allow-list,
and deduplicates repeated idempotency keys. Database-backed tests prove granted delivery,
local receipt suppression, downstream idempotency, permanent rejection, and denial without
an outbox row. An optional compatibility check points the same client at Kanmon's offline
host. Switching between the stub and real Kanmon changes only the configured base URL and
opaque token.


## Progress

- [x] (2026-08-23) Re-audited the plan against the current seven-package repository, all
  prerequisite plans, the current workflow-versioning policy, and Kanmon's implemented
  egress contract.
- [x] (2026-08-23) Confirmed prerequisites 19, 21, 22, 27, 36, and the relevant Settei work
  from plan 37 have landed. `SChannelEgress`, database grant commands, delivery receipts,
  terminal rejection, the authenticated bounded HTTP client, and the single durable
  `Shikigami.Sink.Intent.SinkIntent` owner are available to extend.
- [x] (2026-08-23) Milestone 1: added and validated the `ChannelEgress` declaration,
  pinned additive JSON/Dhall compatibility, rejected unsafe channel/action segments and blank
  static conversation keys, and retained an explicit permanent-failure dispatch arm until the
  transport lands.
- [x] (2026-08-23) Milestone 2: added Kanmon wire DTOs, a route-safe authenticated client,
  Settei base-URL and secret-token settings, shared-manager `HttpEnv` wiring, worker CLI and
  diagnostics, and strict process-level dependency plumbing.
- [x] (2026-08-23) Milestone 3: added only resolved conversation and trigger identifiers to
  `SinkIntent`, centralized their preparation for every producer, dispatched through Kanmon,
  retained the acknowledged activity id, and proved replay-neutral workflow behavior.
- [x] (2026-08-23) Milestone 4: added the production-shaped `stub-kanmon` command,
  database-backed end-to-end coverage, hermetic live transcript, and user/operator docs.
  The optional real-Kanmon comparison was not needed for acceptance and remains an
  informative follow-up.
- [ ] Run all focused and full validation, record results here, and distill any durable
  architectural decision that differs from the existing ADRs.


## Surprises & Discoveries

- (2026-08-23) The original plan described prerequisite APIs as future work. They have now
  landed: production grants use `DbGrants`, outbound HTTP uses `TokenSource` and bounded
  `HttpEnv`, publisher outcomes use delivery receipts, and all producers share
  `Shikigami.Sink.Intent`. Evidence: `Shikigami.Sink.GrantStore`,
  `Shikigami.Sink.Http`, `Shikigami.Sink.Delivery`, and `Shikigami.Sink.Intent` in
  `shikigami-core`.

- (2026-08-23) `Sink` is owned by `shikigami-core/src/Shikigami/Agent/Decl.hs`, not by
  `shikigami-api`. The API package is now limited to the public HTTP surface. The production
  stub and administrative CLI belong in `shikigami-server`; worker assembly and the outbox
  publisher belong in `shikigami-workers`.

- (2026-08-23) Kanmon's configured Intercom action is
  `reply_to_conversation`, not the original plan's illustrative `reply`. The implemented
  contract is in `mori://shinzui/kanmon/repos/kanmon`; the relevant project-relative source
  files are `kanmon-core/src/Kanmon/Egress.hs`, `kanmon-core/src/Kanmon/Http.hs`, and
  `instances/intercom-support.dhall`. Mori does not yet define source-file artifact URIs for
  these files, so the canonical repository URI plus project-relative paths are used here.

- (2026-08-23) The workflow synthesizes an `ActivityEnvelope` for an arbitrary CLI payload.
  That synthetic envelope's subject id is the run idempotency key, not a customer
  conversation. A manual proof of the activity-subject fallback must therefore enqueue a
  complete activity envelope, while a raw payload must provide `conversation_key` in the
  behavior output or use a static declaration.

- (2026-08-23) A delivery retry has two independent deduplication layers. Once Shikigami's
  receipt is `Delivered`, republishing the same outbox message performs no HTTP request.
  Kanmon's `(provider, idempotency_key)` store protects the narrower crash window in which
  Kanmon accepted the request but Shikigami did not persist the acknowledgement. These need
  separate tests; a local receipt-suppression test alone does not exercise Kanmon dedup.

- (2026-08-23) `mori path` resolves the canonical Kanmon repository and Haskell record-pattern
  references used here. The current registry does not yet resolve
  `mori://shinzui/keiro/plans/165-add-terminal-outbox-publication-rejection-outcomes`, but
  ADR 0022 and the implemented terminal-outcome comment already pin that canonical URI. The
  registry lag is not a reason to replace it with an ambiguous plan number or checkout path.

- (2026-08-23) `just keiro-gate HEAD` runs `keiro-scaffold`, whose cleanliness assertion is
  a worktree-versus-index `git diff` over all of `shikigami-core/src`, not only generated
  modules. Running it with the implementation unstaged therefore reported the intended source
  edits as a stale generated layer even though every generated module was unchanged. Staging
  the reviewed source first let the same gate classify the change correctly as
  `replay-neutral: stored-data replay is unchanged` and pass conformance.

- (2026-08-23) The long-lived developer database could not be migrated because its recorded
  `mori://shinzui/kioku` migration 0011 checksum predates the currently mounted dependency
  source. The live proof therefore used a freshly migrated, isolated
  `shikigami_channel_egress_proof` database and removed it afterward, leaving the developer
  database untouched. This was environment drift rather than a ChannelEgress failure.


## Decision Log

- Decision: The declaration remains
  `ChannelEgress : { channel : Text, action : Text, conversationKey : Optional Text }`.
  `channel` and `action` are Kanmon route segments; `conversationKey` is an optional static
  destination. Resolution order is a non-empty static key, a non-empty top-level
  `conversation_key` string in behavior output, then the triggering activity's non-empty
  `subject.id`. Missing all three is a permanent construction failure.
  Rationale: this supports both fixed destinations and the primary "reply to what triggered
  me" case without giving Shikigami provider credentials or arbitrary provider APIs.
  Date: 2026-07-08; clarified 2026-08-23.

- Decision: Resolve the conversation key and triggering activity id before enqueue, and add
  only `conversationKey :: Maybe Text` and `triggeringActivityId :: Maybe Text` to the
  durable `SinkIntent` and `SinkContext`. Do not copy the full `ActivityEnvelope` into every
  sink intent.
  Rationale: publication may occur long after the workflow step, so resolved data must be
  durable. Two small values are sufficient, keep outbox rows bounded, and follow the
  existing `resolvedRecipient` precedent. Optional fields are omitted from JSON, preserving
  old non-egress bytes and allowing old intents to decode as `Nothing`.
  Date: 2026-08-23.

- Decision: Derive `content` from the first non-empty top-level `reply`, `content`, or
  `summary` string, falling back to compact JSON for any other output. Set
  `idempotency_key = Just (mkSourceEventId ctx)` and carry the resolved trigger activity id
  as `triggering_activity_id`.
  Rationale: the ordering matches existing behavior-output conventions, always produces the
  required Kanmon content field, and reuses the stable per-sink identity already used by the
  other doorway client.
  Date: 2026-07-08; clarified 2026-08-23.

- Decision: Validate `channel` and `action` at manifest validation time as one non-empty URL
  segment containing only ASCII letters, digits, `.`, `_`, or `-`; reject a declared empty
  conversation key. Re-run the same route validation at publication before constructing the
  path, so corrupted or hand-built durable data fails permanently without issuing a request.
  Rationale: joining arbitrary declaration text into a URL would admit slashes, query text,
  or traversal-like paths. Kanmon's current identifiers and
  `reply_to_conversation` fit this deliberately small vocabulary.
  Date: 2026-08-23.

- Decision: Mirror Kanmon's current wire contract in `Shikigami.Sink.Wire`, and keep
  transport behavior in a new `Shikigami.Sink.KanmonClient`. Use
  `postJSONWithHeaders`; do not introduce a Kanmon-specific manager, retry loop, raw-token
  argument, or generic HTTP helper.
  Rationale: ADR 0026 centralizes authentication, cancellation, body bounds, headers, and
  failure classification in `Shikigami.Sink.Http`. The outbox, not the client, owns retries.
  Date: 2026-07-08; updated 2026-08-23.

- Decision: Extend `SinkCredentials` and `SinkHttp` with direct `kanmon` fields. Configure
  `sinks.kanmon.base_url` and secret `credentials.sinks.kanmon.token` through Settei, with
  explicit environment bindings `SHIKIGAMI_SINKS_KANMON_BASE_URL` and
  `SHIKIGAMI_KANMON_TOKEN`. `KanmonConfig` carries only `baseUrl`.
  Rationale: the opaque, process-lifetime `TokenSource` seam allows a later Shomei-backed
  source without changing declarations, durable data, or the client. Settei's `SecretText`
  provides the current redaction boundary.
  Date: 2026-07-22; corrected from a future credential-reference assumption 2026-08-23.

- Decision: Reuse `HttpFailure` classification. HTTP 408, 425, 429, 5xx and transport
  failures remain retryable; other 4xx, invalid request/URL/response, oversized bodies, and
  response decoding failures are permanent. Failure to read the configured credential
  source remains transient. A locally missing conversation key is permanent.
  Rationale: this is the policy already implemented and tested by plan 22. Retrying a
  deterministic malformed intent cannot heal it, while transient infrastructure may.
  Date: 2026-07-22; updated 2026-08-23.

- Decision: Use the database grant table and `shikigami grants grant`; do not edit
  `defaultGrantTable`.
  Rationale: plan 21 landed `DbGrants`, which production checks on enqueue and publish. A
  grant or revocation is visible on the next check without redeploying the worker.
  Date: 2026-07-08; superseded 2026-08-23.

- Decision: The workflow's `dispatch-sinks` result remains `Enqueued "outbox:..."`.
  Successful publication records `Delivered <kanmon-activity-id>` in the delivery receipt;
  permanent failure records `Dead` and returns Keiro `PublishRejected`; retryable failure
  leaves publication retryable.
  Rationale: ADR 0022 makes the receipt the delivery source of truth and forbids a workflow
  journal from claiming asynchronous delivery.
  Date: 2026-08-23.

- Decision: This change requires no Keiro patch or `continueAsNew`. Still run
  `just keiro-gate HEAD` and retain wire-compatibility tests.
  Rationale: the existing workflow step names, order, declared domain body, and journaled
  `SinkResult` shape do not change. Process dependencies are threaded outside the journal,
  and the new intent metadata is additive, optional, and omitted for existing sinks. The new
  `Sink` constructor is additive; old constructors retain their encodings.
  Date: 2026-08-23.

- Decision: Keep a production-shaped Shikigami `stub-kanmon` for hermetic proofs and run the
  real Kanmon offline host only as an optional compatibility check.
  Rationale: tests must not depend on another checkout or service, but the local mirror
  should periodically be checked against the authoritative implementation. The default
  proof route is `intercom/reply_to_conversation` and response verb is
  `conversation.reply_sent`.
  Date: 2026-07-08; updated 2026-08-23.

- Decision: The stub accepts only `intercom/reply_to_conversation`, authenticates before
  parsing the body, obtains its optional token only from Settei, and keeps an in-memory
  `(channel, idempotency_key)` map plus an accepted-effect count. Its logs contain only the
  accepted/deduplicated classification, route segments, and bounded activity id; its state
  clears on restart.
  Rationale: this is the smallest inspectable mirror that proves the current Kanmon contract,
  crash-window deduplication, and credential boundary without becoming a second general
  egress service or retaining sensitive request data.
  Date: 2026-08-23.


## Outcomes & Retrospective

As of 2026-08-23, Milestone 1 is complete. `ChannelEgress` now exists in the Dhall and
Haskell declaration mirrors, maps to `SChannelEgress`, validates both route segments and a
declared static key, and round-trips through declaration and sink-intent JSON. The proof
manifest prints the expected constructor and validates successfully. The unchanged heartbeat
manifest still validates, and `nix develop --command cabal test shikigami-core-test` passes
all 502 tests, including old `AgentDecl`, `SinkIntent`, and `SinkResult` fixtures. The first
test compile exposed only two test-import omissions; after importing the constructor fields
and `isLeft`, the full core suite passed. The explicit temporary dispatcher result remains a
permanent failure until Milestone 3 replaces it with Kanmon delivery.

Milestone 2 is also complete. `Shikigami.Sink.KanmonClient` now mirrors Kanmon's exact
snake-case request and response, revalidates route segments before I/O, preserves only
allowlisted propagation headers, and uses the configured opaque token through the shared
bounded HTTP transport. `SinkHttp`, `WorkerEnv`, and `AgentRunDeps` carry strict Kanmon
dependencies; Settei exposes `sinks.kanmon.base_url` and the redacted
`credentials.sinks.kanmon.token`, while only the worker exposes `--kanmon-url`. The example
configuration contains no token. `nix develop --command cabal test shikigami-core-test`
passes all 508 tests and `nix develop --command cabal test shikigami-workers-test` passes all
81 tests. `shikigami-worker --describe-config` lists both Kanmon keys without a value, and
`shikigami-worker --check-config` reports `configuration valid` without opening the runtime
database. Milestone 3 will move the already modelled optional egress metadata onto the
durable intent and replace the temporary dispatcher failure with this client.

Milestone 3 is complete. The shared intent-preparation owner now derives egress metadata from
the declared key, behavior output, or actual triggering activity and stores only
`conversationKey` and `triggeringActivityId`; non-egress encodings remain byte-for-byte
unchanged and old rows decode both fields as `Nothing`. Publication builds the Kanmon request,
preserves transient HTTP failures for retry, terminally rejects deterministic failures, and
records the returned Kanmon activity id in the delivered receipt. A second publication of an
already delivered row performs no HTTP request. `nix develop --command cabal test
shikigami-core-test` passes all 514 tests, and staged `just keiro-gate HEAD` reports
replay-neutral compatibility and passes all generated conformance checks without a patch id or
`continueAsNew`.

Milestone 4 is complete. `shikigami stub-kanmon` serves the exact authenticated route with
shared request/response DTOs, fixed destination authorization, RFC problem details for 401,
bounded activity ids, and concurrency-safe in-memory deduplication without retaining or
logging secrets, content, or conversation keys. Server tests cover success, authentication
before parsing, 400/403/404 behavior, idempotent duplicates, and fresh requests without an
idempotency key; command tests pin the flag surface and absence of a token option. The
database-backed core proof covers the complete granted enqueue/publish/receipt path, local
resend suppression, permanent 403 rejection, and denial without an outbox row.

The focused command `nix develop --command cabal test shikigami-core-test
shikigami-server-test shikigami-workers-test` passed: core reported all 516 tests passing,
the server suite including all seven stub contract cases passed, and workers reported all 81
tests passing. The live transcript used the isolated `shikigami_channel_egress_proof`
database: the workflow journaled `Enqueued`, the stub logged one accepted action with no
sensitive fields, and the receipt reached `delivered` with
`act_01m0rb9fbreyxvv18yww8njqj3`. Re-enqueueing `channel-egress-proof-1` replayed the
journaled result and caused no second stub effect. The scratch database was then removed.
The optional real-Kanmon comparison was skipped because the shared wire DTOs, direct upstream
contract inspection through `mori://shinzui/kanmon/repos/kanmon`, production-shaped stub,
and hermetic tests provide the acceptance proof without coupling validation to another
checkout.


## Context and Orientation

Shikigami is a declared-agent runtime. `schema/Agent.dhall` defines the operator-authored
agent schema, and `shikigami-core/src/Shikigami/Agent/Decl.hs` mirrors it in Haskell. A
`Sink` describes one output destination. `Shikigami.Sink.Validate` performs declaration
checks that Dhall's structural type cannot express. The direct field names in this plan
follow `mori://shinzui/haskell-jitsurei/docs/core-record-patterns`: use
`DuplicateRecordFields`, strict fields, explicit deriving, and names such as `baseUrl`,
`kanmon`, `conversationKey`, and `triggeringActivityId`, never type-prefixed alternatives.

Sink delivery is split across two durable phases. Producers call functions in
`shikigami-core/src/Shikigami/Sink/Intent.hs`. That module checks principal lifecycle and
the `(agent, sink kind)` grant, journals an `Enqueued` `SinkResult`, and writes one
`SinkIntent` plus pending delivery receipt transactionally. Agent runs call
`enqueueSinkIntents`; flows and conversation replies call `enqueueSinkIntentStep` or
`prepareSinkIntent`. `SinkIntent` is the single hand-owned wire contract for every producer
and publisher. It uses `omitNothingFields = True`.

The publisher is
`shikigami-workers/src/Shikigami/Flow/SinkOutbox/Publisher.hs`. It decodes the intent and
calls `publishSinkIntent` in `Shikigami.Agent.Workflow`, which constructs a `SinkContext`
and invokes `Shikigami.Sink.dispatch`. The dispatcher checks lifecycle and the current
database grant again, so a principal pause or grant revocation after enqueue prevents the
external effect. A pending receipt allows a send. A delivered receipt suppresses a repeat
send. A downstream acknowledgement records `Delivered` with the returned id; a permanent
failure records `Dead` and maps to Keiro's terminal `PublishRejected`; a transient failure
maps to retryable `PublishFailed`.

`shikigami-core/src/Shikigami/Sink/Http.hs` owns outbound HTTP. `SinkHttp` holds
process-lifetime clients; `HttpEnv` holds a shared manager, optional `TokenSource`, and
request/response byte limits. `postJSONWithHeaders` injects the bearer credential and
content type, permits only the caller's propagation headers, rethrows asynchronous
cancellation, and returns typed `HttpFailure`. Kawa and Kizashi already share a manager;
Kanmon should use that same direct-request client shape. Danwa remains separate because its
generated client owns a dedicated manager.

`shikigami-core/src/Shikigami/App/Config.hs` is the only configuration declaration.
`AppConfig` holds sink base URLs and optional redacted `SecretText` token values. The worker
composition root in
`shikigami-workers/src/Shikigami/Workers/Command/Worker.hs` lowers those values into
`SinkCredentials`, creates `SinkHttp` once, constructs each small sink config record, and
threads them through `WorkerEnv` and `AgentRunDeps`. The worker command preserves named URL
flags as Settei sources. No sink module reads the environment directly.

The administrative executable is owned by `shikigami-server`. Its subcommands include
`validate`, `enqueue-run`, `grants`, and the production `stub-kawa`. A new listener/stub
belongs in this package according to ADR 0003. Core tests cannot import server, so a focused
core delivery test should use a deliberately small test-only WAI application, while server
tests exercise the actual `stub-kanmon` implementation and CLI.

Kanmon is the platform's bidirectional channel runtime. Its canonical repository is
`mori://shinzui/kanmon/repos/kanmon`, and its initial guide is
`mori://shinzui/kanmon/docs/initial-spec`. The authoritative implementation currently has:

- `POST /channels/{channelId}/actions/{action}`;
- request JSON fields `conversation_key` and `content`, plus optional
  `idempotency_key` and `triggering_activity_id`;
- success JSON fields `activity_id` and `verb`;
- 400 for malformed JSON, 401 for failed authentication, 403 for an unauthorized
  conversation, and 404 for an unknown channel or action;
- idempotency by `(provider, idempotency_key)`, returning the original activity id on a
  duplicate; and
- the default Intercom instance action `reply_to_conversation` and success verb
  `conversation.reply_sent`.

The relevant source-file artifact URI shape is still pending Mori coverage. Resolve the
checkout with `mori path mori://shinzui/kanmon/repos/kanmon` and inspect project-relative
`kanmon-core/src/Kanmon/Egress.hs`, `kanmon-core/src/Kanmon/Http.hs`,
`docs/user/http-api.md`, `instances/intercom-support.dhall`, and
`instances/egress-auth.dhall` before implementing or changing the mirror. Do not copy or
import Kanmon's package: Shikigami owns a small local DTO mirror just as it does for Kawa and
Kizashi.

The workflow rules that constrain this work are in `docs/workflow-versioning.md`.
[ADR 0012](../adr/0012-a-declared-workflow-body-only-grows-behind-a-patch.md) governs patches
for declared workflow-body changes;
[ADR 0022](../adr/0022-the-journal-ends-at-enqueue-and-receipts-own-delivery-truth.md) assigns
asynchronous delivery truth to receipts;
[ADR 0026](../adr/0026-outbound-sink-credentials-stay-opaque-and-http-policy-lives-at-the-process-boundary.md)
governs outbound credentials and HTTP;
[ADR 0001](../adr/0001-declare-only-what-the-runtime-executes.md) forbids declaring runtime
mappings that the executable does not use; and
[ADR 0003](../adr/0003-a-seventh-package-keeps-one-off-agent-runs-light.md) fixes package
ownership. This plan does not add a fake Keiro DSL mapping for `SinkIntent`, because it
remains a hand-owned outbox wire type rather than a declared workflow input or result.


## Plan of Work

### Milestone 1 — Declaration, validation, and compatibility

Add a fifth alternative to `Sink` in `schema/Agent.dhall`, after
`DanwaConversation`:

```dhall
| ChannelEgress :
    { channel : Text
    , action : Text
    , conversationKey : Optional Text
    }
```

Add the exact Haskell mirror to `shikigami-core/src/Shikigami/Agent/Decl.hs`:

```haskell
| ChannelEgress
    { channel :: !Text
    , action :: !Text
    , conversationKey :: !(Maybe Text)
    }
```

Extend every total `Sink` match. `sinkKindOf` maps the new constructor to the already
existing `SChannelEgress`. Add a real dispatcher arm only in Milestone 3; while working
incrementally, a temporary explicit `PermanentFailure "ChannelEgress is not wired"` keeps
the match total and prevents false delivery.

Extend `Shikigami.Sink.Validate` with an exported
`validateKanmonRouteSegment :: Text -> Either Text Text`. Both `channel` and
`action` must be non-empty and contain only `[A-Za-z0-9._-]`. A `Some` conversation key must
remain non-empty after stripping whitespace. Report declaration errors with the field name,
following the existing validation style. Add valid and invalid Dhall fixtures or direct
declaration tests covering empty values, a slash, a query marker, and
`reply_to_conversation`. The client must call this same helper again at the durable publish
boundary; startup validation alone is not permission to trust a stored or hand-built intent.

Add constructor JSON round trips and Dhall decode tests. In
`Shikigami.WireCompatSpec`, pin that previously stored `SinkResult`, `AgentDecl`, and old
`SinkIntent` fixtures still decode. Do not change old golden bytes. The additive union arm
must not alter JSON for any existing constructor.

Create `agents/proof/channel-reply.dhall` from a current proof manifest, using the
`noop-summary` Shikumi program, an Event trigger, and:

```dhall
, sinks =
    [ A.Sink.ChannelEgress
        { channel = "intercom"
        , action = "reply_to_conversation"
        , conversationKey = None Text
        }
    ]
```

This milestone is complete when the new proof manifest validates, the invalid declarations
fail for the intended reason, all existing agent fixtures still load, and the compatibility
tests pass.


### Milestone 2 — Wire client, authenticated HTTP, and configuration

Add the shared local DTOs to `shikigami-core/src/Shikigami/Sink/Wire.hs`, using generic
snake-case JSON options:

```haskell
data EgressActionRequest = EgressActionRequest
  { conversationKey :: !Text
  , content :: !Text
  , idempotencyKey :: !(Maybe Text)
  , triggeringActivityId :: !(Maybe Text)
  }

data EgressActionResponse = EgressActionResponse
  { activityId :: !Text
  , verb :: !Text
  }
```

Add `KanmonConfig { baseUrl :: !Text }` to `Shikigami.Sink.Config`. Add
`Shikigami.Sink.KanmonClient` with this public surface:

```haskell
data KanmonError
  = KanmonHttpError !HttpFailure
  | KanmonDecodeError !Text
  | KanmonUsageError !Text

resolveConversationKey :: Sink -> Maybe ActivityEnvelope -> Value -> Maybe Text
buildEgressRequest :: SinkContext -> Value -> Either Text EgressActionRequest
postEgress :: HttpEnv -> KanmonConfig -> Text -> Text -> EgressActionRequest -> IO (Either KanmonError EgressActionResponse)
postEgressWithHeaders :: HttpEnv -> [Header] -> KanmonConfig -> Text -> Text -> EgressActionRequest -> IO (Either KanmonError EgressActionResponse)
renderKanmonError :: KanmonError -> Text
```

`resolveConversationKey` implements the declared/output/activity precedence and ignores
empty candidates. The intent producer will call it while the triggering activity is in
scope. `buildEgressRequest` reads the already resolved `conversationKey` and
`triggeringActivityId` from `SinkContext`, derives content, and sets the deterministic
idempotency key. It returns `Left` rather than throwing if a caller somehow publishes an old
or malformed ChannelEgress intent without a key. `postEgressWithHeaders` calls the existing
`postJSONWithHeaders` and decodes `EgressActionResponse`; `postEgress` supplies no propagation
headers. It revalidates `channel` and `action` with `validateKanmonRouteSegment` before URL
construction; an invalid durable route becomes `KanmonUsageError`. Neither function retries.
`KanmonError` rendering must not include request content, tokens, or response bodies.

Extend `SinkCredentials` with `kanmon :: !(Maybe TokenSource)` and `SinkHttp` with
`kanmon :: !HttpEnv`. `credentialsFromConfig` converts `kanmonToken`; `newSinkHttp` creates
the Kanmon environment on the existing shared manager used by the direct HTTP sinks. Update
constructor sites and tests so a missing token is allowed, a present token produces the
expected authorization header, caller headers cannot override it, trace headers propagate,
and credential lookup failure retains ADR 0026's transient classification.

Extend `Shikigami.App.Config` with direct fields `kanmonBaseUrl :: !Text` and
`kanmonToken :: !(Maybe SecretText)`. Declare:

```text
sinks.kanmon.base_url                    default http://localhost:8090
credentials.sinks.kanmon.token           optional secret, no default
SHIKIGAMI_SINKS_KANMON_BASE_URL           explicit base-URL binding
SHIKIGAMI_KANMON_TOKEN                    explicit secret binding
```

Export the stable keys. Add `--kanmon-url` to only `shikigami-worker`, as a named Settei
source for `sinks.kanmon.base_url`. Extend `AppConfigSpec`, worker help/config tests, secret
redaction tests, `config/shikigami.example.yaml`, and
`docs/operations/configuration.md`. Keep the token out of help, logs, non-secret example
files, and command arguments. The worker's bounded startup log may add only
`"kanmon": "none" | "token"` to the existing credential-presence event.

Construct `KanmonConfig` in `Shikigami.Workers.Command.Worker` and thread it through direct
`kanmon` fields on `WorkerEnv`, `AgentRunDeps`, and `SinkContext`. This is process dependency
wiring, not durable workflow input. Update all strict record constructors; do not make the
dependency optional merely to reduce compiler errors.

This milestone is complete when request/response JSON exactly matches Kanmon, an
authenticated request carries the allowlisted trace headers and configured bearer token,
all config diagnostics show the new public key and redact the secret key, and no client or
command reads an environment variable directly.


### Milestone 3 — Durable intent metadata and dispatch

Extend the one `SinkIntent` in `Shikigami.Sink.Intent` and `SinkContext` with:

```haskell
conversationKey :: !(Maybe Text)
triggeringActivityId :: !(Maybe Text)
```

Keep `sinkIntentOptions = defaultOptions { omitNothingFields = True }`. In
`enqueueSinkIntents`, resolve the values from each sink, the actual activity, and the
behavior output before constructing the intent. Refactor `enqueueSinkIntentStep` and
`prepareSinkIntent` to accept `Maybe ActivityEnvelope` rather than an already-resolved
recipient. Inside the single preparation owner, derive both the existing
`resolvedRecipient` and the new egress metadata. Flow `SinkEnv` passes its current
`activity`; conversation reply code passes `Nothing`. This removes caller-specific intent
preparation and ensures any future producer gets the same precedence.

Add three compatibility assertions to `SinkIntentSpec` and `WireCompatSpec`: an old fixture
decodes both new fields as `Nothing`; encoding a non-egress intent is byte-for-byte unchanged;
and a new ChannelEgress intent round-trips its resolved key and activity id. The full activity
must not appear in encoded intent JSON.

Replace the temporary dispatch arm in `Shikigami.Sink.runSink`. For
`ChannelEgress {channel, action}`, call `buildEgressRequest ctx output`, then
`postEgressWithHeaders (http ctx ^. #kanmon) (traceHeaders ctx) (kanmon ctx) channel action`.
Map success to `Delivered response.activityId`. Map `KanmonHttpError` through the existing
HTTP classifier and both `KanmonDecodeError` and `KanmonUsageError` to
`PermanentFailure`. Map request-construction failure to `PermanentFailure`. Reuse
`classifiedFailure`; do not introduce an overlapping egress failure taxonomy.

Add focused dispatcher tests for request construction, success id retention, trace
propagation, retryable 429/5xx/transport failure, permanent 400/401/403/404 and decode
failure, and a missing resolved conversation key. Logs may include agent, run id, sink kind,
channel, action, status/classification, and downstream activity id. They must not include
content, conversation key, bearer token, or raw bodies.

Before finishing the milestone, review `docs/workflow-versioning.md` against the actual diff.
The intended result has no step-name/order/result or declared workflow-body change, so do not
add a patch id or call `continueAsNew`. Run `just keiro-gate HEAD`; if the implementation
does alter a journaled step shape, stop and revise this plan before bypassing the gate.

This milestone is complete when an enqueued ChannelEgress intent has only the resolved
minimal metadata, the workflow journal says `Enqueued`, successful publication records the
Kanmon activity id in a delivered receipt, and permanent and transient failures reach the
existing publisher outcomes correctly.


### Milestone 4 — Stub, end-to-end proof, and documentation

Add `shikigami-server/src/Shikigami/Sink/KanmonStub.hs` and
`Shikigami.Server.Command.StubKanmon`. The production-shaped stub handles only
`POST /channels/{channel}/actions/{action}` and shares the DTOs in
`Shikigami.Sink.Wire`. A suitable options record is:

```haskell
data StubKanmonOptions = StubKanmonOptions
  { port :: !Int
  , requireToken :: !(Maybe BearerToken)
  , allowedConversations :: !(Set Text)
  }
```

Register `shikigami stub-kanmon --port PORT [--allow-conversation KEY]`. Port and repeated
conversation allow-list values are invocation arguments; the token comes only from
`Config.kanmonToken`. Default the proof allow-list to `conv_55012` when the option is absent,
and accept only the fixed `intercom/reply_to_conversation` route unless the implementation
adds an equally small explicit route allow-list. Authenticate before reading the body.
Return the repository's RFC 9457 401 response for a missing or wrong token, 400 for malformed
JSON, 404 for an unrecognized channel/action, 403 for a conversation outside the allow-list,
and 200 with the exact `EgressActionResponse`.

Maintain an in-memory map keyed by `(channel, idempotency_key)` and an accepted-effect
counter or inspectable log. A duplicate returns the original activity id and does not
increment accepted effects. No idempotency key means a fresh effect, matching Kanmon. Mint
bounded fixture ids and log metadata only; never log content, the conversation key, or a
credential. Document that the in-memory map clears on restart, as does Kanmon's current
offline store.

Server tests exercise the production stub: success shape, authentication before body
parsing, 400, 403, 404, and same-id dedup. Command tests pin registration, `--port`,
`--allow-conversation`, and absence of a token flag. Core tests use a small test-only WAI app
rather than importing `shikigami-server` against the package direction.

Extend the database-backed `Shikigami.SinkDeliverySpec` with one complete agent-run path.
Insert `channel-reply -> SChannelEgress` through `upsertGrant`; do not rely on seed or static
grants. Use a complete `ActivityEnvelope` whose subject id is `conv_55012`. Assert:

1. enqueue journals `Enqueued`, creates one outbox message, and records a pending receipt;
2. first publication makes one HTTP action and records `Delivered` with the response
   activity id;
3. publishing the same row again makes no HTTP request because the local delivered receipt
   is authoritative;
4. two direct posts with the same idempotency key produce one stub-visible accepted effect
   and the same response id, independently proving downstream dedup;
5. a 403 records a dead receipt and maps to `PublishRejected`;
6. an ungranted agent gets `DeniedOutcome`, no outbox row, no receipt, and no HTTP request.

Update `docs/user/sinks.md` with the declaration, resolution precedence, database grant,
delivery-receipt truth, failure classification, and credential boundary. Update the sink
list in `docs/user/writing-agents.md`, the administrative command list in
`docs/operations/operator-cli.md`, the package/command table in
`docs/architecture/packages.md`, the Settei table in
`docs/operations/configuration.md`, and the example YAML. Correct nearby stale claims about
static grants or a workflow result being `Delivered` when encountered in these owned
sections.

This milestone is complete after the hermetic transcript below succeeds and the optional
real-Kanmon check returns the same response shape without code changes.


## Concrete Steps

Run commands from the repository root. Use the Nix development environment so GHC, Cabal,
Dhall, PostgreSQL tools, and `just` match CI. Begin by recording the worktree and baseline:

```bash
git status --short
nix develop --command cabal build all
nix develop --command cabal run shikigami -- validate agents/heartbeat.dhall
```

After Milestone 1, validate both new and existing declarations:

```bash
nix develop --command cabal run shikigami -- validate agents/proof/channel-reply.dhall
nix develop --command cabal run shikigami -- validate agents/heartbeat.dhall
nix develop --command cabal test shikigami-core-test --test-options='--pattern Agent'
```

Expected new shape includes:

```text
ChannelEgress {channel = "intercom", action = "reply_to_conversation", conversationKey = Nothing}
OK: 1 agent parsed.
```

After Milestones 2 and 3, run the focused suites and workflow gate:

```bash
nix develop --command cabal build all
nix develop --command cabal test shikigami-core-test shikigami-workers-test
nix develop --command cabal run shikigami-worker -- --describe-config
nix develop --command cabal run shikigami-worker -- --check-config
nix develop --command just keiro-gate HEAD
```

The described config must contain `sinks.kanmon.base_url` and the secret Kanmon token key
without a value. `--check-config` must not open the database in diagnostic mode. The Keiro
gate should report that no patch is needed; record any different result in Surprises before
proceeding.

After Milestone 4, prepare the local database and grant. The dev-shell connection string is
used by both commands:

```bash
nix develop --command just create-database
nix develop --command cabal run shikigami -- grants grant channel-reply ChannelEgress --by local-proof
nix develop --command cabal run shikigami -- grants list
```

For the live hermetic proof, use the fixture token only in the process environment; do not
put it in a tracked YAML file. Terminal A runs the stub:

```bash
SHIKIGAMI_KANMON_TOKEN=test-token nix develop --command cabal run shikigami -- stub-kanmon --port 8090 --allow-conversation conv_55012
```

Terminal B runs only proof manifests and points the worker at the stub:

```bash
SHIKIGAMI_KANMON_TOKEN=test-token nix develop --command cabal run shikigami-worker -- --agents agents/proof --kanmon-url http://127.0.0.1:8090
```

Terminal C enqueues a complete activity, with a stable run key:

```bash
nix develop --command cabal run shikigami -- enqueue-run channel-reply --key channel-egress-proof-1 --payload '{"activity_id":"act_channel_1","occurred_at":"2026-08-23T12:00:00Z","source":"external/intercom","actor":{"kind":"human","id":"person_42"},"subject":{"type":"conversation","id":"conv_55012"},"verb":"conversation.message_received","payload":{"text":"Could I get an update?"},"context_refs":[],"idempotency_key":"intercom-message-1"}'
```

Terminal A should log one accepted `intercom/reply_to_conversation` effect without content,
conversation key, or token. Terminal B should show an enqueued sink followed by successful
publication. Query Shikigami's own receipt table and verify that its outcome is delivered
with the returned activity id:

```bash
nix develop --command psql postgresql:///shikigami -x -c "SELECT outbox_message_id, run_id, sink_kind, status, detail FROM shikigami.sink_deliveries WHERE agent = 'channel-reply' ORDER BY updated_at DESC LIMIT 1"
```

Re-enqueuing with the same
`--key` must not create a second workflow run; downstream duplicate behavior is proven by
the focused test because local delivered receipts intentionally suppress a second HTTP call.

Run the focused core, server, and worker suites, then the hermetic regression suite
sequentially; the repository's timing-sensitive database tests are more stable at `-j1`:

```bash
nix develop --command cabal test shikigami-core-test shikigami-server-test shikigami-workers-test
nix develop --command cabal test all -j1
```

Optionally check the mirror against real Kanmon. Resolve its checkout through Mori rather
than embedding a machine path:

```bash
kanmon_repo="$(mori path mori://shinzui/kanmon/repos/kanmon)"
cd "$kanmon_repo"
nix develop --command cabal run kanmon -- serve --port 8090
```

Kanmon's offline fixtures currently accept token `test-token`, conversation `conv_55012`,
and action `reply_to_conversation`. Point the same Shikigami worker at that host. A 200
response must decode to the same `{activity_id, verb}` DTO. This compatibility check is
informative and must not make the Shikigami test suite depend on the Kanmon checkout.


## Validation and Acceptance

Acceptance is behavioral and must be demonstrated by tests, not inferred from compilation.

1. A valid `ChannelEgress` declaration loads from Dhall and JSON, maps to
   `SChannelEgress`, and keeps every old declaration and golden encoding unchanged. Unsafe
   or empty channel/action values and an explicitly empty conversation key are rejected at
   validation.

2. For a database-granted agent and an activity whose subject id is `conv_55012`, enqueue
   writes a single intent containing `conversationKey = Just "conv_55012"` and
   `triggeringActivityId = Just "act_channel_1"`; it does not serialize the full activity.
   The workflow's journaled sink outcome is `Enqueued`, never `Delivered`.

3. Publication sends exactly
   `POST /channels/intercom/actions/reply_to_conversation`, preserves allowed trace headers,
   uses the configured opaque bearer token, and encodes:

```json
{
  "conversation_key": "conv_55012",
  "content": "...",
  "idempotency_key": "channel-reply:<runId>:0",
  "triggering_activity_id": "act_channel_1"
}
```

4. A 200 response stores its `activity_id` in a delivered receipt. A subsequent attempt to
   publish that Shikigami outbox row performs zero HTTP requests. Separately, two direct
   requests with the same idempotency key cause one stub-visible accepted effect and return
   the same id, proving Kanmon's crash-window defense.

5. HTTP 400/401/403/404, a malformed success response, and a locally missing conversation
   key become permanent rejection and a dead receipt. HTTP 408/425/429, 5xx, and transport
   failures remain retryable. Credential-source lookup failure remains retryable. No error
   or log contains token, content, conversation key, or raw response body.

6. Without a current database grant, enqueue returns `DeniedOutcome`, creates no outbox row
   or delivery receipt, and sends nothing. Revoking a grant after enqueue prevents publish
   because the publisher checks the database again.

7. `stub-kanmon` enforces auth before parsing, exact routes, destination authorization, JSON
   shape, and dedup. Its CLI exposes no token option. The optional real-Kanmon check requires
   no client or schema change.

8. `cabal build all`, focused core/server/worker tests, `cabal test all -j1`, config
   diagnostics, and `just keiro-gate HEAD` pass. The final Progress and Outcomes sections
   record the exact commands and results.


## Idempotence and Recovery

The implementation is additive and can be applied incrementally. New optional intent fields
decode as `Nothing` for already-enqueued messages and are omitted for old sink kinds. A
temporary explicit permanent-failure dispatcher arm keeps the build honest between the
declaration and transport milestones. Compiler errors from strict dependency records are a
checklist of composition sites; fix every constructor rather than inserting defaults.

Database grant creation is idempotent through `grants grant`/`upsertGrant`. Repeating the
manual enqueue with the same `--key` reuses the durable workflow identity. If a worker
crashes before HTTP, the outbox retries. If it crashes after Kanmon accepts but before the
delivered receipt commits, the stable `agent:runId:ordinal` key lets Kanmon return the first
activity id without repeating the provider effect. Once the receipt is delivered,
Shikigami skips the network call itself.

A rejected or malformed durable intent cannot be repaired by retry and is terminal. To
retry after fixing a declaration, enqueue a new logical run with a new run key. A 429, 5xx,
transport outage, or unavailable credential source stays retryable and needs no manual row
rewrite. The stub's in-memory idempotency state is intentionally ephemeral; restart it only
between proof scenarios, not during a dedup assertion.

Rollback does not require rewriting journals. Stop declaring `ChannelEgress` and revoke the
database grant. The additive schema constructor, optional decoder fields, config keys, and
stub command may remain inert. Do not delete the constructor or optional fields after they
have appeared in durable data; removal would require a separate workflow/wire migration
plan.


## Interfaces and Dependencies

The landed local plans consumed here are:

- `docs/plans/19-sink-delivery-truth-and-downstream-idempotency.md` for delivery truth
  and Keiro terminal rejection;
- `docs/plans/21-database-backed-sink-permission-grants.md` for `DbGrants`, grant storage,
  and administrative verbs;
- `docs/plans/22-outbound-authentication-for-sink-clients.md` for `TokenSource`, `HttpEnv`,
  bounded requests, trace/header policy, and `HttpFailure` classification;
- `docs/plans/27-consolidate-sink-intent-and-run-lifecycle-machinery.md` for the one
  hand-owned durable `SinkIntent` and preparation path;
- `docs/plans/36-align-shikigami-with-the-six-package-deployed-service-architecture.md` plus the current
  package map in `docs/architecture/packages.md` for ownership; and
- `docs/plans/37-adopt-settei-configuration-across-shikigami-binaries.md` for the one typed
  configuration declaration and diagnostic surface.

This plan owns these new or extended local interfaces:

- `schema/Agent.dhall` and `Shikigami.Agent.Decl.Sink` gain the exact additive
  `ChannelEgress` alternative.
- `Shikigami.Sink.Validate` exports `validateKanmonRouteSegment` and validates both route
  segments plus the optional static key; the client reuses the route validator at publish.
- `Shikigami.Sink.Wire` gains `EgressActionRequest` and `EgressActionResponse`.
- `Shikigami.Sink.Config` gains `KanmonConfig {baseUrl :: !Text}`.
- `Shikigami.Sink.KanmonClient` owns resolution, request construction, transport, response
  decoding, and secret-safe errors with the signatures in Milestone 2.
- `SinkCredentials` and `SinkHttp` gain direct `kanmon` fields using the existing opaque
  token and HTTP policies.
- `Shikigami.Sink.Intent.SinkIntent` and `Shikigami.Sink.Types.SinkContext` gain optional
  `conversationKey` and `triggeringActivityId`; the intent preparation functions derive them
  once.
- `WorkerEnv` and `AgentRunDeps` gain strict `kanmon :: !KanmonConfig` process dependencies.
- `Shikigami.App.Config` gains the two stable Kanmon keys and explicit environment bindings;
  `shikigami-worker` gains `--kanmon-url`.
- `Shikigami.Sink` gains the permission mapping and dispatch arm.
- `shikigami-server` gains `StubKanmonOptions`, `stubKanmonApplication`,
  `runStubKanmon`, and the `stub-kanmon` administrative command.

The external wire contract is consumed from `mori://shinzui/kanmon/repos/kanmon`, with the
source-file paths and pending artifact-level URI limitation recorded in Context. No Kanmon
package dependency is introduced. No dependency version bound or compatibility workaround
is selected by this plan; if implementation unexpectedly needs one, use Mori to inspect its
source and docs, then verify the released version against its authoritative registry and
upstream tags before changing bounds.

Existing Keiro outbox and workflow APIs remain unchanged. The durable cross-repository
terminal outcome is documented by
`mori://shinzui/keiro/plans/165-add-terminal-outbox-publication-rejection-outcomes`; use that
canonical reference in any new durable comment or documentation. Follow
`docs/workflow-versioning.md` for any actual workflow-body deviation and never bypass
`just keiro-gate` by inventing an unrelated patch.


## Revision Notes

- 2026-07-22: Made plan 22 a hard dependency and replaced a serializable bearer token, raw
  token CLI option, and duplicate HTTP helper with the planned opaque token and shared HTTP
  seams. Added the package-split and Settei prerequisites and distinguished permanent from
  transient failure.

- 2026-08-23: Comprehensively refreshed the plan against the implemented repository and
  Kanmon contract. Corrected package ownership and the Intercom action, replaced static
  grants with database grant commands, changed delivery acceptance from a false journaled
  `Delivered` claim to receipt-owned truth, consumed the landed authenticated HTTP and
  consolidated intent seams, reduced durable trigger data from a full activity to two
  optional derived fields, added route validation and explicit workflow-versioning analysis,
  separated local receipt suppression from downstream idempotency, converted cross-repo
  paths to canonical Mori references, and made the tests and manual proof executable against
  current commands.
