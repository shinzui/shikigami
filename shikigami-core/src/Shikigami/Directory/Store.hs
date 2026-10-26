-- | Durable evidence for manifest loading and lifecycle admission refusals.
--
-- Every statement is schema-qualified because the shared Kiroku pool uses a
-- non-public search path. Load reports are reconciled in one transaction, and
-- run skips expose a transaction entry point so Kafka inbox ownership and skip
-- evidence can commit together.
module Shikigami.Directory.Store
  ( SkipStage (..),
    RunSkip (..),
    recordLoadStates,
    recordRunSkip,
    recordRunSkipTx,
    listRunSkips,
    lookupDrainSkip,
  )
where

import Control.Lens (view)
import Data.Bifunctor (first)
import Data.Foldable (traverse_)
import Data.Functor.Contravariant ((>$<))
import Data.Generics.Labels ()
import Data.Text (Text)
import Data.Text qualified as Text
import Data.Time (UTCTime, getCurrentTime)
import GHC.Generics (Generic)
import Hasql.Decoders qualified as Decoders
import Hasql.Encoders qualified as Encoders
import Hasql.Pool (Pool)
import Hasql.Pool qualified as Pool
import Hasql.Session qualified as Session
import Hasql.Statement (Statement, preparable)
import Hasql.Transaction (Transaction)
import Hasql.Transaction qualified as Transaction
import Hasql.Transaction.Sessions qualified as Transaction.Sessions
import Shikigami.Agent.Decl (AgentDecl (..), IdentityDecl (..))
import Shikigami.Agent.Loader (AgentLoadEntry (..), AgentLoadReport (..), LoadError (..))

-- | Admission boundary that refused a run.
data SkipStage = TriggerStage | DrainStage
  deriving stock (Generic, Eq, Ord, Show)

-- | One idempotent trigger or queue-drain refusal.
data RunSkip = RunSkip
  { agentName :: !Text,
    principalId :: !(Maybe Text),
    stage :: !SkipStage,
    detail :: !Text,
    reason :: !Text,
    idempotencyKey :: !Text
  }
  deriving stock (Generic, Eq, Show)

data LoadStatus = Loaded | Failed
  deriving stock (Generic, Eq, Show)

data LoadState = LoadState
  { manifestPath :: !FilePath,
    manifestDirectory :: !FilePath,
    agentName :: !(Maybe Text),
    principalId :: !(Maybe Text),
    status :: !LoadStatus,
    enabled :: !(Maybe Bool),
    error :: !(Maybe Text),
    observedAt :: !UTCTime
  }
  deriving stock (Generic, Eq, Show)

-- | Replace the durable view of one configured manifest directory atomically.
--
-- Deleting that directory's prior rows before upserting the completed report is
-- safe because both operations share a transaction: readers see either the old
-- complete view or the new complete view. An empty report intentionally clears
-- stale paths from the directory.
recordLoadStates :: Pool -> FilePath -> AgentLoadReport -> IO (Either Text ())
recordLoadStates pool directory report = do
  observedAt <- getCurrentTime
  let rows = loadStateRows directory observedAt report
      transaction = do
        Transaction.statement directory deleteDirectoryStatement
        traverse_ (\row -> Transaction.statement row upsertLoadStateStatement) rows
  renderUsage
    <$> Pool.use
      pool
      ( Transaction.Sessions.transaction
          Transaction.Sessions.ReadCommitted
          Transaction.Sessions.Write
          transaction
      )

-- | Record one refusal in its own transaction.
recordRunSkip :: Pool -> RunSkip -> IO (Either Text ())
recordRunSkip pool runSkip =
  renderUsage
    <$> Pool.use
      pool
      ( Transaction.Sessions.transaction
          Transaction.Sessions.ReadCommitted
          Transaction.Sessions.Write
          (recordRunSkipTx runSkip)
      )

-- | Record one refusal inside a caller-owned transaction.
--
-- The uniqueness constraint and @ON CONFLICT@ make retrying the same boundary
-- a no-op while allowing the same external key at a different boundary.
recordRunSkipTx :: RunSkip -> Transaction ()
recordRunSkipTx runSkip = Transaction.statement runSkip recordRunSkipStatement

-- | Read lifecycle refusals in insertion order for operator inspection.
listRunSkips :: Pool -> IO (Either Text [RunSkip])
listRunSkips pool =
  renderUsage <$> Pool.use pool (Session.statement () listRunSkipsStatement)

loadStateRows :: FilePath -> UTCTime -> AgentLoadReport -> [LoadState]
loadStateRows directory observedAt AgentLoadReport {entries} = fmap toRow entries
  where
    toRow = \case
      AgentLoaded
        { path,
          declaration = AgentDecl {name, identity, enabled}
        } ->
          LoadState
            { manifestPath = path,
              manifestDirectory = directory,
              agentName = Just name,
              principalId = declaredPrincipal <$> identity,
              status = Loaded,
              enabled = Just enabled,
              error = Nothing,
              observedAt
            }
      AgentLoadFailed {path, error = LoadError problem} ->
        LoadState
          { manifestPath = path,
            manifestDirectory = directory,
            agentName = Nothing,
            principalId = Nothing,
            status = Failed,
            enabled = Nothing,
            error = Just problem,
            observedAt
          }

declaredPrincipal :: IdentityDecl -> Text
declaredPrincipal IdentityDecl {principal} = principal

deleteDirectoryStatement :: Statement FilePath ()
deleteDirectoryStatement =
  preparable
    "DELETE FROM shikigami.agent_load_state WHERE manifest_directory = $1"
    (Text.pack >$< Encoders.param (Encoders.nonNullable Encoders.text))
    Decoders.noResult

upsertLoadStateStatement :: Statement LoadState ()
upsertLoadStateStatement =
  preparable
    """
    INSERT INTO shikigami.agent_load_state
      (manifest_path, manifest_directory, agent_name, principal_id, status,
       enabled, error, observed_at)
    VALUES ($1, $2, $3, $4, $5, $6, $7, $8)
    ON CONFLICT (manifest_path) DO UPDATE SET
      manifest_directory = EXCLUDED.manifest_directory,
      agent_name = EXCLUDED.agent_name,
      principal_id = EXCLUDED.principal_id,
      status = EXCLUDED.status,
      enabled = EXCLUDED.enabled,
      error = EXCLUDED.error,
      observed_at = EXCLUDED.observed_at
    """
    ( (Text.pack . view #manifestPath >$< Encoders.param (Encoders.nonNullable Encoders.text))
        <> (Text.pack . view #manifestDirectory >$< Encoders.param (Encoders.nonNullable Encoders.text))
        <> (view #agentName >$< Encoders.param (Encoders.nullable Encoders.text))
        <> (view #principalId >$< Encoders.param (Encoders.nullable Encoders.text))
        <> (renderLoadStatus . view #status >$< Encoders.param (Encoders.nonNullable Encoders.text))
        <> (view #enabled >$< Encoders.param (Encoders.nullable Encoders.bool))
        <> (view #error >$< Encoders.param (Encoders.nullable Encoders.text))
        <> (view #observedAt >$< Encoders.param (Encoders.nonNullable Encoders.timestamptz))
    )
    Decoders.noResult

recordRunSkipStatement :: Statement RunSkip ()
recordRunSkipStatement =
  preparable
    """
    INSERT INTO shikigami.run_skips
      (agent_name, principal_id, stage, detail, reason, idempotency_key)
    VALUES ($1, $2, $3, $4, $5, $6)
    ON CONFLICT (stage, idempotency_key) DO NOTHING
    """
    ( (view #agentName >$< Encoders.param (Encoders.nonNullable Encoders.text))
        <> (view #principalId >$< Encoders.param (Encoders.nullable Encoders.text))
        <> (renderSkipStage . view #stage >$< Encoders.param (Encoders.nonNullable Encoders.text))
        <> (view #detail >$< Encoders.param (Encoders.nonNullable Encoders.text))
        <> (view #reason >$< Encoders.param (Encoders.nonNullable Encoders.text))
        <> (view #idempotencyKey >$< Encoders.param (Encoders.nonNullable Encoders.text))
    )
    Decoders.noResult

listRunSkipsStatement :: Statement () [RunSkip]
listRunSkipsStatement =
  preparable
    """
    SELECT agent_name, principal_id, stage, detail, reason, idempotency_key
      FROM shikigami.run_skips
     ORDER BY occurred_at, run_skip_id
    """
    Encoders.noParams
    (Decoders.rowList runSkipRow)

runSkipRow :: Decoders.Row RunSkip
runSkipRow =
  RunSkip
    <$> Decoders.column (Decoders.nonNullable Decoders.text)
    <*> Decoders.column (Decoders.nullable Decoders.text)
    <*> Decoders.column (Decoders.nonNullable (Decoders.refine parseSkipStage Decoders.text))
    <*> Decoders.column (Decoders.nonNullable Decoders.text)
    <*> Decoders.column (Decoders.nonNullable Decoders.text)
    <*> Decoders.column (Decoders.nonNullable Decoders.text)

renderLoadStatus :: LoadStatus -> Text
renderLoadStatus = \case
  Loaded -> "loaded"
  Failed -> "failed"

renderSkipStage :: SkipStage -> Text
renderSkipStage = \case
  TriggerStage -> "trigger"
  DrainStage -> "drain"

parseSkipStage :: Text -> Either Text SkipStage
parseSkipStage = \case
  "trigger" -> Right TriggerStage
  "drain" -> Right DrainStage
  other -> Left ("unknown run skip stage: " <> other)

renderUsage :: Either Pool.UsageError a -> Either Text a
renderUsage = first (Text.pack . show)

-- | Indexed lookup of the drain refusal for one accepted run.
lookupDrainSkip :: Pool -> Text -> Text -> IO (Either Text (Maybe RunSkip))
lookupDrainSkip pool agent key = renderUsage <$> Pool.use pool (Session.statement (agent, key) statement)
  where
    statement =
      preparable
        "SELECT agent_name,principal_id,stage,detail,reason,idempotency_key FROM shikigami.run_skips WHERE agent_name=$1 AND stage='drain' AND idempotency_key=$2"
        ((fst >$< Encoders.param (Encoders.nonNullable Encoders.text)) <> (snd >$< Encoders.param (Encoders.nonNullable Encoders.text)))
        (Decoders.rowMaybe runSkipRow)
