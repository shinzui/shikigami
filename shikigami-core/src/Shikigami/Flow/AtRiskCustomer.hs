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
import Effectful (Eff, (:>))
import GHC.Generics (Generic)
import Keiro.Workflow (StepName (..), Workflow, step)
import Kioku.Api.Types (MemoryRecord (..))
import Numeric.Natural (Natural)
import Shikigami.Activity (ActivityEnvelope (..), Subject (..))
import Shikigami.Agent.Approval (ApprovalChannel (ViaDanwa), ApprovalRequest (..))
import Shikigami.Agent.Decl (Priority (High, Urgent), RecipientFrom (AreaOwner), SignalType (Alert), Sink (..))
import Shikigami.Flow.Acknowledgement (Ack (..), Acknowledgement, awaitAck)
import Shikigami.Flow.Capability (Activity, Memory, MemoryQuery (..), currentActivity, emitSignal, recall, remember)
import Shikigami.Flow.Capability qualified as Capability

data RiskVerdict = RiskVerdict
  { level :: !Text,
    rationale :: !Text,
    ticketId :: !Text
  }
  deriving stock (Eq, Show, Generic)
  deriving anyclass (ToJSON, FromJSON)

-- Lifecycle correspondence checked by @Shikigami.FlowLifecycleSpec@: a low
-- verdict is @ClassifyLowRisk@; a high verdict begins with @ClassifyHighRisk@;
-- an acknowledged wait adds @Acknowledge@; and a timeout adds
-- @DeadlineExpired@. The concrete declined result is not in the illustrative
-- transducer's command alphabet, so the conformance claim deliberately covers
-- only the three sequences that transducer models.
atRiskCustomerFlow ::
  (Workflow :> es, Memory :> es, Capability.Sink :> es, Activity :> es, Acknowledgement :> es) =>
  Value ->
  Eff es Value
atRiskCustomerFlow payload = do
  activity <- currentActivity
  prior <- recall "risk-history" (riskQuery activity)
  verdict <- step (StepName "classify") (pure (classifyRisk activity prior payload))
  if level verdict /= "high"
    then pure (toJSON verdict)
    else do
      _ <- emitSignal "alert" (alertFor verdict activity) (toJSON verdict)
      ack <- awaitAck (StepName "await-ack") (ackRequest verdict activity)
      case ack of
        Acknowledged answer -> do
          _ <- remember "acknowledged" (acknowledgedNote verdict answer)
          pure (resolvedValue verdict answer)
        Declined reason -> do
          _ <- remember "declined" (declinedNote verdict reason)
          pure (declinedValue verdict reason)
        TimedOut -> do
          _ <- emitSignal "escalate" (escalationFor verdict activity) (toJSON verdict)
          _ <- remember "escalated" (escalatedNote verdict)
          pure (escalatedValue verdict)

-- | Classify this activity's risk from what it says and what the agent already
-- learned about the same subject.
--
-- The memory rule is deliberately simple and auditable: a recalled learning
-- that names this subject and the word @escalated@ means this customer has been
-- here before, so an otherwise unremarkable message is high risk. It is the
-- teaching example's demonstration that memory changes a decision, and it has
-- to be checkable without a model.
--
-- The prior rule is checked first because it is the more specific claim: when
-- both fire, the rationale should say /why this subject in particular/ rather
-- than repeating the generic one. The low rationale is byte-identical to what
-- it was, so a fresh database still produces the verdict the workflow tests pin.
classifyRisk :: ActivityEnvelope -> [MemoryRecord] -> Value -> RiskVerdict
classifyRisk activity prior input =
  let ticket = subjectId (subject activity)
      textBlob = Text.toLower (Text.unwords (textFields input <> textFields (payload activity)))
      risks = riskFields input <> riskFields (payload activity)
      highByEnrichment =
        any (Text.isInfixOf "churn risk" . Text.toLower) risks
          && any (== "negative") (sentimentFields input <> sentimentFields (payload activity))
      highByText = any (`Text.isInfixOf` textBlob) ["cancel", "churn", "leaving", "lawsuit"]
      highByMemory = any (mentionsPriorEscalation ticket) prior
   in RiskVerdict
        { level = if highByMemory || highByEnrichment || highByText then "high" else "low",
          rationale =
            if highByMemory
              then "prior escalation on this subject: customer relationship at risk"
              else
                if highByEnrichment || highByText
                  then "customer relationship at risk"
                  else "no high-risk signal detected",
          ticketId = ticket
        }

-- | Whether a recalled memory says this subject has been escalated before.
mentionsPriorEscalation :: Text -> MemoryRecord -> Bool
mentionsPriorEscalation ticket MemoryRecord {content} =
  let lowered = Text.toLower content
   in Text.toLower ticket `Text.isInfixOf` lowered && "escalated" `Text.isInfixOf` lowered

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
