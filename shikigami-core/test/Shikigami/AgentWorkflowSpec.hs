module Shikigami.AgentWorkflowSpec (tests) where

import Control.Exception (SomeException, throwIO, try)
import Control.Monad (forM_, when)
import Data.Aeson (Result (..), Value, fromJSON, object, toJSON, (.=))
import Data.Bifunctor (first)
import Data.Functor.Contravariant ((>$<))
import Data.IORef (IORef, atomicModifyIORef', modifyIORef', newIORef, readIORef, writeIORef)
import Data.List.NonEmpty qualified as NonEmpty
import Data.Map.Strict (Map)
import Data.Map.Strict qualified as Map
import Data.Set qualified as Set
import Data.Text (Text)
import Data.Text qualified as Text
import Data.Time (NominalDiffTime, UTCTime (..), addUTCTime, fromGregorian, getCurrentTime, secondsToNominalDiffTime)
import Effectful (Eff)
import Effectful.Dispatch.Static (unsafeEff_)
import Hasql.Decoders qualified as Decoders
import Hasql.Encoders qualified as Encoders
import Hasql.Pool (Pool)
import Hasql.Pool qualified as Pool
import Hasql.Session qualified as HasqlSession
import Hasql.Statement (Statement, preparable)
import Keiro.Integration.Event (decodeJsonIntegrationEvent)
import Keiro.Outbox (OutboxRow (..), defaultPublishOptions, listOutbox, publishClaimedOutbox)
import Keiro.Timer (TimerRow (..))
import Keiro.Workflow (StepName (..), Workflow, WorkflowId (..), WorkflowName (..), WorkflowOutcome (..), completedStepName, defaultWorkflowRunOptions, loadStepIndex, patchSetStepName, runWorkflow, runWorkflowWith)
import Keiro.Workflow.Awakeable (AwakeableId)
import Keiro.Workflow.Awakeable.Schema (countPendingAwakeables)
import Keiro.Workflow.Child (runChildWorkflow)
import Keiro.Workflow.Child.Schema (ChildRow (..), ChildStatus (..), lookupChildrenOfParent)
import Keiro.Workflow.Resume (ResumeSummary (..), defaultWorkflowResumeOptions, resumeWorkflowsOnce)
import Keiro.Workflow.Sleep (runWorkflowTimerWorker)
import Kioku.Api.Types (Confidence (MediumConfidence), MemoryType (MemoryPattern))
import Kioku.App (AppEffects, AppEnv (..), noopTracer, runAppIO)
import Kioku.Id (SessionId, genMemoryId, genSessionId, idText)
import Kioku.Memory qualified as Memory
import Kioku.Memory.Domain (RecordMemoryData (..))
import Kioku.Memory.ReadModel (MemoryRow (..))
import Kioku.Session (SessionRow (..))
import Kioku.Session qualified as Session
import Kioku.Session.Domain (StartSessionData (..))
import Kioku.Session.ReadModel (TurnRow (..))
import Kiroku.Store.Connection (KirokuStore (..), defaultConnectionSettings, withStore)
import Kiroku.Store.Types (EventId)
import Network.Wai.Handler.Warp (testWithApplication)
import Shikigami.Agent.Approval (ApprovalChannel (..), ApprovalDecision (..), ApprovalEnv (..), ApprovalRequest (..), ApprovalRequirement (..), approvalTimeoutFireAction, defaultApprovalEnv, resolveApproval)
import Shikigami.Agent.Conversation qualified as Conversation
import Shikigami.Agent.Conversation.SessionIndex qualified as SessionIndex
import Shikigami.Agent.Decl (AgentDecl (..), Behavior (..), MemoryPolicy (..), ProfileRequirement (..), RecordPolicy (..), Sink (..), Trigger (..), defaultMemoryPolicy, mkRecallLimit)
import Shikigami.Agent.Delegate (awaitDelegated, delegate, delegatedWorkflowId)
import Shikigami.Agent.Delegate.Context (DelegateCtx (..))
import Shikigami.Agent.Loader (loadAgent)
import Shikigami.Agent.Run (AgentRunResult (..), recallPriorLearnings)
import Shikigami.Agent.RunJob (RunJob (..), RunRouteKind (..), TriggerKind (..))
import Shikigami.Agent.Workflow (AgentRunDeps (..), AgentRunFailure (..), AgentRunHooks (..), SinkIntent (..), agentRunFailureDetail, agentRunRegistry, agentRunWorkflow, agentRunWorkflowName, defaultAgentRunHooks, publishSinkIntent, runAgentRunWorkflow)
import Shikigami.Attestation.Envelope (profileDigest)
import Shikigami.Attestation.Profile
  ( AllowedCall (..),
    EvidenceStrength (EvidenceModelObserved),
    Issuer (..),
    ProfileDigest (..),
    ProfileId (..),
    ProfileLifecycle (Active),
    ProfileVersion (..),
    Prohibitions (..),
    SanctionedExecutionProfile (..),
    SanctionedExecutionProfileRef (..),
    ThinkingLevel (ThinkingHigh),
    defaultProhibitions,
    noSignerRequirements,
    unlimitedProfileLimits,
  )
import Shikigami.Attestation.Resolve (ProfileResolutionError (..), ResolvedProfile (..), postgresProfileStore, resolveProfile)
import Shikigami.Behavior.Error (TransientBehaviorFailure (..))
import Shikigami.Behavior.Run (BehaviorEnv, newBehaviorEnv)
import Shikigami.Fixture.KawaStub (kawaDoorwayApplication)
import Shikigami.Integration.Danwa (AddressedMessage (..), addressedMessageEventType)
import Shikigami.Log qualified as Log
import Shikigami.Memory.Access (agentActor, shikigamiMemorySpace)
import Shikigami.Memory.Scope (agentScope)
import Shikigami.Migrations.TestSupport (withShikigamiMigratedDatabase)
import Shikigami.Sink (GrantSource (DbGrants, StaticGrants), defaultGrantTable)
import Shikigami.Sink.Config (DanwaConfig (..), KawaConfig (..), KizashiConfig (..), ReiConfig (..))
import Shikigami.Sink.GrantStore (revokeGrant)
import Shikigami.Sink.Permission (SinkKind (..))
import Test.Tasty (TestTree, testGroup)
import Test.Tasty.HUnit (assertBool, assertEqual, assertFailure, testCase)

tests :: TestTree
tests =
  testGroup
    "AgentWorkflow"
    [ testCase "behavior retry patch preserves old journals and uses only v2 when fresh" do
        withShikigamiMigratedDatabase \connStr ->
          withStore (defaultConnectionSettings connStr) \_kirokuStore -> do
            tracer <- noopTracer
            behaviorEnv <- newBehaviorEnv
            let appEnv = AppEnv {connectionSettings = defaultConnectionSettings connStr, tracer, metrics = Nothing}
                deps = testDeps appEnv behaviorEnv defaultAgentRunHooks
                oldJob = retryVersioningJob "heartbeat:test-retry-old"
                freshJob = retryVersioningJob "heartbeat:test-retry-fresh"

            oldOutcome <-
              runAppIO appEnv $
                runWorkflowWith
                  defaultWorkflowRunOptions
                  agentRunWorkflowName
                  (WorkflowId (idempotencyKey oldJob))
                  (agentRunWorkflow deps (Just oldJob))
            assertBool ("pre-patch agent run decodes and completes: " <> show oldOutcome) (isCompleted oldOutcome)
            oldIndex <- runAppIO appEnv (loadStepIndex agentRunWorkflowName (WorkflowId (idempotencyKey oldJob)) 0)
            assertEqual "pre-patch journal keeps the old behavior label" (Right True) (Map.member "run-behavior" <$> oldIndex)
            assertEqual "pre-patch journal never writes v2" (Right False) (Map.member "run-behavior-v2" <$> oldIndex)

            freshOutcome <- runAgentRunWorkflow deps freshJob
            assertBool ("fresh agent run completes: " <> show freshOutcome) (isCompleted freshOutcome)
            freshIndex <- runAppIO appEnv (loadStepIndex agentRunWorkflowName (WorkflowId (idempotencyKey freshJob)) 0)
            assertEqual "fresh journal writes the v2 behavior label" (Right True) (Map.member "run-behavior-v2" <$> freshIndex)
            assertEqual "fresh journal never writes the legacy label" (Right False) (Map.member "run-behavior" <$> freshIndex),
      testCase "transient v2 failure leaves no value and a later advance succeeds" do
        withShikigamiMigratedDatabase \connStr ->
          withStore (defaultConnectionSettings connStr) \_kirokuStore -> do
            tracer <- noopTracer
            behaviorEnv <- newBehaviorEnv
            attempts <- newIORef (0 :: Int)
            let appEnv = AppEnv {connectionSettings = defaultConnectionSettings connStr, tracer, metrics = Nothing}
                hooks =
                  defaultAgentRunHooks
                    { beforeStepBody = \stepName ->
                        when (unStepName stepName == "run-behavior-v2") do
                          attempt <- atomicModifyIORef' attempts \count -> (count + 1, count)
                          when (attempt == 0) (throwIO (TransientBehaviorFailure "simulated transient provider failure"))
                    }
                deps = testDeps appEnv behaviorEnv hooks

            firstAttempt <- try @SomeException (runAgentRunWorkflow deps transientRetryJob)
            case firstAttempt of
              Left _ -> pure ()
              Right outcome -> assertFailure ("first transient attempt should escape, got " <> show outcome)
            afterFailure <- runAppIO appEnv (loadStepIndex agentRunWorkflowName (WorkflowId (idempotencyKey transientRetryJob)) 0)
            assertEqual "failed attempt appended no v2 value" (Right False) (Map.member "run-behavior-v2" <$> afterFailure)

            retried <- runAgentRunWorkflow deps transientRetryJob
            assertBool ("retry completes: " <> show retried) (isCompleted retried)
            assertEqual "the behavior body ran twice" 2 =<< readIORef attempts
            afterSuccess <- runAppIO appEnv (loadStepIndex agentRunWorkflowName (WorkflowId (idempotencyKey transientRetryJob)) 0)
            assertEqual "successful retry appended the v2 value" (Right True) (Map.member "run-behavior-v2" <$> afterSuccess),
      testCase "permanent v2 failure is journaled once and replayed" do
        withShikigamiMigratedDatabase \connStr ->
          withStore (defaultConnectionSettings connStr) \_kirokuStore -> do
            tracer <- noopTracer
            behaviorEnv <- newBehaviorEnv
            attempts <- newIORef (0 :: Int)
            let appEnv = AppEnv {connectionSettings = defaultConnectionSettings connStr, tracer, metrics = Nothing}
                hooks =
                  defaultAgentRunHooks
                    { beforeStepBody = \stepName ->
                        when (unStepName stepName == "run-behavior-v2") (modifyIORef' attempts (+ 1))
                    }
                deps = testDepsWithAgents appEnv behaviorEnv hooks [missingTaskDecl]

            firstAttempt <- runAgentRunWorkflow deps permanentFailureJob
            replayed <- runAgentRunWorkflow deps permanentFailureJob
            let isPermanent = \case
                  Right (Completed (Left (PermanentAgentRunFailure detail))) -> "unknown task" `Text.isInfixOf` detail
                  _ -> False
            assertBool ("first attempt is permanent: " <> show firstAttempt) (isPermanent firstAttempt)
            assertBool ("replay keeps the permanent value: " <> show replayed) (isPermanent replayed)
            assertEqual "permanent behavior body executes once" 1 =<< readIORef attempts,
      -- Before this, every kioku result on the agent-run path was discarded with
      -- @_ <-@ or @void@, so a run whose session kioku refused to open still
      -- reported Completed (Right ...) — a successful run with no durable record
      -- of itself. A negative delegation depth is kioku's own lineage rejection,
      -- so it exercises the refusal layer without breaking the store the journal
      -- also needs.
      testCase "a refused session open fails the run instead of completing it" do
        withShikigamiMigratedDatabase \connStr ->
          withStore (defaultConnectionSettings connStr) \_kirokuStore -> do
            tracer <- noopTracer
            behaviorEnv <- newBehaviorEnv
            let appEnv = AppEnv {connectionSettings = defaultConnectionSettings connStr, tracer, metrics = Nothing}
                deps = testDepsWithAgents appEnv behaviorEnv defaultAgentRunHooks [decl]
                refusedJob =
                  job
                    { idempotencyKey = "heartbeat:test-refused-session",
                      delegationDepth = Just (-1)
                    }

            result <- runAgentRunWorkflow deps refusedJob
            case result of
              Right (Completed (Left (PermanentAgentRunFailure detail))) ->
                assertBool
                  ("the failure names the refused write: " <> Text.unpack detail)
                  ("opening the run's kioku session was refused" `Text.isInfixOf` detail)
              other -> assertFailure ("a refused session open must not complete successfully, got " <> show other)

            -- The refusal is journaled, so a replay answers the same way rather
            -- than opening a session on the second attempt.
            replayed <- runAgentRunWorkflow deps refusedJob
            case replayed of
              Right (Completed (Left (PermanentAgentRunFailure _))) -> pure ()
              other -> assertFailure ("replay must keep the refusal, got " <> show other),
      testCase "Never completes a successful session without recording memory" do
        withShikigamiMigratedDatabase \connStr ->
          withStore (defaultConnectionSettings connStr) \_kirokuStore -> do
            tracer <- noopTracer
            behaviorEnv <- newBehaviorEnv
            let appEnv = AppEnv {connectionSettings = defaultConnectionSettings connStr, tracer, metrics = Nothing}
                neverDecl = withRecordPolicy Never decl
                deps = testDepsWithAgents appEnv behaviorEnv defaultAgentRunHooks [neverDecl]
                neverJob = job {idempotencyKey = "heartbeat:test-record-never"}

            result <- runAgentRunWorkflow deps neverJob
            sid <- case result of
              Right (Completed (Right AgentRunResult {sessionId, recordedMemId})) -> do
                assertEqual "the record step returns no memory id" Nothing recordedMemId
                pure sessionId
              other -> assertFailure ("Never run should complete, got " <> show other)

            memories <- runAppIO appEnv (Memory.getRowsBySession shikigamiMemorySpace sid)
            case memories of
              Right (Right rows) -> assertEqual "no memory row was written" 0 (length rows)
              other -> assertFailure ("memory lookup should succeed, got " <> show other)

            session <- runAppIO appEnv (Session.getById shikigamiMemorySpace sid)
            case session of
              Right (Right (Just SessionRow {status})) -> assertEqual "session still completes" "completed" status
              other -> assertFailure ("session lookup should return a completed row, got " <> show other),
      testCase "Always records a failure memory before failing the session" do
        withShikigamiMigratedDatabase \connStr ->
          withStore (defaultConnectionSettings connStr) \_kirokuStore -> do
            tracer <- noopTracer
            behaviorEnv <- newBehaviorEnv
            let appEnv = AppEnv {connectionSettings = defaultConnectionSettings connStr, tracer, metrics = Nothing}
                alwaysDecl = withRecordPolicy Always missingTaskDecl
                deps = testDepsWithAgents appEnv behaviorEnv defaultAgentRunHooks [alwaysDecl]

            result <- runAgentRunWorkflow deps permanentFailureJob
            case result of
              Right (Completed (Left _)) -> pure ()
              other -> assertFailure ("Always run should fail permanently, got " <> show other)

            memories <- runAppIO appEnv (Memory.getActiveRowsByScope shikigamiMemorySpace (agentScope "missing-task-agent"))
            case memories of
              Right (Right [MemoryRow {content, tags}]) -> do
                assertBool "failure content is explicit" ("run failed: " `Text.isPrefixOf` content)
                assertBool "failure tag is present" (Set.member "failure" tags)
              other -> assertFailure ("expected one failure memory, got " <> show other),
      testCase "recallLimit caps fallback recall" do
        withShikigamiMigratedDatabase \connStr ->
          withStore (defaultConnectionSettings connStr) \_kirokuStore -> do
            tracer <- noopTracer
            let appEnv = AppEnv {connectionSettings = defaultConnectionSettings connStr, tracer, metrics = Nothing}
            forM_ [1 .. 5 :: Int] (recordRecallFixture appEnv)
            limit <- either (assertFailure . Text.unpack) pure (mkRecallLimit 3)
            recalled <- recallPriorLearnings appEnv limit (agentScope "recall-limit-agent") "recall fixture"
            assertEqual "declared bound caps fallback rows" 3 (length recalled),
      testCase "replays completed lifecycle steps for the same run id" do
        withShikigamiMigratedDatabase \connStr ->
          withStore (defaultConnectionSettings connStr) \kirokuStore -> do
            tracer <- noopTracer
            behaviorEnv <- newBehaviorEnv
            let appEnv = AppEnv {connectionSettings = defaultConnectionSettings connStr, tracer, metrics = Nothing}
                deps = testDeps appEnv behaviorEnv defaultAgentRunHooks

            firstRun <- runAgentRunWorkflow deps job
            second <- runAgentRunWorkflow deps job
            outboxRows <- runAppIO appEnv (listOutbox "shinzui/shikigami")

            case (firstRun, second) of
              (Right (Completed (Right AgentRunResult {sessionId = firstSessionId})), Right (Completed (Right AgentRunResult {sessionId = secondSessionId}))) -> do
                assertEqual "open-session replayed the original session id" firstSessionId secondSessionId
                assertEqual "dispatch-sinks enqueued one stable outbox row" (Right 1) (length <$> outboxRows)
              other -> assertEqual "both workflow runs complete successfully" "completed twice" (show other),
      -- The two-phase gate, and the reason both phases exist: the enqueue-time
      -- check decides whether an outbox row is written at all, and the
      -- publish-time check revalidates before delivery. A revocation landing
      -- between them must stop the delivery even though the row is already
      -- queued and its journaled SinkResult already says Delivered.
      testCase "a revocation between enqueue and publish delivers nothing" do
        withShikigamiMigratedDatabase \connStr ->
          withStore (defaultConnectionSettings connStr) \kirokuStore -> do
            received <- newIORef (Map.empty :: Map (Text, Text) Text)
            testWithApplication (pure (kawaDoorwayApplication received)) \port -> do
              tracer <- noopTracer
              behaviorEnv <- newBehaviorEnv
              let appEnv = AppEnv {connectionSettings = defaultConnectionSettings connStr, tracer, metrics = Nothing}
                  pool' = pool kirokuStore
                  deps =
                    (testDeps appEnv behaviorEnv defaultAgentRunHooks)
                      { grants = DbGrants pool',
                        kawa = KawaConfig {baseUrl = "http://localhost:" <> Text.pack (show port), sourceSegment = "shinzui/shikigami"}
                      }

              -- heartbeat/KawaDigest is seeded granted, so the run enqueues.
              runResult <- runAgentRunWorkflow deps job
              outboxBefore <- runAppIO appEnv (listOutbox "shinzui/shikigami")
              assertEqual "the granted run enqueued one outbox row" (Right 1) (length <$> outboxBefore)

              -- Now revoke, and drive the publisher exactly as the worker does.
              _ <- revokeGrant pool' "heartbeat" SKawaDigest (Just "test") >>= either (assertFailure . show) pure
              let publishBatch rows =
                    traverse (\row -> (outboxId row,) <$> publishSinkIntent deps row) rows
              published <- runAppIO appEnv (publishClaimedOutbox publishBatch defaultPublishOptions Nothing)

              delivered <- readIORef received
              assertEqual "the kawa stub received nothing" 0 (Map.size delivered)
              assertBool ("the publish pass itself succeeded: " <> show published) (isRight' published)
              assertBool ("the run completed: " <> show runResult) (isCompleted runResult),
      testCase "resumes after a crash without rerunning journaled step bodies" do
        withShikigamiMigratedDatabase \connStr ->
          withStore (defaultConnectionSettings connStr) \kirokuStore -> do
            tracer <- noopTracer
            behaviorEnv <- newBehaviorEnv
            counts <- newIORef Map.empty
            shouldCrash <- newIORef True
            let appEnv = AppEnv {connectionSettings = defaultConnectionSettings connStr, tracer, metrics = Nothing}
                hooks =
                  defaultAgentRunHooks
                    { beforeStepBody = \stepName -> do
                        modifyIORef' counts (Map.insertWith (+) (unStepName stepName) (1 :: Int))
                        when (unStepName stepName == "run-behavior-v2") do
                          crashNow <- atomicModifyIORef' shouldCrash \current -> (False, current)
                          when crashNow (ioError (userError "simulated crash in run-behavior"))
                    }
                deps = testDeps appEnv behaviorEnv hooks

            crashedRun <- try (runAgentRunWorkflow deps crashJob)
            case crashedRun of
              Left (_ :: SomeException) -> pure ()
              Right other -> assertEqual "first run should crash inside run-behavior" "exception" (show other)

            afterCrash <- readIORef counts
            assertEqual "journaled pre-behavior steps ran once before the crash" (Just 1) (Map.lookup "ingest-job" afterCrash)
            assertEqual "lookup-agent ran once before the crash" (Just 1) (Map.lookup "lookup-agent" afterCrash)
            assertEqual "resolve-profile ran once before the crash" (Just 1) (Map.lookup "resolve-profile" afterCrash)
            assertEqual "open-session ran once before the crash" (Just 1) (Map.lookup "open-session" afterCrash)
            assertEqual "recall ran once before the crash" (Just 1) (Map.lookup "recall" afterCrash)
            assertEqual "run-behavior-v2 was attempted once before the crash" (Just 1) (Map.lookup "run-behavior-v2" afterCrash)

            second <- runAgentRunWorkflow deps crashJob
            case second of
              Right (Completed (Right _result)) -> pure ()
              other -> assertEqual "second run should complete" "completed" (show other)

            finalCounts <- readIORef counts
            assertEqual "ingest-job replayed without rerunning" (Just 1) (Map.lookup "ingest-job" finalCounts)
            assertEqual "lookup-agent replayed without rerunning" (Just 1) (Map.lookup "lookup-agent" finalCounts)
            assertEqual "resolve-profile replayed without rerunning" (Just 1) (Map.lookup "resolve-profile" finalCounts)
            assertEqual "open-session replayed without rerunning" (Just 1) (Map.lookup "open-session" finalCounts)
            assertEqual "recall replayed without rerunning" (Just 1) (Map.lookup "recall" finalCounts)
            assertEqual "run-behavior-v2 reran after its failed attempt" (Just 2) (Map.lookup "run-behavior-v2" finalCounts)
            assertEqual "record ran once after recovery" (Just 1) (Map.lookup "record" finalCounts)
            assertEqual "complete ran once after recovery" (Just 1) (Map.lookup "complete" finalCounts)

            stepKeys <- loadLifecycleStepKeys appEnv crashJob
            assertEqual "one row per completed lifecycle step" (Right expectedLifecycleSteps) stepKeys
            outboxRows <- runAppIO appEnv (listOutbox "shinzui/shikigami")
            assertEqual "recovered run enqueued one stable outbox row" (Right 1) (length <$> outboxRows),
      testCase "an unknown required profile refuses before opening a session" do
        withShikigamiMigratedDatabase \connStr ->
          withStore (defaultConnectionSettings connStr) \_kirokuStore -> do
            tracer <- noopTracer
            behaviorEnv <- newBehaviorEnv
            let appEnv = AppEnv {connectionSettings = defaultConnectionSettings connStr, tracer, metrics = Nothing}
                deps = testDepsWithAgents appEnv behaviorEnv defaultAgentRunHooks [profiledDecl]

            result <- runAgentRunWorkflow deps profileRefusalJob
            case result of
              Right (Completed (Left err)) ->
                assertBool ("failure should name the profile: " <> show err) ("sanctioned-review" `Text.isInfixOf` agentRunFailureDetail err)
              other -> assertFailure ("expected a permanent profile refusal, got " <> show other)

            sessions <- runAppIO appEnv (Session.getByScope shikigamiMemorySpace (agentScope "heartbeat"))
            case sessions of
              Right (Right rows) -> assertEqual "no session was opened" 0 (length rows)
              other -> assertFailure ("session query should succeed, got " <> show (first (const ("store-error" :: String)) other))
            outboxRows <- runAppIO appEnv (listOutbox "shinzui/shikigami")
            assertEqual "no sink intent was enqueued" (Right 0) (length <$> outboxRows),
      testCase "a resumed run keeps the profile content and digest it originally resolved" do
        withShikigamiMigratedDatabase \connStr ->
          withStore (defaultConnectionSettings connStr) \kirokuStore -> do
            tracer <- noopTracer
            behaviorEnv <- newBehaviorEnv
            resolverCalls <- newIORef (0 :: Int)
            shouldCrash <- newIORef True
            let appEnv = AppEnv {connectionSettings = defaultConnectionSettings connStr, tracer, metrics = Nothing}
                profileStore = postgresProfileStore (pool kirokuStore)
                originalContent = workflowProfile (ProfileVersion "1")
                originalDigest = profileDigest originalContent
                originalResolved = resolvedWorkflowProfile originalContent originalDigest
                resolver profileId version = do
                  modifyIORef' resolverCalls (+ 1)
                  now <- getCurrentTime
                  resolveProfile profileStore now profileId version
                hooks =
                  defaultAgentRunHooks
                    { beforeStepBody = \stepName ->
                        when (unStepName stepName == "run-behavior-v2") do
                          crashNow <- atomicModifyIORef' shouldCrash \current -> (False, current)
                          when crashNow (ioError (userError "simulated crash after resolve-profile"))
                    }
                deps =
                  (testDepsWithAgents appEnv behaviorEnv hooks [profiledDecl])
                    { resolveRunProfile = resolver
                    }

            insertWorkflowProfile (pool kirokuStore) originalContent originalDigest
            crashed <- try (runAgentRunWorkflow deps profilePinningJob)
            case crashed of
              Left (_ :: SomeException) -> pure ()
              Right other -> assertFailure ("first run should crash after profile resolution, got " <> show other)

            pinnedBefore <- loadProfileResolution appEnv profilePinningJob
            assertEqual "the original content and digest were journaled" (Right (Just originalResolved)) pinnedBefore

            let replacementContent = workflowProfile (ProfileVersion "2")
                replacementDigest = profileDigest replacementContent
            replaceWorkflowProfile
              (pool kirokuStore)
              sampleWorkflowProfileId
              (ProfileVersion "1")
              replacementContent
              replacementDigest

            resumed <- runAgentRunWorkflow deps profilePinningJob
            case resumed of
              Right (Completed (Right _)) -> pure ()
              other -> assertFailure ("resumed run should complete, got " <> show other)

            calls <- readIORef resolverCalls
            assertEqual "resolution executed only on the first attempt" 1 calls
            pinnedAfter <- loadProfileResolution appEnv profilePinningJob
            assertEqual "replay kept the original profile rather than the replacement" pinnedBefore pinnedAfter,
      testCase "a pinned tuple mismatch refuses before the provider or session boundary" do
        withShikigamiMigratedDatabase \connStr ->
          withStore (defaultConnectionSettings connStr) \_kirokuStore -> do
            tracer <- noopTracer
            behaviorEnv <- newBehaviorEnv
            let appEnv = AppEnv {connectionSettings = defaultConnectionSettings connStr, tracer, metrics = Nothing}
                content = workflowProfileWith defaultThinkingProhibitions (ProfileVersion "1")
                digest = profileDigest content
                resolved = resolvedWorkflowProfile content digest
                deps =
                  (testDepsWithAgents appEnv behaviorEnv defaultAgentRunHooks [profiledSkillDecl])
                    { resolveRunProfile = \_profileId _version -> pure (Right resolved)
                    }

            result <- runAgentRunWorkflow deps profileViolationJob
            case result of
              Right (Completed (Left err)) -> do
                let detail = agentRunFailureDetail err
                assertBool ("violation should name the attempted model: " <> Text.unpack detail) ("stub-v1" `Text.isInfixOf` detail)
                assertBool ("violation should name the pinned digest: " <> Text.unpack detail) (profileDigestText digest `Text.isInfixOf` detail)
              other -> assertFailure ("expected a permanent provider-profile refusal, got " <> show other)

            sessions <- runAppIO appEnv (Session.getByScope shikigamiMemorySpace (agentScope "profiled-skill"))
            case sessions of
              Right (Right rows) -> assertEqual "the provider seam was refused before session creation" 0 (length rows)
              other -> assertFailure ("session query should succeed, got " <> show (first (const ("store-error" :: String)) other)),
      testCase "resumes after a crash between record and complete without duplicating memory" do
        withShikigamiMigratedDatabase \connStr ->
          withStore (defaultConnectionSettings connStr) \kirokuStore -> do
            tracer <- noopTracer
            behaviorEnv <- newBehaviorEnv
            counts <- newIORef Map.empty
            shouldCrash <- newIORef True
            let appEnv = AppEnv {connectionSettings = defaultConnectionSettings connStr, tracer, metrics = Nothing}
                hooks =
                  defaultAgentRunHooks
                    { beforeStepBody = \stepName -> do
                        modifyIORef' counts (Map.insertWith (+) (unStepName stepName) (1 :: Int))
                        when (unStepName stepName == "complete") do
                          crashNow <- atomicModifyIORef' shouldCrash \current -> (False, current)
                          when crashNow (ioError (userError "simulated crash before complete"))
                    }
                deps = testDeps appEnv behaviorEnv hooks

            crashedRun <- try (runAgentRunWorkflow deps recordBeforeCompleteCrashJob)
            case crashedRun of
              Left (_ :: SomeException) -> pure ()
              Right other -> assertEqual "first run should crash before complete" "exception" (show other)

            afterCrash <- readIORef counts
            assertEqual "record step completed before the crash" (Just 1) (Map.lookup "record" afterCrash)
            assertEqual "complete step was reached once before the crash" (Just 1) (Map.lookup "complete" afterCrash)

            resumed <- runAgentRunWorkflow deps recordBeforeCompleteCrashJob
            sid <- case resumed of
              Right (Completed (Right AgentRunResult {sessionId})) -> pure sessionId
              other -> assertFailure ("resumed run should complete, got " <> show other)

            finalCounts <- readIORef counts
            assertEqual "record replayed without rerunning" (Just 1) (Map.lookup "record" finalCounts)
            assertEqual "complete body ran once after recovery" (Just 2) (Map.lookup "complete" finalCounts)

            memories <- runAppIO appEnv (Memory.getRowsBySession shikigamiMemorySpace sid)
            case memories of
              Right (Right rows) -> assertEqual "exactly one memory row for the resumed session" 1 (length rows)
              other -> assertFailure ("memory lookup should succeed, got " <> show other)

            session <- runAppIO appEnv (Session.getById shikigamiMemorySpace sid)
            case session of
              Right (Right (Just SessionRow {status, modelUsed})) -> do
                assertEqual "session completed after resume" "completed" status
                -- The durable half of the promise that a stub never passes for
                -- a model: whatever answered is named on the row, so a run made
                -- without a model is identifiable long after the process that
                -- logged its provider has gone.
                assertEqual "the completed session names the model that answered" (Just "stub-v1") modelUsed
              other -> assertFailure ("session lookup should return completed row, got " <> show other),
      testCase "runs Flow behavior through the agent workflow" do
        withShikigamiMigratedDatabase \connStr ->
          withStore (defaultConnectionSettings connStr) \kirokuStore -> do
            tracer <- noopTracer
            behaviorEnv <- newBehaviorEnv
            let appEnv = AppEnv {connectionSettings = defaultConnectionSettings connStr, tracer, metrics = Nothing}
                deps = testDepsWithAgents appEnv behaviorEnv defaultAgentRunHooks [flowDecl]

            result <- runAgentRunWorkflow deps flowJob
            case result of
              Right (Completed (Right AgentRunResult {behaviorOutput})) ->
                assertEqual "flow behavior returns its classified verdict" expectedFlowOutput behaviorOutput
              other -> assertFailure ("flow behavior should complete, got " <> show other)

            outboxRows <- runAppIO appEnv (listOutbox "shinzui/shikigami")
            assertEqual "low-risk flow emits no sink outbox rows" (Right 0) (length <$> outboxRows),
      -- The durable half of the memory proof. The pure rules live in
      -- "Shikigami.BehaviorInputSpec"; this runs the whole
      -- open-session → recall → flow → emit pipeline against a real database
      -- and shows a decision changed by something the agent learned earlier.
      --
      -- The payload is the same calm text the low-risk case above uses, and the
      -- flow reaches the opposite verdict — so it is memory, not the trigger,
      -- that moved it. Recall works without a vector extension because
      -- 'Shikigami.Agent.Run.recallPriorLearnings' falls back to
      -- @getActiveByScope@, which makes this deterministic in CI.
      testCase "a recalled escalation flips the flow's verdict on a calm payload" do
        withShikigamiMigratedDatabase \connStr ->
          withStore (defaultConnectionSettings connStr) \kirokuStore -> do
            tracer <- noopTracer
            behaviorEnv <- newBehaviorEnv
            let appEnv = AppEnv {connectionSettings = defaultConnectionSettings connStr, tracer, metrics = Nothing}
                deps = testDepsWithAgents appEnv behaviorEnv defaultAgentRunHooks [flowDecl]

            recordPriorEscalation appEnv (idempotencyKey flowMemoryJob)

            -- A high verdict emits its alert and then parks awaiting
            -- acknowledgement; the low case above completes outright. Parking
            -- is itself the branch evidence, and the emitted row carries the
            -- verdict that caused it.
            parked <- runAgentRunWorkflow deps flowMemoryJob
            case parked of
              Right Suspended -> pure ()
              other -> assertEqual "high-risk flow parks awaiting acknowledgement" "Suspended" (show other)

            outboxRows <- runAppIO appEnv (listOutbox "shinzui/shikigami")
            case outboxRows of
              Right [OutboxRow {event}] ->
                case decodeJsonIntegrationEvent event of
                  Right SinkIntent {output} ->
                    assertEqual
                      "the emitted signal carries a verdict the recalled memory forced"
                      ( object
                          [ "level" .= ("high" :: Text),
                            "rationale" .= ("prior escalation on this subject: customer relationship at risk" :: Text),
                            "ticketId" .= idempotencyKey flowMemoryJob
                          ]
                      )
                      output
                  Left err -> assertFailure ("the outbox row should decode as a sink intent, got " <> show err)
              other -> assertFailure ("expected exactly one emitted signal, got " <> show (fmap length other)),
      testGroup
        "Conversation"
        [ testCase "parks and resumes a danwa conversation as one workflow session" do
            withShikigamiMigratedDatabase \connStr ->
              withStore (defaultConnectionSettings connStr) \kirokuStore -> do
                tracer <- noopTracer
                behaviorEnv <- newBehaviorEnv
                let appEnv = AppEnv {connectionSettings = defaultConnectionSettings connStr, tracer, metrics = Nothing}
                    env = testConversationEnv appEnv behaviorEnv [conversationDecl]

                firstTurn <- Conversation.runConversationTurn env conversationDecl firstAddressedMessage
                secondTurn <- Conversation.runConversationTurn env conversationDecl secondAddressedMessage

                case (firstTurn, secondTurn) of
                  (Right firstResult, Right secondResult) -> do
                    assertEqual "second human turn reuses the first kioku session" (Conversation.sessionId firstResult) (Conversation.sessionId secondResult)
                    assertBool "first reply is represented by a durable outbox message" ("outbox:danwa-conversation:conv_thread_1:danwa-reply:msg_human_1" `Text.isPrefixOf` Conversation.replyMessageId firstResult)
                    assertBool "second reply is represented by a durable outbox message" ("outbox:danwa-conversation:conv_thread_1:danwa-reply:msg_human_2" `Text.isPrefixOf` Conversation.replyMessageId secondResult)

                    turns <- runAppIO appEnv (Session.getTurns shikigamiMemorySpace (Conversation.sessionId firstResult))
                    case turns of
                      Right (Right rows) ->
                        assertEqual
                          "one conversation session records user/assistant/user/assistant"
                          [("user", 0), ("assistant", 1), ("user", 2), ("assistant", 3)]
                          (turnRoleIndex <$> rows)
                      other -> assertFailure ("getTurns should return conversation turns, got " <> show (first (const ("store-error" :: String)) other))

                    outboxRows <- runAppIO appEnv (listOutbox "shinzui/shikigami")
                    assertEqual "two danwa replies are queued through the outbox" (Right 2) (length <$> outboxRows)

                    pending <- runAppIO appEnv countPendingAwakeables
                    assertEqual "workflow parks again after the second reply" (Right 1) pending

                    -- One turn per generation, so the two turns are on two
                    -- generations and each label appears once in its own -- not
                    -- twice in one under two different computed suffixes.
                    firstKeys <- conversationStepKeys appEnv firstAddressedMessage 0
                    secondKeys <- conversationStepKeys appEnv firstAddressedMessage 1

                    assertBool "the first turn's result is journaled in generation 0" (Map.member "turn-result" firstKeys)
                    assertBool "the second turn's result is journaled in generation 1" (Map.member "turn-result" secondKeys)
                    assertBool "the first assistant turn and reply are one durable step" (Map.member "record-assistant-and-reply" firstKeys)
                    assertBool "the second assistant turn and reply are one durable step" (Map.member "record-assistant-and-reply" secondKeys)

                    -- The label carries no message id any more, so "one
                    -- turn-result per generation" is the property that replaces
                    -- "one turn-result per message".
                    assertEqual "generation 0 holds exactly one turn result" 1 (length (filter (== "turn-result") (Map.keys firstKeys)))
                    assertEqual "generation 1 holds exactly one turn result" 1 (length (filter (== "turn-result") (Map.keys secondKeys)))

                    -- danwa-reply names the outbox row, not a journal step.
                    assertBool "the first reply is not journaled as a separate sink step" (not (any ("danwa-reply" `Text.isPrefixOf`) (Map.keys firstKeys)))
                    assertBool "the second reply is not journaled as a separate sink step" (not (any ("danwa-reply" `Text.isPrefixOf`) (Map.keys secondKeys)))

                    -- The await label lost its ordinal with everything else: a
                    -- generation arms exactly one next-message promise.
                    assertEqual "generation 0 armed the static next-message promise" ["awkid:next-message"] (filter ("awkid:" `Text.isPrefixOf`) (Map.keys firstKeys))
                    assertEqual "generation 1 armed the static next-message promise" ["awkid:next-message"] (filter ("awkid:" `Text.isPrefixOf`) (Map.keys secondKeys))
                  other -> assertFailure ("conversation turns should succeed, got " <> show other),
          testCase "conversation permanent v2 failure completes as a replayable typed failure" do
            withShikigamiMigratedDatabase \connStr ->
              withStore (defaultConnectionSettings connStr) \_kirokuStore -> do
                tracer <- noopTracer
                behaviorEnv <- newBehaviorEnv
                let appEnv = AppEnv {connectionSettings = defaultConnectionSettings connStr, tracer, metrics = Nothing}
                    env = testConversationEnv appEnv behaviorEnv [missingTaskDecl]

                firstFailure <- Conversation.runConversationTurn env missingTaskDecl permanentConversationMessage
                replayed <- Conversation.runConversationTurn env missingTaskDecl permanentConversationMessage
                assertBool
                  ("first turn returns the permanent detail: " <> show firstFailure)
                  (either (Text.isInfixOf "unknown task" . Conversation.conversationTurnFailureDetail) (const False) firstFailure)
                assertEqual "replay returns the same typed failure" firstFailure replayed
                stepIndex <- conversationStepKeys appEnv permanentConversationMessage 0
                assertBool "conversation journals the static v2 label" (Map.member "run-behavior-v2" stepIndex)
                assertBool "conversation never journals the legacy label" (not (Map.member "run-behavior" stepIndex)),
          -- Session resolution used to be a linear scan over every session the
          -- agent had ever had, filtered on subjectRef. It is now a keyed read
          -- of shikigami.conversation_sessions, confirmed against kioku. The
          -- decoy is a running session in the same scope under a different
          -- subject: the exact row the scan had to walk past, and the exact row
          -- a mis-keyed lookup would return.
          testCase "resolves its own session and ignores a decoy in the same scope" do
            withShikigamiMigratedDatabase \connStr ->
              withStore (defaultConnectionSettings connStr) \_kirokuStore -> do
                tracer <- noopTracer
                behaviorEnv <- newBehaviorEnv
                let appEnv = AppEnv {connectionSettings = defaultConnectionSettings connStr, tracer, metrics = Nothing}
                    env = testConversationEnv appEnv behaviorEnv [conversationDecl]

                decoy <- startDecoyConversationSession appEnv "heartbeat" "conv_decoy_thread"

                firstTurn <- Conversation.runConversationTurn env conversationDecl firstAddressedMessage
                secondTurn <- Conversation.runConversationTurn env conversationDecl secondAddressedMessage

                case (firstTurn, secondTurn) of
                  (Right firstResult, Right secondResult) -> do
                    let sid = Conversation.sessionId firstResult
                    assertEqual "both turns resolve the same session" sid (Conversation.sessionId secondResult)
                    assertBool "the decoy in the same scope is never selected" (sid /= decoy)

                    indexed <- runAppIO appEnv (SessionIndex.lookupConversationSession "conv_thread_1")
                    assertEqual
                      "the index points at this conversation's own session"
                      (Right (Just (idText sid)))
                      indexed

                    -- The decoy was started outside the conversation path, so
                    -- nothing indexed it. That is what makes the hit above a
                    -- keyed answer rather than a coincidence.
                    decoyIndexed <- runAppIO appEnv (SessionIndex.lookupConversationSession "conv_decoy_thread")
                    assertEqual "the decoy conversation has no index row" (Right Nothing) decoyIndexed

                    ours <- runningSessionsFor appEnv "heartbeat" "conv_thread_1"
                    assertEqual "exactly one running session carries this conversation id" [idText sid] ours

                    theirs <- runningSessionsFor appEnv "heartbeat" "conv_decoy_thread"
                    assertEqual "the decoy is still running and untouched" [idText decoy] theirs
                  other -> assertFailure ("both conversation turns should succeed, got " <> show other),
          -- The ingress path used to read the step index at a hard-coded
          -- generation 0. That is correct only while nothing rotates the
          -- journal, and M2 makes every turn rotate. Reading the resolved
          -- generation must be behaviour-preserving *before* rotation exists,
          -- which is what this pins: delivery finds the armed promise on a
          -- parked conversation, and refuses one that was never started rather
          -- than throwing.
          testCase "delivery resolves the live generation instead of assuming zero" do
            withShikigamiMigratedDatabase \connStr ->
              withStore (defaultConnectionSettings connStr) \_kirokuStore -> do
                tracer <- noopTracer
                behaviorEnv <- newBehaviorEnv
                let appEnv = AppEnv {connectionSettings = defaultConnectionSettings connStr, tracer, metrics = Nothing}
                    env = testConversationEnv appEnv behaviorEnv [conversationDecl]

                -- Nothing has run, so there is no instance and no generation.
                -- currentGeneration answers 0 for an unknown workflow, so this
                -- is also the proof that the new read is total.
                cold <- Conversation.deliverConversationInputFromApp appEnv firstAddressedMessage
                assertEqual "a conversation that never started has nothing to deliver to" False cold

                firstTurn <- Conversation.runConversationTurn env conversationDecl firstAddressedMessage
                assertBool ("first turn should succeed, got " <> show firstTurn) (either (const False) (const True) firstTurn)

                -- The turn parked on next-message, so the promise is armed and
                -- discoverable through the resolved generation.
                delivered <- Conversation.deliverConversationInputFromApp appEnv secondAddressedMessage
                assertEqual "a parked conversation accepts the next message" True delivered

                -- Signalling the same promise twice must not resolve it twice.
                again <- Conversation.deliverConversationInputFromApp appEnv secondAddressedMessage
                assertEqual "the promise is consumed once" False again,
          -- The bounded-journal claim, stated as something that can fail. The
          -- old body ran every turn of a conversation in one immortal
          -- generation, so replay cost grew with the conversation and never
          -- recovered. Five turns now means five generations, each holding one
          -- turn's worth of labels -- and all five turns still land in ONE kioku
          -- session, because rotation bounds the journal, not the conversation.
          testCase "rotates onto a fresh generation after every turn" do
            withShikigamiMigratedDatabase \connStr ->
              withStore (defaultConnectionSettings connStr) \_kirokuStore -> do
                tracer <- noopTracer
                behaviorEnv <- newBehaviorEnv
                let appEnv = AppEnv {connectionSettings = defaultConnectionSettings connStr, tracer, metrics = Nothing}
                    env = testConversationEnv appEnv behaviorEnv [conversationDecl]
                    messages = [conversationMessageNumbered n | n <- [1 .. 5]]

                results <- traverse (Conversation.runConversationTurn env conversationDecl) messages
                sessions <-
                  traverse
                    ( \(n, result) -> case result of
                        Right turnResult -> pure (Conversation.sessionId turnResult)
                        Left err -> assertFailure ("turn " <> show (n :: Int) <> " should succeed, got " <> show err)
                    )
                    (zip [1 ..] results)

                conversationSession <- case sessions of
                  [] -> assertFailure "five turns should produce five results"
                  firstSession : rest -> do
                    assertBool "all five turns are recorded in one kioku session" (all (== firstSession) rest)
                    pure firstSession

                -- Generation 4 exists, which is the rotation claim: turn N ran
                -- in generation N-1.
                generation4 <- conversationStepKeys appEnv (conversationMessageNumbered 1) 4
                assertBool "the fifth turn ran in generation 4" (Map.member "turn-result" generation4)

                -- No generation holds two turns. This is the property the
                -- static labels depend on and the one that bounds replay.
                forM_ [0 .. 4] \generation -> do
                  keys <- conversationStepKeys appEnv (conversationMessageNumbered 1) generation
                  assertEqual
                    ("generation " <> show generation <> " holds exactly one turn result")
                    1
                    (length (filter (== "turn-result") (Map.keys keys)))
                  assertEqual
                    ("generation " <> show generation <> " armed exactly one next-message promise")
                    ["awkid:next-message"]
                    (filter ("awkid:" `Text.isPrefixOf`) (Map.keys keys))

                -- Ten turns in one session, in order, is what proves rotation
                -- bounded the journal without fragmenting the conversation.
                turns <- runAppIO appEnv (Session.getTurns shikigamiMemorySpace conversationSession)
                case turns of
                  Right (Right rows) ->
                    assertEqual
                      "five turns are recorded as five user/assistant pairs"
                      [(role, index) | index <- [0 .. 9], let role = if even index then "user" else "assistant"]
                      (turnRoleIndex <$> rows)
                  other -> assertFailure ("getTurns should return conversation turns, got " <> show (first (const ("store-error" :: String)) other)),
          -- The lifecycle claim. Before this, a conversation workflow never
          -- ended and its kioku session stayed "running" forever -- a leak, and
          -- a correctness hazard for a resolver that only ever reused running
          -- sessions. The idle timer signals the same next-message awakeable the
          -- next human message would have signalled, so the workflow ends
          -- through its own await rather than being killed from outside.
          testCase "completes the kioku session on idle timeout" do
            withShikigamiMigratedDatabase \connStr ->
              withStore (defaultConnectionSettings connStr) \_kirokuStore -> do
                tracer <- noopTracer
                behaviorEnv <- newBehaviorEnv
                let appEnv = AppEnv {connectionSettings = defaultConnectionSettings connStr, tracer, metrics = Nothing}
                    env = testConversationEnvIdle (secondsToNominalDiffTime 1) appEnv behaviorEnv [conversationDecl]

                firstTurn <- Conversation.runConversationTurn env conversationDecl firstAddressedMessage
                sid <- case firstTurn of
                  Right result -> pure (Conversation.sessionId result)
                  Left err -> assertFailure ("first turn should succeed, got " <> show err)

                (runningStatus, _) <- conversationSessionState appEnv sid
                assertEqual "the session is running while the conversation is parked" "running" runningStatus

                fired <- fireDueConversationIdleTimer appEnv
                assertBool "the idle timer fires" fired

                -- Firing resolves the awakeable; driving the workflow is what
                -- lets it observe the timeout and end.
                resumed <- Conversation.runConversationTurn env conversationDecl firstAddressedMessage
                assertBool ("the epoch should end cleanly, got " <> show resumed) (either (const False) (const True) resumed)

                (completedStatus, _) <- conversationSessionState appEnv sid
                assertEqual "the idle timeout completes the kioku session" "completed" completedStatus

                pending <- runAppIO appEnv countPendingAwakeables
                assertEqual "the ended epoch leaves no promise armed" (Right 0) pending,
          -- A timer armed for turn N belongs to the generation turn N+1 closed.
          -- Under one turn per generation the generation IS the staleness token,
          -- so this is a property of the timer id rather than of a counter
          -- somebody has to keep in step -- but it is only testable if the stale
          -- timer is actually fired.
          testCase "ignores a timer armed in a superseded generation" do
            withShikigamiMigratedDatabase \connStr ->
              withStore (defaultConnectionSettings connStr) \_kirokuStore -> do
                tracer <- noopTracer
                behaviorEnv <- newBehaviorEnv
                let appEnv = AppEnv {connectionSettings = defaultConnectionSettings connStr, tracer, metrics = Nothing}
                    env = testConversationEnvIdle (secondsToNominalDiffTime 1) appEnv behaviorEnv [conversationDecl]

                firstTurn <- Conversation.runConversationTurn env conversationDecl firstAddressedMessage
                sid <- case firstTurn of
                  Right result -> pure (Conversation.sessionId result)
                  Left err -> assertFailure ("first turn should succeed, got " <> show err)

                -- The second message rotates generation 0 shut, which is what
                -- makes generation 0's armed timer stale.
                secondTurn <- Conversation.runConversationTurn env conversationDecl secondAddressedMessage
                assertBool ("second turn should succeed, got " <> show secondTurn) (either (const False) (const True) secondTurn)

                -- Fire every due timer, generation 0's included.
                _ <- fireDueConversationIdleTimer appEnv
                _ <- fireDueConversationIdleTimer appEnv

                stale <- conversationStepKeys appEnv firstAddressedMessage 0
                assertBool "the superseded generation records no terminal step" (not (Map.member "idle-timeout" stale))

                (liveStatus, _) <- conversationSessionState appEnv sid
                assertEqual "the live conversation's session is untouched" "running" liveStatus

                -- And the conversation still works.
                thirdTurn <- Conversation.runConversationTurn env conversationDecl (conversationMessageNumbered 3)
                assertBool ("the conversation continues, got " <> show thirdTurn) (either (const False) (const True) thirdTurn),
          -- The other half of ending an epoch: the next message opens a NEW
          -- session that names the closed one, so a conversation's history stays
          -- walkable across every epoch it has had. previousSessionId was
          -- unconditionally Nothing before, which was the only honest answer
          -- while nothing ever completed a session.
          testCase "opens a new epoch after idle timeout, chaining session lineage" do
            withShikigamiMigratedDatabase \connStr ->
              withStore (defaultConnectionSettings connStr) \_kirokuStore -> do
                tracer <- noopTracer
                behaviorEnv <- newBehaviorEnv
                let appEnv = AppEnv {connectionSettings = defaultConnectionSettings connStr, tracer, metrics = Nothing}
                    env = testConversationEnvIdle (secondsToNominalDiffTime 1) appEnv behaviorEnv [conversationDecl]

                firstTurn <- Conversation.runConversationTurn env conversationDecl firstAddressedMessage
                firstSession <- case firstTurn of
                  Right result -> pure (Conversation.sessionId result)
                  Left err -> assertFailure ("first turn should succeed, got " <> show err)

                _ <- fireDueConversationIdleTimer appEnv
                ended <- Conversation.runConversationTurn env conversationDecl firstAddressedMessage
                assertBool ("the epoch should end, got " <> show ended) (either (const False) (const True) ended)

                (closedStatus, _) <- conversationSessionState appEnv firstSession
                assertEqual "the first epoch's session is closed" "completed" closedStatus

                -- A message after the timeout finds a terminated workflow, so it
                -- starts a fresh epoch.
                nextEpoch <- Conversation.runConversationTurn env conversationDecl secondAddressedMessage
                secondSession <- case nextEpoch of
                  Right result -> pure (Conversation.sessionId result)
                  Left err -> assertFailure ("the next epoch's turn should succeed, got " <> show err)

                assertBool "the new epoch opens a different session" (secondSession /= firstSession)

                (openedStatus, openedPrevious) <- conversationSessionState appEnv secondSession
                assertEqual "the new epoch's session is running" "running" openedStatus
                assertEqual
                  "the new epoch names the closed session as its predecessor"
                  (Just (idText firstSession))
                  openedPrevious

                -- The index moved with the conversation, so the next turn
                -- resolves the new session rather than the closed one.
                indexed <- runAppIO appEnv (SessionIndex.lookupConversationSession "conv_thread_1")
                assertEqual "the index follows the conversation into its new epoch" (Right (Just (idText secondSession))) indexed

                -- The new epoch is a new workflow INSTANCE, which is the whole
                -- reason the epoch exists: a completed keiro instance replays
                -- its completion rather than accepting new work, so reusing the
                -- id would have swallowed this message and returned the previous
                -- epoch's result.
                epochNow <- runAppIO appEnv (SessionIndex.lookupConversationEpoch "conv_thread_1")
                assertEqual "the conversation advanced to epoch 1" (Right 1) epochNow

                epoch0 <- conversationStepKeysAt 0 appEnv secondAddressedMessage 0
                epoch1 <- conversationStepKeysAt 1 appEnv secondAddressedMessage 0
                assertBool "epoch 0's journal holds the timeout that ended it" (Map.member "idle-timeout" epoch0)
                assertBool "epoch 1 has a journal of its own" (Map.member "turn-result" epoch1)
                assertBool "epoch 1 did not end" (not (Map.member "idle-timeout" epoch1))
        ],
      testGroup
        "Delegate"
        [ testCase "parent suspends awaiting delegated child and resumes with child output" do
            withShikigamiMigratedDatabase \connStr ->
              withStore (defaultConnectionSettings connStr) \kirokuStore -> do
                tracer <- noopTracer
                behaviorEnv <- newBehaviorEnv
                parentSession <- genSessionId
                let appEnv = AppEnv {connectionSettings = defaultConnectionSettings connStr, tracer, metrics = Nothing}
                    deps = testDeps appEnv behaviorEnv defaultAgentRunHooks
                    parentWorkflowName = WorkflowName "shikigami.test-delegate-parent"
                    parentWorkflowId = WorkflowId "delegate-parent-1"
                    childWorkflowId = delegatedWorkflowId parentWorkflowId "heartbeat" 0
                    parentBody = parentDelegateWorkflow parentSession

                parked <- runAppIO appEnv (runWorkflow parentWorkflowName parentWorkflowId parentBody)
                assertEqual "parent parks on delegated child" (Right Suspended) parked

                childRun <-
                  runAppIO appEnv $
                    runChildWorkflow
                      defaultWorkflowRunOptions
                      agentRunWorkflowName
                      childWorkflowId
                      (agentRunWorkflow deps Nothing)
                childOutput <-
                  case childRun of
                    Right (Completed (Right AgentRunResult {behaviorOutput = childBehaviorOutput})) -> pure childBehaviorOutput
                    other -> assertFailure ("child agent workflow should complete, got " <> show other)

                resumed <- runAppIO appEnv (runWorkflow parentWorkflowName parentWorkflowId parentBody)
                assertEqual "parent resumes with child behavior output" (Right (Completed childOutput)) resumed,
          testCase "proof supervisor fans out to specialists and records lineage" do
            withShikigamiMigratedDatabase \connStr ->
              withStore (defaultConnectionSettings connStr) \kirokuStore -> do
                tracer <- noopTracer
                behaviorEnv <- newBehaviorEnv
                proofAgents <- loadProofAgents
                let appEnv = AppEnv {connectionSettings = defaultConnectionSettings connStr, tracer, metrics = Nothing}
                    deps = testDepsWithAgents appEnv behaviorEnv defaultAgentRunHooks proofAgents
                    parentWorkflowId = WorkflowId "research-supervisor:test-fanout"
                    webWorkflowId = delegatedWorkflowId parentWorkflowId "web-researcher" 0
                    codeWorkflowId = delegatedWorkflowId parentWorkflowId "code-researcher" 1
                    WorkflowId webWorkflowIdText = webWorkflowId
                    WorkflowId codeWorkflowIdText = codeWorkflowId
                    expectedRunningChildLinks =
                      Set.fromList
                        [ ("shikigami.agent-run", webWorkflowIdText, "running"),
                          ("shikigami.agent-run", codeWorkflowIdText, "running")
                        ]

                parked <- runAgentRunWorkflow deps researchSupervisorJob
                assertEqual "research supervisor parks after spawning children" (Right Suspended) parked
                childLinksAfterPark <- runAppIO appEnv (lookupChildrenOfParent "research-supervisor:test-fanout" "shikigami.agent-run")
                assertEqual
                  "initial park creates two running child workflow links"
                  (Right expectedRunningChildLinks)
                  (childLinkSummary <$> childLinksAfterPark)

                replayedWhileChildrenPending <- runAgentRunWorkflow deps researchSupervisorJob
                assertEqual "parent replay while children are pending parks again" (Right Suspended) replayedWhileChildrenPending
                childLinksAfterReplay <- runAppIO appEnv (lookupChildrenOfParent "research-supervisor:test-fanout" "shikigami.agent-run")
                assertEqual
                  "parent replay does not duplicate delegated children"
                  (childLinkSummary <$> childLinksAfterPark)
                  (childLinkSummary <$> childLinksAfterReplay)

                webRun <-
                  runAppIO appEnv $
                    runChildWorkflow
                      defaultWorkflowRunOptions
                      agentRunWorkflowName
                      webWorkflowId
                      (agentRunWorkflow deps Nothing)
                assertChildCompleted "web specialist completes" webRun

                codeRun <-
                  runAppIO appEnv $
                    runChildWorkflow
                      defaultWorkflowRunOptions
                      agentRunWorkflowName
                      codeWorkflowId
                      (agentRunWorkflow deps Nothing)
                assertChildCompleted "code specialist completes" codeRun

                resumed <- runAgentRunWorkflow deps researchSupervisorJob
                parentSession <-
                  case resumed of
                    Right (Completed (Right AgentRunResult {sessionId = parentSessionId', behaviorOutput})) -> do
                      assertEqual "supervisor synthesizes both findings" expectedSupervisorOutput behaviorOutput
                      pure parentSessionId'
                    other -> assertFailure ("research supervisor should complete after children, got " <> show other)

                children <- runAppIO appEnv (Session.getDelegationChildren shikigamiMemorySpace parentSession)
                case children of
                  Right (Right rows) ->
                    assertEqual
                      "kioku records both delegated child sessions"
                      ( Set.fromList
                          [ ("web-researcher", Just (idText parentSession), 1),
                            ("code-researcher", Just (idText parentSession), 1)
                          ]
                      )
                      (lineageSummary rows)
                  other -> assertFailure ("getDelegationChildren should return rows, got " <> show (first (const ("store-error" :: String)) other))
        ],
      testGroup
        "Approval"
        [ testCase "approved answer resumes and dispatches sink once" do
            withShikigamiMigratedDatabase \connStr ->
              withStore (defaultConnectionSettings connStr) \kirokuStore -> do
                tracer <- noopTracer
                behaviorEnv <- newBehaviorEnv
                aidRef <- newIORef Nothing
                let appEnv = AppEnv {connectionSettings = defaultConnectionSettings connStr, tracer, metrics = Nothing}
                    deps = testDepsWithApproval appEnv behaviorEnv defaultAgentRunHooks (approvalEnv aidRef)

                parked <- runAgentRunWorkflow deps approvalJob
                case parked of
                  Right Suspended -> pure ()
                  other -> assertEqual "workflow parks for approval" "Suspended" (show other)

                pending <- runAppIO appEnv countPendingAwakeables
                assertEqual "one awakeable is pending while parked" (Right 1) pending
                beforeOutbox <- runAppIO appEnv (listOutbox "shinzui/shikigami")
                assertEqual "sink is not dispatched before approval" (Right 0) (length <$> beforeOutbox)

                aid <- readCapturedAwakeable aidRef
                resolved <- resolveApproval appEnv aid (Approved (object ["approved" .= True]))
                assertBool "approval signal resolves the awakeable" resolved
                resumed <- runAppIO appEnv (resumeWorkflowsOnce defaultWorkflowResumeOptions (agentRunRegistry deps))
                assertEqual "resume pass completes the approved workflow" (Right 1) (completed <$> resumed)

                afterOutbox <- runAppIO appEnv (listOutbox "shinzui/shikigami")
                assertEqual "approved sink is dispatched once" (Right 1) (length <$> afterOutbox),
          testCase "rejected answer resumes and suppresses sink dispatch" do
            withShikigamiMigratedDatabase \connStr ->
              withStore (defaultConnectionSettings connStr) \kirokuStore -> do
                tracer <- noopTracer
                behaviorEnv <- newBehaviorEnv
                aidRef <- newIORef Nothing
                let appEnv = AppEnv {connectionSettings = defaultConnectionSettings connStr, tracer, metrics = Nothing}
                    deps = testDepsWithApproval appEnv behaviorEnv defaultAgentRunHooks (approvalEnv aidRef)

                parked <- runAgentRunWorkflow deps rejectedJob
                case parked of
                  Right Suspended -> pure ()
                  other -> assertEqual "workflow parks for approval" "Suspended" (show other)

                aid <- readCapturedAwakeable aidRef
                resolved <- resolveApproval appEnv aid (Rejected "not approved")
                assertBool "rejection signal resolves the awakeable" resolved
                resumed <- runAppIO appEnv (resumeWorkflowsOnce defaultWorkflowResumeOptions (agentRunRegistry deps))
                assertEqual "resume pass completes the rejected workflow" (Right 1) (completed <$> resumed)

                afterOutbox <- runAppIO appEnv (listOutbox "shinzui/shikigami")
                assertEqual "rejected sink is suppressed" (Right 0) (length <$> afterOutbox)
        ],
      testGroup
        "Deadline"
        [ testCase "timeout resumes and suppresses sink dispatch" do
            withShikigamiMigratedDatabase \connStr ->
              withStore (defaultConnectionSettings connStr) \kirokuStore -> do
                tracer <- noopTracer
                behaviorEnv <- newBehaviorEnv
                aidRef <- newIORef Nothing
                let appEnv = AppEnv {connectionSettings = defaultConnectionSettings connStr, tracer, metrics = Nothing}
                    deps = testDepsWithApprovalAndDeadline appEnv behaviorEnv defaultAgentRunHooks (approvalEnv aidRef) (Just (secondsToNominalDiffTime 1))

                parked <- runAgentRunWorkflow deps timeoutJob
                case parked of
                  Right Suspended -> pure ()
                  other -> assertEqual "workflow parks for approval deadline" "Suspended" (show other)

                fireDueApprovalTimer appEnv
                resumed <- runAppIO appEnv (resumeWorkflowsOnce defaultWorkflowResumeOptions (agentRunRegistry deps))
                assertEqual "resume pass completes the timed-out workflow" (Right 1) (completed <$> resumed)

                afterOutbox <- runAppIO appEnv (listOutbox "shinzui/shikigami")
                assertEqual "timed-out sink is suppressed" (Right 0) (length <$> afterOutbox),
          testCase "approved answer before deadline wins over late timer" do
            withShikigamiMigratedDatabase \connStr ->
              withStore (defaultConnectionSettings connStr) \kirokuStore -> do
                tracer <- noopTracer
                behaviorEnv <- newBehaviorEnv
                aidRef <- newIORef Nothing
                let appEnv = AppEnv {connectionSettings = defaultConnectionSettings connStr, tracer, metrics = Nothing}
                    deps = testDepsWithApprovalAndDeadline appEnv behaviorEnv defaultAgentRunHooks (approvalEnv aidRef) (Just (secondsToNominalDiffTime 1))

                parked <- runAgentRunWorkflow deps answeredBeforeDeadlineJob
                case parked of
                  Right Suspended -> pure ()
                  other -> assertEqual "workflow parks for approval deadline" "Suspended" (show other)

                aid <- readCapturedAwakeable aidRef
                resolved <- resolveApproval appEnv aid (Approved (object ["approved" .= True]))
                assertBool "approval signal resolves before deadline" resolved
                fireDueApprovalTimer appEnv
                resumed <- runAppIO appEnv (resumeWorkflowsOnce defaultWorkflowResumeOptions (agentRunRegistry deps))
                assertEqual "resume pass completes the approved workflow" (Right 1) (completed <$> resumed)

                afterOutbox <- runAppIO appEnv (listOutbox "shinzui/shikigami")
                assertEqual "approved sink still dispatches once" (Right 1) (length <$> afterOutbox)
        ]
    ]

parentDelegateWorkflow :: SessionId -> Eff (Workflow : AppEffects) Value
parentDelegateWorkflow currentSession = do
  delegated <-
    delegate
      DelegateCtx
        { delegateDepth = 0,
          sessionId = Just (idText currentSession),
          parentSessionId = Nothing,
          parentRunWorkflowId = Nothing
        }
      "heartbeat"
      (object ["source" .= ("delegate-test" :: Text)])
  awaitDelegated delegated

testDeps :: AppEnv -> BehaviorEnv -> AgentRunHooks -> AgentRunDeps
testDeps appEnv behaviorEnv hooks =
  testDepsWithApproval appEnv behaviorEnv hooks defaultApprovalEnv

testDepsWithAgents :: AppEnv -> BehaviorEnv -> AgentRunHooks -> [AgentDecl] -> AgentRunDeps
testDepsWithAgents appEnv behaviorEnv hooks agentDecls =
  AgentRunDeps
    { appEnv,
      behaviorEnv,
      agents = agentDecls,
      kizashi = KizashiConfig {baseUrl = "http://localhost:1", defaultRecipient = "recipient"},
      kawa = KawaConfig {baseUrl = "http://localhost:1", sourceSegment = "shinzui/shikigami"},
      danwa = DanwaConfig {baseUrl = "http://localhost:1", agentParticipant = "part_agent_test"},
      rei = ReiConfig {baseUrl = Nothing},
      hooks,
      approval = defaultApprovalEnv,
      deadline = Nothing,
      runTimeout = secondsToNominalDiffTime 300,
      logger = Log.silentLogger,
      grants = StaticGrants defaultGrantTable,
      resolveRunProfile = \profileId version -> pure (Left (UnknownProfile profileId version))
    }

testDepsWithApproval :: AppEnv -> BehaviorEnv -> AgentRunHooks -> (SessionId -> ApprovalEnv) -> AgentRunDeps
testDepsWithApproval appEnv behaviorEnv hooks approval =
  testDepsWithApprovalAndDeadline appEnv behaviorEnv hooks approval Nothing

testDepsWithApprovalAndDeadline :: AppEnv -> BehaviorEnv -> AgentRunHooks -> (SessionId -> ApprovalEnv) -> Maybe NominalDiffTime -> AgentRunDeps
testDepsWithApprovalAndDeadline appEnv behaviorEnv hooks approval deadline =
  AgentRunDeps
    { appEnv,
      behaviorEnv,
      agents = [decl],
      kizashi = KizashiConfig {baseUrl = "http://localhost:1", defaultRecipient = "recipient"},
      kawa = KawaConfig {baseUrl = "http://localhost:1", sourceSegment = "shinzui/shikigami"},
      danwa = DanwaConfig {baseUrl = "http://localhost:1", agentParticipant = "part_agent_test"},
      rei = ReiConfig {baseUrl = Nothing},
      hooks,
      approval,
      deadline,
      runTimeout = secondsToNominalDiffTime 300,
      logger = Log.silentLogger,
      grants = StaticGrants defaultGrantTable,
      resolveRunProfile = \profileId version -> pure (Left (UnknownProfile profileId version))
    }

approvalEnv :: IORef (Maybe AwakeableId) -> SessionId -> ApprovalEnv
approvalEnv aidRef currentSession =
  ApprovalEnv
    { currentSession,
      requiresApproval = \_ kind _ ->
        pure
          if kind == SKawaDigest
            then ApprovalRequired approvalRequest
            else ApprovalNotRequired,
      recordPark = \_ aid _ -> writeIORef aidRef (Just aid),
      postAsk = \_ _ _ -> pure ()
    }

approvalRequest :: ApprovalRequest
approvalRequest =
  ApprovalRequest
    { prompt = "Dispatch heartbeat digest?",
      context = object ["source" .= ("test" :: Text)],
      channel = ViaDanwa
    }

readCapturedAwakeable :: IORef (Maybe AwakeableId) -> IO AwakeableId
readCapturedAwakeable aidRef =
  readIORef aidRef >>= \case
    Just aid -> pure aid
    Nothing -> ioError (userError "approval park should capture awakeable id")

loadProofAgents :: IO [AgentDecl]
loadProofAgents = do
  results <-
    traverse
      loadAgent
      [ "../agents/proof/research-supervisor.dhall",
        "../agents/proof/web-researcher.dhall",
        "../agents/proof/code-researcher.dhall"
      ]
  case sequence results of
    Right loaded -> pure loaded
    Left err -> assertFailure ("proof agents should load: " <> show err)

assertChildCompleted :: String -> Either err (WorkflowOutcome (Either AgentRunFailure AgentRunResult)) -> IO ()
assertChildCompleted label = \case
  Right (Completed (Right _)) -> pure ()
  other -> assertFailure (label <> ", got " <> show (first (const ("store-error" :: String)) other))

lineageSummary :: [SessionRow] -> Set.Set (Text, Maybe Text, Int)
lineageSummary rows =
  Set.fromList
    [ (agentId, parentSessionId, delegationDepth)
    | SessionRow {agentId, parentSessionId, delegationDepth} <- rows
    ]

childLinkSummary :: [ChildRow] -> Set.Set (Text, Text, Text)
childLinkSummary rows =
  Set.fromList
    [ (childName, childId, childStatusText status)
    | ChildRow {childName, childId, status} <- rows
    ]

childStatusText :: ChildStatus -> Text
childStatusText = \case
  Running -> "running"
  ChildCompleted -> "completed"
  ChildCancelled -> "cancelled"
  ChildFailed -> "failed"

-- | The conversation environment every Conversation case runs against.
--
-- Named rather than repeated per case because there are now several cases and
-- the interesting differences between them are the agent list and the idle
-- window, not the six fields they all share.
-- | One generation's step index for the given epoch of a conversation.
conversationStepKeys :: AppEnv -> AddressedMessage -> Int -> IO (Map Text Value)
conversationStepKeys = conversationStepKeysAt 0

conversationStepKeysAt :: Int -> AppEnv -> AddressedMessage -> Int -> IO (Map Text Value)
conversationStepKeysAt epoch appEnv msg generation = do
  loaded <- runAppIO appEnv (loadStepIndex Conversation.conversationWorkflowName (Conversation.conversationWorkflowId epoch msg) generation)
  case loaded of
    Right keys -> pure keys
    Left err -> assertFailure ("loadStepIndex failed: " <> show err)

testConversationEnv :: AppEnv -> BehaviorEnv -> [AgentDecl] -> Conversation.ConversationEnv
testConversationEnv appEnv behaviorEnv conversationAgents =
  testConversationEnvIdle (secondsToNominalDiffTime 1800) appEnv behaviorEnv conversationAgents

-- | As 'testConversationEnv', with the idle window under the test's control.
--
-- The idle cases arm a timer and then fire it by hand rather than waiting, so
-- the window they pass is only what the armed row's fireAt records.
testConversationEnvIdle :: NominalDiffTime -> AppEnv -> BehaviorEnv -> [AgentDecl] -> Conversation.ConversationEnv
testConversationEnvIdle idleWindow appEnv behaviorEnv conversationAgents =
  Conversation.ConversationEnv
    { Conversation.appEnv = appEnv,
      Conversation.behaviorEnv = behaviorEnv,
      Conversation.runTimeout = secondsToNominalDiffTime 300,
      Conversation.idleTimeout = idleWindow,
      Conversation.danwa = DanwaConfig {baseUrl = "http://localhost:1", agentParticipant = "part_agent_test"},
      Conversation.agents = conversationAgents,
      Conversation.grants = StaticGrants defaultGrantTable
    }

-- | A running session in the same agent scope under a different subject.
--
-- This is the row the pre-index resolver had to walk past on every single turn:
-- 'Kioku.Session.getByScope' returns every session the agent has ever had, and
-- resolution then scanned them for a @subjectRef@ match. The decoy makes "we
-- selected the right session" a claim with something to be wrong about.
startDecoyConversationSession :: AppEnv -> Text -> Text -> IO SessionId
startDecoyConversationSession appEnv agentName decoyConversationId = do
  now <- getCurrentTime
  sid <- genSessionId
  result <-
    runAppIO appEnv $
      Session.start
        StartSessionData
          { sessionId = sid,
            memorySpaceId = shikigamiMemorySpace,
            actorPrincipal = agentActor agentName,
            ownerPrincipal = Nothing,
            agentId = agentName,
            focus = "conversation",
            scope = agentScope agentName,
            subjectRef = Just decoyConversationId,
            previousSessionId = Nothing,
            parentSessionId = Nothing,
            delegationDepth = 0,
            startedAt = now
          }
  case result of
    Right (Right _) -> pure sid
    other -> assertFailure ("decoy session should start, got " <> show (first (const ("store-error" :: String)) other))

-- | Every running session in this agent's scope whose subject is this
-- conversation.
runningSessionsFor :: AppEnv -> Text -> Text -> IO [Text]
runningSessionsFor appEnv agentName wantedConversationId = do
  rows <- runAppIO appEnv (Session.getByScope shikigamiMemorySpace (agentScope agentName))
  case rows of
    Right (Right allRows) ->
      pure
        [ sessionId
        | SessionRow {sessionId, subjectRef, status} <- allRows,
          subjectRef == Just wantedConversationId,
          status == "running"
        ]
    other -> assertFailure ("getByScope should succeed, got " <> show (first (const ("store-error" :: String)) other))

turnRoleIndex :: TurnRow -> (Text, Int)
turnRoleIndex TurnRow {role, turnIndex} = (role, turnIndex)

-- | Fire a due conversation idle-timeout timer through the same one loop the
-- runtime uses. Returns whether a row fired.
-- | Drain due timers until the conversation idle timer is the one that fires.
--
-- __Not a single pass, and the reason is worth knowing.__ Recording a turn also
-- schedules a kioku L1 distillation timer (@kind: "ramp"@, written by
-- @l1TimerScheduleProjection@ in the same transaction as the assistant turn), so
-- a parked conversation has more than one due row. 'runWorkflowTimerWorker'
-- claims exactly one per call, ordered by @fire_at@, and a row whose fire action
-- declines it is left in @firing@ — which the claim query skips, so it costs one
-- pass and does not spin. Draining is therefore how a test reaches its own timer
-- without depending on which row sorted first.
fireDueConversationIdleTimer :: AppEnv -> IO Bool
fireDueConversationIdleTimer appEnv = go (8 :: Int)
  where
    go 0 = pure False
    go budget = do
      now <- getCurrentTime
      ours <- newIORef False
      claimed <-
        runAppIO appEnv $
          runWorkflowTimerWorker Nothing (addUTCTime 120 now) \row -> do
            outcome <- Conversation.conversationIdleTimeoutFireAction row
            unsafeEff_ (writeIORef ours (maybe False (const True) outcome))
            pure outcome
      wasOurs <- readIORef ours
      case claimed of
        Right (Just _) | not wasOurs -> go (budget - 1)
        Right (Just _) -> pure True
        _ -> pure False

-- | One session's lifecycle status and lineage predecessor.
--
-- Returned as a pair rather than the whole row because @status@ is ambiguous
-- under @DuplicateRecordFields@ here -- four imported records carry one.
conversationSessionState :: AppEnv -> SessionId -> IO (Text, Maybe Text)
conversationSessionState appEnv sid = do
  loaded <- runAppIO appEnv (Session.getById shikigamiMemorySpace sid)
  case loaded of
    Right (Right (Just SessionRow {status = rowStatus, previousSessionId = rowPrevious})) -> pure (rowStatus, rowPrevious)
    other -> assertFailure ("getById should return the session, got " <> show (first (const ("store-error" :: String)) other))

fireDueApprovalTimer :: AppEnv -> IO ()
fireDueApprovalTimer appEnv = do
  now <- getCurrentTime
  fired <- runAppIO appEnv (runWorkflowTimerWorker Nothing (addUTCTime 2 now) approvalTimeoutFireAction)
  assertBool "approval timeout timer should fire" (either (const False) (maybe False (const True)) fired)

-- | The lifecycle step names one agent run journaled, with Keiro's reserved
-- bookkeeping removed so the assertion is about this workflow's own steps.
--
-- @__workflow_patches__@ is filtered alongside @__workflow_completed__@ because
-- a fresh generation records the deployment's active patch set under it whenever
-- that set is non-empty (@recordPatchSetIfFresh@ in @Keiro.Workflow@). Shikigami's
-- set became non-empty when @Shikigami.Flow.Capability.runSink@ took its
-- @shikigami-emit-signal-labels-v1@ guard, so every agent-run journal carries the
-- record now. It is additive bookkeeping, not a lifecycle step.
loadLifecycleStepKeys :: AppEnv -> RunJob -> IO (Either String (Set.Set Text))
loadLifecycleStepKeys appEnv runJob = do
  result <- runAppIO appEnv (loadStepIndex agentRunWorkflowName (WorkflowId (idempotencyKey runJob)) 0)
  pure (first show (Set.delete patchSetStepName . Set.delete completedStepName . Map.keysSet <$> result))

loadProfileResolution :: AppEnv -> RunJob -> IO (Either String (Maybe ResolvedProfile))
loadProfileResolution appEnv runJob = do
  result <- runAppIO appEnv (loadStepIndex agentRunWorkflowName (WorkflowId (idempotencyKey runJob)) 0)
  pure do
    journal <- first show result
    encoded <- maybe (Left "resolve-profile was not journaled") Right (Map.lookup "resolve-profile" journal)
    resolution <- case fromJSON encoded :: Result (Either ProfileResolutionError (Maybe ResolvedProfile)) of
      Success value -> Right value
      Error err -> Left ("cannot decode resolve-profile: " <> err)
    first show resolution

expectedLifecycleSteps :: Set.Set Text
expectedLifecycleSteps =
  Set.fromList
    [ "ingest-job",
      "lookup-agent",
      "patch:shikigami-resolve-profile-v1",
      "resolve-profile",
      "open-session",
      "recall",
      "patch:shikigami-behavior-retry-v1",
      "run-behavior-v2",
      "dispatch-sinks",
      "record",
      "complete"
    ]

isRight' :: Either a b -> Bool
isRight' = either (const False) (const True)

isCompleted :: Either a (WorkflowOutcome (Either failure b)) -> Bool
isCompleted (Right (Completed (Right _))) = True
isCompleted _ = False

decl :: AgentDecl
decl =
  AgentDecl
    { name = "heartbeat",
      description = "workflow test agent",
      trigger = Event {eventType = "test"},
      behavior =
        ShikumiProgram
          { task = "noop-summary",
            preferEnrichment = False,
            grounding = Nothing,
            enabledBy = Nothing
          },
      sinks = [KawaDigest {subjectType = "heartbeat", verb = "heartbeat.tick"}],
      sanctionedProfile = Nothing,
      identity = Nothing,
      memory = defaultMemoryPolicy,
      enabled = True
    }

missingTaskDecl :: AgentDecl
missingTaskDecl =
  AgentDecl
    { name = "missing-task-agent",
      description = "workflow test agent with a permanent program-input failure",
      trigger = Event {eventType = "test"},
      behavior =
        ShikumiProgram
          { task = "missing-task",
            preferEnrichment = False,
            grounding = Nothing,
            enabledBy = Nothing
          },
      sinks = [],
      sanctionedProfile = Nothing,
      identity = Nothing,
      memory = defaultMemoryPolicy,
      enabled = True
    }

profiledDecl :: AgentDecl
profiledDecl =
  AgentDecl
    { name = "heartbeat",
      description = "workflow test agent with a sanctioned profile",
      trigger = Event {eventType = "test"},
      behavior =
        ShikumiProgram
          { task = "noop-summary",
            preferEnrichment = False,
            grounding = Nothing,
            enabledBy = Nothing
          },
      sinks = [KawaDigest {subjectType = "heartbeat", verb = "heartbeat.tick"}],
      sanctionedProfile =
        Just
          ProfileRequirement
            { profileId = "sanctioned-review",
              version = Just "1"
            },
      identity = Nothing,
      memory = defaultMemoryPolicy,
      enabled = True
    }

profiledSkillDecl :: AgentDecl
profiledSkillDecl =
  AgentDecl
    { name = "profiled-skill",
      description = "workflow test skill with a sanctioned profile",
      trigger = Event {eventType = "test"},
      behavior = Skill {path = "agents/skills/triage-note"},
      sinks = [],
      sanctionedProfile =
        Just
          ProfileRequirement
            { profileId = "sanctioned-review",
              version = Just "1"
            },
      identity = Nothing,
      memory = defaultMemoryPolicy,
      enabled = True
    }

flowDecl :: AgentDecl
flowDecl =
  AgentDecl
    { name = "at-risk-customer",
      description = "workflow flow test agent",
      trigger = Event {eventType = "test"},
      behavior = Flow {name = "at-risk-customer"},
      sinks = [],
      sanctionedProfile = Nothing,
      identity = Nothing,
      memory = defaultMemoryPolicy,
      enabled = True
    }

conversationDecl :: AgentDecl
conversationDecl =
  decl
    { trigger = Event {eventType = addressedMessageEventType},
      sinks = [DanwaConversation {topic = "support"}]
    }

withRecordPolicy :: RecordPolicy -> AgentDecl -> AgentDecl
withRecordPolicy recordPolicy AgentDecl {name, description, trigger, behavior, sinks, sanctionedProfile, identity, memory = MemoryPolicy {scope, recallLimit}, enabled} =
  AgentDecl
    { name,
      description,
      trigger,
      behavior,
      sinks,
      sanctionedProfile,
      identity,
      memory = MemoryPolicy {scope, recallLimit, recordPolicy},
      enabled
    }

firstAddressedMessage :: AddressedMessage
firstAddressedMessage =
  AddressedMessage
    { conversationId = "conv_thread_1",
      messageId = "msg_human_1",
      parentMessageId = Nothing,
      author = "part_human_test",
      content = "first question",
      agentParticipantId = "part_agent_test",
      embellishmentId = "emb_human_1",
      mentionedBy = "part_human_test",
      occurredAt = UTCTime (fromGregorian 2026 6 27) 0
    }

secondAddressedMessage :: AddressedMessage
secondAddressedMessage =
  AddressedMessage
    { conversationId = "conv_thread_1",
      messageId = "msg_human_2",
      parentMessageId = Just "msg_human_1",
      author = "part_human_test",
      content = "follow up",
      agentParticipantId = "part_agent_test",
      embellishmentId = "emb_human_2",
      mentionedBy = "part_human_test",
      occurredAt = UTCTime (fromGregorian 2026 6 27) 1
    }

-- | The Nth human message of one long conversation.
conversationMessageNumbered :: Int -> AddressedMessage
conversationMessageNumbered n =
  AddressedMessage
    { conversationId = "conv_rotation",
      messageId = "msg_rotation_" <> Text.pack (show n),
      parentMessageId = if n == 1 then Nothing else Just ("msg_rotation_" <> Text.pack (show (n - 1))),
      author = "part_human_test",
      content = "question " <> Text.pack (show n),
      agentParticipantId = "part_agent_test",
      embellishmentId = "emb_rotation_" <> Text.pack (show n),
      mentionedBy = "part_human_test",
      occurredAt = UTCTime (fromGregorian 2026 6 27) (fromIntegral n)
    }

permanentConversationMessage :: AddressedMessage
permanentConversationMessage =
  AddressedMessage
    { conversationId = "conv_permanent",
      messageId = "msg_permanent",
      parentMessageId = Nothing,
      author = "part_human_test",
      content = "exercise permanent failure",
      agentParticipantId = "part_agent_test",
      embellishmentId = "emb_permanent",
      mentionedBy = "part_human_test",
      occurredAt = UTCTime (fromGregorian 2026 6 27) 0
    }

job :: RunJob
job =
  RunJob
    { agentName = "heartbeat",
      triggerKind = TriggeredByEvent,
      routeKind = AgentWorkflowRoute,
      occurredAt = UTCTime (fromGregorian 2026 6 27) 0,
      triggerPayload = object [],
      idempotencyKey = "heartbeat:test-workflow-replay",
      parentSessionId = Nothing,
      parentRunWorkflowId = Nothing,
      delegationDepth = Nothing
    }

retryVersioningJob :: Text -> RunJob
retryVersioningJob key =
  RunJob
    { agentName = "heartbeat",
      triggerKind = TriggeredByEvent,
      routeKind = AgentWorkflowRoute,
      occurredAt = UTCTime (fromGregorian 2026 6 27) 0,
      triggerPayload = object [],
      idempotencyKey = key,
      parentSessionId = Nothing,
      parentRunWorkflowId = Nothing,
      delegationDepth = Nothing
    }

transientRetryJob :: RunJob
transientRetryJob = retryVersioningJob "heartbeat:test-transient-retry"

permanentFailureJob :: RunJob
permanentFailureJob =
  RunJob
    { agentName = "missing-task-agent",
      triggerKind = TriggeredByEvent,
      routeKind = AgentWorkflowRoute,
      occurredAt = UTCTime (fromGregorian 2026 6 27) 0,
      triggerPayload = object [],
      idempotencyKey = "missing-task-agent:test-permanent-failure",
      parentSessionId = Nothing,
      parentRunWorkflowId = Nothing,
      delegationDepth = Nothing
    }

crashJob :: RunJob
crashJob =
  RunJob
    { agentName = "heartbeat",
      triggerKind = TriggeredByEvent,
      routeKind = AgentWorkflowRoute,
      occurredAt = UTCTime (fromGregorian 2026 6 27) 0,
      triggerPayload = object [],
      idempotencyKey = "heartbeat:test-workflow-crash-resume",
      parentSessionId = Nothing,
      parentRunWorkflowId = Nothing,
      delegationDepth = Nothing
    }

profileRefusalJob :: RunJob
profileRefusalJob =
  RunJob
    { agentName = "heartbeat",
      triggerKind = TriggeredByEvent,
      routeKind = AgentWorkflowRoute,
      occurredAt = UTCTime (fromGregorian 2026 6 27) 0,
      triggerPayload = object [],
      idempotencyKey = "heartbeat:test-profile-refusal",
      parentSessionId = Nothing,
      parentRunWorkflowId = Nothing,
      delegationDepth = Nothing
    }

profilePinningJob :: RunJob
profilePinningJob =
  RunJob
    { agentName = "heartbeat",
      triggerKind = TriggeredByEvent,
      routeKind = AgentWorkflowRoute,
      occurredAt = UTCTime (fromGregorian 2026 6 27) 0,
      triggerPayload = object [],
      idempotencyKey = "heartbeat:test-profile-pinning",
      parentSessionId = Nothing,
      parentRunWorkflowId = Nothing,
      delegationDepth = Nothing
    }

profileViolationJob :: RunJob
profileViolationJob =
  RunJob
    { agentName = "profiled-skill",
      triggerKind = TriggeredByEvent,
      routeKind = AgentWorkflowRoute,
      occurredAt = UTCTime (fromGregorian 2026 6 27) 0,
      triggerPayload = object [],
      idempotencyKey = "profiled-skill:test-profile-violation",
      parentSessionId = Nothing,
      parentRunWorkflowId = Nothing,
      delegationDepth = Nothing
    }

sampleWorkflowProfileId :: ProfileId
sampleWorkflowProfileId = ProfileId "sanctioned-review"

workflowProfile :: ProfileVersion -> SanctionedExecutionProfile
workflowProfile = workflowProfileWith defaultProhibitions

workflowProfileWith :: Prohibitions -> ProfileVersion -> SanctionedExecutionProfile
workflowProfileWith prohibitions version =
  SanctionedExecutionProfile
    { profileId = sampleWorkflowProfileId,
      version,
      issuer = Issuer "shinzui/kikan",
      lifecycle = Active,
      validFrom = UTCTime (fromGregorian 2026 8 1) 0,
      validUntil = Nothing,
      allowedCalls =
        NonEmpty.singleton
          AllowedCall
            { provider = "anthropic",
              api = "messages",
              endpointClass = "https",
              modelId = "claude-sonnet-4-6",
              thinking = ThinkingHigh
            },
      prohibitions,
      limits = unlimitedProfileLimits,
      minimumEvidenceStrength = EvidenceModelObserved,
      requiredCorrelationFields = ["request-id"],
      signerRequirements = noSignerRequirements
    }

defaultThinkingProhibitions :: Prohibitions
defaultThinkingProhibitions =
  Prohibitions
    { aliasesAllowed = False,
      defaultedThinkingAllowed = True,
      providerFallbackAllowed = False,
      modelFallbackAllowed = False,
      effortClampingAllowed = False,
      cliTransportsAllowed = False
    }

resolvedWorkflowProfile :: SanctionedExecutionProfile -> ProfileDigest -> ResolvedProfile
resolvedWorkflowProfile content digest =
  let SanctionedExecutionProfile {profileId, version} = content
   in ResolvedProfile
        { profile = content,
          ref = SanctionedExecutionProfileRef {profileId, version, digest}
        }

insertWorkflowProfile :: Pool -> SanctionedExecutionProfile -> ProfileDigest -> IO ()
insertWorkflowProfile pool content claimedDigest = do
  let SanctionedExecutionProfile {profileId, version, issuer, validFrom, validUntil} = content
      params =
        ( profileIdText profileId,
          profileVersionText version,
          issuerText issuer,
          "active",
          validFrom,
          validUntil,
          toJSON content,
          profileDigestText claimedDigest
        )
  result <- Pool.use pool (HasqlSession.statement params insertWorkflowProfileStatement)
  either (assertFailure . show) pure result

insertWorkflowProfileStatement :: Statement (Text, Text, Text, Text, UTCTime, Maybe UTCTime, Value, Text) ()
insertWorkflowProfileStatement =
  preparable
    """
    INSERT INTO shikigami.sanctioned_execution_profiles
      (profile_id, version, issuer, lifecycle, valid_from, valid_until, profile_content, profile_digest)
    VALUES ($1, $2, $3, $4, $5, $6, $7, $8)
    """
    ( ((\(a, _, _, _, _, _, _, _) -> a) >$< Encoders.param (Encoders.nonNullable Encoders.text))
        <> ((\(_, b, _, _, _, _, _, _) -> b) >$< Encoders.param (Encoders.nonNullable Encoders.text))
        <> ((\(_, _, c, _, _, _, _, _) -> c) >$< Encoders.param (Encoders.nonNullable Encoders.text))
        <> ((\(_, _, _, d, _, _, _, _) -> d) >$< Encoders.param (Encoders.nonNullable Encoders.text))
        <> ((\(_, _, _, _, e, _, _, _) -> e) >$< Encoders.param (Encoders.nonNullable Encoders.timestamptz))
        <> ((\(_, _, _, _, _, f, _, _) -> f) >$< Encoders.param (Encoders.nullable Encoders.timestamptz))
        <> ((\(_, _, _, _, _, _, g, _) -> g) >$< Encoders.param (Encoders.nonNullable Encoders.jsonb))
        <> ((\(_, _, _, _, _, _, _, h) -> h) >$< Encoders.param (Encoders.nonNullable Encoders.text))
    )
    Decoders.noResult

replaceWorkflowProfile :: Pool -> ProfileId -> ProfileVersion -> SanctionedExecutionProfile -> ProfileDigest -> IO ()
replaceWorkflowProfile pool profileId oldVersion replacement claimedDigest = do
  let SanctionedExecutionProfile {version = newVersion} = replacement
      params =
        ( profileIdText profileId,
          profileVersionText oldVersion,
          profileVersionText newVersion,
          toJSON replacement,
          profileDigestText claimedDigest
        )
  result <- Pool.use pool (HasqlSession.statement params replaceWorkflowProfileStatement)
  either (assertFailure . show) pure result

replaceWorkflowProfileStatement :: Statement (Text, Text, Text, Value, Text) ()
replaceWorkflowProfileStatement =
  preparable
    """
    UPDATE shikigami.sanctioned_execution_profiles
       SET version = $3, profile_content = $4, profile_digest = $5
     WHERE profile_id = $1 AND version = $2
    """
    ( ((\(a, _, _, _, _) -> a) >$< Encoders.param (Encoders.nonNullable Encoders.text))
        <> ((\(_, b, _, _, _) -> b) >$< Encoders.param (Encoders.nonNullable Encoders.text))
        <> ((\(_, _, c, _, _) -> c) >$< Encoders.param (Encoders.nonNullable Encoders.text))
        <> ((\(_, _, _, d, _) -> d) >$< Encoders.param (Encoders.nonNullable Encoders.jsonb))
        <> ((\(_, _, _, _, e) -> e) >$< Encoders.param (Encoders.nonNullable Encoders.text))
    )
    Decoders.noResult

profileIdText :: ProfileId -> Text
profileIdText (ProfileId value) = value

profileVersionText :: ProfileVersion -> Text
profileVersionText (ProfileVersion value) = value

profileDigestText :: ProfileDigest -> Text
profileDigestText (ProfileDigest value) = value

issuerText :: Issuer -> Text
issuerText (Issuer value) = value

recordBeforeCompleteCrashJob :: RunJob
recordBeforeCompleteCrashJob =
  RunJob
    { agentName = "heartbeat",
      triggerKind = TriggeredByEvent,
      routeKind = AgentWorkflowRoute,
      occurredAt = UTCTime (fromGregorian 2026 6 27) 0,
      triggerPayload = object [],
      idempotencyKey = "heartbeat:test-record-before-complete-crash",
      parentSessionId = Nothing,
      parentRunWorkflowId = Nothing,
      delegationDepth = Nothing
    }

flowJob :: RunJob
flowJob =
  RunJob
    { agentName = "at-risk-customer",
      triggerKind = TriggeredByEvent,
      routeKind = AgentWorkflowRoute,
      occurredAt = UTCTime (fromGregorian 2026 6 27) 0,
      triggerPayload = object ["text" .= ("customer says thanks, all good" :: Text)],
      idempotencyKey = "at-risk-customer:test-flow-low",
      parentSessionId = Nothing,
      parentRunWorkflowId = Nothing,
      delegationDepth = Nothing
    }

-- | The same agent and the same calm text as 'flowJob', under a different run
-- id so it gets its own workflow and its own subject.
flowMemoryJob :: RunJob
flowMemoryJob =
  RunJob
    { agentName = "at-risk-customer",
      triggerKind = TriggeredByEvent,
      routeKind = AgentWorkflowRoute,
      occurredAt = UTCTime (fromGregorian 2026 6 27) 0,
      triggerPayload = object ["text" .= ("customer says thanks, all good" :: Text)],
      idempotencyKey = "at-risk-customer:test-flow-memory-high",
      parentSessionId = Nothing,
      parentRunWorkflowId = Nothing,
      delegationDepth = Nothing
    }

-- | Seed the at-risk-customer agent's memory with an escalation on this
-- subject, the way an earlier run of the flow would have
-- ('Shikigami.Flow.AtRiskCustomer.escalatedNote' is worded the same).
recordPriorEscalation :: AppEnv -> Text -> IO ()
recordPriorEscalation appEnv ticket = do
  mid <- genMemoryId
  recordedAt <- getCurrentTime
  result <-
    runAppIO appEnv $
      Memory.record
        RecordMemoryData
          { memoryId = mid,
            memorySpaceId = shikigamiMemorySpace,
            actorPrincipal = agentActor "at-risk-customer",
            ownerPrincipal = Nothing,
            agentId = "at-risk-customer",
            sessionId = Nothing,
            scope = agentScope "at-risk-customer",
            memoryType = MemoryPattern,
            content = ticket <> " escalated after acknowledgement timeout",
            priority = 100,
            confidence = MediumConfidence,
            tags = Set.fromList ["flow", "Flow"],
            supersedes = Nothing,
            recordedAt
          }
  case result of
    Right (Right _) -> pure ()
    other -> assertFailure ("seeding the prior escalation should succeed, got " <> show other)

recordRecallFixture :: AppEnv -> Int -> IO ()
recordRecallFixture appEnv ordinal = do
  mid <- genMemoryId
  recordedAt <- getCurrentTime
  result <-
    runAppIO appEnv $
      Memory.record
        RecordMemoryData
          { memoryId = mid,
            memorySpaceId = shikigamiMemorySpace,
            actorPrincipal = agentActor "recall-limit-agent",
            ownerPrincipal = Nothing,
            agentId = "recall-limit-agent",
            sessionId = Nothing,
            scope = agentScope "recall-limit-agent",
            memoryType = MemoryPattern,
            content = "recall fixture " <> Text.pack (show ordinal),
            priority = 100,
            confidence = MediumConfidence,
            tags = Set.fromList ["agent-run", "fixture"],
            supersedes = Nothing,
            recordedAt
          }
  case result of
    Right (Right _) -> pure ()
    other -> assertFailure ("seeding recall fixture should succeed, got " <> show other)

expectedFlowOutput :: Value
expectedFlowOutput =
  object
    [ "level" .= ("low" :: Text),
      "rationale" .= ("no high-risk signal detected" :: Text),
      "ticketId" .= ("at-risk-customer:test-flow-low" :: Text)
    ]

approvalJob :: RunJob
approvalJob =
  RunJob
    { agentName = "heartbeat",
      triggerKind = TriggeredByEvent,
      routeKind = AgentWorkflowRoute,
      occurredAt = UTCTime (fromGregorian 2026 6 27) 0,
      triggerPayload = object [],
      idempotencyKey = "heartbeat:test-approval-approved",
      parentSessionId = Nothing,
      parentRunWorkflowId = Nothing,
      delegationDepth = Nothing
    }

rejectedJob :: RunJob
rejectedJob =
  RunJob
    { agentName = "heartbeat",
      triggerKind = TriggeredByEvent,
      routeKind = AgentWorkflowRoute,
      occurredAt = UTCTime (fromGregorian 2026 6 27) 0,
      triggerPayload = object [],
      idempotencyKey = "heartbeat:test-approval-rejected",
      parentSessionId = Nothing,
      parentRunWorkflowId = Nothing,
      delegationDepth = Nothing
    }

timeoutJob :: RunJob
timeoutJob =
  RunJob
    { agentName = "heartbeat",
      triggerKind = TriggeredByEvent,
      routeKind = AgentWorkflowRoute,
      occurredAt = UTCTime (fromGregorian 2026 6 27) 0,
      triggerPayload = object [],
      idempotencyKey = "heartbeat:test-approval-timeout",
      parentSessionId = Nothing,
      parentRunWorkflowId = Nothing,
      delegationDepth = Nothing
    }

answeredBeforeDeadlineJob :: RunJob
answeredBeforeDeadlineJob =
  RunJob
    { agentName = "heartbeat",
      triggerKind = TriggeredByEvent,
      routeKind = AgentWorkflowRoute,
      occurredAt = UTCTime (fromGregorian 2026 6 27) 0,
      triggerPayload = object [],
      idempotencyKey = "heartbeat:test-approval-before-deadline",
      parentSessionId = Nothing,
      parentRunWorkflowId = Nothing,
      delegationDepth = Nothing
    }

researchSupervisorJob :: RunJob
researchSupervisorJob =
  RunJob
    { agentName = "research-supervisor",
      triggerKind = TriggeredByEvent,
      routeKind = AgentWorkflowRoute,
      occurredAt = UTCTime (fromGregorian 2026 6 27) 0,
      triggerPayload = object ["topic" .= ("durable workflows" :: Text)],
      idempotencyKey = "research-supervisor:test-fanout",
      parentSessionId = Nothing,
      parentRunWorkflowId = Nothing,
      delegationDepth = Nothing
    }

expectedSupervisorOutput :: Value
expectedSupervisorOutput =
  object
    [ "summary" .= ("research-supervisor synthesized delegated findings" :: Text),
      "web"
        .= object
          [ "agent" .= ("web-researcher" :: Text),
            "finding" .= ("Web sources indicate durable workflow delegation should journal child waits." :: Text)
          ],
      "code"
        .= object
          [ "agent" .= ("code-researcher" :: Text),
            "finding" .= ("The code path should spawn child workflows before awaiting their results." :: Text)
          ]
    ]
