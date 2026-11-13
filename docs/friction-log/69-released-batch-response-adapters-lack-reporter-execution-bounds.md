---
type: Friction Entry
title: "Released batch response adapters lack reporter execution bounds"
description: "The public batch adapter contract blocks promotion because cancellation does not provide enforced deadlines, retained-output limits or detached-descendant and native-tool confinement."
generated:
  by: "codex-cli/gpt-6.1-sol"
  at: "2026-11-13T00:36:04Z"
frictionId: FRIC-69
status: logged
impact: blocked
kind: interface
origin: "mori://shinzui/shikigami"
affects: "mori://shinzui/baikai/docs/cli-providers"
affectedVersion: "0.7.3.0"
plan: "docs/plans/80-configure-model-providers-and-agent-launches-through-baikai.md"
---
# Released batch response adapters lack reporter execution bounds

## Attempted

Resume M1 CLI promotion after verifying Hackage preferred releases, upstream tags and the public batch adapter sources.

## Encountered

Core 0.10.1.0 and vendor adapters 0.7.3.0 remain current; timeoutMs is ignored, output is accumulated to EOF, and deliberately detached process groups can escape. The application cannot qualify M2/M3/M6 through that public boundary.

```text
The published CLI guide lists timeoutMs among ignored fields and documents inherited-process-group-only cancellation. Claude captures stdout/stderr with strict hGetContents; Codex retains JSONL through EOF.
```
