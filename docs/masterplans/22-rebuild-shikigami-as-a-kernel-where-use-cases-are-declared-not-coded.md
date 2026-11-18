---
id: 22
slug: rebuild-shikigami-as-a-kernel-where-use-cases-are-declared-not-coded
title: "Rebuild Shikigami as a kernel where use cases are declared, not coded"
kind: master-plan
created_at: 2026-11-15T13:43:04Z
intention: "intention_01m7fq4tf3ejrt0tjxvsy8ejdt"
provenance:
  created_by:
    model: "claude-opus-5-5"
    harness: "claude-code"
    at: 2026-11-15T13:43:04Z
  revisions:
    - model: "claude-opus-5-5"
      harness: "claude-code"
      at: 2026-11-15T14:08:31Z
      mode: "update"
      note: "Filled body; reconciled seven parallel child drafts (worker tier, single ledger, finalMessage, pack labels, plan 12)"
    - model: "claude-fable-5-2"
      harness: "claude-code"
      at: 2026-11-15T14:42:44Z
      mode: "update"
      note: "Deep review: three balanced requirements, kernel invariants and ports, Kikan distribution, baseline gate, EP-8 to EP-11, reconciled pack API and tool hosts"
    - model: "claude-fable-5-2"
      harness: "claude-code"
      at: 2026-11-15T15:09:01Z
      mode: "discuss"
      note: "User decisions: adaptive coordinator stays kernel, stage 3 waits for Kikan-En actions, composition default output, two-step baseline"
    - model: "claude-opus-5-5"
      harness: "claude-code"
      at: 2026-11-15T15:57:53Z
      mode: "implement"
      note: "EP-8 M1 accepted; registry, Action sketch and cross-plan discoveries updated"
    - model: "claude-opus-5-5"
      harness: "claude-code"
      at: 2026-11-16T03:13:20Z
      mode: "implement"
      note: "EP-7 pilot moved to kizashi, stopped and finished by hand; campaign tail validated with build-repair"
    - model: "claude-fable-5-2"
      harness: "claude-code"
      at: 2026-11-16T04:42:50Z
      mode: "update"
      note: "EP-5 M2 accepted: packs composed at start, SDK components, first pack, IR-61"
    - model: "claude-fable-5-2"
      harness: "claude-code"
      at: 2026-11-16T15:53:56Z
      mode: "implement"
      note: "EP-6 M3 accepted"
    - model: "claude-opus-5-5"
      harness: "claude-code"
      at: 2026-11-16T22:31:55Z
      mode: "implement"
      note: "EP-6 complete after M7"
    - model: "claude-opus-5-5"
      harness: "claude-code"
      at: 2026-11-17T04:08:29Z
      mode: "update"
      note: "EP-8 M3 accepted and EP-8 complete; portability check against the fixture Kikan composition"
    - model: "claude-opus-5-5"
      harness: "claude-code"
      at: 2026-11-17T17:46:08Z
      mode: "implement"
      note: "EP-10 M3 accepted; progress snapshot and FRIC-98 and test-placement observations"
    - model: "claude-opus-5-5"
      harness: "claude-code"
      at: 2026-11-17T19:50:51Z
      mode: "implement"
      note: "EP-10 M4 and M5 accepted; conversation-channel decision; FRIC-99 recorded"
    - model: "claude-opus-5-5"
      harness: "claude-code"
      at: 2026-11-18T02:50:27Z
      mode: "implement"
      note: "FRIC-99 resolved by ADR-132; EP-7 M3 accepted on koyomi; EP-11 M2 unblocked"
---

# Rebuild Shikigami as a kernel where use cases are declared, not coded

This MasterPlan is a living document. The sections Progress, Surprises & Discoveries,
Decision Log, and Outcomes & Retrospective must be kept up to date as work proceeds.
If durable project context changes, update or create ADRs in docs/adr/ in the same change.


## Vision & Scope

Shikigami is the core of the Kikan platform, and after a year of work it has not been used
for a single real project. Every new use case brought to it gets the answer "not yet",
because the architecture inverted its own founding premise. `docs/initial-spec.md` set the
goal: "let anyone stand up a new autonomous agent by writing a short declarative `.dhall`
file — not by building and deploying a bespoke service." In the working tree the opposite
is true. Each real use case became a bespoke subsystem inside `shikigami-core`, while the
only declared agents are four demonstrations: `agents/heartbeat.dhall`,
`agents/danwa-heartbeat.dhall`, `agents/triage-note.dhall` and `agents/broken.dhall`. The
2026-11-15 measurements below give the scale. They were taken with `wc -l` over each
namespace under `shikigami-core/src/Shikigami/`.

```text
shikigami-core/src           78,094 lines, 63 top-level namespaces, 93 generated
                             modules, 357 exposed modules (no curated library API)
Watchdog                      2,772     Initiative (unrequested work)   2,714
PracticeReview                4,361     Objective + Mandate + lifecycles 9,109
WorkerSession                 3,510     Workspace                       3,647
Capability                    1,057     Attestation                     3,097
docs/ (Markdown)            114,754 lines: 125 plans, 21 MasterPlans, 123 ADRs
declared agents                   4, none doing real work
```

Five structural causes make every use case a change to the core:

1. **A declared agent is too weak to do real work.** A `Skill` behavior is a system prompt
   plus a home-built tool loop of at most eight turns over Baikai
   (`shikigami-core/src/Shikigami/Behavior/Skill.hs`). It ignores `allowed-tools`, does not
   read `references/` and does not run `scripts/`. Real coding harnesses exist: Claude Code
   and Codex, reachable through `baikai agent run`, documented in
   `mori://shinzui/baikai/packages/baikai-agent` and the Baikai guide
   `docs/user/unattended-agent-runs.md` in `mori://shinzui/baikai`. In Shikigami they only
   run as foreground launches (`shikigami-agent/src/Shikigami/Agent/Command/Launch.hs`).
   [ADR-40](../adr/0040-response-options-and-foreground-launches-have-separate-authority.md)
   keeps them out of durable runs until deadline, output and confinement qualification
   passes.
2. **Tools are a closed set compiled into the core.** The full tool set is
   `workspace.read`, `workspace.edit`, `workspace.exec`, `workspace.git` and
   `workspace.integrate`, implemented across `shikigami-core/src/Shikigami/Capability`,
   `shikigami-core/src/Shikigami/Workspace` and `shikigami-workers/src/Shikigami/Workspace`.
   An agent cannot declare that it may call `mina`, `mori`, `seihou` or `gh`.
   [ADR-65](../adr/0065-mcp-provider-revisions-bind-the-approved-tool-contract.md) designs
   MCP bindings, but no Haskell source references MCP.
3. **Only one trust level exists, set for hostile multi-tenant production.** Running one
   command in a repository requires a Linux systemd supervisor, writable cgroup v2, an
   immutable Nix root, reserved Unix identities, a private network namespace and
   PostgreSQL 18 (`docs/operations/workspaces.md`). Unsupported hosts refuse. The one-off
   commands install a deny-all authorizer
   ([ADR-36](../adr/0036-external-agent-actions-require-fresh-exact-authorization.md)).
   Nothing supports the most common case for this platform today: the operator, on their
   own Mac, with their own repositories and credentials.
4. **Even the extension point is inside the core.** A `Flow` behavior names a compiled
   `FlowDef` that must be added to `Shikigami.Flow.flowRegistry` in `shikigami-core`
   (`docs/user/flows.md`). The coupling is deeper than the list. `FlowEffects` is a closed
   row of 18 effects, 8 of them use-case specific. `runFlowBehavior` in
   `shikigami-core/src/Shikigami/Agent/Workflow.hs` builds every interpreter for every flow
   and tests `flow.name == watchdogFlowName` in three places.
5. **The kernel's own contracts are Kikan's.** The type every authorization decision takes,
   `AgentAction`, is imported from `mori://shinzui/kikan-en/packages/kikan-en-contract`. It
   is a closed sum, so the core cannot name a new kind of action without a Kikan-En
   release. The `Sink` union in `schema/Agent.dhall` and `Shikigami.Agent.Decl` is closed
   over Kawa, Kizashi, Rei, Danwa and channel egress, and `Sink.dispatch` is a `case` over
   per-service clients. Approval channels are closed over Danwa and Kizashi. A declaration
   must name a `Schedule`, `Stream` or `Event` trigger; there is no way to say "the
   operator runs this". Many of the services behind these types are proven only against
   fixtures.

After this initiative, Shikigami is a small durable kernel with contracts of its own. The
kernel owns agent runs, objectives, journals, approvals, authority, the action record,
resource budgets, memory and workspaces. It reaches the outside world through a small set
of *ports*: kernel-owned interfaces for authority, the action record, outputs, approval
channels, triggers, the directory of principals, workspaces and process launch. Adapters
for those ports are chosen when an executable is composed. Use cases are declarations:
Dhall agent files, skills and playbooks, plus Haskell flow packs for the rare case that
needs code. The packs live outside `shikigami-core`. A coding agent (Claude Code or Codex)
is a first-class durable worker. An agent declares the CLI tools and MCP servers it needs,
and authority attaches to that declaration.

**Two compositions, one kernel.** The same kernel is composed two ways, and a declaration
that uses only kernel vocabulary runs unchanged in both.

- The **stock composition** is the seven `shikigami-*` packages with local adapters. It
  serves one operator on their own machine under the `LocalOperator` trust tier: the
  operator is the authority, outputs are local reports, approvals arrive in a local inbox,
  and runs start by hand or on a local schedule. It needs no Kikan service.
- The **Kikan distribution** is a separate package that composes the kernel with the Kikan
  bindings (Kikan-En authority, Kawa, Kizashi, Rei and Danwa adapters) and the
  organizational flow packs (watchdog, unrequested work and practice review). It serves the organization under the `Contained` and `MultiTenant` tiers.

A trust tier selects who decides and how processes are contained. It never switches the
kernel's guarantees off. Kikan has no notion of a tier that skips identity, authorization
or the record of what was done (`mori://shinzui/kikan/docs/cross-cutting-contracts`), so
the following hold in every composition and every tier:

- **K1 Principal.** Every run and every external action carries a principal. A paused
  principal is refused before any protected effect.
- **K2 Authority.** Exactly one authority port decides every external action immediately
  before the effect, and it fails closed.
- **K3 Record.** Every decision and every effect is appended to the action record before
  the effect proceeds. The record is stored where the agent cannot write.
- **K4 Pinned artifact.** A run pins the exact declaration, skill and playbook it
  executes. An edited file affects only later runs.
- **K5 Bounds.** Every run spends under a resource root with deadlines and budgets. Unknown
  usage is recorded as unknown, never as zero.
- **K6 Durability.** Effects happen in journaled steps. A completed step is never rerun,
  and an effect whose fate is unknown is never retried automatically.
- **K7 Evidence.** Observed content is evidence, never instruction
  ([ADR-112](../adr/0112-observed-content-is-evidence-and-never-instruction.md)).
- **K8 Admission.** Run admission is idempotent on its key.

This initiative balances three requirements, and each has its own acceptance test:

- **Routine agents are easy.** An operator declares an agent for a routine task in one
  short Dhall file and a skill, and runs it with one command.
- **Kikan's organizational requirements stay reachable.** Nothing the kernel does for the
  simple case removes a guarantee the organization needs, and every Kikan requirement has a
  named home: a kernel invariant, a port, a binding or a pack.
- **The APIs and boundaries are right before wide adoption.** Every public surface is
  named, owned by one plan, and covered by a compatibility check before it is frozen.

The forcing use case is modernizing seven of the user's keiro services: kanmon, kizashi,
koyomi, danwa, keiei, meibo and jinmyaku. For each repository the playbook ensures `mina`
is configured, ensures the project is registered in Mori, selects and runs the applicable
Seihou blueprints, writes a MasterPlan, executes its plans, captures learnings, and applies
the improved playbook to the next repository. That campaign must be expressed as
declarations running on the kernel, with no change to `shikigami-core`.

**Acceptance tests.** The initiative is done when all four pass.

1. *Architectural.* A new use case ships without changing `shikigami-core`. EP-5 makes this
   mechanically checkable, and EP-7 demonstrates it with the real campaign.
2. *Routine agent.* A new agent for a routine task is one Dhall file of at most fifteen
   lines plus a `SKILL.md`. It runs with one command, asks the operator to confirm its
   declared authority once, runs again without asking, and runs on a local schedule. EP-9
   owns this test.
3. *Portability.* One declaration that uses only kernel vocabulary runs unchanged under the
   stock composition and under the Kikan distribution. Each run satisfies K1 to K8, and the
   two action records differ only in who decided. EP-8 owns the check and EP-10 runs it
   against the Kikan distribution. "Kernel vocabulary" excludes an output or approval
   channel that only one composition registers, and it excludes actions the composed
   authority cannot yet decide (see "The Kikan binding and distribution").
4. *Baseline.* Every surface listed under "Public surfaces" in Integration Points has an
   owner, a stability level and a passing compatibility check. EP-11 owns this gate. It
   freezes in two steps, the declaration baseline and then the kernel baseline, and ends
   the pre-release exception at the second.

**Adoption stages.** Wide adoption waits for the baseline. Stage 1 is the pilot: the
operator's own campaign on their own repositories, run for real while shapes may still
change. Stage 2 begins at the declaration baseline: what the operator writes and runs
every day stops changing underneath them, while the core is still being restructured. It
ends at the kernel baseline. Stage 3 is organizational use through the Kikan distribution
and use by anyone other than the operator. It needs the kernel baseline and the Kikan-En
actions described under "The Kikan binding and distribution". Nothing in this plan invites
stage 3 before both.

**Definition of done for every child plan.** Each child's acceptance includes a run on one
of the user's real repositories or real workloads on this Mac, not only a fixture. The
memory `prioritize-real-use-over-qualification` records why. Hardening for the `Contained`
and `MultiTenant` tiers is deliberately deferred. No child plan may add a Linux-container
qualification suite as a completion gate.

**In scope:** kernel-owned contracts for actions, the action record, outputs, approval
channels and triggers; the `TrustTier` type and the `LocalOperator` tier; a `CodingAgent`
behavior for durable coding-agent workers; declared CLI and MCP tools; a Dhall playbook
behavior with a generic durable interpreter; the routine-agent declaration and command
surface; a pack SDK and a fitness check that keep use cases out of core; moving or retiring
the use-case subsystems now in core; moving the Kikan service bindings out of core into a
Kikan distribution; the real modernization campaign; and the v1 API baseline.

**Excluded:**

- New hardening of the `Contained` and `MultiTenant` tiers. Existing behavior is preserved
  and keeps its existing evidence.
- New Kikan features. The Kikan bindings move unchanged in behavior. Shomei caller
  identity on the HTTP API, cost capture for ordinary runs, the approvals HTTP surface and
  the Kanmon inbox wire stay with their owning plans.
- MasterPlan 21 (enrolled machine daemons). It is deferred; see the Decision Log.
- The actual-model trial of MasterPlan 14 EP-6. It is not a gate here, and the real runs
  in EP-2 and EP-7 supply the live evidence that trial sought.
- Signing and attestation (IR-7), A2A interoperability (IR-6) and governed agent evolution
  beyond playbook proposals (IR-5). The kernel contracts must not close them off: the
  action record is the evidence a signed attestation commits to, and delegation carries
  lineage and budgets.
- Nix packaging of the Kikan distribution. The stock roles keep their frozen closure
  ([ADR-39](../adr/0039-deployment-roles-share-a-frozen-cabal-source-closure.md)).
- Rewriting keiro, Baikai, Seihou, mina, Mori or Kikan-En. Their missing features are
  raised in their own repositories.


## Decomposition Strategy

The decomposition has three layers. The first gives the kernel contracts of its own
(EP-8). The second makes declared agents capable and easy on those contracts (EP-1 to
EP-4 and EP-9) and proves them with the real campaign (EP-7). The third moves everything
that is not kernel out of the core (EP-5, EP-6 and EP-10) and freezes the result (EP-11).
Each child produces a behavior the operator can run on their own machine.

EP-8's first milestone comes first. Today every authorization decision speaks Kikan-En's
closed `AgentAction`, so EP-1's local authorizer, EP-2's coding-agent launch and EP-3's
tool calls would each have to squeeze into Kikan's vocabulary or wait for a Kikan-En
release. EP-8 M1 gives the kernel its own action type, authority port and action record,
with the Kikan-En authorizer as an adapter. It is a mechanical change to about twenty
modules and changes no behavior, which is why it is cheap to do first and expensive to do
after four plans have built on the old type.

EP-1 then adds the tier that authorizes the operator's own actions. It reuses the existing
workspace tools, so its acceptance is a real `Skill` agent reading and editing a real
repository on macOS. EP-2 adds the coding-agent worker, the single largest capability gain.
EP-3 opens the tool set. EP-8's second milestone adds the local output and approval
adapters and the operator-run trigger, so a local run has somewhere to send its result and
somewhere to ask. EP-4 adds the playbook: a Dhall-declared sequence of steps with fan-out,
approval gates and learning capture, interpreted by one generic durable flow in the kernel.
EP-9 turns the pieces into the routine-agent experience: one file, one command, one
confirmation, and a local schedule.

EP-5 and EP-6 restructure the core. EP-5 defines the whole pack API once, including
pack-owned interpreters, and adds a fitness check that fails when use-case code enters the
core. EP-6 applies that boundary to the existing use-case subsystems. Each is moved into a
flow pack, kept in the kernel because it is a genuine kernel primitive, or deleted. EP-10
does the same for the Kikan service bindings and composes the Kikan distribution. EP-7 is
the forcing use case run for real. It is a child plan rather than an integration gate
because the campaign playbook and its learnings are deliverables in their own right. EP-11
is a child plan rather than a checklist because the surface inventory, the compatibility
checks and the end of the pre-release exception are deliverables that outlive this
initiative.

A pre-release fact makes this tractable. Shikigami has no users, no workflow journals that
must resume and no external wire consumers. The user reconfirmed this on 2026-10-30, and
`docs/workflow-versioning.md` records it.
[ADR-27](../adr/0027-the-first-release-establishes-one-clean-durable-baseline.md) allows a
planned v1 surface to replace unreleased declaration and workflow shapes directly until
the first release or deployment. Every child that changes a declaration or a workflow body
under `shikigami-core/src/Shikigami/Agent/` or `shikigami-core/src/Shikigami/Flow/` must
recheck and record those facts, then follow `docs/workflow-versioning.md` (including
`just keiro-gate`). No compatibility patches are needed for shapes that never ran.

The exception ends at EP-11's kernel baseline, not at the first real run. The user decided
this on 2026-11-15. Until that gate, real runs are pilot runs with one rule: **every run is
drained to a terminal state before a change to a workflow or declaration shape lands.**
EP-7's campaign runs obey it. A terminal run journaled before a shape change may become
unreadable by `runs show`; its durable results are the commits, receipts and learnings it
left in the target repositories. EP-11 records the moment the exception ends in this plan's
Decision Log and in `docs/workflow-versioning.md`, and from then on every body change uses
`patch`.

The user also decided on 2026-11-15 that the baseline freezes in two steps.

- The **declaration baseline** freezes what an operator writes and runs: the agent
  declaration with its journal codec, the playbook format, the operator files, the
  `local.report` output helper and the stock commands for local work. It needs EP-1 to
  EP-4, EP-8 and EP-9 Complete, EP-6's first milestone (which removes the `Deterministic`
  arm and so changes the declaration) and EP-7's third milestone.
- The **kernel baseline** freezes what a pack or binding author writes against and what is
  stored: the pack SDK, the kernel ports, the durable wire, the HTTP API, the Kikan output
  helpers and the admin commands. It needs the declaration baseline plus EP-5, EP-6 and
  EP-10 Complete.

Between the two, EP-6 and EP-10 may still change workflow bodies, the SDK and the ports
under the drain rule. They may not change a frozen declaration surface; a change that
turns out to need one goes through a compatible path, such as a new optional field.

Four alternatives were rejected:

- **A rewrite in a new repository.** It discards the kernel pieces that work (the keiro
  journals, objectives, approvals, resource roots, memory and the workspace providers) and
  repeats the original mistake of building a platform before a user. The kernel is
  extracted in place.
- **A thin bypass tool outside Shikigami for the campaign.** It solves the immediate
  problem and leaves the core of Kikan unable to serve the next use case. The user
  explicitly rejected this.
- **Starting with the core shrink (EP-6).** Deleting subsystems before the replacement
  path works would leave nothing runnable. It also lets the restructuring absorb the
  initiative before a single real run happens.
- **Leaving the Kikan types in place and refusing them locally.** The first draft of this
  plan did this: `LocalOperator` refused every Kikan sink, reused Kikan-En's action type
  and added one closed constructor per plan for the ledger and the approval channel. A
  local agent then has no output, and each new kernel effect is again a core change. The
  user chose kernel-owned ports with the Kikan adapters moved out.

Relevant local ADRs, read for this decomposition:

- [ADR-1](../adr/0001-declare-only-what-the-runtime-executes.md): declare a contract only
  when the runtime executes it. EP-6 applies this to the unimplemented `Deterministic`
  behavior arm. It also governs the pack API: each `FlowPack` field lands with one executed
  consumer.
- [ADR-3](../adr/0003-a-seventh-package-keeps-one-off-agent-runs-light.md): the light
  `shikigami-agent` package keeps one-off runs free of platform weight. EP-1, EP-2 and EP-9
  put the operator-facing commands there.
- [ADR-12](../adr/0012-a-declared-workflow-body-only-grows-behind-a-patch.md) and
  [ADR-27](../adr/0027-the-first-release-establishes-one-clean-durable-baseline.md):
  workflow evolution and the pre-release baseline exception.
- [ADR-13](../adr/0013-flow-bodies-reach-the-world-only-through-capabilities.md): flow
  bodies reach the world only through capabilities. EP-5 amends it: a pack's reviewed
  interpreter may use IO, and its flow body may not.
- [ADR-25](../adr/0025-capability-overlays-are-requests-for-additive-model-tools.md): an
  agent requests capabilities and an operator catalog satisfies them. EP-3 extends this to
  declared CLI and MCP tools.
- [ADR-36](../adr/0036-external-agent-actions-require-fresh-exact-authorization.md):
  external actions need fresh exact authorization, and the default is deny-all. EP-8
  restates it over the kernel's own action type, and EP-1 amends it so the authority is
  selected by tier.
- [ADR-39](../adr/0039-deployment-roles-share-a-frozen-cabal-source-closure.md): the stock
  roles are built from one frozen closure of seven `shikigami-*` packages. Packs, the
  Kikan binding and the Kikan distribution therefore carry no `shikigami-` prefix, and no
  stock executable depends on them.
- [ADR-40](../adr/0040-response-options-and-foreground-launches-have-separate-authority.md):
  foreground launches have separate authority, and batch coding-agent runs need
  qualification before becoming background behavior. EP-2 amends this by tier.
- [ADR-59](../adr/0059-harness-policy-is-frozen-at-admission-and-shared-with-ephemeral-execution.md):
  the existing `harness` declaration field is the model tool-loop policy. The new behavior
  arm is named `CodingAgent` to avoid that word.
- [ADR-65](../adr/0065-mcp-provider-revisions-bind-the-approved-tool-contract.md): the
  MCP binding contract. EP-3 implements it.
- [ADR-75](../adr/0075-service-composition-has-a-closed-reviewed-module-budget.md): the
  closed module budget in `tools/style/module-ownership.json`. It is per namespace root and
  knows nothing of packages, so EP-5's kernel boundary is a new check beside it.
- [ADR-112](../adr/0112-observed-content-is-evidence-and-never-instruction.md): observed
  content is evidence, never instruction. It applies to repository content read by
  playbooks in EP-4 and EP-7.

Cross-repository contracts that constrain the kernel. The Kikan cross-cutting contracts
(`mori://shinzui/kikan/docs/cross-cutting-contracts`, the file
`docs/architecture/evolution/contracts.md` in that repository) are the source of the
organizational requirements mapped under "Kikan requirements" below. The Seihou blueprint
migration machinery,
`mori://shinzui/seihou/masterplans/10-blueprint-migration-fan-out-across-a-library-cohort`,
supplies per-edge receipts and not-applicable outcomes that EP-7's playbook consumes. The
improvement request
[governed agent evolution](../improvement-requests/governed-agent-evolution.md) governs
changes to an agent artifact; EP-4's learning step proposes playbook changes under that
rule.


## Exec-Plan Registry

| # | Title | Path | Hard Deps | Soft Deps | Status |
|---|-------|------|-----------|-----------|--------|
| EP-1 | Run declared agents on the operator's own machine through a local-operator trust tier | [docs/plans/126-run-declared-agents-on-the-operator-s-own-machine-through-a-local-operator-trust-tier.md](../plans/126-run-declared-agents-on-the-operator-s-own-machine-through-a-local-operator-trust-tier.md) | EP-8 M1 | None | Complete |
| EP-2 | Run Claude Code and Codex as durable harness workers inside agent runs | [docs/plans/127-run-claude-code-and-codex-as-durable-harness-workers-inside-agent-runs.md](../plans/127-run-claude-code-and-codex-as-durable-harness-workers-inside-agent-runs.md) | EP-1 | None | Complete |
| EP-3 | Let agents declare CLI tools and MCP servers with authority attached to the declaration | [docs/plans/128-let-agents-declare-cli-tools-and-mcp-servers-with-authority-attached-to-the-declaration.md](../plans/128-let-agents-declare-cli-tools-and-mcp-servers-with-authority-attached-to-the-declaration.md) | EP-1; EP-2 M1 (for M3); EP-2 M2 (for M4) | None | Complete |
| EP-4 | Execute Dhall-declared playbooks with fan-out, approval gates, and learning capture | [docs/plans/129-execute-dhall-declared-playbooks-with-fan-out-approval-gates-and-learning-capture.md](../plans/129-execute-dhall-declared-playbooks-with-fan-out-approval-gates-and-learning-capture.md) | EP-2; EP-8 M2 (for M2); EP-3 M4 (for M4) | EP-3 | Complete |
| EP-5 | Move the extension boundary out of shikigami-core with flow packs and an architecture fitness check | [docs/plans/130-move-the-extension-boundary-out-of-shikigami-core-with-flow-packs-and-an-architecture-fitness-check.md](../plans/130-move-the-extension-boundary-out-of-shikigami-core-with-flow-packs-and-an-architecture-fitness-check.md) | None | None | Complete |
| EP-6 | Shrink shikigami-core to the kernel by moving or retiring use-case subsystems | [docs/plans/131-shrink-shikigami-core-to-the-kernel-by-moving-or-retiring-use-case-subsystems.md](../plans/131-shrink-shikigami-core-to-the-kernel-by-moving-or-retiring-use-case-subsystems.md) | EP-5 | None | Complete |
| EP-7 | Modernize the keiro services with a declared campaign playbook | [docs/plans/132-modernize-the-keiro-services-with-a-declared-campaign-playbook.md](../plans/132-modernize-the-keiro-services-with-a-declared-campaign-playbook.md) | EP-3, EP-4 | EP-5 | In Progress |
| EP-8 | Give the kernel its own action, record, output, approval and trigger contracts with local adapters | [docs/plans/133-give-the-kernel-its-own-action-record-output-approval-and-trigger-contracts-with-local-adapters.md](../plans/133-give-the-kernel-its-own-action-record-output-approval-and-trigger-contracts-with-local-adapters.md) | EP-1 (for M2 and M3) | None | Complete |
| EP-9 | Declare and run a routine agent with one file and one command | [docs/plans/134-declare-and-run-a-routine-agent-with-one-file-and-one-command.md](../plans/134-declare-and-run-a-routine-agent-with-one-file-and-one-command.md) | EP-1; EP-8 M2; EP-2 M2b (for the scheduled milestone) | EP-3 | Complete |
| EP-10 | Move the Kikan service bindings out of shikigami-core and compose a Kikan distribution | [docs/plans/135-move-the-kikan-service-bindings-out-of-shikigami-core-and-compose-a-kikan-distribution.md](../plans/135-move-the-kikan-service-bindings-out-of-shikigami-core-and-compose-a-kikan-distribution.md) | EP-5, EP-8 | EP-6 | Complete |
| EP-11 | Freeze the v1 API baseline with a surface inventory and compatibility checks | [docs/plans/136-freeze-the-v1-api-baseline-with-a-surface-inventory-and-compatibility-checks.md](../plans/136-freeze-the-v1-api-baseline-with-a-surface-inventory-and-compatibility-checks.md) | EP-1 to EP-4, EP-8, EP-9; EP-6 M1; EP-7 M3 (for M2); EP-5, EP-6, EP-10 (for M3 and M4) | None | In Progress |

Status values: Not Started, In Progress, Complete, Cancelled.
Hard Deps and Soft Deps reference other rows by their EP- prefix.
A whole-child hard dependency requires that child to be Complete. A dependency written
"EP-n Mk" requires only that milestone's accepted artifact.


## Dependency Graph

```text
EP-8 M1 contracts ─► EP-1 tier ─► EP-2 CodingAgent ─► EP-4 playbooks ─► EP-7 campaign
                        │              │  M2            ▲   ▲                 │ M3
                        │              └─► EP-3 M4 ─────┘   │                 ▼
                        ├─► EP-3 M1–M3 tools ──────────────►┤ (EP-7 hard)   EP-11 baseline
                        ├─► EP-8 M2 local adapters ─────────┘ (EP-4 M2)       ▲
                        │        └─► EP-9 routine agents ─────────────────────┤
                        └─► EP-8 M3 portability check ─► EP-10 Kikan ─────────┤
EP-5 pack SDK ─► EP-6 core shrink ────────────────────────────────────────────┤
      └────────────────────────────────► EP-10 Kikan distribution ────────────┘
```

EP-8 M1 has no dependency. It replaces the Kikan-En action type with the kernel's own in
the authorization path and introduces the action record. EP-1 depends hard on it, because
the `LocalOperator` authority is an adapter of that port and writes that record. EP-8's
later milestones depend hard on EP-1: the local output, approval and trigger adapters are
installed by the `LocalOperator` composition. This is not a cycle, because the dependency
in each direction names a different milestone.

EP-2 depends hard on EP-1. A durable coding-agent step needs a tier that admits a process
on the operator's machine under the operator's authority, plus the `LocalOperator`
workspace provider that EP-1 introduces.

EP-3's first two milestones (CLI tools and MCP for `Skill` agents) need only EP-1. Its
third milestone renders tools for coding agents, so it needs EP-2 M1's accepted
`CodingAgent` arm. Its fourth milestone runs a declared tool as a durable step with a long
deadline, so it needs EP-2 M2's restart-safe attempt machinery.

EP-4 depends hard on EP-2, because the playbook's main step kind runs a coding agent. Its
second milestone needs EP-8 M2's local approval channel. Its fourth milestone needs EP-3
M4's durable tool step. It depends soft on EP-3 otherwise: it can ship without tool steps
and add them when EP-3 lands.

EP-9 depends hard on EP-1 and EP-8 M2: a routine agent needs the tier, the operator-run
trigger and the local report output. Its scheduled milestone needs EP-2 M2b, which lets
`shikigami-worker` run `LocalOperator` work. It depends soft on EP-3, because a routine
agent that declares tools needs them resolved.

EP-5 has no dependencies and can run in parallel with everything on the top row. It
changes package structure, not behavior. EP-6 depends hard on EP-5. EP-10 depends hard on
EP-5 (the binding is composed like a pack) and on EP-8 (the bindings are adapters of
EP-8's ports). It depends soft on EP-6, because the Kikan distribution composes the
organizational packs EP-6 creates and can start with the examples pack alone.

EP-7 depends hard on EP-3 and EP-4. The campaign calls `mina`, `mori` and `seihou` as
declared tools and is itself a playbook. It depends soft on EP-5: the campaign's
declarations should live outside the core, but an `agents/` directory works until the pack
boundary exists.

EP-11's first milestone has no dependency and should start at once: it checks in the
surface inventory and runs every compatibility check in report-only mode, so drift is
visible while the other plans land. Each owning plan registers its surface there when it
ships. Its declaration baseline depends hard on EP-1 to EP-4, EP-8 and EP-9, on EP-6 M1
and on EP-7 at its third milestone. The declaration surface must not freeze before the
campaign has shown, on a second repository, that it carries a real job. Its kernel
baseline depends hard on the declaration baseline and on EP-5, EP-6 and EP-10. EP-7's
fan-out milestone may finish after either. In EP-11's milestones, M1 is the report-only
inventory, M2 the declaration baseline, M3 the exposure shrink and audit, and M4 the
kernel baseline.

Several plans add fields to `AgentRunDeps`, `WorkerEnv` and the tier composition. None
blocks another, and whichever lands second rebases onto the first.

The recommended order for one contributor is EP-8 M1, EP-1, EP-2, EP-3 M1 to M3, EP-8 M2,
EP-9, EP-3 M4, EP-4, EP-7 M1 to M3, then EP-6, EP-10 and the rest of EP-11, with EP-5 and
EP-11 M1 by a second contributor from the start. EP-7's repository inventory needs only the declared `mori`
tool and can begin as soon as EP-3 M1 lands. EP-9 is placed early on purpose: it is the
first point at which the operator can use Shikigami for everyday tasks.


## Integration Points

**Public surfaces.**
Every surface below is a contract that someone outside the kernel writes against. Each has
one owning plan. EP-11 owns the inventory itself (`api-baseline/surfaces.dhall`, checked by
`just api-baseline`), assigns each surface a stability level (`stable`, `provisional` or
`internal`) and adds the compatibility check named here. The owning plan registers its
surface in that inventory in the change that ships it.

- The agent declaration: `schema/Agent.dhall` and `Shikigami.Agent.Decl`. Check: a frozen
  semantic hash of the schema and a corpus of declarations that must keep loading.
- The playbook format: `schema/Playbook.dhall` (EP-4). Same check.
- The operator files: `schema/LocalOperator.dhall` (EP-1) and `schema/Tools.dhall` (EP-3).
  Same check.
- The pack SDK: `shikigami-core:flow-sdk` and `shikigami-core:pack-sdk` (EP-5). Check:
  pinned export lists, so adding to the SDK is a reviewed change.
- The kernel ports: `Shikigami.Authority`, `Shikigami.Record`, `Shikigami.Output`,
  `Shikigami.Approval.Channel` and `Shikigami.Trigger` (EP-8), exported through the pack
  SDK. Same check.
- The durable wire: workflow journals, the `run_jobs` payload and the aggregates declared
  under `domain/`. Check: `just keiro-gate`, which already exists.
- The HTTP API: `docs/api/openapi.json`. Check: an OpenAPI diff that fails on a breaking
  change.
- The operator CLI: `shikigami`, `shikigami-agent-run`, `shikigami-local`,
  `shikigami-tools`. Check: golden `--help` output for the documented verbs.

The agent declaration, the playbook format, the operator files and the stock local
commands freeze at the declaration baseline; the rest freeze at the kernel baseline. Until
its freeze, a plan may change a surface it owns. It may not change a surface
another plan owns; it records a gap against the owner instead.

**The kernel action vocabulary and the authority port.**
EP-8 owns them; EP-1, EP-2, EP-3 and EP-10 consume them. Today
`Shikigami.Action.Authorization.ActionAuthorizer` takes `Kikan.En.Action.AgentAction`. EP-8
M1 introduces the kernel's own type and port in `Shikigami.Authority`:

```haskell
-- As landed by EP-8 M1 (ADR-123):
data Action
  = UseCapability !CapabilityOperation !CapabilityTarget  -- ConnectProvider | InvokeTool name
  | EmitOutput !OutputKind !OutputTarget                   -- open by kind; adapters own their kinds
  -- added by the plan that executes it (ADR-1):
  | RequestApproval !ApprovalChannelKind     -- EP-8 M2
  | LaunchCodingAgent !CodingAgentTarget     -- EP-2
  | RunDeclaredTool !DeclaredToolTarget      -- EP-3
  | DelegateRun !AgentName                   -- the plan that first authorizes a delegation

-- Abstract: read with authority.decide and authority.source; build with
-- `authority source decide`; install with `recorded` (or `recordedIn` over PostgreSQL);
-- scope each run with `scopeToRun`.
data Authority
```

The kernel's own workspace, worker-session, objective and maintenance effects are
`UseCapability (InvokeTool <digest>)` on the reserved `shikigami.workspace`,
`shikigami.worker-sessions` and `shikigami.objectives` capabilities, exactly as they were under
ADR-36. EP-8 M1 found no executed `ReadWorkspace`, `WriteWorkspace`, `ExecuteWorkspace` or tool
discovery, so they are not declared.

The sum is closed over what the kernel itself executes and open by `OutputKind` and
`ApprovalChannelKind` where adapters extend it. A plan that adds a kernel effect adds its
constructor here in the same change. The Kikan-En authorizer becomes an adapter that maps
`Action` to `AgentAction` and refuses an action it cannot map. Deny-all stays the default
when no authority is composed. `Principal` is the existing checked
`DeclarationCoordinate "principal"`. EP-8 restates ADR-36 over this type in a new ADR.

One call path cannot reach the port directly. A coding agent's own shell commands are
decided by EP-3's gate hook, a separate process started by the vendor tool. The authority
decides the launch, the launch writes a sealed grant file, and the hook decides each
command against that file with the same pure function. Its decisions are folded into the
action record when the step settles.

**The action record.**
EP-8 owns it; every plan that performs an external effect appends to it. This replaces the
`ActionLedger` that the first draft gave to EP-1. There is one record:

```haskell
newtype ActionRecord = ActionRecord { append :: RecordEvent -> IO (Either RecordError ()) }
data RecordEvent = RecordEvent
  { at :: !UTCTime, run :: !(Maybe WorkflowId), principal :: !Principal
  , tier :: !TrustTier, agent :: !AgentName, entry :: !RecordEntry }
data RecordEntry = RecordEntry { kind :: !RecordKind, payload :: !Value }
```

`RecordKind` is a checked, dotted name such as `authority.decided` or `tool.called`. The
producer owns its kind and a typed constructor for its payload, so a new effect needs no
change to a shared sum. An authority decision whose append fails is a refusal: an
unrecorded action never proceeds (K3). EP-8 chooses the store. Durable runs write to
PostgreSQL beside the run evidence, so one query answers "what did this run do"; the
database-free `shikigami-run-behavior` writes a file. `shikigami-local ledger` (EP-1) is
the operator's single view in the stock composition. EP-10 projects the same events into
the Kikan run evidence.

**`TrustTier` and the per-run port resolution.**
Involves EP-1 (owner), EP-2, EP-3, EP-4, EP-8 and EP-9. EP-1 defines the closed sum and the
composition:

```haskell
data TrustTier = LocalOperator | Contained | MultiTenant

data TierComposition = TierComposition
  { tier :: !TrustTier
  , resolve :: RunSubject -> IO (Either TierRefusal TierRuntime) }

data RunSubject = RunSubject
  { agent :: !AgentDecl, principal :: !Principal, run :: !WorkflowId
  , repository :: !(Maybe RepositoryId) }
```

`TierRuntime` holds the ports resolved for one run and one repository: the authority, the
action record, the capability runtime, the workspace host and the process launcher. A new
tier-dependent behavior adds a field: EP-2 adds the coding-agent runner and EP-3 the tool
catalog. Resolution is per run and per repository because a long-lived worker serves many
agents and a playbook step may select a different repository than the step before it. The
first draft built one `TierRuntime` per command invocation, which fits neither. Use-case
code never matches on `TrustTier`.

The tier selects who decides and how processes are contained. Which services exist
(outputs, approval channels, the directory) is selected by the composition, not by the
tier. `Contained` and `MultiTenant` keep what each executable does today: the worker's
authority is selected by `authorization.actions.mode`, while the light commands and
conversations stay deny-all. EP-1 writes the tier ADR, which amends ADR-36.

**How the operator grants authority under `LocalOperator`.**
EP-1 owns it; EP-3 and EP-9 consume it. The user decided on 2026-11-15 that the operator
confirms once per declaration. An interactive run shows what the declaration asks for (the
repository and placement, the capabilities, the commands and the declared tools) and asks
once. The answer is stored outside every workspace, keyed by the digest of the declaration
and the repository. A changed declaration asks again. A run with no terminal, which
includes every worker and scheduled run, uses only stored approvals and refuses otherwise.
The command that submits a run is the one that asks, because it has the terminal:
`shikigami-agent-run`, EP-4's `shikigami playbook start` and EP-9's `shikigami-local run`
and `up` all call EP-1's grant check before they enqueue anything. A scheduled run carries
no repository, so the resolver takes it from the stored grant and refuses an agent with
none or several. Approved commands for `workspace.exec` stay in the approvals file until
EP-3 lands, because a declaration has no field for a command line before then.
The approvals file `schema/LocalOperator.dhall` remains the explicit form of the same
grant, for operators who prefer to write it. Every confirmation is itself an
`authority.granted` record entry. EP-3's operator tools file keeps one job: it holds what a
declaration may never carry, namely MCP server transports and credentials. For CLI tools
the confirmed declaration is the grant, so the operator does not write the same patterns
twice.

**Outputs.**
EP-8 owns the port; EP-9 and EP-10 consume it. The closed `Sink` union becomes an open
output contract. A declaration lists `outputs`, each a kind and a configuration. An
`OutputAdapter` registered at composition validates the configuration when the declaration
loads and delivers through the kernel's existing intent, outbox and receipt mechanism
(`Shikigami.Sink.Intent`, `Shikigami.Sink.Delivery`), which stays kernel code. Authoring
stays typed: each adapter ships a Dhall helper that builds its output value. The stock
composition registers `local.report`, which writes the run's result as a file under the
operator's state directory. The Kikan binding registers `kawa.digest`, `kizashi.signal`,
`rei.action`, `danwa.conversation` and `channel.egress`. A declaration that names a kind
its composition does not register fails to load, with a message listing the registered
kinds. A declaration that lists no output receives its composition's default, as the user
decided on 2026-11-15: `local.report` in the stock composition and `kawa.digest` in the
Kikan distribution. The default is resolved when the run is admitted and pinned in the
journal, and `shikigami validate` and the confirmation prompt show it, so where a result
goes is never hidden. An explicit list always wins. This is what lets a routine agent be
promoted into the organization unchanged. EP-1 no longer refuses sinks: until EP-8 M2 lands, a `LocalOperator` run of a
declaration with Kikan sinks is refused at load.

**Approval channels.**
EP-8 owns the port and the `local.inbox` adapter; EP-4 consumes them; EP-10 moves the
Danwa and Kizashi channels into the Kikan binding. The first draft had EP-4 add a
`ViaOperatorInbox` constructor to the closed `ApprovalChannel`. Approval tokens are never
derived from a review id and never printed
([ADR-30](../adr/0030-an-approval-request-is-a-durable-child-workflow.md)).

**Triggers.**
EP-8 owns the declaration change; EP-9 owns the commands. The `Trigger` union gains
`Manual`, meaning the operator or another run starts it, and `trigger` defaults to it. All
intake still ends in a `RunJob`. `Schedule` runs under `LocalOperator` through the local
worker and scheduler (EP-9). `Stream` and `Event` intake from Kawa are Kikan bindings
(EP-10).

**Which process runs `LocalOperator` work.**
Involves EP-1, EP-2 (owner), EP-4, EP-7 and EP-9. EP-1 lets the light commands run
`LocalOperator` agents and has `shikigami-worker` refuse that tier for now. EP-2 lifts the
refusal (its milestone M2b), because playbooks, the campaign and scheduled routine agents
span hours and human approvals. EP-2 records which package composes the coding-agent
runner so that both the light commands and the worker can use it, within ADR-3's package
rules.

**The agent declaration schema (`schema/Agent.dhall` and `Shikigami.Agent.Decl`).**
Involves EP-2, EP-3, EP-4, EP-6, EP-8 and EP-9. EP-2 adds the `CodingAgent` arm, EP-3 the
`tools` field, EP-4 the `Playbook` arm. EP-8 replaces `sinks` with `outputs` and adds
`Trigger.Manual`. EP-6 removes the `Deterministic` arm. EP-9 owns the defaults and the
short form a routine agent uses, and it may not add a field another plan owns. Two rules
apply to every change. A new field has a Dhall default, so checked-in manifests keep
loading. `AgentDecl` is also journaled JSON whose instances strip defaulted fields by hand
(`shikigami-core/src/Shikigami/Agent/Decl.hs`), so each new field or arm needs the same
codec treatment and a round-trip test. The plans land serially in the recommended order; a
later plan rebases onto the earlier schema rather than editing another plan's arm.

**Durable external process attempts.**
EP-2 owns the machinery; EP-3 consumes it. A coding-agent run and a long-running declared
tool call (`seihou agent run --batch` runs for an hour) are the same problem: a process
that must outlive the worker, be reattached after a restart, and end `Uncertain` rather
than be launched twice. EP-2 builds its attempt directory, its pure recovery decision and
its `admit`, `attempt`, `settle` child workflow so that the launched command is a
parameter. EP-3 M4 reuses it for declared tools run as steps.

**Durable coding-agent step contract.**
EP-2 owns it, and EP-4 and EP-7 consume it. It is a capability usable from a flow body per
ADR-13, in `shikigami-core/src/Shikigami/Flow/CodingAgent.hs`:

```haskell
codingAgent :: (CodingAgent :> es) => DeclarationCoordinate "coding-agent-key" -> CodingAgentStep -> Eff es CodingAgentOutcome
data CodingAgentOutcome
  = Completed !CompletedRun | Failed !FailureReason | TimedOut !PartialRun | Uncertain !UncertainRun
```

`CodingAgent` joins `FlowEffects` as a kernel capability with no ambient IO, the way
`Workers` and `Delegate` did. `CompletedRun` carries the exit status, the changed-file
summary, the resulting commit, the agent's bounded `finalMessage` and the evidence
reference. After a worker restart, the step reattaches to a still-running attempt. Baikai
cannot resume a vendor session, so an attempt whose launcher died without a result ends
`Uncertain` and is shown to the operator. A completed step is never rerun. EP-2's
`CodingAgentWorkspace` has only `RunWorkspace`; EP-4 adds the repository-selector
constructor that `ForEach` needs, and EP-1's workspace host identifies a worktree by run
and repository so that one run may hold several. A step may attach skills: `CodingAgentStep`
carries a list of skill directories that EP-2 makes readable to the vendor tool, because
the agent works in the target repository and cannot otherwise see skills kept beside the
playbook. The admitted tool set is EP-3's `ResolvedToolSet`.

**Declared tools, for three hosts.**
EP-3 owns the resolved tool set and every way it is used; EP-2, EP-4 and EP-7 consume it.
A declared tool reaches a run in three ways, and one decision function, `decideToolCall`,
serves all three:

- A `Skill` agent's model calls it as a model-facing tool, with a deadline of at most ten
  minutes. Durable `Skill` runs admit only observations.
- A `CodingAgent` runs it as a shell command, confined by the rendered allow-list and the
  gate hook. **Representative check, owned by EP-3:** a `CodingAgent` agent running Claude
  Code on a real repository successfully calls a declared `mori registry show` tool, and an
  undeclared `gh` call is refused.
- A playbook `Tool` step runs it as a durable step (EP-3 M4), through the capability
  `runDeclaredTool`. Here the call may mutate and may run for hours, bounded by the
  declaration, because it uses EP-2's attempt machinery and ends `Uncertain` instead of
  repeating. The first draft had no owner for this path, limited every call to 600 seconds
  and limited durable runs to observations, which the campaign's `seihou agent run` and
  `mori register` steps cannot live within.

**Playbook declaration format.**
EP-4 owns it, and EP-7 consumes it. The format is Dhall: steps of kind `CodingAgent`,
`Skill`, `Tool`, `Approval`, `RunPlaybook` (nested), plus `ForEach` over an item source and
`Reflect` for learning capture. EP-7's draft was written against a different, imagined
schema, so EP-4 confirms these needs of the campaign and EP-7 is rewritten to EP-4's format:
an item source that reads the run's trigger payload, so one playbook serves one repository
per run; an item source that reads an earlier step's JSON output; a `CodingAgent` step that
attaches skills and exposes named JSON fields of its final message to later steps; and a
`Tool` step with a deadline of hours. **Representative check, owned by EP-4:** a
two-repository playbook that runs a coding agent per repository, pauses at an approval,
resumes after a worker restart without repeating a completed step, and records one
learning. **Earliest interaction check, owned by EP-7:** a one-step playbook that runs the
declared `mori status --json` tool on kanmon.

**The pack API and the kernel fitness check.**
EP-5 owns the whole pack API; EP-6, EP-8 and EP-10 consume and extend it. The first drafts
of EP-5 and EP-6 each defined `FlowPack` and disagreed on its name type, its fields, what a
pack may depend on and who composes it. The reconciled rules:

- One type, `Shikigami.Flow.Pack.FlowPack`, named by `FlowPackName`. EP-5 defines it. A
  later plan that needs a new field extends EP-5's type and records that in its Decision
  Log; it never defines a parallel type.
- A pack flow is a body plus a pack-owned interpreter. The body is written against the
  pack's own capability row and the kernel's, with no `IOE` and no `Store`. The interpreter
  may use both. EP-5 defines this from the start, because it decides what the SDK exports.
  `FlowEffects` then shrinks to kernel capabilities only (EP-6).
- There are two SDK components. `shikigami-core:flow-sdk` is what a flow body may import.
  `shikigami-core:pack-sdk` adds what an interpreter, a trigger hook or an adapter needs:
  the kernel ports, a read view of the run, and the store. A pack library depends on these
  two components and on no other Shikigami package. What a moved subsystem needs from the
  kernel is exported through `pack-sdk` deliberately. That is how this initiative turns 357
  exposed modules into a reviewed API.
- A pack contributes flows, decision programs, program tasks, trigger hooks, output
  adapters, approval-channel adapters, admin CLI verbs and setting decoders. Each field
  lands with its first executed consumer (ADR-1): EP-5 lands flows, programs and tasks;
  EP-6 lands trigger hooks, verbs and settings; EP-8 lands the two adapter fields. EP-10
  lands the field for an extra workflow family, whose one consumer is the Danwa
  conversation workflow; no use-case pack needs it now that the adaptive coordinator stays
  in the kernel.
- **Representative check, owned by EP-5, run before any subsystem moves:** the watchdog
  flow body, the most demanding consumer, compiles in a pack against the pack flow shape
  with its `Observe` interpreter. It proves the shape before EP-6 depends on it.
- Packs live under `packs/` and are named `flow-pack-<name>`, with modules under
  `FlowPack.<Name>`. No pack, binding or distribution package uses the `shikigami-` prefix
  (ADR-39). EP-6's packages are therefore `flow-pack-examples`, `flow-pack-practice-review`,
  `flow-pack-initiative` and `flow-pack-watchdog`.
- No stock executable depends on a pack, and a pack package ships no executable. Each
  role library exposes a `...With` entry point, and a distribution package composes packs
  into its own executables. EP-5 creates `packs/examples-distribution` for its first pack.
  EP-6 creates the distribution package `kikan-shikigami` in its second milestone, and
  EP-10 adds the Kikan binding to it.
- Each pack keeps its flow bodies in a sublibrary that depends on `flow-sdk` only, so the
  compiler, not a convention, keeps IO out of a body.
- The fitness check is a new check, not an extension. `PackageArchitectureSpec` counts
  packages by the `shikigami-` prefix and `tools/style/module-ownership.json` is per
  namespace root, so neither sees a pack today. EP-5 adds a closed list of kernel
  namespaces in `shikigami-core` and the pack dependency rules. EP-6 and EP-10 shrink the
  list. This deserves a new ADR, written by EP-5: "the kernel owns primitives, and use
  cases ship as declarations or out-of-core packs".

**Step labels.**
EP-5 owns the rule; EP-6 follows it. keiro declares the labels of the `AgentRun` body in
the core's `domain/shikigami/agent-run.keiro`, and that one flat body today lists
`watchdog-*`, `initiative-*`, `practice-review-*` and example labels. A pack's labels are
pack-owned and carry the pack's name as a prefix. When a flow leaves the core, its labels
leave the core specification with it, and its `patch` gates go too, since no journal needs
them before the baseline. The first draft of EP-6 kept the labels in the core
specification, which would have left every organizational use case in the kernel's durable
contract. Because `keiro-diff` cannot yet gate labels declared outside the core
specification, each pack ships a golden inventory of its labels in its own test suite, and
EP-5 files a keiro improvement request for workflow fragments declared in separate
packages. At the baseline the core specification holds kernel labels only. The closed
`DecisionLabel` and `RouteLabel` become checked values in EP-6, which opens them to packs.
Decision and route sites are pack-prefixed too (`watchdog-drift`), so the old label bytes
are not kept.

**The Kikan binding and distribution.**
EP-10 owns them. The binding package `kikan-shikigami-binding` holds the Kikan-En authority
adapter, the Meibo directory source, the Kawa, Kizashi, Rei, Danwa and channel output
adapters, the Danwa and Kizashi approval channels, the Kawa stream and event intake, the
Danwa conversation workflow and the Rei tracker adapter. The distribution package
`kikan-shikigami` composes the kernel, the binding and the organizational packs into its
own worker, scheduler, consumer, server and admin executables. After EP-10,
`shikigami-core` links no Kikan client library, and the fitness check enforces it. About
5,000 hand-written lines and eight Cabal dependencies leave the core.

Three consequences follow. The stock `shikigami-consume-stream` and
`shikigami-consume-events` roles are removed, because Kafka intake is a Kikan binding;
until the distribution is packaged with Nix, a deployment builds them from
`kikan-shikigami`. No Meibo client exists today (the directory has only `disabled` and
`file` sources), so there is nothing to move and a live Meibo source stays with its owning
plan. Kikan-En has no action for a declared tool or a coding-agent launch, so the Kikan
distribution refuses both. EP-10 files an improvement request in
`mori://shinzui/kikan-en` for those actions; until it is fulfilled, `CodingAgent` agents,
declared tools and therefore playbooks run only under the stock composition. The user
decided on 2026-11-15 that organizational use (stage 3) waits for it. The request asks
for four things: two new constructors on `AgentAction` in
`mori://shinzui/kikan-en/packages/kikan-en-contract`, one for running a declared tool
(tool name, operation class and repository) and one for launching a coding agent
(provider, workspace access and repository), each with its tag and resource rendering; the
matching permissions and relations in Kikan-En's authorization schema, with grant
fixtures; a contract release; and conformance cases for allow and deny. On the Shikigami
side EP-10 then maps the two kernel actions in `toAgentAction` and adopts the release.
**Representative check, owned by EP-8 and run by EP-10:** the portability test in Vision &
Scope.

**Kikan requirements and where each lives.**
EP-10 keeps this list true. It records where each requirement of
`mori://shinzui/kikan/docs/cross-cutting-contracts` lands, so that no kernel change closes
one off.

- Identity and the kill switch (C14): invariant K1 through the directory port. Both
  compositions use the file directory source today; a live Meibo source is future binding
  work.
- Signed caller identity (C11): the HTTP API, unchanged and out of scope.
- Authorization at every tool and sink dispatch, fail closed (C13): invariant K2, with the
  Kikan-En adapter in the binding (EP-10 M2). Met for the actions Kikan-En names; a declared
  tool and a coding-agent launch are refused under the distribution until Kikan-En adds
  them (`mori://shinzui/kikan-en/improvement-requests/IR-5`). Outbox deliveries are
  re-authorized at publish, under their run.
- "Every action is remembered" (C3) and evidence the agent cannot rewrite: invariant K3.
  The action record holds every decision and effect of a run, an outbox delivery included
  since EP-10 M6, and `record check` asserts K1 to K8. Projecting the record into
  attestation evidence and a per-run Kawa summary is open (EP-10 M6, user decision).
- Activity envelopes, signals, commitments and conversations (C1, C4, C5): the binding's
  output adapters, its Kawa stream and event intake (`kikan-shikigami-consume-stream`,
  `kikan-shikigami-consume-events`) and its Danwa conversation channel on the kernel's
  conversation loop. Met against stubs and a real broker; no Kizashi, Danwa or Kanmon
  instance runs locally (EP-10 M3, M5).
- One exact behavior artifact per run, and governed evolution: invariant K4. Playbook
  proposals (EP-4) are the only evolution path in scope.
- Budgets, cost and usage: invariant K5.
- Tenancy: no tenant field. "Tenancy is data in the graph"; Space context travels in
  `context_refs`, so the kernel adds no tenant type and `MultiTenant` remains a tier.
- Attestation: evidence collection is kernel; signing is a future binding concern.
- A2A delegation: `DelegateRun` carries lineage and budgets; the transport is a future
  adapter.
- Organizational use cases: the watchdog, unrequested work and practice review are packs.
  Adaptive delivery and recurring mandates are kernel primitives.

**Memory for learnings.**
EP-4 owns the convention, and EP-7 consumes it. Learnings are Kioku memories written by
the playbook's `Reflect` step under a playbook-scoped key. A proposed playbook change is a
Git change to the playbook file, offered for human approval. It is never applied to a
running playbook, which follows the governed-agent-evolution request.

**Kernel versus use-case classification.**
EP-6 owns it for use-case subsystems and EP-10 for Kikan bindings; EP-5's fitness check
starts from it. EP-6's draft confirmed the first four groups against the code's import,
workflow, migration and route dependencies, and EP-5 adopts them rather than its own
earlier list.

- **Kernel:** agent runs and execution, objectives, approvals, resource roots, memory,
  workspaces, capabilities, the authority port, the action record, worker sessions, and
  the output and trigger mechanisms. Also `Router`, `Mandate` and `RecurringObjective`,
  which are coordination primitives that other features build on, and all of adaptive
  delivery: the coordinator, its proposal admission and its keiro spec. Evidence collection
  for attestation is kernel.
- **Flow pack:** `PracticeReview` (with the architecture-practice router flow),
  `Initiative`, `Watchdog`, and the example flows in
  `shikigami-core/src/Shikigami/Flow/`.
- **Kikan binding:** the service clients under `Shikigami.Sink`, the Kikan-En authorizer,
  the Meibo directory source, the Danwa conversation channel (the conversation loop itself
  is a kernel primitive, by the user's decision of 2026-11-17), `Objective.Tracker`'s Rei
  adapter and the stream and event consumers. All but the Meibo source, which does not
  exist yet, live in `packs/kikan-shikigami-binding` since EP-10 M2 to M5
  ([ADR-131](../adr/0131-one-kernel-is-composed-two-ways-and-kikan-services-are-bindings.md)).
- **Playbook:** none of today's subsystems. Each holds state or interpreter logic that a
  playbook cannot express, so EP-6 does not depend on EP-4.
- **Retire:** the `Deterministic` behavior arm, together with its only declaration,
  `agents/detectors/stalled-intention.dhall`, and the five unused items the user approved
  on 2026-11-15.

Moving a subsystem out of the kernel never removes a supported feature. After EP-6 and
EP-10, every capability supported today still works: as a flow pack, as a binding, or as a
kernel primitive. Removing anything beyond the approved retirements requires the user's
explicit decision, recorded in this plan's Decision Log.

The cross-plan ADRs this initiative should produce are: the kernel's own action vocabulary,
record and ports (EP-8, restates ADR-36); tier-selected authority and confirm-once grants
(EP-1, amends ADR-36); coding agents as durable workers and tier-scoped qualification
(EP-2, amends ADR-40); declared tools and MCP implementation (EP-3, implements ADR-65 and
extends ADR-25); playbooks as the default extension (EP-4); the kernel boundary, the pack
SDK and pack-owned interpreters (EP-5, amends ADR-13 and ADR-75); subsystem dispositions
(EP-6); the Kikan distribution and the two-composition rule (EP-10); and the v1 baseline
and its compatibility checks (EP-11, ends ADR-27's exception). `docs/adr/` has no OKF
profile, so each plan allocates its ADR number from the files present when it is
implemented.


## Progress

Eleven child plans exist. On 2026-11-15 EP-8 M1 (the kernel action vocabulary, authority port
and action record) was accepted and EP-1 (the local-operator trust tier) completed: an operator
runs a declared agent against their own repository with one command and one confirmation, and
it reads, edits, runs approved rules and commits on a run branch or in place. EP-2 M1 is
accepted: a declared `CodingAgent` runs Claude Code on a real repository as a durable child
workflow and commits on the run branch (ADR 0126 scopes ADR 0040's batch gate to tiers). EP-2
is complete: Claude Code and Codex run on a real repository from the one-off command, from
`--resume` after a kill, from a `local-operator` worker draining `enqueue-run --workspace`, and
from a flow body under call-site keys. EP-3 M1 to M3 are accepted (ADR 0127): a declaration
names CLI tools and MCP server tools, the operator confirms it once, and a `Skill` model, Claude
Code (through a PreToolUse gate) and Codex (MCP only) use exactly those tools, with every call in
the action record. Next in the recommended order are EP-8 M2, EP-9 and EP-3 M4; EP-5 and EP-11
M1 can still start in parallel. EP-8 M2 is accepted: outputs with a composition default (a
local report), a local approval inbox, and `Trigger.Manual` as the default; the Kikan sinks
keep their path until EP-10. EP-3 is complete (declared tools also run as durable, restart-safe
flow steps). EP-4 is complete: Dhall playbooks run durably across repositories with
approvals, reflections that carry learnings forward, bundle proposals on a branch, and fan-out
over tool output (ADR 0128). EP-7 M1 is accepted: the campaign is declared under
`agents/campaigns/keiro-modernization/`, and kanmon passed readiness in place (Mori current,
an `AGENTS.md`, a build plan, an upgraded Seihou manifest). Kizashi replaced kanmon as the pilot
(kanmon has no keiro dependency). The kizashi pilot was stopped on 2026-11-16 because it was
slower than the work by hand; keiro 0.25 was finished by hand, and the playbook's remaining
untested behavior was checked in minutes with a fixture bundle (`build-repair`), which found
and fixed two kernel defects (FRIC-78, FRIC-79). EP-7 M2's acceptance (a full gated pilot)
is not met, and the campaign's shape needs fewer gates and steps before koyomi. EP-9 is complete: a routine agent is one short file, `shikigami-local
run` runs it with one confirmation, and `shikigami-local up` runs scheduled ones locally (the
worker still composes local-operator ports only for coding agents; Surprises). EP-5 M1 is accepted (ADR 0129): the kernel fitness check classifies every core namespace,
freezes the leaving groups and steers a new use-case namespace to a declaration or a pack. EP-5 M2
is accepted on 2026-11-16: flows, decision programs and tasks are composed from packs at
executable start (`Shikigami.Flow.Pack`), `shikigami-core:flow-sdk` and `:pack-sdk` exist with
pinned export lists, and `packs/flow-pack-examples` owns at-risk-customer, which
`packs/examples-distribution` runs and the stock executables refuse. The representative check
against the watchdog changed the pack shape before any subsystem moved (the store's error
channel, the workflow name, and a flow's decision mode as declaration data), and
`mori://shinzui/keiro/okf/improvement-requests/concepts/IR-61` asks keiro for pack-declared
workflow fragments. EP-5 is complete: M3 built a pack and a distribution in the separate local
repository `shikigami-operator-packs` (intended URI `mori://shinzui/shikigami-operator-packs`)
against this checkout and ran its `repository-ledger` flow over real checkouts with no change
here. EP-6 can start. EP-11 M1 is accepted on 2026-11-16: `api-baseline/surfaces.dhall`
registers eight surfaces in report mode (the agent declaration and its journal codec, two
commands, the HTTP API, the durable wire and the two SDK components), `just api-baseline`
checks them against their pins, and `docs/architecture/api-baseline.md` states the stability
policy. The core exposes 388 modules, of which 149 have no consumer. EP-6 M1 is implemented on
2026-11-16 (`2965ac6e`): the `Deterministic` arm, `ShikumiProgram.enabledBy`, the
`shikigami.fired` table, `shikigami danwa-spike` and `agents/detectors/` are gone, and the
`agent-declaration` and `cli-shikigami` surfaces are re-pinned. Its real-model Skill run
was made by the operator on 2026-11-16 (run `3b61386e`, fsrs-hs, 8 approved and 0 refused),
so M1 is accepted. EP-6 M2 is accepted on
2026-11-16: decision and route sites are checked values a pack supplies, the remaining
example flows and their programs moved to `flow-pack-examples`, and the `kikan-shikigami`
distribution's worker created a real objective from `objective-example` while the stock
worker refused the manifest. `flow-sdk` now re-exports whole kernel modules (758 names),
which needs curating before the kernel freeze. EP-6 M3 is accepted on 2026-11-16
(`abac7d83`): practice review and its router run from `flow-pack-practice-review`, a pack
owns a configuration setting for the first time (`FlowPack.settings`), and a pack interpreter
reaches the run's model, stores and grants through `FlowRunContext`. A real review trigger
for fsrs-hs produced the same `unresolved` verdict before and after the move, and the first
real routing call exposed and fixed a router prompt defect (`60938b9a`, FRIC-84). EP-6 M4 is
accepted on 2026-11-16 (`8780e464`): the kernel got the pieces Initiative needed to leave,
each landed with Initiative as its first user and no change in its behavior. A pack setting has a shape and an optional
default (`a132deeb`); the stream consumer consults a pure, transactional `StreamHook`
(`f80be910`) that a pack contributes through `FlowPack.triggers` (`dec023b0`); a pack
contributes admin verbs over an `AdminContext` (`a921ceaf`); and the proposing flow runs as a
`PackFlow` with a kernel counter port, its two patch gates gone (`ee409f61`). Initiative
then moved to `flow-pack-initiative`, and the distribution gained
`kikan-shikigami-consume-stream`. A real meeting transcript published to Kafka became a
proposal from a real model assessment, an ask, an approval and an objective. That run found
a kernel defect no fixture reaches: a worker's resume loop re-entered every run its job loop
was still driving, so any step slower than a second ran twice and the proposing run was
failed by its duplicate. The worker's first drive now holds the instance lease (FRIC-86).
EP-6 M5 is accepted on 2026-11-16 (`8b39a9bd`): the watchdog runs from
`flow-pack-watchdog`. The kernel gained a schedule hook, through which a pack funds its
scheduled ticks from an operator's allowance while the kernel enrolls the root
(`38bd5798`), and a pack gauge sampled by the worker (`f7d25186`); `Observe` left the
kernel's effect row and the watchdog's patch gate and labels left the specification. In a
real run from the distribution, sweeps fired every minute, observed the objective a real
proposal had created, and opened a `stuck-coordinator` finding when it sat idle. With
three use cases out, the builtin pack holds `run-declared-tool` and `adaptive-delivery`.
EP-6 M6 is accepted on 2026-11-16 with an amended acceptance: the adaptive coordinator
stays in the kernel, a boundary rule checks that it imports no Kikan binding, and the first
real adaptive decision was accepted by its checkpoint owner. No stock executable can fund
an objective run, so the coordinator was launched by a standing policy from the
distribution (FRIC-88); the real call needed the proposal vocabulary made exact (FRIC-89)
and an admin verb un-hung (FRIC-90). No worker was dispatched. EP-6 is complete on 2026-11-16: M7 recorded the dispositions in
ADR 0130, and one `kikan-shikigami-worker` session ran all four packs and a kernel mandate
cycle for real. That session found that no real root could fund a mandate, because mandate
admission refused the unbounded cost every real root carries; by the user's decision a
supervised root may now leave cost unbounded when its active work, attempts and tokens are
finite (FRIC-93, ADR-121 amended). The core is 430 modules and 71,900 lines in 70
namespaces, down from 469, 83,611 and 73 at EP-6 M1. EP-8 is complete on 2026-11-16: M3's portability check ran
`agents/proof/portable-note.dhall` unchanged under the stock local-operator composition and
under `shikigami-worker` with the Kikan-En authority (the loopback fixture authority) and
`outputs.default=kawa.digest`. Both runs held K1 to K8 under the new `shikigami record check`,
and their kind-and-tag sequences were equal. By the user's decision M3 pulled the `kawa.digest`
output adapter forward (`Shikigami.Output.Kikan`, FRIC-94), which EP-10 moves with the other
Kikan adapters. `workspace.read` proved to be a light-command overlay only, so it is not
kernel vocabulary (FRIC-95). EP-10 M2 and M3 are accepted on 2026-11-17: the Kikan-En
authority, the five Kikan output adapters, their clients and settings, and the Danwa and
Kizashi approval channels run from `kikan-shikigami-binding`, and the Kawa and Kanmon stubs from
the distribution's admin command. The kernel registers outputs and approval channels from packs
and names no service; `sinks` left the declaration before the first freeze. Through
`kikan-shikigami-worker`, a declaration with no outputs produced exactly one Kawa digest at the
stub and an explicit `channel.egress` reached the Kanmon stub (Kizashi and Danwa against client
tests only, by the user's choice of no sibling stacks). EP-10 M4 is accepted on 2026-11-17
(`6268f9bf`): the kernel's objective tracker runtime is provider-neutral, a pack installs a
provider on `FlowPack.trackerProviders`, and the Rei provider and its real-Rei suite run from
the binding (17/17 against a disposable Rei at the pinned commit); the server composes packs
as `kikan-shikigami-server`. EP-10 M5 is accepted on 2026-11-17 (`6b7b39dc`, `f3774b9d`): the
Kawa stream and event consumers are the distribution's (`kikan-shikigami-consume-stream`,
`kikan-shikigami-consume-events`, the binding's `intake` library) and no stock package links
Kafka. By the user's decision the conversation loop stays in the kernel behind a
conversation-channel port, with Danwa as the binding's channel and the workflow renamed
`shikigami.conversation`. Against the global Redpanda, a published envelope and a Danwa
addressed message each ran end to end through the distribution. The objective continuity
scenario now composes the distribution but exposes a restart-recovery defect (FRIC-99).
EP-10 is complete on 2026-11-17 (ADR-131): the boundary check refuses any stock stanza or
source that reaches a Kikan client, an outbox delivery is recorded against its run, a
deployment-tier one-off run is composed like the worker, and the portability check passed
against the distribution. By the user's decision the record-into-evidence projection is the
attestation plan's, the qualification cohort waits for the distribution's Nix package, and
the Kikan sample declarations stay in `agents/`. EP-11 M3 is accepted on 2026-11-17: every
remaining surface is registered (14, all clean), the core compiles its modules in a private
`internal` library and exposes only the 273 a consumer imports, a check refuses a pack-owned
label in the core keiro specifications, and `docs/architecture/kernel-invariants.md` audits
K1 to K8. EP-11 M2, and M4 after it, wait on EP-7 M3 (the keiro campaign), which is the
user's call. Stage 1 (the pilot) ends at the declaration baseline, and stage 2 at
the kernel baseline.

On 2026-11-17 the user chose to unblock EP-11 M2 by slimming the playbook and running koyomi,
and EP-7 M3 is accepted. Run `aa2b77a1-04e7-5384-8398-07b7e33947e0` passed four gates the user
approved and took koyomi from keiro 0.22 to 0.25 one release edge at a time. An independent
`just check` on the result is green. Before that, FRIC-99 turned out to be a runtime-capacity
deadlock, and ADR-132 resolves it: a stopped process instance releases its permits. Getting the
campaign through on this machine cost the operator-experience gaps FRIC-100 to FRIC-115 record.
EP-11 M2 is the next step.

- [ ] Architectural acceptance: the keiro modernization campaign runs for real on at least
  two of the user's repositories with no change to `shikigami-core` in the commits that
  introduced it, and EP-5's fitness check passes.
- [x] Routine-agent acceptance: EP-9's one-file, one-command, confirm-once agent runs by
  hand and on a local schedule on this Mac. (2026-11-15: `repo-digest` by hand in keiro and
  three scheduled runs under `shikigami-local up`; `readme-keeper` committed in fsrs-hs.)
- [x] Portability acceptance: one declaration runs unchanged under the stock composition
  and the Kikan distribution, with K1 to K8 holding in both. (2026-11-16: EP-8 M3 passed
  against a Kikan composition with the fixture authority. 2026-11-17: EP-10 M6 reran it
  against the distribution: `agents/proof/portable-note.dhall` under `shikigami-agent-run`
  (local-operator, `local.report`) and `kikan-shikigami-agent-run` (contained, Kikan-En
  fixture, `kawa.digest` published by `kikan-shikigami-worker`); both records pass
  `record check`, with the same action decided and delivered.)
- [ ] Declaration baseline: the declaration, playbook, operator-file and local-command
  checks enforce.
- [ ] Kernel baseline: every remaining compatibility check enforces, and the end of the
  pre-release exception is recorded.


## Surprises & Discoveries

- Observation: A declaration whose declared tools become capability overlays needs an
  `identity`, and without one the run stopped after the grant prompt with only
  `MissingCapabilityIdentity`. It cost a rerun in EP-3 and again in EP-4 (FRIC-77, resolved:
  the local-operator composition now refuses such a declaration before the prompt and names
  the field).
  Evidence: FRIC-77; `docs/plans/129-execute-dhall-declared-playbooks-with-fan-out-approval-gates-and-learning-capture.md`.

- Observation: The persisted execution snapshot whitelists workspace providers, and a finite
  token bound reserves each attempt's output plus its whole context window. EP-2's coding-agent
  steps and EP-4's playbook steps that admit workspaces or bound tokens meet both.
  Evidence: EP-1 M2's real runs failed with `UnsupportedReplay` until the parser admitted
  `shikigami.workspace.local/1`, then with `ExecutionResourceBoundUnsupported:Tokens`; see
  EP-1's Outcomes.

- Observation: `shikigami-core` may not link `process`, so every host-process adapter the
  stock composition needs (EP-1's `git` and `mori` resolver, its M2 launcher and worktree
  commands, EP-2's coding-agent launcher, EP-3's CLI tool runner) lives in a leaf package, with
  the kernel holding only the port.
  Evidence: EP-1 M1 tripped `core links the neutral tool registry without a provider adapter`;
  see EP-1's Surprises.

- Observation: Every kernel-owned effect is already a capability-tool invocation, so EP-1's
  `LocalOperator` authority decides `UseCapability (InvokeTool …)` on `shikigami.workspace`
  for workspace reads, edits, execution and Git, not separate workspace actions. A tool name
  is a digest of the exact effect, so an operator grant must match on the capability and the
  tool-name prefix (`exec-`, `commit-`, `replace-`, …), never on the whole name.
  Evidence: EP-8 M1's conversion of `Workspace/Provider.hs`, `WorkerSession/Capability.hs` and
  `Objective/{Capability,Runtime}.hs`.
- Observation: Default parallel test execution still exhausts PostgreSQL clients and races the
  Git fixtures; suites must run one at a time at two threads.
  Evidence: EP-8 M1's first full run; FRIC-51 and FRIC-59 already record the workaround.

- Observation: Shikigami is still pre-release, so ADR-27's baseline exception lets this
  initiative replace unreleased declaration and workflow shapes directly.
  Evidence: `docs/workflow-versioning.md` records the user's 2026-10-30 confirmation that
  Shikigami is unused, and no `git tag` exists.
- Observation: MCP is designed but unimplemented.
  Evidence: ADR-65 exists, but the only `.hs` file mentioning MCP is
  `shikigami-core/test/Shikigami/PackageArchitectureSpec.hs`.
- Observation: Baikai already provides the unattended coding-agent primitive this
  initiative needs.
  Evidence: `baikai agent run <job>` in `mori://shinzui/baikai/packages/baikai-agent`.
  Shikigami excludes it from durable runs by ADR-40's qualification gate, not by any
  missing capability.
- Observation: Claude Code can enforce declared CLI tools on this Mac.
  Evidence: EP-3's drafting verified that, with Claude Code 2.1.325, both
  `--allowedTools 'Bash(mori registry show:*)'` and a PreToolUse hook passed with
  `--settings` allow `mori` and block `gh`. Codex per-run hook support is unverified. If
  Codex has none, Codex agents get only MCP tools.
- Observation: Seihou keeps only the last `seihou agent run` receipt.
  Evidence: EP-7's drafting found `blueprint :: Maybe AppliedBlueprint` in Seihou's
  manifest, so several blueprints applied to one repository overwrite each other's
  receipts. EP-7 uses a per-blueprint commit trailer as evidence and files a Seihou
  improvement request. This does not change the kernel.
- Observation: The kernel's authorization contract is Kikan-En's type, so the kernel
  cannot name its own actions.
  Evidence: `shikigami-core/src/Shikigami/Action/Authorization.hs` imports `AgentAction`
  from `Kikan.En.Action`, a closed eleven-constructor sum in
  `mori://shinzui/kikan-en/packages/kikan-en-contract`. It has no constructor for a
  declared CLI tool or a coding-agent launch. About twenty core modules take an
  `ActionAuthorizer`. The record also carries a `kawaSource` field.
- Observation: Authorization decisions are logged, not recorded.
  Evidence: `logDecision` in the same module. No table holds them, so "every action is
  remembered" is not yet true of the kernel in any tier.
- Observation: Outputs, approval channels and triggers are closed over Kikan services in
  both the schema and the dispatch code.
  Evidence: `Sink` in `shikigami-core/src/Shikigami/Agent/Decl.hs` and `SinkKind` in
  `Sink/Permission.hs`; `Sink.dispatch` is a `case` over service clients; `SinkContext`
  has one configuration field per service; `schema/Agent.dhall` requires a `Schedule`,
  `Stream` or `Event` trigger.
- Observation: Supplying the flow registry at composition moves the list, not the
  coupling.
  Evidence: `FlowDef.run` is quantified over the fixed `FlowEffects` row, and
  `runFlowBehavior` (`shikigami-core/src/Shikigami/Agent/Workflow.hs`, lines 1117 to 1230)
  hand-stacks all 18 interpreters with per-flow `patch` gates and name tests.
- Observation: `shikigami-core` has no library API boundary.
  Evidence: its Cabal file exposes 357 modules; `PackageArchitectureSpec` pins only
  `Shikigami.Sink.Auth.Internal` as hidden.
- Observation: `AgentDecl` is journaled, so a schema change is also a codec change.
  Evidence: the `lookup-agent` step returns it, and its JSON instances strip defaulted
  fields by hand to preserve journal bytes.
- Observation: The first drafts of the child plans disagreed in ways the first
  reconciliation missed.
  Evidence: EP-5 and EP-6 each defined `FlowPack` with different fields and dependency
  rules, and EP-6 named its packages `shikigami-pack-*` although EP-5 forbids the prefix.
  EP-7's playbook sketch used step shapes, an item source and outcome fields that EP-4 and
  EP-2 do not define. EP-3 capped every tool call at 600 seconds and had no path for a
  playbook `Tool` step.
- Observation: The organization cannot yet run the most capable declared behaviors.
  Evidence: EP-10's drafting found no Kikan-En action for a declared tool or a coding-agent
  launch, so the Kikan-En adapter must refuse them.
- Observation: Few Kikan services can run on this Mac.
  Evidence: EP-10's drafting found only Rei known to run locally
  (`tests/objective-trackers/run-rei.sh`), plus the Redpanda broker. Kawa and Kanmon are
  stubs. EP-10's first milestone inventories the rest, and fixture runs there are
  supporting evidence, not acceptance.
- Observation: The pack SDK each subsystem needs measures how much of a use case it is.
  Evidence: EP-6's import survey: practice review needs about 20 kernel modules, initiative
  28, the watchdog 38 and the adaptive coordinator 55, including execution, worker-session
  and objective internals.
- Observation: Writing the campaign in the real playbook format exposed two limits that
  remain. A nested playbook cannot read its parent's step outputs, and a tool argument is a
  single template word.
  Evidence: EP-7's rewritten declarations re-probe inside the nested playbook and use three
  guarded steps for the three blueprint command shapes.
- Observation: EP-11's freeze creates the local tag `api-baseline-v1`, while other plans
  use an empty `git tag --list` as evidence that the exception still holds.
  Evidence: the recheck steps in EP-5 and EP-6. After the baseline those rechecks no longer
  apply, because every change then follows `docs/workflow-versioning.md`.
- Observation (EP-2): a worker serves many runs, so per-run ports cannot come from its
  process-global `AgentRunDeps`. EP-2 resolves a coding-agent step's runner from the step's
  own input (`CodingAgentRunners`) and gives `RunJob` an optional `repository`. EP-3's tool
  hosts and EP-4's playbook steps under the worker need the same per-step resolution; the
  workspace tools are still composed only by the light commands.
  Evidence: `Shikigami.Trust.LocalOperator.Host.queuedCodingAgents` in
  `shikigami-core:local-host`; `docs/plans/127-run-claude-code-and-codex-as-durable-harness-workers-inside-agent-runs.md`,
  Decision Log, M2b.
- Observation (EP-2): a restarted worker resumes a killed worker's runs only after the old
  lease expires, about five minutes. Playbook acceptance that kills a worker should expect it.
  Evidence: EP-2 M2b run `f66d61e5-…`, killed at 18:47:36 and settled at 18:53:05.
- Observation: suites that pass alone fail or hang under parallel threads, under more than one
  child (FRIC-72 under EP-8, FRIC-75 and FRIC-76 under EP-2). FRIC-75 is fixed by a sequential
  group; the others are rerun singly. Promote if a third child meets one.
  Evidence: `docs/friction-log/72-…`, `75-…`, `76-…`.
- Observation (EP-10): `cabal build all` here builds no test suite, so `cabal list-bin` of a
  suite runs whatever binary was last built and a broken suite can look green (FRIC-98). EP-10
  M3 stage a was verified that way. Every child plan's verification should build each suite by
  name (`cabal build <pkg>:test:<suite>`) or run `cabal test`.
  Evidence: `docs/friction-log/98-cabal-build-all-leaves-test-suites-unbuilt-so-cabal-list-bin-runs-stale-test-binaries.md`.
- Observation (EP-10): a test now lives with the code it tests, because no stock package may
  depend on a pack in any stanza. Kernel suites spell outputs as raw `OutputDecl`s and use
  neutral adapters; Kikan delivery is tested in the binding's and the distribution's suites.
  A child that moves code out of the core should plan for its tests to move with it.


- Observation (EP-9): scheduled routine agents run through the light composition inside
  `shikigami-local up`, not `shikigami-worker`, because the worker composes local-operator
  ports only for coding-agent steps. EP-4 and EP-7, which planned to run under the worker,
  need per-run tier composition in the worker (tools, outputs, workspace) or the same local
  loop.
  Evidence: `docs/plans/134-declare-and-run-a-routine-agent-with-one-file-and-one-command.md`,
  Decision Log, M3.

- Observation (EP-10 M6, 2026-11-17): EP-8 M3's portability evidence went stale when EP-10
  M3 moved the Kikan outputs onto the outbox: an outbox delivery left no `output.delivered`
  in its run's record and its publish-time decision was run-less, a K3 gap no suite caught.
  The rerun against the distribution found it, and EP-10 fixed it (`5bd2c94b`). Rerun the
  portability check whenever an adapter's delivery path changes.
- Observation (EP-10 M5 and EP-6 M6): two subsystems a plan proposed to move out of the
  kernel, the conversation loop and the adaptive coordinator, ran on most of the agent-run
  runtime and had a small service edge. Both stayed kernel primitives by the user's decision,
  the conversation loop behind a channel port. Measure that dependence before planning a
  move.
- Observation (EP-10 M5): the objective continuity scenario (`tests/objective-tracking/`),
  which predates this initiative, had not run since EP-10 M2. Composed with the
  distribution, it strands its run after its injected kill (FRIC-99); the scenario is
  restart-recovery qualification, outside the initiative's scope.
  Resolved 2026-11-17: the run was not stranded but deadlocked on runtime capacity. The killed
  worker's dispatched attempt kept the only permit that its own recovery needed.
  [ADR-132](../adr/0132-a-stopped-process-instance-releases-its-runtime-permits.md) makes a
  stopped process instance release its permits, and the unmodified scenario passes at the
  default capacity of one.

## Decision Log

- Decision: EP-8 M1 declares only the two executed actions (`UseCapability`, `EmitOutput`);
  the Integration Points sketch now shows each later constructor with the plan that adds it.
  `Authority` is an abstract record with a hidden run context rather than a newtype.
  Rationale: ADR-1, and the run must be recorded on every event while the worker builds one
  authority per process. See the EP-8 Decision Log.
  Date: 2026-11-15

- Decision: Extract the kernel in place rather than rewrite, and order the work so real use
  begins early.
  Rationale: The journals, objectives, approvals, resource roots, memory and workspaces
  work and are worth keeping. The failure is that no real job ever ran through them.
  Date: 2026-11-15
- Decision: Every child's acceptance includes a real run on the user's own repositories or
  machine. Hardening for `Contained` and `MultiTenant` is out of scope, and no Linux-container
  qualification suite may be a completion gate.
  Rationale: A year of qualification-first plans produced no usable path. The user stated
  that Shikigami has never been used for a single project.
  Date: 2026-11-15
- Decision: Defer MasterPlan 21 (enrolled machine daemons; all children Not Started), and do
  not gate on MasterPlan 14 EP-6's actual-model trial.
  Rationale: Both add substrate for tiers this initiative does not need for real use. The
  real runs in EP-2 and EP-7 supply live model evidence under `LocalOperator`.
  Date: 2026-11-15
- Decision: Name the new behavior arm `CodingAgent` and the trust type `TrustTier`.
  Rationale: `AgentDecl` already has a `harness` field (the ADR-59 tool-loop policy) and a
  `sanctionedProfile` field (attestation). Reusing either word would conflate unrelated
  concepts.
  Date: 2026-11-15
- Decision: Shrinking the core moves features, it does not remove them. The only retirement
  in scope is the never-executable `Deterministic` arm. Every other supported capability
  must run for real after it moves.
  Rationale: The user asked whether supported features were being removed or only moved
  out of the kernel. The goal is a smaller kernel, not a smaller product.
  Date: 2026-11-15
- Decision: Reconcile the child drafts on 2026-11-15. EP-2 lifts the worker's refusal of
  `local-operator`. There is one action ledger. EP-2's `CompletedRun` carries
  `finalMessage` for EP-4. Pack labels are pack-owned under EP-5's prefix rule. EP-6 has no
  dependency on EP-4.
  Rationale: The seven plans were drafted in parallel against the Integration Points. These
  were the places where they assumed different names or owners. The later review entry
  below moves the ledger's ownership to EP-8 and renames it the action record.
  Date: 2026-11-15
- Decision: EP-3 supersedes the remaining MCP scope of plan 12
  (`docs/plans/12-per-agent-mcp-server-declaration-in-agent-dhall.md`). EP-3 also ships a
  small interim MCP client in `shikigami-agent`, local stdio servers only, behind a narrow
  `McpSession` record.
  Rationale: Plan 12 forbids a private downstream client and waits for Baikai's
  `mori://shinzui/baikai/okf/improvement-requests/concepts/IR-2`, which is still proposed.
  Waiting would block real use indefinitely. The narrow record lets Baikai's client replace
  the interim one when IR-2 ships. Plan 12 is updated to point here when EP-3 starts.
  Date: 2026-11-15
- Decision: The user decided four EP-7 and EP-6 questions on 2026-11-15:
  1. The campaign covers kanmon, kizashi, koyomi, danwa, keiei, meibo and jinmyaku, piloting
     on kanmon.
  2. Those repositories need no branches. EP-1 gains an operator-chosen `WorkspacePlacement`
     (`SeparateWorktree` by default, `InPlace` for these seven), and the campaign commits
     directly to each repository's current branch, with the recorded starting commit as the
     undo point.
  3. Their databases need not be preserved (`database.policy=disposable`).
  4. `agents/detectors/stalled-intention.dhall` is deleted with the `Deterministic` arm.
  Rationale: None of these services is in use, and nobody else works in them.
  Date: 2026-11-15
- Decision: The user approved the remaining three questions on 2026-11-15:
  1. Seihou blueprints may start their own Claude Code sessions (`seihou agent --batch`).
  2. EP-4 keeps proposing playbook changes on a review branch in the Shikigami repository,
     approved by merging.
  3. EP-6 deletes five unused items in its M1: the `shikigami.fired` table, the
     `ShikumiProgram.enabledBy` field, `agents/detectors/schema.dhall`,
     `agents/detectors/at-risk-customer.dhall` and the `shikigami danwa-spike` command. They
     were never supported features, so the rule that moving features never removes them
     still holds.
  Rationale: The user answered "everything is fine" when shown the three as proposed.
  Date: 2026-11-15
- Decision: Express multi-step use cases as Dhall playbooks interpreted by one generic
  kernel flow, and keep Haskell flow packs for behavior a playbook cannot express.
  Rationale: The founding goal was declaration over code. A generic interpreter is a kernel
  primitive, while each bespoke flow is a use case.
  Date: 2026-11-15
- Decision: The initiative balances three requirements, each with its own acceptance test:
  routine agents are easy to declare, Kikan's organizational requirements stay reachable,
  and the APIs and boundaries are right before wide adoption.
  Rationale: The user asked for a deep review on 2026-11-15 with these aims: a simple
  kernel for routine tasks, support for the organizational requirements of Kikan, getting
  the APIs and boundaries right before wide adoption, and using this plan to strengthen
  the APIs. The first draft had only the architectural test.
  Date: 2026-11-15
- Decision: The kernel owns its contracts for actions, the action record, outputs,
  approval channels and triggers, and the Kikan service bindings move out of
  `shikigami-core` into a binding package composed by a Kikan distribution. EP-8 and EP-10
  are added for this.
  Rationale: The user chose "ports now, adapters move out" on 2026-11-15. The first draft
  named the core's dependence on Kikan services as its fifth cause and gave it no plan.
  Date: 2026-11-15
- Decision: The pre-release exception ends at EP-11's baseline gate, not at EP-7's first
  run. Until then every run is drained to a terminal state before a shape change. This
  supersedes the earlier rule that EP-7 records the end of the exception.
  Rationale: The user chose the explicit gate on 2026-11-15. EP-5 and EP-6 still make
  breaking changes to the `AgentRun` body and the declaration codec after the campaign
  starts, and ending the exception first would force a patch for each.
  Date: 2026-11-15
- Decision: The baseline freezes in two steps. The declaration baseline freezes the agent
  declaration, the playbook format, the operator files and the stock local commands once
  the campaign has run on a second repository. The kernel baseline freezes the pack SDK,
  the ports, the durable wire, the HTTP API and the admin commands after EP-5, EP-6 and
  EP-10, and ends the pre-release exception.
  Rationale: The user chose two steps on 2026-11-15. With one gate, what the operator
  writes every day stays changeable until the core shrink and the Kikan move are done.
  Date: 2026-11-15
- Decision: A declaration that lists no output receives its composition's default output,
  resolved at admission, pinned in the journal and shown at validation and confirmation.
  Rationale: The user chose this on 2026-11-15, so that a routine agent can be promoted
  into the Kikan distribution unchanged. EP-9's first draft named `local.report` in the
  declaration, which tied every routine agent to the stock composition.
  Date: 2026-11-15
- Decision: Under `LocalOperator` the operator confirms a declaration's authority once,
  and the answer is stored against the declaration's digest. Runs without a terminal use
  only stored approvals. The approvals file remains the explicit form.
  Rationale: The user chose this on 2026-11-15. Requiring a hand-written approvals entry
  and a tools ceiling that repeats the declaration made a routine agent four files.
  Date: 2026-11-15
- Decision: Add EP-9 for the routine-agent experience and EP-11 for the API baseline.
  Rationale: Each has acceptance no other plan owns. Without EP-9, ease of declaration is
  nobody's deliverable. Without EP-11, nothing names the public surfaces or checks them.
  Date: 2026-11-15
- Decision: EP-5 owns the whole pack API, including pack-owned interpreters and a second
  SDK component, and proves it against the watchdog before any subsystem moves. Packs,
  the binding and the distribution carry no `shikigami-` prefix, and only a distribution
  package composes them. Pack labels leave the core specification with their flow.
  Rationale: EP-5 and EP-6 had defined the pack type twice and disagreed on naming,
  dependencies, composition and label ownership. A public API designed twice is the
  failure the user asked this review to prevent.
  Date: 2026-11-15
- Decision: A declared tool runs in three hosts under one decision function, and the
  durable-step host may mutate and run for hours on EP-2's attempt machinery (EP-3 M4).
  Rationale: The campaign's `seihou agent run` and `mori register` steps are long and
  mutating. The first draft gave playbook `Tool` steps no owner.
  Date: 2026-11-15
- Decision: The adaptive-delivery coordinator stays in the kernel, with its capability,
  workflow family and decision site. EP-6 no longer creates an adaptive-delivery pack, and
  the pack API's workflow-family field moves to EP-10, where the Danwa conversation
  workflow is its consumer.
  Rationale: The user decided on 2026-11-15 that it remains in the kernel if it does not
  depend on Kikan services. It does not: `Coordination/*`, `Flow/AdaptiveDelivery` and
  `Program/Decision/Adaptive` import no Kikan service module. As a pack it would have
  needed about 55 kernel modules exported, which marks it as a primitive.
  Date: 2026-11-15
- Decision: Organizational use (stage 3) waits for Kikan-En to add actions for declared
  tools and coding-agent launches. Until then those behaviors run only under the stock
  composition.
  Rationale: The user decided this on 2026-11-15. Mapping them onto an existing Kikan-En
  action would authorize something other than what runs.
  Date: 2026-11-15
- Decision: The tier composition resolves its ports per run and per repository.
  Rationale: The first draft built one runtime per command invocation for one agent and
  one repository. A worker serves many agents, and a playbook step selects its own
  repository.
  Date: 2026-11-15
- Decision: The conversation loop is a kernel primitive with a conversation-channel port, and
  Danwa is one channel in the Kikan binding (EP-10 M5). No pack contributes a workflow
  family: the `workflows` pack field the 2026-11-15 entry moved to EP-10 is not added, and
  `RunRouteKind` stays closed. `FlowPack` gains `conversationChannels` instead, and the
  workflow is renamed `shikigami.conversation` under the pre-release exception.
  Rationale: The user decided this on 2026-11-17. Like the adaptive coordinator, the
  conversation loop runs on most of the agent-run runtime and only three small pieces of it
  were Danwa's. A channel is one port, shaped like an approval channel, where moving the
  family would have added a workflow field, a route registry and timer registration for
  EP-11 to freeze.
  Date: 2026-11-17


## Outcomes & Retrospective

(To be filled during and after implementation.)

Revision note (2026-11-15): a deep review against the code and the Kikan contracts added
the three balanced requirements with their acceptance tests, the kernel invariants K1 to
K8, the public-surface inventory, kernel-owned ports, the Kikan distribution, the explicit
baseline gate and four child plans (EP-8 to EP-11). It reconciled the pack API, tool
hosts, port resolution and the campaign's playbook needs across the existing children.
