{-# LANGUAGE DataKinds #-}

-- | Allocated application identities. Parsing proves prefix, canonical encoding
-- and UUIDv7 domain, not ownership of a persisted review or resolution.
module Shikigami.PracticeReview.Identity
  ( ReviewId,
    parseReviewId,
    reviewIdText,
    newReviewId,
    ResolutionId,
    parseResolutionId,
    resolutionIdText,
    newResolutionId,
  )
where

import Data.Aeson (FromJSON (..), ToJSON (..), withText)
import Data.Bifunctor (first)
import Data.KindID.V7 qualified as KindID
import Data.Text (Text)
import Data.Text qualified as Text

newtype ReviewId = ReviewId (KindID.KindID "shikigami_practice_review")
  deriving stock (Eq, Ord, Show)

parseReviewId :: Text -> Either Text ReviewId
parseReviewId input = do
  value <- first (const "invalid review identity encoding or prefix") (KindID.parseText @"shikigami_practice_review" input)
  case KindID.checkKindID value of
    Just _ -> Left "review identity requires UUIDv7"
    Nothing
      | KindID.toText value == input -> Right (ReviewId value)
      | otherwise -> Left "review identity requires canonical encoding"

reviewIdText :: ReviewId -> Text
reviewIdText (ReviewId value) = KindID.toText value

newReviewId :: IO ReviewId
newReviewId = ReviewId <$> KindID.genKindID @"shikigami_practice_review"

instance ToJSON ReviewId where
  toJSON = toJSON . reviewIdText
  toEncoding = toEncoding . reviewIdText

instance FromJSON ReviewId where
  parseJSON = withText "review identity" (either (fail . Text.unpack) pure . parseReviewId)

newtype ResolutionId = ResolutionId (KindID.KindID "shikigami_practice_review_resolution")
  deriving stock (Eq, Ord, Show)

parseResolutionId :: Text -> Either Text ResolutionId
parseResolutionId input = do
  value <- first (const "invalid resolution identity encoding or prefix") (KindID.parseText @"shikigami_practice_review_resolution" input)
  case KindID.checkKindID value of
    Just _ -> Left "resolution identity requires UUIDv7"
    Nothing
      | KindID.toText value == input -> Right (ResolutionId value)
      | otherwise -> Left "resolution identity requires canonical encoding"

resolutionIdText :: ResolutionId -> Text
resolutionIdText (ResolutionId value) = KindID.toText value

newResolutionId :: IO ResolutionId
newResolutionId = ResolutionId <$> KindID.genKindID @"shikigami_practice_review_resolution"

instance ToJSON ResolutionId where
  toJSON = toJSON . resolutionIdText
  toEncoding = toEncoding . resolutionIdText

instance FromJSON ResolutionId where
  parseJSON = withText "resolution identity" (either (fail . Text.unpack) pure . parseResolutionId)
