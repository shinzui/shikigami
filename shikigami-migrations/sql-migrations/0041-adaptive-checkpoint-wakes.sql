CREATE TABLE shikigami.adaptive_checkpoint_listeners (
  objective_id text NOT NULL REFERENCES shikigami.objectives(objective_id),
  owner_name text NOT NULL,
  owner_id text NOT NULL,
  generation integer NOT NULL CHECK (generation >= 0),
  listener jsonb NOT NULL,
  PRIMARY KEY (objective_id, owner_name, owner_id)
);
