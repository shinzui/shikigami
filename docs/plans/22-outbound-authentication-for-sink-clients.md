---
id: 22
slug: outbound-authentication-for-sink-clients
title: "Outbound authentication for sink clients"
kind: exec-plan
created_at: 2026-07-08T20:14:28Z
intention: "intention_01kx1typzbe9dtqnk49t6d5q5w"
master_plan: "docs/masterplans/4-identity-and-trust-grants-outbound-auth-and-agent-lifecycle-control.md"
---

# Outbound authentication for sink clients

This ExecPlan is a living document. The sections Progress, Surprises & Discoveries,
Decision Log, and Outcomes & Retrospective must be kept up to date as work proceeds.


## Purpose / Big Picture

Shikigami agents deliver their outputs to other services over HTTP ("sinks"): activity digests to kawa, signals to kizashi, and conversation messages to danwa. Today every one of those requests goes out with no credentials at all — the only header the HTTP helper sends is `content-type` (`shikigami-core/src/Shikigami/Sink/Http.hs:31-51`), and the local kawa stub explicitly omits the real doorway's auth gate (`shikigami-core/src/Shikigami/Sink/KawaStub.hs:8`). The real kawa/kizashi/danwa services will require shomei-issued bearer tokens (`docs/initial-spec.md`, IR-2, lines 889-900), so the moment shikigami points at a real endpoint, every sink delivery would fail with 401 — and there is nowhere to even configure a credential.

After this plan, each sink client sends `Authorization: Bearer <token>` when a per-sink token is configured (via environment variables today, via a shomei service-token fetch later behind the same interface), all outbound HTTP goes through one shared connection manager with explicit timeouts (today a brand-new `Manager` is built per request, Http.hs:37, and requests can hang indefinitely on a stuck server), tokens are never logged or serialized, and the `stub-kawa` server can be told to enforce a token so the whole authenticated path is testable end to end:

```bash
# terminal A: the stub now rejects unauthenticated ingest
cabal run shikigami -- stub-kawa --port 8088 --require-token s3cret

# terminal B: the worker sends the token
SHIKIGAMI_KAWA_TOKEN=s3cret cabal run shikigami -- worker --agents agents ...
```


## Progress

- [ ] Milestone 1: shared `Manager` with timeouts; `postJSON` takes an `HttpEnv` and injects a bearer header; kawa/kizashi clients rewired.
- [ ] Milestone 2: credential configuration from env vars (`SHIKIGAMI_{KAWA,KIZASHI,DANWA}_TOKEN`), threaded from the CLI boot to every dispatch; redacted `Show`; boot log states which sinks have tokens (never the values).
- [ ] Milestone 3: danwa client path authenticated (local servant runner over the shared token-injecting manager, replacing `Danwa.runDanwa`).
- [ ] Milestone 4: `stub-kawa --require-token` enforcement plus tests (header asserted by a stub server; 401 path exercised).
- [ ] Milestone 5: shomei token-source seam documented and typed (`TokenSource`), static implementation shipped; `cabal test all` green.


## Surprises & Discoveries

(None yet.)


## Decision Log

- Decision: Ship static per-sink tokens first, behind a `TokenSource` interface (`fetchToken :: IO (Either Text BearerToken)`), and defer shomei-issued service tokens to a later swap of the `TokenSource` implementation.
  Rationale: Verified against the shomei source at `/Users/shinzui/Keikaku/bokuno/shomei` (registered in mori as `shinzui/shomei`): the claims model already carries capability scopes (`AuthClaims` with `scopes :: Set Scope`, `roles`, and the `act` actor claim — `shomei-core/src/Shomei/Domain/Claims.hs:38-52`), signing and verification exist (`signAccessToken`, `shomei-jwt/src/Shomei/Jwt/Sign.hs:125-126`; `verifyToken`, `shomei-jwt/src/Shomei/Jwt/Verify.hs:77`), but the only issuance path builds tokens with `scopes = Set.empty` (`shomei-core/src/Shomei/Workflow/Session.hs:44-56`, line 52) — identity, not capability. Scoped service-token issuance is exactly the IR-2 request into the shomei repo (`docs/initial-spec.md:889-900`) and has not shipped. Designing the interface now and implementing static-first means zero shikigami churn when it does.
  Date: 2026-07-08

- Decision: Tokens live only in a boot-time `SinkHttp`/`TokenSource` value, never in the `KawaConfig`/`KizashiConfig`/`DanwaConfig` records (`shikigami-core/src/Shikigami/Sink/Config.hs:12-31`).
  Rationale: `DanwaConfig` derives `ToJSON`/`FromJSON` (Config.hs:30-31) and sink intents are serialized into the transactional outbox as JSON (`SinkIntent` in `Shikigami/Agent/Workflow.hs:96-106`); putting a secret in a config record is one derived instance away from persisting it in the database or printing it in a log. `BearerToken` gets a redacting `Show` and no JSON instances, so the type system keeps secrets out of every serialization path.
  Date: 2026-07-08

- Decision: Two managers at boot — one shared plain manager (timeouts only) used by `postJSON` for kawa and kizashi, and one danwa manager whose `managerModifyRequest` injects the danwa bearer header. Both created once at process start.
  Rationale: kawa/kizashi requests are built by our own code, so `postJSON` can add the header explicitly per request from its `HttpEnv`. The danwa path goes through the generated servant client (`danwa-client`: `Danwa.Client.runDanwa :: String -> ClientM a -> IO (Either ClientError a)`, `/Users/shinzui/Keikaku/bokuno/danwa/danwa-client/src/Danwa/Client.hs:99-103`), which builds requests internally and — worse — allocates a fresh unauthenticated `Manager` on every call. Rather than patching the danwa repo, shikigami builds its own `ClientEnv` (`mkClientEnv`) over a manager whose `managerModifyRequest` adds the header; that hook is the supported http-client seam for exactly this. It also fixes the per-call manager allocation on the danwa path for free.
  Date: 2026-07-08

- Decision: Response timeout of 30 seconds via `managerResponseTimeout = responseTimeoutMicro 30_000_000` on both managers; keep `defaultManagerSettings` (plain HTTP) as the base.
  Rationale: All configured sink base URLs today are local plain-HTTP endpoints (dev stubs); 30s is generous for a doorway POST but bounds a hung server, which currently blocks the outbox publisher loop (`Shikigami.Worker.runOutboxPublisher`, Worker.hs:103-112) indefinitely. HTTPS (a TLS manager) becomes necessary only when a real remote endpoint ships; note it as a follow-up in the masterplan rather than adding `http-client-tls` speculatively.
  Date: 2026-07-08

- Decision: Configuration idiom is environment variables read in the CLI command modules (`lookupEnv`), matching the existing `PG_CONNECTION_STRING` pattern (`shikigami-cli/src/Shikigami/Cli/Commands/Worker.hs:28`).
  Rationale: `docs/plans/13-wire-a-real-model-provider-into-behavior-runs.md` (MasterPlan 2) lands first and defines the typed `lookupEnv` resolver, fatal-on-invalid startup behavior, and loud redacted description convention. This plan applies that convention to sink tokens instead of establishing a competing one.
  Date: 2026-07-22
- Decision: This plan owns the repository's one header-capable JSON POST seam:
  `postJSONWithHeaders :: HttpEnv -> [(HeaderName, ByteString)] -> Text -> a -> IO ...`;
  `postJSON` is the empty-extra-header wrapper.
  Rationale: plan 28 needs to add `traceparent`, plan 32 needs kanmon requests, and plan
  14 needs authenticated approval notifications. A helper that carries `HttpEnv` lets
  authentication supplied by `TokenSource` compose with caller headers without exposing
  bearer tokens in serializable configs or creating three similar functions.
  Date: 2026-07-22


## Outcomes & Retrospective

(To be filled during and after implementation.)


## Context and Orientation

Repository layout: `shikigami-core` is the runtime library, `shikigami-cli` the `shikigami` executable, `shikigami-migrations` the SQL migrations, `shikigami-api` the wire types. Build/test inside `nix develop` at the repo root with `cabal build all` / `cabal test all`.

Terms. A "sink" is a delivery target declared on an agent (kawa digest / kizashi signal / rei action / danwa conversation). A "bearer token" is an opaque credential sent as the HTTP header `Authorization: Bearer <token>`; the eventual issuer is shomei (the platform's auth service), which signs JWTs whose scopes the receiving service checks. A "Manager" is http-client's connection pool object; creating one is comparatively expensive and is meant to be done once per process, not per request.

The outbound HTTP paths today, all unauthenticated:

- `Shikigami.Sink.Http.postJSON :: (ToJSON a) => Text -> a -> IO (Either Text LBS.ByteString)` (`shikigami-core/src/Shikigami/Sink/Http.hs:31-51`) — POSTs JSON, sends only a `content-type` header (line 42), builds a `newManager defaultManagerSettings` per call (line 37), and sets no timeout beyond the library default. Used by the kawa client (`Shikigami/Sink/KawaClient.hs:90`, `postEnvelope`) and the kizashi client (`Shikigami/Sink/KizashiClient.hs:60`, `postSignal`).
- The danwa client path: `Shikigami.Sink.Danwa.postReply` and `postToFreshConversation` call `Danwa.runDanwa` (`shikigami-core/src/Shikigami/Sink/Danwa.hs:36` and `:64`), which is `danwa-client`'s helper (`/Users/shinzui/Keikaku/bokuno/danwa/danwa-client/src/Danwa/Client.hs:99-103`): it parses the base URL, allocates a fresh `Manager`, and runs the servant `ClientM` with no way to attach headers. (`shikigami-cli/src/Shikigami/Cli/Commands/DanwaSpike.hs:60` also calls it, but that is a dev spike and may stay unauthenticated.)
- Endpoint configuration is base-URLs-only: `KizashiConfig`/`KawaConfig`/`DanwaConfig` in `shikigami-core/src/Shikigami/Sink/Config.hs:12-31`.

Where requests are issued from: the sink dispatcher `Shikigami.Sink.dispatch` (`Sink.hs:39-47`) routes each granted sink to its handler using a `SinkContext` (`Shikigami/Sink/Types.hs:29-38`) that carries the three configs. `SinkContext` is built in `Shikigami.Agent.Workflow.publishSinkIntent` (Workflow.hs:561-583) from `AgentRunDeps` (Workflow.hs:79-89), which is built from `WorkerEnv` (Shikigami/Worker.hs:55-63, populated in `Shikigami/Cli/Commands/Worker.hs:24-43`). So a value created once at CLI boot flows: CLI → `WorkerEnv` → `AgentRunDeps` → `SinkContext` → client call. That is the threading path this plan uses for the HTTP environment.

The stub doorway: `shikigami stub-kawa` runs `Shikigami.Sink.KawaStub.runStubKawa` (`KawaStub.hs:83-92`), a warp app (`stubKawaApplication`, lines 46-74) imitating kawa's `POST /v1/sources/{source}/events` — idempotent, logging, and explicitly without the real doorway's auth gate (module comment, line 8). Its options are `StubKawaOptions { port, republishTopic, broker }` (lines 37-42), parsed in `Shikigami/Cli.hs` (the `stub-kawa` command) and `Shikigami/Cli/Commands/StubKawa.hs`.

Existing test idioms this plan reuses: `shikigami-core/test/Main.hs` spins up in-process warp stubs with `testWithApplication` and asserts on what they received (see `stubKizashiApp` and the `kawaTests` group), and already exercises `stubKawaApplication` directly. The test suite is `shikigami-core-test` (run via `cabal test all`).

Relationship to sibling plans: `docs/plans/21-database-backed-sink-permission-grants.md` threads a `GrantSource` through the same records (`SinkContext`, `AgentRunDeps`, `WorkerEnv`) — the two plans are independent but touch the same constructors, so expect textual merge conflicts, not semantic ones. `docs/plans/32-channel-egress-sink-through-kanmon.md` will add a kanmon egress client that must use this plan's `HttpEnv`/`TokenSource` machinery rather than inventing its own.


## Plan of Work

### Milestone 1 — shared manager, timeouts, and an auth-aware `postJSON`

Scope: stop building a `Manager` per request, bound every request with a timeout, and make `postJSON` capable of injecting a bearer header. At the end, kawa and kizashi clients compile against the new signature and all existing tests pass with a token-less `HttpEnv`.

Create `shikigami-core/src/Shikigami/Sink/Auth.hs` (add to `exposed-modules`):

```haskell
module Shikigami.Sink.Auth
  ( BearerToken (..),
    TokenSource (..),
    staticTokenSource,
    renderAuthHeader,
  )
where

import Data.ByteString (ByteString)
import Data.Text (Text)
import Data.Text.Encoding qualified as TE

-- | An opaque bearer credential. Show is redacted so a token can never leak
-- through error messages, logs, or derived instances. Deliberately has NO
-- ToJSON/FromJSON instances.
newtype BearerToken = BearerToken Text
  deriving stock (Eq)

instance Show BearerToken where
  show _ = "BearerToken <redacted>"

-- | Where tokens come from. Static today (a constant); a shomei-backed source
-- later fetches a scoped service token, caches it until expiry, and refreshes —
-- behind this same one-method interface, so nothing downstream changes.
newtype TokenSource = TokenSource {fetchToken :: IO (Either Text BearerToken)}

staticTokenSource :: Text -> TokenSource
staticTokenSource t = TokenSource (pure (Right (BearerToken t)))

renderAuthHeader :: BearerToken -> ByteString
renderAuthHeader (BearerToken t) = "Bearer " <> TE.encodeUtf8 t
```

Rework `shikigami-core/src/Shikigami/Sink/Http.hs`:

```haskell
data HttpEnv = HttpEnv
  { manager :: !Manager,
    token :: !(Maybe TokenSource)
  }

newSinkManager :: IO Manager
newSinkManager =
  newManager
    defaultManagerSettings {managerResponseTimeout = responseTimeoutMicro 30_000_000}

postJSONWithHeaders :: (ToJSON a) => HttpEnv -> [(HeaderName, ByteString)] -> Text -> a -> IO (Either Text LBS.ByteString)
postJSON :: (ToJSON a) => HttpEnv -> Text -> a -> IO (Either Text LBS.ByteString)
postJSON env = postJSONWithHeaders env []
```

`postJSONWithHeaders` keeps the current parse/try/status handling (Http.hs:32-51) but
uses `manager env` instead of `newManager` (deleting line 37). It starts with the
caller-supplied headers, adds `content-type`, and then resolves authentication: with
`Nothing` it sends no authorization header; with `Just src` it runs `fetchToken src` — a
`Left e` becomes `Left ("token fetch failed: " <> e)` without issuing the request (fail
closed), and a `Right tok` adds `("authorization", renderAuthHeader tok)`. Define
`postJSON` only as the empty-extra-header wrapper. Error strings must never interpolate
the token (the redacted `Show` guards accidents, but do not `show` the header value either).

Rewire the two callers: `postEnvelope :: HttpEnv -> KawaConfig -> ActivityEnvelope -> IO (Either KawaError Text)` (`KawaClient.hs:86-95`) and `postSignal :: HttpEnv -> KizashiConfig -> CreateSignalReq -> IO (Either Text SignalResponse)` (`KizashiClient.hs:57-65`) gain the leading `HttpEnv` parameter and pass it to `postJSON`. Their call sites are in `Shikigami.Sink.runSink` (Sink.hs:51-65) — which reads the envs from `SinkContext` (next milestone). For this milestone to compile independently, add the `SinkContext` fields now (see Milestone 2's record shapes) and let `test/Main.hs`'s `ctxFor` build a token-less env with a per-test `newSinkManager`.

Acceptance: `cabal test all` green (existing kawa/kizashi/danwa dispatch tests unchanged in behavior); `grep -n "newManager" shikigami-core/src/Shikigami/Sink/Http.hs` shows it only inside `newSinkManager`.

### Milestone 2 — credential configuration and threading

Scope: read per-sink tokens from the environment once at boot, and thread a `SinkHttp` bundle along the existing config path so every dispatch uses it. At the end, the worker logs which sinks are authenticated at startup, and requests carry the header (assertable via the Milestone 4 tests).

Add to `Shikigami.Sink.Auth` (or a small `Shikigami.Sink.HttpEnv` section in Http.hs — keep it in one place):

```haskell
data SinkHttp = SinkHttp
  { kawaHttp :: !HttpEnv,
    kizashiHttp :: !HttpEnv,
    danwaClientEnv :: !Servant.Client.ClientEnv
  }

data SinkCredentials = SinkCredentials
  { kawaToken :: !(Maybe TokenSource),
    kizashiToken :: !(Maybe TokenSource),
    danwaToken :: !(Maybe TokenSource)
  }

credentialsFromEnv :: IO SinkCredentials  -- SHIKIGAMI_KAWA_TOKEN, SHIKIGAMI_KIZASHI_TOKEN, SHIKIGAMI_DANWA_TOKEN
newSinkHttp :: SinkCredentials -> DanwaConfig -> IO SinkHttp
```

`credentialsFromEnv` maps `lookupEnv` results through `staticTokenSource` (empty string counts as unset). `newSinkHttp` builds one `newSinkManager` shared by `kawaHttp`/`kizashiHttp`, and the danwa `ClientEnv` per Milestone 3. Threading (same path as the existing configs): `WorkerEnv` (Worker.hs:55-63) gains `sinkHttp :: !SinkHttp`; `agentRunDeps` (Worker.hs:194-206) forwards it into a new `AgentRunDeps.sinkHttp` field (Workflow.hs:79-89); `publishSinkIntent` (Workflow.hs:561-583) puts it into a new `SinkContext.sinkHttp` field (Types.hs:29-38); `runSink` (Sink.hs:51-65) passes `kawaHttp`/`kizashiHttp`/`danwaClientEnv` to the respective handlers. Update every other `AgentRunDeps`/`SinkContext` construction site the compiler flags (at minimum `Shikigami/Cli/Commands/AgentRun.hs`, `Shikigami/Agent/Conversation.hs` if it builds contexts, `test/Main.hs`, `test/Shikigami/AgentWorkflowSpec.hs`).

In `Shikigami.Cli.Commands.Worker.runWorkerCmd` (Worker.hs:24-43): `creds <- credentialsFromEnv`, `sinkHttp <- newSinkHttp creds danwaCfg`, put it in `WorkerEnv`, and log one boot line per sink, e.g. `[worker] sink auth: kawa=token kizashi=none danwa=none` — presence only, never values.

Acceptance: `cabal build all`; starting the worker with `SHIKIGAMI_KAWA_TOKEN=x` prints `kawa=token`; without it, `kawa=none`. `grep -rn "SHIKIGAMI_.*_TOKEN" shikigami-cli/src` shows exactly one reading site.

### Milestone 3 — authenticated danwa client path

Scope: route the danwa sink through a boot-time servant `ClientEnv` whose manager injects the danwa token, replacing the per-call unauthenticated `Danwa.runDanwa`.

In `newSinkHttp`, build the danwa side: resolve the token once per request via `managerModifyRequest` — create `danwaManager <- newManager defaultManagerSettings { managerResponseTimeout = responseTimeoutMicro 30_000_000, managerModifyRequest = addDanwaAuth }` where `addDanwaAuth req` fetches from the configured `TokenSource` (if any) and prepends the `authorization` header (leave the request untouched when no source is configured; on fetch failure let the request proceed unauthenticated and let the server's 401 surface as a `Failed` outcome — the outbox publisher's normal retry path). Then `url <- parseBaseUrl (Text.unpack (baseUrl danwaCfg))` and `pure (mkClientEnv danwaManager url)`. This needs `servant-client` as an explicit `shikigami-core` dependency (it is already in the build plan transitively via `danwa-client`, so the freeze/plan does not change).

In `shikigami-core/src/Shikigami/Sink/Danwa.hs`: change `runDanwa :: ClientEnv -> AgentIdentity -> Maybe DanwaTarget -> Sink -> Value -> IO (Either Text Text)` (was `DanwaConfig` first, Danwa.hs:24) — it still needs `agentParticipant` from `DanwaConfig`, so pass both (`ClientEnv` for transport, `DanwaConfig` for the participant id). Replace the two `Danwa.runDanwa (Text.unpack (baseUrl cfg))` calls (lines 36, 64) with `Servant.Client.runClientM action env`. Update the dispatcher call (Sink.hs:64) to pass `danwaClientEnv (sinkHttp ctx)`.

Note on `managerModifyRequest`: it is applied to every request through that manager (including internal retries), which is why the danwa manager is separate from the kawa/kizashi manager — the hook must never leak the danwa token to other hosts.

Acceptance: existing `danwaTests` in `test/Main.hs` pass with a `ClientEnv` built over the test stub's base URL; a new test asserts the stub received an `authorization` header when a source is configured (Milestone 4's helper).

### Milestone 4 — token enforcement in stub-kawa, and tests

Scope: make the authenticated path provable end to end.

`StubKawaOptions` (KawaStub.hs:37-42) gains `requireToken :: !(Maybe Text)`; `stubKawaApplication` gains the same parameter and, when set, checks the `Authorization` request header equals `"Bearer " <> token` before the existing body handling — otherwise responds `401` with body `unauthorized` and logs `[stub-kawa] rejected: missing/invalid token` (never the presented value). Update the module comment (KawaStub.hs:8) — the auth gate is now optionally imitated. CLI: add `--require-token TOKEN` to the `stub-kawa` parser in `Shikigami/Cli.hs` and thread through `Shikigami/Cli/Commands/StubKawa.hs`.

Tests in `shikigami-core/test/Main.hs` (or a new `Shikigami/SinkAuthSpec.hs` registered in `Main.hs`):

1. Header injection: a recording warp stub (pattern of `stubKizashiApp`) captures `requestHeaders`; `postJSON (HttpEnv mgr (Just (staticTokenSource "s3cret"))) url body` results in exactly one request whose `authorization` header is `Bearer s3cret`; with `token = Nothing`, no `authorization` header is present.
2. Enforcement: `stubKawaApplication` with `requireToken = Just "s3cret"`: a dispatch through a `SinkContext` whose `kawaHttp` has the matching static source yields `Delivered`; with no token, the outcome is `Failed` mentioning `HTTP 401` (which the worker maps to retry — delivery truth is unchanged).
3. Token fetch failure: a `TokenSource` returning `Left "boom"` makes `postJSON` return `Left "token fetch failed: boom"` without the stub receiving any request.
4. Redaction: `show (BearerToken "s3cret")` is `"BearerToken <redacted>"`.

Acceptance: `cabal test all` green including the new group.

### Milestone 5 — the shomei seam (design shipped as types + docs, no shomei calls yet)

Scope: make the future swap mechanical. `TokenSource` already is the seam; this milestone adds the documentation shim so a later implementer needs no archaeology. In `Shikigami.Sink.Auth`, add a haddock section stating: when shomei's scoped service-token issuance ships (IR-2, `docs/initial-spec.md:889-900`), implement `shomeiTokenSource :: ShomeiTokenConfig -> IO TokenSource` in a new module — it logs in / requests a service token with the sink's scope (e.g. `kawa:ingest`, `signal:raise`), caches the `BearerToken` with its expiry in an `IORef`/`MVar`, refreshes ahead of expiry inside `fetchToken`, and never exposes the raw JWT beyond `renderAuthHeader`. The verified shomei building blocks it will call: `signAccessToken`/JWKS on the service side (`shomei-jwt/src/Shomei/Jwt/Sign.hs:125`), `shomei-client` (package `mori://shinzui/shomei/packages/shomei-client`) on ours. Record in this plan's Decision Log when the swap happens.

Acceptance: haddock present; `cabal build all` clean.


## Concrete Steps

All from the repo root `/Users/shinzui/Keikaku/bokuno/shikigami`, inside `nix develop`.

```bash
nix develop
# Milestones 1-3: edits per Plan of Work, then
cabal build all
cabal test all
```

End-to-end transcript (after Milestone 4). Terminal A:

```bash
cabal run shikigami -- stub-kawa --port 8088 --require-token s3cret
```

Terminal B — unauthenticated delivery fails loudly (expect the outbox publisher to log a failed publish with `HTTP 401`, and stub-kawa to log a rejection):

```bash
export PG_CONNECTION_STRING="host=$PGHOST dbname=$PGDATABASE user=$(id -un)"
cabal run shikigami -- worker --agents agents --kawa-url http://localhost:8088 \
  --kizashi-url http://localhost:1 --danwa-url http://localhost:1 --danwa-agent part_test
cabal run shikigami -- enqueue-run heartbeat --payload '{}'
```

Expected stub-kawa output in terminal A:

```text
[stub-kawa] rejected: missing/invalid token
```

Restart the worker with the token and enqueue again:

```bash
SHIKIGAMI_KAWA_TOKEN=s3cret cabal run shikigami -- worker --agents agents --kawa-url http://localhost:8088 \
  --kizashi-url http://localhost:1 --danwa-url http://localhost:1 --danwa-agent part_test
```

Expected stub-kawa output:

```text
[stub-kawa] accepted source=shinzui/shikigami source_event_id=heartbeat:... activity_id=act_...
```

And the worker boot line:

```text
[worker] sink auth: kawa=token kizashi=none danwa=none
```


## Validation and Acceptance

Acceptance is behavioral: (1) with `--require-token` on stub-kawa and no `SHIKIGAMI_KAWA_TOKEN`, a `KawaDigest` sink dispatch ends `Failed … HTTP 401` and nothing is ingested; (2) with the matching token exported, the same dispatch ends `Delivered` and stub-kawa logs `accepted`; (3) no token value ever appears in any log line, error message, or database row — verify by grepping the worker/stub stderr capture for `s3cret` after the transcript above (zero matches), and by `show`ing a `BearerToken` in GHCi (`cabal repl shikigami-core`) and observing `BearerToken <redacted>`; (4) `cabal test all` passes, including the header-injection, enforcement, fetch-failure, and redaction tests of Milestone 4; (5) reading `shikigami-core/src/Shikigami/Sink/Http.hs` shows a single process-lifetime manager path and `managerResponseTimeout` set (the per-request `newManager` at the old line 37 is gone).


## Idempotence and Recovery

All changes are code-only (no migrations, no persisted state), so re-running builds and tests is trivially safe. The rollout is backward compatible at every step: with no `SHIKIGAMI_*_TOKEN` env vars set, requests are byte-identical to today's (modulo the added timeout), and stub-kawa without `--require-token` behaves exactly as before — so the feature can be deployed dark and enabled per environment by setting variables. If a wrong token is configured, deliveries fail with `HTTP 401` and remain in the outbox retry loop (`Failed` → `PublishFailed` → retried by `runOutboxPublisher`), so fixing the variable and restarting the worker resumes delivery without data loss. Never commit a real token to the repo; the transcripts above use throwaway values.


## Interfaces and Dependencies

Dependency changes: add `servant-client` (and `http-types` if not already direct) to `shikigami-core`'s `build-depends`; both are already in the build plan via `danwa-client`/`warp`, so no freeze changes. No new external services: kawa/kizashi are stubbed in-repo, danwa's client is `danwa-client` (source at `/Users/shinzui/Keikaku/bokuno/danwa/danwa-client`).

Signatures that must exist at the end (full module paths):

```haskell
-- shikigami-core : Shikigami.Sink.Auth (new)
newtype BearerToken = BearerToken Text          -- Show redacted; no To/FromJSON
newtype TokenSource = TokenSource {fetchToken :: IO (Either Text BearerToken)}
staticTokenSource :: Text -> TokenSource
renderAuthHeader :: BearerToken -> ByteString
data SinkCredentials = SinkCredentials
  { kawaToken, kizashiToken, danwaToken :: !(Maybe TokenSource) }
credentialsFromEnv :: IO SinkCredentials
data SinkHttp = SinkHttp
  { kawaHttp :: !HttpEnv, kizashiHttp :: !HttpEnv, danwaClientEnv :: !ClientEnv }
newSinkHttp :: SinkCredentials -> DanwaConfig -> IO SinkHttp

-- shikigami-core : Shikigami.Sink.Http
data HttpEnv = HttpEnv {manager :: !Manager, token :: !(Maybe TokenSource)}
newSinkManager :: IO Manager
postJSONWithHeaders :: (ToJSON a) => HttpEnv -> [(HeaderName, ByteString)] -> Text -> a -> IO (Either Text LBS.ByteString)
postJSON :: (ToJSON a) => HttpEnv -> Text -> a -> IO (Either Text LBS.ByteString)

-- shikigami-core : Shikigami.Sink.KawaClient
postEnvelope :: HttpEnv -> KawaConfig -> ActivityEnvelope -> IO (Either KawaError Text)

-- shikigami-core : Shikigami.Sink.KizashiClient
postSignal :: HttpEnv -> KizashiConfig -> CreateSignalReq -> IO (Either Text SignalResponse)

-- shikigami-core : Shikigami.Sink.Danwa
runDanwa :: ClientEnv -> DanwaConfig -> AgentIdentity -> Maybe DanwaTarget -> Sink -> Value -> IO (Either Text Text)

-- shikigami-core : Shikigami.Sink.KawaStub
data StubKawaOptions = StubKawaOptions
  { port :: !Int, republishTopic :: !(Maybe Text), broker :: !(Maybe Text),
    requireToken :: !(Maybe Text) }
stubKawaApplication :: IORef (Map (Text, Text) Text) -> Maybe Republisher -> Maybe Text -> Application

-- shikigami-core : Shikigami.Sink.Types / Shikigami.Agent.Workflow / Shikigami.Worker
-- SinkContext, AgentRunDeps, WorkerEnv each gain: sinkHttp :: !SinkHttp
```

Soft landing dependencies: plan 13 defines the configuration convention and plan 16
settles the sink-client/request shapes this plan wraps. Consumers: plan 14 uses
`SinkHttp` for authenticated approval asks; plan 28 passes `traceparent` through
`postJSONWithHeaders`; plan 32 extends `SinkCredentials`/`SinkHttp` with kanmon and
uses the same helper. Plan 21 touches the same record constructors but is semantically
independent.


## Revision Notes

- 2026-07-22: Made plan 13 the configuration-convention predecessor and assigned this
  plan sole ownership of `postJSONWithHeaders`. Plans 14, 28, and 32 now consume this
  authenticated seam rather than defining raw or incompatible HTTP helpers.
