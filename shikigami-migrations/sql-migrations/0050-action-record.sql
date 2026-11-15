-- Migration: action-record
-- Write idempotent DDL (CREATE ... IF NOT EXISTS) so re-application is safe.

-- Qualify every persistent object with its owning schema. Migration SQL may
-- not mutate search_path. Validate with: just migration-schema-isolation.

-- The kernel's action record (ADR-123): one append-only row per authority
-- decision and per external effect. Rows are inserted through
-- Shikigami.Record and are never updated or deleted by the application. The
-- repository has one database role, so insert-only is enforced by the API
-- rather than by a grant.
CREATE TABLE IF NOT EXISTS shikigami.action_record (
  seq bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  at timestamptz NOT NULL,
  run_id text NULL,
  principal text NOT NULL,
  tier text NOT NULL,
  agent text NULL,
  kind text NOT NULL,
  payload jsonb NOT NULL
);
CREATE INDEX IF NOT EXISTS action_record_run ON shikigami.action_record(run_id, seq);
CREATE INDEX IF NOT EXISTS action_record_kind ON shikigami.action_record(kind, seq);
REVOKE ALL ON shikigami.action_record FROM PUBLIC;
