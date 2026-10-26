---
type: "Capability"
title: "HTTP caller authentication"
description: "Verify configured bearer credentials at the agents mount and propagate a credential-free caller identity to run acceptance."
capabilityId: "CAP-23"
provider: "mori://shinzui/shikigami"
status: "shipped"
stability: "experimental"
since: "unreleased"
packages: ["shikigami-api","shikigami-server","shikigami-client"]
interface: ["Shikigami.Caller.Api","Shikigami.Caller.Verifier","http.auth.mode","SHIKIGAMI_API_TOKEN"]
tags: ["http-caller-authentication"]
generated:
  by: "process:shikigami-documentation-refresh"
  at: "2026-10-25T00:00:00Z"
evidence:
  - kind: module
    resource: "shikigami-server/src/Shikigami/Caller/Verifier.hs"
    proves: "One Authorization header is verified at the protected mount; missing/invalid credentials produce a Bearer challenge."
  - kind: test
    resource: "shikigami-server/test/Shikigami/Caller/VerifierSpec.hs"
    proves: "Bearer acceptance/refusal, duplicate headers, disabled mode, and public probes."
---

# HTTP caller authentication

## Provides

Bearer mode authenticates every route under `/agents` through the vertical mount and supplies a caller ID for acceptance attribution. Invalid or missing credentials return 401 problem details and `WWW-Authenticate`. Health probes remain public. The typed client supplies the credential without changing individual route DTOs.

## Adopt

Set `http.auth.mode=bearer`, provide `http.auth.token` with at least sixteen characters, and optionally set `http.auth.caller`. The client accepts a global `--token TOKEN` or `SHIKIGAMI_API_TOKEN`. See [HTTP API setup](../user/http-api.md) and [authentication configuration](../operations/configuration.md#inbound-api-authentication).

## Evidence

- [Verifier.hs](../../shikigami-server/src/Shikigami/Caller/Verifier.hs): One Authorization header is verified at the protected mount; missing/invalid credentials produce a Bearer challenge.
- [VerifierSpec.hs](../../shikigami-server/test/Shikigami/Caller/VerifierSpec.hs): Bearer acceptance/refusal, duplicate headers, disabled mode, and public probes.

## Limits

Authentication defaults to disabled, producing caller `anonymous`. The initial verifier has one configured credential/caller and no per-agent caller permission model. Rotation requires restart. Caller authentication does not replace the agent's lifecycle admission, sink grants, profiles, or exact-action checks.

This provision is experimental and unreleased; its implementation does not establish a released compatibility promise.

