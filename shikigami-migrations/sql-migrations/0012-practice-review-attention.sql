CREATE TABLE IF NOT EXISTS shikigami.practice_review_attention (
  attention_key text PRIMARY KEY,
  schema_version integer NOT NULL,
  target_project text NOT NULL,
  practice_key text NOT NULL,
  classification text NOT NULL,
  owner_role text NOT NULL,
  recipient text NOT NULL,
  originating_review_id text NOT NULL,
  claim_evidence_digest text NOT NULL,
  outbox_message_id text NOT NULL UNIQUE,
  created_at timestamptz NOT NULL
);

CREATE TABLE IF NOT EXISTS shikigami.practice_review_attention_reviews (
  attention_key text NOT NULL REFERENCES shikigami.practice_review_attention(attention_key),
  review_id text NOT NULL,
  linked_at timestamptz NOT NULL,
  PRIMARY KEY (attention_key, review_id)
);
