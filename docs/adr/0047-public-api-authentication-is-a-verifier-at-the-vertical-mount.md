# 0047. Public API authentication is a verifier at the vertical mount

Date: 2026-10-25

Status: accepted

## Context

Agent discovery and run submission expose domain resources across the service
boundary. A configured credential must identify callers consistently, remain
opaque in diagnostics, and leave the supervisor's health probes usable.

## Decision

Protect the entire agents vertical with Servant's AuthProtect combinator. The
server's context owns a replaceable verifier that returns an ApiCaller. The
first verifier compares one configured bearer token using the existing opaque
token API and constant-time comparison. Missing, malformed, duplicate, and wrong
credentials return the same 401 problem and WWW-Authenticate challenge. Logs
contain only missing/invalid classification, never header bytes.

Health is exempt. Disabled mode identifies callers as anonymous, defaults for
loopback development, and warns when bound elsewhere. The OpenAPI mount instance
adds the security scheme and typed problem response; the client uses the same
mount through AuthenticatedRequest. The standalone client may read
SHIKIGAMI_API_TOKEN at command execution time, an exception to the application
configuration loader's environment ownership because the client has no core
configuration dependency.

## Alternatives rejected

Per-handler checks could omit a new route. WAI-only authentication would leave
the typed client and documentation unaware of required credentials. Coupling
routes to an issuer would make a credential-source migration change the public
contract.

## Consequences

An issuer-backed Shomei or En verifier replaces the static verifier without
changing routes. Authentication supplies identity only; per-agent authorization
remains separate from this boundary. Operators enable bearer mode for remote
access and restart to rotate the credential.

## References

[ExecPlan 89](../plans/89-authenticate-public-api-callers-with-configured-bearer-credentials.md),
[ADR 0026](0026-outbound-sink-credentials-stay-opaque-and-http-policy-lives-at-the-process-boundary.md),
and [ADR 0036](0036-external-agent-actions-require-fresh-exact-authorization.md).
