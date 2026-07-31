---
id: 47
slug: upgrade-shikigami-to-the-coherent-july-2026-dependency-cohort
title: "Upgrade Shikigami to the coherent July 2026 dependency cohort"
kind: exec-plan
created_at: 2026-07-30T14:33:07Z
master_plan: "docs/masterplans/2-production-reality-de-stub-the-runtime-behavior-and-integration-path.md"
---

# Upgrade Shikigami to the coherent July 2026 dependency cohort

This ExecPlan is a living document. The sections Progress, Surprises & Discoveries,
Decision Log, and Outcomes & Retrospective must be kept up to date as work proceeds.


## Purpose / Big Picture

Shikigami currently builds against a copied, commit-pinned dependency cohort that predates
major releases across Keiki, Keiro, Kioku, Shikumi, Baikai, Shibuya, PGMQ, Kiroku, and the
OpenTelemetry packages. After this plan, every co-developed dependency is selected from one
verified release matrix, the application compiles against the released APIs, old wire data has
explicit compatibility evidence, and `cabal build all` plus the repository test suites pass
without relying on arbitrary pre-release commits.

The visible proof is a checked-in release matrix, a dependency-resolution test, replay and queue
codec compatibility tests, and a complete build/test transcript. This plan deliberately does not
perform the durable Codd-ledger import: plan 38 owns that database cutover. It does, however,
update the migration package APIs far enough that plan 38 can land without carrying a second set
of dependency pins.


## Progress

- [x] (2026-07-31T03:46:15Z) M0: Kioku `v0.2.0.0` was published for the Keiki 0.4 /
      Keiro 0.4 cohort. The tag resolves to
      `5765f98add2a87a356c70793a6ba54375ef5feec`, and `kioku-api`,
      `kioku-core`, `kioku-migrations`, `kioku-cli`, and `kioku-migrate` are
      present on Hackage at `0.2.0.0`.
- [ ] M1: Add `docs/dependency-cohort.md` with registry, upstream-tag, package-bound, and API
      compatibility evidence for every upgraded package.
- [ ] M2: Replace the copied dependency block in `cabal.project` with the verified release cohort;
      remove obsolete Codd/hasql-migration pins only when plan 38's replacement is present.
- [ ] M3: Port configuration, provider, worker, storage, queue, tracing, and migration composition
      call sites to the released APIs.
- [ ] M4: Add compatibility fixtures for Keiro workflow state and queue envelopes, Kioku session
      access, SinkIntent JSON, and Shibuya/PGMQ attempt numbering.
- [ ] M5: Run the full build, unit/integration suites, migration smoke, and clean re-run; record the
      resolved versions and transcript.


## Surprises & Discoveries

- Kioku `v0.2.0.0` resolves the cohort incompatibility recorded during the
  2026-07-30 audit. `kioku-core-0.2.0.0` bounds `keiki ^>=0.4.0.0`,
  `keiro ^>=0.4.0.1`, and `keiro-core ^>=0.4.0.1`;
  `kioku-migrations-0.2.0.0` bounds `keiro-migrations ^>=0.4.0.1`. The
  completed upstream request is
  `mori://shinzui/kioku/docs/improvement-requests/release-kioku-for-keiki-0-4-and-keiro-0-4.md`.
  Plan 47 now waits only for plans 36 and 37, not for upstream release work.
- Keiro 0.4 queue payloads use generated codec envelopes. Shikigami's existing bare payloads need
  either a drain-before-cutover rule or an explicitly bounded transitional decoder; silently
  changing the decoder would strand or misinterpret queued work.
- `shibuya-pgmq-adapter-0.12.0.0` already converts PGMQ's one-based `read_count` into the
  zero-based `Message.attempt`. Shikigami must not subtract one again.
- Baikai 0.4 hides direct `Options` and `Context` construction and reports provider failure in-band
  through the response. The port must use `emptyOptions`/`emptyContext` and translate
  `Response.errorInfo`/`isRetryable` into Shikigami's retry taxonomy.
- Shibuya 0.8 handlers receive `Message es msg`, `runApp` takes `AppConfig`, and ordering is
  represented by `OrderingPolicy`. Its internal acknowledgement handle is not an application API.


## Decision Log

- Decision: Upgrade one coherent dependency cohort rather than bumping libraries independently.
  Rationale: Kioku, Keiki, Keiro, Kiroku, Shibuya, and PGMQ share bounds, persisted data, and
  runtime protocols; independent bumps can compile partially while producing an invalid solver or
  an unsafe replay/queue transition.
  Date: 2026-07-30
- Decision: Plan 37 lands before this plan and owns Settei's typed application configuration;
  this plan verifies Settei 0.2 compatibility but does not introduce a competing config layer.
  Rationale: configuration ownership must be settled before porting every executable, and the
  upgrade should not preserve raw `getEnv`/`lookupEnv` call sites as temporary compatibility code.
  Date: 2026-07-30
- Decision: Plan 47 owns package selection and application API ports; plan 38 owns the durable
  Codd-to-pg-migrate ledger import and final operational cutover.
  Rationale: one plan must keep the dependency solver and application build coherent, while the
  data migration needs its own rollback, fixture, and deployment proof.
  Date: 2026-07-30
- Decision: Use released tags and Hackage bounds as the selection contract, then pin the exact tag
  commits in `cabal.project` where source-repository packages remain necessary.
  Rationale: readable release identities make the cohort auditable; exact commits retain
  reproducibility. Arbitrary branch commits are not accepted as a finished state.
  Date: 2026-07-30
- Decision: Accept Kioku `v0.2.0.0` as the cohort release and close M0.
  Rationale: all five Kioku packages are published at `0.2.0.0`; the released
  cabal bounds admit Keiki 0.4 and Keiro 0.4 without `allow-newer`; the release
  includes pre-upgrade event-payload compatibility coverage and the current
  pg-migrate component.
  Date: 2026-07-30


## Outcomes & Retrospective

The external release prerequisite is complete: Kioku `v0.2.0.0` is the
reproducible cohort member, so implementation can proceed after plans 36 and 37.
M1–M5 remain unimplemented.


## Context and Orientation

`cabal.project` currently contains a block copied from an older Kioku project file. It pins raw
commits for Kioku, Keiki, Keiro, Shikumi, Kiroku, Shibuya, PGMQ, Baikai, and their adapters, and it
also pins Codd and hasql-migration. The four local packages are `shikigami-api`,
`shikigami-core`, `shikigami-cli`, and `shikigami-migrations`; plan 36 will expand this into the
fleet's six-package service shape before the port begins.

The target matrix verified on 2026-07-30 is:

| Project/package family | Target release | Principal application changes |
|---|---:|---|
| Settei | 0.2.0.0 | Typed process config from plan 37; env/yaml/CLI sources, no Kubernetes layer |
| Keiki | 0.4.0.0 | Validated structural model and codec compatibility used by Keiro 0.4 |
| Keiro | 0.4.0.1 | state-shape hashes, checked declarations, queue envelopes, timer/child APIs, lease heartbeat |
| Kioku | 0.2.0.0 | Bounds Keiki 0.4 / Keiro 0.4, retains the connection-settings path, adds codec compatibility coverage, and composes migrations through pg-migrate |
| Shikumi | 0.3.0.1 | explicit `Validatable`, strict schema decoding, multi-call ReAct, Baikai 0.4 family |
| Baikai | 0.4.1.0 | smart constructors for options/context and in-band provider errors |
| Shibuya | 0.8.0.1 | `AppConfig`, `Message`, `OrderingPolicy`, public stop/wait/metrics surface |
| shibuya-pgmq-adapter | 0.12.0.0 | already-normalized zero-based delivery attempt |
| PGMQ Haskell packages | 0.4.0.1 | pg-migrate component replaces the legacy migration path |
| Kiroku store | 0.3.1.0 | application/store resources and pg-migrate composition |
| shibuya-kiroku-adapter | 0.4.0.0 | current Kiroku/Shibuya adapter contract |
| pg-migrate | 1.1.0.0 | manifest/component runner and test support consumed by plan 38 |
| hs-opentelemetry family | 1.0.0.0 | current tracer/provider/exporter APIs consumed by plan 28 |

Mori is the source-navigation mechanism for all of these projects. Before changing code, run
`mori registry show <qualified-project> --full`, `mori registry docs <qualified-project>`, and
read the package source at the reported path. The local corpus may lag releases, so also compare
the Hackage `preferred.json`, package cabal bounds, and upstream release tag before fixing a
version or workaround. Never use `/nix/store` as dependency source.

The main application seams are:

- `shikigami-core/src/Shikigami/Agent/Workflow.hs` and
  `shikigami-core/src/Shikigami/Agent/Conversation.hs`: Keiro workflow state, timer, child, queue,
  and continue-as-new APIs.
- `shikigami-core/src/Shikigami/Behavior/Run.hs`: Baikai/Shikumi request construction and error
  translation.
- `shikigami-core/src/Shikigami/Worker.hs`: Shibuya 0.8 app construction, message handling,
  shutdown, metrics, and PGMQ attempt semantics.
- `shikigami-core/src/Shikigami/Memory.hs` and the Kioku call sites: connection settings, session
  and memory stores, and migration resources.
- `shikigami-migrations`: released pg-migrate component composition. Plan 38 owns the historical
  Codd-ledger import and removal of the legacy command path.
- `shikigami-core/src/Shikigami/Telemetry.hs`: hs-opentelemetry 1.0 provider/exporter lifecycle.


## Plan of Work

### Milestone 0 — confirm the released Kioku cohort member

This milestone is complete. Kioku `v0.2.0.0` is tagged at
`5765f98add2a87a356c70793a6ba54375ef5feec`, and all five packages are
published on Hackage at `0.2.0.0`. Preserve this evidence in
`docs/dependency-cohort.md` alongside every other chosen package, version, tag,
tag commit, Hackage revision, and direct bound between cohort members. Record
packages that remain on their current version and why. Reject a matrix that
needs `allow-newer` for a co-developed package.

### Milestone 1 — resolve and pin one build plan

Edit `cabal.project` so every repository appears at most once per tag commit, with the required
subdirectories collected in that stanza. Prefer Hackage releases when no local patch or
source-repository sibling selection is required. Keep tag names in comments beside exact commits.
Run a dry dependency solve and save the resolved cohort in the matrix document. Do not remove Codd
until plan 38's pg-migrate runner and ledger-compatibility fixture are in the same integration
branch.

### Milestone 2 — port application construction and failure semantics

Port the plan-37 configuration composition roots first. Replace Kioku's old `AppEnv { store = ... }`
construction with its released connection/resource contract. Use Baikai smart constructors and map
retryable in-band provider failures to the transient branch of plan 17's taxonomy. Construct
Shibuya through `AppConfig`, handle `Message` values through public fields only, and preserve
Shikigami's shutdown and health semantics without importing `Internal` modules.

### Milestone 3 — port durable and persisted protocols

Update every Keiro workflow definition with its explicit `stateShapeHash` and checked structural or
opaque declaration. Adopt the changed timer and child-failure signatures, lease heartbeat, and
generation-pinned timer behavior. Generate codec envelopes for Shikigami queues. Add a fixture made
with the pre-upgrade bare codec and either drain it before cutover or decode it through one named,
time-bounded compatibility codec. Prove old workflow state and SinkIntent JSON still decode before
removing a compatibility constructor or branch.

Update migration component imports so the application compiles with pg-migrate 1.1, Kiroku 0.3,
Keiro 0.4, and PGMQ 0.4. Keep plan 38's ledger import and deployment transition visibly separate.

### Milestone 4 — close the cohort with evidence

Run formatting, dependency solve, full build, package tests, database integration tests, queue codec
fixtures, replay fixtures, and the migration smoke. Run the build and migration smoke a second time
to prove idempotence. Add the final command transcript and exact resolved commits to
`docs/dependency-cohort.md`; delete superseded compatibility code only when its drain/retention exit
condition is met.


## Concrete Steps

Work from `/Users/shinzui/Keikaku/bokuno/shikigami`.

1. Re-resolve source and release metadata before editing:

       mori registry show shinzui/kioku --full
       mori registry docs shinzui/kioku
       mori registry show shinzui/keiro --full
       mori registry docs shinzui/keiro
       mori registry show shinzui/shibuya --full
       mori registry docs shinzui/shibuya

   Repeat for Keiki, Shikumi, Baikai, Kiroku, PGMQ, pg-migrate, Settei, and
   hs-opentelemetry. Compare the reported source with the authoritative Hackage metadata and
   upstream tag before recording the matrix.

2. Establish a green pre-upgrade baseline:

       nix develop --command cabal build all
       nix develop --command cabal test all

3. With M0 satisfied by Kioku `v0.2.0.0`, update one cohort and inspect the
   solver before porting:

       nix develop --command cabal build all --dry-run
       nix develop --command cabal freeze --dry-run

   The plan must show only the intended cohort and no `allow-newer` exception between
   co-developed packages.

4. Port in the milestone order, running the smallest affected package test after each seam. Then
   execute the full checks documented by the repository's `Justfile` and `flake.nix`.

5. With the plan-38 migration fixture present, run the canonical migration command twice against a
   fresh database and once against the imported legacy fixture. The second fresh run reports no
   pending migrations, and the imported fixture applies no already-recorded migration again.


## Validation and Acceptance

The plan is complete only when all of the following are observable:

1. `docs/dependency-cohort.md` names a released version and exact tag commit for every changed
   co-developed package and contains no unresolved compatibility row.
2. `cabal build all --dry-run` selects the documented matrix without a co-developed-package
   `allow-newer`; `cabal build all` and every package test succeed.
3. A fixture encoded by the old queue codec is either rejected with a documented drain gate or
   accepted by the named transitional decoder, while new queue values use the Keiro 0.4 envelope.
4. A pre-upgrade workflow-state fixture and SinkIntent JSON fixture decode to the same semantic
   values after the port.
5. PGMQ `read_count = 1` reaches the handler as attempt zero, proving there is no double
   normalization.
6. A retryable Baikai error enters the retry path and a terminal error does not; neither is treated
   as a successful model response.
7. The worker starts and stops through Shibuya's public 0.8 surface, and health/metrics do not import
   `Internal` modules.
8. The plan-38 migration smoke succeeds for both a fresh database and a legacy-ledger fixture and
   is idempotent on a second run.


## Idempotence and Recovery

Dependency-matrix discovery and dry solving are read-only and repeatable. Commit the upgrade in
milestone-sized changes so a failed API port can be reverted without discarding matrix evidence.
Keep old wire fixtures permanently. Keep a transitional decoder until its named queue-drain or
retention condition is proven; do not remove it because a fresh-database test passes.

The database transition follows plan 38's backup, ledger-import, and rollback procedure. Never
repair a production migration ledger by hand. If a released package proves incompatible after
pinning, restore the last green cohort as one unit, update the matrix with the failure evidence, and
open or revise an upstream improvement request instead of introducing an unbounded `allow-newer`.


## Interfaces and Dependencies

Hard prerequisites:

- `docs/plans/36-align-shikigami-with-the-six-package-deployed-service-architecture.md` defines the
  package and composition-root ownership used by every port.
- `docs/plans/37-adopt-settei-configuration-across-shikigami-binaries.md` defines the sole process
  configuration surface.

Resolved release input:

- Kioku `v0.2.0.0`, tag commit
  `5765f98add2a87a356c70793a6ba54375ef5feec`, supplies the released
  Keiki 0.4 / Keiro 0.4 compatible dependency and migration surface. Its
  improvement request is completed and is no longer a prerequisite.

Integration dependency:

- `docs/plans/38-migrate-shikigami-database-evolution-from-codd-to-pg-migrate.md` owns historical
  ledger import and the operational cutover. Its migration-runner changes and this plan's package
  pins must be tested together before either is considered shippable.

Downstream consumers:

- Plans 13–35 and 39–46 consume this cohort. They use current released APIs described in their
  2026-07-30 portfolio notes and must not reintroduce pre-upgrade constructors or raw environment
  access.
- Plan 39 consumes Keiro 0.4's checked DSL, structural/opaque declarations, state-shape hashes,
  codec comparison, goldens, and coverage gates.
- Plans 17, 19, 26, 29, and 34 additionally depend on the upstream seams tracked by the portfolio's
  improvement requests; plan 47 does not fake those seams locally.


## Revision Notes

- 2026-07-30: Recorded Kioku `v0.2.0.0`, completed M0, replaced the unresolved
  Kioku matrix row with its released bounds and tag commit, and removed Kioku
  IR-1 from the hard prerequisites. Plan 47 now follows only plans 36 and 37.
- 2026-07-30: Initial plan created from the unfinished-plan and dependency audit. The target matrix
  was verified against Mori-located source, Hackage releases, and upstream release tags. Kioku's
  incompatible released bounds were recorded as the sole hard release gate for the cohort.
