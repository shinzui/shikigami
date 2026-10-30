-- Migration: execution-selection-call-facts
-- Created: 2026-10-28-04-30-50 UTC
-- Write idempotent DDL (CREATE ... IF NOT EXISTS) so re-application is safe.

-- Qualify every persistent object with its owning schema. Migration SQL may
-- not mutate search_path. Validate with the migration-schema-isolation recipe.
CREATE TABLE IF NOT EXISTS shikigami.execution_selections (
  assignment_id text PRIMARY KEY CHECK (length(assignment_id) BETWEEN 1 AND 256),
  state jsonb NOT NULL
);
CREATE TABLE IF NOT EXISTS shikigami.execution_selection_calls (
  assignment_id text NOT NULL REFERENCES shikigami.execution_selections(assignment_id),
  attempt_id text PRIMARY KEY CHECK (length(attempt_id) BETWEEN 1 AND 256),
  operation_id text NOT NULL,
  ordinal bigint NOT NULL CHECK (ordinal > 0),
  state jsonb NOT NULL,
  UNIQUE (assignment_id, ordinal)
);
CREATE INDEX IF NOT EXISTS execution_selection_calls_assignment
  ON shikigami.execution_selection_calls(assignment_id);
CREATE INDEX IF NOT EXISTS execution_selection_calls_operation
  ON shikigami.execution_selection_calls(assignment_id, operation_id);
