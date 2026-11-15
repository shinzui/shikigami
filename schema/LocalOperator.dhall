-- schema/LocalOperator.dhall — the explicit form of what a local operator
-- grants under the LocalOperator trust tier (EP-1 of MasterPlan 22, ADR-124).
--
-- The file is optional. A routine agent is granted by confirming it once in a
-- terminal; this file is for operators who prefer to write the grant, and it
-- is the only place a workspace.exec command rule is approved. An entry for an
-- agent and a repository replaces the confirmation for that pair.
--
-- Default location: $XDG_CONFIG_HOME/shikigami/local-operator.dhall
--
--   let L = /path/to/shikigami/schema/LocalOperator.dhall
--   in  L.Approvals::{
--       , repositories = [ L.Repository::{ identity = "mori://shinzui/fsrs-hs" } ]
--       , agents =
--         [ L.AgentApproval::{
--           , agent = "local-maintainer"
--           , repository = "mori://shinzui/fsrs-hs"
--           , capabilities = [ "workspace.read" ]
--           }
--         ]
--       }

-- Where a run works in an approved repository. SeparateWorktree gives each
-- run its own worktree on a run branch; InPlace works in the checkout on its
-- current branch and is for repositories nobody else is working in.
let Placement = < SeparateWorktree | InPlace >

-- One approved command line for workspace.exec. argv[0] is resolved with
-- PATH when it is not absolute. Only the environment names in `inherit` are
-- passed beyond PATH, HOME, USER, LOGNAME, TMPDIR, LANG and LC_ALL.
let Rule =
      { Type =
          { name : Text
          , argv : List Text
          , inherit : List Text
          , timeoutSeconds : Natural
          , outputBytes : Natural
          }
      , default =
        { inherit = [] : List Text, timeoutSeconds = 600, outputBytes = 65536 }
      }

let Budget =
      { Type =
          { modelAttempts : Natural
          , toolAttempts : Natural
          , tokens : Natural
          , minutes : Natural
          }
      , default =
        { modelAttempts = 30, toolAttempts = 120, tokens = 3000000, minutes = 60 }
      }

-- A repository the operator approves. `source` defaults to `mori path` of
-- the identity; `base` is the commit a run branch starts from.
let Repository =
      { Type =
          { identity : Text
          , source : Optional Text
          , base : Text
          , placement : Placement
          }
      , default =
        { source = None Text, base = "HEAD", placement = Placement.SeparateWorktree }
      }

let AgentApproval =
      { Type =
          { agent : Text
          , repository : Text
          , capabilities : List Text
          , rules : List Rule.Type
          , budget : Optional Budget.Type
          }
      , default =
        { capabilities = [] : List Text
        , rules = [] : List Rule.Type
        , budget = None Budget.Type
        }
      }

let Approvals =
      { Type =
          { repositories : List Repository.Type
          , agents : List AgentApproval.Type
          }
      , default =
        { repositories = [] : List Repository.Type
        , agents = [] : List AgentApproval.Type
        }
      }

in  { Placement, Rule, Budget, Repository, AgentApproval, Approvals }
