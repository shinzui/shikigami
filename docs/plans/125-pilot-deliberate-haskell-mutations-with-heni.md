---
id: 125
slug: pilot-deliberate-haskell-mutations-with-heni
title: "Pilot deliberate Haskell mutations with Heni"
kind: exec-plan
created_at: 2026-11-09T13:41:25Z
intention: "intention_01m4m2pjz6es9v9aqq5jq9c4ee"
provenance:
  created_by:
    model: "gpt-6.1-sol"
    harness: "codex-cli"
    at: 2026-11-09T13:41:25Z
  revisions:
    - model: "gpt-6.1-sol"
      harness: "codex-cli"
      at: 2026-11-09T13:46:42Z
      mode: "implement"
      note: "Implement focused production-module mutation cases with separate Heni CLI and exact diagnostic evidence."
---

# Pilot deliberate Haskell mutations with Heni

This ExecPlan is a living document. The sections Progress, Surprises & Discoveries,
Decision Log, and Outcomes & Retrospective must be kept up to date as work proceeds.
If durable project context changes, update or create ADRs in docs/adr/ in the same change.
Record friction met while implementing in the friction-log bundle as it occurs (see FRICTION.md).


## Purpose / Big Picture

Prove that the existing Haskell suite detects deliberate implementation faults in
resource admission, billing completeness and root revision fencing. A developer
runs `just mutation-tests` with a separately installed Heni executable and receives
a report attributing each detection to a declared test diagnostic. The pilot does
not add Heni to the production dependency cohort or replace ordinary tests.

## Progress

- [x] 2026-11-09: Deliver a reproducible, bounded pilot with three caught mutations and an unchanged passing control; the released Heni CLI accepts all six checked cases.
- [x] 2026-11-09: Qualify the pilot with survivor and unrelated compile-error controls, publish matching source/report identities and document its limits; 789 core tests, conventions and 13 checker tests pass.

## Surprises & Discoveries

A focused GHC build can compile the actual production resource module and its
owning test module as explicit home modules, while importing remaining dependencies
from the project's Cabal environment. Clearing the implicit source search path
with `-i` avoids recompiling the entire service. The first representative build
passed all eleven resource tests. It does not qualify other production modules.

## Decision Log

- Decision (2026-11-09): Use the released, separately built Heni 0.1.0.0 CLI and
  its generic exact-diagnostic contract. Its optional Tasty reporter requires a
  newer Tasty/Aeson/Crypton cohort; upgrading that cohort is outside this pilot.
  Literal failure witnesses, successful baseline/build stages and exact exit
  status provide bounded evidence without pretending to have structured test IDs.
- Decision (2026-11-09): Mutate only the pure production resource owner and reuse
  `Shikigami.ExecutionResourcesSpec`. Force recompilation in each fresh workspace.
  Do not duplicate accounting rules, add database fixtures or claim runtime containment.

## Outcomes & Retrospective

The pilot is complete. The final positive campaign exits 0 with three generic
semantic detections and one passing control. The negative campaign exits 1 with
one survivor and one unexpected build failure, both correctly excluded from
caught results. The campaigns retain the same exact source identity; every
baseline compiles and passes the 11 owning resource tests. The regular core suite
passes 789 tests. [Published qualification](../evidence/mutation/qualification.md)
retains byte-for-byte reports, source hashes, transcripts and scope limits.

The finite-capacity fault also trips the older refusal-order assertion. Generic
diagnostics establish that the intended assertion failed, not that it was the
only failing assertion. Structured test membership remains unknown. No reporter
or production dependency upgrade was needed, and production source remains
unchanged. [ADR 122](../adr/0122-deliberate-mutations-use-a-separate-haskell-tool-and-owning-tests.md)
preserves the tool/dependency boundary and evidence requirements. No friction
entry required triage for this plan. Further database, ownership-workflow or
whole-service campaigns remain separate work, requiring their own fixture scope.

The follow-up metadata correction declares `shinzui/heni:heni-cli` in
`mori.dhall`, with Dev scope and version `==0.1.0.0` on the owning core package,
plus the project dependency and typed package reference. This records an external
development executable, not a linked Heni library. Mori validation resolves all
257 dependencies without changing the schema pin or production dependency cohort.

## Context and Orientation

`shikigami-core/src/Shikigami/Execution/Resources.hs` owns pure resource admission,
complete settlement and root revision checks. Its existing suite is
`shikigami-core/test/Shikigami/ExecutionResourcesSpec.hs`.
[ADR 51](../adr/0051-resource-roots-own-conservative-reservations-and-actual-attempts.md)
requires conservative reservations, complete measured billing and preserved
uncertainty. [ADR 76](../adr/0076-resource-amounts-are-checked-before-accounting-publication.md)
requires checked arithmetic and finite-limit refusal before overflow. These rules
remain unchanged; the pilot tests whether faults in their implementation are detected.

Heni, `mori://shinzui/heni`, runs checked source edits in disposable workspaces.
Its library and optional reporter are independent of the service. The Heni
project-relative paths `docs/user/cli.md`, `docs/user/manifest-reference.md` and
`docs/user/migration-guide.md` describe the contracts; artifact-level URIs are pending.
A mutation is a deliberate source edit. A survivor builds and passes its tests
without the required detection. A compile failure is separate from semantic detection.

## Plan of Work

The first milestone adds `tests/mutation/heni.json`, a native Haskell build adapter
and a small Main module importing the existing owning test suite. The manifest
captures only the resource implementation, its tests and the pilot files. It
contains three guard-bypass faults and one unchanged control tagged `pilot`.
The `mutation-tests` recipe prepares the project's compiled dependencies and runs
Heni within the live `cabal exec` environment. Each stage has a finite timeout;
compilation uses explicit source files and `-fforce-recomp` without build reuse.

The second milestone runs two negative controls: a harmless comment must survive,
and an unknown Haskell identifier must be an unexpected build failure. Publish
reports and a scope note under `docs/evidence/mutation/`, with installation and
repeat commands in `tests/mutation/README.md`. Run the owning regular suite and
format/style checks at the completed boundary.

## Concrete Steps

Run from the repository root. Use a new output directory for each campaign.

```bash
mkdir -p .dev/heni/bin
nix develop --no-write-lock-file -c cabal install --ignore-project heni-cli-0.1.0.0 --installdir=.dev/heni/bin --install-method=copy -j2
nix develop --no-write-lock-file -c cabal build shikigami-core-test
nix develop --no-write-lock-file -c cabal exec -- "$PWD/.dev/heni/bin/heni" check tests/mutation/heni.json
nix develop --no-write-lock-file -c just mutation-tests .dev/heni/bin/heni mutation-results/pilot
nix develop --no-write-lock-file -c cabal exec -- "$PWD/.dev/heni/bin/heni" run tests/mutation/heni.json --tag negative-control --output mutation-results/controls
```

The pilot exits zero for three semantic detections and one passing control.
The negative-control campaign deliberately exits nonzero and reports one survivor
and one unexpected build failure, with neither counted as caught.

## Validation and Acceptance

The actual released Heni CLI must accept every checked edit. A fresh unmodified
baseline passes before each edited candidate. The finite-capacity, missing-billing
and stale-revision candidates build, fail their owning assertions and match their
exact declared diagnostics. The unchanged control passes. The harmless comment
survives, and a missing identifier refuses at build time rather than being
misclassified as a successful semantic test. Retain Heni's reports and source hashes.

Run the regular owning suite with:

```bash
nix develop --no-write-lock-file -c cabal test shikigami-core-test --test-show-details=direct
nix fmt -- tests/mutation/Build.hs tests/mutation/Main.hs shikigami-core/test/Shikigami/ExecutionResourcesSpec.hs
nix develop --no-write-lock-file -c just haskell-conventions
git diff --check
```

No actual-model, PostgreSQL, Linux containment or restart-recovery acceptance is
implied by this pure-module pilot. Generic diagnostic evidence leaves test
selection/counts unknown; the ordinary Tasty output is separate supporting evidence.

## Idempotence and Recovery

Heni leaves source files unchanged and refuses an existing output directory.
Choose a fresh child under ignored `mutation-results/` to repeat a campaign.
A failed baseline, stale edit, timeout or build error must be investigated rather
than accepted as a caught semantic mutation. Generated `.heni-build` directories
are private per workspace and rebuilt from source. The compiled dependency package
databases are read-only inputs; the focused build does not rebuild or mutate them.

## Interfaces and Dependencies

`just mutation-tests HENI OUTPUT` requires the released external Heni CLI, the
repository's GHC 9.12.4 development shell, and a successful `cabal build
shikigami-core-test`. `cabal exec` supplies the exact solved package environment
for the duration of Heni's child builds. `tests/mutation/Build.hs` requires that
environment and invokes GHC with explicit home modules; `tests/mutation/Main.hs`
imports the real resource test tree. Heni owns mutation application, supervision,
baselines, candidate verdicts and report publication. The adapter owns only the
focused compilation command. No native process containment or database resource
lifecycle is delegated to this pilot.
