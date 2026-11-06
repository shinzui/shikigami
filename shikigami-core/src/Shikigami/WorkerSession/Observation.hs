{-# LANGUAGE DataKinds #-}

-- | Lock-free metadata projection owned by continuing sessions. No instruction,
-- context, result or payload reference is selected or decoded.
module Shikigami.WorkerSession.Observation
  ( SessionObservation (..),
    SessionObservationScope (..),
    observeOpenSessions,
    observeSessionsFor,
    observeSessionsUnderObjectives,
    observationSql,
  )
where

import Contravariant.Extras (contrazip3)
import Data.Aeson (FromJSON (..), ToJSON (..), Value, object, withObject, (.:), (.=))
import Data.Aeson qualified as Aeson
import Data.Int (Int64)
import Data.List.NonEmpty (NonEmpty)
import Data.List.NonEmpty qualified as NonEmpty
import Data.Text (Text)
import Data.Time (UTCTime)
import GHC.Generics (Generic)
import Hasql.Decoders qualified as D
import Hasql.Encoders qualified as E
import Hasql.Statement (preparable)
import Hasql.Transaction (Transaction)
import Hasql.Transaction qualified as Tx
import Keiro.Workflow.Types (WorkflowId (..))
import Shikigami.Agent.Principal (AgentIdentity)
import Shikigami.Execution.Coordinate (ExecutionId)
import Shikigami.Execution.Identity (ExecutionRootId)
import Shikigami.Generated.Nominals (ObjectiveId)
import Shikigami.StateRevision (StateRevision)
import Shikigami.WorkerSession.Types

data SessionObservationScope = AllSessions | SessionsWithReferences !(NonEmpty ObjectiveRef) | SessionsForObjectives !(NonEmpty ObjectiveId)
  deriving stock (Eq, Show)

data SessionObservation = SessionObservation
  { sessionId :: !WorkerSessionId,
    revision :: !(StateRevision "worker-session"),
    eventCursor :: !(StateRevision "worker-event"),
    consumedCursor :: !(StateRevision "worker-event"),
    nextSequence :: !(StateRevision "worker-message"),
    epoch :: !(StateRevision "worker-owner"),
    phase :: !SessionPhase,
    objective :: !ObjectiveRef,
    boundObjective :: !(Maybe ObjectiveId),
    rootId :: !ExecutionRootId,
    parentIdentity :: !AgentIdentity,
    activeAssignment :: !(Maybe AssignmentId),
    assignmentPhase :: !(Maybe AssignmentPhase),
    childWorkflowId :: !(Maybe WorkflowId),
    executionId :: !(Maybe ExecutionId),
    queuedAssignments :: !Word,
    assignmentObserved :: !Bool,
    updatedAt :: !UTCTime
  }
  deriving stock (Eq, Show, Generic)

instance FromJSON SessionObservation where
  parseJSON = withObject "SessionObservation" \fields ->
    SessionObservation
      <$> fields .: "sessionId"
      <*> fields .: "revision"
      <*> fields .: "eventCursor"
      <*> fields .: "consumedCursor"
      <*> fields .: "nextSequence"
      <*> fields .: "epoch"
      <*> fields .: "phase"
      <*> fields .: "objective"
      <*> fields .: "boundObjective"
      <*> fields .: "rootId"
      <*> fields .: "parentIdentity"
      <*> fields .: "activeAssignment"
      <*> fields .: "assignmentPhase"
      <*> (fmap WorkflowId <$> fields .: "childWorkflowId")
      <*> fields .: "executionId"
      <*> fields .: "queuedAssignments"
      <*> fields .: "assignmentObserved"
      <*> fields .: "updatedAt"

instance ToJSON SessionObservation where
  toJSON value =
    object
      [ "sessionId" .= value.sessionId,
        "revision" .= value.revision,
        "eventCursor" .= value.eventCursor,
        "consumedCursor" .= value.consumedCursor,
        "nextSequence" .= value.nextSequence,
        "epoch" .= value.epoch,
        "phase" .= value.phase,
        "objective" .= value.objective,
        "boundObjective" .= value.boundObjective,
        "rootId" .= value.rootId,
        "parentIdentity" .= value.parentIdentity,
        "activeAssignment" .= value.activeAssignment,
        "assignmentPhase" .= value.assignmentPhase,
        "childWorkflowId" .= fmap (.unWorkflowId) value.childWorkflowId,
        "executionId" .= value.executionId,
        "queuedAssignments" .= value.queuedAssignments,
        "assignmentObserved" .= value.assignmentObserved,
        "updatedAt" .= value.updatedAt
      ]

-- | Return each row's identity even on corruption so the caller can report a
-- refusal and advance past that row. SQL filters scope before the keyset LIMIT.
-- The public bound is 256 rows. The caller owns transaction timeout and isolation.
observeOpenSessions :: SessionObservationScope -> Maybe WorkerSessionId -> Int -> Transaction [(WorkerSessionId, Either SessionError SessionObservation)]
observeOpenSessions scope after limit = do
  rows <-
    Tx.statement
      (scopeValue scope, maybe "" workerSessionIdText after, fromIntegral (max 1 (min 256 limit)) :: Int64)
      ( preparable
          (observationSql <> " WHERE ($1::jsonb IS NULL OR ($1->'references') @> jsonb_build_array(s.binding->'objective') OR (s.binding#>>'{objective,provider}'='shikigami-objective-v1' AND EXISTS (SELECT 1 FROM shikigami.objective_assignments a WHERE a.reference_key=s.binding#>>'{objective,key}' AND ($1->'objectives') @> jsonb_build_array(a.objective_id)))) AND s.session_id>$2 AND COALESCE(s.state->>'phase','invalid') NOT IN ('Idle','Failed','Cancelled') ORDER BY s.session_id LIMIT $3")
          (contrazip3 (E.param (E.nullable E.jsonb)) (E.param (E.nonNullable E.text)) (E.param (E.nonNullable E.int8)))
          observationRows
      )
  pure (map decode rows)
  where
    scopeValue AllSessions = Nothing
    scopeValue (SessionsWithReferences references) = Just (object ["references" .= references])
    scopeValue (SessionsForObjectives identifiers) = Just (object ["objectives" .= identifiers])

-- | Exact, set-based relationship lookup. No phase filter: Idle is evidence too.
observeSessionsFor :: NonEmpty WorkerSessionId -> Transaction (Either SessionError [(WorkerSessionId, Either SessionError SessionObservation)])
observeSessionsFor identifiers
  | NonEmpty.length identifiers > 256 = pure (Left SessionStorageUnavailable)
  | otherwise = do
      rows <-
        Tx.statement
          (toJSON identifiers)
          (preparable (observationSql <> " WHERE s.session_id IN (SELECT jsonb_array_elements_text($1)) ORDER BY s.session_id LIMIT 256") (E.param (E.nonNullable E.jsonb)) observationRows)
      pure (Right (map decode rows))

-- | Complete bounded relationship inventory, including Idle sessions whose
-- first checkpoint has not yet published a session id into the objective graph.
observeSessionsUnderObjectives :: NonEmpty ObjectiveId -> Transaction (Either SessionError [(WorkerSessionId, Either SessionError SessionObservation)])
observeSessionsUnderObjectives identifiers
  | NonEmpty.length identifiers > 256 = pure (Left SessionStorageUnavailable)
  | otherwise = do
      rows <-
        Tx.statement
          (toJSON identifiers)
          (preparable (observationSql <> " WHERE s.binding#>>'{objective,provider}'='shikigami-objective-v1' AND EXISTS (SELECT 1 FROM shikigami.objective_assignments a WHERE a.reference_key=s.binding#>>'{objective,key}' AND $1 @> jsonb_build_array(a.objective_id)) ORDER BY s.session_id LIMIT 257") (E.param (E.nonNullable E.jsonb)) observationRows)
      pure (if length rows > 256 then Left SessionStorageUnavailable else Right (map decode rows))

observationRows :: D.Result [(Text, Value)]
observationRows = D.rowList ((,) <$> D.column (D.nonNullable D.text) <*> D.column (D.nonNullable D.jsonb))

decode :: (Text, Value) -> (WorkerSessionId, Either SessionError SessionObservation)
decode (identifier, value) =
  ( workerSessionId identifier,
    case Aeson.fromJSON value of
      Aeson.Success observation | workerSessionIdText observation.sessionId == identifier -> Right observation
      _ -> Left SessionStorageUnavailable
  )

-- The queue projection has at most one row; its count means presence, not the
-- complete mailbox size. A missing active message remains explicitly unknown.
observationSql :: Text
observationSql =
  """
  SELECT s.session_id,CASE WHEN s.state->'format'='1'::jsonb AND octet_length(metadata.value::text)<=262144 THEN metadata.value ELSE 'null'::jsonb END
  FROM shikigami.worker_sessions s
  LEFT JOIN shikigami.worker_session_messages m
   ON m.session_id=s.session_id AND m.assignment_id=s.state->>'activeAssignment'
  CROSS JOIN LATERAL (SELECT jsonb_build_object(
   'sessionId',s.state->'sessionId','revision',s.state->'revision',
   'eventCursor',s.state->'eventCursor','consumedCursor',s.state->'consumedCursor',
   'nextSequence',s.state->'nextSequence','epoch',s.state->'epoch','phase',s.state->'phase',
   'objective',s.binding->'objective','boundObjective',(SELECT a.objective_id FROM shikigami.objective_assignments a WHERE a.reference_key=s.binding#>>'{objective,key}' AND s.binding#>>'{objective,provider}'='shikigami-objective-v1' LIMIT 1),'rootId',s.binding->'rootId',
   'parentIdentity',s.binding->'parentIdentity','activeAssignment',s.state->'activeAssignment',
   'assignmentPhase',m.state->'phase','childWorkflowId',m.state->'childWorkflowId',
   'executionId',m.state->'executionId',
   'queuedAssignments',(SELECT count(*) FROM (SELECT 1 FROM shikigami.worker_session_messages q
     WHERE q.session_id=s.session_id AND q.state->>'phase'='Queued' LIMIT 1) queued),
   'assignmentObserved',(s.state->'activeAssignment'='null'::jsonb OR m.assignment_id IS NOT NULL),
   'updatedAt',s.updated_at) AS value) metadata
  """
