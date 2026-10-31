-- | Checked continuing-session admission values.
module Shikigami.WorkerSession.Input
  ( SessionLimit (..),
    MaximumSessions,
    MaximumAssignments,
    MailboxLimit,
    maximumSessionCapacity,
    InstructionText,
    parseInstructionText,
    instructionText,
  )
where

import Data.Aeson (FromJSON (..), ToJSON (..))
import Data.ByteString qualified as ByteString
import Data.Text (Text)
import Data.Text qualified as Text
import Data.Text.Encoding qualified as TextEncoding

class SessionLimit a where
  sessionLimit :: a -> Int
  parseSessionLimit :: Integer -> Either Text a

bounded :: Text -> (Int -> a) -> Int -> Integer -> Either Text a
bounded name constructor upper value
  | value >= 1 && value <= toInteger upper = Right (constructor (fromInteger value))
  | otherwise = Left (name <> " must be within 1.." <> Text.pack (show upper))

newtype MaximumSessions = MaximumSessions Int
  deriving stock (Eq, Ord, Show)

instance SessionLimit MaximumSessions where
  sessionLimit (MaximumSessions value) = value
  parseSessionLimit = bounded "maximum sessions" MaximumSessions 128

instance ToJSON MaximumSessions where
  toJSON = toJSON . sessionLimit
  toEncoding = toEncoding . sessionLimit

instance FromJSON MaximumSessions where
  parseJSON value = parseJSON value >>= either (fail . Text.unpack) pure . parseSessionLimit

newtype MaximumAssignments = MaximumAssignments Int
  deriving stock (Eq, Ord, Show)

instance SessionLimit MaximumAssignments where
  sessionLimit (MaximumAssignments value) = value
  parseSessionLimit = bounded "maximum assignments" MaximumAssignments 1000

instance ToJSON MaximumAssignments where
  toJSON = toJSON . sessionLimit
  toEncoding = toEncoding . sessionLimit

instance FromJSON MaximumAssignments where
  parseJSON value = parseJSON value >>= either (fail . Text.unpack) pure . parseSessionLimit

newtype MailboxLimit = MailboxLimit Int
  deriving stock (Eq, Ord, Show)

instance SessionLimit MailboxLimit where
  sessionLimit (MailboxLimit value) = value
  parseSessionLimit = bounded "mailbox limit" MailboxLimit 128

instance ToJSON MailboxLimit where
  toJSON = toJSON . sessionLimit
  toEncoding = toEncoding . sessionLimit

instance FromJSON MailboxLimit where
  parseJSON value = parseJSON value >>= either (fail . Text.unpack) pure . parseSessionLimit

maximumSessionCapacity :: MaximumSessions
maximumSessionCapacity = MaximumSessions 128

newtype InstructionText = InstructionText Text
  deriving stock (Eq)

instance Show InstructionText where
  show _ = "InstructionText <protected>"

parseInstructionText :: Text -> Either Text InstructionText
parseInstructionText value
  | Text.null (Text.strip value) = Left "instruction must not be blank"
  | ByteString.length (TextEncoding.encodeUtf8 value) > 1048576 = Left "instruction exceeds the payload ceiling"
  | otherwise = Right (InstructionText value)

instructionText :: InstructionText -> Text
instructionText (InstructionText value) = value

instance ToJSON InstructionText where
  toJSON = toJSON . instructionText
  toEncoding = toEncoding . instructionText

instance FromJSON InstructionText where
  parseJSON value = parseJSON value >>= either (fail . Text.unpack) pure . parseInstructionText
