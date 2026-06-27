let A = ../../schema/Agent.dhall
in  A.Agent::{
    , name = "web-researcher"
    , behavior =
        A.Behavior.ShikumiProgram
          { task = "web-researcher"
          , preferEnrichment = False
          , grounding = None Text
          , enabledBy = None Text
          }
    , trigger = A.Trigger.Event { eventType = "proof.research.web" }
    , sinks = [] : List A.Sink
    }
