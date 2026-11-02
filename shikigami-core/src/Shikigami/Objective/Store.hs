{-# LANGUAGE ConstraintKinds #-}
{-# LANGUAGE DataKinds #-}

-- | The only objective writer. Callers obtain the package-private Access from
-- Capability; every transaction rechecks membership before revealing a receipt.
module Shikigami.Objective.Store
  ( ObjectiveEffects,
    create,
    read,
    readVersion,
    resolveAssignment,
    currentCheckpoint,
    readMutationReceipt,
    admitConversationTurn,
    readConversationTurn,
    lookupCreatedObjective,
    lookupCreatedInScope,
    execute,
    lookupCommandReceipt,
    readReceipt,
    versionFor,
    referenceFor,
    validateTransition,
    authorized,
    mayCoordinate,
    validateSnapshot,
    creationAllowed,
  )
where

import Contravariant.Extras (contrazip2, contrazip3, contrazip4, contrazip6)
import Control.Exception (Exception, fromException, throw)
import Data.Aeson qualified as Aeson
import Data.Aeson.Types qualified as Aeson
import Data.ByteString.Lazy qualified as Lazy
import Data.Functor.Contravariant ((>$<))
import Data.Generics.Labels ()
import Data.Int (Int64)
import Data.KindID qualified as KindID
import Data.List (find, nub)
import Effectful (Eff, IOE, (:>))
import Effectful.Error.Static (Error, tryError)
import Effectful.Exception (catchSync, throwIO)
import Hasql.Decoders qualified as D
import Hasql.Encoders qualified as E
import Hasql.Statement (Statement, preparable)
import Hasql.Transaction (Transaction)
import Hasql.Transaction qualified as Tx
import Keiro.Command (CommandError (..))
import Keiro.Projection (ProjectionCommandOutcome (..), runCommandWithCatalogProjections)
import Keiro.ReadModel (ReadModel, runQuery)
import Keiro.Stream qualified as Stream
import Kiroku.Store.Effect (Store)
import Kiroku.Store.Effect.Resource (KirokuStoreResource)
import Kiroku.Store.Error (StoreError)
import Shikigami.Agent.Principal (identityText, principalText)
import Shikigami.App (CommandEffects, commandOptions)
import Shikigami.Decision.Contract (versionedDigest)
import Shikigami.Execution.Identity (OperationId, operationIdText)
import Shikigami.Execution.Progress (noPendingReceipts)
import Shikigami.Execution.Resources qualified as Resources
import Shikigami.Execution.ResourcesStore qualified as Roots
import Shikigami.Execution.Store qualified as Execution
import Shikigami.Execution.Transcript qualified as Execution
import Shikigami.FormatVersion (FormatVersion (V1))
import Shikigami.Objective.Acceptance
import Shikigami.Objective.Authority (Access (..))
import Shikigami.Objective.Catalog (withLiveObjective, withLiveObjectiveTurn)
import Shikigami.Objective.Command
import Shikigami.Objective.Conversation qualified as Conversation
import Shikigami.Objective.Reference (ObjectiveAssociation (..))
import Shikigami.Objective.Types
import Shikigami.ObjectiveLifecycle.Generated.Domain qualified as G
import Shikigami.ObjectiveLifecycle.Generated.EventStream (objectiveLifecycleCategory, objectiveLifecycleEventStream)
import Shikigami.ObjectiveLookup.Generated.ReadModel (objectiveLookupReadModel)
import Shikigami.ObjectiveTurnAdmission.Generated.Domain qualified as Turn
import Shikigami.ObjectiveTurnAdmission.Generated.EventStream (objectiveTurnAdmissionCategory, objectiveTurnAdmissionEventStream)
import Shikigami.ObjectiveTurnLookup.Generated.ReadModel (objectiveTurnLookupReadModel)
import Shikigami.Prelude
import Shikigami.WorkerSession.Checkpoint qualified as CP
import Shikigami.WorkerSession.Input qualified as WorkerInput
import Shikigami.WorkerSession.Store qualified as Sessions
import Shikigami.WorkerSession.Transfer qualified as Transfer
import Shikigami.WorkerSession.Types qualified as WS
import Prelude hiding (read)

type ObjectiveEffects es = (IOE :> es, Store :> es, Error StoreError :> es, KirokuStoreResource :> es, CommandEffects es)

data Abort = Abort ObjectiveError | Retry deriving stock (Show)

instance Exception Abort

abort :: ObjectiveError -> Transaction a
abort = throw . Abort

require :: Either ObjectiveError a -> Transaction a
require = either abort pure

creationAllowed :: ObjectiveSettings -> AccessPrincipal -> Bool
creationAllowed settings actor =
  settings.enabled == ObjectivesEnabled && validPrincipal actor && case actor of
    VerifiedCaller _ -> True
    LocalOperator identity -> settings.operator == Just identity
    RecordedAgent identity -> either (const False) (`elem` map principalText settings.agentCreation) (identityText identity)

rolesFor :: Objective -> AccessPrincipal -> [Role]
rolesFor objective actor = concatMap (.roles) (filter ((== actor) . (.principal)) objective.members)

administrates :: Access -> Bool
administrates access = case access.actor of
  LocalOperator identity -> access.settings.operator == Just identity && access.settings.administration == AdministerAll
  _ -> False

canRead :: Access -> Objective -> Bool
canRead access objective = access.settings.enabled == ObjectivesEnabled && validPrincipal access.actor && (administrates access || not (null (rolesFor objective access.actor)))

mayCoordinate :: Access -> Objective -> Bool
mayCoordinate access objective = canRead access objective && (administrates access || objective.owner == access.actor && Owner `elem` roles || Coordinator `elem` roles)
  where
    roles = rolesFor objective access.actor

-- This check runs under the same row lock as revocations and receipt lookup.
authorized :: Access -> Objective -> Mutation -> Bool
authorized access objective mutation = canRead access objective && (administrates access || allowed)
  where
    roles = rolesFor objective access.actor
    owner = Owner `elem` roles && objective.owner == access.actor
    manage = owner || Coordinator `elem` roles
    complete = owner || Completer `elem` roles
    owns key = Worker `elem` roles && any (\a -> a.definition.assignmentId == key && RecordedAgent a.definition.owner == access.actor && a.definition.state /= Withdrawn) objective.assignments
    allowed = case mutation of
      Public command -> case command of
        GrantMember {} -> owner
        RevokeMember {} -> owner
        AcceptCompletion -> complete
        RecordEvidence _ Attestation {} -> complete
        RecordEvidence key _ -> manage || owns key
        RecordProgress key _ _ _ -> manage || owns key
        _ -> manage
      Internal (IngestCheckpoint _ _ _ _) -> manage
      Internal ProjectCheckpoint {} -> manage
      Internal TransferSessionOwnership {} -> manage
      Internal TransferOwnership {} -> manage

checkAccess :: Access -> Objective -> Transaction ()
checkAccess access objective = do
  now <- Tx.statement () currentTime
  unless (now < access.expiresAt && canRead access objective) (abort ObjectiveDenied)

read :: (ObjectiveEffects es) => Access -> ObjectiveId -> Eff es (Either ObjectiveError Objective)
read access objective = protected do
  current <- locked objective
  checkAccess access current
  pure current

readVersion :: (ObjectiveEffects es) => Access -> WS.ObjectiveRef -> Eff es (Either ObjectiveError CP.ObjectiveVersion)
readVersion access reference = protected do
  (current, key) <- resolveAssignmentTx access reference
  require (versionFor current key)

resolveAssignment :: (ObjectiveEffects es) => Access -> WS.ObjectiveRef -> Eff es (Either ObjectiveError ObjectiveAssociation)
resolveAssignment access reference = protected do
  (current, key) <- resolveAssignmentTx access reference
  unless (mayCoordinate access current) (abort ObjectiveDenied)
  pure (ObjectiveAssociation current.objectiveId key)

resolveAssignmentTx :: Access -> WS.ObjectiveRef -> Transaction (Objective, ObjectiveAssignmentId)
resolveAssignmentTx access reference = do
  unless (WorkerInput.workerCoordinateText reference.provider == "shikigami-objective-v1") (abort ObjectiveMissing)
  (objective, assignment) <- Tx.statement (WorkerInput.workerCoordinateText reference.key) selectReference >>= maybe (abort ObjectiveMissing) pure
  identifier <- requireDecoded (parseObjectiveId objective)
  key <- requireDecoded (parseObjectiveAssignmentId assignment)
  unless (referenceFor identifier key == reference) (abort ObjectiveConflict)
  current <- locked identifier
  checkAccess access current
  unless (current.objectiveId == identifier) (abort ObjectiveConflict)
  pure (current, key)

-- Resource control is read from its owning transaction primitive. The effective
-- cutoff cannot outlive the retained resource envelope.
currentCheckpoint :: (ObjectiveEffects es) => Access -> WS.ObjectiveRef -> Eff es (Either ObjectiveError CP.ObjectiveVersion)
currentCheckpoint access reference = protected do
  (current, key) <- resolveAssignmentTx access reference
  unless (mayCoordinate access current) (abort ObjectiveDenied)
  version <- require (versionFor current key)
  root <- Roots.inspectRootTx version.rootId >>= either (const (abort ObjectiveUnavailable)) pure
  now <- Tx.statement () currentTime
  let cutoff = min version.cutoff root.envelope.cutoff
      active = if version.active == WorkerInput.ObjectiveActive && root.cancelled == Resources.ContinueWork && root.overage == Resources.NoOverage && now < cutoff then WorkerInput.ObjectiveActive else WorkerInput.ObjectiveInactive
  pure (version & #cutoff .~ cutoff & #active .~ active)

-- | Look up a turn that was already admitted; origin validation must never
-- manufacture an association for an execution that is already running.
readConversationTurn :: (ObjectiveEffects es) => Access -> RunReference -> TurnReference -> ConversationRef -> Eff es (Either ObjectiveError (Maybe Conversation.TurnAdmission))
readConversationTurn access run turn conversation = case access.actor of
  RecordedAgent participant -> protectedTurn do
    now <- Tx.statement () currentTime
    unless (now < access.expiresAt && access.settings.enabled == ObjectivesEnabled) (abort ObjectiveDenied)
    saved <- Conversation.lookupTurn run turn conversation participant >>= require
    forM_ saved \admission -> forM_ admission.binding \binding -> locked binding.receipt.objectiveId >>= checkAccess access
    pure saved
  _ -> pure (Left ObjectiveDenied)

-- Receipt-backed lookup supports commands on an objective created within a
-- frozen scope. It grants no access to arbitrary objective selectors.
lookupCreatedObjective :: (ObjectiveEffects es) => Access -> OperationId -> CreationOrigin -> Eff es (Either ObjectiveError (Maybe Receipt))
lookupCreatedObjective access operation origin = protected do
  now <- Tx.statement () currentTime
  unless (now < access.expiresAt && access.settings.enabled == ObjectivesEnabled && origin.operationId == operation) (abort ObjectiveDenied)
  case access.actor of
    RecordedAgent _ -> pure ()
    _ -> abort ObjectiveDenied
  let creator = versionedDigest "shikigami.objective-creator/1" (toJSON access.actor)
  saved <- readRow (creator, operationKey operation) selectCreated
  case saved of
    Nothing -> pure Nothing
    Just (actual, receipt) -> do
      unless (actual == Just origin && receipt.operationId == operation) (abort ObjectiveDenied)
      current <- locked receipt.objectiveId
      checkAccess access current
      original <- readRow (objectiveIdText receipt.objectiveId, operationKey operation) selectReceipt
      unless (original == Just (receipt.fingerprint, Right receipt)) (abort ObjectiveConflict)
      pure (Just receipt)

-- | Runtime adapters supply a pure predicate from frozen source coordinates.
-- The model supplies only the selector; creator attribution and current access
-- are checked by this owner before returning a receipt.
lookupCreatedInScope :: (ObjectiveEffects es) => Access -> ObjectiveId -> (CreationOrigin -> Bool) -> Eff es (Either ObjectiveError (Maybe Receipt))
lookupCreatedInScope access objective within = protected do
  case access.actor of
    RecordedAgent _ -> pure ()
    _ -> abort ObjectiveDenied
  now <- Tx.statement () currentTime
  unless (now < access.expiresAt && access.settings.enabled == ObjectivesEnabled) (abort ObjectiveDenied)
  let creator = versionedDigest "shikigami.objective-creator/1" (toJSON access.actor)
  saved <- readRow (objectiveIdText objective, creator) selectCreatedById
  case saved of
    Nothing -> pure Nothing
    Just (origin, receipt) -> do
      current <- locked objective
      checkAccess access current
      source <- maybe (abort ObjectiveDenied) pure origin
      unless (receipt.objectiveId == objective && source.operationId == receipt.operationId && within source) (abort ObjectiveDenied)
      original <- readRow (objectiveIdText objective, operationKey receipt.operationId) selectReceipt
      unless (original == Just (receipt.fingerprint, Right receipt)) (abort ObjectiveConflict)
      pure (Just receipt)

-- | Called only by authenticated runtime admission. Absence is retained too;
-- accepted turns never acquire a later conversation binding on retry.
admitConversationTurn :: (ObjectiveEffects es) => Access -> RunReference -> TurnReference -> ConversationRef -> Eff es (Either ObjectiveError Conversation.TurnAdmission)
admitConversationTurn access run turn conversation = guarded case access.actor of
  RecordedAgent participant -> do
    original <- recover participant
    case original of
      Left err -> pure (Left err)
      Right (Just admission) -> pure (Right admission)
      Right Nothing -> do
        models <- Conversation.checkMemoryModels
        case models of
          Left err -> pure (Left err)
          Right () -> do
            options <- commandOptions
            let source = versionedDigest "shikigami.objective-turn/1" (toJSON (run, turn, participant))
                (catalog, projections) = withLiveObjectiveTurn (\_ _ -> checkFresh >> (Conversation.admitTurn check run turn conversation participant >>= require) >> pure ())
            attempted <- guarded do
              outcome <- runCommandWithCatalogProjections options objectiveTurnAdmissionEventStream (Stream.entityStream objectiveTurnAdmissionCategory source) (Turn.AdmitObjectiveTurn (Turn.AdmitObjectiveTurnData source)) catalog projections
              pure case outcome of
                Right (ProjectionCommandApplied _) -> Right ()
                Left CommandRejected -> Left ObjectiveConflict
                _ -> Left ObjectiveUnavailable
            saved <- recover participant
            pure case saved of
              Right (Just admission) -> Right admission
              Left err -> Left err
              Right Nothing -> attempted >> Left ObjectiveUnresolved
  _ -> pure (Left ObjectiveDenied)
  where
    recover participant = protectedTurn do
      checkFresh
      saved <- Conversation.lookupTurn run turn conversation participant >>= require
      forM_ saved \admission -> forM_ admission.binding (\binding -> check binding >>= require)
      pure saved
    checkFresh = do
      now <- Tx.statement () currentTime
      unless (now < access.expiresAt && access.settings.enabled == ObjectivesEnabled) (abort ObjectiveDenied)
    check binding = do
      current <- locked binding.receipt.objectiveId
      checkAccess access current
      pure (Right ())

readReceipt :: (ObjectiveEffects es) => Access -> ObjectiveId -> OperationId -> Eff es (Either ObjectiveError (Maybe (Either ObjectiveError Receipt)))
readReceipt access objective operation = protected do
  current <- locked objective
  checkAccess access current
  fmap snd <$> readRow ((objectiveIdText objective), (operationKey operation)) selectReceipt

lookupCommandReceipt :: (ObjectiveEffects es) => Access -> ObjectiveId -> OperationId -> Mutation -> Eff es (Either ObjectiveError (Maybe (Either ObjectiveError Receipt)))
lookupCommandReceipt access objective operation mutation = protected do
  current <- locked objective
  checkAccess access current
  unless (authorized access current mutation) (abort ObjectiveDenied)
  fmap snd <$> readRow ((objectiveIdText objective), operationKey operation) selectReceipt

readMutationReceipt :: (ObjectiveEffects es) => Access -> ObjectiveId -> StateRevision "objective" -> OperationId -> Mutation -> Eff es (Either ObjectiveError (Maybe (Either ObjectiveError Receipt)))
readMutationReceipt access objective expected operation mutation = protected do
  current <- locked objective
  checkAccess access current
  unless (authorized access current mutation) (abort ObjectiveDenied)
  stored <- readRow (objectiveIdText objective, operationKey operation) selectReceipt
  let wanted = commandFingerprint (toJSON (access.actor, objective, expected, operation, commandTag mutation, mutation))
  forM stored \(actual, outcome) -> if actual == wanted then pure outcome else abort ObjectiveConflict

create :: (ObjectiveEffects es) => Access -> OperationId -> Maybe CreationOrigin -> CreateRequest -> IO (Either ObjectiveError ()) -> Eff es (Either ObjectiveError Receipt)
create access operation origin request verifyOrigin = guarded do
  unless (validKey (operationKey operation)) (throwIO (Abort (ObjectiveInvalid "invalid operation key")))
  allocated <- KindID.toText <$> KindID.genKindID @"shikigami_objective"
  identifier <- either (const (throwIO (Abort ObjectiveUnavailable))) pure (parseObjectiveId allocated)
  let creator = versionedDigest "shikigami.objective-creator/1" (toJSON access.actor)
      fingerprint = creationFingerprint (toJSON (access.actor, operation, origin, request))
      initial = Objective identifier access.actor [Member access.actor [Owner, Coordinator, Completer]] request.title request.goal request.instructions initialRevision initialRevision initialRevision request.criteria Open [] [] [] [] [] [] request.external [] Nothing Nothing
      payload = toJSON (request, origin, initial)
      digest = objectivePayloadDigest payload
      receipt = Receipt identifier operation fingerprint initialRevision digest
      lookupOriginal = protected do
        now <- Tx.statement () currentTime
        unless (now < access.expiresAt && access.settings.enabled == ObjectivesEnabled && validPrincipal access.actor) (abort ObjectiveDenied)
        stored <- readRow (creator, (operationKey operation)) selectOrigin
        case stored of
          Nothing -> pure Nothing
          Just (actual, old) -> do
            current <- locked old.objectiveId
            checkAccess access current
            unless (actual == fingerprint && old.operationId == operation) (abort ObjectiveConflict)
            pure (Just old)
  original <- lookupOriginal >>= either (throwIO . Abort) pure
  case original of
    Just old -> pure (Right old)
    Nothing -> do
      unless (creationAllowed access.settings access.actor) (throwIO (Abort ObjectiveDenied))
      case access.actor of
        RecordedAgent _ | isNothing origin -> throwIO (Abort ObjectiveDenied)
        _ -> pure ()
      forM_ origin \source -> unless (source.operationId == operation) (throwIO (Abort ObjectiveDenied))
      verified <- liftIO verifyOrigin
      either (throwIO . Abort) pure verified
      either (throwIO . Abort) pure (validateSnapshot initial)
      result <- persist identifier (G.CreateObjective (G.CreateObjectiveData identifier)) do
        -- Locks serialize identical creation, including creator-scoped retries.
        void (Tx.statement creator lockKey)
        old <- readRow (creator, (operationKey operation)) selectOrigin
        when (isJust old) (throw Retry)
        now <- Tx.statement () currentTime
        unless (now < access.expiresAt && creationAllowed access.settings access.actor) (abort ObjectiveDenied)
        Tx.statement ((objectiveIdText identifier), initial) insertObjective
        writePayload identifier (objectivePayloadDigestText digest) payload
        writeReceipt receipt (Right receipt)
        Tx.statement (creator, (operationKey operation), (objectiveIdText identifier), mutationFingerprintText fingerprint, toJSON origin, receipt) insertOrigin
      recovered <- lookupOriginal
      pure case recovered of Right (Just old) -> Right old; Left err -> Left err; _ -> result >> Left ObjectiveUnresolved

-- Receipt recovery precedes transition validation. A prepare transaction writes
-- only definitive negative outcomes; a positive transition is repeated inside
-- the checked aggregate's append/projection transaction.
execute :: (ObjectiveEffects es) => Access -> ObjectiveId -> StateRevision "objective" -> OperationId -> Mutation -> Eff es (Either ObjectiveError Receipt)
execute access identifier expected operation mutation = guarded do
  unless (validKey (operationKey operation)) (throwIO (Abort (ObjectiveInvalid "invalid operation key")))
  loop (32 :: Int)
  where
    fingerprint = commandFingerprint (toJSON (access.actor, identifier, expected, operation, commandTag mutation, mutation))
    inspect = do
      current <- locked identifier
      checkAccess access current
      unless (authorized access current mutation) (abort ObjectiveDenied)
      old <- readRow ((objectiveIdText identifier), (operationKey operation)) selectReceipt
      case old of
        Just (digest, outcome) -> pure (Left (if digest == fingerprint then outcome else Left ObjectiveConflict))
        Nothing -> do
          now <- Tx.statement () currentTime
          next <- prepareTransition now access expected mutation current
          case next of
            Left err | err == ObjectiveUnavailable -> pure (Left (Left err))
            Left err -> do
              Tx.statement ((objectiveIdText identifier), (operationKey operation), mutationFingerprintText fingerprint, Left err :: Either ObjectiveError Receipt) insertReceipt
              pure (Left (Left err))
            Right _ -> pure (Right current)
    loop remaining
      | remaining <= 0 = pure (Left ObjectiveUnavailable)
      | otherwise = do
          prepared <- protected inspect
          case prepared of
            Left err -> pure (Left err)
            Right (Left outcome) -> pure outcome
            Right (Right before) -> do
              let nextRevision = advanceRevision before.revision
                  command = G.ApplyObjectiveTransition (G.ApplyObjectiveTransitionData identifier (fromInteger (revisionNumber before.revision)) (fromInteger (revisionNumber nextRevision)) (mutationFingerprintText fingerprint))
              applied <- persist identifier command do
                current <- locked identifier
                checkAccess access current
                unless (authorized access current mutation) (abort ObjectiveDenied)
                unless (current.revision == before.revision) (throw Retry)
                old <- readRow ((objectiveIdText identifier), (operationKey operation)) selectReceipt
                when (isJust old) (throw Retry)
                now <- Tx.statement () currentTime
                next <- prepareTransition now access expected mutation current >>= require
                let payload = toJSON (access.actor, mutation, next)
                    digest = objectivePayloadDigest payload
                    receipt = Receipt identifier operation fingerprint next.revision digest
                saveSnapshot next
                writePayload identifier (objectivePayloadDigestText digest) payload
                case mutation of
                  Internal (IngestCheckpoint assignment intent _ _) -> Tx.statement ((objectiveIdText identifier), (objectiveAssignmentIdText assignment), intent.sessionId.value, fromInteger (revisionNumber intent.throughCursor)) saveCursor
                  Internal (ProjectCheckpoint assignment intent) -> Tx.statement ((objectiveIdText identifier), (objectiveAssignmentIdText assignment), intent.sessionId.value, fromInteger (revisionNumber intent.throughCursor)) saveCursor
                  Public (BindConversation conversation) -> Conversation.publishBinding next conversation receipt >>= require
                  _ -> pure ()
                writeReceipt receipt (Right receipt)
              case applied of
                Left ObjectiveUnavailable -> pure (Left ObjectiveUnavailable)
                Left ObjectiveDenied -> pure (Left ObjectiveDenied)
                _ -> loop (remaining - 1)

validateSnapshot :: Objective -> Either ObjectiveError ()
validateSnapshot objective = do
  validateCriteria objective.criteria
  validateGraph (map (.definition) objective.assignments)
  unless (length objective.external <= 64 && length objective.members <= 256 && length objective.decisions <= 64 && length objective.assumptions <= 64 && length objective.nextActions <= 64 && length objective.evidence <= 256 && length objective.reportedResults <= 128 && length objective.unresolved <= 128 && Lazy.length (Aeson.encode objective) <= 1048576) (Left (ObjectiveInvalid "objective exceeds its bounds"))

versionFor :: Objective -> ObjectiveAssignmentId -> Either ObjectiveError CP.ObjectiveVersion
versionFor objective key = do
  assignment <- maybe (Left ObjectiveMissing) Right (find ((== key) . (.definition.assignmentId)) objective.assignments)
  root <- maybe (Left (ObjectiveInvalid "assignment has no admitted resource root")) Right assignment.definition.rootId
  cutoff <- maybe (Left (ObjectiveInvalid "assignment has no admitted cutoff")) Right assignment.definition.cutoff
  pure (CP.ObjectiveVersion objective.revision assignment.revision objective.criteriaRevision assignment.ownerEpoch assignment.definition.owner (if objective.status == Open && assignment.definition.state `notElem` [Done, Withdrawn] then WorkerInput.ObjectiveActive else WorkerInput.ObjectiveInactive) root cutoff)

validateTransition :: UTCTime -> Access -> StateRevision "objective" -> Mutation -> Objective -> Either ObjectiveError Objective
validateTransition _now access expected mutation current = do
  unless (authorized access current mutation) (Left ObjectiveDenied)
  unless (revisionNumber current.revision < toInteger (maxBound :: Int)) (Left ObjectiveUnavailable)
  case mutation of
    Internal (IngestCheckpoint key intent _ _) -> checkpointVersion key intent
    Internal (ProjectCheckpoint key intent) -> checkpointVersion key intent
    _ -> unless (expected == current.revision) (Left ObjectiveConflict)
  next <- transition
  let advanced = next & #revision .~ (advanceRevision current.revision)
  validateSnapshot advanced
  pure advanced
  where
    checkpointVersion key intent = do
      actual <- versionFor current key
      let wanted = intent.expected
          cutoffMatches = case mutation of Internal ProjectCheckpoint {} -> wanted.cutoff <= actual.cutoff; _ -> wanted.cutoff == actual.cutoff
      unless (intent.format == V1 && expected == wanted.revision && expected <= actual.revision && actual.assignmentRevision == wanted.assignmentRevision && actual.criteriaRevision == wanted.criteriaRevision && actual.owner == wanted.owner && actual.ownerEpoch == wanted.ownerEpoch && actual.rootId == wanted.rootId && actual.active == wanted.active && intent.epoch == actual.ownerEpoch && cutoffMatches) (Left ObjectiveConflict)
    active = unless (current.status == Open) (Left (ObjectiveInvalid "objective is not open"))
    editable = unless (current.status `elem` [Open, Blocked]) (Left (ObjectiveInvalid "objective is terminal"))
    invalidate objective = objective & #assignments %~ map (\a -> a & #revision %~ advanceRevision)
    changeAssignment key f = do
      unless (any ((== key) . (.definition.assignmentId)) current.assignments) (Left ObjectiveMissing)
      assignments <- traverse (\a -> if a.definition.assignmentId == key then (\next -> next & #revision .~ (advanceRevision a.revision)) <$> f a else Right a) current.assignments
      pure (current & #assignments .~ assignments)
    withEvidence objective key inputs = do
      assignment <- maybe (Left ObjectiveMissing) Right (find ((== key) . (.definition.assignmentId)) objective.assignments)
      records <- forM inputs \input -> do
        unless (all ((/= input.key) . (.input.key)) objective.evidence && any ((== input.criterion) . (.key)) objective.criteria) (Left ObjectiveInvalidEvidence)
        disposition <- maybe (Left ObjectiveInvalidEvidence) Right (lookup input access.checks)
        case input of
          Attestation {} -> unless (any (\criterion -> criterion.key == input.criterion && criterion.kind == HumanVerifiable) objective.criteria) (Left ObjectiveInvalidEvidence)
          _ -> pure ()
        pure (Evidence input disposition key (assignmentMeaning assignment) access.actor (advanceRevision current.revision) current.instructionsRevision current.criteriaRevision)
      unless (length (nub (map (.input.key) records)) == length records) (Left ObjectiveInvalidEvidence)
      pure (objective & #evidence %~ (<> records))
    transition = case mutation of
      Public command -> case command of
        ReviseInstructions text -> do
          editable
          pure (invalidate (current & #instructions .~ text & #instructionsRevision %~ advanceRevision))
        ReviseCriteria criteria -> editable >> validateCriteria criteria >> pure (current & #criteria .~ criteria & #criteriaRevision %~ advanceRevision)
        SetAssignments graph -> do
          editable
          validateGraph graph
          -- Retain withdrawn nodes: their identities and counters cannot revive.
          unless (all (\a -> a.definition.assignmentId `elem` map (.assignmentId) graph) current.assignments) (Left (ObjectiveInvalid "withdraw assignments instead of deleting identities"))
          assignments <- forM graph \draft -> case find ((== draft.assignmentId) . (.definition.assignmentId)) current.assignments of
            Nothing -> pure (Assignment draft initialRevision initialRevision initialRevision [])
            Just previous -> do
              unless (previous.definition.owner == draft.owner || isNothing previous.definition.sessionId) (Left (ObjectiveInvalid "session ownership requires fenced transfer"))
              unless (((isNothing previous.definition.sessionId && isNothing previous.definition.rootId) || (previous.definition.sessionId == draft.sessionId && previous.definition.rootId == draft.rootId && previous.definition.cutoff == draft.cutoff)) && (previous.definition.state /= Withdrawn || draft.state == Withdrawn)) (Left (ObjectiveInvalid "cannot replace an admitted binding or reuse an assignment"))
              pure if previous.definition == draft then previous else previous & #definition .~ draft & #revision %~ advanceRevision & #instructionsRevision %~ (if previous.definition.instructions == draft.instructions && previous.definition.dependencies == draft.dependencies && previous.definition.owner == draft.owner then id else advanceRevision)
          pure (current & #assignments .~ assignments)
        RecordProgress key state decisions assumptions -> do
          active
          changed <- changeAssignment key (\a -> if a.definition.state == Withdrawn then Left ObjectiveConflict else Right (a & #definition . #state .~ state))
          pure (changed & #decisions %~ (\previous -> nub (previous <> decisions)) & #assumptions %~ (\previous -> nub (previous <> assumptions)))
        RecordEvidence key input -> do
          active
          changed <- changeAssignment key (Right . (\a -> a & #acceptedResults %~ (<> [input.key])))
          withEvidence changed key [input]
        SetNextAction actions -> editable >> pure (current & #nextActions .~ actions)
        SetBlocked blocked -> do
          editable
          let status = if blocked == IsBlocked then Blocked else Open
          pure (if status == current.status then current else invalidate (current & #status .~ status))
        ProposeCompletion proposal -> do
          active
          unless (proposal.objectiveRevision == current.revision && proposal.instructionsRevision == current.instructionsRevision && proposal.criteriaRevision == current.criteriaRevision) (Left ObjectiveConflict)
          pure (current & #proposed .~ Just (proposal, access.actor))
        AcceptCompletion -> do
          (proposal, proposer) <- maybe (Left ObjectiveInvalidEvidence) Right current.proposed
          validateAcceptance current proposal
          pure (invalidate (current & #status .~ Completed & #acceptance .~ Just (ObjectiveAcceptance current.objectiveId proposal proposer access.actor)))
        CancelObjective -> editable >> pure (invalidate (current & #status .~ Cancelled))
        GrantMember principal roles -> do
          unless (validPrincipal principal && not (null roles) && Owner `notElem` roles && principal /= current.owner && length (nub roles) == length roles) (Left (ObjectiveInvalid "invalid member grant"))
          pure (current & #members %~ (\members -> filter ((/= principal) . (.principal)) members <> [Member principal roles]))
        RevokeMember principal -> do
          unless (principal /= current.owner) (Left (ObjectiveInvalid "cannot revoke access owner"))
          pure (current & #members %~ filter ((/= principal) . (.principal)))
        BindConversation conversation -> editable >> (if validKey (conversationRefText conversation) then Right current else Left (ObjectiveInvalid "invalid conversation"))
        LinkExternal reference -> editable >> pure (current & #external %~ (\refs -> nub (refs <> [reference])))
      Internal (TransferSessionOwnership key intent proof) -> do
        unless (access.actor == RecordedAgent intent.actor && intent.format == V1 && Transfer.matchesFence intent proof && intent.newEpoch == advanceRevision intent.oldEpoch && intent.oldOwner /= intent.newOwner && intent.actor /= intent.newOwner) (Left ObjectiveDenied)
        actual <- versionFor current key
        let wanted = intent.expected
        unless (wanted.revision == expected && wanted.assignmentRevision == actual.assignmentRevision && wanted.criteriaRevision == actual.criteriaRevision && wanted.owner == actual.owner && wanted.ownerEpoch == actual.ownerEpoch && wanted.rootId == actual.rootId && wanted.active == actual.active && wanted.owner == intent.oldOwner && wanted.ownerEpoch == intent.oldEpoch && intent.rootId == wanted.rootId) (Left ObjectiveConflict)
        changeAssignment key \assignment -> pure (assignment & #definition . #owner .~ intent.newOwner & #ownerEpoch .~ intent.newEpoch)
      Internal (TransferOwnership key epoch owner) -> do
        unless (either (const False) validKey (identityText owner)) (Left ObjectiveDenied)
        changeAssignment key \assignment -> do
          unless (assignment.ownerEpoch == epoch) (Left ObjectiveConflict)
          pure (assignment & #definition . #owner .~ owner & #ownerEpoch %~ advanceRevision)
      Internal (ProjectCheckpoint key intent) -> do
        unless (access.actor == RecordedAgent intent.actor) (Left ObjectiveDenied)
        changeAssignment key (Right . (\a -> a & #definition . #sessionId .~ Just intent.sessionId))
      Internal (IngestCheckpoint key _ inputs unresolved) -> do
        changed <- changeAssignment key (Right . (\a -> a & #acceptedResults %~ (<> map (.key) inputs)))
        recorded <- withEvidence changed key inputs
        unless (all ((== key) . (.assignmentId)) unresolved) (Left ObjectiveInvalidEvidence)
        pure (recorded & #unresolved .~ (filter ((/= key) . (.assignmentId)) current.unresolved <> unresolved))

-- Source-derived observations are computed inside both inspection and commit.
-- Only the immutable intent enters the command fingerprint, so a retry never
-- changes its request after another source observation becomes available.
prepareTransition :: UTCTime -> Access -> StateRevision "objective" -> Mutation -> Objective -> Transaction (Either ObjectiveError Objective)
prepareTransition now access expected mutation current = do
  checked <- validateSources current mutation
  reports <- case mutation of
    Internal (ProjectCheckpoint key intent) -> traverse (reportedResult key intent) [receipt | WS.EventReceipt {event = WS.ResultAvailable receipt} <- intent.events]
    _ -> pure []
  pure do
    maybe checked Left access.refusal
    next <- validateTransition now access expected mutation current
    sources <- sequence reports
    let withReports = foldl' (\objective result -> objective & #reportedResults %~ (\previous -> filter ((/= result.assignmentId) . (.assignmentId)) previous <> [result])) next sources
    validateSnapshot withReports
    pure withReports

reportedResult :: ObjectiveAssignmentId -> CP.CheckpointIntent -> WS.ResultReceipt -> Transaction (Either ObjectiveError ReportedResult)
reportedResult assignment intent receipt = do
  stored <- Sessions.readResultSourceTx receipt.sessionId receipt.assignmentId >>= either (const (abort ObjectiveUnavailable)) pure
  case stored of
    Nothing -> pure (Left ObjectiveInvalidEvidence)
    Just (actual, result) -> do
      forM_ result.executionId \execution -> do
        source <- Execution.inspectExecutionTx execution >>= either (const (abort ObjectiveUnavailable)) pure >>= maybe (abort ObjectiveUnavailable) pure
        let (state, binding) = source
        unless (binding.rootId == Just intent.expected.rootId && binding.identity == intent.expected.owner) (abort ObjectiveInvalidEvidence)
        -- An uncertain effect cannot become an immutable negative receipt. Wait
        -- on the original intent until its execution owner settles the effects.
        unless (state.pendingReceipts == noPendingReceipts && state.phase `elem` [Execution.Succeeded, Execution.Failed, Execution.Cancelled]) (abort ObjectiveUnresolved)
      pure do
        unless (actual == receipt) (Left ObjectiveInvalidEvidence)
        artifacts <- traverse (either (const (Left ObjectiveInvalidEvidence)) Right . parseArtifactRef . WorkerInput.artifactReferenceText) result.artifacts
        pure (ReportedResult assignment receipt artifacts)

-- | Source authenticity is checked again inside the commit transaction. Future
-- provider adapters additionally validate accepted execution/fence coordinates.
validateSources :: Objective -> Mutation -> Transaction (Either ObjectiveError ())
validateSources objective mutation = do
  evidence <- forM (evidenceInputs mutation) \case
    ResultEvidence {result = WorkerResult receipt artifact} -> do
      let addressed = case mutation of Public (RecordEvidence key _) -> Just key; Internal (IngestCheckpoint key _ _ _) -> Just key; _ -> Nothing
          bound = any (\a -> Just a.definition.assignmentId == addressed && a.definition.sessionId == Just receipt.sessionId) objective.assignments
      stored <- Sessions.readResultSourceTx receipt.sessionId receipt.assignmentId >>= either (const (abort ObjectiveConflict)) pure
      case stored of
        Just (actual, result) ->
          pure do
            unless (bound && actual == receipt) (Left ObjectiveInvalidEvidence)
            unless (WorkerInput.artifactReference (artifactRefText artifact) `elem` result.artifacts) (Left ObjectiveInvalidEvidence)
        Nothing -> pure (Left ObjectiveInvalidEvidence)
    _ -> pure (Right ())
  conversation <- case mutation of
    Public (BindConversation reference) -> fmap (const ()) <$> Conversation.participantFor objective reference
    _ -> pure (Right ())
  bindings <- case mutation of
    Public (SetAssignments graph) -> forM graph \draft -> case draft.sessionId of
      Nothing -> pure (Right ())
      Just session -> do
        actual <- readRow session.value selectWorkerBinding
        let epoch = maybe initialRevision (.ownerEpoch) (find ((== draft.assignmentId) . (.definition.assignmentId)) objective.assignments)
        pure $ case actual of
          Just (state, binding) | state.owner == draft.owner && state.epoch == epoch && Just binding.rootId == draft.rootId && binding.objective == referenceFor objective.objectiveId draft.assignmentId -> Right ()
          _ -> Left ObjectiveConflict
    _ -> pure []
  checkpoint <- case mutation of
    Internal (TransferSessionOwnership key intent proof) -> do
      -- Session mutations lock their resource root before the session row.
      -- Keep that order while composing the ownership source check.
      root <- Roots.inspectRootTx intent.rootId >>= either (const (abort ObjectiveUnavailable)) pure
      settled <- Sessions.verifyTransferSourceTx intent proof
      case settled of
        Left WS.AssignmentConflict -> pure (Left ObjectiveConflict)
        Left _ -> abort ObjectiveUnavailable
        Right () -> case find ((== key) . (.definition.assignmentId)) objective.assignments of
          Just assignment -> do
            now <- Tx.statement () currentTime
            pure do
              cutoff <- maybe (Left ObjectiveConflict) Right assignment.definition.cutoff
              unless (assignment.definition.sessionId == Just intent.sessionId && intent.objective == referenceFor objective.objectiveId key && intent.expected.active == WorkerInput.ObjectiveActive && intent.expected.cutoff == min cutoff root.envelope.cutoff && now < intent.expected.cutoff && root.cancelled == Resources.ContinueWork && root.overage == Resources.NoOverage) (Left ObjectiveConflict)
          Nothing -> pure (Left ObjectiveMissing)
    Internal (IngestCheckpoint key intent inputs _) -> do
      original <- readRow (intent.sessionId.value, operationKey intent.operationId) selectCheckpoint
      cursor <- fromMaybe initialRevision <$> readRow ((objectiveIdText objective.objectiveId), (objectiveAssignmentIdText key), intent.sessionId.value) selectCursor
      case find ((== key) . (.definition.assignmentId)) objective.assignments of
        Just assignment -> pure do
          unless (assignment.definition.sessionId == Just intent.sessionId && intent.actor `matchesActor` objective && original == Just intent && intent.objective == referenceFor objective.objectiveId key && cursor == intent.previousCursor && intent.throughCursor > cursor && revisionNumber intent.throughCursor - revisionNumber cursor <= 100 && map (revisionNumber . (.cursor)) intent.events == [revisionNumber cursor + 1 .. revisionNumber intent.throughCursor]) (Left ObjectiveConflict)
          let results = [receipt | WS.EventReceipt {event = WS.ResultAvailable receipt} <- intent.events]
          forM_ inputs \case
            ResultEvidence {result = WorkerResult receipt _} -> unless (receipt `elem` results) (Left ObjectiveInvalidEvidence)
            _ -> Left ObjectiveInvalidEvidence
        Nothing -> pure (Left ObjectiveMissing)
    Internal (ProjectCheckpoint key intent) -> do
      original <- readRow (intent.sessionId.value, operationKey intent.operationId) selectCheckpoint
      retained <- readRow intent.sessionId.value selectWorkerBinding
      sourceEvents <- Tx.statement (intent.sessionId.value, fromInteger (revisionNumber intent.previousCursor), fromInteger (revisionNumber intent.throughCursor)) selectSourceEvents >>= traverse requireDecoded
      unless (sourceEvents == intent.events) (abort ObjectiveUnavailable)
      cursor <- fromMaybe initialRevision <$> readRow (objectiveIdText objective.objectiveId, objectiveAssignmentIdText key, intent.sessionId.value) selectCursor
      case (find ((== key) . (.definition.assignmentId)) objective.assignments, retained) of
        (Just assignment, Just (state, binding)) -> do
          root <- Roots.inspectRootTx binding.rootId >>= either (const (abort ObjectiveUnavailable)) pure
          now <- Tx.statement () currentTime
          pure do
            cutoff <- maybe (Left ObjectiveConflict) Right assignment.definition.cutoff
            unless (original == Just intent && intent.actor == binding.parentIdentity && binding.sessionId == intent.sessionId && state.sessionId == intent.sessionId && state.owner == intent.expected.owner && state.epoch == intent.epoch && binding.objective == referenceFor objective.objectiveId key && binding.rootId == intent.expected.rootId && (isNothing assignment.definition.sessionId || assignment.definition.sessionId == Just intent.sessionId)) (Left ObjectiveConflict)
            unless (cursor == intent.previousCursor && intent.throughCursor > cursor && revisionNumber intent.throughCursor - revisionNumber cursor <= 100 && map (revisionNumber . (.cursor)) intent.events == [revisionNumber cursor + 1 .. revisionNumber intent.throughCursor]) (Left ObjectiveConflict)
            unless (root.cancelled == Resources.ContinueWork && root.overage == Resources.NoOverage && intent.expected.cutoff == min cutoff root.envelope.cutoff && now < intent.expected.cutoff) (Left ObjectiveConflict)
        _ -> pure (Left ObjectiveConflict)
    _ -> pure (Right ())
  pure (sequence_ evidence >> conversation >> sequence_ bindings >> checkpoint)
  where
    matchesActor actor obj = not (null (rolesFor obj (RecordedAgent actor)))

referenceFor :: ObjectiveId -> ObjectiveAssignmentId -> WS.ObjectiveRef
referenceFor objective assignment = WS.ObjectiveRef (WorkerInput.workerCoordinate "shikigami-objective-v1") (WorkerInput.workerCoordinate (versionedDigest "shikigami.objective-assignment-ref/1" (toJSON (objective, assignment))))

locked :: ObjectiveId -> Transaction Objective
locked identifier = do
  current <- readRow (objectiveIdText identifier) lockObjective >>= maybe (abort ObjectiveMissing) pure
  requireDecoded (validateSnapshot current)
  pure current

saveSnapshot :: Objective -> Transaction ()
saveSnapshot objective = do
  Tx.statement ((objectiveIdText objective.objectiveId), objective) updateObjective
  forM_ objective.assignments \assignment -> Tx.statement ((objectiveIdText objective.objectiveId), (objectiveAssignmentIdText assignment.definition.assignmentId), WorkerInput.workerCoordinateText (referenceFor objective.objectiveId assignment.definition.assignmentId).key, assignment) saveAssignment

writePayload :: ObjectiveId -> Text -> Aeson.Value -> Transaction ()
writePayload objective digest payload = Tx.statement ((objectiveIdText objective), digest, payload) insertPayload

writeReceipt :: Receipt -> Either ObjectiveError Receipt -> Transaction ()
writeReceipt receipt outcome = Tx.statement ((objectiveIdText receipt.objectiveId), operationKey receipt.operationId, mutationFingerprintText receipt.fingerprint, outcome) insertReceipt

-- A rejected Keiro command or concurrent duplicate is retried through the locked
-- inspector. Transport failure remains unavailable/uncertain, never a rejection.
persist :: (ObjectiveEffects es) => ObjectiveId -> G.ObjectiveLifecycleCommand -> Transaction () -> Eff es (Either ObjectiveError ())
persist objective command action = guarded do
  let (catalog, projections) = withLiveObjective (\_ _ -> action)
  options <- commandOptions
  outcome <- runCommandWithCatalogProjections options objectiveLifecycleEventStream (Stream.entityStream objectiveLifecycleCategory (objectiveIdText objective)) command catalog projections
  pure case outcome of
    Right (ProjectionCommandApplied _) -> Right ()
    Right _ -> Left ObjectiveUnavailable
    Left CommandRejected -> Left ObjectiveConflict
    Left (StoreFailed _) -> Left ObjectiveUnavailable
    Left (RetryExhausted _ _) -> Left ObjectiveUnavailable
    Left _ -> Left ObjectiveUnavailable

protected :: (ObjectiveEffects es, ToJSON a, FromJSON a) => Transaction a -> Eff es (Either ObjectiveError a)
protected = protectedUsing objectiveLookupReadModel

protectedTurn :: (ObjectiveEffects es, ToJSON a, FromJSON a) => Transaction a -> Eff es (Either ObjectiveError a)
protectedTurn = protectedUsing objectiveTurnLookupReadModel

protectedUsing :: (ObjectiveEffects es, ToJSON a, FromJSON a) => ReadModel (Transaction Aeson.Value) Aeson.Value -> Transaction a -> Eff es (Either ObjectiveError a)
protectedUsing model action = guarded do
  result <- runQuery Nothing model (toJSON <$> action)
  pure case result of
    Left _ -> Left ObjectiveUnavailable
    Right value -> case Aeson.fromJSON value of Aeson.Success answer -> Right answer; _ -> Left ObjectiveUnavailable

guarded :: (ObjectiveEffects es) => Eff es (Either ObjectiveError a) -> Eff es (Either ObjectiveError a)
guarded action = do
  outcome <-
    tryError @StoreError
      ( catchSync action \exception -> case fromException exception of
          Just (Abort err) -> pure (Left err)
          Just Retry -> pure (Left ObjectiveConflict)
          Nothing -> throwIO exception
      )
  pure (either (const (Left ObjectiveUnavailable)) id outcome)

operationKey :: OperationId -> Text
operationKey = operationIdText

textParam :: E.Params Text
textParam = E.param (E.nonNullable E.text)

jsonParam :: (ToJSON a) => E.Params a
jsonParam = toJSON >$< E.param (E.nonNullable E.jsonb)

intParam :: E.Params Int64
intParam = E.param (E.nonNullable E.int8)

jsonRow :: (FromJSON a) => D.Row (Either () a)
jsonRow = decode <$> D.column (D.nonNullable D.jsonb)
  where
    decode value = case Aeson.fromJSON value of Aeson.Success answer -> Right answer; Aeson.Error _ -> Left ()

-- SQL errors retain the store path. A present but unreadable owned row is an
-- objective refusal and condemns any earlier command/projection writes.
readRow :: input -> Statement input (Maybe (Either () a)) -> Transaction (Maybe a)
readRow input statement = Tx.statement input statement >>= traverse requireDecoded

requireDecoded :: Either err a -> Transaction a
requireDecoded (Right value) = pure value
requireDecoded (Left _) = Tx.condemn >> abort ObjectiveConflict

lockObjective :: Statement Text (Maybe (Either () Objective))
lockObjective = preparable "SELECT state FROM shikigami.objectives WHERE objective_id=$1 FOR UPDATE" textParam (D.rowMaybe jsonRow)

insertObjective, updateObjective :: Statement (Text, Objective) ()
insertObjective = preparable "INSERT INTO shikigami.objectives(objective_id,state) VALUES ($1,$2)" (contrazip2 textParam jsonParam) D.noResult
updateObjective = preparable "UPDATE shikigami.objectives SET state=$2,updated_at=clock_timestamp() WHERE objective_id=$1" (contrazip2 textParam jsonParam) D.noResult

saveAssignment :: Statement (Text, Text, Text, Assignment) ()
saveAssignment = preparable "INSERT INTO shikigami.objective_assignments(objective_id,assignment_id,reference_key,state) VALUES ($1,$2,$3,$4) ON CONFLICT (objective_id,assignment_id) DO UPDATE SET state=$4" (contrazip4 textParam textParam textParam jsonParam) D.noResult

insertPayload :: Statement (Text, Text, Aeson.Value) ()
insertPayload = preparable "INSERT INTO shikigami.objective_payloads(objective_id,digest,payload) VALUES ($1,$2,$3)" (contrazip3 textParam textParam jsonParam) D.noResult

selectReceipt :: Statement (Text, Text) (Maybe (Either () (MutationFingerprint, Either ObjectiveError Receipt)))
selectReceipt = preparable "SELECT fingerprint,outcome FROM shikigami.objective_receipts WHERE objective_id=$1 AND operation_key=$2" (contrazip2 textParam textParam) (D.rowMaybe ((\raw value -> do fingerprint <- either (const (Left ())) Right (parseMutationFingerprint raw); (fingerprint,) <$> value) <$> D.column (D.nonNullable D.text) <*> jsonRow))

insertReceipt :: Statement (Text, Text, Text, Either ObjectiveError Receipt) ()
insertReceipt = preparable "INSERT INTO shikigami.objective_receipts(objective_id,operation_key,fingerprint,outcome) VALUES ($1,$2,$3,$4)" (contrazip4 textParam textParam textParam jsonParam) D.noResult

-- Validate the physical keys as well as the JSON before a creation receipt can
-- authorize continuation. A well-typed receipt for another row is corruption.
originDetails :: D.Row (Either () (MutationFingerprint, Maybe CreationOrigin, Receipt))
originDetails = assemble <$> D.column (D.nonNullable D.text) <*> D.column (D.nonNullable D.text) <*> D.column (D.nonNullable D.text) <*> jsonRow <*> jsonRow
  where
    assemble objective operation raw origin receipt = do
      fingerprint <- either (const (Left ())) Right (parseMutationFingerprint raw)
      source <- origin
      saved <- receipt
      unless (objectiveIdText saved.objectiveId == objective && operationKey saved.operationId == operation && saved.fingerprint == fingerprint) (Left ())
      pure (fingerprint, source, saved)

selectOrigin :: Statement (Text, Text) (Maybe (Either () (MutationFingerprint, Receipt)))
selectOrigin = preparable "SELECT objective_id,operation_key,fingerprint,origin,receipt FROM shikigami.objective_origins WHERE creator_key=$1 AND operation_key=$2" (contrazip2 textParam textParam) (D.rowMaybe (fmap (fmap (\(fingerprint, _, receipt) -> (fingerprint, receipt))) originDetails))

selectCreated :: Statement (Text, Text) (Maybe (Either () (Maybe CreationOrigin, Receipt)))
selectCreated = preparable "SELECT objective_id,operation_key,fingerprint,origin,receipt FROM shikigami.objective_origins WHERE creator_key=$1 AND operation_key=$2" (contrazip2 textParam textParam) (D.rowMaybe (fmap (fmap (\(_, origin, receipt) -> (origin, receipt))) originDetails))

selectCreatedById :: Statement (Text, Text) (Maybe (Either () (Maybe CreationOrigin, Receipt)))
selectCreatedById = preparable "SELECT objective_id,operation_key,fingerprint,origin,receipt FROM shikigami.objective_origins WHERE objective_id=$1 AND creator_key=$2" (contrazip2 textParam textParam) (D.rowMaybe (fmap (fmap (\(_, origin, receipt) -> (origin, receipt))) originDetails))

insertOrigin :: Statement (Text, Text, Text, Text, Aeson.Value, Receipt) ()
insertOrigin = preparable "INSERT INTO shikigami.objective_origins(creator_key,operation_key,objective_id,fingerprint,origin,receipt) VALUES ($1,$2,$3,$4,$5,$6)" (contrazip6 textParam textParam textParam textParam jsonParam jsonParam) D.noResult

lockKey :: Statement Text ()
lockKey = preparable "SELECT pg_advisory_xact_lock(hashtextextended($1,0))" textParam D.noResult

currentTime :: Statement () UTCTime
currentTime = preparable "SELECT clock_timestamp()" E.noParams (D.singleRow (D.column (D.nonNullable D.timestamptz)))

selectCheckpoint :: Statement (Text, Text) (Maybe (Either () CP.CheckpointIntent))
selectCheckpoint = preparable "SELECT state FROM shikigami.worker_session_commands WHERE session_id=$1 AND operation_id=$2" (contrazip2 textParam textParam) (D.rowMaybe jsonRow)

selectCursor :: Statement (Text, Text, Text) (Maybe (Either () (StateRevision "worker-event")))
selectCursor = preparable "SELECT cursor FROM shikigami.objective_cursors WHERE objective_id=$1 AND assignment_id=$2 AND session_id=$3" (contrazip3 textParam textParam textParam) (D.rowMaybe ((either (const (Left ())) Right . parseRevision . toInteger) <$> D.column (D.nonNullable D.int8)))

saveCursor :: Statement (Text, Text, Text, Int64) ()
saveCursor = preparable "INSERT INTO shikigami.objective_cursors(objective_id,assignment_id,session_id,cursor) VALUES ($1,$2,$3,$4) ON CONFLICT (objective_id,assignment_id,session_id) DO UPDATE SET cursor=$4" (contrazip4 textParam textParam textParam intParam) D.noResult

selectReference :: Statement Text (Maybe (Text, Text))
selectReference = preparable "SELECT objective_id,assignment_id FROM shikigami.objective_assignments WHERE reference_key=$1" textParam (D.rowMaybe ((,) <$> D.column (D.nonNullable D.text) <*> D.column (D.nonNullable D.text)))

selectWorkerBinding :: Statement Text (Maybe (Either () (WS.SessionState, WS.SessionBinding)))
selectWorkerBinding = preparable "SELECT state,binding FROM shikigami.worker_sessions WHERE session_id=$1" textParam (D.rowMaybe ((\state binding -> (,) <$> state <*> binding) <$> jsonRow <*> jsonRow))

-- Compare both physical cursors and typed bodies. A substituted well-typed
-- event must not become new evidence merely because an intent row still exists.
selectSourceEvents :: Statement (Text, Int64, Int64) [Either () WS.EventReceipt]
selectSourceEvents = preparable "SELECT cursor,state FROM shikigami.worker_session_events WHERE session_id=$1 AND cursor>$2 AND cursor<=$3 ORDER BY cursor" (contrazip3 textParam intParam intParam) (D.rowList (check <$> D.column (D.nonNullable D.int8) <*> jsonRow))
  where
    check cursor value = do
      receipt <- value
      unless (revisionNumber receipt.cursor == toInteger cursor) (Left ())
      pure receipt
