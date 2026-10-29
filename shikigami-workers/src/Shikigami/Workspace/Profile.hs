-- | Resolve only the rules retained before assignment admission. Current
-- operator defaults cannot reinterpret an accepted rule after restart.
module Shikigami.Workspace.Profile (retainedProcessRule, retainedFileProfile, retainedSystemdProfile, profileStorageSafe) where

import Data.Text qualified as Text
import Kioku.App (AppEnv, runAppIO)
import Kiroku.Store.Transaction (runTransaction)
import Shikigami.Prelude
import Shikigami.Workspace.Instructions
import Shikigami.Workspace.Process
import Shikigami.Workspace.ProcessPolicy
import Shikigami.Workspace.ProcessProfileStore
import Shikigami.Workspace.Systemd qualified as Systemd
import Shikigami.Workspace.Types

retainedSystemdProfile :: ProcessProfile -> IO (Either Text Systemd.SystemdProfile)
retainedSystemdProfile profile = do
  properties <- Systemd.systemdPropertiesIdentity
  let image = profile.policy.image
  pure do
    unless (validProcessProfile profile && profile.policy.propertiesDigest == properties) (Left "workspace process profile is unavailable")
    pure (Systemd.SystemdProfile image.rootDirectory image.rootIdentity image.environmentExecutable image.deadlineExecutable image.collectorExecutable profile.userId profile.groupId)

retainedProcessRule :: AppEnv -> WorkspaceBinding -> WorkspaceAdmission -> Text -> IO (Either Text (ProcessCommand, Systemd.SystemdProfile))
retainedProcessRule appEnv binding admission rule = do
  retained <- retainedFileProfile appEnv binding admission
  case retained of
    Left err -> pure (Left err)
    Right profile -> do
      systemd <- retainedSystemdProfile profile
      case systemd of
        Left err -> pure (Left err)
        Right selected -> do
          identity <- Systemd.systemdProfileIdentity selected
          pure $ maybe (Left "workspace process rule is unavailable") (\command -> Right (command, selected)) (processPolicyCommand profile.policy identity rule)

retainedFileProfile :: AppEnv -> WorkspaceBinding -> WorkspaceAdmission -> IO (Either Text ProcessProfile)
retainedFileProfile appEnv binding admission = do
  retained <- runAppIO appEnv (runTransaction (inspectProcessProfileTx binding.workspace))
  case retained of
    Right (Just (profile, ProfileReady))
      | profile.bindingDigest == workspaceBindingDigest binding && admission.bindingDigest == profile.bindingDigest && profile.instructionDigest == bundleDigest admission.instructions && binding.policyRevision == processPolicyIdentity profile.policy && admission.filePolicy == Just supervisedFilePolicy && profileStorageSafe binding profile -> do
          systemd <- retainedSystemdProfile profile
          case systemd of
            Left err -> pure (Left err)
            Right _ -> pure (Right profile)
    _ -> pure (Left "workspace process rule is unavailable")

outsideStorage :: FilePath -> FilePath -> Bool
outsideStorage root path = value /= parent && not ((parent <> "/") `Text.isPrefixOf` value)
  where
    parent = Text.dropWhileEnd (== '/') (Text.pack root)
    value = Text.pack path

profileStorageSafe :: WorkspaceBinding -> ProcessProfile -> Bool
profileStorageSafe binding profile = all (outsideStorage binding.storageRoot) [profile.policy.image.rootDirectory, profile.policy.image.collectorExecutable]
