-- Migration: workspace-file-receipt-routing
-- Created: 2026-10-30-14-51-50 UTC
-- Write idempotent DDL (CREATE ... IF NOT EXISTS) so re-application is safe.

-- Qualify every persistent object with its owning schema. Migration SQL may
-- not mutate search_path. Validate with: just migration-schema-isolation.

-- Historical file receipts stay readable and gain no invented continuation.
CREATE TABLE IF NOT EXISTS shikigami.workspace_file_registrations (
  operation_id text PRIMARY KEY REFERENCES shikigami.workspace_effects(operation_id),
  registration jsonb NOT NULL
);
REVOKE ALL ON shikigami.workspace_file_registrations FROM PUBLIC;
