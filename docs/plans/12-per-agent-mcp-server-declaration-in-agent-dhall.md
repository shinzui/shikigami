---
id: 12
slug: per-agent-mcp-server-declaration-in-agent-dhall
title: "Per-agent MCP server declaration in Agent.dhall"
kind: exec-plan
created_at: 2026-06-27T17:57:56Z
intention: "intention_01kx1tyzqcerzv4ysbktgr9sw9"
master_plan: "docs/masterplans/7-platform-feature-completion-egress-schema-memory-lifecycle-delegation.md"
provenance:
  revisions:
    - model: "gpt-6-astra"
      harness: "codex-cli"
      at: 2026-10-28T18:49:50Z
      mode: "update"
      note: "Apply overlay scope transfer and refresh MCP release, discovery authorization, schema binding and durable execution acceptance."
  reviews:
    - model: "gpt-6-astra"
      harness: "codex-cli"
      at: 2026-10-28T18:49:50Z
      verdict: "comments"
      note: "Author self-review: common foundations exist; released MCP adapter and consumer qualification remain required."
---

# MCP provider integration for declared capability overlays

The historical filename and frontmatter title identify this plan. Its effective
scope changed on 2026-08-22 and is reconciled throughout this body on 2026-10-28.
It does not add `mcpServers` to Agent.dhall. Implementation of the surviving
MCP-specific scope remains Not Started.

## Purpose / Big Picture

Let an agent request an operator-approved remote observation capability through
its existing `capabilityOverlays` list. The runtime connects to an MCP server,
discovers only a verified tool catalog, invokes authorized tools through the existing
model/execution machinery, and releases resources on every exit. MCP means Model
Context Protocol, the remote tool transport owned upstream; a capability overlay
is Shikigami's additive, operator-selected tool bundle.

For the hermetic proof, an agent requests a capability such as `mcp.echo`. The
operator catalog binds that id to an immutable descriptor/revision and a provider
factory with a local stub endpoint. The model sees the existing overlay namespace,
for example `overlay__mcp-echo__echo`, calls the observation, and incorporates its
result. The test proves authorization before connect, discovery and invocation,
correct remote method/name/schema, bounded execution, cleanup and durable replay.
Agent files contain no endpoint, credential reference, transport or provider handle.

This is the surviving integration capstone of
`mori://shinzui/baikai/masterplans/6-mcp-support-across-the-agent-stack`, coordinated
locally by MasterPlan 7. Its original schema/registry/loop work was superseded by
[MasterPlan 11](../masterplans/11-add-agent-scoped-capability-overlays-without-changing-base-capabilities.md).
Do not repeat that work or treat it as evidence that MCP already runs.

## Progress

- [x] (2026-10-28) Planning refresh reconciles the August scope amendment with the
  current schema, providers, C13 authorizer and durable execution tools.
- [x] Existing prerequisites supplied by plans 56–59: capability declaration,
  immutable catalog, additive registry, acquisition/release, bounded Skill tool
  loop, durable descriptor pinning and one-off harness integration.
- [x] Existing generic authorization: `Action/Authorization.hs` and
  `Capability/Provider.hs` check connection and each exact tool invocation.
  This is not MCP discovery integration or release/deployment qualification.
- [ ] M1: implement the selected pure binding contract and fake-lease fixtures; verify the released transport/adapter/auth handoff.
- [ ] M2: implement the bounded MCP provider and discovery/invocation adapter
  using existing exact-revision leases and C13.
- [ ] M3: wire the provider at supported composition roots and prove current
  durable execution, pinned evidence, cancellation and replay behavior.
- [ ] M4: hermetic end-to-end proof, failure/security matrix, operator docs and
  final accepted dependency/deployment evidence.

## Surprises & Discoveries

The old plan's main body contradicted its own August amendment: it still asked
for agent-authored server configuration and a second `ToolRegistry`/model loop.
Those common features now exist in `Capability/*`, `Behavior/*` and
`Execution/Tools.hs`. The actual declaration mirror is `Shikigami.Agent.Decl`.

C13 is implemented locally. The Kikan-En request document still says proposed;
that stale label cannot establish absence of the connection/invocation boundary.
However, the provider wrapper has no separate discovery callback today. Live MCP
`tools/list` introduces real IO that must receive its own fresh
`DiscoverCapabilityTools` decision, as ADR 0036 requires.

Release verification on 2026-10-28 used Hackage version metadata, downloaded source
archives and upstream peeled tags. `baikai 0.10.0.0` at
`03140cf60381ac154ebfa86d3bb2208d7df8626c` and `shikumi-tools 0.4.1.1` at
`db4eb373803552762edc9e86a231dfb529f8105b` still contain no MCP source modules.
Their owner requests remain proposed:
`mori://shinzui/baikai/okf/improvement-requests/concepts/IR-2` and
`mori://shinzui/shikumi/okf/improvement-requests/concepts/IR-1`.
The selected project uses older Baikai 0.7.2.0 and Shikumi Tools 0.4.0.0.
Updating a pin alone cannot provide the missing contracts.

`Shikumi.Tool` already supports dynamic tools, and Shikigami composes them. The
remaining adapter contract is remote protocol/schema/error mapping, not inventing
a new downstream dynamic-tool sum type. Likewise, closing a connection does not
undo a remote mutation or make retries safe.

## Decision Log

- 2026-10-28 follow-up: Adopt ADR 0065's content-derived MCP revision, explicit
  remote/logical mapping, approved schema contract, per-page discovery authority,
  protocol ceilings and supported execution matrix. M1 now implements and verifies
  these decisions instead of choosing them later.

- 2026-10-28: Apply the existing plan-56/57 ownership transfer throughout the plan.
  Retain the historical file/id and local MasterPlan parent; replace the obsolete
  schema, duplicate registry and single-completion-loop instructions.
- 2026-10-28: Consume current C13 connection/invocation checks and explicitly gate
  discovery IO. Keep upstream request reconciliation distinct from proof that an
  immutable deployable dependency closure and an MCP client exist.
- 2026-10-28: Preserve ADR 0025's final overlay naming and observation-only durable
  policy. The adapter maps upstream/native MCP names explicitly; no second final
  namespace or silent operation-class weakening is introduced.
- 2026-08-22: Plans 56–59 supersede `mcpServers` with provider-neutral capability
  requests, operator-owned configuration, common registry, loop and leases. This
  plan retains MCP transport integration and its authorization/credential proof.
- 2026-06-27/07-22 (retained intent): bracket remote resources, keep secrets out of
  agent/journal data, and require per-action authorization. The original per-agent
  server schema and stand-alone completion loop are superseded.

## Outcomes & Retrospective

No MCP transport implementation or runtime test was performed in this refresh.
The common foundations are delivered elsewhere; this child cannot complete until
released upstream contracts and the consumer acceptance matrix are demonstrated.
The local naming, schema binding, authority sequence, limits and supported-mode
decisions are selected in ADR 0065. Publication of the corresponding upstream
contracts and consumer acceptance remain delivery gates.

## Context and Orientation

An `AgentDecl` in `shikigami-core/src/Shikigami/Agent/Decl.hs` requests stable
`capabilityOverlays` ids. `Capability/Overlay.hs` defines immutable public descriptor
values, and `Capability/Catalog.hs` resolves requests against operator policy.
`Capability/Provider.hs` owns factories keyed by exact capability/revision, concrete
leases and LIFO cleanup; `Capability/Tools.hs` prevents base-tool replacement and
maps logical names into the final `overlay__*` namespace.

A provider returns a descriptor, its tools and a release action. Live endpoint,
transport, credentials and resources remain behind its factory. The provider must
match the pinned descriptor; dynamic remote discovery is not permission to alter
that descriptor. `Behavior/Run.hs` and `Behavior/Skill.hs` already consume a derived
registry. Do not replace their model loop or widen support to ShikumiProgram/Flow
by changing behavior dispatch.

`Execution/Tools.hs` is also a required consumer: new durable Skill execution
pins tool bindings/schema digests, reacquires only needed providers, and uses
accepted tool results after recovery. Existing older workflow branches still use
the behavior attempt. Both must be qualified; a one-off echo command alone proves
neither durable adoption nor replay safety. Read current plans
[82](82-pin-governed-execution-settings-for-agent-assignments.md) and
[83](83-recover-durable-model-and-tool-turns-with-composed-policies.md) before
changing this interface, preserving their in-progress work.

`Action/Authorization.hs` wraps Kikan-En's proof-verifying client.
`Capability/Provider.hs` authorizes `ConnectCapability` before acquisition and
`InvokeCapabilityTool` before each logical tool callback. Extend through the same
authority for discovery; transport credentials never substitute for authorization.
The project currently includes local Kikan-En contract/client packages. See
[the dependency cohort](../dependency-cohort.md) for the immutable-closure gap.

Read [ADR 0025](../adr/0025-capability-overlays-are-requests-for-additive-model-tools.md),
[ADR 0033](../adr/0033-recorded-agent-principals-key-durable-state.md),
[ADR 0036](../adr/0036-external-agent-actions-require-fresh-exact-authorization.md),
[ADR 0039](../adr/0039-deployment-roles-share-a-frozen-cabal-source-closure.md),
[ADR 0057](../adr/0057-skill-parents-admit-frozen-assignments-and-await-execution-children.md)
and [workflow versioning](../workflow-versioning.md). These own the existing durable boundary. ADR 0065 adds the selected MCP binding
contract without changing historical generic descriptor bytes.

## Plan of Work

### M1 — Accept the released producer/consumer contract

Use Mori to locate Baikai, Shikumi and Kikan-En source/docs. Verify authoritative
package metadata, source archives and upstream tags before choosing bounds. Record
actual public module/signature names here once released; do not compile against
the old hypothetical `Baikai.Mcp.Client`/`registerMcpTools` sketches or write a
private downstream JSON-RPC client to bypass the missing owner.

The required producer contracts are initialized connection lifecycle, bounded
transport/protocol failures, discovery and invocation including native remote
names, dynamic JSON schemas/results and opaque credential resolution. Authenticated
server support requires the corresponding released auth contract. The current
request handles are Baikai IR-2, Shikumi IR-1 and
`mori://shinzui/kikan-en/okf/improvement-requests/concepts/IR-3`.
Test the real C13 action contract, including `DiscoverCapabilityTools`, rather than
waiting on or declaring completion from request metadata.

Use the selected binding contract in
[ADR 0065](../adr/0065-mcp-provider-revisions-bind-the-approved-tool-contract.md).
Add `Capability/Mcp/Binding.hs` for a pure, versioned `McpBinding` with direct fields:
capability id, non-secret server id, transport kind, endpoint binding id and a
sorted list of approved tools. Each approved tool has an explicit `remoteName`,
`logicalName`, operator-authored description, input JSON schema, optional output
schema and `Observation` operation class. Endpoint binding ids resolve through
operator configuration; credentials and live URLs/handles never enter the agent
or durable snapshot. Changing endpoint identity requires a new endpoint binding
id and revision; rotating a secret behind the same reference does not. Make the
endpoint binding id content-derived from the canonical non-secret endpoint/transport
configuration and verify it when constructing the factory. Reject credentials in
URLs. A mutable alias resolving to a different endpoint under the same id must
fail startup, rather than silently redirect a pinned tool to another server.

For the proof, capability `mcp.echo` maps native remote name `echo` to logical
`echo`, producing final name `overlay__mcp-echo__echo`. Never split a constructed
`mcp__*` string to recover names. Require the released adapter to expose native
name/schema metadata, or a supplied explicit mapping; this is a Shikumi IR-1
acceptance requirement. Logical names match `[a-z][a-z0-9_-]{0,63}`; enforce unique
remote/logical names and common final-name collision checks. Unapproved remote
tools may be discovered but are never exposed or called. Missing approved tools,
duplicate native names or changed approved input/output schemas fail acquisition.
Remote descriptions never replace the pinned operator-authored descriptions.

Derive the immutable capability revision as `mcp-v1-` plus the existing
`Decision.Contract.versionedDigest` over the domain `shikigami.mcp-binding/1` and
the complete public binding (including limits). Use the existing canonical encoder,
sort the tool list by logical name, preserve JSON schema arrays and do not invent
semantic schema equivalence. Reordered object keys compare equal through canonical
encoding; any other schema difference requires a new binding revision. The existing
CapabilityDescriptor pins this content-derived revision, so no generic descriptor
field or old JSON codec changes are needed. Resolve only the exact stored binding;
recompute its digest at startup and refuse an edited revision. Retain historical
bindings for pending accepted work. `Execution/Tools.hs` continues deriving its
existing per-tool schema digest from this same approved schema.

Discovery is once per successful acquisition, never an in-place refresh. The
provider factory captures the current `ActionAuthorizer`; after connection and
immediately before each list request/page it requests `DiscoverCapabilityTools`
for the same capability/revision/principal used at Connect. Invocation uses the
existing wrapper and the logical name. Every network-visible retry repeats the
appropriate fresh authorization; no token/allow decision is cached in the binding.
Only the separately resolved operator credential is supplied to the transport.

The V1 ceilings are 32 approved tools per binding, 128 discovered tools over at
most 8 pages, 64 KiB per schema and 1 MiB total discovery bytes, 64 KiB arguments,
256 KiB tool results, 10 seconds each for connect and complete discovery, 30 seconds
per invocation, and 5 seconds per release. These ceilings are validated operator
settings that may be lowered; raising them changes the binding format/revision.
No silent truncation and no adapter-level automatic invocation retry: execution
policy owns retry/accounting. Overall execution/provider budgets may be tighter.
Use bounded cancellation with a transport abort action on release timeout; the
upstream transport must supply this resource-ownership contract before adoption.

M1 can implement this pure binding validation, digest/name mapping and fake-lease
fixtures immediately. Record missing releases in
`docs/evidence/mcp-provider/contracts.md` during implementation: Baikai IR-2 must
supply lifecycle, bounded transport/auth and abort; Shikumi IR-1 must supply native
mapping, dynamic schemas and error classification; the existing Kikan-En contract
must pass connect/discovery/invoke revocation fixtures. These are concrete producer
handoffs, not permission to implement or send requests to another repository here.

The early proof is a hermetic provider plus existing overlay/execution consumer:
connect, authorize discovery, list, validate binding, authorize invocation, call,
release. This resolves naming/schema/auth/effect-error questions before multiplying
servers or transports. Until upstream transport/adapter release gates clear, M1
may produce fixtures and the concrete contract, but M2–M4 may not wire live MCP.
Coordinate new package adoption with
[plan 92](92-resolve-the-released-keiro-0-22-cohort-and-rehearse-the-composed-migration.md);
require an accepted solve/migration/package-closure handoff before consuming APIs
outside the current cohort, without blocking independent contract work.

### M2 — Implement an MCP-backed provider

Implement the accepted adapter as a provider factory at the package boundary that
owns its runtime resources. Reuse generic `CapabilityProvider`/`CapabilityLease`;
keep transport setup in operator composition/configuration, not AgentDecl. A
missing or invalid credential reference fails before connection. Resolved secrets
and proof tokens have no public JSON/Show/journal representation.

The common wrapper authorizes connection before acquisition. The MCP acquisition
path must additionally obtain a fresh discovery decision immediately before
`tools/list`, including any later authorized discovery/refresh. Construct logical
tools only after verifying the remote catalog against the immutable binding.
Preserve original remote call names and schemas; use the common exact invocation
authorizer on every tool call, including after an earlier allow or discovery.

Enforce M1's explicit connection/discovery/invocation, pagination, schema and byte ceilings. Fail explicitly on truncation
that would alter semantics. Bound error messages and do not expose raw protocol
bodies, credentials or tool inputs/results in logs, validation, public errors or
ordinary audit coordinates. Protected execution payload storage follows its own
existing access/retention contract; do not forbid necessary accepted tool-result
storage or copy it into public logs.

Acquisition owns cleanup until a valid lease has been returned. If connection
succeeds but discovery/auth/catalog validation fails, close that resource locally:
the outer disposal stack has no successful lease to release yet. Once returned,
release belongs to the common bracket. Handle exceptions/cancellation during each
stage, and ensure one bad release does not prevent other leases being released.
Classify model-visible tool errors separately from infrastructure failures using
the released adapter, preserving current retry/permanent-denial semantics.

### M3 — Integrate supported execution paths

Install the provider in the worker/durable and one-off composition roots using
validated operator configuration. Follow the existing exact-revision registry and
secret resolution patterns; do not hardcode a test server into production defaults.
Keep denied/unconfigured production behavior fail-closed. Use the existing Skill
loop and `Execution/Tools.hs`, including selection/admission and bound schema digest.

The supported matrix is fixed: one-off Skill and fresh durable Skill executions
that use the accepted execution child. Old patch snapshots with no overlay
resolution remain on their old path and do not gain MCP. A retained behavior-attempt
branch may use MCP only if it already pinned the exact overlay; qualify its
at-least-once observation behavior separately. The new conversation execution-child
path is supported once it carries the same pinned binding. Legacy conversation
branches without overlay resolution, Flow and ShikumiProgram refuse a nonempty MCP
request at admission. Test each refusal rather than silently omitting tools.

Put binding types and the reusable client/provider adapter in core under
`Capability/Mcp/Binding.hs` and `Capability/Mcp/Provider.hs`. The factory accepts
already resolved configuration and authorization functions; it never reads process
configuration. Both `shikigami-workers` and `shikigami-agent` construct it at their
composition roots, preserving the existing seven-package dependency arrows.
Add a default-empty MCP binding catalog to those composition roots; do not duplicate
factories in the binaries. The source dependency and immutable packaging update is
owned jointly with plan 92 and the final packaging owner.

Durable providers expose observations only. Reject remote mutations/emissions
rather than relabeling them safe because sockets close or tool IDs exist. Changes
to tool schemas/meaning require a new immutable revision and retention of old
bindings while unfinished accepted work references them. Completed accepted tool
results must replay without requiring a live server or re-invoking the remote
observation; pending calls must reacquire the exact binding or fail visibly.

Any durable body change must follow `docs/workflow-versioning.md`, with real patch
guards where required, checked DSL/generated updates and retained old result
codecs. Do not add journal steps simply to manage ephemeral connections: use the
established attempt/acquisition boundary. Preserve base tools, model policy,
resource accounting and context/output recovery. Extending a generic registry
must not bypass the durable execution attempt ledger.

### M4 — Prove and document the integration

Add a local scripted MCP server using the released supported transport, plus a
scripted model that calls the observation once. The proof agent requests only the
capability id; a separate operator fixture configures the endpoint and non-secret
credential reference. Assert the final overlay name, exact remote invocation,
echoed reply and release. Keep the tests hermetic; live service credentials are
not acceptance prerequisites.

Extend `CapabilityProviderSpec`/`CapabilityOverlaySpec` and execution PostgreSQL
fixtures, or add clearly named `McpProvider` suites where protocol tests need their
own fixture. Required cases are denied connect (zero network calls), denied
discovery (no list call), revoked invocation after discovery (no tool call),
authorizer outage/proof mismatch, missing credentials, unknown/colliding names,
same-name schema drift, unknown pinned revision, oversize data, timeout,
partial acquisition, cancellation and release failure. Sentinel secrets and tool
payloads must not appear in captured public diagnostics.

The durable test accepts a tool result, interrupts/restarts the consumer and proves
no repeated call for that result; a pending result with a missing or changed
provider must refuse rather than silently use the current revision. Run two agents
with different overlays concurrently to prove no shared mutable tool registry or
lease leakage. Include resource/attempt accounting assertions on the current
execution path and unchanged empty-overlay/base-tool behavior.

Document supported modes, observation-only policy, immutable revision upgrades,
credential setup, C13 configuration, protocol limits, failures and cleanup. Record
actual release/solve/package evidence and sanitized proof output in this plan.
A production claim also requires a deployable immutable Kikan-En dependency closure,
not just sibling packages available on one developer machine.

## Concrete Steps

Run from the repository root. Inspect current status/cohort before edits and keep
existing execution/worker-session work intact. Locate dependency owners first:

```bash
mori registry search baikai
mori registry show shinzui/baikai --full
mori registry docs shinzui/baikai
mori registry show shinzui/shikumi --full
mori registry show shinzui/kikan-en --full
```

Baseline and focused suites use the current Cabal component names:

```bash
nix develop --command cabal build all
nix develop --command cabal test shikigami-core:shikigami-core-test
nix develop --command cabal test shikigami-core:shikigami-core-postgres-test --test-options='--num-threads=1'
```

After M2 adds an `McpProvider` group, target it with:

```bash
nix develop --command cabal test shikigami-core:shikigami-core-test --test-options='--pattern McpProvider'
```

Register fixture modules in the owning package's descriptor/Main and run that
package's tests if the adapter belongs outside core. Use the actual supported CLI
and startup configuration in the recorded M4 transcript; the old invented
`shikigami-mcp-stub` executable is not present and is not a prerequisite.
At final implementation qualification:

```bash
nix develop --command cabal test all --test-options='--num-threads=1'
just keiro-gate <pre-change-commit>
git diff --check
```

The gate is required for durable/domain changes, with the real pre-change commit,
not an arbitrary HEAD comparison that misses the implementation. This planning
refresh does not claim any of those runtime checks have passed.

## Validation and Acceptance

Complete only when M1's released contracts, M2's protocol/provider checks, M3's
supported execution paths and M4's security/recovery matrix pass. A registered name
or successful standalone echo is insufficient. No `mcpServers` schema addition,
second model loop, alternate final tool namespace or generic auth replacement is
part of acceptance. Preserve the empty-overlay behavior and the established
separation between capability requests and authority.

## Idempotence and Recovery

Connections are ephemeral leases; remote tool effects are independent. Partial
acquisition closes its own newly opened connection before returning failure;
successful leases use existing LIFO cleanup on all exits. Durable accepted results
replay from protected storage without reconnecting. Pending observations may retry
only under the accepted execution policy and exact pinned binding; at-least-once
observation is not exactly-once remote mutation.

Removing a capability request affects future admission, not an already pinned
run. Retain old provider revisions/codecs until their pending work is retired;
revocation still applies freshly at IO boundaries. Roll forward across journal
changes and do not promise a blind code rollback is safe after new admissions.

## Interfaces and Dependencies

Plans 56–59 are satisfied whole-child prerequisites. They own declarations,
descriptors, common leases, registry/loop behavior, durable pinning and one-off
integration. Plan 12 owns the MCP provider, remote/native/logical name mapping,
discovery binding/auth and producer/consumer proof. It consumes current execution
bindings, canonical schema digests and C13 rather than defining competing owners.

Baikai IR-2 supplies transport/discovery/invocation/auth; Shikumi IR-1 supplies the
public MCP/dynamic-tool adapter. These released contracts gate M2–M4. Kikan-En IR-3
is retained as coordination lineage; current connection/invocation code exists,
while discovery integration and immutable deployment evidence still need proof.
The upstream plan artifacts are
`mori://shinzui/baikai/plans/30-mcp-transport-and-json-rpc-client-core`,
`mori://shinzui/baikai/plans/31-mcp-tool-discovery-and-invocation`,
`mori://shinzui/baikai/plans/32-mcp-authentication-headers-tokens-and-oauth`, and
`mori://shinzui/shikumi/plans/30-mcp-to-tool-adapter-surfacing-mcp-tools-into-the-registry`.
Their implementation details must be rechecked against released contracts.

## Revision Notes

- 2026-10-28 follow-up: Resolve the review holes with an immutable operator binding,
  concrete name/schema/auth mapping, finite protocol limits, package ownership and
  execution-mode rules; retain explicit upstream publication and proof gates.

- 2026-10-28: Rebuilt the unfinished scope around delivered overlays/C13 and current
  durable execution. Removed obsolete schema/registry/loop work; verified remaining
  released MCP gaps; added explicit discovery, schema/name binding, cleanup,
  bounded protocol, replay and immutable-closure gates.
- 2026-08-22: Transferred generic work to plans 56–59; retained MCP-specific scope.
- 2026-08-05/10: Recorded canonical tool-catalog evidence and checked upstream gaps;
  the current owners and release snapshot above supersede those historical details.
- 2026-06-27/07-22/30: Initial C6 plan, credential-reference and authorization gates;
  historical ownership is preserved without restoring superseded agent-authored
  server configuration.
