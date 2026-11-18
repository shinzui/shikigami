-- The campaign's declared CLI tools (EP-7 of MasterPlan 22). Tool steps run
-- them as durable steps; coding agents may run them through the gate, and
-- nothing else from a shell.
let A = ../../../../schema/Agent.dhall

let Blueprint = { name : Text, kind : Text, source : Text, rule : Text }

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

-- seihou agent run|migrate admits only the catalog's blueprints.
let blueprintPatterns =
      List/fold
        Blueprint
        ./blueprints.dhall
        (List A.ArgumentPattern)
        ( \(blueprint : Blueprint) ->
          \(rest : List A.ArgumentPattern) ->
              [ any [ "agent", blueprint.kind, blueprint.name ]
              , any [ "agent", "--debug", blueprint.kind, blueprint.name ]
              ]
            # rest
        )
        ([] : List A.ArgumentPattern)

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
    , tool
        "mina"
        A.OperationClass.Observation
        [ any [ "config", "show" ], any [ "ci" ] ]
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
        (   blueprintPatterns
          # [ any [ "status" ]
            , any [ "outdated" ]
            , any [ "update" ]
            , any [ "sync" ]
            , any [ "manifest", "upgrade" ]
            , any [ "list" ]
            ]
        )
    , tool
        "nix"
        A.OperationClass.IdempotentMutation
        [ any [ "develop", "-c", "cabal" ], any [ "develop", "-c", "just" ] ]
    , tool
        "cabal"
        A.OperationClass.IdempotentMutation
        [ any [ "build" ], any [ "test" ] ]
    , tool "jq" A.OperationClass.Observation [ any ([] : List Text) ]
    , tool
        "bun"
        A.OperationClass.IdempotentMutation
        [ any [ "agents/skills/exec-plan/record-friction.ts" ]
        , any [ "agents/skills/exec-plan/init-plan.ts" ]
        , any [ "agents/skills/exec-plan/record-provenance.ts" ]
        , any [ "agents/skills/master-plan/init-masterplan.ts" ]
        ]
    ]
