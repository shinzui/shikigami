-- The declaration that runs agents/playbooks/package-paths.dhall (EP-4 M4 of
-- MasterPlan 22): two declared mori commands, run as durable steps.
--
--   shikigami-agent-run --set trust.tier=local-operator \
--     --agent agents/playbooks/package-paths-agent.dhall --workspace mori://shinzui/mina \
--     --payload '{"project":"shinzui/mina"}'
let A = ../../schema/Agent.dhall

in  A.Agent::{
    , name = "package-paths"
    , behavior =
        A.Behavior.Playbook
          { bundle = "package-paths.dhall"
          , provider = A.CodingAgentProvider.ClaudeCode
          , access = A.WorkspaceAccess.ReadOnly
          , model = None Text
          , effort = None A.CodingAgentEffort
          }
    , tools =
      [ A.Tool.CliTool
          A.CliTool::{
          , name = "mori"
          , executable = A.ExecutableRef.OnPath "mori"
          , allow =
            [ A.pattern [ "registry", "show" ] A.Trailing.AnyTrailing
            , A.pattern [ "path" ] A.Trailing.AnyTrailing
            ]
          }
      ]
    }
