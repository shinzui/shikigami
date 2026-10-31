-- | A technical assignment locator derived from its owning workflow/message.
module Shikigami.Execution.AssignmentKey
  ( AssignmentKey,
    parseAssignmentKey,
    assignmentKeyText,
    assignmentIdFor,
    conversationAssignmentIdFor,
  )
where

import Data.Aeson (FromJSON (..), ToJSON (..), object, withText, (.=))
import Data.Text (Text)
import Data.Text qualified as Text
import Shikigami.Decision.Contract (versionedDigest)

newtype AssignmentKey = AssignmentKey Text
  deriving stock (Eq, Ord, Show)

parseAssignmentKey :: Text -> Either Text AssignmentKey
parseAssignmentKey value
  | not (Text.null value) && Text.length value <= 256 = Right (AssignmentKey value)
  | otherwise = Left "assignment key must contain 1..256 characters"

assignmentKeyText :: AssignmentKey -> Text
assignmentKeyText (AssignmentKey value) = value

-- The digest has a fixed bounded representation even for empty/Unicode input.
assignmentIdFor :: Text -> AssignmentKey
assignmentIdFor key = AssignmentKey ("assignment:" <> versionedDigest "shikigami.assignment/1" (toJSON key))

conversationAssignmentIdFor :: Text -> Text -> AssignmentKey
conversationAssignmentIdFor workflow message = assignmentIdFor (versionedDigest "shikigami.conversation-assignment/1" (object ["workflow" .= workflow, "message" .= message]))

instance ToJSON AssignmentKey where
  toJSON = toJSON . assignmentKeyText
  toEncoding = toEncoding . assignmentKeyText

instance FromJSON AssignmentKey where
  parseJSON = withText "assignment key" (either (fail . Text.unpack) pure . parseAssignmentKey)
