{-# LANGUAGE DataKinds #-}

-- | Operator-owned repository admission. Resolving a catalog entry is neither
-- filesystem access nor permission to perform an external action.
module Shikigami.Workspace.Catalog
  ( RepositoryPolicy (..),
    WorkspaceCatalog,
    CatalogError (..),
    ResolvedRepository,
    repositoryIdentity,
    repositorySource,
    repositoryBase,
    repositoryPolicyRevision,
    mkWorkspaceCatalog,
    resolveRepository,
  )
where

import Data.List (nub)
import Data.Text (Text)
import Data.Text qualified as Text
import GHC.Generics (Generic)
import Shikigami.Repository (RepositoryId, repositoryId, repositoryIdText)
import Shikigami.Workspace.Value
import System.FilePath (isAbsolute, normalise, splitDirectories)

-- No JSON or Show instance: local source paths are operator configuration,
-- never caller payloads, journal values or diagnostic output.
data RepositoryPolicy = RepositoryPolicy
  { identity :: !(RepositoryId),
    source :: !(WorkspaceLocator "repository-source"),
    revisions :: !([WorkspaceCoordinate "git-object"]),
    defaultRevision :: !(WorkspaceCoordinate "git-object"),
    policyRevision :: !(WorkspaceCoordinate "policy-identity")
  }
  deriving stock (Generic)

newtype WorkspaceCatalog = WorkspaceCatalog [RepositoryPolicy]

data CatalogError
  = InvalidRepositoryIdentity
  | DuplicateRepositoryIdentity
  | InvalidRepositorySource
  | InvalidRepositoryRevisions
  | InvalidRepositoryPolicyRevision
  | UnknownRepository
  | RevisionNotAdmitted
  deriving stock (Eq, Show)

data ResolvedRepository = ResolvedRepository !RepositoryPolicy !(WorkspaceCoordinate "git-object")

repositoryIdentity :: ResolvedRepository -> RepositoryId
repositoryIdentity (ResolvedRepository policy _) = policy.identity

repositorySource :: ResolvedRepository -> WorkspaceLocator "repository-source"
repositorySource (ResolvedRepository policy _) = policy.source

repositoryBase :: ResolvedRepository -> WorkspaceCoordinate "git-object"
repositoryBase (ResolvedRepository _ revision) = revision

repositoryPolicyRevision :: ResolvedRepository -> WorkspaceCoordinate "policy-identity"
repositoryPolicyRevision (ResolvedRepository policy _) = policy.policyRevision

mkWorkspaceCatalog :: [RepositoryPolicy] -> Either CatalogError WorkspaceCatalog
mkWorkspaceCatalog policies = do
  mapM_ validate policies
  let identities = map (.identity) policies
  if length (nub identities) /= length identities
    then Left DuplicateRepositoryIdentity
    else Right (WorkspaceCatalog policies)
  where
    validate policy
      | not (canonicalIdentity policy.identity.value) = Left InvalidRepositoryIdentity
      | not (isAbsolute (workspaceLocatorPath policy.source)) || normalise (workspaceLocatorPath policy.source) /= workspaceLocatorPath policy.source || ".." `elem` splitDirectories (workspaceLocatorPath policy.source) || '\0' `elem` workspaceLocatorPath policy.source = Left InvalidRepositorySource
      | null policy.revisions || not (all (immutableRevision . workspaceCoordinateText) policy.revisions) || policy.defaultRevision `notElem` policy.revisions = Left InvalidRepositoryRevisions
      | not (boundedToken (workspaceCoordinateText policy.policyRevision)) = Left InvalidRepositoryPolicyRevision
      | otherwise = Right ()

-- Exact comparison deliberately refuses aliases, local paths and branch names.
-- The live provider must additionally verify the admitted Git object is a commit
-- and canonicalize the configured source before allocating an isolated worktree.
resolveRepository :: WorkspaceCatalog -> RepositoryId -> Maybe (WorkspaceCoordinate "git-object") -> Either CatalogError ResolvedRepository
resolveRepository (WorkspaceCatalog policies) requested revision = case filter ((== requested) . (.identity)) policies of
  [policy] ->
    let base = maybe policy.defaultRevision id revision
     in if base `elem` policy.revisions
          then Right (ResolvedRepository policy base)
          else Left RevisionNotAdmitted
  _ -> Left UnknownRepository

canonicalIdentity :: Text -> Bool
canonicalIdentity value = case Text.stripPrefix "mori://" value of
  Just rest -> case Text.splitOn "/" rest of
    [namespace, project] -> all boundedToken [namespace, project]
    _ -> False
  Nothing -> False

boundedToken :: Text -> Bool
boundedToken value = not (Text.null value) && Text.length value <= 128 && Text.all allowed value && value `notElem` [".", ".."]
  where
    allowed c = (c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z') || (c >= '0' && c <= '9') || c `elem` ("-_." :: String)

immutableRevision :: Text -> Bool
immutableRevision value = Text.length value `elem` [40, 64] && Text.all (\c -> (c >= '0' && c <= '9') || (c >= 'a' && c <= 'f')) value
