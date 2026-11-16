-- Improve one thing per repository and learn from each (EP-4 M3 of
-- MasterPlan 22). After each repository a read-only Reflect step records
-- learnings, which the next repository's prompt quotes through
-- {{learnings}}, and may suggest a change to this file; the run proposes it
-- on its branch of this repository when it ends.
--
--   payload: { "repositories": ["mori://shinzui/fsrs-hs", "mori://shinzui/mina"], "focus": "an exported function without a Haddock comment" }
let P = ../../schema/Playbook.dhall

in  { main = "learning-review"
    , playbooks =
      [ { name = "learning-review"
        , steps =
          [ P.Step.ForEach
              { id = "each-repository"
              , items = P.Items.FromPayload "repositories"
              , item = "repository"
              , playbook = "improve-and-learn"
              }
          ]
        }
      , { name = "improve-and-learn"
        , steps =
          [ P.Step.CodingAgent
              { id = "improve"
              , prompt =
                  ''
                  This worktree is {{repository}}. Fix exactly one instance of: {{run.focus}}.
                  Add a short, accurate Haddock comment; change nothing else and do not build.

                  {{learnings}}
                  ''
              , workspace = "{{repository}}"
              , deadlineMinutes = 20
              , skills = [] : List Text
              }
          , P.Step.Reflect
              { id = "reflect"
              , prompt =
                  ''
                  The previous step added one Haddock comment in {{repository}} (see the latest commit).
                  What should the same step do differently or keep doing in the next Haskell repository?
                  If the step's prompt in the playbook should say something it does not, suggest it.
                  ''
              , workspace = "{{repository}}"
              }
          ]
        }
      ]
    }
    : P.Bundle
