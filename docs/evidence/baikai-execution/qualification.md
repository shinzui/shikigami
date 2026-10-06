# Baikai execution qualification — 2026-10-06

The HTTP and foreground implementation is qualified independently of batch CLI
promotion. The tested source revision is
`9ce65b23daed965e62db61d0145cfd5006bcfd81`; immutable and installed checks pass.
No live background reporter or service readiness is claimed.

## Released contracts and deterministic checks

- Mori, Hackage preferred versions and upstream release tags agree on core
  0.7.2.0, Claude/OpenAI 0.7.1.0 and agent 0.2.0.1; see [contracts](contracts.md).
- An isolated relocation of the committed descriptor (initially the working
  descriptor before checkpoint) excludes ignored `cabal.project.local` overrides.
  `cabal build all --enable-tests` passes. The frozen solve changes only core,
  Claude and OpenAI versions; agent 0.2.0.1, kdl-hs 1.1.1 and settei-kdl 0.2.0.0
  are added. Export: 357 runtime packages and five immutable repositories.
- Core: 425 checks pass. Includes conditional credentials, catalog/API model
  decoding, typed option ranges, secret redaction, exact profile tuples across all five
  transports (including separate CLI prohibition), no silent adaptive-effort or
  none-tool loss, structural schema checks, real local Chat/Responses HTTP
  wire fixtures, released fake CLI decoding/error paths and cancellation probes.
  The Responses fixture initially lacked the required message item id; corrected
  fixture passes without changing the adapter.
- Agent: 37 checks pass, including terminal-independent fake attended flags/cwd/
  exit 7, pure diagnostics, mounted/native command agreement, executed unattended
  exit 7, operator ceiling refusal and repository policy escalation refusal.
  An initial operator fixture inside the checkout was correctly refused; moving
  it to a separate directory gives the intended trusted-policy test.
- Worker: 88; server: 47; PostgreSQL core: 197; migration smoke: 9 checks pass.
  The workflow tests include replay and durable failure/resume behavior. The new
  guards are pure preflight in existing capabilities and change no workflow step
  or journal result shape. No new patch id is required.
- Qualification Python tests: seven pass. Migration-schema isolation passes.

The bounded cancellation probes intentionally assert the released gap: cancelling
both batch adapters leaves their recorded five-second child alive. Fixture cleanup
terminates only owned recorded PIDs. CLI selection remains refused at configuration
and request boundaries. These negative checks are not cancellation acceptance.
Positive descendant cleanup, enforced deadline/output bounds and installed native
confinement still require an owning released Baikai fix.

## Immutable packaging and workflow gate

At final code revision `9ce65b2`, the committed-descriptor full build passes.
`just keiro-gate 9872e2d` passes unchanged, with an isolated-project Cabal wrapper
that preserves ignored overrides. All five workspace members pass Language 6
checking, regeneration is a no-op, there are no compatibility findings, replay
is neutral and all 37 conformance assertions pass. Reports: [diff](keiro-diff.json)
and [replay impact](keiro-replay-impact.json). Worker 88, server 47 and PostgreSQL
197 checks were repeated at `3280233` using its built binaries and pass.

The initial `3280233` immutable build is superseded by the endpoint-policy
correction: pre-dispatch now derives the actual HTTP URL scheme, matching existing
terminal compliance. The profile matrix tests all three HTTP APIs against an
HTTPS-only refusal and explicit plaintext admission. At `9ce65b2`, all 425 core
and 37 agent checks and the unchanged workflow gate pass again. The final
immutable build uses this corrected revision and passes. The first
`just keiro-gate` trial passed language checking and inspection, but its scaffold
recipe treats *any* uncommitted handwritten core source as drift. No generated
source changed. Successful repeats after the implementation checkpoints retained
the repository gate unchanged.

## Installed package proof

At 2026-10-06 16:28 UTC, all five immutable role targets built successfully from
`9ce65b2`: operator, server, worker, migrate and standalone agent launch. The common
runtime build phase took 43 minutes 16 seconds. At 16:30 UTC, 11 installed command
checks pass from a disposable directory outside the checkout, with all three
API-key variables and all `SHIKIGAMI_*` overrides removed. Nine commands exit 0;
the missing OpenAI credential and blocked batch selection intentionally exit 4.
See [exact outputs and command inputs](installed-checks.json).

Checks cover role version/help entry points, both operator-mounted and standalone
launch commands, the public unattended grammar, pure interactive configuration
with an absent working directory, matching OpenAI credential refusal, valid typed
HTTP options, absence of credential echo and the batch lifecycle promotion gate. The pure
behavior checks use an absent agent file: configuration diagnostics perform no
manifest loading or provider call. The one-off behavior command belongs to the
common runtime; the operator role exports the main CLI and launch command.

Initial smoke-harness attempts failed before a provider call: the behavior binary
was looked up in the wrong role, the log parser selected a derivation stem instead
of its output, and the required `--agent` parser argument was absent. Correcting
those harness inputs gives the successful 11-check retry against the unchanged
built packages. No package implementation change was required.

## Live coverage

| Surface | Coverage |
| --- | --- |
| Anthropic Messages HTTP | Deterministic legacy/config coverage; live untested |
| OpenAI Chat Completions HTTP | Local HTTP/SSE fixture; live untested |
| OpenAI Responses HTTP | Local HTTP/SSE fixture; live untested |
| Claude batch response | Fake decoding/error and negative cancellation probe; live blocked |
| Codex batch response | Fake decoding/error and negative cancellation probe; live blocked |
| Attended terminal | Codex 0.160.1 real terminal response and clean exit; details below |
| Unattended named jobs | Real read-only Codex job returns marker and exit 0; fake ceiling/exit checks pass |

A foreground process exit is not a durable model response or served-model identity.
No login files, provider credentials or private prompts are captured here.

## Attended Codex trial

At 2026-10-06 14:48–14:49 UTC, process user `shinzui` launched the rebuilt
foreground binary from a disposable directory through public Baikai interactive
launching. Source baseline `770969b` plus later pure response-preflight edits;
those edits do not change the launch module. Codex version: 0.160.1. Configured
model: omitted and explicitly announced as `vendor-default`; vendor UI displayed
GPT-6.1-Sol/high. This is vendor-reported identity, not attested served identity.

```sh
env -u ANTHROPIC_API_KEY -u OPENAI_API_KEY -u CODEX_API_KEY TERM=xterm-256color \
  /tmp/dist-newstyle/build/aarch64-osx/ghc-9.12.4/shikigami-agent-0.1.0.0/x/shikigami-agent-launch/build/shikigami-agent-launch/shikigami-agent-launch \
  interactive --config /tmp/shikigami-ep80-attended-3xk_ljlw/launch.yaml \
  --prompt 'Reply with qualification-ep80-attended and do not inspect or change files.'
```

The private temporary config contains only Codex provider, explicit disposable
working directory, `read-only` sandbox and `on-request` approval. No API credential
or login file was copied. The terminal opened, received the public prompt and
returned `qualification-ep80-attended` (vendor displayed three seconds of work).
The session closed with `/quit`; Shikigami propagated exit 0. Total attended
trial was approximately 38 seconds. Native MCP startup was visible, reinforcing
that foreground launch safety is not background reporter confinement. No model
filesystem/tool action appeared; this is not a native-tool denial proof. This
trial creates no Shikigami run, memory, delivery or background batch acceptance.

## Unattended Codex trial

At 2026-10-06 15:03 UTC, code revision `3280233`, process user `shinzui` ran the mounted public unattended
command from another disposable directory. Codex 0.160.1, requested model
`gpt-6.1-sol`, read-only operator ceiling outside the checkout, repository job
capability read-only, timeout 60 seconds, capture mode and output limit 32768 bytes.
All three API-key environment variables were absent. `agent show inspect` returned
source/ceiling diagnostics without executing the job; `agent run inspect` returned
`qualification-ep80-unattended` and exit 0 within the observed 36-second window and configured 60-second deadline. Captured
output was 462 bytes. The directory retained only its README and job config.

```sh
env -u ANTHROPIC_API_KEY -u OPENAI_API_KEY -u CODEX_API_KEY \
  /tmp/dist-newstyle/build/aarch64-osx/ghc-9.12.4/shikigami-agent-0.1.0.0/x/shikigami-agent-launch/build/shikigami-agent-launch/shikigami-agent-launch \
  unattended agent run inspect \
  --user-config /tmp/shikigami-ep80-operator-9q6cbcwd/agents.kdl \
  --config /tmp/shikigami-ep80-unattended-7zuzja0l/agents.kdl \
  --prompt 'Reply with qualification-ep80-unattended and do not inspect or change files.'
```

The actual public flag for repository scope is `--config`; an initial
`--repo-config` spelling was refused by the parser before any job started. The
runbook now uses the verified flag. This proves the mounted foreground named-job
path, with its owning Baikai runner and policy ceiling; it is not a background
response, served-model attestation, durable job, memory or delivery qualification.
