---
id: 78
slug: run-external-operations-from-durable-flows-through-idempotent-shiki-jobs
title: "Run external operations from durable Flows through idempotent shiki jobs"
kind: exec-plan
created_at: 2026-10-02T19:43:12Z
intention: "intention_01m3z248g0ek495ygqwp305emh"
provenance:
  created_by:
    model: "claude-opus-5-5"
    harness: "claude-code"
    at: 2026-10-02T19:43:12Z
  revisions:
    - model: "claude-opus-5-5"
      harness: "claude-code"
      at: 2026-10-02T19:56:31Z
      mode: "update"
      note: "Made the executor generic: Dhall executor catalog with submit/observe templates; no shiki code in Shikigami"
    - model: "gpt-6.2-astra"
      harness: "codex-cli"
      at: 2026-11-21T13:27:28Z
      mode: "update"
      note: "Rebased the generic external-job capability on accepted attempts, the v1 workflow and SDK boundaries, recorded authority and an examples-pack proof. Separated the two upstream acceptance gates."
  reviews:
    - model: "gpt-6.2-astra"
      harness: "codex-cli"
      at: 2026-11-21T13:26:45Z
      verdict: "changes-requested"
      note: "Original plan predates the pack and authority boundaries, the accepted-attempt runtime and the frozen durable baseline. Its live restart procedure cannot prove adoption."
---

# Run external operations from durable Flows through idempotent shiki jobs


## Purpose / Big Picture


A Flow author should be able to submit a long-running external job, wait across restarts, and use its result to decide whether to proceed or ask a human. The motivating runbook has a ten-hour maintenance window inside a multi-day BAREIS repair. This plan delivers the reusable capability and a harmless proof Flow. The service-specific repair belongs to its owning project. See `mori://tan/mls-service-v2/masterplans/10-isolate-mls-identity-from-constellation1-key-drift-and-repair-the-corrupted-bareis-streams`.

An operator supplies a named **executor** in a Dhall catalog, a typed configuration file. Its submit command returns a **handle**, the external system's identifier for the accepted work. Its observe commands take that handle and report progress. A Flow supplies a stable step key, a permitted target, arguments and a deadline. It receives one of six outcomes: succeeded, failed, unknown, timed out, denied or rejected. The job continues independently when Shikigami stops waiting.

The first live example runs a BusyBox echo through shiki on a disposable Kubernetes cluster. The proof is a completed Flow, a matching run in shiki's history and, for a backend that supports adoption by operation ID, exactly one Kubernetes Job even after losing the submit response. Shiki is selected by operator configuration. The shipped Haskell, schemas, manifests and stub tests remain tool-independent.


## Progress


- [x] (2026-10-02) Filed the exact submission authorization request. Its contract and current status are recorded in `mori://shinzui/kikan-en/okf/improvement-requests/concepts/IR-4`.
- [ ] M1. A typed request, outcome and validated executor catalog pass literal-argument, status and compatibility tests.
- [ ] M2. A worker executes and recovers a fake external submission through the existing PostgreSQL accepted-attempt path, including the lost-response case.
- [ ] M3. A versioned child workflow returns the six outcomes to an examples-pack Flow through the SDK and survives worker and scheduler restarts.
- [ ] M4. The Kikan distribution obtains and records a fresh exact decision for each actual submission. Unmapped or refused actions launch zero commands.
- [ ] M5. The deployed worker loads an optional catalog and runs bounded submit and observe commands. Stub executables demonstrate the process and configuration contract.
- [ ] M6. The operator guide, Flow guide and live evidence cover both restart boundaries. Exactly-one-job acceptance requires a shiki build that implements adoption.

At the 2026-11-21 review, the working tree at `d9d18d23` contained the underlying execution, pack and authority machinery. All six feature milestones remain open. M1–M3 and the stub coverage in M5 can proceed independently of both upstream releases.


## Surprises & Discoveries


The October plan assumed that submit belonged inside a journaled step and that a scheduler timer should run the observe command. Shikigami now has a queue for already accepted attempts, with durable claims, dispatch-start evidence, late receipts and bounded recovery. MasterPlan 14 explicitly requires a future external executor to consume that contract. The current resume loop also sets concurrency from runtime capacity and supports lease heartbeats. A workflow can park while a worker runs a short command. [MasterPlan 14, shared interfaces](../masterplans/14-deliver-adaptive-autonomous-objectives-with-durable-workers.md)

The rewrite removed the global Flow list and the core's dependency on Kikan authorization types. A pack contributes a Flow to a distribution, and an authority adapter maps the kernel's action to the external service. The examples-only admin validates the ordinary at-risk manifest. Its Kikan qualification variant, which uses a Kizashi output, validates with the Kikan admin. The same composition distinction matters for this proof.

At review, the shiki upstream head `881851b` had quick submit, sync and JSON show, and the run parser had no `--operation-id`. Kikan-En's contract at Shikigami's configured source revision `16704290` and upstream head `84391b3a` lacked an external-job action. Both requests are still marked proposed. [Shiki adoption request](mori://shinzui/shiki/okf/improvement-requests/concepts/IR-1) and [Kikan-En action request](mori://shinzui/kikan-en/okf/improvement-requests/concepts/IR-4)


## Decision Log


2026-10-02. Keep the executor generic. Operators own the programs, fixed argument templates, target allow-lists and output mappings. Flow code owns the requested operation and its repeat-safety declaration. Model output cannot select an executable, target, operation key or retry policy. There is no cancel command. Ending a wait returns the best available identity for an operator to investigate.

2026-11-21. Retain a keyed durable child for the wait. Give the execution subsystem ownership of actual attempts and give the scheduler only durable wakes. The trigger for this change was the accepted-attempt contract shipped after the original plan. Accounting, dispatch fencing and late receipts need the same owner when the external program returns in milliseconds and the remote job runs for days.

2026-11-21. Add the small Flow capability as a kernel primitive with a concrete SDK consumer in the examples pack. A declared tool already runs a local command to exit and can report an uncertain launcher. A remote handle, repeated observations and adoption of an accepted job are additional semantics. Today's playbook vocabulary cannot express that protocol with its existing Tool step. Playbooks remain the first choice for procedures they can express. The existing playbook and local-operator grant formats cover their current use cases. [Playbook decision](../adr/0128-playbooks-are-the-default-extension-mechanism.md) and [kernel and pack ownership](../adr/0129-the-kernel-owns-primitives-and-use-cases-ship-as-declarations-or-packs.md)

2026-11-21. Keep the original production authority requirement. Add a kernel action for submission and its exact mapping in the Kikan binding. Local-operator, unconfigured hosts and unmapped bindings refuse it. A catalog entry alone confers no authority. The observation protocol is operator-owned reconciliation of an already accepted handle, restricted to that operation's target. It cannot start work or take an arbitrary handle from a Flow. [Kernel authority](../adr/0123-the-kernel-owns-its-action-vocabulary-authority-port-and-action-record.md) and [trust tiers](../adr/0124-authority-is-selected-by-trust-tier-and-the-local-operator-grants-a-declaration-once.md)


## Outcomes & Retrospective


The November review corrected the implementation path and qualification procedure. Using the existing build, all ten kernel-boundary tests passed against the working tree. These checks establish the starting architecture. Feature and cluster evidence belongs here as each milestone completes.


## Context and Orientation


**From declaration to Flow.** `schema/Agent.dhall` defines `Behavior.Flow` and `Trigger.Event`. `shikigami-core/src/Shikigami/Flow.hs` owns `FlowEffects`. Bodies can call replay-safe capabilities. The IO and database interpreters live outside the body. `shikigami-core/src/Shikigami/Flow/Pack.hs` composes a `FlowRegistry` from `FlowPack` values. `runFlowBehavior` in `shikigami-core/src/Shikigami/Agent/Workflow.hs` looks up the selected pack Flow and installs its interpreters. `packs/flow-pack-examples/src/FlowPack/Examples.hs` registers example bodies with `kernelCapabilityFlow`. `packs/kikan-shikigami/src-shared/Packs.hs` composes those examples with the Kikan binding for the admin, worker and scheduler. Stock roles start with the builtin pack. [Flow capability rule](../adr/0013-flow-bodies-reach-the-world-only-through-capabilities.md), [disposition of example Flows](../adr/0130-use-case-subsystems-leave-the-kernel-by-recorded-disposition.md) and [distribution ownership](../adr/0131-one-kernel-is-composed-two-ways-and-kikan-services-are-bindings.md)

**From Flow key to durable child.** A journal is Keiro's durable record of completed workflow steps. On replay it returns their saved values. `shikigami-core/src/Shikigami/Flow/DeclaredTool.hs` and `shikigami-core/src/Shikigami/DeclaredTool/Workflow.hs` show the keyed child call, input handoff and await. `agentRunRegistry` includes that child family. `shikigami-core/src/Shikigami/Workflow/Registry.hs` composes the service registry used on restart. For the new family, derive IDs from versioned, structured parent name, ID, generation and caller key. Generate an opaque child ID from those bytes. Two different tuples must remain distinct even when their text contains separators. [Keyed children](../adr/0023-delegation-is-governed-at-the-child-spawn-boundary.md) and [structured identities](../adr/0086-versioned-structured-coordinates-identify-delegated-and-http-runs.md)

**From accepted work to an actual command.** An operation identifies the logical work. An attempt identifies one opportunity to dispatch it. The queue carries only an `Attempt.JobReference`. The claim identifies the worker and its generation so an expired worker cannot overwrite a later result. Read `shikigami-core/src/Shikigami/Execution/Transcript.hs`, `shikigami-core/src/Shikigami/Execution/Attempt.hs`, `shikigami-core/src/Shikigami/Execution/Store.hs` and `shikigami-core/src/Shikigami/Execution/Executor.hs`. `shikigami-workers/src/Shikigami/Agent/RunJob/Worker.hs` delivers the reference through `executeAcceptedOperation`. Current operation kinds and snapshot admission cater to model, tool and typed-decision work. A deterministic external Flow needs a real, model-free admission path into this machinery. That is the first integration risk in M2. [Accepted operation implementation](83-recover-durable-model-and-tool-turns-with-composed-policies.md), [capacity at the claim](../adr/0109-runtime-capacity-admission-shares-accepted-attempt-fences.md) and [permit recovery](../adr/0132-a-stopped-process-instance-releases-its-runtime-permits.md)

**Workflow and API compatibility.** `cabal.project` pins the Keiro runtime and DSL to 0.22.0.0. The Language 6 manifest is `domain/shikigami.keiro-workspace`. Its member files include `domain/shikigami/agent-run.keiro` and `domain/shikigami/declared-tool.keiro`. The tagged baseline `api-baseline-v1` is commit `89151747`. Changes to existing bodies require a real patch branch or a new workflow name. Existing journal encodings must still decode. The stable SDK and kernel ports have reviewed export pins. [V1 baseline decision](../adr/0133-the-v1-baseline-names-every-public-surface-and-a-change-obeys-its-stability-level.md), [workflow versioning](../workflow-versioning.md), [declared-body evolution](../adr/0012-a-declared-workflow-body-only-grows-behind-a-patch.md) and [API baseline](../architecture/api-baseline.md)

**Who authorizes and who runs a command.** `shikigami-core/src/Shikigami/Authority.hs` defines `Action`, `Authority`, `scopeToRun`, and `recorded`. A failed append to the action record refuses the action. `packs/kikan-shikigami-binding/src/Kikan/Shikigami/Binding/Authority.hs` owns the service mapping and proof verification. Its contract comes from the source-repository pin in `cabal.project`. `shikigami-core/local-host/Shikigami/Workspace/Local/Launcher.hs` demonstrates an argv launcher with a cleared environment, bounded drains and process-group settlement. The host component is a Cabal sublibrary distinct from the domain library. The worker owns composition and supplies the executor port. [Fresh exact authorization](../adr/0036-external-agent-actions-require-fresh-exact-authorization.md) and [process adapter boundary](../adr/0125-host-process-adapters-live-in-a-public-local-host-sublibrary.md)


## Plan of Work


### M1. Define the executor contract and make it testable


Add the typed request, result and pure catalog interpretation under `shikigami-core/src/Shikigami/Execution/ExternalJob/`. Keep the core implementation in the internal library of `shikigami-core/shikigami-core.cabal`. Write the ADR for the new primitive using the next available local ADR number at implementation time. The original plan's suggested ADR 0040 is already occupied. Explain why a declared tool alone cannot implement recovery by external handle. Check ownership in `tools/style/module-ownership.json` and introduce only the public names the proof requires.

The request contains executor, environment, service, bounded argument vector, positive wait duration, optional bounded poll interval, and a repeat-safe flag defaulting to false. Use the existing `Shikigami.Execution.Identity.OperationId`. Derive a stable external key in the portable alphabet `[A-Za-z0-9._:-]` of at most 200 characters from the accepted submission identity. This key survives new actual attempts and child generation rotation. Keep the accepted request and executor definition digest together. The same key with different request bytes or a different definition must conflict before dispatch. Keep the operation ID even if a response containing the handle was lost. Accept matching replays by comparing their retained fingerprint. Test a changed service, argv, principal or executor revision under the same parent key.

Use `schema/Executor.dhall` for a list of named definitions. Each supplies a fixed executable and argv for submit, an ordered nonempty list for observe, a working directory, explicit environment bindings, allowed environments and services, a single-capture handle pattern, status and optional exit-code JSON fields, status map, optional conflict exit code, polling interval, command timeout and `submitRepeatSafe`. Allow only whole-element placeholders `{environment}`, `{service}`, `{operationId}`, `{args}` and observe-only `{handle}`. Expand `{args}` to zero or more literal arguments. Validate duplicate names or mappings, empty programs or targets, misplaced tokens, invalid capture count, invalid bounds and unusable status maps at startup. At admission, bound the number of observations implied by the deadline and interval to fit the execution store's cursor limit (currently 10,000 operations, including submission). Compute one poll from the current state after downtime, so missed intervals cannot cause a burst of attempts. Keyed adoption requires submit to actually receive the operation ID. A repeat-unsafe executor admits only requests explicitly marked safe to repeat.

Use a versioned codec for the six Flow outcomes and durable request and receipt data. A terminal report carries an optional exit code and bounded, non-secret diagnostic. Unknown or timed-out outcomes carry the operation ID and any known handle. Test round trips, malformed inputs, deterministic IDs, changed-request conflicts, literal metacharacters, status mappings and the two repeat-safety flags. A fake accepts a key and fingerprint, returns a stable handle, and counts attempts separately from jobs created. Give tests control over response loss, terminal status, the clock and transient observation errors.


### M2. Prove accepted dispatch and recovery with PostgreSQL


Start with one producer/consumer path. A model-free Flow admission with a run principal and the run's existing resource scope accepts one fake submission, enqueues a reference, dispatches through the worker, and observes the committed handle on a second connection. Anchor this in `shikigami-core/test-postgres/Shikigami/ExecutionTranscriptSpec.hs`. Add an external-job test group alongside it. Use a real run-job delivery, two worker connections and the migrated database fixture. Polling builds on the handle recovered by this test.

Introduce a versioned external-job admission alongside the model-specific `ExecutionSnapshot`. Pin the parent run, verified principal, optional inherited root, child, absolute deadline, validated target, recovery class and protected request reference. An addressed proof run can arrive without a root. Preserve the existing per-execution capacity fallback in that case. An enrolled run keeps its root and its limits through every attempt. Factor common attempt transitions where the current store or executor demands a model selection. Extend the operation input, dispatch and outcome cases to distinguish external submission and observation. Preserve the existing operation-ID check against execution identity and cursor. Give each submission one logical operation, each scheduled observation its own logical operation, and keep the original submit key in all observation references. Old snapshots, queue references and tool calls must still round-trip and take their original paths.

Use `acceptOperation`, `submitExecutionAttemptWith` and the run-job queue's transaction callback for prepared work. Reservation, capacity ticket, attempt and enqueue share the existing submission transaction. The delivering worker claims the exact attempt, validates its resource scope, records dispatch start and obtains the fresh action decision for submission. Recheck the live claim, pinned definition and deadline immediately before launching the injected executor outside the transaction. A policy refusal or authorization outage is known to have launched zero commands at that boundary. Record that fact. Persist the handle or uncertainty and publish the owning wake from the durable receipt. Queue redelivery, worker death or a stopped process permit never constitutes evidence that the external job failed.

Inject a failure *after the fake has accepted* and *before the handle is persisted*. Drop the first worker, let its claim become recoverable, and let another worker drive recovery. `recoverExecutionAttemptWith` reserves a new actual attempt under the same logical operation only for a permitted recovery class and within the existing recovery ceiling. Reauthorize immediately before adoption. Assert two dispatches, the same external key and fingerprint, one external job, one terminal result, correct permit settlement and a stale owner's inability to publish a different result. Exercise late receipts and concurrent duplicate queue delivery. Prove that a repeat-unsafe request on an adopting executor can recover, and that a request on a backend without adoption can retry only when the Flow explicitly marked the operation safe to repeat. Also prove that bare queue redelivery cannot launch a second command and that exhausted or unsafe recovery reports uncertainty. This milestone uses a recorded fixture authority.


### M3. Give the Flow a versioned child and ship the proof in a pack


Add `domain/shikigami/external-job.keiro` to `domain/shikigami.keiro-workspace`. Its child family is `shikigami.external-job`. Add the entire new child declaration to a fresh `patch shikigami-external-job-v1 { … }` block in `domain/shikigami/agent-run.keiro`. Use the generated guard in the actual interpreter and the generated patch set consumed by `shikigami-core/src/Shikigami/Workflow/Versioning.hs`. The false branch preserves old Flow execution and cannot spawn the new child. Regenerate the runtime and update reviewed conformance expectations. Seed a parent with the old patch set, resume it after the change, then run a new parent and demonstrate the different child histories.

Implement the child in `shikigami-core/src/Shikigami/Execution/ExternalJob/Workflow.hs` and its Flow effect in `shikigami-core/src/Shikigami/Flow/ExternalJob.hs`. Use `shikigami-core/test-postgres/Shikigami/DeclaredToolFlowSpec.hs` for the parent/child test pattern. Thread its runtime into `AgentRunDeps`, `agentRunRegistry`, `FlowEffects`, `runFlowBehavior` and test hosts. A child ingest stores a reference to its immutable admitted input. Use Keiro's prepared journal append and classify duplicate versus conflicting input. Make replay repair interruption between child creation and input publication. A complete child returns its recorded outcome to the caller.

Declare static labels for ingest, advancing one transition, waiting on the current attempt or next poll, and rotating with `continueAsNew`. A generation is one journal segment. Its seed points to the original accepted operation and deadline. It never recomputes those from the wall clock. Follow `shikigami-core/src/Shikigami/Execution/Driver.hs` and `shikigami-core/src/Shikigami/Execution/Timer.hs` for a generation-owned wake, a durable notification that makes a parked workflow runnable. Arrange a wake at the earlier of the next check and the absolute deadline, including while submit is outstanding. Bind it to the child, generation and matching wait. Repair an interrupted arm or receipt publication on replay. Route any new wake kind through `shikigamiTimerFallback` in `shikigami-workers/src/Shikigami/Trigger/Scheduler.hs`. Both the standalone scheduler and `runTimerPass` in `shikigami-workers/src/Shikigami/Trigger/Timer.hs` call this dispatcher. Test a due row with either consumer, including a duplicate delivery. Neither timer path executes commands or needs executor credentials.

On wake, read accepted state. Return a committed terminal result, submit a due observation, or park again. Pending, running and transient observations schedule a bounded next check. Use the database clock and conditionally settle the logical wait once. A terminal receipt committed before the cutoff wins even if delivered late. Once the deadline wins, no new attempt may dispatch and no stale wake may rearm. In-flight calls may still report factual receipts. The remote job keeps running. Drive success, failure, unknown, timeout, denial and rejection through the parent with a fake. Cover down-time across the deadline, duplicate and stale wakes, and a failure before a handle exists.

Expose the checked key, request builder, `runExternalJob key request` and outcome inspection through `shikigami-core/src/Shikigami/Flow/Sdk.hs` and its Cabal facade. Rebuild existing pack consumers and interpreter harnesses. Keep IO, raw configuration, and the ability to assert a principal outside the body SDK. Put `ExternalJobProof.hs` in `packs/flow-pack-examples/bodies/FlowPack/Examples/Body/`, register `external-job-proof` in `examplesPack`, and add `packs/flow-pack-examples/agents/external-job-proof.dhall`. Follow the pack's manifest and label tests. Use the stable key `examples-external-job-echo`, an event trigger, explicit proof principal, fixed target and repeat-safe echo arguments constructed by the body. The event supplies only a bounded message. The pack returns a structured result. Prove that the composed distribution discovers it, a stock registry does not, and replay of the completed parent issues zero new submissions.


### M4. Authorize through the kernel port and map the exact action in Kikan


Add an external submission constructor to `Shikigami.Authority.Action` alongside its first dispatch call site. The action contains the executor, environment, service, operation ID and a SHA-256 digest of the expanded argument vector. Use the exact canonical encoding agreed with the Kikan contract. Cover argument order, empty elements and whitespace in proof-binding tests. Bind the request to the pinned definition so a changed executable, working directory or target cannot inherit a previous admission. Validate each component before rendering the action resource. Scope the composed, recorded authority to the accepted run, agent and principal in the queue worker, including on recovery. A policy denial ends a fresh submission as denied. Invalid input is rejected. Service outages, proof-verification failures and unavailable recording refuse dispatch and use bounded retry within the original deadline. Test an allow, revocation between attempts, `PolicyDenied`, invalid coordinates, rejected proof, unavailable service, and action-record append failure. Assert zero launches after each refusal. When a previous dispatch may already have happened, preserve its uncertainty and any known handle even if renewed authorization is denied.

The exact Kikan action is an upstream deliverable. When the requested contract ships, check its actual target, proof-bound invocation fields and service grant against the adopted contract. Verify the released source/pin before updating the Kikan packages in `cabal.project`. Extend the existing `toAgentAction` mapping in the binding and test exact and mismatched arguments, operation and principal using its own suite. The proposed resource is `external_job_service:<executor>/<environment>/<service>` with a `runner` relation. A decision is fresh for every actual submit, including retry or adoption. Only bounded coordinates and the decision disposition reach the action record. Keep tokens and proof bytes inside the adapter. Until the exact mapping is available, the binding returns an unmapped denial. Independently complete stub and PostgreSQL qualification. [Kikan-En action request](mori://shinzui/kikan-en/okf/improvement-requests/concepts/IR-4)


### M5. Wire bounded commands into the deployed worker


Implement the generic process adapter in `shikigami-core/local-host/Shikigami/Execution/ExternalJob/Command.hs`. Reuse the process-group, output-draining and timeout behavior in the host launcher where applicable. Expose it only to the composition that needs to run these commands. The owning worker loads `executors.catalog_file` through the Settei declaration in `shikigami-core/src/Shikigami/App/Config.hs`. Wire the optional setting and its environment binding through `shikigami-workers/src/Shikigami/Workers/Config.hs` and `shikigami-workers/src/Shikigami/Workers/Command/Worker.hs`. Explicitly select a permitted composition and trust tier. An unset key installs an empty catalog. Malformed definitions or command timeouts beyond the worker's actual dispatch budget fail startup. The scheduler only needs the database to wake the child.

Run the fixed program directly with literal argv in the configured directory. Construct the child environment from explicit operator bindings, including any required credential-file locations. Resolve the admitted catalog revision before each call and refuse substitution after a reload. Bound the whole observe sequence by its attempt budget and the remaining wait. Concurrently drain stdout and stderr, retain at most 64 KiB per stream, and settle the local process group on timeout. Reject a truncated parse as ambiguous. Persist only the validated handle, parsed status, optional exit code and a bounded diagnostic code. Raw command output, environment values and proof bytes can contain secrets.

Exercise the actual process adapter with temporary stub executables. Record argv boundaries at the fixture, including empty arguments, spaces and shell metacharacters. Verify handle capture, distinct conflict status, invalid or oversized output, ordered observe commands stopping on first failure, an unmapped status, both pipes filling, and process cleanup on timeout. A lost submit response after possible acceptance enters reconciliation. A configuration conflict before launch is a rejection. A nonzero exit or missing handle by itself cannot prove that nothing ran. Prove empty, invalid and changed-catalog behavior through the worker's normal startup and dispatch path.


### M6. Qualify the external tool and publish the operating procedure


Use the composed Kikan binaries and a disposable cluster to run the live procedures below. Part A proves recovery after a handle was saved with today's quick-submit contract. Part B proves recovery after a handle was lost and requires keyed adoption. Both need the production authority path from M4. Retain the application revision, executor and shiki revisions, operation ID, handle, redacted authorization evidence, number of submit attempts, matching cluster Job count and history-row count.

Write `docs/operations/external-jobs.md` with a complete, validated operator catalog, the required worker and scheduler roles, per-action policy, credential references, deadlines, diagnosis by operation ID or handle, and withdrawal/draining instructions. Add the setting to `docs/operations/configuration.md` and the SDK example to `docs/user/flows.md`, including a short runbook that branches on the outcome and seeks approval. Update the README and roadmap at delivery. Test the catalog shown in the guide with the same decoder as worker startup. Distill the implemented boundary and recovery semantics into the ADR.


## Concrete Steps


Run commands from the repository root in its development shell. Use the PostgreSQL 18 fixture in `shikigami-migrations/test-support/Shikigami/Migrations/TestSupport.hs` for the integration tests. New test groups below are implementation deliverables. First establish that the pack composition and kernel checks work before adding the feature.

```bash
nix develop
just kernel-fitness
cabal run kikan-shikigami -- validate packs/flow-pack-examples/agents/qualification-at-risk-customer.dhall
```

The validation command should parse one agent and recognize its Kikan output. After changing the DSL, regenerate with the producer command. Review its generated Cabal entries and conformance expectations. The gate regenerates again and checks for an empty diff under `shikigami-core/src`, so run it on the committed or staged candidate.

```bash
cabal run -v0 keiro-dsl -- scaffold domain/shikigami.keiro-workspace --out shikigami-core/src
just keiro-gate api-baseline-v1
```

Run focused suites as their milestones land. Select a common `ExternalJob` test group in the relevant Tasty suites and confirm the selected count is positive. The pack suite also checks its label inventory. Compare the stable `flow-sdk` and `kernel-ports` exports against the pins, the SDK facade golden in `shikigami-core/test/golden/sdk/`, and the ownership policy. Register the new operator catalog in `api-baseline/surfaces.dhall` with its owner, typed fixture and compatibility rule. Route that fixture through the runtime decoder in `tools/api-baseline/src/ApiBaseline/Check/DhallSchema.hs`, following the existing tools catalog check. Re-pin only intentionally changed surfaces after inspecting the actual differences. Keep existing declarations and stored payloads readable. [API baseline policy](../architecture/api-baseline.md)

```bash
cabal test shikigami-core-test --test-options='-p ExternalJob'
cabal test shikigami-core-postgres-test --test-options='-p ExternalJob'
cabal test shikigami-workers-test --test-options='-p ExternalJob'
cabal test kikan-shikigami-binding-test --test-options='-p ExternalJob'
cabal test flow-pack-examples-test
cabal build all
just kernel-fitness
just api-baseline
cabal test all
```

For live qualification, provision PostgreSQL, a disposable kind cluster, a shiki project directory, and the Shomei/Kikan-En services and grants for the proof principal. Bind the shiki project's `local` environment to this cluster's kubeconfig context and a dedicated history database. Configure the demo service to target the BusyBox deployment, container `busybox`, namespace `demo`, service account `default` and command path `/bin/busybox`. Set Job retention long enough to observe it after restart. Put the tested Dhall catalog in that project and configure its working directory accordingly. [Shiki project configuration](mori://shinzui/shiki/okf/user-documentation/concepts/DOC-7) and [service configuration](mori://shinzui/shiki/okf/user-documentation/concepts/DOC-9)

```bash
kind create cluster --name shikigami-jobs
kubectl --context kind-shikigami-jobs create namespace demo
kubectl --context kind-shikigami-jobs -n demo create deployment echo --image=busybox:1.36 -- sleep 86400
kubectl --context kind-shikigami-jobs -n demo rollout status deployment/echo
```

Configure the proof executor `cluster-jobs` for `local/echo`. Its literal submit argv after the shiki executable is `["--env","{environment}","run","{service}","--no-wait","--","{args}"]`. Extract the UUID in the `(run <uuid>)` part of stdout. Observe with `--env {environment} runs sync {handle}`, then `--env {environment} runs show {handle}`. Show prints the JSON run record on stdout. Map its `status` field (`Pending`, `Running`, `Succeeded`, `Failed`) and optional `exitCode`. Check with the installed executable and a run in the disposable namespace. Count fixture jobs by operation/handle and keep any manual preflight separate from proof counts.

Set `SHIKIGAMI_AGENTS_DIRECTORY` to the directory containing the proof manifest and `SHIKIGAMI_EXECUTORS_CATALOG_FILE` to the catalog path for the worker. Select `trust.tier=multi-tenant` and the configured `authorization.actions.mode=kikan` binding. Use the same deployment configuration and approved identity directory across roles. Run the worker and scheduler in separate terminals. Validate and enqueue in a third.

```bash
cabal run kikan-shikigami-worker
cabal run kikan-shikigami-scheduler
```

```bash
cabal run kikan-shikigami -- validate packs/flow-pack-examples/agents/external-job-proof.dhall
cabal run kikan-shikigami -- enqueue-run external-job-proof --payload '{"message":"hello A"}'
kubectl --context kind-shikigami-jobs -n demo get jobs
```

**Part A.** Use `submitRepeatSafe=False` and the proof's repeat-safe echo. Give the fixture a long first poll interval and enough time to restart before the deadline. Read the persisted handle, confirm the child is parked and verify that no observation attempt has been accepted. Stop the fixture worker and scheduler, then restart both against the same database. Read the parent using `cabal run kikan-shikigami -- runs show shikigami.agent-run "$proof_workflow_id"`, where `proof_workflow_id` is the run's workflow ID. Inspect its journal and child result and compare the handle with `shiki --env local runs show "$proof_handle"` from the shiki project. Expect a succeeded result and one submit for this run.

**Part B.** Use a verified shiki build implementing the operation-ID contract, add `--operation-id {operationId}` before `--`, configure its documented conflict exit code and mark the executor repeat-safe. Enqueue a distinct proof message. In the disposable fixture use an operator-owned submit wrapper that forwards the exact argv, lets the real tool create its Job, writes a first-call marker containing the key and returned handle, then holds the response without writing it to the worker. Record the argv fingerprint and attempt number with that marker. Publish it atomically outside the worker process and retain it across the fixture restart. Once the test sees the marker, terminate the fixture worker before releasing the wrapper. Confirm the first attempt has dispatch-start evidence and no saved handle, settle the fixture wrapper, then restart the worker. Later calls forward the true response. Assert two actual invocations with the same key, one matching Job, one matching history row, the same handle, and a succeeded Flow. From the disposable shiki project, submit a different echo argument with the same operation ID. Require the documented conflict exit code and check that both counts remain one. The marker and missing local receipt establish where the crash fell. Tear down only the tagged test cluster and fixture-owned state after recording the counts.

```bash
kind delete cluster --name shikigami-jobs
```


## Validation and Acceptance


M1–M3 require a native Haskell round trip and a real PostgreSQL producer/consumer/restart test. Observe all six outcomes at the parent. Verify the old-patch parent, current-patch parent, duplicate input, different input under the same key, lost submit receipt, stale claim, duplicate timer, late success and absolute deadline across an outage. A denied first call, unknown executor, or unsafe request against an unsafe executor must start zero commands. A completed parent replay must produce zero new attempts.

M4–M5 require a positive recorded Kikan decision and a verified refusal path, a real subprocess stub test, and an unchanged empty-catalog startup. Check that the domain library and the pack body have no subprocess dependency and the stock packages have no shiki or Kikan service dependency. Check Cabal components and exact executable tokens. A substring search for `shiki` also matches the project's own name and cannot demonstrate independence. `just kernel-fitness`, the tagged Keiro gate, the API baseline and the affected suites must all pass.

Record the Part A and Part B results separately. The fake covers the crash window during development. Only Part B with independent cluster and history counts qualifies a repeat-unsafe real operation for an adopting backend. Keep the milestone open when the corresponding external contract is unavailable.


## Idempotence and Recovery


The external operation ID follows the logical submission for its whole life. A new attempt, worker, timer or generation reuses it. An adopting backend must return the same handle for identical input and refuse different input. A command that is only *safe to repeat* may create additional jobs after an ambiguous response. Use that mode only for a request explicitly declared safe to repeat. Never claim uniqueness from that mode.

After a possible dispatch, parse failures, process loss and an unavailable authority on retry can leave the external result unknown. Retain the accepted key, fingerprint, attempt history and any later handle. A saved handle moves the child to observation. A terminal result is immutable even when a late receipt adds new evidence. A deadline bounds Shikigami's wait, including the case where submission never produced a handle. It never deletes a remote job.

For first deployment, roll out readers, worker dispatch and timer handling before enabling the catalog. Every worker eligible to claim a new attempt must understand its input. For a planned catalog change, stop new admissions and keep the admitted revision and credentials available while its children drain. If the definition disappears unexpectedly, refuse new dispatch on a replacement target. Park existing observations within their original deadline and report the known handle for manual reconciliation. Keep workflow code, journal decoders and registration deployed while old runs can resume. Rerunning the proof uses a fresh logical event for a new run and the same event to exercise idempotence.


## Interfaces and Dependencies


The Flow-facing API is `runExternalJob key request`. The request owns the wait duration. Keep the checked outcome and its lower-case status encoding available to the caller. The generic runtime port has three operations: pure admission of a target and request, a bounded submit with stable operation ID, and bounded observation of an admitted handle. The trusted worker supplies the implementation and recorded authority. The scheduler handles versioned wake references. Keep raw argv in protected execution input and use digests and references in timers, queue entries and operator diagnostics.

The only proposed Shikigami setting is `executors.catalog_file` (`SHIKIGAMI_EXECUTORS_CATALOG_FILE`). The catalog is operator-owned. No Shikigami package links shiki. The implementation uses the runtime pinned by this checkout, discoverable at `mori://shinzui/keiro/packages/keiro`. Only the Kikan production mapping depends on `mori://shinzui/kikan-en/okf/improvement-requests/concepts/IR-4`. Only keyed adoption by the shiki example depends on `mori://shinzui/shiki/okf/improvement-requests/concepts/IR-1`.


## Revision Notes


- 2026-10-02 (update): Replaced the shiki-specific executor with a generic command executor at the
  user's direction. Shikigami and shiki must stay independent and unlinked. Executors are now
  defined in an operator-owned Dhall catalog (`schema/Executor.dhall`, `executors.catalog_file`)
  with submit and observe command templates, a handle pattern, and a status map. Shiki is
  configured there, not coded. Added the lease-based reason that a single "run and wait" command
  cannot be used, added repeat-safety admission so shiki 0.1.0.0 can be used for repeat-safe
  commands before IR-1 ships, narrowed IR-1 to the operation id alone, and updated Progress,
  Surprises, the Decision Log, Milestones 1, 2, 3, 5, and 6, Concrete Steps, Validation,
  Idempotence, and Interfaces to match.

- 2026-10-02 (update): Filed the Kikan-En request as
  `mori://shinzui/kikan-en/okf/improvement-requests/concepts/IR-4` and aligned Milestone 4, Progress,
  and Interfaces with it. The resource is executor, environment, and service; the argument digest
  and operation id travel in a proof-bound invocation context rather than in the resource.

- 2026-11-21 (review and update): Rebased the six milestones on the frozen kernel, accepted attempts, pack composition and recorded authority. Replaced the timing-dependent crash demonstration with two independently verifiable live cases and rechecked both upstream contracts.
