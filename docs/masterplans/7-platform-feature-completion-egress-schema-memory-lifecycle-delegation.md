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
| 1 | Channel egress sink through kanmon | docs/plans/32-channel-egress-sink-through-kanmon.md | None | cross-MP: plans 21, 22 (MasterPlan 4) | Not Started |
| 2 | Agent schema evolution: identity, memory policy, and enablement | docs/plans/33-agent-schema-evolution-identity-memory-policy-and-enablement.md | None | cross-MP: plan 23 (MasterPlan 4, consumes `identity`), plan 16 (MasterPlan 2, dead-field note) | Not Started |
| 3 | Memory lifecycle: distillation, retention, and shared scope | docs/plans/34-memory-lifecycle-distillation-retention-and-shared-scope.md | None | EP-2 (memory.scope field); cross-MP: plan 13 (ops-level only, see Dependency Graph) | Not Started |
| 4 | Delegation as a first-class declared capability | docs/plans/35-delegation-as-a-first-class-declared-capability.md | EP-2 | cross-MP: plan 24 (MasterPlan 5, step-versioning discipline) | Not Started |
| 5 | Per-agent MCP server declaration in Agent.dhall | docs/plans/12-per-agent-mcp-server-declaration-in-agent-dhall.md | upstream baikai C1/C2 + shikumi C5 (cross-repo) | EP-2 (field pattern); cross-MP: plan 13 (real model makes MCP tools useful) | Not Started |

Status values: Not Started, In Progress, Complete, Cancelled.
Hard Deps and Soft Deps reference other rows by their # prefix (e.g., EP-1, EP-3).

Registry note on EP-5: plan 12 pre-exists this MasterPlan (authored 2026-06-27 as child C6 of
the cross-repo MasterPlan `shinzui/baikai:docs/masterplans/6-mcp-support-across-the-agent-stack.md`).
Its frontmatter `master_plan` key now points at this MasterPlan (the one permitted frontmatter
edit); its prior cross-repo membership is preserved here and in the Decision Log, and its body
was not modified. Its upstream hard dependencies (baikai `Baikai.Mcp.*`, shikumi
`shikumi-tools` adapter) live in other repositories and are tracked inside plan 12 itself.


## Dependency Graph

EP-2 goes first in spirit but blocks almost nothing in practice. Its artifact — the additive
Dhall-field pattern (`Agent.dhall` field + `default` entry + `Shikigami.Api.Agent` mirror +
`validate` proof) — is what EP-4 hard-depends on: EP-4 adds `delegates : List Text` to the
same `Agent` record and its `default`, and doing that before EP-2 lands would establish the
pattern twice and force a merge of two schema shapes. EP-4 is therefore the only hard edge
inside this MasterPlan.

EP-3 soft-depends on EP-2: three of its four milestones (distillation worker, bounded recall
fallback, retention/archival) need nothing from EP-2 and can start immediately; only its
shared-scope milestone consumes the `memory.scope` field EP-2 defines. If EP-2 slips, EP-3
lands its first three milestones and holds the fourth.

EP-1 is independent within this MasterPlan and can run fully in parallel. Its cross-MP soft
dependencies: docs/plans/21-database-backed-sink-permission-grants.md (MasterPlan 4) owns the
database grant table that will gate the new sink kind — until then EP-1 extends the existing
static `defaultGrantTable` stub in `Shikigami.Sink.Permission`, which is exactly the seam plan
21 swaps; and docs/plans/22-outbound-authentication-for-sink-clients.md (MasterPlan 4) owns
real outbound auth headers — EP-1 ships a config-supplied static bearer token for the stub
proof and leaves the header seam for plan 22.

EP-3's relationship to docs/plans/13-wire-a-real-model-provider-into-behavior-runs.md was
verified in code and is weaker than assumed: kioku's distiller does need a model, but kioku
ships its own wiring — `Kioku.Distill.Runtime.newDistillRuntime` registers the Claude provider
and pins `anthropic_claude_haiku_4_5` itself (kioku-core/src/Kioku/Distill/Runtime.hs:60-74).
So EP-3 has no code dependency on plan 13 at all; the only shared concern is operational (an
`ANTHROPIC_API_KEY` in the worker's environment), and EP-3's tests use a stubbed
`DistillRuntime` (its fields are plain function records) so CI needs no key.

EP-5 (plan 12) soft-depends on EP-2 for the field pattern (its M1 adds `mcpServers` to the
same `Agent` record) and, per its own Interfaces section, hard-depends on cross-repo upstream
work (baikai `Baikai.Mcp.Client`/`Baikai.Mcp.Tool`, the shikumi `shikumi-tools` MCP adapter)
plus a `cabal.project` re-pin. Its scope in one paragraph: an agent manifest gains an
`mcpServers : List McpServer` field ({name, url, transport, auth}, default `[]`); at run time
the runtime connects each declared server, registers its tools into a `ToolRegistry` under
`mcp__<server>__<tool>` names, surfaces them to the Skill/ShikumiProgram behavior loops, and
bracket-closes the connections with the run. Its M1-M2 (schema + registry seam) can proceed
now; M3-M5 wait on the upstream repos. Its cross-MP soft dependency on plan 13 is qualitative:
MCP tools are only exercised by a model that actually issues tool calls, so the end-to-end
payoff arrives with a real provider.

Parallelism summary: EP-1, EP-2, EP-3 (milestones 1-3), and EP-5 (M1-M2) can all proceed
concurrently by different contributors; EP-4 starts when EP-2's schema machinery is merged;
EP-3 milestone 4 and EP-5 M3-M5 follow their soft dependencies.


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
Involved: EP-4 and (cross-MP) plan 24. EP-4 removes the research-supervisor special case and
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
both.

IP-5 — the `identity` field. Involved: EP-2 (defines) and cross-MP plan 23 (MasterPlan 4,
consumes). EP-2 defines `identity : Optional { principal : Text }` (default `None`); plan 23
owns joining that principal to meibo and driving lifecycle control from it. The field name
and shape (`identity.principal`, a meibo principal identifier as Text) is the agreed contract;
plan 23 must be updated if it assumed a different shape.

IP-6 — the shared sink HTTP layer (shikigami-core/src/Shikigami/Sink/Http.hs). Involved: EP-1
and cross-MP plan 22. Today `postJSON` supports no custom headers; EP-1 adds an additive
header-capable variant for the kanmon bearer token. Plan 22 (MasterPlan 4) owns where those
header values come from (real token minting); EP-1 only creates the mechanical seam and a
config-supplied static token.


## Progress

Track milestone-level progress across all child plans. Each entry names the child plan
and the milestone. This section provides an at-a-glance view of the entire initiative.

- [ ] EP-1 M1: `ChannelEgress` Sink variant in Dhall + Haskell mirror + proof manifest validates.
- [ ] EP-1 M2: `KanmonConfig` + `KanmonClient` over a header-capable HTTP helper; request-shape unit tests.
- [ ] EP-1 M3: dispatcher arm + grant gating + config plumbing through worker/CLI.
- [ ] EP-1 M4: `stub-kanmon` CLI command and the end-to-end outbox-to-egress proof (delivered, deduplicated, denied).
- [ ] EP-2 M1: `identity`/`memory`/`enabled` fields in `schema/Agent.dhall` with defaults; all existing manifests validate unchanged.
- [ ] EP-2 M2: Haskell mirror types on `AgentDecl`; loader/decoder proof; `validate` prints the new surface.
- [ ] EP-2 M3: `enabled` enforced loudly by a consolidated `loadAgents`; `recallLimit`/`recordPolicy` enforced in the run paths.
- [ ] EP-2 M4: docs/user/writing-agents.md updated; proof manifest exercising all three fields.
- [ ] EP-3 M1: kioku distill timer worker wired as the worker's fifth loop (env-gated); L1 timers actually fire.
- [ ] EP-3 M2: recall fallback bounded and recency-ordered.
- [ ] EP-3 M3: retention — periodic archival of old MemoryPattern rows via kioku `archive`.
- [ ] EP-3 M4: `memory.scope = Shared` semantics implemented over `sharedScope` (record + recall).
- [ ] EP-4 M1: `delegates : List Text` schema field (follows EP-2 pattern) + shared `ingestJobStepName` constant.
- [ ] EP-4 M2: lineage + budget on `RunJob`; ancestor-cycle rejection and budget enforcement in `delegate`.
- [ ] EP-4 M3: `Delegate` Flow capability; allow-list enforced at the capability boundary.
- [ ] EP-4 M4: failure policy — `awaitAllDelegated` (per-child Either) and sibling cancellation via keiro `cancelChild`.
- [ ] EP-4 M5: research-supervisor re-expressed on the general mechanism; hardcoded task-name special case removed.
- [ ] EP-5 M1: `mcpServers` schema field + mirror + examples (per plan 12).
- [ ] EP-5 M2: build wiring (`shikumi-tools`) + `ToolRegistry` seam on `BehaviorEnv` (per plan 12).
- [ ] EP-5 M3-M5: connect/register/close bracket, tool loop, end-to-end (blocked on upstream baikai/shikumi MCP work; per plan 12).


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
  own model, so EP-3 has no code dependency on plan 13 — only an operational API-key
  requirement, and `DistillRuntime` is a record of plain functions so tests can stub it.
- `loadAgents` is copy-pasted in three CLI modules (shikigami-cli/src/Shikigami/Cli/Commands/
  Worker.hs:45-49, Scheduler.hs:77-80, ConsumeStream.hs:90-93) and silently drops manifests
  that fail to load (`pure [a | Right a <- loaded]`). EP-2's "skip disabled agents LOUDLY"
  requirement therefore expands slightly: it consolidates the helper into
  `Shikigami.Agent.Loader` and makes load failures loud too (EP-2 Decision Log).
- Plan 12 predates this MasterPlan and already carried a `master_plan` frontmatter key
  pointing at the cross-repo baikai MasterPlan 6. See Decision Log for how this was resolved.


## Decision Log

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


## Outcomes & Retrospective

Summarize outcomes, gaps, and lessons learned at major milestones or at completion.
Compare the result against the original vision.

(To be filled during and after implementation.)
