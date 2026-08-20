-- Migration: conversation-session-index
-- Created: 2026-08-20-17-30-49 UTC
-- Write idempotent DDL (CREATE ... IF NOT EXISTS) so re-application is safe.
--
-- The keyed conversation -> kioku session index.
--
-- Resolving which kioku session a danwa conversation belongs to used to be a
-- linear scan over every session the agent has ever had
-- (Kioku.Session.getByScope, then a filter on subject_ref). That is O(sessions
-- per agent) on every single turn and it only ever grows.
--
-- Kioku owns the fact; this table is only a keyed cache of it. The authority is
-- still kioku.sessions.subject_ref, and Shikigami.Agent.Conversation.resolveSession
-- re-reads the row through Kioku.Session.getById after this index answers, so a
-- stale or wrong pointer here cannot invent a session that does not exist. When
-- kioku ships an indexed subject_ref read model
-- (mori://shinzui/kioku/okf/improvement-requests/concepts/IR-2) this table is
-- retired and the query moves upstream.
--
-- Like shikigami.sink_grants, every object here is schema-qualified rather than
-- relying on the search_path above: the runtime reads this table over the
-- event-store pool, whose search_path is kiroku.
CREATE SCHEMA IF NOT EXISTS shikigami;

CREATE TABLE IF NOT EXISTS shikigami.conversation_sessions (
  conversation_id TEXT        PRIMARY KEY,
  session_id      TEXT        NOT NULL,
  updated_at      TIMESTAMPTZ NOT NULL DEFAULT now()
);
