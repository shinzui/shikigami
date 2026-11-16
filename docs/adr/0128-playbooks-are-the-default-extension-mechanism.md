# 0128. Playbooks are the default extension mechanism

Date: 2026-11-15

Status: accepted


## Context

MasterPlan 22 rebuilds Shikigami as a kernel where use cases are declared, not coded. Before
EP-4 a multi-step procedure (improve something in each of several repositories, wait for the
operator, learn from each) needed a Haskell flow registered in `Shikigami.Flow`. The flow
capabilities already gave such a body durable, keyed, replay-safe children: coding agents
([ADR 0126](0126-coding-agents-are-durable-workers-and-batch-qualification-is-tier-scoped.md)),
declared tools as steps
([ADR 0127](0127-declared-tools-carry-their-authority-and-reach-each-host-through-one-decision.md))
and approvals.


## Decision

Use cases are declared as Dhall playbooks (`schema/Playbook.dhall`) and run by one kernel
interpreter, `Shikigami.Playbook.Run`. A Haskell flow is written only for behavior a playbook
cannot express.

* **Format.** A bundle names its main playbook and holds siblings; `ForEach` and
  `RunPlaybook` name a sibling instead of embedding steps, because Dhall has no recursive
  types. Steps are `CodingAgent`, `Tool`, `Approval`, `Reflect`, `ForEach` and `RunPlaybook`.
  `shikigami-local playbook validate` refuses unknown siblings, cycles, duplicate ids and
  template references to nothing, naming the step.
* **Running.** The `Playbook` behavior names the bundle and the coding agent its steps use.
  The agent run loads, checks and pins the bundle (with its repository and relative path) in
  the step `playbook-admission`, then runs it as a flow body through the existing capabilities.
  Each effect is an existing keyed child family (`coding-agent`, `declared-tool`, `approval`)
  keyed by the step's path in the bundle (`each-repository.1.improve`), so the parent journal
  has only static labels and `just keiro-gate` checks all of them. A restarted run reads
  finished steps from the journal and reattaches to a launched one. This replaces the planned
  one-transition-per-generation `shikigami.playbook-run` workflow; the journal grows by two
  entries per step, and `continueAsNew` waits for a bundle large enough to need it.
* **Templates and provenance.** `{{run.NAME}}` reads the operator's payload, `{{NAME}}` an
  enclosing item, `{{learnings}}` the learnings so far. Items taken from step output
  (`FromStep`) are observed values: they may be prompt text and tool arguments, but never a
  workspace, so a repository always comes from the bundle or the operator. A tool argument is
  rendered into exactly one word with no shell, and the declared patterns, not the template,
  decide the call.
* **Repositories.** Under the local operator, each step's coding-agent runner is resolved for
  that step's repository: selected through the approvals, granted for the declaration once per
  repository ([ADR 0124](0124-authority-is-selected-by-trust-tier-and-the-local-operator-grants-a-declaration-once.md)),
  in its own worktree of the run.
* **Learning.** A `Reflect` step's read-only agent returns at most three bounded learnings and
  one suggestion. Learnings pass to later items in the run and are kept under the memory label
  `playbook-learnings` (one recall at the start, one write at the end, tagged `playbook` and
  the bundle's name). Suggestions become one coding-agent change of the bundle file on the run's
  branch of the repository that holds it; the change is kept only if it touches nothing but that
  file. A human reviews and merges the branch; nothing changes the current run.


## Alternatives rejected

**One child workflow per playbook with one transition per generation.** It needs run-time
labels or a seed cursor and duplicates the flow capabilities; static child families keyed by
step path give the same replay guarantee.

**Learnings written per Reflect step.** A memory label is a static journal step, so per-step
writes would need one generation each; one write per run keeps the labels static.

**Loading the proposed bundle inside the run.** The core has no port for reading another
worktree; the changed-file rule plus the printed `playbook validate` check leaves validation to
the reviewing human.


## Consequences

A new routine procedure is a Dhall file and a short declaration, not a Haskell change. The
Skill step (a delegated Skill agent) is not part of the format yet; a coding agent with
attached skills covers the campaign's needs. Tool steps run only in the run's own repository,
and an uncertain tool step ends the run instead of asking whether to retry. Run branches are
left in every repository a playbook touched, for the operator to review.


## References

* [docs/plans/129-execute-dhall-declared-playbooks-with-fan-out-approval-gates-and-learning-capture.md](../plans/129-execute-dhall-declared-playbooks-with-fan-out-approval-gates-and-learning-capture.md)
  — the implementing plan.
* [docs/user/playbooks.md](../user/playbooks.md) — the operator guide.
