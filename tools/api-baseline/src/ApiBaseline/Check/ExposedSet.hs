-- | The modules a package's main library exposes, against a pinned list
-- (EP-11 M3). The core's main library re-exports only what a consumer needs
-- from its private @internal@ library, so exposing a module is a reviewed
-- change and hiding one breaks whoever imported it.
module ApiBaseline.Check.ExposedSet
  ( exposedSetFindings,
    renderExposedSet,
    parseExposedSet,
  )
where

import ApiBaseline.Types (Finding (..), Severity (..))
import Data.Set (Set)
import Data.Set qualified as Set
import Data.Text (Text)
import Data.Text qualified as Text

-- | A hidden module breaks an importer; a newly exposed one is a change to
-- review.
exposedSetFindings :: Set Text -> Set Text -> [Finding]
exposedSetFindings pinned current =
  [Finding Breaking ("no longer exposed: " <> Text.intercalate ", " (Set.toAscList removed)) | not (Set.null removed)]
    <> [Finding Changed ("newly exposed: " <> Text.intercalate ", " (Set.toAscList added)) | not (Set.null added)]
  where
    removed = pinned `Set.difference` current
    added = current `Set.difference` pinned

-- | The pin file: one module per line, sorted.
renderExposedSet :: Set Text -> Text
renderExposedSet = Text.unlines . Set.toAscList

parseExposedSet :: Text -> Set Text
parseExposedSet = Set.fromList . filter (not . Text.null) . map Text.strip . Text.lines
