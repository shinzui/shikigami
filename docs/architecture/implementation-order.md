# Shikigami implementation order

Reviewed **2026-08-22**, superseding the 2026-08-21 review. Goal of this revision: absorb the
largest single movement this portfolio has seen — **thirteen plans landed across two days** — and
re-cut what remains around one explicit objective: **land shared types and seams before their
consumers so the sequence minimizes rewrites**.

The first is that **seventeen MasterPlan registry rows now call a complete plan "Not Started"**,
which breaks the status-precedence rule this document has carried since it was written. The second
is that the audit-before-implement instruction adopted on 2026-08-19 **paid for itself and caught
more than it was aimed at**: it was written for stale `file:line` citations, and what it kept
catching was wrong premises.

The standing facts, with two additions.

**Shikigami has no users.** No database's history needs preserving, no workflow instance is in
flight across a deploy, and no wire payload has an external consumer. Every "preserve this
byte-for-byte", "import the old ledger", "survive the upgrade" obligation written into these plans
is therefore *not* v1 work. This now has a second, sharper consequence: the thirteen landings
installed **five patch guards whose legacy branches are unreachable code** — see
[Compatibility work that v1 does not owe](#compatibility-work-that-v1-does-not-owe).

**The cohort is current and has no exclusions.** Re-verified 2026-08-20 against the upstream
working trees: nothing released past what `cabal.project` pins. Three packages *joined* the cohort
during the landings without moving anyone's version — `keiro-pgmq` and `keiro-ops` at 0.13.0.0, and
`shibuya-kafka-adapter` at 0.9.0.0.

**New — the MasterPlan registries are no longer the authority on status.** Every one of the thirteen
plans that landed still reads `Not Started` in its registry row, as do plans 21, 39, 53, and 55,
which this document has listed as complete for two revisions. See
[Registry rot](#registry-rot-seventeen-stale-rows). The precedence rule is therefore amended: **the
plan file's own Progress and Outcomes sections win on status**, this document is the cross-plan
reading of them, and a registry row is evidence only when it is newer than both. Where this
document and a registry disagree about *order*, this document is still the newer cross-MasterPlan
reading.

**New — a plan's premises rot faster than its citations, and its citations faster than its
reasoning.** The 2026-08-19 review found 21 of plan 24's 59 citations pointing at deleted paths and
concluded that pointers rot while arguments survive. Thirteen implementations later, that is
half right. Each of the thirteen was refreshed against the delivered tree before implementing, and
four of them found something worse than a bad path: plan 25 carried two acceptance criteria that could not both hold, plan 26's
central decision was contradicted by an ADR written the previous day, plan 30's whole shape was
obsoleted by a released `keiro-ops`, and plan 20 found three more decayed premises during
implementation than its own pre-implementation refresh had caught. The instruction stands and is
widened in [Citation rot](#citation-rot-re-measured).

`docs/architecture/implementation-order.html` renders the 2026-08-05 state and is **stale**.


## The open set

55 ExecPlans across 10 MasterPlans. **32 are complete**; 23 have open work.

Complete: 1, 2, 3, 4, 5, 6, 7, 9, 10, 11, 15, **17**, **18**, **19**, **20**, 21, **24**, **25**, **26**,
**29**, **30**, **33**, **35**, 36, 39, **43**, 47, **49**, **50**, **51**, 53, 55. Thirteen bold entries
landed on 2026-08-19 and 2026-08-20; plans 19 and 35 landed on 2026-08-22. See
[what landed](#what-landed-and-what-it-changes-for-everyone-else). Plan 30 counts as complete
because its Outcomes section says the purpose is met; its one unchecked behavioral test was
explicitly descoped in favor of the upstream `keiro-ops` coverage plus Shikigami-owned parser,
dispatch, and redaction tests.

Open with a small remainder (5 plans, ~1 session each):

| Plan | Remainder |
|---|---|
| 8 | One manual verification against a live Danwa worker. Its other open box — "run the full build and test suite after the bridge removal" — has been satisfied incidentally many times over; the last recorded full-suite run is plan 26's on 2026-08-20 (432 tests green). |
| 13 | Live Anthropic smoke transcript. Never performed — no credential was available. Still a precondition of plan 52's positive conformance case. |
| 16 | One optional live observation of the outbox retrying a real sink. Not a gate on anything. It also still owns the `emit-signal:<label>` family, which plan 24 made *stable* without making it *declarable*. |
| 37 | M3, **and its description was stale**: the `CODD_*` contract is gone. `shikigami-migrate` now reads `DATABASE_URL` itself through `pg-migrate`, with the reason written into `shikigami-migrations/app/Main.hs:1-25`. What remains is Settei unification, still blocked by the package cycle (`shikigami-core`'s test suite depends on `shikigami-migrations:test-support`). Reassigned to plan 38. |
| 38 | M4: the same Settei unification, plus `just migrate` and `just migrate-status` still passing `DATABASE_URL` (`justfile:27-39`). |

Open and substantial (18 plans): 12, 14, 22, 23, 27, 28 (M2–M4), 31, 32, 34, 40, 41,
42, 44, 45, 46, 48, 52, 54.


## What landed, and what it changes for everyone else

The thirteen-plan 2026-08-19/20 landing is grouped below; plans 19 and 35 are summarized in the
2026-08-22 revision note. Each entry is what shipped, then what it costs or saves someone else.

### Correctness and delivery — plans 17, 18, 20

**Plan 17** put the retry boundary before the journal: a transient behavior error or timeout
escapes before Keiro can append a step result, while a permanent one is bounded, redacted, and
journaled once. Both durable families run under patch `shikigami-behavior-retry-v1`. The run-job
consumer moved onto **`keiro-pgmq` 0.13.0.0**'s typed `Job RunJob` surface with startup
main-queue/DLQ reconciliation and a linked visibility heartbeat (10s renew against a 30s lease).
Settei gained `worker.run_timeout_seconds` (300) and `approval.deadline_seconds` (900).

**Plan 18** closed the loss windows: Kafka offsets advance only after durable dispositions
(ADR 0009), inbox matches enqueue atomically, and application code no longer imports a Kafka
client — `shibuya-kafka-adapter 0.9.0.0` entered the cohort to make that true.

**Plan 20** made routing declared rather than guessed: `RunJob` carries a `routeKind` every
producer sets, `routeRunJob` reads only that field (ADR 0014), and an undecodable conversation
payload reaches the reconciled DLQ as `invalid_route_payload` instead of silently running the other
workflow. The scheduler gained a catch-up policy — `skip_missed` by default, so waking a day late
arms one future tick (ADR 0016) — and a broken manifest or unparseable cron is now loud and
refusable at startup through `agents.strict`.

*For everyone else:* do not construct a Shibuya `AckDecision` for a run job, do not add a second
queue-initialization helper, do not add a second agent-directory traversal, and do not read the
process environment from scheduler or loader code. Plan 20 left two things named and unfinished:
its `InferredLegacyRoute` branch is transitional and waits on `worker.job.route_inferred`
disappearing from logs, and its "log and count" is log-only because **plan 28 M2 still owns the
counter**.

### Durable evolution — plans 24, 25, 26

**Plan 24** wrote the discipline (`docs/workflow-versioning.md`, nine rules, every journaled step
name inventoried) and proved `patch` end to end against a constructed in-flight instance.
`Shikigami.Workflow.Versioning` is the single construction site for `WorkflowRunOptions`
(ADR 0004). Its M4 was delivered differently and honestly: flow names stay in Haskell because
keiro-dsl has no node kind for them, and declaring one would have violated ADR 0001; `flowRegistry`
and `registeredFlowNames` became two projections of one list instead.

**Plan 25** made flow memory replay-safe: `remember` and `recall` are journaled steps under stable
labels declared in `domain/shikigami-agent-run.keiro`, and `FlowEffects` no longer grants `IOE` or
`Store`, so a flow reaches the world only through a capability (ADR 0013). The test that opened the
plan — replaying a completed flow duplicated its memory, `expected: 1, but got: 2` — passes.

**Plan 26** is the one that most exceeded its design. `rotateEvery` was never built, because **one
turn per generation makes the journal bound structural** rather than a tuning constant. The
conversation workflow ends an idle epoch, closes its kioku session, and re-keys the next epoch
(ADR 0018); every label is now static, which **discharged plan 39's largest undeclarable-label
family** and made `domain/shikigami-conversation.keiro` the largest declared body in the service —
five steps, one await, one `continueAsNew`. Session resolution uses a local index,
`shikigami.conversation_sessions`, with a self-healing miss path, because kioku IR-2 has not
shipped.

*For everyone else:* ADR 0012 — a declared workflow body only grows behind a patch — is a **gate
condition, not a style preference**, and it is the rule most likely to surprise the next plan that
adds a journaled step. Plan 26 argued at length that it did not need a patch and was wrong; plan 25
made passing the gate an acceptance criterion while concluding no patch was needed, and carried the
contradiction into implementation. Run `just keiro-gate` against a scratch copy of `domain/`
*before* writing Haskell. And run it with the tree committed: the gate does
`git diff --exit-code -- shikigami-core/src`, so a mid-change run reports a stale generated layer
that is not stale.

### Attestation — plans 49, 50, 51

**Plan 49** shipped five contract modules (`Shikigami.Attestation.{Profile,Agent,Reviewed,Strength,Envelope}`)
and froze the attestation payload encoding as a wire format (ADR 0006), with two evidence-strength
scales deliberately named apart (ADR 0005).

**Plan 50** made profile resolution fail closed: immutable versioned profiles in PostgreSQL, five
typed refusals, `resolve-profile` journaled under `shikigami-resolve-profile-v1` before
`open-session`, and — the correction that matters downstream — **the journal holds the complete
`ResolvedProfile`, not a reference to it** (ADR 0007), because a reference could not enforce the
original policy after the store mutated. Skill dispatch checks the actual Baikai model/options
tuple before any provider request.

**Plan 51** introduced **Shikigami's first checked aggregate**. `RunEvidence` has seven legal
transitions and 56 generated behavior obligations, `domain/shikigami-run-evidence.keiro` is the
workspace's third member, and migration `2026-08-20-01-53-56-run-evidence-and-call-records` adds
the run and call projections under one atomic lifecycle boundary (ADR 0010). The 2026-08-19 review
predicted this plan would turn on most of keiro-dsl's checked surface; it did.
`docs/architecture/shikigami-domain-inventory.md` is kept current with each landing and is the
reference for what the specification does and does not cover — its 2026-08-19 census of "no
aggregate, no read model, no projection" is now one aggregate and two projections out of date.

*For everyone else:* plans 51 and 52 must treat the journaled snapshot as the one policy identity
and **must not resolve a second copy from the store**. And plan 51 deliberately did not fabricate
the review-request identity or the reviewed artifact — MasterPlan 10 assigns that to **plan 14**,
which is now the definer of a stable typed review-request identifier as well as an approval plan.
That makes plan 14 part of the attestation path, not only the egress path.

### Operations and schema — plans 29, 30, 33, 43

**Plan 29** gave all four worker roles a real probe surface on their own listeners (8091–8094),
serving `servant-health` with no Shikigami sibling dependency. Liveness reports **loop progress**,
readiness reports **PostgreSQL reachability and nothing else** (ADR 0020), a dead loop takes the
process down with a non-zero exit (ADR 0019), and `failingSince` reports onset rather than
observation. Its lesson is worth repeating in full: the one real bug it shipped —
`databaseReachable` decoding `select 1` as `int8` — passed 74 worker and 342 core tests and was
caught by `curl`. **Acceptance for a probe has to include running the process and asking it.**

**Plan 30** mounted `keiro-ops`'s embeddable command tree instead of rebuilding another operator
layer. `shikigami agents list` renders the canonical load report, `shikigami runs show` joins a
Keiro workflow to the Kioku session id journaled by `open-session` or `resolve-session`, and the
mounted tree supplies workflow, journal, awakeable, timer, outbox, lease, resurrection, and PGMQ
dead-letter operations. That exact journaled join discharges the plan's possible Kioku IR-2
dependency. The mount also raised the repository's development floor to PostgreSQL 18 because
`keiro-migrations 0.13` refuses other major versions (ADR 0021).

*For everyone else:* plan 23 is now unblocked and should extend the existing `agents` command
rather than introduce a second inventory. Operator verbs over Keiro state stay mounted from
`keiro-ops`; Shikigami writes only joins or views that no owning library can provide.

**Plan 33** delivered declared identity, memory policy, and enablement, with defaulted fields
preserving the journal codec byte-for-byte (ADR 0011). It also delivered **plan 20's
`AgentLoadReport`** as a side effect of hard-depending on it.

**Plan 43** defined the practice-review contracts and, more usefully, promoted repository
provenance to shared domain vocabulary (`Shikigami.Repository`, ADR 0008) so plans 44, 49, and 52
cite one revision type rather than three.

### Two repository-level facts

Plans 20, 26, and 33 observed `cabal test all` hangs and serialized the suite with `-j1`. Plan 30
isolated at least one repeat of that failure to a `shikigami-worker` left running from manual
acceptance; after stopping it, all nine suites passed without the earlier failure. **Before
diagnosing or serializing the suite, stop locally running Shikigami processes; use `-j1` as the
capacity fallback, not as an architectural requirement.**

The ADR corpus went from 3 records to **21** in two days. Reading `docs/adr/` is now part of
pre-implementation audit, not optional context — plan 26 caught its gate contradiction by scanning
the corpus first, which was the cheaper of the two places to find it.


## The cohort, as pinned

Re-verified 2026-08-20 against `cabal.project` and the upstream working trees; no cohort member has
released past its pin. `docs/dependency-cohort.md` is the contract; this is the summary.

| Package | Pinned | Latest released | Current? |
|---|---|---|---|
| `keiki`, `keiki-codec-json` | 0.9.0.0 | 0.9.0.0 | ✅ |
| `keiro`, `-core`, `-migrations`, `-dsl` | 0.13.0.0 | 0.13.0.0 | ✅ |
| `keiro-pgmq` | 0.13.0.0 | 0.13.0.0 | ✅ **new — plan 17** |
| `keiro-ops` | 0.13.0.0 | 0.13.0.0 | ✅ **new — plan 30** |
| `kioku-*` | 0.4.1.0 | 0.4.1.0 | ✅ |
| `shikumi` (+ family) | 0.3.0.2 | 0.3.0.2 | ✅ |
| `baikai`, `baikai-claude` | 0.5.0.0 | 0.5.0.0 | ✅ |
| `pgmq-*` | 0.5.0.0 | 0.5.0.0 | ✅ |
| `shibuya-core` | 0.9.0.0 | 0.9.0.0 | ✅ |
| `shibuya-kafka-adapter` | 0.9.0.0 | 0.9.0.0 | ✅ **new — plan 18** |
| `shibuya-pgmq-adapter` | 0.14.0.0 | 0.14.0.0 | ✅ |
| `kiroku-store` / `-migrations` | 0.8.0.0 / 0.4.0.0 | same | ✅ |
| `shibuya-kiroku-adapter` | 0.5.1.1 | 0.5.1.1 | ✅ |
| `pg-migrate`, `settei`, `servant-health` | 1.1.0.0 / 0.2.0.0 / 0.1.0.0 | unchanged | ✅ |

Three of these arrived *because a plan went looking*, which is the pattern worth keeping: plan 17
found `keiro-pgmq` rather than hand-rolling a typed consumer, plan 18 found `shibuya-kafka-adapter`
rather than keeping a Kafka client in application code, and plan 30's refresh found `keiro-ops`
already shipping the command tree it had budgeted three milestones to build. **Check whether the
cohort already ships it before implementing a milestone** — three times in two days, it did.


## Registry rot: seventeen stale rows

Reconciled 2026-08-21 across `docs/masterplans/`. Thirty-six registry rows read `Not Started`.
**Seventeen of them name a plan that is complete**: 17, 18, 20, 21, 24, 25, 26, 29, 30, 33, 39,
43, 49, 50, 51, 53, 55. An eighteenth, plan 28, is also wrong in the other direction — its M1 landed
2026-08-05.

This matters more than a bookkeeping nit, because this document has told readers since it was
written that *"where this document and a MasterPlan registry disagree about a plan's status, the
registry wins."* Following that rule today would re-schedule seventeen finished plans. The rule is
amended at the top of this document: the plan file's own Progress and Outcomes sections are the
authority on status.

The cause is mechanical and forgivable — a plan's implementer updates the plan file, and updating
the parent registry is a second edit in a different directory that nothing enforces. The fix is
equally mechanical: seventeen row edits, plus the corresponding MasterPlan checklist boxes.
**That is the cheapest outstanding piece of work in the portfolio, and it should be done before
the next planning session rather than during it.** It is not on any critical path and is not
scheduled below; it is one sitting.


## Citation rot: re-measured

Re-measured 2026-08-20 over the then-26 open plans. Seventeen cited `shikigami-cli` or
`shikigami-core/src/Shikigami/Worker.hs`, but plan 30's hits were its own audit and correction
table. With plans 19, 30, and 35 complete and refreshed, **fifteen of the 23 open plans still
carry unfixed pointers**: 8, 12, 13, 14, 16, 22, 23, 27, 28, 31, 32, 34, 37, 40, and 48.
Two open plans (14 and 28) additionally carry line-numbered `keiro/src/...` citations predating
keiro 0.13.

The correction table is unchanged:

| Retired | Current |
|---|---|
| `shikigami-cli/src/Shikigami/Cli/Commands/*.hs` | `shikigami-server/src/Shikigami/Server/Command/*.hs` for `validate` / `render-lifecycle` / `grants`; the worker, scheduler, consumer, and run-behavior entry points are executables in `shikigami-workers` and `shikigami-agent` |
| `shikigami-core/src/Shikigami/Worker.hs` (resume loop) | `shikigami-workers/src/Shikigami/Agent/Workflow/Resume.hs` |
| `shikigami-core/src/Shikigami/Worker.hs` (run-job ack) | `shikigami-workers/src/Shikigami/Agent/RunJob/Worker.hs` |
| `shikigami-cli.cabal` | `shikigami-server/shikigami-server.cabal` or `shikigami-workers/shikigami-workers.cabal` |

**The standing instruction is widened.** Audit immediately before implementing — not as a batch —
and audit four things, not one:

1. Every `` `path:line` `` against the working tree and the pinned keiro tag.
2. **`docs/adr/`**, which now holds 23 records and grew rapidly. Plan 26's central
   decision was contradicted by an ADR that had landed the previous day.
3. **What the cohort already ships.** Three plans in two days found a released package doing work
   they had scheduled.
4. **The plan's premises about runtime behaviour it has not run.** This is the expensive one. Plan
   26's research was sound and three of its inferences about behaviour it had not executed were
   wrong; each was caught by a test the plan itself had specified. Plan 25 put it best: when a plan
   asserts what a dependency does, the assertion is a hypothesis until something executes it.


## Drift each plan must still absorb

- **`kioku 0.4`'s mandatory memory spaces and principals.** Every session/memory command record
  carries `memorySpaceId` and `actorPrincipal`. Shikigami answers both in
  `shikigami-core/src/Shikigami/Memory/Access.hs` with `legacyMemorySpaceId` and a
  `KnownPrincipal` over a self-asserted `shikigami.agent.<name>` ref. **Plans 23, 34, and 54 should
  treat that module as the seam they change.** Plans 50 and 51 have landed and went through it.
- **The kioku deprecation debt has one more consumer and one clear owner.** Shikigami still calls
  kioku's deprecated legacy write surface (~24 `-Wdeprecations`), and plan 25's flow-memory
  capability added `Kioku.Memory.record` to that list — concentrated behind one seam rather than
  scattered, which is the good version of this outcome. Moving to `*WithContext` needs a real
  `PrincipalRef`, so **plan 54 owns clearing it**. Kioku confirmed 2026-08-18 that no removal is
  scheduled.
- **Keiro 0.14 shipped `PublishRejected`.** Plan 19 consumed the released terminal rejection and
  landed on 2026-08-22; plan 22 is no longer waiting on its delivery boundary.
- **Plan 12's upstream contracts are still absent.** Re-verified 2026-08-20: no `Baikai.Mcp.*`
  source in baikai 0.5.0.0, no MCP adapter in shikumi 0.3.0.2. Both carry upstream *plans*
  (baikai MasterPlan 6 plans 30–32; shikumi plan 30). Plan 12 M1–M2 startable; M3–M5 not.
- **Kioku IR-2 is still `proposed`** (re-verified 2026-08-20). Plans 26 and 30 no longer wait on
  it: plan 26 shipped its own index with a self-healing miss path, while plan 30 reads the exact
  session id from the workflow journal. It now touches only plan 34.
- **`keiro 0.13` publishes a Seihou blueprint, `blueprints/keiro-upgrade/`.** Future keiro upgrades
  should go through `seihou agent migrate keiro-upgrade` rather than being hand-derived.
- **Additive-only journaled-value versioning as a hard constraint** on plans 23, 27, and 34.
  Prefer the right shape now over an additive shape that costs a later cleanup — but note that
  ADR 0011 and ADR 0012 have made the *mechanics* routine: plan 33 changed the declaration record
  with no codec change, and four plans added journaled steps behind patches without incident.
- **`pgmq 0.5`'s `parseQueueName` narrowing** and **kioku's projection-schema relocation** are both
  applied and settled. ✅


## Plans that must be updated before implementation

**Discharged since 2026-08-19:** plans 17, 24, 48 (its package re-point), 50, and 51 all consumed
their updates and landed. Plan 30 was refreshed twice, changed shape rather than detail, and then
landed on 2026-08-20.

| Plan | Required update |
|---|---|
| every open plan | **Standing.** Audit citations, `docs/adr/`, what the cohort already ships, and any premise about unexecuted runtime behaviour — immediately before implementing, per [Citation rot](#citation-rot-re-measured). Sixteen open plans still carry deleted paths. |
| 19 | Re-point its `shikigami-cli` citations. Its keiro citations predate 0.13 and its M1 gate is re-verified absent. **Nothing else in it is blocked**, and its unblocked half is now the widest unblocker in the portfolio. |
| 22 | Re-point two `shikigami-cli` citations. Confirm against plan 19's delivered `SinkOutcome` rather than the sketch. It now owns **two** downstream vocabularies, not one: the sink credential surface *and* MasterPlan 10's signing credential class for plan 52. |
| 14 | **New requirement, and it enlarges the plan.** MasterPlan 10 makes plan 14 the definer of the stable typed review-request identifier that plan 51 currently accepts as an opaque caller-supplied value and plan 52's read API serves by. Say so in the plan, and keep the identifier typed and stable from the first commit. Also re-point its four deleted paths and two stale keiro citations. |
| 27 | Its Milestone 1 is ordinary Haskell consolidation — plan 39's specification cannot own the `SinkIntent` wire type, because no declared node consumes it (ADR 0001). Already corrected in the plan. Re-point four deleted paths. |
| 28 | **Now has three named consumers waiting.** Plan 20's Milestone 3 is log-only until M2 supplies the counter; plan 29 left health-path exclusion from request logging to M4 and pointed it at `Servant.Health.Paths.healthRawPaths`; M3's trace propagation still waits on plan 22's `postJSONWithHeaders`. It also carries the largest citation debt in the corpus — 11 deleted paths and 3 stale keiro citations. |
| 30 | ✅ **Landed 2026-08-20.** It mounts `keiro-ops 0.13.0.0`, adds only the agent inventory and Keiro-to-Kioku journal join Shikigami owns, and removes Kioku IR-2 from its dependency set. Plan 23 is now unblocked. |
| 34, 23, 54 | Route memory access through `Shikigami.Memory.Access`; do not name `legacyMemorySpaceId` directly. Plan 23 supplies the directory that plan 54 consumes. |
| 35 | ✅ **Landed 2026-08-22.** Declarations now own allow-lists and bounded budgets; all callers share cycle/depth/root-ledger enforcement; child ids use stable keys; and Flow has the governed capability. |
| 40 | **Entry-ready now that plan 35 landed.** Consume its final `delegates`, `delegationBudget`, lineage, and stable-key surfaces; re-point one deleted path before implementation. |
| 44, 45 | Plan 43 landed and `Shikigami.Repository` is the shared revision vocabulary; cite it rather than defining a second one. **Plan 45's entry rules are met** (43 ✅ + 25 ✅). Plan 44 still needs Kikan IR-5. |
| 48 | Rewrite as a consumer of `Baikai.Agent` / `baikai-agent` — `AgentRunRequest`, `AgentCapability`, `AgentSafety`, `AgentCommand`, `AgentCeiling`. Its package home (`shikigami-agent`) is settled. **Registration under a MasterPlan is still open.** |
| 52 | Bind to `canonicalEncode` / `commitmentDigest`; do not define a second encoder. Its dependency set is now precise: plan 22 (signing credential class), plan 14 (review-request identity), plan 44 (content plane), Kikan IR-5 and IR-6. |
| 12 | Re-verify its three upstream contracts before scheduling M3–M5; all absent as of 2026-08-20. Keep M1–M2 startable. Five deleted paths. |
| 31 | Genuinely last, and its surface grew: plans 17, 20, and 29 each added Settei keys (`worker.run_timeout_seconds`, `approval.deadline_seconds`, `agents.strict`, the scheduler catch-up policy, `health.port` per role). Six deleted paths. |
| every MasterPlan-3 child | Their Context sections name pre-split paths; MasterPlan 3 records the corrected file map — and plan 20 corrected one of its claims when it landed (there is exactly one expected strict-mode failure, `agents/broken.dhall`, not two). |


## Compatibility work that v1 does not owe

Because nothing consumes Shikigami yet, the following is **not** v1 scope, and should be struck
from its plan with a note that it returns when the first real consumer exists.

- **Byte-for-byte `SinkIntent` wire preservation** across plan 27's consolidation. Assert the shape
  you want, not the shape you had; `WireCompatSpec` stays the guard until it lands.
- **In-flight workflow survival across a deploy.** Plans 24, 25, and 26 all built the mechanism and
  none owed the proof — though plan 24 shipped one anyway, and it is the reason the other two could
  trust `patch` without re-deriving it.
- **Replay and queue codec compatibility fixtures.** Old wire data does not exist.
- **Codd-ledger import** (plan 38 M3) — cancelled 2026-08-05.
- **Database remediation on upstream schema moves.** Not owed; the forward path keeps being
  exercised anyway. Recreating the database stays the cheap option, and a database that ever *does*
  hold real data is the `cohort-migrate` skill's job, never `just migrate`.

**New — five patch guards now carry dead legacy branches.** The landings installed
`shikigami-behavior-retry-v1` (plan 17), `shikigami-emit-signal-labels-v1` (plan 24),
`shikigami-flow-memory-steps-v1` (plan 25), `shikigami-conversation-rotation-v1` (plan 26), and
`shikigami-resolve-profile-v1` (plan 50). Every `False` branch exists to serve workflow instances
that started before the patch, and **that population is empty, because Shikigami has no users**.
Plans 25 and 26 each recorded this in their own retrospectives, in near-identical words: cheap to
retire, easy to forget. Per ADR 0004's retirement rule, deleting a guard means deleting the branch
and its specification block together, and it is a gated wire change like any other. This is not
urgent and it is not free forever — each guard that survives to the first real deploy becomes
permanent. **One plan should sweep all five**, and it does not exist yet; the natural home is plan
27, which is already the consolidation plan.


## The order

Stages are entry rules, not calendar promises. The ordering rule is now explicit: **a plan that
owns a shared type, capability, schema field, or client seam lands before plans that consume it.**
A soft dependency is promoted in this sequence when taking it early would install a temporary
adapter that a later plan replaces. Parallel work is safe only across lanes with disjoint edit
surfaces; “startable” by itself is not a reason to start a downstream plan.

### Stage A — Re-baseline the cohort · ✅ complete 2026-08-18

Retired. Delivered by commit `9991032`.

### Stage B — Foundation · ✅ complete 2026-08-19

Plans 18, 21, 36, 39, 43, 49, and 55 have all landed. What was listed here and is *not* done moved
to where it actually belongs: plan 28's M2–M4 is a stage-D item because plan 20 and plan 29 are now
waiting on it, and the cleanup batch (8, 13, 16, 37 M3 / 38 M4) is unstaged — it is a session each,
takes no dependency, and blocks only plan 52's positive conformance case (via 13).

### Stage C — Core semantics · ✅ complete 2026-08-22

- **Plan 17** ✅, **plan 24** ✅, **plan 50** ✅, **plan 29** ✅.
- **Plan 19** ✅ consumed Keiro 0.14's terminal rejection and completed the delivery boundary.
- **Plan 12 M1–M2** — the `mcpServers` declaration and its validation. M3–M5 upstream-gated.
  Under the rewrite-minimizing rule, do not schedule the partial implementation unless another
  plan needs the declaration before the three upstream contracts land; otherwise it creates a
  plan that must be reopened for M3–M5.

### Stage D — Shared seams · **the current entry stage**

- **Plan 19** ✅ defines truthful `SinkOutcome`, delivery receipts, idempotency, and per-sink
  ordering. **Plan 22** is now entry-ready and owns `HttpEnv`, `TokenSource`,
  `postJSONWithHeaders`, and the signing-credential class. Plans 14, 28 M3, 32, and 52 consume
  those seams and must not grow local substitutes first.
- **Plan 35** ✅ is the declaration and durable-delegation seam: `delegates`,
  `delegationBudget`, lineage, the shared budget ledger, stable child keys, structured collection,
  and the Flow capability. **Plan 40** is now entry-ready on that final surface.
- **Plan 23** is unblocked by plan 30 ✅. Land its directory and Meibo lifecycle view before plan
  41, so plan 41 implements the real lifecycle adapter once instead of landing `local-enabled`
  and replacing it later. It also releases plan 54.
- **Plan 28 M2–M4**, after plan 22. M2 and M4 are independently startable, but waiting for M3's
  `postJSONWithHeaders` dependency lets the remaining observability work land in one pass. Plans
  20 and 29 already name the counters and health-path exclusion it must absorb.
- **Plan 30** ✅ mounted `keiro-ops`, shipped the journaled workflow-to-session join, and removed
  Kioku IR-2 from the operator path. **Plans 25, 26, 33, and 51** are also complete.

### Stage E — Consolidation, then consumers · after D

- **Plan 27**, after plans 19, 28, and preferably 35. It consolidates the final sink-intent and
  run-lifecycle shapes only after delivery, tracing, and `RunJob` lineage have stopped moving. It
  is also the natural home for the five-patch-guard sweep.
- **Plan 40**, after plan 35. It adds expertise and routing policy on top of plan 35's one
  authoritative `delegates` list; doing 40 first would force its schema, loader, fixtures, and
  validation tests to be reopened.
- **Plan 41**, after plans 40 and 23. Plan 23 is nominally a soft dependency, but taking it first
  avoids replacing the temporary local-enabled lifecycle adapter.
- **Plan 54**, strictly after plan 23, keys durable state by the final principal identity and
  retires the Kioku deprecation debt. **Plan 34 follows 54** so distillation, retention, and shared
  scope are written against the final memory-access identity seam; its Kioku IR-2-dependent part
  remains gated.
- **Plans 14 and 32**, after plan 27 as well as their declared plan-19/22 gates. Their hard plans
  allow an earlier start, but both touch sink/workflow surfaces that plan 27 consolidates; taking
  the consolidation first is the lower-rewrite order. Plan 14 also owns the stable typed
  review-request identifier.
- **Plan 42**, after plans 35, 40, and 41 and after the plan-27 lifecycle consolidation in this
  sequence. It is the first consumer that actually routes and delegates, so every policy,
  lifecycle, budget, and replay seam should be final before it lands.
- **Plan 45** is independently ready (43 ✅ + 25 ✅) and already consumes final contracts. It is
  safe filler work when the shared-seam lane is blocked, but it does not unblock the current
  bottleneck.
- **Plan 48** is independently startable on `Baikai.Agent`, but register it under a MasterPlan
  before implementation so its ownership does not need a second documentation pass.

### Stage F — Closure · last

- **Plans 44 → 46** — 44 needs Kikan IR-5; 46 after 44 and 45.
- **Plan 52** — after 51 ✅ + 22 + 14 + 44. It consumes plan 22's signing credential class, plan
  14's review-request identity, plan 44's content plane, and plan 49's canonical encoder.
- **Plan 31** — deployable stack. Genuinely last: it documents configuration surfaces that plans
  13, 22, 29, and 32 own, and three of those grew this week.


## Critical path to v1

```text
Delivery:   19 ✅ → 22 → 28 ─┐
                           ├→ 27 → 14 ─┐
Delegation: 24 ✅ + 33 ✅  │        ↘ 32│
            + 39 ✅ → 35 ✅ ─┘          │
                                        ├→ 52 → 31
Attestation: 49 ✅ → 50 ✅ → 51 ✅ ─────┤
             43 ✅ → 44 ────────────────┘
             43 ✅ → 45 ─┐
                    44 ──┴→ 46

Router:     35 ✅ → 40 ─┐
            30 ✅ → 23 ┴→ 41 → 42
Memory:             23 → 54 → 34
```

**The two poles from the last revision are both discharged.** The feature pole has now also lost
plan 35, and the delivery bottleneck has advanced past plan 19. The next shared seams are three
independent lanes: plan 23 for lifecycle/principals, plan 22 for HTTP/auth/signing, and plan 40 for
router policy. Plan 22 still gates the attestation pole as well as egress because it owns the
signing credential class and plan 14 behind it owns the review-request identity plan 51 left open.

Plans 19 and 35 have discharged two of the three seam-definer slots. The immediate queue is now:

1. **Plan 23.** Plan 30 has released it; taking it now prevents plan 41 from shipping a temporary
   lifecycle adapter and gives plan 54 its final directory/principal seam.
2. **Plan 22.** Plan 19 has released it; this opens 28, 14, 32, and 52 without any of them inventing HTTP,
   authentication, header, or signing vocabulary.
3. **Plan 40**, now that plan 35 has landed, and then **plan 41** after plan 23. This is the no-rewrite route into
   the router initiative.
4. **Plan 28 M2–M4**, after plan 22, as one pass rather than two partial implementations.
5. **Plan 27**, after plan 28, before sink/workflow consumers 14 and 32.
6. **Plan 54**, after plan 23, before plan 34. It closes the temporary memory principal seam.

Plan 45 is the safest independent filler if one of those lanes is blocked. Plans 12 M1–M2 and 34's
ungated milestones are technically startable, but postponing them until their upstream contracts
are available avoids deliberately reopening the same plan.

One node still waits on another repository: plan 44 (Kikan IR-5). It does not justify a local
placeholder; the other lanes can advance while it waits.

If a v1 cut smaller than "all 23 remaining plans" becomes attractive, the natural line has moved:
**after stage D plus plans 14 and 27** yields a service with a real provider, honest sinks, correct
delivery semantics, checked durable topology and versioning, fail-closed profile resolution, run
evidence, authenticated egress, approvals, an operator CLI, health, and observability. Stage E's
remainder adds identity and memory features; stage F adds two whole initiatives (router agents,
practice reviews) plus packaging.


## Upstream gates, current status

| Gate | Blocks | Status 2026-08-22 |
|---|---|---|
| Kioku IR-1 | plan 47 | ✅ Closed. |
| kioku 0.3.0.0 | plan 53 M0 | ✅ Closed; superseded by kioku 0.4.1.0. |
| Baikai IR-3 | plans 51, 52 | ✅ **Closed and consumed.** Plan 51 landed on `Baikai.Evidence`. |
| keiro 0.12 | plan 17 | ✅ **Moot and consumed.** keiro 0.13 lifted the cap; plan 17 landed. |
| kioku admitting `baikai ^>=0.5` | plans 48, 51, 52 | ✅ Closed by `kioku 0.4.1.0`. |
| Shibuya IR-1 | plan 29's worker probe | ✅ **Discharged in substance.** `shibuya-core 0.9.0.0` exports `getAppMetrics` / `ProcessorMetrics` / `ProcessorState` — a non-blocking read distinguishing idle, processing, failed-with-reason-and-time, and stopped, attributed by processor id. Plan 29 shipped on it and reports *last activity* rather than *last time we remembered to beat*. The IR is still `proposed` upstream and its second ask is unmet; it gates nothing here. |
| Keiro IR-3 / keiro plan 165 | plan 19 M1's blocked half | ✅ Closed by Keiro 0.14.0.0 and consumed when plan 19 landed. |
| Kioku IR-2 | plan 34 | ❌ Still `proposed`. Plans 26 and 30 stopped waiting on it. |
| Baikai IR-2 | plan 12 M3–M5 | ❌ No `Baikai.Mcp.*` source in baikai 0.5.0.0. Planned upstream. |
| Shikumi IR-1 | plan 12 | ❌ No MCP adapter in shikumi 0.3.0.2. Planned upstream. |
| Kikan-En IR-3 | plan 12 | ❌ Proposed; not re-verified this revision. |
| Kikan IR-5 | plans 44, 46, 52 | ❌ Proposed; not re-verified this revision. |
| Kikan IR-6 | plan 52 | ❌ Proposed. Scope shrinks further: it ratifies the envelope, and plan 49 has now frozen the encoder locally as a wire format (ADR 0006). |
| Shikigami IR-9 | plans 23, 34, 54 | ⏳ Planned as plan 54, after plan 23. Until it lands, `Shikigami.Memory.Access` mints self-asserted refs and the kioku deprecation debt stands. |
| **Shikigami IR-8 — outbound** | **`mori://shinzui/mori` plan 150, M4b** | ❌ **Shikigami is now somebody else's gate.** Mori's Agent automation action is written, its stage 4a is unblocked against a stub, and its stage 4b explicitly waits on Shikigami implementing IR-8. There is no plan here. See [Coverage gaps](#coverage-gaps). |

The pattern to keep using where a contract is pending: define a reader or source record of function
fields, satisfy it with a stub plus fixtures in tests, and let the live client replace the stub.
Plan 44 does this for the content plane; plan 51 did it for call evidence and has now exercised the
seam against the released terminal trace source rather than fixtures alone.


## Coverage gaps

**Four inbound requests have no plan, and one of them blocks another repository.** IR-2 (authorized
cross-cluster diagnostic tools), IR-5 (governed agent evolution), IR-6 (A2A cross-runtime
interoperability), and — newly counted here — **IR-8 (expose addressed agent runs over the public
HTTP API)** appear in no MasterPlan or ExecPlan.

IR-8 is the urgent one and this document has never named it. It was filed 2026-08-07, after the
2026-08-05 audit this section was carried forward from, so it fell through the gap between reviews.
It has a waiting external consumer:
`mori://shinzui/mori/plans/150-add-an-agent-automation-action-that-invokes-shikigami-agents-from-reactions`
has re-architected itself around an HTTP call to Shikigami, split its Milestone 4 so that stage 4a
proves the reaction against a stub, and recorded stage 4b as externally gated on Shikigami. **A
sibling repository has restructured a plan around a request we have not scheduled.** That deserves
either a plan or an explicit, communicated deferral — not silence.

IR-5 remains the consequential one on the merits (declaration revision, artifact identity, run
pinning, baseline-to-candidate relation, rollout policy), and plan 33's landing sharpens rather
than closes it: plan 33 covers `identity`, `memory`, and `enabled`, and plan 49's `AgentVersionRef`
/ `AgentArtifactSet` are shaped so a governed-evolution plan extends them additively. IR-6's
upstream counterpart `mori://shinzui/kikan/okf/improvement-requests/concepts/IR-4` is `accepted`.

**Five plans belong to no MasterPlan.** Plans 7, 9, 10, 11 (complete) and plan 48 (open). Register
48 now that its vocabulary (`Baikai.Agent`) and its package home (`shikigami-agent`) are both
settled.

**Seventeen registry rows are stale.** See [Registry rot](#registry-rot-seventeen-stale-rows). This is
the cheapest open item in the portfolio and the one most likely to mislead the next reader.

**Five patch guards have unreachable legacy branches** and no owning plan. See
[Compatibility work that v1 does not owe](#compatibility-work-that-v1-does-not-owe).

**A capability was once deleted because its purpose was undocumented** — `shikigami-cli` served
consumers not running the Kikan platform, and that requirement existed in no plan or architecture
document until plan 55 wrote it into `packages.md`. The question it raised is still open: which
*other* capabilities are held only by intent? The four unplanned inbound requests above are the
known unknowns.


## Revision note (2026-08-20)

Twelve plans landed in two days: 17, 18, 20, 24, 25, 26, 29, 33, 43, 49, 50, and 51. The entry
stage moves from C to D, and both of the previous revision's critical-path poles are discharged at
their first three nodes. What replaced them is a single bottleneck — **plan 19 → plan 22** — which
now gates the attestation pole as well as egress, because plan 22 owns the signing credential class
and plan 14 behind it owns the review-request identity plan 51 deliberately left open. Plans 30,
40, 35, and 45 are entry-ready in parallel.

Two findings are new. [Registry rot](#registry-rot-seventeen-stale-rows) records that sixteen
MasterPlan rows call a complete plan "Not Started", which is why the status-precedence rule at the
top of this document is amended: the plan file wins, not the registry. And the
audit-before-implement instruction from 2026-08-19 is widened from citations to four things —
citations, the ADR corpus (3 records to 20 in two days), what the cohort already ships (three plans
found a released package doing work they had scheduled), and any premise about runtime behaviour
the plan has not executed. That last one is where the real cost was: plan 26's research was sound
and three of its unexecuted inferences were wrong.

Smaller corrections. Plan 37 M3's description was stale — the `CODD_*` contract is gone and only
the Settei unification remains, still blocked by the package cycle. Plan 8's build-and-test box is
satisfied incidentally; only the live Danwa observation remains. Shibuya IR-1 is discharged in
substance and no longer gates plan 29's worker probe. Kioku IR-2 no longer touches plan 26.
`keiro-pgmq`, `keiro-ops`, and `shibuya-kafka-adapter` joined the cohort table. And **IR-8 is
counted as a coverage gap for the first time**, which makes four unplanned inbound requests rather
than three — the one that matters most, because mori has already restructured a plan around it.


## Revision note (2026-08-21)

Plan 30 landed after the previous review. The portfolio is now 30 complete and 25 open. Its
operator surface mounts `keiro-ops`, its Shikigami-owned run view joins Keiro to the exact Kioku
session id stored in the workflow journal, and Kioku IR-2 is no longer an operator dependency.
That releases plan 23. It also makes the stale MasterPlan count seventeen, adds ADR 0021, and
corrects the test-suite advice: stop any manually started Shikigami processes before treating a
hang as inherent parallel-suite deadlock.

The larger correction is ordering. The previous revision called plan 40 entry-ready, but plan
40's own Progress and Context sections hard-depend on plan 35's `delegates` and
`delegationBudget`. This revision makes rewrite minimization the explicit sequencing rule and
promotes two other soft preferences for the same reason: plan 23 precedes plan 41 so the catalog
ships with the Meibo lifecycle adapter once, and plan 27 precedes plans 14 and 32 so those consumers
land on the consolidated sink/workflow surface. The immediate queue is plan 19, plan 35, plan 23,
then plan 22 and plan 40 as their respective prerequisites land.


## Revision note (2026-08-22)

Plans 19 and 35 landed. The portfolio is now 32 complete and 23 open. Keiro 0.14 closed plan 19's
terminal-rejection gate, so plan 22 is entry-ready. Plan 35 delivered the declaration, stable child
identity, root-wide budget ledger, structured child outcomes, and Flow capability, so plan 40 is
entry-ready and plan 27 can consume the final delegation shape.

The immediate queue is plan 23, plan 22, and plan 40. Plan 23 still comes first under the
rewrite-minimizing rule because it gives plans 41 and 54 their final lifecycle/principal seam;
plans 22 and 40 are independent lanes now that their prerequisites have landed.
