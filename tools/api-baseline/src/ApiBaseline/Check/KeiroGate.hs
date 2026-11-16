-- | The durable workflow contract, through @just keiro-gate@.
module ApiBaseline.Check.KeiroGate (keiroGateFindings) where

import ApiBaseline.Types (Finding (..), Severity (..))
import Data.Text (Text)
import Data.Text qualified as Text

-- | A gate that passes has nothing to report. A gate that fails reports each
-- of keiro's breaking findings, or the tail of its output when it failed for
-- another reason, such as a stale generated layer.
keiroGateFindings :: Bool -> Text -> [Finding]
keiroGateFindings passed output
  | passed = []
  | null breaking = [Finding Breaking ("just keiro-gate failed:\n" <> Text.unlines (lastLines 6))]
  | otherwise = map (Finding Breaking) breaking
  where
    breaking = [line | line <- Text.lines output, "BREAKING:" `Text.isPrefixOf` line]
    lastLines count = reverse (take count (reverse (filter (not . Text.null . Text.strip) (Text.lines output))))
