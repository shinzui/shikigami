-- Migration: execution-instance-liveness
-- A process that claims accepted attempts enrolls an instance and holds a
-- session advisory lock on it for its whole life (ADR 0132). PostgreSQL frees
-- that lock when the process's session ends, so a free lock is the factual stop
-- acknowledgement that lets capacity admission reclaim the instance's permits.
CREATE TABLE IF NOT EXISTS shikigami.execution_instances (
  instance_id integer GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  started_at timestamptz NOT NULL DEFAULT now()
);

-- The instance under which an active permit was granted. Permits granted
-- before this migration, and in-process claims, carry none and are released
-- only by settlement, as before.
ALTER TABLE shikigami.execution_capacity_tickets
  ADD COLUMN IF NOT EXISTS instance_id integer REFERENCES shikigami.execution_instances(instance_id);
CREATE INDEX IF NOT EXISTS execution_capacity_active_instances
  ON shikigami.execution_capacity_tickets(instance_id) WHERE phase='active' AND instance_id IS NOT NULL;
