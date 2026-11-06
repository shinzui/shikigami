# 118. The watchdog is an advisory Flow agent without intervention authority

Date: 2026-11-06

Status: Accepted

## Context

IR-19 requires an independent observer of active work, including stalled coordinators and
work whose own resource root has stopped. Protected transcripts and instructions must
not become either an observation source or authority to intervene.

## Decision

Run one bounded `watchdog-sweep` Flow inside the existing AgentRun workflow per scheduled
tick. The `Observe` capability resolves the configured identity before opening a retained
sweep claim. It reads owner-projected metadata and journals frozen classification inputs.
It can write only the advisory ledger for its own native sweep. It grants no objective
membership, worker command permission, cancellation or transfer authority.

Liveness classification is deterministic. Optional Drift uses the registered input-bound
program and the watchdog's own root; absence of its declared alias disables that optional
inventory without changing required slots in other Flows. Typed decision refusals preserve
liveness delivery. Its advisory interpreter retains policy-resolution refusal and raises it at
the Decision request, inside that boundary; required-decision Flows keep eager refusal.
Infrastructure evidence failures and cancellation propagate.

Findings reach configured recipients through Sink-owned addressed batches. The grant
result retains delivery policy and observation retains objective conversation bindings.
Each intent passes lifecycle, C11 and C13 admission; one static journal record, its outbox
intents and pending receipts commit together. A decoded finding view is not a finding seal.

## Alternatives

A separate workflow family or permanent observation loop would duplicate existing run,
resume and scheduling ownership. Mailbox delivery would put advisory output on the worker
command path. Capability overlays would widen intervention authority unnecessarily.

## Consequences

AgentRun declares `shikigami-watchdog-v1`; historical journals install an unavailable
interpreter with no watchdog or Drift application labels. Roll forward across this patch.
Readiness and liveness probes retain their existing meanings. Operators use existing
objective and worker commands when a finding warrants intervention.
