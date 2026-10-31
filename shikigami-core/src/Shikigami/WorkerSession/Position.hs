-- | Assignment pagination has a before-first position; message sequences do not.
module Shikigami.WorkerSession.Position
  ( MessagePosition,
    beforeMessages,
    afterMessage,
    parseMessagePosition,
    messagePositionNumber,
  )
where

import Data.Aeson (FromJSON (..), ToJSON (..))
import Data.Text (Text)
import Data.Text qualified as Text
import Shikigami.StateRevision (StateRevision, parseRevision, revisionNumber)

data MessagePosition = BeforeMessages | AfterMessage !(StateRevision "worker-message")
  deriving stock (Eq, Ord, Show)

beforeMessages :: MessagePosition
beforeMessages = BeforeMessages

afterMessage :: StateRevision "worker-message" -> MessagePosition
afterMessage = AfterMessage

parseMessagePosition :: Integer -> Either Text MessagePosition
parseMessagePosition (-1) = Right BeforeMessages
parseMessagePosition number = AfterMessage <$> parseRevision number

messagePositionNumber :: MessagePosition -> Integer
messagePositionNumber BeforeMessages = -1
messagePositionNumber (AfterMessage number) = revisionNumber number

instance ToJSON MessagePosition where
  toJSON = toJSON . messagePositionNumber
  toEncoding = toEncoding . messagePositionNumber

instance FromJSON MessagePosition where
  parseJSON value = do
    number <- parseJSON value
    either (fail . Text.unpack) pure (parseMessagePosition number)
