module Shikigami.Agent.Command.AgentRun
  ( runAgentRun,
  )
where

import Data.Aeson ((.=))
import Data.Aeson qualified as Aeson
import Data.Aeson.KeyMap qualified as KeyMap
import Data.ByteString.Lazy qualified as LazyByteString
import Data.List (isInfixOf, isSuffixOf)
import Data.Text (Text)
import Data.Text qualified as Text
import Data.Text.Encoding qualified as TE
import Data.Text.IO qualified as TIO
import Data.Time (getCurrentTime)
import Hasql.Pool qualified
import Keiro.Workflow (WorkflowId (..), WorkflowOutcome (..))
import Kioku.Id (idText)
import Kiroku.Store.Connection (KirokuStore (..), withStore)
import Shikigami.Activity (ActivityEnvelope)
import Shikigami.Agent.Approval qualified as Approval
import Shikigami.Agent.Approval.Workflow qualified as ApprovalWorkflow
import Shikigami.Agent.Decl (AgentDecl (..), Behavior (CoordinatingSkill, Skill))
import Shikigami.Agent.Loader (AgentLoadEntry (..), AgentLoadReport (..), loadAgent)
import Shikigami.Agent.Name (agentNameText)
import Shikigami.Agent.Payload (readPayloadArgument)
import Shikigami.Agent.Principal (compatibilityIdentity)
import Shikigami.Agent.Run (AgentRunResult (..), recordActivityAsMemory, renderMemoryRecord)
import Shikigami.Agent.Run.Key (newCliRunKey)
import Shikigami.Agent.RunJob (RunJob (..), RunRouteKind (AgentWorkflowRoute), TriggerKind (TriggeredByEvent), runJobWorkflowId)
import Shikigami.Agent.Trust (WorkspaceArgument, compatibilityPrincipal, lightComposition, parseWorkspaceArgument, terminalInteraction, workspaceSelector)
import Shikigami.Agent.Workflow qualified as AgentWorkflow
import Shikigami.App (AppEnv (..), noopTracer)
import Shikigami.App.Config (AppConfig)
import Shikigami.App.Config qualified as Config
import Shikigami.App.Config.Load (requireDatabaseUrl)
import Shikigami.Attestation.Resolve qualified as Profile
import Shikigami.Behavior.Provider (newBehaviorEnvFor)
import Shikigami.Directory (disabledDirectoryHandle)
import Shikigami.Execution.Driver (ExecutionStart (..))
import Shikigami.Execution.Foreground (driveExecutionForeground)
import Shikigami.Execution.SelectionRuntime (assignmentIdFor)
import Shikigami.Execution.Transcript (executionIdFor)
import Shikigami.Flow.Decision qualified as FlowDecision
import Shikigami.Flow.Initiative qualified as FlowInitiative
import Shikigami.Flow.Observe qualified as FlowObserve
import Shikigami.Flow.Routing qualified as Routing
import Shikigami.Log qualified as Log
import Shikigami.Migrations (verifyShikigamiMigrations)
import Shikigami.PracticeReview.Capability qualified as PracticeReviewCapability
import Shikigami.Record (KindFilter (..), RecordEvent (..), RecordQuery (..), mkRecordLimit, observedRecord, postgresRecord, readRecord, recordEntry, recordErrorText)
import Shikigami.Repository (repositoryIdText)
import Shikigami.Runtime (registerRuntimeCatalog, runtimeConnectionSettings)
import Shikigami.Sink (DanwaConfig (..), GrantSource (DbGrants), KanmonConfig (..), KawaConfig (..), KizashiConfig (..), ReiConfig (..))
import Shikigami.Sink.Http (HttpLimits (..), credentialsFromConfig, newSinkHttp)
import Shikigami.Trigger.Enqueue (ensureRunQueue)
import Shikigami.Trust.LocalOperator.Grant (Interaction)
import Shikigami.Trust.Runtime (RunSubject (..), TierComposition (..), TierRuntime (..), renderTierRefusal)
import System.Exit (exitFailure)
import System.IO (hPutStrLn, stderr)

-- | @agent-run --agent <name|path> [--from-activity <file>]@: open the kioku store and
-- either run the durable agent workflow (open session → recall → run behavior →
-- record learning → complete) and print the across-run report, or — with
-- @--from-activity@ — map an @activity.v1@ envelope into a memory under the agent
-- scope. The connection string comes from @database.connection_string@, which the
-- development shell still supplies as @PG_CONNECTION_STRING@.
runAgentRun :: String -> Maybe FilePath -> Maybe String -> Maybe String -> Bool -> AppConfig -> IO ()
runAgentRun agentArg mActivity workspace payloadArgument noConfirm config = do
  logger <- Log.newStderrLogger Log.Info
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
            interaction <- terminalInteraction noConfirm
            runDurableAgent logger store appEnv (parseWorkspaceArgument <$> workspace) triggerPayload interaction config decl

runDurableAgent :: Log.Logger -> KirokuStore -> AppEnv -> Maybe WorkspaceArgument -> Aeson.Value -> Interaction -> AppConfig -> AgentDecl -> IO ()
runDurableAgent logger KirokuStore {pool} appEnv workspace triggerPayload interaction config decl = do
  occurredAt <- getCurrentTime
  freshKey <- newCliRunKey ((.name) decl)
  let job =
        RunJob
          { agentName = ((.name) decl),
            identity = compatibilityIdentity ((.name) decl),
            triggerKind = TriggeredByEvent,
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
            routeKind = AgentWorkflowRoute
          }
      record = observedRecord logger Nothing (postgresRecord pool)
      subject =
        RunSubject
          { agent = decl,
            principal = compatibilityPrincipal decl.name,
            run = Just (runJobWorkflowId job),
            repository = workspaceSelector <$> workspace
          }
  -- Resolve the run's ports before any model call: a refused grant, an
  -- unavailable repository or an undeliverable output stops here.
  tierRuntime <- (lightComposition config interaction record).resolve subject >>= either (dieAgentRun . renderTierRefusal) pure
  behEnv <- newBehaviorEnvFor logger ((.behaviorProvider) config) Nothing
  let capabilities = tierRuntime.capabilities
      kizashiConfig =
        KizashiConfig
          { baseUrl = (.kizashiBaseUrl) config,
            defaultRecipient = (.kizashiDefaultRecipient) config
          }
      kawaConfig =
        KawaConfig
          { baseUrl = (.kawaBaseUrl) config,
            sourceSegment = (.kawaSourceSegment) config
          }
      kanmonConfig = KanmonConfig {baseUrl = (.kanmonBaseUrl) config}
      danwaConfig =
        DanwaConfig
          { baseUrl = (.danwaBaseUrl) config,
            agentParticipant = (.danwaAgentParticipant) config
          }
      httpLimits =
        HttpLimits
          { requestBytes = (.httpRequestMaxBytes) config,
            responseBytes = (.httpResponseMaxBytes) config
          }
  sinkHttp <-
    newSinkHttp httpLimits (credentialsFromConfig config) danwaConfig >>= \case
      Left err -> dieAgentRun ("invalid sink HTTP configuration: " <> Text.pack (show err))
      Right clients -> pure clients
  let deps =
        AgentWorkflow.AgentRunDeps
          { AgentWorkflow.appEnv = appEnv,
            AgentWorkflow.behaviorEnv = behEnv,
            AgentWorkflow.decisions = FlowDecision.defaultDecisionServices (either (error . show) id config.decisionModelCatalog),
            AgentWorkflow.actionAuthority = tierRuntime.authority,
            AgentWorkflow.capabilities = capabilities,
            AgentWorkflow.coordination = Nothing,
            AgentWorkflow.objectives = Nothing,
            AgentWorkflow.initiatives = FlowInitiative.disabledInitiatives,
            AgentWorkflow.observe = FlowObserve.disabledObserve,
            AgentWorkflow.workspace = Nothing,
            AgentWorkflow.agents = [decl],
            AgentWorkflow.kizashi = kizashiConfig,
            AgentWorkflow.kawa = kawaConfig,
            AgentWorkflow.kanmon = kanmonConfig,
            AgentWorkflow.danwa = danwaConfig,
            AgentWorkflow.rei = ReiConfig {baseUrl = (.reiBaseUrl) config},
            AgentWorkflow.http = sinkHttp,
            AgentWorkflow.hooks = AgentWorkflow.defaultAgentRunHooks,
            AgentWorkflow.approvalPolicy = Approval.autoApprovePolicy ((.approvalDeadline) config),
            AgentWorkflow.approvalWorkflow = ApprovalWorkflow.defaultApprovalWorkflowEnv,
            AgentWorkflow.runTimeout = (.runTimeout) config,
            AgentWorkflow.harness = (.harness) config,
            AgentWorkflow.delegationBudget = (.delegationBudget) config,
            AgentWorkflow.grants = DbGrants pool,
            AgentWorkflow.directory = disabledDirectoryHandle,
            AgentWorkflow.routing =
              Routing.routingRuntime
                (AgentLoadReport [AgentLoaded {path = "<agent-run>", declaration = decl}])
                disabledDirectoryHandle,
            AgentWorkflow.practiceReview = PracticeReviewCapability.unavailablePracticeReviewRuntime,
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
        Right Suspended -> do
          Log.logInfo logger "execution.durable.accepted" ["workflowId" .= (runJobWorkflowId job).unWorkflowId]
          putStrLn "Agent run accepted; a durable wake is pending."
        Right Cancelled -> dieAgentRun "workflow was cancelled"
        Right Failed -> dieAgentRun "workflow journal carries a terminal failure"
        Right ContinuedAsNew -> dieAgentRun "parent advance requires a worker resume"
  initial <- runParent
  case initial of
    Right Suspended | eligible -> do
      -- The parent has released its workflow lease. Only its accepted child
      -- can perform local work, through the same fenced executor as a worker.
      result <- driveExecutionForeground (AgentWorkflow.executionRuntime deps) (ExecutionStart execution) 10000
      case result of
        Right (Just _) -> runParent >>= finish
        Right Nothing -> finish initial
        Left err -> dieAgentRun ("accepted execution requires recovery: " <> Text.pack (show err))
    _ -> finish initial

-- | Under the local operator, name the repository, the run and its record.
reportLocalRun :: Hasql.Pool.Pool -> TierRuntime -> RunJob -> IO ()
reportLocalRun pool tierRuntime job = case tierRuntime.grant of
  Nothing -> pure ()
  Just grant -> do
    let runId = runJobWorkflowId job
    TIO.putStrLn ("local-operator: repository " <> repositoryIdText grant.repository <> " (" <> Text.pack grant.source <> ")")
    events <- readRecord pool RecordQuery {run = Just runId, kinds = KindPrefix "authority.decided", limit = maxLimit}
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
