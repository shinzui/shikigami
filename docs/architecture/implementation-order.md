# Shikigami implementation order

Reviewed 2026-08-05 (revised later the same day: plan 28 M1 landed, and plan 38's codd import
was cancelled). This document is the narrative companion to
`docs/architecture/implementation-order.html`, which renders the same state as an interactive
dependency board. Where the two disagree, the MasterPlan registries win — each MasterPlan's
Exec-Plan Registry is the authority for its own children's status, and this document is a
cross-MasterPlan reading of them.

The portfolio is 52 ExecPlans across 10 MasterPlans. Sixteen are complete. The narrow foundation
chain finished on 2026-07-31, so the remaining work is wide rather than serial: nothing on the
critical path is waiting on another repository.

Two changes on 2026-08-05 widened it further. Plan 28's Milestone 1 landed `Shikigami.Log` and
the run/call correlation vocabulary. And plan 38's codd-ledger import was **cancelled** —
shikigami has no users, so no database's history needs preserving, and codd was removed from
the repository outright instead. Plan 38 was the portfolio's widest blocker; what it actually
gated was a working pg-migrate authoring path, which exists and is proven, so that gate is
released and only its configuration remainder is open.


## What is done

Six plans landed on 2026-07-31 and between them they closed the foundation:

- Plan 36 gave the repository its six packages — `shikigami-core`, `-api`, `-server`, `-workers`,
  `-migrations`, `-client` — with the dependency arrows asserted by a test that fails the build on a
  forbidden sibling edge, and a generated `docs/api/openapi.json`.
- Plan 37 put nine of ten executables on one typed `AppConfig` resolved through Settei, with fixed
  precedence, rejected unknown keys, and structurally redacted secrets.
- Plan 47 selected the whole dependency cohort from Hackage by version with no `allow-newer`
  between co-developed packages, and removed the codd migration stack from the repository entirely.
  Plan 38's remaining codd-ledger import was cancelled on 2026-08-05, so nothing in the tree
  refers to codd as a live path any more.
- Plans 13, 15, and 16 made the runtime honest: a real model provider that cannot run unannounced,
  behavior arms that receive the trigger payload and recalled memory, and sink handlers that really
  deliver or really fail.

Six more plans — 1 through 6 — completed the original bootstrap, and plans 7, 9, 10, and 11
completed durable workflows, delegation, timers, and the behavior DSL before the MasterPlan
structure existed. Those four, plus plan 8, belong to no MasterPlan registry; see Coverage gaps.

Two deferred items from that cohort are worth naming because they are still open:
`shikigami-migrate` resolves `DATABASE_URL` itself rather than through `AppConfig`, blocked by a
Cabal package cycle and reassigned to plan 38; and plan 13's live Anthropic smoke was never
performed because no credential was available.


## Startable today

Every hard predecessor of these is complete, and none has an upstream gate on its first
milestone.

| Plan | MasterPlan | Why it is worth starting |
|---|---|---|
| 38 (remainder) | 3 · Correctness | Now small: only the `shikigami-migrate` Settei unification, blocked by a Cabal package cycle. M1 and M2 were delivered by plan 47; M3, the codd import, was cancelled 2026-08-05. **No longer gates schema authoring** — plans 19, 21, 23, 35, and 51 may add migrations today. |
| 19 | 3 · Correctness | Newly startable: both its gates cleared on 2026-08-05 (plan 28 M1 landed; plan 38's schema gate released). Only its terminal-delivery milestone waits on Keiro IR-3. |
| 39 | 5 · Durable evolution | **Now the widest:** gates plans 24, 25, 26, 27, 35, 50, and 51. Every new journaled value and durable state machine passes through it. |
| 17 | 3 · Correctness | With plan 18, releases plan 20; also half of plan 14's gate. |
| 21 | 3 · Correctness | Newly startable: its only gate was plan 38's schema-authoring path, which is proven. |
| 18 | 3 · Correctness | Atomic offsets, inbox, and enqueue in one boundary. Independent of 17. |
| 43 | 9 · Practice reviews | Contract-only, no dependencies. Fully startable since plan 47 landed. |
| 49 | 10 · Attestation | Contract-only, no dependencies. Lands the vocabulary nine other plans would otherwise each invent. |

Two more have startable local halves with upstream-gated milestones deferred: plan 12 (M1–M2 now,
live MCP connect and invoke behind three upstream contracts) and plan 29 (the local health slice
now, the worker probe behind Shibuya IR-1).


## Waves

Waves are entry rules, not schedules. A plan may start when its wave's rule is satisfied.

| Wave | Work | Entry rule |
|---|---|---|
| 0 | 43, 49; nine open upstream requests | Open. Both are contract-only with no hard dependencies. |
| 1 | 36 | Complete 2026-07-31. |
| 2 | 37 | Complete 2026-07-31, except the migration executable's Settei unification — reassigned to plan 38. |
| 3 | 47 | Complete 2026-07-31. The codd stack was removed here. |
| 4 | 38 (remainder), 39, 28 M1 ✅ | 28 M1 complete 2026-08-05. Plan 38's import is cancelled and its schema gate released, leaving only its configuration remainder. Plan 39 is now this wave's substance. |
| 5 | 13 ✅, 16 ✅, 17, 18, 21, 24, 50 | 17, 18, and 21 startable now — 21's wait on 38 is released; 24 and 50 wait for 39. |
| 6 | 15 ✅, 19, 20, 22, 25, 26, 30, 33, 51 | 19 is startable (16 ✅, 28 M1 ✅, 38's gate released) → 22; 17+18 → 20; 20 → 30 and 33; 24+39 → 25 and 26; 51 now needs 49+50+39 only. |
| 7 | 12 (runtime), 14, 23, 27, 29, 32, 34, 35, 48, 52 | 12 and 29 have startable local halves now; 52 waits for 51, 22, and 44. |
| 8 | 40 → 41 → 42 | Router declaration, then catalog, then replay-safe execution. All wait on plan 33. |
| 9 | 44, 45 → 46 | Practice-review evidence and memory, then end-to-end orchestration. All wait on plan 43. |
| 10 | 31 | Operations closure, after the public configuration and health surfaces settle. |


## MasterPlan 10, and why it slots in without disruption

`docs/masterplans/10-sanctioned-execution-attestation-for-agent-runs.md` answers
`docs/improvement-requests/attest-sanctioned-agent-execution.md`: make an agent run's execution
provable, so a protected repository can gate a code change on a review a trusted runtime performed
under a policy it can prove it obeyed. It adds four plans.

Plan 49 is contract-only and startable now. Plan 50 needs plan 39. Plan 51 needs 49, 50, 38, 39,
and 28 M1. Plan 52 needs 51, 22, and 44. So the initiative's real prerequisites are exactly the
wave-4 plans that were already the recommended next step — it lengthens the portfolio without
reordering it.

One dependency in that chain deserves emphasis because it is the largest avoidable rework in the
whole portfolio. Plan 50 adds a journaled workflow step and plan 51 adds a durable state machine.
Both are precisely what plan 39's checked specification and evolution gate govern. Hand-authoring
either and re-expressing it under the specification afterward means doing the work twice, which is
why both hard-depend on plan 39 rather than merely preferring it.

Plan 49 is scheduled first for a different reason: nine existing plans are each about to define
something the attestation binds — an agent version, a repository revision, a correlation id, a
review-request id, a tool-catalog digest. Landing the vocabulary before they do turns nine future
reconciliations into nine citations. Those obligations are now recorded in each plan's Portfolio
Reconciliation section: plans 12, 14, 22, 28, 33, 35, 39, 43, 44, and 48.


## Upstream gates

Nine requests in other repositories gate milestones here. Every one was `proposed` as of
2026-08-05 — written down and in some cases reviewed, but not implemented.

| Request | Gates | Note |
|---|---|---|
| Kioku IR-1 | plan 47 | **Completed.** The only closed gate. |
| Kioku IR-2 | plans 26, 34 | Indexed sessions and bounded memory reads. |
| Keiro IR-3 | plan 19's terminal-delivery milestone | Its implementing plan, `mori://shinzui/keiro/plans/165-add-terminal-outbox-publication-rejection-outcomes`, has none of its four milestones done and `PublishRejected` appears nowhere in keiro's sources. Use this as the calibration for how long a `proposed` request takes. |
| Shibuya IR-1 | plan 29's worker probe | Local health slice is startable without it. |
| Baikai IR-2 | plan 12 M3–M5 | MCP client, tool, and auth contracts. |
| Shikumi IR-1 | plan 12 | MCP-to-ToolRegistry adapter. |
| Kikan-En IR-3 | plan 12 | Per-action agent authorization. A declaration is never authorization. |
| Kikan IR-5 | plans 44, 46 | Revision-pinned content plane and tool environment. Also a second consumer once plan 52 needs revision-pinned reads. |
| Baikai IR-3 | plan 51's real evidence | **New 2026-08-05.** Supplies `ModelCallEvidence`. Worked around with a deterministic seam and stub fixtures, so no plan-51 milestone waits for it. |
| Kikan IR-6 | plan 52 | **New 2026-08-05.** Ratifies the canonical attestation envelope, encoding, hashing, and redaction rules, and publishes the golden payloads plan 52 must match byte-for-byte. This one genuinely binds. |

The pattern worth copying: where an upstream contract is pending, define a reader or source record
of function fields, satisfy it with a stub plus fixtures in tests, and let the live client replace
the stub later. Plan 44 does this for the content plane; plan 51 does it for call evidence.


## Coverage gaps

Three findings from the 2026-08-05 audit that no registry currently reflects.

**Three inbound requests have no plan.** `docs/improvement-requests/` holds seven requests kikan
filed against this repository. IR-1 maps to plan 23, IR-3 to MasterPlan 8, IR-4 to MasterPlan 9,
and IR-7 to MasterPlan 10. **IR-2** (authorized cross-cluster diagnostic tools), **IR-5** (governed
agent evolution), and **IR-6** (A2A cross-runtime interoperability) appear in no MasterPlan or
ExecPlan.

IR-5 is the consequential one. It asks for declaration revision, behavior artifact identity, run
pinning, baseline-to-candidate relation, and rollout policy — and plan 33, the plan that looks like
it should own that, covers only the `identity`, `memory`, and `enabled` declaration fields. Plan 49
now defines the minimum immutable agent identity that MasterPlan 10 needs (`AgentVersionRef`,
`AgentArtifactSet`), shaped so a future governed-evolution plan extends it additively rather than
introducing a second vocabulary. Plan 33 records that it does not own this.

IR-6's upstream counterpart, `mori://shinzui/kikan/okf/improvement-requests/concepts/IR-4`, is the
only `accepted` request in kikan's queue. An accepted upstream request with no plan here is the
most awkward of the three.

**Five plans belong to no MasterPlan.** Plans 7, 9, 10, and 11 are complete; plan 48 is not
started and is flagged as unregistered on the board. Plan 8 is the odd one: it is complete in
substance — the Danwa polling bridge is gone from the tree — but still carries two unchecked
Progress items, one of which (a build-and-test run after the bridge removal) was subsumed by the
cohort work's 157 passing tests, and one of which (manual verification against a live Danwa worker)
is real but small.

**Two older plans carry stale package placement.** Plans 43 and 33 name `shikigami-api` and modules
`Shikigami.Api.Agent` and `Shikigami.Api.RunJob` for domain contracts. Plan 36 made
`shikigami-api` the public HTTP contract package that depends on `shikigami-core`, forbade
`shikigami-workers` from depending on it, and moved the domain — the run job is now
`shikigami-core/src/Shikigami/Agent/RunJob.hs`, the declaration is
`shikigami-core/src/Shikigami/Agent/Decl.hs`. Plan 43's Portfolio Reconciliation now records the
correction. More broadly, every child of MasterPlan 3 still names pre-split paths in its Context
section; MasterPlan 3 records the corrected file map in one place, and each child must be
re-pointed at it before implementation.


## Recommended order

1. **Start now, in parallel:** 39 — now the widest single unblocker, gating 24, 25, 26, 27, 35,
   50, and 51 — plus 43 and 49, which are contract-only and need nothing, plus 19 and 21, which
   the 2026-08-05 changes released.
2. **Next:** 17 and 18 together, which release 20. Then 50 once 39 lands, and 22 after 19.
3. **Then:** 24, 51; then 52 as Kikan IR-6 and Baikai IR-3 mature. Plan 38's configuration
   remainder can land whenever the package cycle is broken; only plan 31 waits on it.
4. **Close the credential gap** on plan 13's live smoke. It was an accepted gap; it is now a
   precondition of plan 52's positive conformance case, because a run that never reached a real
   provider cannot demonstrate a `sanctioned` attestation.
5. **Decide on the three unplanned inbound requests.** IR-6 has an accepted upstream counterpart;
   IR-5 is what plan 49 is deliberately shaped to accommodate later.
6. **Coordination:** file and push the two new upstream requests. Kikan IR-6 is the one that
   genuinely blocks — plan 52 cannot freeze its canonical encoding without it.
