-- | The core keiro specification declares kernel journal labels only (EP-11
-- M3). Every flow pack pins the labels its flows journal in its own
-- @test/golden/labels.txt@; a label one of them owns must not be declared in
-- @domain/@, where it would make the kernel's durable contract carry a use
-- case's name.
module ApiBaseline.Check.KernelLabels
  ( specLabels,
    packLabels,
    PackLabelInSpec (..),
    packLabelsInSpecs,
  )
where

import Data.Text (Text)
import Data.Text qualified as Text

-- | The journal labels a keiro specification declares: the name after each
-- @step@, @child@ and @await@, and the id of each @patch@.
specLabels :: Text -> [Text]
specLabels source =
  [ label
  | line <- Text.lines source,
    keyword : label : _ <- [Text.words line],
    keyword `elem` ["step", "child", "await", "patch"]
  ]

-- | One pinned label per non-empty line of a pack's golden inventory.
packLabels :: Text -> [Text]
packLabels = filter (not . Text.null) . map Text.strip . Text.lines

data PackLabelInSpec = PackLabelInSpec
  { label :: !Text,
    spec :: !FilePath,
    pack :: !FilePath
  }
  deriving stock (Eq, Show)

-- | Every label a pack owns that a core specification declares.
packLabelsInSpecs :: [(FilePath, Text)] -> [(FilePath, Text)] -> [PackLabelInSpec]
packLabelsInSpecs specs packs =
  [ PackLabelInSpec {label, spec, pack}
  | (spec, source) <- specs,
    label <- specLabels source,
    (pack, inventory) <- packs,
    label `elem` packLabels inventory
  ]
