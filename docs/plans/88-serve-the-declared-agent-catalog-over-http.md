---
id: 88
slug: serve-the-declared-agent-catalog-over-http
title: "Serve the declared-agent catalog over HTTP"
kind: exec-plan
created_at: 2026-10-22T02:39:24Z
intention: "intention_01m5gqm5sxeb7bxpd8dsranfy2"
master_plan: "docs/masterplans/15-expose-declared-agents-and-agent-runs-over-the-public-http-api.md"
provenance:
  created_by:
    model: "claude-fable-5-1"
    harness: "claude-code"
    at: 2026-10-22T02:39:24Z
  revisions:
    - model: "gpt-6.1-sol"
      harness: "codex-cli"
      at: 2026-10-25T23:18:05Z
      mode: "implement"
      note: "Implement declared-agent catalog, typed routes, client and acceptance"
---

# Serve the declared-agent catalog over HTTP

This ExecPlan is a living document. The sections Progress, Surprises & Discoveries,
Decision Log, and Outcomes & Retrospective must be kept up to date as work proceeds.
If durable project context changes, update or create ADRs in docs/adr/ in the same change.

This plan is a child of
`docs/masterplans/15-expose-declared-agents-and-agent-runs-over-the-public-http-api.md`. Read
its Integration Points section before starting; it names the artifacts this plan owns and the
later plans that consume them.


## Purpose / Big Picture

Today `shikigami-server` serves exactly two routes, the health probes, and the only way to learn
which agents a Shikigami deployment declares is the operator command `shikigami agents list`,
which needs a checkout and a database connection string. After this plan a service on the other
side of the network can ask the running server the same question over HTTP: `GET /agents`
returns a relay-paginated page of every declared agent with its enablement, trigger kind,
behavior kind, Meibo lifecycle, and whether it is currently runnable, and
`GET /agents/{agentName}` returns one agent or a typed `agent_not_found` problem. Both routes
are declared on the umbrella `ShikigamiApi` record, so they appear in `docs/api/openapi.json`
and in the derived `shikigami-client`, which gains `agents list` and `agents show`.

You can see it working by starting the server against the development database and running
`shikigami-client agents show heartbeat`, which prints the heartbeat agent's summary, and
`curl -i http://127.0.0.1:8080/agents/no-such-agent`, which answers
`404 application/problem+json` with `"code":"agent_not_found"`.

This plan also makes the server process load agent manifests and consult the Meibo lifecycle
directory at boot. Later plans in the same MasterPlan (the run-request and run-status routes)
rely on that, which is why the server-side extension lives here rather than in a plan of its own.


## Progress

- [x] M1 (2026-10-25; build and HTTP tests pass): The server process loads the declared-agent catalog and starts the lifecycle directory
      at boot; `ServerEnv` carries the logger, the catalog, and the directory handle; a server
      start logs `server.catalog.loaded` with the loaded and failed manifest counts; every
      existing server test still passes with the extended environment.
- [x] M2 (2026-10-25; API wire/schema and live relay conformance pass): `GET /agents` and `GET /agents/{agentName}` are served and documented: the regenerated
      `docs/api/openapi.json` lists both operations; an unknown agent answers a 404 problem with
      code `agent_not_found`; a bad `first` query answers a 400 `application/problem+json`; the
      relay conformance test walks the live route in both directions without skipping or
      duplicating an agent.
- [x] M3 (2026-10-25; 11 Hurl requests and live client list/show pass): `shikigami-client agents list` and `agents show` work against a running server, and
      `just hurl` passes with the new `tests/hurl/agents.hurl` against the fixture catalog in
      `tests/hurl/agents/`.


## Surprises & Discoveries

The released pagination combinator permits zero-sized pages. The public API
requires positive sizes, so the handler rejects zero, while middleware rewrites
the combinator's negative/invalid-size errors. Both paths have HTTP coverage.
`DirectoryRuntime.refresher` already contains the interval loop; boot brackets and
links that action directly instead of introducing a second timer.

Validation uses the existing `.dev/mp13.cabal.project` because the default project
references missing local Kikan packages (FRIC-4). The full PostgreSQL test suite
requires serial execution in this environment (FRIC-5).


## Decision Log

- Decision: The catalog served over HTTP is the server process's own boot-time load of
  `agents.directory`, joined to the lifecycle directory at request time; it is not read from
  the `shikigami.agent_load_state` table the workers persist.
  Rationale: the server is deployed with the same manifests as the workers, and reading a table
  another process writes would make the catalog depend on a worker having started. The in-memory
  catalog answers even when no worker is running, which is exactly when an operator most wants
  to inspect it.
  Date: 2026-10-22

- Decision: `GET /agents` paginates with relay-pagination over the in-memory catalog ordered by
  agent name, rather than returning a plain list.
  Rationale: `docs/architecture/packages.md` requires relay keyset pagination for every public
  list endpoint, and the fleet standard notes that retrofitting pagination is a breaking change.
  The engine over a sorted list is a few dozen lines.
  Date: 2026-10-22

- Decision: The pagination combinator's own 400 is rewritten to problem details by a narrow WAI
  middleware, the same way Servant's empty 405 is rewritten today.
  Rationale: `Relay.Pagination.Servant.RelayPage` validates `first`, `after`, `last`, and
  `before` before any handler runs and answers with its own `RelayPageError` JSON body; the
  Servant error formatters never see it, and the repository rule is that every error body is
  `application/problem+json`.
  Date: 2026-10-22


## Outcomes & Retrospective

Completed 2026-10-25. The server serves and documents the declaration catalog,
including disabled agents and live lifecycle admission. API, server, client, and
all core suites pass; the PostgreSQL suite passes with `--num-threads=1` (225 tests).
The disposable Hurl suite passes 11 requests and runs the typed client list/show
commands against that server. ADR 0046 records the durable catalog boundary.
FRIC-4 and FRIC-5 are accepted environment workarounds; neither requires changing
the HTTP contract. All validation commands use `--project-file=.dev/mp13.cabal.project`;
Hurl accepts `SHIKIGAMI_CABAL_PROJECT` for the same override.


## Context and Orientation

Shikigami is a runtime for *declared agents*: each agent is a Dhall manifest in the directory
named by the `agents.directory` setting (default `agents`, relative to the working directory),
decoded into the `AgentDecl` record in `shikigami-core/src/Shikigami/Agent/Decl.hs`. The loader
in `shikigami-core/src/Shikigami/Agent/Loader.hs` reads every `*.dhall` file in that one
directory (not recursively) and returns an `AgentLoadReport` whose entries are either
`AgentLoaded {path, declaration}` or `AgentLoadFailed {path, error}`. The worker processes call
`loadAgentsLoud` and then `enabledAgentsFromReport` at boot (see
`shikigami-workers/src/Shikigami/Workers/Command/Worker.hs`); `agents.strict` decides whether a
manifest that fails to load stops the process or is only reported.

A declared agent may carry an `identity` with a Meibo *principal id*. The *lifecycle directory*
in `shikigami-core/src/Shikigami/Directory.hs` is an atomically refreshed snapshot of Meibo
principals (`PrincipalRecord {principalId, handle, lifecycle}` with lifecycle `Active`,
`Paused`, or `Deactivated`). `startDirectory logger settings` returns a `DirectoryRuntime` whose
`handle` answers lookups and whose optional `refresher` is an action the composition root must
run periodically; the workers register it as a loop with the interval from
`DirectorySettings.DirectoryFile {refreshInterval}` (see `directoryLoopRegistration` in
`shikigami-workers/src/Shikigami/Workers/Config.hs`). When `directory` is disabled the handle is
`disabledDirectoryHandle` and every lookup returns nothing. `Directory.lookupPrincipal handle
declaredPrincipalId agentName` is the join this plan needs. The operator command in
`shikigami-server/src/Shikigami/Server/Command/Agents.hs` already performs that join for the
terminal; this plan performs the same join for HTTP and must not disagree with it.

The public HTTP API is one Servant *named-routes record*, `ShikigamiApi` in
`shikigami-api/src/Shikigami/Api.hs`: a record whose fields are endpoints, instantiated at
different `mode`s to produce handlers (server), functions (client), and a description
(OpenAPI). Its module comment is the contract: a new vertical is one field of type
`mode :- "segment" :> NamedRoutes SomeApi`, every terminal route is a `MultiVerb` so each
status, media type, and body is in the type, and every error alternative is declared with
`RespondAs ProblemJSON` against the single problem body in
`shikigami-api/src/Shikigami/Api/Problem.hs`. `shikigami-api/src/Shikigami/Health/Api.hs`
re-exports the health vertical from the released `servant-health` package and is the pattern to
copy: a `Respond` list, a handler-side sum, and a hand-written `AsUnion` instance. The server
assembles handlers in `shikigami-server/src/Shikigami/Server/App.hs` (`shikigamiServer`),
reads dependencies from `ServerEnv` in `shikigami-server/src/Shikigami/Server/Seam.hs`, and is
booted by `shikigami-server/src/Shikigami/Server/Boot.hs` (`runServer`, `newServerEnv`,
`newServerEnvWith`). `docs/api/openapi.json` is generated by `cabal run shikigami-openapi` from
the same record and checked for drift by
`shikigami-api/test/Shikigami/Api/OpenApiSpec.hs`.

*Relay cursor pagination* is the fleet's list contract: a route declares
`RelayPage defaultSize maximumSize`, which adds the query parameters `first`, `after`, `last`,
and `before`, validates them before the handler, and hands the handler one `PageRequest`; the
handler returns a `Connection` of edges and page info. The packages are `relay-pagination`
(types and cursor codec), `relay-pagination-servant` (the combinator, its client and OpenAPI
instances), `relay-pagination-hasql` (keyset SQL plus the pure helpers `mkConnection` and
`mintCursor` in `Relay.Pagination.Hasql.Connection`, which work on any list of rows), and
`relay-pagination-conformance` (`Relay.Pagination.Conformance.Tasty.testConformance`, which
walks a live endpoint). All four are pinned at 0.1.1.0 in `cabal.project`; their source is at
`mori://shinzui/relay-pagination` and the standard is
`mori://shinzui/haskell-jitsurei/docs/api-relay-pagination`.

Relevant ADRs. [ADR 0020](../adr/0020-readiness-covers-only-what-restarting-can-fix.md) keeps
HTTP types out of `shikigami-core`, which is why the HTTP instances for `AgentName` live in
`shikigami-api`. [ADR 0021](../adr/0021-operator-verbs-wrap-the-owning-library.md) records that
`agents list` is one of the two verbs Shikigami writes itself because the inventory is
Shikigami's own concept; this plan is the HTTP face of that same inventory.
[ADR 0001](../adr/0001-declare-only-what-the-runtime-executes.md) is the reason the DTO reports
what the runtime will do with a declaration (`runnable`) rather than advertising the declaration
alone. No cross-repository ADR applies beyond the fleet API standards named in the MasterPlan.


## Plan of Work

### Milestone 1: the server knows its agents and their lifecycle

Create `shikigami-core/src/Shikigami/Agent/Catalog.hs`. It owns a small in-memory view:

```haskell
data AgentCatalog = AgentCatalog
  { declarations :: !(Map Text AgentDecl), -- every manifest that loaded, enabled or not
    failedManifests :: !Int
  }

catalogFromReport :: AgentLoadReport -> AgentCatalog
lookupAgent :: AgentCatalog -> AgentName -> Maybe AgentDecl
emptyCatalog :: AgentCatalog

data AgentLifecycleView
  = LifecycleActive | LifecyclePaused | LifecycleDeactivated
  | LifecycleUnknown     -- a directory is configured but holds no matching principal
  | LifecycleUnverified  -- no directory is configured
agentLifecycle :: Bool -> DirectoryHandle -> AgentDecl -> IO AgentLifecycleView
runnable :: AgentDecl -> AgentLifecycleView -> Bool
```

`agentLifecycle configured handle decl` calls `Directory.lookupPrincipal handle (declared
principal id, if any) decl.name`; a found record maps to its lifecycle, an absent record maps
to `LifecycleUnknown` when `configured` is true and `LifecycleUnverified` otherwise. `runnable`
is `decl.enabled` and the lifecycle being `LifecycleActive` or `LifecycleUnverified`; that is
the same admission the worker's drain gate applies, read from
`shikigami-workers/src/Shikigami/Agent/RunJob/Worker.hs` (`admitRunJobWith`), so the HTTP
answer predicts what a run would do. Keep the declared-only catalog: disabled agents stay in it
so the API can say *why* a run would be refused.

Extend `ServerEnv` in `Shikigami.Server.Seam` with `logger :: Log.Logger`, `catalog ::
AgentCatalog`, and `directory :: DirectoryHandle`. In `Shikigami.Server.Boot.runServer`, after
the migrations check and before the store opens: load the report with the same `loadAgentsLoud`
call the workers use (honouring `agents.strict`), build the catalog, log
`server.catalog.loaded` with the loaded and failed counts, and start the directory with
`Directory.startDirectory`. When the runtime returns a `refresher`, run it on the configured
interval in a background thread owned by `runServer` (use `Control.Concurrent.Async.withAsync`
around the Warp loop so the thread dies with the listener; add `async` to the server's
`build-depends`). Update the module comment of `Boot.hs`, which currently says the process
starts nothing in the background: it now runs one cache refresh, and it still runs no queue,
stream, or scheduler loop. Extend `newServerEnvWith` so tests pass `Log.silentLogger`,
`emptyCatalog`, and `disabledDirectoryHandle`, and update every call site in
`shikigami-server/test/`.

Acceptance: the server test suite passes unchanged in behaviour; starting `shikigami-server`
against the development database prints the `server.catalog.loaded` line; `--check-config`,
`--describe-config`, and `--explain-config` still complete without loading manifests (they return
before `runServer`).

### Milestone 2: the two routes, typed end to end

Create `shikigami-api/src/Shikigami/Agent/Api.hs` with the route record and the wire type:

```haskell
data AgentView = AgentView
  { name :: !Text,
    description :: !Text,
    enabled :: !Bool,
    trigger :: !Text,        -- "schedule" | "stream" | "event"
    behavior :: !Text,       -- "deterministic" | "shikumi_program" | "skill" | "flow"
    sinks :: ![Text],        -- "kawa_digest" | "kizashi_signal" | "rei_action"
                             -- | "danwa_conversation" | "channel_egress"
    delegates :: ![Text],
    principalId :: !(Maybe Text),
    lifecycle :: !Text,      -- "active" | "paused" | "deactivated" | "unknown" | "unverified"
    runnable :: !Bool
  }

data AgentApi mode = AgentApi
  { list :: mode :- RelayPage 50 200
                  :> MultiVerb 'GET '[JSON] AgentPageResponses AgentPageResult,
    show :: mode :- Capture "agentName" AgentName
                  :> MultiVerb 'GET '[JSON] AgentShowResponses AgentShowResult
  }
```

`AgentPageResponses` is `Respond 200 "A page of declared agents" (Connection AgentView)`
followed by `RespondAs ProblemJSON 400 "The cursor does not belong to this route"
ProblemDetails` and `RespondAs ProblemJSON 503 "The lifecycle directory is unavailable"
ProblemDetails`; `AgentShowResponses` is `Respond 200 "The declared agent" AgentView`,
`RespondAs ProblemJSON 404 "No such agent" ProblemDetails`, and the same 503. Write the
`AsUnion` instances by hand as `Servant.Health` does. Give `AgentName` its
`FromHttpApiData`, `ToHttpApiData`, and `ToParamSchema` instances in this module with an
`OPTIONS_GHC -Wno-orphans` pragma and a comment saying why (HTTP types stay out of core). Give
`AgentView` a `ToSchema` through `genericDeclareNamedSchema` with the same Aeson options as its
codec, and give `Connection AgentView` and `Cursor` schemas if the relay packages do not already
provide them; `examples/members-server/src/Example/OpenApi.hs` in `mori://shinzui/relay-pagination`
shows what the library expects. Add `AgentNotFound` to `ProblemCode` in
`Shikigami.Api.Problem` with code `agent_not_found`, title "Agent not found", status 404, not
retryable, and make the total catalog functions cover it. Add the field
`agents :: mode :- "agents" :> NamedRoutes AgentApi` to `ShikigamiApi`, and add
`relay-pagination`, `relay-pagination-servant`, `relay-pagination-hasql`, and `http-api-data`
to the api package's `build-depends`.

Create `shikigami-server/src/Shikigami/Agent/Handler.hs` with `agentServer :: ServerEnv ->
AgentApi (AsServerT ServerM)`. The show handler looks the name up in the catalog, answers the
404 arm when absent, otherwise joins the lifecycle and builds the view; a directory failure
answers the 503 arm with `problem Unavailable`. The list handler sorts the catalog by name,
decodes the request's cursor with `Relay.Pagination.Cursor.decodeCursor` and compares its
fingerprint with `sortSpecFingerprint` of a one-column `SortSpec` over the name (a mismatch is
the 400 arm with `problem InvalidUrl`), keeps the rows strictly after the cursor's name for a
forward page or strictly before it for a backward page, over-fetches one row beyond the page
size, and hands the rows to `mkConnection` from `Relay.Pagination.Hasql.Connection`, which mints
each edge's cursor with the same spec. Read that module's comments before relying on how it
treats the extra row; they describe the probe. Wire `agents = agentServer env` into
`shikigamiServer` in `Shikigami.Server.App`.

In `Shikigami.Server.App`, add a narrow middleware beside `methodNotAllowedProblem` that
rewrites a 400 response produced under a paginated path whose content type is not
`application/problem+json` and whose body decodes as `RelayPageError` into
`problemResponse InvalidUrl` carrying the error's `message` as detail. Keep it narrow: it
inspects only status 400 responses, reads at most a few kilobytes of body, and leaves anything
it cannot decode untouched. Record in Surprises & Discoveries if a cleaner hook exists in the
pinned `relay-pagination-servant` release.

Regenerate `docs/api/openapi.json`. In `shikigami-api/test/Shikigami/Api/OpenApiSpec.hs`,
replace the single hardcoded path list with one expected list per vertical (health, agents)
concatenated into the assertion, assert the two new operation ids `getAgents` and
`getAgentsByAgentName`, and validate an encoded `AgentView` against its published schema. Add
`shikigami-api/test/Shikigami/Agent/ApiSpec.hs` that pins the exact JSON bytes of one
`AgentView` and of an empty `Connection AgentView` as literals, in the manner of
`shikigami-core/test/Shikigami/WireCompatSpec.hs`. In `shikigami-server/test/`, add
`Shikigami/Agent/HandlerSpec.hs` covering: a known agent answers 200 with the expected view; an
unknown agent answers 404 `agent_not_found` as problem details; lifecycle is `paused` for a
principal the static directory source marks paused and `unverified` with the disabled handle
(copy the fixture style of `Shikigami/Server/AgentsSpec.hs`); `?first=0` answers 400
`application/problem+json` with code `invalid_url`; and `testConformance` from
`relay-pagination-conformance` walks a seven-agent synthetic catalog with page size three.
Generalize `Shikigami/Server/DispatchSpec.hs` so a documented path with a capture is requested
with a known agent name substituted, and add `agent_not_found` to
`Shikigami/Server/ProblemSpec.hs`.

Acceptance: `cabal test shikigami-api shikigami-server` passes; `git diff --exit-code
docs/api/openapi.json` is clean after regeneration; the live requests in Validation answer as
stated.

### Milestone 3: client, hurl, and documentation

In `shikigami-client/src/Shikigami/Client.hs` export `agentsClient = (.agents)
shikigamiClient`. In `Shikigami/Client/Command.hs` add `agents list [--server URL] [--first N]
[--after CURSOR]`, which prints one line per edge (`name enabled lifecycle runnable`) and the
end cursor, and `agents show NAME [--server URL]`, which prints the view as labelled lines and
exits 1 on a 404. The `RelayPage` combinator's `HasClient` instance takes a `ClientPage`
argument; `noPageArgs` and `forwardPage` are exported for it. Update the client test that pins
the subcommand list. The client package gains `relay-pagination` and
`relay-pagination-servant` dependencies.

Create `tests/hurl/agents/` holding three fixture manifests: a copy of `agents/heartbeat.dhall`,
a `disabled-heartbeat.dhall` that sets `enabled = False`, and a copy of `agents/broken.dhall`.
Point the runner at it by adding `--set agents.directory=tests/hurl/agents` to the server
start in `tests/hurl/run.sh`. Add `tests/hurl/agents.hurl` asserting: `GET /agents` is 200
`application/json` with two edges whose nodes are named `disabled-heartbeat` and `heartbeat`
in that order, `pageInfo.hasNextPage` false; `GET /agents?first=1` has one edge and
`hasNextPage` true; `GET /agents/heartbeat` is 200 with `runnable` true and `lifecycle`
`unverified`; `GET /agents/disabled-heartbeat` has `enabled` false and `runnable` false;
`GET /agents/no-such-agent` is 404 `application/problem+json` with code `agent_not_found` and
`retryable` false; `GET /agents?first=0` is 400 `application/problem+json`.

Document in `docs/operations/configuration.md` that the server role now reads
`agents.directory`, `agents.strict`, and the `directory.*` keys at boot, and in
`docs/architecture/packages.md` update the `shikigami-server` row of the executable table to say
it serves the agent catalog. Note the new routes in `docs/operations/operator-cli.md` beside
`agents list` so an operator knows both exist.

Acceptance: `just hurl` passes; the client commands behave as described against a running
server.


## Concrete Steps

All commands run from the repository root inside the development shell. Builds and tests need
the shell because `librdkafka` is only on the linker path there.

Start the development database if it is not running, create and migrate it, then build:

```bash
nix develop -c pg_ctl -D db/db -l db/postgres.log -o "-k $PWD/db -h \"\"" start
nix develop -c just create-database
nix develop -c cabal build all
```

After Milestone 1, start the server and look for the catalog line on stderr:

```bash
PG_CONNECTION_STRING="host=$PWD/db dbname=shikigami user=$(id -un)" \
  nix develop -c cabal run shikigami-server -- --host 127.0.0.1 --port 8080
```

Expected on stderr, among the startup lines:

```text
{"event":"server.catalog.loaded","loaded":4,"failed":1,...}
{"event":"server.listening","host":"127.0.0.1","port":8080,...}
```

After Milestone 2, regenerate and check the document, then run the typed tests:

```bash
nix develop -c cabal run shikigami-openapi
git diff --stat docs/api/openapi.json
nix develop -c cabal test shikigami-api shikigami-server
```

After Milestone 3, run the client and the black-box suite:

```bash
nix develop -c cabal run shikigami-client -- agents show heartbeat --server http://127.0.0.1:8080
nix develop -c just hurl
```

Expected client output:

```text
name         heartbeat
enabled      true
trigger      schedule
behavior     shikumi_program
sinks        kawa_digest
lifecycle    unverified
runnable     true
```


## Validation and Acceptance

With the server started as above against the repository's own `agents/` directory:

```bash
curl -s http://127.0.0.1:8080/agents/heartbeat | jq .
curl -si http://127.0.0.1:8080/agents/no-such-agent | head -20
curl -s 'http://127.0.0.1:8080/agents?first=2' | jq '.pageInfo'
curl -si 'http://127.0.0.1:8080/agents?first=0' | head -5
```

The first prints the heartbeat view with `"runnable": true`. The second answers `HTTP/1.1 404`
with `Content-Type: application/problem+json` and a body whose `code` is `agent_not_found` and
`retryable` is `false`. The third prints a page info object with `hasNextPage` true and a
non-null `endCursor`; passing that cursor back as `after` returns the remaining agents and no
agent appears twice. The fourth answers 400 with `application/problem+json`.

Required test commands and results: `cabal test shikigami-api` passes including the artifact
drift check and the new wire pins; `cabal test shikigami-server` passes including the relay
conformance walk, the dispatch generalization, and the 404 problem rendering; `cabal test
shikigami-client` passes with the new subcommands; `just hurl` passes. Run
`cabal test shikigami-core` once as well, because `Shikigami.Agent.Catalog` is new core code
and `Shikigami.PackageArchitectureSpec` must still accept the dependency graph.

The early integration check named by the MasterPlan is the pagination 400: perform the
`first=0` request before building the handler's own cursor branch, so the rewrite is proven
before anything depends on it.


## Idempotence and Recovery

Every step is additive and can be rerun. Regenerating `docs/api/openapi.json` is deterministic;
if the drift test fails, regenerate and commit rather than editing the file. The fixture
directory under `tests/hurl/` is independent of the repository's `agents/` directory, so adding
or disabling fixture agents cannot affect a developer's workers. If the server fails to start
after this change, the most likely cause is the manifest directory: run with
`--set agents.strict=false` to see the failed manifests reported instead of fatal, or point
`--set agents.directory=...` at a known-good directory.


## Interfaces and Dependencies

This plan has no hard prerequisite; it starts from the current tree.

It owns, for the rest of the MasterPlan: `Shikigami.Agent.Catalog` in `shikigami-core`
(`AgentCatalog`, `catalogFromReport`, `lookupAgent`, `emptyCatalog`, `AgentLifecycleView`,
`agentLifecycle`, `runnable`); `Shikigami.Agent.Api` in `shikigami-api` (`AgentApi` with a
`runs` field reserved for
`docs/plans/90-accept-addressed-agent-runs-over-http-with-server-owned-idempotency.md`,
`AgentView`, and the `AgentName` capture instances); the `AgentNotFound` problem code; the
`logger`, `catalog`, and `directory` fields of `ServerEnv`; the per-vertical structure of the
OpenAPI path assertions; the capture-aware dispatch test; the fixture directory
`tests/hurl/agents/`; and the `agents` client subcommands.

Later plans change what this plan builds in two known ways:
`docs/plans/89-authenticate-public-api-callers-with-configured-bearer-credentials.md` wraps the
`agents` mount in its `Authenticated` combinator, which makes `agentServer` take an `ApiCaller`
argument, and adds an `Authorization` header to every block of `tests/hurl/agents.hurl`;
`docs/plans/90-accept-addressed-agent-runs-over-http-with-server-owned-idempotency.md` adds the
`runs` field to `AgentApi`.

Libraries whose choice matters: `servant 0.20` (`MultiVerb`, `RespondAs`, `NamedRoutes`),
`relay-pagination` 0.1.1.0 and its servant, hasql, and conformance packages,
`servant-openapi-hs` and `openapi-hs` (the only lineage that documents `MultiVerb`), and
`async` for the refresh thread. Verify the released versions with `cabal.project` and the
registry before changing any bound.
