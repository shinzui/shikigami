# IR-21 acceptance evidence

Written by `shikigami-workers/test/Shikigami/InitiativeAcceptanceSpec.hs`, which drives the
real path: `processDecodedActivityObserving`, the run queue, the agent-run workflow, the
counted stub provider, the recording notifier, `resolveApproval` and the timer drain. Each
JSON file holds measured counts, statuses and step names, never excerpts or allocated
identifiers. Re-running the group overwrites them.

```bash
cabal test shikigami-workers-test --test-show-details=direct \
  --test-option=-p --test-option='/InitiativeAcceptance/' \
  --test-option=--num-threads --test-option=2
```

| Case | File | Result |
| --- | --- | --- |
| 1. An undirected bug report yields a proposal with evidence; acceptance creates one linked objective | `case-1.json` | Pass |
| 2. Without a policy nothing starts, and approval funds and staffs nothing | `case-2.json` | Pass |
| 3. Under a policy, one bounded objective ends at a reviewable artifact and publishes nothing | `case-3.json` | Pass |
| 4. Planted instructions change no scope, repository, recipient or authority | `case-4.json` | Pass |
| 5. Unrelated chatter leaves recorded skips and notifies nobody | `case-5.json` | Pass |
| 6. Redelivery, restart and restatements yield one proposal, one decision and one ask | `case-6.json` | Pass |
| 7. An open objective owns its subject; once cancelled the subject proposes again | `case-7.json` | Pass |
| 8. Limits stop proposals and admissions visibly | `case-8.json`, `case-8-admission.json` | Pass |
| 9. Rejection suppresses; revocation or expiry stops admission while admitted work continues | `case-9.json`, `case-9-policy.json` | Pass |

## What this does not establish

- The provider is the stub, through the real Handan and Shikumi dispatch path. No trial ran
  against a real model or a real Intercom channel.
- The optional native trial of an admitted objective through plan 86's fixture was not run.
  Admission proves one correctly funded, staffed and bounded objective whose coordinator run
  is admitted to its association; it does not prove the objective completes.
- `--fail-when-exhausted` is covered through `anyExhausted` and option parsing rather than by
  executing the binary against a database.
- The fixture is compiled `-O0` because constructing `AgentRunDeps` under optimization crashed
  the collector (FRIC-60). The worker's own construction of that record is not exercised here.
