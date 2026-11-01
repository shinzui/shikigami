-- Fixture-only executable: never installed in the production runtime. All paths,
-- credentials, repositories and identities below belong to a disposable guest.
module Main (main) where

import Accepted (Prepared (..), advanceUpgrade, executeGitWithBackend, executePrepared, prepareAccepted, prepareUpgrade)
import Auth.Biscuit (toPublic)
import Continuing (continuingCase)
import Control.Concurrent (threadDelay)
import Control.Exception (IOException, SomeException, catch, fromException, throwIO)
import Control.Monad (unless, void)
import Data.Aeson qualified as Aeson
import Data.ByteString qualified as Bytes
import Data.ByteString.Lazy qualified as Lazy
import Data.Generics.Labels ()
import Data.IORef (newIORef, readIORef, writeIORef)
import Data.Map.Strict qualified as Map
import Data.Text qualified as AssignmentText
import Data.Text qualified as Text
import Data.Text.Encoding qualified as Encoding
import Data.Time (addUTCTime, getCurrentTime)
import Data.Time.Clock.POSIX (posixSecondsToUTCTime, utcTimeToPOSIXSeconds)
import Durable (workflowCase)
import Effectful (Eff)
import En.Biscuit.Grant qualified as Grant
import En.Biscuit.Keys (parseSigningKeyText, renderIssuerKeySetText, singleKey)
import En.Biscuit.Mint (MintConfig (..), MintedGrant (..), mintObjectGrantWithExpiry)
import En.Check (CheckDecision (Allowed))
import En.Revision qualified as En
import En.Schema (ObjectType (..), RelationName (..))
import En.Tuple (ObjectRef (..), Subject (SubjectId))
import FixtureIdentity (fixtureOperationId, fixtureRootId)
import GHC.Generics (Generic)
import GHC.Stack (HasCallStack, callStack, prettyCallStack)
import Hasql.Transaction (Transaction)
import Keiro.Workflow.Types (WorkflowId (..))
import Kikan.En.Action qualified as Kikan
import Kiroku.Store.Connection (defaultConnectionSettings)
import Kiroku.Store.Transaction (runTransaction)
import Network.HTTP.Types (status200, status403, status404)
import Network.Wai (Application, pathInfo, requestHeaders, responseLBS, strictRequestBody)
import Network.Wai.Handler.Warp (defaultSettings, runSettings, setHost, setPort)
import Qualification (integrationCase)
import Shikigami.Action.Authorization (ActionAuthorizer)
import Shikigami.Action.Authorization.Config (buildConfiguredActionAuthorizer)
import Shikigami.Agent.Principal (AgentIdentity (VerifiedIdentity), identityText, mkAgentPrincipal)
import Shikigami.App (AppEffects, AppEnv (..), noopTracer, runAppIO)
import Shikigami.App.Config (AppConfig (..), Role (AdminRole), revealSecretText)
import Shikigami.App.Config.Load (ConfigOptions (..), DiagnosticMode (NoDiagnostic), requireDatabaseUrl, runAppConfig)
import Shikigami.Decision.Contract (versionedDigest)
import Shikigami.Directory (DirectoryRuntime (..), identityLifecycleAdmission, startDirectory)
import Shikigami.Execution.AssignmentKey (AssignmentKey, parseAssignmentKey)
import Shikigami.Execution.Attempt qualified as Attempt
import Shikigami.Execution.Counter (noAttempts)
import Shikigami.Execution.Identity (ExecutionRootId, OperationId)
import Shikigami.Execution.Resources qualified as Resources
import Shikigami.Execution.ResourcesStore qualified as Roots
import Shikigami.Execution.Store qualified as Execution
import Shikigami.Execution.Transcript (ExecutionSnapshot (..), ExecutionState (..), operationIdFor)
import Shikigami.Log qualified as Log
import Shikigami.Prelude ((&), (.~))
import Shikigami.Repository (RepositoryId (..))
import Shikigami.StateRevision (StateRevision, parseRevision)
import Shikigami.Workspace.Allocation
import Shikigami.Workspace.Catalog
import Shikigami.Workspace.ContainedFile (withWorkspaceLock)
import Shikigami.Workspace.Git (runWorkspaceGit)
import Shikigami.Workspace.GitObjects qualified as GitObjects
import Shikigami.Workspace.GitProvider
import Shikigami.Workspace.GitStore qualified as Git
import Shikigami.Workspace.GitTypes
import Shikigami.Workspace.InstructionLoader (loadWorkspaceAdmission)
import Shikigami.Workspace.Instructions
import Shikigami.Workspace.Process
import Shikigami.Workspace.ProcessPolicy
import Shikigami.Workspace.ProcessProfileStore
import Shikigami.Workspace.ProcessProvider
import Shikigami.Workspace.ProcessStore qualified as Processes
import Shikigami.Workspace.Provision
import Shikigami.Workspace.Rpc (ProcessView (..), RpcReply (..), RpcRequest (..), callRpc)
import Shikigami.Workspace.Settings (WorkspaceSupervisorSettings (..))
import Shikigami.Workspace.Store qualified as Workspaces
import Shikigami.Workspace.Supervisor (SupervisorRequest (..))
import Shikigami.Workspace.Systemd qualified as Systemd
import Shikigami.Workspace.Types
import Shikigami.Workspace.Value
import System.Directory (createDirectory, doesFileExist)
import System.Environment (getArgs)
import System.Exit (exitFailure)
import System.FilePath ((</>))
import System.IO.Error (ioeGetErrorString)
import System.Process (readProcess)
import Text.Read (readMaybe)

data NativeSpec = NativeSpec {format :: !Int, directory :: !FilePath, image :: !ProcessImage}
  deriving stock (Generic)

instance Aeson.FromJSON NativeSpec where
  parseJSON = Aeson.genericParseJSON Aeson.defaultOptions {Aeson.rejectUnknownFields = True}

data ReadyProfile = ReadyProfile {binding :: !WorkspaceBinding, admission :: !WorkspaceAdmission, profile :: !ProcessProfile, principal :: !Text.Text}
  deriving stock (Generic)
  deriving anyclass (Aeson.FromJSON)

data PreparedCase = PreparedCase {binding :: !WorkspaceBinding, prepared :: !Prepared}
  deriving stock (Generic)
  deriving anyclass (Aeson.FromJSON, Aeson.ToJSON)

main :: IO ()
main = catch dispatch \(failure :: SomeException) -> do
  -- Own IO failures contain static fixture labels/call sites, never payloads or
  -- authorization responses. Keep other exception representations protected.
  case fromException @IOException failure of
    Just problem -> putStrLn (take 1024 (ioeGetErrorString problem))
    Nothing -> pure ()
  putStrLn "FAIL workspace Linux fixture"
  exitFailure
  where
    dispatch =
      getArgs >>= \case
        ["authority", prefix, port]
          | Just number <- readMaybe port,
            number >= 1024,
            number <= 65535 -> do
              checkPrefix prefix
              authority <- authorityApplication prefix
              runSettings (setHost "127.0.0.1" (setPort number defaultSettings)) authority
        ["continuing", config, prefix, stage] -> checkPrefix prefix >> continuingCase config prefix stage
        ["integration", config, prefix] -> checkPrefix prefix >> integrationCase config prefix
        ["workflow", config, prefix, stage] -> checkPrefix prefix >> workflowCase config prefix stage
        ["native-provision", config, spec] -> nativeProvision config spec
        ["prepare", config, prefix, name, mode] -> prepareCase config prefix name (Text.pack mode)
        ["prepare-upgrade", config, prefix, name] -> prepareCase config prefix name "upgrade"
        ["advance-upgrade", config, prefix, name] -> withCase config prefix name \env _ current _ item -> do
          prepared <- advanceUpgrade env current item.prepared
          Lazy.writeFile (caseFile prefix name) (Aeson.encode (PreparedCase item.binding prepared))
        ["worker", config, prefix, name] -> withCase config prefix name \env authorizer current client item -> executePrepared env authorizer current client item.prepared
        ["worker-git-crash", config, prefix, name] -> withCase config prefix name \env authorizer current client item -> do
          let hook = Bytes.writeFile (prefix </> ("git-published-" <> name)) "1" >> let wait = threadDelay 1000000 >> wait in wait
          executeGitWithBackend (nativeGitBackend & #afterPublication .~ hook) env authorizer current client item.prepared
        ["worker-git-deny", config, prefix, name] -> withCase config prefix name \env authorizer current client item -> do
          let capture binding profile target admit = do
                result <- nativeGitBackend.capture binding profile target admit
                case result of Right _ -> Bytes.writeFile (prefix </> "deny-authority") "1"; Left _ -> pure ()
                pure result
          executeGitWithBackend (nativeGitBackend & #capture .~ capture) env authorizer current client item.prepared
        ["freeze", config, prefix, name] -> withCase config prefix name \env _ _ _ item -> do
          requireRight =<< withWorkspaceLock (workspaceMetadata (workspaceLocatorPath item.binding.storageRoot) item.binding) do
            requireRight =<< transact env (Workspaces.freezeWorkspaceTx item.binding item.binding.request.owner item.binding.request.epoch)
            pure (Right ())
        ["duplicate", config, prefix, name] -> withCase config prefix name \env _ _ client item -> do
          Just actual <- stored env (Execution.inspectExecutionAttempt item.prepared.reference.attemptId)
          owner <- maybe (fail "actual claim missing") pure actual.owner
          let request = SupervisorRequest item.prepared.snapshot.executionId item.prepared.reference.operationId item.prepared.reference.attemptId owner actual.generation
          reply <- callRpc client.socketPath client.serverUser client.requestSeconds (RpcLaunch request)
          case reply of
            Right (RpcView view) | view.operationId == request.operationId && view.attemptId == request.attemptId -> pure ()
            _ -> fail "duplicate original request did not observe its registration"
        ["inspect", config, prefix, name] -> withCase config prefix name \env _ _ _ item -> inspectCase env prefix name item
        ["cancel", config, prefix, name] -> withCase config prefix name \env _ _ _ item -> do
          root <- stored env (Roots.inspectRoot item.binding.request.rootId)
          stored env (Roots.setRootControl item.binding.request.rootId root.revision Resources.StopWork Nothing)
        ["verify", config, prefix, name, expected] -> withCase config prefix name \env _ _ _ item -> verifyCase env prefix name expected item
        ["verify-git", config, prefix, name, expected] -> withCase config prefix name \env _ _ _ item -> verifyGitCase env expected item
        ["--help"] -> putStrLn "Disposable workspace Linux fixture: authority DIRECTORY PORT | native-provision CONFIG SPEC"
        _ -> fail "unsupported fixture invocation"

checkPrefix :: FilePath -> IO ()
checkPrefix prefix = unless ("/var/lib/shikigami-prototype-" `Text.isPrefixOf` Text.pack prefix && not (".." `Text.isInfixOf` Text.pack prefix)) (fail "fixture directory refused")

-- Exercise native account/tree provisioning through the actual fresh C13 client
-- and database receipts. This mode does not claim process restart qualification.
nativeProvision :: FilePath -> FilePath -> IO ()
nativeProvision configFile specFile = do
  _ <- requireRight =<< Systemd.systemdBootIdentity
  spec <- requireRight . Aeson.eitherDecodeStrict @NativeSpec =<< Bytes.readFile specFile
  checkPrefix spec.directory
  unless (spec.format == 1) (fail "unsupported fixture format")
  config <- runAppConfig AdminRole (ConfigOptions [configFile] [] [] NoDiagnostic)
  connection <- revealSecretText <$> requireDatabaseUrl "workspace-linux-fixture" config
  tracer <- noopTracer
  let env = AppEnv {connectionSettings = defaultConnectionSettings connection, tracer, metrics = Nothing, store = Nothing}
  logger <- Log.newStderrLogger Log.Info
  authorizer <- requireRight =<< buildConfiguredActionAuthorizer logger config
  directory <- requireRight =<< startDirectory Log.silentLogger config.directorySettings
  principal <- VerifiedIdentity <$> requireRight (mkAgentPrincipal "agent_01h000000000000000triage")
  let source = spec.directory </> "source"
      storage = spec.directory </> "workspaces"
      git args = requireRight =<< runWorkspaceGit spec.directory 65536 args
  createDirectory source
  createDirectory (source </> "src")
  Bytes.writeFile (source </> "AGENTS.md") "Fixture policy: validate the exact resulting tree.\n"
  Bytes.writeFile (source </> "src/dependency.txt") "old dependency\n"
  Bytes.writeFile (source </> "src/mode") "complete\n"
  mapM_ (\name -> Bytes.writeFile (source </> ("src/integration-" <> name)) "0\n") ["a", "b", "c"]
  Bytes.writeFile (source </> "src/large-fixture.bin") (Bytes.replicate 1048577 120)
  void (git ["init", source])
  void (git ["-C", source, "add", "--", "AGENTS.md", "src/dependency.txt", "src/mode", "src/large-fixture.bin", "src/integration-a", "src/integration-b", "src/integration-c"])
  void (git ["-C", source, "-c", "user.name=Fixture", "-c", "user.email=fixture@example.invalid", "commit", "-m", "fixture base"])
  base <- Text.strip . Encoding.decodeUtf8 <$> git ["-C", source, "rev-parse", "HEAD"]
  properties <- Systemd.systemdPropertiesIdentity
  let policy = ProcessPolicy ProcessPolicyV1 spec.image properties [CommandRule (workspaceCoordinate "validate") (workspaceCoordinate "/bin/probe") [(workspaceCoordinate "validate")] (workspaceCoordinate "") (Map.singleton (workspaceCoordinate "HOME") (workspaceCoordinate "/scratch")) ((either (error . show) id . parseProcessSeconds) 30) ((either (error . show) id . parseProcessOutputBytes) 1024)] [(workspaceCoordinate "")] [(workspaceCoordinate "src")]
      request = WorkspaceRequest (WorkflowId "native-fixture") Nothing (fixtureRootId "native-fixture-root") principal principal (fixtureRevision 0)
  catalog <- requireRight (mkWorkspaceCatalog [RepositoryPolicy (RepositoryId "mori://fixture/repo") (workspaceLocator source) [workspaceCoordinate base] (workspaceCoordinate base) (processPolicyIdentity policy)])
  repository <- requireRight (resolveRepository catalog (RepositoryId "mori://fixture/repo") Nothing)
  (binding, state) <- requireRight =<< transact env (Workspaces.reserveWorkspaceTx storage request repository)
  requireRight =<< allocateWorkspace storage binding state
  requireRight =<< transact env (Workspaces.markWorkspaceReadyTx binding)
  admission <- (\value -> value & #filePolicy .~ Just supervisedFilePolicy) <$> (requireRight =<< loadWorkspaceAdmission binding (fixtureAssignment "native-fixture-assignment") 65536)
  now <- getCurrentTime
  void (requireRight =<< transact env (Roots.enrollRootTx request.rootId (Resources.Envelope (Map.fromList [(dimension, Resources.ExplicitlyUnbounded) | dimension <- [minBound .. maxBound]]) (addUTCTime 3600 now))))
  reachedReady <- newIORef False
  let current = identityLifecycleAdmission directory.handle principal
      interrupted = ProvisionRuntime env authorizer current (nativeProvisionBackend & #afterReady .~ (writeIORef reachedReady True >> throwIO (userError "fixture lost ready acknowledgement")))
      runtime = ProvisionRuntime env authorizer current nativeProvisionBackend
      pool = IdentityRange ((either (error . show) id . parseWorkspaceIdentity) 64000) ((either (error . show) id . parseWorkspaceIdentity) 64031)
  first <- provisionWorkspaceProfile interrupted binding admission policy pool
  injected <- readIORef reachedReady
  unless (injected && first == Left ProvisionUnresolved) (fail ("missing injected ready acknowledgement loss: " <> either show (const "unexpected ready result") first))
  (reserved, status) <- maybe (fail "missing retained profile") pure =<< (requireRight =<< transact env (inspectProcessProfileTx binding.workspace))
  unless (status == ProfileReserved) (fail "premature database readiness")
  putStrLn "PASS native provisioning retains its original identity after ready acknowledgement loss"
  ready <- requireRight =<< provisionWorkspaceProfile runtime binding admission policy pool
  unless (ready == reserved) (fail "identity changed during recovery")
  repeated <- requireRight =<< provisionWorkspaceProfile runtime binding admission policy pool
  unless (repeated == ready) (fail "duplicate provisioning changed the identity")
  retained <- transact env (inspectProcessProfileTx binding.workspace)
  unless (retained == Right (Just (ready, ProfileReady))) (fail "readiness was not retained")
  putStrLn "PASS native duplicate provisioning recovers the exact ready profile"
  principalText <- requireRight (identityText principal)
  let manifest = Aeson.object ["binding" Aeson..= binding, "admission" Aeson..= admission, "profile" Aeson..= ready, "principal" Aeson..= principalText]
  Lazy.writeFile (spec.directory </> "native-ready.json") (Aeson.encode manifest)
  putStrLn "Native coupled provisioning passed (2 cases); complete process qualification remains open."

transact :: AppEnv -> Transaction a -> IO a
transact env action = requireRight =<< runAppIO env (runTransaction action)

requireRight :: (HasCallStack) => Either e a -> IO a
requireRight = either (const (fail ("fixture boundary refused\n" <> prettyCallStack callStack))) pure

-- The issuer and credentials are fixture data. Responses still pass through the
-- production client's signature, audience, resource, expiry and request checks.
authorityApplication :: FilePath -> IO Application
authorityApplication prefix = do
  (keyId, secret) <- requireRight (parseSigningKeyText "1:a2c4ead323536b925f3488ee83e0888b79c2761405ca7c0c9a018c7c1905eecc")
  Bytes.writeFile (prefix </> "issuer-public.txt") (Encoding.encodeUtf8 (renderIssuerKeySetText (singleKey keyId (toPublic secret))))
  pure \request respond -> do
    denied <- doesFileExist (prefix </> "deny-authority")
    case pathInfo request of
      ["v1", "agent-actions", "authorize"] | not denied && lookup "Authorization" (requestHeaders request) == Just "Bearer workspace-fixture-token" -> do
        body <- strictRequestBody request
        case Aeson.eitherDecode body of
          Right (accepted :: Kikan.AuthorizeActionRequest)
            | Kikan.agentPrincipalText accepted.principal `elem` ["agent_01h000000000000000triage", "agent_01h000000000000000coordinator", "agent_01h000000000000000successor"],
              Kikan.InvokeCapabilityTool _ <- accepted.action -> do
                now <- getCurrentTime
                let expiry = addUTCTime 30 now
                    grant = Grant.EnGrant (SubjectId (ObjectRef (ObjectType "agent") (Kikan.agentPrincipalText accepted.principal))) (RelationName (Kikan.actionOperation accepted.action)) (ObjectRef (ObjectType (Kikan.actionObjectType accepted.action)) (Kikan.actionObjectId accepted.action)) (En.ConsistencyToken "workspace-fixture") (En.SchemaHash "workspace-fixture-schema") expiry (Grant.Audience "shikigami") (Just (Grant.RequestId (Kikan.requestIdText accepted.requestId))) Nothing
                minted <- requireRight =<< mintObjectGrantWithExpiry (MintConfig secret keyId 30 (pure now)) expiry Allowed grant
                proof <- requireRight (Kikan.mkDecisionProof (Encoding.decodeUtf8 minted.token))
                checked <- requireRight (Kikan.mkConsistencyToken "workspace-fixture")
                -- Match Kikan's public issuer boundary. The frozen En source
                -- can report fractional metadata although Biscuit signs whole
                -- seconds; the verifier requires the response and token to agree.
                -- mori://shinzui/kikan-en, src/Kikan/En/Action/Server.hs
                -- (artifact URI pending).
                let signedExpiry = posixSecondsToUTCTime (fromInteger (round (utcTimeToPOSIXSeconds minted.expiresAt)))
                respond (json status200 (Aeson.toJSON (Kikan.IssuedActionProof proof signedExpiry [] checked)))
          _ -> respond (json status403 refused)
      ["v1", "agent-actions", "authorize"] -> respond (json status403 refused)
      _ -> respond (json status404 refused)
  where
    json status body = responseLBS status [("Content-Type", "application/json")] (Aeson.encode body)
    refused = Aeson.object ["type" Aeson..= ("about:blank" :: Text.Text), "title" Aeson..= ("Fixture refusal" :: Text.Text), "status" Aeson..= (403 :: Int), "detail" Aeson..= ("fixture authority refused" :: Text.Text)]

checkName :: String -> IO ()
checkName name = unless (not (null name) && length name <= 40 && all (\c -> c >= 'a' && c <= 'z' || c == '-') name) (fail "fixture name refused")

withRuntime :: FilePath -> (AppEnv -> ActionAuthorizer -> (ExecutionSnapshot -> IO (Either Text.Text ())) -> ProcessClient -> IO a) -> IO a
withRuntime configFile use = do
  _ <- requireRight =<< Systemd.systemdBootIdentity
  config <- runAppConfig AdminRole (ConfigOptions [configFile] [] [] NoDiagnostic)
  connection <- revealSecretText <$> requireDatabaseUrl "workspace-linux-fixture" config
  tracer <- noopTracer
  let env = AppEnv {connectionSettings = defaultConnectionSettings connection, tracer, metrics = Nothing, store = Nothing}
  authorizer <- requireRight =<< buildConfiguredActionAuthorizer Log.silentLogger config
  directory <- requireRight =<< startDirectory Log.silentLogger config.directorySettings
  socket <- maybe (fail "fixture supervisor configuration missing") (pure . (.socketPath)) config.workspaceSupervisorSettings
  use env authorizer (identityLifecycleAdmission directory.handle . (.identity)) (ProcessClient socket ((either (error . show) id . parseRpcPeerUserId) 0) ((either (error . show) id . parseRpcRequestSeconds) 5) ((either (error . show) id . parseRpcWaitSeconds) 60))

prepareCase :: FilePath -> FilePath -> String -> Text.Text -> IO ()
prepareCase config prefix name mode = do
  checkPrefix prefix
  checkName name
  unless (mode `elem` ["complete", "slow", "orphan", "denials", "upgrade"]) (fail "fixture mode refused")
  initial <- requireRight . Aeson.eitherDecodeStrict @ReadyProfile =<< Bytes.readFile (prefix </> "native-ready.json")
  withRuntime config \env authorizer current client -> do
    let owner = initial.binding.request.owner
        request = WorkspaceRequest (WorkflowId ("case-" <> Text.pack name)) Nothing (fixtureRootId ("case-root-" <> Text.pack name)) owner owner (fixtureRevision 0)
        base = initial.binding.base
        policy = initial.profile.policy
    catalog <- requireRight (mkWorkspaceCatalog [RepositoryPolicy initial.binding.repository initial.binding.source [base] base (processPolicyIdentity policy)])
    repository <- requireRight (resolveRepository catalog initial.binding.repository Nothing)
    (binding, state) <- requireRight =<< transact env (Workspaces.reserveWorkspaceTx (workspaceLocatorPath initial.binding.storageRoot) request repository)
    requireRight =<< allocateWorkspace (workspaceLocatorPath binding.storageRoot) binding state
    requireRight =<< transact env (Workspaces.markWorkspaceReadyTx binding)
    admission <- (\value -> value & #filePolicy .~ Just supervisedFilePolicy) <$> (requireRight =<< loadWorkspaceAdmission binding (fixtureAssignment ("case-assignment-" <> Text.pack name)) 65536)
    now <- getCurrentTime
    void (requireRight =<< transact env (Roots.enrollRootTx request.rootId (Resources.Envelope (Map.fromList [(dimension, Resources.ExplicitlyUnbounded) | dimension <- [minBound .. maxBound]]) (addUTCTime 3600 now))))
    -- This fresh boundary uses the same configured C13 verifier as the daemon.
    profile <- requireRight =<< provisionWorkspaceProfile (ProvisionRuntime env authorizer (currentIdentity owner) nativeProvisionBackend) binding admission policy (IdentityRange ((either (error . show) id . parseWorkspaceIdentity) 64000) ((either (error . show) id . parseWorkspaceIdentity) 64031))
    prepared <- if mode == "upgrade" then prepareUpgrade env authorizer current client binding admission else prepareAccepted env authorizer current client binding admission mode
    let path = workspaceFiles (workspaceLocatorPath binding.storageRoot) binding </> "src/mode"
    actual <- readProcess "/usr/bin/stat" ["-c", "%u", path] ""
    unless (Text.strip (Text.pack actual) == Text.pack (show profile.userId)) (fail "native edit lost workspace ownership")
    Lazy.writeFile (caseFile prefix name) (Aeson.encode (PreparedCase binding prepared))
    putStrLn "PASS accepted native revision-2 edit preserves the reserved Unix identity"
  where
    currentIdentity identity = do
      -- The callback intentionally uses the fresh configured directory handle.
      resolved <- runAppConfig AdminRole (ConfigOptions [config] [] [] NoDiagnostic)
      directory <- requireRight =<< startDirectory Log.silentLogger resolved.directorySettings
      identityLifecycleAdmission directory.handle identity

caseFile :: FilePath -> String -> FilePath
caseFile prefix name = prefix </> ("case-" <> name <> ".json")

withCase :: FilePath -> FilePath -> String -> (AppEnv -> ActionAuthorizer -> (ExecutionSnapshot -> IO (Either Text.Text ())) -> ProcessClient -> PreparedCase -> IO a) -> IO a
withCase config prefix name use = do
  checkPrefix prefix
  checkName name
  item <- requireRight . Aeson.eitherDecodeStrict @PreparedCase =<< Bytes.readFile (caseFile prefix name)
  withRuntime config \env authorizer current client -> use env authorizer current client item

inspectCase :: AppEnv -> FilePath -> String -> PreparedCase -> IO ()
inspectCase env prefix name item = do
  metadata <- stored env (Execution.inspectExecution item.prepared.snapshot.executionId)
  actual <- stored env (Execution.inspectExecutionAttempt item.prepared.reference.attemptId)
  process <- requireRight =<< transact env (Processes.inspectProcessTx item.prepared.reference.operationId)
  git <- requireRight =<< transact env (Git.inspectGitTx item.prepared.reference.operationId)
  let state = (\(value, _, _) -> value) <$> metadata
      operationDirectory record = workspaceMetadata (workspaceLocatorPath item.binding.storageRoot) item.binding </> Text.unpack ("process-" <> Text.drop 7 (versionedDigest "shikigami.workspace-process-directory/1" (Aeson.toJSON (record.operationId, record.fingerprint))))
      capture record = "shikigami-capture-" <> Text.drop (Text.length ("shikigami-workspace-" :: Text.Text)) (workspaceCoordinateText record.unit)
      body = Aeson.object ["state" Aeson..= state, "actual" Aeson..= actual, "process" Aeson..= process, "git" Aeson..= git, "files" Aeson..= workspaceFiles (workspaceLocatorPath item.binding.storageRoot) item.binding, "directory" Aeson..= (operationDirectory <$> process), "capture" Aeson..= (capture <$> process)]
  -- Private fixture control data; never print paths, protected bodies or argv.
  Lazy.writeFile (prefix </> ("status-" <> name <> ".json")) (Aeson.encode body)

verifyCase :: AppEnv -> FilePath -> String -> String -> PreparedCase -> IO ()
verifyCase env _prefix _name expected item = do
  Just (state, _, _) <- stored env (Execution.inspectExecution item.prepared.snapshot.executionId)
  Just actual <- stored env (Execution.inspectExecutionAttempt item.prepared.reference.attemptId)
  Just process <- requireRight =<< transact env (Processes.inspectProcessTx item.prepared.reference.operationId)
  root <- stored env (Roots.inspectRoot item.binding.request.rootId)
  let path = workspaceFiles (workspaceLocatorPath item.binding.storageRoot) item.binding </> "src/launch-count"
  exists <- doesFileExist path
  launches <- if exists then Bytes.length <$> Bytes.readFile path else pure 0
  unless (launches == if expected == "refused" then 0 else 1) (fail "unexpected launch count")
  unless (process.attemptId == actual.request.attemptId && process.generation == actual.generation) (fail "original actual identity changed")
  case expected of
    "unresolved" -> do
      unless (process.phase == ProcessUnresolved && process.receipt == Nothing && actual.phase `elem` [Attempt.DispatchStarted, Attempt.AttemptUncertain] && (root.active > noAttempts || root.unknown > noAttempts)) (fail "missing evidence released capacity")
      blocked <- transact env (Workspaces.checkWorkspaceOperationTx item.binding item.binding.request.owner item.binding.request.epoch (fixtureOperationId "fixture-successor"))
      unless (case blocked of Left _ -> True; _ -> False) (fail "unresolved process opened the file barrier")
    "refused" -> unless (process.phase == ProcessRefused && process.receipt == Nothing && actual.phase == Attempt.AttemptCommitted && state.cursor == (fixtureRevision 3) && root.active == noAttempts && root.unknown == noAttempts) (fail "pre-launch refusal did not settle its actual")
    _ -> case process.receipt of
      Just receipt -> unless (process.phase == ProcessSettled && validProcessReceipt process receipt && actual.phase == Attempt.AttemptCommitted && state.cursor == (fixtureRevision 3) && root.active == noAttempts && root.unknown == noAttempts && if expected == "cancelled" then receipt.termination == ProcessCancelled && not (processSucceeded receipt) else expected == "success" && processSucceeded receipt) (fail "original receipt did not settle")
      Nothing -> fail "completion receipt missing"
  source <- requireRight =<< runWorkspaceGit (workspaceLocatorPath item.binding.storageRoot) 1024 ["-C", workspaceLocatorPath item.binding.source, "status", "--porcelain"]
  unless (Bytes.null source) (fail "source repository changed")
  putStrLn "PASS original accepted operation retains one launch and conservative receipt accounting"

verifyGitCase :: AppEnv -> String -> PreparedCase -> IO ()
verifyGitCase env expected item = do
  Just record <- requireRight =<< transact env (Git.inspectGitTx item.prepared.reference.operationId)
  Just actual <- stored env (Execution.inspectExecutionAttempt item.prepared.reference.attemptId)
  Just (state, _, _) <- stored env (Execution.inspectExecution item.prepared.snapshot.executionId)
  root <- stored env (Roots.inspectRoot item.binding.request.rootId)
  Just validation <- requireRight =<< transact env (Processes.inspectProcessTx (operationIdFor item.prepared.snapshot.executionId (fixtureRevision 2)))
  unless (maybe False processSucceeded validation.receipt && validation.instructionDigest == record.instructionDigest) (fail "upgrade validation evidence missing")
  unless (record.attemptId == actual.request.attemptId && record.generation == actual.generation && actual.phase == Attempt.AttemptCommitted && state.cursor == (fixtureRevision 4) && root.active == noAttempts && root.unknown == noAttempts) (fail "original Git actual did not settle")
  let metadata = workspaceMetadata (workspaceLocatorPath item.binding.storageRoot) item.binding
  headId <- requireRight =<< GitObjects.readHead metadata
  case expected of
    "applied" -> do
      candidate <- maybe (fail "commit candidate missing") pure record.candidate
      unless (record.phase == GitApplied && headId == candidate.result && candidate.parent == item.binding.base && map workspaceCoordinateText candidate.paths == ["src/dependency.txt"]) (fail "unexpected upgrade commit")
      published <- requireRight =<< GitObjects.verifyPublishedCommit metadata candidate
      unless published (fail "commit object evidence mismatched")
      count <- requireRight =<< runWorkspaceGit (workspaceLocatorPath item.binding.storageRoot) 128 ["--git-dir=" <> metadata, "rev-list", "--count", Text.unpack (workspaceCoordinateText item.binding.base) <> "..HEAD"]
      unless (count == "1\n") (fail "duplicate local commit")
      large <- requireRight =<< runWorkspaceGit (workspaceLocatorPath item.binding.storageRoot) 128 ["--git-dir=" <> metadata, "cat-file", "-s", Text.unpack (workspaceCoordinateText candidate.result) <> ":src/large-fixture.bin"]
      unless (large == "1048577\n") (fail "unchanged large blob was not preserved")
    "refused" -> unless (record.phase == GitRefused && record.candidate /= Nothing && headId == item.binding.base) (fail "publication denial changed HEAD")
    _ -> fail "unsupported Git expectation"
  source <- requireRight =<< runWorkspaceGit (workspaceLocatorPath item.binding.storageRoot) 1024 ["-C", workspaceLocatorPath item.binding.source, "status", "--porcelain"]
  unless (Bytes.null source) (fail "source repository changed")
  putStrLn "PASS validated dependency upgrade retains its exact local commit and original actual receipt"

stored :: AppEnv -> Eff AppEffects (Either e a) -> IO a
stored env action = requireRight =<< (requireRight =<< runAppIO env action)

fixtureRevision :: Integer -> StateRevision scope
fixtureRevision value = either (error . show) id (parseRevision value)

fixtureAssignment :: AssignmentText.Text -> AssignmentKey
fixtureAssignment = either (error . show) id . parseAssignmentKey
