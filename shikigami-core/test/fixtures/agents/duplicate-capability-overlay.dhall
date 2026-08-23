let A = ../../../../schema/Agent.dhall

in  A.Agent::{
    , name = "duplicate-capability-overlay"
    , trigger = A.Trigger.Event { eventType = "test.duplicate" }
    , behavior = A.Behavior.Skill { path = "agents/skills/triage-note" }
    , capabilityOverlays = [ "workspace.read", "workspace.read" ]
    }
