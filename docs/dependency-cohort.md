# Dependency cohort — August 2026

Shikigami builds against **one** coherent set of co-developed releases. This
document is the contract: it names each explicitly managed cohort selection,
the upstream tag and tag commit that produced it, and the evidence that the
cohort holds together. `cabal.project` encodes the direct selections as a
`constraints:` block; the one bound-driven transitive selection in the matrix
is labelled as such. A drift between a direct-selection row and the solver is a
bug in one of them.

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
| `shibuya-kafka-adapter` | `mori://shinzui/shibuya-kafka-adapter` |
| `shibuya-pgmq-adapter` | `mori://shinzui/shibuya-pgmq-adapter` |
| `kiroku-store*`, `shibuya-kiroku-adapter` | `mori://shinzui/kiroku` |
| `pgmq-*` | `mori://shinzui/pgmq-hs` |
| `pg-migrate*` | `mori://shinzui/pg-migrate` |
| `settei*` | `mori://shinzui/settei` |
| `servant-health` | `mori://shinzui/servant-health` |
| `ephemeral-pg` | `mori://shinzui/ephemeral-pg` |
| `handan-core` | `mori://shinzui/handan` |
| `kafka-effectful` | `mori://shinzui/kafka-effectful` |
| `danwa*` | `mori://shinzui/danwa` |


## Release matrix

Every row below is resolved from Hackage. "Was" is the version this repository
pinned before the August 2026 upgrade (the July cohort recorded by plan 47).
The matrix records what Shikigami selects, not what Hackage most recently
published; the current release status is called out immediately below it.

| Package | Was | Now | Upstream tag | Tag commit |
|---|---|---|---|---|
| `keiki` | 0.4.0.0 | **0.9.1.0** | `v0.9.1.0` | `15bc83b1eb38d78488862f24bb1d873aa32a919a` |
| `keiki-codec-json` | 0.4.0.0 | **0.9.1.0** | `v0.9.1.0` | `15bc83b1eb38d78488862f24bb1d873aa32a919a` |
| `keiro` | 0.4.0.1 | **0.14.0.0** | `keiro-0.14.0.0` | `0bdd4b7d9c3e766c394ea487333822ddf9a554a8` |
| `keiro-core` | 0.4.0.1 | **0.14.0.0** | `keiro-core-0.14.0.0` | `0bdd4b7d9c3e766c394ea487333822ddf9a554a8` |
| `keiro-dsl` | — | **0.14.0.0** | `keiro-dsl-0.14.0.0` | `0bdd4b7d9c3e766c394ea487333822ddf9a554a8` |
| `keiro-migrations` | 0.4.0.1 | **0.14.0.0** | `keiro-migrations-0.14.0.0` | `0bdd4b7d9c3e766c394ea487333822ddf9a554a8` |
| `keiro-ops` | — | **0.14.0.0** | `keiro-ops-0.14.0.0` | `0bdd4b7d9c3e766c394ea487333822ddf9a554a8` |
| `keiro-pgmq` | — | **0.14.0.0** | `keiro-pgmq-0.14.0.0` | `0bdd4b7d9c3e766c394ea487333822ddf9a554a8` |
| `kioku-api` | 0.2.0.0 | **0.5.0.0** | `v0.5.0.0` | `cb5f35e2e97477ad4da16e2f64b9d09a6c1634ad` |
| `kioku-core` | 0.2.0.0 | **0.5.0.0** | `v0.5.0.0` | `cb5f35e2e97477ad4da16e2f64b9d09a6c1634ad` |
| `kioku-migrations` | 0.2.0.0 | **0.5.0.0** | `v0.5.0.0` | `cb5f35e2e97477ad4da16e2f64b9d09a6c1634ad` |
| `shikumi` | 0.3.0.1 | **0.3.0.2** | `shikumi-0.3.0.2` | `5e3680e52608d7e88698fa9485f78619853ced98` |
| `shikumi-tools` | — | **0.3.0.2** | `shikumi-tools-0.3.0.2` | `5e3680e52608d7e88698fa9485f78619853ced98` |
| `baikai` | 0.4.1.0 | **0.5.0.0** | `baikai-0.5.0.0` | `d6c57d3c70096711231420cfb1f801d6ee600fdc` |
| `baikai-claude` | 0.4.0.1 | **0.5.0.0** | `baikai-claude-0.5.0.0` | `d6c57d3c70096711231420cfb1f801d6ee600fdc` |
| `baikai-effectful` (transitive) | 0.3.0.2 | **0.3.0.3** | `baikai-effectful-0.3.0.3` | `d6c57d3c70096711231420cfb1f801d6ee600fdc` |
| `kafka-effectful` | 0.3.0.0 (Git) | **0.3.0.0** | `v0.3.0.0` | `2f3ee7e4f2da41befd338f3eda35aa337b2f022f` |
| `shibuya-core` | 0.8.0.1 | **0.9.0.0** | `v0.9.0.0` | `d958a5748475a4b84075feda7a2a4f5cc7471c60` |
| `shibuya-kafka-adapter` | — | **0.9.0.0** | `v0.9.0.0` | `89e8026b3aeb7ebca9ff93482fa7f0195be06f63` |
| `shibuya-pgmq-adapter` | 0.12.0.0 | **0.14.0.0** | `v0.14.0.0` | `301652375ecdec01c4e1ff50902900ad3a078ea3` |
| `shibuya-kiroku-adapter` | 0.4.0.0 | **0.5.1.1** | `shibuya-kiroku-adapter-v0.5.1.1` | `7726d23028cd4edfba69762edf659485b9547da4` |
| `kiroku-store` | 0.3.1.0 | **0.8.0.0** | `kiroku-store-v0.8.0.0` | `7726d23028cd4edfba69762edf659485b9547da4` |
| `kiroku-store-migrations` | 0.3.0.0 | **0.4.0.0** | `kiroku-store-migrations-v0.4.0.0` | `7c8f2dac48c077427834650aa6e76d0682712809` |
| `pgmq-core` / `-hasql` / `-effectful` | 0.4.0.1 | **0.5.0.0** | `v0.5.0.0` | `fc13d7a432dbc0cf0ad4cd3616e5d7d28fdf5abe` |
| `pg-migrate` | 1.1.0.0 | 1.1.0.0 | `v1.1.0.0` | `f39d64e354818999667d345a1452f33eb4857fc1` |
| `settei` | 0.2.0.0 | 0.2.0.0 | `v0.2.0.0` | `1bf62b0af110b4f42fe2528e9d459e0ccf12d626` |
| `hs-opentelemetry-api` / `-sdk` | 1.0.0.0 | 1.0.0.0 | Hackage (third party) | — |

`baikai-effectful` is not an exact row in `cabal.project`: `kioku-core`
selects it through `^>=0.3.0.3`, and the resolved plan contains 0.3.0.3. Every
other package named in the first column is an exact `constraints:` selection.

`shikumi-tools 0.3.0.2` is the released model-tool registry consumed by
`shikigami-core`. Hackage and the upstream `shikumi-tools-0.3.0.2` tag were
reverified on 2026-08-22; it shares tag commit
`5e3680e52608d7e88698fa9485f78619853ced98` with the selected `shikumi 0.3.0.2`
cohort.

`kafka-effectful` moved from the post-release Git commit
`f34a43cd476f7234848def9c0f08c54a1b67028e` to the exact Hackage 0.3.0.0
release. The old commit differs from tag `v0.3.0.0` only in Nix development
files; its Cabal file and package source are unchanged, so this is a provenance
cleanup rather than an API or bytecode change.

`pgmq-migration` left the block rather than moving because it resolves into
nothing now that kioku composes its migrations through `pg-migrate`.
`keiro-pgmq`, by contrast, is linked by `shikigami-workers` for the typed
run-job consumer and is pinned with the rest of the Keiro family.

`keiro-ops` is new to this cohort and is an ordinary library: `shikigami-server`
links it so the `shikigami` administrative binary can mount Keiro's operator
command tree instead of hand-writing one. Its own bounds are
`keiro ^>=0.14.0.0`, `keiro-migrations ^>=0.14.0.0`, `keiro-pgmq ^>=0.14.0.0`,
and `kiroku-store >=0.8 && <0.9`, all of which this cohort already satisfies, so
it resolved without moving anything else. Adopted by
`docs/plans/30-operator-cli-inspect-runs-agents-dead-letters-and-cancel.md`.

`keiro-dsl` is new to this cohort and is the one row that is not a library this
service links against. It is the build-time specification toolchain that checks
`domain/shikigami.keiro-workspace` and scaffolds `shikigami-core/src`, so it is
declared as `extra-packages: keiro-dsl` in `cabal.project` rather than as a
`build-depends` of any component. `extra-packages` makes the solver treat a
Hackage package as if it were local, which is what lets `cabal run keiro-dsl --
check ...` resolve to the pinned version from inside this project instead of
depending on a developer's `PATH` or on a separate keiro checkout. The
`constraints:` row pins it to the same `0.14.0.0` as the runtime packages,
because the toolchain and the runtime move in lockstep: `keiro-dsl 0.14.0.0`
declares `keiro-core ^>=0.14.0.0` and `keiki >=0.9 && <0.10`, both of which this
cohort already satisfies. Adopted by
`docs/plans/39-adopt-a-checked-keiro-dsl-specification-and-evolution-gate.md`.

### Current release status

No compatible release line is pending adoption. Hackage and upstream both
identify `keiki-0.9.1.0` and `keiki-codec-json-0.9.1.0` as current (tag
`v0.9.1.0`, commit `15bc83b1eb38d78488862f24bb1d873aa32a919a`, released
2026-08-20), and Shikigami selects both. The release changes the default
inversion-ambiguity analysis so complementary standard `Bool` guards are
proved disjoint; it does not change Keiki's public runtime API or the JSON wire
format. Keiro 0.14 admits `keiki >=0.9 && <0.10`, and Kioku 0.5 admits
`keiki ^>=0.9.0.0`. The paired adoption required no Shikigami source changes;
the Keiro specification, deterministic scaffold, replay diff, conformance,
build, and full serial test gates all passed on 2026-08-22.

Every explicitly managed cohort selection is at its newest Hackage release.
No `allow-newer` is used between co-developed packages.

That was not true when the upgrade started. `kioku-core 0.4.0.0`'s library declared
`baikai ^>=0.4.1.0`, capping baikai below 0.5, which in turn pinned `shikumi` to `0.3.0.1`
(because `shikumi 0.3.0.2` requires `baikai >=0.5`) and `baikai-effectful` to `0.3.0.2`.
Three packages held by one bound.

`kioku 0.4.1.0` (2026-08-18) lifted it: that release moved kioku onto baikai 0.5, declaring
`baikai ^>=0.5.0.0`, `baikai-claude ^>=0.5.0.0`, `baikai-effectful ^>=0.3.0.3`,
`shikumi ^>=0.3.0.2`, and `shikumi-trace ^>=0.2.0.2`. Its keiro, keiki, kiroku, and shibuya
bounds were unchanged from 0.4.0.0, and it added no migration. `kioku 0.5.0.0`
(2026-08-22) then moved the memory cohort to Keiro 0.14 without moving those other
dependencies. That released bound is what lets Shikigami consume Keiro's terminal outbox
rejection without an `allow-newer`.

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
| `danwa-core`, `danwa-api`, `danwa-client` | No Hackage release. Conversation substrate behind the `DanwaConversation` sink. | Danwa publishes. |

Only Handan and Danwa remain Git-sourced, and both exceptions retire when their
packages publish to Hackage.

Schema evolution is pg-migrate throughout. The `codd`, `hasql-migration`, and
`hasql-notifications` forks this project once carried are gone, and so is the
`pg-migrate-import-codd` path that would have imported an existing codd ledger — plan 38
cancelled it on 2026-08-05 because no database needs its history preserved.


## Compatibility evidence

Each row states why the cohort member is safe to adopt, and where the proof lives.

| Concern | Evidence |
|---|---|
| Kioku pairs with the released Keiro/Keiki | `kioku-core-0.5.0.0` declares `keiki ^>=0.9.0.0`, `keiro ^>=0.14.0.0`, and `keiro-core ^>=0.14.0.0`; `kioku-migrations-0.5.0.0` declares `keiro-migrations ^>=0.14.0.0`. The solver selects the exact released cohort with no `allow-newer`. |
| Kioku's own codec regression guard | Kioku 0.2.0.0 adds `Kioku.CodecCompatSpec`, which decodes literal pre-upgrade event payloads under the new cohort. |
| Keiro terminal outbox rejection | Keiro 0.14 adds bounded `PublishRejection` values, `PublishRejected`, terminal `rejected` rows, rejection audit fields, and a `rejected` publisher-summary count. Shikigami constructs code `sink.permanent-failure` through `mkPublishRejection`; it never mutates Keiro-owned tables. |
| Keiro snapshot state-shape hash | `StateCodec` gains `stateShapeHash`; migration `0019-keiro-snapshots-state-shape-hash.sql` adds the column and existing rows take the empty sentinel, invalidating each snapshot exactly once on next hydration. Journals and events are untouched. |
| Keiro child failure reason | Migration `0020-keiro-workflow-children-failure-reason.sql` adds a nullable `failure_reason`; `markChildFailedTx` takes the reason as a third argument. |
| Keiro child-workflow boundary | `mori://shinzui/keiro` 0.14 keeps child registration framework-owned: Shikigami uses the public `spawnChild` and `cancelChild` operations rather than transaction-private child-table functions. The delegation ledger reserves capacity before spawn and repairs the reservation deterministically after a replayed spawn, so the application does not need a coupled Keiro/ledger transaction. |
| Keiro queue envelopes | Scaffolded workqueues gain a versioned `keiroJobCodec` envelope. Shikigami's queues are not scaffolded by `keiro-dsl` and continue to use their own payload codecs, so no in-flight message changes shape in this plan. Recorded as a live constraint for plan 39. |
| PGMQ delivery attempt numbering | `shibuya-pgmq-adapter-0.14.0.0` retains the conversion, present since 0.12, from PGMQ's one-based `read_count` to a zero-based `Message.attempt`. Shikigami must not subtract one again. |
| Shibuya 0.9 public surface | The 0.9 line retains the public surface adopted at 0.8: `runApp` takes `AppConfig`; handlers receive `Message es msg`; `Ordering` is named `OrderingPolicy`; runner internals live under `Shibuya.Internal.*`. Shikigami uses only the public surface. |
| Shibuya Kafka adapter 0.9 | `shibuya-kafka-adapter-0.9.0.0` declares `shibuya-core ^>=0.9.0.0` and `kafka-effectful ^>=0.3.0.0`; the stream worker links that exact adapter and the exact Hackage `kafka-effectful-0.3.0.0` release for `activity.v1`. |
| Baikai 0.5 | The widened `ThinkingLevel` sum and defaulted request `effort` remain, and `ApiProvider` adds `describeThinking` so strictness is decided before request construction. Shikigami's stub implements the new method explicitly. |
| Settei 0.2 | Unchanged by this cohort; `docs/operations/configuration.md` remains the configuration contract. |

## Compatibility fixtures

Four focused spec modules hold the cohort to the claims above. They are the
reason a future bump cannot quietly change a persisted byte or configuration.

| What it pins | Where |
|---|---|
| Pre-upgrade `RunJob` queue payloads, successful journal step values, `SinkIntent` and `SinkResult` outbox JSON (including the deprecated `Stubbed` outcome), additive compatibility defaults, and PGMQ's zero-based attempt | `shikigami-core/test/Shikigami/WireCompatSpec.hs` |
| Agent declarations without delegation fields still load with an empty allow-list and no per-agent budget override, while declared delegation values survive Dhall loading | `shikigami-core/test/Shikigami/AgentLoaderSpec.hs` |
| A Baikai in-band provider failure is a failure, with its retryability preserved, rather than an empty successful reply | `shikigami-core/test/Shikigami/BehaviorProviderSpec.hs` |
| A fresh database applies all four migration components and re-applying is a no-op | `shikigami-migrations/test/Migrate.hs` |

The pre-upgrade wire fixtures are **literals**, deliberately: a fixture built by
calling the current encoder would pass no matter what the encoder did. The
types have evolved since those bytes were captured. `RunJob` gained
`routeKind`, `lineage`, and `delegationBudgetId`; `AgentDecl` gained `delegates`
and `delegationBudget`; `SinkIntent` gained `resolvedRecipient`; and successful
Kioku step values gained a refusal-capable wrapper. Their encoders omit
compatibility defaults and their decoders restore those defaults when keys are
absent, so the specs prove both the unchanged legacy forms and the new
non-default forms. Keep the legacy literals permanently — a change there is a
wire-format change and needs a migration story, not a fixture edit.


## Resolved evidence

Toolchain: GHC 9.12.4 inside the Nix dev shell.

```bash
$ nix develop --command cabal build all --dry-run
Build profile: -w ghc-9.12.4 -O1
```

The plan selects exactly the pinned and transitive versions in the matrix
above, including both Keiki packages at 0.9.1.0 and `kafka-effectful` 0.3.0.0
from Hackage. The only `allow-newer` in `cabal.project` is `haxl:time`, a
third-party bound that predates this cohort; no co-developed package needs one.

```bash
$ nix develop --command cabal test all -j1
keiro-shikigami-conformance PASS   24 checks
shikigami-agent-test        PASS    8 tests
shikigami-api-test          PASS   15 tests
shikigami-client-test       PASS    3 tests
shikigami-core-test         PASS  390 tests
shikigami-migrations-smoke  PASS    2 tests
shikigami-migrations-test   PASS    4 tests
shikigami-server-test       PASS   29 tests
shikigami-workers-test      PASS   78 tests
```

553 checks across nine suites passed on 2026-08-22 with Keiki 0.9.1.0 selected
and `kafka-effectful` 0.3.0.0 resolved from Hackage.

Run the suites with `-j1`. Under `-j`, the database-backed suites each stand up
an ephemeral PostgreSQL and contend, which makes `shikigami-core-test` fail
intermittently. The 553-check run above is the latest complete default-RTS
serial pass and supersedes both the pre-lifecycle 518-check run and the earlier
partial audit that aborted in the GHC runtime rather than at a test assertion.


## What this cohort cost in source, and what it left behind

The source-level adaptations worth carrying forward are recorded here because
the version numbers do not predict them.

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

The first August cohort upgrade was migration-first. It added **16** migrations to the
then-current composed plan — kiroku `0009`–`0011`, keiro `0021`–`0030`, and kioku
`0011`–`0012`. Two of them deserve operator attention:

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

Keiro 0.14 and Kioku 0.5 add two entries: Keiro `0031` adds terminal rejected-outbox audit
columns, constraints, and partial-index exclusions; Kioku `0013` adds the partition-aware
full-text index when `btree_gin` is available and retains the old correctness-preserving index
otherwise. The dependency-composed plan is therefore 55 entries (Kiroku 11, Keiro 31, Kioku
13). Shikigami's ninth entry, `2026-08-22-22-35-00-delegation-budgets.sql`, adds the
shared delegation ledger; the complete application plan is now 64 entries.

Kioku 0.5 also corrects the already-released payload bytes for
`kioku/0011-kioku-memory-space-partition`. A fresh or ephemeral database applies the corrected
payload and needs no special handling. Before the first `up` or `verify` with Kioku 0.5, an
existing database that applied 0011 from Kioku 0.4.0 or 0.4.1 must run Kioku's one-time,
idempotent ledger re-baseline at
`mori://shinzui/kioku` project path
`kioku-migrations/ledger-fixups/2026-08-19-rebaseline-0011-checksum.sql`, after a verified
backup. An artifact-level Mori URI for ledger fixups is pending, so the canonical project URI
and project-relative path are recorded together. That script is operational remediation for
the exact withdrawn checksum, not a schema migration and not permission to ignore any other
checksum mismatch.

**A database holding real data is a different exercise** — use the `cohort-migrate` skill,
which proves the remediation on a restored clone before production is touched.
