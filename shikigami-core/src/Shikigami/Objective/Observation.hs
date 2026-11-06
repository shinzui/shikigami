{-# LANGUAGE DataKinds #-}

-- | Lock-free bounded metadata reads. The SQL projects permitted fields before
-- decoding, so even a refused observation never reads an instruction or result.
module Shikigami.Objective.Observation
  ( ObjectiveObservation (..),
    AssignmentObservation (..),
    ObjectiveObservationScope (..),
    observeOpenObjectives,
    observeObjectivesFor,
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
import Shikigami.Agent.Principal (AgentIdentity)
import Shikigami.Execution.Identity (ExecutionRootId)
import Shikigami.Objective.Types
import Shikigami.WorkerSession.Types (WorkerSessionId)

data ObjectiveObservationScope = AllOpenObjectives | OpenObjectivesIn !(NonEmpty ObjectiveId)
  deriving stock (Eq, Show)

data AssignmentObservation = AssignmentObservation
  { assignmentId :: !ObjectiveAssignmentId,
    owner :: !AgentIdentity,
    state :: !AssignmentState,
    revision :: !(StateRevision "objective-assignment"),
    ownerEpoch :: !(StateRevision "worker-owner"),
    sessionId :: !(Maybe WorkerSessionId),
    rootId :: !(Maybe ExecutionRootId),
    cutoff :: !(Maybe UTCTime)
  }
  deriving stock (Eq, Show, Generic)

data ObjectiveObservation = ObjectiveObservation
  { objectiveId :: !ObjectiveId,
    status :: !Status,
    revision :: !(StateRevision "objective"),
    instructionsRevision :: !(StateRevision "objective-instructions"),
    criteriaRevision :: !(StateRevision "objective-criteria"),
    goal :: !Goal,
    coordinators :: ![Member],
    criteria :: ![Criterion],
    assignments :: ![AssignmentObservation],
    unresolvedOperations :: !Word,
    conversation :: !(Maybe ConversationRef),
    integratedCursors :: !Word,
    relationshipsComplete :: !Bool,
    updatedAt :: !UTCTime
  }
  deriving stock (Eq, Show, Generic)

instance ToJSON AssignmentObservation where
  toJSON value = object ["assignmentId" .= value.assignmentId, "owner" .= value.owner, "state" .= value.state, "revision" .= value.revision, "ownerEpoch" .= value.ownerEpoch, "sessionId" .= value.sessionId, "rootId" .= value.rootId, "cutoff" .= value.cutoff]

instance FromJSON AssignmentObservation where
  parseJSON = withObject "AssignmentObservation" \fields -> AssignmentObservation <$> fields .: "assignmentId" <*> fields .: "owner" <*> fields .: "state" <*> fields .: "revision" <*> fields .: "ownerEpoch" <*> fields .: "sessionId" <*> fields .: "rootId" <*> fields .: "cutoff"

instance ToJSON ObjectiveObservation where
  toJSON value = object ["objectiveId" .= value.objectiveId, "status" .= value.status, "revision" .= value.revision, "instructionsRevision" .= value.instructionsRevision, "criteriaRevision" .= value.criteriaRevision, "goal" .= value.goal, "coordinators" .= value.coordinators, "criteria" .= value.criteria, "assignments" .= value.assignments, "unresolvedOperations" .= value.unresolvedOperations, "conversation" .= value.conversation, "integratedCursors" .= value.integratedCursors, "relationshipsComplete" .= value.relationshipsComplete, "updatedAt" .= value.updatedAt]

instance FromJSON ObjectiveObservation where
  parseJSON = withObject "ObjectiveObservation" \fields -> ObjectiveObservation <$> fields .: "objectiveId" <*> fields .: "status" <*> fields .: "revision" <*> fields .: "instructionsRevision" <*> fields .: "criteriaRevision" <*> fields .: "goal" <*> fields .: "coordinators" <*> fields .: "criteria" <*> fields .: "assignments" <*> fields .: "unresolvedOperations" <*> fields .: "conversation" <*> fields .: "integratedCursors" <*> fields .: "relationshipsComplete" <*> fields .: "updatedAt"

-- | At most 256 subjects, 64 assignments, 32 criteria and 32 coordinators per
-- subject. A larger relationship or 256 KiB projection is explicitly incomplete
-- or refused. Each selected identity survives a corrupt metadata projection.
observeOpenObjectives :: ObjectiveObservationScope -> Maybe ObjectiveId -> Int -> Transaction [(Text, Either ObjectiveError ObjectiveObservation)]
observeOpenObjectives scope after limit = do
  rows <-
    Tx.statement
      (scopeValue scope, maybe "" objectiveIdText after, fromIntegral (max 1 (min 256 limit)) :: Int64)
      ( preparable
          (observationSql <> " WHERE ($1::jsonb IS NULL OR $1 @> jsonb_build_array(o.objective_id)) AND o.objective_id>$2 AND COALESCE(o.state->>'status','invalid') NOT IN ('Completed','Cancelled') ORDER BY o.objective_id LIMIT $3")
          (contrazip3 (E.param (E.nullable E.jsonb)) (E.param (E.nonNullable E.text)) (E.param (E.nonNullable E.int8)))
          observationRows
      )
  pure (map decode rows)
  where
    scopeValue AllOpenObjectives = Nothing
    scopeValue (OpenObjectivesIn identifiers) = Just (toJSON identifiers)

-- | Direct rechecks include terminal objectives. Active-population absence alone
-- is never terminal evidence. More than 256 ids is refused before any query.
observeObjectivesFor :: NonEmpty ObjectiveId -> Transaction (Either ObjectiveError [(Text, Either ObjectiveError ObjectiveObservation)])
observeObjectivesFor identifiers
  | NonEmpty.length identifiers > 256 = pure (Left ObjectiveUnavailable)
  | otherwise = do
      rows <-
        Tx.statement
          (toJSON identifiers)
          (preparable (observationSql <> " WHERE o.objective_id IN (SELECT jsonb_array_elements_text($1)) ORDER BY o.objective_id LIMIT 256") (E.param (E.nonNullable E.jsonb)) observationRows)
      pure (Right (map decode rows))

observationRows :: D.Result [(Text, Value)]
observationRows = D.rowList ((,) <$> D.column (D.nonNullable D.text) <*> D.column (D.nonNullable D.jsonb))

decode :: (Text, Value) -> (Text, Either ObjectiveError ObjectiveObservation)
decode (identifier, value) =
  ( identifier,
    case Aeson.fromJSON value of
      Aeson.Success observed | objectiveIdText observed.objectiveId == identifier -> Right observed
      _ -> Left ObjectiveUnavailable
  )

observationSql :: Text
observationSql =
  """
  SELECT o.objective_id,CASE WHEN octet_length(metadata.value::text)<=262144 THEN metadata.value ELSE 'null'::jsonb END
  FROM shikigami.objectives o
  CROSS JOIN LATERAL (SELECT jsonb_build_object(
   'objectiveId',o.state->'objectiveId','status',o.state->'status','revision',o.state->'revision',
   'instructionsRevision',o.state->'instructionsRevision','criteriaRevision',o.state->'criteriaRevision',
   'goal',o.state->'goal',
   'coordinators',COALESCE((SELECT jsonb_agg(member) FROM (SELECT member FROM jsonb_array_elements(
     CASE WHEN jsonb_typeof(o.state->'members')='array' THEN o.state->'members' ELSE '[]'::jsonb END) member
     WHERE member->'roles' @> '["Coordinator"]'::jsonb LIMIT 32) members),'[]'::jsonb),
   'criteria',COALESCE((SELECT jsonb_agg(criterion) FROM (SELECT criterion FROM jsonb_array_elements(
     CASE WHEN jsonb_typeof(o.state->'criteria')='array' THEN o.state->'criteria' ELSE '[]'::jsonb END) criterion LIMIT 32) criteria),'[]'::jsonb),
   'assignments',COALESCE((SELECT jsonb_agg(jsonb_build_object(
     'assignmentId',assignment#>'{definition,assignmentId}','owner',assignment#>'{definition,owner}',
     'state',assignment#>'{definition,state}','revision',assignment->'revision','ownerEpoch',assignment->'ownerEpoch',
     'sessionId',assignment#>'{definition,sessionId}','rootId',assignment#>'{definition,rootId}','cutoff',assignment#>'{definition,cutoff}'))
     FROM (SELECT assignment FROM jsonb_array_elements(CASE WHEN jsonb_typeof(o.state->'assignments')='array' THEN o.state->'assignments' ELSE '[]'::jsonb END) assignment LIMIT 64) assignments),'[]'::jsonb),
   'unresolvedOperations',CASE WHEN jsonb_typeof(o.state->'unresolved')='array' THEN jsonb_array_length(o.state->'unresolved') END,
   'conversation',(SELECT a.binding->'conversationId' FROM shikigami.objective_associations a
     WHERE a.objective_id=o.objective_id AND a.kind='conversation-current' ORDER BY a.source_id LIMIT 1),
   'integratedCursors',(SELECT count(*) FROM shikigami.objective_cursors c WHERE c.objective_id=o.objective_id),
   'relationshipsComplete',(CASE WHEN jsonb_typeof(o.state->'assignments')='array' AND jsonb_typeof(o.state->'criteria')='array' AND jsonb_typeof(o.state->'members')='array'
     THEN jsonb_array_length(o.state->'assignments')<=64 AND jsonb_array_length(o.state->'criteria')<=32 AND jsonb_array_length(o.state->'members')<=32 ELSE false END),
   'updatedAt',o.updated_at) AS value) metadata
  """
