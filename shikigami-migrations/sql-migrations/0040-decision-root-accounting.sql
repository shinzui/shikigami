-- Actual typed decision calls retain the existing selection/root receipt.
-- Deferred FK permits root-before-decision-run lock ordering in one transaction.
CREATE TABLE shikigami.decision_resource_calls (
  call_id text PRIMARY KEY,
  preparation_id text NOT NULL,
  receipt jsonb NOT NULL,
  FOREIGN KEY (call_id) REFERENCES shikigami.decision_attempts(call_id) DEFERRABLE INITIALLY DEFERRED
);
