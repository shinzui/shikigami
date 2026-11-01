{-# LANGUAGE DataKinds #-}
{-# LANGUAGE ForeignFunctionInterface #-}

-- | Trusted system-service transport, not an execution-authority boundary.
-- The supervisor must commit its single launch transition, hold the workspace
-- lock and recheck actual claims, lifecycle, exact authorization and ownership.
module Shikigami.Workspace.Systemd
  ( SystemdError (..),
    SystemdProfile (..),
    systemdProperties,
    systemdPropertiesIdentity,
    systemdProfileIdentity,
    processArguments,
    collectorArguments,
    startProcess,
    startCollector,
    systemdBootIdentity,
    collectorActive,
    stopProcess,
  )
where

import Control.Exception (IOException, catch)
import Data.Aeson qualified as Aeson
import Data.ByteString qualified as Bytes
import Data.Map.Strict qualified as Map
import Data.Text qualified as Text
import Data.Text.Encoding qualified as Encoding
import Data.Time (diffUTCTime)
import Data.Time.Clock.POSIX (utcTimeToPOSIXSeconds)
import Foreign.C
import Shikigami.Decision.Contract (versionedDigest)
import Shikigami.Prelude
import Shikigami.Workspace.ContainedFile
import Shikigami.Workspace.Process
import Shikigami.Workspace.ProcessPolicy (immutableHelper)
import Shikigami.Workspace.Value
import System.Directory (doesFileExist)
import System.Exit (ExitCode (..))
import System.IO (IOMode (..), withBinaryFile, withFile)
import System.Info qualified as Platform
import System.Posix.User (getEffectiveUserID)
import System.Process (CreateProcess (..), StdStream (..), proc, waitForProcess, withCreateProcess)
import System.Timeout (timeout)

data SystemdError = SystemdUnsupported | SystemdRefused | SystemdUncertain
  deriving stock (Eq, Show)

-- Operator-built immutable root and workspace-specific unprivileged identity.
-- No caller of the eventual socket protocol may choose these paths or ids.
data SystemdProfile = SystemdProfile
  { rootDirectory :: !(WorkspaceLocator "image-root"),
    rootIdentity :: !(WorkspaceCoordinate "image-digest"),
    environmentExecutable :: !(WorkspaceLocator "environment-executable"),
    deadlineExecutable :: !(WorkspaceLocator "deadline-executable"),
    collectorExecutable :: !(WorkspaceLocator "collector-executable"),
    userId :: !(WorkspaceIdentity),
    groupId :: !(WorkspaceIdentity)
  }
  deriving stock (Generic)

instance Show SystemdProfile where show _ = "SystemdProfile <protected>"

foreign import ccall unsafe "shikigami_workspace_systemd_profile" profileBytes :: IO CString

foreign import ccall safe "shikigami_workspace_stop" stopUnit :: CString -> CString -> CString -> CString -> IO CInt

-- Root controls may stop previously admitted work without reviving its actor's
-- authority. A successful stop request supplies no completion or fencing proof.
stopProcess :: ProcessRecord -> IO (Either SystemdError ())
stopProcess record = guarded record do
  if record.unit /= processUnit record.operationId record.fingerprint || not (digestText (workspaceCoordinateText record.fingerprint)) || record.phase `notElem` [ProcessLaunchRequested, ProcessRunning, ProcessUnresolved]
    then pure (Left SystemdRefused)
    else withCString (Text.unpack (workspaceCoordinateText record.unit)) \unit ->
      withCString (Text.unpack (workspaceCoordinateText record.fingerprint)) \fingerprint ->
        withCString (Text.unpack (maybe "" workspaceCoordinateText record.bootId)) \boot ->
          withCString (Text.unpack (maybe "" workspaceCoordinateText record.invocationId)) \invocation -> do
            result <- stopUnit unit fingerprint boot invocation
            pure (if result == 0 then Right () else Left SystemdUncertain)

systemdProperties :: IO [Text]
systemdProperties = do
  body <- profileBytes >>= Bytes.packCString
  -- This is a compiled-in, shared qualification asset, not external JSON.
  either (const (ioError (userError "invalid compiled workspace profile"))) pure (Aeson.eitherDecodeStrict body)

systemdProfileIdentity :: SystemdProfile -> IO (WorkspaceCoordinate "process-profile")
systemdProfileIdentity profile = do
  properties <- systemdProperties
  pure (workspaceCoordinate (versionedDigest "shikigami.workspace-systemd-profile/2" (toJSON (profile.rootDirectory, profile.rootIdentity, profile.environmentExecutable, profile.deadlineExecutable, profile.collectorExecutable, profile.userId, profile.groupId, properties))))

systemdPropertiesIdentity :: IO (WorkspaceCoordinate "process-properties")
systemdPropertiesIdentity = workspaceCoordinate . versionedDigest "shikigami.workspace-systemd-properties/2" . toJSON <$> systemdProperties

-- Status is diagnostic liveness only, never proof that the command settled.
-- Lost/failed capture retains uncertainty even if systemd stopped the command.
collectorActive :: ProcessRecord -> IO (Either SystemdError Bool)
collectorActive record = guarded record do
  if record.unit /= processUnit record.operationId record.fingerprint
    then pure (Left SystemdRefused)
    else do
      result <- timeout 3000000 $ withFile "/dev/null" WriteMode \sink ->
        withCreateProcess
          ( (proc "/usr/bin/systemctl" ["show", "--value", "--property=ActiveState", "--", Text.unpack (captureUnit record)])
              { env = Just [("PATH", "/usr/bin:/bin"), ("LANG", "C")],
                close_fds = True,
                std_in = NoStream,
                std_out = CreatePipe,
                std_err = UseHandle sink
              }
          )
          ( \_ output _ process -> case output of
              Nothing -> pure Nothing
              Just handle -> do
                body <- Bytes.hGet handle 65
                if Bytes.length body > 64
                  then pure Nothing
                  else do
                    status <- waitForProcess process
                    pure (if status == ExitSuccess then Just body else Nothing)
          )
      pure case result of
        Just (Just body) | body `elem` ["active\n", "activating\n"] -> Right True
        Just (Just body) | body `elem` ["inactive\n", "deactivating\n", "failed\n"] -> Right False
        _ -> Left SystemdUncertain

-- Return argv without invoking a shell or interpolating command text. A clean
-- environment is constructed inside the immutable root, rather than relying on
-- the service manager's operator-configured DefaultEnvironment.
processArguments :: UTCTime -> SystemdProfile -> FilePath -> FilePath -> FilePath -> ProcessRecord -> IO (Either SystemdError [String])
processArguments now profile files scratch metadata record = do
  properties <- systemdProperties
  identity <- systemdProfileIdentity profile
  pure do
    remaining <- remainingSeconds now record
    unless (validProfile profile && all safeAbsolute [files, scratch, metadata] && record.command.profile == identity && validLaunchRecord record && safeDirectory (workspaceCoordinateText record.command.directory) && safeAbsolute (Text.unpack (workspaceCoordinateText record.command.executable))) (Left SystemdRefused)
    let cwd = "/workspace" <> if Text.null (workspaceCoordinateText record.command.directory) then "" else "/" <> (workspaceCoordinateText record.command.directory)
        dynamic =
          [ "RootDirectory=" <> Text.pack (workspaceLocatorPath profile.rootDirectory),
            "User=" <> tshow profile.userId,
            "Group=" <> tshow profile.groupId,
            "BindPaths=" <> Text.pack files <> ":/workspace " <> Text.pack scratch <> ":/scratch",
            "WorkingDirectory=" <> cwd,
            "RuntimeMaxSec=" <> tshow remaining,
            "Description=shikigami-workspace/1 " <> (workspaceCoordinateText record.fingerprint),
            "StandardOutput=file:" <> Text.pack metadata <> "/stdout.pipe",
            "StandardError=file:" <> Text.pack metadata <> "/stderr.pipe"
          ]
        environment = [workspaceCoordinateText key <> "=" <> workspaceCoordinateText value | (key, value) <- Map.toAscList record.command.environment]
    pure
      ( map
          Text.unpack
          ( ["--quiet", "--no-ask-password", "--expand-environment=no", "--unit=" <> (workspaceCoordinateText record.unit)]
              <> concatMap (\property -> ["--property", property]) (properties <> dynamic)
              <> ["--", Text.pack (workspaceLocatorPath profile.deadlineExecutable), "1", tshow (floor (utcTimeToPOSIXSeconds record.deadline * 1000000000) :: Integer), "--", Text.pack (workspaceLocatorPath profile.environmentExecutable), "-i"]
              <> environment
              <> [(workspaceCoordinateText record.command.executable)]
              <> map workspaceCoordinateText record.command.arguments
          )
      )

collectorArguments :: UTCTime -> SystemdProfile -> FilePath -> ProcessRecord -> Either SystemdError [String]
collectorArguments now profile metadata record = do
  _ <- remainingSeconds now record
  unless (validProfile profile && safeAbsolute metadata && validLaunchRecord record) (Left SystemdRefused)
  let watchdog = processSecondsNumber record.command.timeoutSeconds + 30
      name = captureUnit record
      properties =
        [ "Type=exec",
          "TimeoutStartSec=5",
          "Restart=no",
          "RuntimeMaxSec=" <> tshow (watchdog + 10),
          "StandardOutput=null",
          "StandardError=null",
          "Description=shikigami-capture/1 " <> (workspaceCoordinateText record.fingerprint),
          "LimitCORE=0",
          "NoNewPrivileges=yes",
          "CapabilityBoundingSet=",
          "ProtectSystem=strict",
          "ReadWritePaths=" <> Text.pack metadata,
          "PrivateNetwork=yes",
          "RestrictAddressFamilies=AF_UNIX"
        ]
  pure
    ( map
        Text.unpack
        ( ["--quiet", "--no-ask-password", "--expand-environment=no", "--unit=" <> name]
            <> concatMap (\property -> ["--property", property]) properties
            <> ["--", Text.pack (workspaceLocatorPath profile.collectorExecutable), Text.pack metadata, (workspaceCoordinateText record.unit), (workspaceCoordinateText record.fingerprint), tshow record.command.outputBytes, tshow watchdog]
        )
    )

startCollector :: SystemdProfile -> FilePath -> ProcessRecord -> IO (Either SystemdError ())
startCollector profile metadata record = guarded record do
  now <- getCurrentTime
  case collectorArguments now profile metadata record of
    Left err -> pure (Left err)
    Right arguments -> do
      private <- checkPrivateDirectory metadata
      ready <- withContainedFile metadata "ready" (readContainedFile 2)
      case (private, ready) of
        (Right (), Right Nothing) -> transport arguments
        _ -> pure (Left SystemdRefused)

-- Starting the capture service is separate from command launch. The supervisor
-- waits for this private ready marker before issuing its single command start.
startProcess :: SystemdProfile -> FilePath -> FilePath -> FilePath -> ProcessRecord -> IO (Either SystemdError ())
startProcess profile files scratch metadata record = guarded record do
  now <- getCurrentTime
  arguments <- processArguments now profile files scratch metadata record
  case arguments of
    Left err -> pure (Left err)
    Right argv -> do
      private <- checkPrivateDirectory metadata
      ready <- withContainedFile metadata "ready" (readContainedFile 2)
      case (private, ready) of
        (Right (), Right (Just "1\n")) -> transport argv
        _ -> pure (Left SystemdRefused)

-- Missing backend support is a bounded refusal. This check does not replace
-- qualification of the effective profile or confer authority on the caller.
systemdBootIdentity :: IO (Either SystemdError (WorkspaceCoordinate "boot-id"))
systemdBootIdentity
  | Platform.os /= "linux" = pure (Left SystemdUnsupported)
  | otherwise = catch work (\(_ :: IOException) -> pure (Left SystemdUnsupported))
  where
    work = do
      uid <- getEffectiveUserID
      cgroup <- doesFileExist "/sys/fs/cgroup/cgroup.controllers"
      bytes <- withBinaryFile "/proc/sys/kernel/random/boot_id" ReadMode (\handle -> Bytes.hGet handle 38)
      pure do
        body <- either (const (Left SystemdUnsupported)) Right (Encoding.decodeUtf8' bytes)
        unless (uid == 0 && cgroup && Text.length body == 37 && Text.last body == '\n' && hostIdentity (Text.init body)) (Left SystemdUnsupported)
        pure (workspaceCoordinate (Text.init body))

guarded :: ProcessRecord -> IO (Either SystemdError a) -> IO (Either SystemdError a)
guarded record work = catch action (\(_ :: IOException) -> pure (Left SystemdUncertain))
  where
    action = do
      boot <- systemdBootIdentity
      case boot of
        Left err -> pure (Left err)
        Right current | record.bootId == Just current -> work
        _ -> pure (Left SystemdRefused)

transport :: [String] -> IO (Either SystemdError ())
transport arguments = do
  result <- timeout 5000000 $ withFile "/dev/null" WriteMode \sink ->
    withCreateProcess
      ((proc "/usr/bin/systemd-run" arguments) {env = Just [("PATH", "/usr/bin:/bin"), ("LANG", "C")], close_fds = True, std_in = NoStream, std_out = UseHandle sink, std_err = UseHandle sink})
      (\_ _ _ process -> waitForProcess process)
  -- Any transport failure may follow acceptance by systemd. Never grant a new
  -- launch on this result; reconciliation observes only the original record.
  pure (if result == Just ExitSuccess then Right () else Left SystemdUncertain)

remainingSeconds :: UTCTime -> ProcessRecord -> Either SystemdError Int
remainingSeconds now record = do
  let remaining = floor (diffUTCTime record.deadline now) :: Integer
  unless (remaining >= 1 && remaining <= toInteger (processSecondsNumber record.command.timeoutSeconds)) (Left SystemdRefused)
  pure (fromInteger remaining)

validLaunchRecord :: ProcessRecord -> Bool
validLaunchRecord record = validProcessCommand record.command && maybe False validProcessRouting record.routing && digestText (workspaceCoordinateText record.fingerprint) && record.unit == processUnit record.operationId record.fingerprint && record.phase == ProcessLaunchRequested && maybe False (hostIdentity . workspaceCoordinateText) record.bootId && isNothing record.invocationId && isNothing record.receipt

validProfile :: SystemdProfile -> Bool
validProfile profile = all safeAbsolute [workspaceLocatorPath profile.rootDirectory, workspaceLocatorPath profile.collectorExecutable, workspaceLocatorPath profile.environmentExecutable, workspaceLocatorPath profile.deadlineExecutable] && all (immutableHelper . Text.pack) [workspaceLocatorPath profile.environmentExecutable, workspaceLocatorPath profile.deadlineExecutable] && digestText (workspaceCoordinateText profile.rootIdentity) && workspaceIdentityNumber profile.userId > 0 && workspaceIdentityNumber profile.groupId > 0

safeAbsolute :: FilePath -> Bool
safeAbsolute path = case Text.stripPrefix "/" (Text.pack path) of
  Just relative -> not (Text.null relative) && safeDirectory relative && not (Text.null (Text.takeWhileEnd (/= '/') relative))
  Nothing -> False

safeDirectory :: Text -> Bool
safeDirectory path = Text.null path || (all (\part -> not (Text.null part) && part `notElem` [".", ".."] && Text.toCaseFold part /= ".git") (Text.splitOn "/" path) && Text.all (\c -> (c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z') || (c >= '0' && c <= '9') || c `elem` ("/._-" :: String)) path)

tshow :: (Show a) => a -> Text
tshow = Text.pack . show

captureUnit :: ProcessRecord -> Text
captureUnit record = "shikigami-capture-" <> Text.drop (Text.length ("shikigami-workspace-" :: Text)) (workspaceCoordinateText record.unit)
