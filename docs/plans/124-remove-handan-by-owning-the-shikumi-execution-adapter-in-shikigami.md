---
id: 124
slug: remove-handan-by-owning-the-shikumi-execution-adapter-in-shikigami
title: "Remove Handan by owning the Shikumi execution adapter in Shikigami"
kind: exec-plan
created_at: 2026-11-05T13:01:31Z
provenance:
  created_by:
    model: "gpt-6.1-sol"
    harness: "codex-cli"
    at: 2026-11-05T13:01:31Z
  revisions:
    - model: "gpt-6.1-sol"
      harness: "codex-cli"
      at: 2026-11-05T13:07:55Z
      mode: "implement"
      note: "Implement local Shikumi runtime and task catalog, remove Handan, and qualify preserved behavior"
---

# Remove Handan by owning the Shikumi execution adapter in Shikigami

This ExecPlan is a living document. Keep Progress, Surprises & Discoveries,
Decision Log, and Outcomes & Retrospective current during implementation.
Follow `.codex/skills/exec-plan/PLANS.md`, `ADR.md`, `PROVENANCE.md`, and
`FRICTION.md` in that skill directory when recording changes and evidence.


## Purpose / Big Picture


Shikigami should execute its registered programs directly through Shikumi without
requiring the separate Handan application library. Operators will keep the same
agent declarations, configuration, outputs, model selection, and recovery
behavior, while maintainers can build and package Shikigami without the Handan
Git source pin. Complete calls and streaming calls will share one
Shikigami-owned interpreter setup.

Success is observable through the shipped heartbeat program, governed typed
decisions against deterministic providers, and replay of committed decisions
with no live model binding. The resolved Cabal plan and exported Nix runtime
closure must contain no `handan-core`. This is a refactor of existing behavior;
it does not introduce new model capabilities or complete the separate release
qualification work in [plan 80](80-configure-model-providers-and-agent-launches-through-baikai.md).


## Progress


- [x] M1 (2026-11-05): The shared local runtime executes complete and streaming decisions; all 19 governed runner cases and all 742 core pure tests pass, including complete/stream structured judgments, model selection, retries, terminal callbacks and cancellation.
- [x] M2 (2026-11-05): Registered behaviors use the local task interface; all behavior tests pass. The committed isolated project and regenerated production export contain no Handan package or source entry. Export: 382 packages, six repositories; only five exclusive packages and the Handan source pin disappear, with all retained package records unchanged.
- [ ] M3: Behavioral regression, durable replay, workflow conformance, and immutable role builds pass, and current documentation describes direct Shikumi execution.

Implementation baseline: `ef6e11b804b9738f65ad87fde05e4be7eec9dc19` on
2026-11-05 (the planning inspection was `cc7433ec`). This is a standalone plan; it has no MasterPlan prerequisite. Reconcile
concurrent edits to the decision runner and dependency cohort before proceeding.

Source checkpoint: the shared local runtime, minimal task interface, dependency
removal and ownership documentation are implemented. All 19 governed runner
tests, all 742 core pure tests, 50 qualification-tool tests, strict user-guide
validation and Haskell conventions pass. The fresh isolated solve removes
`handan-core`, `shikumi-eval`, `shikumi-trace-otel`, `tasty` and `tasty-golden`
from the production closure with no added packages or remaining-version changes.
The isolated all-components build and pure suites pass (742 core, 37 agent,
107 server). The native workflow gate against `ef6e11b8` has no findings and
reports `replay-neutral`. Serial PostgreSQL suites pass: 604 core database cases and 339 worker cases.
The heartbeat CLI returns its original digest and echoed payload. Only the five
immutable role builds remain. Packaging inputs are exported from this exact
isolated solve; committed-input role builds exclude the independent uncommitted
Biscuit update while preserving it in the working tree.


## Surprises & Discoveries


2026-11-05: `agents/README.md` does not exist; detector guidance is in
`agents/detectors/README.md` and current user guides. ADRs use the established
filesystem format; `mori.dhall` declares no profiled ADR bundle.

2026-11-05: Concurrent work changed the Biscuit source pin, metadata and cohort
while this implementation was running (FRIC-61 in `docs/friction-log/`). The source checkpoint stages only Handan
removal from shared files and preserves those other edits. Reconcile the
committed cohort before final isolation/export; unrelated drift must be traced
to that independent update rather than attributed to this refactor.


2026-11-05: The first isolated all-components build found workspace prototype
fixtures left behind by the initiative implementation: two `AgentRunDeps`
constructors lacked the required `initiatives` seed. They now use the existing
`disabledInitiatives`, matching the other fixtures (FRIC-62 in
`docs/friction-log/`). This repairs the required build without adding initiative
behavior or changing production workflow bodies.


## Decision Log


2026-11-05: Own the small execution adapter in Shikigami and call Shikumi's public
interpreters directly. Handan currently adds a runtime record and interpreter
composition; Shikigami already owns admission, evidence, accounting, and replay.
No upstream dependency release or compatibility override is required.

2026-11-05: Replace the legacy task and envelope wrappers with only the behavior
interface this repository uses. Preserve all three registered task names and
JSON outputs. Handan's CLI flags, artifact publication, evaluation handles, and
trace-file management are outside this refactor.

2026-11-05: Preserve workflow labels, result formats, program commitments, and
provider-attempt boundaries. A dependency-adapter change alone does not justify
a new patch, a program-version bump, or a first-release baseline reset. If an
actual semantic change proves necessary, revise this plan and apply
`docs/workflow-versioning.md` before implementing that change.


## Outcomes & Retrospective


(To be filled during and after implementation.)


## Context and Orientation


A Shikumi `Program i o` is a typed model computation from input `i` to output
`o`. An interpreter supplies its effects, including model routing, provider
calls, retries, and concurrency. A provider is the transport implementation for
a selected model. Shikigami's durable workflow journal stores completed step
results; replay reads those stored results instead of repeating model calls.
A result codec is the pure encoder/decoder retained to read those results even
when the executable program or credential has been removed.

The direct dependency is `mori://shinzui/handan/packages/handan-core`, pinned at
`8e98b0a955f908f70657c04f384b6286e4967422` in `cabal.project`. In that project,
`handan-core/src/Handan/Runtime.hs` holds `Runtime`, `newRuntime`, and
`runProgramWith`; source-file artifact URIs are pending. Its runtime record
contains Shikumi `LLMConfig` and a default Baikai model. `newRuntime` registers
the Claude handler globally and chooses Claude Haiku 4.5. `runProgramWith`
composes `runEff`, `runErrorNoCallStack`, `runConcurrent`, `runRouting`,
`runLLMResilient`, `routeLLM`, and `runProgram`. Its richer traced runner and task
builders are not called by Shikigami production code.

The selected core is `mori://shinzui/shikumi/packages/shikumi` 0.5.1.0. Hackage's
package-version endpoint and upstream `shikumi-0.5.1.0` tag were checked on
2026-11-05; the tag peels to `7b96ecf06364b37de44b15c4f58b2528b5a3e0f5`.
The public modules `Shikumi.Program`, `Shikumi.Stream`, `Shikumi.LLM`, and
`Shikumi.Routing` provide the required execution APIs. Preserve the repository's
current exact cohort and index-state; this plan needs no upgrade. Use Mori to
locate dependency sources before changing these integrations, and inspect the
selected release rather than assuming a local checkout matches it. Never search
or read `/nix/store`, and never traverse the filesystem root.

`shikigami-core/src/Shikigami/Program/DecisionRunner.hs` already constructs a
private provider registry for each decision. It wraps each actual transport
attempt for admission and terminal persistence, then updates Handan's runtime
with the selected model, registry, and bounded retry policy. Complete execution
calls `runProgramWith`. Streaming directly composes Shikumi's interpreters in
the same file. Preserve that effect order: `routeLLM` rewrites the model before
`runLLMResilient` dispatches it. Accepted execution additionally serializes
internal calls at the transport boundary and accounts each against the run's
resource root, the durable owner of its spending allowance.

`shikigami-core/src/Shikigami/Behavior/Run.hs` carries the runtime in `BehaviorEnv`,
parses a Handan task's argument map, and converts its envelope to an existing
`RunError` or JSON result. `shikigami-core/src/Shikigami/Behavior/Provider.hs`
constructs this environment at startup.
`shikigami-core/src/Shikigami/Program/Registry.hs` registers `noop-summary`,
`web-researcher`, and `code-researcher`; these are deterministic fixtures, with
only `noop-summary` executing a Shikumi `Embed` node. The two researcher tasks
return fixed findings. `shikigami-core/src/Shikigami/Flow/Decision.hs` carries
Handan's runtime as a service value; its workflow steps need no redesign.

`shikigami-core/src/Shikigami/Program/Decision.hs` owns the separate typed
decision program registry, immutable parameter commitments, and retained pure
result codecs. Keep it separate from the small behavior task catalog. Runtime
adaptation must not change its registered code/schema/validator/derivation
identities, parameter state, or `DecisionOutcome` representation.

The library, pure suite, and PostgreSQL suite declare `handan-core` in
`shikigami-core/shikigami-core.cabal`. `mori.dhall` declares the project/package
relationship. `nix/qualification/cohort.json` and
`nix/qualification/metadata.tar.gz` freeze the resolved production packages and
metadata. `tools/qualification/prepare-project.py` relocates **HEAD's**
`cabal.project` to avoid ignored local overrides; it does not use an uncommitted
edited project. `tools/qualification/export-cohort.py` regenerates packaging
inputs from the successful isolated solve.

The relevant ADRs were read during planning. [ADR 41](../adr/0041-durable-decisions-bind-program-state-and-preserve-committed-outcomes.md)
requires immutable executable state and reuse of the original committed result.
[ADR 42](../adr/0042-decision-admission-intersects-operator-agent-and-pinned-profile-authority.md)
requires operator, agent, and pinned profile authority to intersect before IO.
[ADR 43](../adr/0043-decision-provider-wrappers-own-actual-attempt-boundaries.md)
requires private registries, a separate expectation for each retry, and terminal
persistence before successful observation; callback failures cannot become
provider retries. [ADR 45](../adr/0045-flow-policy-pins-pending-decisions-and-retains-completed-result-codecs.md)
requires whole-Flow policy pinning and retained codecs independent of live
execution. [ADR 110](../adr/0110-accepted-typed-decisions-account-for-every-transport-call.md)
requires root accounting at each actual call, including internal retries and
nodes. [ADR 12](../adr/0012-a-declared-workflow-body-only-grows-behind-a-patch.md)
and `docs/workflow-versioning.md` govern body changes. These requirements remain
acceptance obligations when their Handan-specific wording is amended.


## Plan of Work


### M1: Own and share the Shikumi interpreter setup


Add `shikigami-core/src/Shikigami/Program/Runtime.hs` with a small `ProgramRuntime`
containing `config :: LLMConfig` and `defaultModel :: Model`. Give it complete
and streaming entry points using one effect-stack helper. The helper should
accept the underlying effectful action, so `runProgram` and `streamProgram`
receive exactly the same error, concurrency, routing, and resilient-LLM handlers.
Keep provider wrappers and all application policy in `DecisionRunner`; the new
module only assembles execution. Register its module in the Cabal library.

Preserve the prior default configuration, retry/budget/rate policies, and startup
provider-registration behavior during this refactor. Do not silently select the
Skill model for legacy program behaviors or remove an existing bootstrap
registration while moving constructors. Decision invocations continue to derive
an immutable local runtime with their pinned model and private registry, never
changing global credentials or providers. Do not add secrets to Show instances,
JSON encoders, logs, or persisted runtime records.

Migrate `DecisionRuntime`, `BehaviorEnv`, `DecisionEnv`, their constructors, and
the importing fixtures to `ProgramRuntime`. Route both decision execution modes
through the new module. As the first integration proof, run the existing
two-Predict-node selected-model test and complete/stream judgment tests. Preserve
all final request checks, retry caps, exception classification, callback order,
timeouts, and cancellation behavior. M1 passes when the affected components
compile and existing decision-runner and TypeSafe tests pass through the new
adapter; runtime execution has no Handan import, although legacy task wrappers
can remain until M2.


### M2: Replace behavior tasks and remove the dependency


Introduce `shikigami-core/src/Shikigami/Program/Task.hs` with a minimal existential
`ProgramTask`: `name :: Text`, `parse :: BehaviorInput -> Either Text i`, and
`run :: ProgramRuntime -> i -> IO (Either RunError Value)`. An existential hides
each task's input type so tasks with different parsers fit in one catalog.
Pattern-match the constructor when using its typed functions. Reuse
`Shikigami.Behavior.Input` and `Shikigami.Behavior.Error` directly, avoiding a
cycle through `Behavior.Run`. Use direct record field names following the
repository's Haskell conventions. Do not recreate Handan's envelope, task kinds,
artifact list, or unused evaluation handles.

Migrate `Program.Registry` and `Behavior.Run.runProgramTask` to that interface.
The noop parser receives the original payload value directly. A task can also
read recalled learnings from `BehaviorInput`; replace the obsolete argument-map
parse seam and its tests with equivalent tests of those actual values. Remove
`programArgs` if it has no remaining caller. Preserve the exact noop digest and
fixed researcher findings, unknown-task and parse-failure classification, and
runtime-failure rendering. Add focused failure coverage only where existing
tests do not protect the changed boundary. Do not turn a stub researcher into a
model-backed program or register the documented future detector as part of this
work.

Remove all remaining `Handan.*` imports, `handan-core` component dependencies,
the Handan source stanza in `cabal.project`, and active dependency declarations
in `mori.dhall`. Update the synthetic preparation-tool fixture in
`tools/qualification/test_prepare_project.py` to exercise a generic Git source
stanza rather than relying on this removed dependency. Keep independent
Shikumi dependencies when still imported; do not prune packages merely because
Handan also depended on them.

Commit the coherent source and project change on the current branch before the
final isolated solve, since the preparation script reads HEAD. Export the
successful solve through the existing exporter and inspect the package/version
difference. Handan and packages reachable only through Handan may disappear;
unrelated versions and source pins must remain fixed. M2 passes when the
shipped behavior tests pass and neither the isolated solve nor the regenerated
production closure contains `handan-core` or its repository source entry.


### M3: Verify preserved behavior and document the new ownership


Run the full affected pure suites and database-backed suites with serial
PostgreSQL fixture execution. Preserve complete/stream judgment request bodies,
raw structured answers, typed derivation, selected credentials and endpoints,
internal retry accounting, callback failure behavior, and cancellation. The
existing `DecisionWorkflowSpec` must still replay the entire original committed
result with live bindings and executable programs removed. The accepted
`DecisionExecutionSpec` must still recover results without another provider
call and account internal calls independently. Extend an existing fixture only
if the adapter migration exposes an uncovered contract.

Run `just keiro-gate` against the recorded pre-refactor revision. A service-type
replacement in `Flow/Decision.hs` still requires this gate even though no body
change is intended. Preserve domain declarations, generated inventories, step
labels, patch sets, and persisted result formats. Do not accept regenerated
breaking declarations or invoke the unused-first-release exception to make this
refactor pass. Native conformance is necessary but does not replace the actual
PostgreSQL replay tests.

Refresh current descriptions in `README.md`, `docs/dependency-cohort.md`,
`docs/shikumi-flow-decisions.md`, `agents/README.md`, and
`agents/detectors/at-risk-customer.dhall` where they describe Handan execution.
Search for other current guidance needing the same correction. Preserve dated
historical evidence and completed-plan accounts. Amend ADRs 41 and 43, and any
other directly affected current ownership wording, to describe the local adapter
while retaining their policy and replay decisions. Follow the repository's ADR
format and applicable validation contract; discover that contract before
writing an ADR rather than inventing new metadata.

Build the five affected immutable role attributes using the exported cohort.
This is native packaging regression for the dependency removal. It establishes
no new Linux containment, workspace, paid provider, or production readiness
claim; those remain with their owning plans. M3 passes with the behavioral,
replay, conformance, and role-build evidence recorded here, relevant ADR context
updated, and implementation friction triaged.


## Concrete Steps


Run commands from the repository root. Record the pre-refactor revision before
editing runtime code and use that exact ref for the final gate:

```bash
git rev-parse HEAD
mori registry search handan
mori registry show shinzui/handan --full
mori registry docs shinzui/handan
mori registry search shikumi
mori registry show shinzui/shikumi --full
mori registry docs shinzui/shikumi
rg -n 'Handan\.|handan-core' shikigami-core cabal.project mori.dhall
```

Use `nix develop --no-write-lock-file` for the following Cabal and Just commands,
as the declared shell supplies native libraries and PostgreSQL tools. After the
coherent M2 project edit is committed, prepare a fresh isolated project:

```bash
python3 tools/qualification/prepare-project.py --root .
```

It prints an absolute temporary path ending in `cabal.project`. Set a shell
variable `refactor_project` to that exact printed path. Use a fresh build
directory for this solve, then run:

```bash
cabal build all --project-file="$refactor_project" --builddir=build/handan-removal
cabal test shikigami-core-test shikigami-agent-test shikigami-server-test \
  --project-file="$refactor_project" --builddir=build/handan-removal \
  --test-show-details=direct
cabal test shikigami-core-postgres-test shikigami-workers-test \
  --project-file="$refactor_project" --builddir=build/handan-removal \
  --test-show-details=direct --test-options='--num-threads 1'
python3 -m unittest discover -s tools/qualification -p 'test_*.py' -v
just haskell-conventions
just keiro-gate PRE_REFACTOR_REF
```

Replace `PRE_REFACTOR_REF` with the captured commit. For focused M1 iteration,
run the core pure suite with `--test-options='-p "governed decision runner"'`,
then run the full core suite to include the structured judgment fixtures.
`just keiro-scaffold` inside the gate compares generated files with committed
files; commit coherent changes before final gate execution. Expected results
are successful suites, no unexpected scaffold drift, no breaking workflow
findings, and replay-compatible durable contracts.

Run the shipped noop behavior against the isolated project and inspect its
JSON. `agents/heartbeat.dhall` selects `noop-summary`; its existing `summary`,
`verb`, and echoed `input` must remain intact:

```bash
cabal run shikigami-run-behavior --project-file="$refactor_project" \
  --builddir=build/handan-removal -- \
  --agent agents/heartbeat.dhall --payload '{"source":"handan-removal"}'
```

Locate the successful `cache/plan.json` under `build/handan-removal` and obtain
the secure index location with `cabal path`. Substitute those actual paths in
the exporter command; it must use the same solve that passed the suites:

```bash
cabal path
python3 tools/qualification/export-cohort.py \
  --plan ACTUAL_PLAN_JSON_PATH --index ACTUAL_SECURE_INDEX_PATH \
  --output nix/qualification
nix build --no-link --no-write-lock-file \
  .#shikigami .#shikigami-server .#shikigami-worker \
  .#shikigami-migrate .#shikigami-agent-launch
git diff --check
```

Follow `tools/qualification/README.md` for export prerequisites. Inspect
`nix/qualification/cohort.json`, the metadata archive contents, and the solved
plan directly; do not traverse Nix store outputs. Record removed packages,
retained exact versions, relevant test results, workflow-gate verdict, and
role-build outcomes in this plan. Each implementation commit uses a
Conventional Commit message and the trailer
`ExecPlan: docs/plans/124-remove-handan-by-owning-the-shikumi-execution-adapter-in-shikigami.md`.


## Validation and Acceptance


Implementation evidence (2026-11-05): the fresh isolated project under
`build/handan-removal` builds all components. Its suites pass with 742 core,
37 agent, 107 server, 604 core PostgreSQL and 339 worker cases; database suites
use `-j1` and `--num-threads 1`. This includes the original full-outcome replay
with removed executables and bindings, selected-model judgment requests and raw
answers, retry/terminal/cancellation boundaries, accepted internal-call root
accounting and restart result reuse. The final workflow gate against
`ef6e11b804b9738f65ad87fde05e4be7eec9dc19` passes with no findings, no scaffold
drift and a `replay-neutral` verdict. Qualification-tool tests (50), Haskell
conventions and their 13 tests, focused preparation tests (3), and strict
user-guide/friction validation pass. The heartbeat command returns:

```json
{"input":{"source":"handan-removal"},"summary":"noop-summary produced a fixed digest","verb":"heartbeat.tick"}
```

The exporter produces 382 packages and six repositories. Compared with the
pre-refactor cohort, the only removed packages are `handan-core`, `shikumi-eval`,
`shikumi-trace-otel`, `tasty` and `tasty-golden`; the only removed repository is
Handan's pin. No retained package record or repository pin changes. The metadata
archive has 362 descriptors and omits all removed Hackage packages. The final
test solve retains exactly the exported production package set, versions, flags
and components. Immutable role builds target the exact committed export at
`ea5d930a14f1b8b6bc0d0106e705f3a9b043fbbe`, preserving the independent Biscuit
working-tree update outside this qualification.


A complete refactor must meet both dependency removal and behavior preservation.
Searching active source and component declarations finds no `Handan.*` imports
or `handan-core` dependencies. The successful isolated plan and frozen
production closure contain neither the package nor its Git repository. All
unrelated selected versions remain unchanged, and all five role builds pass.
Historical documentation mentioning Handan does not fail this criterion.

Behavior tests pass the original payload and recalled learnings through the
new task parser. The heartbeat command returns the same JSON shape and echoed
payload as before. Both fixed researcher tasks return the same findings.
Unknown names, rejected input, and execution errors retain their existing
`RunError` meanings. Skill behaviors continue to initialize and dispatch as
before despite sharing the environment whose runtime type changed.

Decision tests execute actual Shikumi Predict and judgment nodes with fixture
providers. Two concurrent invocations cannot exchange models or credentials;
each internal node/retry crosses its own admission and accounting hooks. A
terminal-persistence failure cannot publish success or become a transport retry.
Complete and streaming judgments retain identical request semantics, original
raw answer observations, and typed local derivation. Timeout and cancellation
retain the existing transient/uncertain-call behavior. Use the existing
`DecisionRunnerSpec`, `TypeSafeDecisionSpec`, `InitiativeAssessmentSpec`,
`DecisionWorkflowSpec`, and `DecisionExecutionSpec` as the primary evidence.

A committed durable outcome replays with zero new transport calls after live
programs and bindings are removed, retaining all original fields and existing
format readers. Pending decisions still use their pinned identities or refuse
before dispatch. The workflow gate reports no new breaking contract, and there
is no generated declaration drift. Passing compilation alone cannot close M3.


## Idempotence and Recovery


Work directly on the current branch and commit cohesive milestones. The new
runtime can coexist with the Handan task types during M1; remove the remaining
wrappers and source pin together in M2 so intermediate checkpoints compile.
No database migration, journal rewrite, new patch, or credential change is
planned. Disposable PostgreSQL fixtures own their databases; do not reset an
operator database to repair a test failure.

Re-run preparation after every committed project change, since an older
prepared file retains the earlier source stanza. Re-run export only from the
matching successful solve; export output may overwrite generated packaging
inputs. If export fails or shows unrelated version drift, retain the earlier
committed cohort and fix the isolated solve before replacing it. Do not hand
edit frozen package hashes or archives. Before implementation is deployed, a
normal Git revert can restore a failed milestone without changing durable data.
Resolve unexpected codec or workflow differences through the versioning rules,
never by deleting retained records.


## Interfaces and Dependencies


`Shikigami.Program.Runtime` owns `ProgramRuntime`, its startup constructor, and
complete/stream execution functions over `Shikumi.Program.Program i o`. Their
results remain `IO (Either ShikumiError o)`; the stream entry point additionally
accepts the existing `StreamEvent -> IO ()` observer. The common helper retains
one effect order for both entry points. `config` and `defaultModel` use direct
record names; runtime values remain process-local and unencoded.

`Shikigami.Program.Task` owns the minimal existential behavior task.
`Shikigami.Program.Registry.lookupTask` retains lookup by the existing text
names. `Shikigami.Behavior.Run.runProgramTask` maps parse failures to
`ProgramInputFailed` and delegates execution failures through the existing
error model. The typed durable decision registry and its immutable descriptors
remain owned by `Shikigami.Program.Decision` and its existing submodules.

Use the currently selected public packages from
`mori://shinzui/shikumi/packages/shikumi` and
`mori://shinzui/baikai/packages/baikai`, together with the already selected
Effectful packages. This plan removes
`mori://shinzui/handan/packages/handan-core`; it adds no library, service, network
credential, or source override. Any package used directly by the new adapter
must appear in the importing component's Cabal dependencies rather than relying
on a transitive dependency left over from Handan.
