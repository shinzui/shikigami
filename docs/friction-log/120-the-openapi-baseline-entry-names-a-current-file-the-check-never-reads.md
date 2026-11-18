---
type: Friction Entry
title: "The OpenApi baseline entry names a current file the check never reads"
description: "api-baseline's OpenApi check compares the frozen copy with the description compiled into the tool, so the inventory's current = docs/api/openapi.json is ignored and editing that file alone reports clean."
generated:
  by: "claude-code/claude-opus-5-5"
  at: "2026-11-18T21:05:00Z"
frictionId: FRIC-120
status: logged
impact: detour
kind: tooling
origin: "mori://shinzui/shikigami"
affects: "mori://shinzui/shikigami"
affectedVersion: "unreleased"
plan: "docs/plans/136-freeze-the-v1-api-baseline-with-a-surface-inventory-and-compatibility-checks.md"
workaround: "Demonstrated the removed route in code (ShikigamiApi) instead; docs/architecture/api-baseline.md now says the check reads the compiled description and OpenApiSpec keeps the file equal to it."
tags:
  - "api-baseline"
  - "openapi"
---
# The OpenApi baseline entry names a current file the check never reads

## Attempted

EP-11 M4's breaking-edit demonstration for the HTTP API: delete the path
`/agents/{agentName}/runs/{runId}` from `docs/api/openapi.json` and run
`just api-baseline --only http-api`.

## Encountered

`http-api  stable  clean`, exit 0. `ApiBaseline.Run` matches `OpenApi {frozen}` and compares it
with `renderOpenApi shikigamiOpenApi`, so the entry's `current` field is never read.

## Workaround

Demonstrated the removed route in code (the `openapi` field of `ShikigamiApi`), which reported
`path removed: /openapi` and exit 1. The policy document now says what the check compares. The
field could be dropped from `Surface.dhall`, or the check could also fail when the file differs
from the compiled description.
