let A = ../../schema/Agent.dhall

in  A.Agent::{
    , name = "capability-overlay"
    , description = "Proof agent: requests an operator-resolved workspace reader"
    , behavior = A.Behavior.Skill { path = "agents/skills/triage-note" }
    , trigger = A.Trigger.Event { eventType = "proof.capability-overlay" }
    , capabilityOverlays = [ "workspace.read" ]
    }
