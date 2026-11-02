{-# LANGUAGE DataKinds #-}

-- | Actor-scoped adapter over the objective command owner. The session retains
-- the immutable request; neither the callback nor an ObjectiveRef is a grant.
module Shikigami.Objective.Checkpoint (checkpointProvider, checkpointOperation) where

import Data.Generics.Labels ()
import Data.List.NonEmpty (NonEmpty (..))
import Shikigami.Agent.Principal (AgentIdentity)
import Shikigami.App (AppEnv, runAppIO)
import Shikigami.Decision.Contract (versionedDigest)
import Shikigami.Execution.Identity (OperationId, operationIdWithPrefix)
import Shikigami.FormatVersion (FormatVersion (V1))
import Shikigami.Objective.Capability qualified as Capability
import Shikigami.Objective.Command
import Shikigami.Objective.Reference (ObjectiveAssociation (..))
import Shikigami.Objective.Types
import Shikigami.Prelude
import Shikigami.WorkerSession.Checkpoint qualified as CP
import Shikigami.WorkerSession.Store qualified as Sessions
import Shikigami.WorkerSession.Types (SessionError (..))

checkpointProvider :: AppEnv -> AgentIdentity -> Capability.ObjectiveHost -> CP.CheckpointProvider
checkpointProvider env identity supplied = CP.CheckpointProvider current commit
  where
    host = supplied & #authenticate .~ authenticate & #verifyInternal .~ verify
    authenticate = supplied.authenticate <&> (\result -> result >>= \actor -> if actor == RecordedAgent identity then Right actor else Left ObjectiveDenied)
    current reference =
      runAppIO env (Capability.readCheckpointVersion host reference) <&> \case
        Right (Right version) -> Right version
        _ -> Left "objective assignment authority unavailable"
    verify actor = \case
      ProjectCheckpoint _ intent | actor == RecordedAgent identity && intent.actor == identity -> do
        checked <- runAppIO env do
          permit <- Sessions.authorizeSession intent.sessionId identity (pure (Right ()))
          case permit of
            Left _ -> pure (Left ObjectiveDenied)
            Right access -> do
              original <- Sessions.readCheckpointIntent access intent.operationId
              pure case original of
                Right actual | actual == intent -> Right ()
                Left SessionStorageUnavailable -> Left ObjectiveUnavailable
                _ -> Left ObjectiveDenied
        pure (either (const (Left ObjectiveUnavailable)) id checked)
      _ -> pure (Left ObjectiveDenied)
    commit intent
      | intent.actor /= identity = pure CP.CheckpointUnresolved
      | otherwise = do
          checked <- runAppIO env do
            resolved <- Capability.resolveAssignment host intent.objective
            case resolved of
              Left _ -> pure CP.CheckpointUnavailable
              Right reference -> do
                let command = ProjectCheckpoint reference.assignmentId intent
                result <- Capability.executeInternal host reference.objectiveId intent.expected.revision (checkpointOperation intent) command
                case result of
                  Right receipt -> do
                    let answer = CP.CheckpointReceipt V1 intent.objective intent.operationId (CP.intentFingerprint intent) receipt.revision
                    pure (if CP.matchesReceipt intent answer then CP.CheckpointAccepted answer else CP.CheckpointUnresolved)
                  Left ObjectiveUnavailable -> pure CP.CheckpointUnavailable
                  Left ObjectiveDenied -> pure CP.CheckpointUnavailable
                  Left _ -> do
                    -- Only a retained non-commit for this exact request is a
                    -- definitive conflict. Corruption/transport has no proof.
                    proof <- Capability.readInternalReceipt host reference.objectiveId intent.expected.revision (checkpointOperation intent) command
                    pure case proof of
                      Right (Just (Left refusal)) | refusal `notElem` [ObjectiveDenied, ObjectiveUnavailable, ObjectiveUnresolved] -> CP.CheckpointConflict
                      _ -> CP.CheckpointUnresolved
          pure (either (const CP.CheckpointUnavailable) id checked)

-- Session command keys are scoped by session; objective receipts are scoped by
-- objective. Bind both coordinates rather than requiring global source keys.
checkpointOperation :: CP.CheckpointIntent -> OperationId
checkpointOperation intent = operationIdWithPrefix ('o' :| "bjective-checkpoint:") (versionedDigest "shikigami.objective-checkpoint-operation/1" (toJSON (intent.sessionId, intent.operationId)))
