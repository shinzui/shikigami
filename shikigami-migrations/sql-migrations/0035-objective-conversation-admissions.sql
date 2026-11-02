-- Migration: objective-conversation-admissions
-- Write idempotent DDL (CREATE ... IF NOT EXISTS) so re-application is safe.

-- Qualify every persistent object with its owning schema. Migration SQL may
-- not mutate search_path. Validate with: just migration-schema-isolation.
CREATE TABLE IF NOT EXISTS shikigami.objective_turn_admissions (
  run_id text NOT NULL,
  turn_id text NOT NULL,
  principal_key text NOT NULL,
  objective_id text REFERENCES shikigami.objectives(objective_id),
  admission jsonb NOT NULL,
  PRIMARY KEY (run_id, turn_id, principal_key)
);
