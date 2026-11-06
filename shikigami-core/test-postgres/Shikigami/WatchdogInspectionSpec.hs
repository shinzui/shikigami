{-# LANGUAGE DataKinds #-}

module Shikigami.WatchdogInspectionSpec (tests) where

import Control.Lens ((&), (.~))
import Data.Generics.Labels ()
import Data.List.NonEmpty (NonEmpty (..))
import Data.Map.Strict qualified as Map
import Data.Time (addUTCTime)
import Effectful (Eff)
import Hasql.Transaction qualified as Tx
import Kiroku.Store.Transaction (runTransaction)
import Shikigami.Agent.Principal (AgentIdentity (..), mkAgentPrincipal)
import Shikigami.App (AppEffects, AppEnv, runAppIO)
import Shikigami.Duration (remainingDuration)
import Shikigami.Migrations.TestSupport (DatabaseFixture)
import Shikigami.Trigger.Schedule (parseCron)
import Shikigami.Watchdog.Grant
import Shikigami.Watchdog.Inspection
import Shikigami.Watchdog.Ledger
import Shikigami.Watchdog.Observation
import Shikigami.Watchdog.Store qualified as Store
import Shikigami.Watchdog.Types
import Shikigami.WatchdogStoreSpec qualified as Fixture
import Shikigami.WorkerSessionStoreSpec (withFixture)
import Test.Tasty (TestTree, testGroup)
import Test.Tasty.HUnit (assertBool, assertFailure, testCase, (@?=))

tests :: DatabaseFixture -> TestTree
tests fixture =
  testGroup
    "WatchdogInspection"
    [ testCase "empty ledger has unavailable coverage and no sampled age" $ withFixture fixture \env _ _ -> do
        identity <- principal
        view <- tx env (Store.inspectWatchdog identity AllObjectives)
        view.latestAttempt @?= Nothing
        view.lastCompletedSweep @?= Nothing
        view.coverage @?= Nothing
        view.openEpisodes @?= 0
        tx env (Store.readSweepAgeSeconds identity AllObjectives) >>= (@?= Nothing)
        cron <- right (parseCron "* * * * *")
        overdueVerdict cron (remainingDuration 0) view.inspectedAt view.lastCompletedSweep @?= NoSweepYet,
      testCase "new unfinished attempt never hides the last completed sweep" $ Fixture.withSeed fixture \env grant _ _ -> do
        identity <- principal
        first <- tx env (Store.readLastCompletedSweep identity grant.scope) >>= maybe (assertFailure "no completed seed") pure
        pending <- Fixture.open env grant "unfinished-inspection"
        view <- tx env (Store.inspectWatchdog identity grant.scope)
        fmap (.sweepId) view.latestAttempt @?= Just pending
        fmap (.completedAt) view.latestAttempt @?= Just Nothing
        view.lastCompletedSweep @?= Just first
        assertBool "coverage is retained and has no complete pass yet" (case view.coverage of Just coverage -> coverage.lastPassCompletedAt == Nothing; _ -> False)
        cron <- right (parseCron "* * * * *")
        at <- maybe (assertFailure "seed completion absent") pure first.completedAt
        overdueVerdict cron (remainingDuration 0) at view.lastCompletedSweep @?= SweepFresh
        assertBool "missed next tick is overdue" (case overdueVerdict cron (remainingDuration 0) (addUTCTime 120 at) view.lastCompletedSweep of SweepOverdue {} -> True; _ -> False)
        age <- tx env (Store.readSweepAgeSeconds identity grant.scope)
        assertBool "age comes from the DB clock and is nonnegative" (maybe False (>= 0) age),
      testCase "another principal or another configured scope sees no retained completion" $ Fixture.withSeed fixture \env grant subject _ -> do
        other <- VerifiedIdentity <$> right (mkAgentPrincipal "agent_other_watchdog")
        view <- tx env (Store.inspectWatchdog other grant.scope)
        view.lastCompletedSweep @?= Nothing
        view.latestAttempt @?= Nothing
        view.coverage @?= Nothing
        view.openEpisodes @?= 0
        tx env (Store.listEpisodes other grant.scope (EpisodeFilter False Nothing) Nothing 10) >>= (@?= [])
        identity <- principal
        case subject.objective of
          Just objective -> tx env (Store.readLastCompletedSweep identity (SelectedObjectives (objective :| []))) >>= (@?= Nothing)
          Nothing -> assertFailure "fixture objective absent",
      testCase "incomplete population coverage is visible and cannot become empty completion" $ Fixture.withSeed fixture \env grant _ at -> do
        identity <- principal
        sweep <- Fixture.open env grant "incomplete-inspection"
        let cursor = initialCursor & #scope .~ Just grant.scope & #passClean .~ False
        _ <- tx env (Store.writeCoverage sweep at cursor PassIncomplete)
        view <- tx env (Store.inspectWatchdog identity grant.scope)
        case view.coverage of
          Just coverage -> do coverage.cursor.passClean @?= False; coverage.lastPassCompletedAt @?= Nothing
          Nothing -> assertFailure "incomplete coverage disappeared",
      testCase "episodes and findings page by checked ids and hold configured ownership" $ Fixture.withSeed fixture \env grant subject at -> do
        identity <- principal
        sweep <- Fixture.open env grant "inspection-finding"
        observed <- Fixture.observation env subject (addUTCTime 120 at)
        pool <- Store.newIdentityPool [subject.subject]
        _ <- tx env (Store.recordSweepPage sweep Liveness (addUTCTime 120 at) pool [observed])
        Fixture.close env sweep (addUTCTime 120 at)
        [episode] <- tx env (Store.listEpisodes identity grant.scope (EpisodeFilter True subject.objective) Nothing 1)
        [finding] <- tx env (Store.listFindings identity grant.scope episode.episodeId Nothing 1)
        finding.subject @?= subject.subject
        tx env (Store.listEpisodes identity grant.scope (EpisodeFilter True Nothing) (Just episode.episodeId) 1) >>= (@?= [])
        tx env (Store.listFindings identity grant.scope episode.episodeId (Just finding.findingId) 1) >>= (@?= [])
        other <- VerifiedIdentity <$> right (mkAgentPrincipal "agent_other_watchdog")
        tx env (Store.listFindings other grant.scope episode.episodeId Nothing 100) >>= (@?= [])
        run env (runTransaction (Store.listEpisodes identity grant.scope (EpisodeFilter False Nothing) Nothing 0)) >>= (@?= Left LedgerBounds)
        run env (runTransaction (Store.listFindings identity grant.scope episode.episodeId Nothing 101)) >>= (@?= Left LedgerBounds),
      testCase "corrupt completed sweep refuses inspection rather than reporting no sweep" $ Fixture.withSeed fixture \env grant _ _ -> do
        identity <- principal
        run env (runTransaction (Tx.sql "UPDATE shikigami.watchdog_sweeps SET summary='{}'::jsonb WHERE completed_at IS NOT NULL"))
        run env (runTransaction (Store.inspectWatchdog identity grant.scope)) >>= (@?= Left LedgerCorrupt)
    ]

principal :: IO AgentIdentity
principal = VerifiedIdentity <$> right (mkAgentPrincipal "agent_watchdog")

tx :: AppEnv -> Tx.Transaction (Either WatchdogError a) -> IO a
tx env action = right =<< run env (runTransaction action)

run :: AppEnv -> Eff AppEffects a -> IO a
run env action = right =<< runAppIO env action

right :: (Show e) => Either e a -> IO a
right = either (assertFailure . show) pure
