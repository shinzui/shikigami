-- | A model's stated confidence, admitted only when it is a finite number
-- from zero to one. Decision programs put it in their result types, so the
-- admission happens where the model's output is decoded.
module Shikigami.Program.Decision.Confidence
  ( ModelConfidence,
    parseModelConfidence,
    modelConfidenceNumber,
  )
where

import Data.Aeson (FromJSON (..), ToJSON)
import Data.Bifunctor (first)
import Data.Proxy (Proxy (..))
import Data.Text (Text)
import Data.Text qualified as Text
import Shikumi.Error (ShikumiError (ValidationFailure))
import Shikumi.Schema (FromModel (..), ToSchema (..))

newtype ModelConfidence = ModelConfidence Double
  deriving stock (Eq, Show)
  deriving newtype (ToJSON)

parseModelConfidence :: Double -> Either Text ModelConfidence
parseModelConfidence value
  | isNaN value || isInfinite value || value < 0 || value > 1 = Left "invalid confidence"
  | otherwise = Right (ModelConfidence value)

modelConfidenceNumber :: ModelConfidence -> Double
modelConfidenceNumber (ModelConfidence value) = value

instance FromJSON ModelConfidence where
  parseJSON value = parseJSON value >>= either (fail . Text.unpack) pure . parseModelConfidence

instance ToSchema ModelConfidence where toSchema _ = toSchema (Proxy @Double)

instance FromModel ModelConfidence where
  fromModelP path value = fromModelP @Double path value >>= first ValidationFailure . parseModelConfidence
