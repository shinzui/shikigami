---
type: Review
title: Architecture-practice reviews user guide
description: Every command, key, table, and refusal the guide names exists and behaves as written, but the guide presents a resolution path with no production ingress and a profile-provisioning step with no procedure as if an operator could perform them today.
generated:
  by: process:claude-code
  at: "2026-08-27T01:04:13Z"
reviewId: REV-7
subject: mori://shinzui/shikigami
subjectKind: component
component: docs/user/architecture-practice-reviews.md
reviewedSha: 62861267b8e4994ad15e7083ca0eb6b9a5dc2999
coverage: full
reviewedAt: "2026-08-27T00:12:00Z"
reviewerKind: model
reviewer: process:claude-code
provider: anthropic
model: claude-fable-5
effort: high
outcome: changes-requested
dimensions:
  - documentation
  - operability
produced:
  - mori://shinzui/shikigami/plans/61-enforce-practice-review-resolver-entitlement-and-harden-the-authorization-envelope
  - mori://shinzui/shikigami/plans/62-make-the-practice-review-closeout-and-operator-documentation-true
context: >-
  Read the complete guide and the sink, agent, README, and configuration
  pages the plan changed alongside it; checked each command against the
  server CLI and the operator CLI reference, each configuration key against
  Shikigami.App.Config, the SQL against the two migrations it joins, and each
  behavioural claim against the code and tests reviewed in REV-2 through
  REV-6.
---

# Architecture-practice reviews user guide

## Verdict

Changes requested. The guide is accurate wherever it describes something that
exists: the trigger example validates, the classification table matches
`trustedOwner`, the recipient-map syntax and boot refusals match the
configuration decoder and its tests, `grants grant <agent> <kind> --by` is a
real subcommand, the `outbox` verbs are keiro-ops verbs the operator CLI
reference documents as mounted, the join reads columns both tables have, and
the "never release a reservation" rule matches ADR 0035 and the code. Two
sections describe steps an operator cannot take at this commit, and the guide
does not say so.

## Required

1. **Mark "Resolve a review" as not yet reachable.** The section shows the
   envelope an ingress must produce and says "the ingress boundary
   authenticates a human or approved artifact". No ingress exists: the
   enqueue function and the authorizer seam have no caller outside
   `shikigami-core` and its tests, so there is no endpoint, command, or
   worker path that accepts a resolution. Say that the envelope is the
   contract and that submission requires a deployment adapter that has not
   landed, the same way the live-evidence callout already handles Kikan IR-5.
2. **Give "Provision that immutable active profile" a procedure.** The guide
   tells the operator to provision `sanctioned-review` version 1 "in the
   deployment profile store" and stops. The store is
   `shikigami.sanctioned_execution_profiles`; nothing in the server CLI
   writes it and no operations page describes the row an operator must
   insert, including how the digest is computed. Either document the SQL and
   digest, or point at the tool that does it.
3. **State who may resolve.** The guide says the ingress checks the
   verified subject against `resolution.resolver`. A reader will assume the
   subject must also be the review's recommended, triage, or exception owner.
   It need not be (REV-4). Whichever way that is settled, the guide should
   say it.

## Follow-ups that do not block

- The "Live-evidence status" callout is exactly the right shape; the two
  gaps above deserve the same treatment rather than a rewrite.
- The context-refs sentence is accurate for what the code emits; note that
  an `unresolved` verdict with no acquired evidence carries only the
  `activity://` ref, since that is the production case today.
- The grant commands were not run against a deployment by the plan; the
  guide could say the expected `grants list` output so an operator can
  confirm the two grants landed on the recorded principal rather than a
  manifest name.

## Evidence

- `shikigami-server/src/Shikigami/Server/Command.hs` lines 145 and 251-276:
  `grants grant` with `--by`. `docs/operations/operator-cli.md` lines 31 and
  189-196: `outbox show`, `requeue-stuck`, and `maintenance-pass` are the
  mounted keiro-ops verbs.
- `App/Config.hs` lines 795-813 and `AppConfigSpec.hs` lines 297-303:
  `practice_review.attention_recipients`, its environment binding, and the
  three refusals the guide describes.
- `0008-sink-deliveries.sql` lines 5-17 and
  `0012-practice-review-attention.sql`: every column the
  guide's query names.
- `grep -rn enqueueAuthorizedPracticeReviewResolution` over all package
  `src` and `app` trees: one match, the defining module.
- `grep -rln sanctioned_execution_profiles` over core, server, and worker
  sources: only `Shikigami.Attestation.Resolve`, a reader. No CLI subcommand
  and no operations page mentions provisioning.
