-- Reports one repository's Mori registration, unfinished plans and Git state
-- using only the tools it declares (EP-3 of MasterPlan 22): two CLI tools and
-- two approved tools of the MCP server "git" bound in the operator's
-- tools.dhall. Run it under the
-- local-operator trust tier; the first run asks once and lists the tools:
--
--   shikigami-agent-run --set trust.tier=local-operator \
--     --agent agents/repo-inventory.dhall --workspace mori://shinzui/keiro \
--     --payload '{"repository":"shinzui/keiro"}'
let A = ../schema/Agent.dhall

in  A.Agent::{
    , name = "repo-inventory"
    , behavior = A.Behavior.Skill { path = "agents/skills/repo-inventory" }
    , trigger = A.Trigger.Event { eventType = "repository.inventory.requested" }
    , identity = Some { principal = "principal_repo_inventory" }
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
      , A.Tool.CliTool
          A.CliTool::{
          , name = "mina"
          , executable = A.ExecutableRef.OnPath "mina"
          , allow =
            [ A.pattern [ "docket", "status" ] A.Trailing.NoTrailing
            , A.pattern [ "exec-plan", "remaining" ] A.Trailing.AnyTrailing
            ]
          }
      , A.Tool.McpTools { server = "git", tools = [ "git_status", "git_log" ] }
      ]
    }
