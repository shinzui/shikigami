-- | Protected, application-owned structured answers. Call evidence stays with
-- the actual transport receipt and is never synthesized when reading a snapshot.
module Shikigami.Decision.Answer
  ( AnswerSnapshot,
    answerBlocks,
    answerBytes,
    captureAnswer,
    maxAnswerBytes,
  )
where

import Baikai.Content (AssistantContent (AssistantData), DataContent)
import Data.Aeson (FromJSON (..), Result (..), ToJSON (..), Value, encode, fromJSON, object, toJSON, withObject, (.:), (.=))
import Data.ByteString.Lazy qualified as LBS
import Data.Text (Text)
import Data.Vector qualified as Vector

newtype AnswerSnapshot = AnswerSnapshot [DataContent]
  deriving stock (Eq)

instance Show AnswerSnapshot where show _ = "AnswerSnapshot <protected>"

maxAnswerBytes :: Integer
maxAnswerBytes = 1048576

answerBlocks :: AnswerSnapshot -> [DataContent]
answerBlocks (AnswerSnapshot blocks) = blocks

answerBytes :: AnswerSnapshot -> Integer
answerBytes = toInteger . LBS.length . encode

instance ToJSON AnswerSnapshot where
  toJSON (AnswerSnapshot blocks) = object ["format" .= (1 :: Int), "blocks" .= blocks]

instance FromJSON AnswerSnapshot where
  parseJSON = withObject "structured answer snapshot" \o -> do
    version <- o .: "format"
    if version /= (1 :: Int) then fail "unsupported structured answer version" else pure ()
    blocks <- o .: "blocks"
    let snapshot = AnswerSnapshot blocks
    if null blocks || length blocks > 256 || answerBytes snapshot > maxAnswerBytes
      then fail "structured answer exceeds retained bounds"
      else pure snapshot

captureAnswer :: Vector.Vector AssistantContent -> Either Text (Maybe AnswerSnapshot)
captureAnswer content =
  case [dat | AssistantData dat <- Vector.toList content] of
    [] -> Right Nothing
    blocks -> case fromJSON (toJSON (AnswerSnapshot blocks)) of
      Success snapshot -> Right (Just snapshot)
      Error _ -> Left "structured answer is malformed or exceeds retained bounds"
