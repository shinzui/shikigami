-- The campaign's earliest interaction check (plan 132, Validation and
-- Acceptance): one playbook with one Tool step, the declared `mori status --json`.
-- EP-11 M2 runs it on kanmon as evidence that the frozen declaration surface
-- still carries a real job.
let P = ../../../schema/Playbook.dhall

in  { main = "mori-status"
    , playbooks =
      [ { name = "mori-status"
        , steps =
          [ P.Step.Tool
              { id = "mori"
              , tool = "mori"
              , args = [ "status", "--json" ]
              , deadlineMinutes = 5
              }
          ]
        }
      ]
    }
    : P.Bundle
