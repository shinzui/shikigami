module Shikigami.Router.Catalog
  ( CatalogVersion (..),
    ExclusionReason (..),
    CandidateAvailability (..),
    CandidateEntry (..),
    CandidateCatalog (..),
    buildCandidateCatalog,
  )
where

import Data.Aeson (withObject, withText, (.:))
import Data.Aeson qualified as Aeson
import Data.Map.Strict (Map)
import Data.Map.Strict qualified as Map
import Data.Text qualified as Text
import Data.UUID qualified as UUID
import Data.UUID.V5 qualified as UUID.V5
import Numeric.Natural (Natural)
import Shikigami.Agent.Decl
  ( AgentDecl (..),
    ExpertiseDecl (..),
    IdentityDecl (..),
  )
import Shikigami.Agent.Loader
  ( AgentLoadEntry (..),
    AgentLoadReport (..),
  )
import Shikigami.Directory
  ( DirectorySnapshot (..),
    DirectorySnapshotVersion (..),
    DirectorySourceKind (..),
    PrincipalRecord (..),
    renderDirectorySourceKind,
  )
import Shikigami.Directory qualified as Directory
import Shikigami.Id.Name (nameBytes)
import Shikigami.Prelude
import Shikigami.Router.Declaration (ValidatedRouterDeclaration (..))

-- | A stable identifier for every model-visible input in a candidate catalog.
newtype CatalogVersion = CatalogVersion {value :: Text}
  deriving stock (Generic, Eq, Ord, Show)

instance ToJSON CatalogVersion where
  toJSON (CatalogVersion version) = Aeson.String version

instance FromJSON CatalogVersion where
  parseJSON = withText "catalog version" (pure . CatalogVersion)

data ExclusionReason
  = Disabled
  | Paused
  | Deactivated
  | MissingDeclaration
  | DuplicateDeclaration
  | UnknownPrincipal
  | LifecycleUnavailable
  deriving stock (Generic, Eq, Ord, Show)

instance ToJSON ExclusionReason where
  toJSON = Aeson.String . renderExclusionReason

instance FromJSON ExclusionReason where
  parseJSON = withText "candidate exclusion reason" \case
    "disabled" -> pure Disabled
    "paused" -> pure Paused
    "deactivated" -> pure Deactivated
    "missing-declaration" -> pure MissingDeclaration
    "duplicate-declaration" -> pure DuplicateDeclaration
    "unknown-principal" -> pure UnknownPrincipal
    "lifecycle-unavailable" -> pure LifecycleUnavailable
    other -> fail ("unknown candidate exclusion reason: " <> Text.unpack other)

data CandidateAvailability
  = Available
  | Excluded !ExclusionReason
  deriving stock (Generic, Eq, Show)

instance ToJSON CandidateAvailability where
  toJSON Available = Aeson.object ["status" Aeson..= ("available" :: Text)]
  toJSON (Excluded reason) =
    Aeson.object
      [ "status" Aeson..= ("excluded" :: Text),
        "reason" Aeson..= reason
      ]

instance FromJSON CandidateAvailability where
  parseJSON = withObject "candidate availability" \object -> do
    status <- object .: "status"
    case status :: Text of
      "available" -> pure Available
      "excluded" -> Excluded <$> object .: "reason"
      other -> fail ("unknown candidate availability: " <> Text.unpack other)

data CandidateEntry = CandidateEntry
  { name :: !Text,
    description :: !(Maybe Text),
    expertise :: ![ExpertiseDecl],
    availability :: !CandidateAvailability
  }
  deriving stock (Generic, Eq, Show)
  deriving anyclass (ToJSON, FromJSON)

data CandidateCatalog = CandidateCatalog
  { router :: !Text,
    version :: !CatalogVersion,
    lifecycleSource :: !DirectorySourceKind,
    lifecycleSourceVersion :: !DirectorySnapshotVersion,
    candidates :: ![CandidateEntry],
    unassociatedLoadFailures :: !Natural
  }
  deriving stock (Generic, Eq, Show)
  deriving anyclass (ToJSON, FromJSON)

-- | Resolve exactly the validated router's allow-list against one immutable
-- declaration report and one immutable lifecycle snapshot.
buildCandidateCatalog :: AgentLoadReport -> DirectorySnapshot -> ValidatedRouterDeclaration -> CandidateCatalog
buildCandidateCatalog report snapshot validated =
  CandidateCatalog
    { router = routerName,
      version = catalogVersionFor routerName source sourceVersion resolvedCandidates failureCount,
      lifecycleSource = source,
      lifecycleSourceVersion = sourceVersion,
      candidates = resolvedCandidates,
      unassociatedLoadFailures = failureCount
    }
  where
    AgentLoadReport {entries} = report
    ValidatedRouterDeclaration {declaration = routerDeclaration} = validated
    AgentDecl {name = routerName, delegates} = routerDeclaration
    declarationsByName = loadedDeclarationsByName entries
    lifecycleIndex = indexSnapshot snapshot
    resolvedCandidates = resolveCandidate declarationsByName lifecycleIndex <$> delegates
    failureCount = fromIntegral (length [() | AgentLoadFailed {} <- entries])
    (source, sourceVersion) = snapshotIdentity snapshot

data LifecycleIndex
  = LocalEnabled
  | ConfiguredUnavailable
  | ConfiguredPrincipals !(Map Text PrincipalRecord) !(Map Text PrincipalRecord)

indexSnapshot :: DirectorySnapshot -> LifecycleIndex
indexSnapshot DirectoryDisabledSnapshot {} = LocalEnabled
indexSnapshot DirectoryUnavailableSnapshot {} = ConfiguredUnavailable
indexSnapshot DirectoryConfiguredSnapshot {principals} =
  ConfiguredPrincipals
    (Map.fromList [(principalId, principal) | principal@PrincipalRecord {principalId} <- principals])
    (Map.fromList [(normalizeHandle handle, principal) | principal@PrincipalRecord {handle} <- principals])

loadedDeclarationsByName :: [AgentLoadEntry] -> Map Text [AgentDecl]
loadedDeclarationsByName = foldl' addEntry Map.empty
  where
    addEntry grouped AgentLoadFailed {} = grouped
    addEntry grouped AgentLoaded {declaration = declaration@AgentDecl {name}} =
      Map.insertWith (flip (<>)) name [declaration] grouped

resolveCandidate :: Map Text [AgentDecl] -> LifecycleIndex -> Text -> CandidateEntry
resolveCandidate declarationsByName lifecycleIndex candidateName =
  case Map.findWithDefault [] candidateName declarationsByName of
    [] -> unavailableCandidate candidateName MissingDeclaration
    [_first, _second] -> unavailableCandidate candidateName DuplicateDeclaration
    _first : _second : _rest -> unavailableCandidate candidateName DuplicateDeclaration
    [declaration] -> resolvedCandidate lifecycleIndex declaration

unavailableCandidate :: Text -> ExclusionReason -> CandidateEntry
unavailableCandidate candidateName reason =
  CandidateEntry
    { name = candidateName,
      description = Nothing,
      expertise = [],
      availability = Excluded reason
    }

resolvedCandidate :: LifecycleIndex -> AgentDecl -> CandidateEntry
resolvedCandidate lifecycleIndex AgentDecl {name, description, expertise, enabled, identity} =
  CandidateEntry
    { name,
      description = Just description,
      expertise,
      availability =
        if enabled
          then lifecycleAvailability lifecycleIndex identity name
          else Excluded Disabled
    }

lifecycleAvailability :: LifecycleIndex -> Maybe IdentityDecl -> Text -> CandidateAvailability
lifecycleAvailability LocalEnabled _ _ = Available
lifecycleAvailability ConfiguredUnavailable _ _ = Excluded LifecycleUnavailable
lifecycleAvailability (ConfiguredPrincipals byPrincipalId byHandle) declaredIdentity agentName =
  case foundPrincipal of
    Nothing -> Excluded UnknownPrincipal
    Just PrincipalRecord {lifecycle = Directory.Active} -> Available
    Just PrincipalRecord {lifecycle = Directory.Paused} -> Excluded Paused
    Just PrincipalRecord {lifecycle = Directory.Deactivated} -> Excluded Deactivated
  where
    foundPrincipal = case declaredIdentity of
      Just IdentityDecl {principal} -> Map.lookup principal byPrincipalId
      Nothing -> Map.lookup (normalizeHandle agentName) byHandle

snapshotIdentity :: DirectorySnapshot -> (DirectorySourceKind, DirectorySnapshotVersion)
snapshotIdentity DirectoryDisabledSnapshot {version} = (DirectoryDisabledSource, version)
snapshotIdentity DirectoryConfiguredSnapshot {source, version} = (source, version)
snapshotIdentity DirectoryUnavailableSnapshot {source, version} = (source, version)

catalogVersionFor :: Text -> DirectorySourceKind -> DirectorySnapshotVersion -> [CandidateEntry] -> Natural -> CatalogVersion
catalogVersionFor routerName sourceKind (DirectorySnapshotVersion sourceVersion) candidateEntries failureCount =
  CatalogVersion
    ( Text.pack
        ( UUID.toString
            ( UUID.V5.generateNamed
                UUID.V5.namespaceURL
                ( nameBytes
                    ( canonicalValues
                        [ "shikigami-router-catalog-v1",
                          routerName,
                          renderDirectorySourceKind sourceKind,
                          sourceVersion,
                          tshow failureCount,
                          canonicalList candidateValues candidateEntries
                        ]
                    )
                )
            )
        )
    )

candidateValues :: CandidateEntry -> [Text]
candidateValues CandidateEntry {name, description, expertise, availability} =
  [ name,
    canonicalMaybe description,
    canonicalList expertiseValues expertise,
    renderAvailability availability
  ]

expertiseValues :: ExpertiseDecl -> [Text]
expertiseValues ExpertiseDecl {key, description, aliases, evidenceHints} =
  [ key,
    description,
    canonicalList pure aliases,
    canonicalList pure evidenceHints
  ]

canonicalMaybe :: Maybe Text -> Text
canonicalMaybe Nothing = canonicalValues ["none"]
canonicalMaybe (Just value) = canonicalValues ["some", value]

canonicalList :: (a -> [Text]) -> [a] -> Text
canonicalList render values =
  canonicalValues ([tshow (length values)] <> concatMap render values)

canonicalValues :: [Text] -> Text
canonicalValues = Text.concat . fmap canonicalValue

canonicalValue :: Text -> Text
canonicalValue value = tshow (Text.length value) <> ":" <> value

renderAvailability :: CandidateAvailability -> Text
renderAvailability Available = "available"
renderAvailability (Excluded reason) = "excluded:" <> renderExclusionReason reason

renderExclusionReason :: ExclusionReason -> Text
renderExclusionReason = \case
  Disabled -> "disabled"
  Paused -> "paused"
  Deactivated -> "deactivated"
  MissingDeclaration -> "missing-declaration"
  DuplicateDeclaration -> "duplicate-declaration"
  UnknownPrincipal -> "unknown-principal"
  LifecycleUnavailable -> "lifecycle-unavailable"

normalizeHandle :: Text -> Text
normalizeHandle = Text.toCaseFold . Text.strip

tshow :: (Show a) => a -> Text
tshow = Text.pack . show
