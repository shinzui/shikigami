-- Publish allocation origin and accounting root in one transaction.
CREATE TABLE IF NOT EXISTS shikigami.execution_root_origins (
  workflow_id text PRIMARY KEY,
  root_id text NOT NULL UNIQUE REFERENCES shikigami.execution_roots(root_id) DEFERRABLE INITIALLY DEFERRED,
  binding jsonb NOT NULL
);
