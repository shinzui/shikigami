# Adaptive delivery native qualification

The full fixture command passes with exit 0 and `state: passed` on 2026-11-04.
The driver source is clean `805b34f6`; the selected immutable runtime is
`5ee0dd83`. Its native phase takes 449.866 seconds. The [final facts](native-facts.json)
retain the source/runtime identities, environment, exact artifacts, resource
accounting, selection tuples, refusal controls and recovery receipts.
Milestones 1 and 2 are complete. UC-1/IR-16 and the live milestone remain open.

| Repository | Combined commit | Exact tree |
| --- | --- | --- |
| `mori://fixture/adaptive-producer` | `42da1305db9f3b26d82db286f6c5af0ec6725bba` | `af81302c9ab6d1ccd298179869cc00970d311f28` |
| `mori://fixture/adaptive-consumer` | `d540d242414b1ff442b81dabbe7715e174154161` | `7068c31fead3c40b9cb8f520f0e7770a7fb3eb35` |

All six worker/combined bundles restore independently, pass object/parent checks,
and reproduce both integration trees from the exact worker pairs. The journey
on the returned immutable pair prints `combined journey passed: hello`.
Four sessions retain five messages/results. The seven adaptive provider calls
and two calls for each of the five worker roles survive controller faults and
terminal replay without repetition. Root accounting records 21 model attempts
(including four trusted integration fixture records) and 27 tool attempts
(including two accounting-only probes); active and unknown work are zero at
acceptance. No paid model transport ran.

The passed cuts cover adaptive-validation acknowledgement loss, committed tool
outcome, unconsumed atomic result/wake, accepted follow-up and objective ownership
commit before local successor establishment. A lost real edit reply retains its
original uncertain root hold, refuses the eventual successor through the
concrete workspace owner with a passing old-owner control, and recovers its
original independent late receipt. A separate valid-proposal accounting hold
requires `ObjectiveUnresolved`, then the exact acceptance operation succeeds
after reconciliation. Last-slot reservations, foreign alias, undeclared target,
fresh action authority and process-default drift controls also pass. All 50 host
qualification-tool cases pass. The integration wake errors from the earlier
baseline are absent in both complete `5ee0dd83` native runs.

The earlier complete native run took 451.725 seconds, but its first host verdict
failed because the parser expected a string instead of the real tagged
`ObjectiveError` object. Rechecking the unchanged retained evidence with that
codec corrected passed all artifact/proof checks. The final run above repeats
the whole command with the corrected parser and produces the passing manifest.

The [live missing-configuration control](live-blocked-control.json) returns
blocked/exit 2 without model work. Actual-model coding, production authorization
and approved live limits remain required. Codex CLI is installed/authenticated
but its foreground path does not establish durable response/executor
qualification; choosing that route expands the currently excluded executor
scope. No use-case or request completion is inferred from these scripted trials.

The corrected baseline passes on clean `39ef7263` in 324.755 seconds. Its
[retained facts](baseline-native-facts.json) bind both exact integrated trees,
six independently restored Git artifacts, the returned-pair journey, controller
restarts, fresh authority controls and unchanged terminal replay. Milestone 1
is complete. That reduced baseline retains a blocked full-matrix verdict; the
separate actual-model/production-authority trial has not run.

The first full transfer attempt on that runtime failed after 232.541 seconds.
Its [partial facts](transfer-attempt-facts.json) retain the passed last-slot
root race, foreign-alias refusal and undeclared-target refusal. The unknown-edit
probe incorrectly expected the owner to reject a transfer request while work
was active. The actual contract permits recording a queued handoff while
withholding successor establishment. The corrected probe checks the real
successor write-admission owner directly, without creating a handoff. It uses
the concrete production owner in-process while its independent publisher/RPC
process is paused, requiring real fresh authority, OS locks, a passing old-owner
control and an unchanged root hold. A later
valid-proposal accounting hold separately isolates the completion resource gate.
Those probe corrections are exercised by the complete runs above.

The passing baseline's two manually driven integration executions also emitted
receipt wakeups without an initial driver seed, producing harmless retries while
their factual effects and root accounting settled. The fixture now supplies only
those two known starts to the normal execution driver so it can observe their
terminal state. Worker starts still use normal production admission. This fix
is exercised by the complete runs above.

The first coupled trial on 2026-11-04 UTC failed during initial objective setup.
It does not qualify adaptive repository delivery, any recovery cut or the live
trial. No request or use-case acceptance is closed by this attempt.

The runtime was built from `64d9e4f4` as
`/nix/store/86b1rrqsqyqyl2dh76imp6smzzkg0k3q-shikigami-workspace-prototype-0.1.0.0-64d9e4f`.
The driver recorded source checkpoint `d4735a1f` with a dirty working tree; that
fact limits its source attribution. Its private attempt was
`build/adaptive-delivery-fixture/20261104T061012772850Z-fixture/manifest.json`.
The disposable arm64 Apple guest used native payloads and guards with the x86_64
Haskell controller outside their namespace. No host mounts, existing SSH keys or
model credentials were supplied.

Both repository-local checks passed and the initial combined journey correctly
failed. Native provisioning passed both original-identity/ready-acknowledgement
recovery checks. The native phase then exited 1 after 59.739 seconds. Its
`adaptive-admit.log` identifies the fixture's objective command path at
`Adaptive.hs:179`; no adaptive worker workspace had been allocated.

The fixture's initial assignment named a resource root while omitting its
cutoff. `Objective.Acceptance.validateGraph` explicitly requires both fields to
be present or both absent. The correction starts with the same unbound
assignment shape used by the qualified native coordinator tests; native
admission supplies the root and cutoff together. The shared initial assignment
now passes the executable host `adaptive-contract` check. Command failures also
name the fixture operation and objective error rather than discarding them.

Early-failure artifact collection separately encountered SQL NULL from an
empty binding aggregation. The runner now requests JSON `[]` for that case,
preserving an empty forensic inventory without claiming an artifact or a settled
effect. Subsequent failures retain bounded objective/receipt metadata as well as
the existing workspace diagnostics. A queued `2dce160d` build was stopped before
completion because it contained the same invalid initial assignment.

Run the cheap contract check before building a new immutable Linux runtime:

```bash
nix develop --no-write-lock-file -c cabal run workspace-linux-fixture -- adaptive-contract
```

It prints `PASS native adaptive initial assignment is valid before root/cutoff admission`.
This is a graph contract check, separate from runtime qualification. The current
passing baseline/full-matrix results are recorded above; the live trial remains
required.
