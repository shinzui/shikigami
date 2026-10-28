-- Execution resource rows are application-owned and survive workflow GC.
-- Each root is locked before its normalized operation, attempt and allocation rows.
CREATE TABLE IF NOT EXISTS shikigami.execution_roots (
  root_id text PRIMARY KEY CHECK (length(root_id) BETWEEN 1 AND 256),
  state jsonb NOT NULL
);
CREATE TABLE IF NOT EXISTS shikigami.execution_operations (
  root_id text NOT NULL REFERENCES shikigami.execution_roots(root_id),
  operation_id text NOT NULL CHECK (length(operation_id) BETWEEN 1 AND 256),
  request jsonb NOT NULL,
  PRIMARY KEY (root_id, operation_id)
);
CREATE TABLE IF NOT EXISTS shikigami.execution_attempts (
  root_id text NOT NULL REFERENCES shikigami.execution_roots(root_id),
  attempt_id text NOT NULL CHECK (length(attempt_id) BETWEEN 1 AND 256),
  state jsonb NOT NULL,
  PRIMARY KEY (root_id, attempt_id)
);
CREATE TABLE IF NOT EXISTS shikigami.execution_allocations (
  root_id text NOT NULL REFERENCES shikigami.execution_roots(root_id),
  allocation_id text NOT NULL CHECK (length(allocation_id) BETWEEN 1 AND 256),
  state jsonb NOT NULL,
  PRIMARY KEY (root_id, allocation_id)
);
ALTER TABLE shikigami.delegation_budgets
  ADD COLUMN IF NOT EXISTS execution_root_id text REFERENCES shikigami.execution_roots(root_id);
