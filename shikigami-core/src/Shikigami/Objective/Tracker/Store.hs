{-# LANGUAGE DataKinds #-}

-- | Authenticated command owner for bindings and synchronization. Network reads
-- finish before admission is refreshed and a checked transaction is opened.
module Shikigami.Objective.Tracker.Store where

import Control.Exception (SomeAsyncException, SomeException, fromException, throwIO, try)
import Data.Aeson qualified as Aeson
import Data.Generics.Labels ()
import Data.List (nub)
import Data.Text qualified as Text
import Effectful (Eff)
import Hasql.Transaction (Transaction)
import Shikigami.Execution.Identity (OperationId, operationIdText, operationIdWithPrefix)
import Shikigami.Objective.Authority (Access (..))
import Shikigami.Objective.Capability qualified as Objective
import Shikigami.Objective.Command qualified as OC
import Shikigami.Objective.Store qualified as OStore
import Shikigami.Objective.Tracker.Command
import Shikigami.Objective.Tracker.Config
import Shikigami.Objective.Tracker.Mapping
import Shikigami.Objective.Tracker.Provider qualified as Provider
import Shikigami.Objective.Tracker.Sql qualified as Sql
import Shikigami.Objective.Tracker.Types
import Shikigami.Objective.Types qualified as O
import Shikigami.Prelude hiding (mapped)
import Shikigami.StateRevision

data TrackerHost = TrackerHost
  { objective :: !Objective.ObjectiveHost,
    settings :: !TrackerSettings,
    providerFor :: !(ResourceScope -> IO (Either TrackerError Provider.Provider))
  }
  deriving stock (Generic)

fromObjectiveError :: O.ObjectiveError -> TrackerError
fromObjectiveError = \case
  O.ObjectiveDenied -> TrackerDenied
  O.ObjectiveMissing -> TrackerMissing
  O.ObjectiveUnavailable -> TrackerUnavailable
  O.ObjectiveInvalid reason -> TrackerInvalid reason
  _ -> TrackerConflict

mapped :: (Functor f) => f (Either O.ObjectiveError a) -> f (Either TrackerError a)
mapped = fmap (either (Left . fromObjectiveError) Right)

admit :: TrackerHost -> Aeson.Value -> IO (Either TrackerError Access)
admit host semantic = do
  if isLeft (validateTrackerSettings host.settings)
    then pure (Left TrackerUnavailable)
    else mapped (Objective.admitObjectiveAction host.objective "objective-tracker" semantic)
  where
    isLeft = either (const True) (const False)

requireManage :: Access -> O.Objective -> Transaction ()
requireManage access current = unless (OStore.mayCoordinate access current) (Sql.abort TrackerDenied)

requireOwner :: Access -> O.Objective -> Transaction ()
requireOwner access current = unless (OStore.authorized access current (OC.Public (OC.GrantMember access.actor []))) (Sql.abort TrackerDenied)

query :: (OStore.ObjectiveEffects es, ToJSON a, FromJSON a) => TrackerHost -> O.ObjectiveId -> (Access -> O.Objective -> Transaction a) -> Eff es (Either TrackerError a)
query host objective action = do
  grant <- liftIO (admit host (toJSON ("inspect" :: Text, objective)))
  either (pure . Left) (\access -> mapped (OStore.trackerQuery access objective (action access))) grant

inspectBindings :: (OStore.ObjectiveEffects es) => TrackerHost -> O.ObjectiveId -> Eff es (Either TrackerError [TrackerBinding])
inspectBindings host objective = query host objective (\_ _ -> Sql.bindingsFor objective)

inspectProposals :: (OStore.ObjectiveEffects es) => TrackerHost -> O.ObjectiveId -> TrackerBindingId -> Eff es (Either TrackerError [ImportProposal])
inspectProposals host objective identifier = query host objective \_ _ -> do
  _ <- bindingFor objective identifier
  Sql.proposalsFor identifier

inspectObservations :: (OStore.ObjectiveEffects es) => TrackerHost -> O.ObjectiveId -> TrackerBindingId -> Eff es (Either TrackerError [(Text, TrackerObservation)])
inspectObservations host objective identifier = query host objective \_ _ -> do
  _ <- bindingFor objective identifier
  Sql.observationsFor identifier

inspectPublications :: (OStore.ObjectiveEffects es) => TrackerHost -> O.ObjectiveId -> TrackerBindingId -> Eff es (Either TrackerError [(PublicationIntent, PublicationReceipt)])
inspectPublications host objective identifier = query host objective \_ _ -> do
  _ <- bindingFor objective identifier
  Sql.publicationsFor identifier

bindingFor :: O.ObjectiveId -> TrackerBindingId -> Transaction TrackerBinding
bindingFor objective identifier = do
  binding <- Sql.bindingById identifier
  unless (binding.objectiveId == objective) (Sql.abort TrackerDenied)
  pure binding

provider :: TrackerHost -> ResourceScope -> IO (Either TrackerError Provider.Provider)
provider host scope = do
  case connectionFor host.settings scope of
    Left err -> pure (Left err)
    Right _ ->
      safeNetwork (host.providerFor scope) >>= \case
        Right (Right selected) | selected.capabilities.revision == scope.providerRevision -> pure (Right selected)
        Right (Left err) -> pure (Left err)
        _ -> pure (Left TrackerUnavailable)

readObservation :: Provider.Provider -> ResourceScope -> IO (Either TrackerError TrackerObservation)
readObservation selected scope =
  safeNetwork (selected.readResource scope) >>= \case
    Right (Provider.Observed observation) -> pure (observation <$ validateObservation selected.capabilities scope observation)
    Right Provider.ResourceMissing -> pure (Left TrackerMissing)
    Right Provider.ReadDenied -> pure (Left TrackerDenied)
    _ -> pure (Left TrackerUnavailable)

safeNetwork :: IO a -> IO (Either SomeException a)
safeNetwork action =
  try action >>= \case
    Left exception | Just (_ :: SomeAsyncException) <- fromException exception -> throwIO exception
    outcome -> pure outcome

fingerprintFor :: O.AccessPrincipal -> O.ObjectiveId -> OperationId -> Command -> TrackerDigest "command"
fingerprintFor actor objective operation command = trackerDigest "shikigami.tracker-command/1" (toJSON (TrackerV1, actor, objective, operation, command))

-- Every retry reauthenticates and rechecks present membership before revealing
-- the original immutable receipt; expected revisions are checked afterward.
execute :: (OStore.ObjectiveEffects es) => TrackerHost -> O.ObjectiveId -> OperationId -> Command -> Eff es (Either TrackerError CommandReceipt)
execute _ _ operation _ | not (O.validKey (operationIdText operation)) = pure (Left (TrackerInvalid "invalid tracker operation key"))
execute host objective operation command = do
  grant <- liftIO (admit host (toJSON (objective, operation, command)))
  case grant of
    Left err -> pure (Left err)
    Right access -> do
      let fingerprint = fingerprintFor access.actor objective operation command
          original =
            mapped
              ( OStore.trackerQuery access objective \current -> do
                  permission host access command current
                  stored <- Sql.lookupReceipt objective operation
                  forM_ stored \receipt -> unless (receipt.actor == access.actor && receipt.operationId == operation && receipt.fingerprint == fingerprint) (Sql.abort TrackerConflict)
                  pure stored
              )
      old <- original
      case old of
        Left err -> pure (Left err)
        Right (Just receipt) -> pure (Right receipt)
        Right Nothing | requiresEnablement command && (host.settings.enabled /= TrackersEnabled || access.settings.enabled /= O.ObjectivesEnabled) -> pure (Left TrackerDenied)
        Right Nothing -> do
          prepared <- prepare host command
          case prepared of
            Left err -> pure (Left err)
            Right observation -> do
              fresh <- liftIO (admit host (toJSON (objective, operation, command)))
              case fresh of
                Right current | current.actor == access.actor -> do
                  applied <- case command of
                    ApplyProposal identifier expected proposal revision -> apply host current objective operation command identifier expected proposal revision
                    _ ->
                      mapped
                        ( OStore.trackerTransaction current objective (digestText fingerprint) \snapshot -> do
                            permission host current command snapshot
                            existing <- Sql.lookupReceipt objective operation
                            case existing of
                              Just receipt -> unless (receipt.fingerprint == fingerprint) (Sql.abort TrackerConflict)
                              Nothing -> do
                                result <- transition host current snapshot command observation
                                Sql.insertReceipt objective (CommandReceipt TrackerV1 operation current.actor fingerprint result)
                        )
                  case applied of Left err -> pure (Left err); Right () -> original >>= \case Right (Just receipt) -> pure (Right receipt); Left err -> pure (Left err); _ -> pure (Left TrackerUnavailable)
                Right _ -> pure (Left TrackerDenied)
                Left err -> pure (Left err)

requiresEnablement :: Command -> Bool
requiresEnablement = \case
  Bind {} -> True
  Resume {} -> True
  ChangeMapping {} -> True
  ApplyProposal {} -> True
  RebaseProposal {} -> True
  _ -> False

permission :: TrackerHost -> Access -> Command -> O.Objective -> Transaction ()
permission host access command current = do
  case command of
    Bind _ scope _ -> requireOwner access current >> unless (either (const False) (elem access.actor . (.useGrants)) (connectionFor host.settings scope)) (Sql.abort TrackerDenied)
    AttestDelivery {} -> requireReconciliation host access
    SuppressPublication {} -> requireManage access current
    ApplyProposal identifier _ _ _ -> requireImport identifier
    RebaseProposal identifier _ _ _ -> requireImport identifier
    _ -> requireManage access current
  where
    requireImport identifier = do
      requireManage access current
      binding <- bindingFor current.objectiveId identifier
      unless (matchesConnection host.settings binding.scope binding.connectionDigest) (Sql.abort TrackerConflict)
      unless (either (const False) (elem access.actor . (.useGrants)) (connectionFor host.settings binding.scope)) (Sql.abort TrackerDenied)

requireReconciliation :: TrackerHost -> Access -> Transaction ()
requireReconciliation host access = unless (access.actor `elem` host.settings.reconciliationOperators && case access.actor of O.LocalOperator _ -> True; _ -> False) (Sql.abort TrackerDenied)

prepare :: (OStore.ObjectiveEffects es) => TrackerHost -> Command -> Eff es (Either TrackerError (Maybe (Provider.Provider, TrackerObservation)))
prepare host = \case
  Bind _ scope _ -> liftIO do
    selected <- provider host scope
    case selected of Left err -> pure (Left err); Right remote -> fmap (fmap (Just . (remote,))) (readObservation remote scope)
  _ -> pure (Right Nothing)

transition :: TrackerHost -> Access -> O.Objective -> Command -> Maybe (Provider.Provider, TrackerObservation) -> Transaction CommandResult
transition host access objective command prepared = case command of
  Bind identifier scope policy -> do
    (selected, observation) <- maybe (Sql.abort TrackerUnavailable) pure prepared
    Sql.lockResource scope
    own <- Sql.bindingsFor objective.objectiveId
    remote <- Sql.resourceBindings scope
    forM_ (filter ((== ReconciliationOnly) . (.state)) (nub (own <> remote))) \old -> do
      pending <- Sql.hasUnresolved old.bindingId
      when pending (Sql.abort TrackerConflict)
    binding <- Sql.require (admitBinding host.settings access.actor True (nub (own <> remote)) identifier scope policy selected.capabilities observation objective)
    Sql.insertBinding binding
    Sql.retainObservation identifier observation "baseline"
    pure (BindingResult binding)
  Pause identifier expected -> changeBinding identifier expected (\binding -> pure (binding & #state .~ Paused))
  Resume identifier expected -> changeBinding identifier expected \binding -> do
    unless (binding.state /= ReconciliationOnly && matchesConnection host.settings binding.scope binding.connectionDigest && mayUseConnection host.settings access.actor binding.scope) (Sql.abort TrackerDenied)
    pure (binding & #state .~ Active)
  Detach identifier expected -> changeBinding identifier expected (\binding -> pure (binding & #state .~ ReconciliationOnly))
  ChangeMapping identifier expected policy -> changeBinding identifier expected \binding -> do
    Sql.require (validatePolicy policy)
    unless (binding.state /= ReconciliationOnly && matchesConnection host.settings binding.scope binding.connectionDigest && mayUseConnection host.settings access.actor binding.scope) (Sql.abort TrackerDenied)
    pending <- Sql.hasUnresolved identifier
    when pending (Sql.abort TrackerConflict)
    others <- Sql.bindingsFor objective.objectiveId
    unless (all (\other -> other.bindingId == identifier || other.state == ReconciliationOnly || not (policy.instructions == ProposeField && other.policy.instructions == ProposeField) && not (policy.lifecycle == ProposeField && other.policy.lifecycle == ProposeField)) others) (Sql.abort TrackerConflict)
    pure (binding & #policy .~ policy)
  RejectProposal identifier expected proposalId revision reason -> do
    binding <- requireBinding identifier expected
    proposal <- Sql.proposalById proposalId
    unless (proposal.bindingId == identifier && proposal.bindingRevision == expected && proposal.state == AwaitingDecision && revision == objective.revision && binding.state == Active) (Sql.abort TrackerConflict)
    unless (boundedReason reason) (Sql.abort (TrackerInvalid "a decision requires a bounded nonempty reason"))
    let next = proposal & #state .~ Declined
    Sql.saveProposal next
    pure (RejectedProposal next reason)
  RebaseProposal identifier expected proposalId revision -> do
    binding <- requireBinding identifier expected
    old <- Sql.proposalById proposalId
    unless (old.bindingId == identifier && old.state `elem` [AwaitingDecision, Superseded] && revision == objective.revision && binding.state == Active && old.observation == binding.latest) (Sql.abort TrackerConflict)
    identifier' <- Sql.require (either (Left . TrackerInvalid) Right (parseCoordinate (digestText (trackerDigest "shikigami.tracker-rebased-proposal/1" (toJSON (old, objective.revision, objective.instructions)) :: TrackerDigest "proposal-identity"))))
    let next = old & #proposalId .~ identifier' & #bindingRevision .~ expected & #localBase .~ objective.instructions & #localRevision .~ revision & #state .~ AwaitingDecision
    Sql.saveProposal (old & #state .~ Superseded)
    Sql.saveBinding (binding & #localBase .~ objective.instructions & #localRevision .~ revision)
    Sql.insertProposal next
    pure (ProposalResult next)
  SuppressPublication identifier expected reason -> do
    (intent, receipt) <- Sql.publicationById identifier
    unless (intent.objectiveId == objective.objectiveId && receipt.revision == expected && boundedReason reason) (Sql.abort TrackerConflict)
    let next = receipt & #revision %~ advanceRevision & #suppression .~ Just reason & #state .~ (if receipt.state == Pending then Suppressed else receipt.state)
    Sql.savePublicationReceipt next
    pure (PublicationResult next)
  AttestDelivery identifier attemptId incarnation remote digest expected reason -> do
    (intent, receipt) <- Sql.publicationById identifier
    attempt <- maybe (Sql.abort TrackerConflict) pure receipt.attempt
    let verification = VerifiedDelivery identifier attemptId intent.scope remote digest
    requireReconciliation host access
    unless (intent.objectiveId == objective.objectiveId && intent.scope.incarnation == incarnation && intent.digest == digest && receipt.revision == expected && receipt.state == Unknown && attempt.attemptId == attemptId && boundedReason reason) (Sql.abort TrackerConflict)
    verified <- Sql.hasVerification verification
    unless verified (Sql.abort TrackerConflict)
    let next = receipt & #revision %~ advanceRevision & #state .~ Delivered & #evidence .~ Just (DeliveryEvidence OperatorAttested remote verification (Just access.actor) (Just reason))
    Sql.savePublicationReceipt next
    pure (PublicationResult next)
  ApplyProposal {} -> Sql.abort TrackerConflict
  where
    requireBinding identifier expected = do
      binding <- bindingFor objective.objectiveId identifier
      unless (binding.revision == expected) (Sql.abort TrackerConflict)
      pure binding
    changeBinding identifier expected change = do
      binding <- requireBinding identifier expected
      next <- (\value -> value & #revision %~ advanceRevision) <$> change binding
      Sql.saveBinding next
      proposals <- Sql.awaitingProposalsFor identifier
      forM_ (filter ((== AwaitingDecision) . (.state)) proposals) (Sql.saveProposal . (\proposal -> proposal & #state .~ Superseded))
      pure (BindingResult next)

boundedReason :: O.Instructions -> Bool
boundedReason value = let raw = O.instructionsText value in not (Text.null (Text.strip raw)) && Text.length raw <= 4096

apply :: (OStore.ObjectiveEffects es) => TrackerHost -> Access -> O.ObjectiveId -> OperationId -> Command -> TrackerBindingId -> StateRevision "tracker-binding" -> ProposalId -> StateRevision "objective" -> Eff es (Either TrackerError ())
apply host access objective operation command identifier expected proposalId revision = do
  selected <-
    mapped
      ( OStore.trackerQuery access objective \current -> do
          requireManage access current
          binding <- bindingFor objective identifier
          proposal <- Sql.proposalById proposalId
          unless (binding.revision == expected) (Sql.abort TrackerConflict)
          Sql.require (validateDecision binding proposal current revision)
          pure proposal
      )
  case selected of
    Left err -> pure (Left err)
    Right proposal -> case proposal.change of
      InstructionsChange instructions -> commit proposal (OC.ReviseInstructions instructions)
      LifecycleChange RemoteCancelled -> commit proposal OC.CancelObjective
      _ -> pure (Left (TrackerInvalid "remote lifecycle facts require the explicit local evidence-validated lifecycle commands"))
  where
    fingerprint = fingerprintFor access.actor objective operation command
    localOperation = operationIdWithPrefix ('t' :| "racker-apply:") (digestText fingerprint)
    commit proposal mutation = do
      result <-
        mapped
          ( Objective.executeCommandWithTrackerCommit host.objective access.actor objective revision localOperation mutation \next objectiveReceipt -> do
              binding <- bindingFor objective identifier
              retained <- Sql.proposalById proposalId
              unless (binding.revision == expected && retained == proposal) (Sql.abort TrackerConflict)
              -- The current objective projection has already applied exactly revision+1.
              unless (next.revision == advanceRevision revision && binding.latest == proposal.observation && binding.localBase == proposal.localBase) (Sql.abort TrackerConflict)
              Sql.saveProposal (proposal & #state .~ Applied)
              Sql.saveBinding (binding & #localBase .~ next.instructions & #localRevision .~ next.revision)
              Sql.insertReceipt objective (CommandReceipt TrackerV1 operation access.actor fingerprint (AppliedProposal proposal.proposalId objectiveReceipt))
          )
      pure (() <$ result)

observe :: (OStore.ObjectiveEffects es) => TrackerHost -> O.ObjectiveId -> TrackerBindingId -> Eff es (Either TrackerError ())
observe host objective identifier = do
  selected <- query host objective \access _ -> do
    binding <- bindingFor objective identifier
    unless (binding.state == Active && matchesConnection host.settings binding.scope binding.connectionDigest && mayUseConnection host.settings access.actor binding.scope) (Sql.abort TrackerDenied)
    pure binding
  case selected of
    Left err -> pure (Left err)
    Right binding -> do
      readResult <- liftIO do
        selectedProvider <- provider host binding.scope
        case selectedProvider of Left err -> pure (Left err); Right remote -> readObservation remote binding.scope
      case readResult of
        Left err -> do
          grant <- liftIO (admit host (toJSON ("observe-failure" :: Text, objective, identifier)))
          case grant of
            Left refusal -> pure (Left refusal)
            Right access -> do
              retained <-
                mapped
                  ( OStore.trackerTransaction access objective "tracker-read-failure" \_ -> do
                      current <- bindingFor objective identifier
                      unless (current.state == Active && current.revision == binding.revision && mayUseConnection host.settings access.actor current.scope) (Sql.abort TrackerDenied)
                      Sql.retainObservation identifier current.latest (case err of TrackerMissing -> "missing"; TrackerDenied -> "denied"; TrackerUnavailable -> "unavailable"; _ -> "invalid-observation")
                  )
              pure (retained >> Left err)
        Right observation -> do
          grant <- liftIO (admit host (toJSON ("observe" :: Text, objective, identifier)))
          case grant of
            Left err -> pure (Left err)
            Right access ->
              mapped
                ( OStore.trackerTransaction access objective (digestText observation.digest) \_ -> do
                    current <- bindingFor objective identifier
                    unless (current.state == Active && current.revision == binding.revision && mayUseConnection host.settings access.actor current.scope) (Sql.abort TrackerDenied)
                    (disposition, proposals) <- Sql.require (stageProposals current observation)
                    Sql.retainObservation identifier observation (case disposition of Advance -> "advance"; Duplicate -> "duplicate"; Older -> "older"; Equivocation -> "equivocation")
                    when (disposition == Advance) do
                      old <- Sql.awaitingProposalsFor identifier
                      let awaiting = filter ((== AwaitingDecision) . (.state)) old
                          unchanged = filter (\proposal -> changeStillPresent observation proposal.change && all ((/= proposal.change) . (.change)) proposals) awaiting
                      carried <- forM unchanged \proposal -> do
                        nextId <- Sql.require (either (Left . TrackerInvalid) Right (proposalIdentifier current observation proposal.change))
                        pure (proposal & #proposalId .~ nextId & #observation .~ observation)
                      forM_ awaiting (Sql.saveProposal . (\proposal -> proposal & #state .~ Superseded))
                      forM_ (proposals <> carried) Sql.insertProposal
                      Sql.saveBinding (current & #latest .~ observation)
                )

changeStillPresent :: TrackerObservation -> ProposedChange -> Bool
changeStillPresent observation = \case
  InstructionsChange value -> observation.snapshot.instructions == value
  LifecycleChange value -> observation.snapshot.lifecycle == value

-- Scheduler APIs expose no unadmitted protected records.
scheduledBindings :: (OStore.ObjectiveEffects es) => TrackerHost -> Maybe TrackerBindingId -> Eff es (Either TrackerError [(O.ObjectiveId, TrackerBindingId)])
scheduledBindings host after = do
  grant <- liftIO (admit host (toJSON ("schedule" :: Text)))
  either (pure . Left) (\access -> mapped (OStore.trackerRoutingKeys access after host.settings.batchSize)) grant

inspectBinding :: (OStore.ObjectiveEffects es) => TrackerHost -> O.ObjectiveId -> TrackerBindingId -> Eff es (Either TrackerError TrackerBinding)
inspectBinding host objective identifier = query host objective (\_ _ -> bindingFor objective identifier)

nextPublication :: (OStore.ObjectiveEffects es) => TrackerHost -> O.ObjectiveId -> TrackerBindingId -> Eff es (Either TrackerError (Maybe (PublicationIntent, PublicationReceipt)))
nextPublication host objective identifier = query host objective \_ _ -> bindingFor objective identifier >> Sql.nextUnsettled identifier
