-- The declaration that runs agents/playbooks/build-repair.dhall, the quick check
-- of a campaign's tail (plan 132). Point it at a small Cabal package whose build
-- is broken and whose tests then fail, and run it twice: the second run's
-- fix-build prompt must quote the first run's learnings.
--
--   shikigami-agent-run --set trust.tier=local-operator \
--     --agent agents/playbooks/build-repair-agent.dhall --workspace PATH-TO-FIXTURE \
--     --payload '{"instruction":"Fix the compile error with the smallest change. Do not edit the tests."}'
--
-- The second run's instruction can ask for no change, to see a failed final
-- build end the run.
let A = ../../schema/Agent.dhall

in  A.Agent::{
    , name = "build-repair"
    , behavior =
        A.Behavior.Playbook
          { bundle = "build-repair.dhall"
          , provider = A.CodingAgentProvider.ClaudeCode
          , access = A.WorkspaceAccess.EditWorkspace
          , model = None Text
          , effort = None A.CodingAgentEffort
          }
    , identity = Some { principal = "principal_build_repair" }
    , tools =
      [ A.Tool.CliTool
          A.CliTool::{
          , name = "cabal"
          , executable = A.ExecutableRef.OnPath "cabal"
          , allow =
            [ A.pattern [ "build" ] A.Trailing.AnyTrailing
            , A.pattern [ "test" ] A.Trailing.AnyTrailing
            ]
          }
      ]
    }
