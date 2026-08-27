# 0036. External agent actions require fresh exact authorization

Date: 2026-08-26

Status: accepted


## Context

Shikigami already has local admission controls. Capability declarations are requests resolved
against an operator catalog, and sink dispatch retains the database-backed C11 lifecycle and
sink-kind grant. Neither control answers whether one admitted Meibo agent may touch one provider
revision, logical tool, or fully resolved sink target at the instant external IO occurs.

Kikan-En supplies the product policy and a narrow Shomei-authenticated check-and-mint endpoint.
Its allow response is a short-lived En Biscuit signed over the principal, operation, canonical
resource, audience, schema hash, consistency token, request id, and expiry.


## Decision

Every external agent action passes a fresh C13 decision in addition to the existing local gate.
Shikigami authorizes `ConnectCapability` immediately before provider acquisition and
`InvokeCapabilityTool` immediately before each leased `SomeTool.run`. Catalog resolution,
descriptor presence, provider connection, and tool discovery never imply tool invocation.
Shikigami's current providers advertise an immutable descriptor in their acquired lease and have
no separate discovery callback; if such a callback is introduced, it must authorize
`DiscoverCapabilityTools` immediately before that IO.

Sinks retain lifecycle admission and the C11 sink-kind grant. After those pass, Shikigami derives
the closed Kikan action from the fully resolved intent and authorizes it before enqueue. The
publisher repeats lifecycle, C11, and C13 against the durable exact target immediately before
delivery. It obtains a new decision rather than persisting the enqueue decision.

Only `mori://shinzui/kikan-en/packages/kikan-en-client` may turn an HTTP allow into an authorized
action. The client verifies the En Biscuit locally against the original coordinates and configured
issuer keys and schema hashes. Shikigami retains only bounded audit coordinates; bearer tokens,
Biscuit bytes, tool inputs/results, provider credentials, and sink payloads are neither logged nor
written to journals or outbox rows.

Policy denial remains a terminal non-action. Service unavailability, invalid coordinates, and
proof rejection are distinct retryable fail-closed outcomes. Missing production configuration
installs a deny-all authorizer; test-only allow fixtures must be selected explicitly.


## Alternatives rejected

**Replace C11 with Kikan-En.** Rejected because lifecycle and coarse sink authority answer a
different question and already close the enqueue-to-publish revocation race.

**Authorize only at declaration or catalog resolution.** Rejected because declarations and pure
resolution are requests, not fresh authority, and cannot guard the eventual IO callback.

**Authorize a provider once and trust all advertised tools.** Rejected because provider
connection does not imply permission for sibling tools.

**Store the Biscuit in the workflow journal or outbox.** Rejected because the proof is a bearer
capability, can outlive a relationship deletion briefly, and is unnecessary after the guarded IO
returns.


## Consequences

Kikan-En and Shomei are required for protected production IO. A Kikan or Shomei outage produces no
provider connection, tool callback, outbox insertion, or downstream delivery. Each sink incurs two
authorization requests, and each tool invocation incurs one.

Kikan-En issues proofs for 30 seconds and enforces a 60-second maximum. Deleting a relationship
prevents the next fully consistent mint immediately, but an already-issued proof remains locally
valid until expiry unless its revocation id is consulted. Issuer rotation therefore trusts the new
public key before switching the signer and retains the old public key for at least the 60-second
maximum lifetime.


## References

* `mori://shinzui/en/plans/27-per-action-authorization-for-agent-tool-and-sink-dispatch` —
  coordinated implementation and cross-repository evidence.
* `mori://shinzui/kikan-en` — closed action contract, policy schema, authenticated endpoint, and
  proof-verifying client.
* `mori://shinzui/en/packages/en-biscuit` — generic signed decision proof and verifier.
* [ADR 0025](0025-capability-overlays-are-requests-for-additive-model-tools.md) — operator-owned
  overlay descriptors and provider leases.
* [ADR 0033](0033-recorded-agent-principals-key-durable-state.md) — admitted Meibo principal
  identity.
