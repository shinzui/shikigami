-- Native accepted-adapter qualification. Production configured policy and host
-- select every allocation/profile; this fixture supplies deterministic model
-- replies and no objective ownership receipts.
module Qualification (Qualification (..), Ready (..), withQualification, loadAssignment, runTools, executeConfigured, resultValue, run, right, integrationCase) where

import Accepted
import Baikai.Options (emptyOptions)
import Control.Concurrent (threadDelay)
import Control.Monad (forM, unless, void, when)
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
import Effectful (Eff)
import FixtureIdentity (fixtureRootId)
import GHC.Generics (Generic)
import GHC.Stack (HasCallStack, callStack, prettyCallStack)
import Kioku.Id (genSessionId)
import Kiroku.Store.Connection (KirokuStore (..), defaultConnectionSettings, withStore)
import Kiroku.Store.Transaction (runTransaction)
import Shikigami.Action.Authorization (ActionAuthorizer)
import Shikigami.Action.Authorization.Config (buildConfiguredActionAuthorizer)
import Shikigami.Agent.Name (AgentName, mkAgentName)
import Shikigami.Agent.Principal (AgentIdentity, identityText)
import Shikigami.App (AppEffects, AppEnv (..), noopTracer, runAppIO)
import Shikigami.App.Config (AppConfig (..), Role (AdminRole), revealSecretText)
import Shikigami.App.Config.Load (ConfigOptions (..), DiagnosticMode (NoDiagnostic), requireDatabaseUrl, runAppConfig)
import Shikigami.Behavior.Skill (SkillDir (..))
import Shikigami.Behavior.StubProvider (stubModel)
import Shikigami.Capability.Overlay (emptyResolvedCapabilitySet)
import Shikigami.Capability.Provider (CapabilityRuntime (..))
import Shikigami.Decision.ModelCatalog (modelCatalog)
import Shikigami.Directory (DirectoryRuntime (..), identityLifecycleAdmission, startDirectory)
import Shikigami.Execution.Attempt (JobReference (..))
import Shikigami.Execution.Identity
import Shikigami.Execution.Policy.Types
import Shikigami.Execution.Resources qualified as Resources
import Shikigami.Execution.ResourcesStore qualified as Roots
import Shikigami.Execution.Runner (OperationContext (..))
import Shikigami.Execution.Selection
import Shikigami.Execution.SelectionRuntime (assignmentIdFor)
import Shikigami.Execution.Start (SkillAssignment (..))
import Shikigami.Execution.Store qualified as Execution
import Shikigami.Execution.Transcript
import Shikigami.Log qualified as Log
import Shikigami.Workspace.Admission (WorkspaceHost (..))
import Shikigami.Workspace.Allocation
import Shikigami.Workspace.ConfiguredHost
import Shikigami.Workspace.GitObjects qualified as Objects
import Shikigami.Workspace.GitStore qualified as Git
import Shikigami.Workspace.GitTypes
import Shikigami.Workspace.Instructions
import Shikigami.Workspace.Integration qualified as Integration
import Shikigami.Workspace.Process
import Shikigami.Workspace.ProcessPolicy
import Shikigami.Workspace.ProcessProvider (ProcessClient (..))
import Shikigami.Workspace.Provider (Replacement (..), contentDigest)
import Shikigami.Workspace.Settings
import Shikigami.Workspace.Store qualified as Store
import Shikigami.Workspace.Types
import System.Directory (doesFileExist)
import System.FilePath ((</>))
import System.Process (readProcess)

data Ready = Ready {binding :: !WorkspaceBinding, admission :: !WorkspaceAdmission, profile :: !ProcessProfile}
  deriving stock (Generic)
  deriving anyclass (Aeson.FromJSON)

data Qualification = Qualification
  { env :: !AppEnv,
    authorizer :: !ActionAuthorizer,
    current :: !(ExecutionSnapshot -> IO (Either Text.Text ())),
    lifecycle :: !(AgentIdentity -> IO (Either Text.Text ())),
    client :: !ProcessClient,
    host :: !WorkspaceHost,
    initial :: !Ready,
    prefix :: !FilePath
  }

withQualification :: FilePath -> FilePath -> (Qualification -> IO a) -> IO a
withQualification configFile prefix use = do
  initial <- right . Aeson.eitherDecodeStrict @Ready =<< Bytes.readFile (prefix </> "native-ready.json")
  config <- runAppConfig AdminRole (ConfigOptions [configFile] [] [] NoDiagnostic)
  connection <- revealSecretText <$> requireDatabaseUrl "workspace-qualification" config
  tracer <- noopTracer
  let env = AppEnv {connectionSettings = defaultConnectionSettings connection, tracer, metrics = Nothing, store = Nothing}
  authorizer <- right =<< buildConfiguredActionAuthorizer Log.silentLogger config
  directory <- right =<< startDirectory Log.silentLogger config.directorySettings
  socket <- maybe (fail "qualification socket absent") (pure . (.socketPath)) config.workspaceSupervisorSettings
  principal <- right (identityText initial.binding.request.owner)
  withStore env.connectionSettings \store -> do
    let repository = WorkspaceRepository initial.binding.repository initial.binding.source [WorkspaceRevision initial.binding.base (bundleDigest initial.admission.instructions)] initial.binding.base "qualification-reviewed" initial.profile.policy.readPaths initial.profile.policy.writePaths
        process = WorkspaceProcessSettings socket 0 5 60 (IdentityRange 64000 64031) (Map.singleton repository.identity initial.profile.policy)
        settings = WorkspaceSettings initial.binding.storageRoot [repository] [WorkspaceGrant "fixture" principal repository.identity Nothing] (Just process)
        client = ProcessClient socket 0 5 60
        current = identityLifecycleAdmission directory.handle . (.identity)
    host <- right (configuredWorkspaceHostWithTransfers env store.pool directory.handle authorizer settings)
    use (Qualification env authorizer current (identityLifecycleAdmission directory.handle) client host initial prefix)

loadAssignment :: Qualification -> ExecutionRootId -> Text.Text -> AgentIdentity -> IO WorkspaceAdmission
loadAssignment q root runId owner = do
  now <- getCurrentTime
  session <- genSessionId
  selection <- right (resolveExecutionSelection (assignmentIdFor runId) (either (error . show) id (modelCatalog [])) (defaultBinding stubModel emptyOptions) Nothing Nothing Nothing Nothing (Just root) now)
  let assignment = SkillAssignment runId (fixtureAgentName "fixture") owner session selection Nothing emptyResolvedCapabilitySet (Right defaultHarnessPolicy) (SkillDir "fixture") (fail "host cannot dispatch a model")
  let awaitAdmission remaining = do
        result <- q.host.load assignment
        case result of
          Right admitted -> pure admitted
          Left _ | remaining > (0 :: Int) -> threadDelay 100000 >> awaitAdmission (remaining - 1)
          _ -> right result
  -- The independent receipt scanner shares this lock. Retry only the same
  -- authoritative child; a busy lock never supplies admission or a new copy.
  awaitAdmission 30

runTools :: Qualification -> Prepared -> IO (Prepared, [Aeson.Value])
runTools q first = loop first []
  where
    loop prepared previous = do
      Just operation <- right =<< run q.env (Execution.inspectOperation prepared.reference.operationId)
      when (operation.specification.name == executionCoordinate "overlay__workspace-exec__validate") do
        clock <- doesFileExist "/run/shikigami-workspace-prototype.clock-steps"
        when clock (void (readProcess "/usr/bin/timeout" ["40", q.prefix </> "root/bin/probe", "--await-clock-step"] ""))
      executeConfigured q prepared
      output <- resultValue q prepared
      next <- advanceTools q.env q.current prepared
      case next of Nothing -> pure (prepared, reverse (output : previous)); Just value -> loop value (output : previous)

resultValue :: Qualification -> Prepared -> IO Aeson.Value
resultValue q prepared = do
  access <- right =<< run q.env (Execution.authorizeReplay prepared.snapshot.executionId prepared.snapshot.identity (q.current prepared.snapshot))
  Just operation <- right =<< run q.env (Execution.inspectOperation prepared.reference.operationId)
  result <- maybe (fail "qualification result missing") pure operation.outcome
  outcome <- right =<< run q.env (Execution.readReplayPayload @OperationOutcome access "operation-outcome" result)
  case outcome of
    RichToolReturned output | not (toolFailed output.failed) -> case output.blocks of [TextBlock text] -> right (Aeson.eitherDecodeStrict (Encoding.encodeUtf8 text)); _ -> fail "qualification JSON absent"
    _ -> fail "qualification operation refused"

integrationCase :: FilePath -> FilePath -> IO ()
integrationCase config prefix = withQualification config prefix \q -> do
  let root = fixtureRootId "integration-qualification-root"
      owner = q.initial.binding.request.owner
      edit path before after = ("overlay__workspace-edit__replace", Aeson.toJSON (Replacement path (Just (contentDigest before)) after))
      validate = ("overlay__workspace-exec__validate", Aeson.object ["rule" Aeson..= ("validate" :: Text.Text)])
  now <- getCurrentTime
  void (right =<< run q.env (Roots.enrollRoot root (Resources.Envelope (Map.fromList [(dimension, Resources.ExplicitlyUnbounded) | dimension <- [minBound .. maxBound]]) (addUTCTime 3600 now))))
  artifacts <- forM [("one", "a", "1\n"), ("two", "b", "1\n"), ("three", "a", "2\n"), ("four", "c", "1\n")] \(name, path, value) -> do
    admission <- loadAssignment q root ("integration-worker-" <> name) owner
    prepared <- prepareTools q.env q.authorizer q.current q.client admission [edit "src/dependency.txt" "old dependency\n" "new dependency\n", edit ("src/integration-" <> path) "0\n" value, validate, ("overlay__workspace-git__commit", Aeson.toJSON (GitCommitRequest q.initial.binding.base ("Worker " <> name)))]
    (lastTool, outputs) <- runTools q prepared
    receipt <- right (Aeson.fromJSON (outputs !! 2) `asEither` ())
    unless (successful receipt) (fail "worker-local validation failed")
    Just (binding, record) <- right =<< run q.env (runTransaction (Git.inspectRegisteredGitTx lastTool.reference.operationId))
    candidate <- maybe (fail "worker artifact missing") pure record.candidate
    unless (record.phase == GitApplied) (fail "worker artifact not applied")
    pure (Integration.Artifact record.operation.operationId (workspaceBindingDigest binding) binding.base candidate.result)
  let pair indexes = [artifacts !! index | index <- indexes]
      plan name selected = do
        admission <- loadAssignment q root ("integration-target-" <> name) owner
        prepared <- prepareTools q.env q.authorizer q.current q.client admission [("overlay__workspace-integrate__plan", Aeson.toJSON (Integration.Request q.initial.binding.base selected))]
        (lastTool, outputs) <- runTools q prepared
        Just (binding, _) <- right =<< run q.env (runTransaction (Store.inspectWorkspaceTx admission.workspace))
        Objects.readHead (workspaceMetadata binding.storageRoot binding) >>= \value -> unless (value == Right binding.base) (fail "planning changed HEAD")
        output <- case outputs of [value] -> pure value; _ -> fail "expected one integration proposal"
        pure (binding, lastTool, output)
  (target, proposed, proposal) <- plan "success" (pair [0, 3])
  field "conflicts" proposal >>= \value -> unless (value == Aeson.toJSON ([] :: [Text.Text])) (fail "unexpected integration conflict")
  replacements <- right . (`asEither` ()) . Aeson.fromJSON =<< field "replacements" proposal
  apply <- continueTools q.env q.current proposed (map (\replacement -> ("overlay__workspace-edit__replace", Aeson.toJSON (replacement :: Replacement))) replacements <> [validate, ("overlay__workspace-git__commit", Aeson.toJSON (GitCommitRequest target.base "Integrate exact worker artifacts"))])
  (committed, results) <- runTools q apply
  receipt <- right (Aeson.fromJSON (results !! length replacements) `asEither` ())
  unless (successful receipt) (fail "combined validation failed")
  Just (_, committedRecord) <- right =<< run q.env (runTransaction (Git.inspectRegisteredGitTx committed.reference.operationId))
  candidate <- maybe (fail "combined commit absent") pure committedRecord.candidate
  field "tree" proposal >>= \tree -> unless (tree == Aeson.toJSON candidate.tree) (fail "validated commit differs from planned combined tree")
  putStrLn "PASS two exact worker commits integrate, validate and commit in a third configured workspace"
  (_, _, conflict) <- plan "conflict" (pair [0, 2])
  field "conflicts" conflict >>= \value -> unless (value == Aeson.toJSON ["src/integration-a" :: Text.Text]) (fail "overlap conflict not reported")
  putStrLn "PASS overlapping exact worker artifacts report conflicts without publishing files or HEAD"
  (failedTarget, failurePlan, failureProposal) <- plan "validation-failure" (pair [0, 1])
  failureReplacements <- right . (`asEither` ()) . Aeson.fromJSON =<< field "replacements" failureProposal
  failedApply <- continueTools q.env q.current failurePlan (map (\replacement -> ("overlay__workspace-edit__replace", Aeson.toJSON (replacement :: Replacement))) failureReplacements <> [validate])
  (_, failures) <- runTools q failedApply
  failedReceipt <- right (Aeson.fromJSON @ProcessReceipt (last failures) `asEither` ())
  unless (failedReceipt.termination == ProcessExited && failedReceipt.exitCode == Just 77 && failedReceipt.descendantsEmpty && failedReceipt.outputComplete) (fail "combined-only failure not retained")
  Objects.readHead (workspaceMetadata failedTarget.storageRoot failedTarget) >>= \value -> unless (value == Right failedTarget.base) (fail "failed integration published a commit")
  putStrLn "PASS successful worker-local validations do not conceal a failing exact combined tree"
  let evidence = Aeson.object ["artifacts" Aeson..= artifacts, "combined" Aeson..= candidate, "validation" Aeson..= receipt, "combinedFailure" Aeson..= failedReceipt]
  Lazy.writeFile (prefix </> "integration-evidence.json") (Aeson.encode evidence)

successful :: ProcessReceipt -> Bool
successful receipt = receipt.termination == ProcessExited && receipt.exitCode == Just 0 && receipt.descendantsEmpty && receipt.outputComplete

field :: Aeson.Key -> Aeson.Value -> IO Aeson.Value
field name (Aeson.Object fields) = maybe (fail "qualification evidence field missing") pure (KeyMap.lookup name fields)
field _ _ = fail "qualification evidence object missing"

asEither :: Aeson.Result a -> () -> Either String a
asEither (Aeson.Success value) _ = Right value
asEither (Aeson.Error err) _ = Left err

run :: AppEnv -> Eff AppEffects a -> IO a
run env action = right =<< runAppIO env action

right :: (HasCallStack) => Either e a -> IO a
right = either (const (fail ("qualification boundary refused\n" <> prettyCallStack callStack))) pure

executeConfigured :: Qualification -> Prepared -> IO ()
executeConfigured q = executeWithProviders q.host.capabilities.providers q.env q.authorizer q.current

fixtureAgentName :: Text -> AgentName
fixtureAgentName = either (error . show) id . mkAgentName
