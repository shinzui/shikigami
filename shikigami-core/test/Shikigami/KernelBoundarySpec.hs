-- | The kernel fitness check: @shikigami-core@ keeps primitives, and use
-- cases leave it as declarations or flow packs
-- (@docs\/adr\/0129-the-kernel-owns-primitives-and-use-cases-ship-as-declarations-or-packs.md@).
--
-- The policy is the @kernel@ section of @tools\/style\/module-ownership.json@:
-- a closed map from every top-level namespace under @shikigami-core\/src\/Shikigami@
-- to @kernel@, @flow-pack@ or @kikan-binding@, and the modules of the leaving
-- groups, frozen so that the list can only shrink. The rules are one pure
-- function, 'kernelViolations', so each is tested on synthetic inputs as well
-- as on the real tree.
--
-- The real-tree test walks the source directory rather than the @.cabal@
-- module list, so a planted file fails before anyone lists it. The pack rules
-- read every @packs\/*\/*.cabal@ and hold vacuously until a pack exists.
module Shikigami.KernelBoundarySpec
  ( tests,
    NamespaceStatus (..),
    KernelPolicy (..),
    OutOfCorePackage (..),
    KernelInputs (..),
    KernelViolation (..),
    kernelViolations,
    renderKernelViolation,
  )
where

import Data.Aeson (FromJSON (..), withObject, withText, (.:))
import Data.Aeson qualified as Aeson
import Data.List (sort)
import Data.Map.Strict (Map)
import Data.Map.Strict qualified as Map
import Data.Maybe (mapMaybe)
import Data.Set (Set)
import Data.Set qualified as Set
import Data.Text (Text)
import Data.Text qualified as Text
import Data.Text.IO qualified as TIO
import Shikigami.PackageArchitectureSpec (Stanza (..), cabalFieldEntries, cabalPathIn, expectedPackages, forbiddenInLightPackages, haskellSources, parseStanzas, repositoryRoot)
import System.Directory (doesDirectoryExist, listDirectory)
import System.FilePath (dropExtension, makeRelative, splitDirectories, takeExtension, (</>))
import Test.Tasty (TestTree, testGroup)
import Test.Tasty.HUnit (assertBool, assertEqual, assertFailure, testCase, (@?=))

-- ── The policy ──────────────────────────────────────────────────────────────

data NamespaceStatus
  = Kernel
  | -- | EP-6 moves it to a flow pack.
    LeavingToPack
  | -- | EP-10 moves it to the Kikan binding package.
    LeavingToBinding
  deriving stock (Eq, Show)

instance FromJSON NamespaceStatus where
  parseJSON = withText "NamespaceStatus" \case
    "kernel" -> pure Kernel
    "flow-pack" -> pure LeavingToPack
    "kikan-binding" -> pure LeavingToBinding
    other -> fail ("unknown namespace status " <> show other)

data KernelPolicy = KernelPolicy
  { namespaces :: !(Map Text NamespaceStatus),
    frozenModules :: !(Set Text),
    -- | SDK component -> the modules it must re-export, exactly.
    sdkModules :: !(Map Text [Text]),
    decision :: !Text
  }
  deriving stock (Eq, Show)

instance FromJSON KernelPolicy where
  parseJSON = withObject "KernelPolicy" \o ->
    KernelPolicy <$> o .: "namespaces" <*> (Set.fromList <$> o .: "frozenModules") <*> o .: "sdkModules" <*> o .: "decision"

-- ── What the rules read ─────────────────────────────────────────────────────

-- | A package found under @packs\/@: a pack (a library and tests) or a
-- distribution (executables and no library).
data OutOfCorePackage = OutOfCorePackage
  { name :: !Text,
    stanzas :: ![Stanza]
  }
  deriving stock (Eq, Show)

data KernelInputs = KernelInputs
  { -- | Every @.hs@ file under the source root, relative to it
    -- (@Shikigami\/Watchdog\/Store.hs@).
    sources :: ![FilePath],
    -- | The seven stock packages and their stanzas.
    stock :: ![(Text, [Stanza])],
    outOfCore :: ![OutOfCorePackage],
    -- | Each SDK sublibrary that exists, with its @reexported-modules@.
    sdkExports :: !(Map Text [Text]),
    -- | The ADR-75 domain roots, and the roots of the composition modules and
    -- the generated layer.
    reviewedRoots :: !(Set Text),
    -- | What each module of the adaptive coordinator imports. The coordinator
    -- is a kernel primitive on the strength of depending on no Kikan service
    -- (plan 131, M6), so that claim is checked and not only recorded.
    coordinatorImports :: ![(Text, [Text])]
  }
  deriving stock (Eq, Show)

data KernelViolation
  = -- | A top-level root in the core that the policy does not classify.
    UnknownNamespace !Text !FilePath
  | -- | A new module under a root that is leaving the core.
    UnfrozenModule !Text !NamespaceStatus
  | -- | A frozen module that no longer exists: the list must shrink.
    StaleFrozenModule !Text
  | -- | A classified root with no module left: the map must shrink.
    EmptyNamespace !Text
  | -- | A kernel root neither ADR-75 nor the composition list reviews.
    UnreviewedKernelRoot !Text
  | -- | (stanza of a stock package, the pack or distribution it names)
    StockDependsOnPack !Text !Text
  | -- | (pack, forbidden dependency)
    PackEscapesSdk !Text !Text
  | -- | (pack, dependency of its @bodies@ sublibrary other than @flow-sdk@)
    BodyEscapesFlowSdk !Text !Text
  | PackShipsExecutable !Text
  | PackWithoutTests !Text
  | PrefixedOutOfCorePackage !Text
  | -- | (SDK component, the modules it re-exports)
    SdkExportsDrifted !Text ![Text]
  | -- | (coordinator module, the Kikan binding module it imports)
    CoordinatorImportsBinding !Text !Text
  deriving stock (Eq, Show)

-- | The adaptive coordinator: the modules that stay in the kernel as a
-- primitive rather than leaving as a use case.
isCoordinatorModule :: Text -> Bool
isCoordinatorModule name =
  "Shikigami.Coordination." `Text.isPrefixOf` name || name `elem` ["Shikigami.Flow.AdaptiveDelivery", "Shikigami.Program.Decision.Adaptive"]

-- | The Kikan service bindings still compiled into the core. EP-10 moves them
-- to a binding package, after which the package dependency rule covers this.
isBindingModule :: Text -> Bool
isBindingModule name =
  name `elem` ["Shikigami.Sink.KawaClient", "Shikigami.Sink.KizashiClient", "Shikigami.Sink.Danwa", "Shikigami.Sink.KanmonClient", "Shikigami.Sink.ReiAction", "Shikigami.Integration.Danwa", "Shikigami.Authority.KikanEn"]
    || any (`Text.isPrefixOf` name) ["Shikigami.Authority.KikanEn.", "Shikigami.DanwaConversation."]

-- ── The rules ───────────────────────────────────────────────────────────────

kernelViolations :: KernelPolicy -> KernelInputs -> [KernelViolation]
kernelViolations policy inputs =
  concat
    [ concatMap sourceViolation modules,
      [StaleFrozenModule frozen | frozen <- Set.toList policy.frozenModules, frozen `Set.notMember` present],
      [EmptyNamespace root | root <- Map.keys policy.namespaces, root `Set.notMember` populated],
      [UnreviewedKernelRoot root | (root, Kernel) <- Map.toList policy.namespaces, root `Set.notMember` inputs.reviewedRoots],
      [ StockDependsOnPack (package <> ":" <> stanzaLabel stanza) dependency
      | (package, packageStanzas) <- inputs.stock,
        stanza <- packageStanzas,
        dependency <- packageOf <$> stanza.dependencies,
        dependency `Set.member` outOfCoreNames
      ],
      concatMap outOfCoreViolations inputs.outOfCore,
      [ SdkExportsDrifted component found
      | (component, pinned) <- Map.toList policy.sdkModules,
        Just found <- [Map.lookup component inputs.sdkExports],
        sort found /= sort pinned
      ],
      [CoordinatorImportsBinding owner imported | (owner, imports) <- inputs.coordinatorImports, isCoordinatorModule owner, imported <- imports, isBindingModule imported]
    ]
  where
    modules = mapMaybe (\path -> (path,) <$> moduleOf path) inputs.sources
    present = Set.fromList (snd <$> modules)
    populated = Set.fromList (mapMaybe (rootOf . snd) modules)
    outOfCoreNames = Set.fromList ((.name) <$> inputs.outOfCore)
    sourceViolation (path, moduleName) = case rootOf moduleName of
      Nothing -> []
      Just root -> case Map.lookup root policy.namespaces of
        Nothing -> [UnknownNamespace root path]
        Just Kernel -> []
        Just status
          | moduleName `Set.member` policy.frozenModules -> []
          | otherwise -> [UnfrozenModule moduleName status]
    outOfCoreViolations package =
      let libraries = filter ((== "library") . (.kind)) package.stanzas
          mainLibraries = filter (Text.null . (.name)) libraries
          executables = filter ((== "executable") . (.kind)) package.stanzas
          isPack = not (null libraries)
       in concat
            [ [PrefixedOutOfCorePackage package.name | "shikigami-" `Text.isPrefixOf` package.name],
              [PackShipsExecutable package.name | isPack, not (null executables)],
              [PackWithoutTests package.name | isPack, not (any ((== "test-suite") . (.kind)) package.stanzas)],
              [ PackEscapesSdk package.name dependency
              | library <- mainLibraries,
                dependency <- library.dependencies,
                isShikigami dependency && dependency `notElem` ["shikigami-core:flow-sdk", "shikigami-core:pack-sdk"]
                  || packageOf dependency `elem` (fst <$> forbiddenInLightPackages)
              ],
              [ BodyEscapesFlowSdk package.name dependency
              | library <- filter ((== "bodies") . (.name)) libraries,
                dependency <- library.dependencies,
                isShikigami dependency && dependency /= "shikigami-core:flow-sdk"
              ]
            ]
    isShikigami dependency = "shikigami-" `Text.isPrefixOf` dependency
    stanzaLabel stanza = if Text.null stanza.name then stanza.kind else stanza.kind <> " " <> stanza.name

-- | @Shikigami/Watchdog/Store.hs@ is @FlowPack.Watchdog.Store@.
moduleOf :: FilePath -> Maybe Text
moduleOf path
  | takeExtension path /= ".hs" = Nothing
  | otherwise = case splitDirectories (dropExtension path) of
      segments@("Shikigami" : _ : _) -> Just (Text.intercalate "." (Text.pack <$> segments))
      _ -> Nothing

-- | The top-level namespace of a @Shikigami.*@ module.
rootOf :: Text -> Maybe Text
rootOf moduleName = case Text.splitOn "." moduleName of
  ("Shikigami" : root : _) -> Just root
  _ -> Nothing

-- | @shikigami-core:flow-sdk@ names the package @shikigami-core@.
packageOf :: Text -> Text
packageOf = Text.takeWhile (/= ':')

-- ── The messages ────────────────────────────────────────────────────────────

renderKernelViolation :: KernelPolicy -> KernelViolation -> Text
renderKernelViolation policy = \case
  UnknownNamespace root path ->
    Text.unlines
      [ "shikigami-core/src/" <> Text.pack path <> ": Shikigami." <> root <> " is not a kernel namespace.",
        "  shikigami-core owns primitives only (" <> policy.decision <> ").",
        "  Ship a use case as a declaration under agents/ (a skill or a playbook, docs/user/playbooks.md),",
        "  or as a flow pack under packs/ that depends only on shikigami-core:flow-sdk and shikigami-core:pack-sdk.",
        "  A genuine new primitive needs an ADR and a \"kernel\" entry in tools/style/module-ownership.json."
      ]
  UnfrozenModule moduleName status ->
    moduleName <> " is a new module under a namespace that is leaving the core (" <> leaving status <> "); add it to the pack or binding instead, or move the namespace first."
  StaleFrozenModule moduleName ->
    moduleName <> " is frozen in tools/style/module-ownership.json but no longer exists; remove it from kernel.frozenModules."
  EmptyNamespace root ->
    "Shikigami." <> root <> " has no module left; remove it from kernel.namespaces."
  UnreviewedKernelRoot root ->
    "Shikigami." <> root <> " is a kernel namespace but neither domainRoots nor compositionModules reviews it."
  StockDependsOnPack stanza dependency ->
    stanza <> " depends on " <> dependency <> "; stock packages never depend on a pack, only a distribution composes packs."
  PackEscapesSdk package dependency ->
    package <> " depends on " <> dependency <> "; a pack library may depend on shikigami-core:flow-sdk and shikigami-core:pack-sdk only, and on nothing a light package forbids."
  BodyEscapesFlowSdk package dependency ->
    package <> ":bodies depends on " <> dependency <> "; flow bodies may depend on shikigami-core:flow-sdk only."
  PackShipsExecutable package ->
    package <> " is a pack with an executable; executables belong to a distribution package."
  PackWithoutTests package ->
    package <> " is a pack without a test suite."
  PrefixedOutOfCorePackage package ->
    package <> " lives under packs/ but uses the shikigami- prefix, which names the seven stock packages."
  SdkExportsDrifted component found ->
    "shikigami-core:" <> component <> " re-exports " <> Text.intercalate ", " found <> ", which differs from kernel.sdkModules."
  CoordinatorImportsBinding owner imported ->
    owner <> " imports " <> imported <> ". The adaptive coordinator is a kernel primitive because it depends on no Kikan service; reach the service through a capability, or record a new disposition."
  where
    leaving = \case
      LeavingToPack -> "to a flow pack"
      LeavingToBinding -> "to the Kikan binding"
      Kernel -> "kernel"

-- ── Reading the real tree ───────────────────────────────────────────────────

data OwnershipFile = OwnershipFile
  { kernel :: !KernelPolicy,
    domainRoots :: ![Text],
    compositionModules :: ![Text],
    generatedRoot :: !Text
  }

instance FromJSON OwnershipFile where
  parseJSON = withObject "OwnershipFile" \o ->
    OwnershipFile <$> o .: "kernel" <*> o .: "domainRoots" <*> o .: "compositionModules" <*> o .: "generatedRoot"

readTree :: IO (KernelPolicy, KernelInputs)
readTree = do
  root <- repositoryRoot
  ownership :: OwnershipFile <- Aeson.eitherDecodeFileStrict (root </> "tools/style/module-ownership.json") >>= either (assertFailure . ("module-ownership.json: " <>)) pure
  let sourceRoot = root </> "shikigami-core/src"
  sources <- fmap (makeRelative sourceRoot) <$> haskellSources (sourceRoot </> "Shikigami")
  stockFiles <- mapM (\package -> (package,) <$> TIO.readFile (cabalPathIn root package)) expectedPackages
  outOfCore <- packPackages (root </> "packs")
  let coreCabal = maybe "" id (lookup "shikigami-core" stockFiles)
      sdkExports =
        Map.fromList
          [ (component, Text.dropWhileEnd (== ',') <$> cabalFieldEntries "reexported-modules:" block)
          | component <- Map.keys ownership.kernel.sdkModules,
            Just block <- [stanzaBlock ("library " <> component) coreCabal]
          ]
      reviewedRoots = Set.fromList (ownership.domainRoots <> mapMaybe rootOf (ownership.generatedRoot : ownership.compositionModules))
  coordinatorImports <-
    mapM
      (\(path, name) -> (name,) . importedModules <$> TIO.readFile (sourceRoot </> path))
      [(path, name) | path <- sources, Just name <- [moduleOf path], isCoordinatorModule name]
  pure (ownership.kernel, KernelInputs {sources, stock = fmap parseStanzas <$> stockFiles, outOfCore, sdkExports, reviewedRoots, coordinatorImports})

-- | The modules a source file imports, qualified or not.
importedModules :: Text -> [Text]
importedModules source =
  [ name
  | line <- Text.lines source,
    Just rest <- [Text.stripPrefix "import " line],
    name : _ <- [filter (/= "qualified") (Text.words rest)]
  ]

-- | Every package directly under @packs/@.
packPackages :: FilePath -> IO [OutOfCorePackage]
packPackages directory = do
  exists <- doesDirectoryExist directory
  if not exists
    then pure []
    else do
      entries <- sort <$> listDirectory directory
      concat
        <$> mapM
          ( \entry -> do
              let packageDirectory = directory </> entry
              isDirectory <- doesDirectoryExist packageDirectory
              files <- if isDirectory then listDirectory packageDirectory else pure []
              mapM
                (\file -> OutOfCorePackage (Text.pack (dropExtension file)) . parseStanzas <$> TIO.readFile (packageDirectory </> file))
                [file | file <- sort files, takeExtension file == ".cabal"]
          )
          entries

-- | The text of one stanza, from its header to the next top-level line.
stanzaBlock :: Text -> Text -> Maybe Text
stanzaBlock header contents = case dropWhile ((/= header) . Text.stripEnd) (Text.lines contents) of
  [] -> Nothing
  (first : rest) -> Just (Text.unlines (first : takeWhile (\line -> Text.null line || Text.head line == ' ') rest))

-- | The names a module header exports, one per entry, sorted. Comments and
-- section headings are dropped, so only a change to the surface moves it.
exportList :: Text -> [Text]
exportList source = sort [Text.unwords (Text.words entry) | entry <- Text.splitOn "," body, not (Text.null (Text.strip entry))]
  where
    header = Text.unlines (takeWhile (/= "where") (dropWhile (not . Text.isPrefixOf "module ") (Text.lines source)))
    uncommented = Text.unlines [fst (Text.breakOn "--" line) | line <- Text.lines header]
    -- No entry of these facades has an inner comma, so splitting on commas is exact.
    body = Text.dropEnd 1 (Text.stripEnd (Text.drop 1 (Text.dropWhile (/= '(') uncommented)))

-- ── Tests ───────────────────────────────────────────────────────────────────

tests :: TestTree
tests =
  testGroup
    "kernel boundary"
    [ testCase "the real tree keeps the kernel boundary" do
        (policy, inputs) <- readTree
        assertBool "the walk found the core's sources" (length inputs.sources > 100)
        case kernelViolations policy inputs of
          [] -> pure ()
          found -> assertFailure (Text.unpack (Text.unlines (renderKernelViolation policy <$> found))),
      testCase "the policy classifies every top-level namespace and freezes only existing modules" do
        (policy, inputs) <- readTree
        let roots = Set.fromList (mapMaybe (\path -> moduleOf path >>= rootOf) inputs.sources)
        Map.keysSet policy.namespaces @?= roots
        assertBool "something is leaving" (any (/= Kernel) (Map.elems policy.namespaces)),
      -- Adding a name to an SDK facade is a reviewed diff: the golden file
      -- changes with it. EP-11 reuses this as the SDK's compatibility check.
      -- The adaptive coordinator stays in the kernel because it needs no Kikan
      -- service (plan 131, M6). A planted import of a binding fails; the same
      -- import from a module outside the coordinator is not this rule's concern.
      testCase "the adaptive coordinator imports no Kikan binding module" do
        (_, inputs) <- readTree
        assertBool "the walk found the coordinator" (length inputs.coordinatorImports > 5)
        let planted owner = fixture {coordinatorImports = [(owner, ["Shikigami.Flow.Decision", "Shikigami.Sink.KizashiClient", "Shikigami.DanwaConversation.Loop"])]}
        kernelViolations synthetic (planted "Shikigami.Coordination.Workflow")
          @?= [ CoordinatorImportsBinding "Shikigami.Coordination.Workflow" "Shikigami.Sink.KizashiClient",
                CoordinatorImportsBinding "Shikigami.Coordination.Workflow" "Shikigami.DanwaConversation.Loop"
              ]
        kernelViolations synthetic (planted "Shikigami.Program.Decision.Adaptive") @?= [CoordinatorImportsBinding "Shikigami.Program.Decision.Adaptive" "Shikigami.Sink.KizashiClient", CoordinatorImportsBinding "Shikigami.Program.Decision.Adaptive" "Shikigami.DanwaConversation.Loop"]
        kernelViolations synthetic (planted "Shikigami.Agent.Run") @?= []
        assertBool "the refusal says why it is a primitive" ("depends on no Kikan service" `Text.isInfixOf` renderKernelViolation synthetic (CoordinatorImportsBinding "Shikigami.Coordination.Workflow" "Shikigami.Sink.KizashiClient")),
      testCase "each SDK facade exports exactly its golden list" do
        root <- repositoryRoot
        (policy, _) <- readTree
        -- The facades are the modules written for the SDK. A whole kernel
        -- module re-exported beside them is pinned by the api-baseline
        -- export check, which reads interface files.
        let facades = filter (\name -> ".Sdk" `Text.isInfixOf` name) (concat (Map.elems policy.sdkModules))
        assertBool "the policy names SDK facades" (not (null facades))
        mapM_
          ( \facade -> do
              source <- TIO.readFile (root </> "shikigami-core/src" </> Text.unpack (Text.replace "." "/" facade) <> ".hs")
              golden <- TIO.readFile (root </> "shikigami-core/test/golden/sdk" </> Text.unpack facade <> ".txt")
              assertEqual (Text.unpack facade <> " differs from its golden export list") (Text.lines golden) (exportList source)
          )
          facades,
      testCase "a planted use-case namespace fails with the route out of the core" do
        let found = kernelViolations synthetic (fixture {sources = "Shikigami/Campaign/Plan.hs" : fixture.sources})
        found @?= [UnknownNamespace "Campaign" "Shikigami/Campaign/Plan.hs"]
        let message = Text.concat (renderKernelViolation synthetic <$> found)
        mapM_ (\needle -> assertBool (Text.unpack needle) (needle `Text.isInfixOf` message)) ["Shikigami.Campaign is not a kernel namespace", "agents/", "packs/", "shikigami-core:flow-sdk", synthetic.decision],
      testCase "a leaving namespace accepts no new module, and the lists only shrink" do
        kernelViolations synthetic (fixture {sources = "Shikigami/Watchdog/Pager.hs" : fixture.sources}) @?= [UnfrozenModule "Shikigami.Watchdog.Pager" LeavingToPack]
        kernelViolations synthetic (fixture {sources = filter (/= "Shikigami/Watchdog/Sweep.hs") fixture.sources})
          @?= [StaleFrozenModule "Shikigami.Watchdog.Sweep", EmptyNamespace "Watchdog"]
        kernelViolations synthetic (fixture {reviewedRoots = Set.delete "Agent" fixture.reviewedRoots}) @?= [UnreviewedKernelRoot "Agent"],
      testCase "a pack depends on the SDK only, keeps bodies on flow-sdk, ships tests and no executable" do
        kernelViolations synthetic (fixture {outOfCore = [goodPack, distribution]}) @?= []
        let escaping = OutOfCorePackage "shikigami-ledger" [library "" ["base", "shikigami-core", "warp"], library "bodies" ["shikigami-core:pack-sdk"], Stanza "executable" "ledger" ["base"]]
        kernelViolations synthetic (fixture {outOfCore = [escaping]})
          @?= [ PrefixedOutOfCorePackage "shikigami-ledger",
                PackShipsExecutable "shikigami-ledger",
                PackWithoutTests "shikigami-ledger",
                PackEscapesSdk "shikigami-ledger" "shikigami-core",
                PackEscapesSdk "shikigami-ledger" "warp",
                BodyEscapesFlowSdk "shikigami-ledger" "shikigami-core:pack-sdk"
              ],
      testCase "a stock package never depends on a pack, and the SDK re-exports stay pinned" do
        let stockOnPack = fixture {stock = [("shikigami-agent", [library "" ["base", "flow-pack-ledger"]])], outOfCore = [goodPack]}
        kernelViolations synthetic stockOnPack @?= [StockDependsOnPack "shikigami-agent:library" "flow-pack-ledger"]
        kernelViolations synthetic (fixture {sdkExports = Map.fromList [("flow-sdk", ["Shikigami.Flow.Sdk.Program", "Shikigami.Flow.Sdk"])]}) @?= []
        kernelViolations synthetic (fixture {sdkExports = Map.fromList [("flow-sdk", ["Shikigami.Flow.Sdk", "Shikigami.Store"])]})
          @?= [SdkExportsDrifted "flow-sdk" ["Shikigami.Flow.Sdk", "Shikigami.Store"]]
    ]
  where
    synthetic =
      KernelPolicy
        { namespaces = Map.fromList [("Agent", Kernel), ("Watchdog", LeavingToPack), ("DanwaConversation", LeavingToBinding)],
          frozenModules = Set.fromList ["Shikigami.Watchdog.Sweep", "Shikigami.DanwaConversation.Loop"],
          sdkModules = Map.fromList [("flow-sdk", ["Shikigami.Flow.Sdk", "Shikigami.Flow.Sdk.Program"])],
          decision = "docs/adr/0129-the-kernel-owns-primitives-and-use-cases-ship-as-declarations-or-packs.md"
        }
    fixture =
      KernelInputs
        { sources = ["Shikigami/Agent.hs", "Shikigami/Agent/Run.hs", "Shikigami/Watchdog/Sweep.hs", "Shikigami/DanwaConversation/Loop.hs"],
          stock = [("shikigami-agent", [library "" ["base", "shikigami-core"]])],
          outOfCore = [],
          sdkExports = Map.empty,
          reviewedRoots = Set.fromList ["Agent", "Watchdog", "DanwaConversation"],
          coordinatorImports = [("Shikigami.Coordination.Workflow", ["Shikigami.Coordination.Runtime", "Shikigami.Flow.Decision"])]
        }
    library = Stanza "library"
    goodPack =
      OutOfCorePackage
        { name = "flow-pack-ledger",
          stanzas = [library "" ["base", "shikigami-core:flow-sdk", "shikigami-core:pack-sdk"], library "bodies" ["base", "shikigami-core:flow-sdk"], Stanza "test-suite" "flow-pack-ledger-test" ["base", "flow-pack-ledger"]]
        }
    distribution = OutOfCorePackage {name = "ledger-distribution", stanzas = [Stanza "executable" "ledger-agent-run" ["base", "shikigami-agent", "flow-pack-ledger"]]}
