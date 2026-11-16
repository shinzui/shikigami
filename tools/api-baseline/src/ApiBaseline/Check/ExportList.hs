-- | The exported names of a module against a pinned list.
--
-- The names come from GHC's interface files, read with @ghc --show-iface@.
-- An interface lists every export whatever the source says: an explicit
-- list, a re-exported module, or no list at all.
module ApiBaseline.Check.ExportList
  ( exportListFindings,
    parseInterfaceExports,
    renderPinned,
    parsePinned,
  )
where

import ApiBaseline.Types (Finding (..), Severity (..))
import Data.Char (isSpace)
import Data.Map.Strict (Map)
import Data.Map.Strict qualified as Map
import Data.Set (Set)
import Data.Set qualified as Set
import Data.Text (Text)
import Data.Text qualified as Text

-- | A removed name breaks an importer; an added name is a change to review.
exportListFindings :: Text -> Set Text -> Set Text -> [Finding]
exportListFindings moduleName pinned current =
  [Finding Breaking (moduleName <> " no longer exports: " <> Text.intercalate ", " (Set.toAscList removed)) | not (Set.null removed)]
    <> [Finding Changed (moduleName <> " newly exports: " <> Text.intercalate ", " (Set.toAscList added)) | not (Set.null added)]
  where
    removed = pinned `Set.difference` current
    added = current `Set.difference` pinned

-- | The exports section of @ghc --show-iface@ output, as unqualified names.
-- A type's constructors and fields appear as @Type.member@, so removing a
-- constructor from an export is seen as well as removing the type.
parseInterfaceExports :: Text -> Set Text
parseInterfaceExports output =
  Set.fromList (concatMap entry (takeWhile indented (drop 1 (dropWhile (/= "exports:") (Text.lines output)))))
  where
    indented line = "  " `Text.isPrefixOf` line
    entry line =
      let (parent, rest) = Text.breakOn "{" (Text.strip line)
          owner = unqualified parent
          children = Text.words (Text.dropEnd 1 (Text.drop 1 rest))
       in owner : [owner <> "." <> child | child <- map unqualified children, child /= owner]
    -- @Shikigami.Flow.Pack.kernelCapabilityFlow@ is @kernelCapabilityFlow@; an
    -- operator such as @Effectful.Internal.Effect.:>@ keeps its symbol.
    unqualified name = case Text.breakOnAll "." name of
      [] -> name
      breaks ->
        let candidates = [Text.drop 1 suffix | (prefix, suffix) <- breaks, isModulePath prefix, not (Text.null (Text.drop 1 suffix))]
         in case candidates of
              [] -> name
              _ -> last candidates
    isModulePath prefix = all isModuleSegment (Text.splitOn "." prefix)
    isModuleSegment segment = case Text.uncons segment of
      Just (first, _) -> first `elem` ['A' .. 'Z'] && not (Text.any isSpace segment)
      Nothing -> False

-- | The pin file: one @Module name@ line per exported name, sorted.
renderPinned :: Map Text (Set Text) -> Text
renderPinned exports = Text.unlines [moduleName <> " " <> name | (moduleName, names) <- Map.toAscList exports, name <- Set.toAscList names]

parsePinned :: Text -> Map Text (Set Text)
parsePinned contents =
  Map.fromListWith Set.union [(moduleName, Set.singleton (Text.drop 1 name)) | line <- Text.lines contents, let (moduleName, name) = Text.breakOn " " line, not (Text.null name)]
