-- Migration: execution-transcripts-and-accepted-operations
-- Created: 2026-10-28-05-48-04 UTC
-- Write idempotent DDL (CREATE ... IF NOT EXISTS) so re-application is safe.

-- Qualify every persistent object with its owning schema. Migration SQL may
-- not mutate search_path. Validate with: just migration-schema-isolation.

CREATE TABLE IF NOT EXISTS shikigami.executions (
  execution_id text PRIMARY KEY CHECK (length(execution_id) BETWEEN 1 AND 256),
  state jsonb NOT NULL,
  binding jsonb NOT NULL,
  updated_at timestamptz NOT NULL DEFAULT now()
);

-- Replay bodies are never selected by ordinary inspection. Runtime reads are
-- bound to one admitted execution and identity by the application store API.
CREATE TABLE IF NOT EXISTS shikigami.execution_payloads (
  execution_id text NOT NULL REFERENCES shikigami.executions(execution_id),
  payload_id text NOT NULL,
  digest text NOT NULL,
  bytes bigint NOT NULL CHECK (bytes BETWEEN 0 AND 1048576),
  body jsonb NOT NULL,
  PRIMARY KEY (execution_id, payload_id)
);
REVOKE ALL ON shikigami.execution_payloads FROM PUBLIC;

CREATE TABLE IF NOT EXISTS shikigami.execution_transcript_operations (
  execution_id text NOT NULL REFERENCES shikigami.executions(execution_id),
  operation_id text PRIMARY KEY CHECK (length(operation_id) BETWEEN 1 AND 256),
  position bigint NOT NULL CHECK (position BETWEEN 0 AND 10000),
  state jsonb NOT NULL,
  UNIQUE (execution_id, position)
);
CREATE INDEX IF NOT EXISTS execution_transcript_operations_execution
  ON shikigami.execution_transcript_operations(execution_id, position);
