---
type: Friction Entry
title: "The adaptive proposal vocabulary did not say the proposal is flat, that laterEvidence is a key, or how an assignment id is written"
description: "The first real adaptive decision was rejected at output validation, and the next at evidence validation, because the vocabulary text the coordinator hands the model left three shapes and one rule to be guessed."
generated:
  by: "claude-code/claude-fable-5-2"
  at: "2026-11-16T21:27:51Z"
frictionId: FRIC-89
status: "resolved"
impact: detour
kind: interface
origin: "mori://shinzui/shikigami"
affects: "mori://shinzui/shikigami"
affectedVersion: "unreleased"
plan: "docs/plans/131-shrink-shikigami-core-to-the-kernel-by-moving-or-retiring-use-case-subsystems.md"
workaround: "The vocabulary in Shikigami.Coordination.Workflow now states the twelve flat fields, that six are copied from proposalCoordinates, that laterEvidence is one short key, that an assignment id is the object the checkpoint writes, and that evidence comes only from checkpoint.objective.evidence. Three replays and one full run then produced a decision the checkpoint owner accepted."
tags:
  - "real-use"
resolution: "Commit 5a30047a states the proposal's flat shape, the laterEvidence key and the assignment id object in the coordinator vocabulary."
amended:
  - by: "claude-code/claude-opus-5-5"
    at: "2026-11-16T22:32:12Z"
    change: "Triage at plan 131 completion: resolved."
---
# The adaptive proposal vocabulary did not say the proposal is flat, that laterEvidence is a key, or how an assignment id is written

## Attempted

The first real adaptive-delivery decision, gpt-5.4-mini under the adaptive alias, on a coordinator funded by a standing policy.

## Encountered

decision-result-adapt journaled OutputValidationFailure and the run failed. Replaying the journaled input showed the model nested proposalCoordinates as an object instead of copying its six fields to the top level, wrote laterEvidence as a sentence where the decoder requires a whitespace-free EvidenceKey, and wrote assignment ids as bare strings where the codec is {value:text}. Once those decoded, adaptive-validation refused ObjectiveInvalidEvidence: the model cited the activity id mentioned in the assignment's instructions, and evidence must come from checkpoint.objective.evidence, which was empty. The rejected output itself is not retained, so the cause was only visible by replaying the call.

## Workaround

The vocabulary in Shikigami.Coordination.Workflow now states the twelve flat fields, that six are copied from proposalCoordinates, that laterEvidence is one short key, that an assignment id is the object the checkpoint writes, and that evidence comes only from checkpoint.objective.evidence. Three replays and one full run then produced a decision the checkpoint owner accepted.
