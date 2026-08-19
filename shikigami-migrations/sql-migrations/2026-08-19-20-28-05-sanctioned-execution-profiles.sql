-- Migration: sanctioned-execution-profiles
-- Created: 2026-08-19-20-28-05 UTC
-- Write idempotent DDL (CREATE ... IF NOT EXISTS) so re-application is safe.

CREATE SCHEMA IF NOT EXISTS shikigami;

CREATE TABLE IF NOT EXISTS shikigami.sanctioned_execution_profiles (
    profile_id      TEXT        NOT NULL,
    version         TEXT        NOT NULL,
    issuer          TEXT        NOT NULL,
    lifecycle       TEXT        NOT NULL,
    valid_from      TIMESTAMPTZ NOT NULL,
    valid_until     TIMESTAMPTZ,
    profile_content JSONB       NOT NULL,
    profile_digest  TEXT        NOT NULL,
    created_at      TIMESTAMPTZ NOT NULL DEFAULT now(),
    PRIMARY KEY (profile_id, version),
    CONSTRAINT sanctioned_execution_profiles_lifecycle
      CHECK (lifecycle IN ('active', 'expired', 'withdrawn')),
    CONSTRAINT sanctioned_execution_profiles_content_identity
      CHECK (
        profile_content ->> 'profileId' = profile_id
        AND profile_content ->> 'version' = version
        AND profile_content ->> 'issuer' = issuer
        AND profile_content ->> 'lifecycle' = lifecycle
      )
);

COMMENT ON TABLE shikigami.sanctioned_execution_profiles IS
  'Immutable sanctioned execution profile revisions; resolution re-hashes profile_content before use.';
