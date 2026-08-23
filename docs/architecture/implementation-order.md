# Shikigami implementation order

Reviewed **2026-08-23** after plans 22, 28, and 27 landed, superseding the earlier 2026-08-23
review. Goal of this revision: move the portfolio past the completed HTTP, observability, and
lifecycle-consolidation lane; recognize MasterPlan 8 as the active initiative and MasterPlan 9 as
its direct successor; and keep the separate production-completion lane ordered so shared records
and schemas move once.

Four more plans landed after the earlier review. Plan 22 established the authenticated, bounded
HTTP and credential seam. Plan 28 completed runtime metrics, tracing, request logging, and graceful
telemetry shutdown. Plan 27 then consolidated the final sink-intent and agent-run lifecycle shapes.
Plan 40 added the canonical expertise and routing-policy declaration. The portfolio remains 59
plans, with 41 complete and 18 open. MasterPlan 8 is now in progress at plan 41; plan 42 remains
behind it in that initiative's internal order.

**Shikigami has no users.** No database's history needs preserving, no workflow instance is in
flight across a deploy, and no wire payload has an external consumer. Every "preserve this
byte-for-byte", "import the old ledger", "survive the upgrade" obligation written into these plans
is therefore *not* v1 work. This now has a second, sharper consequence: the recent landings
installed **six patch guards whose legacy branches are unreachable code** — see
[Compatibility work that v1 does not owe](#compatibility-work-that-v1-does-not-owe).

**The cohort is current and has no exclusions.** Re-verified 2026-08-23 against Hackage for every
row and the upstream tags for the changed Keiki, Keiro, Kioku, Shikumi, and Baikai families:
nothing released past what `cabal.project` pins. The table in this document had fallen behind the
repository contract: the selected family is Keiki 0.9.1, Keiro 0.14, and
Kioku 0.5, and `shikumi-tools` 0.3.0.2 joined the cohort for the capability-overlay runtime. See
[The cohort, as pinned](#the-cohort-as-pinned).

**The MasterPlan registries are no longer the authority on status.** Twenty registry rows call a
complete plan `Not Started`; plans 22 and 28 are the newest stale rows, while MasterPlans 5 and 11
correctly record plan 27 and plans 56–59. See
[Registry rot](#registry-rot-twenty-stale-rows). The precedence rule remains: **the plan file's own
Progress and Outcomes sections win on status**, this document is the cross-plan reading of them,
and a registry row is evidence only when it is newer than both. Where this
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

59 ExecPlans across 11 MasterPlans. **41 are complete**; 18 have open work.

Complete: 1, 2, 3, 4, 5, 6, 7, 9, 10, 11, 15, **17**, **18**, **19**, **20**, 21, **22**, **23**, **24**, **25**,
**26**, **27**, **28**, **29**, **30**, **33**, **35**, 36, 39, **40**, **43**, 47, **49**, **50**, **51**, 53, 55,
**56**, **57**, **58**, **59**. Plans 22, 28, 27, and 40 are the latest landings. See
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

Open and substantial (13 plans): 12, 14, 31, 32, 34, 41, 42, 44, 45, 46, 48, 52, 54.


## What landed, and what it changes for everyone else

The recent landings are grouped below. Each entry is what shipped, then what it costs or saves
someone else.

### HTTP, observability, and lifecycle consolidation — plans 22, 28, 27

**Plan 22** delivered one authenticated and bounded outbound HTTP boundary. Kawa and Kizashi share
a process-lifetime TLS-capable manager; Danwa uses a separately bounded Servant manager; opaque
`TokenSource` values stay outside serialized configuration and journals; and
`postJSONWithHeaders` is the one extension point for trace and Kanmon headers. ADR 0026 records the
security and process-lifecycle boundary.

**Plan 28** completed the operational surface on that final HTTP seam. Every long-running process
has structured logs, real OpenTelemetry tracing and metrics, graceful provider flush/shutdown, and
bounded request logging. Sink intent producers persist trace context, and publishers continue it
through `sink.publish` and the authenticated HTTP request. Its one unchecked one-shot-CLI logging
item is an explicit scope decision, not unfinished runtime work.

**Plan 27** then moved both sink-intent implementations into the one hand-owned
`Shikigami.Sink.Intent` vertical, made the one-off agent CLI drive the durable workflow, and added
executable Keiki conformance for the modelled at-risk branches. It preserved the settled plan-19
delivery semantics and plan-28 trace context while changing no workflow label or patch set.

*For everyone else:* plans 32 and 14 can now consume the final HTTP, sink, and agent-run surfaces.
MasterPlan 8's plan 42 can extend the final `AgentRunDeps` and workflow body rather than reconciling
with telemetry or lifecycle code motion afterward. The six legacy patch guards were **not** retired
by plan 27; that portfolio-added cleanup remains unscheduled and is tracked below.

### Router declaration — plan 40

**Plan 40** completed MasterPlan 8's declaration child. The canonical Dhall and Haskell declaration
now carries expertise plus a bounded optional router policy, router validation keeps `delegates` as
the only candidate authority, and proof manifests plus CLI diagnostics exercise both valid and
invalid declarations. Because there are still no deployed journals, ADR 0027 establishes one
complete v1 JSON declaration instead of retaining the pre-release missing-key codec shim.

*For everyone else:* plan 41 consumes these final types and is already in progress; plan 42 remains
behind the completed catalog. Plans 32 and 14 should not overlap the active catalog/workflow lane
when work is single-threaded.

### Lifecycle and capability overlays — plans 23, 56, 57, 58, 59

**Plan 23** delivered `Shikigami.Directory`: one cached, fail-closed principal/lifecycle view with
distinct disabled and unavailable states. Load reports and trigger/drain refusals are durable;
schedule, Kafka, PGMQ, and sink boundaries consult the same lifecycle policy; new Kioku sessions
carry the resolved principal id; and `shikigami agents list` / `agents sync` expose and reconcile
the declaration-to-principal join. ADR 0024 records the last-valid-snapshot rule. The implementation
deliberately stayed file-source-first: it did not add a Meibo package or live HTTP client.

**Plans 56–59** completed MasterPlan 11. An agent now requests additive model-facing tools through
`capabilityOverlays`; an operator catalog resolves that request to immutable descriptors; provider
leases acquire deterministically and release in reverse order; and Skills share one bounded
`shikumi-tools` model/tool loop. Fresh durable runs journal the complete descriptor snapshot under
patch `shikigami-capability-overlays-v1`, then reacquire that exact revision per behavior attempt.
The portable one-off path proves the same seam with a confined, observation-only
`workspace.read` provider. ADR 0025 records the authority, replay, and lease boundaries.

*For everyone else:* plan 41 can now implement its final `DirectorySnapshot` lifecycle adapter
once; `local-enabled` remains only as the honest name for explicit directory-disabled compatibility
mode, not as a temporary configured source. Plan 54 has cleared only its first gate:
plan 23 exists, but the live Meibo client is still unreleased and its dependency closure also
includes unreleased `mori://shinzui/shomei/packages/shomei-servant`. Plan 12 must be rewritten as an
MCP provider for the overlay registry — its proposed `mcpServers` declaration, generic registry,
bracket, and model/tool loop are superseded. Plan 48 consumes the same seams and now has its
read-only slice, but its remaining writable harness is still blocked by its own prerequisites.

### Correctness and delivery — plans 17, 18, 20

**Plan 17** put the retry boundary before the journal: a transient behavior error or timeout
escapes before Keiro can append a step result, while a permanent one is bounded, redacted, and
journaled once. Both durable families run under patch `shikigami-behavior-retry-v1`. The run-job
consumer moved onto **`keiro-pgmq`**'s typed `Job RunJob` surface (initially 0.13.0.0; selected
now at 0.14.0.0), with startup main-queue/DLQ reconciliation and a linked visibility heartbeat
(10s renew against a 30s lease).
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
disappearing from logs. Plan 28 has now delivered the previously missing counter.

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
`docs/architecture/shikigami-domain-inventory.md` is the intended reference for what the
specification does and does not cover, but its 2026-08-19 census of "no aggregate, no read model,
no projection" is still one aggregate and two projections out of date. It now lists the overlay
workflow label, but that incidental edit did not refresh the census.

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
dead-letter operations. That exact journaled join discharges the plan's possible
`mori://shinzui/kioku/okf/improvement-requests/concepts/IR-2` dependency. The mount also raised the
repository's development floor to PostgreSQL 18 because Keiro migrations refuse other major
versions (ADR 0021).

*For everyone else:* plan 23 consumed this seam and extended the existing `agents` command rather
than introducing a second inventory. Operator verbs over Keiro state stay mounted from
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

The ADR corpus went from 3 records to **25**. Reading `docs/adr/` is now part of
pre-implementation audit, not optional context — plan 26 caught its gate contradiction by scanning
the corpus first, which was the cheaper of the two places to find it.


## The cohort, as pinned

Re-verified 2026-08-23 against `cabal.project` and Hackage for every row, plus the upstream tags for
the changed Keiki, Keiro, Kioku, Shikumi, and Baikai families; no cohort member has released past
its pin. `docs/dependency-cohort.md` is the contract; this is the summary.

| Package | Pinned | Latest released | Current? |
|---|---|---|---|
| `keiki`, `keiki-codec-json` | 0.9.1.0 | 0.9.1.0 | ✅ |
| `keiro`, `-core`, `-migrations`, `-dsl` | 0.14.0.0 | 0.14.0.0 | ✅ |
| `keiro-pgmq` | 0.14.0.0 | 0.14.0.0 | ✅ **plan 17** |
| `keiro-ops` | 0.14.0.0 | 0.14.0.0 | ✅ **plan 30** |
| `kioku-*` | 0.5.0.0 | 0.5.0.0 | ✅ |
| `shikumi`, `shikumi-tools` | 0.3.0.2 | 0.3.0.2 | ✅ **`shikumi-tools` added by plan 57** |
| `baikai`, `baikai-claude` | 0.5.0.0 | 0.5.0.0 | ✅ |
| `pgmq-*` | 0.5.0.0 | 0.5.0.0 | ✅ |
| `shibuya-core` | 0.9.0.0 | 0.9.0.0 | ✅ |
| `shibuya-kafka-adapter` | 0.9.0.0 | 0.9.0.0 | ✅ **new — plan 18** |
| `shibuya-pgmq-adapter` | 0.14.0.0 | 0.14.0.0 | ✅ |
| `kiroku-store` / `-migrations` | 0.8.0.0 / 0.4.0.0 | same | ✅ |
| `shibuya-kiroku-adapter` | 0.5.1.1 | 0.5.1.1 | ✅ |
| `pg-migrate`, `settei`, `servant-health` | 1.1.0.0 / 0.2.0.0 / 0.1.0.0 | unchanged | ✅ |

Four of these arrived *because a plan went looking*, which is the pattern worth keeping: plan 17
found `keiro-pgmq` rather than hand-rolling a typed consumer, plan 18 found `shibuya-kafka-adapter`
rather than keeping a Kafka client in application code, and plan 30's refresh found `keiro-ops`
already shipping the command tree it had budgeted three milestones to build. Plan 57 found
`shikumi-tools` already shipping the registry and Baikai already shipping the bounded tool loop,
so it implemented lifecycle composition instead of another tool protocol. **Check whether the
cohort already ships it before implementing a milestone.**


## Registry rot: twenty stale rows

Reconciled 2026-08-23 across `docs/masterplans/`. **Twenty rows name a plan that is complete but
still say `Not Started`**: 17, 18, 20, 21, 22, 23, 24, 25, 26, 28, 29, 30, 33, 39, 43, 49, 50,
51, 53, and 55. MasterPlan 5 correctly marks plan 27 complete, MasterPlan 8 records plan 40 in
progress, and MasterPlan 11 correctly marks all four of its children complete.

This matters more than a bookkeeping nit, because this document has told readers since it was
written that *"where this document and a MasterPlan registry disagree about a plan's status, the
registry wins."* Following that rule today would re-schedule twenty finished plans. The rule is
amended at the top of this document: the plan file's own Progress and Outcomes sections are the
authority on status.

The cause is mechanical and forgivable — a plan's implementer updates the plan file, and updating
the parent registry is a second edit in a different directory that nothing enforces. The fix is
equally mechanical: twenty row edits, plus the corresponding MasterPlan checklist boxes.
**That is the cheapest outstanding piece of work in the portfolio, and it should be done before
the next planning session rather than during it.** It is not on any critical path and is not
scheduled below; it is one sitting.


## Citation rot: re-measured

Re-measured 2026-08-23 over the 19 open plans. **Ten open plans still carry unfixed pointers** to
`shikigami-cli`, `shikigami-core/src/Shikigami/Worker.hs`, or the old Cabal package: 8, 12, 13,
14, 16, 31, 32, 34, 37, and 48. Plan 14 additionally carries line-numbered `keiro/src/...`
citations predating Keiro 0.14.

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
2. **`docs/adr/`**, which now holds 25 records and grew rapidly. Plan 26's central
   decision was contradicted by an ADR that had landed the previous day.
3. **What the cohort already ships.** Four plans found a released package doing work
   they had scheduled.
4. **The plan's premises about runtime behaviour it has not run.** This is the expensive one. Plan
   26's research was sound and three of its inferences about behaviour it had not executed were
   wrong; each was caught by a test the plan itself had specified. Plan 25 put it best: when a plan
   asserts what a dependency does, the assertion is a hypothesis until something executes it.


## Drift each plan must still absorb

- **Kioku's mandatory memory spaces and principals, now pinned at 0.5.** Every session/memory command record
  carries `memorySpaceId` and `actorPrincipal`. Shikigami answers both in
  `shikigami-core/src/Shikigami/Memory/Access.hs` with `legacyMemorySpaceId` and a
  `KnownPrincipal` over a self-asserted `shikigami.agent.<name>` ref. **Plans 34 and 54 should treat
  that module as the seam they change.** Plan 23 now supplies the directory and session attribution
  that plan 54 consumes without re-keying memory itself.
- **The kioku deprecation debt has one more consumer and one clear owner.** Shikigami still calls
  kioku's deprecated legacy write surface (~24 `-Wdeprecations`), and plan 25's flow-memory
  capability added `Kioku.Memory.record` to that list — concentrated behind one seam rather than
  scattered, which is the good version of this outcome. Moving to `*WithContext` needs a real
  `PrincipalRef`, so **plan 54 owns clearing it**. Kioku confirmed 2026-08-18 that no removal is
  scheduled.
- **Keiro 0.14 shipped `PublishRejected`.** Plan 19 consumed the released terminal rejection and
  landed on 2026-08-22; plan 22 is no longer waiting on its delivery boundary.
- **Plan 12's upstream contracts are still absent.** Re-verified 2026-08-23: no `Baikai.Mcp.*`
  source in Baikai 0.5.0.0, no MCP adapter in Shikumi 0.3.0.2, and Kikan-En's per-action request is
  still proposed. Plans 56 and 57 superseded plan 12's old M1–M2 shape: the declaration is now a
  provider-neutral overlay request and the registry/bracket/loop already exist. **Do not implement
  the old partial milestones; rewrite plan 12 as an MCP overlay provider after its three upstream
  contracts land.**
- **`mori://shinzui/kioku/okf/improvement-requests/concepts/IR-2` is still `proposed`**
  (re-verified 2026-08-23). Plans 26 and 30 no longer wait on
  it: plan 26 shipped its own index with a self-healing miss path, while plan 30 reads the exact
  session id from the workflow journal. It now touches only plan 34.
- **Keiro publishes a Seihou blueprint, `blueprints/keiro-upgrade/`.** Future Keiro upgrades
  should go through `seihou agent migrate keiro-upgrade` rather than being hand-derived.
- **Additive-only journaled-value versioning as a hard constraint** on plan 34 and every future
  durable consumer, including MasterPlans 8 and 9.
  Prefer the right shape now over an additive shape that costs a later cleanup — but note that
  ADR 0011 and ADR 0012 have made the *mechanics* routine: plan 33 changed the declaration record
  with no codec change, and six plans added journaled steps behind patches without incident.
- **`pgmq 0.5`'s `parseQueueName` narrowing** and **kioku's projection-schema relocation** are both
  applied and settled. ✅


## Plans that must be updated before implementation

**Discharged since 2026-08-19:** plans 17, 24, 50, and 51 consumed their updates and landed. Plan
30 was refreshed twice, changed shape rather than detail, and landed on 2026-08-20. Plan 48
consumed its package re-point and overlay reconciliation, but the broader harness remains open.

| Plan | Required update |
|---|---|
| every open plan | **Standing.** Audit citations, `docs/adr/`, what the cohort already ships, and any premise about unexecuted runtime behaviour — immediately before implementing, per [Citation rot](#citation-rot-re-measured). Ten open plans still carry deleted paths. |
| 22 | ✅ **Landed 2026-08-23.** It owns the opaque `TokenSource`, bounded `HttpEnv`, `SinkHttp`, header-capable POST seam, and MasterPlan-10 signing credential class consumed downstream. |
| 14 | **New requirement, and it enlarges the plan.** MasterPlan 10 makes plan 14 the definer of the stable typed review-request identifier that plan 51 currently accepts as an opaque caller-supplied value and plan 52's read API serves by. Say so in the plan, and keep the identifier typed and stable from the first commit. Also re-point its four deleted paths and two stale keiro citations. |
| 27 | ✅ **Landed 2026-08-23.** One hand-owned sink-intent module and one durable agent-run lifecycle are now final. The separately proposed six-guard retirement sweep did not land and needs an explicit owner before the first real deploy. |
| 28 | ✅ **Landed 2026-08-23.** Runtime logs, metrics, trace propagation, request logging, and graceful telemetry lifecycle now consume plan 22's final HTTP seam. |
| 23 | ✅ **Landed 2026-08-22.** It supplies the cached directory, durable lifecycle refusals, session attribution, and operator reconciliation. It intentionally did not add the live Meibo client. |
| 30 | ✅ **Landed 2026-08-20.** It mounts `keiro-ops 0.14.0.0`, adds only the agent inventory and Keiro-to-Kioku journal join Shikigami owns, and removes `mori://shinzui/kioku/okf/improvement-requests/concepts/IR-2` from its dependency set. |
| 34, 54 | Route memory access through `Shikigami.Memory.Access`; do not name `legacyMemorySpaceId` directly. Plan 23 supplies the directory that plan 54 consumes. |
| 54 | Refresh Milestone 0 before implementation. Plan 23 cleared the local-code gate, but Meibo still has no release or tag, and its `meibo-api` 0.1.0.0 depends on the also-unreleased `mori://shinzui/shomei/packages/shomei-servant`. Select remote-reachable commits and prove that whole source-package closure against the pinned cohort before treating M1 as entry-ready. |
| 35 | ✅ **Landed 2026-08-22.** Declarations now own allow-lists and bounded budgets; all callers share cycle/depth/root-ledger enforcement; child ids use stable keys; and Flow has the governed capability. |
| 40 | ✅ **Landed 2026-08-23.** Expertise and bounded routing policy are now part of the canonical declaration; live manifests keep Dhall defaults and the repository pins one complete v1 JSON declaration under ADR 0027. |
| 41, 42 | Plan 41 is **in progress**: its immutable directory-snapshot slice has landed and catalog construction remains. Plan 42 follows the completed catalog on the final delegation and workflow-versioning contracts. |
| 44, 45 | Plan 43 landed and `Shikigami.Repository` is the shared revision vocabulary; cite it rather than defining a second one. **Plan 45's entry rules are met** (43 ✅ + 25 ✅). Plan 44 still needs `mori://shinzui/kikan/okf/improvement-requests/concepts/IR-5`. |
| 48 | Its 2026-08-23 revision now consumes plans 56, 57, and 59 and counts the read-only slice complete. Do not call it independently startable: plan 31 and the other prerequisites in its Progress section remain open. Its package home (`shikigami-agent`) is settled; registration under a MasterPlan is still open. |
| 52 | Bind to `canonicalEncode` / `commitmentDigest`; do not define a second encoder. Its dependency set is now precise: plan 22 (signing credential class), plan 14 (review-request identity), plan 44 (content plane), `mori://shinzui/kikan/okf/improvement-requests/concepts/IR-5`, and `mori://shinzui/kikan/okf/improvement-requests/concepts/IR-6`. |
| 12 | Rewrite comprehensively around the plan-56/57 overlay seam before implementation. Retire the proposed `mcpServers` field and the already-delivered generic registry/bracket/loop milestones; retain only MCP transport, credential resolution, per-action authorization, adapter naming, and conformance. All three upstream contracts remain absent as of 2026-08-23. Five deleted paths. |
| 31 | Genuinely last, and its surface grew: plans 17, 20, 23, 29, 55, and 56–59 added Settei keys, a seventh package, new commands, and capability configuration that its stack/package documentation must absorb. Six deleted paths. |
| 56–59 | ✅ **Landed 2026-08-22/23.** Their MasterPlan registry is current. Downstream plans must import the final overlay/catalog/provider types rather than recreate an MCP- or workspace-specific registry. |
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

**Six patch guards still carry dead legacy branches.** The landings installed
`shikigami-behavior-retry-v1` (plan 17), `shikigami-emit-signal-labels-v1` (plan 24),
`shikigami-flow-memory-steps-v1` (plan 25), `shikigami-conversation-rotation-v1` (plan 26), and
`shikigami-resolve-profile-v1` (plan 50), followed by `shikigami-capability-overlays-v1` (plan 58).
Every `False` branch exists to serve workflow instances
that started before the patch, and **that population is empty, because Shikigami has no users**.
Plans 25 and 26 each recorded this in their own retrospectives, in near-identical words: cheap to
retire, easy to forget. Per ADR 0004's retirement rule, deleting a guard means deleting the branch
and its specification block together, and it is a gated wire change like any other. Plan 27 landed
without the portfolio-added sweep, and plan 42 intends to add `shikigami-routing-steps-v1`, so the
count becomes seven when MasterPlan 8 completes. This is not urgent and it is not free forever —
each guard that survives to the first real deploy becomes permanent. Give the retirement sweep an
explicit plan after the durable topology for MasterPlans 8 and 9 settles, but before the first real
deployment; do not silently append it to another plan during implementation.


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
waiting on it, and the cleanup batch (8, 13, 16, 37 M3 / 38 M4) is unstaged — it is a session each
and takes no dependency. Plan 13's live smoke blocks plan 52's positive conformance case and is also
an explicit plan-48 prerequisite.

### Stage C — Core semantics · ✅ complete 2026-08-23

- **Plan 17** ✅, **plan 24** ✅, **plan 50** ✅, **plan 29** ✅.
- **Plan 19** ✅ consumed Keiro 0.14's terminal rejection and completed the delivery boundary.
- **Plans 56–59** ✅ superseded plan 12's generic M1–M2 work with the provider-neutral overlay
  seam. Plan 12 is now wholly upstream-gated and must be rewritten before implementation; do not
  add the retired `mcpServers` declaration.

### Stage D — Shared seams · delivery lane complete; router lane active

- **Plan 19** ✅ defines truthful `SinkOutcome`, delivery receipts, idempotency, and per-sink
  ordering. **Plan 22** ✅ now owns `HttpEnv`, `TokenSource`,
  `postJSONWithHeaders`, and the signing-credential class. Plans 14, 32, and 52 consume those seams
  and must not grow local substitutes first; plan 28 already consumed them.
- **Plan 35** ✅ is the declaration and durable-delegation seam: `delegates`,
  `delegationBudget`, lineage, the shared budget ledger, stable child keys, structured collection,
  and the Flow capability. **Plan 40** ✅ added the declaration policy on that final surface;
  **plan 41 is in progress**, and plan 42 follows it inside MasterPlan 8.
- **Plan 23** ✅ landed its directory and lifecycle view. It releases plan 41 completely and clears
  plan 54's local-code gate, but not plan 54's live Meibo/Shomei dependency gate.
- **Plan 28** ✅ consumed plan 22's header-capable client and completed metrics, trace propagation,
  request logging, and graceful provider lifecycle in one pass.
- **Plan 30** ✅ mounted `keiro-ops`, shipped the journaled workflow-to-session join, and removed
  `mori://shinzui/kioku/okf/improvement-requests/concepts/IR-2` from the operator path. **Plans 25,
  26, 33, and 51** are also complete.
- **Plans 56–59** ✅ own the one overlay declaration/catalog/provider/lease/tool-loop seam. Plan 12
  and plan 48 are consumers, not reasons to introduce another registry.

### Stage E — Active initiatives and released consumers · **current**

- **Plan 27** ✅ consolidated the final sink-intent and run-lifecycle shapes after delivery and
  tracing stopped moving. It did not absorb the later-proposed patch-retirement sweep.
- **MasterPlan 8 is active: plan 40 ✅ → plan 41 (in progress) → plan 42.** Plan 40 defines the
  declaration fields; plan 41's immutable `DirectorySnapshot` slice has landed and its catalog
  remains; plan 42 adds replay-safe routing and governed delegation on the final plan-27 lifecycle.
  Finish this internal sequence before opening another schema or agent-workflow consumer.
- **Plan 54**, after a refreshed Milestone 0 proves remote-reachable Meibo and Shomei source pins
  against the cohort. Plan 23 supplies the directory, but it intentionally did not add the live
  client. Once that dependency spike passes, plan 54 keys durable state by the final principal and
  retires the Kioku deprecation debt. **Plan 34 follows 54** so distillation, retention, and shared
  scope are written against the final memory-access identity seam; its
  `mori://shinzui/kioku/okf/improvement-requests/concepts/IR-2` slice remains gated.
- **Plans 32 then 14** are released by plans 22 and 27 but should follow MasterPlan 8 when work is
  single-threaded. Plan 32 overlaps plan 40 on `schema/Agent.dhall` and finalizes the sink-kind and
  `SinkHttp` records; plan 14 then constructs approval policy and notification tests against that
  final sink surface. Plan 14 also owns the stable typed review-request identifier.
- **Plan 45** is independently ready (43 ✅ + 25 ✅) and already consumes final contracts. It is
  the safest parallel step toward MasterPlan 9 while MasterPlan 8 is active.
- **Plan 48** is not independently startable. Plans 56, 57, and 59 delivered its generic overlay
  machinery and read-only slice, but its own Progress section still hard-gates M1 on plan 31 and
  other open prerequisites. Register it under a MasterPlan before the remaining writable work so
  its ownership does not need a second documentation pass.

### Stage F — MasterPlan 9 and closure

- **MasterPlan 9 is the direct successor to MasterPlan 8.** Plan 43 ✅ owns the shared contracts;
  plan 45 is locally ready; plan 44's deterministic reader seam and stub fixtures are startable,
  while its live adapter still needs
  `mori://shinzui/kikan/okf/improvement-requests/concepts/IR-5`. Plan 46 closes the initiative after
  MasterPlan 8, plans 44 and 45, and the live Kikan gate.
- **Plan 52** — after 51 ✅ + 22 ✅ + 14 + 44. It consumes plan 22's signing credential class, plan
  14's review-request identity, plan 44's content plane, and plan 49's canonical encoder.
- **Plan 31** — deployable stack. Genuinely last: it documents configuration surfaces that plans
  13, 22, 23, 29, 32, 55, and 56–59 own, including the seventh package and overlay configuration.
- **Plan 48 remainder**, after plan 31 and its other Progress gates. The read-only provider is
  already complete; this leaf work adds mutation, commands, sandboxing, packaging, and the full
  one-off proof without sitting on the v1 service critical path.


## Critical path to v1

```text
Production:  19 ✅ → 22 ✅ → 28 ✅ → 27 ✅ → 32 → 14
Attestation: 49 ✅ → 50 ✅ → 51 ✅
Evidence:    43 ✅ → 44
Closure:     14 + 51 ✅ + 44 → 52 → 31

Router:      35 ✅ + 23 ✅ → 40 ✅ → 41 (in progress) → 42
Practice:    43 ✅ → 45
             43 ✅ → 44 → [Kikan IR-5 live gate]
Closure:     MasterPlan 8 + 44 + 45 → 46
Memory:             23 ✅ → [Meibo/Shomei pin proof] → 54 → 34

Overlays:   56 ✅ → 57 ✅ → 58 ✅
                         └→ 59 ✅ → 48 remainder
```

The delivery/consolidation lane through plan 27 is discharged. MasterPlan 8 is the active
initiative: finish plan 41, then 42 without interleaving another edit to the declaration
schema or agent workflow. MasterPlan 9 is its direct successor because plan 46 consumes the router;
plan 45 can advance independently, while the live half of plan 44 still waits on Kikan IR-5. The
memory lane remains conditional: plan 54 must prove the unreleased Meibo/Shomei source closure
rather than discover it halfway through M1.

The immediate queue, optimized to avoid reopening consumers, is now:

1. **Finish MasterPlan 8: complete plan 41, then plan 42.** Plan 40 is complete and plan 41's
   immutable directory-snapshot slice has landed; every external foundation and the plan-27
   consolidation are complete. This is now the no-rewrite path to a working declarative router.
2. **Advance MasterPlan 9, the direct successor.** Plan 45 is locally ready. Plan 44 may land its
   deterministic reader seam and stub fixtures, but its live adapter remains gated on
   `mori://shinzui/kikan/okf/improvement-requests/concepts/IR-5`; plan 46 follows MasterPlan 8 plus
   completed plans 44 and 45.
3. **Plan 32, then plan 14**, on the separate production-completion lane. Both need a fresh audit
   before implementation. Taking plan 32 first finalizes `SinkKind`, `SinkCredentials`, and
   `SinkHttp` before plan 14 constructs approval configuration, notification wiring, and the
   stable review-request identity.
4. **Plan 54's M0 dependency proof** may run independently now. Implement plan 54 only if that
   proof selects remote-reachable Meibo and Shomei commits that build against the cohort; then land
   it before plan 34.

Plan 45 is the safest parallel task while another contributor owns MasterPlan 8. Plan 12's old
M1–M2 are superseded, plan 48 still has open hard prerequisites, and plan 34's ungated milestones
should wait for plan 54; starting any of those now deliberately buys a second pass.

One live node still waits on another repository: plan 44's production adapter needs
`mori://shinzui/kikan/okf/improvement-requests/concepts/IR-5`. Its deterministic port and fixtures
can land, but they must not invent a second live Kikan contract; the other lanes can advance while
the upstream request waits.

If a v1 cut smaller than "all 18 remaining plans" becomes attractive, the natural line has moved:
**after MasterPlan 8 plus plans 32 and 14** yields a service with a real provider, honest sinks,
correct delivery semantics, checked durable topology and versioning, fail-closed profile resolution,
run evidence, authenticated egress, approvals, an operator CLI, health, and observability. Stage E's
conditional memory lane adds principal-keyed identity and memory features; stage F closes practice
reviews, attestation, deployment packaging, and the writable one-off harness.


## Upstream gates, current status

| Gate | Blocks | Status 2026-08-23 |
|---|---|---|
| `mori://shinzui/kioku/okf/improvement-requests/concepts/IR-1` | plan 47 | ✅ Closed. |
| kioku 0.3.0.0 | plan 53 M0 | ✅ Closed; superseded by the selected Kioku 0.5.0.0. |
| `mori://shinzui/baikai/okf/improvement-requests/concepts/IR-3` | plans 51, 52 | ✅ **Closed and consumed.** Plan 51 landed on `Baikai.Evidence`. |
| keiro 0.12 | plan 17 | ✅ **Moot and consumed.** The selected Keiro 0.14 lifted the cap; plan 17 landed. |
| Kioku admitting `baikai ^>=0.5` | plans 48, 51, 52 | ✅ Closed by Kioku 0.4.1.0; the selected release is now 0.5.0.0. |
| `mori://shinzui/shibuya/okf/improvement-requests/concepts/IR-1` | plan 29's worker probe | ✅ **Discharged in substance.** `shibuya-core 0.9.0.0` exports `getAppMetrics` / `ProcessorMetrics` / `ProcessorState` — a non-blocking read distinguishing idle, processing, failed-with-reason-and-time, and stopped, attributed by processor id. Plan 29 shipped on it and reports *last activity* rather than *last time we remembered to beat*. The IR is still `proposed` upstream and its second ask is unmet; it gates nothing here. |
| `mori://shinzui/keiro/okf/improvement-requests/concepts/IR-3` | plan 19 M1's blocked half | ✅ Closed by Keiro 0.14.0.0 and consumed when plan 19 landed. |
| `mori://shinzui/kioku/okf/improvement-requests/concepts/IR-2` | plan 34 | ❌ Still `proposed`. Plans 26 and 30 stopped waiting on it. |
| `mori://shinzui/baikai/okf/improvement-requests/concepts/IR-2` | plan 12 | ❌ Still `proposed`; Baikai 0.5.0.0 has no `Baikai.Mcp.*` source. |
| `mori://shinzui/shikumi/okf/improvement-requests/concepts/IR-1` | plan 12 | ❌ Still `proposed`; Shikumi 0.3.0.2 has no MCP adapter. |
| `mori://shinzui/kikan-en/okf/improvement-requests/concepts/IR-3` | plan 12 | ❌ Still `proposed`. |
| Meibo + Shomei source-package closure | plan 54 | ⚠️ Meibo has no Hackage release or tag; its remote `master` is `a641e2d`. `meibo-api` also depends on unreleased `mori://shinzui/shomei/packages/shomei-servant`. Plan 54 must select remote-reachable commits and compile-prove the closure before M1. |
| `mori://shinzui/kikan/okf/improvement-requests/concepts/IR-5` | plans 44, 46, 52 | ❌ Still `proposed`. |
| `mori://shinzui/kikan/okf/improvement-requests/concepts/IR-6` | plan 52 | ❌ Still `proposed`. Scope shrinks further: it ratifies the envelope, and plan 49 has now frozen the encoder locally as a wire format (ADR 0006). |
| Shikigami IR-9 | plans 34, 54 | ⏳ Plan 23's directory prerequisite is complete. Plan 54 remains at its external dependency gate; until it lands, `Shikigami.Memory.Access` mints self-asserted refs and the Kioku deprecation debt stands. |
| **Shikigami IR-8 — outbound** | **`mori://shinzui/mori/plans/150-add-an-agent-automation-action-that-invokes-shikigami-agents-from-reactions`, M4b** | ❌ **Shikigami is now somebody else's gate.** Mori's Agent automation action is written, its stage 4a is unblocked against a stub, and its stage 4b explicitly waits on Shikigami implementing IR-8. There is no plan here. See [Coverage gaps](#coverage-gaps). |

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

**Twenty registry rows are stale.** See [Registry rot](#registry-rot-twenty-stale-rows). This is
the cheapest open item in the portfolio and the one most likely to mislead the next reader.

**Six patch guards have unreachable legacy branches.** Their retirement now needs an explicit
post-topology cleanup: plan 27 landed without the sweep, and MasterPlan 8 will add a seventh guard.
See [Compatibility work that v1 does not owe](#compatibility-work-that-v1-does-not-owe).

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

Two findings are new. [Registry rot](#registry-rot-twenty-stale-rows) records that sixteen
MasterPlan rows call a complete plan "Not Started", which is why the status-precedence rule at the
top of this document is amended: the plan file wins, not the registry. And the
audit-before-implement instruction from 2026-08-19 is widened from citations to four things —
citations, the ADR corpus (3 records to 20 in two days), what the cohort already ships (three plans
found a released package doing work they had scheduled), and any premise about runtime behaviour
the plan has not executed. That last one is where the real cost was: plan 26's research was sound
and three of its unexecuted inferences were wrong.

Smaller corrections. Plan 37 M3's description was stale — the `CODD_*` contract is gone and only
the Settei unification remains, still blocked by the package cycle. Plan 8's build-and-test box is
satisfied incidentally; only the live Danwa observation remains.
`mori://shinzui/shibuya/okf/improvement-requests/concepts/IR-1` is discharged in substance and no
longer gates plan 29's worker probe. `mori://shinzui/kioku/okf/improvement-requests/concepts/IR-2`
no longer touches plan 26.
`keiro-pgmq`, `keiro-ops`, and `shibuya-kafka-adapter` joined the cohort table. And **IR-8 is
counted as a coverage gap for the first time**, which makes four unplanned inbound requests rather
than three — the one that matters most, because mori has already restructured a plan around it.


## Revision note (2026-08-21)

Plan 30 landed after the previous review. The portfolio is now 30 complete and 25 open. Its
operator surface mounts `keiro-ops`, its Shikigami-owned run view joins Keiro to the exact Kioku
session id stored in the workflow journal, and
`mori://shinzui/kioku/okf/improvement-requests/concepts/IR-2` is no longer an operator dependency.
That releases plan 23. It also makes the stale MasterPlan count seventeen, adds ADR 0021, and
corrects the test-suite advice: stop any manually started Shikigami processes before treating a
hang as inherent parallel-suite deadlock.

The larger correction is ordering. The previous revision called plan 40 entry-ready, but plan
40's own Progress and Context sections hard-depend on plan 35's `delegates` and
`delegationBudget`. This revision makes rewrite minimization the explicit sequencing rule and
promotes two other soft preferences for the same reason: plan 23 precedes plan 41 so the catalog
ships with the directory lifecycle adapter once, and plan 27 precedes plans 14 and 32 so those consumers
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


## Revision note (2026-08-23)

Plan 23 and plans 56–59 landed. The portfolio is now 37 complete and 22 open across 11
MasterPlans. Plan 23 supplies the cached, fail-closed directory and lifecycle enforcement seam, so
plan 41 can consume the real adapter. MasterPlan 11 supplies one provider-neutral capability
request/catalog/provider seam, exact-revision durable pinning, and the first confined
`workspace.read` provider. That initiative supersedes plan 12's proposed `mcpServers` field and
generic registry/loop work, and completes plan 48's read-only slice.

The immediate queue is now plan 22, then plan 28 and plan 27 on the delivery lane; plan 40 then
plan 41 on the router lane. Plans 40–42 were refreshed against the delivered August architecture;
their only remaining external-free order is 40 → 41 → 42, and no implementation milestone is
checked yet. Plan 54 is not yet an implementation-ready third lane: plan 23 cleared
its local prerequisite, but Meibo remains untagged and unreleased, and its API package pulls the
also-unreleased Shomei Servant package. A refreshed M0 dependency proof comes before plan 54 M1.
Plan 48 is likewise no longer described as independent filler because its own Progress section
still hard-gates the remainder on plan 31 and other open prerequisites.

The cohort summary is corrected to the selected Keiki 0.9.1, Keiro 0.14, and Kioku 0.5 releases
and adds `shikumi-tools` 0.3.0.2. Hackage for every row and the changed families' upstream tags
were reverified on 2026-08-23. The MasterPlan stale-row count is now eighteen, the ADR corpus
contains 25 records, and plan 58 raises the dead patch-guard sweep from five branches to six.


## Revision note (2026-08-23, post-delivery)

Plans 22, 28, 27, and 40 landed in order. The portfolio is now 41 complete and 18 open. Authenticated,
bounded HTTP and credential resolution are final; runtime logs, metrics, trace propagation, request
logging, and graceful telemetry lifecycle consume that seam; and sink-intent plus agent-run
lifecycle duplication has been consolidated afterward. Plan 40 then added the router declaration
policy on those final foundations. Plans 32 and 14 are consequently released onto final sink and
workflow surfaces.

MasterPlan 8 is now the active initiative, with plan 40 complete, plan 41 in progress after landing
its immutable directory-snapshot slice, and plan 42 still behind the catalog. MasterPlan 9 is its
direct successor: plan 45 is ready, plan 44 can land its deterministic reader seam but not its live Kikan adapter while
`mori://shinzui/kikan/okf/improvement-requests/concepts/IR-5` remains proposed, and plan 46 closes
only after both children and MasterPlan 8. On the separate production-completion lane, plan 32
precedes plan 14 so the latter consumes final `SinkKind`, `SinkCredentials`, and `SinkHttp` records.

The earlier ordering assigned six dead patch guards to plan 27 as a portfolio-added cleanup, but
the completed plan deliberately changed no patch set. That cleanup therefore remains unscheduled;
plan 42 intends to add a seventh guard. Give the sweep an explicit owner after the durable topology
for MasterPlans 8 and 9 settles and before the first real deployment. Finally, the registry-rot
count rises to twenty because the parent rows for completed plans 22 and 28 still say
`Not Started`; MasterPlan 5 correctly records plan 27 and MasterPlan 8 correctly records plan 40
complete plus plan 41 in progress.
