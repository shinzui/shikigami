-- | An authored expertise key. Normalization is only for duplicate admission.
module Shikigami.Agent.ExpertiseKey
  ( ExpertiseKey,
    parseExpertiseKey,
    expertiseKeyText,
    duplicateExpertiseKeys,
  )
where

import Data.Aeson (FromJSON (..), ToJSON, withText)
import Data.Set qualified as Set
import Data.Text (Text)
import Data.Text qualified as Text
import Dhall (Decoder (..), FromDhall (..))
import Dhall qualified

newtype ExpertiseKey = ExpertiseKey Text
  deriving stock (Eq, Ord, Show)
  deriving newtype (ToJSON)

parseExpertiseKey :: Text -> Either Text ExpertiseKey
parseExpertiseKey value
  | not (Text.null (normalized value)) = Right (ExpertiseKey value)
  | otherwise = Left "expertise key must not be blank"

expertiseKeyText :: ExpertiseKey -> Text
expertiseKeyText (ExpertiseKey value) = value

normalized :: Text -> Text
normalized = Text.toCaseFold . Text.strip

-- Return normalized duplicates once, in their original collision order.
duplicateExpertiseKeys :: [ExpertiseKey] -> [ExpertiseKey]
duplicateExpertiseKeys = go Set.empty Set.empty . map (ExpertiseKey . normalized . expertiseKeyText)
  where
    go _ _ [] = []
    go seen reported (value : rest)
      | value `Set.member` reported = go seen reported rest
      | value `Set.member` seen = value : go seen (Set.insert value reported) rest
      | otherwise = go (Set.insert value seen) reported rest

instance FromJSON ExpertiseKey where
  parseJSON = withText "expertise key" (either (fail . Text.unpack) pure . parseExpertiseKey)

instance FromDhall ExpertiseKey where
  autoWith _ =
    let Decoder {extract = extractText, expected = expectedText} = Dhall.strictText
     in Decoder
          { extract = \expression ->
              case Dhall.toMonadic (extractText expression) of
                Left err -> Dhall.fromMonadic (Left err)
                Right value -> either Dhall.extractError pure (parseExpertiseKey value),
            expected = expectedText
          }
