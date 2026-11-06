{-# LANGUAGE DataKinds #-}

module Shikigami.WatchdogSweepSpec (tests) where

import Control.Exception (SomeException, throwIO, try)
import Control.Lens ((&), (.~))
import Control.Monad (when)
import Data.Aeson (Value, eitherDecode, encode, object, toJSON, (.=))
import Data.Generics.Labels ()
import Data.IORef (atomicModifyIORef', newIORef)
import Data.Int (Int64)
import Data.List.NonEmpty qualified as NonEmpty
import Data.Map.Strict qualified as Map
import Data.Set qualified as Set
import Data.Text (Text)
import Data.Text qualified as Text
import Data.Time (addUTCTime)
import Effectful (Eff)
import Hasql.Decoders qualified as D
import Hasql.Encoders qualified as E
import Hasql.Statement (preparable)
import Hasql.Transaction qualified as Tx
import Keiro.Outbox qualified as Outbox
import Keiro.Workflow (StepName (..), WorkflowId (..), WorkflowOutcome (..), WorkflowRunOptions (..), loadStepIndex, runWorkflowWith)
import Kiroku.Store.Transaction (runTransaction)
import Shikigami.Action.Authorization (allowAllActionAuthorizerForTests, denyAllActionAuthorizer)
import Shikigami.Agent.Decl (AgentDecl (..), Behavior (Flow))
import Shikigami.Agent.DeclarationValue (declarationCoordinate)
import Shikigami.Agent.Delegate.Context (DelegateCtx (..))
import Shikigami.Agent.Principal (AgentIdentity (..), mkAgentPrincipal)
import Shikigami.Agent.RunJob (RunJob (..), runJobWorkflowId)
import Shikigami.Agent.Workflow
import Shikigami.AgentWorkflowSpec qualified as AgentFixture
import Shikigami.App (AppEffects, AppEnv, runAppIO)
import Shikigami.Behavior.Run (newBehaviorEnv)
import Shikigami.Directory qualified as Directory
import Shikigami.Execution.Resources qualified as Resources
import Shikigami.Execution.ResourcesStore qualified as Roots
import Shikigami.Fixture.ExecutionIdentity (fixtureOperationId)
import Shikigami.Flow.Decision qualified as Decision
import Shikigami.Flow.Observe qualified as Observe
import Shikigami.Flow.Watchdog (driftAlias, watchdogFlowName)
import Shikigami.Migrations.TestSupport (DatabaseFixture)
import Shikigami.Objective.Capability qualified as Objectives
import Shikigami.Objective.Command (Command (CancelObjective))
import Shikigami.Objective.Types qualified as Objective
import Shikigami.ObjectiveStoreSpec qualified as ObjectiveFixture
import Shikigami.Program.Decision.Drift (DriftInput (..), DriftProposal (..), DriftProposalSubject (..))
import Shikigami.RouterWorkflowSpec qualified as RouterFixture
import Shikigami.Sink (GrantSource (StaticGrants), SinkKind (SDanwaConversation))
import Shikigami.Sink.Intent (decodeSinkIntentEvent)
import Shikigami.Sink.Types (DanwaTarget (..))
import Shikigami.StateRevision (initialRevision)
import Shikigami.Trigger.Enqueue (scheduledRunJob)
import Shikigami.Watchdog.Classify (Observed (..), classifyPage)
import Shikigami.Watchdog.Grant
import Shikigami.Watchdog.Observation
import Shikigami.Watchdog.Store qualified as Ledger
import Shikigami.Watchdog.Types
import Shikigami.WatchdogDriftSpec qualified as DriftFixture
import Shikigami.WatchdogObservationSpec (start)
import Shikigami.WorkerSession.Capability qualified as Workers
import Shikigami.WorkerSession.Input (workerCoordinate)
import Shikigami.WorkerSession.Store qualified as Sessions
import Shikigami.WorkerSession.Types (SessionAdmission (..), SessionScope (..), sessionIdFor)
import Shikigami.WorkerSessionCapabilitySpec qualified as CapabilityFixture
import Shikigami.WorkerSessionStoreSpec (withFixture)
import Shikigami.Workflow.Versioning (shikigamiWorkflowRunOptions)
import Shikigami.Workspace.Reference (WorkspaceRef (..))
import Shikigami.Workspace.Value (workspaceCoordinate)
import Test.Tasty (TestTree, testGroup)
import Test.Tasty.HUnit (assertBool, assertFailure, testCase, (@?=))

tests :: DatabaseFixture -> TestTree
tests fixture =
  testGroup
    "WatchdogSweep"
    [ testCase "registered watchdog Drift charges its own root while observed root is stopped" $
        withDriftSweep fixture \h deps job -> do
          objectiveBefore <- DriftFixture.objectiveState h
          target <- DriftFixture.inspect h h.objectiveRoot
          _ <- right =<< run h.env (Roots.setRootControl h.objectiveRoot target.revision Resources.StopWork Nothing)
          targetBefore <- DriftFixture.inspect h h.objectiveRoot
          complete =<< runAgentRunWorkflow deps job
          h.calls >>= (@?= 1)
          prompts <- h.prompts
          assertBool "protected inputs cannot instruct the assessment" (all (\prompt -> not ("PRIVATE_REPLAY_MARKER" `Text.isInfixOf` prompt || "ignore previous instructions" `Text.isInfixOf` prompt)) prompts)
          own <- DriftFixture.inspect h (maybe (error "no root") id job.executionRootId)
          DriftFixture.amount own.usage.settled Resources.ModelAttempts @?= Just 1
          DriftFixture.inspect h h.objectiveRoot >>= (@?= targetBefore)
          DriftFixture.objectiveState h >>= (@?= objectiveBefore)
          driftCount <- run h.env (runTransaction (Tx.statement () (preparable "SELECT count(*) FROM shikigami.watchdog_findings" E.noParams (D.singleRow (D.column (D.nonNullable D.int8))))))
          driftCount @?= (1 :: Int64)
          [intent] <- traverse (right . decodeSinkIntentEvent . (.event)) =<< run h.env (Outbox.listOutbox "shinzui/shikigami")
          intent.danwaTarget @?= Just (DanwaTarget (declarationCoordinate "trusted-thread") Nothing)
          intent.resolvedRecipient @?= Nothing,
      testCase "committed Drift result survives AgentRun restart without another provider call" $
        withDriftSweep fixture \h deps job -> do
          crashResumeWith (1, 1, 1, 1) h.env deps job (StepName "decision-result-drift")
          h.calls >>= (@?= 1),
      testCase "a Drift refusal still delivers an independently stuck session" $
        withDriftSweep fixture \h deps job -> do
          access <- right =<< run h.env (Sessions.authorizeSession (sessionIdFor h.admission) h.admission.context.identity (pure (Right ())))
          start h.env access
          grant <- right (resolveObservationGrant deps.observe.settings job.identity)
          page <- right =<< run h.env (observePage grant defaultObservationBounds initialCursor)
          let priorPage = page & #subjects .~ [subject | subject <- page.subjects, subject.subject == WorkerSession (sessionIdFor h.admission)] & #observedAt .~ addUTCTime (-120) page.observedAt
          seedMarks h.env grant priorPage
          let refused = deps & #decisions .~ Decision.emptyDecisionServices
          complete =<< runAgentRunWorkflow refused job
          h.calls >>= (@?= 0)
          counts h.env >>= (@?= (2, 1, 1, 1)),
      testCase "watchdog cancellation and transfer are refused without changing retained work" $ do
        principal <- VerifiedIdentity <$> right (mkAgentPrincipal "agent_watchdog")
        CapabilityFixture.withConfiguredCapabilityFixture fixture (\admission -> admission & #context . #identity .~ principal) \env admission host scope authorizer _ _ -> do
          before <- run env (Sessions.inspectSession (sessionIdFor admission))
          grant <- right =<< run env (Workers.resolveGrant host authorizer scope.run Nothing)
          admitted <- maybe (assertFailure "fixture control scope unavailable") pure grant
          let session = sessionIdFor admission
              commands =
                [ Workers.CancelWorker session initialRevision initialRevision,
                  Workers.TransferWorker session initialRevision initialRevision (WorkspaceRef (workspaceCoordinate "fixture") (workspaceCoordinate "protected")) admission.worker
                ]
          mapM_
            ( \command -> do
                result <- run env (Workers.executeCommand host denyAllActionAuthorizer admitted (fixtureOperationId "watchdog-denied-control") command)
                assertBool "control refused" (either (const True) (const False) result)
            )
            commands
          run env (Sessions.inspectSession session) >>= (@?= before)
        DriftFixture.withHarness fixture \h -> do
          before <- DriftFixture.objectiveState h
          let host = ObjectiveFixture.ownerHost & #authenticate .~ pure (Right (Objective.RecordedAgent principal)) & #actions .~ denyAllActionAuthorizer
          result <- Objectives.admitObjectiveAction host "cancel" (toJSON CancelObjective)
          assertBool "objective cancellation refused" (either (const True) (const False) result)
          DriftFixture.objectiveState h >>= (@?= before),
      testCase "real AgentRun records one quiet finding and one addressed intent" $
        withSweep fixture \env deps job -> do
          complete =<< runAgentRunWorkflow deps job
          index <- run env (loadStepIndex agentRunWorkflowName (runJobWorkflowId job) 0)
          case Map.lookup "emit-signals-watchdog-deliver" index of
            Just value -> assertBool (show value) ("Enqueued" `Text.isInfixOf` Text.pack (show value))
            Nothing -> assertFailure "missing batch emission"
          counts env >>= (@?= (2, 1, 1, 1))
          complete =<< runAgentRunWorkflow deps job
          counts env >>= (@?= (2, 1, 1, 1)),
      testCase "two findings use two ordinals in one static batch journal step" $
        withSweepCount 2 fixture \env deps job -> do
          complete =<< runAgentRunWorkflow deps job
          counts env >>= (@?= (2, 2, 2, 2))
          positions <- run env (runTransaction (Tx.statement () (preparable "SELECT ordinal FROM shikigami.sink_deliveries ORDER BY ordinal" E.noParams (D.rowList (D.column (D.nonNullable D.int4))))))
          positions @?= [0, 1]
          index <- run env (loadStepIndex agentRunWorkflowName (runJobWorkflowId job) 0)
          length (filter ("emit-signals-" `Text.isPrefixOf`) (Map.keys index)) @?= 1,
      testCase "per-intent C13 denial retains no intent or pending receipt" $
        withSweep fixture \env deps job -> do
          complete =<< runAgentRunWorkflow (deps & #actionAuthorizer .~ denyAllActionAuthorizer) job
          counts env >>= (@?= (2, 1, 0, 0)),
      testCase "paused lifecycle refuses every batch intent at emission" $
        withSweep fixture \env deps job -> do
          directory <- Directory.newDirectoryHandle (Directory.staticDirectorySource [Directory.PrincipalRecord (declarationCoordinate "agent_watchdog") (declarationCoordinate "heartbeat") Directory.Paused])
          _ <- right =<< Directory.refreshDirectory directory
          complete =<< runAgentRunWorkflow (deps & #directory .~ directory) job
          counts env >>= (@?= (2, 1, 0, 0)),
      testCase "next tick coalesces the quiet episode without another intent" $
        withSweep fixture \env deps job -> do
          complete =<< runAgentRunWorkflow deps job
          complete =<< runAgentRunWorkflow deps (nextJob job)
          counts env >>= (@?= (3, 1, 1, 1)),
      testCase "missing delivery policy reports a refusal and still closes" $
        withSweep fixture \env deps job -> do
          let seed = deps.observe
              changed = fmap (\settings -> settings & #delivery .~ Nothing) seed.settings
          complete =<< runAgentRunWorkflow (deps & #observe .~ Observe.ObserveSeed changed Observe.noObserveHooks) job
          counts env >>= (@?= (2, 1, 0, 0)),
      testCase "per-intent C11 denial produces no outbox or pending delivery" $
        withSweep fixture \env deps job -> do
          complete =<< runAgentRunWorkflow (deps & #grants .~ StaticGrants Map.empty) job
          counts env >>= (@?= (2, 1, 0, 0)),
      testCase "pre-patch AgentRun emits no watchdog or Drift application labels" $
        withSweep fixture \env deps job -> do
          let options = shikigamiWorkflowRunOptions env & #activePatches .~ Set.empty
          complete . Right =<< run env (runWorkflowWith options agentRunWorkflowName (runJobWorkflowId job) (agentRunWorkflow deps (Just job)))
          counts env >>= (@?= (1, 0, 0, 0))
          index <- run env (loadStepIndex agentRunWorkflowName (runJobWorkflowId job) 0)
          assertBool "no new labels" (all (\label -> not ("watchdog-" `Text.isPrefixOf` label || "decision-" `Text.isPrefixOf` label)) (Map.keys index)),
      testCase "one-off unavailable adapter adds no observation or decision labels" $
        withSweep fixture \env deps job -> do
          let oneOff = deps & #observe .~ Observe.disabledObserve & #agents .~ map (\decl -> decl & #decisionModels .~ [driftAlias]) deps.agents
          complete =<< runAgentRunWorkflow oneOff job
          counts env >>= (@?= (1, 0, 0, 0))
          index <- run env (loadStepIndex agentRunWorkflowName (runJobWorkflowId job) 0)
          assertBool "unavailable adapter is silent" (all (\label -> not ("watchdog-" `Text.isPrefixOf` label || "decision-" `Text.isPrefixOf` label)) (Map.keys index)),
      testCase "configured worker retains a disabled-policy grant refusal" $
        withSweep fixture \env deps job -> do
          complete =<< runAgentRunWorkflow (deps & #observe .~ Observe.ObserveSeed Nothing Observe.noObserveHooks) job
          counts env >>= (@?= (1, 0, 0, 0))
          index <- run env (loadStepIndex agentRunWorkflowName (runJobWorkflowId job) 0)
          assertBool "disabled refusal is retained" (Map.member "watchdog-grant" index),
      testCase "another identity cannot open a sweep" $
        withSweep fixture \env deps job -> do
          let wrong = job & #identity .~ AgentFixture.job.identity
          complete =<< runAgentRunWorkflow deps wrong
          counts env >>= (@?= (1, 0, 0, 0)),
      testCase "crash after record resumes the original notice with one intent" $
        withSweep fixture \env deps job -> crashResume env deps job (StepName "watchdog-record"),
      testCase "crash after deliver retains original recipient across changed settings" $
        withSweep fixture \env deps job -> crashResume env deps job (StepName "emit-signals-watchdog-deliver")
    ]

withSweep :: DatabaseFixture -> (AppEnv -> AgentRunDeps -> RunJob -> IO a) -> IO a
withSweep = withSweepCount 1

withSweepCount :: Int -> DatabaseFixture -> (AppEnv -> AgentRunDeps -> RunJob -> IO a) -> IO a
withSweepCount count fixture use = withFixture fixture \env admission access -> do
  start env access
  when (count > 1) do
    let second = admission & #scope . #workerKey .~ workerCoordinate "second-worker"
    _ <- right =<< run env (Sessions.openSession second)
    other <- right =<< run env (Sessions.authorizeSession (sessionIdFor second) second.context.identity (pure (Right ())))
    start env other
  settings <-
    right
      ( eitherDecode
          ( encode
              ( object
                  [ "principal" .= ("agent_watchdog" :: Text),
                    "scope" .= ("all" :: Text),
                    "stuckWindowSeconds" .= (60 :: Int),
                    "parkedWindowSeconds" .= (30 :: Int),
                    "coordinatorWindowSeconds" .= (60 :: Int),
                    "subjectsPerSweep" .= (9 :: Int),
                    "delivery" .= object ["operatorRecipient" .= ("operator" :: Text), "operatorSink" .= object ["tag" .= ("DanwaConversation" :: Text), "topic" .= ("watchdog-operator" :: Text)], "conversationSink" .= object ["tag" .= ("DanwaConversation" :: Text), "topic" .= ("watchdog" :: Text)]]
                  ]
              )
          )
      )
  principal <- VerifiedIdentity <$> right (mkAgentPrincipal "agent_watchdog")
  grant <- right (resolveObservationGrant (Just settings) principal)
  page <- right =<< run env (observePage grant defaultObservationBounds initialCursor)
  let before = addUTCTime (-120) page.observedAt
      earlier = page & #observedAt .~ before
  sweep <- newSweepId
  let origin = Ledger.SweepOrigin agentRunWorkflowName (WorkflowId "watchdog-prior") before principal
  _ <- right =<< run env (runTransaction (Ledger.openSweep sweep origin (snapshotGrant grant)))
  pool <- Ledger.newIdentityPool (map (.subject) page.subjects)
  _ <- right =<< run env (runTransaction (Ledger.recordSweepPage sweep Liveness before pool (classifyPage (grantWindows grant) earlier Map.empty)))
  _ <- right =<< run env (runTransaction (Ledger.closeSweep sweep (Ledger.SweepSummary before (fromIntegral (length page.subjects)) 0 0 page.passCompleted)))
  directory <- Directory.newDirectoryHandle (Directory.staticDirectorySource [Directory.PrincipalRecord (declarationCoordinate "agent_watchdog") (declarationCoordinate "heartbeat") Directory.Active])
  _ <- right =<< Directory.refreshDirectory directory
  behavior <- newBehaviorEnv
  let declaration = AgentFixture.decl & #behavior .~ Flow watchdogFlowName & #sinks .~ []
      deps =
        AgentFixture.testDepsWithAgents env behavior defaultAgentRunHooks [declaration]
          & #observe .~ Observe.ObserveSeed (Just settings) Observe.noObserveHooks
          & #directory .~ directory
          & #grants .~ StaticGrants (Map.singleton principal (Set.singleton SDanwaConversation))
      job = scheduledRunJob principal declaration.name page.observedAt
  use env deps job

withDriftSweep :: DatabaseFixture -> (DriftFixture.Harness -> AgentRunDeps -> RunJob -> IO a) -> IO a
withDriftSweep fixture use = DriftFixture.withHarness fixture \h -> do
  let declaration = RouterFixture.routerDecl & #behavior .~ Flow watchdogFlowName & #decisionModels .~ [driftAlias] & #sinks .~ []
  settings <-
    right
      ( eitherDecode
          ( encode
              ( object
                  [ "principal" .= ("router" :: Text),
                    "scope" .= ("all" :: Text),
                    "stuckWindowSeconds" .= (60 :: Int),
                    "parkedWindowSeconds" .= (30 :: Int),
                    "coordinatorWindowSeconds" .= (60 :: Int),
                    "subjectsPerSweep" .= (9 :: Int),
                    "driftIntervalSeconds" .= (300 :: Int),
                    "driftSubjectsPerSweep" .= (1 :: Int),
                    "delivery" .= object ["operatorRecipient" .= ("operator" :: Text), "operatorSink" .= object ["tag" .= ("DanwaConversation" :: Text), "topic" .= ("watchdog-operator" :: Text)], "conversationSink" .= object ["tag" .= ("DanwaConversation" :: Text), "topic" .= ("watchdog" :: Text)]]
                  ]
              )
          )
      )
  -- Seed the owner's retained association projection. Authorization to create
  -- that binding is covered by ObjectiveStoreSpec; this fixture tests its reader.
  run
    h.env
    ( runTransaction
        ( Tx.statement
            (object ["objective" .= h.input.objective])
            (preparable "INSERT INTO shikigami.objective_associations(kind,source_id,objective_id,binding) VALUES ('conversation-current','watchdog-fixture',$1->>'objective','{\"conversationId\":\"trusted-thread\"}'::jsonb)" (E.param (E.nonNullable E.jsonb)) D.noResult)
        )
    )
  h.reply (DriftProposal [DriftProposalSubject (subjectKeyText (subjectKey (ObjectiveCoordinator h.input.objective))) "outside-scope" "The retained unrelated-export operation is outside this objective." [0]])
  (_, root) <- DriftFixture.enroll h "watchdog-agent" 1
  let job = RouterFixture.routerJob "drift-watchdog-agent" & #executionRootId .~ Just root
      deps =
        AgentFixture.testDepsWithAgents h.env h.runtime defaultAgentRunHooks [declaration]
          & #deliveryPool .~ Just h.pool
          & #decisions .~ h.services
          & #grants .~ StaticGrants (Map.singleton job.identity (Set.singleton SDanwaConversation))
          & #observe .~ Observe.ObserveSeed (Just settings) Observe.noObserveHooks
  use h deps job

seedMarks :: AppEnv -> ObservationGrant -> ObservationPage -> IO ()
seedMarks env grant page = do
  sweep <- newSweepId
  let origin = Ledger.SweepOrigin agentRunWorkflowName (WorkflowId "watchdog-prior") page.observedAt (grantPrincipal grant)
  _ <- right =<< run env (runTransaction (Ledger.openSweep sweep origin (snapshotGrant grant)))
  pool <- Ledger.newIdentityPool (map (.subject) page.subjects)
  _ <- right =<< run env (runTransaction (Ledger.recordSweepPage sweep Liveness page.observedAt pool (classifyPage (grantWindows grant) page Map.empty)))
  _ <- right =<< run env (runTransaction (Ledger.closeSweep sweep (Ledger.SweepSummary page.observedAt (fromIntegral (length page.subjects)) 0 0 page.passCompleted)))
  pure ()

nextJob :: RunJob -> RunJob
nextJob job = scheduledRunJob job.identity job.agentName (addUTCTime 300 job.occurredAt)

crashResume :: AppEnv -> AgentRunDeps -> RunJob -> StepName -> IO ()
crashResume = crashResumeWith (2, 1, 1, 1)

crashResumeWith :: (Int64, Int64, Int64, Int64) -> AppEnv -> AgentRunDeps -> RunJob -> StepName -> IO ()
crashResumeWith expected env deps job target = do
  crashed <- newIORef False
  let witness = do
        index <- run env (loadStepIndex agentRunWorkflowName (runJobWorkflowId job) 0)
        when (Map.member target.unStepName index) do
          first <- atomicModifyIORef' crashed (\old -> (True, not old))
          when first (throwIO (userError "watchdog committed-step crash"))
      options = shikigamiWorkflowRunOptions env & #onJournalAppend .~ Just witness
  let hooked =
        deps
          & #hooks . #afterStepBody
            .~ ( \step -> when (step == target && "emit-signals-" `Text.isPrefixOf` target.unStepName) do
                   first <- atomicModifyIORef' crashed (\old -> (True, not old))
                   when first (throwIO (userError "watchdog batch committed before close"))
               )
  failure <- try @SomeException (run env (runWorkflowWith options agentRunWorkflowName (runJobWorkflowId job) (agentRunWorkflow hooked (Just job))))
  assertBool "crash observed" (either (const True) (const False) failure)
  afterCrash <- run env (loadStepIndex agentRunWorkflowName (runJobWorkflowId job) 0)
  assertBool "the target journal append committed" (Map.member target.unStepName afterCrash)
  assertBool "crash occurred before watchdog-close committed" (not (Map.member "watchdog-close" afterCrash))
  let seed = deps.observe
      changed = fmap (\settings -> settings & #delivery .~ Nothing) seed.settings
  complete =<< runAgentRunWorkflow (deps & #observe .~ Observe.ObserveSeed changed Observe.noObserveHooks) job
  counts env >>= (@?= expected)

counts :: AppEnv -> IO (Int64, Int64, Int64, Int64)
counts env = run env (runTransaction (Tx.statement () (preparable "SELECT (SELECT count(*) FROM shikigami.watchdog_sweeps WHERE completed_at IS NOT NULL),(SELECT count(*) FROM shikigami.watchdog_findings),(SELECT count(*) FROM keiro.keiro_outbox),(SELECT count(*) FROM shikigami.sink_deliveries)" E.noParams (D.singleRow ((,,,) <$> count <*> count <*> count <*> count)))))
  where
    count = D.column (D.nonNullable D.int8)

complete :: (Show a) => Either e (WorkflowOutcome (Either a b)) -> IO ()
complete (Right (Completed (Right _))) = pure ()
complete _ = assertFailure "AgentRun did not complete successfully"

run :: AppEnv -> Eff AppEffects a -> IO a
run env action = right =<< runAppIO env action

right :: (Show e) => Either e a -> IO a
right = either (assertFailure . show) pure
