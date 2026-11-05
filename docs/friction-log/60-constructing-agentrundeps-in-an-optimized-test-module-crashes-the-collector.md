---
type: Friction Entry
title: "Constructing AgentRunDeps in an optimized test module crashes the collector"
description: "A native GHC 9.12.4 evacuate crash recurred as FRIC-13's signature: the propose-work fixture segfaulted at the first major GC when AgentRunDeps was built by a record literal under optimization, while the same values passed when the record was rebuilt through its O0 defining module or the fixture itself was O0."
generated:
  by: "claude-code/claude-opus-5-5"
  at: "2026-11-05T02:02:40Z"
frictionId: FRIC-60
status: logged
impact: detour
kind: tooling
origin: "mori://shinzui/shikigami"
affects: "https://www.haskell.org/ghc/"
plan: "docs/plans/116-propose-work-through-a-stream-triggered-flow-with-durable-human-acceptance-and-trusted-origin-links.md"
workaround: "Compile the fixture and Shikigami.Workers.Config at O0, the latter as an unproven precaution for the production record construction"
---
# Constructing AgentRunDeps in an optimized test module crashes the collector

## Attempted

Run the ProposeWork worker fixture through the real agent-run workflow

## Encountered

Exit 139; EXC_BAD_ACCESS in evacuate at 0xfffffffffffffff8; the debug RTS reports invalid closure, info=0x0. Existing literal fixtures pass at -A64k, a plain-function literal in the fixture still crashes, and the trigger is not established.

## Workaround

Compile the fixture and Shikigami.Workers.Config at O0, the latter as an unproven precaution for the production record construction
