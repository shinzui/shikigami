{-# LANGUAGE DataKinds #-}

-- | Capture inputs only after exact admission and settlement. This module is
-- not a capability adapter and cannot publish a commit or grant a process fence.
module Shikigami.Workspace.GitCapture (CapturedTree (..), captureGitTree) where

import Control.Exception (IOException, catch)
import Control.Monad (foldM)
import Data.ByteString qualified as Bytes
import Data.Text (Text)
import Shikigami.Prelude (Generic)
import Shikigami.Workspace.Allocation (workspaceFiles, workspaceMetadata)
import Shikigami.Workspace.ContainedFile
import Shikigami.Workspace.GitObjects
import Shikigami.Workspace.ProcessPolicy
import Shikigami.Workspace.Systemd (systemdBootIdentity)
import Shikigami.Workspace.Types
import Shikigami.Workspace.Value
import System.Timeout (timeout)

data CapturedTree = CapturedTree {target :: !(WorkspaceCoordinate "file-target"), tree :: !(WorkspaceCoordinate "git-object"), paths :: !([WorkspaceCoordinate "relative-path"])}
  deriving stock (Eq, Generic)

-- The caller holds the workspace lock and settled-process barrier throughout,
-- and has obtained fresh whole-tree C13 for expectedTarget. The path callback
-- enforces the frozen scoped instruction/operator policy before content reads.
-- V1 requires whole-tree read scope; changed paths still need separate write
-- admission before a commit is planned or HEAD can be published.
captureGitTree :: WorkspaceBinding -> ProcessProfile -> WorkspaceCoordinate "file-target" -> (WorkspaceCoordinate "relative-path" -> IO (Either WorkspaceError ())) -> IO (Either WorkspaceError CapturedTree)
captureGitTree binding profile expectedTarget admitPath = catch bounded (\(_ :: IOException) -> pure refused)
  where
    bounded = maybe refused id <$> timeout 60000000 capture
    capture = do
      host <- systemdBootIdentity
      case host of
        Left _ -> pure refused
        Right _ | not (validProcessProfile profile && profile.bindingDigest == workspaceBindingDigest binding && processPolicyIdentity profile.policy == binding.policyRevision && workspaceCoordinate "" `elem` profile.policy.readPaths) -> pure refused
        Right _ -> do
          root <- checkPrivateDirectory (workspaceLocatorPath binding.storageRoot)
          metadata <- checkPrivateDirectory (workspaceMetadata (workspaceLocatorPath binding.storageRoot) binding)
          case root >> metadata of
            Left _ -> pure refused
            Right () -> flatten <$> withContainedFile (workspaceFiles (workspaceLocatorPath binding.storageRoot) binding) ".shikigami-git-target" (\anchor -> Right <$> captureRoot anchor)
    captureRoot anchor = do
      before <- containedTargetIdentity anchor
      if before /= Right (workspaceCoordinateText expectedTarget)
        then pure refused
        else do
          listed <- listContainedFiles (workspaceIdentityNumber profile.userId) anchor
          case listed of
            Left _ -> pure refused
            Right entries -> do
              allowed <- sequence <$> traverse (admitPath . workspaceCoordinate . fst) entries
              case allowed of
                Left err -> pure (Left err)
                Right _ -> do
                  objects <- foldM readEntry (Right (0, [])) entries
                  case objects of
                    Left err -> pure (Left err)
                    Right (_, blobs) -> do
                      after <- withContainedFile (workspaceFiles (workspaceLocatorPath binding.storageRoot) binding) ".shikigami-git-target" containedTargetIdentity
                      if after /= before
                        then pure refused
                        else do
                          tree <- storeFlatTree (workspaceMetadata (workspaceLocatorPath binding.storageRoot) binding) (reverse blobs)
                          pure ((\object -> CapturedTree expectedTarget object (map (workspaceCoordinate . fst) entries)) <$> tree)
    readEntry (Left err) _ = pure (Left err)
    readEntry (Right (total, previous)) (path, executable) = do
      captured <- withContainedFile (workspaceFiles (workspaceLocatorPath binding.storageRoot) binding) path (readContainedGitBlob (min 16777216 (67108864 - total)))
      case captured of
        Right (Just bytes) | total + Bytes.length bytes <= 67108864 -> do
          blob <- storeBlob (workspaceMetadata (workspaceLocatorPath binding.storageRoot) binding) bytes
          pure do
            object <- blob
            pure (total + Bytes.length bytes, GitEntry (workspaceCoordinate path) (if executable then GitExecutable else GitRegular) object : previous)
        _ -> pure refused
    flatten value = either (const refused) id value
    refused = Left WorkspaceAllocationRefused
