---
type: "Guide"
title: "Finite adaptive delivery"
description: "Run one objective through the compiled adaptive-delivery Flow with a finite resource root and cutoff."
docId: "DOC-19"
tags: ["objectives", "flows", "adaptive-delivery"]
generated:
  by: process:claude-code
  at: 2026-11-04T18:45:00Z
---

# Finite adaptive delivery

`adaptive-delivery` is a compiled Flow for one objective with a finite resource
root and cutoff. It can choose a small worker, permitted local coordinators and
descendants, bounded direct work, or a revised organization after a finding.
There is no recurring schedule or implicit publish, merge or deployment action.

Start from [the proof declaration](../../agents/proof/adaptive-delivery.dhall).
Configure the `adaptive` typed-decision model alias independently of worker
models, load its declared delegate roles, and grant their actual principals the
appropriate objective membership. Give local CoordinatingSkill roles their own
declared descendants and coordinator membership. The root's pinned transitive
catalog bounds the hierarchy; declarations and prompt text grant no additional
capabilities. See [model permissions](../operations/baikai-execution.md) and
[resource roots](../operations/execution-resources.md).

For example, create an objective to deliver one reviewed report with an exact
combined artifact identifier and a user-journey criterion. Assign a delivery
entry to the Flow's principal and admit the run with the separate
`objectiveId`/`assignmentId` selector described in [objectives](objectives.md).
The run must carry its admitted resource root. Set a finite cutoff and enough
model, tool and descendant capacity for both coordinator decisions and workers.
The default execution/advance capacities remain one; an operator may configure
positive bounded values after qualification.

A small checkpoint may choose one worker. An early result can request more
context in that same session, narrow an unfenced assignment, or create another
permitted role. A larger graph may put descendants beneath a local coordinator;
that coordinator acquires its own worker tool from its verified native child
association. The root reacts to retained checkpoint evidence. Silence and token
activity do not trigger model polling. New operator configuration never silently
enlarges an admitted catalog. A revoked owner or unavailable authority stops fresh
work while accepted references remain available for governed recovery.

Use the existing API or CLI to inspect the same objective:

```bash
shikigami --config config.json objectives inspect OBJECTIVE --after 0 --limit 20 --json
```

`adaptive` contains the current hierarchy/session references, accepted decision
rationale and operation tags, root reservations/usage, and coarse refusal/terminal
observations. Follow both `next` and `adaptive.next` while the objective revision
is unchanged. Instructions and result bodies stay protected. Unknown spending or
pending receipts are still held; waiting or a lease timeout does not refund them.

A successful worker result is an observation. An artifact-free reply cannot be
used as an artifact check. Record actual combined checks and user-journey evidence
through their owning verifier or authorized human-completer path. The Flow may
then propose the exact artifact/check set. Completion still requires the
objective owner's explicit acceptance at the matching revisions, with all
outstanding source work and uncertainty settled.

## Qualification and related automation

The [native qualification](../evidence/adaptive-delivery/native-qualification.md)
passes the full repository, recovery and refusal matrix using deterministic model
providers. Both exact combined repository trees pass their checks and the returned
pair's user journey; terminal replay preserves model bindings, call receipts and
settled root accounting. The separate actual-model trial under production
authorization and approved live limits remains open in
[plan 86](../plans/86-qualify-integrated-adaptive-autonomous-delivery.md).

An independently scheduled [watchdog](watchdog.md) can report quiet work or drift
using its own allowance. It has no authority to cancel or reorganize your workers.
[Unrequested-work proposals](unrequested-work.md) use a separate admission path;
only a configured standing policy can fund and dispatch their coordinator
automatically. Neither path enables recurring objective mandates, which remain
planned under plan 87.
