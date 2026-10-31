-- | Discover instructions from the pinned immutable Git tree, never from the
-- mutable worktree. Callers retain the resulting bundle in protected snapshots.
module Shikigami.Workspace.InstructionLoader (loadRepositoryInstructions, loadWorkspaceAdmission) where

import Data.ByteString qualified as Bytes
import Data.ByteString.Char8 qualified as Char8
import Data.List (inits)
import Data.Set qualified as Set
import Data.Text qualified as Text
import Data.Text.Encoding qualified as Encoding
import Shikigami.Execution.AssignmentKey (AssignmentKey)
import Shikigami.Workspace.Allocation (workspaceMetadata)
import Shikigami.Workspace.Git (runWorkspaceGit)
import Shikigami.Workspace.Instructions
import Shikigami.Workspace.Types
import Text.Read (readMaybe)

loadRepositoryInstructions :: WorkspaceBinding -> Int -> IO (Either InstructionError InstructionBundle)
loadRepositoryInstructions = loadInstructions False

loadInstructions :: Bool -> WorkspaceBinding -> Int -> IO (Either InstructionError InstructionBundle)
loadInstructions qualifyFiles binding budget = do
  listing <- git 1048576 ["ls-tree", "-r", "-l", "-z", Text.unpack binding.base]
  case listing >>= parseListing of
    Left err -> pure (Left err)
    Right entries
      | budget < 0 || length entries > 64 || sum [size | (_, size) <- entries] > toInteger (min 65536 budget) -> pure (Left InstructionBudgetExceeded)
      | otherwise -> do
          bodies <- traverse load entries
          pure (sequence bodies >>= mkInstructionBundle budget binding.repository binding.base)
  where
    git limit args = either (const (Left InstructionSourceRefused)) Right <$> runWorkspaceGit binding.storageRoot limit (["--git-dir=" <> workspaceMetadata binding.storageRoot binding] <> args)
    load (path, size) = do
      body <- git (fromInteger size) ["cat-file", "blob", Text.unpack binding.base <> ":" <> Text.unpack path]
      pure do
        bytes <- body
        if toInteger (Bytes.length bytes) /= size
          then Left InstructionSourceRefused
          else do
            text <- either (const (Left InstructionSourceRefused)) Right (Encoding.decodeUtf8' bytes)
            pure (path, text)
    parseListing bytes = do
      let records = filter (not . Bytes.null) (Bytes.split 0 bytes)
      paths <- traverse listingPath records
      let prefixes = Set.fromList [Text.intercalate "/" prefix | path <- paths, prefix <- drop 1 (inits (Text.splitOn "/" path))]
      -- A portable workspace cannot faithfully distinguish case-colliding Git
      -- paths/scopes on macOS. Refuse the base rather than merge their policies.
      if (qualifyFiles && not (all (\path -> validWorkspacePath path && Text.all (< '\DEL') path) paths)) || Set.size (Set.map Text.toCaseFold prefixes) /= Set.size prefixes
        then Left InstructionSourceRefused
        else fmap concat (traverse entry records)
    listingPath raw = case Bytes.break (== 9) raw of
      (_, suffix) | Bytes.null suffix -> Left InstructionSourceRefused
      (_, suffix) -> either (const (Left InstructionSourceRefused)) Right (Encoding.decodeUtf8' (Bytes.drop 1 suffix))
    entry raw = do
      let (metadata, suffix) = Bytes.break (== 9) raw
      if Bytes.null suffix
        then Left InstructionSourceRefused
        else do
          path <- either (const (Left InstructionSourceRefused)) Right (Encoding.decodeUtf8' (Bytes.drop 1 suffix))
          if snd (Text.breakOnEnd "/" path) /= "AGENTS.md"
            then Right []
            else case Char8.words metadata of
              [mode, "blob", _, encodedSize] | mode `elem` ["100644", "100755"] -> case readMaybe (Char8.unpack encodedSize) of
                Just size | size >= (0 :: Integer) -> Right [(path, size)]
                _ -> Left InstructionSourceRefused
              _ -> Left InstructionSourceRefused

-- | Content loading after trusted provider admission. This does not grant
-- lifecycle, replay, read or write authority; the provider supplies retained
-- binding and execution-assignment coordinates outside model arguments.
loadWorkspaceAdmission :: WorkspaceBinding -> AssignmentKey -> Int -> IO (Either InstructionError WorkspaceAdmission)
loadWorkspaceAdmission binding assignmentId budget = do
  loaded <- loadInstructions True binding budget
  pure ((\bundle -> WorkspaceAdmission binding.workspace (workspaceBindingDigest binding) binding.request.runId assignmentId binding.request.rootId binding.request.owner binding.request.epoch bundle (Just nativeFilePolicy)) <$> loaded)
