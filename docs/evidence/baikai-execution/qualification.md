# Baikai execution qualification — 2026-10-06

The HTTP and foreground implementation is qualified independently of batch CLI
promotion. The exact source revision and immutable package checks are recorded
below as they finish. No live background reporter or service readiness is claimed.

## Released contracts and deterministic checks

- Mori, Hackage preferred versions and upstream release tags agree on core
  0.7.2.0, Claude/OpenAI 0.7.1.0 and agent 0.2.0.1; see [contracts](contracts.md).
- An isolated relocation of the committed descriptor (initially the working
  descriptor before checkpoint) excludes ignored `cabal.project.local` overrides.
  `cabal build all --enable-tests` passes. The frozen solve changes only core,
  Claude and OpenAI versions; agent 0.2.0.1, kdl-hs 1.1.1 and settei-kdl 0.2.0.0
  are added. Export: 357 runtime packages and five immutable repositories.
- Core: 421 checks pass. Includes conditional credentials, catalog/API model
  decoding, typed option ranges, secret redaction, real local Chat/Responses HTTP
  wire fixtures, released fake CLI decoding/error paths and cancellation probes.
  The Responses fixture initially lacked the required message item id; corrected
  fixture passes without changing the adapter.
- Agent: 37 checks pass, including terminal-independent fake attended flags/cwd/
  exit 7, pure diagnostics, mounted/native command agreement, executed unattended
  exit 7, operator ceiling refusal and repository policy escalation refusal.
  An initial operator fixture inside the checkout was correctly refused; moving
  it to a separate directory gives the intended trusted-policy test.
- Worker: 88; server: 47; PostgreSQL core: 197; migration smoke: 8 checks pass.
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

Pending final committed-source checks. The first `just keiro-gate` trial passed
language checking and inspection, but its scaffold recipe treats *any* uncommitted
handwritten core source as drift. No generated source changed. Repeat after the
implementation checkpoint, retaining the repository gate unchanged.

## Live coverage

| Surface | Coverage |
| --- | --- |
| Anthropic Messages HTTP | Deterministic legacy/config coverage; live untested |
| OpenAI Chat Completions HTTP | Local HTTP/SSE fixture; live untested |
| OpenAI Responses HTTP | Local HTTP/SSE fixture; live untested |
| Claude batch response | Fake decoding/error and negative cancellation probe; live blocked |
| Codex batch response | Fake decoding/error and negative cancellation probe; live blocked |
| Attended terminal | Fake flag/cwd/exit evidence; real trial pending |
| Unattended named jobs | Public native/mounted parser, fake exit and ceiling evidence; live untested |

A foreground process exit is not a durable model response or served-model identity.
No login files, provider credentials or private prompts are captured here.
