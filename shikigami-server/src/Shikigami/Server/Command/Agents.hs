-- | @shikigami agents list|sync@: the joined declaration and principal
-- inventory.
--
-- The loader remains the only owner of manifest traversal, and the cached
-- directory remains the only owner of principal lookup. This module joins one
-- completed load report to one complete directory snapshot for presentation
-- and reconciliation. Failed manifests and directory-only principals stay in
-- the result instead of disappearing at the join boundary.
module Shikigami.Server.Command.Agents
  ( AgentInventoryEntry (..),
    AgentSyncEntry (..),
    AgentSyncOutcome (..),
    AliasSyncEntry (..),
    AliasSyncOutcome (..),
    buildAgentInventory,
    reconcileAgentInventory,
    reconcileAgentAliases,
    runAgentsList,
    runAgentsSync,
  )
where

import Control.Monad (foldM, when)
import Data.Aeson (Value, object, (.=))
import Data.Aeson qualified as Aeson
import Data.Bifunctor (first)
import Data.ByteString.Lazy.Char8 qualified as LazyChar8
import Data.Functor ((<&>))
import Data.List (transpose)
import Data.Map.Strict qualified as Map
import Data.Maybe (catMaybes)
import Data.Set qualified as Set
import Data.Text (Text)
import Data.Text qualified as Text
import Data.Text.IO qualified as TextIO
import Hasql.Pool (Pool)
import Kioku.Memory qualified as Memory
import Kioku.Memory.ReadModel (MemoryRow (..))
import Kiroku.Store.Connection (KirokuStore (..), defaultConnectionSettings, withStore)
import Kiroku.Store.Effect (runStoreIO)
import Shikigami.Agent.Decl
  ( AgentDecl (..),
    IdentityDecl (..),
    StreamMatch (..),
    Trigger (..),
  )
import Shikigami.Agent.Loader
  ( AgentLoadEntry (..),
    AgentLoadReport (..),
    LoadError (..),
    loadAgentsReport,
  )
import Shikigami.Agent.Principal (AgentPrincipal, mkAgentPrincipal, principalText)
import Shikigami.Agent.Run (behaviorKindText)
import Shikigami.App.Config (AppConfig (agentsDirectory, directorySettings), revealSecretText)
import Shikigami.App.Config.Load (requireDatabaseUrl)
import Shikigami.Directory (DirectoryHandle, DirectoryRuntime (..), DirectorySettings (..), Lifecycle (..), PrincipalRecord (..))
import Shikigami.Directory qualified as Directory
import Shikigami.Directory.Store (recordLoadStates)
import Shikigami.Log qualified as Log
import Shikigami.Memory.Access (shikigamiMemorySpace)
import Shikigami.Memory.AliasStore (AliasReconciliation (..))
import Shikigami.Memory.AliasStore qualified as AliasStore
import Shikigami.Memory.Scope (shikigamiNamespace)
import Shikigami.Sink.GrantStore
  ( GrantIdentityEvidence (..),
    GrantPrincipalSync (..),
    GrantPrincipalSyncStatus (..),
    listGrantIdentityEvidence,
    reconcileGrantPrincipal,
  )
import System.Exit (exitFailure)
import System.FilePath (takeBaseName)
import System.IO (hPutStrLn, stderr)

-- | One row in the union of manifest load results and directory principals.
--
-- The constructor is uniform so renderers cannot accidentally omit a state.
-- The valid shapes built here are: declaration with an optional principal,
-- failed manifest, or principal without a manifest.
data AgentInventoryEntry = AgentInventoryEntry
  { manifestPath :: !(Maybe FilePath),
    declaration :: !(Maybe AgentDecl),
    principal :: !(Maybe PrincipalRecord),
    failure :: !(Maybe LoadError),
    directoryConfigured :: !Bool
  }
  deriving stock (Eq, Show)

data AgentSyncEntry = AgentSyncEntry
  { name :: !Text,
    principalId :: !(Maybe Text),
    outcome :: !AgentSyncOutcome
  }
  deriving stock (Eq, Show)

data AgentSyncOutcome
  = GrantsReconciled !GrantPrincipalSync
  | MissingPrincipal
  | MissingManifest
  | ManifestLoadFailed !Text
  | AmbiguousJoin !Text
  | DirectoryDisabledForSync
  deriving stock (Eq, Show)

-- | One legacy name considered by alias reconciliation.
data AliasSyncEntry = AliasSyncEntry
  { legacyName :: !Text,
    aliasPrincipalId :: !(Maybe Text),
    outcome :: !AliasSyncOutcome
  }
  deriving stock (Eq, Show)

data AliasSyncOutcome
  = AliasReconciled !AliasReconciliation
  | AliasMissingMapping
  | AliasPrincipalMissing ![Text]
  | AliasMultiplyClaimed ![Text]
  | AliasInvalidMapping !Text
  deriving stock (Eq, Show)

-- | Join one load report to one already-refreshed directory snapshot.
--
-- An explicit declaration principal is authoritative because
-- 'Directory.lookupPrincipal' only falls back to the declaration name when the
-- id is absent. Principals consumed by successful joins are removed from the
-- directory-only tail by stable id.
buildAgentInventory :: Bool -> DirectoryHandle -> AgentLoadReport -> IO [AgentInventoryEntry]
buildAgentInventory configured directoryHandle AgentLoadReport {entries} = do
  manifestEntries <- traverse fromLoadEntry entries
  principals <- Directory.directoryPrincipals directoryHandle
  let joinedIds =
        Set.fromList
          [ (.principalId) joined
          | AgentInventoryEntry {principal = Just joined, declaration = Just _} <- manifestEntries
          ]
      principalOnly =
        [ AgentInventoryEntry
            { manifestPath = Nothing,
              declaration = Nothing,
              principal = Just directoryPrincipal,
              failure = Nothing,
              directoryConfigured = configured
            }
        | directoryPrincipal <- principals,
          (.principalId) directoryPrincipal `Set.notMember` joinedIds
        ]
  pure (manifestEntries <> principalOnly)
  where
    fromLoadEntry = \case
      AgentLoaded {path, declaration = decl} -> do
        joined <- Directory.lookupPrincipal directoryHandle (declaredPrincipalId decl) (declName decl)
        pure
          AgentInventoryEntry
            { manifestPath = Just path,
              declaration = Just decl,
              principal = joined,
              failure = Nothing,
              directoryConfigured = configured
            }
      AgentLoadFailed {path, error = problem} ->
        pure
          AgentInventoryEntry
            { manifestPath = Just path,
              declaration = Nothing,
              principal = Nothing,
              failure = Just problem,
              directoryConfigured = configured
            }

-- | Reconcile every unambiguous declaration/principal join with the grant
-- store, preserving missing and failed sides as explicit issues.
reconcileAgentInventory :: Pool -> [AgentInventoryEntry] -> IO (Either Text [AgentSyncEntry])
reconcileAgentInventory pool inventory =
  foldM reconcileOne (Right []) inventory
  where
    joinedKeys =
      [ (declName decl, (.principalId) joined)
      | AgentInventoryEntry {declaration = Just decl, principal = Just joined} <- inventory
      ]
    nameCounts = Map.fromListWith (+) [(agentName, 1 :: Int) | (agentName, _) <- joinedKeys]
    principalCounts = Map.fromListWith (+) [(joinedId, 1 :: Int) | (_, joinedId) <- joinedKeys]

    reconcileOne (Left err) _ = pure (Left err)
    reconcileOne (Right accumulated) entry = do
      next <- reconcileEntry entry
      pure ((\value -> accumulated <> [value]) <$> next)

    reconcileEntry AgentInventoryEntry {declaration = Just decl, principal = Just joined} = do
      let agentName = declName decl
          joinedId = (.principalId) joined
          nameCount = Map.findWithDefault 0 agentName nameCounts
          principalCount = Map.findWithDefault 0 joinedId principalCounts
      if nameCount == 1 && principalCount == 1
        then
          fmap
            ( \result ->
                AgentSyncEntry
                  { name = agentName,
                    principalId = Just joinedId,
                    outcome = GrantsReconciled result
                  }
            )
            <$> reconcileGrantPrincipal pool agentName joinedId
        else
          pure
            ( Right
                AgentSyncEntry
                  { name = agentName,
                    principalId = Just joinedId,
                    outcome =
                      AmbiguousJoin
                        ( "join is not one-to-one (declaration name matches="
                            <> Text.pack (show nameCount)
                            <> ", principal matches="
                            <> Text.pack (show principalCount)
                            <> ")"
                        )
                  }
            )
    reconcileEntry AgentInventoryEntry {declaration = Just decl, principal = Nothing, directoryConfigured} =
      pure
        ( Right
            AgentSyncEntry
              { name = declName decl,
                principalId = Nothing,
                outcome =
                  if directoryConfigured
                    then MissingPrincipal
                    else DirectoryDisabledForSync
              }
        )
    reconcileEntry AgentInventoryEntry {manifestPath = Just path, failure = Just (LoadError problem)} =
      pure
        ( Right
            AgentSyncEntry
              { name = Text.pack (takeBaseName path),
                principalId = Nothing,
                outcome = ManifestLoadFailed problem
              }
        )
    reconcileEntry AgentInventoryEntry {principal = Just directoryPrincipal} =
      pure
        ( Right
            AgentSyncEntry
              { name = principalHandle directoryPrincipal,
                principalId = Just ((.principalId) directoryPrincipal),
                outcome = MissingManifest
              }
        )
    reconcileEntry _ = pure (Left "invalid agent inventory entry")

-- | Reconcile every discovered legacy name to exactly one principal. Claims
-- come from an exact current declaration join, principal-bearing grant
-- evidence, or an explicit @LEGACY_NAME=agent_...@ option. Any malformed,
-- missing, or multiply-owned candidate is reported without writing that name.
reconcileAgentAliases ::
  Pool ->
  Set.Set Text ->
  [GrantIdentityEvidence] ->
  [AgentInventoryEntry] ->
  [Text] ->
  IO (Either Text [AliasSyncEntry])
reconcileAgentAliases pool legacyScopes grantEvidence inventory rawExplicitMappings = do
  reconciled <- traverse reconcileCandidate (Set.toAscList candidates)
  pure ((invalidExplicitEntries <>) <$> sequence reconciled)
  where
    joined =
      [ (declName decl, rawPrincipal)
      | AgentInventoryEntry {declaration = Just decl, principal = Just directoryPrincipal} <- inventory,
        let rawPrincipal = (.principalId) directoryPrincipal
      ]
    nameCounts = Map.fromListWith (+) [(agentName, 1 :: Int) | (agentName, _) <- joined]
    principalCounts = Map.fromListWith (+) [(rawPrincipal, 1 :: Int) | (_, rawPrincipal) <- joined]
    unambiguousJoins =
      [ (agentName, principal)
      | (agentName, rawPrincipal) <- joined,
        Map.findWithDefault 0 agentName nameCounts == 1,
        Map.findWithDefault 0 rawPrincipal principalCounts == 1,
        Right principal <- [mkAgentPrincipal rawPrincipal]
      ]
    currentByName = Map.fromList unambiguousJoins
    currentPrincipals = Set.fromList (map snd unambiguousJoins)

    parsedExplicit = map parseExplicitAlias rawExplicitMappings
    explicitMappings = [mapping | Right mapping <- parsedExplicit]
    invalidExplicitEntries =
      [ AliasSyncEntry
          { legacyName = raw,
            aliasPrincipalId = Nothing,
            outcome = AliasInvalidMapping detail
          }
      | (raw, Left (Nothing, detail)) <- zip rawExplicitMappings parsedExplicit
      ]
    invalidExplicitClaims =
      Map.fromListWith
        (<>)
        [ (legacy, [detail])
        | Left (Just legacy, detail) <- parsedExplicit
        ]

    grantNames = Set.fromList [agentName | GrantIdentityEvidence {agentName} <- grantEvidence]
    explicitNames = Set.fromList (map fst explicitMappings)
    candidates = legacyScopes <> grantNames <> explicitNames <> Map.keysSet invalidExplicitClaims

    baseClaims =
      Map.fromListWith
        Set.union
        [ (candidate, Set.singleton principal)
        | candidate <- Set.toList candidates,
          Just principal <- [Map.lookup candidate currentByName]
        ]
    explicitClaims =
      Map.fromListWith
        Set.union
        [ (legacy, Set.singleton principal)
        | (legacy, principal) <- explicitMappings,
          principal `Set.member` currentPrincipals
        ]
    grantClaims =
      Map.fromListWith
        Set.union
        [ (agentName, Set.singleton principal)
        | GrantIdentityEvidence {agentName, principalId = Just rawPrincipal} <- grantEvidence,
          Right principal <- [mkAgentPrincipal rawPrincipal],
          principal `Set.member` currentPrincipals
        ]
    allClaims = Map.unionsWith Set.union [baseClaims, explicitClaims, grantClaims]

    missingPrincipalClaims =
      Map.fromListWith
        Set.union
        ( [ (legacy, Set.singleton (principalText principal))
          | (legacy, principal) <- explicitMappings,
            principal `Set.notMember` currentPrincipals
          ]
            <> [ (agentName, Set.singleton rawPrincipal)
               | GrantIdentityEvidence {agentName, principalId = Just rawPrincipal} <- grantEvidence,
                 case mkAgentPrincipal rawPrincipal of
                   Left _ -> False
                   Right principal -> principal `Set.notMember` currentPrincipals
               ]
        )
    invalidGrantClaims =
      Map.fromListWith
        (<>)
        [ (agentName, ["grant carries invalid principal '" <> rawPrincipal <> "': " <> detail])
        | GrantIdentityEvidence {agentName, principalId = Just rawPrincipal} <- grantEvidence,
          Left detail <- [mkAgentPrincipal rawPrincipal]
        ]

    reconcileCandidate legacy =
      case Map.lookup legacy invalidExplicitClaims of
        Just details -> pure (Right (issue (AliasInvalidMapping (Text.intercalate "; " details))))
        Nothing ->
          case Map.lookup legacy invalidGrantClaims of
            Just details -> pure (Right (issue (AliasInvalidMapping (Text.intercalate "; " details))))
            Nothing ->
              case Set.toAscList (Map.findWithDefault Set.empty legacy missingPrincipalClaims) of
                missing@(_ : _) -> pure (Right (issue (AliasPrincipalMissing missing)))
                [] ->
                  case Set.toAscList (Map.findWithDefault Set.empty legacy allClaims) of
                    [] -> pure (Right (issue AliasMissingMapping))
                    principals@(_ : _ : _) ->
                      pure (Right (issue (AliasMultiplyClaimed (map principalText principals))))
                    [principal] ->
                      AliasStore.reconcileAlias pool principal legacy <&> fmap (reconciled principal)
      where
        issue aliasOutcome =
          AliasSyncEntry
            { legacyName = legacy,
              aliasPrincipalId = Nothing,
              outcome = aliasOutcome
            }
        reconciled principal aliasResult =
          AliasSyncEntry
            { legacyName = legacy,
              aliasPrincipalId = Just (principalText principal),
              outcome = AliasReconciled aliasResult
            }

parseExplicitAlias :: Text -> Either (Maybe Text, Text) (Text, AgentPrincipal)
parseExplicitAlias raw = do
  let (legacy, suffix) = Text.breakOn "=" raw
      principal = Text.drop 1 suffix
      identifiedLegacy
        | Text.null legacy = Nothing
        | otherwise = Just legacy
  when
    (Text.null suffix || Text.null legacy || Text.null principal || Text.any (== '=') principal)
    (Left (identifiedLegacy, "expected LEGACY_NAME=agent_..."))
  validated <- first (identifiedLegacy,) (mkAgentPrincipal principal)
  pure (legacy, validated)

discoverLegacyAgentScopes :: KirokuStore -> IO (Either Text (Set.Set Text))
discoverLegacyAgentScopes store =
  runStoreIO store (Memory.getActiveRowsInNamespace shikigamiMemorySpace shikigamiNamespace) <&> \case
    Left err -> Left (Text.pack (show err))
    Right (Left err) -> Left (Text.pack (show err))
    Right (Right rows) ->
      Right
        ( Set.fromList
            [ legacy
            | MemoryRow {scopeKind = Just "agent", scopeRef = Just legacy} <- rows,
              isLegacyScope legacy
            ]
        )
  where
    isLegacyScope scope =
      not ("agent_" `Text.isPrefixOf` scope)
        && not ("shikigami.agent." `Text.isPrefixOf` scope)

-- | @shikigami agents list [--json]@.
--
-- This command opens no database. It exits zero when a manifest failed to
-- parse because showing that failure is the inventory doing its job. A
-- configured directory whose initial snapshot cannot be loaded still fails
-- closed, consistently with long-running roles.
runAgentsList :: Bool -> AppConfig -> IO ()
runAgentsList asJson config = do
  report <- loadAgentsReport ((.agentsDirectory) config)
  (configured, directoryHandle) <- loadDirectory "agents list" ((.directorySettings) config)
  inventory <- buildAgentInventory configured directoryHandle report
  if asJson
    then LazyChar8.putStrLn (Aeson.encode (map inventoryJson inventory))
    else renderInventoryTable inventory

-- | @shikigami agents sync [--json] [--alias LEGACY_NAME=agent_...]@.
--
-- The completed manifest report is persisted before directory reconciliation,
-- so a broken directory source cannot make a broken manifest invisible. Join
-- issues are reported and skipped. A conflicting existing grant principal is
-- the one per-row issue that makes the command exit non-zero: identity was
-- already asserted and this command deliberately refused to overwrite it.
runAgentsSync :: Bool -> [Text] -> AppConfig -> IO ()
runAgentsSync asJson explicitAliases config = do
  report <- loadAgentsReport ((.agentsDirectory) config)
  withKirokuStore config "agents sync" \store -> do
    let storePool = pool store
    recordLoadStates storePool ((.agentsDirectory) config) report >>= \case
      Left err -> die "agents sync" err
      Right () -> pure ()
    (configured, directoryHandle) <- loadDirectory "agents sync" ((.directorySettings) config)
    inventory <- buildAgentInventory configured directoryHandle report
    legacyScopes <- discoverLegacyAgentScopes store >>= either (die "agents sync") pure
    grantEvidence <- listGrantIdentityEvidence storePool >>= either (die "agents sync") pure
    aliases <-
      reconcileAgentAliases storePool legacyScopes grantEvidence inventory explicitAliases
        >>= either (die "agents sync") pure
    results <- reconcileAgentInventory storePool inventory >>= either (die "agents sync") pure
    if asJson
      then
        LazyChar8.putStrLn
          ( Aeson.encode
              ( object
                  [ "load_state_recorded" .= True,
                    "results" .= map syncJson results,
                    "aliases" .= map aliasSyncJson aliases
                  ]
              )
          )
      else do
        renderSyncResults results
        renderAliasSyncResults aliases
    when (any hasPrincipalConflict results || any hasAliasIssue aliases) exitFailure

loadDirectory :: String -> DirectorySettings -> IO (Bool, DirectoryHandle)
loadDirectory context settings =
  Directory.startDirectory Log.silentLogger settings >>= \case
    Left err -> die context err
    Right runtime -> pure (isConfigured settings, runtimeDirectoryHandle runtime)
  where
    isConfigured DirectoryDisabled = False
    isConfigured DirectoryFile {} = True

renderInventoryTable :: [AgentInventoryEntry] -> IO ()
renderInventoryTable [] = putStrLn "no manifests or principals found"
renderInventoryTable inventory = do
  mapM_ (TextIO.putStrLn . padRow widths) rows
  case failures of
    [] -> pure ()
    _ -> do
      putStrLn ""
      mapM_ renderFailure failures
  where
    rows = inventoryHeader : map inventoryRow inventory
    widths = columnWidths rows
    failures =
      [ (path, problem)
      | AgentInventoryEntry {manifestPath = Just path, failure = Just problem} <- inventory
      ]

    renderFailure (path, LoadError detail) = do
      putStrLn (path <> ":")
      TextIO.putStrLn (indent detail)

    indent = Text.unlines . map ("  " <>) . Text.lines . Text.stripEnd

inventoryHeader :: [Text]
inventoryHeader = ["NAME", "BEHAVIOR", "TRIGGER", "ENABLED", "MANIFEST", "PRINCIPAL", "LIFECYCLE"]

inventoryRow :: AgentInventoryEntry -> [Text]
inventoryRow AgentInventoryEntry {declaration = Just decl, principal, directoryConfigured} =
  [ declName decl,
    behaviorKindText ((.behavior) decl),
    triggerSummary ((.trigger) decl),
    if (.enabled) decl then "yes" else "no",
    "loaded",
    maybe "NO PRINCIPAL" (.principalId) principal,
    case principal of
      Just joined -> renderLifecycle ((.lifecycle) joined)
      Nothing
        | directoryConfigured -> "-"
        | otherwise -> "DISABLED"
  ]
inventoryRow AgentInventoryEntry {manifestPath = Just path, failure = Just _} =
  [Text.pack (takeBaseName path), "-", "-", "-", "failed", "-", "-"]
inventoryRow AgentInventoryEntry {principal = Just directoryPrincipal} =
  [ principalHandle directoryPrincipal,
    "-",
    "-",
    "-",
    "NO MANIFEST",
    (.principalId) directoryPrincipal,
    renderLifecycle ((.lifecycle) directoryPrincipal)
  ]
inventoryRow _ = ["INVALID", "-", "-", "-", "-", "-", "-"]

inventoryJson :: AgentInventoryEntry -> Value
inventoryJson AgentInventoryEntry {manifestPath = Just path, declaration = Just decl, principal, directoryConfigured} =
  object
    [ "state" .= ("loaded" :: Text),
      "path" .= path,
      "name" .= declName decl,
      "behavior" .= behaviorKindText ((.behavior) decl),
      "trigger" .= triggerSummary ((.trigger) decl),
      "enabled" .= (.enabled) decl,
      "principal_id" .= fmap (.principalId) principal,
      "lifecycle"
        .= case principal of
          Just joined -> Just (renderLifecycle ((.lifecycle) joined))
          Nothing
            | directoryConfigured -> Nothing
            | otherwise -> Just ("disabled" :: Text)
    ]
inventoryJson AgentInventoryEntry {manifestPath = Just path, failure = Just (LoadError detail)} =
  object
    [ "state" .= ("failed" :: Text),
      "path" .= path,
      "error" .= detail
    ]
inventoryJson AgentInventoryEntry {principal = Just directoryPrincipal} =
  object
    [ "state" .= ("no-manifest" :: Text),
      "name" .= principalHandle directoryPrincipal,
      "principal_id" .= (.principalId) directoryPrincipal,
      "lifecycle" .= renderLifecycle ((.lifecycle) directoryPrincipal)
    ]
inventoryJson _ = object ["state" .= ("invalid" :: Text)]

renderSyncResults :: [AgentSyncEntry] -> IO ()
renderSyncResults [] = putStrLn "no manifests or principals found"
renderSyncResults entries = mapM_ (TextIO.putStrLn . syncLine) entries

syncLine :: AgentSyncEntry -> Text
syncLine AgentSyncEntry {name, principalId, outcome} =
  case outcome of
    GrantsReconciled GrantPrincipalSync {filledCount, verifiedCount, status = PrincipalSynced} ->
      Text.unwords
        [ "SYNCED",
          name,
          maybe "NO PRINCIPAL" id principalId,
          "filled=" <> Text.pack (show filledCount),
          "verified=" <> Text.pack (show verifiedCount)
        ]
    GrantsReconciled GrantPrincipalSync {status = PrincipalConflict conflicts} ->
      Text.unwords
        [ "CONFLICT",
          name,
          "expected=" <> maybe "NO PRINCIPAL" id principalId,
          "existing=" <> Text.intercalate "," (Set.toAscList conflicts)
        ]
    MissingPrincipal -> "ISSUE " <> name <> " NO PRINCIPAL"
    MissingManifest -> "ISSUE " <> name <> " NO MANIFEST"
    ManifestLoadFailed _ -> "ISSUE " <> name <> " MANIFEST FAILED"
    AmbiguousJoin detail -> "ISSUE " <> name <> " " <> detail
    DirectoryDisabledForSync -> "ISSUE " <> name <> " DIRECTORY DISABLED"

syncJson :: AgentSyncEntry -> Value
syncJson AgentSyncEntry {name, principalId, outcome} =
  object
    ( [ "name" .= name,
        "principal_id" .= principalId
      ]
        <> outcomeFields outcome
    )
  where
    outcomeFields = \case
      GrantsReconciled GrantPrincipalSync {filledCount, verifiedCount, status = PrincipalSynced} ->
        [ "outcome" .= ("synced" :: Text),
          "filled" .= filledCount,
          "verified" .= verifiedCount
        ]
      GrantsReconciled GrantPrincipalSync {status = PrincipalConflict conflicts} ->
        [ "outcome" .= ("conflict" :: Text),
          "existing_principal_ids" .= Set.toAscList conflicts
        ]
      MissingPrincipal -> ["outcome" .= ("missing-principal" :: Text)]
      MissingManifest -> ["outcome" .= ("missing-manifest" :: Text)]
      ManifestLoadFailed detail ->
        [ "outcome" .= ("manifest-failed" :: Text),
          "error" .= detail
        ]
      AmbiguousJoin detail ->
        [ "outcome" .= ("ambiguous-join" :: Text),
          "detail" .= detail
        ]
      DirectoryDisabledForSync -> ["outcome" .= ("directory-disabled" :: Text)]

hasPrincipalConflict :: AgentSyncEntry -> Bool
hasPrincipalConflict AgentSyncEntry {outcome = GrantsReconciled GrantPrincipalSync {status = PrincipalConflict _}} = True
hasPrincipalConflict _ = False

renderAliasSyncResults :: [AliasSyncEntry] -> IO ()
renderAliasSyncResults [] = pure ()
renderAliasSyncResults entries = do
  putStrLn ""
  mapM_ (TextIO.putStrLn . aliasSyncLine) entries

aliasSyncLine :: AliasSyncEntry -> Text
aliasSyncLine AliasSyncEntry {legacyName, aliasPrincipalId, outcome} =
  case outcome of
    AliasReconciled AliasInserted {} -> prefix "ALIASED"
    AliasReconciled AliasAlreadyPresent {} -> prefix "ALIAS PRESENT"
    AliasReconciled AliasConflict {existingPrincipalId} ->
      "ALIAS CONFLICT " <> legacyName <> " expected=" <> expected <> " existing=" <> existingPrincipalId
    AliasMissingMapping -> "ALIAS ISSUE " <> legacyName <> " MISSING MAPPING"
    AliasPrincipalMissing missing ->
      "ALIAS ISSUE " <> legacyName <> " PRINCIPAL MISSING " <> Text.intercalate "," missing
    AliasMultiplyClaimed principals ->
      "ALIAS ISSUE " <> legacyName <> " MULTIPLY CLAIMED " <> Text.intercalate "," principals
    AliasInvalidMapping detail -> "ALIAS ISSUE " <> legacyName <> " INVALID " <> detail
  where
    expected = maybe "NO PRINCIPAL" id aliasPrincipalId
    prefix status = Text.unwords [status, legacyName, expected]

aliasSyncJson :: AliasSyncEntry -> Value
aliasSyncJson AliasSyncEntry {legacyName, aliasPrincipalId, outcome} =
  object
    ( [ "legacy_name" .= legacyName,
        "principal_id" .= aliasPrincipalId
      ]
        <> outcomeFields outcome
    )
  where
    outcomeFields = \case
      AliasReconciled AliasInserted {} -> ["outcome" .= ("inserted" :: Text)]
      AliasReconciled AliasAlreadyPresent {} -> ["outcome" .= ("already-present" :: Text)]
      AliasReconciled AliasConflict {existingPrincipalId} ->
        [ "outcome" .= ("conflict" :: Text),
          "existing_principal_id" .= existingPrincipalId
        ]
      AliasMissingMapping -> ["outcome" .= ("missing-mapping" :: Text)]
      AliasPrincipalMissing missing ->
        [ "outcome" .= ("principal-missing" :: Text),
          "missing_principal_ids" .= missing
        ]
      AliasMultiplyClaimed principals ->
        [ "outcome" .= ("multiply-claimed" :: Text),
          "claimed_principal_ids" .= principals
        ]
      AliasInvalidMapping detail ->
        [ "outcome" .= ("invalid-mapping" :: Text),
          "detail" .= detail
        ]

hasAliasIssue :: AliasSyncEntry -> Bool
hasAliasIssue AliasSyncEntry {outcome = AliasReconciled AliasInserted {}} = False
hasAliasIssue AliasSyncEntry {outcome = AliasReconciled AliasAlreadyPresent {}} = False
hasAliasIssue _ = True

declaredPrincipalId :: AgentDecl -> Maybe Text
declaredPrincipalId AgentDecl {identity} = declared <$> identity
  where
    declared IdentityDecl {principal} = principal

declName :: AgentDecl -> Text
declName AgentDecl {name} = name

principalHandle :: PrincipalRecord -> Text
principalHandle PrincipalRecord {handle} = handle

runtimeDirectoryHandle :: DirectoryRuntime -> DirectoryHandle
runtimeDirectoryHandle DirectoryRuntime {handle} = handle

renderLifecycle :: Lifecycle -> Text
renderLifecycle = \case
  Active -> "active"
  Paused -> "paused"
  Deactivated -> "deactivated"

triggerSummary :: Trigger -> Text
triggerSummary = \case
  Schedule {cron} -> "schedule " <> cron
  Event {eventType} -> "event " <> eventType
  Stream {match} -> Text.unwords ("stream" : streamMatchParts match)

streamMatchParts :: StreamMatch -> [Text]
streamMatchParts StreamMatch {verb, source, subjectType, verbs} =
  case parts of
    [] -> ["*"]
    _ -> parts
  where
    parts =
      catMaybes
        [ ("source=" <>) <$> source,
          ("subject=" <>) <$> subjectType,
          ("verb=" <>) <$> verb,
          case verbs of
            [] -> Nothing
            _ -> Just ("verbs=" <> Text.intercalate "," verbs)
        ]

columnWidths :: [[Text]] -> [Int]
columnWidths = map (maximum . map Text.length) . transpose

padRow :: [Int] -> [Text] -> Text
padRow widths cells =
  Text.stripEnd (Text.intercalate "  " (zipWith pad widths cells))
  where
    pad width cell = cell <> Text.replicate (width - Text.length cell) " "

withKirokuStore :: AppConfig -> String -> (KirokuStore -> IO a) -> IO a
withKirokuStore config context use = do
  connectionString <- revealSecretText <$> requireDatabaseUrl (Text.pack context) config
  withStore (defaultConnectionSettings connectionString) use

die :: String -> Text -> IO a
die context message = do
  hPutStrLn stderr (context <> ": " <> Text.unpack message)
  exitFailure
