# Bundle Update Log

## 2026-10-25
* **Update**: FRIC-2 accepted: Serial test scheduling passed all 208 PostgreSQL cases without changing the fixture server or application pools.
* **Addition**: FRIC-2 records detour tooling friction with mori://shinzui/shikigami: Default PostgreSQL test parallelism exhausts fixture connections
* **Update**: FRIC-1 accepted: The upstream packages are available; use an isolated source checkout to validate without mutating the older local dependency checkout.
* **Addition**: FRIC-1 records blocked environment friction with mori://shinzui/kikan-en: Baseline build references absent Kikan action packages
* **Adoption**: Adopt the `friction-log` profile (`coordination.frictionLog`) from https://raw.githubusercontent.com/shinzui/okf-profiles/v0.23.0/package.dhall.
