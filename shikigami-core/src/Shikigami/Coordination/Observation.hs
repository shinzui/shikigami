{-# LANGUAGE DataKinds #-}

-- | Accepted coordinator coordinates and checkpoint listeners. This projection
-- never loads a proposal, instruction, outcome or objective receipt payload.
module Shikigami.Coordination.Observation
  ( CoordinatorObservation (..),
    ListenerObservation (..),
    RunObservation (..),
    observeCoordinators,
    observationSql,
  )
where

import Data.Aeson (FromJSON (..), ToJSON (..), Value, object, withObject, (.:), (.=))
import Data.Aeson qualified as Aeson
import Data.List.NonEmpty (NonEmpty)
import Data.List.NonEmpty qualified as NonEmpty
import Data.Text (Text)
import GHC.Generics (Generic)
import Hasql.Decoders qualified as D
import Hasql.Encoders qualified as E
import Hasql.Statement (preparable)
import Hasql.Transaction (Transaction)
import Hasql.Transaction qualified as Tx
import Shikigami.Agent.Principal (AgentIdentity)
import Shikigami.Execution.Identity (ExecutionRootId, OperationId)
import Shikigami.Objective.Types (ObjectiveError (ObjectiveUnavailable), ObjectiveId, objectiveIdText)
import Shikigami.StateRevision (StateRevision)

data ListenerObservation = ListenerObservation
  { ownerName :: !Text,
    ownerId :: !Text,
    generation :: !Int,
    after :: !(StateRevision "objective")
  }
  deriving stock (Eq, Show, Generic)

data RunObservation = RunObservation {runId :: !Text, identity :: !AgentIdentity, rootId :: !(Maybe ExecutionRootId)}
  deriving stock (Eq, Show, Generic)

data CoordinatorObservation = CoordinatorObservation
  { objectiveId :: !ObjectiveId,
    latestDecision :: !(Maybe OperationId),
    latestRevision :: !(Maybe (StateRevision "objective")),
    listeners :: ![ListenerObservation],
    runs :: ![RunObservation],
    terminal :: !Bool,
    relationshipsComplete :: !Bool
  }
  deriving stock (Eq, Show, Generic)

instance ToJSON ListenerObservation where
  toJSON value = object ["ownerName" .= value.ownerName, "ownerId" .= value.ownerId, "generation" .= value.generation, "after" .= value.after]

instance FromJSON ListenerObservation where
  parseJSON = withObject "ListenerObservation" \fields -> ListenerObservation <$> fields .: "ownerName" <*> fields .: "ownerId" <*> fields .: "generation" <*> fields .: "after"

instance ToJSON RunObservation where
  toJSON value = object ["runId" .= value.runId, "identity" .= value.identity, "rootId" .= value.rootId]

instance FromJSON RunObservation where
  parseJSON = withObject "RunObservation" \fields -> RunObservation <$> fields .: "runId" <*> fields .: "identity" <*> fields .: "rootId"

instance ToJSON CoordinatorObservation where
  toJSON value = object ["objectiveId" .= value.objectiveId, "latestDecision" .= value.latestDecision, "latestRevision" .= value.latestRevision, "listeners" .= value.listeners, "runs" .= value.runs, "terminal" .= value.terminal, "relationshipsComplete" .= value.relationshipsComplete]

instance FromJSON CoordinatorObservation where
  parseJSON = withObject "CoordinatorObservation" \fields -> CoordinatorObservation <$> fields .: "objectiveId" <*> fields .: "latestDecision" <*> fields .: "latestRevision" <*> fields .: "listeners" <*> fields .: "runs" <*> fields .: "terminal" <*> fields .: "relationshipsComplete"

-- | At most 256 objectives and eight listeners/runs per objective. A larger
-- relation is incomplete, not absent. Receipt coordinates prove the latest
-- decision was committed; protected decision bodies stay with readDecision.
observeCoordinators :: NonEmpty ObjectiveId -> Transaction (Either ObjectiveError [(Text, Either ObjectiveError CoordinatorObservation)])
observeCoordinators identifiers
  | NonEmpty.length identifiers > 256 = pure (Left ObjectiveUnavailable)
  | otherwise = do
      rows <-
        Tx.statement
          (toJSON identifiers)
          ( preparable
              observationSql
              (E.param (E.nonNullable E.jsonb))
              (D.rowList ((,) <$> D.column (D.nonNullable D.text) <*> D.column (D.nonNullable D.jsonb)))
          )
      pure (Right (map decode rows))
  where
    decode (identifier, value) =
      ( identifier,
        case Aeson.fromJSON value of
          Aeson.Success observed
            | objectiveIdText observed.objectiveId == identifier,
              all (\listener -> listener.generation >= 0 && listener.generation <= 1000000) observed.listeners ->
                Right observed
          _ -> Left ObjectiveUnavailable
      )

observationSql :: Text
observationSql =
  """
  SELECT o.objective_id,jsonb_build_object(
   'objectiveId',o.objective_id,'latestDecision',d.operation_id,'latestRevision',d.revision,
   'listeners',COALESCE((SELECT jsonb_agg(jsonb_build_object('ownerName',l.owner_name,'ownerId',l.owner_id,
     'generation',l.generation,'after',l.listener->'after')) FROM
     (SELECT owner_name,owner_id,generation,listener FROM shikigami.adaptive_checkpoint_listeners
      WHERE objective_id=o.objective_id ORDER BY owner_name,owner_id LIMIT 8) l),'[]'::jsonb),
   'runs',COALESCE((SELECT jsonb_agg(jsonb_build_object('runId',s.scope#>'{run,runId}','identity',s.scope#>'{run,identity}','rootId',s.scope#>'{run,rootId}')) FROM
     (SELECT scope FROM shikigami.objective_scopes WHERE objective_id=o.objective_id ORDER BY fingerprint LIMIT 8) s),'[]'::jsonb),
   'terminal',EXISTS (SELECT 1 FROM shikigami.adaptive_observations a WHERE a.objective_id=o.objective_id AND a.kind='terminal'),
   'relationshipsComplete',
     (SELECT count(*) FROM (SELECT 1 FROM shikigami.adaptive_checkpoint_listeners WHERE objective_id=o.objective_id LIMIT 9) listeners)<=8
     AND (SELECT count(*) FROM (SELECT 1 FROM shikigami.objective_scopes WHERE objective_id=o.objective_id LIMIT 9) scopes)<=8
     AND NOT EXISTS (SELECT 1 FROM shikigami.adaptive_decisions bad LEFT JOIN shikigami.objective_receipts r
       ON r.objective_id=bad.objective_id AND r.operation_key=bad.operation_id
       WHERE bad.objective_id=o.objective_id AND (r.outcome->'Right'->>'operationId' IS DISTINCT FROM bad.operation_id
         OR r.outcome->'Right'->>'objectiveId' IS DISTINCT FROM bad.objective_id
         OR r.outcome->'Right'->'revision' IS DISTINCT FROM to_jsonb(bad.revision))))
  FROM shikigami.objectives o
  LEFT JOIN LATERAL (SELECT d.operation_id,d.revision FROM shikigami.adaptive_decisions d
   JOIN shikigami.objective_receipts r ON r.objective_id=d.objective_id AND r.operation_key=d.operation_id
   WHERE d.objective_id=o.objective_id AND r.outcome->'Right'->>'operationId'=d.operation_id
     AND r.outcome->'Right'->>'objectiveId'=d.objective_id AND r.outcome->'Right'->'revision'=to_jsonb(d.revision)
   ORDER BY d.revision DESC LIMIT 1) d ON true
  WHERE $1 @> jsonb_build_array(o.objective_id) ORDER BY o.objective_id LIMIT 256
  """
