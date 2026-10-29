---
id: 100
slug: expose-governed-objective-inspection-through-the-api-and-cli
title: "Expose governed objective inspection through the API and CLI"
kind: exec-plan
created_at: 2026-10-29T00:19:50Z
intention: "intention_01m62265gjex4a0k54gsbwx4gs"
master_plan: "docs/masterplans/17-track-durable-objectives-and-authoritative-assignment-checkpoints-without-rei.md"
provenance:
  created_by:
    model: "claude-fable-5-1"
    harness: "claude-code"
    at: 2026-10-29T00:19:50Z
  reviews:
    - model: "gpt-6-astra"
      harness: "codex-cli"
      at: 2026-10-29T12:59:01Z
      verdict: "changes-requested"
      note: "API/CLI require EP-2-owned enablement and operator identity before their declared milestone gates; align dependency ownership."
  revisions:
    - model: "gpt-6-astra"
      harness: "codex-cli"
      at: 2026-10-29T13:05:53Z
      mode: "update"
      note: "Resolve configuration prerequisite ownership and stage conversation binding behind EP-2 milestone 1."
---

# Expose governed objective inspection through the API and CLI

This ExecPlan is a living document. The sections Progress, Surprises & Discoveries,
Decision Log, and Outcomes & Retrospective must be kept up to date as work proceeds.
If durable project context changes, update or create ADRs in docs/adr/ in the same change.
Record friction met while implementing in the friction-log bundle as it occurs (see FRICTION.md).


## Purpose / Big Picture

After this plan, an authenticated user can create an objective, list and inspect objectives they belong to, page through an objective's history and submit closed commands over HTTP, and an operator can do the same from the CLI as a separately recorded trusted identity. A caller who is not a member sees neither the objective nor its receipts. The same command owner from [plan 98](98-persist-authoritative-objectives-and-conditional-commands.md) serves both surfaces, so HTTP and CLI return identical domain outcomes. The observable result is the server contract suite and the hurl runner passing with two distinct authenticated callers, a revoked agent and an anonymous caller, including the trusted run-association cases from [plan 99](99-supply-trusted-objective-associations-and-the-real-checkpoint-ownership-and-scope-providers.md) exercised through the HTTP request path. This is EP-3 of [MasterPlan 17](../masterplans/17-track-durable-objectives-and-authoritative-assignment-checkpoints-without-rei.md).


## Progress

- [ ] Milestone 1: the `/objectives` vertical is mounted under the existing authenticated boundary with the `format: 1` command envelope, the documented status codes and regenerated OpenAPI; the API and client packages build and their contract tests pass.
- [ ] Milestone 2: `shikigami objectives create|inspect|history|command` call the same command owner as a recorded local operator identity, with bounded pagination and payload limits.
- [ ] Milestone 3: server contract tests with two callers, a revoked agent and an anonymous caller pass, including plan 99's run-association cases over HTTP, and `just hurl` passes with the new objective requests.

Planning baseline `3900c0e634d9b559e92a6989bb10f9943e0beab1`, inspected 2026-10-28. No implementation or test results are claimed. Hard prerequisite: plan 98 Complete; milestone 3 additionally requires plan 99 milestone 1.


## Surprises & Discoveries

(None yet.)


## Decision Log

- Decision: The public vertical is `/objectives`, and an A2A protocol task from IR-6 never shares an objective identity; a future A2A subtree mounts under its own base path.
  Rationale: MasterPlan 17 names the record `Objective` to match plans 84–87, UC-1 and the worker-session code; the standard A2A `/tasks/{id}` paths stay free.
  Date: 2026-10-28

- Decision: A local operator is a separately recorded trusted administrative identity loaded from configuration; CLI flags cannot impersonate an API caller or a recorded agent.
  Rationale: ADR 0047 separates authentication from resource authorization, and ADR 0033 keys authority by recorded principal. Operator access follows objective membership or explicit operator administration policy, never an agent identity supplied in a request.
  Date: 2026-10-28


## Outcomes & Retrospective

(To be filled during and after implementation.)


## Context and Orientation

An objective is a goal spanning executions, with a revision, instruction and criteria revisions, members with roles, assignments, evidence and receipts; plan 98 defines the record in `shikigami-core/src/Shikigami/Objective/Types.hs`, the closed public command sum in `Objective/Command.hs` (`ReviseInstructions`, `ReviseCriteria`, `SetAssignments`, `RecordProgress`, `RecordEvidence`, `SetNextAction`, `SetBlocked`, `ProposeCompletion`, `AcceptCompletion`, `CancelObjective`, `GrantMember`, `RevokeMember`, `BindConversation`, `LinkExternal`), authenticated command admission in `Objective/Capability.hs` with typed errors for missing, denied, conflict, invalid evidence, unavailable and unresolved outcomes, and the access-principal sum distinguishing a verified API caller, a recorded agent identity and a trusted local operator. Creation is its own operation keyed by authenticated creator and operation key. Plan 99 adds the optional objective/assignment reference to run requests in `shikigami-api/src/Shikigami/AgentRun/Api.hs` and the `BindConversation` behavior this plan exposes.

`shikigami-api/src/Shikigami/Api.hs` composes the public API; at the baseline it mounts only `health` and the authenticated `agents` vertical, and `shikigami-api/test/Main.hs` holds the OpenAPI contract tests. `shikigami-api/src/Shikigami/Caller/Api.hs` defines `ApiCaller` and `shikigami-server/src/Shikigami/Caller/Verifier.hs` the bearer verifier at the vertical mount, which represents one configured caller or anonymous access, not an issuer-backed directory; use a verifier fixture to test distinct callers. `shikigami-server/src/Shikigami/Server/App.hs` mounts verticals; `shikigami-server/src/Shikigami/AgentRun/Handler.hs` and `shikigami-api/src/Shikigami/Agent/Api.hs` are the shape to follow. `shikigami-client/src/Shikigami/Client.hs` is the typed client and `shikigami-server/src/Shikigami/Server/Command.hs` the operator CLI parser; `shikigami-server/src/Shikigami/Server/Command/Workers.hs` shows an existing command group. `tests/hurl/` holds the HTTP runner (`run.sh`, which honors `SHIKIGAMI_CABAL_PROJECT`, and per-vertical `.hurl` files); `just hurl` runs it. `docs/operations/operator-cli.md` documents operator commands.

Relevant decisions: [ADR 0047](../adr/0047-public-api-authentication-is-a-verifier-at-the-vertical-mount.md) places authentication at the vertical mount and leaves resource authorization to the handler; [ADR 0033](../adr/0033-recorded-agent-principals-key-durable-state.md) keys authority by recorded principal; [ADR 0025](../adr/0025-capability-overlays-are-requests-for-additive-model-tools.md) and [ADR 0066](../adr/0066-worker-commands-require-retained-scopes-and-fresh-exact-authority.md) establish that a name or supplied identity confers no authority. No ADR governs public resource paths; MasterPlan 17 reserves `/objectives` here and the A2A base path elsewhere.


The reviewed contracts are recorded in [ADR 0067](../adr/0067-objective-checkpoints-use-assignment-scoped-preconditions.md) (checkpoint preconditions and instruction invalidation) and [ADR 0068](../adr/0068-objective-creation-has-authority-before-association.md) (creation authority before association). These are accepted design decisions; implementation and acceptance evidence remain outstanding.

## Plan of Work

Plan 98 owns and delivers shared enablement, local operator identity and creation policy before this plan starts. Milestones 1–2 use that configuration and the objective store directly; they do not require plan 99’s worker providers. `BindConversation` is declared in the public schema in milestone 1 but remains explicitly unavailable until plan 99 milestone 1 supplies its validator; milestone 3 must test that real behavior as well as run associations.

### Milestone 1 — The authenticated objective vertical

Add `shikigami-api/src/Shikigami/Objective/Api.hs` and `shikigami-server/src/Shikigami/Objective/Handler.hs`; extend `shikigami-api/src/Shikigami/Api.hs`, `shikigami-server/src/Shikigami/Server/App.hs`, `shikigami-client/src/Shikigami/Client.hs` and the OpenAPI generation and its tests in `shikigami-api/test/Main.hs`. Mount the vertical under the existing authenticated boundary. Offer `POST /objectives`, `GET /objectives`, `GET /objectives/:objectiveId`, `GET /objectives/:objectiveId/history` and `POST /objectives/:objectiveId/commands`. Command bodies carry `format: 1`, `operationKey`, `expectedRevision` and `command`, whose discriminant is `tag` and whose tags are plan 98's public sum; creation is its own endpoint. Return 201 for creation, 200 for identical replay, reads and accepted commands, 409 for a stale version or key mismatch, 413 for oversize payloads and 503 for store unavailability. Missing and inaccessible objectives both read as 404; an authenticated user lacking a permitted operation receives a bounded 403. Apply authorization to list, history and payload reads as well as writes, and never let a replay receipt lookup bypass authentication or current permission. Public metadata must not include instructions, tokens, hidden model context or unrestricted result bodies. Missing or unknown codec versions fail explicitly. Write exact JSON examples and schema tests together with the types. Milestone 1 is accepted when the API, client and server packages build, the OpenAPI contract tests pass with the new routes, and the status-code matrix is covered by handler tests against the plan 98 store.

### Milestone 2 — Operator CLI over the same owner

Add `shikigami-server/src/Shikigami/Server/Command/Objectives.hs` and extend `shikigami-server/src/Shikigami/Server/Command.hs` with `shikigami objectives create --operation-key KEY --file FILE --json`, `objectives inspect OBJECTIVE --json`, `objectives history OBJECTIVE --after CURSOR --limit N --json` and `objectives command OBJECTIVE --operation-key KEY --expected-revision N --file FILE --json`. These call the same command owner. The local operator is a separately recorded trusted administrative identity loaded from configuration; flags cannot impersonate an API caller or a recorded agent, and operator access follows objective membership or explicit operator administration policy. Default pages to 20 and cap at 100; bound command payloads to 1 MiB and model replies to 16 KiB; store large evidence behind protected references read with explicit pagination; order by stable revision or cursor, not timestamps alone. Milestone 2 is accepted when each command round-trips against a disposable database, CLI and HTTP return the same domain outcome for the same command, and `cabal run shikigami -- objectives --help` lists the four commands.

### Milestone 3 — Server contract with distinct callers

Add server contract tests with two distinct authenticated callers, a revoked agent and an anonymous caller, and exercise plan 99's run-association cases through the HTTP request path: a permitted association on a run request commits with acceptance and queue send, a forged objective reference in trigger text and an unauthorized association enqueue nothing, and an old unassociated request keeps its original fingerprint and codec path. Verify caller A can create, inspect, revise and submit associated runs, caller B and an ungranted agent cannot read, list, mutate or attach, revocation affects fresh operations and protected reads, and existing anonymous or unassociated run functionality is intact while objective access stays denied by default. Add `tests/hurl/objectives.hurl` covering creation, replay, inspect, history paging and a stale-revision conflict. Milestone 3 is accepted when the server suite and `just hurl` pass.


## Concrete Steps

Run commands from the repository root, `/Users/shinzui/Keikaku/bokuno/shikigami`, inside `nix develop --no-write-lock-file` if needed. Capture `git rev-parse HEAD` as the implementation baseline and confirm the build:

```bash
cabal build all
```

If the checked-in project cannot resolve its co-developed dependencies, follow `docs/dependency-cohort.md` and plan 98's local-project convention consistently, and set `SHIKIGAMI_CABAL_PROJECT=.dev/mp13.cabal.project` for the hurl runner, which `tests/hurl/run.sh` already supports. Run focused checks while implementing and the affected suites at each boundary:

```bash
cabal test shikigami-api-test shikigami-server-test --test-show-details=direct --test-options='--num-threads=1'
just hurl
cabal run shikigami -- objectives --help
```

The help output must list `create`, `inspect`, `history` and `command`. At a coherent commit, run the gate against the saved baseline (this plan declares no workflow change, so the report must be replay-neutral) and check whitespace:

```bash
just keiro-gate IMPLEMENTATION_BASELINE
just user-docs-validate
git diff --check
```

Every commit follows Conventional Commits and ends with:

```text
MasterPlan: docs/masterplans/17-track-durable-objectives-and-authoritative-assignment-checkpoints-without-rei.md
ExecPlan: docs/plans/100-expose-governed-objective-inspection-through-the-api-and-cli.md
Intention: intention_01m62265gjex4a0k54gsbwx4gs
```


## Validation and Acceptance

Governed use through supported entry points: caller A can inspect its objective; caller B and an ungranted agent cannot read, list, mutate or attach it. Revocation affects fresh operations and protected reads. Replay receipt lookup never bypasses authentication or current permission. Existing anonymous and unassociated run functionality remains intact while objective access remains denied by default. CLI and HTTP commands return the same domain outcomes, pagination is bounded, and oversize payloads are refused with 413. Required acceptance is the passing API and server suites, the hurl runner and the CLI help transcript. Record actual passing counts only after running them.


## Idempotence and Recovery

A retried `POST /objectives` or command with the same operation key and bytes returns the original receipt and 200; a changed body under the same key returns 409. Reads are side-effect free. The vertical adds no migration and no workflow change; rolling it back is removing the mount. Disabling objective tracking in operator configuration must make the vertical refuse with 503, not fall back to an unauthenticated path.


## Interfaces and Dependencies

Hard prerequisite: plan 98 Complete; milestone 3 additionally requires plan 99 milestone 1 (the optional objective reference on run requests and `BindConversation`). `Shikigami.Objective.Api` owns the HTTP contract and envelope; `Shikigami.Objective.Handler` and `Shikigami.Server.Command.Objectives` are adapters over `Shikigami.Objective.Capability`; neither adds a second executor or authorization order. Plan 102 drives these endpoints and commands from its fixture. Dependencies and cohort are unchanged; the API uses the existing Servant and OpenAPI stack already in `shikigami-api`. Locate any further dependency API through Mori and read its source before use.


## Revision Notes

2026-10-29: Clarified that plan 98 supplies shared configuration; retained plan 99 milestone 1 only for association behavior and its acceptance.
