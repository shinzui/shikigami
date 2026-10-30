-- Migration: shikigami-fired
-- shikigami stores agent RUNS as kioku Sessions (kioku_sessions), so there is NO
-- bespoke agent_runs table. The only shikigami-owned table is the detector
-- suppression table below, keyed (detector, subject, window) so a still-true
-- condition does not re-raise a signal on every evaluation tick.

CREATE SCHEMA IF NOT EXISTS shikigami;

CREATE TABLE IF NOT EXISTS shikigami.fired (
  detector     TEXT        NOT NULL,
  subject_type TEXT        NOT NULL,
  subject_id   TEXT        NOT NULL,
  window_key   TEXT        NOT NULL,
  signal_id    TEXT        NOT NULL,
  fired_at     TIMESTAMPTZ NOT NULL DEFAULT now(),
  PRIMARY KEY (detector, subject_type, subject_id, window_key)
);
