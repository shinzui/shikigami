-- Migration: agent-principal-state
-- Created: 2026-08-26-18-20-00 UTC
--
-- Shikigami owns only the alias metadata. Kioku memories remain append-only in
-- Kioku's schema and are read through Kioku's public recall API.
CREATE TABLE shikigami.agent_scope_aliases (
  principal_id     TEXT        NOT NULL CHECK (principal_id LIKE 'agent\_%' ESCAPE '\'),
  legacy_agent_name TEXT       NOT NULL CHECK (btrim(legacy_agent_name) <> ''),
  created_at       TIMESTAMPTZ NOT NULL DEFAULT now(),
  updated_at       TIMESTAMPTZ NOT NULL DEFAULT now(),
  PRIMARY KEY (principal_id, legacy_agent_name),
  UNIQUE (legacy_agent_name)
);

-- A verified grant is owned by the stable principal. A compatibility grant is
-- deliberately name-keyed and is considered only in directory-disabled mode.
ALTER TABLE shikigami.sink_grants
  DROP CONSTRAINT sink_grants_pkey;

CREATE UNIQUE INDEX sink_grants_verified_identity_key
  ON shikigami.sink_grants (principal_id, sink_kind)
  WHERE principal_id IS NOT NULL;

CREATE UNIQUE INDEX sink_grants_compatibility_identity_key
  ON shikigami.sink_grants (agent_name, sink_kind)
  WHERE principal_id IS NULL;

CREATE INDEX sink_grants_agent_name_idx
  ON shikigami.sink_grants (agent_name, sink_kind);
