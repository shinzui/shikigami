-- | The HTTP boundary owns acceptance before a worker creates a workflow.
module Shikigami.AgentRun.Ledger
  ( RunRequestRow (..),
    AcceptOutcome (..),
    httpRunKey,
    payloadFingerprint,
    acceptRunRequest,
    lookupRunRequest,
    recordDeadLetter,
    listRunRequests,
    RunListError (..),
  )
where

import Data.Aeson (Value, encode)
import Data.Bifunctor (first)
import Data.ByteString qualified as BS
import Data.ByteString.Lazy qualified as LBS
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
import Keiro.Workflow.Types (WorkflowId (..))
import Pgmq (MessageId (..))
import Relay.Pagination (Connection, CursorError, PageRequest)
import Relay.Pagination.Hasql qualified as Relay
import Shikigami.Agent.Name (AgentName, agentNameText)
import Shikigami.Agent.Run.Key (RunKey (..), runKeyText)
import Shikigami.Agent.RunJob (RunJob (..), runJobWorkflowId)
import Shikigami.Behavior.Error (boundedBehaviorDetail)
import Shikigami.Prelude
import Shikigami.Trigger.Enqueue (enqueueRunJobTx)

httpRunKey :: AgentName -> Text -> RunKey
httpRunKey agent key = RunKey (agentNameText agent <> ":http:" <> key)

-- Aeson's ordered object encoding makes object member order immaterial.
payloadFingerprint :: Value -> Text
payloadFingerprint = UUID.toText . UUID.generateNamed UUID.namespaceURL . BS.unpack . LBS.toStrict . encode

data RunRequestRow = RunRequestRow
  { agentName :: !Text,
    idempotencyKey :: !Text,
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

acceptRunRequest :: Pool -> RunJob -> Text -> IO (Either Text AcceptOutcome)
acceptRunRequest pool job caller = do
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
    agent = agentNameText job.agentName
    key = Text.drop (Text.length agent + Text.length ":http:") (runKeyText job.idempotencyKey)
    fingerprint = payloadFingerprint job.triggerPayload
    accept = do
      MessageId message <- enqueueRunJobTx job
      let row = RunRequestRow agent key (runJobWorkflowId job).unWorkflowId (runKeyText job.idempotencyKey) fingerprint caller message job.occurredAt "accepted" Nothing Nothing
      inserted <- Tx.statement row insertStatement
      case inserted of
        Just acceptedAt -> pure (Just (row & #acceptedAt .~ acceptedAt))
        Nothing -> Tx.condemn >> pure Nothing

lookupRunRequest :: Pool -> AgentName -> Text -> IO (Either Text (Maybe RunRequestRow))
lookupRunRequest pool agent runId = safeUse pool (Session.statement (agentNameText agent, runId) lookupIdStatement)

safeUse :: Pool -> Session.Session a -> IO (Either Text a)
safeUse pool action = first (const "The run acceptance store is unavailable.") <$> Pool.use pool action

columns :: Text
columns = "agent_name, idempotency_key, run_id, run_key, payload_fingerprint, requested_by, queue_message_id, accepted_at, disposition, disposition_detail, disposition_at"

rowDecoder :: D.Row RunRequestRow
rowDecoder =
  RunRequestRow
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

keyEncoder :: E.Params (Text, Text)
keyEncoder = (fst >$< E.param (E.nonNullable E.text)) <> (snd >$< E.param (E.nonNullable E.text))

lookupKeyStatement, lookupIdStatement :: Statement (Text, Text) (Maybe RunRequestRow)
lookupKeyStatement = preparable ("SELECT " <> columns <> " FROM shikigami.agent_run_requests WHERE agent_name=$1 AND idempotency_key=$2") keyEncoder (D.rowMaybe rowDecoder)
lookupIdStatement = preparable ("SELECT " <> columns <> " FROM shikigami.agent_run_requests WHERE agent_name=$1 AND run_id=$2") keyEncoder (D.rowMaybe rowDecoder)

insertStatement :: Statement RunRequestRow (Maybe UTCTime)
insertStatement =
  preparable
    "INSERT INTO shikigami.agent_run_requests (agent_name,idempotency_key,run_id,run_key,payload_fingerprint,requested_by,queue_message_id) VALUES ($1,$2,$3,$4,$5,$6,$7) ON CONFLICT (agent_name,idempotency_key) DO NOTHING RETURNING accepted_at"
    ( ((.agentName) >$< E.param (E.nonNullable E.text))
        <> ((.idempotencyKey) >$< E.param (E.nonNullable E.text))
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
