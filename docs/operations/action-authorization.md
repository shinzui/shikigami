# Per-action authorization operations

Shikigami fails closed at every protected external-IO boundary. Enabling Kikan authorization is a
grouped configuration change: partial trust material is rejected during configuration resolution,
and the default `disabled` mode authorizes no provider, tool, or sink action.

The owning services and contracts are:

* `mori://shinzui/kikan-en` — Kikan product policy, `POST /v1/agent-actions/authorize`, and the
  proof-verifying client;
* `mori://shinzui/shomei` — OAuth2 `client_credentials` issuer;
* `mori://shinzui/en/packages/en-biscuit` — signed decision proof and local verifier.


## Required configuration

Set all of these values for the worker:

| Key | Environment variable | Meaning |
|---|---|---|
| `authorization.actions.mode` | `SHIKIGAMI_ACTION_AUTHORIZATION_MODE` | Set to `kikan`. |
| `authorization.actions.kikan_en.base_url` | `SHIKIGAMI_ACTION_KIKAN_EN_BASE_URL` | HTTPS base URL for Kikan-En. |
| `authorization.actions.shomei.base_url` | `SHIKIGAMI_ACTION_SHOMEI_BASE_URL` | HTTPS base URL for Shomei. |
| `authorization.actions.shomei.client_id` | `SHIKIGAMI_ACTION_SHOMEI_CLIENT_ID` | Machine client allowed the exact scope below. |
| `credentials.authorization.actions.shomei.client_secret` | `SHIKIGAMI_ACTION_SHOMEI_CLIENT_SECRET` | Secret machine credential; redacted by Settei. |
| `authorization.actions.en.issuer_public_keys` | `SHIKIGAMI_ACTION_EN_ISSUER_PUBLIC_KEYS` | En verifier keyset, `<id>:<64-hex>[,…]`. |
| `authorization.actions.en.schema_hashes` | `SHIKIGAMI_ACTION_EN_SCHEMA_HASHES` | Comma-separated accepted Kikan schema hashes such as `sha256:…`. |
| `authorization.actions.caller_id` | `SHIKIGAMI_ACTION_CALLER_ID` | Bounded public service identity written to audit logs. |

The Shomei client must be permitted exactly the
`kikan-en:authorize-agent-action` scope. The configured Kawa source remains
`sinks.kawa.source_segment`; it is also the exact Kawa authorization target.

Validate without starting a process:

```bash
shikigami-worker --check-config
shikigami-worker --explain-config
```

The explanation redacts the Shomei client secret. Never place that secret, an OAuth token, or a
Biscuit in a support transcript.


## Gate order and failure behavior

Capability connection runs the existing pure catalog admission, then C13, then provider
acquisition. Each leased logical tool runs C13 again immediately before its callback. A provider
lease does not grant its sibling tools. Current providers have no separate discovery IO callback;
adding one requires a `DiscoverCapabilityTools` check at that new boundary.

Sink enqueue and publish both run lifecycle admission, C11 sink-kind authorization, and C13 exact
target authorization in that order. A policy denial is journaled as `DeniedOutcome` and performs
no IO. Kikan/Shomei outage, invalid coordinates, or proof rejection becomes the distinct
`AuthorizationFailed` outcome and performs no IO. At enqueue it creates no outbox row; at publish
it leaves a retryable delivery failure.

Audit event `agent_action.authorization` contains only caller id, Meibo principal, action,
canonical resource, request id, decision, and—on allow—checked-at token, schema hash, and expiry.
It never contains credentials, proof bytes, tool payloads, or sink payloads.


## Revocation and key rotation

Kikan-En requests a fully consistent En decision for every mint. Deleting the exact relationship
therefore prevents the next proof immediately. A proof already returned to a caller can remain
locally valid until its signed expiry: the default lifetime is 30 seconds and the issuer ceiling is
60 seconds. Shikigami does not store the proof and obtains a fresh one for every boundary.

For signer rotation:

1. Add the new En public key to every Shikigami verifier keyset.
2. Confirm the new trust configuration is deployed.
3. Switch Kikan-En to the new signing key id.
4. Retain the old public key for more than 60 seconds, then remove it.

Schema rollout follows the same overlap discipline: deploy a verifier accepting both hashes,
switch Kikan-En, wait beyond 60 seconds, and then remove the old hash.


## Incident triage

An `unavailable` decision points to Shomei token acquisition, Kikan transport, authentication, or
service availability. A `proof_rejected` decision means the HTTP allow could not be verified
against the configured keys, audience, schema hashes, coordinates, time, or revocation source.
Treat it as a trust-configuration or issuer incident, not as a policy denial. A `denied` decision
means Kikan evaluated the exact current relationship and returned no allow.

Do not bypass the authorizer during an outage. Restore Shomei/Kikan reachability or correct the
trust set, then retry the action before any protected IO.
