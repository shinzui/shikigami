-- Terminal queue disposition for HTTP requests that never opened a workflow.
ALTER TABLE shikigami.agent_run_requests
  ADD COLUMN IF NOT EXISTS disposition text NOT NULL DEFAULT 'accepted'
    CHECK (disposition IN ('accepted', 'dead_lettered')),
  ADD COLUMN IF NOT EXISTS disposition_detail text,
  ADD COLUMN IF NOT EXISTS disposition_at timestamptz;
