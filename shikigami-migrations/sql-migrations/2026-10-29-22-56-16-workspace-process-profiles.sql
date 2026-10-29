-- Migration: workspace-process-profiles
-- Created: 2026-10-29-22-56-16 UTC
-- Write idempotent DDL (CREATE ... IF NOT EXISTS) so re-application is safe.

-- Qualify every persistent object with its owning schema. Migration SQL may
-- not mutate search_path. Validate with: just migration-schema-isolation.

-- The reserved Unix pool is operator-owned. Rows survive worker/service loss;
-- identity recycling is a separate, fenced cleanup operation.
CREATE TABLE IF NOT EXISTS shikigami.workspace_profile_allocator (
  singleton boolean PRIMARY KEY CHECK (singleton)
);
INSERT INTO shikigami.workspace_profile_allocator(singleton) VALUES(true)
  ON CONFLICT DO NOTHING;

CREATE TABLE IF NOT EXISTS shikigami.workspace_process_profiles (
  resource text PRIMARY KEY REFERENCES shikigami.workspace_bindings(resource),
  user_id integer UNIQUE NOT NULL CHECK (user_id >= 1000),
  profile jsonb NOT NULL,
  ready boolean NOT NULL DEFAULT false
);
