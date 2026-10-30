-- Migration: workspace-bindings
-- Created: 2026-10-29-13-51-21 UTC
-- Write idempotent DDL (CREATE ... IF NOT EXISTS) so re-application is safe.

-- Qualify every persistent object with its owning schema. Migration SQL may
-- not mutate search_path. Validate with: just migration-schema-isolation.

-- Paths and principals in binding are protected provider metadata, never public
-- diagnostics or journal payloads. Reservation identity cannot be reassigned.
CREATE TABLE IF NOT EXISTS shikigami.workspace_bindings (
  assignment_key text PRIMARY KEY,
  resource text NOT NULL UNIQUE,
  binding jsonb NOT NULL,
  state text NOT NULL CHECK (state IN ('reserved', 'ready'))
);
