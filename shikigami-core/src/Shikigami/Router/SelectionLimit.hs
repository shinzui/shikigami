-- | A positive bounded routing fan-out, checked at every ingress.
module Shikigami.Router.SelectionLimit
  ( SelectionLimit,
    parseSelectionLimit,
    selectionLimitInt,
    selectionLimitNatural,
  )
where

import Data.Aeson (FromJSON (..), ToJSON)
import Data.Text (Text)
import Data.Text qualified as Text
import Dhall (Decoder (..), FromDhall (..))
import Dhall qualified
import Numeric.Natural (Natural)

newtype SelectionLimit = SelectionLimit Natural
  deriving stock (Eq, Ord, Show)
  deriving newtype (ToJSON)

parseSelectionLimit :: Natural -> Either Text SelectionLimit
parseSelectionLimit value
  | value >= 1 && value <= 16 = Right (SelectionLimit value)
  | otherwise = Left "maxSelections must be between 1 and 16 inclusive"

selectionLimitInt :: SelectionLimit -> Int
selectionLimitInt = fromIntegral . selectionLimitNatural

selectionLimitNatural :: SelectionLimit -> Natural
selectionLimitNatural (SelectionLimit value) = value

instance FromJSON SelectionLimit where
  parseJSON value = parseJSON value >>= either (fail . Text.unpack) pure . parseSelectionLimit

instance FromDhall SelectionLimit where
  autoWith _ =
    let Decoder {extract = extractNatural, expected = expectedNatural} = Dhall.natural
     in Decoder
          { extract = \expression ->
              case Dhall.toMonadic (extractNatural expression) of
                Left err -> Dhall.fromMonadic (Left err)
                Right value -> either Dhall.extractError pure (parseSelectionLimit value),
            expected = expectedNatural
          }
