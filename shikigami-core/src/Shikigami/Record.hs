{-# LANGUAGE DataKinds #-}

-- | The kernel's action record: one append-only log of every authority
-- decision and every external effect.
--
-- The record is a port. A producer owns its 'RecordKind' (a checked dotted
-- name such as @authority.decided@) and builds its payload with its own typed
-- constructor beside the code that performs the effect, so a new kind of
-- effect needs no change to a shared sum. The kernel only checks the shape:
-- the kind grammar and a bounded payload.
--
-- Two stores ship here. Durable runs append to @shikigami.action_record@ in
-- PostgreSQL beside the run evidence, so one query answers "what did this run
-- do". The database-free one-off command appends JSON Lines to a file outside
-- every workspace. Both are insert-only through this API.
--
-- A payload never carries tool input, file content or a credential. Callers
-- build payloads from bounded coordinates only.
module Shikigami.Record
  ( -- * Kinds
    RecordKind,
    mkRecordKind,
    recordKindText,

    -- * Tier labels
    TierLabel,
    mkTierLabel,
    tierLabelText,
    unspecifiedTier,

    -- * Entries and events
    RecordEntry,
    mkRecordEntry,
    recordEntry,
    maxRecordPayloadBytes,
    RecordEvent (..),
    RecordError (..),
    recordErrorText,

    -- * The port
    ActionRecord (..),
    observedRecord,
    memoryRecord,

    -- * Stores
    fileRecord,
    postgresRecord,

    -- * Reading
    RecordQuery (..),
    KindFilter (..),
    RecordLimit,
    mkRecordLimit,
    defaultRecordLimit,
    readRecord,
    readRecordFile,

    -- * Rendering
    renderRecordEvent,
  )
where

import Control.Exception (IOException, try)
import Data.Aeson (Value, (.:), (.:?), (.=))
import Data.Aeson qualified as Aeson
import Data.Aeson.KeyMap qualified as KeyMap
import Data.Bifunctor (first)
import Data.ByteString qualified as ByteString
import Data.ByteString.Char8 qualified as ByteString.Char8
import Data.ByteString.Lazy qualified as LazyByteString
import Data.Char (isAsciiLower, isDigit)
import Data.Foldable (traverse_)
import Data.Functor.Contravariant ((>$<))
import Data.IORef (atomicModifyIORef', newIORef, readIORef)
import Data.Int (Int64)
import Data.Text qualified as Text
import Data.Text.Encoding qualified as Text.Encoding
import Data.Time.Format.ISO8601 (iso8601Show)
import Hasql.Decoders qualified as Decoders
import Hasql.Encoders qualified as Encoders
import Hasql.Pool (Pool)
import Hasql.Pool qualified as Pool
import Hasql.Session qualified as Session
import Hasql.Statement (Statement, preparable)
import Keiro.Workflow (WorkflowId (..))
import Numeric.Natural (Natural)
import Shikigami.Agent.Name (AgentName, agentNameText, mkAgentName)
import Shikigami.Log qualified as Log
import Shikigami.Prelude hiding (at, matching, (.=))
import Shikigami.Telemetry.Metrics (ShikigamiMetrics, recordActionRecordEvent)
import System.Directory (createDirectoryIfMissing, doesFileExist)
import System.FilePath (takeDirectory)
import System.IO (IOMode (AppendMode), hClose, hFlush, withBinaryFile)
import System.Posix.Files (setFileMode)

-- | A checked, dotted record kind: @[a-z][a-z0-9-]*(\.[a-z][a-z0-9-]*)+@, at
-- most 64 bytes. The producer of an effect owns its kind.
newtype RecordKind = RecordKind Text
  deriving stock (Eq, Ord, Show)

mkRecordKind :: Text -> Either Text RecordKind
mkRecordKind value
  | Text.length value > 64 = Left "record kind must be at most 64 characters"
  | length segments < 2 = Left ("record kind must be a dotted name: " <> value)
  | all validSegment segments = Right (RecordKind value)
  | otherwise = Left ("record kind must match [a-z][a-z0-9-]*(.[a-z][a-z0-9-]*)+: " <> value)
  where
    segments = Text.splitOn "." value
    validSegment segment = case Text.uncons segment of
      Just (first', rest) -> isAsciiLower first' && Text.all (\c -> isAsciiLower c || isDigit c || c == '-') rest
      Nothing -> False

recordKindText :: RecordKind -> Text
recordKindText (RecordKind value) = value

-- | Which trust tier the run executed under, as recorded. EP-1 supplies the
-- tier type; until then every composition records 'unspecifiedTier'.
newtype TierLabel = TierLabel Text
  deriving stock (Eq, Ord, Show)

mkTierLabel :: Text -> Either Text TierLabel
mkTierLabel value
  | Text.null value || Text.length value > 32 = Left "tier label must be 1 to 32 characters"
  | Text.all (\c -> isAsciiLower c || isDigit c || c == '-') value = Right (TierLabel value)
  | otherwise = Left ("tier label must match [a-z0-9-]+: " <> value)

tierLabelText :: TierLabel -> Text
tierLabelText (TierLabel value) = value

unspecifiedTier :: TierLabel
unspecifiedTier = TierLabel "unspecified"

-- | A kind and its bounded payload. The constructor is private:
-- 'mkRecordEntry' refuses a payload whose canonical JSON exceeds
-- 'maxRecordPayloadBytes'.
data RecordEntry = RecordEntry !RecordKind !Value
  deriving stock (Eq, Show)

maxRecordPayloadBytes :: Natural
maxRecordPayloadBytes = 8192

mkRecordEntry :: RecordKind -> Value -> Either RecordError RecordEntry
mkRecordEntry kind payload
  | size > maxRecordPayloadBytes = Left (RecordEntryTooLarge size)
  | otherwise = Right (RecordEntry kind payload)
  where
    size = fromIntegral (LazyByteString.length (Aeson.encode payload))

recordEntry :: RecordEntry -> (RecordKind, Value)
recordEntry (RecordEntry kind payload) = (kind, payload)

-- | One appended fact. @run@ is absent for decisions made outside a run (for
-- example workspace maintenance); @agent@ is absent when no declaration is in
-- scope.
data RecordEvent = RecordEvent
  { at :: !UTCTime,
    run :: !(Maybe WorkflowId),
    principal :: !Text,
    tier :: !TierLabel,
    agent :: !(Maybe AgentName),
    entry :: !RecordEntry
  }
  deriving stock (Eq, Show)

instance Aeson.ToJSON RecordEvent where
  toJSON RecordEvent {at, run, principal, tier, agent, entry = RecordEntry kind payload} =
    Aeson.object
      [ "at" .= at,
        "run" .= fmap (.unWorkflowId) run,
        "principal" .= principal,
        "tier" .= tierLabelText tier,
        "agent" .= fmap agentNameText agent,
        "kind" .= recordKindText kind,
        "payload" .= payload
      ]

instance Aeson.FromJSON RecordEvent where
  parseJSON = Aeson.withObject "RecordEvent" \value -> do
    at <- value .: "at"
    run <- fmap WorkflowId <$> value .:? "run"
    principal <- value .: "principal"
    tier <- value .: "tier" >>= either (fail . Text.unpack) pure . mkTierLabel
    agent <- value .:? "agent" >>= traverse (either (fail . Text.unpack) pure . mkAgentName)
    kind <- value .: "kind" >>= either (fail . Text.unpack) pure . mkRecordKind
    payload <- value .: "payload"
    pure RecordEvent {at, run, principal, tier, agent, entry = RecordEntry kind payload}

data RecordError
  = RecordStoreUnavailable !Text
  | RecordEntryTooLarge !Natural
  deriving stock (Eq, Show)

recordErrorText :: RecordError -> Text
recordErrorText = \case
  RecordStoreUnavailable detail -> "action record unavailable: " <> Text.take 256 detail
  RecordEntryTooLarge size -> "action record entry is " <> Text.pack (show size) <> " bytes, above the " <> Text.pack (show maxRecordPayloadBytes) <> " byte bound"

-- | The port. An adapter appends one event durably or reports why it could
-- not; a caller that cannot record must not proceed with the effect.
newtype ActionRecord = ActionRecord
  { append :: RecordEvent -> IO (Either RecordError ())
  }

-- | Log and count each append: @record.appended@ at debug level, or
-- @record.append_failed@ at error level, and the counter
-- @shikigami.record.events{record.kind, decision}@ when metrics are
-- composed. The record itself remains the source of truth.
observedRecord :: Log.Logger -> Maybe ShikigamiMetrics -> ActionRecord -> ActionRecord
observedRecord logger metrics ActionRecord {append = inner} =
  ActionRecord
    { append = \event@RecordEvent {run, entry = RecordEntry kind payload} -> do
        result <- inner event
        case result of
          Right () -> do
            Log.logDebug logger "record.appended" ["kind" .= recordKindText kind, Log.runIdKey .= fmap (.unWorkflowId) run]
            traverse_ (\m -> recordActionRecordEvent m (recordKindText kind) (decisionLabel payload)) metrics
          Left failure -> do
            Log.logError logger "record.append_failed" ["kind" .= recordKindText kind, Log.runIdKey .= fmap (.unWorkflowId) run, "reason" .= recordErrorText failure]
            traverse_ (\m -> recordActionRecordEvent m (recordKindText kind) "append_failed") metrics
        pure result
    }
  where
    decisionLabel value = case Aeson.fromJSON value of
      Aeson.Success (DecisionField decision) | decision `elem` ["allowed", "denied", "unavailable", "proof_rejected", "invalid"] -> decision
      _ -> "none"

-- | An in-memory record for tests and for compositions that read back their
-- own events. The second value returns the events in append order.
memoryRecord :: IO (ActionRecord, IO [RecordEvent])
memoryRecord = do
  ref <- newIORef []
  pure
    ( ActionRecord {append = \event -> atomicModifyIORef' ref (\events -> (event : events, Right ()))},
      reverse <$> readIORef ref
    )

-- | Append JSON Lines to a file the agent cannot reach. The file and its
-- directory are created on first use; the file is mode 0600.
fileRecord :: FilePath -> IO (Either RecordError ActionRecord)
fileRecord path = do
  prepared <- try do
    createDirectoryIfMissing True (takeDirectory path)
    exists <- doesFileExist path
    unless exists (ByteString.writeFile path ByteString.empty)
    setFileMode path 0o600
  pure case prepared of
    Left (problem :: IOException) -> Left (RecordStoreUnavailable (Text.pack (show problem)))
    Right () -> Right ActionRecord {append = appendLine}
  where
    appendLine event = do
      written <- try do
        withBinaryFile path AppendMode \handle -> do
          ByteString.hPut handle (LazyByteString.toStrict (Aeson.encode event) <> "\n")
          hFlush handle
          hClose handle
      pure (first (\(problem :: IOException) -> RecordStoreUnavailable (Text.pack (show problem))) written)

-- | Append to @shikigami.action_record@ over a pool whose statements are
-- schema-qualified (the event-store pool's search path is @kiroku@).
postgresRecord :: Pool -> ActionRecord
postgresRecord pool =
  ActionRecord
    { append = \RecordEvent {at, run, principal, tier, agent, entry = RecordEntry kind payload} ->
        first (RecordStoreUnavailable . Text.pack . show)
          <$> Pool.use
            pool
            ( Session.statement
                (at, fmap (.unWorkflowId) run, principal, tierLabelText tier, fmap agentNameText agent, recordKindText kind, payload)
                insertStatement
            )
    }

insertStatement :: Statement (UTCTime, Maybe Text, Text, Text, Maybe Text, Text, Value) ()
insertStatement =
  preparable
    """
    INSERT INTO shikigami.action_record (at, run_id, principal, tier, agent, kind, payload)
    VALUES ($1, $2, $3, $4, $5, $6, $7)
    """
    ( ((\(a, _, _, _, _, _, _) -> a) >$< Encoders.param (Encoders.nonNullable Encoders.timestamptz))
        <> ((\(_, b, _, _, _, _, _) -> b) >$< Encoders.param (Encoders.nullable Encoders.text))
        <> ((\(_, _, c, _, _, _, _) -> c) >$< Encoders.param (Encoders.nonNullable Encoders.text))
        <> ((\(_, _, _, d, _, _, _) -> d) >$< Encoders.param (Encoders.nonNullable Encoders.text))
        <> ((\(_, _, _, _, e, _, _) -> e) >$< Encoders.param (Encoders.nullable Encoders.text))
        <> ((\(_, _, _, _, _, f, _) -> f) >$< Encoders.param (Encoders.nonNullable Encoders.text))
        <> ((\(_, _, _, _, _, _, g) -> g) >$< Encoders.param (Encoders.nonNullable Encoders.jsonb))
    )
    Decoders.noResult

-- | Which events to read. Results are always the most recent @limit@ matching
-- events, returned oldest first.
data RecordQuery = RecordQuery
  { run :: !(Maybe WorkflowId),
    kinds :: !KindFilter,
    limit :: !RecordLimit
  }

data KindFilter
  = AllKinds
  | KindPrefix !Text
  | -- | Only @authority.decided@ entries whose decision is not @allowed@.
    RefusalsOnly
  deriving stock (Eq, Show)

newtype RecordLimit = RecordLimit Int64
  deriving stock (Eq, Ord, Show)

mkRecordLimit :: Int -> Either Text RecordLimit
mkRecordLimit n
  | n < 1 = Left "limit must be at least 1"
  | n > 1000 = Left "limit must be at most 1000"
  | otherwise = Right (RecordLimit (fromIntegral n))

defaultRecordLimit :: RecordLimit
defaultRecordLimit = RecordLimit 50

readRecord :: Pool -> RecordQuery -> IO (Either RecordError [RecordEvent])
readRecord pool RecordQuery {run, kinds, limit = RecordLimit limitValue} = do
  let (prefix, refusals) = case kinds of
        AllKinds -> (Nothing, False)
        KindPrefix value -> (Just value, False)
        RefusalsOnly -> (Just "authority.decided", True)
  result <- Pool.use pool (Session.statement (fmap (.unWorkflowId) run, prefix, refusals, limitValue) readStatement)
  pure case result of
    Left problem -> Left (RecordStoreUnavailable (Text.pack (show problem)))
    Right rows -> traverse decodeRow rows
  where
    decodeRow (at, runId, principal, tierText, agentText, kindText, payload) =
      first RecordStoreUnavailable do
        tier <- mkTierLabel tierText
        agent <- traverse mkAgentName agentText
        kind <- mkRecordKind kindText
        pure RecordEvent {at, run = WorkflowId <$> runId, principal, tier, agent, entry = RecordEntry kind payload}

readStatement :: Statement (Maybe Text, Maybe Text, Bool, Int64) [(UTCTime, Maybe Text, Text, Text, Maybe Text, Text, Value)]
readStatement =
  preparable
    """
    SELECT at, run_id, principal, tier, agent, kind, payload
      FROM ( SELECT seq, at, run_id, principal, tier, agent, kind, payload
               FROM shikigami.action_record
              WHERE ($1::text IS NULL OR run_id = $1)
                AND ($2::text IS NULL OR starts_with(kind, $2))
                AND (NOT $3 OR payload->>'decision' IS DISTINCT FROM 'allowed')
              ORDER BY seq DESC
              LIMIT $4 ) AS recent
     ORDER BY seq ASC
    """
    ( ((\(a, _, _, _) -> a) >$< Encoders.param (Encoders.nullable Encoders.text))
        <> ((\(_, b, _, _) -> b) >$< Encoders.param (Encoders.nullable Encoders.text))
        <> ((\(_, _, c, _) -> c) >$< Encoders.param (Encoders.nonNullable Encoders.bool))
        <> ((\(_, _, _, d) -> d) >$< Encoders.param (Encoders.nonNullable Encoders.int8))
    )
    ( Decoders.rowList
        ( (,,,,,,)
            <$> Decoders.column (Decoders.nonNullable Decoders.timestamptz)
            <*> Decoders.column (Decoders.nullable Decoders.text)
            <*> Decoders.column (Decoders.nonNullable Decoders.text)
            <*> Decoders.column (Decoders.nonNullable Decoders.text)
            <*> Decoders.column (Decoders.nullable Decoders.text)
            <*> Decoders.column (Decoders.nonNullable Decoders.text)
            <*> Decoders.column (Decoders.nonNullable Decoders.jsonb)
        )
    )

-- | Read a JSON Lines record written by 'fileRecord', applying the same
-- query. A malformed line is reported, never skipped silently.
readRecordFile :: FilePath -> RecordQuery -> IO (Either RecordError [RecordEvent])
readRecordFile path RecordQuery {run, kinds, limit = RecordLimit limitValue} = do
  contents <- try (ByteString.readFile path)
  pure case contents of
    Left (problem :: IOException) -> Left (RecordStoreUnavailable (Text.pack (show problem)))
    Right bytes -> do
      events <- traverse decodeLine (filter (not . ByteString.null) (ByteString.Char8.lines bytes))
      let matching = filter matches events
      pure (reverse (take (fromIntegral limitValue) (reverse matching)))
  where
    decodeLine line =
      first (RecordStoreUnavailable . ("malformed record line: " <>) . Text.pack) (Aeson.eitherDecodeStrict line)
    matches RecordEvent {run = eventRun, entry = RecordEntry kind payload} =
      maybe True (== eventRun) (Just <$> run)
        && case kinds of
          AllKinds -> True
          KindPrefix prefix -> prefix `Text.isPrefixOf` recordKindText kind
          RefusalsOnly -> recordKindText kind == "authority.decided" && decisionOf payload /= Just "allowed"
    decisionOf = \case
      Aeson.Object object -> case Aeson.fromJSON (Aeson.Object object) of
        Aeson.Success (DecisionField decision) -> Just decision
        Aeson.Error _ -> Nothing
      _ -> Nothing

newtype DecisionField = DecisionField Text

instance Aeson.FromJSON DecisionField where
  parseJSON = Aeson.withObject "DecisionField" \value -> DecisionField <$> value .: "decision"

-- | One event on one line: time, run, agent, principal, kind, then the
-- action, resource, decision and who decided when the payload carries them.
renderRecordEvent :: RecordEvent -> Text
renderRecordEvent RecordEvent {at, run, principal, tier, agent, entry} =
  let (kind, payload) = recordEntry entry
      field name = case payload of
        Aeson.Object object -> case KeyMap.lookup name object of
          Just (Aeson.String value) -> Just value
          _ -> Nothing
        _ -> Nothing
      number name = case payload of
        Aeson.Object object | Just (Aeson.Number value) <- KeyMap.lookup name object -> Just (Text.pack (show (round value :: Integer)))
        _ -> Nothing
      arguments = case payload of
        Aeson.Object object | Just value <- KeyMap.lookup "arguments" object -> Text.Encoding.decodeUtf8Lenient (LazyByteString.toStrict (Aeson.encode value))
        _ -> "[]"
      -- A declared tool call (EP-3): admitted with its exit, or refused with why.
      decided = case (recordKindText kind, field "decision", field "detail") of
        ("tool.called", Just decision, _) ->
          [decision, maybe "?" id (field "tool")]
            <> maybe ["run", arguments] (\remote -> [remote | remote /= "-"]) (field "remote")
            <> maybe [] (\code -> ["exit " <> code]) (number "exitCode")
            <> maybe [] pure (field "reason")
        (_, Just "allowed", _) -> ["allowed"]
        (_, Just _, Just detail) -> ["refused " <> detail]
        (_, Just decision, Nothing) -> ["refused " <> decision]
        _ -> []
      source = maybe [] (\by -> ["(source: " <> by <> ")"]) (field "decidedBy")
   in Text.unwords
        ( [ Text.pack (iso8601Show at),
            maybe "-" (.unWorkflowId) run,
            maybe "-" agentNameText agent,
            principal,
            tierLabelText tier,
            recordKindText kind
          ]
            <> maybe [] pure (field "action")
            <> maybe [] pure (field "resource")
            <> decided
            <> source
            <> [Text.take 200 (Text.Encoding.decodeUtf8Lenient (LazyByteString.toStrict (Aeson.encode payload))) | null decided]
        )
