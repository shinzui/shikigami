{-# LANGUAGE DataKinds #-}

module Shikigami.WatchdogStoreSpec (tests, withSeed, open, close, observation, transaction) where

import Control.Concurrent.Async (concurrently)
import Control.Lens ((&), (.~))
import Data.Aeson (eitherDecode)
import Data.Generics.Labels ()
import Data.Int (Int64)
import Data.List.NonEmpty (NonEmpty (..))
import Data.List.NonEmpty qualified as NonEmpty
import Data.Map.Strict qualified as Map
import Data.Text qualified as Text
import Data.Time (UTCTime, addUTCTime)
import Effectful (Eff)
import Hasql.Decoders qualified as D
import Hasql.Encoders qualified as E
import Hasql.Statement (preparable)
import Hasql.Transaction (Transaction)
import Hasql.Transaction qualified as Tx
import Keiro.Workflow.Types (WorkflowId (..), WorkflowName (..))
import Kiroku.Store.Transaction (runTransaction)
import Shikigami.Agent.Principal (AgentIdentity (..), mkAgentPrincipal)
import Shikigami.App (AppEffects, AppEnv (..), runAppIO)
import Shikigami.Duration (remainingDuration)
import Shikigami.Migrations.TestSupport (DatabaseFixture)
import Shikigami.StateRevision (advanceRevision, initialRevision)
import Shikigami.Watchdog.Classify
import Shikigami.Watchdog.Episode (findingView)
import Shikigami.Watchdog.Grant
import Shikigami.Watchdog.Observation
import Shikigami.Watchdog.Store qualified as Store
import Shikigami.Watchdog.Types
import Shikigami.WatchdogClassifySpec qualified as Fixture
import Shikigami.WatchdogObservationSpec (fixtureGrant, start)
import Shikigami.WorkerSession.Types (sessionIdFor)
import Shikigami.WorkerSessionStoreSpec (withFixture)
import Test.Tasty (TestTree, testGroup)
import Test.Tasty.HUnit (assertBool, assertFailure, testCase, (@?=))

tests :: DatabaseFixture -> TestTree
tests fixture =
  testGroup
    "WatchdogStore"
    [ testCase "origin replay retains identity and claim; changed binding refuses" $
        withFixture fixture \env _ _ -> do
          grant <- grantSnapshot
          origin <- originFor "first"
          Store.readCoverage origin.principal grant.scope `transaction` env >>= (@?= Nothing)
          first <- newSweepId
          replay <- newSweepId
          transaction (Store.openSweep first origin grant) env >>= (@?= first)
          transaction (Store.openSweep replay origin grant) env >>= (@?= first)
          changed <- run env (runTransaction (Store.openSweep replay origin (grant & #windows .~ (grant.windows & #stuck .~ remainingDuration 61))))
          changed @?= Left Store.LedgerBindingConflict
          run env (runTransaction (Store.openSweep replay (origin & #dueAt .~ addUTCTime 1 origin.dueAt) grant)) >>= (@?= Left Store.LedgerBindingConflict)
          newer <- originFor "second"
          run env (runTransaction (Store.openSweep replay newer grant)) >>= (@?= Left (Store.SweepClaimHeld first))
          before <- transaction (Store.readSweep first) env
          completed <- transaction (Store.closeSweep first (summary Fixture.instant 0 0)) env
          transaction (Store.closeSweep first (summary Fixture.instant 0 0)) env >>= (@?= completed)
          transaction (Store.openSweep replay newer grant) env >>= (@?= replay)
          transaction (Store.closeSweep first (summary Fixture.instant 0 0)) env >>= (@?= completed)
          third <- newSweepId
          thirdOrigin <- originFor "third"
          run env (runTransaction (Store.openSweep third thirdOrigin grant)) >>= (@?= Left (Store.SweepClaimHeld replay))
          case before of Just view -> assertBool "completion is a fresh retained database time" (completed >= view.openedAt); _ -> assertFailure "missing sweep",
      testCase "page retry after commit returns the original finding and counts" $
        withSeed fixture \env grant subject at -> do
          sweep <- open env grant "detected"
          observed <- observation env subject (addUTCTime 120 at)
          identities <- Store.newIdentityPool [subject.subject]
          outcome <- transaction (Store.recordSweepPage sweep Liveness (addUTCTime 120 at) identities [observed]) env
          length outcome.notices @?= 1
          outcome.opened @?= 1
          differentIds <- Store.newIdentityPool [subject.subject]
          replay <- transaction (Store.recordSweepPage sweep Liveness (addUTCTime 120 at) differentIds [observed]) env
          Store.pageOutcomeView replay @?= Store.pageOutcomeView outcome
          counts env >>= (@?= (1, 1, 1))
          run env (runTransaction (Store.recordSweepPage sweep Liveness (addUTCTime 121 at) identities [observed])) >>= (@?= Left Store.LedgerBindingConflict)
          close env sweep (addUTCTime 120 at)
          next <- open env grant "continued"
          again <- observation env subject (addUTCTime 240 at)
          nextIds <- Store.newIdentityPool [subject.subject]
          continued <- transaction (Store.recordSweepPage next Liveness (addUTCTime 240 at) nextIds [again]) env
          continued.notices @?= []
          continued.continued @?= 1
          counts env >>= (@?= (1, 1, 1)),
      testCase "material summaries produce another finding on the retained episode" $
        withSeed fixture \env grant subject at -> do
          first <- open env grant "first-detection"
          observed <- observation env subject (addUTCTime 120 at)
          pool <- Store.newIdentityPool [subject.subject]
          initial <- transaction (Store.recordSweepPage first Liveness (addUTCTime 120 at) pool [observed]) env
          close env first (addUTCTime 120 at)
          next <- open env grant "material-change"
          later <- observation env subject (addUTCTime 240 at)
          let changed =
                later
                  & #outcome .~ case later.outcome of
                    Detected detection -> Detected (detection & #summary . #ownerEpoch .~ Just (advanceRevision initialRevision))
                    other -> other
          nextPool <- Store.newIdentityPool [subject.subject]
          material <- transaction (Store.recordSweepPage next Liveness (addUTCTime 240 at) nextPool [changed]) env
          case (map findingView initial.notices, map findingView material.notices) of
            ([before], [after]) -> do
              before.episodeId @?= after.episodeId
              assertBool "fresh finding identity" (before.findingId /= after.findingId)
            other -> assertFailure (show other)
          counts env >>= (@?= (1, 2, 2))
          close env next (addUTCTime 240 at)
          lastSweep <- open env grant "lapsed-deadline"
          final <- observation env subject (addUTCTime 360 at)
          let lapsed =
                final
                  & #outcome .~ case final.outcome of
                    Detected detection -> Detected (detection & #summary . #ownerEpoch .~ Just (advanceRevision initialRevision) & #summary . #lapsed .~ [PermissionDeadline])
                    other -> other
          lastPool <- Store.newIdentityPool [subject.subject]
          lastNotice <- transaction (Store.recordSweepPage lastSweep Liveness (addUTCTime 360 at) lastPool [lapsed]) env
          length lastNotice.notices @?= 1
          counts env >>= (@?= (1, 3, 3)),
      testCase "progress closes only its detector family; unknown holds episodes" $
        withSeed fixture \env grant subject at -> do
          sweep <- open env grant "both-families"
          observed <- observation env subject (addUTCTime 120 at)
          pool <- Store.newIdentityPool [subject.subject]
          _ <- transaction (Store.recordSweepPage sweep Liveness (addUTCTime 120 at) pool [observed]) env
          let drift = adverseDrift (addUTCTime 120 at) observed
          driftPool <- Store.newIdentityPool [subject.subject]
          _ <- transaction (Store.recordSweepPage sweep DriftAssessmentFamily (addUTCTime 120 at) driftPool [drift]) env
          close env sweep (addUTCTime 120 at)
          unknownSweep <- open env grant "unknown"
          current <- observation env subject (addUTCTime 180 at)
          unknownPool <- Store.newIdentityPool [subject.subject]
          held <- transaction (Store.recordSweepPage unknownSweep Liveness (addUTCTime 180 at) unknownPool [current & #outcome .~ Clear ObservationUnknown]) env
          held.closed @?= 0
          close env unknownSweep (addUTCTime 180 at)
          clearSweep <- open env grant "progress"
          fresh <- observation env subject (addUTCTime 240 at)
          cleared <- transaction (Store.recordSweepPage clearSweep Liveness (addUTCTime 240 at) pool [fresh & #outcome .~ Clear Progressing]) env
          cleared.closed @?= 1
          reasons <- run env (runTransaction (Tx.statement () (preparable "SELECT closed_reason FROM shikigami.watchdog_episodes WHERE closed_at IS NOT NULL" E.noParams (D.rowList (D.column (D.nonNullable D.text))))))
          reasons @?= ["progressing"]
          noDuplicate <- transaction (Store.recordSweepPage clearSweep DriftAssessmentFamily (addUTCTime 240 at) pool [adverseDrift (addUTCTime 240 at) fresh]) env
          noDuplicate.notices @?= []
          counts env >>= (@?= (1, 2, 2)),
      testCase "short identity pool and stale frozen priors refuse without partial writes" $
        withSeed fixture \env grant subject at -> do
          sweep <- open env grant "refusals"
          observed <- observation env subject (addUTCTime 120 at)
          run env (runTransaction (Store.recordSweepPage sweep Liveness (addUTCTime 120 at) (Store.IdentityPool []) [observed])) >>= (@?= Left Store.IdentityPoolTooSmall)
          counts env >>= (@?= (0, 0, 0))
          pool <- Store.newIdentityPool [subject.subject]
          _ <- transaction (Store.recordSweepPage sweep Liveness (addUTCTime 120 at) pool [observed]) env
          close env sweep (addUTCTime 120 at)
          newer <- open env grant "stale-input"
          run env (runTransaction (Store.recordSweepPage newer Liveness (addUTCTime 60 at) pool [observed])) >>= (@?= Left Store.StaleObservation)
          counts env >>= (@?= (1, 1, 1)),
      testCase "two concurrent recorders recover one page receipt and one finding" $
        withSeed fixture \env grant subject at -> do
          sweep <- open env grant "concurrent"
          observed <- observation env subject (addUTCTime 120 at)
          one <- Store.newIdentityPool [subject.subject]
          two <- Store.newIdentityPool [subject.subject]
          (first, second) <-
            concurrently
              (transaction (Store.recordSweepPage sweep Liveness (addUTCTime 120 at) one [observed]) env)
              (transaction (Store.recordSweepPage sweep Liveness (addUTCTime 120 at) two [observed]) env)
          Store.pageOutcomeView first @?= Store.pageOutcomeView second
          counts env >>= (@?= (1, 1, 1)),
      testCase "real owner page feeds frozen marks and the episode ledger" $
        withFixture fixture \env _ access -> do
          start env access
          grant <- fixtureGrant
          sweep <- open env (snapshotGrant grant) "real-first"
          page <- transactionObservation env grant
          pool <- Store.newIdentityPool (map (.subject) page.subjects)
          first <- transaction (Store.recordSweepPage sweep Liveness page.observedAt pool (classifyPage (grantWindows grant) page Map.empty)) env
          first.notices @?= []
          close env sweep page.observedAt
          run env (runTransaction (Tx.sql "UPDATE shikigami.watchdog_marks SET first_seen_at=first_seen_at-interval '120 seconds',last_changed_at=last_changed_at-interval '120 seconds'"))
          laterSweep <- open env (snapshotGrant grant) "real-stuck"
          later <- transactionObservation env grant
          case NonEmpty.nonEmpty (map (subjectKey . (.subject)) later.subjects) of
            Nothing -> assertFailure "real population missing"
            Just keys -> do
              priors <- transaction (Store.readPriorMarks keys) env
              identities <- Store.newIdentityPool (map (.subject) later.subjects)
              detected <- transaction (Store.recordSweepPage laterSweep Liveness later.observedAt identities (classifyPage (grantWindows grant) later priors)) env
              length detected.notices @?= 1,
      testCase "incomplete passes never close; complete passes confirm deleted owners and replay" $
        withSeed fixture \env grant subject at -> do
          sweep <- open env grant "first-pass"
          observed <- observation env subject (addUTCTime 120 at)
          pool <- Store.newIdentityPool [subject.subject]
          _ <- transaction (Store.recordSweepPage sweep Liveness (addUTCTime 120 at) pool [observed]) env
          let firstPage = completedPage grant (addUTCTime 121 at) [subject]
          first <- transaction (Store.completePass sweep firstPage) env
          first.complete @?= True
          first.closedEpisodes @?= []
          close env sweep firstPage.observedAt
          next <- open env grant "second-pass"
          let completed = completedPage grant (addUTCTime 240 at) []
          run env (runTransaction (Store.completePass next (completed & #passCompleted .~ PassIncomplete))) >>= (@?= Left Store.IncompletePass)
          counts env >>= (@?= (1, 1, 1))
          confirmed <- transaction (Store.completePass next completed) env
          length confirmed.closedEpisodes @?= 1
          confirmed.complete @?= True
          transaction (Store.completePass next completed) env >>= (@?= confirmed)
          counts env >>= (@?= (0, 1, 1)),
      testCase "an unseen idle or corrupt owner remains unknown after direct recheck" $
        withFixture fixture \env admission _ -> do
          grant <- grantSnapshot
          (_, template, _) <- Fixture.fixtureSubjects
          let subject = template & #subject .~ WorkerSession (sessionIdFor admission)
          first <- open env grant "seed-existing"
          saved <- transaction (Store.readSweep first) env >>= maybe (assertFailure "missing") pure
          let at = addUTCTime 1 saved.openedAt
          pool <- Store.newIdentityPool [subject.subject]
          _ <- transaction (Store.recordSweepPage first Liveness at pool [classify Fixture.windows at Nothing subject]) env
          close env first at
          detectedSweep <- open env grant "existing-detection"
          observed <- observation env subject (addUTCTime 120 at)
          _ <- transaction (Store.recordSweepPage detectedSweep Liveness (addUTCTime 120 at) pool [observed]) env
          _ <- transaction (Store.completePass detectedSweep (completedPage grant (addUTCTime 121 at) [subject])) env
          close env detectedSweep (addUTCTime 121 at)
          unseenSweep <- open env grant "existing-unseen"
          let page = completedPage grant (addUTCTime 240 at) []
          unknown <- transaction (Store.completePass unseenSweep page) env
          unknown.complete @?= False
          unknown.unknownSubjects @?= [subjectKey subject.subject]
          counts env >>= (@?= (1, 1, 1))
          close env unseenSweep page.observedAt
          run env (runTransaction (Tx.sql "UPDATE shikigami.worker_sessions SET state=jsonb_set(state,'{format}','2'::jsonb)"))
          corruptSweep <- open env grant "existing-corrupt"
          corrupt <- transaction (Store.completePass corruptSweep (completedPage grant (addUTCTime 360 at) [])) env
          corrupt.complete @?= False
          counts env >>= (@?= (1, 1, 1)),
      testCase "coverage receipts cannot overwrite a later tick and scope changes start fresh" $
        withSeed fixture \env grant subject at -> do
          first <- open env grant "coverage-first"
          let cursor = initialCursor & #scope .~ Just grant.scope & #nextKind .~ Sessions
          original <- transaction (Store.writeCoverage first at cursor PassContinuing) env
          close env first at
          next <- open env grant "coverage-second"
          let advanced = cursor & #nextKind .~ Executions
          newer <- transaction (Store.writeCoverage next (addUTCTime 120 at) advanced PassContinuing) env
          transaction (Store.writeCoverage first at cursor PassContinuing) env >>= (@?= original)
          origin <- originFor "coverage-read"
          transaction (Store.readCoverage origin.principal grant.scope) env >>= (@?= Just newer)
          close env next (addUTCTime 120 at)
          case subject.objective of
            Nothing -> assertFailure "fixture objective missing"
            Just objective -> do
              let selected = grant & #scope .~ SelectedObjectives (objective :| [])
              transaction (Store.readCoverage origin.principal selected.scope) env >>= (@?= Nothing)
              _ <- open env selected "coverage-selected"
              reset <- transaction (Store.readCoverage origin.principal selected.scope) env >>= maybe (assertFailure "missing reset") pure
              reset.cursor @?= initialCursor
    ]

withSeed :: DatabaseFixture -> (AppEnv -> GrantSnapshot -> SubjectObservation -> UTCTime -> IO a) -> IO a
withSeed fixture use = withFixture fixture \env _ _ -> do
  grant <- grantSnapshot
  (_, subject, _) <- Fixture.fixtureSubjects
  sweep <- open env grant "seed"
  saved <- transaction (Store.readSweep sweep) env >>= maybe (assertFailure "missing seed") pure
  let at = addUTCTime 1 saved.openedAt
      observed = classify Fixture.windows at Nothing subject
  pool <- Store.newIdentityPool [subject.subject]
  _ <- transaction (Store.recordSweepPage sweep Liveness at pool [observed]) env
  close env sweep at
  use env grant subject at

observation :: AppEnv -> SubjectObservation -> UTCTime -> IO Observed
observation env subject at = do
  priors <- transaction (Store.readPriorMarks (subjectKey subject.subject :| [])) env
  pure (classify Fixture.windows at (Map.lookup (subjectKey subject.subject) priors) subject)

adverseDrift :: UTCTime -> Observed -> Observed
adverseDrift at observed =
  observed
    & #outcome .~ case observed.outcome of
      Detected detection -> Detected (detection & #kind .~ DriftWork & #verdict .~ Progressing & #summary . #kind .~ DriftWork & #summary . #driftCategory .~ Just OutsideScope & #window . #observedAt .~ at)
      _ -> observed.outcome

summary :: UTCTime -> Word -> Word -> Store.SweepSummary
summary at subjects findings = Store.SweepSummary at subjects 0 findings PassContinuing

close :: AppEnv -> SweepId -> UTCTime -> IO ()
close env sweep at = do
  _ <- transaction (Store.closeSweep sweep (summary at 1 0)) env
  pure ()

open :: AppEnv -> GrantSnapshot -> String -> IO SweepId
open env grant name = do
  identifier <- newSweepId
  origin <- originFor name
  transaction (Store.openSweep identifier origin grant) env

originFor :: String -> IO Store.SweepOrigin
originFor name = do
  principal <- VerifiedIdentity <$> right (mkAgentPrincipal "agent_watchdog")
  pure (Store.SweepOrigin (WorkflowName "fixture.watchdog") (WorkflowId (fromString name)) Fixture.instant principal)
  where
    fromString = Text.pack

grantSnapshot :: IO GrantSnapshot
grantSnapshot = right (eitherDecode "{\"scope\":\"all\",\"windows\":{\"stuck\":60,\"parked\":30,\"coordinator\":90,\"drift\":600},\"budget\":9}")

counts :: AppEnv -> IO (Int64, Int64, Int64)
counts env = run env (runTransaction (Tx.statement () (preparable "SELECT (SELECT count(*) FROM shikigami.watchdog_episodes WHERE closed_at IS NULL),(SELECT count(*) FROM shikigami.watchdog_findings),(SELECT COALESCE(sum(notified_count),0)::bigint FROM shikigami.watchdog_episodes)" E.noParams (D.singleRow ((,,) <$> D.column (D.nonNullable D.int8) <*> D.column (D.nonNullable D.int8) <*> D.column (D.nonNullable D.int8))))))

transaction :: Transaction (Either Store.WatchdogError a) -> AppEnv -> IO a
transaction action env = right =<< run env (runTransaction action)

run :: AppEnv -> Eff AppEffects a -> IO a
run env action = runAppIO env action >>= right

right :: (Show e) => Either e a -> IO a
right = either (assertFailure . show) pure

completedPage :: GrantSnapshot -> UTCTime -> [SubjectObservation] -> ObservationPage
completedPage grant at subjects = ObservationPage at (initialCursor & #scope .~ Just grant.scope & #exhausted .~ [Objectives, Sessions, Executions]) PassCompleted subjects []

transactionObservation :: AppEnv -> ObservationGrant -> IO ObservationPage
transactionObservation env grant = right =<< run env (observePage grant defaultObservationBounds initialCursor)
