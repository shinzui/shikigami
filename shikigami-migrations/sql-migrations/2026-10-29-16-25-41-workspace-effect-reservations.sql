-- Migration: workspace-effect-reservations
-- Created: 2026-10-29-16-25-41 UTC
-- Write idempotent DDL (CREATE ... IF NOT EXISTS) so re-application is safe.

-- Qualify every persistent object with its owning schema. Migration SQL may
-- not mutate search_path. Validate with: just migration-schema-isolation.

CREATE TABLE IF NOT EXISTS shikigami.workspace_controls (
  resource text PRIMARY KEY REFERENCES shikigami.workspace_bindings(resource),
  owner jsonb NOT NULL,
  epoch bigint NOT NULL CHECK (epoch >= 0),
  frozen boolean NOT NULL DEFAULT false
);
INSERT INTO shikigami.workspace_controls(resource,owner,epoch)
SELECT resource,binding->'request'->'owner',(binding->'request'->>'epoch')::bigint
FROM shikigami.workspace_bindings ON CONFLICT DO NOTHING;

-- Effect receipts are factual provider metadata, never an alternate attempt or
-- accounting owner. Accepted execution operation IDs remain globally unique.
CREATE TABLE IF NOT EXISTS shikigami.workspace_effects (
  operation_id text PRIMARY KEY,
  resource text NOT NULL REFERENCES shikigami.workspace_bindings(resource),
  fingerprint text NOT NULL,
  receipt jsonb,
  settled boolean NOT NULL DEFAULT false
);
CREATE INDEX IF NOT EXISTS workspace_unsettled_effects
  ON shikigami.workspace_effects(resource) WHERE NOT settled;
