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
import Data.Functor.Contravariant ((>$<))
import Data.Generics.Labels ()
import Data.IORef (IORef, modifyIORef', newIORef, readIORef)
import Data.Int (Int64)
import Data.Map.Strict qualified as Map
import Data.Set qualified as Set
import Data.Text (Text)
import Data.Time (UTCTime (..), fromGregorian, secondsToNominalDiffTime)
import Data.Vector qualified as Vector
import Effectful (liftIO, runEff)
import Effectful.Error.Static (runErrorNoCallStack)
import Effectful.Exception qualified as EffException
import Hasql.Decoders qualified as Decoders
import Hasql.Encoders qualified as Encoders
import Hasql.Pool qualified as Pool
import Hasql.Session qualified as Session
import Hasql.Statement (Statement, preparable)
import Keiro.Outbox (listOutbox)
import Keiro.Workflow (WorkflowId (..), WorkflowName (..), WorkflowOutcome (..), loadStepIndex, runWorkflowWith)
import Kioku.Id (SessionId, genSessionId, idText)
import Kioku.Id qualified as NominalId
import Kiroku.Store.Connection (KirokuStore (..), defaultConnectionSettings, withStore)
import Kiroku.Store.Effect (runStoreResource)
import Kiroku.Store.Effect.Resource (withKirokuStore)
import Kiroku.Store.Error (StoreError)
import Pgmq qualified
import Shikigami.Action.Authorization (allowAllActionAuthorizerForTests)
import Shikigami.Activity (ActivityEnvelope (..), Actor (..), Subject (..))
import Shikigami.Activity.Coordinate
import Shikigami.Agent.Approval (autoApprovePolicy)
import Shikigami.Agent.Approval.Workflow qualified as ApprovalWorkflow
import Shikigami.Agent.Decl (AgentDecl (..), Behavior (..), RecordPolicy (Never), Trigger (..), defaultDelegationBudget, defaultMemoryPolicy)
import Shikigami.Agent.DeclarationValue
import Shikigami.Agent.Delegate.Depth (DelegationDepth, parseDelegationDepth)
import Shikigami.Agent.Name (AgentName, mkAgentName)
import Shikigami.Agent.Principal (ResolvedAgentIdentity (CompatibilityAgent), compatibilityIdentity)
import Shikigami.Agent.Run (AgentRunResult (..))
import Shikigami.Agent.Run.Key (RunKey, parseRunKey)
import Shikigami.Agent.RunJob (RunJob (..), RunRouteKind (AgentWorkflowRoute), TriggerKind (TriggeredByEvent))
import Shikigami.Agent.Workflow qualified as AgentWorkflow
import Shikigami.App (AppEnv (..), noopTracer, runAppIO)
import Shikigami.Attestation.Resolve (ProfileResolutionError (UnknownProfile))
import Shikigami.Behavior.Run (BehaviorEnv, newBehaviorEnv)
import Shikigami.Capability.Provider qualified as CapabilityProvider
import Shikigami.Directory (disabledDirectoryHandle)
import Shikigami.Duration (parseDuration)
import Shikigami.Execution.Policy.Types qualified as Harness
import Shikigami.Fixture.SinkHttp (testSinkHttp)
import Shikigami.Flow.Capability (SinkEnv (..), runSink)
import Shikigami.Flow.Decision qualified as FlowDecision
import Shikigami.Flow.OpenTelemetryPracticeReview (opentelemetryPracticeReviewFlow)
import Shikigami.Flow.Routing qualified as Routing
import Shikigami.Log qualified as Log
import Shikigami.Migrations.TestSupport (DatabaseFixture, withShikigamiFreshDatabase)
import Shikigami.PracticeReview
  ( ClaimId,
    ClaimKind (Fact),
    ContentReference (..),
    EvidenceItem (..),
    ExceptionApproval (..),
    OwnerPrincipal,
    PracticeAdoptionBinding (..),
    PracticeKey,
    PracticeReviewClaim (..),
    PracticeReviewClassification (..),
    PracticeReviewResolutionRequest (..),
    PracticeReviewTrigger (..),
    PracticeReviewVerdict (..),
    ResolutionOutcome (..),
    ReviewId,
    ReviewLineage (..),
    parseClaimId,
    parseOwnerPrincipal,
    parsePracticeKey,
    reviewIdText,
    validateResolutionRequest,
    validateTrigger,
    validateVerdict,
    validatedVerdictValue,
  )
import Shikigami.PracticeReview qualified as Review
import Shikigami.PracticeReview qualified as ReviewValue
import Shikigami.PracticeReview.Attention
  ( AttentionKey,
    PracticeReviewAttentionEnv (..),
    attentionKeyText,
    deriveAttentionKey,
    runPracticeReviewAttentionAtomic,
  )
import Shikigami.PracticeReview.Authorization
  ( AuthorizedPracticeReviewResolution (..),
    AuthorizedResolutionReceipt (authorizationId),
    ResolutionAuthorityKind (Human),
    ResolutionAuthorizationError (..),
    ResolutionSubmissionEvidence (..),
    ReviewResolutionAuthorizer (..),
    enqueueAuthorizedPracticeReviewResolution,
    mkAuthorizedResolutionReceipt,
    validateAuthorizedPracticeReviewResolution,
  )
import Shikigami.PracticeReview.Authorization qualified as ReviewAuth
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
import Shikigami.PracticeReview.Identity (attentionKeyForDigest, newReviewId)
import Shikigami.PracticeReview.IdentityStore qualified as IdentityStore
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
import Shikigami.RunJobs (decodeRunJob)
import Shikigami.Sink.Config (DanwaConfig (..), KanmonConfig (..), KawaConfig (..), KizashiConfig (..), ReiConfig (..))
import Shikigami.Sink.Delivery (sinkMessageId)
import Shikigami.Sink.GrantStore (GrantSource (StaticGrants))
import Shikigami.Sink.Permission (SinkKind (SKawaDigest, SKizashiSignal))
import Shikigami.Trigger.Enqueue (ensureRunQueue, runQueueName)
import Shikigami.Trigger.Schedule (parseCron)
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
      ingressTests databaseFixture,
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
        validated <- expectRight (validateResolutionRequest resolution)
        receipt <- expectRight (mkAuthorizedResolutionReceipt Human (resolverOf resolution) "mori://shinzui/shikigami/reviews/approval-1" (resolvedAtOf resolution) validated)
        let envelope = AuthorizedPracticeReviewResolution {schemaVersion = ReviewAuth.authorizationEnvelopeSchemaVersion, resolution, authorization = receipt}
        decoded <- decodeOrFail (encode envelope)
        validateAuthorizedPracticeReviewResolution decoded @?= Right (validated, receipt)
        ReviewAuth.resolutionAuthorizationIdText ((.authorizationId) receipt) @?= "dc9940fc-5b78-5d6d-b8fb-0b9d4ddcd166",
      testCase "subject mismatch, disallowed source, and altered receipt are refused" do
        resolution <- firstResolution
        validated <- expectRight (validateResolutionRequest resolution)
        mismatched <- expectRight (mkAuthorizedResolutionReceipt Human (fixtureOwnerPrincipal "different-subject") "activity://approval/1" (resolvedAtOf resolution) validated)
        let mismatchedEnvelope = AuthorizedPracticeReviewResolution {schemaVersion = ReviewAuth.authorizationEnvelopeSchemaVersion, resolution, authorization = mismatched}
        assertBool "subject mismatch was accepted" (isSubjectMismatch (validateAuthorizedPracticeReviewResolution mismatchedEnvelope))
        assertBool
          "noncanonical authorization source was accepted"
          (isSourceInvalid (mkAuthorizedResolutionReceipt Human (resolverOf resolution) "https://example.invalid/approval" (resolvedAtOf resolution) validated))
        validReceipt <- expectRight (mkAuthorizedResolutionReceipt Human (resolverOf resolution) "activity://approval/1" (resolvedAtOf resolution) validated)
        let validEnvelope = AuthorizedPracticeReviewResolution {schemaVersion = ReviewAuth.authorizationEnvelopeSchemaVersion, resolution, authorization = validReceipt}
        assertDecodeFailure @AuthorizedPracticeReviewResolution (alterAuthorizationId "altered" (Aeson.toJSON validEnvelope))
        altered <- decodeOrFail (encode (alterAuthorizationId "00000000-0000-5000-8000-000000000000" (Aeson.toJSON validEnvelope)))
        assertBool "altered authorization id was accepted" (isIdInvalid (validateAuthorizedPracticeReviewResolution altered)),
      testCase "authorization decoders reject unknown envelope and receipt fields" do
        resolution <- firstResolution
        validated <- expectRight (validateResolutionRequest resolution)
        receipt <- expectRight (mkAuthorizedResolutionReceipt Human (resolverOf resolution) "activity://approval/1" (resolvedAtOf resolution) validated)
        let envelope = AuthorizedPracticeReviewResolution {schemaVersion = ReviewAuth.authorizationEnvelopeSchemaVersion, resolution, authorization = receipt}
        assertDecodeFailure @AuthorizedPracticeReviewResolution (insertObjectField "unexpected" Aeson.Null (Aeson.toJSON envelope))
        assertDecodeFailure @AuthorizedPracticeReviewResolution (insertAuthorizationField "unexpected" Aeson.Null (Aeson.toJSON envelope))
        assertDecodeFailure @PracticeReviewResolutionRequest (insertObjectField "resolutionId" (String "caller-selected") (Aeson.toJSON resolution))
        changed <- decodeOrFail (encode (envelope & #resolution .~ (resolution & #reason .~ "changed after authorization")))
        assertBool "receipt did not bind the complete command" (isIdInvalid (validateAuthorizedPracticeReviewResolution changed))
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
        attentionKeyText key @?= "4978b57a-1a3d-5210-b82d-671276f2c485"
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
        let appEnv = AppEnv {connectionSettings = defaultConnectionSettings connectionString, tracer, metrics = Nothing, store = Nothing}
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
        priorReviewId <- allocatedIdFor appEnv (completeOpenTelemetryTrigger "complete-consistent")
        let reReviewTrigger = completeOpenTelemetryReferenceChangeTrigger "complete-reference-change" priorReviewId
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
          reviewId <- allocatedIdFor appEnv reviewedTrigger
          superseding <- newReviewId
          let resultingApplicability =
                case adoptions of
                  PracticeAdoptionBinding {claimedApplicability} : _
                    | retainsApplicability -> Just claimedApplicability
                  _ -> Nothing
              supersedingReviewId
                | isSuperseded = Just superseding
                | otherwise = Nothing
              commandKey = "complete-resolution-" <> resolutionLabel
              resolution =
                PracticeReviewResolutionRequest
                  { schemaVersion = ReviewValue.practiceReviewSchemaVersion,
                    idempotencyKey = reviewResolutionKey commandKey,
                    reviewId,
                    outcome,
                    resolver = fixtureOwnerPrincipal "architecture-council",
                    reason = "Verified orchestration resolution fixture.",
                    resolvedAt = UTCTime (fromGregorian 2026 8 26) 0,
                    resultingApplicability,
                    supersedingReviewId
                  }
          validatedResolution <- expectRight (validateResolutionRequest resolution)
          receipt <-
            expectRight
              ( mkAuthorizedResolutionReceipt
                  Human
                  (fixtureOwnerPrincipal "architecture-council")
                  ("activity://approval/" <> resolutionLabel)
                  (resolvedAtOf resolution)
                  validatedResolution
              )
          let envelope = AuthorizedPracticeReviewResolution {schemaVersion = ReviewAuth.authorizationEnvelopeSchemaVersion, resolution, authorization = receipt}
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
        let appEnv = AppEnv {connectionSettings = defaultConnectionSettings connectionString, tracer, metrics = Nothing, store = Nothing}
            baseRuntime = incompleteRuntime evidenceCalls evaluatorCalls legacyAttentionCalls
            runtime = (baseRuntime & #attentionRecipients .~ (recipients))
            deps = specialistAgentRunDeps appEnv behaviorEnv runtime
            job =
              RunJob
                { agentName = fixtureAgentName reviewerAgent,
                  identity = compatibilityIdentity (fixtureAgentName reviewerAgent),
                  triggerKind = TriggeredByEvent,
                  routeKind = AgentWorkflowRoute,
                  occurredAt = UTCTime (fromGregorian 2026 8 26) 0,
                  triggerPayload = Aeson.toJSON trigger,
                  idempotencyKey = fixtureRunKey "agent-run-practice-review-incomplete",
                  parentSessionId = Just parentSession,
                  parentRunWorkflowId = Just (WorkflowId "architecture-practice-router-parent"),
                  delegationDepth = Just (fixtureDelegationDepth 1),
                  lineage = map fixtureAgentName ["architecture-practice-router", reviewerAgent],
                  executionRequest = Nothing,
                  executionPermissions = Nothing,
                  executionRootId = Nothing,
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
            let appEnv = AppEnv {connectionSettings = defaultConnectionSettings connectionString, tracer, metrics = Nothing, store = Nothing}
                runtime = incompleteRuntime evidenceCalls evaluatorCalls attentionCalls
                workflowId = WorkflowId "practice-review-incomplete-replay"
                runInput :: WorkflowId -> Value -> IO (Either StoreError (WorkflowOutcome Value))
                runInput selectedWorkflowId input =
                  runEff
                    . runErrorNoCallStack
                    . withKirokuStore (appEnv.connectionSettings)
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
                                identity = CompatibilityAgent (fixtureAgentName reviewerAgent),
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

            reviewId <- allocatedIdFor appEnv contractTrigger
            let resolution =
                  PracticeReviewResolutionRequest
                    { schemaVersion = ReviewValue.practiceReviewSchemaVersion,
                      idempotencyKey = reviewResolutionKey "resolution-command-fixture",
                      reviewId,
                      outcome = Rejected,
                      resolver = fixtureOwnerPrincipal "architecture-council",
                      reason = "The incomplete advisory review was explicitly rejected by its verified resolver.",
                      resolvedAt = UTCTime (fromGregorian 2026 8 26) 0,
                      resultingApplicability = Nothing,
                      supersedingReviewId = Nothing
                    }
            bareResolution <-
              try @SomeException
                (runInput (WorkflowId "practice-review-bare-resolution") (Aeson.toJSON resolution))
            assertRunRefused bareResolution
            validatedResolution <- expectRight (validateResolutionRequest resolution)
            receipt <-
              expectRight
                ( mkAuthorizedResolutionReceipt
                    Human
                    (fixtureOwnerPrincipal "architecture-council")
                    "activity://approval/practice-review-fixture"
                    (resolvedAtOf resolution)
                    validatedResolution
                )
            let envelope = AuthorizedPracticeReviewResolution {schemaVersion = ReviewAuth.authorizationEnvelopeSchemaVersion, resolution, authorization = receipt}
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
        firstVerdict <- expectRight (validateVerdict verdict)
        secondReviewId <- newReviewId
        let secondTriggerKey = reviewTriggerKey "equivalent-trigger-two"
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
            let appEnv = AppEnv {connectionSettings = defaultConnectionSettings connectionString, tracer, metrics = Nothing, store = Nothing}
                runAttention suffix runIdentifier validated =
                  runEff
                    . runErrorNoCallStack
                    . withKirokuStore (appEnv.connectionSettings)
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
                  [ runAttention "one" "kioku_session_01kvxa7d2cezhs874g3n8dfgme" firstVerdict,
                    runAttention "two" "kioku_session_01kvxa7d2cezhs874g3n8dfgmf" secondVerdict
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
            fmap length outbox @?= Right 1,
      testCase "corrupt retained attention results roll back association and recover after exact repair" do
        verdict <- targetSuspectVerdict
        firstVerdict <- expectRight (validateVerdict verdict)
        secondReviewId <- newReviewId
        secondVerdict <- expectRight (validateVerdict (verdict & #reviewId .~ secondReviewId & #triggerIdempotencyKey .~ reviewTriggerKey "attention-repair-two"))
        recipients <- expectRight (mkAttentionRecipientMap [("team-example-service", "recipient_target")])
        (withShikigamiFreshDatabase databaseFixture) \connectionString ->
          withStore (defaultConnectionSettings connectionString) \KirokuStore {pool} -> do
            tracer <- noopTracer
            let appEnv = AppEnv {connectionSettings = defaultConnectionSettings connectionString, tracer, metrics = Nothing, store = Nothing}
                identifier = "practice-review-attention-decoder"
                counts = Pool.use pool (Session.statement () attentionCountsStatement) >>= either (assertFailure . show) pure
                replace value = Pool.use pool (Session.statement (identifier, value) replaceAttentionStepStatement) >>= either (assertFailure . show) pure
            outcome <- runEff . runErrorNoCallStack . withKirokuStore appEnv.connectionSettings . runStoreResource $
              runWorkflowWith (shikigamiWorkflowRunOptions appEnv) (WorkflowName "shikigami.practice-review.attention-test") (WorkflowId identifier) $
                runPracticeReviewAttentionAtomic (attentionEnv recipients "kioku_session_01kvxa7d2cezhs874g3n8dfgme") do
                  original <- requestPracticeReviewAttention firstVerdict
                  liftIO (assertBool "positive reservation was not retained" (isReserved original))
                  liftIO (counts >>= (@?= (1, 1, 1)))
                  let originalWire = Aeson.toJSON original
                      corrupt = corruptAttentionKey (attentionKeyText original.attentionKey) originalWire
                  liftIO (assertBool "corruption control did not change the key" (corrupt /= originalWire))
                  liftIO (replace corrupt)
                  refused <- EffException.trySync (requestPracticeReviewAttention secondVerdict)
                  liftIO case refused of Left _ -> pure (); Right _ -> assertFailure "unreadable retained result was accepted"
                  liftIO (counts >>= (@?= (1, 1, 1)))
                  liftIO (replace originalWire)
                  recovered <- requestPracticeReviewAttention secondVerdict
                  liftIO (recovered @?= original)
                  liftIO (counts >>= (@?= (1, 2, 1)))
                  pure (Aeson.toJSON recovered)
            _ <- decodeAttentionOutcome outcome
            outbox <- runAppIO appEnv (listOutbox "shinzui/shikigami")
            fmap length outbox @?= Right 1
    ]

-- Mutate the exact native key independently of the generic sum encoding.
corruptAttentionKey :: Text -> Value -> Value
corruptAttentionKey target = go
  where
    go (Object fields) = Object (fmap go fields)
    go (Array values) = Array (fmap go values)
    go (String raw) | raw == target = String "malformed-attention-key"
    go value = value

replaceAttentionStepStatement :: Statement (Text, Value) ()
replaceAttentionStepStatement =
  preparable
    "UPDATE keiro.keiro_workflow_steps SET result=$2 WHERE workflow_id=$1 AND workflow_name='shikigami.practice-review.attention-test' AND generation=0 AND step_name='practice-review-attention'"
    ((fst >$< Encoders.param (Encoders.nonNullable Encoders.text)) <> (snd >$< Encoders.param (Encoders.nonNullable Encoders.jsonb)))
    Decoders.noResult

attentionEnv :: AttentionRecipientMap -> Text -> PracticeReviewAttentionEnv
attentionEnv recipients runIdentifier =
  PracticeReviewAttentionEnv
    { agent = fixtureAgentName reviewerAgent,
      identity = compatibilityIdentity (fixtureAgentName reviewerAgent),
      runId = either (error . show) id (NominalId.parseId runIdentifier),
      occurredAt = Nothing,
      activity = Just reviewActivity,
      grants = StaticGrants (Map.singleton (compatibilityIdentity (fixtureAgentName reviewerAgent)) (Set.fromList [SKawaDigest, SKizashiSignal])),
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
      AgentWorkflow.decisions = FlowDecision.emptyDecisionServices,
      AgentWorkflow.actionAuthorizer = allowAllActionAuthorizerForTests,
      AgentWorkflow.capabilities = CapabilityProvider.emptyCapabilityRuntime,
      AgentWorkflow.coordination = Nothing,
      AgentWorkflow.workspace = Nothing,
      AgentWorkflow.agents = [reviewerDecl],
      AgentWorkflow.kizashi = KizashiConfig {baseUrl = "http://localhost:1", defaultRecipient = (declarationCoordinate "recipient_unused")},
      AgentWorkflow.kawa = KawaConfig {baseUrl = "http://localhost:1", sourceSegment = (activityCoordinate "shinzui/shikigami")},
      AgentWorkflow.kanmon = KanmonConfig {baseUrl = "http://localhost:1"},
      AgentWorkflow.danwa = DanwaConfig {baseUrl = "http://localhost:1", agentParticipant = (declarationCoordinate "part_agent_practice_review")},
      AgentWorkflow.rei = ReiConfig {baseUrl = Nothing},
      AgentWorkflow.http = testSinkHttp,
      AgentWorkflow.hooks = AgentWorkflow.defaultAgentRunHooks,
      AgentWorkflow.approvalPolicy = autoApprovePolicy (((either (error . show) id . parseDuration) (secondsToNominalDiffTime 900))),
      AgentWorkflow.approvalWorkflow = ApprovalWorkflow.defaultApprovalWorkflowEnv,
      AgentWorkflow.runTimeout = (either (error . show) id (parseDuration (secondsToNominalDiffTime 300))),
      AgentWorkflow.harness = Harness.defaultHarnessPolicy,
      AgentWorkflow.delegationBudget = defaultDelegationBudget,
      AgentWorkflow.logger = Log.silentLogger,
      AgentWorkflow.grants = StaticGrants (Map.singleton (compatibilityIdentity (fixtureAgentName reviewerAgent)) (Set.fromList [SKawaDigest, SKizashiSignal])),
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
    . withKirokuStore (appEnv.connectionSettings)
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
                identity = CompatibilityAgent (fixtureAgentName reviewerAgent),
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
        -- Historical model proposals may contain placeholder host metadata. The
        -- host owns these fields; replay must replace them before decoding.
        pure
          ( Right
              ( foldr
                  (uncurry insertObjectField)
                  (Aeson.toJSON (proposalWithEvidence evidence proposal))
                  [ ("schemaVersion", Number 99),
                    ("reviewId", String "model-placeholder"),
                    ("triggerIdempotencyKey", String ""),
                    ("specialist", String ""),
                    ("lineage", String "model-placeholder")
                  ]
              )
          ),
      attention = \validated -> do
        modifyIORef' attentionCalls (+ 1)
        let PracticeReviewVerdict {reviewId} = validatedVerdictValue validated
        pure (Right (Reserved (attentionKeyForDigest ("fixture-attention-" <> reviewIdText reviewId)) (sinkMessageId ("outbox-" <> reviewIdText reviewId)))),
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
  ( proposal
      & #targetEvidence .~ ([])
      & #referenceEvidence .~ ([])
      & #upstreamEvidence .~ ([])
      & #claims
        .~ ( [ PracticeReviewClaim
                 { claimId = fixtureClaimId "claim-complete-orchestration",
                   kind = Fact,
                   statement = "The bounded evidence supports the proposed architecture-practice classification.",
                   material = ReviewValue.Material,
                   evidenceIds = citationIds
                 }
             ]
           )
  )
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
        pure (Right (Reserved (attentionKeyForDigest "fixture-attention") (sinkMessageId "fixture-outbox"))),
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
    { identity = compatibilityIdentity (fixtureAgentName reviewerAgent),
      parentWorkflowId = Just (WorkflowId "architecture-practice-parent"),
      parentSessionId = Just nominalSessionFixture,
      childWorkflowId = WorkflowId "practice-review-child",
      childSessionId = nominalSessionFixture
    }

sinkEnvFixture :: SessionId -> SinkEnv
sinkEnvFixture session =
  SinkEnv
    { agent = fixtureAgentName reviewerAgent,
      runId = session,
      occurredAt = Nothing,
      danwaTarget = Nothing,
      activity = Just reviewActivity,
      grants = StaticGrants (Map.singleton (compatibilityIdentity (fixtureAgentName reviewerAgent)) (Set.fromList [SKawaDigest, SKizashiSignal])),
      directory = disabledDirectoryHandle,
      identity = compatibilityIdentity (fixtureAgentName reviewerAgent)
    }

reviewerDecl :: AgentDecl
reviewerDecl =
  AgentDecl
    { name = fixtureAgentName reviewerAgent,
      description = "practice-review orchestration fixture",
      trigger = Event {eventType = declarationCoordinate ("practice-review.requested")},
      behavior = Flow {name = declarationCoordinate ("opentelemetry-practice-review")},
      sinks = [],
      delegates = map fixtureAgentName [],
      delegationBudget = Nothing,
      sanctionedProfile = Nothing,
      capabilityOverlays = [],
      identity = Nothing,
      memory = defaultMemoryPolicy & #recordPolicy .~ Never,
      enabled = agentEnablement (True),
      expertise = [],
      execution = Nothing,
      harness = Nothing,
      decisionModels = [],
      routing = Nothing
    }

reviewActivity :: ActivityEnvelope
reviewActivity =
  ActivityEnvelope
    { activityId = activityCoordinate ("act_practice_review_fixture"),
      occurredAt = activityCoordinate ("2026-08-26T00:00:00Z"),
      source = activityCoordinate ("shinzui/shikigami"),
      actor = Actor {kind = either (error . show) id (parseActorKind ("agent")), id = activityCoordinate (reviewerAgent), session = fmap activityCoordinate (Nothing)},
      subject = Subject {kind = activityCoordinate ("practice-review"), subjectId = activityCoordinate ("fixture")},
      verb = activityCoordinate ("practice-review.requested"),
      payload = Aeson.object [],
      contextRefs = [],
      idempotencyKey = activityCoordinate ("practice-review-fixture")
    }

reviewerAgent :: Text
reviewerAgent = "opentelemetry-practice-reviewer"

firstResolution :: IO PracticeReviewResolutionRequest
firstResolution = do
  values <- readFixture "resolutions-valid.json" >>= decodeOrFail . LazyByteString.fromStrict
  resolutions <- traverse (decodeOrFail . encode . removeAllocatedId) (values :: [Value])
  case resolutions of
    resolution : _ -> pure resolution
    [] -> assertFailure "resolution fixture is empty"

targetSuspectVerdict :: IO PracticeReviewVerdict
targetSuspectVerdict = do
  verdicts <- readFixture "verdicts-valid.json" >>= decodeOrFail . LazyByteString.fromStrict
  case verdicts of
    _ : verdict : _ -> pure verdict
    _ -> assertFailure "target-suspect verdict fixture is absent"

resolverOf :: PracticeReviewResolutionRequest -> OwnerPrincipal
resolverOf PracticeReviewResolutionRequest {resolver} = resolver

resolvedAtOf :: PracticeReviewResolutionRequest -> UTCTime
resolvedAtOf PracticeReviewResolutionRequest {resolvedAt} = resolvedAt

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

fixtureAgentName :: Text -> AgentName
fixtureAgentName = either (error . show) id . mkAgentName

fixtureDelegationDepth :: Int -> DelegationDepth
fixtureDelegationDepth = either (error . show) id . parseDelegationDepth . toInteger

fixtureRunKey :: Text -> RunKey
fixtureRunKey = either (error . show) id . parseRunKey

fixturePracticeKey :: Text -> PracticeKey
fixturePracticeKey = either (error . show) id . parsePracticeKey

fixtureOwnerPrincipal :: Text -> OwnerPrincipal
fixtureOwnerPrincipal = either (error . show) id . parseOwnerPrincipal

fixtureClaimId :: Text -> ClaimId
fixtureClaimId = either (error . show) id . parseClaimId

removeAllocatedId :: Value -> Value
removeAllocatedId (Object value) = Object (KeyMap.delete "resolutionId" value)
removeAllocatedId value = value

allocatedIdFor :: AppEnv -> PracticeReviewTrigger -> IO ReviewId
allocatedIdFor app trigger = do
  validated <- expectRight (validateTrigger trigger)
  reference <- IdentityStore.reserveReviewIdentity app (CompatibilityAgent (fixtureAgentName reviewerAgent)) validated (fixturePracticeKey "opentelemetry") (fixtureAgentName reviewerAgent) >>= expectRight
  pure (IdentityStore.allocatedReviewId reference)

ingressTests :: DatabaseFixture -> TestTree
ingressTests fixture = testCase "practice resolution ingress authorizes the ID-free command before queue publication" do
  withShikigamiFreshDatabase fixture \connection -> withStore (defaultConnectionSettings connection) \store -> do
    ensureRunQueue store.pool >>= expectRight
    request <- firstResolution
    calls <- newIORef (0 :: Int)
    let identity = compatibilityIdentity (fixtureAgentName reviewerAgent)
        submission = ResolutionSubmissionEvidence "protected-authentication-material"
        denied = ReviewResolutionAuthorizer \_ _ -> modifyIORef' calls (+ 1) >> pure (Left (ResolutionAuthorizerRefused "fixture refusal"))
        send = enqueueAuthorizedPracticeReviewResolution store.pool identity reviewerAgent
    show submission @?= "<resolution-submission-evidence>"
    refused <- send denied request submission
    case refused of Left (ResolutionAuthorizerRefused _) -> pure (); other -> assertFailure (show other)
    metrics <- Pool.use store.pool (Pgmq.queueMetrics runQueueName) >>= expectRight
    metrics.queueLength @?= 0
    let allowed = ReviewResolutionAuthorizer \command _ -> do
          command @?= request
          modifyIORef' calls (+ 1)
          validated <- expectRight (validateResolutionRequest command)
          pure (mkAuthorizedResolutionReceipt Human (resolverOf command) "activity://approval/ingress" (resolvedAtOf command) validated)
    _ <- send allowed request submission >>= expectRight
    readIORef calls >>= (@?= 2)
    messages <- Pool.use store.pool (Pgmq.readMessage (Pgmq.ReadMessage runQueueName 30 (Just 10) Nothing)) >>= expectRight
    Vector.length messages @?= 1
    forM_ (Vector.toList messages) \message -> do
      job <- expectRight (decodeRunJob message.body.unMessageBody)
      envelope <- decodeOrFail (encode job.triggerPayload)
      (validated, _) <- expectRight (validateAuthorizedPracticeReviewResolution envelope)
      Aeson.toJSON (Review.validatedResolutionRequestValue validated) @?= Aeson.toJSON request

reviewResolutionKey :: Text -> ReviewValue.ResolutionKey
reviewResolutionKey = either (error . show) id . ReviewValue.parseResolutionKey

reviewTriggerKey :: Text -> ReviewValue.TriggerKey
reviewTriggerKey = either (error . show) id . ReviewValue.parseTriggerKey
