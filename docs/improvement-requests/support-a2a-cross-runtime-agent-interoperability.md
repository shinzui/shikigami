---
type: Improvement Request
title: Support A2A cross-runtime agent interoperability
description: Implement authenticated, authorized, durable delegation between independently deployed Shikigami runtimes.
timestamp: "2026-07-30T00:45:00Z"
requestId: IR-6
status: proposed
origin: mori://shinzui/kikan
---

# Improvement Request: Support A2A Cross-Runtime Agent Interoperability

## Status

**Proposed.** Adopt the Agent2Agent (A2A) protocol as Shikigami's standard external
agent-to-agent surface. This request turns Kikan's transport-neutral cross-runtime delegation
request into an owner-side Shikigami design. It does not claim implementation, and it does not
make A2A a prerequisite for the smaller broker/probe path in Kikan Use Case 005.

The implementation baseline is **A2A protocol 1.0**. Pin the initial normative schema snapshot
to the upstream `v1.0.1` release, but advertise and negotiate the major/minor wire version
`1.0`: A2A patch versions do not participate in wire negotiation. Do not silently fall back to
0.3 semantics.


## Context

Shikigami already has the right local execution primitive. `Shikigami.Agent.Delegate.delegate`
starts a deterministic Keiro child workflow, pre-journals its `RunJob`, records Kioku
parent/child lineage, and lets the parent suspend in `awaitDelegated`. That primitive is local:
the target is an agent name in the same workflow registry and the child has no runtime address.

The pending first-class delegation plan,
`docs/plans/35-delegation-as-a-first-class-declared-capability.md`, adds a declaration
allow-list, cycle detection, a durable tree-wide child budget, a Flow capability, and partial
result handling. Those rules remain the local and remote governance foundation. A2A is not a
second delegation model; it is the external transport and task lifecycle used when the target
address names another runtime.

The pending service-boundary plan,
`docs/plans/36-align-shikigami-with-the-six-package-deployed-service-architecture.md`, fixes
six packages: `shikigami-core`, `shikigami-api`, `shikigami-server`, `shikigami-workers`,
`shikigami-migrations`, and `shikigami-client`. This request preserves that package set. Do
not add a seventh `shikigami-a2a` package.

A2A 1.0 supplies the interoperable vocabulary Shikigami otherwise would have to invent:

- an `AgentCard` for identity, skills, interfaces, capabilities, and security requirements;
- `Message`, `Part`, `Task`, `TaskStatus`, and `Artifact` objects;
- send, inspect, list, cancel, stream, subscribe, push-notification, and extended-card
  operations;
- HTTP+JSON, JSON-RPC, and gRPC bindings; and
- protocol extensions for information not carried by the core model.

The standard deliberately does not define Kikan's authority model, durable global delegation
budget, lineage/cycle rules, result schema, or data-handling classes. Those remain Kikan
contracts carried through a versioned A2A extension and enforced independently by the target
runtime.


## The Request

Add an A2A client and server vertical to Shikigami, backed by its existing durable workflow
runtime and the Kikan trust boundary.

### 1. Fix the protocol and binding baseline

Implement A2A protocol version `1.0` from an integrity-checked snapshot of upstream
`specification/a2a.proto` at tag `v1.0.1`.

The first transport is the standard **HTTP+JSON binding**:

- HTTPS in production;
- `Content-Type: application/a2a+json` for A2A request and response bodies;
- `A2A-Version: 1.0` on every client request;
- `A2A-Extensions` for negotiated Kikan extensions;
- the standard HTTP+JSON paths and methods; and
- the standard `google.rpc.Status` JSON error representation, including A2A error details.

The A2A route subtree is therefore an explicit exception to Shikigami's ordinary RFC 7807
application-error envelope. Do not wrap A2A errors in `ProblemDetails` or expose the ordinary
Shikigami API shape at an A2A interface URL.

The first release supports:

| Operation | First-release behavior |
|---|---|
| `SendMessage` / `POST /message:send` | Supported; creates or continues a durable Shikigami-backed task. |
| `GetTask` / `GET /tasks/{id}` | Supported and caller-scoped. |
| `ListTasks` / `GET /tasks` | Supported with bounded pagination and caller-scoped filtering. |
| `CancelTask` / `POST /tasks/{id}:cancel` | Supported and propagated into Keiro cancellation. |
| Public Agent Card | Supported for every A2A-exposed declared agent. |
| `SendStreamingMessage` and `SubscribeToTask` | Initially unsupported and advertised as `streaming: false`; return the standard unsupported-operation error. |
| Push-notification configuration CRUD | Initially unsupported and advertised as `pushNotifications: false`; return the standard unsupported-operation error. |
| Extended Agent Card | Initially optional. If absent, advertise `extendedAgentCard: false` and return the standard unsupported-operation error. |

JSON-RPC, gRPC, SSE streaming, and push notifications are later additive capabilities. Do not
advertise one until its complete operation set, ordering rules, authentication, restart
behavior, and negative conformance tests pass.

For non-streaming `SendMessage`, honor `SendMessageConfiguration.returnImmediately`:

- `true` returns the newly accepted non-terminal Task immediately;
- `false` or absent waits until the Task reaches a terminal or interrupted A2A state; and
- a transport disconnect never cancels the durable task implicitly.

Set explicit application and proxy timeouts that are coherent with the maximum blocking wait.
Callers of long-running agents should request `returnImmediately = true` and poll. If a client or
proxy nevertheless disconnects from a blocking request, the durable Task continues and the caller
can recover it by replaying the same idempotency identity; the server must not return a non-terminal
Task early when the selected A2A semantics require it to wait.

### 2. Keep a checked normative protocol snapshot

Add a protocol provenance manifest recording:

- upstream repository and tag;
- exact `a2a.proto` commit and SHA-256;
- supported A2A major/minor versions;
- implemented binding and optional capabilities; and
- the command that checks the local codecs and fixtures against the pinned snapshot.

Do not opportunistically copy types from an SDK or blog post. The upstream Protocol Buffer
definition is normative. Mori currently has no registered `proto-lens`, Protocol Buffers, or
gRPC Haskell project, so an implementation plan must use Mori plus Hackage and upstream release
tags before selecting a generator or new dependency. The first HTTP+JSON slice may use
hand-authored Haskell types and Aeson codecs only if golden fixtures prove exact ProtoJSON field
names, enum values, one-of representation, required-field behavior, timestamp formatting, and
unknown-field handling.

### 3. Expose declared agents deliberately

Add an optional A2A exposure block to the canonical `schema/Agent.dhall`. Existing manifests
must remain valid and unexposed by default.

Conceptually:

```dhall
, a2a = Some
    { version = "1.0"
    , public = False
    , agentVersion = "2026.07.1"
    , defaultInputModes = [ "application/json" ]
    , defaultOutputModes = [ "application/json" ]
    , skills =
        [ { id = "diagnose-service"
          , name = "Diagnose service"
          , description = "Produce a bounded, typed diagnostic evidence bundle"
          , inputModes = [ "application/json" ]
          , outputModes = [ "application/json" ]
          }
        ]
    }
```

The concrete schema may refine the names, but it must preserve these invariants:

1. A declared agent is not remotely invocable merely because it exists or appears in a local
   `delegates` list.
2. Agent Card skills come from reviewed declaration data, never inferred from prompts, tools,
   trigger payloads, or model output.
3. Every skill has a stable identifier and explicit input/output media types.
4. Agent version is independent of A2A protocol version.
5. A paused, deactivated, or locally disabled agent is never advertised as available and
   refuses new tasks even if a stale Agent Card remains cached.
6. Public cards contain no internal prompts, tool inventories, credentials, filesystem paths,
   private endpoints, or undisclosed agent names.

Model each exposed declared agent as an A2A remote-agent identity even when several agents share
one Shikigami server. The `tenant` value in the selected `AgentInterface` is a stable,
configuration-owned routing value derived from the canonical agent principal, not an arbitrary
string supplied by a prompt.

Serve a public card at the standard well-known URI only when the deployment has one configured
default public agent. Also support configured/direct card URLs for individual exposed agents so
Meibo or another curated registry can index more than one card per runtime. The Agent Card's
interface URL is assembled from validated deployment configuration; never trust inbound host or
forwarded headers to mint it.

Support JWS-signed Agent Cards before cards are accepted across separately administered Kikan
installations. Canonicalize card JSON with RFC 8785, exclude the signature field, publish key ids
and JWKS locations, support rotation, and reject revoked or expired verification keys. Use
Shomei-managed identity/key material where its interfaces fit; do not store signing keys in agent
declarations.

### 4. Add runtime-qualified remote delegation declarations

Keep plan 35's `delegates : List Text` for local targets. Add a distinct remote-target
declaration rather than overloading a text name with URL semantics.

The transport-neutral address contains at least:

```text
runtime principal id
agent principal id
Agent Card reference or trusted registry key
required A2A major/minor version
required Kikan extension versions
```

A remote-delegate entry additionally bounds:

- allowed task/skill ids;
- accepted input and result schema ids;
- maximum child count, depth, tokens, cost, and duration;
- allowed input and output data-handling classes;
- whether standard A2A without Kikan's governance extension is permitted;
- retry/cancellation policy; and
- explicit fallback behavior when the target is unavailable.

URLs are resolved from trusted configuration or a verified directory record. An LLM, tool
result, inbound message, or trigger payload may select only among declaration-authorized remote
addresses; it may not introduce a new URL, runtime, Agent Card, tenant, or protocol downgrade.

Local and remote targets share plan 35's root delegation budget and cycle rules. A remote edge
reserves a durable child slot before any network request and uses the same reservation for every
retry. Falling back from remote to local is a new delegation decision and must be explicitly
declared, authorized, and journaled; never silently substitute an agent with a similar name.

### 5. Define a required Kikan delegation extension

Register and document a versioned A2A extension URI for governed Shikigami-to-Shikigami
delegation. The extension carries or binds the information the A2A core model does not define:

- delegation id and retry-stable idempotency key;
- source and target runtime and agent principals;
- parent run, workflow, session, and A2A context/task references;
- complete runtime/agent lineage and current global depth;
- root budget id plus requested token, cost, time, and child-count attenuation;
- deadline and cancellation correlation;
- trace context;
- task type, input schema id, permitted result schema id, and data-handling class;
- authorization-decision reference or proof binding; and
- result provenance and content hash.

Declare the extension as required on Agent Cards whose skills cannot safely run without it.
If the caller does not advertise support, fail with A2A's required-extension error before a
workflow, task row, or existence-revealing lookup is created.

Use the A2A core objects as intended:

- the initiating request is a `Message` with a stable client `messageId`;
- typed task input is a JSON `DataPart` with an explicit media type and schema reference;
- long-running work is always an A2A `Task`, not a direct response `Message`;
- results are `Artifact` values, not status messages;
- `contextId` maps to the durable remote interaction/session correlation;
- follow-up input names the existing `taskId` and matching `contextId`; and
- critical results are durable task state/artifacts, never stream-only messages.

Map Shikigami outcomes onto A2A states explicitly:

| Shikigami outcome | A2A state |
|---|---|
| accepted but not started | `TASK_STATE_SUBMITTED` |
| executing or awaiting a child | `TASK_STATE_WORKING` |
| awaiting ordinary caller input | `TASK_STATE_INPUT_REQUIRED` |
| awaiting an out-of-band credential or authorization decision | `TASK_STATE_AUTH_REQUIRED` |
| completed with validated artifacts | `TASK_STATE_COMPLETED` |
| failed after acceptance | `TASK_STATE_FAILED` |
| cancelled | `TASK_STATE_CANCELED` |
| denied, unsupported, invalid before execution, or disabled target | `TASK_STATE_REJECTED` when a Task exists, otherwise the appropriate protocol error |
| deadline expired before acceptance | rejection/error; no child run |
| deadline expired after acceptance | `TASK_STATE_FAILED` with a typed Kikan extension reason of `expired` |

An A2A state transition is not itself authorization. `TASK_STATE_AUTH_REQUIRED` requests
authorization; only the actual Shomei/Kikan-En decision permits the protected action.

### 6. Make inbound tasks normal durable Shikigami runs

The A2A server adapter must perform this ordered boundary:

1. validate TLS-facing request limits, media type, A2A version, required extensions, and JSON;
2. authenticate the caller;
3. resolve the target tenant to one exact exposed agent without fallback;
4. authorize visibility and the requested skill before revealing whether prior tasks exist;
5. validate the Kikan extension, lineage, schemas, data class, deadline, and budgets;
6. deduplicate the caller identity plus message/delegation id;
7. create the A2A Task and enqueue one ordinary local agent run atomically; and
8. project subsequent workflow state and outputs into Task status and Artifacts.

The target runtime makes its own decision. A source declaration, signed Agent Card, Shomei token,
or parent Kikan-En proof is never sufficient authority by itself. The target may reduce budgets,
tools, sinks, output schema, or result visibility but may not broaden them.

An accepted inbound A2A run uses the same agent loader, lifecycle gate, workflow registry,
Kioku session machinery, tool authorization, sink authorization, timeouts, and observability as
any other Shikigami run. Do not create a simplified A2A execution path that bypasses
`agentRunWorkflow`.

`CancelTask` durably requests Keiro workflow cancellation. Cancellation is idempotent, preserves
the terminal audit record, and propagates best-effort to descendants using plan 35's child handles
and remote cancellation correlations. A client disconnect, expired bearer token, or failed polling
request does not cancel the Task.

### 7. Make outbound delegation a durable client process

An agent workflow must not perform an unjournaled HTTP call and then hope to record the remote
task id. Use a durable outbound request/result seam:

1. The local workflow validates the declaration, reserves its global child budget slot, and
   appends one `RemoteDelegationRequested` record/outbox item under a deterministic delegation id.
2. An A2A client dispatcher owned by the `shikigami-client` package claims that item, resolves and
   verifies the Agent Card, acquires credentials, and sends the A2A message.
3. It durably records the selected interface, card digest, remote Task id/context id, attempts,
   and next polling time before acknowledging delivery.
4. It polls with bounded backoff, or later consumes a verified stream/push update, until the Task
   is terminal or interrupted.
5. It publishes a correlated result/update that resumes the parked parent workflow exactly once.
6. Cancellation and deadline records are delivered through the same durable path.

The dispatcher is a separate executable/process component inside the existing
`shikigami-client` package; it is not started inside `shikigami-server`, and
`shikigami-workers` does not import the API or client package. The queue/job types needed by both
the core workflow and dispatcher live in `shikigami-core`; `shikigami-client` already reaches core
through the six-package dependency graph.

Client behavior must:

- require HTTPS outside an explicit local-test profile;
- verify the server certificate and, when present/required, an Agent Card signature;
- select only a declared `supportedInterfaces` entry with HTTP+JSON and protocol `1.0`;
- refuse redirects or DNS/IP changes that escape the configured trust boundary;
- enforce request, response, part, artifact, history, and total-task size limits;
- classify protocol rejection separately from transient transport failure;
- never retry a non-idempotent operation under a new delegation/message id;
- cache cards with bounded freshness and persist the exact card digest used for a dispatch; and
- reject a changed card that broadens or redirects authority until trusted configuration or the
  directory accepts it.

### 8. Persist task truth and idempotency

Use the event/workflow journal as durable execution truth and database read models/coordination
tables for the A2A resource surface. Add migrations for at least these concepts, with final names
chosen by the implementation plan:

- inbound A2A Task ↔ workflow/run/session correlation;
- caller-scoped message/delegation idempotency;
- task status transition projection;
- artifacts and artifact-part metadata/provenance;
- outbound dispatch/interface/card-digest/remote-task correlation;
- delivery, poll, and cancellation attempt scheduling; and
- push-notification configuration only when that capability is implemented.

Server-generated Task ids are stable opaque ids. The same authenticated caller replaying the same
Kikan delegation id/message id receives the original Task and never starts another workflow.
Reusing an id with different normalized content is a conflict and creates no work. At-least-once
queue delivery, HTTP retry, process restart, and parent workflow replay must all converge on the
same local/remote Task pair.

`ListTasks` and `GetTask` query only caller-authorized projections. Perform authorization before a
lookup that could distinguish “not found” from “exists but forbidden.” Bound history length, page
size, artifact inclusion, and response bytes regardless of caller input.

### 9. Compose Shomei identity with Kikan-En authorization

Use standard A2A security declarations and ordinary HTTP authorization headers:

- Shomei authenticates the calling runtime/service and issues short-lived, audience-bound OAuth2
  client-credentials tokens;
- the on-behalf-of agent identity is a distinct, verified claim/correlation, not a caller-chosen
  string;
- the Agent Card declares the actual OAuth2/OpenID Connect scheme and scopes;
- every A2A operation authenticates independently; and
- TLS, issuer, audience, signature, subject, expiry, and disabled-principal checks fail closed.

Use coarse scopes such as invoke/read/cancel only for admission to the protocol operation class.
Kikan-En decides the exact source agent → target agent → skill/task-type relationship and every
protected tool/sink action taken inside the child. Extend Kikan-En's schema and conformance suite in
its owning repository; do not add an A2A-specific authorization table to Shikigami.

Any short-lived Kikan-En/Biscuit decision proof is sent in a security-reviewed extension header or
service parameter bound to the delegation, target, task type, budgets, data class, audience, and
expiry. Do not put bearer credentials or reusable proofs in `Message`, `Part`, `Artifact`, Agent
Card, workflow journal, logs, traces, or persisted raw task metadata.

Credentials requested through `TASK_STATE_AUTH_REQUIRED` are received out of band unless a later
security-reviewed extension defines an encrypted, target-bound in-band flow. A status transition or
follow-up prose message never grants authority.

### 10. Preserve Meibo and Mori ownership boundaries

Meibo is the canonical directory of live principals. Production remote-address resolution should
eventually use a Meibo record that binds runtime principal, agent principal, lifecycle, owner, card
reference/digest, and credential linkage. The first two-runtime proof may use explicit trusted
configuration, but it must exercise the same resolution interface and cannot treat a URL as identity.

Mori remains the project/source/document registry. It may document that a project ships an A2A
surface, but it is not the live A2A Agent Card registry and does not decide whether a runtime or agent
is active.

### 11. Emit attributable observability without leaking content

Both client and server record:

- delegation id, local and remote Task ids, context id, and workflow/run/session correlation;
- authenticated source and target principals;
- selected Agent Card digest, interface, binding, and protocol/extension versions;
- lineage depth and root budget id;
- requested and enforced budget summary;
- authorization decision ids/outcomes without tokens;
- delivery attempts, state transitions, retry class, cancellation, and timeout propagation;
- artifact schema, size, provenance, and hash; and
- terminal outcome and latency.

Propagate W3C trace context across the A2A HTTP boundary and link client/server spans to the durable
workflow. Do not log request/response bodies, prompts, raw task inputs, raw artifacts, credentials,
authorization proofs, query values, or full Agent Cards. Data retention follows the target's policy;
an A2A message does not automatically become Kawa, Danwa, or Kioku content.

Publish compact A2A lifecycle activities to Kawa only through the ordinary Shikigami activity sink
and its authorization path. Danwa is used only when a declared workflow deliberately creates or
attaches a human conversation. Kioku stores session/memory content only according to the agent's
memory policy. A2A must not write those systems implicitly.


## Package Ownership

Honor the six-package architecture:

| Package | A2A ownership |
|---|---|
| `shikigami-core` | Transport-neutral remote-address/delegation types, Kikan extension model, state mapping, workflow integration, durable request/result records, task-store/client ports, and pure validation. No WAI/Servant server. |
| `shikigami-api` | Exact A2A 1.0 HTTP+JSON DTOs/codecs, headers, standard error objects, and typed route definitions, plus generated protocol documentation/fixtures. It may consume core ids and pure mappings. |
| `shikigami-server` | Agent Card rendering/serving, authentication middleware, A2A handlers, caller-scoped task queries, inbound task creation, cancellation, and mapping between API DTOs and core commands/results. |
| `shikigami-workers` | Processing the core-owned inbound task/run and remote-result queues, resuming workflows, projecting task state/artifacts, and scheduling durable work. It imports core, not API/server/client. |
| `shikigami-migrations` | A2A correlation, idempotency, projection, outbox, delivery-schedule, and optional push-config schema. No production sibling dependency. |
| `shikigami-client` | Reusable HTTP+JSON A2A client, Agent Card resolution/verification, polling/cancellation, and the durable outbound dispatcher executable. It consumes API/core through the allowed graph. |

Module names remain vertical and domain-first (`Shikigami.A2A.*`) across packages. Technical
composition stays in the plan-36 allow-listed server/worker namespaces. If implementation reveals
that the six-package dependency graph cannot express the dispatcher without a cycle, revise plan 36
explicitly before coding; do not hide an illegal sibling dependency or add an unplanned seventh
package.


## Delivery Sequence

1. Land or reconcile plan 36's six-package boundaries and plan 35's local declaration,
   lineage, cycle, and durable budget semantics.
2. Pin the A2A schema, implement codecs/fixtures, and add the disabled-by-default declaration
   surface.
3. Implement caller-scoped task persistence plus the non-streaming HTTP+JSON server operations.
4. Implement the durable outbound dispatcher and two-runtime task/result/cancellation path.
5. Integrate Shomei, Kikan-En, Meibo lifecycle/resolution, signed cards, and the required Kikan
   extension before any production or cross-organization exposure.
6. Add streaming, subscription, push notifications, authenticated extended cards, and more protocol
   bindings only as separately advertised, fully tested capabilities.

Use Case 005's constrained diagnostic broker/probe, typed operations, and per-action authorization
remain prerequisites for using a remote edge agent to diagnose production. A2A does not replace that
security boundary.


## Acceptance Sketch

The request is accepted when an automated two-runtime proof demonstrates all of the following:

1. Runtime A discovers one exposed agent on runtime B from a valid A2A 1.0 Agent Card.
2. The client selects HTTP+JSON `1.0`, sends `A2A-Version: 1.0`, and refuses a card/interface that
   only supports 0.3 or an undeclared required extension.
3. An authorized parent sends one typed message and receives one server-generated Task backed by
   one normal Shikigami workflow.
4. `returnImmediately = true` returns a non-terminal task; the blocking form returns at the first
   terminal/interrupted state.
5. Polling reaches one validated Artifact whose schema/provenance identify runtime B, the target
   agent, child run, and evidence sources.
6. Replaying the parent workflow, outbound queue item, HTTP request, or inbound queue item creates no
   second remote Task or child workflow.
7. Reusing the same delegation/message id with changed content fails without execution.
8. Restarting the client dispatcher, server, workers, or either database projection resumes the same
   correlated task.
9. An ungranted runtime/agent, disabled target, unknown tenant, undeclared skill, wrong audience,
   expired token, invalid card signature, and unsupported version/extension each fail closed.
10. `GetTask`, `ListTasks`, cancellation, subscription, and push-config operations do not reveal a
    task to another authenticated caller.
11. Global depth, child-count, token, cost, duration, deadline, result-schema, and data-class bounds
    survive the runtime boundary and cannot be broadened by B.
12. A supplied lineage cycle is rejected before child creation.
13. Cancellation reaches a running remote child and both sides converge on correlated terminal
    states without deleting audit history.
14. Target-side Kikan-En still denies an ungranted tool or sink even after delegation admission.
15. `TASK_STATE_INPUT_REQUIRED` parks and resumes on a same-task follow-up message with matching
    context; a mismatched context/task pair is rejected.
16. `TASK_STATE_AUTH_REQUIRED` alone authorizes nothing, and credentials/proofs never appear in
    stored task content, logs, traces, or artifacts.
17. Streaming, push, and extended-card requests return the standard unsupported errors while their
    Agent Card capability flags are false.
18. A paused/deactivated agent disappears from new discovery and refuses new work even when a stale
    previously signed card is presented.
19. Official A2A JSON fixtures round-trip through Shikigami's codecs, and a reference A2A client can
    exercise the supported operations without a Shikigami-specific transport fork.
20. The package-dependency gate still sees exactly the six plan-36 packages and no forbidden
    worker→API/server/client production edge.


## Out of Scope Here

- Using A2A for same-runtime delegation; local child workflows remain the direct path.
- Treating A2A as an LLM-provider API (`baikai`) or tool protocol (`shikumi`/MCP).
- Transparent migration of a running workflow between runtimes.
- Shared databases, workflow registries, Kioku stores, prompts, tools, or hidden model state.
- A public agent marketplace or dynamic prompt-selected endpoints.
- General chat federation; A2A messages serve task interaction, while Danwa remains Kikan's
  durable human/agent conversation substrate.
- Bypassing per-tool, per-sink, diagnostic-operation, or data-egress authorization.
- General remote shell, Kubernetes, remediation, or production mutation.
- Advertising streaming, push notifications, extended cards, JSON-RPC, or gRPC before their
  complete conformance and security work lands.


## References

- [A2A 1.0 specification](https://a2a-protocol.org/latest/specification/).
- [A2A `v1.0.1` release](https://github.com/a2aproject/A2A/releases/tag/v1.0.1).
- [A2A protocol repository](https://github.com/a2aproject/A2A).
- `mori://shinzui/kikan/okf/improvement-requests/concepts/IR-4` — originating
  transport-neutral contract.
- `mori://shinzui/kikan/okf/use-cases/concepts/UC-5` — motivating edge-runtime use
  case and sequencing constraint.
- `docs/plans/9-multi-agent-delegation-primitive.md` — shipped local durable primitive.
- `docs/plans/35-delegation-as-a-first-class-declared-capability.md` — local declaration,
  lineage, cycle, budget, and Flow governance prerequisite.
- `docs/plans/36-align-shikigami-with-the-six-package-deployed-service-architecture.md` — package
  boundary this request preserves.
- `docs/improvement-requests/consult-meibo-agent-lifecycle.md` — canonical lifecycle lookup.
- `schema/Agent.dhall`, `shikigami-api/src/Shikigami/Api/Agent.hs`, and
  `shikigami-core/src/Shikigami/Agent/Delegate.hs` — current declaration and delegation seams.
