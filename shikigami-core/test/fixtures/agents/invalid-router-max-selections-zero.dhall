let A = ../../../../schema/Agent.dhall

in  A.Agent::{
    , name = "invalid-router-max-selections-zero"
    , trigger = A.Trigger.Event { eventType = "test.invalid-router" }
    , behavior =
        A.Behavior.ShikumiProgram
          { task = "noop-summary"
          , preferEnrichment = False
          , grounding = None Text
          , enabledBy = None Text
          }
    , delegates = [ "proof-reviewer" ]
    , routing = Some
      { maxSelections = 0
      , minimumConfidence = A.RouterConfidence.RoutingMedium
      , onNoMatch = A.NoMatchPolicy.ReturnNoMatch
      , onAmbiguous = A.AmbiguousPolicy.ReturnAmbiguous
      }
    }
