-- | The package boundaries are real, not aspirational.
--
-- @docs\/architecture\/packages.md@ says which packages exist and which may
-- depend on which. Cabal enforces the arrows that /are/ declared, but nothing
-- stops someone from declaring a new one: adding @shikigami-api@ to
-- @shikigami-workers@'s @build-depends@ compiles perfectly well and quietly
-- makes a worker able to import HTTP route types. These tests read the @.cabal@
-- files and fail when that happens.
--
-- They also pin the negative space in @shikigami-core@. The domain package must
-- not link a web server, an OpenTelemetry exporter, a supervised queue adapter,
-- or a Kafka client — not because those are bad, but because each one belongs to
-- a specific runtime role, and a core that links them is a core that has
-- absorbed one.
--
-- The @.cabal@ files are parsed as text rather than through @Cabal-syntax@. The
-- files are machine-formatted by @treefmt@, so the shape is stable, and a text
-- parse keeps this test suite from depending on the build system's own library.
-- The parser fails loudly rather than silently returning nothing: a package whose
-- library stanza yields no dependencies at all is treated as a parse failure,
-- because "no forbidden dependencies found" would otherwise be trivially true.
module Shikigami.PackageArchitectureSpec (tests) where

import Data.List (sort)
import Data.Maybe (mapMaybe)
import Data.Text (Text)
import Data.Text qualified as Text
import Data.Text.IO qualified as TIO
import System.Directory (doesFileExist)
import System.FilePath ((</>))
import Test.Tasty (TestTree, testGroup)
import Test.Tasty.HUnit (assertBool, assertFailure, testCase, (@?=))

-- | The six packages, in dependency order.
expectedPackages :: [Text]
expectedPackages =
  [ "shikigami-api",
    "shikigami-client",
    "shikigami-core",
    "shikigami-migrations",
    "shikigami-server",
    "shikigami-workers"
  ]

-- | Which siblings each package's /production library/ may depend on.
--
-- Read as the arrows in @docs\/architecture\/packages.md@: api and workers see
-- core; server sees core and api; client sees api; core and migrations see no
-- sibling at all.
allowedLibraryEdges :: [(Text, [Text])]
allowedLibraryEdges =
  [ ("shikigami-core", []),
    ("shikigami-api", ["shikigami-core"]),
    ("shikigami-server", ["shikigami-core", "shikigami-api"]),
    ("shikigami-workers", ["shikigami-core"]),
    ("shikigami-migrations", []),
    ("shikigami-client", ["shikigami-api"])
  ]

-- | Packages whose runtime role core must never absorb.
--
-- Each entry names what linking it would mean: a listener, an exporter, a
-- supervised queue adapter, or a stream client.
forbiddenInCore :: [(Text, Text)]
forbiddenInCore =
  [ ("wai", "an HTTP application interface belongs to shikigami-server"),
    ("warp", "an HTTP server belongs to shikigami-server"),
    ("servant-server", "HTTP route execution belongs to shikigami-server"),
    ("hs-opentelemetry-sdk", "a tracer provider belongs at an executable boundary"),
    ("hs-opentelemetry-exporter-otlp", "an exporter belongs at an executable boundary"),
    ("shibuya-pgmq-adapter", "the supervised queue adapter belongs to shikigami-workers"),
    ("pgmq-effectful", "the queue effect interpreter belongs to shikigami-workers"),
    ("hw-kafka-client", "stream clients belong to shikigami-workers"),
    ("kafka-effectful", "stream clients belong to shikigami-workers")
  ]

tests :: TestTree
tests =
  testGroup
    "package architecture"
    [ testCase "the repository has exactly the six declared packages" do
        root <- repositoryRoot
        found <- mapM (\name -> (name,) <$> doesFileExist (cabalPathIn root name)) expectedPackages
        mapM_
          (\(name, exists) -> assertBool (Text.unpack name <> ": missing .cabal file") exists)
          found
        projectPackages <- declaredProjectPackages root
        sort projectPackages @?= sort expectedPackages,
      testCase "no production library depends on a forbidden sibling" do
        stanzas <- allStanzas
        mapM_
          ( \(package, allowed) -> do
              libraryDeps <- productionLibraryDeps package stanzas
              let siblings = filter (`elem` expectedPackages) (fmap dropSublibrary libraryDeps)
                  illegal = filter (`notElem` allowed) siblings
              assertBool
                ( Text.unpack package
                    <> "'s library may depend on "
                    <> show allowed
                    <> " but also depends on "
                    <> show illegal
                )
                (null illegal)
          )
          allowedLibraryEdges,
      testCase "shikigami-core links no listener, exporter, queue adapter, or stream client" do
        stanzas <- allStanzas
        coreDeps <- productionLibraryDeps "shikigami-core" stanzas
        mapM_
          ( \(dependency, why) ->
              assertBool
                ("shikigami-core's library depends on " <> Text.unpack dependency <> ": " <> Text.unpack why)
                (dependency `notElem` coreDeps)
          )
          forbiddenInCore,
      testCase "only test suites depend on the migrations test-support sublibrary" do
        stanzas <- allStanzas
        let offenders =
              [ (package, stanzaKind stanza, stanzaName stanza)
              | (package, packageStanzas) <- stanzas,
                stanza <- packageStanzas,
                stanzaKind stanza /= "test-suite",
                "shikigami-migrations:test-support" `elem` stanzaDeps stanza
              ]
        assertBool
          ("only test suites may use shikigami-migrations:test-support; found " <> show offenders)
          (null offenders),
      testCase "every package that ships a library also ships a test suite" do
        stanzas <- allStanzas
        let untested =
              [ package
              | (package, packageStanzas) <- stanzas,
                any (\s -> stanzaKind s == "library" && Text.null (stanzaName s)) packageStanzas,
                not (any (\s -> stanzaKind s == "test-suite") packageStanzas)
              ]
        assertBool ("packages with a library but no test suite: " <> show untested) (null untested)
    ]

-- ── Reading the packages ────────────────────────────────────────────────────

-- | One @library@, @executable@, or @test-suite@ block and the packages it needs.
data Stanza = Stanza
  { stanzaKind :: !Text,
    stanzaName :: !Text,
    stanzaDeps :: ![Text]
  }
  deriving stock (Eq, Show)

allStanzas :: IO [(Text, [Stanza])]
allStanzas = do
  root <- repositoryRoot
  mapM
    ( \package -> do
        contents <- TIO.readFile (cabalPathIn root package)
        pure (package, parseStanzas contents)
    )
    expectedPackages

-- | The dependencies of a package's main (unnamed) library stanza.
--
-- Fails the test rather than returning an empty list when the stanza is missing
-- or yields nothing, so a parser regression cannot make the invariants pass
-- vacuously.
productionLibraryDeps :: Text -> [(Text, [Stanza])] -> IO [Text]
productionLibraryDeps package stanzas =
  case lookup package stanzas of
    Nothing -> assertFailure (Text.unpack package <> ": not parsed")
    Just packageStanzas ->
      case filter (\s -> stanzaKind s == "library" && Text.null (stanzaName s)) packageStanzas of
        [] -> assertFailure (Text.unpack package <> ": no library stanza found")
        (libraryStanza : _)
          | null (stanzaDeps libraryStanza) ->
              assertFailure (Text.unpack package <> ": library stanza parsed with no dependencies")
          | otherwise -> pure (stanzaDeps libraryStanza)

-- | @shikigami-migrations:test-support@ names the @shikigami-migrations@ package.
dropSublibrary :: Text -> Text
dropSublibrary = Text.takeWhile (/= ':')

-- | Split a @.cabal@ file into its stanzas and collect each one's dependencies.
--
-- A stanza begins at a line with no leading whitespace whose first word is
-- @library@, @executable@, @test-suite@, or @benchmark@, and continues until the
-- next such line. Dependency names are the first word of each @, name@ line
-- inside the stanza's @build-depends@ list.
parseStanzas :: Text -> [Stanza]
parseStanzas contents = go (Text.lines contents) Nothing []
  where
    go [] current acc = reverse (maybe acc (: acc) current)
    go (line : rest) current acc =
      case stanzaHeader line of
        Just (kind, name) -> go rest (Just (Stanza kind name [])) (maybe acc (: acc) current)
        Nothing -> case (current, dependencyName line) of
          (Just stanza, Just dependency) ->
            go rest (Just stanza {stanzaDeps = stanzaDeps stanza <> [dependency]}) acc
          _ -> go rest current acc

    stanzaHeader line
      | Text.null line = Nothing
      | Text.head line == ' ' = Nothing
      | otherwise = case Text.words line of
          (kind : rest)
            | kind `elem` ["library", "executable", "test-suite", "benchmark"] ->
                Just (kind, Text.unwords rest)
          _ -> Nothing

    dependencyName line = case Text.words (Text.strip line) of
      ("," : dependency : _) -> Just dependency
      _ -> Nothing

-- ── Locating the repository ─────────────────────────────────────────────────

cabalPathIn :: FilePath -> Text -> FilePath
cabalPathIn root package = root </> Text.unpack package </> (Text.unpack package <> ".cabal")

-- | The packages @cabal.project@ actually builds.
--
-- Compared against 'expectedPackages' so that adding a seventh package to the
-- project fails here rather than being noticed in review.
declaredProjectPackages :: FilePath -> IO [Text]
declaredProjectPackages root = do
  contents <- TIO.readFile (root </> "cabal.project")
  pure (mapMaybe packageLine (takeWhile (not . Text.null) (drop 1 (Text.lines contents))))
  where
    packageLine line = case Text.words line of
      [word] | "shikigami-" `Text.isPrefixOf` word -> Just word
      _ -> Nothing

-- | Find the repository root from wherever the test runner started.
--
-- Cabal runs a test suite with the working directory set to its own package, but
-- a developer may run the built binary from the repository root, so both are
-- tried.
repositoryRoot :: IO FilePath
repositoryRoot = go [".", ".."]
  where
    go [] = assertFailure "cannot find cabal.project from the working directory; tried \".\" and \"..\""
    go (candidate : rest) = do
      exists <- doesFileExist (candidate </> "cabal.project")
      if exists then pure candidate else go rest
