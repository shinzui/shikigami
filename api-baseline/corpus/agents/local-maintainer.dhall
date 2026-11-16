-- A routine maintenance agent for a repository on the operator's own machine.
-- Run it under the local-operator trust tier (docs/user/local-operator.md):
--
--   shikigami-agent-run --set trust.tier=local-operator \
--     --agent agents/local-maintainer.dhall --workspace mori://shinzui/fsrs-hs \
--     --payload '{"task":"Summarize what src/ implements."}'
let A = ../../../schema/Agent.dhall

in  A.Agent::{
    , name = "local-maintainer"
    , behavior = A.Behavior.Skill { path = "agents/skills/local-maintainer" }
    , trigger = A.Trigger.Event { eventType = "local.maintenance.requested" }
    , identity = Some { principal = "principal_local_maintainer" }
    , capabilityOverlays =
      [ "workspace.read", "workspace.edit", "workspace.exec", "workspace.git" ]
    }
