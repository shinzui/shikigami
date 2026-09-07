{-# LANGUAGE MultilineStrings #-}

-- | The keyed conversation-to-session index.
--
-- A danwa conversation runs as one durable workflow, and every turn of it has to
-- answer the same question: which kioku session am I recording into? Before this
-- module the answer came from 'Kioku.Session.getByScope' — every session the
-- agent has ever had — followed by a linear scan for one whose @subjectRef@
-- matched the conversation id. That is O(sessions per agent) per turn, on a set
-- that only grows.
--
-- This module is the keyed answer: one row per conversation id, pointing at the
-- session that conversation is being recorded into.
--
-- __Kioku is still the authority.__ This table is a cache of a fact kioku owns
-- (@kioku.sessions.subject_ref@), not a second source of truth. Every caller
-- resolves an id here and then re-reads the session row through
-- 'Kioku.Session.getById', so a stale or wrong pointer cannot invent a session
-- that does not exist — it can only cause a miss, and a miss falls back to the
-- scan and repairs itself. The index exists because kioku has no @subjectRef@
-- read model yet; when
-- @mori:\/\/shinzui\/kioku\/okf\/improvement-requests\/concepts\/IR-2@ ships,
-- this module and its table are retired and the query moves upstream.
--
-- Every statement is __schema-qualified__, for the same reason
-- "Shikigami.Sink.GrantStore" says so: these run on the event-store pool, whose
-- @search_path@ is @kiroku@, so an unqualified @conversation_sessions@ would
-- resolve to the wrong schema or to nothing at all.
module Shikigami.Agent.Conversation.SessionIndex
  ( lookupConversationSession,
    rememberConversationSession,
    lookupConversationEpoch,
    advanceConversationEpoch,
  )
where

import Contravariant.Extras (contrazip3)
import Data.Functor.Contravariant ((>$<))
import Effectful (Eff, (:>))
import Hasql.Decoders qualified as Decoders
import Hasql.Encoders qualified as Encoders
import Hasql.Statement (Statement, preparable)
import Hasql.Transaction qualified as Tx
import Kiroku.Store.Effect (Store)
import Kiroku.Store.Transaction (runTransaction)
import Shikigami.Prelude

-- | The session id this conversation was last recorded into, if the index knows
-- one.
--
-- 'Nothing' means "ask kioku the slow way" rather than "no session exists": the
-- index is a cache, and a miss is always safe to repair.
lookupConversationSession :: (Store :> es) => Text -> Eff es (Maybe Text)
lookupConversationSession conversationId =
  runTransaction (Tx.statement conversationId selectConversationSessionStmt)

-- | Point this conversation at this session, replacing any previous pointer.
--
-- An upsert rather than an insert because a conversation outlives any one
-- session: after an idle timeout completes one session, the next epoch opens a
-- new one under the same conversation id and this row moves to it.
--
-- The epoch is deliberately left alone. Which epoch is live is
-- 'advanceConversationEpoch''s answer, and a new session inside an epoch must
-- not disturb it.
rememberConversationSession :: (Store :> es) => Text -> Text -> UTCTime -> Eff es ()
rememberConversationSession conversationId sessionId now =
  runTransaction (Tx.statement (conversationId, sessionId, now) upsertConversationSessionStmt)

-- | Which epoch of this conversation is live.
--
-- An /epoch/ is one workflow instance, from a conversation's first message (or
-- its first message after an idle timeout) until the next idle timeout. Epoch 0
-- is the answer for a conversation nobody has heard of, which is what keeps a
-- first message addressing the historical workflow id.
lookupConversationEpoch :: (Store :> es) => Text -> Eff es Int
lookupConversationEpoch conversationId =
  fromMaybe 0 <$> runTransaction (Tx.statement conversationId selectConversationEpochStmt)

-- | Record that this conversation has moved on to @epoch@.
--
-- __Idempotent by construction, not by being called once.__ It sets the epoch to
-- a value the caller computed (the completing epoch, plus one) under a
-- @GREATEST@, rather than incrementing. The caller is a journaled workflow step,
-- and a journaled step is at-least-once: an increment run twice would skip an
-- epoch, and — worse — could move the live epoch past an instance that ingress
-- had already started addressing, orphaning it. @GREATEST@ of an absolute value
-- cannot do either.
advanceConversationEpoch :: (Store :> es) => Text -> Int -> UTCTime -> Eff es ()
advanceConversationEpoch conversationId epoch now =
  runTransaction (Tx.statement (conversationId, epoch, now) advanceConversationEpochStmt)

selectConversationSessionStmt :: Statement Text (Maybe Text)
selectConversationSessionStmt =
  preparable
    """
    SELECT session_id
    FROM shikigami.conversation_sessions
    WHERE conversation_id = $1
    """
    (Encoders.param (Encoders.nonNullable Encoders.text))
    (Decoders.rowMaybe (Decoders.column (Decoders.nonNullable Decoders.text)))

selectConversationEpochStmt :: Statement Text (Maybe Int)
selectConversationEpochStmt =
  preparable
    """
    SELECT epoch
    FROM shikigami.conversation_sessions
    WHERE conversation_id = $1
    """
    (Encoders.param (Encoders.nonNullable Encoders.text))
    (Decoders.rowMaybe (Decoders.column (Decoders.nonNullable (fromIntegral <$> Decoders.int4))))

advanceConversationEpochStmt :: Statement (Text, Int, UTCTime) ()
advanceConversationEpochStmt =
  preparable
    """
    INSERT INTO shikigami.conversation_sessions (conversation_id, session_id, updated_at, epoch)
    VALUES ($1, '', $3, $2)
    ON CONFLICT (conversation_id) DO UPDATE
      SET epoch = GREATEST(shikigami.conversation_sessions.epoch, EXCLUDED.epoch),
          updated_at = EXCLUDED.updated_at
    """
    ( contrazip3
        (Encoders.param (Encoders.nonNullable Encoders.text))
        (fromIntegral >$< Encoders.param (Encoders.nonNullable Encoders.int4))
        (Encoders.param (Encoders.nonNullable Encoders.timestamptz))
    )
    Decoders.noResult

upsertConversationSessionStmt :: Statement (Text, Text, UTCTime) ()
upsertConversationSessionStmt =
  preparable
    """
    INSERT INTO shikigami.conversation_sessions (conversation_id, session_id, updated_at)
    VALUES ($1, $2, $3)
    ON CONFLICT (conversation_id) DO UPDATE
      SET session_id = EXCLUDED.session_id,
          updated_at = EXCLUDED.updated_at
    """
    ( contrazip3
        (Encoders.param (Encoders.nonNullable Encoders.text))
        (Encoders.param (Encoders.nonNullable Encoders.text))
        (Encoders.param (Encoders.nonNullable Encoders.timestamptz))
    )
    Decoders.noResult
