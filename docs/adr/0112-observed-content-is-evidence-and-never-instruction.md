# 112. Observed content is evidence and never instruction

Date: 2026-11-04

Status: Accepted

## Context

[IR-21](../improvement-requests/propose-unrequested-work-from-observed-activity.md)
has an agent read chat messages and transcripts that nobody addressed to it and
decide whether they describe work. Anybody who can write to an observed channel can
therefore put text in front of that decision, including text that says to ignore
limits, target another repository, notify another channel or act for its author.
[ADR 0029](0029-model-routing-output-is-a-proposal-until-validated-against-journaled-authority.md)
already makes model output a proposal until validated. Here the input is hostile too,
so a prompt-level instruction not to obey the excerpt would be a request, not a
boundary.

## Decision

Authority at every stage comes only from operator-owned state and the run's recorded
identity: an observer allowance in process configuration for attention and spend, the
existing `objectives.agentCreation` grant for creating an objective, and a standing
policy for admitting one without a person. No stage reads authority from an excerpt,
a message's author or model output.

The assessment's output type is deliberately impoverished. `AssessmentOutput` has no
repository, principal, recipient, operation, instruction or URL field. It selects a
repository and evidence by position in lists the operator supplied and an action class
from the permitted list, and `ActionClass` has no publishing or merging constructor.
`validateAssessment` is the only minter of the sealed `Assessment` and looks the
repository identifier up from the operator's list, so the identifier never comes from
the model.

Recipients and principals come from configuration and the recorded identity. The
approval ask's channel is overridden by the run's journaled approval policy, and the
objective's owner is the run's principal. An ask links evidence by coordinate and
digest; excerpt text never reaches a ledger row, a notification, an objective or a
metric. It appears only in the decision's own journaled input, in a field named as
quoted evidence.

A result validator cannot see its input, so choice rules run in the Flow, and a bad
answer is a recorded `decision-refused` skip rather than a failed run.

## Alternatives

Prompt-level guardrails were rejected as the boundary. The signature does say the
excerpt is quoted evidence, because that improves answers, but no authority rests on
it. Trusting message authorship was rejected because the source's own identity claims
are not Shikigami authority and an author's seniority must not widen scope. A
per-message allow-list of permitted instructions was rejected because it would make
instructions in observed text meaningful at all.

## Consequences

Planted instructions are inert by construction rather than by filtering, and the
output schema itself can be asserted to contain no authority-bearing key. A new action
class, recipient strategy or source adapter is a code change, not a configuration
entry or something a model can suggest. Model-authored outcome and criterion text
still reaches a person and an objective's goal: it is untrusted description, which is
why those criteria are human-verifiable and the objective's template forbids
publication regardless of what they say.
