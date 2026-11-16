--| opentelemetry-practice-reviewer: the specialist the router delegates to.
-- It reads revision-pinned evidence, recalls prior adjudication, validates one
-- advisory verdict and records it as review memory.
--
-- The flow lives in this pack. Run it from a worker composed with the pack
-- (kikan-shikigami-worker); the stock worker refuses the manifest.
let A = ../../../schema/Agent.dhall

in  A.Agent::{
    , name = "opentelemetry-practice-reviewer"
    , description =
        "Reviews OpenTelemetry instrumentation and telemetry architecture"
    , behavior = A.Behavior.Flow { name = "opentelemetry-practice-review" }
    , trigger =
        A.Trigger.Event { eventType = "proof.opentelemetry-practice-review" }
    , expertise =
      [ { key = "opentelemetry"
        , description =
            "OpenTelemetry signals, semantic conventions, context propagation, and SDK architecture"
        , aliases = [ "otel", "telemetry" ]
        , evidenceHints =
          [ "traceparent", "service.name", "instrumentation scope" ]
        }
      ]
    , sanctionedProfile = Some
      { profileId = "sanctioned-review", version = Some "1" }
    , memory =
      { scope = A.MemoryScope.AgentScope
      , recallLimit = 10
      , recordPolicy = A.RecordPolicy.Never
      }
    , sinks = [] : List A.Sink
    }
