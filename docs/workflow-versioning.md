# Changing a durable workflow without breaking the ones already running

This is a normative document. Every change to a Shikigami workflow body — every
change to `shikigami-core/src/Shikigami/Agent/Workflow.hs`,
`shikigami-core/src/Shikigami/Agent/Conversation.hs`, or any flow under
`shikigami-core/src/Shikigami/Flow/` — must follow the rules in
[Rules](#the-rules). Plans that touch those files cite this document as their
review standard.

It is written for someone who has never used keiro. Every term is defined where
it first appears.


## Current first-release baseline exception

On 2026-10-30 the user reconfirmed that Shikigami is unused. [ADR-27](adr/0027-the-first-release-establishes-one-clean-durable-baseline.md) applies to [MasterPlan 16](masterplans/16-upgrade-shikigami-to-keiro-0-22-and-retire-superseded-runtime-workarounds.md): consolidate unreleased workflow shapes and remove obsolete patch false branches instead of protecting nonexistent instances. Record exact breaking diagnostics and establish the reviewed current baseline. Same-build replay and all authority/effect boundaries still apply. The rules below govern subsequent evolution and become unconditional at first release/deployment; this exception does not authorize database deletion.


The later [ADR-86](adr/0086-versioned-structured-coordinates-identify-delegated-and-http-runs.md)
identity audit replaces ambiguous delimiter encodings with versioned structured
coordinates. AgentRun and ContinuingWorker declare their v2 child derivations;
their exact native WorkflowBodyChanged findings are retained with the acceptance
evidence. The aggregate replay-impact verdict covers stored-data folds and does
not make those changed child identities compatible. This remains part of the
confirmed unused first-release reset; no old-identity fallback is introduced.

[ADR-87](adr/0087-agent-values-retain-checked-meaning-and-separate-compatibility-scopes.md)
also versions the directory-disabled compatibility scope after reproducing a
sanitizer collision. Its attribution/scope meaning changes intentionally under
this exception. Nominal agent values and the explicit unbound seed retain valid
wire values and existing labels; a neutral native helper-reference diff is not a
claim that the old compatibility namespace is preserved.

[ADR-88](adr/0088-run-keys-separate-caller-and-trigger-coordinates.md) versions
fresh trigger and one-off invocation keys after real queue/inbox collision
controls. HTTP v2 and delegated child coordinates retain their bytes. This is
also an intentional unused first-release identity reset; unchanged native helper
references do not imply old producer-key compatibility.


[ADR-92](adr/0092-review-values-are-checked-and-source-citations-use-structured-coordinates.md)
versions fresh source-citation labels after a collision in two admitted opaque
path/hash pairs. The Flow keeps its labels, order, effects and valid scalar
codecs. Fresh acquired citation identities intentionally change under the unused
first-release exception; neutral native helper references do not imply old
producer-identity compatibility. No old citation factory fallback is introduced.


[ADR-93](adr/0093-review-entities-are-allocated-behind-durable-request-receipts.md)
adds the review identity reservation step and changes resolution input/result
contracts to owner-allocated UUIDv7 entities. Allocation receipts retain logical
request convergence; memory candidate recording and retirement keep their
recovery protocol. Retain the exact breaking native findings under this unused
first-release exception and establish the committed current baseline. No old ID
reader or patch false branch is introduced.


## What a durable workflow is, and why editing one is not like editing ordinary code

Shikigami runs each agent run and each Danwa conversation as a **durable
workflow**: an ordinary Haskell computation (an `effectful` `Eff` program) that
is executed through keiro's runner rather than called directly. The runner's job
is to make the computation survive a crash.

It does that with a **journal**: a per-instance, append-only list of records in
Postgres. Each `step (StepName "open-session") action` in the body either runs
`action` and appends a record named `"open-session"` holding its JSON-encoded
result, or — if a record with that name is already in the journal — skips the
action entirely and returns the recorded result. Re-running a workflow from the
top therefore does not redo work; it fast-forwards through everything already
recorded and continues from the first step that has no record. That fast-forward
is called **replay**.

An **instance** is one run of a workflow, identified by a `WorkflowId`. An
instance is **in flight** when its journal exists but carries no terminal marker
— typically because it is suspended waiting on a human approval, a timer, or a
child workflow. A **deploy** is restarting a Shikigami process with changed
workflow-body code against the same database.

The hazard follows directly. The journal is durable and the code is not. An
instance that suspended last week under last week's code will be replayed by
*this* week's code, against *last* week's journal. The runner has no way to
notice that the body changed. It matches records to steps by name, so if the new
code asks for a name the old journal happens to hold, it gets the old value —
even when the new code meant something entirely different by that name.

Five properties of the runner follow from this, and every rule below is a
consequence of one of them. The source references below use the selected Keiro
0.15.0.0 tag in `mori://shinzui/keiro`, located through Mori. File references
under `keiro/` and `keiro-dsl/` are relative to that canonical project;
artifact-level source-file URIs are pending. The
[dependency cohort](dependency-cohort.md) records the selection and qualification status.

**Replay is keyed by step name, not by source position.** Moving a `step` call
earlier or later in the body, or wrapping it in a different `if`, changes
nothing as long as its name is unchanged (`keiro/src/Keiro/Workflow.hs:24-28`).
This is why reordering code is safe and renaming is not.

**Renaming a step deliberately orphans its record.** The renamed step finds no
record under its new name, so its action runs fresh on the next replay, and the
old record is left behind unread (`keiro/src/Keiro/Workflow.hs:24-26`). This is
not a bug to be worked around — it is keiro's recommended way to make one step
re-run after its meaning changed.

**Step actions are at-least-once, not exactly-once.** If the process dies after
the action ran but before its journal record committed, the next replay runs the
action again. Any step that touches an external system must be idempotent — an
upsert, or a request carrying its own deduplication token.

**A journaled result must keep decoding into the type the step expects.** If it
no longer does, the runner throws `WorkflowStepDecodeError`
(`keiro/src/Keiro/Workflow.hs:829`) and the instance stops making progress.
Changing a step's result type is therefore a breaking change unless the JSON
stays compatible in both directions.

**A step name derived from a run-local counter is not stable across deploys.**
keiro says so about its own ordinal conveniences: "ordinal names are only stable
if the order of `awaitStep`-style calls does not change across deploys; the named
forms are the stable primitives" (`keiro/src/Keiro/Workflow.hs:306-311`). A
counter restarts at zero on every run *including every replay*, so it produces
the same names only while the code that drives it is frozen.


## The two escape hatches keiro gives you

### `patch` — remember which code shape an instance started under

```haskell
patch :: (Workflow :> es) => PatchId -> Eff es Bool
```

(`keiro/src/Keiro/Workflow.hs:368`.) A **patch** is a named branch decision that
is journaled once per instance and replayed verbatim forever after, so an
instance keeps taking the branch it started on even as the code moves on.

It works by comparing against a set the deployed code declares. When an instance
starts fresh, the runner records the currently-active patch ids once, under the
reserved step name `__workflow_patches__`
(`keiro/src/Keiro/Workflow.hs:657`, called at line 584). Each `patch pid` call
then journals its `Bool` under `patch:<pid>` on first encounter and returns the
recorded value on every later replay (handler at
`keiro/src/Keiro/Workflow.hs:781`).

The net effect is the whole point: an instance that was **already in flight**
when the patch shipped has no recorded patch set, so its decision is `False` and
it stays on the old branch. An instance started **after** the patch shipped
recorded the set containing the id, so its decision is `True` and it takes the
new branch. One body serves both.

The active set is not ambient. It is a field of `WorkflowRunOptions`
(`keiro/src/Keiro/Workflow.hs:389-418`), and the plain `runWorkflow` entry point
uses `defaultWorkflowRunOptions`, whose `activePatches` is empty
(`keiro/src/Keiro/Workflow.hs:516-522`). **A workflow run through plain
`runWorkflow` sees every patch as `False`.** In Shikigami nothing may call
`runWorkflow` directly for a durable workflow; see
[the single construction site](#one-construction-site-for-run-options).

One consequence is worth stating plainly, because it is not what most people
assume. A `patch` call resolves against the set **recorded in the journal**, not
against the options the current run was handed
(`keiro/src/Keiro/Workflow.hs:790-792`). So `activePatches` matters at exactly
one moment: when a generation starts fresh and records it. After that the
instance's answer is fixed, and re-invoking it with different options — a resume
worker configured differently, a one-off `runWorkflowWith`, a rolled-back binary
— cannot change it. Two things follow. Handing the resume worker the same options
as the first run is correctness hygiene rather than the thing that makes `patch`
work. And an instance that started before the patch existed has *no* recorded set
at all, so its decision is `False` however the resuming process is configured —
which is precisely the guarantee the mechanism is for.

Note also that keiro records `__workflow_patches__` only when the active set is
non-empty (`keiro/src/Keiro/Workflow.hs:657-660`). A deployment with no patches
writes no such record, so adopting the first patch id is the change that makes
that reserved step name start appearing in fresh journals.

### `continueAsNew` — rotate a journal that would otherwise grow forever

```haskell
continueAsNew :: (Workflow :> es, ToJSON s) => s -> Eff es a
restoreSeed   :: (Workflow :> es, ToJSON s, FromJSON s) => s -> Eff es s
```

(`keiro/src/Keiro/Workflow.hs:337` and `:347`.) A workflow that loops forever —
a conversation that awaits message after message — appends a record per
iteration, and its journal grows without bound. Replay cost grows with it.

`continueAsNew` ends the current **generation** and starts a fresh one carrying a
seed value. The runner appends the seed to generation *g+1* first and only then
writes the terminal rotation marker on generation *g*, so a crash between the two
still converges forward. The next run reads the seed back with `restoreSeed`
called at the top of the body. Generation 0 keeps the original stream name; later
generations get a `#<g>` suffix.

Two consequences bite in practice. Rotation records the active patch set
atomically with the seed, so an asynchronous append arriving before the new
generation's first run cannot force every patch decision to the old branch. And
**rotation invalidates any awakeable id already handed to an external holder**:
the new generation allocates a fresh opaque id, and the id published before
rotation no longer wakes the live instance. Whoever holds it must be re-notified
through the same idempotent, id-keyed callback.

The conversation loop always uses `restoreSeed` and `continueAsNew`. It processes
one turn per generation and carries the next message and conversation state into
the next generation. Plan 65 retired the pre-release legacy branch and patch
after verifying ADR 0027's unused-state conditions. See
[plan 26](plans/26-conversation-workflow-lifecycle-idle-timeout-journal-rotation-session-completion.md).


## The rules

### The one pre-v1 baseline exception

ADR 0027 records that Shikigami has no users or durable state to preserve and is
approaching its first release. Before that release only, a planned v1 surface may
replace an unreleased declaration or workflow shape directly instead of creating
a compatibility path for an empty population. The owning ExecPlan must recheck
all four facts immediately before the change: no resumable workflow journals, no
queued or stored payloads requiring the old codec, no external wire consumers,
and no release or deployment that froze the old shape.

For a declared workflow-body reset, run `keiro-check`, `keiro-inspect`,
`keiro-scaffold`, generated conformance, replay tests, and the full suite. Also
run `keiro-diff` against the pre-reset revision and record its exact breaking findings (including `WorkflowBodyChanged` or
`WorkflowPatchRemoved`, as applicable). That one finding is accepted as evidence of the
deliberate baseline reset; it is not hidden behind an undeclared label, a fake
patch, or a weakened gate. Subsequent work compares against the new baseline.

This exception expires at the first release or deployment, whichever comes
first. Every rule below then applies without exception.

**1. Workflow names and workflow ids are permanent.** The name is the journal's
stream name and the id is its key; changing either makes every existing instance
invisible rather than migrated. Both names live in the checked specification —
`domain/shikigami/agent-run.keiro` and `domain/shikigami/conversation.keiro` —
and `just keiro-diff` classifies a rename as `BREAKING` with the code
`WorkflowStableNameChanged`. A wholesale redesign of a workflow gets a *new*
name, and the old one keeps running until its instances drain.

**2. Prefer additive change — but a *declared* body still needs a patch guard.**
At run time a new step with a new name is safe: no existing journal holds that
name, so every in-flight instance simply runs it on its next replay. Reordering
existing steps is safe too, because replay matches by name.

That is where this rule used to stop, and it was misleading. Run-time safety is
not gate acceptance. **`keiro-dsl diff` classifies any change to a body declared
in `domain/*.keiro` as `BREAKING` unless the entire change sits inside a *new*
`patch` block**, and it treats a pure append exactly like a rename
(`classifyWorkflowBody` in keiro-dsl's `Keiro.Dsl.Diff`; its own test is named
"classifies workflow relabeling and appends as WorkflowBodyChanged"). The rule is
structural: the differ does not consult its own replay verdict, which can say
`replay-neutral` about the very same change. There is no waiver — `--gate` only
adds failures.

So adding a step to a declared workflow costs a patch id, and rule 4's mechanism
applies even when rule 4's *reasoning* does not. Earlier patch-guarded additions to
`domain/shikigami/agent-run.keiro` include: `resolve-profile` inside
`shikigami-resolve-profile-v1`, `run-behavior-v2` inside
`shikigami-behavior-retry-v1`, and the flow memory labels inside
`shikigami-flow-memory-steps-v1`. Because ADR-0001 forbids declaring a guard the
runtime does not honour, the guard also obliges a real `False` branch carrying
the pre-change behavior — so budget for the branch, and delete it with the patch
id once no pre-change instance can resume.

An undeclared step name — one this specification cannot hold, such as anything
carrying a colon — is genuinely free, because there is no declared body for the
differ to compare. That is the only case where "additive needs no ceremony" still
holds.

**3. Rename a step to make exactly that step re-run.** When one step's meaning
changes and you want in-flight instances to redo it under the new meaning,
renaming is the mechanism — not `patch`. The old record is orphaned, the new name
misses, and the action runs fresh.

**4. Use `patch` when an in-flight instance would otherwise be left incoherent.**
Specifically: when the change **adds, removes, or reorders steps that an
in-flight instance may straddle**, or **changes the meaning of a result already
journaled under a name you are keeping**. The test is whether an instance
half-way through the old shape can finish coherently under the new shape. If it
cannot, guard the change:

```haskell
useNewShape <- patch (PatchId "shikigami-some-change-v1")
if useNewShape then newShape else oldShape
```

Register the id as described in [Registering a patch id](#registering-a-patch-id).

**5. Never derive a step name from a run-local mutable counter.** A counter
restarts at zero on every replay, so its names are stable only while the calling
code is frozen — which is precisely the assumption a deploy breaks. Use a
caller-supplied stable label, or keiro's named primitives `sleepNamed` and
`awakeableNamed`. The worked example below is the instance of this rule that
Shikigami actually had.

**6. Use `continueAsNew` for any workflow that journals an unbounded number of
steps**, with `restoreSeed` as the first thing the body does. Re-publish any
awakeable id the previous generation had handed out.

**7. Never change the type a kept step name decodes into.** Rename the step
(rule 3) or guard the change (rule 4). A result type change with the name kept is
how an instance acquires a `WorkflowStepDecodeError` it can never get past.

**8. Patch ids are never reused**, and an id is removed from the active set only
in the same change that deletes its `patch` call from the body — never before.
Removing it while the call remains silently flips every future instance to the
old branch.

**9. Do not roll a deploy back across a patch introduction.** Once instances have
journaled `patch:<id> = true`, code that no longer contains the new branch cannot
serve them. Roll forward instead.


## One construction site for run options

Because `activePatches` travels in `WorkflowRunOptions`, a second options value
constructed somewhere else is a second, divergent answer to "which patches are
active" — and the workflow that gets the wrong one silently takes the wrong
branch. Shikigami therefore constructs `WorkflowRunOptions` in exactly one place:

```haskell
-- shikigami-core/src/Shikigami/Workflow/Versioning.hs
shikigamiActivePatches       :: Set PatchId
shikigamiWorkflowRunOptions  :: AppEnv -> WorkflowRunOptions
shikigamiWorkflowResumeOptions :: AppEnv -> NominalDiffTime -> WorkflowResumeOptions
```

Every durable workflow run goes through those values: the agent-run workflow
(`shikigami-core/src/Shikigami/Agent/Workflow.hs`), the conversation workflow
(`shikigami-core/src/Shikigami/Agent/Conversation.hs`), the approval child
(`shikigami-core/src/Shikigami/Agent/Approval/Workflow.hs`), and the resume worker
that re-invokes both after a crash or a wake
(`shikigami-workers/src/Shikigami/Agent/Workflow/Resume.hs`). The resume worker
carries them through `WorkflowResumeOptions.runOptions`
(`keiro/src/Keiro/Workflow/Resume.hs:182-186`), so a resumed run honours exactly
the options its first run did.

New workflow run or resume options belong in that module too rather than in a
fresh value at a call site. Keep the lease domains distinct: the PGMQ delivery
heartbeat in
`docs/plans/17-behavior-retry-semantics-run-timeouts-and-visibility-heartbeat.md`
uses `Keiro.PGMQ.JobContext.extendLease`; the Keiro resume worker injects
`WorkflowRunOptions.leaseHeartbeat` itself and is configured through
`WorkflowResumeOptions.leaseTtl`. Direct runs leave `leaseHeartbeat` unset.


## Registering a patch id

A patch id is a **declared surface**, not just a Haskell literal. It is written
in the checked specification, and the Haskell value is generated from it.

1. Declare the patch inside the owning workflow's body in
   `domain/shikigami/agent-run.keiro`, `domain/shikigami/conversation.keiro`,
   or `domain/shikigami/approval.keiro`:

   ```text
   patch shikigami-emit-signal-labels-v1 {
   }
   ```

   The block may be empty. It lists the *declarable* labels the patch guards, and
   a label that is computed at run time or carries a colon cannot be declared at
   all (see [Undeclarable label families](#undeclarable-label-families)).

2. A patch id is a wire word: it must match `[A-Za-z0-9][A-Za-z0-9_-]*`. **It may
   not contain a dot.** `shikigami.emit-signal-labels-v1` fails to parse;
   `shikigami-emit-signal-labels-v1` is the same intent, spelled legally.

3. Regenerate and gate:

   ```bash
   just keiro-scaffold
   just keiro-gate <merge-base>
   ```

   Scaffolding puts the id into `declaredPatches` in the generated
   `Shikigami.AgentRun.Generated.WorkflowRuntime` (or the conversation's
   equivalent), which is where `shikigamiActivePatches` reads it from. Nothing
   hand-maintains a second list.

4. The generated conformance target asserts the patch set, so
   `shikigami-core/src/keiro-dsl-conformance.workspace.shikigami/src/KeiroConformance/Expectations.hs`
   must be updated in the same change. That file is hand-owned and created once;
   keiro-dsl will never rewrite it.

Declaring the patch and calling `patch` at run time check different things and
neither substitutes for the other. The runtime call keeps an in-flight instance
coherent across the deploy; the declaration plus `just keiro-diff` refuses a
change that would strand it in the first place.


## Worked example: `emitSignal` step names

This historical example motivated this document and illustrates rule 5. Plan 65
retired the ordinal branch and its patch together under ADR 0027; current flows
always use explicit stable labels. The example explains how to migrate when
real pre-change journals exist.

**Before.** The `Sink` capability interpreter in
`shikigami-core/src/Shikigami/Flow/Capability.hs` allocated a fresh `IORef`
counter per interpreted flow run and named each emission's journal step from it:

```haskell
runSink SinkEnv {..} action = do
  ordinalRef <- liftIO (newIORef (0 :: Int))
  interpret
    ( \_ -> \case
        EmitSignal sink output -> do
          ordinal <- liftIO (atomicModifyIORef' ordinalRef \n -> (n + 1, n))
          let stepName = StepName ("emit-signal:" <> Text.pack (show ordinal))
          ...
    )
    action
```

While the flow code is frozen this is fine: the i-th emission always gets ordinal
i, on a first run and on every replay alike.

**Why it breaks on a deploy.** Consider `atRiskCustomerFlow`, which emits an
alert (`emit-signal:0`), parks on an acknowledgement awakeable, and — if the
acknowledgement times out — emits an escalation (`emit-signal:1`). Suppose a
deploy inserts a new emission *before* the alert. An instance parked at the
acknowledgement now resumes under code where the new emission is ordinal 0 and
the alert is ordinal 1. Two things go wrong at once. The new emission looks up
`emit-signal:0`, finds the *alert's* record, and replays it — so the new signal
silently reports the old signal's result and is never actually sent. And the
alert, now asking for `emit-signal:1`, finds nothing, re-runs, and enqueues a
duplicate: the outbox id is derived from the workflow id and the step name
(`shikigami-core/src/Shikigami/Flow/SinkOutbox.hs:125-126`), so a different step
name means a different id and no deduplication.

**After.** The label is supplied by the caller and never derived from anything
that moves:

```haskell
data Sink :: Effect where
  EmitSignal :: Text -> Agent.Sink -> Value -> Sink m SinkResult

emitSignal :: (Sink :> es) => Text -> Agent.Sink -> Value -> Eff es SinkResult
```

so `atRiskCustomerFlow` reads `emitSignal "alert" ...` and
`emitSignal "escalate" ...`. Inserting a third emission now cannot disturb
either, because neither name depends on how many emissions precede it.

**Why the change itself needs a patch.** Switching schemes is exactly rule 4: it
renames every emission step at once, so an instance parked between two emissions
would resume into a body whose names no longer match its journal — its alert
record `emit-signal:0` would be orphaned and re-enqueued as `emit-signal:alert`,
producing the duplicate the change exists to prevent. The interpreter therefore
decides the scheme once per run, under a patch:

```haskell
useLabels <- patch (PatchId "shikigami-emit-signal-labels-v1")
```

In-flight flows resume with `useLabels = False`, keep the ordinal scheme, and
replay their journals correctly. Fresh flows record the patch set, get
`useLabels = True`, and use labels for good. Once no pre-change instance can
still resume, the `False` branch and the id are deleted together — rule 8.

The label is a caller-supplied token, not runtime data. Values that are
themselves replay-stable (a ticket id read out of a journaled verdict, say) are
permissible but discouraged; prefer a static token.


## Historical pre-release journal inventory

The patch narratives in this section describe the superseded pre-release
baseline. Plan 93 removes those patch calls and declarations under ADR-27.
Current workflows execute the selected behavior directly; `shikigamiActivePatches`
is empty. Genuine runtime alternatives (non-Skill inline behavior, configured
capabilities and generation rotation) remain. This historical explanation does
not require retaining readers or false branches for the unused old population.
The checked workspace, generated facts and same-build tests define the current
step inventory. Future deployed changes follow the normative rules above.

The checked specification and generated facts are the maintained inventory of
static labels. Read them together with the body and capability interpreters for
computed label families; a duplicated line-number census quickly becomes stale.

| Workflow | Declaration | Generated facts | Runtime body |
| --- | --- | --- | --- |
| `shikigami.agent-run` | [Agent run](../domain/shikigami/agent-run.keiro) | [AgentRun facts](../shikigami-core/src/Shikigami/AgentRun/Generated/WorkflowFacts.hs) | [Workflow.hs](../shikigami-core/src/Shikigami/Agent/Workflow.hs) |
| `shikigami.danwa-conversation` | [Conversation](../domain/shikigami/conversation.keiro) | [DanwaConversation facts](../shikigami-core/src/Shikigami/DanwaConversation/Generated/WorkflowFacts.hs) | [Conversation.hs](../shikigami-core/src/Shikigami/Agent/Conversation.hs) |
| `shikigami.approval` | [Approval](../domain/shikigami/approval.keiro) | [Approval facts](../shikigami-core/src/Shikigami/Approval/Generated/WorkflowFacts.hs) | [Approval/Workflow.hs](../shikigami-core/src/Shikigami/Agent/Approval/Workflow.hs) |
| `shikigami.execution` | [Execution driver](../domain/shikigami/execution-driver.keiro) | [ExecutionDriver facts](../shikigami-core/src/Shikigami/ExecutionDriver/Generated/WorkflowFacts.hs) | [Execution/Driver.hs](../shikigami-core/src/Shikigami/Execution/Driver.hs) |
| `shikigami.worker-session` | [Continuing worker](../domain/shikigami/continuing-worker.keiro) | [ContinuingWorker facts](../shikigami-core/src/Shikigami/ContinuingWorker/Generated/WorkflowFacts.hs) | [WorkerSession/Workflow.hs](../shikigami-core/src/Shikigami/WorkerSession/Workflow.hs) |

The approval child journals `ingest-approval`, `notify`, and its `decision` wait.
All agent runs use this child. Plan 65 removed the unused pre-release approval
branch and its patch together. Agent runs also declare profile and
overlay resolution, routing, practice-review evidence/evaluation/attention, and
practice-review memory transitions. These are persisted contracts, not optional
additions to the census.

Flow capability families include `recall-<label>`, `remember-<label>`, and
`emit-signal:<label>`. Child identity comes from the governed delegation/approval
call site. Conversation rotation uses static per-turn labels and has no legacy
message-id or ordinal journal branch. `danwa-reply:<messageId>` identifies a sink intent rather than
a workflow journal step.

Keiro writes reserved patch, terminal, generation, sleep, awakeable, and child
records as well. Their definitions belong to `mori://shinzui/keiro`, at
project-relative `keiro/src/Keiro/Workflow/Types.hs` (artifact-level URI pending).
Never reuse a reserved name for an application step.

The two memory families are marked `declared` because they are the first
flow-side journal names this service can gate rather than merely keep stable by
convention. `runMemory` journals a flow's `recall` and `remember` under the
caller's label, and the labels every *registered* flow reaches are declared in
`domain/shikigami/agent-run.keiro` — today `recall-risk-history`,
`remember-acknowledged`, `remember-declined`, and `remember-escalated`. The first
router similarly owns the static `route-catalog-architecture-practice` and
`route-decision-architecture-practice` labels. Under ADR-0027 those two labels
enter the unreleased v1 body directly: there is no prior durable population to
preserve and therefore no legacy branch to model. Adding a
labeled memory call to a registered flow therefore also means adding its label
there and passing `just keiro-gate`.

The typed-decision application patch is `shikigami-flow-decisions-v1`. Its real runtime
guard enables the finite typed Decision capability; an old patch snapshot keeps
the disabled interpreter and makes no `decision-policy` lookup. Existing flows
have no decision slots and add no decision steps. The checked segment declares:

| Label | Persisted contract |
| --- | --- |
| `decision-policy` | Bounded refusal or `DecisionPolicySnapshot`, format 1, for all slots |
| `decision-prepare-triage` | Bounded refusal or `PreparedDecision`, including immutable program/model/input bindings |
| `decision-result-triage` | `DecisionOutcome`, format 1, containing rich result or bounded refusal |
| `decision-catalog-investigate` | Existing versioned `CandidateCatalog` |
| `decision-prepare-investigate` | Same prepared envelope for the second slot |
| `decision-result-investigate` | Same versioned outcome envelope for the second slot |

Each slot is one-use within a generation. Completed results use retained pure
codecs without executable/model lookup or current domain revalidation. Pending
results require the exact pinned executable, parameter/derivation state and
credential binding. Keep historical codecs independently of retired executables;
unknown versions fail explicitly. Changes to local derivation require a new
immutable program identity even when provider requests remain identical. See
[the authoring guide](shikumi-flow-decisions.md) and [ADR 0045](adr/0045-flow-policy-pins-pending-decisions-and-retains-completed-result-codecs.md).

Do not roll back across this patch introduction. Preserve both branches until
no pre-change instance can resume, then retire the guard and declaration
together. **A subsequent change to a
declared workflow body still requires a new real patch guard**, including pure
appends, unless the released differ explicitly classifies a supported rotation
extension as additive. Plan 65's accepted breaking reports apply only to its
verified unused pre-v1 reset; the gate is unchanged.

Delegation derives child workflow identity from the parent workflow, target agent
and caller-supplied stable key. The declaration-driven supervisor derives keys
from the delegates stored in the journaled `lookup-agent` result, so later
manifest edits cannot move an in-flight run's children.

Continuing sessions introduce a new workflow family with no historical body.
They restore a seed, publish a generation-owned mailbox wake, select at most one
accepted assignment, await its governed child and retain its result before
rotation. The session and assignment determine the child identity independently
of coordinator rotation. Existing one-shot delegation retains its original
request and step shape. Missing objective providers admit no new assignment.
Future changes to this body follow the same patch and gate rules. See
[ADR 0062](adr/0062-session-generations-await-governed-children-and-retain-checkpoint-intents.md).


Agent runs also declare `shikigami-durable-execution-v1`. Eligible fresh leaf
Skills journal `admit-skill-execution` and await the registered execution child.
Old patch snapshots keep `run-behavior-v2`; fixed supervisors, routed Skills and
Flows retain their existing orchestration. A completed accepted result is read
from protected storage without looking up a live provider. Session, memory and
sink ownership and step codecs are unchanged. Preserve both branches and roll
forward across this patch introduction. See [ADR 0057](adr/0057-skill-parents-admit-frozen-assignments-and-await-execution-children.md).

Agent runs also declare `shikigami-worker-coordination-v1`. Old Flow journals
keep the disabled Workers interpreter and make no coordination-policy lookup.
New Flows journal `worker-coordination-policy`, a bounded scope fingerprint or
refusal. Each command reacquires that retained scope and fresh exact authority.
Future registered callers must declare their concrete `workers-command-<label>`,
`workers-state-<label>`, `workers-subscribe-<label>` and `workers-read-<label>`
steps and generation-owned event waits. Event acceptance and wake completion
share a transaction; notifications target only their publishing generation.

Old Skills retain their original static menu branch. The explicit new
`CoordinatingSkill` behavior requires the new patch and an admitted worker tool
before model dispatch. Ordinary fixed supervisors retain their old behavior;
conversations and ephemeral execution do not admit this coordinator behavior.
Accepted execution snapshots retain their original bindings. Session replay
repairs missing child input and acknowledges an already retained result under
the existing labels and codecs. These repairs add no parent journal step.
See [ADR 0066](adr/0066-worker-commands-require-retained-scopes-and-fresh-exact-authority.md).

Agent runs also declare `shikigami-governed-workspaces-v1`. Only journaled
requests for the separate `workspace.edit`, `workspace.exec` or `workspace.git`
capabilities select `resolve-governed-capability-overlays` and
`admit-workspace-skill-execution`. The exact operator-installed adapter registry
must admit their descriptor. File, process and local Git adapters are now
implemented and installed only through explicit reviewed operator configuration.
The trusted workspace host freezes reviewed repository instructions before the
first model request. Old patch snapshots retain the original resolution and
Skill admission labels and cannot gain mutation authority. Existing observation
requests retain their original path. The normal configured parent/child upgrade
passes the complete native process/Git/workflow gate. Roll forward across this
patch; handoff and integration qualification remain separate gates in
[Plan 96](plans/96-provide-governed-mutable-repository-workspaces-for-durable-agents.md).

## Undeclarable label families

Conversations also declare `shikigami-conversation-durable-execution-v1`.
Eligible new Skills admit a protected assignment and await the same execution
child while old snapshots retain `run-behavior-v2`. The atomic assistant/reply
owner remains unchanged. Ingress distinguishes accepted turns from completed
replies, and asynchronous wakes append only to their publishing generation.
Historical timer payloads remain readable. See
[ADR 0058](adr/0058-conversation-acceptance-and-wakes-retain-their-generation.md).

The checked specification cannot hold every name in the table above. A keiro-dsl
workflow label is a compile-time wire word matching `[A-Za-z0-9][A-Za-z0-9_-]*`,
so a label that carries a colon or is computed at run time cannot be declared —
which means `just keiro-diff` cannot gate a change to it. The remaining application family is
`emit-signal:<label>`; approval now has a dedicated child with static labels and
conversation turns occupy separate generations. The census with owners is
`docs/architecture/shikigami-domain-inventory.md`.

**The conversation family is no longer on that list for fresh instances, and how
it left is the transferable lesson.** Its labels carried a `:<messageId>` suffix
for one reason: a keiro journal matches records to steps by label, and the old
body ran every turn of a conversation in a single immortal generation, so two
turns could not both write `record-user`. The fix was not to find a declarable
spelling of the suffix — it was to remove the reason for the suffix.
`docs/plans/26-conversation-workflow-lifecycle-idle-timeout-journal-rotation-session-completion.md`
rotates onto a fresh generation after every turn, so a generation holds exactly
one turn, every label is written at most once, and `record-user`,
`run-behavior-v2`, `record-assistant-and-reply`, `turn-result`, and
`next-message` are all plain wire words the specification can hold. Plan 65 retired the suffixed branch and its patch from the unused baseline.

Before reaching for a computed suffix, ask what forces it. If the answer is
"several of these happen in one generation", rotation may remove the question
entirely — and a bounded journal is worth having on its own.

Flow memory labels are deliberately *not* in that list, and the contrast is the
point. `recall-<label>` and `remember-<label>` use a hyphen where the sink family
uses a colon, which is the whole difference between a name this gate governs and
a name it cannot see. The same fix already applies to patch ids, where
`shikigami.emit-signal-labels-v1` fails to parse and
`shikigami-emit-signal-labels-v1` does not. A new capability choosing a separator
for its journal labels should choose the hyphen for this reason, and accept the
cost that comes with it: a new label on a registered flow is now a specification
edit, a regeneration, and a gate run, not just a Haskell edit.

Note what the worked example did and did not achieve. `emit-signal:alert` is
*stable* — that was the point — but it still carries a colon, so it is still
outside the specification. Making it declarable means choosing a separator the
grammar accepts, which is a second and independent decision about a persisted
step name;
`docs/plans/16-honest-sink-handlers-real-reiaction-and-honored-declaration-fields.md`
owns that family.


## Before you merge

Run the gate whenever the change touches `domain/`, the generated layer under
`shikigami-core/src/Shikigami/*/Generated/`, or a durable identity:

```bash
just keiro-gate <merge-base>
```

It runs `keiro-check`, `keiro-inspect`, `keiro-scaffold` followed by
`git diff --exit-code`, `keiro-diff`, and the generated conformance test. A
`BREAKING` finding exits non-zero and is a deployment gate, not an advisory.

The deploy-simulation tests in
`shikigami-core/test/Shikigami/WorkflowVersioningSpec.hs` are the executable
version of this document: they start a workflow under old-shape code, suspend it,
swap in new-shape code, and prove the in-flight instance takes the old branch
while a fresh one takes the new. A change to a rule here should change a test
there.


## Related

* `mori://shinzui/keiro-runtime-patterns/docs/keiro-durable-workflows` — the
  fleet standard this document specializes for Shikigami.
* `mori://shinzui/keiro-runtime-patterns/docs/keiro-evolution-and-rollout` — the
  gate ladder and rollout ordering rules.
* `docs/adr/0001-declare-only-what-the-runtime-executes.md` — why a surface is
  declared only when the generated artifact is the one the runtime executes.
* `docs/architecture/shikigami-domain-inventory.md` — the declared and
  undeclared surface census.

## Runtime maintenance after the first-release baseline

[ADR 0038](adr/0038-runtime-startup-and-maintenance-share-validated-owners.md) owns
startup and retention. The runtime verifies migrations before acquiring resources,
registers the evidence catalog, and uses one core registry for agent runs, approval
children and conversations. The worker's bounded resume command previews by default:

```bash
shikigami-worker --resume-passes 10 --resume-limit 100
shikigami-worker --resume-passes 10 --resume-limit 100 --force
```

Each pass logs all released summary fields. Zero `advanced` ends the drain even
when blocked candidates remain; `discovered` is not a progress test. The continuous
runner retains upstream failure isolation. The released success-summary callback is
absent, so successful per-pass summaries are available through the bounded action.

One dispatcher drains up to 100 sleep/custom timers per pass. Hourly GC collects at
most 100 terminal instances older than 90 days, excluding live workflows and completed
children of live parents. This bounds workflow deduplication: older job redelivery
requires operator review. Evidence streams, rich query rows and sink delivery receipts
are separate retention owners and are not collected by this workflow policy.


## Plan 65 qualification baseline

The workflow reset is `f1118af`, followed by strict runtime identities in
`8a70c92` and the generated queue/evidence-prefix reset in `f43b0ca`. The exact
accepted diagnostics are retained under [plan-65 evidence](evidence/plan-65/).
Ordinary gates passed on the reconciled catalog (`6f21b6e`), runtime assembly
(`66ffd29`), nominal scalar checkpoint (`a083d88`) and final qualification
(`8b0a98a`). The final report has no findings. These later gates do not
waive or reclassify the earlier intentional breaks.

Generation zero has one explicitly unbound conversation seed. Its complete
codec accepts the empty agent name only with unresolved identity, zero turns
and absent messages. Ingress names and carried generations remain strict. This
preserves the seed's journal bytes without weakening RunJob validation.

A workflow that crashes before its first committed journal entry is not yet a
resumable instance. The queue owns that retry; the failed-workflow resurrection
owner applies once a journal exists. The PostgreSQL test first commits ingestion
before injecting a failed step so it exercises that actual boundary.
