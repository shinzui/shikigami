---
id: 53
slug: upgrade-shikigami-to-the-keiro-0-11-and-keiki-0-9-cohort
title: "Upgrade Shikigami to the keiro 0.11 and keiki 0.9 cohort"
kind: exec-plan
created_at: 2026-08-06T03:49:01Z
intention: "intention_01kx1tyx3yehmsq9eyywdcf5c7"
master_plan: "docs/masterplans/5-durable-evolution-versioning-and-replay-safety-for-long-lived-workflows.md"
---

# Upgrade Shikigami to the keiro 0.11 and keiki 0.9 cohort

This ExecPlan is a living document. The sections Progress, Surprises & Discoveries,
Decision Log, and Outcomes & Retrospective must be kept up to date as work proceeds.


## Purpose / Big Picture

Shikigami builds against `keiro 0.4.0.1` and `keiki 0.4.0.0`. Hackage has `keiro 0.11.0.0`
and `keiki 0.9.0.0` — seven and five major releases ahead. After this plan the repository
builds against those, and the checked release matrix in `docs/dependency-cohort.md` says so.

It is worth being honest about why this is worth doing, because the obvious reason is wrong.
The keiro *runtime* API that shikigami actually calls — durable workflows, awakeables, child
workflows, timers, the transactional outbox, the idempotent inbox — is essentially unchanged
between 0.4 and 0.11. Upgrading buys almost nothing for the code that exists today. What it
buys is the code that does not exist yet:

- **`keiro-dsl 0.11`**, which is the entire subject of
  `docs/plans/39-adopt-a-checked-keiro-dsl-specification-and-evolution-gate.md`. Plan 39 was
  written against an older DSL. The 0.11 line adds a released *language 4*, a `check
  --min-language N` floor, `--deny-warnings` and `--deny CODE` for CI, a machine-readable
  `check --report-out` record, and resolution of every internally decidable process, router,
  projection, publisher, queue, pgmq source-key, read-model, and timer-ID surface. Those are
  precisely the mechanisms plan 39's Milestone 3 needs to turn "do not rename a journaled step"
  from tribal knowledge into a build failure. Adopting the DSL against 0.4 and re-adopting
  against 0.11 would be doing the work twice.
- **`keiki 0.9`**, which seals `InCtor`/`WireCtor` construction behind trusted producers and
  classifies replay head identity structurally. Every durable state machine a later plan writes
  is built on that.

The user-visible proof is narrow and should be stated as such: `cabal build all` and `cabal
test all` pass against the new pins, `docs/dependency-cohort.md` names the new matrix, and
`keiro-dsl --help` reports the 0.11 command surface that plan 39 will drive. There is no
behavior change to any running agent. That is the point — this is a foundation move, and a
successful one is invisible at runtime.


## Progress

Use a checklist to summarize granular steps. Every stopping point must be documented here,
even if it requires splitting a partially completed task into two ("done" vs. "remaining").
This section must always reflect the actual current state of the work.

- [ ] M0 (gate): a published `kioku` supporting `keiro 0.11` / `keiki 0.9` exists on Hackage.
      **Blocked as of 2026-08-05** — see Context. Kioku is being updated now; this plan cannot
      start until it lands. Record the version and its bounds here when it does.
- [ ] M1: pins bumped in `cabal.project`; `cabal build all --dry-run` resolves with no
      `allow-newer` between co-developed packages; the resolved matrix recorded.
- [ ] M2: the tree compiles. Expected fallout is confined to
      `shikigami-core/src/Shikigami/Flow/Lifecycle/AtRiskCustomer.hs`, the only file that
      imports `Keiki`.
- [ ] M2: `atRiskCustomerMermaid` re-checked against keiki 0.8's renderer change, and the
      FlowLifecycle rendering tests updated to whatever the chosen options actually produce.
- [ ] M2: `validateTransducer` results re-checked against keiki 0.7's conservative projection.
      If any check now returns `UnverifiedOpaque` where it returned a `Verified*` result,
      record it in Surprises & Discoveries and decide explicitly — do not silence it.
- [ ] M3: `cabal test all` green; wire-compatibility specs re-run and unchanged.
- [ ] M4: `docs/dependency-cohort.md` records the new matrix, the upstream tag behind each
      release, and the compatibility evidence.
- [ ] M4: plan 39 re-pointed at the keiro-dsl 0.11 surface (see Interfaces and Dependencies).


## Surprises & Discoveries

Document unexpected behaviors, bugs, optimizations, or insights discovered during
implementation. Provide concise evidence.

**The cohort is smaller than it looks.** Of shikigami's pinned co-developed packages, only
`kioku` depends on keiro or keiki at all. Checked on Hackage on 2026-08-05:
`kiroku-store-0.3.1.0`, `shibuya-core-0.8.0.1`, `shibuya-kiroku-adapter-0.4.0.0`, and
`pgmq-hasql-0.4.0.1` declare no dependency on either. So the coherence problem this plan has to
solve is a two-body problem — shikigami and kioku — not the nine-package matrix plan 47 faced.

**keiki reaches exactly one file.** `Shikigami/Flow/Lifecycle/AtRiskCustomer.hs` is the only
module in the repository that imports `Keiki` (`Keiki.Builder`, `Keiki.Core`,
`Keiki.Render.Mermaid`). Five keiki majors therefore have a blast radius of one file plus its
tests, which is why this upgrade is far less risky than the version numbers suggest.

**Upgrading does not unblock plan 19.** `docs/plans/19-sink-delivery-truth-and-downstream-idempotency.md`
Milestone 1 wants a released Keiro `PublishRejected` terminal outcome. It does not exist at
0.11 either: `PublishOutcome` is still `PublishSucceeded | PublishFailed` at
`keiro/src/Keiro/Outbox.hs:264-269` in the 0.11 tree, verified 2026-08-05. Keiro IR-3 remains
the gate; do not expect this plan to move it.


## Decision Log

Record every decision made while working on the plan.

- Decision: Treat a published, keiro-0.11-compatible `kioku` as a hard gate (M0) rather than
  working around it with `allow-newer`.
  Rationale: `kioku-core 0.2.0.0` — the only published version, and the one in the local
  checkout — declares `keiro ^>=0.4.0.1` and `keiki ^>=0.4.0.0`, both capped below the next
  major (verified against the Hackage `.cabal` and
  `/Users/shinzui/Keikaku/bokuno/kioku/kioku-core/kioku-core.cabal` on 2026-08-05). Forcing the
  solver past that would mean running kioku's session and memory code against a keiro it was
  never compiled or tested against, which is exactly the failure mode
  `docs/plans/47-upgrade-shikigami-to-the-coherent-july-2026-dependency-cohort.md` established
  the no-`allow-newer`-between-co-developed-packages rule to prevent. Kioku is being updated to
  this cohort now, so the gate is expected to clear on its own.
  Date: 2026-08-05

- Decision: Do this upgrade *before* plan 39 rather than after.
  Rationale: plan 39 encodes shikigami's durable identities in `domain/shikigami.keiro` and
  scaffolds generated modules from them. keiro-dsl 0.11 changes the generated naming edition
  (compound module paths move, for example `Service_oncall` → `ServiceOncall`), renames every
  scaffold sidecar file, and adds a released language 4 whose acceptance differs from earlier
  languages. Adopting the DSL at 0.4 and then upgrading would mean a scaffold-wide rename and a
  language migration on a spec that had just been hand-authored. Plan 39 should meet 0.11 first.
  Date: 2026-08-05

- Decision: Do not chase the intermediate releases; go 0.4 → 0.11 in one step.
  Rationale: keiro 0.5, 0.8, and 0.10 record "no changes this release; version moves with the
  package set", and 0.6, 0.7, and 0.9 are almost entirely keiki-bound bumps plus additive
  re-exports. There is no intermediate release whose behavior shikigami needs to observe
  separately, and stopping at each would multiply build cycles without adding evidence.
  Date: 2026-08-05

- Decision: Treat any new `UnverifiedOpaque` result from `validateTransducer` as a finding to
  record and decide, never as something to suppress.
  Rationale: keiki 0.7 made verification conservative across one-way generated projections, so
  a check that previously proved a property may now decline to. That is information about the
  at-risk-customer lifecycle, not noise. `Shikigami/Flow/Lifecycle/AtRiskCustomer.hs` already
  documents why each check is held (`checkStateChangingEpsilon` and the output-free-edge
  argument); a downgraded result means that documentation needs revisiting.
  Date: 2026-08-05


## Outcomes & Retrospective

Summarize outcomes, gaps, and lessons learned at major milestones or at completion.
Compare the result against the original purpose.

(To be filled during and after implementation.)


## Context and Orientation

Shikigami is a Haskell project built with Cabal inside a Nix development shell. **Every build
and test command must run under `nix develop -c`**: `librdkafka` is only on the linker path
inside the flake devShell, and a bare `cabal build all` fails at link time with
`ld: library not found for -lrdkafka` even when `cabal` and `ghc` resolve to nix store paths.

Two terms. *keiro* is the durable-workflow engine over PostgreSQL: an agent run is a keiro
workflow, journaled step by step so a crashed process can resume it, and outbound sink
deliveries go through keiro's transactional outbox. *keiki* is the typed state-machine
(transducer) library; shikigami uses it to model one agent lifecycle and render it as a
diagram.

### What is pinned today

`cabal.project` lines 19-24 pin the packages this plan moves:

```text
    keiki                   ==0.4.0.0
  , keiki-codec-json        ==0.4.0.0
  , keiro                   ==0.4.0.1
  , keiro-core              ==0.4.0.1
  , keiro-migrations        ==0.4.0.1
  , keiro-pgmq              ==0.4.0.1
```

Published on Hackage as of 2026-08-05: `keiro`, `keiro-core`, `keiro-dsl`, `keiro-migrations`,
and `keiro-pgmq` at `0.11.0.0`; `keiki` and `keiki-codec-json` at `0.9.0.0`. Confirm this again
before starting — the list moves:

```bash
for p in keiro keiro-core keiro-migrations keiro-pgmq keiki keiki-codec-json kioku-core; do
  echo -n "$p: "
  curl -s "https://hackage.haskell.org/package/$p/preferred.json" \
    | python3 -c "import sys,json;print(', '.join(json.load(sys.stdin)['normal-version'][:3]))"
done
```

### The gate

`kioku-core 0.2.0.0` requires `keiro ^>=0.4.0.1` and `keiki ^>=0.4.0.0`. The `^>=` operator caps
at the next major, so those bounds exclude keiro 0.11 and keiki 0.9 outright. `kioku-core` is a
hard dependency of `shikigami-core` (it owns `AppEnv`, memory, and sessions), so **this plan
cannot proceed until a kioku release carrying the new bounds is on Hackage.** Verify with:

```bash
curl -s https://hackage.haskell.org/package/kioku-core-<VERSION>/kioku-core.cabal \
  | grep -iE "keiro|keiki"
```

and expect bounds admitting `keiro 0.11` and `keiki 0.9`. Nothing else needs checking: no other
pinned co-developed package depends on keiro or keiki.

### What shikigami actually uses

The keiro surface, so you know what a break would touch. All of it is hand-written today;
none of it is generated:

| Capability | Modules |
|---|---|
| Durable workflows, journaled steps | `Keiro.Workflow` (`runWorkflow`, `step`) |
| Crash resume | `Keiro.Workflow.Resume` (`WorkflowRegistry`, `runWorkflowResumeWorker`) |
| Suspend and signal | `Keiro.Workflow.Awakeable` — approvals, delegation |
| Child workflows | `Keiro.Workflow.Child` (`spawnChild`, `awaitChild`) |
| Timers | `Keiro.Timer`, `Keiro.Workflow.Sleep` |
| Transactional outbox | `Keiro.Outbox` (`enqueueOutboxTx`, `publishClaimedOutbox`) |
| Idempotent inbox | `Keiro.Inbox`, `Keiro.Inbox.Kafka`, `Keiro.Inbox.Types` |
| Integration events | `Keiro.Integration.Event` |
| Projections, commands | `Keiro.Projection`, `Keiro.Command` |

The durable identities that replay depends on, which this upgrade must not disturb: workflow
names `shikigami.agent-run` and `shikigami.danwa-conversation`; the queue `shikigami_run_jobs`;
and thirteen journaled step names — `ingest-job`, `lookup-agent`, `open-session`, `recall`,
`run-behavior`, `dispatch-sinks`, `record`, `complete`, `fail-session`, `await-ack`, `classify`,
`ingest-start`, `resolve-session`.

### What changed upstream that matters

**keiro 0.5 → 0.11, for a runtime consumer: almost nothing.** 0.5, 0.8, and 0.10 are
"no changes; version moves with the package set". 0.6, 0.7, and 0.9 are keiki-bound bumps whose
only consumer-facing additions are re-exports: `Keiro.Codec.Nominal` (0.6),
`Keiro.Codec.IdDomain` (0.7, with `parseKindIdV7Text` / `parseKindIdV7Value` added in 0.9), and
`Keiro.Inbox.Types` re-exporting `RetryDelay` from `Shibuya.Core.Ack` (0.9). That last one is a
small simplification shikigami can take: `Shikigami.Trigger.Consumer` currently imports
`RetryDelay` from shibuya directly.

**keiki 0.7 — verification became conservative.** A predicate that crosses a one-way generated
projection is now opaque to symbolic proof, so `validateTransducer` may return
`UnverifiedOpaque` where 0.6 returned a `Verified*` result. Runtime execution is unchanged. This
is the one change with a real chance of surfacing in shikigami.

**keiki 0.8 — the Mermaid renderer changed.** `MermaidOptions` removed `showWrittenSlots` and
`showGuardSummary`; set `updateMode = MermaidUpdateWrittenSlots` and
`guardMode = MermaidGuardStructuralSummary` instead. More importantly, `toMermaid` and every
no-options shape renderer now default to *semantic truncation*; `toTopologyMermaid` with
`topologyMermaidOptions` produces the previous compact bytes. `TLit` and `lit` now require
`Show`. `Shikigami/Flow/Lifecycle/AtRiskCustomer.hs:82` calls
`toMermaidWith defaultMermaidOptions`, so its output may change and the FlowLifecycle rendering
tests may need new expectations.

**keiki 0.9 — construction sealed.** `WireCtor` and `InCtor` construction and record update are
behind read-only patterns; manual behavior uses `unavailableWireCtor` / `unavailableInCtor`, and
trusted construction uses the Generic or Template Haskell producers. `mkWireCtor` and `mkInCtor`
are deprecated. Shikigami constructs neither directly, so this is expected to be a non-event —
confirm rather than assume.

**keiro-dsl 0.11 — the reason to do this.** Released language 4; `check --min-language N`;
`--deny-warnings` and repeatable `--deny CODE` to make warnings CI-failing without changing
their severity; `check --report-out` writing the append-only `keiro-dsl/check-report/1` schema
through `Keiro.Dsl.CheckReport`; `scaffold --apply-name-migrations` for backup-backed,
digest-journaled source moves; field aliases (`haskell <selector>` and `as "<wire-key>"`); and
resolution of every internally decidable process, router, projection, publisher, queue, pgmq
source-key, read-model, and timer-ID surface. Note also that generated Haskell now uses one
checked UpperCamelCase/lowerCamelCase naming edition, so compound module paths differ from
earlier DSL output.


## Plan of Work

### Milestone 0 — the gate

Nothing in this plan can start until a published kioku admits keiro 0.11 and keiki 0.9. Check
with the two commands in Context. When it lands, record the version and its exact bounds in
Progress, and confirm that no *other* pinned package has grown a keiro or keiki dependency in
the meantime — the two-body assumption is worth re-verifying rather than inheriting.

### Milestone 1 — pins and resolution

Edit `cabal.project` lines 19-24 to the new versions, and bump `kioku-api`, `kioku-core`, and
`kioku-migrations` to the release from M0. Then resolve without building:

```bash
nix develop -c cabal build all --dry-run
```

The acceptance here is specifically that this succeeds **with no `allow-newer` stanza added**.
If the solver refuses, stop and read the conflict rather than relaxing a bound: a refusal at
this point means the cohort is genuinely incoherent and the answer is upstream, not local.

### Milestone 2 — compile, and the keiki fallout

Build. Expect the keiro-facing code to be untouched and the work to land in one file:

```bash
nix develop -c cabal build all --enable-tests
```

In `shikigami-core/src/Shikigami/Flow/Lifecycle/AtRiskCustomer.hs`, two things need judgement
rather than mechanical fixing.

First, the diagram. Decide whether the at-risk-customer diagram wants keiki 0.8's new default
(semantic truncation, via `toMermaidWith defaultMermaidOptions` as today) or the previous
compact rendering (`toTopologyMermaid` with `topologyMermaidOptions`). The consumer is
`render-lifecycle`, which emits a diagram a human reads, so prefer whichever is more legible and
say why in the Decision Log. Then update the FlowLifecycle expectations in
`shikigami-core/test/` to match — the tests to look at are the ones named for rendering the
expected states and for the registry diagram.

Second, validation. Run the transducer's checks and compare results to before the upgrade. If
keiki 0.7's conservatism downgrades any check to `UnverifiedOpaque`, that is a finding: record
it with the evidence, and either restructure the predicate so it is provable again or document
why an opaque result is acceptable here. Do not widen the validation options to make it go away.

### Milestone 3 — prove nothing moved

Run the full suite:

```bash
nix develop -c cabal test all
```

Pay particular attention to `Shikigami.WireCompatSpec`, which pins the exact bytes of
`shikigami_run_jobs` payloads and sink-outbox rows. Those encodings are shikigami's own, not
keiro's, so they must be **unchanged** — a diff there means something has reached further than
this upgrade should.

Also confirm the durable identities listed in Context still appear verbatim in the tree. A
grep is sufficient and worth doing explicitly, because a rename here is silent until a parked
workflow fails to resume.

### Milestone 4 — record it, and hand off to plan 39

Update `docs/dependency-cohort.md` with the new release matrix: package, previous version, new
version, the upstream tag, and the commit behind it. Follow the table format already there.

Then re-point `docs/plans/39-adopt-a-checked-keiro-dsl-specification-and-evolution-gate.md` at
the 0.11 surface. Plan 39's Milestone 3 currently says "add domain, DSL conformance,
integration-contract, and evolution-diff tests to CI"; with 0.11 that becomes concrete —
`keiro-dsl check --min-language 4 --deny-warnings --report-out <path>` plus
`keiro-dsl diff --since <ref>`. Record in plan 39 that its generated output follows the 0.11
naming edition, so it never has to run `scaffold --apply-name-migrations` for a spec authored
after this upgrade.


## Concrete Steps

All commands run from `/Users/shinzui/Keikaku/bokuno/shikigami`.

```bash
# M0 — the gate
curl -s https://hackage.haskell.org/package/kioku-core/preferred.json \
  | python3 -c "import sys,json;print(json.load(sys.stdin)['normal-version'][:3])"
curl -s https://hackage.haskell.org/package/kioku-core-<VERSION>/kioku-core.cabal \
  | grep -iE "keiro|keiki"

# M1 — pins, then resolve only
$EDITOR cabal.project
nix develop -c cabal build all --dry-run

# M2 — compile
nix develop -c cabal build all --enable-tests

# M3 — prove
nix develop -c cabal test all
grep -rhoE 'StepName "[a-z0-9-]+"' --include='*.hs' shikigami-core/src | sort -u
grep -rn 'WorkflowName "' --include='*.hs' shikigami-core/src

# M4 — the DSL surface plan 39 will drive
nix develop -c keiro-dsl check --help
```

The step-name grep must print exactly the thirteen names listed in Context, and the workflow-name
grep exactly `shikigami.agent-run` and `shikigami.danwa-conversation`.

A database is available for the database-backed suites; if the developer cluster is not running:

```bash
nix develop -c pg_ctl -D db/db -l db/postgres.log -o "-k $PWD/db -h \"\"" start
```


## Validation and Acceptance

Acceptance is behavioral and deliberately modest, because a correct foundation upgrade changes
no behavior:

1. `nix develop -c cabal build all --enable-tests` succeeds with the new pins and **no
   `allow-newer` between co-developed packages** in `cabal.project`.
2. `nix develop -c cabal test all` is green, including `Shikigami.WireCompatSpec` with its
   byte pins unchanged.
3. The thirteen journaled step names, two workflow names, and the queue name are unchanged.
4. `docs/dependency-cohort.md` names the new matrix with upstream tags.
5. `nix develop -c keiro-dsl check --help` reports the 0.11 options (`--min-language`,
   `--deny-warnings`, `--deny`, `--report-out`), confirming plan 39 has the surface it needs.

An end-to-end smoke is worth doing even though nothing should change: start the worker, enqueue
one run, and confirm a `worker.job.completed` and a `sink.result` line still appear (the
structured-logging vocabulary from
`docs/plans/28-structured-logging-metrics-and-trace-propagation.md`).


## Idempotence and Recovery

Every change is to `cabal.project` pins, one Haskell source file, its tests, and documentation.
Recovery is `git checkout -- cabal.project` and a rebuild; there is no data migration, no schema
change, and no wire-format change. Nothing in this plan writes to a database.

The upgrade is safe to abandon at any milestone boundary because each leaves the tree either on
the old pins entirely or on the new pins with a green build. Do not leave the tree in a state
where `cabal.project` names the new versions and `allow-newer` hides an unresolved conflict —
that is the one outcome this plan is written to prevent.


## Interfaces and Dependencies

Hard gate: a published `kioku` admitting `keiro 0.11` and `keiki 0.9`. Nothing else blocks.

Consumed upstream, verified on 2026-08-05:

- `keiro`, `keiro-core`, `keiro-migrations`, `keiro-pgmq`, `keiro-dsl` at `0.11.0.0`
  (`mori://shinzui/keiro`, tags `keiro-0.11.0.0` and siblings).
- `keiki`, `keiki-codec-json` at `0.9.0.0` (`mori://shinzui/keiki`, tag `v0.9.0.0`).

Downstream consequences inside this repository:

- `docs/plans/39-adopt-a-checked-keiro-dsl-specification-and-evolution-gate.md` **hard-depends
  on this plan** and should not start before it; see the Decision Log for why.
- `docs/plans/24-flow-versioning-with-keiro-patch-and-continue-as-new.md`,
  `docs/plans/25-replay-safe-flow-memory-capabilities.md`,
  `docs/plans/26-conversation-workflow-lifecycle-idle-timeout-journal-rotation-session-completion.md`,
  `docs/plans/27-consolidate-sink-intent-and-run-lifecycle-machinery.md`,
  `docs/plans/35-delegation-as-a-first-class-declared-capability.md`,
  `docs/plans/50-fail-closed-profile-resolution-and-run-pinning.md`, and
  `docs/plans/51-run-evidence-aggregate-and-compliance-roll-up.md` all reach keiro through
  plan 39 and inherit this upgrade transitively. None needs its own pin work.
- `docs/plans/19-sink-delivery-truth-and-downstream-idempotency.md` is **not** unblocked by this
  plan. See Surprises & Discoveries.

This plan owns no runtime module. It touches `cabal.project`,
`shikigami-core/src/Shikigami/Flow/Lifecycle/AtRiskCustomer.hs`, that module's tests, and
`docs/dependency-cohort.md`.


## Revision Notes

- 2026-08-05: Created. Records that keiro 0.11 and keiki 0.9 are published, that
  `kioku-core 0.2.0.0`'s `^>=0.4` bounds are the only thing blocking the upgrade, that no other
  pinned co-developed package depends on keiro or keiki, and that the real payoff is keiro-dsl
  0.11 for plan 39 rather than any runtime change.
