# Bundle Update Log

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
