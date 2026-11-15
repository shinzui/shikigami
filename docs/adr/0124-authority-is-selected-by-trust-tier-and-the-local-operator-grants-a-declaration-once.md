# 0124. Authority is selected by trust tier, and the local operator grants a declaration once

Date: 2026-11-15

Status: accepted


## Context

[ADR 0123](0123-the-kernel-owns-its-action-vocabulary-authority-port-and-action-record.md) gave
the kernel one authority port and an action record, with deny-all when nothing is composed.
Every executable still chose its authority the same way: the worker from
`authorization.actions.mode`, and the light commands, conversations and server handlers by
hard-coding deny-all. So the most common case for this platform today, one operator running a
declared agent against their own repository on their own Mac, had no authority that could say
yes. `shikigami-agent-run` with `workspace.read` failed before acquiring its provider.

The operator is already the authority over their own machine and repositories. What was
missing was a way to say so that keeps the kernel's guarantees: a principal on every action,
one authority deciding each action before it happens, and a record of every decision.


## Decision

A process composes one *trust tier*, the setting `trust.tier`:

* `contained` (the default) keeps what each executable does today.
* `multi-tenant` is `contained` with a configured service authority required; the worker refuses
  it when `authorization.actions.mode` is `disabled`.
* `local-operator` makes the operator the authority. Only the light commands
  (`shikigami-agent-run`, `shikigami-run-behavior`) compose it; the worker refuses it until EP-2
  of MasterPlan 22 lets it run local work.

A tier selects who decides and how processes are contained. It never switches a kernel guarantee
off, and use-case code never matches on it. Ports are resolved per run and per repository through
`Shikigami.Trust.Runtime.TierComposition.resolve`, before anything is enqueued or a model is
called, so a refusal costs nothing.

Under `local-operator` a *grant* is what the operator allowed one declaration to do on one
repository. It comes from one of two places, in this order:

1. An entry for that agent and repository in the explicit approvals file
   (`schema/LocalOperator.dhall`, default `$XDG_CONFIG_HOME/shikigami/local-operator.dhall`). It is
   used as written and never prompted for; a declaration that asks for more than the entry lists
   is refused. Command rules for `workspace.exec` are approved only here.
2. A stored confirmation under the digest of the declaration and the repository, in
   `$XDG_STATE_HOME/shikigami/grants/`, mode 0600. When there is none and the command has a
   terminal, it shows what the declaration asks for and asks once. A yes is appended to the action
   record as `authority.granted` before it is stored; a no, or end of input, refuses.

A run with no terminal, which includes every worker and scheduled run, uses only these two and
refuses otherwise. Any change to the declaration changes its digest and asks again. The store is
outside every workspace, so an agent cannot write its own grant.

The local authority (`Shikigami.Trust.LocalOperator.Authority`) approves exactly what the grant
lists, for the agent's declared and compatibility principals only, and refuses every other kind of
action until the plan that owns it extends the policy. It is installed with `recorded`, so every
decision, refusals included, is in the record that `shikigami-local ledger` prints. Until EP-8 M2
adds local outputs, a declaration that lists a Kikan sink is refused when it is resolved.

This amends ADR 0036 as ADR 0123 restated it: the authority is selected by the tier, `contained`
keeps deny-all when no authority is composed, and `local-operator` decides exactly what the
operator granted.


## Alternatives rejected

**Require an approvals-file entry for every agent.** Rejected because a routine agent then needs
several hand-written files before it runs once; the user chose confirm-once on 2026-11-15.

**Grant by agent name alone.** Rejected because an edited declaration would silently inherit
authority it was never shown with.

**A permissive local mode that skips authorization.** Rejected because Kikan has no notion of a
tier that skips identity, authorization or the record, and a routine agent must be promotable to
the organization unchanged.

**Let the worker compose `local-operator` now.** Rejected for this step because a worker has no
terminal to confirm from and no local launcher yet; EP-2 lifts the refusal with both.


## Consequences

An operator runs a declared agent on their own repository with one command and one confirmation.
`shikigami-local approvals` lists every explicit approval and stored grant, `shikigami-local
revoke <digest>` deletes a confirmation, and `shikigami-local ledger` shows every grant and
decision.

A stored grant is keyed by the whole declaration, so cosmetic edits ask again. Confirmed grants
carry no command rules; until declared tools exist, `workspace.exec` needs the approvals file.

EP-2, EP-3 and EP-8 M2 extend the local policy for coding-agent launches, declared tools, outputs
and approvals. EP-9 builds the routine-agent commands on `resolveGrant`.


## References

* [ADR 0036](0036-external-agent-actions-require-fresh-exact-authorization.md) and
  [ADR 0123](0123-the-kernel-owns-its-action-vocabulary-authority-port-and-action-record.md) —
  amended here.
* [ADR 0003](0003-a-seventh-package-keeps-one-off-agent-runs-light.md) — why `shikigami-local`
  lives in `shikigami-agent`.
* [ADR 0025](0025-capability-overlays-are-requests-for-additive-model-tools.md) — a declaration
  requests capabilities; the operator satisfies them.
* [docs/plans/126-run-declared-agents-on-the-operator-s-own-machine-through-a-local-operator-trust-tier.md](../plans/126-run-declared-agents-on-the-operator-s-own-machine-through-a-local-operator-trust-tier.md)
  — the implementing plan.
* [docs/user/local-operator.md](../user/local-operator.md) — the operator walkthrough.
* Amended by [ADR 0126](0126-coding-agents-are-durable-workers-and-batch-qualification-is-tier-scoped.md)
  — `shikigami-worker` composes `local-operator` for queued coding-agent steps.
