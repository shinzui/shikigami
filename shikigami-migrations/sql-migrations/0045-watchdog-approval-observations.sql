-- Migration: watchdog-approval-observations
-- Write idempotent DDL (CREATE ... IF NOT EXISTS) so re-application is safe.

-- Qualify every persistent object with its owning schema. Migration SQL may
-- not mutate search_path. Validate with: just migration-schema-isolation.

-- Body-free relation published by the approval owner. It grants no authority
-- and contains no approval request, decision or timer payload.
CREATE TABLE IF NOT EXISTS shikigami.approval_observation_associations (
  review_id text PRIMARY KEY,
  parent_name text NOT NULL CHECK (length(parent_name) BETWEEN 1 AND 512),
  parent_id text NOT NULL CHECK (length(parent_id) BETWEEN 1 AND 512)
);
CREATE INDEX IF NOT EXISTS approval_observation_parent
  ON shikigami.approval_observation_associations (parent_name, parent_id, review_id);
