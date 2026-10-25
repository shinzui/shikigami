let A = ../../schema/Agent.dhall

in  A.Agent::{
    , name = "shikumi-decision-example"
    , description = "Triage and investigate with separately authorized typed programs"
    , behavior = A.Behavior.Flow { name = "shikumi-decision-example" }
    , trigger = A.Trigger.Event { eventType = "proof.shikumi-decision" }
    , decisionModels = [ "triage", "investigate" ]
    , delegates = [ "opentelemetry-practice-reviewer", "code-researcher" ]
    , delegationBudget = Some 4
    , routing = Some
      { maxSelections = 2
      , minimumConfidence = A.RouterConfidence.RoutingMedium
      , onNoMatch = A.NoMatchPolicy.ReturnNoMatch
      , onAmbiguous = A.AmbiguousPolicy.ReturnAmbiguous
      }
    }
