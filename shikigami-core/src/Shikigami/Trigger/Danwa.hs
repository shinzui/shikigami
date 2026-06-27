module Shikigami.Trigger.Danwa
  ( AddressedMessage (..),
    DanwaBridgeConfig (..),
    DanwaBridgeResult (..),
    detectAddressed,
    runDanwaBridgeOnce,
    runDanwaBridge,
  )
where

import Control.Concurrent (threadDelay)
import Control.Monad (forM, forever, void)
import Data.Aeson (FromJSON (..), ToJSON (..), object, withObject, (.:), (.=))
import Data.Functor ((<&>))
import Data.List (find)
import Data.Maybe (fromMaybe)
import Data.Text (Text)
import Data.Text qualified as Text
import Hasql.Decoders qualified as D
import Hasql.Encoders qualified as E
import Hasql.Pool (Pool, UsageError)
import Hasql.Pool qualified as Pool
import Hasql.Session qualified as Session
import Hasql.Statement (Statement, preparable)
import Pgmq (MessageId)
import Shikigami.Api.Agent (AgentDecl (..))
import Shikigami.Trigger.Enqueue (enqueueAddressedRunWithKey)
import System.IO (hPutStrLn, stderr)

data AddressedMessage = AddressedMessage
  { conversationId :: !Text,
    messageId :: !Text,
    author :: !Text,
    content :: !Text,
    agentParticipant :: !Text
  }
  deriving stock (Eq, Show)

instance ToJSON AddressedMessage where
  toJSON msg =
    object
      [ "conversationId" .= conversationId msg,
        "messageId" .= messageId msg,
        "author" .= author msg,
        "content" .= content msg,
        "agentParticipant" .= agentParticipant msg
      ]

instance FromJSON AddressedMessage where
  parseJSON =
    withObject "AddressedMessage" \o ->
      AddressedMessage
        <$> o .: "conversationId"
        <*> o .: "messageId"
        <*> o .: "author"
        <*> o .: "content"
        <*> o .: "agentParticipant"

data DanwaBridgeConfig = DanwaBridgeConfig
  { agentMap :: ![(Text, Text)],
    pollIntervalMicros :: !Int,
    deliverAddressed :: !(AddressedMessage -> IO Bool)
  }

data DanwaBridgeResult
  = DeliveredToConversation
  | EnqueuedRun !(Either UsageError MessageId)

runDanwaBridge :: DanwaBridgeConfig -> Pool -> Pool -> [AgentDecl] -> IO ()
runDanwaBridge cfg shikigamiPool danwaPool agents = forever do
  _ <- runDanwaBridgeOnce cfg shikigamiPool danwaPool agents
  threadDelay (pollIntervalMicros cfg)

runDanwaBridgeOnce :: DanwaBridgeConfig -> Pool -> Pool -> [AgentDecl] -> IO [(AddressedMessage, DanwaBridgeResult)]
runDanwaBridgeOnce cfg shikigamiPool danwaPool agents = do
  ensureSeenTable shikigamiPool
  detected <- detectAddressed cfg danwaPool
  fmap concat $
    forM detected \msg ->
      case resolveAgent cfg agents msg of
        Nothing -> do
          hPutStrLn stderr ("[danwa-bridge] no declared agent for participant " <> Text.unpack (agentParticipant msg))
          pure []
        Just agent -> do
          let key = agent <> ":" <> messageId msg
          claimed <- claimSeen shikigamiPool key
          if not claimed
            then pure []
            else do
              delivered <- deliverAddressed cfg msg
              if delivered
                then pure [(msg, DeliveredToConversation)]
                else do
                  result <- enqueueAddressedRunWithKey shikigamiPool agent (toJSON msg) key
                  pure [(msg, EnqueuedRun result)]

detectAddressed :: DanwaBridgeConfig -> Pool -> IO [AddressedMessage]
detectAddressed cfg danwaPool = do
  fmap concat $
    forM (fst <$> agentMap cfg) \participant ->
      Pool.use danwaPool (Session.statement participant selectAddressedStmt) <&> \case
        Right rows -> rows
        Left _ ->
          -- A missing danwa database or schema should not crash a supervised bridge loop.
          -- The next poll can recover once danwa is available.
          []

resolveAgent :: DanwaBridgeConfig -> [AgentDecl] -> AddressedMessage -> Maybe Text
resolveAgent cfg agents msg = do
  agentName <- lookup (agentParticipant msg) (agentMap cfg)
  declared <- find ((== agentName) . name) agents
  pure (name declared)

ensureSeenTable :: Pool -> IO ()
ensureSeenTable pool =
  void $
    Pool.use pool $
      Session.script
        """
        CREATE TABLE IF NOT EXISTS shikigami_danwa_bridge_seen (
          idempotency_key text PRIMARY KEY,
          seen_at timestamptz NOT NULL DEFAULT now()
        )
        """

claimSeen :: Pool -> Text -> IO Bool
claimSeen pool key =
  Pool.use pool (Session.statement key claimSeenStmt) <&> \case
    Right claimed -> claimed
    Left _ -> False

selectAddressedStmt :: Statement Text [AddressedMessage]
selectAddressedStmt =
  preparable
    """
    SELECT m.conversation_id,
           m.message_id,
           m.author,
           m.content,
           $1
      FROM danwa.danwa_messages m
      JOIN danwa.danwa_embellishments e
        ON e.target_type = 'message'
       AND e.target_id = m.message_id
     WHERE NOT m.deleted
       AND NOT e.removed
       AND e.kind = 'mention'
       AND (e.payload ->> 'mentionedParticipantId' = $1
            OR e.payload ->> 'participantId' = $1
            OR e.payload ->> 'participant_id' = $1)
     ORDER BY m.posted_at, m.message_id
     LIMIT 100
    """
    (E.param (E.nonNullable E.text))
    (D.rowList addressedRow)

addressedRow :: D.Row AddressedMessage
addressedRow =
  AddressedMessage
    <$> D.column (D.nonNullable D.text)
    <*> D.column (D.nonNullable D.text)
    <*> D.column (D.nonNullable D.text)
    <*> D.column (D.nonNullable D.text)
    <*> D.column (D.nonNullable D.text)

claimSeenStmt :: Statement Text Bool
claimSeenStmt =
  preparable
    """
    INSERT INTO shikigami_danwa_bridge_seen (idempotency_key)
    VALUES ($1)
    ON CONFLICT (idempotency_key) DO NOTHING
    RETURNING true
    """
    (E.param (E.nonNullable E.text))
    (fromMaybe False <$> D.rowMaybe (D.column (D.nonNullable D.bool)))
