{-# LANGUAGE DataKinds #-}

-- | Lock-free resource control metadata. Usage vectors, operation requests and
-- attempt bodies remain with the resource owner and are never projected here.
module Shikigami.Execution.RootObservation (RootObservation (..), observeRoots, observationSql) where

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
import Shikigami.Execution.Counter (AttemptCount)
import Shikigami.Execution.Identity (ExecutionRootId, executionRootIdText, parseExecutionRootId)
import Shikigami.Execution.Resources (Cancellation, Overage, ResourceError (ResourceStateCorrupt))
import Shikigami.StateRevision (StateRevision)

data RootObservation = RootObservation
  { rootId :: !ExecutionRootId,
    revision :: !(StateRevision "execution-root"),
    cancelled :: !Cancellation,
    overage :: !Overage,
    cutoff :: !UTCTime,
    active :: !(AttemptCount "root-active"),
    unknown :: !(AttemptCount "root-unknown")
  }
  deriving stock (Eq, Show, Generic)

instance ToJSON RootObservation where
  toJSON value = object ["rootId" .= value.rootId, "revision" .= value.revision, "cancelled" .= value.cancelled, "overage" .= value.overage, "cutoff" .= value.cutoff, "active" .= value.active, "unknown" .= value.unknown]

instance FromJSON RootObservation where
  parseJSON = withObject "RootObservation" \fields -> RootObservation <$> fields .: "rootId" <*> fields .: "revision" <*> fields .: "cancelled" <*> fields .: "overage" <*> fields .: "cutoff" <*> fields .: "active" <*> fields .: "unknown"

observeRoots :: NonEmpty ExecutionRootId -> Transaction (Either ResourceError [(ExecutionRootId, Either ResourceError RootObservation)])
observeRoots identifiers
  | NonEmpty.length identifiers > 256 = pure (Left ResourceStateCorrupt)
  | otherwise = do
      rows <- Tx.statement (toJSON identifiers) (preparable observationSql (E.param (E.nonNullable E.jsonb)) (D.rowList ((,) <$> D.column (D.nonNullable D.text) <*> D.column (D.nonNullable D.jsonb))))
      pure (traverse decode rows)
  where
    decode (identifier, value) = do
      rootId <- either (const (Left ResourceStateCorrupt)) Right (parseExecutionRootId identifier)
      pure
        ( rootId,
          case Aeson.fromJSON value of
            Aeson.Success observed | executionRootIdText observed.rootId == identifier -> Right observed
            _ -> Left ResourceStateCorrupt
        )

observationSql :: Text
observationSql =
  """
  SELECT root_id,jsonb_build_object('rootId',root_id,'revision',state->'revision',
   'cancelled',state->'cancelled','overage',state->'overage','cutoff',state#>'{envelope,cutoff}',
   'active',state->'active','unknown',state->'unknown')
  FROM shikigami.execution_roots
  WHERE root_id IN (SELECT jsonb_array_elements_text($1)) ORDER BY root_id LIMIT 256
  """
