# Plan 113: independent watchdog qualification

The eight IR-19 acceptance cases pass against disposable migrated PostgreSQL
through real schedule timers, generated PGMQ admission, AgentRun and the production
resume registry. `WatchdogQualificationSpec` writes [acceptance.json](acceptance.json)
from assertions in the current run; the additional control records lost-result
append accounting. Fixtures use deterministic typed-model providers and retained
owner records. No external model, notification or command service is contacted.

```text
cabal test shikigami-workers-test --test-show-details=direct \
  --test-options='-p WatchdogQualification --num-threads 1'
All 8 tests passed (7.48s)
```

| IR-19 case | Observed result |
| --- | --- |
| 1: stalled active worker | One stuck finding; a later scheduled sweep retains the same episode and finding, with no new delivery. No coordinator finding substitutes for it. |
| 2: bounded waits | Real accepted permission, exact parent approval and an independent registered command suppress quiet findings. After permission expiry and production approval-timeout dispatch, two lapsed findings appear; the command remains within its own deadline. |
| 3: idle coordinator | One separate coordinator finding for the open objective, with no worker finding. |
| 4: drift | An accepted `unrelated-export` operation produces cited execution and coordinator drift through the typed provider. Objective versions, assignments and command receipts remain equal. |
| 5: no intervention authority | Cancel and transfer under the scheduled watchdog identity lack admitted coordination authority; objective cancellation is refused. Session and objective state remain unchanged. |
| 6: planted instructions | Protected worker/model inputs and command arguments cannot enter the bounded Drift input, substitute subjects or select `other-thread`. The unbound worker notice addresses the configured operator. |
| 7: stopped target | A stalled execution under the stopped objective root is reported. That root remains byte-for-byte equal after the sweep. The watchdog root alone settles one model attempt and retains unmeasured token usage. |
| 8: restart and missed cadence | Crash after committed `decision-result-drift`, before `watchdog-close`, resumes through the registry with one provider call, one finding and stable delivery receipts. A skipped tick retains a RunSkip and the last completion becomes overdue. |
| Additional lost-append control | Crash before the decision result append requires a second actual call. Both model attempts are charged to the same watchdog root. |

The fixtures age initial semantic marks by 120 seconds against 60-second windows,
without changing the host clock. Permission expiry changes only accepted deadline
metadata; approval expiry runs the production dispatcher at the due instant. During
that drain, schedule admission is deliberately disabled to avoid spending on the
incidental due tick, then the next real tick uses the original allowance. Command
and permission executions have distinct workflow parents, so an approval wait
cannot mask missing command facts.

Six core PostgreSQL inspection tests and three database-backed command cases cover
empty coverage, missing completion, scoped ownership, bounded keyset pages,
corruption refusal, a fresh completion and a stale completion despite a newer
unfinished attempt. Telemetry force-flush tests cover fixed counter attributes,
ledger-only database-clock age, no age point before completion, and failure
isolation. Built CLI contracts include help and pre-configuration bounds checks.

Final runtime candidate: `1c48b31a` (inspection milestone `23949ce5`); final
closure also refreshes the generated OpenAPI document for existing adaptive
objective views. The initial API equality check found that stale artifact; after
regeneration all API/client/server cases pass.

Validation on 2026-11-06:

| Check | Result |
| --- | --- |
| Core unit | 784 passed |
| Core PostgreSQL | 665 passed |
| Worker, including eight qualification and four telemetry cases | 351 passed |
| Agent | 37 passed |
| API / client / server | 35 / 9 / 113 passed |
| Total package tests | 1,994 passed |
| Full `cabal build all`, including workspace prototype | Passed |
| `just keiro-gate c68af1a5` | Replay-neutral; 183 conformance checks; generated sources clean |
| Built CLI contracts | 91 real-process checks passed |
| Migration unit / smoke (inspection milestone) | 9 / 11 passed |
| Haskell conventions / migration schema isolation | Passed |
| Capability / user / improvement-request profiles, graph and Mori manifest | Passed |

ADR distillation retains the observation/family boundaries in
[0116](../../adr/0116-watchdog-observation-preserves-completeness-and-detector-boundaries.md),
semantic marks in [0117](../../adr/0117-watchdog-staleness-is-measured-against-its-own-sweep-marks.md),
advisory authority in [0118](../../adr/0118-the-watchdog-is-an-advisory-flow-agent-without-intervention-authority.md),
operator-owned envelopes in [0119](../../adr/0119-the-schedule-trigger-enrolls-an-operator-owned-watchdog-envelope-per-tick.md)
and independent ledger liveness in
[0120](../../adr/0120-watchdog-liveness-is-an-operator-facing-ledger-verdict.md).

Optional native Linux watchdog trial: **not run**. Apple containers are available;
this plan does not add a native command-containment claim. Optional live-model
trial: **not run**. These are additional trials; deterministic acceptance establishes
bounded admission, accounting, replay and authority behavior, not model quality.
