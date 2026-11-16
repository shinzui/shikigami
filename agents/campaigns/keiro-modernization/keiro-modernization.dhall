-- The keiro modernization campaign's declaration (EP-7 of MasterPlan 22).
-- Each repository is granted once, with the placement the operator's
-- approvals file chooses (in-place for the campaign repositories).
--
--   shikigami-agent-run --set trust.tier=local-operator \
--     --agent agents/campaigns/keiro-modernization/keiro-modernization.dhall \
--     --workspace mori://shinzui/kanmon --payload '{"repos":["mori://shinzui/kanmon"]}'
let A = ../../../schema/Agent.dhall

in  A.Agent::{
    , name = "keiro-modernization"
    , identity = Some { principal = "principal_keiro_modernization" }
    , behavior =
        A.Behavior.Playbook
          { bundle = "playbook.dhall"
          , provider = A.CodingAgentProvider.ClaudeCode
          , access = A.WorkspaceAccess.EditWorkspace
          , model = None Text
          , effort = None A.CodingAgentEffort
          }
    , tools = ./tools.dhall
    }
