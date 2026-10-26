---
id: 15
slug: expose-declared-agents-and-agent-runs-over-the-public-http-api
title: "Expose declared agents and agent runs over the public HTTP API"
kind: master-plan
created_at: 2026-10-22T02:39:20Z
intention: "intention_01m5gqm5sxeb7bxpd8dsranfy2"
provenance:
  created_by:
    model: "claude-fable-5-1"
    harness: "claude-code"
    at: 2026-10-22T02:39:20Z
  revisions:
    - model: "gpt-6.1-sol"
      harness: "codex-cli"
      at: 2026-10-25T23:18:05Z
      mode: "implement"
      note: "Begin catalog vertical and verify child dependencies"
---

# Expose declared agents and agent runs over the public HTTP API

This MasterPlan is a living document. The sections Progress, Surprises & Discoveries,
Decision Log, and Outcomes & Retrospective must be kept up to date as work proceeds.
If durable project context changes, update or create ADRs in docs/adr/ in the same change.


## Vision & Scope

After this initiative, `shikigami-server` serves a public HTTP API that another service can use
to work with Shikigami entirely across the service boundary. The first such service is
`mori://shinzui/mori`, whose automation reactions need to fire a declared Shikigami agent and
wait for its outcome without sharing a database or a queue with Shikigami. A caller can list the
declared agents and read one agent's declaration summary and lifecycle; request a run for a named
agent with a caller-supplied idempotency key and receive a stable run identifier; follow that
identifier to the run's durable lifecycle (`accepted`, `running`, `succeeded`, `failed`, or
`cancelled`) with a bounded summary or failure reason; and list the runs that were requested for
an agent. Every route beyond the two health probes requires a bearer credential. All of it is
typed on the umbrella `ShikigamiApi` record in `shikigami-api/src/Shikigami/Api.hs`, served by
`shikigami-server`, callable from `shikigami-client`, and described in `docs/api/openapi.json`,
so a route cannot be served without appearing in the document and a client call that does not
match the served route does not compile.

The initiative fulfils two improvement requests:
[IR-8](../improvement-requests/expose-addressed-agent-runs-over-http.md), which asks for an
addressed-run vertical with server-owned idempotency on a caller-supplied key, and
[IR-10](../improvement-requests/expose-agent-run-status-over-http.md), which asks for a typed,
idempotent run-status read over the identifier IR-8 returns. It deliberately goes further than
the two requests, because they are the first domain verticals on an API that so far serves only
health, and the shape they establish is the shape every later vertical will follow: a
Shikigami-owned ledger for the facts the HTTP boundary itself creates, owning-library reads for
the facts keiro and kioku hold, one closed problem catalog, relay keyset pagination for every
list route, and authentication at the vertical mount.

Explicitly excluded from this initiative: cancellation over HTTP (it needs an authorization
model deciding who may stop whose run, and operators already have `shikigami wf cancel` through
the mounted keiro-ops tree described in
[ADR 0021](../adr/0021-operator-verbs-wrap-the-owning-library.md)); requesting a conversation
turn over HTTP (danwa addressed messages arrive as integration events and keep their declared
route per [ADR 0014](../adr/0014-a-run-job-declares-its-route-rather-than-being-guessed.md));
streaming, callbacks, or webhooks (mori polls, by its own decision in
`mori://shinzui/mori/plans/282-track-agent-runs-to-terminal-workflow-outcomes`); runtime-to-runtime
delegation over A2A
([IR-6](../improvement-requests/support-a2a-cross-runtime-agent-interoperability.md) is a
different surface with different semantics); an authorization model that decides which caller
may run which agent (that remains the Kikan contract behind
[ADR 0036](../adr/0036-external-agent-actions-require-fresh-exact-authorization.md); this
initiative authenticates callers and nothing more); the attestation read vertical
(`docs/plans/52-signed-attestation-read-api-and-uc-8-conformance.md` under MasterPlan 10 adds a
sibling field on the same record and is not changed here); and any change on mori's side
(`mori://shinzui/mori/plans/281-invoke-shikigami-agents-from-mori-reactions` and plan 282
consume this contract).


## Decomposition Strategy

The work is split into four child plans, each named for the behaviour a caller gains rather
than for the packages it touches, and each accepted by a live HTTP request against the real
server in addition to in-process tests.

The first child serves the declared-agent catalog (`GET /agents` and `GET /agents/{agentName}`).
It exists for two reasons. Mori needs to validate that a reaction names a real, runnable agent,
and the run-request route needs an authoritative "unknown agent" answer. It is also the plan that
teaches `shikigami-server` to load agent manifests and consult the Meibo lifecycle directory at
boot, which every later vertical depends on; carrying that extension inside the first vertical
that needs it avoids an infrastructure-only plan with no observable behaviour.

The second child authenticates callers with a configured bearer credential at the vertical
mount, renders refusals as the one problem body, publishes the security scheme in the OpenAPI
document, and teaches the client to carry a token. It is independent of the catalog and runs in
parallel with it, but it is a hard prerequisite of the run-request plan: a route that starts
agent runs must never be served unauthenticated at any commit on master.

The third child accepts addressed runs (`POST /agents/{agentName}/runs`), which is IR-8. Its
distinctive artifact is a Shikigami-owned acceptance ledger written in the same database
transaction as the queue send, so that the same caller key never produces a second run and so
that a run exists as a readable resource from the moment it is accepted, before any worker has
drained it.

The fourth child exposes status and history (`GET /agents/{agentName}/runs/{runId}` and
`GET /agents/{agentName}/runs`), which is IR-10. It composes the ledger with the owning-library
reads that `shikigami runs show` already performs and with the existing lifecycle-refusal
evidence, and it closes the one gap in which a run could otherwise stay `accepted` forever by
having the worker record a dead-letter disposition on the ledger.

The principles were: group by caller-visible behaviour; give every shared artifact exactly one
owning plan (see Integration Points); let the two plans that can start immediately run in
parallel; and serialize only where a later plan consumes an artifact the earlier plan defines.

Alternatives considered and rejected. One ExecPlan for IR-8 and IR-10 alone would have left the
agent lookup, the authentication boundary, and the ledger as side effects of a single plan with
no independent acceptance, and would not give mori the catalog read it needs. A separate
"extend the server runtime" plan was rejected as an infrastructure plan with nothing a user can
see. Answering status by reading the run-job queue or its dead-letter queue was rejected: queue
reads are not a supported status model, keiro-pgmq's `readDlq` hides every row it inspects for
thirty seconds, and the receipts model of
[ADR 0022](../adr/0022-the-journal-ends-at-enqueue-and-receipts-own-delivery-truth.md) already
shows how Shikigami owns truth beyond a library boundary. Deferring authentication was rejected
for the reason given above.

ADRs consulted and carried into the children, all by repository-relative path:
[ADR 0011](../adr/0011-defaulted-agent-fields-preserve-journal-codec-compatibility.md) and
[ADR 0012](../adr/0012-a-declared-workflow-body-only-grows-behind-a-patch.md), which are why no
child touches a workflow body under `shikigami-core/src/Shikigami/Agent/` or
`shikigami-core/src/Shikigami/Flow/`;
[ADR 0014](../adr/0014-a-run-job-declares-its-route-rather-than-being-guessed.md), which is why
the HTTP producer sets `AgentWorkflowRoute` explicitly;
[ADR 0020](../adr/0020-readiness-covers-only-what-restarting-can-fix.md), which keeps health
exempt from both the problem-details rule and authentication, and keeps HTTP types out of
`shikigami-core`;
[ADR 0021](../adr/0021-operator-verbs-wrap-the-owning-library.md), which fixes the rule that
Shikigami writes only the join and reads keiro and kioku through exported operations, now
extended from operator verbs to HTTP reads;
[ADR 0022](../adr/0022-the-journal-ends-at-enqueue-and-receipts-own-delivery-truth.md), the
model the acceptance ledger copies;
[ADR 0026](../adr/0026-outbound-sink-credentials-stay-opaque-and-http-policy-lives-at-the-process-boundary.md),
whose opaque `BearerToken` and constant-time comparison the inbound verifier reuses; and
[ADR 0036](../adr/0036-external-agent-actions-require-fresh-exact-authorization.md), which is
why authorization is out of scope here. Across repositories, Keiro's
`mori://shinzui/keiro/okf/adrs/concepts/ADR-28` (operator commands wrap supported library APIs
and respect schema ownership) binds the status read. The fleet API standards the children
follow are `mori://shinzui/haskell-jitsurei/docs/api-servant-routes`,
`mori://shinzui/haskell-jitsurei/docs/api-rfc9457-problem-details`,
`mori://shinzui/haskell-jitsurei/docs/api-relay-pagination`,
`mori://shinzui/haskell-jitsurei/docs/api-openapi-from-types`, and
`mori://shinzui/haskell-jitsurei/docs/api-hurl-integration-testing`, as summarized locally in
`docs/architecture/packages.md` under "The public HTTP API standard".


## Exec-Plan Registry

| # | Title | Path | Hard Deps | Soft Deps | Status |
|---|-------|------|-----------|-----------|--------|
| 1 | Serve the declared-agent catalog over HTTP | docs/plans/88-serve-the-declared-agent-catalog-over-http.md | None | None | Complete |
| 2 | Authenticate public API callers with configured bearer credentials | docs/plans/89-authenticate-public-api-callers-with-configured-bearer-credentials.md | None | EP-1 (its final milestone wraps the `agents` mount, which EP-1 creates) | Complete |
| 3 | Accept addressed agent runs over HTTP with server-owned idempotency | docs/plans/90-accept-addressed-agent-runs-over-http-with-server-owned-idempotency.md | EP-1, EP-2 | None | Complete |
| 4 | Expose agent-run status and history over HTTP | docs/plans/91-expose-agent-run-status-and-history-over-http.md | EP-3 | None | In Progress |

Status values: Not Started, In Progress, Complete, Cancelled.
Hard Deps and Soft Deps reference other rows by their # prefix (e.g., EP-1, EP-3).
A whole-child hard dependency requires that child to be Complete.


## Dependency Graph

EP-1 and EP-2 have no prerequisites and run in parallel. EP-2's dependency on EP-1 is soft:
the combinator, the verifier, the configuration keys, the 401 rendering, the OpenAPI security
scheme, and the client token option are all provable against a test-only protected route in the
server test suite, but EP-2's acceptance includes wrapping the real `agents` mount, so if EP-2
finishes first its last milestone waits for EP-1's mount to exist and is completed then.

EP-3 depends hard on both. From EP-1 it needs the agent catalog and directory handle in
`ServerEnv`, the `AgentName` path-capture instances, the `agent_not_found` problem code, and the
lifecycle view that decides whether an agent is runnable. From EP-2 it needs the `Authenticated`
mount and the `ApiCaller` value its handler records as the requesting principal. Starting EP-3
earlier would mean either serving the mutating route unauthenticated or inventing a second agent
lookup.

EP-4 depends hard on EP-3. It extends the `AgentRunApi` record EP-3 creates, reads the ledger
table and module EP-3 owns, looks runs up by the identifier EP-3 defines, and extends the hurl
file EP-3 adds.

EP-4 additionally needs a reliable source for pre-workflow terminal dispositions.
The current hook cannot observe automatic exhaustion; FRIC-7 records the
reproduction. A callback is one option, not a required API shape. A supported
durable read or retention-aware reconciliation can also supply the fact. The
existing readDlq leases visible rows and omits archived/deleted evidence;
non-destructive PGMQ live/archive reads are still unreleased. Choosing a
reconciliation design would revise this plan's DLQ exclusion. The child remains
In Progress while that case is unfulfilled.

The resulting order is three phases: Phase 1 runs EP-1 and EP-2 together; Phase 2 runs EP-3;
Phase 3 runs EP-4. No milestone interleaving across children is needed.


## Integration Points

1. **The umbrella route record** `shikigami-api/src/Shikigami/Api.hs` (`ShikigamiApi`). EP-1
   adds the field `agents :: mode :- "agents" :> NamedRoutes AgentApi`, with `AgentApi` in
   `shikigami-api/src/Shikigami/Agent/Api.hs` carrying `list` and `show`. EP-2 changes that
   field to `agents :: mode :- Authenticated :> "agents" :> NamedRoutes AgentApi`. EP-3 adds
   `runs :: mode :- Capture "agentName" AgentName :> "runs" :> NamedRoutes AgentRunApi` to
   `AgentApi`, with `AgentRunApi` in `shikigami-api/src/Shikigami/AgentRun/Api.hs` carrying
   `request`; EP-4 adds `list` and `show` to `AgentRunApi`. Plan 52 under MasterPlan 10 adds a
   sibling `attestations` field later and is unaffected. The resulting operations, with the
   operation ids `Shikigami.Api.OpenApi.operationIdFor` derives, are `getAgents`,
   `getAgentsByAgentName`, `postAgentsByAgentNameRuns`, `getAgentsByAgentNameRuns`, and
   `getAgentsByAgentNameRunsByRunId`.

2. **The problem catalog** `Shikigami.Api.Problem.ProblemCode`. Each plan appends constructors
   and never renames or repurposes one. EP-1 adds `AgentNotFound` (`agent_not_found`, 404, not
   retryable, title "Agent not found"). EP-3 adds `AgentNotRunnable` (`agent_not_runnable`, 409,
   not retryable, title "Agent not runnable"), `IdempotencyKeyConflict`
   (`idempotency_key_conflict`, 409, not retryable, title "Idempotency key conflict"), and
   `PayloadTooLarge` (`payload_too_large`, 413, not retryable, title "Payload too large"). EP-4
   adds `RunNotFound` (`run_not_found`, 404, not retryable, title "Run not found"). EP-2 reuses
   `Unauthorized`; every plan reuses `Unavailable` for a directory or store outage and
   `InvalidUrl` for a cursor or capture that does not parse.

3. **`AgentName` as a path capture.** `Shikigami.Agent.Name.AgentName` in `shikigami-core` has
   no HTTP instances. EP-1 defines `FromHttpApiData`, `ToHttpApiData`, and `ToParamSchema` for
   it in `shikigami-api/src/Shikigami/Agent/Api.hs` as documented orphan instances, so that
   `shikigami-core` keeps no HTTP dependency (the reasoning of ADR 0020). EP-3 and EP-4 reuse
   that capture unchanged.

4. **`ServerEnv` and server boot.** `shikigami-server/src/Shikigami/Server/Seam.hs` and
   `shikigami-server/src/Shikigami/Server/Boot.hs`. EP-1 adds `logger`, `catalog ::
   AgentCatalog`, and `directory :: DirectoryHandle`, and makes boot load manifests and start the
   directory. EP-3 adds `pool :: Hasql.Pool.Pool` and makes boot reconcile the run-job queue with
   `Shikigami.Trigger.Enqueue.ensureRunQueue`. EP-2 adds no field; its `AuthHandler` is a
   Servant context entry built in `shikigami-server/src/Shikigami/Server/App.hs`. EP-4 adds
   `readRunStatus`, a closure over the boot-owned KirokuStore for exported workflow
   and session reads. The test
   constructor `newServerEnvWith` grows with each plan, and each plan updates every call site in
   `shikigami-server/test/`.

5. **The agent catalog view** `Shikigami.Agent.Catalog` in `shikigami-core` (EP-1):
   `AgentCatalog` (declarations by name plus the count of manifests that failed to load),
   `catalogFromReport`, `lookupAgent`, and the lifecycle classification `agentLifecycle` that
   joins a declaration to the directory. EP-3 consumes it for the 404 and 409 decisions and for
   the declared principal it passes to identity admission.

6. **The run identity contract** (EP-3 defines, EP-4 and `shikigami runs show` consume). The run
   key of an HTTP-requested run is `RunKey (agentName <> ":http:" <> idempotencyKey)`, built by
   `httpRunKey` in `shikigami-core/src/Shikigami/AgentRun/Ledger.hs`. The public `runId` is the
   keiro workflow id of that key, exactly `(runJobWorkflowId job).unWorkflowId` from
   `shikigami-core/src/Shikigami/Agent/RunJob.hs`, which is the same value the worker logs under
   `run_id`, the sink receipts store, and `shikigami runs show shikigami.agent-run <id>` accepts.
   This is an ADR candidate (see below).

7. **The acceptance ledger** `shikigami.agent_run_requests` and
   `Shikigami.AgentRun.Ledger` (EP-3 owns). Columns: `agent_name`, `idempotency_key`, `run_id`,
   `run_key`, `payload_fingerprint`, `requested_by`, `queue_message_id`, `accepted_at`; primary
   key `(agent_name, idempotency_key)`; unique `(agent_name, run_id)`. Operations:
   `acceptRunRequest` (one transaction: send the run job with
   `Shikigami.Trigger.Enqueue.enqueueRunJobTx`, insert the row, condemn the transaction if the
   row already existed), `lookupRunRequest`, `payloadFingerprint`. EP-4 adds, by an additive
   migration, `disposition` (`accepted` or `dead_lettered`), `disposition_detail`, and
   `disposition_at`, plus `recordDeadLetter` and the keyset listing query. Nothing else may write
   this table.

8. **The `Authenticated` combinator and `ApiCaller`** (EP-2 owns). `Shikigami.Caller.Api` in
   `shikigami-api` defines `type Authenticated = AuthProtect "shikigami-bearer"`,
   `ApiCaller { callerId :: Text }`, and the OpenAPI security scheme; `Shikigami.Caller.Verifier`
   in `shikigami-server` builds the `AuthHandler Request ApiCaller`. EP-3's handler receives the
   `ApiCaller` and writes `callerId` into `requested_by`.

9. **The generated OpenAPI artifact and its test.** Every plan regenerates
   `docs/api/openapi.json` with `cabal run shikigami-openapi` in the same commit as its route
   change and updates the exact path and operation-id assertions in
   `shikigami-api/test/Shikigami/Api/OpenApiSpec.hs`. EP-1 restructures those assertions into one
   expected list per vertical so later plans append rather than rewrite.

10. **The documented-equals-served dispatch test**
    `shikigami-server/test/Shikigami/Server/DispatchSpec.hs` hardcodes the two health paths.
    EP-1 generalizes it to substitute a known agent name for captures; EP-3 and EP-4 extend the
    substitution with a known run id.

11. **The hurl suite** under `tests/hurl/`. EP-1 adds `tests/hurl/agents/` (fixture manifests:
    a copy of `agents/heartbeat.dhall`, a disabled agent, and a copy of `agents/broken.dhall`),
    points `tests/hurl/run.sh` at it, and adds `tests/hurl/agents.hurl`. EP-2 makes `run.sh`
    start the server in bearer mode with a generated token, passes it to hurl as the `token`
    variable, adds `tests/hurl/auth.hurl`, and adds the `Authorization` header to every protected
    block in the other files. EP-3 adds `tests/hurl/agent-runs.hurl`; EP-4 extends it. The
    default runner keeps running every file, because its database is disposable; a write against
    it enqueues one message that no worker drains. Whichever of EP-1 and EP-2 lands second
    rebases the header lines.

12. **The client command line** `shikigami-client/src/Shikigami/Client/Command.hs` and its test,
    which pins the exact subcommand list. EP-1 adds `agents list` and `agents show`; EP-2 adds a
    global `--token` option and the `SHIKIGAMI_API_TOKEN` environment fallback; EP-3 adds
    `runs request`; EP-4 adds `runs show`, `runs list`, and `runs wait`.

13. **Configuration** `shikigami-core/src/Shikigami/App/Config.hs` and
    `docs/operations/configuration.md`. EP-2 adds `http.auth.mode`, `http.auth.token`, and
    `http.auth.caller`. EP-1 adds no key but documents that the server role now reads
    `agents.directory`, `agents.strict`, and the `directory.*` keys at boot.

14. **The worker dead-letter hook** (EP-4). One additive, best-effort call in
    `shikigami-workers/src/Shikigami/Agent/RunJob/Worker.hs` (`handleRunJob`) after the outcome
    is known, never inside a workflow body. `docs/workflow-versioning.md` is unaffected; EP-4
    runs `just keiro-gate` to prove it.

15. **Early producer/consumer checks.** Before building the run listing, EP-1 proves that the
    relay-pagination combinator's own pre-handler 400 (`RelayPageError` JSON) reaches the caller
    as `application/problem+json`, because the combinator answers before any handler and the
    problem formatters do not see it. Before building the HTTP route, EP-3 proves with two
    concurrent callers against a real database that the ledger transaction yields exactly one
    queue message and one `accepted` answer. Before adding configuration, EP-2 proves that the
    `AuthProtect` client and OpenAPI instances compile against the `agents` mount.

16. **Improvement-request status.** IR-8 and IR-10 are moved to `accepted` with this MasterPlan
    as `targetPlan` when the plans are created; mori's plan 281 reads that status as its gate.
    EP-3 moves IR-8 to `completed` and EP-4 moves IR-10 to `completed`, each regenerating
    `docs/improvement-requests/index.md` and adding a log entry.

ADR candidates, each created by the plan that establishes the decision and allocated the next
free number at creation time: an acceptance-ledger record (EP-3) covering the ledger as the
HTTP boundary's durable truth, the transactional enqueue, the replay-versus-conflict rule, and
the run identity contract; a status-composition record (EP-4) extending ADR 0021 from operator
verbs to HTTP reads, fixing the derivation precedence, and stating that a store outage is never
rendered as a failed run; and an inbound-authentication record (EP-2) stating that callers are
authenticated by a verifier seam at the server boundary that a Shomei or En issuer later
replaces, that health is exempt, and that authentication is not authorization.


## Progress

EP-1, EP-2 and EP-3 are Complete. EP-4 is In Progress: status/history routes,
wire/schema tests, bidirectional history conformance, client show/list/wait and
operator JSON are implemented. The live suite passes 26 Hurl requests, then boots
a real worker and verifies accepted-to-succeeded execution and the operator join.
Core PostgreSQL validation passes serially; all worker tests pass. The frozen
source closure now includes the four added adapters/snippet dependencies (361
runtime packages); previous package versions and repository pins are unchanged.

The remaining integration gate is automatic retry exhaustion before workflow
creation. Released Keiro dead-letters before invoking the domain handler; the
prescribed receipt hook cannot observe that disposition. The reproduction proves
zero handler calls, one DLQ entry, and Accepted status. EP-4 M1 and full IR-10
acceptance remain open until a reliable disposition source is integrated.
FRIC-7 and ADR 0049 record the evidence and the callback/reconciliation options.
The normal-path checks do not waive this criterion.

Validation uses the existing isolated `.dev/mp13.cabal.project` for the missing
Kikan paths and serial core PostgreSQL execution. ADRs 0046–0049 distill the
implemented catalog, authentication, acceptance and status boundaries.


## Surprises & Discoveries

The planned worker hook covers explicit Dead outcomes only. Automatic retry
exhaustion bypasses the domain handler in Keiro 0.18; the latest released 0.21
Job API likewise has no callback. This does not rule out later inspection:
readDlq exposes the outcome while its row is visible and retained. A reliable
reconciler needs evidence retention and coordination with redrive/purge; the
non-destructive PGMQ inspection additions are not released yet. The previous
callback-only prerequisite was too strong. FRIC-7 carries the real drain
reproduction; IR-10 remains in-progress. ADR 0049 records the API investigation.

Keiro owner reads require the existing KirokuStore handle; EP-4 captures it in a
server reader seam instead of implementing an interpreter over a raw pool.
HTTP run keys always take runJobWorkflowId's UUIDv5 fallback because colons are
workflow journal separators. The public ID contract itself is unchanged.


## Decision Log

- Decision: HTTP-originated runs are modelled with a Shikigami-owned acceptance ledger written in
  the same transaction as the queue send, and status is derived by joining that ledger with
  owning-library reads (keiro `lookupInstance` and `loadStepIndex`, kioku `getById`) and the
  existing `shikigami.run_skips` evidence.
  Rationale: between acceptance and drain no keiro row exists, so without a ledger an accepted
  run would be indistinguishable from an unknown one; a ledger insert with the queue send in one
  transaction is also the only place server-side idempotency can be enforced before a second
  message exists. Reading queue or dead-letter rows was rejected because they are not a supported
  status model (ADR 0021, Keiro ADR-28) and `readDlq` hides inspected rows.
  Date: 2026-10-22

- Decision: The public run identifier is the keiro workflow id of the run key
  `<agent>:http:<idempotencyKey>`, computed by the existing `runJobWorkflowId`.
  Rationale: IR-10 requires the identifier to be defined once; this value is already the
  worker's `run_id` log key, the sink receipt key, and the id `runs show` accepts, so the HTTP
  surface introduces no second identity.
  Date: 2026-10-22

- Decision: Idempotency semantics are: a new `(agent, key)` answers 202 Accepted; the same key
  with the same payload fingerprint answers 200 OK with the same body; the same key with a
  different payload answers 409 `idempotency_key_conflict`.
  Rationale: a replay is a success for the retrying caller (mori treats a duplicate as success),
  while a key reused for different work is a caller bug that must not silently return the other
  run. IR-8 leaves the exact status codes to Shikigami.
  Date: 2026-10-22

- Decision: Authentication is its own child plan, runs in parallel with the catalog, and is a
  hard prerequisite of the run-request plan.
  Rationale: a route that starts agent runs must never be served unauthenticated on master, and
  mori's client already plans to carry a bearer token.
  Date: 2026-10-22

- Decision: Authentication is a configured bearer credential behind a verifier seam, with
  authorization out of scope.
  Rationale: IR-8 states that mori will carry whatever authentication Shikigami requires and
  that authorization remains the Kikan contract (ADR 0036); ADR 0026 already records that a
  Shomei-issued token replaces only the credential source, which is the seam this initiative
  keeps.
  Date: 2026-10-22

- Decision: Every list route paginates with relay-pagination, including the in-memory agent
  catalog.
  Rationale: `docs/architecture/packages.md` requires relay keyset pagination for any public list
  endpoint, and the fleet standard notes that retrofitting pagination is a breaking change while
  an unnecessary connection costs one wrapper.
  Date: 2026-10-22

- Decision: The dead-letter closure is a best-effort worker-side ledger disposition, not a
  dead-letter-queue read.
  Rationale: the worker already writes Shikigami-owned refusal evidence at the drain boundary
  (`run_skips`), so a disposition write at the dead-letter boundary is the same pattern; it keeps
  the status read O(1) and off keiro-pgmq's hidden-row semantics.
  Date: 2026-10-22

- Decision: Cancellation, conversation-route runs, streaming, callbacks, and live status in the
  run list are excluded.
  Rationale: cancellation needs an authorization model; conversation turns keep their declared
  event route; mori polls; computing live status for every row of a list would multiply the
  keiro and kioku reads per request. Each exclusion is recorded so a later plan argues against
  it explicitly.
  Date: 2026-10-22

- Decision: New modules follow the concept-first placement rules in
  `docs/architecture/packages.md`: `Shikigami.Agent.Api` and `Shikigami.Agent.Handler`,
  `Shikigami.Agent.Catalog`, `Shikigami.AgentRun.Api`, `Shikigami.AgentRun.Handler`,
  `Shikigami.AgentRun.Ledger`, `Shikigami.AgentRun.Status`, `Shikigami.Caller.Api`, and
  `Shikigami.Caller.Verifier`. The `Shikigami.Server.*` composition allowlist is not extended.
  Rationale: package names express layers and module names express concepts; the health
  vertical (`Shikigami.Health.Api` and `Shikigami.Health.Handler`) is the precedent.
  Date: 2026-10-22


## Outcomes & Retrospective

Three child plans are complete and committed; EP-4's public read surface and normal
execution path are implemented and tested. The final terminal-closure gate remains
open, so the initiative is not complete. Durable context is recorded in ADRs
0046–0049. FRIC-4, FRIC-5 and FRIC-6 are accepted validation workarounds; FRIC-7
is tracked by IR-10. Resume at EP-4 by selecting a reliable owner-supported
disposition source. A durable lookup or retention-aware reconciliation is an
alternative to a callback; the latter option requires revising the existing DLQ
design exclusion. Keep the terminal-closure acceptance unchanged.

Coordination revision 2026-10-25: EP-4 retains its acceptance but now records the
reproduced owner-level terminal-disposition prerequisite and store-reader seam.
