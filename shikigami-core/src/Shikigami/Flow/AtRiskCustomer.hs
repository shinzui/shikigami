module Shikigami.Flow.AtRiskCustomer
  ( RiskVerdict (..),
    atRiskCustomerFlow,
    classifyRisk,
  )
where

import Data.Aeson (FromJSON, ToJSON, Value (..), object, toJSON, (.=))
import Data.Aeson.Key qualified as Key
import Data.Aeson.KeyMap qualified as KeyMap
import Data.Foldable (toList)
import Data.Text (Text)
import Data.Text qualified as Text
import Data.Time (NominalDiffTime)
import Effectful (Eff, IOE, (:>))
import GHC.Generics (Generic)
import Keiro.Workflow (StepName (..), Workflow, step)
import Kiroku.Store.Effect (Store)
import Numeric.Natural (Natural)
import Shikigami.Activity (ActivityEnvelope (..), Subject (..))
import Shikigami.Agent.Approval (ApprovalChannel (ViaDanwa), ApprovalEnv, ApprovalRequest (..))
import Shikigami.Agent.Decl (Priority (High, Urgent), RecipientFrom (AreaOwner), SignalType (Alert), Sink (..))
import Shikigami.Flow.Acknowledgement (Ack (..), awaitAcknowledgement)
import Shikigami.Flow.Capability (Activity, Memory, MemoryQuery (..), currentActivity, emitSignal, recall, remember)
import Shikigami.Flow.Capability qualified as Capability

data RiskVerdict = RiskVerdict
  { level :: !Text,
    rationale :: !Text,
    ticketId :: !Text
  }
  deriving stock (Eq, Show, Generic)
  deriving anyclass (ToJSON, FromJSON)

atRiskCustomerFlow ::
  (Workflow :> es, Store :> es, IOE :> es, Memory :> es, Capability.Sink :> es, Activity :> es) =>
  ApprovalEnv ->
  NominalDiffTime ->
  Value ->
  Eff es Value
atRiskCustomerFlow approval deadline payload = do
  activity <- currentActivity
  prior <- recall (riskQuery activity)
  verdict <- step (StepName "classify") (pure (classifyRisk activity prior payload))
  if level verdict /= "high"
    then pure (toJSON verdict)
    else do
      _ <- emitSignal (alertFor verdict activity) (toJSON verdict)
      ack <- awaitAcknowledgement approval (StepName "await-ack") (ackRequest verdict activity) deadline
      case ack of
        Acknowledged answer -> do
          _ <- remember (acknowledgedNote verdict answer)
          pure (resolvedValue verdict answer)
        Declined reason -> do
          _ <- remember (declinedNote verdict reason)
          pure (declinedValue verdict reason)
        TimedOut -> do
          _ <- emitSignal (escalationFor verdict activity) (toJSON verdict)
          _ <- remember (escalatedNote verdict)
          pure (escalatedValue verdict)

classifyRisk :: ActivityEnvelope -> [a] -> Value -> RiskVerdict
classifyRisk activity _prior input =
  let textBlob = Text.toLower (Text.unwords (textFields input <> textFields (payload activity)))
      risks = riskFields input <> riskFields (payload activity)
      highByEnrichment =
        any (Text.isInfixOf "churn risk" . Text.toLower) risks
          && any (== "negative") (sentimentFields input <> sentimentFields (payload activity))
      highByText = any (`Text.isInfixOf` textBlob) ["cancel", "churn", "leaving", "lawsuit"]
      high = highByEnrichment || highByText
   in RiskVerdict
        { level = if high then "high" else "low",
          rationale =
            if high
              then "customer relationship at risk"
              else "no high-risk signal detected",
          ticketId = subjectId (subject activity)
        }

riskQuery :: ActivityEnvelope -> MemoryQuery
riskQuery ActivityEnvelope {subject} =
  MemoryQuery ("customer risk history for " <> subjectId subject)

alertFor :: RiskVerdict -> ActivityEnvelope -> Sink
alertFor verdict activity =
  riskSignal
    "Relationship at risk: {verdict.rationale}"
    High
    80
    [ "verb:relationship.at_risk",
      "subject:" <> activitySubjectType activity,
      "activity:" <> activityId activity,
      "ticket:" <> ticketId verdict
    ]

escalationFor :: RiskVerdict -> ActivityEnvelope -> Sink
escalationFor verdict activity =
  riskSignal
    "Escalate unacknowledged at-risk customer: {verdict.rationale}"
    Urgent
    95
    [ "verb:relationship.escalation_required",
      "subject:" <> activitySubjectType activity,
      "activity:" <> activityId activity,
      "ticket:" <> ticketId verdict
    ]

riskSignal :: Text -> Priority -> Natural -> [Text] -> Sink
riskSignal intentTemplate priority importance extraContextTags =
  KizashiSignal
    { source = "shinzui/shikigami",
      signalType = Alert,
      priority,
      importance,
      recipientFrom = AreaOwner,
      defaultRecipient = Just "role_relationship_owner",
      intentTemplate,
      extraContextTags
    }

activitySubjectType :: ActivityEnvelope -> Text
activitySubjectType ActivityEnvelope {subject = Subject {subjectType}} = subjectType

ackRequest :: RiskVerdict -> ActivityEnvelope -> ApprovalRequest
ackRequest verdict activity =
  ApprovalRequest
    { prompt = "Acknowledge at-risk customer alert?",
      context =
        object
          [ "verdict" .= verdict,
            "activity_id" .= activityId activity,
            "ticket_id" .= ticketId verdict
          ],
      channel = ViaDanwa
    }

acknowledgedNote :: RiskVerdict -> Value -> Value
acknowledgedNote verdict answer =
  object
    [ "summary" .= ("at-risk customer alert acknowledged" :: Text),
      "verdict" .= verdict,
      "acknowledgement" .= answer
    ]

declinedNote :: RiskVerdict -> Text -> Value
declinedNote verdict reason =
  object
    [ "summary" .= ("at-risk customer alert declined: " <> reason),
      "verdict" .= verdict
    ]

escalatedNote :: RiskVerdict -> Value
escalatedNote verdict =
  object
    [ "summary" .= ("at-risk customer alert escalated after acknowledgement timeout" :: Text),
      "verdict" .= verdict
    ]

resolvedValue :: RiskVerdict -> Value -> Value
resolvedValue verdict answer =
  object
    [ "status" .= ("acknowledged" :: Text),
      "verdict" .= verdict,
      "acknowledgement" .= answer
    ]

declinedValue :: RiskVerdict -> Text -> Value
declinedValue verdict reason =
  object
    [ "status" .= ("declined" :: Text),
      "verdict" .= verdict,
      "reason" .= reason
    ]

escalatedValue :: RiskVerdict -> Value
escalatedValue verdict =
  object
    [ "status" .= ("escalated" :: Text),
      "verdict" .= verdict
    ]

textFields :: Value -> [Text]
textFields = \case
  Object o -> stringsAt ["text"] o <> stringsAt ["payload", "text"] o
  String text -> [text]
  _ -> []

sentimentFields :: Value -> [Text]
sentimentFields = \case
  Object o ->
    Text.toLower <$> (stringsAt ["sentiment"] o <> stringsAt ["enrichment", "sentiment"] o <> stringsAt ["payload", "enrichment", "sentiment"] o)
  _ -> []

riskFields :: Value -> [Text]
riskFields = \case
  Object o -> stringsAt ["risks"] o <> stringsAt ["enrichment", "risks"] o <> stringsAt ["payload", "enrichment", "risks"] o
  _ -> []

stringsAt :: [Text] -> KeyMap.KeyMap Value -> [Text]
stringsAt path object' =
  case valueAt path object' of
    Just (String text) -> [text]
    Just (Array values) -> [text | String text <- toList values]
    _ -> []

valueAt :: [Text] -> KeyMap.KeyMap Value -> Maybe Value
valueAt [] _ = Nothing
valueAt [key] object' = KeyMap.lookup (Key.fromText key) object'
valueAt (key : rest) object' = do
  Object child <- KeyMap.lookup (Key.fromText key) object'
  valueAt rest child
