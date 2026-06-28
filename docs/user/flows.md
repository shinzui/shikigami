# Flows

`Flow` behavior names a registered lifecycle-backed agent workflow:

```dhall
behavior = Schema.Behavior.Flow { name = "at-risk-customer" }
```

Flows run inside the agent workflow, so their internal steps, waits, and sink emissions are journaled by `keiro`. Use a Flow when the agent needs a durable lifecycle with modeled states, approvals, acknowledgements, or replay-safe side effects.

## At-risk customer

The first registered flow is `at-risk-customer`. Its manifest lives at:

```sh
agents/detectors/at-risk-customer-flow.dhall
```

The flow classifies incoming ticket activity. Low-risk input returns a low-risk result with no sink outbox message. High-risk input emits an alert, parks for acknowledgement, and either records the acknowledgement branch or escalates after the configured acknowledgement deadline.

## Rendering the lifecycle

Render the registered lifecycle as Mermaid:

```sh
cabal run shikigami -- render-lifecycle agents/detectors/at-risk-customer-flow.dhall
```

Validate the Dhall manifest with the normal loader:

```sh
cabal run shikigami -- validate agents/detectors/at-risk-customer-flow.dhall
```
