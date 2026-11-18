---
id: 136
slug: freeze-the-v1-api-baseline-with-a-surface-inventory-and-compatibility-checks
title: "Freeze the v1 API baseline with a surface inventory and compatibility checks"
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
      at: 2026-11-15T14:45:00Z
      mode: "other"
      note: "Drafted plan body under MasterPlan 22"
    - model: "claude-fable-5-2"
      harness: "claude-code"
      at: 2026-11-15T15:08:44Z
      mode: "update"
      note: "Two-step freeze: declaration baseline then kernel baseline (user decision 2026-11-15)"
    - model: "claude-fable-5-2"
      harness: "claude-code"
      at: 2026-11-16T05:08:52Z
      mode: "implement"
      note: "M1: surface inventory, api-baseline tool with six checks, eight surfaces pinned in report mode, exposure measurement"
    - model: "claude-opus-5-5"
      harness: "claude-code"
      at: 2026-11-17T21:21:43Z
      mode: "implement"
      note: "EP-11 M3 accepted: 6 surfaces registered, ExposedSet check, private internal library exposing 273 modules, kernel-label check, K1-K8 audit"
    - model: "claude-opus-5-5"
      harness: "claude-code"
      at: 2026-11-18T04:40:16Z
      mode: "implement"
      note: "M2 accepted: declaration baseline frozen at c54933b5; corpus loaders hardened (0e26cf31); real runs on kanmon"
---

# Freeze the v1 API baseline with a surface inventory and compatibility checks

This ExecPlan is a living document. The sections Progress, Surprises & Discoveries,
Decision Log, and Outcomes & Retrospective must be kept up to date as work proceeds.
If durable project context changes, update or create ADRs in docs/adr/ in the same change.
Record friction met while implementing in the friction-log bundle as it occurs (see FRICTION.md).


## Purpose / Big Picture

Shikigami is being rebuilt as a small kernel that other people and other packages write
against: agent declarations in Dhall, playbooks, operator files, a pack SDK, kernel ports, an
HTTP API, a durable wire format and a handful of commands. Today none of those surfaces is
named in one place, none has a stated owner or stability promise, and nothing fails when one
changes by accident. `shikigami-core` exposes 357 modules, so in practice everything is
public.

After this plan, one checked-in inventory lists every public surface with its owner, its
stability level and the rule a change must obey. One command, `just api-baseline`, checks all
of them. If someone renames a field in `schema/Agent.dhall`, removes an export from the pack
SDK, drops an HTTP route or changes a documented command's options, the command fails and its
message says what was broken, which rule applies and how to make the change deliberately. The
plan then freezes the result as the v1 baseline, in two steps, and ends the pre-release
exception that has let this initiative replace shapes without compatibility code.

The work starts now, before the other plans land. Its first milestone wires the inventory and
the checks against today's surfaces in report-only mode, so drift is visible while the kernel
is still being rebuilt and each owning plan can register its surface as it ships.

The first freeze is the *declaration baseline*. It covers what an operator writes and types
every day: the agent declaration and its journaled form, the playbook format, the operator
files, the `local.report` output helper and the stock commands used for local work. It
happens as soon as the campaign has run on a second repository, so the operator's routine
agents and playbooks stop breaking while the core is still being restructured. The second
freeze is the *kernel baseline*. It covers what a pack or a service writes against: the pack
SDK, the kernel ports, the durable wire, the HTTP API, the Kikan output helpers and the admin
command. It happens after the use-case subsystems and the Kikan bindings have left the core,
and it is the moment the pre-release exception ends.

This is EP-11 of
[MasterPlan 22](../masterplans/22-rebuild-shikigami-as-a-kernel-where-use-cases-are-declared-not-coded.md).
It owns that plan's fourth acceptance test, "Baseline", and its "Public surfaces" list.


## Progress

- [x] M1 (2026-11-16): the inventory `api-baseline/surfaces.dhall` and the Haskell tool
  `api-baseline` exist. `just api-baseline` reports on today's surfaces without failing, a
  deliberate edit to `schema/Agent.dhall` shows up as drift in the report and fails under
  `--enforce`, and the exposed-module measurement is recorded.
  - Evidence, commit `b068bf0d`. `just api-baseline` prints
    `api-baseline: 8 surfaces, 8 report-only, 0 enforcing` and eight `clean` lines
    (`agent-declaration`, `agent-journal-codec`, `cli-shikigami-agent-run`, `http-api`,
    `durable-wire`, `cli-shikigami`, `flow-sdk`, `pack-sdk`) in about 17 seconds, keiro gate
    included, and exits 0.
  - With `delegationBudget : Optional Natural` renamed to `delegationLimit` in
    `schema/Agent.dhall`, the report shows `agent-declaration  provisional  BREAKING` with the
    hash change and, for each of the three corpus files, `no longer loads:` followed by
    `Error: Expression doesn't match annotation` and `{ - delegationLimit : …`, then the rule,
    the provisional policy and `just api-baseline-pin agent-declaration`. The run exits 0.
    `just api-baseline --enforce --only agent-declaration` exits 1. After restoring the file
    both surfaces are `clean` again. `agent-journal-codec` reports `BREAKING` for the same
    edit, because it cannot load the declarations it compares.
  - `cabal test api-baseline-test` passes 39 tests on synthetic input: every `OpenApiChange`
    rule, a removed and an added export, a removed constructor, a removed option and a removed
    subcommand, a corpus file that fails to load, a journal golden that no longer decodes, and
    that `verdict` never fails a `Report` surface.
  - `api-baseline exposure` prints
    `exposure: 388 exposed, 239 needed by a consumer, 149 exposed but unneeded`.
  - The package-architecture and kernel-boundary groups of `shikigami-core-test` pass (17
    tests), `just haskell-conventions` passes, `nix/qualification/cohort.json` is unchanged and
    `.#packages.aarch64-darwin.shikigami-worker.drvPath` evaluates.
- [x] M2 (first freeze, the declaration baseline): the agent declaration, its journal codec,
  the playbook format, the operator files, the `local.report` helper and the stock
  local-work commands are registered by their owners, pinned and enforcing. A deliberate
  breaking edit to each is caught, an additive one re-pins cleanly, the commit is recorded,
  and the routine agent and the campaign's one-step playbook run for real on the frozen
  declaration surface.
  - Evidence, 2026-11-17. The freeze is `c54933b5`, and `0e26cf31` hardens its corpus loading.
    `just api-baseline` reports 19 surfaces, 8 enforcing, all clean; `git tag --list` is
    empty.
  - Breaking edits caught, each exiting 1 and then reverted:
    - renaming `trigger` in `schema/Agent.dhall` (stable policy text)
    - removing the `Probe` step kind from `schema/Playbook.dhall`
    - renaming `identity` in `schema/LocalOperator.dhall`
    - an `AgentDecl` decoder that drops the `name` key, failing every stored golden
    - removing `shikigami-local run --in`, which reports the provisional policy because
      that CLI froze as provisional
  - Additive change: a new exported helper in `schema/Agent.dhall` reports CHANGED, and
    `just api-baseline-pin agent-declaration` makes it clean. A defaulted field added to the
    Dhall schema alone is correctly BREAKING, because the runtime decodes into `AgentDecl`;
    a real new field lands in both in one commit. The same experiment on
    `schema/LocalOperator.dhall` showed the check had only evaluated non-agent corpora. It
    now loads each through its runtime loader (FRIC-118, `0e26cf31`).
  - Real runs on the frozen surface, each confirmed once by the user:
    - `agents/playbooks/mori-status-agent.dhall` on kanmon (run `f352af57-…`) ran the
      declared `mori status --json`, recorded 2 approved decisions and 0 refused, and
      stopped on mori's exit 1, as kanmon's pre-freeze readiness probe did.
    - The routine coder agent `repo-digest`, created by `shikigami-local new --coder`, ran
      by hand in kanmon (run `ebf038f8-…`). It changed nothing and delivered its report
      through the composition default (`output.delivered`).
  - Kernel surface still free: removing `PackGauge` from `Shikigami.Pack.Sdk` prints a
    pack-sdk finding and exits 0.
  - Friction: FRIC-116 to FRIC-119.

- [x] M3: every remaining surface is registered in report mode, `shikigami-core` exposes only
  what the SDK and the sibling packages need, the core keiro specification holds kernel
  labels only, and the audit of invariants K1 to K8 and the three requirements is checked in
  with evidence from real runs in both compositions.
  - Evidence, 2026-11-17 (`bc5c1a39`, `b931599f`, `1c235f7b`, `e986252f` and the split
    commit). `just api-baseline` reports 14 surfaces, all clean: the M1 eight plus
    `kernel-ports`, `pack-service-ports`, `kikan-output-helpers`, `kikan-output-dhall`,
    `pack-declaration-codec` and `core-exposed-modules`. `api-baseline exposure` prints
    `273 exposed, 273 needed by a consumer, 0 exposed but unneeded` (343, 250 and 93 before).
    `api-baseline-test` passes 44 cases, including the kernel-label check on synthetic and
    real input and the empty-pin regression. The audit is
    `docs/architecture/kernel-invariants.md`. After the split, core unit 742 of 743 (the
    HTTP-timing flake passes alone), core postgres 549/549, workers 294 with the known Git
    flake, server 96, agent 42, api 35, client 9, migrations 9, binding 82, distribution
    44, packs 14, 79, 115 and 120; kernel fitness 10/10 and conventions pass.
- [ ] M4 (second freeze, the kernel baseline): the pack SDK, the kernel ports, the durable
  wire, the HTTP API, the Kikan output helpers and the admin command are pinned and
  enforcing. A deliberate breaking edit to each is caught, the end of the pre-release
  exception is recorded at a named commit with the tag, the baseline ADR is accepted, and a
  pilot declaration runs for real on the frozen build in both compositions.

## Surprises & Discoveries

- Observation: The HTTP contract already has a staleness check, but not a compatibility
  check.
  Evidence: `shikigami-api/test/Shikigami/Api/OpenApiSpec.hs` regenerates the document and
  fails when `docs/api/openapi.json` differs. It proves the file matches the code. It cannot
  tell an additive change from a removed route, because both simply regenerate.
- Observation: `docs/capabilities-coverage.md` is an earlier census of the consumer surface.
  It counted 162 exposed core modules on 2026-10-29; the Cabal file lists 357 on 2026-11-15.
  Evidence: `awk 'NR>=39 && NR<404' shikigami-core/shikigami-core.cabal | grep -c
  'Shikigami\.'` prints 357. A hand-maintained census drifts, which is why this plan measures
  with a tool.
- Observation (M1): the core exposes 388 modules, and 149 of them have no consumer.
  Evidence: `cabal run -v0 api-baseline -- exposure` on 2026-11-16 printed
  `exposure: 388 exposed, 239 needed by a consumer, 149 exposed but unneeded`. The count was
  357 on 2026-11-15; MasterPlan 22's kernel work added the rest. A consumer here is a sibling
  package or its tests, the core's `inspection` and `local-host` sublibraries, `packs/`,
  `tools/`, `tests/` and the keiro conformance package. The core's own tests are not
  consumers, because M3 gives them the private sublibrary.
- Observation (M1): EP-5 had shipped, so its two SDK entries were registered now, in report
  mode with `freeze = Kernel`, and the inventory starts with eight surfaces instead of six.
  Their pins are `api-baseline/goldens/exports/flow-sdk.txt` and `pack-sdk.txt`, 167 names
  between them, counting constructors and fields.
- Observation (M1): the `shikigami` command has no `playbook` verbs, so there is no
  declaration-baseline entry for them. A playbook is run by `shikigami-agent-run` and
  `shikigami-local`. `cli-shikigami` pins the top-level help and 18 admin verbs, all in the
  kernel baseline.
- Observation (M1): the whole report takes about 17 seconds, because `just keiro-gate HEAD`
  finds an unchanged tree. `--only <surface>` runs one check when the gate is not wanted.


## Decision Log

- Decision (M2 preconditions, 2026-11-17): all hold. EP-1, EP-2, EP-3, EP-4, EP-8 and EP-9
  are Complete, and EP-6 accepted M1 on 2026-11-16. EP-7 accepted M3 on 2026-11-17 with the
  koyomi run `aa2b77a1-…`. Every run in the local database is terminal: the user had the
  stray EP-2 test run `7a28975f-…` (`haddock-gaps`) cancelled with `shikigami wf cancel
  --force`. Its child had failed to decode a pre-exception journal (`key "tools" not found`).
  Date: 2026-11-17

- Decision (M2 inventory): five declaration surfaces join the three from M1.
  - `playbook-bundle` covers `schema/Playbook.dhall`, against `api-baseline/corpus/playbooks`.
  - `local-operator-file` covers `schema/LocalOperator.dhall`, against `corpus/operator`.
  - `tools-ceiling` covers `schema/Tools.dhall`, against `corpus/tools`.
  - `local-output-helper` covers `schema/outputs/Local.dhall`, against `corpus/outputs`.
  - `cli-shikigami-local` pins fourteen verbs.

  There is no `shikigami-tools` executable: EP-3 shipped its commands as `shikigami-local
  tools`, `mcp` and `gate`. So the `shikigami-local` surface stands for it, with `gate` and
  `tool-attempt` left out as internal hooks.

  The `playbook` verbs are `shikigami-local playbook validate`. Plan 132 names a `shikigami
  playbook` admin verb, but EP-4 did not ship one.

  `schema/Routine.dhall` is checked through `corpus/agents/repo-digest.dhall`.

  The corpus holds real declarations only:
  - the campaign agent and bundle with their tools and catalog
  - the four `agents/playbooks` bundles
  - the one-step `mori-status` bundle and agent, which plan 132 describes and this milestone
    added under `agents/playbooks/`
  - `repo-inventory-coder`
  - a routine coder agent and the documented `plain-note` with its local output
  - the operator's campaign approvals file and the documented pre-approval
  - the documented `mori` ceiling

  No declaration names a Kikan output or a moved flow.
  Date: 2026-11-17

- Decision (M2 freeze): eight declaration surfaces enforce.
  - Stable: `schema/Agent.dhall`, `schema/Playbook.dhall` and `schema/LocalOperator.dhall`,
    the journal codec, and the `local.report` helper.
  - Provisional: `tools-ceiling`, because the ceiling catalog has one documented use and no
    second consumer.
  - Provisional: `cli-shikigami-agent-run`, whose grant and resume options are still
    settling (FRIC-102, FRIC-105).
  - Provisional: `cli-shikigami-local`, because several verbs refuse `--help` (FRIC-117)
    and the grant and placement commands those entries call for do not exist yet.

  `just api-baseline` joins `just keiro-gate` in the justfile's gate comment and in
  `docs/workflow-versioning.md`'s "Before you merge". That document now states that the
  declaration surfaces change only compatibly, while workflow bodies stay under the exception
  until M4. Pinning four new entries that shared a placeholder hash wrote one hash into all of
  them (FRIC-116), so the hashes were set from the reported values.
  Date: 2026-11-17

- Decision: (M3, 2026-11-17) The core is split as planned: every module is compiled in a
  private `library internal`, and the main `library` re-exports exactly the modules a
  consumer imports, generated by `api-baseline exposure --needed` (273 of 343 previously
  exposed; 0 exposed but unneeded). The core's sublibraries (`inspection`, `flow-sdk`,
  `pack-sdk`, `local-host`) and its four test suites depend on `shikigami-core:internal`.
  Consumers counted are the sibling packages and their tests, the core's public
  sublibraries, the packs, the tools, `tests/`, the keiro conformance package and the core
  test modules a pack's suite compiles (`borrowedCoreSources`: the watchdog pack borrows 21,
  which alone added 23 needed modules). A new `ExposedSet` check kind pins the main
  library's exposed set as `core-exposed-modules`: a hidden module is `Breaking`, a newly
  exposed one `Changed`. The package-architecture rules read the internal library's
  dependencies as the core's production library, and an `ExportList` on a main library also
  finds interfaces in its sublibraries, preferring them over interfaces left from before
  the split. The fallback (`other-modules`) was not needed: `cabal build all`, every test
  suite and the Nix evaluation of `shikigami-worker` pass.
  Date: 2026-11-17

- Decision: (M3, 2026-11-17) Pack declarations get their own kernel-freeze surface,
  `pack-declaration-codec`: a `JournalCodec` over `api-baseline/corpus/packs`, one declaration
  per flow pack (`objective-example`, `proposer`, `architecture-practice-router`,
  `watchdog`), copied with only import paths changed. They stay out of the
  `agent-declaration` corpus, which by the M1 decision holds only declarations that name no
  moved flow and no Kikan output, because that corpus belongs to the first freeze.
  Date: 2026-11-17
- Decision: (M3) The audit of K1 to K8 and the three requirements is
  `docs/architecture/kernel-invariants.md`. Its real-run evidence is plan 135's M6 pair
  (`portable-note` under `shikigami-agent-run` local-operator and under
  `kikan-shikigami-agent-run` contained), plus EP-8 M3's real-model pair; it records the
  partial entries (K1 file directory, K2 IR-5, K5 lease-only ordinary runs, K6 adapter
  deduplication) and the architectural requirement as not accepted.
  Date: 2026-11-17

- Decision: (M3, 2026-11-17) Four surfaces join the inventory in report mode, each in the
  kernel freeze: `kernel-ports` (EP-8's `Shikigami.Approval.Channel`, `Shikigami.Authority`,
  `Shikigami.Authority.Adapter`, `Shikigami.Output`, `Shikigami.Output.Registration`,
  `Shikigami.Record`), `pack-service-ports` (EP-10's `Shikigami.Agent.Conversation.Channel`
  and `Shikigami.Objective.Tracker.Provider`), `kikan-output-helpers` (the export list of
  `kikan-shikigami-binding:outputs`) and `kikan-output-dhall` (the binding's
  `dhall/Outputs.dhall`, with a corpus of the three Kikan sample declarations under
  `api-baseline/corpus/kikan`). The distribution's default output is not a separate surface:
  no check kind observes a composition's default, and `run.admitted` records it per run.
  `ExportList.component` accepts `package:library` for a sublibrary, whose interfaces Cabal
  writes under `l/<library>/build/<library>`.
  Date: 2026-11-17
- Decision: (M3) `pin` refuses a schema entry whose pinned hash is empty, and writes the
  inventory beside itself and renames it. Pinning `kikan-output-dhall` with an empty hash had
  truncated `surfaces.dhall` to zero bytes: replacing the empty string failed after the file
  was opened for writing. A regression test pins an empty hash into a scratch inventory and
  requires the file unchanged.
  Date: 2026-11-17

- Decision: `cli-shikigami` was re-pinned on 2026-11-16 after `shikigami danwa-spike` was
  removed, the first breaking finding the inventory recorded.
  Rationale: the removal is an approved removal of plan 131 (M1), whose Decision Log holds the
  reason. The surface is provisional and report-only, so the policy asks for this entry and
  the re-pin in the same commit (`2965ac6e`).
  Date: 2026-11-16
- Decision: Export lists are read as names from GHC interface files, with constructors and
  fields as `Type.member`. Hoogle text is not adopted.
  Rationale: the bounded prototype was a two-module scratch package with a facade that only
  re-exports. `cabal haddock --haddock-hoogle` listed the re-exported names under the facade
  module with their signatures, so Hoogle does see same-package re-exports. Adopting it for
  the core needs documentation built for the whole dependency closure: the same command on
  `shikigami-core` had built documentation for 257 dependencies and had not reached the core
  when the scratch package had already answered the question, and it was stopped. An
  interface file exists after any build and also lists names re-exported from other packages
  (`Eff`, `step`), which the SDK facades do. Signatures can be reconsidered in M3 if a type
  change behind an unchanged name proves to be a real gap.
  Date: 2026-11-16
- Decision: `DhallSchema` decides only whether each corpus file still loads; whether it loads
  to the same value is decided by `JournalCodec`, whose golden is the declaration's JSON.
  Rationale: the plan gave both checks a stored golden of the loaded value. One golden per
  declaration is enough, and the journal encoding is the one that must survive. The schema
  entry needs no artifact beyond its hash.
  Date: 2026-11-16
- Decision: A schema's pinned hash stays a field of the inventory entry, and `pin` rewrites
  that one string in `surfaces.dhall`. Everything else `pin` writes is a file under
  `api-baseline/goldens/` or `api-baseline/frozen/`.
  Rationale: the plan's `Surface` type carries the hash inline, and a reviewer sees a schema
  change as one changed line beside the entry's rule. `pin` never edits `stability` or `rule`.
  Date: 2026-11-16
- Decision: A check that cannot run exits 2 and is never reported as clean. `check` also
  takes `--only <surface>`, repeatable.
  Rationale: an executable that is not built, a missing interface file or an empty corpus
  would otherwise read as "no findings". Exit 1 stays reserved for a finding on an enforcing
  surface. `--only` keeps the demonstration and a pin review fast.
  Date: 2026-11-16
- Decision: The M1 corpus is three real stock declarations that name no Kikan output and no
  moved flow: `repo-inventory`, `local-maintainer` and `coding-agent-example`, copied from
  `agents/` with only the schema import path changed. M2 fills the corpus.
  Rationale: the plan's example named `triage-note`, which declares a Kizashi sink and is
  excluded from the first freeze by this plan's own rule.
  Date: 2026-11-16
- Decision: The inventory is a Dhall file at `api-baseline/surfaces.dhall`, typed by
  `api-baseline/Surface.dhall`, with the frozen artifacts beside it under
  `api-baseline/frozen/` and the declaration corpus under `api-baseline/corpus/`.
  Rationale: Dhall is already the repository's declaration language and Haskell decodes it
  with the `dhall` library the core depends on. A closed union for the stability level and the
  check kind makes an unknown value a type error instead of a silently skipped surface.
  Date: 2026-11-15
- Decision: The checks are one Haskell executable, `api-baseline`, in a new package
  `tools/api-baseline` whose name has no `shikigami-` prefix.
  Rationale: `AGENTS.md` prefers Haskell for new tooling, and the checks need the real
  decoders (`Shikigami.Agent.Loader`, the `AgentDecl` codec, the generated OpenAPI value)
  rather than a second model of them. The package count test and the frozen Nix closure
  recognize the seven deployment packages by that prefix
  ([ADR-39](../adr/0039-deployment-roles-share-a-frozen-cabal-source-closure.md)), so an
  unprefixed tool package stays outside both, the same way the MasterPlan's flow packs do.
  Date: 2026-11-15
- Decision: A semantic hash of a schema reports that it changed; a corpus of declarations
  decides whether the change broke anything.
  Rationale: A new field with a default changes the hash and breaks nobody. Treating every
  hash change as breaking would train contributors to re-pin without thinking. The hash makes
  the change a reviewed line in a diff, and the corpus is the compatibility rule.
  Date: 2026-11-15
- Decision: The enforcement mode is a field of each inventory entry, `Report` or `Enforce`.
  Each entry also names the freeze it belongs to, and each freeze flips its own entries in
  one commit.
  Rationale: The other plans are still changing their surfaces under the pre-release
  exception. Report mode makes drift visible to them without blocking a change they are
  entitled to make.
  Date: 2026-11-15
- Decision: The baseline freezes in two steps. The first, the declaration baseline (M2),
  covers `schema/Agent.dhall` and the `AgentDecl` journal codec, `schema/Playbook.dhall`,
  `schema/LocalOperator.dhall`, `schema/Tools.dhall`, the `local.report` output helper and
  the stock commands used for local work (`shikigami-agent-run`, `shikigami-local`,
  `shikigami-tools` and the `shikigami playbook` verbs). The second, the kernel baseline
  (M4), covers `shikigami-core:flow-sdk` and `shikigami-core:pack-sdk`, the kernel ports, the
  durable wire, the HTTP API, the Kikan output helpers and the rest of the `shikigami` admin
  command. Only the second ends the ADR-27 pre-release exception, creates the tag and writes
  the ADR.
  Rationale: The user decided on 2026-11-15 to "freeze in two steps". One freeze at the end
  left the surfaces the operator uses daily changeable for the whole initiative, behind the
  core shrink (EP-6) and the Kikan move (EP-10). Two steps stop routine agents and playbooks
  from breaking as soon as the campaign has proved them, while the surfaces that are still
  moving with the restructuring freeze when it is done.
  Date: 2026-11-15
- Decision: Between the two freezes the drain rule still governs workflow bodies, and a
  frozen declaration surface may change only by a compatible path.
  Rationale: EP-6 and EP-10 remove step labels and patch gates and change the SDK after the
  first freeze, which they may do while every run is drained first. What they may not do is
  change the declaration, its codec, the playbook format, the operator files or a stock
  local-work command without a default, a decoder for the old bytes or a kept option. The
  first freeze therefore makes ADR-11 unconditional for `AgentDecl` early: a journal written
  after it must keep decoding. The first freeze creates no tag, because sibling plans still
  read an empty `git tag --list` as evidence that workflow bodies may change.
  Date: 2026-11-15
- Decision: The first freeze's corpus holds only declarations that the stock composition
  loads and that no later plan moves. Declarations that name a Kikan output or a flow that
  leaves the core join the corpus at the second freeze.
  Rationale: EP-10 moves `agents/heartbeat.dhall`, `agents/danwa-heartbeat.dhall` and
  `agents/triage-note.dhall` with the Kikan helper file, and EP-6 moves the flows that the
  manifests under `agents/proof/` name. Pinning them first would make each of those planned
  moves a breaking finding against a frozen surface.
  Date: 2026-11-15
- Decision: The exposed-module target is derived, not chosen: the set of core modules that a
  sibling package, a pack, the SDK components or the conformance package imports.
  Rationale: Any number picked today would be a guess. The tool computes the set from the
  tree, so the target follows the code and the measurement can be repeated.
  Date: 2026-11-15


## Outcomes & Retrospective

(To be filled during and after implementation.)


## Context and Orientation

Shikigami is a Haskell monorepo of seven Cabal packages listed in `cabal.project`:
`shikigami-core` (the domain library and durable workflows), `shikigami-api` (HTTP route
types), `shikigami-server` (the HTTP server and the `shikigami` admin command),
`shikigami-workers` (the worker, scheduler and stream consumers), `shikigami-agent` (light
one-off commands), `shikigami-client` and `shikigami-migrations`. Work inside the development
shell (`nix develop` or direnv). Records use unprefixed strict fields under
`DuplicateRecordFields`, following
`mori://shinzui/haskell-jitsurei/docs/core-record-patterns`.

MasterPlan 22 turns `shikigami-core` into a kernel. Its sibling plans add or change the
surfaces this plan freezes. None had started when this plan was written, so every name below
that belongs to a sibling is that sibling's to finalize; when a landed name differs, use the
landed one and record the mapping in the Decision Log. The siblings, by their MasterPlan
label and file, are: EP-1 `docs/plans/126-…` (the `LocalOperator` trust tier and
`schema/LocalOperator.dhall`), EP-2 `docs/plans/127-…` (the `CodingAgent` behavior), EP-3
`docs/plans/128-…` (declared tools and `schema/Tools.dhall`), EP-4 `docs/plans/129-…`
(playbooks and `schema/Playbook.dhall`), EP-5 `docs/plans/130-…` (the pack SDK and the kernel
fitness check), EP-6 `docs/plans/131-…` (moving use-case subsystems into packs), EP-7
`docs/plans/132-…` (the keiro modernization campaign, the pilot), EP-8 `docs/plans/133-…`
(the kernel ports), EP-9 `docs/plans/134-…` (routine agents) and EP-10 `docs/plans/135-…`
(the Kikan binding and distribution).

A *public surface* is a contract that someone outside the kernel writes against. The
MasterPlan names eight:

- The agent declaration: `schema/Agent.dhall`, decoded into `AgentDecl` in
  `shikigami-core/src/Shikigami/Agent/Decl.hs` by `shikigami-core/src/Shikigami/Agent/Loader.hs`.
- The playbook format: `schema/Playbook.dhall` (EP-4).
- The operator files: `schema/LocalOperator.dhall` (EP-1) and `schema/Tools.dhall` (EP-3).
- The pack SDK: two public Cabal sublibraries of `shikigami-core`, `flow-sdk` and `pack-sdk`
  (EP-5). A *sublibrary* is a named library stanza inside one Cabal package; a package that
  depends on `shikigami-core:flow-sdk` can import only the modules that stanza lists.
- The kernel ports: the modules `Shikigami.Authority`, `Shikigami.Record`,
  `Shikigami.Output`, `Shikigami.Approval.Channel` and `Shikigami.Trigger` (EP-8), exported
  through the pack SDK. A *port* is a kernel-owned interface whose implementation, an
  *adapter*, is chosen when an executable is composed.
- The durable wire: workflow journals, the `run_jobs` payload and the aggregates declared
  under `domain/`. `just keiro-gate <revision>` already checks it. keiro is the durable
  workflow library (`mori://shinzui/keiro`); a *journal* is the stored list of a workflow's
  step results, and a step's *label* is the name a replay matches on.
- The HTTP API: `docs/api/openapi.json`, generated by `cabal run shikigami-openapi` from
  `shikigami-api/src/Shikigami/Api/OpenApi.hs`.
- The operator CLI: `shikigami`, `shikigami-agent-run`, and the sibling plans' new
  `shikigami-local` and `shikigami-tools`.

There is a ninth, which the others imply: the journaled JSON form of `AgentDecl`. The
agent-run workflow's `lookup-agent` step stores the decoded declaration in the journal, and
the JSON instances in `Decl.hs` strip defaulted fields by hand. A schema change is therefore
also a codec change, and a codec change can make a stored journal undecodable even when every
Dhall file still loads.

Existing gates this plan builds on rather than replaces: `just keiro-gate` (the durable
wire), `just haskell-conventions` (`tools/style/check_haskell.py` and
`tools/style/module-ownership.json`, the closed list of namespace roots),
`just domain-value-types`, `just user-docs-validate`, and
`shikigami-core/test/Shikigami/PackageArchitectureSpec.hs`, which enforces the legal
dependency arrows between the seven packages. The existing Python checks stay as they are;
`AGENTS.md` asks only that new tooling be Haskell.

The MasterPlan defines eight invariants, K1 to K8, that must hold in every composition: every
action carries a principal (K1); one authority port decides every external action and fails
closed (K2); every decision and effect is appended to an action record the agent cannot write
(K3); a run pins the exact declaration it executes (K4); every run spends under a resource
root with deadlines and budgets (K5); effects happen in journaled steps and an uncertain
effect is never retried automatically (K6); observed content is evidence, never instruction
(K7); and run admission is idempotent (K8). It also sets three requirements: routine agents
are easy to declare, Kikan's organizational requirements stay reachable, and the APIs are
right before wide adoption. A *composition* is a set of executables built from the kernel
plus adapters: the *stock composition* is the seven packages with local adapters, and the
*Kikan distribution* adds the Kikan service bindings and organizational packs.

The *pre-release exception* is the rule in
[ADR-27](../adr/0027-the-first-release-establishes-one-clean-durable-baseline.md) and
`docs/workflow-versioning.md` ("The one pre-v1 baseline exception"). While Shikigami has no
users, no journals that must resume, no stored payloads needing an old codec and no external
wire consumers, a plan may replace an unreleased declaration or workflow shape directly. The
MasterPlan's Decision Log (2026-11-15) says the exception ends at this plan's baseline gate,
and that until then every real run is drained to a terminal state before a shape change.

Relevant ADRs:
[ADR-1](../adr/0001-declare-only-what-the-runtime-executes.md) says to declare only what the
runtime executes, so the inventory lists a surface only once its owner has shipped it.
[ADR-11](../adr/0011-defaulted-agent-fields-preserve-journal-codec-compatibility.md) and
[ADR-12](../adr/0012-a-declared-workflow-body-only-grows-behind-a-patch.md) are the rules
that become unconditional when the exception ends: additive declaration fields preserve
journal bytes, and a workflow body grows only behind a `patch`.
[ADR-27](../adr/0027-the-first-release-establishes-one-clean-durable-baseline.md) is the
exception itself.
[ADR-39](../adr/0039-deployment-roles-share-a-frozen-cabal-source-closure.md) fixes the
seven-package closure the tool package must stay outside.
[ADR-75](../adr/0075-service-composition-has-a-closed-reviewed-module-budget.md) is the
closed module budget; it is per namespace root and says nothing about which modules are
exposed, so the exposure work in M3 is a new check beside it.
[ADR-122](../adr/0122-deliberate-mutations-use-a-separate-haskell-tool-and-owning-tests.md)
is the precedent for a separate Haskell tool with tests in the owning packages.


## Plan of Work

### Milestone 1: the inventory and a report-only harness (no prerequisite)

At the end of this milestone `just api-baseline` runs every check that today's tree can
support and prints a report. Nothing is blocked yet.

Create `api-baseline/Surface.dhall`, the type of the inventory, and
`api-baseline/surfaces.dhall`, the inventory itself:

```dhall
-- api-baseline/Surface.dhall
let Stability = < Stable | Provisional | Internal >
let Enforcement = < Report | Enforce >
let Freeze = < Declaration | Kernel >   -- which of the two freezes pins this surface
let Check =
      < DhallSchema : { schema : Text, hash : Text, corpus : Text }
      | ExportList : { component : Text, modules : List Text, pinned : Text }
      | OpenApi : { current : Text, frozen : Text }
      | CliHelp : { executable : Text, verbs : List (List Text), goldens : Text }
      | JournalCodec : { corpus : Text, goldens : Text }
      | KeiroGate : { since : Text }
      >
let Surface =
      { name : Text            -- stable identifier, e.g. "agent-declaration"
      , owner : Text           -- repository-relative path of the owning plan
      , stability : Stability
      , rule : Text            -- the compatibility rule, in one sentence
      , check : Check
      , freeze : Freeze
      , enforcement : Enforcement
      }
in  { Stability, Enforcement, Freeze, Check, Surface }
```

An entry for a surface that already exists looks like this. `hash` is the Dhall semantic
hash of the normalized schema, the value `dhall hash --file schema/Agent.dhall` prints:

```dhall
{ name = "agent-declaration"
, owner = "docs/masterplans/22-rebuild-shikigami-as-a-kernel-where-use-cases-are-declared-not-coded.md"
, stability = S.Stability.Provisional
, rule = "Every declaration in the corpus keeps loading to the same value; a new field has a default."
, check = S.Check.DhallSchema
    { schema = "schema/Agent.dhall", hash = "sha256:…", corpus = "api-baseline/corpus/agents" }
, freeze = S.Freeze.Declaration
, enforcement = S.Enforcement.Report
}
```

Register the surfaces that exist today: the agent declaration, its journal codec, the HTTP
API, the durable wire, and the `shikigami` and `shikigami-agent-run` commands. The others are
registered by their owners as they ship. The `CliHelp` check lists verbs, so one executable
can belong to both freezes: the `shikigami playbook` verbs form an entry in the declaration
baseline, and the remaining `shikigami` verbs an entry in the kernel baseline.

Create the package `tools/api-baseline` (add it to `cabal.project` `packages:`), with a
library, the executable `api-baseline` and a test suite `api-baseline-test`. Its library
depends on `shikigami-core`, `shikigami-api`, `dhall`, `aeson` and `process`. Confirm that
adding it leaves `nix/qualification/cohort.json` unchanged and that the "exactly seven
packages" case in `PackageArchitectureSpec` still passes; both recognize deployment packages
by the `shikigami-` prefix. The core of the tool is pure, so each rule is testable on
synthetic input:

```haskell
-- tools/api-baseline/src/ApiBaseline/Types.hs
data Stability = Stable | Provisional | Internal
data Enforcement = Report | Enforce
data Surface = Surface
  { name :: !SurfaceName, owner :: !FilePath, stability :: !Stability
  , rule :: !Text, check :: !Check, freeze :: !Freeze, enforcement :: !Enforcement }
data Freeze = DeclarationBaseline | KernelBaseline

data Finding = Finding { surface :: !SurfaceName, severity :: !Severity, detail :: !Detail }
data Severity = Breaking | Changed   -- Changed: differs from the pin but obeys the rule
data Verdict = Clean | Drift !(NonEmpty Finding) | Broken !(NonEmpty Finding)

loadInventory :: FilePath -> IO (Either InventoryError [Surface])
checkSurface  :: Surface -> IO [Finding]
verdict       :: Enforcement -> [Finding] -> Verdict
renderFinding :: Surface -> Finding -> Text   -- names the rule and the deliberate-change path
```

Each check kind is one module with a pure comparison and a thin IO wrapper:

- `ApiBaseline.Check.DhallSchema` computes the semantic hash with the `dhall` library and
  loads every file in the corpus directory through the real loader (for agents,
  `Shikigami.Agent.Loader`). A hash that differs from the pin is `Changed`. A corpus file
  that no longer loads, or that loads to a different value than its stored golden, is
  `Breaking`.
- `ApiBaseline.Check.JournalCodec` keeps, for each corpus agent, the JSON that `AgentDecl`'s
  `ToJSON` produced when the golden was pinned. It is `Breaking` when the stored JSON no
  longer decodes to the value the Dhall file loads to, and `Changed` when re-encoding
  produces different bytes.
- `ApiBaseline.Check.OpenApi` compares the current document with a frozen copy under these
  rules. `Breaking`: a path or operation removed; a response status removed; a property
  removed from a response schema; a property's type changed; a request property added as
  required; an enumeration value removed from a response. `Changed`: any other difference.
  The rules are a closed sum `OpenApiChange`, so the report names the one that fired.
- `ApiBaseline.Check.CliHelp` runs each listed verb of a built executable with `--help` and
  compares with a golden file. A removed option or verb is `Breaking`; any other difference
  is `Changed`. The comparison parses the option names out of the help text for the breaking
  rule and compares whole text for the changed one.
- `ApiBaseline.Check.ExportList` compares the exported names of the listed modules with a
  pinned file. A removed name is `Breaking`; an added name is `Changed`. It reads the names
  from GHC interface files with `ghc --show-iface`, which is certain to list exports. Before
  relying on it, run a bounded prototype: try `cabal haddock --haddock-hoogle
  shikigami-core`, whose text output also carries type signatures. Adopt the Hoogle output
  only if it lists re-exported names under the SDK facade modules; otherwise keep names only
  and record the result in the Decision Log.
- `ApiBaseline.Check.KeiroGate` shells out to `just keiro-gate <since>` and maps a breaking
  keiro finding to `Breaking`.

Add the measurement command `api-baseline exposure`. It parses the `exposed-modules` of
`shikigami-core`, collects every `import Shikigami.…` in the other packages' sources, in
`packs/` and in the keiro conformance package, and prints three numbers: exposed today, needed
by a consumer, and exposed but unneeded. Record the output in Surprises & Discoveries. It
changes nothing in M1.

Add the recipes to the `Justfile`:

```just
# Check every registered public surface against its pinned baseline.
api-baseline *args:
    cabal run -v0 api-baseline -- check api-baseline/surfaces.dhall {{args}}

# Re-pin one surface after a deliberate, reviewed change.
api-baseline-pin surface:
    cabal run -v0 api-baseline -- pin api-baseline/surfaces.dhall {{surface}}
```

`check` exits 0 when every finding belongs to a `Report` surface, and non-zero when an
`Enforce` surface has any finding. `--enforce` treats every surface as `Enforce`, which is
how M1 demonstrates the failure. `pin` rewrites only the frozen artifacts of the named
surface, never the inventory's `stability` or `rule`.

Write `docs/architecture/api-baseline.md`: what a public surface is, the three stability
levels, and the stability policy below. Link it from `docs/README.md`.

The stability policy, which the failure message quotes for the level of the surface that
broke:

- `stable`: a breaking change needs a new ADR, a compatibility path (a Dhall default, a
  `patch` for a workflow body, a codec that still reads the old bytes, a deprecated route
  kept for one release) and a re-pin in the same commit. An additive change needs only the
  re-pin.
- `provisional`: a breaking change needs a Decision Log entry in the owning plan and a
  re-pin. The surface's corpus must be updated in the same commit, so the next reader sees
  what changed.
- `internal`: no check and no promise. A pack may not import an internal module; EP-5's
  fitness check enforces that.

### Milestone 2: the first freeze, the declaration baseline

Preconditions, each checked and recorded in the Decision Log with the date: EP-1, EP-2, EP-3,
EP-4, EP-8 and EP-9 are Complete; EP-6 has accepted its first milestone, which removes the
`Deterministic` arm and the `ShikumiProgram.enabledBy` field and is the last planned change
to the declaration; EP-7 has accepted its third milestone, so the declaration surface has
carried a real job on a second repository; and every run in the local database is terminal.
EP-5, EP-10 and the rest of EP-6 are not required.

As each owner ships, it adds its entry in report mode with `freeze = Declaration`:
`schema/LocalOperator.dhall` (EP-1), `schema/Tools.dhall` (EP-3), `schema/Playbook.dhall` and
the `shikigami playbook` verbs (EP-4), `schema/outputs/Local.dhall` (EP-8), `shikigami-local`
(EP-1, with EP-9's verbs), `shikigami-tools` (EP-3) and `schema/Routine.dhall` (EP-9, checked
as part of the agent-declaration corpus). This plan reviews each entry and fills any the
owner missed. The MasterPlan's schema rule applies: this plan may not change a surface it
does not own, so a defect found here is recorded against the owner.

Fill the corpus with real declarations, not fixtures written for the check: the manifests
under `agents/` that the stock composition loads, the campaign's agent and playbook files
from EP-7, EP-9's routine agents (which state no output, so the composition default applies),
and the operator files used in the pilot, with machine-specific paths left as they are, since
the loader does not resolve them. Each corpus file imports its schema by relative path, so a
schema change is exercised against it. Leave out every declaration that names a Kikan output
or a flow that EP-6 moves; those join in M4 (Decision Log).

Then freeze, in one commit: re-pin every `Declaration` surface, set its `stability` (the
three schemas, the codec and the `local.report` helper are `stable`; a command still settling
may stay `provisional` with a stated reason) and set its `enforcement` to `Enforce`. Add
`just api-baseline` to whatever recipe or checklist the repository runs before merge, beside
`just keiro-gate`. Record the commit in MasterPlan 22's Decision Log and add a paragraph to
`docs/workflow-versioning.md` stating that from this commit the agent declaration and its
journal codec change only compatibly, while workflow bodies remain under the pre-release
exception and the drain rule until the kernel baseline. Create no tag. Update
`docs/roadmap.md` and `docs/README.md`: stage 1, the pilot, complete; the declaration
baseline reached at the named commit.

### Milestone 3: the remaining surfaces, the exposed set, and the audit

As each owner ships, it adds its entry in report mode with `freeze = Kernel`:
`shikigami-core:flow-sdk` and `shikigami-core:pack-sdk` (EP-5), the five kernel port modules
(EP-8), and the Kikan output helpers and the distribution's default output (EP-10). The
durable wire, the HTTP API and the `shikigami` admin verbs were registered in M1. Add one
declaration per pack and the three Kikan-output manifests to the corpus, each loaded through
the composition that registers its kinds.

Rerun `api-baseline exposure`. The "needed" set is now meaningful, because the packs, the
Kikan binding and the SDK components exist. Make it the exposed set. The method is the
standard Cabal one and keeps the core's own tests working: move every module of
`shikigami-core` into a private sublibrary `shikigami-core:internal` (`visibility:
private`), which the main library and the core's own test suites depend on, and have the main
library, `flow-sdk`, `pack-sdk` and `inspection` list only the needed modules as
`reexported-modules`. A sibling package cannot depend on a private sublibrary, so the
compiler enforces the boundary. Add an `ExposedSet` check kind whose pin is the list of
exposed modules, so a newly exposed module is a reviewed `Changed` finding. If the private
sublibrary proves unworkable with the frozen closure or the conformance package, fall back to
moving unneeded modules to `other-modules` and giving the core test suites the source
directory directly, and record the reason.

Confirm the durable contract. After EP-6 and EP-10, `domain/shikigami/agent-run.keiro` must
declare kernel labels only. Add a case to `api-baseline-test` that reads the specification
and fails on any label whose prefix belongs to a pack (`watchdog-`, `initiative-`,
`practice-review-`, `objectives-example-`, and the route and decision labels of moved
flows), using the pack names from EP-5's kernel list in
`tools/style/module-ownership.json` rather than a second hand-written list.

Then audit the finished kernel. Write `docs/architecture/kernel-invariants.md` with one
section per invariant K1 to K8. Each section names the code that enforces the invariant, the
test that fails when it is removed, and evidence from a real run in the stock composition and
in the Kikan distribution: the run id and the action-record entries or log lines that show
it. Where an invariant holds only by convention, say so and record a gap against the owning
plan; do not paper over it. Add a second part for the three requirements, citing the
acceptance evidence of EP-9 (routine agent), EP-10 (portability) and EP-7 (architectural). A
gap that the audit finds is not this plan's to fix in the kernel, but M4 cannot be accepted
while a gap against an invariant is open.

### Milestone 4: the second freeze, the kernel baseline

Preconditions, each checked and recorded in the Decision Log with the date: the first freeze
is accepted; EP-5, EP-6 and EP-10 are Complete, which with the first freeze's preconditions
means every other child plan of MasterPlan 22 except EP-7's fan-out milestone; the audit has
no open gap against an invariant; and every run in the local database is terminal.

In one commit: re-pin every `Kernel` surface, set each entry's `stability` (the SDK, the
ports, the durable wire and the HTTP API are `stable`; the Kikan output helpers are
`provisional` and owned by the binding), and set every remaining `enforcement` to `Enforce`.
Set the `KeiroGate` entry's `since` to that commit.

Record the end of the pre-release exception. Add a Decision Log entry to MasterPlan 22
naming the commit and the four rechecked facts, replace the "Current first-release baseline
exception" paragraph of `docs/workflow-versioning.md` with a statement that the exception
ended at that commit and the rules below it are unconditional, and create the annotated tag
`api-baseline-v1` on the commit. The tag is local; push it only if the user asks. From here
on, plans that check `git tag --list` for the pre-release facts will find it.

Write the baseline ADR with the next unused number in `docs/adr/` (the directory has no OKF
profile, so the number comes from the files present): "The v1 baseline names every public
surface and a change obeys its stability level". It records the inventory and its location,
the three levels and the policy, the check per surface, the two freezes and what each
covered, the private-sublibrary boundary, and that ADR-27's exception has ended. Add a
reference line to ADR-27 and ADR-75.

Update `docs/roadmap.md` and `docs/README.md` so the three adoption stages of the
MasterPlan are visible: stage 1, the pilot, complete; stage 2, the baseline, reached in two
named commits; stage 3, organizational use through the Kikan distribution and use by anyone
other than the operator, open once Kikan-En can decide declared tools and coding-agent
launches, as the MasterPlan records. Regenerate `docs/artifacts/roadmap.html` if the
roadmap's maintenance note requires both representations to match.


## Concrete Steps

Run everything from `/Users/shinzui/Keikaku/bokuno/shikigami` inside the development shell.

Milestone 1:

```bash
cabal build api-baseline shikigami shikigami-agent-run shikigami-openapi
cabal test api-baseline-test
just api-baseline
cabal run -v0 api-baseline -- exposure
```

Expected report shape (values illustrative):

```text
api-baseline: 6 surfaces, 6 report-only, 0 enforcing
  agent-declaration        provisional  clean
  agent-journal-codec      provisional  clean
  http-api                 provisional  clean
  durable-wire             provisional  clean
  cli-shikigami            provisional  clean
  cli-shikigami-agent-run  provisional  clean
exposure: 357 exposed, <n> needed by a consumer, <357-n> exposed but unneeded
```

Demonstrate drift and the failure, then undo it:

```bash
cp schema/Agent.dhall "${TMPDIR:-/tmp}"/Agent.dhall.keep
sed -i '' 's/delegationBudget : Optional Natural/delegationLimit : Optional Natural/' schema/Agent.dhall
just api-baseline            # exits 0, reports the finding
just api-baseline --enforce  # exits non-zero
cp "${TMPDIR:-/tmp}"/Agent.dhall.keep schema/Agent.dhall
just api-baseline            # clean again
```

Expected failure text:

```text
agent-declaration (provisional): BREAKING
  api-baseline/corpus/agents/triage-note.dhall no longer loads:
    schema/Agent.dhall: expected field delegationBudget
  Rule: Every declaration in the corpus keeps loading to the same value; a new field has a default.
  This surface is provisional. A breaking change needs a Decision Log entry in its owning
  plan and an updated corpus in the same commit, then: just api-baseline-pin agent-declaration
  Policy: docs/architecture/api-baseline.md
```

Milestone 2, the first freeze, after its preconditions hold:

```bash
shikigami --config config.json runs --help       # use the listed verbs to confirm no non-terminal run
for s in $(cabal run -v0 api-baseline -- list api-baseline/surfaces.dhall --freeze declaration); do just api-baseline-pin "$s"; done
just api-baseline                                # declaration surfaces enforcing; the rest report
git tag --list                                   # still empty: the first freeze creates no tag
```

```text
api-baseline: 14 surfaces, 6 report-only, 8 enforcing (declaration baseline)
```

Milestone 4, the second freeze, after its preconditions hold:

```bash
git tag --list                                   # expect empty before the freeze
shikigami --config config.json runs --help       # confirm no non-terminal run
for s in $(cabal run -v0 api-baseline -- list api-baseline/surfaces.dhall --freeze kernel); do just api-baseline-pin "$s"; done
just api-baseline                                # every surface enforcing and clean
git tag -a api-baseline-v1 -m "Shikigami v1 API baseline" <freeze-commit>
```

Commits follow Conventional Commits and carry the trailers:

```text
feat(api-baseline): check public surfaces against a pinned inventory

MasterPlan: docs/masterplans/22-rebuild-shikigami-as-a-kernel-where-use-cases-are-declared-not-coded.md
ExecPlan: docs/plans/136-freeze-the-v1-api-baseline-with-a-surface-inventory-and-compatibility-checks.md
Intention: intention_01m7fq4tf3ejrt0tjxvsy8ejdt
```


## Validation and Acceptance

M1 is accepted on this Mac when `just api-baseline` prints the report for the surfaces that
exist today and exits 0; the renamed-field edit above appears as a `BREAKING` finding in
report mode and makes `just api-baseline --enforce` exit non-zero with the rule and the
deliberate-change path in the message; restoring the file makes it clean; and `api-baseline
exposure` prints its three numbers, which are recorded in this plan. `api-baseline-test`
covers, on synthetic input, each `OpenApiChange` rule, a removed and an added export, a
removed CLI option, a corpus file that fails to load, a journal golden that no longer
decodes, and that `verdict` never fails a `Report` surface. The package-count case of
`PackageArchitectureSpec` and `nix/qualification/cohort.json` are unchanged.

M2, the first freeze, is accepted by four observations. First, a deliberate breaking edit to
each declaration surface is caught: the renamed field in `schema/Agent.dhall`, a removed step
kind in `schema/Playbook.dhall`, a renamed field in `schema/LocalOperator.dhall`, a stored
`AgentDecl` journal golden made undecodable by a codec edit, and a removed option of
`shikigami-local run` each make `just api-baseline` exit non-zero with the `stable` policy
text, and each edit is reverted. Second, an additive change (a new defaulted field in
`schema/Agent.dhall`) reports `Changed`, and `just api-baseline-pin agent-declaration` makes
it clean. Third, a real run on the frozen declaration surface: EP-9's routine agent runs by
hand on one of the operator's repositories and writes its report through the composition
default, and EP-7's one-step playbook runs the declared `mori status --json` tool on kanmon,
both completing as they did before the freeze. Fourth, a kernel-baseline surface is still
free: removing an export from a report-mode SDK entry prints a finding and exits 0.
MasterPlan 22's Decision Log and `docs/workflow-versioning.md` name the same commit, and
`git tag --list` is still empty.

M3 is accepted when the inventory lists every surface in the MasterPlan's "Public surfaces"
list, each with an owner path that exists and a check that runs clean; `api-baseline
exposure` reports zero exposed-but-unneeded modules; `cabal build all` and `cabal test all`
pass; a scratch module in a pack that imports a non-SDK core module fails to compile; the
label case fails when a `watchdog-` label is planted in `domain/shikigami/agent-run.keiro`
and passes when it is removed; and `docs/architecture/kernel-invariants.md` cites, for each
of K1 to K8, the enforcing code, a test and a real run id in each composition. Any gap it
records is linked from the owning plan. The declaration surfaces frozen in M2 stay clean
throughout, which shows that EP-6's and EP-10's moves did not touch them.

M4, the second freeze, is accepted by four observations. First, a deliberate breaking edit
to each kernel surface is caught: a removed export from `Shikigami.Flow.Sdk`, a removed field
of a kernel port record, a removed route in the API, a removed admin verb, and a step label
removed from a kernel workflow without a `patch` each make `just api-baseline` exit non-zero
with the `stable` policy text; each edit is reverted. Second, an additive SDK export reports
`Changed` and re-pins cleanly. Third, a real run on the frozen build in each composition:
EP-9's routine agent under the stock composition, and EP-8's portability declaration under
the Kikan distribution, both completing as before. Fourth, MasterPlan 22's Decision Log,
`docs/workflow-versioning.md`, the tag and the ADR all name the same commit. This is the
MasterPlan's baseline acceptance.

Proposals that are not required here: publishing the SDK's Haddock, a semantic version
number for each surface, and running `just api-baseline` in a hosted CI service.


## Idempotence and Recovery

`just api-baseline` and `api-baseline exposure` only read. `just api-baseline-pin` rewrites
the frozen artifacts of one surface from the working tree and is safe to repeat; review its
diff before committing, because a pin made by mistake hides a real break. The demonstration
edits are made to a saved copy's original and restored from it; if a session ends midway,
`git checkout -- schema/Agent.dhall` restores the file. The M3 restructuring is a set of
Cabal-file changes with no data migration, reverted with `git revert`. Each freeze commit
changes only the inventory and pins. If a blocking defect is found after either, do not
unfreeze the surface or delete the tag: fix forward under the `stable` policy, which is the point of the
baseline. Never drop the Shikigami database to make a check pass. After the first freeze its journaled
declarations must keep decoding; after the second its journals are state that must resume.


## Interfaces and Dependencies

M1 has no prerequisite and can start immediately. M2, the first freeze, needs EP-1, EP-2,
EP-3, EP-4, EP-8 and EP-9 Complete, EP-6's first milestone accepted and EP-7 at its third
milestone. M3 and M4, the second freeze, additionally need EP-5, EP-6 and EP-10 Complete. The
registry row for this plan in MasterPlan 22 should read: "EP-1 to EP-4, EP-8, EP-9; EP-6 M1;
EP-7 M3 (for M2); EP-5, EP-6, EP-10 (for M3 and M4)". Between the freezes, EP-6 and EP-10
may change the durable wire and the SDK under the drain rule, and may not change a frozen
declaration surface.

Interfaces this plan publishes, which the sibling plans use to register their surfaces:

- `api-baseline/Surface.dhall` (the `Surface`, `Stability`, `Enforcement` and `Check`
  types) and `api-baseline/surfaces.dhall` (the inventory). An owning plan adds its entry
  and its corpus directory in the commit that ships its surface.
- The `api-baseline` executable: `check`, `pin`, `list` and `exposure`, and the recipes
  `just api-baseline` and `just api-baseline-pin`.
- `docs/architecture/api-baseline.md`, the stability policy.

What this plan consumes: `Shikigami.Agent.Loader` and the `AgentDecl` JSON instances
(`shikigami-core`); the OpenAPI value in `shikigami-api/src/Shikigami/Api/OpenApi.hs`; the
loaders EP-1, EP-3 and EP-4 provide for their schemas; EP-5's `sdkModules` list and kernel
namespace list in `tools/style/module-ownership.json`; and EP-8's port module names. The
libraries that matter are `dhall` (semantic hashing and decoding), `aeson` (the OpenAPI and
codec comparisons), `process` (running `--help`, `ghc --show-iface` and `just keiro-gate`)
and Cabal's private and public sublibraries (the M3 boundary). Locate dependency sources
with `mori registry show <project> --full`, not from memory.

Revision note (2026-11-15): the initial body was drafted under MasterPlan 22.

Revision note (2026-11-15, user decision): the baseline freezes in two steps. M2 is now the
declaration baseline and M4 the kernel baseline, each inventory entry names its freeze, and
the first freeze's corpus excludes declarations that a later plan moves.

Revision note (2026-11-16, M1 implementation): M1 is complete. Eight surfaces are registered,
including EP-5's two SDK components. Export lists come from interface files after a Hoogle
prototype, a check that cannot run exits 2, and the exposure measurement is recorded.
