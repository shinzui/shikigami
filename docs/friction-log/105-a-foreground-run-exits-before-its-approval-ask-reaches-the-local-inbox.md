---
type: Friction Entry
title: "A foreground run exits before its approval ask reaches the local inbox"
description: "shikigami-agent-run printed 'a durable wake is pending' and exited while the approval workflow had only ingested its request, so shikigami-local approvals pending was empty until a --resume delivered it, against a default 900-second deadline."
generated:
  by: "claude-code/claude-opus-5-5"
  at: "2026-11-17T23:54:51Z"
frictionId: FRIC-105
status: "resolved"
impact: detour
kind: interface
origin: "mori://shinzui/shikigami"
affects: "mori://shinzui/shikigami"
affectedVersion: "unreleased"
plan: "docs/plans/132-modernize-the-keiro-services-with-a-declared-campaign-playbook.md"
workaround: "Ran shikigami-agent-run --resume <run>, which delivered the ask and printed the readiness report; approved within the deadline."
tags:
  - "approval"
  - "local-inbox"
  - "playbook"
resolution: "Fixed in a5f59a45: a foreground local run drives its children until none progresses, so the first pass prints 'Run <ID> waits for approval: shikigami-local approvals resolve <REVIEW-ID>'; the local ask waits a day by default (trust.local_operator.approval_deadline_seconds)."
amended:
  - by: "claude-code/claude-opus-5-5"
    at: "2026-11-18T12:29:02Z"
    change: "Status set to resolved."
---
# A foreground run exits before its approval ask reaches the local inbox

## Attempted

Reach the koyomi readiness-review approval in a foreground campaign run.

## Encountered

'Agent run accepted; a durable wake is pending.' approvals pending: 'No pending approvals'. review_793a... was running with only ingest-approval journaled. docs/user/playbooks.md promises 'Run <ID> waits for approval: shikigami-local approvals resolve <REVIEW-ID>'. The ask carried a 15-minute deadline (resolve-approval-policy deadline 900), short for a human gate.

## Workaround

Ran shikigami-agent-run --resume <run>, which delivered the ask and printed the readiness report; approved within the deadline.
