-- Migration: sink-grants
-- Created: 2026-08-06-04-02-23 UTC
--
-- The C11 per-agent-per-sink grant table. One row per (agent, sink kind); a row
-- with granted = TRUE allows the sink, granted = FALSE records a revocation
-- (kept for audit), and no row at all denies. principal_id is reserved for the
-- verified meibo principal id that
-- docs/plans/23-agent-lifecycle-control-with-meibo-principals.md introduces, and
-- is nullable until then, so re-keying grants by verified identity later is a
-- column population rather than a table reshape.
--
-- Unlike the other migrations in this component, nothing here relies on the
-- pool's kiroku search_path: every object below is schema-qualified, because the
-- runtime reads this table over the event-store pool whose search_path is
-- kiroku.
CREATE SCHEMA IF NOT EXISTS shikigami;

CREATE TABLE IF NOT EXISTS shikigami.sink_grants (
  agent_name   TEXT        NOT NULL,
  principal_id TEXT        NULL,
  sink_kind    TEXT        NOT NULL
    CHECK (sink_kind IN ('KawaDigest','KizashiSignal','ReiAction','DanwaConversation','ChannelEgress')),
  granted      BOOLEAN     NOT NULL DEFAULT TRUE,
  granted_by   TEXT        NULL,
  granted_at   TIMESTAMPTZ NOT NULL DEFAULT now(),
  revoked_by   TEXT        NULL,
  revoked_at   TIMESTAMPTZ NULL,
  updated_at   TIMESTAMPTZ NOT NULL DEFAULT now(),
  PRIMARY KEY (agent_name, sink_kind)
);

-- The CHECK list is exactly what Shikigami.Sink.Permission.sinkKindText renders,
-- including ChannelEgress, which no sink variant produces yet:
-- docs/plans/32-channel-egress-sink-through-kanmon.md will, and a grant table
-- that rejected it would have to be migrated on that plan's first day.

-- Seed: the five agents from the compiled-in defaultGrantTable
-- (shikigami-core/src/Shikigami/Sink/Permission.hs), so applying this migration
-- preserves today's behavior exactly. Agents absent here — including every proof
-- agent under agents/proof/ — stay denied until granted at runtime.
INSERT INTO shikigami.sink_grants (agent_name, sink_kind, granted_by) VALUES
  ('heartbeat',         'KawaDigest',        'seed:defaultGrantTable'),
  ('heartbeat',         'KizashiSignal',     'seed:defaultGrantTable'),
  ('heartbeat',         'ReiAction',         'seed:defaultGrantTable'),
  ('heartbeat',         'DanwaConversation', 'seed:defaultGrantTable'),
  ('danwa-heartbeat',   'DanwaConversation', 'seed:defaultGrantTable'),
  ('triage-note',       'KizashiSignal',     'seed:defaultGrantTable'),
  ('triage-note',       'ReiAction',         'seed:defaultGrantTable'),
  ('stalled-intention', 'KizashiSignal',     'seed:defaultGrantTable'),
  ('at-risk-customer',  'KizashiSignal',     'seed:defaultGrantTable')
ON CONFLICT (agent_name, sink_kind) DO NOTHING;
