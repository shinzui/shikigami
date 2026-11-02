-- Protected synchronization records. Connection credentials are never stored.
CREATE TABLE IF NOT EXISTS shikigami.objective_tracker_bindings (
  binding_id text PRIMARY KEY,
  objective_id text NOT NULL REFERENCES shikigami.objectives(objective_id),
  connection_id text NOT NULL,
  incarnation text NOT NULL,
  resource_id text NOT NULL,
  active boolean NOT NULL,
  state jsonb NOT NULL
);
CREATE UNIQUE INDEX IF NOT EXISTS objective_tracker_resource_active
  ON shikigami.objective_tracker_bindings(connection_id, incarnation, resource_id) WHERE active;
CREATE INDEX IF NOT EXISTS objective_tracker_by_objective
  ON shikigami.objective_tracker_bindings(objective_id, binding_id);
CREATE TABLE IF NOT EXISTS shikigami.objective_tracker_observations (
  observation_key text PRIMARY KEY,
  position bigint GENERATED ALWAYS AS IDENTITY UNIQUE,
  binding_id text NOT NULL REFERENCES shikigami.objective_tracker_bindings(binding_id),
  disposition text NOT NULL,
  observation jsonb NOT NULL
);
CREATE TABLE IF NOT EXISTS shikigami.objective_tracker_proposals (
  proposal_id text PRIMARY KEY,
  binding_id text NOT NULL REFERENCES shikigami.objective_tracker_bindings(binding_id),
  state jsonb NOT NULL
);
CREATE TABLE IF NOT EXISTS shikigami.objective_tracker_commands (
  objective_id text NOT NULL REFERENCES shikigami.objectives(objective_id),
  operation_key text NOT NULL,
  fingerprint text NOT NULL,
  receipt jsonb NOT NULL,
  PRIMARY KEY(objective_id, operation_key)
);
CREATE TABLE IF NOT EXISTS shikigami.objective_tracker_publications (
  publication_id text PRIMARY KEY,
  binding_id text NOT NULL REFERENCES shikigami.objective_tracker_bindings(binding_id),
  objective_revision bigint NOT NULL CHECK (objective_revision >= 0),
  intent jsonb NOT NULL,
  receipt_state text NOT NULL CHECK (receipt_state IN ('Pending','Attempting','Delivered','Rejected','Conflict','Unknown','Suppressed')),
  receipt jsonb NOT NULL
);
CREATE INDEX IF NOT EXISTS objective_tracker_publication_order
  ON shikigami.objective_tracker_publications(binding_id, objective_revision, publication_id);
CREATE TABLE IF NOT EXISTS shikigami.objective_tracker_attempts (
  attempt_id text PRIMARY KEY,
  publication_id text NOT NULL REFERENCES shikigami.objective_tracker_publications(publication_id),
  attempt jsonb NOT NULL
);
CREATE TABLE IF NOT EXISTS shikigami.objective_tracker_verifications (
  verification_key text PRIMARY KEY,
  publication_id text NOT NULL REFERENCES shikigami.objective_tracker_publications(publication_id),
  evidence jsonb NOT NULL
);
