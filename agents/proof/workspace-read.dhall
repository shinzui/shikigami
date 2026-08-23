let A = ../../schema/Agent.dhall

in  A.Agent::{
    , name = "workspace-read"
    , description = "Proof agent: reads a bounded Git worktree through an operator-owned overlay"
    , behavior = A.Behavior.Skill { path = "agents/skills/triage-note" }
    , trigger = A.Trigger.Event { eventType = "proof.workspace-read" }
    , capabilityOverlays = [ "workspace.read" ]
    , identity = Some { principal = "principal_workspace_read_proof" }
    }
