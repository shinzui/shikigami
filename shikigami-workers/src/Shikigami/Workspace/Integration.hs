{-# LANGUAGE DataKinds #-}

-- | Conservative three-way integration of exact immutable artifacts. The
-- accepted provider owns authority and locks; this primitive never edits a
-- worktree, index or HEAD. Unsupported deltas refuse rather than invoke Git
-- merge drivers, filters, hooks, transport or repository code.
module Shikigami.Workspace.Integration (Artifact (..), Request (..), schema, validRequest, mergeManifests, planIntegration) where

import Control.Exception (Exception, catch, throwIO)
import Data.Aeson ((.=))
import Data.Aeson qualified as Aeson
import Data.ByteString.Lazy qualified as Lazy
import Data.Generics.Labels ()
import Data.List (nub)
import Data.Map.Strict qualified as Map
import Data.Set qualified as Set
import Data.Text qualified as Text
import Data.Text.Encoding qualified as Encoding
import Shikigami.Execution.Identity (OperationId, operationIdText)
import Shikigami.Prelude hiding ((.=))
import Shikigami.Workspace.Allocation (workspaceMetadata)
import Shikigami.Workspace.GitObjects qualified as Objects
import Shikigami.Workspace.GitTypes
import Shikigami.Workspace.Provider (Replacement (..), contentDigest)
import Shikigami.Workspace.Types
import Shikigami.Workspace.Value

data Artifact = Artifact {operationId :: !OperationId, bindingDigest :: !(WorkspaceCoordinate "binding-digest"), base :: !(WorkspaceCoordinate "git-object"), revision :: !(WorkspaceCoordinate "git-object")}
  deriving stock (Eq, Generic)
  deriving anyclass (ToJSON)

instance Show Artifact where show _ = "Artifact <protected>"

instance FromJSON Artifact where parseJSON = Aeson.genericParseJSON Aeson.defaultOptions {Aeson.rejectUnknownFields = True}

data Request = Request {expectedParent :: !(WorkspaceCoordinate "git-object"), artifacts :: ![Artifact]}
  deriving stock (Eq, Generic)
  deriving anyclass (ToJSON)

instance Show Request where show _ = "IntegrationRequest <protected>"

instance FromJSON Request where parseJSON = Aeson.genericParseJSON Aeson.defaultOptions {Aeson.rejectUnknownFields = True}

schema :: Aeson.Value
schema = Aeson.object ["type" .= ("object" :: Text), "properties" .= Aeson.object ["expectedParent" .= objectId, "artifacts" .= Aeson.object ["type" .= ("array" :: Text), "minItems" .= (2 :: Int), "maxItems" .= (8 :: Int), "items" .= Aeson.object ["type" .= ("object" :: Text), "properties" .= Aeson.object ["operationId" .= string, "bindingDigest" .= string, "base" .= objectId, "revision" .= objectId], "required" .= ["operationId", "bindingDigest", "base", "revision" :: Text], "additionalProperties" .= False]]], "required" .= ["expectedParent", "artifacts" :: Text], "additionalProperties" .= False]
  where
    string = Aeson.object ["type" .= ("string" :: Text), "maxLength" .= (256 :: Int)]
    objectId = Aeson.object ["type" .= ("string" :: Text), "pattern" .= ("^[a-f0-9]{40}([a-f0-9]{24})?$" :: Text)]

validRequest :: Request -> Bool
validRequest request = validGitObject (workspaceCoordinateText request.expectedParent) && length request.artifacts >= 2 && length request.artifacts <= 8 && length (nub (map (.operationId) request.artifacts)) == length request.artifacts && all valid request.artifacts
  where
    valid artifact = let operation = operationIdText artifact.operationId in not (Text.null operation) && Text.length operation <= 256 && Text.length (workspaceCoordinateText artifact.bindingDigest) <= 256 && all (validGitObject . workspaceCoordinateText) [artifact.base, artifact.revision]

-- A source contributes its delta against the common base. Equal overlapping
-- deltas converge; unequal overlapping deltas are reported without any writes.
mergeManifests :: [Objects.GitEntry] -> [Objects.GitEntry] -> [[Objects.GitEntry]] -> Either [WorkspaceCoordinate "relative-path"] [Objects.GitEntry]
mergeManifests common target workers =
  let original = manifest common
      (combined, conflicts) = foldl' (apply original) (manifest target, Set.empty) (map manifest workers)
      paths = Map.keys combined
      prefixes = Set.fromList [Text.intercalate "/" (take n components) | path <- paths, let components = Text.splitOn "/" (workspaceCoordinateText path), n <- [1 .. length components]]
      directories = Set.fromList [Text.intercalate "/" (take n components) | path <- paths, let components = Text.splitOn "/" (workspaceCoordinateText path), n <- [1 .. length components - 1]]
      structural = Set.size prefixes /= Set.size (Set.map Text.toCaseFold prefixes) || not (Set.null (Set.intersection (Set.map workspaceCoordinateText (Map.keysSet combined)) directories))
   in if not (Set.null conflicts) then Left (Set.toAscList conflicts) else if structural then Left (take 256 paths) else Right (Map.elems combined)
  where
    manifest = Map.fromList . map (\entry -> (entry.name, entry))
    apply base (current, conflicts) incoming = foldl' (change base incoming) (current, conflicts) (Set.toAscList (Map.keysSet base <> Map.keysSet incoming))
    change base incoming (current, conflicts) path
      | proposed == original = (current, conflicts)
      | actual == original || actual == proposed = (maybe (Map.delete path current) (\entry -> Map.insert path entry current) proposed, conflicts)
      | otherwise = (current, Set.insert path conflicts)
      where
        original = Map.lookup path base; proposed = Map.lookup path incoming; actual = Map.lookup path current

newtype IntegrationAbort = IntegrationAbort WorkspaceError deriving stock (Show)

instance Exception IntegrationAbort

-- First revision supports UTF8 replacements/creation in existing directories,
-- without deletion or executable-mode changes. Original unchanged binary blobs
-- remain exact. Recipes are protected tool results, never logged as evidence.
planIntegration :: WorkspaceBinding -> Request -> [(WorkspaceBinding, GitRecord)] -> (WorkspaceCoordinate "relative-path" -> IO ()) -> IO (Either WorkspaceError Aeson.Value)
planIntegration binding request sources admit = catch (Right <$> plan) (\(IntegrationAbort err) -> pure (Left err))
  where
    metadata = workspaceMetadata (workspaceLocatorPath binding.storageRoot) binding
    need = either (throwIO . IntegrationAbort) pure
    refuse = throwIO (IntegrationAbort WorkspaceAllocationRefused)
    plan = do
      (baseTree, _) <- need =<< Objects.readCommit metadata binding.base
      (headTree, _) <- need =<< Objects.readCommit metadata request.expectedParent
      base <- need =<< Objects.readFlatTree metadata baseTree
      target <- need =<< Objects.readFlatTree metadata headTree
      workers <- forM sources \(source, record) -> do
        candidate <- maybe refuse pure record.candidate
        let sourceMetadata = workspaceMetadata (workspaceLocatorPath source.storageRoot) source
        (tree, parents) <- need =<< Objects.readCommit sourceMetadata candidate.result
        unless (tree == candidate.tree && parents == [source.base] && candidate.parent == source.base) refuse
        entries <- need =<< Objects.readFlatTree sourceMetadata tree
        pure (sourceMetadata, entries)
      case mergeManifests base target (map snd workers) of
        Left conflicts -> pure (evidence ["conflicts" .= take 256 conflicts, "replacements" .= ([] :: [Replacement])])
        Right combined -> do
          let previous = Map.fromList [(entry.name, entry) | entry <- target]
              next = Map.fromList [(entry.name, entry) | entry <- combined]
              changed = [path | path <- Set.toAscList (Map.keysSet previous <> Map.keysSet next), Map.lookup path previous /= Map.lookup path next]
              locations = Map.fromList [(entry.objectId, sourceMetadata) | (sourceMetadata, entries) <- workers, entry <- entries]
              directories = Set.fromList ("" : [Text.intercalate "/" (take n components) | entry <- target, let components = Text.splitOn "/" (workspaceCoordinateText entry.name), n <- [1 .. length components - 1]])
          unless (length changed <= 256) refuse
          replacements <- forM changed \path -> do
            admit path
            incoming <- maybe refuse pure (Map.lookup path next)
            let prior = Map.lookup path previous
                directory = Text.intercalate "/" (init (Text.splitOn "/" (workspaceCoordinateText path)))
            unless (Set.member directory directories && maybe (incoming.mode == GitRegular) ((== incoming.mode) . (.mode)) prior) refuse
            bytes <- need =<< Objects.readBlob (Map.findWithDefault metadata incoming.objectId locations) 262144 incoming.objectId
            content <- either (const refuse) pure (Encoding.decodeUtf8' bytes)
            unless (not (Text.any (== '\0') content)) refuse
            expected <- forM prior \entry -> do
              old <- need =<< Objects.readBlob metadata 262144 entry.objectId
              contentDigest <$> either (const refuse) pure (Encoding.decodeUtf8' old)
            pure (Replacement path expected content, bytes, incoming.objectId)
          -- Bound the complete proposal before importing even immutable blobs.
          let proposal tree = evidence ["conflicts" .= ([] :: [Text]), "tree" .= tree, "paths" .= changed, "replacements" .= map (\(replacement, _, _) -> replacement) replacements]
          unless (Lazy.length (Aeson.encode (proposal (workspaceCoordinate @"git-object" (Text.replicate 64 "0")))) <= 32768) refuse
          forM_ replacements \(_, bytes, expected) -> do
            stored <- need =<< Objects.storeBlob metadata bytes
            unless (stored == expected) refuse
          tree <- need =<< Objects.storeFlatTree metadata combined
          pure (proposal tree)
    evidence fields = Aeson.object (["repository" .= binding.repository, "base" .= binding.base, "expectedParent" .= request.expectedParent, "artifacts" .= request.artifacts] <> fields)
