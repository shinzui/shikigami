{-# LANGUAGE DataKinds #-}

-- | Fenced ownership changes use the same conditional command owner as public
-- edits. The workspace provider is configured by the host, never by a caller.
module Shikigami.Objective.Ownership (ownershipProvider, ownershipOperation) where

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
import Shikigami.WorkerSession.Checkpoint (ObjectiveVersion (..))
import Shikigami.WorkerSession.Store qualified as Sessions
import Shikigami.WorkerSession.Transfer qualified as Transfer

ownershipProvider :: AppEnv -> AgentIdentity -> Capability.ObjectiveHost -> Maybe Transfer.WorkspaceProvider -> Transfer.OwnershipProvider
ownershipProvider env identity supplied workspace = Transfer.OwnershipProvider transfer
  where
    host = supplied & #authenticate .~ authenticate & #verifyInternal .~ verify
    authenticate = supplied.authenticate <&> (\result -> result >>= \actor -> if actor == RecordedAgent identity then Right actor else Left ObjectiveDenied)
    verify actor = \case
      TransferSessionOwnership _ intent proof | actor == RecordedAgent identity && intent.actor == identity -> case workspace of
        Nothing -> pure (Left ObjectiveUnavailable)
        Just provider -> do
          retained <- runAppIO env do
            permit <- Sessions.authorizeSession intent.sessionId identity (pure (Right ()))
            case permit of
              Left _ -> pure False
              Right access -> do
                original <- Sessions.readTransferOperation access intent.operationId
                fence <- Sessions.readTransferFence access
                pure (original == Right intent && fence == Right (Just proof) && Transfer.matchesFence intent proof)
          case retained of
            Right True ->
              provider.reconcile intent <&> \case
                Transfer.FencedAndSettled actual | actual == proof -> Right ()
                Transfer.FenceConflict -> Left ObjectiveConflict
                Transfer.FenceUnavailable -> Left ObjectiveUnavailable
                _ -> Left ObjectiveUnresolved
            _ -> pure (Left ObjectiveUnavailable)
      _ -> pure (Left ObjectiveDenied)
    transfer intent proof
      | intent.actor /= identity = pure Transfer.OwnershipUnresolved
      | otherwise = do
          checked <- runAppIO env do
            resolved <- Capability.resolveAssignment host intent.objective
            case resolved of
              Left _ -> pure Transfer.OwnershipUnavailable
              Right reference -> do
                let command = TransferSessionOwnership reference.assignmentId intent proof
                result <- Capability.executeInternal host reference.objectiveId intent.expected.revision (ownershipOperation intent) command
                case result of
                  Right receipt -> do
                    let answer = Transfer.OwnershipReceipt V1 intent.objective intent.operationId (Transfer.ownershipFingerprint intent proof) receipt.revision
                    pure (if Transfer.matchesOwnership intent proof answer then Transfer.OwnershipAccepted answer else Transfer.OwnershipUnresolved)
                  Left ObjectiveUnavailable -> pure Transfer.OwnershipUnavailable
                  Left ObjectiveDenied -> pure Transfer.OwnershipUnavailable
                  Left _ -> do
                    saved <- Capability.readInternalReceipt host reference.objectiveId intent.expected.revision (ownershipOperation intent) command
                    pure case saved of
                      Right (Just (Left refusal)) | refusal `notElem` [ObjectiveDenied, ObjectiveUnavailable, ObjectiveUnresolved] -> Transfer.OwnershipConflict
                      _ -> Transfer.OwnershipUnresolved
          pure (either (const Transfer.OwnershipUnavailable) id checked)

ownershipOperation :: Transfer.TransferIntent -> OperationId
ownershipOperation intent = operationIdWithPrefix ('o' :| "bjective-handoff:") (versionedDigest "shikigami.objective-ownership-operation/1" (toJSON (intent.sessionId, intent.operationId)))
