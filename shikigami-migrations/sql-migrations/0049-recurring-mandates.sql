-- Migration: recurring-mandates
-- Write idempotent DDL (CREATE ... IF NOT EXISTS) so re-application is safe.

-- Qualify every persistent object with its owning schema. Migration SQL may
-- not mutate search_path. Validate with: just migration-schema-isolation.

CREATE TABLE IF NOT EXISTS shikigami.mandates (
  mandate_id text PRIMARY KEY,
  objective_id text NOT NULL REFERENCES shikigami.objectives(objective_id),
  state jsonb NOT NULL
);
CREATE INDEX IF NOT EXISTS mandates_objective ON shikigami.mandates(objective_id, mandate_id);
CREATE TABLE IF NOT EXISTS shikigami.mandate_receipts (
  mandate_id text NOT NULL REFERENCES shikigami.mandates(mandate_id),
  operation_key text NOT NULL,
  fingerprint text NOT NULL,
  outcome jsonb NOT NULL,
  PRIMARY KEY (mandate_id, operation_key)
);
CREATE TABLE IF NOT EXISTS shikigami.mandate_cycles (
  mandate_id text NOT NULL REFERENCES shikigami.mandates(mandate_id),
  cycle bigint NOT NULL CHECK (cycle > 0),
  state jsonb NOT NULL,
  PRIMARY KEY (mandate_id, cycle)
);
