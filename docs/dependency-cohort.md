# Dependency cohort — September 2026

Shikigami builds against **one** coherent set of co-developed releases. This
document is the contract: it names each explicitly managed cohort selection,
the upstream tag and tag commit that produced it, and the evidence that the
cohort holds together. `cabal.project` encodes the direct selections as a
`constraints:` block; bound-driven transitive selections in the matrix are
labelled as such. A drift between a direct-selection row and the solver is a
bug in one of them.

## Current Keiro 0.17 target

MasterPlan 12 advances the runtime to this coherent selection:

| Family | Selected release |
|---|---|
| `keiro`, `keiro-core`, `keiro-dsl`, `keiro-migrations`, `keiro-ops`, `keiro-pgmq`, `keiro-test-support` | `0.17.0.0` |
| `kioku-api`, `kioku-core`, `kioku-migrations` | `0.7.0.0` |
| `pgmq-core`, `pgmq-hasql`, `pgmq-effectful`, `pgmq-config` | `0.6.1.0` |
| `shibuya-pgmq-adapter` | `0.16.0.0` |
| `shikumi`, `shikumi-tools`, `shikumi-trace` | `0.4.0.0`, `0.4.0.0`, `0.3.0.0` |
| `baikai`, `baikai-claude`, `baikai-openai`, `baikai-effectful` | `0.7.0.0`, `0.7.0.0`, `0.7.0.0`, `0.4.0.1` |

All seven Keiro releases are on Hackage and their release tags resolve to commit
`11e0bba4f634ac6fa4526e2814bd5a8177e3f050` in `mori://shinzui/keiro`.
Kioku's release commit is
`37c3acd2d16e18c49217bc6189ea20b496907e3b`; its 0.7 Cabal files admit Keiro
0.17 and move AI execution to an explicit host-owned runtime. Shikigami loads that
runtime from `KIOKU_AI_CONFIG`; an absent or disabled query-embedding feature makes
hybrid recall fall back to keyword search.

`baikai-effectful` is deliberately fixed at 0.4.0.1. Version 0.4.0.2 requires
`effectful-core ^>=2.7`, while the selected Keiro/Kioku releases require a version
below 2.7. Kioku 0.7 admits 0.4.0.1, so no `allow-newer` is needed.

At authoritative index-state `2026-09-19T01:06:24Z`, Hackage exposes all three
Kioku 0.7.0.0 packages. A detached Shikigami worktree with no
`cabal.project.local` downloaded them from Hackage, built every application
component, and passed the aggregate qualification. The older Plan 65 matrix below
remains historical evidence for the 0.15 baseline used by the real upgrade fixture.


Plan 65 adoption starts at `65b8a1b44faa540fef163d5de33ee1c79eea7de4`.
On 2026-09-07 the preferred-version endpoints for all seven Keiro and three Kioku
packages still select 0.15.0.0 and 0.5.2.0 respectively. All ten released Cabal
files match their upstream tag bytes exactly. The refreshed secure index is
`2026-09-07T12:40:03Z`; `nix develop -c cabal build all --dry-run` succeeds with
these selections and the existing unrelated constraints. Edition migration, runtime assembly and nominal scalar qualification pass.
The final Plan 65 acceptance record below supersedes the historical August test counts.

The Danwa plan `mori://shinzui/danwa/plans/13-upgrade-danwa-to-the-released-keiro-0-15-cohort`
now records five non-migration library builds and three pure suites passing, but the
existing source pin is retained until this consumer build requires a move and a
published compatible commit is verified. Retire the pin on a compatible published
package release, or advance it to a verified published cohort commit after checking
its API changes and this service's full consumer tests.

Two rules govern changes:

1. **Released versions only.** A co-developed dependency is selected by Hackage
   version. A `source-repository-package` stanza is admissible only for a package
   with no Hackage release, or for a fork we deliberately carry; each such stanza
   carries a comment saying which case it is and when it retires. A sibling package path is
   permitted only while an unpublished public contract is being co-developed, and records the
   exact producing commit it must become.
2. **No permanent `allow-newer` between co-developed packages.** If two cohort
   members cannot agree, the fix is an upstream release or Hackage revision,
   not an unbounded solver override. A temporary exception must name only the
   stale package/bound pair, carry compatibility evidence here, and retire as
   soon as corrected release metadata is published.

Regenerate the resolved-version evidence with:

```bash
nix develop --command cabal build all --dry-run
```

Use the Nix development environment for native libraries and PostgreSQL tools.
An already configured agent environment can invoke Cabal and built test binaries
directly; an unconfigured shell can fail to link `rdkafka`.


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
| `kikan-en-contract`, `kikan-en-client` | `mori://shinzui/kikan-en` |
| `en-core`, `en-biscuit` | `mori://shinzui/en` |
| `shomei*` | `mori://shinzui/shomei` |
| `biscuit` | `mori://shinzui/biscuit-haskell` |


## Release matrix

Every row below is resolved from Hackage. "Was" is the version this repository
pinned before the August 2026 upgrade (the July cohort recorded by plan 47).
The matrix records what Shikigami selects, not what Hackage most recently
published; the current release status is called out immediately below it.

| Package | Was | Now | Upstream tag | Tag commit |
|---|---|---|---|---|
| `keiki` | 0.4.0.0 | **0.9.1.0** | `v0.9.1.0` | `15bc83b1eb38d78488862f24bb1d873aa32a919a` |
| `keiki-codec-json` | 0.4.0.0 | **0.9.1.0** | `v0.9.1.0` | `15bc83b1eb38d78488862f24bb1d873aa32a919a` |
| `keiro` | 0.4.0.1 | **0.15.0.0** | `keiro-0.15.0.0` | `de574cdcb0add3fefbb0fdd96d820258d15f8997` |
| `keiro-core` | 0.4.0.1 | **0.15.0.0** | `keiro-core-0.15.0.0` | `de574cdcb0add3fefbb0fdd96d820258d15f8997` |
| `keiro-dsl` | — | **0.15.0.0** | `keiro-dsl-0.15.0.0` | `de574cdcb0add3fefbb0fdd96d820258d15f8997` |
| `keiro-migrations` | 0.4.0.1 | **0.15.0.0** | `keiro-migrations-0.15.0.0` | `de574cdcb0add3fefbb0fdd96d820258d15f8997` |
| `keiro-ops` | — | **0.15.0.0** | `keiro-ops-0.15.0.0` | `de574cdcb0add3fefbb0fdd96d820258d15f8997` |
| `keiro-pgmq` | — | **0.15.0.0** | `keiro-pgmq-0.15.0.0` | `de574cdcb0add3fefbb0fdd96d820258d15f8997` |
| `keiro-test-support` | — | **0.15.0.0** (migration test-support only) | `keiro-test-support-0.15.0.0` | `de574cdcb0add3fefbb0fdd96d820258d15f8997` |
| `kioku-api` | 0.2.0.0 | **0.5.2.0** | `v0.5.2.0` | `14a7543f508a7d8110296383aa0500ab9e3b6a5d` |
| `kioku-core` | 0.2.0.0 | **0.5.2.0** | `v0.5.2.0` | `14a7543f508a7d8110296383aa0500ab9e3b6a5d` |
| `kioku-migrations` | 0.2.0.0 | **0.5.2.0** | `v0.5.2.0` | `14a7543f508a7d8110296383aa0500ab9e3b6a5d` |
| `shikumi` | 0.3.0.1 | **0.3.0.3** | `shikumi-0.3.0.3` | `205219f75dde9350cad9fd47b97a5e1576674123` |
| `shikumi-tools` | — | **0.3.0.3** | `shikumi-tools-0.3.0.3` | `205219f75dde9350cad9fd47b97a5e1576674123` |
| `shikumi-trace` (transitive) | — | **0.2.0.3** | `shikumi-trace-0.2.0.3` | `205219f75dde9350cad9fd47b97a5e1576674123` |
| `shikumi-trace-otel` (transitive) | — | **0.1.1.1** | `shikumi-trace-otel-0.1.1.1` | `205219f75dde9350cad9fd47b97a5e1576674123` |
| `baikai` | 0.4.1.0 | **0.6.0.0** | `baikai-0.6.0.0` | `1b97e14c62f03ca35adc2feecae1a505a9edf02b` |
| `baikai-claude` | 0.4.0.1 | **0.6.0.0** | `baikai-claude-0.6.0.0` | `1b97e14c62f03ca35adc2feecae1a505a9edf02b` |
| `baikai-openai` (transitive) | — | **0.6.0.0** | `baikai-openai-0.6.0.0` | `1b97e14c62f03ca35adc2feecae1a505a9edf02b` |
| `baikai-effectful` (transitive) | 0.3.0.2 | **0.4.0.0** | `baikai-effectful-0.4.0.0` | `1b97e14c62f03ca35adc2feecae1a505a9edf02b` |
| `baikai-trace-otel` (transitive) | — | **0.4.0.0** | `baikai-trace-otel-0.4.0.0` | `1b97e14c62f03ca35adc2feecae1a505a9edf02b` |
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

Rows labelled transitive are not exact entries in `cabal.project`; they are the
versions selected through the pinned Kioku, Shikumi, and Baikai packages. Every
other package named in the first column is an exact `constraints:` selection.

`shikumi-tools 0.3.0.3` is the released model-tool registry consumed by
`shikigami-core`. Hackage and the upstream `shikumi-tools-0.3.0.3` tag were
reverified on 2026-08-29; it shares tag commit
`205219f75dde9350cad9fd47b97a5e1576674123` with the selected `shikumi 0.3.0.3`
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
`keiro ^>=0.15.0.0`, `keiro-migrations ^>=0.15.0.0`, `keiro-pgmq ^>=0.15.0.0`,
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
`constraints:` row pins it to the same `0.15.0.0` as the runtime packages,
because the toolchain and the runtime move in lockstep: `keiro-dsl 0.15.0.0`
declares `keiro-core ^>=0.15.0.0` and `keiki >=0.9 && <0.10`, both of which this
cohort already satisfies. Adopted by
`docs/plans/39-adopt-a-checked-keiro-dsl-specification-and-evolution-gate.md`.

### Current release status

No compatible release line in the released cohort matrix is pending adoption. The unpublished
action-authorization dependencies are recorded separately below. Hackage and upstream both
identify `keiki-0.9.1.0` and `keiki-codec-json-0.9.1.0` as current (tag
`v0.9.1.0`, commit `15bc83b1eb38d78488862f24bb1d873aa32a919a`, released
2026-08-20), and Shikigami selects both. The release changes the default
inversion-ambiguity analysis so complementary standard `Bool` guards are
proved disjoint; it does not change Keiki's public runtime API or the JSON wire
format. Keiro 0.14 admits `keiki >=0.9 && <0.10`, and Kioku 0.5 admits
`keiki ^>=0.9.0.0`. The paired adoption required no Shikigami source changes;
the Keiro specification, deterministic scaffold, replay diff, conformance,
build, and full serial test gates all passed on 2026-08-22.

The August matrix was verified on 2026-08-29. Plan 65 rechecked the seven Keiro
and three Kioku packages on 2026-09-07 and adopted Keiro 0.15.0.0 with Kioku
0.5.2.0. Kioku retains the Baikai 0.6, Shikumi 0.3.0.3 and `http-client-tls` 0.4
compatibility introduced by its preceding 0.5.1.0 release.

Five narrow `http-client-tls` exceptions remain while released Hackage metadata catches up:
`baikai`, `baikai-claude`, `baikai-openai`, `shikumi-tools`, and the third-party `claude`
package all cap the dependency below 0.4 even though their used API compiles against 0.4.
Local upstream fixes widen the four co-developed package bounds to `<0.5`; the consuming
overrides retire after those Hackage revisions or replacement releases are published. The
pre-existing third-party `haxl:time` exception is unrelated.

The Baikai source fix is required, but not sufficient by itself: without it the solver rejects
the direct Baikai packages, while `shikumi-tools` and `claude` independently retain the same
stale cap. Removing upper bounds entirely is not the fix; the upstream Cabal files retain a
PVP upper bound and widen only through the compatibility-proved 0.4 line.

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
| `en-core`, `en-biscuit` | En has no upstream tag or Hackage release. The exact commit `51edaab17473f7b9310f8802ccffd23bac5e4a9e` supplies the generic proof verifier used by the Kikan client. | En publishes a compatible release. |
| `shomei-core`, `shomei-jwt`, `shomei-servant`, `shomei-client` | Shomei's 0.1.0.0 source tags resolve to exact commit `65551cb120336b53695c0dd30ebe0e473d6efcb2`, but the packages are not on Hackage. | Shomei publishes those packages. |
| `biscuit` | Exact commit `8c0b3c5a13ce4a310737c0336f2ae167a1597588` is En's current proof-parser dependency. | En adopts a released compatible Biscuit package. |

`kikan-en-contract` and `kikan-en-client` are temporarily listed as sibling packages from the
`mori://shinzui/kikan-en` checkout at commit
`b061e55cda12ff87fbfeb61c99466e03cd2d6852`. They are the only Kikan packages Shikigami links;
the PostgreSQL host and policy internals remain outside this build. Replace the sibling paths with
that exact upstream commit when the packages are published to the remote repository, then with a
released version when one exists.

Schema evolution is pg-migrate throughout. The `codd`, `hasql-migration`, and
`hasql-notifications` forks this project once carried are gone, and so is the
`pg-migrate-import-codd` path that would have imported an existing codd ledger — plan 38
cancelled it on 2026-08-05 because no database needs its history preserved.


## Compatibility evidence

Each row states why the cohort member is safe to adopt, and where the proof lives.

| Concern | Evidence |
|---|---|
| Kioku pairs with the released Keiro/Keiki | `kioku-core-0.5.2.0` declares `keiki ^>=0.9.0.0`, `keiro ^>=0.15.0.0`, and `keiro-core ^>=0.15.0.0`; `kioku-migrations-0.5.2.0` declares `keiro-migrations ^>=0.15.0.0`. The solver selects that exact released cohort. |
| Kioku's own codec regression guard | Kioku 0.2.0.0 adds `Kioku.CodecCompatSpec`, which decodes literal pre-upgrade event payloads under the new cohort. |
| Keiro terminal outbox rejection | Keiro 0.14 adds bounded `PublishRejection` values, `PublishRejected`, terminal `rejected` rows, rejection audit fields, and a `rejected` publisher-summary count. Shikigami constructs code `sink.permanent-failure` through `mkPublishRejection`; it never mutates Keiro-owned tables. |
| Keiro snapshot state-shape hash | `StateCodec` gains `stateShapeHash`; migration `0019-keiro-snapshots-state-shape-hash.sql` adds the column and existing rows take the empty sentinel, invalidating each snapshot exactly once on next hydration. Journals and events are untouched. |
| Keiro child failure reason | Migration `0020-keiro-workflow-children-failure-reason.sql` adds a nullable `failure_reason`; `markChildFailedTx` takes the reason as a third argument. |
| Keiro child-workflow boundary | `mori://shinzui/keiro` 0.14 keeps child registration framework-owned: Shikigami uses the public `spawnChild` and `cancelChild` operations rather than transaction-private child-table functions. The delegation ledger reserves capacity before spawn and repairs the reservation deterministically after a replayed spawn, so the application does not need a coupled Keiro/ledger transaction. |
| Keiro queue envelopes | Plan 65 moves every run-job producer and the worker to the generated version-1 `{v,t,data}` envelope, policy and provisioning. Literal current bytes and rejection of the retired bare payload are tested; the unused pre-v1 reset has recorded breaking evidence. |
| PGMQ delivery attempt numbering | `shibuya-pgmq-adapter-0.14.0.0` retains the conversion, present since 0.12, from PGMQ's one-based `read_count` to a zero-based `Message.attempt`. Shikigami must not subtract one again. |
| Shibuya 0.9 public surface | The 0.9 line retains the public surface adopted at 0.8: `runApp` takes `AppConfig`; handlers receive `Message es msg`; `Ordering` is named `OrderingPolicy`; runner internals live under `Shibuya.Internal.*`. Shikigami uses only the public surface. |
| Shibuya Kafka adapter 0.9 | `shibuya-kafka-adapter-0.9.0.0` declares `shibuya-core ^>=0.9.0.0` and `kafka-effectful ^>=0.3.0.0`; the stream worker links that exact adapter and the exact Hackage `kafka-effectful-0.3.0.0` release for `activity.v1`. |
| Baikai 0.6 | Evolvable constructors are hidden behind `emptyModel`, `emptyResponse`, `apiProviderWith`, and evidence builders/selectors. Shikigami uses those public paths, handles the new sampling adjustments separately from thinking weakening, and pins literal evidence JSON to schema `baikai.model-call-evidence/2.0`. |
| TLS 0.4 compatibility | The Baikai core, Claude, and OpenAI suites pass against `http-client-tls ==0.4.0` with only the independently stale `claude:http-client-tls` metadata relaxed; all 70 Shikumi-tools tests pass against the same line with the released Baikai and Claude metadata exceptions. Their source uses the retained `tlsManagerSettings` surface. Baikai, Shikumi-tools, and Claude need Hackage revisions before Shikigami can remove the narrow exceptions. |
| Settei 0.2 | Unchanged by this cohort; `docs/operations/configuration.md` remains the configuration contract. |

## Compatibility fixtures

Four focused spec modules hold the cohort to the claims above. They are the
reason a future bump cannot quietly change a persisted byte or configuration.

| What it pins | Where |
|---|---|
| Current generated `RunJob` envelope, rejection of retired bare/incomplete payloads, successful journal values, `SinkIntent`/`SinkResult` JSON and PGMQ's zero-based attempt | `shikigami-core/test/Shikigami/WireCompatSpec.hs` |
| Agent declarations without delegation fields still load with an empty allow-list and no per-agent budget override, while declared delegation values survive Dhall loading | `shikigami-core/test/Shikigami/AgentLoaderSpec.hs` |
| A Baikai in-band provider failure is a failure, with its retryability preserved, rather than an empty successful reply | `shikigami-core/test/Shikigami/BehaviorProviderSpec.hs` |
| A fresh database applies all four migration components and re-applying is a no-op | `shikigami-migrations/test/Migrate.hs` |

Wire fixtures are **literals**, deliberately: encoding a fixture with the current
encoder would pass even if the encoder changed. Plan 65 preserves unrelated
sink and journal wire contracts, and explicitly replaces only the verified
unused RunJob and workflow baseline. RunJob now requires all twelve fields,
including nullable lineage fields; no bare-envelope fallback or inferred route
remains. Agent names, run keys, delegation depth and evidence quantities retain
nominal types internally and unwrap only at their owning external boundaries.


## Resolved evidence

Toolchain: GHC 9.12.4 inside the Nix dev shell.

```bash
$ nix develop --command cabal build all --dry-run
Build profile: -w ghc-9.12.4 -O1
```

The plan selects exactly the pinned and transitive versions in the matrix
above, including Kioku 0.5.2.0, Shikumi 0.3.0.3, Baikai 0.6.0.0,
`http-client-tls` 0.4.0, both Keiki packages at 0.9.1.0, and
`kafka-effectful` 0.3.0.0 from Hackage. The temporary TLS metadata exceptions
are listed under Current release status; `haxl:time` remains the only unrelated
exception.

```bash
$ nix develop --command cabal test all -j1
keiro-shikigami-conformance PASS   30 checks
shikigami-agent-test        PASS   29 tests
shikigami-api-test          PASS   15 tests
shikigami-client-test       PASS    3 tests
shikigami-core-test         PASS  599 tests
shikigami-migrations-smoke  PASS    2 tests
shikigami-migrations-test   PASS    5 tests
shikigami-server-test       PASS   46 tests
shikigami-workers-test      PASS   81 tests
```

810 checks across nine Shikigami suites passed on 2026-08-29 with Kioku 0.5.1.0,
Shikumi 0.3.0.3, Baikai 0.6.0.0, and `http-client-tls` 0.4.0 selected. The two
sibling Kikan-En package suites also passed.

Run the suites with `-j1`. Under `-j`, the database-backed suites each stand up
an ephemeral PostgreSQL and contend, which makes `shikigami-core-test` fail
intermittently. The 810-check run above is historical August evidence. Plan 65 splits core
unit, PostgreSQL, domain and diagram suites; each PostgreSQL example clones its
suite's migrated template through migrations:test-support.


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

**baikai 0.6 hid evolvable record constructors.** Shikigami moved its stub provider and tests
to `emptyModel`, `emptyResponse`, and `apiProviderWith`; evidence consumers now use selectors
and generic lenses rather than matching the hidden `EvidenceRequest` and `ModelCallEvidence`
constructors. The schema-major evidence fixtures moved from 1.0 to 2.0. The new sampling-drop
adjustments deliberately do not produce `ProhibitedEffortClamping`, because Baikai marks them
as unrelated to thinking strength.

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

The former Baikai fixture deprecations no longer survive: 0.6 removed `_Model`, `_Response`,
and `_Context`, and Shikigami now uses the supported empty values and builders.


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

Kioku 0.5.1.0 is a bounds/API-adaptation release and adds no migration, so those counts and the
0.5.0.0 ledger re-baseline procedure remain unchanged.

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


## Plan 65 final qualification — 2026-09-07

`cabal build all --enable-tests -j1 --ghc-options=-fmax-errors=10000` passes
for every library, executable and test target. The built suites run serially
from their owning package directories, with `--num-threads=1` for Tasty and
`+RTS -N2 -RTS` for threaded core/database/server/worker suites. The complete
result is [final-suites.json](evidence/plan-65/final-suites.json).

| Suite | Passing checks |
|---|---:|
| conformance | 37 |
| kikan-en-client-tests | custom driver; PASS |
| kikan-en-contract-tests | custom driver; PASS |
| shikigami-agent-test | 29 |
| shikigami-api-test | 15 |
| shikigami-client-test | 3 |
| shikigami-core-diagrams-test | 4 |
| shikigami-core-domain-test | 13 |
| shikigami-core-postgres-test | 197 |
| shikigami-core-test | 405 |
| shikigami-migrations-smoke | 8 |
| shikigami-migrations-test | 5 |
| shikigami-server-test | 46 |
| shikigami-workers-test | 85 |

There are 797 Tasty tests, 13 domain assertions and 37 generated conformance
checks (847 counted checks), plus both custom Kikan-En dependency drivers.
The three assembled PostgreSQL scenarios are included in those counts.
The domain report has 56 filled obligations: 50 verified and six unverified
with passing witnesses. Missing, pending, duplicate, stale and failed sets are
empty. No fabricated totality or rich-payload replay claim is needed.

Runtime entry points verify migrations read-only before startup, then register
the validated evidence catalog. The generated run-job codec/policy, bounded
resume registry, batched timer routing and terminal GC policy execute through
their production owners. See the [domain inventory](architecture/shikigami-domain-inventory.md)
and [runtime ADR](adr/0038-runtime-startup-and-maintenance-share-validated-owners.md).

`just keiro-gate 8b0a98a` passes unmodified: strict Language 5 checks, deterministic
regeneration, no compatibility findings, replay-neutral impact and all 37
conformance checks. The [final gate report](evidence/plan-65/final-gate-diff.json)
records this exact source/acceptance baseline. A separate deliberately incompatible
fixture still fails the differ with `WorkflowBodyChanged`.
