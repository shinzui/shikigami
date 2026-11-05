---
type: "Guide"
title: "Durable objectives"
description: "Create and continue an objective across runs and conversations, then explicitly accept its integrated result."
docId: "DOC-16"
tags: ["objectives", "continuity"]
generated:
  by: process:codex-cli
  at: 2026-11-02T09:53:52Z
---

# Durable objectives

An objective keeps a goal, instructions, criteria, assignments, progress and
receipts in Shikigami's database. It needs no Rei endpoint. An assignment is a
versioned part of that goal with an owner. Several runs can contribute to one
objective; finishing a run or assignment does not complete the objective.

A memory session supplies recalled learnings. A conversation supplies recorded
turns. Neither replaces the objective's authoritative checkpoint. A Rei intention
can be an optional external reference. Optional [tracker bindings](objective-trackers.md) offer reviewed Rei proposals
and independent progress delivery. An A2A task mapping remains separate.

## Create and inspect

An operator must enable tracking and configure an operator identity; the HTTP
surface additionally requires a verified caller. See [operations](../operations/objective-tracking.md).

```bash
shikigami --config config.json objectives create --operation-key delivery-create --file create.json --json
shikigami --config config.json objectives inspect OBJECTIVE --after 0 --limit 20 --json
shikigami --config config.json objectives history OBJECTIVE --limit 20 --json
```

Use the returned `objectiveId` for `OBJECTIVE`. A create document has this shape:

```json
{
  "title": "Deliver a reviewed result",
  "goal": "The combined artifact meets its criteria",
  "instructions": "Preserve decisions and review the full journey",
  "criteria": [{"key":"review","description":"Review the combined artifact","kind":"HumanVerifiable","journeyRequired":true}],
  "external": []
}
```

Inspection exposes bounded metadata, references and current versions. It excludes
protected instructions, statements and result bodies. Follow `next` while the
revision stays unchanged; restart paging after a revision change. History retains
the original command actor and receipt, including after process restarts.

An objective can also begin as an [unrequested proposal](unrequested-work.md) that a person
accepted or a standing policy admitted. It links back to its proposal and observed source.

## Continue through a run or conversation

An authorized caller can associate a run using the separate `objective` selector
in [the run API](http-api.md). The owner checks current membership and assignment
ownership before atomically accepting the association and queue job:

```json
{
  "idempotencyKey": "delivery-part-a",
  "payload": {"request":"Continue the assigned work"},
  "objective": {"objectiveId":"OBJECTIVE","assignmentId":{"value":"part-a"}}
}
```

A declared Skill receives the native `objectives` tool only when its protected
admission permits it. An operator can authorize creation for an agent before it
has an objective. That first run can create a goal, plan its own assignments and
record progress. A later associated run reads that same goal even when learning
memory is unavailable. The model cannot choose an actor, resource root, durable
operation key or unrelated objective. Describing a tool grants no execution
permission. Ordinary Skills consume their assignments without coordinator grants.

An owner or coordinator can explicitly `BindConversation` using a recorded
Shikigami-owned conversation identifier. The next admitted turn retains its
binding; rebinding cannot retarget a previously accepted turn. Objective access
and permission to deliver conversation replies are separate checks.

Typed Flows use `Shikigami.Flow.Objectives` through static step labels. The
registered `objective-example` demonstrates creation and progress. These effects
use the same command owner as the native tool, HTTP and CLI.

## Update and recover

Commands require a stable operation key and expected revision. For example,
`command.json` may contain:

```json
{"tag":"SetNextAction","contents":["Review the combined artifact"]}
```

```bash
shikigami --config config.json objectives command OBJECTIVE --operation-key delivery-next --expected-revision 0 --file command.json --json
```

After an uncertain response, retry the exact key, revision and document. An
accepted retry returns its original receipt even after later revisions. Reusing
that key with changed input conflicts. For a new stale command, inspect current
state and reconcile deliberately before issuing a new intent. An unavailable or
unresolved result supplies no proof that an effect failed.

Worker checkpoints use assignment versions so unrelated sibling progress can
commit independently. Changing instructions, criteria, dependencies or ownership
invalidates affected old work; reverting text does not revive it. Conflicted
checkpoint intents need explicit reconciliation, not a silently advanced cursor.

## Complete or cancel

An owner or completer proposes completion against the exact current objective,
instruction and criteria versions, naming the integrated artifacts, checks and
limitations. Explicit `AcceptCompletion` is the terminal transition. Every
required criterion and journey must pass with evidence for those versions; all
required work must be done and linked uncertain effects must be settled.

Human-verifiable criteria require an authorized explicit attestation. Automatic
criteria require a trusted verifier-owned interpretation of retained results.
There is currently no general automatic verifier installed in the HTTP/worker
hosts. Worker success and model statements do not create a passing automatic
check. The qualification fixture uses explicit completer review of actual
retained outputs and labels this boundary.

Cancellation stops new objective work and retains existing receipts, unresolved
operations and late facts. It does not assert that external effects stopped.
Receipts and evidence currently have indefinite retention; do not delete their
owning stores to make a goal appear settled.

See [the objective API](../api/objectives.md) for exact command envelopes and
[the reproducible qualification](../../tests/objective-tracking/README.md).
