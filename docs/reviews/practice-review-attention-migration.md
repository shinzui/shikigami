---
type: Review
title: Practice-review attention migration
description: The additive migration creates exactly the two logical tables ADR 0035 specifies, carries no delivery state, and applies twice cleanly; it lacks only an index for the audit query that walks from a review id to its reservation.
generated:
  by: process:claude-code
  at: "2026-08-27T00:12:00Z"
reviewId: REV-3
subject: mori://shinzui/shikigami
subjectKind: migration
component: 2026-08-26-20-30-00-practice-review-attention.sql
reviewedSha: 62861267b8e4994ad15e7083ca0eb6b9a5dc2999
coverage: full
reviewedAt: "2026-08-27T00:12:00Z"
reviewerKind: model
reviewer: process:claude-code
provider: anthropic
model: claude-fable-5
effort: high
outcome: approved
dimensions:
  - correctness
  - operability
  - design
context: >-
  Read the migration, its manifest entry, the contract test that inspects the
  embedded DDL, the sink_deliveries migration it joins against, and every
  statement in Shikigami.PracticeReview.Attention that touches the tables;
  ran the migration contract and fresh/apply-again smoke suites as part of
  the full suite at the reviewed commit.
---

# Practice-review attention migration

## Verdict

Approved. The file creates `shikigami.practice_review_attention` keyed by the
semantic attention key with a unique `outbox_message_id`, and
`shikigami.practice_review_attention_reviews` keyed by `(attention_key,
review_id)` with a foreign key to the reservation. Both statements are
`CREATE TABLE IF NOT EXISTS`, schema-qualified, and free of the status,
signal-id, error, retry, and delivered-at columns that ADR 0022 and ADR 0035
forbid. The manifest appends it last, which pg-migrate treats as the
authoritative order. The columns the code writes match the DDL one for one,
and the operator query in the user guide joins on a column that exists on both
sides.

## Follow-ups that do not block

- `practice_review_attention_reviews` has no index on `review_id`. The
  guide's audit question "which reservation did review X coalesce into" scans
  the association table; add `(review_id)` when the table is expected to
  grow beyond a few thousand rows.
- `schema_version` is written as `1` and never read. Keep it, since the ADR
  says a projection change is a new version, but nothing yet refuses a row of
  another version.
- The file omits the `SET search_path` preamble the `just new-migration`
  template emits. That is correct here because every name is qualified, but
  a future edit that adds an unqualified statement would land in whatever
  schema the component's connection defaults to.

## Evidence

- `shikigami-migrations/sql-migrations/2026-08-26-20-30-00-practice-review-attention.sql`
  and its manifest line; `shikigami-migrations/test/Main.hs` lines 55-62
  assert both table names are present and `delivery_status` is absent.
- Migration contract suite: 5 tests passed; fresh and apply-again smoke
  suite: 2 tests passed, both in the full serialized run at the reviewed
  commit.
- `2026-08-21-15-13-00-sink-deliveries.sql` lines 5-17 define
  `outbox_message_id`, `status`, `detail`, and `updated_at`, the columns the
  guide's join reads.
- `Attention.hs` lines 334-383 bind eleven and three parameters to the
  eleven and three columns respectively.
