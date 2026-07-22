---
id: 31
slug: deployable-service-stack-process-compose-packaging-and-configuration
title: "Deployable service stack: process-compose, packaging, and configuration"
kind: exec-plan
created_at: 2026-07-08T20:14:28Z
intention: "intention_01kx1tyx3yehmsq9eyywdcf5c7"
master_plan: "docs/masterplans/6-operations-and-observability-run-shikigami-as-a-real-service.md"
---

# Deployable service stack: process-compose, packaging, and configuration

This ExecPlan is a living document. The sections Progress, Surprises & Discoveries,
Decision Log, and Outcomes & Retrospective must be kept up to date as work proceeds.


## Purpose / Big Picture

Shikigami today is a dev-shell-only program: `process-compose.yaml` at the repo root starts
Postgres and nothing else, the `Justfile` knows only how to create and migrate the database,
and the four long-running commands that together form the runtime — `shikigami worker`,
`shikigami scheduler`, `shikigami consume-stream`, and `shikigami consume-events` — must each
be started by hand in its own terminal, in the right order, with the right flags. There is no
Kafka broker in the stack even though both consumers need one, no way to install shikigami as
a service on a real machine, and no single document that says which environment variables and
flags exist.

After this plan, one command — `just dev` — boots the entire local runtime: Postgres, a Kafka
broker, the codd migrations, the `stub-kawa` sink target, the worker, the scheduler, and both
stream consumers, with health-check-based startup ordering so nothing races its dependencies.
A second deliverable makes the same runtime installable outside the dev shell: a flake output
`nixosModules.shikigami` defines systemd services for the worker, scheduler, and consumers,
configured entirely through module options and an environment file. The third deliverable is
`docs/operations/configuration.md`, a single configuration reference that enumerates every
environment variable and CLI flag the runtime reads, so an operator never greps the source to
find a knob.

The user-visible proof: run `just dev` inside `nix develop`, wait for the process list to show
every process ready, then `cabal run shikigami -- publish-fixture fixtures/envelope.json` and
watch the fixture flow through the consumer, the queue, the worker, and out to `stub-kawa` —
with no manual terminal juggling. On the packaging side, `nix flake show` lists
`nixosModules.shikigami`, and `nix flake check` passes a check that evaluates the module and
asserts the rendered service commands.


## Progress

- [ ] M1: Kafka broker (KRaft single-node) added to the dev shell via `flake.module.nix` and to
      `process-compose.yaml`, with an exec readiness probe; broker reachable on 127.0.0.1:9092.
- [ ] M1: `stub-kawa`, `worker`, `scheduler`, `consume-stream`, and `consume-events` processes
      added to `process-compose.yaml` with `depends_on` ordering (postgres healthy and schema
      migrated before DB-touching processes; kafka ready before consumers).
- [ ] M1: `just dev`, `just build`, and `just dev-down` recipes added to the `Justfile`;
      `just dev` boots the full stack.
- [ ] M2: end-to-end smoke transcript recorded in this plan: `publish-fixture` → consumer match
      → worker run → stub-kawa ingest, all inside the composed stack.
- [ ] M3: `nix/nixos-module.nix` written; `flake.module.nix` exports it as
      `nixosModules.shikigami`; `nix flake show` lists it.
- [ ] M3: flake check `nixos-module-eval` evaluates the module with a sample configuration and
      asserts the rendered `ExecStart` lines; `nix flake check` passes.
- [ ] M4: `docs/operations/configuration.md` written, covering every env var and flag verified
      in the code, plus reserved sections naming the plans that will add more (13, 22, 28, 29).


## Surprises & Discoveries

(None yet.)


## Decision Log

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
  `packages.default`, nix/haskell.nix:62), and the configuration reference is written so either
  packaging consumes identical env vars and flags. Container-only packaging was rejected
  because nothing in the target environment runs containers today.
  Date: 2026-07-08

- Decision: Use exec-based readiness probes and `process_started` conditions for the shikigami
  processes in M1, and switch to HTTP probes against `/readyz` once
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

(To be filled during and after implementation.)


## Context and Orientation

Shikigami is a declared-agent runtime: agents are short Dhall manifests in `agents/` (for
example `agents/heartbeat.dhall`), and one CLI executable, `shikigami` (built from
`shikigami-cli`, dispatcher in `shikigami-cli/src/Shikigami/Cli.hs`), provides twelve
subcommands. Four of them are long-running and together form "the runtime":

- `shikigami worker` (`shikigami-cli/src/Shikigami/Cli/Commands/Worker.hs`) drains the
  `shikigami_run_jobs` Postgres queue and runs agents; it also hosts the keiro workflow-resume,
  outbox-publisher, and timer loops (`shikigami-core/src/Shikigami/Worker.hs:70`).
- `shikigami scheduler` (`shikigami-cli/src/Shikigami/Cli/Commands/Scheduler.hs`) arms cron
  triggers and fires keiro timers.
- `shikigami consume-stream` and `shikigami consume-events`
  (`shikigami-cli/src/Shikigami/Cli/Commands/ConsumeStream.hs`) consume Kafka topics
  (`activity.v1` and `danwa.message-addressed.v1` by default) and enqueue run jobs.

The substrate is Postgres (the pgmq queue, keiro workflow/outbox/timer tables, kioku
session/memory tables — all installed by the codd migrations in `shikigami-migrations`) plus a
Kafka-protocol broker for the two consumers. A fifth process, `shikigami stub-kawa --port 8088`
(`shikigami-core/src/Shikigami/Sink/KawaStub.hs`), is a warp HTTP server imitating the real
kawa ingest doorway; the worker's default `--kawa-url http://localhost:8088` points at it.

*process-compose* is a docker-compose-style supervisor for plain processes, driven by
`process-compose.yaml`; the binary is already in the dev shell (`nix/haskell.nix:25-35` lists
`process-compose` among `baseDevPackages`). The current `process-compose.yaml` (repo root, 30
lines) defines exactly three processes: `postgres` (socket-only: started with
`-c listen_addresses=''` and a Unix-socket directory `$PGHOST`, with an exec readiness probe
`pg_ctl status -D $PGDATA`), `create_schema` (runs `just create-database` once postgres is
`process_healthy`), and a `sanity_check` echo. There is no broker and none of the shikigami
processes, even though `docs/initial-spec.md:545-548` and `:728` intended "postgres + a
Redpanda/Kafka broker".

The `Justfile` has three recipes: `create-database` (idempotent `createdb` then `just
migrate`), `migrate` (touches `shikigami-migrations/shikigami-migrations.cabal` to force
re-embedding, then runs `cabal run shikigami-migrate` with `CODD_CONNECTION`,
`CODD_MIGRATION_DIRS`, `CODD_EXPECTED_SCHEMA_DIR`, and `CODD_SCHEMAS=kiroku` set), and
`new-migration`. *codd* is the SQL-migration tool; shikigami embeds its migrations at compile
time and applies them through the `shikigami-migrate` executable
(`shikigami-migrations/app/Main.hs`).

The runtime's entire configuration surface today, verified in code, is:

- `PG_CONNECTION_STRING` — read with `getEnv` (hard failure when unset) by every DB-touching
  command: `Commands/Worker.hs:28`, `Commands/Scheduler.hs:36`, `Commands/ConsumeStream.hs:40`
  and `:70`, `Commands/AgentRun.hs:36`, `Commands/EnqueueRun.hs:27`. The dev shell exports it
  (`nix/haskell.nix:44`).
- `OTEL_EXPORTER_OTLP_ENDPOINT` — read with `lookupEnv` in
  `shikigami-core/src/Shikigami/Telemetry.hs:20`; when set, the standard `OTEL_*` exporter
  variables are also honored via `loadExporterEnvironmentVariables` (Telemetry.hs:38).
- CLI flags, all with defaults, defined in `shikigami-cli/src/Shikigami/Cli.hs`: the worker's
  `--agents agents`, `--kawa-url http://localhost:8088`, `--kizashi-url http://localhost:8089`,
  `--danwa-url http://localhost:8080`, `--danwa-agent part_shikigami` (Cli.hs:139-150); the
  consumers' `--agents`, `--broker 127.0.0.1:9092`, `--topic`, `--group` (Cli.hs:98-130); the
  scheduler's `--agents` (Cli.hs:131-138); `stub-kawa`'s required `--port` (Cli.hs:69-78).

Everything Kafka-related is a flag, not an env var — which is why the composed stack can pin
the broker to `127.0.0.1:9092` and match the flag defaults exactly.

On the nix side: `flake.nix` is a flake-parts flake wrapping `github:shinzui/haskell-nix-dev`
(seihou); `nix/haskell.nix` exposes `packages.default` via `callCabal2nix` at line 62 and the
dev shells, and declares the extension option `haskellProject.extraDevPackages` (line 8);
`flake.module.nix.example` is the template for the unmanaged, committed extension file
`flake.module.nix`, which `flake.nix:41` imports when present. Today there is no
`flake.module.nix`, no NixOS module, and no container packaging of any kind.

Two sibling plans matter here. `docs/plans/29-health-liveness-and-worker-loop-supervision.md`
(EP-2 of this MasterPlan) adds `/healthz` and `/readyz` HTTP endpoints to the long-running
commands — this plan's readiness probes upgrade to them but do not wait for them.
`docs/plans/28-structured-logging-metrics-and-trace-propagation.md` (EP-1) adds observability
configuration (metrics exporter, log level); the configuration reference in M4 must list
whatever EP-1 introduces, so finish or reconcile M4 after EP-1's surface is known.


## Plan of Work

### Milestone 1 — the full local stack under process-compose

Scope: a broker in the dev shell, all runtime processes in `process-compose.yaml`, ordered
startup, and a `just dev` entry point. At the end, `just dev` (inside `nix develop`) brings up
eight processes with correct ordering.

First, prototype the broker choice (a prototyping step in the PLANS.md sense: cheap,
discardable, de-risks the milestone). Inside the dev shell run
`nix eval --raw nixpkgs#apacheKafka.name` and then start a single-node KRaft broker by hand
(commands in Concrete Steps). If the attribute is missing or broken on the host platform,
record the failure in Surprises & Discoveries and fall back to documenting a Redpanda container
profile; the rest of the milestone is broker-agnostic because every consumer flag defaults to
`--broker 127.0.0.1:9092`.

Second, create `flake.module.nix` at the repo root by copying `flake.module.nix.example` and
setting `haskellProject.extraDevPackages = [ pkgs.apacheKafka ];` in its `perSystem` section.
This puts `kafka-server-start.sh`, `kafka-storage.sh`, and `kafka-topics.sh` on the dev-shell
PATH without touching the seihou-managed `nix/haskell.nix`.

Third, commit a minimal single-node KRaft config as `nix/kafka-server.properties`
(`listeners=PLAINTEXT://127.0.0.1:9092,CONTROLLER://127.0.0.1:9093`, log dirs under
`.dev/kafka/data`) and add a `kafka` process to `process-compose.yaml`. KRaft needs a one-time
storage format; guard it with a marker file under `.dev/kafka` so re-runs are idempotent. Give
it an exec readiness probe that lists topics against `127.0.0.1:9092`. Keep the existing
`postgres` and `create_schema` processes unchanged.

Fourth, add the five shikigami processes, each running through `cabal run` so the stack always
executes the current working tree (a deliberate dev-stack choice; the NixOS module in M3 runs
the installed binary instead):

- `stub_kawa`: `cabal run shikigami -- stub-kawa --port 8088`; no dependencies. Its only route
  is `POST /v1/sources/{source}/events` (KawaStub.hs:49), so until plan 29 gives processes a
  GET health endpoint, its condition for dependents is `process_started`.
- `worker`: `cabal run shikigami -- worker --agents agents`; depends on `create_schema`
  completed and `stub_kawa` started.
- `scheduler`: `cabal run shikigami -- scheduler --agents agents`; depends on `create_schema`
  completed.
- `consume_stream` / `consume_events`: the two consumer commands with default flags; each
  depends on `create_schema` completed and `kafka` healthy.

Note `create_schema` uses condition `process_completed_successfully`, not `process_healthy`,
because it is a run-once process. The worker and scheduler do not need Kafka at all — they must
not wait on it.

Fifth, add the `Justfile` recipes: `dev` (depends on `build`, then execs `process-compose`),
`build` (`cabal build all`), and `dev-down` (`process-compose down`). Making `dev` depend on
`build` prevents the first boot from timing out probes while cabal compiles.

Acceptance: `just dev` shows all processes up; `process-compose process list` in a second
terminal reports `postgres` and `kafka` Ready, `create_schema` Completed, and the five
shikigami processes Running.

### Milestone 2 — end-to-end smoke through the composed stack

Scope: prove the stack is wired, not merely started. With `just dev` up, publish the checked-in
fixture onto `activity.v1` and observe the full path: `consume_stream` logs a MATCH and an
enqueue, `worker` logs the agent run completing, and `stub_kawa` logs the ingested digest
envelope. This is the living-loop shape proven in
`docs/plans/6-end-to-end-living-loop-proof-and-detector-conformance.md`, but here the subject
under test is composition and ordering, not agent semantics. Record the transcript in this
plan's Concrete Steps when done. Acceptance is the three log lines named in Validation
appearing without any manual process start.

### Milestone 3 — NixOS module

Scope: a new file `nix/nixos-module.nix` plus its export and an evaluation check. The module
defines an option tree `services.shikigami` with: `enable`, `package` (defaults to this
flake's `packages.default`), `agentsDir` (path to a directory of `.dhall` manifests),
`environmentFile` (an `EnvironmentFile` handed to systemd, carrying `PG_CONNECTION_STRING` and
optionally `OTEL_EXPORTER_OTLP_ENDPOINT` — secrets stay out of the nix store), and per-service
submodules `worker` (`enable`, `kawaUrl`, `kizashiUrl`, `danwaUrl`, `danwaAgent`), `scheduler`
(`enable`), `consumeStream` (`enable`, `broker`, `topic`, `group`), `consumeEvents` (same),
and `migrate` (`enable`, a oneshot `shikigami-migrate` service for single-host setups). Each
enabled submodule renders one systemd service (`shikigami-worker`, `shikigami-scheduler`,
`shikigami-consume-stream`, `shikigami-consume-events`) whose `ExecStart` is the installed
binary with exactly the flags documented in the configuration reference, with
`Restart=always`, `RestartSec=2`, and `DynamicUser=true`. Migrations stay an explicit operator
step by default because codd migrations against a shared database must not race multiple
service starts.

`flake.module.nix` grows a top-level section:

```nix
{
  flake.nixosModules.shikigami = import ./nix/nixos-module.nix;
}
```

Because the development hosts are darwin, do not gate acceptance on booting a NixOS VM.
Instead add a flake check (`perSystem.checks.nixos-module-eval` in `flake.module.nix`) that
runs `lib.evalModules` over the module with a representative configuration and asserts the
rendered `ExecStart` strings contain the expected subcommands and flags. This proves the option
plumbing without a linux builder; a real `nixos-rebuild` on a linux host is optional extra
validation.

Acceptance: `nix flake show` lists `nixosModules.shikigami`; `nix flake check` passes,
including the new check.

### Milestone 4 — the configuration reference

Scope: write `docs/operations/configuration.md`, structured by process. For each of the four
runtime commands plus `stub-kawa` and `shikigami-migrate`: the env vars read (with exact
failure behavior — `PG_CONNECTION_STRING` aborts the process when unset), every flag with its
default (from `shikigami-cli/src/Shikigami/Cli.hs`, cited in Context), and the
process-compose/systemd incarnation of each. Include the `CODD_*` variables the migrate path
needs (`CODD_CONNECTION`, `CODD_MIGRATION_DIRS`, `CODD_EXPECTED_SCHEMA_DIR`, `CODD_SCHEMAS`,
as set in `Justfile` lines 33-37). Include the actual model-provider configuration from plan
13, sink and kanmon credentials from plans 22/32, observability settings from plan 28, and
health ports from plan 29. Cite each owning implementation; do not retain a reserved section.

Acceptance: the document exists and every variable/flag in it traces to a cited file:line in
this repo (spot-check at least `PG_CONNECTION_STRING` and the worker flags).


## Concrete Steps

All commands run from the repo root, inside `nix develop`.

Prototype the broker (M1, discard afterwards):

```bash
nix eval --raw nixpkgs#apacheKafka.name
mkdir -p .dev/kafka
cp nix/kafka-server.properties .dev/kafka/server.properties   # after writing the config file
kafka-storage.sh format --standalone -t "$(kafka-storage.sh random-uuid)" -c .dev/kafka/server.properties
kafka-server-start.sh .dev/kafka/server.properties &
kafka-topics.sh --bootstrap-server 127.0.0.1:9092 --list
```

Expected probe transcript once the broker runs (empty list first boot, or the fixture topic):

```text
$ kafka-topics.sh --bootstrap-server 127.0.0.1:9092 --list
activity.v1
```

Edit `process-compose.yaml`, appending (keep the existing `postgres`, `create_schema`, and
`sanity_check` entries unchanged):

```yaml
  kafka:
    command: >
      bash -c 'mkdir -p .dev/kafka &&
      cp -n nix/kafka-server.properties .dev/kafka/server.properties || true &&
      test -f .dev/kafka/.formatted ||
        (kafka-storage.sh format --standalone -t "$(kafka-storage.sh random-uuid)" -c .dev/kafka/server.properties &&
         touch .dev/kafka/.formatted) &&
      exec kafka-server-start.sh .dev/kafka/server.properties'
    readiness_probe:
      exec:
        command: "kafka-topics.sh --bootstrap-server 127.0.0.1:9092 --list"
      initial_delay_seconds: 5
      period_seconds: 5
      timeout_seconds: 4
      failure_threshold: 10
    availability:
      restart: on_failure

  stub_kawa:
    command: "cabal run shikigami -- stub-kawa --port 8088"
    availability:
      restart: on_failure

  worker:
    command: "cabal run shikigami -- worker --agents agents"
    depends_on:
      create_schema:
        condition: process_completed_successfully
      stub_kawa:
        condition: process_started
    availability:
      restart: on_failure

  scheduler:
    command: "cabal run shikigami -- scheduler --agents agents"
    depends_on:
      create_schema:
        condition: process_completed_successfully
    availability:
      restart: on_failure

  consume_stream:
    command: "cabal run shikigami -- consume-stream --agents agents"
    depends_on:
      create_schema:
        condition: process_completed_successfully
      kafka:
        condition: process_healthy
    availability:
      restart: on_failure

  consume_events:
    command: "cabal run shikigami -- consume-events --agents agents"
    depends_on:
      create_schema:
        condition: process_completed_successfully
      kafka:
        condition: process_healthy
    availability:
      restart: on_failure
```

(When `docs/plans/29-health-liveness-and-worker-loop-supervision.md` is complete, add its
`--health-port` flags here and replace the shikigami processes' started-conditions with
`http_get` readiness probes against each process's `/readyz`.)

Add to `Justfile`:

```just
# Boot the full local stack (postgres + kafka + migrations + runtime processes).
dev: build
    process-compose

build:
    cabal build all

dev-down:
    process-compose down
```

Run and verify M1:

```bash
just dev            # TUI comes up; leave it running
# in a second terminal:
process-compose process list
```

Expected (abridged; exact column layout varies by process-compose version):

```text
NAME             STATUS
postgres         Ready
kafka            Ready
create_schema    Completed
stub_kawa        Running
worker           Running
scheduler        Running
consume_stream   Running
consume_events   Running
```

M2 smoke, in a second terminal with the stack up:

```bash
cabal run shikigami -- publish-fixture fixtures/envelope.json
```

Then observe in the process-compose TUI (or `.dev/process-compose.log`):

```text
[stream] MATCH agent=heartbeat
[stream]   enqueued run job ...
[shikigami.worker] agent=heartbeat workflow completed
```

followed by an ingest log line from `stub_kawa` (its exact format is defined in
`shikigami-core/src/Shikigami/Sink/KawaStub.hs`; match on the envelope log it writes per
accepted POST). Which agent matches depends on the fixture and the manifests in `agents/`;
`fixtures/envelope.json` is built to match the checked-in detector agents — read the fixture
and `agents/*.dhall` and substitute the actual agent name in the transcript.

M3, after writing `nix/nixos-module.nix` and extending `flake.module.nix`:

```bash
nix flake show 2>/dev/null | grep -A1 nixosModules
nix flake check
```

Expected:

```text
└───nixosModules
    └───shikigami: NixOS module
```

and `nix flake check` finishing without error (the `nixos-module-eval` check evaluates).

M4:

```bash
mkdir -p docs/operations
"$EDITOR" docs/operations/configuration.md
grep -n PG_CONNECTION_STRING shikigami-cli/src/Shikigami/Cli/Commands/*.hs
grep -n OTEL_EXPORTER_OTLP_ENDPOINT shikigami-core/src/Shikigami/Telemetry.hs
```

The two greps are the spot-check that the reference's claims match the code.


## Validation and Acceptance

Local stack: from a clean checkout (no `db/`, no `.dev/`), `nix develop` then `just dev`
reaches the process list shown above — `postgres` and `kafka` Ready, `create_schema`
Completed, five shikigami processes Running — with no manual intervention. Then
`cabal run shikigami -- publish-fixture fixtures/envelope.json` produces, within a few
seconds, a `[stream] MATCH` line from `consume_stream`, a `workflow completed` line from
`worker`, and an ingest line from `stub_kawa`. While the stack is up,
`psql "$PG_CONNECTION_STRING" -c 'select 1'` succeeds. Quitting the TUI (or `just dev-down`)
and re-running `just dev` works without manual cleanup — this proves the Kafka format guard
and the idempotent `create-database` path.

Packaging: `nix flake show` lists `nixosModules.shikigami`, and `nix flake check` passes,
including `checks.<system>.nixos-module-eval`, which must fail if the module stops rendering
`shikigami worker --agents` (or the other three subcommands) into the services' `ExecStart`.

Configuration reference: `docs/operations/configuration.md` exists and covers the existing
database/migration surface plus the actual provider, sink-auth, observability, health, and
kanmon settings produced by plans 13, 22, 28, 29, and 32. Every entry cites its owning
implementation; there are no reserved placeholders.

Regression: `cabal build all` and `cabal test all` still pass inside `nix develop`. The only
test suite, `shikigami-core-test`, provisions its own ephemeral Postgres via
`withShikigamiMigratedDatabase`
(`shikigami-migrations/test-support/Shikigami/Migrations/TestSupport.hs:12`), so it must pass
whether or not the composed stack is running:

```bash
cabal test all
```

Expected: `Test suite shikigami-core-test: PASS`.


## Idempotence and Recovery

Every step is re-runnable. `create-database` already guards `createdb` behind a `pg_database`
existence check; the Kafka storage format is guarded by `.dev/kafka/.formatted`;
`process-compose` restarts crashed processes per each `availability.restart` policy, and the
whole stack tears down with `process-compose down`. If the Kafka data directory is corrupted
(broker crash-loops with a storage error in the TUI), recovery is
`rm -rf .dev/kafka && just dev` — nothing durable lives in Kafka (durable state is Postgres);
the fixture topic is re-created on demand. If `create_schema` fails mid-migration, codd applies
migrations transactionally; re-running `just migrate` resumes from the ledger. The nix changes
are additive files (`flake.module.nix`, `nix/nixos-module.nix`, `nix/kafka-server.properties`);
rollback is deleting them plus `git checkout -- process-compose.yaml Justfile`.


## Interfaces and Dependencies

Tools: `process-compose` (already in the dev shell, `nix/haskell.nix:25-35`); nixpkgs
`apacheKafka` (new, via `haskellProject.extraDevPackages` in `flake.module.nix`); `just`;
flake-parts (the `flake.nixosModules` mechanism). No new Haskell dependencies — this plan
changes zero Haskell code.

Files that must exist at the end: `flake.module.nix` (committed; sets `extraDevPackages`,
exports `flake.nixosModules.shikigami`, defines `perSystem.checks.nixos-module-eval`),
`nix/nixos-module.nix`, `nix/kafka-server.properties`, the extended `process-compose.yaml`,
the extended `Justfile` (`dev`, `build`, `dev-down`), and `docs/operations/configuration.md`.

The NixOS module's option interface (the names operators and later plans program against):

```nix
services.shikigami = {
  enable = true;
  package = <derivation>;            # default: this flake's packages.default
  agentsDir = "/etc/shikigami/agents";
  environmentFile = "/run/secrets/shikigami.env";  # PG_CONNECTION_STRING, OTEL_*
  worker = { enable = true; kawaUrl = "..."; kizashiUrl = "..."; danwaUrl = "..."; danwaAgent = "part_shikigami"; };
  scheduler.enable = true;
  consumeStream = { enable = true; broker = "127.0.0.1:9092"; topic = "activity.v1"; group = "shikigami-stream"; };
  consumeEvents = { enable = true; broker = "127.0.0.1:9092"; topic = "danwa.message-addressed.v1"; group = "shikigami-events"; };
  migrate.enable = false;            # oneshot shikigami-migrate service for single-host setups
};
```

Cross-plan dependencies, as recorded in
`docs/masterplans/6-operations-and-observability-run-shikigami-as-a-real-service.md`: soft
dependency on `docs/plans/29-health-liveness-and-worker-loop-supervision.md` (readiness probes
upgrade from exec/started conditions to `/readyz` HTTP probes; nothing here blocks on it);
integration dependency with
`docs/plans/28-structured-logging-metrics-and-trace-propagation.md` (its logging/metrics env
vars and flags are added to the configuration reference and the NixOS module); documentation
and closure dependency on
`docs/plans/13-wire-a-real-model-provider-into-behavior-runs.md` and
`docs/plans/22-outbound-authentication-for-sink-clients.md` (owners of model-provider and
sink-credential names), plus plan 32's kanmon configuration. The plan is implementable
earlier, but should land after these soft dependencies.


## Revision Notes

- 2026-07-22: Made this the operations-closure plan. The configuration reference now
  waits for and documents actual settings from plans 13, 22, 28, 29, and 32 instead of
  publishing reserved placeholders.
