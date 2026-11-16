-- Validates the tail of a campaign playbook (plan 132): a failing build probe,
-- a fix-build coding agent that quotes it, a final build that must pass, a
-- tests probe that reports a failure without ending the run, a close approval
-- and Reflect. A second run recalls the first run's learnings.
--
--   payload: { "instruction": "..." }
let P = ../../schema/Playbook.dhall

in  { main = "build-repair"
    , playbooks =
      [ { name = "build-repair"
        , steps =
          [ P.Step.Probe { id = "build", tool = "cabal", args = [ "build", "all" ], deadlineMinutes = 10 }
          , P.Step.CodingAgent
              { id = "fix-build"
              , prompt =
                  ''
                  The build of this repository reports:

                  {{steps.build.output}}

                  {{run.instruction}}

                  {{learnings}}
                  ''
              , workspace = ""
              , deadlineMinutes = 15
              , skills = [] : List Text
              }
          , P.Step.Tool { id = "final-build", tool = "cabal", args = [ "build", "all" ], deadlineMinutes = 10 }
          , P.Step.Probe { id = "tests", tool = "cabal", args = [ "test", "all" ], deadlineMinutes = 10 }
          , P.Step.Approval
              { id = "close"
              , prompt =
                  ''
                  The build passes. The tests report:

                  {{steps.tests.output}}
                  ''
              }
          , P.Step.Reflect
              { id = "reflect"
              , prompt =
                  ''
                  The fix-build step repaired a compile error (see the latest commit), and the tests then reported:

                  {{steps.tests.output}}

                  What should the fix-build step do differently next time in a repository like this one?
                  ''
              , workspace = ""
              }
          ]
        }
      ]
    }
    : P.Bundle
