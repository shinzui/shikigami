let A = ../../schema/Agent.dhall
in  A.Agent::{
    , name = "research-supervisor"
    , behavior =
        A.Behavior.ShikumiProgram
          { task = "research-supervisor"
          , preferEnrichment = False
          , grounding = None Text
          }
    , trigger = A.Trigger.Event { eventType = "proof.research" }
    , delegates = [ "web-researcher", "code-researcher" ]
    , delegationBudget = Some 8
    }
