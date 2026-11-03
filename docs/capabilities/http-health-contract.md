---
type: "Capability"
title: "Typed HTTP health contract"
description: "Serve separate liveness and readiness endpoints with a shared typed client, OpenAPI description, and problem response conventions."
capabilityId: "CAP-16"
provider: "mori://shinzui/shikigami"
status: "shipped"
stability: "experimental"
since: "unreleased"
packages: ["shikigami-api", "shikigami-server", "shikigami-client", "shikigami-workers"]
interface: ["GET /health/live", "GET /health/ready", "Shikigami.Client", "shikigami-client health --server URL", "shikigami-openapi"]
tags: ["http-health-contract"]
generated:
  by: "process:shikigami-capabilities-bootstrap"
  at: "2026-10-10T15:55:22Z"
evidence:
  - kind: module
    resource: "shikigami-client/src/Shikigami/Client/Command.hs"
    proves: "The client health command checks both probes and fails on a failed probe or request."
  - kind: test
    resource: "shikigami-workers/test/Shikigami/Health/WorkerSpec.hs"
    proves: "Worker probe contract, heartbeat staleness, and configured dependency readiness behavior."
  - kind: module
    resource: "shikigami-api/src/Shikigami/Api.hs"
    proves: "The shared public route tree mounts health separately from the authenticated agents vertical."
  - kind: test
    resource: "shikigami-server/test/Shikigami/Server/DispatchSpec.hs"
    proves: "Documented paths equal served paths and the two probes use their intended checks."
  - kind: test
    resource: "shikigami-api/test/Shikigami/Api/OpenApiSpec.hs"
    proves: "Generated OpenAPI contract behavior."
  - kind: example
    resource: "shikigami-api/test/hurl/health.hurl"
    proves: "Executable HTTP probe assertions."
---

# Typed HTTP health contract

## Provides

The API package declares one shared route record from which server dispatch, typed client calls, and OpenAPI generation derive. Liveness and readiness use distinct injectable checks and typed 200/503 responses. Other application failures use the common problem-details contract rather than ad hoc response shapes.

## Adopt

Start `shikigami-server` with its resolved configuration, call the probe routes, or derive calls through the client package. `shikigami-client health --server URL` checks both probes and exits nonzero on a failed probe or call. Worker roles expose the same health paths through their optional configured listeners. Generate the API document with `shikigami-openapi`.

## Evidence

- [Client/Command.hs](../../shikigami-client/src/Shikigami/Client/Command.hs): client health checks and exit behavior.
- [WorkerSpec.hs](../../shikigami-workers/test/Shikigami/Health/WorkerSpec.hs): worker health contract.
- [Api.hs](../../shikigami-api/src/Shikigami/Api.hs): Health is mounted separately from the authenticated agents vertical.
- [DispatchSpec.hs](../../shikigami-server/test/Shikigami/Server/DispatchSpec.hs): Documented paths equal served paths and the two probes use their intended checks.
- [OpenApiSpec.hs](../../shikigami-api/test/Shikigami/Api/OpenApiSpec.hs): Generated OpenAPI contract behavior.
- [health.hurl](../../shikigami-api/test/hurl/health.hurl): Executable HTTP probe assertions.

## Limits

Health probes are public even when [HTTP caller authentication](http-caller-authentication.md) protects the agents mount. The API also serves the [declared-agent catalog](declared-agent-http-catalog.md), [run acceptance](idempotent-http-agent-runs.md), and [run lifecycle/history](http-agent-run-lifecycle.md). Grants, approval resolution, and attestations remain outside the public HTTP surface. Probe 503 bodies are status reports and intentionally differ from application problem responses.

The available implementation is unreleased. No Shikigami release tags or published releases were present when this catalog was authored; the Cabal package version alone does not establish a released compatibility promise.
