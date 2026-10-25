{-# LANGUAGE AllowAmbiguousTypes #-}

module Shikigami.PracticeReviewOrchestrationSpec (tests) where

import Control.Concurrent (forkIO, newEmptyMVar, putMVar, takeMVar)
import Control.Exception (SomeException, try)
import Control.Lens ((&), (.~))
import Control.Monad (forM_)
import Data.Aeson (FromJSON, Value (..), eitherDecode, encode)
import Data.Aeson qualified as Aeson
import Data.Aeson.Key (Key)
import Data.Aeson.KeyMap qualified as KeyMap
import Data.ByteString qualified as ByteString
import Data.ByteString.Lazy qualified as LazyByteString
import Data.Generics.Labels ()
import Data.IORef (IORef, modifyIORef', newIORef, readIORef)
import Data.Int (Int64)
import Data.Map.Strict qualified as Map
import Data.Set qualified as Set
import Data.Text (Text)
import Data.Time (UTCTime (..), fromGregorian, secondsToNominalDiffTime)
import Effectful (runEff)
import Effectful.Error.Static (runErrorNoCallStack)
import Hasql.Decoders qualified as Decoders
import Hasql.Encoders qualified as Encoders
import Hasql.Pool qualified as Pool
import Hasql.Session qualified as Session
import Hasql.Statement (Statement, preparable)
import Keiro.Outbox (listOutbox)
import Keiro.Workflow (WorkflowId (..), WorkflowName (..), WorkflowOutcome (..), loadStepIndex, runWorkflowWith)
import Kioku.App (AppEnv (..), noopTracer, runAppIO)
import Kioku.Id (SessionId, genSessionId, idText)
import Kioku.Id qualified as NominalId
import Kiroku.Store.Connection (KirokuStore (..), defaultConnectionSettings, withStore)
import Kiroku.Store.Effect (runStoreResource)
import Kiroku.Store.Effect.Resource (withKirokuStore)
import Kiroku.Store.Error (StoreError)
import Shikigami.Action.Authorization (allowAllActionAuthorizerForTests)
import Shikigami.Activity (ActivityEnvelope (..), Actor (..), Subject (..))
import Shikigami.Agent.Approval (autoApprovePolicy)
import Shikigami.Agent.Approval.Workflow qualified as ApprovalWorkflow
import Shikigami.Agent.Decl (AgentDecl (..), Behavior (..), RecordPolicy (Never), Trigger (..), defaultDelegationBudget, defaultMemoryPolicy)
import Shikigami.Agent.Delegate.Depth (DelegationDepth (..))
import Shikigami.Agent.Name (AgentName (..))
import Shikigami.Agent.Principal (ResolvedAgentIdentity (CompatibilityAgent), compatibilityIdentity)
import Shikigami.Agent.Run (AgentRunResult (..))
import Shikigami.Agent.Run.Key (RunKey (..))
import Shikigami.Agent.RunJob (RunJob (..), RunRouteKind (AgentWorkflowRoute), TriggerKind (TriggeredByEvent))
import Shikigami.Agent.Workflow qualified as AgentWorkflow
import Shikigami.Attestation.Resolve (ProfileResolutionError (UnknownProfile))
import Shikigami.Behavior.Run (BehaviorEnv, newBehaviorEnv)
import Shikigami.Capability.Provider qualified as CapabilityProvider
import Shikigami.Directory (disabledDirectoryHandle)
import Shikigami.Fixture.SinkHttp (testSinkHttp)
import Shikigami.Flow.Capability (SinkEnv (..), runSink)
import Shikigami.Flow.OpenTelemetryPracticeReview (opentelemetryPracticeReviewFlow)
import Shikigami.Flow.Routing qualified as Routing
import Shikigami.Log qualified as Log
import Shikigami.Migrations.TestSupport (DatabaseFixture, withShikigamiFreshDatabase)
import Shikigami.PracticeReview
  ( ClaimId (..),
    ClaimKind (Fact),
    ContentReference (..),
    EvidenceItem (..),
    ExceptionApproval (..),
    OwnerPrincipal (..),
    PracticeAdoptionBinding (..),
    PracticeKey (..),
    PracticeReviewClaim (..),
    PracticeReviewClassification (..),
    PracticeReviewResolution (..),
    PracticeReviewTrigger (..),
    PracticeReviewVerdict (..),
    ResolutionOutcome (..),
    ReviewId (..),
    ReviewLineage (..),
    deriveResolutionId,
    deriveReviewId,
    validateResolution,
    validateVerdict,
    validatedVerdictValue,
  )
import Shikigami.PracticeReview.Attention
  ( AttentionKey (..),
    PracticeReviewAttentionEnv (..),
    deriveAttentionKey,
    runPracticeReviewAttentionAtomic,
  )
import Shikigami.PracticeReview.Authorization
  ( AuthorizedPracticeReviewResolution (..),
    AuthorizedResolutionReceipt (authorizationId),
    ResolutionAuthorityKind (Human),
    ResolutionAuthorizationError (..),
    mkAuthorizedResolutionReceipt,
    validateAuthorizedPracticeReviewResolution,
  )
import Shikigami.PracticeReview.Capability
  ( AttentionRecipientMap,
    AttentionReservationResult (..),
    PracticeReviewExecutionContext (..),
    PracticeReviewRuntime (..),
    emptyAttentionRecipientMap,
    mkAttentionRecipientMap,
    requestPracticeReviewAttention,
    runExecutionContext,
    runPracticeReviewAttention,
    runPracticeReviewEvaluator,
    runPracticeReviewEvidence,
  )
import Shikigami.PracticeReview.Evidence
  ( DependencyPinResolver (..),
    EvidenceBundle (..),
    EvidenceReadError (ContentPlaneUnavailable),
    EvidenceReader (..),
    EvidenceSource (..),
  )
import Shikigami.PracticeReview.Memory
  ( PracticeReviewMemoryEnv (..),
    runPracticeReviewMemory,
  )
import Shikigami.PracticeReviewEvidenceSpec
  ( completeDependencyPinResolver,
    completeEvidenceReader,
    completeOpenTelemetryReferenceChangeTrigger,
    completeOpenTelemetryTrigger,
    completeReferenceRevision,
  )
import Shikigami.Repository (RepoRef (..), revisionText)
import Shikigami.Sink.Config (DanwaConfig (..), KanmonConfig (..), KawaConfig (..), KizashiConfig (..), ReiConfig (..))
import Shikigami.Sink.GrantStore (GrantSource (StaticGrants))
import Shikigami.Sink.Permission (SinkKind (SKawaDigest, SKizashiSignal))
import Shikigami.Workflow.Versioning (shikigamiWorkflowRunOptions)
import System.Directory (doesFileExist)
import System.FilePath ((</>))
import Test.Tasty (TestTree, testGroup)
import Test.Tasty.HUnit (assertBool, assertFailure, testCase, (@?=))

tests :: DatabaseFixture -> TestTree
tests databaseFixture =
  testGroup
    "practice review orchestration"
    [ authorizationTests,
      attentionIdentityTests,
      (completeClassificationTests databaseFixture),
      (agentRunSpecialistTests databaseFixture),
      (replayTests databaseFixture),
      (atomicAttentionTests databaseFixture)
    ]

authorizationTests :: TestTree
authorizationTests =
  testGroup
    "authorized resolution"
    [ testCase "valid receipt round-trips and remains bound to the resolution" do
        resolution <- firstResolution
        validated <- expectRight (validateResolution resolution)
        receipt <- expectRight (mkAuthorizedResolutionReceipt Human (resolverOf resolution) "mori://shinzui/shikigami/reviews/approval-1" (resolvedAtOf resolution) validated)
        let envelope = AuthorizedPracticeReviewResolution {schemaVersion = 1, resolution, authorization = receipt}
        decoded <- decodeOrFail (encode envelope)
        validateAuthorizedPracticeReviewResolution decoded @?= Right (validated, receipt)
        (.authorizationId) receipt @?= "7898dedb-294d-5f61-872b-211c0df7c6af",
      testCase "subject mismatch, disallowed source, and altered receipt are refused" do
        resolution <- firstResolution
        validated <- expectRight (validateResolution resolution)
        mismatched <- expectRight (mkAuthorizedResolutionReceipt Human (OwnerPrincipal "different-subject") "activity://approval/1" (resolvedAtOf resolution) validated)
        let mismatchedEnvelope = AuthorizedPracticeReviewResolution {schemaVersion = 1, resolution, authorization = mismatched}
        assertBool "subject mismatch was accepted" (isSubjectMismatch (validateAuthorizedPracticeReviewResolution mismatchedEnvelope))
        assertBool
          "noncanonical authorization source was accepted"
          (isSourceInvalid (mkAuthorizedResolutionReceipt Human (resolverOf resolution) "https://example.invalid/approval" (resolvedAtOf resolution) validated))
        validReceipt <- expectRight (mkAuthorizedResolutionReceipt Human (resolverOf resolution) "activity://approval/1" (resolvedAtOf resolution) validated)
        let validEnvelope = AuthorizedPracticeReviewResolution {schemaVersion = 1, resolution, authorization = validReceipt}
        altered <- decodeOrFail (encode (alterAuthorizationId "altered" (Aeson.toJSON validEnvelope)))
        assertBool "altered authorization id was accepted" (isIdInvalid (validateAuthorizedPracticeReviewResolution altered)),
      testCase "authorization decoders reject unknown envelope and receipt fields" do
        resolution <- firstResolution
        validated <- expectRight (validateResolution resolution)
        receipt <- expectRight (mkAuthorizedResolutionReceipt Human (resolverOf resolution) "activity://approval/1" (resolvedAtOf resolution) validated)
        let envelope = AuthorizedPracticeReviewResolution {schemaVersion = 1, resolution, authorization = receipt}
        assertDecodeFailure @AuthorizedPracticeReviewResolution (insertObjectField "unexpected" Aeson.Null (Aeson.toJSON envelope))
        assertDecodeFailure @AuthorizedPracticeReviewResolution (insertAuthorizationField "unexpected" Aeson.Null (Aeson.toJSON envelope))
    ]

attentionIdentityTests :: TestTree
attentionIdentityTests =
  testGroup
    "attention identity"
    [ testCase "frozen target-suspect vector is stable across whitespace normalization" do
        verdict <- targetSuspectVerdict
        validated <- expectRight (validateVerdict verdict)
        recipients <- expectRight (mkAttentionRecipientMap [("team-example-service", "recipient_target")])
        key <- expectRight (deriveAttentionKey recipients validated)
        key @?= AttentionKey "4978b57a-1a3d-5210-b82d-671276f2c485"
        normalized <- expectRight (validateVerdict (verdict & #recommendedAction .~ "  Ask   the target owner to reconcile the decision.  "))
        deriveAttentionKey recipients normalized @?= Right key,
      testCase "recipient and material action changes produce distinct attention keys" do
        verdict <- targetSuspectVerdict
        validated <- expectRight (validateVerdict verdict)
        recipientsA <- expectRight (mkAttentionRecipientMap [("team-example-service", "recipient_target")])
        recipientsB <- expectRight (mkAttentionRecipientMap [("team-example-service", "recipient_other")])
        changed <- expectRight (validateVerdict (verdict & #recommendedAction .~ "Escalate the target decision to its owner."))
        key <- expectRight (deriveAttentionKey recipientsA validated)
        assertBool "recipient did not affect attention identity" (deriveAttentionKey recipientsB validated /= Right key)
        assertBool "material action did not affect attention identity" (deriveAttentionKey recipientsA changed /= Right key)
    ]

completeClassificationTests :: DatabaseFixture -> TestTree
completeClassificationTests databaseFixture =
  testCase "complete evidence covers every model classification and approval attention branch" do
    verdicts <- readFixture "verdicts-valid.json" >>= decodeOrFail . LazyByteString.fromStrict
    (consistent, targetSuspect, referenceSuspect, exceptionRequired) <-
      case verdicts of
        first : second : third : fourth : _ -> pure (first, second, third, fourth)
        _ -> assertFailure "complete verdict fixtures are absent"
    let exceptionWithoutApproval =
          exceptionRequired
            & #exceptionApproval .~ NoApproval
            & #recommendedOwner .~ Nothing
        cases =
          [ ("consistent", Consistent, consistent, False),
            ("target-suspect", TargetSuspect, targetSuspect, True),
            ("reference-suspect", ReferenceSuspect, referenceSuspect, True),
            ("legitimate-exception-required", LegitimateException, exceptionRequired, True),
            ("legitimate-exception-approved", LegitimateException, exceptionWithoutApproval, False)
          ]
    (withShikigamiFreshDatabase databaseFixture) \connectionString ->
      withStore (defaultConnectionSettings connectionString) \_store -> do
        tracer <- noopTracer
        behaviorEnv <- newBehaviorEnv
        let appEnv = AppEnv {connectionSettings = defaultConnectionSettings connectionString, tracer, metrics = Nothing}
        forM_ cases \(label, expectedClassification, proposal, expectsAttention) -> do
          session <- genSessionId
          evidenceCalls <- newIORef 0
          evaluatorCalls <- newIORef 0
          attentionCalls <- newIORef 0
          let runtime = completeRuntime evidenceCalls evaluatorCalls attentionCalls proposal
              workflowId = WorkflowId ("practice-review-complete-" <> label)
              trigger = Aeson.toJSON (completeOpenTelemetryTrigger ("complete-" <> label))
              runOnce = runPracticeReviewInput appEnv behaviorEnv session runtime workflowId trigger
          first <- runOnce
          assertReviewOutcome expectedClassification expectsAttention first
          firstEvidenceCalls <- readIORef evidenceCalls
          assertBool "complete fixture reader was never called" (firstEvidenceCalls > 0)
          readIORef evaluatorCalls >>= (@?= 1)
          readIORef attentionCalls >>= (@?= if expectsAttention then 1 else 0)

          replayed <- runOnce
          replayed @?= first
          readIORef evidenceCalls >>= (@?= firstEvidenceCalls)
          readIORef evaluatorCalls >>= (@?= 1)
          readIORef attentionCalls >>= (@?= if expectsAttention then 1 else 0)
        outbox <- runAppIO appEnv (listOutbox "shinzui/shikigami")
        fmap length outbox @?= Right (length cases)

        reReviewSession <- genSessionId
        reReviewEvidenceCalls <- newIORef 0
        reReviewEvaluatorCalls <- newIORef 0
        reReviewAttentionCalls <- newIORef 0
        let priorTrigger = completeOpenTelemetryTrigger "complete-consistent"
            priorReviewId = deriveReviewId priorTrigger (PracticeKey "opentelemetry") reviewerAgent
            reReviewTrigger = completeOpenTelemetryReferenceChangeTrigger "complete-reference-change" priorReviewId
            reReviewRuntime = completeRuntime reReviewEvidenceCalls reReviewEvaluatorCalls reReviewAttentionCalls referenceSuspect
            reReviewWorkflowId = WorkflowId "practice-review-complete-reference-change"
            runReReview = runPracticeReviewInput appEnv behaviorEnv reReviewSession reReviewRuntime reReviewWorkflowId (Aeson.toJSON reReviewTrigger)
        reReviewed <- runReReview
        assertReviewOutcome ReferenceSuspect True reReviewed
        assertReferenceChangeOutcome priorReviewId completeReferenceRevision reReviewed
        reReviewEvidenceCount <- readIORef reReviewEvidenceCalls
        assertBool "reference re-review did not acquire evidence" (reReviewEvidenceCount > 0)
        readIORef reReviewEvaluatorCalls >>= (@?= 1)
        readIORef reReviewAttentionCalls >>= (@?= 1)
        reReviewedReplay <- runReReview
        reReviewedReplay @?= reReviewed
        readIORef reReviewEvidenceCalls >>= (@?= reReviewEvidenceCount)
        readIORef reReviewEvaluatorCalls >>= (@?= 1)
        readIORef reReviewAttentionCalls >>= (@?= 1)

        let resolutionCases =
              [ ("accepted", Accepted, True, False),
                ("rejected", Rejected, False, False),
                ("narrowed", Narrowed, True, False),
                ("superseded", Superseded, False, True)
              ]
        forM_ (zip resolutionCases (drop 1 cases)) \((resolutionLabel, outcome, retainsApplicability, isSuperseded), (reviewLabel, _, _, _)) -> do
          session <- genSessionId
          evidenceCalls <- newIORef 0
          evaluatorCalls <- newIORef 0
          attentionCalls <- newIORef 0
          let reviewedTrigger@PracticeReviewTrigger {adoptions} = completeOpenTelemetryTrigger ("complete-" <> reviewLabel)
              reviewId = deriveReviewId reviewedTrigger (PracticeKey "opentelemetry") reviewerAgent
              resultingApplicability =
                case adoptions of
                  PracticeAdoptionBinding {claimedApplicability} : _
                    | retainsApplicability -> Just claimedApplicability
                  _ -> Nothing
              supersedingReviewId
                | isSuperseded = Just (deriveReviewId (completeOpenTelemetryTrigger "complete-superseding-review") (PracticeKey "opentelemetry") reviewerAgent)
                | otherwise = Nothing
              commandKey = "complete-resolution-" <> resolutionLabel
              resolution =
                PracticeReviewResolution
                  { schemaVersion = 1,
                    resolutionId = deriveResolutionId reviewId commandKey,
                    idempotencyKey = commandKey,
                    reviewId,
                    outcome,
                    resolver = OwnerPrincipal "architecture-council",
                    reason = "Verified orchestration resolution fixture.",
                    resolvedAt = UTCTime (fromGregorian 2026 8 26) 0,
                    resultingApplicability,
                    supersedingReviewId
                  }
          validatedResolution <- expectRight (validateResolution resolution)
          receipt <-
            expectRight
              ( mkAuthorizedResolutionReceipt
                  Human
                  (OwnerPrincipal "architecture-council")
                  ("activity://approval/" <> resolutionLabel)
                  (resolvedAtOf resolution)
                  validatedResolution
              )
          let envelope = AuthorizedPracticeReviewResolution {schemaVersion = 1, resolution, authorization = receipt}
              runtime = completeRuntime evidenceCalls evaluatorCalls attentionCalls consistent
              workflowId = WorkflowId ("practice-review-complete-resolution-" <> resolutionLabel)
              runOnce = runPracticeReviewInput appEnv behaviorEnv session runtime workflowId (Aeson.toJSON envelope)
          resolved <- runOnce
          assertResolutionOutcome resolved
          replayed <- runOnce
          replayed @?= resolved
          readIORef evidenceCalls >>= (@?= 0)
          readIORef evaluatorCalls >>= (@?= 0)
          readIORef attentionCalls >>= (@?= 0)
        outboxAfterResolutions <- runAppIO appEnv (listOutbox "shinzui/shikigami")
        fmap length outboxAfterResolutions @?= Right (length cases + 1 + length resolutionCases)

agentRunSpecialistTests :: DatabaseFixture -> TestTree
agentRunSpecialistTests databaseFixture =
  testCase "real AgentRun installs review patches, recorded lineage, memory, grants, and atomic attention" do
    let trigger = completeOpenTelemetryTrigger "agent-run-incomplete"
    (withShikigamiFreshDatabase databaseFixture) \connectionString ->
      withStore (defaultConnectionSettings connectionString) \KirokuStore {pool} -> do
        tracer <- noopTracer
        behaviorEnv <- newBehaviorEnv
        parentSession <- genSessionId
        evidenceCalls <- newIORef 0
        evaluatorCalls <- newIORef 0
        legacyAttentionCalls <- newIORef 0
        recipients <- expectRight (mkAttentionRecipientMap [("architecture-council", "recipient_triage")])
        let appEnv = AppEnv {connectionSettings = defaultConnectionSettings connectionString, tracer, metrics = Nothing}
            baseRuntime = incompleteRuntime evidenceCalls evaluatorCalls legacyAttentionCalls
            runtime = baseRuntime {attentionRecipients = recipients}
            deps = specialistAgentRunDeps appEnv behaviorEnv runtime
            job =
              RunJob
                { agentName = AgentName reviewerAgent,
                  identity = compatibilityIdentity reviewerAgent,
                  triggerKind = TriggeredByEvent,
                  routeKind = AgentWorkflowRoute,
                  occurredAt = UTCTime (fromGregorian 2026 8 26) 0,
                  triggerPayload = Aeson.toJSON trigger,
                  idempotencyKey = RunKey "agent-run-practice-review-incomplete",
                  parentSessionId = Just parentSession,
                  parentRunWorkflowId = Just (WorkflowId "architecture-practice-router-parent"),
                  delegationDepth = Just (DelegationDepth 1),
                  lineage = map AgentName ["architecture-practice-router", reviewerAgent],
                  delegationBudgetId = Nothing
                }
        first <- AgentWorkflow.runAgentRunWorkflow deps job
        case first of
          Right (Completed (Right AgentRunResult {behaviorOutput})) ->
            assertReviewValue Unresolved True behaviorOutput
          other -> assertFailure ("real specialist AgentRun did not complete: " <> show other)
        firstEvidenceCount <- readIORef evidenceCalls
        assertBool "real specialist did not acquire evidence" (firstEvidenceCount > 0)
        readIORef evaluatorCalls >>= (@?= 0)
        readIORef legacyAttentionCalls >>= (@?= 0)

        replayed <- AgentWorkflow.runAgentRunWorkflow deps job
        replayed @?= first
        readIORef evidenceCalls >>= (@?= firstEvidenceCount)
        readIORef evaluatorCalls >>= (@?= 0)
        readIORef legacyAttentionCalls >>= (@?= 0)
        outbox <- runAppIO appEnv (listOutbox "shinzui/shikigami")
        fmap length outbox @?= Right 2
        counts <-
          Pool.use pool (Session.statement () attentionCountsStatement)
            >>= either (assertFailure . show) pure
        counts @?= (1, 1, 1)
        steps <- runAppIO appEnv (loadStepIndex AgentWorkflow.agentRunWorkflowName (WorkflowId "agent-run-practice-review-incomplete") 0)
        case steps of
          Left problem -> assertFailure (show problem)
          Right index -> do
            assertBool "real AgentRun omitted the evidence step" (Map.member "practice-review-evidence" index)
            assertBool "real AgentRun omitted the attention step" (Map.member "practice-review-attention" index)
            assertBool "incomplete real AgentRun invoked the evaluator" (Map.notMember "practice-review-evaluate" index)

replayTests :: DatabaseFixture -> TestTree
replayTests databaseFixture =
  testGroup
    "replay"
    [ testCase "incomplete evidence skips evaluation and replays every external result" do
        triggerBytes <- readFixture "trigger-valid.json"
        trigger <- decodeOrFail (LazyByteString.fromStrict triggerBytes) :: IO Value
        contractTrigger <- decodeOrFail (LazyByteString.fromStrict triggerBytes) :: IO PracticeReviewTrigger
        (withShikigamiFreshDatabase databaseFixture) \connectionString ->
          withStore (defaultConnectionSettings connectionString) \_store -> do
            tracer <- noopTracer
            behaviorEnv <- newBehaviorEnv
            session <- genSessionId
            evidenceCalls <- newIORef 0
            evaluatorCalls <- newIORef 0
            attentionCalls <- newIORef 0
            let appEnv = AppEnv {connectionSettings = defaultConnectionSettings connectionString, tracer, metrics = Nothing}
                runtime = incompleteRuntime evidenceCalls evaluatorCalls attentionCalls
                workflowId = WorkflowId "practice-review-incomplete-replay"
                runInput :: WorkflowId -> Value -> IO (Either StoreError (WorkflowOutcome Value))
                runInput selectedWorkflowId input =
                  runEff
                    . runErrorNoCallStack
                    . withKirokuStore (connectionSettings appEnv)
                    . runStoreResource
                    $ runWorkflowWith
                      (shikigamiWorkflowRunOptions appEnv)
                      (WorkflowName "shikigami.practice-review.test")
                      selectedWorkflowId
                      ( runExecutionContext executionContextFixture
                          . runPracticeReviewEvidence True runtime
                          . runPracticeReviewEvaluator True behaviorEnv runtime
                          . runPracticeReviewMemory
                            PracticeReviewMemoryEnv
                              { appEnv,
                                agent = reviewerDecl,
                                identity = CompatibilityAgent reviewerAgent,
                                sessionId = Just session
                              }
                          . runPracticeReviewAttention True runtime
                          . runSink (sinkEnvFixture session)
                          $ opentelemetryPracticeReviewFlow input
                      )
                runOnce = runInput workflowId trigger
            malformedTrigger <-
              try @SomeException
                ( runInput
                    (WorkflowId "practice-review-unknown-trigger-field")
                    (insertObjectField "unexpected" Aeson.Null trigger)
                )
            assertRunRefused malformedTrigger
            first <- runOnce
            assertUnresolvedOutcome first
            firstEvidenceCalls <- readIORef evidenceCalls
            assertBool "the incomplete reader was never called" (firstEvidenceCalls > 0)
            readIORef evaluatorCalls >>= (@?= 0)
            readIORef attentionCalls >>= (@?= 1)
            outboxAfterFirst <- runAppIO appEnv (listOutbox "shinzui/shikigami")
            fmap length outboxAfterFirst @?= Right 1

            replayed <- runOnce
            assertUnresolvedOutcome replayed
            readIORef evidenceCalls >>= (@?= firstEvidenceCalls)
            readIORef evaluatorCalls >>= (@?= 0)
            readIORef attentionCalls >>= (@?= 1)
            outboxAfterReplay <- runAppIO appEnv (listOutbox "shinzui/shikigami")
            fmap length outboxAfterReplay @?= Right 1
            steps <- runAppIO appEnv (loadStepIndex (WorkflowName "shikigami.practice-review.test") workflowId 0)
            case steps of
              Left problem -> assertFailure (show problem)
              Right index -> do
                assertBool "evidence step is absent" (Map.member "practice-review-evidence" index)
                assertBool "attention step is absent" (Map.member "practice-review-attention" index)
                assertBool "incomplete evidence invoked the evaluator" (Map.notMember "practice-review-evaluate" index)

            let reviewId = deriveReviewId contractTrigger (PracticeKey "opentelemetry") reviewerAgent
                resolution =
                  PracticeReviewResolution
                    { schemaVersion = 1,
                      resolutionId = deriveResolutionId reviewId "resolution-command-fixture",
                      idempotencyKey = "resolution-command-fixture",
                      reviewId,
                      outcome = Rejected,
                      resolver = OwnerPrincipal "architecture-council",
                      reason = "The incomplete advisory review was explicitly rejected by its verified resolver.",
                      resolvedAt = UTCTime (fromGregorian 2026 8 26) 0,
                      resultingApplicability = Nothing,
                      supersedingReviewId = Nothing
                    }
            bareResolution <-
              try @SomeException
                (runInput (WorkflowId "practice-review-bare-resolution") (Aeson.toJSON resolution))
            assertRunRefused bareResolution
            validatedResolution <- expectRight (validateResolution resolution)
            receipt <-
              expectRight
                ( mkAuthorizedResolutionReceipt
                    Human
                    (OwnerPrincipal "architecture-council")
                    "activity://approval/practice-review-fixture"
                    (resolvedAtOf resolution)
                    validatedResolution
                )
            let envelope = AuthorizedPracticeReviewResolution {schemaVersion = 1, resolution, authorization = receipt}
            resolved <- runInput (WorkflowId "practice-review-resolution-replay") (Aeson.toJSON envelope)
            assertResolutionOutcome resolved
            resolvedReplay <- runInput (WorkflowId "practice-review-resolution-replay") (Aeson.toJSON envelope)
            assertResolutionOutcome resolvedReplay
            outboxAfterResolution <- runAppIO appEnv (listOutbox "shinzui/shikigami")
            fmap length outboxAfterResolution @?= Right 2
    ]

atomicAttentionTests :: DatabaseFixture -> TestTree
atomicAttentionTests databaseFixture =
  testGroup
    "atomic attention"
    [ testCase "concurrent equivalent reviews share one reservation, outbox, and receipt" do
        verdict <- targetSuspectVerdict
        trigger <- readFixture "trigger-valid.json" >>= decodeOrFail . LazyByteString.fromStrict
        firstVerdict <- expectRight (validateVerdict verdict)
        let secondTriggerKey = "equivalent-trigger-two"
            PracticeReviewVerdict {practice, specialist} = verdict
            secondReviewId = deriveReviewId (trigger & #idempotencyKey .~ secondTriggerKey) practice specialist
        secondVerdict <-
          expectRight
            ( validateVerdict
                ( verdict
                    & #reviewId .~ secondReviewId
                    & #triggerIdempotencyKey .~ secondTriggerKey
                )
            )
        recipients <- expectRight (mkAttentionRecipientMap [("team-example-service", "recipient_target")])
        (withShikigamiFreshDatabase databaseFixture) \connectionString ->
          withStore (defaultConnectionSettings connectionString) \KirokuStore {pool} -> do
            tracer <- noopTracer
            let appEnv = AppEnv {connectionSettings = defaultConnectionSettings connectionString, tracer, metrics = Nothing}
                runAttention suffix runIdentifier validated =
                  runEff
                    . runErrorNoCallStack
                    . withKirokuStore (connectionSettings appEnv)
                    . runStoreResource
                    $ runWorkflowWith
                      (shikigamiWorkflowRunOptions appEnv)
                      (WorkflowName "shikigami.practice-review.attention-test")
                      (WorkflowId ("practice-review-attention-" <> suffix))
                      ( runPracticeReviewAttentionAtomic
                          (attentionEnv recipients runIdentifier)
                          (Aeson.toJSON <$> requestPracticeReviewAttention validated)
                      )
            resultVars <- traverse (const newEmptyMVar) [firstVerdict, secondVerdict]
            let actions =
                  [ runAttention "one" "run-one" firstVerdict,
                    runAttention "two" "run-two" secondVerdict
                  ]
            sequence_
              [ forkIO (try @SomeException action >>= putMVar resultVar)
              | (action, resultVar) <- zip actions resultVars
              ]
            concurrent <- traverse takeMVar resultVars
            outcomes <- traverse (either (assertFailure . show) pure) concurrent
            reservations <- traverse decodeAttentionOutcome outcomes
            assertBool "no concurrent writer reserved attention" (any isReserved reservations)
            assertBool "no concurrent writer coalesced attention" (any isCoalesced reservations)
            counts <-
              Pool.use pool (Session.statement () attentionCountsStatement)
                >>= either (assertFailure . show) pure
            counts @?= (1, 2, 1)
            outbox <- runAppIO appEnv (listOutbox "shinzui/shikigami")
            fmap length outbox @?= Right 1
    ]

attentionEnv :: AttentionRecipientMap -> Text -> PracticeReviewAttentionEnv
attentionEnv recipients runIdentifier =
  PracticeReviewAttentionEnv
    { agent = reviewerAgent,
      identity = compatibilityIdentity reviewerAgent,
      runId = runIdentifier,
      occurredAt = Nothing,
      activity = Just reviewActivity,
      grants = StaticGrants (Map.singleton reviewerAgent (Set.fromList [SKawaDigest, SKizashiSignal])),
      directory = disabledDirectoryHandle,
      recipients
    }

decodeAttentionOutcome :: Either StoreError (WorkflowOutcome Value) -> IO AttentionReservationResult
decodeAttentionOutcome (Right (Completed value)) =
  case Aeson.fromJSON value of
    Aeson.Error detail -> assertFailure detail
    Aeson.Success result -> pure result
decodeAttentionOutcome _ = assertFailure "attention workflow did not complete"

isReserved :: AttentionReservationResult -> Bool
isReserved Reserved {} = True
isReserved _ = False

isCoalesced :: AttentionReservationResult -> Bool
isCoalesced Coalesced {} = True
isCoalesced _ = False

attentionCountsStatement :: Statement () (Int64, Int64, Int64)
attentionCountsStatement =
  preparable
    """
    SELECT
      (SELECT count(*) FROM shikigami.practice_review_attention),
      (SELECT count(*) FROM shikigami.practice_review_attention_reviews),
      (SELECT count(*) FROM shikigami.sink_deliveries WHERE outbox_message_id LIKE 'practice-review-attention:%')
    """
    Encoders.noParams
    ( Decoders.singleRow
        ( (,,)
            <$> Decoders.column (Decoders.nonNullable Decoders.int8)
            <*> Decoders.column (Decoders.nonNullable Decoders.int8)
            <*> Decoders.column (Decoders.nonNullable Decoders.int8)
        )
    )

specialistAgentRunDeps :: AppEnv -> BehaviorEnv -> PracticeReviewRuntime -> AgentWorkflow.AgentRunDeps
specialistAgentRunDeps appEnv behaviorEnv practiceReview =
  AgentWorkflow.AgentRunDeps
    { AgentWorkflow.appEnv,
      AgentWorkflow.behaviorEnv,
      AgentWorkflow.actionAuthorizer = allowAllActionAuthorizerForTests,
      AgentWorkflow.capabilities = CapabilityProvider.emptyCapabilityRuntime,
      AgentWorkflow.agents = [reviewerDecl],
      AgentWorkflow.kizashi = KizashiConfig {baseUrl = "http://localhost:1", defaultRecipient = "recipient_unused"},
      AgentWorkflow.kawa = KawaConfig {baseUrl = "http://localhost:1", sourceSegment = "shinzui/shikigami"},
      AgentWorkflow.kanmon = KanmonConfig {baseUrl = "http://localhost:1"},
      AgentWorkflow.danwa = DanwaConfig {baseUrl = "http://localhost:1", agentParticipant = "part_agent_practice_review"},
      AgentWorkflow.rei = ReiConfig {baseUrl = Nothing},
      AgentWorkflow.http = testSinkHttp,
      AgentWorkflow.hooks = AgentWorkflow.defaultAgentRunHooks,
      AgentWorkflow.approvalPolicy = autoApprovePolicy (secondsToNominalDiffTime 900),
      AgentWorkflow.approvalWorkflow = ApprovalWorkflow.defaultApprovalWorkflowEnv,
      AgentWorkflow.runTimeout = secondsToNominalDiffTime 300,
      AgentWorkflow.delegationBudget = defaultDelegationBudget,
      AgentWorkflow.logger = Log.silentLogger,
      AgentWorkflow.grants = StaticGrants (Map.singleton reviewerAgent (Set.fromList [SKawaDigest, SKizashiSignal])),
      AgentWorkflow.directory = disabledDirectoryHandle,
      AgentWorkflow.routing = unusedRoutingRuntime,
      AgentWorkflow.practiceReview,
      AgentWorkflow.deliveryPool = Nothing,
      AgentWorkflow.resolveRunProfile = \profileId version -> pure (Left (UnknownProfile profileId version))
    }

unusedRoutingRuntime :: Routing.RoutingRuntime
unusedRoutingRuntime =
  Routing.RoutingRuntime
    { Routing.resolveCatalog = \_ -> fail "specialist AgentRun must not resolve a router catalog",
      Routing.evaluateRoute = \_ _ _ -> pure (Left (Routing.RoutingEvaluationFailed "specialist AgentRun must not evaluate a route"))
    }

runPracticeReviewInput ::
  AppEnv ->
  BehaviorEnv ->
  SessionId ->
  PracticeReviewRuntime ->
  WorkflowId ->
  Value ->
  IO (Either StoreError (WorkflowOutcome Value))
runPracticeReviewInput appEnv behaviorEnv session runtime workflowId input =
  runEff
    . runErrorNoCallStack
    . withKirokuStore (connectionSettings appEnv)
    . runStoreResource
    $ runWorkflowWith
      (shikigamiWorkflowRunOptions appEnv)
      (WorkflowName "shikigami.practice-review.test")
      workflowId
      ( runExecutionContext executionContextFixture
          . runPracticeReviewEvidence True runtime
          . runPracticeReviewEvaluator True behaviorEnv runtime
          . runPracticeReviewMemory
            PracticeReviewMemoryEnv
              { appEnv,
                agent = reviewerDecl,
                identity = CompatibilityAgent reviewerAgent,
                sessionId = Just session
              }
          . runPracticeReviewAttention True runtime
          . runSink (sinkEnvFixture session)
          $ opentelemetryPracticeReviewFlow input
      )

completeRuntime :: IORef Int -> IORef Int -> IORef Int -> PracticeReviewVerdict -> PracticeReviewRuntime
completeRuntime evidenceCalls evaluatorCalls attentionCalls proposal =
  PracticeReviewRuntime
    { evidenceReader = countingEvidenceReader evidenceCalls,
      dependencyPinResolver = completeDependencyPinResolver,
      evaluator = \_ evidence _ -> do
        modifyIORef' evaluatorCalls (+ 1)
        pure (Right (Aeson.toJSON (proposalWithEvidence evidence proposal))),
      attention = \validated -> do
        modifyIORef' attentionCalls (+ 1)
        let PracticeReviewVerdict {reviewId = ReviewId reviewValue} = validatedVerdictValue validated
        pure (Right (Reserved ("attention-" <> reviewValue) ("outbox-" <> reviewValue))),
      attentionRecipients = emptyAttentionRecipientMap
    }

countingEvidenceReader :: IORef Int -> EvidenceReader
countingEvidenceReader calls =
  let EvidenceReader {resolveRef, readBlob, readDiff, readTree, grep} = completeEvidenceReader
      counted :: IO result -> IO result
      counted action = modifyIORef' calls (+ 1) >> action
   in EvidenceReader
        { resolveRef = \repository reference -> counted (resolveRef repository reference),
          readBlob = \reference path -> counted (readBlob reference path),
          readDiff = \repository base headRevision path -> counted (readDiff repository base headRevision path),
          readTree = \reference path page -> counted (readTree reference path page),
          grep = \reference query page -> counted (grep reference query page)
        }

proposalWithEvidence :: EvidenceBundle -> PracticeReviewVerdict -> PracticeReviewVerdict
proposalWithEvidence EvidenceBundle {target, references, upstream} proposal =
  proposal
    { targetEvidence = [],
      referenceEvidence = [],
      upstreamEvidence = [],
      claims =
        [ PracticeReviewClaim
            { claimId = ClaimId "claim-complete-orchestration",
              kind = Fact,
              statement = "The bounded evidence supports the proposed architecture-practice classification.",
              material = True,
              evidenceIds = citationIds
            }
        ]
    }
  where
    citationIds =
      [evidenceId | EvidenceSource {citation = EvidenceItem {evidenceId}} <- target <> references <> upstream]

assertReviewOutcome ::
  PracticeReviewClassification ->
  Bool ->
  Either error (WorkflowOutcome Value) ->
  IO ()
assertReviewOutcome expectedClassification expectsAttention (Right (Completed output)) =
  assertReviewValue expectedClassification expectsAttention output
assertReviewOutcome _ _ _ = assertFailure "complete practice-review flow did not complete"

assertReviewValue :: PracticeReviewClassification -> Bool -> Value -> IO ()
assertReviewValue expectedClassification expectsAttention (Object output) = do
  case KeyMap.lookup "verdict" output of
    Just (Object verdict) -> KeyMap.lookup "classification" verdict @?= Just (Aeson.toJSON expectedClassification)
    other -> assertFailure ("completed output has no verdict: " <> show other)
  let attention = KeyMap.lookup "attention" output
  if expectsAttention
    then assertBool "actionable verdict did not request attention" (attention /= Just Null)
    else attention @?= Just Null
assertReviewValue _ _ _ = assertFailure "practice-review output is not an object"

assertReferenceChangeOutcome ::
  ReviewId ->
  Text ->
  Either error (WorkflowOutcome Value) ->
  IO ()
assertReferenceChangeOutcome expectedPrior expectedRevision (Right (Completed (Object output))) =
  case KeyMap.lookup "verdict" output >>= decodeValue of
    Just PracticeReviewVerdict {lineage = ReviewLineage {priorReviewId}, referenceEvidence} -> do
      priorReviewId @?= Just expectedPrior
      let revisions =
            [ revisionText revision
            | EvidenceItem {content = ContentReference {provenance = RepoRef {revision}}} <- referenceEvidence
            ]
      assertBool "reference re-review did not cite the changed pinned revision" (expectedRevision `elem` revisions)
    Nothing -> assertFailure "reference re-review output has no decodable verdict"
  where
    decodeValue value =
      case Aeson.fromJSON value of
        Aeson.Error _ -> Nothing
        Aeson.Success verdict -> Just verdict
assertReferenceChangeOutcome _ _ _ = assertFailure "reference re-review did not complete"

incompleteRuntime :: IORef Int -> IORef Int -> IORef Int -> PracticeReviewRuntime
incompleteRuntime evidenceCalls evaluatorCalls attentionCalls =
  PracticeReviewRuntime
    { evidenceReader =
        EvidenceReader
          { resolveRef = \_ _ -> unavailable,
            readBlob = \_ _ -> unavailable,
            readDiff = \_ _ _ _ -> unavailable,
            readTree = \_ _ _ -> unavailable,
            grep = \_ _ _ -> unavailable
          },
      dependencyPinResolver = DependencyPinResolver (\_ _ -> Left "fixture unavailable"),
      evaluator = \_ _ _ -> modifyIORef' evaluatorCalls (+ 1) >> pure (Left "evaluator must not run"),
      attention = \_ -> do
        modifyIORef' attentionCalls (+ 1)
        pure (Right (Reserved "fixture-attention" "fixture-outbox")),
      attentionRecipients = emptyAttentionRecipientMap
    }
  where
    unavailable :: IO (Either EvidenceReadError value)
    unavailable = do
      modifyIORef' evidenceCalls (+ 1)
      pure (Left (ContentPlaneUnavailable "fixture unavailable"))

assertUnresolvedOutcome :: Either error (WorkflowOutcome Value) -> IO ()
assertUnresolvedOutcome (Right (Completed (Object output))) =
  case KeyMap.lookup "verdict" output of
    Just (Object verdict) -> KeyMap.lookup "classification" verdict @?= Just (String "unresolved")
    other -> assertFailure ("completed output has no verdict: " <> show other)
assertUnresolvedOutcome other = assertFailure ("practice-review flow did not complete: " <> showOutcome other)
  where
    showOutcome _ = "unexpected workflow outcome"

assertResolutionOutcome :: Either error (WorkflowOutcome Value) -> IO ()
assertResolutionOutcome (Right (Completed (Object output))) =
  KeyMap.lookup "kind" output @?= Just (String "practice-review-resolution")
assertResolutionOutcome _ = assertFailure "practice-review resolution flow did not complete"

assertRunRefused :: Either SomeException (Either error (WorkflowOutcome value)) -> IO ()
assertRunRefused (Left _) = pure ()
assertRunRefused (Right (Left _)) = pure ()
assertRunRefused (Right (Right Completed {})) = assertFailure "invalid practice-review input completed"
assertRunRefused (Right (Right _)) = pure ()

executionContextFixture :: PracticeReviewExecutionContext
executionContextFixture =
  PracticeReviewExecutionContext
    { identity = compatibilityIdentity reviewerAgent,
      parentWorkflowId = Just (WorkflowId "architecture-practice-parent"),
      parentSessionId = Just nominalSessionFixture,
      childWorkflowId = WorkflowId "practice-review-child",
      childSessionId = nominalSessionFixture
    }

sinkEnvFixture :: SessionId -> SinkEnv
sinkEnvFixture session =
  SinkEnv
    { agent = reviewerAgent,
      runId = idText session,
      occurredAt = Nothing,
      danwaTarget = Nothing,
      activity = Just reviewActivity,
      grants = StaticGrants (Map.singleton reviewerAgent (Set.fromList [SKawaDigest, SKizashiSignal])),
      directory = disabledDirectoryHandle,
      identity = compatibilityIdentity reviewerAgent
    }

reviewerDecl :: AgentDecl
reviewerDecl =
  AgentDecl
    { name = reviewerAgent,
      description = "practice-review orchestration fixture",
      trigger = Event {eventType = "practice-review.requested"},
      behavior = Flow {name = "opentelemetry-practice-review"},
      sinks = [],
      delegates = [],
      delegationBudget = Nothing,
      sanctionedProfile = Nothing,
      capabilityOverlays = [],
      identity = Nothing,
      memory = defaultMemoryPolicy & #recordPolicy .~ Never,
      enabled = True,
      expertise = [],
      decisionModels = [],
      routing = Nothing
    }

reviewActivity :: ActivityEnvelope
reviewActivity =
  ActivityEnvelope
    { activityId = "act_practice_review_fixture",
      occurredAt = "2026-08-26T00:00:00Z",
      source = "shinzui/shikigami",
      actor = Actor {kind = "agent", id = reviewerAgent, session = Nothing},
      subject = Subject {subjectType = "practice-review", subjectId = "fixture"},
      verb = "practice-review.requested",
      payload = Aeson.object [],
      contextRefs = [],
      idempotencyKey = "practice-review-fixture"
    }

reviewerAgent :: Text
reviewerAgent = "opentelemetry-practice-reviewer"

firstResolution :: IO PracticeReviewResolution
firstResolution = do
  resolutions <- readFixture "resolutions-valid.json" >>= decodeOrFail . LazyByteString.fromStrict
  case resolutions of
    resolution : _ -> pure resolution
    [] -> assertFailure "resolution fixture is empty"

targetSuspectVerdict :: IO PracticeReviewVerdict
targetSuspectVerdict = do
  verdicts <- readFixture "verdicts-valid.json" >>= decodeOrFail . LazyByteString.fromStrict
  case verdicts of
    _ : verdict : _ -> pure verdict
    _ -> assertFailure "target-suspect verdict fixture is absent"

resolverOf :: PracticeReviewResolution -> OwnerPrincipal
resolverOf PracticeReviewResolution {resolver} = resolver

resolvedAtOf :: PracticeReviewResolution -> UTCTime
resolvedAtOf PracticeReviewResolution {resolvedAt} = resolvedAt

alterAuthorizationId :: Text -> Value -> Value
alterAuthorizationId replacement = insertAuthorizationField "authorizationId" (String replacement)

insertAuthorizationField :: Key -> Value -> Value -> Value
insertAuthorizationField key value (Object envelope) =
  case KeyMap.lookup "authorization" envelope of
    Just (Object receipt) -> Object (KeyMap.insert "authorization" (Object (KeyMap.insert key value receipt)) envelope)
    _ -> Object envelope
insertAuthorizationField _ _ other = other

insertObjectField :: Key -> Value -> Value -> Value
insertObjectField key value (Object objectValue) = Object (KeyMap.insert key value objectValue)
insertObjectField _ _ other = other

isSubjectMismatch :: Either ResolutionAuthorizationError value -> Bool
isSubjectMismatch (Left AuthorizationSubjectMismatch {}) = True
isSubjectMismatch _ = False

isSourceInvalid :: Either ResolutionAuthorizationError value -> Bool
isSourceInvalid (Left AuthorizationSourceInvalid {}) = True
isSourceInvalid _ = False

isIdInvalid :: Either ResolutionAuthorizationError value -> Bool
isIdInvalid (Left AuthorizationIdInvalid {}) = True
isIdInvalid _ = False

assertDecodeFailure :: forall value. (FromJSON value) => Value -> IO ()
assertDecodeFailure value =
  case Aeson.fromJSON @value value of
    Aeson.Error _ -> pure ()
    Aeson.Success _ -> assertFailure "strict decoder accepted an unknown field"

decodeOrFail :: (FromJSON value) => LazyByteString.ByteString -> IO value
decodeOrFail bytes =
  case eitherDecode bytes of
    Left detail -> assertFailure detail
    Right value -> pure value

expectRight :: (Show error) => Either error value -> IO value
expectRight = either (assertFailure . show) pure

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

nominalSessionFixture :: NominalId.SessionId
nominalSessionFixture = either (error . show) id (NominalId.parseId "kioku_session_01kvxa7d2cezhs874g3n8dfgme")
