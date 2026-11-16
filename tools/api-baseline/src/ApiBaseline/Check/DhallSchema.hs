-- | A Dhall schema surface: the schema's semantic hash, and a corpus of real
-- declarations that must keep loading.
--
-- The hash answers "did the schema change at all", which an additive field
-- changes too. The corpus answers "does what people wrote still load", which
-- is the compatibility rule.
module ApiBaseline.Check.DhallSchema
  ( dhallSchemaFindings,
    excerpt,
    semanticHash,
    corpusFiles,
    loadCorpusFile,
  )
where

import ApiBaseline.Types (Finding (..), Severity (..))
import Control.Exception (SomeException, try)
import Data.List (sort)
import Data.Text (Text)
import Data.Text qualified as Text
import Dhall qualified
import Dhall.Core qualified
import Dhall.Import qualified
import Shikigami.Agent.Loader (LoadError (..), loadAgent)
import System.Directory (doesDirectoryExist, listDirectory)
import System.FilePath (takeExtension, (</>))

-- | The findings for a pinned hash, the current hash (or why the schema no
-- longer evaluates) and each corpus file's load result.
dhallSchemaFindings :: Text -> Text -> Either Text Text -> [(FilePath, Either Text ())] -> [Finding]
dhallSchemaFindings schema pinnedHash currentHash loads =
  schemaFindings <> [Finding Breaking (Text.pack path <> " no longer loads:\n" <> excerpt problem) | (path, Left problem) <- loads]
  where
    schemaFindings = case currentHash of
      Left problem -> [Finding Breaking (schema <> " no longer evaluates:\n" <> excerpt problem)]
      Right current
        | current == pinnedHash -> []
        | otherwise -> [Finding Changed (schema <> " changed: pinned " <> pinnedHash <> ", now " <> current)]

-- | The informative part of a Dhall error, which otherwise runs to pages:
-- its first lines, without blank lines or terminal colour codes.
excerpt :: Text -> Text
excerpt = Text.unlines . take 8 . filter (not . Text.null . Text.strip) . Text.lines . withoutColour
  where
    withoutColour text = case Text.breakOn "\ESC[" text of
      (before, rest)
        | Text.null rest -> before
        | otherwise -> before <> withoutColour (Text.drop 1 (Text.dropWhile (/= 'm') rest))

-- | The semantic hash @dhall hash@ prints: of the import-resolved,
-- alpha-beta-normalized expression.
semanticHash :: FilePath -> IO (Either Text Text)
semanticHash path = do
  evaluated <- try @SomeException (Dhall.inputExpr (Text.pack ("./" <> path)))
  pure case evaluated of
    Left problem -> Left (Text.pack (show problem))
    Right expression -> Right (Dhall.Import.hashExpressionToCode (Dhall.Core.alphaNormalize (Dhall.Core.denote expression)))

corpusFiles :: FilePath -> IO [FilePath]
corpusFiles directory = do
  exists <- doesDirectoryExist directory
  if exists
    then map (directory </>) . sort . filter ((== ".dhall") . takeExtension) <$> listDirectory directory
    else pure []

-- | Load one corpus file as the runtime would. Agent declarations go through
-- the agent loader; a file of another schema is evaluated and type-checked.
loadCorpusFile :: Text -> FilePath -> IO (Either Text ())
loadCorpusFile schema path
  | schema == "schema/Agent.dhall" =
      loadAgent path >>= \case
        Left (LoadError problem) -> pure (Left problem)
        Right _ -> pure (Right ())
  | otherwise = fmap (const ()) <$> semanticHash path
