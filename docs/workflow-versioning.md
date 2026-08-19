# Changing a durable workflow without breaking the ones already running

This is a normative document. Every change to a Shikigami workflow body — every
change to `shikigami-core/src/Shikigami/Agent/Workflow.hs`,
`shikigami-core/src/Shikigami/Agent/Conversation.hs`, or any flow under
`shikigami-core/src/Shikigami/Flow/` — must follow the rules in
[Rules](#the-rules). Plans that touch those files cite this document as their
review standard.

It is written for someone who has never used keiro. Every term is defined where
it first appears.


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
consequence of one of them. They are verified against keiro 0.13.0.0, whose
source is reachable at the path `mori registry show keiro --full` reports;
`keiro/src/Keiro/Workflow.hs` below means that checkout's
`keiro/src/Keiro/Workflow.hs`.

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

Nothing in Shikigami calls `continueAsNew` today. The conversation loop is its
intended first consumer, in
`docs/plans/26-conversation-workflow-lifecycle-idle-timeout-journal-rotation-session-completion.md`.


## The rules

**1. Workflow names and workflow ids are permanent.** The name is the journal's
stream name and the id is its key; changing either makes every existing instance
invisible rather than migrated. Both names live in the checked specification —
`domain/shikigami-agent-run.keiro` and `domain/shikigami-conversation.keiro` —
and `just keiro-diff` classifies a rename as `BREAKING` with the code
`WorkflowStableNameChanged`. A wholesale redesign of a workflow gets a *new*
name, and the old one keeps running until its instances drain.

**2. Prefer additive change.** A new step with a new name is always safe: no
existing journal holds that name, so every in-flight instance simply runs it on
its next replay. Reordering existing steps is safe too, because replay matches by
name. These two cover most changes and need no ceremony.

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
shikigamiWorkflowRunOptions  :: WorkflowRunOptions
shikigamiWorkflowResumeOptions :: WorkflowResumeOptions
```

Every durable workflow run goes through those values: the agent-run workflow
(`shikigami-core/src/Shikigami/Agent/Workflow.hs`), the conversation workflow
(`shikigami-core/src/Shikigami/Agent/Conversation.hs`), and the resume worker
that re-invokes both after a crash or a wake
(`shikigami-workers/src/Shikigami/Agent/Workflow/Resume.hs`). The resume worker
carries them through `WorkflowResumeOptions.runOptions`
(`keiro/src/Keiro/Workflow/Resume.hs:182-186`), so a resumed run honours exactly
the options its first run did.

New per-run options belong in that module too rather than in a fresh value at a
call site. The lease heartbeat that
`docs/plans/17-behavior-retry-semantics-run-timeouts-and-visibility-heartbeat.md`
needs is the next such field.


## Registering a patch id

A patch id is a **declared surface**, not just a Haskell literal. It is written
in the checked specification, and the Haskell value is generated from it.

1. Declare the patch inside the owning workflow's body in
   `domain/shikigami-agent-run.keiro` or `domain/shikigami-conversation.keiro`:

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

This is the change that motivated this document, and it is a textbook instance of
rule 5.

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


## What Shikigami journals today

Every step name any Shikigami workflow can write, as of this document. A change
to this table is a change to a persisted compatibility identifier and is governed
by the rules above.

```text
agent run  (workflow "shikigami.agent-run",
            shikigami-core/src/Shikigami/Agent/Workflow.hs)
  ingest-job                       :187
  lookup-agent                     :188
  open-session                     :228
  recall                           :229
  run-behavior                     :236
  fail-session                     :239
  record                           :249
  complete                         :250
  dispatch-sinks                   :491
  approval:<SinkKind>:<ordinal>    :299-300   -- ordinal-derived; see below
  child:<childWorkflowId>          Shikigami/Agent/Delegate.hs:46-62

conversation  (workflow "shikigami.danwa-conversation",
               shikigami-core/src/Shikigami/Agent/Conversation.hs)
  ingest-start                     :132
  lookup-agent                     :144
  resolve-session                  :166
  record-user:<messageId>          :168
  run-behavior:<messageId>         :173
  record-assistant-and-reply:<messageId>  :263
  turn-result:<messageId>          :259
  danwa-reply:<messageId>          :267
  next-message:<ordinal>           :255       -- ordinal-derived; see below

flow capabilities  (run inside the agent-run workflow)
  classify                         Shikigami/Flow/AtRiskCustomer.hs:45
  await-ack                        Shikigami/Flow/AtRiskCustomer.hs:50
  <step>:notify                    Shikigami/Agent/Approval.hs:157
  emit-signal:<label>              Shikigami/Flow/Capability.hs   -- post-patch
  emit-signal:<ordinal>            (pre-patch; in-flight instances only)

reserved by keiro  (keiro/src/Keiro/Workflow/Types.hs)
  __workflow_completed__           :318
  __workflow_cancelled__           :327
  __workflow_failed__              :332
  __workflow_continued_as_new__    :345
  __workflow_seed__                :355
  __workflow_patches__             :389
  patch:<patchId>                  :393
  sleep:<label>                    :360
  awk:<uuid>                       :365
  awkid:<label>                    :371
  child:<childWorkflowId>          :376
```

Two ordinal-derived names remain, and this document does not fix them; it records
that they are governed by rule 5 and names their owners.
`approval:<SinkKind>:<ordinal>` counts approvals within one run, so inserting a
sink into an agent declaration shifts the names of every later approval.
`next-message:<ordinal>` counts conversation turns and is owned by plan 26. A
third instance is not a step name but has the same shape: `delegate` derives a
child workflow id from `freshOrdinal "delegate"`
(`shikigami-core/src/Shikigami/Agent/Delegate.hs:46-48`), and the child's journal
record is named after that id, so an ordinal shift moves the child. Plan 35 owns
delegation.


## Undeclarable label families

The checked specification cannot hold every name in the table above. A keiro-dsl
workflow label is a compile-time wire word matching `[A-Za-z0-9][A-Za-z0-9_-]*`,
so a label that carries a colon or is computed at run time cannot be declared —
which means `just keiro-diff` cannot gate a change to it. Those families are
`approval:<SinkKind>:<ordinal>`, `<step>:notify`, `emit-signal:<label>`, and
every per-message conversation label; the census with per-family owners is
`docs/architecture/shikigami-domain-inventory.md`.

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
