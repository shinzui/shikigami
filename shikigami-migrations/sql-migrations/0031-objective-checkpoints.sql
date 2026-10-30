-- Retained objective data is independent of workflow journal collection.
CREATE TABLE IF NOT EXISTS shikigami.objectives (
  objective_id text PRIMARY KEY,
  state jsonb NOT NULL,
  updated_at timestamptz NOT NULL DEFAULT clock_timestamp()
);
CREATE TABLE IF NOT EXISTS shikigami.objective_assignments (
  objective_id text NOT NULL REFERENCES shikigami.objectives(objective_id),
  assignment_id text NOT NULL,
  reference_key text NOT NULL UNIQUE,
  state jsonb NOT NULL,
  PRIMARY KEY (objective_id, assignment_id)
);
CREATE TABLE IF NOT EXISTS shikigami.objective_payloads (
  objective_id text NOT NULL REFERENCES shikigami.objectives(objective_id),
  digest text NOT NULL,
  payload jsonb NOT NULL,
  PRIMARY KEY (objective_id, digest)
);
-- Both accepted and definitive rejected outcomes are immutable.
CREATE TABLE IF NOT EXISTS shikigami.objective_receipts (
  objective_id text NOT NULL REFERENCES shikigami.objectives(objective_id),
  operation_key text NOT NULL,
  fingerprint text NOT NULL,
  outcome jsonb NOT NULL,
  PRIMARY KEY (objective_id, operation_key)
);
CREATE TABLE IF NOT EXISTS shikigami.objective_origins (
  creator_key text NOT NULL,
  operation_key text NOT NULL,
  objective_id text NOT NULL UNIQUE REFERENCES shikigami.objectives(objective_id),
  fingerprint text NOT NULL,
  origin jsonb NOT NULL,
  receipt jsonb NOT NULL,
  PRIMARY KEY (creator_key, operation_key)
);
CREATE TABLE IF NOT EXISTS shikigami.objective_associations (
  kind text NOT NULL,
  source_id text NOT NULL,
  objective_id text NOT NULL REFERENCES shikigami.objectives(objective_id),
  binding jsonb NOT NULL,
  PRIMARY KEY (kind, source_id, objective_id)
);
CREATE TABLE IF NOT EXISTS shikigami.objective_scopes (
  fingerprint text PRIMARY KEY,
  objective_id text NOT NULL REFERENCES shikigami.objectives(objective_id),
  scope jsonb NOT NULL
);
CREATE TABLE IF NOT EXISTS shikigami.objective_cursors (
  objective_id text NOT NULL REFERENCES shikigami.objectives(objective_id),
  assignment_id text NOT NULL,
  session_id text NOT NULL,
  cursor bigint NOT NULL CHECK (cursor >= 0),
  PRIMARY KEY (objective_id, assignment_id, session_id),
  FOREIGN KEY (objective_id, assignment_id) REFERENCES shikigami.objective_assignments(objective_id, assignment_id)
);
