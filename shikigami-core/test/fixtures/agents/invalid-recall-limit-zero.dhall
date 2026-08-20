let A = ../../../../schema/Agent.dhall

in  A.Agent::{
    , name = "invalid-recall-limit-zero"
    , trigger = A.Trigger.Event { eventType = "test.invalid" }
    , behavior =
        A.Behavior.ShikumiProgram
          { task = "noop-summary"
          , preferEnrichment = False
          , grounding = None Text
          , enabledBy = None Text
          }
    , memory =
        { scope = A.MemoryScope.AgentScope
        , recallLimit = 0
        , recordPolicy = A.RecordPolicy.OnSuccess
        }
    }
