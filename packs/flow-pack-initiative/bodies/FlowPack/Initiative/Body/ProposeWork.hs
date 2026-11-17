{-# LANGUAGE DataKinds #-}

-- | The proposing flow: observe, assess once, propose, and wait for a person
-- or admit under a standing policy.
module FlowPack.Initiative.Body.ProposeWork
  ( proposeWork,
  )
where

import Data.Aeson (Value, object, toJSON, (.=))
import Data.Text (Text)
import Data.Text qualified as Text
import FlowPack.Initiative.Capability
import FlowPack.Initiative.Notice (acceptanceAsk, admissionNotice, noticeSink)
import FlowPack.Initiative.Program.Assessment (Verdict (..), assessmentInput, validateAssessment)
import FlowPack.Initiative.Reservation (Reservation (..))
import FlowPack.Initiative.Settings
import FlowPack.Initiative.Template (deliverAssignment, instructionsFor, objectiveRequest)
import FlowPack.Initiative.Types hiding (NotActionable, Pending)
import FlowPack.Initiative.Types qualified as Types
import Shikigami.Decision.Contract (failureCode)
import Shikigami.Duration (Duration, durationTime, remainingDuration)
import Shikigami.Execution.Resources (Envelope (..))
import Shikigami.Flow.Decision (Decision, decide)
import Shikigami.Flow.Objectives (Objectives)
import Shikigami.Flow.Objectives qualified as Objectives
import Shikigami.Flow.Sdk (Ack (..), Acknowledgement, Eff, SinkCapability, StepName (..), awaitAckWithin, declarationCoordinate, emitDirected, sinkOutput, toRecipient, (:>))
import Shikigami.Objective.Command qualified as Command
import Shikigami.Objective.Operation qualified as Operation
import Shikigami.Objective.Types
  ( AccessPrincipal (RecordedAgent),
    AssignmentDraft (..),
    AssignmentState (Pending),
    ObjectiveError (ObjectiveDenied),
    Receipt (..),
    Role (Coordinator),
    parseInstructions,
  )

-- | Observe, assess once, propose, and wait for a person. Nothing here funds,
-- staffs or starts work, and nothing observed can change what is created.
proposeWork :: (Initiative :> es, Decision :> es, Acknowledgement :> es, Objectives :> es, SinkCapability :> es) => Value -> Eff es Value
proposeWork _payload =
  open >>= \case
    Left reason -> pure (skipped reason)
    Right opened -> do
      let input = assessmentInput opened.candidate opened.repositories opened.permitted
      output <- decide proposeStep proposeAlias input
      case validateAssessment opened.candidate opened.repositories opened.permitted output of
        Left failure -> terminal opened (DecisionRefused (failureCode failure))
        Right (NotActionable _) -> terminal opened Types.NotActionable
        Right (Actionable assessment) ->
          recordProposal opened assessment >>= \case
            Left reason -> pure (skipped reason)
            Right proposal ->
              reserve opened proposal >>= \case
                HumanPath _ -> awaitAcceptance opened proposal
                Admit reservation -> admitWork opened proposal reservation
  where
    terminal opened reason = do
      recordSkip opened reason
      pure (skipped reason)

skipped :: SkipReason -> Value
skipped reason = object ["disposition" .= ("skipped" :: Text), "skip" .= reason]

resolved :: Either RefusalKind ProposalView -> Value
resolved = \case
  Right view -> object ["disposition" .= proposalStatusTag view.status, "proposal" .= toJSON view]
  Left kind -> object ["disposition" .= ("refused" :: Text), "refusal" .= kind]

awaitAcceptance :: (Initiative :> es, Acknowledgement :> es, Objectives :> es) => Opened -> ProposalView -> Eff es Value
awaitAcceptance opened proposal = do
  answer <- awaitAckWithin (StepName "initiative-await-acceptance") (approvalWindow opened.allowance.proposalExpiry) (acceptanceAsk opened.agent opened.observer proposal)
  case answer of
    Declined _ -> resolved <$> resolve opened proposal RejectedByPerson
    TimedOut -> resolved <$> resolve opened proposal ExpiredUnanswered
    Acknowledged _ -> case objectiveRequest opened.agent proposal of
      Left _ -> resolved <$> resolve opened proposal (RefusedBecause AcceptanceFailed)
      Right request ->
        Objectives.create (declarationCoordinate "initiative-accept") request >>= \case
          Right Operation.Reply {result = Operation.ObjectiveCreated receipt} -> resolved <$> resolve opened proposal (AcceptedWith receipt.objectiveId)
          Left ObjectiveDenied -> resolved <$> resolve opened proposal (RefusedBecause CreationDenied)
          _ -> resolved <$> resolve opened proposal (RefusedBecause AcceptanceFailed)

-- | Create, fund, grant, staff, launch, notify. Authority for each step is the
-- owner's own: the proposer's creation grant, the coordinator's declared identity
-- and the objective's commands. Before an objective exists a failure falls back to
-- a person; after, the partial objective stays visible and the proposal is refused.
admitWork :: (Initiative :> es, Acknowledgement :> es, Objectives :> es, SinkCapability :> es) => Opened -> ProposalView -> Reservation -> Eff es Value
admitWork opened proposal reservation =
  case objectiveRequest opened.agent proposal of
    Left problem -> do
      failAdmission proposal AdmissionRefused problem
      awaitAcceptance opened proposal
    Right request ->
      Objectives.create (declarationCoordinate "initiative-admit") request >>= \case
        Right Operation.Reply {result = Operation.ObjectiveCreated receipt} -> staff receipt
        Left ObjectiveDenied -> do
          failAdmission proposal CreationDenied "objective creation was denied"
          awaitAcceptance opened proposal
        _ -> do
          failAdmission proposal AdmissionRefused "objective creation did not complete"
          awaitAcceptance opened proposal
  where
    staff created =
      fund opened proposal reservation created.objectiveId >>= \case
        Left problem -> refuse problem
        Right funded ->
          Objectives.command (declarationCoordinate "initiative-grant") created.objectiveId created.revision (Command.GrantMember (RecordedAgent funded.coordinatorIdentity) [Coordinator]) >>= \case
            Right Operation.Reply {result = Operation.ObjectiveUpdated granted} ->
              Objectives.command (declarationCoordinate "initiative-staff") created.objectiveId granted.revision (Command.SetAssignments [deliverDraft funded]) >>= \case
                Right Operation.Reply {result = Operation.ObjectiveUpdated _} ->
                  launch proposal funded >>= \case
                    Left problem -> refuse problem
                    Right _ -> do
                      let KizashiRecipient recipient = opened.allowance.notices
                      _ <- emitDirected (declarationCoordinate "initiative-admitted") (toRecipient recipient (sinkOutput (noticeSink recipient))) (admissionNotice opened.agent opened.observer proposal created.objectiveId reservation.policyId)
                      resolved <$> resolve opened proposal (AdmittedUnder created.objectiveId reservation.policyId)
                _ -> refuse "the objective refused its assignment"
            _ -> refuse "the objective refused its coordinator"
    deliverDraft funded =
      AssignmentDraft
        { assignmentId = deliverAssignment,
          instructions = either (error . Text.unpack) id (parseInstructions (either (const "") (instructionsFor opened.agent proposal) (parseActionClass proposal.assessment.actionClass))),
          dependencies = [],
          owner = funded.coordinatorIdentity,
          state = Pending,
          sessionId = Nothing,
          rootId = Just funded.rootId,
          cutoff = Just reservation.envelope.cutoff
        }
    refuse problem = do
      failAdmission proposal AdmissionRefused problem
      resolved <$> resolve opened proposal (RefusedBecause AdmissionRefused)

-- | The two scopes are nominal on purpose. This is the one place a proposal's
-- expiry becomes an approval deadline.
approvalWindow :: Duration "initiative-proposal" -> Duration "approval"
approvalWindow = remainingDuration . durationTime
