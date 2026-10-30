module Shikigami.WorkspaceWorkflowSpec (tests) where

import Baikai.Content qualified as Content
import Baikai.Context qualified as Context
import Baikai.Provider.Registry qualified as Provider
import Baikai.StopReason (StopReason (ToolUse))
import Baikai.Stream (liftCompleteToStream)
import Data.Aeson qualified as Aeson
import Data.Generics.Labels ()
import Data.IORef
import Data.Map.Strict qualified as Map
import Data.Set qualified as Set
import Data.Text qualified as Text
import Data.Time (addUTCTime, getCurrentTime)
import Data.Vector qualified as Vector
import Effectful (Eff)
import Keiro.Workflow (PatchId (..), WorkflowId (..), WorkflowOutcome (..), WorkflowRunOptions (..), loadStepIndex, runWorkflowWith)
import Kioku.App (AppEffects, AppEnv (..), runAppIO)
import Kiroku.Store.Connection (KirokuStore (..), withStore)
import Kiroku.Store.Transaction (runTransaction)
import Shikigami.Action.Authorization
import Shikigami.Agent.Approval (autoApprovePolicy)
import Shikigami.Agent.Approval.Workflow qualified as Approval
import Shikigami.Agent.Decl
import Shikigami.Agent.Loader (loadAgent)
import Shikigami.Agent.Name (AgentName (..))
import Shikigami.Agent.Principal (AgentIdentity (..), identityText)
import Shikigami.Agent.Run.Key (RunKey (..))
import Shikigami.Agent.RunJob
import Shikigami.Agent.Workflow qualified as Agent
import Shikigami.App.Config (AppConfig (..), defaultAppConfig)
import Shikigami.Attestation.Resolve (ProfileResolutionError (UnknownProfile))
import Shikigami.Behavior.Run (newBehaviorEnv)
import Shikigami.Behavior.StubProvider (stubApiProvider)
import Shikigami.Capability.Overlay (CapabilityDescriptor (..))
import Shikigami.Directory (disabledDirectoryHandle)
import Shikigami.Execution.Driver (ExecutionStart (..))
import Shikigami.Execution.Foreground (driveExecutionForeground)
import Shikigami.Execution.Identity (ExecutionRootId (..))
import Shikigami.Execution.Policy.Types (defaultHarnessPolicy)
import Shikigami.Execution.Resources qualified as Resources
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
import Shikigami.Store.ExecutionResources qualified as Roots
import Shikigami.Trigger.Enqueue (ensureRunQueue)
import Shikigami.Workflow.Versioning (shikigamiWorkflowRunOptions)
import Shikigami.Workspace.Admission (WorkspaceHost (..))
import Shikigami.Workspace.Allocation
import Shikigami.Workspace.Catalog (repositoryBase)
import Shikigami.Workspace.ConfiguredHost
import Shikigami.Workspace.FileProvider
import Shikigami.Workspace.Instructions (WorkspaceAdmission (..), bundleDigest, mkInstructionBundle)
import Shikigami.Workspace.ProcessPolicy
import Shikigami.Workspace.Provider
import Shikigami.Workspace.Settings
import Shikigami.Workspace.Store qualified as Store
import Shikigami.Workspace.Systemd qualified as Systemd
import Shikigami.Workspace.Types
import Shikigami.WorkspaceStoreSpec qualified as Fixture
import System.Directory (doesPathExist, makeAbsolute)
import System.FilePath ((</>))
import Test.Tasty (TestTree, testGroup)
import Test.Tasty.HUnit

tests :: DatabaseFixture -> TestTree
tests fixture =
  testGroup
    "workspace governed parent and child"
    [ testCase "real parent admission freezes instructions and child edits once across restart" $
        withWorkflow fixture \env root job host deps observed -> do
          Agent.runAgentRunWorkflow deps job >>= assertSuspended
          let execution = executionIdFor (assignmentIdFor (runJobWorkflowId job).unWorkflowId)
          Just (_, _, _) <- right =<< run env (Execution.inspectExecution execution)
          -- The retained snapshot must resume even when today's repository
          -- selector is unavailable; its base/instructions never reload.
          let retired = deps {Agent.workspace = Just (host {load = \_ -> assertFailure "retained assignment reloaded source" >> fail "unreachable"})}
          Agent.runAgentRunWorkflow retired job >>= assertSuspended
          result <- right =<< driveExecutionForeground (Agent.executionRuntime retired) (ExecutionStart execution) 30
          assertBool "execution child completed" (maybe False (const True) result)
          (snapshot, _) <- do
            access <- right =<< run env (Execution.authorizeReplay execution job.identity (pure (Right ())))
            right =<< run env (Execution.loadExecution access)
          admission <- maybe (fail "workspace admission missing") pure snapshot.workspace
          let request = WorkspaceRequest snapshot.runId Nothing (ExecutionRootId "workflow-root") job.identity job.identity 0
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
      testCase "old patch snapshot refuses mutation without allocating or calling a model" $
        withWorkflow fixture \env root job _ deps observed -> do
          let options = shikigamiWorkflowRunOptions env & #activePatches .~ Set.delete (PatchId "shikigami-governed-workspaces-v1") (shikigamiWorkflowRunOptions env).activePatches
          outcome <- run env (runWorkflowWith options Agent.agentRunWorkflowName (runJobWorkflowId job) (Agent.agentRunWorkflow deps (Just job)))
          case outcome of Completed (Left _) -> pure (); _ -> assertFailure ("old branch admitted mutation: " <> show outcome)
          doesPathExist root >>= (@?= False)
          readIORef observed >>= (@?= []),
      testCase "operator principal mismatch refuses before source allocation" $
        withWorkflowConfig (\settings -> settings & #grants .~ [WorkspaceGrant "workspace-worker" "other-principal" "mori://fixture/repo" Nothing]) fixture \_ root job _ deps observed -> do
          Agent.runAgentRunWorkflow deps job >>= assertRefused
          doesPathExist root >>= (@?= False)
          readIORef observed >>= (@?= []),
      testCase "unreviewed instruction digest refuses before protected execution or model dispatch" $
        withWorkflowConfig (\settings -> settings & #repositories .~ [entry {revisions = [revision {instructionDigest = "sha256:" <> Text.replicate 64 "0"} | revision <- entry.revisions]} | entry <- settings.repositories]) fixture \env _ job _ deps observed -> do
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
      provider = stubApiProvider {Provider.complete = complete, Provider.stream = liftCompleteToStream complete}
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
