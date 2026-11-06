{-# LANGUAGE DataKinds #-}

-- | Transcript-owner observation projects specifications, attempt deadlines
-- and objective-scope coordinates. It never selects a prompt, operation input,
-- outcome or result body.
module Shikigami.Execution.Observation
  ( ExecutionObservation (..),
    OperationObservation (..),
    AttemptObservation (..),
    ExecutionObservationScope (..),
    observeOpenExecutions,
    observeExecutionsFor,
    observeExecutionsForSessions,
    observeExecutionsUnderObjectives,
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
import Keiro.Workflow.Types (WorkflowId (..), mkWorkflowId)
import Shikigami.Execution.Attempt (AttemptPhase)
import Shikigami.Execution.Identity (ExecutionRootId, OperationId)
import Shikigami.Execution.Progress (PendingReceiptCount)
import Shikigami.Execution.Transcript (ExecutionError (CorruptReplay), ExecutionId, ExecutionPhase, OperationSpec (..), OperationUncertainty, PermissionBinding, executionIdText, executionIdentity, operationIdFor)
import Shikigami.Generated.Nominals (ObjectiveId)
import Shikigami.StateRevision (StateRevision, revisionNumber)
import Shikigami.WorkerSession.Input (WorkerSessionId)

data ExecutionObservationScope = AllExecutions | ExecutionsForObjectives !(NonEmpty ObjectiveId)
  deriving stock (Eq, Show)

data AttemptObservation = AttemptObservation {phase :: !AttemptPhase, expiresAt :: !(Maybe UTCTime)}
  deriving stock (Eq, Show, Generic)

data OperationObservation = OperationObservation
  { operationId :: !OperationId,
    position :: !(StateRevision "execution-operation"),
    specification :: !OperationSpec,
    uncertain :: !OperationUncertainty,
    permission :: !(Maybe PermissionBinding),
    attempts :: ![AttemptObservation],
    attemptsComplete :: !Bool
  }
  deriving stock (Eq, Show, Generic)

data ExecutionObservation = ExecutionObservation
  { executionId :: !ExecutionId,
    runId :: !WorkflowId,
    revision :: !(StateRevision "execution"),
    cursor :: !(StateRevision "execution-operation"),
    phase :: !ExecutionPhase,
    activeOperation :: !(Maybe OperationId),
    pendingReceipts :: !PendingReceiptCount,
    rootId :: !(Maybe ExecutionRootId),
    objective :: !(Maybe ObjectiveId),
    operations :: ![OperationObservation],
    operationsComplete :: !Bool,
    activityComplete :: !Bool,
    uncertainOperations :: !Word,
    activePermission :: !(Maybe PermissionBinding),
    updatedAt :: !UTCTime
  }
  deriving stock (Eq, Show, Generic)

instance ToJSON AttemptObservation where
  toJSON value = object ["phase" .= value.phase, "expiresAt" .= value.expiresAt]

instance FromJSON AttemptObservation where
  parseJSON = withObject "AttemptObservation" \fields -> AttemptObservation <$> fields .: "phase" <*> fields .: "expiresAt"

instance ToJSON OperationObservation where
  toJSON value = object ["operationId" .= value.operationId, "position" .= value.position, "specification" .= value.specification, "uncertain" .= value.uncertain, "permission" .= value.permission, "attempts" .= value.attempts, "attemptsComplete" .= value.attemptsComplete]

instance FromJSON OperationObservation where
  parseJSON = withObject "OperationObservation" \fields -> OperationObservation <$> fields .: "operationId" <*> fields .: "position" <*> fields .: "specification" <*> fields .: "uncertain" <*> fields .: "permission" <*> fields .: "attempts" <*> fields .: "attemptsComplete"

instance ToJSON ExecutionObservation where
  toJSON value = object ["executionId" .= value.executionId, "runId" .= value.runId.unWorkflowId, "revision" .= value.revision, "cursor" .= value.cursor, "phase" .= value.phase, "activeOperation" .= value.activeOperation, "pendingReceipts" .= value.pendingReceipts, "rootId" .= value.rootId, "objective" .= value.objective, "operations" .= value.operations, "operationsComplete" .= value.operationsComplete, "activityComplete" .= value.activityComplete, "uncertainOperations" .= value.uncertainOperations, "activePermission" .= value.activePermission, "updatedAt" .= value.updatedAt]

instance FromJSON ExecutionObservation where
  parseJSON = withObject "ExecutionObservation" \fields -> ExecutionObservation <$> fields .: "executionId" <*> (fields .: "runId" >>= either (fail . show) pure . mkWorkflowId) <*> fields .: "revision" <*> fields .: "cursor" <*> fields .: "phase" <*> fields .: "activeOperation" <*> fields .: "pendingReceipts" <*> fields .: "rootId" <*> fields .: "objective" <*> fields .: "operations" <*> fields .: "operationsComplete" <*> fields .: "activityComplete" <*> fields .: "uncertainOperations" <*> fields .: "activePermission" <*> fields .: "updatedAt"

-- | At most 256 executions, the last 32 accepted specifications per execution
-- and four live/uncertain attempt headers per operation. Historical operation
-- sampling is separate from complete activity counts (at most 10001 positions). Counts beyond these limits
-- are represented as incomplete, never inferred to be empty. Wire cap: 256 KiB.
observeOpenExecutions :: ExecutionObservationScope -> Maybe ExecutionId -> Int -> Transaction [(ExecutionId, Either ExecutionError ExecutionObservation)]
observeOpenExecutions scope after limit = do
  rows <-
    Tx.statement
      (scopeValue scope, maybe "" executionIdText after, fromIntegral (max 1 (min 256 limit)) :: Int64)
      ( preparable
          (observationSql <> " WHERE ($1::jsonb IS NULL OR $1 @> jsonb_build_array(COALESCE(snapshot.body#>>'{content,objectiveScope,target}',association.objective_id))) AND e.execution_id>$2 AND COALESCE(e.state->>'phase','invalid') NOT IN ('Succeeded','Failed','Cancelled') ORDER BY e.execution_id LIMIT $3")
          (contrazip3 (E.param (E.nullable E.jsonb)) (E.param (E.nonNullable E.text)) (E.param (E.nonNullable E.int8)))
          observationRows
      )
  pure (map decode rows)
  where
    scopeValue AllExecutions = Nothing
    scopeValue (ExecutionsForObjectives identifiers) = Just (toJSON identifiers)

observeExecutionsFor :: NonEmpty ExecutionId -> Transaction (Either ExecutionError [(ExecutionId, Either ExecutionError ExecutionObservation)])
observeExecutionsFor identifiers
  | NonEmpty.length identifiers > 256 = pure (Left CorruptReplay)
  | otherwise = do
      rows <-
        Tx.statement
          (toJSON identifiers)
          (preparable (observationSql <> " WHERE e.execution_id IN (SELECT jsonb_array_elements_text($1)) ORDER BY e.execution_id LIMIT 256") (E.param (E.nonNullable E.jsonb)) observationRows)
      pure (Right (map decode rows))

-- | The message owner already retains an execution coordinate. Join only that
-- coordinate and binding reference, never the message input or result.
observeExecutionsForSessions :: NonEmpty WorkerSessionId -> Transaction (Either ExecutionError [(ExecutionId, Either ExecutionError ExecutionObservation)])
observeExecutionsForSessions identifiers
  | NonEmpty.length identifiers > 256 = pure (Left CorruptReplay)
  | otherwise = do
      rows <-
        Tx.statement
          (toJSON identifiers)
          (preparable (observationSql <> " WHERE EXISTS (SELECT 1 FROM shikigami.worker_session_messages m WHERE (m.state->>'executionId'=e.execution_id OR m.state->>'childWorkflowId'=snapshot.body#>>'{content,runId}') AND $1 @> jsonb_build_array(m.session_id)) AND COALESCE(e.state->>'phase','invalid') NOT IN ('Succeeded','Failed','Cancelled') ORDER BY e.execution_id LIMIT 257") (E.param (E.nonNullable E.jsonb)) observationRows)
      pure (if length rows > 256 then Left CorruptReplay else Right (map decode rows))

-- | Complete active execution inventory for a bounded objective set, including
-- subjects outside the top-level population page. Truncation refuses the relation.
observeExecutionsUnderObjectives :: NonEmpty ObjectiveId -> Transaction (Either ExecutionError [(ExecutionId, Either ExecutionError ExecutionObservation)])
observeExecutionsUnderObjectives identifiers
  | NonEmpty.length identifiers > 256 = pure (Left CorruptReplay)
  | otherwise = do
      rows <-
        Tx.statement
          (toJSON identifiers)
          (preparable (observationSql <> " WHERE $1 @> jsonb_build_array(COALESCE(snapshot.body#>>'{content,objectiveScope,target}',association.objective_id)) AND COALESCE(e.state->>'phase','invalid') NOT IN ('Succeeded','Failed','Cancelled') ORDER BY e.execution_id LIMIT 257") (E.param (E.nonNullable E.jsonb)) observationRows)
      pure (if length rows > 256 then Left CorruptReplay else Right (map decode rows))

observationRows :: D.Result [(Text, Value)]
observationRows = D.rowList ((,) <$> D.column (D.nonNullable D.text) <*> D.column (D.nonNullable D.jsonb))

decode :: (Text, Value) -> (ExecutionId, Either ExecutionError ExecutionObservation)
decode (identifier, value) =
  ( executionIdentity identifier,
    case Aeson.fromJSON value of
      Aeson.Success observed | executionIdText observed.executionId == identifier, revisionNumber observed.cursor <= 10000, all (\operation -> operation.specification.operationId == operation.operationId && operation.operationId == operationIdFor observed.executionId operation.position) observed.operations -> Right observed
      _ -> Left CorruptReplay
  )

observationSql :: Text
observationSql =
  """
   SELECT e.execution_id,CASE WHEN e.state->'format'='1'::jsonb AND octet_length(metadata.value::text)<=262144 THEN metadata.value ELSE 'null'::jsonb END
   FROM shikigami.executions e
   LEFT JOIN shikigami.execution_payloads snapshot ON snapshot.execution_id=e.execution_id AND snapshot.payload_id=e.state#>>'{snapshot,payloadId}' AND snapshot.body->>'kind'='snapshot' AND snapshot.digest=e.binding->>'snapshotDigest'
   LEFT JOIN shikigami.execution_transcript_operations active ON active.operation_id=e.state->>'activeOperation' AND active.execution_id=e.execution_id
   LEFT JOIN LATERAL (SELECT a.objective_id FROM shikigami.worker_session_messages m
     JOIN shikigami.worker_sessions s ON s.session_id=m.session_id
     JOIN shikigami.objective_assignments a ON a.reference_key=s.binding#>>'{objective,key}'
     WHERE (m.state->>'executionId'=e.execution_id OR m.state->>'childWorkflowId'=snapshot.body#>>'{content,runId}') AND s.binding#>>'{objective,provider}'='shikigami-objective-v1'
     ORDER BY a.objective_id LIMIT 1) association ON true
   CROSS JOIN LATERAL (SELECT jsonb_build_object(
    'executionId',e.state->'executionId','runId',snapshot.body#>'{content,runId}','revision',e.state->'revision','cursor',e.state->'cursor',
    'phase',e.state->'phase','activeOperation',e.state->'activeOperation','pendingReceipts',CASE WHEN e.state ? 'pendingReceipts' THEN e.state->'pendingReceipts' ELSE '0'::jsonb END,
    'rootId',e.binding->'rootId','objective',COALESCE(snapshot.body#>>'{content,objectiveScope,target}',association.objective_id),
    'activePermission',active.state->'permission',
    'operations',COALESCE((SELECT jsonb_agg(op.metadata ORDER BY op.position) FROM (
      SELECT o.position,CASE WHEN o.state->'format'='1'::jsonb THEN jsonb_build_object('operationId',o.operation_id,'position',o.position,
        'specification',o.state->'specification','uncertain',o.state->'uncertain','permission',o.state->'permission',
        'attempts',COALESCE((SELECT jsonb_agg(jsonb_build_object('phase',attempt->'phase','expiresAt',attempt->'expiresAt'))
          FROM (SELECT value AS attempt FROM jsonb_each(CASE WHEN jsonb_typeof(o.dispatches)='object' THEN o.dispatches ELSE '{}'::jsonb END) WHERE COALESCE(value->>'phase','invalid') NOT IN ('AttemptCommitted','AttemptAbandoned','AttemptSuperseded') OR (value->>'phase'='AttemptSuperseded' AND value->'lateReceipt'='null'::jsonb) ORDER BY key LIMIT 4) attempts),'[]'::jsonb),
        'attemptsComplete',CASE WHEN jsonb_typeof(o.dispatches)='object' THEN (SELECT count(*) FROM (SELECT 1 FROM jsonb_each(o.dispatches) WHERE COALESCE(value->>'phase','invalid') NOT IN ('AttemptCommitted','AttemptAbandoned','AttemptSuperseded') OR (value->>'phase'='AttemptSuperseded' AND value->'lateReceipt'='null'::jsonb) LIMIT 5) attempts)<=4 ELSE false END) ELSE 'null'::jsonb END AS metadata
      FROM shikigami.execution_transcript_operations o WHERE o.execution_id=e.execution_id ORDER BY CASE WHEN o.state->'outcome' IS NULL OR o.state->'outcome'='null'::jsonb OR COALESCE(o.state->'uncertain','true'::jsonb)<>'false'::jsonb OR jsonb_typeof(o.dispatches) IS DISTINCT FROM 'object' OR EXISTS (SELECT 1 FROM jsonb_each(CASE WHEN jsonb_typeof(o.dispatches)='object' THEN o.dispatches ELSE '{}'::jsonb END) a WHERE COALESCE(a.value->>'phase','invalid') NOT IN ('AttemptCommitted','AttemptAbandoned','AttemptSuperseded') OR (a.value->>'phase'='AttemptSuperseded' AND a.value->'lateReceipt'='null'::jsonb)) THEN 0 ELSE 1 END,o.position DESC LIMIT 32) op),'[]'::jsonb),
    'operationsComplete',(e.state->'activeOperation'='null'::jsonb OR active.operation_id IS NOT NULL) AND (SELECT count(*) FROM (SELECT 1 FROM shikigami.execution_transcript_operations o WHERE o.execution_id=e.execution_id LIMIT 33) operations)<=32,
    'activityComplete',(COALESCE(e.state->'activeOperation','null'::jsonb)='null'::jsonb OR active.operation_id IS NOT NULL) AND (SELECT count(*) FROM shikigami.execution_transcript_operations o WHERE o.execution_id=e.execution_id AND (o.state->'outcome' IS NULL OR o.state->'outcome'='null'::jsonb OR COALESCE(o.state->'uncertain','true'::jsonb)<>'false'::jsonb OR jsonb_typeof(o.dispatches) IS DISTINCT FROM 'object' OR EXISTS (SELECT 1 FROM jsonb_each(CASE WHEN jsonb_typeof(o.dispatches)='object' THEN o.dispatches ELSE '{}'::jsonb END) a WHERE COALESCE(a.value->>'phase','invalid') NOT IN ('AttemptCommitted','AttemptAbandoned','AttemptSuperseded') OR (a.value->>'phase'='AttemptSuperseded' AND a.value->'lateReceipt'='null'::jsonb))))<=32,
  'uncertainOperations',(SELECT count(*) FROM shikigami.execution_transcript_operations o WHERE o.execution_id=e.execution_id AND o.state->'uncertain'='true'::jsonb),
  'updatedAt',e.updated_at) AS value) metadata
  """
