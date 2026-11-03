{-# LANGUAGE DataKinds #-}

module Shikigami.Program.Decision.JudgmentExample
  ( Ticket (..),
    Category (..),
    PredicateResult (..),
    ChoiceResult (..),
    ScoreResult (..),
    TicketJudgment (..),
    judgmentProgram,
    judgmentProgramWithSettings,
    pinnedParams,
  )
where

import Data.Aeson (FromJSON (..), ToJSON (..), Value (String), defaultOptions, genericParseJSON, object, withText, (.=))
import Data.Map.Strict (Map)
import Data.Map.Strict qualified as Map
import Data.Text (Text)
import Data.Text qualified as Text
import Data.Vector qualified as Vector
import GHC.Generics (Generic)
import Shikigami.Decision.Contract (versionedDigest)
import Shikigami.Program.Decision
import Shikumi.Adapter (ToPrompt)
import Shikumi.Decision qualified as D
import Shikumi.Decision.Setting (DecisionSetting (..))
import Shikumi.Program (Params, Program (..), emptyParams, setDecisionSetting)
import Shikumi.Schema (FromModel, ToSchema, Validatable)
import Shikumi.Signature (mkSignature)

data Ticket = Ticket {ticket :: !Text}
  deriving stock (Eq, Show, Generic)
  deriving anyclass (FromJSON, ToJSON, FromModel, ToSchema, Validatable, ToPrompt)

data Category = Billing | Technical
  deriving stock (Eq, Show, Generic)

instance ToJSON Category where
  toJSON Billing = String "billing"
  toJSON Technical = String "technical"

instance FromJSON Category where
  parseJSON = withText "ticket category" \case
    "billing" -> pure Billing
    "technical" -> pure Technical
    _ -> fail "unknown ticket category"

instance D.ChoiceOptions Category where
  choiceOptions = [("billing", Billing, Just "Billing or payment issue"), ("technical", Technical, Just "Product or availability issue")]

data Judgments = Judgments
  { urgent :: !D.Noul,
    category :: !(D.Choice Category),
    severity :: !(D.Score '["Minor", "Disruptive", "Blocking"])
  }
  deriving stock (Generic)
  deriving anyclass (FromModel, ToSchema, Validatable, ToPrompt, ToJSON)

data PredicateResult = PredicateResult
  {value :: !Bool, probability :: !Double, confidence :: !Double}
  deriving stock (Eq, Show, Generic)
  deriving anyclass (FromJSON, ToJSON)

data ChoiceResult = ChoiceResult
  {value :: !Category, probabilities :: !(Map Text Double), confidence :: !(Maybe Double)}
  deriving stock (Eq, Show, Generic)
  deriving anyclass (FromJSON, ToJSON)

data ScoreResult = ScoreResult
  {value :: !Double, level :: !Int, label :: !Text, probabilities :: !(Map Text Double), confidence :: !(Maybe Double)}
  deriving stock (Eq, Show, Generic)
  deriving anyclass (FromJSON, ToJSON)

data TicketJudgment = TicketJudgment
  {urgent :: !PredicateResult, category :: !ChoiceResult, severity :: !ScoreResult}
  deriving stock (Eq, Show, Generic)
  deriving anyclass (ToJSON)

instance FromJSON TicketJudgment where
  parseJSON value = do
    result <- genericParseJSON defaultOptions value
    either (fail . Text.unpack) pure (validateJudgment result)

pinnedParams :: Params
pinnedParams =
  setDecisionSetting "urgent" (NoulSetting 0.8) $
    setDecisionSetting "category" (ChoiceSetting (Map.fromList [("billing", 4), ("technical", 1)])) $
      setDecisionSetting "severity" (ScoreSetting [0.75, 1.75]) emptyParams

judgmentProgram :: RegisteredProgram Ticket TicketJudgment
judgmentProgram = judgmentProgramWithSettings "1" pinnedParams

judgmentProgramWithSettings :: Text -> Params -> RegisteredProgram Ticket TicketJudgment
judgmentProgramWithSettings version settings =
  either (error . show) id $
    registerJudgmentProgram
      "ticket-judgment"
      version
      (versionedDigest "shikigami.ticket-judgment-code/1" (String "closed-ticket-fields-and-local-derivation-v1"))
      "ticket/1"
      "ticket-judgment/1"
      "ticket-validator/1"
      ("ticket-derive/" <> version)
      (object ["derivation" .= ("explicit-noul-choice-score-settings/1" :: Text)])
      (FMap retain (Predict (mkSignature "Judge whether this ticket is urgent, classify its issue category and assess its severity using only the supplied ticket.") settings))
      jsonResultCodec
      validateTicket
      validateJudgment
  where
    validateTicket input
      | Text.null (Text.strip input.ticket) || Text.length input.ticket > 65536 = Left "ticket must be nonblank and bounded"
      | otherwise = Right input

retain :: Judgments -> TicketJudgment
retain input =
  TicketJudgment
    (PredicateResult input.urgent.value input.urgent.probability input.urgent.confidence)
    (ChoiceResult input.category.value input.category.probabilities input.category.confidence)
    ( ScoreResult
        input.severity.value
        input.severity.level
        (Map.findWithDefault "invalid" input.severity.level labels)
        (Map.fromList [(Text.pack (show n), p) | (n, p) <- zip [0 :: Int ..] (Vector.toList input.severity.levelProbabilities)])
        input.severity.confidence
    )
  where
    labels = Map.fromList [(0, "Minor"), (1, "Disruptive"), (2, "Blocking")]

validateJudgment :: TicketJudgment -> Either Text TicketJudgment
validateJudgment result
  | unit result.urgent.probability
      && unit result.urgent.confidence
      && Map.keys result.category.probabilities == ["billing", "technical"]
      && distribution result.category.probabilities
      && maybe True unit result.category.confidence
      && Map.keys result.severity.probabilities == ["0", "1", "2"]
      && distribution result.severity.probabilities
      && maybe True unit result.severity.confidence
      && finite result.severity.value
      && result.severity.value >= 0
      && result.severity.value <= 2
      && lookup result.severity.level [(0, "Minor"), (1, "Disruptive"), (2, "Blocking")] == Just result.severity.label =
      Right result
  | otherwise = Left "invalid retained ticket judgment"
  where
    finite n = not (isNaN n || isInfinite n)
    unit n = finite n && n >= 0 && n <= 1
    distribution ps = all unit ps && sum ps > 0
