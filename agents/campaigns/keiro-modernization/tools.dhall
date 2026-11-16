-- The campaign's declared CLI tools (EP-7 of MasterPlan 22). Tool steps run
-- them as durable steps; coding agents may run them through the gate, and
-- nothing else from a shell.
let A = ../../../schema/Agent.dhall

let tool =
      \(name : Text) ->
      \(operationClass : A.OperationClass) ->
      \(allow : List A.ArgumentPattern) ->
        A.Tool.CliTool
          A.CliTool::{
          , name
          , executable = A.ExecutableRef.OnPath name
          , allow
          , operationClass
          }

let any = \(words : List Text) -> A.pattern words A.Trailing.AnyTrailing

in  [ tool
        "git"
        A.OperationClass.Observation
        [ any [ "rev-parse" ]
        , any [ "status" ]
        , any [ "log" ]
        , any [ "diff" ]
        , any [ "show" ]
        , any [ "grep" ]
        ]
    , tool "mina" A.OperationClass.Observation [ any [ "config", "show" ], any [ "ci" ] ]
    , tool
        "mori"
        A.OperationClass.IdempotentMutation
        [ any [ "status" ]
        , any [ "schema", "upgrade" ]
        , any [ "register" ]
        , any [ "registry", "show" ]
        , any [ "path" ]
        ]
    , tool
        "seihou"
        A.OperationClass.IdempotentMutation
        [ any [ "status" ]
        , any [ "outdated" ]
        , any [ "update" ]
        , any [ "sync" ]
        , any [ "manifest", "upgrade" ]
        , any [ "list" ]
        ]
    , tool "nix" A.OperationClass.IdempotentMutation [ any [ "develop", "-c", "cabal" ] ]
    , tool "cabal" A.OperationClass.IdempotentMutation [ any [ "build" ] ]
    , tool "jq" A.OperationClass.Observation [ any ([] : List Text) ]
    , tool
        "bun"
        A.OperationClass.IdempotentMutation
        [ any [ "agents/skills/exec-plan/record-friction.ts", "init" ] ]
    ]
