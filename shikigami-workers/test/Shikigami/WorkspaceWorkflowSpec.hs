module Shikigami.WorkspaceWorkflowSpec (tests) where

import Baikai.Content qualified as Content
import Baikai.Context qualified as Context
import Baikai.Provider.Registry qualified as Provider
import Baikai.StopReason (StopReason (ToolUse))
import Baikai.Stream (liftCompleteToStream)
import Control.Exception (throwIO)
import Data.Aeson ((.=))
import Data.Aeson qualified as Aeson
import Data.Generics.Labels ()
import Data.IORef
import Data.Map.Strict qualified as Map
import Data.Text qualified as Text
import Data.Time (addUTCTime, getCurrentTime)
import Data.Vector qualified as Vector
import Effectful (Eff)
import Keiro.Workflow (WorkflowId (..), WorkflowOutcome (..), loadStepIndex)
import Kiroku.Store.Connection (KirokuStore (..), withStore)
import Kiroku.Store.Transaction (runTransaction)
import Shikigami.Action.Authorization
import Shikigami.Agent.Approval (autoApprovePolicy)
import Shikigami.Agent.Approval.Workflow qualified as Approval
import Shikigami.Agent.Decl
import Shikigami.Agent.Delegate.Context (DelegateCtx (..))
import Shikigami.Agent.Delegate.Depth (DelegationDepth (..))
import Shikigami.Agent.Loader (loadAgent)
import Shikigami.Agent.Name (AgentName (..))
import Shikigami.Agent.Principal (AgentIdentity (..), identityText)
import Shikigami.Agent.Run.Key (RunKey (..))
import Shikigami.Agent.RunJob
import Shikigami.Agent.Workflow qualified as Agent
import Shikigami.App (AppEffects, AppEnv (..), runAppIO)
import Shikigami.App.Config (AppConfig (..), defaultAppConfig)
import Shikigami.Attestation.Resolve (ProfileResolutionError (UnknownProfile))
import Shikigami.Behavior.Run (newBehaviorEnv)
import Shikigami.Behavior.StubProvider (stubApiProvider)
import Shikigami.Capability.Overlay (CapabilityDescriptor (..))
import Shikigami.Directory (disabledDirectoryHandle)
import Shikigami.Execution.Driver (ExecutionStart (..))
import Shikigami.Execution.Foreground (driveExecutionForeground)
import Shikigami.Execution.Identity (ExecutionRootId (..), OperationId (..))
import Shikigami.Execution.Policy.Types (defaultHarnessPolicy)
import Shikigami.Execution.Resources qualified as Resources
import Shikigami.Execution.ResourcesStore qualified as Roots
import Shikigami.Execution.SelectionRuntime (assignmentIdFor)
import Shikigami.Execution.Store qualified as Execution
import Shikigami.Execution.Transcript (ExecutionSnapshot (..), executionIdFor)
import Shikigami.Flow.Decision qualified as Decision
import Shikigami.Flow.Routing qualified as Routing
import Shikigami.Log qualified as Log
import Shikigami.Migrations.TestSupport (DatabaseFixture)
import Shikigami.PracticeReview.Capability qualified as Practice
import Shikigami.Prelude ((&), (.~))
import Shikigami.RunEvidence.Catalog qualified as Catalog
import Shikigami.Sink (GrantSource (StaticGrants), defaultGrantTable)
import Shikigami.Sink.Config
import Shikigami.Sink.Http (HttpLimits (..), credentialsFromConfig, newSinkHttp)
import Shikigami.StateRevision (StateRevision, parseRevision)
import Shikigami.Trigger.Enqueue (ensureRunQueue)
import Shikigami.WorkerSession.Input (SessionLimit (..))
import Shikigami.WorkerSession.Store qualified as Sessions
import Shikigami.WorkerSession.Types qualified as Sessions
import Shikigami.Workspace.Admission (WorkspaceHost (..))
import Shikigami.Workspace.Allocation
import Shikigami.Workspace.Catalog (repositoryBase)
import Shikigami.Workspace.Catalog qualified as WorkspaceCatalog
import Shikigami.Workspace.Cleanup
import Shikigami.Workspace.CleanupStore
import Shikigami.Workspace.ConfiguredHost
import Shikigami.Workspace.FileProvider
import Shikigami.Workspace.Instructions (WorkspaceAdmission (..), bundleDigest, mkInstructionBundle)
import Shikigami.Workspace.ProcessPolicy
import Shikigami.Workspace.Provider
import Shikigami.Workspace.Reference (WorkspaceRef (..))
import Shikigami.Workspace.Settings
import Shikigami.Workspace.Store qualified as Store
import Shikigami.Workspace.Systemd qualified as Systemd
import Shikigami.Workspace.Types
import Shikigami.WorkspaceStoreSpec qualified as Fixture
import System.Directory (createFileLink, doesPathExist, makeAbsolute)
import System.FilePath ((</>))
import Test.Tasty (TestTree, testGroup)
import Test.Tasty.HUnit

tests :: DatabaseFixture -> TestTree
tests fixture =
  testGroup
    "workspace governed parent and child"
    [ testCase "historical cleanup plans retain their encoding without invented ownership" $ do
        let original = Aeson.object ["bindingDigest" .= ("sha256:" <> Text.replicate 64 "a"), "filesTarget" .= ("1:2" :: Text.Text), "scratchTarget" .= ("1:3" :: Text.Text), "userId" .= (62000 :: Int)]
        case Aeson.fromJSON original of
          Aeson.Success (plan :: CleanupPlan) -> do
            plan.ownership @?= Nothing
            Aeson.toJSON plan @?= original
          Aeson.Error err -> assertFailure err,
      testCase "terminal cleanup recovers interruption without removing source, metadata or a sibling" $
        withWorkflow fixture \env root job _ deps _ -> do
          binding <- finishWorkspace env job deps
          writeFile (root </> "retained-sibling") "sibling"
          let runtime = maintenance env root
              interrupted = (runtime & #afterFiles .~ (throwIO (userError "fixture lost cleanup acknowledgement")))
          cleanupWorkspace interrupted job.identity binding.workspace >>= (@?= Left CleanupUnresolved)
          doesPathExist (workspaceFiles root binding) >>= (@?= False)
          doesPathExist (workspaceScratch root binding) >>= (@?= True)
          Just (_, False) <- run env (runTransaction (inspectCleanupTx binding))
          cleanupWorkspace runtime job.identity binding.workspace >>= (@?= Right ())
          cleanupWorkspace runtime job.identity binding.workspace >>= (@?= Right ())
          doesPathExist (workspaceScratch root binding) >>= (@?= False)
          doesPathExist (workspaceMetadata root binding) >>= (@?= True)
          readFile (binding.source </> "dependency.txt") >>= (@?= "old dependency\n")
          readFile (root </> "retained-sibling") >>= (@?= "sibling")
          Just (_, True) <- run env (runTransaction (inspectCleanupTx binding))
          catalog <- right (WorkspaceCatalog.mkWorkspaceCatalog [WorkspaceCatalog.RepositoryPolicy binding.repository binding.source [binding.base] binding.base binding.policyRevision])
          repository <- right (WorkspaceCatalog.resolveRepository catalog binding.repository Nothing)
          run env (runTransaction (Store.reserveWorkspaceTx root binding.request repository)) >>= (@?= Left WorkspaceBindingConflict)
          (foreignBinding, _) <- right =<< run env (runTransaction (Store.reserveWorkspaceTx (root <> "-other") (binding.request & #runId .~ "foreign-workspace") repository))
          listing <- right =<< listWorkspaces runtime job.identity Nothing
          assertBool "operator listing omits other storage roots, local paths and private instructions" (all (\secret -> not (secret `Text.isInfixOf` Text.pack (show (Aeson.encode listing)))) [Text.pack root, Text.pack binding.source, "PRIVATE_WORKFLOW_POLICY", foreignBinding.workspace.resource])
          Agent.runAgentRunWorkflow deps job >>= assertCompleted,
      testCase "active execution and denied cleanup leave the worktree untouched" $
        withWorkflow fixture \env root job _ deps _ -> do
          Agent.runAgentRunWorkflow deps job >>= assertSuspended
          binding <- admittedBinding env job
          cleanupWorkspace (maintenance env root) job.identity binding.workspace >>= (@?= Left CleanupRefused)
          run env (runTransaction (inspectCleanupTx binding)) >>= (@?= Nothing)
          _ <- finishWorkspace env job deps
          let denied = (maintenance env root) & #authorizer .~ denyAllActionAuthorizer
          cleanupWorkspace denied job.identity binding.workspace >>= (@?= Left CleanupRefused)
          readFile (workspaceFiles root binding </> "dependency.txt") >>= (@?= "workflow replacement\n"),
      testCase "terminal cleanup refuses unsettled effects and a live idle session" $
        withWorkflow fixture \env root job _ deps _ -> do
          binding <- finishWorkspace env job deps
          parentSession <- pure binding.request.runId
          parent <- right =<< loadAgent "../agents/heartbeat.dhall"
          access <- right =<< run env (Execution.authorizeReplay (executionIdFor (assignmentIdFor (runJobWorkflowId job).unWorkflowId)) job.identity (pure (Right ())))
          (snapshot, _) <- right =<< run env (Execution.loadExecution access)
          let coordinator = CompatibilityIdentity "cleanup-coordinator"
              admission = Sessions.SessionAdmission 1 (Sessions.SessionScope parentSession "worker") (Sessions.ObjectiveRef "fixture" "objective") (parent & #name .~ "cleanup-coordinator" & #delegates .~ ["workspace-worker"]) (DelegateCtx (DelegationDepth 0) coordinator (Just snapshot.sessionId) Nothing (Just (WorkflowId "cleanup-parent")) [AgentName "cleanup-coordinator"] Nothing (Just binding.request.rootId) Nothing defaultDelegationBudget) (AgentName "workspace-worker") job.identity (fixtureLimit 10) (fixtureLimit 4)
          _ <- right =<< run env (Sessions.openSession admission)
          cleanupWorkspace (maintenance env root) job.identity binding.workspace >>= (@?= Left CleanupRefused)
          run env (runTransaction (inspectCleanupTx binding)) >>= (@?= Nothing)
          readFile (workspaceFiles root binding </> "dependency.txt") >>= (@?= "workflow replacement\n"),
      testCase "terminal cleanup refuses a prepared mutation without inferring settlement from a free lock" $
        withWorkflow fixture \env root job _ deps _ -> do
          binding <- finishWorkspace env job deps
          run env (runTransaction (Store.reserveWorkspaceEffectTx binding job.identity (fixtureRevision 0) (OperationId "pending-cleanup-effect") "pending")) >>= (@?= Right Nothing)
          cleanupWorkspace (maintenance env root) job.identity binding.workspace >>= (@?= Left CleanupRefused)
          run env (runTransaction (inspectCleanupTx binding)) >>= (@?= Nothing)
          doesPathExist (workspaceFiles root binding) >>= (@?= True),
      testCase "hostile terminal tree is never followed or partly deleted" $
        withWorkflow fixture \env root job _ deps _ -> do
          binding <- finishWorkspace env job deps
          let marker = root </> "outside-marker"
          writeFile marker "outside"
          createFileLink marker (workspaceFiles root binding </> "escape")
          cleanupWorkspace (maintenance env root) job.identity binding.workspace >>= (@?= Left CleanupUnresolved)
          readFile marker >>= (@?= "outside")
          readFile (workspaceFiles root binding </> "dependency.txt") >>= (@?= "workflow replacement\n"),
      testCase "real parent admission freezes instructions and child edits once across restart" $
        withWorkflow fixture \env root job host deps observed -> do
          Agent.runAgentRunWorkflow deps job >>= assertSuspended
          let execution = executionIdFor (assignmentIdFor (runJobWorkflowId job).unWorkflowId)
          Just (_, _, _) <- right =<< run env (Execution.inspectExecution execution)
          -- The retained snapshot must resume even when today's repository
          -- selector is unavailable; its base/instructions never reload.
          let retired = (deps & #workspace .~ (Just ((host & #load .~ (\_ -> assertFailure "retained assignment reloaded source" >> fail "unreachable")))))
          Agent.runAgentRunWorkflow retired job >>= assertSuspended
          result <- right =<< driveExecutionForeground (Agent.executionRuntime retired) (ExecutionStart execution) 30
          assertBool "execution child completed" (maybe False (const True) result)
          (snapshot, _) <- do
            access <- right =<< run env (Execution.authorizeReplay execution job.identity (pure (Right ())))
            right =<< run env (Execution.loadExecution access)
          admission <- maybe (fail "workspace admission missing") pure snapshot.workspace
          let request = WorkspaceRequest snapshot.runId Nothing (ExecutionRootId "workflow-root") job.identity job.identity (fixtureRevision 0)
              -- The binding itself is authoritative, never a model-selected path.
              storage = root
          Just (binding, _) <- run env (runTransaction (Store.inspectWorkspaceTx admission.workspace))
          binding.request @?= request
          readFile (workspaceFiles storage binding </> "dependency.txt") >>= (@?= "workflow replacement\n")
          contexts <- readIORef observed
          length contexts @?= 2
          assertBool "every real model request includes pinned repository instructions" (all (maybe False (Text.isInfixOf "PRIVATE_WORKFLOW_POLICY") . (.systemPrompt)) contexts)
          Agent.runAgentRunWorkflow retired job >>= assertCompleted
          Agent.runAgentRunWorkflow retired job >>= assertCompleted
          length <$> readIORef observed >>= (@?= 2)
          journal <- run env (loadStepIndex Agent.agentRunWorkflowName (runJobWorkflowId job) 0)
          assertBool "new admission label belongs to the real parent" (Map.member "admit-workspace-skill-execution" journal)
          assertBool "historical admission label is not reused" (not (Map.member "admit-skill-execution" journal)),
      testCase "installing the supervised host preserves an admitted file-only execution without provisioning it" $
        withWorkflow fixture \env root job _ deps observed -> withStore env.connectionSettings \store -> do
          Agent.runAgentRunWorkflow deps job >>= assertSuspended
          binding <- admittedBinding env job
          let execution = executionIdFor (assignmentIdFor (runJobWorkflowId job).unWorkflowId)
          access <- right =<< run env (Execution.authorizeReplay execution job.identity (pure (Right ())))
          (snapshot, _) <- right =<< run env (Execution.loadExecution access)
          admission <- maybe (fail "workspace admission missing") pure snapshot.workspace
          principal <- right (identityText job.identity)
          let digest = "sha256:" <> Text.replicate 64 "a"
              policy = ProcessPolicy 1 (ProcessImage "/qualified/root" digest "/bin/env" "/bin/deadline" "/qualified/collector") digest [CommandRule "validate" "/bin/validate" [] "" Map.empty 30 1024] [""] ["dependency.txt"]
              process = WorkspaceProcessSettings "/run/shikigami/supervisor.sock" 0 5 60 (IdentityRange 64000 64031) (Map.singleton binding.repository policy)
              settings = WorkspaceSettings root [WorkspaceRepository binding.repository binding.source [WorkspaceRevision binding.base (bundleDigest admission.instructions)] binding.base "policy-1" [""] ["dependency.txt"]] [WorkspaceGrant "workspace-worker" principal binding.repository Nothing] (Just process)
          host <- right (configuredWorkspaceHost env store.pool disabledDirectoryHandle allowAllActionAuthorizerForTests settings)
          let resumed = (deps & #capabilities .~ (host.capabilities) & #workspace .~ (Just ((host & #load .~ (\_ -> assertFailure "old file assignment attempted process provisioning" >> fail "unreachable")))))
          _ <- right =<< driveExecutionForeground (Agent.executionRuntime resumed) (ExecutionStart execution) 30
          Agent.runAgentRunWorkflow resumed job >>= assertCompleted
          readFile (workspaceFiles root binding </> "dependency.txt") >>= (@?= "workflow replacement\n")
          length <$> readIORef observed >>= (@?= 2),
      testCase "operator principal mismatch refuses before source allocation" $
        withWorkflowConfig (\settings -> settings & #grants .~ [WorkspaceGrant "workspace-worker" "other-principal" "mori://fixture/repo" Nothing]) fixture \_ root job _ deps observed -> do
          Agent.runAgentRunWorkflow deps job >>= assertRefused
          doesPathExist root >>= (@?= False)
          readIORef observed >>= (@?= []),
      testCase "unreviewed instruction digest refuses before protected execution or model dispatch" $
        withWorkflowConfig (\settings -> settings & #repositories .~ [(entry & #revisions .~ ([(revision & #instructionDigest .~ ("sha256:" <> Text.replicate 64 "0")) | revision <- entry.revisions])) | entry <- settings.repositories]) fixture \env _ job _ deps observed -> do
          Agent.runAgentRunWorkflow deps job >>= assertRefused
          let execution = executionIdFor (assignmentIdFor (runJobWorkflowId job).unWorkflowId)
          run env (Execution.inspectExecution execution) >>= (@?= Right Nothing)
          readIORef observed >>= (@?= []),
      testCase "allocation requires fresh external authority before reading the source" $
        withWorkflowAuthority denyAllActionAuthorizer id fixture \_ root job _ deps observed -> do
          Agent.runAgentRunWorkflow deps job >>= assertRefused
          doesPathExist root >>= (@?= False)
          readIORef observed >>= (@?= []),
      testCase "configured process host description performs no provisioning and unsupported admission never allocates" $
        withWorkflowConfig supervised fixture \_ root job host deps observed -> do
          doesPathExist root >>= (@?= False)
          readIORef observed >>= (@?= [])
          -- Constructing the operator host exposes descriptions only. On an
          -- unsupported host its actual admission refuses before source IO.
          supported <- Systemd.systemdBootIdentity
          case supported of
            Left _ -> do
              Agent.runAgentRunWorkflow deps job >>= assertRefused
              doesPathExist root >>= (@?= False)
              readIORef observed >>= (@?= [])
            Right _ -> pure ()
          host `seq` pure (),
      testCase "a configured write restriction refuses the accepted target without a file effect" $
        withWorkflowConfig (\settings -> settings & #repositories .~ [entry & #writePaths .~ ["other"] | entry <- settings.repositories]) fixture \env root job _ deps observed -> do
          Agent.runAgentRunWorkflow deps job >>= assertSuspended
          let execution = executionIdFor (assignmentIdFor (runJobWorkflowId job).unWorkflowId)
          _ <- right =<< driveExecutionForeground (Agent.executionRuntime deps) (ExecutionStart execution) 30
          access <- right =<< run env (Execution.authorizeReplay execution job.identity (pure (Right ())))
          (snapshot, _) <- right =<< run env (Execution.loadExecution access)
          admission <- maybe (fail "workspace admission missing") pure snapshot.workspace
          Just (binding, _) <- run env (runTransaction (Store.inspectWorkspaceTx admission.workspace))
          readFile (workspaceFiles root binding </> "dependency.txt") >>= (@?= "old dependency\n")
          length <$> readIORef observed >>= (@?= 2)
    ]
  where
    supervised settings = settings & #process .~ Just (WorkspaceProcessSettings "/run/shikigami/supervisor.sock" 0 5 60 (IdentityRange 64000 64031) (Map.fromList [(entry.identity, ProcessPolicy 1 (ProcessImage "/qualified/root" digest "/bin/env" "/bin/deadline" "/qualified/collector") digest [CommandRule "validate" "/bin/validate" [] "" Map.empty 30 1024] entry.readPaths entry.writePaths) | entry <- settings.repositories]))
    digest = "sha256:" <> Text.replicate 64 "a"

withWorkflow :: DatabaseFixture -> (AppEnv -> FilePath -> RunJob -> WorkspaceHost -> Agent.AgentRunDeps -> IORef [Context.Context] -> IO a) -> IO a
withWorkflow = withWorkflowConfig id

withWorkflowConfig :: (WorkspaceSettings -> WorkspaceSettings) -> DatabaseFixture -> (AppEnv -> FilePath -> RunJob -> WorkspaceHost -> Agent.AgentRunDeps -> IORef [Context.Context] -> IO a) -> IO a
withWorkflowConfig = withWorkflowAuthority allowAllActionAuthorizerForTests

withWorkflowAuthority :: ActionAuthorizer -> (WorkspaceSettings -> WorkspaceSettings) -> DatabaseFixture -> (AppEnv -> FilePath -> RunJob -> WorkspaceHost -> Agent.AgentRunDeps -> IORef [Context.Context] -> IO a) -> IO a
withWorkflowAuthority authorizer configure fixture use = Fixture.withFixture fixture \env source root _ -> withStore env.connectionSettings \store -> do
  writeFile (source </> "AGENTS.md") "PRIVATE_WORKFLOW_POLICY: validate changes"
  repository <- Fixture.commitRepository source
  original <- right =<< loadAgent "../agents/triage-note.dhall"
  skill <- makeAbsolute "../agents/skills/triage-note"
  now <- getCurrentTime
  observed <- newIORef []
  base <- newBehaviorEnv
  http <- right =<< newSinkHttp (HttpLimits defaultAppConfig.httpRequestMaxBytes defaultAppConfig.httpResponseMaxBytes) (credentialsFromConfig defaultAppConfig) (DanwaConfig "http://localhost:1" "fixture")
  let complete model context options = do
        ordinal <- atomicModifyIORef' observed (\values -> (values <> [context], length values))
        response <- Provider.complete stubApiProvider model context options
        pure (if ordinal == 0 then response & #message . #stopReason .~ ToolUse & #message . #content .~ Vector.singleton (Content.AssistantToolCall (Content.ToolCall "edit" "overlay__workspace-edit__replace" (Aeson.toJSON (Replacement "dependency.txt" (Just (contentDigest "old dependency\n")) "workflow replacement\n")))) else response)
      provider = (stubApiProvider & #complete .~ (complete) & #stream .~ (liftCompleteToStream complete))
  providers <- Provider.newProviderRegistryFrom [provider]
  expected <- right (mkInstructionBundle 65536 "mori://fixture/repo" (repositoryBase repository) [("AGENTS.md", "PRIVATE_WORKFLOW_POLICY: validate changes")])
  principal <- right (identityText (CompatibilityIdentity "workspace-worker"))
  let settings = WorkspaceSettings root [WorkspaceRepository "mori://fixture/repo" source [WorkspaceRevision (repositoryBase repository) (bundleDigest expected)] (repositoryBase repository) "policy-1" [""] ["dependency.txt"]] [WorkspaceGrant "workspace-worker" principal "mori://fixture/repo" Nothing] Nothing
  host <- right (configuredWorkspaceHost env store.pool disabledDirectoryHandle authorizer (configure settings))
  let declaration = original & #name .~ "workspace-worker" & #behavior .~ Skill (Text.pack skill) & #identity .~ Just (IdentityDecl "workspace-principal") & #capabilityOverlays .~ [workspaceEditDescriptor.capability] & #sinks .~ []
      identity = CompatibilityIdentity "workspace-worker"
      rootId = ExecutionRootId "workflow-root"
      job = RunJob (AgentName "workspace-worker") identity TriggeredBySchedule now Aeson.Null (RunKey "workspace-workflow-fixture") Nothing Nothing Nothing [] Nothing Nothing (Just rootId) Nothing AgentWorkflowRoute
      deps =
        Agent.AgentRunDeps
          { appEnv = env,
            behaviorEnv = base & #providerRegistry .~ Just providers,
            decisions = Decision.emptyDecisionServices,
            actionAuthorizer = authorizer,
            capabilities = host.capabilities,
            workspace = Just host,
            coordination = Nothing,
            agents = [declaration],
            kizashi = KizashiConfig "http://localhost:1" "recipient",
            kawa = KawaConfig "http://localhost:1" "fixture",
            kanmon = KanmonConfig "http://localhost:1",
            danwa = DanwaConfig "http://localhost:1" "fixture",
            rei = ReiConfig Nothing,
            http,
            hooks = Agent.defaultAgentRunHooks,
            approvalPolicy = autoApprovePolicy 900,
            approvalWorkflow = Approval.defaultApprovalWorkflowEnv,
            runTimeout = 30,
            harness = defaultHarnessPolicy,
            delegationBudget = defaultDelegationBudget,
            grants = StaticGrants defaultGrantTable,
            directory = disabledDirectoryHandle,
            routing = Routing.RoutingRuntime (\_ -> error "no router") (\_ _ _ -> error "no router"),
            practiceReview = Practice.unavailablePracticeReviewRuntime,
            deliveryPool = Nothing,
            logger = Log.silentLogger,
            resolveRunProfile = \profile version -> pure (Left (UnknownProfile profile version))
          }
  _ <- right =<< run env Catalog.registerProjectionCatalog
  _ <- right =<< ensureRunQueue store.pool
  run env (Roots.enrollRoot rootId (Resources.Envelope (Map.fromList [(dimension, Resources.ExplicitlyUnbounded) | dimension <- [minBound .. maxBound]]) (addUTCTime 3600 now))) >>= (@?= Right Resources.Accepted)
  use env root job host deps observed

assertSuspended :: (Show e, Show a) => Either e (WorkflowOutcome a) -> IO ()
assertSuspended (Right Suspended) = pure ()
assertSuspended other = assertFailure ("expected suspended parent: " <> show other)

assertCompleted :: (Show e, Show a, Show b) => Either e (WorkflowOutcome (Either a b)) -> IO ()
assertCompleted (Right (Completed (Right _))) = pure ()
assertCompleted other = assertFailure ("expected completed parent: " <> show other)

assertRefused :: (Show e, Show a, Show b) => Either e (WorkflowOutcome (Either a b)) -> IO ()
assertRefused (Right (Completed (Left _))) = pure ()
assertRefused other = assertFailure ("expected refused parent: " <> show other)

run :: AppEnv -> Eff AppEffects a -> IO a
run env action = runAppIO env action >>= right

right :: (Show e) => Either e a -> IO a
right = either (\err -> assertFailure (show err) >> fail "unreachable") pure

maintenance :: AppEnv -> FilePath -> MaintenanceRuntime
maintenance env root = MaintenanceRuntime env root allowAllActionAuthorizerForTests (\_ -> pure (Right ())) (pure ())

admittedBinding :: AppEnv -> RunJob -> IO WorkspaceBinding
admittedBinding env job = do
  let execution = executionIdFor (assignmentIdFor (runJobWorkflowId job).unWorkflowId)
  access <- right =<< run env (Execution.authorizeReplay execution job.identity (pure (Right ())))
  (snapshot, _) <- right =<< run env (Execution.loadExecution access)
  admission <- maybe (fail "workspace admission missing") pure snapshot.workspace
  Just (binding, _) <- run env (runTransaction (Store.inspectWorkspaceTx admission.workspace))
  pure binding

finishWorkspace :: AppEnv -> RunJob -> Agent.AgentRunDeps -> IO WorkspaceBinding
finishWorkspace env job deps = do
  Agent.runAgentRunWorkflow deps job >>= assertSuspended
  let execution = executionIdFor (assignmentIdFor (runJobWorkflowId job).unWorkflowId)
  _ <- right =<< driveExecutionForeground (Agent.executionRuntime deps) (ExecutionStart execution) 30
  Agent.runAgentRunWorkflow deps job >>= assertCompleted
  admittedBinding env job

fixtureRevision :: Integer -> StateRevision scope
fixtureRevision value = either (error . show) id (parseRevision value)

fixtureLimit :: (SessionLimit a) => Integer -> a
fixtureLimit value = either (error . show) id (parseSessionLimit value)
