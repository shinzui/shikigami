-- Bounded ledger of observed activity and unrequested proposals. No body text is
-- stored: an assessment's evidence carries coordinates and digests only.
CREATE TABLE shikigami.initiative_observers (
  observer text PRIMARY KEY
);
CREATE TABLE shikigami.initiative_candidates (
  observer text NOT NULL,
  activity_id text NOT NULL,
  source text,
  subject_kind text,
  subject_id text,
  verdict text NOT NULL CHECK (verdict IN ('skipped', 'evaluating', 'proposed', 'not-actionable')),
  skip_reason text,
  proposal_id text,
  run_workflow_id text,
  recorded_at timestamptz NOT NULL,
  evaluated_at timestamptz,
  PRIMARY KEY (observer, activity_id)
);
CREATE INDEX initiative_candidates_window ON shikigami.initiative_candidates (observer, recorded_at);
CREATE INDEX initiative_candidates_evaluated ON shikigami.initiative_candidates (observer, evaluated_at);
CREATE TABLE shikigami.initiative_proposals (
  proposal_id text PRIMARY KEY,
  proposal_key text NOT NULL,
  observer text NOT NULL,
  source text NOT NULL,
  subject_kind text NOT NULL,
  subject_id text NOT NULL,
  assessment jsonb NOT NULL,
  requested jsonb NOT NULL,
  status text NOT NULL,
  status_detail jsonb NOT NULL,
  proposed_at timestamptz NOT NULL,
  expires_at timestamptz NOT NULL,
  resolved_at timestamptz,
  suppressed_until timestamptz,
  notified_at timestamptz,
  revision numeric NOT NULL CHECK (revision >= 0),
  run_workflow_id text NOT NULL
);
CREATE UNIQUE INDEX initiative_proposals_pending_key ON shikigami.initiative_proposals (proposal_key) WHERE status = 'pending';
CREATE INDEX initiative_proposals_key ON shikigami.initiative_proposals (proposal_key, proposed_at);
CREATE INDEX initiative_proposals_window ON shikigami.initiative_proposals (observer, proposed_at);
CREATE INDEX initiative_proposals_notified ON shikigami.initiative_proposals (observer, notified_at);
