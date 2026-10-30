-- Fixture-only executable: never installed in the production runtime. All paths,
-- credentials, repositories and identities below belong to a disposable guest.
module Main (main) where

import Accepted (Prepared (..), executePrepared, prepareAccepted)
import Auth.Biscuit (toPublic)
import Control.Exception (IOException, SomeException, catch, fromException, throwIO)
import Control.Monad (unless, void)
import Data.Aeson qualified as Aeson
import Data.ByteString qualified as Bytes
import Data.ByteString.Lazy qualified as Lazy
import Data.Generics.Labels ()
import Data.IORef (newIORef, readIORef, writeIORef)
import Data.Map.Strict qualified as Map
import Data.Text qualified as Text
import Data.Text.Encoding qualified as Encoding
import Data.Time (addUTCTime, getCurrentTime)
import Data.Time.Clock.POSIX (posixSecondsToUTCTime, utcTimeToPOSIXSeconds)
import Effectful (Eff)
import En.Biscuit.Grant qualified as Grant
import En.Biscuit.Keys (parseSigningKeyText, renderIssuerKeySetText, singleKey)
import En.Biscuit.Mint (MintConfig (..), MintedGrant (..), mintObjectGrantWithExpiry)
import En.Check (CheckDecision (Allowed))
import En.Revision qualified as En
import En.Schema (ObjectType (..), RelationName (..))
import En.Tuple (ObjectRef (..), Subject (SubjectId))
import GHC.Generics (Generic)
import GHC.Stack (HasCallStack, callStack, prettyCallStack)
import Hasql.Transaction (Transaction)
import Kikan.En.Action qualified as Kikan
import Kioku.App (AppEffects, AppEnv (..), noopTracer, runAppIO)
import Kiroku.Store.Connection (defaultConnectionSettings)
import Kiroku.Store.Transaction (runTransaction)
import Network.HTTP.Types (status200, status403, status404)
import Network.Wai (Application, pathInfo, requestHeaders, responseLBS, strictRequestBody)
import Network.Wai.Handler.Warp (defaultSettings, runSettings, setHost, setPort)
import Shikigami.Action.Authorization (ActionAuthorizer)
import Shikigami.Action.Authorization.Config (buildConfiguredActionAuthorizer)
import Shikigami.Agent.Principal (AgentIdentity (VerifiedIdentity), identityText, mkAgentPrincipal)
import Shikigami.App.Config (AppConfig (..), Role (AdminRole), revealSecretText)
import Shikigami.App.Config.Load (ConfigOptions (..), DiagnosticMode (NoDiagnostic), requireDatabaseUrl, runAppConfig)
import Shikigami.Decision.Contract (versionedDigest)
import Shikigami.Directory (DirectoryRuntime (..), identityLifecycleAdmission, startDirectory)
import Shikigami.Execution.Attempt qualified as Attempt
import Shikigami.Execution.Identity (ExecutionRootId (..), OperationId (..))
import Shikigami.Execution.Resources qualified as Resources
import Shikigami.Execution.Store qualified as Execution
import Shikigami.Execution.Transcript (ExecutionSnapshot (..), ExecutionState (..))
import Shikigami.Log qualified as Log
import Shikigami.Prelude ((&), (.~))
import Shikigami.Store.ExecutionResources qualified as Roots
import Shikigami.Workspace.Allocation
import Shikigami.Workspace.Catalog
import Shikigami.Workspace.Git (runWorkspaceGit)
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
        ["native-provision", config, spec] -> nativeProvision config spec
        ["prepare", config, prefix, name, mode] -> prepareCase config prefix name (Text.pack mode)
        ["worker", config, prefix, name] -> withCase config prefix name \env authorizer current client item -> executePrepared env authorizer current client item.prepared
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
          stored env (Roots.setRootControl item.binding.request.rootId root.revision True Nothing)
        ["verify", config, prefix, name, expected] -> withCase config prefix name \env _ _ _ item -> verifyCase env prefix name expected item
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
  let env = AppEnv {connectionSettings = defaultConnectionSettings connection, tracer, metrics = Nothing}
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
  void (git ["init", source])
  void (git ["-C", source, "add", "--", "AGENTS.md", "src/dependency.txt", "src/mode"])
  void (git ["-C", source, "-c", "user.name=Fixture", "-c", "user.email=fixture@example.invalid", "commit", "-m", "fixture base"])
  base <- Text.strip . Encoding.decodeUtf8 <$> git ["-C", source, "rev-parse", "HEAD"]
  properties <- Systemd.systemdPropertiesIdentity
  let policy = ProcessPolicy 1 spec.image properties [CommandRule "validate" "/bin/probe" ["validate"] "" (Map.singleton "HOME" "/scratch") 30 1024] [""] ["src"]
      request = WorkspaceRequest "native-fixture" Nothing (ExecutionRootId "native-fixture-root") principal principal 0
  catalog <- requireRight (mkWorkspaceCatalog [RepositoryPolicy "mori://fixture/repo" source [base] base (processPolicyIdentity policy)])
  repository <- requireRight (resolveRepository catalog "mori://fixture/repo" Nothing)
  (binding, state) <- requireRight =<< transact env (Workspaces.reserveWorkspaceTx storage request repository)
  requireRight =<< allocateWorkspace storage binding state
  requireRight =<< transact env (Workspaces.markWorkspaceReadyTx binding)
  admission <- (\value -> value & #filePolicy .~ Just supervisedFilePolicy) <$> (requireRight =<< loadWorkspaceAdmission binding "native-fixture-assignment" 65536)
  now <- getCurrentTime
  void (requireRight =<< transact env (Roots.enrollRootTx request.rootId (Resources.Envelope (Map.fromList [(dimension, Resources.ExplicitlyUnbounded) | dimension <- [minBound .. maxBound]]) (addUTCTime 3600 now))))
  reachedReady <- newIORef False
  let current = identityLifecycleAdmission directory.handle principal
      interrupted = ProvisionRuntime env authorizer current (nativeProvisionBackend & #afterReady .~ (writeIORef reachedReady True >> throwIO (userError "fixture lost ready acknowledgement")))
      runtime = ProvisionRuntime env authorizer current nativeProvisionBackend
      pool = IdentityRange 64000 64031
  first <- provisionWorkspaceProfile interrupted binding admission policy pool
  injected <- readIORef reachedReady
  unless (injected && first == Left ProvisionUnresolved) (fail ("missing injected ready acknowledgement loss: " <> either show (const "unexpected ready result") first))
  (reserved, status) <- maybe (fail "missing retained profile") pure =<< transact env (inspectProcessProfileTx binding.workspace)
  unless (status == ProfileReserved) (fail "premature database readiness")
  putStrLn "PASS native provisioning retains its original identity after ready acknowledgement loss"
  ready <- requireRight =<< provisionWorkspaceProfile runtime binding admission policy pool
  unless (ready == reserved) (fail "identity changed during recovery")
  repeated <- requireRight =<< provisionWorkspaceProfile runtime binding admission policy pool
  unless (repeated == ready) (fail "duplicate provisioning changed the identity")
  retained <- transact env (inspectProcessProfileTx binding.workspace)
  unless (retained == Just (ready, ProfileReady)) (fail "readiness was not retained")
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
            | Kikan.agentPrincipalText accepted.principal == "agent_01h000000000000000triage",
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
  let env = AppEnv {connectionSettings = defaultConnectionSettings connection, tracer, metrics = Nothing}
  authorizer <- requireRight =<< buildConfiguredActionAuthorizer Log.silentLogger config
  directory <- requireRight =<< startDirectory Log.silentLogger config.directorySettings
  socket <- maybe (fail "fixture supervisor configuration missing") (pure . (.socketPath)) config.workspaceSupervisorSettings
  use env authorizer (identityLifecycleAdmission directory.handle . (.identity)) (ProcessClient socket 0 5 60)

prepareCase :: FilePath -> FilePath -> String -> Text.Text -> IO ()
prepareCase config prefix name mode = do
  checkPrefix prefix
  checkName name
  unless (mode `elem` ["complete", "slow", "orphan", "denials"]) (fail "fixture mode refused")
  initial <- requireRight . Aeson.eitherDecodeStrict @ReadyProfile =<< Bytes.readFile (prefix </> "native-ready.json")
  withRuntime config \env authorizer current client -> do
    let owner = initial.binding.request.owner
        request = WorkspaceRequest ("case-" <> Text.pack name) Nothing (ExecutionRootId ("case-root-" <> Text.pack name)) owner owner 0
        base = initial.binding.base
        policy = initial.profile.policy
    catalog <- requireRight (mkWorkspaceCatalog [RepositoryPolicy initial.binding.repository initial.binding.source [base] base (processPolicyIdentity policy)])
    repository <- requireRight (resolveRepository catalog initial.binding.repository Nothing)
    (binding, state) <- requireRight =<< transact env (Workspaces.reserveWorkspaceTx initial.binding.storageRoot request repository)
    requireRight =<< allocateWorkspace binding.storageRoot binding state
    requireRight =<< transact env (Workspaces.markWorkspaceReadyTx binding)
    admission <- (\value -> value & #filePolicy .~ Just supervisedFilePolicy) <$> (requireRight =<< loadWorkspaceAdmission binding ("case-assignment-" <> Text.pack name) 65536)
    now <- getCurrentTime
    void (requireRight =<< transact env (Roots.enrollRootTx request.rootId (Resources.Envelope (Map.fromList [(dimension, Resources.ExplicitlyUnbounded) | dimension <- [minBound .. maxBound]]) (addUTCTime 3600 now))))
    -- This fresh boundary uses the same configured C13 verifier as the daemon.
    profile <- requireRight =<< provisionWorkspaceProfile (ProvisionRuntime env authorizer (currentIdentity owner) nativeProvisionBackend) binding admission policy (IdentityRange 64000 64031)
    prepared <- prepareAccepted env authorizer current client binding admission mode
    let path = workspaceFiles binding.storageRoot binding </> "src/mode"
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
  process <- transact env (Processes.inspectProcessTx item.prepared.reference.operationId)
  let state = (\(value, _, _) -> value) <$> metadata
      operationDirectory record = workspaceMetadata item.binding.storageRoot item.binding </> Text.unpack ("process-" <> Text.drop 7 (versionedDigest "shikigami.workspace-process-directory/1" (Aeson.toJSON (record.operationId, record.fingerprint))))
      capture record = "shikigami-capture-" <> Text.drop (Text.length ("shikigami-workspace-" :: Text.Text)) record.unit
      body = Aeson.object ["state" Aeson..= state, "actual" Aeson..= actual, "process" Aeson..= process, "files" Aeson..= workspaceFiles item.binding.storageRoot item.binding, "directory" Aeson..= (operationDirectory <$> process), "capture" Aeson..= (capture <$> process)]
  -- Private fixture control data; never print paths, protected bodies or argv.
  Lazy.writeFile (prefix </> ("status-" <> name <> ".json")) (Aeson.encode body)

verifyCase :: AppEnv -> FilePath -> String -> String -> PreparedCase -> IO ()
verifyCase env _prefix _name expected item = do
  Just (state, _, _) <- stored env (Execution.inspectExecution item.prepared.snapshot.executionId)
  Just actual <- stored env (Execution.inspectExecutionAttempt item.prepared.reference.attemptId)
  Just process <- transact env (Processes.inspectProcessTx item.prepared.reference.operationId)
  root <- stored env (Roots.inspectRoot item.binding.request.rootId)
  let path = workspaceFiles item.binding.storageRoot item.binding </> "src/launch-count"
  exists <- doesFileExist path
  launches <- if exists then Bytes.length <$> Bytes.readFile path else pure 0
  unless (launches == if expected == "refused" then 0 else 1) (fail "unexpected launch count")
  unless (process.attemptId == actual.request.attemptId && process.generation == actual.generation) (fail "original actual identity changed")
  case expected of
    "unresolved" -> do
      unless (process.phase == ProcessUnresolved && process.receipt == Nothing && actual.phase `elem` [Attempt.DispatchStarted, Attempt.AttemptUncertain] && root.active + root.unknown >= 1) (fail "missing evidence released capacity")
      blocked <- transact env (Workspaces.checkWorkspaceOperationTx item.binding item.binding.request.owner item.binding.request.epoch (OperationId "fixture-successor"))
      unless (case blocked of Left _ -> True; _ -> False) (fail "unresolved process opened the file barrier")
    "refused" -> unless (process.phase == ProcessRefused && process.receipt == Nothing && actual.phase == Attempt.AttemptCommitted && state.cursor == 3 && root.active == 0 && root.unknown == 0) (fail "pre-launch refusal did not settle its actual")
    _ -> case process.receipt of
      Just receipt -> unless (process.phase == ProcessSettled && validProcessReceipt process receipt && actual.phase == Attempt.AttemptCommitted && state.cursor == 3 && root.active == 0 && root.unknown == 0 && if expected == "cancelled" then receipt.termination == ProcessCancelled && not (processSucceeded receipt) else expected == "success" && processSucceeded receipt) (fail "original receipt did not settle")
      Nothing -> fail "completion receipt missing"
  source <- requireRight =<< runWorkspaceGit item.binding.storageRoot 1024 ["-C", item.binding.source, "status", "--porcelain"]
  unless (Bytes.null source) (fail "source repository changed")
  putStrLn "PASS original accepted operation retains one launch and conservative receipt accounting"

stored :: AppEnv -> Eff AppEffects (Either e a) -> IO a
stored env action = requireRight =<< (requireRight =<< runAppIO env action)
