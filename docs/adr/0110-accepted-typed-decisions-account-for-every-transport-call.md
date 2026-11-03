# 110. Accepted typed decisions account for every transport call

Date: 2026-11-03

Status: Accepted

## Context

Typed decision programs can contain multiple model nodes and retries. Charging
only their wrapper, or executing the entire program inside a workflow result
step, would bypass root spending limits or occupy a workflow advance during
provider IO. Existing synchronous decision journals must retain their labels,
preparation, outcome codecs and replay behavior.

## Decision

The new adaptive interpreter submits a `TypedDecision` operation to the existing
accepted executor. Protected operation input retains the complete preparation
and serializable parameter state. Admission verifies the state commitment,
model descriptor, profile and native workflow identity. An accepted preparation
is recovered before consulting live programs or model bindings. Results use the
existing `DecisionOutcome` envelope and retained pure result codecs.

The wrapper uses the existing attempt claim, dispatch fence, shared capacity
ticket, queue repair and generation-owned observation wake. It does not reserve
a synthetic model attempt against the root. Every actual provider call instead
receives an independently allocated resource attempt through the existing
selection/root owner. This wrapper sits below Shikumi's internal nodes and
retry loops. The final credential-free request options determine reservation
ceilings. Fresh authority and the exact executor claim are checked before each
call. Internal parallel nodes serialize at this transport boundary, so one
typed work item never consumes more than its one runtime permit.

Resource admission/settlement composes with the decision evidence owner's
transaction. Root locks precede decision-run locks. An allocated decision call
retains its actual selection receipt through an application-owned association;
the deferred evidence foreign key permits that lock order. Any owner's refusal
rolls back both owners. Unresolved provider expectations retain uncertain root
usage; a stopped local executor can release runtime occupancy without inventing
measurements or settling unknown spending.

The synchronous interpreter retains its original branch. Only the accepted
adaptive slot uses the new submit/observe path and its static submit label.
Carried coordinator policy bounds future generations; current configuration
cannot expand it silently. New registered workflow call sites must declare the
new steps/child and introduce a real patch protecting existing populations.

## Consequences

A multi-node typed program spends one root attempt per actual transport call.
An exhausted root refuses an internal retry/node before provider IO. A held
decision uses the same capacity mechanism as worker execution while its parent
workflow is suspended. A result already committed by either executor or parent
is read without another model invocation or current result validation.

Unknown calls can block further progress until their evidence is reconciled;
lease expiry cannot refund them. Production executor consumers must use the
typed-aware entry point. The legacy executor explicitly refuses typed work
when no typed runner is installed.

This record covers the execution/evidence bridge. The adaptive coordinator's
graph-to-session command protocol and exact artifact qualification remain
separate implementation and acceptance obligations in Plan 85.
