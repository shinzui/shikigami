let A = ../../../../schema/Agent.dhall

in  A.Agent::{
    , name = "invalid-capability-id"
    , trigger = A.Trigger.Event { eventType = "test.invalid" }
    , behavior = A.Behavior.Skill { path = "agents/skills/triage-note" }
    , capabilityOverlays = [ "Workspace.read" ]
    }
