---
type: "Capability"
title: "Worker operations and telemetry"
description: "Operate supervised background roles with bounded recovery, configuration diagnostics, runtime inspection, and exported run metrics."
capabilityId: "CAP-17"
provider: "mori://shinzui/shikigami"
status: "shipped"
stability: "experimental"
since: "unreleased"
packages: ["shikigami-workers", "shikigami-server", "shikigami-core"]
interface: ["shikigami-worker", "shikigami runs", "shikigami wf", "--check-config", "--explain-config"]
tags: ["worker-operations-and-telemetry"]
generated:
  by: "process:shikigami-capabilities-bootstrap"
  at: "2026-10-10T15:55:22Z"
evidence:
  - kind: module
    resource: "shikigami-server/src/Shikigami/Server/Command/Runs.hs"
    proves: "Run inspection joins workflows to recorded sessions and retains explicit session-link failure states."
  - kind: test
    resource: "shikigami-server/test/Shikigami/Server/RequestLogSpec.hs"
    proves: "Request logging includes safe trace correlation and redaction and excludes health traffic."
  - kind: test
    resource: "shikigami-core/test/Shikigami/AppConfigSpec.hs"
    proves: "Configuration resolution, validation, secret redaction, and diagnostics without live resource acquisition."
  - kind: test
    resource: "shikigami-workers/test/Shikigami/Workers/SupervisionSpec.hs"
    proves: "Signal shutdown, sibling cancellation, resume retry limits, and bounded drain behavior."
  - kind: test
    resource: "shikigami-workers/test/Shikigami/TimerRecoverySpec.hs"
    proves: "Expired guarded timer claim recovery fences stale claim tokens."
  - kind: test
    resource: "shikigami-workers/test/Shikigami/TelemetrySpec.hs"
    proves: "Force-flush exports all run/queue/consumer metrics and independent sampling survives a failed target."
  - kind: guide
    resource: "docs/operations/configuration.md"
    proves: "Per-binary settings, sources, redacted explanation, and check-only diagnostics."
  - kind: guide
    resource: "docs/operations/operator-cli.md"
    proves: "Repository-owned fleet/run commands and mounted dependency-owned runtime commands."
---

# Worker operations and telemetry

## Provides

Separate binaries own queue execution, schedule intake, stream intake, and integration-event intake. Linked worker loops stop coherently when a required sibling ends or throws; resume work and timer recovery are bounded. Operators can inspect fleet/run state and use mounted workflow, timer, outbox, inbox, queue, and projection commands. Telemetry records correlated run outcomes, queue depth, and consumed records.

## Adopt

Resolve each role's configuration and use `--describe-config`, `--describe-config-json`, `--check-config`, or `--explain-config` before launch; the shared configuration resolver keeps diagnostics free of runtime resource acquisition and redacts secrets. Configure telemetry export and use [the operator CLI](../operations/operator-cli.md) for runtime inspection and explicitly selected maintenance operations. `shikigami runs show WORKFLOW_NAME WORKFLOW_ID --json` joins workflow state to the journal-recorded session, distinguishes unopened/refused/unreadable/missing sessions, and includes recorded turns when available. Request logging includes safe trace correlation and redaction while excluding routine health traffic.

## Evidence

- [Runs.hs](../../shikigami-server/src/Shikigami/Server/Command/Runs.hs): joined run/session inspection.
- [RequestLogSpec.hs](../../shikigami-server/test/Shikigami/Server/RequestLogSpec.hs): request logging contract.
- [AppConfigSpec.hs](../../shikigami-core/test/Shikigami/AppConfigSpec.hs): shared configuration contract.
- [SupervisionSpec.hs](../../shikigami-workers/test/Shikigami/Workers/SupervisionSpec.hs): Signal shutdown, sibling cancellation, resume retry limits, and bounded drain behavior.
- [TimerRecoverySpec.hs](../../shikigami-workers/test/Shikigami/TimerRecoverySpec.hs): Expired guarded timer claim recovery fences stale claim tokens.
- [TelemetrySpec.hs](../../shikigami-workers/test/Shikigami/TelemetrySpec.hs): Force-flush exports all run/queue/consumer metrics and independent sampling survives a failed target.
- [configuration.md](../../docs/operations/configuration.md): Per-binary settings, sources, redacted explanation, and check-only diagnostics.
- [operator-cli.md](../../docs/operations/operator-cli.md): Repository-owned fleet/run commands and mounted dependency-owned runtime commands.

## Limits

Long-running roles require their configured database, broker, and service dependencies. Metrics and diagnostics do not replace durable run evidence. Runtime administration commands are mounted from [the upstream operations package](mori://shinzui/keiro/packages/keiro-ops); Shikigami supplies the composition and its fleet/run commands.

The available implementation is unreleased. No Shikigami release tags or published releases were present when this catalog was authored; the Cabal package version alone does not establish a released compatibility promise.

## Bounded execution and session inspection

The administrative surface also includes `resources inspect`, `executions inspect`
and `workers inspect`, plus governed worker control verbs. See
[root accounting](root-resource-accounting.md),
[execution recovery](recoverable-skill-execution.md),
[continuing sessions](continuing-worker-primitives.md) and the
[operator guide](../operations/operator-cli.md). Inspection excludes protected
transcript/instruction bodies. Missing real providers refuse new dependent work.
