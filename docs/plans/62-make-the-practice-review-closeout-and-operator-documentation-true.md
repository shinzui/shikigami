---
id: 62
slug: make-the-practice-review-closeout-and-operator-documentation-true
title: "Make the practice-review closeout and operator documentation true"
kind: exec-plan
master_plan: "docs/masterplans/9-architecture-practice-review-flow.md"
created_at: 2026-08-27T00:54:32Z
intention: "intention_01m10bc7hae8trp0ev5mzpvt0d"
provenance:
  revisions:
    - model: "gpt-6.1-sol"
      harness: "codex-cli"
      at: 2026-11-06T21:09:33Z
      mode: "update"
      note: "Accept bounded closeout documentation reconciliation; refresh still-open profile provisioning and current operator examples."
---

# Make the practice-review closeout and operator documentation true

This living plan was refreshed against `ff00b819` on 2026-11-06. The existing
repair scope remains; obsolete August paths, entity IDs and patch instructions are removed.

## Purpose / Big Picture

An operator should be able to install and inspect the exact sanctioned review profile
using supported commands and follow instructions that match the implemented reviewer.
The closeout must distinguish actual fixture coverage from unproven routed/delivery/live
cases. Resolution examples must describe the real ingress contract and its deployment gap.
This plan documents the core enqueue boundary; it does not add a public authentication
adapter or implement resolver entitlement, which remains plan 61.

## Progress

- [x] (2026-11-06) M1: current plan-46 closeout and MasterPlan-9 registry describe the delivered subset and required repairs/live evidence; the current workflow guide points to actual declarations/generated facts, and ADR-0034 has no whitespace defect.
- [ ] M2: implemented profile install/show commands and an operator-authored `sanctioned-review` version-1 artifact pass validation, immutable duplicate/conflict and real resolution tests.
- [ ] M3: current ID-free/versioned user examples, absent-ingress and unresolved-context guidance, provisioning instructions and applicable operator documentation validate against the final code.

M1 is the documentation reconciliation delivered in this refresh, not proof that plan 46
or this child is complete. Profiles commands and `config/profiles/` are still absent.

## Surprises & Discoveries

The old plan cited deleted pure-test paths and a nine-case suite. Orchestration,
profile resolution, router and delivery integration tests now live under
`shikigami-core/test-postgres/Shikigami/`. The suite additionally covers real ID-free
ingress and corrupt attention results. Its larger presence does not close plan 63.

The maintained workflow inventory now links `domain/shikigami/agent-run.keiro` and
its generated facts. Historical review patch ids have been retired; the old instruction
to append seven labels and two retired patches to a prose census is obsolete. Follow
the checked current declarations instead. ADR 0034 already ends cleanly.

The user guide still shows a schema-1 envelope and caller-supplied deterministic
resolutionId. Current schema-2 admission takes an ID-free request and allocates the
entity in its owner. Plan 61 will add entitlement with a new version; examples must
follow whichever implementation has actually landed, never a planned codec.

## Decision Log

2026-11-06 refresh: credit current closeout/inventory reconciliation as M1; preserve
profile provisioning and user guidance as separate deliverables. Use current opaque
profile values, the public store owner and actual admin composition; remove obsolete
patch-branch comments because those branches no longer exist.

Historical rationale follows; dated references to a missing registry refresh or the
old test inventory are superseded by the current Context and Plan of Work.

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

M1's documentation reconciliation is delivered by this refresh. M2/M3 remain open:
there is no profiles command or shipped profile artifact, and existing user examples
are stale. No database, profile installation or runtime test was executed for this
planning update. The documented future transcript is an acceptance expectation only.

## Context and Orientation

`shikigami-server/src/Shikigami/Server/Command.hs` owns administrative command dispatch;
`Server/Command/Grants.hs` and existing Ops/Objectives commands show current parser,
configuration and administrative runtime composition. Add the Profiles command in that
package, with reusable install/store behavior in core rather than tests mirroring SQL.

`shikigami-core/src/Shikigami/Attestation/Profile.hs` defines the checked profile;
Envelope.hs supplies `profileDigest` and Resolve.hs supplies `postgresProfileStore`
and fail-closed `resolveProfile`. The profile migration and store schema already exist.
Read their current statement/codec instead of constructing obsolete public newtypes.
PostgreSQL ProfileResolutionSpec and AgentWorkflowSpec provide validation fixtures.

The proof reviewer at `agents/proof/opentelemetry-practice-reviewer.dhall` requires
`sanctioned-review` version 1. Its installed artifact must use approved provider/model/
thinking tuples and explicit validity/issuer/lifecycle. Test fixture defaults cannot
choose deployment authority for an operator. A profile is permission data, not a secret.

Read [ADR 0007](../adr/0007-a-resolved-profile-is-a-run-local-policy-snapshot.md),
[ADR 0034](../adr/0034-review-resolutions-enter-as-verified-durable-envelopes.md),
[ADR 0093](../adr/0093-review-entities-are-allocated-behind-durable-request-receipts.md)
and [workflow versioning](../workflow-versioning.md). Plan 46 owns the current closeout,
plan 61 entitlement/source policy and plan 63 the full conformance matrix. Historical
review events in docs/reviews are immutable; later evidence supersedes their findings.

## Plan of Work

### M1 — Keep closeout consistent with proven behavior

The refreshed plan 46 identifies delivered M1–M3 separately from M4/M5 acceptance;
MasterPlan 9 keeps three original children Complete and plan 46 In Progress with
repair dependencies. The current guide delegates label inventory to checked declarations
and generated facts. Do not restore old patch ids or stale line-number inventories.
As repairs land, replace only the applicable open findings with named test evidence.
Do not rewrite original review events or imply that historical suite totals certify
new branches. This refresh accepts that bounded documentation outcome.

### M2 — Implement immutable profile provisioning

Add `shikigami profiles install FILE` and `profiles show ID [--version V]` in the
server admin parser. Decode through the actual checked SanctionedExecutionProfile
boundary, compute the same canonical digest resolution uses, and install through one
reusable core operation. A new id/version inserts immutable content; an identical
retry returns the existing digest; a different payload under the same id/version
refuses and leaves the row unchanged. Concurrent identical/conflicting installs must
follow those same outcomes. Reuse the admin runtime and explicit database settings.

Create `config/profiles/sanctioned-review-1.json` from an explicitly chosen non-secret
profile, validated against the proof reviewer's requirement and current provider catalog.
Do not synthesize deployment issuer/authority from fixture defaults. The checked-in
example must clearly distinguish the example's model/validity from deployment approval.
`show` uses the same fail-closed resolution owner and renders bounded public fields,
not a raw secret/config dump. Existing absent/expired/withdrawn/ambiguous/digest-mismatch
refusals remain authoritative.

Test real command parsing and dispatch plus actual install/show behavior with disposable
migrated PostgreSQL. Install twice, resolve the committed artifact, attempt a changed
payload and assert refusal/original preservation. Cover malformed files, invalid values,
concurrent conflicts and explicit version selection. Keep these in the server suite and
core PostgreSQL owner suite; do not copy the command's SQL into a test-only substitute.
Document the actual commands in `docs/operations/operator-cli.md`.

### M3 — Fix current operator/user guidance

In `docs/user/architecture-practice-reviews.md`, state that no deployed resolution
authentication adapter is wired. The tested core enqueue helper is a contract for such
an adapter, not a command an operator can currently invoke. Use an ID-free resolution
request, the actually implemented outer schema and its real receipt fields; remove
caller-authored ResolutionId and derived-entity instructions. If plan 61 has landed,
include its entitlement field/version and owner-or-authority rule; otherwise do not
claim it is enforced. A self-consistent receipt checksum is not authentication.

Replace unsupported profile-provisioning prose with M2's real validated install/show
commands, before reviewer enablement. Explain required explicit deployment authorization
and profile validity. For an unresolved review before content acquisition, document only
refs actually emitted; do not claim a missing project citation exists. Preserve the
live-reader warning and correct grants/recipient/recovery commands from current parsers.

No obsolete attention-interpreter branch comment is needed: current production installs
the interpreter directly. If code comments are changed, describe the current body and
follow the workflow rules. Maintain user OKF timestamp/log/index through its established
commands and run user-docs validation. Examples should be decoded by the current
validators where feasible, rather than checked only by matching strings.

## Concrete Steps

Run from the repository root. Use the Nix shell and isolated migrated fixtures; ordinary
plan refresh does not install into an existing developer or production database.

```bash
plan62_base=$(git rev-parse HEAD)
nix develop --no-write-lock-file -c cabal build all
nix develop --no-write-lock-file -c cabal test shikigami-core-postgres-test -j1 --test-options='--num-threads=1 -p profile' --test-show-details=direct
nix develop --no-write-lock-file -c cabal test shikigami-server-test -j1 --test-options=--num-threads=1 --test-show-details=direct
just user-docs-validate
git diff --check
```

After M2 exists, against a task-owned migrated fixture database, exercise install, show
and repeat install with the same artifact, then reject a changed same-version artifact.
Record actual output/digest and assert the proof manifest validates. These commands are
future deliverables, not available merely because they appear in this plan.
Run full applicable tests; use `just keiro-gate` against `plan62_base` only where durable
body/codec changes occur. No removed patch or production ingress is introduced here.

## Validation and Acceptance

M1 documents actual coverage and current declarations without obsolete patch claims.
M2 installs and resolves the exact artifact, converges on repeat/concurrency and refuses
conflicting content. M3's instructions/examples match current code, show real provisioning
and explicitly identify absent ingress/live reader behavior. All docs and applicable
behavioral tests pass. Profile deployment authorization remains explicit.

## Idempotence and Recovery

Profile revisions are immutable; changes use a new version. Do not update stored content
or canonical bytes to make an old digest pass. Failed parsing/admission changes nothing;
lost successful responses recover the original record. Documentation can be rerun against
current validators. Never alter immutable review events to erase prior findings.

## Interfaces and Dependencies

Server owns the Profiles command; core owns reusable profile install/resolve behavior;
AppConfig owns administrative connection settings. The existing profile store, typed
values and digest are delivered prerequisites. Plan 61 owns entitlement, plan 63 runtime
conformance and plan 46 live reader acceptance. No signature algorithm or upstream release
is required for profile provisioning. This plan answers
[REV-1](../reviews/plan-46-review-orchestration-closeout.md) and
[REV-7](../reviews/architecture-practice-reviews-user-guide.md), with current fact checks
superseding obsolete line numbers and retired-branch notes.

## Revision Notes

2026-11-06: Accept bounded closeout/inventory reconciliation; rebase provisioning and
examples on current admin/store/ID-free contracts, remove retired-patch and removed-test
instructions, and retain real install/show and user-document acceptance as open work.
