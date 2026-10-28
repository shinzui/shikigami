# 0059. Harness policy is frozen at admission and shared with ephemeral execution

Date: 2026-10-28

Status: accepted

## Context

Policy evaluation already governs accepted model/tool operations, but process
configuration, agent declarations and database-free commands need one supported
policy surface. A later configuration error or stricter default must not prevent
reading an already accepted assignment or rewrite its policy.

## Decision

The shared Settei declaration owns `behavior.harness` and its environment binding.
It decodes bounded, strict overrides into a validated operator policy. Agent
declarations add an optional `harness` value through the canonical Dhall schema.
Absent JSON fields decode to no override and remain omitted on encoding, keeping
historical declaration bytes stable.

New Skill admission narrows the operator policy with the journaled declaration.
Only new snapshots evaluate that policy result. Existing matching snapshots
retain their original policy even if a newly proposed policy is invalid.
Overrides can add restrictions and lower ceilings, retain more recent context,
and strengthen output requirements. They grant no model, tool or external action.
The old coarse workflow branch retains its existing semantics and labels.

The database-free command explicitly selects ephemeral recording. It uses the
same pure context selection, summary preparation, tool admission and output
validation policies. Each summary and repair consumes an ordinary model turn;
model/tool calls have bounded deadlines and payloads. Accepted request, response
and observation data remain in memory only, with protected display behavior.
Human permission requires the durable command. Nested model work is blocked by
a private empty registry, and uncertain effects have no automatic retry.

The durable one-off command accepts the normal child and drives that specific
child locally after the parent releases its workflow lease. It executes only
already accepted attempt references through the normal fenced executor; it does
not consume other queue entries. Background duplicates subsequently observe
committed attempts. Local driving has a bounded advance allowance and yields for
human decisions, live claims and unresolved effects. Existing workspace provider
lifetime and recovery limits remain unchanged.

## Consequences

Workers, conversations and both one-off commands receive policy from the shared
configuration owner. New declaration fixtures qualify the Dhall and replay
codecs; behavioral fixtures cover output repair, observation reuse, denial,
human refusal and one invocation of an uncertain native effect. The production
foreground driver is exercised by the real parent/HTTP PostgreSQL fixture.
Class-specific durable uncertainty recovery and bounded operator inspection
remain open in plan 83. No dependency bounds change.

## References

- [Plan 83](../plans/83-recover-durable-model-and-tool-turns-with-composed-policies.md)
- [Policy operations guide](../operations/durable-execution.md)
- [ADR 0011](0011-defaulted-agent-fields-preserve-journal-codec-compatibility.md)
- [ADR 0057](0057-skill-parents-admit-frozen-assignments-and-await-execution-children.md)
- [ADR 0058](0058-conversation-acceptance-and-wakes-retain-their-generation.md)
