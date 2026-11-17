module Shikigami.Agent.Command.AgentRun
  ( runAgentRun,
  )
where

import Baikai.Options qualified as Options
import Control.Exception (finally)
import Control.Monad (void)
import Data.Aeson ((.=))
import Data.Aeson qualified as Aeson
import Data.Aeson.KeyMap qualified as KeyMap
import Data.ByteString.Lazy qualified as LazyByteString
import Data.Either (rights)
import Data.Functor ((<&>))
import Data.List (isInfixOf, isSuffixOf)
import Data.Map.Strict qualified as Map
import Data.Maybe (isJust)
import Data.Set qualified as Set
import Data.Text (Text)
import Data.Text qualified as Text
import Data.Text.Encoding qualified as TE
import Data.Text.IO qualified as TIO
import Data.Time (UTCTime, addUTCTime, getCurrentTime)
import Hasql.Pool qualified
import Keiro.Workflow (StepName (..), WorkflowId (..), WorkflowOutcome (..), loadStepIndex)
import Keiro.Workflow.Child (runChildWorkflow)
import Kioku.Id (idText)
import Kiroku.Store.Connection (KirokuStore (..), withStore)
import Kiroku.Store.Effect (runStoreIO)
import Kiroku.Store.Error (StoreError)
import Shikigami.Activity (ActivityEnvelope)
import Shikigami.Agent.Approval qualified as Approval
import Shikigami.Agent.Approval.LocalInbox (PendingApproval (..), listPendingApprovals, localInboxDirectory, localInboxNotifier)
import Shikigami.Agent.Approval.Workflow (approvalWorkflow, approvalWorkflowName)
import Shikigami.Agent.Approval.Workflow qualified as ApprovalWorkflow
import Shikigami.Agent.Decl (AgentDecl (..), Behavior (CoordinatingSkill, Skill))
import Shikigami.Agent.Loader (AgentLoadEntry (..), AgentLoadReport (..), loadAgent)
import Shikigami.Agent.Name (agentNameText)
import Shikigami.Agent.Payload (readPayloadArgument)
import Shikigami.Agent.Principal (compatibilityIdentity)
import Shikigami.Agent.Run (AgentRunResult (..), recordActivityAsMemory, renderMemoryRecord)
import Shikigami.Agent.Run.Key (newCliRunKey)
import Shikigami.Agent.RunJob (RunJob (..), RunRouteKind (AgentWorkflowRoute), TriggerKind (TriggeredByOperator), runJobWorkflowId)
import Shikigami.Agent.Trust (WorkspaceArgument (..), compatibilityPrincipal, lightComposition, parseWorkspaceArgument, terminalInteraction, workspaceArgumentText, workspaceSelector)
import Shikigami.Agent.Workflow qualified as AgentWorkflow
import Shikigami.Agent.Workflow.Name (agentRunWorkflowName, ingestJobStepName)
import Shikigami.App (AppEnv (..), noopTracer, runAppIO)
import Shikigami.App.Config (AppConfig)
import Shikigami.App.Config qualified as Config
import Shikigami.App.Config.Load (requireDatabaseUrl)
import Shikigami.Attestation.Resolve qualified as Profile
import Shikigami.Authority (mkOutputKind)
import Shikigami.Behavior.Provider (newBehaviorEnvFor)
import Shikigami.Behavior.Run (withProgramTasks)
import Shikigami.CodingAgent.Types (renderOutcome)
import Shikigami.CodingAgent.Workflow (codingAgentStepWorkflow, codingAgentStepWorkflowName, fixedCodingAgentRunner)
import Shikigami.DeclaredTool.Workflow (declaredToolStepWorkflow, declaredToolStepWorkflowName, renderToolStepOutcome)
import Shikigami.Directory (disabledDirectoryHandle)
import Shikigami.Execution.Admission (enrollRootRun)
import Shikigami.Execution.Driver (ExecutionStart (..))
import Shikigami.Execution.Foreground (driveExecutionForeground)
import Shikigami.Execution.Quantity (parseResourceAmount)
import Shikigami.Execution.Resources (Dimension (..), Envelope (..), Limit (..))
import Shikigami.Execution.SelectionRuntime (assignmentIdFor)
import Shikigami.Execution.Transcript (executionIdFor)
import Shikigami.Flow.Builtin (builtinPack)
import Shikigami.Flow.Pack qualified as FlowPack
import Shikigami.Flow.Routing qualified as Routing
import Shikigami.Log qualified as Log
import Shikigami.Migrations (verifyShikigamiMigrations)
import Shikigami.Output (OutputReceipt (..))
import Shikigami.Output.Registration (AdapterContext (..), OutputRegistration, buildOutputRegistry)
import Shikigami.Record (KindFilter (..), RecordEvent (..), RecordQuery (..), mkRecordLimit, observedRecord, postgresRecord, readRecord, recordEntry, recordErrorText)
import Shikigami.Repository (repositoryIdText)
import Shikigami.Runtime (registerRuntimeCatalog, runtimeConnectionSettings)
import Shikigami.Sink (GrantSource (DbGrants))
import Shikigami.Sink.Http (HttpLimits (..))
import Shikigami.Trigger.Enqueue (ensureRunQueue)
import Shikigami.Trust.LocalOperator.Approvals (Budget (..))
import Shikigami.Trust.LocalOperator.Grant (Interaction, defaultStateDirectory)
import Shikigami.Trust.Runtime (RunSubject (..), TierComposition (..), TierRuntime (..), renderTierRefusal)
import Shikigami.Trust.Tier (TrustTier (LocalOperator))
import Shikigami.Workflow.Versioning (shikigamiWorkflowRunOptions)
import System.Directory (makeAbsolute)
import System.Exit (exitFailure)
import System.IO (hPutStrLn, stderr)

-- | @agent-run --agent <name|path> [--from-activity <file>]@: open the kioku store and
-- either run the durable agent workflow (open session → recall → run behavior →
-- record learning → complete) and print the across-run report, or — with
-- @--from-activity@ — map an @activity.v1@ envelope into a memory under the agent
-- scope. The connection string comes from @database.connection_string@, which the
-- development shell still supplies as @PG_CONNECTION_STRING@.
runAgentRun :: [FlowPack.FlowPack] -> String -> Maybe FilePath -> Maybe String -> Maybe String -> Bool -> Maybe Text -> AppConfig -> IO ()
runAgentRun packs agentArg mActivity workspace payloadArgument noConfirm resume config = do
  logger <- Log.newStderrLogger Log.Info
  flows <- FlowPack.composeFlowRegistryOrExit logger "shikigami-agent-run" (builtinPack : packs)
  let path = resolvePath agentArg
  declE <- loadAgent path
  case declE of
    Left err -> do
      hPutStrLn stderr ("agent-run: load error in " <> path <> ": " <> show err)
      exitFailure
    Right decl -> do
      connStr <- Config.revealSecretText <$> requireDatabaseUrl "shikigami-agent-run" config
      verifyShikigamiMigrations connStr
      tr <- noopTracer
      let settings = runtimeConnectionSettings logger Nothing connStr
      withStore settings $ \store -> do
        registerRuntimeCatalog store
        let appEnv = AppEnv {connectionSettings = settings, tracer = tr, metrics = Nothing, store = Just store}
        case mActivity of
          Just actPath -> do
            decoded <- Aeson.eitherDecodeFileStrict' actPath
            case decoded :: Either String ActivityEnvelope of
              Left e -> do
                hPutStrLn stderr ("agent-run: cannot decode activity " <> actPath <> ": " <> e)
                exitFailure
              Right env -> do
                recE <- recordActivityAsMemory appEnv decl env
                case recE of
                  Left e -> hPutStrLn stderr ("agent-run: " <> Text.unpack e) >> exitFailure
                  Right m -> putStrLn ("recorded activity memory " <> Text.unpack (idText m))
          Nothing -> do
            supplied <- readPayloadArgument payloadArgument
            triggerPayload <- case supplied of
              Nothing -> pure Aeson.Null
              Just raw -> maybe (dieAgentRun "payload input is not valid JSON") pure (Aeson.decodeStrict (TE.encodeUtf8 (Text.pack raw)))
            -- Refused before a session opens: a manifest naming a flow this
            -- executable was not composed with can never run here.
            case FlowPack.flowDeclarationErrors flows decl of
              [] -> pure ()
              problems -> dieAgentRun (Text.intercalate "; " problems)
            interaction <- terminalInteraction noConfirm
            runDurableAgent flows (concatMap (.outputs) packs) logger store appEnv (parseWorkspaceArgument <$> workspace) triggerPayload interaction config decl resume

runDurableAgent :: FlowPack.FlowRegistry -> [OutputRegistration] -> Log.Logger -> KirokuStore -> AppEnv -> Maybe WorkspaceArgument -> Aeson.Value -> Interaction -> AppConfig -> AgentDecl -> Maybe Text -> IO ()
runDurableAgent flows outputRegistrations logger store@KirokuStore {pool} appEnv workspace triggerPayload interaction config decl resume = do
  occurredAt <- getCurrentTime
  freshKey <- newCliRunKey ((.name) decl)
  -- With --resume, the run is the journaled job of an earlier invocation: the
  -- same workflow id replays its journal, so completed steps are read back and
  -- an interrupted coding-agent attempt is reattached, never relaunched.
  journaled <- traverse (journaledJob store decl) resume
  -- The run journals the repository it was given, as an absolute path or a
  -- Mori identity, so a resume (or a worker) finds the same one.
  given <- traverse absoluteWorkspace workspace
  let named = maybe (parseWorkspaceArgument . Text.unpack <$> (journaled >>= (.repository))) Just given
  let fresh =
        RunJob
          { agentName = ((.name) decl),
            identity = compatibilityIdentity ((.name) decl),
            triggerKind = TriggeredByOperator,
            occurredAt,
            triggerPayload,
            idempotencyKey = freshKey,
            parentSessionId = Nothing,
            parentRunWorkflowId = Nothing,
            delegationDepth = Nothing,
            lineage = [],
            executionRequest = Nothing,
            executionPermissions = Nothing,
            executionRootId = Nothing,
            delegationBudgetId = Nothing,
            objective = Nothing,
            routeKind = AgentWorkflowRoute,
            repository = workspaceArgumentText <$> given
          }
      unrooted = maybe fresh id journaled
      record = observedRecord logger Nothing (postgresRecord pool)
      subject =
        RunSubject
          { agent = decl,
            principal = compatibilityPrincipal decl.name,
            run = Just (runJobWorkflowId unrooted),
            repository = workspaceSelector <$> named
          }
  -- Outside the local tier a run's outputs are enqueued through the adapters
  -- the composed packs register, for a worker's publisher (plan 135, M3).
  let httpLimits =
        HttpLimits
          { requestBytes = (.httpRequestMaxBytes) config,
            responseBytes = (.httpResponseMaxBytes) config
          }
  organization <-
    buildOutputRegistry AdapterContext {logger, settings = config.packSettings, httpLimits} [] outputRegistrations config.defaultOutputKind
      >>= either (\problem -> dieAgentRun ("invalid outputs: " <> problem)) pure
  -- Resolve the run's ports before any model call: a refused grant, an
  -- unavailable repository or an undeliverable output stops here.
  tierRuntime <- (lightComposition config organization interaction record).resolve subject >>= either (dieAgentRun . renderTierRefusal) pure
  -- A run that may mutate the repository spends under a resource root sized by
  -- its grant's budget (K5).
  job <- case (journaled, tierRuntime.workspace, tierRuntime.grant) of
    (Just resumed, _, _) -> pure resumed
    (Nothing, Just _, Just grant) -> do
      now <- getCurrentTime
      enrolled <- runAppIO appEnv (enrollRootRun (grantEnvelope now (boundsTokens config) grant.budget) unrooted)
      case enrolled of
        Right (Right rooted) -> pure rooted
        Right (Left problem) -> dieAgentRun ("the run's resource root was refused: " <> Text.pack (show problem))
        Left problem -> dieAgentRun ("the run's resource root is unavailable: " <> Text.pack (show problem))
    _ -> pure unrooted
  -- Under the local operator, an output that needs approval asks through the
  -- local inbox (EP-8 M2).
  stateDirectory <- maybe defaultStateDirectory pure config.localOperatorStateDirectory
  let localTier = config.trustTier == LocalOperator
      approvalPolicy
        | localTier = Approval.ApprovalPolicySnapshot {requireFor = Set.fromList (rights (mkOutputKind <$> config.approvalRequiredOutputs)), channel = Approval.localInboxChannel, deadline = config.approvalDeadline}
        | otherwise = Approval.autoApprovePolicy ((.approvalDeadline) config)
      approvalEnv
        | localTier = ApprovalWorkflow.ApprovalWorkflowEnv {notifier = localInboxNotifier (localInboxDirectory stateDirectory)}
        | otherwise = ApprovalWorkflow.defaultApprovalWorkflowEnv
  behEnv <- withProgramTasks (FlowPack.lookupTask flows) <$> newBehaviorEnvFor logger ((.behaviorProvider) config) Nothing
  let capabilities = tierRuntime.capabilities
      deps =
        AgentWorkflow.AgentRunDeps
          { AgentWorkflow.appEnv = appEnv,
            AgentWorkflow.behaviorEnv = behEnv,
            AgentWorkflow.decisions = FlowPack.decisionServices flows (either (error . show) id config.decisionModelCatalog),
            AgentWorkflow.flows = flows,
            AgentWorkflow.actionAuthority = tierRuntime.authority,
            AgentWorkflow.capabilities = capabilities,
            AgentWorkflow.coordination = Nothing,
            AgentWorkflow.objectives = Nothing,
            AgentWorkflow.packMetrics = const FlowPack.noPackMetrics,
            AgentWorkflow.workspaceCatalog = [],
            AgentWorkflow.workspace = tierRuntime.workspace,
            AgentWorkflow.agents = [decl],
            AgentWorkflow.hooks = AgentWorkflow.defaultAgentRunHooks,
            AgentWorkflow.codingAgents = tierRuntime.codingAgents,
            AgentWorkflow.outputs = tierRuntime.outputs,
            AgentWorkflow.declaredTools = tierRuntime.declaredTools,
            AgentWorkflow.approvalPolicy = approvalPolicy,
            AgentWorkflow.approvalWorkflow = approvalEnv,
            AgentWorkflow.runTimeout = (.runTimeout) config,
            AgentWorkflow.harness = (.harness) config,
            AgentWorkflow.delegationBudget = (.delegationBudget) config,
            AgentWorkflow.grants = DbGrants pool,
            AgentWorkflow.directory = disabledDirectoryHandle,
            AgentWorkflow.routing =
              Routing.routingRuntime
                (AgentLoadReport [AgentLoaded {path = "<agent-run>", declaration = decl}])
                disabledDirectoryHandle,
            AgentWorkflow.packSettings = config.packSettings,
            AgentWorkflow.deliveryPool = Just pool,
            AgentWorkflow.logger = logger,
            AgentWorkflow.resolveRunProfile = \profileId version -> do
              now <- getCurrentTime
              Profile.resolveProfile (Profile.postgresProfileStore pool) now profileId version
          }
  ensureRunQueue pool >>= either (dieAgentRun . Text.pack . show) pure
  let runParent = AgentWorkflow.runAgentRunWorkflow deps job
      eligible = case decl of AgentDecl {behavior = Skill {}, delegates = [], routing = Nothing} -> True; AgentDecl {behavior = CoordinatingSkill {}, routing = Nothing} -> True; _ -> False
      execution = executionIdFor (assignmentIdFor (runJobWorkflowId job).unWorkflowId)
      finish = \case
        Left err -> dieAgentRun ("workflow store failure: " <> Text.pack (show err))
        Right (Completed (Left failure)) -> dieAgentRun (AgentWorkflow.agentRunFailureDetail failure)
        Right (Completed (Right result)) -> do
          renderRunResult decl result
          reportLocalRun pool tierRuntime job
          reportOutputs appEnv job
        Right Suspended -> do
          Log.logInfo logger "execution.durable.accepted" ["workflowId" .= (runJobWorkflowId job).unWorkflowId]
          putStrLn "Agent run accepted; a durable wake is pending."
        Right Cancelled -> dieAgentRun "workflow was cancelled"
        Right Failed -> dieAgentRun "workflow journal carries a terminal failure"
        Right ContinuedAsNew -> dieAgentRun "parent advance requires a worker resume"
  let drivePending :: Int -> Either StoreError (WorkflowOutcome (Either AgentWorkflow.AgentRunFailure AgentRunResult)) -> IO ()
      drivePending budget current
        | budget <= 0 = finish current
        | otherwise = do
            progressed <- foregroundChildren appEnv deps job
            mapM_ (\(_, outcome) -> either (const (pure ())) (mapM_ TIO.putStrLn) outcome) progressed
            case [problem | (_, Left problem) <- progressed] of
              problem : _ -> dieAgentRun problem
              []
                | any (\(_, outcome) -> outcome /= Right Nothing) progressed ->
                    runParent >>= \case
                      next@(Right Suspended) -> drivePending (budget - 1) next
                      next -> finish next
                | otherwise -> do
                    -- Every pending child waits on the operator.
                    pendingAsks <- listPendingApprovals (localInboxDirectory stateDirectory)
                    TIO.putStrLn ("Run " <> (runJobWorkflowId job).unWorkflowId <> " waits for approval:")
                    mapM_ (\pendingAsk -> TIO.putStrLn ("  shikigami-local approvals resolve " <> pendingAsk.reviewId <> "    # " <> pendingAsk.prompt)) pendingAsks
                    TIO.putStrLn ("then: shikigami-agent-run --agent <the same declaration> --resume " <> (runJobWorkflowId job).unWorkflowId)
  (`finally` tierRuntime.release) do
    initial <- runParent
    case initial of
      -- The parent awaits a child (a coding-agent step or an approval): this
      -- command drives each pending child in the foreground and resumes the
      -- parent while that makes progress. An approval waits for the operator.
      Right Suspended | not eligible -> drivePending 8 initial
      Right Suspended | eligible -> do
        -- The parent has released its workflow lease. Only its accepted child
        -- can perform local work, through the same fenced executor as a worker.
        result <- driveExecutionForeground (AgentWorkflow.executionRuntime deps) (ExecutionStart execution) 10000
        case result of
          Right (Just _) ->
            runParent >>= \case
              -- After the behavior, an output may still wait on an approval.
              next@(Right Suspended) -> drivePending 8 next
              next -> finish next
          Right Nothing -> finish initial
          Left err -> dieAgentRun ("accepted execution requires recovery: " <> Text.pack (show err))
      _ -> finish initial

-- | Drive the parent's pending children and resume it until it finishes or
-- waits on the operator.
foregroundChildren ::
  AppEnv ->
  AgentWorkflow.AgentRunDeps ->
  RunJob ->
  IO [(Text, Either Text (Maybe Text))]
foregroundChildren appEnv deps job = do
  let parent = runJobWorkflowId job
  steps <- runAppIO appEnv (loadStepIndex agentRunWorkflowName parent 0)
  let journal = either (const Map.empty) id steps
      pending =
        [ child
        | key <- Map.keys journal,
          Just child <- [Text.stripPrefix "child:" key],
          not (":result" `Text.isSuffixOf` child),
          not (Map.member ("child:" <> child <> ":result") journal)
        ]
      options = shikigamiWorkflowRunOptions appEnv
  traverse
    ( \child ->
        if ":declared-tool:" `Text.isInfixOf` child
          then
            runAppIO appEnv (runChildWorkflow options declaredToolStepWorkflowName (WorkflowId child) (declaredToolStepWorkflow deps.declaredTools Nothing)) <&> \case
              Right (Completed outcome) -> (child, Right (Just ("declared-tool: " <> renderToolStepOutcome outcome)))
              Right Suspended -> (child, Right Nothing)
              Right other -> (child, Left ("the declared-tool step did not finish: " <> Text.pack (show (void other))))
              Left problem -> (child, Left (Text.pack (show problem)))
          else
            if ":coding-agent:" `Text.isInfixOf` child
              then
                runAppIO appEnv (runChildWorkflow options codingAgentStepWorkflowName (WorkflowId child) (codingAgentStepWorkflow deps.codingAgents Nothing)) <&> \case
                  Right (Completed outcome) -> (child, Right (Just ("coding-agent: " <> renderOutcome outcome)))
                  Right Suspended -> (child, Right Nothing)
                  Right other -> (child, Left ("the coding-agent step did not finish: " <> Text.pack (show (void other))))
                  Left problem -> (child, Left (Text.pack (show problem)))
              else
                runAppIO appEnv (runChildWorkflow options approvalWorkflowName (WorkflowId child) (approvalWorkflow deps.approvalWorkflow Nothing)) <&> \case
                  Right (Completed _) -> (child, Right (Just ("approval " <> child <> " resolved")))
                  Right Suspended -> (child, Right Nothing)
                  Right other -> (child, Left ("the approval did not finish: " <> Text.pack (show (void other))))
                  Left problem -> (child, Left (Text.pack (show problem)))
    )
    pending

absoluteWorkspace :: WorkspaceArgument -> IO WorkspaceArgument
absoluteWorkspace = \case
  WorkspacePath path -> WorkspacePath <$> makeAbsolute path
  named -> pure named

-- | The job journaled by an earlier invocation of this one-off run. One-off
-- runs never continue as new, so the job is in generation 0.
journaledJob :: KirokuStore -> AgentDecl -> Text -> IO RunJob
journaledJob store decl workflowId = do
  steps <- runStoreIO store (loadStepIndex agentRunWorkflowName (WorkflowId workflowId) 0)
  case steps of
    Left problem -> dieAgentRun ("cannot read run " <> workflowId <> ": " <> Text.pack (show problem))
    Right journal -> case Map.lookup ingestJob journal of
      Nothing -> dieAgentRun ("no agent run " <> workflowId <> " has been journaled")
      Just value -> case Aeson.fromJSON value of
        Aeson.Error problem -> dieAgentRun ("run " <> workflowId <> " has an unreadable job: " <> Text.pack problem)
        Aeson.Success job
          | job.agentName /= decl.name -> dieAgentRun ("run " <> workflowId <> " belongs to agent " <> agentNameText job.agentName <> ", not " <> agentNameText decl.name)
          | (runJobWorkflowId job).unWorkflowId /= workflowId -> dieAgentRun ("run " <> workflowId <> " journals another run's job")
          | otherwise -> pure job
  where
    StepName ingestJob = ingestJobStepName

-- | The resource envelope of a local run: the grant's attempts, one active
-- unit of work, no descendants, cost unbounded (no provider reports it), and
-- a cutoff the grant's minutes from now. Tokens are bounded only when
-- @behavior.options.max_tokens@ is configured, because a finite token bound
-- reserves each attempt's output plus its whole context window; otherwise the
-- attempts and the cutoff bound the run and usage is recorded as unknown.
grantEnvelope :: UTCTime -> Bool -> Budget -> Envelope
grantEnvelope now finiteTokens Budget {modelAttempts, toolAttempts, tokens, minutes} =
  Envelope
    { limits =
        Map.fromList
          [ (ActiveWork, amount 1),
            (LifetimeDescendants, amount 0),
            (ModelAttempts, amount (fromIntegral modelAttempts)),
            (ToolAttempts, amount (fromIntegral toolAttempts)),
            (Tokens, if finiteTokens then amount (fromIntegral tokens) else ExplicitlyUnbounded),
            (CostMicroUsd, ExplicitlyUnbounded)
          ],
      cutoff = addUTCTime (fromIntegral (minutes * 60)) now
    }
  where
    amount n = either (error . Text.unpack) Limited (parseResourceAmount n)

-- | Whether the configured model call names an output-token ceiling.
boundsTokens :: AppConfig -> Bool
boundsTokens config = case config.behaviorProvider of
  Config.UseHttp _ options _ -> isJust (Options.maxTokens options)
  _ -> False

-- | Under the local operator, name the repository, the run and its record.
-- | Where the run's outputs went: each delivery receipt journaled by
-- @deliver-outputs@, or that the result stayed in the journal (EP-8 M2).
reportOutputs :: AppEnv -> RunJob -> IO ()
reportOutputs appEnv job = do
  steps <- runAppIO appEnv (loadStepIndex agentRunWorkflowName (runJobWorkflowId job) 0)
  let journal = either (const Map.empty) id steps
  case Map.lookup "deliver-outputs" journal of
    Nothing -> TIO.putStrLn "report  none (the result is in the journal)"
    Just value -> case Aeson.fromJSON value of
      Aeson.Success (receipts :: [Either Text OutputReceipt]) ->
        mapM_ (either (\problem -> TIO.putStrLn ("report  failed: " <> problem)) (\receipt -> TIO.putStrLn ("report  " <> receipt.location))) receipts
      Aeson.Error _ -> TIO.putStrLn "report  unreadable delivery receipt"

reportLocalRun :: Hasql.Pool.Pool -> TierRuntime -> RunJob -> IO ()
reportLocalRun pool tierRuntime job = case tierRuntime.grant of
  Nothing -> pure ()
  Just grant -> do
    let runId = runJobWorkflowId job
    TIO.putStrLn ("local-operator: repository " <> repositoryIdText grant.repository <> " (" <> Text.pack grant.source <> ")")
    events <- readRecord pool RecordQuery {run = Just runId, kinds = KindPrefix "authority.decided", limit = maxLimit}
    commits <- readRecord pool RecordQuery {run = Just runId, kinds = KindPrefix "commit.created", limit = maxLimit}
    opened <- readRecord pool RecordQuery {run = Just runId, kinds = KindPrefix "workspace.opened", limit = maxLimit}
    mapM_ (\event -> TIO.putStrLn ("local-operator: worktree " <> field "root" event <> " on " <> field "branch" event <> " from " <> Text.take 7 (field "base" event))) (either (const []) id opened)
    mapM_ (\event -> TIO.putStrLn ("local-operator: commit " <> Text.take 7 (field "commit" event) <> " on " <> field "branch" event)) (either (const []) id commits)
    case events of
      Left problem -> TIO.putStrLn ("local-operator: record unavailable: " <> recordErrorText problem)
      Right decided -> do
        let refused = length (filter refusal decided)
        TIO.putStrLn
          ( "local-operator: record "
              <> Text.pack (show (length decided - refused))
              <> " approved, "
              <> Text.pack (show refused)
              <> " refused — shikigami-local ledger --run "
              <> runId.unWorkflowId
          )
  where
    maxLimit = either (error . Text.unpack) id (mkRecordLimit 1000)
    refusal RecordEvent {entry} = case snd (recordEntry entry) of
      Aeson.Object fields -> KeyMap.lookup "decision" fields /= Just (Aeson.String "allowed")
      _ -> True
    field name RecordEvent {entry} = case snd (recordEntry entry) of
      Aeson.Object fields | Just (Aeson.String value) <- KeyMap.lookup name fields -> value
      _ -> "?"

renderRunResult :: AgentDecl -> AgentRunResult -> IO ()
renderRunResult decl result = do
  putStrLn ("agent " <> show (agentNameText ((.name) decl)) <> " run " <> Text.unpack (idText ((.sessionId) result)))
  putStrLn ("recalled " <> show (length ((.recalledPrior) result)) <> " prior memories:")
  mapM_ (TIO.putStrLn . ("  - " <>) . renderMemoryRecord) ((.recalledPrior) result)
  maybe
    (pure ())
    (\memoryId -> putStrLn ("recorded learning " <> Text.unpack (idText memoryId)))
    ((.recordedMemId) result)
  -- The behavior's answer, so the operator can read what the agent did.
  case result.behaviorOutput of
    Aeson.Object fields | Just (Aeson.String reply) <- KeyMap.lookup "reply" fields -> TIO.putStrLn ("reply:\n" <> reply)
    Aeson.Null -> pure ()
    other -> TIO.putStrLn ("output: " <> TE.decodeUtf8Lenient (LazyByteString.toStrict (Aeson.encode other)))

dieAgentRun :: Text -> IO a
dieAgentRun detail = do
  hPutStrLn stderr ("agent-run: " <> Text.unpack detail)
  exitFailure

-- | A bare agent name resolves to @agents/<name>.dhall@; anything that already looks
-- like a path (contains @/@ or ends in @.dhall@) is used as-is.
resolvePath :: String -> FilePath
resolvePath arg
  | ".dhall" `isSuffixOf` arg = arg
  | "/" `isInfixOf` arg = arg
  | otherwise = "agents/" <> arg <> ".dhall"
