{-# LANGUAGE DataKinds #-}

module Shikigami.WatchdogTypesSpec (tests) where

import Data.Aeson (FromJSON, ToJSON, eitherDecode, encode)
import Data.ByteString.Lazy qualified
import Data.Either (isLeft)
import Data.List.NonEmpty qualified
import Data.Text qualified as Text
import Shikigami.Agent.Approval (parseReviewRequestId)
import Shikigami.Agent.Name (mkAgentName)
import Shikigami.Agent.Principal (AgentIdentity (..), mkAgentPrincipal)
import Shikigami.Coordination.Observation qualified as Coordinator
import Shikigami.Duration (durationTime)
import Shikigami.Execution.Coordinate (executionIdentity)
import Shikigami.Execution.Identity (newExecutionRootId, parseOperationId)
import Shikigami.Execution.Observation qualified as Execution
import Shikigami.Objective.Observation qualified as ObjectiveObservation
import Shikigami.Objective.Types qualified as Objective
import Shikigami.StateRevision (initialRevision)
import Shikigami.Watchdog.Grant
import Shikigami.Watchdog.Observation qualified as Observation
import Shikigami.Watchdog.Types
import Shikigami.WorkerSession.Input (workerSessionId)
import Shikigami.WorkerSession.Observation qualified as Session
import Test.Tasty (TestTree, testGroup)
import Test.Tasty.HUnit (assertBool, assertFailure, testCase, (@?=))

tests :: TestTree
tests =
  testGroup
    "Watchdog values"
    [ testCase "a one-subject sweep rotates fairly and skips exhausted kinds" do
        Observation.pageShares 1 Observation.initialCursor @?= [(Observation.Objectives, 1), (Observation.Sessions, 0), (Observation.Executions, 0)]
        let sessionsNext = Observation.CoverageCursor Nothing Nothing Nothing Nothing [] Observation.Sessions True
            executionsNext = Observation.CoverageCursor Nothing Nothing Nothing Nothing [Observation.Sessions] Observation.Executions True
        Observation.pageShares 1 sessionsNext @?= [(Observation.Objectives, 0), (Observation.Sessions, 1), (Observation.Executions, 0)]
        Observation.pageShares 3 executionsNext @?= [(Observation.Objectives, 1), (Observation.Sessions, 0), (Observation.Executions, 2)]
        sum (map snd (Observation.pageShares 16777216 Observation.initialCursor)) @?= 96,
      testCase "observation owner statements take no row locks" do
        mapM_
          ( \sql -> do
              assertBool "no exclusive lock" (not ("FOR UPDATE" `Text.isInfixOf` Text.toUpper sql))
              assertBool "no shared lock" (not ("FOR SHARE" `Text.isInfixOf` Text.toUpper sql))
          )
          [ObjectiveObservation.observationSql, Session.observationSql, Execution.observationSql, Coordinator.observationSql],
      testCase "allocated ids require canonical UUIDv7 and the exact prefix" do
        sweep <- newSweepId
        episode <- newEpisodeId
        finding <- newFindingId
        parseSweepId (sweepIdText sweep) @?= Right sweep
        parseEpisodeId (episodeIdText episode) @?= Right episode
        parseFindingId (findingIdText finding) @?= Right finding
        roundTrip sweep
        roundTrip episode
        roundTrip finding
        assertBool "cross-kind" (isLeft (parseSweepId (episodeIdText episode)))
        assertBool "UUIDv4" (isLeft (parseSweepId "shikigami_watchdog_sweep_00000000008008000000001ayd"))
        assertBool "empty" (isLeft (parseEpisodeId ""))
        assertBool "noncanonical" (isLeft (parseFindingId (Text.toUpper (findingIdText finding)))),
      testCase "subject keys round trip all kinds and preserve owner coordinates" do
        objective <- checked (Objective.parseObjectiveId "shikigami_objective_01kwz3wy6wf8qv2pnwnb46qg1w")
        mapM_
          ( \subject -> do
              parseSubjectKey (subjectKeyText (subjectKey subject)) @?= Right subject
              roundTrip subject
              roundTrip (subjectKey subject)
          )
          [ObjectiveCoordinator objective, WorkerSession (workerSessionId "session/a"), Execution (executionIdentity "execution/a")]
        mapM_
          (\value -> assertBool (Text.unpack value) (isLeft (parseSubjectKey value)))
          ["", "coordinator/2/nope", "coordinator/1/nope", "session/1/", "execution/1/"],
      testCase "activity marks have a stable versioned canonical digest" do
        let mark = CoordinatorMark (CoordinatorActivity Objective.Open initialRevision Nothing Nothing 0 CoordinatorOpen)
        roundTrip mark
        roundTrip (markDigest mark)
        -- This pin is filled from the canonical commitment implementation and
        -- prevents a wire change silently resetting every retained staleness mark.
        markDigestText (markDigest mark) @?= "sha256:c3fd63eb7b4cb7b08777766316bc5f2ddfa08a06a2b146a8b41b69e6d66fd47c"
        assertBool "revision-sensitive" (markDigest mark /= markDigest (CoordinatorMark (CoordinatorActivity Objective.Blocked initialRevision Nothing Nothing 0 CoordinatorOpen)))
        mapM_ (\value -> assertBool "invalid digest" (isLeft (parseMarkDigest value))) ["", "sha256:abc", "sha256:" <> Text.replicate 64 "A"],
      testCase "waiting, evidence and finding codecs retain coordinates without bodies" do
        let instant = read "2026-11-06 00:00:00 UTC"
        operation <- checked (parseOperationId "fixture/operation")
        review <- checked (parseReviewRequestId "review_00000000-0000-5000-8000-000000000000")
        objective <- checked (Objective.parseObjectiveId "shikigami_objective_01kwz3wy6wf8qv2pnwnb46qg1w")
        root <- newExecutionRootId
        assignment <- checked (Objective.parseObjectiveAssignmentId "fixture")
        let session = workerSessionId "fixture"
            execution = executionIdentity "fixture"
        mapM_ roundTrip [AwaitingApproval instant review, AwaitingPermission instant, RunningCommand instant operation, ParkedAssignment instant, ObjectiveBlocked]
        mapM_ roundTrip [ApprovalWait instant review, PermissionWait instant, CommandWait instant operation, AssignmentParked, BlockedObjective]
        mapM_ roundTrip [Progressing, Waiting ObjectiveBlocked, Unresolved, Stuck, StuckCoordinator, Terminal, ObservationUnknown]
        mapM_ roundTrip [StuckWork, UnresolvedOutcome, StuckCoordinatorWork, DriftWork]
        mapM_ roundTrip [Liveness, DriftAssessmentFamily]
        mapM_ roundTrip [WithinScope, PossibleDrift, OutsideScope]
        let evidence = [ObjectiveEvidence objective initialRevision, AssignmentEvidence assignment initialRevision initialRevision, SessionEvidence session initialRevision, ExecutionEvidence execution initialRevision, DecisionEvidence operation, ProcessEvidence operation, RootEvidence root initialRevision, ApprovalEvidence review]
        mapM_ roundTrip evidence
        sweep <- newSweepId
        episode <- newEpisodeId
        finding <- newFindingId
        budget <- checked (parseWatchdogLimit 3)
        roundTrip (FindingView finding episode sweep (Just objective) (WorkerSession session) StuckWork (Data.List.NonEmpty.fromList evidence) (ObservedWindow instant instant instant) (ObservationLimit budget Complete Unknown)),
      testCase "watchdog limits admit only positive bounded quantities" do
        mapM_ (\n -> assertBool "bound refused" (isLeft (parseWatchdogLimit @"subjects" n))) [-1, 0, 16777217]
        (limitValue <$> parseWatchdogLimit @"subjects" 16777216) @?= Right 16777216,
      testCase "grant refuses disabled, unresolved and other principals" do
        settings <- checked (eitherDecode settingsJson)
        principal <- VerifiedIdentity <$> checked (mkAgentPrincipal "agent_watchdog")
        other <- VerifiedIdentity <$> checked (mkAgentPrincipal "agent_other")
        either Just (const Nothing) (resolveObservationGrant Nothing principal) @?= Just WatchdogDisabled
        either Just (const Nothing) (resolveObservationGrant (Just settings) UnresolvedLegacyIdentity) @?= Just UnresolvedIdentity
        either Just (const Nothing) (resolveObservationGrant (Just settings) other) @?= Just NotTheWatchdogPrincipal
        grant <- checked (resolveObservationGrant (Just settings) principal)
        grantScope grant @?= AllObjectives
        limitValue (grantBudget grant) @?= 3
        roundTrip (snapshotGrant grant),
      testCase "replay retains admitted windows and scope but rechecks identity" do
        settings <- checked (eitherDecode settingsJson)
        changed <- checked (eitherDecode "{\"principal\":\"agent_watchdog\",\"scope\":\"all\",\"stuckWindowSeconds\":900,\"parkedWindowSeconds\":900,\"coordinatorWindowSeconds\":900,\"subjectsPerSweep\":1}")
        principal <- VerifiedIdentity <$> checked (mkAgentPrincipal "agent_watchdog")
        grant <- checked (resolveObservationGrant (Just settings) principal)
        restored <- checked (restoreGrant (snapshotGrant grant) principal (Just changed))
        snapshotGrant restored @?= snapshotGrant grant
        durationTime (grantWindows restored).stuck @?= 60,
      testCase "compatibility identity is admitted only by an exact name policy" do
        settings <- checked (eitherDecode "{\"principal\":\"watchdog\",\"scope\":\"all\",\"stuckWindowSeconds\":60,\"parkedWindowSeconds\":30,\"coordinatorWindowSeconds\":60,\"subjectsPerSweep\":1}")
        name <- CompatibilityIdentity <$> checked (mkAgentName "watchdog")
        _ <- checked (resolveObservationGrant (Just settings) name)
        verified <- VerifiedIdentity <$> checked (mkAgentPrincipal "agent_watchdog")
        either Just (const Nothing) (resolveObservationGrant (Just settings) verified) @?= Just NotTheWatchdogPrincipal,
      testCase "settings reject zero windows, empty scope, unknown keys and bad limits" do
        mapM_
          (\raw -> assertBool "invalid settings" (isLeft (eitherDecode @WatchdogSettings raw)))
          [ "{\"principal\":\"watchdog\",\"scope\":{\"objectives\":[]},\"stuckWindowSeconds\":1,\"parkedWindowSeconds\":1,\"coordinatorWindowSeconds\":1,\"subjectsPerSweep\":1}",
            "{\"principal\":\"watchdog\",\"scope\":\"all\",\"stuckWindowSeconds\":0,\"parkedWindowSeconds\":1,\"coordinatorWindowSeconds\":1,\"subjectsPerSweep\":1}",
            "{\"principal\":\"watchdog\",\"scope\":\"all\",\"stuckWindowSeconds\":1,\"parkedWindowSeconds\":1,\"coordinatorWindowSeconds\":1,\"subjectsPerSweep\":0}",
            "{\"surprise\":true}"
          ]
    ]

settingsJson :: Data.ByteString.Lazy.ByteString
settingsJson = "{\"principal\":\"agent_watchdog\",\"scope\":\"all\",\"stuckWindowSeconds\":60,\"parkedWindowSeconds\":30,\"coordinatorWindowSeconds\":120,\"subjectsPerSweep\":3}"

checked :: (Show e) => Either e a -> IO a
checked = either (assertFailure . show) pure

roundTrip :: (Eq a, Show a, ToJSON a, FromJSON a) => a -> IO ()
roundTrip value = eitherDecode (encode value) @?= Right value
