---
id: 31
slug: deployable-service-stack-process-compose-packaging-and-configuration
title: "Deployable service stack: process-compose, packaging, and configuration"
kind: exec-plan
created_at: 2026-07-08T20:14:28Z
intention: "intention_01kx1tyx3yehmsq9eyywdcf5c7"
master_plan: "docs/masterplans/6-operations-and-observability-run-shikigami-as-a-real-service.md"
provenance:
  revisions:
    - model: "gpt-6.1-sol"
      harness: "codex-cli"
      at: 2026-10-06T04:07:36Z
      mode: "implement"
      note: "Build the seven-package immutable offline qualification graph and export isolated deployment roles under plan 79"
    - model: "gpt-6.1-sol"
      harness: "codex-cli"
      at: 2026-11-06T21:09:33Z
      mode: "update"
      note: "Refresh deployment plan against delivered roles, migration/configuration/health owners and remaining composed/drain acceptance."
---

# Deployable service stack: process-compose, packaging, and configuration

This living plan was refreshed against source checkpoint `ff00b819` on 2026-11-06.
The refresh changes documentation only; retained qualification applies to its named candidate.

## Purpose / Big Picture

An operator should boot the complete development service with `just dev`, observe a
fixture pass through Kafka, durable admission, the worker and a sink, and install the
same roles using `nixosModules.shikigami`. Startup must apply and verify the embedded
migration plan once, check configuration before resource acquisition, expose the
existing health endpoints and stop within a configured drain bound.

Immutable packages and a configuration guide already exist. The missing delivery is
service composition, its end-to-end smoke, the NixOS module and shutdown qualification.
This plan does not redo the model runtime, workspace supervisor or objective providers.

## Progress

- [x] (2026-10-06; extended 2026-11-05) Immutable packaging slice: named roles and installed assets build from a frozen Cabal closure. Plan 124 records all five native role builds after Handan removal, with 382 packages and six immutable repositories.
- [ ] M1: a complete, health-ordered process-compose stack with an initialized Kafka broker and `just dev|build|dev-down` works on a fresh disposable development database and on restart.
- [ ] M2: the composed stack completes the fixture through stream intake, durable run and sink receipt; installed startup is proven with explicit test trust/configuration.
- [ ] M3: `nixosModules.shikigami` and its representative NixOS evaluation check render the real role executables, configuration sources and migration ordering.
- [ ] M4: the existing configuration reference matches deployment sources, and every long-running role proves bounded SIGTERM intake stop, settlement/drain, telemetry flush and resource closure.

Plans 36–38, 47, 28–30, 22 and 32 are accepted foundations. No implementation
milestone above is closed by this refresh. The old plan-79 host acceptance and
configuration-page tasks are integrated into M2/M4 rather than counted as new features.

## Surprises & Discoveries

On 2026-11-06, `process-compose.yaml` still contains only `sanity_check`,
`create_schema` and `postgres`. The Justfile has no dev/build/dev-down recipes.
`nix/nixos-module.nix` is absent. In contrast, `flake.module.nix` already exports
`shikigami-runtime`, CLI/server/worker/migrate/scheduler/consumer roles and workspace
qualification outputs. Do not overwrite that module from its example.

`shikigami-migrate` owns `DATABASE_URL` and pg-migrate's parser; it does not accept
application Settei `--config` files. The old `config/migrations-dev.yaml` command
was invalid. Its `check` is offline; `up`, `verify` and `verify-schema` use the
explicit database connection. Runtime startup verification is read-only.

The earlier 354-package closure and unpublished Kikan-En source description are
historical. Current immutable sources and build facts are in the cohort guide and
plan 124. Their native packaging acceptance is not a full service-stack or Linux
runtime qualification result.

## Decision Log

2026-11-06 refresh: retain the existing deployment target, broker intent, frozen
closure and four milestones. Consume completed health/configuration/packaging
owners, remove obsolete CLI paths and migration flags, and keep installed host
startup distinct from local deterministic composition.

The following decisions describe their dated checkpoints. References to missing
health endpoints, absent packaging or old host setup are superseded by the current
Context and Plan of Work; deployment and ownership choices remain in force.

- Decision: Export and build the exact qualified Cabal runtime closure offline,
  then wrap each deployed role around the resulting executable and installed assets.
  Rationale: preserve the selected cohort without a mutable sibling dependency or
  an independent Nixpkgs solve. Correct the root default in the managed base module
  because merely forcing an override still eagerly evaluates that invalid package.
  The custom deployment implementation lives in `flake.module.nix` and
  `nix/qualification-package.nix`. Cold builds are deliberately monolithic.
  Durable context: [ADR 0039](../adr/0039-deployment-roles-share-a-frozen-cabal-source-closure.md).
  Date: 2026-10-06

- Decision: Use Apache Kafka in KRaft mode (nixpkgs attribute `apacheKafka`) as the local
  broker rather than a Redpanda server binary.
  Rationale: `docs/initial-spec.md` lines 545-548 and 728 call for "a Redpanda/Kafka broker
  (run via the project's `process-compose.yaml`)" — either implementation satisfies the intent,
  since `hw-kafka-client`/`kafka-effectful` speak the Kafka wire protocol to both. nixpkgs does
  not package the Redpanda server (only the `rpk` client), and the development machines are
  darwin, where Redpanda has no native build; running it would require a container daemon,
  which the dev shell deliberately avoids. Kafka in KRaft mode is a single JVM process with no
  ZooKeeper, packaged in nixpkgs for both darwin and linux. M1 includes a prototyping step that
  verifies the attribute before committing to it; if `apacheKafka` proves unusable on the host,
  the recorded fallback is a documented Redpanda container profile.
  Date: 2026-07-08

- Decision: Extend the flake through a committed `flake.module.nix` (copied from
  `flake.module.nix.example`) instead of editing `nix/haskell.nix`.
  Rationale: `flake.nix` lines 39-41 document `flake.module.nix` as the extension point that
  seihou (the `github:shinzui/haskell-nix-dev` scaffolding this flake wraps) "never generates,
  touches, or migrates"; `nix/haskell.nix` is seihou-managed and already declares the
  `haskellProject.extraDevPackages` option (nix/haskell.nix:8) precisely so projects can add
  dev-shell packages without touching the managed module. The same file can carry the
  top-level `flake.nixosModules.shikigami` output, since flake-parts modules may contribute
  `flake.*` attributes.
  Date: 2026-07-08

- Decision: Package for deployment as a NixOS module, not a container image.
  Rationale: the surrounding platform is nix-first — the flake wraps
  `github:shinzui/haskell-nix-dev`, publishes to the `shinzui.cachix.org` cache
  (flake.nix:21-24), and sibling kikan services deploy the same way. A NixOS module composes
  with a host's existing Postgres/Kafka services and needs no registry or container runtime.
  A container image remains cheap to add later (`pkgs.dockerTools.buildImage` over the same
  `packages.shikigami-runtime`), and the configuration reference is written so either
  packaging consumes identical env vars and flags. Container-only packaging was rejected
  because nothing in the target environment runs containers today.
  Date: 2026-07-08
- Decision: NixOS is the deployment target and process-compose is the local target;
  Kubernetes overlays are not applicable unless a Kubernetes deployment target is
  explicitly added later.
  Rationale: speculative manifests would create an untested parallel configuration and
  lifecycle surface.
  Date: 2026-07-22
- Decision: Startup runs plan 38's pg-migrate `check`/`up`/`verify` gate once before services;
  runtime settings come from plan 37's Settei composition, with standard OTel variables
  left to the SDK.
  Rationale: schema and process configuration each require one authoritative owner.
  Date: 2026-07-22

- Decision: Use exec-based readiness probes and `process_started` conditions for the shikigami
  processes in M1, and switch to HTTP probes against `/health/ready` once
  `docs/plans/29-health-liveness-and-worker-loop-supervision.md` lands.
  Rationale: the runtime has no HTTP health server yet (plan 29 adds one); blocking this plan
  on plan 29 would serialize two otherwise-independent work streams. `process-compose` supports
  both probe kinds, so M1 ships without HTTP probes and a listed follow-up step upgrades them.
  This is the soft dependency the MasterPlan records between EP-4 (this plan) and EP-2 (29).
  Date: 2026-07-08

- Decision: Land the configuration reference after plans 13, 22, 28, 29, and 32 and
  document their actual surfaces; do not ship reserved placeholders.
  Rationale: those plans author provider, credential/HTTP, observability, health, and
  kanmon settings. Packaging is the portfolio closure step, so waiting avoids publishing
  an immediately stale reference and lets the composed smoke test exercise real settings.
  Date: 2026-07-22

## Outcomes & Retrospective

In progress. Packaging has accepted historical and current-native evidence;
process composition, NixOS installation and graceful drain remain unqualified.
No build, service startup or live integration was executed by this refresh.

## Context and Orientation

There are seven application packages. `shikigami-server` owns the server and
administrative `shikigami` executable, `shikigami-workers` owns worker, scheduler
and both consumers, and `shikigami-migrations` owns `shikigami-migrate`.
`shikigami-core` supplies domain and reusable behavior, `shikigami-api` the public
route contract, `shikigami-client` the typed client and `shikigami-agent` one-offs.
See [package ownership](../architecture/packages.md).

Read `shikigami-server/src/Shikigami/Server/Command.hs` and its `StubKawa.hs` and
`PublishFixture.hs` modules; worker composition is in
`shikigami-workers/src/Shikigami/Workers/Command/` and `Workers/Config.hs`.
Health and supervision are implemented in `shikigami-workers/src/Shikigami/Health/Worker.hs`
and the server health vertical. Use exact `/health/live` and `/health/ready`
routes with distinct configured ports. Workers remain independent of sibling
API/server packages.

Configuration is declared in `shikigami-core/src/Shikigami/App/Config.hs` and
resolved through Settei. [The existing reference](../operations/configuration.md)
documents repeated `--config PATH`, explicit environment bindings, flags and
`--set`. Preserve the migration exception in
[ADR 0032](../adr/0032-the-migration-cli-keeps-a-dedicated-configuration-boundary.md).
Do not invent environment names or put secret contents into Nix expressions.

`flake.module.nix` and `nix/qualification-package.nix` already assemble the frozen
runtime. `nix/qualification/cohort.json` is the selected source closure. Follow
[ADR 0039](../adr/0039-deployment-roles-share-a-frozen-cabal-source-closure.md),
[plan 124](124-remove-handan-by-owning-the-shikumi-execution-adapter-in-shikigami.md)
and [the cohort](../dependency-cohort.md). The selected index is
`2026-11-03T12:48:57Z`: Keiro 0.22, Baikai 0.10, Shikumi 0.5.1 and Kioku 0.12.0.2.
No dependency upgrade is required here.

## Plan of Work

### M1 — Compose the local runtime

Extend the existing unmanaged flake module with a verified Kafka dev dependency;
retain its role outputs and closure. The selected intent is a single-node KRaft
broker on loopback 9092, with controller on a separate loopback port and data in
an isolated development directory. Verify the pinned nixpkgs attribute and shipped
Kafka CLI before choosing exact flags. Use Mori to find dependency docs first.
Accept a bounded broker prototype before adding the full startup graph. If native
Kafka cannot meet the target, record the tested failure and use the documented
container fallback without changing the Kafka protocol contract.

Extend process-compose with broker readiness, migration completion and server,
stub-kawa, worker, scheduler and both consumer roles. Database roles wait for
healthy PostgreSQL and a successful single migration process. Consumers also
wait for healthy Kafka. Other roles do not require Kafka merely to start.
The migration process runs the embedded `check`, `up`, `verify` and `verify-schema`
commands with `DATABASE_URL`; application roles use checked Settei sources.
Create the referenced non-secret dev configurations and run each role's
`--check-config` before starting it. Use existing HTTP readiness for server and
worker roles; the test sink needs a separately valid readiness/start condition.

The composed fixture must supply explicit disposable identity, sink grants and
any required authority through existing supported owners. Choose a key-free
fixture provider. Do not require production credentials to prove local wiring
or claim fixture authority qualifies a production deployment. Add dev/build/down
recipes and build before probes begin, avoiding compilation-shaped startup races.
Prove clean startup, teardown and a second startup without reformatting existing
broker data or racing migrations.

### M2 — Prove composed delivery and installed startup

Select an actual fixture and matching manifest by reading
`shikigami-server/src/Shikigami/Server/Command/PublishFixture.hs`, agent declarations
and the existing local-qualification driver. Do not reuse an obsolete positional
publish-fixture invocation. With no manually started role, observe one accepted
stream event, one durable run and the prepared/delivered sink receipt plus the
stub's accepted request. Assert identities and durable outcomes as well as logs;
structured log names are not the old hand-written MATCH transcript.

For installed startup, select the exact current immutable role output and its
installed assets outside the checkout. Supply explicit private test configuration
and report missing trust/authority as blocked. Reuse plan 79's actual readiness
boundary; do not broaden its accepted profile by quoting a native build. Keep
fixture proof and production-host authorization evidence separate.

### M3 — Export a NixOS module

Add `nix/nixos-module.nix`, export `nixosModules.shikigami` from the existing flake
module and default its package to `shikigami-runtime`, which contains every role.
Expose `services.shikigami` with enable/package, ordered config-source paths,
secret-directory paths and an optional environment file for explicit compatibility
bindings and SDK-owned OTel settings. Per-role enablement/configuration paths
cover server, worker, scheduler, consumeStream and consumeEvents. Avoid mirroring
all Settei application keys as a second Nix configuration authority.

Add one optional explicit migration oneshot and make enabled database roles
require its success when selected. Runtime ExecStart uses the actual installed
role, not administrative subcommands. Render restart policy, bounded stop timeout
and SIGTERM delivery. Check service-user access to assets/private configuration
and required runtime resources; select identity settings appropriate to those
resources rather than assuming DynamicUser can access every workspace service.
Keep credentials out of derivation contents.

Use the pinned nixpkgs NixOS evaluation mechanism with a representative Linux
configuration to assert enabled units, exact commands, source ordering and
migration dependencies. Mac development does not require booting a NixOS VM for
this evaluation milestone. A module evaluation does not prove runtime drain or
Linux containment. Reuse Apple containers for required Linux runtime checks,
falling back to the configured builder for compilation as repository guidance states.

### M4 — Close configuration and shutdown acceptance

Update the existing configuration guide and deployment examples from actual
`--describe-config`/`--check-config` outputs, retaining the migration and typed-client
exceptions. Document health ports, model/HTTP options, sink credentials, identity
and authority, and explicitly separate SDK-owned OTel configuration. Remove
reserved placeholders and invalid flags. Preserve one settings owner.

Exercise SIGTERM during accepted work in each affected role: stop intake before
releasing ownership; drain or durably retain accepted work within the configured
bound; preserve uncertain remote outcomes; flush OTel and close HTTP, Kafka and
database resources. Restart and verify recoverable work converges. A fast idle
exit alone cannot close this milestone, and whole-cgroup process settlement remains
the workspace supervisor's separately qualified responsibility.

## Concrete Steps

Run from the repository root. Before implementation capture a baseline and inspect
current commands safely:

```bash
plan31_base=$(git rev-parse HEAD)
nix develop --no-write-lock-file -c cabal run shikigami-migrate -- --help
nix develop --no-write-lock-file -c cabal run shikigami-migrate -- check
nix develop --no-write-lock-file -c cabal run shikigami-worker -- --describe-config
nix develop --no-write-lock-file -c cabal run shikigami -- publish-fixture --help
```

Use a task-owned disposable database for migration/runtime acceptance, never an
existing developer or production database. After implementing the new recipes,
run `just dev`, inspect `process-compose process list`, execute the fixture using
the parser's actual arguments, stop with `just dev-down`, and repeat startup.
The expected evidence is durable event/run/receipt identity and healthy roles,
not a copied speculative transcript.

```bash
nix flake check --no-write-lock-file
nix develop --no-write-lock-file -c cabal build all
nix develop --no-write-lock-file -c cabal test all -j1 --test-options=--num-threads=1 --test-show-details=direct
git diff --check
```

If Haskell lifecycle changes touch Agent/Flow bodies, follow
[workflow versioning](../workflow-versioning.md) and run the ordinary gate against
`plan31_base`. Check module evaluation and composed behavior at the final candidate;
record actual package output, platform and source instead of searching the Nix store.

## Validation and Acceptance

M1 accepts healthy ordered startup and repeat startup; M2 accepts the complete
fixture and installed startup with selected private test configuration; M3 accepts
the exported module and representative evaluation; M4 accepts truthful configuration
and bounded drain/recovery under accepted work. Full applicable package checks must
pass. Published role-build evidence alone satisfies none of these missing gates.

## Idempotence and Recovery

Preserve broker identity/data across restart and let pg-migrate own ledger handling.
Never delete broker/database data or use a Git reset as a routine retry. Use fresh
task-owned directories for qualification. Restart from retained run/outbox receipts;
do not republish accepted effects under new identities to hide uncertainty.
Retain deployed package/secret-source references for rollback decisions; configuration
rollback cannot decode an incompatible journal branch automatically.

## Interfaces and Dependencies

This child owns process-compose, dev recipes, the NixOS module and its evaluation,
deployment-source documentation and process-level drain qualification. Existing
health, settings, migration, telemetry, sink-delivery and workspace owners supply
behavior. Plans 36–38/47 and 28–30/22/32 are complete; plan 124 supplies the current
local adapter and native packaging baseline. Optional production trust is a runtime
qualification prerequisite, not a reason to block key-free local composition.

## Revision Notes

2026-11-06: Replaced removed CLI/core-worker paths, invalid migration config flags,
absent-health assumptions and destructive recovery instructions with the seven-package
runtime, existing frozen roles, current health/configuration owners and four explicit
remaining acceptance milestones. Preserved prior decisions and historical build evidence.
