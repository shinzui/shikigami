-- Root-run-wide delegation budgets and idempotent child reservations.

CREATE SCHEMA IF NOT EXISTS shikigami;

CREATE TABLE IF NOT EXISTS shikigami.delegation_budgets (
  budget_id text PRIMARY KEY,
  root_workflow_id text UNIQUE NOT NULL,
  maximum integer NOT NULL CHECK (maximum BETWEEN 0 AND 1000),
  consumed integer NOT NULL DEFAULT 0 CHECK (consumed >= 0 AND consumed <= maximum),
  created_at timestamptz NOT NULL,
  updated_at timestamptz NOT NULL
);

CREATE TABLE IF NOT EXISTS shikigami.delegation_reservations (
  budget_id text NOT NULL REFERENCES shikigami.delegation_budgets (budget_id) ON DELETE CASCADE,
  child_workflow_id text NOT NULL,
  reserved_at timestamptz NOT NULL,
  PRIMARY KEY (budget_id, child_workflow_id)
);

CREATE INDEX IF NOT EXISTS delegation_reservations_child_workflow_id_idx
  ON shikigami.delegation_reservations (child_workflow_id);
