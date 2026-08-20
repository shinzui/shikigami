# 0015. A kioku write answers on two layers, and a journaled step keeps its bytes

Date: 2026-08-20

Status: accepted


## Context

Kioku is the agent memory and session store. The durable agent-run workflow opens
a session, records a learning, completes the session, and on the failure path
marks the session failed. Every one of those results was discarded with `_ <-` or
`void`, so a run could report success having opened no session and persisted no
memory, and nothing anywhere said so.

Fixing that surfaced two constraints the obvious fix does not satisfy.

**A kioku write answers on two layers.** `Kioku.Session.start`, `.complete` and
`.failSession` return `Eff es (Either SessionWriteError SessionId)`, and
`Kioku.Memory.record` returns `Eff es (Either MemoryWriteError MemoryId)`. This
repository runs them through a helper that adds its own `Either StoreError`. So a
discarded result was hiding two different facts: *the store could not be reached*
and *the store refused the command*. They are not the same failure. A transport
failure will succeed on the next attempt; a refusal — an invalid session lineage,
a space or actor mismatch — is rebuilt identically from the same journaled job on
every attempt and will be refused every time.

**Those four writes are journaled workflow steps.** Each runs inside `runStep`,
which appends the step's value to keiro's workflow journal and decodes it again
on replay. Widening the step's result type to `Either Text a` would encode as
`{"Right": …}`, and every workflow parked with a bare session-id string in its
`open-session` step would stop replaying.


## Decision

**Classify a kioku failure by layer, and give each layer the disposition it
deserves.**

* An unreachable store is rethrown into the workflow driver's `Error StoreError`,
  which `Shikigami.Agent.Workflow.runAgentRunWorkflow` already runs outside
  `runWorkflowWith`. It surfaces as that function's `Left storeError`, which the
  run-job worker's outcome table already maps to a retry. Nothing is journaled,
  because nothing durable happened.
* A refusal becomes a journaled value the caller turns into a
  `PermanentAgentRunFailure`, which the worker already dead-letters. Journaling it
  is correct: the same answer on replay is the honest answer.

**A journaled step value may gain a shape, but the value it already wrote keeps
its bytes.**

`Shikigami.Agent.Workflow.StepResult` follows
[ADR 0011](0011-defaulted-agent-fields-preserve-journal-codec-compatibility.md)
for the second time: `StepProduced` encodes as the bare value the step already
wrote, and only `StepRefused` introduces a key. The constraint that buys is that
the produced type must never itself encode as an object carrying `stepRefused`;
the three uses encode as a string, a string-or-null, and an empty array.

**A write that is allowed to continue after failing must say so in its name and
in the log.** `recordFailureLearningBestEffort` is the only such write on this
path — the run has already failed, and losing a note about why does not make the
recorded outcome wrong. It logs `agent.memory.best_effort_failed` on either
failure layer rather than vanishing. Anything else that discards a kioku result
is a bug, not a policy.


## Alternatives rejected

**Collapse both layers into the retrying arm.** It is what the originating plan
assumed, and it would make a permanently-invalid job burn its whole retry budget
before dead-lettering, for no chance of a different answer.

**Journal `Either Text a` directly.** Simplest to write, and it breaks replay for
every workflow parked before the change.

**Throw the refusal as an exception.** It escapes `runWorkflowWith`, which catches
only its own sentinels, and lands where the job processor has no typed answer for
it — so a permanent producer bug would look like a crashed worker.


## Consequences

A run that cannot record itself no longer reports success. That is the point, and
it means some runs that used to "succeed" now retry or dead-letter; the failures
they now surface were always happening.

Anyone adding a kioku call to a journaled path must bind *both* layers. Anyone
widening a journaled step's result type must check what the old bytes were first.
`Shikigami.WireCompatSpec` pins the `StepResult` encodings, so a derived instance
slipped in later fails a test rather than a replay in production.

The refusal layer is what makes this testable without breaking the store the
journal also needs: `Kioku.Session.validateLineage` rejects a negative delegation
depth against a perfectly healthy database, which is how
`Shikigami.AgentWorkflowSpec` drives it.
