---
id: 62
slug: make-the-practice-review-closeout-and-operator-documentation-true
title: "Make the practice-review closeout and operator documentation true"
kind: exec-plan
created_at: 2026-08-27T00:54:32Z
intention: "intention_01m10bc7hae8trp0ev5mzpvt0d"
---

# Make the practice-review closeout and operator documentation true

This ExecPlan is a living document. The sections Progress, Surprises & Discoveries,
Decision Log, and Outcomes & Retrospective must be kept up to date as work proceeds.
If durable project context changes, update or create ADRs in docs/adr/ in the same change.


## Purpose / Big Picture

Plan 46 landed the OpenTelemetry practice-review specialist and wrote a closeout that the
next engineer will read instead of the code. Review records
[REV-1](../reviews/plan-46-review-orchestration-closeout.md) and
[REV-7](../reviews/architecture-practice-reviews-user-guide.md) found that the closeout
claims conformance coverage the suite does not contain, that master plan 9 still lists all
four of its plans as not started, that the workflow-versioning inventory omits the seven
new journal labels and two patch ids, that ADR 0034 fails `git diff --check`, and that the
user guide tells an operator to do two things nobody can do: submit a resolution through an
ingress that has no caller, and provision a sanctioned execution profile with no procedure
or tool.

After this plan every one of those documents says what is true at its commit. The plan
also closes the second gap for real rather than by disclaimer: an operator can run
`cabal run shikigami -- profiles install config/profiles/sanctioned-review-1.json` against
a migrated database, see the computed digest printed, and then start the reviewer without
the "profile absent" refusal. The resolution ingress remains unreachable until a
deployment adapter lands, and the guide says so in the same voice as its existing
live-evidence callout.


## Progress

- [ ] M1: plan 46 Outcomes and Milestone 4 rewritten to the proven set; master plan 9
      registry; workflow-versioning inventory; ADR 0034 whitespace.
- [ ] M2: `shikigami profiles install` and `profiles show`, the checked-in
      `sanctioned-review` version 1 profile, and their tests.
- [ ] M3: user guide corrections (unreachable ingress, provisioning procedure, unresolved
      context refs) and the interpreter-branch comment.


## Surprises & Discoveries

(None yet.)


## Decision Log

- Decision: Give profile provisioning a real subcommand instead of documenting SQL.
  Rationale: the digest is `commitmentDigest` over the profile's canonical JSON
  (`Shikigami.Attestation.Envelope.profileDigest`), and the table's check constraint
  requires the JSON identity fields to match the columns. A hand-written `INSERT` would
  require an operator to reproduce a canonical JSON encoder; a subcommand that calls the
  same function cannot drift from resolution.
  Date: 2026-08-27.

- Decision: Do not attempt to build the resolution ingress in this plan; document its
  absence.
  Rationale: an ingress needs a real authentication or approved-artifact adapter and an
  endpoint or command, which is feature work with its own contract; plan 61 defines the
  entitlement rule that any such ingress must apply. Documentation must be true now.
  Date: 2026-08-27.

- Decision: Master plan 9 rows are set from each plan's own Progress section, not from
  this plan's opinion.
  Rationale: a registry row is a summary of the plan it points at; the implementer verifies
  each plan's checklist and records `Complete` only where every non-external item is
  checked, otherwise `In Progress` with the open item named.
  Date: 2026-08-27.


## Outcomes & Retrospective

(To be filled during and after implementation.)


## Context and Orientation

The documents involved are all in the repository. `docs/plans/46-orchestrate-review-delivery-and-end-to-end-conformance.md`
is the closeout; its Progress entry for Milestone 4 (lines 66-70), its Outcomes and
Retrospective (lines 252-278), and its Milestone 4 narrative (lines 526-565) are the
passages that overclaim. `docs/masterplans/9-architecture-practice-review-flow.md` holds
the Exec-Plan Registry table (lines 55-60) with a Status column whose allowed values are
written under the table. `docs/workflow-versioning.md` has a section "What Shikigami
journals today" (from line 415) that declares itself the complete inventory of journal
step names and patch ids. `docs/adr/0034-review-resolutions-enter-as-verified-durable-envelopes.md`
ends with two newlines. `docs/user/architecture-practice-reviews.md` is the user guide;
its sections are "Trigger a review", "Resolve a review", "Configure attention and grants",
and "Inspect and recover delivery". `docs/operations/operator-cli.md` documents the
`shikigami` admin executable and the keiro-ops verbs it mounts.

What the suite actually proves is recorded in REV-1: nine cases in
`shikigami-core/test/Shikigami/PracticeReviewOrchestrationSpec.hs`, no Warp sink stubs,
no attention-specific Kizashi retry coverage, one identity, a router spec that still uses a
`noop-summary` specialist, and no provisioned profile. Plans 61 and 63 change some of
that later; this plan writes what is true at the commit it lands on, and those plans
append revision notes when they change it.

A *sanctioned execution profile* is a versioned record naming which model, provider, and
thinking settings a run may use. The reviewer declaration
(`agents/proof/opentelemetry-practice-reviewer.dhall`) requires profile
`sanctioned-review` version `1`. At run time `Shikigami.Attestation.Resolve.resolveProfile`
reads `shikigami.sanctioned_execution_profiles` (created by
`shikigami-migrations/sql-migrations/2026-08-19-20-28-05-sanctioned-execution-profiles.sql`),
re-hashes `profile_content`, and refuses a row that is absent, not `active`, expired,
or whose stored digest disagrees with the content. The row shape is `(profile_id, version,
issuer, lifecycle, valid_from, valid_until, profile_content, profile_digest)`, with a check
that the JSON's `profileId`, `version`, `issuer`, and `lifecycle` equal the columns.
`shikigami-core/test/Shikigami/ProfileResolutionSpec.hs` has an `insertProfile` helper
that shows the exact statement, and `shikigami-core/test/Shikigami/AgentWorkflowSpec.hs`
builds a version-1 profile with `workflowProfileWith defaultThinkingProhibitions
(ProfileVersion "1")`; both are the models for M2.

Relevant local ADRs: [0007](../adr/0007-a-resolved-profile-is-a-run-local-policy-snapshot.md)
and plan [50](../plans/50-fail-closed-profile-resolution-and-run-pinning.md)
define profile resolution; [0027](../adr/0027-the-first-release-establishes-one-clean-durable-baseline.md)
explains why no compatibility branch is needed for a new CLI verb;
[0034](../adr/0034-review-resolutions-enter-as-verified-durable-envelopes.md) is corrected
for whitespace only here (plan 61 amends its content). No cross-repository ADR applies.


## Plan of Work

### Milestone 1: True closeout documents

At the end of this milestone the four planning and versioning documents match the tree.

In plan 46, rewrite the Milestone 4 Progress entry and the Outcomes paragraph that begins
"The focused practice-review suite passes 44 tests" so they enumerate what the nine
orchestration cases prove (authorization refusals, key stability under whitespace and
under recipient and action change, the five-classification matrix with attention
presence, one real AgentRun with the incomplete reader, replay of the incomplete path,
and one concurrent reservation race) and state plainly what they do not: no Warp Kawa or
Kizashi stubs, no transient-500, terminal-4xx, or unknown-outcome coverage against a
reservation, only the compatibility identity, no classification, claim, or content-hash
key variation, no router-to-specialist delegation with the Flow specialist, and no
provisioned profile. Add a sentence that the resolution enqueue boundary has no production
caller. Append a Revision Note dated 2026-08-27 citing REV-1 by relative link and naming
plans 61 and 63 as the work that changes the facts. Do not rewrite the Milestone 4
narrative as if it were never claimed; add one paragraph at its end that says which of
its sentences the suite does not yet realise.

In master plan 9, set each registry row's Status from that plan's Progress section. Open
plans 43, 44, and 45, confirm every non-external checklist item is checked, and record
`Complete`; for plan 46 record `In Progress` and name the open external item (Kikan IR-5
live evidence) in the same cell, because the master plan's status vocabulary has no
"complete except external" value. Append a revision note to the master plan.

In `docs/workflow-versioning.md`, under "flow capabilities" in the inventory, add
`practice-review-evidence`, `practice-review-evaluate`, and `practice-review-attention`
with the file `Shikigami/PracticeReview/Capability.hs` and
`Shikigami/PracticeReview/Attention.hs`, marked "declared; post-patch", and
`practice-review-remember-provisional`, `practice-review-resolve`,
`practice-review-recall`, and `practice-review-chain` with
`Shikigami/PracticeReview/Memory.hs`, marked the same. Under "written by keiro on this
service's behalf", add `patch:shikigami-practice-review-memory-v1` and
`patch:shikigami-practice-review-flow-v1`, each described as "every agent-run that
interprets a flow", because `runFlowBehavior` and `runPracticeReviewMemory` evaluate both
guards for every Flow. Also fix the dangling sentence "that they are governed by rule 5
and names their owners." that sits after "Two ordinal-derived names remain" while you are
in the file.

Remove the final blank line from ADR 0034 so `git diff --check` passes.


### Milestone 2: A profile provisioning command

At the end of this milestone `cabal run shikigami -- profiles install <file>` inserts a
sanctioned profile with the digest resolution will recompute, `profiles show <id>
[--version V]` prints what resolution sees, and a checked-in file provisions
`sanctioned-review` version 1.

Create `shikigami-server/src/Shikigami/Server/Command/Profiles.hs` following the shape of
the existing `Shikigami.Server.Command.Grants` module (find it via the `grants` entry in
`adminSubcommands` in `shikigami-server/src/Shikigami/Server/Command.hs`). `install`
takes a file path, decodes it as `Shikigami.Attestation.Envelope.SanctionedExecutionProfile`,
computes `profileDigest`, inserts the row with `ON CONFLICT (profile_id, version) DO
NOTHING` using the same column list as `ProfileResolutionSpec.insertProfile`, and prints
`installed <profileId> <version> digest=<sha> ` or `already present <profileId>
<version>` when the row existed, in which case it also compares the stored digest and
exits non-zero with a clear message if they differ, because an existing row with different
content is exactly the drift resolution would refuse. `show` calls `resolveProfile
(postgresProfileStore pool)` for the id and optional version and prints the resolved
profile or the rendered `ProfileResolutionError`. Register both under a `profiles` entry in
`adminSubcommands`. The admin executable's configuration loading and pool acquisition are
already done for `grants`; reuse them.

Create `config/profiles/sanctioned-review-1.json` by encoding the value
`workflowProfileWith defaultThinkingProhibitions (ProfileVersion "1")` from
`AgentWorkflowSpec.hs` once (a one-off test that writes the JSON, run and then deleted, or
a `cabal repl shikigami-core-test` session) and committing the output. Add a test in
`shikigami-server/test` that runs the parser over `profiles install` and `profiles show`
help text, following the existing "each subcommand parses" test, and an integration case
in `shikigami-core/test/Shikigami/ProfileResolutionSpec.hs` that loads the checked-in
JSON, inserts it through the same statement the command uses, and resolves it with
`resolveProfile` at a time inside its validity window, proving the file is a profile the
reviewer can actually run under.

Document the two verbs in `docs/operations/operator-cli.md` beside `grants`.


### Milestone 3: User guide corrections and the interpreter comment

At the end of this milestone the guide describes only steps an operator can take, marks
the one it cannot, and the dead interpreter branch explains itself.

In `docs/user/architecture-practice-reviews.md`, at the top of "Resolve a review", add a
blockquote in the same form as the existing "Live-evidence status" callout: the envelope
below is the contract an ingress must produce; no ingress is wired in this release, so
resolutions cannot be submitted until a deployment adapter that authenticates the resolver
lands; the entitlement rule (plan 61) applies to any such adapter. In "Configure attention
and grants", replace the sentence "Provision that immutable active profile in the
deployment profile store before enabling the agent" with the two commands from M2 and
their expected output, and keep the list of refusals that follows. In "Trigger a review",
after the sentence about Kawa context refs, add that an `unresolved` verdict recorded
before live evidence is available carries only the `activity://practice-review/<id>` ref,
because no project was cited. Update the guide's `cabal run shikigami -- agents sync`
sequence so provisioning precedes it.

In `shikigami-core/src/Shikigami/Agent/Workflow.hs`, above the `attentionInterpreter`
binding in `runFlowBehavior`, add a comment: the `otherwise` branch is the pre-patch
shape required by rule 2 of `docs/workflow-versioning.md`; no journal can take it today
because every fresh run records the patch as true and no pre-patch reviewer journal exists
(ADR 0027), and the stub `attention` callback it installs fails closed by design.


## Concrete Steps

All commands run from `/Users/shinzui/Keikaku/bokuno/shikigami` inside the Nix shell with
the local PostgreSQL cluster running.

Milestone 1 is prose; verify with:

```bash
git diff --check
grep -n "practice-review-" docs/workflow-versioning.md
grep -n "| 4 |" docs/masterplans/9-architecture-practice-review-flow.md
```

The first prints nothing; the second lists the seven labels and two patch ids; the third
shows the plan-46 row with `In Progress`.

Milestone 2:

```bash
nix develop -c cabal build all
nix develop -c cabal run shikigami -- profiles install config/profiles/sanctioned-review-1.json
nix develop -c cabal run shikigami -- profiles show sanctioned-review --version 1
nix develop -c cabal run shikigami -- profiles install config/profiles/sanctioned-review-1.json
nix develop -c cabal test shikigami-core-test -j1 --test-options='-p "profile"' --test-show-details=direct
nix develop -c cabal test shikigami-server-test -j1 --test-show-details=direct
```

Expected transcript for the three `profiles` invocations:

```text
installed sanctioned-review 1 digest=sha256:<64 hex>
sanctioned-review 1 issuer=<issuer> lifecycle=active valid_from=<time> digest=sha256:<same 64 hex>
already present sanctioned-review 1 digest=sha256:<same 64 hex>
```

Finish with the full suite and gate:

```bash
nix develop -c cabal test all -j1 --test-show-details=direct
nix develop -c just keiro-gate <merge-base>
```

Every commit carries:

```text
ExecPlan: docs/plans/62-make-the-practice-review-closeout-and-operator-documentation-true.md
Intention: intention_01m10bc7hae8trp0ev5mzpvt0d
```


## Validation and Acceptance

For M1, a reader of plan 46 can list, from its Outcomes alone, exactly the nine cases the
suite has and the six things it lacks, and finds a 2026-08-27 revision note; master plan 9
shows three `Complete` rows and one `In Progress` row naming Kikan IR-5; `grep` finds the
new inventory lines; `git diff --check` is silent.

For M2, on a freshly migrated local database the three-command transcript above
reproduces, and after it `nix develop -c cabal run shikigami -- validate
agents/proof/opentelemetry-practice-reviewer.dhall` still validates the declaration. A
second `install` of a *modified* copy of the JSON with the same id and version exits
non-zero with a digest-mismatch message and leaves the original row untouched.

For M3, the guide's "Resolve a review" section opens with the not-wired callout, and its
provisioning paragraph is the transcript an operator can reproduce. `cabal test all -j1`
passes.


## Idempotence and Recovery

Document edits are plain text; re-running the greps verifies them. `profiles install` is
idempotent by construction (`ON CONFLICT DO NOTHING` plus a digest comparison) and never
updates a row, which matches the table's "immutable revisions" comment; to change a
profile, install a new version. If the checked-in JSON is regenerated, compare its digest
with the one recorded in the guide's transcript; a difference means the profile content
changed and the guide's sample output must be refreshed. No step touches `domain/` or the
generated layer.


## Interfaces and Dependencies

`Shikigami.Server.Command.Profiles` exports the `install` and `show` parsers and runners
used by `Shikigami.Server.Command.adminSubcommands`. It depends on
`Shikigami.Attestation.Envelope` (`SanctionedExecutionProfile`, `profileDigest`),
`Shikigami.Attestation.Resolve` (`postgresProfileStore`, `resolveProfile`,
`renderProfileResolutionError`, `profileDigestText`), `hasql` for the insert, and the admin
executable's existing configuration and pool plumbing. `config/profiles/sanctioned-review-1.json`
is a `SanctionedExecutionProfile` document. The review records this plan answers are
[REV-1](../reviews/plan-46-review-orchestration-closeout.md) (required items 1 through 7)
and [REV-7](../reviews/architecture-practice-reviews-user-guide.md) (required items 1 and 2
and the unresolved-refs follow-up), plus the interpreter-branch note from
[REV-6](../reviews/practice-review-capability-ports.md).
