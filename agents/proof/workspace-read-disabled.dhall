let A = ../../schema/Agent.dhall

in  A.Agent::{
    , name = "workspace-read-disabled"
    , description = "Proof agent: same Skill without the workspace overlay"
    , behavior = A.Behavior.Skill { path = "agents/skills/triage-note" }
    , trigger = A.Trigger.Event { eventType = "proof.workspace-read-disabled" }
    , identity = Some { principal = "principal_workspace_read_proof" }
    }
