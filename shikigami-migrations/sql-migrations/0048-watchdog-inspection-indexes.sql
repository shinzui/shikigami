-- Migration: watchdog-inspection-indexes
-- Claim-scoped latest completion/attempt and bounded operator keyset readers.
CREATE INDEX IF NOT EXISTS watchdog_claim_completed_sweeps
  ON shikigami.watchdog_sweeps(claim_key,completed_at DESC,sweep_id DESC)
  WHERE completed_at IS NOT NULL;
CREATE INDEX IF NOT EXISTS watchdog_claim_attempts
  ON shikigami.watchdog_sweeps(claim_key,opened_at DESC,sweep_id DESC);
CREATE INDEX IF NOT EXISTS watchdog_episode_inspection
  ON shikigami.watchdog_episodes(last_seen_sweep,episode_id);
CREATE INDEX IF NOT EXISTS watchdog_finding_inspection
  ON shikigami.watchdog_findings(episode_id,finding_id);
