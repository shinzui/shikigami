-- Migration: workspace-git-effect-records
-- Created: 2026-10-30-02-48-50 UTC
-- Write idempotent DDL (CREATE ... IF NOT EXISTS) so re-application is safe.

-- Qualify every persistent object with its owning schema. Migration SQL may
-- not mutate search_path. Validate with: just migration-schema-isolation.

-- Keep the common unsettled-effect barrier. Historical rows and file receipt
-- encodings retain their meaning; each provider reads only its own receipt kind.
ALTER TABLE shikigami.workspace_effects
  ADD COLUMN IF NOT EXISTS kind text NOT NULL DEFAULT 'file'
    CHECK (kind IN ('file', 'git'));
