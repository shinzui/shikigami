{-# LANGUAGE DataKinds #-}

-- | Narrow authenticated adapter over the real objective checkpoint owner.
-- Stable operation lookup precedes validation, so a committed decision is never
-- recomputed against a later checkpoint. Current authority still gates reads.
module Shikigami.Coordination.Checkpoint (Checkpoint (..), Provider (..), checkpointProvider) where

import Data.Aeson ((.!=), (.:), (.:?))
import Data.Aeson qualified as Aeson
import Data.Generics.Labels ()
import Effectful (Eff)
import Hasql.Transaction (Transaction)
import Shikigami.App (AppEffects, AppEnv, runAppIO)
import Shikigami.Coordination.Proposal
import Shikigami.Coordination.Sql qualified as Sql
import Shikigami.Coordination.Validate
import Shikigami.Execution.Identity (OperationId)
import Shikigami.Objective.Capability qualified as Owner
import Shikigami.Objective.Command (InternalCommand (ApplyAdaptiveDecision))
import Shikigami.Objective.Store qualified as Store
import Shikigami.Objective.Types
import Shikigami.Prelude
import Shikigami.Workspace.Reference (WorkspaceRef)

data Checkpoint = Checkpoint
  { objective :: !Objective,
    arrangement :: ![Placement],
    workspaces :: ![(ObjectiveAssignmentId, WorkspaceRef)]
  }
  deriving stock (Eq, Show, Generic)
  deriving anyclass (ToJSON)

instance FromJSON Checkpoint where
  parseJSON = Aeson.withObject "AdaptiveCheckpoint" \fields -> Checkpoint <$> fields .: "objective" <*> fields .: "arrangement" <*> (fields .:? "workspaces" .!= [])

data Provider = Provider
  { current :: !(ObjectiveId -> IO (Either ObjectiveError Checkpoint)),
    observe :: !(ObjectiveId -> OperationId -> IO (Either ObjectiveError (Maybe AcceptedDecision))),
    accept :: !(Proposal -> IO (Either ObjectiveError AcceptedDecision))
  }

-- | The supplied policy must already be pinned from admitted declarations.
-- The callback checks its continued availability; it may refuse but cannot add
-- authority. It is runtime context and has no model-facing decoder.
checkpointProvider :: AppEnv -> Owner.ObjectiveHost -> Policy -> IO (Either ObjectiveError ()) -> Provider
checkpointProvider env supplied policy fresh = Provider current observe accept
  where
    host = supplied & #verifyInternal .~ verify
    owned :: Eff AppEffects (Either ObjectiveError a) -> IO (Either ObjectiveError a)
    owned action = runAppIO env action <&> either (const (Left ObjectiveUnavailable)) id
    query :: (ToJSON a, FromJSON a) => ObjectiveId -> (Objective -> Transaction (Either ObjectiveError a)) -> IO (Either ObjectiveError a)
    query objective action = owned do
      grant <- liftIO (Owner.admitObjectiveAction host "adaptive-checkpoint" (toJSON objective))
      case grant of
        Left err -> pure (Left err)
        Right access -> do
          answer <- Store.coordinationQuery access objective \current ->
            if Store.mayCoordinate access current
              then action current
              else pure (Left ObjectiveDenied)
          pure (answer >>= id)
    current objective = query objective \value -> do
      retained <- Sql.readArrangement objective
      pure do
        previous <- retained
        arrangement <- currentArrangement policy previous value
        Right (Checkpoint value arrangement policy.workspaces)
    observe objective operation = query objective \_ -> Sql.readDecision objective operation
    verify actor command = case command of
      ApplyAdaptiveDecision decision | actor == RecordedAgent policy.identity && decision.policy == policy -> fresh
      _ -> pure (Left ObjectiveDenied)
    accept proposal =
      observe proposal.objectiveId proposal.operationId >>= \case
        Right (Just decision)
          | decision.proposal == proposal && decision.policy == policy -> pure (Right decision)
          | otherwise -> pure (Left ObjectiveConflict)
        Left err -> pure (Left err)
        Right Nothing -> do
          available <- fresh
          checkpoint <- current proposal.objectiveId
          now <- getCurrentTime
          case available >> (checkpoint >>= \value -> validateProposal now policy value.arrangement value.objective proposal) of
            Left err -> do
              when (err /= ObjectiveUnavailable) $ void $ query proposal.objectiveId \_ -> do
                Sql.saveObservation proposal.objectiveId proposal.operationId "refusal" proposal.checkpointRevision "Refused" (Just (refusalCode err))
                pure (Right ())
              pure (Left err)
            Right decision -> do
              receipt <- owned (Owner.executeInternal host proposal.objectiveId proposal.checkpointRevision proposal.operationId (ApplyAdaptiveDecision decision))
              pure (decision <$ receipt)

-- Keep protected diagnostics and untrusted text out of public metadata.
refusalCode :: ObjectiveError -> Text
refusalCode = \case
  ObjectiveMissing -> "Missing"
  ObjectiveDenied -> "Denied"
  ObjectiveConflict -> "Conflict"
  ObjectiveInvalid _ -> "InvalidProposal"
  ObjectiveInvalidEvidence -> "InvalidEvidence"
  ObjectiveUnavailable -> "Unavailable"
  ObjectiveUnresolved -> "Unresolved"
