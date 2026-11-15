---
id: 127
slug: run-claude-code-and-codex-as-durable-harness-workers-inside-agent-runs
title: "Run Claude Code and Codex as durable harness workers inside agent runs"
kind: exec-plan
created_at: 2026-11-15T13:43:17Z
intention: "intention_01m7fq4tf3ejrt0tjxvsy8ejdt"
master_plan: "docs/masterplans/22-rebuild-shikigami-as-a-kernel-where-use-cases-are-declared-not-coded.md"
provenance:
  created_by:
    model: "claude-opus-5-5"
    harness: "claude-code"
    at: 2026-11-15T13:43:17Z
  revisions:
    - model: "claude-opus-5-5"
      harness: "claude-code"
      at: 2026-11-15T13:58:24Z
      mode: "other"
      note: "Drafted plan body under MasterPlan 22"
    - model: "claude-opus-5-5"
      harness: "claude-code"
      at: 2026-11-15T14:08:31Z
      mode: "update"
      note: "MasterPlan 22 reconciliation of cross-plan interfaces"
    - model: "claude-fable-5-2"
      harness: "claude-code"
      at: 2026-11-15T14:50:34Z
      mode: "update"
      note: "Cascaded MasterPlan 22 review: command-parameterized attempt machinery, skills on steps, kernel authority and record ports"
    - model: "claude-opus-5-5"
      harness: "claude-code"
      at: 2026-11-15T17:50:40Z
      mode: "implement"
      note: "M1 accepted: CodingAgent arm, durable child workflow, local-host runner, real Claude Code run on mina; ADR 0126"
---

# Run Claude Code and Codex as durable harness workers inside agent runs

This ExecPlan is a living document. The sections Progress, Surprises & Discoveries,
Decision Log, and Outcomes & Retrospective must be kept up to date as work proceeds.
If durable project context changes, update or create ADRs in docs/adr/ in the same change.
Record friction met while implementing in the friction-log bundle as it occurs (see FRICTION.md).


## Purpose / Big Picture

Today a declared Shikigami agent that has to change code gets a home-built tool loop of
at most eight model turns (`shikigami-core/src/Shikigami/Behavior/Skill.hs`). Claude Code
and Codex, the real coding tools, run only as foreground launches that the operator
watches in a terminal. After this plan an operator writes a short Dhall declaration whose
behavior is `CodingAgent`, runs it against one of their own repositories on this Mac, and
gets back a durable result. Claude Code (or Codex) did the work unattended in a Git
worktree on the run's branch. Shikigami committed the result there. One operator command
shows the outcome, the commit, the changed files and the evidence record Baikai wrote.

The run is durable. If the worker process is killed while Claude Code is still working,
the coding agent keeps running. When the worker restarts it reattaches to that same
attempt instead of starting a second one. A step that already finished is never rerun. A
step whose fate cannot be established ends as `Uncertain` and is shown to the operator
with the workspace state. It is never silently retried.

The same machinery is exposed to flow bodies as a replay-safe capability. EP-4's playbook
interpreter (`docs/plans/129-execute-dhall-declared-playbooks-with-fan-out-approval-gates-and-learning-capture.md`)
runs its coding-agent steps through it and never spawns a process itself.

A coding-agent run is one case of a more general problem: an external process that must
outlive the worker, be reattached after a restart, and end `Uncertain` rather than be
launched twice. This plan therefore builds the attempt directory, the recovery decision and
the three-step child body so that the launched command is a parameter. EP-3
(`docs/plans/128-let-agents-declare-cli-tools-and-mcp-servers-with-authority-attached-to-the-declaration.md`)
reuses that machinery in its fourth milestone to run a long, mutating declared tool as a
durable step. A step may also attach skill directories, so a coding agent working in a
target repository can read skills kept beside the declaration.


## Progress

- [x] M1 (2026-11-15): A declared `CodingAgent` agent runs Claude Code on a real repository on this
  Mac, commits on the run branch, and `shikigami runs show` prints its outcome, commit,
  changed files and evidence path. The `CodingAgent` arm and the `CodingAgentStep` child
  workflow are in the v1 baseline, the pre-release facts are rechecked and recorded, and the
  `just keiro-gate` findings are recorded. The launch is decided as `LaunchCodingAgent` by
  the tier authority and appears in the action record. A step that attaches a skill
  directory reads that skill in a real run.
  Evidence: `agents/coding-agent-example.dhall` ran under `local-operator` on
  `mori://shinzui/mina` (run `cea2a2c7-2866-5c4d-9fd1-4c2be8c99a96`): Claude Code added one
  Haddock comment and Shikigami committed it as `c94de20` on
  `shikigami/haddock-gaps/ab167062bc7b` (left for review). The run printed
  `coding-agent: coding agent completed with exit 0, commit c94de20, 1 files changed`;
  `shikigami-local ledger` shows `launch_coding_agent` approved plus
  `coding-agent.launched` and `coding-agent.settled`; `shikigami runs show --json` carries the
  `codingAgent` field with the outcome, commit, changes and an evidence summary whose
  `run_id` is the child id. The same declaration under `trust.tier=contained` ended
  `TierRefused` before any process started. A probe declaration attaching
  `agents/skills/exec-plan` (run `b0d7d1d9-b92a-5fa8-ac37-6d10813bcd87`) quoted the skill's
  title "ExecPlan Skill" from its `SKILL.md`; its unchanged branch was removed. Unit tests:
  `CodingAgent` group in `shikigami-core:test` (10 cases, checked values, the example
  declaration, the recovery table and the outcome codec).
- [ ] M2: Killing the worker mid-run and resuming reattaches to the surviving attempt and
  completes without a second launch. Resuming a completed run reads the journal without
  launching. An attempt whose launcher died without a result ends `Uncertain` and is
  reported. Shown on a real repository and by the recovery tests. The attempt machinery
  takes its command as a parameter, proven by a test that drives it with a plain shell
  command; this milestone is the named prerequisite of EP-3 M4.
- [ ] M2b: `shikigami-worker` accepts the `local-operator` tier, lifting EP-1's interim
  refusal. A `CodingAgent` run queued with `shikigami enqueue-run` is executed by a
  `shikigami-worker` started on this Mac. Killing the worker by its saved PID and starting
  it again resumes the run exactly as `--resume` does in M2. EP-4 and EP-7 run playbooks
  under this worker (MasterPlan 22 Decision Log, 2026-11-15).
- [ ] M3: The same declaration shape runs Codex on a real repository. A flow body calls
  the capability twice under two keys and replays without relaunching. The new ADR
  amending ADR-40 is accepted, and the operations runbook documents the durable path.


## Surprises & Discoveries

- Observation: Baikai cannot resume an interrupted coding-agent session, so recovery cannot
  be "resume the recorded session".
  Evidence: `AgentRunRequest` in `baikai/src/Baikai/Agent.hs` (Baikai 0.10.1.1) has no
  session field. The Claude renderer adds `--no-session-persistence` and the Codex renderer
  adds `--ephemeral` by default. The session or thread id appears only in the evidence
  record built *after* the process exits (`observeToolOutput` in
  `baikai-agent/src/Baikai/Agent/Run.hs`). A worker killed mid-run therefore never holds a
  session id to resume.
- Observation: The coding agent outlives its parent. Baikai spawns it with
  `create_group = True`, in its own process group, so killing the parent does not reach
  it. Baikai's CLI writes the evidence file and then its JSON envelope only after the agent
  exits (`execute` in `baikai-agent/src/Baikai/Agent/Cli.hs`). This plan's recovery design
  rests on that ordering.
- Observation: Every existing flow capability (`Workers`, `Delegate`, `Routing`, …) is a
  member of `FlowEffects` in `shikigami-core/src/Shikigami/Flow.hs`. See the Decision Log
  for what that means for this capability.


- Observation: Claude Code's `--output-format json` with Baikai's capture is an array of
  stream events, not one object; the final message is the `result` of the last event whose
  `type` is `result`.
  Evidence: the first real run printed the whole event array as the run's reply;
  `finalMessageOf` in `shikigami-core/local-host/Shikigami/CodingAgent/Local.hs` now reads the
  last `result` event, and the skill-probe run's reply is the agent's own sentence.
- Observation: The launched Claude Code uses the operator's whole Claude configuration,
  including their MCP servers and tools. That is the operator's own authority, as ADR 0126
  states for `local-operator`, and one more reason the gate stays closed for other tiers.
  Evidence: the `init` event of run `cea2a2c7-…` lists the operator's MCP tools.
- Observation: The worktree must be opened on the parent run, not the child. A step keyed
  by the child id would open a second worktree, so the coding agent's commit would not be on
  the branch the rest of the run (and `runs show`) reports.
  Evidence: `admit` in `Shikigami.CodingAgent.Local` opens `openRunWorktree` with the parent id.
- Observation: The foreground `shikigami-agent-run` has no resume worker, so a parent that
  spawns the child suspends on `awaitChild` and nothing drives the child.
  Evidence: the first coding-agent run ended `Suspended`. The command now drives the child
  with `runChildWorkflow` when the parent suspends on it, then re-runs the parent.

## Decision Log

- Decision: Run the coding agent through the mounted Baikai CLI
  (`shikigami-agent-launch unattended agent run … --json`) as a child process in its own
  process group, with its standard output sent to a file in a per-attempt directory. Do not
  call `Baikai.Agent.Run.runAgentCommand` in-process.
  Rationale: The in-process call loses the result when the worker dies, because the
  outcome lives only in the dead process's memory. A launcher writing to files keeps
  running, finishes under Baikai's own deadline and output bounds, and leaves a complete
  envelope and evidence record for the restarted worker to collect. This also follows ADR-40's
  rule that unattended runs keep Baikai's loader, operator ceiling, bounded runner and exit
  codes, with no copied process engine.
  Date: 2026-11-15
- Decision: Recovery reattaches to the recorded attempt or reports `Uncertain`. It never
  resumes a vendor session and never launches a second attempt automatically.
  Rationale: Session resume is unavailable (see Surprises). A second launch on a worktree
  that an orphaned first attempt may still be editing would interleave two writers. ADR-60
  already forbids redispatching an uncertain effect merely because ownership changed.
  Date: 2026-11-15
- Decision: Each coding-agent call is a keyed child workflow, `shikigami.coding-agent-step`,
  whose body has three static steps (`admit`, `attempt`, `settle`). The parent agent-run body
  declares one `child coding-agent` entry, as it does for `delegate`.
  Rationale: Step labels must be static wire words for `just keiro-diff` to gate them
  (`docs/workflow-versioning.md`, "Undeclarable label families"). Per-key step labels in the
  parent would form an undeclarable family. A child keyed by call site gives EP-4 any
  number of calls with fixed labels.
  Date: 2026-11-15
- Decision: The `CodingAgent` capability is added to `FlowEffects` as a dynamic effect with
  no `IOE` or `Store` in the flow body. This is how `Workers` and `Delegate` were added.
  Rationale: `FlowDef.run` is quantified over `FlowEffects es`, so a flow cannot request an
  effect outside it. The MasterPlan's wording "a capability, not a new `FlowEffects`
  member" conflicts with the code. Its intent, no ambient effect, is what ADR-13 protects,
  and this design keeps it. This conflict is reported to the MasterPlan.
  Date: 2026-11-15
- Decision: Shikigami commits only on `Completed`, for any exit code. On `TimedOut` and
  `Uncertain` it leaves the worktree untouched and reports a summary of the uncommitted
  changes.
  Rationale: A commit on the run branch claims to be a result. Partial work from a killed or
  timed-out agent must stay visibly partial for the operator to inspect.
  Date: 2026-11-15
- Decision: The process-spawning runner lives in the light `shikigami-agent` package
  (`Shikigami.Agent.CodingAgent.Local`). `shikigami-core` holds only the types, the effect,
  the child workflow and the runner interface record.
  Rationale: `shikigami-agent` already links `baikai-agent` and owns launches (ADR-3,
  ADR-40), and `shikigami-core` has no `process` dependency. If EP-1 runs `LocalOperator`
  agents from `shikigami-worker` rather than `shikigami-agent-run`, move this one module to
  the package that composes `LocalOperator` and record the move here.
  Date: 2026-11-15
- Decision: The attempt machinery is command-parameterized. The attempt directory layout,
  the facts read from it, `recoverAttempt`, the spawn-in-own-group and reattach code, and
  the `admit`, `attempt`, `settle` body live in `Shikigami.Process.Attempt` and take the
  command to launch and a parser for its result file. The coding-agent runner is its first
  instance.
  Rationale: MasterPlan 22's review of 2026-11-15 found that EP-3's playbook `Tool` steps
  (`seihou agent run --batch` runs for an hour and mutates) need exactly this recovery
  behavior, and had no owner for it. Building it once here costs a type parameter; building
  it twice would give two recovery policies. No coding-agent acceptance changes.
  Date: 2026-11-15
- Decision: `CodingAgentStep` carries `skills`, a list of skill directories. The runner
  copies each into the attempt directory and names the copies in Baikai's `extra-dirs` job
  key, and the prompt preamble lists them.
  Rationale: The agent works in the target repository and cannot see skills kept beside a
  declaration or playbook; EP-7's campaign needs its four skills in every target. Checked
  on 2026-11-15: Claude Code 2.1.325 and Codex 0.169.0 both accept `--add-dir`, and Baikai
  maps `extra-dirs` to it (`baikai-agent/src/Baikai/Agent/Config.hs`,
  `baikai/src/Baikai/Agent.hs` in `mori://shinzui/baikai`). For Codex `--add-dir` grants
  write access, which is why the runner passes a per-attempt copy and never the original.
  Date: 2026-11-15
- Decision: The launch is authorized as `LaunchCodingAgent` on the kernel's own `Action`
  type and recorded through the action record under kinds this plan owns
  (`coding-agent.launched`, `coding-agent.settled`). The runner is obtained from
  `TierComposition.resolve`, not from a per-invocation runtime.
  Rationale: MasterPlan 22's review moved authority and the record to EP-8's kernel ports
  and made port resolution per run and repository (EP-1). Kikan-En's `AgentAction` has no
  constructor for a coding-agent launch.
  Date: 2026-11-15
- Decision: This plan lifts EP-1's interim refusal of `local-operator` in `shikigami-worker`
  (milestone M2b).
  Rationale: The MasterPlan reconciliation on 2026-11-15 found that EP-4's playbooks and
  EP-7's campaign run under `shikigami-worker`, because they span hours and human approvals.
  EP-1 deferred the worker decision to this plan. The runner module may therefore need to
  live where both `shikigami-agent-run` and `shikigami-worker` can compose it. Record its
  final package here when M2b lands.
  Date: 2026-11-15


- Decision: The runner lives in `shikigami-core:local-host`
  (`Shikigami.CodingAgent.Local`), not `shikigami-agent`.
  Rationale: ADR 0125 put EP-1's host adapters there so that `shikigami-worker` (M2b) can
  compose them without depending on `shikigami-agent`. This resolves the earlier decision's
  "move this one module" clause before the move was needed.
  Date: 2026-11-15
- Decision: In M1 an attached skill's `SKILL.md` is inlined into the prompt (at most 32 KiB
  per skill) after the skill directory is copied into the attempt directory; Baikai's
  `extra-dirs` is not set yet.
  Rationale: Inlining gives the agent the skill regardless of each vendor's directory
  permissions and grants Codex no write access to the copy. A skill's supporting files are
  therefore not reachable in M1. M3 decides `extra-dirs` with Codex, where `--add-dir`
  grants write access.
  Date: 2026-11-15
- Decision: Workflow ids in the coding-agent values are `Text` (`parent`, `child`), and the
  foreground driver computes the child id with generation 0.
  Rationale: keiro's `WorkflowId` has no JSON instances, and the foreground command always
  runs generation 0 of a fresh run. The worker path (M2b) derives the generation from the
  workflow as `runCodingAgentChild` does.
  Date: 2026-11-15
- Decision: The local-operator authority approves `LaunchCodingAgent` only when the target
  repository is the granted repository; the grant prompt names the provider and access.
  Kikan-En maps the action to `NoKikanAction` and so refuses it.
  Rationale: The grant digest covers the declaration and repository; a launch elsewhere is
  outside what the operator confirmed.
  Date: 2026-11-15
- Decision: A `CodingAgent` declaration does not bound tokens; Shikigami does not translate
  the vendor's token use into the execution resource bounds.
  Rationale: The vendor CLI owns its model loop and reports no enforceable token ceiling; the
  deadline is the enforced bound (ADR 0040 forbids substituting an unsupported option).
  Date: 2026-11-15
- Decision: Pre-release recheck, 2026-11-15, before adding `child coding-agent` to the
  agent-run body. (1) No resumable workflow journal must survive: the only journals are the
  developer database's and this session's disposable runs. (2) No queued or stored payload
  needs an old codec. (3) There are no external wire consumers. (4) There is no release or
  deployment: `git tag` prints nothing. ADR 0027's exception therefore applies: the new entry
  replaces the unreleased baseline without a patch id. `just keiro-gate` reports the expected
  `WorkflowBodyChanged` for `shikigami.agent-run`, recorded in
  `docs/evidence/plan-127/keiro-diff.txt`.
  Date: 2026-11-15

## Outcomes & Retrospective

(To be filled during and after implementation.)


## Context and Orientation

Read this section as a newcomer. It describes the code and the terms this plan relies on.

**Agent declarations.** An agent is a Dhall file such as `agents/triage-note.dhall`, typed
by `schema/Agent.dhall` and decoded into `AgentDecl` in
`shikigami-core/src/Shikigami/Agent/Decl.hs`. The `behavior` field is a closed union:
`Deterministic`, `ShikumiProgram`, `Skill`, `CoordinatingSkill` and `Flow`. This plan adds
`CodingAgent`. The existing `harness` field is unrelated: it is the ADR-59 model tool-loop
policy. The new arm deliberately does not reuse that word.

**Agent runs are durable workflows.** A *durable workflow* is a keiro function whose every
side effect is wrapped in a named *step*. Each step's result is appended to a *journal*.
After a crash the function runs again from the top, and completed steps are answered from
the journal instead of re-executed. A step is at-least-once at its boundary: if the process
dies inside a step body, that body runs again on resume. The agent-run workflow is
`agentRunWorkflow` in `shikigami-core/src/Shikigami/Agent/Workflow.hs`. Its steps are
declared in `domain/shikigami/agent-run.keiro`. Behavior dispatch happens in
`runSessionedAgent` (around line 690). That is where `Skill`, `Flow` and the others branch,
after the `open-session` and `recall` steps. A *child workflow* is a separate workflow the
parent starts and awaits. Its result is journaled in the parent. Precedents are
`child execution` and `child delegate` in `agent-run.keiro`. The keyed delegate capability
is in `shikigami-core/src/Shikigami/Flow/Delegate.hs`.

**Flows and capabilities.** A `Flow` behavior names a compiled `FlowDef`. Its body is
written against `FlowEffects` (`shikigami-core/src/Shikigami/Flow.hs`), which grants no
`IOE` or `Store`. Every way a flow reaches the world is a dynamic effect whose interpreter
journals the call, for example `Memory` in `shikigami-core/src/Shikigami/Flow/Capability.hs`
and `Workers` in `shikigami-core/src/Shikigami/Flow/Workers.hs`. The interpreters are stacked
in `runFlowBehavior` in `Shikigami/Agent/Workflow.hs`.

**Baikai's unattended runs.** Baikai (`mori://shinzui/baikai`, package
`mori://shinzui/baikai/packages/baikai-agent`, currently 0.10.1.1, guide
`docs/user/unattended-agent-runs.md` in that repository) runs Claude Code or Codex without a
terminal. A *job* (provider, working directory, capability, timeout, output mode) is
resolved from a repository-scope KDL file (`--config PATH`) and bounded by the operator's
*ceiling* in `~/.config/baikai/agents.kdl`. With no operator file, the default ceiling
permits `read-only` and `edit-workspace` and refuses `full-access`. The capability maps to
Claude's `--permission-mode plan|acceptEdits|bypassPermissions` and to Codex's
`--sandbox read-only|workspace-write|danger-full-access`. The prompt is passed on standard
input. Under `output "capture"` and `output-format "json"`, the `--json` envelope carries
`outcome`, `exitCode`, bounded captured streams and an `evidence` object. `--evidence-file`
writes the same evidence atomically, and `--run-id` labels it. Exit codes: the agent's own
code passes through, `64` usage, `69` unstartable, `75` timed out (Baikai interrupts, then
terminates, then kills the whole process group), `77` refused by policy, `78`
misconfigured. Evidence has no `FromJSON` instance by design. Read it as a JSON `Value`
and match on `schema_version`. In Shikigami, `shikigami-agent-launch unattended …` mounts
Baikai's whole parser (`shikigami-agent/src/Shikigami/Agent/Command/Launch.hs`). The
runbook is `docs/operations/baikai-execution.md`.

**The `LocalOperator` tier (from EP-1).** EP-1
(`docs/plans/126-run-declared-agents-on-the-operator-s-own-machine-through-a-local-operator-trust-tier.md`)
defines `data TrustTier = LocalOperator | Contained | MultiTenant` and
`TierComposition { tier, resolve :: RunSubject -> IO (Either TierRefusal TierRuntime) }`,
which resolves the ports for one run and one repository. `TierRuntime` holds the authority,
the action record, the capability runtime, the workspace host and the process launcher. Its
`LocalOperator` workspace provider gives a run a Git worktree of a real checkout on a run
branch, identified by run and repository, or the checkout itself for a repository the
operator marked `InPlace`. Under `LocalOperator` the operator grants a declaration once,
and runs without a terminal use only stored grants. This plan adds one field to
`TierRuntime` and consumes the workspace, the authority and the record. The exact names are
EP-1's. Where this plan writes `TierRuntime`, `LocalWorkspace`, `worktreePath`, `runBranch`
and `baseCommit`, use whatever EP-1 landed, and record the mapping in the Decision Log.

**The kernel authority and record (from EP-8 M1).** EP-8
(`docs/plans/133-give-the-kernel-its-own-action-record-output-approval-and-trigger-contracts-with-local-adapters.md`)
owns `Shikigami.Authority`, whose closed `Action` sum is the kernel's own vocabulary and
whose `Authority {decide :: Principal -> Action -> IO (Either AuthorityFailure Decision)}`
is the one port that decides an external action immediately before it happens. It also
owns `Shikigami.Record.ActionRecord`, an append-only record of `RecordEntry {kind,
payload}` values where each producer owns its dotted kind. A plan that adds a kernel effect
adds its `Action` constructor in the same change; this plan adds or fills
`LaunchCodingAgent !CodingAgentTarget`.

Relevant ADRs. [ADR-13](../adr/0013-flow-bodies-reach-the-world-only-through-capabilities.md)
says a flow body reaches the world only through replay-safe capabilities and holds no
ambient IO. [ADR-40](../adr/0040-response-options-and-foreground-launches-have-separate-authority.md)
keeps foreground launches separate, mounts Baikai's whole parser for unattended commands,
and requires a batch adapter to prove descendant cancellation, enforced deadlines, bounded
output and reporter confinement before it becomes background behavior. This plan amends
that gate by tier. [ADR-27](../adr/0027-the-first-release-establishes-one-clean-durable-baseline.md)
and `docs/workflow-versioning.md` let an unreleased declaration or workflow shape be
replaced directly, provided the owning plan rechecks the four unused-state facts and
records the `keiro-diff` findings.
[ADR-57](../adr/0057-skill-parents-admit-frozen-assignments-and-await-execution-children.md)
has the parent freeze an admission and await a child, which is the shape used here.
[ADR-59](../adr/0059-harness-policy-is-frozen-at-admission-and-shared-with-ephemeral-execution.md)
defines the unrelated `harness` field.
[ADR-60](../adr/0060-safe-recovery-spends-new-attempts-and-retains-independent-receipts.md)
forbids redispatching an uncertain effect merely because a claim expired.
[ADR-3](../adr/0003-a-seventh-package-keeps-one-off-agent-runs-light.md) puts one-off and
launch commands in `shikigami-agent`.
[ADR-80](../adr/0080-opaque-checked-values-do-not-expose-generic-construction.md) and
[ADR-87](../adr/0087-agent-values-retain-checked-meaning-and-separate-compatibility-scopes.md)
give checked values private representations, explicit parsers and no `Generic`
construction. [ADR-112](../adr/0112-observed-content-is-evidence-and-never-instruction.md)
treats repository and trigger content as evidence, never instruction.

Haskell records follow `mori://shinzui/haskell-jitsurei/docs/core-record-patterns`: strict
fields named without type or constructor prefixes, relying on `DuplicateRecordFields`.


## Plan of Work

### Milestone 1 — a declared coding agent changes a real repository

At the end of this milestone an operator runs a `CodingAgent` declaration with Claude Code
against a real checkout on this Mac. They see a commit on the run branch, and
`shikigami runs show` shows what happened.

*Types* (new module `shikigami-core/src/Shikigami/CodingAgent/Types.hs`). The checked values
follow ADR-80. Each has a private constructor, a parser returning `Either Text`, a
`FromDhall` that calls the parser, and a codec that re-checks on decode.

```haskell
data CodingAgentProvider = ClaudeCode | Codex
data WorkspaceAccess = ReadOnly | EditWorkspace | FullAccess
-- No None/Minimal: Claude would silently raise them to Low (ADR-40 forbids substitution).
data CodingAgentEffort = EffortLow | EffortMedium | EffortHigh | EffortXHigh | EffortMax

newtype CodingAgentPrompt = CodingAgentPrompt Text   -- nonblank, at most 64 KiB UTF-8
mkCodingAgentPrompt :: Text -> Either Text CodingAgentPrompt
newtype DeadlineMinutes = DeadlineMinutes Natural    -- 1 .. 720
mkDeadlineMinutes :: Natural -> Either Text DeadlineMinutes
newtype VendorModelId = VendorModelId Text           -- nonblank; absent means vendor default
mkVendorModelId :: Text -> Either Text VendorModelId

-- What a caller asks for. The flow body or the declaration supplies it.
data CodingAgentStep = CodingAgentStep
  { provider :: !CodingAgentProvider,
    prompt :: !CodingAgentPrompt,
    access :: !WorkspaceAccess,
    model :: !(Maybe VendorModelId),
    effort :: !(Maybe CodingAgentEffort),
    deadlineMinutes :: !DeadlineMinutes,
    workspace :: !CodingAgentWorkspace,
    skills :: ![SkillDirectory]        -- each holds a SKILL.md; made readable to the vendor tool
  }

newtype SkillDirectory = SkillDirectory FilePath   -- mkSkillDirectory: resolved against the declaration
                                                   -- file, must contain SKILL.md, at most 8 per step

-- RunWorkspace is the run's own LocalOperator worktree. EP-4 adds a repository
-- selector constructor for fan-out when it needs one.
data CodingAgentWorkspace = RunWorkspace

-- What admission froze and journaled. This is the contract's full input.
data CodingAgentAdmission = CodingAgentAdmission
  { step :: !CodingAgentStep,
    worktree :: !WorktreeRef,          -- path, branch and base commit, from EP-1's provider
    tools :: !ResolvedToolSet,         -- the slot EP-3 fills; noDeclaredTools for now
    deadline :: !UTCTime,              -- absolute: admittedAt + deadlineMinutes
    attemptDirectory :: !AttemptDirectory
  }

data CodingAgentOutcome
  = Completed !CompletedRun
  | Failed !FailureReason
  | TimedOut !PartialRun
  | Uncertain !UncertainRun

data CompletedRun = CompletedRun
  {exit :: !AgentExitCode, changes :: !ChangeSummary, result :: !ResultCommit,
   finalMessage :: !BoundedText,     -- the agent's last message, at most 16 KiB; EP-4's Reflect step reads it
   evidence :: !EvidenceSummary}
data ResultCommit = Unchanged !GitObject | Committed !GitObject   -- never a Maybe
data PartialRun = PartialRun {limit :: !DeadlineMinutes, uncommitted :: !ChangeSummary, evidence :: !EvidenceSummary}
data UncertainRun = UncertainRun {reason :: !UncertainReason, uncommitted :: !ChangeSummary, launcher :: !(Maybe LaunchRecord)}
data UncertainReason = IntentWithoutLaunch | LauncherGoneWithoutResult | UnreadableResult | LauncherOverran
data FailureReason
  = RefusedByCeiling !BoundedText    -- Baikai exit 77
  | Unstartable !BoundedText         -- exit 69, or the launcher itself missing
  | Misconfigured !BoundedText       -- exit 64 or 78
  | DeadlineBeforeLaunch
  | TierRefused !BoundedText         -- Contained or MultiTenant (ADR-40 gate)
  | WorkspaceUnavailable !BoundedText

data ChangeSummary = ChangeSummary {files :: ![ChangedFile], omitted :: !Natural}   -- at most 200 files listed
data ChangedFile = ChangedFile {path :: !(WorkspaceCoordinate "relative-path"), change :: !FileChange}
data FileChange = Added | Modified | Deleted | Renamed
data EvidenceSummary = EvidenceSummary
  {file :: !FilePath, digest :: !(ExecutionDigest "coding-agent-evidence"), strength :: !Text, session :: !(Maybe Text), reportedModel :: !(Maybe Text)}
```

`CodingAgentTarget`, the payload of the `LaunchCodingAgent` action, names the provider, the
access level and the repository, which is everything the operator's grant is checked
against. `GitObject` stands for `WorkspaceCoordinate "git-object"` from
`shikigami-core/src/Shikigami/Workspace/GitTypes.hs`. Reuse it instead of adding another
commit type. `ResolvedToolSet` and `noDeclaredTools` go in a new module,
`shikigami-core/src/Shikigami/Tool/Resolved.hs`, which EP-3 takes over and extends. Create
it with only an empty sealed value and a read view. If EP-3 has already landed, import its
type instead. Only bounded summaries are journaled. The full envelope, evidence and
captured streams stay in the attempt directory, referenced by path and digest.

*Declaration arm.* In `schema/Agent.dhall`, add three unions:
`CodingAgentProvider = < ClaudeCode | Codex >`,
`WorkspaceAccess = < ReadOnly | EditWorkspace | FullAccess >` and
`CodingAgentEffort = < EffortLow | EffortMedium | EffortHigh | EffortXHigh | EffortMax >`.
Add the arm `CodingAgent : { provider, prompt : Text, access, model : Optional Text,
effort : Optional CodingAgentEffort, deadlineMinutes : Natural, skills : List Text }` and
export the new unions. `AgentDecl` is journaled by the `lookup-agent` step, and its JSON
instances strip defaulted fields by hand; give the new arm a codec round-trip test. Adding a union alternative leaves every checked-in manifest loading unchanged.
Mirror the arm in `Behavior` in `Shikigami/Agent/Decl.hs` with the checked field types
above. The decoded arm becomes a `CodingAgentStep` with `workspace = RunWorkspace`. GHC's
incomplete-pattern warnings then list every behavior switch to update:
`behaviorKindText` in `Shikigami/Agent/Run.hs`; `durableSkill`, `usesDefaultModel` (the arm
uses no Baikai HTTP model, so `False`) and `behaviorEnvForProfile` in
`Shikigami/Agent/Workflow.hs`; `runBehavior` in `Shikigami/Behavior/Run.hs`, where the
database-free command refuses with "CodingAgent runs only as a durable agent run"; and
`shikigami-server/src/Shikigami/Server/Command/Validate.hs`. Add
`agents/coding-agent-example.dhall` plus a prompt file next to it, and document the arm in
`docs/user/behaviors.md`.

*Child workflow.* Add `domain/shikigami/coding-agent.keiro`:

```text
workflow CodingAgentStep
  name "shikigami.coding-agent-step"
  in CodingAgentStepInput
  out CodingAgentOutcome
  id from input via codingAgentStepWorkflowId
  body
    step admit -> CodingAgentAdmissionResult
    step attempt -> CodingAgentAttemptResult
    step settle -> CodingAgentOutcome
```

In `domain/shikigami/agent-run.keiro`, add
`child coding-agent id input via codingAgentStepWorkflowId -> CodingAgentOutcome` next to
`child delegate`. `CodingAgentStepInput` carries the parent workflow id, the generation,
the call-site key (`DeclarationCoordinate "coding-agent-key"`), the run identity and the
`CodingAgentStep`. `codingAgentStepWorkflowId` derives the child id from the parent id,
generation and key, using the structured-coordinate style of ADR-86. Run
`just keiro-scaffold` to generate `shikigami-core/src/Shikigami/CodingAgentStep/Generated/`.
Implement the body in `shikigami-core/src/Shikigami/CodingAgent/Workflow.hs` and register it
wherever `agentRunRegistry` registers the execution and delegate children. The three step
bodies call the tier's runner:

```haskell
-- New field on EP-1's TierRuntime, so it is resolved per run and repository.
data CodingAgentRunner = CodingAgentRunner
  { admit :: CodingAgentStepInput -> IO (Either FailureReason CodingAgentAdmission),
    attempt :: CodingAgentAdmission -> IO AttemptResult,    -- must be idempotent (see M2)
    settle :: CodingAgentAdmission -> AttemptResult -> IO CodingAgentOutcome
  }

refusingCodingAgentRunner :: Text -> CodingAgentRunner   -- Contained, MultiTenant
```

`Contained` and `MultiTenant` get `refusingCodingAgentRunner`. Its `admit` returns
`TierRefused` with ADR-40's qualification wording, so existing tiers behave as before.

The three step bodies are not written for coding agents alone. Put the shared shape in
`shikigami-core/src/Shikigami/Process/Attempt.hs` (a new kernel root `Process`, listed in
`tools/style/module-ownership.json`):

```haskell
-- What to launch. The coding-agent runner builds one; EP-3 M4 builds one for a declared tool.
data AttemptCommand = AttemptCommand
  { program :: !FilePath, arguments :: ![Text], directory :: !FilePath
  , resultFile :: !FilePath            -- written atomically by the launched process when it exits
  , stderrFile :: !FilePath, deadline :: !UTCTime }

-- The three journaled steps of one durable external process attempt.
data AttemptHandlers input admission result outcome = AttemptHandlers
  { admit :: input -> IO (Either outcome admission)
  , command :: admission -> IO AttemptCommand          -- also writes the attempt's input files
  , parseResult :: ByteString -> Either Text result    -- the result file's contents
  , settle :: admission -> AttemptResult result -> IO outcome }

attemptBody ::
  (Workflow :> es, IOE :> es, ToJSON admission, FromJSON admission, ToJSON outcome, FromJSON outcome) =>
  AttemptHandlers input admission result outcome -> input -> Eff es outcome
  -- runs the static steps admit, attempt, settle; `attempt` is the restart-safe launch of M2
```

`CodingAgentRunner` is the `AttemptHandlers` instance for coding agents, with Baikai's JSON
envelope as its result file. The keyed child `shikigami.coding-agent-step` calls
`attemptBody` with it. A second family that reuses the body declares its own three static
labels in its own `.keiro` file, as keiro requires typed inputs and outputs per family.

*Capability.* Add `shikigami-core/src/Shikigami/Flow/CodingAgent.hs`:

```haskell
data CodingAgent :: Effect where
  RunCodingAgent :: DeclarationCoordinate "coding-agent-key" -> CodingAgentStep -> CodingAgent m CodingAgentOutcome

codingAgent :: (CodingAgent :> es) => DeclarationCoordinate "coding-agent-key" -> CodingAgentStep -> Eff es CodingAgentOutcome
runCodingAgentCapability :: (Workflow :> es, Store :> es, IOE :> es) => CodingAgentEnv -> Eff (CodingAgent : es) a -> Eff es a
```

The interpreter starts or awaits the keyed child. A replay returns the journaled child
result. Add `CodingAgent :> es` to `FlowEffects`, and add the interpreter to the stack in
`runFlowBehavior`. In `runSessionedAgent`, add a `CodingAgent` branch that runs the same
interpreter around one `codingAgent "behavior" step` call. That way the arm and the flow
capability share one implementation. `Completed` with exit code 0 goes to
`finishSuccessfulRun`, so memory, sinks and session completion keep their existing owners.
Every other outcome goes to `finishRunFailure` with the rendered outcome. The outcome itself
stays readable from the child either way.

*Local runner.* Add `shikigami-agent/src/Shikigami/Agent/CodingAgent/Local.hs` with
`localCodingAgentRunner :: LocalCodingAgentConfig -> TierRuntime -> CodingAgentRunner`. Its
`admit` step does five things. It asks the resolved authority to decide
`LaunchCodingAgent` (provider, access, repository); extend EP-1's `decideLocalAction` so
that a grant covering the repository and the declaration's `CodingAgent` arm approves it,
and so that the confirmation EP-1 shows the operator lists the provider and access level.
The decision is appended to the action record by the authority itself. It takes the run's
worktree from the resolved workspace host. It fixes the absolute deadline. It chooses the
attempt directory `<local state root>/attempts/<child-workflow-id>/`, which must lie
outside the worktree. It copies each of the step's skill directories to
`<attempt>/skills/<name>/`, refusing a directory without `SKILL.md`, a symlink that leaves
the directory, or more than 2 MiB in total. Its `attempt` step writes three files into the attempt
directory: `job.kdl` (the job `shikigami-step` with `working-dir "."`, `output "capture"`,
`output-format "json"`, `output-limit` of 1 MiB per stream, `timeout` equal to the seconds
left before the deadline, and the mapped capability, effort and model), `prompt.md` and
`intent.json`. When the step has skills, `job.kdl` also carries `extra-dirs` naming the
copies under `<attempt>/skills/`, which Baikai renders as `--add-dir` for either vendor
tool. The prompt is the declaration's prompt, followed by a fixed preamble that names the
worktree, says not to push, and lists each attached skill by name and absolute path with
the instruction to read its `SKILL.md` before starting, followed by the trigger payload as
a quoted JSON block (ADR-112). Before relying on `extra-dirs`, confirm in a scratch run
that Claude Code under `--permission-mode acceptEdits` reads a file in an added directory
without a prompt; if it does not, record that and inline each `SKILL.md` into the prompt
instead, within the 64 KiB bound. The step then spawns this command in a new process group, with the
worktree as its working directory and standard output and error redirected to
`envelope.json` and `stderr.log` in the attempt directory:

```bash
shikigami-agent-launch unattended agent run shikigami-step \
  --config <attempt>/job.kdl --prompt-file <attempt>/prompt.md \
  --run-id <child-workflow-id> --evidence-file <attempt>/evidence.json --json
```

The step then writes `launch.json`, containing the pid and the process start time, and
waits. `LocalCodingAgentConfig` holds the launcher path, which defaults to the
`shikigami-agent-launch` next to the running executable. `settle` reads the envelope. Exit
`75` becomes `TimedOut`. Exits `64`, `69`, `77` and `78` with `outcome` other than `ran`
become `Failed`. Otherwise the run is `Completed`. For `Completed`, `settle` runs
`git add -A` and then `git commit` in the worktree, but only when `git status --porcelain`
is non-empty. The commit uses the operator's own Git identity and the message
`shikigami(<agent>): coding-agent <key>`. `settle` then computes the change summary from
`git diff --name-status -z <base>..HEAD` and returns `Committed` with the new head, or
`Unchanged` with the base. If EP-1's `LocalOperator` workspace already exposes Git helpers,
use those instead of calling `git` directly. A re-executed `settle` is idempotent: once the
commit has landed, the tree is clean, so the same summary and head are derived again. Log
`coding-agent.admitted`, `coding-agent.launched`, `coding-agent.settled` (with outcome,
exit code, short commit and file count) and `coding-agent.uncertain` through
`Shikigami.Log`. Also append two entries to the action record through the resolved
`ActionRecord`, under kinds this plan owns: `coding-agent.launched` (provider, access,
attempt directory, launcher pid) when the launch record is written, and
`coding-agent.settled` (outcome, exit code, commit, changed-file count) from `settle`. A
re-executed step appends again; key each entry by the child workflow id so the reader shows
one line per attempt. The payloads never contain the prompt or captured output.

*Operator view.* Add `shikigami-core/src/Shikigami/CodingAgent/Inspect.hs` with
`codingAgentInspection :: Map Text Value -> Maybe Value`. It reads the journaled `admit` and
`settle` results of a `CodingAgentStep` journal, or the parent's `coding-agent` child
result. Use it from `runRunsShow` in `shikigami-server/src/Shikigami/Server/Command/Runs.hs`
(a `codingAgent` JSON field plus text lines, next to `execution`) and from the final report
of `shikigami-agent-run`. Use `docs/user/log.md` to decide whether a user-log entry is
needed.

*Pre-release recheck and gate.* Before the workflow change, recheck and record in this
plan's Decision Log the four ADR-27 facts. They are: no resumable workflow journals that
must survive, no queued or stored payloads needing an old codec, no external wire
consumers, and no release or deployment (`git tag` is empty). If any fact has become false,
for example because EP-7 has deployed, stop. Instead, wrap the new `child coding-agent`
entry in a `patch shikigami-coding-agent-v1 { … }` block and follow
`docs/workflow-versioning.md`, "Registering a patch id". Run `just keiro-gate` against the
merge base. Expect a `WorkflowBodyChanged` finding for `shikigami.agent-run`. Save the exact
output to `docs/evidence/plan-127/keiro-diff.txt` and cite it here. Every other component
(check, inspect, scaffold with a clean diff, conformance) must pass.

*ADR.* Write the next free ADR in `docs/adr/` (0123 or later; EP-1 may take a number
first), titled "Coding agents are durable workers and batch qualification is tier-scoped".
It amends ADR-40 as follows. The deadline, output and confinement qualification gate still
applies to `Contained` and `MultiTenant`. `LocalOperator` admits coding agents under the
operator's authority, with Baikai-enforced deadlines, bounded per-stream capture, the
operator's Baikai ceiling, the operator's one-time grant of the declaration, a recorded
`LaunchCodingAgent` decision, and the recovery policy in this plan. A coding-agent result is
a step outcome, never a Baikai `Response` and never a `run-behavior-v2` success. Add one
"Amended by" reference line to ADR-40's References section, and leave its decision text
unchanged.

### Milestone 2 — restart never reruns and never loses track

This milestone makes the `attempt` step body safe to re-execute. Recovery is a pure
decision over facts read from the attempt directory. The decision lives in
`shikigami-core/src/Shikigami/Process/Attempt.hs` beside `attemptBody`, so it is testable
without processes and knows nothing about coding agents. The type parameter `r` is the
parsed result file: Baikai's `LauncherEnvelope` for a coding agent.

```haskell
data AttemptFacts r = AttemptFacts
  { intent :: !(Maybe AttemptIntent),
    launch :: !(Maybe LaunchRecord),
    envelope :: !(EnvelopeState r),
    launcher :: !LauncherState,
    now :: !UTCTime,
    deadline :: !UTCTime
  }
data EnvelopeState r = NoEnvelope | PartialEnvelope | Envelope !r   -- per AttemptHandlers.parseResult
data LauncherState = LauncherAbsent | LauncherRunning | LauncherGone   -- pid plus start time, so a reused pid reads as Gone

data RecoveryDecision r
  = LaunchFresh                        -- no intent.json: nothing was ever attempted
  | Collect !r                         -- a complete result exists: use it, never relaunch
  | Reattach !LaunchRecord             -- launcher alive: wait for it until deadline plus 60 s
  | GiveUp !UncertainReason

recoverAttempt :: AttemptFacts r -> RecoveryDecision r

data AttemptResult r = Collected !r | GaveUp !UncertainReason
-- The IO half lives in shikigami-agent (Shikigami.Agent.Process.Attempt): read the facts,
-- decide, then spawn in a new process group, reattach and wait, or give up.
runAttempt :: (ByteString -> Either Text r) -> AttemptDirectory -> AttemptCommand -> IO (AttemptResult r)
```

`UncertainReason` moves to this module with the decision; `Shikigami.CodingAgent.Types`
re-exports it. `runAttempt` requires only that the launched process writes its result file
atomically when it exits. Baikai's CLI already does. A caller whose command does not, such
as EP-3 M4's declared tools, wraps it in a launcher that does; that wrapper is EP-3's.

The rules, in order:

1. A complete envelope means `Collect`.
2. A live launcher, inside the deadline plus grace, means `Reattach`.
3. A live launcher past the deadline plus grace means `GiveUp LauncherOverran`. Shikigami
   does not kill it. The operator sees its pid in `runs show`.
4. An intent without a launch record means `GiveUp IntentWithoutLaunch`, because the spawn
   may have happened.
5. A launch record with the launcher gone and no envelope (or a partial one) means
   `GiveUp LauncherGoneWithoutResult` or `UnreadableResult`.
6. Otherwise `LaunchFresh`.

`GiveUp` reaches `settle` as `GaveUp`, which returns `Uncertain` with the uncommitted change
summary and does not commit. Log `coding-agent.reattached` and `coding-agent.uncertain`. Because
the launcher runs in its own process group, an interrupt in the worker's terminal does not
reach it.

Restarting a one-off run needs a way to re-drive the same workflow instance. If EP-1 has
not provided one, add `shikigami-agent-run --resume WORKFLOW_ID` in
`shikigami-agent/src/Shikigami/Agent/Command/AgentRun.hs`. It reads the original `RunJob`
from the journaled `ingest-job` step and calls `runAgentRunWorkflow` with it. Because the
workflow id derives from the job, keiro replays the journal. If the previous process's
lease has not yet expired, exit `75` with "run is leased by <owner>; retry after <n>s",
naming the lease from the workflow row (`leased_by`).

### Milestone 3 — Codex, flow-body use, and the documented path

Map `Codex` through the same runner. Baikai refuses a tool allow-list for Codex with exit
77. With `noDeclaredTools` that list is empty, and EP-3 owns any rendering beyond it. Note
in the runbook that Codex's `workspace-write` sandbox may block `git commit` inside a
linked worktree, because the worktree's Git directory lies outside the sandbox. Shikigami's
`settle` does the commit, so the agent does not need to. Add a test-only registered flow,
or reuse the `FlowLifecycleSpec` harness, that calls `codingAgent` under keys `first` and
`second`. This is the representative check for EP-4. Add a section "Durable coding-agent
steps (LocalOperator)" to `docs/operations/baikai-execution.md`. It covers the declaration,
the ceiling file, the attempt directory, the recovery policy, `--resume` and `runs show`.
It also documents attaching skills and the command-parameterized attempt machinery that
EP-3 reuses. Mark the ADR accepted.


## Concrete Steps

Run everything from `/Users/shinzui/Keikaku/bokuno/shikigami` inside the development shell
(`nix develop`, which supplies `PG_CONNECTION_STRING`). Make sure the vendor tools are on
the worker's `PATH` and logged in: `claude --version` and `codex --version` should both
succeed. Both are installed on this Mac at `/Users/shinzui/.local/bin/claude` and
`/opt/homebrew/bin/codex`.

```bash
just keiro-scaffold && git diff --stat shikigami-core/src/Shikigami/CodingAgentStep/Generated
cabal build all
cabal test shikigami-core:test:shikigami-core-test --test-options='--match CodingAgent'
cabal test shikigami-agent:test:shikigami-agent-test --test-options='--match CodingAgent'
just keiro-gate "$(git merge-base HEAD master)" | tee docs/evidence/plan-127/keiro-diff.txt
```

The real run for M1 uses EP-1's `LocalOperator` invocation. The flags below assume EP-1
extends the existing `--workspace` option of `shikigami-agent-run`. Adjust them to what
EP-1 landed.

```bash
cat > /private/tmp/haddock.dhall <<'EOF'
let A = /Users/shinzui/Keikaku/bokuno/shikigami/schema/Agent.dhall
in  A.Agent::{
    , name = "haddock-gaps"
    , trigger = A.Trigger.Event { eventType = "operator.request" }
    , behavior = A.Behavior.CodingAgent
        { provider = A.CodingAgentProvider.ClaudeCode
        , prompt = "Find one exported function in src/ without a Haddock comment and add an accurate one. Change nothing else."
        , access = A.WorkspaceAccess.EditWorkspace
        , model = None Text
        , effort = None A.CodingAgentEffort
        , deadlineMinutes = 20
        , skills = [] : List Text
        }
    }
EOF
cabal run shikigami-agent-run -- --agent /private/tmp/haddock.dhall --workspace /Users/shinzui/Keikaku/bokuno/mina
```

The first run in a terminal asks the operator to grant the declaration once (EP-1); answer
`y`. Expected stderr includes lines like the following (ids abbreviated):

```text
coding-agent.admitted key=behavior provider=claude worktree=…/mina-run-01… branch=shikigami/haddock-gaps/01… deadline=…
coding-agent.launched pid=48122 attempt=…/attempts/shikigami.coding-agent-step-…/
coding-agent.settled outcome=completed exit=0 commit=3f9c2e1 files=1
```

```bash
cabal run shikigami -- runs show shikigami.agent-run <WORKFLOW_ID> --json | jq .codingAgent
git -C <worktree path from the output> log --oneline -1 && git -C <worktree> show --stat HEAD
```

Then check the record and the skill attachment. The ledger command is EP-1's. For the
skill, set `skills = [ "/Users/shinzui/Keikaku/bokuno/shikigami/agents/skills/exec-plan" ]`
and change the prompt to "Read the attached exec-plan skill and report the title of its
SKILL.md in your final message; change nothing." The final message must quote that title.

```bash
cabal run -v0 shikigami-agent:exe:shikigami-local -- ledger --run <WORKFLOW_ID>
```

```text
…Z approved launch_coding_agent claude edit-workspace mori://shinzui/mina
…Z coding-agent.launched attempt=…/attempts/shikigami.coding-agent-step-…/ pid=48122
…Z coding-agent.settled outcome=completed exit=0 commit=3f9c2e1 files=1
```

For M2, start the same run with `deadlineMinutes = 20` and a prompt that takes a few
minutes. When `coding-agent.launched` appears, kill the worker. Then confirm the coding
agent is still alive and resume:

```bash
kill -9 <shikigami-agent-run pid>      # the pid of the process you started, from `echo $!`
ps -o pid,pgid,command -p <launcher pid from launch.json>
cabal run shikigami-agent-run -- --resume <WORKFLOW_ID>
```

Expect `coding-agent.reattached pid=<same pid>`, then `coding-agent.settled`, and no second
`coding-agent.launched`. For the `Uncertain` path, kill both the worker and the launcher's
process group (`kill -TERM -<pgid>`; you started it) before resuming. Expect
`coding-agent.uncertain reason=LauncherGoneWithoutResult`, and a `runs show` outcome of
`uncertain` with the uncommitted files listed.


## Validation and Acceptance

Acceptance is behavior observed on this Mac against real repositories. The tests support
it but do not replace it.

M1 is accepted when a `CodingAgent` declaration with `ClaudeCode` runs through the
`LocalOperator` tier against `/Users/shinzui/Keikaku/bokuno/mina` (or another real
checkout under `/Users/shinzui/Keikaku/bokuno/`). The original checkout's working tree and
branch must be unchanged. The run's worktree branch must carry a new commit made by
Shikigami, containing Claude Code's change. `shikigami runs show shikigami.agent-run <id>
--json` must report `codingAgent.outcome = "completed"`, the exit code, the commit, the
changed files, and an evidence file path whose contents carry the child workflow id as
`run_id`. The action record for the run must show one approved `LaunchCodingAgent`
decision, one `coding-agent.launched` and one `coding-agent.settled` entry. With no
terminal and no stored grant the run must refuse before any process starts. A run whose
step attaches the `exec-plan` skill must quote that skill's title in its final message, and
the original skill directory must be unchanged. The same declaration run under `Contained`
must refuse with `TierRefused` before any process starts. Unit tests in `shikigami-core-test` cover the checked parsers (blank
prompt, 0 and 721 deadline minutes, blank model), the Dhall decoding of the new arm and the
loading of every existing manifest, and the mapping from envelope to outcome (exits 0, 1,
75, 77, and an envelope with `outcome` other than `ran`). The keiro gate's
`WorkflowBodyChanged` finding is recorded with the pre-release facts.

M2 is accepted when the real kill-and-resume on a real repository shows exactly one
`coding-agent.launched` line across both processes and a completed outcome with a commit.
Resuming a run that has already completed must print its outcome from the journal, with no
`coding-agent.launched` and no change to the attempt directory. The killed-launcher case
must end `Uncertain` and list the uncommitted files, and the worktree must have no new
commit. `recoverAttempt` must have a case per rule above. One `shikigami-agent-test` case
drives `runAttempt` with a plain command that is not a coding agent (a shell script that
sleeps, then writes its result file atomically): it kills the driving thread, calls
`runAttempt` again, and asserts one launch and a `Collected` result. That case is what
EP-3 M4 relies on. One `shikigami-agent-test`
integration case covers the timing-dependent rules end to end. In it, a stub vendor
executable (a few lines of shell written by the test into a temporary directory and named
through a test-only Baikai operator file's `executable`) sleeps, edits a file, and prints
Claude-shaped JSON. The case kills the driving thread, resumes, and asserts one launch and
a `Completed` outcome.

M3 is accepted when the same declaration with `provider = Codex` makes and commits a real
change in a second real checkout (for example `/Users/shinzui/Keikaku/bokuno/keiro-syntax`)
and `runs show` reports it. The two-key flow test must show two children with distinct ids,
and a replay of the completed flow must not invoke the runner. The runbook section and the
ADR must be merged.

Not required, and proposed only as later scope: resuming vendor sessions, cancelling a
running step from an operator command, and any `Contained` or `MultiTenant`
qualification.


## Idempotence and Recovery

The steps can be repeated. `just keiro-scaffold` regenerates deterministically. Real runs
each create a fresh run, worktree and branch through EP-1's provider and never touch the
original checkout's branch. Remove finished worktrees with EP-1's cleanup command, or with
`git worktree remove <path>` followed by `git branch -D <run branch>` in the source
checkout. Attempt directories are plain files under `<local state root>/attempts/`, and each holds
its own copies of any attached skills. Delete one only
after its run is terminal. While a run is unfinished, its attempt directory *is* the
recovery state, and deleting it turns a recoverable attempt into `IntentWithoutLaunch`.
If the workflow change has to be backed out before merge, revert the commit. No database
migration is involved. Do not delete the developer database (ADR-27). Stop any process this
plan's instructions started by its recorded pid or process group, never by name.


## Interfaces and Dependencies

Prerequisite: EP-1 must be Complete, and through it EP-8 M1. This plan needs
`TierComposition.resolve` and the `TierRuntime` it returns (to which this plan adds
`codingAgents :: CodingAgentRunner`), the `LocalOperator` workspace provider (a worktree
with path, run branch and base commit, identified by run and repository), EP-1's grant and
`decideLocalAction` (extended here for `LaunchCodingAgent`), EP-8's `Authority` and
`ActionRecord`, and a way to invoke a `LocalOperator` run on this Mac. EP-3
(`docs/plans/128-let-agents-declare-cli-tools-and-mcp-servers-with-authority-attached-to-the-declaration.md`)
is not required. This plan creates `Shikigami.Tool.Resolved.ResolvedToolSet` containing
only `noDeclaredTools`. EP-3 owns that module from then on and supplies the renderers into
Claude and Codex job settings. Its representative check (a declared `mori registry show`
call succeeds and an undeclared `gh` call is refused) runs through this plan's runner.

Interfaces other plans consume. Each module name is final once M1 lands.

- `Shikigami.CodingAgent.Types` (`shikigami-core`): `CodingAgentStep`,
  `CodingAgentWorkspace`, `CodingAgentAdmission`, `CodingAgentOutcome` and its parts, and
  the checked parsers.
- `Shikigami.Flow.CodingAgent` (`shikigami-core`): the `CodingAgent` effect,
  `codingAgent :: DeclarationCoordinate "coding-agent-key" -> CodingAgentStep -> Eff es CodingAgentOutcome`,
  and its interpreter. EP-4's playbook interpreter calls only this function.
- `Shikigami.CodingAgent.Workflow` and `domain/shikigami/coding-agent.keiro`: the
  `shikigami.coding-agent-step` child and `codingAgentStepWorkflowId`.
- `Shikigami.Process.Attempt` (`shikigami-core`): `AttemptCommand`, `AttemptHandlers`,
  `attemptBody`, `AttemptFacts`, `recoverAttempt`, `AttemptResult`, and in `shikigami-agent`
  `Shikigami.Agent.Process.Attempt.runAttempt`. Accepted with M2. EP-3's fourth milestone
  depends on M2 by name ("EP-2 M2 (for M4)" in MasterPlan 22's registry) and builds its
  declared-tool step on these.
- `Shikigami.CodingAgent.Inspect`: `codingAgentInspection`.
- `Shikigami.Agent.CodingAgent.Local` (`shikigami-agent`): `localCodingAgentRunner`.

External dependencies: Baikai 0.10.1.1 and `baikai-agent` 0.2.0.4, already pinned by
Shikigami. This plan relies on their CLI flags (`--config`, `--prompt-file`, `--run-id`,
`--evidence-file`, `--json`), on the exit-code contract, on evidence being written before
the envelope, and on the agent running in its own process group. Before relying on these,
verify the released version against Hackage and the upstream tags, as the global
dependency rule requires. This plan also relies on Baikai's `extra-dirs` job key. Add the new
namespaces (`CodingAgent`, `CodingAgentStep`, `Process`) to
`tools/style/module-ownership.json` (ADR-75). They are kernel primitives under the
classification in MasterPlan 22.

Revision note (2026-11-15): cascaded the MasterPlan 22 review. The attempt machinery is
command-parameterized for EP-3 M4, steps attach skills, and the launch is decided and
recorded through EP-8's kernel ports resolved per run by EP-1.
