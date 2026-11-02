{-# LANGUAGE DataKinds #-}

-- | Durable admission of provider reads. Worker execution restores only the
-- authenticated principal retained by this owner, then checks current authority.
-- No public request supplies a principal, target URL, credential or dispatch POST.
module Shikigami.Objective.Tracker.Control where

import Data.Generics.Labels ()
import Data.KindID qualified as KindID
import Data.Time (addUTCTime)
import Effectful (Eff)
import Hasql.Transaction (Transaction)
import Shikigami.Execution.Identity (OperationId, operationIdText)
import Shikigami.Objective.Authority (Access (..))
import Shikigami.Objective.Store qualified as O
import Shikigami.Objective.Tracker.Command qualified as C
import Shikigami.Objective.Tracker.Config
import Shikigami.Objective.Tracker.Control.Types
import Shikigami.Objective.Tracker.Dispatch qualified as Dispatch
import Shikigami.Objective.Tracker.Sql qualified as Sql
import Shikigami.Objective.Tracker.Store qualified as S
import Shikigami.Objective.Tracker.Types
import Shikigami.Objective.Types qualified as OT
import Shikigami.Prelude

networkRequest :: ControlRequest -> Bool
networkRequest = \case RunCommand C.Bind {} -> True; RunCommand _ -> False; _ -> True

permission :: S.TrackerHost -> Access -> OT.Objective -> ControlRequest -> Transaction ()
permission host access current = \case
  RunCommand command -> S.permission host access command current
  Observe binding _ -> do
    S.requireManage access current
    retained <- S.bindingFor current.objectiveId binding
    unless (connectionUse retained.scope) (Sql.abort TrackerDenied)
  Reconcile identifier -> do
    S.requireManage access current
    (intent, _) <- Sql.publicationById identifier
    unless (intent.objectiveId == current.objectiveId && connectionUse intent.scope) (Sql.abort TrackerDenied)
  Verify identifier _ -> do
    S.requireReconciliation host access
    (intent, _) <- Sql.publicationById identifier
    unless (intent.objectiveId == current.objectiveId) (Sql.abort TrackerDenied)
  where
    -- Disabling dispatch does not hide an already admitted operation. Current
    -- membership and connection grants still apply; fresh admission separately
    -- requires enablement before resolving a provider.
    connectionUse scope = either (const False) (elem access.actor . (.useGrants)) (connectionFor host.settings scope)

precondition :: OT.ObjectiveId -> ControlRequest -> Transaction ()
precondition objective = \case
  Observe identifier expected -> do
    binding <- S.bindingFor objective identifier
    unless (binding.revision == expected && binding.state == Active) (Sql.abort TrackerConflict)
  _ -> pure ()

enqueue :: (O.ObjectiveEffects es) => S.TrackerHost -> OT.ObjectiveId -> OperationId -> ControlRequest -> Eff es (Either TrackerError (Bool, ControlRecord))
enqueue host objective operation request
  | not (networkRequest request) || not (OT.validKey (operationIdText operation)) = pure (Left (TrackerInvalid "invalid queued tracker request"))
  | otherwise = do
      grant <- liftIO (S.admit host (toJSON (objective, operation, request)))
      case grant of
        Left err -> pure (Left err)
        Right access -> do
          admission <- liftIO (KindID.toText <$> KindID.genKindID @"shikigami_tracker_control")
          let admissionId = either (error . show) id (parseCoordinate admission)
          prepared <-
            S.mapped
              ( O.trackerQuery access objective \current -> do
                  permission host access current request
                  target <- case request of
                    RunCommand (C.Bind _ scope _) -> Just . (scope,) . connectionDigestFor <$> Sql.require (connectionFor host.settings scope)
                    Observe identifier _ -> do
                      binding <- S.bindingFor objective identifier
                      pure (Just (binding.scope, binding.connectionDigest))
                    Reconcile identifier -> publicationTarget identifier
                    Verify identifier _ -> publicationTarget identifier
                    _ -> pure Nothing
                  let draft = ControlRecord TrackerV1 objective operation admissionId access.actor (trackerDigest "draft" (toJSON request)) request target Queued Nothing Nothing
                      record = draft & #fingerprint .~ controlFingerprint draft
                  old <- Sql.controlById objective operation
                  forM_ old \retained -> unless (retained.fingerprint == record.fingerprint) (Sql.abort TrackerConflict)
                  pure (record, old)
              )
          case prepared of
            Left err -> pure (Left err)
            Right (_, Just old) -> pure (Right (False, old))
            Right (record, Nothing)
              | host.settings.enabled /= TrackersEnabled || access.settings.enabled /= OT.ObjectivesEnabled -> pure (Left TrackerDenied)
              | otherwise -> do
                  available <- case record.target of Just (scope, _) -> (() <$) <$> liftIO (S.provider host scope); _ -> pure (Right ())
                  case available of
                    Left err -> pure (Left err)
                    Right () -> do
                      accepted <-
                        S.mapped
                          ( O.trackerTransaction access objective (digestText record.fingerprint) \current -> do
                              permission host access current request
                              old <- Sql.controlById objective operation
                              case old of
                                Just retained -> unless (retained.fingerprint == record.fingerprint) (Sql.abort TrackerConflict)
                                Nothing -> do
                                  local <- Sql.lookupReceipt objective operation
                                  when (isJust local) (Sql.abort TrackerConflict)
                                  precondition objective request
                                  Sql.insertControl record
                          )
                      case accepted of
                        Left err -> pure (Left err)
                        Right () -> fmap (fmap (\stored -> (stored.admissionId == admissionId, stored))) (inspect host objective operation)
  where
    publicationTarget identifier = do
      (intent, _) <- Sql.publicationById identifier
      pure (Just (intent.scope, intent.connectionDigest))

inspect :: (O.ObjectiveEffects es) => S.TrackerHost -> OT.ObjectiveId -> OperationId -> Eff es (Either TrackerError ControlRecord)
inspect host objective operation = S.query host objective \access current -> do
  record <- Sql.controlById objective operation >>= maybe (Sql.abort TrackerMissing) pure
  unless (record.actor == access.actor) (Sql.abort TrackerDenied)
  permission host access current record.request
  pure record

service :: (O.ObjectiveEffects es, ToJSON a, FromJSON a) => S.TrackerHost -> Transaction a -> Eff es (Either TrackerError a)
service host action = do
  grant <- liftIO (S.admit host (toJSON ("tracker-control-scheduler" :: Text)))
  either (pure . Left) (\access -> S.mapped (O.trackerServiceQuery access action)) grant

serviceWrite :: (O.ObjectiveEffects es) => S.TrackerHost -> OT.ObjectiveId -> Text -> Transaction () -> Eff es (Either TrackerError ())
serviceWrite host objective fingerprint action = do
  grant <- liftIO (S.admit host (toJSON ("tracker-control-settlement" :: Text)))
  either (pure . Left) (\access -> S.mapped (O.trackerServiceTransaction access objective fingerprint action)) grant

-- Requests contain only safe repeatable reads or existing idempotent commands.
-- A lease prevents routine duplicate work, while original keys recover a crash.
runPending :: (O.ObjectiveEffects es) => S.TrackerHost -> Maybe (OT.ObjectiveId, OperationId) -> Eff es (Either TrackerError (Maybe (OT.ObjectiveId, OperationId)))
runPending host after = do
  found <- service host (Sql.pendingControls after host.settings.batchSize)
  case found of
    Left err -> pure (Left err)
    Right keys -> do
      forM_ keys \(objective, operation, actor) -> runOne host objective operation actor
      pure (Right (if length keys < host.settings.batchSize then Nothing else case reverse keys of (o, k, _) : _ -> Just (o, k); _ -> Nothing))

runOne :: (O.ObjectiveEffects es) => S.TrackerHost -> OT.ObjectiveId -> OperationId -> OT.AccessPrincipal -> Eff es ()
runOne host objective operation actor = do
  let caller = host & #objective . #authenticate .~ pure (Right actor)
  admitted <- inspect caller objective operation
  case admitted of
    Left err ->
      void
        ( serviceWrite host objective "tracker-control-refused" do
            old <- Sql.controlById objective operation
            forM_ old \record -> when (record.state /= Finished) (Sql.saveControl (record & #state .~ Finished & #claim .~ Nothing & #failure .~ Just err))
        )
    Right original | original.state == Finished -> pure ()
    Right original -> do
      now <- liftIO getCurrentTime
      claimId <- liftIO Dispatch.freshClaimId
      let token = either (error . show) id (parseCoordinate (coordinateText claimId))
      claimed <- serviceWrite host objective (coordinateText token) do
        old <- Sql.controlById objective operation >>= maybe (Sql.abort TrackerMissing) pure
        unless (old.fingerprint == original.fingerprint) (Sql.abort TrackerConflict)
        when (old.state /= Finished && maybe True ((<= now) . snd) old.claim) do
          Sql.saveControl (old & #state .~ Running & #claim .~ Just (token, addUTCTime 30 now))
      case claimed of
        Left _ -> pure ()
        Right () -> do
          current <- inspect caller objective operation
          case current of
            Right record | fmap fst record.claim == Just token -> do
              result <- if maybe False (\(scope, digest) -> not (matchesConnection host.settings scope digest)) record.target then pure (Left TrackerConflict) else execute caller objective operation record.request
              void
                ( serviceWrite host objective (coordinateText token <> ":finished") do
                    old <- Sql.controlById objective operation >>= maybe (Sql.abort TrackerMissing) pure
                    when (fmap fst old.claim == Just token && old.state == Running) (Sql.saveControl (old & #state .~ Finished & #claim .~ Nothing & #failure .~ either Just (const Nothing) result))
                )
            _ -> pure ()

execute :: (O.ObjectiveEffects es) => S.TrackerHost -> OT.ObjectiveId -> OperationId -> ControlRequest -> Eff es (Either TrackerError ())
execute host objective operation = \case
  RunCommand command -> (() <$) <$> S.execute host objective operation command
  Observe identifier expected -> S.observeAt host objective identifier (Just expected)
  Reconcile identifier -> (() <$) <$> Dispatch.reconcile host objective identifier
  Verify identifier receipt -> (() <$) <$> Dispatch.verifyDelivery host objective identifier receipt
