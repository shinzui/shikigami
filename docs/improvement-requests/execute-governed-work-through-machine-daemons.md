---
type: Improvement Request
title: Execute governed work through enrolled machine daemons
description: Let a central Shikigami runtime run durable workspace operations on enrolled machines through an outbound daemon that enforces its own local limits, so a compromised runtime cannot reach beyond each machine's grant.
timestamp: "2026-11-04T04:09:59Z"
generated:
  by: process:claude-code
  at: "2026-11-04T04:09:59Z"
requestId: IR-20
status: proposed
origin: mori://shinzui/shikigami
---

# Execute governed work through enrolled machine daemons

## Status

**Proposed; no implementation plan selected.** This request adopts the machine-daemon element
of DeepSeek Harness's "Exploring Super-agent Design" notes (1 November 2026), read from a
summary diagram rather than the source text. Those notes leave one security question open: a
hijacked cloud agent could reach every connected machine. This request treats that question as
its central requirement.

## Problem and current coverage

[Governed workspaces](provide-governed-mutable-repository-workspaces.md) run durable agent work
on one host. `shikigami-workspace-supervisor` owns a socket-activated Unix listener, and workers
reach it through a local socket checked by kernel peer credentials
(`Shikigami.Workspace.RpcClient`). This cannot reach a repository, toolchain or device on another
machine. [MasterPlan 14](../masterplans/14-deliver-adaptive-autonomous-objectives-with-durable-workers.md)
deliberately starts within one deployment.

The durable side is already strong. Workflows recover from their journals, and accepted effects
are settled by [independent receipts](../adr/0060-safe-recovery-spends-new-attempts-and-retains-independent-receipts.md).
What is missing is a way to apply those rules across an unreliable network to machines that come
and go. Other work does not supply it:

- [A2A interoperability](support-a2a-cross-runtime-agent-interoperability.md) connects independent
  Shikigami runtimes. A daemon is not an agent runtime and does not run models or workflows.
- [Plan 78](../plans/78-run-external-operations-from-durable-flows-through-idempotent-shiki-jobs.md)
  describes an optional generic job executor. It retains neither coding sessions nor workspaces,
  and its implementation milestones are unchecked.
- The current process containment depends on Linux systemd and cgroup v2, so it does not describe
  a developer's macOS laptop.

## Requested change

1. Provide a small machine daemon that hosts the existing workspace operations, with the durable
   workflow, model calls and objective state remaining in the central runtime. The daemon holds
   no provider credentials and makes no model calls.
2. The daemon connects outbound only and opens no inbound port. Enrollment creates a distinct
   machine identity through an explicit operator action on both sides. Each identity is
   individually revocable, and a revoked identity is refused on retries and reconnection.
3. **The machine is the enforcement point.** Its operator configures a local policy naming the
   repositories, identities, operation classes, containment profile and resource ceilings it
   allows. The effective permission is the intersection of central authority and local policy,
   and nothing the central runtime sends can widen local policy. The daemon offers typed
   workspace operations only. It offers no general remote shell.
4. Bind each command to a machine, assignment, owner epoch and operation identity, so that a
   captured or replayed command cannot run elsewhere or twice. A compromised runtime is limited
   to what that machine's local policy already allows.
5. Admission selects a machine explicitly from the agent's grant and the assignment's repository.
   Assignments are never silently moved between machines. Moving one uses
   [fenced handoff](support-continuing-worker-sessions.md) and an explicit base.
6. State exactly what "your repository stays where it is" means. Work runs in an isolated copy at
   an approved commit on that machine, as it does today. Uncommitted changes in a person's working
   tree are not visible unless a separate explicit grant says so. Bounded output, receipts and
   artifact identities are the only content sent centrally by default, and that set is documented.
7. Absence is a normal state. A disconnected machine leaves its assignments parked or unresolved.
   A lost acknowledgement stays unknown until the machine's retained receipt settles it, and a
   timeout alone never counts as failure. Local deadlines and cancellation keep working without
   the central connection, and work resumes on reconnection without resetting accounting.
8. Fencing must hold across a partition. A former owner cannot write after a transfer, including
   when its machine reconnects later with stale commands or results. Declare each platform's
   containment profile separately. A platform without a qualified profile refuses process tools
   and does not silently fall back to weaker isolation.
9. Operators can inspect enrolled machines, connection state, policy revision, assignments and
   unresolved operations. The existing single-host deployment continues to work without a daemon.

## Acceptance

Qualify these with at least two disposable machines, such as Apple containers, connected through
a network that the test can sever. Host-only compilation does not qualify them.

1. A fresh machine is enrolled with explicit approval, runs an authorized workspace edit,
   validation and commit, and returns exact artifact identities to a central workflow.
2. A central grant allows an operation that a machine's local policy forbids. It is refused on
   the machine, and a forged central command that requests a wider scope is refused the same way.
3. A compromised-runtime fixture holding the central credentials cannot read outside an allowed
   repository, cannot obtain a shell, and cannot use one machine's identity on another.
4. Sever the connection during a command. The command settles under its local deadline, the
   central state stays unresolved rather than failed, and reconnection settles it from the
   receipt once with no duplicate effect.
5. Transfer an assignment during a partition. When the former machine returns, its writes are
   refused and its late results cannot complete the assignment.
6. Restart the daemon, and separately the central worker, at each side of an accepted operation.
   Both recover from retained receipts without repeating the effect.
7. Revoke a machine. New commands and retries are refused, and existing uncertain outcomes remain
   inspectable.
8. A machine lacking a qualified containment profile refuses process tools at admission.
9. A person's uncommitted file is neither read nor sent without an explicit grant.

## Dependencies and scope

- [IR-11](provide-governed-mutable-repository-workspaces.md) supplies workspace operations,
  receipts and process fencing, and its supervisor is the natural base for the daemon.
- [IR-15](support-continuing-worker-sessions.md) supplies session ownership and transfer.
- [IR-16](support-adaptive-durable-orchestration.md) supplies shared capacity and limits.
- Where the central runtime is hosted remains an
  operator choice. It already runs independently of any client machine.

Native macOS containment, mobile or intermittently powered devices beyond the disconnected-state
contract, a machine marketplace, model calls from the daemon, and interactive terminal attachment
are out of scope for the first delivery. Changes to durable bodies follow
[workflow versioning](../workflow-versioning.md).
