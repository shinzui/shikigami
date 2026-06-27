let A = ../../schema/Agent.dhall
in  A.Agent::{
    , name = "code-researcher"
    , behavior =
        A.Behavior.ShikumiProgram
          { task = "code-researcher"
          , preferEnrichment = False
          , grounding = None Text
          , enabledBy = None Text
          }
    , trigger = A.Trigger.Event { eventType = "proof.research.code" }
    , sinks = [] : List A.Sink
    }
