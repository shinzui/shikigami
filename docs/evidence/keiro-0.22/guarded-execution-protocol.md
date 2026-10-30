# Guarded execution protocol (K22-4)

Plan 93 M1 is accepted in commit `eb8eeac`. Its 50 native transcript cases prove
accepted convergence, typed refusal, tentative-append rollback under catalog
fencing, all-eventful live edges, and late refusal after observing tentative cursor
and accounting writes. M2 expands that protocol; all 379 native core PostgreSQL cases pass.
The source retains its late protected input read even when its value is unused,
preserving the final access-expiry check before tool reservation.

Every lifecycle catalog write in `Shikigami.Execution.Store` now enters
`persistGuarded`, directly for outcome recording or through `persistChecked`.
The latter interprets `ExceptT ExecutionError Transaction` preparation twice:
first as the typed guard, then to reread values for inline delivery under retained
row locks. No mutable cell crosses the callbacks. Preparation contains bounded
application SQL, row/identity locks and pure checks; no reservation, settlement,
publication, independent transaction or external effect occurs there. A late
read-permit expiry remains a refusal through whole-transaction rollback.

The common order remains the store append/catalog fences, application root,
execution, operation/attempt and then the existing attempt-identity transaction
lock where needed. Participating owner operations retain those locks until commit.
New admission, operations, permissions, wakes, claims, dispatch start/abandonment,
stop/finish, late receipts and reconciliation now return applicable pre-inline
business checks through `PreconditionRefused`. Exact operation fingerprints,
claim generations, scoped identity, root authority and immutable snapshot checks
remain unchanged.

Retained exception sites are intentional:

- `writePayload` verifies the actual stored digest/bytes after publication. A
  conflict or corrupt replay must unwind the transaction.
- Selection-call and root reservation/settlement owners can refuse while writing
  coupled accounting. They remain in the inline transaction.
- Retiring an uncertain attempt changes pending membership. Its subsequent
  pending-attempt assertion must observe the tentative retirement; failure rolls
  that retirement and the lifecycle append back together.
- Queue acceptance is the existing queue owner's transaction callback. A failure
  rolls back reservation, prepared attempt, wake and lifecycle append.
- `recordOutcomeAndAdvanceWith` invokes its final hook after payload/cursor and
  accounting writes. Claim/fence checks and deliberate faults there retain the
  existing `ExecutionAbort`/`CheckFailed` boundary.
- Protected payload decoding and read access are separate from ordinary expected
  admission. They retain explicit corrupt/unsupported/replay-read refusals.

`checkStartedExecutionAttempt` is a read-only dispatch-authority check without a
lifecycle catalog append. Its existing transaction/authority checks remain with that owner;
there is no aggregate command to wrap merely to use the new API.
