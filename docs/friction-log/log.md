# Bundle Update Log

## 2026-10-28
* **Update**: FRIC-13 accepted: Accept the qualified module-local O0 workaround after all 1057 tests, full build, compatible evolution/conformance and schema isolation passed.
* **Update**: FRIC-13 logged: Replace the disproven narrow transform workaround with the module-local unoptimized boundary that passed the complete capability group; full-suite qualification pending.
* **Update**: FRIC-13 logged: Full-suite recurrence invalidated acceptance of the provisional transform exclusion; reopen investigation.
* **Update**: FRIC-13 accepted: Accept the narrow compiler workaround after clean-build failure and passing controlled transform-disabled replay.
* **Addition**: FRIC-13 records detour tooling friction with https://www.haskell.org/ghc/: Expanded Flow registry crashes during garbage collection under GHC worker-wrapper
* **Update**: FRIC-12 accepted: EP-3 qualifies generation-bound message and timer publication and accepts the composition cost.
* **Addition**: FRIC-12 records detour interface friction with mori://shinzui/keiro/packages/keiro: Awakeable repair requires an explicit publishing-generation transaction
* **Update**: FRIC-11 resolved: Record the separately affected EP-2 occurrence after the producer was identified during EP-3.
* **Addition**: FRIC-11 records detour tooling friction with mori://shinzui/shikigami: Selection migration inherited executable output from the recipe comment
* **Update**: FRIC-10 resolved: The isolated migration recipe probe passed; applied migration bytes are unchanged.
* **Addition**: FRIC-10 records detour tooling friction with mori://shinzui/shikigami: Migration template executes the schema check inside SQL
* **Update**: FRIC-9 accepted: Accept the versioned codec solution and document the worker-before-producer rollout in ADR 0051.
* **Update**: FRIC-8 accepted: Retain the validated isolated-source workaround.
* **Addition**: FRIC-9 records detour interface friction with mori://shinzui/keiro/packages/keiro-dsl: Queue payload additions have no optional compatibility policy
* **Addition**: FRIC-8 records detour environment friction with mori://shinzui/kikan-en: Resource-ledger baseline needs isolated Kikan sources

## 2026-10-26
* **Update**: FRIC-7 resolved: Resolved the handler-hook gap using existing released APIs; no owner callback or release is required. ADR 0050 records the retention condition.

## 2026-10-25
* **Update**: FRIC-7 promoted: IR-10 and plan 91 retain the automatic-disposition acceptance gate as an explicit owner-release prerequisite.
* **Addition**: FRIC-7 records blocked interface friction with mori://shinzui/keiro: Automatic PGMQ exhaustion bypasses the domain disposition hook
* **Update**: FRIC-6 accepted: The complete keiro gate passes with zero durable-contract findings.
* **Addition**: FRIC-6 records detour tooling friction with mori://shinzui/shikigami: Keiro scaffold drift check includes hand-owned core edits
* **Update**: FRIC-5 accepted: Serial execution verified the full suite without exceeding connection capacity.
* **Update**: FRIC-4 accepted: Catalog validation completed through the existing local override.
* **Addition**: FRIC-5 records detour tooling friction with mori://shinzui/shikigami: Parallel PostgreSQL suite exhausts ephemeral connection capacity
* **Addition**: FRIC-4 records detour environment friction with mori://shinzui/shikigami: Default Cabal project points at missing Kikan packages
* **Update**: FRIC-3 accepted: The HTTPS archive cache fill bypassed the 403 without changing package selection.
* **Addition**: FRIC-3 records detour environment friction with https://hackage.haskell.org/package/hw-kafka-streamly-0.2.0.0: Legacy Cabal package mirror rejects a required source archive
* **Update**: FRIC-2 accepted: Serial test scheduling passed all 208 PostgreSQL cases without changing the fixture server or application pools.
* **Addition**: FRIC-2 records detour tooling friction with mori://shinzui/shikigami: Default PostgreSQL test parallelism exhausts fixture connections
* **Update**: FRIC-1 accepted: The upstream packages are available; use an isolated source checkout to validate without mutating the older local dependency checkout.
* **Addition**: FRIC-1 records blocked environment friction with mori://shinzui/kikan-en: Baseline build references absent Kikan action packages
* **Adoption**: Adopt the `friction-log` profile (`coordination.frictionLog`) from https://raw.githubusercontent.com/shinzui/okf-profiles/v0.23.0/package.dhall.
