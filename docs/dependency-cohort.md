# Dependency cohort — July 2026

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

Every row below is resolved from Hackage. "Was" is the version selected by the
pre-upgrade commit-pinned `cabal.project`.

| Package | Was | Now | Upstream tag | Tag commit |
|---|---|---|---|---|
| `keiki` | 0.1.0.0 | **0.4.0.0** | `v0.4.0.0` | `6807aac817fe53bbcc1b11b9e1a1b226bae14413` |
| `keiki-codec-json` | 0.1.0.0 | **0.4.0.0** | `v0.4.0.0` | `6807aac817fe53bbcc1b11b9e1a1b226bae14413` |
| `keiro` | 0.1.0.0 | **0.4.0.1** | `keiro-0.4.0.1` | `ad9f4c0371763616d1a96fd63b712d4061415175` |
| `keiro-core` | 0.1.0.0 | **0.4.0.1** | `keiro-core-0.4.0.1` | `ad9f4c0371763616d1a96fd63b712d4061415175` |
| `keiro-migrations` | 0.1.0.0 | **0.4.0.1** | `keiro-migrations-0.4.0.1` | `ad9f4c0371763616d1a96fd63b712d4061415175` |
| `kioku-api` | 0.1.0.0 | **0.2.0.0** | `v0.2.0.0` | `5765f98add2a87a356c70793a6ba54375ef5feec` |
| `kioku-core` | 0.1.0.0 | **0.2.0.0** | `v0.2.0.0` | `5765f98add2a87a356c70793a6ba54375ef5feec` |
| `kioku-migrations` | 0.1.0.0 | **0.2.0.0** | `v0.2.0.0` | `5765f98add2a87a356c70793a6ba54375ef5feec` |
| `shikumi` | 0.1.0.1 | **0.3.0.1** | `shikumi-0.3.0.1` | `580b6c70a58bc96a8d52502c2e7c9376d2c46a15` |
| `shikumi-trace` | 0.1.0.1 | **0.2.0.1** | `shikumi-trace-0.2.0.1` | `580b6c70a58bc96a8d52502c2e7c9376d2c46a15` |
| `shikumi-eval` | 0.1.0.1 | **0.2.0.1** | `shikumi-eval-0.2.0.1` | `580b6c70a58bc96a8d52502c2e7c9376d2c46a15` |
| `shikumi-cache` | 0.1.0.1 | **0.1.2.1** | `shikumi-cache-0.1.2.1` | `580b6c70a58bc96a8d52502c2e7c9376d2c46a15` |
| `shikumi-trace-otel` | 0.1.0.0 | **0.1.1.0** | `shikumi-trace-otel-0.1.1.0` | `580b6c70a58bc96a8d52502c2e7c9376d2c46a15` |
| `baikai` | 0.2.0.0 | **0.4.1.0** | `baikai-0.4.1.0` | `62e1d919def1c02023b14dfba567922347bbfe83` |
| `baikai-claude` | 0.2.0.0 | **0.4.0.1** | `baikai-claude-0.4.0.1` | `97fa0d5727128f567a40b190dc7a657670fb03a4` |
| `baikai-effectful` | 0.2.0.0 | **0.3.0.2** | `baikai-effectful-0.3.0.2` | `62e1d919def1c02023b14dfba567922347bbfe83` |
| `baikai-trace-otel` | 0.2.0.0 | **0.3.0.2** | `baikai-trace-otel-0.3.0.2` | `62e1d919def1c02023b14dfba567922347bbfe83` |
| `baikai-openai` | 0.2.0.0 | **0.4.0.0** | `baikai-openai-0.4.0.0` | `62e1d919def1c02023b14dfba567922347bbfe83` |
| `shibuya-core` | 0.7.1.0 | **0.8.0.1** | `v0.8.0.1` | `172df245f40a454af46dd7f4cde855eaa4414c5a` |
| `shibuya-pgmq-adapter` | 0.8.0.0 | **0.12.0.0** | `v0.12.0.0` | `85931b45702faecc035d89bb5cff381e8679f793` |
| `shibuya-kiroku-adapter` | 0.4.0.0 | 0.4.0.0 | `shibuya-kiroku-adapter-v0.4.0.0` | (unchanged) |
| `kiroku-store` | 0.2.1.0 | **0.3.1.0** | `kiroku-store-v0.3.1.0` | `3009dda7238f7d05b1d0c97b04ec5d4c55031304` |
| `kiroku-store-migrations` | 0.1.1.0 | **0.3.0.0** | `kiroku-store-migrations-v0.3.0.0` | `3009dda7238f7d05b1d0c97b04ec5d4c55031304` |
| `pgmq-core` / `-hasql` / `-effectful` | 0.3.0.0 | **0.4.0.1** | `v0.4.0.1` | `f4a101843ea6f5c055277fd84859ece02865eff4` |
| `pg-migrate` (+ `-cli`, `-embed`, `-import-codd`, `-test-support`) | — | **1.1.0.0** | `v1.1.0.0` | `f39d64e354818999667d345a1452f33eb4857fc1` |
| `ephemeral-pg` | 0.2.1.0 (fork pin) | **0.2.2.0** | Hackage | — |
| `settei` (+ `-env`, `-yaml`, `-optparse-applicative`) | 0.2.0.0 | 0.2.0.0 | `v0.2.0.0` | `1bf62b0af110b4f42fe2528e9d459e0ccf12d626` |
| `servant-health` | 0.1.0.0 | 0.1.0.0 | `v0.1.0.0` | `c70bffdd59e9336700dde304dac1328d3cb62f6a` |
| `hs-opentelemetry-*` | 1.0.0.0 | 1.0.0.0 | Hackage (third party) | — |

`keiro-pgmq` and `pgmq-migration` leave the build plan: `kioku-migrations 0.2.0.0`
composes its migrations through `pg-migrate` rather than the legacy PGMQ
migration path, and nothing else pulled them in.

`kiroku-test-support` also leaves the plan. It was pinned but had no reverse
dependency; the shikigami test suites use `shikigami-migrations:test-support`
and `codd-extras:ephemeral` instead.


## Packages still resolved from Git

| Package | Reason | Retires when |
|---|---|---|
| `handan-core` | No Hackage release. Typed-program runtime behind `Shikigami.Behavior.Run` and `Shikigami.Program.Registry`. | Handan publishes. |
| `kafka-effectful` | No Hackage release. `activity.v1` stream consumer. | It publishes. |
| `danwa-core`, `danwa-api`, `danwa-client` | No Hackage release. Conversation substrate behind the `DanwaConversation` sink. | Danwa publishes. |
| `codd`, `hasql-migration`, `hasql-notifications` | Forks carried for the current codd migration path. | `docs/plans/38-migrate-shikigami-database-evolution-from-codd-to-pg-migrate.md` completes the pg-migrate cutover. |

`codd-extras` is a sibling path package added by `cabal.project.local`; it is not
part of this cohort and retires with codd.


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
