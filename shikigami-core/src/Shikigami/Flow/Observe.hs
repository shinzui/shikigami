{-# LANGUAGE DataKinds #-}
{-# LANGUAGE TypeFamilies #-}

-- | Journaled read authority and advisory ledger writes. No owner commands.
module Shikigami.Flow.Observe
  ( Observe,
    ObserveSeed (..),
    ObserveRuntime (..),
    ObserveHooks (..),
    noObserveHooks,
    disabledObserve,
    observeAvailable,
    Granted (..),
    SweepOpened (..),
    ObservedPage (..),
    resolveGrant,
    openSweep,
    observeActive,
    recordPage,
    recordDrift,
    closeSweep,
    runObserve,
    unavailableObserve,
  )
where

import Data.Aeson (FromJSON (..), ToJSON (..), object, withObject, (.:), (.=))
import Data.Either (rights)
import Data.List (nub)
import Data.List.NonEmpty (NonEmpty)
import Data.List.NonEmpty qualified as NonEmpty
import Data.Map.Strict (Map)
import Data.Map.Strict qualified as Map
import Data.Time (UTCTime)
import Effectful (Dispatch (Dynamic), DispatchOf, Eff, Effect, IOE, liftIO, (:>))
import Effectful.Dispatch.Dynamic (interpret, send)
import Effectful.Error.Static (Error)
import GHC.Generics (Generic)
import Hasql.Transaction qualified as Tx
import Keiro.Workflow (StepName (..), Workflow, step)
import Kiroku.Store.Effect (Store)
import Kiroku.Store.Error (StoreError)
import Kiroku.Store.Transaction (runTransactionNoRetry)
import Shikigami.Agent.Principal (AgentIdentity)
import Shikigami.Objective.Observation qualified as Objective
import Shikigami.Watchdog.Classify (Observed (..), PriorMark)
import Shikigami.Watchdog.Drift qualified as Drift
import Shikigami.Watchdog.Grant
import Shikigami.Watchdog.Observation
import Shikigami.Watchdog.Store qualified as Ledger
import Shikigami.Watchdog.Types

data ObserveHooks = ObserveHooks
  { onSweepCompleted :: !(SweepId -> Ledger.SweepSummary -> IO ()),
    onFinding :: !(FindingView -> IO ()),
    onRefusal :: !(IO ())
  }

noObserveHooks :: ObserveHooks
noObserveHooks = ObserveHooks (\_ _ -> pure ()) (\_ -> pure ()) (pure ())

data ObserveSeed
  = ObserveSeed {settings :: !(Maybe WatchdogSettings), hooks :: !ObserveHooks}
  | UnavailableObserve {settings :: !(Maybe WatchdogSettings), hooks :: !ObserveHooks}

observeAvailable :: ObserveSeed -> Bool
observeAvailable ObserveSeed {} = True
observeAvailable UnavailableObserve {} = False

disabledObserve :: ObserveSeed
disabledObserve = UnavailableObserve Nothing noObserveHooks

data ObserveRuntime = ObserveRuntime {seed :: !ObserveSeed, identity :: !AgentIdentity, origin :: !Ledger.SweepOrigin, driftEnabled :: !Bool}

data Granted = Granted {grant :: !GrantSnapshot, delivery :: !(Maybe DeliveryPolicy), driftEnabled :: !Bool}
  deriving stock (Eq, Show, Generic)
  deriving anyclass (ToJSON, FromJSON)

data SweepOpened = SweepOpened {sweepId :: !SweepId, cursor :: !CoverageCursor, openedAt :: !UTCTime}
  deriving stock (Eq, Show, Generic)
  deriving anyclass (ToJSON, FromJSON)

data ObservedPage = ObservedPage
  { page :: !ObservationPage,
    priors :: !(Map SubjectKey PriorMark),
    checks :: !(Map SubjectKey Drift.DriftCheck),
    objectives :: ![Objective.ObjectiveObservation]
  }
  deriving stock (Eq, Show, Generic)

instance ToJSON ObservedPage where
  toJSON value = object ["page" .= value.page, "priors" .= Map.toList value.priors, "checks" .= Map.toList value.checks, "objectives" .= value.objectives]

instance FromJSON ObservedPage where
  parseJSON = withObject "ObservedPage" \fields -> ObservedPage <$> fields .: "page" <*> (Map.fromList <$> fields .: "priors") <*> (Map.fromList <$> fields .: "checks") <*> fields .: "objectives"

data Observe :: Effect where
  ResolveGrant :: Observe m (Either GrantRefusal Granted)
  OpenSweep :: Granted -> Observe m (Either Ledger.WatchdogError SweepOpened)
  ObserveActive :: Granted -> CoverageCursor -> Observe m (Either ObservationError ObservedPage)
  RecordPage :: SweepId -> ObservedPage -> [Observed] -> Observe m (Either Ledger.WatchdogError Ledger.PageOutcomeView)
  RecordDrift :: SweepId -> UTCTime -> [Observed] -> NonEmpty Drift.DriftCheck -> Observe m (Either Ledger.WatchdogError Ledger.PageOutcomeView)
  CloseSweep :: SweepId -> Ledger.SweepSummary -> Observe m (Either Ledger.WatchdogError UTCTime)

type instance DispatchOf Observe = Dynamic

resolveGrant :: (Observe :> es) => Eff es (Either GrantRefusal Granted)
resolveGrant = send ResolveGrant

openSweep :: (Observe :> es) => Granted -> Eff es (Either Ledger.WatchdogError SweepOpened)
openSweep = send . OpenSweep

observeActive :: (Observe :> es) => Granted -> CoverageCursor -> Eff es (Either ObservationError ObservedPage)
observeActive grant = send . ObserveActive grant

recordPage :: (Observe :> es) => SweepId -> ObservedPage -> [Observed] -> Eff es (Either Ledger.WatchdogError Ledger.PageOutcomeView)
recordPage sweep page = send . RecordPage sweep page

recordDrift :: (Observe :> es) => SweepId -> UTCTime -> [Observed] -> NonEmpty Drift.DriftCheck -> Eff es (Either Ledger.WatchdogError Ledger.PageOutcomeView)
recordDrift sweep at outcomes = send . RecordDrift sweep at outcomes

closeSweep :: (Observe :> es) => SweepId -> Ledger.SweepSummary -> Eff es (Either Ledger.WatchdogError UTCTime)
closeSweep sweep = send . CloseSweep sweep

runObserve :: (Workflow :> es, Store :> es, Error StoreError :> es, IOE :> es) => ObserveRuntime -> Eff (Observe : es) a -> Eff es a
runObserve runtime = selectObserve runtime.seed $ interpret \_ -> \case
  ResolveGrant -> step (StepName "watchdog-grant") do
    let result = (\grant -> Granted (snapshotGrant grant) (runtime.seed.settings >>= (.delivery)) runtime.driftEnabled) <$> resolveObservationGrant runtime.seed.settings runtime.identity
    case result of Left _ -> liftIO runtime.seed.hooks.onRefusal; Right _ -> pure ()
    pure result
  OpenSweep granted -> step (StepName "watchdog-open") do
    proposed <- liftIO newSweepId
    case restoreGrant granted.grant runtime.identity runtime.seed.settings of
      Left _ -> pure (Left Ledger.LedgerBindingConflict)
      Right _ -> runTransactionNoRetry do
        Ledger.openSweep proposed runtime.origin granted.grant >>= \case
          Left problem -> pure (Left problem)
          Right sweep ->
            Ledger.readCoverage runtime.identity granted.grant.scope >>= \case
              Left problem -> pure (Left problem)
              Right coverage ->
                Ledger.readSweep sweep >>= \case
                  Right (Just saved) -> pure (Right (SweepOpened sweep (maybe initialCursor (.cursor) coverage) saved.openedAt))
                  _ -> pure (Left Ledger.LedgerCorrupt)
  ObserveActive granted cursor -> step (StepName "watchdog-observe") do
    case restoreGrant granted.grant runtime.identity runtime.seed.settings of
      Left _ -> pure (Left ObservationUnavailable)
      Right grant ->
        observePage grant defaultObservationBounds cursor >>= \case
          Left problem -> pure (Left problem)
          Right page -> case NonEmpty.nonEmpty (map (subjectKey . (.subject)) page.subjects) of
            Nothing -> pure (Right (ObservedPage page Map.empty Map.empty []))
            Just keys -> runTransactionNoRetry do
              Tx.sql "SET TRANSACTION READ ONLY"
              Tx.sql "SET LOCAL statement_timeout='2000ms'"
              priors <- Ledger.readPriorMarks keys
              checks <- Drift.readDriftChecks keys
              objectives <- case NonEmpty.nonEmpty (nub [objective | subject <- page.subjects, Just objective <- [subject.objective]]) of
                Nothing -> pure (Right [])
                Just ids -> Objective.observeObjectivesFor ids
              pure case (priors, checks, objectives) of
                (Right previous, Right retained, Right owners) -> Right (ObservedPage page previous retained (rights (map snd owners)))
                _ -> Left ObservationUnavailable
  RecordPage sweep observed outcomes -> step (StepName "watchdog-record") do
    pool <- liftIO (Ledger.newIdentityPool (map (.subject) outcomes))
    result <-
      runTransactionNoRetry
        ( ownedSweep runtime sweep do
            Ledger.recordSweepPage sweep Liveness observed.page.observedAt pool outcomes >>= \case
              Left problem -> pure (Left problem)
              Right outcome ->
                Ledger.writeCoverage sweep observed.page.observedAt observed.page.cursor observed.page.passCompleted >>= \case
                  Left problem -> pure (Left problem)
                  Right _ ->
                    if observed.page.passCompleted == PassCompleted
                      then fmap (fmap (const (Ledger.pageOutcomeView outcome))) (Ledger.completePass sweep observed.page)
                      else pure (Right (Ledger.pageOutcomeView outcome))
        )
    report result
  RecordDrift sweep at outcomes checks -> step (StepName "watchdog-drift-record") do
    pool <- liftIO (Ledger.newIdentityPool (map (.subject) outcomes))
    result <-
      runTransactionNoRetry
        ( ownedSweep runtime sweep do
            Ledger.recordSweepPage sweep DriftAssessmentFamily at pool outcomes >>= \case
              Left problem -> pure (Left problem)
              Right outcome ->
                Drift.recordDriftChecks sweep at checks >>= \case
                  Left _ -> Tx.condemn >> pure (Left Ledger.LedgerBindingConflict)
                  Right () -> pure (Right (Ledger.pageOutcomeView outcome))
        )
    report result
  CloseSweep sweep summary -> step (StepName "watchdog-close") do
    result <- runTransactionNoRetry (ownedSweep runtime sweep (Ledger.closeSweep sweep summary))
    case result of Right _ -> liftIO (runtime.seed.hooks.onSweepCompleted sweep summary); Left _ -> liftIO runtime.seed.hooks.onRefusal
    pure result
  where
    report result = do
      liftIO case result of Right outcome -> mapM_ runtime.seed.hooks.onFinding outcome.notices; Left _ -> runtime.seed.hooks.onRefusal
      pure result

selectObserve :: ObserveSeed -> (Eff (Observe : es) a -> Eff es a) -> Eff (Observe : es) a -> Eff es a
selectObserve seed interpreter
  | observeAvailable seed = interpreter
  | otherwise = unavailableObserve

-- The effect can write only its own admitted native sweep, even if another
-- compiled Flow passes a decoded id or a fabricated read view.
ownedSweep :: ObserveRuntime -> SweepId -> Tx.Transaction (Either Ledger.WatchdogError a) -> Tx.Transaction (Either Ledger.WatchdogError a)
ownedSweep runtime sweep action = case resolveObservationGrant runtime.seed.settings runtime.identity of
  Left _ -> Tx.condemn >> pure (Left Ledger.LedgerBindingConflict)
  Right _ ->
    Ledger.readSweep sweep >>= \case
      Right (Just saved) | saved.origin == runtime.origin -> action
      _ -> Tx.condemn >> pure (Left Ledger.LedgerBindingConflict)

-- No application journal labels in historical or one-off runs.
unavailableObserve :: Eff (Observe : es) a -> Eff es a
unavailableObserve = interpret \_ -> \case
  ResolveGrant -> pure (Left WatchdogDisabled)
  OpenSweep _ -> pure (Left Ledger.LedgerBindingConflict)
  ObserveActive _ _ -> pure (Left ObservationUnavailable)
  RecordPage _ _ _ -> pure (Left Ledger.LedgerBindingConflict)
  RecordDrift _ _ _ _ -> pure (Left Ledger.LedgerBindingConflict)
  CloseSweep _ _ -> pure (Left Ledger.LedgerBindingConflict)
