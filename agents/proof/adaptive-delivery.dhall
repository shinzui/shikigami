let A = ../../schema/Agent.dhall

in  A.Agent::{
    , name = "adaptive-delivery"
    , description = "Deliver one finite objective; adapt only to retained findings and require an exact combined artifact check"
    , behavior = A.Behavior.Flow { name = "adaptive-delivery" }
    , trigger = A.Trigger.Event { eventType = "proof.adaptive-delivery" }
    , decisionModels = [ "adaptive" ]
    , delegates = [ "opentelemetry-practice-reviewer", "code-researcher" ]
    , delegationBudget = Some 8
    }
