-- Allocation receipts outlive producing workflows and Kioku supersession.
CREATE TABLE IF NOT EXISTS shikigami.practice_review_identities (
  kind text NOT NULL CHECK (kind IN ('review', 'resolution')),
  owner_key text NOT NULL,
  request_key text NOT NULL,
  entity_id text NOT NULL UNIQUE,
  binding jsonb NOT NULL,
  PRIMARY KEY (kind, owner_key, request_key)
);
