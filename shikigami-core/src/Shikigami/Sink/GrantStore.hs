{-# LANGUAGE MultilineStrings #-}

-- | Reading and writing the C11 sink-grant table.
--
-- A \"grant\" is the statement \"agent X may use sink kind K\". Before this
-- module those statements were a 'Data.Map.Map' compiled into the binary, so
-- granting a new agent a sink meant editing Haskell and redeploying every
-- process. They now live in @shikigami.sink_grants@, and this module is the only
-- place that talks to it.
--
-- Three things about the table are worth knowing before reading the SQL.
--
-- Every statement is __schema-qualified__. The pool these run on is the
-- event-store pool, whose @search_path@ is @kiroku@ (kiroku-store's
-- @defaultConnectionSettings@), so an unqualified @sink_grants@ would resolve to
-- the wrong schema or to nothing at all.
--
-- A revocation is a __row update, not a delete__: @granted = FALSE@ with
-- @revoked_by@ and @revoked_at@ filled in. The row stays so that "this agent was
-- deliberately revoked" is distinguishable from "nobody ever granted this", both
-- to an operator reading the table and to a later audit.
--
-- 'listGrants' is __keyset-paginated__ and never loads the whole table. That is
-- not premature: the grant table is read by an operator command whose output
-- goes to a terminal, and an unbounded @SELECT@ over a table that grows with
-- (agents × sink kinds) is the kind of thing that is fine until it is not.
module Shikigami.Sink.GrantStore
  ( -- * The gate
    GrantSource (..),
    checkGrant,

    -- * Rows
    GrantRow (..),

    -- * Reading
    lookupGrant,
    listGrants,

    -- * Paging
    PageSize,
    mkPageSize,
    unPageSize,
    defaultPageSize,
    GrantCursor (..),
    GrantPageRequest (..),
    GrantPage (..),

    -- * Writing
    upsertGrant,
    revokeGrant,
  )
where

import Data.Bifunctor (first)
import Data.Functor.Contravariant ((>$<))
import Data.Int (Int64)
import Data.Map.Strict (Map)
import Data.Set (Set)
import Data.Text qualified as Text
import Hasql.Decoders qualified as Decoders
import Hasql.Encoders qualified as Encoders
import Hasql.Pool (Pool)
import Hasql.Pool qualified as Pool
import Hasql.Session qualified as Session
import Hasql.Statement (Statement, preparable)
import Shikigami.Prelude
import Shikigami.Sink.Permission
  ( AgentIdentity (..),
    Denied (..),
    SinkKind,
    checkGrantStatic,
    sinkKindText,
  )

-- | Where grants come from.
--
-- A small sum rather than a threaded function value: there are four gate call
-- sites and several dependency records to construct, and a named constructor at
-- each process boot makes "which source is this process using?" answerable by
-- reading the composition root.
data GrantSource
  = -- | The compiled-in table from "Shikigami.Sink.Permission". Test and seed
    -- data now — no production process builds this.
    StaticGrants !(Map Text (Set SinkKind))
  | -- | The @shikigami.sink_grants@ table, over the event-store pool.
    DbGrants !Pool

-- | Is this agent permitted this sink kind? @Right ()@ if granted, else
-- @Left (Denied reason)@.
--
-- __The database arm fails closed.__ If the lookup errors, the sink is denied
-- with the error in the reason. C11 is a trust boundary, and delivering to an
-- external service when we cannot prove a grant exists is exactly the failure
-- the gate exists to prevent.
--
-- The three database outcomes are distinguished in the reason text because an
-- operator reading a denial needs to know which one happened: a revoked grant
-- means somebody did that deliberately, a missing grant means nobody ever
-- granted it, and a lookup failure means the gate could not tell and refused.
checkGrant :: GrantSource -> AgentIdentity -> SinkKind -> IO (Either Denied ())
checkGrant source identity@(AgentIdentity nm) kind = case source of
  StaticGrants table -> pure (checkGrantStatic table identity kind)
  DbGrants pool ->
    lookupGrant pool nm kind <&> \case
      Right (Just True) -> Right ()
      Right (Just False) ->
        Left (Denied ("agent '" <> nm <> "' grant for " <> sinkKindText kind <> " is revoked"))
      Right Nothing ->
        Left (Denied ("agent '" <> nm <> "' has no grant for " <> sinkKindText kind))
      Left err ->
        Left (Denied ("grant lookup failed (denying) for agent '" <> nm <> "': " <> err))

-- | One row of @shikigami.sink_grants@.
--
-- @principalId@ is always 'Nothing' today. The column exists so that
-- @docs\/plans\/23-agent-lifecycle-control-with-meibo-principals.md@ can re-key
-- grants by verified principal without reshaping the table.
data GrantRow = GrantRow
  { agentName :: !Text,
    principalId :: !(Maybe Text),
    sinkKind :: !Text,
    granted :: !Bool,
    grantedBy :: !(Maybe Text),
    grantedAt :: !UTCTime,
    revokedBy :: !(Maybe Text),
    revokedAt :: !(Maybe UTCTime)
  }
  deriving stock (Eq, Show, Generic)

-- | How many rows one page may carry. The constructor is private: a caller
-- cannot ask for an unbounded page, because 'mkPageSize' is the only way in.
newtype PageSize = PageSize Int64
  deriving stock (Eq, Ord, Show)

-- | Accept a page size between 1 and 200, rejecting anything else with a
-- message an operator can act on.
mkPageSize :: Int -> Either Text PageSize
mkPageSize n
  | n < 1 = Left "page size must be at least 1"
  | n > 200 = Left "page size must be at most 200"
  | otherwise = Right (PageSize (fromIntegral n))

unPageSize :: PageSize -> Int64
unPageSize (PageSize n) = n

-- | Fifty rows: enough to read a small deployment's whole grant table in one
-- page, small enough to stay a terminal-sized answer.
defaultPageSize :: PageSize
defaultPageSize = PageSize 50

-- | Where the previous page stopped. Ordering is @(agent_name, sink_kind)@, so
-- the cursor is exactly that pair — the last row the caller has already seen.
data GrantCursor = GrantCursor
  { agentName :: !Text,
    sinkKind :: !Text
  }
  deriving stock (Eq, Show, Generic)

data GrantPageRequest = GrantPageRequest
  { size :: !PageSize,
    after :: !(Maybe GrantCursor)
  }

-- | At most @size@ rows, plus where to resume. @next@ is 'Nothing' exactly when
-- the page is the last one.
data GrantPage = GrantPage
  { items :: ![GrantRow],
    next :: !(Maybe GrantCursor)
  }

-- | Is this agent granted this sink kind?
--
-- Three-valued on purpose: @Right Nothing@ (no row — never granted) is a
-- different fact from @Right (Just False)@ (a row saying revoked), and the
-- caller renders them differently. A pool failure is @Left@ and the caller must
-- fail closed.
lookupGrant :: Pool -> Text -> SinkKind -> IO (Either Text (Maybe Bool))
lookupGrant pool agent kind =
  renderUsage <$> Pool.use pool (Session.statement (agent, sinkKindText kind) lookupStatement)

lookupStatement :: Statement (Text, Text) (Maybe Bool)
lookupStatement =
  preparable
    """
    SELECT granted
      FROM shikigami.sink_grants
     WHERE agent_name = $1
       AND sink_kind = $2
    """
    ( (fst >$< Encoders.param (Encoders.nonNullable Encoders.text))
        <> (snd >$< Encoders.param (Encoders.nonNullable Encoders.text))
    )
    (Decoders.rowMaybe (Decoders.column (Decoders.nonNullable Decoders.bool)))

-- | One page of grants, ordered by @(agent_name, sink_kind)@.
--
-- Fetches @size + 1@ rows and returns at most @size@: the extra row is how the
-- page knows whether a next one exists without a second count query.
listGrants :: Pool -> GrantPageRequest -> IO (Either Text GrantPage)
listGrants pool GrantPageRequest {size, after} = do
  let limitPlusOne = unPageSize size + 1
      params = case after of
        Nothing -> ("", "", False, limitPlusOne)
        Just GrantCursor {agentName = a, sinkKind = k} -> (a, k, True, limitPlusOne)
  result <- Pool.use pool (Session.statement params listStatement)
  pure (paginate <$> renderUsage result)
  where
    paginate rows =
      let kept = take (fromIntegral (unPageSize size)) rows
          more = length rows > fromIntegral (unPageSize size)
          cursorOf GrantRow {agentName = a, sinkKind = k} = GrantCursor {agentName = a, sinkKind = k}
       in GrantPage
            { items = kept,
              next = if more then cursorOf <$> lastMay kept else Nothing
            }
    lastMay [] = Nothing
    lastMay xs = Just (last xs)

-- | The keyset predicate is @($3 = FALSE) OR (agent_name, sink_kind) > ($1, $2)@:
-- a row-value comparison, which is what makes a two-column keyset both correct
-- and index-friendly on the primary key.
listStatement :: Statement (Text, Text, Bool, Int64) [GrantRow]
listStatement =
  preparable
    """
    SELECT agent_name, principal_id, sink_kind, granted,
           granted_by, granted_at, revoked_by, revoked_at
      FROM shikigami.sink_grants
     WHERE (NOT $3) OR ((agent_name, sink_kind) > ($1, $2))
     ORDER BY agent_name, sink_kind
     LIMIT $4
    """
    ( ((\(a, _, _, _) -> a) >$< Encoders.param (Encoders.nonNullable Encoders.text))
        <> ((\(_, k, _, _) -> k) >$< Encoders.param (Encoders.nonNullable Encoders.text))
        <> ((\(_, _, u, _) -> u) >$< Encoders.param (Encoders.nonNullable Encoders.bool))
        <> ((\(_, _, _, l) -> l) >$< Encoders.param (Encoders.nonNullable Encoders.int8))
    )
    (Decoders.rowList grantRow)

grantRow :: Decoders.Row GrantRow
grantRow =
  GrantRow
    <$> Decoders.column (Decoders.nonNullable Decoders.text)
    <*> Decoders.column (Decoders.nullable Decoders.text)
    <*> Decoders.column (Decoders.nonNullable Decoders.text)
    <*> Decoders.column (Decoders.nonNullable Decoders.bool)
    <*> Decoders.column (Decoders.nullable Decoders.text)
    <*> Decoders.column (Decoders.nonNullable Decoders.timestamptz)
    <*> Decoders.column (Decoders.nullable Decoders.text)
    <*> Decoders.column (Decoders.nullable Decoders.timestamptz)

-- | Grant a sink kind to an agent, or re-grant a previously revoked one.
--
-- Re-granting clears @revoked_by@ and @revoked_at@ rather than leaving them set,
-- so a row never claims to be both granted and revoked.
upsertGrant :: Pool -> Text -> SinkKind -> Maybe Text -> IO (Either Text ())
upsertGrant pool agent kind by =
  renderUsage <$> Pool.use pool (Session.statement (agent, sinkKindText kind, by) upsertStatement)

upsertStatement :: Statement (Text, Text, Maybe Text) ()
upsertStatement =
  preparable
    """
    INSERT INTO shikigami.sink_grants
        (agent_name, sink_kind, granted, granted_by, granted_at, updated_at)
    VALUES ($1, $2, TRUE, $3, now(), now())
    ON CONFLICT (agent_name, sink_kind) DO UPDATE
       SET granted = TRUE,
           granted_by = EXCLUDED.granted_by,
           granted_at = now(),
           revoked_by = NULL,
           revoked_at = NULL,
           updated_at = now()
    """
    ( ((\(a, _, _) -> a) >$< Encoders.param (Encoders.nonNullable Encoders.text))
        <> ((\(_, k, _) -> k) >$< Encoders.param (Encoders.nonNullable Encoders.text))
        <> ((\(_, _, b) -> b) >$< Encoders.param (Encoders.nullable Encoders.text))
    )
    Decoders.noResult

-- | Revoke a grant. Returns whether a row was actually affected, so the caller
-- can tell an operator that they revoked something that was never granted
-- instead of silently reporting success.
revokeGrant :: Pool -> Text -> SinkKind -> Maybe Text -> IO (Either Text Bool)
revokeGrant pool agent kind by =
  fmap (> 0) . renderUsage
    <$> Pool.use pool (Session.statement (agent, sinkKindText kind, by) revokeStatement)

revokeStatement :: Statement (Text, Text, Maybe Text) Int64
revokeStatement =
  preparable
    """
    UPDATE shikigami.sink_grants
       SET granted = FALSE,
           revoked_by = $3,
           revoked_at = now(),
           updated_at = now()
     WHERE agent_name = $1
       AND sink_kind = $2
    """
    ( ((\(a, _, _) -> a) >$< Encoders.param (Encoders.nonNullable Encoders.text))
        <> ((\(_, k, _) -> k) >$< Encoders.param (Encoders.nonNullable Encoders.text))
        <> ((\(_, _, b) -> b) >$< Encoders.param (Encoders.nullable Encoders.text))
    )
    Decoders.rowsAffected

-- | Pool failures become a one-line message. The full 'Pool.UsageError' 'Show'
-- output carries the statement text, which is not something to put in a denial
-- reason that may be logged.
renderUsage :: Either Pool.UsageError a -> Either Text a
renderUsage = first (Text.pack . show)
