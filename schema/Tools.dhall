-- The operator's tools file, $XDG_CONFIG_HOME/shikigami/tools.dhall (EP-3 of
-- MasterPlan 22). Optional: a declared CLI tool runs on the operator's grant
-- of the declaration. A ceiling of the same name bounds the declaration.
let A = ./Agent.dhall

let CliToolCeiling =
      { name : Text
      , executable : A.ExecutableRef
      , allow : List A.ArgumentPattern
      , maximumOperationClass : A.OperationClass
      }

let Catalog =
      { Type = { cli : List CliToolCeiling }, default.cli = [] : List CliToolCeiling }

in  { CliToolCeiling, Catalog }
