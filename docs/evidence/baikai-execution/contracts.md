# Baikai execution contracts

## IR-5 released streaming follow-up — 2026-11-03 UTC

The application now selects Shikumi 0.5.1.0, cache 0.2.1.1, tools 0.4.2.1 and
trace 0.3.2.0 at index `2026-11-03T12:48:57Z`. Authoritative Hackage versions,
descriptor hashes and matching upstream tag bytes are retained in
[the release record](shikumi-streaming-release.json). All four tags peel to
`7b96ecf06364b37de44b15c4f58b2528b5a3e0f5` in `mori://shinzui/shikumi`.
The coupled application solve succeeds without new bounds overrides or changes
to the Kioku, Baikai, Effectful or Handan selections.

All 15 real TypeSafe consumer checks pass through complete and streamed public
execution, including exact request/raw/typed parity, atomic event ordering,
acknowledged terminals and failure/cancellation boundaries. FRIC-49 is resolved.
The following 0.5.0 and October records retain their historical meaning; they
do not describe the current streaming capability.

## Released-cohort consumer checkpoint — 2026-11-03 UTC

Kioku API/core/migrations 0.12.0.2 now admits Shikumi 0.5.0.0; tag
`v0.12.0.2` at `mori://shinzui/kioku` peels to
`5a62c3ef29cad50543f7bae97126e0431225998d`. FRIC-48 is resolved. The full
application candidate resolves at index `2026-11-03T02:59:02Z` with Baikai
0.10.0.0, vendors 0.7.3.0, agent 0.2.0.4, TypeSafe 0.1.0.1, Shikumi 0.5.0.0
and its published companion packages, Effectful 2.7.1.0/core 2.7.1.2 and
strict-mutable-base 2.0.0.0. The existing Handan source pin builds unchanged.
No new bounds override is used. The successful solve is exported to the frozen
Nix cohort: 387 runtime packages and seven immutable repositories. All five
role attributes evaluate in a dry run; immutable builds and installed-asset
qualification remain separate acceptance gates.

The real public TypeSafe complete path and durable queue/restart checks are
recorded in [structured-judgments.md](structured-judgments.md). Public Shikumi
judgment streaming still refuses before transport; FRIC-49 is promoted to
`mori://shinzui/shikumi/okf/improvement-requests/concepts/IR-5`.

Both CLI adapters now pass the positive inherited-group cancellation probes in
`BehaviorProviderSpec`: synchronize on an owned child, cancel the caller, require
the original `ThreadKilled`, and verify the child is gone. The probes use fake
executables and no vendor login. These are Darwin consumer results; Linux
consumer qualification remains open. The application gate is now
`BatchBoundsAndConfinementRequired`: the batch APIs still need an enforced
deadline, bounded retained output and descendant confinement. Group
cancellation does not establish those properties.

## Shikumi publication follow-up — 2026-11-03 UTC

Shikumi 0.5.0.0, tools 0.4.2.0, cache 0.2.1.0, trace/eval 0.3.1.0 and
trace-otel 0.1.3.0 now admit Baikai 0.10. Their release tags peel to
`b9b7a73f276ec022a72d00a447d320eade1cb741` in `mori://shinzui/shikumi`.
FRIC-46 is resolved. [The follow-up evidence](shikumi-release-followup.json)
retains descriptor hashes and complete paired probe projects at fixed index
`2026-11-03T02:09:47Z`: the Baikai 0.10 / Shikumi 0.5 dry-run succeeds, while
adding Kioku core 0.12.0.1 fails:

```text
rejecting: kioku-core-0.12.0.1 (conflict: shikumi==0.5.0.0, kioku-core => shikumi^>=0.4.1.1)
```

The next prerequisite is a validated compatibility revision or release from
`mori://shinzui/kioku/packages/kioku-core`, recorded as FRIC-48. Application pins
are unchanged. This checks solver contracts only; it proves no upgraded build,
TypeSafe application path, cache roundtrip or runtime lifecycle. Earlier evidence
below retains the versions and failure observed at its own checkpoint.

## Release prerequisite recheck — 2026-11-03 UTC

[The machine-readable check](release-prerequisite.json) records current normal
Hackage versions, downloaded descriptor hashes, relevant bounds and verified
upstream tags. Baikai core 0.10.0.0, Claude/OpenAI 0.7.3.0, agent 0.2.0.4 and
TypeSafe 0.1.0.1 are published. All six imported Shikumi packages still exclude
core 0.9 and 0.10 in their published descriptors. Kioku core 0.12.0.1 admits 0.10,
but does not remove that Shikumi conflict. The application pins remain unchanged.

After `cabal update`, an isolated library with only `base`, `baikai ==0.10.0.0`
and `shikumi ==0.4.1.1`, compiler GHC 9.12.4 and index state
`2026-11-02T23:00:00Z` fails `cabal build all --dry-run` with:

```text
Error: [Cabal-7107]
rejecting: baikai-0.10.0.0 (conflict: shikumi => baikai>=0.8.0.0 && <0.9)
```

The probe uses no sibling source, bounds override or application pins, so it
isolates the owning release prerequisite. Recreate it in a temporary directory
with this library descriptor and a `Probe.hs` containing `module Probe where`:

```cabal
cabal-version: 3.0
name: ep80-release-probe
version: 0.1.0.0
build-type: Simple
library
  exposed-modules: Probe
  build-depends: base, baikai ==0.10.0.0, shikumi ==0.4.1.1
  default-language: Haskell2010
```

Its `cabal.project` is:

```cabal
packages: .
with-compiler: ghc-9.12.4
index-state: 2026-11-02T23:00:00Z
```

Run from the Shikigami checkout with
`nix develop --command cabal build all --dry-run --project-file=ABSOLUTE_PROBE_DIRECTORY/cabal.project`.
The prerequisite is a published compatible Shikumi consumer, including the public
judgment router/derivation APIs and structured cache codec, from
`mori://shinzui/shikumi`. FRIC-46 records this occurrence. No upgraded cancellation,
deadline, confinement, Linux runtime or TypeSafe application qualification is
claimed. The cancellation fix is published; the negative probes below apply to
the application's retained October Baikai pins.

Independent application work exposes optional decision-binding `base_url` and
`cache_retention`, using existing endpoint and retention validation. Changed
selections get different descriptor digests; omitted settings preserve legacy
identity. A conflicting program retention refuses before attempt admission.
Focused complete/stream tests and a public Anthropic adapter loopback fixture
exercise that path. The fixture checks the retained adapter's existing top-level
cache controls; it does not qualify the newer shared-prefix implementation.

## October qualified inventory

Inspected on 2026-10-06 UTC using Mori discovery, Hackage `preferred.json`, and
upstream annotated release tags. The selected released packages are
`mori://shinzui/baikai/packages/baikai` 0.7.2.0,
`mori://shinzui/baikai/packages/baikai-claude` 0.7.1.0,
`mori://shinzui/baikai/packages/baikai-openai` 0.7.1.0, and
`mori://shinzui/baikai/packages/baikai-agent` 0.2.0.1.
The first three tags peel to `7dd44f96e5bba1a0dfa6a693a6c4858d81ab9831`;
the agent tag peels to `4a9547b00de18b095259e3720e1ede82670787c9`.
Hackage preferred versions and the upstream tag identities were rechecked at
2026-10-06 15:25 UTC and still report these selections; no newer vendor fix is
published. The Cabal index
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

## October batch release prerequisite (historical)

Owning defect report: `mori://shinzui/baikai/okf/bug-reports/concepts/BUG-1`
(status `reported`), with the exact bounded reproduction and cancellation fix
acceptance. Additional deadline/output/confinement requirements below remain
separate qualification prerequisites.

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
| thinking | `behavior.options.thinking` | Typed six-level vocabulary; unsupported/clamped model/effort refused |
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
| responseFormat | `behavior.options.response_format` | Baikai JSON plus nonblank schema name and object/boolean document root |
| toolChoice | `behavior.options.tool_choice` | auto/none/required/function name; actual request must advertise tools for required/named; Anthropic none with tools refused |
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
