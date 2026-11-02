{-# LANGUAGE DataKinds #-}

-- | Protected, bounded display projections. The digest names the full retained
-- document; previews explicitly truncate text and cannot be submitted as commands.
module Shikigami.Objective.Tracker.Inspection where

import Data.Aeson qualified as Aeson
import Data.List (sortOn)
import Data.Text (pack)
import Data.Text qualified as Text
import Data.Vector qualified as Vector
import Effectful (Eff)
import Shikigami.Execution.Identity (OperationId)
import Shikigami.Objective.Authority (Access (..))
import Shikigami.Objective.Store qualified as O
import Shikigami.Objective.Tracker.Control.Types
import Shikigami.Objective.Tracker.Sql qualified as Sql
import Shikigami.Objective.Tracker.Store qualified as S
import Shikigami.Objective.Tracker.Types
import Shikigami.Objective.Types qualified as OT
import Shikigami.Prelude

-- No private field appears unbounded; at most six records fit a protected reply.
data RecordView = RecordView
  { identity :: !Text,
    digest :: !Text,
    preview :: !Aeson.Value,
    truncated :: !Bool
  }
  deriving stock (Eq, Show, Generic)
  deriving anyclass (ToJSON, FromJSON)

recordView :: HistoryRecord -> RecordView
recordView record = RecordView record.identity (digestText (trackerDigest "shikigami.tracker-inspection/1" record.document :: TrackerDigest "inspection")) preview (preview /= record.document)
  where
    preview = bounded record.document

bounded :: Aeson.Value -> Aeson.Value
bounded = \case
  Aeson.String value -> Aeson.String (Text.take 160 value)
  Aeson.Object fields -> Aeson.Object (fmap bounded fields)
  Aeson.Array values -> Aeson.Array (Vector.map bounded (Vector.take 16 values))
  value -> value

bindings :: (O.ObjectiveEffects es) => S.TrackerHost -> OT.ObjectiveId -> Eff es (Either TrackerError [RecordView])
bindings host objective = fmap (fmap (sortOn (.identity) . map (\binding -> recordView (HistoryRecord (coordinateText binding.bindingId) (toJSON binding))))) (S.inspectBindings host objective)

history :: (O.ObjectiveEffects es) => S.TrackerHost -> OT.ObjectiveId -> TrackerBindingId -> HistoryKind -> Bool -> Maybe Text -> Int -> Eff es (Either TrackerError [RecordView])
history host objective binding kind forward after limit = S.query host objective \_ _ -> do
  _ <- S.bindingFor objective binding
  fmap recordView <$> Sql.historyPage binding kind forward after (min 7 limit)

localReceipt :: (O.ObjectiveEffects es) => S.TrackerHost -> OT.ObjectiveId -> OperationId -> Eff es (Either TrackerError CommandReceipt)
localReceipt host objective operation = S.query host objective \access current -> do
  receipt <- Sql.lookupReceipt objective operation >>= maybe (Sql.abort TrackerMissing) pure
  unless (receipt.actor == access.actor) (Sql.abort TrackerDenied)
  S.requireManage access current
  pure receipt

data BindingView = BindingView
  { objectiveId :: !Text,
    localRevision :: !Integer,
    localStatus :: !Text,
    localInstructions :: !RecordView,
    binding :: !RecordView,
    lastSuccessfulObservation :: !(Maybe UTCTime),
    pendingProposals :: !Int,
    deliveryState :: !(Maybe Text)
  }
  deriving stock (Eq, Show, Generic)
  deriving anyclass (ToJSON, FromJSON)

binding :: (O.ObjectiveEffects es) => S.TrackerHost -> OT.ObjectiveId -> TrackerBindingId -> Eff es (Either TrackerError BindingView)
binding host objective identifier = S.query host objective \_ current -> do
  retained <- S.bindingFor objective identifier
  proposals <- Sql.awaitingProposalsFor identifier
  unresolved <- Sql.nextUnsettled identifier
  latest <- case unresolved of Just pair -> pure (Just pair); Nothing -> Sql.latestPublication identifier
  observed <- Sql.lastObservationTime identifier
  pure (BindingView (OT.objectiveIdText objective) (OT.revisionNumber current.revision) (pack (show current.status)) (recordView (HistoryRecord "local-instructions" (toJSON current.instructions))) (recordView (HistoryRecord (coordinateText identifier) (toJSON retained))) observed (length proposals) (pack . show . (.state) . snd <$> latest))
