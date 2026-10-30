-- Persist agent load state and lifecycle admission skips

CREATE SCHEMA IF NOT EXISTS shikigami;

CREATE TABLE shikigami.agent_load_state (
  manifest_path text PRIMARY KEY,
  manifest_directory text NOT NULL,
  agent_name text,
  principal_id text,
  status text NOT NULL CHECK (status IN ('loaded', 'failed')),
  enabled boolean,
  error text,
  observed_at timestamptz NOT NULL,
  CONSTRAINT agent_load_state_shape CHECK (
    (status = 'loaded'
      AND agent_name IS NOT NULL
      AND enabled IS NOT NULL
      AND error IS NULL)
    OR
    (status = 'failed'
      AND agent_name IS NULL
      AND principal_id IS NULL
      AND enabled IS NULL
      AND error IS NOT NULL)
  )
);

CREATE INDEX agent_load_state_manifest_directory_idx
  ON shikigami.agent_load_state (manifest_directory);

CREATE INDEX agent_load_state_agent_name_idx
  ON shikigami.agent_load_state (agent_name)
  WHERE agent_name IS NOT NULL;

CREATE TABLE shikigami.run_skips (
  run_skip_id bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  agent_name text NOT NULL,
  principal_id text,
  stage text NOT NULL CHECK (stage IN ('trigger', 'drain')),
  detail text NOT NULL,
  reason text NOT NULL,
  idempotency_key text NOT NULL,
  occurred_at timestamptz NOT NULL DEFAULT now(),
  UNIQUE (stage, idempotency_key)
);

CREATE INDEX run_skips_agent_occurred_at_idx
  ON shikigami.run_skips (agent_name, occurred_at DESC);
