---
id: 7
slug: platform-feature-completion-egress-schema-memory-lifecycle-delegation
title: "Platform Feature Completion: Egress, Schema, Memory Lifecycle, Delegation"
kind: master-plan
created_at: 2026-07-08T20:13:36Z
intention: "intention_01kx1tyzqcerzv4ysbktgr9sw9"
---

# Platform Feature Completion: Egress, Schema, Memory Lifecycle, Delegation

This MasterPlan is a living document. The sections Progress, Surprises & Discoveries,
Decision Log, and Outcomes & Retrospective must be kept up to date as work proceeds.


## Vision & Scope

Shikigami's README (README.md:11-17) promises a five-part agent model — behavior, trigger,
sinks, identity, memory — and the architecture spec (docs/initial-spec.md) promises a fifth
sink (channel egress through kanmon, contract C12) and multi-agent coordination. Today the
runtime delivers three of the five parts. There is no `identity` field, no `memory`
configuration, and no enable/disable flag in `schema/Agent.dhall` (lines 59-68 define exactly
five fields: name, description, trigger, behavior, sinks). The channel-egress sink exists only
as a reserved permission enum (`SChannelEgress`, shikigami-core/src/Shikigami/Sink/Permission.hs:30).
Memory has no lifecycle: every write is priority 100 / MediumConfidence / MemoryPattern /
supersedes Nothing, kioku's L1-distillation timers are scheduled but never fired, and nothing
is ever archived. Delegation works mechanically but is reachable only through one hardcoded
demo task name and stub children.

After this initiative, all of those promises are real and observable. An operator can declare
a `ChannelEgress` sink and watch a run act back on the outside world through kanmon's egress
API (against a stub-kanmon until the real service is deployed, exactly the pattern the kawa
stub established). An agent manifest can declare `identity` (a meibo principal), a `memory`
policy (scope, recall limit, record policy), and `enabled = False` — with defaults that keep
every existing manifest byte-compatible. The worker runs kioku's distillation loop so
conversation sessions actually distill into consolidated memories, recall is bounded and
recency-ordered on non-vector installs, old memories are archived, and `memory.scope = Shared`
gives agents a real cross-agent memory. Delegation becomes a declared capability: an agent
lists whom it may delegate to, flows can delegate through a capability, cycles are rejected,
child-run budgets are enforced, and partial-failure collection with sibling cancellation is
available. Finally, the pre-existing plan for per-agent MCP server declaration
(docs/plans/12-per-agent-mcp-server-declaration-in-agent-dhall.md) is registered here so the
whole declaration-surface completion is coordinated in one place.

Explicitly excluded: real shomei-verified grants and outbound token minting (MasterPlan 4,
docs/plans/21-database-backed-sink-permission-grants.md and
docs/plans/22-outbound-authentication-for-sink-clients.md), a real model provider for behavior
runs (MasterPlan 2, docs/plans/13-wire-a-real-model-provider-into-behavior-runs.md), the
general workflow-versioning machinery (MasterPlan 5,
docs/plans/24-flow-versioning-with-keiro-patch-and-continue-as-new.md), and kanmon's ingress
half (owned by the kanmon repo). This MasterPlan builds the seams those plans swap into.


## Decomposition Strategy

The initiative decomposes by functional concern into five work streams, each independently
demonstrable:

EP-1 (channel egress) is the outbound-action surface: a new Sink variant, a kanmon HTTP
client, permission gating, and a stub-kanmon for the living-loop proof. It touches the sink
dispatcher path and is verifiable entirely on its own with the stub.

EP-2 (schema evolution) is the declaration surface: the `identity`, `memory`, and `enabled`
fields, added with Dhall defaults so no existing manifest changes. It is deliberately the
pattern-setter: it establishes the "additive field with a default, mirrored in
`Shikigami.Api.Agent`, proven by `validate`" discipline that every other schema-touching plan
(EP-1, EP-4, EP-5) follows.

EP-3 (memory lifecycle) is runtime semantics for memory: firing the already-scheduled
distillation timers, bounding the recall fallback, archiving old memories, and implementing
the `memory.scope = Shared` semantics whose field EP-2 defines.

EP-4 (delegation) is coordination semantics: the `delegates` allow-list, a Flow `delegate`
capability, cycle detection, budgets, failure policy, and retiring the hardcoded
research-supervisor special case.

EP-5 (per-agent MCP servers) is the pre-existing, already-authored plan 12, registered here
because it extends the same shared schema artifact and should follow EP-2's field pattern.

Alternatives considered. (a) One combined "schema plan" absorbing all Dhall changes from
EP-1/EP-2/EP-4/EP-5 — rejected because it would serialize four otherwise-parallel runtime
work streams behind a single document and violate the balance principle (one plan doing all
the schema work, the others reduced to wiring). Instead EP-2 defines the pattern and each
plan owns its own field end to end. (b) Merging EP-2 and EP-3 (memory policy field plus
memory semantics) — rejected because EP-2 is a pure declaration-surface change verifiable via
`validate` with no database, while EP-3 is worker/runtime behavior needing real Postgres and a
distillation runtime; they have different verification shapes and only one small shared
artifact (the `memory` field), which is handled as an integration point. (c) Splitting EP-4
into "schema" and "runtime" halves — rejected as too granular; the allow-list is meaningless
without the enforcement.


## Exec-Plan Registry

| # | Title | Path | Hard Deps | Soft Deps | Status |
|---|-------|------|-----------|-----------|--------|
| 1 | Channel egress sink through kanmon | docs/plans/32-channel-egress-sink-through-kanmon.md | cross-MP: plans 19, 22, 36, 37, and 47 | cross-MP: plan 21 (MasterPlan 4), plan 27 (MasterPlan 5) | Not Started |
| 2 | Agent schema evolution: identity, memory policy, and enablement | docs/plans/33-agent-schema-evolution-identity-memory-policy-and-enablement.md | cross-MP: plans 20, 36, and 47 | cross-MP: plan 16 (MasterPlan 2) | Not Started |
| 3 | Memory lifecycle: distillation, retention, and shared scope | docs/plans/34-memory-lifecycle-distillation-retention-and-shared-scope.md | EP-2; cross-MP: plans 36, 37, and 47; upstream Kioku IR-2 for M2/M3 | None | Not Started |
| 4 | Delegation as a first-class declared capability | docs/plans/35-delegation-as-a-first-class-declared-capability.md | EP-2; cross-MP: plans 24, 36–39, and 47 | None | Not Started |
| 5 | Per-agent MCP server declaration in Agent.dhall | docs/plans/12-per-agent-mcp-server-declaration-in-agent-dhall.md | cross-MP: plans 36, 37, and 47; upstream Baikai IR-2, Shikumi IR-1, and Kikan-En IR-3 for M3–M5 | EP-2 (field pattern); cross-MP: plan 13 (real model makes MCP tools useful) | Not Started |

Status values: Not Started, In Progress, Complete, Cancelled.
Hard Deps and Soft Deps reference other rows by their # prefix (e.g., EP-1, EP-3).

Registry note on EP-5: plan 12 pre-exists this MasterPlan (authored 2026-06-27 as child C6 of
the cross-repo MasterPlan `shinzui/baikai:docs/masterplans/6-mcp-support-across-the-agent-stack.md`).
Its frontmatter `master_plan` key points at this MasterPlan; its prior cross-repo membership
is preserved here and in the Decision Log, and its body was updated by the 2026-07-22
conformance/security pass. Its upstream hard dependencies (baikai `Baikai.Mcp.*`, shikumi
`shikumi-tools` adapter) live in other repositories and are tracked inside plan 12 itself.


## Dependency Graph

EP-2 follows plans 36 and 20, which own package placement and the canonical agent load
report/loud loader.
EP-2 extends that seam with enabled-agent selection rather than introducing another
directory walk. Within this MasterPlan, EP-2 goes first. Its artifact — the additive
Dhall-field pattern (`Agent.dhall` field + `default` entry + `Shikigami.Api.Agent` mirror +
`validate` proof) — is what EP-4 hard-depends on: EP-4 adds `delegates : List Text` to the
same `Agent` record and its `default`, and doing that before EP-2 lands would establish the
pattern twice and force a merge of two schema shapes. EP-4 is therefore the only hard edge
inside this MasterPlan.

EP-3 hard-depends on EP-2 and plans 36/37. The `memory` policy defines bounds and
enablement for every lifecycle loop, plan 36 assigns the worker package, and plan 37
owns settings. The complete supervised loop lands once rather than shipping an
unbounded environment-gated precursor.

EP-1 hard-depends on plans 36/37,
docs/plans/19-sink-delivery-truth-and-downstream-idempotency.md, and
docs/plans/22-outbound-authentication-for-sink-clients.md (MasterPlan 4),
which owns `HttpEnv`, `TokenSource`, and `postJSONWithHeaders`; EP-1 extends those records for
kanmon. Plan 19 owns the permanent/transient receipt and Keiro terminal-outcome mapping.
Its remaining cross-MP soft dependencies are plan 21, which owns the database grant
table, and plan 27, which
consolidates the sink-intent module. These soft edges make the preferred landing order
plan 21/27 → EP-1 after plans 19/22 without blocking schema/client work.

EP-3's relationship to docs/plans/13-wire-a-real-model-provider-into-behavior-runs.md was
verified in code and is weaker than assumed: kioku's distiller does need a model, but kioku
ships its own wiring — `Kioku.Distill.Runtime.newDistillRuntime` registers the Claude provider
and pins `anthropic_claude_haiku_4_5` itself (kioku-core/src/Kioku/Distill/Runtime.hs:60-74).
So EP-3 has no code dependency on plan 13 at all; its live provider credential is an opaque
reference resolved through plan 37's Settei composition root, and EP-3's tests use a stubbed
`DistillRuntime` (its fields are plain function records) so CI needs no key.

EP-5 (plan 12) hard-depends on plans 36/37 plus its upstream client, adapter, and
authorization contracts, and soft-depends on EP-2 for the field pattern (its M1 adds `mcpServers` to the
same `Agent` record) and, per its own Interfaces section, hard-depends on cross-repo upstream
work (baikai `Baikai.Mcp.Client`/`Baikai.Mcp.Tool`, the shikumi `shikumi-tools` MCP adapter)
and Kikan-En IR-3's per-action agent authorization contract, plus a coherent released
dependency update. Its scope in one paragraph: an agent manifest
gains an `mcpServers : List McpServer` field ({name, url, transport,
credential-reference}, default `[]`); at run time the runtime connects each authorized
declared server, registers only authorized tools into a `ToolRegistry` under
`mcp__<server>__<tool>` names, surfaces them to the Skill/ShikumiProgram behavior loops, and
bracket-closes the connections with the run. Its M1-M2 (schema + registry seam) can proceed
now; M3-M5 wait on the upstream repos. Its cross-MP soft dependency on plan 13 is qualitative:
MCP tools are only exercised by a model that actually issues tool calls, so the end-to-end
payoff arrives with a real provider.

EP-4 also hard-depends on plans 24 and 36–39. Delegation changes the durable agent-run
workflow and must update the checked Keiro DSL, pass its generated/harness drift gate,
land under the workflow-versioning discipline and active-patch plumbing, and use plan 38's
pg-migrate plan for its durable global budget ledger.

Parallelism summary: after plan 20, EP-2 can proceed alongside EP-5 M1-M2. EP-3 starts after
EP-2 and plans 36/37. EP-1 begins after plan 22. EP-4 starts after EP-2 and plans 24/36–39;
EP-5 M3-M5 follows its upstream authorization/client/adapter dependencies. This is the MasterPlan-7 slice of
the canonical MP-2 through MP-7 waves recorded in MasterPlan 2.


## Integration Points

IP-1 — `schema/Agent.dhall` and `shikigami-api/src/Shikigami/Api/Agent.hs` (the shared
declaration artifact). Involved: EP-1, EP-2, EP-4, EP-5. This pair is THE contended artifact
of the initiative: EP-1 adds a `ChannelEgress` alternative to the `Sink` union, EP-2 adds
`identity`/`memory`/`enabled` fields to `Agent`, EP-4 adds `delegates`, EP-5 adds
`mcpServers`. EP-2 owns the pattern: every addition must be additive, must extend the
`Agent.default` record so existing manifests need no edits, must be mirrored field-for-field
in `AgentDecl` (Dhall decoding fails at runtime otherwise — the constructor and field names of
the Haskell mirror must match the Dhall union alternatives and record fields exactly), must be
proven by `cabal run shikigami -- validate agents/heartbeat.dhall` succeeding unchanged, and
must update docs/user/writing-agents.md. Merge order within the files is by plan landing
order; conflicts are textual only because every change is additive.

IP-2 — the sink permission gate and grant vocabulary
(shikigami-core/src/Shikigami/Sink/Permission.hs). Involved: EP-1 and (cross-MP) plan 21.
`SChannelEgress` is already enumerated (Permission.hs:30) so `SinkKind` does not change; EP-1
adds grant-table entries for its proof agent to the static `defaultGrantTable` and dispatches
through the existing `checkGrant` seam. Plan 21 (MasterPlan 4) replaces the table with a
database lookup behind the same `checkGrant :: AgentIdentity -> SinkKind -> IO (Either Denied ())`
signature; EP-1 must not change that signature.

IP-3 — the durable agent-run workflow's step surface
(shikigami-core/src/Shikigami/Agent/Workflow.hs and Shikigami/Agent/Workflow/Name.hs).
Involved: EP-4 and (cross-MP hard dependency) plan 24. EP-4 removes the research-supervisor special case and
introduces a shared `ingestJobStepName` constant (today the literal `"ingest-job"` appears
independently in Workflow.hs and Delegate.hs:68). Any change to journaled step names or step
order in `agentRunWorkflow` must follow the versioning discipline that plan 24 (MasterPlan 5)
establishes; EP-4 is constrained to keep every existing wire-visible step name byte-identical
and only add steps, so in-flight journals replay.

IP-4 — the `memory` policy field. Involved: EP-2 (defines) and EP-3 (implements). EP-2 fixes
the shape: `memory : { scope : < AgentScope | Shared >, recallLimit : Natural, recordPolicy :
< Always | OnSuccess | Never > }` with default `{ scope = AgentScope, recallLimit = 10,
recordPolicy = OnSuccess }`, and enforces `recallLimit`/`recordPolicy`. EP-3 implements the
`scope = Shared` semantics over `Shikigami.Memory.Scope.sharedScope`. Neither plan may rename
the field or its alternatives without updating the other; the shape above is normative for
both. `Natural` values are converted through checked, bounded validation before any
`Int`, SQL limit, batch size, timer, or allocation; zero and oversized values receive
specific validation errors rather than wrapping or exhausting resources.

IP-5 — the `identity` field. Involved: EP-2 (defines) and cross-MP plan 23 (MasterPlan 4,
consumes after EP-2). EP-2 defines `identity : Optional { principal : Text }` (default `None`);
plan 23 owns joining that principal to meibo and driving lifecycle control from it, with a
name-based fallback only when the optional field is absent.

IP-6 — the shared sink HTTP layer (shikigami-core/src/Shikigami/Sink/Http.hs). Involved: EP-1
and cross-MP plan 22. Plan 22 defines `HttpEnv`, `TokenSource`, and
`postJSONWithHeaders`; EP-1 adds duplicate direct `kanmon` fields to its credential/HTTP records and
uses plan 37's Settei credential-reference setting and explicit legacy binding.
`KanmonConfig` carries no secret and EP-1 creates no second header helper. Plan 28 adds
`traceparent` through the same function. Permanent 4xx responses are classified once
and dead-lettered/denied rather than retried forever; 429 and transient 5xx/network
failures use the shared bounded retry policy.

IP-7 — agent loading and inspection. Plan 20 defines `loadAgentsReport` and loud/strict
loading. EP-2 adds enabled-agent selection over that report. Plan 30 consumes the report for
the `agents` operator command; plan 23 later persists and annotates it with lifecycle state.

IP-8 — checked delegation topology and global budget. Plan 39 owns
`domain/shikigami.keiro`; EP-4 adds stable delegation steps/children there in the same
change as runtime code. The remaining child/time/depth budget is persisted in `RunJob`
lineage and consumed atomically across the entire descendant tree, not reset per parent
or process. Cycle and allow-list checks happen before child creation; replay observes the
same budget decision.

IP-9 — MCP credentials and authorization. Plan 12 stores only credential references in
agent Dhall. Secret values are resolved through plan 37's Settei composition root into
non-serializable/redacted types; they never gain `Show`, JSON, or tool-output exposure.
Kikan-En IR-3 must define which agent/principal may connect to which server and tool before
runtime milestones begin; transport authentication alone is insufficient.


## Progress

Track milestone-level progress across all child plans. Each entry names the child plan
and the milestone. This section provides an at-a-glance view of the entire initiative.

- [ ] EP-1 M1: `ChannelEgress` Sink variant in Dhall + Haskell mirror + proof manifest validates.
- [ ] EP-1 M2: `KanmonConfig` + `KanmonClient` over a header-capable HTTP helper; request-shape unit tests.
- [ ] EP-1 M3: dispatcher arm + grant gating + Settei config plumbing; permanent-4xx versus transient retry classification.
- [ ] EP-1 M4: `stub-kanmon` CLI command and the end-to-end outbox-to-egress proof (delivered, deduplicated, denied).
- [ ] EP-2 M1: `identity`/`memory`/`enabled` fields in `schema/Agent.dhall` with defaults; all existing manifests validate unchanged.
- [ ] EP-2 M2: Haskell mirror types on `AgentDecl`; loader/decoder proof; `validate` prints the new surface.
- [ ] EP-2 M3: `enabled` enforced over plan 20's canonical load report; bounded checked conversion for `recallLimit` and all policy Naturals; `recordPolicy` enforced in run paths.
- [ ] EP-2 M4: docs/user/writing-agents.md updated; proof manifest exercising all three fields.
- [ ] EP-3 M1: kioku distill timer worker wired as a Settei-configured, fail-fast supervised worker loop; L1 timers actually fire.
- [ ] EP-3 M2: recall fallback bounded and recency-ordered by server-side query limits.
- [ ] EP-3 M3: retention — server-side bounded batches periodically archive old MemoryPattern rows via kioku `archive`.
- [ ] EP-3 M4: `memory.scope = Shared` semantics implemented over `sharedScope` (record + recall).
- [ ] EP-4 M1: `delegates : List Text` schema field (follows EP-2 pattern) + shared `ingestJobStepName` constant.
- [ ] EP-4 M2: lineage + durable global descendant budget on `RunJob`; ancestor-cycle rejection and atomic budget enforcement in `delegate`.
- [ ] EP-4 M3: `Delegate` Flow capability; allow-list enforced at the capability boundary.
- [ ] EP-4 M4: failure policy — `awaitAllDelegated` (per-child Either) and sibling cancellation via keiro `cancelChild`.
- [ ] EP-4 M5: research-supervisor re-expressed on the general mechanism; hardcoded task-name special case removed.
- [ ] EP-5 M1: `mcpServers` schema field with credential references only + mirror + examples (per plan 12).
- [ ] EP-5 M2: build wiring (`shikumi-tools`) + `ToolRegistry` seam on `BehaviorEnv` (per plan 12).
- [ ] EP-5 M3-M5: connect/register/close bracket, tool loop, end-to-end (blocked on upstream Baikai IR-2, Shikumi IR-1, and Kikan-En IR-3; per plan 12).


## Surprises & Discoveries

Document cross-plan insights, dependency changes, scope adjustments, or unexpected
interactions between child plans. Provide concise evidence.

- Kanmon's egress API already exists in code, so EP-1 does not need to invent a contract.
  `/Users/shinzui/Keikaku/bokuno/kanmon/kanmon-core/src/Kanmon/Http.hs:134` routes
  `POST /channels/{channelId}/actions/{action}` and `Kanmon/Egress.hs` defines
  `EgressActionRequest {conversation_key, content, idempotency_key, triggering_activity_id}`
  and `EgressActionResponse {activity_id, verb}` with 401/403 mapping, bearer verification,
  per-destination grants, and idempotency. EP-1's stub mirrors this real wire contract
  byte-for-byte instead of pinning a provisional one (recorded in EP-1's Decision Log). The
  spec's Open Question 4 (docs/initial-spec.md:942-944) is thereby answerable from kanmon's
  actual code.
- Kioku's distillation runtime is self-contained: `newDistillRuntime`
  (kioku-core/src/Kioku/Distill/Runtime.hs:60-74) registers the Claude provider and picks its
  own model, so EP-3 has no code dependency on plan 13. Its live credential is resolved by
  plan 37 from an opaque reference, and `DistillRuntime` is a record of plain functions so
  tests can stub it.
- `loadAgents` is copy-pasted in three CLI modules (shikigami-cli/src/Shikigami/Cli/Commands/
  Worker.hs:45-49, Scheduler.hs:77-80, ConsumeStream.hs:90-93) and silently drops manifests
  that fail to load (`pure [a | Right a <- loaded]`). The portfolio audit found that four
  plans proposed overlapping fixes. Ownership is now plan 20 (canonical report/logging) →
  EP-2 (enabled selection) and plan 30 (inspection) → plan 23
  (persistence/lifecycle); EP-2 no longer consolidates the base loader.
- Plan 12 predates this MasterPlan and already carried a `master_plan` frontmatter key
  pointing at the cross-repo baikai MasterPlan 6. See Decision Log for how this was resolved.
- Fleet conformance audit (2026-07-22): configuration, package placement, and checked
  durable topology are shared foundations, not per-feature choices. Plans 32–35 and 12
  now consume plans 36/37/39 where applicable.
- Safety audit (2026-07-22): unbounded Dhall `Natural` conversion, client-side memory
  trimming, per-parent delegation budgets, and transport-only MCP authentication all
  admit resource or authorization failures. The affected plans now require bounded
  validation, server-side batching, a durable global budget, and explicit authz.


## Decision Log

- Decision: Require plan 47 for every child and represent MCP and bounded-memory upstream
  work as explicit milestone gates rather than blocking their whole ExecPlans.
  Rationale: schema/registry seams and distillation wiring can land safely before live MCP or
  new Kioku reads, provided runtime invocation and unbounded queries remain forbidden.
  Date: 2026-07-30


Record every decomposition or coordination decision made while working on the master
plan.

- Decision: Decompose into five plans — egress (32), schema surface (33), memory lifecycle
  (34), delegation (35), plus registering pre-existing plan 12 — with EP-2 as the
  pattern-setter for all schema changes and the only intra-MP hard edge being 35 → 33.
  Rationale: each stream is independently demonstrable (stub-kanmon e2e; `validate` over
  unchanged manifests; distilled/archived memory rows; a delegating flow with cycle/budget
  rejection); a single schema mega-plan would serialize parallel runtime work; merging 33+34
  mixes a no-database declaration change with Postgres-backed worker semantics.
  Date: 2026-07-08

- Decision: Register docs/plans/12-per-agent-mcp-server-declaration-in-agent-dhall.md as EP-5
  and re-point its frontmatter `master_plan` from
  `shinzui/baikai:docs/masterplans/6-mcp-support-across-the-agent-stack.md` to this MasterPlan,
  preserving the prior value here (registry note, this entry) rather than duplicating the YAML
  key.
  Rationale: the file already had a `master_plan` key; YAML forbids duplicate keys, so "add
  the key" is implemented as "replace the value and record the lineage". Plan 12's body — which
  narrates the baikai MasterPlan's integration contract in full — was left untouched, so no
  information is lost; this repo's registry tooling resolves the local path.
  Date: 2026-07-08

- Decision: EP-1 targets kanmon's real, already-implemented wire contract (route
  `POST /channels/{channelId}/actions/{action}`, snake_case body) and still ships a
  stub-kanmon CLI command in this repo for the hermetic living-loop proof, following the
  `stub-kawa` precedent (shikigami-core/src/Shikigami/Sink/KawaStub.hs).
  Rationale: kanmon has a consumable API in code but is not part of shikigami's dev stack; a
  local stub keeps the proof runnable with `cabal run` alone, and because the stub mirrors the
  real contract, swapping to real kanmon is a base-URL change with no schema change.
  Date: 2026-07-08

- Decision: The normative `memory` field shape is
  `{ scope : < AgentScope | Shared >, recallLimit : Natural, recordPolicy : < Always | OnSuccess | Never > }`
  with default `{ scope = AgentScope, recallLimit = 10, recordPolicy = OnSuccess }`; EP-2
  enforces `recallLimit`/`recordPolicy`, EP-3 implements `scope` (IP-4).
  Rationale: the defaults encode today's verified behavior (recall `maxResults = 10` at
  shikigami-core/src/Shikigami/Agent/Run.hs:207; recording only on the success arm at
  Agent/Run.hs:93-112 and Agent/Workflow.hs:585-605), so an undeclared `memory` field changes
  nothing; splitting enforcement this way keeps EP-3's database-heavy scope work out of EP-2's
  declaration-surface plan.
  Date: 2026-07-08

- Decision: Keep `sharedScope` (Shikigami/Memory/Scope.hs:17-22) rather than delete it; EP-3
  gives it real semantics driven by `memory.scope = Shared`.
  Rationale: cross-agent memory is half of the README's memory promise and kioku already
  models the global scope (`ScopeGlobal`); deleting it would orphan the `Shared` schema
  alternative EP-2 introduces. Detailed record/recall semantics are settled in EP-3's Decision
  Log.
  Date: 2026-07-08

- Decision: EP-4 must keep all existing journaled step names ("ingest-job", "lookup-agent",
  "open-session", "recall", "run-behavior", "dispatch-sinks", "record", "complete",
  "fail-session") byte-identical and only add steps; the shared constant refactor changes
  code, not wire values.
  Rationale: `Shikigami.Agent.Delegate.delegate` pre-journals the child's "ingest-job" step by
  name (Delegate.hs:64-71) and keiro replays by step name; plan 24 (MasterPlan 5) owns the
  general versioning machinery, and until it lands the only safe move is additive (IP-3).
  Date: 2026-07-08
- Decision: Make plan 20 a hard predecessor of EP-2, plan 22 a hard predecessor of EP-1,
  and plans 24/39 hard predecessors of EP-4.
  Rationale: these plans now consume concrete shared artifacts (`loadAgentsReport`,
  authenticated `HttpEnv`/`postJSONWithHeaders`, and workflow-versioning discipline plus
  patch plumbing). Encoding those as hard edges removes provisional implementations and
  gives the portfolio a deterministic landing order.
  Date: 2026-07-22
- Decision: Schema Naturals are validated into bounded domain types before conversion;
  memory reads and archival run in server-side bounded batches under supervised loops.
  Rationale: Dhall's unbounded values and client-side trimming otherwise permit overflow,
  excessive allocation, and scans that ignore the declared limits.
  Date: 2026-07-22
- Decision: Delegation uses a durable, global descendant budget and updates the checked
  Keiro DSL; per-parent resettable counters are forbidden.
  Rationale: a local budget allows exponential fan-out and gives replay/process restarts
  different enforcement outcomes.
  Date: 2026-07-22
- Decision: Agent manifests contain MCP credential references only, and plan 12 waits for
  Kikan-En IR-3's upstream authorization contract in addition to client/transport support.
  Rationale: embedding secret values makes declarations serializable leak surfaces, while
  authentication alone does not authorize an agent to a server or tool.
  Date: 2026-07-22
- Decision: Plan 23 consumes EP-2's declared `identity.principal`; it no longer lands
  first and relies on a later one-function override.
  Rationale: the optional field preserves compatibility for existing manifests, while
  ordering the plans avoids shipping and then replacing name-only identity resolution.
  Date: 2026-07-22


## Outcomes & Retrospective

Summarize outcomes, gaps, and lessons learned at major milestones or at completion.
Compare the result against the original vision.

(To be filled during and after implementation.)


## Revision Notes

- 2026-07-30: Recorded Kikan-En IR-3 as the canonical per-action authorization request for
  EP-5 runtime milestones.
- 2026-07-30: Added plan 47, linked Kioku IR-2 and the three MCP upstream requests, and
  recorded which child milestones remain startable behind inert or bounded seams.

- 2026-07-22: Added cross-MasterPlan prerequisites for plans 20, 22, and 24; unified
  HTTP ownership with MasterPlan 4; ordered the shared loader/agent-command work; and
  made plan 23 consume the identity field after it exists. These changes align
  MasterPlan 7 with the canonical MP-2 through MP-7 execution waves in MasterPlan 2.
- 2026-07-22: Added architecture/Settei/Keiro-DSL prerequisites and corrected egress
  retry classification, bounded schema validation, memory batching/supervision, global
  delegation budgets, and MCP credential-reference/authorization requirements.
