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
      , [ "watchdog" ]
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
            , hash = "sha256:3f2b4809a5c20e4464c746c33c3c7900ab835609d99c6c59c8e78b6c3c309dcb"
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
    ]
