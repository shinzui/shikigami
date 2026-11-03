CREATE TABLE IF NOT EXISTS shikigami.adaptive_decisions (
  objective_id text NOT NULL REFERENCES shikigami.objectives(objective_id),
  operation_id text NOT NULL,
  revision numeric NOT NULL CHECK (revision > 0),
  manifest jsonb NOT NULL,
  PRIMARY KEY (objective_id, operation_id),
  UNIQUE (objective_id, revision)
);
