-- | Coupled pre-model provisioning. Reservations and prepared receipts survive
-- interruption; neither expiry nor a failed acknowledgement allocates a new uid.
module Shikigami.Workspace.Provision
  ( ProvisionError (..),
    ManagedIdentity (..),
    ProvisionRuntime (..),
    ProvisionBackend (..),
    nativeProvisionBackend,
    provisionWorkspaceProfile,
  )
where

import Control.Exception (Exception, IOException, catch, throwIO)
import Data.Aeson qualified as Aeson
import Data.ByteString qualified as Bytes
import Data.ByteString.Lazy qualified as Lazy
import Data.Generics.Labels ()
import Data.Text qualified as Text
import Data.Text.Encoding qualified as Encoding
import Hasql.Transaction (Transaction)
import Kiroku.Store.Transaction (runTransaction)
import Shikigami.Action.Authorization (ActionAuthorizer (..))
import Shikigami.Agent.Principal (identityText)
import Shikigami.App (AppEnv, runAppIO)
import Shikigami.Decision.Contract (versionedDigest)
import Shikigami.Execution.Identity (OperationId (..))
import Shikigami.Execution.Resources qualified as Resources
import Shikigami.Prelude
import Shikigami.Store.ExecutionResources qualified as Roots
import Shikigami.Workspace.Allocation
import Shikigami.Workspace.ContainedFile
import Shikigami.Workspace.Instructions
import Shikigami.Workspace.ProcessPolicy
import Shikigami.Workspace.ProcessProfileStore
import Shikigami.Workspace.Profile (profileStorageSafe, retainedSystemdProfile)
import Shikigami.Workspace.Provider (workspaceProvisionAction)
import Shikigami.Workspace.Store qualified as Store
import Shikigami.Workspace.Systemd qualified as Systemd
import Shikigami.Workspace.Types
import System.Exit (ExitCode (..))
import System.IO (IOMode (WriteMode), withFile)
import System.Process (CreateProcess (..), StdStream (..), proc, waitForProcess, withCreateProcess)
import System.Timeout (timeout)

data ProvisionError = ProvisionRefused | ProvisionUnavailable | ProvisionUnresolved | ProvisionUnsupported
  deriving stock (Eq, Show)

data ManagedIdentity = IdentityMissing | IdentityGroupOnly | IdentityReady
  deriving stock (Eq, Show)

data ProvisionRuntime = ProvisionRuntime
  { appEnv :: !AppEnv,
    authorizer :: !ActionAuthorizer,
    current :: !(IO (Either Text ())),
    backend :: !ProvisionBackend
  }
  deriving stock (Generic)

data ProvisionBackend = ProvisionBackend
  { bootIdentity :: !(IO (Either Systemd.SystemdError Text)),
    inspectIdentity :: !(ProcessProfile -> IO (Either ProvisionError ManagedIdentity)),
    createIdentity :: !(IO (Either ProvisionError ()) -> ProcessProfile -> IO (Either ProvisionError ())),
    tree :: !(Int -> Bool -> ContainedFile -> IO (Either FileError ())),
    afterReady :: !(IO ())
  }
  deriving stock (Generic)

data ProvisionMarker = ProvisionMarker
  { format :: !Int,
    fingerprint :: !Text,
    filesTarget :: !Text,
    scratchTarget :: !Text,
    ready :: !Bool
  }
  deriving stock (Eq, Generic)
  deriving anyclass (ToJSON)

instance FromJSON ProvisionMarker where
  parseJSON = Aeson.genericParseJSON Aeson.defaultOptions {Aeson.rejectUnknownFields = True}

newtype ProvisionAbort = ProvisionAbort ProvisionError deriving stock (Show)

instance Exception ProvisionAbort

nativeProvisionBackend :: ProvisionBackend
nativeProvisionBackend = ProvisionBackend Systemd.systemdBootIdentity inspectNativeIdentity createNativeIdentity provisionContainedRoot (pure ())

provisionWorkspaceProfile :: ProvisionRuntime -> WorkspaceBinding -> WorkspaceAdmission -> ProcessPolicy -> IdentityRange -> IO (Either ProvisionError ProcessProfile)
provisionWorkspaceProfile runtime binding admission policy pool = protect do
  boot <- runtime.backend.bootIdentity >>= either (const (abort ProvisionUnsupported)) pure
  checkCurrent runtime binding
  (profile, state) <- transact runtime (reserveProcessProfileTx binding (bundleDigest admission.instructions) policy pool) >>= either (const (abort ProvisionRefused)) pure
  _ <- retainedSystemdProfile profile >>= either (const (abort ProvisionUnsupported)) pure
  unless (profileStorageSafe binding profile) (abort ProvisionRefused)
  needFile =<< checkPrivateDirectory binding.storageRoot
  let metadata = workspaceMetadata binding.storageRoot binding
  needFile =<< checkPrivateDirectory metadata
  locked <-
    withWorkspaceLock metadata $
      Right <$> do
        checkCurrent runtime binding
        available <- transact runtime (Store.checkWorkspaceOperationTx binding admission.owner admission.epoch (OperationId "workspace-profile-admission"))
        either (const (abort ProvisionRefused)) pure available
        files <- withContainedFile (workspaceFiles binding.storageRoot binding) ".shikigami-profile-target" \filesRoot ->
          Right <$> do
            scratch <- withContainedFile (workspaceScratch binding.storageRoot binding) ".shikigami-profile-target" \scratchRoot ->
              Right <$> provisionRoots runtime binding admission profile state boot metadata filesRoot scratchRoot
            either (const (abort ProvisionUnresolved)) pure scratch
        either (const (abort ProvisionUnresolved)) pure files
  either (const (abort ProvisionUnresolved)) pure locked

provisionRoots :: ProvisionRuntime -> WorkspaceBinding -> WorkspaceAdmission -> ProcessProfile -> ProfileState -> Text -> FilePath -> ContainedFile -> ContainedFile -> IO ProcessProfile
provisionRoots runtime binding admission profile state boot metadata files scratch = do
  filesTarget <- containedTargetIdentity files >>= either (const (abort ProvisionRefused)) pure
  scratchTarget <- containedTargetIdentity scratch >>= either (const (abort ProvisionRefused)) pure
  action <- either (const (abort ProvisionRefused)) pure (workspaceProvisionAction binding admission profile boot filesTarget scratchTarget)
  principal <- either (const (abort ProvisionRefused)) pure (identityText admission.owner)
  let authorize = protect do
        checkCurrent runtime binding
        runtime.authorizer.authorize principal action >>= either (const (abort ProvisionRefused)) (const (pure ()))
        checkCurrent runtime binding
      fresh = authorize >>= either abort pure
      expected = ProvisionMarker 1 (versionedDigest "shikigami.workspace-provision/1" (toJSON profile)) filesTarget scratchTarget False
  fresh
  marker <- readMarker metadata
  forM_ marker \old -> unless (old == expected || old == (expected & #ready .~ True)) (abort ProvisionUnresolved)
  identity <- runtime.backend.inspectIdentity profile >>= either abort pure
  case (state, marker) of
    (ProfileReady, Just old) | old.ready && identity == IdentityReady -> pure profile
    (ProfileReady, _) -> abort ProvisionUnresolved
    (ProfileReserved, Just old) | old.ready && identity == IdentityReady -> do
      fresh
      transact runtime (readyProcessProfileTx binding profile) >>= either (const (abort ProvisionUnresolved)) pure
      pure profile
    (ProfileReserved, _) -> do
      when (isNothing marker && identity /= IdentityMissing) (abort ProvisionRefused)
      runtime.backend.tree profile.userId False files >>= either (const (abort ProvisionRefused)) pure
      runtime.backend.tree profile.userId False scratch >>= either (const (abort ProvisionRefused)) pure
      when (isNothing marker) (fresh >> writeMarker metadata expected)
      runtime.backend.createIdentity authorize profile >>= either abort pure
      fresh
      runtime.backend.tree profile.userId True files >>= either (const (abort ProvisionUnresolved)) pure
      fresh
      runtime.backend.tree profile.userId True scratch >>= either (const (abort ProvisionUnresolved)) pure
      fresh
      writeMarker metadata (expected & #ready .~ True)
      runtime.backend.afterReady
      transact runtime (readyProcessProfileTx binding profile) >>= either (const (abort ProvisionUnresolved)) pure
      pure profile

checkCurrent :: ProvisionRuntime -> WorkspaceBinding -> IO ()
checkCurrent runtime binding = do
  runtime.current >>= either (const (abort ProvisionRefused)) pure
  root <- runAppIO runtime.appEnv (Roots.inspectRoot binding.request.rootId) >>= either (const (abort ProvisionUnavailable)) (either (const (abort ProvisionRefused)) pure)
  now <- getCurrentTime
  either (const (abort ProvisionRefused)) pure (Resources.checkRoot now root.revision root)
  transact runtime (Store.checkWorkspaceOwnerTx binding binding.request.owner binding.request.epoch) >>= either (const (abort ProvisionRefused)) pure

readMarker :: FilePath -> IO (Maybe ProvisionMarker)
readMarker metadata = do
  result <- withContainedFile metadata "profile-provision.json" (readContainedFile 4096)
  bytes <- either (const (abort ProvisionUnresolved)) pure result
  traverse (either (const (abort ProvisionUnresolved)) pure . Aeson.eitherDecodeStrict) bytes

writeMarker :: FilePath -> ProvisionMarker -> IO ()
writeMarker metadata marker = do
  result <- withContainedFile metadata "profile-provision.json" \target -> do
    previous <- readContainedFile 4096 target
    case previous of
      Left err -> pure (Left err)
      Right old -> replaceContainedFile metadata target old (Lazy.toStrict (Aeson.encode marker))
  either (const (abort ProvisionUnresolved)) pure result

managedName :: ProcessProfile -> Text
managedName profile = "shikigami-ws-" <> Text.pack (show profile.userId)

managedComment :: ProcessProfile -> Text
managedComment profile = "shikigami-ws-" <> Text.drop 7 (versionedDigest "shikigami.workspace-provision/1" (toJSON profile))

inspectNativeIdentity :: ProcessProfile -> IO (Either ProvisionError ManagedIdentity)
inspectNativeIdentity profile = protect do
  let uid = Text.pack (show profile.userId)
      name = managedName profile
      lookupEntry kind selected = do
        (status, bytes) <- command "/usr/bin/getent" [kind, Text.unpack selected]
        case (status, Encoding.decodeUtf8' bytes) of
          (ExitFailure 2, Right body) | Text.null body -> pure Nothing
          (ExitSuccess, Right body) -> pure (Just (Text.splitOn ":" (Text.strip body)))
          _ -> abort ProvisionUnavailable
  userById <- lookupEntry "passwd" uid
  userByName <- lookupEntry "passwd" name
  groupById <- lookupEntry "group" uid
  groupByName <- lookupEntry "group" name
  let validUser = case userById of
        Just [actual, _, user, group, comment, home, shell] -> actual == name && user == uid && group == uid && comment == managedComment profile && home == "/var/empty" && shell == "/usr/sbin/nologin"
        _ -> False
      validGroup = case groupById of Just [actual, _, group, members] -> actual == name && group == uid && Text.null members; _ -> False
  if all isNothing [userById, userByName, groupById, groupByName]
    then pure IdentityMissing
    else
      if isNothing userById && isNothing userByName && validGroup && groupById == groupByName
        then pure IdentityGroupOnly
        else
          if validUser && validGroup && userById == userByName && groupById == groupByName
            then do
              (status, groups) <- command "/usr/bin/id" ["-G", Text.unpack name]
              unless (status == ExitSuccess && either (const False) ((== [uid]) . Text.words) (Encoding.decodeUtf8' groups)) (abort ProvisionRefused)
              pure IdentityReady
            else abort ProvisionRefused

createNativeIdentity :: IO (Either ProvisionError ()) -> ProcessProfile -> IO (Either ProvisionError ())
createNativeIdentity authorize profile = protect do
  let uid = show profile.userId
      name = Text.unpack (managedName profile)
      effect executable arguments = do
        authorize >>= either abort pure
        (status, _) <- command executable arguments
        unless (status == ExitSuccess) (abort ProvisionUnresolved)
  state <- inspectNativeIdentity profile >>= either abort pure
  when (state == IdentityMissing) (effect "/usr/sbin/groupadd" ["--gid", uid, name])
  current <- inspectNativeIdentity profile >>= either abort pure
  when (current == IdentityGroupOnly) (effect "/usr/sbin/useradd" ["--system", "--uid", uid, "--gid", uid, "--no-create-home", "--no-user-group", "--home-dir", "/var/empty", "--shell", "/usr/sbin/nologin", "--comment", Text.unpack (managedComment profile), name])
  final <- inspectNativeIdentity profile >>= either abort pure
  unless (final == IdentityReady) (abort ProvisionUnresolved)

command :: FilePath -> [String] -> IO (ExitCode, Bytes.ByteString)
command executable arguments = do
  result <- timeout 5000000 $ withFile "/dev/null" WriteMode \sink ->
    withCreateProcess ((proc executable arguments) {env = Just [("PATH", "/usr/bin:/bin"), ("LANG", "C")], close_fds = True, std_in = NoStream, std_out = CreatePipe, std_err = UseHandle sink}) \_ output _ process -> case output of
      Nothing -> abort ProvisionUnavailable
      Just handle -> do
        bytes <- Bytes.hGet handle 4097
        when (Bytes.length bytes > 4096) (abort ProvisionUnresolved)
        status <- waitForProcess process
        pure (status, bytes)
  maybe (abort ProvisionUnresolved) pure result

transact :: ProvisionRuntime -> Transaction a -> IO a
transact runtime action = runAppIO runtime.appEnv (runTransaction action) >>= either (const (abort ProvisionUnavailable)) pure

needFile :: Either FileError () -> IO ()
needFile = either (const (abort ProvisionUnavailable)) pure

abort :: ProvisionError -> IO a
abort = throwIO . ProvisionAbort

protect :: IO a -> IO (Either ProvisionError a)
protect work = catch (catch (Right <$> work) (\(ProvisionAbort err) -> pure (Left err))) (\(_ :: IOException) -> pure (Left ProvisionUnresolved))
