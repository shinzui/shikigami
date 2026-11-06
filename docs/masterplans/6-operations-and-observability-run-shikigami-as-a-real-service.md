---
id: 6
slug: operations-and-observability-run-shikigami-as-a-real-service
title: "Operations and Observability: Run Shikigami as a Real Service"
kind: master-plan
created_at: 2026-07-08T20:13:36Z
intention: "intention_01kx1tyx3yehmsq9eyywdcf5c7"
provenance:
  revisions:
    - model: "gpt-5.6-sol"
      harness: "codex-cli"
      at: 2026-09-21T18:24:04Z
      mode: "update"
      note: "Reconciled status and progress during the 2026-09-21 portfolio audit"
    - model: "gpt-6.1-sol"
      harness: "codex-cli"
      at: 2026-10-29T13:10:20Z
      mode: "update"
      note: "Reconcile partial plan 31 packaging delivery with registry and progress"
    - model: "gpt-6.1-sol"
      harness: "codex-cli"
      at: 2026-11-06T21:09:33Z
      mode: "update"
      note: "Refresh current code, completed prerequisites, shared ownership and genuine remaining acceptance; preserve historical decisions."
---

# Operations and Observability: Run Shikigami as a Real Service

This MasterPlan was refreshed against `ff00b819` on 2026-11-06. Child plans own
milestones and acceptance; this document owns coordination.

## Vision & Scope

Operate Shikigami with structured logs, metrics/traces, exact health probes, supervised
loops, administrative inspection/recovery and a reproducible service deployment.
Observability, health/supervision and operator commands are delivered. Completing this
initiative still requires the full local stack, its composed smoke, NixOS module and
bounded graceful drain. Immutable executables alone are not a composed deployment.

The scope remains process-compose for local development and a NixOS module for
installation. Provider implementation, workflow retry/timeout policy, workspace
containment and signed attestations keep their existing owners. No Kubernetes target
or alternative supervisor is introduced by this refresh.

## Decomposition Strategy

Retain four independently observable streams: logging/metrics/tracing (28), health and
supervision (29), operator commands (30), service composition/deployment (31). The first
three are Complete. Plan 31 consumes their actual health/settings/lifecycle surfaces;
it does not recreate them or wait for a release already adopted.

Read [package ownership](../architecture/packages.md),
[ADR 0019](../adr/0019-a-loop-that-stops-stops-the-process.md),
[ADR 0020](../adr/0020-readiness-covers-only-what-restarting-can-fix.md),
[ADR 0021](../adr/0021-operator-verbs-wrap-the-owning-library.md),
[ADR 0032](../adr/0032-the-migration-cli-keeps-a-dedicated-configuration-boundary.md)
and [ADR 0039](../adr/0039-deployment-roles-share-a-frozen-cabal-source-closure.md).
Their implemented boundaries remain authoritative; this refresh changes no architecture.

## Exec-Plan Registry

| # | Title | Path | Hard Deps | Soft Deps | Status |
|---|-------|------|-----------|-----------|--------|
| EP-1 | Structured logging, metrics and trace propagation | docs/plans/28-structured-logging-metrics-and-trace-propagation.md | None | None | Complete (2026-08-23) |
| EP-2 | Health, liveness and worker supervision | docs/plans/29-health-liveness-and-worker-loop-supervision.md | None | EP-1 | Complete (2026-08-23) |
| EP-3 | Operator CLI | docs/plans/30-operator-cli-inspect-runs-agents-dead-letters-and-cancel.md | None | EP-1 | Complete (2026-08-20; accepted automated-fixture scope recorded in child) |
| EP-4 | Deployable stack, packaging and configuration | docs/plans/31-deployable-service-stack-process-compose-packaging-and-configuration.md | None | EP-1, EP-2, EP-3 | In Progress |

Statuses are Not Started, In Progress, Complete and Cancelled. Historical external
prerequisites 20/22/32/36–38/47 and the worker probe release are accepted. They are
removed from active dependency cells, not waived or reclassified as optional.

## Dependency Graph

EP-4 is independently eligible. Its package/configuration/migration, telemetry, health
and sink-auth prerequisites have landed. It must consume them and pass its own composed
acceptance. The health contract is available now, so readiness uses actual HTTP probes
rather than an instruction to upgrade from temporary process-started checks later.

Plan 124 supplies the current local Shikumi adapter and five native immutable role-build
results. Plans 79/80 own their separately bounded readiness/provider qualification;
plan 31 retains installed startup and full stack/drain acceptance. Missing production
trust/configuration blocks that selected trial, not key-free local composition.

## Integration Points

**Telemetry and lifecycle.** Plan 28 owns `Shikigami.Log`, metric/span vocabulary,
request-log bounds and bracketed exporter lifecycle. Plan 31 consumes these for startup,
request correlation and shutdown; it must prove flush under accepted work. Preserve
health-path request-log exclusions and the existing outbound HTTP tracing/auth boundary.

**Health and package boundaries.** Plan 29 owns server health through the public API
and worker probes through the released external substrate. Workers never import sibling
api/server packages. Exact unauthenticated `/health/live` and `/health/ready` remain the
probe contract. Readiness checks PostgreSQL; do not introduce Kafka/downstream cascading
readiness merely because the composed graph includes them.

**Configuration/migrations.** `App/Config.hs` and the existing configuration guide own
Settei keys, precedence, compatibility bindings and redaction. Application roles use those
sources; `shikigami-migrate` separately consumes `DATABASE_URL` and the embedded pg-migrate
parser/plan. A single explicit migration process precedes database services. Startup
verification remains read-only. OTel's standard environment is SDK-owned.

**Packaging/composition.** Plan 31 extends the existing `flake.module.nix` and
`nix/qualification-package.nix` roles/frozen closure, adds process-compose/dev recipes
and `nix/nixos-module.nix`, and proves the complete startup graph. Do not copy the example
module over existing exports, invent a second dependency solve or confuse native builds
with Linux runtime/containment proof. Use repository Apple-container/builder guidance.

**Inspection/recovery.** Plan 30 wraps owning query/command APIs for runs, agents,
DLQ and outbox. Preserve confirmation/audit behavior, schema-qualified queries and the
real dead-letter queue. Receipt uncertainty and workspace settlement remain with their
owners; service restart cannot claim an unknown remote effect never happened.

## Progress

Three of four children are Complete. Plan 31 has accepted immutable packaging and installed
asset evidence, including plan 124's 2026-11-05 native regression on the Handan-free closure.
The 2026-11-06 source still has only PostgreSQL/schema/sanity entries in process-compose,
no dev/build/down recipes and no NixOS module. The configuration guide already exists.
Remaining acceptance is local composition/restart, complete delivery smoke/installed startup,
module evaluation and bounded drain/flush/recovery. No runtime qualification was rerun
by this plan refresh.

## Surprises & Discoveries

The old plan-31 commands incorrectly passed application `--config` to the migration
executable and cited removed `shikigami-cli`/core-worker paths. The refreshed child uses
current seven-package roles and the accepted migration exception. Old missing-health,
354-package closure and unpublished-source descriptions refer to earlier checkpoints.
The current cohort/export and role-build records are in the dependency guide and plan 124.

## Decision Log

2026-11-06 refresh: discharge completed external prerequisites in active scheduling,
retain existing four-plan ownership, and replace speculative stack commands with current
roles/migration/health owners. This is a source/status refresh, not a target or scope change.

Historical rationale follows; absent-health/old package observations describe their dates.

- Decision: Require plan 47 for all operations children and block only plan 29's Shibuya
  worker-probe slice on Shibuya IR-1.
  Rationale: OTel/Shibuya APIs must be ported coherently, but the typed health server and local
  loop-supervision work remain independently deliverable.
  Date: 2026-07-30


- Decision: Decompose Operations & Observability into four plans — observability (28), health &
  supervision (29), operator CLI (30), deployable stack (31) — with EP-1 as the soft-first
  vocabulary owner and no original intra-MasterPlan hard dependencies. The 2026-07-22
  portfolio revision adds plan 20 as EP-3's cross-MasterPlan hard dependency.
  Rationale: the four concerns touch largely disjoint code and each yields a distinct operator-
  visible capability, so they are independently verifiable and can run in parallel. Folding
  health into observability, or the CLI into the stack, was rejected as producing lopsided plans
  with mixed risk profiles (see Decomposition Strategy).
  Date: 2026-07-22

- Decision: Keep intra-MasterPlan dependencies soft, but make plan 20 a cross-MasterPlan
  hard dependency of EP-3. EP-1 M3 also waits for plan 22's authenticated HTTP seam.
  Rationale: health and operator queries remain independent, but `agents list` now consumes
  a concrete shared report and HTTP tracing must compose with authentication rather than
  create a second helper.
  Date: 2026-07-22

- Decision: EP-1 owns the observability vocabulary as an explicit Integration Point (IP-A) that
  MasterPlans 2-5 also consume.
  Rationale: those MasterPlans' plans emit run/sink/timer logs and metrics; without a single
  naming owner the vocabulary would drift across a dozen plans. Centralizing the convention in
  EP-1's Decision Log gives one place to change it.
  Date: 2026-07-08

- Decision: Route the two cross-MasterPlan overlaps (cancellation with plan 17; consume-loop
  death with plan 18) through named integration points (IP-E, IP-F) rather than absorbing that
  work here.
  Rationale: plan 17 owns in-workflow timeout and plan 18 owns Kafka reconnect/atomic
  consumption; this MasterPlan owns only the operator-facing cancel surface and the *observability*
  of loop death. Naming the seams prevents duplicated or conflicting implementations of the same
  keiro marker and the same consume loop.
  Date: 2026-07-08
- Decision: EP-4 is the operations-closure plan and should land after plans 13, 22, and
  32 plus EP-1/EP-2 have stabilized their configuration and health surfaces.
  Rationale: a configuration reference with placeholders immediately becomes stale;
  packaging last lets `just dev` and the NixOS module prove the actual final surface.
  Date: 2026-07-22
- Decision: EP-3 owns the `agents` command group, plan 20 owns its report, and plan 23
  extends it after plan 33 defines declared identity.
  Rationale: this eliminates duplicate CLI parsers and directory traversal across three
  MasterPlans.
  Date: 2026-07-22
- Decision: The public service boundary follows the full API pattern: `NamedRoutes`,
  terminal `MultiVerb`, OpenAPI from the served proxy, RFC 7807 for non-health errors,
  and bounded request logging inside OTel. Health reports are the documented exception.
  Rationale: one typed route tree keeps server behavior, documentation, error variants,
  middleware, and contract tests from drifting.
  Date: 2026-07-22
- Decision: Health uses two package-correct implementations of one wire contract: the public
  server extends `shikigami-api`, while workers consume a released external
  `shibuya-metrics` probe application. Workers never import sibling API/server packages.
  Rationale: this is the only route that preserves both the strict six-package dependency
  graph and exact health endpoints on every deployed process without duplicating a
  handwritten local WAI server.
  Date: 2026-07-22
- Decision: EP-3 operates on plan 17's real dead-letter queue and exposes inspect,
  repair/replay, and discard with confirmation and audit coverage.
  Rationale: PGMQ archive internals are not an operational contract and cannot support
  a truthful remediation workflow.
  Date: 2026-07-22
- Decision: EP-4 deploys through process-compose and NixOS, uses plan 37's Settei
  configuration and plan 38's migration gate, and proves graceful drain/shutdown.
  Kubernetes overlays are out of scope while no Kubernetes target exists.
  Rationale: deployment artifacts should match the actual target and lifecycle instead
  of creating untested parallel configuration surfaces.
  Date: 2026-07-22

## Outcomes & Retrospective

Observability, health/supervision and operator administration are delivered. Packaging has
current accepted native evidence, but plan 31 still owns actual composed deployment and
drain. Complete this MasterPlan only after its four remaining acceptance milestones pass.

## Revision Notes

2026-11-06: Rebase coordination on delivered health/configuration/packaging, remove
satisfied start gates, and retain exact composed, installed, NixOS and shutdown acceptance.
