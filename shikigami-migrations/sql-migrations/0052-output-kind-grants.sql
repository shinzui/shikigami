-- Migration: output-kind-grants
-- Write idempotent DDL (CREATE ... IF NOT EXISTS) so re-application is safe.

-- Qualify every persistent object with its owning schema. Migration SQL may
-- not mutate search_path. Validate with: just migration-schema-isolation.

-- C11 grants and delivery receipts are keyed by output kind (plan 135, M3).
-- The five Kikan sinks became the output kinds kawa.digest, kizashi.signal,
-- rei.action, danwa.conversation and channel.egress, delivered by adapters a
-- composition registers. The grant table's CHECK pinned the five legacy
-- names; an output kind is an open, checked dotted name owned by its
-- adapter, so the constraint becomes the kind's shape and the stored values
-- are renamed. Re-running is a no-op: renamed rows no longer match.
ALTER TABLE shikigami.sink_grants DROP CONSTRAINT IF EXISTS sink_grants_sink_kind_check;

UPDATE shikigami.sink_grants
SET sink_kind = CASE sink_kind
  WHEN 'KawaDigest' THEN 'kawa.digest'
  WHEN 'KizashiSignal' THEN 'kizashi.signal'
  WHEN 'ReiAction' THEN 'rei.action'
  WHEN 'DanwaConversation' THEN 'danwa.conversation'
  WHEN 'ChannelEgress' THEN 'channel.egress'
END
WHERE sink_kind IN ('KawaDigest', 'KizashiSignal', 'ReiAction', 'DanwaConversation', 'ChannelEgress');

ALTER TABLE shikigami.sink_grants DROP CONSTRAINT IF EXISTS sink_grants_output_kind_check;
ALTER TABLE shikigami.sink_grants
  ADD CONSTRAINT sink_grants_output_kind_check
  CHECK (sink_kind ~ '^[a-z][a-z0-9-]*(\.[a-z][a-z0-9-]*)+$' AND length(sink_kind) <= 64);

UPDATE shikigami.sink_deliveries
SET sink_kind = CASE sink_kind
  WHEN 'KawaDigest' THEN 'kawa.digest'
  WHEN 'KizashiSignal' THEN 'kizashi.signal'
  WHEN 'ReiAction' THEN 'rei.action'
  WHEN 'DanwaConversation' THEN 'danwa.conversation'
  WHEN 'ChannelEgress' THEN 'channel.egress'
END
WHERE sink_kind IN ('KawaDigest', 'KizashiSignal', 'ReiAction', 'DanwaConversation', 'ChannelEgress');
