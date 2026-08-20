let A = ../../../../schema/Agent.dhall

in  A.Agent::{
    , name = "invalid-recall-limit-too-large"
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
        , recallLimit = 1001
        , recordPolicy = A.RecordPolicy.OnSuccess
        }
    }
