-- | An exact operator/declaration model lookup name, distinct from a vendor ID.
module Shikigami.Decision.ModelAlias
  ( ModelAlias,
    parseModelAlias,
    modelAliasFromNonEmpty,
    modelAliasText,
  )
where

import Data.Aeson (FromJSON (..), ToJSON (..), withText)
import Data.List.NonEmpty (NonEmpty)
import Data.List.NonEmpty qualified as NonEmpty
import Data.Text (Text)
import Data.Text qualified as Text
import Dhall (Decoder (..), FromDhall (..))
import Dhall qualified

newtype ModelAlias = ModelAlias Text
  deriving stock (Eq, Ord, Show)

parseModelAlias :: Text -> Either Text ModelAlias
parseModelAlias value
  | Text.null value = Left "model alias must not be empty"
  | otherwise = Right (ModelAlias value)

modelAliasFromNonEmpty :: NonEmpty Char -> ModelAlias
modelAliasFromNonEmpty = ModelAlias . Text.pack . NonEmpty.toList

modelAliasText :: ModelAlias -> Text
modelAliasText (ModelAlias value) = value

instance ToJSON ModelAlias where
  toJSON = toJSON . modelAliasText
  toEncoding = toEncoding . modelAliasText

instance FromJSON ModelAlias where
  parseJSON = withText "model alias" (either (fail . Text.unpack) pure . parseModelAlias)

instance FromDhall ModelAlias where
  autoWith _ =
    let Decoder {extract = extractText, expected = expectedText} = Dhall.strictText
     in Decoder
          { extract = \expression ->
              case Dhall.toMonadic (extractText expression) of
                Left err -> Dhall.fromMonadic (Left err)
                Right value -> either Dhall.extractError pure (parseModelAlias value),
            expected = expectedText
          }
