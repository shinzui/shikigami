let A = ../../schema/Agent.dhall

in  A.Agent::{
    , name = "architecture-practice-router"
    , description =
        "Routes architecture-practice payloads to declared specialists"
    , behavior =
        A.Behavior.ShikumiProgram
          { task = "noop-summary"
          , preferEnrichment = False
          , grounding = None Text
          , enabledBy = None Text
          }
    , trigger = A.Trigger.Event { eventType = "proof.architecture-practice" }
    , delegates = [ "opentelemetry-practice-reviewer", "code-researcher" ]
    , delegationBudget = Some 4
    , routing = Some
      { maxSelections = 2
      , minimumConfidence = A.RouterConfidence.RoutingMedium
      , onNoMatch = A.NoMatchPolicy.ReturnNoMatch
      , onAmbiguous = A.AmbiguousPolicy.ReturnAmbiguous
      }
    }
