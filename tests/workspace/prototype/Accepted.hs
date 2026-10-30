-- Actual accepted execution/claim plumbing for the disposable Linux fixture.
-- Only the model response is deterministic; files, accounts, RPC and systemd
-- use their production interpreters.
module Accepted (Prepared (..), prepareAccepted, prepareUpgrade, advanceUpgrade, executePrepared, executeGitWithBackend, prepareTools, continueTools, advanceTools, executeWithProviders) where

import Baikai.Options (emptyOptions)
import Baikai.StopReason (StopReason (ToolUse))
import Control.Monad (unless, void)
import Data.Aeson qualified as Aeson
import Data.Aeson.KeyMap qualified as KeyMap
import Data.Generics.Labels ()
import Data.Map.Strict qualified as Map
import Data.Text qualified as Text
import Data.Time (getCurrentTime)
import Data.UUID.V4 qualified as UUID
import Data.Vector qualified as Vector
import Effectful (Eff)
import GHC.Generics (Generic)
import GHC.Stack (HasCallStack, callStack, prettyCallStack)
import Keiro.Workflow.Awakeable (AwakeableId (..))
import Keiro.Workflow.Awakeable.Schema (registerAwakeableTx)
import Keiro.Workflow.Types (WorkflowId (..))
import Kioku.Id (genSessionId)
import Kiroku.Store.Transaction (runTransaction)
import Shikigami.Action.Authorization (ActionAuthorizer)
import Shikigami.Agent.Decl (Behavior (Skill))
import Shikigami.Agent.Name (AgentName (..))
import Shikigami.App (AppEffects, AppEnv, runAppIO)
import Shikigami.Behavior.StubProvider (stubModel)
import Shikigami.Capability.Catalog
import Shikigami.Capability.Overlay
import Shikigami.Capability.Provider
import Shikigami.Decision.Contract (versionedDigest)
import Shikigami.Decision.ModelCatalog (modelCatalog)
import Shikigami.Execution.Attempt qualified as Attempt
import Shikigami.Execution.Executor qualified as Executor
import Shikigami.Execution.Identity
import Shikigami.Execution.Policy.Types
import Shikigami.Execution.Resources qualified as Resources
import Shikigami.Execution.Selection
import Shikigami.Execution.SelectionStore qualified as Calls
import Shikigami.Execution.Store qualified as Execution
import Shikigami.Execution.Tools qualified as Tools
import Shikigami.Execution.Transcript
import Shikigami.Log qualified as Log
import Shikigami.Prelude ((&), (.~))
import Shikigami.RunEvidence.Catalog qualified as Catalog
import Shikigami.Workspace.FileProvider
import Shikigami.Workspace.GitProvider
import Shikigami.Workspace.GitTypes (GitCommitRequest (..))
import Shikigami.Workspace.Instructions
import Shikigami.Workspace.ProcessProvider
import Shikigami.Workspace.Provider (Replacement (..), contentDigest)
import Shikigami.Workspace.Types

data Prepared = Prepared {snapshot :: !ExecutionSnapshot, reference :: !Attempt.JobReference}
  deriving stock (Generic)
  deriving anyclass (Aeson.ToJSON, Aeson.FromJSON)

prepareAccepted :: AppEnv -> ActionAuthorizer -> (ExecutionSnapshot -> IO (Either Text.Text ())) -> ProcessClient -> WorkspaceBinding -> WorkspaceAdmission -> Text.Text -> IO Prepared
prepareAccepted = preparePlan False

prepareUpgrade :: AppEnv -> ActionAuthorizer -> (ExecutionSnapshot -> IO (Either Text.Text ())) -> ProcessClient -> WorkspaceBinding -> WorkspaceAdmission -> IO Prepared
prepareUpgrade env authorizer current client binding admission = preparePlan True env authorizer current client binding admission "complete"

preparePlan :: Bool -> AppEnv -> ActionAuthorizer -> (ExecutionSnapshot -> IO (Either Text.Text ())) -> ProcessClient -> WorkspaceBinding -> WorkspaceAdmission -> Text.Text -> IO Prepared
preparePlan upgrade env authorizer current client binding admission mode = do
  now <- getCurrentTime
  session <- genSessionId
  selection <- right (resolveExecutionSelection admission.assignmentId (must (modelCatalog [])) (defaultBinding stubModel emptyOptions) Nothing Nothing Nothing Nothing (Just admission.rootId) now)
  let runtime = fileRuntime env authorizer current
      providers = registry runtime client
      descriptors = [supervisedWorkspaceEditDescriptor, (workspaceExecAdapter client).descriptor] <> [workspaceGitDescriptor | upgrade]
  catalog <- right (mkCapabilityCatalog descriptors)
  capabilities <- right (resolveGovernedCapabilityOverlays (durableAdapterInstalled providers) catalog (\_ _ -> Right ()) (ResolutionSubject (Just "fixture") Durable (Skill "fixture") Nothing) (map (.capability) descriptors))
  let initial = ExecutionSnapshot 1 (executionIdFor admission.assignmentId) binding.request.runId (AgentName "fixture") admission.owner session selection Nothing (SkillInstructions "fixture" "system" "body") (ReplayContext 2 (Just (instructionPrompt admission.instructions)) [RequestTurn [TextBlock "fixture edit and validation"] Nothing]) capabilities (Aeson.toJSON ([] :: [Aeson.Value])) defaultHarnessPolicy [] (Just admission)
  menu <- right =<< Tools.describeExecutionTools Log.silentLogger authorizer providers native initial
  let edit = only (filter (\tool -> tool.name == "overlay__workspace-edit__replace") menu.toolBindings)
      validate = only (filter (\tool -> tool.name == "overlay__workspace-exec__validate") menu.toolBindings)
      commit = only (filter (\tool -> tool.name == "overlay__workspace-git__commit") menu.toolBindings)
      selected = [edit, validate] <> [commit | upgrade]
      filterTool (Aeson.Object fields) = KeyMap.lookup "name" fields `elem` map (Just . Aeson.String . (.name)) selected
      filterTool _ = False
      offered = case menu.offeredTools of Aeson.Array values -> Aeson.Array (Vector.filter filterTool values); value -> value
      snapshot = initial & #offeredTools .~ offered & #toolBindings .~ selected
      editInput = Aeson.toJSON (if upgrade then Replacement "src/dependency.txt" (Just (contentDigest "old dependency\n")) "new dependency\n" else Replacement "src/mode" (Just (contentDigest "complete\n")) (mode <> "\n"))
      validateInput = Aeson.object ["rule" Aeson..= ("validate" :: Text.Text)]
      commitInput = Aeson.toJSON (GitCommitRequest binding.base "chore(deps): upgrade fixture dependency")
      assistant = ReplayAssistant 1 ([ToolBlock (ToolInvocation "edit-mode" edit.name editInput), ToolBlock (ToolInvocation "validate-mode" validate.name validateInput)] <> [ToolBlock (ToolInvocation "commit-upgrade" commit.name commitInput) | upgrade]) ToolUse Nothing Nothing (Aeson.object []) Nothing
      model = OperationSpec (operationIdFor snapshot.executionId 0) ModelTurn RepeatableObservation "model" (policyDigest snapshot) "scope" Nothing
  void (right =<< run env Catalog.registerProjectionCatalog)
  void (right =<< run env (Execution.admitExecution snapshot))
  access <- right =<< run env (Execution.authorizeReplay snapshot.executionId snapshot.identity (current snapshot))
  (_, operation) <- right =<< run env (Execution.acceptOperation access 0 model (Aeson.object []))
  let OperationId key = operation.specification.operationId
      request = Resources.AttemptRequest (AttemptId ("model:" <> key)) operation.specification.operationId (Map.fromList [(Resources.ActiveWork, 1), (Resources.ModelAttempts, 1), (Resources.Tokens, 10), (Resources.CostMicroUsd, 0)]) Resources.EnforcedCeiling
  reservation <- right =<< run env (Calls.reserveSelectionCall selection (Calls.CallLimits Nothing Nothing Nothing Nothing Nothing) request "fixture-model" now)
  call <- case reservation of Calls.NewCall value -> pure value; _ -> fail "new fixture model call required"
  let outcome = ModelReturned assistant Nothing
  response <- right (Execution.outcomeReference outcome)
  void (right =<< run env (Execution.recordOutcomeAndAdvance access 1 operation.specification.operationId outcome (NeedTool response 0) (Just (call, Calls.CallOutcome Calls.CallTerminal (Map.fromList [(Resources.Tokens, 1), (Resources.CostMicroUsd, 0)]) [] Nothing Nothing Nothing))))
  first <- submit env snapshot access (ToolOperationInput response 0 (ToolInvocation "edit-mode" edit.name editInput) edit)
  executePrepared env authorizer current client first
  (_, afterEdit) <- right =<< run env (Execution.loadExecution access)
  unless (afterEdit.cursor == 2 && afterEdit.next == NeedTool response 1) (fail "native edit did not advance")
  submit env snapshot access (ToolOperationInput response 1 (ToolInvocation "validate-mode" validate.name validateInput) validate)
  where
    only [value] = value
    only _ = error "fixture exact tool binding missing"

advanceUpgrade :: AppEnv -> (ExecutionSnapshot -> IO (Either Text.Text ())) -> Prepared -> IO Prepared
advanceUpgrade env current prepared = do
  let snapshot = prepared.snapshot
  access <- right =<< run env (Execution.authorizeReplay snapshot.executionId snapshot.identity (current snapshot))
  (_, state) <- right =<< run env (Execution.loadExecution access)
  case state.next of
    NeedTool response 2 | state.cursor == 3 -> do
      outcome <- right =<< run env (Execution.readReplayPayload @OperationOutcome access "operation-outcome" response)
      case outcome of
        ModelReturned assistant _ -> case drop 2 (toolInvocations assistant) of
          [invocation] -> case filter (\binding -> binding.name == invocation.name && binding == gitBinding "commit") snapshot.toolBindings of
            [binding] -> submit env snapshot access (ToolOperationInput response 2 invocation binding)
            _ -> fail "exact Git binding missing"
          _ -> fail "retained commit invocation missing"
        _ -> fail "retained model response missing"
    _ -> fail "validated upgrade continuation missing"

submit :: AppEnv -> ExecutionSnapshot -> Execution.ReplayAccess -> ToolOperationInput -> IO Prepared
submit env snapshot access input = do
  (_, state) <- right =<< run env (Execution.loadExecution access)
  let position = state.cursor
      specification = OperationSpec (operationIdFor snapshot.executionId position) ToolOperation input.binding.recovery input.binding.name (policyDigest snapshot) (toolScopeDigest input.binding) (Just input.position)
      OperationId key = specification.operationId
      reference = Attempt.JobReference 1 snapshot.executionId specification.operationId (AttemptId ("tool:" <> key))
  void (right =<< run env (Execution.acceptOperation access state.revision specification (Aeson.toJSON input)))
  (_, accepted) <- right =<< run env (Execution.loadExecution access)
  awakeable <- UUID.nextRandom
  run env (runTransaction (registerAwakeableTx awakeable "shikigami.execution" (executionWorkflowId snapshot.executionId).unWorkflowId))
  let submission = Attempt.AttemptSubmission (Execution.toolAttemptRequest reference.attemptId reference.operationId input.binding) Nothing (Attempt.ExecutionWake (AwakeableId awakeable) 0)
  void (right =<< run env (Execution.submitExecutionAttemptWith access accepted.revision submission (\_ -> pure ())))
  pure (Prepared snapshot reference)

executePrepared :: AppEnv -> ActionAuthorizer -> (ExecutionSnapshot -> IO (Either Text.Text ())) -> ProcessClient -> Prepared -> IO ()
executePrepared env authorizer current client prepared = do
  executeGitWithBackend nativeGitBackend env authorizer current client prepared

executeGitWithBackend :: GitBackend -> AppEnv -> ActionAuthorizer -> (ExecutionSnapshot -> IO (Either Text.Text ())) -> ProcessClient -> Prepared -> IO ()
executeGitWithBackend backend env authorizer current client prepared = do
  let file = fileRuntime env authorizer current
      providers = must (installDurableAdapters [supervisedWorkspaceEditAdapter file, workspaceExecAdapter client, workspaceGitAdapterWithBackend backend file, transferredWorkspaceEditAdapter file, transferredWorkspaceExecAdapter client, transferredWorkspaceGitAdapterWithBackend backend file, workspaceIntegrationAdapterWithBackend backend file] emptyCapabilityProviderRegistry)
      runtime = Executor.ExecutionRuntime env (\_ -> current prepared.snapshot) current (\_ -> error "fixture does not dispatch a model") (Tools.withExecutionTools Log.silentLogger authorizer providers native) 5
  result <- Executor.executeAcceptedAttempt runtime prepared.snapshot.identity prepared.reference
  unless (result == Right Executor.ExecutorDone) (fail "fixture execution did not finish its delivery")

fileRuntime :: AppEnv -> ActionAuthorizer -> (ExecutionSnapshot -> IO (Either Text.Text ())) -> FileRuntime
fileRuntime env authorizer current = FileRuntime env authorizer current current (\_ _ _ _ _ -> pure (Right ()))

registry :: FileRuntime -> ProcessClient -> CapabilityProviderRegistry
registry file client = must (installDurableAdapters [supervisedWorkspaceEditAdapter file, workspaceExecAdapter client, workspaceGitAdapter file] emptyCapabilityProviderRegistry)

native :: Tools.NativeToolFactory
native = Tools.NativeToolFactory (\_ -> pure (Right [])) (\_ _ _ -> pure (Right []))

policyDigest :: ExecutionSnapshot -> Text.Text
policyDigest snapshot = versionedDigest "shikigami.harness-policy/1" (Aeson.toJSON snapshot.policy)

run :: AppEnv -> Eff AppEffects a -> IO a
run env action = right =<< runAppIO env action

right :: (HasCallStack) => Either e a -> IO a
right = either (const (fail ("accepted fixture boundary refused\n" <> prettyCallStack callStack))) pure

must :: Either e a -> a
must = either (const (error "fixture definition refused")) id

-- Transfer-aware qualification uses real protected model/tool inputs and actual
-- claims. This helper never invents session/objective ownership authority.
prepareTools :: AppEnv -> ActionAuthorizer -> (ExecutionSnapshot -> IO (Either Text.Text ())) -> ProcessClient -> WorkspaceAdmission -> [(Text.Text, Aeson.Value)] -> IO Prepared
prepareTools env authorizer current client admission calls = do
  now <- getCurrentTime
  session <- genSessionId
  selection <- right (resolveExecutionSelection admission.assignmentId (must (modelCatalog [])) (defaultBinding stubModel emptyOptions) Nothing Nothing Nothing Nothing (Just admission.rootId) now)
  let file = fileRuntime env authorizer current
      adapters = [transferredWorkspaceEditAdapter file, transferredWorkspaceExecAdapter client, transferredWorkspaceGitAdapter file, workspaceIntegrationAdapter file]
      providers = must (installDurableAdapters adapters emptyCapabilityProviderRegistry)
      descriptors = map (.descriptor) adapters
  catalog <- right (mkCapabilityCatalog descriptors)
  capabilities <- right (resolveGovernedCapabilityOverlays (durableAdapterInstalled providers) catalog (\_ _ -> Right ()) (ResolutionSubject (Just "fixture") Durable (Skill "fixture") Nothing) (map (.capability) descriptors))
  let initial = ExecutionSnapshot 1 (executionIdFor admission.assignmentId) admission.runId (AgentName "fixture") admission.owner session selection Nothing (SkillInstructions "fixture" "system" "body") (ReplayContext 2 (Just (instructionPrompt admission.instructions)) [RequestTurn [TextBlock "qualified workspace operation"] Nothing]) capabilities (Aeson.toJSON ([] :: [Aeson.Value])) defaultHarnessPolicy [] (Just admission)
  menu <- right =<< Tools.describeExecutionTools Log.silentLogger authorizer providers native initial
  let snapshot = initial & #offeredTools .~ menu.offeredTools & #toolBindings .~ menu.toolBindings
  void (right =<< run env Catalog.registerProjectionCatalog)
  void (right =<< run env (Execution.admitExecution snapshot))
  appendTools env current snapshot calls

continueTools :: AppEnv -> (ExecutionSnapshot -> IO (Either Text.Text ())) -> Prepared -> [(Text.Text, Aeson.Value)] -> IO Prepared
continueTools env current prepared = appendTools env current prepared.snapshot

appendTools :: AppEnv -> (ExecutionSnapshot -> IO (Either Text.Text ())) -> ExecutionSnapshot -> [(Text.Text, Aeson.Value)] -> IO Prepared
appendTools env current snapshot calls = do
  unless (not (null calls)) (fail "empty accepted fixture tools")
  access <- right =<< run env (Execution.authorizeReplay snapshot.executionId snapshot.identity (current snapshot))
  (_, state) <- right =<< run env (Execution.loadExecution access)
  unless (state.next == NeedModel) (fail "fixture did not reach model boundary")
  let invocations = [ToolInvocation ("fixture-call-" <> Text.pack (show index)) name input | (index, (name, input)) <- zip [0 :: Int ..] calls]
      assistant = ReplayAssistant 1 (map ToolBlock invocations) ToolUse Nothing Nothing (Aeson.object []) Nothing
      model = OperationSpec (operationIdFor snapshot.executionId state.cursor) ModelTurn RepeatableObservation "model" (policyDigest snapshot) "fixture-model" Nothing
  (_, operation) <- right =<< run env (Execution.acceptOperation access state.revision model (Aeson.object []))
  now <- getCurrentTime
  let OperationId key = operation.specification.operationId
      request = Resources.AttemptRequest (AttemptId ("model:" <> key)) operation.specification.operationId (Map.fromList [(Resources.ActiveWork, 1), (Resources.ModelAttempts, 1), (Resources.Tokens, 10), (Resources.CostMicroUsd, 0)]) Resources.EnforcedCeiling
  reserved <- right =<< run env (Calls.reserveSelectionCall snapshot.selection (Calls.CallLimits Nothing Nothing Nothing Nothing Nothing) request "fixture-model" now)
  call <- case reserved of Calls.NewCall value -> pure value; _ -> fail "expected new fixture call"
  let outcome = ModelReturned assistant Nothing
  response <- right (Execution.outcomeReference outcome)
  (_, accepted) <- right =<< run env (Execution.loadExecution access)
  void (right =<< run env (Execution.recordOutcomeAndAdvance access accepted.revision operation.specification.operationId outcome (NeedTool response 0) (Just (call, Calls.CallOutcome Calls.CallTerminal (Map.fromList [(Resources.Tokens, 1), (Resources.CostMicroUsd, 0)]) [] Nothing Nothing Nothing))))
  nextTool env access snapshot response 0 (head invocations)

advanceTools :: AppEnv -> (ExecutionSnapshot -> IO (Either Text.Text ())) -> Prepared -> IO (Maybe Prepared)
advanceTools env current prepared = do
  access <- right =<< run env (Execution.authorizeReplay prepared.snapshot.executionId prepared.snapshot.identity (current prepared.snapshot))
  (_, state) <- right =<< run env (Execution.loadExecution access)
  case state.next of
    NeedModel -> pure Nothing
    NeedTool response position -> do
      outcome <- right =<< run env (Execution.readReplayPayload @OperationOutcome access "operation-outcome" response)
      case outcome of
        ModelReturned assistant _ -> case take 1 (drop position (toolInvocations assistant)) of
          [invocation] -> Just <$> nextTool env access prepared.snapshot response position invocation
          _ -> fail "retained invocation missing"
        _ -> fail "retained fixture model missing"
    _ -> fail "fixture tool did not settle"

nextTool :: AppEnv -> Execution.ReplayAccess -> ExecutionSnapshot -> PayloadRef -> Int -> ToolInvocation -> IO Prepared
nextTool env access snapshot response position invocation = case filter ((== invocation.name) . (.name)) snapshot.toolBindings of
  [binding] -> submit env snapshot access (ToolOperationInput response position invocation binding)
  _ -> fail "exact retained fixture tool missing"

executeWithProviders :: CapabilityProviderRegistry -> AppEnv -> ActionAuthorizer -> (ExecutionSnapshot -> IO (Either Text.Text ())) -> Prepared -> IO ()
executeWithProviders providers env authorizer current prepared = do
  let runtime = Executor.ExecutionRuntime env (\_ -> current prepared.snapshot) current (\_ -> error "fixture does not dispatch a model") (Tools.withExecutionTools Log.silentLogger authorizer providers native) 5
  result <- Executor.executeAcceptedAttempt runtime prepared.snapshot.identity prepared.reference
  unless (result == Right Executor.ExecutorDone) (fail "configured fixture delivery did not finish")
