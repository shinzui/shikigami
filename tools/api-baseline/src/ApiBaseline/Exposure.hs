-- | How much of @shikigami-core@ is exposed, and how much of that anything
-- outside its main library imports.
--
-- The core exposes every module today. This measurement says how far that is
-- from what its consumers need, which is the set a later milestone makes the
-- exposed set. It reads source text and changes nothing.
module ApiBaseline.Exposure
  ( Exposure (..),
    exposureCounts,
    parseExposedModules,
    importedModules,
    measureExposure,
    renderExposure,
  )
where

import Control.Monad (filterM)
import Data.Set (Set)
import Data.Set qualified as Set
import Data.Text (Text)
import Data.Text qualified as Text
import Data.Text.IO qualified as TextIO
import System.Directory (doesDirectoryExist, listDirectory)
import System.FilePath (takeExtension, takeFileName, (</>))

data Exposure = Exposure
  { exposed :: !(Set Text),
    imported :: !(Set Text)
  }

-- | Exposed today, needed by a consumer, and exposed but unneeded.
exposureCounts :: Exposure -> (Int, Int, Int)
exposureCounts exposure = (Set.size exposure.exposed, Set.size needed, Set.size (exposure.exposed `Set.difference` needed))
  where
    needed = exposure.exposed `Set.intersection` exposure.imported

renderExposure :: Exposure -> Text
renderExposure exposure =
  "exposure: "
    <> count exposed
    <> " exposed, "
    <> count needed
    <> " needed by a consumer, "
    <> count unneeded
    <> " exposed but unneeded"
  where
    (exposed, needed, unneeded) = exposureCounts exposure
    count = Text.pack . show

-- | The @exposed-modules@ of a Cabal file's main library stanza.
parseExposedModules :: Text -> Set Text
parseExposedModules contents =
  Set.fromList
    [ Text.strip line
    | line <- takeWhile continuation (drop 1 (dropWhile (not . field) mainLibrary)),
      not (Text.null (Text.strip line))
    ]
  where
    mainLibrary = takeWhile (not . nextStanza) (drop 1 (dropWhile ((/= "library") . Text.stripEnd) (Text.lines contents)))
    nextStanza line = not (Text.null line) && not (" " `Text.isPrefixOf` line) && not ("--" `Text.isPrefixOf` line)
    field line = Text.strip line == "exposed-modules:"
    continuation line = Text.null (Text.strip line) || "    " `Text.isPrefixOf` line

-- | The @Shikigami.*@ modules a source file imports.
importedModules :: Text -> Set Text
importedModules source =
  Set.fromList
    [ moduleName
    | line <- Text.lines source,
      "import" : rest <- [Text.words line],
      moduleName : _ <- [filter (/= "qualified") rest],
      "Shikigami." `Text.isPrefixOf` moduleName
    ]

-- | Measure from the repository root. A consumer is anything that links the
-- core's main library from outside it: the sibling packages and their tests,
-- the core's own public sublibraries, the packs, the tools and the keiro
-- conformance package. The core's own source and test suites are not
-- consumers.
measureExposure :: FilePath -> IO Exposure
measureExposure root = do
  exposed <- parseExposedModules <$> TextIO.readFile (root </> "shikigami-core" </> "shikigami-core.cabal")
  sources <- concat <$> mapM (haskellSources . (root </>)) consumerDirectories
  imported <- Set.unions <$> mapM (fmap importedModules . TextIO.readFile) sources
  pure Exposure {exposed, imported}
  where
    consumerDirectories =
      [ "shikigami-agent",
        "shikigami-api",
        "shikigami-client",
        "shikigami-migrations",
        "shikigami-server",
        "shikigami-workers",
        "shikigami-core/inspection",
        "shikigami-core/local-host",
        "shikigami-core/src/keiro-dsl-conformance.workspace.shikigami",
        "packs",
        "tools",
        "tests"
      ]

haskellSources :: FilePath -> IO [FilePath]
haskellSources directory = do
  exists <- doesDirectoryExist directory
  if not exists
    then pure []
    else do
      entries <- map (directory </>) . filter ((/= "dist-newstyle") . takeFileName) <$> listDirectory directory
      directories <- filterM doesDirectoryExist entries
      nested <- concat <$> mapM haskellSources directories
      pure ([entry | entry <- entries, takeExtension entry == ".hs"] <> nested)
