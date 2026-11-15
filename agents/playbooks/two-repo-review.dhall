-- Review two repositories in turn (EP-4 of MasterPlan 22): for each
-- repository in the run's payload, a coding agent improves one thing, and the
-- operator approves before the next repository starts.
--
--   payload: { "repositories": ["mori://shinzui/fsrs-hs", "mori://shinzui/mina"], "focus": "Haddock gaps" }
let P = ../../schema/Playbook.dhall

in  { main = "two-repo-review"
    , playbooks =
      [ { name = "two-repo-review"
        , steps =
          [ P.Step.ForEach
              { id = "each-repository"
              , items = P.Items.FromPayload "repositories"
              , item = "repository"
              , playbook = "review-one"
              }
          ]
        }
      , { name = "review-one"
        , steps =
          [ P.Step.CodingAgent
              { id = "improve"
              , prompt = "In {{repository}}, address one instance of: {{run.focus}}. Change nothing else."
              , workspace = "{{repository}}"
              , deadlineMinutes = 20
              }
          , P.approval "continue" "Continue after reviewing the change in {{repository}}?"
          ]
        }
      ]
    }
    : P.Bundle
