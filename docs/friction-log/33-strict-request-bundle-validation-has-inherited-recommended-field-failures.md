---
type: Friction Entry
title: "Strict request-bundle validation has inherited recommended-field failures"
description: "Strict validation of the improvement-request bundle rejects pre-existing missing review and resolution metadata, requiring an isolated baseline comparison for the IR-13 lifecycle update."
generated:
  by: "codex-cli/gpt-6.1-sol"
  at: "2026-10-30T19:37:45Z"
frictionId: FRIC-33
status: "accepted"
impact: detour
kind: process
origin: "mori://shinzui/shikigami"
affects: "mori://shinzui/shikigami"
plan: "docs/plans/98-persist-authoritative-objectives-and-conditional-commands.md"
workaround: "Compare the same strict command against a copied implementation-baseline bundle and retain the existing diagnostics without inventing historical reviews or changing unrelated request records."
resolution: "The current strict diagnostics exactly match the implementation-baseline bundle; request-corpus review/resolution metadata cleanup is outside plan 98 and no review history is fabricated."
amended:
  - by: "codex-cli/gpt-6.1-sol"
    at: "2026-10-30T19:38:08Z"
    change: "Baseline and current strict validation outputs compare byte-for-byte equal; retain the inherited eight diagnostics as a known qualification limit."
---
# Strict request-bundle validation has inherited recommended-field failures

## Attempted

okf validate docs/improvement-requests --strict --profile docs/improvement-requests/profile.dhall --profile-enforce --log-enforce

## Encountered

Eight existing concepts omit profile-recommended reviews or terminal resolution fields, including IR-13 before this implementation.

```text
Strict validator reports missing reviews for seven concepts and missing terminal resolution for expose-addressed-agent-runs-over-http.
```

## Workaround

Compare the same strict command against a copied implementation-baseline bundle and retain the existing diagnostics without inventing historical reviews or changing unrelated request records.
