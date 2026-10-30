-- Migration: workspace-process-registrations
-- Created: 2026-10-29-18-00-53 UTC
-- Write idempotent DDL (CREATE ... IF NOT EXISTS) so re-application is safe.

-- Qualify every persistent object with its owning schema. Migration SQL may
-- not mutate search_path. Validate with: just migration-schema-isolation.

-- Launch/receipt metadata is independent of queue-worker lifetime. It does not
-- replace accepted execution attempts, resource accounting or authorization.
CREATE TABLE IF NOT EXISTS shikigami.workspace_processes (
  operation_id text PRIMARY KEY,
  resource text NOT NULL REFERENCES shikigami.workspace_bindings(resource),
  fingerprint text NOT NULL,
  record jsonb NOT NULL,
  settled boolean NOT NULL DEFAULT false
);
CREATE INDEX IF NOT EXISTS workspace_unsettled_processes
  ON shikigami.workspace_processes(resource) WHERE NOT settled;
