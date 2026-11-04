-- Metadata only. Protected proposals and outputs stay with their owning stores.
CREATE TABLE shikigami.adaptive_observations (
  objective_id text NOT NULL REFERENCES shikigami.objectives(objective_id),
  operation_id text NOT NULL,
  kind text NOT NULL CHECK (kind IN ('refusal', 'terminal')),
  revision numeric NOT NULL CHECK (revision >= 0),
  status text NOT NULL,
  refusal text,
  PRIMARY KEY (objective_id, operation_id, kind)
);
