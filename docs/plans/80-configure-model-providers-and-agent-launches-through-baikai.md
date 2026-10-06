---
id: 80
slug: configure-model-providers-and-agent-launches-through-baikai
title: "Configure model providers and agent launches through Baikai"
kind: exec-plan
created_at: 2026-10-06T14:02:35Z
intention: "intention_01m47m186wenjt8ecxny19rm3m"
provenance:
  created_by:
    model: "gpt-6.1-sol"
    harness: "codex-cli"
    at: 2026-10-06T14:02:35Z
  revisions:
    - model: "gpt-6.1-sol"
      harness: "codex-cli"
      at: 2026-10-06T14:10:30Z
      mode: "other"
      note: "Ground initial provider and launch integration plan in current Shikigami wiring and verified released Baikai surfaces"
    - model: "gpt-6.1-sol"
      harness: "codex-cli"
      at: 2026-10-06T14:14:42Z
      mode: "implement"
      note: "Begin released adapter contract verification and implementation"
---

# Configure model providers and agent launches through Baikai


This ExecPlan is a living document. Keep Progress, Surprises & Discoveries, Decision Log, and Outcomes & Retrospective current. Distill implemented architectural decisions into `docs/adr/` before completion.


## Purpose / Big Picture


An operator can configure the model provider, transport, model, reasoning effort, and supported execution settings, with Baikai performing the provider call or agent launch. The target background reporter can use an already authenticated Codex or Claude CLI without an HTTP API key after the owning released cancellation/confinement prerequisite passes. The selected releases fail descendant cancellation, so this path remains unavailable; the HTTP and foreground integration is independently implemented. A separate foreground command can open an interactive session or run an unattended named Baikai coding job. Effective configuration explains the selected surface and settings before a model is called.

The foundation already exists: [plan 13](13-wire-a-real-model-provider-into-behavior-runs.md) installed a shared Baikai builder and typed provider configuration. At authoring revision `f740895`, Shikigami's operator choices remain `stub` and Anthropic HTTP. Baikai has more execution surfaces, and Shikigami's profile code understands their tags, but neither fact exposes them through runtime configuration. Extend that foundation rather than implementing provider integrations again.

“Everything configurable through Baikai” means model and agent execution choices supported by the selected Baikai release. Database, authorization, memory, delivery, manifests and workflow supervision retain their existing owners. A model response, an attended terminal session and a coding process have different results and authority. This plan exposes all three honestly.


## Progress


- [x] (2026-10-06 14:40 UTC) M1 released API/version inventory and bounded fake adapter probes complete; both batch adapters leave a child alive after cancellation.
- [ ] M1 remaining: owning released child-group cleanup/deadline/output fix, positive cancellation probe and installed reporter confinement audit.
- [x] (2026-10-06 14:40 UTC) M2 independent HTTP typed options, conditional credentials, catalog decoding and redacted reports implemented; core suite 425 checks pass.
- [ ] M2 remaining: CLI model/config resolution after the release prerequisite.
- [x] (2026-10-06 14:40 UTC) M3 three HTTP APIs dispatch through the shared builder, with pre-request compatibility and existing actual-tuple profile gates. Local Chat and Responses wire fixtures pass.
- [ ] M3 remaining: two CLI response handlers and positive confinement/profile-tuple qualification after the release prerequisite.
- [x] (2026-10-06 14:40 UTC) M4 foreground interactive resolver and public unattended parser mounted. All 37 agent checks pass, including operator-ceiling and exit semantics.
- [x] (2026-10-06 14:49 UTC) M4 real attended Codex 0.160.1 terminal opened, returned the public marker with key environment variables absent, and closed with propagated exit 0; no durable/background claim.
- [x] (2026-10-06 14:40 UTC) M5 HTTP/foreground docs and ADR 0040 written. Isolated full Cabal build, core 425, worker 88, server 47, PostgreSQL 197 and migration smoke checks pass. Frozen export has only intended Baikai upgrades plus agent/KDL additions.
- [ ] M5 remaining: committed descriptor solve, clean-source keiro gate, immutable role build and installed command evidence.
- [ ] M6: authenticated batch reporter remains blocked by the released lifecycle prerequisite. Live HTTP alternatives are untested; no service readiness is claimed.


## Surprises & Discoveries


Released batch adapters rethrow cancellation but lack an explicit child-group cleanup contract. Bounded fake-process probes confirm that a child remains alive for both selected released adapters; a typed promotion gate refuses CLI responses. background CLI resolution, confinement and M6 must wait for an owning released fix. See [contract inventory](../evidence/baikai-execution/contracts.md).

The public unattended parser includes its own `agent` group and does not export the inner parser. The mounted spelling is therefore `unattended agent run|show|list`, preserving Baikai grammar without copying it.


## Decision Log


Decision (2026-10-06 UTC): Extend `behavior.provider`, preserving `stub` and `anthropic`. Add `openai`, `openai-responses`, `claude-cli` and `codex-cli`, meaning OpenAI Chat Completions HTTP, OpenAI Responses HTTP, Claude batch CLI and Codex batch CLI respectively. Vendor request rendering, subprocess output parsing and model invocation belong to Baikai.

Decision (2026-10-06 UTC): Put attended and unattended launches in a separate foreground executable in `shikigami-agent`. A durable Skill needs a Baikai `Response`; interactive launchers return process exit and own the terminal, while unattended jobs can change a working tree. Neither replaces `run-behavior-v2`. Plans 48 and 78 retain governed workspace and durable external-job ownership.

Decision (2026-10-06 UTC): Reuse `Baikai.Agent.Config` and `Baikai.Agent.Cli` for unattended named jobs, including the operator-only policy ceiling and source reports. Settei remains Shikigami's existing resolver for response calls and the interactive wrapper. Baikai has an unattended job loader, not one universal configuration API for every surface; do not invent one or duplicate its KDL parser.

Decision (2026-10-06 UTC): Require explicit models and constrained vendor-native authority for background batch calls. Returning text does not prove a coding CLI's internal tools were disabled. If a public Baikai adapter cannot uphold confinement or cancellation, an owning Baikai release becomes a prerequisite; Shikigami must not copy its process engine to work around that gap.

Decision (2026-10-06 UTC): Inherit plan 79's active intention because this work enables its API-key-free provider path. Correct its earlier unconditional Anthropic key prerequisite during authoring. CLI login does not replace authorization or delivery credentials, and a CLI trial does not close plan 13's specifically Anthropic HTTP smoke acceptance.


Decision (2026-10-06 UTC): Keep CLI response selection unavailable while the released process lifecycle cannot establish descendant cleanup. Implement the independent HTTP and foreground paths and retain a typed request gate. Do not copy Baikai supervision into Shikigami.

Decision (2026-10-06 UTC): Preserve the public unattended parser's `agent` group under `unattended`. Its inner parser is not exported, so target examples adopt `unattended agent`.

## Outcomes & Retrospective


Implementation is in progress. HTTP and foreground integration are independently implemented and under final packaging qualification. Batch responses remain unavailable until the released cancellation/confinement contract is proven; no authenticated Shikigami batch result or service qualification is claimed. A separate real attended Codex session returned the public marker and closed with exit 0; details are in [qualification evidence](../evidence/baikai-execution/qualification.md).


## Context and Orientation


`shikigami-core/src/Shikigami/App/Config.hs` owns typed settings and explicit environment bindings. At the authoring baseline, `ProviderSelection` was `UseStub | UseAnthropic Model SecretText`; the implementation adds `UseHttp Model Options SecretText`. `behaviorProviderConfig` conditionally requires the matching HTTP vendor credential and decodes models against the selected API/vendor catalog. Anthropic keeps its existing default; OpenAI requires an explicit model. Settei resolves files, environment and command overrides, retaining sources and redacting secrets. `shikigami-core/src/Shikigami/App/Config/Load.hs` and `shikigami-core/src/Shikigami/App/Role.hs` implement shared configuration commands. The default stub contacts no provider.

`shikigami-core/src/Shikigami/Behavior/Provider.hs:newBehaviorEnvFor` creates the Shikumi runtime and registers the selected Baikai handler. Its `BehaviorEnv` carries the actual Baikai `Model`, `Options`, tool registry and trace sink. `providerCall` derives policy inputs from those actual values. `callSurface` already maps both CLI tags to endpoint class `cli`, but the builder has no CLI selection branch. A transport is the mechanism used to call a model: HTTP or a local subprocess here.

`shikigami-core/src/Shikigami/Behavior/Skill.hs` invokes `completeRequest`. With no Shikumi tools it takes a single-completion path; with tools it runs a bounded model/tool loop. `shikigami-core/src/Shikigami/Flow/Routing.hs` and `shikigami-core/src/Shikigami/PracticeReview/Capability.hs` also call Baikai and request `JsonObject` output. CLI response adapters do not support Shikigami's advertised tool loop. Current vendor releases support JSON schema output, but `JsonObject` has no CLI analogue. Do not silently drop a requirement or claim every Flow works through a CLI.

`shikigami-workers/src/Shikigami/Workers/Command/Worker.hs`, `shikigami-agent/src/Shikigami/Agent/Command/AgentRun.hs` and `shikigami-agent/src/Shikigami/Agent/Command/RunBehavior.hs` reuse the builder. Find every builder caller, including server/conversation composition, during implementation. The database-free behavior command deliberately refuses a manifest requiring a sanctioned profile. Database-backed runs resolve that policy before calling a provider. A sanctioned profile is a journaled permission snapshot naming exact provider/API/transport/model/thinking combinations; new transport configuration must preserve that admission boundary.

Discover dependency roots using `mori registry show shinzui/baikai --full` and read source at selected release tags. Never search `/nix/store`. Canonical packages are `mori://shinzui/baikai/packages/baikai`, `mori://shinzui/baikai/packages/baikai-claude`, `mori://shinzui/baikai/packages/baikai-openai` and `mori://shinzui/baikai/packages/baikai-agent`. Guides are `mori://shinzui/baikai/docs/cli-providers`, `mori://shinzui/baikai/docs/interactive-launches`, `mori://shinzui/baikai/docs/unattended-agent-runs` and `mori://shinzui/baikai/docs/model-call-evidence`. Necessary contracts are summarized here so those references are supporting material rather than unstated design requirements.

Public response modules are `Baikai.Provider.Claude.Api`, `Baikai.Provider.Claude.Cli`, `Baikai.Provider.OpenAI.Api`, `Baikai.Provider.OpenAI.Responses` and `Baikai.Provider.OpenAI.Cli`. Their tags are `AnthropicMessages`, `AnthropicMessagesCli`, `OpenAIChatCompletions`, `OpenAIResponses` and `OpenAICompletionsCli`. CLI config records expose executable, extra arguments and working directory; Codex also exposes ephemeral and Git-repository-check choices. Build CLI models with public `emptyModel`, explicit vendor/model id and the CLI tag. Do not dispatch an HTTP catalog descriptor unchanged through a CLI or fabricate model pricing/limits. Catalog limits may be reused only for the same explicit model and remain configured facts rather than evidence of the model actually served.

The interactive vocabulary is `Baikai.Interactive.InteractiveLaunchRequest`, with prompt, optional system prompt/model/effort, working directory, extra directories, safety and arguments. Vendor `launchClaudeInteractive` and `launchCodexInteractive` return `Either AgentRenderError InteractiveLaunchResult`. Refusal starts no process; a nonzero result means the process ran and failed. The unattended surface uses `Baikai.Agent.Config` for named jobs, `Baikai.Agent.Cli` for parsing/policy-aware execution, and `Baikai.Agent.Run.runAgentCommand` for bounded execution. Its operator ceiling is the maximum permission set repository jobs may request; repository config cannot raise it. Its runner bounds retained output and terminates the process group on timeout. These guarantees must not be assumed for the separate batch adapters without testing.

The authoring baseline froze core/Claude/OpenAI at 0.7.0.0; the implementation freezes core 0.7.2.0, Claude/OpenAI 0.7.1.0 and agent 0.2.0.1. The public CLI and interactive modules already exist at those tags. `shikigami-core/shikigami-core.cabal` now directly declares core, Claude and OpenAI; `shikigami-agent` directly depends on `baikai-agent` and both vendors for foreground execution. Transitive presence is not a direct import dependency. On 2026-10-06 UTC, Hackage `preferred.json` and upstream tags agreed on normal releases core 0.7.2.0, Claude/OpenAI 0.7.1.0 and agent 0.2.0.1. Current core/vendor tags peel to `7dd44f96e5bba1a0dfa6a693a6c4858d81ab9831`; agent 0.2.0.1 peels to `4a9547b00de18b095259e3720e1ede82670787c9`. Recheck the authoritative registry and upstream before changing pins. A local checkout or later guide alone does not establish compatibility with the frozen cohort.

Relevant architectural context is established. [ADR 0003](../adr/0003-a-seventh-package-keeps-one-off-agent-runs-light.md) keeps foreground commands in the light agent package. [ADR 0007](../adr/0007-a-resolved-profile-is-a-run-local-policy-snapshot.md) gates actual dispatch against pinned policy. [ADR 0012](../adr/0012-a-declared-workflow-body-only-grows-behind-a-patch.md) protects durable identities. [ADR 0021](../adr/0021-operator-verbs-wrap-the-owning-library.md) requires mounting owning-library commands. [ADR 0025](../adr/0025-capability-overlays-are-requests-for-additive-model-tools.md) keeps requested tools distinct from acquired authorized tools. [ADR 0026](../adr/0026-outbound-sink-credentials-stay-opaque-and-http-policy-lives-at-the-process-boundary.md) keeps secrets opaque until request construction and preserves cancellation. [ADR 0036](../adr/0036-external-agent-actions-require-fresh-exact-authorization.md) requires fresh admission of protected actions. [ADR 0020](../adr/0020-readiness-covers-only-what-restarting-can-fix.md) excludes provider/login availability from readiness. [ADR 0039](../adr/0039-deployment-roles-share-a-frozen-cabal-source-closure.md) requires a frozen package/source closure and installed-asset proof.

[Plan 48](48-add-a-portable-one-off-repository-agent-harness.md) owns declared-agent workspace policy; this plan adds no manifest tool authority. [Plan 73](73-define-typed-decision-programs-and-authorized-model-catalogs.md) owns future authorized aliases and catalog snapshots and must reuse this transport boundary. [Plan 78](78-run-external-operations-from-durable-flows-through-idempotent-shiki-jobs.md) owns durable external-job submission/observation. [Plan 79](79-qualify-local-agent-execution-and-prioritize-production-readiness.md) owns real authorization, memory, delivery, restart and human-wait qualification. A standalone launch does not close those plans.


## Plan of Work


### Milestone 1: Prove contracts and inventory the settings


Create `docs/evidence/baikai-execution/contracts.md` recording selected release descriptors, public imports, provider tags, option translations and mode-specific requirements. In the Mori-discovered Baikai root read `baikai/src/Baikai/Options.hs`, `baikai/src/Baikai/Interactive.hs`, all five vendor response modules, both interactive modules and `baikai-agent/src/Baikai/Agent/{Config,Cli,Run}.hs` at selected tags. Do not depend on `Internal` modules or vendor `Transport` modules explicitly documented as unstable.

Use temporary fake vendor executables to prove response decoding, failure classification, cancellation and schema support through public adapters before wiring new Shikigami branches. Keep contract cases in `shikigami-core/test/Shikigami/BehaviorProviderSpec.hs`. Assert cancellation leaves no live child and unsupported requirements are identified. Require an explicit operator working directory for a background subprocess; the worker's ambient directory is not a stable launch setting.

Audit vendor-native authority separately from Baikai's lack of advertised tool calling. Read bounded installed CLI `--help` output and official vendor documentation, then prove the selected disabling/confinement policy with fake argument assertions and a disposable real probe before promotion. The reporter must not receive edit/full-access flags or inherit a coding job's unrestricted policy. If the supported Baikai renderer cannot express necessary confinement or cancel children, record the exact missing contract and make a released fix in the owning Baikai package a prerequisite. Keep HTTP and foreground integration independently deliverable; do not copy a parser or supervisor into Shikigami.

Inventory every public response option, CLI config field, interactive request field and unattended job field. Each must be configurable, supplied per invocation by its existing caller, or explicitly inapplicable with a reason. Select verified released dependencies that satisfy the proofs, preserving unrelated Keiro/Kioku pins. The milestone passes when fake-provider tests and the inventory establish executable contracts without API credentials. Record unresolved upstream requirements with canonical artifact references if one is needed.


### Milestone 2: Extend typed configuration and effective reports


Refactor `ProviderSelection` and `behaviorProviderConfig` in `shikigami-core/src/Shikigami/App/Config.hs` into a resolved response configuration with choice, explicit Baikai model, supported options and conditional opaque credential. Preserve `stub`, existing Anthropic defaults and existing precedence. HTTP lookup filters the generated catalog by the chosen API, rather than using Anthropic's list for OpenAI. CLI models require a nonblank explicit vendor model id and carry their actual CLI tag. An unknown HTTP catalog model or unsupported API/option pair fails resolution; do not substitute a nearby model.

Add `behavior.base_url`, `behavior.options.*` and `behavior.cli.*` settings with explicit environment bindings. Map supported `thinking`, `max_tokens`, `temperature`, `timeout_ms`, `top_p`, `stop_sequences`, `seed`, `frequency_penalty`, `presence_penalty`, `cache_retention`, `speed`, `response_format`, `tool_choice`, `headers` and `metadata` to Baikai's public types. Decode schema JSON structurally, validate finite positive deadlines and numeric ranges, and preserve an explicitly configured endpoint in the actual model and public report. Model limits remain catalog facts, not unchecked operator claims. Evidence run identity/strength, tool registry and trace sink remain caller-owned; default configuration can request evidence only under that caller's policy.

CLI settings correspond to executable, canonical working directory, ephemeral session and Git-check fields in the selected vendor config. HTTP-only options on a CLI fail with the key named instead of being silently ignored. Raw provider arguments are secret-classified, operator-only escape hatches allowed only under the surface policy proven in M1; they cannot silently replace the constrained reporter policy. A foreground interactive operator may explicitly set arguments, and unattended arguments use Baikai's ceiling. Report support and source for every accepted setting.

Require `credentials.providers.anthropic.api_key` only for Anthropic HTTP and new `credentials.providers.openai.api_key` only for OpenAI HTTP. Bind `OPENAI_API_KEY` explicitly through Settei. Keep `SecretText` until the existing Baikai credential boundary; secret-bearing headers and raw arguments also stay redacted in configuration, errors and logs. CLI branches do not require or unwrap HTTP keys and never parse/copy vendor login stores. The subprocess uses the login of its actual process user. An inherited API environment variable can affect vendor authentication, so prove API-key-free operation with those variables removed.

Extend `shikigami-core/test/Shikigami/AppConfigSpec.hs` for all selections, conditional secrets, precedence, unknown models, invalid options and redaction. `--check-config` resolves without provider calls, database IO or CLI spawning. Executable/login availability is an explicit run/provider diagnostic rather than a hidden config probe. Acceptance is valid CLI configuration with both API variables absent, missing HTTP credentials refused by key name, identical legacy defaults and complete redacted effective reports.


### Milestone 3: Dispatch through one Baikai builder and gate every request


Extend `shikigami-core/src/Shikigami/Behavior/Provider.hs:newBehaviorEnvFor` to register the selected public provider. For custom CLI settings register the value returned by `claudeCliProvider` or `codexCliProvider` through the public Baikai registry. Add direct `baikai-openai` to `shikigami-core/shikigami-core.cabal`. Keep one resolved environment across worker, server/conversation composition and both existing one-off commands; entry points must not render vendor arguments or parse subprocess JSON.

Add a typed request-compatibility check beside the builder and invoke it immediately before every Baikai request in `shikigami-core/src/Shikigami/Behavior/Skill.hs`, `shikigami-core/src/Shikigami/Flow/Routing.hs` and `shikigami-core/src/Shikigami/PracticeReview/Capability.hs`. It checks actual options, response format and context/tool requirements. A CLI with advertised Shikumi tools or `JsonObject` refuses permanently before spawning. CLI JSON schema requests are admitted only when the selected public adapter and installed vendor capability support them; otherwise refuse before spawn. Preserve provider retry classification and rethrow asynchronous cancellation.

Keep `providerCall` derived from the actual model/options. Preserve `(messages, cli)` for Claude and `(completions, cli)` for Codex, with vendors `anthropic` and `openai`; OpenAI Responses uses `(responses, https)`. Do not loosen existing profiles or default CLI prohibitions. Tests prove explicitly allowed CLI tuples and refusal for HTTP-only policy, changed model, unapproved thinking and disallowed defaulted thinking. A CLI process success proves it ran, not which remote model served it; preserve Baikai's weaker evidence and unknown usage semantics.

Extend `shikigami-core/test/Shikigami/BehaviorProviderSpec.hs` and `shikigami-core/test/Shikigami/CapabilityProviderSpec.hs` with fake vendor and local HTTP fixtures, malformed JSON, missing executable, nonzero exit, cancellation, unsupported tool/schema and profile refusal. Invocation markers prove no process or HTTP call occurred for refusals. Discover and exercise every builder caller. If the registry is process-global, install one immutable selected handler at startup; do not overwrite it per run or promise independently configured concurrent environments without a public registry contract. Acceptance is the same resolved selection reaching the public adapter through worker and one-off composition, with actual request/policy violations refused before dispatch.


### Milestone 4: Expose attended and unattended foreground launches


Add `shikigami-agent/src/Shikigami/Agent/Command/Launch.hs`, `shikigami-agent/app/agent-launch/Main.hs` and executable `shikigami-agent-launch` in `shikigami-agent/shikigami-agent.cabal`. Its executable depends on its own library and stays free of worker/server/Kafka dependencies. Direct public Baikai vendor/agent dependencies belong only to packages importing them.

Add an `interactive` subcommand with the existing shared Settei configuration flags and a dedicated launch resolver requiring no database: `launch.provider=claude|codex`, optional `launch.model`, `launch.thinking`, required `launch.working_directory`, `launch.extra_directories`, vendor executable/arguments and typed `launch.safety` fields. Map per-invocation prompt and optional system prompt into `InteractiveLaunchRequest` and use the vendor launcher. Require a terminal for a real attended session; config/command inspection works without one and starts nothing. Require explicit safety: Codex sandbox/approval or Claude allowed-tools vocabulary. Preserve Baikai's cross-provider and unsupported-policy refusals, rather than silently weakening them. An omitted foreground model is a visibly reported vendor default, not an exact-model claim. Propagate process exit and distinguish refusal from an executed nonzero result.

Mount `Baikai.Agent.Cli.agentCliParser` under an `unattended` subtree and interpret `runAgentCli` or `runAgentCliWithPaths`. Expose its existing `run`, `show` and `list` commands and named-job settings. Reuse `.baikai/agents.kdl`, the operator file, resolution reports and separate ceiling source. Do not flatten these into `behavior.*`, duplicate precedence or allow repository input to raise the ceiling. Preserve Baikai's exit codes and output modes: inherited output goes to real streams and is not captured in the returned record. This wrapper adds no policy exemptions, memory session, delivery receipt or durable execution claim.

Add `shikigami-agent/test/Shikigami/Agent/LaunchSpec.hs` and extend `shikigami-agent/test/Shikigami/Agent/CommandSpec.hs`. Fake commands and temporary source files prove cwd, prompt, model, effort, policy refusal, operator ceiling, redaction and exit propagation. Compare mounted unattended parsing/results to Baikai's own API. Do not install vendor assets or commit workspace changes as a launch side effect. Acceptance is config-selected Claude or Codex for both foreground surfaces, with refusals proven before process creation.


### Milestone 5: Preserve journals, package commands and document the boundary


Update `docs/operations/configuration.md`, `docs/operations/operator-cli.md`, `docs/architecture/packages.md`, `README.md` and new `docs/operations/baikai-execution.md`. Include checked field/support inventory, effective reports, complete examples, unsupported-option errors, mode/result distinctions and login requirements. Document actual process user, `HOME`, `PATH`, executable and explicit cwd for a supervised Mac worker. Host service changes remain owned by `mori://shinzui/dotfiles.nix/plans/4-bootstrap-persistent-shikigami-agents-and-validate-service-migration-learning`; no vendor login store is copied into configuration or package outputs.

Provider configuration is process-local, not itself journaled. Preserve serialized inputs/results and existing workflow steps. Changing worker configuration can change an unexecuted or retried call; pinned profiles still refuse disallowed tuples. Document draining old work or retaining the prior configured worker during promotion. If any body under `shikigami-core/src/Shikigami/Agent/` or `shikigami-core/src/Shikigami/Flow/` changes, follow `docs/workflow-versioning.md`: classify the change, declare any needed patch in `domain/`, preserve old branches and pass `just keiro-gate`. Do not hide a journal change inside a configuration refactor.

Refresh the isolated committed solve and `nix/qualification/cohort.json` plus exact metadata/vendor archives when dependencies change. A release newer than `cabal.project`'s index cutoff requires a deliberate index-state/cohort update, not an ignored override. Use `tools/qualification/export-cohort.py` as documented in `tools/qualification/README.md`. Update `nix/qualification-package.nix` and `flake.module.nix`, the actual immutable executable assembly, to include the launch executable in the operator package. Vendor CLI binaries/login are external host prerequisites. Prove installed commands outside the checkout and no reliance on sibling sources or relative assets.

Run the full affected suites and gates below. Update or create a local ADR for implemented configuration/launch ownership following `docs/adr/README.md`; preserve established secret/profile/library decisions. Acceptance is a successful isolated build, regression and journal compatibility proof, four frozen role builds at the selected revision, and installed launch commands outside the repository. Record failed trials separately from successful retries.


### Milestone 6: Prove CLI login and hand off plan 79


With an already authenticated CLI under the intended process user, run the supplied-payload reporter through `shikigami-run-behavior` with both HTTP API key variables absent and no key in config. Select an explicit model supported by that login. Record revision, vendor version, transport, requested model, command, duration, process user and real outcome in `docs/evidence/baikai-execution/qualification.md`, retaining Baikai's weaker evidence claim. Separately open and close one real attended session in a disposable workspace with explicit policy. Never capture login files, keys or private prompts.

Each other provider has deterministic adapter coverage; mark live coverage individually. Live HTTP trials require their matching API credentials and are optional for this CLI acceptance. Lack of login leaves this live milestone unchecked with a concrete reason. Update plan 79, `docs/evidence/local-qualification/readiness.md` and `docs/roadmap.md` with implemented transport and remaining service/trust/destination prerequisites. A standalone response proves no memory, delivery, restart or human wait. Only an actual Anthropic HTTP run can close plan 13's HTTP smoke. Complete this plan after deterministic, installed, one authenticated batch CLI and one attended session evidence, naming untested live alternatives and any open integration gates.


## Concrete Steps


Run from the repository root. Discover sources and verify registry/releases before selecting new bounds or pins:

```bash
cd /Users/shinzui/Keikaku/bokuno/shikigami
git status --short
mori registry search baikai
mori registry show shinzui/baikai --full
mori registry docs shinzui/baikai
curl -fsSL https://hackage.haskell.org/package/baikai/preferred.json
curl -fsSL https://hackage.haskell.org/package/baikai-claude/preferred.json
curl -fsSL https://hackage.haskell.org/package/baikai-openai/preferred.json
curl -fsSL https://hackage.haskell.org/package/baikai-agent/preferred.json
git ls-remote --tags https://github.com/shinzui/baikai.git 'refs/tags/baikai-*'
```

Preserve ignored `cabal.project.local`. The helper prints one isolated committed project filename. Use it consistently and regenerate after changing the committed descriptor:

```bash
qualification_project=$(python3 tools/qualification/prepare-project.py)
nix develop --command cabal build all --enable-tests --project-file="$qualification_project"
nix develop --command cabal test shikigami-core-test shikigami-agent-test \
  shikigami-workers-test shikigami-server-test --project-file="$qualification_project"
just keiro-gate
bash tools/check-migration-schema-isolation.sh
git diff --check
```

Expected: all selected suites pass, no unapproved workflow change, only the documented historical migration exception, and no whitespace errors. If durable profile execution or workflow bodies change, run disposable PostgreSQL suites too:

```bash
nix develop --command cabal test shikigami-core-postgres-test \
  shikigami-migrations-smoke --project-file="$qualification_project"
```

After exporting the actual solved `plan.json` with the existing exporter, verify all role packages:

```bash
nix build --no-link .#shikigami .#shikigami-server .#shikigami-worker .#shikigami-migrate
```

The following batch response interfaces remain deferred: the selected releases fail cancellation and the current resolver refuses both CLI choices. Execute these future acceptance commands only after an owning released fix, positive cleanup/confinement checks and the remaining CLI resolver/dispatch implementation. Create a private config `/tmp/shikigami-baikai/cli.yaml` and a disposable existing working directory. Replace `EXPLICIT_CLI_MODEL_ID` with an actual model id supported by the login; it is a placeholder, not an application alias:

```yaml
behavior:
  provider: codex-cli
  model: EXPLICIT_CLI_MODEL_ID
  options:
    thinking: low
  cli:
    executable: codex
    working_directory: /tmp/shikigami-baikai/workspace
    ephemeral: true
    skip_git_repo_check: true
```

```bash
nix develop --command cabal run shikigami-run-behavior \
  --project-file="$qualification_project" -- --check-config \
  --config /tmp/shikigami-baikai/cli.yaml
nix develop --command env -u ANTHROPIC_API_KEY -u OPENAI_API_KEY -u CODEX_API_KEY \
  cabal run shikigami-run-behavior --project-file="$qualification_project" -- \
  --config /tmp/shikigami-baikai/cli.yaml \
  --agent fixtures/qualification/agents/service-health-reporter.dhall \
  --payload '{"text":"Qualification marker EP80: all supplied services are healthy."}'
```

Expected: `configuration valid` without spawning for the first command, and real reporter text referencing the supplied marker from the selected CLI for the second. This proves a response, not delivery. Repeat with `claude-cli`, Claude executable/model and no Codex-only settings when that login is available. An HTTP `anthropic` selection without a key must refuse naming `credentials.providers.anthropic.api_key` before dispatch.

An attended target config in `/tmp/shikigami-baikai/interactive.yaml` uses separate vocabulary:

```yaml
launch:
  provider: codex
  working_directory: /tmp/shikigami-baikai/workspace
  safety:
    codex_sandbox: read-only
    codex_approval: on-request
```

```bash
nix develop --command cabal run shikigami-agent-launch \
  --project-file="$qualification_project" -- interactive --check-config \
  --config /tmp/shikigami-baikai/interactive.yaml
nix develop --command cabal run shikigami-agent-launch \
  --project-file="$qualification_project" -- interactive \
  --config /tmp/shikigami-baikai/interactive.yaml \
  --prompt 'Describe the current directory without changing files.'
nix develop --command cabal run shikigami-agent-launch \
  --project-file="$qualification_project" -- unattended --help
```

Expected: the check starts nothing; attended execution opens the selected CLI terminal session and propagates exit. Unattended help displays Baikai's `agent` group; `unattended agent --help` displays `run`, `show`, `list` and original configuration options. Put this job in a disposable repository's `.baikai/agents.kdl`:

```kdl
jobs {
  inspect {
    provider "codex"
    working-dir "."
    timeout "2m"
    output "capture"
    safety {
      capability "read-only"
    }
  }
}
```

Run from that disposable repository with the installed command:

```bash
shikigami-agent-launch unattended agent show inspect
printf '%s\n' 'Describe this disposable repository without changing files.' \
  | shikigami-agent-launch unattended agent run inspect --prompt-stdin
```

Expected: source/policy report followed by a bounded job honoring the operator ceiling and preserving vendor exit. No Shikigami durable run or sink receipt is created. Execute these live model commands during implementation/qualification, not merely plan authoring.


## Validation and Acceptance


With no configuration, stub commands still run without keys/database. Legacy Anthropic retains its API/model and opaque key requirement. Every new response choice reaches its intended public Baikai handler, proved by fake markers or local HTTP fixtures. Unknown selections/models, missing matching credentials, invalid options, unsupported tool/schema requests and forbidden profiles refuse before external IO. CLI config validates without keys; missing executable/logout is a visible failure rather than fallback to HTTP or stub.

Meaningful regression cases cover exact cwd/argument transport, cancellation including children, API key/header/raw-argument redaction, no unsupported option loss, allowed/refused CLI tuples and no registry leakage. A configured reporting process must not silently acquire vendor-native mutation authority. Fake tests establish dispatch/policy contracts, not vendor login or remote model evidence.

Launch tests prove wrong-provider safety, exceeded ceiling and repository ceiling override start nothing; nonzero exit propagates; process results never become durable `Response` success. The isolated build, affected suites, workflow gate, frozen role builds and installed commands outside checkout must pass. Real CLI response and attended session records name vendor version, requested model, user and outcome, and distinguish reported facts from unverified served-model identity. Plan 79's remaining service and fault scenarios stay independently unchecked until observed.


## Idempotence and Recovery


Config checks, fake tests and command inspection are repeatable and make no real model call. Test fixtures own and clean up processes, directories and markers on success, exception and cancellation. Never stop unrelated user CLI sessions. Real model trials can consume usage every time; use fresh public markers and record attempts rather than promising one physical call.

The existing coarse durable behavior step can repeat a model call after a crash; this plan does not implement individual model-turn durability. Keep mutable coding jobs out of that step. Drain old runs or retain their old configured worker during rollout because transport selection is process-local and pinned profiles may refuse replacements. Roll back with the prior configuration and immutable package, retaining compatible journal code and old patch branches. Relogin never rewrites policy snapshots.

Use disposable workspaces for live attended/unattended trials. Preserve changed trees as evidence and use a new directory for retry rather than resetting a user's work. Recover API failures by fixing matching credential references, CLI failures by fixing executable/login/cwd, and policy refusals by an explicit operator decision rather than automatic downgrade. Provider/login availability remains outside readiness probes.


## Interfaces and Dependencies


The resolved response type in `shikigami-core/src/Shikigami/App/Config.hs` distinguishes stub, three HTTP APIs and two CLI APIs, carries exact Baikai model/options and opaque credentials, and is not a new journal payload. CLI configuration names operator executable/cwd. Preserve `newBehaviorEnvFor` as the common composition boundary and `providerCall` as its actual-dispatch projection. Use direct Haskell record field names and follow the repository's record-pattern guidance.

The typed compatibility check beside `Shikigami.Behavior.Provider` accepts actual selected model/options plus request context/tool requirements and returns a permanent refusal before IO. Each model caller maps that result into its existing failure algebra. A launch-specific resolver/entry point in the agent package needs no database; mounted unattended parsing/running uses public `Baikai.Agent.Cli` records and returns exit/output without a local process engine.

Expose the response guard with this pure contract, naming the refusal constructors for unsupported tools, format and options during M1. Rendering identifies the public setting or requirement and never includes a credential, prompt or raw arguments:

```haskell
validateResponseRequest ::
  Model -> Options -> Context -> Either ResponseCompatibilityError ()

renderResponseCompatibilityError :: ResponseCompatibilityError -> Text
```

`Model`, `Options` and `Context` are the selected public Baikai types. The guard validates support; it neither changes the request nor downgrades its requirements. Profile permission checking remains the existing separate check against the pinned policy and actual `providerCall`.

Required response packages are `mori://shinzui/baikai/packages/baikai`, `mori://shinzui/baikai/packages/baikai-claude` and `mori://shinzui/baikai/packages/baikai-openai`. Unattended integration adds `mori://shinzui/baikai/packages/baikai-agent` at the agent composition leaf. Select verified released versions in M1, freezing exact descriptors and source hashes; do not weaken bounds or advance unrelated runtime packages to obtain a solve. Models, reasoning constructors and safety vocabulary must come from the selected coherent Baikai release.

No authorization or delivery service is needed for deterministic tests or foreground launch commands. M6 requires an authenticated vendor CLI; live HTTP tests require matching API credentials. PostgreSQL 18, Shomei/Kikan-En trust/grants, Kawa and later Danwa/Kizashi remain plan 79 prerequisites. Vendor CLI login replaces none of those credentials.


## Revision Notes


2026-10-06 UTC: Created after auditing the existing plan-13 builder and released Baikai surfaces. Scoped missing selectable transports/options and foreground integration, retained existing policy owners, and corrected the unconditional API-key prerequisite in plan-79 readiness guidance.

2026-10-06 UTC: Implementation separates deliverable HTTP/foreground integration from the batch release prerequisite; the public unattended grammar retains its `agent` group. Trials and final acceptance remain tracked independently.

2026-10-06 14:40 UTC: Split implemented HTTP/foreground work from remaining CLI acceptance after both released adapters failed descendant cancellation probes. Added actual parser spelling, frozen cohort, pure request guards and ADR 0040; no authenticated batch or service result is claimed.

2026-10-06 14:49 UTC: Added preflight refusals for Anthropic adaptive minimal clamping, none-tool choice with advertised tools, and invalid schema document roots. Real attended Codex trial returned the public marker and exit 0; batch remains blocked.
