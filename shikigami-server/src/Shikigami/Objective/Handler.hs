{-# LANGUAGE DataKinds #-}

-- | Thin HTTP adapter; all membership, receipt and mutation ordering belongs
-- to the objective command owner.
module Shikigami.Objective.Handler (objectiveServer, objectiveHost, receiptView, historyView) where

import Data.Aeson (encode)
import Data.ByteString.Lazy qualified as Lazy
import Data.Maybe (listToMaybe)
import Effectful (Eff)
import Kiroku.Store.Connection (defaultConnectionSettings)
import Servant.Server.Generic (AsServerT)
import Shikigami.Action.Authorization (denyAllActionAuthorizer)
import Shikigami.Agent.Principal (identityText)
import Shikigami.Api.Problem
import Shikigami.App (AppEffects, AppEnv (..), runAppIO)
import Shikigami.App.Config (AppConfig (..), HttpAuthSettings (..))
import Shikigami.Caller.Api (ApiCaller (..))
import Shikigami.Execution.Identity (operationIdText)
import Shikigami.Objective.Api
import Shikigami.Objective.Capability qualified as Owner
import Shikigami.Objective.Inspection qualified as View
import Shikigami.Objective.Tracker.Handler (trackerServer)
import Shikigami.Objective.Types qualified as O
import Shikigami.Prelude
import Shikigami.Server.Seam

objectiveHost :: O.ObjectiveSettings -> IO (Either O.ObjectiveError O.AccessPrincipal) -> Owner.ObjectiveHost
objectiveHost settings authenticate = Owner.ObjectiveHost settings authenticate denyAllActionAuthorizer (\_ _ -> pure (Left O.ObjectiveDenied)) (\_ _ -> pure (Left O.ObjectiveDenied)) (\_ -> pure (Left O.ObjectiveUnavailable))

objectiveServer :: ServerEnv -> ApiCaller -> ObjectiveApi (AsServerT ServerM)
objectiveServer env caller = ObjectiveApi {create, list, inspect, history, command, trackers = trackerServer env caller}
  where
    host = objectiveHost env.appConfig.objectiveSettings $ pure $ case env.appConfig.httpAuth of
      AuthDisabled -> Left O.ObjectiveDenied
      AuthBearer {} -> either (const (Left O.ObjectiveDenied)) (Right . O.VerifiedCaller) (O.parseCallerId caller.callerId)
    run :: Eff AppEffects (Either O.ObjectiveError a) -> ServerM (Either O.ObjectiveError a)
    run action
      | env.appConfig.objectiveSettings.enabled == O.ObjectivesDisabled = pure (Left O.ObjectiveUnavailable)
      | otherwise = case env.store of
          Nothing -> pure (Left O.ObjectiveUnavailable)
          Just store -> liftIO (runAppIO (AppEnv (defaultConnectionSettings "") env.tracer Nothing (Just store)) action) <&> either (const (Left O.ObjectiveUnavailable)) id
    create body
      | Lazy.length (encode body) > 1048576 = pure (CreateTooLarge tooLarge)
      | otherwise = run (Owner.createObjectiveWithDisposition host body.operationKey Nothing body.request) <&> either createError (\(fresh, receipt) -> if fresh then Created (receiptView receipt) else Replayed (receiptView receipt))
    inspect raw after requested = case (O.parseObjectiveId raw, pageSize requested) of
      (Left _, _) -> pure (ReadMissing missing)
      (Right objective, Right limit) | fromMaybe 0 after >= 0 && fromMaybe 0 after <= 10000 -> run (Owner.inspectObjective host objective (fromMaybe 0 after) limit) <&> either readError Found
      _ -> pure (ReadInvalid invalid)
    list after requested = case (traverse O.parseObjectiveId after, pageSize requested) of
      (Right cursor, Right limit) -> run (Owner.listObjectives host cursor (limit + 1)) <&> either listError (\rows -> let page = take limit rows in Listed (ObjectivePage (map View.objectiveView page) (if length rows > limit then O.objectiveIdText . (.objectiveId) <$> listToMaybe (reverse page) else Nothing)))
      _ -> pure (ListInvalid invalid)
    history raw after requested = case (O.parseObjectiveId raw, traverse O.parseRevision after, pageSize requested) of
      (Right objective, Right cursor, Right limit) -> run (Owner.readHistory host objective cursor (limit + 1)) <&> either historyError (\rows -> let page = take limit rows in HistoryFound (HistoryPage (map historyView page) (if length rows > limit then O.revisionNumber . (.receipt.revision) <$> listToMaybe (reverse page) else Nothing)))
      (Left _, _, _) -> pure (HistoryMissing missing)
      _ -> pure (HistoryInvalid invalid)
    command raw body
      | Lazy.length (encode body) > 1048576 = pure (CommandTooLarge tooLarge)
      | otherwise = case O.parseObjectiveId raw of
          Left _ -> pure (CommandMissing missing)
          Right objective -> run (Owner.executeCommand host objective body.expectedRevision body.operationKey body.command) <&> either commandError (CommandAccepted . receiptView)
    createError = \case
      O.ObjectiveDenied -> CreateDenied denied
      O.ObjectiveMissing -> CreateMissing missing
      O.ObjectiveConflict -> CreateConflict conflict
      O.ObjectiveInvalid _ -> CreateInvalid invalid
      O.ObjectiveInvalidEvidence -> CreateInvalid invalid
      _ -> CreateUnavailable unavailable
    readError = \case
      O.ObjectiveDenied -> ReadMissing missing
      O.ObjectiveMissing -> ReadMissing missing
      _ -> ReadUnavailable unavailable
    listError = \case
      O.ObjectiveDenied -> ListDenied denied
      O.ObjectiveInvalid _ -> ListInvalid invalid
      _ -> ListUnavailable unavailable
    historyError = \case
      O.ObjectiveDenied -> HistoryMissing missing
      O.ObjectiveMissing -> HistoryMissing missing
      O.ObjectiveInvalid _ -> HistoryInvalid invalid
      _ -> HistoryUnavailable unavailable
    commandError = \case
      O.ObjectiveDenied -> CommandDenied denied
      O.ObjectiveMissing -> CommandMissing missing
      O.ObjectiveConflict -> CommandConflict conflict
      O.ObjectiveInvalid _ -> CommandInvalid invalid
      O.ObjectiveInvalidEvidence -> CommandInvalid invalid
      _ -> CommandUnavailable unavailable
    missing = problem NotFound "No accessible objective matches this request."
    denied = problem Forbidden "The current principal cannot perform this objective operation."
    conflict = problem IdempotencyKeyConflict "The expected revision or retained operation does not match."
    invalid = problem InvalidBody "The objective document or page bounds are invalid."
    unavailable = problem Unavailable "Objective tracking is disabled or its authority is unavailable."
    tooLarge = problem PayloadTooLarge "Objective documents are limited to 1 MiB."

pageSize :: Maybe Int -> Either Text Int
pageSize requested = let count = fromMaybe 20 requested in if count >= 1 && count <= 100 then Right count else Left "page size must be 1..100"

receiptView :: O.Receipt -> ReceiptView
receiptView receipt = ReceiptView (O.objectiveIdText receipt.objectiveId) (operationIdText receipt.operationId) (O.mutationFingerprintText receipt.fingerprint) (O.revisionNumber receipt.revision) (O.objectivePayloadDigestText receipt.payloadDigest)

historyView :: View.HistoryEntry -> HistoryView
historyView entry = HistoryView (receiptView entry.receipt) (principal entry.actor) entry.command
  where
    principal = \case
      O.VerifiedCaller value -> PrincipalView "caller" (O.callerIdText value)
      O.LocalOperator value -> PrincipalView "operator" (O.operatorIdText value)
      O.RecordedAgent value -> PrincipalView "agent" (either (const "unavailable") id (identityText value))
