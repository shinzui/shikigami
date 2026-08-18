---
type: Improvement Request
title: Add authorized cross-cluster diagnostic tools to Shikigami
description: Add durable broker, probe, authorization, and typed telemetry-tool paths without exposing production credentials.
timestamp: "2026-07-30T00:41:00Z"
generated:
  by: human:nadeem
  at: "2026-07-30T00:41:00Z"
requestId: IR-2
status: proposed
origin: mori://shinzui/kikan
---

# Improvement Request: add authorized cross-cluster diagnostic tools to Shikigami

**Authored by:** `shinzui/kikan` agents while validating
`mori://shinzui/kikan/okf/use-cases/concepts/UC-5`.
**Addressed to:** `shinzui/shikigami` agents, with `shinzui/shikumi` owning typed tool adapters and
`shinzui/kikan-en` owning authorization vocabulary.
**Status:** proposed; required for use case 005.
**Contracts:** C5, C11, C13, and the proposed cross-cluster diagnostics contract.
**Created:** 2026-07-24.


## Why

Shikigami can run declared agents, durably execute workflows, and delegate to child agents inside the
same runtime. Shikumi supplies typed tools and a `ToolEnv` seam. Those are useful foundations, but the
live source has three gaps for production diagnosis:

1. `schema/Agent.dhall` cannot declare a remote diagnostic tool source.
2. `Shikigami.Sink.Permission` still uses a static sink grant table; the specified Kikan-En
   `checkAction` integration is not present at tool dispatch.
3. There is no durable broker, outbound production probe, or typed Kubernetes/telemetry adapter.

Using Shikumi's `localToolEnv` in a production cluster would be unsafe because it intentionally
exposes the host filesystem, environment, and arbitrary shell under the runtime's current
permissions. Directly exporting a Kubernetes token or Grafana/Prometheus credential to the central
agent would move the production trust boundary into Kikan.


## Requested architecture

Add a cross-cluster diagnostics slice with four separable parts.

### 1. Contract package

Consume Kikan's versioned `DiagnosticTarget`, `DiagnosticRequest`, `EvidenceBundle`, operation,
error, lifecycle, and authorization-proof schemas. Generate or hand-author Haskell types with
round-trip and schema-conformance tests. Shikigami must not invent private field names or operation
aliases.

The contract types should live in a small package that the broker, probe, Shikumi adapters, tests,
and future non-Haskell probes can consume without importing the full Shikigami runtime.

### 2. Diagnostic broker

Add a serving component that:

- accepts only requests already authorized by Shikigami;
- persists request state and terminal results;
- routes by canonical cluster id;
- supports outbound probe registration, capability advertisement, heartbeats, delivery, result
  submission, and protocol-version negotiation;
- enforces idempotency, expiry, cancellation, maximum request/result size, and attempt limits;
- correlates request, agent run, incident, probe, En decision, and distributed trace;
- verifies the probe service identity;
- exposes no raw Kubernetes or observability credentials;
- returns typed unavailable, expired, denied, unsupported, limit, backend, and protocol errors.

Use Shikigami's existing durable workflow/inbox substrate where it fits. Do not create another
long-lived task model merely because the transport crosses a cluster boundary.

The production probe initiates the connection. Polling, streamed HTTP, or a mutually reachable
message broker may be selected through a prototype, but the observable semantics above must not
depend on the transport.

### 3. Production diagnostic probe

Add a constrained executable or deployment mode that:

- has no model provider, prompt, general Shikigami behavior, arbitrary shell, code-writing tools, or
  normal agent sinks;
- authenticates the broker and presents its own Shomei service identity;
- verifies the En Biscuit's signature, audience, expiry, subject, permission, target, operation,
  incident, window, and resource bounds;
- applies a second local allow-list for cluster, namespace, service labels, operations, and limits;
- executes with local Kubernetes ServiceAccount and telemetry credentials;
- redacts before returning data;
- records a local audit event and result hash;
- fails closed on unknown fields, versions, operations, permissions, or policies.

The first implementation may be a package and executable in Shikigami. If operations, release
cadence, or threat-boundary review later justify a separate project, extract it while preserving the
contract and conformance fixtures.

### 4. Shikumi diagnostic tools

Add typed tool definitions for:

```text
kubernetes.get_workload_status
kubernetes.list_workload_pods
kubernetes.get_events
kubernetes.get_recent_logs
logs.search
metrics.query_range
traces.find
traces.get
grafana.get_alert_rule
grafana.get_dashboard_panel
```

The central tool implementation authorizes and submits a diagnostic request, awaits a terminal
result, and decodes the evidence bundle. The probe-side implementation calls only the configured
local API adapter.

The two sides must not expose a generic `run_command`, `kubectl`, `http_request`, provider query
string, or MCP tool passthrough. The first metrics and log queries should be named templates whose
service selector and bounds are injected by trusted code.


## Agent declaration and tool discovery

Extend the agent declaration with an explicit diagnostic capability request. The precise Dhall shape
belongs to the Shikigami plan, but it must identify:

- the diagnostic tool source;
- allowed operation names;
- allowed target aliases or service-relative target resolution;
- optional per-agent limits that can only attenuate platform limits.

The declaration controls which tool definitions the model sees. It is not authority. Every
invocation calls Kikan-En `checkAction` for the authenticated agent, exact permission, and canonical
`observability_target`.

Generic MCP support is not a prerequisite. Native Shikumi tools can implement the use case first. If
MCP later exposes them, MCP is an agent-facing adapter over the same authorization and broker
workflow; it does not replace either and cannot supply a wider operation surface.


## Kubernetes adapter constraints

The probe's Kubernetes client may read only the approved namespace-scoped resources needed for
workload state, pods, events, and pod logs. The corresponding deployment must not grant:

```text
secrets
configmaps unless explicitly justified
pods/exec
pods/attach
pods/portforward
nodes/proxy
workload create, update, patch, or delete
impersonation
token or certificate signing
```

The adapter must inject namespace and service selectors from the authorized target. It cannot trust a
model-supplied namespace or arbitrary field selector. Because Kubernetes RBAC cannot naturally limit
dynamically named pods by workload label, the documentation must state that the namespace is the
underlying Kubernetes trust boundary unless separate namespaces or ServiceAccounts provide a smaller
one.


## Telemetry adapter constraints

Each adapter has hard platform limits and lower request limits:

- maximum evidence window;
- maximum future/old timestamp skew;
- maximum series, samples, log lines, traces, spans, and bytes;
- maximum backend execution time;
- maximum concurrent requests per probe and target;
- rate limit per agent and incident;
- allow-listed labels, fields, templates, or query operators;
- redaction and sensitive-label rules.

The probe queries the configured metrics, logs, and trace stores. It does not query the
OpenTelemetry Collector. Grafana operations read alert-rule and dashboard-panel metadata only; they
do not grant blanket data-source proxy access.

Direct pod logs are a separately authorized fallback. Centralized logs are the default.


## Evidence handling

Every result must preserve:

- target and request id;
- collection and observation timestamps;
- source backend and executed safe-query identifier;
- Kubernetes resource version or telemetry backend provenance where available;
- truncation, sampling, and redaction;
- partial errors;
- post-redaction result hash.

Logs, annotations, metric labels, span attributes, and exception messages are untrusted input. The
tool result presented to the model must identify them as evidence and keep system instructions,
authorization policy, and tool metadata outside that content channel.

Shikigami may publish a compact conclusion and provenance to Danwa, Kawa, or Rei through its normal
authorized sinks. It must not automatically persist the raw evidence bundle as organizational
memory.


## Durable and audit behavior

Every tool invocation records:

```text
agent run and session
incident and activity
request id and idempotency key
operation and target
requested and enforced bounds
Shomei principal
En decision id and proof expiry
probe identity
state transitions and delivery attempts
result size, redaction/truncation counts, and hash
terminal outcome and latency
```

The audit log must never contain tokens, local credentials, or unredacted raw evidence. Replayed
workflow steps must observe the journaled terminal result rather than re-running a production query.


## Required tests

The implementation must pass Kikan's cross-cluster diagnostic conformance suite and add project-level
tests for:

1. exact allow and target/operation deny through live `checkAction`;
2. proof tampering and expiry rejected at the probe;
3. request replay executes the local adapter at most once;
4. workflow crash after enqueue resumes without a duplicate production query;
5. probe disconnect, reconnect, version mismatch, and unsupported capability;
6. deadline and cancellation before and during execution;
7. backend timeout and partial evidence;
8. deterministic redaction, truncation, and result hashing;
9. selector injection proving an agent cannot broaden namespace or service;
10. unknown operation and arbitrary shell/HTTP requests denied;
11. raw evidence absent from durable organizational-memory outputs;
12. a complete local demonstration from alert fixture to evidence-backed Danwa triage.


## Acceptance

With Kikan and a fixture target cluster running, an operator can trigger the use case 005 alert and
observe:

- Shikigami exposes only the steward's declared diagnostic tools.
- An allowed workload-status, log, metric, and trace request returns bounded evidence from the
  granted service.
- The same agent is denied another service and every undeclared or ungranted operation.
- Production exposes no inbound endpoint and no credential appears in the Kikan agent environment.
- Stopping the probe yields `target_unavailable` without delaying the human Alert.
- Replaying the workflow does not repeat the production query.
- Broker and probe audit records correlate by request id and result hash.


## Non-goals

This request does not add operational mutation, shell execution, pod exec, unrestricted backend query
languages, public production ingress, permanent raw telemetry memory, or a full production-side
agent. Cross-runtime agent delegation is a separate follow-on request.
