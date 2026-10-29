-- | Trusted allocation only. The private provider root must be operator-owned
-- and inaccessible to workspace processes. No tool may select these paths.
module Shikigami.Workspace.Allocation (allocateWorkspace, allocateWorkspaceWithCheckpoint, workspaceFiles, workspaceMetadata) where

import Control.Exception (IOException, catch)
import Data.Aeson qualified as Aeson
import Data.ByteString.Char8 qualified as Char8
import Data.ByteString.Lazy qualified as Lazy
import Data.Text qualified as Text
import Data.UUID qualified as UUID
import Data.UUID.V4 qualified as UUID
import Shikigami.Decision.Contract (versionedDigest)
import Shikigami.WorkerSession.Transfer (WorkspaceRef (..))
import Shikigami.Workspace.Git (runWorkspaceGit)
import Shikigami.Workspace.Types
import System.Directory
import System.Exit (ExitCode (..))
import System.FilePath (isAbsolute, (</>))

workspaceFiles :: FilePath -> WorkspaceBinding -> FilePath
workspaceFiles root binding = root </> Text.unpack binding.workspace.resource </> "files"

workspaceMetadata :: FilePath -> WorkspaceBinding -> FilePath
workspaceMetadata root binding = root </> Text.unpack binding.workspace.resource </> "metadata"

-- | Populate a fresh staging directory and atomically publish it. Interrupted
-- staging directories are never exposed or reused. A duplicate publication
-- verifies the retained marker and cannot reset already accepted edits.
-- The caller must reserve in Store first and mark ready only after this returns.
allocateWorkspace :: FilePath -> WorkspaceBinding -> AllocationState -> IO (Either WorkspaceError ())
allocateWorkspace = allocateWorkspaceWithCheckpoint (pure ())

-- | Fault-injection boundary after the private copy is complete and before it
-- becomes visible. An asynchronous worker interruption leaves only staging.
allocateWorkspaceWithCheckpoint :: IO () -> FilePath -> WorkspaceBinding -> AllocationState -> IO (Either WorkspaceError ())
allocateWorkspaceWithCheckpoint checkpoint root binding state = catch work (\(_ :: IOException) -> pure (Left WorkspaceAllocationRefused))
  where
    destination = root </> Text.unpack binding.workspace.resource
    marker = "allocation.json"
    receipt = Aeson.toJSON (versionedDigest "shikigami.workspace-allocation/1" (Aeson.toJSON binding))
    work
      | root == "/" || binding.source == "/" || root /= binding.storageRoot || not (isAbsolute root) || binding.workspace.provider /= "shikigami.workspace/1" || not (safeResource binding.workspace.resource) = pure (Left WorkspaceAllocationRefused)
      | otherwise = do
          canonical <- canonicalizePath root
          source <- canonicalizePath binding.source
          if canonical /= root || source /= binding.source || root == source || Text.pack (source <> "/") `Text.isPrefixOf` Text.pack (root <> "/")
            then pure (Left WorkspaceAllocationRefused)
            else do
              createDirectoryIfMissing True root
              exists <- doesPathExist destination
              if exists then verify else if state == Ready then pure (Left WorkspaceAllocationRefused) else populate
    verify = do
      linked <- pathIsSymbolicLink destination
      markerLinked <- pathIsSymbolicLink (destination </> marker)
      if linked || markerLinked
        then pure (Left WorkspaceAllocationRefused)
        else do
          actual <- Aeson.decode <$> Lazy.readFile (destination </> marker)
          pure (if actual == Just receipt then Right () else Left WorkspaceBindingConflict)
    populate = do
      -- Verify the exact object type before allocating any mutable repository.
      (status, kind, _) <- git ["-C", binding.source, "cat-file", "-t", Text.unpack binding.base]
      if status /= ExitSuccess || kind /= "commit\n"
        then pure (Left WorkspaceAllocationRefused)
        else do
          nonce <- UUID.toText <$> UUID.nextRandom
          let staging = root </> ("staging-" <> Text.unpack nonce)
              metadata = staging </> "metadata"
              files = staging </> "files"
          createDirectory staging
          (cloned, _, _) <- git ["clone", "--bare", "--no-hardlinks", "--dissociate", "--", binding.source, metadata]
          if cloned /= ExitSuccess
            then pure (Left WorkspaceAllocationRefused)
            else do
              createDirectory files
              (checked, _, _) <- git ["--git-dir=" <> metadata, "--work-tree=" <> files, "checkout", "--force", "--detach", Text.unpack binding.base]
              if checked /= ExitSuccess
                then pure (Left WorkspaceAllocationRefused)
                else do
                  checkpoint
                  Lazy.writeFile (staging </> marker) (Aeson.encode receipt)
                  catch (renameDirectory staging destination >> pure (Right ())) (\(_ :: IOException) -> verify)
    safeResource value = not (Text.null value) && Text.length value <= 128 && Text.all (\c -> (c >= '0' && c <= '9') || (c >= 'a' && c <= 'f')) value
    git args = runWorkspaceGit root 65536 args >>= pure . either (const (ExitFailure 1, "", "")) (\bytes -> (ExitSuccess, Char8.unpack bytes, ""))
