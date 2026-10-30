-- The HTTP boundary's durable acceptance facts, committed with queue delivery.
CREATE SCHEMA IF NOT EXISTS shikigami;
CREATE TABLE IF NOT EXISTS shikigami.agent_run_requests (
  agent_name text NOT NULL,
  idempotency_key text NOT NULL,
  run_id text NOT NULL,
  run_key text NOT NULL,
  payload_fingerprint text NOT NULL,
  requested_by text NOT NULL,
  queue_message_id bigint NOT NULL,
  accepted_at timestamptz NOT NULL DEFAULT now(),
  PRIMARY KEY (agent_name, idempotency_key),
  UNIQUE (agent_name, run_id),
  UNIQUE (run_key)
);
CREATE INDEX IF NOT EXISTS agent_run_requests_agent_accepted_idx
  ON shikigami.agent_run_requests (agent_name, accepted_at DESC, run_id);
