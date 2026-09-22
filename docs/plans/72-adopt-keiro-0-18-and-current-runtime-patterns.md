---
id: 72
slug: adopt-keiro-0-18-and-current-runtime-patterns
title: "Adopt Keiro 0.18 and current runtime patterns"
kind: exec-plan
created_at: 2026-09-22T03:15:38Z
intention: "intention_01m33ha9kmebxtmq7wsqrpxrp9"
provenance:
  created_by:
    model: "gpt-5.6-sol"
    harness: "codex-cli"
    at: 2026-09-22T03:15:38Z
---

# Adopt Keiro 0.18 and current runtime patterns

This ExecPlan is a living document. The sections Progress, Surprises & Discoveries,
Decision Log, and Outcomes & Retrospective must be kept up to date as work proceeds.
If durable project context changes, update or create ADRs in docs/adr/ in the same change.


## Purpose / Big Picture

Move Shikigami from the released Keiro 0.17 package family to the released 0.18 family without
changing its durable workflow, queue, event, or identifier contracts. After this work, every
Keiro package in the Cabal plan and the project-local `keiro-dsl` executable is 0.18.0.0, the
generated layer is reproducible with that toolchain, and the PostgreSQL-backed test fixture runs
with the new `ephemeral-pg` requirement. A developer can see the result by inspecting the Cabal
plan, running the strict Keiro gate, and running the full application and black-box test suites.

Keiro 0.18 also adds checked Language 6 mappings for bare containers, calendar days, text sets,
base16 bytes, and UUIDv5-or-v7 identifier admission. This plan evaluates those features against
Shikigami's actual declared surfaces. It deliberately does not turn a release upgrade into a
persisted-schema change: the present specification has no opaque mapped codec that these features
can replace, and its one declared TypeID is correctly v7-only. The applicability result and the
latest `keiro-runtime-patterns` guidance will be recorded as durable project evidence.


## Progress

- [x] (2026-09-21) Verified the Keiro 0.18.0.0 Hackage releases, upstream release tags, upgrade
  guide, current Shikigami dependency surfaces, generated ledger, relevant ADRs, workflow
  versioning rules, and the 2026-09-21 runtime-patterns revision.
- [ ] Milestone 1: select the released 0.18 cohort, update every explicit dependency constraint
  and Mori dependency declaration, and prove the solver selects the intended package set.
- [ ] Milestone 2: regenerate with `keiro-dsl` 0.18, prove the change is a tool-version restamp
  rather than a durable contract change, and retain only the justified hand-owned holes.
- [ ] Milestone 3: pass database-backed migration fixtures, behavior conformance, the full test
  suite, the black-box server suite, and the strict Keiro evolution gate.
- [ ] Milestone 4: record the 0.18 pattern delta, cohort and rollout facts, update the relevant
  ADR, perform the final ADR-distillation pass, and commit the qualification evidence.


## Surprises & Discoveries

- Keiro 0.18 changes no migration payload and does not move Keiki, Kiroku, Shibuya, PGMQ, or the
  PGMQ adapter to a new compatibility line. Its required consumer change in this repository is
  primarily generated-code and test-tooling alignment, not a database cutover. Evidence: the
  upstream 0.17-to-0.18 migration guide says no recorded checksum or ledger fixup changes.
- `keiro-test-support 0.18.0.0` requires `ephemeral-pg >=0.3.1 && <0.4`, while the released
  `pg-migrate-test-support 1.1.0.0` used by `shikigami-migrations-smoke` still declares
  `ephemeral-pg >=0.2 && <0.3`. The upstream guide authorizes exactly the scoped
  `pg-migrate-test-support:ephemeral-pg` relaxation for this pair; no broader solver override is
  justified.
- Shikigami imports `Keiro.Codec.IdDomain` only from generated modules, which use the smart
  constructor `typeIdV7Domain`. It neither constructs `IdDomainContract` positionally nor matches
  `IdDomainFailure`, so the widened 0.18 runtime type requires no hand-written source adaptation.
- The current DSL ledger lists three legitimate holes: the projection catalog's live handler,
  the read-model SQL implementation, and executed aggregate behavior witnesses. It lists no
  mapped consumer declaration. The new checked value policies therefore do not remove a current
  opaque codec hole.


## Decision Log

- Decision: Adopt all seven Keiro packages at 0.18.0.0 as one lockstep family, using Hackage
  releases and the common upstream release commit rather than a sibling checkout or Git override.
  Rationale: Hackage marks all seven releases normal, and the seven remote tags peel to
  `b12bbdd7abc8c1a59e7a09891471ef182a4d801a` in `mori://shinzui/keiro`.
  Date: 2026-09-21.
- Decision: Keep every `domain/*.keiro` member at Language 6, but do not introduce the new checked
  mappings or widen `RunEvidenceId` admission in this upgrade.
  Rationale: the 0.18 guide makes these opt-in schema decisions. Shikigami has no declared mapped
  codec to replace; its generated `RunEvidenceId` is allocated as TypeID-v7; and application
  UUIDv5 values are technical workflow/deduplication identities rather than this declared TypeID
  domain. Changing queue field bindings or ID admission would add replay and drain obligations
  unrelated to adopting the release.
  Date: 2026-09-21.
- Decision: Preserve the three existing hand-owned holes and reassess them by capability rather
  than by raw hole count.
  Rationale: SQL execution, a live-only rich-evidence handler, and executed conformance witnesses
  are application responsibilities that Keiro 0.18 does not generate. The current
  runtime-patterns standard explicitly says zero holes is not equivalent to correctness.
  Date: 2026-09-21.
- Decision: Treat the prior `docs/operations/keiro-0.17-rollout.md` as historical cutover guidance
  and add a separate 0.18 rollout note instead of rewriting it.
  Rationale: migration 0032's stop-the-writers procedure remains true for a 0.15-to-0.17 crossing,
  while 0.17-to-0.18 adds no migration and needs no such cutover.
  Date: 2026-09-21.


## Outcomes & Retrospective

(To be filled during and after implementation.)


## Context and Orientation

Shikigami is a seven-package Haskell service. A dependency **cohort** is the set of released
package versions that Cabal must solve together. `cabal.project` selects the Hackage snapshot,
adds the build-time `keiro-dsl` executable as an extra package, and pins that tool to 0.17.0.0.
Runtime bounds appear in `shikigami-core/shikigami-core.cabal`,
`shikigami-migrations/shikigami-migrations.cabal`, and
`shikigami-server/shikigami-server.cabal`; unbounded direct Keiro dependencies in other package
files are constrained transitively by the lockstep package family. `mori.dhall` repeats five
explicit 0.17 constraints as registry metadata. `docs/dependency-cohort.md` is the human-readable
record of what the solver selected.

The checked durable specification is `domain/shikigami.keiro-workspace`, composing five
`domain/*.keiro` members. Every member explicitly declares candidate Language 6. The generated
Haskell, Cabal fragment, scaffold ledger, and conformance package live under
`shikigami-core/src/`; their banners currently name `keiro-dsl 0.17.0.0`. `Justfile` defines
`keiro-check`, `keiro-inspect`, `keiro-scaffold`, `keiro-diff`, and the composed `keiro-gate`.
The gate denies warnings, refuses opaque-boundary growth, checks deterministic regeneration,
classifies compatibility across six durable surfaces, emits replay impact, and runs the generated
conformance package.

The only DSL-declared identifier is `RunEvidenceId` in
`domain/shikigami-run-evidence.keiro`. The generated modules
`shikigami-core/src/Shikigami/Generated/Nominals.hs` and
`shikigami-core/src/Shikigami/Generated/Nominals/Internal.hs` use `typeIdV7Domain`; hand-written
code does not construct or destructure Keiro's ID-domain runtime types. The generated queue in
`domain/shikigami-run-jobs.keiro` owns primitive, optional, list, JSON, and time fields, and
`Shikigami.RunJobs` validates them into richer application types. This is a real runtime
adapter, not an opaque mapped DSL codec. Byte strings, sets, hexadecimal values, and UUIDv5 values
elsewhere in `shikigami-core/src/` do not occur on a declared mapped persisted surface.

`shikigami-migrations/shikigami-migrations.cabal` links both
`keiro-test-support ^>=0.17.0.0` and `pg-migrate-test-support ^>=1.1.0.0` in different test
components. Keiro 0.18 raises the former's `ephemeral-pg` floor to 0.3.1; the latter's Hackage
metadata still caps it below 0.3. The exact exception belongs in `cabal.project`, alongside the
unrelated existing `claude:http-client-tls` exception. The resulting fixture starts PostgreSQL
under `/tmp/ephpg-keiro-<uid>`, so the database-backed suite is required acceptance evidence.

The relevant local decisions are [ADR 0001](../adr/0001-declare-only-what-the-runtime-executes.md),
which forbids declaring a generated contract the runtime does not execute; [ADR 0002](../adr/0002-generated-code-is-not-formatted.md),
which keeps formatters away from generated output; [ADR 0012](../adr/0012-a-declared-workflow-body-only-grows-behind-a-patch.md),
which requires patch guards for workflow-body growth; [ADR 0037](../adr/0037-adopt-the-released-keiro-contracts-before-v1.md),
which owns released Keiro and DSL adoption; and [ADR 0038](../adr/0038-runtime-startup-and-maintenance-share-validated-owners.md),
which owns migration verification, runtime registries, timer recovery, and maintenance bounds.
`docs/workflow-versioning.md` is also normative. Because this upgrade changes no workflow body,
step label, result type, queue envelope, or ID admission, it needs no new patch ID or
`continueAsNew` branch. ADR 0037 should receive the 0.18 adoption amendment; ADR 0038 remains
unchanged unless implementation discovers a runtime ownership change.

Mori resolves Keiro as `mori://shinzui/keiro` and its public packages as
`mori://shinzui/keiro/packages/keiro`, `mori://shinzui/keiro/packages/keiro-core`,
`mori://shinzui/keiro/packages/keiro-dsl`, `mori://shinzui/keiro/packages/keiro-migrations`,
`mori://shinzui/keiro/packages/keiro-ops`, `mori://shinzui/keiro/packages/keiro-pgmq`, and
`mori://shinzui/keiro/packages/keiro-test-support`. The applicable current guidance is
`mori://shinzui/keiro-runtime-patterns/docs/keiro-dsl-adoption`,
`mori://shinzui/keiro-runtime-patterns/docs/keiro-mapped-consumer-surfaces`,
`mori://shinzui/keiro-runtime-patterns/docs/keiro-identifier-domains`,
`mori://shinzui/keiro-runtime-patterns/docs/keiro-behavior-conformance`, and
`mori://shinzui/keiro-runtime-patterns/docs/migrations-testing`. Research used runtime-patterns
commit `24e4e61075ccc323cc1b443775963805b7059bee` from 2026-09-21.


## Plan of Work

### Milestone 1 — Resolve one released Keiro 0.18 cohort

Record the pre-change Git revision, refresh the Hackage index, and replace the pinned
`index-state` in `cabal.project` with an exact UTC snapshot at or after the 0.18 publication that
contains all seven releases. Change `keiro-dsl ==0.17.0.0` to 0.18.0.0. Convert the existing
one-line `allow-newer` field into a two-entry field containing only
`claude:http-client-tls` and `pg-migrate-test-support:ephemeral-pg`; do not add a general package
or version wildcard.

Raise every explicit Keiro bound in `shikigami-core/shikigami-core.cabal`,
`shikigami-migrations/shikigami-migrations.cabal`, and
`shikigami-server/shikigami-server.cabal` from 0.17.0.0 to 0.18.0.0. Make the same five metadata
changes in `mori.dhall`. Leave Keiki 0.9, Kiroku Store 0.8 and migrations 0.4, Kioku 0.7, PGMQ
0.6, and the 0.16 PGMQ adapter on their compatible release lines. Do not force pg-migrate 1.2 or
Kiroku migrations 0.5 into the plan: Keiro 0.18 still targets pg-migrate 1.1 and Kiroku
migrations 0.4.

Resolve and inspect the Cabal plan. All seven Keiro packages must be exactly 0.18.0.0;
`ephemeral-pg` must be 0.3.1.0; and `pg-migrate-test-support` remains 1.1.0.0 under the one scoped
relaxation. The refreshed compatible patch set should include Kiroku Store 0.8.0.1,
Shibuya Core/Metrics 0.9.0.3, and `shibuya-kiroku-adapter` 0.5.1.2 if they are in the application
plan. If the solver requires any other `allow-newer`, source checkout, or unpublished package,
stop and record the conflict instead of widening policy. Milestone acceptance is a reproducible
dry-run whose resolved versions match this contract.

### Milestone 2 — Regenerate without changing durable meaning

Run the 0.18 scaffolder directly over `domain/shikigami.keiro-workspace` and review every changed
file under `shikigami-core/src/`. With the current specification, the upstream migration guide
predicts only 0.17-to-0.18 provenance-banner restamps, including the generated conformance
package. No `domain/*.keiro` source, generated type shape, codec body, queue policy, workflow
inventory, behavior key, fold fingerprint, or ledger semantic row should change. Do not format
the generated output.

Run `check --explain-bindings`, coverage, `behavior-obligations`, and the compatibility diff
against the recorded baseline. Record the applicability census in a new concise
`docs/architecture/keiro-0.18-pattern-adoption.md`: the checked bare-container/date/set/base16
policies are not used because no current mapped declaration matches them; v5-or-v7 admission is
not used because `RunEvidenceId` is v7-only; and the three hand-owned holes remain SQL, live-only
projection, and witness obligations. The report must also note that `Shikigami.RunEvidence.Conformance`
already gates all required obligations and preserves honest unverified identity/register equality
guards. An unexpected generated semantic diff is a discovery that must be investigated and added
to this plan before proceeding. Milestone acceptance is a clean semantic diff and a second
scaffold that produces no tracked changes.

### Milestone 3 — Exercise the changed runtime and test fixture

Build all components and run every test component, including the optional generated conformance
package. Run the migration smoke suite explicitly so success proves that the reconciled
`ephemeral-pg` 0.3.1 fixture can start, migrate a template, clone isolated databases, and clean up.
Run the strict Keiro gate against the recorded pre-upgrade revision; its diff and replay-impact
reports must contain no breaking or replay-affecting contract change. Run migration schema
isolation and the disposable Hurl suite so the server starts against a fresh database and serves
its public health/problem contracts on the new runtime.

No production database migration is added in this milestone. Existing migration tests must show
that the complete Keiro/Kiroku/Kioku/Shikigami plan remains valid and idempotent, and a current
ledger verifies successfully. Milestone acceptance is successful execution—not merely
compilation—of the PostgreSQL fixture, generated behavior conformance, workflow/queue suites, and
black-box HTTP checks.

### Milestone 4 — Make the release and rollout record durable

Update `docs/dependency-cohort.md` so its current target, Hackage evidence, tag commit, selected
patch releases, scoped solver exception, and reproduction commands describe 0.18 rather than
0.17. Update `docs/architecture/shikigami-domain-inventory.md` to name Keiro 0.18 and explain why
the new checked mappings and widened ID admission are absent. Add
`docs/operations/keiro-0.18-rollout.md` for the actual 0.17-to-0.18 path: verify migrations, deploy
the lockstep binaries, and permit ordinary binary rollback because this plan writes no new
workflow shape, wire policy, ID domain, or migration. Direct readers starting before 0.17 to the
existing `docs/operations/keiro-0.17-rollout.md` guarded-timer cutover first.

Append a Keiro 0.18 amendment to `docs/adr/0037-adopt-the-released-keiro-contracts-before-v1.md`
that records the release family, banner-only DSL regeneration, mapping/admission exclusions, and
scoped test dependency exception. Preserve the filesystem ADR convention discovered by
`mori show --full`; `docs/adr` is not a profiled OKF bundle. During the final distillation pass,
update ADR 0038 only if implementation actually changes runtime ownership or rollout semantics.
Record concise command outputs and resolved versions in `docs/evidence/keiro-0.18/qualification.md`.
Milestone acceptance is agreement among the Cabal plan, generated artifacts, dependency record,
pattern record, rollout note, ADR, and qualification evidence.


## Concrete Steps

Run every command from `/Users/shinzui/Keikaku/bokuno/shikigami` (or the root of a clean checkout
of this repository). Start clean and retain the baseline revision for `keiro-dsl diff`:

```bash
git status --short
BASELINE_SHA="$(git rev-parse HEAD)"
printf '%s\n' "$BASELINE_SHA"
mori registry show shinzui/keiro --full
mori registry docs shinzui/keiro-runtime-patterns
cabal update
```

After editing the dependency files, resolve without building and inspect the package versions.
`cabal update` prints the current secure-index state; replace `HEAD` with that exact UTC timestamp
in `cabal.project` before committing.

```bash
nix develop --command cabal build all --dry-run --index-state=HEAD
nix develop --command cabal build all --dry-run
jq -r '."install-plan"[] | select(."pkg-name" | test("^(keiro|keiro-core|keiro-dsl|keiro-migrations|keiro-ops|keiro-pgmq|keiro-test-support|ephemeral-pg|pg-migrate-test-support|kiroku-store|shibuya-core|shibuya-metrics|shibuya-kiroku-adapter)$")) | [."pkg-name", ."pkg-version"] | @tsv' dist-newstyle/cache/plan.json | sort
mori show --full
```

The relevant portion of the version report must include:

```text
ephemeral-pg	0.3.1.0
keiro	0.18.0.0
keiro-core	0.18.0.0
keiro-dsl	0.18.0.0
keiro-migrations	0.18.0.0
keiro-ops	0.18.0.0
keiro-pgmq	0.18.0.0
keiro-test-support	0.18.0.0
pg-migrate-test-support	1.1.0.0
```

Regenerate once, inspect the diff, then run the semantic checks. The direct scaffold is expected
to change tracked generated files on its first run; `just keiro-scaffold` later proves that the
committed result is deterministic.

```bash
nix develop --command cabal run -v0 keiro-dsl -- scaffold domain/shikigami.keiro-workspace --out shikigami-core/src
git diff -- domain shikigami-core/src
just keiro-check
just keiro-inspect
nix develop --command cabal run -v0 keiro-dsl -- behavior-obligations domain/shikigami.keiro-workspace --format=json
just keiro-diff "$BASELINE_SHA"
```

Build and exercise all relevant behavior after the generated output and dependency edits agree:

```bash
nix develop --command cabal build all --enable-tests
nix develop --command cabal test shikigami-migrations:shikigami-migrations-smoke --test-show-details=direct
nix develop --command cabal test keiro-shikigami-conformance --test-show-details=direct
nix develop --command cabal test all --test-show-details=direct
just migration-schema-isolation
just keiro-gate "$BASELINE_SHA"
bash tests/hurl/run.sh
```

Run the documentation and final drift checks after updating the durable records:

```bash
just keiro-scaffold
git diff --check
git status --short
```

Commit in working checkpoints. Every commit uses Conventional Commits and both active trailers;
for example:

```text
build(deps): adopt the Keiro 0.18 cohort

Align the released runtime, DSL-generated layer, and test fixture dependency.

ExecPlan: docs/plans/72-adopt-keiro-0-18-and-current-runtime-patterns.md
Intention: intention_01m33ha9kmebxtmq7wsqrpxrp9
```


## Validation and Acceptance

Acceptance requires all of the following observable results.

The resolved Cabal plan reports all seven Keiro packages at 0.18.0.0 from Hackage, with no Keiro
source override and only the two named `allow-newer` exceptions. Mori reports 0.18 constraints
for each Shikigami package that carries an explicit Keiro bound. `docs/dependency-cohort.md`
matches the actual plan and identifies upstream release commit
`b12bbdd7abc8c1a59e7a09891471ef182a4d801a`.

Every generated banner and the generated conformance package report `keiro-dsl 0.18.0.0`.
`just keiro-check` and `just keiro-inspect` exit zero, all five members remain explicitly declared
at candidate Language 6, and coverage reports no new opaque persisted root. The compatibility
report contains no breaking finding, the replay-impact report is neutral, and a repeated
`just keiro-scaffold` leaves no diff. No workflow patch ID, queue drain, upcaster, ID-domain
change, or migration is introduced merely to adopt the release.

`Shikigami.RunEvidence.Conformance` still reports no pending, missing, duplicate, stale, or failed
behavior key. All total generated guards remain verified; the six identity/register equality
guards may remain honestly unverified under the existing policy. The generated conformance test
and full application suite exit zero.

The explicit migration smoke suite starts PostgreSQL with `ephemeral-pg` 0.3.1, applies the
complete migration plan, proves a second application is a no-op, exercises isolation and cleanup,
and exits zero. No new Keiro migration appears. The Hurl runner starts a disposable server and
database and reports its health and problem-detail requests passing, demonstrating that the
upgraded runtime boots and serves behavior rather than only compiling.

The 0.18 pattern record gives a concrete disposition for every runtime-patterns change since the
0.17 review. The rollout note distinguishes a direct 0.17-to-0.18 binary upgrade from the older
guarded-timer schema cutover. ADR 0037, the domain inventory, the cohort document, and the
qualification evidence agree with the code.


## Idempotence and Recovery

Dependency resolution, checking, inspection, behavior inventory, and scaffolding are safe to
repeat. The scaffolder never deletes stale files; inspect its report and remove a stale generated
path only after confirming ownership. Never hand-edit or format a generated module. If the first
scaffold produces more than version-banner or tool-provenance changes, restore only those newly
generated edits with a reviewed patch or re-run from a clean worktree after documenting the
semantic delta; do not weaken `keiro-check`, `keiro-diff`, or coverage gates.

The scoped `allow-newer` is temporary metadata reconciliation. If a later Hackage revision of
`pg-migrate-test-support 1.1.0.0` widens its `ephemeral-pg` bound before implementation, remove
the exception and record the authoritative revision instead. If 1.1.0.0 still has the old bound,
retain exactly the scoped exception and prove the smoke suite. Do not solve failure by upgrading
pg-migrate or Kiroku migrations outside Keiro 0.18's admitted cohort.

All database acceptance uses disposable fixtures. Keiro 0.18 adds no migration payload, so there
is no production ledger rollback or data rewrite in this plan. Before any deployment, run the
read-only migration verification from the 0.18 rollout note. Because the plan intentionally keeps
wire bytes, workflow shapes, and ID admission unchanged, a direct binary rollback to the qualified
0.17 release is available. A future optional mapping or admission change must receive its own
plan, fixtures, diff evidence, drain/replay decision, and rollout boundary.


## Interfaces and Dependencies

The release unit is `keiro`, `keiro-core`, `keiro-dsl`, `keiro-migrations`, `keiro-ops`,
`keiro-pgmq`, and `keiro-test-support`, all at 0.18.0.0. Keiro's unchanged compatible substrate is
Keiki 0.9, Kiroku Store 0.8 with Kiroku migrations 0.4, Shibuya 0.9, PGMQ 0.6, and
`shibuya-pgmq-adapter` 0.16. The project-local DSL executable remains an `extra-packages` tool in
`cabal.project`, not a linked application library.

Keiro 0.18 widens `Keiro.Codec.IdDomain.IdDomainContract` with `idDomainAdmission`, widens
`IdDomainFailure`, and adds `typeIdV5OrV7Domain`. Shikigami's only callers remain generated code
using `typeIdV7Domain`; no new hand-written import or compatibility shim should appear. Keiro 0.18
also widens public `keiro-dsl` AST types, but Shikigami executes the tool and does not import its
library, so there is no exhaustive pattern match to adapt.

`Keiro.Test.Postgres` remains the fixture boundary used by
`Shikigami.Migrations.TestSupport`. Its 0.18 implementation owns the stable per-user temporary
root and requires `ephemeral-pg` 0.3.1. The old `Database.PostgreSQL.Migrate.Test` dependency is
kept only for `shikigami-migrations-smoke`; the Cabal-project relaxation reconciles their
compatible use of the same `Config` API.

The DSL-generated runtime interfaces remain byte- and type-compatible with the 0.17 Shikigami
specification: `Shikigami.RunJobs.Generated.QueueCodec` owns the schema-version-1 queue envelope,
`Shikigami.RunEvidence.Generated.*` owns the event codec and transducer,
`Shikigami.AgentRun.Generated.WorkflowRuntime`,
`Shikigami.Approval.Generated.WorkflowRuntime`, and
`Shikigami.DanwaConversation.Generated.WorkflowRuntime` own stable workflow facts, and
`Shikigami.RunEvidence.Conformance` owns the application-facing behavior gate. The expected
implementation changes their generated provenance, not these interfaces or their durable values.
