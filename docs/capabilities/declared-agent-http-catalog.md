---
type: "Capability"
title: "Declared-agent HTTP catalog"
description: "Discover boot-loaded declarations and current lifecycle admission through authenticated HTTP, Relay pages, and a typed client."
capabilityId: "CAP-22"
provider: "mori://shinzui/shikigami"
status: "shipped"
stability: "experimental"
since: "unreleased"
packages: ["shikigami-core","shikigami-api","shikigami-server","shikigami-client"]
interface: ["GET /agents","GET /agents/{agentName}","shikigami-client agents list|show"]
tags: ["declared-agent-http-catalog"]
generated:
  by: "process:shikigami-documentation-refresh"
  at: "2026-10-25T00:00:00Z"
requires: ["CAP-1","CAP-23"]
evidence:
  - kind: module
    resource: "shikigami-server/src/Shikigami/Agent/Handler.hs"
    proves: "Declaration views, lifecycle joins, stable name ordering, and pagination refusal behavior."
  - kind: test
    resource: "shikigami-server/test/Shikigami/Agent/HandlerSpec.hs"
    proves: "Known/disabled/unknown agents, unavailable directory, malformed pagination, and bidirectional page conformance."
---

# Declared-agent HTTP catalog

## Provides

Clients can list or inspect the server deployment's valid declarations, including disabled agents, without reading its filesystem. Views expose enablement, behavior/trigger/sink kinds, delegates, declared principal, current lifecycle, and `runnable`. Pages use Relay connections ordered by name, with a default size of 50 and maximum of 200.

## Adopt

Start the server with its agent directory and caller configuration, then use `shikigami-client agents list` or `agents show NAME`. Follow the [HTTP API guide](../user/http-api.md) for credentials, pagination, and the generated [OpenAPI contract](../api/openapi.json).

Builds on [CAP-1: Typed agent declarations](typed-agent-declarations.md) and [CAP-23: HTTP caller authentication](http-caller-authentication.md).

## Evidence

- [Handler.hs](../../shikigami-server/src/Shikigami/Agent/Handler.hs): Declaration views, lifecycle joins, stable name ordering, and pagination refusal behavior.
- [HandlerSpec.hs](../../shikigami-server/test/Shikigami/Agent/HandlerSpec.hs): Known/disabled/unknown agents, unavailable directory, malformed pagination, and bidirectional page conformance.

## Limits

Declarations are a boot-time snapshot; reload requires restart. Directory-disabled views say `unverified`. Runnable reflects enablement and lifecycle, not provider, tool, profile, or sink success. An unavailable lifecycle directory returns 503. The catalog cannot create or edit manifests.

This provision is experimental and unreleased; its implementation does not establish a released compatibility promise.

