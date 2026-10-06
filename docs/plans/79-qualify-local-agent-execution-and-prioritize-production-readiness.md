---
id: 79
slug: qualify-local-agent-execution-and-prioritize-production-readiness
title: "Qualify local agent execution and prioritize production readiness"
kind: exec-plan
created_at: 2026-10-06T03:27:48Z
intention: "intention_01m47m186wenjt8ecxny19rm3m"
provenance:
  created_by:
    model: "gpt-6.1-sol"
    harness: "codex-cli"
    at: 2026-10-06T03:27:48Z
  revisions:
    - model: "gpt-6.1-sol"
      harness: "codex-cli"
      at: 2026-10-06T03:34:11Z
      mode: "other"
      note: "Complete the initial grounded qualification plan and record current-tree audit evidence"
---

# Qualify local agent execution and prioritize production readiness


This ExecPlan is a living document. The sections Progress, Surprises & Discoveries,
Decision Log, and Outcomes & Retrospective must be kept up to date as work proceeds.
If durable project context changes, update or create ADRs in docs/adr/ in the same change.


## Purpose / Big Picture


Prove one useful Shikigami path on this Mac before deploying agents in production, and turn observed failures into an ordered work list. A trusted collector supplies a small service-health snapshot. An explicitly addressed agent consumes it, calls a real model, remembers the result, and delivers a report through an authorized sink. An operator can restart the worker, repeat a submission, interrupt delivery, and inspect what actually survived. A separate existing Flow proves that a human approval wait survives a restart and reaches the correct acknowledge, decline, or timeout outcome.

The deliverables are a repeatable qualification command, an isolated persistent host deployment, and `docs/evidence/local-qualification/readiness.md`, which names the exact revisions tested and separates observed results from open claims. Finishing the local scenario establishes a complete path for this workload. Production readiness additionally requires the relevant production gates below; a green health endpoint alone establishes neither claim.


## Progress


- [x] (2026-10-06 UTC; 2026-10-05 local) Inspect implementation, relevant ADRs, backlog, historical qualification, and the existing host bootstrap plan; create the plan intention.
- [x] (2026-10-06 UTC) Evaluate current Nix exports and default package; compare normal and isolated Cabal dependency solves. Results and limits are recorded below.
- [x] (2026-10-06 UTC) Run the migration schema-isolation check; application SQL passes, with its documented checksum-immutable historical exception.
- [ ] M1: Produce the reproducible baseline and current readiness inventory; run fresh build and automated checks.
- [ ] M2: Complete the necessary plan-31 packaging slice and install isolated, supervised host roles through the existing host bootstrap plan.
- [ ] M3: Deliver a real-model service-health report and prove scoped learning and recall.
- [ ] M4: Prove redelivery, process restart, sink failure, and authorization refusal with bounded fault rehearsals.
- [ ] M5: Prove durable human waits, publish the prioritized readiness report, and record production promotion gates.


## Surprises & Discoveries


The authoring audit used Shikigami revision `c2157236b1aa49b27a1f13323e70c973686aa5d1`. The working tree was clean before this plan was created. On 2026-10-06 UTC, package discovery succeeded but package evaluation failed:

```text
$ nix eval --json .#packages.aarch64-darwin --apply builtins.attrNames
["default"]
$ nix eval --raw .#packages.aarch64-darwin.default.drvPath
cabal2nix: user error (*** Found neither a .cabal file nor package.yaml. Exiting.)
```

`nix/haskell.nix` and `flake.module.nix` still treat the repository root as one Cabal package. The tree has seven Shikigami packages and no root Cabal file. There are also no separately exported deployment roles. This is an observed deployment blocker, not merely an unchecked checklist in plan 31.

The normal dependency solve failed because the ignored `cabal.project.local` points at a mutable local Kioku 0.8.0.1 checkout, which requires Keiro 0.19; the committed project pins Keiro 0.18. An absolute-path copy of the committed `cabal.project` in a temporary directory, with no local override and no version changes, solved successfully under GHC 9.12.4:

```text
$ cabal build all --dry-run
rejecting: kioku-core-0.8.0.1 (... kioku-core => keiro^>=0.19.0.0)
$ cabal build all --dry-run --project-file=<isolated absolute-path project>
Build profile: -w ghc-9.12.4 -O1
In order, the following would be built ...
```

The successful solve does not prove compilation or an immutable deployment: `cabal.project` still includes sibling Kikan-En contract/client source directories. Preserve the user's local override; select an isolated committed cohort for this proof. Do not turn the local conflict into an unrelated dependency upgrade.

`docs/evidence/keiro-0.18/qualification.md` records a successful September 21 build, tests, migration and HTTP checks at an older revision. It is valuable historical evidence, but it is not a fresh pass for the current tree. During plan authoring, no full compile, runtime deployment, real-model call, fault rehearsal, or production check was performed.

The current-tree static migration check passed on 2026-10-06 UTC:

```text
$ bash tools/check-migration-schema-isolation.sh
migration-schema-isolation: historical exception retained: shikigami-migrations/sql-migrations/2026-06-24-12-00-00-shikigami-fired.sql mutates search_path; applied bytes are checksum-immutable
migration-schema-isolation: application SQL is schema-qualified; vendored PGMQ SQL has no session path mutation
```

This checks SQL ownership conventions, not whether migrations have run successfully on a live database.


## Decision Log


Decision (2026-10-06 UTC): Start with a bounded, supplied-payload reporter, then qualify an existing deterministic Flow. The reporter needs no model tools, repository executor, Kubernetes provider, Kafka broker, or task store. This reaches real model, workflow, memory, identity, authorization, and delivery boundaries with few new moving parts.

Decision (2026-10-06 UTC): Keep packaging implementation owned by [plan 31](31-deployable-service-stack-process-compose-packaging-and-configuration.md) and Mac service/configuration implementation owned by the existing host bootstrap plan. This plan defines the qualification acceptance and orchestrates only the necessary slices. Completing its host reporter does not close the host plan's Danwa coding and migration-learning acceptance.

Decision (2026-10-06 UTC): Do not require IR-14 before starting. The current Skill body can repeat a model call after a crash inside its coarse behavior step. Accept and document that limitation for this short, tool-free workload; require stable logical run and sink identities. A stronger claim about recovering individual model/tool turns is work for IR-14.

Decision (2026-10-06 UTC): Use a dedicated qualification database, manifest directory, file-backed principal directory, loopback ports, receiver destinations, and supervisor labels. Production grants, queues, service units, and databases are outside this rehearsal. The user asked to create a new intention through `mina ci`; the returned intention is linked in frontmatter.


## Outcomes & Retrospective


The authoring audit establishes a packaging failure and a local dependency override conflict; the isolated committed dependency solve passes. Runtime qualification remains unperformed. Update this section after each milestone with observed outcomes and remaining gaps. At completion, promote lasting operational lessons into the relevant ADRs and reconcile `docs/roadmap.md` with the readiness report.


## Context and Orientation


Shikigami represents an agent in `schema/Agent.dhall`. A manifest selects a trigger, behavior, memory policy, stable principal, and output sinks. A principal is the stable `agent_...` identity that owns memory and grants; the manifest name is its human-readable handle. `agents/proof/heartbeat.dhall` is a deterministic example, not a real-model proof. `shikigami-core/src/Shikigami/Behavior/Skill.hs` runs skill instructions through the selected model provider. `shikigami-core/src/Shikigami/Behavior/Provider.hs` selects the stub or Anthropic implementation. A stub success does not establish a model call.

`shikigami-core/src/Shikigami/Agent/Workflow.hs` runs an agent as a `shikigami.agent-run` workflow: its journal is the durable record of completed steps in PostgreSQL. Resuming a recorded step returns its stored value. The ordinary Skill loop is inside the coarse `run-behavior-v2` step, so its individual exchanges are not independently recoverable. `shikigami-workers/src/Shikigami/Workers/Config.hs` currently installs `emptyCapabilityRuntime`, so configuring a model tool in a manifest is not proof that a production provider exists. This proof supplies observations in the run payload instead.

`shikigami-server/src/Shikigami/Server/Command/Runs.hs` joins workflow state to the Kioku session through the journaled session id. `runs show` currently reports session status and turn count but omits the recorded model identity. The `recall` workflow step records the memories actually supplied to the behavior; inspect that journaled value when proving recall instead of issuing a new query after the run. `shikigami-core/src/Shikigami/Memory/Access.hs` owns memory access; use its scoped operations, not queries against another library's private tables. `shikigami-core/src/Shikigami/Sink/Delivery.hs` owns delivery receipts, which distinguish queued work from actual publication. A receipt records the sink's delivery result; it is not a cryptographic attestation.

`shikigami-core/src/Shikigami/Flow/AtRiskCustomer.hs` already provides a useful durable-wait example. A payload containing `text: "customer threatens to cancel"` yields high risk, emits an alert, and awaits a human answer. Approval remembers acknowledgement; rejection remembers decline; timeout emits an escalation and remembers it. `shikigami-core/src/Shikigami/Agent/Approval/Notification.hs` transports the ask and its opaque reply token. The reply command uses that UUID token, not the stable review identifier.

`docs/operations/configuration.md` documents layered configuration and secrets, and `docs/operations/operator-cli.md` documents enqueue, principal sync, grants, run inspection, and approvals. Runtime database configuration is `database.connection_string` / `PG_CONNECTION_STRING`; migration commands use `DATABASE_URL`. In file directory mode, the JSON snapshot contains `principal_id`, `handle`, and `lifecycle`; configured invalid identity fails closed. `authorization.actions.mode=disabled` denies protected external actions. Real delivery requires the complete Kikan/Shomei/En trust configuration and exact action authorization, in addition to Shikigami sink grants. Do not substitute an allow-all authorizer to obtain a green live result.

`process-compose.yaml` currently provisions database development support, not a persistent server/worker stack. Build declarations are in `cabal.project`, `flake.module.nix`, and `nix/haskell.nix`. The package set must include the exact sibling Kikan-En contract/client sources as well as the pinned dependency cohort. Discover external owners and source APIs using Mori before implementing packaging or fixtures; verify registry releases and upstream tags before choosing any new bounds or pins.

The host bootstrap is `mori://shinzui/dotfiles.nix/plans/4-bootstrap-persistent-shikigami-agents-and-validate-service-migration-learning`. Its project is `mori://shinzui/dotfiles.nix`; it owns user launchd services (the Mac supervisor that starts and restarts processes), runtime configuration, secrets, host state, and an isolated Danwa coding example. Its older dependency target must be rechecked against the selected Shikigami cohort. The intended plan URI currently does not resolve through the local Mori artifact index; retain the canonical URI and inspect the owning project's `docs/plans/4-bootstrap-persistent-shikigami-agents-and-validate-service-migration-learning.md` after discovering its root with `mori registry show shinzui/dotfiles.nix --full`. Leave unrelated staged host changes alone.

Relevant ADR context is already established. [ADR 0007](../adr/0007-a-resolved-profile-is-a-run-local-policy-snapshot.md) pins resolved policy per run. [ADR 0012](../adr/0012-a-declared-workflow-body-only-grows-behind-a-patch.md), together with `docs/workflow-versioning.md`, requires replay-safe workflow changes; qualification should exercise existing bodies first. [ADR 0019](../adr/0019-a-loop-that-stops-stops-the-process.md) lets the supervisor recover a dead runtime loop. [ADR 0020](../adr/0020-readiness-covers-only-what-restarting-can-fix.md) keeps readiness separate from downstream outages. [ADR 0022](../adr/0022-the-journal-ends-at-enqueue-and-receipts-own-delivery-truth.md) makes receipts the delivery truth. [ADR 0025](../adr/0025-capability-overlays-are-requests-for-additive-model-tools.md) distinguishes requested tools from implemented providers. [ADR 0033](../adr/0033-recorded-agent-principals-key-durable-state.md) keys memory and grants by recorded principals. [ADR 0036](../adr/0036-external-agent-actions-require-fresh-exact-authorization.md) requires fresh authorization at external action boundaries. [ADR 0038](../adr/0038-runtime-startup-and-maintenance-share-validated-owners.md) requires verified migrations and shared workflow registration at startup. Preserve these contracts; add an ADR only if implementation establishes a new lasting decision.

### Prerequisites and work order


Start this plan now. Before its persistent live milestone, complete the relevant packaging slice of [plan 31](31-deployable-service-stack-process-compose-packaging-and-configuration.md): working per-role exports and an immutable dependency/source closure. The full process-compose/Kafka/NixOS program is not required for addressed enqueue on this Mac. Resolve the ignored local Kioku override by choosing the isolated project for qualification, without changing the user's file. These two observed blockers have priority over adding new agent capabilities.

The live reporter closes the relevant open live-provider acceptance in [plan 13](13-wire-a-real-model-provider-into-behavior-runs.md); it need not be implemented separately first. Reuse completed approval and delivery implementations, but rerun their relevant tests at the selected revision. The historical Keiro 0.18 qualification does not need to be repeated as a dependency migration; fresh acceptance still must run.

[Plan 60](60-harden-practice-review-attention-reservation-and-specialist-failure-boundaries.md) and [plan 61](61-enforce-practice-review-resolver-entitlement-and-harden-the-authorization-envelope.md) describe known attention-transaction and resolver-entitlement defects. They are priority fixes before enabling the OpenTelemetry practice-review path in production. They do not block a local catalog containing only the reporter, observer, and at-risk Flow. The resolver ingress currently has no production caller; do not invent a currently exposed endpoint. If production adds that ingress, its entitlement defect becomes a concrete admission blocker. Audit any production catalog and integrations rather than treating this small proof as certification of all features.

[IR-14](../improvement-requests/record-durable-model-tool-turns-and-compose-harness-policies.md) becomes a prerequisite when acceptance requires recovery of individual model/tool exchanges, long-running tool loops, or avoiding repeated provider calls after a mid-behavior crash. [Plan 77](77-add-a-read-only-k8s-observe-capability-provider-for-durable-agents.md) becomes relevant when the agent itself must observe Kubernetes; this reporter receives a trusted snapshot. [Plan 48](48-add-a-portable-one-off-repository-agent-harness.md), the Danwa mutation work represented by IR-11, and [plan 78](78-run-external-operations-from-durable-flows-through-idempotent-shiki-jobs.md) belong before a durable coding/external-job scenario, subject to that plan's upstream prerequisites. HTTP-trigger/API IRs, task-store IR-13, typed-decision IR-12, and signing plan 52 are not prerequisites for this CLI-addressed reporter. Reconsider those priorities only when evidence or the selected production workload makes them relevant.


## Plan of Work


### Milestone 1: Establish the reproducible baseline and evidence inventory


Create `tools/qualification/prepare-project.py`. It reads the committed `cabal.project`, makes package and optional-package paths absolute relative to the checkout, writes the result into a new temporary directory, and prints that project-file path. It must preserve dependency pins, constraints, index state, and compiler selection. Fail on unsupported syntax rather than silently dropping settings. Its purpose is to avoid the ignored adjacent `cabal.project.local`, not to claim the mutable sibling packages are reproducible. Record the sibling revisions; immutable packaging is the next gate.

Create `tools/qualification/check.sh` with the interface specified below. Its `baseline` phase records revision, dirty-tree state, architecture, compiler, selected project, dependency sources and Nix evaluation results into a private artifact directory. Run a fresh full build, pure tests, isolated PostgreSQL integration tests, migration smoke, and workflow conformance. Use a dedicated PostgreSQL database and existing test fixtures, never a production URL. If a check fails, preserve its output and record the blocker rather than proceeding as if historical passes apply.

Seed `docs/evidence/local-qualification/readiness.md` with the authoring audit and append fresh results separately. Each claim names its command, timestamp, revision, observed outcome, and evidence location. Classify work as blocking this scenario, blocking a selected production feature, or a later capability. A build or test failure yields a prioritized issue with a minimal reproducer. Acceptance is a report that reproduces the current two failures, distinguishes the successful isolated solve, and then accurately reports the fresh checks; this milestone can finish with explicitly recorded blockers even if a later live milestone cannot start.

### Milestone 2: Obtain immutable packages and a persistent isolated host runtime


Implement or complete the packaging slice in plan 31 and update that plan's Progress and provenance. `flake.module.nix` and `nix/haskell.nix` must export working `shikigami`, `shikigami-server`, `shikigami-worker`, and `shikigami-migrate` outputs for this Mac. Build all seven local packages through the actual multi-package graph. Resolve sibling package source ownership explicitly and pin reviewed source revisions; do not make the release depend on an unrecorded adjacent checkout. Verify newly chosen pins through Mori and authoritative upstream releases/tags. The installed closure must contain the schemas and skill assets needed by qualification. Test from outside the source checkout so current-directory imports cannot hide missing assets. Plan 31 owns the export naming decision; if it already establishes different names, update all commands here to the adopted interface before continuing.

Coordinate the host slice through the canonical dotfiles plan. Install distinct qualification launchd jobs for server and worker, with logs and automatic restart. Use a new database named `shikigami_qualification`, dedicated loopback ports selected after checking they are unused, and configuration at `$HOME/.config/shikigami/qualification/runtime.yaml`. Keep secrets in the host's existing secret mechanism and refer to them from runtime configuration. Record exact labels, resolved binary paths, ports, dependency endpoints, and a bounded timeout in a private deployment inventory. Use explicit migration commands before enabling the jobs; startup must verify installed migrations. Include only addressed-run and resume loops required here; a Kafka consumer is not needed for this trigger.

Use real test authorization services for action admission. Begin with local receiver destinations for controlled delivery faults, then exercise an actual test Kawa destination before claiming downstream integration. If authorization or a test destination is unavailable, mark that phase blocked; deterministic fixture transport evidence still has a useful narrower claim. A contract-compatible receiver is not proof of a live Kawa, Danwa, or Kizashi deployment.

Run `check.sh --phase host`. It must validate manifests, configured principals, migration verification, binary startup, and separate server/worker readiness. Kill only the recorded qualification worker PID, observe a different PID under the same supervisor label, and show that operator inspection still works. Acceptance is an immutable build and supervised runtime that survives shell closure and deliberate worker termination. Mark packaging and host-slice work in their owning plans without closing unrelated milestones.

### Milestone 3: Prove a useful real-model report and scoped memory


Create a deployment fixture tree at `fixtures/qualification/`, containing `agents/service-health-reporter.dhall`, `agents/service-health-observer.dhall`, `skills/service-health/SKILL.md`, `directory.json`, `healthy.json`, and `degraded.json`. Keep the agent loader restricted to that fixture catalog. Package or copy the required Dhall schema so all imports work in the immutable runtime. The reporter uses `Behavior.Skill`, an Event trigger `qualification.service-health`, a KawaDigest sink with subject type `service-health` and verb `qualification.health.report`, explicit stable identity, no capability overlays or delegates, and agent-scoped memory with OnSuccess recording and recall limit 3. The observer has a distinct identity and the same memory isolation policy, but cannot see the reporter's learning. File directory entries are active, unique, and match those identities. Grant only the required sink kind through the operator CLI, then sync principals; configure exact external action authorization for these destinations.

The snapshot contains a public run marker, capture time, named service statuses, and bounded diagnostic text. Healthy and degraded fixtures differ in one named service; degraded includes the unique marker `qualification-cache-unavailable`. Create `tools/qualification/snapshot.py` to fetch only the configured loopback health URLs from the deployment inventory with timeouts and size limits, and emit this same shape. Do not gather process environments or secret-bearing logs. The agent reports what the supplied snapshot says, distinguishes current from prior state, and gives one suggested operator follow-up. The output must contain the service name and marker when supplied; it must not invent an observation or claim to have executed a repair. Choose a model accepted by the built provider's catalog, record its actual identifier, and cap attempts, run time and run count. Do not change model catalogs just to match an example name.

Add `tools/qualification/inspect-run` only for evidence that existing CLI commands cannot expose. It is a small Haskell operator utility, wired as a `shikigami-server` test/support component, using the same configuration and library-owned reads as `Shikigami.Server.Command.Runs`. Follow the recorded session id to read `modelUsed`; expose scoped learning identifiers/content through existing Shikigami/Kioku operations and delivery receipts through their owning module. Discover exact dependency APIs with Mori. It takes a workflow name/id and returns bounded JSON containing identity, session/model, learning and delivery evidence; it performs no writes or private-table queries. Prefer additive fields in an existing supported command if that is smaller; document the adopted interface in this plan. Never treat model prose alone as proof of scoped recall.

Run the degraded reporter with a stable enqueue key, inspect successful workflow/session state, the real model identity, recorded learning, and a successful test-sink receipt. Submit a healthy snapshot under a different key to the same reporter. Prove that the earlier learning is in scoped recall evidence and that the report distinguishes recovery from prior degradation. Send the same healthy payload to the observer under a third key and show that its recall evidence excludes the reporter's learning. Pair model prose with recorded memory evidence, since prose is probabilistic. Acceptance requires a model-authored useful report and exact persisted evidence for the run, principal, memory and delivered sink; the stub cannot pass this milestone. Link the live transcript back to plan 13's outstanding acceptance.

### Milestone 4: Exercise recovery and refusal boundaries


Add only the fault controls needed to a qualification receiver fixture at `tools/qualification/receiver.py`, matching the request/response contracts used by `Shikigami.Sink.KawaClient` and the approval notifier. Reuse the existing `Shikigami.Sink.KawaStub` contract and fixtures where possible. The receiver persists observed idempotency keys, requests, reply tokens and logical acceptance counts in its own SQLite database; it supports a configured number of HTTP 503 responses and explicit release of a blocked response. An inspect command returns bounded JSON. This fixture store survives receiver restart and is separate from Shikigami's database. Transport fixture success is labeled as such; real authorization remains enabled.

The `recovery` phase performs controlled trials with distinct stable keys. First stop the supervised qualification worker, enqueue a job, restart it, and prove the job completes. Resubmit the completed job twice with the same key and identical payload: the logical run/session, recorded learning and sink identity must stay stable, and the receiver must show one accepted logical report. Capture the workflow id printed by enqueue; do not reconstruct it from the key because special keys can be encoded.

For sink retry, have the receiver reject two attempts with 503, then accept. Show pending/retrying and delivered receipts separately, with a stable message/idempotency key. For ambiguous delivery, let the receiver accept and hold the response, terminate the qualification worker or dispatcher that owns that request, release the response, and restart. A retry may reach the receiver, but its persisted deduplication must leave one accepted logical effect. Record the receiver's deduplication assumption; Shikigami does not provide universal exactly-once delivery.

For refusal, revoke the reporter's KawaDigest grant before enqueueing a new run and prove no sink request is accepted and the refusal is inspectable. Restore it, pause the reporter in the directory snapshot, wait for a documented successful refresh, and prove a new run produces no model or sink effect. Restore active lifecycle and prove new work is admitted. Exercise external action authorization denial with the test authorization service's supported policy controls and show no HTTP publication; a local grant alone must not bypass that denial. Record any impossible trial as an open blocker with its missing integration.

Finally terminate the worker during a model attempt, using an observable provider-start event if available. Allow the original request to finish or expire before resuming, according to provider/run timeout configuration. The model may be called again; the resulting workflow must either reach a consistent completed run or a documented bounded terminal failure, with no duplicate logical learning or accepted report. Record attempts honestly. If exact timing is not observable, mark this specific trial unproven instead of adding unsafe test hooks to a workflow body. Acceptance is an evidence record for each trial, not merely a healthy process afterward. Any violation of logical state uniqueness blocks promotion and becomes a high-priority fix.

### Milestone 5: Prove durable waits and publish the production work order


Add `fixtures/qualification/agents/at-risk-customer.dhall`, selecting the existing `at-risk-customer` Flow with its own active principal and grants for the sinks it actually emits. Configure a test Danwa destination for the ask and test Kizashi destination for alerts; use the controlled receiver only for contract rehearsals, and record an actual service trial separately. Set `approval.deadline_seconds` to a short valid value for timeout trials, then restore the recorded normal setting. Derive activity payloads from the existing `AgentWorkflowSpec` / `FlowLifecycleSpec` fixture shape so subject, actor, and area-owner recipient routing are explicit; a bare text field establishes classification but not a routable activity.

The `waits` phase creates three separate high-risk runs. For the first, capture the ask token, prove the parent is waiting, restart the worker, then resolve the same token with `--approve`; inspect acknowledgement learning and successful parent completion. For the second, resolve with `--reject "qualification decline"` and verify decline learning. For the third, restart during the wait and supply no answer; prove that the durable timer causes one logical escalation and remembered timeout outcome. Reusing an answered or expired token must fail explicitly. Use bounded polling beyond the configured deadline and resume cadence; do not infer timeout from sleeping a fixed duration. Show that repeated resume does not publish duplicate logical alerts.

Finish `docs/evidence/local-qualification/readiness.md` and update `docs/roadmap.md` with the tested revision and ordered work. A pass is a directly observed expected result; a failure is observed contrary behavior; blocked means a required dependency is unavailable; unproven means a trial has not supplied evidence. Each open item names its reproducer, impact, scenario, existing IR/plan owner where applicable, and next acceptance. Separate current-tree failures from later feature requests and stale document status. Promote packaging/build failures and state-loss/authorization/delivery violations first. Keep plans 60/61 ahead of enabling practice review. Prioritize IR-14 next only if crash evidence or the next workload requires individual-turn recovery; prioritize coding/provider plans when selecting that workload.

Record production promotion as a separate gate: deploy the same immutable artifacts and feature-scoped configuration in a production-like environment; verify destination authorization and actual service integration; restore a backup into an isolated database and inspect completed and waiting runs; perform a supported version change while a workflow is suspended and prove it resumes under `docs/workflow-versioning.md`; demonstrate an operational rollback that respects database/journal compatibility; and agree workload-specific limits and failure handling. The target production host, enabled catalog and integrations must be named before executing those trials. Unknown targets remain unproven, not assumed. Completion of this local plan can leave that gate open if its environment is unavailable, but cannot claim production qualification in that case.


## Concrete Steps


All repository commands run from the Shikigami checkout root. The two helper scripts and inspection utility below are implementation deliverables, not present at authoring time. Start by recording the baseline and repeating the package checks:

```bash
git rev-parse HEAD
git status --short
nix eval --json .#packages.aarch64-darwin --apply builtins.attrNames
nix eval --raw .#packages.aarch64-darwin.default.drvPath
```

After implementing the isolated-project helper, use its path consistently. Supply a dedicated test database through the host's secret configuration before database tests. Do not print database credentials in evidence.

```bash
QUALIFICATION_PROJECT=$(python3 tools/qualification/prepare-project.py)
cabal build all --dry-run --project-file="$QUALIFICATION_PROJECT"
cabal build all --enable-tests --project-file="$QUALIFICATION_PROJECT"
cabal test shikigami-core-test shikigami-workers-test shikigami-server-test \
  --project-file="$QUALIFICATION_PROJECT" --test-show-details=direct
cabal test shikigami-core-postgres-test shikigami-migrations-smoke \
  keiro-shikigami-conformance --project-file="$QUALIFICATION_PROJECT" \
  --test-show-details=direct
```

The dry run should solve without the Kioku 0.8 / Keiro 0.18 conflict. Fresh build and tests must exit zero for the tested immutable cohort before live qualification. The conformance target follows the existing `justfile`; if a generated component must be prepared, use the existing `just keiro-check` workflow and record the resulting command, without changing workflow declarations to make the qualification pass. Never inspect or search `/nix/store` to debug package failures; use source declarations and Mori.

After plan 31 exports the agreed role names, package discovery must list them and these builds must succeed:

```bash
nix build --no-link .#shikigami .#shikigami-server \
  .#shikigami-worker .#shikigami-migrate
```

The check driver receives explicit, non-secret configuration and private evidence paths. Its default phase must be `baseline`; model calls and fault injection occur only when their phase is explicitly chosen. Create a private evidence directory before invoking it:

```bash
mkdir -p "$HOME/.local/state/shikigami/qualification/evidence"
chmod 700 "$HOME/.local/state/shikigami/qualification/evidence"
bash tools/qualification/check.sh --phase baseline \
  --config "$HOME/.config/shikigami/qualification/runtime.yaml" \
  --artifact-dir "$HOME/.local/state/shikigami/qualification/evidence"
```

Repeat the same command with phases `host`, `report`, `recovery`, and `waits`, in that order, once the preceding milestone passes. Each phase writes a summary with case-specific pass/fail/blocked/unproven outcomes, exits nonzero for failures or required blocked/unproven cases, and prints where evidence was written. It must validate that configured database, labels, ports and destinations match the dedicated inventory before making changes. Require an explicit test-mode inventory flag to run fault phases. Never fall back to a default database or broad process-name kill.

The report phase wraps supported operator commands. After loading configuration, granting and syncing identities, the basic submission and inspection look like this:

```bash
QUALIFICATION_CONFIG="$HOME/.config/shikigami/qualification/runtime.yaml"
shikigami --config "$QUALIFICATION_CONFIG" agents list --json
shikigami --config "$QUALIFICATION_CONFIG" grants grant service-health-reporter KawaDigest
shikigami --config "$QUALIFICATION_CONFIG" agents sync --json
shikigami --config "$QUALIFICATION_CONFIG" enqueue-run service-health-reporter \
  --payload '{"run_marker":"qualification-01","text":"cache: unavailable; qualification-cache-unavailable"}' \
  --key qualification-report-01
```

The driver uses the full snapshot fixture; the short payload above demonstrates the operator interface. Store the printed workflow id and use it in `runs show shikigami.agent-run ID --json`, `wf show`, `wf journal`, and `wf steps`. The driver polls with an explicit deadline rather than guessing completion. For waits, the supported decision commands are:

```bash
shikigami --config "$QUALIFICATION_CONFIG" resolve-approval "$QUALIFICATION_TOKEN" --approve
shikigami --config "$QUALIFICATION_CONFIG" resolve-approval "$QUALIFICATION_TOKEN" --reject "qualification decline"
```

These are alternatives on separate trial tokens. The first accepted decision prints `resolved: true` and exits zero; repeated or expired tokens print false and exit one. Record the exact supervisor operations and inspection command adopted during implementation in this section before marking their milestones complete.


## Validation and Acceptance


For this local workload, all five milestones must have observed evidence. The packages build without ambient sibling source dependencies; server and worker restart under dedicated supervision; degraded input produces a useful report from the recorded real model; workflow and session complete; learning belongs to the recorded principal; delivery has a successful receipt and downstream observation. The healthy follow-up recalls that learning, while a distinct principal does not. Repeated keys preserve logical identity. Receiver failure and restart recover without lost work or duplicate accepted logical effects. Grant, lifecycle and external authorization refusals prevent publication. Human acknowledge, decline and durable timeout survive restart and give their specified outcomes.

Add meaningful tests only for new logic: isolated-project parsing preserves pins and rejects unsupported declarations; inspection follows recorded ids and distinguishes missing evidence from empty evidence; the receiver's failure/restart deduplication works. Reuse current integration suites for workflow behavior. Exercise real boundaries at least once; no simulated transcript is acceptance. Record logical effects separately from physical HTTP or model attempts. A forced mid-Skill restart may repeat the provider call under current behavior, and that honest limitation does not invalidate this workload's narrower proof.

The readiness report must make it possible to answer three different questions: does this workload work locally, what prevents the selected production deployment, and which next workload needs which IR or plan? A production conclusion requires the explicitly scoped production gate in Milestone 5. Do not mark unavailable real integration or suspended-workflow upgrade tests as passed. The plan's local completion and the report's production verdict are separate fields.


## Idempotence and Recovery


Use one trial id and one payload hash per logical submission. Repeating that trial reuses its stable enqueue key; a changed payload uses a new key. Keep receiver state and evidence across process restarts. Failed assertions preserve artifacts and return nonzero. Every fault phase restores changed test policy, directory lifecycle, receiver failure settings and revoked grants in a cleanup handler, and records any failed restoration. A second run first checks that cleanup has completed.

Only the dedicated qualification service labels/PIDs may be stopped or restarted. Back up its database before migration/version rehearsals, keep the previous immutable binaries and non-secret config, and verify compatible migrations/journals before reverting binaries. Never use direct SQL to force a workflow, approval, queue, or receipt state. Use supported operator/library operations and recorded lease/timeout behavior. If a job stalls, inspect its workflow, session, lease and delivery receipt before attempting bounded recovery. Recreate disposable test databases only after explicitly verifying the dedicated database name; retain evidence separately.

The ignored local project and unrelated dotfiles changes remain untouched. Dependency upgrades or durable workflow fixes discovered during qualification belong to their own owning IR/plan and must follow workflow-versioning and normal checks. Rerun only the affected qualification cases after a fix, then report the new revision and remaining results accurately.


## Interfaces and Dependencies


`tools/qualification/prepare-project.py` prints exactly one isolated project path on success and diagnostics on stderr on failure. `tools/qualification/check.sh --phase baseline|host|report|recovery|waits --config PATH --artifact-dir PATH` accepts existing Shikigami layered configuration, uses a private deployment inventory, and emits a bounded machine-readable phase summary alongside human output. Each summary names revision, phase, case, outcome, reason, workflow/session/principal ids where present, and relative evidence files. Secret values must be redacted before writing files intended for the repository.

`tools/qualification/snapshot.py` accepts an explicit allowlist of loopback health endpoints and produces capture time, public marker and bounded service status details. It has no agent tooling or mutation interface. `tools/qualification/receiver.py` owns its fixture request log, deduplication state, controlled transport failures and inspection interface. Implement its wire contract from the existing client/stub source, not from a guessed generic HTTP API. The inspection utility uses `Keiro.Workflow.loadStepIndex`, recorded session links, and library-owned Kioku/Shikigami reads as the existing run command does; it does not create a parallel persistence layer. Its exact adopted command and output schema must be recorded when implemented.

Required runtime services are a dedicated PostgreSQL database, the existing configured model provider for the explicit live phase, real test action-authorization services for protected external publication, and supported test sink/approval destinations for integration claims. The controlled receiver supports narrower contract and fault evidence. Kafka, Kubernetes, repository mutation executors, task stores and signed attestations are outside this first workload. Preserve the committed Keiro cohort unless independent evidence justifies a separately planned migration.

This plan owns qualification fixtures, scripts, evidence and roadmap reconciliation. Plan 31 owns production packaging changes; the canonical dotfiles bootstrap plan owns host service/configuration changes. If qualification requires an agent/Flow body edit, first follow `docs/workflow-versioning.md`, declare the necessary patch in `domain/`, run `just keiro-gate`, and document the changed replay contract before resuming the proof.


## Revision Notes


2026-10-06 UTC: Created from a current-tree audit and the existing host bootstrap context, linked to the intention created at the user's request. Seeded the observed packaging and dependency results; all runtime acceptance remains open.
