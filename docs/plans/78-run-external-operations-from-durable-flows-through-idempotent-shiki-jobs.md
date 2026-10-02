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
---

# Run external operations from durable Flows through idempotent shiki jobs

This ExecPlan is a living document. The sections Progress, Surprises & Discoveries,
Decision Log, and Outcomes & Retrospective must be kept up to date as work proceeds.
If durable project context changes, update or create ADRs in docs/adr/ in the same change.

The title names shiki because shiki is the first tool this mechanism will drive. Shikigami itself
gains no dependency on shiki and no knowledge of it. Everything shiki-specific lives in operator
configuration.


## Purpose / Big Picture

Some operational work takes days and has several steps: run a repair command, wait hours for it
to finish, check the result, get a human's go-ahead, run the next command, and meet hard
deadlines along the way. The motivating example is the BAREIS re-key repair in
`mori://tan/mls-service-v2/masterplans/10-isolate-mls-identity-from-constellation1-key-drift-and-repair-the-corrupted-bareis-streams`,
whose maintenance window must restore every stopped worker within 10 hours and whose later
phases span several days. Today a human drives every step by hand from a terminal.

A Shikigami Flow can already hold a multi-day sequence durably. It journals each step, survives
restarts, waits for human acknowledgement with a deadline, and sends notifications. What a Flow
cannot do is start work outside Shikigami and wait for its result. This plan adds that ability
through a **generic command executor**: operator configuration names an executor and gives it two
command templates. The submit template starts the work and returns quickly. The observe template
reports the work's status. Shikigami fills in placeholders, runs the commands without a shell,
extracts a handle from the submit output, and maps the observe output to a fixed set of statuses.
It never knows which tool sits behind the templates.

After this plan, a Flow author writes one line such as
`runExternalJob "apply-repoint" request (hours 6)` and gets back a typed outcome: succeeded,
failed, outcome unknown, timed out, denied, or rejected. Behind that line, Shikigami starts a
durable child workflow. The child runs the submit command once under a stable operation id, polls
with the observe command on durable timers, and wakes the parent when the work ends.

The first configured executor will run shiki (`mori://shinzui/shiki`). shiki starts the command as
a Kubernetes Job built from the target service's live Deployment: `shiki run --no-wait` returns at
once and prints the run id, `shiki runs sync <id>` records the outcome, and `shiki runs show <id>`
prints the run as JSON. The Job runs in the cluster, so the machine hosting Shikigami can sleep or
restart without stopping the work. When Shikigami comes back, it observes the outcome and the Flow
continues.

To see it working: a proof Flow `external-job-proof`, triggered by an event, runs `echo hello`
through an executor configured for shiki against a local `kind` cluster. If the worker is killed
after the Job is submitted and then restarted, the Flow still completes with `succeeded`, and
exactly one Kubernetes Job exists for that operation.


## Progress

- [ ] Milestone 1: ADR, core types, the executor catalog schema and template engine, and an in-memory fake executor, with unit tests.
- [ ] Milestone 2: the `shikigami.external-job` child workflow, its DSL declaration, poll and deadline timers, and scheduler dispatch, tested against PostgreSQL with the fake executor.
- [ ] Milestone 3: the `ExternalJob` Flow effect, its interpreter in the Flow chain, and the `external-job-proof` Flow and manifest.
- [ ] Milestone 4: fresh per-action authorization through the Kikan-En `run_external_job` action (blocked on `mori://shinzui/kikan-en/okf/improvement-requests/concepts/IR-4`).
- [ ] Milestone 5: the generic command executor in `shikigami-workers`, the `executors.catalog_file` setting, and worker and scheduler wiring, tested with stub executables.
- [ ] Milestone 6: live `kind` validation with crash recovery through a shiki-configured executor, operator and user documentation, and ADR distillation. The repeat-unsafe crash test needs `mori://shinzui/shiki/okf/improvement-requests/concepts/IR-1`.
- [x] (2026-10-02) Filed the Kikan-En request for a `run_external_job` action as `mori://shinzui/kikan-en/okf/improvement-requests/concepts/IR-4`.


## Surprises & Discoveries

- Observation (found while writing this plan): shiki 0.1.0.0 can already be driven by a generic
  submit and observe pair. `shiki run --no-wait` returns after submission and prints
  `submitted job <job> (run <uuid>)`, `shiki runs sync <id>` records the outcome, and
  `shiki runs show <id>` prints the run as JSON. The one thing missing is a repeatable submission:
  every `shiki run` creates a random run id and a time-plus-random Job name
  (`shiki-cli/src/Shiki/Cli/Run.hs`, `generateJobName` in `shiki-core/src/Shiki/K8s/JobBuilder.hs`),
  and a `409 AlreadyExists` becomes a failed run. A retried submission therefore starts a second
  Job. Filed as `mori://shinzui/shiki/okf/improvement-requests/concepts/IR-1`, which asks only for
  `--operation-id`. Evidence: shiki commit `3f1ff98`.

- Observation: a single long blocking command cannot be a workflow step. Keiro's resume worker
  holds a lease on each workflow instance that is renewed only at step boundaries, and the lease's
  documentation says it "must exceed the longest single step action". Shikigami sets the lease to
  the worker's run timeout plus 30 seconds (`shikigamiWorkflowResumeOptions` in
  `shikigami-core/src/Shikigami/Workflow/Versioning.hs`), and advances one workflow at a time
  (`maxConcurrentAdvances = 1`). A step that blocks for hours would let another worker claim the
  same workflow and would stall every other workflow. This is why the executor has a quick submit
  command and a separate observe command.

- Observation: Kikan-En's closed `AgentAction` vocabulary
  (`Kikan.En.Action` in `mori://shinzui/kikan-en/packages/kikan-en-contract`) has no action for
  running an external job. Its closest constructor, `ExecuteWorkspace` (operation `can_bash`),
  means running a shell in a workspace, which is a different authority. Milestone 4 needs a new
  constructor.


## Decision Log

- Decision: Shikigami and shiki stay independent. Shikigami has no build dependency on shiki, no
  shiki-specific module, type, configuration key, or test, and it does not call shiki by name.
  The executor is generic, and shiki appears only in operator configuration and in this plan's
  live-validation steps.
  Rationale: the user requires the projects to be unlinked. A generic executor also serves any
  tool that can submit work and report its status.
  Date: 2026-10-02

- Decision: An executor is configured with two command templates, submit and observe, rather than
  one "run and wait" command.
  Rationale: a long blocking command inside a workflow step would outlive the workflow lease and
  stall the resume loop (see Surprises & Discoveries), and it would die with the host. A quick
  submit plus periodic observation keeps every command short and lets the work continue while
  Shikigami is down.
  Date: 2026-10-02

- Decision: Polling lives in Shikigami's child workflow, written once, not in each runbook Flow.
  Rationale: polling in the Flow would make every runbook re-implement status parsing, and it
  would add one journal entry per poll under generated labels that the DSL gate cannot declare
  ([ADR 0012](../adr/0012-a-declared-workflow-body-only-grows-behind-a-patch.md)).
  Date: 2026-10-02

- Decision: Model an external job as a durable child workflow named `shikigami.external-job`,
  spawned and awaited by the Flow effect's interpreter, following the approval child workflow
  (`shikigami-core/src/Shikigami/Agent/Approval/Workflow.hs`).
  Rationale: [ADR 0030](../adr/0030-an-approval-request-is-a-durable-child-workflow.md) already
  establishes this shape for "start something, wait durably, return a typed answer". It gives a
  deterministic child id, an isolated journal, static step labels the DSL can declare, and
  Keiro's `spawnChild`/`awaitChild` semantics.
  Date: 2026-10-02

- Decision: Poll with one-shot Keiro timers that re-arm themselves, and wake the child through an
  awakeable. Do not add a new long-running worker loop.
  Rationale: the existing timer loop and the scheduler's dispatch by timer `kind` already run the
  approval deadline. A new loop would need its own supervision
  ([ADR 0019](../adr/0019-a-loop-that-stops-stops-the-process.md)). The child's journal stays at
  three static entries.
  Date: 2026-10-02

- Decision: Idempotency belongs to the submitted command, and Shikigami supplies the key.
  Shikigami derives one operation id per child workflow, `shikigami:<child workflow id>`, and
  substitutes it for `{operationId}` on every submission attempt. An executor declares whether its
  submit command is repeat-safe. Shikigami refuses to run a request through a repeat-unsafe
  executor unless the request says the command itself is safe to run twice.
  Rationale: a crash can always fall between the external tool accepting a submission and
  Shikigami's journal recording it
  ([ADR 0022](../adr/0022-the-journal-ends-at-enqueue-and-receipts-own-delivery-truth.md) makes the
  same argument for sinks). Only a key that the external tool enforces closes that window. For
  shiki that key is IR-1's `--operation-id`. Until IR-1 ships, a shiki executor can be configured
  as repeat-unsafe and used for read-only or otherwise repeat-safe commands.
  Date: 2026-10-02

- Decision: Executors are defined in a Dhall catalog file, typed by a new `schema/Executor.dhall`,
  and named by one Settei key, `executors.catalog_file`.
  Rationale: command templates and status maps are lists and records, which flat environment
  variables encode badly. Shikigami already validates agent declarations from Dhall, so operators
  use the same language and get typed errors at startup.
  Date: 2026-10-02

- Decision: Commands run as an executable plus an argument vector, never through a shell.
  Placeholders are whole argument elements, and `{args}` expands to zero or more elements.
  Rationale: no quoting or injection surface. An operator who needs a pipeline can point the
  template at a script they own.
  Date: 2026-10-02

- Decision: A timeout or deadline never cancels or deletes the external work. The outcome is
  `ExternalJobTimedOut` with the handle, and the Flow decides what to do (usually ask a human).
  Rationale: for repair commands, killing a writer midway is often worse than letting it finish.
  The executor contract has no cancel command.
  Date: 2026-10-02

- Decision: The executable and its fixed arguments come from operator configuration. A Flow chooses
  only a named executor, an environment and service from the executor's allow-lists, and the
  trailing arguments. Those come from Flow code and the trigger payload, never from model output.
  Rationale: Flow bodies are reviewed, compiled Haskell. Keeping model text out of commands keeps
  this a deterministic runbook mechanism rather than a model-driven shell.
  Date: 2026-10-02

- Decision: Runbook Flows for a specific service, such as an MP-10 repair Flow for
  mls-service-v2, are out of scope. This plan ships the mechanism and a proof Flow.
  Rationale: Flows are compiled into `shikigami-core` and registered in `flowRegistry`
  (`shikigami-core/src/Shikigami/Flow.hs`). A work-specific runbook there would put another
  organization's operational code inside Shikigami's core. Letting a separate package contribute
  Flows to the worker needs its own plan.
  Date: 2026-10-02

- Decision: Use the word "external job" for types, modules, and DSL names, and avoid
  "operation", except for the opaque `operationId` key.
  Rationale: keiro-dsl already uses the keyword `operation` (for example `operation RunAgentRun`
  in `domain/shikigami-agent-run.keiro`).
  Date: 2026-10-02


## Outcomes & Retrospective

(To be filled during and after implementation.)


## Context and Orientation

**Shikigami, Flows, and journals.** Shikigami runs declared agents. An agent is a Dhall file under
`agents/` whose `behavior` says what runs; `behavior = A.Behavior.Flow { name = "…" }` selects a
Flow (`schema/Agent.dhall` line 39, `Flow {name :: !Text}` in
`shikigami-core/src/Shikigami/Agent/Decl.hs`). A Flow is a Haskell function
`FlowEffects es => Value -> Eff es Value` registered as a `FlowDef` in `flowRegistry` in
`shikigami-core/src/Shikigami/Flow.hs`. It runs inside a durable workflow on Keiro, a
PostgreSQL-backed workflow engine (`mori://shinzui/keiro`, pinned at 0.18.0.0). A workflow
records each named step's result in its **journal**. When the process restarts, Keiro **replays**
the workflow: steps already in the journal return their recorded result instead of running again.

**What a Flow may touch.** `FlowEffects` (`shikigami-core/src/Shikigami/Flow.hs`, lines 69 to 82)
lists every effect a Flow body may use: `Workflow`, `Memory`, `Sink`, `Activity`,
`Acknowledgement`, `Delegate`, `Routing`, `ExecutionContext`, and four practice-review effects.
There is deliberately no `IOE` (arbitrary IO) and no `Store`, and the comment above it says that
adding an effect widens what every Flow may do.
[ADR 0013](../adr/0013-flow-bodies-reach-the-world-only-through-capabilities.md) makes this the
rule: a Flow reaches the world only through an effect whose interpreter is replay-safe. The
interpreters are stacked in `runFlowBehavior` in `shikigami-core/src/Shikigami/Agent/Workflow.hs`
(around lines 754 to 856). This plan adds one effect, `ExternalJob`, and one interpreter to that
chain, and records the decision in a new ADR.

**The approval child workflow, the pattern to copy.** `Acknowledgement` lets a Flow wait for a
human answer with a deadline. Its production interpreter, `runAcknowledgementWithChild` in
`shikigami-core/src/Shikigami/Flow/Acknowledgement.hs`, calls `requestApproval` in
`shikigami-core/src/Shikigami/Agent/Approval/Workflow.hs`. That function:

1. reads the parent's coordinates with `currentWorkflow` and `currentRunGeneration`;
2. derives a deterministic child id with a version-5 UUID over a purpose string
   (`reviewRequestIdFor` in `shikigami-core/src/Shikigami/Agent/Approval.hs`);
3. calls Keiro's `spawnChild` (idempotent for the same id);
4. writes the child's input as a recorded `ingest-approval` step into the child's journal with
   `appendJournalEntry`;
5. waits with `awaitChild`.

The child (`approvalWorkflow`) then:

1. reads its input;
2. allocates an **awakeable** (a durable promise another process can resolve) with
   `awakeableNamed`;
3. notifies a human;
4. arms a deadline with `armApprovalDeadline`, which schedules a one-shot Keiro timer (a
   `TimerRequest` passed to `scheduleTimerOnceTx`) whose payload carries
   `kind = "shikigami.approval-timeout"`;
5. awaits the awakeable.

When the timer fires, the scheduler process dispatches on `kind`
(`shikigami-workers/src/Shikigami/Trigger/Scheduler.hs`, around lines 197 to 222) to
`approvalTimeoutFireAction`, which calls `signalAwakeable aid TimedOut`.

The child's steps are declared in the keiro-dsl file `domain/shikigami-approval.keiro`. The parent
declares `child approval id input via approvalWorkflowId` in `domain/shikigami-agent-run.keiro`.
Generated runtime code lives under `shikigami-core/src/Shikigami/Approval/Generated/`. The registry
entry is `approvalRegistry`, which `agentRunRegistry` (`shikigami-core/src/Shikigami/Agent/Workflow.hs`,
around lines 284 to 287) merges. Declared patch sets are unioned in
`shikigami-core/src/Shikigami/Workflow/Versioning.hs`. Copy each of these touch points for the new
child workflow.

**Delegation** (`shikigami-core/src/Shikigami/Flow/Delegate.hs` and
`shikigami-core/src/Shikigami/Agent/Delegate.hs`) uses the same spawn-and-await shape.
[ADR 0023](../adr/0023-delegation-is-governed-at-the-child-spawn-boundary.md) requires child ids
derived from caller-supplied stable keys, never ordinals, and forbids touching Keiro's private
tables.

**Keiro 0.18 primitives used here.** From `Keiro.Workflow`: `step`, `currentWorkflow`,
`currentRunGeneration`, `appendJournalEntry`, `patch`. From `Keiro.Workflow.Child`: `spawnChild`,
`awaitChild`. From `Keiro.Workflow.Awakeable`: `awakeableNamed`, `signalAwakeable` (returns
`False` when the awakeable was already resolved). From `Keiro.Timer`: `TimerRequest`,
`scheduleTimerOnceTx`, `TimerRow`. Read their signatures in the Keiro checkout found with
`mori registry show shinzui/keiro --full`. That checkout may be ahead of 0.18, so use
`git show keiro-0.18.0.0:<path>` to read the pinned source.

**Leases and timeouts.** The resume worker leases each workflow instance for the worker's
configured run timeout plus 30 seconds (`shikigamiWorkflowResumeOptions` in
`shikigami-core/src/Shikigami/Workflow/Versioning.hs`). The submit command runs inside a workflow
step, so its timeout must not exceed the run timeout. The observe command runs inside a timer fire
action in the scheduler process, not inside a workflow lease, but it still gets a bounded timeout.

**Versioning rules.** Workflow names and step labels are durable.
[ADR 0012](../adr/0012-a-declared-workflow-body-only-grows-behind-a-patch.md) requires a `patch`
block for any change to a released declared body.
[ADR 0027](../adr/0027-the-first-release-establishes-one-clean-durable-baseline.md) and
`docs/workflow-versioning.md` ("The one pre-v1 baseline exception") allow adding the new `child`
declaration to `domain/shikigami-agent-run.keiro` directly only if four facts hold immediately
before the change: no resumable workflow journals, no queued or stored payloads needing the old
codec, no external wire consumers, and no release or deployment that froze the old shape. Check
them; if any fails, add the declaration behind a patch as ADR 0012 describes.

**Authorization.** [ADR 0036](../adr/0036-external-agent-actions-require-fresh-exact-authorization.md)
requires a fresh Kikan-En decision immediately before every external agent action, and the proof
is never journaled. The seam is `ActionAuthorizer` in
`shikigami-core/src/Shikigami/Action/Authorization.hs`, whose
`authorize :: Text -> AgentAction -> IO (Either ActionAuthorizationFailure ActionAuthorizationDecision)`
takes the principal and an `AgentAction`. `denyAllActionAuthorizer` is the production default when
authorization is disabled. `allowAllActionAuthorizerForTests` is for tests only. Kikan-En lives at
`mori://shinzui/kikan-en` and is built from a sibling checkout listed in `cabal.project`.

**Credentials and process boundaries.**
[ADR 0026](../adr/0026-outbound-sink-credentials-stay-opaque-and-http-policy-lives-at-the-process-boundary.md)
keeps credentials opaque and out of journals and logs. An executor's commands use whatever
credentials their own tools read: for shiki, a kubeconfig, possibly using `gke-gcloud-auth-plugin`,
and a history database URL from `shiki.dhall` or `SHIKI_DATABASE_URL`. Shikigami passes the
worker's environment through to the subprocess, plus any variables the catalog sets, and never logs
environment values. Captured stdout and stderr are bounded, and they are not journaled except for
the extracted handle and the parsed status fields.

**Package boundary.** `shikigami-core/test/Shikigami/PackageArchitectureSpec.hs` forbids
`process` and `typed-process` in `shikigami-core`'s library. Template expansion and output parsing
are pure, so they live in core. The code that actually starts subprocesses lives in
`shikigami-workers`.

**The first executor, shiki.** `mori://shinzui/shiki` 0.1.0.0 is a separate project that runs
`shiki run <service> -- <args>` as a one-off Kubernetes Job built from the service's live
Deployment, and records each run in PostgreSQL. It is configured through a project directory
holding `shiki.dhall` and `services/<service>.dhall`. Its relevant behavior:

- `shiki run --no-wait` prints `submitted job <job> (run <uuid>)` and exits 0.
- `shiki runs sync <id>` records the outcome of a finished Job and leaves a running one unchanged.
- `shiki runs show <id>` prints the run as JSON, including `status` and `exitCode`. Check the
  exact `status` spelling with a real run before writing the status map; it is expected to be a
  capitalized constructor name such as `Running`.

IR-1, `mori://shinzui/shiki/okf/improvement-requests/concepts/IR-1`, asks shiki for
`--operation-id` with adoption, which makes the submit command repeat-safe.

**Testing patterns.** `shikigami-core/test-postgres/Shikigami/AgentWorkflowSpec.hs` drives approval
children to completion with `driveApprovalChildToPark`, `resumeApprovalToCompletion`, and
`fireDueApprovalTimer`. It resumes workflows with
`resumeWorkflowsOnce defaultWorkflowResumeOptions (agentRunRegistry deps)` and fires timers by
passing a future time to `runWorkflowTimerWorker Nothing (addUTCTime n now) <fireAction>`.
`shikigami-core/test-postgres/Shikigami/FlowLifecycleSpec.hs` runs Flow bodies with the full
interpreter stack (`runFlowBody`, `runFlowWorkflow`). Test databases come from
`Shikigami.Migrations.TestSupport.withShikigamiFreshDatabase`.

**Configuration.** Settings are declared with Settei in `shikigami-core/src/Shikigami/App/Config.hs`.
Copy an optional path setting such as `directory.file.path` (`directoryFilePathSetting`) for the
new key. Agent declarations are decoded from Dhall with `FromDhall` instances; follow that style
for the executor catalog.

**Related work.** `docs/plans/77-add-a-read-only-k8s-observe-capability-provider-for-durable-agents.md`
adds read-only cluster observation, which a runbook Flow will use, through a Skill step, to verify
"writers stopped". [IR-11](../improvement-requests/provide-governed-mutable-repository-workspaces.md)
requests governed mutation for repository workspaces. The dotfiles bootstrap plan
`mori://shinzui/dotfiles.nix/plans/4-bootstrap-persistent-shikigami-agents-and-validate-service-migration-learning`
requires a durable executor adapter with the same contract this plan builds: persist an operation
id and a job handle before waiting, poll, recover after a restart, and return the same job for a
repeated request.


## Plan of Work


### Milestone 1: Decision, types, catalog schema, and templates

This milestone fixes the vocabulary and the configuration format so later milestones only fill
them in. At the end, the core types compile, executor catalogs parse and validate, template
expansion and output parsing are tested, and a fake executor exists for tests.

Write `docs/adr/0040-flows-run-external-jobs-through-a-durable-child-and-a-generic-command-executor.md`
in the existing ADR format. If plan 77 has not yet claimed 0039, take the next free number
instead. It should state the decisions in this plan's Decision Log: a new Flow effect, the child
workflow, timer-driven polling, the submit and observe templates, operation ids and repeat-safety,
no cancellation on timeout, commands from configuration and code only, no shell, and no tool-specific
code. Amend the comment above `FlowEffects` to point at it.

Create `shikigami-core/src/Shikigami/ExternalJob/Types.hs` with:

- `ExternalJobRequest`: executor name, environment, service, an argument list, a deadline in
  seconds, `repeatSafe :: Bool` (default `False`), and an optional poll interval override.
- `ExternalJobHandle`: executor name, operation id, and the handle text extracted from submit
  output.
- `ExternalJobStatus`: `Pending`, `Running`, `Succeeded`, `Failed`, `Unknown`.
- `ExternalJobOutcome` with these constructors:
  - `ExternalJobSucceeded ExternalJobReport`
  - `ExternalJobFailed ExternalJobReport`
  - `ExternalJobOutcomeUnknown ExternalJobReport`
  - `ExternalJobTimedOut ExternalJobHandle`
  - `ExternalJobDenied Text`
  - `ExternalJobRejected Text`
- `ExternalJobReport`: the handle, an optional exit code, and an optional bounded detail string.
- `OperationId`, a newtype with a smart constructor accepting 1 to 200 characters from
  `[A-Za-z0-9._:-]`.

Give every journaled type explicit, tagged `ToJSON`/`FromJSON` instances with round-trip tests,
because they are written to journals and must decode forever.

Create `schema/Executor.dhall`, the typed shape of an executor catalog. Here
`Command = { executable : Text, arguments : List Text }`, and a catalog is a list of executors:

```dhall
let Command = { executable : Text, arguments : List Text }

let StatusMapping = { value : Text, status : < Pending | Running | Succeeded | Failed | Unknown > }

let Executor =
      { name : Text
      , workingDirectory : Optional Text
      , environmentVariables : List { mapKey : Text, mapValue : Text }
      , environments : List Text
      , services : List Text
      , submit : Command
      , submitRepeatSafe : Bool
      , conflictExitCode : Optional Natural
      , handlePattern : Text
      , observe : List Command
      , statusField : Text
      , statusMap : List StatusMapping
      , exitCodeField : Optional Text
      , pollIntervalSeconds : Natural
      , commandTimeoutSeconds : Natural
      }

in  { Command, StatusMapping, Executor }
```

Create `shikigami-core/src/Shikigami/ExternalJob/Catalog.hs` with `FromDhall` decoding and a
validation function, `loadExecutorCatalog :: FilePath -> IO (Either Text ExecutorCatalog)`, that
rejects:

- duplicate executor names;
- an empty submit executable;
- an empty `observe` list;
- a `handlePattern` that does not compile or lacks exactly one capture group;
- a submit template whose `{operationId}` presence contradicts `submitRepeatSafe` (repeat-safe
  without `{operationId}` is allowed, because a tool may be idempotent by other means, but log a
  warning);
- an unknown placeholder;
- `{args}` appearing anywhere except as a whole argument element.

Create `shikigami-core/src/Shikigami/ExternalJob/Template.hs`, which is pure. The placeholders are
`{operationId}`, `{environment}`, `{service}`, and `{handle}` (observe only); each replaces a
substring of one argument. `{args}` must be a whole element and expands to the request's argument
list. The module also holds:

- `extractHandle :: Regex -> Text -> Either Text Text`, applied to submit stdout;
- `parseObservation :: StatusSpec -> ByteString -> Either Text (ExternalJobStatus, Maybe Int)`,
  which reads the status field from the JSON object printed by the last observe command and maps it
  through `statusMap`. Any value not in `statusMap` is an error; the caller treats it as transient
  and logs it.

Create `shikigami-core/src/Shikigami/ExternalJob/Executor.hs` with the runtime interface. It is a
record of functions, so core never imports `process`:

```haskell
data ExternalJobExecutor = ExternalJobExecutor
  { executorName :: !Text,
    admit :: ExternalJobRequest -> Either Text (),
    submit :: OperationId -> ExternalJobRequest -> IO (Either ExecutorError ExternalJobHandle),
    observe :: ExternalJobHandle -> ExternalJobRequest -> IO (Either ExecutorError ExternalJobStatusReport)
  }

data ExecutorError = ExecutorTransient !Text | ExecutorPermanent !Text | ExecutorConflict !Text
newtype ExternalJobExecutors = ExternalJobExecutors (Map Text ExternalJobExecutor)
noExternalJobExecutors :: ExternalJobExecutors
```

`admit` enforces the executor's environment and service allow-lists. It also refuses a request
with `repeatSafe = False` when the executor's `submitRepeatSafe` is `False`. All of this happens
before any IO.

Add a fake executor in the core test suites' shared support location,
`newFakeExecutor :: IO (FakeExecutorControl, ExternalJobExecutor)`. It keeps jobs in an `IORef`
keyed by operation id: a repeated `submit` with the same id returns the existing handle and
increments a `submitCalls` counter without creating a second job. The control lets a test finish
a job, fail it, make it vanish (unknown), or make `submit` fail transiently once.

Add `operationIdForChild :: WorkflowId -> OperationId`, producing `shikigami:<child workflow id>`.
Add `externalJobWorkflowIdFor`, a version-5 UUID over
`"shikigami:external-job:<parent name>:<parent id>:<generation>:<key>"`, modeled on
`reviewRequestIdFor`.

Add `shikigami-core/test/Shikigami/ExternalJobSpec.hs` to test:

- codec round trips and id determinism;
- `OperationId` validation;
- catalog validation errors;
- template expansion, including `{args}` with zero, one, and several elements, and refusal of
  `{args}` inside a larger argument;
- handle extraction against `submitted job echo-oneoff-20261002-120000-abcdef (run 3f9c2a1e-7b4d-4c1a-9e2f-5d8a6b0c3e71)`;
- status parsing with a capitalized map such as `Running` and `Succeeded`.


### Milestone 2: The child workflow and its timers

At the end of this milestone, a test can spawn `shikigami.external-job` directly, see it submit
once through the fake executor, poll on timers, and complete with each outcome. Killing and
resuming it does not create a second job.

Declare the workflow in a new `domain/shikigami-external-job.keiro`, modeled on
`domain/shikigami-approval.keiro`:

```text
language keiro-dsl 6
context shikigami
layout collocated

workflow ExternalJob
  name "shikigami.external-job"
  in ExternalJobWorkflowInput { externalJobId:Id }
  out ExternalJobOutcome
  id from input.externalJobId via externalJobWorkflowIdText
  body
    step ingest-external-job -> ExternalJobWorkflowInput
    step submit-external-job -> ExternalJobSubmission
    await completion -> ExternalJobOutcome
```

In `domain/shikigami-agent-run.keiro`, add
`child external-job id input via externalJobWorkflowId -> ExternalJobOutcome` next to the existing
`child approval` line, after checking the pre-v1 facts described in Context. Regenerate code with
the repository's keiro-dsl tooling; `just keiro-gate` runs the checks, and
`docs/workflow-versioning.md` names the scaffold command. Add the generated `declaredPatches` to
`shikigami-core/src/Shikigami/Workflow/Versioning.hs`.

Implement `externalJobWorkflow` in `shikigami-core/src/Shikigami/ExternalJob/Workflow.hs`:

1. `ingest-external-job` reads the input recorded by the parent: the request, the principal, and
   the parent's coordinates.
2. `submit-external-job` runs one step body. It looks up the executor by name (an unknown executor
   gives `Rejected`) and calls `admit` (a refusal gives `Rejected`). It then authorizes; until
   Milestone 4 this is a function parameter that tests set to allow. Finally it calls `submit` with
   `operationIdForChild`.
   - A transient error throws, so Keiro retries the step; the same operation id makes the retry
     safe for repeat-safe commands.
   - A conflict or permanent error gives `Rejected`.
   - The step records either the handle or a terminal refusal.
3. If the submission was refused, the child returns that outcome immediately. Otherwise it
   allocates the awakeable with `awakeableNamed "completion"`, arms the deadline timer and the
   first poll timer in one transaction, and awaits the awakeable.

Add two timer kinds in `shikigami-core/src/Shikigami/ExternalJob/Timers.hs`:

- `"shikigami.external-job-deadline"` carries the awakeable id and the handle. Its fire action
  signals `ExternalJobTimedOut handle`.
- `"shikigami.external-job-poll"` carries the awakeable id, the handle, the request, and an attempt
  number. Its fire action calls `observe`:
  - `Pending`, `Running`, or a transient error: schedule the next poll timer.
  - `Succeeded`, `Failed`, or `Unknown`: signal the matching outcome with `signalAwakeable`.
  - If `signalAwakeable` returns `False` (already resolved, for example by the deadline), stop
    polling.
  - Stop after a hard cap of attempts (the deadline divided by the interval, plus a 24-hour
    grace), logging `external_job.poll_abandoned`.

Timer ids are version-5 UUIDs over the child id, the kind, and the attempt number, as
`armApprovalDeadline` does, so re-arming is idempotent.

Add dispatch branches for both kinds to `shikigami-workers/src/Shikigami/Trigger/Scheduler.hs`, and
thread the configured `ExternalJobExecutors` into the scheduler's environment. Register the
workflow with an `externalJobRegistry` merged into `agentRunRegistry`. Add an
`externalJob :: ExternalJobRuntime` field (executors plus authorizer) to `AgentRunDeps` in
`shikigami-core/src/Shikigami/Agent/Workflow.hs`. In `shikigami-workers/src/Shikigami/Workers/Config.hs`
`agentRunDeps`, pass `noExternalJobExecutors` for now, so production behavior is unchanged.

Add `shikigami-core/test-postgres/Shikigami/ExternalJobWorkflowSpec.hs`, modeled on the approval
tests in `AgentWorkflowSpec.hs`, with cases for:

- success: one submit, then a poll sees `Succeeded`;
- failure with an exit code;
- outcome unknown;
- deadline first: the result is `TimedOut`, and later polls stop without error;
- a transient submit failure: the step retries, the same operation id is used twice, and the fake
  holds one job;
- simulated crash after submit: run the step body, abandon the workflow before its journal entry
  commits by throwing from a test hook, then resume. Assert `submitCalls == 2` and one job;
- an unknown executor gives `Rejected`;
- an admission refusal, including a repeat-unsafe request on a repeat-unsafe executor, gives
  `Rejected` with no submit.


### Milestone 3: The Flow effect and a proof Flow

At the end of this milestone, a Flow can call `runExternalJob`, and a registered proof Flow runs a
job end to end against the fake executor.

Create `shikigami-core/src/Shikigami/Flow/ExternalJob.hs` with a dynamic effect
`ExternalJob :: Effect` and one operation,
`RunExternalJob :: StepName -> ExternalJobRequest -> ExternalJob m ExternalJobOutcome`, plus the
smart constructor `runExternalJob`. Write its production interpreter `runExternalJobWithChild` by
copying `runAcknowledgementWithChild`:

1. derive the child id from the parent coordinates and the key `"flow-" <> stepName`;
2. `spawnChild`;
3. record `ingest-external-job` with `appendJournalEntry`;
4. `awaitChild`.

A `WorkflowChildFailed` becomes a typed `ExternalJobChildFailed` exception, handled like
`ApprovalAcknowledgementFailed` in `runFlowBehavior`. Add `ExternalJob :> es` to `FlowEffects` and
the interpreter to the chain in `runFlowBehavior`. Add a `runExternalJobFake` interpreter for pure
Flow tests.

Add the proof Flow `shikigami-core/src/Shikigami/Flow/ExternalJobProof.hs`. It reads `executor`,
`environment`, `service`, and `message` from the trigger payload and runs
`runExternalJob "echo" request { executor, environment, service, arguments = ["echo", message], repeatSafe = True }`
with a 10-minute deadline. `echo` is safe to run twice. The Flow returns the outcome as JSON.
Register it in `flowRegistry` as `external-job-proof` with a small lifecycle diagram, following the
existing entries. Add the manifest `agents/proof/external-job-proof.dhall`:

```dhall
let A = ../../schema/Agent.dhall

in  A.Agent::{
    , name = "external-job-proof"
    , description = "Proof agent: runs one command through a configured external-job executor"
    , behavior = A.Behavior.Flow { name = "external-job-proof" }
    , trigger = A.Trigger.Event { eventType = "proof.external-job" }
    }
```

Add any identity fields the manifest needs the same way as
`agents/detectors/at-risk-customer-flow.dhall`; Milestone 4 needs a principal.

Extend `shikigami-core/test-postgres/Shikigami/FlowLifecycleSpec.hs` (or add
`ExternalJobFlowSpec.hs`) to run the proof Flow through the full agent-run workflow with the fake
executor registered as `fake`. Assert that the run completes, the Flow's result contains
`"status": "succeeded"`, the parent journal holds one child entry for `flow-echo`, and replaying
the completed parent does not call `submit` again.


### Milestone 4: Fresh authorization

At the end of this milestone, every submission asks Kikan-En immediately before running the
submit command, and a denial produces `ExternalJobDenied` with no command run.

This needs a new action in `Kikan.En.Action`, requested as
`mori://shinzui/kikan-en/okf/improvement-requests/concepts/IR-4`. The request names it
`run_external_job`, for example `RunExternalJob ExternalJobTarget ExternalJobInvocation`:

- **Target:** names the executor, environment, and service. Its resource is
  `external_job_service:<executor>/<environment>/<service>`, granted through an explicit `runner`
  relation.
- **Invocation context:** carries the SHA-256 digest of the expanded argument vector and the
  operation id. The decision proof binds it, so one grant covers many commands against a service,
  but a proof cannot be reused for a different command.

That change belongs to `mori://shinzui/kikan-en` and is made under its own plan. Shikigami builds
Kikan-En from the sibling checkout named in `cabal.project`, so the Shikigami side can be built
against the co-developed contract once it exists. Use the constructor names Kikan-En ships, not
the example names above.

In the `submit-external-job` step, build the action from the request and call
`authorize principal action` immediately before `submit`:

- `ActionPolicyDenied` becomes `ExternalJobDenied` (terminal).
- An outage, invalid coordinates, or a rejected proof throws, so Keiro retries.

This mirrors the sink and capability paths in `shikigami-core/src/Shikigami/Sink/Authorization.hs`
and `shikigami-core/src/Shikigami/Capability/Provider.hs`. Never journal the decision proof. Add
tests with `allowAllActionAuthorizerForTests` and with an authorizer that denies `RunExternalJob`,
and assert that the fake records zero submits on denial.

If the Kikan-En change is not available when Milestones 1 to 3 are done, stop here, leave this
item unchecked, and do not enable an executor catalog in production. With the default
`denyAllActionAuthorizer`, every submission is denied, which is the correct fail-closed behavior.


### Milestone 5: The generic command executor

At the end of this milestone, a worker configured with an executor catalog runs real commands. No
code in this milestone names any particular tool.

Create `shikigami-workers/src/Shikigami/Workers/Executor/Command.hs` exporting
`commandExecutor :: ExecutorDefinition -> ExternalJobExecutor`. Add `typed-process` (or `process`)
to the `shikigami-workers` library dependencies; only `shikigami-core` is restricted.

- **Running a command:** expand the template with Milestone 1's pure functions and start the
  executable with the argument vector (never a shell), in the configured working directory. Pass
  the worker's environment plus `environmentVariables`. Enforce `commandTimeoutSeconds` (killing
  the local command process on timeout, never the external work), and capture stdout and stderr up
  to a fixed bound (64 KiB each).
- **submit:** run the submit command.
  - Exit code 0 with a matching `handlePattern` gives the handle.
  - Exit code `conflictExitCode` gives `ExecutorConflict`.
  - Exit code 0 without a match gives `ExecutorPermanent`: the tool's output format changed, and
    retrying cannot help.
  - Any other exit code or a timeout gives `ExecutorTransient`.
- **observe:** run each observe command in order with `{handle}` filled in. Any non-zero exit or a
  timeout gives `ExecutorTransient`. Parse the last command's stdout with `parseObservation`; a
  parse failure is also transient.
- **Errors and logs:** include the executor name, the exit code, and up to 512 bytes of stderr.
  Never include environment values.

Add the Settei key `executors.catalog_file` to `shikigami-core/src/Shikigami/App/Config.hs`
(optional, no default; environment variable `SHIKIGAMI_EXECUTORS_CATALOG_FILE`). Document it in
`docs/operations/configuration.md`.

In `shikigami-workers/src/Shikigami/Workers/Command/Worker.hs` and the scheduler command:

- With no catalog file configured, use `noExternalJobExecutors`.
- Otherwise load and validate the catalog with `loadExecutorCatalog`, and refuse to start on any
  error.
- Also refuse to start if an executor's `commandTimeoutSeconds` exceeds the worker's run timeout.
  The submit command runs inside a workflow step whose lease is the run timeout plus 30 seconds.
- Build one `commandExecutor` per definition, and pass the result to `agentRunDeps` and the
  scheduler.
- Log one `external_job.executor.installed` line per executor, with its name, environments,
  services, and `submitRepeatSafe`.

Add `shikigami-workers/test/Shikigami/Workers/CommandExecutorSpec.hs`. It writes small stub
executables into a temporary directory: shell scripts in the test fixture, which is acceptable
because tests own them. Assert:

- the exact argument vector for submit and observe, including `{args}` expansion;
- handle extraction;
- the mapping of each exit code;
- status mapping and unmapped values;
- that observe commands run in sequence and stop at the first failure;
- timeout behavior;
- that stderr is truncated and environment values never appear in errors.

Add configuration tests: no catalog yields no executors, an invalid catalog refuses startup, and a
timeout above the run timeout refuses startup.


### Milestone 6: Live validation and documentation

At the end of this milestone, crash recovery is shown on a real cluster through an executor
configured for shiki, and operators and Flow authors have documentation.

Run the live scenario in Concrete Steps. It has two parts:

- **Part A** uses shiki as it is today, with a repeat-unsafe executor and the repeat-safe `echo`
  proof. It shows a full run, and a restart while the Job is running.
- **Part B** needs a shiki release with IR-1. It switches the executor's submit template to
  `--operation-id {operationId}` with `submitRepeatSafe = True`, and shows that a crash right after
  submission still yields exactly one Job.

Then write:

- `docs/operations/external-jobs.md`: the executor catalog format and every field, placeholders,
  the status contract, repeat-safety and why it matters, the timeout constraint, Kikan-En policy for
  `RunExternalJob`, the scheduler role requirement (poll timers fire in the scheduler), timeout
  semantics (work is never cancelled), and the effect of a sleeping or stopped host (work
  continues; polls and deadlines fire late by up to the downtime). Include a complete shiki catalog
  entry as a worked example, clearly labeled as configuration for an external tool.
- A section in `docs/user/flows.md` on `runExternalJob`, with the proof Flow as the example and a
  short sketch of a multi-day runbook Flow that combines `runExternalJob`, `awaitAck`, and sinks.
  The sketch is prose and pseudocode, not a registered Flow.

Link both from `README.md`. Finish the ADR from Milestone 1 with what implementation taught, and
update `docs/roadmap.md`.


## Concrete Steps

Run all commands from `/Users/shinzui/Keikaku/bokuno/shikigami` inside `nix develop`, unless a
step says otherwise. The sibling Kikan-En checkout must exist at `../kikan-project/kikan-en`.

After each milestone:

```bash
cabal build all
cabal test shikigami-core-test --test-options='-p ExternalJob'
cabal test shikigami-core-postgres-test --test-options='-p ExternalJob'
cabal test shikigami-workers-test --test-options='-p Executor'
just keiro-gate
```

For Milestone 2's versioning evidence, run `just keiro-gate` and `git diff --stat domain/`, and
record the output in this plan. The gate should report the new workflow and the new `child`
declaration. If the pre-v1 exception applies, it reports exactly the expected body change recorded
in `docs/workflow-versioning.md`; otherwise it reports a passing patch.

Milestone 6 live scenario. It needs shiki on `PATH`, Docker, and a local PostgreSQL for shiki's
history. `kind` and `kubectl` come from a temporary Nix shell:

```bash
nix shell nixpkgs#kind nixpkgs#kubectl
kind create cluster --name shikigami-jobs
kubectl create namespace demo
kubectl -n demo create deployment echo --image=busybox:1.36 -- sleep 1000000
mkdir -p /tmp/shiki-proof/services
# Write /tmp/shiki-proof/shiki.dhall with a "local" environment pointing at a local database,
# and /tmp/shiki-proof/services/echo.dhall describing deployment "echo", container "busybox",
# namespace "demo", following shiki's docs/user/service-config.md.
```

First submit one run by hand and read the outputs, so the catalog's `handlePattern` and `statusMap`
match what this shiki version prints:

```bash
cd /tmp/shiki-proof && shiki --env local run echo --no-wait -- echo hi
shiki --env local runs show <run id printed above>
```

Then write `/tmp/shiki-proof/executors.dhall`. This is operator configuration, outside the
Shikigami repository:

```dhall
let E = /Users/shinzui/Keikaku/bokuno/shikigami/schema/Executor.dhall

in  [ { name = "cluster-jobs"
      , workingDirectory = Some "/tmp/shiki-proof"
      , environmentVariables = [] : List { mapKey : Text, mapValue : Text }
      , environments = [ "local" ]
      , services = [ "echo" ]
      , submit =
        { executable = "shiki"
        , arguments = [ "--env", "{environment}", "run", "{service}", "--no-wait", "--", "{args}" ]
        }
      , submitRepeatSafe = False
      , conflictExitCode = None Natural
      , handlePattern = "\\(run ([0-9a-f-]+)\\)"
      , observe =
        [ { executable = "shiki", arguments = [ "--env", "{environment}", "runs", "sync", "{handle}" ] }
        , { executable = "shiki", arguments = [ "--env", "{environment}", "runs", "show", "{handle}" ] }
        ]
      , statusField = "status"
      , statusMap =
        [ { value = "Pending", status = E.StatusMapping.status.Pending }
        , { value = "Running", status = E.StatusMapping.status.Running }
        , { value = "Succeeded", status = E.StatusMapping.status.Succeeded }
        , { value = "Failed", status = E.StatusMapping.status.Failed }
        ]
      , exitCodeField = Some "exitCode"
      , pollIntervalSeconds = 5
      , commandTimeoutSeconds = 30
      }
    ]
```

The union-value syntax for `status` will follow whatever `schema/Executor.dhall` exports. Adjust
this example to the final schema and copy the working version into
`docs/operations/external-jobs.md`.

Part A: start the server, the worker, and the scheduler as `docs/user/getting-started.md`
describes, with `SHIKIGAMI_EXECUTORS_CATALOG_FILE=/tmp/shiki-proof/executors.dhall` and
`authorization.actions.mode = kikan` with a policy allowing `RunExternalJob` for the proof agent's
principal. If Kikan-En is not available, record that the live run used the test-only authorizer in
a development build. Trigger the proof agent:

```bash
cabal run shikigami -- enqueue-run external-job-proof --payload '{"executor":"cluster-jobs","environment":"local","service":"echo","message":"hello"}'
kubectl -n demo get jobs --watch
```

When the Job appears, stop the worker and the scheduler (Ctrl-C), wait 30 seconds, and start them
again. Expected: the proof run completes, `shikigami runs show <run id>` (see
`docs/operations/operator-cli.md`) shows output containing `"status": "succeeded"`, and
`kubectl -n demo get jobs` lists one Job for this run.

Part B, after shiki ships IR-1: change the submit arguments to
`[ "--env", "{environment}", "run", "{service}", "--no-wait", "--operation-id", "{operationId}", "--", "{args}" ]`,
set `submitRepeatSafe = True` and `conflictExitCode` to shiki's documented value, and restart.
Trigger the proof again, but stop the worker immediately after the submit command returns: watch
for the `external_job.submitted` log line, then press Ctrl-C at once. Restart it. Expected: one Job
labeled with this operation's `shiki.dev/operation-hash`, and a completed proof run. Then run
`shiki --env local runs list` and confirm a single run for that operation.

Tear down:

```bash
kind delete cluster --name shikigami-jobs
rm -rf /tmp/shiki-proof
```


## Validation and Acceptance

Accept the plan when all of these hold:

1. The PostgreSQL suite proves the following with the fake executor:
   - each outcome (succeeded, failed, unknown, timed out, denied, rejected) reaches the Flow;
   - a simulated crash after submission leads to a second `submit` with the same operation id and
     still one job;
   - a completed parent replays without calling `submit`;
   - a denied authorization runs no command;
   - a repeat-unsafe request on a repeat-unsafe executor is rejected before any command runs.
2. `just keiro-gate` passes with the new workflow declared and the versioning evidence recorded.
3. The command-executor tests pass with stub executables, and without `executors.catalog_file` the
   worker behaves exactly as before. `cabal test` for all suites passes, including
   `PackageArchitectureSpec`, which proves core still links no `process` dependency.
4. `grep -ri shiki` over `shikigami-core`, `shikigami-workers`, `shikigami-server`, `schema`, and
   `agents` finds nothing. shiki appears only in documentation examples and this plan.
5. Live Part A completes on `kind`, and, once IR-1 ships, Part B shows exactly one Job after a
   crash right after submission.

Before this plan, a Flow has no way to start external work and wait for it. After it, the proof
Flow does so through configuration alone and survives a crash.


## Idempotence and Recovery

Every code change is additive. With no catalog configured, the `ExternalJob` effect exists, but any
request is rejected with "unknown executor". Existing Flows do not use it.

At runtime:

- A retried submit step reuses the operation id, so a repeat-safe tool adopts its earlier work.
  For repeat-unsafe executors, admission refuses every request not marked `repeatSafe`.
- A poll timer that fires twice signals an awakeable that is already resolved and stops. A
  deadline that fires after completion does the same.
- Shikigami never cancels external work.
- If the external tool is unavailable, polls keep retrying until the attempt cap. The work's true
  state stays visible in the tool itself; for shiki, `shiki runs show <handle>`, with the handle
  taken from the child workflow's journaled submission.

To roll back, remove `executors.catalog_file` and restart. Children that are already waiting then
fail their polls with "unknown executor" (treated as transient), and their deadlines produce
`TimedOut`. Their external work continues.

The `kind` steps are repeatable after `kind delete cluster --name shikigami-jobs`.


## Interfaces and Dependencies

New modules in `shikigami-core`, all added to `shikigami-core/shikigami-core.cabal`:

```haskell
-- Shikigami.ExternalJob.Types
data ExternalJobRequest = ExternalJobRequest
  { executor :: !Text, environment :: !Text, service :: !Text, arguments :: ![Text],
    deadlineSeconds :: !Int, repeatSafe :: !Bool, pollIntervalSeconds :: !(Maybe Int) }
data ExternalJobHandle = ExternalJobHandle
  { executor :: !Text, operationId :: !OperationId, handle :: !Text }
data ExternalJobStatus = Pending | Running | Succeeded | Failed | Unknown
data ExternalJobReport = ExternalJobReport
  { handle :: !ExternalJobHandle, exitCode :: !(Maybe Int), detail :: !(Maybe Text) }
data ExternalJobOutcome
  = ExternalJobSucceeded !ExternalJobReport
  | ExternalJobFailed !ExternalJobReport
  | ExternalJobOutcomeUnknown !ExternalJobReport
  | ExternalJobTimedOut !ExternalJobHandle
  | ExternalJobDenied !Text
  | ExternalJobRejected !Text
newtype OperationId = OperationId Text   -- smart constructor mkOperationId
operationIdForChild :: WorkflowId -> OperationId
externalJobWorkflowIdFor :: WorkflowName -> WorkflowId -> RunGeneration -> Text -> ExternalJobId

-- Shikigami.ExternalJob.Catalog
data ExecutorDefinition       -- decoded from schema/Executor.dhall
newtype ExecutorCatalog = ExecutorCatalog [ExecutorDefinition]
loadExecutorCatalog :: FilePath -> IO (Either Text ExecutorCatalog)

-- Shikigami.ExternalJob.Template   (pure)
expandCommand :: TemplateContext -> Command -> Either Text (Text, [Text])
extractHandle :: Regex -> Text -> Either Text Text
parseObservation :: StatusSpec -> ByteString -> Either Text (ExternalJobStatus, Maybe Int)

-- Shikigami.ExternalJob.Executor
data ExternalJobExecutor = ExternalJobExecutor { … }   -- as in Milestone 1
newtype ExternalJobExecutors = ExternalJobExecutors (Map Text ExternalJobExecutor)

-- Shikigami.ExternalJob.Workflow
externalJobWorkflow :: ExternalJobRuntime -> Maybe ExternalJobWorkflowInput -> Eff (Workflow : AppEffects) ExternalJobOutcome
externalJobRegistry :: ExternalJobRuntime -> Map WorkflowName WorkflowDef

-- Shikigami.ExternalJob.Timers
externalJobPollFireAction :: ExternalJobExecutors -> TimerRow -> Eff es (Maybe EventId)
externalJobDeadlineFireAction :: TimerRow -> Eff es (Maybe EventId)

-- Shikigami.Flow.ExternalJob
data ExternalJob :: Effect where
  RunExternalJob :: StepName -> ExternalJobRequest -> ExternalJob m ExternalJobOutcome
runExternalJob :: (ExternalJob :> es) => StepName -> ExternalJobRequest -> Eff es ExternalJobOutcome
runExternalJobWithChild :: (Workflow :> es, Store :> es, IOE :> es) => ExternalJobRuntime -> Eff (ExternalJob : es) a -> Eff es a
```

New module in `shikigami-workers`: `Shikigami.Workers.Executor.Command`, exporting
`commandExecutor :: ExecutorDefinition -> ExternalJobExecutor` and using `typed-process` or
`process`.

New file: `schema/Executor.dhall`, the executor catalog type.

New configuration key:

```text
executors.catalog_file    SHIKIGAMI_EXECUTORS_CATALOG_FILE    path to a Dhall executor catalog; unset means no executors
```

The executor contract that any external tool must meet, documented in
`docs/operations/external-jobs.md`:

- **Submit:** returns within the command timeout, exits 0 when the work is accepted, and prints
  text from which `handlePattern` extracts one handle. To be declared repeat-safe, it must accept
  the same `{operationId}` again without starting the work twice.
- **Observe:** the last observe command exits 0 and prints a JSON object whose `statusField` value
  appears in the executor's `statusMap`.

External dependencies:

- `mori://shinzui/shiki/okf/improvement-requests/concepts/IR-1`: needed only to configure shiki as
  a repeat-safe executor (Part B). Shikigami's code does not depend on it.
- The `run_external_job` action requested in
  `mori://shinzui/kikan-en/okf/improvement-requests/concepts/IR-4`. Hard dependency for
  production use in Milestone 4.
- Keiro 0.18's child workflow, awakeable, and timer APIs, already pinned.
- At runtime, the scheduler role must run, because poll and deadline timers fire there.


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
