{-# LANGUAGE DataKinds #-}

-- | What a person is told about unrequested work. Pure, and built only from the
-- proposal's view: evidence is linked by coordinate, and no excerpt text appears
-- because the body stays with the channel that published it.
module Shikigami.Initiative.Notice
  ( acceptanceAsk,
    admissionNotice,
    noticeSink,
    nobodyRequested,
  )
where

import Data.Aeson (Value, object, toJSON, (.=))
import Data.Text (Text)
import Data.Text qualified as Text
import Data.Time.Format.ISO8601 (iso8601Show)
import Shikigami.Activity.Coordinate (activityCoordinate, activityCoordinateText)
import Shikigami.Agent.Approval (ApprovalChannel (ViaKizashi), ApprovalRequest (..))
import Shikigami.Agent.Decl (Priority (Normal), RecipientFrom (Actor), SignalType (Notification), Sink (..))
import Shikigami.Agent.DeclarationValue (DeclarationCoordinate, parseSignalImportance)
import Shikigami.Agent.Name (AgentName, agentNameText)
import Shikigami.Agent.Principal (AgentPrincipal, principalText)
import Shikigami.Execution.Coordinate (executionDigestText)
import Shikigami.Initiative.Types
import Shikigami.Objective.Keys (ObservedSource (..))
import Shikigami.Objective.Types (ObjectiveId, objectiveIdText)

nobodyRequested :: Text
nobodyRequested = "Nobody requested this work."

-- | The notifier renders at most 1000 characters of this prompt and then the
-- accept and reject commands carrying the opaque token, so the fixed sentences
-- come first and the model-authored outcome is bounded. The full view travels in
-- the context. The channel here is a placeholder: the run's approval policy
-- overrides it, so nothing observed can choose where the ask goes.
acceptanceAsk :: AgentName -> AgentPrincipal -> ProposalView -> ApprovalRequest
acceptanceAsk agent principal view =
  ApprovalRequest
    { prompt =
        Text.intercalate
          "\n"
          ( [ "Unrequested proposal from agent " <> agentNameText agent <> " (" <> principalText principal <> "). " <> nobodyRequested,
              "To stop further proposals: remove this principal's observer allowance from the initiatives settings and restart the worker.",
              "Proposal " <> view.proposalId <> " expires at " <> Text.pack (iso8601Show view.expiresAt) <> ".",
              "Outcome: " <> Text.take 240 view.assessment.outcome,
              "Repository: " <> view.assessment.repository <> ". Action: " <> view.assessment.actionClass <> ". Confidence: " <> Text.pack (show view.assessment.confidence) <> "."
            ]
              <> map evidenceLine (take 2 view.assessment.evidence)
          ),
      context = toJSON view,
      channel = ViaKizashi
    }

evidenceLine :: EvidenceRef -> Text
evidenceLine evidence =
  "Evidence: "
    <> activityCoordinateText evidence.subject.source
    <> " / "
    <> activityCoordinateText evidence.subject.subjectKind
    <> " / "
    <> Text.take 80 (activityCoordinateText evidence.subject.subjectId)
    <> " / "
    <> Text.take 80 (activityCoordinateText evidence.activity)
    <> " at "
    <> Text.pack (iso8601Show evidence.occurredAt)
    <> " "
    <> executionDigestText evidence.digest

-- | An admitted objective tells someone even though nobody had to answer.
admissionNotice :: AgentName -> AgentPrincipal -> ProposalView -> ObjectiveId -> StandingPolicyId -> Value
admissionNotice agent principal view objective policy =
  object
    [ "summary" .= ("Agent " <> agentNameText agent <> " (" <> principalText principal <> ") admitted unrequested work under a standing policy. " <> nobodyRequested),
      "outcome" .= Text.take 240 view.assessment.outcome,
      "repository" .= view.assessment.repository,
      "actionClass" .= view.assessment.actionClass,
      "proposal" .= view.proposalId,
      "objective" .= objectiveIdText objective,
      "policy" .= standingPolicyIdText policy,
      "stop" .= ("shikigami proposals policy revoke " <> standingPolicyIdText policy <> " --expected-revision N" :: Text),
      "cancel" .= ("shikigami objectives command " <> objectiveIdText objective :: Text)
    ]

-- | The closed form of an admission notice. Its recipient is passed explicitly,
-- so the actor field here selects nothing.
noticeSink :: DeclarationCoordinate "recipient" -> Sink
noticeSink recipient =
  KizashiSignal
    { source = activityCoordinate "shinzui/shikigami",
      signalType = Notification,
      priority = Normal,
      importance = either (error . Text.unpack) id (parseSignalImportance 60),
      recipientFrom = Actor,
      defaultRecipient = Just recipient,
      intentTemplate = "Unrequested work was admitted under a standing policy. Nobody requested it.",
      extraContextTags = ["unrequested-work"]
    }
