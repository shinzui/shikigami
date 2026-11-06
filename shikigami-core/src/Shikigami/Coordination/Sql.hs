{-# LANGUAGE DataKinds #-}

-- | Private projection of accepted manifests, committed with the objective.
-- Every protected read binds the projection to its original objective receipt
-- and payload commitment before it can supply executable operations.
module Shikigami.Coordination.Sql (saveDecision, readDecision, readArrangement, readDecisions, saveObservation, readObservations, module Shikigami.Coordination.Observation) where

import Contravariant.Extras (contrazip2, contrazip3, contrazip4, contrazip6)
import Data.Aeson qualified as Aeson
import Data.Aeson.KeyMap qualified as KeyMap
import Data.Functor.Contravariant ((>$<))
import Data.Text qualified as Text
import Data.Vector qualified as Vector
import Hasql.Decoders qualified as D
import Hasql.Encoders qualified as E
import Hasql.Statement (preparable)
import Hasql.Transaction (Transaction)
import Hasql.Transaction qualified as Tx
import Shikigami.Coordination.Observation
import Shikigami.Coordination.Proposal
import Shikigami.Execution.Identity (OperationId, operationIdText)
import Shikigami.FormatVersion (FormatVersion (V1))
import Shikigami.Objective.Types
import Shikigami.Prelude
import Text.Read (readMaybe)

data RawDecision = RawDecision !Text !Text !Text !Aeson.Value !(Maybe Text) !(Maybe Aeson.Value) !(Maybe Aeson.Value)

saveDecision :: AcceptedDecision -> Receipt -> Transaction ()
saveDecision decision receipt =
  Tx.statement
    (objectiveIdText receipt.objectiveId, operationIdText receipt.operationId, revisionNumber receipt.revision, toJSON decision)
    (preparable "INSERT INTO shikigami.adaptive_decisions (objective_id,operation_id,revision,manifest) VALUES ($1,$2,$3,$4)" (contrazip4 text text (fromInteger >$< E.param (E.nonNullable E.numeric)) json) D.noResult)
  where
    json = E.param (E.nonNullable E.jsonb)

readDecision :: ObjectiveId -> OperationId -> Transaction (Either ObjectiveError (Maybe AcceptedDecision))
readDecision objective operation = do
  row <- Tx.statement (objectiveIdText objective, operationIdText operation) (preparable (selectDecision <> " WHERE d.objective_id=$1 AND d.operation_id=$2") (contrazip2 text text) (D.rowMaybe rawDecision))
  pure do
    decoded <- traverse decode row
    forM_ decoded \decision -> unless (decision.proposal.objectiveId == objective && decision.proposal.operationId == operation) unavailable
    pure decoded

readArrangement :: ObjectiveId -> Transaction (Either ObjectiveError (Maybe [Placement]))
readArrangement objective = do
  row <- Tx.statement (objectiveIdText objective) (preparable (selectDecision <> " WHERE d.objective_id=$1 ORDER BY d.revision DESC LIMIT 1") text (D.rowMaybe rawDecision))
  pure do
    decoded <- traverse decode row
    forM_ decoded \decision -> unless (decision.proposal.objectiveId == objective) unavailable
    pure ((.arrangement) <$> decoded)

readDecisions :: ObjectiveId -> Int -> Int -> Transaction (Either ObjectiveError [AcceptedDecision])
readDecisions objective after limit = do
  rows <- Tx.statement (objectiveIdText objective, fromIntegral after, fromIntegral limit) (preparable (selectDecision <> " WHERE d.objective_id=$1 ORDER BY d.revision DESC OFFSET $2 LIMIT $3") (contrazip3 text (E.param (E.nonNullable E.int4)) (E.param (E.nonNullable E.int4))) (D.rowList rawDecision))
  pure (traverse decode rows)

-- No model text, instructions, payload or credentials enter this projection.
saveObservation :: ObjectiveId -> OperationId -> Text -> StateRevision "objective" -> Text -> Maybe Text -> Transaction ()
saveObservation objective operation kind revision status refusal =
  Tx.statement
    (objectiveIdText objective, operationIdText operation, kind, revisionNumber revision, status, refusal)
    (preparable "INSERT INTO shikigami.adaptive_observations(objective_id,operation_id,kind,revision,status,refusal) SELECT $1,$2,$3,$4,$5,$6 WHERE (SELECT count(*) FROM shikigami.adaptive_observations WHERE objective_id=$1)<4096 ON CONFLICT DO NOTHING" (contrazip6 text text text (fromInteger >$< E.param (E.nonNullable E.numeric)) text (E.param (E.nullable E.text))) D.noResult)

readObservations :: ObjectiveId -> Int -> Int -> Transaction (Either ObjectiveError [(Text, Text, Integer, Text, Maybe Text)])
readObservations objective after limit = do
  rows <-
    Tx.statement
      (objectiveIdText objective, fromIntegral after, fromIntegral limit)
      (preparable "SELECT operation_id,kind,revision::text,status,refusal FROM shikigami.adaptive_observations WHERE objective_id=$1 ORDER BY revision DESC,operation_id,kind OFFSET $2 LIMIT $3" (contrazip3 text (E.param (E.nonNullable E.int4)) (E.param (E.nonNullable E.int4))) (D.rowList ((,,,,) <$> required D.text <*> required D.text <*> required D.text <*> required D.text <*> D.column (D.nullable D.text))))
  let checked = forM rows \(operation, kind, revision, status, refusal) -> case readMaybe (Text.unpack revision) of
        Just number | number >= 0 && kind `elem` ["refusal", "terminal"] && Text.length operation <= 256 && Text.length status <= 128 && maybe True ((<= 128) . Text.length) refusal -> Right (operation, kind, number, status, refusal)
        _ -> Left ObjectiveUnavailable
  when (case checked of Left _ -> True; _ -> False) Tx.condemn
  pure checked
  where
    required = D.column . D.nonNullable

selectDecision :: Text
selectDecision = "SELECT d.objective_id,d.operation_id,d.revision::text,d.manifest,r.fingerprint,r.outcome,p.payload FROM shikigami.adaptive_decisions d LEFT JOIN shikigami.objective_receipts r ON r.objective_id=d.objective_id AND r.operation_key=d.operation_id LEFT JOIN shikigami.objective_payloads p ON p.objective_id=d.objective_id AND p.digest=r.outcome->'Right'->>'payloadDigest'"

rawDecision :: D.Row RawDecision
rawDecision = RawDecision <$> required D.text <*> required D.text <*> required D.text <*> required D.jsonb <*> optional D.text <*> optional D.jsonb <*> optional D.jsonb
  where
    required = D.column . D.nonNullable
    optional = D.column . D.nullable

text :: E.Params Text
text = E.param (E.nonNullable E.text)

unavailable :: Either ObjectiveError a
unavailable = Left ObjectiveUnavailable

-- A committed manifest is decoded, never revalidated under current policy.
-- The receipt proves the historical validator's original accepted payload.
decode :: RawDecision -> Either ObjectiveError AcceptedDecision
decode (RawDecision objective operation rawRevision manifest rawFingerprint rawOutcome rawPayload) = do
  decision <- fromValue manifest
  unless (decision.format == V1 && decision.validatorVersion `elem` ["shikigami.adaptive-validator/1", "shikigami.adaptive-validator/2", "shikigami.adaptive-validator/3"]) unavailable
  revision <- maybe unavailable Right (readMaybe (Text.unpack rawRevision) :: Maybe Integer)
  fingerprint <- maybe unavailable Right rawFingerprint
  outcome <- maybe unavailable fromValue rawOutcome
  receipt <- case outcome :: Either ObjectiveError Receipt of Right receipt -> Right receipt; Left _ -> unavailable
  payload <- maybe unavailable Right rawPayload
  (actor, mutation, next) <- case payload of
    Aeson.Array values -> case Vector.toList values of
      [actor, mutation, next] -> (,,) <$> fromValue actor <*> pure mutation <*> (fromValue next :: Either ObjectiveError Objective)
      _ -> unavailable
    _ -> unavailable
  source <- case mutation of
    Aeson.Object fields | KeyMap.lookup "tag" fields == Just (Aeson.String "Internal") -> case KeyMap.lookup "contents" fields of
      Just (Aeson.Object command) | KeyMap.lookup "tag" command == Just (Aeson.String "ApplyAdaptiveDecision") -> maybe unavailable Right (KeyMap.lookup "contents" command)
      _ -> unavailable
    _ -> unavailable
  unless (source == manifest && revision == revisionNumber receipt.revision && revision == revisionNumber (advanceRevision decision.proposal.checkpointRevision)) unavailable
  unless (objectiveIdText receipt.objectiveId == objective && operationIdText receipt.operationId == operation && receipt.objectiveId == decision.proposal.objectiveId && receipt.operationId == decision.proposal.operationId && next.objectiveId == receipt.objectiveId && next.revision == receipt.revision && actor == RecordedAgent decision.policy.identity) unavailable
  unless (mutationFingerprintText receipt.fingerprint == fingerprint && receipt.payloadDigest == objectivePayloadDigest payload) unavailable
  let expected = commandFingerprint (toJSON (actor :: AccessPrincipal, receipt.objectiveId, decision.proposal.checkpointRevision, receipt.operationId, "adaptive-decision" :: Text, mutation))
  unless (receipt.fingerprint == expected) unavailable
  pure decision

fromValue :: (FromJSON a) => Aeson.Value -> Either ObjectiveError a
fromValue value = case Aeson.fromJSON value of Aeson.Success result -> Right result; Aeson.Error _ -> unavailable
