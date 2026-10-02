---
id: 77
slug: add-a-read-only-k8s-observe-capability-provider-for-durable-agents
title: "Add a read-only k8s.observe capability provider for durable agents"
kind: exec-plan
created_at: 2026-10-02T19:17:42Z
intention: "intention_01m3z0rf99ekhbddpz2jjy33j5"
provenance:
  created_by:
    model: "claude-opus-5-5"
    harness: "claude-code"
    at: 2026-10-02T19:17:42Z
---

# Add a read-only k8s.observe capability provider for durable agents

This ExecPlan is a living document. The sections Progress, Surprises & Discoveries,
Decision Log, and Outcomes & Retrospective must be kept up to date as work proceeds.
If durable project context changes, update or create ADRs in docs/adr/ in the same change.


## Purpose / Big Picture

An operator who runs Shikigami inside a Kubernetes cluster wants a declared agent to watch the
services that share that cluster: how much CPU and memory their pods use, whether their batch and
cron jobs succeeded, what their logs and warning events say, and whether a rollout finished. Today
no Shikigami agent can see any of that. The only capability overlay that exists reads a local Git
worktree, and the long-running worker does not install any overlay at all.

After this plan, an operator can grant Shikigami's Kubernetes service account a read-only role in
the namespaces it should watch, set `capabilities.k8s_observe.mode` to `in_cluster`, and declare
an agent with `capabilityOverlays = [ "k8s.observe" ]`. When that agent runs as a durable
(scheduled, stream, or addressed) run, its model can call seven read-only tools: list workloads,
describe a rollout, list pods, read pod resource usage, list jobs and cron jobs, list events, and
read a bounded, redacted slice of a pod's logs. Every tool refuses namespaces the operator did not
allow, every answer is size-bounded, secrets and environment values are never read, and every call
still passes Shikigami's fresh per-action authorization check before it touches the API server.

The motivating scenario is recorded as the Kikan use case
`mori://shinzui/kikan/okf/use-cases/concepts/UC-40`: an engineer wants a scheduled digest of a
production service's health (the first target is `mori://tan/mls-service-v2`) that compares
resource use, job outcomes, and warnings against remembered baselines, plus log-backed
investigation and a release go/no-go check. This plan delivers only the Kubernetes observation
capability that use case depends on. The digest agent itself, its delivery channel, and any
deployment action are separate work.

To see it working: `shikigami k8s-observe check` reports, for each allowed namespace, whether the
configured credentials can list pods; the core test suite proves that a scripted model calling
`overlay__k8s-observe__list_pods` receives a bounded pod summary from a fake API server; and, on a
local `kind` cluster, a durable run of the proof agent `agents/proof/k8s-observe.dhall` lists the
pods of a demo namespace.


## Progress

- [ ] Milestone 1: Kubernetes API client with bearer-token and custom-CA TLS, plus the `shikigami k8s-observe check` operator verb, proven against a local `kind` cluster.
- [ ] Milestone 2: Typed, bounded observations (workloads, rollout, pods, metrics, jobs, events, logs) with namespace allow-list and log redaction, unit-tested against JSON fixtures and a fake API server.
- [ ] Milestone 3: `k8s.observe` revision `1` descriptor, provider, and tools; tool-level tests through a scripted model.
- [ ] Milestone 4: Settei configuration and durable worker wiring; `disabled` default leaves existing behavior unchanged.
- [ ] Milestone 5: Proof agent, operator documentation with RBAC manifest, durable end-to-end test, and live `kind` validation.
- [ ] Completion: ADR distillation (new ADR for same-cluster Kubernetes observation), roadmap and use-case feature status updated.


## Surprises & Discoveries

- Observation (found while writing this plan): the durable worker hard-codes an empty capability
  runtime, so no durable agent can use any overlay today, including `workspace.read`.
  Evidence: `shikigami-workers/src/Shikigami/Workers/Config.hs`, function `agentRunDeps`, sets
  `AgentWorkflow.capabilities = emptyCapabilityRuntime`. Milestone 4 replaces this.


## Decision Log

- Decision: Implement a narrow, hand-written Kubernetes REST client on `http-client` and
  `http-client-tls` that decodes only the fields the tools return, instead of depending on the
  generated `kubernetes-api` packages (`mori://codedownio/kubernetes-api`).
  Rationale: seven read-only GET endpoints do not justify a generated client covering the whole
  API, its compile time, or its version-per-cluster package scheme. Decoding only named fields also
  guarantees that secret-bearing fields such as container `env` values are never materialized.
  Date: 2026-10-02

- Decision: The provider runs in-process in the same cluster as the services it observes,
  authenticated as Shikigami's own Kubernetes service account. It is not the cross-cluster
  broker and probe requested by IR-2
  (`docs/improvement-requests/authorized-cross-cluster-diagnostic-tools.md`).
  Rationale: IR-2 exists because Kikan's own cluster must never hold production credentials. When
  Shikigami is deployed into the work cluster itself, the trust boundary is the service account's
  RBAC role, so a read-only role plus Shikigami's own namespace allow-list is sufficient. IR-2
  remains the path for a Shikigami that lives in a different cluster.
  Date: 2026-10-02

- Decision: Do not add a local or static authorization mode. Live tool calls require
  `authorization.actions.mode = kikan`, and Kikan-En policy must permit `ConnectCapability` for
  `k8s.observe` revision `1` and `InvokeCapabilityTool` for each logical tool.
  Rationale: [ADR 0036](../adr/0036-external-agent-actions-require-fresh-exact-authorization.md)
  requires a fresh Kikan-En decision for every external agent action and reserves allow-all
  authorizers for tests. Tests in this plan use `allowAllActionAuthorizerForTests` explicitly.
  Date: 2026-10-02

- Decision: Expose exactly seven `Observation` tools and no tool for Secrets, ConfigMaps,
  `pods/exec`, `pods/portforward`, or arbitrary API paths.
  Rationale: durable runs admit only `Observation` tools (`admitOperationClass` in
  `shikigami-core/src/Shikigami/Capability/Catalog.hs`), and a closed tool set is what lets an
  operator reason about what the model can see.
  Date: 2026-10-02

- Decision: The provider lives in `shikigami-core` under `Shikigami.Capability.Kubernetes*`.
  Rationale: the durable worker in `shikigami-workers` and the administrative command in
  `shikigami-server` both depend on `shikigami-core`, and core already owns outbound HTTP clients
  (for example `Shikigami.Sink.KawaClient`). The one-off package `shikigami-agent` stays as light
  as [ADR 0003](../adr/0003-a-seventh-package-keeps-one-off-agent-runs-light.md) requires because
  it does not wire this provider.
  Date: 2026-10-02

- Decision: Re-read the bearer token file on every request.
  Rationale: Kubernetes projected service-account tokens rotate (by default about hourly); caching
  the token at startup would make a long-running worker fail an hour after it starts.
  Date: 2026-10-02

- Decision: When the metrics API (`metrics.k8s.io`) is absent or forbidden, `pod_metrics` returns
  a structured `{"available": false, "reason": ...}` answer rather than a tool failure.
  Rationale: many clusters, including a default `kind` cluster, run without metrics-server. The
  model should be able to say "metrics unavailable" and continue with the other tools.
  Date: 2026-10-02


## Outcomes & Retrospective

(To be filled during and after implementation.)


## Context and Orientation

Shikigami is a Haskell runtime for "declared agents": an agent is a Dhall file under `agents/`
that names a behavior (what runs), a trigger (when), sinks (where output goes), an identity, and
memory. The schema is `schema/Agent.dhall`. A durable run is one that the long-running worker
(`shikigami-worker`, package `shikigami-workers`) executes as a journaled workflow on Keiro; a
one-off run is a direct command-line invocation (`shikigami-agent-run`, package `shikigami-agent`).
A "journaled step" is a unit of work whose result is written to the workflow journal so that, if
the process restarts and the workflow replays, the step's recorded answer is reused instead of
running again.

A **capability overlay** is the only supported way to give an agent's model extra tools. It is
described in [ADR 0025](../adr/0025-capability-overlays-are-requests-for-additive-model-tools.md).
In plain terms: the agent declaration lists capability names it wants
(`capabilityOverlays = [ "workspace.read" ]`); an operator-owned **catalog** decides whether that
name exists and is allowed; a **provider** turns the allowed name into live tools for the length of
one run (a **lease**) and cleans up afterwards. The public, serializable description of a
capability is a `CapabilityDescriptor`: a capability id (lowercase dotted, for example
`k8s.observe`), an immutable revision word (for example `1`), and a list of logical tool names,
each tagged with an operation class: `Observation`, `IdempotentMutation`, or `IrreversibleEmission`.
Durable runs reject any tool that is not `Observation`. The model sees each tool under a namespaced
name produced by `overlayToolName`: capability dots become dashes, so the tool `list_pods` of
`k8s.observe` appears to the model as `overlay__k8s-observe__list_pods`. Overlays are accepted only
for `Skill` behaviors (a Markdown skill directory run by a model with a tool loop), only when the
agent declares an `identity`, and not together with `delegates`.

The relevant modules, all under `shikigami-core/src/Shikigami/Capability/`, are:

`Overlay.hs` defines `CapabilityId`, `CapabilityRevision`, `CapabilityOperationClass`,
`CapabilityToolDescriptor`, `CapabilityDescriptor`, and `ResolvedCapabilitySet`.
`Catalog.hs` defines `CapabilityCatalog`, `mkCapabilityCatalog`, `ExecutionMode` (`Durable` or
`OneOff`), `ResolutionSubject`, `CapabilityResolutionError`, and `resolveCapabilityOverlays`, the
pure admission check that runs as the journaled step `resolve-capability-overlays`.
`Provider.hs` defines `CapabilityRuntime` (catalog, provider registry, and an `authorize` policy
callback), `CapabilityProvider` (a descriptor plus `acquire :: CapabilityScope -> IO (Either
CapabilityAcquireError CapabilityLease)`), `CapabilityLease` (descriptor, tools, release action),
`mkCapabilityProviderRegistry`, and `withCapabilityOverlays`, which acquires each provider,
checks that the lease's tool names exactly match the descriptor, wraps every tool so that it asks
the `ActionAuthorizer` for `InvokeCapabilityTool` immediately before running, and releases leases
in reverse order on every exit path.
`Tools.hs` performs the collision-safe, namespaced composition of overlay tools with the base tool
registry.

The one existing provider is `shikigami-agent/src/Shikigami/Agent/Capability/Workspace.hs`
(`workspaceReadDescriptor`, `workspaceReadProvider`, tools `read`, `grep`, `glob`), and
`shikigami-agent/src/Shikigami/Agent/Capability/OneOff.hs` shows how a `CapabilityRuntime` is built
and how its `authorize` callback (`authorizeForMode`) refuses anything except the one installed
descriptor. Use these two files as the pattern for this plan. Tools are built with
`Shikumi.Tool.mkTool name description handler`, where the handler's input type derives
`ToSchema`, `FromModel`, and has a `Validatable` instance, and its output derives `ToJSON`. A tool
handler reports a bad request with `throwError (ValidationFailure text)` and an upstream failure
with `throwError (ProviderFailure text)` from `Shikumi.Error`.

The durable path is in `shikigami-core/src/Shikigami/Agent/Workflow.hs`.
`resolveCapabilitiesForRun` resolves the declaration's overlays against `(.capabilities) deps` with
`mode = Durable`. `runSessionedAgent` then runs a `Skill` behavior inside the single journaled step
`run-behavior-v2`, calling `runBehaviorWithCapabilities`, which calls `withCapabilityOverlays`.
Because the whole behavior is one journaled step, tool calls are not repeated when a completed run
replays; they may be repeated only if the process dies mid-step and the step is retried, which is
harmless for read-only tools. The `AgentRunDeps` value is built in
`shikigami-workers/src/Shikigami/Workers/Config.hs` by `agentRunDeps`, which currently passes
`emptyCapabilityRuntime`. `WorkerEnv` (same file, around line 88) is constructed in
`shikigami-workers/src/Shikigami/Workers/Command/Worker.hs` (around line 161).

**Authorization.** `Shikigami.Action.Authorization`
(`shikigami-core/src/Shikigami/Action/Authorization.hs`) provides `ActionAuthorizer`,
`denyAllActionAuthorizer`, `newKikanActionAuthorizer`, and `allowAllActionAuthorizerForTests`.
With the default `authorization.actions.mode = disabled`, every capability connection and tool call
is denied. [ADR 0036](../adr/0036-external-agent-actions-require-fresh-exact-authorization.md)
makes this deliberate: every external agent action needs a fresh decision from Kikan-En
(`mori://shinzui/kikan-en`) authenticated through Shomei (`mori://shinzui/shomei`). Its action
coordinates come from `Kikan.En.Action.mkCapabilityTarget` and `mkCapabilityToolTarget`; those
accept the id `k8s.observe`, revision `1`, and tool names containing underscores, so no Kikan-En
code change is needed, only policy relationships. `docs/operations/action-authorization.md` lists
the required configuration.

**Configuration.** Shikigami's configuration uses Settei, declared in
`shikigami-core/src/Shikigami/App/Config.hs`. Each setting has a stable dotted key, a help string,
a decoder, and an environment binding; `shikigami-worker --explain-config` prints every key with
secrets redacted. The `directory.mode` setting (`DirectoryMode`, `directoryModeSetting`, key
`directory.mode`, environment variable `SHIKIGAMI_DIRECTORY_MODE`) is the closest pattern for an
optional feature with a `disabled` default and mode-dependent required keys. All keys are
documented in `docs/operations/configuration.md`.

**Kubernetes terms used here.** The **API server** is the cluster's HTTPS REST endpoint. Inside a
pod, it is reachable at `https://$KUBERNETES_SERVICE_HOST:$KUBERNETES_SERVICE_PORT`, and the pod's
**service account** credentials are mounted at
`/var/run/secrets/kubernetes.io/serviceaccount/` as `token` (a bearer token that rotates),
`ca.crt` (the certificate authority that signed the API server's certificate), and `namespace`.
**RBAC** (role-based access control) grants a service account verbs (`get`, `list`) on resources
in a namespace through a `Role` and a `RoleBinding`. The **metrics API** (`metrics.k8s.io/v1beta1`)
is served only when metrics-server is installed and gives current CPU and memory per container.
**kind** ("Kubernetes in Docker") runs a throwaway local cluster for testing.

**Testing patterns.** `shikigami-core/test/Shikigami/SinkAuthSpec.hs` starts fake HTTP servers
with `Network.Wai.Handler.Warp.testWithApplication`; `wai` and `warp` are already dependencies of
the `shikigami-core-test` suite. `shikigami-core/test/Shikigami/BehaviorToolSpec.hs` registers a
scripted Baikai model provider that emits tool calls (for example to
`overlay__workspace-read__missing`) and asserts on the tool results, using
`allowAllActionAuthorizerForTests`. `shikigami-core/test/Shikigami/CapabilityProviderSpec.hs`
tests lease validation and release ordering. `shikigami-core/test-postgres/Shikigami/AgentWorkflowSpec.hs`
runs durable agent workflows against a temporary PostgreSQL, including capability-overlay cases.

**Relevant ADRs.** [ADR 0013](../adr/0013-flow-bodies-reach-the-world-only-through-capabilities.md):
Flow bodies cannot perform IO, so this capability is for `Skill` behaviors; Flow access would need
a new replay-safe effect and is out of scope.
[ADR 0021](../adr/0021-operator-verbs-wrap-the-owning-library.md): operator verbs wrap the owning
library, which is why `shikigami k8s-observe check` calls the same client module the tools use.
[ADR 0025](../adr/0025-capability-overlays-are-requests-for-additive-model-tools.md): descriptors
are immutable; any change to tool names, inputs, or output shapes after release needs revision
`2`, not an edit to revision `1`.
[ADR 0026](../adr/0026-outbound-sink-credentials-stay-opaque-and-http-policy-lives-at-the-process-boundary.md):
credentials stay opaque and are never logged or journaled; the token is read into a `SecretText`-like
value and never shown.
[ADR 0036](../adr/0036-external-agent-actions-require-fresh-exact-authorization.md), summarized
above. [ADR 0003](../adr/0003-a-seventh-package-keeps-one-off-agent-runs-light.md), summarized in
the Decision Log.

**Related plans and requests.** `docs/plans/31-deployable-service-stack-process-compose-packaging-and-configuration.md`
(not started) owns packaging; this plan assumes an operator can already run `shikigami-worker` in a
pod and does not build images or manifests beyond the RBAC example. IR-2,
`docs/improvement-requests/authorized-cross-cluster-diagnostic-tools.md`, owns the cross-cluster
variant.


## Plan of Work

The work proceeds bottom-up: first prove that Shikigami can talk to a real API server, then build
typed bounded observations, then wrap them as a capability, then wire the capability into the
worker, and finally prove the whole path with a proof agent.


### Milestone 1: API client and operator check (prototype)

This milestone de-risks the only unfamiliar piece: an HTTPS client that trusts a cluster-specific
CA and sends a rotating bearer token. At the end, an operator can run
`shikigami k8s-observe check` and see, per configured namespace, whether listing pods is allowed.

Create `shikigami-core/src/Shikigami/Capability/Kubernetes/Client.hs`. Define a
`KubernetesEndpoint` record with `apiServerUrl :: !Text`, `tokenFile :: !FilePath`, and
`caFile :: !FilePath`, and a function `inClusterEndpoint :: IO (Either KubernetesClientError
KubernetesEndpoint)` that reads `KUBERNETES_SERVICE_HOST` and `KUBERNETES_SERVICE_PORT` and uses
the standard service-account paths. Define `newKubernetesClient :: KubernetesEndpoint -> Int -> IO
(Either KubernetesClientError KubernetesClient)` (the `Int` is the request timeout in seconds). It
reads the CA file with `Data.X509.CertificateStore.readCertificateStore` (package
`crypton-x509-store`), builds `Network.TLS.ClientParams` whose `clientShared` uses that store as
`sharedCAStore` and whose `clientSupported` keeps the library defaults, wraps them as
`Network.Connection.TLSSettings` (package `crypton-connection`), and creates one `Manager` with
`Network.HTTP.Client.TLS.mkManagerSettings` and `newTlsManagerWith`. The build plan already
resolves `crypton-connection` 0.4.6, `crypton-x509-store` 1.9.0, `tls` 2.4.4, and `data-default`
0.8.0.2 transitively; add them to the `shikigami-core` library's `build-depends` without new
version constraints. The client exposes
`getJson :: FromJSON a => KubernetesClient -> Text -> [(ByteString, Maybe ByteString)] -> IO
(Either KubernetesClientError a)` and `getText` (for logs) that read the token file fresh on each
call, send `Authorization: Bearer <token>`, cap the response body at a fixed byte limit, and map
HTTP 401, 403, 404, timeouts, TLS failures, and decode failures to distinct
`KubernetesClientError` constructors. The token value must never appear in a `Show` instance, log
line, or error text; give the token a newtype without `Show` or with a redacting `Show`.

Add an administrative verb in `shikigami-server/src/Shikigami/Server/Command.hs` (and a module
`shikigami-server/src/Shikigami/Server/Command/K8sObserve.hs`), following how the existing `grants`
verbs are structured: `shikigami k8s-observe check` loads configuration (Milestone 4 adds the keys;
for this milestone accept the explicit endpoint through the same environment variables Milestone 4
will bind, listed under Interfaces), builds the client, and for each allowed namespace performs
`GET /api/v1/namespaces/<ns>/pods?limit=1`, printing one line per namespace. Prove it on `kind` as
shown in Concrete Steps. If custom-CA TLS cannot be made to work with these libraries, record the
evidence in Surprises & Discoveries and stop; do not fall back to disabling certificate
verification.


### Milestone 2: Typed, bounded observations

At the end of this milestone, pure Haskell functions return small, model-friendly summaries of
cluster state, and tests prove the bounds, the namespace allow-list, and log redaction without any
cluster.

Create `shikigami-core/src/Shikigami/Capability/Kubernetes/Observe.hs`. Define a
`KubernetesObserveScope` record holding the `KubernetesClient`, the allowed namespaces as a
`Set Text`, and the limits (`maxLogLines`, `maxLogBytes`, `maxItems`). Every function first checks
the namespace against the allow-list and returns `NamespaceNotAllowed ns` before any HTTP call.
Define one function per observation:

`listWorkloads` reads `GET /apis/apps/v1/namespaces/<ns>/deployments` and `.../statefulsets` and
returns, per workload: kind, name, desired, ready, updated and available replicas, container
images, `metadata.generation` versus `status.observedGeneration`, and the `Available` and
`Progressing` condition statuses and reasons.

`describeRollout` reads one deployment and the replica sets selected by its
`spec.selector.matchLabels` (`GET .../replicasets?labelSelector=...`) and returns the revision
(annotation `deployment.kubernetes.io/revision`), images, and ready counts of each replica set,
newest first, plus whether the rollout is complete (updated equals desired, available equals
desired, and observed generation is current).

`listPods` reads `GET /api/v1/namespaces/<ns>/pods` with an optional `labelSelector` and returns,
per pod: name, phase, node, start time, and per container: name, image, ready, restart count,
current state, last termination reason and exit code (this is how `OOMKilled` becomes visible),
and resource requests and limits. Never decode `env`, `envFrom`, `volumes`, or annotations.

`podMetrics` reads `GET /apis/metrics.k8s.io/v1beta1/namespaces/<ns>/pods` and returns CPU (in
millicores) and memory (in MiB) per container. A 404 or 403 becomes `available = False` with a
reason, as recorded in the Decision Log.

`listJobs` reads `GET /apis/batch/v1/namespaces/<ns>/cronjobs` and `.../jobs` and returns, per
cron job: schedule, suspend flag, last schedule time, last successful time, and active count; per
job: owner cron job (from `ownerReferences`), start and completion time, succeeded and failed
counts, and the `Complete` or `Failed` condition with reason.

`listEvents` reads `GET /api/v1/namespaces/<ns>/events` (with `fieldSelector=type=Warning` when
`warningsOnly` is set) and returns type, reason, message, involved object kind and name, count, and
last timestamp, filtered to the last `sinceMinutes` (default 60) and sorted newest first.

`readLogs` reads `GET /api/v1/namespaces/<ns>/pods/<pod>/log` with `container`, `tailLines`
(clamped to `maxLogLines`), `sinceSeconds`, `previous`, and `limitBytes` (set to `maxLogBytes`),
then applies `redactLogText` and returns the lines plus a `truncated` flag.

Every list result is capped at `maxItems` entries with a `truncated` flag, and each returned record
type derives `ToJSON`. Put the redaction rules in
`shikigami-core/src/Shikigami/Capability/Kubernetes/Redact.hs` as `redactLogText :: Text -> Text`.
It replaces the password part of URLs with credentials (`scheme://user:secret@host` becomes
`scheme://user:[REDACTED]@host`), values after `password=`, `passwd=`, `secret=`, `token=`, and
`api_key=` (case-insensitive), `Authorization: Bearer` and `Basic` values, and strings shaped like
JSON Web Tokens (three base64url segments separated by dots, starting `eyJ`). Redaction is
best-effort defense in depth; the operator documentation must say so.

Add `shikigami-core/test/Shikigami/KubernetesObserveSpec.hs` with JSON fixtures under
`shikigami-core/test/fixtures/k8s/` (one captured list response per endpoint; capture them from the
`kind` cluster in Milestone 1 with `kubectl get --raw <path>` and remove anything sensitive). Tests
decode each fixture, assert the summaries, start a Warp fake API server with `testWithApplication`
that serves the fixtures and records request paths, and assert: a disallowed namespace makes no
request; `tailLines` is clamped; `maxItems` truncation sets the flag; metrics 404 yields
`available = False`; a 403 maps to the forbidden error; and each redaction rule works.


### Milestone 3: The k8s.observe capability

At the end of this milestone, `k8s.observe` exists as a provider that any `CapabilityRuntime` can
install, and a scripted model can call its tools.

Create `shikigami-core/src/Shikigami/Capability/Kubernetes.hs` exporting `k8sObserveId`,
`k8sObserveDescriptor`, `k8sObserveProvider`, and `k8sObserveCapabilityRuntime`. The descriptor
has id `k8s.observe`, revision `1`, and seven `Observation` tools named `list_workloads`,
`describe_rollout`, `list_pods`, `pod_metrics`, `list_jobs`, `list_events`, and `read_logs`.
`k8sObserveProvider :: KubernetesObserveScope -> CapabilityProvider` returns a lease whose tools are
built with `mkTool`, one per Milestone 2 function, each with a precise description that names the
namespace requirement and the limits, and whose `release` is `pure (Right ())` because the HTTP
manager is shared for the life of the process. `acquire` checks only that the token and CA files
are still readable and otherwise returns `CapabilityAcquireError` with a bounded message. Tool
handlers map `NamespaceNotAllowed` and bad input to `ValidationFailure` and transport, 401, 403, and
5xx failures to `ProviderFailure`, mirroring `runWorkspaceTool` in `Workspace.hs`.

`k8sObserveCapabilityRuntime :: KubernetesObserveScope -> Either Text CapabilityRuntime` builds the
catalog with `mkCapabilityCatalog [k8sObserveDescriptor]`, the registry with
`mkCapabilityProviderRegistry [k8sObserveProvider scope]`, and an `authorize` callback modeled on
`authorizeForMode` in `OneOff.hs`: it requires `mode == Durable`, a non-empty principal, the exact
`k8sObserveDescriptor`, and only `Observation` tools, and otherwise returns
`CapabilityAuthorizationDenied` with a reason.

Register the new modules in `shikigami-core/shikigami-core.cabal`. Extend
`shikigami-core/test/Shikigami/BehaviorToolSpec.hs` (or add `KubernetesCapabilitySpec.hs`) with a
case that composes the overlay through `withCapabilityOverlays` using
`allowAllActionAuthorizerForTests`, has the scripted model call
`overlay__k8s-observe__list_pods` with `{"namespace": "demo"}` against the Warp fake API server,
and asserts that the tool result contains the fixture's pod names. Add a second case that uses an
`ActionAuthorizer` returning `ActionPolicyDenied` for `InvokeCapabilityTool` and asserts that the
fake server receives no request. Add a lease-validation case to `CapabilityProviderSpec.hs`
asserting the lease's tool names equal the descriptor's.


### Milestone 4: Configuration and worker wiring

At the end of this milestone, a worker started with `capabilities.k8s_observe.mode = in_cluster`
installs the capability for durable runs, and a worker with the default `disabled` behaves exactly
as before.

In `shikigami-core/src/Shikigami/App/Config.hs`, add a `K8sObserveSettings` value to `AppConfig`
following the `directory.mode` pattern. Its mode is `disabled` (default), `in_cluster`, or
`explicit`. `in_cluster` uses `inClusterEndpoint`; `explicit` requires `api_server_url`,
`token_file`, and `ca_file` and exists for local testing against `kind`. Both enabled modes require
a non-empty `namespaces` list. Limits have defaults: `max_log_lines` 200 (range 1 to 2000),
`max_log_bytes` 65536 (range 1024 to 1048576), `max_items` 100 (range 1 to 500), and
`request_timeout_seconds` 10 (range 1 to 60). Partial configuration (for example `explicit` without
`ca_file`) must fail configuration resolution with a clear message, as authorization configuration
already does. The exact keys and environment variables are listed under Interfaces.

In `shikigami-workers/src/Shikigami/Workers/Config.hs`, add a field `capabilities ::
!CapabilityRuntime` to `WorkerEnv`, add an accessor `envCapabilities` in the same style as the
existing `env*` accessors, and change `agentRunDeps` to pass `envCapabilities env` instead of
`emptyCapabilityRuntime`. In `shikigami-workers/src/Shikigami/Workers/Command/Worker.hs`, where
`WorkerEnv` is constructed, build the runtime: `disabled` yields `emptyCapabilityRuntime`; an
enabled mode builds the endpoint and client and calls `k8sObserveCapabilityRuntime`, and a failure
there stops startup with the configuration error. Log one `capability.k8s_observe.installed` line
with the mode and namespaces (never the token). Add the keys to `docs/operations/configuration.md`
and update `config/shikigami.example.yaml` with a commented-out example.

Add a test to `shikigami-workers-test` asserting that the default configuration yields an empty
catalog and that `explicit` mode without `ca_file` is a configuration error. Confirm
`shikigami-worker --explain-config` lists the new keys.


### Milestone 5: Proof agent, documentation, and end-to-end validation

At the end of this milestone, an operator has a documented path from RBAC to a running agent, and
the durable path is proven both in the PostgreSQL test suite and live on `kind`.

Add `agents/skills/k8s-observe-proof/SKILL.md`: a short skill instructing the model to call
`overlay__k8s-observe__list_pods` for the namespace given in the trigger payload and reply with a
one-paragraph health summary. Add `agents/proof/k8s-observe.dhall` modeled on
`agents/proof/capability-overlay.dhall`: `Skill` behavior pointing at that skill, trigger
`A.Trigger.Event { eventType = "proof.k8s-observe" }`, an `identity` with a principal, and
`capabilityOverlays = [ "k8s.observe" ]`.

Extend `shikigami-core/test-postgres/Shikigami/AgentWorkflowSpec.hs` with a durable run of a
declaration equivalent to the proof agent, using the stub or scripted model provider, the Warp fake
API server, and `allowAllActionAuthorizerForTests`. Assert the run succeeds, the
`resolve-capability-overlays` step journaled a resolved set containing `k8s.observe` revision `1`,
and the fake server saw exactly one pods request.

Write `docs/operations/k8s-observe.md`. It must contain: what the capability can and cannot see;
the RBAC manifest from Interfaces with an explanation of why it excludes Secrets and `pods/exec`
and must not be a wildcard; the configuration keys; the Kikan-En policy relationships required
(connect `k8s.observe`/`1`, invoke each of the seven tools) with a pointer to
`docs/operations/action-authorization.md`; the warning that log lines are sent to the model
provider and redaction is best-effort; and a troubleshooting table mapping `check` output (401,
403, TLS failure, metrics unavailable) to causes. Link it from `README.md`'s documentation list and
from `docs/user/` where overlays are described.

Run the live `kind` validation in Concrete Steps. If a Kikan-En and Shomei instance is available,
run the proof agent through `shikigami-worker` with `authorization.actions.mode = kikan` and record
the transcript. If not, record in Surprises & Discoveries that the live durable path was proven only
through `shikigami k8s-observe check` plus the PostgreSQL test, and leave a Progress item for the
Kikan-backed run.


### Completion

Write `docs/adr/0039-kubernetes-observation-is-a-same-cluster-read-only-overlay.md` in the existing
ADR format, capturing: same-cluster, in-process observation bounded by RBAC and a namespace
allow-list; no Secrets, exec, or arbitrary paths; narrow hand-written client; structured
metrics-unavailable answers; and IR-2 as the cross-cluster path. Update the roadmap
`docs/roadmap.md` open-plan table, and update the `k8s-observe-capability` feature status in
`mori://shinzui/kikan/okf/use-cases/concepts/UC-40` to `delivered` with this plan's evidence.


## Concrete Steps

All commands run from the repository root `/Users/shinzui/Keikaku/bokuno/shikigami` inside the
development shell (`nix develop`) unless stated otherwise. The co-developed Kikan-En checkout must
exist at `../kikan-project/kikan-en`, as `cabal.project` requires.

Build and run the fast tests after each milestone:

```bash
cabal build all
cabal test shikigami-core-test --test-options='-p Kubernetes'
cabal test shikigami-workers-test
```

Milestone 1 and 5 local cluster setup. `kind` and `kubectl` are not in the development shell; use
a temporary Nix shell. Docker (or a compatible runtime) must be running.

```bash
nix shell nixpkgs#kind nixpkgs#kubectl
kind create cluster --name shikigami-observe
kubectl create namespace demo
kubectl -n demo create deployment web --image=nginx:1.27 --replicas=2
kubectl -n demo create cronjob tick --image=busybox:1.36 --schedule='*/1 * * * *' -- sh -c 'echo tick; date'
kubectl -n demo create serviceaccount shikigami-observer
kubectl apply -f docs/operations/k8s-observe-rbac.example.yaml   # the Role/RoleBinding from Interfaces, namespace demo
kubectl -n demo create token shikigami-observer --duration=1h > /tmp/k8s-observe-token
kubectl config view --raw -o jsonpath='{.clusters[?(@.name=="kind-shikigami-observe")].cluster.certificate-authority-data}' | base64 -d > /tmp/k8s-observe-ca.crt
export SHIKIGAMI_K8S_OBSERVE_MODE=explicit
export SHIKIGAMI_K8S_OBSERVE_API_SERVER_URL="$(kubectl config view --raw -o jsonpath='{.clusters[?(@.name=="kind-shikigami-observe")].cluster.server}')"
export SHIKIGAMI_K8S_OBSERVE_TOKEN_FILE=/tmp/k8s-observe-token
export SHIKIGAMI_K8S_OBSERVE_CA_FILE=/tmp/k8s-observe-ca.crt
export SHIKIGAMI_K8S_OBSERVE_NAMESPACES=demo,kube-system
cabal run shikigami -- k8s-observe check
```

Expected output (`kube-system` is configured but not granted, which proves the RBAC boundary):

```text
k8s.observe  mode=explicit  server=https://127.0.0.1:<port>
demo         ok          list pods allowed (2 pods)
kube-system  forbidden   the service account cannot list pods in this namespace (HTTP 403)
```

Capture fixtures for Milestone 2 from the same cluster, then scrub them:

```bash
kubectl get --raw /api/v1/namespaces/demo/pods > shikigami-core/test/fixtures/k8s/pods.json
kubectl get --raw /apis/apps/v1/namespaces/demo/deployments > shikigami-core/test/fixtures/k8s/deployments.json
kubectl get --raw /apis/batch/v1/namespaces/demo/cronjobs > shikigami-core/test/fixtures/k8s/cronjobs.json
kubectl get --raw /apis/batch/v1/namespaces/demo/jobs > shikigami-core/test/fixtures/k8s/jobs.json
kubectl get --raw /api/v1/namespaces/demo/events > shikigami-core/test/fixtures/k8s/events.json
```

Milestone 4 configuration check:

```bash
cabal run shikigami-worker -- --explain-config | grep k8s_observe
```

Expected: one line per `capabilities.k8s_observe.*` key with its source; no token value appears.

Milestone 5 PostgreSQL suite (starts its own temporary PostgreSQL):

```bash
cabal test shikigami-core-postgres-test --test-options='-p k8s'
```

Tear down the local cluster when finished:

```bash
kind delete cluster --name shikigami-observe
rm -f /tmp/k8s-observe-token /tmp/k8s-observe-ca.crt
```


## Validation and Acceptance

The plan is accepted when all of the following are observed.

Running `cabal run shikigami -- k8s-observe check` against the `kind` setup above prints `ok` for
`demo` and `forbidden` for `kube-system`.

`cabal test shikigami-core-test` passes, and its Kubernetes tests demonstrate: a scripted model's
call to `overlay__k8s-observe__list_pods` returns the fixture pod names; a call naming a namespace
outside the allow-list returns a validation error and the fake server records no request; a denied
`InvokeCapabilityTool` decision results in no request; `read_logs` clamps `tailLines` and redacts a
fixture line containing `postgres://app:hunter2@db:5432/x` to
`postgres://app:[REDACTED]@db:5432/x`; and a 404 from the metrics endpoint yields
`{"available": false, ...}`.

`cabal test shikigami-core-postgres-test` passes, including a durable run that resolves
`k8s.observe` revision `1` and calls the fake API server once.

`cabal test shikigami-workers-test` passes, including the test that the default configuration
installs an empty catalog. Before this plan, a durable agent declaring
`capabilityOverlays = [ "k8s.observe" ]` fails its run with an unknown-capability refusal; after
this plan, with the mode enabled, it resolves.

`cabal build all` succeeds with no new warnings in the touched modules, and the full test suites
that passed before the change still pass.


## Idempotence and Recovery

All code changes are additive. The `disabled` default means a deployment that does not set
`capabilities.k8s_observe.mode` behaves exactly as before, so the change is safe to ship before any
operator configures it. To roll back an enabled deployment, set the mode back to `disabled` and
restart the worker; durable runs already journaled with a resolved `k8s.observe` overlay will then
fail at provider acquisition with `CapabilityProviderUnavailable`, which is the existing, typed
behavior for a missing provider and does not corrupt the journal.

The `kind` steps are repeatable: `kind create cluster` fails harmlessly if the cluster exists (run
`kind delete cluster --name shikigami-observe` first to start clean), and `kubectl apply` is
idempotent. The token expires after one hour; re-run `kubectl create token` if `check` starts
reporting HTTP 401.

Never relax TLS verification to make a step pass. If the custom-CA client fails, record the error
in Surprises & Discoveries and resolve the cause.


## Interfaces and Dependencies

New library dependencies of `shikigami-core` (versions already in the build plan, added without new
constraints): `crypton-connection`, `crypton-x509-store`, `tls`, `data-default`. Existing ones
used: `http-client`, `http-client-tls`, `aeson`, `text`, `containers`. No `kubernetes-api`
dependency.

New modules, all registered in `shikigami-core/shikigami-core.cabal`:

```haskell
-- shikigami-core/src/Shikigami/Capability/Kubernetes/Client.hs
data KubernetesEndpoint = KubernetesEndpoint
  { apiServerUrl :: !Text, tokenFile :: !FilePath, caFile :: !FilePath }
data KubernetesClient            -- opaque: Manager, endpoint, timeout
data KubernetesClientError       -- Unauthorized | Forbidden | NotFound | Timeout | TlsFailure Text
                                 -- | HttpStatus Int | ResponseTooLarge | DecodeFailure Text | TokenUnreadable
inClusterEndpoint :: IO (Either KubernetesClientError KubernetesEndpoint)
newKubernetesClient :: KubernetesEndpoint -> Int -> IO (Either KubernetesClientError KubernetesClient)
getJson :: FromJSON a => KubernetesClient -> Text -> [(ByteString, Maybe ByteString)] -> IO (Either KubernetesClientError a)
getText :: KubernetesClient -> Text -> [(ByteString, Maybe ByteString)] -> IO (Either KubernetesClientError Text)

-- shikigami-core/src/Shikigami/Capability/Kubernetes/Observe.hs
data KubernetesObserveScope = KubernetesObserveScope
  { client :: !KubernetesClient, namespaces :: !(Set Text)
  , maxLogLines :: !Int, maxLogBytes :: !Int, maxItems :: !Int }
data ObserveError = NamespaceNotAllowed !Text | ObserveClientError !KubernetesClientError
listWorkloads   :: KubernetesObserveScope -> Text -> IO (Either ObserveError WorkloadList)
describeRollout :: KubernetesObserveScope -> Text -> Text -> IO (Either ObserveError RolloutSummary)
listPods        :: KubernetesObserveScope -> Text -> Maybe Text -> IO (Either ObserveError PodList)
podMetrics      :: KubernetesObserveScope -> Text -> Maybe Text -> IO (Either ObserveError PodMetrics)
listJobs        :: KubernetesObserveScope -> Text -> IO (Either ObserveError JobList)
listEvents      :: KubernetesObserveScope -> Text -> Maybe Int -> Bool -> IO (Either ObserveError EventList)
readLogs        :: KubernetesObserveScope -> LogRequest -> IO (Either ObserveError LogExcerpt)

-- shikigami-core/src/Shikigami/Capability/Kubernetes/Redact.hs
redactLogText :: Text -> Text

-- shikigami-core/src/Shikigami/Capability/Kubernetes.hs
k8sObserveId :: CapabilityId                      -- "k8s.observe"
k8sObserveDescriptor :: CapabilityDescriptor      -- revision "1", seven Observation tools
k8sObserveProvider :: KubernetesObserveScope -> CapabilityProvider
k8sObserveCapabilityRuntime :: KubernetesObserveScope -> Either Text CapabilityRuntime
```

Tool inputs (each a record deriving `ToSchema`, `FromModel`, with a `Validatable` instance):
`list_workloads {namespace}`, `describe_rollout {namespace, deployment}`,
`list_pods {namespace, labelSelector?}`, `pod_metrics {namespace, labelSelector?}`,
`list_jobs {namespace}`, `list_events {namespace, sinceMinutes?, warningsOnly?}`,
`read_logs {namespace, pod, container?, tailLines?, sinceMinutes?, previous?}`.

Configuration keys (Settei, documented in `docs/operations/configuration.md`):

```text
capabilities.k8s_observe.mode                     SHIKIGAMI_K8S_OBSERVE_MODE                     disabled | in_cluster | explicit (default disabled)
capabilities.k8s_observe.namespaces               SHIKIGAMI_K8S_OBSERVE_NAMESPACES               comma-separated, required when enabled
capabilities.k8s_observe.api_server_url           SHIKIGAMI_K8S_OBSERVE_API_SERVER_URL           explicit mode only
capabilities.k8s_observe.token_file               SHIKIGAMI_K8S_OBSERVE_TOKEN_FILE               explicit mode only
capabilities.k8s_observe.ca_file                  SHIKIGAMI_K8S_OBSERVE_CA_FILE                  explicit mode only
capabilities.k8s_observe.max_log_lines            SHIKIGAMI_K8S_OBSERVE_MAX_LOG_LINES            default 200
capabilities.k8s_observe.max_log_bytes            SHIKIGAMI_K8S_OBSERVE_MAX_LOG_BYTES            default 65536
capabilities.k8s_observe.max_items                SHIKIGAMI_K8S_OBSERVE_MAX_ITEMS                default 100
capabilities.k8s_observe.request_timeout_seconds  SHIKIGAMI_K8S_OBSERVE_REQUEST_TIMEOUT_SECONDS  default 10
```

RBAC manifest, saved as `docs/operations/k8s-observe-rbac.example.yaml` and repeated in
`docs/operations/k8s-observe.md`. One `Role` and `RoleBinding` per observed namespace; the subject
is Shikigami's service account in the namespace where Shikigami runs:

```yaml
apiVersion: rbac.authorization.k8s.io/v1
kind: Role
metadata:
  name: shikigami-k8s-observe
  namespace: demo
rules:
  - apiGroups: [""]
    resources: ["pods", "pods/log", "events"]
    verbs: ["get", "list"]
  - apiGroups: ["apps"]
    resources: ["deployments", "replicasets", "statefulsets"]
    verbs: ["get", "list"]
  - apiGroups: ["batch"]
    resources: ["jobs", "cronjobs"]
    verbs: ["get", "list"]
  - apiGroups: ["metrics.k8s.io"]
    resources: ["pods"]
    verbs: ["get", "list"]
---
apiVersion: rbac.authorization.k8s.io/v1
kind: RoleBinding
metadata:
  name: shikigami-k8s-observe
  namespace: demo
roleRef:
  apiGroup: rbac.authorization.k8s.io
  kind: Role
  name: shikigami-k8s-observe
subjects:
  - kind: ServiceAccount
    name: shikigami-observer
    namespace: demo
```

External services: a Kubernetes API server reachable from the worker; for live tool calls,
Kikan-En and Shomei configured as in `docs/operations/action-authorization.md`. Optional:
metrics-server for `pod_metrics`.
