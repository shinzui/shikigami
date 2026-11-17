-- | Each comparison rule on synthetic input, so a rule cannot pass vacuously
-- on a tree that happens to be clean.
module Main (main) where

import ApiBaseline.Check.CliHelp (cliHelpFindings, helpVocabulary)
import ApiBaseline.Check.DhallSchema (dhallSchemaFindings, excerpt)
import ApiBaseline.Check.ExportList (exportListFindings, parseInterfaceExports, parsePinned, renderPinned)
import ApiBaseline.Check.JournalCodec (encodeGolden, journalCodecFindings)
import ApiBaseline.Check.KeiroGate (keiroGateFindings)
import ApiBaseline.Check.KernelLabels (PackLabelInSpec (..), packLabels, packLabelsInSpecs, specLabels)
import ApiBaseline.Check.OpenApi (OpenApiChange (..), openApiChanges)
import ApiBaseline.Exposure (Exposure (..), exposureCounts, importedModules, parseExposedModules)
import ApiBaseline.Run (pinSurface)
import ApiBaseline.Types
import Data.Aeson (Value, object, (.=))
import Data.List.NonEmpty (NonEmpty ((:|)))
import Data.Map.Strict qualified as Map
import Data.Set qualified as Set
import Data.Text (Text)
import Data.Text qualified as Text
import Data.Text.IO qualified as TextIO
import System.Directory (createDirectoryIfMissing, doesFileExist, listDirectory, removeDirectoryRecursive)
import System.FilePath ((</>))
import Test.Tasty (TestTree, defaultMain, testGroup)
import Test.Tasty.HUnit (assertBool, testCase, (@?=))

main :: IO ()
main =
  defaultMain
    ( testGroup
        "api-baseline"
        [verdictTests, schemaTests, codecTests, openApiTests, cliTests, exportTests, gateTests, exposureTests, pinTests, labelTests]
    )

severities :: [Finding] -> [Severity]
severities = map (.severity)

verdictTests :: TestTree
verdictTests =
  testGroup
    "verdict"
    [ testCase "a report-only surface never fails, whatever it finds" do
        verdict Report [] @?= Clean
        verdict Report [breaking] @?= Drift (breaking :| [])
        verdict Report [changed, breaking] @?= Drift (changed :| [breaking]),
      testCase "an enforcing surface fails on any finding, additive ones included" do
        verdict Enforce [] @?= Clean
        verdict Enforce [changed] @?= Broken (changed :| [])
        verdict Enforce [breaking] @?= Broken (breaking :| []),
      testCase "a finding names its rule and the path for a deliberate change" do
        let rendered = renderFinding surface [breaking]
        mapM_
          (\needle -> assertBool (Text.unpack needle) (needle `Text.isInfixOf` rendered))
          ["agent-declaration (provisional): BREAKING", "Rule: keeps loading", "Decision Log", "just api-baseline-pin agent-declaration", "docs/architecture/api-baseline.md"]
        assertBool "a change is not called breaking" ("CHANGED" `Text.isInfixOf` renderFinding surface [changed])
        assertBool "a stable surface asks for an ADR" ("ADR" `Text.isInfixOf` renderFinding (surface {stability = Stable}) [breaking])
    ]
  where
    breaking = Finding Breaking "a corpus file no longer loads"
    changed = Finding Changed "the hash moved"
    surface =
      Surface
        { name = "agent-declaration",
          owner = "docs/plans/x.md",
          stability = Provisional,
          rule = "keeps loading",
          check = KeiroGate {since = "HEAD"},
          freeze = Declaration,
          enforcement = Report
        }

schemaTests :: TestTree
schemaTests =
  testGroup
    "dhall schema"
    [ testCase "an unchanged schema whose corpus loads is clean" do
        dhallSchemaFindings "schema/A.dhall" "sha256:aa" (Right "sha256:aa") [("corpus/one.dhall", Right ())] @?= [],
      testCase "a moved hash with a loading corpus is a change" do
        severities (dhallSchemaFindings "schema/A.dhall" "sha256:aa" (Right "sha256:bb") [("corpus/one.dhall", Right ())]) @?= [Changed],
      testCase "a corpus file that fails to load is breaking and is named" do
        let found = dhallSchemaFindings "schema/A.dhall" "sha256:aa" (Right "sha256:bb") [("corpus/one.dhall", Left "expected field delegationBudget"), ("corpus/two.dhall", Right ())]
        severities found @?= [Changed, Breaking]
        assertBool "names the file and the reason" (any (\finding -> "corpus/one.dhall no longer loads" `Text.isInfixOf` finding.detail && "delegationBudget" `Text.isInfixOf` finding.detail) found),
      testCase "a Dhall error is quoted without blank lines or colour codes" do
        excerpt "\n\ESC[1;31mError\ESC[0m: Expression doesn't match annotation\n\n{ - delegationLimit : …\n" @?= "Error: Expression doesn't match annotation\n{ - delegationLimit : …\n",
      testCase "a schema that no longer evaluates is breaking" do
        severities (dhallSchemaFindings "schema/A.dhall" "sha256:aa" (Left "parse error") []) @?= [Breaking]
    ]

codecTests :: TestTree
codecTests =
  testGroup
    "journal codec"
    [ testCase "the pinned bytes of an unchanged value are clean" do
        journalCodecFindings "one" sample (Just (encodeGolden sample)) @?= [],
      testCase "a golden that no longer decodes is breaking" do
        severities (journalCodecFindings "one" sample (Just "{\"not\":\"a pair\"}")) @?= [Breaking],
      testCase "a golden that decodes to another value is breaking" do
        severities (journalCodecFindings "one" sample (Just (encodeGolden (("other", 2) :: (Text, Int))))) @?= [Breaking],
      testCase "the same value in different bytes is a change" do
        severities (journalCodecFindings "one" sample (Just "[\"name\" , 1]")) @?= [Changed],
      testCase "a declaration with no golden is a change, not a clean result" do
        severities (journalCodecFindings "one" sample Nothing) @?= [Changed]
    ]
  where
    sample = ("name", 1) :: (Text, Int)

openApiTests :: TestTree
openApiTests =
  testGroup
    "openapi"
    [ testCase "identical documents have no change" do
        openApiChanges baseDocument baseDocument @?= [],
      testCase "a removed path" do
        openApiChanges baseDocument (document [] baseSchemas) @?= [PathRemoved "/runs"],
      testCase "a removed operation" do
        openApiChanges baseDocument (document [("/runs", [("get", getRuns ["200", "404"])])] baseSchemas) @?= [OperationRemoved "/runs" "post"],
      testCase "a removed response status" do
        openApiChanges baseDocument (document [("/runs", [("get", getRuns ["200"]), ("post", postRun)])] baseSchemas) @?= [ResponseStatusRemoved "/runs" "get" "404"],
      testCase "a property removed from a response schema" do
        openApiChanges baseDocument (withSchemas [("Run", schema [("id", "string")] [] ["queued", "done"]), requestSchema])
          @?= [ResponsePropertyRemoved "schema Run" "status"],
      testCase "a property whose type changed" do
        openApiChanges baseDocument (withSchemas [("Run", schema [("id", "integer"), ("status", "string")] [] ["queued", "done"]), requestSchema])
          @?= [PropertyTypeChanged "schema Run" "id" "string" "integer"],
      testCase "a request property that became required" do
        openApiChanges baseDocument (withSchemas [runSchema, ("NewRun", schema [("agent", "string"), ("note", "string")] ["agent", "note"] [])])
          @?= [RequestPropertyNowRequired "schema NewRun" "note"],
      testCase "an enumeration value removed from a response" do
        openApiChanges baseDocument (withSchemas [("Run", schema [("id", "string"), ("status", "string")] [] ["queued"]), requestSchema])
          @?= [ResponseEnumValueRemoved "schema Run" "done"],
      testCase "an added path, an added response property and a newly optional request property are compatible" do
        let extended =
              document
                [("/runs", [("get", getRuns ["200", "404"]), ("post", postRun)]), ("/health", [("get", getRuns ["200"])])]
                [("Run", schema [("id", "string"), ("status", "string"), ("startedAt", "string")] [] ["queued", "done", "failed"]), ("NewRun", schema [("agent", "string"), ("note", "string"), ("label", "string")] ["agent"] [])]
        openApiChanges baseDocument extended @?= [OtherDifference],
      testCase "a property removed from a request-only schema does not break a reader" do
        openApiChanges baseDocument (withSchemas [runSchema, ("NewRun", schema [("agent", "string")] ["agent"] [])]) @?= [OtherDifference]
    ]
  where
    baseSchemas = [runSchema, requestSchema]
    runSchema = ("Run", schema [("id", "string"), ("status", "string")] [] ["queued", "done"])
    requestSchema = ("NewRun", schema [("agent", "string"), ("note", "string")] ["agent"] [])
    baseDocument = withSchemas baseSchemas
    withSchemas = document [("/runs", [("get", getRuns ["200", "404"]), ("post", postRun)])]
    getRuns statuses = object ["responses" .= object [status .= response "Run" | status <- statuses]]
    postRun = object ["requestBody" .= response "NewRun", "responses" .= object ["201" .= response "Run"]]
    response :: Text -> Value
    response name = object ["content" .= object ["application/json" .= object ["schema" .= object ["$ref" .= ("#/components/schemas/" <> name)]]]]

document :: [(Text, [(Text, Value)])] -> [(Text, Value)] -> Value
document paths schemas =
  object
    [ "paths" .= Map.fromList [(path, Map.fromList operations) | (path, operations) <- paths],
      "components" .= object ["schemas" .= Map.fromList schemas]
    ]

schema :: [(Text, Text)] -> [Text] -> [Text] -> Value
schema properties required enumeration =
  object
    [ "type" .= ("object" :: Text),
      "properties" .= Map.fromList [(name, object ["type" .= kind]) | (name, kind) <- properties],
      "required" .= required,
      "enum" .= enumeration
    ]

cliTests :: TestTree
cliTests =
  testGroup
    "cli help"
    [ testCase "the vocabulary is the options and the listed commands" do
        helpVocabulary help @?= Set.fromList ["--agent", "--payload", "--resume", "-h", "--help", "show", "list"],
      testCase "identical text is clean" do
        cliHelpFindings "tool" ["runs"] (Just help) help @?= [],
      testCase "a removed option is breaking and is named" do
        let found = cliHelpFindings "tool" ["runs"] (Just help) (Text.replace "[--resume WORKFLOW_ID]" "" (Text.replace "  --resume WORKFLOW_ID     Continue a run\n" "" help))
        severities found @?= [Breaking]
        assertBool "names the option" (any (Text.isInfixOf "--resume" . (.detail)) found),
      testCase "a removed command is breaking" do
        severities (cliHelpFindings "tool" [] (Just help) (Text.replace "  list                     List runs\n" "" help)) @?= [Breaking],
      testCase "an added option and a reworded description are changes" do
        severities (cliHelpFindings "tool" [] (Just help) (help <> "  --verbose                Say more\n")) @?= [Changed]
        severities (cliHelpFindings "tool" [] (Just help) (Text.replace "Continue a run" "Continue an interrupted run" help)) @?= [Changed],
      testCase "an unpinned verb is a change" do
        severities (cliHelpFindings "tool" ["new"] Nothing help) @?= [Changed]
    ]
  where
    help =
      Text.unlines
        [ "Usage: tool runs --agent NAME|FILE [--payload JSON|-] [--resume WORKFLOW_ID]",
          "",
          "  Inspect runs",
          "",
          "Available options:",
          "  --agent NAME|FILE        Agent name or manifest path",
          "  --payload JSON|-         Trigger payload",
          "  --resume WORKFLOW_ID     Continue a run",
          "  -h,--help                Show this help text",
          "",
          "Available commands:",
          "  show                     Show one run",
          "  list                     List runs"
        ]

exportTests :: TestTree
exportTests =
  testGroup
    "export list"
    [ testCase "an interface's exports are read as unqualified names with their members" do
        parseInterfaceExports interface
          @?= Set.fromList ["kernelCapabilityFlow", ":>", "FlowPack", "FlowPack.flows", "FlowPack.name", "Ack", "Ack.Acknowledged", "Ack.TimedOut"],
      testCase "a removed export is breaking and an added one is a change" do
        severities (exportListFindings "M" (Set.fromList ["a", "b"]) (Set.fromList ["a", "b"])) @?= []
        severities (exportListFindings "M" (Set.fromList ["a", "b"]) (Set.fromList ["a"])) @?= [Breaking]
        severities (exportListFindings "M" (Set.fromList ["a"]) (Set.fromList ["a", "c"])) @?= [Changed]
        severities (exportListFindings "M" (Set.fromList ["a", "b"]) (Set.fromList ["a", "c"])) @?= [Breaking, Changed],
      testCase "a removed constructor is a removed export" do
        let narrowed = Set.delete "Ack.TimedOut" (parseInterfaceExports interface)
        severities (exportListFindings "M" (parseInterfaceExports interface) narrowed) @?= [Breaking],
      testCase "a pin file reads back what was written" do
        let pins = Map.fromList [("M.One", Set.fromList ["a", ":>"]), ("M.Two", Set.fromList ["T", "T.field"])]
        parsePinned (renderPinned pins) @?= pins
    ]
  where
    interface =
      Text.unlines
        [ "interface Shikigami.Flow.Sdk 9124",
          "exports:",
          "  Shikigami.Flow.Pack.kernelCapabilityFlow",
          "  Effectful.Internal.Effect.:>",
          "  Shikigami.Flow.Pack.FlowPack{Shikigami.Flow.Pack.FlowPack Shikigami.Flow.Pack.flows Shikigami.Flow.Pack.name}",
          "  Shikigami.Flow.Acknowledgement.Ack{Shikigami.Flow.Acknowledgement.Acknowledged Shikigami.Flow.Acknowledgement.TimedOut}",
          "direct module dependencies:",
          "  Shikigami.Flow"
        ]

gateTests :: TestTree
gateTests =
  testGroup
    "keiro gate"
    [ testCase "a passing gate reports nothing" do
        keiroGateFindings True "BREAKING: ignored when the gate passed" @?= [],
      testCase "each breaking finding of a failed gate is reported" do
        let found = keiroGateFindings False "noise\nBREAKING: AgentRun workflow-body changed [WorkflowBodyChanged]\nmore\nBREAKING: Approval changed\n"
        severities found @?= [Breaking, Breaking],
      testCase "a gate that failed for another reason is still breaking" do
        severities (keiroGateFindings False "keiro-scaffold: the committed generated layer is out of date\n") @?= [Breaking]
    ]

exposureTests :: TestTree
exposureTests =
  testGroup
    "exposure"
    [ testCase "the main library's exposed modules are read, and no other stanza's" do
        parseExposedModules cabal @?= Set.fromList ["Shikigami.Agent.Decl", "Shikigami.Flow", "Shikigami.Flow.Sdk"],
      testCase "Shikigami imports are collected, qualified or not" do
        importedModules "import Data.Text (Text)\nimport Shikigami.Flow.Sdk\nimport qualified Shikigami.Agent.Decl as Decl\nimport Shikigami.Log qualified as Log\n-- import Shikigami.Hidden\n"
          @?= Set.fromList ["Shikigami.Flow.Sdk", "Shikigami.Agent.Decl", "Shikigami.Log"],
      testCase "the three numbers are exposed, needed and exposed but unneeded" do
        exposureCounts Exposure {exposed = Set.fromList ["A", "B", "C"], imported = Set.fromList ["B", "Elsewhere"]} @?= (3, 1, 2)
    ]
  where
    cabal =
      Text.unlines
        [ "library",
          "  import: common",
          "  exposed-modules:",
          "    Shikigami.Agent.Decl",
          "    Shikigami.Flow",
          "    Shikigami.Flow.Sdk",
          "",
          "  build-depends:",
          "    base,",
          "",
          "library inspection",
          "  exposed-modules:",
          "    Shikigami.Inspection.Store"
        ]

-- | Pinning a schema rewrites one hash inside the inventory, so it must never
-- damage the inventory when the pin cannot be found.
pinTests :: TestTree
pinTests =
  testGroup
    "pin"
    [ testCase "an empty pinned hash is refused and leaves the inventory intact" do
        -- Relative, as every inventory path is.
        let scratch = "api-baseline-pin-test.scratch"
        createDirectoryIfMissing True scratch
        let schema = scratch </> "Schema.dhall"
            inventory = scratch </> "surfaces.dhall"
            original = "[ { hash = \"\" } ]\n"
            surface =
              Surface
                { name = "fixture",
                  owner = "fixture",
                  stability = Provisional,
                  rule = "fixture",
                  check = DhallSchema {schema = Text.pack schema, hash = "", corpus = Text.pack scratch},
                  freeze = Kernel,
                  enforcement = Report
                }
        TextIO.writeFile schema "{ field = 1 }"
        TextIO.writeFile inventory original
        result <- pinSurface inventory surface
        after <- TextIO.readFile inventory
        removeDirectoryRecursive scratch
        assertBool ("the empty pin was accepted: " <> show result) (either (Text.isInfixOf "empty") (const False) result)
        after @?= original
    ]

-- | The core keiro specification declares kernel labels only: no label a
-- flow pack pins in its golden inventory (EP-11 M3).
labelTests :: TestTree
labelTests =
  testGroup
    "kernel labels"
    [ testCase "a label a pack owns is refused in a core specification" do
        let spec = "workflow AgentRun\n  body\n    step lookup-agent -> AgentDecl\n    step watchdog-observe -> Observed\n"
            packs = [("packs/flow-pack-watchdog/test/golden/labels.txt", "watchdog-observe\nwatchdog-open\n")]
        specLabels spec @?= ["lookup-agent", "watchdog-observe"]
        packLabelsInSpecs [("domain/shikigami/agent-run.keiro", spec)] packs
          @?= [PackLabelInSpec {label = "watchdog-observe", spec = "domain/shikigami/agent-run.keiro", pack = "packs/flow-pack-watchdog/test/golden/labels.txt"}]
        packLabelsInSpecs [("domain/shikigami/agent-run.keiro", "    step lookup-agent -> AgentDecl\n")] packs @?= [],
      testCase "the real core specifications declare no pack label" do
        let root = "../.."
        specNames <- filter (Text.isSuffixOf ".keiro" . Text.pack) <$> listDirectory (root </> "domain/shikigami")
        specs <- mapM (\name -> (("domain/shikigami" </> name),) <$> TextIO.readFile (root </> "domain/shikigami" </> name)) specNames
        packDirectories <- listDirectory (root </> "packs")
        inventories <-
          fmap concat
            . mapM
              ( \directory -> do
                  let path = "packs" </> directory </> "test/golden/labels.txt"
                  exists <- doesFileExist (root </> path)
                  if exists then (\contents -> [(path, contents)]) <$> TextIO.readFile (root </> path) else pure []
              )
            $ packDirectories
        assertBool "the core declares its agent-run labels" (any (elem "lookup-agent" . specLabels . snd) specs)
        assertBool "at least four packs pin their labels" (length inventories >= 4 && all (not . null . packLabels . snd) inventories)
        packLabelsInSpecs specs inventories @?= []
    ]
