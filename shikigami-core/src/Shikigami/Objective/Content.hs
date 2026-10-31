-- | Checked objective prose. These values retain plain JSON strings and do
-- not expose protected content through Show or unchecked constructors.
module Shikigami.Objective.Content
  ( Title,
    parseTitle,
    titleText,
    Goal,
    parseGoal,
    goalText,
    Instructions,
    parseInstructions,
    instructionsText,
    CriterionDescription,
    parseCriterionDescription,
    criterionDescriptionText,
    AttestationStatement,
    parseAttestationStatement,
    attestationStatementText,
    DecisionNote,
    parseDecisionNote,
    decisionNoteText,
    AssumptionNote,
    parseAssumptionNote,
    assumptionNoteText,
    NextAction,
    parseNextAction,
    nextActionText,
    CompletionLimitation,
    parseCompletionLimitation,
    completionLimitationText,
  )
where

import Data.Aeson (FromJSON (..), ToJSON (..), withText)
import Data.Text (Text)
import Data.Text qualified as Text

checkedText :: Text -> Int -> Int -> (Text -> value) -> Text -> Either Text value
checkedText label least greatest construct value
  | size >= least && size <= greatest = Right (construct value)
  | otherwise = Left (label <> " must contain " <> Text.pack (show least) <> ".." <> Text.pack (show greatest) <> " characters")
  where
    size = Text.length value

newtype Title = Title Text
  deriving stock (Eq, Ord)

instance Show Title where show _ = "Title <protected>"

parseTitle :: Text -> Either Text Title
parseTitle = checkedText "title" 1 512 Title

titleText :: Title -> Text
titleText (Title value) = value

instance ToJSON Title where
  toJSON = toJSON . titleText
  toEncoding = toEncoding . titleText

instance FromJSON Title where
  parseJSON = withText "title" (either (fail . Text.unpack) pure . parseTitle)

newtype Goal = Goal Text
  deriving stock (Eq, Ord)

instance Show Goal where show _ = "Goal <protected>"

parseGoal :: Text -> Either Text Goal
parseGoal = checkedText "goal" 1 32768 Goal

goalText :: Goal -> Text
goalText (Goal value) = value

instance ToJSON Goal where
  toJSON = toJSON . goalText
  toEncoding = toEncoding . goalText

instance FromJSON Goal where
  parseJSON = withText "goal" (either (fail . Text.unpack) pure . parseGoal)

newtype Instructions = Instructions Text
  deriving stock (Eq, Ord)

instance Show Instructions where show _ = "Instructions <protected>"

parseInstructions :: Text -> Either Text Instructions
parseInstructions = checkedText "instructions" 0 32768 Instructions

instructionsText :: Instructions -> Text
instructionsText (Instructions value) = value

instance ToJSON Instructions where
  toJSON = toJSON . instructionsText
  toEncoding = toEncoding . instructionsText

instance FromJSON Instructions where
  parseJSON = withText "instructions" (either (fail . Text.unpack) pure . parseInstructions)

newtype CriterionDescription = CriterionDescription Text
  deriving stock (Eq, Ord)

instance Show CriterionDescription where show _ = "CriterionDescription <protected>"

parseCriterionDescription :: Text -> Either Text CriterionDescription
parseCriterionDescription = checkedText "criterionDescription" 1 4096 CriterionDescription

criterionDescriptionText :: CriterionDescription -> Text
criterionDescriptionText (CriterionDescription value) = value

instance ToJSON CriterionDescription where
  toJSON = toJSON . criterionDescriptionText
  toEncoding = toEncoding . criterionDescriptionText

instance FromJSON CriterionDescription where
  parseJSON = withText "criterionDescription" (either (fail . Text.unpack) pure . parseCriterionDescription)

newtype AttestationStatement = AttestationStatement Text
  deriving stock (Eq, Ord)

instance Show AttestationStatement where show _ = "AttestationStatement <protected>"

parseAttestationStatement :: Text -> Either Text AttestationStatement
parseAttestationStatement = checkedText "attestationStatement" 1 4096 AttestationStatement

attestationStatementText :: AttestationStatement -> Text
attestationStatementText (AttestationStatement value) = value

instance ToJSON AttestationStatement where
  toJSON = toJSON . attestationStatementText
  toEncoding = toEncoding . attestationStatementText

instance FromJSON AttestationStatement where
  parseJSON = withText "attestationStatement" (either (fail . Text.unpack) pure . parseAttestationStatement)

newtype DecisionNote = DecisionNote Text
  deriving stock (Eq, Ord)

instance Show DecisionNote where show _ = "DecisionNote <protected>"

parseDecisionNote :: Text -> Either Text DecisionNote
parseDecisionNote = checkedText "decisionNote" 0 4096 DecisionNote

decisionNoteText :: DecisionNote -> Text
decisionNoteText (DecisionNote value) = value

instance ToJSON DecisionNote where
  toJSON = toJSON . decisionNoteText
  toEncoding = toEncoding . decisionNoteText

instance FromJSON DecisionNote where
  parseJSON = withText "decisionNote" (either (fail . Text.unpack) pure . parseDecisionNote)

newtype AssumptionNote = AssumptionNote Text
  deriving stock (Eq, Ord)

instance Show AssumptionNote where show _ = "AssumptionNote <protected>"

parseAssumptionNote :: Text -> Either Text AssumptionNote
parseAssumptionNote = checkedText "assumptionNote" 0 4096 AssumptionNote

assumptionNoteText :: AssumptionNote -> Text
assumptionNoteText (AssumptionNote value) = value

instance ToJSON AssumptionNote where
  toJSON = toJSON . assumptionNoteText
  toEncoding = toEncoding . assumptionNoteText

instance FromJSON AssumptionNote where
  parseJSON = withText "assumptionNote" (either (fail . Text.unpack) pure . parseAssumptionNote)

newtype NextAction = NextAction Text
  deriving stock (Eq, Ord)

instance Show NextAction where show _ = "NextAction <protected>"

parseNextAction :: Text -> Either Text NextAction
parseNextAction = checkedText "nextAction" 0 4096 NextAction

nextActionText :: NextAction -> Text
nextActionText (NextAction value) = value

instance ToJSON NextAction where
  toJSON = toJSON . nextActionText
  toEncoding = toEncoding . nextActionText

instance FromJSON NextAction where
  parseJSON = withText "nextAction" (either (fail . Text.unpack) pure . parseNextAction)

newtype CompletionLimitation = CompletionLimitation Text
  deriving stock (Eq, Ord)

instance Show CompletionLimitation where show _ = "CompletionLimitation <protected>"

parseCompletionLimitation :: Text -> Either Text CompletionLimitation
parseCompletionLimitation = checkedText "completionLimitation" 0 4096 CompletionLimitation

completionLimitationText :: CompletionLimitation -> Text
completionLimitationText (CompletionLimitation value) = value

instance ToJSON CompletionLimitation where
  toJSON = toJSON . completionLimitationText
  toEncoding = toEncoding . completionLimitationText

instance FromJSON CompletionLimitation where
  parseJSON = withText "completionLimitation" (either (fail . Text.unpack) pure . parseCompletionLimitation)
