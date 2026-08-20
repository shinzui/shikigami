# 0004. Durable workflow evolution goes through one options value and the checked patch set

Date: 2026-08-19

Status: accepted


## Context

Shikigami runs agent runs and Danwa conversations as Keiro workflows. Each step
is journaled to Postgres and replayed rather than re-executed, so an instance
that suspends — waiting on an approval, a timer, a child — is resumed later by
whatever code is deployed then. The runtime matches journal records to steps by
name and cannot tell that the body changed in between, so new code asking for a
name the old journal happens to hold silently receives the old value.

Keiro's answer is `patch`: a branch decision journaled once per instance and
replayed verbatim, so an instance keeps the code shape it started under while
fresh instances take the new one. Two properties of how it is wired decide
whether it works at all.

First, the deployed code declares its active patch ids in
`WorkflowRunOptions.activePatches`, and the plain `runWorkflow` entry point
passes `defaultWorkflowRunOptions`, whose set is empty. Every Shikigami workflow
ran that way, so a `patch` call added to the codebase would have read `False`
everywhere — including in the very deploy that introduced it. Worse, this fails
silently: the wrong branch is taken, not an error.

Second, the set is per-run rather than global. Nothing prevents a call site from
building its own `WorkflowRunOptions`, and a second value is a second answer to
"which patches are active". This is not hypothetical: future changes need one
place to combine patch activation with snapshot and telemetry policy. Plan 17
also demonstrates why the option types must be distinguished carefully: its
PGMQ delivery heartbeat belongs to `Keiro.PGMQ.JobContext.extendLease`, while
its slow-step budget changes `WorkflowResumeOptions.leaseTtl`. Neither is a
reason to set `WorkflowRunOptions.leaseHeartbeat` on a direct run.

There was also no written rule about which workflow-body changes are safe to
deploy over suspended instances, and one capability was already violating the
unwritten one: `emitSignal` named each emission's journal step from a per-run
counter, which is stable only while the surrounding code is frozen.


## Decision

**`Shikigami.Workflow.Versioning` is the only place Shikigami constructs
`WorkflowRunOptions`, and its active patch set is derived from the checked
specification rather than written in Haskell.**

Concretely:

* Every durable workflow run — the agent-run workflow, the conversation
  workflow, and the resume worker that re-invokes both — goes through
  `shikigamiWorkflowRunOptions` or `shikigamiWorkflowResumeOptions`. No
  production call site uses `runWorkflow` or `runWorkflowResumeWorker`.
* New workflow run or resume options are added to that module, not to a fresh
  value at a call site. Plan 17 leaves direct
  `WorkflowRunOptions.leaseHeartbeat` unset, uses
  `JobContext.extendLease` for the independent PGMQ delivery heartbeat, and
  sizes the central `WorkflowResumeOptions.leaseTtl` above its slowest
  synchronous step.
* `shikigamiActivePatches` is the union of the generated per-workflow
  `declaredPatches` sets. Adding a patch id therefore means declaring it in
  `domain/shikigami-agent-run.keiro` or `domain/shikigami-conversation.keiro`,
  regenerating, and passing `just keiro-gate`. There is no hand-maintained list
  that could drift from the gated one.
* The union is deliberate. Keiro's resume worker carries one `WorkflowRunOptions`
  for every workflow it drives, so there is no boundary at which a per-workflow
  set could be applied; activating an id for a workflow that never calls `patch`
  with it is inert.
* `docs/workflow-versioning.md` is the normative rulebook for when a change needs
  a patch at all, and `shikigami-core/test/Shikigami/WorkflowVersioningSpec.hs`
  is its executable half.


## Alternatives rejected

**Leave options at the call sites and be careful.** The failure mode is a
workflow taking the wrong branch with no error, discovered — if ever — as
corrupted durable state long after the deploy. "Be careful" is not a control for
a defect that is invisible at the moment it is introduced, and the plan-17
collision shows the pressure is real rather than theoretical.

**Write the patch set as a Haskell literal.** Simpler, and it is what
`docs/plans/24-flow-versioning-with-keiro-patch-and-continue-as-new.md`
originally specified — the plan predates plan 39, whose scaffold now emits
`declaredPatches` from the specification. Keeping a literal beside the generated
value would recreate exactly the two-lists-that-disagree problem this record
exists to prevent, and it would leave patch ids — persisted journal keys —
outside the evolution gate that classifies every other durable identity.

**Set the patch set per workflow with the generated `withDeclaredPatches`.**
More precise, and unreachable: the resume worker has one options value for all
workflows, so the precision would hold on first runs and evaporate on resumes,
which is the worse of the two possible inconsistencies.

**Declare the flow-name registry in the specification too.** Attempted while
implementing plan 24's fourth milestone and abandoned. keiro-dsl has no node kind
for it — a Shikigami "flow" is a Haskell function running inside the agent-run
workflow, not a durable node — so the declaration would be a generated artifact
no runtime path consumes, which
[ADR-0001](0001-declare-only-what-the-runtime-executes.md) forbids. The intent
was met structurally instead: `flowRegistry` and `registeredFlowNames` are two
projections of one list in `Shikigami.Flow`. (That list was an unexported
`FlowRegistration` when this was written; it is now `flowRegistry :: [FlowDef]`
itself, with `registeredFlowNames` projecting from it. The invariant is
unchanged — see [ADR-0013](0013-flow-bodies-reach-the-world-only-through-capabilities.md).)


## Consequences

Adding a patch id is now a specification change with a gate, not a one-line edit.
That is the point, and it costs a `just keiro-scaffold` plus a deliberate edit to
the hand-owned `KeiroConformance.Expectations`, which asserts each workflow's
patch set and never gets rewritten by the tool.

Fresh workflow journals now carry Keiro's reserved `__workflow_patches__` record,
because Keiro writes it only when the active set is non-empty and Shikigami's
became non-empty with the first patch. It is additive, but assertions that
compare an exact step-name set must filter it —
`AgentWorkflowSpec.loadLifecycleStepKeys` already does, alongside
`__workflow_completed__`.

A patch id must be spelled as a keiro-dsl wire word, `[A-Za-z0-9][A-Za-z0-9_-]*`.
Dots are not admitted, so the fleet-conventional `shikigami.some-change` form is
unavailable and ids read `shikigami-some-change-v1`. Choosing the legal spelling
before the first `patch:<id>` row exists is free; changing it afterwards is a
migration.

One operational property is worth knowing because it is not what most people
assume: a `patch` call resolves against the set recorded in the journal, not
against the options the current run was handed. `activePatches` therefore matters
at exactly one moment — when a generation starts fresh and records it — and a
differently-configured resume, or a rolled-back binary, cannot change an
instance's answer afterwards. Threading the same options through the resume
worker is correctness hygiene rather than the thing that makes `patch` work.

Retiring a patch is a two-part change that must happen together: delete the
guarded old branch from the body and remove the id from the specification in the
same commit, and only once no instance journaled before the patch can still
resume. Removing the id while the call remains flips every future instance to the
old branch, silently. For the same reason a deploy must not be rolled back across
a patch introduction: instances that journaled `patch:<id> = true` cannot be
served by code that no longer contains the new branch.


## References

* `docs/workflow-versioning.md` — the rules, the step-name inventory, and the
  worked `emitSignal` example.
* `docs/plans/24-flow-versioning-with-keiro-patch-and-continue-as-new.md` — the
  plan this record distils, including the probe evidence for the patch-id
  grammar.
* [ADR-0001](0001-declare-only-what-the-runtime-executes.md) — why the flow-name
  registry stayed out of the specification.
* [ADR-0012](0012-a-declared-workflow-body-only-grows-behind-a-patch.md) — the
  companion rule this record's Context gestured at and did not state: `keiro-dsl
  diff` demands a patch guard for *any* change to a declared body, appends
  included, so growing a workflow always allocates a patch id.
* `mori://shinzui/keiro-runtime-patterns/docs/keiro-durable-workflows` — the
  fleet standard: "A journaled step result is permanent. Never change the type a
  step decodes into: rename the step so it runs fresh, or guard the change with a
  stable `patch`."
* `mori://shinzui/keiro-runtime-patterns/docs/keiro-evolution-and-rollout` — the
  gate ladder and the durable-value rollout ordering rules.
