{- The inventory of Shikigami's public surfaces.

   An owning plan adds its entry here, in report mode, in the commit that ships
   its surface. `just api-baseline` checks every entry against its pin, and
   `just api-baseline-pin <name>` re-pins one after a deliberate, reviewed
   change. A freeze sets `stability` and turns `enforcement` to Enforce.

   Policy: docs/architecture/api-baseline.md
-}
let S = ./Surface.dhall

let masterPlan =
      "docs/masterplans/22-rebuild-shikigami-as-a-kernel-where-use-cases-are-declared-not-coded.md"

let packPlan =
      "docs/plans/130-move-the-extension-boundary-out-of-shikigami-core-with-flow-packs-and-an-architecture-fitness-check.md"

let portsPlan =
      "docs/plans/133-give-the-kernel-its-own-action-record-output-approval-and-trigger-contracts-with-local-adapters.md"

let bindingPlan =
      "docs/plans/135-move-the-kikan-service-bindings-out-of-shikigami-core-and-compose-a-kikan-distribution.md"

let baselinePlan =
      "docs/plans/136-freeze-the-v1-api-baseline-with-a-surface-inventory-and-compatibility-checks.md"

let adminVerbs =
      [ [] : List Text
      , [ "validate" ]
      , [ "render-lifecycle" ]
      , [ "flows" ]
      , [ "enqueue-run" ]
      , [ "resolve-approval" ]
      , [ "grants" ]
      , [ "agents" ]
      , [ "runs" ]
      , [ "runs", "show" ]
      , [ "resources" ]
      , [ "executions" ]
      , [ "workers" ]
      , [ "objectives" ]
      , [ "mandates" ]
      , [ "record" ]
      , [ "record", "list" ]
      ]

in  [ { name = "agent-declaration"
      , owner = masterPlan
      , stability = S.Stability.Provisional
      , rule =
          "Every declaration in the corpus keeps loading to the same value; a new field has a default."
      , check =
          S.Check.DhallSchema
            { schema = "schema/Agent.dhall"
            , hash = "sha256:55f88d2c3b6af71d5a4e002f4d6217f138306702cbc9b38709b9b8b8b28e6058"
            , corpus = "api-baseline/corpus/agents"
            }
      , freeze = S.Freeze.Declaration
      , enforcement = S.Enforcement.Report
      }
    , { name = "agent-journal-codec"
      , owner = masterPlan
      , stability = S.Stability.Provisional
      , rule =
          "A journaled declaration keeps decoding to the value its Dhall file loads to."
      , check =
          S.Check.JournalCodec
            { corpus = "api-baseline/corpus/agents"
            , goldens = "api-baseline/goldens/agents"
            }
      , freeze = S.Freeze.Declaration
      , enforcement = S.Enforcement.Report
      }
    , { name = "cli-shikigami-agent-run"
      , owner = baselinePlan
      , stability = S.Stability.Provisional
      , rule =
          "An option or command that existed keeps its name and meaning; new ones may be added."
      , check =
          S.Check.CliHelp
            { executable = "shikigami-agent-run"
            , verbs = [ [] : List Text ]
            , goldens = "api-baseline/goldens/cli"
            }
      , freeze = S.Freeze.Declaration
      , enforcement = S.Enforcement.Report
      }
    , { name = "http-api"
      , owner = baselinePlan
      , stability = S.Stability.Provisional
      , rule =
          "No path, operation, response status, response property or response enumeration value is removed; no property changes type; no request property becomes required."
      , check =
          S.Check.OpenApi
            { current = "docs/api/openapi.json"
            , frozen = "api-baseline/frozen/openapi.json"
            }
      , freeze = S.Freeze.Kernel
      , enforcement = S.Enforcement.Report
      }
    , { name = "durable-wire"
      , owner = baselinePlan
      , stability = S.Stability.Provisional
      , rule =
          "A workflow body, event or stored value changes only as docs/workflow-versioning.md allows."
      , check = S.Check.KeiroGate { since = "HEAD" }
      , freeze = S.Freeze.Kernel
      , enforcement = S.Enforcement.Report
      }
    , { name = "cli-shikigami"
      , owner = baselinePlan
      , stability = S.Stability.Provisional
      , rule =
          "An option or command that existed keeps its name and meaning; new ones may be added."
      , check =
          S.Check.CliHelp
            { executable = "shikigami"
            , verbs = adminVerbs
            , goldens = "api-baseline/goldens/cli"
            }
      , freeze = S.Freeze.Kernel
      , enforcement = S.Enforcement.Report
      }
    , { name = "flow-sdk"
      , owner = packPlan
      , stability = S.Stability.Provisional
      , rule =
          "A name a flow body or a pack value can import stays exported with the same meaning; new names may be added."
      , check =
          S.Check.ExportList
            { component = "shikigami-core"
            , modules =
              [ "Shikigami.Agent.Delegate"
              , "Shikigami.Agent.Name"
              , "Shikigami.Decision.Contract"
              , "Shikigami.Flow.Decision"
              , "Shikigami.Flow.Delegate"
              , "Shikigami.Flow.Objectives"
              , "Shikigami.Flow.Sdk"
              , "Shikigami.Flow.Sdk.Program"
              , "Shikigami.Objective.Command"
              , "Shikigami.Objective.Operation"
              , "Shikigami.Objective.Types"
              , "Shikigami.Program.Decision"
              , "Shikigami.Program.Decision.Confidence"
              , "Shikigami.Router.Decision"
              ]
            , pinned = "api-baseline/goldens/exports/flow-sdk.txt"
            }
      , freeze = S.Freeze.Kernel
      , enforcement = S.Enforcement.Report
      }
    , { name = "pack-sdk"
      , owner = packPlan
      , stability = S.Stability.Provisional
      , rule =
          "A name a pack interpreter can import stays exported with the same meaning; new names may be added."
      , check =
          S.Check.ExportList
            { component = "shikigami-core"
            , modules = [ "Shikigami.Pack.Sdk" ]
            , pinned = "api-baseline/goldens/exports/pack-sdk.txt"
            }
      , freeze = S.Freeze.Kernel
      , enforcement = S.Enforcement.Report
      }
    , { name = "kernel-ports"
      , owner = portsPlan
      , stability = S.Stability.Provisional
      , rule =
          "A port type, constructor or function an adapter can name stays exported with the same meaning; new ones may be added."
      , check =
          S.Check.ExportList
            { component = "shikigami-core"
            , modules =
              [ "Shikigami.Approval.Channel"
              , "Shikigami.Authority"
              , "Shikigami.Authority.Adapter"
              , "Shikigami.Output"
              , "Shikigami.Output.Registration"
              , "Shikigami.Record"
              ]
            , pinned = "api-baseline/goldens/exports/kernel-ports.txt"
            }
      , freeze = S.Freeze.Kernel
      , enforcement = S.Enforcement.Report
      }
    , { name = "pack-service-ports"
      , owner = bindingPlan
      , stability = S.Stability.Provisional
      , rule =
          "A tracker-provider or conversation-channel name a pack can implement stays exported with the same meaning; new ones may be added."
      , check =
          S.Check.ExportList
            { component = "shikigami-core"
            , modules =
              [ "Shikigami.Agent.Conversation.Channel"
              , "Shikigami.Objective.Tracker.Provider"
              ]
            , pinned = "api-baseline/goldens/exports/pack-service-ports.txt"
            }
      , freeze = S.Freeze.Kernel
      , enforcement = S.Enforcement.Report
      }
    , { name = "kikan-output-helpers"
      , owner = bindingPlan
      , stability = S.Stability.Provisional
      , rule =
          "A typed Kikan output configuration or helper a flow body can import stays exported with the same meaning; new ones may be added."
      , check =
          S.Check.ExportList
            { component = "kikan-shikigami-binding:outputs"
            , modules = [ "Kikan.Shikigami.Binding.Outputs" ]
            , pinned = "api-baseline/goldens/exports/kikan-output-helpers.txt"
            }
      , freeze = S.Freeze.Kernel
      , enforcement = S.Enforcement.Report
      }
    , { name = "kikan-output-dhall"
      , owner = bindingPlan
      , stability = S.Stability.Provisional
      , rule =
          "A declaration that builds a Kikan output with the binding's Dhall helpers keeps loading; new helpers may be added."
      , check =
          S.Check.DhallSchema
            { schema = "packs/kikan-shikigami-binding/dhall/Outputs.dhall"
            , hash = "sha256:6595877baa3b7cb0e96ae9731e6db610eef3bdfcf5522b952af432a63b0d020f"
            , corpus = "api-baseline/corpus/kikan"
            }
      , freeze = S.Freeze.Kernel
      , enforcement = S.Enforcement.Report
      }
    , { name = "pack-declaration-codec"
      , owner = masterPlan
      , stability = S.Stability.Provisional
      , rule =
          "A journaled declaration that runs a pack's flow keeps decoding to the value its Dhall file loads to."
      , check =
          S.Check.JournalCodec
            { corpus = "api-baseline/corpus/packs"
            , goldens = "api-baseline/goldens/packs"
            }
      , freeze = S.Freeze.Kernel
      , enforcement = S.Enforcement.Report
      }
    , { name = "core-exposed-modules"
      , owner = baselinePlan
      , stability = S.Stability.Provisional
      , rule =
          "A module the core's main library exposes stays exposed; exposing another is a reviewed change."
      , check =
          S.Check.ExposedSet
            { cabal = "shikigami-core/shikigami-core.cabal"
            , pinned = "api-baseline/goldens/exposed/shikigami-core.txt"
            }
      , freeze = S.Freeze.Kernel
      , enforcement = S.Enforcement.Report
      }
    ]
