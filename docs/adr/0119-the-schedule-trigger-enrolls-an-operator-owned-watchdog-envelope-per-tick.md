# 119. The schedule trigger enrolls an operator-owned watchdog envelope per tick

Date: 2026-11-06

Status: Accepted

## Context

Scheduled agents historically carry no execution root. A watchdog needs independent model
spend even when observed work has exhausted its own allowance. Installing an agent declaration
must not grant spend. Recomputing an absolute cutoff on retry conflicts with strict origin
binding and can accidentally broaden the allowance.

## Decision

Only the schedule trigger honors the watchdog allowance in operator configuration. It
requires the configured verified principal, the admitted identity and `watchdog-sweep` Flow
to match. Admission requires positive bounded ActiveWork, ModelAttempts and Tokens, explicit
unbounded CostMicroUsd, a positive lifetime and bounded nonnegative other dimensions.

The first root cutoff is receipt time plus the lifetime, following [ADR 0115](0115-evaluation-spend-is-a-root-enrolled-at-the-trigger-and-accounted-slots-refuse-without-one.md).
Resource ownership retains the first complete envelope at the native workflow origin. Retries
recover it after verifying creator and agent, including after configuration changes. The
existing exact-envelope allocator remains strict for its callers. Root and run-job publication
share one transaction. Missing or mismatched allowance records a trigger skip; storage failure
retains the timer for retry.

## Alternatives

Declaration-wide resources would let installed code allocate spend. An allowance keyed only
by display agent name would weaken verified identity binding. Charging observed roots would
make observation fail precisely when independent supervision is needed.

## Consequences

The Dhall declaration and AgentDecl resource schema stay unchanged. Other schedule agents
retain their existing behavior. Stream, event, delegated and one-off watchdog invocations do
not gain this schedule allowance. Deploy the resource owner and accounting support before
enabling the schedule and its operator configuration; actual provider attempts remain
conservatively accounted under [ADR 0051](0051-resource-roots-own-conservative-reservations-and-actual-attempts.md).
