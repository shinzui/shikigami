# Continuing-worker consumer acceptance

Accepted on 2026-11-03. [Retained results](acceptance.json) name implementation
checkpoint `b8611d2b`, baseline `0e38c0a8`, the immutable Linux controller and
streamed runner `f9cba01e`. All 1,703 host package cases, the domain suite,
177 workflow conformance controls, migration isolation and style checks pass.
Nine focused native ownership/restart cases pass, including two exact
established-handoff replies from the administrative command itself. The prior
full 25-case workspace matrix remains separate evidence.

| Requirement | Consumer evidence | Real-provider evidence |
| --- | --- | --- |
| IR-15 acceptance 1: two assignments, retained findings and restart continuity | `WorkerSessionSpec`: two governed assignments survive rotation with distinct child/run identities; `WorkerSessionCapabilitySpec`: continuing follow-up compacts and resumes with retained findings | Plan 96 configured durable worker and same-owner follow-up cases |
| IR-15 acceptance 2: duplicate follow-up/event and one integration | `WorkerSessionStoreSpec`: concurrent identical acceptance, checkpoint acknowledgement loss and cursor rollback; `WorkerSessionCapabilitySpec`: replayed event page and native command | Plan 99 simultaneous sibling integration, lost acknowledgement and local-cursor rollback |
| IR-15 acceptance 3: active/idle follow-up ordering | `WorkerSessionStoreSpec`: ordered follow-ups, result/follow-up races and assignment-bound interruption; combined compaction case retains a third queued assignment | Plan 96 same-owner follow-up preserves workspace and Unix identity |
| IR-15 acceptance 4: unresolved in-flight transfer and old-owner refusal | `WorkerSessionHandoffSpec`: uncertainty, proof substitution, active assignment and missing execution evidence | Plan 96 full 25-case real-objective matrix; this closeout additionally exercises the actual administrative recovery path across supervisor/controller restart |
| IR-15 acceptance 5: retained idle work and authority/resource refusals | `WorkerSessionSpec`: idle retention, missing/stale authority and pre-spawn root refusal; capability/store tests cover foreign targets, revoked authority and unchanged limits; governed delegation retains cycle/depth checks | Plan 99 retained scopes, scope publication rollback and revoked membership; Plan 96 fresh exact authority and former-owner refusal |
| IR-15 acceptance 6: recover a completed child before notification | `WorkerSessionSpec`: registered-child repair and two retained results; handoff tests recover a result committed before owner change; capability tests repair driver registration and replay event pages | Plan 99 checkpoint receipt recovery; Plan 96 accepted-result/receipt recovery after intake and controller loss |
| IR-14 acceptance 8: follow-up, compaction, crash and coordination replay | The combined PostgreSQL case drives a real continuing assignment, accepts a recorded summary, reconstructs its execution driver and replays the same native command; accepted selection, pending message, session state and shared ledger remain unchanged | Provider scope/ownership and native fencing are qualified separately by plans 99 and 96; no model network call or live coding trial is claimed |

The consumer fixtures use deterministic model responses and selected fixture
checkpoint/scope providers. The production objective and workspace gates are
retained separately; fixture success does not replace their evidence.

Plan 85 owns adaptive proposal validation, asynchronous typed decisions and
measured bounded concurrency. Plan 86 owns the combined-artifact/live coding
trial and the integrated UC-1 recheck of IR-14 acceptance 8. Plan 87 owns
explicit recurring mandates. Those outcomes are outside this closeout.

Historical provider evidence is retained in
[plan 99](../plan-99/provider-completion-qualification.json) and
[plan 96](../plan-96/joint-native-qualification.json).
