-- Local-operator approvals (docs/user/local-operator.md).
-- The keiro modernization campaign works in place on each repository's current
-- branch (user decision, 2026-11-15; plan 132). No agent is pre-approved here:
-- each declaration is still confirmed once in a terminal.
let L = ../../../schema/LocalOperator.dhall

let inPlace =
      \(identity : Text) ->
        L.Repository::{ identity, placement = L.Placement.InPlace }

in  L.Approvals::{
    , repositories =
      [ inPlace "mori://shinzui/kizashi"
      , inPlace "mori://shinzui/koyomi"
      , inPlace "mori://shinzui/keiei"
      , inPlace "mori://shinzui/danwa"
      , inPlace "mori://shinzui/meibo"
      , inPlace "mori://shinzui/jinmyaku"
      ]
    }
