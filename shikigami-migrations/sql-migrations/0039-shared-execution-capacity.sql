-- One database-wide admission owner spans worker replicas and operation kinds.
CREATE TABLE IF NOT EXISTS shikigami.execution_capacity (
  singleton boolean PRIMARY KEY DEFAULT true CHECK (singleton),
  maximum integer NOT NULL CHECK (maximum BETWEEN 1 AND 128),
  revision bigint NOT NULL DEFAULT 0 CHECK (revision >= 0),
  turn bigint NOT NULL DEFAULT 0 CHECK (turn >= 0)
);
INSERT INTO shikigami.execution_capacity(singleton,maximum) VALUES (true,1)
  ON CONFLICT (singleton) DO NOTHING;
CREATE TABLE IF NOT EXISTS shikigami.execution_capacity_roots (
  root_key text PRIMARY KEY,
  last_turn bigint NOT NULL DEFAULT 0 CHECK (last_turn >= 0)
);
CREATE TABLE IF NOT EXISTS shikigami.execution_capacity_tickets (
  ticket_key text PRIMARY KEY,
  root_key text NOT NULL REFERENCES shikigami.execution_capacity_roots(root_key),
  sequence bigint GENERATED ALWAYS AS IDENTITY UNIQUE,
  phase text NOT NULL DEFAULT 'waiting' CHECK (phase IN ('waiting','active','settled')),
  owner text,
  CHECK ((phase='active') = (owner IS NOT NULL))
);
CREATE INDEX IF NOT EXISTS execution_capacity_waiting ON shikigami.execution_capacity_tickets(root_key,sequence) WHERE phase='waiting';

-- Enroll retained work conservatively. Expired claims and unknown transports
-- do not become free capacity during rollout; their existing owner reconciles
-- them. The application validates the complete attempt envelope before action.
INSERT INTO shikigami.execution_capacity_roots(root_key)
SELECT DISTINCT COALESCE(e.binding->>'rootId','execution:' || e.execution_id)
FROM shikigami.executions e
JOIN shikigami.execution_transcript_operations o USING(execution_id)
CROSS JOIN LATERAL jsonb_each(o.dispatches) a
WHERE a.value->>'phase' IN ('AwaitingDispatch','Claimed','DispatchStarted','AttemptUncertain','AttemptSuperseded')
ON CONFLICT(root_key) DO NOTHING;
INSERT INTO shikigami.execution_capacity_tickets(ticket_key,root_key,phase,owner)
SELECT 'attempt:' || a.key,
       COALESCE(e.binding->>'rootId','execution:' || e.execution_id),
       CASE WHEN a.value->>'phase'='AwaitingDispatch' THEN 'waiting' ELSE 'active' END,
       CASE WHEN a.value->>'phase'='AwaitingDispatch' THEN NULL ELSE a.value->>'owner' END
FROM shikigami.executions e
JOIN shikigami.execution_transcript_operations o USING(execution_id)
CROSS JOIN LATERAL jsonb_each(o.dispatches) a
WHERE a.value->>'phase' IN ('AwaitingDispatch','Claimed','DispatchStarted','AttemptUncertain','AttemptSuperseded')
ON CONFLICT(ticket_key) DO NOTHING;

-- Objective graph admission must find sessions even before their first result
-- projects a session reference into the objective assignment.
CREATE INDEX IF NOT EXISTS worker_sessions_objective_reference
  ON shikigami.worker_sessions ((binding->'objective'));
