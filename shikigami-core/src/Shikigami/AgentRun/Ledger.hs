-- | The HTTP boundary owns acceptance before a worker creates a workflow.
module Shikigami.AgentRun.Ledger
  ( RunRequestRow (..),
    AcceptOutcome (..),
    httpRunKey,
    payloadFingerprint,
    acceptRunRequest,
    lookupRunRequest,
    lookupRunRequestById,
    recordDeadLetter,
    refreshRunDisposition,
    listRunRequests,
    RunListError (..),
  )
where

import Data.Aeson (Value, encode, object, withObject, (.:), (.=))
import Data.Aeson qualified as Aeson
import Data.Aeson.Types (parseEither)
import Data.Bifunctor (first)
import Data.ByteString qualified as BS
import Data.ByteString.Lazy qualified as LBS
import Data.Foldable (toList)
import Data.Functor.Contravariant ((>$<))
import Data.Generics.Labels ()
import Data.Int (Int64)
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
import Shikigami.Agent.Run.Key (RunKey (..), runKeyText)
import Shikigami.Agent.RunJob (RunJob (..), runJobWorkflowId)
import Shikigami.AgentRun.RequestKey
import Shikigami.Behavior.Error (boundedBehaviorDetail)
import Shikigami.Decision.Contract (versionedDigest)
import Shikigami.Prelude hiding ((.=))
import Shikigami.RunJobs qualified as RunJobs
import Shikigami.Trigger.Enqueue (enqueueRunJobTx)

httpRunKey :: AgentName -> RequestKey -> RunKey
httpRunKey agent key = RunKey ("http-run-v2:" <> versionedDigest "shikigami.http-run/2" (object ["agent" .= agent, "key" .= key]))

-- Aeson's ordered object encoding makes object member order immaterial.
payloadFingerprint :: Value -> Text
payloadFingerprint = UUID.toText . UUID.generateNamed UUID.namespaceURL . BS.unpack . LBS.toStrict . encode

data RunRequestRow = RunRequestRow
  { agentName :: !AgentName,
    idempotencyKey :: !RequestKey,
    runId :: !Text,
    runKey :: !Text,
    payloadFingerprint :: !Text,
    requestedBy :: !Text,
    queueMessageId :: !Int64,
    acceptedAt :: !UTCTime,
    disposition :: !Text,
    dispositionDetail :: !(Maybe Text),
    dispositionAt :: !(Maybe UTCTime)
  }
  deriving stock (Generic, Eq, Show)

data AcceptOutcome = Accepted !RunRequestRow | Replayed !RunRequestRow | Conflicting !RunRequestRow
  deriving stock (Eq, Show)

acceptRunRequest :: Pool -> RunJob -> RequestKey -> Text -> IO (Either Text AcceptOutcome)
acceptRunRequest pool job key caller
  | job.idempotencyKey /= httpRunKey job.agentName key = pure (Left "HTTP run key does not match its acceptance coordinates.")
  | otherwise = do
      result <- Pool.use pool (Tx.transaction Tx.ReadCommitted Tx.Write accept)
      case result of
        Left _ -> pure (Left "The run acceptance store is unavailable.")
        Right (Just row) -> pure (Right (Accepted row))
        Right Nothing -> do
          existing <- safeUse pool (Session.statement (agent, key) lookupKeyStatement)
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
      MessageId message <- enqueueRunJobTx job
      let row = RunRequestRow agent key (runJobWorkflowId job).unWorkflowId (runKeyText job.idempotencyKey) fingerprint caller message job.occurredAt "accepted" Nothing Nothing
      inserted <- Tx.statement row insertStatement
      case inserted of
        Just acceptedAt -> pure (Just (row & #acceptedAt .~ acceptedAt))
        Nothing -> Tx.condemn >> pure Nothing

lookupRunRequest :: Pool -> AgentName -> Text -> IO (Either Text (Maybe RunRequestRow))
lookupRunRequest pool agent runId = safeUse pool (Session.statement (agent, runId) lookupIdStatement)

-- | The operator knows the workflow UUID before a journal can name its agent.
-- Refuse ambiguous ids rather than selecting an arbitrary agent's request.
lookupRunRequestById :: Pool -> Text -> IO (Either Text (Maybe RunRequestRow))
lookupRunRequestById pool runId = do
  rows <- safeUse pool (Session.statement runId statement)
  pure $ case rows of
    Left err -> Left err
    Right [] -> Right Nothing
    Right [row] -> Right (Just row)
    Right _ -> Left "The run identifier is ambiguous."
  where
    statement = preparable ("SELECT " <> columns <> " FROM shikigami.agent_run_requests WHERE run_id=$1 LIMIT 2") (E.param (E.nonNullable E.text)) (D.rowList rowDecoder)

safeUse :: Pool -> Session.Session a -> IO (Either Text a)
safeUse pool action = first (const "The run acceptance store is unavailable.") <$> Pool.use pool action

columns :: Text
columns = "agent_name, idempotency_key, run_id, run_key, payload_fingerprint, requested_by, queue_message_id, accepted_at, disposition, disposition_detail, disposition_at"

rowDecoder :: D.Row RunRequestRow
rowDecoder =
  RunRequestRow
    <$> D.column (D.nonNullable (D.refine mkAgentName D.text))
    <*> D.column (D.nonNullable (D.refine parseRequestKey D.text))
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

keyEncoder :: E.Params (Text, Text)
keyEncoder = (fst >$< E.param (E.nonNullable E.text)) <> (snd >$< E.param (E.nonNullable E.text))

lookupKeyStatement :: Statement (AgentName, RequestKey) (Maybe RunRequestRow)
lookupKeyStatement = preparable ("SELECT " <> columns <> " FROM shikigami.agent_run_requests WHERE agent_name=$1 AND idempotency_key=$2") (((agentNameText . fst) >$< E.param (E.nonNullable E.text)) <> ((requestKeyText . snd) >$< E.param (E.nonNullable E.text))) (D.rowMaybe rowDecoder)

lookupIdStatement :: Statement (AgentName, Text) (Maybe RunRequestRow)
lookupIdStatement = preparable ("SELECT " <> columns <> " FROM shikigami.agent_run_requests WHERE agent_name=$1 AND run_id=$2") (((agentNameText . fst) >$< E.param (E.nonNullable E.text)) <> (snd >$< E.param (E.nonNullable E.text))) (D.rowMaybe rowDecoder)

insertStatement :: Statement RunRequestRow (Maybe UTCTime)
insertStatement =
  preparable
    "INSERT INTO shikigami.agent_run_requests (agent_name,idempotency_key,run_id,run_key,payload_fingerprint,requested_by,queue_message_id) VALUES ($1,$2,$3,$4,$5,$6,$7) ON CONFLICT (agent_name,idempotency_key) DO NOTHING RETURNING accepted_at"
    ( ((agentNameText . (.agentName)) >$< E.param (E.nonNullable E.text))
        <> ((requestKeyText . (.idempotencyKey)) >$< E.param (E.nonNullable E.text))
        <> ((.runId) >$< E.param (E.nonNullable E.text))
        <> ((.runKey) >$< E.param (E.nonNullable E.text))
        <> ((.payloadFingerprint) >$< E.param (E.nonNullable E.text))
        <> ((.requestedBy) >$< E.param (E.nonNullable E.text))
        <> ((.queueMessageId) >$< E.param (E.nonNullable E.int8))
    )
    (D.rowMaybe (D.column (D.nonNullable D.timestamptz)))

-- | Idempotent best-effort receipt for a decoded job's terminal queue outcome.
recordDeadLetter :: Pool -> RunKey -> Text -> IO (Either Text Bool)
recordDeadLetter pool key detail =
  safeUse pool $
    Session.statement (runKeyText key, boundedBehaviorDetail detail) $
      preparable
        "UPDATE shikigami.agent_run_requests SET disposition='dead_lettered', disposition_detail=$2, disposition_at=COALESCE(disposition_at,now()) WHERE run_key=$1 RETURNING true"
        keyEncoder
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
refreshRunDisposition pool request
  | request.disposition /= "accepted" = pure (Right request)
  | otherwise = do
      result <- safeUse pool (Tx.transaction Tx.ReadCommitted Tx.Write reconcile)
      pure (either Left id result)
  where
    reconcile = do
      entries <-
        Tx.statement
          ReadMessage
            { queueName = RunJobs.runJob.jobQueue.dlqName,
              delay = 0,
              batchSize = Just 1,
              conditional = Just (object ["original_message_id" .= request.queueMessageId])
            }
          PgmqStatements.readMessage
      case toList entries of
        [] -> pure (Right request)
        entry : _ -> case parseEither (withObject "Keiro DLQ envelope" (.: "dead_letter_reason")) (unMessageBody entry.body) of
          Left _ -> Tx.condemn >> pure (Left "The run disposition is unavailable.")
          Right reason -> do
            updated <- Tx.statement (request.runKey, boundedBehaviorDetail reason) receiptStatement
            case updated of
              Nothing -> Tx.condemn >> pure (Left "The run disposition is unavailable.")
              Just row -> pure (Right row)
    receiptStatement =
      preparable
        ("UPDATE shikigami.agent_run_requests SET disposition='dead_lettered', disposition_detail=COALESCE(disposition_detail,$2), disposition_at=COALESCE(disposition_at,now()) WHERE run_key=$1 RETURNING " <> columns)
        keyEncoder
        (D.rowMaybe rowDecoder)

data RunListError = InvalidRunCursor !CursorError | RunListUnavailable !Text
  deriving stock (Eq, Show)

listRunRequests :: Pool -> AgentName -> PageRequest -> IO (Either RunListError (Connection RunRequestRow))
listRunRequests pool agent request = case Relay.paginate runSort request base rowDecoder of
  Left err -> pure (Left (InvalidRunCursor err))
  Right statement -> first RunListUnavailable <$> safeUse pool (Session.statement () statement)
  where
    base =
      Snippet.sql ("SELECT " <> columns <> " FROM shikigami.agent_run_requests WHERE agent_name = ")
        <> Snippet.encoderAndParam (E.nonNullable E.text) (agentNameText agent)
    runSort =
      Relay.SortSpec
        ( Relay.KeyColumn "accepted_at" Relay.Desc (.acceptedAt) Relay.timestamptzKey
            :| [Relay.KeyColumn "run_id" Relay.Asc (.runId) Relay.textKey]
        )
