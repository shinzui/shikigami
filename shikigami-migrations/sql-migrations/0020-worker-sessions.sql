-- Migration: worker-sessions
-- Created: 2026-10-28-16-55-08 UTC
-- Write idempotent DDL (CREATE ... IF NOT EXISTS) so re-application is safe.

-- Qualify every persistent object with its owning schema. Migration SQL may
-- not mutate search_path. Validate with: just migration-schema-isolation.

CREATE TABLE IF NOT EXISTS shikigami.worker_sessions (
  session_id text PRIMARY KEY CHECK (length(session_id) BETWEEN 1 AND 256),
  scope_digest text NOT NULL UNIQUE,
  state jsonb NOT NULL,
  binding jsonb NOT NULL,
  updated_at timestamptz NOT NULL DEFAULT now()
);

CREATE TABLE IF NOT EXISTS shikigami.worker_session_payloads (
  session_id text NOT NULL REFERENCES shikigami.worker_sessions(session_id),
  payload_id text NOT NULL,
  digest text NOT NULL,
  bytes bigint NOT NULL CHECK (bytes BETWEEN 0 AND 1048576),
  body jsonb NOT NULL,
  PRIMARY KEY (session_id, payload_id)
);
REVOKE ALL ON shikigami.worker_session_payloads FROM PUBLIC;

CREATE TABLE IF NOT EXISTS shikigami.worker_session_messages (
  session_id text NOT NULL REFERENCES shikigami.worker_sessions(session_id),
  sequence bigint NOT NULL CHECK (sequence BETWEEN 0 AND 9999),
  assignment_id text NOT NULL UNIQUE,
  operation_id text NOT NULL CHECK (length(operation_id) BETWEEN 1 AND 256),
  state jsonb NOT NULL,
  PRIMARY KEY (session_id, sequence),
  UNIQUE (session_id, operation_id)
);

CREATE TABLE IF NOT EXISTS shikigami.worker_session_results (
  session_id text NOT NULL REFERENCES shikigami.worker_sessions(session_id),
  assignment_id text PRIMARY KEY REFERENCES shikigami.worker_session_messages(assignment_id),
  state jsonb NOT NULL
);

CREATE TABLE IF NOT EXISTS shikigami.worker_session_events (
  session_id text NOT NULL REFERENCES shikigami.worker_sessions(session_id),
  cursor bigint NOT NULL CHECK (cursor BETWEEN 1 AND 100000),
  state jsonb NOT NULL,
  PRIMARY KEY (session_id, cursor)
);

-- Stable command keys and pending integration intents outlive queue delivery.
-- Only metadata and protected payload references belong in this state column.
CREATE TABLE IF NOT EXISTS shikigami.worker_session_commands (
  session_id text NOT NULL REFERENCES shikigami.worker_sessions(session_id),
  operation_id text NOT NULL CHECK (length(operation_id) BETWEEN 1 AND 256),
  fingerprint text NOT NULL,
  state jsonb NOT NULL,
  PRIMARY KEY (session_id, operation_id)
);
