# Dependency cohort — August 2026

Shikigami builds against **one** coherent set of co-developed releases. This
document is the contract: it names the released version of every co-developed
package, the upstream tag and tag commit that produced it, and the evidence that
the cohort holds together. `cabal.project` encodes the same set as a
`constraints:` block, so a drift between this table and the solver is a bug in
one of them.

Two rules govern changes:

1. **Released versions only.** A co-developed dependency is selected by Hackage
   version. A `source-repository-package` stanza is admissible only for a package
   with no Hackage release, or for a fork we deliberately carry; each such stanza
   carries a comment saying which case it is and when it retires.
2. **No `allow-newer` between co-developed packages.** If two cohort members
   cannot agree, the fix is an upstream release, not a solver override. The one
   `allow-newer` in `cabal.project` (`haxl:time`) is a third-party bound and
   predates this cohort.

Regenerate the resolved-version evidence with:

```bash
nix develop --command cabal build all --dry-run
```

All builds and tests must run inside the Nix dev shell; a bare `cabal build all`
compiles and then fails at link with `ld: library not found for -lrdkafka`.


## Upstream projects

The tag commits below live in these repositories. Use the canonical URI when
referring to them from anywhere durable.

| Family | Project |
|---|---|
| `keiki`, `keiki-codec-json` | `mori://shinzui/keiki` |
| `keiro*` | `mori://shinzui/keiro` |
| `kioku*` | `mori://shinzui/kioku` |
| `shikumi*` | `mori://shinzui/shikumi` |
| `baikai*` | `mori://shinzui/baikai` |
| `shibuya-core`, `shibuya-metrics` | `mori://shinzui/shibuya` |
| `shibuya-pgmq-adapter` | `mori://shinzui/shibuya-pgmq-adapter` |
| `kiroku-store*`, `shibuya-kiroku-adapter` | `mori://shinzui/kiroku` |
| `pgmq-*` | `mori://shinzui/pgmq-hs` |
| `pg-migrate*` | `mori://shinzui/pg-migrate` |
| `settei*` | `mori://shinzui/settei` |
| `servant-health` | `mori://shinzui/servant-health` |
| `ephemeral-pg` | `mori://shinzui/ephemeral-pg` |
| `handan-core` | `mori://shinzui/handan` |


## Release matrix

Every row below is resolved from Hackage. "Was" is the version this repository
pinned before the August 2026 upgrade (the July cohort recorded by plan 47).

| Package | Was | Now | Upstream tag | Tag commit |
|---|---|---|---|---|
| `keiki` | 0.4.0.0 | **0.9.0.0** | `v0.9.0.0` | `9714d37033c37595e3aaa3319ca0ca77466782e0` |
| `keiki-codec-json` | 0.4.0.0 | **0.9.0.0** | `v0.9.0.0` | `9714d37033c37595e3aaa3319ca0ca77466782e0` |
| `keiro` | 0.4.0.1 | **0.13.0.0** | `keiro-0.13.0.0` | `1eef4b2f5323c419050f3584a0969a0c4f1c9308` |
| `keiro-core` | 0.4.0.1 | **0.13.0.0** | `keiro-core-0.13.0.0` | `1eef4b2f5323c419050f3584a0969a0c4f1c9308` |
| `keiro-dsl` | — | **0.13.0.0** | `keiro-dsl-0.13.0.0` | `1eef4b2f5323c419050f3584a0969a0c4f1c9308` |
| `keiro-migrations` | 0.4.0.1 | **0.13.0.0** | `keiro-migrations-0.13.0.0` | `1eef4b2f5323c419050f3584a0969a0c4f1c9308` |
| `kioku-api` | 0.2.0.0 | **0.4.1.0** | `v0.4.1.0` | `bb141a7599e5a20c2840ab5702784aa41049c2fc` |
| `kioku-core` | 0.2.0.0 | **0.4.1.0** | `v0.4.1.0` | `bb141a7599e5a20c2840ab5702784aa41049c2fc` |
| `kioku-migrations` | 0.2.0.0 | **0.4.1.0** | `v0.4.1.0` | `bb141a7599e5a20c2840ab5702784aa41049c2fc` |
| `shikumi` | 0.3.0.1 | **0.3.0.2** | `shikumi-0.3.0.2` | `5e3680e52608d7e88698fa9485f78619853ced98` |
| `baikai` | 0.4.1.0 | **0.5.0.0** | `baikai-0.5.0.0` | `d6c57d3c70096711231420cfb1f801d6ee600fdc` |
| `baikai-claude` | 0.4.0.1 | **0.5.0.0** | `baikai-claude-0.5.0.0` | `d6c57d3c70096711231420cfb1f801d6ee600fdc` |
| `baikai-effectful` | 0.3.0.2 | **0.3.0.3** | `baikai-effectful-0.3.0.3` | `d6c57d3c70096711231420cfb1f801d6ee600fdc` |
| `shibuya-core` | 0.8.0.1 | **0.9.0.0** | `v0.9.0.0` | `d958a5748475a4b84075feda7a2a4f5cc7471c60` |
| `shibuya-pgmq-adapter` | 0.12.0.0 | **0.14.0.0** | `v0.14.0.0` | `301652375ecdec01c4e1ff50902900ad3a078ea3` |
| `shibuya-kiroku-adapter` | 0.4.0.0 | **0.5.1.1** | `shibuya-kiroku-adapter-v0.5.1.1` | `7726d23028cd4edfba69762edf659485b9547da4` |
| `kiroku-store` | 0.3.1.0 | **0.8.0.0** | `kiroku-store-v0.8.0.0` | `7726d23028cd4edfba69762edf659485b9547da4` |
| `kiroku-store-migrations` | 0.3.0.0 | **0.4.0.0** | `kiroku-store-migrations-v0.4.0.0` | `7c8f2dac48c077427834650aa6e76d0682712809` |
| `pgmq-core` / `-hasql` / `-effectful` | 0.4.0.1 | **0.5.0.0** | `v0.5.0.0` | `fc13d7a432dbc0cf0ad4cd3616e5d7d28fdf5abe` |
| `pg-migrate` (+ `-cli`, `-embed`, `-test-support`) | 1.1.0.0 | 1.1.0.0 | `v1.1.0.0` | `f39d64e354818999667d345a1452f33eb4857fc1` |
| `settei` (+ `-env`, `-yaml`, `-optparse-applicative`) | 0.2.0.0 | 0.2.0.0 | `v0.2.0.0` | `1bf62b0af110b4f42fe2528e9d459e0ccf12d626` |
| `hs-opentelemetry-*` | 1.0.0.0 | 1.0.0.0 | Hackage (third party) | — |

Two constraints left the block rather than moving: `keiro-pgmq` and `pgmq-migration`
resolve into nothing now that kioku composes its migrations through `pg-migrate`.
Neither appears in `cabal build all --dry-run`, so pinning them pinned nothing.

`keiro-dsl` is new to this cohort and is the one row that is not a library this
service links against. It is the build-time specification toolchain that checks
`domain/shikigami.keiro-workspace` and scaffolds `shikigami-core/src`, so it is
declared as `extra-packages: keiro-dsl` in `cabal.project` rather than as a
`build-depends` of any component. `extra-packages` makes the solver treat a
Hackage package as if it were local, which is what lets `cabal run keiro-dsl --
check ...` resolve to the pinned version from inside this project instead of
depending on a developer's `PATH` or on a separate keiro checkout. The
`constraints:` row pins it to the same `0.13.0.0` as the runtime packages,
because the toolchain and the runtime move in lockstep: `keiro-dsl 0.13.0.0`
declares `keiro-core ^>=0.13.0.0` and `keiki >=0.9 && <0.10`, both of which this
cohort already satisfies. Adopted by
`docs/plans/39-adopt-a-checked-keiro-dsl-specification-and-evolution-gate.md`.

### Nothing is held back

This cohort has no exclusions. Every co-developed package is at its newest Hackage release,
and no `allow-newer` is used anywhere between them.

That was not true when the upgrade started. `kioku-core 0.4.0.0`'s library declared
`baikai ^>=0.4.1.0`, capping baikai below 0.5, which in turn pinned `shikumi` to `0.3.0.1`
(because `shikumi 0.3.0.2` requires `baikai >=0.5`) and `baikai-effectful` to `0.3.0.2`.
Three packages held by one bound.

`kioku 0.4.1.0` (2026-08-18) lifted it: the release moves kioku onto baikai 0.5, declaring
`baikai ^>=0.5.0.0`, `baikai-claude ^>=0.5.0.0`, `baikai-effectful ^>=0.3.0.3`,
`shikumi ^>=0.3.0.2`, and `shikumi-trace ^>=0.2.0.2`. Its keiro, keiki, kiroku, and shibuya
bounds are unchanged from 0.4.0.0, and it adds no migration.

This is the outcome the cohort discipline is for. The bound was a true statement about which
baikai kioku had compiled against, so the fix was an upstream release rather than a solver
override — and when it arrived, taking it was a version bump and one compile error.

### The keiro 0.11 / keiki 0.9 gate, and how it cleared

The July cohort recorded this upgrade as blocked: `kioku-core 0.2.0.0` declared
`keiro ^>=0.4.0.1` and `keiki ^>=0.4.0.0`, both capped below the next major.

It cleared twice over. `kioku 0.3.0.0` (2026-08-05) was a bounds-only release admitting
keiki 0.9 / keiro 0.11, and `kioku 0.4.0.0` (2026-08-17) went further, declaring
`keiro ^>=0.13.0.0`, `kiroku-store ^>=0.8.0.0`, `shibuya-core ^>=0.9.0.0`, and
`shibuya-kiroku-adapter ^>=0.5.1.1`. That second release is what makes this cohort larger
than the one plan 53 was written against: `shibuya-core 0.9.0.0` and the kiroku 0.8 line
were excluded by keiro 0.11's own bounds and are admissible under keiro 0.13.

## Packages still resolved from Git

| Package | Reason | Retires when |
|---|---|---|
| `handan-core` | No Hackage release. Typed-program runtime behind `Shikigami.Behavior.Run` and `Shikigami.Program.Registry`. | Handan publishes. |
| `kafka-effectful` | No Hackage release. `activity.v1` stream consumer. | It publishes. |
| `danwa-core`, `danwa-api`, `danwa-client` | No Hackage release. Conversation substrate behind the `DanwaConversation` sink. | Danwa publishes. |

Schema evolution is pg-migrate throughout. The `codd`, `hasql-migration`, and
`hasql-notifications` forks this project once carried are gone, and so is the
`pg-migrate-import-codd` path that would have imported an existing codd ledger — plan 38
cancelled it on 2026-08-05 because no database needs its history preserved.


## Compatibility evidence

Each row states why the cohort member is safe to adopt, and where the proof lives.

| Concern | Evidence |
|---|---|
| Kioku pairs with the released Keiro/Keiki | `kioku-core-0.2.0.0` declares `keiki ^>=0.4.0.0`, `keiro ^>=0.4.0.1`, `keiro-core ^>=0.4.0.1`; `kioku-migrations-0.2.0.0` declares `keiro-migrations ^>=0.4.0.1`. The solver selects them with no `allow-newer`. |
| Kioku's own codec regression guard | Kioku 0.2.0.0 adds `Kioku.CodecCompatSpec`, which decodes literal pre-upgrade event payloads under the new cohort. |
| Keiro snapshot state-shape hash | `StateCodec` gains `stateShapeHash`; migration `0019-keiro-snapshots-state-shape-hash.sql` adds the column and existing rows take the empty sentinel, invalidating each snapshot exactly once on next hydration. Journals and events are untouched. |
| Keiro child failure reason | Migration `0020-keiro-workflow-children-failure-reason.sql` adds a nullable `failure_reason`; `markChildFailedTx` takes the reason as a third argument. |
| Keiro queue envelopes | Scaffolded workqueues gain a versioned `keiroJobCodec` envelope. Shikigami's queues are not scaffolded by `keiro-dsl` and continue to use their own payload codecs, so no in-flight message changes shape in this plan. Recorded as a live constraint for plan 39. |
| PGMQ delivery attempt numbering | `shibuya-pgmq-adapter-0.12.0.0` already converts PGMQ's one-based `read_count` into a zero-based `Message.attempt`. Shikigami must not subtract one again. |
| Shibuya 0.8 public surface | `runApp` takes `AppConfig`; handlers receive `Message es msg`; `Ordering` is renamed `OrderingPolicy`; runner internals moved under `Shibuya.Internal.*`. Shikigami uses only the public surface. |
| Baikai 0.4 | `ThinkingLevel` gains `ThinkingXHigh`/`ThinkingMax` and `InteractiveLaunchRequest` gains a defaulted `effort`; exhaustive matches must account for the widened sum. |
| Settei 0.2 | Unchanged by this plan; `docs/operations/configuration.md` remains the configuration contract. |

## Compatibility fixtures

Three suites hold the cohort to the claims above. They are the reason a future
bump cannot quietly change a persisted byte.

| What it pins | Where |
|---|---|
| Pre-upgrade `RunJob` queue payloads, `SinkIntent` and `SinkResult` outbox JSON (including the deprecated `Stubbed` outcome), and PGMQ's zero-based attempt | `shikigami-core/test/Shikigami/WireCompatSpec.hs` |
| A Baikai in-band provider failure is a failure, with its retryability preserved, rather than an empty successful reply | `shikigami-core/test/Shikigami/BehaviorProviderSpec.hs` |
| A fresh database applies all four migration components and re-applying is a no-op | `shikigami-migrations/test/Migrate.hs` |

The wire fixtures are **literals**, deliberately: a fixture built by calling the
current encoder would pass no matter what the encoder did. They were captured
from the encoders as they stand, and `git diff fef46f1..` over the modules
defining those types is empty, so they are also what the pre-upgrade build
produced. Keep them permanently — a change there is a wire-format change and
needs a migration story, not a fixture edit.


## Resolved evidence

Toolchain: GHC 9.12.4 inside the Nix dev shell.

```bash
$ nix develop --command cabal build all --dry-run
Build profile: -w ghc-9.12.4 -O1
```

The plan selects exactly the matrix above. The only `allow-newer` in
`cabal.project` is `haxl:time`, a third-party bound that predates this cohort;
no co-developed package needs one.

```bash
$ nix develop --command cabal test all -j1
shikigami-api-test          PASS   15 tests
shikigami-client-test       PASS    3 tests
shikigami-core-test         PASS   93 tests
shikigami-migrations-smoke  PASS    2 tests
shikigami-migrations-test   PASS    3 tests
shikigami-server-test       PASS   20 tests
shikigami-workers-test      PASS   21 tests
```

157 tests across seven suites, and the same result on an immediate second run.

Run the suites with `-j1`. Under `-j`, the database-backed suites each stand up
an ephemeral PostgreSQL and contend, which makes `shikigami-core-test` fail
intermittently while every suite passes serially.


## What this cohort cost in source, and what it left behind

Two upstream changes reached this repository. Both are recorded here because the version
numbers do not predict either one.

**keiki 0.9 sealed `InCtor`.** It is now a read-only pattern synonym: matching and field
selection still work, construction and record update do not.
`shikigami-core/src/Shikigami/Flow/Lifecycle/AtRiskCustomer.hs` built four `InCtor` values
by direct record construction and stopped compiling. They moved to
`mkInCtorVia @"<ConstructorName>"`, which required adding `Generic` to
`AtRiskCustomerCommand`'s deriving clause.

That choice is deliberate and worth not re-litigating. keiki offers `unavailableInCtor`,
which compiles just as readily and needs no `Generic` instance — but it carries no trusted
structural evidence, so `validateTransducer` would start returning `UnverifiedOpaque` where
it returns verified results today. The cheaper fix silently weakens a replay-safety check,
which is exactly the kind of regression a passing test suite does not catch.

**kioku 0.4 made memory spaces and principals mandatory.** Every session and memory command
record grew required `memorySpaceId` and `actorPrincipal` fields (`StartSessionData` and
`RecordMemoryData` also grew `ownerPrincipal`), and every read — `Session.getById`,
`getByScope`, `getTurns`, `getDelegationChildren`, `Memory.getRowsBySession`,
`Recall.getActiveByScope` — grew a leading `MemorySpaceId` argument. `Recall.recall` changed
shape entirely, taking a `MemoryAccessContext` and a new `RecallQuery`.

**This is not in kioku's changelog.** The 0.4.0.0 entry documents only the projection-schema
relocation; the 0.3.0.0 entry calls itself bounds-only with no source change. The mandatory
access fields are a breaking change that neither entry mentions, and they were discovered
here by compiling against it. That is worth an upstream improvement request.

Shikigami's answer to both new questions lives in one module,
`shikigami-core/src/Shikigami/Memory/Access.hs`, rather than at ~24 call sites:

- the space is `legacyMemorySpaceId`, the space kioku's migration `0011` backfills existing
  rows into. Shikigami is a single-space deployment, so this is the space, not a placeholder;
- the recorded actor is `KnownPrincipal` over a ref this service mints,
  `shikigami.agent.<name>`. This started as `LegacyPrincipal`, on the reasoning that
  `KnownPrincipal` claims a *directory* vouched and Shikigami has none. Kioku settled it in
  ADR-5 (revised 2026-08-18) and the premise was wrong twice: `KnownPrincipal` asserts a
  principal was *vouched for*, with `assumeAuthorizedMemoryContext` making the host itself
  accountable for the ref; and `LegacyPrincipal` is decode-side only, so stamping it on a new
  event asserts the event predates memory spaces, which is false. Self-assertion belongs in the
  ref's kind prefix — `PrincipalRef` names what a principal *is*, `RecordedPrincipal` names how
  much history *knows*;
- reads go through `assumeAuthorizedMemoryContext` under a service principal. A context is a
  decision rather than a document — kioku deliberately gives it no `FromJSON` instance — and
  no read path persists its actor, so naming the service there records nothing.

The retirement condition for all three is
`docs/improvement-requests/key-agent-continuity-by-meibo-principal.md` (IR-9). When agents
resolve to real principals, that module changes and the call sites do not.

**baikai 0.5 added a field to `ApiProvider`.** `describeThinking :: Model -> Options ->
ThinkingTranslation` lets the pre-dispatch strictness gate refuse a call *before* a request is
built, so it cannot wait for the translation a provider returns alongside its mapped request.
`shikigami-core/src/Shikigami/Behavior/StubProvider.hs` is the repository's only `ApiProvider`
and stopped compiling.

The stub calls no model and puts nothing on any wire, so it now reports that honestly: a caller
who set no level gets `noThinkingRequested`, and a caller who asked for one gets
`ThinkingModeUnsupported` with `ThinkingDroppedUnsupportedHost` recorded. The weaker answer —
claiming the request was expressed — would let a caller who asked for guaranteed evidence pass
the gate and then receive a fixed string, which is the failure the gate exists to prevent.

### Debt this cohort takes on knowingly

Shikigami now calls kioku's legacy compatibility surface — `Session.start`, `complete`,
`failSession`, `recordTurn`, `Memory.record`, and `Recall.legacyRecall` — all of which are
deprecated with "accepts only `legacyMemorySpaceId` and will be removed". That is ~24
`-Wdeprecations` warnings in `shikigami-core`. The build is not `-Werror`, so this is debt
rather than breakage, but it is debt with an announced expiry: the `*WithContext` variants
are the replacement, and taking them properly means having real principals, which is IR-9
again.

Three smaller deprecations survive from baikai: `_Model`, `_Response`, and `_Context`, the
record bases `StubProvider.hs` builds its fixtures from. They are unrelated to this upgrade and
were already deprecated before it; they are noted here so the next reader does not mistake them
for fallout from baikai 0.5.


## Migration consequence

This upgrade is migration-first. It added **16** migrations to the composed plan — kiroku
`0009`–`0011`, keiro `0021`–`0030`, and kioku `0011`–`0012` — bringing the applied total to
57. Two of them deserve operator attention:

- **`kioku/0011-kioku-memory-space-partition`** adds the partition column and backfills every
  existing row into `kioku_legacy` before making the column `NOT NULL`. A row that escapes
  the backfill becomes inaccessible rather than universally visible, which is the failure
  direction kioku chose deliberately.
- **`kioku/0012-relocate-projections-to-kioku-schema`** moves seven relations out of the
  `kiroku` schema into a dedicated `kioku` schema and drops the redundant prefix
  (`kiroku.kioku_memories` becomes `kioku.memories`). It is metadata only — OIDs, rows,
  indexes, constraints, and grants are preserved — and it accepts exactly two catalog states,
  raising transactionally on anything else.

Upstream calls this a planned-outage upgrade: stop writers, back up, migrate, grant
`USAGE ON SCHEMA kioku` if the runtime role is not the schema owner, reconcile the read-model
registry, then start the new binary. There are no compatibility views and restarting the old
binary is **not** a rollback. Shikigami is a library embedder, so the registry reconciliation
is its own responsibility; it is already wired at
`shikigami-migrations/src/Shikigami/Migrations.hs:106`.

`kioku 0.4.1.0` adds no migration — it is a dependency-bounds release — so the plan below is
unchanged by it.

Applied and verified on the in-repo dev cluster on 2026-08-17: 57 applied, 0 pending, and
`cabal test all` green afterwards. **A database holding real data is a different exercise** —
use the `cohort-migrate` skill, which proves the remediation on a restored clone before
production is touched.
