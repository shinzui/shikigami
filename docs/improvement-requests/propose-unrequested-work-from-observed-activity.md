---
type: Improvement Request
title: Propose unrequested work from observed activity
description: Let an agent notice actionable work nobody asked it to do and propose a governed objective, starting it only under an explicit, bounded and revocable standing policy.
timestamp: "2026-11-04T18:45:00Z"
generated:
  by: process:claude-code
  at: "2026-11-04T04:09:59Z"
requestId: IR-21
status: accepted
targetPlan: docs/masterplans/20-propose-unrequested-work-from-observed-activity-under-governed-standing-policies.md
origin: mori://shinzui/shikigami
---

# Propose unrequested work from observed activity

## Status

**Accepted; implementation planned but not started.**
[MasterPlan 20](../masterplans/20-propose-unrequested-work-from-observed-activity-under-governed-standing-policies.md)
coordinates this request through five child plans: bounded observation with observer
allowances, closed source adapters, a deterministic pre-filter and the proposal ledger
([plan 114](../plans/114-bound-observation-with-observer-allowances-source-adapters-a-deterministic-pre-filter-and-the-proposal-ledger.md)),
a registered typed assessment decision whose output cannot select repository, authority or
recipient ([plan 115](../plans/115-assess-candidates-with-a-registered-typed-decision-whose-output-cannot-select-repository-authority-or-recipient.md)),
the stream-triggered `propose-work` Flow with durable human acceptance and trusted origin
links ([plan 116](../plans/116-propose-work-through-a-stream-triggered-flow-with-durable-human-acceptance-and-trusted-origin-links.md)),
standing policies and autonomous admission of bounded objectives
([plan 117](../plans/117-admit-bounded-objectives-autonomously-under-explicit-revocable-standing-policies.md)),
and operator observability with the integrated acceptance runner that closes this request
([plan 118](../plans/118-make-proposals-observable-to-operators-and-qualify-ir-21.md)). No child has
started. The MasterPlan records why the pre-filter runs at the trigger and only the Flow
calls a model, why a proposal is keyed by observer principal and source subject, why model
output is validated into a sealed assessment that cannot express authority, why standing
policies are revocable durable rows read fresh at every admission, and why admitted work is
an independent coordinator run with its own resource root.

This request adopts the "acts without being asked" element of DeepSeek Harness's "Exploring
Super-agent Design" notes (1 November 2026), read from a summary diagram rather than the
source text. In their example, a user described a double-click bug in chat without tagging
the agent, and the agent reproduced it, found the cause and opened a fix. This request keeps
that outcome and adds the authority model the example does not address.

## Problem and current coverage

Agents can already observe. A [stream trigger](../capabilities/durable-trigger-intake.md) fires on
matching activity, and a run can make a [typed decision](compose-shikumi-decisions-in-durable-flows.md)
and report through a sink. What is missing is a governed path from "this looks actionable" to
useful work:

- [Agent objective creation](../adr/0068-objective-creation-has-authority-before-association.md)
  exists under a default-deny operator allow-list keyed by principal. It deliberately adds no
  tools, widens no scope, admits no worker slots and allocates no resource root, so a created
  objective is not funded or staffed work.
- [Durable human approval](../capabilities/durable-human-approval.md) can park a decision, but no
  contract ties a proposal to the objective it would create.
- [Recurring mandates](support-recurring-objective-supervision.md) continue objectives that were
  explicitly admitted. They do not originate new ones.
- Nothing limits how often an agent may interrupt people with unrequested suggestions, or prevents
  it from proposing work that somebody already owns.

Observed activity is also untrusted input. A chat message, issue or review comment can be written
to steer an agent. Without a firm boundary, unprompted action turns anyone who can post into the
observed channel into someone who can direct an agent that holds repository authority.

## Requested change

1. Define the path as observation, candidate, proposal, admission, and finally ordinary objective
   execution. Each stage is durable, attributable and separately refusable. An explicitly tagged
   request is a different path and is unchanged by this request.
2. **Observed content is evidence and never instruction.** Authority comes only from a standing
   policy and the current state of the agent's principal. Neither a message's text nor its
   author's identity can create, select or widen authority.
3. Evaluate candidates in two steps: a cheap deterministic pre-filter from the trigger match, then
   a registered typed decision over bounded evidence. Skipping is the normal result. A skip is
   recorded in bounded form and notifies nobody.
4. A proposal is a typed record carrying the proposed outcome, acceptance criteria, repository
   identity, requested authority and resource envelope, evidence references with their source
   activity, and confidence. It is a proposal until validated against journaled authority, in line
   with [ADR 0029](../adr/0029-model-routing-output-is-a-proposal-until-validated-against-journaled-authority.md).
5. Before proposing, check for existing owners: open objectives, active assignments and earlier
   proposals from the same source. Proposals are keyed so that redelivery, restart and repeated
   discussion of one problem produce one proposal.
6. By default a proposal requires human acceptance through the durable approval path and expires
   when unanswered. Accepting creates the objective with a trusted origin link to the proposal and
   its source. A rejection is recorded and suppresses equivalent proposals for a declared period.
7. Allow autonomous admission only under an explicit **standing policy** that names the principal,
   sources, repositories, permitted action classes, resource envelope per objective and in total,
   rate limit and expiry. Policies are default-deny and revocable, and revocation stops new
   admission immediately. Installing an agent or Skill, or a previous success, never creates or
   extends one. A policy cannot permit publication or merging without a separately granted action,
   and the first delivery should stop at a reviewable artifact.
8. Bound attention and spend. Per-policy limits cap proposals and notifications over time, and an
   exhausted limit stops evaluation visibly rather than dropping it silently. Observation costs
   have their own accounted allowance.
9. Unrequested output says so. Anything a person sees names the agent, states that nobody requested
   it, links its source evidence and shows how to reject or stop it. Operators can inspect
   candidates, proposals, decisions, policies and the outcomes of admitted work.

## Acceptance

1. A chat fixture describes a reproducible bug without addressing the agent. A proposal appears
   with evidence references. Nothing is created until a person accepts it, and then one objective
   links back to the proposal and its source.
2. Without a standing policy, no objective is created and no work is started under any observed
   content.
3. Under a standing policy, an equivalent message admits one bounded objective that ends at a
   reviewable artifact and publishes nothing.
4. Observed messages tell the agent to ignore its limits, target another repository, or act for
   their author. Scope, repository, recipient and authority are unchanged, whoever wrote them.
5. Unrelated chatter produces recorded skips and no notifications.
6. Duplicate delivery, restart between decision and proposal, and several people restating one
   problem yield one proposal and no repeated decision sampling for a recorded slot.
7. A problem already owned by an open objective produces no competing proposal or objective.
8. Rate and spend limits stop further proposals and admissions, and the stopped state is visible.
9. Reject a proposal and see equivalent ones suppressed. Revoke a policy, or let it expire, and
   see new admission stop while admitted work stays under its own objective's controls.

## Dependencies and scope

- [IR-13](support-optional-major-task-tracking.md) supplies objective records, origin links and
  creation authority, and [IR-16](support-adaptive-durable-orchestration.md) supplies coordination
  and resource roots for admitted work.
- [IR-11](provide-governed-mutable-repository-workspaces.md) supplies repository work for coding
  outcomes. [Integrated delivery](../plans/86-qualify-integrated-adaptive-autonomous-delivery.md)
  should be qualified before a standing policy is used on real repositories.
- Sources are limited to what intake already provides. Observing GitHub, or opening a pull request,
  needs a provider that does not exist today. `mori://shinzui/kanmon` currently ships Intercom and
  transcript channels. That channel work is a separate request, and the first delivery can be
  qualified from fixtures and existing activity.
- [IR-19](supervise-active-work-with-an-independent-watchdog-agent.md) should observe objectives
  admitted through this path like any others.

Automatic merging or deployment, a shared router that handles all incoming events, learning
per-person preferences, and unbounded ambient monitoring are out of scope. Changes to durable bodies
follow [workflow versioning](../workflow-versioning.md).
