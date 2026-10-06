# Local agent qualification readiness

Updated 2026-10-06 UTC. Local workload: **blocked; not qualified**. Production:
**unproven**. Implementation authority is [plan 79](../../plans/79-qualify-local-agent-execution-and-prioritize-production-readiness.md).

The fresh baseline began at `120a09bbe563ff4c9a745b69d3286574876b9be5` on
2026-10-06T03:56:58Z. Source edits during qualification are listed below; historical
September evidence is not used as a current pass. Private raw logs are under
`$HOME/.local/state/shikigami/qualification/evidence/20261006T035658Z-baseline-10793/`.
Logs and generated build products remain outside this repository.

## Observed checks

| Case | Outcome | Command and evidence |
|---|---|---|
| Original Nix default | fail | `nix eval --raw .#packages.aarch64-darwin.default.drvPath`; `nix-default.log`: root has no Cabal file |
| Ambient dependency solve | fail | `cabal build all --dry-run`; `ambient-solve.log`: mutable Kioku 0.8.0.1 conflicts with Keiro 0.18 |
| Isolated committed solve | pass | `cabal build all --dry-run --project-file=PROJECT`; `isolated-solve.log` |
| Ambient build | fail | `cabal build all --enable-tests --project-file=PROJECT`; `build.log`: native librdkafka unavailable |
| Declared-shell build | pass | `nix develop --command cabal build all --enable-tests --project-file=PROJECT`; `build-devshell.log` |
| Migration SQL isolation | pass | `bash tools/check-migration-schema-isolation.sh`; `migration-schema.log`; historical immutable exception reported |
| Regression suites | pass after test correction | `nix develop --command cabal test shikigami-core-test shikigami-workers-test shikigami-server-test shikigami-migrations-test shikigami-core-postgres-test shikigami-migrations-smoke keiro-shikigami-conformance --project-file=PROJECT --test-show-details=direct`; `tests-devshell.log` plus `core-tests-retry.log` |
| Workflow specification | pass | `nix develop --command cabal run -v0 --project-file=PROJECT keiro-dsl -- check domain/shikigami.keiro-workspace --min-language 6 --deny-warnings --explain-bindings --report-out FILE --coverage-report FILE --fail-on-opaque`; `workflow-check.log`, `keiro-check.json`, `keiro-coverage.json` |
| Project relocation tests | pass | `python3 -m unittest discover -s tools/qualification -p 'test_*.py' -v`; preserves pins and overrides, rejects unsupported relocation |
| New per-role evaluation | pass | `nix eval --json .#packages.aarch64-darwin --apply builtins.attrNames` lists CLI, server, worker, migrate and optional roles; default derivation evaluation succeeds |
| Immutable Nix build | pending | `nix build --no-link .#shikigami .#shikigami-server .#shikigami-worker .#shikigami-migrate`; preliminary solve/staging corrections recorded in `nix-build-offline.log` and `nix-build-components.log`; compilation attempt in `nix-build-closure.log` was interrupted to validate final packaging inputs |

`PROJECT` is the exact isolated path recorded in `baseline.json`. The seven runtime
packages and mutable sibling revisions are recorded there. Migration smoke provisions
its own disposable PostgreSQL 18 instance; these commands do not use a production URL.
All non-core suites passed at the baseline source. Core's first run had one failure out
of 405: the 100 ms test action won a scheduling race against its 10 ms timeout. The
test now blocks on an empty MVar and has an independent 2-second bound. All 405 core
tests passed after that change; runtime timeout code and workflow bodies were unchanged.
Other suites passed 5 migration composition, 9 migration smoke, 88 worker, 47 server and
197 PostgreSQL core cases. Generated conformance passed.

## Source and packaging identity

`nix/qualification/cohort.json` records the 354-package runtime/component closure from
the successful GHC 9.12.4 solve, exact Hackage tarball and metadata hashes, selected flags,
five Git source revisions with NAR hashes, and the reviewed Kikan-En source archive.
The secure Cabal index supplied descriptor bytes only when they matched the solved plan's
hash. No package bound or cohort upgrade was introduced. Component restrictions exclude
unused dependency executables that Cabal otherwise tries to solve as local source goals.

The compatible `mori://shinzui/kikan-en/repos/kikan-en` commit
`16704290d527d413568bfa40c983f5c3604c35c8` is absent from its advertised GitHub remote;
the client also has no Hackage release. The checked-in archive contains exactly the
clean commit's contract/client trees and is checksum-verified during evaluation. This
is an explicit unpublished source pin, not evidence of a published upstream release.

## Ordered remaining work

The operator confirmed that none of the integration services are running. Startup
priority is PostgreSQL 18 plus Shomei and Kikan-En (dedicated database, machine
client, En issuer public keys/schema hashes and scoped grants), then Kawa plus
Anthropic credentials (report delivery), then Danwa and Kizashi (human waits and
alerts). Supply test URLs, source/participant/recipient identifiers and private
credential-file paths. Kafka, Kubernetes and a coding executor are outside this
qualification workload. The independent packaging build does not require these
services to be live.

| Priority | Scope and status | Reproducer / impact | Owner and next acceptance |
|---|---|---|---|
| 1 | Local scenario: pending immutable build | Run the four-role Nix build; package evaluation alone does not prove compilation or installed assets | [Plan 31](../../plans/31-deployable-service-stack-process-compose-packaging-and-configuration.md): complete offline build and outside-checkout startup/configuration/fixture checks |
| 2 | Local scenario: blocked authorization and destinations | No qualification runtime config, test-service endpoints, issuer keys/schema hashes or machine credential paths are declared; protected delivery must deny | `mori://shinzui/dotfiles.nix/plans/4-bootstrap-persistent-shikigami-agents-and-validate-service-migration-learning`: configure exact test trust and destinations, migrate dedicated DB, install distinct launchd jobs and prove restart |
| 3 | Local scenario: unproven live/report/recovery/waits | No real-model run, recorded recall, live receipt, fault rehearsal or supervised approval trial has occurred | [Plan 79](../../plans/79-qualify-local-agent-execution-and-prioritize-production-readiness.md): execute each bounded phase after the first two gates |
| 4 | Selected production practice review: open known defects | Attention transaction and resolver entitlement acceptance remains open; the reporter catalog does not enable this feature | [Plan 60](../../plans/60-harden-practice-review-attention-reservation-and-specialist-failure-boundaries.md), [plan 61](../../plans/61-enforce-practice-review-resolver-entitlement-and-harden-the-authorization-envelope.md): finish their regressions before enabling practice review |
| 5 | Workload-dependent turn recovery | Current Skill journals one coarse behavior step; mid-call crash may repeat model IO | [IR-14](../../improvement-requests/record-durable-model-tool-turns-and-compose-harness-policies.md): individual-turn recovery when the workload requires it; current crash trial still unproven |
| 6 | Later observation/coding/external operations | Supplied snapshots do not prove agent-owned Kubernetes observation or repository mutation | Plans [77](../../plans/77-add-a-read-only-k8s-observe-capability-provider-for-durable-agents.md), [48](../../plans/48-add-a-portable-one-off-repository-agent-harness.md), [78](../../plans/78-run-external-operations-from-durable-flows-through-idempotent-shiki-jobs.md) and their upstream prerequisites, selected only for the next workload |

Area-owner and subject-owner recipient strategies currently return no resolved recipient
in `Shikigami.Sink.Recipient`. The at-risk Flow therefore needs an explicitly configured
test fallback recipient. An activity payload alone does not prove directory routing.

## Production promotion gates

No target production host or enabled integration catalog has been selected. Deployment
of the same immutable artifacts, real destination authorization, backup restoration,
suspended-workflow supported upgrade, database/journal-compatible rollback and agreed
workload limits are all **unproven**. A fixture receiver can prove transport/retry
contracts; it cannot certify Kawa, Danwa, Kizashi or their production authorization.
