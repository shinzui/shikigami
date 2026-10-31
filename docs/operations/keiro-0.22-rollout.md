# Keiro 0.22 first deployment on macOS

This release establishes the current schema and workflow baseline for an unused
service. The accepted profile is arm64 macOS, GHC 9.12.4, PostgreSQL 18 and PGMQ,
with local stub model fixtures for repeatable qualification. Linux containment,
live vendor credentials and a real Kafka broker are outside this profile.
The remaining exhaustive domain audit is tracked in
[plan108](../plans/108-complete-the-remaining-domain-scalar-identity-and-decoder-audit.md).

## Build and identify the candidate

Use the pinned development shell and committed Cabal project, with no ignored
local dependency overrides. `cabal.project`, the released-cohort evidence and
`nix/qualification/cohort.json` identify the selected 0.22 closure. The latter
contains exact descriptor/source hashes, flags and six immutable Git sources.
It supersedes the old 0.18 export. A refreshed export is not a cold Nix build.

```bash
nix develop --no-write-lock-file -c cabal build all --enable-tests -j1
nix develop --no-write-lock-file -c cabal list-bin exe:shikigami-migrate
nix develop --no-write-lock-file -c cabal list-bin exe:shikigami-server
nix develop --no-write-lock-file -c cabal list-bin exe:shikigami-worker
```

Run the displayed absolute executables in the same runtime environment. Record
`--version`, source identity and artifact hashes before operating. The Nix role
recipe installs schema, fixture/skill assets and completions under its output;
final qualification also exercises built macOS roles outside the checkout using
copied schema/agent assets. No Linux verification is required for this acceptance.

## Provision and verify a fresh database

Obtain a PostgreSQL 18 connection from the deployment's configuration source.
Use a newly provisioned database; these instructions never clear a developer or
existing database. The migration role reads `DATABASE_URL`. Other application
roles read `PG_CONNECTION_STRING` through Settei.

```bash
export DATABASE_URL='host=127.0.0.1 port=5432 dbname=shikigami user=shikigami'
shikigami-migrate plan
shikigami-migrate up
shikigami-migrate status
shikigami-migrate verify-schema
export PG_CONNECTION_STRING="$DATABASE_URL"
```

The composed owners are PGMQ, Kiroku, Keiro, Kioku and Shikigami. `up` also
reconciles the application read-model registry. Startup verifies the migration
ledger and refuses missing/changed history; `verify-schema` independently checks
live framework/application objects. Investigate a refusal rather than editing
checksums, deleting rows or bypassing verification.

## Configure and start roles

Install the intended agent declarations and their referenced schema/skills.
Use an absolute agents directory outside the source checkout. Inspect each role's
accepted settings before startup:

```bash
shikigami-server --describe-config
shikigami-worker --describe-config
shikigami-server --check-config --config /absolute/path/server.yaml
shikigami-worker --check-config --config /absolute/path/worker.yaml
```

Configure public HTTP authentication through the secret source and enable bearer
mode explicitly. Keep inspection disabled unless needed. If enabled, use the
separate bounded loopback listener and credentials described in
[inspection](inspection.md); public HTTP authentication is a different boundary.

```bash
shikigami-server --config /absolute/path/server.yaml
shikigami-worker --config /absolute/path/worker.yaml
```

Run these in the deployment's process supervisor with independently retained logs.
Start scheduler/stream/event roles only when their corresponding source and
transport are configured. Do not enable Linux-only process/containment tools on
the strength of this macOS qualification. Configuration, profiles and action
verification remain mandatory for actual tool/provider dispatch.

## Exercise work and same-build recovery

Check `/health/ready`, then use the configured client/server credentials to list
agents and submit one enabled agent with a stable caller key. Repeat that exact
request and confirm it returns the original run. Inspect its status/history,
wait for worker completion and verify that duplicate submission did not dispatch
a second provider/tool action. Use `shikigami-client --help` and its `runs`
subcommands for the current CLI contract.

Stop the owning worker/server through the supervisor, restart the same binaries
with the same configuration/database, and inspect the original run. Retained
workflows, queue receipts and actual attempts govern recovery. Unknown physical
outcomes stay unresolved until their original evidence arrives; a restart is not
permission to start a replacement effect or release capacity.

For the repeatable disposable qualification fixture:

```bash
nix develop --no-write-lock-file -c bash tests/hurl/run.sh
python3 tests/cli/contracts.py
```

The HTTP fixture provisions and removes only its own PostgreSQL instance, copies
schema/agents outside the checkout, checks authentication/idempotency/status and
actual worker delivery, and exercises permanent failure and database outage.
The CLI fixture checks eleven roles, three shell completions, configuration/stdin
boundaries and malformed input from an unrelated working directory.

## Stop and rollback boundaries

Stop producers before draining/stopping consumers, and preserve pending work,
receipts and protected payloads. Retain the exact qualified binary/configuration
set for same-build restart. Old Keiro 0.18 binaries are not a fallback against the
new schema. Any future cross-build change follows
[workflow versioning](../workflow-versioning.md) and needs its own deployment
qualification; this first-release evidence does not promise populated downgrade.
