module Shikigami.Agent.Command.AgentRun
  ( runAgentRun,
  )
where

import Data.Aeson qualified as Aeson
import Data.List (isInfixOf, isSuffixOf)
import Data.Text (Text)
import Data.Text qualified as Text
import Data.Text.IO qualified as TIO
import Data.Time (getCurrentTime)
import Keiro.Workflow (WorkflowOutcome (..))
import Kioku.App (AppEnv (..), noopTracer)
import Kioku.Id (genSessionId, idText)
import Kiroku.Store.Connection (KirokuStore (..), withStore)
import Shikigami.Action.Authorization (denyAllActionAuthorizer)
import Shikigami.Activity (ActivityEnvelope)
import Shikigami.Agent.Approval qualified as Approval
import Shikigami.Agent.Approval.Workflow qualified as ApprovalWorkflow
import Shikigami.Agent.Capability.OneOff (oneOffCapabilityRuntime, renderOneOffCapabilityError)
import Shikigami.Agent.Decl (AgentDecl (..))
import Shikigami.Agent.Loader (AgentLoadEntry (..), AgentLoadReport (..), loadAgent)
import Shikigami.Agent.Name (AgentName (..))
import Shikigami.Agent.Principal (compatibilityIdentity)
import Shikigami.Agent.Run (AgentRunResult (..), recordActivityAsMemory, renderMemoryRecord)
import Shikigami.Agent.Run.Key (RunKey (..))
import Shikigami.Agent.RunJob (RunJob (..), RunRouteKind (AgentWorkflowRoute), TriggerKind (TriggeredByEvent))
import Shikigami.Agent.Workflow qualified as AgentWorkflow
import Shikigami.App.Config (AppConfig)
import Shikigami.App.Config qualified as Config
import Shikigami.App.Config.Load (requireDatabaseUrl)
import Shikigami.Attestation.Resolve qualified as Profile
import Shikigami.Behavior.Provider (newBehaviorEnvFor)
import Shikigami.Directory (disabledDirectoryHandle)
import Shikigami.Flow.Decision qualified as FlowDecision
import Shikigami.Flow.Routing qualified as Routing
import Shikigami.Log qualified as Log
import Shikigami.Migrations (verifyShikigamiMigrations)
import Shikigami.PracticeReview.Capability qualified as PracticeReviewCapability
import Shikigami.Runtime (registerRuntimeCatalog, runtimeConnectionSettings)
import Shikigami.Sink (DanwaConfig (..), GrantSource (DbGrants), KanmonConfig (..), KawaConfig (..), KizashiConfig (..), ReiConfig (..))
import Shikigami.Sink.Http (HttpLimits (..), credentialsFromConfig, newSinkHttp)
import System.Exit (exitFailure)
import System.IO (hPutStrLn, stderr)

-- | @agent-run --agent <name|path> [--from-activity <file>]@: open the kioku store and
-- either run the durable agent workflow (open session → recall → run behavior →
-- record learning → complete) and print the across-run report, or — with
-- @--from-activity@ — map an @activity.v1@ envelope into a memory under the agent
-- scope. The connection string comes from @database.connection_string@, which the
-- development shell still supplies as @PG_CONNECTION_STRING@.
runAgentRun :: String -> Maybe FilePath -> Maybe FilePath -> AppConfig -> IO ()
runAgentRun agentArg mActivity workspace config = do
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
        let appEnv = AppEnv {connectionSettings = settings, tracer = tr, metrics = Nothing}
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
          Nothing -> runDurableAgent logger store appEnv workspace config decl

runDurableAgent :: Log.Logger -> KirokuStore -> AppEnv -> Maybe FilePath -> AppConfig -> AgentDecl -> IO ()
runDurableAgent logger KirokuStore {pool} appEnv workspace config decl = do
  behEnv <- newBehaviorEnvFor logger ((.behaviorProvider) config) Nothing
  capabilities <-
    oneOffCapabilityRuntime workspace decl >>= \case
      Left err -> dieAgentRun (renderOneOffCapabilityError err)
      Right runtime -> pure runtime
  let kizashiConfig =
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
  occurredAt <- getCurrentTime
  freshId <- genSessionId
  let job =
        RunJob
          { agentName = AgentName ((.name) decl),
            identity = compatibilityIdentity ((.name) decl),
            triggerKind = TriggeredByEvent,
            occurredAt,
            triggerPayload = Aeson.Null,
            idempotencyKey = RunKey ((.name) decl <> ":cli:" <> idText freshId),
            parentSessionId = Nothing,
            parentRunWorkflowId = Nothing,
            delegationDepth = Nothing,
            lineage = [],
            delegationBudgetId = Nothing,
            routeKind = AgentWorkflowRoute
          }
      deps =
        AgentWorkflow.AgentRunDeps
          { AgentWorkflow.appEnv = appEnv,
            AgentWorkflow.behaviorEnv = behEnv,
            AgentWorkflow.decisions = FlowDecision.defaultDecisionServices (either (error . show) id config.decisionModelCatalog),
            AgentWorkflow.actionAuthorizer = denyAllActionAuthorizer,
            AgentWorkflow.capabilities = capabilities,
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
  AgentWorkflow.runAgentRunWorkflow deps job >>= \case
    Left err -> dieAgentRun ("workflow store failure: " <> Text.pack (show err))
    Right (Completed (Left failure)) -> dieAgentRun (AgentWorkflow.agentRunFailureDetail failure)
    Right (Completed (Right result)) -> renderRunResult decl result
    Right Suspended -> dieAgentRun "workflow suspended; a worker must resume it after its wake condition"
    Right Cancelled -> dieAgentRun "workflow was cancelled"
    Right Failed -> dieAgentRun "workflow journal carries a terminal failure"
    Right ContinuedAsNew -> dieAgentRun "workflow continued as new; a worker must resume its next generation"

renderRunResult :: AgentDecl -> AgentRunResult -> IO ()
renderRunResult decl result = do
  putStrLn ("agent " <> show ((.name) decl) <> " run " <> Text.unpack (idText ((.sessionId) result)))
  putStrLn ("recalled " <> show (length ((.recalledPrior) result)) <> " prior memories:")
  mapM_ (TIO.putStrLn . ("  - " <>) . renderMemoryRecord) ((.recalledPrior) result)
  maybe
    (pure ())
    (\memoryId -> putStrLn ("recorded learning " <> Text.unpack (idText memoryId)))
    ((.recordedMemId) result)

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
