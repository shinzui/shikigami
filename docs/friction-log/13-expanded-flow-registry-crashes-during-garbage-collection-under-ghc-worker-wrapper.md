---
type: Friction Entry
title: "Expanded Flow registry crashes during garbage collection under GHC worker-wrapper"
description: "A native GHC 9.12.4 crash during Flow replay required clean-build isolation and a module-local optimization workaround."
generated:
  by: "codex-cli/gpt-6.1-sol"
  at: "2026-10-28T19:53:52Z"
frictionId: FRIC-13
status: "accepted"
impact: detour
kind: tooling
origin: "mori://shinzui/shikigami"
affects: "https://www.haskell.org/ghc/"
affectedVersion: "9.12.4"
plan: "docs/plans/84-coordinate-continuing-worker-sessions-and-fenced-handoffs.md"
workaround: "Compile only Shikigami.Agent.Workflow with -O0; all other modules retain normal optimization. Keep forced-GC deployment replay coverage. The fresh-build five-suite run passed all 1057 cases, including 350 PostgreSQL cases. Requalify on a compiler upgrade and measure scheduling throughput under plan 85."
tags:
  - "haskell"
  - "runtime"
resolution: "Accept the module-local unoptimized workflow boundary after the complete five-suite run passed; narrower exclusions were disproven, and no upstream compiler cause or untested release fix is claimed."
amended:
  - by: "codex-cli/gpt-6.1-sol"
    at: "2026-10-28T19:54:27Z"
    change: "Accept the narrow compiler workaround after clean-build failure and passing controlled transform-disabled replay."
  - by: "codex-cli/gpt-6.1-sol"
    at: "2026-10-28T19:57:36Z"
    change: "Full-suite recurrence invalidated acceptance of the provisional transform exclusion; reopen investigation."
  - by: "codex-cli/gpt-6.1-sol"
    at: "2026-10-28T20:02:21Z"
    change: "Replace the disproven narrow transform workaround with the module-local unoptimized boundary that passed the complete capability group; full-suite qualification pending."
  - by: "codex-cli/gpt-6.1-sol"
    at: "2026-10-28T20:05:46Z"
    change: "Accept the qualified module-local O0 workaround after all 1057 tests, full build, compatible evolution/conformance and schema isolation passed."
---
# Expanded Flow registry crashes during garbage collection under GHC worker-wrapper

## Attempted

Run the PostgreSQL WorkerSessionCapability deployment replay test under normal optimization, then force performGC after suspension.

## Encountered

The process exited 139; macOS reported EXC_BAD_ACCESS in evacuate at address 0xfffffffffffffff8. The failure reproduced after a fresh build and with a single RTS capability.

```text
Fresh build: /tmp/shikigami-mp14-worker-clean-build-test.log. Module-local -fno-worker-wrapper: /tmp/shikigami-mp14-worker-flow-ww-test.log, all three deployment tests passed with explicit GC.
```

## Workaround

The initial registry-only worker/wrapper exclusion passed the isolated replay
but failed the full population; it is rejected. Workflow-only worker/wrapper
and strictness exclusions were also insufficient. The upstream cause remains
unidentified.

Compile only `Shikigami.Agent.Workflow` with `-O0`; other modules retain normal
optimization. Keep explicit collection at suspension/resume in the replay
regression. The fresh-build five-suite run passes all 1,057 cases, including 350
PostgreSQL cases (`/tmp/shikigami-mp14-workers-accepted-all-tests.log`). Full build,
conformance/evolution and schema isolation also pass. Keep the compiler pin
unchanged and requalify before removing the workaround; plan 85 must measure
scheduling throughput. Official distribution listing and upstream release tags
were checked; no later 9.12 maintenance release tag was present.
