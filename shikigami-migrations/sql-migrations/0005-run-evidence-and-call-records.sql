-- Migration: run-evidence-and-call-records
-- Created: 2026-08-20-01-53-56 UTC
--
-- The Keiro runEvidence stream is the lifecycle authority. These two tables
-- are the transactional operator projection: one row answers the run-level
-- status/verdict query and one row preserves each Baikai terminal call exactly
-- once under Shikigami's stable correlation id.

CREATE SCHEMA IF NOT EXISTS shikigami;

CREATE TABLE IF NOT EXISTS shikigami.run_evidence (
  run_id               TEXT        PRIMARY KEY,
  run_evidence_id      TEXT        NOT NULL UNIQUE,
  status               TEXT        NOT NULL,
  verdict              TEXT,
  reasons              JSONB       NOT NULL DEFAULT '[]'::jsonb,
  binding              JSONB       NOT NULL,
  observations         JSONB       NOT NULL DEFAULT '{}'::jsonb,
  expected_call_count  INTEGER     NOT NULL DEFAULT 0,
  recorded_call_count  INTEGER     NOT NULL DEFAULT 0,
  created_at           TIMESTAMPTZ NOT NULL DEFAULT now(),
  updated_at           TIMESTAMPTZ NOT NULL DEFAULT now(),
  CONSTRAINT run_evidence_status
    CHECK (status IN (
      'requested',
      'profile-resolved',
      'running',
      'evidence-sealed',
      'attested',
      'non-conforming',
      'incomplete',
      'failed'
    )),
  CONSTRAINT run_evidence_verdict
    CHECK (verdict IS NULL OR verdict IN (
      'sanctioned',
      'not-sanctioned',
      'incomplete',
      'failed'
    )),
  CONSTRAINT run_evidence_counts
    CHECK (expected_call_count >= 0 AND recorded_call_count >= 0)
);

CREATE INDEX IF NOT EXISTS run_evidence_status_verdict_idx
  ON shikigami.run_evidence (status, verdict);

CREATE TABLE IF NOT EXISTS shikigami.run_evidence_calls (
  run_id             TEXT        NOT NULL,
  call_id            TEXT        NOT NULL,
  source_run_id      TEXT        NOT NULL,
  relationship       TEXT        NOT NULL,
  related_call_id    TEXT,
  resolved_model_id  TEXT        NOT NULL,
  requested_alias    TEXT,
  baikai_call_id     TEXT        NOT NULL,
  attempt             BIGINT      NOT NULL,
  call_status         TEXT        NOT NULL,
  evidence_strength   TEXT        NOT NULL,
  evidence            JSONB       NOT NULL,
  created_at          TIMESTAMPTZ NOT NULL DEFAULT now(),
  updated_at          TIMESTAMPTZ NOT NULL DEFAULT now(),
  PRIMARY KEY (run_id, call_id),
  FOREIGN KEY (run_id) REFERENCES shikigami.run_evidence (run_id),
  CONSTRAINT run_evidence_calls_relationship
    CHECK (relationship IN ('root', 'retry', 'fallback', 'continuation', 'child')),
  CONSTRAINT run_evidence_calls_attempt CHECK (attempt > 0)
);

CREATE INDEX IF NOT EXISTS run_evidence_calls_source_run_idx
  ON shikigami.run_evidence_calls (source_run_id);

CREATE INDEX IF NOT EXISTS run_evidence_calls_baikai_call_idx
  ON shikigami.run_evidence_calls (baikai_call_id);

COMMENT ON TABLE shikigami.run_evidence IS
  'Transactional operator projection of the event-sourced runEvidence aggregate.';

COMMENT ON TABLE shikigami.run_evidence_calls IS
  'Baikai terminal call evidence keyed by owning run and stable Shikigami call correlation id.';
