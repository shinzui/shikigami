{-# LANGUAGE DataKinds #-}

module Shikigami.Objective.Tracker.Handler (trackerServer, operationView, localOperationView) where

import Data.Aeson qualified as Aeson
import Data.ByteString.Lazy qualified as Lazy
import Data.Text (pack)
import Effectful (Eff)
import Kiroku.Store.Connection (defaultConnectionSettings)
import Relay.Pagination (CursorPayload (..), Direction (..), KeyValue (..), PageRequest (..), decodeCursor)
import Relay.Pagination.Hasql.Connection (mkConnection)
import Relay.Pagination.Hasql.KeyCodec (textKey)
import Relay.Pagination.Hasql.SortSpec
import Relay.Pagination.Servant qualified as Relay
import Servant.Server.Generic (AsServerT)
import Shikigami.Action.Authorization (denyAllActionAuthorizer)
import Shikigami.Api.Problem
import Shikigami.App (AppEffects, AppEnv (..), runAppIO)
import Shikigami.App.Config (AppConfig (..), HttpAuthSettings (..))
import Shikigami.Caller.Api (ApiCaller (..))
import Shikigami.Execution.Identity (operationIdText, parseOperationId)
import Shikigami.Objective.Capability qualified as Objective
import Shikigami.Objective.Tracker.Api
import Shikigami.Objective.Tracker.Control qualified as Control
import Shikigami.Objective.Tracker.Control.Types
import Shikigami.Objective.Tracker.Inspection qualified as View
import Shikigami.Objective.Tracker.Store qualified as Store
import Shikigami.Objective.Tracker.Types hiding (Conflict)
import Shikigami.Objective.Types qualified as O
import Shikigami.Prelude
import Shikigami.Server.Seam

trackerServer :: ServerEnv -> ApiCaller -> Text -> TrackerApi (AsServerT ServerM)
trackerServer env caller raw = TrackerApi {list, inspect, observations = history Observations, proposals = history Proposals, deliveries = history Publications, command, operation}
  where
    host = Store.TrackerHost (Objective.ObjectiveHost env.appConfig.objectiveSettings authenticate denyAllActionAuthorizer (\_ _ -> pure (Left O.ObjectiveDenied)) (\_ _ -> pure (Left O.ObjectiveDenied)) (\_ -> pure (Left O.ObjectiveUnavailable))) env.appConfig.trackerSettings env.trackerProvider
    authenticate = pure case env.appConfig.httpAuth of
      AuthDisabled -> Left O.ObjectiveDenied
      AuthBearer {} -> either (const (Left O.ObjectiveDenied)) (Right . O.VerifiedCaller) (O.parseCallerId caller.callerId)
    run :: Eff AppEffects (Either TrackerError a) -> ServerM (Either TrackerError a)
    run action = case env.store of
      Just store | env.appConfig.objectiveSettings.enabled == O.ObjectivesEnabled -> liftIO (runAppIO (AppEnv (defaultConnectionSettings "") env.tracer Nothing (Just store)) action) <&> either (const (Left TrackerUnavailable)) id
      _ -> pure (Left TrackerUnavailable)
    list request = page "bindings" Nothing request \objective forward after limit -> do
      rows <- View.bindings host objective
      pure (fmap (take limit . order forward . filter (within forward after)) rows)
    inspect identifier = case (O.parseObjectiveId raw, parseCoordinate identifier) of
      (Right objective, Right binding) -> run (View.binding host objective binding) <&> either readError boundedResult
      _ -> pure (Missing missing)
    history kind identifier request = page (pack (show kind)) (Just identifier) request \objective forward after limit ->
      case parseCoordinate identifier of
        Left _ -> pure (Left TrackerMissing)
        Right binding -> View.history host objective binding kind forward after limit
    page label binding request fetch = case O.parseObjectiveId raw of
      Left _ -> pure (PageMissing missing)
      Right objective -> do
        let sort = SortSpec (KeyColumn ("tracker-v1:" <> raw <> ":" <> fromMaybe "" binding <> ":" <> label) Asc (.identity) textKey :| [])
            effective = request {pageSize = min 3 request.pageSize}
        case traverse (decodeCursor (sortSpecFingerprint sort)) request.cursor of
          Right payload | request.pageSize > 0 -> case traverse cursorKey payload of
            Just after -> do
              rows <- run (fetch objective (request.direction == Forward) after (effective.pageSize + 1))
              pure case rows of
                Left TrackerDenied -> PageMissing missing
                Left TrackerMissing -> PageMissing missing
                Left _ -> PageUnavailable unavailable
                Right values -> let connection = mkConnection sort effective values in if Lazy.length (Aeson.encode connection) <= 16384 then PageOk connection else PageTooLarge tooLarge
            Nothing -> pure (PageInvalid (invalidPage request))
          _ -> pure (PageInvalid (invalidPage request))
    command body
      | Lazy.length (Aeson.encode body) > 1048576 = pure (TooLarge tooLarge)
      | otherwise = case O.parseObjectiveId raw of
          Left _ -> pure (Missing missing)
          Right objective
            | Control.networkRequest body.request -> run (Control.enqueue host objective body.operationKey body.request) <&> either commandError (\(fresh, record) -> if fresh then Accepted (operationView record) else Ok (operationView record))
            | RunCommand request <- body.request -> run (Store.execute host objective body.operationKey request) <&> either commandError (Ok . localOperationView)
            | otherwise -> pure (Invalid invalid)
    operation key = case (O.parseObjectiveId raw, parseOperationId key) of
      (Right objective, Right operation) -> do
        queued <- run (Control.inspect host objective operation)
        case queued of
          Right record -> pure (Ok (operationView record))
          Left TrackerMissing -> run (View.localReceipt host objective operation) <&> either readError (Ok . localOperationView)
          Left err -> pure (readError err)
      _ -> pure (Missing missing)
    cursorKey payload = case payload.keys of [KvText key] -> Just key; _ -> Nothing
    within _ Nothing _ = True
    within True (Just key) row = row.identity > key
    within False (Just key) row = row.identity < key
    order True = id
    order False = reverse
    boundedResult value = if Lazy.length (Aeson.encode value) <= 16384 then Ok value else TooLarge tooLarge
    readError = \case TrackerDenied -> Missing missing; TrackerMissing -> Missing missing; _ -> NotAvailable unavailable
    commandError = \case
      TrackerDenied -> Denied denied
      TrackerMissing -> Missing missing
      TrackerConflict -> Conflict conflict
      TrackerInvalid _ -> Invalid invalid
      TrackerUnavailable -> NotAvailable unavailable
    missing = problem NotFound "No accessible tracker record matches this request."
    denied = problem Forbidden "The current principal cannot perform this tracker operation."
    conflict = problem IdempotencyKeyConflict "The expected revision or retained tracker operation does not match."
    invalid = problem InvalidBody "The closed tracker document is invalid."
    unavailable = problem Unavailable "The tracker authority or configured provider is unavailable."
    tooLarge = problem PayloadTooLarge "Protected tracker replies are limited to 16 KiB and command documents to 1 MiB; request a smaller page."

operationView :: ControlRecord -> OperationView
operationView record = OperationView (operationIdText record.operationId) (pack (show record.state)) (failureCode <$> record.failure) (digestText record.fingerprint)

localOperationView :: CommandReceipt -> OperationView
localOperationView receipt = OperationView (operationIdText receipt.operationId) "Finished" Nothing (digestText receipt.fingerprint)

failureCode :: TrackerError -> Text
failureCode = \case TrackerDenied -> "denied"; TrackerMissing -> "missing"; TrackerConflict -> "conflict"; TrackerInvalid _ -> "invalid"; TrackerUnavailable -> "unavailable"

invalidPage :: PageRequest -> Relay.RelayPageError
invalidPage request = Relay.RelayPageError "invalid_cursor" "Use a positive page size and a cursor issued for this objective, binding and history." False (Just (if request.direction == Forward then "after" else "before"))
