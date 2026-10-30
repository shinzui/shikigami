-- Add sink delivery receipts

CREATE SCHEMA IF NOT EXISTS shikigami;

CREATE TABLE IF NOT EXISTS shikigami.sink_deliveries (
  receipt_key text PRIMARY KEY,
  outbox_message_id text NOT NULL,
  run_id text NOT NULL,
  agent text NOT NULL,
  ordinal integer NOT NULL CHECK (ordinal >= 0),
  sink_kind text NOT NULL,
  status text NOT NULL CHECK (
    status IN ('pending', 'attempting', 'delivered', 'failed', 'dead', 'unknown', 'conversation-started')
  ),
  detail text,
  updated_at timestamptz NOT NULL
);

CREATE INDEX IF NOT EXISTS sink_deliveries_outbox_message_id_idx
  ON shikigami.sink_deliveries (outbox_message_id);

CREATE INDEX IF NOT EXISTS sink_deliveries_run_id_idx
  ON shikigami.sink_deliveries (run_id, ordinal);
