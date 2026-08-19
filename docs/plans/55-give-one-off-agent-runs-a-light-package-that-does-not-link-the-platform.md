---
id: 55
slug: give-one-off-agent-runs-a-light-package-that-does-not-link-the-platform
title: "Give one-off agent runs a light package that does not link the platform"
kind: exec-plan
created_at: 2026-08-19T16:37:01Z
intention: "intention_01kyv7saq6ew2a2k5vw230pw1f"
master_plan: "docs/masterplans/2-production-reality-de-stub-the-runtime-behavior-and-integration-path.md"
---

# Give one-off agent runs a light package that does not link the platform

This ExecPlan is a living document. The sections Progress, Surprises & Discoveries,
Decision Log, and Outcomes & Retrospective must be kept up to date as work proceeds.
If durable project context changes, update or create ADRs in docs/adr/ in the same change.


## Purpose / Big Picture

Shikigami is meant to be usable in two ways. One is the deployed service: a server, background
workers, Kafka, PGMQ, Postgres, and the Kikan platform around it. The other is a **one-off
agent run** — someone who is *not* running Kikan takes a declared agent and runs it against a
payload or a repository, once, from a command line. The second use case is what makes the
package versatile to consumers with simpler needs, and Kikan itself does not use it.

Today that second use case technically works and is expensive for no reason. Both of its
commands live in `shikigami-workers`, whose library links `hw-kafka-client`,
`kafka-effectful`, `pgmq-effectful`, `shibuya-pgmq-adapter`,
`hs-opentelemetry-exporter-otlp`, `hs-opentelemetry-sdk`, `baikai-trace-otel`, and `async`.
Every executable in that package is `build-depends: base, optparse-applicative,
shikigami-workers`, so all of it is linked into all of them — including
`shikigami-run-behavior`, whose own documentation says it "opens no database and joins no
queue". `hw-kafka-client` binds `librdkafka`, a C library, which is why a bare
`cabal build all` in this repository fails at link with `ld: library not found for -lrdkafka`
unless it runs inside the Nix dev shell. A consumer who wants to run one agent should not have
to acquire a Kafka C library to do it.

After this change there is a seventh Cabal package, **`shikigami-agent`**, that depends on
`shikigami-core` and nothing else, and owns the one-off commands. A consumer can build it
without any of the eight platform dependencies above:

```bash
cd /Users/shinzui/Keikaku/bokuno/shikigami
nix develop -c cabal build shikigami-agent --dry-run
```

and see a build plan containing no `hw-kafka-client`, no `kafka-effectful`, no
`pgmq-effectful`, no `shibuya-pgmq-adapter`, no `hs-opentelemetry-sdk`, and no
`hs-opentelemetry-exporter-otlp`. `cabal run shikigami-run-behavior -- --help` and
`cabal run shikigami-agent-run -- --help` behave exactly as they do now, from the new package.

This also gives `docs/plans/48-add-a-portable-one-off-repository-agent-harness.md` an honest
home. Plan 48's Purpose says its `shikigami-run` command "never dispatches the declaration's
sinks, never starts a trigger, and never opens Kioku or PostgreSQL", and then places its
executable in the workers package — which would ship a binary that links PGMQ and Kafka to
prove it does not use them. After this plan, plan 48's executable belongs in `shikigami-agent`.


## Progress

Use a checklist to summarize granular steps. Every stopping point must be documented here,
even if it requires splitting a partially completed task into two ("done" vs. "remaining").
This section must always reflect the actual current state of the work.

- [x] (2026-08-19) M1: created `shikigami-agent/` with a library depending only on
      `shikigami-core`, moved both command modules into it as `Shikigami.Agent.Command.*`, added
      `Shikigami.Agent.Command` as the composition module, moved both executables, and added the
      package to `cabal.project`. `git` recorded all four moves as renames.
- [x] (2026-08-19) M1: `RoleInfo` and `runRole` moved to a new `Shikigami.App.Role` in
      `shikigami-core` rather than being duplicated — see the Decision Log. `shikigami-workers`
      now imports them, and `WorkerRoleInfo` is gone.
- [x] (2026-08-19) M1: the dependency win is proven. `cabal build shikigami-agent --dry-run`
      names none of `hw-kafka-client`, `kafka-effectful`, `pgmq-effectful`,
      `shibuya-pgmq-adapter`, `hs-opentelemetry-sdk`, `hs-opentelemetry-exporter-otlp`,
      `baikai-trace-otel`, or `shikigami-workers`. `cabal build all` and `cabal test all -j1`
      are green: nine suites, including the new `shikigami-agent-test`.
- [x] (2026-08-19) M2: extended `Shikigami.PackageArchitectureSpec` — seven expected packages,
      `shikigami-agent -> shikigami-core`, `forbiddenInCore` generalised to
      `forbiddenInLightPackages` over a `lightPackages` list, and a new case: **every executable
      links only its own package's library**. All three were mutation-tested and each fails on
      its own fault.
- [x] (2026-08-19) M3: updated `docs/architecture/packages.md` — a new "Two ways to use
      Shikigami" section states the one-off mode as a **constraint** rather than leaving it
      implicit, the package table and arrow list gain `shikigami-agent`, the executable-ownership
      table re-points both commands, the composition allowlist gains `Shikigami.App.Role` and
      `Shikigami.Agent.Command.*`, and the "no umbrella dispatcher" paragraph now explains why
      `shikigami-agent` is neither an umbrella nor a utility package.
- [x] (2026-08-19) M3: revised plan 36 with a reconciliation section. Its architectural
      judgement stands and is explicitly not reversed; what it missed was the product intent,
      which was written down nowhere.
- [x] (2026-08-19) M3: revised plan 48 — `shikigami-run` targets `shikigami-agent`, with a
      reconciliation section covering the now-enforced boundary and the shared
      `Shikigami.App.Role.runRole`.
- [x] (2026-08-19) M3: wrote
      `docs/adr/0003-a-seventh-package-keeps-one-off-agent-runs-light.md` and updated
      `docs/architecture/implementation-order.md`.


## Surprises & Discoveries

Document unexpected behaviors, bugs, optimizations, or insights discovered during
implementation. Provide concise evidence.

**The one-off commands were never coupled to the platform; their dispatcher was** (found
2026-08-19, before implementation). `shikigami-workers/src/Shikigami/Workers/Command/RunBehavior.hs`
imports only `shikigami-core` modules — `Shikigami.Agent.Loader`, `Shikigami.App.Config`,
`Shikigami.Behavior.Provider`, `Shikigami.Behavior.Run`, `Shikigami.Log`. `AgentRun.hs` adds
only `Kioku.App`, `Kioku.Id`, and `Kiroku.Store.Connection`, which it genuinely needs because
it drives a kioku session. Neither touches Kafka, PGMQ, Shibuya, or OpenTelemetry.

The coupling is one module. `shikigami-workers/src/Shikigami/Workers/Command.hs` imports
`Shikigami.Workers.Command.AgentRun`, `.RunBehavior`, `.Scheduler`, `.Worker`, and
`Shikigami.Workers.Subscription` together, so the package that contains the light commands also
contains the heavy loops, and every executable links the union.

That is the same shape as the umbrella dispatcher plan 36 deleted `shikigami-cli` for — moved
down one level, from between packages to inside one, where it stopped being visible.
`Shikigami.PackageArchitectureSpec` cannot see it either: it checks which *siblings* a library
declares, not what an *executable* drags in.


## Decision Log

Record every decision made while working on the plan.

- Decision (2026-08-19): **Add a seventh package rather than splitting the dispatcher in
  place.** Two options were weighed. Splitting `Shikigami.Workers.Command` in two and pointing
  the light executables at `shikigami-core` is cheaper and needs no divergence from the fleet
  standard, but it leaves the one-off binaries in a package named for supervised background
  loops, and nothing prevents the coupling returning the next time someone adds an import to a
  shared command module. A package boundary is the only mechanism Cabal actually enforces, and
  the whole reason plan 36 moved to packages was that "Cabal, not convention, enforces the
  arrows" (`docs/architecture/packages.md:12-17`). The capability being protected is a product
  property — versatility for consumers who are not running Kikan — so it should be protected by
  the strongest available mechanism, not by a filing convention.

- Decision (2026-08-19): **Name it `shikigami-agent`, and put its modules under
  `Shikigami.Agent.Command.*`.** The concern raised when choosing the name was that
  `Shikigami.Agent.*` is already the agent vertical in `shikigami-core`. On inspection that is
  not a collision but the documented convention: `docs/architecture/packages.md:90-93` says a
  module "lands in the package that owns its *runtime role*, and keeps the module name of its
  *concept*", and gives `Shikigami.Trigger.*` spanning core and workers as the worked example.
  The Agent vertical spanning core and `shikigami-agent` is the same pattern, and
  `<Package>.Command` / `<Package>.Command.*` is the established name for a package's
  option-parser composition modules (`packages.md:102-108`). The leaf names `RunBehavior` and
  `AgentRun` are kept so the diff stays a move.

- Decision (2026-08-19): **Diverge from the fleet's six-package standard, deliberately and in
  writing.** `mori://shinzui/keiro-runtime-patterns/docs/architecture-service-packages` opens
  with "A deployed keiro service is exactly six cabal packages with explicit dependency
  budgets." This adds a seventh. The divergence is recorded because the standard's own purpose
  — keeping "domain decisions, HTTP types, HTTP execution, background processing, schema
  installation, and client consumption independently buildable" — is what this package serves
  rather than violates: it adds a *lighter* leaf under core, not another edge between existing
  packages. The objection that retired `shikigami-cli` was that it depended on
  `shikigami-server` **and** `shikigami-workers`; a package depending only on `shikigami-core`
  raises none of it. The standard also does not contemplate a service that is deliberately
  usable outside its own platform, which is the property being preserved.

- Decision (2026-08-19, taken during Milestone 1): **Move `RoleInfo` and `runRole` to
  `Shikigami.App.Role` in `shikigami-core` rather than duplicating them.** The plan left this
  open ("duplicating a fifteen-line helper is acceptable; duplicating configuration resolution
  is not"), and on reading `Shikigami.Workers.Command` it is the second: `runRole` calls
  `runAppConfig`, so it *is* the resolution order — parse, resolve, act — and that ordering is
  what makes `--check-config` honest, per that module's own haddock. Two copies could disagree
  about when required-key checking runs relative to the action opening a database or joining a
  consumer group. `Shikigami.App.Role` joins the composition-name allowlist beside
  `Shikigami.App.Config`, for the same stated reason: every executable in every package
  resolves settings the same way. The type is renamed from `WorkerRoleInfo` to `RoleInfo` now
  that it is not worker-specific.

- Decision (2026-08-19): **`shikigami-agent-run` keeps its database dependency and stays in the
  new package anyway.** It opens a kioku session and therefore needs `hasql`, `hasql-pool`, and
  `kiroku-store`, all of which `shikigami-core` already carries. "Light" here means *does not
  link the platform's messaging, queueing, and telemetry export stack*, not *has no
  dependencies*. Splitting the two commands across two packages by database use would trade a
  real boundary for a cosmetic one.


## Outcomes & Retrospective

### What a consumer can do now (2026-08-19)

`shikigami-agent` depends on `shikigami-core` and nothing else, and owns both one-off
executables. The dependency win is checkable in one command:

```text
$ cabal build shikigami-agent --dry-run | grep -E 'kafka|pgmq|otlp|shibuya|workers'
$ echo $?
1                                  # nothing matched
```

Eight packages dropped off the path for a one-off run — `hw-kafka-client`, `kafka-effectful`,
`pgmq-effectful`, `shibuya-pgmq-adapter`, `hs-opentelemetry-sdk`,
`hs-opentelemetry-exporter-otlp`, `baikai-trace-otel`, and `async`. The first matters most to
the consumer this mode exists for: `librdkafka` is a C library, and building it was previously a
precondition for running one agent once.

Nine test suites pass, including a new `shikigami-agent-test` that mirrors
`Shikigami.Workers.CommandSpec` so the diagnostic flags stay identical across packages.

### The part that outlives the package

`Shikigami.PackageArchitectureSpec` gained the rule that **every executable links only its own
package's library**. That is the check that would have caught the original regression, and its
absence is why the regression survived a test suite written to prevent exactly this class of
problem: the old rule looked at what a *library* declares, so it structurally could not see
coupling that lived inside a package rather than between two. All three new assertions were
mutation-tested rather than assumed.

The other durable output is a sentence in `docs/architecture/packages.md` saying what
`shikigami-agent` is *for*. Plan 36's reasoning was sound and its outcome removed a capability,
because the capability's rationale lived in someone's head rather than in the repository.

### Lessons

**A dependency graph describes what a package *is*, never what it is *for*.** Plan 36 read
`shikigami-cli` correctly as an umbrella dispatcher and deleted it correctly on that reading.
Nothing in the repository could have told it the package also served consumers who are not
running the platform. The fix is not more careful reading; it is writing the purpose down where
the architecture is described.

**A boundary that a test cannot see is a convention.** The two one-off commands were never
coupled to Kafka or PGMQ — their imports prove it — but they linked both for three weeks,
because the coupling was one composition module inside a package whose executables all depend on
the whole library. `PackageArchitectureSpec` existed the entire time and was blind to it.

**The same mistake recurs one level down.** Plan 36 removed an umbrella dispatcher that spanned
four packages and recreated a smaller one inside `shikigami-workers`. Worth watching for
whenever a structural fix moves a problem rather than dissolving it.


## Context and Orientation

All paths are relative to the repository root `/Users/shinzui/Keikaku/bokuno/shikigami`.

### What exists today

The repository has six Cabal packages, listed in `cabal.project`'s `packages:` block:
`shikigami-api`, `shikigami-core`, `shikigami-client`, `shikigami-migrations`,
`shikigami-server`, `shikigami-workers`. `docs/architecture/packages.md` is the authoritative
statement of which package owns what; its header says it "is owned by
`docs/plans/36-align-shikigami-with-the-six-package-deployed-service-architecture.md`; change
it only through a plan revision", which is why this plan revises plan 36 rather than editing
that document alone.

A *package* here is a Cabal package, which is a compile-time dependency boundary: if
`shikigami-workers` does not list `shikigami-api` in `build-depends`, a worker module
physically cannot import an HTTP route type. The legal sibling edges today are exactly:

```text
shikigami-api     -> shikigami-core
shikigami-server  -> shikigami-core, shikigami-api
shikigami-workers -> shikigami-core
shikigami-client  -> shikigami-api
```

`shikigami-core` and `shikigami-migrations` depend on no sibling.

### The two commands this plan moves

`shikigami-workers` owns six executables. Four are long-running platform roles
(`shikigami-worker`, `shikigami-scheduler`, `shikigami-consume-stream`,
`shikigami-consume-events`). Two are one-off commands, and they are what this plan is about:

- **`shikigami-run-behavior`** — "Runs one agent's behavior with deterministic stubs (no
  database, no key)" (`docs/architecture/packages.md:131`). Implemented by
  `shikigami-workers/src/Shikigami/Workers/Command/RunBehavior.hs`, which imports only
  `shikigami-core` modules.
- **`shikigami-agent-run`** — "Runs one agent through the kioku session/memory lifecycle"
  (`packages.md:132`). Implemented by
  `shikigami-workers/src/Shikigami/Workers/Command/AgentRun.hs`, which imports `shikigami-core`
  plus `Kioku.App`, `Kioku.Id`, and `Kiroku.Store.Connection`.

Both are reached through `shikigami-workers/src/Shikigami/Workers/Command.hs`, a composition
module that also imports the scheduler, worker, and Kafka subscription commands. Each
executable's stanza is:

```cabal
executable shikigami-run-behavior
  main-is:        Main.hs
  hs-source-dirs: app/run-behavior
  build-depends:
    , base
    , optparse-applicative
    , shikigami-workers
```

so the binary links the whole `shikigami-workers` library.

### The eight dependencies that do not belong in a one-off run

Comparing the two libraries' `build-depends`, `shikigami-workers` carries these and
`shikigami-core` does not:

| Package | Why it is platform-only |
|---|---|
| `hw-kafka-client` | Kafka client; binds the `librdkafka` C library |
| `kafka-effectful` | the `activity.v1` stream consumer effect |
| `pgmq-effectful` | the PGMQ queue effect interpreter |
| `shibuya-pgmq-adapter` | the supervised queue adapter |
| `hs-opentelemetry-sdk` | tracer provider, an executable-boundary concern |
| `hs-opentelemetry-exporter-otlp` | OTLP exporter, likewise |
| `baikai-trace-otel` | provider trace export |
| `async` | concurrent supervision of the worker loops |

`hw-kafka-client` is the expensive one for a consumer: `librdkafka` is a C library, and this
repository's own `docs/dependency-cohort.md` records that a bare `cabal build all` "compiles and
then fails at link with `ld: library not found for -lrdkafka`" outside the Nix dev shell.

Note what does **not** drop. `shikigami-core` still carries `hasql`, `hasql-pool`,
`pgmq-hasql`, `shibuya-core`, `kiroku-store`, `kioku-*`, `keiro`, `keiki`, `baikai`, `dhall`,
and `hs-opentelemetry-api`. This plan makes the one-off path *lighter*, not dependency-free;
making `shikigami-core` itself lighter is separate work that nothing currently plans.

### The existing architecture test

`shikigami-core/test/Shikigami/PackageArchitectureSpec.hs` parses the `.cabal` files as text
and enforces three things: that `cabal.project` builds exactly the expected package list, that
no production library depends on a forbidden sibling, and that `shikigami-core` does not link
any of a named list of runtime-role packages (`forbiddenInCore`, lines 64-75, which already
names `hw-kafka-client`, `kafka-effectful`, `pgmq-effectful`, `shibuya-pgmq-adapter`,
`hs-opentelemetry-sdk`, and `hs-opentelemetry-exporter-otlp` with reasons). It does **not**
check what an executable stanza depends on, which is exactly the gap that let this regression
exist inside a package.

### Relevant ADRs

`docs/adr/` exists and holds two records, both created 2026-08-19 by
`docs/plans/39-adopt-a-checked-keiro-dsl-specification-and-evolution-gate.md`:
[ADR 0001](../adr/0001-declare-only-what-the-runtime-executes.md) and
[ADR 0002](../adr/0002-generated-code-is-not-formatted.md). Neither covers package structure.
The corpus is plain Markdown — `mori.dhall` declares no OKF bundle for `docs/adr`, so records
carry no OKF frontmatter and no `docId`; see `docs/adr/README.md`. This plan adds ADR 0003.

### Why `shikigami-cli` was deleted, and what that missed

`shikigami-cli` was deleted by plan 36 in commit `b3b8024` (2026-07-30). Its `build-depends`
listed `shikigami-api`, `shikigami-core`, `shikigami-server`, **and** `shikigami-workers`, so
the single `shikigami` binary linked the HTTP server, the Kafka consumers, the OTel exporter,
and the worker loops together. Plan 36's Decision Log of 2026-07-22 rejected keeping it as a
seventh package on the grounds that "a single umbrella process dispatcher cannot honestly
import both server and worker implementation without violating the dependency graph". That
argument is correct and this plan does not disturb it.

What it missed is that `shikigami-cli` also carried a product intent — a one-off agent runner
for consumers who are not using the Kikan platform, deliberately not used by Kikan itself. That
intent appears nowhere in plan 36, in `docs/architecture/packages.md`, in any MasterPlan, or in
`docs/improvement-requests/`. Because it was never written down, the package read as pure
architecture and was removed as such. Recording it is part of this plan's Milestone 3, and is
the thing that stops the same deletion happening again.


## Plan of Work

**Milestone 1 — the package.** Create `shikigami-agent/` with a `library` stanza whose only
sibling dependency is `shikigami-core`, exposing `Shikigami.Agent.Command`,
`Shikigami.Agent.Command.RunBehavior`, and `Shikigami.Agent.Command.AgentRun`. Move the two
command modules from `shikigami-workers/src/Shikigami/Workers/Command/` unchanged except for
their `module` line and imports. Write `Shikigami.Agent.Command` as a new composition module
carrying only the two one-off parsers — model it on
`shikigami-workers/src/Shikigami/Workers/Command.hs`, which already exposes `runRole` and a
per-role `ParserInfo`, but do not import the scheduler, worker, or subscription commands.
Move `shikigami-workers/app/run-behavior/` and `app/agent-run/` to
`shikigami-agent/app/run-behavior/` and `app/agent-run/`, and move the two `executable` stanzas
across, changing `shikigami-workers` to `shikigami-agent` in their `build-depends`. Delete the
two moved modules and their two `other-modules`/`exposed-modules` entries from
`shikigami-workers.cabal`, and remove their imports from `Shikigami.Workers.Command`. Add
`shikigami-agent` to `cabal.project`'s `packages:` block. Copy the `common common` stanza from
`shikigami-core.cabal` so warnings and default extensions match. Acceptance: the dry-run plan
for `shikigami-agent` names none of the eight platform packages, and `cabal build all` and
`cabal test all -j1` are green.

**Milestone 2 — enforce it.** Extend `shikigami-core/test/Shikigami/PackageArchitectureSpec.hs`:
add `shikigami-agent` to `expectedPackages`, add `("shikigami-agent", ["shikigami-core"])` to
`allowedLibraryEdges`, and apply the existing `forbiddenInCore` list to `shikigami-agent` as
well as `shikigami-core` — rename it `forbiddenInLightPackages` and take the package list as
data. Then add the case that would have caught the original regression: for each executable
stanza in each package, assert that it does not `build-depends` on a sibling library whose
transitive dependency set includes a package forbidden to that executable's role. The
pragmatic version, given the text parser already in that module, is narrower and sufficient:
assert that **every executable in `shikigami-agent` depends only on `shikigami-agent`,
`base`, and `optparse-applicative`**, and that **no executable in any package depends on more
than one sibling library**. Acceptance: both new cases pass, and each fails when the
corresponding fault is introduced by hand — verify that explicitly, do not assume it.

**Milestone 3 — record it.** Revise `docs/architecture/packages.md`: the package table gains a
seventh row, the arrow list gains `shikigami-agent -> shikigami-core`, the executable-ownership
table moves `shikigami-run-behavior` and `shikigami-agent-run` to the new package, the module
placement allowlist gains `Shikigami.Agent.Command` and `Shikigami.Agent.Command.*`, and the
"There is no umbrella dispatcher binary and no utility package" paragraph is corrected — the
first clause stands, the second no longer does, and the paragraph must say why the two are
different. Add a short section stating the one-off consumer use case as a requirement, so the
next architecture change has to argue against it explicitly. Revise plan 36 with a dated
section recording what its Decision Log missed. Revise plan 48 to own `shikigami-run` from
`shikigami-agent`. Write `docs/adr/0003-a-seventh-package-keeps-one-off-agent-runs-light.md`.
Update `docs/architecture/implementation-order.md`: the package count, the plan-48 entry, and a
note in the update table.


## Concrete Steps

Run from `/Users/shinzui/Keikaku/bokuno/shikigami`. Every build and test command must run
inside the Nix dev shell, because the rest of the repository still links `librdkafka`.

```bash
nix develop

# M1
mkdir -p shikigami-agent/src/Shikigami/Agent/Command shikigami-agent/app/run-behavior shikigami-agent/app/agent-run
git mv shikigami-workers/src/Shikigami/Workers/Command/RunBehavior.hs shikigami-agent/src/Shikigami/Agent/Command/RunBehavior.hs
git mv shikigami-workers/src/Shikigami/Workers/Command/AgentRun.hs    shikigami-agent/src/Shikigami/Agent/Command/AgentRun.hs
git mv shikigami-workers/app/run-behavior/Main.hs shikigami-agent/app/run-behavior/Main.hs
git mv shikigami-workers/app/agent-run/Main.hs    shikigami-agent/app/agent-run/Main.hs
# then write shikigami-agent/shikigami-agent.cabal and Shikigami/Agent/Command.hs by hand,
# and edit shikigami-workers.cabal, Shikigami/Workers/Command.hs, and cabal.project.

cabal build shikigami-agent --dry-run
cabal build all
cabal test all -j1

# M2
cabal test shikigami-core:shikigami-core-test

# M3 — no commands; documentation only.
```

The dependency win is the acceptance evidence for Milestone 1. Expect the dry-run plan to
contain none of these:

```text
hw-kafka-client  kafka-effectful  pgmq-effectful  shibuya-pgmq-adapter
hs-opentelemetry-sdk  hs-opentelemetry-exporter-otlp  baikai-trace-otel  async
```

Check it mechanically rather than by eye:

```bash
cabal build shikigami-agent --dry-run 2>&1 \
  | grep -E 'hw-kafka-client|kafka-effectful|pgmq-effectful|shibuya-pgmq-adapter|opentelemetry-sdk|exporter-otlp|baikai-trace-otel' \
  && echo "FAIL: a platform dependency reached shikigami-agent" \
  || echo "OK: no platform dependency in the shikigami-agent plan"
```


## Validation and Acceptance

Acceptance is behavioral and has four parts.

**The commands still work, identically.** `cabal run shikigami-run-behavior -- --help` and
`cabal run shikigami-agent-run -- --help` render the same flags they render today, from the new
package. `shikigami-workers`'s existing per-command `--help` smoke tests move with the
commands; the workers test suite keeps its four remaining role tests and the agent test suite
gains two.

**The dependency win is real.** The grep above prints `OK`. Additionally,
`cabal build shikigami-agent --dry-run` must not name `shikigami-workers` at all.

**The boundary is enforced, not documented.** Introduce each fault by hand and confirm the
matching test fails, then revert it:

1. Add `, shikigami-workers` to `shikigami-agent`'s library `build-depends` → "no production
   library depends on a forbidden sibling" fails.
2. Add `, hw-kafka-client` to `shikigami-agent`'s library `build-depends` → the
   forbidden-package case fails naming `shikigami-agent`.
3. Point the `shikigami-run-behavior` executable at `shikigami-workers` → the new
   executable-weight case fails.

**Nothing else moved.** `cabal test all -j1` passes all eight suites, and
`git diff --stat` shows the two command modules as renames rather than rewrites.


## Idempotence and Recovery

Milestone 1 is a file move plus Cabal edits; it is safe to repeat and trivially revertible with
`git checkout`. Nothing touches a database, a queue, or any persisted identity — no workflow
name, step name, queue name, or wire format changes, so
`domain/shikigami.keiro-workspace` and the generated layer under
`shikigami-core/src/Shikigami/*/Generated/` are untouched and `just keiro-gate` is unaffected.
Run it once at the end anyway to prove that.

The one irreversible-feeling step is deleting the two modules from `shikigami-workers`; do it in
the same commit as the move so `git mv` records a rename and history follows the file. If a
`cabal build` fails partway, the tree is still consistent: no generated artifact and no
committed ledger depends on package membership.

Do the milestones in order and commit each. Milestone 2's tests will fail until Milestone 1
lands, which is the correct dependency; do not weaken a test to make an intermediate commit
green.


## Interfaces and Dependencies

`shikigami-agent/shikigami-agent.cabal` declares one library and two executables. Its library
`build-depends` is the subset of `shikigami-core`'s that the two moved modules actually use,
plus `shikigami-core` itself:

```cabal
library
  hs-source-dirs:  src
  exposed-modules:
    Shikigami.Agent.Command
    Shikigami.Agent.Command.AgentRun
    Shikigami.Agent.Command.RunBehavior
  build-depends:
    , aeson
    , base
    , kioku-api
    , kioku-core
    , kiroku-store
    , optparse-applicative
    , settei
    , settei-optparse-applicative
    , shikigami-core
    , text
```

Confirm that list against the modules' actual imports rather than copying it; `AgentRun.hs`
needs `Kioku.App`, `Kioku.Id`, and `Kiroku.Store.Connection`, and `RunBehavior.hs` needs none of
them.

The composition module keeps the shape `Shikigami.Workers.Command` already uses, so the moved
`app/*/Main.hs` files change only their import:

```haskell
-- shikigami-agent/src/Shikigami/Agent/Command.hs
module Shikigami.Agent.Command
  ( runRole,
    RoleInfo,
    agentRunRoleInfo,
    runBehaviorRoleInfo,
  )
where
```

`shikigami-workers` keeps `runRole` and its four platform roles. If `runRole` and `RoleInfo`
are genuinely shared scaffolding rather than duplicated, move them to `shikigami-core` under an
allowlisted composition name and have both packages import them; decide that during Milestone 1
by reading `shikigami-workers/src/Shikigami/Workers/Command.hs` and record the choice in the
Decision Log. Duplicating a fifteen-line helper is acceptable; duplicating configuration
resolution is not, and `Shikigami.App.Config` already lives in core precisely so that every
executable in every package resolves settings the same way.

This plan hard-depends on nothing and blocks nothing, but it should land **before**
`docs/plans/48-add-a-portable-one-off-repository-agent-harness.md`, which otherwise builds its
portable harness inside the package this plan exists to move it out of.
