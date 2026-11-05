---
type: "Capability"
title: "Unrequested work proposals"
description: "Observe activity under an allowance, propose actionable work through durable human acceptance, and admit bounded objectives only under an explicit, revocable standing policy."
capabilityId: "CAP-31"
provider: "mori://shinzui/shikigami"
status: "shipped"
stability: "experimental"
since: "unreleased"
packages: ["shikigami-core", "shikigami-workers", "shikigami-migrations", "shikigami-server"]
interface: ["Shikigami.Flow.Initiative", "Shikigami.Initiative.Settings", "Shikigami.Initiative.Policy", "Shikigami.Initiative.Inspection", "shikigami proposals"]
tags: ["unrequested-work", "proposals", "standing-policies"]
generated:
  by: "process:claude-code"
  at: "2026-11-04T18:45:00Z"
requires: ["CAP-2", "CAP-3"]
evidence:
  - kind: test
    resource: "shikigami-workers/test/Shikigami/InitiativeAcceptanceSpec.hs"
    proves: "All nine IR-21 acceptance cases through real stream intake, run queue, approval resolution and admission."
  - kind: test
    resource: "shikigami-workers/test/Shikigami/StreamInboxSpec.hs"
    proves: "A skip or an evaluation root, candidate and job commit with the inbox row, and roll back together."
  - kind: test
    resource: "shikigami-core/test/Shikigami/InitiativeAssessmentSpec.hs"
    proves: "Model output selects only among operator-supplied options, and its schema has no authority-bearing field."
  - kind: test
    resource: "shikigami-core/test-postgres/Shikigami/InitiativePolicySpec.hs"
    proves: "Install validation, fresh-read revocation, expiry, window and total exhaustion, and digest pinning."
  - kind: example
    resource: "agents/proof/proposer.dhall"
    proves: "A stream-triggered proposer declaration."
---

# Unrequested work proposals

## Provides

An agent with an observer allowance reads bounded excerpts from `activity.v1` through closed per-source adapters. A pure pre-filter records irrelevant messages as bounded skips inside the inbox transaction and starts nothing. A candidate gets its own resource root and one run, whose `propose-work` Flow checks for an existing owner and the attention windows, asks one typed decision whether the excerpt describes work, and records a proposal keyed by observer and source subject.

By default the proposal parks on the durable approval child with its own expiry. Accepting creates one objective with a trusted link to its proposal and source; rejecting or ignoring it suppresses the subject for a declared period. An operator can install a revocable standing policy under which a covered proposal is instead admitted: one funded, staffed objective with an independent coordinator run, ending at a reviewable artifact.

## Adopt

Add an observer allowance, promote `agents/proof/proposer.dhall`, and follow [Operating unrequested work](../operations/unrequested-work.md). [Unrequested work](../user/unrequested-work.md) is what a person sees. `shikigami proposals` lists proposals, candidates and admissions, shows usage with exhaustion explicit, prunes old skips, and installs, revokes and lists standing policies.

Builds on [CAP-2: Durable trigger intake](durable-trigger-intake.md) and [CAP-3: Program and Skill execution](program-and-skill-execution.md).

## Evidence

- [InitiativeAcceptanceSpec.hs](../../shikigami-workers/test/Shikigami/InitiativeAcceptanceSpec.hs): All nine IR-21 acceptance cases through real stream intake, run queue, approval resolution and admission.
- [StreamInboxSpec.hs](../../shikigami-workers/test/Shikigami/StreamInboxSpec.hs): A skip or an evaluation root, candidate and job commit with the inbox row, and roll back together.
- [InitiativeAssessmentSpec.hs](../../shikigami-core/test/Shikigami/InitiativeAssessmentSpec.hs): Model output selects only among operator-supplied options, and its schema has no authority-bearing field.
- [InitiativePolicySpec.hs](../../shikigami-core/test-postgres/Shikigami/InitiativePolicySpec.hs): Install validation, fresh-read revocation, expiry, window and total exhaustion, and digest pinning.
- [proposer.dhall](../../agents/proof/proposer.dhall): A stream-triggered proposer declaration.

## Limits

- Observation runs only on `activity.v1`. Supported sources are the Intercom and transcript
  channels and a chat fixture; a new source is a code change.
- Assessment reads the current message only, with no thread history.
- Admission never publishes, merges or deploys, and no action class can express it. A policy
  grants no workspace, sink or tool authority.
- Policy totals are reservations rather than measurements. An underspending objective still
  consumes its whole envelope, and a reservation stays consumed if its admission fails.
- Admission proves one correctly funded, staffed and bounded objective. Whether that objective
  completes depends on the adaptive coordinator.
- A root that refuses the model attempt fails the evaluation run rather than recording a skip,
  so its candidate stays `evaluating`.
- Observers need a verified directory principal; compatibility identities cannot observe.
