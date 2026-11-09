{-# LANGUAGE DataKinds #-}

-- | A bounded read-only cycle accepts one authoritative checkpoint snapshot.
-- No-delta observations neither run a worker nor publish objective progress.
module Shikigami.Mandate.Cycle (acceptWake, commitCycleProgress, reconcileCycle) where

import Data.Generics.Labels ()
import Data.List (find)
import Data.Text qualified as Text
import Data.Time (addUTCTime)
import Effectful (Eff)
import Hasql.Transaction (Transaction)
import Shikigami.App (AppEffects)
import Shikigami.Execution.Identity (OperationId, operationIdWithPrefix)
import Shikigami.Execution.Resources qualified as R
import Shikigami.Execution.ResourcesStore qualified as Roots
import Shikigami.Mandate.Store qualified as S
import Shikigami.Mandate.Types
import Shikigami.Objective.Capability qualified as Owner
import Shikigami.Objective.Store qualified as Goals
import Shikigami.Objective.Types hiding (CreateRequest)
import Shikigami.Prelude

nextNumber :: Mandate -> Integer
nextNumber state = maybe 1 ((+ 1) . (.number)) state.lastCycle

fences :: Objective -> Mandate -> [(ObjectiveAssignmentId, StateRevision "worker-owner")]
fences goal state = [(key, assignment.ownerEpoch) | key <- state.admission.scope, Just assignment <- [find ((== key) . (.definition.assignmentId)) goal.assignments]]

-- This check is repeated in the commit transaction, including no-delta cycles.
stopReasonFor :: UTCTime -> Objective -> Mandate -> Transaction (Maybe StopReason)
stopReasonFor now goal state
  | now >= state.admission.expiresAt = pure (Just Expired)
  | goal.status `elem` [Completed, Cancelled] = pure (Just ObjectiveFinished)
  | goal.owner /= state.owner = pure (Just OwnershipChanged)
  | otherwise = do
      root <- Roots.inspectRootTx state.admission.rootId
      pure case root of
        Left _ -> Just RootStopped
        Right value | value.cancelled == R.StopWork || value.overage /= R.NoOverage || now >= value.envelope.cutoff -> Just RootStopped
        _ -> Nothing

-- | Wake ids are hints. Current state selects the stable cycle identity.
acceptWake :: Owner.ObjectiveHost -> MandateId -> UTCTime -> Eff AppEffects (Either ObjectiveError Mandate)
acceptWake host identifier now = do
  observed <- S.inspectMandate host identifier
  case observed of
    Left err -> pure (Left err)
    Right state | isJust state.stopReason || isJust state.activeCycle -> pure (Right state)
    Right state -> S.transition host identifier state.revision (key "accept" state) (toJSON ("accept" :: Text, nextNumber state)) \goal current -> do
      reason <- stopReasonFor now goal current
      case reason of
        Just stop -> pure (stopped stop goal current)
        Nothing -> do
          S.checkScope current.admission goal
          void (S.checkRoot now current.admission.rootId current.admission.expiresAt)
          if current.watermark == Just (S.checkpointMark goal)
            then pure (idle now goal current)
            else do
              receipt <- Goals.checkpointReceiptTx goal >>= S.require
              let number = nextNumber current
                  cycle = Cycle number (S.cycleOperation identifier number) (S.checkpointMark goal) goal.instructionsRevision goal.criteriaRevision goal.owner (fences goal current) current.admission.rootId [receipt.operationId]
              pure (current & #activeCycle .~ Just cycle & #unresolved .~ goal.unresolved)

-- A read-only checkpoint cycle is accepted only against its exact current
-- owner/meaning. Revalidation after replacement never restores old assignments.
commitCycleProgress :: Owner.ObjectiveHost -> MandateId -> UTCTime -> Eff AppEffects (Either ObjectiveError Mandate)
commitCycleProgress host identifier now = do
  observed <- S.inspectMandate host identifier
  case observed of
    Left err -> pure (Left err)
    Right state | isJust state.stopReason -> pure (Right state)
    Right state -> case state.activeCycle of
      Nothing -> pure (Right state)
      Just cycle -> S.transition host identifier state.revision (key "commit" state) (toJSON ("commit" :: Text, cycle.operationId)) \goal current -> do
        reason <- stopReasonFor now goal current
        case reason of
          Just stop -> pure (stopped stop goal current)
          Nothing -> do
            S.checkScope current.admission goal
            void (S.checkRoot now current.admission.rootId current.admission.expiresAt)
            receipt <- Goals.checkpointReceiptTx goal >>= S.require
            -- Only the checkpoint owner supplies accepted progress references.
            -- This read-only adapter can safely supersede its observation with
            -- current state; it has launched no external operation to hand off.
            let actual = cycle & #checkpoint .~ S.checkpointMark goal & #instructionsRevision .~ goal.instructionsRevision & #criteriaRevision .~ goal.criteriaRevision & #owner .~ goal.owner & #fences .~ fences goal current & #progress .~ [receipt.operationId]
                due = min current.admission.expiresAt (addUTCTime (fromIntegral current.admission.cadence.seconds) now)
            pure (current & #watermark .~ Just actual.checkpoint & #lastCycle .~ Just actual & #activeCycle .~ Nothing & #idleCount .~ 0 & #nextDue .~ Just due & #unresolved .~ goal.unresolved)

idle :: UTCTime -> Objective -> Mandate -> Mandate
idle now goal state = state & #idleCount .~ count & #nextDue .~ Just (min state.admission.expiresAt (addUTCTime (fromIntegral (backoff state.admission.cadence count)) now)) & #unresolved .~ goal.unresolved
  where
    count = min 20 (state.idleCount + 1)

stopped :: StopReason -> Objective -> Mandate -> Mandate
stopped reason goal state = state & #stopReason .~ Just reason & #fence %~ advanceRevision & #nextDue .~ Nothing & #unresolved .~ goal.unresolved

key :: Text -> Mandate -> OperationId
key phase state = operationIdWithPrefix ('m' :| "andate:") (phase <> ":" <> state.admission.mandateId.value <> ":" <> (case state.activeCycle of Just cycle -> showText cycle.number; Nothing -> showText (revisionNumber state.revision)))
  where
    showText = Text.pack . show

-- | Process maintenance may stop a revoked caller, but never grants it work.
-- The supplied actor host must authenticate the retained authority exactly.
reconcileCycle :: Owner.ObjectiveHost -> (AccessPrincipal -> Owner.ObjectiveHost) -> MandateId -> UTCTime -> Eff AppEffects (Either ObjectiveError Mandate)
reconcileCycle service hostFor identifier now = do
  observed <- S.serviceInspect service identifier
  case observed of
    Left err -> pure (Left err)
    Right state | isJust state.stopReason -> pure (Right state)
    Right state -> do
      let host = hostFor state.authority
      actor <- liftIO host.authenticate
      case actor of
        Right actual | actual == state.authority -> do
          accepted <- acceptWake host identifier now
          case accepted of
            Right _ -> do
              committed <- commitCycleProgress host identifier now
              case committed of
                Left ObjectiveDenied -> revoke
                _ -> pure committed
            Left ObjectiveDenied -> revoke
            Left err -> pure (Left err)
        Left ObjectiveUnavailable -> pure (Left ObjectiveUnavailable)
        _ -> revoke
  where
    revoke = do
      observed <- S.serviceInspect service identifier
      case observed of
        Left err -> pure (Left err)
        Right state | isJust state.stopReason -> pure (Right state)
        Right state -> S.serviceTransition service identifier state.revision (key "revoke" state) (toJSON ("revoked" :: Text)) \goal current -> pure (stopped Revoked goal current)
