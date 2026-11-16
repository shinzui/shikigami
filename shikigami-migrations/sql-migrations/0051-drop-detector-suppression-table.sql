-- Migration: drop-detector-suppression-table
-- Write idempotent DDL (CREATE ... IF NOT EXISTS) so re-application is safe.

-- Qualify every persistent object with its owning schema. Migration SQL may
-- not mutate search_path. Validate with: just migration-schema-isolation.

-- The detector suppression table of migration 0001 was keyed (detector,
-- subject, window) so a still-true condition would not re-raise a signal on
-- every evaluation tick. No runtime path ever read or wrote it: the
-- deterministic-rule behavior it served was never implemented and is removed
-- from the declaration schema (plan 131, M1). Durable inbox and output
-- idempotency handle delivery duplicates. Migration 0001 keeps its checksum;
-- this migration removes what it created.
DROP TABLE IF EXISTS shikigami.fired;
