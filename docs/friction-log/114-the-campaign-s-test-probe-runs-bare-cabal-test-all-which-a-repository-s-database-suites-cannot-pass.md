---
type: Friction Entry
title: "The campaign's test probe runs bare cabal test all, which a repository's database suites cannot pass"
description: "The keiro playbook's tests probe runs nix develop -c cabal test all, but koyomi's database and fixture suites run only through just check's scripts, so the close review showed exit 1 for a green upgrade."
generated:
  by: "claude-code/claude-opus-5-5"
  at: "2026-11-18T02:47:30Z"
frictionId: FRIC-114
status: logged
impact: detour
kind: interface
origin: "mori://shinzui/shikigami"
affects: "mori://shinzui/shikigami"
affectedVersion: "unreleased"
plan: "docs/plans/132-modernize-the-keiro-services-with-a-declared-campaign-playbook.md"
workaround: "Read the failures by hand, approved the close, and ran nix develop -c just check independently."
tags:
  - "playbook"
  - "testing"
---
# The campaign's test probe runs bare cabal test all, which a repository's database suites cannot pass

## Attempted

Read koyomi's close review in run aa2b77a1-04e7-5384-8398-07b7e33947e0.

## Encountered

19 of 36 suites failed on setup only: NotifierConnectError (no socket at koyomi/db/.s.PGSQL.5432), 'test database connection failed', and getEnv failures for KOYOMI_EN_TEST_URL, KOYOMI_JWKS_TEST_DIRECTORY, KOYOMI_DIRECTORY_TEST_URL and KOYOMI_HTTP_CONTRACT_CAPTURE. The other 17 passed. ExecPlan 9 recorded just check exit 0 on each edge.

## Workaround

Read the failures by hand, approved the close, and ran nix develop -c just check independently.
