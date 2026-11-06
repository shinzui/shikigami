{-# LANGUAGE DataKinds #-}

module Shikigami.WatchdogDriftCadenceSpec (tests) where

import Control.Lens ((&), (.~))
import Data.Aeson (eitherDecode, encode, object, (.=))
import Data.Either (isLeft)
import Data.Generics.Labels ()
import Data.List.NonEmpty (NonEmpty (..))
import Data.List.NonEmpty qualified as NonEmpty
import Data.Map.Strict qualified as Map
import Data.Text qualified as Text
import Data.Time (UTCTime, addUTCTime)
import Keiro.Workflow.Types (WorkflowId (..))
import Shikigami.Agent.Principal (AgentIdentity (..), mkAgentPrincipal)
import Shikigami.Duration (durationTime, remainingDuration)
import Shikigami.Execution.Observation qualified as Execution
import Shikigami.Execution.Progress (noPendingReceipts)
import Shikigami.Execution.Transcript qualified as Owner
import Shikigami.Objective.Observation qualified as Objective
import Shikigami.Objective.Types qualified as Objective
import Shikigami.Program.Decision.Drift
import Shikigami.StateRevision (initialRevision)
import Shikigami.Watchdog.Drift
import Shikigami.Watchdog.Grant
import Shikigami.Watchdog.Observation
import Shikigami.Watchdog.Types
import Test.Tasty (TestTree, testGroup)
import Test.Tasty.HUnit (assertBool, assertFailure, testCase, (@?=))

tests :: TestTree
tests =
  testGroup
    "Watchdog Drift cadence"
    [ testCase "fresh checks suppress unchanged and changed marks until the minimum interval" do
        (objective, subject) <- fixture "first" False
        cadence <- cadenceWith 1
        let check = DriftCheck subject.subject objective.objectiveId instant (markDigest subject.mark) WithinScope
            checks = Map.singleton (subjectKey subject.subject) check
            changed = subject & #mark .~ ExecutionMark (ExecutionActivity (Objective.advanceRevision initialRevision) initialRevision Owner.Active Nothing 0 noPendingReceipts)
        dueForDrift cadence (addUTCTime 599 instant) checks [subject] @?= Nothing
        dueForDrift cadence (addUTCTime 599 instant) checks [changed] @?= Nothing
        fmap (map (.subject) . NonEmpty.toList . snd) (dueForDrift cadence (addUTCTime 600 instant) checks [changed]) @?= Just [subject.subject],
      testCase "oldest due objective wins and one bounded batch has stable order" do
        (firstObjective, first) <- fixture "first" False
        (secondObjective, second) <- fixture "second" True
        cadence <- cadenceWith 1
        let checks = Map.fromList [(subjectKey first.subject, DriftCheck first.subject firstObjective.objectiveId (addUTCTime 60 instant) (markDigest first.mark) WithinScope), (subjectKey second.subject, DriftCheck second.subject secondObjective.objectiveId instant (markDigest second.mark) WithinScope)]
        fmap fst (dueForDrift cadence (addUTCTime 900 instant) checks [first, second]) @?= Just secondObjective.objectiveId
        fmap fst (dueForDrift cadence (addUTCTime 900 instant) (Map.delete (subjectKey first.subject) checks) [first, second]) @?= Just firstObjective.objectiveId
        two <- cadenceWith 2
        (_, third) <- fixture "third" False
        (_, fourth) <- fixture "fourth" False
        case dueForDrift two instant Map.empty [third, first, fourth] of
          Just (_, selected) -> do
            NonEmpty.length selected @?= 2
            map (.subject) (NonEmpty.toList selected) @?= map (.subject) (NonEmpty.toList (maybe (error "missing") snd (dueForDrift two instant Map.empty [fourth, first, third])))
          _ -> assertFailure "due population missing",
      testCase "missing scope, incomplete relationships and duplicate identities are not assessed" do
        (_, subject) <- fixture "first" False
        cadence <- cadenceWith 1
        dueForDrift cadence instant Map.empty [subject & #objective .~ Nothing] @?= Nothing
        dueForDrift cadence instant Map.empty [subject & #relationshipsComplete .~ Unknown] @?= Nothing
        dueForDrift cadence instant Map.empty [subject, subject] @?= Nothing,
      testCase "metadata builder refuses a different objective and oversized public goals" do
        (objective, subject) <- fixture "first" False
        (other, _) <- fixture "second" True
        limit <- right (parseWatchdogLimit 1)
        input <- right (buildDriftInput limit objective (subject :| []))
        input.objective @?= objective.objectiveId
        map (.subject) (NonEmpty.toList input.subjects) @?= [subject.subject]
        assertBool "cross-objective input refused" (isLeft (buildDriftInput limit other (subject :| [])))
        goal <- right (Objective.parseGoal (mconcat (replicate 4097 "a")))
        assertBool "oversized goal refused" (isLeft (buildDriftInput limit (objective & #goal .~ goal) (subject :| []))),
      testCase "check construction requires the sealed exact input and complete selected subjects" do
        (objective, subject) <- fixture "first" False
        limit <- right (parseWatchdogLimit 1)
        input <- right (buildDriftInput limit objective (subject :| []))
        let output = DriftProposal [DriftProposalSubject (subjectKeyText (subjectKey subject.subject)) "outside-scope" "The available work does not match the goal." [0]]
        assessment <- right (validateDriftAssessment input output)
        checks <- right (checksForAssessment instant input (subject :| []) assessment)
        map (.mark) (NonEmpty.toList checks) @?= [markDigest subject.mark]
        checksForAssessment instant (input & #goal .~ "Changed scope") (subject :| []) assessment @?= Left DriftBindingConflict
        checksForAssessment instant input ((subject & #relationshipsComplete .~ Unknown) :| []) assessment @?= Left DriftBindingConflict,
      testCase "omitted drift is disabled; admitted cadence and budget survive policy replay" do
        settings <- settingsWith Nothing Nothing
        principal <- VerifiedIdentity <$> right (mkAgentPrincipal "agent_watchdog")
        disabled <- right (resolveObservationGrant (Just settings) principal)
        cadenceForGrant disabled @?= Nothing
        configured <- settingsWith (Just 600) (Just 2)
        grant <- right (resolveObservationGrant (Just configured) principal)
        changed <- settingsWith (Just 1200) (Just 1)
        replay <- right (restoreGrant (snapshotGrant grant) principal (Just changed))
        fmap (limitValue . (.subjectsPerSweep)) (cadenceForGrant replay) @?= Just 2
        fmap (durationTime . (.interval)) (cadenceForGrant replay) @?= Just 600
        old <- right (eitherDecode @GrantSnapshot "{\"scope\":\"all\",\"windows\":{\"stuck\":60,\"parked\":30,\"coordinator\":90,\"drift\":600},\"budget\":9}")
        old.driftBudget @?= Nothing,
      testCase "partial, zero and catalog-exceeding cadence settings refuse at load" do
        mapM_
          ( \(interval, budget) -> do
              let decoded = decodeSettings interval budget
              assertBool "invalid cadence settings refused" (isLeft decoded)
          )
          [(Just 600, Nothing), (Nothing, Just 1), (Just 0, Just 1), (Just 600, Just 17)]
    ]

instant :: UTCTime
instant = read "2026-11-04 00:00:00 UTC"

cadenceWith :: Int -> IO DriftCadence
cadenceWith budget = DriftCadence (remainingDuration 600) <$> right (parseWatchdogLimit budget)

fixture :: String -> Bool -> IO (Objective.ObjectiveObservation, SubjectObservation)
fixture label second = do
  identifier <- right (Objective.parseObjectiveId (if second then "shikigami_objective_01kwz3wy6wf8qv2pnwnb46qg1x" else "shikigami_objective_01kwz3wy6wf8qv2pnwnb46qg1w"))
  goal <- right (Objective.parseGoal "Produce the architecture summary")
  let executionId = Owner.executionIdentity (Text.pack label)
      objective = Objective.ObjectiveObservation identifier Objective.Open initialRevision initialRevision initialRevision goal [] [] [] 0 Nothing 0 True instant
      execution = Execution.ExecutionObservation executionId (WorkflowId "cadence-child") initialRevision initialRevision Owner.Active Nothing noPendingReceipts Nothing (Just identifier) [] True True 0 Nothing instant
      subject = SubjectObservation (Execution executionId) (Just identifier) (ExecutionMark (ExecutionActivity initialRevision initialRevision Owner.Active Nothing 0 noPendingReceipts)) [] (ExecutionEvidence executionId initialRevision :| []) Complete (ExecutionMetadata execution) [] [] [] []
  pure (objective, subject)

settingsWith :: Maybe Int -> Maybe Int -> IO WatchdogSettings
settingsWith interval budget = right (decodeSettings interval budget)

decodeSettings :: Maybe Int -> Maybe Int -> Either String WatchdogSettings
decodeSettings interval budget = eitherDecode (encode (object ["principal" .= ("agent_watchdog" :: Text.Text), "scope" .= ("all" :: Text.Text), "stuckWindowSeconds" .= (60 :: Int), "parkedWindowSeconds" .= (30 :: Int), "coordinatorWindowSeconds" .= (90 :: Int), "subjectsPerSweep" .= (9 :: Int), "driftIntervalSeconds" .= interval, "driftSubjectsPerSweep" .= budget]))

right :: (Show e) => Either e a -> IO a
right = either (assertFailure . show) pure
