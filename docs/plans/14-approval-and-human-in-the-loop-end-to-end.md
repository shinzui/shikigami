---
id: 14
slug: approval-and-human-in-the-loop-end-to-end
title: "Approval and human-in-the-loop end to end"
kind: exec-plan
created_at: 2026-07-08T20:14:28Z
intention: "intention_01kx1tygnxenvarsw91bjsy19r"
master_plan: "docs/masterplans/2-production-reality-de-stub-the-runtime-behavior-and-integration-path.md"
---

# Approval and human-in-the-loop end to end

This ExecPlan is a living document. The sections Progress, Surprises & Discoveries,
Decision Log, and Outcomes & Retrospective must be kept up to date as work proceeds.


## Purpose / Big Picture

Shikigami already has the low-level pieces of durable approval. An agent workflow can
allocate a Keiro awakeable, arm a durable deadline, suspend, accept an external decision,
and resume without dispatching a sink twice. The production composition is still inert:
`Shikigami.Workers.Config.agentRunDeps` installs `defaultApprovalEnv`, which never requires
sink approval and never sends a notification. Flow acknowledgements do park, but the same
no-op notifier means no human sees their token. `resolveApproval` exists in core, but the
administrative `shikigami` dispatcher has no command that calls it.

After this plan, a deployment can require approval for selected sink kinds with the typed
Settei keys `approval.require` and `approval.channel`; the existing
`approval.deadline_seconds` remains the common deadline. A fresh agent run journals the
resolved approval policy as a run-local snapshot. Each required sink approval and each
Flow acknowledgement runs as a dedicated `shikigami.approval` child workflow. That child
uses the static labels `ingest-approval`, `notify`, and `decision`, posts an authenticated
ask through the process-lifetime Danwa or Kizashi client, and parks on an opaque Keiro
awakeable token. An operator can then run:

```bash
nix develop -c cabal run shikigami -- resolve-approval TOKEN --approve
```

or:

```bash
nix develop -c cabal run shikigami -- resolve-approval TOKEN --reject "not approved"
```

The worker's already-supervised resume loop drives the child and then the parent. Approval
dispatches the sink exactly once; rejection or timeout suppresses it. Flow acknowledgements
use the same visible notification and resolution path. A stable `ReviewRequestId` identifies
the review forever and is printed in the ask, while the random awakeable token authorizes
one decision; they are deliberately different values.

The observable acceptance path is: start a worker with `KawaDigest` approval enabled,
enqueue `heartbeat`, see one Danwa or Kizashi ask containing a review id and token, approve
the token from the terminal, and observe the Kawa intent enqueue and publish. Repeating the
same resolution reports that the token is unknown or already resolved. A second run rejected
from the terminal completes without enqueuing its Kawa intent.


## Progress

- [x] (2026-08-23) Re-audited the repository, all prerequisite plans, the accepted workflow,
      configuration, outbound HTTP, operator-command, and attestation decisions, and the
      current Keiro 0.14 source and release tag.
- [x] (2026-08-23) Rebased this plan from the removed monolithic worker and pre-Settei design
      onto `shikigami-core`, `shikigami-workers`, and `shikigami-server`; removed work already
      delivered by plans 17, 22, 36, 37, 39, 47, and 51.
- [x] (2026-08-23) Declared and scaffolded the approval child workflow and the permanent
      `shikigami-approval-workflow-v1` parent patch; updated the generated inventory,
      Cabal module list, active-patch union, and conformance expectations.
- [x] (2026-08-23) Added deploy-simulation replay tests for the legacy and child-workflow
      branches on both Flow and sink request keys, plus a frozen stable-review-id vector and
      generated-patch membership assertion. The Keiro gate follows the milestone commit because
      its scaffold check compares generated files with `HEAD`.
- [x] (2026-08-23) Verified the checkpoint with `nix fmt`, `git diff --check`, `cabal build all`,
      all 30 `keiro-shikigami-conformance` facts, the three approval/versioning focused tests,
      and all 44 `AgentWorkflow` tests.
- [x] (2026-08-23) Completed milestone 2: added authenticated, bounded Danwa and Kizashi asks
      over the process `SinkHttp`, safe transient/permanent classification, retry semantics,
      stable public review identity, and permanent fail-closed parent behavior.
- [x] (2026-08-23) Completed milestone 3: added typed Settei parsing and diagnostics for
      `approval.require` and `approval.channel`, wired the resolved policy and real notifier into
      `WorkerEnv`, registered the child for resume, and added the secret-safe structured startup
      event. All 53 focused configuration cases pass.
- [x] (2026-08-23) Completed milestone 4: added `shikigami resolve-approval`, parser and
      exit-selection tests, real WAI Danwa/Kizashi notification tests, and durable
      park-notify-resolve-resume proofs for approve, reject, timeout, double resolution,
      notification failure, and the remote-accept/local-commit crash window.
- [x] (2026-08-23) Completed milestone 5: `nix fmt`, `git diff --check`, `cabal build all`,
      `just keiro-gate 20bd2a8e23dbac16246bfbf9559a5ca6c1f7d7ed`, and the complete
      `cabal test all -j1` run passed. The serial run covered all nine test components and 737
      cases, including 530 core, 81 worker, 43 server, and 30 generated conformance cases.
- [x] (2026-08-23) Exercised the production composition against the real local Danwa server and
      a fresh isolated Shikigami database: approve published one Kawa event, double resolution
      was refused, and reject plus timeout both completed without creating another outbox row.
      The redacted transcript is recorded below.


## Surprises & Discoveries

- Observation: most of the original prerequisites are already complete, and the current
  worker already carries `approvalDeadline` from `approval.deadline_seconds` into
  `AgentRunDeps.deadline`.
  Evidence: `docs/plans/17-behavior-retry-semantics-run-timeouts-and-visibility-heartbeat.md`,
  `docs/plans/22-outbound-authentication-for-sink-clients.md`, and
  `docs/plans/39-adopt-a-checked-keiro-dsl-specification-and-evolution-gate.md` have completed
  progress; `Shikigami.App.Config` declares the key and
  `Shikigami.Workers.Config.agentRunDeps` passes it onward.
  Date: 2026-08-23

- Observation: the original plan's promise to leave approval step labels untouched is no
  longer compatible with the repository's checked durable-workflow rules. Sink approvals use
  `approval:<SinkKind>:<ordinal>` and notifications append `:notify`; these computed labels
  cannot be declared as Keiro DSL wire words and are named as remaining debt by ADR 0017.
  Evidence: `domain/shikigami-agent-run.keiro`, `docs/workflow-versioning.md`,
  `docs/adr/0017-rotate-to-make-a-label-static-rather-than-computing-it.md`, and
  `Shikigami.Agent.Workflow.approveSinks`.
  Date: 2026-08-23

- Observation: the production resume worker is no longer a one-shot action. It supervises the
  Keiro resume runner with capped backoff and fails the process after repeated runner exits.
  This plan only needs to add the approval workflow to the registry; it does not need to build
  polling or recovery infrastructure.
  Evidence: `Shikigami.Agent.Workflow.Resume.runResumeLoop` and
  `Shikigami.Agent.Workflow.Resume.workflowRegistry`.
  Date: 2026-08-23

- Observation: outbound authentication, request/response bounds, redirect refusal, shared
  managers, and typed HTTP failure classification are already centralized in `SinkHttp`.
  Approval notification must consume that object rather than construct a client or manager.
  Evidence: `Shikigami.Sink.Http` and ADR 0026.
  Date: 2026-08-23

- Observation: `ReviewRequestId` already exists in `Shikigami.Attestation.Evidence`, because
  plan 51 needed the type before the approval owner existed. Production agent runs do not yet
  create run evidence, so this plan owns the approval identity and preserves the evidence JSON
  shape, but does not invent evidence persistence work.
  Evidence: `Shikigami.Attestation.Evidence`, outcomes in
  `docs/plans/51-run-evidence-aggregate-and-compliance-roll-up.md`, and the follow-on query in
  `docs/plans/52-signed-attestation-read-api-and-uc-8-conformance.md`.
  Date: 2026-08-23

- Observation: the earlier reconciliation proposed a DSL signal operation keyed by the parent
  workflow id. That is not the runtime being implemented: `resolveApproval` signals an opaque,
  random, journaled `AwakeableId`. Declaring the proposed operation would violate ADR 0001 by
  claiming a generated contract the CLI does not execute.
  Evidence: `mori://shinzui/keiro/packages/keiro` documents v4 journaled awakeable ids and
  idempotent `signalAwakeable`; `domain/shikigami-agent-run.keiro` has no matching keyed signal
  runtime.
  Date: 2026-08-23

- Observation: approval policy itself is replay-sensitive. Reading process configuration again
  after a crash could cause an old run to skip an approval it previously required, or require a
  new one before dispatch. The policy must cross one static journal step before it controls the
  workflow.
  Evidence: the same mutable-policy problem and journaled-snapshot remedy are established for
  execution profiles by ADR 0007.
  Date: 2026-08-23

- Observation: Keiro DSL 0.14 scaffolds `declaredPatches :: Set PatchId`, but does not generate
  one named Haskell constant per declared patch.
  Evidence: the scaffolded `Shikigami.AgentRun.Generated.WorkflowRuntime` exports
  `declaredPatches`, `declaredPatchStepNames`, and `withDeclaredPatches`; the generator in
  `mori://shinzui/keiro/packages/keiro-dsl` emits no per-patch binding.
  Date: 2026-08-23

- Observation: `just keiro-scaffold` intentionally fails while newly scaffolded output differs
  from `HEAD`, even when the generated files are correct. A new workflow declaration therefore
  needs a milestone commit before `just keiro-gate <merge-base>` can prove both scaffold
  cleanliness and compatibility against the pre-change tree.
  Evidence: the scaffold recipe completed generation and reported only the expected generated
  diff; `cabal test keiro-shikigami-conformance` passed all 30 facts afterward.
  Date: 2026-08-23

- Observation: the administrative executable already has its own telemetry composition helper,
  `withServerTelemetry`, and the server package deliberately does not depend on
  `shikigami-workers`. The one-shot resolution command can construct the same `AppEnv` shape
  without importing the worker package or starting worker loops.
  Evidence: `Shikigami.Server.Command.ResolveApproval`, `Shikigami.Server.Telemetry`, and the
  component dependency graph in `shikigami-server.cabal`.
  Date: 2026-08-23

- Observation: Cabal commands that build the same test component concurrently race over the
  component's inplace package-cache lock. Focused test invocations and final validation must be
  serialized, independently of the repository's database-test serialization requirement.
  Evidence: two concurrent focused `shikigami-core-test` invocations produced a missing
  `package.cache.lock`; rerunning the affected target alone passed.
  Date: 2026-08-23

- Observation: the existing local `shikigami` development database was five migrations behind
  and reported a historical Kioku checksum mismatch. Applying pending migrations to that
  database would have mixed this feature proof with unrelated migration recovery work.
  Evidence: `just migrate-status` reported `pending=5`, `issues=1`, with
  `MigrationChecksumMismatch` for `kioku/0011-kioku-memory-space-partition`; the manual proof
  therefore used a freshly created and fully migrated `shikigami_plan14` database.
  Date: 2026-08-23

- Observation: the dev shell's `PG_CONNECTION_STRING` binding outranks configuration files, as
  the Settei contract says it should. A temporary file naming the isolated database was correctly
  shadowed until the manual commands supplied an explicit process environment value.
  Evidence: `--explain-config-json` named `PG_CONNECTION_STRING` as the winning origin and the
  temporary YAML source as shadowed.
  Date: 2026-08-23


## Decision Log

- Decision: Fresh parent workflows use a dedicated `shikigami.approval` child workflow for
  every Flow acknowledgement and required sink approval. The parent change is guarded by the
  permanent patch id `shikigami-approval-workflow-v1`; the false branch retains the current
  direct awakeable path for pre-change journals.
  Rationale: one approval per child generation permits static `ingest-approval`, `notify`, and
  `decision` labels, so the checked DSL can describe the durable shape. The child relationship
  remains idempotent and resumable through Keiro's existing `spawnChild`/`awaitChild` machinery.
  This project-level choice is recorded in ADR 0030.
  Date: 2026-08-23

- Decision: The true patch branch journals an `ApprovalPolicySnapshot` once under
  `resolve-approval-policy` before either behavior or sink policy consumes it. The snapshot
  includes the selected sink-kind set, notification channel, and deadline.
  Rationale: process configuration is mutable across deploys; workflow decisions must replay
  from the original policy rather than silently adopt the worker that happens to resume them.
  Date: 2026-08-23

- Decision: `approval.require` is a comma-separated set of canonical `sinkKindText` values and
  defaults to the empty set. `approval.channel` accepts `danwa` or `kizashi` and defaults to
  `danwa`. Existing `approval.deadline_seconds` remains the bounded positive duration. Explicit
  environment bindings are `SHIKIGAMI_APPROVAL_REQUIRE`,
  `SHIKIGAMI_APPROVAL_CHANNEL`, and `SHIKIGAMI_APPROVAL_DEADLINE_SECONDS`.
  Rationale: these values belong in the one typed Settei application config and its diagnostics;
  a second environment parser would create conflicting precedence and error behavior. Empty
  `require` preserves existing sink auto-approval.
  Date: 2026-08-23

- Decision: Even when the sink policy is disabled, the worker installs the real approval
  notifier. Policy only decides whether an ordinary declared sink needs approval; an explicit
  Flow acknowledgement always asks.
  Rationale: `awaitAcknowledgement` is an intentional human gate, not a sink-policy lookup. The
  current no-op notifier is why that gate is invisible in production.
  Date: 2026-08-23

- Decision: `ReviewRequestId` is a stable public identifier derived with UUIDv5 from the parent
  workflow name, workflow id, generation, and a stable request key. Sink keys use
  `sink-<canonical-kind>-<declared-ordinal>`; Flow keys use
  `flow-<call-site-StepName>`.
  `AwakeableId` remains Keiro's opaque random token and is never derived from the review id.
  Rationale: the review id is safe to index, log, and retain in attestations; the token is a
  one-shot capability. Making the token predictable would weaken the authorization boundary,
  while using it as the review id would couple durable evidence to a completion mechanism.
  Date: 2026-08-23

- Decision: Move the owning `ReviewRequestId` newtype into the approval vocabulary and import or
  re-export it from `Shikigami.Attestation.Evidence` without changing its `Text` JSON encoding.
  Rationale: approval now owns construction and semantics, while plans 51 and 52 retain source
  and wire compatibility. Connecting every approval to run-evidence persistence remains outside
  this plan because no production caller constructs that aggregate today.
  Date: 2026-08-23

- Decision: Approval asks reuse the authenticated `SinkHttp.danwa` and `SinkHttp.kizashi`
  clients. Danwa gains a text-post helper factored from its existing fresh-conversation path;
  Kizashi receives an `AgentRequest` signal through the existing wire DTO and client.
  Rationale: plan 22 and ADR 0026 already own credentials, managers, timeouts, bounds, redirects,
  and failure classification. Approval is another caller of that boundary, not a parallel HTTP
  stack.
  Date: 2026-08-23

- Decision: A transient notification failure throws before the `notify` result is journaled, so
  Keiro retries the approval child with its existing durable attempt/backoff policy. A permanent
  failure is journaled as a typed `ApprovalNotificationFailed` child result; the parent records
  `fail-session` and returns a permanent `AgentRunFailure`. A child that exhausts transient
  attempts is caught by the parent and mapped to the same permanent run failure with the child
  identity preserved in the diagnostic.
  Rationale: temporary transport/service failure may recover; invalid requests, forbidden
  credentials, and malformed responses will not. Neither class may silently approve or suppress
  a request.
  Date: 2026-08-23

- Decision: The resolution surface is a local administrative CLI command, not a new HTTP route.
  It is registered in `Shikigami.Server.Command`, requires the database only when executed, and
  calls the Shikigami-owned `resolveApproval` library function.
  Rationale: this is the smallest complete operator path and follows ADR 0021's rule that
  operator verbs wrap the owning library instead of reaching into private tables. A future HTTP
  handler can call the same function without changing the workflow contract.
  Date: 2026-08-23

- Decision: The one-shot resolution command uses `withServerTelemetry`, then constructs the
  Shikigami `AppEnv` with the resolved database settings, its tracer, and no process metrics.
  Rationale: this is the established composition boundary for administrative commands in the
  owning package; importing worker telemetry would invert the package graph and couple a local
  operator action to long-running worker resources.
  Date: 2026-08-23

- Decision: Do not add a Keiro DSL `signal` operation for `resolve-approval` in this plan.
  Rationale: the CLI is keyed by `AwakeableId`, whereas the DSL signal form identifies a declared
  await through a workflow key and label. ADR 0001 forbids declaring a generated operation the
  runtime does not execute.
  Date: 2026-08-23

- Decision: Keep the runtime `approvalWorkflowPatch` value hand-owned and assert that it is a
  member of generated `AgentRun.declaredPatches` in the deploy-simulation tests.
  Rationale: the pinned Keiro DSL generator exposes the authoritative set but no individual
  constant. The membership assertion detects spelling drift while preserving the existing
  runtime pattern for `patch` calls.
  Date: 2026-08-23


## Outcomes & Retrospective

The implementation carries approval from resolved process policy through a journaled parent
snapshot and dedicated child workflow to an authenticated, human-visible ask. The operator CLI
signals the opaque decision token through the owning core API; the worker resume registry advances
the child and parent, and only an approved sink reaches the existing outbox boundary. Replay tests
preserve pre-change parent journals, while fresh runs use only the child's static labels. Both
transports, approval/rejection/timeout, double resolution, fail-closed notification behavior, and
the at-least-once post crash window are covered automatically. The complete serial suite, Keiro
evolution gate, and a real Danwa/Kawa operator exercise all passed.

The manual exercise used `mori://shinzui/danwa/packages/danwa-server` on `127.0.0.1:18080`, the
repository's Kawa stub on `127.0.0.1:18088`, and a freshly migrated `shikigami_plan14` database.
The Danwa checkout's current head descends from Shikigami's pinned client commit and has no later
API/server changes. The worker announced this effective policy before starting its loops:

```json
{"event":"worker.approval.policy","mode":"required","required_sink_kinds":["KawaDigest"],"channel":"danwa","deadline_seconds":60}
```

Redacted approve transcript:

```text
run:    plan14-manual-approve-20260824
review: review_b48c1ef9-220c-59e9-b9ac-558841a3d9ee
token:  a4a55ade-…-401d
ask:    POST /conversations/.../messages -> 200
first:  resolved: true (exit 0)
repeat: resolved: false (unknown or already resolved) (exit 1)
kawa:   accepted source=shinzui/shikigami; outbox status=sent, attempts=1
```

Redacted reject and timeout transcript:

```text
reject run:    plan14-manual-reject-20260824
reject review: review_8ad637ab-7f78-58fe-b6d7-ccf58c644f1d
reject token:  497c9213-…-85b0
reject result: resolved: true; no additional outbox row

timeout run:    plan14-manual-timeout-20260824
timeout review: review_4461b54d-82b8-5299-968c-5ea855f7710f
timeout token:  bb939e61-…-c1d1
deadline:       3 seconds
timeout result: parent workflow and kioku session completed; no additional outbox row
```

The final operator `outbox list --source shinzui/shikigami` contained exactly the one sent row
from the approved run. All temporary processes were stopped and temporary configuration files
were removed. The isolated `danwa` and `shikigami_plan14` databases remain locally available for
auditing this transcript.


## Context and Orientation

This repository is split into seven packages. The parts relevant here are:

- `shikigami-core` owns domain types, durable workflow bodies, Keiro registry definitions,
  Settei's shared `AppConfig`, sink clients, and most workflow tests.
- `shikigami-workers` owns the long-running worker composition and supervision. Its
  `Shikigami.Workers.Command.Worker` builds `SinkHttp` once and its
  `Shikigami.Workers.Config.agentRunDeps` adapts `WorkerEnv` to the core workflow.
- `shikigami-server` owns the short-lived `shikigami` administrative executable. The dispatcher
  is `Shikigami.Server.Command`; each command returns an `AdminAction`, and only commands that
  need PostgreSQL call `requireDatabaseUrl` when they execute.

An agent run is the Keiro workflow `shikigami.agent-run`, implemented by
`Shikigami.Agent.Workflow` and declared by `domain/shikigami-agent-run.keiro`. The workflow
journals results by stable label and can suspend on timers, awakeables, or child workflows. The
resume registry is assembled in `Shikigami.Agent.Workflow.Resume.workflowRegistry`. The worker
also runs queue, outbox, timer, and telemetry loops; notification delivery is part of the approval
workflow, while an approved sink still ends the parent journal at outbox enqueue as required by
ADR 0022.

`Shikigami.Agent.Approval` currently defines `ApprovalRequest`, `ApprovalChannel`,
`ApprovalDecision`, `ApprovalRequirement`, `ApprovalEnv`, `awaitApproval`, deadline firing, and
`resolveApproval`. `awakeableNamed` allocates random v4 ids and journals them under a label before
exposing them. `signalAwakeable` atomically completes the row and appends the result, returns
`False` for an unknown or already-resolved token, and is safe to repeat. These are Keiro 0.14
contracts verified in `mori://shinzui/keiro/packages/keiro`; the repository pins 0.14.0.0 and the
upstream `keiro-0.14.0.0` tag exists.

Today `approveSinks` enumerates declared sinks and creates labels such as
`approval:KawaDigest:0`; `awaitApproval` derives `approval:KawaDigest:0:notify`. The at-risk Flow
uses the static `await-ack` label. The new child workflow removes those computed application labels
from fresh parent executions. Keiro's own reserved child steps still contain the child id, but the
DSL represents that family with a `child approval ...` body node, as it already does for delegation.

Any edit under `shikigami-core/src/Shikigami/Agent/` or
`shikigami-core/src/Shikigami/Flow/` must follow `docs/workflow-versioning.md`. A new parent body
shape requires a permanent patch declaration, a generated patch value, an active runtime branch,
old/new replay tests, and `just keiro-gate <merge-base>`. Generated files are regenerated by the
gate/scaffold and are never hand-edited or formatted. Keep the old false branch until operational
evidence says no pre-change instance can resume, then retire it under ADR 0004's procedure.

[ADR 0030](../adr/0030-an-approval-request-is-a-durable-child-workflow.md) owns this plan's child
workflow, policy snapshot, and split review/token identity. It applies
[ADR 0001](../adr/0001-declare-only-what-the-runtime-executes.md) to the absent signal operation,
[ADR 0004](../adr/0004-one-options-value-and-a-checked-patch-set.md) and
[ADR 0012](../adr/0012-a-declared-workflow-body-only-grows-behind-a-patch.md) to the compatibility
branch, [ADR 0007](../adr/0007-a-resolved-profile-is-a-run-local-policy-snapshot.md) to the
run-local policy snapshot, and
[ADR 0017](../adr/0017-rotate-to-make-a-label-static-rather-than-computing-it.md) to the computed
label family. [ADR 0013](../adr/0013-flow-bodies-reach-the-world-only-through-capabilities.md)
requires Flow to reach approval through its interpreter;
[ADR 0021](../adr/0021-operator-verbs-wrap-the-owning-library.md) governs the CLI;
[ADR 0022](../adr/0022-the-journal-ends-at-enqueue-and-receipts-own-delivery-truth.md) preserves the
outbox boundary; and
[ADR 0026](../adr/0026-outbound-sink-credentials-stay-opaque-and-http-policy-lives-at-the-process-boundary.md)
owns notification credentials and HTTP policy. Generated files remain unformatted under
[ADR 0002](../adr/0002-generated-code-is-not-formatted.md). The pre-v1 exception in
[ADR 0027](../adr/0027-the-first-release-establishes-one-clean-durable-baseline.md) is not assumed:
unless its facts are freshly re-proved during implementation, use the patch described here.

The approval channels are already production-capable. `Shikigami.Sink.Http.SinkHttp` owns the
authenticated Danwa `ClientEnv` and authenticated Kizashi `HttpEnv`.
`Shikigami.Sink.Danwa` already starts, joins, and posts to a fresh conversation for one-shot sink
delivery; factor that sequence so a caller can post rendered approval text without fabricating a
`Sink`. `Shikigami.Sink.KizashiClient.postSignal` accepts the existing `CreateSignalReq`, whose
`SignalType.AgentRequest` and `Priority.High` values live in `Shikigami.Agent.Decl`. Danwa's client
contract is verified at `mori://shinzui/danwa/packages/danwa-client`.

Follow the record conventions at `mori://shinzui/haskell-jitsurei/docs/core-record-patterns`:
fields are direct names such as `channel`, `deadline`, `request`, and `status`, strict where
appropriate, with `DuplicateRecordFields` handling repeated vocabulary. Do not introduce fields
such as `approvalPolicyChannel` or `approvalWorkflowStatus`.


## Plan of Work

### Milestone 1 — Declare the durable shape and compatibility patch

Start with the contract because it determines every runtime label. Add
`domain/shikigami-approval.keiro` to `domain/shikigami.keiro-workspace`. It declares the new
workflow, but no external operation:

```text
workflow Approval
  name "shikigami.approval"
  in ApprovalWorkflowInput {
    reviewRequestId:Id
  }
  out ApprovalWorkflowResult
  id from input.reviewRequestId via reviewRequestIdText
  body
    step ingest-approval -> ApprovalWorkflowInput
    step notify -> ApprovalNotificationResult
    await decision -> ApprovalDecision
```

Extend the parent `AgentRun.body` with one new patch block:

```text
patch shikigami-approval-workflow-v1 {
  step resolve-approval-policy -> ApprovalPolicySnapshot
  child approval id input via approvalWorkflowId -> ApprovalWorkflowResult
}
```

Leave the existing `await await-ack -> ApprovalDecision` declaration in place because the false
runtime branch can still execute it for an old instance. Update the specification comments: the
computed approval and notify labels now belong only to the legacy branch; the true branch is
represented by the approval child. Do not add `SignalAcknowledgement` or any other signal
operation.

Run `just keiro-scaffold`, review every generated path, wire the generated approval facts/runtime
module into the Cabal component and `Shikigami.Workflow.Versioning.shikigamiActivePatches`, and
update the create-once conformance expectations only as the scaffold instructs. Keiro DSL 0.14
does not generate individual patch constants, so keep the hand-owned `approvalWorkflowPatch`
value beside the approval runtime and assert that it belongs to the generated AgentRun patch set.

Before proceeding, add focused deploy-simulation tests. A workflow begun with the patch absent
must retain the direct legacy `await-ack` or auto-approved sink path when resumed by code whose
active patch set includes the new id. A fresh workflow must journal the true patch choice,
`resolve-approval-policy`, and a child relation, and must never append a new
`approval:<kind>:<ordinal>` or derived `:notify` application step. Test both flow and sink paths.

### Milestone 2 — Implement approval identity, policy, notification, and child runtime

In `Shikigami.Agent.Approval`, move or re-export `ReviewRequestId` as the approval-owned newtype
while preserving its current `Text` JSON encoding in `Shikigami.Attestation.Evidence`. Add a pure
derivation function over parent workflow name, parent workflow id, generation, and stable request
key. Use an explicit UUIDv5 namespace input beginning with `shikigami:approval-review:` and render
the public value as `review_<uuid>`. Add frozen-vector tests so the derivation cannot drift.

Add pure policy types, preferably in `Shikigami.Agent.Approval.Policy`, without importing
`Shikigami.App.Config` or `Shikigami.Sink.Http`; this avoids a configuration/HTTP import cycle.
The runtime snapshot contains the canonical `Set SinkKind`, `ApprovalChannel`, and
`NominalDiffTime`, derives explicit JSON instances, and exposes `requiresApprovalFor`. Keep parsing
helpers beside the type, but let `AppConfig` own Settei declarations and source precedence.

Add `Shikigami.Agent.Approval.Workflow` for the child body and parent-side spawn/await helper.
`requestApproval` obtains the parent workflow coordinates and generation, derives the review id
and child `WorkflowId`, calls `spawnChild`, appends `ingest-approval` to the child's journal as
delegation already appends `ingest-job`, then awaits the typed child result. Its stable request key
is `sink-<canonical-kind>-<declared-ordinal>` for a declared sink and the caller's durable
`StepName` prefixed with `flow-` for a Flow acknowledgement. The child registry body reads the
journaled input when resumed; it never consults mutable parent state.

The child allocates `awakeableNamed (StepName "decision")`, then runs
`step (StepName "notify")`. Render a bounded, human-readable message containing the prompt,
compact context, review id, opaque token, deadline, and exact CLI examples. Do not put credentials,
HTTP response bodies, or exception text into the message, journal, or logs. After a successful
notification, arm the existing deterministic approval deadline using the static `decision` label
and await the decision. Return `ApprovalResolved decision`. If notification permanently fails,
return `ApprovalNotificationFailed safeDetail` without arming or awaiting.

Refactor `Shikigami.Sink.Danwa` to export a direct `postText` helper returning
`Either DanwaError Text`. Reuse the existing authenticated `ClientEnv`, fresh conversation start,
join, and post calls; approval has no outbox delivery receipt, so the helper must not fabricate a
`DeliveryGuard` or a `DanwaConversation` sink. For Kizashi, build `CreateSignalReq` with
`AgentRequest`, `High`, the configured recipient, the prompt as intent, and context tags carrying
the review id; send it with the existing authenticated `HttpEnv`.

Map `DanwaHttpError` and `KizashiHttpError` through `httpFailureIsPermanent`. Treat Danwa usage or
receipt errors and Kizashi decode errors as permanent because repeating the same input cannot fix
them. Throw a dedicated synchronous exception for transient notification failures before the
`notify` step records a result. Let Keiro's current resume policy back off and retry up to its
configured attempt ceiling. Keep the successful post at-least-once: a process crash after the
remote accepted the ask but before the step commit may send the same review id and token again.

Add `approvalRegistry` and union it into the worker registry. The registry closes over the
process-lifetime notifier and database `AppEnv`; the child input supplies the session, policy
deadline, channel, request, and review identity. Extend `shikigamiActivePatches` with the generated
approval declared-patch set even if the new workflow currently declares none, so future approval
patches have the same single source of truth.

### Milestone 3 — Resolve configuration once and wire production

Extend `Shikigami.App.Config.AppConfig` and its applicative declaration with the two new settings.
`approval.require` accepts an empty value or a comma-separated set of exact canonical names:
`KawaDigest`, `KizashiSignal`, `ReiAction`, `DanwaConversation`, and `ChannelEgress`. Trim
surrounding whitespace, reject duplicate or unknown elements with an error that lists all valid
names, and treat an empty scalar as the empty set. `approval.channel`
accepts exactly `danwa` or `kizashi`. Bind both environment variables explicitly, update
`declaredKeys`, environment-binding, default, file/env/CLI precedence, malformed-winner, schema,
and explain-config tests in `Shikigami.AppConfigSpec`, and update
`config/shikigami.example.yaml` plus `docs/operations/configuration.md`.

At worker startup, build one `ApprovalPolicySnapshot` from the already-resolved `AppConfig` and
existing deadline, and one notifier from `SinkHttp`, `DanwaConfig`, `KizashiConfig`, and the
structured logger. Add both to `WorkerEnv` with direct record fields and pass them into
`AgentRunDeps` and the approval registry. Keep `defaultApprovalEnv` only for the false patch branch
and focused legacy tests. Log one secret-safe event such as `worker.approval.policy` before loops
start, with `mode`, `required_sink_kinds`, `channel`, and `deadline_seconds`; an empty set must be
reported as `mode=auto_approve`, not silently omitted.

In the true patch branch, journal `resolve-approval-policy` exactly once and pass that recorded
snapshot to both behavior interpretation and `approveSinks`. Change the Flow acknowledgement
interpreter to call the approval child helper when the patch is true and the existing direct
`awaitApproval` path when false. Make the true acknowledgement interpreter failure-aware: map
`ApprovalNotificationFailed` and caught `WorkflowChildFailed` values to the `Left Text` already
returned by `runFlowBehavior`, so the existing behavior failure branch records `fail-session`
instead of throwing and spending the parent workflow's own retry budget. Change `approveSinks`
similarly, returning `Either AgentRunFailure [Sink]`: only kinds selected by the journaled snapshot
spawn a child; unselected kinds pass through. An approval result keeps the sink; rejection or
timeout suppresses it. A permanent notification failure or failed child runs the existing
`fail-session` step and returns `PermanentAgentRunFailure` before `dispatch-sinks`.

Retain the current declared sink ordinal in the request key because `AgentDecl.sinks` is journaled
by `lookup-agent`; do not reuse that key as an application step label. Preserve sink ordering and
the outbox boundary: approvals decide which intents reach `enqueueSinkIntents`, and neither the
approval child nor notifier directly dispatches the approved sink.

### Milestone 4 — Add the operator command and automated end-to-end proof

Add `Shikigami.Server.Command.ResolveApproval` and register `resolve-approval` in
`adminSubcommands`. The parser accepts exactly one decision:

```bash
shikigami resolve-approval TOKEN --approve
shikigami resolve-approval TOKEN --reject REASON
```

Parse `TOKEN` as a UUID and construct the exported `AwakeableId`. Let optparse's existing
`usageExitCode` handle invalid UUIDs, missing decisions, and mutually supplied decisions. The
action calls `requireDatabaseUrl "resolve-approval"`, constructs `AppEnv` with the same connection
settings and `withRunTelemetry` composition used by workers, and invokes `resolveApproval`.
Success prints both the token and `resolved: true` and exits 0. An unknown, timed-out, or already
resolved token prints `resolved: false (unknown or already resolved)` and exits 1. Never query or
mutate Keiro's private tables directly, and do not make the CLI run a resume pass.

Extend `Shikigami.Server.CommandSpec` so the top-level command list, help coverage, UUID parser,
mutual exclusion, and reject reason are pinned. Put effectful command behavior behind a small
helper so tests can assert exit selection without spawning the executable; retain one database
integration case for real `resolveApproval` semantics in core.

Build the automated acceptance proof around the existing WAI/Warp Danwa and Kizashi stubs in
`Shikigami.AgentWorkflowSpec`. Run a fresh heartbeat agent with `KawaDigest` required. Assert that
the parent records the policy snapshot and child relation, the child records one notify result and
suspends, and the captured ask contains the same typed review id and token as the journal. Resolve
through the same render/parse boundary as the CLI, drive the existing timer/resume helpers, and
assert one outbox intent for approval, none for rejection, and none for timeout. Repeat the signal
and prove it returns false and creates no second intent.

Add failure cases: Danwa and Kizashi 5xx/transport failures leave `notify` unrecorded and increment
the child's retry attempt; 400/401/403/404 or invalid response records permanent notification
failure, fails the parent session, and does not retry or enqueue. Add a crash window test in which
the remote accepts the ask before the local step commit; replay may post twice, but both asks must
carry the same review id and awakeable token and only one decision can win.

### Milestone 5 — Gate, full validation, and manual transcript

Run the generated-code/evolution gate from the repository's merge base, build every component,
run focused tests, then run the complete suite serially. The repository has observed intermittent
parallel test failures, so final evidence uses `cabal test all -j1`. Run `nix fmt` only on
hand-owned sources; generated Keiro output is excluded by ADR 0002.

Finally, exercise a real configured Danwa or Kizashi service and record the redacted transcript in
Progress and Outcomes. The automated stub proof remains the self-contained acceptance test; the
manual exercise verifies operator ergonomics and the production process composition.


## Concrete Steps

Run every command from `/Users/shinzui/Keikaku/bokuno/shikigami`.

First establish the merge base used by the workflow gate and inspect the current tree:

```bash
git status --short
git rev-parse HEAD
```

After editing the DSL, scaffold and run the evolution gate, replacing `<merge-base>` with the
commit printed above:

```bash
just keiro-scaffold
just keiro-gate <merge-base>
```

Use focused tests while implementing:

```bash
nix develop -c cabal test shikigami-core-test --test-option -p --test-option approval
nix develop -c cabal test shikigami-core-test --test-option -p --test-option configuration
nix develop -c cabal test shikigami-workers-test --test-option -p --test-option worker
nix develop -c cabal test shikigami-server-test --test-option -p --test-option "administrative command line"
```

Then run final validation:

```bash
nix fmt
nix develop -c cabal build all
nix develop -c cabal test all -j1
just keiro-gate <merge-base>
git status --short
```

For the manual path, add the following values to an untracked local configuration file or pass
them with `--set`; do not commit credentials:

```yaml
approval:
  require: KawaDigest
  channel: danwa
  deadline_seconds: 60
```

With PostgreSQL migrated and Danwa running at the configured URL, use four terminals. The local
Kawa stub makes the final delivery visible without a second repository:

```bash
# terminal 1
nix develop -c cabal run shikigami-worker -- --config config/shikigami.example.yaml --set approval.require=KawaDigest --set approval.channel=danwa
```

```bash
# terminal 2
nix develop -c cabal run shikigami -- stub-kawa --port 8088
```

```bash
# terminal 3
nix develop -c cabal run shikigami -- grants grant heartbeat KawaDigest --by plan-14-demo
nix develop -c cabal run shikigami -- enqueue-run heartbeat --key approval-demo-approve
```

Read the approval message in Danwa. It must show a `review_...` identifier, an opaque UUID token,
the prompt, deadline, and both resolution forms. Copy the token, then:

```bash
# terminal 4
nix develop -c cabal run shikigami -- resolve-approval TOKEN --approve
nix develop -c cabal run shikigami -- resolve-approval TOKEN --approve
```

The first command prints `resolved: true`. The second exits 1 and prints the already-resolved
message. Enqueue a distinct key and reject it:

```bash
nix develop -c cabal run shikigami -- enqueue-run heartbeat --key approval-demo-reject
nix develop -c cabal run shikigami -- resolve-approval NEW_TOKEN --reject "manual rejection proof"
```

For timeout, enqueue one more distinct key with a short `approval.deadline_seconds`, do not resolve
it, and observe the timer worker complete the child with `TimedOut` and the parent suppress the
sink. Record identifiers only in redacted or test values; never paste credentials or authorization
headers into this plan.


## Validation and Acceptance

Acceptance is behavioral and durable, not merely a compiling command.

Configuration acceptance requires `--describe-config` and `--explain-config` to show all three
approval keys and their sources. Empty `approval.require` resolves to auto-approve. An unknown
kind or channel makes `--check-config` exit with the reserved configuration status before opening
PostgreSQL or constructing HTTP clients. Environment, file, and `--set` precedence follow every
other `AppConfig` key.

Workflow acceptance requires the Keiro DSL and generated facts to contain the new approval
workflow and parent patch. Fresh agent runs journal `resolve-approval-policy` and use only the
child's static application labels. Old journals replay the false branch without looking for new
steps. `just keiro-gate <merge-base>` and its conformance target pass.

Identity acceptance requires a frozen `ReviewRequestId` vector, stability across crash/resume,
and distinct review ids for different parent generations or request keys. The awakeable token is
random, stable only because Keiro journals it, and unequal to the review id. Moving the type does
not alter the JSON emitted or accepted by `Shikigami.Attestation.Evidence`.

Notification acceptance requires an authenticated request through the existing `SinkHttp` object.
The message contains no secret material and does contain the prompt, bounded context, review id,
token, deadline, and executable resolution command. A successful notify is journaled once; a
crash-before-commit retry may duplicate the remote ask with identical identity. Transient failures
retry under Keiro's durable attempt policy. Permanent failures fail closed and never arm a timer,
await a decision, dispatch a sink, or loop forever.

Resolution acceptance requires approve, reject, timeout, unknown token, and double-resolution
cases. Approval yields exactly one sink outbox intent; rejection and timeout yield zero. The CLI
only signals the awakeable and returns; the worker resume loop advances child and parent. Flow
acknowledgement is covered independently of sink policy and sends a visible ask even when
`approval.require` is empty.

The final evidence is green focused tests, `cabal build all`, `cabal test all -j1`, `nix fmt`,
`just keiro-gate <merge-base>`, and the manual transcript recorded in this living plan.


## Idempotence and Recovery

The plan adds no schema migration or bespoke approval table. Keiro owns the parent/child relation,
child journal, awakeable row, timer, retries, and terminal failure state. Kioku owns the agent
session, and the existing `fail-session` step records approval-notification failure there.

`ReviewRequestId` and the approval child `WorkflowId` are deterministic from journal-stable parent
coordinates and a stable request key. Re-running `spawnChild` attaches to the existing child.
Appending `ingest-approval` uses the same idempotent journal rule as delegated `ingest-job`.
`awakeableNamed "decision"` replays the already-journaled random token. The timer id remains UUIDv5
over the approval child identity, generation, and static decision label, so repeated arming is
first-write-wins. `signalAwakeable` is atomic and one-shot.

Notification is intentionally at-least-once rather than exactly-once. If the remote accepted the
message but the local `notify` step did not commit, a retry posts it again. The repeated review id
and token let a human recognize the duplicate, and only one resolution can succeed. Do not add an
approval-specific receipt table in an attempt to hide this unavoidable distributed commit window.

A transient notification exception is retried with Keiro's persisted attempts and exponential
backoff. At the configured ceiling the child is terminally failed and the parent maps that failure
to its normal permanent failure path. After an operator repairs the downstream service or
credential, the existing Keiro operator resurrection command can retry the failed child; preserve
the child workflow registry entry while any instance exists. A permanent typed notification
failure does not need resurrection unless code or configuration changes make the same request
valid; starting a new agent run is the normal retry.

Rollback must not simply remove the patch id, approval workflow registry entry, or false branch.
Disable new sink approvals with an empty `approval.require` while keeping the code capable of
resuming existing approval children. Retire the patch and legacy labels only after the operational
drain evidence required by `docs/workflow-versioning.md` and ADR 0004. Generated files are restored
by rerunning the scaffold from the matching DSL, never by hand.


## Interfaces and Dependencies

The precise module split may be adjusted to avoid cycles, but the hand-owned domain surface should
remain equivalent to:

```haskell
newtype ReviewRequestId = ReviewRequestId {value :: Text}
  deriving stock (Eq, Ord, Show, Generic)
  deriving newtype (ToJSON, FromJSON)

data ApprovalPolicySnapshot = ApprovalPolicySnapshot
  { requireFor :: !(Set SinkKind),
    channel :: !ApprovalChannel,
    deadline :: !NominalDiffTime
  }

data ApprovalWorkflowInput = ApprovalWorkflowInput
  { reviewRequestId :: !ReviewRequestId,
    sessionId :: !SessionId,
    request :: !ApprovalRequest,
    deadline :: !NominalDiffTime
  }

data ApprovalWorkflowResult
  = ApprovalResolved !ApprovalDecision
  | ApprovalNotificationFailed !Text

data ApprovalNotificationError
  = TransientNotification !Text
  | PermanentNotification !Text

reviewRequestIdFor :: WorkflowName -> WorkflowId -> Int -> Text -> ReviewRequestId
reviewRequestIdText :: ReviewRequestId -> Text
approvalWorkflowId :: ReviewRequestId -> WorkflowId
requiresApprovalFor :: ApprovalPolicySnapshot -> SinkKind -> Bool
```

The notification seam carries process resources but never crosses JSON or the journal:

```haskell
data ApprovalNotifier = ApprovalNotifier
  { recordPark :: !(SessionId -> ReviewRequestId -> AwakeableId -> ApprovalRequest -> IO ()),
    postAsk :: !(ReviewRequestId -> AwakeableId -> NominalDiffTime -> ApprovalRequest -> IO (Either ApprovalNotificationError ()))
  }

postText :: ClientEnv -> DanwaConfig -> Text -> IO (Either DanwaError Text)
```

The durable helpers expose a registry and a parent-side request operation; exact effect rows should
follow the existing delegation and agent workflow rather than introducing a second runner:

```haskell
approvalRegistry :: ApprovalWorkflowEnv -> WorkflowRegistry AppEffects

requestApproval ::
  (Workflow :> es, Store :> es, IOE :> es) =>
  Text ->
  SessionId ->
  ApprovalRequest ->
  NominalDiffTime ->
  Eff es ApprovalWorkflowResult
```

The CLI continues to consume the existing external completion interface:

```haskell
resolveApproval :: AppEnv -> AwakeableId -> ApprovalDecision -> IO Bool
```

Repository-local dependencies are `Shikigami.Agent.Approval`,
`Shikigami.Agent.Workflow`, `Shikigami.Flow.Acknowledgement`, `Shikigami.App.Config`,
`Shikigami.Sink.Http`, `Shikigami.Sink.Danwa`, `Shikigami.Sink.KizashiClient`,
`Shikigami.Workers.Config`, `Shikigami.Agent.Workflow.Resume`,
`Shikigami.Workflow.Versioning`, and `Shikigami.Server.Command`. The relevant accepted decisions
are ADRs 0001, 0002, 0004, 0007, 0012, 0013, 0017, 0021, 0022, 0026, 0027, and 0030.

External dependencies are the pinned and verified
`mori://shinzui/keiro/packages/keiro` 0.14.0.0 API and
`mori://shinzui/danwa/packages/danwa-client` at the commit already pinned by this repository. No
new package dependency is expected: `uuid`, `containers`, `aeson`, `optparse-applicative`, WAI/Warp,
Keiro, and Danwa are already in the owning components. If implementation discovers a missing
dependency, locate its current source and docs with Mori and verify its released version and
upstream tag before changing Cabal bounds.


## Revision Notes

- 2026-08-23: Implemented the durable approval child, replay-safe parent patch, stable review
  identity, authenticated Danwa/Kizashi notifications, typed Settei policy, production worker
  composition, operator resolution CLI, automated durability/failure proofs, and real-service
  approve/reject/timeout transcript. Passed the evolution gate and all 737 serial tests.
- 2026-08-23: Recorded that Keiro DSL 0.14 exposes the checked patch set but no individual patch
  constants, and changed the runtime-binding instruction to require a generated-set membership
  assertion instead.
- 2026-08-23: Re-audited and comprehensively rewrote the plan after the package split, Settei
  adoption, authenticated `SinkHttp`, supervised resume loop, checked Keiro DSL, workflow
  versioning ADRs, and run-evidence vocabulary landed. Removed completed prerequisite work and
  stale file/line references. Replaced undeclarable computed labels for fresh runs with a patched
  approval child workflow, made approval policy a journaled run-local snapshot, corrected the CLI
  location to the server administrative dispatcher, preserved `ReviewRequestId` wire compatibility,
  and removed the invalid proposed DSL signal operation because resolution is keyed by opaque
  `AwakeableId`. Recorded the durable architecture in
  `docs/adr/0030-an-approval-request-is-a-durable-child-workflow.md`.
- 2026-08-05: Assigned this plan ownership of a stable typed review-request identifier used by run
  attestation and later lookup.
- 2026-07-22: Rebased policy configuration on Settei and made authenticated outbound clients and
  typed HTTP failure classification hard dependencies.
- 2026-07-08: Created the original plan for a production policy, notifier, and resolution path.
