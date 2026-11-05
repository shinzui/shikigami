{-# LANGUAGE DataKinds #-}
{-# LANGUAGE TypeFamilies #-}

-- | The proposing Flow and the capability it reaches the ledger through. Every
-- operation is one journaled step with a static name, and what an operation
-- journals is a readable value rather than a sealed one: the sealed candidate is
-- re-derived from the journaled envelope, so a run never trusts intake for it.
module Shikigami.Flow.Initiative
  ( Initiative,
    Opened (..),
    Resolution (..),
    open,
    recordSkip,
    recordProposal,
    resolve,
    InitiativeSeed (..),
    InitiativeHooks (..),
    noInitiativeHooks,
    disabledInitiatives,
    InitiativeRuntime (..),
    RepositoryOption (..),
    runInitiative,
    unavailableInitiative,
    proposeWork,
    proposeWorkSlots,
    proposeWorkFlowName,
  )
where

import Data.Aeson (FromJSON, ToJSON, Value, object, toJSON, (.=))
import Data.List.NonEmpty (NonEmpty (..))
import Data.List.NonEmpty qualified as NonEmpty
import Data.Text (Text)
import Data.Time (UTCTime, getCurrentTime)
import Effectful (Dispatch (Dynamic), DispatchOf, Eff, Effect, IOE, liftIO, (:>))
import Effectful.Dispatch.Dynamic (interpret, send)
import GHC.Generics (Generic)
import Hasql.Transaction (Transaction)
import Keiro.Workflow (StepName (..), Workflow, WorkflowId, step)
import Kiroku.Store.Effect (Store)
import Kiroku.Store.Transaction (runTransaction)
import Shikigami.Activity (ActivityEnvelope (..))
import Shikigami.Agent.DeclarationValue (DeclarationCoordinate, declarationCoordinate)
import Shikigami.Agent.Name (AgentName)
import Shikigami.Agent.Principal (AgentIdentity, AgentPrincipal)
import Shikigami.Decision.Contract (DecisionSlot, failureCode)
import Shikigami.Duration (Duration, durationTime, remainingDuration)
import Shikigami.Execution.Resources qualified as Resources
import Shikigami.Flow.Acknowledgement (Ack (..), Acknowledgement, awaitAckWithin)
import Shikigami.Flow.Decision (Decision, decide, decisionSlot, proposeAlias, proposeStep)
import Shikigami.Flow.Objectives (Objectives)
import Shikigami.Flow.Objectives qualified as Objectives
import Shikigami.Initiative.Ledger qualified as Ledger
import Shikigami.Initiative.Notice (acceptanceAsk)
import Shikigami.Initiative.Prefilter (prefilter)
import Shikigami.Initiative.Settings
import Shikigami.Initiative.Source (observe)
import Shikigami.Initiative.Template (objectiveRequest)
import Shikigami.Initiative.Types hiding (NotActionable)
import Shikigami.Initiative.Types qualified as Types
import Shikigami.Objective.Operation qualified as Operation
import Shikigami.Objective.Types (ObjectiveError (ObjectiveDenied), ObjectiveId, Receipt (..))
import Shikigami.Program.Decision.Initiative (Verdict (..), assessmentInput, validateAssessment)
import Shikigami.Repository (RepositoryId)
import Shikigami.StateRevision (parseRevision)

data Initiative :: Effect where
  Open :: Initiative m (Either SkipReason Opened)
  RecordSkip :: Opened -> SkipReason -> Initiative m ()
  RecordProposal :: Opened -> Assessment -> Initiative m (Either SkipReason ProposalView)
  Resolve :: Opened -> ProposalView -> Resolution -> Initiative m (Either RefusalKind ProposalView)

type instance DispatchOf Initiative = Dynamic

-- | A candidate worth one evaluation, what the operator offers it, and who is
-- observing. Nothing here came from the observed text except the excerpt.
data Opened = Opened
  { candidate :: !Candidate,
    allowance :: !ObserverAllowance,
    repositories :: !(NonEmpty (RepositoryId, Text)),
    at :: !UTCTime,
    agent :: !AgentName,
    observer :: !AgentPrincipal
  }

data Resolution
  = AcceptedWith !ObjectiveId
  | RejectedByPerson
  | ExpiredUnanswered
  | RefusedBecause !RefusalKind
  deriving stock (Eq, Show)

open :: (Initiative :> es) => Eff es (Either SkipReason Opened)
open = send Open

recordSkip :: (Initiative :> es) => Opened -> SkipReason -> Eff es ()
recordSkip opened reason = send (RecordSkip opened reason)

recordProposal :: (Initiative :> es) => Opened -> Assessment -> Eff es (Either SkipReason ProposalView)
recordProposal opened assessment = send (RecordProposal opened assessment)

resolve :: (Initiative :> es) => Opened -> ProposalView -> Resolution -> Eff es (Either RefusalKind ProposalView)
resolve opened proposal resolution = send (Resolve opened proposal resolution)

-- | Bounded tags only: nothing here carries an identifier, excerpt or error text.
data InitiativeHooks = InitiativeHooks
  { onCandidate :: !(Text -> Maybe Text -> IO ()),
    onProposal :: !(Text -> IO ()),
    onRefusal :: !(Text -> IO ())
  }

noInitiativeHooks :: InitiativeHooks
noInitiativeHooks = InitiativeHooks (\_ _ -> pure ()) (\_ -> pure ()) (\_ -> pure ())

-- | The process-lifetime half of the runtime. It never crosses a journal.
data InitiativeSeed = InitiativeSeed
  { settings :: !(Maybe InitiativeSettings),
    repositories :: ![RepositoryOption],
    hooks :: !InitiativeHooks
  }

disabledInitiatives :: InitiativeSeed
disabledInitiatives = InitiativeSeed Nothing [] noInitiativeHooks

data RepositoryOption = RepositoryOption
  { repository :: !RepositoryId,
    description :: !Text
  }
  deriving stock (Eq, Show, Generic)
  deriving anyclass (ToJSON, FromJSON)

-- | The per-run half. The identity is the run's recorded one and the envelope is
-- the journaled trigger payload: neither can be supplied by a Flow body.
data InitiativeRuntime = InitiativeRuntime
  { seed :: !InitiativeSeed,
    identity :: !AgentIdentity,
    activity :: !ActivityEnvelope,
    agent :: !AgentName,
    run :: !WorkflowId
  }

-- | What @initiative-open@ retains: the allowance and catalog this run is bound
-- to, even if the settings change while it is parked for a week.
data OpenAdmission = OpenAdmission
  { allowance :: !ObserverAllowance,
    repositories :: ![RepositoryOption],
    at :: !UTCTime
  }
  deriving stock (Eq, Show, Generic)
  deriving anyclass (ToJSON, FromJSON)

runInitiative :: (Workflow :> es, Store :> es, IOE :> es) => InitiativeRuntime -> Eff (Initiative : es) a -> Eff es a
runInitiative runtime = interpret \_ -> \case
  Open -> do
    recorded <- step (StepName "initiative-open") (openStep runtime)
    pure (recorded >>= rederive runtime)
  RecordSkip opened reason ->
    step (StepName "initiative-skip") do
      let facts = candidateFacts opened.candidate
      runTransaction (Ledger.recordSkipTx facts.observer opened.at Nothing (Right (reason, facts.observed)))
      liftIO (runtime.seed.hooks.onCandidate (verdictOf reason) (Just (skipReasonText reason)))
  RecordProposal opened assessment ->
    step (StepName "initiative-proposal") (proposalStep runtime opened assessment)
  Resolve opened proposal resolution ->
    step (StepName "initiative-resolve") (resolveStep runtime opened proposal resolution)

verdictOf :: SkipReason -> Text
verdictOf = \case
  Types.NotActionable -> "not-actionable"
  _ -> "skipped"

-- | The sealed candidate is rebuilt from journaled values by the pure functions
-- intake used, so a replay and the original run cannot disagree.
rederive :: InitiativeRuntime -> OpenAdmission -> Either SkipReason Opened
rederive runtime admission = do
  observed <- observe admission.at runtime.activity
  candidate <- prefilter admission.allowance observed
  repositories <- maybe (Left NoRepositories) Right (NonEmpty.nonEmpty [(option.repository, option.description) | option <- admission.repositories])
  pure
    Opened
      { candidate,
        allowance = admission.allowance,
        repositories,
        at = admission.at,
        agent = runtime.agent,
        observer = admission.allowance.principal
      }

openStep :: (Store :> es, IOE :> es) => InitiativeRuntime -> Eff es (Either SkipReason OpenAdmission)
openStep runtime = do
  now <- liftIO getCurrentTime
  case runtime.seed.settings of
    Nothing -> pure (Left NoObserverAllowance)
    Just configured -> case resolveAllowance configured runtime.identity of
      Left reason -> pure (Left reason)
      Right allowance -> do
        result <- runTransaction (admitTx runtime allowance now)
        liftIO case result of
          Left reason -> runtime.seed.hooks.onCandidate (verdictOf reason) (Just (skipReasonText reason))
          Right _ -> runtime.seed.hooks.onCandidate "evaluating" Nothing
        pure result

-- | Pre-filter, then owner, then attention, in one transaction under the
-- observer's anchor. Spending the evaluation slot is the last thing it does.
admitTx :: InitiativeRuntime -> ObserverAllowance -> UTCTime -> Transaction (Either SkipReason OpenAdmission)
admitTx runtime allowance now =
  case observe now runtime.activity of
    Left reason -> do
      Ledger.recordSkipTx allowance.principal now Nothing (Left (reason, runtime.activity.activityId))
      pure (Left reason)
    Right observed -> case prefilter allowance observed of
      Left reason -> skip reason observed
      Right candidate
        | null runtime.seed.repositories -> skip NoRepositories observed
        | otherwise -> do
            Ledger.recordCandidateTx candidate runtime.run now
            owner <- Ledger.checkOwner allowance.principal observed.subject now
            case owner of
              Left _ -> skip OwnerUnknown observed
              Right (Left reason) -> skip reason observed
              Right (Right ()) -> do
                usage <- Ledger.checkWindows allowance (Just observed.activity) now
                case usage.exhausted of
                  Ledger.EvaluationsAt _ : _ -> skip EvaluationsExhausted observed
                  Ledger.ProposalsAt _ : _ -> skip ProposalsExhausted observed
                  Ledger.NotificationsAt _ : _ -> skip NotificationsExhausted observed
                  [] -> do
                    Ledger.markEvaluationStartedTx allowance.principal observed.activity now
                    pure (Right OpenAdmission {allowance, repositories = runtime.seed.repositories, at = now})
  where
    skip reason observed = do
      Ledger.recordSkipTx allowance.principal now Nothing (Right (reason, observed))
      pure (Left reason)

proposalStep :: (Store :> es, IOE :> es) => InitiativeRuntime -> Opened -> Assessment -> Eff es (Either SkipReason ProposalView)
proposalStep runtime opened assessment = do
  proposal <- liftIO newProposalId
  now <- liftIO getCurrentTime
  let facts = candidateFacts opened.candidate
      sealed = assessmentFacts assessment
      requested =
        RequestedAuthority
          { repository = sealed.repository,
            actionClass = sealed.actionClass,
            limits = mempty :: Resources.Limits,
            objectiveWindow = remainingDuration 0
          }
  result <- runTransaction do
    usage <- Ledger.checkWindows opened.allowance (Just facts.observed.activity) now
    case [() | Ledger.ProposalsAt _ <- usage.exhausted] of
      _ : _ -> do
        Ledger.recordSkipTx facts.observer now Nothing (Right (ProposalsExhausted, facts.observed))
        pure (Left ProposalsExhausted)
      [] -> do
        receipt <- Ledger.recordProposalTx proposal opened.candidate assessment requested now opened.allowance.proposalExpiry runtime.run
        case receipt of
          Left _ -> pure (Left ProposalsExhausted)
          Right ledger -> case ledger.disposition of
            Ledger.Converged -> do
              Ledger.recordSkipTx facts.observer now Nothing (Right (AlreadyProposed ledger.proposalId, facts.observed))
              pure (Left (AlreadyProposed ledger.proposalId))
            Ledger.Created -> do
              Ledger.markCandidateProposedTx facts.observer facts.observed.activity ledger.proposalId
              Ledger.recordNotificationTx ledger.proposalId now
              stored <- Ledger.readProposal ledger.proposalId
              pure case stored of
                Right (Just row) -> Right (proposalView row)
                _ -> Left ProposalsExhausted
  liftIO case result of
    Left reason -> runtime.seed.hooks.onCandidate (verdictOf reason) (Just (skipReasonText reason))
    Right view -> do
      runtime.seed.hooks.onCandidate "proposed" Nothing
      runtime.seed.hooks.onProposal (proposalStatusTag view.status)
  pure result

resolveStep :: (Store :> es, IOE :> es) => InitiativeRuntime -> Opened -> ProposalView -> Resolution -> Eff es (Either RefusalKind ProposalView)
resolveStep runtime opened view resolution = do
  now <- liftIO getCurrentTime
  let status = case resolution of
        AcceptedWith objective -> Accepted objective
        RejectedByPerson -> Rejected now
        ExpiredUnanswered -> Expired now
        RefusedBecause kind -> Refused kind
  case (parseProposalId view.proposalId, parseRevision view.revision) of
    (Right proposal, Right expected) -> do
      outcomeOf <- runTransaction do
        outcome <- Ledger.resolveProposal proposal expected status now opened.allowance.rejectionSuppression
        case outcome of
          Left _ -> pure (Left AcceptanceFailed)
          Right _ ->
            Ledger.readProposal proposal >>= \case
              Right (Just row) -> pure (Right (proposalView row))
              _ -> pure (Left AcceptanceFailed)
      liftIO case outcomeOf of
        Right stored -> runtime.seed.hooks.onProposal (proposalStatusTag stored.status)
        Left kind -> runtime.seed.hooks.onRefusal (refusalKindText kind)
      pure outcomeOf
    _ -> pure (Left AcceptanceFailed)

-- | Installed where the patch is absent and in one-off runs: nothing can observe.
unavailableInitiative :: (Workflow :> es) => Eff (Initiative : es) a -> Eff es a
unavailableInitiative = interpret \_ -> \case
  Open -> do
    recorded <- step (StepName "initiative-open") (pure noAllowance)
    pure (Left (either id (const NoObserverAllowance) recorded))
  RecordSkip _ _ -> pure ()
  RecordProposal _ _ -> pure (Left NoObserverAllowance)
  Resolve _ _ _ -> pure (Left AcceptanceFailed)

noAllowance :: Either SkipReason OpenAdmission
noAllowance = Left NoObserverAllowance

proposeWorkFlowName :: DeclarationCoordinate "flow"
proposeWorkFlowName = declarationCoordinate "propose-work"

proposeWorkSlots :: [DecisionSlot]
proposeWorkSlots = [decisionSlot proposeStep [proposeAlias]]

-- | Observe, assess once, propose, and wait for a person. Nothing here funds,
-- staffs or starts work, and nothing observed can change what is created.
proposeWork :: (Initiative :> es, Decision :> es, Acknowledgement :> es, Objectives :> es) => Value -> Eff es Value
proposeWork _payload =
  open >>= \case
    Left reason -> pure (skipped reason)
    Right opened -> do
      let permitted = allActionClasses
          input = assessmentInput opened.candidate opened.repositories permitted
      output <- decide proposeStep proposeAlias input
      case validateAssessment opened.candidate opened.repositories permitted output of
        Left failure -> terminal opened (DecisionRefused (failureCode failure))
        Right (NotActionable _) -> terminal opened Types.NotActionable
        Right (Actionable assessment) ->
          recordProposal opened assessment >>= \case
            Left reason -> pure (skipped reason)
            Right proposal -> awaitAcceptance opened proposal
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

-- | The two scopes are nominal on purpose. This is the one place a proposal's
-- expiry becomes an approval deadline.
approvalWindow :: Duration "initiative-proposal" -> Duration "approval"
approvalWindow = remainingDuration . durationTime
