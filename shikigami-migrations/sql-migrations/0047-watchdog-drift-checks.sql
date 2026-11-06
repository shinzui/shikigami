-- Migration: watchdog-drift-checks
-- Metadata only. The drift slice has no dependency on the episode ledger.
CREATE TABLE IF NOT EXISTS shikigami.watchdog_drift_checks (
  subject_key text PRIMARY KEY,
  subject jsonb NOT NULL,
  objective_id text NOT NULL,
  checked_at timestamptz NOT NULL,
  mark_digest text NOT NULL,
  category text NOT NULL CHECK (category IN ('within-scope','possible-drift','outside-scope')),
  sweep_id text NOT NULL
);
CREATE TABLE IF NOT EXISTS shikigami.watchdog_drift_receipts (
  sweep_id text PRIMARY KEY,
  input_digest text NOT NULL
);
