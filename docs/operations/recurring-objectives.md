# Recurring objective checkpoints

An ordinary `objectives create` admits finite work. It creates no recurring
authority. Installing an agent, Skill, standing policy or cron schedule also
creates no mandate. A mandate is a separate, explicit authorization to supervise
an objective until its finite expiry, terminal completion, revocation or cancellation.

Apply the application migrations before restarting workers. Enable objective
tracking and configure its local operator as described in
[objective tracking](objective-tracking.md). The worker's existing workflow
resumer and shared 100-row timer dispatcher run recurrence; no extra scheduler
process is needed.

First obtain an objective, its assignment identifiers and an already admitted
resource root. Every selected assignment must belong to that root. The root's
admitted quantities must be finite and its cutoff must cover the mandate expiry.
Creating or editing a mandate never allocates a replacement root or resets usage.

Write a request such as the following to `mandate.json`, replacing the objective,
root, assignment and expiry with real admitted values. Expiry must be in the
future, within one year, and no later than the retained root cutoff.

```json
{
  "mandateId": "release-evidence",
  "objectiveId": "<OBJECTIVE>",
  "rootId": "<ROOT>",
  "scope": ["<ASSIGNMENT>"],
  "sources": ["CurrentObjectiveCheckpoint"],
  "maximumEvents": 1,
  "cadence": {"seconds": 300, "maximumSeconds": 3600},
  "expiresAt": "<FINITE-UTC-EXPIRY>",
  "mode": "ContinuingCoordinator",
  "stopCondition": "WhenObjectiveTerminal"
}
```

```bash
shikigami mandates create --operation-key release-evidence-create --file mandate.json --json
shikigami mandates inspect release-evidence --json
```

The supplied source is a whole current checkpoint from the real objective owner.
Each cycle consumes at most one snapshot, within `maximumEvents` (1..100).
It retains the exact accepted objective receipt, instruction and criteria
revisions, assignment owner fences and shared root. This is read-only checkpoint
supervision: it dispatches no model, worker, tool, external publication or user
notification. `ContinuingCoordinator` uses the continuing controller directly;
`FreshCycleRun` puts that same bounded adapter in an independently resumed native
child. Both reread current state and accept only owner-provided progress references.
Neither mode grants new adaptive or workspace authority.

Objective changes wake the supervisor promptly. Timers repair missed events and
process restarts. A wake carries only mandate and generation references. Replacing
instructions before an old timer fires therefore selects the current checkpoint.
Duplicate event/timer deliveries coalesce; an unchanged checkpoint retains its
last cycle and doubles the idle interval up to `maximumSeconds` and expiry.
Inspection includes the watermark, last/active cycle, owner/fence, next due,
stop reason, unresolved objective operations and authoritative root usage,
including unknown attempt holds.

A schedule update requires fresh operator authority and the exact current
mandate revision. Put only `cadence` and `expiresAt` in `schedule.json`; unknown
fields are refused. Faster scheduling or a later expiry is a newly authorized
command and remains within the original root. Objective, root, source and scope
are immutable; a different scope requires a separately admitted mandate.

```bash
shikigami mandates update release-evidence --expected-revision 7 --operation-key release-evidence-update --file schedule.json --json
shikigami mandates cancel release-evidence --expected-revision 8 --operation-key release-evidence-cancel --json
```

Use the revision returned by inspection; the controller may have advanced it.
Retry a lost acknowledgement with the same operation key, expected revision and
complete request. An accepted retry returns its original result. Conflicting
reuse or a stale new command is refused. A stopped mandate cannot be revived by
an update or late wake. Cancellation closes admission, retires its listener and
disables its timer. Accepted and uncertain operations remain retained with their
original owners; cancellation does not claim that an external process stopped.

Mandate receipts and cycle references have application-owned retention and are
not deleted by terminal workflow garbage collection. Progress and desired due
time commit together. A restart between that commit and listener/timer
publication resumes the recorded native input and repairs the wake. Deploy the
additive migration and new workflow registry together; future body changes must
follow [workflow versioning](../workflow-versioning.md).
