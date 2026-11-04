---
type: Improvement Request
title: Supervise active work with an independent watchdog agent
description: Detect stuck or drifting coordinators and workers from authoritative durable state, and raise bounded, deduplicated findings without gaining authority over the work observed.
timestamp: "2026-11-04T04:09:59Z"
generated:
  by: process:claude-code
  at: "2026-11-04T04:09:59Z"
requestId: IR-19
status: proposed
origin: mori://shinzui/shikigami
---

# Supervise active work with an independent watchdog agent

## Status

**Proposed; no implementation plan selected.** This request adopts the watchdog element of
DeepSeek Harness's "Exploring Super-agent Design" notes (1 November 2026), read from a
summary diagram rather than the source text. Those notes describe a design and prototype,
so they motivate this request but do not establish its contract.

## Problem and current coverage

Shikigami can keep work durable without anyone noticing that the work has stopped being
useful. A coordinator is the only component that reasons about its workers' progress, so
nothing reasons about a coordinator that is itself stuck or off course.

Existing mechanisms each answer a narrower question:

- [Worker health](../capabilities/worker-operations-and-telemetry.md) reports whether a
  process loop is alive (`Shikigami.Health.Worker`), not whether an objective is advancing.
- Consumer [inspection](../operations/inspection.md) applies a stuck threshold to message
  processing. An operator has to be looking at it, and it has no objective context.
- [Root resource accounting](../capabilities/root-resource-accounting.md), objective cutoffs
  and the workspace deadline guard stop work at a limit. Work can waste most of its allowance
  before reaching one, and a limit does not explain what went wrong.
- Worker sessions retain `Active`, `Parked` and `Unresolved` phases and accepted operations.
  These are the facts a watchdog needs, but no component evaluates them over time.
- [Adaptive coordination](support-adaptive-durable-orchestration.md) reflects at meaningful
  boundaries, which a coordinator that has stopped making progress may never reach.

## Requested change

1. Provide a watchdog as a declared agent with its own recorded principal, running from the
   existing schedule trigger. It needs no sleep loop or second scheduler, and
   [a late cron tick runs about the current time](../adr/0016-a-cron-agent-runs-about-now-not-once-per-missed-minute.md).
2. Give it a read-only view of authoritative objective, assignment, session, operation and
   resource state, selected by explicit grant and bounded per sweep. It reads references and
   structured facts. It does not read transcripts or repository contents by default.
3. Detect **stuck** work deterministically, without a model call: active work with no newly
   accepted operation, event or checkpoint revision within a declared window. Work that is
   legitimately waiting must be distinguishable, including a pending human approval, a parked
   assignment within its window and a running command within its deadline. Unknown operation
   outcomes are reported as unresolved. They are never treated as failed.
4. Detect **drift** through a registered typed decision over bounded evidence, comparing
   current work with the objective's admitted scope and acceptance criteria. A drift finding
   carries its evidence references and is advisory. Its output cannot change scope.
5. Produce a typed finding that names the objective, subject, detection kind, evidence and
   observed window. Deliver findings through declared sinks to the responsible coordinator
   or operator. Findings for one continuing episode coalesce, and a further notice requires a
   material change in the evidence.
6. The watchdog holds no intervention authority by virtue of being a watchdog. Any cancel,
   transfer or fence goes through the existing command owners with current membership and
   exact action authority, and the first delivery should require no such grant. Worker and
   model output cannot grant it.
7. Charge the watchdog's work to a resource allowance separate from the roots it observes, so
   an exhausted objective cannot silence it and observation cannot consume the objective's
   budget. Model-based drift checks have their own cadence and limit.
8. Make the watchdog observable and fail loudly. Operators can see the last completed sweep,
   coverage and refusals, and a stopped watchdog must be detectable by ordinary health checks
   rather than read as "no findings".

## Acceptance

1. A fixture worker stops producing accepted operations while its session stays active. One
   finding names it within the configured window, and later sweeps of the same episode send
   no further notice.
2. Work waiting on a human approval, and a command running within its deadline, produce no
   stuck finding. When the approval deadline passes without an effect, the finding appears.
3. A coordinator that has stopped deciding while its workers are idle is reported. A worker
   finding alone does not satisfy this case.
4. A worker that continues to produce accepted operations outside its admitted scope yields a
   drift finding with evidence references, using the deterministic provider. No objective
   state changes as a result.
5. A watchdog without intervention grants attempts a cancel and a transfer through the
   ordinary commands. Both are refused, and the observed work is unaffected.
6. Instructions planted in worker output do not alter a finding's subject, its recipient or
   the watchdog's authority.
7. An objective exhausts its root allowance and is still reported, while watchdog usage does
   not appear in that root's accounting.
8. Restart the watchdog mid-sweep. No finding is duplicated, no drift decision is sampled
   again for a recorded slot, and a missed sweep is visible to operators.

## Dependencies and scope

- [IR-13](support-optional-major-task-tracking.md),
  [IR-15](support-continuing-worker-sessions.md) and
  [IR-16](support-adaptive-durable-orchestration.md) supply the objective, session and
  organization state observed here.
- [IR-12](compose-shikumi-decisions-in-durable-flows.md) supplies typed drift decisions.
- [IR-18](support-recurring-objective-supervision.md) is related but distinct. A mandate
  resumes work it owns, while a watchdog observes work it does not own. This request does not
  depend on recurring mandates, and it should observe them once they exist.

Automatic remediation, general-purpose alerting, and quality scoring of finished work are out
of scope. Choosing default windows for real workloads requires observed data, so they should
be configurable and reported with their observation limits. Changes to durable bodies follow
[workflow versioning](../workflow-versioning.md).
