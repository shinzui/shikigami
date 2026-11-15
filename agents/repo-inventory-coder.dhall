-- The repo-inventory tools, given to Claude Code as a coding agent (EP-3 M3 of
-- MasterPlan 22). The agent runs its declared commands itself; a PreToolUse
-- hook (shikigami-local gate) allows exactly the declared tools and records
-- every decision. Its Baikai ceiling must allow provider arguments:
--
--   policy { allow-provider-args #true }   // ~/.config/baikai/agents.kdl
--
--   shikigami-agent-run --set trust.tier=local-operator \
--     --agent agents/repo-inventory-coder.dhall --workspace mori://shinzui/keiro
let A = ../schema/Agent.dhall

in  A.Agent::{
    , name = "repo-inventory-coder"
    , behavior =
        A.Behavior.CodingAgent
          { provider = A.CodingAgentProvider.ClaudeCode
          , prompt =
              ''
              Report on this repository using only your declared tools. Run
              `mori registry show shinzui/keiro` and call the git_status MCP tool
              with this worktree as repo_path. Then try `gh pr list` once and say
              whether it was allowed. Change no file.
              ''
          , access = A.WorkspaceAccess.EditWorkspace
          , model = None Text
          , effort = None A.CodingAgentEffort
          , deadlineMinutes = 10
          , skills = [] : List Text
          }
    , trigger = A.Trigger.Event { eventType = "repository.inventory.requested" }
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
      , A.Tool.McpTools { server = "git", tools = [ "git_status", "git_log" ] }
      ]
    }
