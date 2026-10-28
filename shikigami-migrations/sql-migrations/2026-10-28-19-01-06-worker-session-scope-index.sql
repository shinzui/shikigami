-- Migration: worker-session-scope-index
-- Created: 2026-10-28-19-01-06 UTC
-- Write idempotent DDL (CREATE ... IF NOT EXISTS) so re-application is safe.

-- Qualify every persistent object with its owning schema. Migration SQL may
-- not mutate search_path. Validate with: just migration-schema-isolation.

-- Admission serializes this scope under an application advisory lock before
-- counting retained sessions. All past sessions count; a new grant cannot reset
-- the count or substitute another resource root.
CREATE INDEX IF NOT EXISTS worker_sessions_parent_scope
  ON shikigami.worker_sessions
  ((binding->'scope'->>'parent'), (binding->'parentIdentity'), session_id);
