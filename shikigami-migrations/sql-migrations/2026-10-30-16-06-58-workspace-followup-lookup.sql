-- Migration: workspace-followup-lookup
-- Created: 2026-10-30-16-06-58 UTC
-- Write idempotent DDL (CREATE ... IF NOT EXISTS) so re-application is safe.

-- Qualify every persistent object with its owning schema. Migration SQL may
-- not mutate search_path. Validate with: just migration-schema-isolation.

CREATE INDEX IF NOT EXISTS workspace_session_allocation
  ON shikigami.workspace_bindings((binding->'request'->'assignment'->>0));
CREATE INDEX IF NOT EXISTS execution_assignment_lookup
  ON shikigami.executions((binding->>'assignmentId'));
