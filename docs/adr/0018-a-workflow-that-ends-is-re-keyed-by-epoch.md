# 0018. A workflow that ends is re-keyed by epoch

Date: 2026-08-20

Status: accepted


## Context

A danwa conversation is unbounded: a human may send another message a second or
a month after the last one. It ran as one keiro workflow instance that never
returned, so its kioku session stayed `status = "running"` forever and nothing
ever closed one. Session resolution only ever reused a running session, so that
set only grew — a resource leak and a correctness hazard at the same time.

`docs/plans/26-conversation-workflow-lifecycle-idle-timeout-journal-rotation-session-completion.md`
ends a conversation that has been idle past a configured window: a durable timer
signals the same awakeable the next human message would have signalled, the
workflow closes its kioku session and returns.

That raises a question the plan did not anticipate, and the natural assumption is
wrong. The plan said a later message would find "a terminated workflow, so
delivery fails and `runConversationTurn` runs a fresh `ConversationStart` — the
existing code path, unchanged." It is neither fresh nor unchanged. A keiro
instance is identified by its workflow id, and `conversationWorkflowId` was
`"danwa-conversation:" <> conversationId` — stable for the life of the
conversation. **Running a completed instance again replays its recorded
completion.** The new message was swallowed and the caller was handed the
*previous* epoch's turn result, reported as success:

```text
opens a new epoch after idle timeout, chaining session lineage: FAIL
  "the new epoch opens a different session"
```

Ending a long-lived workflow and continuing the thing it was serving are only
jointly satisfiable if the continuation is a different instance.


## Decision

**A lifecycle that can end and resume is keyed by an epoch, and the epoch is part
of the workflow id.**

An *epoch* is one workflow instance: from a conversation's first message (or its
first message after an idle timeout) until the next idle timeout. A conversation
spans several, chained through kioku session lineage.

* **Epoch 0 keeps the historical workflow id verbatim.** Only epoch 1 and later
  carry the `:e<n>` suffix. The workflow id is a durable identity and every
  instance that predates epochs is epoch 0, so nothing already journaled moves.
  A scheme that renamed epoch 0 would have been a wire change wearing a feature's
  clothes.
* **The live epoch is resolved before anything addresses the conversation**, and
  therefore cannot come from inside the workflow. It is a column on
  `shikigami.conversation_sessions`, the index the same plan added, so the
  ingress path answers it in one indexed read.
* **The workflow learns its own epoch by parsing its own id**
  (`conversationEpochOfWorkflowId`) rather than carrying a counter. A
  self-describing id cannot drift from a field somebody has to maintain, and it
  costs no new journaled state.
* **The advance is written inside the journaled terminal step, as an absolute
  value under `GREATEST`.** A journaled step is at-least-once. An increment run
  twice would not merely skip an epoch — it could move the live epoch past an
  instance ingress had already started addressing, orphaning it. Setting
  `max(existing, thisEpoch + 1)` cannot.
* **The next epoch names the one that closed.** `startSession` passes the
  completed session's id as kioku's `previousSessionId`, so `Session.getChain`
  walks a conversation across every epoch it has had. That field was
  unconditionally `Nothing` before, which was the only honest answer while
  nothing ever completed a session.


## Alternatives rejected

**Do not end the workflow.** Complete the kioku session on the idle timeout and
rotate into a dormant generation that awaits the next message. This needs no
epoch and no id change, and it fixes the session leak. It was rejected because it
leaves the instance immortal, which is one of the defects the work exists to
remove, and because a dormant generation still holds an armed promise — the
conversation is quiescent but not finished, and nothing can ever say it is.

**Ask keiro whether the current instance is terminal, and increment on the fly.**
Avoids the column. Rejected because "is epoch N terminal" has to be asked
repeatedly to find the live epoch, making every message walk the chain, and the
answer still has to be written down somewhere to be worth having.

**Key the instance by session id instead of an epoch counter.** The ingress path
does not know the session id either, so it is the same lookup with a less legible
key and no ordering.


## Consequences

Ending a workflow is now a three-part act — close the domain resource, advance
the key, return — and all three belong in the same journaled step. Splitting them
leaves a state where the session is closed but the next message still addresses
the completed instance, which is silent message loss rather than an error.

**Ingress paths gain a resolution step.** `deliverConversationInputFromApp` reads
the epoch before it can build a workflow id, in addition to reading the
generation. Both are resolved and neither is assumed; the previous code assumed
both, which was correct only for a workflow that neither rotated nor ended.

Not every identity moves with the epoch. The reply's sink-intent id is pinned at
epoch 0 (`conversationWorkflowId 0`), because it names an outbox row rather than
a workflow instance and its shape is asserted downstream. When a workflow id is
reused as a component of some other id, decide deliberately which of the two it
is naming.

A message that arrives while the ending is in flight is not lost. It finds no
armed promise, `Shikigami.Agent.Conversation` reports `ConversationBusy` — the
instance is still live — and the queue redelivers it as backpressure. By the
time it lands, the epoch has advanced and it opens the next one.

Anyone giving another long-lived workflow a real ending owes the same three
things: an epoch key resolvable from outside the workflow, an epoch-0 identity
that does not move, and an advance that is safe to repeat.


## References

* `docs/plans/26-conversation-workflow-lifecycle-idle-timeout-journal-rotation-session-completion.md`
  — the plan, including the failing transcript that forced this.
* [ADR-0017](0017-rotate-to-make-a-label-static-rather-than-computing-it.md) —
  rotation bounds the journal *within* an epoch; this record bounds the instance.
* [ADR-0015](0015-a-kioku-write-answers-on-two-layers-and-a-journaled-step-keeps-its-bytes.md)
  — why the session completion binds both failure layers.
* `mori://shinzui/keiro-runtime-patterns/docs/keiro-workflow-reliability` — the
  custom wake-source contract the idle timer satisfies, and the rule that a
  terminal journal refusal settles the wake source and delivers nothing.
