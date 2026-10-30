-- Migration: workspace-terminal-cleanup
-- Created: 2026-10-30-13-16-43 UTC
-- Write idempotent DDL (CREATE ... IF NOT EXISTS) so re-application is safe.

-- Qualify every persistent object with its owning schema. Migration SQL may
-- not mutate search_path. Validate with: just migration-schema-isolation.

-- Cleanup retains the exact roots and identity before deleting any worktree.
-- Provider metadata and all effect receipts survive terminal cleanup.
CREATE TABLE IF NOT EXISTS shikigami.workspace_cleanup (
  resource text PRIMARY KEY REFERENCES shikigami.workspace_bindings(resource),
  plan jsonb NOT NULL,
  complete boolean NOT NULL DEFAULT false
);
REVOKE ALL ON shikigami.workspace_cleanup FROM PUBLIC;
