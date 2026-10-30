{-# LANGUAGE ConstraintKinds #-}

-- | The only objective writer. Callers obtain the package-private Access from
-- Capability; every transaction rechecks membership before revealing a receipt.
module Shikigami.Objective.Store
  ( ObjectiveEffects,
    create,
    read,
    readVersion,
    execute,
    lookupCommandReceipt,
    readReceipt,
    versionFor,
    referenceFor,
    validateTransition,
    authorized,
    creationAllowed,
  )
where

import Contravariant.Extras (contrazip2, contrazip3, contrazip4, contrazip6)
import Control.Exception (Exception, fromException, throw)
import Data.Aeson ((.:))
import Data.Aeson qualified as Aeson
import Data.Aeson.Types qualified as Aeson
import Data.ByteString.Lazy qualified as Lazy
import Data.Functor.Contravariant ((>$<))
import Data.Generics.Labels ()
import Data.Int (Int64)
import Data.List (find, nub)
import Data.Text qualified as Text
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
import Keiro.ReadModel (runQuery)
import Keiro.Stream qualified as Stream
import Kiroku.Store.Effect (Store)
import Kiroku.Store.Effect.Resource (KirokuStoreResource)
import Kiroku.Store.Error (StoreError)
import Shikigami.Agent.Principal (identityText)
import Shikigami.App (CommandEffects, commandOptions)
import Shikigami.Decision.Contract (versionedDigest)
import Shikigami.Execution.Identity (OperationId (..))
import Shikigami.Execution.Transcript (PayloadRef (..))
import Shikigami.Objective.Acceptance
import Shikigami.Objective.Authority (Access (..))
import Shikigami.Objective.Catalog (withLiveObjective)
import Shikigami.Objective.Command
import Shikigami.Objective.Types
import Shikigami.ObjectiveLifecycle.Generated.Domain qualified as G
import Shikigami.ObjectiveLifecycle.Generated.EventStream (objectiveLifecycleCategory, objectiveLifecycleEventStream)
import Shikigami.ObjectiveLookup.Generated.ReadModel (objectiveLookupReadModel)
import Shikigami.Prelude
import Shikigami.WorkerSession.Checkpoint qualified as CP
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
  settings.enabled && validPrincipal actor && case actor of
    VerifiedCaller _ -> True
    LocalOperator identity -> settings.operator == Just identity
    RecordedAgent identity -> either (const False) (`elem` settings.agentCreation) (identityText identity)

rolesFor :: Objective -> AccessPrincipal -> [Role]
rolesFor objective actor = concatMap (.roles) (filter ((== actor) . (.principal)) objective.members)

administrates :: Access -> Bool
administrates access = case access.actor of
  LocalOperator identity -> access.settings.operator == Just identity && access.settings.administration == AdministerAll
  _ -> False

canRead :: Access -> Objective -> Bool
canRead access objective = access.settings.enabled && validPrincipal access.actor && (administrates access || not (null (rolesFor objective access.actor)))

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
  unless (reference.provider == "shikigami-objective-v1") (abort ObjectiveMissing)
  (objective, assignment) <- Tx.statement reference.key selectReference >>= maybe (abort ObjectiveMissing) pure
  current <- locked (ObjectiveId objective)
  checkAccess access current
  require (versionFor current (ObjectiveAssignmentId assignment))

readReceipt :: (ObjectiveEffects es) => Access -> ObjectiveId -> OperationId -> Eff es (Either ObjectiveError (Maybe (Either ObjectiveError Receipt)))
readReceipt access objective operation = protected do
  current <- locked objective
  checkAccess access current
  fmap snd <$> Tx.statement (objective.value, (operationKey operation)) selectReceipt

lookupCommandReceipt :: (ObjectiveEffects es) => Access -> ObjectiveId -> OperationId -> Mutation -> Eff es (Either ObjectiveError (Maybe (Either ObjectiveError Receipt)))
lookupCommandReceipt access objective operation mutation = protected do
  current <- locked objective
  checkAccess access current
  unless (authorized access current mutation) (abort ObjectiveDenied)
  fmap snd <$> Tx.statement (objective.value, operationKey operation) selectReceipt

create :: (ObjectiveEffects es) => Access -> OperationId -> Maybe CreationOrigin -> CreateRequest -> IO (Either ObjectiveError ()) -> Eff es (Either ObjectiveError Receipt)
create access operation origin request verifyOrigin = guarded do
  unless (creationAllowed access.settings access.actor) (throwIO (Abort ObjectiveDenied))
  unless (validKey (operationKey operation)) (throwIO (Abort (ObjectiveInvalid "invalid operation key")))
  let creator = versionedDigest "shikigami.objective-creator/1" (toJSON access.actor)
      identifier = ObjectiveId ("objective-" <> versionedDigest "shikigami.objective-id/1" (toJSON (access.actor, operation)))
      fingerprint = versionedDigest "shikigami.objective-create/1" (toJSON (access.actor, operation, origin, request))
      initial = Objective identifier access.actor [Member access.actor [Owner, Coordinator, Completer]] request.title request.goal request.instructions 0 0 0 request.criteria Open [] [] [] [] [] request.external [] Nothing Nothing
      payload = toJSON (request, origin, initial)
      digest = versionedDigest "shikigami.objective-payload/1" payload
      receipt = Receipt identifier operation fingerprint 0 digest
      lookupOriginal = protected do
        now <- Tx.statement () currentTime
        unless (now < access.expiresAt && creationAllowed access.settings access.actor) (abort ObjectiveDenied)
        stored <- Tx.statement (creator, (operationKey operation)) selectOrigin
        case stored of
          Nothing -> pure Nothing
          Just (actual, old) -> do
            current <- locked old.objectiveId
            checkAccess access current
            unless (actual == fingerprint) (abort ObjectiveConflict)
            pure (Just old)
  original <- lookupOriginal >>= either (throwIO . Abort) pure
  case original of
    Just old -> pure (Right old)
    Nothing -> do
      verified <- liftIO verifyOrigin
      either (throwIO . Abort) pure verified
      either (throwIO . Abort) pure (validateSnapshot initial)
      result <- persist identifier (G.CreateObjective (G.CreateObjectiveData identifier)) do
        -- Locks serialize identical creation, including creator-scoped retries.
        void (Tx.statement creator lockKey)
        old <- Tx.statement (creator, (operationKey operation)) selectOrigin
        when (isJust old) (throw Retry)
        now <- Tx.statement () currentTime
        unless (now < access.expiresAt && creationAllowed access.settings access.actor) (abort ObjectiveDenied)
        Tx.statement (identifier.value, initial) insertObjective
        writePayload identifier digest payload
        writeReceipt receipt (Right receipt)
        Tx.statement (creator, (operationKey operation), identifier.value, fingerprint, toJSON origin, receipt) insertOrigin
      recovered <- lookupOriginal
      pure case recovered of Right (Just old) -> Right old; Left err -> Left err; _ -> result >> Left ObjectiveUnresolved

-- Receipt recovery precedes transition validation. A prepare transaction writes
-- only definitive negative outcomes; a positive transition is repeated inside
-- the checked aggregate's append/projection transaction.
execute :: (ObjectiveEffects es) => Access -> ObjectiveId -> Integer -> OperationId -> Mutation -> Eff es (Either ObjectiveError Receipt)
execute access identifier expected operation mutation = guarded do
  unless (validKey (operationKey operation)) (throwIO (Abort (ObjectiveInvalid "invalid operation key")))
  loop (32 :: Int)
  where
    fingerprint = versionedDigest "shikigami.objective-command/1" (toJSON (access.actor, identifier, expected, operation, commandTag mutation, mutation))
    inspect = do
      current <- locked identifier
      checkAccess access current
      unless (authorized access current mutation) (abort ObjectiveDenied)
      old <- Tx.statement (identifier.value, (operationKey operation)) selectReceipt
      case old of
        Just (digest, outcome) -> pure (Left (if digest == fingerprint then outcome else Left ObjectiveConflict))
        Nothing -> do
          now <- Tx.statement () currentTime
          checked <- validateSources current mutation
          let next = maybe checked Left access.refusal >> validateTransition now access expected mutation current
          case next of
            Left err | err == ObjectiveUnavailable -> pure (Left (Left err))
            Left err -> do
              Tx.statement (identifier.value, (operationKey operation), fingerprint, Left err :: Either ObjectiveError Receipt) insertReceipt
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
              let nextRevision = before.revision + 1
                  command = G.ApplyObjectiveTransition (G.ApplyObjectiveTransitionData identifier (fromInteger before.revision) (fromInteger nextRevision) fingerprint)
              applied <- persist identifier command do
                current <- locked identifier
                checkAccess access current
                unless (authorized access current mutation) (abort ObjectiveDenied)
                unless (current.revision == before.revision) (throw Retry)
                old <- Tx.statement (identifier.value, (operationKey operation)) selectReceipt
                when (isJust old) (throw Retry)
                now <- Tx.statement () currentTime
                validateSources current mutation >>= require
                next <- require (validateTransition now access expected mutation current)
                let payload = toJSON (access.actor, mutation, next)
                    digest = versionedDigest "shikigami.objective-payload/1" payload
                    receipt = Receipt identifier operation fingerprint next.revision digest
                saveSnapshot next
                writePayload identifier digest payload
                case mutation of
                  Internal (IngestCheckpoint assignment intent _ _) -> Tx.statement (identifier.value, assignment.value, intent.sessionId.value, fromInteger intent.throughCursor) saveCursor
                  Public (BindConversation conversation) -> Tx.statement (conversation, identifier.value, toJSON receipt) bindConversation
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
  unless (not (Text.null objective.title) && Text.length objective.title <= 512 && not (Text.null objective.goal) && Text.length objective.goal <= 32768 && Text.length objective.instructions <= 32768 && length objective.external <= 64 && length objective.members <= 256 && length objective.decisions <= 64 && length objective.assumptions <= 64 && length objective.nextActions <= 64 && length objective.evidence <= 256 && length objective.unresolved <= 128 && all ((<= 4096) . Text.length) (objective.decisions <> objective.assumptions <> objective.nextActions) && Lazy.length (Aeson.encode objective) <= 1048576) (Left (ObjectiveInvalid "objective exceeds its bounds"))

versionFor :: Objective -> ObjectiveAssignmentId -> Either ObjectiveError CP.ObjectiveVersion
versionFor objective key = do
  assignment <- maybe (Left ObjectiveMissing) Right (find ((== key) . (.definition.assignmentId)) objective.assignments)
  root <- maybe (Left (ObjectiveInvalid "assignment has no admitted resource root")) Right assignment.definition.rootId
  cutoff <- maybe (Left (ObjectiveInvalid "assignment has no admitted cutoff")) Right assignment.definition.cutoff
  pure (CP.ObjectiveVersion objective.revision assignment.revision objective.criteriaRevision assignment.ownerEpoch assignment.definition.owner (objective.status == Open && assignment.definition.state `notElem` [Done, Withdrawn]) root cutoff)

validateTransition :: UTCTime -> Access -> Integer -> Mutation -> Objective -> Either ObjectiveError Objective
validateTransition _now access expected mutation current = do
  unless (authorized access current mutation) (Left ObjectiveDenied)
  unless (current.revision >= 0 && current.revision < toInteger (maxBound :: Int)) (Left ObjectiveUnavailable)
  case mutation of
    Internal (IngestCheckpoint key intent _ _) -> do
      actual <- versionFor current key
      let wanted = intent.expected
      unless (intent.format == 1 && expected == wanted.revision && expected >= 0 && expected <= actual.revision && actual.assignmentRevision == wanted.assignmentRevision && actual.criteriaRevision == wanted.criteriaRevision && actual.owner == wanted.owner && actual.ownerEpoch == wanted.ownerEpoch && actual.rootId == wanted.rootId && actual.active == wanted.active && intent.epoch == actual.ownerEpoch && wanted.cutoff == actual.cutoff) (Left ObjectiveConflict)
    _ -> unless (expected == current.revision) (Left ObjectiveConflict)
  next <- transition
  let advanced = next & #revision .~ (current.revision + 1)
  validateSnapshot advanced
  pure advanced
  where
    active = unless (current.status == Open) (Left (ObjectiveInvalid "objective is not open"))
    editable = unless (current.status `elem` [Open, Blocked]) (Left (ObjectiveInvalid "objective is terminal"))
    invalidate objective = objective & #assignments %~ map (\a -> a & #revision %~ (+ 1))
    changeAssignment key f = do
      unless (any ((== key) . (.definition.assignmentId)) current.assignments) (Left ObjectiveMissing)
      assignments <- traverse (\a -> if a.definition.assignmentId == key then (\next -> next & #revision .~ (a.revision + 1)) <$> f a else Right a) current.assignments
      pure (current & #assignments .~ assignments)
    withEvidence objective key inputs = do
      assignment <- maybe (Left ObjectiveMissing) Right (find ((== key) . (.definition.assignmentId)) objective.assignments)
      records <- forM inputs \input -> do
        unless (validKey input.key && all ((/= input.key) . (.input.key)) objective.evidence && any ((== input.criterion) . (.key)) objective.criteria && validKey (evidenceArtifact input)) (Left ObjectiveInvalidEvidence)
        disposition <- maybe (Left ObjectiveInvalidEvidence) Right (lookup input access.checks)
        case input of
          Attestation {statement} -> unless (not (Text.null statement) && Text.length statement <= 4096 && any (\criterion -> criterion.key == input.criterion && criterion.kind == HumanVerifiable) objective.criteria) (Left ObjectiveInvalidEvidence)
          _ -> pure ()
        pure (Evidence input disposition key (assignmentMeaning assignment) access.actor (current.revision + 1) current.instructionsRevision current.criteriaRevision)
      unless (length (nub (map (.input.key) records)) == length records) (Left ObjectiveInvalidEvidence)
      pure (objective & #evidence %~ (<> records))
    transition = case mutation of
      Public command -> case command of
        ReviseInstructions text -> do
          editable
          pure (invalidate (current & #instructions .~ text & #instructionsRevision %~ (+ 1)))
        ReviseCriteria criteria -> editable >> validateCriteria criteria >> pure (current & #criteria .~ criteria & #criteriaRevision %~ (+ 1))
        SetAssignments graph -> do
          editable
          validateGraph graph
          -- Retain withdrawn nodes: their identities and counters cannot revive.
          unless (all (\a -> a.definition.assignmentId `elem` map (.assignmentId) graph) current.assignments) (Left (ObjectiveInvalid "withdraw assignments instead of deleting identities"))
          assignments <- forM graph \draft -> case find ((== draft.assignmentId) . (.definition.assignmentId)) current.assignments of
            Nothing -> pure (Assignment draft 0 0 0 [])
            Just previous -> do
              unless (previous.definition.owner == draft.owner || isNothing previous.definition.sessionId) (Left (ObjectiveInvalid "session ownership requires fenced transfer"))
              unless (((isNothing previous.definition.sessionId && isNothing previous.definition.rootId) || (previous.definition.sessionId == draft.sessionId && previous.definition.rootId == draft.rootId && previous.definition.cutoff == draft.cutoff)) && (previous.definition.state /= Withdrawn || draft.state == Withdrawn)) (Left (ObjectiveInvalid "cannot replace an admitted binding or reuse an assignment"))
              pure if previous.definition == draft then previous else previous & #definition .~ draft & #revision %~ (+ 1) & #instructionsRevision %~ (if previous.definition.instructions == draft.instructions && previous.definition.dependencies == draft.dependencies && previous.definition.owner == draft.owner then id else (+ 1))
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
          let status = if blocked then Blocked else Open
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
        BindConversation conversation -> editable >> (if validKey conversation then Right current else Left (ObjectiveInvalid "invalid conversation"))
        LinkExternal reference -> editable >> pure (current & #external %~ (\refs -> nub (refs <> [reference])))
      Internal (TransferOwnership key epoch owner) -> do
        unless (either (const False) validKey (identityText owner)) (Left ObjectiveDenied)
        changeAssignment key \assignment -> do
          unless (assignment.ownerEpoch == epoch) (Left ObjectiveConflict)
          pure (assignment & #definition . #owner .~ owner & #ownerEpoch %~ (+ 1))
      Internal (IngestCheckpoint key _ inputs unresolved) -> do
        changed <- changeAssignment key (Right . (\a -> a & #acceptedResults %~ (<> map (.key) inputs)))
        recorded <- withEvidence changed key inputs
        unless (all ((== key) . (.assignmentId)) unresolved) (Left ObjectiveInvalidEvidence)
        pure (recorded & #unresolved .~ (filter ((/= key) . (.assignmentId)) current.unresolved <> unresolved))

-- | Source authenticity is checked again inside the commit transaction. Future
-- provider adapters additionally validate accepted execution/fence coordinates.
validateSources :: Objective -> Mutation -> Transaction (Either ObjectiveError ())
validateSources objective mutation = do
  evidence <- forM (evidenceInputs mutation) \case
    ResultEvidence {result = WorkerResult receipt artifact} -> do
      let addressed = case mutation of Public (RecordEvidence key _) -> Just key; Internal (IngestCheckpoint key _ _ _) -> Just key; _ -> Nothing
          bound = any (\a -> Just a.definition.assignmentId == addressed && a.definition.sessionId == Just receipt.sessionId) objective.assignments
      stored <- Tx.statement (receipt.sessionId.value, receipt.assignmentId.value) selectWorkerResult
      case stored of
        Just (actual, payload) -> pure do
          unless (bound && actual == receipt && versionedDigest "shikigami.worker-session-payload/1" payload == receipt.output.digest) (Left ObjectiveInvalidEvidence)
          result <- case payload of
            Aeson.Object fields -> case Aeson.parseMaybe (\o -> o .: "content") fields of
              Just value -> Right (value :: WS.AssignmentResult)
              Nothing -> Left ObjectiveInvalidEvidence
            _ -> Left ObjectiveInvalidEvidence
          unless (artifact `elem` result.artifacts && result.assignmentId == receipt.assignmentId && result.disposition == receipt.disposition) (Left ObjectiveInvalidEvidence)
        Nothing -> pure (Left ObjectiveInvalidEvidence)
    _ -> pure (Right ())
  bindings <- case mutation of
    Public (SetAssignments graph) -> forM graph \draft -> case draft.sessionId of
      Nothing -> pure (Right ())
      Just session -> do
        actual <- Tx.statement session.value selectWorkerBinding
        let epoch = maybe 0 (.ownerEpoch) (find ((== draft.assignmentId) . (.definition.assignmentId)) objective.assignments)
        pure $ case actual of
          Just (state, binding) | state.owner == draft.owner && state.epoch == epoch && Just binding.rootId == draft.rootId && binding.objective == referenceFor objective.objectiveId draft.assignmentId -> Right ()
          _ -> Left ObjectiveConflict
    _ -> pure []
  checkpoint <- case mutation of
    Internal (IngestCheckpoint key intent inputs _) -> do
      storedIntent <- Tx.statement (intent.sessionId.value, operationKey intent.operationId) selectCheckpoint
      let original = storedIntent >>= \value -> case Aeson.fromJSON value of Aeson.Success decoded -> Just decoded; _ -> Nothing
      cursor <- fromMaybe 0 <$> Tx.statement (objective.objectiveId.value, key.value, intent.sessionId.value) selectCursor
      case find ((== key) . (.definition.assignmentId)) objective.assignments of
        Just assignment -> pure do
          unless (assignment.definition.sessionId == Just intent.sessionId && intent.actor `matchesActor` objective && original == Just intent && intent.objective == referenceFor objective.objectiveId key && cursor == intent.previousCursor && intent.throughCursor > cursor && intent.throughCursor - cursor <= 100 && map (.cursor) intent.events == [cursor + 1 .. intent.throughCursor]) (Left ObjectiveConflict)
          let results = [receipt | WS.EventReceipt {event = WS.ResultAvailable receipt} <- intent.events]
          forM_ inputs \case
            ResultEvidence {result = WorkerResult receipt _} -> unless (receipt `elem` results) (Left ObjectiveInvalidEvidence)
            _ -> Left ObjectiveInvalidEvidence
        Nothing -> pure (Left ObjectiveMissing)
    _ -> pure (Right ())
  pure (sequence_ evidence >> sequence_ bindings >> checkpoint)
  where
    matchesActor actor obj = not (null (rolesFor obj (RecordedAgent actor)))

referenceFor :: ObjectiveId -> ObjectiveAssignmentId -> WS.ObjectiveRef
referenceFor objective assignment = WS.ObjectiveRef "shikigami-objective-v1" (versionedDigest "shikigami.objective-assignment-ref/1" (toJSON (objective, assignment)))

locked :: ObjectiveId -> Transaction Objective
locked identifier = Tx.statement identifier.value lockObjective >>= maybe (abort ObjectiveMissing) pure

saveSnapshot :: Objective -> Transaction ()
saveSnapshot objective = do
  Tx.statement (objective.objectiveId.value, objective) updateObjective
  forM_ objective.assignments \assignment -> Tx.statement (objective.objectiveId.value, assignment.definition.assignmentId.value, (referenceFor objective.objectiveId assignment.definition.assignmentId).key, assignment) saveAssignment

writePayload :: ObjectiveId -> Text -> Aeson.Value -> Transaction ()
writePayload objective digest payload = Tx.statement (objective.value, digest, payload) insertPayload

writeReceipt :: Receipt -> Either ObjectiveError Receipt -> Transaction ()
writeReceipt receipt outcome = Tx.statement (receipt.objectiveId.value, operationKey receipt.operationId, receipt.fingerprint, outcome) insertReceipt

-- A rejected Keiro command or concurrent duplicate is retried through the locked
-- inspector. Transport failure remains unavailable/uncertain, never a rejection.
persist :: (ObjectiveEffects es) => ObjectiveId -> G.ObjectiveLifecycleCommand -> Transaction () -> Eff es (Either ObjectiveError ())
persist objective command action = guarded do
  let (catalog, projections) = withLiveObjective (\_ _ -> action)
  options <- commandOptions
  outcome <- runCommandWithCatalogProjections options objectiveLifecycleEventStream (Stream.entityStream objectiveLifecycleCategory objective.value) command catalog projections
  pure case outcome of
    Right (ProjectionCommandApplied _) -> Right ()
    Right _ -> Left ObjectiveUnavailable
    Left CommandRejected -> Left ObjectiveConflict
    Left (StoreFailed _) -> Left ObjectiveUnavailable
    Left (RetryExhausted _ _) -> Left ObjectiveUnavailable
    Left _ -> Left ObjectiveUnavailable

protected :: (ObjectiveEffects es, ToJSON a, FromJSON a) => Transaction a -> Eff es (Either ObjectiveError a)
protected action = guarded do
  result <- runQuery Nothing objectiveLookupReadModel (toJSON <$> action)
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
operationKey (OperationId key) = key

textParam :: E.Params Text
textParam = E.param (E.nonNullable E.text)

jsonParam :: (ToJSON a) => E.Params a
jsonParam = toJSON >$< E.param (E.nonNullable E.jsonb)

intParam :: E.Params Int64
intParam = E.param (E.nonNullable E.int8)

jsonRow :: (FromJSON a) => D.Row a
jsonRow = D.column (D.nonNullable (D.refine (\value -> case Aeson.fromJSON value of Aeson.Success answer -> Right answer; Aeson.Error _ -> Left "unreadable objective record") D.jsonb))

lockObjective :: Statement Text (Maybe Objective)
lockObjective = preparable "SELECT state FROM shikigami.objectives WHERE objective_id=$1 FOR UPDATE" textParam (D.rowMaybe jsonRow)

insertObjective, updateObjective :: Statement (Text, Objective) ()
insertObjective = preparable "INSERT INTO shikigami.objectives(objective_id,state) VALUES ($1,$2)" (contrazip2 textParam jsonParam) D.noResult
updateObjective = preparable "UPDATE shikigami.objectives SET state=$2,updated_at=clock_timestamp() WHERE objective_id=$1" (contrazip2 textParam jsonParam) D.noResult

saveAssignment :: Statement (Text, Text, Text, Assignment) ()
saveAssignment = preparable "INSERT INTO shikigami.objective_assignments(objective_id,assignment_id,reference_key,state) VALUES ($1,$2,$3,$4) ON CONFLICT (objective_id,assignment_id) DO UPDATE SET state=$4" (contrazip4 textParam textParam textParam jsonParam) D.noResult

insertPayload :: Statement (Text, Text, Aeson.Value) ()
insertPayload = preparable "INSERT INTO shikigami.objective_payloads(objective_id,digest,payload) VALUES ($1,$2,$3)" (contrazip3 textParam textParam jsonParam) D.noResult

selectReceipt :: Statement (Text, Text) (Maybe (Text, Either ObjectiveError Receipt))
selectReceipt = preparable "SELECT fingerprint,outcome FROM shikigami.objective_receipts WHERE objective_id=$1 AND operation_key=$2" (contrazip2 textParam textParam) (D.rowMaybe ((,) <$> D.column (D.nonNullable D.text) <*> jsonRow))

insertReceipt :: Statement (Text, Text, Text, Either ObjectiveError Receipt) ()
insertReceipt = preparable "INSERT INTO shikigami.objective_receipts(objective_id,operation_key,fingerprint,outcome) VALUES ($1,$2,$3,$4)" (contrazip4 textParam textParam textParam jsonParam) D.noResult

selectOrigin :: Statement (Text, Text) (Maybe (Text, Receipt))
selectOrigin = preparable "SELECT fingerprint,receipt FROM shikigami.objective_origins WHERE creator_key=$1 AND operation_key=$2" (contrazip2 textParam textParam) (D.rowMaybe ((,) <$> D.column (D.nonNullable D.text) <*> jsonRow))

insertOrigin :: Statement (Text, Text, Text, Text, Aeson.Value, Receipt) ()
insertOrigin = preparable "INSERT INTO shikigami.objective_origins(creator_key,operation_key,objective_id,fingerprint,origin,receipt) VALUES ($1,$2,$3,$4,$5,$6)" (contrazip6 textParam textParam textParam textParam jsonParam jsonParam) D.noResult

lockKey :: Statement Text ()
lockKey = preparable "SELECT pg_advisory_xact_lock(hashtextextended($1,0))" textParam D.noResult

currentTime :: Statement () UTCTime
currentTime = preparable "SELECT clock_timestamp()" E.noParams (D.singleRow (D.column (D.nonNullable D.timestamptz)))

selectWorkerResult :: Statement (Text, Text) (Maybe (WS.ResultReceipt, Aeson.Value))
selectWorkerResult = preparable "SELECT r.state,p.body FROM shikigami.worker_session_results r JOIN shikigami.worker_session_payloads p ON p.session_id=r.session_id AND p.payload_id=r.state->'output'->>'payloadId' WHERE r.session_id=$1 AND r.assignment_id=$2" (contrazip2 textParam textParam) (D.rowMaybe ((,) <$> jsonRow <*> D.column (D.nonNullable D.jsonb)))

selectCheckpoint :: Statement (Text, Text) (Maybe Aeson.Value)
selectCheckpoint = preparable "SELECT state FROM shikigami.worker_session_commands WHERE session_id=$1 AND operation_id=$2" (contrazip2 textParam textParam) (D.rowMaybe jsonRow)

selectCursor :: Statement (Text, Text, Text) (Maybe Integer)
selectCursor = preparable "SELECT cursor FROM shikigami.objective_cursors WHERE objective_id=$1 AND assignment_id=$2 AND session_id=$3" (contrazip3 textParam textParam textParam) (D.rowMaybe (toInteger <$> D.column (D.nonNullable D.int8)))

saveCursor :: Statement (Text, Text, Text, Int64) ()
saveCursor = preparable "INSERT INTO shikigami.objective_cursors(objective_id,assignment_id,session_id,cursor) VALUES ($1,$2,$3,$4) ON CONFLICT (objective_id,assignment_id,session_id) DO UPDATE SET cursor=$4" (contrazip4 textParam textParam textParam intParam) D.noResult

bindConversation :: Statement (Text, Text, Aeson.Value) ()
bindConversation = preparable "INSERT INTO shikigami.objective_associations(kind,source_id,objective_id,binding) VALUES ('conversation',$1,$2,$3) ON CONFLICT (kind,source_id,objective_id) DO UPDATE SET binding=$3" (contrazip3 textParam textParam jsonParam) D.noResult

selectReference :: Statement Text (Maybe (Text, Text))
selectReference = preparable "SELECT objective_id,assignment_id FROM shikigami.objective_assignments WHERE reference_key=$1" textParam (D.rowMaybe ((,) <$> D.column (D.nonNullable D.text) <*> D.column (D.nonNullable D.text)))

selectWorkerBinding :: Statement Text (Maybe (WS.SessionState, WS.SessionBinding))
selectWorkerBinding = preparable "SELECT state,binding FROM shikigami.worker_sessions WHERE session_id=$1" textParam (D.rowMaybe ((,) <$> jsonRow <*> jsonRow))
