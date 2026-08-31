---
id: 65
slug: migrate-shikigami-to-the-keiro-0-15-cohort-and-the-idiomatic-v2-record-model
title: "Migrate Shikigami to the keiro 0.15 cohort and the idiomatic-v2 record model"
kind: exec-plan
created_at: 2026-08-31T10:30:57Z
intention: "intention_01m1bntpmbeqet1597zr91ej43"
---

# Migrate Shikigami to the keiro 0.15 cohort and the idiomatic-v2 record model

This ExecPlan is a living document. The sections Progress, Surprises & Discoveries,
Decision Log, and Outcomes & Retrospective must be kept up to date as work proceeds.
If durable project context changes, update or create ADRs in docs/adr/ in the same change.


## Purpose / Big Picture

Shikigami's durable workflow and aggregate identities are declared in a checked
specification under `domain/`, and a build-time tool called `keiro-dsl` turns that
specification into Haskell source under `shikigami-core/src`. Today Shikigami is pinned to
the `keiro` 0.14.0.0 release line. Keiro published 0.15.0.0 on 2026-08-30. After this plan,
Shikigami builds, tests, and scaffolds against that 0.15.0.0 line, and its generated Haskell
layer is written in the new presentation style that release introduces.

What a person can do afterwards that they cannot do today: run `just keiro-gate` and have it
pass against the current Keiro toolchain instead of a superseded one. Right now, running the
0.15.0.0 toolchain against this repository is impossible — the dependency solver refuses to
build it at all — and once that is unblocked, the toolchain refuses to scaffold until the
repository explicitly opts in to the new generated-code style. This plan clears both refusals
and leaves the gate green.

There is no user-visible behavior change in the running service. Keiro 0.15.0.0 does not
change any wire format, JSON key, SQL name, workflow identity, journal byte, or runtime
semantic. Its own release notes say so, and the runtime libraries themselves are republished
without functional change: `keiro-core` 0.15.0.0's changelog entry reads, in full, "No changes
this release." The entire substance of the release is a change to the *Haskell surface* that
`keiro-dsl` emits and consumes. That is why the proof of success in this plan is not a new
feature but an unchanged one: every existing test still passes, every persisted byte fixture
still matches, and the specification gate still reports the same identities — while the source
that produces them is written differently.

The cost is concentrated in one place and it is large. The new style removes record *selector
functions* — the ordinary Haskell functions like `failureKey someFailure` that read a field out
of a record — and replaces reading with dot syntax, `someFailure.key`. Turning that on is a
per-component switch, not a per-module one, so switching it on for the component that compiles
the generated modules switches it on for every record `shikigami-core` defines. That is 587
distinct field names, and an upper bound of roughly ten thousand places across all seven
packages where one of those names is applied as a function. This plan takes that cost
deliberately rather than working around it; the reasoning, and the alternatives that were
rejected, are in the Decision Log.


## Progress

Every stopping point is recorded here. Split a partially finished item into a "done" half and
a "remaining" half rather than leaving it ambiguous.

### Milestone 1 — Prove and record the cohort gate

- [ ] Reproduce the solver refusal for keiro 0.15.0.0 and capture the transcript.
- [ ] Add a "Pending adoption: the keiro 0.15 cohort" subsection to `docs/dependency-cohort.md`
      stating exactly what Kioku must publish.
- [ ] Commit with the `ExecPlan:` and `Intention:` trailers.

### Milestone 2 — Prepare hand-owned code for the record model (edition-neutral)

- [ ] Add `OverloadedRecordDot` to the `common common` stanza of all seven `.cabal` files.
- [ ] Rewrite `shikigami-core/src/Shikigami/RunEvidence/BehaviorHoles.hs` to read and build the
      generated behavior records positionally, so it compiles under both editions.
- [ ] `nix develop -c cabal build all` and `nix develop -c cabal test all -j1` are green.
- [ ] Commit.

### Milestone 3 — Take the lockstep 0.15 bump

- [ ] Confirm the Kioku release that admits keiro 0.15 is on Hackage.
- [ ] Move the six Keiro `constraints:` rows in `cabal.project` to `==0.15.0.0`.
- [ ] Move `keiro-migrations ^>=0.15.0.0` in `shikigami-migrations/shikigami-migrations.cabal`.
- [ ] Move `keiro ==0.15.0.0` and `keiro-ops ==0.15.0.0` in `shikigami-server/shikigami-server.cabal`.
- [ ] Decide the Danwa pin: move it if `mori://shinzui/danwa` ExecPlan 13 has landed, otherwise
      record the retirement condition and leave the commit alone.
- [ ] `nix develop -c cabal build all --dry-run` selects the 0.15.0.0 set; build and tests green.
- [ ] Capture the `just keiro-scaffold` edition refusal transcript; it is expected to fail here.
- [ ] Commit.

### Milestone 4 — Adopt idiomatic-v2 and the record model

- [ ] Ignore the edition backup directory in `.gitignore`.
- [ ] Run the explicit `--apply-generated-haskell-edition` scaffold.
- [ ] Paste the regenerated Cabal fragment's extensions into `shikigami-core.cabal`.
- [ ] Migrate `shikigami-core/src` off selector application (113 modules).
- [ ] Migrate `shikigami-core/test` (43 modules).
- [ ] Migrate `shikigami-workers` (28 modules).
- [ ] Migrate `shikigami-server` (32 modules).
- [ ] Migrate `shikigami-agent` (10 modules).
- [ ] Migrate `shikigami-api` (7 modules).
- [ ] Migrate `shikigami-migrations` (5 modules).
- [ ] Migrate `shikigami-client` (2 modules).
- [ ] Fix the 34 individually-exported selector names in 14 modules.
- [ ] Repoint `Shikigami.KeiroSpecificationSpec` and `Shikigami.PackageArchitectureSpec` if the
      parse assumptions moved.
- [ ] `just keiro-gate` passes end to end.
- [ ] Full serial test run green.
- [ ] Commit.

### Milestone 5 — Reconcile the surrounding contracts

- [ ] Update `docs/dependency-cohort.md`: matrix rows, upstream tags, evidence, cost section.
- [ ] Update `docs/architecture/packages.md` module-placement and record-model rules.
- [ ] Write `docs/adr/0037-*.md` recording the record-model decision.
- [ ] Remove the Milestone 1 pending-adoption subsection now that it has retired.
- [ ] Fill in Outcomes & Retrospective and commit.


## Surprises & Discoveries

Document unexpected behaviors, bugs, optimizations, or insights discovered during
implementation. Provide concise evidence.

Two findings from the research that preceded this plan are recorded up front because they
changed its shape.

**The 0.15 runtime bump is a no-op, and yet it is blocked.** Four of the six Keiro packages
Shikigami selects change nothing at all in 0.15.0.0. `keiro-core` and `keiro-migrations` say
"No changes this release"; `keiro`, `keiro-ops`, and `keiro-pgmq` changed only the bound on
`keiro-test-support` inside their own test-suite stanzas, which no library consumer sees. And
yet the solver refuses the upgrade outright, because Kioku's released metadata caps Keiro below
0.15. Reproduced on 2026-08-31 against a Hackage index at `2026-08-31T08:25:22Z`:

```text
$ nix develop -c cabal build all --dry-run --project-file=cabal.project.probe015
Resolving dependencies...
Error: [Cabal-7107]
Could not resolve dependencies:
[__0] trying: danwa-core-0.1.0.0 (user goal)
[__1] trying: keiro-0.15.0.0 (dependency of danwa-core)
[__2] trying: shikigami-agent-0.1.0.0 (user goal)
[__3] next goal: kioku-core (dependency of shikigami-agent)
[__3] rejecting: kioku-core-0.5.1.0 (conflict: keiro==0.15.0.0, kioku-core => keiro^>=0.14.0.0)
[__3] skipping: kioku-core; 0.5.0.0, 0.4.1.0, 0.4.0.0, 0.3.0.0, 0.2.0.0, 0.1.0.0 (has the same
      characteristics that caused the previous version to fail: excludes 'keiro' version 0.15.0.0)
[__3] fail (backjumping, conflict set: keiro, kioku-core, shikigami-agent)
```

`danwa-core` appears in that trace as the package that *accepted* keiro 0.15.0.0 — it declares
`keiro` with no version bound at all — not as a blocker. Danwa is separately being moved onto
this same cohort under `mori://shinzui/danwa` ExecPlan 13, "Upgrade Danwa to the released Keiro
0.15 cohort"; that work had not begun as of 2026-08-31 and, because the commit Shikigami pins
declares no Keiro bound, it neither blocks nor is blocked by this plan. It does mean the pin
should follow. The same probe with the Kioku bound
relaxed and Shikigami's own two bounds relaxed produces a complete, conflict-free plan selecting
`keiro-core-0.15.0.0`, `keiro-migrations-0.15.0.0`, `keiro-pgmq-0.15.0.0`, `keiro-0.15.0.0`, and
`keiro-ops-0.15.0.0` alongside the unchanged `kioku-core-0.5.1.0`. So exactly two released
Kioku libraries stand between this repository and the current Keiro.

**The v1 generated layer itself uses selector functions.** This is what forces the two halves of
Milestone 4 into a single commit. `shikigami-core/src/Shikigami/RunEvidence/Generated/BehaviorContract.hs`
at the current edition contains:

```haskell
    [ "key" .= unBehaviorKey (failureKey behaviorFailure)
    , "subject" .= failureSubject behaviorFailure
    , "code" .= failureCode behaviorFailure
    , "detail" .= failureDetail behaviorFailure
```

Those are selector applications inside a `-- @generated` file. Turning on `NoFieldSelectors`
for the stanza that compiles it therefore breaks it, and it must not be hand-edited — that is
the generated-code firewall recorded in [docs/adr/0002-generated-code-is-not-formatted.md](../adr/0002-generated-code-is-not-formatted.md).
The extension can only be switched on in the same change that replaces those bytes with
idiomatic-v2 output.


## Decision Log

- Decision: Treat the released Kioku bound as a hard prerequisite rather than routing around it
  with `allow-newer`.
  Rationale: Two independent sources forbid the workaround. `docs/dependency-cohort.md` rule 2
  says "No permanent `allow-newer` between co-developed packages. If two cohort members cannot
  agree, the fix is an upstream release or Hackage revision, not an unbounded solver override."
  Keiro's own published upgrade guidance for this exact edge is more specific still: "If another
  released package excludes the 0.15.0.0 bound, stop and report that solver conflict; do not use
  `allow-newer`, a git override, or a wider unsupported bound." The temptation here is unusually
  strong, because `keiro-core` 0.15.0.0 is functionally identical to 0.14.0.0 and an override
  would demonstrably work. It is still the wrong move: the bound is a true statement about which
  Keiro Kioku was compiled against, and overriding a true statement to save an upstream release
  is how a cohort stops meaning anything. Milestone 1 therefore records the gate and Milestone 3
  waits for it.
  Date: 2026-08-31

- Decision: Enable the idiomatic-v2 record model on `shikigami-core`'s existing shared library
  stanza and migrate every affected hand-written module, rather than isolating the generated
  layer in its own Cabal component.
  Rationale: This was put to the plan's owner with the measured cost of each option, and this
  is the option chosen. The rejected alternative was an internal sublibrary
  (`library keiro-generated` inside `shikigami-core.cabal`) carrying only the 18 generated
  modules and the one hand-owned hole module, with the four required extensions scoped to it;
  the main library would have depended on it and re-exported `Shikigami.Generated.Conformance`
  for the generated conformance runner. That would have confined the extension change to 19
  files. It was rejected in favour of one uniform record model across the package: a package in
  which some records have selectors and some do not is a package where every reader has to know
  which stanza a type came from. The second rejected alternative — enabling only
  `OverloadedRecordDot` and skipping `NoFieldSelectors`, deviating from the fragment keiro-dsl
  emits — was rejected because it is a silent trap: it compiles today and breaks the first time
  a generated module declares a field and a binding of the same name, with no warning that the
  repository had opted out of the contract.
  Date: 2026-08-31

- Decision: Scope `NoFieldSelectors` to `shikigami-core` and add only `OverloadedRecordDot` to
  the other six packages.
  Rationale: `NoFieldSelectors` acts at the point a record is *defined*, so it only needs to be
  on where the generated modules live. `OverloadedRecordDot` acts at the point a field is
  *read*, so every package that reads a `shikigami-core` record needs it. Turning
  `NoFieldSelectors` on in the other six as well would multiply the migration by their own
  record definitions for no gain in this plan. Whether the fleet eventually wants one model
  everywhere is a separate question and is left open.
  Date: 2026-08-31

- Decision: Do not commit the edition backup directory
  `shikigami-core/src/.keiro-dsl-generated-haskell-migrations/`.
  Rationale: keiro-dsl writes the pre-migration bytes there so a rollback has evidence, and its
  own guide states that "Version-control restoration is equally valid when it restores the same
  complete set." Git already holds that complete set at the commit before Milestone 4, so
  committing a second copy adds no recoverability and adds a directory of dead generated bytes
  that every future reviewer has to scroll past. It is gitignored instead, alongside the
  existing ignore for the paste-ready Cabal fragment.
  Date: 2026-08-31

- Decision: Do not make Shikigami's 0.15 move wait for Danwa's, and do not move the Danwa pin to
  a mid-upgrade commit.
  Rationale: Danwa is being taken onto the same cohort under `mori://shinzui/danwa` ExecPlan 13,
  which had not started as of 2026-08-31. The commit Shikigami pins declares `keiro` and
  `keiro-core` with no version bound, so it builds identically against 0.14.0.0 and 0.15.0.0 —
  the runtime libraries are functionally unchanged between them. Coupling the two plans would
  therefore buy nothing and would make each one's schedule the other's problem. Moving the pin
  to an intermediate Danwa commit is worse than leaving it: an unreleased dependency pinned to a
  commit that has not passed its own repository's gate is a pin with no evidence behind it,
  which is exactly what the "Packages still resolved from Git" table in
  `docs/dependency-cohort.md` exists to keep honest. The pin moves when Danwa's plan completes.
  Date: 2026-08-31

- Decision: Bridge `BehaviorHoles.hs` through positional constructor patterns in Milestone 2,
  then convert it to concise-label record dot in Milestone 4.
  Rationale: Keiro's guide names exactly three dual-edition bridges, and positional patterns are
  the one that survives a *renamed* label, which is what every field this module reads is about
  to get. Writing it positionally first means the module compiles unchanged across the edition
  boundary, so Milestone 4's build failures are all in hand-written application code and none of
  them are in the file that talks to the generated contract. Converting it afterwards costs one
  small diff and leaves the module in the idiom the edition exists for, rather than leaving a
  nine-field positional pattern behind as permanent scar tissue.
  Date: 2026-08-31


## Outcomes & Retrospective

(To be filled during and after implementation.)


## Context and Orientation

### What this repository is, and where the pieces live

Shikigami is a Haskell service that runs declared agents as durable workflows. It is split
into seven Cabal packages at the repository root: `shikigami-core` (the domain library every
other package builds on), `shikigami-api`, `shikigami-agent`, `shikigami-workers`,
`shikigami-server`, `shikigami-client`, and `shikigami-migrations`. `cabal.project` lists all
seven, pins the compiler to `ghc-9.12.4`, and carries a `constraints:` block naming the exact
Hackage version of every co-developed dependency.

Everything is built and tested inside a Nix development shell. A bare `cabal build` compiles
and then fails at link time with `ld: library not found for -lrdkafka`. Every command in this
plan is therefore written as `nix develop -c <command>`, run from the repository root
`/Users/shinzui/Keikaku/bokuno/shikigami`.

### Keiro, keiki, and keiro-dsl, in plain language

**Keiro** is the event-sourcing and durable-workflow framework this service runs on. A
*durable workflow* here means a long-running process whose every step is written to a
database journal, so that if the process dies it can be replayed from the journal and resume
where it left off. Keiro ships as six libraries Shikigami selects: `keiro`, `keiro-core`,
`keiro-migrations`, `keiro-ops`, `keiro-pgmq`, and `keiro-dsl`. Its canonical project handle
is `mori://shinzui/keiro`.

**keiki** is the state-machine and event-shape library Keiro builds on. It is not moving in
this plan.

**keiro-dsl** is the odd one out. It is not a library Shikigami links against; it is a
command-line *toolchain*. It reads a checked specification of the service's durable identities
and generates Haskell source from it. `cabal.project` declares it with

```cabal
extra-packages: keiro-dsl
```

which tells the solver to treat that Hackage package as if it were a local one. That is what
makes `cabal run keiro-dsl -- ...` resolve to the version this project pins, so that every
developer and CI run the same toolchain without depending on `PATH` or on a separate Keiro
checkout. Because it lives in the same solver plan as the service, `keiro-dsl` cannot be at a
different Keiro version from the runtime libraries — that fact is the whole of Milestone 1.

### The specification and the generated layer

The specification is `domain/shikigami.keiro-workspace`, a manifest listing four member files:
`domain/shikigami-agent-run.keiro`, `domain/shikigami-approval.keiro`,
`domain/shikigami-conversation.keiro`, and `domain/shikigami-run-evidence.keiro`. Each declares
`language keiro-dsl 5` and `context shikigami` on its first two significant lines.

From that specification, `keiro-dsl scaffold` writes 18 Haskell modules into
`shikigami-core/src`, each carrying a first-line banner of the form
`-- @generated by keiro-dsl 0.14.0.0 (language keiro-dsl 5) from ...; do not edit.` They are:

```text
shikigami-core/src/Shikigami/AgentRun/Generated/WorkflowFacts.hs
shikigami-core/src/Shikigami/AgentRun/Generated/WorkflowRuntime.hs
shikigami-core/src/Shikigami/Approval/Generated/WorkflowFacts.hs
shikigami-core/src/Shikigami/Approval/Generated/WorkflowRuntime.hs
shikigami-core/src/Shikigami/DanwaConversation/Generated/WorkflowFacts.hs
shikigami-core/src/Shikigami/DanwaConversation/Generated/WorkflowRuntime.hs
shikigami-core/src/Shikigami/Generated/BehaviorSourceMap.hs
shikigami-core/src/Shikigami/Generated/Conformance.hs
shikigami-core/src/Shikigami/Generated/Nominals.hs
shikigami-core/src/Shikigami/Generated/Nominals/Internal.hs
shikigami-core/src/Shikigami/Generated/ReplayAudit.hs
shikigami-core/src/Shikigami/RunEvidence/Generated/BehaviorContract.hs
shikigami-core/src/Shikigami/RunEvidence/Generated/Codec.hs
shikigami-core/src/Shikigami/RunEvidence/Generated/Domain.hs
shikigami-core/src/Shikigami/RunEvidence/Generated/EventStream.hs
shikigami-core/src/Shikigami/RunEvidence/Generated/Harness.hs
shikigami-core/src/Shikigami/RunEvidence/Generated/Projection.hs
shikigami-core/src/Shikigami/RunEvidence/Generated/Transducer.hs
```

Alongside them the tool writes four bookkeeping files. Three are committed:

- `shikigami-core/src/keiro-dsl-ledger.workspace.shikigami.txt` — the *scaffold ledger*, the
  tool's own record of what it generated last time and under which conventions. Its line
  `naming-edition idiomatic-v1` is the single fact that makes this plan necessary.
- `shikigami-core/src/keiro-dsl-migration-report.workspace.shikigami.txt`
- `shikigami-core/src/keiro-dsl-conformance.workspace.shikigami/` — a small generated Cabal
  package holding a conformance test runner, plus one create-once hand-owned module
  `src/KeiroConformance/Expectations.hs`. `cabal.project` picks it up through
  `optional-packages: shikigami-core/src/keiro-dsl-conformance.workspace.*/*.cabal`, and it is
  run as `cabal test keiro-shikigami-conformance`.

The fourth, `shikigami-core/src/keiro-dsl-cabal-fragment.workspace.shikigami.txt`, is
deliberately **not** committed — `.gitignore` excludes it. It is a paste-ready Cabal snippet
that a human copies into `shikigami-core/shikigami-core.cabal`. That file is where the required
language extensions arrive, so Milestone 4 has to read it after regenerating.

Two modules are *hand-owned but generated-adjacent*, meaning keiro-dsl created them once and
will never overwrite them:

- `shikigami-core/src/Shikigami/RunEvidence/BehaviorHoles.hs` — a "hole" module. It supplies,
  by hand, one canonical history and expected outcome for every state/command cell the
  specification declares. It is the only hand-written file in the repository that reads the
  generated behavior-contract records field by field.
- `shikigami-core/src/keiro-dsl-conformance.workspace.shikigami/src/KeiroConformance/Expectations.hs`
  — a table of expected workflow facts as plain string pairs. It touches no record fields and
  needs no change in this plan.

### The gate

`Justfile` defines the specification gate. `just keiro-gate` runs, in order:

1. `just keiro-check` — `keiro-dsl check` with `--min-language 5 --deny-warnings
   --explain-bindings --fail-on-opaque`, writing reports under `build/`.
2. `just keiro-inspect` — asserts every member *declares* its language rather than inheriting a
   silent default.
3. `just keiro-scaffold` — regenerates the layer and then runs `git diff --exit-code --
   shikigami-core/src`. The regeneration being a no-op is the whole test: it proves the
   committed bytes are what the current specification produces.
4. `just keiro-diff HEAD^` — classifies a proposed change across the compatibility surfaces.
5. `cabal test keiro-shikigami-conformance`.

Step 3 is where keiro-dsl 0.15.0.0 will refuse until the edition is explicitly adopted.

### What Keiro 0.15.0.0 actually changes

The release is dated 2026-08-30 and all six packages are on Hackage. Verified on 2026-08-31
against `https://hackage.haskell.org/package/<name>/preferred` and against the upstream tags
`keiro-0.15.0.0`, `keiro-core-0.15.0.0`, `keiro-dsl-0.15.0.0`, `keiro-migrations-0.15.0.0`,
`keiro-ops-0.15.0.0`, and `keiro-pgmq-0.15.0.0`, all at commit
`de574cdcb0add3fefbb0fdd96d820258d15f8997` on `mori://shinzui/keiro` (the
`chore(release): 0.15.0.0` commit).

For the five runtime libraries there is nothing to migrate. `keiro-core` and
`keiro-migrations` are pure republishes. `keiro`, `keiro-ops`, and `keiro-pgmq` changed only
the `keiro-test-support` bound inside their own test-suite stanzas; their changelogs each say
"Library consumers are unaffected."

`keiro-dsl` 0.15.0.0 is the release. It does two things:

1. It changes the record style of the Haskell it *emits*. Generated product records lose their
   owner-prefixed field labels and their selector functions, and take concise repeated labels
   instead. The generated Cabal fragment now defaults four extensions:
   `DuplicateRecordFields`, `NoFieldSelectors`, `OverloadedRecordDot`, and `OverloadedStrings`.
   This new style is named **`idiomatic-v2`**; the current style is `idiomatic-v1`.
2. It refuses to scaffold at all over a ledger that still records a pre-v2 edition, until the
   operator passes `--apply-generated-haskell-edition` explicitly. Before overwriting, that
   flag copies every ledger-recorded generated file plus the ledger and the Cabal fragment into
   `<out>/.keiro-dsl-generated-haskell-migrations/idiomatic-v1-to-idiomatic-v2/`.

The release notes are explicit that "`.keiro` syntax, serialized identities, and runtime
behavior are unchanged," and that "JSON and wire keys, canonical/rendered output, diagnostics,
fingerprints, `.keiro` language behavior, and runtime semantics are unchanged by the record
migration." The specification's declared `language keiro-dsl 5` stays valid.

Two Keiro documents are worth reading alongside this plan, though this plan repeats everything
from them that matters. Both live in the `mori://shinzui/keiro` checkout:
`docs/guides/adopting-keiro-dsl-idiomatic-v2.md` (the adoption procedure and the rollback path)
and `blueprints/keiro-upgrade/migrations/0-14-to-0-15.md` (the upgrade edge, including the
instruction not to reach for `allow-newer`).

### What idiomatic-v2 renames, concretely, in this repository

Only three generated modules declare product records with prefixed labels, so the rename map
for Shikigami is short and fully enumerable. In
`shikigami-core/src/Shikigami/Generated/BehaviorSourceMap.hs`, `BehaviorSourceLocation` renames
`sourceFile` to `file`, `sourceLine` to `line`, and `sourceColumn` to `column`. In the three
`*/Generated/WorkflowFacts.hs` modules, `WorkflowFacts` renames `workflowFactName` to `name`,
`workflowFactIdVia` to `idVia`, `workflowFactIdField` to `idField`, `workflowFactBody` to
`body`, `workflowFactAwaitLabels` to `awaitLabels`, and `workflowFactPatchIds` to `patchIds`.
In `shikigami-core/src/Shikigami/RunEvidence/Generated/BehaviorContract.hs`:

```text
BehaviorRequirement       requirementKey           -> key
                          requirementKind          -> kind
                          requirementEvidence      -> evidence
                          requirementGuardCoverage -> guardCoverage
                          requirementSource        -> source
                          requirementCommandName   -> commandName
                          requirementExpectedEdge  -> expectedEdge
                          requirementTarget        -> target
                          requirementEventKinds    -> eventKinds
BehaviorWitness           witnessKey               -> key
                          witnessHistory           -> history
                          witnessHistoryPrefix     -> historyPrefix
                          witnessObservedChunk     -> observedChunk
                          witnessCommand           -> command
                          witnessExpected          -> expected
BehaviorFailure           failureKey               -> key
                          failureSubject           -> subject
                          failureCode              -> code
                          failureDetail            -> detail
BehaviorConformanceReport reportRequired           -> required
                          reportFilled             -> filled
                          reportPending            -> pending
                          reportMissing            -> missing
                          reportDuplicate          -> duplicate
                          reportStale              -> stale
                          reportFailed             -> failed
                          reportVerified           -> verified
                          reportUnverified         -> unverified
BehaviorKey               unBehaviorKey            -> unchanged (an explicit newtype unwrapper)
```

The 28 `*Data` records in
`shikigami-core/src/Shikigami/RunEvidence/Generated/Domain.hs` already use the concise labels
`runEvidenceId` and `runId` and do not rename.

Exactly one hand-written module in the repository reads any of those renamed labels:
`shikigami-core/src/Shikigami/RunEvidence/BehaviorHoles.hs`. Every other consumer of the
generated layer imports it `qualified` and touches only constructors and top-level values
(`Shikigami.Agent.Approval.Workflow`, `Shikigami.Agent.Conversation`,
`Shikigami.Agent.Workflow.Name`, `Shikigami.Workflow.Versioning`,
`Shikigami.Attestation.Evidence`, `Shikigami.Attestation.EvidenceStore`,
`Shikigami.RunEvidence.Conformance`). The rename itself is therefore a very small change. It is
the *extension* the rename requires that is large.

### Why the extension is the expensive part

`NoFieldSelectors` is a definition-site extension: it applies to every record declared in a
module compiled with it, and Cabal applies `default-extensions` to a whole component, not to
selected modules. `shikigami-core`'s library stanza compiles the 18 generated modules together
with 100 hand-written ones, so switching it on removes the selector functions for every record
`shikigami-core` defines — 587 distinct field names — and every read of one of them anywhere
in the repository must become dot syntax instead.

The measured upper bound, taken on 2026-08-31 by matching those 587 names in application
position across all Haskell sources, is:

```text
shikigami-core/src        ~4709 sites across 113 modules
shikigami-core/test       ~3539 sites across  43 modules
shikigami-workers          ~919 sites across  28 modules
shikigami-server           ~724 sites across  32 modules
shikigami-agent            ~255 sites across  10 modules
shikigami-api               ~97 sites across   7 modules
shikigami-migrations        ~44 sites across   5 modules
shikigami-client            ~14 sites across   2 modules
```

This is an over-estimate, deliberately: the scan cannot distinguish a selector application from
a local binding that happens to share a field's name, nor from an existing record-dot use. GHC's
type errors are the authority. It is quoted here so nobody starts Milestone 4 expecting a
morning's work.

Three specific shapes are *not* broken by `NoFieldSelectors` and must not be rewritten:
record construction (`Foo { bar = x }`), record update (`r { bar = x }`), and field puns in
patterns (`Foo {bar}`). GHC2024 already implies `NamedFieldPuns`, so puns keep working. Only
*application* of a field name as a function breaks. Separately, 34 field names are listed
individually in the export lists of 14 `shikigami-core` modules; those exports name values that
will no longer exist and must be deleted from the export list (the field is still exported by
the type's `(..)`).

### Existing local ADRs relevant to this plan

Scanned the filenames and headings of all 36 records under `docs/adr/`. Three are relevant.

[docs/adr/0002-generated-code-is-not-formatted.md](../adr/0002-generated-code-is-not-formatted.md)
excludes `keiro-dsl` output from `treefmt` and states the generated-code firewall: a
`-- @generated` file is never hand-modified, because determinism — that scaffolding an unchanged
specification twice reports every module `unchanged` — is what makes a committed generated file
trustworthy. This plan obeys that firewall absolutely: no generated file is edited by hand at
any point, and every change to one arrives through `keiro-dsl scaffold`. The record also warns
that "a new generated artifact in a location the globs do not match will be formatted silently,"
which is why Milestone 4 re-checks the `treefmt.settings.global.excludes` list in
`flake.module.nix` after regenerating.

[docs/adr/0012-a-declared-workflow-body-only-grows-behind-a-patch.md](../adr/0012-a-declared-workflow-body-only-grows-behind-a-patch.md)
governs changes to a declared workflow body. It is relevant as a *boundary*: this plan changes
no workflow body, adds no step, and declares no patch id. If any step of this plan appears to
require one, that is a signal the plan has gone wrong, because Keiro 0.15.0.0 changes no
workflow semantics.

[docs/adr/0027-the-first-release-establishes-one-clean-durable-baseline.md](../adr/0027-the-first-release-establishes-one-clean-durable-baseline.md)
is the record that lets this plan skip a data-migration story entirely: nothing in 0.15.0.0
touches a persisted byte, and no journal, snapshot, or event payload changes shape.

No existing ADR covers the Haskell record model of this repository. Milestone 5 creates one.

### The two upstream coordination points

The first is a hard blocker. `kioku-core` 0.5.1.0 — the newest release, tagged `v0.5.1.0` on 2026-08-29 at commit
`d071aea110bb3ca90bfcd1af70441dd0e2f2d086` of `mori://shinzui/kioku` — declares
`keiro ^>=0.14.0.0` and `keiro-core ^>=0.14.0.0`, and `kioku-migrations` 0.5.1.0 declares
`keiro-migrations ^>=0.14.0.0`. In Cabal, `^>=0.14.0.0` means `>=0.14.0.0 && <0.15`. Those two
libraries are the only released packages in Shikigami's closure that exclude 0.15.0.0;
`kioku-api` declares no Keiro dependency and `danwa-core` declares `keiro` unbounded.

Shikigami links `kioku-core` from four packages, so there is no way to satisfy both. Kioku must
publish a release whose `kioku-core` declares `keiro ^>=0.15.0.0` and `keiro-core ^>=0.15.0.0`
and whose `kioku-migrations` declares `keiro-migrations ^>=0.15.0.0`. Because the Keiro runtime
libraries are functionally unchanged at 0.15.0.0, that is a bounds-only release for Kioku, and
there is direct precedent: `kioku 0.3.0.0` (2026-08-05) was exactly such a release, admitting
keiki 0.9 and keiro 0.11 without a source change. That work belongs to
`mori://shinzui/kioku` and is outside this repository. Milestone 1 states the requirement;
Milestone 3 consumes it.

The second is not a blocker but must not be forgotten. Danwa — the conversation substrate behind
the `DanwaConversation` sink — has no Hackage release, so `cabal.project` resolves
`danwa-core`, `danwa-api`, and `danwa-client` from the Git commit
`301bc1b381fb1baa253b9ba5fce5735e6d0a8ca9`. Danwa is being moved onto this same Keiro cohort
under `mori://shinzui/danwa` ExecPlan 13, "Upgrade Danwa to the released Keiro 0.15 cohort",
itself a child of that repository's MasterPlan 2. As of 2026-08-31 that plan records that no
implementation work has begun.

Nothing about it gates this plan. The pinned Danwa commit declares `keiro` and `keiro-core`
with no version bound at all, so it resolves against 0.15.0.0 exactly as it resolves against
0.14.0.0, and since the Keiro runtime libraries are functionally unchanged between the two, the
resulting build is the same build. What it means is that after this plan lands, Shikigami will
be linking a Danwa that was pinned before Danwa itself was validated against the cohort. That
is a provenance gap rather than a correctness one, and the right closure is to move the pin to
the commit that completes Danwa's ExecPlan 13 — opportunistically in Milestone 3 if it has
landed by then, and otherwise as a recorded retirement condition in
`docs/dependency-cohort.md`. Do not delay this plan waiting for it, and do not move the pin to
a mid-upgrade Danwa commit that has not passed its own gate.


## Plan of Work

The work is five milestones. Milestones 1 and 2 can be done today, in either order, and do not
depend on anything upstream. Milestone 3 cannot start until Kioku publishes. Milestone 4 is the
large one and must land as a single working commit. Milestone 5 tidies the durable record.

### Milestone 1 — Prove and record the cohort gate

**Scope.** Turn "we cannot upgrade yet" from a thing someone discovered once into a checked-in,
reproducible statement with a named exit condition. Nothing changes version.

**What exists at the end.** `docs/dependency-cohort.md` has a new subsection under its
"Current release status" heading, titled "Pending adoption: the keiro 0.15 cohort," which
names the release, states that its runtime half is a functional no-op, quotes the solver
refusal, and names exactly what Kioku must publish. Anyone who asks "why is Shikigami not on
the current Keiro?" gets a complete answer from that file alone.

**Edits.** One file: `docs/dependency-cohort.md`. Insert the new subsection immediately after
the existing `### Current release status` prose and before `### The keiro 0.11 / keiki 0.9
gate, and how it cleared`. That neighbouring subsection is the template to follow — it is the
last time this repository recorded a blocked cohort move, and it reads as a small narrative of
what blocked it and what cleared it. Write this one the same way, in the present tense.

The subsection must state, in prose: that Keiro 0.15.0.0 was published 2026-08-30 and is on
Hackage for all six selected packages; that `keiro-core` and `keiro-migrations` declare no
changes and that `keiro`, `keiro-ops`, and `keiro-pgmq` changed only their own test-suite
bounds, so the runtime half of the move is a republish; that the substance is `keiro-dsl`'s
idiomatic-v2 generated-Haskell edition; that `kioku-core` 0.5.1.0 and `kioku-migrations`
0.5.1.0 cap Keiro below 0.15 and are the sole blockers; and that the exit condition is a
bounds-only Kioku release declaring `keiro ^>=0.15.0.0`, `keiro-core ^>=0.15.0.0`, and
`keiro-migrations ^>=0.15.0.0`. Include the solver transcript from the Surprises section, and
state explicitly that `allow-newer` is not the answer here, quoting the cohort's own rule 2 and
Keiro's upgrade-edge instruction.

**Acceptance.** `docs/dependency-cohort.md` contains the subsection; the transcript in it can
be reproduced by following the Concrete Steps below and getting the same conflict set.

### Milestone 2 — Prepare hand-owned code for the record model

**Scope.** Two edition-neutral preparations, both of which are safe on the current cohort and
both of which shrink Milestone 4.

**What exists at the end.** Every package can read a field with dot syntax, and the one
hand-written module that reads generated behavior records does so in a way that survives the
rename. The build and the full test suite are green, still on keiro 0.14.0.0 and still on the
`idiomatic-v1` generated layer.

**Edits.**

First, add `OverloadedRecordDot` to the `default-extensions` list of the `common common` stanza
in all seven `.cabal` files: `shikigami-core/shikigami-core.cabal`,
`shikigami-agent/shikigami-agent.cabal`, `shikigami-api/shikigami-api.cabal`,
`shikigami-client/shikigami-client.cabal`,
`shikigami-migrations/shikigami-migrations.cabal`, `shikigami-server/shikigami-server.cabal`,
and `shikigami-workers/shikigami-workers.cabal`. Each currently reads

```cabal
  default-extensions:
    BlockArguments
    DeriveAnyClass
    DuplicateRecordFields
    MultilineStrings
    OverloadedLabels
    OverloadedStrings
```

and becomes

```cabal
  default-extensions:
    BlockArguments
    DeriveAnyClass
    DuplicateRecordFields
    MultilineStrings
    OverloadedLabels
    OverloadedRecordDot
    OverloadedStrings
```

This is additive and cannot break existing code that composes functions with spaces around the
dot, which is how every composition in this repository is written. `OverloadedRecordDot` only
changes the meaning of `a.b` written with no surrounding whitespace where `a` begins with a
lowercase letter; a scan of all Haskell sources on 2026-08-31, with string literals and
comments removed, found 117 such occurrences and every one of them is already an intentional
record-dot use inside a generated module. Nonetheless, re-run that scan after the edit if the
build produces a surprising type error, and treat any hit outside a `Generated` directory as
the cause.

Second, rewrite `shikigami-core/src/Shikigami/RunEvidence/BehaviorHoles.hs`. Today it reads
generated fields by applying selectors and constructs a witness with prefixed labels:

```haskell
witness :: BehaviorRequirement -> BehaviorWitness
witness requirement =
  LiveWitness
    { witnessKey = requirementKey requirement,
      witnessHistory = historyFor (requirementSource requirement),
      witnessCommand = commandFor (requirementCommandName requirement),
      witnessExpected = expectationFor requirement
    }

expectationFor :: BehaviorRequirement -> LiveExpectation
expectationFor BehaviorRequirement {requirementKind, requirementCommandName, requirementSource} =
  case requirementKind of
    LiveTransition -> Emits (eventFor requirementCommandName :| [])
    RequiredRejection -> Rejects (rejectionFor requirementSource)
    ReplayTransition -> error "RunEvidence has no replay-only behavior requirement"
```

Every one of `witnessKey`, `witnessHistory`, `witnessCommand`, `witnessExpected`,
`requirementKey`, `requirementSource`, `requirementCommandName`, and `requirementKind` is
renamed by idiomatic-v2. Keiro's adoption guide names positional constructor syntax as the
bridge that survives a rename, because "Constructor order is stable across the edition."
Rewrite both functions to use it. `BehaviorRequirement` has nine fields in the declaration order
`key, kind, evidence, guardCoverage, source, commandName, expectedEdge, target, eventKinds`, and
`LiveWitness` has four in the order `key, history, command, expected`:

```haskell
witness :: BehaviorRequirement -> BehaviorWitness
witness requirement@(BehaviorRequirement key _ _ _ source commandName _ _ _) =
  LiveWitness key (historyFor source) (commandFor commandName) (expectationFor requirement)

expectationFor :: BehaviorRequirement -> LiveExpectation
expectationFor (BehaviorRequirement _ kind _ _ source commandName _ _ _) =
  case kind of
    LiveTransition -> Emits (eventFor commandName :| [])
    RequiredRejection -> Rejects (rejectionFor source)
    ReplayTransition -> error "RunEvidence has no replay-only behavior requirement"
```

Add a short comment above `witness` recording *why* the module is written positionally: it is a
deliberate dual-edition bridge across the keiro-dsl generated-Haskell edition boundary, and it
becomes record dot in Milestone 4. Leave the rest of the module — `historyFor`, `commandFor`,
`eventFor`, the fixture values — untouched; none of it reads a renamed field.

Note that this file also currently imports `Shikigami.Prelude`, which it uses only for `Text`.
That import is fine and stays.

**Acceptance.** `nix develop -c cabal build all` succeeds. `nix develop -c cabal test all -j1`
reports the same suites and the same counts as the last recorded run in
`docs/dependency-cohort.md` (810 checks across nine suites, plus the two sibling Kikan-En
suites). `just keiro-gate` still passes: the generated layer has not changed and neither has
the toolchain.

### Milestone 3 — Take the lockstep 0.15 bump

**Scope.** Move all six Keiro selections to 0.15.0.0 and nothing else. Do not touch the Kiroku,
Keiki, Shibuya, Kioku, Shikumi, or Baikai selections — Keiro's own upgrade edge states that this
release "entails no upstream edge" and that its `kiroku-store`, `kiroku-store-migrations`,
`keiki`, and `shibuya-core` bounds are unchanged.

**Precondition.** A Kioku release admitting `keiro ^>=0.15.0.0` is on Hackage. Verify with

```bash
curl -s -H 'Accept: application/json' https://hackage.haskell.org/package/kioku-core/preferred
```

and by reading the new release's `kioku-core.cabal` and `kioku-migrations.cabal` bounds. If it
is not there, stop; the plan resumes when it is. Do not proceed with `allow-newer`, a
`source-repository-package` override, or a wider bound.

**What exists at the end.** The solver selects the 0.15.0.0 Keiro set, the whole repository
builds, and the whole test suite passes — with the generated layer still at `idiomatic-v1`, and
`just keiro-scaffold` failing with the edition refusal. That failure is the milestone's
deliverable evidence, not a defect: it demonstrates that keiro-dsl refuses before writing
anything.

**Edits.** Three files.

In `cabal.project`, the `constraints:` block's Keiro rows move from `==0.14.0.0` to
`==0.15.0.0`:

```diff
-  , keiro                   ==0.14.0.0
-  , keiro-core              ==0.14.0.0
-  , keiro-dsl               ==0.14.0.0
-  , keiro-migrations        ==0.14.0.0
-  , keiro-ops               ==0.14.0.0
-  , keiro-pgmq              ==0.14.0.0
+  , keiro                   ==0.15.0.0
+  , keiro-core              ==0.15.0.0
+  , keiro-dsl               ==0.15.0.0
+  , keiro-migrations        ==0.15.0.0
+  , keiro-ops               ==0.15.0.0
+  , keiro-pgmq              ==0.15.0.0
```

Also bump the Kioku rows to whatever version the new Kioku release carries, keeping
`kioku-api`, `kioku-core`, and `kioku-migrations` at one version as they are today.

In `shikigami-migrations/shikigami-migrations.cabal`, line 30, change
`keiro-migrations ^>=0.14.0.0` to `keiro-migrations ^>=0.15.0.0`, and bump the two `kioku-*`
rows below it to the new Kioku line.

In `shikigami-server/shikigami-server.cabal`, lines 69–70, change `keiro ==0.14.0.0` and
`keiro-ops ==0.14.0.0` to `==0.15.0.0`.

Then settle the Danwa pin. Check whether `mori://shinzui/danwa` ExecPlan 13 has completed. If it
has, move the `tag:` of the Danwa `source-repository-package` stanza in `cabal.project` from
`301bc1b381fb1baa253b9ba5fce5735e6d0a8ca9` to that plan's final commit, and re-run the dry-run
solve and the full suite with it. If it has not, leave the tag alone — the pinned commit
declares no Keiro bound and resolves against 0.15.0.0 unchanged — and instead add a sentence to
the `danwa-core`, `danwa-api`, `danwa-client` row of the "Packages still resolved from Git"
table in `docs/dependency-cohort.md` recording that the pin predates Danwa's own Keiro 0.15
adoption and should move to the commit that completes it. Do not pin a mid-upgrade Danwa commit.

No other file in the repository names a Keiro version. The banner inside
`shikigami-core/src/keiro-dsl-conformance.workspace.shikigami/keiro-shikigami-conformance.cabal`
also says `0.14.0.0`, but that is generated output and updates itself in Milestone 4.

**Acceptance.** `nix develop -c cabal build all --dry-run` prints a plan containing
`keiro-core-0.15.0.0`, `keiro-0.15.0.0`, `keiro-migrations-0.15.0.0`, `keiro-ops-0.15.0.0`, and
`keiro-pgmq-0.15.0.0`. `nix develop -c cabal build keiro-dsl --dry-run` selects
`keiro-dsl-0.15.0.0`. `nix develop -c cabal build all` and `nix develop -c cabal test all -j1`
are green. `just keiro-scaffold` fails with a refusal naming the recorded Generated paths, the
ledger, the Cabal fragment, and any attributable old selector uses in create-once files; capture
that transcript into Surprises & Discoveries.

### Milestone 4 — Adopt idiomatic-v2 and the record model

**Scope.** The edition apply, the extension switch, and the whole selector migration, as one
commit that leaves the tree building. They cannot be separated: the current generated
`BehaviorContract.hs` applies its own selectors, so `NoFieldSelectors` breaks it, and it may not
be hand-fixed.

**What exists at the end.** The ledger records `naming-edition idiomatic-v2`; the 18 generated
modules carry a `0.15.0.0` banner and concise labels; `shikigami-core`'s stanza carries the four
extensions from the regenerated fragment; every hand-written read of a `shikigami-core` field is
dot syntax; `just keiro-gate` passes; the whole suite passes.

**Order of work.** Do it in this order; each step's failure mode is easier to read than the
next one's.

*Step A — ignore the backup directory.* Add to `.gitignore`, next to the existing keiro-dsl
entries, with a comment explaining that git itself is the rollback:

```gitignore
# keiro-dsl copies the pre-migration generated layer here when a generated-Haskell
# edition is applied. The same complete set is already in git history at the commit
# before the adoption, which the adoption guide accepts as an equally valid restore,
# so this is local migration evidence rather than something to commit.
shikigami-core/src/.keiro-dsl-generated-haskell-migrations/
```

*Step B — apply the edition.* From the repository root, run the ordinary scaffold command with
the explicit adoption flag. The working tree must be clean first, because the tool records
durable backups but cannot roll back unrelated edits.

```bash
nix develop -c cabal run -v0 keiro-dsl -- scaffold domain/shikigami.keiro-workspace \
  --out shikigami-core/src \
  --apply-generated-haskell-edition
```

This is *not* a legacy-v1 tree: the ledger already records `naming-edition idiomatic-v1` and the
sidecar files already use their current names, so `--apply-name-migrations` is not needed and
must not be passed. If the tool asks for both flags, stop and re-read its message — that would
mean the ledger is older than this plan assumes.

Afterwards, inspect the three things the run produces: the changed generated modules, the new
`naming-edition idiomatic-v2` line in
`shikigami-core/src/keiro-dsl-ledger.workspace.shikigami.txt`, and
`shikigami-core/src/.keiro-dsl-generated-haskell-migrations/idiomatic-v1-to-idiomatic-v2/remediation-report.txt`.
Read that report in full. It lists every attributable use of a renamed label it can see in
recorded hole files, and it is the tool's own account of what it thinks still needs migrating.
It is explicitly *not* a claim to understand the whole application — compile errors remain the
authority outside the scaffold inventory.

*Step C — reconcile the Cabal fragment.* Read the regenerated
`shikigami-core/src/keiro-dsl-cabal-fragment.workspace.shikigami.txt` (gitignored, so it will
not appear in `git status`). Reconcile it into `shikigami-core/shikigami-core.cabal`: the
`other-modules` block under the "Generated by `keiro-dsl scaffold`" comment, the
`Shikigami.Generated.Conformance` line in `exposed-modules`, the `build-depends` list, and the
extensions. The extensions go into the shared `common common` stanza, which after Milestone 2
already has `DuplicateRecordFields`, `OverloadedRecordDot`, and `OverloadedStrings`; add
`NoFieldSelectors`:

```cabal
  default-extensions:
    BlockArguments
    DeriveAnyClass
    DuplicateRecordFields
    MultilineStrings
    NoFieldSelectors
    OverloadedLabels
    OverloadedRecordDot
    OverloadedStrings
```

Check the fragment's `build-depends` against the stanza's. The current fragment lists `aeson`,
`base`, `containers`, `effectful-core`, `keiki`, `keiro`, and `text`, but
`*/Generated/WorkflowRuntime.hs` imports `Kiroku.Store.Effect`, which comes from
`kiroku-store`. The stanza already depends on `kiroku-store` for hand-written reasons, so this
has never mattered; verify it is still listed and note any other omission in Surprises &
Discoveries, because it would matter to anyone who later isolates the generated layer.

*Step D — migrate the selector reads, package by package.* Build one component at a time and
let GHC drive. Start with the core library, because nothing else compiles until it does:

```bash
nix develop -c cabal build shikigami-core:lib:shikigami-core
```

Each error is of the form "Variable not in scope: someField :: Foo -> Bar". Replace the
application `someField x` with `x.someField`, and `someField (g y)` with `(g y).someField`.
Where the value is a lambda argument or a section, the mechanical rewrite `someField` to
`(.someField)` is valid and reads acceptably in point-free chains such as `map (.name) xs`.
Where the code is already pattern-matching on the constructor, prefer adding a field pun to
rewriting the read.

Three rewrites are wrong and must not be used. Do not add `FieldSelectors` to any module or
stanza to opt back out — Keiro's upgrade edge names that specifically as a compatibility escape
hatch to avoid, and it would silently exempt whichever module carried it from the model the rest
of the package now follows. Do not introduce a hand-written function with the field's old name
that does the same thing; that is the same escape hatch with a longer diff. Do not mechanically
rename same-spelled fields across types to make an error go away — under
`DuplicateRecordFields` two different records may legitimately share a label, and a blind rename
can silently retarget a read at the wrong type.

Then, in order, and rebuilding after each: `shikigami-core:test:shikigami-core-test`,
`shikigami-workers`, `shikigami-server`, `shikigami-agent`, `shikigami-api`,
`shikigami-migrations`, `shikigami-client`, and each package's test suite. Tick the matching
Progress entry as each component compiles, and if the work stops part-way, split that entry so
the next contributor knows which component was mid-flight.

*Step E — fix the export lists.* Fourteen `shikigami-core` modules name 34 field selectors
individually in their `module M (...) where` export lists. Those names no longer exist and the
compiler will say so. Delete each from the export list; the field is still exported to
record-dot users by the type's `(..)` entry. Do not replace it with anything.

*Step F — return `BehaviorHoles.hs` to the idiom.* With the edition applied, rewrite the
positional bridge from Milestone 2 into concise-label record dot, and delete the comment that
explained the bridge:

```haskell
witness :: BehaviorRequirement -> BehaviorWitness
witness requirement =
  LiveWitness
    { key = requirement.key,
      history = historyFor requirement.source,
      command = commandFor requirement.commandName,
      expected = expectationFor requirement
    }

expectationFor :: BehaviorRequirement -> LiveExpectation
expectationFor requirement =
  case requirement.kind of
    LiveTransition -> Emits (eventFor requirement.commandName :| [])
    RequiredRejection -> Rejects (rejectionFor requirement.source)
    ReplayTransition -> error "RunEvidence has no replay-only behavior requirement"
```

*Step G — repair the architecture tests if their assumptions moved.* Two test modules read
`.cabal` files as text and will notice this change.
`shikigami-core/test/Shikigami/KeiroSpecificationSpec.hs` compares the generated modules on disk
against the module names declared in `shikigami-core.cabal`; that comparison should still hold
exactly, and if it does not, the fragment was reconciled incompletely — fix the `.cabal`, not
the test. `shikigami-core/test/Shikigami/PackageArchitectureSpec.hs` should be unaffected by this
plan's chosen approach, since no new stanza appears; confirm it passes rather than assuming.

*Step H — check the formatter firewall.* Confirm that every path the scaffold wrote is still
matched by the `treefmt.settings.global.excludes` globs in `flake.module.nix`. The current globs
are `shikigami-core/src/Shikigami/Generated/*.hs`,
`shikigami-core/src/Shikigami/*/Generated/*.hs`,
`shikigami-core/src/keiro-dsl-conformance.workspace.*/*.cabal`, and
`shikigami-core/src/keiro-dsl-conformance.workspace.*/src/Main.hs`. Note that the first glob does
*not* match `shikigami-core/src/Shikigami/Generated/Nominals/Internal.hs`, one directory deeper;
that is a pre-existing gap rather than something this plan introduces, but if the formatter now
rewrites that file, the next scaffold will report it `overwritten` and `just keiro-scaffold` will
fail. If that happens, extend the globs in `flake.module.nix` in this same commit and record it
in Surprises & Discoveries as an ADR-0002 consequence realised.

**Acceptance.** `just keiro-gate` passes all five stages, including the `git diff --exit-code`
determinism check after re-scaffolding. `nix develop -c cabal test all -j1` reports the same
nine Shikigami suites with the same check counts as before the migration. In particular
`shikigami-core-test` must still report its `Shikigami.WireCompatSpec` cases green — those are
literal pre-upgrade byte fixtures, and their passing is the direct evidence that a large source
rewrite changed no persisted byte.

### Milestone 5 — Reconcile the surrounding contracts

**Scope.** Make the durable documents true again and promote the durable decision out of this
plan.

**What exists at the end.** `docs/dependency-cohort.md` describes the cohort Shikigami actually
selects; `docs/architecture/packages.md` states the repository's record model as a rule rather
than as an accident of one migration; a new ADR records the decision and the alternatives; and
the Milestone 1 pending-adoption subsection is gone, because it retired.

**Edits.**

In `docs/dependency-cohort.md`: move the six Keiro rows of the release matrix to 0.15.0.0 with
tags `keiro-0.15.0.0`, `keiro-core-0.15.0.0`, `keiro-dsl-0.15.0.0`,
`keiro-migrations-0.15.0.0`, `keiro-ops-0.15.0.0`, `keiro-pgmq-0.15.0.0` and the release commit
they share; update the Kioku rows to the release that cleared the gate; delete the pending
subsection; add a compatibility-evidence row stating that 0.15.0.0 changes no wire, JSON, SQL,
fingerprint, or runtime observation and that `WireCompatSpec` is the check; and add a paragraph
to "What this cohort cost in source" describing the record-model switch honestly, including the
scale, since the version numbers do not predict it.

In `docs/architecture/packages.md`, under "Module placement rules": state that
`shikigami-core` compiles with `NoFieldSelectors` and `OverloadedRecordDot`, that reads of its
records are dot syntax, that construction, update, and puns are unchanged, and that the reason
is the keiro-dsl generated layer sharing the stanza. State that the other six packages carry
`OverloadedRecordDot` so they can read those records, and that they do not carry
`NoFieldSelectors`.

Create `docs/adr/0037-<slug>.md` — the next free number; 0036 is the highest today. Follow the
house shape: an `# 0037. <Title>` heading, then `Date:`, `Status: accepted`, and the sections
Context, Decision, Alternatives rejected, Consequences, References. The corpus is plain
Markdown; `docs/adr/README.md` states it is not an OKF bundle and that no `docId` or frontmatter
belongs there. The record should say that Shikigami's Haskell record model is set by the
generated layer it shares a component with, name the two rejected alternatives with the numbers
that made the choice, and state the consequence a future contributor will actually feel: a new
record in `shikigami-core` has no selectors and never will, and a new `shikigami-core` field
read from a sibling package needs dot syntax.

Finally, fill in this plan's Outcomes & Retrospective and perform the ADR distillation pass over
the Decision Log and Surprises & Discoveries.


## Concrete Steps

All commands run from the repository root `/Users/shinzui/Keikaku/bokuno/shikigami`.

### Reproducing the Milestone 1 solver refusal

The refusal cannot be reproduced by passing `--constraint` on the command line, because
`cabal.project`'s own `constraints:` block wins and the two conflict with each other, producing
a misleading "constraint from cabal.project requires ==0.14.0.0" message. Use a throwaway
project file instead. Refresh the package index first, or the solver will report that
`keiro-core-0.15.0.0` does not exist rather than that it is excluded:

```bash
nix develop -c cabal update

sed -E 's/^([[:space:]]*,?[[:space:]]*)(keiro|keiro-core|keiro-dsl|keiro-migrations|keiro-ops|keiro-pgmq)([[:space:]]+)==0\.14\.0\.0/\1\2\3==0.15.0.0/' \
  cabal.project > cabal.project.probe015

nix develop -c cabal build all --dry-run --project-file=cabal.project.probe015
```

Expect the conflict quoted in Surprises & Discoveries, ending with:

```text
[__3] rejecting: kioku-core-0.5.1.0 (conflict: keiro==0.15.0.0, kioku-core => keiro^>=0.14.0.0)
```

Delete the probe file when finished; it must not be committed:

```bash
rm -f cabal.project.probe015
```

### Verifying the Milestone 3 precondition

```bash
curl -s -H 'Accept: application/json' https://hackage.haskell.org/package/kioku-core/preferred
curl -s -H 'Accept: application/json' https://hackage.haskell.org/package/keiro/preferred
```

The second already prints `0.15.0.0` first. The first must print a version newer than
`0.5.1.0`; then read that release's `.cabal` bounds before trusting it.

To settle the Danwa pin, read the state of that repository's own plan and compare its head
commit with the one `cabal.project` pins:

```bash
grep -n -A3 'danwa' cabal.project | grep -n 'tag:'
sed -n '/^## Progress/,/^## Surprises/p' \
  /Users/shinzui/Keikaku/bokuno/danwa/docs/plans/13-upgrade-danwa-to-the-released-keiro-0-15-cohort.md
```

If that plan's Progress section still says no implementation work has begun, leave the pin.

### The Milestone 3 build and the expected refusal

```bash
nix develop -c cabal build all --dry-run
nix develop -c cabal build all
nix develop -c cabal test all -j1
just keiro-scaffold   # expected to FAIL with the edition refusal; capture the output
```

### The Milestone 4 apply

```bash
git status --porcelain    # must be empty before applying

nix develop -c cabal run -v0 keiro-dsl -- scaffold domain/shikigami.keiro-workspace \
  --out shikigami-core/src \
  --apply-generated-haskell-edition

grep naming-edition shikigami-core/src/keiro-dsl-ledger.workspace.shikigami.txt
cat shikigami-core/src/.keiro-dsl-generated-haskell-migrations/idiomatic-v1-to-idiomatic-v2/remediation-report.txt
cat shikigami-core/src/keiro-dsl-cabal-fragment.workspace.shikigami.txt
```

The `grep` must print `naming-edition idiomatic-v2`.

### The Milestone 4 migration loop

```bash
nix develop -c cabal build shikigami-core:lib:shikigami-core
nix develop -c cabal build shikigami-core:test:shikigami-core-test
nix develop -c cabal build shikigami-workers
nix develop -c cabal build shikigami-server
nix develop -c cabal build shikigami-agent
nix develop -c cabal build shikigami-api
nix develop -c cabal build shikigami-migrations
nix develop -c cabal build shikigami-client
nix develop -c cabal build all
```

To relocate the individually-exported selector names of Step E:

```bash
python3 - <<'PY'
import re, os
names = set()
for dp, _, fs in os.walk('shikigami-core/src'):
    for f in fs:
        if not f.endswith('.hs'):
            continue
        src = open(os.path.join(dp, f), encoding='utf-8', errors='replace').read()
        for m in re.finditer(r"^\s*[{,]?\s*([a-z][A-Za-z0-9_']*)\s*::", src, re.M):
            names.add(m.group(1))
for dp, _, fs in os.walk('shikigami-core/src'):
    for f in fs:
        if not f.endswith('.hs'):
            continue
        p = os.path.join(dp, f)
        src = open(p, encoding='utf-8', errors='replace').read()
        m = re.search(r"\nmodule\s+[\w.]+\s*\((.*?)\)\s*where", src, re.S)
        if not m:
            continue
        body = re.sub(r"\([^()]*\)", "", m.group(1))
        hits = [t for t in re.split(r"[,\s]+", body) if t in names]
        if hits:
            print(p, hits)
PY
```

### The gate and the full suite

```bash
just keiro-gate
nix develop -c cabal test all -j1
```

Run the suites with `-j1`. Under `-j`, the database-backed suites each stand up an ephemeral
PostgreSQL and contend, which makes `shikigami-core-test` fail intermittently for reasons that
have nothing to do with this plan.

### Committing

Every commit made under this plan carries both trailers:

```text
chore(deps): take the keiro 0.15.0.0 lockstep release

Move the six Keiro constraints to 0.15.0.0 and widen the two local bounds
that named 0.14. The runtime half of the release is a republish; the
generated-Haskell edition is adopted separately.

ExecPlan: docs/plans/65-migrate-shikigami-to-the-keiro-0-15-cohort-and-the-idiomatic-v2-record-model.md
Intention: intention_01m1bntpmbeqet1597zr91ej43
```

Commit directly to the current branch; do not create a feature branch.


## Validation and Acceptance

Acceptance is phrased as things a person can run and observe.

**The toolchain is current.** `nix develop -c cabal build keiro-dsl --dry-run` names
`keiro-dsl-0.15.0.0`, and every generated module's first-line banner reads
`-- @generated by keiro-dsl 0.15.0.0 (language keiro-dsl 5) from ...; do not edit.` Confirm with:

```bash
head -1 shikigami-core/src/Shikigami/RunEvidence/Generated/Codec.hs
```

**The edition is adopted, and adopting it was idempotent.** The ledger line reads
`naming-edition idiomatic-v2`, and re-running the ordinary scaffold command — with no apply flag
— succeeds and changes nothing:

```bash
nix develop -c cabal run -v0 keiro-dsl -- scaffold domain/shikigami.keiro-workspace \
  --out shikigami-core/src
git diff --exit-code -- shikigami-core/src
```

An empty diff and a zero exit are the whole test. This is the same check `just keiro-scaffold`
performs, and it is what makes a committed generated file trustworthy: it is what the current
specification produces, not what someone's editor left behind.

**The declared identities did not move.** `cabal test keiro-shikigami-conformance` passes with
its 30 checks against the unmodified expectation table in
`shikigami-core/src/keiro-dsl-conformance.workspace.shikigami/src/KeiroConformance/Expectations.hs`.
That table is hand-owned and lists every workflow's name, id field, id constructor, await
labels, patch ids, and full step body as literal strings. If any durable identity had shifted,
this suite would fail and the table would have needed editing. It must not be edited.

**No persisted byte changed.** `shikigami-core-test` passes, including
`Shikigami.WireCompatSpec`, which decodes literal pre-upgrade payloads captured before earlier
upgrades — queue `RunJob` payloads, journal step values, `SinkIntent` and `SinkResult` outbox
JSON. Those fixtures are literals on purpose: a fixture built by calling the current encoder
would pass no matter what the encoder did.

**The specification still checks clean.** `just keiro-check` exits zero with
`--deny-warnings` and `--fail-on-opaque`. A new keiro-dsl warning appearing on a toolchain
upgrade is a finding about this specification and must be read, not suppressed.

**Nothing regressed.** `nix develop -c cabal test all -j1` reports nine Shikigami suites plus
the two sibling Kikan-En suites, with check counts matching the last recorded run. Record the
new transcript in `docs/dependency-cohort.md` under "Resolved evidence."

**The service still runs.** Bring up the dev database and apply migrations, which exercises the
composed `keiro-migrations` component at its new version:

```bash
just create-database
just migrate-status
```

`just migrate-status` on an already-migrated database must report nothing to apply. Keiro
0.15.0.0 adds no migration, so a fresh `just migrate` and a repeat run are both expected to be
no-ops beyond what 0.14.0.0 applied.


## Idempotence and Recovery

**Milestones 1, 2, 3 and 5** are ordinary edits to text files and are safe to repeat, revise, or
revert with git.

**Milestone 4's apply is the one step with a special recovery path**, and it is well specified
upstream. The apply copies every ledger-recorded generated file, the ledger, and the Cabal
fragment into
`shikigami-core/src/.keiro-dsl-generated-haskell-migrations/idiomatic-v1-to-idiomatic-v2/`
*before* overwriting anything. Repeating a successful apply is an ordinary idempotent v2
scaffold. A pre-existing backup whose bytes differ from the current source is a hard refusal,
not a silent overwrite.

To roll back, restore the complete backed-up set to `shikigami-core/src`, including the Cabal
fragment and the ledger — or, equivalently and more simply here, `git checkout` the commit
before the adoption. Restoring is all-or-nothing: a v1 ledger must never be paired with v2
generated modules, or the next scaffold will reason from a false history. The restored ledger
records `naming-edition idiomatic-v1` again and the 0.15.0.0 tool will refuse ordinary
regeneration until a later explicit adoption, which is the correct behavior. The
`remediation-report.txt` does not need to be restored or removed; it is regenerated on every
apply and never blocks a rollback-edit-retry cycle.

If an apply is interrupted, do not rerun blind. Inspect the backup directory first. The tool
either continues from byte-identical backup evidence or refuses with a source/backup conflict;
on a refusal, restore the complete set and retry. That conflict check runs only while the ledger
still records the older edition — once it says `idiomatic-v2`, an ordinary rerun does not
mistake later application edits for migration conflicts.

Because Milestone 4 cannot leave the tree compiling part-way through, expect to work with an
uncommittable tree for its duration. If the work must be paused, `git stash` is not a good fit
for a change of this size; instead commit to a scratch branch, note in Progress exactly which
component was mid-migration, and return to it. Note that this repository's pre-commit hook
stashes unstaged work while it runs, so partially staged states can look briefly alarming; that
is the hook, not lost work.

**One risk has no undo and must simply not be taken:** hand-editing a `-- @generated` file. If
one is edited, the next scaffold refuses to overwrite it (the banner check) or silently reverts
the edit, and either way the repository has lost the property that its generated layer is
derived from its specification. If a generated file looks wrong, the specification under
`domain/` is where to look.


## Interfaces and Dependencies

**Dependency selections that change.** `cabal.project`'s `constraints:` block moves `keiro`,
`keiro-core`, `keiro-dsl`, `keiro-migrations`, `keiro-ops`, and `keiro-pgmq` from `==0.14.0.0`
to `==0.15.0.0`, and moves the three `kioku-*` rows to the Kioku release that admits it.
`shikigami-migrations/shikigami-migrations.cabal` moves `keiro-migrations` to `^>=0.15.0.0` and
its `kioku-*` bounds to match. `shikigami-server/shikigami-server.cabal` moves `keiro` and
`keiro-ops` to `==0.15.0.0`. Nothing else in the cohort moves: `keiki` and `keiki-codec-json`
stay at 0.9.1.0, `kiroku-store` at 0.8.0.0, `kiroku-store-migrations` at 0.4.0.0,
`shibuya-core` at 0.9.0.0, and the `pgmq-*`, `pg-migrate`, `settei`, `shikumi*`, and `baikai*`
selections are untouched. The five temporary `http-client-tls` `allow-newer` exceptions and the
unrelated `haxl:time` exception stay exactly as they are; this plan adds none and removes none.

**Dependency selections that may change, and the condition.** The Danwa
`source-repository-package` stanza in `cabal.project` pins `danwa-core`, `danwa-api`, and
`danwa-client` at commit `301bc1b381fb1baa253b9ba5fce5735e6d0a8ca9`. Those packages declare
`keiro` and `keiro-core` unbounded, so the pin resolves against 0.15.0.0 without change and is
not a blocker. It moves only when `mori://shinzui/danwa` ExecPlan 13 completes that
repository's own move onto this cohort; until then the stale pin is recorded as a retirement
condition rather than fixed.

**Language extensions that change.** All seven packages gain `OverloadedRecordDot` in their
`common common` stanza. `shikigami-core` additionally gains `NoFieldSelectors`.
`DuplicateRecordFields` and `OverloadedStrings` are already present everywhere. No module gains
a `{-# LANGUAGE FieldSelectors #-}` pragma; adding one anywhere is a defect against this plan.

**Interfaces that must exist unchanged at the end.** These are the load-bearing surfaces this
plan must not disturb, stated so that a reader can check them directly:

- `Shikigami.Generated.Conformance` continues to export `runServiceConformanceChecks :: IO [(String, Bool)]`
  and `serviceConformanceFacts :: [(String, String)]`, and remains in `exposed-modules` of
  `shikigami-core`'s library so the generated `keiro-shikigami-conformance` test package, which
  depends on `shikigami-core`, can import it.
- `Shikigami.RunEvidence.Conformance` continues to export
  `runEvidenceBehaviorConformanceReport :: BehaviorConformanceReport` and
  `runEvidenceBehaviorConformancePassed :: Bool`.
- `Shikigami.RunEvidence.BehaviorHoles` continues to export
  `behaviorWitnesses :: [BehaviorWitness]`.
- The three `*/Generated/WorkflowRuntime.hs` modules continue to export `workflowName`,
  `declaredPatches`, `allocateDeclaredAwait`, and their named await values, which
  `Shikigami.Agent.Approval.Workflow`, `Shikigami.Agent.Conversation`,
  `Shikigami.Agent.Workflow.Name`, and `Shikigami.Workflow.Versioning` consume qualified.
- `Shikigami.RunEvidence.Generated.Domain`'s command and event constructors, and the `*Data`
  field labels `runEvidenceId` and `runId`, which `Shikigami.Attestation.Evidence` builds
  positionally today and which do not rename.

**Upstream artifacts this plan depends on.** The Keiro release `keiro-dsl-0.15.0.0` and its five
sibling tags on `mori://shinzui/keiro`; the adoption guide
`docs/guides/adopting-keiro-dsl-idiomatic-v2.md` and the upgrade edge
`blueprints/keiro-upgrade/migrations/0-14-to-0-15.md` in that same checkout; and a Kioku release
on `mori://shinzui/kioku` admitting `keiro ^>=0.15.0.0`, which does not exist at the time this
plan was written and is the plan's only external blocker.
