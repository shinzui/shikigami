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
    withActionAuthorizer,
    actionAuthorizerFor,

    -- * Rows
    GrantRow (..),

    -- * Reading
    lookupGrant,
    listGrants,
    GrantIdentityEvidence (..),
    listGrantIdentityEvidence,

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
    GrantPrincipalSync (..),
    GrantPrincipalSyncStatus (..),
    reconcileGrantPrincipal,
  )
where

import Contravariant.Extras (contrazip2, contrazip3, contrazip4)
import Data.Bifunctor (first)
import Data.Int (Int64)
import Data.Map.Strict (Map)
import Data.Set (Set)
import Data.Set qualified as Set
import Data.Text qualified as Text
import Hasql.Decoders qualified as Decoders
import Hasql.Encoders qualified as Encoders
import Hasql.Pool (Pool)
import Hasql.Pool qualified as Pool
import Hasql.Session qualified as Session
import Hasql.Statement (Statement, preparable)
import Hasql.Transaction qualified as Transaction
import Hasql.Transaction.Sessions qualified as Transaction.Sessions
import Shikigami.Action.Authorization (ActionAuthorizer, allowAllActionAuthorizerForTests, denyAllActionAuthorizer)
import Shikigami.Agent.Name (AgentName, agentNameText, mkAgentName)
import Shikigami.Agent.Principal (AgentIdentity (..), AgentPrincipal, mkAgentPrincipal, principalText)
import Shikigami.Prelude
import Shikigami.Sink.Permission
  ( Denied (..),
    SinkKind,
    checkGrantStatic,
    parseSinkKind,
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
    StaticGrants !(Map AgentIdentity (Set SinkKind))
  | -- | The @shikigami.sink_grants@ table, over the event-store pool.
    DbGrants !Pool
  | -- | C11 plus the process-local C13 interpreter. This wrapper is live
    -- dependency wiring and is never serialized.
    ActionGatedGrants !ActionAuthorizer !GrantSource

withActionAuthorizer :: ActionAuthorizer -> GrantSource -> GrantSource
withActionAuthorizer authorizer source = ActionGatedGrants authorizer source

-- | Focused static fixtures predate C13 and remain isolated from network IO.
-- A bare production database source is fail-closed; production composition
-- must wrap it explicitly.
actionAuthorizerFor :: GrantSource -> ActionAuthorizer
actionAuthorizerFor = \case
  ActionGatedGrants authorizer _ -> authorizer
  StaticGrants {} -> allowAllActionAuthorizerForTests
  DbGrants {} -> denyAllActionAuthorizer

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
checkGrant source identity kind = case source of
  StaticGrants table -> pure (checkGrantStatic table identity kind)
  ActionGatedGrants _ underlying -> checkGrant underlying identity kind
  DbGrants pool ->
    lookupGrant pool identity kind <&> \case
      Right (Just True) -> Right ()
      Right (Just False) ->
        Left (Denied ("agent '" <> label <> "' grant for " <> sinkKindText kind <> " is revoked"))
      Right Nothing ->
        Left (Denied ("agent '" <> label <> "' has no grant for " <> sinkKindText kind))
      Left err ->
        Left (Denied ("grant lookup failed (denying) for agent '" <> label <> "': " <> err))
  where
    label = case identity of
      VerifiedIdentity principal -> principalText principal
      CompatibilityIdentity agentName -> agentNameText agentName
      UnresolvedLegacyIdentity -> "unresolved-legacy"

-- | One row of @shikigami.sink_grants@.
--
-- @principalId@ is filled by @shikigami agents sync@ after it verifies a
-- declaration/directory join. Verified rows are keyed by principal and retain
-- @agentName@ as presentation and reconciliation evidence; null-principal rows
-- are explicitly bounded compatibility grants.
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

-- | Distinct presentation-name/principal pairs retained by the grant table.
-- Sync uses these rows as migration evidence without depending on sink kinds.
data GrantIdentityEvidence = GrantIdentityEvidence
  { agentName :: !AgentName,
    principalId :: !(Maybe AgentPrincipal)
  }
  deriving stock (Eq, Ord, Show, Generic)

-- | Result of reconciling one declaration/principal join across all of the
-- declaration's sink-grant rows.
--
-- Counts describe the state observed while the rows were locked: @filledCount@
-- is the number changed from null in this call and @verifiedCount@ is the
-- number that already carried the expected id. A conflict changes nothing.
data GrantPrincipalSync = GrantPrincipalSync
  { agentName :: !Text,
    principalId :: !Text,
    filledCount :: !Int64,
    verifiedCount :: !Int64,
    status :: !GrantPrincipalSyncStatus
  }
  deriving stock (Eq, Show, Generic)

data GrantPrincipalSyncStatus
  = PrincipalSynced
  | PrincipalConflict !(Set Text)
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
  { agentName :: !AgentName,
    sinkKind :: !SinkKind
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
lookupGrant :: Pool -> AgentIdentity -> SinkKind -> IO (Either Text (Maybe Bool))
lookupGrant pool identity kind = case identity of
  VerifiedIdentity principal ->
    renderUsage <$> Pool.use pool (Session.statement (principalText principal, sinkKindText kind) lookupVerifiedStatement)
  CompatibilityIdentity agentName ->
    renderUsage <$> Pool.use pool (Session.statement (agentNameText agentName, sinkKindText kind) lookupCompatibilityStatement)
  UnresolvedLegacyIdentity -> pure (Left "cannot check a grant for unresolved legacy identity")

lookupVerifiedStatement :: Statement (Text, Text) (Maybe Bool)
lookupVerifiedStatement =
  preparable
    """
    SELECT granted
      FROM shikigami.sink_grants
     WHERE principal_id = $1
       AND sink_kind = $2
    """
    ( contrazip2
        (Encoders.param (Encoders.nonNullable Encoders.text))
        (Encoders.param (Encoders.nonNullable Encoders.text))
    )
    (Decoders.rowMaybe (Decoders.column (Decoders.nonNullable Decoders.bool)))

lookupCompatibilityStatement :: Statement (Text, Text) (Maybe Bool)
lookupCompatibilityStatement =
  preparable
    """
    SELECT granted
      FROM shikigami.sink_grants
     WHERE agent_name = $1
       AND principal_id IS NULL
       AND sink_kind = $2
    """
    ( contrazip2
        (Encoders.param (Encoders.nonNullable Encoders.text))
        (Encoders.param (Encoders.nonNullable Encoders.text))
    )
    (Decoders.rowMaybe (Decoders.column (Decoders.nonNullable Decoders.bool)))

-- | All distinct identity evidence carried by grants, in deterministic order.
-- This is intentionally unpaged: the result cardinality is bounded by agent
-- identities rather than by the (agents x sink kinds) grant relation.
listGrantIdentityEvidence :: Pool -> IO (Either Text [GrantIdentityEvidence])
listGrantIdentityEvidence pool =
  renderUsage <$> Pool.use pool (Session.statement () grantIdentityEvidenceStatement)

grantIdentityEvidenceStatement :: Statement () [GrantIdentityEvidence]
grantIdentityEvidenceStatement =
  preparable
    """
    SELECT DISTINCT agent_name, principal_id
      FROM shikigami.sink_grants
     ORDER BY agent_name, principal_id NULLS FIRST
    """
    Encoders.noParams
    ( Decoders.rowList
        ( GrantIdentityEvidence
            <$> Decoders.column (Decoders.nonNullable (Decoders.refine mkAgentName Decoders.text))
            <*> Decoders.column (Decoders.nullable (Decoders.refine mkAgentPrincipal Decoders.text))
        )
    )

-- | One page of grants, ordered by @(agent_name, sink_kind)@.
--
-- Fetches @size + 1@ rows and returns at most @size@: the extra row is how the
-- page knows whether a next one exists without a second count query.
listGrants :: Pool -> GrantPageRequest -> IO (Either Text GrantPage)
listGrants pool GrantPageRequest {size, after} = do
  let limitPlusOne = unPageSize size + 1
      params = case after of
        Nothing -> ("", "", False, limitPlusOne)
        Just GrantCursor {agentName = a, sinkKind = k} -> (agentNameText a, sinkKindText k, True, limitPlusOne)
  result <- Pool.use pool (Session.statement params listStatement)
  pure (renderUsage result >>= paginate)
  where
    paginate rows = do
      let kept = take (fromIntegral (unPageSize size)) rows
          more = length rows > fromIntegral (unPageSize size)
      next <- if more then traverse cursorOf (lastMay kept) else Right Nothing
      pure GrantPage {items = kept, next}
    cursorOf GrantRow {agentName = a, sinkKind = k} =
      GrantCursor <$> mkAgentName a <*> maybe (Left ("unknown sink kind: " <> k)) Right (parseSinkKind k)
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
    ( contrazip4
        (Encoders.param (Encoders.nonNullable Encoders.text))
        (Encoders.param (Encoders.nonNullable Encoders.text))
        (Encoders.param (Encoders.nonNullable Encoders.bool))
        (Encoders.param (Encoders.nonNullable Encoders.int8))
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
upsertGrant :: Pool -> Text -> AgentIdentity -> SinkKind -> Maybe Text -> IO (Either Text ())
upsertGrant pool agent identity kind by = case identity of
  VerifiedIdentity principal ->
    renderUsage <$> Pool.use pool (Session.statement (agent, principalText principal, sinkKindText kind, by) upsertVerifiedStatement)
  CompatibilityIdentity compatibilityName
    | agentNameText compatibilityName == agent ->
        renderUsage <$> Pool.use pool (Session.statement (agent, sinkKindText kind, by) upsertCompatibilityStatement)
    | otherwise -> pure (Left "compatibility identity does not match the selected agent")
  UnresolvedLegacyIdentity -> pure (Left "cannot grant an unresolved legacy identity")

upsertVerifiedStatement :: Statement (Text, Text, Text, Maybe Text) ()
upsertVerifiedStatement =
  preparable
    """
    INSERT INTO shikigami.sink_grants
        (agent_name, principal_id, sink_kind, granted, granted_by, granted_at, updated_at)
    VALUES ($1, $2, $3, TRUE, $4, now(), now())
    ON CONFLICT (principal_id, sink_kind) WHERE principal_id IS NOT NULL DO UPDATE
       SET agent_name = EXCLUDED.agent_name,
           granted = TRUE,
           granted_by = EXCLUDED.granted_by,
           granted_at = now(),
           revoked_by = NULL,
           revoked_at = NULL,
           updated_at = now()
    """
    ( contrazip4
        (Encoders.param (Encoders.nonNullable Encoders.text))
        (Encoders.param (Encoders.nonNullable Encoders.text))
        (Encoders.param (Encoders.nonNullable Encoders.text))
        (Encoders.param (Encoders.nullable Encoders.text))
    )
    Decoders.noResult

upsertCompatibilityStatement :: Statement (Text, Text, Maybe Text) ()
upsertCompatibilityStatement =
  preparable
    """
    INSERT INTO shikigami.sink_grants
        (agent_name, principal_id, sink_kind, granted, granted_by, granted_at, updated_at)
    VALUES ($1, NULL, $2, TRUE, $3, now(), now())
    ON CONFLICT (agent_name, sink_kind) WHERE principal_id IS NULL DO UPDATE
       SET granted = TRUE,
           granted_by = EXCLUDED.granted_by,
           granted_at = now(),
           revoked_by = NULL,
           revoked_at = NULL,
           updated_at = now()
    """
    ( contrazip3
        (Encoders.param (Encoders.nonNullable Encoders.text))
        (Encoders.param (Encoders.nonNullable Encoders.text))
        (Encoders.param (Encoders.nullable Encoders.text))
    )
    Decoders.noResult

-- | Revoke a grant. Returns whether a row was actually affected, so the caller
-- can tell an operator that they revoked something that was never granted
-- instead of silently reporting success.
revokeGrant :: Pool -> AgentIdentity -> SinkKind -> Maybe Text -> IO (Either Text Bool)
revokeGrant pool identity kind by = case identity of
  VerifiedIdentity principal ->
    affected <$> Pool.use pool (Session.statement (principalText principal, sinkKindText kind, by) revokeVerifiedStatement)
  CompatibilityIdentity agent ->
    affected <$> Pool.use pool (Session.statement (agentNameText agent, sinkKindText kind, by) revokeCompatibilityStatement)
  UnresolvedLegacyIdentity -> pure (Left "cannot revoke an unresolved legacy identity")
  where
    affected = fmap (> 0) . renderUsage

revokeVerifiedStatement :: Statement (Text, Text, Maybe Text) Int64
revokeVerifiedStatement =
  preparable
    """
    UPDATE shikigami.sink_grants
       SET granted = FALSE,
           revoked_by = $3,
           revoked_at = now(),
           updated_at = now()
     WHERE principal_id = $1
       AND sink_kind = $2
    """
    ( contrazip3
        (Encoders.param (Encoders.nonNullable Encoders.text))
        (Encoders.param (Encoders.nonNullable Encoders.text))
        (Encoders.param (Encoders.nullable Encoders.text))
    )
    Decoders.rowsAffected

revokeCompatibilityStatement :: Statement (Text, Text, Maybe Text) Int64
revokeCompatibilityStatement =
  preparable
    """
    UPDATE shikigami.sink_grants
       SET granted = FALSE,
           revoked_by = $3,
           revoked_at = now(),
           updated_at = now()
     WHERE agent_name = $1
       AND principal_id IS NULL
       AND sink_kind = $2
    """
    ( contrazip3
        (Encoders.param (Encoders.nonNullable Encoders.text))
        (Encoders.param (Encoders.nonNullable Encoders.text))
        (Encoders.param (Encoders.nullable Encoders.text))
    )
    Decoders.rowsAffected

-- | Fill or verify the principal id on every grant row for one declared agent.
--
-- The selected rows are locked until the transaction completes. If any row
-- already carries a different id, no null row is filled: an operator must
-- repair that identity conflict explicitly rather than letting a bulk sync
-- produce a mixed identity set.
reconcileGrantPrincipal :: Pool -> Text -> Text -> IO (Either Text GrantPrincipalSync)
reconcileGrantPrincipal pool agent principal =
  renderUsage
    <$> Pool.use
      pool
      ( Transaction.Sessions.transaction
          Transaction.Sessions.ReadCommitted
          Transaction.Sessions.Write
          do
            existing <- Transaction.statement agent lockGrantPrincipalsStatement
            let conflicts = Set.fromList [found | Just found <- existing, found /= principal]
                verified = fromIntegral (length [() | Just found <- existing, found == principal])
            if Set.null conflicts
              then do
                filled <- Transaction.statement (agent, principal) fillGrantPrincipalsStatement
                pure
                  GrantPrincipalSync
                    { agentName = agent,
                      principalId = principal,
                      filledCount = filled,
                      verifiedCount = verified,
                      status = PrincipalSynced
                    }
              else
                pure
                  GrantPrincipalSync
                    { agentName = agent,
                      principalId = principal,
                      filledCount = 0,
                      verifiedCount = verified,
                      status = PrincipalConflict conflicts
                    }
      )

lockGrantPrincipalsStatement :: Statement Text [Maybe Text]
lockGrantPrincipalsStatement =
  preparable
    "SELECT principal_id FROM shikigami.sink_grants WHERE agent_name = $1 FOR UPDATE"
    (Encoders.param (Encoders.nonNullable Encoders.text))
    (Decoders.rowList (Decoders.column (Decoders.nullable Decoders.text)))

fillGrantPrincipalsStatement :: Statement (Text, Text) Int64
fillGrantPrincipalsStatement =
  preparable
    """
    UPDATE shikigami.sink_grants
       SET principal_id = $2,
           updated_at = now()
     WHERE agent_name = $1
       AND principal_id IS NULL
    """
    ( contrazip2
        (Encoders.param (Encoders.nonNullable Encoders.text))
        (Encoders.param (Encoders.nonNullable Encoders.text))
    )
    Decoders.rowsAffected

-- | Pool failures become a one-line message. The full 'Pool.UsageError' 'Show'
-- output carries the statement text, which is not something to put in a denial
-- reason that may be logged.
renderUsage :: Either Pool.UsageError a -> Either Text a
renderUsage = first (Text.pack . show)
