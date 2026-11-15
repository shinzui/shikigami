# 0126. Coding agents are durable workers and batch qualification is tier-scoped

Date: 2026-11-15

Status: accepted


## Context

[ADR 0040](0040-response-options-and-foreground-launches-have-separate-authority.md) keeps
Baikai's batch coding CLIs out of background work until an adapter proves descendant
cancellation, enforced deadlines, bounded retained output and reporter confinement. That gate
was written for one deployment shape: a shared worker running other people's agents, where
the coding CLI's native tools are an unconfined effect inside Shikigami's authority.

MasterPlan 22 adds trust tiers ([ADR 0124](0124-authority-is-selected-by-trust-tier-and-the-local-operator-grants-a-declaration-once.md)).
Under `local-operator` the operator runs their own declarations on their own machine against
their own checkouts, the same authority with which they would run `claude` or `codex` in a
terminal. The useful work there is "run Claude Code or Codex on this repository and keep the
result", and it must survive a worker restart without launching a second writer on the same
worktree. Baikai cannot resume an interrupted vendor session: the session id exists only in
the evidence record written after the process exits.


## Decision

A coding agent is a declared behavior arm, `CodingAgent`, that runs as a durable keyed child
workflow, `shikigami.coding-agent-step`, with the static steps `ingest-coding-agent-step`,
`admit`, `attempt` and `settle`. The parent agent run declares one `child coding-agent`
entry. The child id is the parent id, its generation and a call-site key, so a flow body can
call the capability any number of times with fixed step labels.

The launch is the kernel action `LaunchCodingAgent` (provider, workspace access, repository),
decided by the run's tier authority and recorded in the action record together with
`coding-agent.launched` and `coding-agent.settled` entries
([ADR 0123](0123-the-kernel-owns-its-action-vocabulary-authority-port-and-action-record.md)).

The attempt runs Baikai's own unattended CLI (`shikigami-agent-launch unattended agent run`)
detached in its own session, with its envelope, standard error and evidence record written to
a per-attempt directory outside the worktree. Shikigami copies no process engine: Baikai's
loader, operator ceiling, deadline, per-stream output bound and exit codes apply. Recovery is
a pure decision over what that directory holds: collect a complete result, reattach to a live
launcher inside its deadline plus a grace period, or end `Uncertain`. It never resumes a
vendor session and never launches a second attempt on its own.

A coding-agent result is a step outcome, `Completed`, `Failed`, `TimedOut` or `Uncertain`. It
is never a Baikai `Response` and never a `run-behavior-v2` success. Shikigami commits on the
run branch only on `Completed`; partial work is left uncommitted and summarized.

This amends ADR 0040's batch gate by scoping it to tiers. The deadline, output and
confinement qualification still applies to `contained` and `multi-tenant`, whose runner
refuses the step with `TierRefused` before any process starts. `local-operator` admits coding
agents under the operator's authority, with Baikai-enforced deadlines, bounded per-stream
capture, the operator's Baikai ceiling, the operator's one-time grant of the declaration, a
recorded `LaunchCodingAgent` decision, and the recovery policy above. ADR 0040's decision text
is otherwise unchanged; foreground launches and HTTP responses keep their separate authority.

`shikigami-worker` composes `local-operator` too, amending
[ADR 0124](0124-authority-is-selected-by-trust-tier-and-the-local-operator-grants-a-declaration-once.md),
which had it refuse the tier. A worker serves many runs, so it resolves each coding-agent step's
ports from the step itself: the declaration by name, the repository the run names (a queued run
carries it from `shikigami enqueue-run --workspace`), a stored or approvals-file grant (a worker
never asks), and the parent run's worktree. Its other runs keep the configured authority.

The process-spawning runner lives in `shikigami-core:local-host`
([ADR 0125](0125-host-process-adapters-live-in-a-public-local-host-sublibrary.md)), so both
the light commands and `shikigami-worker` can compose it.


## Alternatives rejected

**Call Baikai's runner in-process.** The outcome would live only in the worker's memory and be
lost when the worker died, leaving an orphaned agent still editing the worktree.

**Relaunch after a restart.** A second launch beside an orphaned first attempt interleaves two
writers. [ADR 0060](0060-safe-recovery-spends-new-attempts-and-retains-independent-receipts.md)
already forbids redispatching an uncertain effect because ownership changed.

**Lift ADR 0040's gate for every tier.** A shared worker running third-party declarations still
needs the confinement evidence ADR 0040 asks for.

**Per-key step labels in the parent.** They form an undeclarable label family that
`just keiro-diff` cannot gate (`docs/workflow-versioning.md`).


## Consequences

Operators can declare `CodingAgent` agents and run them with `shikigami-agent-run` under
`local-operator`; the run's branch holds one commit per completed step. `shikigami runs show`
reports the outcome, commit, changed files and evidence summary.

The attempt machinery (`Shikigami.Process.Attempt`) is parameterized over the launched command
and its result, so a long mutating declared tool can reuse it. An `Uncertain` outcome needs an
operator: the worktree and attempt directory are left for inspection.

The agent-run body gains a `child coding-agent` entry. Under the pre-release exception of
[ADR 0027](0027-the-first-release-establishes-one-clean-durable-baseline.md) this replaces the
unreleased baseline instead of adding a patch.


## References

* [ADR 0040](0040-response-options-and-foreground-launches-have-separate-authority.md) — the
  gate this record scopes to tiers.
* [ADR 0124](0124-authority-is-selected-by-trust-tier-and-the-local-operator-grants-a-declaration-once.md)
  — trust tiers and the one-time grant.
* [docs/plans/127-run-claude-code-and-codex-as-durable-harness-workers-inside-agent-runs.md](../plans/127-run-claude-code-and-codex-as-durable-harness-workers-inside-agent-runs.md)
  — the implementing plan.
