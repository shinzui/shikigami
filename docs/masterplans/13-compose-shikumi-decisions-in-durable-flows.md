---
id: 13
slug: compose-shikumi-decisions-in-durable-flows
title: "Compose Shikumi decisions in durable Flows"
kind: master-plan
created_at: 2026-09-26T18:34:11Z
intention: "intention_01m3fft4cceb1ba9t3fammx5x4"
provenance:
  created_by:
    model: "gpt-6-astra"
    harness: "codex-cli"
    at: 2026-09-26T18:34:11Z
  revisions:
    - model: "gpt-6.1-sol"
      harness: "codex-cli"
      at: 2026-10-21T20:30:29Z
      mode: "update"
      note: "Coordinate Shikumi MP-12 without blocking current scope; bind parameter state and derivation, preserve committed results and distinguish probability data from call evidence"
---

# Compose Shikumi decisions in durable Flows


This MasterPlan is a living document. The sections Progress, Surprises & Discoveries,
Decision Log, and Outcomes & Retrospective must be kept up to date as work proceeds.
If durable project context changes, update or create ADRs in docs/adr/ in the same change.


## Vision & Scope


Implement [IR-12](../improvement-requests/compose-shikumi-decisions-in-durable-flows.md): a compiled Haskell Flow invokes registered, typed Shikumi programs at named decision points, chooses an authorized model for each invocation, and branches on validated results. A demonstration triages with one model, optionally investigates with another, and returns or delegates through the existing governed boundary. A completed decision replays without model calls; its original program, input, model tuple, policy, and result remain inspectable after configuration changes.

A Flow is a compiled function interpreted inside the agent-run durable workflow. A journal stores named step results so a restarted worker can resume. A model tuple means provider, API, endpoint class, exact model ID, and thinking setting. The tuple grants no authority by itself: operator catalog membership, the journaled agent declaration, and any pinned sanctioned profile must all permit it. Model output proposes data; Haskell validation and the existing effect capabilities control execution.

Scope includes a typed decision registry, operator model catalog, per-agent model allow-list, an isolated provider runner, durable accounting for every provider attempt, versioned decision journals, workflow declarations and gates, and a tested authoring example. It excludes per-node model selection, arbitrary provider identifiers from payloads, visual editing, IR-7 signing/read-API completion, and changing existing router semantics. Every actual call inside a program remains individually accounted for even though model selection is per invocation.

The Flow-facing contract belongs to Shikigami: a typed static decision slot, an authorized model alias and typed input produce a validated typed result. Shikumi and Handan APIs remain behind the registry and runner adapter; this boundary does not assume their APIs will never change. Probability-backed output types, Jev transport and calibration are optional future integrations, outside this initiative's acceptance criteria.


## Decomposition Strategy


Four work streams separate admission, execution, evidence persistence, and durable orchestration. Admission can be tested without a provider. Execution can be tested with an in-memory evidence callback. Persistence can be tested with provider evidence fixtures. Orchestration consumes all three and proves the complete request through the real workflow and PostgreSQL harness. Combining the runner with workflow evolution would obscure the independent provider and replay failure boundaries; splitting by Haskell files would create shared ownership without independently useful behavior.

The existing `Shikigami.Program.Registry` contains unrestricted Handan `Task` wrappers. `Behavior.Run.runProgramTask` passes input through an argument map and extracts an untyped envelope. It does not propagate `BehaviorEnv.model`, credentials, or call evidence into Handan. The new registry holds typed `Shikumi.Program` values, whose embedded effects are restricted to model calls and typed errors, and uses Handan's public runtime to execute them. Existing task names remain usable through their existing path.

Research on 2026-09-26 verified Shikumi 0.4.0.0 on Hackage and upstream tag `shikumi-0.4.0.0` at `59d38bcfcedc85602564063d35703f75480a6156`. Handan has no Hackage package or remote release tag; `cabal.project` pins `8e98b0a955f908f70657c04f384b6286e4967422`. At that revision `Runtime` exposes its default model and `LLMConfig`, including an explicit provider registry. Released Baikai exposes isolated registries and public provider handler wrappers. These APIs support a local adapter without an upstream extension. Hackage and tags also report Baikai 0.7.1.0 (`9f269c917c15d5449067f3c96e7ce3452fc6d7eb`), newer than the 0.7.0.0 cohort documented locally. No dependency upgrade is prescribed; the runner plan verifies the selected build against released source before choosing any bound change. Sources belong to `mori://shinzui/shikumi`, `mori://shinzui/handan`, and `mori://shinzui/baikai`; source-file artifact URIs are pending.

Relevant local decisions consulted are [ADR 0001](../adr/0001-declare-only-what-the-runtime-executes.md) (honest declarations), [ADR 0004](../adr/0004-one-options-value-and-a-checked-patch-set.md) (one workflow options owner), [ADR 0007](../adr/0007-a-resolved-profile-is-a-run-local-policy-snapshot.md) (pinned policy), [ADR 0010](../adr/0010-run-evidence-lifecycle-and-payloads-have-one-atomic-boundary.md) (atomic evidence and encode-only provider records), [ADR 0012](../adr/0012-a-declared-workflow-body-only-grows-behind-a-patch.md) (declared body evolution), [ADR 0013](../adr/0013-flow-bodies-reach-the-world-only-through-capabilities.md) (Flow effects), [ADR 0023](../adr/0023-delegation-is-governed-at-the-child-spawn-boundary.md), [ADR 0028](../adr/0028-a-router-catalog-is-a-bounded-snapshot-of-declared-authority.md), and [ADR 0029](../adr/0029-model-routing-output-is-a-proposal-until-validated-against-journaled-authority.md). The normative [workflow versioning rules](../workflow-versioning.md) govern all workflow changes. Historical ADR text describing retired patches does not override the current body.

Cross-repository research also read the request-default decision `mori://shinzui/shikumi/okf/adrs/concepts/ADR-12` and transport-accounting decision `mori://shinzui/shikumi/okf/adrs/concepts/ADR-13`. Their IDs and owning adrs bundle were checked against local source discovered through Mori; current registry handle lookups are stale and do not resolve them. These intended canonical handles follow the repository cross-reference rule despite that resolution gap. Their relevant constraints are embedded here: fill-only request defaults are not authorization; billing observations omit full call evidence and use process-local IDs; cache hits are not provider calls. The runner must enforce the final options and collect actual terminal evidence below internal retries.


## Exec-Plan Registry


| # | Title | Path | Hard Deps | Soft Deps | Status |
|---|-------|------|-----------|-----------|--------|
| 1 | Typed programs and authorized model catalogs | docs/plans/73-define-typed-decision-programs-and-authorized-model-catalogs.md | None | None | Not Started |
| 2 | Governed Shikumi provider execution | docs/plans/74-run-shikumi-decisions-through-governed-provider-calls.md | EP-1 | None | Not Started |
| 3 | Durable decision call evidence | docs/plans/75-persist-decision-call-evidence-across-retries-and-restarts.md | EP-1 | None | Not Started |
| 4 | Durable Flow composition and acceptance | docs/plans/76-compose-and-verify-typed-shikumi-decisions-in-durable-flows.md | EP-1, EP-2, EP-3 | None | Not Started |

EP numbers above identify registry rows; filenames contain repository-wide plan IDs. Status values are Not Started, In Progress, Complete, and Cancelled.


## Dependency Graph


EP-1 defines the descriptor, typed program registry, model selection, and callback contracts consumed by both EP-2 and EP-3. Once it is complete, those two plans can proceed independently: EP-2 proves execution against fake callbacks; EP-3 proves persistence against typed evidence fixtures. They have an integration dependency on the same begin/finish callback contract. EP-4 needs the real runner and store together before enabling the production capability.

```text
EP-1 (73) -> EP-2 (74) --+
          -> EP-3 (75) --+-> EP-4 (76)
```

The completed declarations/catalog/router work in `docs/masterplans/8-declarative-router-agents.md` and the implemented profile and evidence core in `docs/plans/50-fail-closed-profile-resolution-and-run-pinning.md` and `docs/plans/51-run-evidence-aggregate-and-compliance-roll-up.md` are existing prerequisites. The unfinished signing and endpoint work in `docs/plans/52-signed-attestation-read-api-and-uc-8-conformance.md` is not a hard dependency. It remains coordinated by `docs/masterplans/10-sanctioned-execution-attestation-for-agent-runs.md`. This initiative consumes the evidence core and must not claim an ordinary run has a reviewed-artifact binding it was never given.

`mori://shinzui/shikumi/masterplans/12-support-typesafe-jev-and-probability-backed-decision-outputs` is a coordination dependency, not a hard prerequisite for any child here. It plans probability-bearing results and local decision settings in program `Params`; its cache/trace replay can intentionally derive a different answer from the same provider response after settings change. Our current typed generative example needs none of those unreleased features. Before a future adoption, qualify the required published Shikumi/Baikai interfaces and the Handan adapter, retain the identities and codecs needed by existing runs, and introduce new program/result versions. Neither Jev support nor the calibration optimizer gates this initiative. The intended canonical MasterPlan URI is currently unresolved by Mori; the plan was read in the registered source checkout.


## Integration Points


EP-1 owns new modules `shikigami-core/src/Shikigami/Program/Decision.hs` and `shikigami-core/src/Shikigami/Decision/Contract.hs`. They define typed program references, immutable implementation/result-validator identities, serializable decision descriptors, bounded failures, and the begin/finish call callbacks. EP-2 implements the execution side; EP-3 implements storage callbacks; EP-4 composes them. Changing a persisted identity means a new version, never overwriting a registry key.

EP-1 also owns parameter-state identity: a versioned digest of the registered program's complete effective parameter state, including every node's instruction override and demonstrations, plus the version of local result derivation and its effective defaults. Future decision thresholds, cuts and weights must join that identity when supported. The policy snapshot, prepared decision and evidence references carry these identities; the immutable registration retains the matching executable and state. A request/cache key or structural program shape is insufficient because local settings can change an answer without changing either. EP-2 verifies a pending invocation against the full pinned identity; EP-3 stores it without reinterpreting it; EP-4 pins it for every slot before the first invocation. [ADR 0041](../adr/0041-durable-decisions-bind-program-state-and-preserve-committed-outcomes.md) records this boundary.

EP-1 owns `shikigami-core/src/Shikigami/Decision/ModelCatalog.hs`, the `decisionModels` agent allow-list, `schema/Agent.dhall`, and the operator catalog configuration in `Shikigami.App.Config`. EP-4 threads the resolved catalog through the worker and one-off agent runtime. EP-2 consumes a resolved selection and rechecks actual provider options. Secrets and provider handlers stay process-local; journals contain immutable descriptor identity and an opaque credential binding only. Missing or changed bindings cannot fall back to process defaults.

EP-2 owns `shikigami-core/src/Shikigami/Program/DecisionRunner.hs` and the refactoring of provider tuple checking in `Shikigami.Behavior.Provider`. An invocation uses a private registry with an authorized wrapper around the selected real handler; the wrapper is below Shikumi retries and captures each actual attempt. No process-global registry mutation changes another run's model or credential. The existing timeout, retry, rate, tool, and profile limits remain effective.

EP-3 owns new `shikigami-core/src/Shikigami/Decision/Evidence.hs`, additive attempt-ledger migrations, and extensions to `Shikigami.Attestation.Evidence`, `Compliance`, and `EvidenceStore`. The ledger records expected calls before dispatch and terminal evidence before a successful decision can be journaled. Full Baikai evidence stays encode-only JSON; restartable compliance uses an explicitly versioned Shikigami fact record derived from typed provider evidence. Both live and restarted roll-ups use one evaluator. EP-4 supplies stable parent run/workflow/generation/decision identities and invokes finalization; it never invents reviewed-artifact metadata.

Probability/confidence data, if present in a future registered output, is validated result data preserved by EP-1's versioned result codec and EP-4's outcome journal. It cannot satisfy EP-3's provider-attempt or compliance-evidence requirements. A completed outcome is decoded with its retained codec, never recomputed from provider evidence under new parameters. EP-4 owns a regression using current APIs that changes local derivation while leaving the provider response unchanged and proves both completed-result reuse and pending-state pinning.

EP-4 owns `shikigami-core/src/Shikigami/Flow/Decision.hs`, `FlowEffects`, workflow wiring, program and flow example registrations, `domain/shikigami-agent-run.keiro`, generated conformance expectations, and authoring documentation. It journals one complete decision-policy snapshot for the Flow and preparation/result steps for each call site. The snapshot binds all declared decision slots, including slots not yet executed, so changing a deployment between decisions cannot reinterpret the pending one. A completed step is read before consulting a live registry; pending steps require the pinned implementation and credential binding to remain available.

Each plan adds only its own module/test entries to `shikigami-core/shikigami-core.cabal` and test entry points. EP-1 is the owner of shared contract changes. EP-4 is the integration owner of all cross-plan amendments and the sole owner of workflow labels. Relevant durable decisions must be distilled into local ADRs during implementation, especially whole-Flow pinning, model authorization, private provider registries, crash accounting, and encode-only evidence recovery.


## Progress


All four children are Not Started. Plan 73 is ready first; plans 74 and 75 follow its accepted contracts, then plan 76 integrates them. [Shikumi MP-12](mori://shinzui/shikumi/masterplans/12-support-typesafe-jev-and-probability-backed-decision-outputs) does not block this scope. Each child owns its milestone checklist; the registry above remains the source of truth for whole-child status.


## Surprises & Discoveries


None recorded during implementation.


## Decision Log


2026-09-26: Split admission, execution, evidence, and workflow integration into four plans. The runner and evidence store have separate observable contracts and can be validated independently after admission types exist.

2026-09-26: Use a new typed decision registry and Handan's configurable runtime with private Baikai handlers. The arbitrary `Task.taskRun :: ... -> IO Envelope` boundary cannot guarantee decision-only effects or typed output. Public released APIs are sufficient; no upstream fork is planned.

2026-09-26: Pin the complete finite decision policy before the first invocation, then journal each invocation's selected descriptor and validated result. Pinning only completed results leaves a pending second decision vulnerable to catalog/program drift after a restart.

2026-09-26: Separate durable decisions from actual provider attempts. Keiro steps are at-least-once across the action/append crash window. Completed decision replay makes zero new calls, but a lost append can require a new provider attempt, which must be separately recorded rather than overwritten or called exactly-once.

2026-09-26: Keep IR-7's reviewed-artifact requirements honest. Persist ordinary run decision evidence and reuse its call-compliance evaluator; only an explicitly supplied valid review binding can participate in the existing sanctioned attestation lifecycle.

2026-10-21: Coordinate with `mori://shinzui/shikumi/masterplans/12-support-typesafe-jev-and-probability-backed-decision-outputs` without adding a hard dependency. Pin effective parameter state and derivation semantics, preserve committed outcomes independently of upstream cache/trace re-derivation, and keep probability data separate from execution evidence. Revision: clarify the adapter and identity contracts across plans 73–76 so implementation can proceed on current APIs; Jev and calibration remain outside acceptance. See ADR 0041.


## Outcomes & Retrospective


To be filled during implementation. Completion requires all six IR-12 acceptance cases and ADR distillation across all four child plans.
