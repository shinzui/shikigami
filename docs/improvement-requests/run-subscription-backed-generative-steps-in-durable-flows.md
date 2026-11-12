---
type: Improvement Request
title: Run subscription-backed generative steps in durable Flows
description: Once CLI response providers qualify, let a durable Flow's generative step use an authenticated Claude or Codex CLI login, with JSON-schema output, isolated tools and configuration, pinned bindings, honest usage evidence, and a distinct login failure.
timestamp: "2026-11-12T16:00:00Z"
generated:
  by: process:claude-code
  at: "2026-11-12T16:00:00Z"
requestId: IR-25
status: proposed
origin: mori://tan/tan-product-management
---

# Run subscription-backed generative steps in durable Flows

## Status

**Proposed; no implementation plan selected.** This request comes from
`mori://tan/tan-product-management/masterplans/2-add-shikigami-product-management-reviews-and-follow-up`,
which reviewed Shikigami at commit `5b716874`. It gates the draft stage of
`mori://tan/tan-product-management/plans/11-run-recurring-product-reviews-with-durable-history-and-delivery`.
That consumer's owner uses Claude and Codex subscription logins for generative calls
and a TypeSafe API key for typed judgments. They do not plan to use Anthropic or
OpenAI API keys. The request builds on
[plan 80](../plans/80-configure-model-providers-and-agent-launches-through-baikai.md)
and does not ask to reorder it.

## Problem and current coverage

The consumer's registered review Flow has two stages. A generative step drafts a
structured report from the run payload. A TypeSafe judgment program then classifies
each item. The judgment stage works with today's `decisionModels` catalog. The draft
stage has no subscription-backed path.

- Background `claude-cli` and `codex-cli` response providers are refused. Plan 80's
  Milestone 1 owes enforced deadlines, bounded retained output, and descendant
  confinement. Milestones 2 and 3 then add CLI configuration and handlers, and
  Milestone 6 proves a key-free supplied-payload reporter through
  `shikigami-run-behavior`.
- Plan 80 stops at that one-off reporter. It says the CLI adapters do not support
  Shikigami's tool loop, that `JsonObject` has no CLI analogue, and not to "claim
  every Flow works through a CLI".
- Flow generation requests `JsonObject` today. Routing sets it in
  `shikigami-core/src/Shikigami/Flow/Routing.hs`, and the practice-review evaluator
  sets it in `shikigami-core/src/Shikigami/PracticeReview/Capability.hs`.
- Typed decisions select a binding from `decisionModels`, built through
  `providerCallFor` in `shikigami-core/src/Shikigami/Decision/ModelCatalog.hs`. The
  catalog admits HTTP providers and TypeSafe, not a CLI login.

Even after Milestone 6, no durable Flow can draft with a subscription login.

## Requested change

1. Once plan 80 qualifies CLI response providers, admit them for generative steps in
   durable Flows. That can be through `decisionModels` bindings for typed decision
   programs, through the model-call capability that routing and practice review use,
   or both. Which one is Shikigami's choice.
2. Let a Flow step request JSON-schema structured output that a CLI adapter can
   honor. A step that requires `JsonObject` with a CLI binding is refused at
   admission, never silently downgraded. Existing `JsonObject` callers keep their
   current HTTP behavior.
3. Carry the CLI transport into sanctioned execution profiles and decision bindings:
   provider, transport, model, and the vendor CLI version that served the call. Pin
   the binding on replay, and refuse a tuple outside the pinned profile before
   dispatch.
4. Isolate the CLI process. It gets no tools, a working directory that holds only
   what the step supplies, and a home and configuration directory of its own, so the
   operator's global instructions, hooks, MCP servers, and memory never enter the
   prompt. Remove API-key variables so the call cannot silently switch to key
   authentication. Reuse plan 80's confinement boundary rather than a second one.
5. Record each call as correlated run evidence. Report whatever usage the CLI
   exposes, and retain unknown usage as uncertain against root resource accounting
   ([CAP-26](../capabilities/root-resource-accounting.md)). Never estimate token
   counts and present them as actual.
6. Report an absent or expired login as its own failure kind on run status, distinct
   from a provider or behavior failure, so an operator knows to renew the login.
7. Keep today's recovery semantics. A crash after dispatch and before the result is
   recorded can repeat one call, and a completed result replays without the CLI or
   its login.

The configuration syntax, failure-kind name, and evidence fields are Shikigami's to
choose.

## Acceptance

1. A registered Flow's CLI-backed generative step returns schema-valid JSON. It runs
   on a worker whose service user holds a vendor login and whose environment has no
   Anthropic, OpenAI, or Codex API-key variables. The Flow validates the result and
   continues.
2. After that step completes, removing the login and restarting the worker replays
   the recorded result with no new CLI call.
3. Output that violates the requested schema ends the step with a typed failure, and
   the Flow does not reach later steps.
4. A canary file next to the working directory and a canary instruction in the
   operator's global CLI configuration never appear in the step's output.
5. With the login removed before dispatch, the run fails with the distinct login
   failure kind on `GET /agents/{agentName}/runs/{runId}`.
6. A step that requires `JsonObject` with a CLI binding is refused at admission.
7. A CLI model or transport outside the pinned profile is refused before dispatch.
8. Flows bound to HTTP providers or TypeSafe behave exactly as before.

## Dependencies and scope

This depends on plan 80 Milestones 1 to 3 and follows its Milestone 6 qualification
approach. It builds on [CAP-21](../capabilities/typed-flow-decisions.md),
[CAP-13](../capabilities/sanctioned-execution-profiles.md),
[CAP-14](../capabilities/run-evidence-and-compliance.md), and
[CAP-26](../capabilities/root-resource-accounting.md). It does not ask for a CLI
tool loop, attended launches, or any change to TypeSafe, which keeps its own
credential. It is independent of
[IR-24](read-pinned-allowlisted-repository-evidence-in-durable-runs.md), which
concerns how evidence reaches the run rather than how the model is called.
