-- The declaration that runs agents/playbooks/learning-review.dhall (EP-4 of
-- MasterPlan 22). Its coding-agent steps use Claude Code with edit access;
-- each repository named in the payload is granted once.
--
--   shikigami-agent-run --set trust.tier=local-operator \
--     --agent agents/playbooks/learning-review-agent.dhall --workspace mori://shinzui/fsrs-hs \
--     --payload '{"repositories":["mori://shinzui/fsrs-hs","mori://shinzui/mina"],"focus":"an exported function without a Haddock comment"}'
let A = ../../schema/Agent.dhall

in  A.Agent::{
    , name = "learning-review"
    , behavior =
        A.Behavior.Playbook
          { bundle = "learning-review.dhall"
          , provider = A.CodingAgentProvider.ClaudeCode
          , access = A.WorkspaceAccess.EditWorkspace
          , model = None Text
          , effort = None A.CodingAgentEffort
          }
    }
