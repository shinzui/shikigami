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

After this plan, each sink client sends `Authorization: Bearer <token>` when a per-sink
credential reference is resolved through plan 37's Settei application config (static
secret source today, shomei service-token fetch later behind the same interface), all
outbound HTTP goes through one shared connection manager with explicit timeouts, tokens
are never logged or serialized, and `stub-kawa` can enforce the authenticated path end to end:

```bash
# terminal A: the stub now rejects unauthenticated ingest
cabal run shikigami -- stub-kawa --config config/stub-kawa-auth.yaml

# terminal B: the worker sends the token
cabal run shikigami-worker -- --config config/worker-auth.yaml
```


## Progress

- [ ] Milestone 1: shared `Manager` with timeouts and bounded request/response bodies; `postJSON` takes an `HttpEnv`, injects auth, and preserves typed failure class; kawa/kizashi clients rewired.
- [ ] Prerequisites: plans 36/37 complete; HTTP modules follow the six-package boundary and credentials come from Settei.
- [ ] Milestone 2: Settei credential-reference configuration with explicit legacy bindings, threaded from composition root to dispatch; secret types have no `Show`/JSON instances; boot log states which sinks have credentials (never values).
- [ ] Milestone 3: danwa client path authenticated (local servant runner over the shared token-injecting manager, replacing `Danwa.runDanwa`).
- [ ] Milestone 4: stub-kawa credential-reference enforcement plus tests (header asserted by a stub server; 401 path exercised).
- [ ] Milestone 5: shomei token-source seam documented and typed (`TokenSource`), static implementation shipped; `cabal test all` green.


## Surprises & Discoveries

(None yet.)


## Decision Log

- Decision: Ship static per-sink tokens first, behind a `TokenSource` interface
  (`fetchToken :: IO (Either CredentialFailure BearerToken)`), and defer shomei-issued
  service tokens to a later swap of the `TokenSource` implementation.
  Rationale: Verified against the shomei source at `/Users/shinzui/Keikaku/bokuno/shomei` (registered in mori as `shinzui/shomei`): the claims model already carries capability scopes (`AuthClaims` with `scopes :: Set Scope`, `roles`, and the `act` actor claim — `shomei-core/src/Shomei/Domain/Claims.hs:38-52`), signing and verification exist (`signAccessToken`, `shomei-jwt/src/Shomei/Jwt/Sign.hs:125-126`; `verifyToken`, `shomei-jwt/src/Shomei/Jwt/Verify.hs:77`), but the only issuance path builds tokens with `scopes = Set.empty` (`shomei-core/src/Shomei/Workflow/Session.hs:44-56`, line 52) — identity, not capability. Scoped service-token issuance is exactly the IR-2 request into the shomei repo (`docs/initial-spec.md:889-900`) and has not shipped. Designing the interface now and implementing static-first means zero shikigami churn when it does.
  Date: 2026-07-08

- Decision: Tokens live only in a boot-time `SinkHttp`/`TokenSource` value, never in the `KawaConfig`/`KizashiConfig`/`DanwaConfig` records (`shikigami-core/src/Shikigami/Sink/Config.hs:12-31`).
  Rationale: `DanwaConfig` derives `ToJSON`/`FromJSON` (Config.hs:30-31) and sink intents are serialized into the transactional outbox as JSON (`SinkIntent` in `Shikigami/Agent/Workflow.hs:96-106`); putting a secret in a config record is one derived instance away from persisting it in the database or printing it in a log. `BearerToken` has a private constructor and no `Show` or JSON instances, so the type system keeps secrets out of every serialization path.
  Date: 2026-07-08

- Decision: Two TLS-capable managers at boot — one shared manager used by `postJSON` for kawa
  and kizashi, and one danwa manager whose request hook injects the danwa bearer header and
  whose response hook enforces the same body limit. Both are created once at process start;
  redirects are disabled so credentials cannot be replayed to a redirect target.
  Rationale: kawa/kizashi requests are built by our own code, so `postJSON` can add the header explicitly per request from its `HttpEnv`. The danwa path goes through the generated servant client (`danwa-client`: `Danwa.Client.runDanwa :: String -> ClientM a -> IO (Either ClientError a)`, `/Users/shinzui/Keikaku/bokuno/danwa/danwa-client/src/Danwa/Client.hs:99-103`), which builds requests internally and — worse — allocates a fresh unauthenticated `Manager` on every call. Rather than patching the danwa repo, shikigami builds its own `ClientEnv` (`mkClientEnv`) over a manager whose `managerModifyRequest` adds the header; that hook is the supported http-client seam for exactly this. It also fixes the per-call manager allocation on the danwa path for free.
  Date: 2026-07-08

- Decision: Response timeout of 30 seconds via
  `managerResponseTimeout = responseTimeoutMicro 30_000_000` on both managers, based on
  `http-client-tls`'s `tlsManagerSettings` so HTTP and HTTPS endpoints share one path.
  Rationale: 30s bounds a hung doorway request, which currently blocks the outbox publisher
  loop indefinitely. Authentication must not require a later manager replacement when a real
  endpoint moves from a local HTTP stub to HTTPS.
  Date: 2026-07-08

- Decision: Bound encoded request and decoded response bytes in the HTTP layer with validated
  `HttpLimits`; never use an unbounded lazy-body helper for remote responses.
  Rationale: a timeout does not cap memory. A compromised or broken service can stream an
  arbitrarily large body, while an oversized behavior output can create an equally large
  request. Limits are Settei domain values and violations are typed permanent protocol/input
  failures.
  Date: 2026-07-22

- Decision: Plan 37 owns Settei source composition, explicit legacy environment
  bindings, validation, diagnostics, and exit semantics. This plan declares per-sink
  credential-reference settings only; command/client modules never call `lookupEnv`.
  Rationale: credentials need one typed/redacted composition root and must not become
  process arguments, serializable config, or arbitrary log values.
  Date: 2026-07-22
- Decision: This plan owns the repository's one header-capable JSON POST seam:
  `postJSONWithHeaders :: HttpEnv -> [(HeaderName, ByteString)] -> Text -> a -> IO ...`;
  `postJSON` is the empty-extra-header wrapper.
  Rationale: plan 28 needs to add `traceparent`, plan 32 needs kanmon requests, and plan
  14 needs authenticated approval notifications. A helper that carries `HttpEnv` lets
  authentication supplied by `TokenSource` compose with caller headers without exposing
  bearer tokens in serializable configs or creating three similar functions.
  Date: 2026-07-22
- Decision: Preserve HTTP failure class. Treat malformed/oversized requests, oversized
  responses, redirects, and 4xx responses as permanent by default; 408, 425, and 429 are
  transient, and a client may give a documented endpoint-specific meaning to 409. Treat
  timeouts, network failures, and 5xx as transient. Callers and the outbox map the typed class
  instead of parsing error text or retrying every non-2xx response.
  Rationale: credentials and URLs do not repair themselves during a tight retry loop, while
  throttling and service outages do. A typed `HttpFailure` keeps this distinction consistent
  for kawa, kizashi, danwa, approvals, and kanmon.
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
  ( BearerToken,
    TokenSource (..),
    credentialToken,
    staticTokenSource,
  )
where

import Data.Text (Text)

-- | An opaque bearer credential. The constructor is private and the type has
-- no Show, Read, ToJSON, or FromJSON instance.
newtype BearerToken = BearerToken Text
  deriving stock (Eq)

credentialToken :: CredentialValue -> BearerToken

data CredentialFailure = CredentialFailure
  { reference :: !CredentialRef,
    reason :: !CredentialFailureReason
  }
  deriving stock (Eq, Show)

data CredentialFailureReason
  = CredentialBackendUnavailable
  | CredentialExpired
  | CredentialRejected
  deriving stock (Eq, Show)

-- | Where tokens come from. Static today (a constant); a shomei-backed source
-- later fetches a scoped service token, caches it until expiry, and refreshes —
-- behind this same one-method interface, so nothing downstream changes.
newtype TokenSource = TokenSource {fetchToken :: !(IO (Either CredentialFailure BearerToken))}

staticTokenSource :: BearerToken -> TokenSource
staticTokenSource token = TokenSource (pure (Right token))

-- renderAuthHeader lives in an unexposed package-internal module used only by
-- the HTTP request builder.
```

Rework `shikigami-core/src/Shikigami/Sink/Http.hs`:

```haskell
data HttpEnv = HttpEnv
  { manager :: !Manager,
    token :: !(Maybe TokenSource),
    limits :: !HttpLimits
  }

newSinkManager :: IO Manager
newSinkManager =
  newManager
    tlsManagerSettings
      { managerResponseTimeout = responseTimeoutMicro 30_000_000
      }

postJSONWithHeaders :: (ToJSON a) => HttpEnv -> [(HeaderName, ByteString)] -> Text -> a -> IO (Either HttpFailure LBS.ByteString)
postJSON :: (ToJSON a) => HttpEnv -> Text -> a -> IO (Either HttpFailure LBS.ByteString)
postJSON env = postJSONWithHeaders env []
```

`postJSONWithHeaders` keeps the current parse/try/status handling (Http.hs:32-51) but
uses `manager env` instead of `newManager` (deleting line 37). It starts with the
caller-supplied headers, adds `content-type`, and then resolves authentication: with
`Nothing` it sends no authorization header; with `Just src` it runs `fetchToken src` — a
`Left e` becomes a typed transient credential failure without issuing the request (fail
closed), and a `Right tok` adds `("authorization", renderAuthHeader tok)`. Define
`postJSON` only as the empty-extra-header wrapper. Rendered diagnostics carry only stable
error categories and credential-reference names; provider error text is not retained and the
secret type cannot be rendered. Set `redirectCount = 0` on the request and classify every 3xx
as a permanent unexpected-response failure so the authorization header is never forwarded to
a redirect target.
Encode the request once and reject it before network IO if it exceeds `requestBytes`. Read
the response through a streaming/bounded http-client path, abort after `responseBytes + 1`,
and never construct an unbounded lazy body. Tests cover exact-boundary and one-byte-over
request/response cases.

Rewire the two callers: `postEnvelope :: HttpEnv -> KawaConfig -> ActivityEnvelope -> IO
(Either KawaError Text)` and `postSignal :: HttpEnv -> KizashiConfig -> CreateSignalReq -> IO
(Either KizashiError SignalResponse)` gain the leading `HttpEnv` parameter and preserve the
typed failure class from `postJSON`. Their call sites read the direct `http` field from
`SinkContext`; tests build a token-less environment with a per-test manager and explicit
test `HttpLimits`.
Preserve `HttpFailure` through client-specific errors. At the sink boundary, map permanent
failures to plan 19's additive `PermanentFailure` and transient failures to the existing
`Failed`; plan 19 maps those to Keiro `PublishRejected`/`PublishFailed`.

Acceptance: `cabal test all` green (existing kawa/kizashi/danwa dispatch tests unchanged in behavior); `grep -n "newManager" shikigami-core/src/Shikigami/Sink/Http.hs` shows it only inside `newSinkManager`.

### Milestone 2 — Settei credential configuration and threading

Scope: resolve per-sink credential references once in plan 37's Settei composition root
and thread a `SinkHttp` bundle along the existing config path. At the end, the worker
logs presence only and requests carry the header.

Add to `Shikigami.Sink.Auth` (or a small `Shikigami.Sink.HttpEnv` section in Http.hs — keep it in one place):

```haskell
data SinkHttp = SinkHttp
  { kawa :: !HttpEnv,
    kizashi :: !HttpEnv,
    danwa :: !Servant.Client.ClientEnv
  }

data SinkCredentials = SinkCredentials
  { kawa :: !(Maybe TokenSource),
    kizashi :: !(Maybe TokenSource),
    danwa :: !(Maybe TokenSource)
  }

credentialsFromConfig :: AppConfig -> Either ConfigError SinkCredentials
newSinkHttp :: HttpLimits -> SinkCredentials -> DanwaConfig -> IO SinkHttp
```

`credentialsFromConfig` resolves validated Settei credential references to private
`BearerToken` values at the composition root and maps them through `staticTokenSource`;
missing required values fail typed startup validation.
`newSinkHttp` builds the shared managers/client environments. Thread `SinkHttp` through
the strict records from the plan-36 composition root to dispatch, updating every
constructor site the compiler identifies.

At the worker composition root, obtain `creds <- credentialsFromConfig appConfig`, build
`SinkHttp`, and log one boot line per sink—presence only, never values.

Acceptance: `cabal build all`; plan 37's explain diagnostics show only a redacted winning
source for the kawa credential reference, and the worker prints `kawa=token` or `kawa=none`
without the reference's value. Production modules contain no direct environment read.

### Milestone 3 — authenticated danwa client path

Scope: route the danwa sink through a boot-time servant `ClientEnv` whose manager injects the danwa token, replacing the per-call unauthenticated `Danwa.runDanwa`.

In `newSinkHttp`, build the danwa side with a dedicated manager whose
`managerModifyRequest` fetches from the configured `TokenSource` and prepends the
authorization header. The same hook sets `redirectCount = 0` and rejects a generated request
body over `requestBytes` before network IO. If no source is configured, leave the
authorization header untouched. If a
configured source fails, throw a private typed `CredentialUnavailable` exception from the
hook, catch it at the client boundary, and return a typed sink failure without issuing the
HTTP request; never degrade to an unauthenticated request. Set the same bounded response
timeout and install `managerModifyResponse` to wrap the response `BodyReader`, count chunks,
and throw a private `ResponseTooLarge` as soon as reading would exceed `responseBytes`.
This bounds servant-client's otherwise eager body decode too. Parse the configured base URL
once and construct one boot-time `ClientEnv`.

In `Shikigami.Sink.Danwa`, change `runDanwa` to accept the boot-time `ClientEnv` and return
`Either DanwaError Text`, retaining the permanent/transient class from Servant/client
failures. It still receives `DanwaConfig` for participant identity. Replace per-call
`Danwa.runDanwa` with `runClientM` and pass `danwa (http ctx)` from the dispatcher.

Note on `managerModifyRequest`: it is applied to every request through that manager (including internal retries), which is why the danwa manager is separate from the kawa/kizashi manager — the hook must never leak the danwa token to other hosts.

Acceptance: existing `danwaTests` in `test/Main.hs` pass with a `ClientEnv` built over the test stub's base URL; a new test asserts the stub received an `authorization` header when a source is configured (Milestone 4's helper).

### Milestone 4 — token enforcement in stub-kawa, and tests

Scope: make the authenticated path provable end to end.

`StubKawaOptions` gains `requireToken :: !(Maybe BearerToken)`; the Settei surface accepts a
credential reference and resolves it at the stub executable's composition root. When set,
`stubKawaApplication` compares the request header in constant time before body handling;
otherwise it returns a typed 401 problem response and logs only
`[stub-kawa] rejected: missing/invalid token`. Do not add a raw-token command-line option.

Tests in `shikigami-core/test/Main.hs` (or a new `Shikigami/SinkAuthSpec.hs` registered in `Main.hs`):

1. Header injection: a recording Warp stub captures request headers; use a test-only smart
   constructor to build a `BearerToken`, then `staticTokenSource token`. The request contains
   the expected authorization bytes; `Nothing` sends no header. No failure output renders the
   token.
2. Enforcement: `stubKawaApplication` with the same opaque test token accepts the matching
   `HttpEnv`; with no token it returns HTTP 401 and records no ingest.
3. Token fetch failure: a `TokenSource` returning a typed `CredentialFailure` makes
   `postJSON` return the corresponding transient `HttpFailure` without the stub receiving any
   request or rendering backend error text.
4. Non-renderability: compile-time/API tests prove production code has no `Show`, `Read`, or
   JSON instance and cannot access the private constructor.
5. Limits and redirects: kawa/kizashi and servant-based danwa tests cover exact-boundary and
   one-byte-over request/response bodies; a 3xx target receives no follow-up request or
   authorization header.

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
cabal run shikigami -- stub-kawa --config config/stub-kawa-auth.yaml
```

Terminal B — unauthenticated delivery fails loudly (expect the outbox publisher to log a
failed publish with `HTTP 401`, and stub-kawa to log a rejection). The checked config file
contains the database, agent directory, and sink URLs but intentionally omits
`credentials.sinks.kawa.token`:

```bash
cabal run shikigami-worker -- --config config/worker-auth-missing.yaml
cabal run shikigami -- enqueue-run heartbeat --payload '{}' --config config/operator-dev.yaml
```

Expected stub-kawa output in terminal A:

```text
[stub-kawa] rejected: missing/invalid token
```

Restart the worker with the credential reference enabled through plan 37's Settei sources
and enqueue again:

```bash
cabal run shikigami-worker -- --config config/worker-auth.yaml
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

Acceptance is behavioral: (1) with stub enforcement enabled and no worker credential, a
`KawaDigest` dispatch ends in typed HTTP 401 failure and nothing is ingested; (2) with the
matching reference resolved, it is delivered; (3) a planted token appears nowhere in logs,
errors, diagnostics, database rows, or JSON, and production code cannot `show` it; (4)
configured token-source failure issues no request; and (5) the full suite passes with one
process-lifetime manager path and bounded timeouts.


## Idempotence and Recovery

Plan 37 explicitly binds the legacy `SHIKIGAMI_*_TOKEN` names, so rollout remains backward
compatible while also supporting file/secret sources. No sink/command module reads those
names directly, and no credential value is admitted to serializable configuration.

All changes are code-only. With no credential reference, requests are byte-identical to
today except for the timeout; stub enforcement disabled behaves as before. A wrong credential
returns a permanent 401 failure and is not automatically retried; a resolver failure fails
closed before the request. Correct the secret source/reference and use the audited replay
path where appropriate. Never place raw
tokens in repositories, process arguments, or example configuration files.


## Portfolio Reconciliation (2026-07-30)

This plan hard-depends on plans 19, 36, 37, and 47. It owns the only authenticated,
header-capable HTTP layer. Credential values are opaque Settei composition-root values; sink
configuration and journaled intents carry references only. Preserve plan 19's terminal/transient
classification when translating HTTP responses.


## Portfolio Reconciliation (2026-08-05)

`docs/plans/52-signed-attestation-read-api-and-uc-8-conformance.md` reuses this plan's credential
resolution for a **second, stricter credential class**: the key that signs a run attestation. Keep
the resolution machinery general enough to serve it, and keep the distinction visible in the code
rather than only in prose. A sink credential authenticates this system to a downstream service, so a
behavior that leaked one could impersonate the runtime. A signing key is worse: a behavior that could
reach it could forge the very attestation meant to constrain that behavior. Both the local request
`docs/improvement-requests/attest-sanctioned-agent-execution.md` and the shared upstream contract
`mori://shinzui/kikan/okf/improvement-requests/concepts/IR-6` require signing keys to be held outside
agent-controlled behavior and mutable workspaces, and plan 52 asserts that non-visibility with a
test rather than a comment. Nothing in this plan's own scope changes; do not add the signing class
here.


## Interfaces and Dependencies

Hard dependencies: plans 19, 36, and 37. Plan 19 supplies the additive permanent-failure
outcome and Keiro terminal mapping; plan 37 supplies application config and the secret
boundary. Plan 13 no longer defines configuration conventions.

Dependency changes: add `servant-client`, `http-client-tls`, and `http-types` if they are not
already direct dependencies of `shikigami-core`. Before choosing bounds, use Mori for source
and verify the current Hackage release/upstream tag. No new external services: kawa/kizashi
are stubbed in-repo, danwa's client is `danwa-client` (source at
`/Users/shinzui/Keikaku/bokuno/danwa/danwa-client`).

Signatures that must exist at the end (full module paths):

```haskell
-- shikigami-core : Shikigami.Sink.Auth (new)
newtype BearerToken = BearerToken Text          -- private constructor; no Show/Read/JSON
data CredentialFailure = CredentialFailure
  { reference :: !CredentialRef, reason :: !CredentialFailureReason }
newtype TokenSource = TokenSource {fetchToken :: !(IO (Either CredentialFailure BearerToken))}
credentialToken :: CredentialValue -> BearerToken
staticTokenSource :: BearerToken -> TokenSource
-- package-internal only: renderAuthHeader :: BearerToken -> ByteString
data SinkCredentials = SinkCredentials
  { kawa, kizashi, danwa :: !(Maybe TokenSource) }
credentialsFromConfig :: AppConfig -> Either ConfigError SinkCredentials
data SinkHttp = SinkHttp
  { kawa :: !HttpEnv, kizashi :: !HttpEnv, danwa :: !ClientEnv }
newSinkHttp :: HttpLimits -> SinkCredentials -> DanwaConfig -> IO SinkHttp

-- shikigami-core : Shikigami.Sink.Http
data HttpLimits = HttpLimits {requestBytes :: !ByteLimit, responseBytes :: !ByteLimit}
data HttpEnv = HttpEnv
  { manager :: !Manager, token :: !(Maybe TokenSource), limits :: !HttpLimits }
newSinkManager :: IO Manager -- TLS-capable; timeout set once
data HttpFailure = PermanentHttpFailure ... | TransientHttpFailure ...
postJSONWithHeaders :: (ToJSON a) => HttpEnv -> [(HeaderName, ByteString)] -> Text -> a -> IO (Either HttpFailure LBS.ByteString)
postJSON :: (ToJSON a) => HttpEnv -> Text -> a -> IO (Either HttpFailure LBS.ByteString)

-- shikigami-core : Shikigami.Sink.KawaClient
postEnvelope :: HttpEnv -> KawaConfig -> ActivityEnvelope -> IO (Either KawaError Text)

-- shikigami-core : Shikigami.Sink.KizashiClient
postSignal :: HttpEnv -> KizashiConfig -> CreateSignalReq -> IO (Either KizashiError SignalResponse)

-- shikigami-core : Shikigami.Sink.Danwa
runDanwa :: ClientEnv -> DanwaConfig -> AgentIdentity -> Maybe DanwaTarget -> Sink -> Value -> IO (Either DanwaError Text)

-- shikigami-core : Shikigami.Sink.KawaStub
data StubKawaOptions = StubKawaOptions
  { port :: !Int, republishTopic :: !(Maybe Text), broker :: !(Maybe Text),
    requireToken :: !(Maybe BearerToken) }
stubKawaApplication :: IORef (Map (Text, Text) Text) -> Maybe Republisher -> Maybe BearerToken -> Application

-- shikigami-core : Shikigami.Sink.Types / Shikigami.Agent.Workflow / Shikigami.Worker
-- SinkContext, AgentRunDeps, WorkerEnv each gain: http :: !SinkHttp
```

Soft landing dependency: plan 16 settles the sink-client/request shapes this plan wraps.
Consumers: plan 14 uses
`SinkHttp` for authenticated approval asks; plan 28 passes `traceparent` through
`postJSONWithHeaders`; plan 32 extends `SinkCredentials`/`SinkHttp` with kanmon and
uses the same helper. Plan 21 touches the same record constructors but is semantically
independent.


## Revision Notes

- 2026-08-05: Added a Portfolio Reconciliation note recording a second consumer of this plan's
  credential resolution — MasterPlan 10's attestation signing key, a stricter class that must remain
  unreachable from behavior, prompt, tools, and workspace. This plan's own scope is unchanged and does
  not add that class.

- 2026-07-22: Made plan 13 the configuration-convention predecessor and assigned this
  plan sole ownership of `postJSONWithHeaders`. Plans 14, 28, and 32 now consume this
  authenticated seam rather than defining raw or incompatible HTTP helpers.
- 2026-07-22: Superseded plan 13's config ownership with plans 36/37; replaced direct
  token environment reads with Settei credential references and explicit legacy bindings.
- 2026-07-22: Applied the record/security pass: direct duplicate fields (`kawa`, `kizashi`,
  `danwa`, `http`), private non-renderable tokens, reference-only process surfaces, and
  fail-closed danwa credential resolution.
