---
id: 89
slug: authenticate-public-api-callers-with-configured-bearer-credentials
title: "Authenticate public API callers with configured bearer credentials"
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
      at: 2026-10-25T23:22:58Z
      mode: "implement"
      note: "Implement bearer authentication at the public vertical mount"
---

# Authenticate public API callers with configured bearer credentials

This ExecPlan is a living document. The sections Progress, Surprises & Discoveries,
Decision Log, and Outcomes & Retrospective must be kept up to date as work proceeds.
If durable project context changes, update or create ADRs in docs/adr/ in the same change.

This plan is a child of
`docs/masterplans/15-expose-declared-agents-and-agent-runs-over-the-public-http-api.md`. Read
its Integration Points section before starting.


## Purpose / Big Picture

The public HTTP API has no notion of who is calling. That is acceptable while it serves only
health probes; it is not acceptable once it serves agent declarations and, in the next plan,
starts agent runs. After this plan every route that is not a health probe sits behind a bearer
credential: a request without a valid `Authorization: Bearer <token>` header answers
`401 application/problem+json` with code `unauthorized` and a `WWW-Authenticate` header, and
never reveals whether the token was absent, malformed, or wrong. The credential is configured
through the same Settei declaration as every other setting (`http.auth.mode` and
`http.auth.token`), is redacted in every diagnostic, and is compared in constant time. The
OpenAPI document publishes the `bearer` security scheme so a generated client knows to send
it, and `shikigami-client` carries a token from `--token` or `SHIKIGAMI_API_TOKEN`.

You can see it working by starting the server with `--set http.auth.mode=bearer` and a token,
observing that `curl http://127.0.0.1:8080/agents` answers 401 while
`curl -H 'Authorization: Bearer <token>' http://127.0.0.1:8080/agents` answers 200, and that
`curl http://127.0.0.1:8080/health/live` answers 200 with no header at all.

This plan authenticates callers; it does not authorize them. Which caller may run which agent
remains the Kikan contract described in
[ADR 0036](../adr/0036-external-agent-actions-require-fresh-exact-authorization.md), and the
verifier is built as a seam so that a Shomei- or En-issued service token can replace the static
credential without touching the routes.


## Progress

- [x] M1: The `Authenticated` combinator, the `ApiCaller` principal, and the OpenAPI security
      scheme exist in `shikigami-api`; the regenerated `docs/api/openapi.json` carries
      `components.securitySchemes.bearer`, a `bearer` security requirement and a 401 response on
      every operation outside `/health`, and none on the health probes.
- [x] M2: `http.auth.mode`, `http.auth.token`, and `http.auth.caller` are declared; the server
      refuses to start in bearer mode without a token; the verifier admits a correct token,
      rejects a missing or wrong one with the 401 problem, and in disabled mode admits every
      request as `anonymous`; the request log never contains the header.
- [x] M3: `shikigami-client --token` and `SHIKIGAMI_API_TOKEN` work for every non-health
      command; `tests/hurl/run.sh` starts the server in bearer mode and `tests/hurl/auth.hurl`
      proves the 401 and 200 paths; every protected block in the other hurl files carries the
      header; the configuration document describes the three keys.


## Surprises & Discoveries

(None yet.)


## Decision Log

- Decision: Use Servant's `AuthProtect "shikigami-bearer"` as the combinator rather than a
  hand-written one.
  Rationale: `servant-server` supplies `HasServer` through a context-registered `AuthHandler`
  and `servant-client-core` supplies `HasClient` through `AuthenticatedRequest`, so only the
  OpenAPI instance has to be written; the shomei reference implementation
  (`mori://shinzui/shomei`, `shomei-servant/src/Shomei/Servant/Auth.hs`) hand-writes its
  combinator because it also threads cookies and CSRF, which this API does not need.
  Date: 2026-10-22

- Decision: Authentication is applied at the vertical mount in `ShikigamiApi` (the `agents`
  field) rather than on each inner field.
  Rationale: the fleet standard prefers per-field placement so that a future public route in
  the same record is not accidentally protected; here the intent is the opposite, every route
  under `/agents` is protected and must stay so, and the health vertical is the only public one.
  Date: 2026-10-22

- Decision: `http.auth.mode` defaults to `disabled`, and the server logs a warning at boot when
  authentication is disabled while binding a non-loopback interface.
  Rationale: the development default binds `127.0.0.1` and must keep working with no token; a
  production configuration that binds `*` without a credential is almost certainly a mistake and
  the log line names it without refusing to start.
  Date: 2026-10-22


## Outcomes & Retrospective

Completed 2026-10-25. The protected mount, typed credential client, documented
bearer security scheme and 401 response are integrated. API, server, client and
core unit suites pass. Assembled-application tests prove byte-identical missing,
wrong, malformed and duplicate-header refusals, valid-token admission, disabled
mode and public health. Existing request-log secret coverage includes Authorization.
Configuration inspection refuses bearer mode without `http.auth.token` and accepts
a valid token without opening the database. The Hurl suite passes 15 requests;
its live client checks prove both `--token` and environment fallback. ADR 0047
records the verifier boundary and the standalone client's environment exception.
Validation uses the existing isolated project as recorded in EP-1.


## Context and Orientation

The public API is the named-routes record `ShikigamiApi` in `shikigami-api/src/Shikigami/Api.hs`;
its module comment states the conventions (one field per vertical, `MultiVerb` terminals,
`RespondAs ProblemJSON` errors). The server turns it into a WAI application in
`shikigami-server/src/Shikigami/Server/App.hs` with `genericServeTWithContext`, passing a
Servant *context*, a heterogeneous list of values that combinators may look up; today it holds
only the problem-details error formatters. Handlers run in `ServerM` from
`shikigami-server/src/Shikigami/Server/Seam.hs`, and a handler aborts with `throwProblem`,
which renders the single RFC 9457 body defined in `shikigami-api/src/Shikigami/Api/Problem.hs`.
The problem catalog already has an `Unauthorized` code (401, not retryable, title
"Unauthorized").

A *bearer credential* is a secret string sent as `Authorization: Bearer <token>`. Shikigami
already handles such credentials on the outbound side:
`shikigami-core/src/Shikigami/Sink/Auth.hs` exports the opaque `BearerToken` (no `Show`, no
JSON), `credentialToken :: SecretText -> BearerToken`, and `matchesBearerHeader :: BearerToken
-> ByteString -> Bool`, a constant-time comparison of a received header against the expected
`Bearer <token>` rendering. The two test stubs in `shikigami-server/src/Shikigami/Sink/KawaStub.hs`
and `KanmonStub.hs` use exactly that function to check inbound headers, and
[ADR 0026](../adr/0026-outbound-sink-credentials-stay-opaque-and-http-policy-lives-at-the-process-boundary.md)
records why the token never acquires a rendering or serialization instance. This plan reuses
those pieces unchanged.

Configuration is one Settei declaration in `shikigami-core/src/Shikigami/App/Config.hs`.
Secrets are declared with `secretSetting` and decoded into `SecretText`, whose only exit is
`revealSecretText` (see `kawaTokenSetting` for the shape, including its environment-variable
binding). Enumerated settings decode a fixed vocabulary (see `schedulerCatchUpSetting`), and a
conditional requirement, a key required only when another key selects it, is modelled by
`directorySettingsConfig`. Role-specific required keys are listed by `roleRequiredKeys`, and
`missingRequirements` reports them under `--check-config` before any resource opens. The
operator-facing description of all of this is `docs/operations/configuration.md`.

Servant's generalized authentication: `Servant.API.Experimental.Auth.AuthProtect tag` is a
combinator; the server interprets it through an `AuthHandler Request a` placed in the context
(`Servant.Server.Experimental.Auth.mkAuthHandler`), and the type family instance
`AuthServerData (AuthProtect tag) = a` names the value the handler receives; the client
interprets it through `Servant.Client.Core.AuthenticatedRequest` built with
`mkAuthenticatedRequest`. `servant-openapi-hs` at the pinned release has no `HasOpenApi`
instance for `AuthProtect`, so one must be written; `Data.OpenApi` (package `openapi-hs`,
source at `mori://shinzui/openapi-hs`) provides `SecurityScheme`, `SecuritySchemeHttp`,
`HttpSchemeBearer`, `SecurityRequirement`, and the `allOperations` traversal used to add a
requirement and a response to every operation. The request log in
`shikigami-server/src/Shikigami/Server/RequestLog.hs` logs method, path, status, and trace
ids and must never log headers; its test is `shikigami-server/test/Shikigami/Server/RequestLogSpec.hs`.

The black-box suite is `tests/hurl/run.sh`, which starts a disposable PostgreSQL, migrates it,
starts the built server with `PG_CONNECTION_STRING`, waits for readiness, and runs
`hurl --test --variable base_url=... tests/hurl/*.hurl`. The fleet standard for it is
`mori://shinzui/haskell-jitsurei/docs/api-hurl-integration-testing`.

Relevant ADRs: ADR 0026 above (opaque credential, constant-time compare, redaction);
[ADR 0020](../adr/0020-readiness-covers-only-what-restarting-can-fix.md), which is why the
health probes stay outside authentication (a probe that needs a credential is a probe the
supervisor cannot run); and [ADR 0036](../adr/0036-external-agent-actions-require-fresh-exact-authorization.md),
which is why authorization is not attempted here. The fleet's problem-details standard
`mori://shinzui/haskell-jitsurei/docs/api-rfc9457-problem-details` requires that
security-equivalent failures be indistinguishable, which fixes the single 401 body below.


## Plan of Work

### Milestone 1: the contract

Create `shikigami-api/src/Shikigami/Caller/Api.hs`:

```haskell
type Authenticated = AuthProtect "shikigami-bearer"

-- | Who is calling, as far as the server can tell. One configured credential
-- maps to one caller label; a later issuer-backed verifier fills in a real
-- principal here without changing any route.
newtype ApiCaller = ApiCaller { callerId :: Text }

bearerSchemeName :: Text   -- "bearer"
```

In the same module write the orphan `HasOpenApi (AuthProtect "shikigami-bearer" :> api)`
instance (with `OPTIONS_GHC -Wno-orphans` and a comment naming the missing upstream instance):
it takes the sub-API's document, registers the `bearer` HTTP security scheme under
`components.securitySchemes`, sets a `bearer` security requirement on every operation, and adds
a 401 response described as "Missing or invalid bearer credential" with the
`application/problem+json` media type and the `ProblemDetails` schema reference. `AuthProtect`
already has a `HasLink` instance in servant.

Change the field in `Shikigami.Api` to `agents :: mode :- Authenticated :> "agents" :>
NamedRoutes AgentApi`. If `docs/plans/88-serve-the-declared-agent-catalog-over-http.md` has not
landed yet, prove the instances against a test-only record in the server test suite and finish
this step when the mount exists; do not add a temporary route to the real record.

Regenerate `docs/api/openapi.json` and extend `shikigami-api/test/Shikigami/Api/OpenApiSpec.hs`
with three assertions: the security scheme exists and is `http`/`bearer`; every operation whose
path does not start with `/health` has exactly the `bearer` requirement and a 401 response; the
two health operations have no security requirement.

### Milestone 2: configuration and the verifier

In `Shikigami.App.Config` add:

```haskell
data HttpAuthSettings
  = AuthDisabled
  | AuthBearer { token :: !SecretText, caller :: !Text }
```

declared from `http.auth.mode` (`disabled` or `bearer`, default `disabled`), `http.auth.token`
(a `SecretText`, bound to the environment variable `SHIKIGAMI_API_TOKEN`, required when the mode
is `bearer`, rejected when shorter than sixteen characters), and `http.auth.caller` (text,
default `api-caller`), following the conditional shape of `directorySettingsConfig`. Add the
field `httpAuth :: HttpAuthSettings` to `AppConfig`. Make the conditional requirement visible
to `--check-config` so that `--set http.auth.mode=bearer` without a token fails with the key
named, and extend `shikigami-core/test/Shikigami/AppConfigSpec.hs` for the three keys, the
minimum length, and redaction in `--explain-config`.

Create `shikigami-server/src/Shikigami/Caller/Verifier.hs`:

```haskell
type instance AuthServerData Authenticated = ApiCaller

newCallerVerifier :: Log.Logger -> HttpAuthSettings -> AuthHandler Request ApiCaller
```

In bearer mode the handler reads the `Authorization` header, compares it with
`matchesBearerHeader (credentialToken token)`, and on success returns `ApiCaller caller`. On a
missing, malformed, or mismatched header it logs `server.auth.rejected` with a `reason` of
`missing` or `invalid` and nothing else, and throws `problemServerError Unauthorized "A valid
bearer token is required."` with an added `WWW-Authenticate: Bearer realm="shikigami"` header.
The body and status are identical for every rejection. In disabled mode it returns
`ApiCaller "anonymous"` without reading headers. Put the type family instance here, with
`OPTIONS_GHC -Wno-orphans` if GHC objects, because `shikigami-api` does not depend on
`servant-server`.

In `Shikigami.Server.App`, build the verifier from `env.appConfig.httpAuth` and `env.logger`
and add it to the context (`verifier :. problemErrorFormatters :. EmptyContext`); change the
`agents` wiring to `agents = \caller -> agentServer env caller` and give `agentServer` its
leading `ApiCaller` argument (it is unused by the catalog routes and recorded by the
run-request route of
`docs/plans/90-accept-addressed-agent-runs-over-http-with-server-owned-idempotency.md`). In
`Shikigami.Server.Boot.runServer` log `server.auth.mode` with the mode; when the mode is
`disabled` and `http.host` is not `127.0.0.1`, `localhost`, or `::1`, log it at warning level
under the event `server.auth.disabled`.

Add `shikigami-server/test/Shikigami/Caller/VerifierSpec.hs` driving the assembled application
with `testWithApplication`: no header answers 401 `application/problem+json` with code
`unauthorized`, `retryable` false, and a `WWW-Authenticate` header; a wrong token answers the
byte-identical body; the right token answers the route's normal status; disabled mode answers
the normal status with no header; `/health/live` answers 200 without a header in bearer mode.
Extend `RequestLogSpec` with a request carrying an `Authorization` header and assert the
rendered log line does not contain the token.

### Milestone 3: client, hurl, documentation, ADR

In `shikigami-client/src/Shikigami/Client.hs` add:

```haskell
type Credential = AuthenticatedRequest Authenticated
credentialFor :: Maybe Text -> Credential
```

built with `mkAuthenticatedRequest` adding `Authorization: Bearer <token>` when a token is
given and adding nothing otherwise. In `Shikigami/Client/Command.hs` add a global `--token
TOKEN` option; when absent, read `SHIKIGAMI_API_TOKEN` at run time with `lookupEnv` (never as
an optparse default, so `--help` cannot print it). Pass the credential to every agents and runs
call; the `health` command takes none. Update the client test for the option.

Change `tests/hurl/run.sh` to generate a token (`python3 -c 'import secrets;
print(secrets.token_urlsafe(24))'`), export it as `SHIKIGAMI_API_TOKEN`, start the server with
`--set http.auth.mode=bearer`, and pass `--variable token="$token"` to hurl. Add
`tests/hurl/auth.hurl`: `GET /agents` without a header is 401 `application/problem+json` with
code `unauthorized` and a `WWW-Authenticate` header; with `Authorization: Bearer wrong` it is
401 with the same body; with `Authorization: Bearer {{token}}` it is 200; `GET /health/live`
without a header is 200. Add `Authorization: Bearer {{token}}` to every block under `/agents` in
`tests/hurl/agents.hurl` (and in `tests/hurl/agent-runs.hurl` if it already exists).

Document the three keys, the environment variable, the loopback warning, and the client option
in `docs/operations/configuration.md`. Create the ADR the MasterPlan names: inbound API
authentication is a verifier seam at the server boundary; the static bearer credential is the
first verifier and a Shomei or En issuer replaces only the verifier; health is exempt;
authentication is not authorization. Allocate the next free ADR number at creation time and
follow `docs/adr/README.md`.


## Concrete Steps

All commands run from the repository root inside the development shell.

Build and run the typed tests after each milestone:

```bash
nix develop -c cabal build all
nix develop -c cabal run shikigami-openapi
git diff --stat docs/api/openapi.json
nix develop -c cabal test shikigami-core shikigami-api shikigami-server shikigami-client
```

Prove the configuration gate without a database:

```bash
nix develop -c cabal run shikigami-server -- --check-config --set http.auth.mode=bearer
```

Expected: a non-zero exit naming `http.auth.token` as missing. Then with a token:

```bash
SHIKIGAMI_API_TOKEN=0123456789abcdefXYZ nix develop -c cabal run shikigami-server -- \
  --check-config --set http.auth.mode=bearer
```

Expected output:

```text
configuration valid
```

Start the server in bearer mode against the development database and exercise it:

```bash
PG_CONNECTION_STRING="host=$PWD/db dbname=shikigami user=$(id -un)" \
SHIKIGAMI_API_TOKEN=0123456789abcdefXYZ \
  nix develop -c cabal run shikigami-server -- --host 127.0.0.1 --port 8080 --set http.auth.mode=bearer
curl -si http://127.0.0.1:8080/agents | head -8
curl -s -H 'Authorization: Bearer 0123456789abcdefXYZ' http://127.0.0.1:8080/agents | jq '.pageInfo'
curl -si http://127.0.0.1:8080/health/live | head -1
nix develop -c cabal run shikigami-client -- --token 0123456789abcdefXYZ agents show heartbeat
nix develop -c just hurl
```


## Validation and Acceptance

The first `curl` answers `HTTP/1.1 401`, `Content-Type: application/problem+json`,
`WWW-Authenticate: Bearer realm="shikigami"`, and a body with `"code":"unauthorized"` and
`"retryable":false`. The second prints the page info object. The third prints `HTTP/1.1 200`.
The client prints the heartbeat view. `just hurl` passes with authentication enabled for the
whole suite.

The unit-level requirements are the assertions listed under each milestone: the OpenAPI
security scheme and per-operation requirements, the three configuration keys and the minimum
token length, the byte-identical 401 for missing and wrong credentials, the exemption of the
health probes, and the absence of the token from the request log. The early integration check
named by the MasterPlan is compiling the `AuthProtect` client and OpenAPI instances against the
`agents` mount before any configuration work begins.


## Idempotence and Recovery

Every change is additive and rerunnable. If a deployment is locked out after enabling bearer
mode, the recovery is a configuration change: set `http.auth.mode=disabled` or supply the
token through `SHIKIGAMI_API_TOKEN`, then restart; no data is touched. Rotating a token is the
same restart with a new value. If the OpenAPI drift test fails, regenerate and commit the
artifact.


## Interfaces and Dependencies

This plan has no hard prerequisite. Its last milestone wraps the `agents` mount created by
`docs/plans/88-serve-the-declared-agent-catalog-over-http.md`; everything before that can be
proven against a test-only record.

It owns `Shikigami.Caller.Api` in `shikigami-api` (`Authenticated`, `ApiCaller`, the OpenAPI
security instance), `Shikigami.Caller.Verifier` in `shikigami-server` (`newCallerVerifier` and
the `AuthServerData` instance), the `httpAuth` field of `AppConfig` with its three keys, the
`Credential` helpers in `Shikigami.Client`, the `--token` option, `tests/hurl/auth.hurl`, and
the bearer-mode start in `tests/hurl/run.sh`. The run-request plan consumes `ApiCaller` and
records `callerId`.

Libraries whose choice matters: `servant`, `servant-server`, and `servant-client-core` at the
pinned 0.20 line (generalized authentication is marked experimental upstream but has been
stable for years; shomei relies on it); `openapi-hs` and `servant-openapi-hs` for the security
scheme; `memory`'s `constEq` through `Shikigami.Sink.Auth` for the comparison. Verify the
released versions against `cabal.project` and the registry before changing a bound.
