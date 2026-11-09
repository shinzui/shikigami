# 0122. Deliberate mutations use a separate Haskell tool and owning tests

Date: 2026-11-09

Status: accepted

## Context

Corrupting inputs checks defensive behavior but does not establish that the
suite detects faults in the implementation. Critical resource invariants need
deliberate guard-bypass tests. Their runner must distinguish semantic detection
from stale edits, compilation failures and unrelated failures.

Heni's initial optional Tasty reporter requires newer dependencies than the
service's qualified cohort. A tooling pilot does not justify changing that cohort.

## Decision

Use the separately built released CLI from `mori://shinzui/heni` for curated
mutation campaigns. Reuse the owning Haskell test suite. Heni owns checked edits,
fresh baselines, stage supervision, classification and portable reports; local
Haskell adapters own only consumer-specific compilation.

The initial pure-resource pilot compiles explicit production and test modules
afresh in each workspace, importing remaining compiled dependencies from the
project's live Cabal environment. Capture only the declared source files, clear
implicit source search paths and force recompilation. The host package databases
are trusted external inputs and must remain stable during a campaign. This is
focused module evidence, not a fresh whole-service build.

Generic diagnostic evidence requires a passing baseline, a successful candidate
build, the declared test exit and an exact diagnostic emitted only for a failing
assertion. Keep structured selection/counts unknown until an appropriate reporter
is integrated. Require unchanged, surviving-edit and unrelated-build-error
controls. Publish the evidence scope with each result; a curated score is not
repository-wide mutation coverage.

## Alternatives rejected

A new Python mutation runner would duplicate Heni's lifecycle and verdict rules.
Copying domain rules into a small substitute model would test different code.
Accepting any nonzero exit would count compiler errors as semantic detections.
Changing the production cohort solely to install a reporter expands the pilot's
scope. Reusing candidate binaries without verified input observation can hide edits.

## Consequences

Developers install the CLI independently and run campaigns through `cabal exec`
after preparing the owning suite's dependencies. New cases need exact edit
preconditions and meaningful witnesses. Database, workflow and process cases need
their own resource/containment acceptance before joining this pure-module pilot.
The ordinary test suite remains required.

## References

- [Pilot commands and limits](../../tests/mutation/README.md)
- [Plan 125](../plans/125-pilot-deliberate-haskell-mutations-with-heni.md)
- [Resource ownership](0051-resource-roots-own-conservative-reservations-and-actual-attempts.md)
- [Checked accounting](0076-resource-amounts-are-checked-before-accounting-publication.md)
