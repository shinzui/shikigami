{-# LANGUAGE DataKinds #-}

-- | Mandate lifecycle, receipts and progress share the objective lock. The
-- retained resource owner is consulted, never copied or replenished.
module Shikigami.Mandate.Store
  ( admitMandate,
    inspectMandate,
    inspectWithResources,
    updateMandate,
    stopMandate,
    transition,
    serviceTransition,
    serviceInspect,
    locate,
    cycleOperation,
    checkpointMark,
    require,
    abort,
    loadTx,
    saveCycleTx,
    checkRoot,
    checkScope,
    publishWake,
  )
where

import Contravariant.Extras (contrazip2, contrazip3)
import Control.Exception (Exception, fromException, throw)
import Data.Aeson ((.=))
import Data.Aeson qualified as Aeson
import Data.Functor.Contravariant ((>$<))
import Data.Generics.Labels ()
import Data.List (find)
import Data.Map.Strict qualified as Map
import Data.Text qualified as Text
import Effectful (Eff)
import Effectful.Error.Static (tryError)
import Effectful.Exception (catchSync, throwIO)
import Hasql.Decoders qualified as D
import Hasql.Encoders qualified as E
import Hasql.Statement (preparable)
import Hasql.Transaction (Transaction)
import Hasql.Transaction qualified as Tx
import Keiro.Command (CommandError (..))
import Keiro.Projection (ProjectionCommandOutcome (..), runCommandWithCatalogProjections)
import Keiro.ReadModel (runQuery)
import Keiro.Stream qualified as Stream
import Keiro.Timer (cancelTimerTx, scheduleTimerOnceTx)
import Keiro.Workflow (StepName (..))
import Kiroku.Store.Error (StoreError)
import Kiroku.Store.Transaction (runTransaction)
import Shikigami.App (AppEffects, commandOptions)
import Shikigami.Coordination.Wake qualified as CheckpointWake
import Shikigami.Decision.Contract (versionedDigest)
import Shikigami.Execution.Identity (ExecutionRootId, OperationId, operationIdText, operationIdWithPrefix)
import Shikigami.Execution.Resources qualified as R
import Shikigami.Execution.ResourcesStore qualified as Roots
import Shikigami.Mandate.Catalog
import Shikigami.Mandate.Types
import Shikigami.Mandate.Wake qualified as Wake
import Shikigami.MandateLifecycle.Generated.Domain qualified as G
import Shikigami.MandateLifecycle.Generated.EventStream
import Shikigami.MandateLookup.Generated.ReadModel (mandateLookupReadModel)
import Shikigami.Objective.Authority (Access (..))
import Shikigami.Objective.Capability qualified as Owner
import Shikigami.Objective.Store qualified as Goals
import Shikigami.Objective.Types hiding (CreateRequest)
import Shikigami.Prelude hiding ((.=))
import Shikigami.RecurringObjective.Generated.WorkflowRuntime qualified as Native
import Shikigami.Workflow.Versioning (prepareAdmittedInput)

newtype Failure = Failure ObjectiveError deriving stock (Show)

instance Exception Failure

abort :: ObjectiveError -> Transaction a
abort err = Tx.condemn >> throw (Failure err)

require :: Either ObjectiveError a -> Transaction a
require = either abort pure

guarded :: Eff AppEffects (Either ObjectiveError a) -> Eff AppEffects (Either ObjectiveError a)
guarded action = do
  value <- tryError @StoreError (catchSync action \exception -> case fromException exception of Just (Failure err) -> pure (Left err); Nothing -> throwIO exception)
  pure (either (const (Left ObjectiveUnavailable)) id value)

text :: E.Params Text
text = E.param (E.nonNullable E.text)

json :: (ToJSON a) => E.Params a
json = toJSON >$< E.param (E.nonNullable E.jsonb)

column :: D.Row Aeson.Value
column = D.column (D.nonNullable D.jsonb)

decode :: (FromJSON a) => Aeson.Value -> Transaction a
decode value = case Aeson.fromJSON value of Aeson.Success answer -> pure answer; _ -> abort ObjectiveUnavailable

loadTx :: MandateId -> Transaction (Maybe Mandate)
loadTx identifier = do
  value <- Tx.statement identifier.value (preparable "SELECT state FROM shikigami.mandates WHERE mandate_id=$1 FOR UPDATE" text (D.rowMaybe column))
  forM value \raw -> do
    state <- decode raw
    unless (state.format == 1 && state.admission.mandateId == identifier) (abort ObjectiveUnavailable)
    require (validateSnapshot state)
    pure state

-- Only the locator is public to the trusted runtime; no payload is exposed.
locate :: MandateId -> Eff AppEffects (Either ObjectiveError ObjectiveId)
locate identifier = guarded $ runTransaction do
  row <- Tx.statement identifier.value (preparable "SELECT objective_id FROM shikigami.mandates WHERE mandate_id=$1" text (D.rowMaybe (D.column (D.nonNullable D.text))))
  pure (maybe (Left ObjectiveMissing) (either (const (Left ObjectiveUnavailable)) Right . parseObjectiveId) row)

permit :: Owner.ObjectiveHost -> Text -> Aeson.Value -> Eff AppEffects Access
permit host label semantic = liftIO (Owner.admitObjectiveAction host label semantic) >>= either (throwIO . Failure) pure

query :: Owner.ObjectiveHost -> MandateId -> Bool -> Eff AppEffects (Either ObjectiveError Mandate)
query host identifier service = guarded do
  access <- permit host "mandate-inspect" (toJSON identifier)
  objective <- locate identifier >>= either (throwIO . Failure) pure
  let action = do
        goal <- Goals.lockedEither objective >>= require
        if service then checkService access else Goals.checkAccessTx access goal >>= require
        state <- loadTx identifier >>= maybe (abort ObjectiveMissing) pure
        unless (state.admission.objectiveId == objective) (abort ObjectiveUnavailable)
        pure state
  protected action

inspectMandate :: Owner.ObjectiveHost -> MandateId -> Eff AppEffects (Either ObjectiveError Mandate)
inspectMandate host key = query host key False

inspectWithResources :: Owner.ObjectiveHost -> MandateId -> Eff AppEffects (Either ObjectiveError (Mandate, R.Root))
inspectWithResources host identifier = guarded do
  access <- permit host "mandate-inspect" (toJSON identifier)
  objective <- locate identifier >>= either (throwIO . Failure) pure
  protected do
    goal <- Goals.lockedEither objective >>= require
    Goals.checkAccessTx access goal >>= require
    state <- loadTx identifier >>= maybe (abort ObjectiveMissing) pure
    unless (state.admission.objectiveId == objective) (abort ObjectiveUnavailable)
    root <- Roots.inspectRootTx state.admission.rootId >>= either (const (abort ObjectiveUnavailable)) pure
    pure (state, root)

serviceInspect :: Owner.ObjectiveHost -> MandateId -> Eff AppEffects (Either ObjectiveError Mandate)
serviceInspect host key = query host key True

checkService :: Access -> Transaction ()
checkService access = case access.actor of
  LocalOperator identity | access.settings.operator == Just identity -> do
    now <- Tx.statement () (preparable "SELECT clock_timestamp()" E.noParams (D.singleRow (D.column (D.nonNullable D.timestamptz))))
    unless (now < access.expiresAt) (abort ObjectiveDenied)
  _ -> abort ObjectiveDenied

checkRoot :: UTCTime -> ExecutionRootId -> UTCTime -> Transaction R.Root
checkRoot now root expiry = do
  state <- Roots.inspectRootTx root >>= either (const (abort ObjectiveDenied)) pure
  unless (state.cancelled == R.ContinueWork && state.overage == R.NoOverage && now < state.envelope.cutoff && expiry <= state.envelope.cutoff) (abort ObjectiveDenied)
  -- Absent dimensions deny expenditure. Explicit unbounded spend cannot fund
  -- recurring work; its time and every admitted quantity must be finite.
  unless (all (\case R.Limited _ -> True; R.ExplicitlyUnbounded -> False) (Map.elems state.envelope.limits)) (abort ObjectiveDenied)
  pure state

checkScope :: CreateRequest -> Objective -> Transaction ()
checkScope request goal = do
  unless (goal.status `elem` [Open, Blocked]) (abort ObjectiveDenied)
  forM_ request.scope \key -> case find ((== key) . (.definition.assignmentId)) goal.assignments of
    Just assignment | assignment.definition.rootId == Just request.rootId && assignment.definition.state /= Withdrawn -> pure ()
    _ -> abort ObjectiveDenied

checkpointMark :: Objective -> Watermark
checkpointMark goal = Watermark goal.revision (versionedDigest "shikigami.objective-checkpoint/1" (toJSON (goal.objectiveId, goal.revision)))

cycleOperation :: MandateId -> Integer -> OperationId
cycleOperation identifier cycle = operationIdWithPrefix ('m' :| "andate-cycle:") (versionedDigest "shikigami.mandate-cycle/1" (toJSON (identifier, cycle)))

admitMandate :: Owner.ObjectiveHost -> OperationId -> CreateRequest -> Eff AppEffects (Either ObjectiveError Mandate)
admitMandate host operation request = guarded do
  access <- permit host "mandate-create" (toJSON (operation, request))
  now <- liftIO getCurrentTime
  let initial goal = do
        require (validateRequest now request)
        checkScope request goal
        void (checkRoot now request.rootId request.expiresAt)
        pure (Mandate 1 request access.actor goal.owner initialRevision initialRevision Nothing Nothing Nothing (Just now) 0 Nothing goal.unresolved Nothing)
  mutate access False request.objectiveId request.mandateId operation (toJSON ("create" :: Text, request)) Nothing (\_ _ -> pure ()) \goal previous -> do
    unless (isNothing previous) (abort ObjectiveConflict)
    initial goal

updateMandate :: Owner.ObjectiveHost -> MandateId -> StateRevision "mandate" -> OperationId -> ScheduleUpdate -> Eff AppEffects (Either ObjectiveError Mandate)
updateMandate host identifier expected operation update = do
  now <- liftIO getCurrentTime
  transition host identifier expected operation (toJSON ("update" :: Text, update)) \goal state -> do
    require (validateSchedule now update.cadence update.expiresAt)
    void (checkRoot now state.admission.rootId update.expiresAt)
    checkScope state.admission goal
    unless (isNothing state.activeCycle && isNothing state.stopReason) (abort ObjectiveConflict)
    pure (state & #admission . #cadence .~ update.cadence & #admission . #expiresAt .~ update.expiresAt & #nextDue .~ Just now & #idleCount .~ 0)

stopMandate :: Owner.ObjectiveHost -> MandateId -> StateRevision "mandate" -> OperationId -> Eff AppEffects (Either ObjectiveError Mandate)
stopMandate host identifier expected operation = transition host identifier expected operation (toJSON ("cancel" :: Text)) \goal state -> pure (state & #stopReason .~ Just CancelledByCaller & #fence %~ advanceRevision & #nextDue .~ Nothing & #unresolved .~ goal.unresolved)

transition :: Owner.ObjectiveHost -> MandateId -> StateRevision "mandate" -> OperationId -> Aeson.Value -> (Objective -> Mandate -> Transaction Mandate) -> Eff AppEffects (Either ObjectiveError Mandate)
transition host key expected operation semantic action = change host False key expected operation semantic action

serviceTransition :: Owner.ObjectiveHost -> MandateId -> StateRevision "mandate" -> OperationId -> Aeson.Value -> (Objective -> Mandate -> Transaction Mandate) -> Eff AppEffects (Either ObjectiveError Mandate)
serviceTransition host key expected operation semantic action = change host True key expected operation semantic action

change :: Owner.ObjectiveHost -> Bool -> MandateId -> StateRevision "mandate" -> OperationId -> Aeson.Value -> (Objective -> Mandate -> Transaction Mandate) -> Eff AppEffects (Either ObjectiveError Mandate)
change host service identifier expected operation semantic action = guarded do
  access <- permit host "mandate-command" (toJSON (identifier, expected, operation, semantic))
  objective <- locate identifier >>= either (throwIO . Failure) pure
  mutate access service objective identifier operation semantic (Just expected) (\_ _ -> pure ()) \goal previous -> do
    state <- maybe (abort ObjectiveMissing) pure previous
    unless (isNothing state.stopReason) (abort ObjectiveConflict)
    action goal state

-- A receipt is bound to actor, full command and expected version. Receipt
-- recovery precedes current-version checks, after current authorization.
mutate :: Access -> Bool -> ObjectiveId -> MandateId -> OperationId -> Aeson.Value -> Maybe (StateRevision "mandate") -> (Objective -> Mandate -> Transaction ()) -> (Objective -> Maybe Mandate -> Transaction Mandate) -> Eff AppEffects (Either ObjectiveError Mandate)
mutate access service objective identifier operation semantic expected extra action = do
  let fingerprint = versionedDigest "shikigami.mandate-command/1" (toJSON (access.actor, objective, identifier, operation, semantic, expected))
      checked goal = do
        if service
          then checkService access
          else do
            unless (access.settings.enabled == ObjectivesEnabled) (abort ObjectiveDenied)
            Goals.checkAccessTx access goal >>= require
            unless (Goals.mayCoordinate access goal) (abort ObjectiveDenied)
        previous <- loadTx identifier
        forM_ previous \state -> unless (state.admission.objectiveId == objective) (abort ObjectiveUnavailable)
        receipt <- Tx.statement (identifier.value, operationIdText operation) (preparable "SELECT fingerprint,outcome FROM shikigami.mandate_receipts WHERE mandate_id=$1 AND operation_key=$2" (contrazip2 text text) (D.rowMaybe ((,) <$> D.column (D.nonNullable D.text) <*> column)))
        case receipt of
          Just (stored, raw) | stored == fingerprint -> do
            original <- decode raw
            require (validateSnapshot original)
            unless (original.admission.mandateId == identifier && original.admission.objectiveId == objective) (abort ObjectiveUnavailable)
            pure (Left original)
          Just _ -> abort ObjectiveConflict
          Nothing -> do
            unless (fmap (.revision) previous == expected) (abort ObjectiveConflict)
            proposed <- action goal previous
            pure (Right (previous, proposed))
      preview = do
        goal <- Goals.lockedEither objective >>= require
        checked goal
  observed <- protected preview
  case observed of
    Left err -> pure (Left err)
    Right (Left original) -> pure (Right original)
    Right (Right (previous, proposed)) -> do
      notify <- maybe (pure (pure ())) CheckpointWake.prepareListener (previous >>= (.wake))
      input <- prepareAdmittedInput Native.workflowName (mandateWorkflowId identifier) (StepName "ingest-mandate") (Aeson.object ["mandateId" .= identifier])
      let nextRevision = maybe initialRevision advanceRevision expected
          next = proposed & #revision .~ nextRevision
          command = case expected of
            Nothing -> G.AdmitMandate (G.AdmitMandateData identifier.value)
            Just prior | isJust next.stopReason -> G.StopMandate (G.StopMandateData identifier.value (fromInteger (revisionNumber prior)) (fromInteger (revisionNumber nextRevision)))
            Just prior -> G.AdvanceMandate (G.AdvanceMandateData identifier.value (fromInteger (revisionNumber prior)) (fromInteger (revisionNumber nextRevision)))
          commit = do
            goal <- Goals.lockedEither objective >>= require
            fresh <- checked goal
            (_, actual) <- either (const (abort ObjectiveConflict)) pure fresh
            unless (actual == proposed) (abort ObjectiveConflict)
            Tx.statement (identifier.value, objectiveIdText objective, next) (preparable "INSERT INTO shikigami.mandates(mandate_id,objective_id,state) VALUES ($1,$2,$3) ON CONFLICT (mandate_id) DO UPDATE SET state=EXCLUDED.state" (contrazip3 text text json) D.noResult)
            Tx.statement (identifier.value, operationIdText operation, Aeson.object ["fingerprint" .= fingerprint, "outcome" .= next]) (preparable "INSERT INTO shikigami.mandate_receipts(mandate_id,operation_key,fingerprint,outcome) VALUES ($1,$2,$3->>'fingerprint',$3->'outcome')" (contrazip3 text text json) D.noResult)
            forM_ next.lastCycle (saveCycleTx identifier)
            when (isNothing expected) (void input)
            forM_ (previous >>= (.wake)) \listener -> do
              void (cancelTimerTx (Wake.timerIdFor identifier listener))
              notify
              when (isJust next.stopReason) (CheckpointWake.unregisterTx listener)
            extra goal next
          (catalog, projections) = withLiveMandate (\_ _ -> commit)
      options <- commandOptions
      result <- runCommandWithCatalogProjections options mandateLifecycleEventStream (Stream.entityStream mandateLifecycleCategory identifier.value) command catalog projections
      pure case result of
        Right (ProjectionCommandApplied _) -> Right next
        Left CommandRejected -> Left ObjectiveConflict
        _ -> Left ObjectiveUnavailable

protected :: (ToJSON a, FromJSON a) => Transaction a -> Eff AppEffects (Either ObjectiveError a)
protected action = guarded do
  result <- runQuery Nothing mandateLookupReadModel (toJSON <$> action)
  pure case result of
    Left _ -> Left ObjectiveUnavailable
    Right raw -> case Aeson.fromJSON raw of Aeson.Success value -> Right value; _ -> Left ObjectiveUnavailable

saveCycleTx :: MandateId -> Cycle -> Transaction ()
saveCycleTx identifier cycle = do
  retained <- Tx.statement (identifier.value, Text.pack (show cycle.number), cycle) (preparable "INSERT INTO shikigami.mandate_cycles(mandate_id,cycle,state) VALUES ($1,$2::bigint,$3) ON CONFLICT (mandate_id,cycle) DO UPDATE SET state=EXCLUDED.state WHERE shikigami.mandate_cycles.state=$3 RETURNING state" (contrazip3 text text json) (D.rowMaybe column))
  unless (retained == Just (toJSON cycle)) (abort ObjectiveConflict)

-- Listener publication and timer installation share the mandate commit. The
-- desired due time was already retained by progress; replay repairs this step.
publishWake :: Owner.ObjectiveHost -> MandateId -> StateRevision "mandate" -> CheckpointWake.Listener -> Eff AppEffects (Either ObjectiveError Mandate)
publishWake host identifier expected listener = guarded do
  access <- permit host "mandate-publish-wake" (toJSON (identifier, expected, listener))
  checked <- CheckpointWake.validateListener listener
  either (throwIO . Failure) pure checked
  unless (listener.ownerName == Native.workflowName && listener.ownerId == mandateWorkflowId identifier) (throwIO (Failure ObjectiveDenied))
  notify <- CheckpointWake.prepareListener listener
  let operation = operationIdWithPrefix ('m' :| "andate-wake:") (versionedDigest "shikigami.mandate-wake/1" (toJSON listener))
      extra goal next = do
        require =<< CheckpointWake.registerTx listener goal.revision notify
        forM_ next.nextDue \due -> scheduleTimerOnceTx (Wake.request next listener due)
  mutate access True listener.objectiveId identifier operation (toJSON listener) (Just expected) extra \_ previous -> do
    state <- maybe (abort ObjectiveMissing) pure previous
    unless (state.admission.objectiveId == listener.objectiveId && isNothing state.stopReason) (abort ObjectiveConflict)
    pure (state & #wake .~ Just listener)
