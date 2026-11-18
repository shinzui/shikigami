-- A tool ceiling (docs/user/declared-tools.md, "An optional ceiling").
let A = ../../../schema/Agent.dhall

let T = ../../../schema/Tools.dhall

in  T.Catalog::{
    , cli =
      [ { name = "mori"
        , executable = A.ExecutableRef.OnPath "mori"
        , allow = [ A.pattern [ "path" ] A.Trailing.AnyTrailing ]
        , maximumOperationClass = A.OperationClass.Observation
        }
      ]
    }
