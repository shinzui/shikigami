-- Migration: watchdog-ledger
-- Qualify persistent objects; never mutate search_path.
-- Metadata and references only. Native workflow coordinates retain each claim.
CREATE TABLE IF NOT EXISTS shikigami.watchdog_claims (
  claim_key text PRIMARY KEY,
  principal jsonb NOT NULL,
  scope jsonb NOT NULL,
  active_sweep text
);
CREATE TABLE IF NOT EXISTS shikigami.watchdog_sweeps (
  sweep_id text PRIMARY KEY,
  workflow_name text NOT NULL,
  workflow_id text NOT NULL,
  origin jsonb NOT NULL,
  grant_snapshot jsonb NOT NULL,
  claim_key text NOT NULL REFERENCES shikigami.watchdog_claims(claim_key),
  due_at timestamptz NOT NULL,
  opened_at timestamptz NOT NULL DEFAULT clock_timestamp(),
  completed_at timestamptz,
  summary jsonb,
  UNIQUE(workflow_name, workflow_id)
);
CREATE INDEX IF NOT EXISTS watchdog_completed_sweeps
  ON shikigami.watchdog_sweeps(completed_at DESC) WHERE completed_at IS NOT NULL;
CREATE TABLE IF NOT EXISTS shikigami.watchdog_marks (
  subject_key text PRIMARY KEY,
  subject jsonb NOT NULL,
  objective_id text,
  mark_digest text NOT NULL,
  mark jsonb NOT NULL,
  first_seen_at timestamptz NOT NULL,
  last_changed_at timestamptz NOT NULL,
  last_seen_at timestamptz NOT NULL,
  last_seen_sweep text NOT NULL REFERENCES shikigami.watchdog_sweeps(sweep_id)
);
CREATE TABLE IF NOT EXISTS shikigami.watchdog_episodes (
  episode_id text PRIMARY KEY,
  subject_key text NOT NULL,
  subject jsonb NOT NULL,
  objective_id text,
  kind text NOT NULL,
  family text NOT NULL CHECK (family IN ('liveness','drift')),
  opened_at timestamptz NOT NULL,
  opened_sweep text NOT NULL REFERENCES shikigami.watchdog_sweeps(sweep_id),
  closed_at timestamptz,
  closed_reason text,
  last_summary_digest text NOT NULL,
  last_seen_sweep text NOT NULL REFERENCES shikigami.watchdog_sweeps(sweep_id),
  notified_count integer NOT NULL CHECK (notified_count >= 1)
);
CREATE UNIQUE INDEX IF NOT EXISTS watchdog_open_episodes
  ON shikigami.watchdog_episodes(subject_key,kind) WHERE closed_at IS NULL;
CREATE TABLE IF NOT EXISTS shikigami.watchdog_findings (
  finding_id text PRIMARY KEY,
  episode_id text NOT NULL REFERENCES shikigami.watchdog_episodes(episode_id),
  sweep_id text NOT NULL REFERENCES shikigami.watchdog_sweeps(sweep_id),
  recorded_at timestamptz NOT NULL,
  finding jsonb NOT NULL,
  UNIQUE(episode_id,sweep_id)
);
CREATE TABLE IF NOT EXISTS shikigami.watchdog_coverage (
  claim_key text PRIMARY KEY REFERENCES shikigami.watchdog_claims(claim_key),
  cursor jsonb NOT NULL,
  pass_started_at timestamptz NOT NULL,
  last_pass_completed_at timestamptz
);
CREATE TABLE IF NOT EXISTS shikigami.watchdog_receipts (
  sweep_id text NOT NULL REFERENCES shikigami.watchdog_sweeps(sweep_id),
  operation text NOT NULL,
  input_digest text NOT NULL,
  outcome jsonb NOT NULL,
  PRIMARY KEY(sweep_id,operation)
);
