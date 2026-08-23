let A = ../../schema/Agent.dhall

in  A.Agent::{
    , name = "opentelemetry-practice-reviewer"
    , description =
        "Reviews OpenTelemetry instrumentation and telemetry architecture"
    , behavior =
        A.Behavior.ShikumiProgram
          { task = "noop-summary"
          , preferEnrichment = False
          , grounding = None Text
          , enabledBy = None Text
          }
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
    }
