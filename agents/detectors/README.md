# Detector declarations

These manifests import [the canonical agent schema](../../schema/Agent.dhall).
The [detector guide](../../docs/user/detectors.md) documents their current runtime
support and how to configure the worker and stream consumer.

| Manifest | Status |
| --- | --- |
| [stalled-intention.dhall](stalled-intention.dhall) | Schema-valid seed; `Deterministic` execution is unsupported. |
| [at-risk-customer.dhall](at-risk-customer.dhall) | Schema-valid seed; its classifier task is not registered. |
| [at-risk-customer-flow.dhall](at-risk-customer-flow.dhall) | Registered durable Flow; requires database, approval, and sink authorization wiring. |

`schema.dhall` is a retired tombstone that evaluates to text, not an Agent schema.
Import `../../schema/Agent.dhall` instead. Directory loading
is not recursive: pass `--agents agents/detectors` to both worker and consumer.
Validation checks declarations, not the execution of every behavior. The seed
`enabledBy` field and the migrated detector suppression table are not active runtime
features. See [Flows](../../docs/user/flows.md) for the executable lifecycle example.
