---
type: Friction Entry
title: "Released Shikumi rejects streaming decision outputs before transport"
description: "Shikumi 0.5 exposes the new judgment types and complete-call routing but explicitly refuses TypeSafe and rich-decision streaming, preventing plan 80 complete/stream parity through its public runner."
generated:
  by: "codex-cli/gpt-6.1-sol"
  at: "2026-11-03T03:48:56Z"
frictionId: FRIC-49
status: "resolved"
impact: blocked
kind: interface
origin: "mori://shinzui/shikigami"
affects: "mori://shinzui/shikumi/packages/shikumi"
affectedVersion: "0.5.0.0"
plan: "docs/plans/80-configure-model-providers-and-agent-launches-through-baikai.md"
promotedTo: "mori://shinzui/shikumi/okf/improvement-requests/concepts/IR-5"
amended:
  - by: "codex-cli/gpt-6.1-sol"
    at: "2026-11-03T03:55:18Z"
    change: "Filed Shikumi IR-5 for public judgment streaming, settings-aware typed derivation, atomic structured events and acknowledged attempt evidence; complete/stream acceptance remains blocked on a qualifying release."
  - by: "codex-cli/gpt-6.1-sol"
    at: "2026-11-03T13:20:23Z"
    change: "Resolve the pre-transport judgment-streaming blocker after verifying tagged Hackage descriptors and the real public provider through the application wrapper; broader plan acceptance remains separate."
resolution: "Released Shikumi 0.5.1.0, cache 0.2.1.1, tools 0.4.2.1 and trace 0.3.2.0 at 7b96ecf06364b37de44b15c4f58b2528b5a3e0f5 implement owning IR-5. The coherent application solve and all 15 real TypeSafe complete/stream consumer checks pass, including raw/typed parity, atomic events, acknowledged terminal ordering, refusal, cancellation and failure boundaries."
---
# Released Shikumi rejects streaming decision outputs before transport

## Attempted

Qualify public Shikumi.Stream.streamProgram and Shikumi.Routing.routeLLM against the adopted 0.5.0.0 release for the application TypeSafe stream path.

## Encountered

streamPredict rejects evidenceFields and routeLLM rejects Stream when capabilityFor is DecisionOnly or decision metadata is present, before the application provider wrapper can receive the request.

```text
ValidationFailure "decision outputs do not support streaming"
```
