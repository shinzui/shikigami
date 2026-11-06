{-# LANGUAGE DataKinds #-}

-- | Unsettled command headers. Arguments, environment, output and receipt
-- bodies are deliberately absent from the SQL projection and public records.
module Shikigami.Workspace.ProcessObservation (ProcessObservation (..), observeUnsettledProcesses, observationSql) where

import Data.Aeson (FromJSON (..), ToJSON (..), object, withObject, (.:), (.=))
import Data.Aeson qualified as Aeson
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
import Shikigami.Execution.Identity (OperationId, operationIdText, parseOperationId)
import Shikigami.Workspace.Process (ProcessPhase)
import Shikigami.Workspace.Types (WorkspaceError (WorkspaceBindingConflict))

data ProcessObservation = ProcessObservation
  { operationId :: !OperationId,
    phase :: !ProcessPhase,
    deadline :: !UTCTime,
    receiptObserved :: !Bool
  }
  deriving stock (Eq, Show, Generic)

instance ToJSON ProcessObservation where
  toJSON value = object ["operationId" .= value.operationId, "phase" .= value.phase, "deadline" .= value.deadline, "receiptObserved" .= value.receiptObserved]

instance FromJSON ProcessObservation where
  parseJSON = withObject "ProcessObservation" \fields -> ProcessObservation <$> fields .: "operationId" <*> fields .: "phase" <*> fields .: "deadline" <*> fields .: "receiptObserved"

observeUnsettledProcesses :: NonEmpty OperationId -> Transaction (Either WorkspaceError [(OperationId, Either WorkspaceError ProcessObservation)])
observeUnsettledProcesses identifiers
  | NonEmpty.length identifiers > 256 = pure (Left WorkspaceBindingConflict)
  | otherwise = do
      rows <- Tx.statement (toJSON identifiers) (preparable observationSql (E.param (E.nonNullable E.jsonb)) (D.rowList ((,) <$> D.column (D.nonNullable D.text) <*> D.column (D.nonNullable D.jsonb))))
      pure (traverse decode rows)
  where
    decode (identifier, value) = do
      operationId <- either (const (Left WorkspaceBindingConflict)) Right (parseOperationId identifier)
      pure
        ( operationId,
          case Aeson.fromJSON value of
            Aeson.Success observed | operationIdText observed.operationId == identifier -> Right observed
            _ -> Left WorkspaceBindingConflict
        )

observationSql :: Text
observationSql =
  """
  SELECT operation_id,jsonb_build_object('operationId',record->'operationId',
   'phase',record->'phase','deadline',record->'deadline',
   'receiptObserved',CASE WHEN record ? 'receipt' THEN record->'receipt'<>'null'::jsonb END)
  FROM shikigami.workspace_processes
  WHERE NOT settled AND operation_id IN (SELECT jsonb_array_elements_text($1)) ORDER BY operation_id LIMIT 256
  """
