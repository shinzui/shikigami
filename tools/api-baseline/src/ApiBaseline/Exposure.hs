-- | How much of @shikigami-core@ is exposed, and how much of that anything
-- outside its main library imports.
--
-- The core exposes every module today. This measurement says how far that is
-- from what its consumers need, which is the set a later milestone makes the
-- exposed set. It reads source text and changes nothing.
module ApiBaseline.Exposure
  ( Exposure (..),
    exposureCounts,
    neededModules,
    parseExposedModules,
    parseStanzaModules,
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
  { -- | What the main library exposes or re-exports.
    exposed :: !(Set Text),
    -- | Every module the core defines: the main library's own and, once it
    -- re-exports from a private @internal@ library, that library's.
    defined :: !(Set Text),
    imported :: !(Set Text)
  }

-- | The core modules some consumer imports.
neededModules :: Exposure -> Set Text
neededModules exposure = exposure.defined `Set.intersection` exposure.imported

-- | Exposed today, needed by a consumer, and exposed but unneeded.
exposureCounts :: Exposure -> (Int, Int, Int)
exposureCounts exposure = (Set.size exposure.exposed, Set.size needed, Set.size (exposure.exposed `Set.difference` needed))
  where
    needed = neededModules exposure

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

-- | The @exposed-modules@ and @reexported-modules@ of a Cabal file's main
-- library stanza.
parseExposedModules :: Text -> Set Text
parseExposedModules contents = parseStanzaModules "library" ["exposed-modules:", "reexported-modules:"] contents

-- | The modules the named fields of one stanza list, such as
-- @parseStanzaModules "library internal" ["exposed-modules:"]@.
parseStanzaModules :: Text -> [Text] -> Text -> Set Text
parseStanzaModules header fields contents =
  Set.fromList
    [ Text.dropWhileEnd (== ',') (Text.strip line)
    | name <- fields,
      line <- takeWhile continuation (drop 1 (dropWhile ((/= name) . Text.strip) stanza)),
      not (Text.null (Text.strip line))
    ]
  where
    stanza = takeWhile (not . nextStanza) (drop 1 (dropWhile ((/= header) . Text.stripEnd) (Text.lines contents)))
    nextStanza line = not (Text.null line) && not (" " `Text.isPrefixOf` line) && not ("--" `Text.isPrefixOf` line)
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
  cabal <- TextIO.readFile (root </> "shikigami-core" </> "shikigami-core.cabal")
  let exposed = parseExposedModules cabal
      defined = parseStanzaModules "library" ["exposed-modules:"] cabal <> parseStanzaModules "library internal" ["exposed-modules:"] cabal
  sources <- concat <$> mapM (haskellSources . (root </>)) consumerDirectories
  imported <- Set.unions <$> mapM (fmap importedModules . TextIO.readFile) sources
  pure Exposure {exposed, defined, imported}
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
