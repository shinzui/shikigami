let A = ../../schema/Agent.dhall

in  A.Agent::{
    , name = "shikumi-judgment-example"
    , description = "Judge the urgency, category and severity of a supplied ticket"
    , behavior = A.Behavior.Flow { name = "shikumi-judgment-example" }
    , trigger = A.Trigger.Event { eventType = "proof.shikumi-judgment" }
    , decisionModels = [ "judge" ]
    }
