-- | A small, atomically refreshed view of Meibo principals.
--
-- The runtime deliberately consumes a narrow projection rather than Meibo's
-- complete wire type.  That keeps lifecycle enforcement independent of fields
-- Shikigami does not use and gives the file-backed development source the same
-- semantics as a future typed Meibo client.
module Shikigami.Directory
  ( Lifecycle (..),
    PrincipalRecord (..),
    DirectorySettings (..),
    DirectoryView,
    DirectorySource,
    DirectoryHandle,
    LifecycleDecision (..),
    DirectoryRuntime (..),
    fileDirectorySource,
    staticDirectorySource,
    newDirectoryHandle,
    disabledDirectoryHandle,
    refreshDirectory,
    startDirectory,
    startDirectoryWithHeartbeat,
    consultLifecycle,
    lifecycleAdmission,
    principalAttribution,
    lookupPrincipal,
    directoryPrincipals,
  )
where

import Control.Concurrent (threadDelay)
import Control.Monad (forever)
import Data.Aeson (FromJSON (..), withObject, withText, (.:))
import Data.Aeson qualified as Aeson
import Data.ByteString qualified as BS
import Data.IORef (IORef, atomicModifyIORef', newIORef, readIORef)
import Data.List (sortOn)
import Data.Map.Strict (Map)
import Data.Map.Strict qualified as Map
import Data.Text (Text)
import Data.Text qualified as Text
import Data.Time (NominalDiffTime, UTCTime, getCurrentTime, nominalDiffTimeToSeconds)
import GHC.Generics (Generic)
import Shikigami.Log qualified as Log
import System.IO.Error (tryIOError)

-- | The lifecycle values Shikigami enforces from Meibo.
data Lifecycle = Active | Paused | Deactivated
  deriving stock (Generic, Eq, Ord, Show)

instance FromJSON Lifecycle where
  parseJSON = withText "principal lifecycle" \case
    "active" -> pure Active
    "paused" -> pure Paused
    "deactivated" -> pure Deactivated
    other -> fail ("unknown principal lifecycle: " <> Text.unpack other)

-- | The exact principal projection needed by lifecycle gates and attribution.
data PrincipalRecord = PrincipalRecord
  { principalId :: !Text,
    handle :: !Text,
    lifecycle :: !Lifecycle
  }
  deriving stock (Generic, Eq, Show)

instance FromJSON PrincipalRecord where
  parseJSON = withObject "principal" \object ->
    PrincipalRecord
      <$> object .: "principal_id"
      <*> object .: "handle"
      <*> object .: "lifecycle"

-- | Operator choice for the lifecycle directory.
data DirectorySettings
  = DirectoryDisabled
  | DirectoryFile
      { path :: !FilePath,
        refreshInterval :: !NominalDiffTime
      }
  deriving stock (Generic, Eq, Show)

-- | One immutable, fully validated directory snapshot.
data DirectoryView = DirectoryView
  { byPrincipalId :: !(Map Text PrincipalRecord),
    byHandle :: !(Map Text PrincipalRecord),
    loadedAt :: !UTCTime
  }

-- | Fetch and validate the next candidate snapshot.
type DirectorySource = IO (Either Text DirectoryView)

data DirectoryState = DirectoryState
  { snapshot :: !(Maybe DirectoryView),
    lastError :: !(Maybe Text)
  }

-- | Mutable publication point for immutable snapshots.
--
-- Disabled mode is represented explicitly, so it cannot be confused with a
-- configured source that has not produced a valid snapshot yet.
data DirectoryHandle
  = DisabledDirectory
  | ConfiguredDirectory !DirectorySource !(IORef DirectoryState)

-- | Result of consulting lifecycle immediately before a side effect.
data LifecycleDecision
  = AllowRun !(Maybe PrincipalRecord)
  | SkipRun !PrincipalRecord !Text
  | UnknownPrincipal !Text
  | DirectoryUnavailable !Text
  deriving stock (Generic, Eq, Show)

-- | Resources returned to an executable's composition root.
--
-- The optional action is a long-running refresh loop.  Supervision belongs to
-- the executable, alongside its other durable worker loops.
data DirectoryRuntime = DirectoryRuntime
  { handle :: !DirectoryHandle,
    refresher :: !(Maybe (IO ()))
  }

-- | Read a JSON array from disk and turn it into a validated snapshot.
--
-- Unknown object fields are ignored by Aeson.  A malformed candidate never
-- reaches the handle: validation happens before 'Right' is returned.
fileDirectorySource :: FilePath -> DirectorySource
fileDirectorySource filePath = do
  contentsResult <- tryIOError (BS.readFile filePath)
  case contentsResult of
    Left problem -> pure (Left ("could not read directory file " <> Text.pack filePath <> ": " <> Text.pack (show problem)))
    Right contents ->
      case Aeson.eitherDecodeStrict' contents of
        Left problem -> pure (Left ("could not decode directory file " <> Text.pack filePath <> ": " <> Text.pack problem))
        Right principals -> do
          now <- getCurrentTime
          pure (buildDirectoryView now principals)

-- | Build an in-memory source with the same validation as the file source.
--
-- Useful for deterministic tests and for adapters that have already projected
-- an upstream response into 'PrincipalRecord's.
staticDirectorySource :: [PrincipalRecord] -> DirectorySource
staticDirectorySource principals = do
  now <- getCurrentTime
  pure (buildDirectoryView now principals)

-- | Make a configured handle with no initial snapshot.
newDirectoryHandle :: DirectorySource -> IO DirectoryHandle
newDirectoryHandle source = do
  state <- newIORef DirectoryState {snapshot = Nothing, lastError = Nothing}
  pure (ConfiguredDirectory source state)

-- | Compatibility mode: lifecycle checks allow work and attach no principal.
disabledDirectoryHandle :: DirectoryHandle
disabledDirectoryHandle = DisabledDirectory

-- | Fetch and atomically publish one candidate snapshot.
--
-- Failure records its diagnostic but preserves the last valid snapshot.  This
-- is the central last-known-valid invariant: readers see the old complete view
-- or the new complete view, never an invalid or partially-built candidate.
refreshDirectory :: DirectoryHandle -> IO (Either Text ())
refreshDirectory DisabledDirectory = pure (Right ())
refreshDirectory (ConfiguredDirectory source stateRef) = do
  candidate <- source
  atomicModifyIORef' stateRef \state ->
    case candidate of
      Left problem ->
        (state {lastError = Just problem}, Left problem)
      Right newSnapshot ->
        (DirectoryState {snapshot = Just newSnapshot, lastError = Nothing}, Right ())

-- | Construct a directory handle and its supervised refresh action.
--
-- Configured startup requires one valid snapshot.  Once startup succeeds, a
-- later refresh failure is logged and the last valid snapshot remains live.
startDirectory :: Log.Logger -> DirectorySettings -> IO (Either Text DirectoryRuntime)
startDirectory logger = startDirectoryWithHeartbeat logger (pure ())

-- | 'startDirectory' with a callback after every background refresh attempt.
--
-- Composition roots use the callback to heartbeat the supervised directory
-- loop.  It runs after both successes and failures because a failed fetch is a
-- dependency condition while a missing callback means the loop itself wedged.
startDirectoryWithHeartbeat :: Log.Logger -> IO () -> DirectorySettings -> IO (Either Text DirectoryRuntime)
startDirectoryWithHeartbeat _ _ DirectoryDisabled =
  pure (Right DirectoryRuntime {handle = disabledDirectoryHandle, refresher = Nothing})
startDirectoryWithHeartbeat logger heartbeat (DirectoryFile filePath interval)
  | interval <= 0 = pure (Left "directory.refresh_interval_seconds must be positive")
  | otherwise = do
      directoryHandle <- newDirectoryHandle (fileDirectorySource filePath)
      refreshDirectory directoryHandle >>= \case
        Left problem -> pure (Left problem)
        Right () ->
          pure
            ( Right
                DirectoryRuntime
                  { handle = directoryHandle,
                    refresher = Just (refreshLoop logger heartbeat directoryHandle filePath interval)
                  }
            )

-- | Resolve a principal and translate its lifecycle into an enforcement result.
--
-- A declared principal id is authoritative.  Handle fallback is used only when
-- the declaration has no principal id, so a typo cannot accidentally bind to a
-- different principal with a matching human-readable handle.
consultLifecycle :: DirectoryHandle -> Maybe Text -> Text -> IO LifecycleDecision
consultLifecycle DisabledDirectory _ _ = pure (AllowRun Nothing)
consultLifecycle directoryHandle@(ConfiguredDirectory _ stateRef) declaredPrincipalId agentHandle = do
  state <- readIORef stateRef
  case snapshot state of
    Nothing -> pure (DirectoryUnavailable (maybe "directory has no valid snapshot" id (lastError state)))
    Just _ -> do
      found <- lookupPrincipal directoryHandle declaredPrincipalId agentHandle
      pure case found of
        Nothing -> UnknownPrincipal (maybe agentHandle id declaredPrincipalId)
        Just principal -> case lifecycle principal of
          Active -> AllowRun (Just principal)
          Paused -> SkipRun principal "principal lifecycle is paused"
          Deactivated -> SkipRun principal "principal lifecycle is deactivated"

-- | Collapse a lifecycle decision into the shape side-effect gates need.
-- The successful value is the principal id to carry into durable work.
lifecycleAdmission :: DirectoryHandle -> Maybe Text -> Text -> IO (Either Text (Maybe Text))
lifecycleAdmission directoryHandle declaredPrincipalId agentHandle =
  fmap
    ( \case
        AllowRun Nothing -> Right declaredPrincipalId
        AllowRun (Just principal) -> Right (Just (principalId principal))
        SkipRun _ reason -> Left reason
        UnknownPrincipal identifier -> Left ("unknown principal: " <> identifier)
        DirectoryUnavailable problem -> Left ("directory unavailable: " <> problem)
    )
    (consultLifecycle directoryHandle declaredPrincipalId agentHandle)

-- | Resolve the principal stored on a newly opened Kioku session.
--
-- The drain gate has already admitted configured work, so a configured lookup
-- succeeds in normal operation. The fallback preserves disabled-mode behavior
-- and keeps a declared id authoritative if attribution is retried around a
-- snapshot change.
principalAttribution :: DirectoryHandle -> Maybe Text -> Text -> IO Text
principalAttribution directoryHandle declaredPrincipalId agentHandle = do
  found <- lookupPrincipal directoryHandle declaredPrincipalId agentHandle
  pure (maybe (maybe agentHandle id declaredPrincipalId) principalId found)

-- | Look up by authoritative principal id, or by normalized handle only when
-- no id was declared.
lookupPrincipal :: DirectoryHandle -> Maybe Text -> Text -> IO (Maybe PrincipalRecord)
lookupPrincipal DisabledDirectory _ _ = pure Nothing
lookupPrincipal (ConfiguredDirectory _ stateRef) declaredPrincipalId agentHandle = do
  state <- readIORef stateRef
  pure do
    view <- snapshot state
    case declaredPrincipalId of
      Just identifier -> Map.lookup identifier (byPrincipalId view)
      Nothing -> Map.lookup (normalizeHandle agentHandle) (byHandle view)

-- | Principals in deterministic handle order, for inspection and sync commands.
directoryPrincipals :: DirectoryHandle -> IO [PrincipalRecord]
directoryPrincipals DisabledDirectory = pure []
directoryPrincipals (ConfiguredDirectory _ stateRef) = do
  state <- readIORef stateRef
  pure case snapshot state of
    Nothing -> []
    Just view -> sortOn (normalizeHandle . principalHandle) (Map.elems (byPrincipalId view))

refreshLoop :: Log.Logger -> IO () -> DirectoryHandle -> FilePath -> NominalDiffTime -> IO ()
refreshLoop logger heartbeat directoryHandle filePath interval = forever do
  threadDelay (durationMicroseconds interval)
  refreshDirectory directoryHandle >>= \case
    Left problem ->
      Log.logWarn
        logger
        "directory.refresh_failed"
        [ "path" Aeson..= filePath,
          "reason" Aeson..= problem
        ]
    Right () ->
      Log.logDebug logger "directory.refreshed" ["path" Aeson..= filePath]
  heartbeat

durationMicroseconds :: NominalDiffTime -> Int
durationMicroseconds = ceiling . (* 1_000_000) . nominalDiffTimeToSeconds

buildDirectoryView :: UTCTime -> [PrincipalRecord] -> Either Text DirectoryView
buildDirectoryView loadedAt principals = do
  validated <- traverse validatePrincipal principals
  principalIndex <- uniqueIndex "principal id" principalId validated
  handleIndex <- uniqueIndex "normalized handle" (normalizeHandle . principalHandle) validated
  pure DirectoryView {byPrincipalId = principalIndex, byHandle = handleIndex, loadedAt}

validatePrincipal :: PrincipalRecord -> Either Text PrincipalRecord
validatePrincipal principal
  | not ("agent_" `Text.isPrefixOf` principalId principal) =
      Left ("principal id must begin with agent_: " <> principalId principal)
  | Text.null (normalizeHandle (principalHandle principal)) =
      Left ("principal handle must not be empty: " <> principalId principal)
  | otherwise = Right principal

uniqueIndex :: Text -> (PrincipalRecord -> Text) -> [PrincipalRecord] -> Either Text (Map Text PrincipalRecord)
uniqueIndex label key = go Map.empty
  where
    go index [] = Right index
    go index (principal : rest) =
      let value = key principal
       in if Map.member value index
            then Left ("duplicate " <> label <> ": " <> value)
            else go (Map.insert value principal index) rest

normalizeHandle :: Text -> Text
normalizeHandle = Text.toCaseFold . Text.strip

principalHandle :: PrincipalRecord -> Text
principalHandle PrincipalRecord {handle = value} = value
