-- Revocable standing policies and the receipts pinned to their exact digests.
-- A changed policy is a new row and a revocation of the old one.
CREATE TABLE shikigami.initiative_standing_policies (
  policy_id text PRIMARY KEY,
  principal text NOT NULL,
  policy jsonb NOT NULL,
  digest text NOT NULL,
  installed_by text NOT NULL,
  installed_at timestamptz NOT NULL,
  expires_at timestamptz NOT NULL,
  revoked_by text,
  revoked_at timestamptz,
  revision numeric NOT NULL CHECK (revision >= 0)
);
CREATE INDEX initiative_standing_policies_principal ON shikigami.initiative_standing_policies (principal, expires_at);
CREATE TABLE shikigami.initiative_admissions (
  proposal_id text PRIMARY KEY REFERENCES shikigami.initiative_proposals(proposal_id),
  policy_id text NOT NULL REFERENCES shikigami.initiative_standing_policies(policy_id),
  policy_digest text NOT NULL,
  reserved jsonb NOT NULL,
  stage text NOT NULL CHECK (stage IN ('reserved', 'created', 'funded', 'staffed', 'launched', 'refused')),
  objective_id text,
  root_id text,
  coordinator_workflow_id text,
  refusal text,
  reserved_at timestamptz NOT NULL,
  updated_at timestamptz NOT NULL
);
CREATE INDEX initiative_admissions_policy_window ON shikigami.initiative_admissions (policy_id, reserved_at);
