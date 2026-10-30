{-# LANGUAGE RankNTypes #-}

module Shikigami.PracticeReviewMemorySpec (tests) where

import Control.Concurrent (forkFinally)
import Control.Concurrent.MVar (newEmptyMVar, putMVar, readMVar, takeMVar)
import Control.Exception (SomeException, displayException)
import Control.Lens ((&), (.~))
import Data.Aeson (FromJSON, Value, eitherDecode, eitherDecodeStrict', encode, object, (.=))
import Data.ByteString qualified as ByteString
import Data.Generics.Labels ()
import Data.Map.Strict qualified as Map
import Data.Set qualified as Set
import Data.Text (Text)
import Data.Text qualified as Text
import Data.Time.Clock (getCurrentTime)
import Effectful (Eff, (:>))
import Keiro.Workflow
  ( WorkflowId (..),
    WorkflowName (..),
    WorkflowOutcome (..),
    WorkflowRunOptions (..),
    defaultWorkflowRunOptions,
    loadStepIndex,
    runWorkflowWith,
  )
import Kioku.Api.Types qualified as Kioku
import Kioku.Id (MemoryId, SessionId, genMemoryId, genSessionId, idText)
import Kioku.Memory qualified as Memory
import Kioku.Memory.Domain (RecordMemoryData (..))
import Kioku.Memory.ReadModel (MemoryRow (..))
import Kiroku.Store.Connection (defaultConnectionSettings, withStore)
import Kiroku.Store.Error (StoreError)
import Shikigami.Agent.Decl
  ( AgentDecl (..),
    Behavior (..),
    Trigger (..),
    defaultMemoryPolicy,
  )
import Shikigami.Agent.Principal (ResolvedAgentIdentity (CompatibilityAgent))
import Shikigami.App (AppEnv (..), noopTracer, runAppIO)
import Shikigami.Memory.Access (agentActor, shikigamiMemorySpace, shikigamiWriteContext)
import Shikigami.Migrations.TestSupport (DatabaseFixture, withShikigamiFreshDatabase)
import Shikigami.PracticeReview
  ( Applicability (..),
    PracticeKey (..),
    PracticeReviewResolution (..),
    PracticeReviewVerdict (..),
    ProjectRef (..),
    ResolutionId (..),
    ResolutionOutcome (..),
    ReviewId (..),
    ValidatedPracticeReviewResolution,
    ValidatedPracticeReviewVerdict,
    deriveResolutionId,
    validateResolution,
    validateVerdict,
    validatedResolutionValue,
    validatedVerdictValue,
  )
import Shikigami.PracticeReview.Memory
  ( PracticeReviewChain (..),
    PracticeReviewChainEntry (..),
    PracticeReviewMemory,
    PracticeReviewMemoryEnv (..),
    PracticeReviewMemoryEnvelope (..),
    RecalledPracticeReviews (..),
    ReviewMemoryDiagnostic (..),
    ReviewMemoryError (..),
    ReviewRecallContext (..),
    appliesTo,
    decodePracticeReviewMemory,
    encodePracticeReviewMemory,
    practiceReviewScope,
    practiceReviewTags,
    provisionalMemoryId,
    recallPracticeReviewChain,
    recallPracticeReviews,
    rememberProvisional,
    resolveReview,
    resolvedMemoryId,
    runPracticeReviewMemory,
  )
import Shikigami.Repository (RelativePath, RepositoryId (..), mkRelativePath)
import System.Directory (doesFileExist)
import System.FilePath ((</>))
import Test.Tasty (TestTree, testGroup)
import Test.Tasty.HUnit (assertBool, assertFailure, testCase, (@?=))

tests :: DatabaseFixture -> TestTree
tests databaseFixture =
  testGroup
    "PracticeReviewMemory"
    [ envelopeTests,
      identityTests,
      applicabilityTests,
      tagTests,
      (postgresTests databaseFixture)
    ]

envelopeTests :: TestTree
envelopeTests =
  testGroup
    "envelopes"
    [ testCase "round-trips validated provisional and resolved version-1 content" do
        (verdicts, resolutions) <- readValidatedContracts
        verdict <- itemAt "target-suspect verdict" 1 verdicts
        resolution <- itemAt "accepted resolution" 0 resolutions
        let provisional = ProvisionalReview verdict
            resolved = ResolvedReview verdict resolution
        decodePracticeReviewMemory (encodePracticeReviewMemory provisional) @?= Right provisional
        decodePracticeReviewMemory (encodePracticeReviewMemory resolved) @?= Right resolved,
      testCase "rejects an unknown envelope version" do
        (verdicts, _) <- readValidatedContracts
        verdict <- itemAt "target-suspect verdict" 1 verdicts
        let encoded = encodePracticeReviewMemory (ProvisionalReview verdict)
            unknown = Text.replace "\"schemaVersion\":1" "\"schemaVersion\":2" encoded
        assertBool "unknown version must fail" (isLeft (decodePracticeReviewMemory unknown)),
      testCase "rejects a resolved envelope whose review ids disagree" do
        (verdicts, resolutions) <- readValidatedContracts
        verdict <- itemAt "target-suspect verdict" 1 verdicts
        rejectedForAnotherReview <- itemAt "rejected resolution" 1 resolutions
        let malformed = encodePracticeReviewMemory (ResolvedReview verdict rejectedForAnotherReview)
        assertBool "mismatched review ids must fail" (isLeft (decodePracticeReviewMemory malformed)),
      testCase "an acknowledgement-shaped value cannot decode as a resolution" do
        let acknowledgement = object ["status" .= ("acknowledged" :: Text), "by" .= ("operator" :: Text)]
        assertBool
          "acknowledgement JSON must fail the resolution boundary"
          (isLeft (eitherDecode (encode acknowledgement) :: Either String PracticeReviewResolution))
    ]

identityTests :: TestTree
identityTests =
  testGroup
    "logical ids"
    [ testCase "provisional ReviewId mapping has a frozen vector" do
        idText (provisionalMemoryId (ReviewId "be79e848-6ce5-5fef-a5c8-bce0596f3784"))
          @?= "kioku_memory_0gg1z2ykx0ah8tcjndjjv6d3ds",
      testCase "resolved ResolutionId mapping has a frozen vector" do
        idText (resolvedMemoryId (ResolutionId "e2b49500-7d39-5f99-8cc9-fde8dbc18853"))
          @?= "kioku_memory_2kxg1vkpjjbt3arkd5s8y8hxvm"
    ]

applicabilityTests :: TestTree
applicabilityTests =
  testGroup
    "applicability"
    [ testCase "matches normalized project, path prefix, dependency, and practice" do
        parent <- expectRight (mkRelativePath "src/Regulated")
        child <- expectRight (mkRelativePath "src/Regulated/Adapter.hs")
        let scope = boundedApplicability parent
            context = recallContext (Just child) (Set.singleton " HS-OPENTELEMETRY-API ")
        assertBool "all dimensions match" (appliesTo scope context),
      testCase "path matching observes segment boundaries" do
        parent <- expectRight (mkRelativePath "src/Foo")
        child <- expectRight (mkRelativePath "src/Foo/Bar.hs")
        sibling <- expectRight (mkRelativePath "src/Foobar.hs")
        assertBool "child path matches" (appliesTo (pathOnly parent) (recallContext (Just child) Set.empty))
        assertBool "textual-but-not-segment prefix misses" (not (appliesTo (pathOnly parent) (recallContext (Just sibling) Set.empty))),
      testCase "empty dimensions are wildcards and populated dimensions exclude mismatches" do
        path <- expectRight (mkRelativePath "docs/adr/0001.md")
        assertBool "fully empty scope is a wildcard" (appliesTo emptyApplicability (recallContext (Just path) Set.empty))
        let wrongProject = Applicability [ProjectRef "other" (RepositoryId "repo_other")] [] [] []
            wrongPractice = Applicability [] [] [] [PracticeKey "logging"]
            wrongDependency = Applicability [] [] ["other-package"] []
            context = recallContext (Just path) (Set.singleton "hs-opentelemetry-api")
        assertBool "project mismatch excludes" (not (appliesTo wrongProject context))
        assertBool "practice mismatch excludes" (not (appliesTo wrongPractice context))
        assertBool "dependency mismatch excludes" (not (appliesTo wrongDependency context))
    ]

tagTests :: TestTree
tagTests =
  testGroup
    "tags"
    [ testCase "provisional tags duplicate stable lookup identities" do
        (verdicts, _) <- readValidatedContracts
        verdict <- itemAt "target-suspect verdict" 1 verdicts
        let tags = practiceReviewTags (ProvisionalReview verdict)
            PracticeReviewVerdict {reviewId = ReviewId reviewId} = validatedVerdictValue verdict
        assertBool "state tag" (Set.member "state:provisional" tags)
        assertBool "practice tag" (Set.member "practice:opentelemetry" tags)
        assertBool "review tag" (Set.member ("review:" <> reviewId) tags)
        assertBool "target repository tag" (Set.member "project:repo_target" tags)
        assertBool "classification tag" (Set.member "classification:target-suspect" tags),
      testCase "resolved tags add resolution and outcome identities deterministically" do
        (verdicts, resolutions) <- readValidatedContracts
        verdict <- itemAt "target-suspect verdict" 1 verdicts
        resolution <- itemAt "accepted resolution" 0 resolutions
        let envelope = ResolvedReview verdict resolution
            tags = practiceReviewTags envelope
            PracticeReviewResolution {resolutionId = ResolutionId resolutionId} = validatedResolutionValue resolution
        practiceReviewTags envelope @?= tags
        assertBool "resolved state" (Set.member "state:resolved" tags)
        assertBool "resolution id" (Set.member ("resolution:" <> resolutionId) tags)
        assertBool "accepted outcome" (Set.member "outcome:accepted" tags)
    ]

postgresTests :: DatabaseFixture -> TestTree
postgresTests databaseFixture =
  testGroup
    "PostgreSQL transitions"
    [ testCase "journals provisional replay with one row and refuses semantic drift" do
        (withReviewEnv databaseFixture) \appEnv session -> do
          (verdicts, _) <- readValidatedContracts
          verdict <- itemAt "target-suspect verdict" 1 verdicts
          let workflowId = WorkflowId "practice-review-provisional-replay"
              expectedId = verdictProvisionalId verdict
          first <- runReviewOperation appEnv session workflowId (rememberProvisional Nothing verdict)
          firstId <- expectCompletedRight first
          firstId @?= expectedId
          replayed <- runReviewOperation appEnv session workflowId (rememberProvisional Nothing verdict)
          replayedId <- expectCompletedRight replayed
          replayedId @?= expectedId
          crossWorkflow <-
            runReviewOperation
              appEnv
              session
              (WorkflowId "practice-review-provisional-logical-replay")
              (rememberProvisional Nothing verdict)
          crossWorkflowId <- expectCompletedRight crossWorkflow
          crossWorkflowId @?= expectedId
          row <- requireMemoryRow appEnv expectedId
          let MemoryRow
                { status,
                  memoryType,
                  confidence,
                  sessionId,
                  tags,
                  content
                } = row
          status @?= "active"
          memoryType @?= Kioku.memoryTypeToText Kioku.MemoryPattern
          confidence @?= Kioku.confidenceToText Kioku.HighConfidence
          sessionId @?= Just (idText session)
          tags @?= practiceReviewTags (ProvisionalReview verdict)
          decodePracticeReviewMemory content @?= Right (ProvisionalReview verdict)

          scopeRows <- activePracticeRows appEnv (PracticeKey "opentelemetry")
          length scopeRows @?= 1
          journal <- loadReviewStepIndex appEnv workflowId
          assertBool "fixed remember step is journaled" (Map.member "practice-review-remember-provisional" journal)
          let changedRaw = validatedVerdictValue verdict & #recommendedAction .~ "semantically changed action"
          changed <- expectRight (validateVerdict changedRaw)
          changedResult <-
            runReviewOperation
              appEnv
              session
              (WorkflowId "practice-review-provisional-conflict")
              (rememberProvisional Nothing changed)
          expectCompleted changedResult >>= \case
            Left (ReviewContentConflict conflictedId _) -> conflictedId @?= expectedId
            other -> assertFailure ("expected changed-content conflict, got " <> show other),
      testCase "classifies all four resolved outcomes and scope-narrows guidance" do
        (withReviewEnv databaseFixture) \appEnv session -> do
          (verdicts, resolutions) <- readValidatedContracts
          pairs <- traverse (pairAt verdicts resolutions) [(1, 0), (2, 1), (3, 2), (4, 3)]
          resolvedIds <-
            traverse
              (\(ordinal, (verdict, resolution)) -> recordAndResolve appEnv session ordinal verdict resolution)
              (zip [(0 :: Int) ..] pairs)

          (acceptedVerdict, acceptedResolution) <- itemAt "accepted pair" 0 pairs
          acceptedReplay <-
            runReviewOperation
              appEnv
              session
              (WorkflowId "practice-review-resolve-accepted-replay")
              (resolveReview (verdictProvisionalId acceptedVerdict) acceptedResolution)
          acceptedReplayId <- expectCompletedRight acceptedReplay
          acceptedReplayId @?= resolutionMemoryId acceptedResolution

          acceptedPath <- expectRight (mkRelativePath "docs/adr/0009-disable-propagation.md")
          acceptedView <- runRecall appEnv session (WorkflowId "practice-review-recall-accepted") (recallContext (Just acceptedPath) Set.empty)
          let RecalledPracticeReviews
                { guiding,
                  doNotRepeat,
                  pending,
                  retired,
                  diagnostics
                } = acceptedView
          length guiding @?= 1
          length doNotRepeat @?= 1
          length pending @?= 0
          length retired @?= 1
          diagnostics @?= []

          narrowedPath <- expectRight (mkRelativePath "src/Regulated/Adapter.hs")
          narrowedView <- runRecall appEnv session (WorkflowId "practice-review-recall-narrowed") (recallContext (Just narrowedPath) Set.empty)
          let RecalledPracticeReviews {guiding = narrowedGuidance} = narrowedView
          length narrowedGuidance @?= 1

          outsidePath <- expectRight (mkRelativePath "src/Public/Adapter.hs")
          outsideView <- runRecall appEnv session (WorkflowId "practice-review-recall-outside") (recallContext (Just outsidePath) Set.empty)
          let RecalledPracticeReviews {guiding = outsideGuidance} = outsideView
          length outsideGuidance @?= 0

          activeRows <- activePracticeRows appEnv (PracticeKey "opentelemetry")
          Set.fromList (idText <$> resolvedIds) @?= Set.fromList (rowMemoryId <$> activeRows),
      testCase "a newer review retires the prior resolution and preserves the full chain" do
        (withReviewEnv databaseFixture) \appEnv session -> do
          (verdicts, resolutions) <- readValidatedContracts
          original <- itemAt "target-suspect verdict" 1 verdicts
          accepted <- itemAt "accepted resolution" 0 resolutions
          priorResolution <- recordAndResolve appEnv session 0 original accepted
          newer <- itemAt "consistent newer verdict" 0 verdicts
          let newerId = verdictProvisionalId newer
          recorded <-
            runReviewOperation
              appEnv
              session
              (WorkflowId "practice-review-newer-provisional")
              (rememberProvisional (Just priorResolution) newer)
          recordedId <- expectCompletedRight recorded
          recordedId @?= newerId

          priorRow <- requireMemoryRow appEnv priorResolution
          let MemoryRow {status = priorStatus, supersededBy = priorSupersededBy} = priorRow
          priorStatus @?= "superseded"
          priorSupersededBy @?= Just (idText newerId)
          newerRow <- requireMemoryRow appEnv newerId
          let MemoryRow {status = newerStatus, supersedes = newerSupersedes} = newerRow
          newerStatus @?= "active"
          newerSupersedes @?= Just (idText priorResolution)

          let PracticeReviewVerdict {reviewId = originalReviewId} = validatedVerdictValue original
          chain <- runChain appEnv session (WorkflowId "practice-review-chain-newer") originalReviewId
          let PracticeReviewChain {entries} = chain
          length entries @?= 3
          [status | PracticeReviewChainEntry {status} <- entries]
            @?= ["superseded", "superseded", "active"],
      testCase "malformed active content is diagnostic and never guidance" do
        (withReviewEnv databaseFixture) \appEnv session -> do
          malformedId <- seedMalformedMemory appEnv session
          path <- expectRight (mkRelativePath "docs/adr/0001.md")
          recalled <- runRecall appEnv session (WorkflowId "practice-review-recall-malformed") (recallContext (Just path) Set.empty)
          let RecalledPracticeReviews {guiding, doNotRepeat, pending, retired, diagnostics} = recalled
          guiding @?= []
          doNotRepeat @?= []
          pending @?= []
          retired @?= []
          case diagnostics of
            [ReviewMemoryDiagnostic {memoryId, code}] -> do
              memoryId @?= idText malformedId
              code @?= "invalid-envelope"
            other -> assertFailure ("expected one malformed diagnostic, got " <> show other),
      testCase "valid content stored under the wrong practice scope is diagnostic" do
        (withReviewEnv databaseFixture) \appEnv session -> do
          (verdicts, _) <- readValidatedContracts
          verdict <- itemAt "target-suspect verdict" 1 verdicts
          misplacedId <-
            seedReviewContent
              appEnv
              session
              (PracticeKey "logging")
              (encodePracticeReviewMemory (ProvisionalReview verdict))
          recalled <-
            runRecall
              appEnv
              session
              (WorkflowId "practice-review-recall-wrong-scope")
              (recallContextFor (PracticeKey "logging") Nothing Set.empty)
          let RecalledPracticeReviews {guiding, doNotRepeat, pending, retired, diagnostics} = recalled
          guiding @?= []
          doNotRepeat @?= []
          pending @?= []
          retired @?= []
          case diagnostics of
            [ReviewMemoryDiagnostic {memoryId, code}] -> do
              memoryId @?= idText misplacedId
              code @?= "scope-mismatch"
            other -> assertFailure ("expected one scope diagnostic, got " <> show other),
      testCase "competing resolutions converge on one active winner and retain the loser" do
        (withReviewEnv databaseFixture) \appEnv session -> do
          (verdicts, resolutions) <- readValidatedContracts
          verdict <- itemAt "target-suspect verdict" 1 verdicts
          accepted <- itemAt "accepted resolution" 0 resolutions
          _ <-
            runReviewOperation
              appEnv
              session
              (WorkflowId "practice-review-race-provisional")
              (rememberProvisional Nothing verdict)
              >>= expectCompletedRight
          rejected <- competingRejected accepted

          gate <- newEmptyMVar
          acceptedResult <- newEmptyMVar
          rejectedResult <- newEmptyMVar
          let provisionalId = verdictProvisionalId verdict
          _ <-
            forkFinally
              (readMVar gate >> runReviewOperation appEnv session (WorkflowId "practice-review-race-accepted") (resolveReview provisionalId accepted))
              (putMVar acceptedResult)
          _ <-
            forkFinally
              (readMVar gate >> runReviewOperation appEnv session (WorkflowId "practice-review-race-rejected") (resolveReview provisionalId rejected))
              (putMVar rejectedResult)
          putMVar gate ()
          acceptedOutcome <- takeMVar acceptedResult >>= expectThread
          rejectedOutcome <- takeMVar rejectedResult >>= expectThread
          outcomes <- traverse expectCompleted [acceptedOutcome, rejectedOutcome]
          let winners = [memoryId | Right memoryId <- outcomes]
              conflicts = [winner | Left (ResolutionConflict winner) <- outcomes]
          case (winners, conflicts) of
            ([winner], [conflictWinner]) -> conflictWinner @?= winner
            other -> assertFailure ("expected one winner and one typed conflict, got " <> show other)

          activeRows <- activePracticeRows appEnv (PracticeKey "opentelemetry")
          length activeRows @?= 1
          let PracticeReviewVerdict {reviewId} = validatedVerdictValue verdict
          chain <- runChain appEnv session (WorkflowId "practice-review-race-chain") reviewId
          let PracticeReviewChain {entries} = chain
          length entries @?= 3
          length [() | PracticeReviewChainEntry {status = "active"} <- entries] @?= 1
          length [() | PracticeReviewChainEntry {status = "superseded"} <- entries] @?= 2
    ]

reviewWorkflowName :: WorkflowName
reviewWorkflowName = WorkflowName "shikigami.practice-review-memory.test"

withReviewEnv :: DatabaseFixture -> (AppEnv -> SessionId -> IO value) -> IO value
withReviewEnv databaseFixture action =
  (withShikigamiFreshDatabase databaseFixture) \connectionString ->
    withStore (defaultConnectionSettings connectionString) \_store -> do
      tracer <- noopTracer
      session <- genSessionId
      let appEnv =
            AppEnv
              { connectionSettings = defaultConnectionSettings connectionString,
                tracer,
                metrics = Nothing,
                store = Nothing
              }
      action appEnv session

runReviewOperation ::
  AppEnv ->
  SessionId ->
  WorkflowId ->
  (forall es. (PracticeReviewMemory :> es) => Eff es result) ->
  IO (Either StoreError (WorkflowOutcome result))
runReviewOperation = runReviewOperationWith reviewRunOptions

runReviewOperationWith ::
  WorkflowRunOptions ->
  AppEnv ->
  SessionId ->
  WorkflowId ->
  (forall es. (PracticeReviewMemory :> es) => Eff es result) ->
  IO (Either StoreError (WorkflowOutcome result))
runReviewOperationWith runOptions appEnv session workflowId operation =
  runAppIO appEnv $
    runWorkflowWith
      runOptions
      reviewWorkflowName
      workflowId
      (runPracticeReviewMemory reviewEnv operation)
  where
    reviewEnv =
      PracticeReviewMemoryEnv
        { appEnv,
          agent = reviewAgentDecl,
          identity = CompatibilityAgent "opentelemetry-practice-reviewer",
          sessionId = Just session
        }

reviewRunOptions :: WorkflowRunOptions
reviewRunOptions = defaultWorkflowRunOptions

reviewAgentDecl :: AgentDecl
reviewAgentDecl =
  AgentDecl
    { name = "opentelemetry-practice-reviewer",
      description = "practice-review memory integration test agent",
      trigger = Event {eventType = "architecture.practice-review.test"},
      behavior = Deterministic {rule = "practice-review-memory-test", params = mempty},
      sinks = [],
      delegates = [],
      delegationBudget = Nothing,
      sanctionedProfile = Nothing,
      capabilityOverlays = [],
      identity = Nothing,
      memory = defaultMemoryPolicy,
      enabled = True,
      expertise = [],
      execution = Nothing,
      harness = Nothing,
      decisionModels = [],
      routing = Nothing
    }

loadReviewStepIndex :: AppEnv -> WorkflowId -> IO (Map.Map Text Value)
loadReviewStepIndex appEnv workflowId =
  runAppIO appEnv (loadStepIndex reviewWorkflowName workflowId 0) >>= \case
    Left err -> assertFailure ("failed to load review workflow journal: " <> show err)
    Right index -> pure index

expectCompleted :: (Show result) => Either StoreError (WorkflowOutcome result) -> IO result
expectCompleted = \case
  Left err -> assertFailure ("review workflow failed: " <> show err)
  Right (Completed result) -> pure result
  Right outcome -> assertFailure ("review workflow did not complete: " <> show outcome)

expectCompletedRight :: Either StoreError (WorkflowOutcome (Either ReviewMemoryError MemoryId)) -> IO MemoryId
expectCompletedRight outcome =
  expectCompleted outcome >>= \case
    Left err -> assertFailure ("review memory operation failed: " <> show err)
    Right memoryId -> pure memoryId

recordAndResolve ::
  AppEnv ->
  SessionId ->
  Int ->
  ValidatedPracticeReviewVerdict ->
  ValidatedPracticeReviewResolution ->
  IO MemoryId
recordAndResolve appEnv session ordinal verdict resolution = do
  let suffix = Text.pack (show ordinal)
      provisional = verdictProvisionalId verdict
  _ <-
    runReviewOperation
      appEnv
      session
      (WorkflowId ("practice-review-record-" <> suffix))
      (rememberProvisional Nothing verdict)
      >>= expectCompletedRight
  runReviewOperation
    appEnv
    session
    (WorkflowId ("practice-review-resolve-" <> suffix))
    (resolveReview provisional resolution)
    >>= expectCompletedRight

runRecall :: AppEnv -> SessionId -> WorkflowId -> ReviewRecallContext -> IO RecalledPracticeReviews
runRecall appEnv session workflowId context =
  runReviewOperation appEnv session workflowId (recallPracticeReviews context)
    >>= expectCompleted

runChain :: AppEnv -> SessionId -> WorkflowId -> ReviewId -> IO PracticeReviewChain
runChain appEnv session workflowId reviewId =
  runReviewOperation appEnv session workflowId (recallPracticeReviewChain reviewId)
    >>= expectCompleted

verdictProvisionalId :: ValidatedPracticeReviewVerdict -> MemoryId
verdictProvisionalId verdict =
  let PracticeReviewVerdict {reviewId} = validatedVerdictValue verdict
   in provisionalMemoryId reviewId

resolutionMemoryId :: ValidatedPracticeReviewResolution -> MemoryId
resolutionMemoryId resolution =
  let PracticeReviewResolution {resolutionId} = validatedResolutionValue resolution
   in resolvedMemoryId resolutionId

pairAt ::
  [ValidatedPracticeReviewVerdict] ->
  [ValidatedPracticeReviewResolution] ->
  (Int, Int) ->
  IO (ValidatedPracticeReviewVerdict, ValidatedPracticeReviewResolution)
pairAt verdicts resolutions (verdictIndex, resolutionIndex) = do
  verdict <- itemAt "paired verdict" verdictIndex verdicts
  resolution <- itemAt "paired resolution" resolutionIndex resolutions
  pure (verdict, resolution)

activePracticeRows :: AppEnv -> PracticeKey -> IO [MemoryRow]
activePracticeRows appEnv practice =
  runAppIO appEnv (Memory.getActiveRowsByScope shikigamiMemorySpace (practiceReviewScope practice)) >>= \case
    Left err -> assertFailure ("failed to query active practice-review rows: " <> show err)
    Right (Left err) -> assertFailure ("active practice-review query was refused: " <> show err)
    Right (Right rows) -> pure rows

requireMemoryRow :: AppEnv -> MemoryId -> IO MemoryRow
requireMemoryRow appEnv memoryId =
  runAppIO appEnv (Memory.getMemoryRowById shikigamiMemorySpace memoryId) >>= \case
    Left err -> assertFailure ("failed to read practice-review row: " <> show err)
    Right (Left err) -> assertFailure ("practice-review row query was refused: " <> show err)
    Right (Right Nothing) -> assertFailure ("practice-review row is missing: " <> Text.unpack (idText memoryId))
    Right (Right (Just row)) -> pure row

rowMemoryId :: MemoryRow -> Text
rowMemoryId MemoryRow {memoryId} = memoryId

seedMalformedMemory :: AppEnv -> SessionId -> IO MemoryId
seedMalformedMemory appEnv session =
  seedReviewContent
    appEnv
    session
    (PracticeKey "opentelemetry")
    "{\"schemaVersion\":99}"

seedReviewContent :: AppEnv -> SessionId -> PracticeKey -> Text -> IO MemoryId
seedReviewContent appEnv session practice content = do
  memoryId <- genMemoryId
  recordedAt <- getCurrentTime
  let agentName = "opentelemetry-practice-reviewer"
      recordedIdentity = CompatibilityAgent agentName
      command =
        RecordMemoryData
          { memoryId,
            memorySpaceId = shikigamiMemorySpace,
            actorPrincipal = agentActor recordedIdentity,
            ownerPrincipal = Nothing,
            agentId = agentName,
            sessionId = Just session,
            scope = practiceReviewScope practice,
            memoryType = Kioku.MemoryConstraint,
            content,
            priority = 100,
            confidence = Kioku.HighConfidence,
            tags = Set.fromList ["practice-review", "state:fixture"],
            supersedes = Nothing,
            recordedAt
          }
  runAppIO appEnv (Memory.recordWithContext (shikigamiWriteContext recordedIdentity) command) >>= \case
    Left err -> assertFailure ("failed to seed malformed review memory: " <> show err)
    Right (Left err) -> assertFailure ("malformed review seed was refused: " <> show err)
    Right (Right stored) -> pure stored

competingRejected :: ValidatedPracticeReviewResolution -> IO ValidatedPracticeReviewResolution
competingRejected accepted = do
  let acceptedValue = validatedResolutionValue accepted
      PracticeReviewResolution {reviewId} = acceptedValue
      commandKey = "race-rejected"
      rejectedValue =
        acceptedValue
          & #resolutionId
            .~ deriveResolutionId reviewId commandKey
          & #idempotencyKey
            .~ commandKey
          & #outcome
            .~ Rejected
          & #reason
            .~ "the competing reviewer rejected the practice"
          & #resultingApplicability
            .~ Nothing
  expectRight (validateResolution rejectedValue)

expectThread :: Either SomeException value -> IO value
expectThread = \case
  Left err -> assertFailure ("concurrent review operation failed: " <> displayException err)
  Right value -> pure value

boundedApplicability :: RelativePath -> Applicability
boundedApplicability path =
  Applicability
    { projects = [ProjectRef "target" (RepositoryId "repo_target")],
      paths = [path],
      dependencies = ["hs-opentelemetry-api"],
      practices = [PracticeKey "opentelemetry"]
    }

pathOnly :: RelativePath -> Applicability
pathOnly path = Applicability [] [path] [] []

emptyApplicability :: Applicability
emptyApplicability = Applicability [] [] [] []

recallContext :: Maybe RelativePath -> Set.Set Text -> ReviewRecallContext
recallContext = recallContextFor (PracticeKey "opentelemetry")

recallContextFor :: PracticeKey -> Maybe RelativePath -> Set.Set Text -> ReviewRecallContext
recallContextFor practice path dependencies =
  ReviewRecallContext
    { project = ProjectRef "target" (RepositoryId "repo_target"),
      path,
      dependencies,
      practice
    }

readValidatedContracts :: IO ([ValidatedPracticeReviewVerdict], [ValidatedPracticeReviewResolution])
readValidatedContracts = do
  rawVerdicts <- readFixture "verdicts-valid.json" >>= decodeOrFail
  rawResolutions <- readFixture "resolutions-valid.json" >>= decodeOrFail
  verdicts <- traverse (expectRight . validateVerdict) rawVerdicts
  resolutions <- traverse (expectRight . validateResolution) rawResolutions
  pure (verdicts, resolutions)

readFixture :: FilePath -> IO ByteString.ByteString
readFixture name = do
  root <- repositoryRoot
  ByteString.readFile (root </> "fixtures" </> "practice-review" </> name)

repositoryRoot :: IO FilePath
repositoryRoot = go [".", ".."]
  where
    go [] = assertFailure "cannot find cabal.project from the working directory"
    go (candidate : rest) = do
      exists <- doesFileExist (candidate </> "cabal.project")
      if exists then pure candidate else go rest

decodeOrFail :: (FromJSON value) => ByteString.ByteString -> IO value
decodeOrFail bytes =
  case eitherDecodeStrict' bytes of
    Left err -> assertFailure err
    Right value -> pure value

itemAt :: String -> Int -> [value] -> IO value
itemAt label index values =
  case drop index values of
    value : _ -> pure value
    [] -> assertFailure (label <> " fixture is missing")

expectRight :: (Show error) => Either error value -> IO value
expectRight = \case
  Left err -> assertFailure (show err)
  Right value -> pure value

isLeft :: Either left right -> Bool
isLeft = \case
  Left _ -> True
  Right _ -> False
