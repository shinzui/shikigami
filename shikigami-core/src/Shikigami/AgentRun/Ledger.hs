-- | The HTTP boundary owns acceptance before a worker creates a workflow.
module Shikigami.AgentRun.Ledger
  ( RunRequestRow (..),
    AcceptOutcome (..),
    RunDisposition (..),
    renderRunDisposition,
    httpRunKey,
    PayloadFingerprint,
    parsePayloadFingerprint,
    payloadFingerprintText,
    payloadFingerprint,
    CallerAttribution,
    callerAttribution,
    callerAttributionText,
    acceptRunRequest,
    lookupRunRequest,
    lookupRunRequestTx,
    lookupRunRequestById,
    recordDeadLetter,
    refreshRunDisposition,
    listRunRequests,
    listRunRequestsTx,
    RunListError (..),
  )
where

import Data.Aeson (Value, encode, object, withObject, withText, (.:), (.=))
import Data.Aeson.Types (parseEither)
import Data.Bifunctor (first)
import Data.Bits ((.&.))
import Data.ByteString qualified as BS
import Data.ByteString.Lazy qualified as LBS
import Data.Foldable (toList)
import Data.Functor.Contravariant ((>$<))
import Data.Generics.Labels ()
import Data.Text qualified as Text
import Data.UUID qualified as UUID
import Data.UUID.V5 qualified as UUID
import Hasql.Decoders qualified as D
import Hasql.DynamicStatements.Snippet qualified as Snippet
import Hasql.Encoders qualified as E
import Hasql.Pool (Pool)
import Hasql.Pool qualified as Pool
import Hasql.Session qualified as Session
import Hasql.Statement (Statement, preparable)
import Hasql.Transaction qualified as Tx
import Hasql.Transaction.Sessions qualified as Tx
import Keiro.PGMQ qualified as Job
import Keiro.Workflow.Types (WorkflowId (..))
import Pgmq (Message (..), MessageBody (..), MessageId (..), ReadMessage (..))
import Pgmq.Hasql.Statements.Message qualified as PgmqStatements
import Relay.Pagination (Connection, CursorError, PageRequest)
import Relay.Pagination.Hasql qualified as Relay
import Shikigami.Agent.Name (AgentName, agentNameText, mkAgentName)
import Shikigami.Agent.Run.Key (RunKey, parseRunKey, runKeyText, runKeyWithPrefix)
import Shikigami.Agent.RunJob (RunJob (..), runJobWorkflowId)
import Shikigami.AgentRun.RequestKey
import Shikigami.Behavior.Error (boundedBehaviorDetail)
import Shikigami.Decision.Contract (versionedDigest)
import Shikigami.Prelude hiding ((.=))
import Shikigami.RunJobs qualified as RunJobs
import Shikigami.Trigger.Enqueue (enqueueRunJobTx)

httpRunKey :: AgentName -> RequestKey -> RunKey
httpRunKey agent key = runKeyWithPrefix ('h' :| "ttp-run-v2:") (versionedDigest "shikigami.http-run/2" (object ["agent" .= agent, "key" .= key]))

-- | The original UUIDv5 payload commitment, not an allocated entity identity.
newtype PayloadFingerprint = PayloadFingerprint UUID.UUID
  deriving stock (Eq, Ord, Show)

parsePayloadFingerprint :: Text -> Either Text PayloadFingerprint
parsePayloadFingerprint raw = case UUID.fromText raw of
  Just value
    | let (_, version, variant, _) = UUID.toWords value,
      raw == UUID.toText value,
      version .&. 0xf000 == 0x5000,
      variant .&. 0xc0000000 == 0x80000000 ->
        Right (PayloadFingerprint value)
  _ -> Left "request payload fingerprint requires a canonical RFC 4122 UUIDv5"

payloadFingerprintText :: PayloadFingerprint -> Text
payloadFingerprintText (PayloadFingerprint value) = UUID.toText value

instance ToJSON PayloadFingerprint where
  toJSON = toJSON . payloadFingerprintText
  toEncoding = toEncoding . payloadFingerprintText

instance FromJSON PayloadFingerprint where
  parseJSON = withText "request payload fingerprint" (either (fail . Text.unpack) pure . parsePayloadFingerprint)

-- Aeson's ordered object encoding makes object member order immaterial.
payloadFingerprint :: Value -> PayloadFingerprint
payloadFingerprint = PayloadFingerprint . UUID.generateNamed UUID.namespaceURL . BS.unpack . LBS.toStrict . encode

-- | Exact attribution supplied by the authenticated HTTP adapter. The caller's
-- authority owns its vocabulary; retaining a claim grants no authentication.
newtype CallerAttribution = CallerAttribution Text
  deriving stock (Eq, Ord, Show)

callerAttribution :: Text -> CallerAttribution
callerAttribution = CallerAttribution

callerAttributionText :: CallerAttribution -> Text
callerAttributionText (CallerAttribution value) = value

data RunRequestRow = RunRequestRow
  { agentName :: !AgentName,
    idempotencyKey :: !RequestKey,
    runId :: !WorkflowId,
    runKey :: !RunKey,
    payloadFingerprint :: !PayloadFingerprint,
    requestedBy :: !CallerAttribution,
    queueMessageId :: !MessageId,
    acceptedAt :: !UTCTime,
    disposition :: !RunDisposition,
    dispositionDetail :: !(Maybe Text),
    dispositionAt :: !(Maybe UTCTime)
  }
  deriving stock (Generic, Eq, Show)

-- | The service-owned queue disposition; workflow lifecycle remains separately
-- derived from durable workflow facts. Stored spellings are unchanged.
data RunDisposition = RunAccepted | RunDeadLettered
  deriving stock (Eq, Show)

renderRunDisposition :: RunDisposition -> Text
renderRunDisposition = \case
  RunAccepted -> "accepted"
  RunDeadLettered -> "dead_lettered"

parseRunDisposition :: Text -> Either Text RunDisposition
parseRunDisposition = \case
  "accepted" -> Right RunAccepted
  "dead_lettered" -> Right RunDeadLettered
  _ -> Left "unknown run disposition"

data AcceptOutcome = Accepted !RunRequestRow | Replayed !RunRequestRow | Conflicting !RunRequestRow
  deriving stock (Eq, Show)

acceptRunRequest :: Pool -> RunJob -> RequestKey -> CallerAttribution -> IO (Either Text AcceptOutcome)
acceptRunRequest pool job key caller
  | job.idempotencyKey /= httpRunKey job.agentName key = pure (Left "HTTP run key does not match its acceptance coordinates.")
  | otherwise = do
      result <- Pool.use pool (Tx.transaction Tx.ReadCommitted Tx.Write accept)
      case result of
        Left _ -> pure (Left "The run acceptance store is unavailable.")
        Right (Just row) -> pure (Right (Accepted row))
        Right Nothing -> do
          existing <- runRead pool (Tx.statement (agent, key) lookupKeyStatement >>= checkedRead . sequence)
          pure $ case existing of
            Right (Just row)
              | row.payloadFingerprint == fingerprint -> Right (Replayed row)
              | otherwise -> Right (Conflicting row)
            Right Nothing -> Left "The accepted request could not be read."
            Left err -> Left err
  where
    agent = job.agentName
    fingerprint = payloadFingerprint job.triggerPayload
    accept = do
      message <- enqueueRunJobTx job
      let row = RunRequestRow agent key (runJobWorkflowId job) job.idempotencyKey fingerprint caller message job.occurredAt RunAccepted Nothing Nothing
      inserted <- Tx.statement row insertStatement
      case inserted of
        Just acceptedAt -> pure (Just (row & #acceptedAt .~ acceptedAt))
        Nothing -> Tx.condemn >> pure Nothing

lookupRunRequest :: Pool -> AgentName -> WorkflowId -> IO (Either Text (Maybe RunRequestRow))
lookupRunRequest pool agent runId = runRead pool (lookupRunRequestTx agent runId)

lookupRunRequestTx :: AgentName -> WorkflowId -> Tx.Transaction (Either Text (Maybe RunRequestRow))
lookupRunRequestTx agent runId = Tx.statement (agent, runId) lookupIdStatement >>= checkedRead . sequence

-- | The operator knows the workflow UUID before a journal can name its agent.
-- Refuse ambiguous ids rather than selecting an arbitrary agent's request.
lookupRunRequestById :: Pool -> WorkflowId -> IO (Either Text (Maybe RunRequestRow))
lookupRunRequestById pool runId = do
  rows <- runRead pool (Tx.statement runId statement >>= checkedRead . sequence)
  pure $ case rows of
    Left err -> Left err
    Right [] -> Right Nothing
    Right [row] -> Right (Just row)
    Right _ -> Left "The run identifier is ambiguous."
  where
    statement = preparable ("SELECT " <> columns <> " FROM shikigami.agent_run_requests WHERE run_id=$1 LIMIT 2") ((.unWorkflowId) >$< E.param (E.nonNullable E.text)) (D.rowList rowDecoder)

safeUse :: Pool -> Session.Session a -> IO (Either Text a)
safeUse pool action = first (const "The run acceptance store is unavailable.") <$> Pool.use pool action

columns :: Text
columns = "agent_name, idempotency_key, run_id, run_key, payload_fingerprint, requested_by, queue_message_id, accepted_at, disposition, disposition_detail, disposition_at"

rowDecoder :: D.Row (Either Text RunRequestRow)
rowDecoder =
  assemble
    <$> text
    <*> text
    <*> text
    <*> text
    <*> text
    <*> text
    <*> D.column (D.nonNullable D.int8)
    <*> D.column (D.nonNullable D.timestamptz)
    <*> text
    <*> D.column (D.nullable D.text)
    <*> D.column (D.nullable D.timestamptz)
  where
    text = D.column (D.nonNullable D.text)
    assemble agent key run runKey fingerprint caller message accepted disposition detail observed =
      RunRequestRow <$> mkAgentName agent <*> parseRequestKey key <*> pure (WorkflowId run) <*> parseRunKey runKey <*> parsePayloadFingerprint fingerprint <*> pure (callerAttribution caller) <*> pure (MessageId message) <*> pure accepted <*> parseRunDisposition disposition <*> pure detail <*> pure observed

checkedRead :: Either Text a -> Tx.Transaction (Either Text a)
checkedRead = \case
  Left _ -> Tx.condemn >> pure (Left "The retained run acceptance is corrupt.")
  Right value -> pure (Right value)

runRead :: Pool -> Tx.Transaction (Either Text a) -> IO (Either Text a)
runRead pool action = do
  result <- safeUse pool (Tx.transaction Tx.ReadCommitted Tx.Write action)
  pure (result >>= id)

lookupKeyStatement :: Statement (AgentName, RequestKey) (Maybe (Either Text RunRequestRow))
lookupKeyStatement = preparable ("SELECT " <> columns <> " FROM shikigami.agent_run_requests WHERE agent_name=$1 AND idempotency_key=$2") (((agentNameText . fst) >$< E.param (E.nonNullable E.text)) <> ((requestKeyText . snd) >$< E.param (E.nonNullable E.text))) (D.rowMaybe rowDecoder)

lookupIdStatement :: Statement (AgentName, WorkflowId) (Maybe (Either Text RunRequestRow))
lookupIdStatement = preparable ("SELECT " <> columns <> " FROM shikigami.agent_run_requests WHERE agent_name=$1 AND run_id=$2") (((agentNameText . fst) >$< E.param (E.nonNullable E.text)) <> (((.unWorkflowId) . snd) >$< E.param (E.nonNullable E.text))) (D.rowMaybe rowDecoder)

insertStatement :: Statement RunRequestRow (Maybe UTCTime)
insertStatement =
  preparable
    "INSERT INTO shikigami.agent_run_requests (agent_name,idempotency_key,run_id,run_key,payload_fingerprint,requested_by,queue_message_id) VALUES ($1,$2,$3,$4,$5,$6,$7) ON CONFLICT (agent_name,idempotency_key) DO NOTHING RETURNING accepted_at"
    ( ((agentNameText . (.agentName)) >$< E.param (E.nonNullable E.text))
        <> ((requestKeyText . (.idempotencyKey)) >$< E.param (E.nonNullable E.text))
        <> (((.unWorkflowId) . (.runId)) >$< E.param (E.nonNullable E.text))
        <> ((runKeyText . (.runKey)) >$< E.param (E.nonNullable E.text))
        <> ((payloadFingerprintText . (.payloadFingerprint)) >$< E.param (E.nonNullable E.text))
        <> ((callerAttributionText . (.requestedBy)) >$< E.param (E.nonNullable E.text))
        <> (((.unMessageId) . (.queueMessageId)) >$< E.param (E.nonNullable E.int8))
    )
    (D.rowMaybe (D.column (D.nonNullable D.timestamptz)))

runKeyEncoder :: E.Params (RunKey, Text)
runKeyEncoder = ((runKeyText . fst) >$< E.param (E.nonNullable E.text)) <> (snd >$< E.param (E.nonNullable E.text))

-- | Idempotent best-effort receipt for a decoded job's terminal queue outcome.
recordDeadLetter :: Pool -> RunKey -> Text -> IO (Either Text Bool)
recordDeadLetter pool key detail =
  safeUse pool $
    Session.statement (key, boundedBehaviorDetail detail) $
      preparable
        "UPDATE shikigami.agent_run_requests SET disposition='dead_lettered', disposition_detail=$2, disposition_at=COALESCE(disposition_at,now()) WHERE run_key=$1 RETURNING true"
        runKeyEncoder
        (fmap (fromMaybe False) (D.rowMaybe (D.column (D.nonNullable D.bool))))

-- | Reconcile a pre-workflow request from the released PGMQ read API. The
-- documented Keiro DLQ envelope carries the original queue id and reason.
-- Filter by that id, never lease unrelated entries. A zero-second
-- visibility timeout keeps the entry available to operators; PGMQ still bumps
-- its DLQ read count. The read and receipt commit together, and failure rolls
-- both back. A leased/absent row supplies no negative evidence.
--
-- Retain DLQ evidence until this receipt is recorded. Later archive/redrive/purge
-- cannot erase the ledger's fact. No workflow journal or private table is read.
refreshRunDisposition :: Pool -> RunRequestRow -> IO (Either Text RunRequestRow)
refreshRunDisposition pool request = runRead pool do
  retained <- lookupRunRequestTx request.agentName request.runId
  case retained of
    Left err -> pure (Left err)
    Right Nothing -> Tx.condemn >> pure (Left "The run disposition is unavailable.")
    Right (Just current)
      | current.disposition /= RunAccepted -> pure (Right current)
      | otherwise -> reconcile current
  where
    reconcile current = do
      entries <-
        Tx.statement
          ReadMessage
            { queueName = RunJobs.runJob.jobQueue.dlqName,
              delay = 0,
              batchSize = Just 1,
              conditional = Just (object ["original_message_id" .= current.queueMessageId])
            }
          PgmqStatements.readMessage
      case toList entries of
        [] -> pure (Right current)
        entry : _ -> case parseEither (withObject "Keiro DLQ envelope" (.: "dead_letter_reason")) (unMessageBody entry.body) of
          Left _ -> Tx.condemn >> pure (Left "The run disposition is unavailable.")
          Right reason -> do
            updated <- Tx.statement (current.runKey, boundedBehaviorDetail reason) receiptStatement >>= checkedRead . sequence
            case updated of
              Left err -> pure (Left err)
              Right Nothing -> Tx.condemn >> pure (Left "The run disposition is unavailable.")
              Right (Just row) -> pure (Right row)

    receiptStatement =
      preparable
        ("UPDATE shikigami.agent_run_requests SET disposition='dead_lettered', disposition_detail=COALESCE(disposition_detail,$2), disposition_at=COALESCE(disposition_at,now()) WHERE run_key=$1 RETURNING " <> columns)
        runKeyEncoder
        (D.rowMaybe rowDecoder)

data RunListError = InvalidRunCursor !CursorError | RunListUnavailable !Text
  deriving stock (Eq, Show)

listRunRequests :: Pool -> AgentName -> PageRequest -> IO (Either RunListError (Connection RunRequestRow))
listRunRequests pool agent request = do
  result <- safeUse pool (Tx.transaction Tx.ReadCommitted Tx.Write (listRunRequestsTx agent request))
  pure (first RunListUnavailable result >>= id)

listRunRequestsTx :: AgentName -> PageRequest -> Tx.Transaction (Either RunListError (Connection RunRequestRow))
listRunRequestsTx agent request = case Relay.paginateSnippet runSort request base of
  Left err -> pure (Left (InvalidRunCursor err))
  Right snippet -> do
    -- Validate every fetched row, including the extra pagination probe, before
    -- constructing cursors or trimming the page. Corruption is never omission.
    decoded <- Tx.statement () (Snippet.toStatement snippet (D.rowList rowDecoder)) >>= checkedRead . sequence
    pure (first RunListUnavailable (Relay.mkConnection runSort request <$> decoded))
  where
    base =
      Snippet.sql ("SELECT " <> columns <> " FROM shikigami.agent_run_requests WHERE agent_name = ")
        <> Snippet.encoderAndParam (E.nonNullable E.text) (agentNameText agent)
    runSort =
      Relay.SortSpec
        ( Relay.KeyColumn "accepted_at" Relay.Desc (.acceptedAt) Relay.timestamptzKey
            :| [Relay.KeyColumn "run_id" Relay.Asc ((.unWorkflowId) . (.runId)) Relay.textKey]
        )
