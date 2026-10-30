---
type: Friction Entry
title: "Batch qualification retains open stdin in a fake unattended vendor"
description: "The final host test rerun waits indefinitely for a fake vendor to receive EOF when the harness keeps stdin open."
generated:
  by: "codex-cli/gpt-6.1-sol"
  at: "2026-10-30T18:41:26Z"
frictionId: FRIC-31
status: logged
impact: detour
kind: tooling
origin: "mori://shinzui/shikigami"
affects: "mori://shinzui/shikigami"
plan: "docs/plans/96-provide-governed-mutable-repository-workspaces-for-durable-agents.md"
workaround: "Stop only the recorded fixture processes, then rerun the agent suite with stdin redirected from /dev/null. Use closed stdin for subsequent batch qualification."
---
# Batch qualification retains open stdin in a fake unattended vendor

## Attempted

Run cabal test all --test-options=-j2 --test-show-details=direct through the asynchronous command harness.

## Encountered

All other suites passed, but the agent launch fixture retained a /bin/sh vendor and cat waiting for EOF for more than four minutes; the fixture timeout did not terminate that wait.

```text
/tmp/shikigami-96-final-all-last.log; test process 12780 retained vendor 12789 and cat 12871. Earlier full host run passed.
```

## Workaround

Stop only the recorded fixture processes, then rerun the agent suite with stdin redirected from /dev/null. Use closed stdin for subsequent batch qualification.
