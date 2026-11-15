-- A coding agent that improves one thing in a repository on the operator's
-- own machine. Run it under the local-operator trust tier:
--
--   shikigami-agent-run --set trust.tier=local-operator \
--     --agent agents/coding-agent-example.dhall --workspace mori://shinzui/mina
let A = ../schema/Agent.dhall

in  A.Agent::{
    , name = "haddock-gaps"
    , behavior =
        A.Behavior.CodingAgent
          { provider = A.CodingAgentProvider.ClaudeCode
          , prompt =
              "Find one exported function in src/ without a Haddock comment and add an accurate one. Change nothing else."
          , access = A.WorkspaceAccess.EditWorkspace
          , model = None Text
          , effort = None A.CodingAgentEffort
          , deadlineMinutes = 20
          , skills = [] : List Text
          }
    , trigger = A.Trigger.Event { eventType = "operator.request" }
    }
