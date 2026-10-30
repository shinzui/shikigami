-- Migration: execution-attempt-claims
-- Created: 2026-10-28-12-05-01 UTC
-- Write idempotent DDL (CREATE ... IF NOT EXISTS) so re-application is safe.

-- Qualify every persistent object with its owning schema. Migration SQL may
-- not mutate search_path. Validate with: just migration-schema-isolation.

-- Keep the established execution projection group and query identity. Old
-- writers preserve this new column while updating their operation state.
ALTER TABLE shikigami.execution_transcript_operations
  ADD COLUMN IF NOT EXISTS dispatches jsonb NOT NULL DEFAULT '{}'::jsonb
  CHECK (jsonb_typeof(dispatches) = 'object');
CREATE INDEX IF NOT EXISTS execution_transcript_operation_dispatches
  ON shikigami.execution_transcript_operations USING GIN (dispatches);
