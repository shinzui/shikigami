let A = ../../schema/Agent.dhall
in  A.Agent::{
    , name = "code-researcher"
    , behavior =
        A.Behavior.ShikumiProgram
          { task = "code-researcher"
          , preferEnrichment = False
          , grounding = None Text
          }
    , trigger = A.Trigger.Event { eventType = "proof.research.code" }
    }
