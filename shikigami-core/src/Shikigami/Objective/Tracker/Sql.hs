{-# LANGUAGE DataKinds #-}

-- | Package-private protected storage primitives. Callers must hold the
-- objective lock and the catalog transaction fence before using these writes.
module Shikigami.Objective.Tracker.Sql where

import Contravariant.Extras (contrazip2, contrazip3, contrazip4, contrazip5, contrazip7)
import Control.Exception (Exception, throw)
import Data.Aeson qualified as Aeson
import Data.Functor.Contravariant ((>$<))
import Data.Int (Int64)
import Hasql.Decoders qualified as D
import Hasql.Encoders qualified as E
import Hasql.Statement (Statement, preparable)
import Hasql.Transaction (Transaction)
import Hasql.Transaction qualified as Tx
import Shikigami.Execution.Identity (OperationId, operationIdText, parseOperationId)
import Shikigami.Objective.Tracker.Control.Types
import Shikigami.Objective.Tracker.Mapping (validatePolicy)
import Shikigami.Objective.Tracker.Types
import Shikigami.Objective.Types (AccessPrincipal, ObjectiveId, objectiveIdText, parseObjectiveId)
import Shikigami.Prelude
import Shikigami.StateRevision

newtype TrackerFailure = TrackerFailure TrackerError deriving stock (Show)

instance Exception TrackerFailure

abort :: TrackerError -> Transaction a
abort error = Tx.condemn >> throw (TrackerFailure error)

require :: Either TrackerError a -> Transaction a
require = either abort pure

decode :: (FromJSON a) => Aeson.Value -> Transaction a
decode value = case Aeson.fromJSON value of Aeson.Success answer -> pure answer; Aeson.Error _ -> abort TrackerConflict

textParam :: E.Params Text
textParam = E.param (E.nonNullable E.text)

jsonParam :: (ToJSON a) => E.Params a
jsonParam = toJSON >$< E.param (E.nonNullable E.jsonb)

jsonColumn :: D.Row Aeson.Value
jsonColumn = D.column (D.nonNullable D.jsonb)

type BindingRow = (Text, Text, Text, Text, Text, Bool, Aeson.Value)

bindingColumns :: Text
bindingColumns = "binding_id,objective_id,connection_id,incarnation,resource_id,active,state"

bindingRow :: D.Row BindingRow
bindingRow = (,,,,,,) <$> textColumn <*> textColumn <*> textColumn <*> textColumn <*> textColumn <*> D.column (D.nonNullable D.bool) <*> jsonColumn

textColumn :: D.Row Text
textColumn = D.column (D.nonNullable D.text)

decodeBinding :: BindingRow -> Transaction TrackerBinding
decodeBinding (identifier, objective, connection, incarnation, resource, active, raw) = do
  binding <- decode raw
  unless (coordinateText binding.bindingId == identifier && objectiveIdText binding.objectiveId == objective && coordinateText binding.scope.connectionId == connection && coordinateText binding.scope.incarnation == incarnation && coordinateText binding.scope.resourceId == resource && active == (binding.state /= ReconciliationOnly) && binding.baseline.scope == binding.scope && binding.latest.scope == binding.scope && binding.baseline.digest == observationDigest binding.baseline.snapshot && binding.latest.digest == observationDigest binding.latest.snapshot) (abort TrackerConflict)
  require (validatePolicy binding.policy)
  pure binding

bindingsFor :: ObjectiveId -> Transaction [TrackerBinding]
bindingsFor objective = do
  rows <- Tx.statement (objectiveIdText objective) selectBindings
  unless (length rows <= 64) (abort TrackerConflict)
  traverse decodeBinding rows

selectBindings :: Statement Text [BindingRow]
selectBindings = preparable ("SELECT " <> bindingColumns <> " FROM shikigami.objective_tracker_bindings WHERE objective_id=$1 ORDER BY binding_id LIMIT 65 FOR UPDATE") textParam (D.rowList bindingRow)

bindingById :: TrackerBindingId -> Transaction TrackerBinding
bindingById identifier = do
  value <- Tx.statement (coordinateText identifier) (preparable ("SELECT " <> bindingColumns <> " FROM shikigami.objective_tracker_bindings WHERE binding_id=$1 FOR UPDATE") textParam (D.rowMaybe bindingRow)) >>= maybe (abort TrackerMissing) decodeBinding
  unless (value.bindingId == identifier) (abort TrackerConflict)
  pure value

-- Global remote-resource admission is serialized before a uniqueness check;
-- objective-local locks alone cannot serialize two different objectives.
lockResource :: ResourceScope -> Transaction ()
lockResource scope = void (Tx.statement (digestText (trackerDigest "shikigami.tracker-resource-lock/1" (toJSON (scope.connectionId, scope.incarnation, scope.resourceId)) :: TrackerDigest "resource-lock")) (preparable "SELECT pg_advisory_xact_lock(hashtextextended($1,0))" textParam D.noResult))

resourceBindings :: ResourceScope -> Transaction [TrackerBinding]
resourceBindings scope = Tx.statement (coordinateText scope.connectionId, coordinateText scope.incarnation, coordinateText scope.resourceId) (preparable ("SELECT " <> bindingColumns <> " FROM shikigami.objective_tracker_bindings WHERE connection_id=$1 AND incarnation=$2 AND resource_id=$3 AND (active OR EXISTS (SELECT 1 FROM shikigami.objective_tracker_publications p WHERE p.binding_id=shikigami.objective_tracker_bindings.binding_id AND p.receipt_state IN ('Attempting','Unknown'))) ORDER BY binding_id LIMIT 65 FOR UPDATE") (contrazip3 textParam textParam textParam) (D.rowList bindingRow)) >>= traverse decodeBinding

insertBinding :: TrackerBinding -> Transaction ()
insertBinding binding = Tx.statement (coordinateText binding.bindingId, objectiveIdText binding.objectiveId, coordinateText binding.scope.connectionId, coordinateText binding.scope.incarnation, coordinateText binding.scope.resourceId, binding.state /= ReconciliationOnly, binding) (preparable "INSERT INTO shikigami.objective_tracker_bindings(binding_id,objective_id,connection_id,incarnation,resource_id,active,state,last_observed_at) VALUES($1,$2,$3,$4,$5,$6,$7,clock_timestamp())" (contrazip7 textParam textParam textParam textParam textParam (E.param (E.nonNullable E.bool)) jsonParam) D.noResult)

saveBinding :: TrackerBinding -> Transaction ()
saveBinding binding = Tx.statement (coordinateText binding.bindingId, binding.state /= ReconciliationOnly, binding) (preparable "UPDATE shikigami.objective_tracker_bindings SET active=$2,state=$3 WHERE binding_id=$1" (contrazip3 textParam (E.param (E.nonNullable E.bool)) jsonParam) D.noResult)

retainObservation :: TrackerBindingId -> TrackerObservation -> Text -> Transaction ()
retainObservation identifier observation disposition = do
  let key = digestText (trackerDigest "shikigami.tracker-observation-key/1" (toJSON (identifier, observation, disposition)) :: TrackerDigest "observation-key")
  Tx.statement (key, coordinateText identifier, disposition, observation) (preparable "INSERT INTO shikigami.objective_tracker_observations(observation_key,binding_id,disposition,observation,observed_at) VALUES($1,$2,$3,$4,clock_timestamp()) ON CONFLICT(observation_key) DO NOTHING" (contrazip4 textParam textParam textParam jsonParam) D.noResult)

observationsFor :: TrackerBindingId -> Transaction [(Text, TrackerObservation)]
observationsFor identifier = Tx.statement (coordinateText identifier) (preparable "SELECT disposition,observation FROM shikigami.objective_tracker_observations WHERE binding_id=$1 ORDER BY position DESC LIMIT 100" textParam (D.rowList ((,) <$> textColumn <*> jsonColumn))) >>= traverse (\(disposition, raw) -> (disposition,) <$> decode raw)

proposalsFor :: TrackerBindingId -> Transaction [ImportProposal]
proposalsFor identifier = Tx.statement (coordinateText identifier) (preparable "SELECT proposal_id,state FROM shikigami.objective_tracker_proposals WHERE binding_id=$1 ORDER BY (state->>'state'='AwaitingDecision') DESC,proposal_id LIMIT 100 FOR UPDATE" textParam (D.rowList ((,) <$> textColumn <*> jsonColumn))) >>= traverse (decodeProposal identifier)

awaitingProposalsFor :: TrackerBindingId -> Transaction [ImportProposal]
awaitingProposalsFor identifier = do
  rows <- Tx.statement (coordinateText identifier) (preparable "SELECT proposal_id,state FROM shikigami.objective_tracker_proposals WHERE binding_id=$1 AND state->>'state'='AwaitingDecision' ORDER BY proposal_id LIMIT 3 FOR UPDATE" textParam (D.rowList ((,) <$> textColumn <*> jsonColumn)))
  unless (length rows <= 2) (abort TrackerConflict)
  traverse (decodeProposal identifier) rows

decodeProposal :: TrackerBindingId -> (Text, Aeson.Value) -> Transaction ImportProposal
decodeProposal identifier (key, raw) = do
  proposal <- decode raw
  unless (coordinateText proposal.proposalId == key && proposal.bindingId == identifier && proposal.observation.digest == observationDigest proposal.observation.snapshot) (abort TrackerConflict)
  pure proposal

proposalById :: ProposalId -> Transaction ImportProposal
proposalById identifier = do
  proposal <- Tx.statement (coordinateText identifier) (preparable "SELECT state FROM shikigami.objective_tracker_proposals WHERE proposal_id=$1 FOR UPDATE" textParam (D.rowMaybe jsonColumn)) >>= maybe (abort TrackerMissing) decode
  unless (proposal.proposalId == identifier) (abort TrackerConflict)
  pure proposal

insertProposal :: ImportProposal -> Transaction ()
insertProposal proposal = Tx.statement (coordinateText proposal.proposalId, coordinateText proposal.bindingId, proposal) (preparable "INSERT INTO shikigami.objective_tracker_proposals(proposal_id,binding_id,state) VALUES($1,$2,$3) ON CONFLICT(proposal_id) DO NOTHING" (contrazip3 textParam textParam jsonParam) D.noResult)

saveProposal :: ImportProposal -> Transaction ()
saveProposal proposal = Tx.statement (coordinateText proposal.proposalId, proposal) (preparable "UPDATE shikigami.objective_tracker_proposals SET state=$2 WHERE proposal_id=$1" (contrazip2 textParam jsonParam) D.noResult)

lookupReceipt :: ObjectiveId -> OperationId -> Transaction (Maybe CommandReceipt)
lookupReceipt objective operation = do
  value <- Tx.statement (objectiveIdText objective, operationIdText operation) (preparable "SELECT receipt FROM shikigami.objective_tracker_commands WHERE objective_id=$1 AND operation_key=$2 AND receipt IS NOT NULL" (contrazip2 textParam textParam) (D.rowMaybe jsonColumn))
  traverse decode value

insertReceipt :: ObjectiveId -> CommandReceipt -> Transaction ()
insertReceipt objective receipt = Tx.statement (objectiveIdText objective, operationIdText receipt.operationId, digestText receipt.fingerprint, receipt) (preparable "INSERT INTO shikigami.objective_tracker_commands(objective_id,operation_key,fingerprint,receipt) VALUES($1,$2,$3,$4) ON CONFLICT(objective_id,operation_key) DO UPDATE SET fingerprint=EXCLUDED.fingerprint,receipt=EXCLUDED.receipt WHERE shikigami.objective_tracker_commands.receipt IS NULL" (contrazip4 textParam textParam textParam jsonParam) D.noResult)

-- Public inspection is bounded; internal barriers and the latest export base
-- have dedicated indexed queries, so a long history cannot hide Unknown work.
publicationsFor :: TrackerBindingId -> Transaction [(PublicationIntent, PublicationReceipt)]
publicationsFor identifier = Tx.statement (coordinateText identifier) (preparable "SELECT publication_id,receipt_state,intent,receipt FROM shikigami.objective_tracker_publications WHERE binding_id=$1 ORDER BY objective_revision,publication_id LIMIT 100 FOR UPDATE" textParam (D.rowList publicationRow)) >>= traverse decodePublication

type PublicationRow = (Text, Text, Aeson.Value, Aeson.Value)

publicationRow :: D.Row PublicationRow
publicationRow = (,,,) <$> textColumn <*> textColumn <*> jsonColumn <*> jsonColumn

decodePublication :: PublicationRow -> Transaction (PublicationIntent, PublicationReceipt)
decodePublication (identifier, state, rawIntent, rawReceipt) = do
  intent <- decode rawIntent
  receipt <- decode rawReceipt
  unless (coordinateText intent.publicationId == identifier && receipt.publicationId == intent.publicationId && intent.digest == publicationDigest intent && stateText receipt.state == state) (abort TrackerConflict)
  forM_ receipt.attempt \attempt -> do
    original <- Tx.statement (coordinateText attempt.attemptId) (preparable "SELECT attempt FROM shikigami.objective_tracker_attempts WHERE attempt_id=$1" textParam (D.rowMaybe jsonColumn)) >>= maybe (abort TrackerConflict) decode
    unless (original == attempt && attempt.publicationId == intent.publicationId && attempt.bindingRevision == intent.bindingRevision && attempt.capabilities.revision == intent.scope.providerRevision) (abort TrackerConflict)
  unless (receipt.state `notElem` [Attempting, Unknown, Delivered] || isJust receipt.attempt) (abort TrackerConflict)
  pure (intent, receipt)

latestPublication :: TrackerBindingId -> Transaction (Maybe (PublicationIntent, PublicationReceipt))
latestPublication identifier = Tx.statement (coordinateText identifier) (preparable "SELECT publication_id,receipt_state,intent,receipt FROM shikigami.objective_tracker_publications WHERE binding_id=$1 ORDER BY objective_revision DESC,publication_id DESC LIMIT 1 FOR UPDATE" textParam (D.rowMaybe publicationRow)) >>= traverse decodePublication

hasUnresolved :: TrackerBindingId -> Transaction Bool
hasUnresolved identifier = do
  row <- Tx.statement (coordinateText identifier) (preparable "SELECT publication_id,receipt_state,intent,receipt FROM shikigami.objective_tracker_publications WHERE binding_id=$1 AND receipt_state IN ('Attempting','Unknown') ORDER BY objective_revision LIMIT 1 FOR UPDATE" textParam (D.rowMaybe publicationRow))
  isJust <$> traverse decodePublication row

hasEarlierUnsettled :: TrackerBindingId -> StateRevision "objective" -> Transaction Bool
hasEarlierUnsettled identifier revision = do
  row <- Tx.statement (coordinateText identifier, fromInteger (revisionNumber revision) :: Int64) (preparable "SELECT publication_id,receipt_state,intent,receipt FROM shikigami.objective_tracker_publications WHERE binding_id=$1 AND objective_revision<$2 AND receipt_state IN ('Pending','Attempting','Unknown') ORDER BY objective_revision LIMIT 1 FOR UPDATE" (contrazip2 textParam (E.param (E.nonNullable E.int8))) (D.rowMaybe publicationRow))
  isJust <$> traverse decodePublication row

publicationById :: PublicationId -> Transaction (PublicationIntent, PublicationReceipt)
publicationById identifier = Tx.statement (coordinateText identifier) (preparable "SELECT publication_id,receipt_state,intent,receipt FROM shikigami.objective_tracker_publications WHERE publication_id=$1 FOR UPDATE" textParam (D.rowMaybe publicationRow)) >>= maybe (abort TrackerMissing) decodePublication

stateText :: DeliveryState -> Text
stateText = \case Pending -> "Pending"; Attempting -> "Attempting"; Delivered -> "Delivered"; Rejected -> "Rejected"; Conflict -> "Conflict"; Unknown -> "Unknown"; Suppressed -> "Suppressed"

insertPublication :: PublicationIntent -> PublicationReceipt -> Transaction ()
insertPublication intent receipt = Tx.statement (coordinateText intent.publicationId, coordinateText intent.bindingId, fromInteger (revisionNumber intent.objectiveRevision) :: Int64, stateText receipt.state, toJSON (intent, receipt)) (preparable "INSERT INTO shikigami.objective_tracker_publications(publication_id,binding_id,objective_revision,receipt_state,intent,receipt) VALUES($1,$2,$3,$4,$5->0,$5->1)" (contrazip5 textParam textParam (E.param (E.nonNullable E.int8)) textParam jsonParam) D.noResult)

savePublicationReceipt :: PublicationReceipt -> Transaction ()
savePublicationReceipt receipt = Tx.statement (coordinateText receipt.publicationId, stateText receipt.state, receipt) (preparable "UPDATE shikigami.objective_tracker_publications SET receipt_state=$2,receipt=$3 WHERE publication_id=$1" (contrazip3 textParam textParam jsonParam) D.noResult)

insertAttempt :: PublicationAttempt -> Transaction ()
insertAttempt attempt = Tx.statement (coordinateText attempt.attemptId, coordinateText attempt.publicationId, attempt) (preparable "INSERT INTO shikigami.objective_tracker_attempts(attempt_id,publication_id,attempt) VALUES($1,$2,$3)" (contrazip3 textParam textParam jsonParam) D.noResult)

retainVerification :: VerifiedDelivery -> Transaction ()
retainVerification evidence = Tx.statement (verificationKey evidence, coordinateText evidence.publicationId, evidence) (preparable "INSERT INTO shikigami.objective_tracker_verifications(verification_key,publication_id,evidence) VALUES($1,$2,$3) ON CONFLICT(verification_key) DO NOTHING" (contrazip3 textParam textParam jsonParam) D.noResult)

hasVerification :: VerifiedDelivery -> Transaction Bool
hasVerification evidence = do
  value <- Tx.statement (verificationKey evidence) (preparable "SELECT evidence FROM shikigami.objective_tracker_verifications WHERE verification_key=$1" textParam (D.rowMaybe jsonColumn))
  case value of Nothing -> pure False; Just raw -> (== evidence) <$> decode raw

verificationKey :: VerifiedDelivery -> Text
verificationKey = digestText . (trackerDigest "shikigami.tracker-verification/1" :: Aeson.Value -> TrackerDigest "verification-key") . toJSON

-- Only routing coordinates leave this bounded process scan. Every subsequent
-- lookup rechecks objective permission before revealing protected state.
routingKeys :: Maybe TrackerBindingId -> Int -> Transaction [(ObjectiveId, TrackerBindingId)]
routingKeys after limit = do
  rows <- Tx.statement (maybe "" coordinateText after, fromIntegral (max 1 (min 100 limit)) :: Int64) (preparable "SELECT objective_id,binding_id FROM shikigami.objective_tracker_bindings WHERE binding_id>$1 AND (active OR EXISTS (SELECT 1 FROM shikigami.objective_tracker_publications p WHERE p.binding_id=shikigami.objective_tracker_bindings.binding_id AND p.receipt_state IN ('Pending','Attempting','Unknown'))) ORDER BY binding_id LIMIT $2" (contrazip2 textParam (E.param (E.nonNullable E.int8))) (D.rowList ((,) <$> textColumn <*> textColumn)))
  forM rows \(objective, binding) -> (,) <$> require (either (const (Left TrackerConflict)) Right (parseObjectiveId objective)) <*> require (either (const (Left TrackerConflict)) Right (parseCoordinate binding))

nextUnsettled :: TrackerBindingId -> Transaction (Maybe (PublicationIntent, PublicationReceipt))
nextUnsettled identifier = Tx.statement (coordinateText identifier) (preparable "SELECT publication_id,receipt_state,intent,receipt FROM shikigami.objective_tracker_publications WHERE binding_id=$1 AND receipt_state IN ('Pending','Attempting','Unknown') ORDER BY objective_revision,publication_id LIMIT 1 FOR UPDATE" textParam (D.rowMaybe publicationRow)) >>= traverse decodePublication

controlById :: ObjectiveId -> OperationId -> Transaction (Maybe ControlRecord)
controlById objective operation = do
  row <- Tx.statement (objectiveIdText objective, operationIdText operation) (preparable "SELECT control_actor,pending,control FROM shikigami.objective_tracker_commands WHERE objective_id=$1 AND operation_key=$2 AND control IS NOT NULL FOR UPDATE" (contrazip2 textParam textParam) (D.rowMaybe ((,,) <$> jsonColumn <*> D.column (D.nonNullable D.bool) <*> jsonColumn)))
  forM row \(rawActor, pending, raw) -> do
    record <- decode raw
    actor <- decode rawActor
    unless (record.objectiveId == objective && record.operationId == operation && record.actor == actor && pending == (record.state /= Finished) && record.fingerprint == controlFingerprint record) (abort TrackerConflict)
    unless (case record.state of Queued -> isNothing record.claim && isNothing record.failure; Running -> isJust record.claim && isNothing record.failure; Finished -> isNothing record.claim) (abort TrackerConflict)
    pure record

insertControl :: ControlRecord -> Transaction ()
insertControl record = Tx.statement (objectiveIdText record.objectiveId, operationIdText record.operationId, digestText record.fingerprint, toJSON record.actor, record) (preparable "INSERT INTO shikigami.objective_tracker_commands(objective_id,operation_key,fingerprint,control_actor,pending,control) VALUES($1,$2,$3,$4,true,$5)" (contrazip5 textParam textParam textParam jsonParam jsonParam) D.noResult)

saveControl :: ControlRecord -> Transaction ()
saveControl record = Tx.statement (objectiveIdText record.objectiveId, operationIdText record.operationId, record.state /= Finished, record) (preparable "UPDATE shikigami.objective_tracker_commands SET pending=$3,control=$4 WHERE objective_id=$1 AND operation_key=$2 AND control IS NOT NULL" (contrazip4 textParam textParam (E.param (E.nonNullable E.bool)) jsonParam) D.noResult)

pendingControls :: Maybe (ObjectiveId, OperationId) -> Int -> Transaction [(ObjectiveId, OperationId, AccessPrincipal)]
pendingControls after limit = do
  let (objective, operation) = maybe ("", "") (\(o, k) -> (objectiveIdText o, operationIdText k)) after
  rows <- Tx.statement (objective, operation, fromIntegral (max 1 (min 100 limit)) :: Int64) (preparable "SELECT objective_id,operation_key,control_actor FROM shikigami.objective_tracker_commands WHERE pending AND (objective_id,operation_key)>($1,$2) ORDER BY objective_id,operation_key LIMIT $3" (contrazip3 textParam textParam (E.param (E.nonNullable E.int8))) (D.rowList ((,,) <$> textColumn <*> textColumn <*> jsonColumn)))
  forM rows \(o, k, a) -> (,,) <$> require (either (const (Left TrackerConflict)) Right (parseObjectiveId o)) <*> require (either (const (Left TrackerConflict)) Right (parseOperationId k)) <*> decode a

historyPage :: TrackerBindingId -> HistoryKind -> Bool -> Maybe Text -> Int -> Transaction [HistoryRecord]
historyPage identifier kind forward after limit = do
  let comparator = if forward then ">" else "<"
      direction = if forward then "ASC" else "DESC"
      boundary = fromMaybe (if forward then "" else "~") after
      parameters = (coordinateText identifier, boundary, fromIntegral (max 1 (min 101 limit)) :: Int64)
      encoder = contrazip3 textParam textParam (E.param (E.nonNullable E.int8))
      suffix key = " WHERE binding_id=$1 AND " <> key <> comparator <> "$2 ORDER BY " <> key <> " " <> direction <> " LIMIT $3 FOR UPDATE"
  case kind of
    Observations -> do
      rows <- Tx.statement parameters (preparable ("SELECT lpad(position::text,20,'0'),disposition,observation FROM shikigami.objective_tracker_observations" <> suffix "lpad(position::text,20,'0')") encoder (D.rowList ((,,) <$> textColumn <*> textColumn <*> jsonColumn)))
      forM rows \(key, disposition, raw) -> do
        observation <- decode @TrackerObservation raw
        unless (observation.digest == observationDigest observation.snapshot) (abort TrackerConflict)
        pure (HistoryRecord key (toJSON (disposition, observation)))
    Proposals -> do
      rows <- Tx.statement parameters (preparable ("SELECT proposal_id,state FROM shikigami.objective_tracker_proposals" <> suffix "proposal_id") encoder (D.rowList ((,) <$> textColumn <*> jsonColumn)))
      forM rows \row@(key, _) -> HistoryRecord key . toJSON <$> decodeProposal identifier row
    Publications -> do
      rows <- Tx.statement parameters (preparable ("SELECT publication_id,receipt_state,intent,receipt FROM shikigami.objective_tracker_publications" <> suffix "publication_id") encoder (D.rowList publicationRow))
      forM rows \row@(key, _, _, _) -> HistoryRecord key . toJSON <$> decodePublication row

lastObservationTime :: TrackerBindingId -> Transaction (Maybe UTCTime)
lastObservationTime identifier = Tx.statement (coordinateText identifier) (preparable "SELECT last_observed_at FROM shikigami.objective_tracker_bindings WHERE binding_id=$1" textParam (D.singleRow (D.column (D.nullable D.timestamptz))))

markObserved :: TrackerBindingId -> Transaction ()
markObserved identifier = Tx.statement (coordinateText identifier) (preparable "UPDATE shikigami.objective_tracker_bindings SET last_observed_at=clock_timestamp() WHERE binding_id=$1" textParam D.noResult)
