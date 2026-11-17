{-# LANGUAGE DataKinds #-}

-- | The at-risk-customer flow body: the repository's teaching example of a
-- durable flow. It classifies a ticket, raises an alert, waits for a person
-- to acknowledge it, and escalates when nobody does.
--
-- This module is in the pack's @bodies@ sublibrary, which depends on
-- @shikigami-core:flow-sdk@ and no other Shikigami component. Everything the
-- body does to the world therefore goes through a kernel capability; it
-- cannot name @IOE@ or the store.
--
-- Every durable label this body journals starts with the pack's name,
-- @examples@, or is a kernel capability label built from a key that does
-- (@recall:examples-risk-history@ and so on). The labels are pinned by
-- @test/golden/labels.txt@.
module FlowPack.Examples.Body.AtRiskCustomer
  ( RiskVerdict (..),
    RiskLevel (..),
    atRiskCustomerFlow,
    atRiskCustomerFlowName,
    classifyRisk,
  )
where

import Data.Aeson (FromJSON (..), ToJSON (..), Value (..), object, toJSON, withText, (.=))
import Data.Aeson.Key qualified as Key
import Data.Aeson.KeyMap qualified as KeyMap
import Data.Foldable (toList)
import Data.Text (Text)
import Data.Text qualified as Text
import GHC.Generics (Generic)
import Kikan.Shikigami.Binding.Outputs
import Kioku.Api.Types (MemoryRecord (..))
import Shikigami.Flow.Sdk

atRiskCustomerFlowName :: DeclarationCoordinate "flow"
atRiskCustomerFlowName = declarationCoordinate "at-risk-customer"

data RiskLevel = HighRisk | LowRisk deriving stock (Eq, Show)

instance ToJSON RiskLevel where
  toJSON HighRisk = String "high"
  toJSON LowRisk = String "low"

instance FromJSON RiskLevel where
  parseJSON = withText "risk level" \case
    "high" -> pure HighRisk
    "low" -> pure LowRisk
    _ -> fail "unknown risk level"

data RiskVerdict = RiskVerdict
  { level :: !RiskLevel,
    rationale :: !Text,
    ticketId :: !(ActivityCoordinate "subject-id")
  }
  deriving stock (Eq, Show, Generic)
  deriving anyclass (ToJSON, FromJSON)

-- Lifecycle correspondence with "FlowPack.Examples.Lifecycle.AtRiskCustomer": a low
-- verdict is @ClassifyLowRisk@; a high verdict begins with @ClassifyHighRisk@;
-- an acknowledged wait adds @Acknowledge@; and a timeout adds
-- @DeadlineExpired@. The concrete declined result is not in the illustrative
-- transducer's command alphabet, so the conformance claim deliberately covers
-- only the three sequences that transducer models.
atRiskCustomerFlow ::
  (Workflow :> es, Memory :> es, SinkCapability :> es, Activity :> es, Acknowledgement :> es) =>
  Value ->
  Eff es Value
atRiskCustomerFlow payload = do
  activity <- currentActivity
  prior <- recall (declarationCoordinate "examples-risk-history") (riskQuery activity)
  verdict <- step (StepName "examples-classify") (pure (classifyRisk activity prior payload))
  if (.level) verdict /= HighRisk
    then pure (toJSON verdict)
    else do
      _ <- emitSignal (declarationCoordinate "examples-alert") ((alertFor verdict activity)) (toJSON verdict)
      ack <- awaitAck (StepName "examples-await-ack") (ackRequest verdict activity)
      case ack of
        Acknowledged answer -> do
          _ <- remember (declarationCoordinate "examples-acknowledged") (acknowledgedNote verdict answer)
          pure (resolvedValue verdict answer)
        Declined reason -> do
          _ <- remember (declarationCoordinate "examples-declined") (declinedNote verdict reason)
          pure (declinedValue verdict reason)
        TimedOut -> do
          _ <- emitSignal (declarationCoordinate "examples-escalate") ((escalationFor verdict activity)) (toJSON verdict)
          _ <- remember (declarationCoordinate "examples-escalated") (escalatedNote verdict)
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
  let ticket = activityCoordinateText ((.subjectId) ((.subject) activity))
      textBlob = Text.toLower (Text.unwords (textFields input <> textFields ((.payload) activity)))
      risks = riskFields input <> riskFields ((.payload) activity)
      highByEnrichment =
        any (Text.isInfixOf "churn risk" . Text.toLower) risks
          && any (== "negative") (sentimentFields input <> sentimentFields ((.payload) activity))
      highByText = any (`Text.isInfixOf` textBlob) ["cancel", "churn", "leaving", "lawsuit"]
      highByMemory = any (mentionsPriorEscalation ticket) prior
   in RiskVerdict
        { level = if highByMemory || highByEnrichment || highByText then HighRisk else LowRisk,
          rationale =
            if highByMemory
              then "prior escalation on this subject: customer relationship at risk"
              else
                if highByEnrichment || highByText
                  then "customer relationship at risk"
                  else "no high-risk signal detected",
          ticketId = (.subjectId) ((.subject) activity)
        }

-- | Whether a recalled memory says this subject has been escalated before.
mentionsPriorEscalation :: Text -> MemoryRecord -> Bool
mentionsPriorEscalation ticket MemoryRecord {content} =
  let lowered = Text.toLower content
   in Text.toLower ticket `Text.isInfixOf` lowered && "escalated" `Text.isInfixOf` lowered

riskQuery :: ActivityEnvelope -> MemoryQuery
riskQuery ActivityEnvelope {subject} =
  MemoryQuery ("customer risk history for " <> activityCoordinateText ((.subjectId) subject))

alertFor :: RiskVerdict -> ActivityEnvelope -> OutputDecl
alertFor verdict activity =
  riskSignal
    "Relationship at risk: {verdict.rationale}"
    High
    (either (error . show) id (parseSignalImportance 80))
    [ "verb:relationship.at_risk",
      "subject:" <> activitySubjectType activity,
      "activity:" <> activityCoordinateText ((.activityId) activity),
      "ticket:" <> activityCoordinateText ((.ticketId) verdict)
    ]

escalationFor :: RiskVerdict -> ActivityEnvelope -> OutputDecl
escalationFor verdict activity =
  riskSignal
    "Escalate unacknowledged at-risk customer: {verdict.rationale}"
    Urgent
    (either (error . show) id (parseSignalImportance 95))
    [ "verb:relationship.escalation_required",
      "subject:" <> activitySubjectType activity,
      "activity:" <> activityCoordinateText ((.activityId) activity),
      "ticket:" <> activityCoordinateText ((.ticketId) verdict)
    ]

riskSignal :: Text -> Priority -> SignalImportance -> [Text] -> OutputDecl
riskSignal intentTemplate priority importance extraContextTags =
  ( kizashiSignalOutput
      KizashiSignalOutput
        { source = activityCoordinate "shinzui/shikigami",
          signalType = Alert,
          priority,
          importance,
          recipientFrom = AreaOwner,
          defaultRecipient = Just (declarationCoordinate "role_relationship_owner"),
          intentTemplate,
          extraContextTags,
          recipient = Nothing
        }
  )

activitySubjectType :: ActivityEnvelope -> Text
activitySubjectType ActivityEnvelope {subject = Subject {kind = subjectType}} = activityCoordinateText subjectType

ackRequest :: RiskVerdict -> ActivityEnvelope -> ApprovalRequest
ackRequest verdict activity =
  ApprovalRequest
    { prompt = "Acknowledge at-risk customer alert?",
      context =
        object
          [ "verdict" .= verdict,
            "activity_id" .= (.activityId) activity,
            "ticket_id" .= (.ticketId) verdict
          ],
      channel = configuredApprovalChannel
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
