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
    buildAgentInventory,
    reconcileAgentInventory,
    runAgentsList,
    runAgentsSync,
  )
where

import Control.Monad (foldM, when)
import Data.Aeson (Value, object, (.=))
import Data.Aeson qualified as Aeson
import Data.ByteString.Lazy.Char8 qualified as LazyChar8
import Data.List (transpose)
import Data.Map.Strict qualified as Map
import Data.Maybe (catMaybes)
import Data.Set qualified as Set
import Data.Text (Text)
import Data.Text qualified as Text
import Data.Text.IO qualified as TextIO
import Hasql.Pool (Pool)
import Kiroku.Store.Connection (KirokuStore (..), defaultConnectionSettings, withStore)
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
import Shikigami.Agent.Run (behaviorKindText)
import Shikigami.App.Config (AppConfig, agentsDirectory, directorySettings, revealSecretText)
import Shikigami.App.Config.Load (requireDatabaseUrl)
import Shikigami.Directory (DirectoryHandle, DirectoryRuntime (..), DirectorySettings (..), Lifecycle (..), PrincipalRecord (..))
import Shikigami.Directory qualified as Directory
import Shikigami.Directory.Store (recordLoadStates)
import Shikigami.Log qualified as Log
import Shikigami.Sink.GrantStore
  ( GrantPrincipalSync (..),
    GrantPrincipalSyncStatus (..),
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
          [ Directory.principalId joined
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
          Directory.principalId directoryPrincipal `Set.notMember` joinedIds
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
      [ (declName decl, Directory.principalId joined)
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
          joinedId = Directory.principalId joined
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
                principalId = Just (Directory.principalId directoryPrincipal),
                outcome = MissingManifest
              }
        )
    reconcileEntry _ = pure (Left "invalid agent inventory entry")

-- | @shikigami agents list [--json]@.
--
-- This command opens no database. It exits zero when a manifest failed to
-- parse because showing that failure is the inventory doing its job. A
-- configured directory whose initial snapshot cannot be loaded still fails
-- closed, consistently with long-running roles.
runAgentsList :: Bool -> AppConfig -> IO ()
runAgentsList asJson config = do
  report <- loadAgentsReport (agentsDirectory config)
  (configured, directoryHandle) <- loadDirectory "agents list" (directorySettings config)
  inventory <- buildAgentInventory configured directoryHandle report
  if asJson
    then LazyChar8.putStrLn (Aeson.encode (map inventoryJson inventory))
    else renderInventoryTable inventory

-- | @shikigami agents sync [--json]@.
--
-- The completed manifest report is persisted before directory reconciliation,
-- so a broken directory source cannot make a broken manifest invisible. Join
-- issues are reported and skipped. A conflicting existing grant principal is
-- the one per-row issue that makes the command exit non-zero: identity was
-- already asserted and this command deliberately refused to overwrite it.
runAgentsSync :: Bool -> AppConfig -> IO ()
runAgentsSync asJson config = do
  report <- loadAgentsReport (agentsDirectory config)
  withPool config "agents sync" \pool -> do
    recordLoadStates pool (agentsDirectory config) report >>= \case
      Left err -> die "agents sync" err
      Right () -> pure ()
    (configured, directoryHandle) <- loadDirectory "agents sync" (directorySettings config)
    inventory <- buildAgentInventory configured directoryHandle report
    results <- reconcileAgentInventory pool inventory >>= either (die "agents sync") pure
    if asJson
      then
        LazyChar8.putStrLn
          ( Aeson.encode
              ( object
                  [ "load_state_recorded" .= True,
                    "results" .= map syncJson results
                  ]
              )
          )
      else renderSyncResults results
    when (any hasPrincipalConflict results) exitFailure

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
    behaviorKindText (behavior decl),
    triggerSummary (trigger decl),
    if enabled decl then "yes" else "no",
    "loaded",
    maybe "NO PRINCIPAL" Directory.principalId principal,
    case principal of
      Just joined -> renderLifecycle (Directory.lifecycle joined)
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
    Directory.principalId directoryPrincipal,
    renderLifecycle (Directory.lifecycle directoryPrincipal)
  ]
inventoryRow _ = ["INVALID", "-", "-", "-", "-", "-", "-"]

inventoryJson :: AgentInventoryEntry -> Value
inventoryJson AgentInventoryEntry {manifestPath = Just path, declaration = Just decl, principal, directoryConfigured} =
  object
    [ "state" .= ("loaded" :: Text),
      "path" .= path,
      "name" .= declName decl,
      "behavior" .= behaviorKindText (behavior decl),
      "trigger" .= triggerSummary (trigger decl),
      "enabled" .= enabled decl,
      "principal_id" .= fmap Directory.principalId principal,
      "lifecycle"
        .= case principal of
          Just joined -> Just (renderLifecycle (Directory.lifecycle joined))
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
      "principal_id" .= Directory.principalId directoryPrincipal,
      "lifecycle" .= renderLifecycle (Directory.lifecycle directoryPrincipal)
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

withPool :: AppConfig -> String -> (Pool -> IO a) -> IO a
withPool config context use = do
  connectionString <- revealSecretText <$> requireDatabaseUrl (Text.pack context) config
  withStore (defaultConnectionSettings connectionString) (use . pool)

die :: String -> Text -> IO a
die context message = do
  hPutStrLn stderr (context <> ": " <> Text.unpack message)
  exitFailure
