# Baikai execution contracts

Inspected on 2026-10-06 UTC using Mori discovery, Hackage `preferred.json`, and
upstream annotated release tags. The selected released packages are
`mori://shinzui/baikai/packages/baikai` 0.7.2.0,
`mori://shinzui/baikai/packages/baikai-claude` 0.7.1.0,
`mori://shinzui/baikai/packages/baikai-openai` 0.7.1.0, and
`mori://shinzui/baikai/packages/baikai-agent` 0.2.0.1.
The first three tags peel to `7dd44f96e5bba1a0dfa6a693a6c4858d81ab9831`;
the agent tag peels to `4a9547b00de18b095259e3720e1ede82670787c9`.
The registry still reports those as its newest normal releases. The Cabal index
cutoff advances to 2026-10-06T14:00:00Z, with every previously frozen Hackage
runtime version retained by explicit constraints. The solve adds the unattended
package and its KDL configuration dependencies.

Public response imports are `Baikai.Provider.Claude.Api`,
`Baikai.Provider.Claude.Cli`, `Baikai.Provider.OpenAI.Api`,
`Baikai.Provider.OpenAI.Responses`, and `Baikai.Provider.OpenAI.Cli`.
Their tags respectively are `AnthropicMessages`, `AnthropicMessagesCli`,
`OpenAIChatCompletions`, `OpenAIResponses`, and `OpenAICompletionsCli`.
The HTTP handlers expose immutable default provider values; configuration is in
the actual model/options, so repeated registration does not replace per-run
executable configuration. Baikai's default registry is global. Shikigami uses
only the immutable shipped HTTP handlers and its immutable stub handler here.

## Batch release prerequisite

The released Codex adapter uses `withCreateProcess` without `create_group` or a
process-group termination strategy. The released Claude adapter uses Cradle.
Both rethrow asynchronous cancellation through Baikai's `trySync`, but that alone
does not establish descendant cleanup. `BehaviorProviderSpec` contains bounded
fake-process probes: a shell starts a five-second child, records both owned PIDs,
then receives cancellation. The probes assert the known surviving-child gap and
keep `validateResponseOptions` refusing both CLI tags. Test cleanup explicitly
terminates only the recorded fixture processes. Promotion must replace the
negative assertion with a no-survivor assertion against a released adapter,
remove `BatchCancellationReleaseRequired`, and finish the CLI resolver and live
qualification. No process supervisor or JSON parser is copied into Shikigami.

The owning prerequisite is `mori://shinzui/baikai` with project-relative sources
`baikai-openai/src/Baikai/Provider/OpenAI/Cli.hs` and
`baikai-claude/src/Baikai/Provider/Claude/Cli.hs`; artifact-level source URIs are
pending. It needs child-group cancellation, an enforced batch deadline and
bounded output, with synchronous failures still classified and asynchronous
exceptions rethrown. These are separate from the unattended runner's guarantees.
No authenticated batch response is claimed for Shikigami.

Installed help reports Codex 0.160.1 and Claude Code 2.1.291. Official
[Codex CLI reference](https://developers.openai.com/codex/cli/reference/) and
[Claude CLI reference](https://code.claude.com/docs/en/cli-reference) were checked.
Claude's `--tools ""` disables built-in tools; `--allowedTools` preapproves tools
and is not a deny list. Codex supports a read-only sandbox, but native tools,
user configuration, hooks and MCP need a separate confinement audit. Neither
adapter's default argument vector supplies reporter confinement. Raw arguments
can express flags, but they are not permission to accept arbitrary operator
arguments into a constrained background reporter. No real confinement probe is
promoted while the process-lifecycle prerequisite fails.

## Response setting inventory

Every field in public `Baikai.Options.Options` has an owner:

| Field | Shikigami setting or owner | Support/refusal |
| --- | --- | --- |
| apiKey | `credentials.providers.{anthropic,openai}.api_key` | Required only by matching HTTP selection; lowered at builder |
| thinking | `behavior.options.thinking` | Typed six-level vocabulary; unsupported model/effort refused |
| maxTokens | `behavior.options.max_tokens` | Positive; catalog limit retained and checked |
| temperature | `behavior.options.temperature` | Finite 0–2; unsupported model/thinking combination refused |
| timeoutMs | `behavior.options.timeout_ms` | Integer 1–86400000; public HTTP whole-call deadline |
| topP | `behavior.options.top_p` | Finite 0–1; unsupported sampling refused |
| stopSequences | `behavior.options.stop_sequences` | Array; Messages and Chat only |
| seed | `behavior.options.seed` | Integer; Chat only |
| frequencyPenalty | `behavior.options.frequency_penalty` | Finite −2–2; Chat only |
| presencePenalty | `behavior.options.presence_penalty` | Finite −2–2; Chat only |
| cacheRetention | `behavior.options.cache_retention` | none/short/long; selected model/endpoint must honor it |
| speed | `behavior.options.speed` | standard/fast; Messages only, fast catalog-gated |
| responseFormat | `behavior.options.response_format` | Structural Baikai `JsonObject`/`JsonSchema` JSON |
| toolChoice | `behavior.options.tool_choice` | auto/none/required/function name; actual request must advertise tools |
| headers | `behavior.options.headers` | HTTP map; entire configuration value redacted |
| metadata | `behavior.options.metadata` | Responses only; bounded string map; configuration redacted |
| evidence | Caller-owned | Run identity, evidence strength and strictness are never invented from operator defaults |

`behavior.base_url` updates the actual model endpoint and is visible in effective
configuration. Credential-bearing, query-bearing and fragment-bearing endpoint
URLs are refused. Catalog model identity, limits, prices and compatibility remain
catalog facts. Context messages/system prompt/tools, trace sink, tool registry and
run evidence identity remain supplied by existing callers. Stub defaults and
legacy Anthropic defaults stay intact.

Claude batch config has executable, extraArgs and workingDir. Codex adds
skipGitRepoCheck and ephemeral. All these response CLI settings are deferred until
the lifecycle and confinement prerequisite passes; neither selectable CLI nor
`behavior.cli.*` keys are advertised as implemented. CLI JsonObject and Shikumi
tools receive typed permanent refusals even for hand-built environments. CLI
schema adapters render schema JSON, but schema name/strict have no CLI analogue;
installed flag availability and confinement require qualification before admission.

## Foreground setting inventory

Every `InteractiveLaunchRequest` field is supplied: userPrompt/systemPrompt by
`--prompt`/`--system-prompt`; modelId/effort by `launch.model`/`launch.thinking`;
workingDir by required `launch.working_directory`; extraDirs by
`launch.extra_directories`; extraArgs by secret-classified `launch.arguments`;
safety by explicit `launch.safety.codex_sandbox` plus
`launch.safety.codex_approval`, or nonempty `launch.safety.claude_allowed_tools`.
Vendor config executable is `launch.executable`; its separate extraArgs is empty
to avoid two argument sources. Omitted model means visibly reported vendor default.
Real launch requires stdin/stdout terminals. Configuration checks spawn nothing.
The public vendor renderer and launcher retain refusal versus executed-exit
semantics. Paths are canonicalized and checked at the actual launch boundary.

Every public `AgentJob` field stays with the mounted Baikai loader:
provider, executable, modelId, effort, workingDir, extraDirs, capability,
allowedTools, providerArgs, timeout, output, outputFormat, outputLimit, envRequires.
The operator ceiling and repository-scope refusal are owned by
`Baikai.Agent.Config`; Shikigami adds no resolution layer or ceiling bypass.
`Baikai.Agent.Cli.agentCliParser` includes its public `agent` group, so the exact
mounted command is `shikigami-agent-launch unattended agent …`. The public parser
does not export the inner group. Flattening would duplicate private grammar.
Prompt transport, environment requirements, output mode, retained output bounds,
process group deadline handling, and evidence options remain library-owned.
Inherited output is emitted directly by Baikai; returned streams hold only the
library's captured text. Exit codes pass through unchanged.
