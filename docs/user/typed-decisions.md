---
type: "Guide"
title: "Typed decisions in Flows"
description: "Configure model aliases, run the typed decision example, and preserve governed results and attempt evidence on replay."
docId: "DOC-15"
timestamp: "2026-11-05T13:11:17Z"
tags: ["flows", "decisions", "models"]
generated:
  by: process:shikigami-documentation-refresh
  at: 2026-10-25T00:00:00Z
---

# Typed decisions in Flows

A compiled Flow can call a registered typed Shikumi program, validate its answer,
and branch through existing memory, routing, delegation, and sink capabilities.
Each decision selects an admitted model alias. The runtime pins the program,
effective instructions/parameters, input, model binding, and policy so restart
cannot silently select a different implementation or model.

This is a capability inside `Behavior.Flow`. The synchronous `ShikumiProgram`
behavior still selects its ordinary task registry. Whole-assignment model
selection and recoverable intermediate Skill turns remain planned.

## Run the example without a model key

The [proof declaration](../../agents/proof/shikumi-decision-example.dhall) selects
`shikumi-decision-example` and grants `decisionModels = [ "triage", "investigate" ]`.
Triage either returns immediately or selects investigation. Investigation uses
two Predict nodes and can return a result or propose a specialist route.

Follow [Getting Started](getting-started.md) to build and migrate PostgreSQL.
Save this operator catalog as `decision-models.yaml` in the repository root:

```yaml
behavior:
  provider: stub
  decisionModels:
    - alias: triage
      version: "1"
      bindingId: proof-triage
      bindingVersion: "1"
      provider: stub
      model: stub-triage
      thinking: default
      max_tokens: 1024
      timeout_ms: 30000
    - alias: investigate
      version: "1"
      bindingId: proof-investigate
      bindingVersion: "1"
      provider: stub
      model: stub-investigate
      thinking: default
      max_tokens: 2048
      timeout_ms: 30000
```

Enqueue the request, then start the worker against the same database:

```sh
export SHIKIGAMI_AGENTS_DIRECTORY=agents/proof
cabal run shikigami -- --config decision-models.yaml enqueue-run shikumi-decision-example \
  --payload '{"request":"Review the architecture practice"}' --key decision-example-1
cabal run shikigami-worker -- --config decision-models.yaml
```

Set that directory in both terminals. The private deterministic stub exercises
actual Shikumi dispatch and returns typed JSON. Its investigation branch
records one triage call and two investigation calls under distinct model
descriptors. This proves the local dispatch path; its requested-model evidence
does not identify an independently observed remote model.

The request-taking example needs a payload from the queue or
[HTTP run API](http-api.md). `shikigami-agent-run` currently supplies a null
trigger payload; `shikigami-run-behavior` cannot interpret durable Flows.

## Configure authority and live execution

The operator's `behavior.decisionModels` catalog is restricted by the agent's
`decisionModels` list, the Flow's finite slot inventory, and any pinned sanctioned
profile. An empty catalog grants nothing. Admission checks the complete inventory
before the first call, including branches that may not execute. A triage-only
profile therefore cannot admit this two-slot example.

Configure live entries with `anthropic`, `openai` (Chat Completions), or
`openai-responses`, using exact model IDs accepted by the selected Baikai catalog.
Supply credentials separately with `ANTHROPIC_API_KEY` or `OPENAI_API_KEY`.
Unknown fields/models, unsupported thinking settings, and credentials inside
catalog entries are refused. `thinking: default` must also satisfy the profile.
Catalog JSON can be supplied through `SHIKIGAMI_BEHAVIOR_DECISION_MODELS`.
See the [authoring and operations guide](../shikumi-flow-decisions.md) for live
configuration examples and registration details.

Model output grants no authority. A specialist proposal must decode and validate
against the journaled candidate catalog and declared delegate set. No-match and
ambiguous results create no children. A valid route still crosses the current
delegation authorization boundary.

## Replay, evidence, and changing a program

A completed decision replays its full validated result through its historical
codec without another provider call or current validator. Pending work requires
the exact pinned program state and binding. Missing historical versions refuse
before dispatch; changing an alias or default does not replace them. Retain pure
result codecs even after retiring executable programs.

Each actual provider attempt first records an expectation, then terminal evidence
and compliance facts before a successful result can be journaled. A crash between
provider execution and the result append may cause another actual attempt.
Both attempts remain visible. Unresolved expectations and unknown usage remain
uncertain; the ledger does not make provider transport exactly-once.

Library consumers query `Shikigami.Decision.Evidence.readDecisionReport` and
`listDecisionCalls`. Reports are unsigned, bounded to 10,000 attempts, with detail
pages of at most 200. There is no decision-report HTTP endpoint.

New decisions require immutable program/validator/schema/parameter identities,
a retained result codec, a closed `DecisionLabel`, and literal preparation/result
step labels. Each declared slot runs once per workflow generation; loops need
generation rotation. Follow [Flows](flows.md), the
[authoring guide](../shikumi-flow-decisions.md), and
[workflow versioning](../workflow-versioning.md) before changing a durable body.
