CREATE TABLE shikigami.decision_runs (
  run_id text PRIMARY KEY,
  profile jsonb NOT NULL,
  started_at timestamptz NOT NULL DEFAULT clock_timestamp(),
  report jsonb
);

CREATE TABLE shikigami.decision_invocations (
  invocation_id text PRIMARY KEY,
  run_id text NOT NULL REFERENCES shikigami.decision_runs(run_id),
  binding jsonb NOT NULL,
  created_at timestamptz NOT NULL DEFAULT clock_timestamp()
);
CREATE INDEX decision_invocations_run ON shikigami.decision_invocations(run_id);

CREATE TABLE shikigami.decision_attempts (
  call_id text PRIMARY KEY,
  correlation_id text NOT NULL UNIQUE,
  run_id text NOT NULL REFERENCES shikigami.decision_runs(run_id),
  invocation_id text NOT NULL REFERENCES shikigami.decision_invocations(invocation_id),
  ordinal bigint NOT NULL CHECK (ordinal > 0),
  effective_model jsonb NOT NULL,
  terminal jsonb,
  facts jsonb,
  evidence jsonb,
  created_at timestamptz NOT NULL DEFAULT clock_timestamp(),
  finished_at timestamptz,
  UNIQUE (run_id, ordinal),
  CHECK ((terminal IS NULL) = (finished_at IS NULL)),
  CHECK (facts IS NULL OR evidence IS NOT NULL)
);
CREATE INDEX decision_attempts_invocation ON shikigami.decision_attempts(invocation_id, ordinal);
