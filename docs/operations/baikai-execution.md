# Configuring Baikai responses and foreground launches

Shikigami supports `stub`, `anthropic`, `openai` (Chat Completions), and
`openai-responses` for model responses. The shared worker, server and one-off
builder uses Baikai's public HTTP providers. The default stub calls no model.
Anthropic keeps its existing `claude-sonnet-4-6` default. OpenAI selections require
an explicit model present in the selected API's released Baikai catalog.
Unknown ids fail configuration; there is no alias substitution or provider fallback.

Background `claude-cli` and `codex-cli` responses require enforced deadlines,
bounded retained output and descendant confinement. The selected release adds
inherited process-group cancellation; cancellation alone does not supply those
remaining contracts. Configuration names the requirements before a model call. CLI
login is not currently an API-key-free background reporter path. See the
[complete setting/support inventory](../evidence/baikai-execution/contracts.md).

TypeSafe is available only through explicitly judgment-capable
[typed Flow decisions](../shikumi-flow-decisions.md). It uses its own
`TYPESAFE_API_KEY` and refuses generative defaults such as token limits and
reasoning options, including explicit `none`.

## Response configuration

```yaml
behavior:
  provider: openai-responses
  model: gpt-6.1-sol
  options:
    thinking: low
    max_tokens: 4096
    timeout_ms: 30000
    response_format:
      tag: JsonObject
credentials:
  providers:
    openai:
      api_key: PRIVATE_OPERATOR_KEY
```

Check the exact accepted model ids with a configuration check: an unknown id
reports the selected API catalog. `PRIVATE_OPERATOR_KEY` is an illustrative
placeholder; store the real value only in private configuration, or supply
`OPENAI_API_KEY`. `ANTHROPIC_API_KEY` is bound only to Anthropic's credential.
Each credential is required only by its matching selected HTTP API. Both remain
opaque until the shared builder's Baikai API-key boundary.

```sh
shikigami-run-behavior --check-config --config /private/path/response.yaml
shikigami-worker --explain-config --config /private/path/worker.yaml
```

Configuration diagnostics do not call a model or open a database. Every accepted
setting has an explicit environment binding: `SHIKIGAMI_BEHAVIOR_BASE_URL`, and
`SHIKIGAMI_BEHAVIOR_OPTIONS_` followed by the uppercase option name. Structured
headers, metadata and response format accept YAML objects or JSON text via
`--set`/environment. Stop sequences accept a YAML array or JSON array text.
Header values and credentials are redacted in configuration reports; metadata is
also redacted there, but provider metadata should contain public correlation
facts, not secrets. API keys and credential-looking header values remain redacted
in Baikai's Options renderings. Raw background provider arguments are unavailable.

The pure admission check rejects unsupported requirements with their public key,
for example `behavior.options.seed` on Anthropic, stop sequences on Responses,
or sampling on a model that cannot honor it. Numeric ranges and catalog output
limits are checked. Adaptive Anthropic `minimal` is refused because its renderer
clamps it to `low`. Anthropic tool choice `none` with advertised tools is refused
because that renderer omits the choice field while still sending tools. JSON
Schema names must be nonblank and schema roots must be objects or booleans; full
provider-specific schema validation remains with the provider. Required/named tool choice is checked against the actual
request's advertised tools immediately before each call. A Flow's JsonObject
requirement and a Skill's acquired registry cannot be silently dropped.
The actual model and thinking preference still pass the exact pinned-profile gate.

`behavior.base_url` overrides the actual endpoint, with no embedded credentials,
query or fragment. HTTP profile endpoint class follows its actual URL scheme;
an HTTPS-only profile refuses an `http://` override before dispatch. Flow routing
and practice review retain their caller-owned JsonObject preference; the
configured response format supplies the Skill/default request preference. Evidence identity/strictness, prompt/context, trace sink and
tool registry stay caller-owned. Endpoint/model reporting is a configured fact;
a returned response is not automatically proof of the served model identity.

## Governed assignment selection

Use the existing operator `behavior.decisionModels` catalog for whole-run aliases
as well as decision slots. Its historical configuration name does not grant an
agent either permission. For example, a private worker configuration can declare:

```yaml
behavior:
  decisionModels:
    - {alias: coordinator, version: "1", bindingId: coordinator, bindingVersion: "1", provider: openai-responses, model: gpt-6.1-sol, thinking: high}
    - {alias: worker-a, version: "1", bindingId: worker-a, bindingVersion: "1", provider: openai-responses, model: gpt-6.1-sol, thinking: medium}
    - {alias: worker-b, version: "1", bindingId: worker-b, bindingVersion: "1", provider: openai-responses, model: gpt-6.1-sol, thinking: low}
```

Credentials use the same private provider settings as above. Catalog entries
accept exact released models, explicit thinking (including `default`), optional
`max_tokens` and `timeout_ms`, and immutable descriptor/binding identities.
In an agent declaration, opt into whole-run selection with:

```dhall
execution = Some
  { defaultAlias = "coordinator"
  , permittedAliases = [ "coordinator", "worker-a", "worker-b" ]
  }
```

Typed `RunJob.executionRequest` can require a permitted alias/thinking value and
narrow permitted aliases. `executionPermissions` carries the parent's ceiling.
Neither field accepts endpoints, keys or vendor flags. Decision-slot permission
continues to use `decisionModels`; an unused default cannot grant or deny a slot.
Historical declarations omit `execution` and keep the process default.

New runs journal a complete immutable selection before calling a model. Changing
an alias or process default cannot reroute pending work: retain its exact binding
or the run reports `PinnedBindingUnavailable`. Credential rotation preserves the
opaque binding identity; changed endpoint/model/options authority needs a new
descriptor version. Each conversation message is an assignment; its admitted root
and user constraints persist across generation rotation and cannot change within
the live epoch. Overlays remain unavailable in conversations.

Each actual provider attempt reserves the shared root and assignment limits before
dispatch. Profile call/retry/concurrency/token limits survive retries and restart;
duration is an absolute deadline from admission. Profile lifecycle is checked at
dispatch using its exact pinned version/digest; revocation and expiry stop new
calls without replacing the recorded policy. Unsupported hard invoice-cost caps
refuse before dispatch because HTTP does not enforce an invoice ceiling.
Finite token envelopes require an explicit output limit and enough capacity for a
conservative model context plus output bound. Unknown billing remains unknown;
catalog price estimates never become measured cost. A terminal transport releases
its active slot while retaining missing billing holds. An uncertain transport keeps
its active reservation until reconciliation.

`shikigami runs show WORKFLOW_NAME WORKFLOW_ID --json` includes `execution` with
descriptor, current binding availability and up to 100 normalized attempt facts.
It keeps requested model identity separate from provider-reported identity and
omits effective options, credentials and request bodies. This accounting boundary
does not yet replay individual completed model/tool turns; the durable execution
transcript owns that recovery.

Apply migrations, upgrade queue readers to codec v3, then enable v3 producers.
Both v1 and v2 remain readable and gain no selection authority from old metadata.
Stop old workflow writers before enabling selection. After new selection journals
exist, roll forward. Keep accounting facts beyond terminal workflow GC.

## Attended launches

`shikigami-agent-launch interactive` is a foreground terminal session. It opens
no memory session or workflow and creates no sink receipt. The vendor CLI owns
the terminal and Shikigami propagates its exit status. Omitted model means the
visibly reported vendor default.

```yaml
launch:
  provider: codex
  working_directory: /tmp/disposable-workspace
  safety:
    codex_sandbox: read-only
    codex_approval: on-request
```

```sh
shikigami-agent-launch interactive --check-config --config /private/path/launch.yaml
shikigami-agent-launch interactive --config /private/path/launch.yaml \
  --prompt 'Describe the current directory without changing files.'
```

A real launch requires stdin and stdout terminals and an existing directory.
Directory paths must be absolute and are canonicalized at launch. Config checks
need no live workspace, vendor executable or login. `launch.model`,
`launch.thinking`, `launch.extra_directories`, `launch.executable` and secret
`launch.arguments` are optional. `--system-prompt` supplies a system prompt.
Every setting has an explicit `SHIKIGAMI_LAUNCH_…` binding, replacing dots by
underscores. Arguments and directory arrays use JSON text in environment/`--set`.

Claude uses `launch.provider: claude` and a nonempty
`launch.safety.claude_allowed_tools` array instead of Codex safety fields.
That field preapproves Claude tools; it is not a denial policy for other tools.
Cross-provider safety is refused before spawning. Codex supports `read-only`,
`workspace-write`, or `danger-full-access`, with `on-request` or `never` approval.
The operator explicitly chooses foreground authority. Arguments may contain
provider-native flags and remain redacted in effective reports. An unavailable
executable/directory is exit 69; configuration/refusal is exit 4; missing terminal
or prompt is exit 2. An executed vendor failure preserves that vendor exit.

## Unattended named jobs

The public Baikai parser retains its own `agent` group:

```sh
shikigami-agent-launch unattended agent --help
shikigami-agent-launch unattended agent list
shikigami-agent-launch unattended agent show inspect
printf '%s\n' 'Describe this disposable repository without changing files.' \
  | shikigami-agent-launch unattended agent run inspect --prompt-stdin
```

`.baikai/agents.kdl` names repository jobs; `~/.config/baikai/agents.kdl` supplies
operator defaults and the separate permission ceiling. Use Baikai's mounted
`--user-config` (operator scope), `--config` (repository scope), `--set` and evidence options. Repository input
cannot raise that ceiling, and Shikigami adds no exemption. A capturing job may be:

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

Baikai bounds retained output and terminates the process group on a job deadline.
Inherited output goes to real streams; it is not fabricated from returned text.
A process result is not a durable model Response. This wrapper does not qualify
workspace-tool authorization, idempotent durable jobs, memory or delivery.

## Process ownership and promotion

Vendor binaries and authenticated login are external host prerequisites. A
supervised Mac worker uses its actual process user's `HOME`, `PATH`, executable
and explicit working directory; an interactive shell's login/configuration is
not automatically shared with it. Never copy login stores into Shikigami
configuration or package outputs. Host service changes belong to
`mori://shinzui/dotfiles.nix/plans/4-bootstrap-persistent-shikigami-agents-and-validate-service-migration-learning`.
Inherited API variables may change vendor authentication; a future API-key-free
trial must remove Anthropic, OpenAI and Codex API variables and use a private
key-free config. Login does not replace authorization or delivery credentials.

Response configuration is process-local. A changed worker may make an unexecuted
or retried call with a different transport/model; its pinned profile still refuses
unapproved tuples. Drain older work or retain its prior configured worker during
promotion. Journal labels, step order and serialized inputs/results are unchanged
by the pure request checks. Existing recorded results replay without calling a
provider. Provider/login availability stays outside readiness probes.
