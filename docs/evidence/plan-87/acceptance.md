# Plan 87 acceptance

Qualified on 2026-11-09 UTC from baseline
`751afde63a726ebf7256073e746e4eaa00dab95a`.

The production feature is explicit recurring **read-only checkpoint supervision**.
`ContinuingCoordinator` observes in the continuing controller;
`FreshCycleRun` uses a separately resumed bounded child. Both consume the real
objective owner's current snapshot and accepted receipt under its lock, retain
assignment fences and the same finite resource root, and publish generation-owned
wakes through existing owners. The fixture does not substitute a synthetic
checkpoint provider. All databases are disposable.

## Qualification

The complete four-suite command exited zero: **787 core, 681 PostgreSQL,
353 worker and 114 server cases**. Final focused verification also passes
**3 pure, 16 PostgreSQL recurrence and 2 serving-timer cases**. That final group
includes named source JSON encoding and uncertain root holds in separate expiry,
revocation and cancellation trials. Six diagram cases and the hand-owned domain
behavior/guard controls pass.

```bash
nix develop --no-write-lock-file -c cabal build all
nix develop --no-write-lock-file -c cabal test shikigami-core-test shikigami-core-postgres-test shikigami-workers-test shikigami-server-test -j1 --test-options=--num-threads=1 --test-show-details=direct
nix develop --no-write-lock-file -c cabal test shikigami-core-test shikigami-core-postgres-test -j1 --test-options='--pattern=Mandate --num-threads=1' --test-show-details=direct
nix develop --no-write-lock-file -c cabal test shikigami-workers-test -j1 --test-options='--pattern=MandateTimer --num-threads=1' --test-show-details=direct
nix develop --no-write-lock-file -c cabal test shikigami-core-domain-test shikigami-core-diagrams-test
nix develop --no-write-lock-file -c just migration-schema-isolation
nix develop --no-write-lock-file -c just keiro-gate 751afde63a726ebf7256073e746e4eaa00dab95a
nix fmt
python3 tools/style/check_haskell.py
python3 -m unittest discover -s tools/style -v
```

The build, schema isolation, formatting and Haskell conventions pass; all thirteen
style mutation checks pass. Native `shikigami mandates --help` exposes create,
inspect, update and cancel. Server parser controls require operation keys and
expected revisions and reject negative versions before IO.

The ordinary deployment gate passes **210 conformance controls**. Its retained
[compatibility report](compatibility.json) contains eleven additive findings and
`breaking: false`; [replay impact](replay-impact.json) is `replay-neutral`.
Existing durable bodies, patch branches and result codecs retain their contracts.
The new lifecycle, three targets, read model, projection owner and two workflow
families are additions. Migration 0049 supplies the application-owned DDL.

## Observable acceptance

| Requirement | Accepted production path and observation |
| --- | --- |
| Explicit ongoing versus finite admission | Ordinary objective creation and verified completion create no mandate. Explicit admission requires a finite root/expiry and bounded scope/source/cadence. A successful ongoing cycle retains next due. |
| Idempotent controls | Identical admission/edit retries recover the original receipt; conflicting payloads, stale versions, unavailable authority, foreign/missing roots and root-exceeding extensions refuse. |
| Coalesced current-state work | Concurrent wakes accept one active cycle. The serving timer pass recovers a crashed `Firing` claim while an objective event targets the same generation; the updated checkpoint is consumed once. |
| Restart at progress/wake boundary | Accepted watermark, receipt and desired due survive before listener/timer installation. The admitted native controller repairs publication without another accepted evidence cycle. |
| Restart at child/input boundary | A fresh child discovered without input suspends. Publishing its original native input resumes the same identity, accepts one checkpoint and replays its completed result. |
| Replaced instructions and assignments | Replacement instructions and an assignment owner change precede commit. The accepted cycle records the current instruction/criteria revisions, checkpoint and owner fences; no old assignment is recreated. |
| Honest stops | Verified objective completion, expiry, revoked coordination, reduction to reader and cancellation close admission. Late claimed timer rows cannot revive it; exact owned timers/listeners retire. Uncertain actual root attempts retain their original holds and remain inspectable. |
| Useful idle retention | Repeated unchanged observations keep the previous cycle, cap exponential backoff, and add no objective progress, worker or provider attempt. A later source change accepts the next cycle once. |
| Shared root and inspection | Continuing/fresh cycles retain the original root; root equality controls show no replenishment or discarded unknown usage. Inspection combines mandate references with authoritative resource state. The administrative aggregate display exposes only mandate ID and revision. |

The owning tests are `shikigami-core/test/Shikigami/MandateSpec.hs`,
`shikigami-core/test-postgres/Shikigami/MandateStoreSpec.hs`,
`shikigami-workers/test/Shikigami/MandateTimerSpec.hs`, and the server command and
inspection suites. Operator usage is in
[recurring objectives](../../operations/recurring-objectives.md); durable context
is in [ADR 0121](../../adr/0121-recurring-mandates-retain-authority-checkpoint-receipts-and-generation-owned-wakes.md).

FRIC-65 is accepted: full worker qualification rewrites Plan 113's retained
artifact with new fixture identities. The historical file was restored after
the suite; its original evidence is not part of this change. The entry and triage
are in `docs/friction-log/`. Plan 86's separate live coding trial remains with
that child; this qualification uses governed read-only evidence.
