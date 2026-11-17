---
id: 135
slug: move-the-kikan-service-bindings-out-of-shikigami-core-and-compose-a-kikan-distribution
title: "Move the Kikan service bindings out of shikigami-core and compose a Kikan distribution"
kind: exec-plan
created_at: 2026-11-15T14:37:16Z
intention: "intention_01m7fq4tf3ejrt0tjxvsy8ejdt"
master_plan: "docs/masterplans/22-rebuild-shikigami-as-a-kernel-where-use-cases-are-declared-not-coded.md"
provenance:
  created_by:
    model: "claude-fable-5-2"
    harness: "claude-code"
    at: 2026-11-15T14:37:16Z
  revisions:
    - model: "claude-fable-5-2"
      harness: "claude-code"
      at: 2026-11-15T14:45:36Z
      mode: "other"
      note: "Drafted plan body under MasterPlan 22"
    - model: "claude-fable-5-2"
      harness: "claude-code"
      at: 2026-11-15T15:01:14Z
      mode: "update"
      note: "Adaptive-delivery coordinator stays in the kernel (user decision 2026-11-15)"
    - model: "claude-fable-5-2"
      harness: "claude-code"
      at: 2026-11-15T15:08:44Z
      mode: "update"
      note: "Distribution default output kawa.digest; no change to first-freeze surfaces (user decisions 2026-11-15)"
    - model: "claude-opus-5-5"
      harness: "claude-code"
      at: 2026-11-17T05:37:04Z
      mode: "implement"
      note: "M1 implemented: binding package, distribution composition, flows pack lines, inventory"
    - model: "claude-opus-5-5"
      harness: "claude-code"
      at: 2026-11-17T17:46:08Z
      mode: "implement"
      note: "M3 implemented: outputs, approval channels, settings and stubs run from the binding and distribution; acceptance recorded"
---

# Move the Kikan service bindings out of shikigami-core and compose a Kikan distribution

This ExecPlan is a living document. The sections Progress, Surprises & Discoveries,
Decision Log, and Outcomes & Retrospective must be kept up to date as work proceeds.
If durable project context changes, update or create ADRs in docs/adr/ in the same change.
Record friction met while implementing in the friction-log bundle as it occurs (see FRICTION.md).


## Purpose / Big Picture

Shikigami is the agent runtime at the centre of the Kikan platform. Today its core package,
`shikigami-core`, links the client libraries of five Kikan services and compiles their wire
shapes into its own types. An operator who wants to run one agent on their own Mac still
builds, and is constrained by, the organization's clients. An organization that wants to
change how it talks to one of its services has to change the kernel.

After this plan there are two ways to compose the same kernel, and both are real programs.
The *stock composition* is the seven `shikigami-*` packages. It links no Kikan client library
and serves one operator with local adapters. The *Kikan distribution* is a separate package,
`kikan-shikigami`, whose executables compose the kernel with a *binding package*,
`kikan-shikigami-binding`, and with the organizational flow packs. The binding holds every
piece of code that knows a Kikan service: the Kikan-En authority adapter, the output
adapters for Kawa, Kizashi, Rei, Danwa and channel egress, the Danwa and Kizashi approval
channels, the Danwa conversation loop, the Rei tracker provider and the Kawa stream and
event intake. Every Kikan feature that works today keeps working, from the distribution's
executables instead of the stock ones.

You can see it working three ways. `cabal build shikigami-core` succeeds with no `danwa-*`,
`kikan-en-*`, `rei-api-*` or `shomei-*` package in its build plan, and a test fails if one
returns. One declaration that uses only kernel vocabulary runs unchanged under
`shikigami-agent-run` and under `kikan-shikigami-agent-run`, and the two action records
differ only in who decided. And a declared agent that raises a Kizashi signal, writes a Kawa
digest or updates a Rei intention does so through the distribution's worker against the real
service where one runs on this Mac.


## Progress

- [x] M1: The binding and distribution packages exist and build. `kikan-shikigami-binding`
  depends only on `shikigami-core:flow-sdk` and `shikigami-core:pack-sdk`; the fitness check
  knows both packages; `kikan-shikigami flows` lists the composed packs. The local service
  inventory is recorded with what actually starts on this Mac. (2026-11-17: `cabal build
  kikan-shikigami-binding kikan-shikigami` succeeds; `kikan-shikigami flows` prints
  `kikan-binding    no contributions` under `packs:` and `shikigami flows` does not list it;
  the kernel boundary case "the Kikan binding is held to the SDK, and no stock package
  depends on it" refuses a binding that depends on `shikigami-workers` or `kafka-effectful`
  and a stock executable that depends on the binding; 19/19 of `package architecture` and
  `kernel boundary` pass. The inventory below is read-only; starting a sibling's stack is
  deferred to the milestone that needs it, with the user's approval.)
- [x] M2: The Kikan-En authority adapter runs from the binding. `shikigami-core` no longer
  imports `Kikan.En.*` or `Shomei.*`, the `kawaSource` field is gone from the authority
  port, and a distribution worker authorizes a real action against a locally started
  Kikan-En and Shomei, or the recorded fallback is used. (2026-11-17: fallback used, since
  the user chose no sibling stacks. `Kikan.Shikigami.Binding.Authority` registers `kikan`;
  0 stock modules import `Kikan.En` or `Shomei` (15 -> 3 files for all four Kikan roots;
  17 -> 10 Kikan dependency lines in `shikigami-core.cabal`). `kikan-shikigami-worker`
  ran `agents/proof/portable-note.dhall` (stub behavior provider) against the loopback
  fixture authority and `stub-kawa`: the record holds `run.admitted` (outputs `kawa.digest`,
  composition default), `authority.decided emit_output` with `decidedBy: service:kikan-en`,
  `output.delivered` and `run.finished`, and `kikan-shikigami record check` reports
  K1 K2/K3 K4 K5 K6 K8 hold. The stock `shikigami-worker` refuses `mode=kikan` at start
  naming `kikan-shikigami-worker`, and refuses the Kikan-En keys as unknown (exit 4).
  Binding tests 11/11 including `toAgentAction` over every `Action` constructor; core
  866/866; workers 301/301 with the known Git-provider load flake passing alone; server
  108/108; distribution 10/10. `just keiro-gate HEAD~1` after d74b7efa: conformance PASS,
  no workflow body change. The Kikan-En gap is filed, by the user's decision, as
  `mori://shinzui/kikan-en/improvement-requests/IR-5` (kikan-en commit 045171f, "Authorize
  a coding-agent launch per action"; not pushed).)
- [x] M3: The five output adapters and the two approval channels run from the binding, and
  the distribution registers `kawa.digest` as its default output. A declared agent's outputs
  reach their services through the distribution worker, a declaration with no outputs gets a
  Kawa digest, and the stock composition refuses a declaration naming a Kikan output kind at
  load. (2026-11-17: stage a `dda65c61`, stage c `269a7355`, stages b, d and e `ee48e978`.
  Acceptance, through `kikan-shikigami-worker` on a disposable PostgreSQL with the loopback
  fixture authority and the distribution's stubs: a declaration with no `outputs`
  (`default-digest`, validated as `outputs: kawa.digest (composition default)`) produced
  exactly one envelope at `kikan-shikigami stub-kawa` and a `delivered` receipt carrying its
  `act_` id; an explicit `channel.egress` was accepted by `stub-kanmon` with a `delivered`
  receipt; an explicit `rei.action` produced no Kawa envelope and a visible `failed` receipt
  ("no rei endpoint is configured"), retried on each publish pass. Every delivery was
  authorized twice, at enqueue and at publish (`dispatch_kawa`, `dispatch_channel`,
  `act_on_intention`, decided by the fixture's Kikan-En). The stock `shikigami validate
  agents/triage-note.dhall` fails with "output kind kizashi.signal is not registered here
  (registered: local.report)". Gaps, named: Kizashi and Danwa ran against their client
  tests only (the binding's `OutputDispatchSpec` and `ApprovalNotificationSpec`), since the
  user chose no sibling stacks; `rei.action` cannot run against a real Rei, because Rei
  exposes no ingestion endpoint for it (its v2 API serves the tracker, M4); the receipts were
  checked for kind and status, not compared byte for byte with a pre-move run. Suites: core
  unit 809/809 and postgres 549/549, binding 65/65, distribution 42/42, workers 301 with the
  known Git flake passing alone, server 97/97, agent 42, api 35, client 9, migrations 9 and
  11, packs 14, 120, 79 and 115; kernel fitness, conventions, capabilities and api-baseline
  clean; `just keiro-gate HEAD~1` after `ee48e978`: conformance PASS, every generated module
  unchanged.)
- [x] M4: The Rei tracker provider runs from the binding and passes the existing real-Rei
  qualification. Provider-neutral tracker code stays in the kernel. (2026-11-17: code
  `6268f9bf`. `Shikigami.Objective.Tracker.Runtime` is provider-neutral and opens each
  connection through the `TrackerProviderRegistration` its revision names;
  `Kikan.Shikigami.Binding.Tracker.Rei` installs `rei-v2-objectives/1`; `rei-api-client` and
  `rei-api-contract` appear only in `kikan-shikigami-binding.cabal`. Real-Rei acceptance from
  the binding: `bash tests/objective-trackers/run-rei.sh` with `SHIKIGAMI_REI_SOURCE` set to
  a separate clone at the pinned Rei commit `c109222` (the operator's own checkout was left
  where it was) ran `kikan-shikigami-binding:test:kikan-shikigami-binding-rei-test`: "All 17
  tests passed", disposable Rei 8.0.0.0, typed contract 0.2.0.0, loopback only. Suites: core
  unit 809/809 and postgres 549/549, binding 65/65, distribution 42/42, server 97/97, kernel
  fitness 9/9, conventions clean. `just keiro-gate 85d1cb75` (the commit before M4):
  conformance PASS, every generated module unchanged, no workflow body change;
  `just api-baseline`: 8 surfaces clean.)
- [ ] M5: The Danwa conversation loop and the Kawa stream and event intake run from the
  distribution's executables. The stock role set no longer contains a consumer.
- [ ] M6: `shikigami-core` and the other six packages link no Kikan client library and the
  fitness check enforces it. The action record is projected into run evidence. The
  portability check passes against the Kikan distribution, with the default output resolved
  to `local.report` in one run and `kawa.digest` in the other. The ADR and the requirement
  mapping are published.


## Surprises & Discoveries

These came from read-only research on 2026-11-15, before implementation.

- Observation: No Meibo client exists. The MasterPlan speaks of "the Meibo directory source
  in the binding", but the directory has two modes, `disabled` and `file`, and
  `MeiboClientSource` is only an attribution label on a directory snapshot.
  Evidence: `DirectoryMode = DisableDirectory | ReadDirectoryFile` in
  `shikigami-core/src/Shikigami/App/Config.hs` (line 919), and `DirectorySourceKind` in
  `shikigami-core/src/Shikigami/Directory.hs` (lines 158 to 161). No module imports a Meibo
  library. See the Decision Log for what this plan does about it.
- Observation: Kikan-En's action type reaches well beyond the authorizer. Five core
  capability modules and two worker modules build `AgentAction` values directly.
  Evidence: `Kikan.En.Action` is imported by `Capability/Provider.hs`, `Objective/Capability.hs`,
  `Objective/Runtime.hs`, `WorkerSession/Capability.hs` and `Workspace/Provider.hs` in
  `shikigami-core`, and by `Workspace/GitProvider.hs` and `Workspace/Cleanup.hs` in
  `shikigami-workers`. Replacing these is EP-8 M1's work and a prerequisite here.
- Observation: The stock role set includes two consumers that exist only to read Kikan's
  streams, and `shikigami-workers` and `shikigami-server` link Kafka for them.
  Evidence: `executable shikigami-consume-stream` and `executable shikigami-consume-events`
  in `shikigami-workers/shikigami-workers.cabal`; `hw-kafka-client` and `kafka-effectful` in
  both packages' dependencies; `shikigami-workers/src/Shikigami/Trigger/Consumer.hs` is 818
  lines.
- Observation: The bundled `process-compose.yaml` starts PostgreSQL only. Every other
  service is either a sibling repository's own stack or a stub inside `shikigami-server`.
  Evidence: `process-compose.yaml` lists `postgres`, `create_schema` and `sanity_check`.
  `docs/capabilities/local-integration-fixtures.md` states that `stub-kawa` and
  `stub-kanmon` "are development fixtures, not production replacements".


- Observation: (M1 inventory, 2026-11-17, read-only.) No sibling repository's
  `process-compose.yaml` starts its service. Each starts only its own PostgreSQL on a Unix
  socket under the repository (`pg_ctl start ... -c listen_addresses=''`) and runs
  `just create-database`; Kawa's also starts ClickHouse. The service itself is a separate
  executable. Built servers found under each checkout's `dist-newstyle`: Shomei
  (`shomei-server`, `shomei-migrate`), Kawa (`kawa-server`, `kawa-read-server`,
  `kawa-migrate`), Kizashi (`kizashi`, `kizashi-migrate`), Danwa (`danwa-server`,
  `danwa-worker`, `danwa-migrate`) and Rei (`rei-api`, `rei-migrations`). Kikan-En
  (`just start-server`), Kanmon and Meibo have no build. The global Redpanda answers at
  `127.0.0.1:9092` (`rpk cluster info`). So a real run is possible for Rei (this repository's
  `tests/objective-trackers/run-rei.sh`), and plausible for Shomei, Kawa, Kizashi and Danwa
  once each one's database is created and migrated; Kikan-En needs a build first, and the
  M2 acceptance falls back to the loopback fixture authority
  (`tests/objective-tracking/fixture`) unless it is built.
  Evidence: `find <checkout>/dist-newstyle/build -path '*/x/*' -perm -u+x` per service;
  `grep command: <checkout>/process-compose.yaml`.

- Observation: Declared tools already reach Kikan-En. The kernel `Action` has no
  `RunDeclaredTool` constructor: a declared tool is `UseCapability (InvokeTool ...)` and maps
  to `invoke_capability_tool`. Only `LaunchCodingAgent` has no Kikan-En action. Kikan-En
  already carries IR-3 (MCP tool invocation) and IR-4 (`run_external_job`), and none for a
  coding-agent launch.
  Evidence: `toAgentAction` in `packs/kikan-shikigami-binding/src/Kikan/Shikigami/Binding/Authority.hs`;
  `ls $(mori path mori://shinzui/kikan-en)/docs/improvement-requests`.

- Observation: (M3 inventory, 2026-11-17) What depends on the closed `Sink` union, the
  map stage (a) and (c) work from. Definition: `Agent/Decl.hs` (`data Sink`, derived
  `FromDhall`/JSON; `sinks :: [Sink]`) and `schema/Agent.dhall` (`Sink` union, `sinks`
  field and default). Kernel pattern matches: `Sink.hs` (`sinkKindOf`, `runSink`),
  `Sink/Authorization.hs` (`sinkOutputKind`, `sinkAction` targets), `Sink/Intent.hs`
  (`SinkIntent.sink`, `egressMetadata`), `Sink/Recipient.hs`, `Sink/Validate.hs`,
  `Sink/Types.hs` (`AddressedSignal.sink`), `Flow/Capability.hs` (`EmitSignal*` effect),
  `Flow/Sdk.hs` (re-exports `Sink (..)`), `Agent/Workflow.hs` (`approveSinks`, sink kind in
  approval keys `sink-<Kind>-<n>`, spans and logs), `Agent/Conversation.hs:1489` (a
  hard-coded `DanwaConversation` reply sink). Readers of `decl.sinks`: `Agent/Workflow.hs`,
  `Sink/Validate.hs` via `shikigami-server/.../Command/Validate.hs`, `Coordination/Direct.hs`
  (`null declaration.sinks`), `shikigami-agent/.../Agent/Trust.hs` (`sinkKindNames`, the
  light tier's `OutputsUnavailable` refusal), and `shikigami-server/.../Agent/Handler.hs`
  feeding `shikigami-api/.../Agent/Api.hs` `sinks :: [Text]` (snake_case) printed by
  `shikigami-client/.../Client/Command.hs`. Packs that build `Sink` values: examples
  `AtRiskCustomer`, initiative `Notice`, practice-review `OpenTelemetryReview` and
  `Attention`, watchdog `Settings` (`operatorSink`, `conversationSink`). `SinkKind` users:
  `Agent/Approval.hs` (`approval.require` parses PascalCase names), `App/Config.hs`
  (`approvalRequiredSinks`), `Sink/Delivery.hs` (`sink_deliveries.sink_kind`),
  `Sink/GrantStore.hs` and `shikigami-server/.../Command/Grants.hs` (`sink_grants`),
  `Workers/Command/Worker.hs`, `Agent/Command/AgentRun.hs`. Stored legacy names: migrations
  `0003-sink-grants.sql` (CHECK and seed rows), `0008-sink-deliveries.sql`,
  `0011-agent-principal-state.sql` (indexes), `shikigami-migrations/expected-schema.txt`,
  `api-baseline/goldens/exports/flow-sdk.txt`, `shikigami-core/test/fixtures/wire/agent-decl-v1.json`,
  `config/shikigami.example.yaml`, `tests/cli/contracts.py`. Declarations with non-empty
  sinks: `agents/{heartbeat,danwa-heartbeat,triage-note}.dhall`,
  `agents/proof/{heartbeat,channel-reply}.dhall`,
  `packs/flow-pack-examples/agents/qualification-at-risk-customer.dhall`,
  `tests/hurl/agents/disabled-heartbeat.dhall`,
  `fixtures/qualification/agents/service-health-{observer,reporter}.dhall`; nine more
  declare `sinks = []`. About 45 test files construct sinks or kinds (largest:
  `AppConfigSpec` 36, `SinkDeliverySpec` 30, `SinkHonestySpec` 14, `AgentWorkflowSpec` 13).
  The five kinds are spelled three ways today: PascalCase (`SinkKind`, the database,
  `approval.require`), dotted (`sinkOutputKind`, `Trust.sinkKindNames`) and snake_case
  (the HTTP API); after M3 only the dotted output kind remains.
  Evidence: an Explore-agent inventory of the working tree at 177d9b4e.

- Observation: (M3 acceptance) `shikigami grants grant` and `revoke` never returned under a
  file directory: they ran the directory's periodic refresh loop as `finally` cleanup, the
  defect the admin context had already fixed for `principalActive`. A one-shot verb now uses
  the snapshot `startDirectory` loads and never runs the refresher.
  Evidence: the acceptance hung on `kikan-shikigami grants grant default-digest
  kawa.digest` with `directory.mode=file`; `Shikigami.Server.Command.Grants`.
- Observation: (M3 acceptance) The development shell exports `PG_CONNECTION_STRING`, and the
  environment outranks `--config`, so a disposable run must clear it or it reaches the
  development database. The first attempt stopped at migration verification there (the
  development database lacks `0052`) before any write.
- Observation: (M3) `tests/objective-tracking/continuity.py` still drives the stock
  `shikigami-worker` with `authorization.actions.mode=kikan`, which the stock worker has
  refused since M2, and its fixture agents grant `danwa.conversation`, which only the
  distribution registers since M3. The script must run the distribution's executables; M5,
  which moves the conversation loop, is where it is next run.
- Observation: (M3 acceptance, unrelated to this plan) The worker's timer loop logs
  `scheduler.timer.unknown_kind` for Kioku's L1 distillation timers (kind `final`, and one
  with no kind), which `Kioku.Distill.Timer` writes and no Shikigami action claims.
  Evidence: two such lines per finished run in the acceptance worker log;
  `mori://shinzui/kioku` `kioku-core/src/Kioku/Distill/Timer.hs` line 128 (artifact URI
  pending).
  Planned in `docs/plans/137-settle-kioku-distillation-timers-through-kioku-s-fire-api-in-the-shared-timer-dispatcher.md`.

## Decision Log

- Decision: The binding is one package, `kikan-shikigami-binding`, with modules under
  `Kikan.Shikigami.Binding.*`, in `packs/kikan-shikigami-binding/`. The distribution is
  `kikan-shikigami` in `packs/kikan-shikigami/`.
  Rationale: The MasterPlan names both. One binding package keeps one dependency rule to
  check. The bindings share the HTTP environment and credential loading in
  `Shikigami.Sink.Http`, so splitting per service would duplicate it. Neither name starts
  with `shikigami-`, so the frozen Nix closure of ADR-39 does not see them.
  Date: 2026-11-15
- Decision: The Kikan distribution's default output is `kawa.digest`. A declaration with no
  `outputs` that runs under the distribution emits one Kawa digest of its result; an explicit
  `outputs` list always wins.
  Rationale: The user decided on 2026-11-15 to "use composition default output". EP-8 owns
  the mechanism (`DefaultOutput` on the `OutputRegistry`, resolved at admission and pinned
  in the journal). Kawa is the right default because Kikan's C3 contract is "every action is
  remembered": a run that names no destination should still leave a digest in the
  organization's stream. It also makes a routine agent written for the stock composition
  load here unchanged.
  Date: 2026-11-15
- Decision: This plan changes no surface frozen by EP-11's first freeze, the declaration
  baseline. The Kikan output helper files and the declarations that use them may still
  move, because they freeze second.
  Rationale: The user decided on 2026-11-15 to "freeze in two steps". The first freeze
  covers `schema/Agent.dhall`, the `AgentDecl` journal codec, the playbook format, the
  operator files, the `local.report` helper and the stock local-work CLI
  (`shikigami-agent-run`, `shikigami-local`, `shikigami-tools`, `shikigami playbook`). It may
  land before or during this plan. This plan's moves touch the durable wire, the SDK, the
  ports and the admin and distribution executables, all of which freeze second. Checked
  against the plan: it does not change the `outputs` JSON shape in `AgentDecl`, the
  `Trigger` union (the `Stream` and `Event` arms stay in the schema; only their intake
  moves) or any stock local-work command. One thing does need care: M3 moves
  `agents/heartbeat.dhall`, `agents/danwa-heartbeat.dhall` and `agents/triage-note.dhall`
  and the Kikan helper file, so those three declarations must not be in the first freeze's
  corpus. EP-11 keeps declarations that name a Kikan output, or a flow that leaves the core,
  in the second freeze's corpus.
  Date: 2026-11-15
- Decision: This plan moves no Meibo client, because none exists. The directory port and its
  file source stay in the kernel. The label `MeiboClientSource` stays a recognized
  attribution value so that stored snapshots keep decoding. A Meibo client source is future
  work in the binding and is listed as deferred in the requirement mapping.
  Rationale: ADR-1 forbids declaring what the runtime does not execute. The file projection
  is how a principal's lifecycle reaches Shikigami today, and it is service-neutral.
  Date: 2026-11-15
- Decision: The `kawaSource` field leaves the authority port. The Kawa output adapter owns
  its source segment as adapter configuration and names it in the `EmitOutput` target it
  asks the authority to decide.
  Rationale: The field exists only so that `Shikigami.Sink.Authorization.sinkAction` can
  build a `DispatchKawa` target. A port that every composition implements must not carry
  one service's configuration.
  Date: 2026-11-15
- Decision: Settings move with their owner and keep their keys. The binding declares the
  `sinks.*`, `authorization.actions.kikan_en.*`, `authorization.actions.shomei.*` and
  `authorization.actions.en.*` settings through the pack's setting decoders (the `FlowPack`
  field EP-6 lands). `authorization.actions.mode` stays a kernel key; the value `kikan` is
  accepted only when a composed binding registers an authority under that name.
  Rationale: An operator's existing configuration file must keep working with the
  distribution's executables. The stock composition should fail at startup, with a message
  naming the distribution, when given a Kikan setting it cannot honour.
  Date: 2026-11-15
- Decision: SQL migrations stay in `shikigami-migrations`. `docs/architecture/packages.md`
  records which tables the binding owns.
  Rationale: Migrations form one ordered, locked chain for one schema. The pre-release
  exception never authorizes database deletion (`docs/workflow-versioning.md`).
  Date: 2026-11-15
- Decision: The stream and event consumers become distribution executables, and the two
  stock consumer executables are removed.
  Rationale: Both consume Kikan's `activity.v1` stream and integration topics and nothing
  else. Under the MasterPlan, stream and event intake from Kawa is a Kikan binding. This
  changes the stock role set, so it is the last move and is recorded in the ADR. See "What
  the deployed roles lose" in Plan of Work.
  Date: 2026-11-15
- Decision: The binding is a plain `FlowPack` value, `kikanBinding`, not an
  `IO FlowPack` built from a `KikanBindingConfig`. A registration that needs settings (the
  authority, the output adapters) carries a builder that takes the validated
  `PackSettings`, the way a `PackGauge` already does, so every role entry point keeps
  taking `[FlowPack]` and no `PackSource` is introduced.
  Rationale: EP-5 and EP-6 landed only `[FlowPack]`, and pack settings are validated by the
  executable's configuration loader before anything runs. A pure value also lets
  `kikan-shikigami flows` and `validate` list the binding without loading configuration.
  Date: 2026-11-17
- Decision: `kikan-shikigami-server` is added when a milestone gives it something to
  compose (M4, when the server's tracker runtime takes providers from packs), not in M1.
  `shikigami-server` has no `...With` entry point and nothing in the binding needs it yet.
  Rationale: ADR-1; an executable identical to the stock one proves nothing.
  Date: 2026-11-17
- Decision: `flows` gains a `packs:` block, one line per composed pack listing what it
  contributes (flows, programs, tasks, settings, verbs, gauges, and the binding's
  registrations as they land). A pack with no flow, such as the binding, otherwise never
  appears. This changes `shikigami flows` output, a second-freeze admin surface.
  Date: 2026-11-17
- Decision: (M2) The kernel selects an authority by name from what the composed packs
  register. `FlowPack` gains `authorities :: [AuthorityAdapter]`
  (`Shikigami.Authority.Adapter`: a `mode` and a `build :: AuthorityContext -> IO (Either
  Text Authority)`), `composeFlowRegistry` refuses two packs that register one mode, and
  `Shikigami.Authority.Configured.buildConfiguredAuthority` takes the adapters.
  `ActionAuthorizationConfig` becomes `ActionAuthorizationDisabled | ActionAuthorizationBy
  Text`; `authorization.actions.mode` stays a kernel key and accepts `disabled` or a
  lowercase name. The seven Kikan-En keys are the binding's pack settings with the same keys
  and environment variables. This extends EP-5's `FlowPack`; no parallel type.
  Rationale: the plan's "registry of authorities by name", with the binding a plain value
  (see the M1 decision).
  Date: 2026-11-17
- Decision: (M2) Pack settings gain a secret shape, `SecretTextSetting`. Its value is
  stored apart in `PackSettings` (whose `Show` prints only the key), is never returned by
  `packSettingValue`, has no default and no renderer, and is read with
  `packSettingSecret`/`revealPackSecret`. `Shikigami.Pack.Sdk` exports the three names.
  Rationale: the Shomei client secret had to move with its owner, and a public pack setting
  would have printed it in `--explain-config`. The core test "a secret pack setting is
  readable by its pack and never displayed" plants a token and checks every diagnostic
  mode and `show`.
  Date: 2026-11-17
- Decision: (M2) `AuthorityContext` carries the deployment's Kawa source
  (`sinks.kawa.source_segment`) only until M3. The Kikan-En mapping needs it for
  `DispatchKawa`, and the key is a kernel key until M3 moves `sinks.*` to the binding; then
  the field leaves the context and the binding reads its own setting. The authority port
  itself (`Shikigami.Authority`) already had no `kawaSource`: EP-8 had placed it in the
  adapter's `KikanEnMapping`.
  Date: 2026-11-17
- Decision: (M2) Every stock role that builds the authority takes it from its packs: the
  worker and its `--workspace-*` maintenance action, the admin `workers` verb, and the
  workspace supervisor, which gains `workspaceSupervisorRoleInfoWith` and a distribution
  executable `kikan-shikigami-workspace-supervisor`. The optional Linux fixture
  `tests/workspace/prototype` composes `[kikanAuthorityAdapter]` and loads
  `authoritySettings`. With `mode=kikan` and settings missing, the refusal now comes from
  the adapter at start (naming each missing key), not from configuration resolution.
  Rationale: no Kikan feature lost; the supervisor would otherwise have lost Kikan-En.
  Date: 2026-11-17
- Decision: (M2) `pack-sdk` re-exports three more kernel modules: `Shikigami.Authority`
  (the port the adapter implements), `Shikigami.Authority.Adapter` (its registration) and
  `Shikigami.Behavior.Error` (`boundedBehaviorDetail`, the redaction every refusal detail
  passes through). `flow-sdk` and `pack-sdk` were re-pinned (`FlowPack.authorities`; the
  secret names); both changes are additive.
  Date: 2026-11-17
- Decision: (M2) Pre-release recheck, 2026-11-17. M2 changed
  `shikigami-core/src/Shikigami/Flow/Pack.hs` and `Flow/Builtin.hs` (a record field, not a
  workflow body) and nothing under `Agent/` or `domain/`. The four facts of ADR-27: no
  journal that must resume (run 7a28975f in the development database is the user's open
  decision and was not touched; scratch databases were used); no stored payload needing an
  old codec (no codec changed); no external wire consumer; `git tag --list` prints nothing.
  The MasterPlan records no EP-11 baseline gate, so the exception stands.
  Date: 2026-11-17
- Decision: (M3, user decision 2026-11-17) `sinks` and the closed `Sink` union leave the
  agent declaration before EP-11's first freeze; the five Kikan kinds become output kinds
  declared in `outputs` and built with typed Dhall helpers in the binding. The user chose
  this over keeping `Sink` as kernel declaration data with only the clients moved, which
  would have frozen Kikan constructors into `schema/Agent.dhall`. No declaration outside
  this repository uses `sinks` (fsrs-hs and keiro checked); 13 here do.
  Date: 2026-11-17
- Decision: (M3 design) The kernel keeps one delivery mechanism, the sink intent, outbox
  and `shikigami.sink_deliveries` receipts, and addresses it by `OutputDecl` instead of
  `Sink`. An adapter says how it is delivered: `local.report` stays inline in the run (the
  light command has no outbox publisher); a Kikan kind is delivered by the outbox publisher,
  which keeps the lifecycle check, the C11 grant check (keyed by output kind), fresh C13
  authorization of the adapter-named `EmitOutput` target, and the receipt guard. What the
  sink intent carries for one service today (`danwaTarget`, the resolved Kizashi
  recipient, the channel conversation key) becomes adapter-owned JSON computed at enqueue
  from the trigger activity and the output, so the kernel no longer names a service.
  Staged so every step builds and passes: (a) the kernel pipeline addresses outputs and
  dispatches through adapters while the adapters are still in core; (b) the adapters move to
  the binding; (c) `sinks` leaves the schema and the declarations move to `outputs`;
  (d) the approval-channel port and the Danwa and Kizashi channels; (e) the stubs become
  distribution admin verbs. Two consequences found while designing: the flow SDK's emit
  operations (`emitSignal`, `emitSignalTo`, `emitSignals` in `Shikigami.Flow.Capability`,
  used by the watchdog pack's `Delivery`) take an `OutputDecl` instead of a `Sink`; and
  `shikigami.sink_grants` pins the five legacy kind names in a CHECK constraint
  (migration `0003-sink-grants.sql`), so grants keyed by output kind need a new migration
  that relaxes the check and renames the stored values (`KawaDigest` to `kawa.digest` and
  so on). The `dispatch-sinks` journal step stores `[SinkResult]` whose `kind` changes from
  the closed `SinkKind` to an output kind; `just keiro-gate` will report it.
  Date: 2026-11-17
- Decision: (M3 stage a, 2026-11-17) The adapter says how it delivers. `OutputAdapter`
  carries `route :: OutputRoute`, either `DeliverInline` (the `local.report` delivery
  function, unchanged) or `DeliverByOutbox OutboxRoute`, whose three functions are the whole
  of what the kernel asks of a service: `address` (computed at enqueue from the
  configuration, the trigger activity and the result, journaled opaquely), `target` (the
  `EmitOutput` segments the authority decides, from configuration and address) and
  `dispatch` (called by the publisher with an `OutboxDelivery`). `SinkContext` is gone; its
  per-service fields are the adapter's own (`KikanServices`), and `danwaTarget`,
  `resolvedRecipient`, `conversationKey` and `triggeringActivityId` are adapter address or
  configuration. A producer directs an output in its configuration: `toRecipient` sets a
  signal's exact `recipient`, `inThread` a Danwa `thread`. So `SinkIntent` is
  `{agent, identity, runId, ordinal, occurredAt, output, address, result}`, `SinkResult.kind`
  is an `OutputKind`, `dispatch-sinks` journals dotted kinds, and C11 grants and delivery
  receipts are keyed by output kind (migration `0052-output-kind-grants` drops the five-name
  CHECK for a kind-shaped one and renames stored rows). The agent run resolves one output
  list (legacy `sinks` converted by `sinkOutput` until stage c, then `outputs`), asks one
  approval per output under the key `output-<kind>-<n>`, then enqueues the outbox outputs in
  `dispatch-sinks` and delivers the inline ones in `deliver-outputs`, each at its position
  in the list. `approval.require` names output kinds and still accepts the five legacy
  names; `approval.require_outputs` adds to the same set. The flow SDK's `emitSignalTo`
  becomes `emitDirected` (same `emit-signal-<label>` step name) and `AddressedSignal`
  becomes `AddressedOutput`. The five adapters and the typed configurations
  (`Shikigami.Output.Kikan`, `Shikigami.Sink.Outputs`) are still in core for this stage.
  Rationale: the staged design above; every later stage moves code without reshaping it.
  Date: 2026-11-17
- Decision: (M3 stage a) `kawa.digest` is one adapter and it is delivered by the outbox,
  like the `KawaDigest` sink it replaces; its configuration is the sink's
  `{subjectType, verb}`. EP-8 M3's inline `kawa.digest` (configuration `{subjectKind, verb}`)
  is retired. Consequence for M6: a Kikan run's record now has `authority.decided` for the
  enqueue but no `output.delivered`, because delivery happens later in the publisher; M6's
  projection of the record into run evidence must add the publisher's delivery entry before
  the portability comparison is rerun.
  Date: 2026-11-17
- Decision: (M3 stage a) Pre-release recheck, 2026-11-17. Stage a changes workflow bodies
  under `shikigami-core/src/Shikigami/Agent/` (the order of `resolve-outputs`,
  `dispatch-sinks` and `deliver-outputs`, and the approval child keys) and
  `shikigami-core/src/Shikigami/Flow/` (the emit operations), and the stored shape of
  outbox intents and delivery kinds. The four facts of ADR-27: no journal that must resume
  (run 7a28975f in the development database is untouched; every test used a scratch
  database); no stored payload that needs an old codec (the development database has 0
  `keiro.keiro_outbox` rows and 0 `shikigami.sink_deliveries` rows); no external wire
  consumer; `git tag --list` prints nothing. The MasterPlan records no EP-11 baseline, so
  the exception stands and the old intent bytes are not decoded.
  Date: 2026-11-17
- Decision: (M3 stage c, 2026-11-17) `sinks` and the `Sink` union leave
  `schema/Agent.dhall` and `Shikigami.Agent.Decl`, together with the three Kizashi enums
  (`SignalType`, `Priority`, `RecipientFrom`) in the Dhall schema; the journal codec of
  `AgentDecl` loses the `sinks` key. A declaration lists Kikan outputs in `outputs`,
  built with `schema/outputs/Kikan.dhall` (`kawaDigest`, `kizashiSignal` over
  `KizashiSignal::{..}`, `reiAction`, `danwaConversation`, `channelEgress` over
  `ChannelEgress::{..}`), which renders each kind's JSON configuration; stage b moves that
  file to the binding. Packs build the typed configurations of `Shikigami.Sink.Outputs`,
  re-exported by `flow-sdk` until the binding owns them. The watchdog's delivery policy
  setting carries outputs (`operatorOutput`, `conversationOutput`, each `{kind, config}`)
  in place of `operatorSink` and `conversationSink`. The HTTP API's agent view reports
  `outputs` (the declared output kinds; empty means the composition default) in place of
  `sinks`. `ChannelEgressOutput` always encodes `conversationKey` (null when absent), so a
  configuration built in Haskell and one rendered by the Dhall helper are equal values.
  Rationale: the user's decision above; the first freeze must not carry Kikan
  constructors. Pre-release recheck as for stage a (same day, same facts).
  Date: 2026-11-17
- Decision: (M3 stage c) Stage a's commit was verified with stale binaries for the
  workers, server, agent and pack suites: `cabal build all` here does not build test
  suites, and those suites did not compile at `dda65c61` (FRIC-98). Stage c fixes them and
  every suite is now built by name before it runs.
  Date: 2026-11-17
- Decision: (M3 stages b and d, 2026-11-17) A pack registers outputs and approval channels
  on its `FlowPack`, as it registers authorities. `Shikigami.Output.Registration` gives
  `OutputRegistration {kind, validate, defaultConfig, preferredDefault, build}`, where
  `build :: AdapterContext -> IO (Either Text OutputAdapter)` runs once at start from
  `AdapterContext {logger, settings, httpLimits}`; `validationRegistry` checks declarations
  with no service at hand (`shikigami validate`), and `buildOutputRegistry` builds the
  worker's and the light command's registry. `Shikigami.Approval.Channel` gives
  `ApprovalChannelRegistration {channel, preferred, build}` and
  `composeApprovalNotifier`, which routes an ask by the channel it names, with the
  kernel's local inbox always composed. `ApprovalChannel` becomes a name
  (`mkApprovalChannel`); an ask that names `configuredApprovalChannel` goes to the
  composition's channel. `outputs.default` takes `composition` (the default: the output a
  composed pack prefers, else none), `none`, or a registered kind; `approval.channel`
  is optional (absent: the preferred channel, else `local-inbox`), and an executable
  refuses to start on a channel or default kind it does not compose.
  `composeFlowRegistry` refuses a kind or channel two packs register.
  Rationale: the kernel then names no service, and the stock composition is the empty case
  of the same mechanism, not a special one.
  Date: 2026-11-17
- Decision: (M3 stage b) The binding holds the five adapters, their clients
  (`Kikan.Shikigami.Binding.Output.{Kawa,Kizashi,Kanmon,Rei,Danwa,Recipient,Wire,Config,Http}`),
  the Danwa and Kizashi approval channels (`Kikan.Shikigami.Binding.Approval`; Danwa is
  preferred) and the service settings (`Kikan.Shikigami.Binding.Settings`). The
  `sinks.*` and `credentials.sinks.*` keys keep their names and variables as the binding's
  pack settings, the tokens as secret pack settings, so an operator's configuration keeps
  working with the distribution and a stock executable refuses them as unknown. The typed
  configurations, the Kizashi enums, `toRecipient`, `inThread` and the binding's approval
  channel names are a public sublibrary, `kikan-shikigami-binding:outputs`, depending on
  `flow-sdk` only, so a pack's bodies may import them. `kawa.digest` is the binding's
  preferred default, with the verb this plan names (`agent.run.completed`, replacing EP-8's
  `reported`). The Dhall helper moved to `packs/kikan-shikigami-binding/dhall/Outputs.dhall`.
  The kernel's Danwa conversation still spells its reply as a raw `danwa.conversation`
  output until M5, with the same configuration JSON as before; the kernel keeps the generic
  HTTP layer (`Shikigami.Sink.Http`, `Shikigami.Sink.Auth`), now re-exported by `pack-sdk`.
  Date: 2026-11-17
- Decision: (M3 stage b) The worker flags `--kawa-url`, `--kizashi-url`, `--kanmon-url`,
  `--danwa-url` and `--danwa-agent` are removed with the kernel keys they set. An operator
  sets the binding's keys with `--set` or their variables; pre-release, no deployment uses
  the flags.
  Date: 2026-11-17
- Decision: (M3 stage b) Tests follow the code they test, because no stock package may
  depend on a pack in any stanza. The Kikan client, dispatch, honesty and approval-channel
  tests moved to the binding's suite (65 cases); the binding publishes its fixtures as
  `kikan-shikigami-binding:test-support`. The Kikan delivery suite through the kernel's
  publisher (`SinkDeliverySpec`, 20 cases) moved to the distribution as
  `Kikan.OutputDeliverySpec`. Kernel tests spell outputs as raw `OutputDecl`s
  (`Shikigami.Fixture.RawOutput`) and use neutral adapters that deliver nowhere or record
  what they are handed (`Shikigami.Fixture.Outputs`); the two kernel cases that used the
  Kawa and Danwa stubs (revocation between enqueue and publish, approval convergence)
  assert the same properties on a capturing adapter and a capturing approval channel. The
  qualification closure's two fixture agents now keep their results in the journal, because
  that closure is the stock composition (ADR-39).
  Date: 2026-11-17
- Decision: (M3 stage e) `stub-kawa` and `stub-kanmon` are verbs of the distribution's
  `kikan-shikigami` command, from a stub-only `FlowPack` that the admin executable composes;
  their tokens come from the binding's secret settings. The modules live in
  `packs/kikan-shikigami/admin/` and are compiled into the admin executable and the test
  suite, because a distribution has no library by the fitness rule. `publish-fixture` stays
  stock until M5 moves the stream intake: it publishes a kernel activity envelope and needs
  no Kikan service.
  Date: 2026-11-17
- Decision: (M3) The three sample declarations `agents/{heartbeat,danwa-heartbeat,triage-note}.dhall`
  stay in `agents/` for now, importing the binding's helper. About 40 files name them,
  among them core tests that only decode them; moving them changes no behaviour and is
  left to M6 with the distribution's example set.
  Date: 2026-11-17
- Decision: (M4, 2026-11-17) A pack installs an objective tracker provider as a
  `TrackerProviderRegistration {revision, connect}` on `FlowPack.trackerProviders`, in
  `Shikigami.Objective.Tracker.Provider`; `connect :: HttpLimits -> Connection -> IO (Either
  TrackerError TrackerConnection)` opens one configured connection at start, and a
  `TrackerConnection` is `{provider :: ResourceScope -> Either TrackerError Provider, close}`.
  `Shikigami.Objective.Tracker.Runtime.withTrackerProviders` takes the installed
  registrations, keeps the connection-digest fence, and refuses a revision nobody installs
  ("objective tracker provider revision is not installed"). The kernel keeps the generic
  `env:NAME` credential reading (`environmentCredential`); `Sink.Auth.bearerTokenFromText`
  is the token boundary for a credential an adapter reads itself. The Rei provider is
  `Kikan.Shikigami.Binding.Tracker.Rei.reiTrackerProvider`, installed by the binding, and its
  real-Rei suite is `kikan-shikigami-binding:test:kikan-shikigami-binding-rei-test` under the
  binding's `objective-tracker-rei-tests` flag. `shikigami-core` no longer depends on
  `rei-api-client` or `rei-api-contract`. `composeFlowRegistry` refuses a revision two packs
  install, and `flows` lists each pack's authority, outputs, channels and trackers.
  Date: 2026-11-17
- Decision: (M4) The server composes packs: `Shikigami.Server.Boot.runServerMainWith` and
  `runServerWith` take `[FlowPack]`, accept their settings and open tracker connections
  through their providers; the distribution adds `kikan-shikigami-server`. The admin
  `objectives trackers` commands take the composed packs' providers. As decided for M1, the
  server executable is added now because it composes something.
  Date: 2026-11-17
- Decision: (M4) The frozen qualification cohort (`nix/qualification/cohort.json`, ADR-39)
  is not regenerated here. It has not been since M2 removed Kikan-En from the core, and
  regenerating it needs the isolated qualification solve and the Nix builds; M6, which owns
  the Nix exclusion and its consequences, regenerates it once for M2 to M5.
  Date: 2026-11-17
- Decision: The development stubs (`stub-kawa`, `stub-kanmon`, `publish-fixture`) move to
  the distribution's admin executable.
  Rationale: They are fixtures for Kikan services. The stock admin command should not offer
  a Kawa stub to an operator who has no Kawa.
  Date: 2026-11-15


## Outcomes & Retrospective

(To be filled during and after implementation.)


## Context and Orientation

Shikigami is a Haskell monorepo of seven Cabal packages, listed in `cabal.project`.
`shikigami-core` is the domain library and durable workflows. `shikigami-agent` holds light
one-off commands. `shikigami-workers` holds the background executables: `shikigami-worker`,
`shikigami-scheduler`, `shikigami-consume-stream` and `shikigami-consume-events`.
`shikigami-server` holds the HTTP server and the `shikigami` admin command. `shikigami-api`,
`shikigami-client` and `shikigami-migrations` complete the set. Records use strict,
unprefixed fields under `DuplicateRecordFields` (`AGENTS.md`).

Kikan is the organization platform Shikigami belongs to. Its services, each a sibling
repository, are: Kikan-En (`mori://shinzui/kikan-en`), which decides whether a principal may
perform an action; Shomei (`mori://shinzui/shomei`), which issues signed identity tokens;
Kawa (`mori://shinzui/kawa`), the activity stream; Kizashi (`mori://shinzui/kizashi`), which
carries signals to people; Rei (`mori://shinzui/rei`), which tracks commitments called
intentions; Danwa (`mori://shinzui/danwa`), which hosts conversations; Kanmon
(`mori://shinzui/kanmon`), the gateway for channel egress; and Meibo
(`mori://shinzui/meibo`), the directory of principals. The contracts between them are the
Kikan cross-cutting contracts, `mori://shinzui/kikan/docs/cross-cutting-contracts`, the file
`docs/architecture/evolution/contracts.md` in that repository. This plan cites them by their
numbers there, such as C13 for authorization.

This plan is EP-10 of
`docs/masterplans/22-rebuild-shikigami-as-a-kernel-where-use-cases-are-declared-not-coded.md`.
Three sibling plans supply what it consumes. None had landed when this plan was written, so
the names below come from the MasterPlan's Integration Points and must be rechecked against
the landed code before each milestone.

EP-8 (`docs/plans/133-give-the-kernel-its-own-action-record-output-approval-and-trigger-contracts-with-local-adapters.md`)
gives the kernel its own *ports*. A port is a kernel-owned interface that an adapter
implements; adapters are chosen when an executable is composed. The ports are
`Shikigami.Authority` (an `Action` sum owned by the kernel and an `Authority` record with one
`decide` function), `Shikigami.Record` (the append-only *action record* of every decision and
effect), `Shikigami.Output` (an `OutputAdapter` registered under an `OutputKind`, replacing
the closed `Sink` union), `Shikigami.Approval.Channel` (an adapter per `ApprovalChannelKind`)
and `Shikigami.Trigger`. After EP-8, the Kikan clients still live in `shikigami-core`, as
adapters behind those ports. This plan moves them out.

EP-5 (`docs/plans/130-move-the-extension-boundary-out-of-shikigami-core-with-flow-packs-and-an-architecture-fitness-check.md`)
defines the *pack*: a Cabal package outside the seven that exports one
`Shikigami.Flow.Pack.FlowPack` value and depends on exactly two components of the core.
`shikigami-core:flow-sdk` is what a flow body may import. `shikigami-core:pack-sdk` adds
what an interpreter or an adapter needs: the kernel ports, a read view of the run and the
store. EP-5 also adds the *fitness check*, a test group named `kernel boundary` in
`shikigami-core/test/Shikigami/PackageArchitectureSpec.hs` that fails when use-case code
enters the core or when a stock package depends on a pack. Each role library exposes a
`...With :: [FlowPack] -> ...` entry point, and no stock executable depends on a pack.

EP-6 (`docs/plans/131-shrink-shikigami-core-to-the-kernel-by-moving-or-retiring-use-case-subsystems.md`)
moves the organizational use cases into packs named `flow-pack-<name>` and creates the
distribution package `kikan-shikigami` when it moves the first scheduled flow. It is a soft
dependency: if it has not created the distribution, this plan does.

What is Kikan-specific in the tree today, measured on 2026-11-15 with `wc -l`:

```text
shikigami-core/src/Shikigami/
  Sink/{KawaClient,KizashiClient,KanmonClient,Danwa,ReiAction}.hs        618  service clients
  Sink/{Http,Auth,Auth/Internal,Config,Recipient,Wire,Authorization,
        Validate}.hs                                                     982  shared by clients
  Sink.hs (dispatch case), Sink/Types.hs (SinkContext)                   327  reshaped by EP-8
  Sink/{Intent,Delivery,GrantStore,Permission}.hs                      1,495  kernel mechanism, stays
  Action/Authorization.hs (newKikanActionAuthorizer), .../Config.hs      259  about 150 lines move
  Agent/Conversation.hs, Agent/Conversation/SessionIndex.hs,
    Integration/Danwa.hs                                               1,747  Danwa conversation loop
  DanwaConversation/Generated/*                                           86  generated from domain/
  Objective/Tracker/{Rei,Runtime}.hs                                     244  Rei provider and wiring
  Objective/Tracker/* (the other thirteen modules)                     1,864  provider-neutral, stays
shikigami-workers/src/Shikigami/
  Trigger/Consumer.hs, Integration/ConsumerRuntime.hs                    871  Kafka intake
shikigami-server/src/Shikigami/
  Server/Command/{StubKawa,StubKanmon,PublishFixture}.hs,
    Sink/{KawaStub,KanmonStub,KawaStub/Republish}.hs                          development stubs
```

About 5,000 hand-written lines move. The Cabal dependencies that leave `shikigami-core` are
`danwa-api`, `danwa-client`, `kikan-en-client`, `kikan-en-contract`, `rei-api-client`,
`rei-api-contract`, `shomei-client` and `shomei-servant`. `kikan-en-client` and
`kikan-en-contract` also leave `shikigami-workers`, and `danwa-api` and `danwa-client` leave
`shikigami-server`. The Kafka libraries `hw-kafka-client` and `kafka-effectful` leave
`shikigami-workers` and `shikigami-server` in M5. Kioku (`mori://shinzui/kioku`) is not a
Kikan service; it is the memory library the kernel uses over its own PostgreSQL, and it
stays.

Two composition records carry the Kikan fields today. `AgentRunDeps`
(`shikigami-core/src/Shikigami/Agent/Workflow.hs`) has `actionAuthorizer`, the service
configurations `kizashi`, `kawa`, `kanmon`, `danwa` and `rei`, `http :: SinkHttp` and
`grants :: GrantSource`. `WorkerEnv` (`shikigami-workers/src/Shikigami/Workers/Config.hs`)
repeats most of them and adds `trackers`. `SinkContext`
(`shikigami-core/src/Shikigami/Sink/Types.hs`) has one configuration field per service. The
settings are in `shikigami-core/src/Shikigami/App/Config.hs`: `sinks.kawa.base_url`,
`sinks.kawa.source_segment`, `sinks.kizashi.base_url`, `sinks.kizashi.default_recipient`,
`sinks.kanmon.base_url`, `sinks.danwa.base_url`, `sinks.danwa.agent_participant`,
`sinks.rei.base_url`, and `authorization.actions.mode` with its `kikan_en`, `shomei`, `en`
and `caller_id` companions.

Relevant ADRs:

- [ADR-1](../adr/0001-declare-only-what-the-runtime-executes.md): declare only what the
  runtime executes. It is why no Meibo client is invented here.
- [ADR-3](../adr/0003-a-seventh-package-keeps-one-off-agent-runs-light.md): `shikigami-agent`
  links no Kafka, PGMQ or OTLP stack, and every executable links only its own package's
  library. The distribution's light executable must stay light.
- [ADR-13](../adr/0013-flow-bodies-reach-the-world-only-through-capabilities.md), as EP-5
  amends it: a pack's reviewed interpreter or adapter may use IO; a flow body may not.
- [ADR-27](../adr/0027-the-first-release-establishes-one-clean-durable-baseline.md) and
  `docs/workflow-versioning.md`: unreleased workflow and declaration shapes may be replaced
  directly until the baseline, provided four facts are rechecked and recorded and
  `just keiro-gate` still runs.
- [ADR-30](../adr/0030-an-approval-request-is-a-durable-child-workflow.md): an approval is a
  durable child workflow, and its token is never derived from its review id or printed.
- [ADR-36](../adr/0036-external-agent-actions-require-fresh-exact-authorization.md): every
  external action needs fresh exact authorization and the default is deny-all. EP-8 restates
  it over the kernel's `Action`.
- [ADR-39](../adr/0039-deployment-roles-share-a-frozen-cabal-source-closure.md): the stock
  roles are built from one frozen closure of seven `shikigami-*` packages. The binding and
  the distribution are outside it.
- [ADR-75](../adr/0075-service-composition-has-a-closed-reviewed-module-budget.md): the
  closed module budget that EP-5's kernel boundary sits beside.
- [ADR-112](../adr/0112-observed-content-is-evidence-and-never-instruction.md): content read
  from a stream or a conversation is evidence, never instruction.

No ADR yet records the two-composition rule. This plan writes it.


## Plan of Work

The order runs from least to most coupled. M1 creates the packages and moves nothing. M2
moves the authority adapter, which has one seam. M3 moves the output and approval adapters,
which share an HTTP environment. M4 moves the Rei provider, which sits behind an existing
provider record. M5 moves the two pieces woven into workflows and executables: the Danwa
conversation loop and the Kafka intake. M6 removes the last dependencies, makes the fitness
check enforce the result and runs the portability check. After every milestone the full tree
builds, `cabal test all` passes, and the Kikan feature that moved runs from the
distribution.

Every move obeys three rules. Behavior does not change: same settings, same wire requests,
same refusals. Anything the binding needs from the kernel is exported through
`shikigami-core:pack-sdk` in the same commit and listed in this plan's Decision Log with the
reason, because that list is how 357 exposed modules become a reviewed API. And tests move
with their code: a core test that needs a Kikan client becomes a binding test.

### Pre-release recheck and the workflow gate

Before each milestone that changes code under `shikigami-core/src/Shikigami/Agent/` or
`shikigami-core/src/Shikigami/Flow/`, or anything under `domain/`, recheck the four facts
of ADR-27 and record them, dated, in the Decision Log: no workflow journals that must
resume, no stored payloads that need an old codec, no external wire consumers, and no
release or deployment (`git tag --list` prints nothing). Also read the MasterPlan's Decision
Log: the exception ends when EP-11's baseline gate is recorded there. If it has ended, a move
must keep every journal label and patch order byte-identical and any codec change needs a
decode path. Drain every non-terminal run before switching to a build with a moved shape;
that is the MasterPlan's pilot rule. Run `just keiro-gate "$(git merge-base HEAD master)"`
after the milestone. M2, M3 and M4 should report no body change. M5 is expected to report
one for the conversation workflow; record its text.

### Milestone 1: the packages, the dependency rule and the service inventory

At the end of this milestone both packages build and compose an empty binding, and the plan
records which Kikan services actually run on this Mac.

Create `packs/kikan-shikigami-binding/` with a library whose only Shikigami dependencies
are `shikigami-core:flow-sdk` and `shikigami-core:pack-sdk`, and a test suite. Its root
module exports the binding as a pack value built from loaded settings:

```haskell
-- packs/kikan-shikigami-binding/src/Kikan/Shikigami/Binding.hs
data KikanBindingConfig   -- sealed; loaded once at startup from the binding's settings

loadKikanBindingConfig :: PackSettings -> Either (NonEmpty BindingConfigError) KikanBindingConfig

-- | Everything that knows a Kikan service. Fields are filled milestone by milestone.
kikanBinding :: Log.Logger -> KikanBindingConfig -> IO FlowPack
```

If EP-6 has not created it, create `packs/kikan-shikigami/` with one executable per role and
no library. Each `main` is a few lines:

```haskell
-- packs/kikan-shikigami/app/worker/Main.hs
main :: IO ()
main = runRole (workerRoleInfoWith kikanPacks)

-- packs/kikan-shikigami/src-shared/Kikan/Shikigami/Packs.hs (an internal library)
kikanPacks :: PackSource
kikanPacks = packsFromSettings \logger settings -> do
  config <- either (refuseStartup logger) pure (loadKikanBindingConfig settings)
  binding <- kikanBinding logger config
  pure (binding : organizationalPacks)   -- the flow-pack-* packages EP-6 created
```

`PackSource` is whatever EP-5 and EP-6 landed for packs that need settings at construction;
if only `[FlowPack]` exists, extend EP-5's entry points rather than adding a parallel one,
and record that. The executables are `kikan-shikigami-worker`, `kikan-shikigami-scheduler`,
`kikan-shikigami-server`, `kikan-shikigami` (admin) and `kikan-shikigami-agent-run`. The
last depends on `shikigami-agent` and must still satisfy the light-package rule: add the
binding's library to the packages the fitness check holds to `forbiddenInLightPackages` only
if its dependencies allow, and otherwise record that the light executable composes without
the binding's Kafka-using module, which arrives only in M5 as a separate internal library.

Add both packages to `cabal.project` `packages:`. Extend the fitness check's pack rules, if
EP-5's do not already cover it, so that `kikan-shikigami-binding` is held to the two SDK
components and `kikan-shikigami` may depend on role libraries, the binding and packs, and
nothing may depend on `kikan-shikigami`.

Then take the inventory. For each service, try to start it from its own repository and
record in Surprises & Discoveries what happened: the command, whether it listened, and on
which address. The sibling repositories each carry a `process-compose` file
(`mori path mori://shinzui/kawa` and so on resolve their checkouts). What is known before
trying: Rei has a real disposable launcher used by this repository,
`tests/objective-trackers/run-rei.sh`; the Kafka-compatible broker is the operator's global
Redpanda at `127.0.0.1:9092`; Kawa and Kanmon have stubs in `shikigami-server`; nothing in
this repository starts Kikan-En, Shomei, Kizashi or Danwa. The outcome of this inventory
decides which acceptance run each later milestone uses, as Validation and Acceptance sets
out. It is not a gate: a service that will not start is recorded, and its milestone falls
back to supporting evidence with the gap named.

### Milestone 2: the authority adapter

At the end of this milestone `shikigami-core` imports nothing from `Kikan.En` or `Shomei`.

After EP-8 M1 the Kikan-En authorizer is an adapter in core that maps the kernel's `Action`
to Kikan-En's `AgentAction` and refuses an action it cannot map. Move it to
`Kikan.Shikigami.Binding.Authority`:

```haskell
-- | The C13 authority. Refuses an action with no Kikan-En equivalent.
kikanAuthority :: Log.Logger -> KikanEnSettings -> KikanEnClient -> IO (Either Text ShomeiAccessToken) -> Authority

toAgentAction :: Action -> Either UnmappedAction AgentAction
```

`toAgentAction` is total over the kernel's sum and is the one place the two vocabularies
meet. `RunDeclaredTool` and `LaunchCodingAgent` have no Kikan-En constructor today; they map
to `Left`, so under the distribution those actions are refused until Kikan-En grows them.
Record that as a gap against `mori://shinzui/kikan-en` in an improvement request, and list
it in the requirement mapping. Move `buildConfiguredActionAuthorizer`, the token source and
the `authorization.actions.*` setting decoders with it. The kernel keeps the key
`authorization.actions.mode` and a registry of authorities by name; the binding registers
`kikan`. Remove `kawaSource` from the port (Decision Log) and have the Kawa output adapter
carry its source segment. Delete the `Kikan.En.Action.ActionSchemaHash` import from
`App/Config.hs` by moving that setting's decoder. Drop `kikan-en-client`, `kikan-en-contract`,
`shomei-client` and `shomei-servant` from `shikigami-core.cabal` and the first two from
`shikigami-workers.cabal`; if `shomei-servant` proves to be used by HTTP caller
authentication, keep it, record why, and note that caller identity (C11) is out of scope.

### Milestone 3: output adapters and approval channels

At the end of this milestone the binding registers `kawa.digest`, `kizashi.signal`,
`rei.action`, `danwa.conversation` and `channel.egress`, plus the Danwa and Kizashi approval
channels, and `shikigami-core` holds no service client.

Move `Shikigami.Sink.{KawaClient,KizashiClient,KanmonClient,Danwa,ReiAction}` and the
modules only they use (`Http`, `Auth`, `Auth.Internal`, `Config`, `Recipient`, `Wire`,
`Authorization`, `Validate`) to `Kikan.Shikigami.Binding.Output.*`. Each becomes one
`OutputAdapter` under EP-8's port: it validates its configuration when a declaration loads,
names its `EmitOutput` target for the authority, and delivers an intent. The kernel keeps
the mechanism: `Shikigami.Sink.Intent`, `Shikigami.Sink.Delivery`, the outbox and the
`shikigami.sink_deliveries` receipts. `GrantStore` and `Permission` are keyed by the closed
`SinkKind` today; whatever EP-8 made of them (grants keyed by `OutputKind`) stays kernel,
and the seed grant table for Kikan agents moves to the binding as data. Move the Dhall
helpers that build each output value to `packs/kikan-shikigami-binding/dhall/Outputs.dhall`
and update `agents/heartbeat.dhall`, `agents/danwa-heartbeat.dhall` and
`agents/triage-note.dhall` to import them; these three declarations then load only under the
distribution, so move them to `packs/kikan-shikigami/agents/`. Move the Danwa and Kizashi
approval notifiers behind EP-8's `ApprovalChannel` adapters. Remove the per-service fields
from `AgentRunDeps`, `WorkerEnv` and `SinkContext`; the adapters close over their own
configuration. Build the distribution's `OutputRegistry` with EP-8's `mkOutputRegistry`,
passing `DefaultOutput` with a `kawa.digest` whose subject type is `agent-run` and whose verb
is `agent.run.completed`, the verb Kikan's signal catalog already names for a finished run.
`kikan-shikigami validate` then prints `outputs: kawa.digest (composition default)` for a
declaration with none, and the run's `run.admitted` record entry says the same. The stock
executables are unaffected: their default stays `local.report`. Move the stubs and
`publish-fixture` to the distribution's admin executable
(Decision Log). Drop `danwa-api` and `danwa-client` from `shikigami-server.cabal`.
`shikigami-core.cabal` still needs them until M5.

### Milestone 4: the Rei tracker provider

At the end of this milestone `Shikigami.Objective.Tracker` is provider-neutral and the Rei
provider is installed by the binding.

The seam already exists: `Shikigami.Objective.Tracker.Provider.Provider` is a record of
`readResource`, `publish`, `reconcile` and `verifyReceipt`. Only `Tracker/Rei.hs` and the
Rei-specific half of `Tracker/Runtime.hs` (which checks `Rei.reiProviderRevision`, reads an
`env:NAME` credential and calls `Rei.mkReiProvider`) know Rei. Move them to
`Kikan.Shikigami.Binding.Tracker.Rei`, and turn the kernel's runtime into a lookup in a
registry of providers by revision that packs fill. This needs a `trackerProviders` field on
`FlowPack`; extend EP-5's type and record it. Move the `shikigami-objective-tracker-rei-test`
suite and its `objective-tracker-rei-tests` flag to the binding. Drop `rei-api-client` and
`rei-api-contract` from `shikigami-core.cabal`.

### Milestone 5: the conversation loop and the stream intake

At the end of this milestone the Danwa conversation workflow and the Kafka consumers run
only from the distribution.

The conversation loop is `Shikigami.Agent.Conversation` (1,529 lines), its session index and
`Shikigami.Integration.Danwa`. It is a second durable workflow family beside `AgentRun`,
declared in `domain/shikigami/conversation.keiro` and generated into
`Shikigami.DanwaConversation.Generated`. Move the hand-written modules to
`Kikan.Shikigami.Binding.Conversation` and contribute the family through a `workflows :: !(WorkflowRegistry AppEffects)`
field that this plan adds to EP-5's `FlowPack` (empty for every other pack), so that
`Shikigami.Workflow.Registry` unions it with the kernel families and refuses a duplicate
family name at composition. This plan is the field's first executed consumer (ADR-1): EP-6
does not add it, because the adaptive-delivery coordinator stays in the kernel by the user's
decision of 2026-11-15. `RunRouteKind.ConversationWorkflowRoute` in `domain/shikigami/run-jobs.keiro`
is how a run job reaches it; replace the closed route with a route name a pack registers,
and record the `keiro-gate` finding.

One question is settled by a bounded prototype before the move: can `just keiro-scaffold`
generate the conversation facts into the binding from a specification the binding owns? Try
it for half a day. If it works, move `conversation.keiro` into
`packs/kikan-shikigami-binding/domain/` and generate there, which is the end state the
MasterPlan's label rule wants. If it does not, leave the specification and the generated
modules in core as specification-owned, cite the keiro
improvement request EP-5 files for workflow fragments in separate packages, and record that
the baseline carries this one exception.

For intake, move `shikigami-workers/src/Shikigami/Trigger/Consumer.hs` and
`Integration/ConsumerRuntime.hs` to an internal library of the binding,
`kikan-shikigami-binding:intake`, kept separate so the light executable never links Kafka.
The kernel keeps what every intake ends in: `Shikigami.Trigger.Enqueue` and the `RunJob`
queue. Add `kikan-shikigami-consume-stream` and `kikan-shikigami-consume-events` to the
distribution and delete the two stock executables and their Kafka dependencies. Stream and
event triggers in a declaration then load only where an intake adapter is composed; the
stock composition refuses them at load with a message naming the registered trigger kinds.
Drop `danwa-api` and `danwa-client` from `shikigami-core.cabal`.

**What the deployed roles lose.** Nix packaging of the distribution is excluded from this
initiative (ADR-39). After this milestone the stock Nix roles are a kernel with local
adapters: they have no Kikan-En authority, no Kikan output, no conversation loop, no stream
or event intake and no organizational pack. Organizational deployment therefore needs the
distribution packaged, which is follow-up work named in the ADR. Until then the distribution
is built and run with `cabal`, which is what every acceptance run here uses. Nobody deploys
the stock roles for organizational use today, since Shikigami has no deployment at all.

### Milestone 6: enforcement, evidence, portability and the record of decisions

Add a rule to the fitness check: no stanza of the seven stock packages may depend on a
package in a closed list of Kikan client libraries (`danwa-api`, `danwa-client`,
`kikan-en-client`, `kikan-en-contract`, `rei-api-client`, `rei-api-contract`,
`shomei-client`, `kafka-effectful`, `hw-kafka-client`), and no module under the seven may
import `Kikan.`, `Danwa.`, `Rei.` or `Shomei.`. Prove the rule on synthetic inputs so it
cannot pass vacuously. Remove the Kikan binding namespaces from EP-5's kernel namespace
list; its stale-entry rule forces this.

Project the action record into run evidence. The kernel's record (EP-8) is the source of
truth for "what did this run do". The `RunEvidence` aggregate
(`domain/shikigami/run-evidence.keiro`, `shikigami-core/src/Shikigami/Attestation/Evidence.hs`)
is what an attestation will commit to. Add a binding module that, for a finished run, reads
its record events through the pack SDK and appends them to the run's evidence, and emits one
Kawa digest per run summarizing its actions with `actor.kind = "agent"`, which is how C3's
"every action is remembered" becomes true in the organization's own stream. Evidence
collection itself stays kernel; signing stays out of scope.

Run the portability check that EP-8 owns, against the distribution. Take EP-8's declaration,
which uses only kernel vocabulary, and run it once with `shikigami-agent-run` under
`LocalOperator` and once with `kikan-shikigami-agent-run` under `Contained`. Compare the two
action records with EP-8's comparison command. They must list the same actions in the same
order and differ only in the deciding authority, its decision reference and the output kind
the default resolved to. The declaration has no `outputs` line, so the check also asserts
the default: `run.admitted` names `local.report (composition default)` in the stock run and
`kawa.digest (composition default)` in the distribution run, and each run's
`output.delivered` entry matches. Add EP-9's routine agent
(`docs/plans/134-declare-and-run-a-routine-agent-with-one-file-and-one-command.md`) to the
check once it exists and uses no coding agent or declared tool: it must load under
`kikan-shikigami validate` unchanged.

Write the ADR, next free number in `docs/adr/`: "One kernel is composed two ways, and Kikan
services are bindings". It records the two-composition rule; that the stock packages link no
Kikan client; the binding's dependency rule; that settings keep their keys and migrations
stay in one chain; the removal of the stock consumers; the Nix exclusion and its
consequence; and the Meibo and conversation-specification exceptions if they stand. Update
`docs/architecture/packages.md` with both packages, their tables and the legal arrows.
Update `docs/user/living-loop.md`, `docs/capabilities/local-integration-fixtures.md` and the
capability pages for addressed conversations and the sink outbox to name the distribution's
executables. Finally bring the MasterPlan's "Kikan requirements and where each lives" list
up to date from the mapping below.

### The requirement mapping this plan keeps true

Each entry gives the requirement, its home after this plan and its state. "Met" means it
runs in the distribution; "partial" names what is missing; "deferred" names the owner.

- Identity and the kill switch (C14): invariant K1; the worker refuses a paused principal
  through the directory (`shikigami-workers/src/Shikigami/Agent/RunJob/Worker.hs`, the
  `lifecycleRefusal` call). Partial: the directory reads a file projection; a live Meibo
  source is deferred to a future binding plan, and Kikan's own C14 fixtures are open.
- Signed caller identity (C11): the HTTP API. Deferred to its owning plan
  (`mori://shinzui/kikan/docs/cross-cutting-contracts`, C11; open in Kikan's project
  status).
- Authorization at every tool and sink dispatch, fail closed (C13): invariant K2 with
  `kikanAuthority`. Met for the actions Kikan-En names; partial for `RunDeclaredTool` and
  `LaunchCodingAgent`, refused until Kikan-En adds them (improvement request filed in M2).
- "Every action is remembered" (C3) and evidence the agent cannot rewrite: invariant K3
  with the M6 projection. Met in the store; the Kawa digest is met only where Kawa runs.
- Activity envelopes, signals, commitments and conversations (C1, C4, C5): the output and
  intake adapters. Met against a real service where one runs locally, otherwise against a
  stub, as Validation and Acceptance records per service.
- One exact behavior artifact per run and governed evolution: invariant K4. Met for
  pinning; evolution beyond playbook proposals is deferred to Shikigami's IR-5.
- Budgets, cost and usage: invariant K5. Partial: cost capture for ordinary runs is
  deferred to its owning plan.
- Tenancy: no tenant type; Space context travels in `context_refs`. Met by not adding one.
- Attestation: evidence collection is kernel. Signing is deferred to plan 52
  (`docs/plans/52-signed-attestation-read-api-and-uc-8-conformance.md`).
- A2A delegation: `DelegateRun` carries lineage and budgets. The transport is deferred to
  Shikigami's IR-6.
- Channel egress through Kanmon (C12): the `channel.egress` adapter. Partial: the inbox
  wire is deferred to its owning Kikan plan.
- Organizational use cases: the packs EP-6 creates, composed by the distribution. Met when
  EP-6 is; mandates stay a kernel primitive.


## Concrete Steps

Run everything from `/Users/shinzui/Keikaku/bokuno/shikigami` inside the development shell
(`nix develop` or direnv). Start PostgreSQL with `process-compose up` in another terminal.

Measure what is in core before M1 and again at M6, and record both in Outcomes:

```bash
grep -rlE '^import +(qualified +)?(Kikan\.En|Danwa\.|Rei\.|Shomei\.)' \
  shikigami-core/src shikigami-workers/src shikigami-server/src shikigami-agent/src | wc -l
grep -cE '^\s+(danwa-|kikan-en-|rei-api-|shomei-)' shikigami-core/shikigami-core.cabal
```

```text
15
17
```

Both must be 0 at M6. The second count includes the test stanzas.

Build and check after every milestone:

```bash
cabal build all
cabal test all
just kernel-fitness
just haskell-conventions
just keiro-gate "$(git merge-base HEAD master)"
```

Confirm the composition (M1 onward):

```bash
cabal run kikan-shikigami -- flows
cabal run shikigami -- flows
```

```text
kikan-binding  (authority: kikan; outputs: kawa.digest, kizashi.signal, rei.action,
                danwa.conversation, channel.egress; channels: danwa, kizashi)
```

The first command lists the binding and the organizational packs. The second must not list
`kikan-binding`.

Start a sibling service for a real run (M2 to M5). The form is the same for each; the
service's own README is authoritative for its ports:

```bash
cd "$(mori path mori://shinzui/kizashi)" && process-compose up > /private/tmp/kizashi.log 2>&1 &
echo $! > /private/tmp/kizashi.pid
```

Stop it with `kill "$(cat /private/tmp/kizashi.pid)"`, never by process name.

Run the distribution worker and send it work (M3):

```bash
worker=$(cabal list-bin kikan-shikigami-worker)
"$worker" --agents packs/kikan-shikigami/agents > /private/tmp/kikan-worker.log 2>&1 &
echo $! > /private/tmp/kikan-worker.pid
cabal run kikan-shikigami -- enqueue-run triage-note \
  --payload '{"ticket":"Login page returns 500 after deploy"}'
cabal run kikan-shikigami -- runs show shikigami.agent-run <WORKFLOW_ID> --json | jq '.sinks'
```

The Rei qualification (M4), moved with the suite:

```bash
bash tests/objective-trackers/run-rei.sh
```

The portability check (M6), with EP-8's declaration and comparison command substituted:

```bash
cabal run shikigami-agent-run -- --set trust.tier=local-operator --agent <EP-8 declaration>
cabal run kikan-shikigami-agent-run -- --agent <EP-8 declaration>
<EP-8 comparison command> <run-1> <run-2>
```

```text
actions: 6 of 6 match in order
differs: authority (local-operator: operator approval / kikan: kikan-en decision)
differs: default output (local-operator: local.report / kikan: kawa.digest)
```


## Validation and Acceptance

"No supported Kikan feature lost" is the overriding criterion. Each milestone is accepted by
the moved feature running from the distribution on this Mac. Where a real service starts,
the run against it is the acceptance. Where only a stub or fixture exists, the run against
the stub is supporting evidence, the plan says so in Outcomes, and the milestone is accepted
with the gap named. No milestone adds a Linux or container qualification gate.

M1 is accepted when `cabal build kikan-shikigami-binding kikan-shikigami` succeeds;
`kikan-shikigami flows` prints the binding; a synthetic-input test shows the fitness check
refusing a binding that depends on `shikigami-workers` and a stock package that depends on
the binding; and the inventory of services is recorded with evidence for each.

M2 is accepted when the import count for `Kikan.En` and `Shomei` in `shikigami-core` is 0,
and a distribution worker run of an agent with one protected action shows a Kikan-En
decision in the action record. If Kikan-En and Shomei start locally (M1's inventory), that
run is against them and is the acceptance. If they do not, the acceptance is the existing
authorizer test suite passing from the binding against its recorded fixtures, with the gap
named. In both cases the stock `shikigami-worker` given `authorization.actions.mode=kikan`
must refuse at startup with a message naming `kikan-shikigami-worker`, and a unit test must
cover `toAgentAction` for every constructor of `Action`.

M3 is accepted per output kind, each through `kikan-shikigami-worker`. `rei.action` runs
against the real Rei started by `run-rei.sh`. `kizashi.signal` and `danwa.conversation` run
against the real services if they start, and otherwise against their existing client tests.
`kawa.digest` and `channel.egress` run against `kikan-shikigami stub-kawa` and
`stub-kanmon`; those are stubs, so they are supporting evidence. Each run's
`sink_deliveries` receipt and action-record entries must match a run of the same agent on
the pre-move build. The stock `shikigami validate agents/…` of a declaration naming
`kizashi.signal` must fail with the list of registered kinds. A declaration with no
`outputs` run through `kikan-shikigami-worker` must produce exactly one Kawa digest at the
stub, and the same declaration with an explicit `rei.action` must produce none.

M4 is accepted when `tests/objective-trackers/run-rei.sh` passes from the binding against
the real disposable Rei, and `shikigami-core` builds without `rei-api-*`.

M5 is accepted when, with the global Redpanda reachable (`rpk cluster info --brokers
127.0.0.1:9092`), `kikan-shikigami publish-fixture` puts one activity envelope on
`activity.v1`, `kikan-shikigami-consume-stream` enqueues a run for the matching agent, and
the distribution worker completes it: the living loop of `docs/user/living-loop.md`, from
the distribution. The broker is real; the Kawa on the other side is the stub. A conversation
turn is accepted against a real Danwa if it starts, and otherwise by the moved conversation
tests in `test-postgres`. `cabal build shikigami-workers shikigami-server` must show no Kafka
library in their plans.

M6 is accepted when both measurement commands print 0; the fitness rule fails on a planted
`import Rei.Client` in `shikigami-core` and passes after its removal; a finished
distribution run's evidence contains its record events; the portability check prints
matching actions that differ only in authority and in the default output, as shown above;
and the ADR and the documentation updates are merged.

Proposed, not required: a Nix package for the distribution, a live Meibo directory source,
and Kikan-En actions for declared tools and coding agents.


## Idempotence and Recovery

Each milestone is a small number of commits that build and pass on their own. Moves use
`git mv` so history follows the files. A failed move is reverted with `git revert`; no data
migration is involved and no table moves, so a database migrated at any point stays valid
for every build. The measurement, fitness and gate commands are read-only. If
`just keiro-gate` reports a body change in M2, M3 or M4, a label or patch order moved by
accident: restore it rather than accept the finding. Before switching a local worker to a
build with a moved shape, drain its non-terminal runs. Stop any service or worker this plan
started by its recorded pid. Never delete the Shikigami database to recover.

The riskiest step is removing the stock consumers in M5. It is one commit, last in the
milestone, after the distribution's consumers have passed the living-loop run; reverting it
restores the stock executables with no other change.


## Interfaces and Dependencies

Hard prerequisites: EP-5 and EP-8 must be Complete. From EP-5 this plan needs
`Shikigami.Flow.Pack.FlowPack`, the two SDK components, the role entry points
`agentRunRoleInfoWith`, `workerRoleInfoWith` and `runAdminWith`, and the `kernel boundary`
test group. From EP-8 it needs `Shikigami.Authority` (`Action`, `Authority`),
`Shikigami.Record`, `Shikigami.Output` (`OutputAdapter`, `OutputKind`, `DefaultOutput`,
`mkOutputRegistry`),
`Shikigami.Approval.Channel`, `Shikigami.Trigger`, the `FlowPack` fields for output and
approval adapters, and the portability declaration with its comparison command. EP-6 is a
soft prerequisite: its `kikan-shikigami` distribution, its trigger-hook, verb
and setting-decoder fields on `FlowPack`, and its organizational packs (watchdog, unrequested
work and practice review; adaptive delivery stays in the kernel). Where EP-6 has not
landed a field this plan needs, extend EP-5's type and record it; never define a parallel
type.

What this plan expects to add to `shikigami-core:pack-sdk`, each recorded when added: the
output intent, delivery receipt and grant types; the directory read view; the run-job
enqueue functions of `Shikigami.Trigger.Enqueue`; the tracker `Provider` record and its
types; the workflow registry type and the session and memory operations the conversation
loop uses; the run-evidence append; and the record read view.

What this plan adds to `FlowPack`: `trackerProviders`, an authority registration by name,
and an intake registration for stream and event trigger kinds.

Interfaces it publishes: `Kikan.Shikigami.Binding.kikanBinding` and
`loadKikanBindingConfig`; the executables `kikan-shikigami-worker`,
`kikan-shikigami-scheduler`, `kikan-shikigami-consume-stream`,
`kikan-shikigami-consume-events`, `kikan-shikigami-server`, `kikan-shikigami` and
`kikan-shikigami-agent-run`; and `packs/kikan-shikigami-binding/dhall/Outputs.dhall`.

What EP-11
(`docs/plans/136-freeze-the-v1-api-baseline-with-a-surface-inventory-and-compatibility-checks.md`)
freezes from here, all in its second freeze, the kernel baseline: the `pack-sdk` export list
as extended above; the binding's output kinds and their Dhall helpers as a `provisional`
surface owned by the binding, not the kernel; the distribution's default output; the setting
keys; and the rule that the stock packages link no Kikan client. EP-11's first freeze, the
declaration baseline, may precede this plan. After it, no milestone here may change the
agent declaration, its journal codec, the playbook format, the operator files or the stock
local-work commands; a need to do so is raised with the MasterPlan, not worked around.

External libraries, located with `mori registry show <project> --full` rather than from
memory: `kikan-en-client` and `kikan-en-contract` (`mori://shinzui/kikan-en`), `shomei-client`
(`mori://shinzui/shomei`), `danwa-api` and `danwa-client` (`mori://shinzui/danwa`),
`rei-api-client` and `rei-api-contract` (`mori://shinzui/rei`), keiro for the workflow
registry and the gate (`mori://shinzui/keiro`), and `kafka-effectful` with the Shibuya Kafka
adapter for intake. Their pins stay in this repository's `cabal.project`, which the
distribution builds under.

Revision note (2026-11-15, user decision): the adaptive-delivery coordinator stays in the
kernel, so this plan, not EP-6, adds the `workflows` pack field for the Danwa conversation
family.
