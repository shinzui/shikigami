-- Workspace entities retain their original identity across follow-up/handoff.
-- The provider resource remains the stable technical origin locator. This
-- first-release migration expects fresh provisioning; it does not rewrite old
-- protected bindings or allocate replacement identities for populated rows.
ALTER TABLE shikigami.workspace_bindings
  ADD COLUMN workspace_id text NOT NULL,
  ADD CONSTRAINT workspace_entity_identity_unique UNIQUE (workspace_id),
  ADD CONSTRAINT workspace_entity_identity_matches_binding
    CHECK ((binding->>'id') IS NOT NULL AND binding->>'id' = workspace_id);
