-- An approvals file that pre-approves one agent on one repository with a
-- budget (docs/user/local-operator.md, "The explicit approvals file").
let L = ../../../schema/LocalOperator.dhall

in  L.Approvals::{
    , repositories = [ L.Repository::{ identity = "mori://shinzui/fsrs-hs" } ]
    , agents =
      [ L.AgentApproval::{
        , agent = "local-maintainer"
        , repository = "mori://shinzui/fsrs-hs"
        , capabilities = [ "workspace.read" ]
        , budget = Some L.Budget::{ minutes = 30 }
        }
      ]
    }
