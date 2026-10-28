# Execution resource accounting

New objective admission can enroll a root run through
`Shikigami.Execution.Admission.enrollRootRun`. Supply an explicit envelope with
an absolute UTC cutoff and dimension policies. Existing ordinary run producers
remain unenrolled. Descendants inherit the root and cannot create another
allowance. Resource admission complements the existing authority checks.

Inspect one admitted root with:

```bash
shikigami resources inspect ROOT --json
```

The bounded response includes the admitted limits, policy revision, cutoff,
settled direct reservations, held capacity including exclusive allocations,
measured usage across allocations, active and unknown attempt counts, and
refusal categories. Cost is integer millionths of one USD. Inspection contains
no prompts, tool payloads, provider credentials or operation history.

Only `Accepted` from `beginAttempt` permits a new dispatcher to proceed.
`AlreadyAccepted` means the executor must recover the existing attempt; it does
not permit another transport call. Each actual retry uses a new attempt id under
the same logical operation. Token/cost ceilings must be applied to the request by
the transport owner. Missing measurements remain unknown, with reservations
held until a verified reconciliation records the measured result.

Cancellation, cutoff and reduced active capacity deny new work while permitting
accepted work to record results. A reduced cap below current occupancy allows
that work to drain. Overage is retained and stops further admission. Lease
expiry never releases uncertain effects. Do not delete resource rows because a
workflow is terminal or its journal has passed the workflow retention window.

For rollout, apply the additive migration with the dedicated migration role.
Upgrade workers before producers: the new application queue codec writes
version 2 and accepts retained version 1 messages through an upcaster. Version
1 inputs remain unchanged and unenrolled. Stop all old workflow writers before
enrolling resource roots. Resume using the shared workflow options containing
`shikigami-execution-resources-v1`; historical journals retain their old branch.
Roll forward after new journals or queue messages have been written.
