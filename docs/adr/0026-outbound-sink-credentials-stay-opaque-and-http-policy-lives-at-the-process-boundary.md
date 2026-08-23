# 0026. Outbound sink credentials stay opaque and HTTP policy lives at the process boundary

Date: 2026-08-23

Status: accepted


## Context

Kawa, Kizashi, and Danwa sink requests were unauthenticated. The direct JSON clients created
an HTTP manager per request, while the generated Danwa client hid request construction behind
Servant and its convenience runner also created a manager per operation. None of those paths
bounded response memory, refused credential-bearing redirects, or preserved enough failure
structure for the outbox to distinguish a terminal refusal from a retryable outage.

Sink intents and workflow inputs are durable. Putting a token in the existing sink endpoint
records would therefore place it next to derived JSON instances and journal/outbox values.
Logging raw HTTP exceptions, response bodies, or arbitrary headers would create a second leak
path. The eventual Shomei service-token flow is not yet available, but choosing a static-only
client API would force every sink to change again when it arrives.


## Decision

**A sink credential is an opaque process-lifetime value obtained through `TokenSource`, and
all outbound HTTP authentication, timeout, redirect, body-limit, and failure policy is owned
by `Shikigami.Sink.Http`.**

Settei resolves one optional `SecretText` per sink. The composition root converts it to a
`BearerToken`, whose constructor and only header renderer live in a non-exposed internal
module. `BearerToken` has no `Show`, `Read`, or JSON instances. Public code may install it in a
`TokenSource` or compare an already-received bearer header in constant time, but cannot render
it. Endpoint configuration, sink declarations, outbox values, and workflow data remain
credential-free.

`SinkHttp` is built once before worker loops start and is threaded only as a nonserialized
dependency. Kawa and Kizashi share one TLS-capable manager and retain separate token sources.
Danwa receives a dedicated manager because its request hook applies to every generated request
and must never authenticate another host. Both paths use a 30-second response timeout, disable
redirects, reject encoded requests over the configured limit before network IO, and stream
responses only up to the configured limit. A configured source that cannot return a token
fails closed without issuing an unauthenticated request.

The header-capable JSON helper owns `Authorization` and `Content-Type`; caller headers cannot
override them. HTTP and Servant failures collapse into a typed, secret-free algebra. Invalid
input, redirects, ordinary 4xx responses, and malformed or oversized responses are permanent;
408, 425, 429, transport failures, and 5xx responses are transient. The outbox maps that type
directly instead of parsing text. Diagnostics retain no exception rendering, response body,
credential value, or arbitrary remote header.

Only synchronous HTTP and client exceptions enter that failure algebra. Asynchronous
cancellation is rethrown unchanged so Keiro attempt cancellation, worker shutdown, and process
supervision can stop an in-flight request.

The production Kawa stub can enforce the same opaque token before reading its body. Rejection
uses Shikigami's one RFC 9457 problem-details renderer and logs only a stable missing/invalid
category. No raw-token command-line option exists.

Future scoped Shomei issuance replaces only the `TokenSource` implementation: it may fetch,
cache, and refresh a token while preserving this client and serialization boundary. The
current project-level dependency is `mori://shinzui/shomei`; the artifact URI for its scoped
service-token request is pending Mori coverage.

Adding `SinkHttp` to the agent dependency records does not require a workflow patch. It changes
no Keiro step name, order, argument, or result and crosses no journal boundary.


## Alternatives rejected

**Put tokens in `KawaConfig`, `KizashiConfig`, or `DanwaConfig`.** Those records sit beside
serializable endpoint data and can reach durable sink intents. A future derived instance or
diagnostic would expose the credential.

**Read environment variables in each client.** That duplicates source precedence and
redaction policy, hides dependencies, and prevents provider-backed refresh behind one seam.

**Use one manager with a global authentication hook.** The Danwa hook would attach its token
to every host reached through that manager. Per-request direct injection is safe for Kawa and
Kizashi; the generated client therefore needs a dedicated manager.

**Follow redirects or rely on the default response checker.** A redirect can replay a bearer
token to another origin, and exception-based status handling retains unsafe request/response
detail while erasing the retry classification.

**Use unbounded lazy response helpers.** A timeout limits elapsed time, not memory. A broken or
hostile sink could continue allocating until the process fails.

**Log upstream exception text to aid diagnosis.** HTTP exception values may contain request
headers, and remote bodies and headers are attacker-controlled. Stable categories, status
codes, and configured byte counts are sufficient operational evidence.


## Consequences

Deployments remain compatible when no sink token is configured. Once enforcement is enabled,
a wrong or absent token becomes a terminal 401 delivery failure; credential-provider outages
remain retryable and never fall back to anonymous delivery.

Every worker owns two process-lifetime connection pools: one for direct sink requests and one
for Danwa. Tests and other composition roots must construct `SinkHttp` explicitly, even when
all sources are absent. Rei currently reuses the shared manager through an explicitly
unauthenticated `HttpEnv`, so the Kawa token cannot bleed into its request.

The current direct `http-client-tls ==0.3.6.1` pin is a compatibility constraint imposed by
the repository's Baikai/crypton dependency cohort. It should be revisited with that cohort,
without weakening the manager policy described here.

The token-source seam is deliberately narrower than a general secret provider. A future
Shomei adapter must keep plaintext confined to the internal header boundary, cache expiry
state outside durable values, and return only stable typed failures.


## References

* `docs/plans/22-outbound-authentication-for-sink-clients.md` — implementation plan and
  acceptance evidence.
* [ADR-0022](0022-the-journal-ends-at-enqueue-and-receipts-own-delivery-truth.md) — terminal
  and retryable delivery ownership.
* `docs/workflow-versioning.md` — why process-dependency threading needs no workflow patch.
* `mori://shinzui/danwa/packages/danwa-client` — generated client whose requests are wrapped
  by the dedicated manager.
* `mori://shinzui/haskell-jitsurei/docs/api-rfc9457-problem-details` — shared HTTP problem
  response convention.
