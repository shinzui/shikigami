# Keiro 0.18 rollout

This runbook covers a direct Shikigami upgrade from the qualified Keiro 0.17
runtime to the qualified 0.18 runtime. The release changes no Keiro migration
payload, workflow step shape, queue envelope, event codec, or identifier admission.
It therefore needs no maintenance window, queue drain, journal replay, or schema
cutover.

If the deployed runtime predates Keiro 0.17, first complete the guarded timer
cutover in [the 0.17 runbook](keiro-0.17-rollout.md). Do not skip that boundary by
applying this binary-only procedure to a 0.15 deployment.

## Before deployment

1. Build every deployable binary from the same revision. Confirm the Cabal plan
   selects `keiro`, `keiro-core`, `keiro-dsl`, `keiro-migrations`, `keiro-ops`,
   `keiro-pgmq`, and `keiro-test-support` at 0.18.0.0.
2. Run the read-only migration verification used by the normal startup path. It
   must accept the current ledger and report no pending Shikigami or Keiro
   migration introduced by this upgrade.
3. Confirm the worker and server configuration still points at the same database,
   queues, workflow registry, and migration owner used by the qualified 0.17
   deployment.

## Deploy

Stop or replace the 0.17 server, worker, migration, and operator binaries as one
release unit. Start the 0.18 migration verifier, then the server and workers through
their normal process owners. No writer fencing beyond the platform's ordinary
lockstep replacement is required because both versions read and write the same
durable contracts.

After startup, verify the health endpoint, worker queue consumption, and migration
verification. Exercise one representative run if the environment permits it, and
confirm that its workflow and RunEvidence records complete without a dead letter.

## Rollback

For a direct 0.17-to-0.18 deployment, stop the 0.18 binaries and redeploy the
qualified 0.17 binaries as one release unit. No database rollback or data rewrite
is required. This rollback permission ends after any later release writes a new
workflow shape, wire policy, identifier domain, or migration; follow that release's
own runbook instead.
