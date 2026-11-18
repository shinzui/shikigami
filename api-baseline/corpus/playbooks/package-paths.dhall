-- Fan out over what a declared tool returns (EP-4 M4 of MasterPlan 22): the
-- packages Mori registers for a project, and each package's path. Items from
-- step output are observed values: they may be tool arguments and prompt
-- text, never a workspace.
--
--   payload: { "project": "shinzui/mina" }
let P = ../../../schema/Playbook.dhall

in  { main = "package-paths"
    , playbooks =
      [ { name = "package-paths"
        , steps =
          [ P.Step.Tool
              { id = "packages"
              , tool = "mori"
              , args = [ "registry", "show", "{{run.project}}", "--full", "--json" ]
              , deadlineMinutes = 1
              }
          , P.Step.ForEach
              { id = "each-package"
              , items =
                  P.Items.FromStep { step = "packages", at = "/packages", key = "name" }
              , item = "package"
              , playbook = "locate"
              }
          ]
        }
      , { name = "locate"
        , steps =
          [ P.Step.Tool
              { id = "path"
              , tool = "mori"
              , args = [ "path", "mori://{{run.project}}/packages/{{package}}" ]
              , deadlineMinutes = 1
              }
          ]
        }
      ]
    }
    : P.Bundle
