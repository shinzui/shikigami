{-# LANGUAGE DataKinds #-}

-- | The sweep's interpreter, its pack flow and its gauge. A sweep can write
-- only the ledger rows of the native run it was admitted as.
module FlowPack.Watchdog.Runtime (ObserveRuntime (..), runObserve, watchdogSweepFlow, sweepAgeGauge) where

import Control.Monad (replicateM_)
import Data.Either (rights)
import Data.List (nub)
import Data.List.NonEmpty qualified as NonEmpty
import Data.Map.Strict qualified as Map
import Data.Maybe (isJust, mapMaybe)
import Effectful (Dispatch (Dynamic), DispatchOf, Eff, Effect, IOE, liftIO, (:>))
import Effectful.Dispatch.Dynamic (interpret, send)
import Effectful.Error.Static (Error)
import Effectful.Exception (onException, throwIO, try)
import FlowPack.Watchdog.Body.Sweep
import FlowPack.Watchdog.Capability
import FlowPack.Watchdog.Classify
import FlowPack.Watchdog.Drift.Store qualified as DriftStore
import FlowPack.Watchdog.Grant
import FlowPack.Watchdog.Ledger (PageOutcomeView (..), SweepOrigin (..), SweepSummary (..))
import FlowPack.Watchdog.Observation
import FlowPack.Watchdog.Observation.Read (observePage)
import FlowPack.Watchdog.Setting (watchdogSettingsFrom)
import FlowPack.Watchdog.Store (readSweepAgeSeconds)
import FlowPack.Watchdog.Store qualified as Ledger
import FlowPack.Watchdog.Types
import Hasql.Transaction qualified as Tx
import Keiro.Workflow (StepName (..), Workflow, step)
import Kiroku.Store.Effect (Store)
import Kiroku.Store.Error (StoreError)
import Kiroku.Store.Transaction (runTransactionNoRetry)
import Shikigami.Agent.Decl (AgentDecl (..))
import Shikigami.Agent.Principal (AgentIdentity)
import Shikigami.Flow.Sdk (DecisionMode (..), DefaultModelRequirement (..), FlowDef (..), LifecycleDiagram (..), PackFlow (..), StepName (..), Workflow, step)
import Shikigami.Objective.Observation qualified as Objective
import Shikigami.Pack.Sdk (FlowRunContext (..), PackGauge (..), PackMetrics (..))

-- | The sweep as a pack flow: the body over the pack's own @Observe@
-- interpreter, which the kernel never names. A drift assessment is advisory
-- and is made only by a declaration that lists the @drift@ alias, on a run
-- that carries an enrolled root to charge it to.
--
-- A sweep that dies is counted before the failure reaches the workflow
-- driver, so a watchdog that cannot finish is visible without a finding.
watchdogSweepFlow :: PackFlow
watchdogSweepFlow =
  PackFlow
    { definition =
        FlowDef
          { name = watchdogFlowName,
            decisionSlots = watchdogSlots,
            requiresDefaultModel = DefaultModelOptional,
            decisionMode = AdvisoryDecisions,
            lifecycle = LifecycleDiagram "flowchart LR\n Grant --> Observe --> Classify --> Record --> Drift --> Deliver --> Close" []
          },
      run = \context payload ->
        runObserve
          ObserveRuntime
            { settings = watchdogSettingsFrom context.settings,
              metrics = context.metrics,
              identity = context.requestIdentity,
              origin = SweepOrigin context.workflowName context.runId context.occurredAt context.requestIdentity,
              driftEnabled = driftAlias `elem` context.agent.decisionModels && isJust context.executionRoot
            }
          (watchdogSweep payload)
          `onException` liftIO (context.metrics.count "sweep" [("outcome", "failed")])
    }

-- | Database-clock age, in seconds, of the last completed scoped sweep. It is
-- absent until one completes and when the watchdog is not configured, so an
-- alert on it fires when sweeps stop and not merely because none was asked for.
sweepAgeGauge :: PackGauge
sweepAgeGauge =
  PackGauge
    { name = "sweep.age",
      sample = \settings -> case watchdogSettingsFrom settings of
        Nothing -> pure (Right Nothing)
        Just configured -> either (const (Left "watchdog ledger unavailable")) Right <$> runTransactionNoRetry (readSweepAgeSeconds configured.principal configured.scope)
    }

-- | What one sweep's interpreter is given. The policy is the operator's
-- setting, absent when the watchdog is not configured; every event the sweep
-- counts goes to the pack's counter with bounded attributes.
data ObserveRuntime = ObserveRuntime {settings :: !(Maybe WatchdogSettings), metrics :: !PackMetrics, identity :: !AgentIdentity, origin :: !Ledger.SweepOrigin, driftEnabled :: !Bool}

runObserve :: (Workflow :> es, Store :> es, Error StoreError :> es, IOE :> es) => ObserveRuntime -> Eff (Observe : es) a -> Eff es a
runObserve runtime = interpret \_ -> \case
  ResolveGrant -> step (StepName "watchdog-grant") do
    let result = (\grant -> Granted (snapshotGrant grant) (runtime.settings >>= (.delivery)) runtime.driftEnabled) <$> resolveObservationGrant runtime.settings runtime.identity
    case result of Left _ -> liftIO uncompleted; Right _ -> pure ()
    pure result
  OpenSweep granted -> step (StepName "watchdog-open") do
    proposed <- liftIO newSweepId
    result <- case restoreGrant granted.grant runtime.identity runtime.settings of
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
    case result of Left _ -> liftIO uncompleted; Right _ -> pure ()
    pure result
  ObserveActive granted cursor -> step (StepName "watchdog-observe") do
    case restoreGrant granted.grant runtime.identity runtime.settings of
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
              checks <- DriftStore.readDriftChecks keys
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
                DriftStore.recordDriftChecks sweep at checks >>= \case
                  Left _ -> Tx.condemn >> pure (Left Ledger.LedgerBindingConflict)
                  Right () -> pure (Right (Ledger.pageOutcomeView outcome))
        )
    report result
  CloseSweep sweep summary -> step (StepName "watchdog-close") do
    result <- runTransactionNoRetry (ownedSweep runtime sweep (Ledger.closeSweep sweep summary))
    case result of Right _ -> liftIO (completed summary); Left _ -> liftIO uncompleted
    pure result
  where
    report result = do
      liftIO case result of Right outcome -> mapM_ found outcome.notices; Left _ -> pure ()
      pure result
    -- A journaled step replays its result and not its body, so a resumed run
    -- counts nothing twice; a step that crashes after its transaction may.
    count = runtime.metrics.count
    uncompleted = count "sweep" [("outcome", "refused")] >> count "refusal" [("refusal.kind", "uncompleted")]
    completed summary
      | summary.refusals == 0 = count "sweep" [("outcome", "completed")]
      | otherwise = count "sweep" [("outcome", "refused")] >> replicateM_ (fromIntegral summary.refusals) (count "refusal" [("refusal.kind", "retained")])
    found finding = count "finding" [("detection.kind", case finding.kind of StuckWork -> "stuck"; UnresolvedOutcome -> "unresolved"; StuckCoordinatorWork -> "stuck-coordinator"; DriftWork -> "drift")]

-- The effect can write only its own admitted native sweep, even if another
-- compiled Flow passes a decoded id or a fabricated read view.
ownedSweep :: ObserveRuntime -> SweepId -> Tx.Transaction (Either Ledger.WatchdogError a) -> Tx.Transaction (Either Ledger.WatchdogError a)
ownedSweep runtime sweep action = case resolveObservationGrant runtime.settings runtime.identity of
  Left _ -> Tx.condemn >> pure (Left Ledger.LedgerBindingConflict)
  Right _ ->
    Ledger.readSweep sweep >>= \case
      Right (Just saved) | saved.origin == runtime.origin -> action
      _ -> Tx.condemn >> pure (Left Ledger.LedgerBindingConflict)
