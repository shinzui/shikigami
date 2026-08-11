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

**The gate this plan was blocked on cleared on 2026-08-05.** `kioku 0.3.0.0` was published that
day and declares `keiki ^>=0.9.0.0`, `keiro ^>=0.11.0.0`, and `keiro-core ^>=0.11.0.0`. That was
the single condition Milestone 0 waited for, so this plan is startable now and is the first thing
that should be implemented in the repository — see the ordering argument in
`docs/architecture/implementation-order.md`.

This plan also takes four smaller version moves that became available in the same window, because
taking them here costs one build cycle and taking them separately costs several: `shikumi 0.3.0.2`
(a patch), and `pgmq-core`/`pgmq-hasql`/`pgmq-effectful`/`pgmq-migration` at `0.5.0.0` together
with `shibuya-pgmq-adapter 0.13.0.0`, which is the adapter release that consumes pgmq 0.5 while
still accepting the `shibuya-core 0.8.0.1` that keiro 0.11 requires.

Equally important is what this plan deliberately does **not** take, because three tempting newer
releases are excluded by the bounds of the very packages this cohort is built around, and trying
to take them is how this upgrade turns into an unresolvable solver fight. See "What this cohort
excludes, and why" in Context.

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

- [x] (2026-08-10) M0 (gate): **cleared.** `kioku 0.3.0.0` is published on Hackage (tag
      `v0.3.0.0`, 2026-08-05) and `kioku-core.cabal` at that tag declares
      `keiki ^>=0.9.0.0`, `keiro ^>=0.11.0.0`, `keiro-core ^>=0.11.0.0`, and
      `keiro-migrations ^>=0.11.0.0`. It is a bounds-only release: no kioku source file changed,
      no migration was added, and no event payload or snapshot is affected.
- [x] (2026-08-10) M0: the two-body assumption re-verified. Re-checked on 2026-08-10 that no
      other pinned co-developed package has grown a keiro or keiki dependency.
- [ ] M1: pins bumped in `cabal.project` — `keiki`/`keiki-codec-json` to `0.9.0.0`,
      `keiro`/`-core`/`-migrations` to `0.11.0.0`, `kioku-api`/`-core`/`-migrations` to
      `0.3.0.0`, `shikumi` to `0.3.0.2`, `pgmq-*` to `0.5.0.0`, `shibuya-pgmq-adapter` to
      `0.13.0.0`. `cabal build all --dry-run` resolves with no `allow-newer` between
      co-developed packages; the resolved matrix recorded.
- [ ] M1: `keiro-pgmq` removed from the constraints block if it is still listed — plan 47
      recorded that it left the build plan when kioku moved to `pg-migrate`.
- [ ] M2: the tree compiles. Fallout is expected in exactly one file,
      `shikigami-core/src/Shikigami/Flow/Lifecycle/AtRiskCustomer.hs`.
- [ ] M2: the four `InCtor` values in `AtRiskCustomer.hs` moved off direct record construction,
      which keiki 0.9 seals. Prefer `mkInCtorVia @"<ConstructorName>"`, which requires adding
      `Generic` to `AtRiskCustomerCommand`'s deriving clause — see Surprises & Discoveries for
      why this is not the same choice as `unavailableInCtor`.
- [ ] M2: `atRiskCustomerMermaid` re-checked against keiki 0.8's renderer change, and the
      FlowLifecycle rendering tests updated to whatever the chosen options actually produce.
- [ ] M2: `validateTransducer` results re-checked against keiki 0.7's conservative projection.
      If any check now returns `UnverifiedOpaque` where it returned a `Verified*` result,
      record it in Surprises & Discoveries and decide explicitly — do not silence it.
- [ ] M3: `cabal test all` green. `Shikigami.WireCompatSpec` is a change detector here, not a
      compatibility contract — see the Decision Log entry of 2026-08-10.
- [ ] M4: `docs/dependency-cohort.md` records the new matrix, the upstream tag behind each
      release, and — as named rows, not omissions — the three releases this cohort excludes and
      the bound that excludes each.
- [ ] M4: plan 39 re-pointed at the keiro-dsl 0.11 surface (see Interfaces and Dependencies).
- [ ] M4: the two upstream release requests filed — `keiro 0.12` and a `kioku` admitting
      `baikai ^>=0.5` — because between them they gate plans 17, 48, 51, and 52.


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
`keiro/src/Keiro/Outbox.hs:264-269` in the 0.11 tree, re-verified 2026-08-10. Keiro IR-3 remains
the gate; do not expect this plan to move it.

**Correction (2026-08-10): keiki 0.9's sealed construction *does* reach this repository.** The
2026-08-05 draft of this plan said "Shikigami constructs neither `WireCtor` nor `InCtor`
directly, so this is expected to be a non-event". That is wrong.
`shikigami-core/src/Shikigami/Flow/Lifecycle/AtRiskCustomer.hs:128-134` builds an `InCtor` by
direct record construction:

```haskell
nullary :: String -> AtRiskCustomerCommand -> InCtor AtRiskCustomerCommand '[]
nullary name command =
  InCtor
    { icName = name,
      icMatch = \candidate -> if candidate == command then Just RNil else Nothing,
      icBuild = \RNil -> command
    }
```

Under keiki 0.9 `InCtor` is a read-only pattern synonym — matching and field selection still
work, construction and record update do not — so this will not compile. Four call sites use it:
`classifyLowRisk`, `classifyHighRisk`, `acknowledge`, and `deadlineExpired`, at lines 112-126.

**The obvious fix is the wrong one, and the difference interacts with the validation concern
above.** keiki 0.9 offers two ways out. `unavailableInCtor name match build` has exactly the
shape of the existing `nullary` helper and is a one-line mechanical substitution — but its
haddock is explicit that the result "carries no trusted structural evidence". `mkInCtorVia
@"ClassifyLowRisk"` derives the match/build pair from the type's `Generic` representation and
does carry that evidence. Since this same milestone has to re-check whether
`validateTransducer` has started returning `UnverifiedOpaque`, deliberately choosing the
evidence-free constructor first would be sawing off the branch: it makes conservative validation
*more* likely and then leaves you unable to tell whether the downgrade came from keiki 0.7's
conservatism or from your own construction choice. Take `mkInCtorVia`, which needs `Generic`
added to `AtRiskCustomerCommand`'s deriving clause at
`shikigami-core/src/Shikigami/Flow/Lifecycle/AtRiskCustomer.hs:42` (currently
`deriving stock (Eq, Show)`), and fall back to `unavailableInCtor` only if the Generic path
genuinely does not typecheck — recording that here if so.


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

- Decision: Widen this plan's scope to `shikumi 0.3.0.2`, `pgmq-* 0.5.0.0`, and
  `shibuya-pgmq-adapter 0.13.0.0`, but no further.
  Rationale: each is admissible alongside keiro 0.11 and kioku 0.3, verified on 2026-08-10.
  `shikumi 0.3.0.2` satisfies kioku 0.3's `shikumi ^>=0.3.0.1`. `shibuya-pgmq-adapter 0.13.0.0`
  requires `pgmq-* ^>=0.5` and `shibuya-core ^>=0.8.0.1` — checked in that tag's
  `shibuya-pgmq-adapter/shibuya-pgmq-adapter.cabal` lines 49-52 — so it takes pgmq 0.5 without
  needing shibuya-core 0.9, which keiro 0.11 forbids. Bundling them costs one build cycle here
  and saves three separate pin-and-rebuild rounds later. The one behavioral note: pgmq 0.5
  narrows `parseQueueName` to `[a-z0-9_]{1,47}`, and `shikigami_run_jobs`
  (`shikigami-core/src/Shikigami/Trigger/Enqueue.hs:29`) already conforms.
  Date: 2026-08-10

- Decision: Do not attempt `shibuya-core 0.9.0.0`, `kiroku-store 0.4.0.0`, or `baikai 0.5.0.0`
  in this plan, and record each exclusion as a named row in `docs/dependency-cohort.md` rather
  than leaving it silent.
  Rationale: all three are published and all three are excluded by a bound belonging to a
  package this cohort is built on, so attempting any of them turns M1 into an unresolvable
  solver conflict. `keiro 0.11.0.0`'s `keiro/keiro.cabal` declares
  `kiroku-store >=0.3 && <0.4` and `shibuya-core >=0.8.0.1 && <0.9`; `kioku-core 0.3.0.0`
  declares `baikai ^>=0.4.1.0`, which excludes 0.5. A silent omission would read as an oversight
  to the next person and invite exactly the `allow-newer` this rule exists to prevent. Each
  exclusion has a named upstream successor and a named downstream consumer, recorded in
  Interfaces and Dependencies.
  Date: 2026-08-10

- Decision: Treat `Shikigami.WireCompatSpec` as a change detector in this plan, not as a
  compatibility contract, and do not add replay or queue-codec compatibility fixtures.
  Rationale: shikigami has no users. No database holds history, no workflow instance is in
  flight, and no external consumer reads a `shikigami_run_jobs` payload or a sink-outbox row.
  The 2026-08-05 draft inherited plan 47's "wire-compatibility specs re-run and unchanged"
  acceptance from a context where preserving old wire data mattered. Here the spec is still
  worth running — an unexplained diff means something reached further than a pin bump should,
  which is real information — but a diff is a prompt to understand the cause, not a release
  blocker, and updating the pinned bytes is a legitimate resolution once the cause is known.
  Date: 2026-08-10

- Decision: Prefer `mkInCtorVia` over `unavailableInCtor` for the four sealed-construction fixes.
  Rationale: recorded in full in Surprises & Discoveries. In short, `unavailableInCtor` is the
  mechanically closer substitution but yields a constructor carrying no trusted structural
  evidence, which makes this same milestone's `validateTransducer` re-check ambiguous — a
  downgraded result could no longer be attributed to keiki 0.7's conservatism rather than to
  this plan's own choice.
  Date: 2026-08-10

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

### The gate, and that it is now open

The gate was `kioku-core 0.2.0.0`, which required `keiro ^>=0.4.0.1` and `keiki ^>=0.4.0.0`. The
`^>=` operator caps at the next major, so those bounds excluded keiro 0.11 and keiki 0.9
outright, and `kioku-core` is a hard dependency of `shikigami-core` (it owns `AppEnv`, memory,
and sessions).

**`kioku 0.3.0.0` cleared it on 2026-08-05.** It is a deliberate bounds-only release — kioku's
changelog states that no source file changed, no migration was added, and no event payload or
snapshot is affected; it is a major bump only because `kioku-core` forces its consumers onto
keiki 0.9's sealed constructor API and no `kioku-core` spans both cohorts. Re-confirm before
starting, because bounds are the whole point of this release:

```bash
curl -s https://hackage.haskell.org/package/kioku-core-0.3.0.0/kioku-core.cabal \
  | grep -iE "keiro|keiki|baikai|shikumi|kiroku"
```

Expect `keiki ^>=0.9.0.0`, `keiro ^>=0.11.0.0`, `keiro-core ^>=0.11.0.0`,
`kiroku-store ^>=0.3.0.1`, `shikumi ^>=0.3.0.1`, and — importantly for what this plan cannot do
— `baikai ^>=0.4.1.0`.

One consequence of kioku 0.3 worth knowing before M2: its changelog warns that keiki 0.9's
rewritten inversion-ambiguity analysis can change the warning set from `validateEventStream` /
`mkEventStream`, and that `mkEventStreamOrThrow` now fails at runtime rather than at compile
time. Kioku's own streams still assemble clean, but a consumer with its own streams should
exercise its startup path. Shikigami should therefore actually start a worker during M3 rather
than infer from a green test suite that startup is fine.

### What this cohort excludes, and why

Three newer releases are published, are tempting, and must not be attempted here. Each is
excluded by a bound belonging to a package this cohort is built on, so reaching for any of them
converts Milestone 1 from a pin bump into an unresolvable solver conflict. Verified against the
named files on 2026-08-10.

`shibuya-core 0.9.0.0` and `kiroku-store 0.4.0.0` are both excluded by keiro 0.11 itself:
`keiro/keiro.cabal` at tag `keiro-0.11.0.0` declares `kiroku-store >=0.3 && <0.4` and
`shibuya-core >=0.8.0.1 && <0.9`. `shibuya-pgmq-adapter 0.14.0.0` follows shibuya-core 0.9 and is
excluded transitively, which is why this plan takes `0.13.0.0` instead; `shibuya-kiroku-adapter
0.4.0.1` follows kiroku-store 0.4 and is excluded the same way. The successor that lifts all
four is **`keiro 0.12`**, already staged in keiro's `Unreleased` changelog section, which
requires `kiroku-store >=0.4 && <0.5`. Its downstream consumer here is
`docs/plans/17-behavior-retry-semantics-run-timeouts-and-visibility-heartbeat.md`, which needs
shibuya-core 0.9's `ApplicationFailure DeadLetterCode Text`.

`baikai 0.5.0.0` is excluded by `kioku-core 0.3.0.0`'s `baikai ^>=0.4.1.0`. The successor is a
kioku release admitting `baikai ^>=0.5`. Its downstream consumers here are
`docs/plans/48-add-a-portable-one-off-repository-agent-harness.md`,
`docs/plans/51-run-evidence-aggregate-and-compliance-roll-up.md`, and
`docs/plans/52-signed-attestation-read-api-and-uc-8-conformance.md`, which between them want
`Baikai.Agent` and `Baikai.Evidence`.

Both successor releases should be requested upstream as part of Milestone 4. They are not this
plan's work, but this plan is where the need becomes legible, and four other plans wait on them.

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

**keiki 0.9 — construction sealed. This is the one change that definitely breaks the build.**
`WireCtor` and `InCtor` construction and record update are behind read-only patterns; manual
behavior uses `unavailableWireCtor` / `unavailableInCtor`, and trusted construction uses the
Generic or Template Haskell producers (`mkInCtorVia`, `mkWireCtorVia`). `mkWireCtor`, `mkInCtor`,
`mkWireCtor0`, and `mkInCtor0` are deprecated. Shikigami *does* construct `InCtor` directly, in
`AtRiskCustomer.hs` — the 2026-08-05 draft of this plan said otherwise and was wrong. See
Surprises & Discoveries for the four affected values, the two available fixes, and why
`mkInCtorVia` is the right one.

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

### Milestone 0 — the gate (complete)

This milestone is done: `kioku 0.3.0.0` admits keiro 0.11 and keiki 0.9, and no other pinned
co-developed package has grown a keiro or keiki dependency. Re-run the verification command in
Context before starting M1 anyway — it costs a second, and a plan that assumes a bound it has
not looked at is the failure mode this milestone exists to prevent.

### Milestone 1 — pins and resolution

Edit the `constraints:` block in `cabal.project` to the versions listed in Progress. Concretely:
`keiki` and `keiki-codec-json` to `0.9.0.0`; `keiro`, `keiro-core`, and `keiro-migrations` to
`0.11.0.0`; `kioku-api`, `kioku-core`, and `kioku-migrations` to `0.3.0.0`; `shikumi` to
`0.3.0.2`; `pgmq-core`, `pgmq-hasql`, `pgmq-effectful`, and `pgmq-migration` to `0.5.0.0`; and
`shibuya-pgmq-adapter` to `0.13.0.0`. Leave `shibuya-core` at `0.8.0.1`, `kiroku-store` at
`0.3.1.0`, `shibuya-kiroku-adapter` at `0.4.0.0`, `baikai` at `0.4.1.0`, and `baikai-claude` at
`0.4.0.1` — those five are held down by the bounds described in "What this cohort excludes, and
why", and moving any of them is what makes the solver fail.

While in the file, drop `keiro-pgmq` from the constraints block if it is still there. Plan 47
recorded that it left the build plan when kioku moved its migrations to `pg-migrate`, and a pin
on a package no longer in the plan is a bound nobody will think to update.

Then resolve without building:

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

In `shikigami-core/src/Shikigami/Flow/Lifecycle/AtRiskCustomer.hs`, three things need work, of
which the first is mechanical and the other two need judgement.

First, the sealed constructors. The build will stop at the `nullary` helper on line 128, because
`InCtor` is now a read-only pattern and its record syntax no longer constructs. Replace the four
values at lines 112-126 with `mkInCtorVia`, which derives the match and build functions from the
type's `Generic` representation:

```haskell
classifyLowRisk :: InCtor AtRiskCustomerCommand '[]
classifyLowRisk = mkInCtorVia @"ClassifyLowRisk"
```

and likewise for `classifyHighRisk`, `acknowledge`, and `deadlineExpired`. This requires
`Generic` in `AtRiskCustomerCommand`'s deriving clause on line 42, which today reads
`deriving stock (Eq, Show)` and should read `deriving stock (Eq, Generic, Show)`. The `nullary`
helper then has no remaining callers and should be deleted rather than left as dead code. If the
Generic path does not typecheck, fall back to `unavailableInCtor name match build`, which takes
exactly the arguments `nullary` already computes — but record in Surprises & Discoveries that you
did, because it changes how the next item should be read.

Second, the diagram. Decide whether the at-risk-customer diagram wants keiki 0.8's new default
(semantic truncation, via `toMermaidWith defaultMermaidOptions` as today) or the previous
compact rendering (`toTopologyMermaid` with `topologyMermaidOptions`). The consumer is
`render-lifecycle`, which emits a diagram a human reads, so prefer whichever is more legible and
say why in the Decision Log. Then update the FlowLifecycle expectations in
`shikigami-core/test/` to match — the tests to look at are the ones named for rendering the
expected states and for the registry diagram.

Third, validation. Run the transducer's checks and compare results to before the upgrade. If
keiki 0.7's conservatism downgrades any check to `UnverifiedOpaque`, that is a finding: record
it with the evidence, and either restructure the predicate so it is provable again or document
why an opaque result is acceptable here. Do not widen the validation options to make it go away.
This is the reason the first item chose `mkInCtorVia`: an evidence-free constructor would give
conservative validation a second possible cause and make this comparison uninterpretable.

### Milestone 3 — prove nothing moved

Run the full suite:

```bash
nix develop -c cabal test all
```

`Shikigami.WireCompatSpec` pins the exact bytes of `shikigami_run_jobs` payloads and sink-outbox
rows. Read a diff there as a change detector rather than as a broken contract: shikigami has no
users, so no stored payload and no external reader depends on those bytes, and the Decision Log
entry of 2026-08-10 records that judgement. What a diff *does* mean is that a pin bump reached
further than it should have, which is worth understanding before you accept it. Investigate the
cause, write it into Surprises & Discoveries, and then update the pinned bytes if the cause is
benign.

Also confirm the durable identities listed in Context still appear verbatim in the tree. A grep
is sufficient and worth doing explicitly. The reason is weaker than it was — with no deployed
instances there is no parked workflow to fail to resume — but these names are about to become
the input to plan 39's checked specification, and it is much cheaper to notice a drifted step
name now than to discover it as a diff against a freshly authored `domain/shikigami.keiro`.

Finally, start the worker once. Kioku 0.3's changelog warns that keiki 0.9 moved
`mkEventStreamOrThrow`'s failure from compile time to runtime, so a green test suite is not by
itself evidence that process startup is intact. The end-to-end smoke described in Validation and
Acceptance covers this.

### Milestone 4 — record it, hand off to plan 39, and ask upstream for the rest

Update `docs/dependency-cohort.md` with the new release matrix: package, previous version, new
version, the upstream tag, and the commit behind it. Follow the table format already there.

Give the three excluded releases named rows of their own rather than leaving them out. For each,
record the release that is available, the exact bound that excludes it, and the upstream release
that would lift it. A reader who finds `shibuya-core 0.8.0.1` pinned while 0.9.0.0 is on Hackage
should be able to see in one place that this is a decision rather than neglect — otherwise the
next person to notice will reach for `allow-newer`, which is the single thing the cohort
discipline exists to prevent.

Then file the two upstream requests, because four plans in this repository wait on them and
nothing surfaces that need except this milestone. The first asks the keiro project to publish
`0.12` — its `Unreleased` section is already written and already requires
`kiroku-store >=0.4 && <0.5` — which lifts the `shibuya-core <0.9` and `kiroku-store <0.4` caps
and unblocks plan 17. The second asks the kioku project for a release admitting
`baikai ^>=0.5`, which unblocks plans 48, 51, and 52. Reference both by canonical URI
(`mori://shinzui/keiro` and `mori://shinzui/kioku`) and record the request identifiers in
Progress once filed.

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
# M0 — the gate (already cleared; re-confirm, do not assume)
curl -s https://hackage.haskell.org/package/kioku-core-0.3.0.0/kioku-core.cabal \
  | grep -iE "keiro|keiki|baikai|shikumi|kiroku"

# M0 — re-confirm the three exclusions still hold before pinning
curl -s https://hackage.haskell.org/package/keiro-0.11.0.0/keiro.cabal \
  | grep -iE "kiroku-store|shibuya-core"

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
2. `nix develop -c cabal test all` is green. If `Shikigami.WireCompatSpec` diffs, the cause is
   understood and written down before the pinned bytes are updated.
3. The thirteen journaled step names, two workflow names, and the queue name are unchanged.
4. `docs/dependency-cohort.md` names the new matrix with upstream tags, **and** names
   `shibuya-core 0.9.0.0`, `kiroku-store 0.4.0.0`, and `baikai 0.5.0.0` as deliberate exclusions
   with the bound and the successor release for each.
5. `nix develop -c keiro-dsl check --help` reports the 0.11 options (`--min-language`,
   `--deny-warnings`, `--deny`, `--report-out`), confirming plan 39 has the surface it needs.

The end-to-end smoke is required rather than optional, and the reason is specific. Kioku 0.3's
changelog records that keiki 0.9 moved `mkEventStreamOrThrow`'s failure from compile time to
runtime, so neither a clean build nor a green suite proves that a process still starts. Start the
worker, enqueue one run, and confirm a `worker.job.completed` and a `sink.result` line still
appear (the structured-logging vocabulary from
`docs/plans/28-structured-logging-metrics-and-trace-propagation.md`). A worker that fails during
event-stream assembly will do so on startup, before any job is drained, and that is exactly the
failure this step is here to catch.


## Idempotence and Recovery

Every change is to `cabal.project` pins, one Haskell source file, its tests, and documentation.
Recovery is `git checkout -- cabal.project` and a rebuild; there is no data migration, no schema
change, and no wire-format change. Nothing in this plan writes to a database.

The upgrade is safe to abandon at any milestone boundary because each leaves the tree either on
the old pins entirely or on the new pins with a green build. Do not leave the tree in a state
where `cabal.project` names the new versions and `allow-newer` hides an unresolved conflict —
that is the one outcome this plan is written to prevent.


## Interfaces and Dependencies

Hard gate: **cleared.** It was a published `kioku` admitting `keiro 0.11` and `keiki 0.9`, and
`kioku 0.3.0.0` (2026-08-05) is that release. Nothing else blocks this plan.

Consumed upstream, verified on 2026-08-10:

- `keiro`, `keiro-core`, `keiro-migrations`, `keiro-dsl` at `0.11.0.0`
  (`mori://shinzui/keiro`, tags `keiro-0.11.0.0` and siblings).
- `keiki`, `keiki-codec-json` at `0.9.0.0` (`mori://shinzui/keiki`, tag `v0.9.0.0`).
- `kioku-api`, `kioku-core`, `kioku-migrations` at `0.3.0.0` (`mori://shinzui/kioku`, tag
  `v0.3.0.0`).
- `shikumi` at `0.3.0.2` (`mori://shinzui/shikumi`, tag `shikumi-0.3.0.2`).
- `pgmq-core`, `pgmq-hasql`, `pgmq-effectful`, `pgmq-migration` at `0.5.0.0`
  (`mori://shinzui/pgmq-hs`, tag `v0.5.0.0`).
- `shibuya-pgmq-adapter` at `0.13.0.0` (`mori://shinzui/shibuya-pgmq-adapter`, tag `v0.13.0.0`).

Held down deliberately, with the excluding bound and the successor release that lifts it:

- `shibuya-core` stays at `0.8.0.1`; `0.9.0.0` is excluded by keiro 0.11's
  `shibuya-core >=0.8.0.1 && <0.9`. Lifted by `keiro 0.12`.
- `kiroku-store` stays at `0.3.1.0` and `shibuya-kiroku-adapter` at `0.4.0.0`; `0.4.0.0` and
  `0.4.0.1` respectively are excluded by keiro 0.11's `kiroku-store >=0.3 && <0.4`. Lifted by
  `keiro 0.12`.
- `baikai` stays at `0.4.1.0` and `baikai-claude` at `0.4.0.1`; `0.5.0.0` is excluded by
  `kioku-core 0.3.0.0`'s `baikai ^>=0.4.1.0`. Lifted by a kioku release admitting
  `baikai ^>=0.5`.

Upstream requests this plan should file (Milestone 4), because no other plan surfaces the need:
`keiro 0.12` against `mori://shinzui/keiro`, and a baikai-0.5-admitting release against
`mori://shinzui/kioku`.

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
- `docs/plans/17-behavior-retry-semantics-run-timeouts-and-visibility-heartbeat.md`,
  `docs/plans/48-add-a-portable-one-off-repository-agent-harness.md`,
  `docs/plans/51-run-evidence-aggregate-and-compliance-roll-up.md`, and
  `docs/plans/52-signed-attestation-read-api-and-uc-8-conformance.md` are **not** unblocked by
  this plan either, and each is waiting on one of the two upstream releases this plan requests.

This plan owns no runtime module. It touches `cabal.project`,
`shikigami-core/src/Shikigami/Flow/Lifecycle/AtRiskCustomer.hs`, that module's tests, and
`docs/dependency-cohort.md`.

No relevant ADR exists: this repository has no `docs/adr/` directory. The durable cohort contract
lives in `docs/dependency-cohort.md`, which Milestone 4 updates, and that document is the thing a
future reader should be pointed at.


## Revision Notes

- 2026-08-05: Created. Records that keiro 0.11 and keiki 0.9 are published, that
  `kioku-core 0.2.0.0`'s `^>=0.4` bounds are the only thing blocking the upgrade, that no other
  pinned co-developed package depends on keiro or keiki, and that the real payoff is keiro-dsl
  0.11 for plan 39 rather than any runtime change.

- 2026-08-10: Unblocked, widened, corrected, and narrowed — in that order of importance.

  **Unblocked.** Milestone 0's gate cleared on 2026-08-05 with `kioku 0.3.0.0`, which declares
  `keiki ^>=0.9.0.0` and `keiro ^>=0.11.0.0`. The plan had recorded the gate as open and nobody
  had re-checked it in five days. M0 is now checked off with the version and bounds recorded, and
  the Purpose section states plainly that this plan is startable and is the first thing to
  implement in the repository.

  **Widened.** Scope now includes `shikumi 0.3.0.2`, `pgmq-* 0.5.0.0`, and
  `shibuya-pgmq-adapter 0.13.0.0`. All three became available in the same window and all three
  are admissible alongside keiro 0.11 and kioku 0.3 — in particular adapter 0.13 takes pgmq 0.5
  while still accepting `shibuya-core 0.8.0.1`, which keiro 0.11 requires. Bundling them costs
  one build cycle instead of three.

  **Corrected.** The plan asserted that shikigami "constructs neither `WireCtor` nor `InCtor`
  directly, so this is expected to be a non-event". That is false:
  `shikigami-core/src/Shikigami/Flow/Lifecycle/AtRiskCustomer.hs:128-134` builds an `InCtor` by
  record construction, which keiki 0.9 seals, so the build will stop there. Milestone 2 now
  carries the concrete fix (`mkInCtorVia` plus a `Generic` derivation), and the Decision Log
  records why `mkInCtorVia` rather than the mechanically closer `unavailableInCtor`: the latter
  carries no trusted structural evidence and would make the same milestone's `validateTransducer`
  re-check impossible to attribute.

  **Narrowed.** Two things left the plan. Wire- and replay-compatibility evidence is gone,
  because shikigami has no users: no stored payload, in-flight workflow, or external reader
  depends on those bytes, so `Shikigami.WireCompatSpec` is now framed as a change detector whose
  diff must be explained rather than a contract that must not move. And the plan now states
  explicitly that it does **not** take `shibuya-core 0.9.0.0`, `kiroku-store 0.4.0.0`, or
  `baikai 0.5.0.0`, naming for each the bound that excludes it and the upstream release that
  would lift it — a new "What this cohort excludes, and why" section in Context, matching rows in
  Interfaces and Dependencies, and named rows in the `docs/dependency-cohort.md` update that
  Milestone 4 produces. Silence there was the real risk: a reader seeing a pin behind a published
  release reaches for `allow-newer`, which is the one outcome the cohort discipline exists to
  prevent.

  Milestone 4 also gained a new obligation: file the two upstream release requests (`keiro 0.12`,
  and a kioku admitting `baikai ^>=0.5`). Four plans — 17, 48, 51, and 52 — wait on them, and no
  other plan in the portfolio surfaces the need.
