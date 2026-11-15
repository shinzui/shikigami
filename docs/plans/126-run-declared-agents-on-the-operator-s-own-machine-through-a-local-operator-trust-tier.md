---
id: 126
slug: run-declared-agents-on-the-operator-s-own-machine-through-a-local-operator-trust-tier
title: "Run declared agents on the operator's own machine through a local-operator trust tier"
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
      at: 2026-11-15T14:04:28Z
      mode: "other"
      note: "Drafted plan body under MasterPlan 22"
    - model: "claude-opus-5-5"
      harness: "claude-code"
      at: 2026-11-15T14:15:42Z
      mode: "discuss"
      note: "Applied user decisions of 2026-11-15 (repos, in-place placement, disposable databases, stalled-intention)"
    - model: "claude-fable-5-2"
      harness: "claude-code"
      at: 2026-11-15T14:50:34Z
      mode: "update"
      note: "Cascaded MasterPlan 22 review: EP-8 M1 dependency, kernel authority and record ports, per-run resolution, confirm-once grants"
    - model: "claude-opus-5-5"
      harness: "claude-code"
      at: 2026-11-15T16:40:22Z
      mode: "implement"
      note: "M1 implemented: TrustTier, approvals, confirm-once grants, local authority, shikigami-local, ADR-124"
---

# Run declared agents on the operator's own machine through a local-operator trust tier

This ExecPlan is a living document. The sections Progress, Surprises & Discoveries,
Decision Log, and Outcomes & Retrospective must be kept up to date as work proceeds.
If durable project context changes, update or create ADRs in docs/adr/ in the same change.
Record friction met while implementing in the friction-log bundle as it occurs (see FRICTION.md).


## Purpose / Big Picture

Today a declared agent cannot touch a repository on the operator's own Mac. The one-off
commands install a deny-all authorizer, so even read-only `workspace.read` fails before its
provider is acquired (`docs/user/cli.md`, "Current limitation"). The mutating tools
(`workspace.edit`, `workspace.exec`, `workspace.git`) exist only behind a Linux systemd
supervisor, reserved Unix identities and Kikan-En authorization.

After this plan the operator selects a *trust tier*: a named level of authority and
containment that decides who authorizes a run's actions and how its processes are contained.
The tier never switches the kernel's guarantees off: every action still has a principal, is
decided by one authority and is recorded. Under the new `LocalOperator` tier the operator is
the authority. They run a declared Skill agent against a real checkout with
`shikigami-agent-run`. The first time, the command shows what the declaration asks for (the
repository, where the run will work, and its capabilities) and asks once. The answer is
stored against the declaration's digest, so the next run does not ask and an edited
declaration asks again. An approvals file in the XDG config directory is the explicit form
of the same grant, and the only place command rules are approved. The run works in its own
Git worktree on a fresh branch. It reads and edits files, runs only operator-approved
commands (each under a deadline with bounded output), and commits on that branch. The commit
is visible in the operator's checkout with `git log <branch>`. Every grant and every
decision, including refusals, is appended to the kernel's action record, which
`shikigami-local ledger` prints. No Kikan service is needed, only the local PostgreSQL that
`shikigami-agent-run` already uses and the operator's model credential. Under `Contained`
and `MultiTenant` each executable keeps doing what it does today.

This plan builds on EP-8 M1
(`docs/plans/133-give-the-kernel-its-own-action-record-output-approval-and-trigger-contracts-with-local-adapters.md`),
which gives the kernel its own action type, authority port and action record. The
`LocalOperator` authority is an adapter of that port.


## Progress

- [x] Milestone 1 (2026-11-15) — the tier exists and a read-only LocalOperator run works. `TrustTier`,
  the per-run `TierComposition`, grants (the approvals file and the confirm-once store), the
  local authority adapter, the record kinds, `shikigami-local` and the tier ADR are in
  place. On this Mac, `shikigami-agent-run` runs `agents/local-maintainer.dhall`
  (`workspace.read`) against `mori://shinzui/fsrs-hs` with no approvals file: it asks once,
  answers from the real files, and does not ask on the second run. The action record shows
  the grant and the approved decisions. `agents/triage-note.dhall`, which declares a Kizashi
  sink, is refused when it is resolved, before any model call. Without a tier setting the
  read-only command fails exactly as before.
  Evidence (this Mac, `behavior.provider=openai`, `behavior.model=gpt-5.4-mini`, grants in a
  scratch `trust.local_operator.state_dir`, no approvals file): the first run of
  `agents/local-maintainer.dhall` against `mori://shinzui/fsrs-hs` printed the request, asked
  `Grant this declaration? [y/N]`, and on `y` answered from `src/FSRS.hs`,
  `src/FSRS/Scheduler.hs`, `fsrs-hs.cabal` and `README.md`, ending `record 17 approved, 0
  refused`. The second run did not ask. An edited copy of the declaration run with no terminal
  refused with `no stored grant for this declaration; run it once in a terminal to confirm it`
  before any model call, as did the unedited one before its confirmation. `shikigami-local
  ledger --run <id>` showed `authority.granted` and the approved `authority.decided` events
  with the run id; `shikigami-local approvals` listed the stored grant. `triage-note` was
  refused with `the declaration lists outputs this composition cannot deliver:
  kizashi.signal`. Without `trust.tier` the read-only command failed with today's deny-all
  refusal (`ExecutionPolicyRefused "exact capability lease is unavailable"`). Selecting the
  checkout by path resolved the same identity and reused the grant. `LocalOperatorSpec` (13
  cases), the agent `CommandSpec`, the worker tier test and `just haskell-conventions` pass;
  ADR-124 is written.
- [ ] Milestone 2 — LocalOperator edits, executes and commits in a worktree. The same agent
  with all four workspace capabilities produces a commit on
  `shikigami/local-maintainer/<suffix>` in fsrs-hs, runs the approved `build` rule under its
  deadline, and has an unapproved rule refused; `shikigami-local ledger --run <id>
  --refusals` shows the refusal and `shikigami-local approvals` shows what was approved.
  One run can hold worktrees of two repositories, each identified by run and repository.
  The same agent against a repository the operator marked `InPlace` commits directly on that
  checkout's current branch with no worktree or branch created. A second concurrent run, or
  a run against a dirty tree, is refused and appears in the action record.


## Surprises & Discoveries

- Observation: `shikigami-core` may not link `process`; the package-architecture test treats it
  as a provider adapter. Every host process the local operator needs (`git`, `mori`, and in
  milestone 2 the command launcher and worktree commands) must live outside core.
  Evidence: `core links the neutral tool registry without a provider adapter` failed with
  `core links ["process"]`. M1 injects a `CheckoutResolver` into the approvals module and puts
  the process adapter in `shikigami-agent/src/Shikigami/Agent/Checkout.hs`.
- Observation: `mori status --json` exits 1 whenever it lists any project issue, while still
  printing the identity; its text contains non-ASCII characters. See FRIC-74.
- Observation: `shikigami-agent-run` printed no answer, only the session and the learning.
  Evidence: `renderRunResult` ignored `behaviorOutput`. M1 prints the reply, because the
  operator needs to read what the agent did.
- Observation: Workspace effects are capability tools of `shikigami.workspace`, not separate
  workspace actions (EP-8 M1). Milestone 2's policy therefore maps a granted `workspace.edit`,
  `workspace.exec` or `workspace.git` to `UseCapability` on those capability ids at revision
  `local-1`.


## Decision Log

- Decision: Add an operator-chosen `WorkspacePlacement`. `SeparateWorktree` is the default,
  and `InPlace` commits directly to the checkout's current branch.
  Rationale: On 2026-11-15 the user said the repositories EP-7 modernizes need no branches,
  because nobody else works in them. Branch-per-run stays the default where other work may
  be in flight. `InPlace` keeps the undo point (the recorded starting commit) and refuses
  dirty trees and concurrent runs.
  Date: 2026-11-15

- Decision: `TrustTier`, `TierComposition` and the `TierRuntime` record live in
  `shikigami-core`, as do the `LocalOperator` interpreters (authority adapter, grants,
  worktree, launcher, adapters). The light-command composition lives in `shikigami-agent`;
  the worker builds its `Contained`/`MultiTenant` composition in `shikigami-workers`.
  Rationale: The MasterPlan puts the type and composition in the core, but today's
  `Contained` pieces are split: `workspace.read` is in `shikigami-agent` (ADR-25) and the
  configured workspace host is in `shikigami-workers`. Moving them is churn unrelated to use.
  Date: 2026-11-15
- Decision: Explicit approvals are keyed by agent name and repository, and confirmed grants
  by the digest of the declaration and the repository. The authority, resolved for one run,
  accepts exactly that agent's declared `identity.principal` and its compatibility
  principal.
  Rationale: Durable tools are scoped by `principalScopeText (CompatibilityAgent name)`
  (`shikigami-core/src/Shikigami/Execution/Tools.hs`), a derived `shikigami.agent.v2.<uuid>`
  string an operator cannot reasonably write.
  Date: 2026-11-15
- Decision: The pure catalog `authorize` admits installed local descriptors; approval is
  decided only by the tier `Authority` at IO, so every decision reaches the action record.
  Rationale: ADR-36 already treats resolution as a request; a pure check cannot write.
  Date: 2026-11-15
- Decision: Local tools reuse the ids `workspace.edit`, `workspace.exec`, `workspace.git`
  at revision `local-1`, installed as durable adapters only by `LocalOperator`, with
  admissions carrying a new `FilePolicy` constructor `LocalHostFilesV1`.
  Rationale: Declarations stay portable across tiers; generic durable overlays admit only
  observations; the supervised adapters compare `filePolicy` exactly and so refuse local
  admissions without new code.
  Date: 2026-11-15
- Decision: A `LocalOperator` run requesting a mutating workspace tool enrolls a resource
  root with `Shikigami.Execution.Admission.enrollRootRun`, from the approval's `budget`.
  Rationale: `WorkspaceAdmission.rootId` is mandatory and `shikigami-agent-run` sets
  `executionRootId = Nothing`; enrolling avoids changing a protected snapshot type and bounds
  real model and tool spend.
  Date: 2026-11-15
- Decision (superseded by the MasterPlan 22 review entry below): Kikan sinks are refused
  under `LocalOperator` (`SinkUnavailable`, ledgered); no local report sink is added.
  Rationale: A new sink kind changes the declaration and workflow body, while sink denial is
  already a non-fatal `DeniedOutcome` (`shikigami-core/src/Shikigami/Sink.hs`).
  Date: 2026-11-15
- Decision: `trust.tier` defaults to `contained`. `MultiTenant` uses the `Contained`
  composition but configuration refuses it when `authorization.actions.mode` is `disabled`.
  `shikigami-worker` refuses `local-operator` in this plan.
  Rationale: Today's behavior is unchanged while `MultiTenant` has one executed difference
  ([ADR-1](../adr/0001-declare-only-what-the-runtime-executes.md)). This slightly refines
  the MasterPlan's "unchanged"; EP-2 may lift the worker refusal.
  Date: 2026-11-15
- Decision: Local commits use `-c commit.gpgsign=false commit --no-verify` under the
  operator's Git identity, with `Shikigami-Run:` and `Shikigami-Agent:` trailers.
  Rationale: An unattended run cannot answer pinentry or interactive hooks; the branch is a
  proposal the operator reviews, amends or signs.
  Date: 2026-11-15
- Decision: This plan depends hard on EP-8 M1. The `LocalOperator` authority is an adapter
  of `Shikigami.Authority` over the kernel's own `Action` type, not an `ActionAuthorizer`
  over Kikan-En's `AgentAction`.
  Rationale: MasterPlan 22's review of 2026-11-15 found that `AgentAction` is a closed sum
  owned by `mori://shinzui/kikan-en/packages/kikan-en-contract`. A local authorizer written
  against it would put Kikan's vocabulary under the operator's own tier, and EP-2 and EP-3
  could not name a coding-agent launch or a declared tool without a Kikan-En release.
  Date: 2026-11-15
- Decision: This plan defines no ledger type and no ledger file. It appends to EP-8's
  `Shikigami.Record` action record under kinds it owns (`authority.decided`,
  `authority.granted`, `workspace.opened`, `process.finished`, `commit.created`) and keeps
  `shikigami-local ledger` as the operator's view.
  Rationale: MasterPlan 22 moved the record to EP-8 so that there is one record in every
  tier and a new effect needs no change to a shared sum. The first draft's `LedgerEntry`
  was a closed sum that every later plan had to extend.
  Date: 2026-11-15
- Decision: Ports are resolved per run and per repository through
  `TierComposition.resolve :: RunSubject -> IO (Either TierRefusal TierRuntime)`. A worktree
  and the `InPlace` lock are identified by run and repository.
  Rationale: The first draft's `selectTierRuntime` built one runtime per command invocation
  for one agent and one repository. EP-2 runs `LocalOperator` work in a long-lived worker
  that serves many agents, and EP-4's playbook steps each select a repository.
  Date: 2026-11-15
- Decision: The operator grants a declaration once. An interactive run shows the request
  and asks; the answer is stored outside every workspace under the digest of the
  declaration and the repository. Runs without a terminal use only stored grants or the
  approvals file. A grant with no stated budget uses a bounded default.
  Rationale: The user chose "confirm once per declaration" on 2026-11-15. Requiring a
  hand-written approvals entry before anything ran made a routine agent several files.
  Command rules stay in the approvals file, because a declaration cannot name a command line
  until EP-3 adds declared tools.
  Date: 2026-11-15
- Decision: The authority no longer refuses sinks as `SinkUnavailable`. Outputs under
  `LocalOperator` belong to EP-8 M2. Until it lands, a declaration that lists sinks is
  refused when it is resolved, with `OutputsUnavailable`.
  Rationale: MasterPlan 22 replaces the closed `Sink` union with an output port. A run that
  completes with its only output silently denied teaches the operator nothing, and a
  refusal constructor here would be deleted by EP-8.
  Date: 2026-11-15
- Decision: Landed names for EP-8 M1's contracts. `Authority` is abstract
  (`authority.decide`), `Action` is `UseCapability (ConnectProvider | InvokeTool)` or
  `EmitOutput`, and `RecordEvent.tier` is a `TierLabel` (`trustTierLabel`). The local policy
  therefore approves `UseCapability` for granted capability ids and refuses `EmitOutput` as
  `OutsideGrant`; `ReadWorkspace`, `WriteWorkspace` and `ExecuteWorkspace` do not exist.
  Rationale: EP-8 M1 declared only executed actions (ADR-1).
  Date: 2026-11-15
- Decision: M1 defers `ProcessLauncher`, the `TierRuntime.workspace` and `launcher` fields and
  the worker's `TierComposition` wrapper to milestone 2 and EP-2. `TierRuntime` carries the
  resolved `grant` instead. The worker refuses `local-operator`, and `multi-tenant` with
  `authorization.actions.mode=disabled`, at boot (`workerTierAdmission`).
  Rationale: ADR-1; none has an executed consumer in M1, and wrapping the worker's existing
  values changes no behavior.
  Date: 2026-11-15
- Decision: The record kinds live with their producers: `grantEntry` (`authority.granted`) in
  `Shikigami.Trust.LocalOperator.Grant`, `authority.decided` from EP-8's `recorded`. No
  `Records` module is added; milestone 2 adds its kinds beside the worktree and launcher code.
  Rationale: EP-8's rule that a producer owns its kind.
  Date: 2026-11-15
- Decision: `RunSubject.repository` is a `RepositorySelector` (identity or path), not a
  `RepositoryId`. An unlisted path takes its Mori identity from `mori status --json` and
  otherwise `file://<toplevel>`.
  Rationale: `--workspace` takes either form, and a path must resolve to the same grant as its
  identity.
  Date: 2026-11-15
- Decision: A grant confirmation is appended to the record before it is stored, and a failed
  append refuses the grant. End of input at the prompt is a no.
  Rationale: K3; and a piped or closed terminal must never become consent.
  Date: 2026-11-15
- Decision: Pre-release recheck for M1, 2026-11-15: no `git tag`, no deployment, no journals
  that must resume, no wire consumers. M1 changes no workflow body or journaled value.
  Rationale: Required before each milestone.
  Date: 2026-11-15
- Decision: "`Contained` keeps today's behavior" is restated per executable. The worker's
  authority is selected by `authorization.actions.mode`; the light commands, conversations
  and the server's objective handlers hard-code deny-all.
  Rationale: The review checked the code: there is no single behavior today
  (`shikigami-workers/src/Shikigami/Workers/Command/Worker.hs`,
  `shikigami-agent/src/Shikigami/Agent/Command/AgentRun.hs`,
  `shikigami-core/src/Shikigami/Agent/Conversation.hs`).
  Date: 2026-11-15


## Outcomes & Retrospective

(To be filled during and after implementation.)


## Context and Orientation

Shikigami is a Haskell monorepo. `shikigami-core` is the domain library; `shikigami-agent`
is the light one-off package and may depend only on `shikigami-core` and
`shikigami-migrations` (`shikigami-core/test/Shikigami/PackageArchitectureSpec.hs`). Records
use `DuplicateRecordFields`/`NoFieldSelectors` with unprefixed fields (`AGENTS.md`).

An agent is a Dhall declaration (`schema/Agent.dhall`) with a `behavior` (here
`Skill { path }`, a directory holding `SKILL.md`), `capabilityOverlays` (capability ids such
as `"workspace.read"`) and an optional `identity = Some { principal = "…" }`. An overlay is
a request for extra model tools that an operator catalog satisfies with an immutable
descriptor (`shikigami-core/src/Shikigami/Capability/Overlay.hs`, `Catalog.hs`); the model
sees them as `overlay__workspace-edit__replace` and so on.

`shikigami-agent-run --agent FILE [--workspace DIR]`
(`shikigami-agent/src/Shikigami/Agent/Command/AgentRun.hs`) opens the local PostgreSQL store,
builds `AgentRunDeps` (`shikigami-core/src/Shikigami/Agent/Workflow.hs`), starts the
durable agent-run workflow and drives its accepted Skill execution in the foreground. It
sets `actionAuthorizer = denyAllActionAuthorizer`, `workspace = Nothing` and
`executionRootId = Nothing`, always passes a `null` trigger payload, and uses
`oneOffCapabilityRuntime` (`shikigami-agent/src/Shikigami/Agent/Capability/OneOff.hs`),
whose catalog holds only the `workspace.read` revision 1 provider from
`.../Capability/Workspace.hs`. `shikigami-run-behavior` (`.../Command/RunBehavior.hs`) is
the database-free sibling and is also deny-all.

Authority has two layers. `CapabilityRuntime.authorize`
(`shikigami-core/src/Shikigami/Capability/Provider.hs`) is a pure check on resolving a
descriptor. An `ActionAuthorizer` (`shikigami-core/src/Shikigami/Action/Authorization.hs`)
is a record whose `authorize :: DeclarationCoordinate "principal" -> AgentAction -> IO
(Either ActionAuthorizationFailure ActionAuthorizationDecision)` runs immediately before IO.
`AgentAction` is Kikan's closed vocabulary from
`mori://shinzui/kikan-en/packages/kikan-en-contract` (`ConnectCapability`,
`InvokeCapabilityTool`, `ExecuteWorkspace`, `DispatchKawa`, `DispatchKizashi`,
`ActOnIntention`, `AttachDanwa`, `DispatchChannel`, and others), rendered by `actionTag`
and `actionResource`. Production builds `newKikanActionAuthorizer` from
`authorization.actions.mode` (`.../Action/Authorization/Config.hs`). Decisions are only
logged (`logDecision`); no table records them.

That is the state before EP-8 M1, which this plan requires. EP-8 M1 replaces the Kikan-En
type in this path with the kernel's own `Shikigami.Authority.Action` and `Authority` port,
keeps deny-all as the default, turns the Kikan-En authorizer into an adapter, and adds the
action record `Shikigami.Record.ActionRecord`. Where this plan says "authority", "action"
and "record", it means those. If a name differs in the landed code, use the landed name and
record the mapping in the Decision Log.

Durable Skill execution (`shikigami-core/src/Shikigami/Execution/Tools.hs`) admits generic
overlays only when all their tools are `Observation`s. Mutation needs a `DurableAdapter`
installed with `installDurableAdapters`: a descriptor, fixed tool contracts (schema and
recovery class) and a `prepare` callback receiving the frozen `ExecutionSnapshot` and
accepted dispatch coordinates. A declaration naming `workspace.edit`, `workspace.exec` or
`workspace.git` (`requestsWorkspace`) routes through the journaled step
`admit-workspace-skill-execution`, which calls `WorkspaceHost.load :: SkillAssignment -> IO
(Either ExecutionError WorkspaceAdmission)` (`shikigami-core/src/Shikigami/Workspace/Admission.hs`).
A `WorkspaceAdmission` (`.../Workspace/Instructions.hs`) carries a `WorkspaceRef {provider,
resource}`, a binding digest, run and assignment ids, a mandatory `ExecutionRootId`, the
owner, an epoch, an `InstructionBundle` of `AGENTS.md` files frozen at the base, and a
`Maybe FilePolicy` (`.../Workspace/Value.hs`). The only hosts
(`shikigami-workers/src/Shikigami/Workspace/Host.hs`, `ConfiguredHost.hs`) copy repositories
into a private store and, for processes, require the Linux supervisor of
`docs/operations/workspaces.md`.

Reusable checked values exist: `Shikigami.Repository` (`RepositoryId`, `Revision` via
`mkRevision`, `RelativePath` via `mkRelativePath`), `mkInstructionBundle`, and
`enrollRootRun` with `Shikigami.Execution.Resources.Envelope` (per-`Dimension` `Limits`
plus a cutoff). Configuration is Settei-based in `shikigami-core/src/Shikigami/App/Config.hs`.
New top-level namespaces are listed in `tools/style/module-ownership.json`
(`just haskell-conventions`). The acceptance repository is `mori://shinzui/fsrs-hs`, which
`mori path` resolves to `/Users/shinzui/Keikaku/bokuno/fsrs-hs` (a small Haskell library
with `flake.nix`, `Justfile`, `README.md`).

Relevant ADRs:
[ADR-3](../adr/0003-a-seventh-package-keeps-one-off-agent-runs-light.md) keeps one-off
commands in `shikigami-agent`, so `shikigami-local` goes there.
[ADR-25](../adr/0025-capability-overlays-are-requests-for-additive-model-tools.md) makes the
operator catalog the authority, requires installed durable adapters for mutation, and
forbids widening `workspace.read` revision 1.
[ADR-36](../adr/0036-external-agent-actions-require-fresh-exact-authorization.md) requires
fresh authorization before every connection and tool call, with deny-all when unconfigured;
this plan amends it so the authorizer is tier-selected.
[ADR-27](../adr/0027-the-first-release-establishes-one-clean-durable-baseline.md) with
`docs/workflow-versioning.md` allows replacing unreleased shapes after rechecking the
pre-release facts, and still requires `just keiro-gate`.
[ADR-59](../adr/0059-harness-policy-is-frozen-at-admission-and-shared-with-ephemeral-execution.md)
bounds model turns through `behavior.harness` (default eight).
[ADR-78](../adr/0078-execution-policy-and-durable-progress-use-checked-distinct-values.md)
and [ADR-80](../adr/0080-opaque-checked-values-do-not-expose-generic-construction.md) govern
the new checked newtypes and sealed values.
[ADR-75](../adr/0075-service-composition-has-a-closed-reviewed-module-budget.md) makes the
new `Trust` root a reviewed entry.
[ADR-102](../adr/0102-workspaces-have-allocated-identities-beside-stable-origin-locators.md)
allocates governed `WorkspaceId`s in PostgreSQL; local worktrees do not use that store.


## Plan of Work

Two milestones: the first makes authority selectable and observable with read-only tools;
the second adds the worktree, launcher and mutating tools. Each ends in a real run.

### Milestone 1: tier, grants, authority adapter and record kinds

This milestone builds on two kernel contracts that EP-8 M1
(`docs/plans/133-give-the-kernel-its-own-action-record-output-approval-and-trigger-contracts-with-local-adapters.md`)
delivers and owns. Read them from the landed code and use their exact names; the shapes
below are the ones MasterPlan 22 records.

```haskell
-- Shikigami.Authority (EP-8 M1): the kernel's own action type and the one deciding port
data Action
  = UseCapability !CapabilityTarget | ReadWorkspace !WorkspaceTarget | WriteWorkspace !WorkspaceTarget
  | ExecuteWorkspace !WorkspaceCommandTarget | RunDeclaredTool !DeclaredToolTarget
  | LaunchCodingAgent !CodingAgentTarget | EmitOutput !OutputKind !OutputTarget
  | RequestApproval !ApprovalChannelKind | DelegateRun !AgentName
newtype Authority = Authority {decide :: Principal -> Action -> IO (Either AuthorityFailure Decision)}

-- Shikigami.Record (EP-8 M1): the single action record
newtype ActionRecord = ActionRecord {append :: RecordEvent -> IO (Either RecordError ())}
data RecordEvent = RecordEvent
  {at :: !UTCTime, run :: !(Maybe WorkflowId), principal :: !Principal, tier :: !TrustTier, agent :: !AgentName, entry :: !RecordEntry}
data RecordEntry = RecordEntry {kind :: !RecordKind, payload :: !Value}   -- kind is a checked dotted name
```

`RecordEvent` names `TrustTier`, so EP-8 M1 needs the bare enumeration. If EP-8 M1 already
created `Shikigami.Trust.Tier`, extend that module here instead of adding it, and record
that in the Decision Log.

Add `shikigami-core/src/Shikigami/Trust/Tier.hs` and `Shikigami/Trust/Runtime.hs`, and list
`Trust` in `tools/style/module-ownership.json`. Use-case code never matches on `TrustTier`.

```haskell
data TrustTier = LocalOperator | Contained | MultiTenant
  deriving stock (Eq, Ord, Show, Enum, Bounded)
parseTrustTier :: Text -> Either TrustTierError TrustTier  -- local-operator | contained | multi-tenant
trustTierText :: TrustTier -> Text

-- Built once per process. A worker serves many agents, and a playbook step may select
-- another repository than the step before it, so ports are resolved per run and repository.
data TierComposition = TierComposition
  { tier :: !TrustTier,
    resolve :: RunSubject -> IO (Either TierRefusal TierRuntime)
  }

data RunSubject = RunSubject
  {agent :: !AgentDecl, principal :: !Principal, run :: !WorkflowId, repository :: !(Maybe RepositoryId)}

-- The ports for one run and one repository. Later plans add a field per new
-- tier-dependent behavior (EP-2 the coding-agent runner, EP-3 the tool catalog).
data TierRuntime = TierRuntime
  { tier :: !TrustTier,
    authority :: !Authority,
    record :: !ActionRecord,
    capabilities :: !CapabilityRuntime,   -- generic providers plus installed durable adapters
    workspace :: !(Maybe WorkspaceHost),
    launcher :: !ProcessLauncher
  }

data TierRefusal
  = NoGrant !GrantRefusal                 -- nothing granted this declaration on this repository
  | RepositoryUnavailable !ApprovalsError
  | OutputsUnavailable !(NonEmpty Text)   -- declared sinks this composition cannot deliver
  | TierUnsupportedHere !TrustTier !Text  -- e.g. local-operator in shikigami-worker (until EP-2)
```

`ProcessLauncher` (milestone 2) is declared here too; until then every tier uses
`unavailableLauncher`. Resolution is idempotent for a subject: resolving the same run and
repository twice yields ports bound to the same grant and the same worktree.

**Grants.** A *grant* is what the operator allowed one declaration to do on one repository.
It has two sources, and both produce the same sealed value. The first is the explicit
approvals file. The second is a one-time interactive confirmation, which the user chose on
2026-11-15 so that a routine agent needs no hand-written approvals entry.

Add `shikigami-core/src/Shikigami/Trust/LocalOperator/Approvals.hs` and
`schema/LocalOperator.dhall` (record-completion defaults). The file is Dhall, like agent
declarations, and defaults to `$XDG_CONFIG_HOME/shikigami/local-operator.dhall`
(`getXdgDirectory XdgConfig`). It is optional: a missing file is an empty set of explicit
approvals, not an error. Decoded input is plain data; the validated value is sealed and
read through `HasField` views. Construction is IO because it canonicalizes sources, runs
`mori path <uri>` when `source` is omitted, and resolves programs with `findExecutable`.

```haskell
data LocalApprovalsInput = LocalApprovalsInput {repositories :: ![RepositoryInput], agents :: ![AgentApprovalInput]}
data RepositoryInput = RepositoryInput {identity :: !Text, source :: !(Maybe Text), base :: !Text, placement :: !PlacementInput}
data AgentApprovalInput = AgentApprovalInput
  {agent :: !Text, repository :: !Text, capabilities :: ![Text], rules :: ![RuleInput], budget :: !(Maybe BudgetInput)}
data RuleInput = RuleInput {name :: !Text, argv :: ![Text], inherit :: ![Text], timeoutSeconds :: !Natural, outputBytes :: !Natural}
data BudgetInput = BudgetInput {modelAttempts :: !Natural, toolAttempts :: !Natural, tokens :: !Natural, minutes :: !Natural}

data LocalApprovals; data LocalRepository; data AgentApproval  -- abstract, HasField read views
data ApprovedRule = ApprovedRule
  {name :: !RuleName, program :: !ProgramPath, arguments :: ![Text], inherit :: ![Text], deadline :: !LaunchDeadline, outputLimit :: !OutputLimit}
newtype RuleName = RuleName Text                 -- mkRuleName: [a-z][a-z0-9-]{0,63}
newtype ProgramPath = ProgramPath FilePath       -- absolute and executable
newtype LaunchDeadline = LaunchDeadline Natural  -- 1..86400 seconds
newtype OutputLimit = OutputLimit Natural        -- 1024..1048576 bytes per stream

loadLocalApprovals :: FilePath -> IO (Either ApprovalsError LocalApprovals)
selectRepository :: LocalApprovals -> RepositorySelector -> IO (Either ApprovalsError LocalRepository)
data RepositorySelector = SelectByIdentity !RepositoryId | SelectByPath !FilePath
approvalFor :: LocalApprovals -> AgentName -> LocalRepository -> Maybe AgentApproval
```

`selectRepository` also accepts a checkout the file does not list: `SelectByPath` on a Git
toplevel yields a `LocalRepository` with the default placement `SeparateWorktree` and base
`HEAD`. Its identity is the Mori identity when `mori` reports one for that path, and
otherwise a path-derived identity; check what `RepositoryId`'s parser admits and record the
chosen form in the Decision Log. `ApprovalsError` has one constructor per refusal (invalid
Dhall, non-canonical, duplicate or unresolvable repository, unknown repository or
capability, duplicate approval, invalid rule, missing program). Only the four `workspace.*`
ids are known until EP-3 adds declared tools.

Add `shikigami-core/src/Shikigami/Trust/LocalOperator/Grant.hs`:

```haskell
-- What a declaration asks for on a repository. Pure, derived from the declaration.
data GrantRequest = GrantRequest
  {agent :: !AgentName, repository :: !LocalRepository, placement :: !WorkspacePlacement, capabilities :: !(Set CapabilityId)}
requestedGrant :: AgentDecl -> LocalRepository -> GrantRequest

newtype GrantDigest = GrantDigest Text  -- versionedDigest "shikigami.local-grant/1" over the canonical
                                        -- declaration JSON and the repository identity
grantDigest :: AgentDecl -> LocalRepository -> GrantDigest

data GrantSource = FromApprovalsFile | ConfirmedByOperator !UTCTime
data LocalGrant   -- sealed; views: agent, repository, placement, capabilities, rules, budget, source, digest
data Budget = Budget {modelAttempts :: !Natural, toolAttempts :: !Natural, tokens :: !Natural, minutes :: !Natural}
defaultBudget :: Budget   -- 30 model attempts, 120 tool attempts, 3,000,000 tokens, 60 minutes

data GrantStore = GrantStore
  {lookup :: GrantDigest -> IO (Either GrantError (Maybe LocalGrant)), save :: LocalGrant -> IO (Either GrantError ())}
openGrantStore :: FilePath -> IO (Either GrantError GrantStore)   -- <state>/grants/<digest>.json, mode 0600

data Interaction = Interactive !Prompt | Unattended   -- Prompt: show a rendered request, read yes or no
data GrantRefusal = NoStoredGrant !GrantDigest | OperatorDeclined | RequestExceedsApproval !(Set CapabilityId)
resolveGrant :: Interaction -> LocalApprovals -> GrantStore -> AgentDecl -> LocalRepository -> IO (Either GrantRefusal LocalGrant)
renderGrantRequest :: GrantRequest -> Text
```

`resolveGrant` applies these rules in order:

1. An approvals-file entry for this agent and repository is the grant, used as written and
   never prompted for. If the declaration requests a capability the entry does not list,
   the result is `RequestExceedsApproval`.
2. Otherwise a stored grant under `grantDigest` is the grant.
3. Otherwise, when `Interactive`, the command prints `renderGrantRequest` (the repository
   with its resolved path, the placement, each requested capability, and, once EP-3 lands,
   each declared tool) and asks once. A yes is saved to the store and appended to the
   record as `authority.granted`; a no is `OperatorDeclined`.
4. Otherwise `NoStoredGrant`. A run with no terminal never prompts. That covers every
   worker and scheduled run.

Two more operations serve the commands that submit runs (EP-4's `shikigami playbook start`
and EP-9's `shikigami-local run` and `up`), which call `resolveGrant` before they enqueue
anything, because they hold the terminal and the worker does not:

```haskell
grantsForAgent :: GrantStore -> LocalApprovals -> AgentName -> IO (Either GrantError [LocalGrant])
proposeBudget :: Budget -> GrantRequest -> GrantRequest
```

`grantsForAgent` lists the stored and file grants of one agent. A scheduled run job carries
no repository, so `TierComposition.resolve` takes the repository from the agent's single
grant and refuses with `TierRefusal` when it has none or several. `proposeBudget` lets a
caller such as EP-9 show its own bounded defaults in the prompt; otherwise the prompt
shows `defaultBudget`. `NoStoredGrant` is the refusal a caller matches to tell the operator to
run the agent once by hand.

The digest covers the whole declaration, so any edit to the declaration asks again. The
store lives under the operator's state directory, outside every workspace, so an agent
cannot write its own grant. A confirmed grant carries no `workspace.exec` rules: a
declaration has no field that names a command line until EP-3 adds declared tools, so
approved rules exist only in the approvals file. A grant with no stated budget uses
`defaultBudget`, so a routine agent states none. `Interaction` is `Interactive` only when
standard input and output are both terminals (`hIsTerminalDevice`, as
`shikigami-agent/src/Shikigami/Agent/Command/Launch.hs` already checks) and
`--no-confirm` was not passed.

**The authority adapter.** Add
`shikigami-core/src/Shikigami/Trust/LocalOperator/Authority.hs`: a pure policy and a thin
wrapper that appends the decision before returning.

```haskell
data LocalSelection = LocalSelection {agent :: !AgentName, principals :: !(Set Principal), grant :: !LocalGrant}
data LocalDecision = Approved !GrantDigest | Refused !RefusalReason
data RefusalReason
  = ForeignPrincipal | CapabilityNotGranted !CapabilityId | RuleNotGranted !RuleName
  | RepositoryNotGranted | OutsideGrant !Text   -- the action's tag, for kinds no plan has granted yet
decideLocalAction :: LocalSelection -> Principal -> Action -> LocalDecision
localOperatorAuthority :: RecordContext -> ActionRecord -> LocalSelection -> Authority
```

`decideLocalAction` approves `UseCapability` for granted capabilities, `ReadWorkspace` and
`WriteWorkspace` on the granted repository, and `ExecuteWorkspace` for granted rules. It
refuses any other principal with `ForeignPrincipal`. It refuses `RunDeclaredTool`,
`LaunchCodingAgent`, `EmitOutput`, `RequestApproval` and `DelegateRun` with `OutsideGrant`.
Each of those is extended by the plan that owns the effect: EP-2 for `LaunchCodingAgent`,
EP-3 for `RunDeclaredTool`, and EP-8 M2 for `EmitOutput` and `RequestApproval` with its
local adapters. The wrapper appends one `authority.decided` entry per decision. It maps
`Refused` to EP-8's policy-denied failure with a readable reason, and returns EP-8's
service-unavailable failure if the append fails, so an unrecorded action never proceeds
(invariant K3 of MasterPlan 22).

**Record kinds.** This plan defines no ledger type and no ledger file. It appends to EP-8's
`ActionRecord` and owns these kinds and their typed payload constructors, in
`shikigami-core/src/Shikigami/Trust/LocalOperator/Records.hs`:

```haskell
authorityDecided :: Action -> LocalDecision -> RecordEntry        -- authority.decided
authorityGranted :: LocalGrant -> RecordEntry                     -- authority.granted
workspaceOpened  :: RunWorktree -> RecordEntry                    -- workspace.opened   (milestone 2)
processFinished  :: RuleName -> LaunchResult -> RecordEntry       -- process.finished   (milestone 2)
commitCreated    :: RunBranch -> Revision -> Revision -> Natural -> RecordEntry  -- commit.created (milestone 2)
```

Payloads never contain tool inputs, file contents or credentials. EP-8 chooses the store:
durable runs write to PostgreSQL beside the run evidence, and the database-free
`shikigami-run-behavior` writes a file. `Contained` and `MultiTenant` runs append to the
same record through whatever EP-8 composes for them.

**Configuration and composition.** Add Settei keys in `Config.hs`, documented in
`docs/operations/configuration.md`: `trust.tier` (`SHIKIGAMI_TRUST_TIER`, default
`contained`), `trust.local_operator.approvals_file` and `trust.local_operator.state_dir`
(absent means the XDG defaults; the state directory holds grants, worktrees and locks).
Resolution refuses `multi-tenant` with `authorization.actions.mode=disabled`.

Add `shikigami-agent/src/Shikigami/Agent/Trust.hs`:

```haskell
data WorkspaceArgument = WorkspacePath !FilePath | WorkspaceRepository !RepositoryId
parseWorkspaceArgument :: String -> Either Text WorkspaceArgument  -- "mori://" selects an identity
lightComposition :: Log.Logger -> AppConfig -> Interaction -> ActionRecord -> IO (Either TierError TierComposition)
runSubject :: AgentDecl -> WorkflowId -> Maybe WorkspaceArgument -> IO (Either TierError RunSubject)
```

`Contained` and `MultiTenant` keep what each executable does today, and there is no single
"today's behavior". For the light commands, `lightComposition` resolves every subject to
the values they hard-code now: EP-8's deny-all authority, `oneOffCapabilityRuntime`, no
host and `unavailableLauncher`. In
`shikigami-workers/src/Shikigami/Workers/Command/Worker.hs`, wrap the values built today
(the authority selected by `authorization.actions.mode` and
`configuredWorkspaceHostWithTransfers`) in a `TierComposition` whose `resolve` ignores the
repository, read `AgentRunDeps` fields from the resolved runtime, and refuse
`local-operator` with a message naming the two light commands. Conversations
(`Shikigami.Agent.Conversation`) and the server's objective handlers keep their own
deny-all authority and are not touched.

For `LocalOperator`, `resolve` loads the approvals file, selects the repository from the
subject (default: the current Git toplevel, and only when the declaration requests
overlays), calls `resolveGrant`, and returns `localOperatorAuthority` with the unchanged
`workspace.read` revision 1 provider scoped to that checkout and a catalog `authorize`
that admits installed descriptors. It returns `OutputsUnavailable` when the declaration
lists sinks: outputs under `LocalOperator` arrive with EP-8 M2's `local.report` adapter,
and until then a declaration with Kikan sinks is refused when it is resolved, before any
model call. This plan adds no sink refusal inside the authority.

`AgentRun.hs` and `RunBehavior.hs` take their authority and capability runtime from the
resolved `TierRuntime`; `shikigami-run-behavior` has no workflow, so it mints an
invocation-scoped id for its subject. `shikigami-agent-run` gains `--payload JSON` (reusing
`Shikigami.Agent.Payload.payloadArgument`) and `--no-confirm`, and, under `LocalOperator`,
ends by printing the repository, run id and record counts with the inspection command. Add
`agents/local-maintainer.dhall` (Skill, `workspace.read`,
`identity = Some { principal = "principal_local_maintainer" }`) and
`agents/skills/local-maintainer/SKILL.md`, which tells the model to do the payload's task
and answer from files it read.

Add the light executable `shikigami-local` (`shikigami-agent/app/local/Main.hs`, listed in
`agentRoles`). `shikigami-local approvals` validates the approvals file when one exists and
prints repositories with resolved sources, each explicit approval's capabilities, rules
(program, deadline, output limit) and budget, and each stored grant with its digest, agent,
repository and confirmation time. `shikigami-local revoke <digest>` deletes a stored
grant. `shikigami-local ledger [--run ID] [--refusals] [--limit N] [--json]` prints action
record events oldest first through EP-8's reader; it is the operator's single view of the
record in the stock composition.

Write the next free ADR in `docs/adr/`, "Authority and containment are selected by trust
tier, and the local operator grants a declaration once", amending ADR-36 as EP-8 restated
it: `Contained` keeps deny-all when no authority is composed, and `LocalOperator` decides
exactly what the operator granted and records every decision. Add a pointer to it in
ADR-36's References. Replace the "Current limitation" paragraph in `docs/user/cli.md` and
start `docs/user/local-operator.md` with the walkthrough from Concrete Steps.

### Milestone 2: worktree, launcher and mutating tools

Add `shikigami-core/src/Shikigami/Workspace/Local.hs` (split if it grows) with four parts.

*Worktree provider.* `openRunWorktree` derives everything from the run and the repository:
suffix = first twelve hex digits of `versionedDigest "shikigami.local-worktree/1"` over the
workflow id and the repository identity, so one run may hold a worktree in each of several
repositories; root =
`<state>/worktrees/<namespace>-<project>/<suffix>`; branch = `shikigami/<agent>/<suffix>`
(checked with `git check-ref-format --branch`). It resolves the approved `base` (default
`HEAD`) with `git rev-parse --verify <base>^{commit}` and runs `git -C <source> worktree add
-b <branch> <root> <commit>`. A second call returns the same `RunWorktree`; a branch at
another commit or a root on another branch is refused, never reset. A new worktree appends
a `workspace.opened` record entry.

*Placement.* The operator's approvals file chooses, per approved repository, where a run
works:

```haskell
data WorkspacePlacement
  = SeparateWorktree   -- default: a run branch in its own worktree, as described above
  | InPlace            -- work directly in the checkout, on its current branch
```

`InPlace` is for repositories nobody else is working in. On 2026-11-15 the user chose it for
the keiro services that EP-7 modernizes, and said no branches are needed there. For an `InPlace`
repository, `openRunWorktree` creates no worktree and no branch. It returns a `RunWorktree`
whose root is the checkout and whose branch is the checkout's current branch. It refuses to
start when `git status --porcelain` is not empty, when `HEAD` is detached, or when another
running run already holds that checkout. That last check uses an exclusive lock file under
`<state>/locks/`, named for the repository and holding the run id, released when the run
ends; the same run reopening the same repository holds its own lock. The
`workspace.opened` entry records the placement and the starting commit as `base`, so
`git -C <checkout> reset --hard <base>` is the documented undo. Commits land on the current
branch with the same `commit.created` record entry. The placement is operator authority, so a declaration cannot ask for `InPlace`
on a repository the operator did not mark that way.

*Host launcher.* `hostProcessLauncher` uses `System.Process` with `create_group = True`, a
cleared environment (`PATH`, `HOME`, `USER`, `LOGNAME`, `TMPDIR`, `LANG`, `LC_ALL` plus the
rule's `inherit` names), concurrent draining of stdout and stderr keeping the first
`outputLimit` bytes of each and counting the rest, and at the deadline `SIGTERM` to the
group followed by `SIGKILL` after five seconds. Add `unix` to `shikigami-core` if it is not
already a direct dependency.

```haskell
data LaunchRequest = LaunchRequest
  {program :: !ProgramPath, arguments :: ![Text], directory :: !WorktreeRoot, inherit :: ![Text], deadline :: !LaunchDeadline, outputLimit :: !OutputLimit}
data LaunchOutcome = Exited !ExitCode | DeadlineExpired
data LaunchResult = LaunchResult {outcome :: !LaunchOutcome, stdout :: !CapturedOutput, stderr :: !CapturedOutput, elapsedMs :: !Natural}
data CapturedOutput  -- abstract: capturedText, capturedDropped
data LaunchRefusal = LaunchUnavailable !TrustTier | LaunchFailed !Text
newtype ProcessLauncher = ProcessLauncher {launch :: LaunchRequest -> IO (Either LaunchRefusal LaunchResult)}
```

`WorktreeRoot` is constructed only by the worktree provider, so model text never becomes a
directory or program.

*Durable adapters* (`localWorkspaceAdapters :: LocalWorkspace -> [DurableAdapter]`). Each
`prepare` refuses a snapshot whose admission provider is not `shikigami.workspace.local/1` or
whose `filePolicy` is not `Just LocalHostFilesV1`, finds the worktree from the admission's
`WorkspaceRef.resource`, and asks the authority to decide `UseCapability` before any IO.
`workspace.edit@local-1` offers `read {path}` (`Observation`; content plus `contentDigest`)
and `replace {path, expected, content}` (`IdempotentMutation`, recovery `IdempotentEffect`:
it succeeds when the current digest equals `expected` or the file already holds `content`).
Paths pass `mkRelativePath` and `validWorkspacePath`; symlink components and `.git` are
refused; files keep the 256 KiB limit. `workspace.exec@local-1` offers `run {rule}`
(`IdempotentMutation`, recovery `UncertainEffect`); it also asks for `ExecuteWorkspace`,
runs the approved rule in the worktree through the tier launcher, appends `process.finished`,
returns exit code and bounded output, and lists approved rule names in its description.
`workspace.git@local-1` offers `status` and `diff` (`Observation`, bounded to 32 KiB) and
`commit {message, expectedParent}` (`IdempotentMutation`, recovery `UncertainEffect`), which
refuses unless `HEAD` equals `expectedParent` and something changed, then runs `git add -A`
and the commit from the Decision Log and appends `commit.created`. Git calls go through the
launcher with a 120-second deadline.

*Workspace host* (`localWorkspaceHost :: LocalWorkspace -> WorkspaceHost`). `load` refuses an
assignment without `selection.rootId`, opens the run worktree, freezes every `AGENTS.md`
blob at the base (`git ls-tree`, `git show`) with `mkInstructionBundle 65536`, and returns a
`WorkspaceAdmission` with provider `shikigami.workspace.local/1`, resource `<suffix>`, epoch
`initialRevision`, `filePolicy = Just LocalHostFilesV1` (new constructor, text
`local-host-v1`) and binding digest `versionedDigest "shikigami.local-binding/1"` over
repository, base, branch and resource.

The `LocalOperator` branch of `TierComposition.resolve` now installs the adapters, sets
`workspace = Just (localWorkspaceHost …)` and `launcher = hostProcessLauncher`, and scopes
`workspace.read` to the subject's worktree when one exists for its run and repository. When the
declaration requests a mutating tool, `AgentRun.hs` calls `enrollRootRun` first with an
envelope mapping `budget` to `ModelAttempts`, `ToolAttempts` and `Tokens`, `ActiveWork` 1,
`LifetimeDescendants` 0, `CostMicroUsd` `ExplicitlyUnbounded`, and cutoff `now + minutes`
(the grant's budget, or `defaultBudget` when the grant states none);
check the dimensions the Skill executor reserves and record any correction in the Decision
Log. The command finishes by printing the run branch and its commits from the action record.
Extend `agents/local-maintainer.dhall` to all four capabilities and its `SKILL.md` to read
before replacing, run an approved rule when asked, and commit once with a Conventional
Commits message using the `expectedParent` from `status`. Add a "Local-operator worktrees"
section to `docs/operations/workspaces.md` and finish `docs/user/local-operator.md`.

### Pre-release recheck and the workflow gate

No workflow body should change: no step or patch is added under
`shikigami-core/src/Shikigami/Agent/` or `.../Flow/`. Before merging each milestone, recheck
and record (dated, in the Decision Log) the pre-release facts from
`docs/workflow-versioning.md` — no `git tag`, no deployment, no journals or wire consumers —
and run `just keiro-gate`. If a body change proves necessary, follow
`docs/workflow-versioning.md` and capture the `keiro-diff` finding under ADR-27.


## Concrete Steps

Work in `/Users/shinzui/Keikaku/bokuno/shikigami` inside the dev shell (`nix develop` or
direnv). Start PostgreSQL with `process-compose up` in another terminal, then:

```bash
just create-database
cabal build shikigami-agent:exe:shikigami-agent-run shikigami-agent:exe:shikigami-local
```

Milestone 1 needs no approvals file: the first run asks once. Milestone 2 runs a command
rule, and rules are approved only in the approvals file, so write it before milestone 2
(rules are the operator's choice; this one builds fsrs-hs in its own dev shell). An
approvals entry for an agent and repository replaces the confirmation for that pair.

```dhall
-- ~/.config/shikigami/local-operator.dhall
let L = /Users/shinzui/Keikaku/bokuno/shikigami/schema/LocalOperator.dhall

in  L.Approvals::{
    , repositories = [ L.Repository::{ identity = "mori://shinzui/fsrs-hs" } ]
    , agents =
      [ L.AgentApproval::{
        , agent = "local-maintainer"
        , repository = "mori://shinzui/fsrs-hs"
        , capabilities = [ "workspace.read", "workspace.edit", "workspace.exec", "workspace.git" ]
        , rules = [ L.Rule::{ name = "build", argv = [ "nix", "develop", "--command", "cabal", "build", "all" ], timeoutSeconds = 1800 } ]
        , budget = L.Budget::{ modelAttempts = 30, toolAttempts = 120, tokens = 3000000, minutes = 60 }
        }
      ]
    }
```

Check it with `cabal run -v0 shikigami-agent:exe:shikigami-local -- approvals`, which
prints the repository with its resolved source, the approval with the resolved `nix`
path, deadline, output limit and budget, and every stored grant.

Milestone 1, with no approvals file yet. Run the first command in a terminal and answer
`y`; run it a second time and expect no question. The third command declares a Kizashi
sink and must be refused before any model call:

```bash
cabal run -v0 shikigami-agent:exe:shikigami-agent-run -- --set trust.tier=local-operator \
  --agent agents/local-maintainer.dhall --workspace mori://shinzui/fsrs-hs \
  --payload '{"task":"Summarize what src/ implements and which module owns scheduling."}'
cabal run -v0 shikigami-agent:exe:shikigami-agent-run -- --set trust.tier=local-operator \
  --agent agents/triage-note.dhall --payload '{"ticket":"Login page returns 500 after deploy"}'
cabal run -v0 shikigami-agent:exe:shikigami-local -- ledger --limit 20
```

```text
local-operator: local-maintainer asks for
  repository   mori://shinzui/fsrs-hs (/Users/shinzui/Keikaku/bokuno/fsrs-hs)
  placement    separate worktree on a run branch
  capabilities workspace.read
  budget       default (30 model attempts, 120 tool attempts, 3000000 tokens, 60 minutes)
Grant this declaration? [y/N] y
local-operator: granted 5c1e0b7a92d4 — revoke with: shikigami-local revoke 5c1e0b7a92d4
…
local-operator: triage-note declares outputs this composition cannot deliver: kizashi-signal
```

The same first command with standard input redirected from `/dev/null` and no stored grant
must refuse with `no stored grant for this declaration; run it once in a terminal`.

Milestone 2 (the task deliberately asks for one unapproved rule):

```bash
cabal run -v0 shikigami-agent:exe:shikigami-agent-run -- --set trust.tier=local-operator \
  --set 'behavior.harness={"maxModelTurns":24}' \
  --agent agents/local-maintainer.dhall --workspace mori://shinzui/fsrs-hs \
  --payload '{"task":"Add a Building section to README.md derived from flake.nix, the cabal file and the Justfile. First try rule release; if refused, continue. Run rule build, then commit."}'
```

```text
local-operator: repository mori://shinzui/fsrs-hs (/Users/shinzui/Keikaku/bokuno/fsrs-hs)
local-operator: worktree ~/.local/state/shikigami/worktrees/shinzui-fsrs-hs/3f9c2a7e1b04 on shikigami/local-maintainer/3f9c2a7e1b04 from a53bcfe
local-operator: commit 9d1e0c4 on shikigami/local-maintainer/3f9c2a7e1b04
local-operator: record 17 approved, 1 refused — shikigami-local ledger --run <workflow-id>
```

```bash
git -C /Users/shinzui/Keikaku/bokuno/fsrs-hs log --format='%h %s%n%(trailers)' -1 shikigami/local-maintainer/3f9c2a7e1b04
cabal run -v0 shikigami-agent:exe:shikigami-local -- ledger --run <workflow-id> --refusals
```

```text
2026-…Z refused execute_workspace workspace:shinzui/fsrs-hs/release  rule release is not approved for local-maintainer
```

Hashes, paths and counts above are illustrative; compare the shape.


## Validation and Acceptance

Automated checks are Haskell tests in the owning packages. In `shikigami-core/test` (wired
into `Main.hs`), `TrustTierSpec`, `LocalOperatorApprovalsSpec`, `LocalOperatorGrantSpec`,
`LocalOperatorAuthoritySpec` and `LocalWorkspaceSpec` prove: tier text round-trips and
unknown text is refused; a valid approvals file decodes, a missing one is empty, and each
invalid case returns its own `ApprovalsError`. `resolveGrant` uses an approvals entry
without prompting, returns a stored grant without prompting, prompts exactly once when
`Interactive` and saves a yes, returns `OperatorDeclined` on a no and `NoStoredGrant` when
`Unattended`; a one-character change to the declaration changes `grantDigest`; a declaration
asking for more than its approvals entry lists yields `RequestExceedsApproval`.
`decideLocalAction` approves granted `UseCapability`, workspace reads and writes on the
granted repository and granted rules, and refuses an ungranted capability, an ungranted
rule, a foreign principal, and `EmitOutput`, `LaunchCodingAgent` and `RunDeclaredTool` with
`OutsideGrant`; each decision appends exactly one `authority.decided` entry and a failing
record append yields the service-unavailable failure. Resolving one subject twice yields
the same grant and worktree, and resolving two repositories for one run yields two
worktrees. On a temporary Git repository: opening a worktree twice yields
one worktree on the derived branch and a conflicting branch is refused; `replace` applies,
replays idempotently and refuses `../`, absolute paths, symlinks and `.git`; `commit` with a
stale `expectedParent` is refused and a real commit carries both trailers; the launcher
returns `DeadlineExpired` for `sh -c 'sleep 30 & sleep 30'` under a one-second deadline with
no group member surviving, and bounds a 10 MiB writer while reporting dropped bytes. In
`shikigami-agent/test`, `CommandSpec` checks `shikigami-local --help`,
`parseWorkspaceArgument`, and that the default tier resolves to the deny-all authority with no
workspace host.

```bash
cabal test shikigami-core:test:shikigami-core-test --test-options="-p '/TrustTier/ || /LocalOperator/ || /LocalWorkspace/'"
cabal test shikigami-agent:test:shikigami-agent-test
just haskell-conventions
just domain-value-types
just keiro-gate "$(git merge-base HEAD master)"
```

Milestone 1 is accepted by real runs on this Mac, with no approvals file present: the first
read-only run asks once and answers from the actual fsrs-hs sources; the second run does not
ask; after a one-line edit to `agents/local-maintainer.dhall` the run asks again; the same
command with no terminal and no stored grant refuses without calling the model.
`shikigami-local ledger` shows one `authority.granted` entry and approved
`authority.decided` entries for `workspace.read` with the run id, and `shikigami-local
approvals` lists the stored grant. The `triage-note` run is refused when resolved, naming
its Kizashi sink, with no model call and no Kikan service contacted. The read-only command
without `--set trust.tier=local-operator` fails with today's deny-all message.

Milestone 2 is accepted by the real run above: `git -C /Users/shinzui/Keikaku/bokuno/fsrs-hs
branch --list 'shikigami/*'` shows the run branch; its tip changes `README.md`, has the
worktree base as parent and carries both trailers; the operator's checkout and current branch
are untouched; the run's record contains `workspace.opened`, `process.finished` for `build` with
its exit code, `commit.created`, and the refused `release` rule, and `shikigami-local
approvals` shows `release` was never approved.

Out of scope, for later plans: local outputs and approval channels (EP-8 M2), declared
tools in the confirmation (EP-3), the one-file routine-agent form and local schedules (EP-9,
`docs/plans/134-declare-and-run-a-routine-agent-with-one-file-and-one-command.md`), a
worktree cleanup command, cross-process resume of an interrupted local run, and
`LocalOperator` in `shikigami-worker` (EP-2).


## Idempotence and Recovery

Loading approvals is read-only and the action record is append-only. Saving a grant is
idempotent: the file is named by its digest. `shikigami-local revoke <digest>` removes a
stored grant, after which the next interactive run asks again. `openRunWorktree` is
idempotent per run and repository and refuses rather than resets conflicts. Every `shikigami-agent-run`
invocation is a new run with its own branch, so retries never disturb earlier work. Discard a
run with `git -C <source> worktree remove <root>` and `git -C <source> branch -D <branch>`.
The action record is never rewritten.

An interrupted run leaves its accepted execution in PostgreSQL. A possibly applied `replace`
replays idempotently; an unrecorded `run` or `commit` is `UncertainEffect`, so the executor
does not repeat it. Inspect the worktree (`git status`) and the record, then re-run the task
as a new run; this plan adds no cross-process resume. Unsetting `trust.tier` (or setting
`contained`) restores what each executable does today; stored grants are ignored outside
`LocalOperator`.


## Interfaces and Dependencies

This is EP-1 of
`docs/masterplans/22-rebuild-shikigami-as-a-kernel-where-use-cases-are-declared-not-coded.md`
and has one hard prerequisite: milestone M1 of EP-8
(`docs/plans/133-give-the-kernel-its-own-action-record-output-approval-and-trigger-contracts-with-local-adapters.md`),
which supplies `Shikigami.Authority` (`Action`, `Authority`, the deny-all default) and
`Shikigami.Record` (`ActionRecord`, `RecordEvent`, `RecordEntry`, its reader). It needs host
`git`, the `mori` CLI (only when `source` is omitted or a path's identity is looked up), the
local PostgreSQL of `shikigami-agent-run` and the operator's `behavior.provider` credential.
It imports nothing from `mori://shinzui/kikan-en/packages/kikan-en-contract`. No Kikan-En,
Shomei, Kawa, Kizashi, Rei or Danwa service is contacted.

Published interfaces: `Shikigami.Trust.Tier.TrustTier`;
`Shikigami.Trust.Runtime.TierComposition`, `RunSubject`, `TierRefusal` and `TierRuntime`
(add a field per new tier-dependent behavior), `ProcessLauncher`, `LaunchRequest` and
`LaunchResult`; `Shikigami.Workspace.Local.openRunWorktree`, `RunWorktree` and
`hostProcessLauncher`; `Shikigami.Trust.LocalOperator.Approvals`,
`Shikigami.Trust.LocalOperator.Grant` (`LocalGrant`, `GrantRequest`, `grantDigest`,
`resolveGrant`, `GrantStore`, `Interaction`, `defaultBudget`), `decideLocalAction` and the
record kinds in `Shikigami.Trust.LocalOperator.Records`; and `shikigami-agent`'s
`lightComposition`. The schema file `schema/LocalOperator.dhall` is a public surface of
MasterPlan 22 that this plan owns.

EP-2 consumes `TierComposition.resolve`, `launcher`, `openRunWorktree` and
`TierRuntime.workspace` for coding-agent steps, extends `decideLocalAction` for
`LaunchCodingAgent`, and lifts the worker's refusal of `local-operator`. EP-3 extends
`GrantRequest` and `renderGrantRequest` with the declaration's tools, so one confirmation
covers them, and extends `decideLocalAction` for `RunDeclaredTool`. EP-8 M2 extends it for
`EmitOutput` and `RequestApproval` and removes the `OutputsUnavailable` refusal for kinds
its local adapters register. EP-4 resolves a subject per playbook step with that step's
repository. EP-9 builds the routine-agent commands on `resolveGrant`. All of them decide
through `authority` and append through `record`, so `shikigami-local ledger` shows them
without new inspection code.

Revision note (2026-11-15): cascaded the MasterPlan 22 review. The plan now depends on EP-8
M1, adapts the kernel authority port, appends to the kernel action record, resolves ports
per run and repository, and adds confirm-once grants.
