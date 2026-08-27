---
type: Review
title: ExecPlan 46 closeout against the landed tree
description: The plan's reproducible gates hold at the reviewed commit, but its closeout claims end-to-end coverage the conformance suite does not contain, and three documents it owns were left stale.
generated:
  by: process:claude-code
  at: "2026-08-27T00:12:00Z"
reviewId: REV-1
subject: mori://shinzui/shikigami/plans/46-orchestrate-review-delivery-and-end-to-end-conformance
subjectKind: plan
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
  - test-coverage
  - design
context: >-
  Read the complete plan, ADRs 0034 and 0035, master plan 9, the workflow
  versioning guide, every file the three plan commits (8e0df55..HEAD) touch,
  and the practice-review orchestration spec; reran the plan's own
  verification commands at the reviewed commit and compared each Outcomes and
  Milestone-4 claim against what the tree and the suite actually contain.
---

# ExecPlan 46 closeout against the landed tree

## Verdict

Changes requested. Every gate the plan says it ran reproduces at the reviewed
commit: `cabal build all` exits 0, the serialized suite passes all 801 tests,
and `just keiro-gate 8e0df55` classifies both new patches as ADDITIVE with
stored-data replay neutral. The design decisions in the Decision Log are
coherent and the code follows them. What does not hold is the plan's account of
what was proven: the Milestone 4 text and the Outcomes section describe a
conformance matrix that the committed spec only partly implements, and three
documents the plan is responsible for keeping true were not updated. A closeout
record is the thing the next engineer reads instead of the code, so it must
claim exactly what the suite proves.

## Required

1. **Rewrite the Outcomes and the Milestone 4 checklist entry to what the
   suite contains.** `PracticeReviewOrchestrationSpec` has nine cases. It
   does not contain: Warp Kawa or Kizashi stubs (every AgentRun fixture uses
   `http://localhost:1` and `deliveryPool = Nothing`); transient Kizashi 500,
   terminal 4xx, or unknown crash-window handling against an attention
   reservation; the three-identity matrix (only `compatibilityIdentity` is
   exercised); a changed material claim, cited content hash, or
   classification producing a new attention key (only recipient and action
   are tested); or assertions on Kawa payload context refs, cited
   revisions, or the reservation row for the five-classification matrix,
   which asserts classification, attention non-null, and an outbox count.
   Delivery retry and recorded-principal behaviour are covered elsewhere in
   the suite for generic sinks, and the record may say so, but it may not
   present them as attention or specialist coverage.
2. **State that the router-to-specialist chain is not exercised.**
   `RouterWorkflowSpec` still delegates to a `noop-summary` Shikumi
   specialist; the only real-AgentRun test constructs the specialist `RunJob`
   with synthetic parent lineage. The plan's "real router and specialist
   declarations" claim is half true.
3. **State that the profiled path is not exercised end to end.** The
   orchestration fixtures declare `sanctionedProfile = Nothing` and resolve
   every profile to `UnknownProfile`; the only profiled-Flow test proves the
   refusal branch. Milestone 1 asked for the matching immutable profile to be
   provisioned in integration tests.
4. **State that the resolution ingress has no production caller.**
   `enqueueAuthorizedPracticeReviewResolution` and
   `ReviewResolutionAuthorizer` are referenced only from `shikigami-core` and
   its tests; no server, API, or worker path constructs an envelope. The
   library boundary is complete; the feature is not reachable.
5. **Update master plan 9's registry.** All four rows, including plan 46,
   still read `Not Started`.
6. **Add the seven `practice-review-*` labels and the two patch ids to the
   inventory in `docs/workflow-versioning.md`.** That section calls itself
   "every step name any Shikigami workflow can write" and makes a change to
   it a compatibility event; the plan chose not to touch the guide because the
   general rules needed no clarification, which is true of the rules and
   false of the inventory.
7. **Remove the trailing blank line from ADR 0034.** `git diff --check
   8e0df55..HEAD` fails on it, and the plan's Concrete Steps list that
   command as part of finishing.

## Follow-ups that do not block

- The Surprises section says `shikigami-practice-review-memory-v1` and its
  labels were "not in `domain/shikigami-agent-run.keiro`"; the diff confirms
  both patch blocks were added here, so the plan owns that transition and the
  inventory entry above.
- The Outcomes say the operator grant commands "were not run against a real
  deployment database". That is honest and should stay; the user guide (see
  REV-7) is where the same caveat is missing.

## Evidence

- `nix develop -c cabal build all` exited 0 at the reviewed commit.
- `nix develop -c cabal test all -j1 --test-show-details=direct` started
  2026-08-27T00:04:35Z and exited 0 at 00:07:15Z: 30 conformance PASS lines,
  and tasty reported 29 agent, 15 API, 3 client, 5 migration contract, 81
  worker, 46 server, 2 migration smoke, and 590 core tests passed, 801 in
  total, matching the plan's count.
- `just keiro-gate 8e0df55` exited 0 at 00:08:10Z; `keiro-diff` reported
  `ADDITIVE` for `shikigami-practice-review-memory-v1` and
  `shikigami-practice-review-flow-v1` and `replay-neutral` for stored data.
- `git diff --check 8e0df55..HEAD` reported
  `docs/adr/0034-review-resolutions-enter-as-verified-durable-envelopes.md:72:
  new blank line at EOF`.
- `PracticeReviewOrchestrationSpec.hs` lines 617-620 and 635 set every sink
  base URL to `http://localhost:1` and `deliveryPool = Nothing`; lines
  191-199 are the only attention-key variation test; lines 736-744 are the
  matrix assertion.
- `RouterWorkflowSpec.hs` lines 395-403 build the specialist as
  `ShikumiProgram {task = "noop-summary"}`.
- `grep -rn enqueueAuthorizedPracticeReviewResolution` over every package's
  `src` and `app` directories matches only
  `shikigami-core/src/Shikigami/PracticeReview/Authorization.hs`.
- `docs/masterplans/9-architecture-practice-review-flow.md` lines 57-60 carry
  `Not Started` for plans 43 through 46.
- `docs/workflow-versioning.md` lines 415-490 list no `practice-review-*`
  label and no practice-review patch id; the three plan commits do not touch
  the file.
