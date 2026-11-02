-- Queue admission and local command receipts share the existing preserved
-- command target and operation primary key. Historical receipts remain intact.
ALTER TABLE shikigami.objective_tracker_commands ALTER COLUMN receipt DROP NOT NULL;
ALTER TABLE shikigami.objective_tracker_commands ADD COLUMN IF NOT EXISTS control jsonb;
ALTER TABLE shikigami.objective_tracker_commands ADD COLUMN IF NOT EXISTS control_actor jsonb;
ALTER TABLE shikigami.objective_tracker_commands ADD COLUMN IF NOT EXISTS pending boolean NOT NULL DEFAULT false;
CREATE INDEX IF NOT EXISTS objective_tracker_controls_pending
  ON shikigami.objective_tracker_commands(objective_id, operation_key) WHERE pending;
CREATE INDEX IF NOT EXISTS objective_tracker_observation_page
  ON shikigami.objective_tracker_observations(binding_id, (lpad(position::text,20,'0')));
CREATE INDEX IF NOT EXISTS objective_tracker_proposal_page
  ON shikigami.objective_tracker_proposals(binding_id, proposal_id);
CREATE INDEX IF NOT EXISTS objective_tracker_publication_page
  ON shikigami.objective_tracker_publications(binding_id, publication_id);
-- Historical observation times are unknown; do not invent them on upgrade.
ALTER TABLE shikigami.objective_tracker_observations ADD COLUMN IF NOT EXISTS observed_at timestamptz;
ALTER TABLE shikigami.objective_tracker_bindings ADD COLUMN IF NOT EXISTS last_observed_at timestamptz;

DO $migration$
BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_catalog.pg_constraint WHERE conname='objective_tracker_command_payload' AND conrelid='shikigami.objective_tracker_commands'::regclass) THEN
    ALTER TABLE shikigami.objective_tracker_commands ADD CONSTRAINT objective_tracker_command_payload
      CHECK ((receipt IS NOT NULL OR control IS NOT NULL) AND ((control IS NULL AND control_actor IS NULL AND NOT pending) OR (control IS NOT NULL AND control_actor IS NOT NULL)));
  END IF;
END
$migration$;
