# 121. Recurring mandates retain authority, checkpoint receipts and generation-owned wakes

Date: 2026-11-09

Status: Accepted

## Context

A schedule has no objective ownership, checkpoint watermark or finite recurring
authority. A successful finite run cannot silently authorize another run, and
replaying an old prompt would bypass replacement instructions. Existing objective,
session, resource and timer owners already supply those independent boundaries.

## Decision

`Mandate` owns an explicitly admitted, versioned recurring record and its checked
`MandateLifecycle` stream. Admission pins an objective, bounded assignment scope,
finite retained root, source descriptors, bounded cadence and finite expiry.
Commands require current objective coordination authority, immutable operation
keys and expected versions. Objective, source, root and scope remain immutable.
Schedule extensions require fresh exact authorization and cannot extend the root.

The first supported source is the whole current objective checkpoint. A bounded
read-only cycle retains that owner's exact accepted receipt and snapshot identity.
The source descriptor has an explicit named JSON codec; its wire name does not
depend on how many constructors a future source vocabulary contains.
It does not manufacture objective progress or launch a model to audit unchanged
state. Current instruction/criteria revisions and assignment owner fences are
reread at acceptance and commit. This adapter has no external effects to transfer;
an assignment replacement supersedes its observation rather than restoring the
old assignment. New effectful adapters must compose the existing coordinator,
session and execution admission owners and retain their accepted intents/receipts.
They cannot infer write authority from a mandate wake or lease expiry.

One objective lock covers current authority, mandate transitions, accepted progress
references and watermark/desired-due publication. A completed cycle leaves the
mandate active. Unchanged checkpoints retain the previous cycle and back off
within admitted limits. Root quantities and uncertain attempt holds remain with
the resource owner and are never copied into a workflow seed or replenished.

`RecurringObjective` restores a reference seed first and rotates at each wake.
`RecurringCheckpointCycle` supplies independently resumed fresh cycles. Both are
new native families, so existing workflow bodies and patch branches retain their
exact shape. Admission commits generation-zero input and the deployment patch
snapshot with the mandate, through the public native admission boundary.
Fresh children await their static ingestion label if discovered between spawn
and input publication. A restarted parent can publish the original admitted
reference without a missing-input failure stranding the child.

The existing objective listener owner provides event hints; the existing shared
100-row timer dispatcher supplies the backstop. Timer payloads carry mandate,
revision, generation and listener references. Progress persists desired wake
state before publication; replay repairs a lost publication without consuming the
checkpoint twice. Cancellation, expiry, authority loss and terminal objectives
close admission. Stops advance the fence, retire the exact generation's listener
and cancel its owned timer through public owners. Late hints cannot revive state.
Unknown work and cycle/checkpoint receipts remain independently of workflow GC.

`Mandate`, `MandateLifecycle`, `MandateLookup`, `RecurringObjective` and
`RecurringCheckpointCycle` are reviewed concept roots in the module ownership
inventory. `Server.Command.Mandates` is the operator transport over those owners.

## Alternatives rejected

A second cron reader would race the timer owner. Storing scheduled instructions
would create obsolete authority. Allocating a root per cycle would reset lifetime
limits. Rewriting the objective's progress for an unchanged observation would
turn bookkeeping into perpetual apparent progress. Declaring cancellation as
external settlement would lose unknown effects. Each is rejected.

## Consequences

Operators separately admit finite work and recurring checkpoint supervision.
The read-only modes are available without provider credentials or workspace
mutation. Broader source/action adapters require explicit trusted composition;
the recurrence record alone never enables protected effects. Rollout uses additive
schema/workflow declarations and the normal regeneration and conformance gate.

See [Plan 87](../plans/87-supervise-recurring-objectives-from-current-durable-checkpoints.md),
[operations](../operations/recurring-objectives.md) and
[native admission](0111-adaptive-delivery-carries-native-admission-and-reference-only-seeds.md).
