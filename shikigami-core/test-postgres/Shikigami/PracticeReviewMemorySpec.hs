{-# LANGUAGE RankNTypes #-}

module Shikigami.PracticeReviewMemorySpec (tests) where

import Control.Concurrent (forkFinally)
import Control.Concurrent.Async (replicateConcurrently)
import Control.Concurrent.MVar (newEmptyMVar, putMVar, readMVar, takeMVar)
import Control.Exception (SomeException, displayException, try)
import Control.Lens ((&), (.~))
import Data.Aeson (FromJSON, Value, eitherDecode, eitherDecodeStrict', encode, object, (.=))
import Data.ByteString qualified as ByteString
import Data.Generics.Labels ()
import Data.Map.Strict qualified as Map
import Data.Set qualified as Set
import Data.Text (Text)
import Data.Text qualified as Text
import Data.Time.Clock (getCurrentTime)
import Effectful (Eff, IOE, (:>))
import Effectful qualified
import Hasql.Pool qualified as Pool
import Hasql.Session qualified as Session
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
import Kiroku.Store.Connection (KirokuStore (..), defaultConnectionSettings, withStore)
import Kiroku.Store.Error (StoreError)
import Shikigami.Activity.Coordinate
import Shikigami.Agent.Decl
  ( AgentDecl (..),
    Behavior (..),
    Trigger (..),
    defaultMemoryPolicy,
  )
import Shikigami.Agent.DeclarationValue
import Shikigami.Agent.Name (AgentName, mkAgentName)
import Shikigami.Agent.Principal (ResolvedAgentIdentity (CompatibilityAgent))
import Shikigami.App (AppEnv (..), noopTracer, runAppIO)
import Shikigami.Memory.Access (agentActor, shikigamiMemorySpace, shikigamiWriteContext)
import Shikigami.Migrations.TestSupport (DatabaseFixture, withShikigamiFreshDatabase)
import Shikigami.PracticeReview
  ( Applicability (..),
    PracticeKey,
    PracticeReviewResolution (..),
    PracticeReviewResolutionRequest (..),
    PracticeReviewVerdict (..),
    ProjectRef (..),
    ResolutionId,
    ResolutionOutcome (..),
    ReviewId,
    ValidatedPracticeReviewResolution,
    ValidatedPracticeReviewVerdict,
    parsePracticeKey,
    parseResolutionId,
    parseReviewId,
    resolutionIdText,
    reviewIdText,
    validateResolution,
    validateResolutionRequest,
    validateTrigger,
    validateVerdict,
    validatedResolutionValue,
    validatedTriggerValue,
    validatedVerdictValue,
  )
import Shikigami.PracticeReview qualified as Review
import Shikigami.PracticeReview qualified as ReviewValue
import Shikigami.PracticeReview.Identity (newResolutionId)
import Shikigami.PracticeReview.IdentityStore qualified as IdentityStore
import Shikigami.PracticeReview.Memory
  ( PracticeReviewChain (..),
    PracticeReviewChainEntry (..),
    PracticeReviewMemory,
    PracticeReviewMemoryEnv (..),
    PracticeReviewMemoryEnvelope (..),
    RecalledPracticeReviews (..),
    ResolvedPracticeReview (..),
    ReviewMemoryDiagnostic (..),
    ReviewMemoryError (..),
    ReviewRecallContext (..),
    allocatedReviewId,
    appliesTo,
    decodePracticeReviewMemory,
    encodePracticeReviewMemory,
    practiceReviewScope,
    practiceReviewTags,
    provisionalMemoryId,
    recallPracticeReviewChain,
    recallPracticeReviews,
    reserveReviewIdentity,
    resolvedMemoryId,
    runPracticeReviewMemory,
  )
import Shikigami.PracticeReview.Memory qualified as ReviewMemory
import Shikigami.Repository (RelativePath, RepositoryId, mkRelativePath, repositoryId, repositoryIdText)
import Shikigami.Trigger.Schedule (parseCron)
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
        idText (provisionalMemoryId (fixtureReviewId "shikigami_practice_review_6qqyrw7p5ffa9873q5jp4aahjm"))
          @?= "kioku_memory_6w46arhnxdbjy89t9nhx5m73hc",
      testCase "resolved ResolutionId mapping has a frozen vector" do
        idText (resolvedMemoryId (fixtureResolutionId "shikigami_practice_review_resolution_7vrc7qfsy9fjer83xyg2t8m382"))
          @?= "kioku_memory_30xdzf1f12an8tm1c746a0nzpv"
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
        let wrongProject = Applicability [ProjectRef "other" (repositoryId "repo_other")] [] [] []
            wrongPractice = Applicability [] [] [] [fixturePracticeKey "logging"]
            wrongDependency = Applicability [] [] [reviewDependencyName "other-package"] []
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
            PracticeReviewVerdict {reviewId} = validatedVerdictValue verdict
        assertBool "state tag" (Set.member "state:provisional" tags)
        assertBool "practice tag" (Set.member "practice:opentelemetry" tags)
        assertBool "review tag" (Set.member ("review:" <> reviewIdText reviewId) tags)
        assertBool "target repository tag" (Set.member "project:repo_target" tags)
        assertBool "classification tag" (Set.member "classification:target-suspect" tags),
      testCase "resolved tags add resolution and outcome identities deterministically" do
        (verdicts, resolutions) <- readValidatedContracts
        verdict <- itemAt "target-suspect verdict" 1 verdicts
        resolution <- itemAt "accepted resolution" 0 resolutions
        let envelope = ResolvedReview verdict resolution
            tags = practiceReviewTags envelope
            PracticeReviewResolution {resolutionId} = validatedResolutionValue resolution
        practiceReviewTags envelope @?= tags
        assertBool "resolved state" (Set.member "state:resolved" tags)
        assertBool "resolution id" (Set.member ("resolution:" <> resolutionIdText resolutionId) tags)
        assertBool "accepted outcome" (Set.member "outcome:accepted" tags)
    ]

postgresTests :: DatabaseFixture -> TestTree
postgresTests databaseFixture =
  testGroup
    "PostgreSQL transitions"
    [ testCase "allocation receipts converge concurrently and refuse changed bindings" do
        withReviewEnv databaseFixture \app session -> do
          trigger <- readFixture "trigger-valid.json" >>= decodeOrFail >>= expectRight . validateTrigger
          let creator = CompatibilityAgent (fixtureAgentName "opentelemetry-practice-reviewer")
              reserve = IdentityStore.reserveReviewIdentity app creator trigger (fixturePracticeKey "opentelemetry") (fixtureAgentName "opentelemetry-practice-reviewer")
          gate <- newEmptyMVar
          left <- newEmptyMVar
          right <- newEmptyMVar
          _ <- forkFinally (readMVar gate >> reserve) (putMVar left)
          _ <- forkFinally (readMVar gate >> reserve) (putMVar right)
          putMVar gate ()
          first <- takeMVar left >>= expectThread >>= expectRight
          second <- takeMVar right >>= expectThread >>= expectRight
          first @?= second
          recovered <- reserve >>= expectRight
          recovered @?= first
          eitherDecode (encode recovered) @?= Right recovered
          changedPath <- expectRight (mkRelativePath "docs/adr/changed.md")
          changed <- expectRight (validateTrigger (validatedTriggerValue trigger & #changedDecisionPaths .~ [changedPath]))
          conflict <- IdentityStore.reserveReviewIdentity app creator changed (fixturePracticeKey "opentelemetry") (fixtureAgentName "opentelemetry-practice-reviewer")
          assertBool "changed trigger reused receipt" (isLeft conflict)
          other <- IdentityStore.reserveReviewIdentity app (CompatibilityAgent (fixtureAgentName "another-reviewer")) trigger (fixturePracticeKey "opentelemetry") (fixtureAgentName "opentelemetry-practice-reviewer") >>= expectRight
          assertBool "creators shared an allocation" (allocatedReviewId other /= allocatedReviewId first)
          (verdicts, _) <- readAllocatedContracts app
          verdict <- itemAt "target-suspect verdict" 1 verdicts
          forged <- expectRight (validateVerdict (validatedVerdictValue verdict & #reviewId .~ allocatedReviewId other & #triggerIdempotencyKey .~ (validatedTriggerValue trigger).idempotencyKey))
          IdentityStore.verifyReviewIdentity app (CompatibilityAgent (fixtureAgentName "another-reviewer")) other forged >>= (@?= Right ())
          refusal <- IdentityStore.verifyReviewIdentity app creator other forged
          assertBool "parsed reference established ownership" (isLeft refusal)
          refusedWrite <- runReviewOperation app session (WorkflowId "forged-reference") (ReviewMemory.rememberProvisional other Nothing forged) >>= expectCompleted
          case refusedWrite of Left (ReviewMemoryRefused _) -> pure (); unexpected -> assertFailure (show unexpected)
          activePracticeRows app (fixturePracticeKey "opentelemetry") >>= (\rows -> length rows @?= 0)
          -- Allocation is durable without a successful workflow/journal response.
          runReviewOperation app session (WorkflowId "allocation-recovery") (reserveReviewIdentity trigger (fixturePracticeKey "opentelemetry") (fixtureAgentName "opentelemetry-practice-reviewer")) >>= expectCompleted >>= (\value -> value @?= Right first),
      testCase "resolution receipts recover the same entity and bind the complete command" do
        withReviewEnv databaseFixture \app _ -> do
          (_, resolutions) <- readAllocatedContracts app
          resolution <- itemAt "accepted resolution" 0 resolutions
          let creator = CompatibilityAgent (fixtureAgentName "opentelemetry-practice-reviewer")
              request = requestFor resolution
          concurrent <- replicateConcurrently 8 (IdentityStore.reserveResolutionIdentity app creator request) >>= traverse expectRight
          concurrent @?= replicate 8 resolution
          recovered <- IdentityStore.reserveResolutionIdentity app creator request >>= expectRight
          recovered @?= resolution
          let raw = Review.validatedResolutionRequestValue request
          changed <- expectRight (validateResolutionRequest (raw & #reason .~ "different adjudication"))
          conflict <- IdentityStore.reserveResolutionIdentity app creator changed
          assertBool "changed command reused an allocated resolution" (isLeft conflict)
          wrongOwner <- IdentityStore.reserveResolutionIdentity app (CompatibilityAgent (fixtureAgentName "another-reviewer")) request
          assertBool "another creator recovered a resolution" (isLeft wrongOwner)
          IdentityStore.reserveResolutionIdentity app creator request >>= (\result -> result @?= Right recovered),
      testCase "identity store transport failure is not journaled as a permanent refusal" do
        withReviewEnv databaseFixture \app session -> do
          trigger <- readFixture "trigger-valid.json" >>= decodeOrFail >>= expectRight . validateTrigger
          withStore app.connectionSettings \store -> Pool.use store.pool (Session.script "DROP TABLE shikigami.practice_review_identities") >>= expectRight
          result <- try @SomeException (runReviewOperation app session (WorkflowId "identity-store-unavailable") (reserveReviewIdentity trigger (fixturePracticeKey "opentelemetry") (fixtureAgentName "opentelemetry-practice-reviewer")))
          case result of Left _ -> pure (); Right (Left _) -> pure (); unexpected -> assertFailure (show unexpected)
          journal <- loadReviewStepIndex app (WorkflowId "identity-store-unavailable")
          assertBool "transport failure became a journaled result" (Map.notMember "practice-review-reserve-identity" journal),
      testCase "journals provisional replay with one row and refuses semantic drift" do
        (withReviewEnv databaseFixture) \appEnv session -> do
          (verdicts, _) <- readAllocatedContracts appEnv
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

          scopeRows <- activePracticeRows appEnv (fixturePracticeKey "opentelemetry")
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
          (verdicts, resolutions) <- readAllocatedContracts appEnv
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

          activeRows <- activePracticeRows appEnv (fixturePracticeKey "opentelemetry")
          Set.fromList (idText <$> resolvedIds) @?= Set.fromList (rowMemoryId <$> activeRows),
      testCase "a newer review retires the prior resolution and preserves the full chain" do
        (withReviewEnv databaseFixture) \appEnv session -> do
          (verdicts, resolutions) <- readAllocatedContracts appEnv
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
          (verdicts, _) <- readAllocatedContracts appEnv
          verdict <- itemAt "target-suspect verdict" 1 verdicts
          misplacedId <-
            seedReviewContent
              appEnv
              session
              (fixturePracticeKey "logging")
              (encodePracticeReviewMemory (ProvisionalReview verdict))
          recalled <-
            runRecall
              appEnv
              session
              (WorkflowId "practice-review-recall-wrong-scope")
              (recallContextFor (fixturePracticeKey "logging") Nothing Set.empty)
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
          (verdicts, resolutions) <- readAllocatedContracts appEnv
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

          activeRows <- activePracticeRows appEnv (fixturePracticeKey "opentelemetry")
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
  (forall es. (PracticeReviewMemory :> es, IOE :> es) => Eff es result) ->
  IO (Either StoreError (WorkflowOutcome result))
runReviewOperation = runReviewOperationWith reviewRunOptions

runReviewOperationWith ::
  WorkflowRunOptions ->
  AppEnv ->
  SessionId ->
  WorkflowId ->
  (forall es. (PracticeReviewMemory :> es, IOE :> es) => Eff es result) ->
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
          identity = CompatibilityAgent (fixtureAgentName "opentelemetry-practice-reviewer"),
          sessionId = Just session
        }

reviewRunOptions :: WorkflowRunOptions
reviewRunOptions = defaultWorkflowRunOptions

reviewAgentDecl :: AgentDecl
reviewAgentDecl =
  AgentDecl
    { name = fixtureAgentName "opentelemetry-practice-reviewer",
      description = "practice-review memory integration test agent",
      trigger = Event {eventType = declarationCoordinate ("architecture.practice-review.test")},
      behavior = Deterministic {rule = "practice-review-memory-test", params = mempty},
      sinks = [],
      delegates = map fixtureAgentName [],
      delegationBudget = Nothing,
      sanctionedProfile = Nothing,
      capabilityOverlays = [],
      identity = Nothing,
      memory = defaultMemoryPolicy,
      enabled = agentEnablement (True),
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
    (fixturePracticeKey "opentelemetry")
    "{\"schemaVersion\":99}"

seedReviewContent :: AppEnv -> SessionId -> PracticeKey -> Text -> IO MemoryId
seedReviewContent appEnv session practice content = do
  memoryId <- genMemoryId
  recordedAt <- getCurrentTime
  let agentName = "opentelemetry-practice-reviewer"
      recordedIdentity = CompatibilityAgent (fixtureAgentName agentName)
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
  identifier <- newResolutionId
  let acceptedValue = validatedResolutionValue accepted
      commandKey = reviewResolutionKey "race-rejected"
      rejectedValue =
        acceptedValue
          & #resolutionId
            .~ identifier
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
    { projects = [ProjectRef "target" (repositoryId "repo_target")],
      paths = [path],
      dependencies = [reviewDependencyName "hs-opentelemetry-api"],
      practices = [fixturePracticeKey "opentelemetry"]
    }

pathOnly :: RelativePath -> Applicability
pathOnly path = Applicability [] [path] [] []

emptyApplicability :: Applicability
emptyApplicability = Applicability [] [] [] []

recallContext :: Maybe RelativePath -> Set.Set Text -> ReviewRecallContext
recallContext = recallContextFor (fixturePracticeKey "opentelemetry")

recallContextFor :: PracticeKey -> Maybe RelativePath -> Set.Set Text -> ReviewRecallContext
recallContextFor practice path dependencies =
  ReviewRecallContext
    { project = ProjectRef "target" (repositoryId "repo_target"),
      path,
      dependencies = Set.map reviewDependencyName dependencies,
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

fixtureAgentName :: Text -> AgentName
fixtureAgentName = either (error . show) id . mkAgentName

fixturePracticeKey :: Text -> PracticeKey
fixturePracticeKey = either (error . show) id . parsePracticeKey

fixtureReviewId :: Text -> ReviewId
fixtureReviewId = either (error . show) id . parseReviewId

fixtureResolutionId :: Text -> ResolutionId
fixtureResolutionId = either (error . show) id . parseResolutionId

requestFor :: ValidatedPracticeReviewResolution -> Review.ValidatedResolutionRequest
requestFor validated =
  let PracticeReviewResolution {schemaVersion, idempotencyKey, reviewId, outcome, resolver, reason, resolvedAt, resultingApplicability, supersedingReviewId} = validatedResolutionValue validated
   in either (error . show) id (validateResolutionRequest PracticeReviewResolutionRequest {schemaVersion, idempotencyKey, reviewId, outcome, resolver, reason, resolvedAt, resultingApplicability, supersedingReviewId})

triggerFor :: ValidatedPracticeReviewVerdict -> IO Review.ValidatedPracticeReviewTrigger
triggerFor validated = do
  template <- readFixture "trigger-valid.json" >>= decodeOrFail
  let PracticeReviewVerdict {triggerIdempotencyKey} = validatedVerdictValue validated
  expectRight (validateTrigger (template & #idempotencyKey .~ triggerIdempotencyKey))

rememberProvisional :: (PracticeReviewMemory :> es, IOE :> es) => Maybe MemoryId -> ValidatedPracticeReviewVerdict -> Eff es (Either ReviewMemoryError MemoryId)
rememberProvisional prior verdict = do
  let PracticeReviewVerdict {practice, specialist} = validatedVerdictValue verdict
  trigger <- Effectful.liftIO (triggerFor verdict)
  reference <- reserveReviewIdentity trigger practice specialist
  case reference of
    Left problem -> pure (Left problem)
    Right allocated -> ReviewMemory.rememberProvisional allocated prior verdict

resolveReview :: (PracticeReviewMemory :> es) => MemoryId -> ValidatedPracticeReviewResolution -> Eff es (Either ReviewMemoryError MemoryId)
resolveReview provisional resolution = fmap (fmap (\ResolvedPracticeReview {memoryId} -> memoryId)) (ReviewMemory.resolveReview provisional (requestFor resolution))

readAllocatedContracts :: AppEnv -> IO ([ValidatedPracticeReviewVerdict], [ValidatedPracticeReviewResolution])
readAllocatedContracts app = do
  (verdicts, resolutions) <- readValidatedContracts
  pairs <- traverse allocate verdicts
  let replace identifier = maybe identifier id (lookup identifier pairs)
  updatedVerdicts <- traverse (expectRight . validateVerdict . (\raw@PracticeReviewVerdict {reviewId} -> raw & #reviewId .~ replace reviewId) . validatedVerdictValue) verdicts
  updatedResolutions <- traverse (allocateCommand replace) resolutions
  pure (updatedVerdicts, updatedResolutions)
  where
    creator = CompatibilityAgent (fixtureAgentName "opentelemetry-practice-reviewer")
    allocate verdict = do
      trigger <- triggerFor verdict
      let PracticeReviewVerdict {reviewId, practice, specialist} = validatedVerdictValue verdict
      reference <- IdentityStore.reserveReviewIdentity app creator trigger practice specialist >>= expectRight
      pure (reviewId, allocatedReviewId reference)
    allocateCommand replace validated = do
      let raw@PracticeReviewResolution {reviewId, supersedingReviewId} = validatedResolutionValue validated
      changed <- expectRight (validateResolution (raw & #reviewId .~ replace reviewId & #supersedingReviewId .~ fmap replace supersedingReviewId))
      IdentityStore.reserveResolutionIdentity app creator (requestFor changed) >>= expectRight

reviewDependencyName :: Text -> ReviewValue.DependencyName
reviewDependencyName = either (error . show) id . ReviewValue.parseDependencyName

reviewResolutionKey :: Text -> ReviewValue.ResolutionKey
reviewResolutionKey = either (error . show) id . ReviewValue.parseResolutionKey
