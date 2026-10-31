-- Normal agent parent/child qualification with the production configured host.
-- Every model request is derived from retained context, so a process restart
-- cannot reset a fixture counter and accidentally issue another mutation.
module Durable (workflowCase) where

import Baikai.Content qualified as Content
import Baikai.Context qualified as Context
import Baikai.Message qualified as Message
import Baikai.Provider.Registry qualified as Provider
import Baikai.StopReason (StopReason (ToolUse))
import Baikai.Stream (liftCompleteToStream)
import Control.Monad (unless, void)
import Data.Aeson qualified as Aeson
import Data.Aeson.KeyMap qualified as KeyMap
import Data.ByteString qualified as Bytes
import Data.ByteString.Lazy qualified as Lazy
import Data.Generics.Labels ()
import Data.Map.Strict qualified as Map
import Data.Text (Text)
import Data.Text qualified as Text
import Data.Text.Encoding qualified as Encoding
import Data.Time (addUTCTime, getCurrentTime)
import Data.Vector qualified as Vector
import Effectful (Eff)
import FixtureIdentity (fixtureRootId)
import GHC.Generics (Generic)
import Keiro.Workflow (WorkflowId (..), WorkflowOutcome (..), loadStepIndex)
import Kiroku.Store.Connection (KirokuStore (..), defaultConnectionSettings, withStore)
import Kiroku.Store.Transaction (runTransaction)
import Shikigami.Action.Authorization.Config (buildConfiguredActionAuthorizer)
import Shikigami.Agent.Approval (autoApprovePolicy)
import Shikigami.Agent.Approval.Workflow qualified as Approval
import Shikigami.Agent.Decl
import Shikigami.Agent.Loader (loadAgent)
import Shikigami.Agent.Name (AgentName, mkAgentName)
import Shikigami.Agent.Principal (identityText)
import Shikigami.Agent.Run.Key (RunKey, parseRunKey)
import Shikigami.Agent.RunJob
import Shikigami.Agent.Workflow qualified as Agent
import Shikigami.App (AppEffects, AppEnv (..), noopTracer, runAppIO)
import Shikigami.App.Config (AppConfig (..), Role (AdminRole), revealSecretText)
import Shikigami.App.Config.Load (ConfigOptions (..), DiagnosticMode (NoDiagnostic), requireDatabaseUrl, runAppConfig)
import Shikigami.Attestation.Resolve (ProfileResolutionError (UnknownProfile))
import Shikigami.Behavior.Run (newBehaviorEnv)
import Shikigami.Behavior.StubProvider (stubApiProvider)
import Shikigami.Capability.Overlay (CapabilityDescriptor (..))
import Shikigami.Directory (DirectoryRuntime (..), startDirectory)
import Shikigami.Execution.Driver (ExecutionStart (..))
import Shikigami.Execution.Foreground (driveExecutionForeground)
import Shikigami.Execution.Identity
import Shikigami.Execution.Policy.Types
import Shikigami.Execution.Resources qualified as Resources
import Shikigami.Execution.ResourcesStore qualified as Roots
import Shikigami.Execution.SelectionRuntime (assignmentIdFor)
import Shikigami.Execution.Store qualified as Execution
import Shikigami.Execution.Transcript
import Shikigami.Flow.Decision qualified as Decision
import Shikigami.Flow.Routing qualified as Routing
import Shikigami.Log qualified as Log
import Shikigami.PracticeReview.Capability qualified as Practice
import Shikigami.Prelude ((&), (.~))
import Shikigami.RunEvidence.Catalog qualified as Catalog
import Shikigami.Sink (GrantSource (StaticGrants), defaultGrantTable)
import Shikigami.Sink.Config
import Shikigami.Sink.Http (HttpLimits (..), credentialsFromConfig, newSinkHttp)
import Shikigami.StateRevision (initialRevision, revisionNumber)
import Shikigami.Trigger.Enqueue (ensureRunQueue)
import Shikigami.Workspace.Admission (WorkspaceHost (..))
import Shikigami.Workspace.Allocation
import Shikigami.Workspace.ConfiguredHost
import Shikigami.Workspace.FileProvider
import Shikigami.Workspace.Git (runWorkspaceGit)
import Shikigami.Workspace.GitObjects qualified as Objects
import Shikigami.Workspace.GitProvider (workspaceGitDescriptor)
import Shikigami.Workspace.GitTypes (GitCandidate (..), GitCommitRequest (..))
import Shikigami.Workspace.Instructions
import Shikigami.Workspace.Process
import Shikigami.Workspace.ProcessPolicy hiding (strictOptions)
import Shikigami.Workspace.Provider (Replacement (..), contentDigest)
import Shikigami.Workspace.Settings
import Shikigami.Workspace.Store qualified as Store
import Shikigami.Workspace.Supervisor (workspaceExecDescriptor)
import Shikigami.Workspace.Types
import System.FilePath ((</>))

-- The native provision fixture supplies only approved immutable coordinates.
data Ready = Ready {binding :: !WorkspaceBinding, admission :: !WorkspaceAdmission, profile :: !ProcessProfile}
  deriving stock (Generic)
  deriving anyclass (Aeson.FromJSON)

workflowCase :: FilePath -> FilePath -> String -> IO ()
workflowCase configFile prefix stage = do
  initial <- right . Aeson.eitherDecodeStrict @Ready =<< Bytes.readFile (prefix </> "native-ready.json")
  config <- runAppConfig AdminRole (ConfigOptions [configFile] [] [] NoDiagnostic)
  connection <- revealSecretText <$> requireDatabaseUrl "workspace-workflow-fixture" config
  tracer <- noopTracer
  let env = AppEnv {connectionSettings = defaultConnectionSettings connection, tracer, metrics = Nothing, store = Nothing}
  authorizer <- right =<< buildConfiguredActionAuthorizer Log.silentLogger config
  directory <- right =<< startDirectory Log.silentLogger config.directorySettings
  withStore env.connectionSettings \store -> do
    principal <- right (identityText initial.binding.request.owner)
    socket <- maybe (fail "fixture socket missing") (pure . (.socketPath)) config.workspaceSupervisorSettings
    let repository = WorkspaceRepository initial.binding.repository initial.binding.source [WorkspaceRevision initial.binding.base (bundleDigest initial.admission.instructions)] initial.binding.base "workflow-reviewed" initial.profile.policy.readPaths initial.profile.policy.writePaths
        process = WorkspaceProcessSettings socket 0 5 60 (IdentityRange 64000 64031) (Map.singleton repository.identity initial.profile.policy)
        settings = WorkspaceSettings initial.binding.storageRoot [repository] [WorkspaceGrant "workspace-upgrade" principal repository.identity Nothing] (Just process)
        code = "/var/lib/shikigami-workspace-fixture-code"
        skill = code </> "agents/skills/triage-note"
    host <- right (configuredWorkspaceHost env store.pool directory.handle authorizer settings)
    original <- right =<< loadAgent (code </> "agents/triage-note.dhall")
    base <- newBehaviorEnv
    let complete model context options = do
          unless (maybe False (Text.isInfixOf "Fixture policy: validate the exact resulting tree.") context.systemPrompt) (fail "frozen repository instructions absent")
          let results = [result | Message.ToolResultMessage result <- Vector.toList context.messages]
          unless (all (not . (.isError)) results) (fail "workspace tool refused")
          Bytes.appendFile (prefix </> "workflow-model-calls") "1\n"
          response <- Provider.complete stubApiProvider model context options
          if null results
            then
              pure
                ( response
                    & #message
                    . #stopReason
                    .~ ToolUse
                    & #message
                    . #content
                    .~ Vector.fromList
                      [ Content.AssistantToolCall (Content.ToolCall "upgrade" "overlay__workspace-edit__replace" (Aeson.toJSON (Replacement "src/dependency.txt" (Just (contentDigest "old dependency\n")) "new dependency\n"))),
                        Content.AssistantToolCall (Content.ToolCall "validate" "overlay__workspace-exec__validate" (Aeson.object ["rule" Aeson..= ("validate" :: Text.Text)])),
                        Content.AssistantToolCall (Content.ToolCall "commit" "overlay__workspace-git__commit" (Aeson.toJSON (GitCommitRequest initial.binding.base "chore(deps): upgrade fixture dependency")))
                      ]
                )
            else do
              validation <- resultJson "overlay__workspace-exec__validate" results
              commit <- resultJson "overlay__workspace-git__commit" results
              receipt <- case Aeson.fromJSON @ProcessReceipt validation of Aeson.Success value -> pure value; Aeson.Error err -> fail err
              unless (receipt.termination == ProcessExited && receipt.exitCode == Just 0 && receipt.descendantsEmpty && receipt.outputComplete) (fail "validation was not successful")
              let evidence = Aeson.object ["git" Aeson..= commit, "validation" Aeson..= validation, "summary" Aeson..= ("Upgraded dependency and validated the committed tree." :: Text.Text)]
              pure (response & #message . #content .~ Vector.singleton (Content.AssistantText (Content.TextContent (Encoding.decodeUtf8 (Lazy.toStrict (Aeson.encode evidence))))))
        provider = stubApiProvider {Provider.complete = complete, Provider.stream = liftCompleteToStream complete}
    providers <- Provider.newProviderRegistryFrom [provider]
    now <- getCurrentTime
    http <- right =<< newSinkHttp (HttpLimits config.httpRequestMaxBytes config.httpResponseMaxBytes) (credentialsFromConfig config) (DanwaConfig "http://localhost:1" "fixture")
    let declaration = original & #name .~ fixtureAgentName "workspace-upgrade" & #behavior .~ Skill (Text.pack skill) & #identity .~ Just (IdentityDecl principal) & #capabilityOverlays .~ map (.capability) [supervisedWorkspaceEditDescriptor, workspaceExecDescriptor, workspaceGitDescriptor] & #sinks .~ []
        rootId = fixtureRootId "workflow-upgrade-root"
        job = RunJob (fixtureAgentName "workspace-upgrade") initial.binding.request.owner TriggeredBySchedule now Aeson.Null (fixtureRunKey "workspace-durable-upgrade") Nothing Nothing Nothing [] Nothing Nothing (Just rootId) Nothing AgentWorkflowRoute
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
              harness = defaultHarnessPolicy & #output .~ JsonFields ["git", "validation", "summary"],
              delegationBudget = defaultDelegationBudget,
              grants = StaticGrants defaultGrantTable,
              directory = directory.handle,
              routing = Routing.RoutingRuntime (\_ -> error "no router") (\_ _ _ -> error "no router"),
              practiceReview = Practice.unavailablePracticeReviewRuntime,
              deliveryPool = Nothing,
              logger = Log.silentLogger,
              resolveRunProfile = \profile version -> pure (Left (UnknownProfile profile version))
            }
        execution = executionIdFor (assignmentIdFor (runJobWorkflowId job).unWorkflowId)
        runtime = Agent.executionRuntime deps
        parent = right =<< Agent.runAgentRunWorkflow deps job
        metadata = right =<< run env (Execution.inspectExecution execution)
    void (right =<< run env Catalog.registerProjectionCatalog)
    void (right =<< ensureRunQueue store.pool)
    existing <- run env (Roots.inspectRoot rootId)
    case existing of Left _ -> void (right =<< run env (Roots.enrollRoot rootId (Resources.Envelope (Map.fromList [(dimension, Resources.ExplicitlyUnbounded) | dimension <- [minBound .. maxBound]]) (addUTCTime 3600 now)))); Right _ -> pure ()
    case stage of
      "admit" -> do
        parent >>= suspended
        parent >>= suspended
        Just (state, _, _) <- metadata
        unless (state.cursor == initialRevision) (fail "admission performed an effect")
      "edit" -> do
        parent >>= suspended
        let advance remaining = do
              Just (state, _, _) <- metadata
              if revisionNumber state.cursor >= 2
                then unless (revisionNumber state.cursor == 2) (fail "edit checkpoint overran")
                else do
                  unless (remaining > (0 :: Int)) (fail "edit checkpoint did not advance")
                  void (right =<< driveExecutionForeground runtime (ExecutionStart execution) 1)
                  advance (remaining - 1)
        advance 10
      "run" -> do
        parent >>= suspended
        result <- right =<< driveExecutionForeground runtime (ExecutionStart execution) 100
        unless (maybe False (const True) result) (fail "execution child did not complete")
        parent >>= completed
      "verify" -> do
        first <- parent
        completed first
        second <- parent
        unless (second == first) (fail "duplicate terminal result changed")
        access <- right =<< run env (Execution.authorizeReplay execution job.identity (pure (Right ())))
        (snapshot, state) <- right =<< run env (Execution.loadExecution access)
        admission <- maybe (fail "admitted workspace absent") pure snapshot.workspace
        Just (binding, _) <- right =<< run env (runTransaction (Store.inspectWorkspaceTx admission.workspace))
        unless (admission.filePolicy == Just supervisedFilePolicy) (fail "wrong filesystem profile")
        let metadataPath = workspaceMetadata binding.storageRoot binding
        headId <- right =<< Objects.readHead metadataPath
        count <- right =<< runWorkspaceGit prefix 128 ["--git-dir=" <> metadataPath, "rev-list", "--count", Text.unpack binding.base <> "..HEAD"]
        unless (Text.strip (Encoding.decodeUtf8 count) == "1" && headId /= binding.base) (fail "upgrade did not publish exactly one commit")
        resultRef <- maybe (fail "terminal result absent") pure state.result
        output <- right =<< run env (Execution.readReplayPayload @Aeson.Value access "execution-result" resultRef)
        reply <- field "reply" output
        text <- case reply of Aeson.String value -> pure value; _ -> fail "terminal reply missing"
        evidence <- right (Aeson.eitherDecodeStrict @Aeson.Value (Encoding.encodeUtf8 text))
        git <- field "git" evidence
        candidateValue <- field "commit" git
        exact <- case Aeson.fromJSON @GitCandidate candidateValue of Aeson.Success value -> pure value; Aeson.Error err -> fail err
        unless (exact.result == headId && exact.parent == binding.base && exact.paths == ["src/dependency.txt"]) (fail "terminal Git evidence did not match publication")
        field "instructionDigest" git >>= \value -> unless (value == Aeson.String (bundleDigest admission.instructions)) (fail "instruction identity missing")
        sourceStatus <- right =<< runWorkspaceGit prefix 4096 ["-C", binding.source, "status", "--porcelain"]
        unless (Bytes.null sourceStatus) (fail "source repository changed")
        calls <- Bytes.readFile (prefix </> "workflow-model-calls")
        unless (calls == "1\n1\n") (fail "restart or redelivery repeated model dispatch")
        journal <- run env (loadStepIndex Agent.agentRunWorkflowName (runJobWorkflowId job) 0)
        unless (Map.member "admit-workspace-skill-execution" journal) (fail "normal parent admission missing")
        Lazy.writeFile (prefix </> "workflow-evidence.json") (Aeson.encode evidence)
      _ -> fail "unsupported workflow stage"

resultJson :: Text.Text -> [Message.ToolResultPayload] -> IO Aeson.Value
resultJson name results = case filter ((== name) . (.toolName)) results of
  [result] -> case [value.text | Content.ToolResultText value <- Vector.toList result.content] of
    [body] -> right (Aeson.eitherDecodeStrict (Encoding.encodeUtf8 body))
    _ -> fail "bounded tool JSON missing"
  _ -> fail "exact tool result missing"

field :: Aeson.Key -> Aeson.Value -> IO Aeson.Value
field name (Aeson.Object fields) = maybe (fail "evidence field missing") pure (KeyMap.lookup name fields)
field _ _ = fail "evidence is not an object"

suspended :: (Show e, Show a) => WorkflowOutcome (Either e a) -> IO ()
suspended Suspended = pure ()
suspended other = fail ("parent did not await its child: " <> show other)

completed :: (Show e, Show a) => WorkflowOutcome (Either e a) -> IO ()
completed (Completed (Right _)) = pure ()
completed other = fail ("parent did not complete: " <> show other)

run :: AppEnv -> Eff AppEffects a -> IO a
run env action = right =<< runAppIO env action

right :: (Show e) => Either e a -> IO a
right = either (fail . show) pure

fixtureAgentName :: Text -> AgentName
fixtureAgentName = either (error . show) id . mkAgentName

fixtureRunKey :: Text -> RunKey
fixtureRunKey = either (error . show) id . parseRunKey
