---
type: "Guide"
title: "Unrequested work"
description: "What a person sees when an agent proposes work nobody asked for, and what answering does."
docId: "DOC-18"
tags: ["objectives", "proposals", "triggers"]
generated:
  by: process:claude-code
  at: 2026-11-04T18:45:00Z
---

# Unrequested work

An agent can read a channel it was pointed at, notice something that looks like work, and
propose it even though nobody asked. Operators turn this on and set its limits; see
[Operating unrequested work](../operations/unrequested-work.md).

## What you see

A proposal reaches you as an approval request. It starts by naming the agent and saying
that nobody requested the work:

```text
Unrequested proposal from agent proposer (agent_shikigami_proposer). Nobody requested this work.
```

It then says when the proposal expires, what outcome is proposed, which repository and kind
of work it would be, and how confident the agent is. Evidence appears as coordinates (source,
subject, activity, time and a digest), so you can find the original message where it lives.
The message text itself is not repeated. The last lines are the commands to answer it:

```bash
shikigami resolve-approval TOKEN --approve
shikigami resolve-approval TOKEN --reject "reason"
```

The outcome and criteria were written by a model reading someone else's message. Treat them
as a description to check. They cannot change what the agent is allowed to do, whatever the
original message said.

## What your answer does

Accepting creates one objective whose owner is the proposing agent, linked back to the
proposal and the observed source. Nothing else happens: no budget is allocated, nobody is
assigned and no work starts. Staffing it is a separate decision.

Rejecting records that the subject should stay quiet for a period your operator configured,
so restating the same conversation produces nothing new until that period ends. Not
answering has the same effect once the proposal expires.

If you accept and the agent is no longer allowed to create objectives, the proposal is
marked refused and no objective exists.

## One conversation, one proposal

Proposals are per agent and per conversation or transcript. While one is waiting, or while an
accepted one's objective is still open, further messages in that conversation are recorded
and propose nothing. Redelivered messages and restatements by other people do the same.

## When nobody is asked

An operator can install a standing policy that lets covered proposals become objectives
without an answer. You are told afterwards: the notice says nobody requested the work and
names the proposal, the objective and the policy, with the commands to stop further
admissions and to cancel the objective.

An admitted objective has a coordinator and one assignment, and it ends at a reviewable
artifact. Its instructions forbid merging, deploying and publishing, and the policy gives the
coordinator no extra permissions, so a person still decides what happens to the result.

## Related

- [Triggers](triggers.md) for the stream matching a proposer uses.
- [Objectives](objectives.md) for what an accepted proposal becomes.
