# Keiro 0.22 adoption and runtime-pattern audit

Audit date: 2026-10-28. This is an initial source audit and implementation ledger, not a passing runtime qualification. No build, migration or replay test was executed as part of plan creation. The current dependency selection remains Keiro 0.18.0.0.

The implementation is coordinated by [MasterPlan 16](../masterplans/16-upgrade-shikigami-to-keiro-0-22-and-retire-superseded-runtime-workarounds.md). EP-1 is [plan 92](../plans/92-resolve-the-released-keiro-0-22-cohort-and-rehearse-the-composed-migration.md), EP-2 is [plan 93](../plans/93-adopt-guarded-catalog-commands-and-qualify-current-dsl-consumer-contracts.md), EP-3 is [plan 94](../plans/94-adopt-current-runtime-lifecycle-patterns-and-bounded-operator-inspection.md), and EP-4 is [plan 95](../plans/95-close-the-runtime-pattern-audit-and-qualify-the-keiro-0-22-rollout.md).

## Evidence boundary

The source baseline is Shikigami HEAD `93829c4b8f0a809bfb3586ecf3f65d7732e0ac56` plus the execution changes already in the working tree when planning began. Dirty files included `domain/shikigami-execution.keiro`, `Shikigami.Execution.Store`, workflow/executor/wake integration, generated execution artifacts and PostgreSQL fixtures. These changes belong to ongoing plan 83 work and were preserved. Implementation must capture the actual reconciled source tree before comparing builds; HEAD alone does not describe this baseline.

The guidance source is `mori://shinzui/keiro-runtime-patterns` revision `62531b00b415785be61584a3c44b569fdfb35c4e`, whose checkout was clean. Mori's documentation catalog lags newer inspection material, so the inventory below also scans the source's canonical `resource` metadata. The core standards reviewed in depth were runtime assembly, command/error handling, catalog preconditions, mapped consumers, semantic locality, durable workflow reliability/evolution, delivery lifecycle and inspection hosting. Other inventory rows are assigned for evidence closure; inclusion is not a claim of an in-depth review or compliance.

Published release facts were checked through Hackage package JSON/current Cabal descriptors and remote upstream tags. Keiro 0.22.0.0 is published for all eight packages, and all peeled tags share `b28201f2063fa4f6dcb724cbf474959107e36b74`. The [upstream release](https://github.com/shinzui/keiro/releases/tag/keiro-0.22.0.0) describes the cohort. Hackage's package registry endpoint is [Keiro versions](https://hackage.haskell.org/package/keiro.json). Package identities are `mori://shinzui/keiro/packages/keiro`, `mori://shinzui/keiro/packages/keiro-core`, `mori://shinzui/keiro/packages/keiro-dsl`, `mori://shinzui/keiro/packages/keiro-pgmq`, `mori://shinzui/keiro/packages/keiro-migrations`, `mori://shinzui/keiro/packages/keiro-test-support`, `mori://shinzui/keiro/packages/keiro-ops` and the optional `mori://shinzui/keiro/packages/keiro-ops-http`.

Published `mori://shinzui/kioku/packages/kioku-core` 0.12.0.0 admits Keiro 0.22 and `mori://shinzui/kiroku/packages/kiroku-store` 0.12. The newest standalone Store is 0.13.0.0, outside those bounds; it is not the chosen substrate. The final compatible patch set requires a solver run. Runtime release notes and source are at `mori://shinzui/keiro`, project-relative `CHANGELOG.md` and `blueprints/keiro-upgrade/migrations/` (artifact-level source URIs pending). Read every intervening edge, including entailed upstream upgrades.

## Findings and required dispositions

| ID | Source finding | Required result | Owner | State |
|---|---|---|---|---|
| K22-1 | `cabal.project`, package bounds and `mori.dhall` select 0.18 with older Kioku/Store/Shibuya/PGMQ/pg-migrate. | One published compatible 0.22 cohort; updated descriptors and metadata; release-only solve/build evidence. | EP-1 | Confirmed upgrade work |
| K22-2 | `cabal.project` retains `pg-migrate-test-support:ephemeral-pg`; released pg-migrate-test-support 1.2 admits `>=0.3.1 && <0.4`. | Remove this scoped workaround while migration smoke fixtures pass. Treat `claude:http-client-tls` separately. | EP-1 | Confirmed obsolete workaround |
| K22-3 | `Shikigami.Migrations` composes four components and vendors PGMQ under a historical application migration. | Explicitly cover PGMQ 0007 and the Kiroku category/checkpoint/index/namespace migrations; preserve historical names/checksums and prove an old-schema upgrade. | EP-1 | Confirmed migration ownership risk |
| K22-4 | `Shikigami.Execution.Store.persist` captures relational checks/writes in a live projection and routes expected failures with `ExecutionAbort`. | Adopt typed guarded preconditions for eligible pre-inline admission checks. Retain `ExecutionAbort` rollback for post-write hooks and write-time owner refusals; inventory retained sites and prove both rollback paths, fence behavior and retry semantics. | EP-2 | Replacement candidate grounded in source; integration proof required |
| K22-5 | `Trigger.Consumer` constructs Shibuya `AppConfig` directly; worker health imports pre-Paused states. | Default-based assembly, truthful Paused health, deliveryStatus admission and permanent finalizer failure reaching supervision. | EP-1 compile adaptation; EP-3 semantics | Confirmed new API obligations |
| K22-6 | Generator 0.21 changes whole-name symbols, all BehaviorContract reports and history-backed initial witnesses. | Regenerate six-member workspace, preserve create-once bodies, compile actual consumers and run full service conformance. | EP-1 baseline; EP-2 evidence | Required source compatibility work |
| K22-7 | Existing ops hooks mount replay/catalog but no application aggregate descriptors. | Mount narrow RunEvidence/ExecutionLifecycle descriptors and exercise bounded upstream workflow/timer/projection inspection. | EP-3 | Applicable feature adoption |
| K22-8 | Domain inventory and 0.18 adoption record describe five workspace members; current manifest has six including ExecutionLifecycle. | Current census, evidence ownership and qualified exceptions match final runtime. Preserve historical release records. | EP-2 census; EP-4 closure | Confirmed documentation drift |
| K22-9 | Nix deployment closure is separately frozen under `nix/qualification/`. | Re-export the final solve and compile/verify all four role artifacts. | EP-4 | Required packaging integration |
| K22-10 | Prior qualification targets 0.18; its direct rollback was migration-neutral. | Independent old/new retained-history proof and a stopped-writer 0.22 migration/recovery runbook. | EP-4 | New qualification required |

The generated catalog and live factories already preserve separate evidence/execution projection sets by source, and startup registration uses the shared catalog. The new source audit must preserve that design. Existing tests/ADRs support it, but no 0.22 pass is claimed here. Protected replay data is live-only and cannot be reconstructed from lifecycle events.

## Feature and workaround decisions

Typed catalog preconditions are selected for execution admission checks that can be decided before inline delivery. The released callback runs before projections and cannot represent a later refusal. Preserve the post-write `recordOutcomeAndAdvanceWith` hook and exception rollback for accounting/settlement owner failures, mapping the error only after transaction rollback. K22-4 closes with tested migration of eligible checks and an explicit inventory of retained exception sites, not wholesale removal of `ExecutionAbort`. `runDomainCommandWithCatalogProjectionsGuarded` returns `PreconditionRefused` only after rollback and does not provide a committed receipt/position. Keep checks bounded under the catalog fence, retain the application lock order and make no external call in a retriable transaction. Its guide is `mori://shinzui/keiro/okf/guides/concepts/DOC-29`; the relevant standards are `mori://shinzui/keiro-runtime-patterns/docs/keiro-projection-catalogs` and `mori://shinzui/keiro-runtime-patterns/docs/keiro-command-cycle-and-errors`. This is not permission to move all rich writes into an unrestricted guard callback or to discard late rollback protection.

The 0.21 mapped initial/write-lift and public scalar-list capabilities, and 0.22 structural enum equality, require consumer-by-consumer review. Current ExecutionLifecycle uses Text/Int rather than mapped enums. RunEvidence's six ID/Text equality guards are not made exhaustive by structural enum equality. Queue route/trigger values retain existing Aeson spellings and refined/opaque identity parsers. Apply new checked support where it replaces a real adapter with equivalent laws and history; otherwise record a bounded non-applicability. Neither a declaration nor changed generated bytes proves adoption.

The RunJobs versioned application input inside the generated queue is retained. FRIC-9 (`docs/friction-log/9-queue-payload-additions-have-no-optional-compatibility-policy.md`) records that optional structural queue fields are still unsupported at the released 0.22 cohort. Keep literal historical v1/v2/v3 readers and newer execution input versions present at handoff. This is distinct from the fixture-bound workaround that can now be removed.

Rich live-only projection handlers, application SQL/read-model holes and history-backed behavior witnesses remain actual application responsibilities. The new release does not supply missing Baikai replay decoders or permission to expose protected payloads. Preserve their precise necessity; review whether any particular hole is genuinely superseded before deleting it. `mori://shinzui/keiro-runtime-patterns/docs/keiro-mapped-consumer-surfaces` requires independent wire/register/fold/snapshot/replay evidence for any native-enum adapter replacement.

The existing resource-aware resume worker and process-local ops database adapter remain capability checks, not assumed cleanup targets. Reinspect the released exports: remove either only when the supported public effect/configuration boundary actually replaces it. No effect cast, private schema SQL or parser introspection is a substitute.

Bounded workflow/timer/projection/shard reads and explicit aggregate inspection are selected through the existing CLI. Application inspectors must render narrow lifecycle metadata using the shared hydration path; they must not reuse a rich snapshot JSON codec as a display policy. No compiled process manager currently exists to mount, and no namespace/shard topology change is needed merely for this upgrade. Snapshot seed verification inherits its released bounded defaults; ordinary command provenance stays disabled.

The new HTTP operations package, composed browser surfaces and shared live feeds are optional and not selected. Their absence is not a finding against a CLI-only operator surface. If selected later, dedicated capacity, host authentication, Origin policy, default-disabled mutations, finite read/encoding/delivery budgets, schema checks and joined feed shutdown become required under `mori://shinzui/keiro-runtime-patterns/docs/inspection-hosting-and-browser-access` and `mori://shinzui/keiro-runtime-patterns/docs/inspection-bounded-live-feeds`.

## Architecture context

Consulted local decisions: [ADR 0001](../adr/0001-declare-only-what-the-runtime-executes.md), [ADR 0012](../adr/0012-a-declared-workflow-body-only-grows-behind-a-patch.md), [ADR 0037](../adr/0037-adopt-the-released-keiro-contracts-before-v1.md), [ADR 0038](../adr/0038-runtime-startup-and-maintenance-share-validated-owners.md), [ADR 0039](../adr/0039-deployment-roles-share-a-frozen-cabal-source-closure.md) and [ADR 0053](../adr/0053-execution-lifecycle-and-protected-replay-share-an-atomic-boundary.md). Their existing declarations, persistence, startup, retention and packaging constraints remain binding. The historical pre-v1 reset does not authorize deleting current journals.

Cross-repository decisions were discovered through Mori and read from the owning source: `mori://shinzui/keiro/okf/adrs/concepts/ADR-28` requires public owning APIs for operations; `mori://shinzui/keiro/okf/adrs/concepts/ADR-54` requires explicit aggregate descriptors, safe display policy and shared hydration. These principles determine the selected CLI inspection path.

## Complete source inventory for closure

The pinned source contains 94 documents with canonical resource metadata. Each row must receive an actual applicability, implementation/evidence reference and final disposition in EP-4. “Pending evidence” is deliberate: this inventory prevents omissions and does not falsely label unreviewed standards compliant. Owners may hand off a specific finding through the MasterPlan integration points.

| Canonical standard | Closure owner | Current disposition |
|---|---|---|
| `mori://shinzui/keiro-runtime-patterns/docs/architecture-cross-cutting-modules` | EP-4 | Pending evidence |
| `mori://shinzui/keiro-runtime-patterns/docs/architecture-domain-design` | EP-4 | Pending evidence |
| `mori://shinzui/keiro-runtime-patterns/docs/architecture-domain-newtypes-and-typeids` | EP-4 | Pending evidence |
| `mori://shinzui/keiro-runtime-patterns/docs/architecture-extended-node-verticals` | EP-4 | Pending evidence |
| `mori://shinzui/keiro-runtime-patterns/docs/architecture-generated-compilation-contract` | EP-4 | Pending evidence |
| `mori://shinzui/keiro-runtime-patterns/docs/architecture-overview` | EP-4 | Pending evidence |
| `mori://shinzui/keiro-runtime-patterns/docs/architecture-service-packages` | EP-4 | Pending evidence |
| `mori://shinzui/keiro-runtime-patterns/docs/architecture-spec-and-scaffolding` | EP-4 | Pending evidence |
| `mori://shinzui/keiro-runtime-patterns/docs/architecture-test-layout` | EP-4 | Pending evidence |
| `mori://shinzui/keiro-runtime-patterns/docs/architecture-vertical-slice-modules` | EP-4 | Pending evidence |
| `mori://shinzui/keiro-runtime-patterns/docs/architecture-worked-example-conversation` | EP-4 | Pending evidence |
| `mori://shinzui/keiro-runtime-patterns/docs/config-kubernetes-deployment` | EP-3 | Pending evidence |
| `mori://shinzui/keiro-runtime-patterns/docs/config-overview` | EP-3 | Pending evidence |
| `mori://shinzui/keiro-runtime-patterns/docs/config-settei-cli-standard` | EP-3 | Pending evidence |
| `mori://shinzui/keiro-runtime-patterns/docs/config-settei-gotchas` | EP-3 | Pending evidence |
| `mori://shinzui/keiro-runtime-patterns/docs/config-settei-service-standard` | EP-3 | Pending evidence |
| `mori://shinzui/keiro-runtime-patterns/docs/runtime-patterns-getting-started` | EP-4 | Pending evidence |
| `mori://shinzui/keiro-runtime-patterns/docs/inspection-bounded-live-feeds` | EP-3 | Pending evidence |
| `mori://shinzui/keiro-runtime-patterns/docs/inspection-hosting-and-browser-access` | EP-3 | Pending evidence |
| `mori://shinzui/keiro-runtime-patterns/docs/inspection-overview` | EP-3 | Pending evidence |
| `mori://shinzui/keiro-runtime-patterns/docs/keiki-build-time-validation` | EP-2 | Pending evidence |
| `mori://shinzui/keiro-runtime-patterns/docs/keiki-checked-composition` | EP-2 | Pending evidence |
| `mori://shinzui/keiro-runtime-patterns/docs/keiki-collections-and-opaque-guards` | EP-2 | Pending evidence |
| `mori://shinzui/keiro-runtime-patterns/docs/keiki-constructor-evidence` | EP-2 | Pending evidence |
| `mori://shinzui/keiro-runtime-patterns/docs/keiki-diagnosing-rejected-commands` | EP-2 | Pending evidence |
| `mori://shinzui/keiro-runtime-patterns/docs/keiki-diagram-docs` | EP-2 | Pending evidence |
| `mori://shinzui/keiro-runtime-patterns/docs/keiki-event-schema-evolution` | EP-2 | Pending evidence |
| `mori://shinzui/keiro-runtime-patterns/docs/keiki-exact-projection-domains` | EP-2 | Pending evidence |
| `mori://shinzui/keiro-runtime-patterns/docs/keiki-json-event-codecs` | EP-2 | Pending evidence |
| `mori://shinzui/keiro-runtime-patterns/docs/keiki-operator-conflicts` | EP-2 | Pending evidence |
| `mori://shinzui/keiro-runtime-patterns/docs/keiki-overview` | EP-2 | Pending evidence |
| `mori://shinzui/keiro-runtime-patterns/docs/keiki-structured-replay-and-hydration` | EP-2 | Pending evidence |
| `mori://shinzui/keiro-runtime-patterns/docs/keiki-transducer-best-practices` | EP-2 | Pending evidence |
| `mori://shinzui/keiro-runtime-patterns/docs/keiki-typed-field-projections` | EP-2 | Pending evidence |
| `mori://shinzui/keiro-runtime-patterns/docs/keiki-upgrading-to-keiki-0-2` | EP-2 | Pending evidence |
| `mori://shinzui/keiro-runtime-patterns/docs/keiro-aggregate-expressions` | EP-2 | Pending evidence |
| `mori://shinzui/keiro-runtime-patterns/docs/keiro-behavior-conformance` | EP-2 | Pending evidence |
| `mori://shinzui/keiro-runtime-patterns/docs/keiro-brownfield-adoption` | EP-2 | Pending evidence |
| `mori://shinzui/keiro-runtime-patterns/docs/keiro-command-cycle-and-errors` | EP-2 | Pending evidence |
| `mori://shinzui/keiro-runtime-patterns/docs/keiro-dead-timer-resume` | EP-3 | Pending evidence |
| `mori://shinzui/keiro-runtime-patterns/docs/keiro-dsl-adoption` | EP-2 | Pending evidence |
| `mori://shinzui/keiro-runtime-patterns/docs/keiro-dsl-semantic-locality` | EP-2 | Pending evidence |
| `mori://shinzui/keiro-runtime-patterns/docs/keiro-durable-workflows` | EP-3 | Pending evidence |
| `mori://shinzui/keiro-runtime-patterns/docs/keiro-evolution-and-rollout` | EP-4 | Pending evidence |
| `mori://shinzui/keiro-runtime-patterns/docs/keiro-generated-haskell-editions` | EP-2 | Pending evidence |
| `mori://shinzui/keiro-runtime-patterns/docs/keiro-gotchas` | EP-3 | Pending evidence |
| `mori://shinzui/keiro-runtime-patterns/docs/keiro-identifier-domains` | EP-2 | Pending evidence |
| `mori://shinzui/keiro-runtime-patterns/docs/keiro-language-versions` | EP-3 | Pending evidence |
| `mori://shinzui/keiro-runtime-patterns/docs/keiro-mapped-consumer-surfaces` | EP-2 | Pending evidence |
| `mori://shinzui/keiro-runtime-patterns/docs/keiro-nominal-bindings` | EP-2 | Pending evidence |
| `mori://shinzui/keiro-runtime-patterns/docs/keiro-operations-console` | EP-3 | Pending evidence |
| `mori://shinzui/keiro-runtime-patterns/docs/keiro-overview` | EP-3 | Pending evidence |
| `mori://shinzui/keiro-runtime-patterns/docs/keiro-projection-catalogs` | EP-2 | Pending evidence |
| `mori://shinzui/keiro-runtime-patterns/docs/keiro-read-models-and-projections` | EP-3 | Pending evidence |
| `mori://shinzui/keiro-runtime-patterns/docs/keiro-runtime-assembly` | EP-3 | Pending evidence |
| `mori://shinzui/keiro-runtime-patterns/docs/keiro-service-workspaces` | EP-2 | Pending evidence |
| `mori://shinzui/keiro-runtime-patterns/docs/keiro-stream-scoped-repair` | EP-3 | Pending evidence |
| `mori://shinzui/keiro-runtime-patterns/docs/keiro-telemetry` | EP-3 | Pending evidence |
| `mori://shinzui/keiro-runtime-patterns/docs/keiro-two-schema-arrangement` | EP-4 | Pending evidence |
| `mori://shinzui/keiro-runtime-patterns/docs/keiro-typeid-prefix-naming` | EP-3 | Pending evidence |
| `mori://shinzui/keiro-runtime-patterns/docs/keiro-workflow-reliability` | EP-3 | Pending evidence |
| `mori://shinzui/keiro-runtime-patterns/docs/kiroku-append-and-read` | EP-3 | Pending evidence |
| `mori://shinzui/keiro-runtime-patterns/docs/kiroku-checkpoint-inventory` | EP-3 | Pending evidence |
| `mori://shinzui/keiro-runtime-patterns/docs/kiroku-connection-settings` | EP-3 | Pending evidence |
| `mori://shinzui/keiro-runtime-patterns/docs/kiroku-history-retention` | EP-3 | Pending evidence |
| `mori://shinzui/keiro-runtime-patterns/docs/kiroku-inspection` | EP-3 | Pending evidence |
| `mori://shinzui/keiro-runtime-patterns/docs/kiroku-lifecycle-and-deletion` | EP-3 | Pending evidence |
| `mori://shinzui/keiro-runtime-patterns/docs/kiroku-observability` | EP-3 | Pending evidence |
| `mori://shinzui/keiro-runtime-patterns/docs/kiroku-operational-invariants` | EP-3 | Pending evidence |
| `mori://shinzui/keiro-runtime-patterns/docs/kiroku-overview` | EP-3 | Pending evidence |
| `mori://shinzui/keiro-runtime-patterns/docs/kiroku-subscriptions` | EP-3 | Pending evidence |
| `mori://shinzui/keiro-runtime-patterns/docs/kiroku-transactions-and-projections` | EP-3 | Pending evidence |
| `mori://shinzui/keiro-runtime-patterns/docs/messaging-glossary` | EP-3 | Pending evidence |
| `mori://shinzui/keiro-runtime-patterns/docs/messaging-gotchas` | EP-3 | Pending evidence |
| `mori://shinzui/keiro-runtime-patterns/docs/messaging-inbox` | EP-3 | Pending evidence |
| `mori://shinzui/keiro-runtime-patterns/docs/messaging-integration-events` | EP-3 | Pending evidence |
| `mori://shinzui/keiro-runtime-patterns/docs/messaging-kiroku-subscriptions` | EP-3 | Pending evidence |
| `mori://shinzui/keiro-runtime-patterns/docs/messaging-outbox` | EP-3 | Pending evidence |
| `mori://shinzui/keiro-runtime-patterns/docs/messaging-overview` | EP-3 | Pending evidence |
| `mori://shinzui/keiro-runtime-patterns/docs/messaging-pgmq-connection-faults` | EP-3 | Pending evidence |
| `mori://shinzui/keiro-runtime-patterns/docs/messaging-pgmq-dead-letter-administration` | EP-3 | Pending evidence |
| `mori://shinzui/keiro-runtime-patterns/docs/messaging-pgmq-jobs` | EP-3 | Pending evidence |
| `mori://shinzui/keiro-runtime-patterns/docs/messaging-pgmq-queue-reconciliation` | EP-3 | Pending evidence |
| `mori://shinzui/keiro-runtime-patterns/docs/messaging-process-managers` | EP-3 | Pending evidence |
| `mori://shinzui/keiro-runtime-patterns/docs/messaging-shibuya-inspection` | EP-3 | Pending evidence |
| `mori://shinzui/keiro-runtime-patterns/docs/messaging-shibuya-processing` | EP-3 | Pending evidence |
| `mori://shinzui/keiro-runtime-patterns/docs/messaging-transport-selection` | EP-3 | Pending evidence |
| `mori://shinzui/keiro-runtime-patterns/docs/migrations-authoring` | EP-1 | Pending evidence |
| `mori://shinzui/keiro-runtime-patterns/docs/migrations-codd-transition` | EP-1 | Pending evidence |
| `mori://shinzui/keiro-runtime-patterns/docs/migrations-operations` | EP-1 | Pending evidence |
| `mori://shinzui/keiro-runtime-patterns/docs/migrations-overview` | EP-1 | Pending evidence |
| `mori://shinzui/keiro-runtime-patterns/docs/migrations-pg-migrate-model` | EP-1 | Pending evidence |
| `mori://shinzui/keiro-runtime-patterns/docs/migrations-service-package` | EP-1 | Pending evidence |
| `mori://shinzui/keiro-runtime-patterns/docs/migrations-testing` | EP-1 | Pending evidence |
