# 0027. The first release establishes one clean durable baseline

Date: 2026-08-23

Status: accepted


## Context

Shikigami has no users, no deployed workflow instances, no database history that
must survive, no in-flight queue messages, and no external consumer of its wire
formats. Its first release is imminent. Compatibility branches and codecs aimed
at pre-release shapes therefore protect an empty population while becoming code
that the first release would have to carry and later remove.

Two existing rules were written for an already released service. ADR 0011 says
that additive `AgentDecl` fields preserve historical journal bytes, and ADR 0012
says that every declared workflow-body addition is introduced through a patch
with a real legacy branch. Those remain the correct defaults once durable state
can exist. They do not justify manufacturing a historical v0 contract immediately
before v1.

Keiro's workflow differ deliberately has no waiver for this situation. A direct
body change is reported as `WorkflowBodyChanged` even when the operator knows the
old population is empty. That diagnostic remains useful evidence: it identifies
the exact shape being reset and prevents an accidental breaking change from being
mistaken for an additive one.


## Decision

**The first release establishes one complete v1 declaration and workflow
baseline without compatibility code for unreleased shapes.**

Until the first public release or deployment creates durable state, all of the
following must remain true for a baseline reset: there are no users, no workflow
journals that must resume, no queued or stored payloads that must decode, and no
external wire consumers. The facts are rechecked and recorded in the owning
ExecPlan immediately before the reset.

For the declarative-router initiative:

* Dhall record-completion defaults remain, because checked-in manifests are live
  source files and must continue to load unchanged.
* `AgentDecl` has one complete v1 JSON representation containing every field.
  The pre-release omission and missing-key compatibility codec is removed rather
  than extended with two more special cases.
* The router catalog and decision labels enter the declared agent-run body
  directly as part of the v1 baseline. There is no router patch id and no false
  branch for workflow instances that do not exist.
* The baseline change still runs `keiro-check`, `keiro-inspect`, deterministic
  scaffolding, generated conformance, focused replay tests, and the full suite.
  `keiro-diff` is also run and its expected `WorkflowBodyChanged` finding is
  captured in the plan. The finding is accepted only for the isolated pre-v1
  baseline change; it is not hidden, reclassified, or turned into a general
  waiver.

The exception ends at the first release or deployment, whichever happens first.
From that point onward, the released JSON shape is durable, ADR 0011 governs
additive declaration fields, and ADR 0012 plus `docs/workflow-versioning.md`
govern every declared workflow-body evolution. A future contributor may not
infer another reset merely because usage is believed to be small.


## Alternatives rejected

**Ship a router patch now and retire it after release.** The false branch serves
no instance, adds a persisted patch id to every fresh journal, and creates a
cleanup obligation during the release window.

**Keep extending the default-omitting `AgentDecl` codec.** No stored declaration
needs that shape. A complete v1 object is simpler to inspect and establishes the
wire contract that later compatibility work will protect.

**Leave the route labels undeclared so the differ stays green.** This avoids the
diagnostic by giving up the durable inventory. The first release should begin
with the labels checked, not merely protected by naming convention.

**Disable or weaken the evolution gate.** The breaking report is accurate and
valuable. The one-time decision is to accept a known pre-release break with no
affected state, not to teach the tool or repository to ignore breaking changes.


## Consequences

The first release has no dead router branch, router patch id, or pre-v1
`AgentDecl` decoding path. Current manifests remain source-compatible through
Dhall defaults, and routing is replay-safe within the v1 shape because catalog
and decision values are still journaled under static declared names.

The pre-v1 workflow baseline commit cannot use a passing `just keiro-gate
<pre-reset-ref>` as its acceptance signal: the differ must report the deliberate
break. Its component checks and conformance tests must pass, the exact diff
finding must be recorded, and subsequent changes use the new baseline. Once v1
is released, a `WorkflowBodyChanged` finding is again a release blocker unless a
new, separately approved migration strategy covers real durable state.


## References

* [`docs/masterplans/8-declarative-router-agents.md`](../masterplans/8-declarative-router-agents.md)
  — the initiative establishing the v1 router surface.
* [ADR 0011](0011-defaulted-agent-fields-preserve-journal-codec-compatibility.md)
  — the post-release declaration-codec rule.
* [ADR 0012](0012-a-declared-workflow-body-only-grows-behind-a-patch.md)
  — the post-release declared-body rule.
* [`docs/workflow-versioning.md`](../workflow-versioning.md) — the normative
  replay and release rules.



## Implementation evidence — 2026-09-07

Plan 65 rechecked the four unused-state facts before its workflow and queue/identity resets. Commits f1118af and f43b0ca retain exact accepted diagnostics under docs/evidence/plan-65. No developer database was reset. Subsequent ordinary gates pass against the new committed baseline, with no weakened flags.

See [Plan 65](../plans/65-migrate-shikigami-to-the-keiro-0-15-cohort-and-the-idiomatic-v2-record-model.md) and [ADR 0038](0038-runtime-startup-and-maintenance-share-validated-owners.md).
