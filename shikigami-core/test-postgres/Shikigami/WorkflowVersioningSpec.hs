-- | Deploying changed workflow code over instances that are already running.
--
-- A Keiro workflow journals each step to Postgres and replays that journal
-- instead of re-running it, so an instance suspended before a deploy is resumed
-- by code that has since changed. Nothing in the runtime notices the change: it
-- matches journal records to steps by name, so new code asking for a name the
-- old journal happens to hold gets the old value.
--
-- @Keiro.Workflow.patch@ is the escape hatch, and these are its executable
-- proof. Each case manufactures the in-flight instance the hazard needs —
-- Shikigami has no deployment yet, so there is no real one to find — by running
-- a workflow to suspension under one code shape and resuming it under another.
--
-- The rules these cases enforce are written out in @docs\/workflow-versioning.md@.
-- A change to a rule there should change a case here.
module Shikigami.WorkflowVersioningSpec (tests) where

import Control.Exception (SomeException, try)
import Control.Lens ((&), (.~))
import Data.Aeson (Value)
import Data.Aeson qualified as Aeson
import Data.Generics.Labels ()
import Data.IORef (IORef, atomicModifyIORef', newIORef, readIORef)
import Data.Map.Strict (Map)
import Data.Map.Strict qualified as Map
import Data.Set qualified as Set
import Data.Text (Text)
import Data.Time (secondsToNominalDiffTime)
import Effectful (Eff, IOE, liftIO, (:>))
import Keiro.Workflow (PatchId (..), StepName (..), Workflow, WorkflowId (..), WorkflowName (..), WorkflowOutcome (..), WorkflowRunOptions (..), defaultWorkflowRunOptions, loadStepIndex, patch, patchSetStepName, patchStepName, runWorkflowWith, step)
import Keiro.Workflow.Instance (ResurrectOutcome (..), resurrectFailedWorkflow)
import Keiro.Workflow.Resume (ResumeSummary (..), WorkflowDef (..), WorkflowResumeOptions (..), resumeWorkflowsOnceUpTo)
import Kiroku.Store.Connection (defaultConnectionSettings, withStore)
import Kiroku.Store.Error (StoreError)
import Shikigami.Agent.Approval qualified as Approval
import Shikigami.Agent.Workflow.Input (awaitInput, deliverInputTo)
import Shikigami.App (AppEffects, AppEnv (..), noopTracer, runAppIO)
import Shikigami.Migrations.TestSupport (DatabaseFixture, withShikigamiFreshDatabase)
import Shikigami.ObjectiveWorkflowSpec qualified as Objectives
import Shikigami.Workflow.Versioning (shikigamiActivePatches, shikigamiWorkflowResumeOptions)
import Test.Tasty (TestTree, testGroup)
import Test.Tasty.HUnit (assertBool, assertEqual, testCase)

tests :: DatabaseFixture -> TestTree
tests databaseFixture =
  testGroup
    "WorkflowVersioning"
    [ testCase "resume lease exceeds the synchronous behavior timeout" do
        tracer <- noopTracer
        let timeout = secondsToNominalDiffTime 300
            appEnv = AppEnv {connectionSettings = defaultConnectionSettings "", tracer, metrics = Nothing, store = Nothing}
            WorkflowResumeOptions
              { leaseTtl,
                runOptions = WorkflowRunOptions {leaseHeartbeat}
              } = shikigamiWorkflowResumeOptions appEnv timeout
        assertEqual "resume lease includes the scheduling margin" (secondsToNominalDiffTime 330) leaseTtl
        assertEqual "resume worker, not direct runs, installs the instance heartbeat" Nothing leaseHeartbeat,
      testCase "in-flight workflow survives a simulated deploy under a patch guard" (inFlightSurvivesDeploy databaseFixture),
      testCase "failed workflows resurrect through the public owner" (failedWorkflowResurrects databaseFixture),
      testCase "an old agent journal replays without objective policy or tools" (Objectives.oldAgentReplay databaseFixture),
      testCase "an old conversation journal replays without objective policy or tools" (Objectives.oldConversationReplay databaseFixture),
      testCase "approval review identity has a frozen public vector" approvalReviewIdentityIsStable,
      testCase "only the declared application workflow patches are active" do
        assertEqual "active application patches" (Set.fromList [PatchId "shikigami-objective-tracking-v1", PatchId "shikigami-conversation-objective-tracking-v1", PatchId "shikigami-structured-judgments-v1"]) shikigamiActivePatches
    ]

-- ── Test A: the patch primitive, end to end ─────────────────────────────────

-- | A workflow started before a patch shipped keeps the old branch; one started
-- after takes the new one.
--
-- Two bodies share one 'WorkflowName', which is what a deploy looks like from
-- the journal's point of view: same stream, different code. The new body inserts
-- a step (@enrich@) ahead of the parked instance's resume point — the change
-- class @docs\/workflow-versioning.md@ rule 4 says must be guarded, because the
-- parked instance cannot finish coherently under the new shape.
--
-- The options are built here rather than taken from
-- "Shikigami.Workflow.Versioning" on purpose: this case is about the mechanism,
-- so it must not pass or fail because of which patches production happens to
-- have active today.
inFlightSurvivesDeploy :: DatabaseFixture -> IO ()
inFlightSurvivesDeploy databaseFixture =
  (withShikigamiFreshDatabase databaseFixture) \connStr ->
    withStore (defaultConnectionSettings connStr) \_kirokuStore -> do
      tracer <- noopTracer
      let appEnv = AppEnv {connectionSettings = defaultConnectionSettings connStr, tracer, metrics = Nothing, store = Nothing}
      collectRuns <- newIORef (0 :: Int)

      -- The old deploy: the patch does not exist yet, so its options name none.
      parked <-
        runAppIO appEnv (runWorkflowWith preDeployOptions versioningWorkflowName inFlightId (oldShape collectRuns))
      assertEqual "the pre-deploy run parks on its awakeable" (Right Suspended) parked
      assertEqual "the pre-deploy run executed collect once" 1 =<< readIORef collectRuns

      delivered <-
        runAppIO appEnv (deliverInputTo versioningWorkflowName inFlightId externalAnswerStep ("answered" :: Text))
      assertEqual "the external answer resolves the awakeable" (Right True) delivered

      -- The deploy happens here: same workflow name, changed body, patch active.
      resumed <-
        runAppIO appEnv (runWorkflowWith postDeployOptions versioningWorkflowName inFlightId (newShape collectRuns))
      assertEqual
        "the in-flight instance completes on the OLD branch"
        (Right (Completed "v1:answered"))
        resumed
      assertEqual
        "collect was replayed from the journal, not re-executed"
        1
        =<< readIORef collectRuns

      inFlight <- loadStepNames appEnv versioningWorkflowName inFlightId
      assertEqual
        "the in-flight instance journaled its patch decision"
        (Right True)
        (elem (patchStepName versioningPatch) <$> inFlight)
      assertEqual
        "it recorded no patch set, because it started before the patch existed"
        (Right False)
        (elem patchSetStepName <$> inFlight)
      assertEqual
        "it never ran the inserted step"
        (Right False)
        (elem "enrich" <$> inFlight)

      -- A fresh instance under the same new code takes the other branch.
      freshRuns <- newIORef (0 :: Int)
      freshParked <-
        runAppIO appEnv (runWorkflowWith postDeployOptions versioningWorkflowName freshId (newShape freshRuns))
      assertEqual "the fresh run parks on its awakeable" (Right Suspended) freshParked
      freshDelivered <-
        runAppIO appEnv (deliverInputTo versioningWorkflowName freshId externalAnswerStep ("answered" :: Text))
      assertEqual "the external answer resolves the fresh awakeable" (Right True) freshDelivered
      freshResumed <-
        runAppIO appEnv (runWorkflowWith postDeployOptions versioningWorkflowName freshId (newShape freshRuns))
      assertEqual
        "the fresh instance completes on the NEW branch"
        (Right (Completed "v2:answered"))
        freshResumed

      fresh <- loadStepIndexFor appEnv versioningWorkflowName freshId
      assertEqual
        "the fresh instance recorded the active patch set"
        (Right True)
        (Map.member patchSetStepName <$> fresh)
      assertEqual
        "the fresh instance journaled the patch decision as true"
        (Right (Just (Aeson.Bool True)))
        (Map.lookup (patchStepName versioningPatch) <$> fresh)
      assertEqual
        "the fresh instance ran the inserted step"
        (Right True)
        (Map.member "enrich" <$> fresh)

versioningWorkflowName :: WorkflowName
versioningWorkflowName = WorkflowName "shikigami.test-versioning"

versioningPatch :: PatchId
versioningPatch = PatchId "shikigami-test-versioning-v2"

inFlightId :: WorkflowId
inFlightId = WorkflowId "wid-inflight"

freshId :: WorkflowId
freshId = WorkflowId "wid-fresh"

externalAnswerStep :: StepName
externalAnswerStep = StepName "external-answer"

-- | The options a deploy made before the patch existed would have used.
preDeployOptions :: WorkflowRunOptions
preDeployOptions = defaultWorkflowRunOptions

-- | The options the deploy that introduces the patch uses.
postDeployOptions :: WorkflowRunOptions
postDeployOptions = defaultWorkflowRunOptions {activePatches = Set.singleton versioningPatch}

-- | The body as it was before the change: collect, then park.
--
-- The 'IORef' counts executions of @collect@'s /action/, which is how the test
-- tells a replay (the action does not run) from a re-run (it does).
oldShape :: IORef Int -> Eff (Workflow : AppEffects) Text
oldShape collectRuns = do
  _ <- step (StepName "collect") (countCollect collectRuns)
  answer <- awaitInput externalAnswerStep
  pure ("v1:" <> answer)

-- | The body after the change: an inserted @enrich@ step and a different result,
-- both behind the patch.
newShape :: IORef Int -> Eff (Workflow : AppEffects) Text
newShape collectRuns = do
  useNewShape <- patch versioningPatch
  if useNewShape
    then do
      _ <- step (StepName "collect") (countCollect collectRuns)
      _ <- step (StepName "enrich") (pure ("enriched" :: Text))
      answer <- awaitInput externalAnswerStep
      pure ("v2:" <> answer)
    else do
      _ <- step (StepName "collect") (countCollect collectRuns)
      answer <- awaitInput externalAnswerStep
      pure ("v1:" <> answer)

countCollect :: (IOE :> es) => IORef Int -> Eff es Text
countCollect ref = do
  _ <- liftIO (atomicModifyIORef' ref \n -> (n + 1, n))
  pure "v1"

approvalReviewIdentityIsStable :: IO ()
approvalReviewIdentityIsStable = do
  let parentName = WorkflowName "shikigami.agent-run"
      parentId = WorkflowId "heartbeat:test"
      reviewId = Approval.reviewRequestIdFor parentName parentId 0 "sink-KawaDigest-0"
      expected = "review_65c07499-2dd9-52d2-ab2b-035bdd321b06"
  assertEqual "the UUIDv5 review vector does not drift" expected (Approval.reviewRequestIdText reviewId)
  assertEqual "the public JSON encoding remains a bare text value" (Aeson.String expected) (Aeson.toJSON reviewId)
  assertBool
    "a new parent generation receives a distinct review id"
    (reviewId /= Approval.reviewRequestIdFor parentName parentId 1 "sink-KawaDigest-0")
  assertBool
    "a distinct stable request key receives a distinct review id"
    (reviewId /= Approval.reviewRequestIdFor parentName parentId 0 "flow-await-ack")

-- ── Reading a journal ───────────────────────────────────────────────────────

loadStepIndexFor :: AppEnv -> WorkflowName -> WorkflowId -> IO (Either StoreError (Map Text Value))
loadStepIndexFor appEnv workflowName workflowId =
  runAppIO appEnv (loadStepIndex workflowName workflowId 0)

loadStepNames :: AppEnv -> WorkflowName -> WorkflowId -> IO (Either StoreError [Text])
loadStepNames appEnv workflowName workflowId =
  fmap Map.keys <$> loadStepIndexFor appEnv workflowName workflowId

-- The first run leaves a resumable instance; the bounded resume pass records a
-- terminal failure at its configured ceiling. Repair retains the journal and
-- allows the same stable step to finish after its external dependency recovers.
failedWorkflowResurrects :: DatabaseFixture -> IO ()
failedWorkflowResurrects databaseFixture =
  withShikigamiFreshDatabase databaseFixture \connStr -> do
    tracer <- noopTracer
    let appEnv = AppEnv {connectionSettings = defaultConnectionSettings connStr, tracer, metrics = Nothing, store = Nothing}
        name = WorkflowName "plan65.failure"
        wid = WorkflowId "resurrect"
        ingested = step (StepName "ingest") (pure () :: Eff (Workflow : AppEffects) ())
        broken = ingested >> step (StepName "dependency") (liftIO (ioError (userError "dependency unavailable")) :: Eff (Workflow : AppEffects) ())
        healthy = ingested >> step (StepName "dependency") (pure () :: Eff (Workflow : AppEffects) ())
        options = shikigamiWorkflowResumeOptions appEnv 60 & #maxAttempts .~ 1
    first <- try @SomeException (runAppIO appEnv (runWorkflowWith defaultWorkflowRunOptions name wid broken))
    assertBool "the initial dependency failure escapes" (either (const True) (const False) first)
    failed <- runAppIO appEnv (resumeWorkflowsOnceUpTo 1 options (Map.singleton name (WorkflowDef (const broken))))
    assertEqual ("bounded pass records terminal failure: " <> show failed) (Right 1) ((.failed) <$> failed)
    repaired <- runAppIO appEnv (resurrectFailedWorkflow name wid)
    assertEqual "supported owner resurrects the instance" (Right WorkflowResurrected) repaired
    completed <- runAppIO appEnv (resumeWorkflowsOnceUpTo 1 options (Map.singleton name (WorkflowDef (const healthy))))
    assertEqual "the recovered dependency completes" (Right 1) ((.completed) <$> completed)
