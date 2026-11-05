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
    AdmissionDecision (..),
    Funded (..),
    open,
    recordSkip,
    recordProposal,
    resolve,
    reserve,
    fund,
    launch,
    failAdmission,
    InitiativeSeed (..),
    InitiativeHooks (..),
    noInitiativeHooks,
    disabledInitiatives,
    InitiativeRuntime (..),
    AdmissionPatch (..),
    RepositoryOption (..),
    runInitiative,
    unavailableInitiative,
    proposeWork,
    proposeWorkSlots,
    proposeWorkFlowName,
  )
where

import Control.Lens ((&), (.~))
import Data.Aeson (FromJSON, ToJSON, Value, object, toJSON, (.=))
import Data.Foldable (toList)
import Data.Generics.Labels ()
import Data.List.NonEmpty (NonEmpty (..))
import Data.List.NonEmpty qualified as NonEmpty
import Data.Text (Text)
import Data.Text qualified as Text
import Data.Time (UTCTime, getCurrentTime)
import Effectful (Dispatch (Dynamic), DispatchOf, Eff, Effect, IOE, liftIO, (:>))
import Effectful.Dispatch.Dynamic (interpret, send)
import GHC.Generics (Generic)
import Hasql.Transaction (Transaction)
import Keiro.Workflow (StepName (..), Workflow, WorkflowId (..), step)
import Kiroku.Store.Effect (Store)
import Kiroku.Store.Transaction (runTransaction)
import Shikigami.Activity (ActivityEnvelope (..))
import Shikigami.Agent.Decl (AgentDecl (..), IdentityDecl (..))
import Shikigami.Agent.DeclarationValue (DeclarationCoordinate, declarationCoordinate, declarationCoordinateText)
import Shikigami.Agent.Name (AgentName, agentNameText)
import Shikigami.Agent.Principal (AgentIdentity (VerifiedIdentity), AgentPrincipal, compatibilityIdentity, mkAgentPrincipal, resolveAgentIdentity)
import Shikigami.Agent.Run.Key (runKeyWithPrefix)
import Shikigami.Agent.RunJob (RunJob (..), RunRouteKind (AgentWorkflowRoute), runJobWorkflowId)
import Shikigami.Decision.Contract (DecisionSlot, failureCode, versionedDigest)
import Shikigami.Directory qualified as Directory
import Shikigami.Duration (Duration, durationTime, remainingDuration)
import Shikigami.Execution.Identity (ExecutionRootId)
import Shikigami.Execution.Resources qualified as Resources
import Shikigami.Execution.ResourcesStore (allocateRootForWorkflow)
import Shikigami.Flow.Acknowledgement (Ack (..), Acknowledgement, awaitAckWithin)
import Shikigami.Flow.Capability (Sink, emitSignalTo)
import Shikigami.Flow.Decision (Decision, decide, decisionSlot, proposeAlias, proposeStep)
import Shikigami.Flow.Objectives (Objectives)
import Shikigami.Flow.Objectives qualified as Objectives
import Shikigami.Initiative.Ledger qualified as Ledger
import Shikigami.Initiative.Notice (acceptanceAsk, admissionNotice, noticeSink)
import Shikigami.Initiative.Policy (Reservation (..))
import Shikigami.Initiative.Policy qualified as Policy
import Shikigami.Initiative.Prefilter (prefilter)
import Shikigami.Initiative.Settings
import Shikigami.Initiative.Source (observe)
import Shikigami.Initiative.Template (admissionRequest, deliverAssignment, instructionsFor, objectiveRequest)
import Shikigami.Initiative.Types hiding (NotActionable, Pending)
import Shikigami.Initiative.Types qualified as Types
import Shikigami.Objective.Association qualified as Association
import Shikigami.Objective.Command qualified as Command
import Shikigami.Objective.Operation qualified as Operation
import Shikigami.Objective.Reference (ObjectiveAssociation (..))
import Shikigami.Objective.Types
  ( AccessPrincipal (RecordedAgent),
    AssignmentDraft (..),
    AssignmentState (Pending),
    ObjectiveError (ObjectiveDenied),
    ObjectiveId,
    ObjectiveSettings,
    Receipt (..),
    Role (Coordinator),
    parseInstructions,
  )
import Shikigami.Program.Decision.Initiative (Verdict (..), assessmentInput, validateAssessment)
import Shikigami.Repository (RepositoryId)
import Shikigami.StateRevision (parseRevision)
import Shikigami.Trigger.Enqueue (addressedRunJob, enqueueRunJobTx)

data Initiative :: Effect where
  Open :: Initiative m (Either SkipReason Opened)
  RecordSkip :: Opened -> SkipReason -> Initiative m ()
  RecordProposal :: Opened -> Assessment -> Initiative m (Either SkipReason ProposalView)
  Resolve :: Opened -> ProposalView -> Resolution -> Initiative m (Either RefusalKind ProposalView)
  ReserveAdmission :: Opened -> ProposalView -> Initiative m AdmissionDecision
  Fund :: Opened -> ProposalView -> Reservation -> ObjectiveId -> Initiative m (Either Text Funded)
  Launch :: ProposalView -> Funded -> Initiative m (Either Text Text)
  FailAdmission :: ProposalView -> RefusalKind -> Text -> Initiative m ()

type instance DispatchOf Initiative = Dynamic

-- | A candidate worth one evaluation, what the operator offers it, and who is
-- observing. Nothing here came from the observed text except the excerpt.
data Opened = Opened
  { candidate :: !Candidate,
    allowance :: !ObserverAllowance,
    repositories :: !(NonEmpty (RepositoryId, Text)),
    at :: !UTCTime,
    agent :: !AgentName,
    observer :: !AgentPrincipal,
    -- | What the assessment may choose: every class, or what covering policies permit.
    permitted :: !(NonEmpty ActionClass),
    -- | The standing policies this run may be admitted under, in install order.
    consulted :: ![StandingPolicyId]
  }

-- | The journaled outcome of trying to admit. A refusal is retained in bounded
-- words before the Flow falls back to a person, so nothing is dropped silently.
data AdmissionDecision = Admit !Reservation | HumanPath !(Maybe Text)
  deriving stock (Eq, Show, Generic)
  deriving anyclass (ToJSON, FromJSON)

-- | The coordinator's run, funded and not yet started.
data Funded = Funded
  { rootId :: !ExecutionRootId,
    job :: !RunJob,
    coordinatorIdentity :: !AgentIdentity
  }
  deriving stock (Eq, Show, Generic)
  deriving anyclass (ToJSON, FromJSON)

data Resolution
  = AcceptedWith !ObjectiveId
  | AdmittedUnder !ObjectiveId !StandingPolicyId
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

reserve :: (Initiative :> es) => Opened -> ProposalView -> Eff es AdmissionDecision
reserve opened proposal = send (ReserveAdmission opened proposal)

fund :: (Initiative :> es) => Opened -> ProposalView -> Reservation -> ObjectiveId -> Eff es (Either Text Funded)
fund opened proposal reservation objective = send (Fund opened proposal reservation objective)

launch :: (Initiative :> es) => ProposalView -> Funded -> Eff es (Either Text Text)
launch proposal funded = send (Launch proposal funded)

failAdmission :: (Initiative :> es) => ProposalView -> RefusalKind -> Text -> Eff es ()
failAdmission proposal kind detail = send (FailAdmission proposal kind detail)

-- | Bounded tags only: nothing here carries an identifier, excerpt or error text.
data InitiativeHooks = InitiativeHooks
  { onCandidate :: !(Text -> Maybe Text -> IO ()),
    onProposal :: !(Text -> IO ()),
    onAdmission :: !(Text -> IO ()),
    onRefusal :: !(Text -> IO ())
  }

noInitiativeHooks :: InitiativeHooks
noInitiativeHooks = InitiativeHooks (\_ _ -> pure ()) (\_ -> pure ()) (\_ -> pure ()) (\_ -> pure ())

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
    run :: !WorkflowId,
    -- | Whether this run's journal is past the admission patch. A policy can only
    -- narrow or admit where it is.
    admission :: !AdmissionPatch,
    directory :: !Directory.DirectoryHandle,
    declarations :: ![AgentDecl],
    objectiveSettings :: !ObjectiveSettings
  }

data AdmissionPatch = AdmissionAbsent | AdmissionPresent
  deriving stock (Eq, Show)

-- | What @initiative-open@ retains: the allowance and catalog this run is bound
-- to, even if the settings change while it is parked for a week.
data OpenAdmission = OpenAdmission
  { allowance :: !ObserverAllowance,
    repositories :: ![RepositoryOption],
    at :: !UTCTime,
    permitted :: ![ActionClass],
    consulted :: ![StandingPolicyId]
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
      liftIO (reportSkip runtime reason)
  RecordProposal opened assessment ->
    step (StepName "initiative-proposal") (proposalStep runtime opened assessment)
  Resolve opened proposal resolution ->
    step (StepName "initiative-resolve") (resolveStep runtime opened proposal resolution)
  ReserveAdmission opened proposal ->
    step (StepName "initiative-admit") (admitStep runtime opened proposal)
  Fund _ proposal reservation objective ->
    step (StepName "initiative-fund") (fundStep runtime proposal reservation objective)
  Launch proposal funded ->
    step (StepName "initiative-launch") do
      launched <- launchStep runtime proposal funded
      liftIO (either (const (pure ())) (const (runtime.seed.hooks.onAdmission "launched")) launched)
      pure launched
  FailAdmission proposal kind detail ->
    step (StepName "initiative-admission-failed") do
      now <- liftIO getCurrentTime
      liftIO do
        runtime.seed.hooks.onRefusal (refusalKindText kind)
        runtime.seed.hooks.onAdmission "refused"
      case parseProposalId proposal.proposalId of
        Left _ -> pure ()
        Right identifier -> runTransaction (Policy.recordAdmissionStage identifier (Policy.AdmissionFailed kind detail) now)

-- | A full window is a visible refusal as well as a skip.
reportSkip :: InitiativeRuntime -> SkipReason -> IO ()
reportSkip runtime reason = do
  runtime.seed.hooks.onCandidate (verdictOf reason) (Just (skipReasonText reason))
  case reason of
    EvaluationsExhausted -> runtime.seed.hooks.onRefusal (skipReasonText reason)
    ProposalsExhausted -> runtime.seed.hooks.onRefusal (skipReasonText reason)
    NotificationsExhausted -> runtime.seed.hooks.onRefusal (skipReasonText reason)
    _ -> pure ()

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
  permitted <- maybe (Left NoRepositories) Right (NonEmpty.nonEmpty admission.permitted)
  pure
    Opened
      { candidate,
        allowance = admission.allowance,
        repositories,
        at = admission.at,
        agent = runtime.agent,
        observer = admission.allowance.principal,
        permitted,
        consulted = admission.consulted
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
          Left reason -> reportSkip runtime reason
          -- The consumer reported this candidate as evaluating when it enqueued the run.
          Right _ -> pure ()
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
                    covering <- case runtime.admission of
                      AdmissionAbsent -> pure []
                      AdmissionPresent -> map Policy.policyFacts <$> Policy.coveringPolicies allowance.principal observed.kind now
                    pure (Right (narrowed runtime allowance now covering))
  where
    skip reason observed = do
      Ledger.recordSkipTx allowance.principal now Nothing (Right (reason, observed))
      pure (Left reason)

-- | Under a covering policy the model is offered only what that policy could admit.
narrowed :: InitiativeRuntime -> ObserverAllowance -> UTCTime -> [Policy.PolicyFacts] -> OpenAdmission
narrowed runtime allowance now covering =
  OpenAdmission
    { allowance,
      repositories = case covering of
        [] -> runtime.seed.repositories
        _ -> case [option | option <- runtime.seed.repositories, option.repository `elem` concatMap (toList . (.input.repositories)) covering] of
          [] -> runtime.seed.repositories
          overlap -> overlap,
      at = now,
      permitted = case covering of
        [] -> NonEmpty.toList allActionClasses
        _ -> [choice | choice <- NonEmpty.toList allActionClasses, choice `elem` concatMap (toList . (.input.actionClasses)) covering],
      consulted = map (.policyId) covering
    }

-- | Fresh under each policy's row lock. A retried step finds what it already took.
admitStep :: (Store :> es, IOE :> es) => InitiativeRuntime -> Opened -> ProposalView -> Eff es AdmissionDecision
admitStep runtime opened proposal = do
  now <- liftIO getCurrentTime
  decision <- case parseProposalId proposal.proposalId of
    Left _ -> pure (HumanPath (Just "proposal id is unreadable"))
    Right identifier -> runTransaction (firstAdmitted identifier now Nothing opened.consulted)
  liftIO case decision of
    HumanPath (Just detail) -> runtime.seed.hooks.onRefusal (Text.takeWhile (/= ':') detail)
    _ -> pure ()
  pure decision
  where
    firstAdmitted _ _ refusal [] = pure (HumanPath (renderRefusal <$> refusal))
    firstAdmitted identifier now refusal (policy : rest) =
      Policy.reserveAdmission identifier policy proposal.requested now >>= \case
        Right reservation -> pure (Admit reservation)
        Left (Policy.AlreadyAdmitted _) ->
          Policy.readReservation identifier >>= \case
            Just reservation -> pure (Admit reservation)
            Nothing -> pure (HumanPath (Just "already-admitted"))
        Left other -> firstAdmitted identifier now (Just (maybe other id refusal)) rest
    renderRefusal refusal = case refusal of
      Policy.PolicyGone reason -> Policy.admissionRefusalText refusal <> ": " <> Policy.policyRefusalText reason
      Policy.AdmissionsExhausted used -> Policy.admissionRefusalText refusal <> ": " <> Text.pack (show used)
      Policy.TotalsExhausted dimension -> Policy.admissionRefusalText refusal <> ": " <> Text.pack (show dimension)
      other -> Policy.admissionRefusalText other

-- | Enroll the coordinator's own root, derived from the proposal, so a retried
-- step recovers the same root and job. The policy grants the coordinator nothing:
-- its identity comes from its own declaration and current directory state.
fundStep :: (Store :> es, IOE :> es) => InitiativeRuntime -> ProposalView -> Reservation -> ObjectiveId -> Eff es (Either Text Funded)
fundStep runtime proposal reservation objective = do
  now <- liftIO getCurrentTime
  identity <- liftIO (coordinatorIdentityOf runtime reservation.coordinator)
  case identity >>= \admitted -> (admitted,) <$> resolveAgentIdentity admitted of
    Left problem -> pure (Left problem)
    Right (coordinatorIdentity, resolvedCoordinator) -> do
      let key = runKeyWithPrefix ('i' :| "nitiative-admission-v1:") (versionedDigest "shikigami.initiative-admission/1" (object ["proposal" .= proposal.proposalId]))
          job =
            addressedRunJob now coordinatorIdentity reservation.coordinator AgentWorkflowRoute (admissionRequest runtime.agent proposal objective) key
              & #objective .~ Just (ObjectiveAssociation objective deliverAssignment)
      allocated <- allocateRootForWorkflow resolvedCoordinator reservation.coordinator (runJobWorkflowId job) Nothing reservation.envelope
      case allocated of
        Left refusal -> pure (Left (Text.pack (show refusal)))
        Right root -> do
          case parseProposalId proposal.proposalId of
            Left _ -> pure ()
            Right identifier -> runTransaction do
              Policy.recordAdmissionStage identifier (Policy.Created objective) now
              Policy.recordAdmissionStage identifier (Policy.Funded root) now
          pure (Right Funded {rootId = root, job = job & #executionRootId .~ Just root, coordinatorIdentity})

coordinatorIdentityOf :: InitiativeRuntime -> AgentName -> IO (Either Text AgentIdentity)
coordinatorIdentityOf runtime name =
  case [declared | declared <- runtime.declarations, declared.name == name] of
    [] -> pure (Left "coordinator is not declared")
    declared : _ -> do
      let principal = (\IdentityDecl {principal = claimed} -> claimed) <$> declared.identity
      decision <- Directory.consultLifecycle runtime.directory principal (agentNameText name)
      pure case decision of
        Directory.AllowRun (Just record) -> VerifiedIdentity <$> mkAgentPrincipal (declarationCoordinateText record.principalId)
        Directory.AllowRun Nothing -> Right (compatibilityIdentity name)
        Directory.SkipRun _ reason -> Left reason
        Directory.UnknownPrincipal identifier -> Left ("unknown principal: " <> identifier)
        Directory.DirectoryUnavailable problem -> Left problem

-- | Register the run with the objective owner and enqueue it as one fact: the
-- owner checks membership and assignment under its own lock, acting for the
-- proposer that created the objective. The job's workflow id is its key, so a
-- replayed send is the same instance.
launchStep :: (Store :> es, IOE :> es) => InitiativeRuntime -> ProposalView -> Funded -> Eff es (Either Text Text)
launchStep runtime proposal funded = do
  now <- liftIO getCurrentTime
  let workflow = runJobWorkflowId funded.job
  case funded.job.objective of
    Nothing -> pure (Left "the coordinator job names no objective")
    Just reference -> runTransaction do
      associated <- Association.admitRunTx Association.NewRun runtime.objectiveSettings (RecordedAgent runtime.identity) funded.coordinatorIdentity workflow reference
      case associated of
        Left problem -> pure (Left problem)
        Right () -> do
          _ <- enqueueRunJobTx funded.job
          case parseProposalId proposal.proposalId of
            Left _ -> pure ()
            Right identifier -> do
              Policy.recordAdmissionStage identifier Policy.Staffed now
              Policy.recordAdmissionStage identifier (Policy.Launched workflow) now
          pure (Right workflow.unWorkflowId)

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
    Left reason -> reportSkip runtime reason
    Right view -> do
      runtime.seed.hooks.onCandidate "proposed" Nothing
      runtime.seed.hooks.onProposal (proposalStatusTag view.status)
  pure result

resolveStep :: (Store :> es, IOE :> es) => InitiativeRuntime -> Opened -> ProposalView -> Resolution -> Eff es (Either RefusalKind ProposalView)
resolveStep runtime opened view resolution = do
  now <- liftIO getCurrentTime
  let status = case resolution of
        AcceptedWith objective -> Accepted objective
        AdmittedUnder objective policy -> Admitted objective policy
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
  ReserveAdmission _ _ -> pure (HumanPath Nothing)
  Fund _ _ _ _ -> pure (Left "initiatives are unavailable")
  Launch _ _ -> pure (Left "initiatives are unavailable")
  FailAdmission _ _ _ -> pure ()

noAllowance :: Either SkipReason OpenAdmission
noAllowance = Left NoObserverAllowance

proposeWorkFlowName :: DeclarationCoordinate "flow"
proposeWorkFlowName = declarationCoordinate "propose-work"

proposeWorkSlots :: [DecisionSlot]
proposeWorkSlots = [decisionSlot proposeStep [proposeAlias]]

-- | Observe, assess once, propose, and wait for a person. Nothing here funds,
-- staffs or starts work, and nothing observed can change what is created.
proposeWork :: (Initiative :> es, Decision :> es, Acknowledgement :> es, Objectives :> es, Sink :> es) => Value -> Eff es Value
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
admitWork :: (Initiative :> es, Acknowledgement :> es, Objectives :> es, Sink :> es) => Opened -> ProposalView -> Reservation -> Eff es Value
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
                      _ <- emitSignalTo (declarationCoordinate "initiative-admitted") recipient (noticeSink recipient) (admissionNotice opened.agent opened.observer proposal created.objectiveId reservation.policyId)
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
