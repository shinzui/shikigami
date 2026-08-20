# 0017. Rotate to make a label static, rather than computing it

Date: 2026-08-20

Status: accepted


## Context

A keiro workflow journal matches records to steps by label, so two occurrences of
the same work in one journal generation must not write the same label. The
obvious way out is to make the label unique per occurrence by computing a suffix
from something at hand — a message id, an ordinal.

Shikigami did this twice. The conversation workflow ran every turn of a
conversation in a single immortal generation and wrote `record-user:<messageId>`,
`run-behavior-v2:<messageId>`, `record-assistant-and-reply:<messageId>`,
`turn-result:<messageId>` and `next-message:<ordinal>`. The agent-run workflow
does the same for `approval:<SinkKind>:<ordinal>` and `emit-signal:<label>`.

The cost is not the ugliness. A keiro-dsl workflow label is a compile-time wire
word matching `[A-Za-z0-9][A-Za-z0-9_-]*`, so a computed suffix — and in
particular a colon — cannot appear in `domain/*.keiro`. An undeclared label is
invisible to `just keiro-gate`, which means `keiro-dsl diff` cannot classify a
change to it and nothing refuses a change that would strand a durable identity.
`docs/workflow-versioning.md` listed "every per-message conversation label" among
the undeclarable families, which was most of that workflow's journal.

The second cost is the one that produced the suffixes in the first place: a
generation that holds every turn of a conversation grows without bound. Replay
and hydration get slower with every message and never recover.

`docs/plans/26-conversation-workflow-lifecycle-idle-timeout-journal-rotation-session-completion.md`
found that these are the same problem. The suffixes exist *because* several
turns share one generation. Rotating onto a fresh generation after every turn —
`Keiro.Workflow.continueAsNew` with a small seed — removes the reason for them:
a generation holds exactly one turn, each label is written at most once, and
every one of them becomes a plain wire word the specification can hold.


## Decision

**When a computed label suffix is forced by "several of these happen in one
generation", rotate the generation instead of computing the suffix.**

Concretely, for the conversation workflow: one turn per generation, sealed by a
terminal `continueAsNew` carrying a `ConversationSeed`. Three things follow, and
all three are the point rather than side effects.

* **The journal is bounded by construction, not by a tuning constant.** A
  per-generation replay is a fixed handful of steps no matter how long the
  conversation runs. An earlier draft of the plan proposed rotating every twenty
  turns; a cadence constant is a number somebody has to choose, defend, and
  revisit, and it leaves the labels computed anyway.
* **Every label becomes declarable**, so the body moves into `domain/*.keiro` and
  under the gate. This discharged the largest undeclarable-label family in the
  service.
* **The "which generation is live" question gets exercised on every turn**
  instead of rarely, so a bug in it fails in the first test rather than in
  production. That is not hypothetical: the ingress path had a hard-coded
  generation 0 (`loadStepIndex … 0`) that was harmless only because nothing
  rotated.

Rotating is not free and the cost should be stated plainly: one rotation per turn
writes a seed and marks the generation terminal. A conversation turn already
opens a database transaction per step and makes a model call. The rotation is not
the expensive part.

**Idempotency must not be resting on the label.** It was not here, and that is
what made the change safe: replay identity for a redelivered message comes from
kioku's turn ids (`danwa:user:<messageId>`, `danwa:assistant:<messageId>`), which
are unchanged. Check this before removing a suffix — if the label *is* the
identity, removing it silently converts a dedupe into a double write.

**A consumer that used the label to identify the occurrence needs another key.**
With `turn-result:<messageId>`, the label answered "the result for this message".
With the bare `turn-result` it does not. `loadConversationResult` now matches on
`ConversationTurnResult.userTurnId`, which is derived from the message id, and
searches the live generation and the one a rotation just closed.


## Alternatives rejected

**Find a declarable spelling of the suffix.** Replace the colon with a hyphen and
declare `record-user-<messageId>`. It does not work: the suffix is still computed
at run time, so there is no finite label set for the specification to hold. This
is only a fix for a family whose suffix is a compile-time constant, which is what
separates the flow memory labels (`recall-<label>`, declarable) from the sink
labels (`emit-signal:<label>`, not).

**Leave the labels undeclared and only bound the journal.** Rotation alone would
have fixed replay cost while leaving the gate blind. Rejected for the reason
[ADR-0012](0012-a-declared-workflow-body-only-grows-behind-a-patch.md) gives for
preferring declaration: an undeclared label is stable only by convention, and
`just keiro-diff` cannot see a change to it. Taking the rotation without the
declaration would have been paying the cost and leaving the benefit.

**A rotation cadence of N turns.** Bounds the journal, keeps the suffixes, keeps
the gate blind, and adds a constant to argue about. Strictly worse on every axis
than one turn per generation.


## Consequences

Rotation and the label change are one change and must ship together. The labels
are only safe to make static *because* the generation holds one turn; shipping
the labels without the rotation would make two turns collide on `record-user`.

**A rotating body makes the resume options load-bearing in a way a non-rotating
one is not.** A generation created by `continueAsNew` has not journaled its own
patch decision when the resume worker first runs it, so a resume configured with
an empty active patch set reads the body's guard as `False` and takes the branch
the journal was *not* written under. This is
[ADR-0004](0004-one-options-value-and-a-checked-patch-set.md)'s rule with teeth:
before rotation, a mis-configured resume mostly replayed already-journaled
decisions and got away with it. Every conversation resume goes through
`shikigamiWorkflowResumeOptions`, including in tests.

Callers see a new outcome. `runWorkflowWith` returns `ContinuedAsNew` on the run
that accepts a message, and **that is not the run that processes it** — the
rotation seeds the next generation and unwinds, so the work is still owed.
`Shikigami.Agent.Conversation.driveConversationTurn` re-enters on a rotation,
consults the journal first so a rotation that followed its own turn is
recognised, and carries a budget so a pathological delivery pattern becomes queue
backpressure rather than a spin. Anything else that drives a rotating workflow
synchronously owes the same loop.

Growing the declared body still costs a patch guard every time, per ADR-0012.
That is what `shikigami-conversation-rotation-v1` is, and its `False` branch is
the old immortal loop with its suffixed labels — which is also why those labels
still appear in `docs/architecture/shikigami-domain-inventory.md`.

The general question to ask before computing a label: **what forces the
suffix?** If the answer is "several of these happen in one generation", rotation
may remove the question, and a bounded journal is worth having on its own.


## References

* `docs/plans/26-conversation-workflow-lifecycle-idle-timeout-journal-rotation-session-completion.md`
  — the plan, with the `keiro-diff` classification and the failing/passing
  transcripts.
* [ADR-0012](0012-a-declared-workflow-body-only-grows-behind-a-patch.md) — why a
  declared body only grows behind a patch guard, and why declaring is worth the
  cost.
* [ADR-0004](0004-one-options-value-and-a-checked-patch-set.md) — one options
  value, and where the active patch set comes from.
* [ADR-0018](0018-a-workflow-that-ends-is-re-keyed-by-epoch.md) — the other half
  of bounding an unbounded conversation.
* `docs/workflow-versioning.md` — the journal label inventory and the
  undeclarable families.
* `mori://shinzui/keiro-runtime-patterns/docs/keiro-durable-workflows` — the
  fleet's rule that rotation invalidates awakeable ids already handed out.
