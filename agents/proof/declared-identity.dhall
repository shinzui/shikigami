let A = ../../schema/Agent.dhall

in  A.Agent::{
    , name = "declared-identity"
    , description = "Proof agent: exercises identity, memory policy, and enablement"
    , behavior =
        A.Behavior.ShikumiProgram
          { task = "noop-summary"
          , preferEnrichment = False
          , grounding = None Text
          , enabledBy = None Text
          }
    , trigger = A.Trigger.Event { eventType = "proof.identity" }
    , identity = Some { principal = "principal_shikigami_proof" }
    , memory =
        { scope = A.MemoryScope.AgentScope
        , recallLimit = 3
        , recordPolicy = A.RecordPolicy.Never
        }
    , enabled = False
    }
