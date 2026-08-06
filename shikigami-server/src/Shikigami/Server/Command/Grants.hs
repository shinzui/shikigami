-- | @shikigami grants list|grant|revoke@: the operator surface over the C11
-- sink-grant table.
--
-- Before this command, granting an agent a sink meant editing
-- @defaultGrantTable@ in @shikigami-core@ and redeploying every process. These
-- three subcommands write @shikigami.sink_grants@, and the running worker picks
-- the change up on its next dispatch — there is no cache to invalidate and no
-- restart to schedule, because the gate reads the table per check.
--
-- Output is human-readable on standard out. These are one-shot operator
-- commands, not a runtime loop, so they are a terminal interface rather than a
-- log stream; the structured-JSON vocabulary in "Shikigami.Log" deliberately
-- does not apply here.
module Shikigami.Server.Command.Grants
  ( runGrantsList,
    runGrantsGrant,
    runGrantsRevoke,
  )
where

import Data.Text (Text)
import Data.Text qualified as Text
import Data.Text.IO qualified as TextIO
import Data.Time.Format.ISO8601 (iso8601Show)
import Hasql.Pool (Pool)
import Kiroku.Store.Connection (KirokuStore (..), defaultConnectionSettings, withStore)
import Shikigami.App.Config (AppConfig, revealSecretText)
import Shikigami.App.Config.Load (requireDatabaseUrl)
import Shikigami.Sink.GrantStore
  ( GrantCursor (..),
    GrantPage (..),
    GrantPageRequest (..),
    GrantRow (..),
    defaultPageSize,
    listGrants,
    mkPageSize,
    revokeGrant,
    upsertGrant,
  )
import Shikigami.Sink.Permission (SinkKind, parseSinkKind, sinkKindText)
import System.Exit (exitFailure)
import System.IO (hPutStrLn, stderr)

-- | @grants list [--limit N] [--after AGENT:KIND]@.
--
-- Validation happens before the pool opens, so a bad @--limit@ or cursor costs
-- no connection.
runGrantsList :: Maybe Int -> Maybe String -> AppConfig -> IO ()
runGrantsList mlimit mafter config = do
  size <- either (die "grants list") pure (maybe (Right defaultPageSize) mkPageSize mlimit)
  after <- either (die "grants list") pure (traverse parseCursor mafter)
  withPool config "grants list" \pool -> do
    result <- listGrants pool GrantPageRequest {size, after}
    case result of
      Left err -> die "grants list" err
      Right GrantPage {items, next} -> do
        if null items
          then putStrLn "no grants"
          else mapM_ (TextIO.putStrLn . renderRow) items
        case next of
          Nothing -> pure ()
          Just GrantCursor {agentName = a, sinkKind = k} ->
            putStrLn ("-- more: --after " <> Text.unpack a <> ":" <> Text.unpack k)

-- | @grants grant <agent> <kind> [--by WHO]@.
runGrantsGrant :: String -> String -> Maybe String -> AppConfig -> IO ()
runGrantsGrant agent kindArg by config = do
  kind <- requireKind "grants grant" kindArg
  withPool config "grants grant" \pool ->
    upsertGrant pool (Text.pack agent) kind (Text.pack <$> by) >>= \case
      Left err -> die "grants grant" err
      Right () ->
        putStrLn ("granted " <> agent <> " " <> Text.unpack (sinkKindText kind))

-- | @grants revoke <agent> <kind> [--by WHO]@.
--
-- Revoking something that was never granted is reported rather than silently
-- succeeding: an operator who mistyped an agent name should find out here, not
-- when the sink they meant to stop keeps being delivered.
runGrantsRevoke :: String -> String -> Maybe String -> AppConfig -> IO ()
runGrantsRevoke agent kindArg by config = do
  kind <- requireKind "grants revoke" kindArg
  withPool config "grants revoke" \pool ->
    revokeGrant pool (Text.pack agent) kind (Text.pack <$> by) >>= \case
      Left err -> die "grants revoke" err
      Right True ->
        putStrLn ("revoked " <> agent <> " " <> Text.unpack (sinkKindText kind))
      Right False ->
        putStrLn
          ( "no grant row for "
              <> agent
              <> " "
              <> Text.unpack (sinkKindText kind)
              <> " (nothing to revoke)"
          )

-- | One row, tab-free and greppable: state, agent, kind, then the audit trail.
renderRow :: GrantRow -> Text
renderRow GrantRow {agentName, sinkKind, granted, grantedBy, grantedAt, revokedBy, revokedAt} =
  Text.intercalate
    "  "
    [ if granted then "granted" else "revoked",
      agentName,
      sinkKind,
      audit
    ]
  where
    audit
      | granted = "by=" <> orUnknown grantedBy <> " at=" <> stamp grantedAt
      | otherwise =
          "by=" <> orUnknown revokedBy <> " at=" <> maybe "?" stamp revokedAt
    orUnknown = maybe "?" id
    stamp = Text.pack . iso8601Show

-- | @AGENT:KIND@, the same shape @grants list@ prints as its continuation hint.
parseCursor :: String -> Either Text GrantCursor
parseCursor raw =
  case Text.breakOn ":" (Text.pack raw) of
    (_, "") -> Left ("--after must be AGENT:KIND (got '" <> Text.pack raw <> "')")
    (a, rest) ->
      let k = Text.drop 1 rest
       in if Text.null a || Text.null k
            then Left ("--after must be AGENT:KIND (got '" <> Text.pack raw <> "')")
            else Right GrantCursor {agentName = a, sinkKind = k}

-- | Reject an unknown sink kind by naming the five that exist, because the
-- strings are exact and an operator guessing "kawa" deserves the list.
requireKind :: String -> String -> IO SinkKind
requireKind ctx raw =
  case parseSinkKind (Text.pack raw) of
    Just k -> pure k
    Nothing ->
      die
        ctx
        ( "unknown sink kind '"
            <> Text.pack raw
            <> "'; expected one of KawaDigest, KizashiSignal, ReiAction, DanwaConversation, ChannelEgress"
        )

withPool :: AppConfig -> String -> (Pool -> IO a) -> IO a
withPool config ctx use = do
  connStr <- revealSecretText <$> requireDatabaseUrl (Text.pack ctx) config
  withStore (defaultConnectionSettings connStr) (use . pool)

die :: String -> Text -> IO a
die ctx msg = do
  hPutStrLn stderr (ctx <> ": " <> Text.unpack msg)
  exitFailure
