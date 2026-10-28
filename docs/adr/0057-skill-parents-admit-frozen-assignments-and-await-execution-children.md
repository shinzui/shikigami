# 0057. Skill parents admit frozen assignments and await execution children

Date: 2026-10-28

Status: accepted

## Context

An accepted execution must keep its original Skill, recalled input and offered
tool menu after a file or process configuration changes. Completed output must
remain readable after a provider binding retires. Existing agent journals still
need their coarse behavior step, while new model/tool work must release the
parent workflow advance.

## Decision

Fresh leaf Skills use the real `shikigami-durable-execution-v1` branch. The
parent retains profile/selection resolution, session opening and recall. A new
admission step freezes loaded instructions, the original Skill request rendering,
recalled input, selection, policy and exact tool bindings into a protected
snapshot. Its journal contains only the execution reference or bounded refusal.
It then awaits the registered execution child. Fixed supervisors, routed Skills
and Flows retain their existing orchestration owners. Old patch snapshots retain
the complete coarse `run-behavior-v2` branch.

Admission checks for an existing execution before loading a Skill or describing
tools. Matching assignment/run/session/identity/selection coordinates reuse that
snapshot even when the Skill path, process policy or provider menu has changed.
A racing admission rechecks the winner instead of replacing its snapshot.
Private model settings, invalid snapshots and oversized initial input refuse
before tool-menu acquisition. Native factories have a separate description
function which receives no accepted operation coordinates and invokes no tool
body. Capability menu leases use the existing guarded owner, are bounded by the
admission deadline, and are released before snapshot acceptance. Dispatch later
prepares only the unfinished tool with its trusted accepted operation context.

The parent bypasses live provider construction on its new branch. The child
performs fresh exact binding checks for unfinished work. After completion, an
identity-authorized protected result read needs no provider or Skill lookup.
The existing memory, session and sink steps retain their ownership and codecs.
Session completion records the pinned model id directly, without constructing a
replacement model merely to obtain display metadata.

The driver cancels unused observation promises when it rotates, completes or
waits on Approval. No pending promise is left behind by a generation that never
awaited it. Prepared model requests also validate API/context compatibility
before reservation and immediately before dispatch.

## Alternatives rejected

Reopening the Skill on every resume would reinterpret accepted work. Holding
menu leases across model turns would retain providers that no unfinished tool
needs. A description call cannot invent an accepted operation/idempotency key.
Rebuilding a retired provider merely to read an accepted result would defeat
durable replay. Replacing the old branch or silently disabling the new production
patch would leave one journal population unsupported.

## Consequences

The agent parent now uses the durable driver for eligible new Skills. Explicit
old-patch fixtures retain coarse lease/retry coverage; new fixtures exercise
pending binding replacement/refusal, completion after retirement, menu admission
and the real child/executor path. Conversation adoption, operator/declaration
policy configuration, ephemeral policy execution and remaining recovery
qualification are still open in plan 83. Workspace and objective provider gates
remain separately owned. Drain old resumers before activating new parent
populations and roll forward across this patch; an older binary cannot serve
the new branch.

## References

- [Plan 83](../plans/83-recover-durable-model-and-tool-turns-with-composed-policies.md)
- [Workflow versioning](../workflow-versioning.md)
- [ADR 0053](0053-execution-lifecycle-and-protected-replay-share-an-atomic-boundary.md)
- [ADR 0055](0055-execution-drivers-rotate-around-accepted-work.md)
- [ADR 0056](0056-context-summaries-are-accepted-accounted-model-operations.md)
