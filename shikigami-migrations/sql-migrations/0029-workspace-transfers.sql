-- Migration: workspace-transfers
-- Created: 2026-10-30-14-59-29 UTC
-- Write idempotent DDL (CREATE ... IF NOT EXISTS) so re-application is safe.

-- Qualify every persistent object with its owning schema. Migration SQL may
-- not mutate search_path. Validate with: just migration-schema-isolation.

CREATE TABLE IF NOT EXISTS shikigami.workspace_transfers (
  resource text NOT NULL REFERENCES shikigami.workspace_bindings(resource),
  old_epoch bigint NOT NULL CHECK (old_epoch >= 0),
  intent jsonb NOT NULL,
  proof jsonb,
  PRIMARY KEY(resource, old_epoch)
);
CREATE INDEX IF NOT EXISTS worker_session_child_mapping
  ON shikigami.worker_session_messages((state->>'childWorkflowId'))
  WHERE state->>'childWorkflowId' IS NOT NULL;
CREATE TABLE IF NOT EXISTS shikigami.workspace_successor_admissions (
  run_id text PRIMARY KEY,
  resource text NOT NULL REFERENCES shikigami.workspace_bindings(resource),
  session_id text NOT NULL REFERENCES shikigami.worker_sessions(session_id),
  assignment_id text NOT NULL UNIQUE REFERENCES shikigami.worker_session_messages(assignment_id),
  sequence bigint NOT NULL CHECK (sequence BETWEEN 0 AND 9999),
  admission jsonb NOT NULL
);
REVOKE ALL ON shikigami.workspace_transfers FROM PUBLIC;
REVOKE ALL ON shikigami.workspace_successor_admissions FROM PUBLIC;
