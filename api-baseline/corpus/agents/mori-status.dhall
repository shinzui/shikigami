-- The declaration that runs agents/playbooks/mori-status.dhall: one declared
-- tool, `mori status`, and nothing else.
--
--   shikigami-agent-run --set trust.tier=local-operator \
--     --agent agents/playbooks/mori-status-agent.dhall --workspace mori://shinzui/kanmon
let A = ../../../schema/Agent.dhall

in  A.Agent::{
    , name = "mori-status"
    , behavior =
        A.Behavior.Playbook
          { bundle = "mori-status/mori-status.dhall"
          , provider = A.CodingAgentProvider.ClaudeCode
          , access = A.WorkspaceAccess.ReadOnly
          , model = None Text
          , effort = None A.CodingAgentEffort
          }
    , identity = Some { principal = "principal_mori_status" }
    , tools =
      [ A.Tool.CliTool
          A.CliTool::{
          , name = "mori"
          , executable = A.ExecutableRef.OnPath "mori"
          , allow = [ A.pattern [ "status" ] A.Trailing.AnyTrailing ]
          , operationClass = A.OperationClass.Observation
          }
      ]
    }
