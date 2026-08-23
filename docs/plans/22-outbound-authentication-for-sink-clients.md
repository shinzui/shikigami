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

Shikigami agents deliver their outputs to other services over HTTP ("sinks"): activity digests to kawa, signals to kizashi, and conversation messages to danwa. Today every one of those requests goes out with no credentials at all — the only header the HTTP helper sends is `content-type` (`shikigami-core/src/Shikigami/Sink/Http.hs`), and the local kawa stub explicitly omits the real doorway's auth gate (`shikigami-server/src/Shikigami/Sink/KawaStub.hs`). The real kawa/kizashi/danwa services will require shomei-issued bearer tokens (`docs/initial-spec.md`, IR-2, lines 889-900), so the moment shikigami points at a real endpoint, every sink delivery would fail with 401 — and there is nowhere to configure a credential.

After this plan, each sink client sends `Authorization: Bearer <token>` when a per-sink
credential is resolved through plan 37's Settei application config (a static secret
today, shomei service-token fetch later behind the same interface), outbound HTTP goes
through process-lifetime connection managers with explicit timeouts and body limits, tokens
are never logged or serialized, and `stub-kawa` can enforce the authenticated path end to end:

```bash
# terminal A: the server-owned stub now rejects unauthenticated ingest
cabal run shikigami -- --config config/stub-kawa-auth.yaml stub-kawa --port 8088

# terminal B: the worker sends the token
cabal run shikigami-worker -- --config config/worker-auth.yaml
```


## Progress

- [x] (2026-08-23T15:08:41Z) Pre-implementation audit: compared the full plan with the current seven-package tree, plan 37's delivered Settei surface, plans 19/36/47, the still-open but unrelated migration item in plan 37, local ADRs 0003/0020/0022/0024, and the Mori-located dependency sources. The plan required a refresh before implementation.
- [x] (2026-08-23T15:08:41Z) Prerequisites: plans 19, 36, and 47 are complete; plan 37's application configuration, redaction, and source composition are complete. Its only open item is the migration package cycle and does not block sink authentication.
- [x] (2026-08-23T15:08:41Z) Refreshed every affected plan section onto the current package boundaries, Settei secret types, dependency releases, local ADRs, and applicable Haskell Jitsurei standards before changing code.
- [ ] Milestone 1: shared TLS-capable `Manager` with timeouts and bounded request/response bodies; `postJSON` takes an `HttpEnv`, injects auth, and preserves typed failure class; kawa/kizashi clients rewired.
- [ ] Milestone 2: optional Settei secret settings with explicit legacy bindings, converted to opaque tokens and threaded from composition root to dispatch; secret types have no `Show`/JSON instances; boot log states which sinks have credentials (never values).
- [ ] Milestone 3: danwa client path authenticated (local servant runner over the shared token-injecting manager, replacing `Danwa.runDanwa`).
- [ ] Milestone 4: server-owned stub-kawa token enforcement plus tests (header asserted by a stub server; RFC 9457 401 path exercised).
- [ ] Milestone 5: shomei token-source seam documented and typed (`TokenSource`), static implementation shipped; `cabal test all` green.


## Surprises & Discoveries

- Observation: Plan 36 removed `shikigami-cli`; production listeners and administrative commands now live in `shikigami-server`, supervised loops live in `shikigami-workers`, and a later decision added the deliberately light seventh package `shikigami-agent`.
  Evidence: `docs/adr/0003-a-seventh-package-keeps-one-off-agent-runs-light.md`, `shikigami-server/shikigami-server.cabal`, and `shikigami-workers/shikigami-workers.cabal`.

- Observation: `stub-kawa` moved to `shikigami-server`, while core tests use the intentionally smaller `shikigami-core/test/Shikigami/Fixture/KawaStub.hs` fixture to preserve package direction.
  Evidence: the production modules are `shikigami-server/src/Shikigami/Sink/KawaStub.hs` and `shikigami-server/src/Shikigami/Server/Command/StubKawa.hs`; core's fixture comment explicitly forbids a dependency on the server package.

- Observation: Plan 37 shipped `SecretText`, `CredentialRef`, the flat strict `AppConfig`, explicit environment bindings, and redacted diagnostics, but deliberately left `credentials.sinks.*.token` and HTTP byte limits to this plan. The old draft's `CredentialValue` type does not exist.
  Evidence: `Shikigami.App.Config` documents `SecretText` and `CredentialRef`; plan 37's Decision Log assigns the sink credential and byte-limit keys to plan 22.

- Observation: The authoritative package registry currently lists `http-client` 0.7.19, `http-client-tls` 0.4.0, and `servant-client` 0.20.3.0. Mori located their sources at `mori://snoyberg/http-client` and `mori://haskell-servant/servant`; upstream tags confirm those releases. The existing project already selects Servant 0.20.x through its package bounds and Danwa source pin.
  Evidence: `cabal list --simple-output`, upstream `git ls-remote --tags`, `mori registry show ... --full`, and `cabal.project`.


## Decision Log

- Decision: Ship static per-sink tokens first, behind a `TokenSource` interface
  (`fetchToken :: IO (Either CredentialFailure BearerToken)`), and defer shomei-issued
  service tokens to a later swap of the `TokenSource` implementation.
  Rationale: Verified against `mori://shinzui/shomei`: the claims model already carries capability scopes (`AuthClaims` with `scopes :: Set Scope`, `roles`, and the `act` actor claim in project-relative `shomei-core/src/Shomei/Domain/Claims.hs`), signing and verification exist in `shomei-jwt/src/Shomei/Jwt/Sign.hs` and `Verify.hs`, but the only issuance path in `shomei-core/src/Shomei/Workflow/Session.hs` builds tokens with `scopes = Set.empty` — identity, not capability. Scoped service-token issuance is the Shomei repository's IR-2 in project-relative `docs/initial-spec.md`; an artifact-level URI is pending Mori coverage. Designing the interface now and implementing static-first means zero Shikigami client churn when it ships.
  Date: 2026-07-08

- Decision: Tokens live only in a boot-time `SinkHttp`/`TokenSource` value, never in the `KawaConfig`/`KizashiConfig`/`DanwaConfig` records (`shikigami-core/src/Shikigami/Sink/Config.hs:12-31`).
  Rationale: `DanwaConfig` derives `ToJSON`/`FromJSON` (Config.hs:30-31) and sink intents are serialized into the transactional outbox as JSON (`SinkIntent` in `Shikigami/Agent/Workflow.hs:96-106`); putting a secret in a config record is one derived instance away from persisting it in the database or printing it in a log. `BearerToken` has a private constructor and no `Show` or JSON instances, so the type system keeps secrets out of every serialization path.
  Date: 2026-07-08

- Decision: Two TLS-capable managers at boot — one shared manager used by `postJSON` for kawa
  and kizashi, and one danwa manager whose request hook injects the danwa bearer header and
  whose response hook enforces the same body limit. Both are created once at process start;
  redirects are disabled so credentials cannot be replayed to a redirect target.
  Rationale: kawa/kizashi requests are built by our own code, so `postJSON` can add the header explicitly per request from its `HttpEnv`. The danwa path goes through `mori://shinzui/danwa/packages/danwa-client`; its project-relative `danwa-client/src/Danwa/Client.hs` helper builds requests internally and allocates a fresh unauthenticated `Manager` on every operation. Rather than patching Danwa, Shikigami builds its own `ClientEnv` (`mkClientEnv`) over a manager whose `managerModifyRequest` adds the header; that hook is the supported http-client seam for exactly this. It also fixes the per-operation manager allocation on the sink path.
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

- Decision: Refresh the plan onto the current package boundaries: the reusable auth and
  HTTP client types remain in `shikigami-core`; worker construction and boot diagnostics
  live in `shikigami-workers`; production `stub-kawa` enforcement lives in
  `shikigami-server`; core tests use their package-local fixture rather than importing the
  server.
  Rationale: Cabal package direction is enforced by `Shikigami.PackageArchitectureSpec`,
  and `docs/adr/0003-a-seventh-package-keeps-one-off-agent-runs-light.md` records the current
  seven-package architecture. Moving the production listener back into core would reverse
  the dependency arrow.
  Date: 2026-08-23

- Decision: Reuse plan 37's `SecretText` as the resolved static credential value and
  convert it once with `credentialToken`; retain `CredentialRef` only in typed token-source
  failures and future provider-backed sources. Add optional `SecretText` fields to
  `AppConfig` for the three sink tokens and validated `ByteLimit` fields for HTTP request
  and response limits.
  Rationale: Settei already owns secret sensitivity, redaction, source precedence, and the
  only intentional plaintext escape hatch (`revealSecretText`). Inventing the draft-only
  `CredentialValue` wrapper would duplicate that boundary without adding protection.
  Date: 2026-08-23

- Decision: Treat plan 37's remaining `shikigami-migrate` package-cycle item as unrelated,
  not as a blocker for this plan.
  Rationale: the application declaration, source ordering, secret redaction, environment
  bindings, and worker/server composition APIs this work consumes are complete and tested;
  sink authentication does not import or modify the migration runner.
  Date: 2026-08-23

- Decision: Apply the current Haskell Jitsurei standards to every new type and module:
  GHC2024 imports use postpositive `qualified`; records have strict, unprefixed fields and
  explicit deriving strategies; record updates use generic-lens rather than `{ ... }`
  update syntax; the generic-lens orphan is imported only in modules that use `#field`;
  and production `stub-kawa` reuses Shikigami's existing RFC 9457 problem response for
  HTTP 401.
  Rationale: These are the repository-wide rules in
  `mori://shinzui/haskell-jitsurei/docs/core-standards`,
  `mori://shinzui/haskell-jitsurei/docs/core-record-patterns`, and
  `mori://shinzui/haskell-jitsurei/docs/api-rfc9457-problem-details`. Shikigami already
  implements the problem catalog in `shikigami-api/src/Shikigami/Api/Problem.hs` and the
  one WAI renderer in `shikigami-server/src/Shikigami/Server/App.hs`; a stub-specific
  plaintext 401 would create a second error dialect.
  Date: 2026-08-23


## Outcomes & Retrospective

(To be filled during and after implementation.)


## Context and Orientation

Repository layout: `shikigami-core` owns reusable runtime and sink-client code;
`shikigami-server` owns the public server, the `shikigami` administrative executable, and
the production `stub-kawa` listener; `shikigami-workers` owns `shikigami-worker` and the
supervised publisher/run loops; `shikigami-api`, `shikigami-client`,
`shikigami-migrations`, and `shikigami-agent` complete the seven-package tree. Build and
test inside `nix develop` at the repo root with `cabal build all` and `cabal test all`.

Terms. A "sink" is a delivery target declared on an agent (kawa digest / kizashi signal / rei action / danwa conversation). A "bearer token" is an opaque credential sent as the HTTP header `Authorization: Bearer <token>`; the eventual issuer is shomei (the platform's auth service), which signs JWTs whose scopes the receiving service checks. A "Manager" is http-client's connection pool object; creating one is comparatively expensive and is meant to be done once per process, not per request.

The outbound HTTP paths at the 2026-08-23 audit are all unauthenticated:

- `Shikigami.Sink.Http.postJSON :: ToJSON a => Text -> a -> IO (Either Text LBS.ByteString)` in `shikigami-core/src/Shikigami/Sink/Http.hs` posts JSON, sends only `content-type`, allocates `newManager defaultManagerSettings` per call, and reads the whole response with `httpLbs`. `Shikigami.Sink.KawaClient.postEnvelope` and `Shikigami.Sink.KizashiClient.postSignal` call it.
- `Shikigami.Sink.Danwa.postReply` and `postToFreshConversation` call `Danwa.Client.runDanwa`. The Mori-registered package `mori://shinzui/danwa/packages/danwa-client` implements that helper by parsing the URL and allocating `newManager defaultManagerSettings` for every operation. `shikigami-server/src/Shikigami/Server/Command/DanwaSpike.hs` is a development spike and may keep the upstream convenience runner.
- Endpoint configuration remains base-URL-only in `shikigami-core/src/Shikigami/Sink/Config.hs`, while process values are declared in the flat `Shikigami.App.Config.AppConfig`.

Where requests are issued from: `Shikigami.Sink.dispatch` routes each granted sink through
`Shikigami.Sink.Types.SinkContext`. `Shikigami.Agent.Workflow.publishSinkIntent` builds that
context from `AgentRunDeps`; `shikigami-workers/src/Shikigami/Workers/Config.hs` builds
`AgentRunDeps` from `WorkerEnv`; and
`shikigami-workers/src/Shikigami/Workers/Command/Worker.hs` constructs `WorkerEnv` once at
boot. The process-lifetime value therefore flows: worker composition root → `WorkerEnv` →
`AgentRunDeps` → `SinkContext` → client call. This is the threading path for `SinkHttp`.

The production stub doorway belongs to `shikigami-server`:
`Shikigami.Sink.KawaStub.runStubKawa` serves an idempotent Warp application at
`POST /v1/sources/{source}/events`, and `Shikigami.Server.Command.StubKawa` composes it from
`AppConfig`. Its current `StubKawaOptions` has `port`, `republishTopic`, and `broker` fields.
The core test package cannot import that listener, so
`shikigami-core/test/Shikigami/Fixture/KawaStub.hs` provides a deliberately minimal recording
doorway fixture.

Existing test idioms this plan reuses: `shikigami-core/test/Main.hs` and focused spec modules
start Warp applications with `testWithApplication`; the core package can test header injection,
limits, redirects, failure classification, and the fixture doorway. Production
`stubKawaApplication` enforcement is tested in `shikigami-server-test`, which already owns the
server package. `cabal test all` runs both suites.

Relevant durable decisions: `docs/adr/0022-the-journal-ends-at-enqueue-and-receipts-own-delivery-truth.md`
requires the publisher to distinguish terminal non-sends from retryable failure and makes the
delivery receipt the downstream truth; this plan's permanent/transient HTTP classification feeds
that contract. `docs/adr/0020-readiness-covers-only-what-restarting-can-fix.md` says downstream
HTTP health is not readiness, so these managers do not add sink probes. The package ownership
refresh follows `docs/adr/0003-a-seventh-package-keeps-one-off-agent-runs-light.md`. No existing
ADR owns outbound credential representation or HTTP client policy; this plan must create one at
completion if those decisions remain durable.

Applicable implementation standards are
`mori://shinzui/haskell-jitsurei/docs/core-standards`,
`mori://shinzui/haskell-jitsurei/docs/core-custom-prelude`,
`mori://shinzui/haskell-jitsurei/docs/core-record-patterns`, and
`mori://shinzui/haskell-jitsurei/docs/api-rfc9457-problem-details`. The Servant route-design
standard is not triggered because this plan consumes Danwa's generated client and changes no
Shikigami API route type. The request-logging standard reinforces the security rule: never log
`Authorization`, request bodies, or arbitrary headers.

Relationship to sibling plans: plan 21 is already complete, and its `GrantSource` fields are part
of the constructors this plan edits; preserve them. Plan 19 is complete and supplies
`PermanentFailure`/`Failed` plus the Keiro terminal mapping. Plan 23 is complete and adds directory
fields that must also be preserved. `docs/plans/32-channel-egress-sink-through-kanmon.md` will add
a kanmon client that must use this plan's `HttpEnv`/`TokenSource` machinery.


## Plan of Work

### Milestone 1 — shared manager, timeouts, and an auth-aware `postJSON`

Scope: stop building a `Manager` per request, bound every request with a timeout, and make `postJSON` capable of injecting a bearer header. At the end, kawa and kizashi clients compile against the new signature and all existing tests pass with a token-less `HttpEnv`.

Create `shikigami-core/src/Shikigami/Sink/Auth.hs` as the exposed safe API and
`shikigami-core/src/Shikigami/Sink/Auth/Internal.hs` as an `other-modules`
implementation module. The public module re-exports `BearerToken` without its constructor
and exposes only operations that cannot render it. The internal module owns the constructor
and the one `Authorization` rendering function used by the core HTTP layer.

```haskell
module Shikigami.Sink.Auth
  ( BearerToken,
    CredentialFailure (..),
    CredentialFailureReason (..),
    TokenSource (..),
    credentialToken,
    staticTokenSource,
    matchesBearerHeader,
  )
where

import Shikigami.App.Config (CredentialRef, SecretText)

-- | An opaque bearer credential. The constructor is private and the type has
-- no Show, Read, ToJSON, or FromJSON instance.
newtype BearerToken = BearerToken Text
  deriving stock (Generic, Eq)

credentialToken :: SecretText -> BearerToken

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

-- Safe for the server-owned stub: compares an already-received header without
-- returning or rendering the token. The implementation uses a constant-time
-- byte comparison.
matchesBearerHeader :: BearerToken -> ByteString -> Bool

-- renderAuthHeader lives only in Auth.Internal and is used by the core request
-- builder. No server, worker, test diagnostic, or serializable type receives it.
```

Milestone 2 adds `ByteLimit` plus the validated `http.request_max_bytes` and
`http.response_max_bytes` settings to `Shikigami.App.Config`; Milestone 1 uses
smart-constructed limits while the client layer is built. Rework
`shikigami-core/src/Shikigami/Sink/Http.hs`:

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
secret type cannot be rendered. `HttpFailure` is a typed permanent/transient sum with safe
reasons and a `renderHttpFailure` function; callers never parse its prose. Set
`redirectCount = 0` and a no-throw status checker on the request, then classify every 3xx
as a permanent unexpected-response failure so the authorization header is never forwarded to
a redirect target.
Encode the request once and reject it before network IO if it exceeds `requestBytes`. Read
the response through a streaming/bounded http-client path, abort after `responseBytes + 1`,
and never construct an unbounded lazy body. Tests cover exact-boundary and one-byte-over
request/response cases.

Rewire the two callers: `postEnvelope :: HttpEnv -> KawaConfig -> ActivityEnvelope -> IO
(Either KawaError Text)` and `postSignal :: HttpEnv -> KizashiConfig -> CreateSignalReq -> IO
(Either KizashiError SignalResponse)` gain the leading `HttpEnv` parameter and preserve the
typed failure class from `postJSON`. `KawaError` and `KizashiError` distinguish HTTP failure
from response decoding. Their call sites select the `kawa` or `kizashi` field from the
`SinkHttp` bundle carried directly by `SinkContext`; tests build token-less environments with
per-test managers and explicit `HttpLimits`.
Preserve `HttpFailure` through client-specific errors. At the sink boundary, map permanent
failures to plan 19's additive `PermanentFailure` and transient failures to the existing
`Failed`; plan 19 maps those to Keiro `PublishRejected`/`PublishFailed`.

Acceptance: `cabal test all` green (existing kawa/kizashi/danwa dispatch tests unchanged in behavior); `grep -n "newManager" shikigami-core/src/Shikigami/Sink/Http.hs` shows it only inside `newSinkManager`.

### Milestone 2 — Settei credential configuration and threading

Scope: resolve per-sink secret settings once in plan 37's Settei composition root
and thread a `SinkHttp` bundle along the existing config path. At the end, the worker
logs presence only and requests carry the header.

Extend `shikigami-core/src/Shikigami/App/Config.hs` with optional `SecretText` fields
`kawaToken`, `kizashiToken`, and `danwaToken`; validated `ByteLimit` fields
`httpRequestMaxBytes` and `httpResponseMaxBytes`; secret settings
`credentials.sinks.<name>.token`; explicit legacy environment bindings
`SHIKIGAMI_<NAME>_TOKEN`; and the two public byte-limit settings. Limits default to 8 MiB,
accept 1 KiB through 64 MiB, and expose a smart constructor plus a safe numeric accessor.
Update `Shikigami.AppConfigSpec` to pin schema order, bindings, bounds, source precedence,
and redaction. The optional static credentials preserve the current no-auth development
default; a configured source is fail-closed at request time.

Add the following process-lifetime bundle to `Shikigami.Sink.Http`:

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

credentialsFromConfig :: AppConfig -> SinkCredentials
newSinkHttp :: HttpLimits -> SinkCredentials -> DanwaConfig -> IO (Either SinkHttpError SinkHttp)
```

`credentialsFromConfig` is pure and cannot fail after Settei resolution: it converts each
`Maybe SecretText` through `credentialToken` and `staticTokenSource`. `newSinkHttp` builds
the shared manager and Danwa client environment,
returning a typed startup error if the Danwa base URL cannot be parsed. Thread `SinkHttp`
through the current strict records `WorkerEnv`, `AgentRunDeps`, and `SinkContext`, preserving
all fields delivered by plans 19, 21, 23, 28, and 56–59.

At `shikigami-workers/src/Shikigami/Workers/Command/Worker.hs`, build the credentials,
limits, and `SinkHttp` after configuration succeeds and before starting any loop. A startup
construction error is logged by safe category and exits before work begins. Log one structured
boot line with `kawa`, `kizashi`, and `danwa` presence as `"token"` or `"none"`, never values.

Acceptance: `cabal build all`; `--explain-config` shows a redacted winning source for the
kawa token, the worker log reports only presence, and a planted value is absent from all
diagnostics. Production modules contain no direct environment read.

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

`shikigami-server/src/Shikigami/Sink/KawaStub.hs` changes
`StubKawaOptions` to gain `requireToken :: !(Maybe BearerToken)` and
`stubKawaApplication` to accept the same value. `Shikigami.Server.Command.StubKawa` converts
the already-resolved optional `AppConfig.kawaToken` at the command composition root. When
enforcement is configured, `stubKawaApplication` uses `matchesBearerHeader` before body
handling. A mismatch returns `Shikigami.Server.App.problemResponse Unauthorized` with the
existing RFC 9457 `application/problem+json` shape and logs only
`[stub-kawa] rejected: missing/invalid token`. Do not add a raw-token command-line option.

Put reusable client tests in a focused `shikigami-core/test/Shikigami/SinkAuthSpec.hs`
registered in `shikigami-core.cabal` and `test/Main.hs`. Put production stub enforcement
tests in `shikigami-server-test`, where importing `Shikigami.Sink.KawaStub` respects package
direction:

1. Header injection: a recording Warp stub captures request headers; use a test-only smart
   constructor to build a `BearerToken`, then `staticTokenSource token`. The request contains
   the expected authorization bytes; `Nothing` sends no header. No failure output renders the
   token.
2. Enforcement: production `stubKawaApplication` with the same opaque token accepts the
   matching `HttpEnv`; with no token it returns HTTP 401, the shared problem media type/body,
   and records no ingest.
3. Token fetch failure: a `TokenSource` returning a typed `CredentialFailure` makes
   `postJSON` return the corresponding transient `HttpFailure` without the stub receiving any
   request or rendering backend error text.
4. Non-renderability: the exposed API omits the constructor and every render operation;
   `shikigami-core`'s package-boundary test pins `Auth.Internal` as non-exposed. The planted
   secret is absent from all rendered failures and config diagnostics. Haskell cannot write a
   positive runtime assertion that a typeclass instance does not exist, so the API boundary and
   compile-time consumer fixture are the proof.
5. Limits and redirects: kawa/kizashi and servant-based danwa tests cover exact-boundary and
   one-byte-over request/response bodies; a 3xx target receives no follow-up request or
   authorization header.

Acceptance: `cabal test all` is green across core and server, including the new groups.

### Milestone 5 — the shomei seam (design shipped as types + docs, no shomei calls yet)

Scope: make the future swap mechanical. `TokenSource` already is the seam; this milestone
adds the documentation shim so a later implementer needs no archaeology. In
`Shikigami.Sink.Auth`, add a Haddock section stating: when Shomei's scoped service-token
issuance request ships (`mori://shinzui/shomei` together with the project-relative request
`docs/initial-spec.md`, IR-2, lines 889-900; an artifact-level URI is pending Mori coverage),
implement `shomeiTokenSource :: ShomeiTokenConfig -> IO TokenSource` in a new module. It
requests a service token with the sink's scope (for example `kawa:ingest` or `signal:raise`),
caches the `BearerToken` with its expiry in an `MVar`, refreshes ahead of expiry inside
`fetchToken`, and never exposes the raw JWT beyond the internal authorization-header renderer.
The verified service-side building block is `signAccessToken` under the Shomei project; the
future client package is `mori://shinzui/shomei/packages/shomei-client`. Record in this plan's
Decision Log when the swap happens.

Acceptance: haddock present; `cabal build all` clean.


## Concrete Steps

All from the repo root `/Users/shinzui/Keikaku/bokuno/shikigami`, inside `nix develop`.

```bash
nix develop --command cabal build all
nix develop --command cabal test all
```

End-to-end transcript (after Milestone 4). Terminal A:

```bash
cabal run shikigami -- --config config/stub-kawa-auth.yaml stub-kawa --port 8088
```

Terminal B — unauthenticated delivery fails loudly (expect the outbox publisher to log a
failed publish with `HTTP 401`, and stub-kawa to log a rejection). The checked config file
contains the database, agent directory, and sink URLs but intentionally omits
`credentials.sinks.kawa.token`:

```bash
cabal run shikigami-worker -- --config config/worker-auth-missing.yaml
cabal run shikigami -- --config config/operator-dev.yaml enqueue-run heartbeat --payload '{}'
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
errors, diagnostics, database rows, or JSON, and production code cannot render it; (4)
configured token-source failure issues no request; (5) exact-limit bodies succeed and
one-byte-over bodies fail before unbounded allocation or dispatch; (6) redirects are not
followed with credentials; and (7) the full suite passes with process-lifetime manager paths
and bounded timeouts.


## Idempotence and Recovery

This plan adds explicit `SHIKIGAMI_KAWA_TOKEN`, `SHIKIGAMI_KIZASHI_TOKEN`, and
`SHIKIGAMI_DANWA_TOKEN` bindings to plan 37's one binding table, so rollout supports both
existing environment deployment practice and file/secret sources. No sink or command module
reads those names directly, and no credential value is admitted to serializable sink config.

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

Dependency changes: `http-client` and `http-types` are already direct core dependencies. Add
`http-client-tls >=0.4 && <0.5` and `servant-client >=0.20 && <0.21` to
`shikigami-core`; add test-only dependencies only where compilation proves they are direct.
The 2026-08-23 registry audit verified Hackage releases `http-client` 0.7.19,
`http-client-tls` 0.4.0, and `servant-client` 0.20.3.0 against upstream tags after Mori
located `mori://snoyberg/http-client`, `mori://haskell-servant/servant`, and
`mori://shinzui/danwa/packages/danwa-client`. No new external service is required.

Signatures that must exist at the end (full module paths):

```haskell
-- shikigami-core : Shikigami.Sink.Auth (new)
newtype BearerToken = BearerToken Text          -- private constructor; no Show/Read/JSON
data CredentialFailure = CredentialFailure
  { reference :: !CredentialRef, reason :: !CredentialFailureReason }
newtype TokenSource = TokenSource {fetchToken :: !(IO (Either CredentialFailure BearerToken))}
credentialToken :: SecretText -> BearerToken
staticTokenSource :: BearerToken -> TokenSource
matchesBearerHeader :: BearerToken -> ByteString -> Bool
-- Auth.Internal only: renderAuthHeader :: BearerToken -> ByteString
data SinkCredentials = SinkCredentials
  { kawa, kizashi, danwa :: !(Maybe TokenSource) }
credentialsFromConfig :: AppConfig -> SinkCredentials
data SinkHttp = SinkHttp
  { kawa :: !HttpEnv, kizashi :: !HttpEnv, danwa :: !ClientEnv }
newSinkHttp :: HttpLimits -> SinkCredentials -> DanwaConfig -> IO (Either SinkHttpError SinkHttp)

-- shikigami-core : Shikigami.Sink.Http
data HttpLimits = HttpLimits {requestBytes :: !ByteLimit, responseBytes :: !ByteLimit}
data HttpEnv = HttpEnv
  { manager :: !Manager, token :: !(Maybe TokenSource), limits :: !HttpLimits }
newSinkManager :: IO Manager -- TLS-capable; timeout set once
data HttpFailure = PermanentHttpFailure ... | TransientHttpFailure ...
renderHttpFailure :: HttpFailure -> Text
postJSONWithHeaders :: (ToJSON a) => HttpEnv -> [(HeaderName, ByteString)] -> Text -> a -> IO (Either HttpFailure LBS.ByteString)
postJSON :: (ToJSON a) => HttpEnv -> Text -> a -> IO (Either HttpFailure LBS.ByteString)

-- shikigami-core : Shikigami.Sink.KawaClient
postEnvelope :: HttpEnv -> KawaConfig -> ActivityEnvelope -> IO (Either KawaError Text)

-- shikigami-core : Shikigami.Sink.KizashiClient
postSignal :: HttpEnv -> KizashiConfig -> CreateSignalReq -> IO (Either KizashiError SignalResponse)

-- shikigami-core : Shikigami.Sink.Danwa
runDanwa :: ClientEnv -> DanwaConfig -> AgentIdentity -> Maybe DanwaTarget -> Sink -> Value -> IO (Either DanwaError Text)

-- shikigami-server : Shikigami.Sink.KawaStub
data StubKawaOptions = StubKawaOptions
  { port :: !Int, republishTopic :: !(Maybe Text), broker :: !(Maybe Text),
    requireToken :: !(Maybe BearerToken) }
stubKawaApplication :: IORef (Map (Text, Text) Text) -> Maybe Republisher -> Maybe BearerToken -> Application

-- shikigami-core : Shikigami.Sink.Types / Shikigami.Agent.Workflow
-- shikigami-workers : Shikigami.Workers.Config
-- SinkContext, AgentRunDeps, WorkerEnv each gain: http :: !SinkHttp

-- shikigami-core : Shikigami.App.Config
newtype ByteLimit = ByteLimit Int             -- private constructor
mkByteLimit :: Int -> Either Text ByteLimit
byteLimitBytes :: ByteLimit -> Int
-- AppConfig gains optional SecretText kawaToken/kizashiToken/danwaToken and
-- total ByteLimit httpRequestMaxBytes/httpResponseMaxBytes fields.
```

Soft landing dependency: plan 16 settles the sink-client/request shapes this plan wraps.
Consumers: plan 14 uses
`SinkHttp` for authenticated approval asks; plan 28 passes `traceparent` through
`postJSONWithHeaders`; plan 32 extends `SinkCredentials`/`SinkHttp` with kanmon and
uses the same helper. Plan 21 touches the same record constructors but is semantically
independent.


## Revision Notes

- 2026-08-23: Refreshed the plan before implementation against the current seven-package
  tree. Moved worker and production-stub work to `shikigami-workers` and
  `shikigami-server`, reused plan 37's delivered `SecretText`/Settei composition boundary,
  added the missing byte-limit configuration work, updated Danwa and HTTP dependency facts
  from Mori plus authoritative release sources, incorporated ADRs 0003/0020/0022/0024, and
  made the applicable Haskell Jitsurei core/record/RFC 9457 standards explicit. The security
  outcome and five-milestone structure remain unchanged.

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
