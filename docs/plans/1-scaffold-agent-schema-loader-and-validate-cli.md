---
id: 1
slug: scaffold-agent-schema-loader-and-validate-cli
title: "Scaffold, Agent Schema, Loader, and Validate CLI"
kind: exec-plan
created_at: 2026-06-24T23:41:28Z
intention: "intention_01kvy04813ehbv9aghj3tn4zjx"
master_plan: "docs/masterplans/1-shikigami-declared-agent-runtime-bootstrap.md"
provenance:
  revisions:
    - model: "gpt-6.1-sol"
      harness: "codex-cli"
      at: 2026-11-06T20:49:07Z
      mode: "update"
      note: "Expose the three historically accepted milestones under Progress while retaining detailed evidence."
---

# Scaffold, Agent Schema, Loader, and Validate CLI

This ExecPlan is a living document. The sections Progress, Surprises & Discoveries,
Decision Log, and Outcomes & Retrospective must be kept up to date as work proceeds.


## Purpose / Big Picture

**Shikigami** (式神, "a summoned spirit-servant bound to its master's will") is a runtime in which
an autonomous software agent is *declared*, not coded. Instead of writing and deploying a bespoke
service, you write a short, typed configuration file that says "run **this behavior**, when **this
trigger** fires, and send the result to **these sinks**," and a thin worker runs it forever. The
configuration language is **Dhall** — a small, typed, non-Turing-complete configuration language
(think "JSON with types, functions, and imports, but guaranteed to terminate"). An agent declaration
is a Dhall record `{ name, behavior, trigger, sinks }`.

This ExecPlan (EP-1) is the **hard root** of the whole initiative. Nothing else in the runtime
compiles until EP-1 lands. After EP-1 is complete, a person who has only this repository and a Nix
dev shell can do all of the following, observably:

1. Run `cabal build all` from `/Users/shinzui/Keikaku/bokuno/shikigami` and watch the four-package
   project build green against a coherent set of pinned dependencies.
2. Run `just create-database` and watch a fresh PostgreSQL database receive the **kioku** memory
   tables (`kioku_memories`, `kioku_sessions`, `kioku_turns` in the `kiroku` schema) plus shikigami's
   own suppression table `shikigami_fired` — and *not* a bespoke `agent_runs` table (kioku replaces
   it).
3. Run `cabal run shikigami -- validate agents/heartbeat.dhall` and see the agent declaration parsed
   from Dhall and pretty-printed as a typed Haskell value, ending with `OK: 1 agent parsed.`
4. Run `cabal run shikigami -- validate agents/broken.dhall` on a malformed file and see the program
   exit with a **non-zero** status and a typed error message (not a crash, not a stack trace).
5. For a *skill-agent* (an agent whose behavior is a directory of instructions), run `validate` and
   see it additionally check that the skill directory exists and that its `SKILL.md` front-matter is
   well-formed (a `name` that matches the directory and a non-empty `description`).

The user-visible behavior this plan enables is exactly steps 3–5: **you can author an agent in Dhall
and have the tool tell you, precisely, whether it is valid.** Everything else (the behavior runner,
the sinks, the triggers, the worker) is built by later ExecPlans on the foundation this plan lays.

This plan deliberately does **not** build any runtime behavior beyond `validate`: no behavior runner,
no sink dispatcher, no trigger evaluator, no worker, no Kafka consumer. Those are owned by
`docs/plans/2-behavior-runner-and-kioku-session-and-memory-integration.md` (EP-2),
`docs/plans/3-sink-dispatcher-permission-gate-and-kawa-stub.md` (EP-3),
`docs/plans/4-trigger-evaluators-and-the-activity-v1-stream-consumer.md` (EP-4), and
`docs/plans/5-the-supervised-worker-and-run-orchestration.md` (EP-5). EP-1 produces the artifacts
they all import: the wire types, the canonical schema, the loader, the pin-set, and the migration
composition.


## Progress

Reconciled 2026-11-06: all three milestones were accepted on 2026-06-24, as
recorded in Outcomes & Retrospective. The original checklist below is retained
as historical evidence; the milestone summary is directly under Progress so Mina
can observe the completed work.

- [x] (2026-06-24) M1: four-package bootstrap and coherent dependency pins built successfully; a second build reported `Up to date`.
- [x] (2026-06-24) M2: composed migrations applied and reapplied without changes; Kioku tables and `shikigami_fired` existed, with no bespoke `agent_runs` table.
- [x] (2026-06-24) M3: canonical schema, typed loader and validate CLI accepted the heartbeat and Skill fixtures and rejected malformed declarations and mismatched Skill names.


## Historical milestone evidence

### Milestone M1 — four-package project scaffolds and builds ✅ (2026-06-24)

- [x] Confirm the already-scaffolded files (`flake.nix`, `nix/*`, `process-compose.yaml`,
      `fourmolu.yaml`, `.seihou/`) are present and do not overwrite them.
- [x] Author `cabal.project` with the four shikigami packages plus **GitHub git stanzas** for kioku /
      handan / shikumi / kafka-effectful and **Hackage** `dhall` (not local paths — see Decision Log),
      with kioku's kikan pin block copied byte-identically (IP-8). Corrected the handan/kafka-effectful
      package paths (handan-core; kafka-effectful at repo root).
- [x] Copy + rename `Justfile` from kizashi (`kizashi`→`shikigami`); `nix/haskell.nix` already
      exports `PGDATABASE=shikigami` and `.envrc` exists.
- [x] Create `shikigami-api/shikigami-api.cabal` with the `common` stanza (IP-9) and module list.
- [x] Create `shikigami-api/src/Shikigami/Prelude.hs` (no `Data.Generics.Labels` re-export).
- [x] Create `shikigami-core/shikigami-core.cabal`, `shikigami-cli/shikigami-cli.cabal`,
      `shikigami-migrations/shikigami-migrations.cabal` (with the `common` stanza, `import: common`).
- [x] Add placeholder modules so each package has at least one exposed module; `cabal build all`
      exits 0 and a second run reports `Up to date`.

### Milestone M2 — migration composition + suppression table + scope helper ✅ (2026-06-24)

- [x] Create `shikigami-migrations/src/Shikigami/Migrations.hs` composing
      `kiokuMigrations <> shikigamiOwnMigrations` (NOT re-adding kiroku/keiro — kioku already does).
- [x] Create `shikigami-migrations/sql-migrations/0001-shikigami-fired.sql` (the
      `shikigami_fired` DDL; NO `agent_runs` table).
- [x] Create `shikigami-migrations/app/Main.hs` (the `shikigami-migrate` codd executable).
- [x] Create `shikigami-migrations/test-support/Shikigami/Migrations/TestSupport.hs`
      (`withShikigamiMigratedDatabase`).
- [x] Create `shikigami-core/src/Shikigami/Memory/Scope.hs` (`agentScope`/`sharedScope`).
- [x] Run `just create-database`; `\dt kiroku.kioku_*` lists `kioku_memories`/`kioku_sessions`/
      `kioku_turns` (+ extra kioku tables), `shikigami_fired` exists, `agent_runs` absent; re-run is a
      no-op (`[0 found]`).

### Milestone M3 — schema, wire types, loader, validate CLI ✅ (2026-06-24)

- [x] Author `schema/Agent.dhall` as the canonical C5 superset (reconciles spec + seed detectors).
- [x] Create `shikigami-api/src/Shikigami/Api/Agent.hs` (wire types + `FromDhall` + `aeson`).
- [x] Create `shikigami-api/src/Shikigami/Api/Activity.hs` (the nine-field `ActivityEnvelope`, IP-6).
- [x] Create `shikigami-core/src/Shikigami/Agent/Loader.hs` (`loadAgent`, `LoadError`).
- [x] Create `shikigami-core/src/Shikigami/Agent/Skill.hs` (`SKILL.md` front-matter validation;
      `checkFields` implemented via aeson `KeyMap` lookups; `SkillNameMismatch` made positional to keep
      the `-Wpartial-fields` foundation warning-clean).
- [x] Create `shikigami-cli/src/Shikigami/Cli/Commands/Validate.hs`, `Shikigami/Cli.hs`,
      `app/Main.hs` (the M1 `app/Main.hs` already calls `Cli.main`; only the library changed).
- [x] Author `agents/heartbeat.dhall`, `agents/triage-note.dhall`, `agents/broken.dhall` + the
      `agents/skills/triage-note/SKILL.md` skill dir.
- [x] `cabal run shikigami -- validate agents/heartbeat.dhall` prints the `AgentDecl` + `OK: 1 agent
      parsed.`, exit 0.
- [x] `validate agents/broken.dhall` prints Dhall's typed "Expression doesn't match annotation"
      (behavior vs behaviour) error, exit 1.
- [x] `validate agents/triage-note.dhall` reports `OK: 1 agent parsed (skill … valid).`; corrupting
      the skill `name:` yields `SkillNameMismatch "triage-note" "wrong"`, exit 1; restored.


## Surprises & Discoveries

Document unexpected behaviors, bugs, optimizations, or insights discovered during
implementation. Provide concise evidence.

- **`kiokuMigrations` already includes the framework migrations (affects M2).** Reading the real
  source at `/Users/shinzui/Keikaku/bokuno/kioku/kioku-migrations/src/Kioku/Migrations.hs`,
  `kiokuMigrations = do { kiroku <- kirokuMigrations; keiro <- keiroFrameworkMigrations; own <-
  kiokuOwnMigrations; pure (kiroku <> keiro <> own) }`. So the four-term chain `kirokuMigrations <>
  keiroFrameworkMigrations <> kiokuMigrations <> shikigamiOwnMigrations` written in the MasterPlan
  milestone and in the kioku-side prior-art plan would apply kiroku + keiro **twice** and fail codd
  (it rejects re-presented already-applied timestamps). The correct composition is `kiokuMigrations
  <> shikigamiOwnMigrations`. Recorded at authoring time from the on-disk source; see the Decision
  Log. This is the "framework-migration overlap subtlety" the EP-1 brief flagged.

- **kioku's kiroku pin differs from kizashi's (affects M1).** kioku pins kiroku at
  `4312aa8cc3e4f6ab0d19fc8bb12d0dd9f8cc164a`; kizashi pins it at
  `322096c88ce3db125e9cd0cea3fcf5f96c158db2`. Because shikigami links kioku's compiled packages, the
  pin block must be copied from kioku's `cabal.project`, not kizashi's, or the solve splits into two
  incompatible kiroku/hasql worlds. See the Decision Log and IP-8.

- **Two IP-8 local-path pins were wrong in the plan text (affects M1).** The plan listed
  `/Users/shinzui/Keikaku/bokuno/handan/handan` and
  `/Users/shinzui/Keikaku/bokuno/kafka-effectful/kafka-effectful`, but the actual package
  directories are `handan/handan-core` (the package is `handan-core`; there is no `handan/handan`)
  and `kafka-effectful` itself (the `.cabal` is at the repo root, not a `kafka-effectful/` subdir).
  Corrected both in `cabal.project`; `cabal build all --dry-run` then resolved the full coherent
  pin-set (kioku + kikan + handan-core + shikumi + baikai + kafka-effectful + dhall). Discovered when
  the first `cabal build all` failed with "package location does not exist".

- **The seed detectors use a richer Dhall shape than the spec's illustrative schema (affects M3,
  EP-6).** `agents/detectors/schema.dhall` uses singular `sink`, `Behavior = <Deterministic | Program
  | Skill>`, `Trigger = <Observe | Schedule | Addressed>`, and `Sink = <RaiseSignal |
  RecordReiAction>`, with rich `RaiseSignal` fields (`importance`, `recipientFrom`, `intentTemplate`,
  `extraContextTags`). The canonical `schema/Agent.dhall` is designed as the strict superset (IP-2) so
  EP-6's re-point is a mechanical rename, not a redesign.


## Decision Log

Record every decision made while working on the plan.

- Decision: Compose migrations as `kiokuMigrations <> shikigamiOwnMigrations`, **NOT**
  `kirokuMigrations <> keiroFrameworkMigrations <> kiokuMigrations <> shikigamiOwnMigrations`.
  Rationale: reading the real source at
  `/Users/shinzui/Keikaku/bokuno/kioku/kioku-migrations/src/Kioku/Migrations.hs`, the exported
  `kiokuMigrations` is *already* `kirokuMigrations <> keiroFrameworkMigrations <> kiokuOwnMigrations`.
  The MasterPlan's milestone text and the kioku-side prior-art plan
  (`/Users/shinzui/Keikaku/bokuno/kioku/docs/plans/6-shikigami-memory-integration-with-kioku.md`)
  both write the full four-term chain, which would apply the kiroku and keiro framework migrations
  **twice**. codd identifies migrations by their leading timestamp and treats a re-presented
  already-applied migration as an error, so the naive chain would fail `just create-database`. The
  correct, non-double-applying composition is `kiokuMigrations <> shikigamiOwnMigrations`. This is
  exactly the "framework-migration overlap subtlety" the EP-1 brief warned about. The observable
  acceptance (the three `kioku_*` tables plus `shikigami_fired` all present) is identical; only the
  composition expression changes. Recorded here so EP-2/EP-6 do not re-introduce the double chain.
  Date: 2026-06-24

- Decision: Use **kioku's** `cabal.project` pin block byte-identically, not kizashi's.
  Rationale: kioku pins kiroku at `4312aa8cc3e4f6ab0d19fc8bb12d0dd9f8cc164a` whereas kizashi pins it
  at `322096c88ce3db125e9cd0cea3fcf5f96c158db2`; kioku also pins `baikai` (with `baikai-effectful`)
  which kizashi does not. Because shikigami depends on kioku's compiled packages, the solver must see
  the *same* kiroku/keiro/shibuya/pgmq versions kioku was built against, or the build splits into two
  incompatible hasql/kiroku worlds. IP-8 mandates copying kioku's block; the kiroku-pin-skew note in
  kioku's MasterPlan says "prefer kioku's pins over kizashi's older ones." So the source of truth for
  the pin block is `/Users/shinzui/Keikaku/bokuno/kioku/cabal.project`.
  Date: 2026-06-24

- Decision: **(SUPERSEDED 2026-06-24 by the GitHub+Hackage decision below.)** Pin kioku, handan,
  shikumi, baikai, kafka-effectful, and dhall by **local path**, not git tag, for the foundation build.
  Rationale: all six dependency repos are checked out as sibling directories under
  `/Users/shinzui/Keikaku/bokuno/`; a local-path `packages:` entry avoids a network fetch, lets the
  solver use exactly the working-tree sources we read while authoring, and removes the need to tag
  kioku before EP-1 can build (kioku is co-developed). The IP-8 note that a `source-repository-package`
  git stanza can replace the local paths once kioku is tagged is preserved in Interfaces and
  Dependencies as the release path. `dhall` is a third-party corpus checkout at
  `/Users/shinzui/Keikaku/hub/haskell/dhall-haskell-project/dhall-haskell/dhall`; pin its package
  directory by local path too.
  Date: 2026-06-24

- Decision: Pin the co-developed shinzui dependencies by **GitHub `source-repository-package` git
  stanza** and `dhall` from **Hackage** — no local-path/corpus checkouts (supersedes the local-path
  decision above, at the user's request).
  Rationale: the user directed "use hackage and github for dependencies and not use corpus ones."
  Concretely: `kioku` → git `608fbc98e2191bc83b353b14e2c6ba98d543d715` (subdir
  `kioku-api kioku-core kioku-cli kioku-migrations`); `handan` → git
  `d25fac3f758d9f0143fc00f27437d4e477801321` (subdir `handan-core`); `shikumi` → git
  `36496deef05060ef9e49486225ab475541343f05` (subdir `shikumi shikumi-trace`, tagged
  `shikumi-0.1.0.1`); `kafka-effectful` → git `f34a43cd476f7234848def9c0f08c54a1b67028e`; `dhall` →
  Hackage (`>=1.42`, solver picks 1.42.3). `baikai` stays as kioku's existing git stanza
  (`a219ace8…`, already GitHub — the kioku-core-compatible baikai). kioku is pinned at
  `origin/master` (608fbc9), not the local working-tree HEAD (36443c1): the three-commit local lead is
  **docs-only** (masterplan/plan markdown — verified `git diff --stat origin/master..HEAD` touches only
  two `.md` files), so origin/master carries byte-identical Haskell. A git pin can only reference a
  pushed commit, so origin/master is the correct, safe choice. **Bonus:** moving these from `packages:`
  (which `cabal build all` always builds) to `source-repository-package` means EP-1 only builds what it
  actually depends on (dhall, kioku, shikumi) — handan/kafka-effectful/baikai are fetched for the solve
  but not built until EP-2/EP-4 need them.
  Date: 2026-06-24

- Decision: Build **no `agent_runs` table**. shikigami's own migration creates only `shikigami_fired`.
  Rationale: the MasterPlan replaced the spec's bespoke session store with kioku's
  `kioku_sessions` (Decision Log entry in `docs/masterplans/1-...md`). The only shikigami-owned table
  this plan needs is the suppression table from `agents/detectors/README.md`. The exact DDL is copied
  from that README so EP-6's detectors find the table they expect.
  Date: 2026-06-24

- Decision: Design `schema/Agent.dhall` as the **superset** of (a) the spec's illustrative schema in
  `docs/initial-spec.md` and (b) the seed detector schema at `agents/detectors/schema.dhall`, anchored
  on the spec's C5 names (`sinks : List Sink`; `Behavior` covering the typed-program and skill arms;
  the three C3 trigger classes).
  Rationale: IP-2 makes EP-1 the owner of the canonical schema and requires it to express everything
  the seeds need so EP-6's re-point is a mechanical rename. The seeds use a singular `sink`, a richer
  `Behavior = < Deterministic | Program | Skill >`, a richer `Trigger = < Observe | Schedule |
  Addressed >`, and a `Sink = < RaiseSignal | RecordReiAction >`. The canonical schema therefore (1)
  carries all three behavior arms (Deterministic + ShikumiProgram + Skill), (2) carries all three
  trigger arms named to match C3 (Schedule/Stream/Event) with a Stream `match` rich enough for the
  seeds' `subjectType`/`verbs`, (3) carries the producer sink set (KawaDigest/KizashiSignal/ReiAction/
  DanwaConversation) plus the seeds' rich `RaiseSignal` fields folded into `KizashiSignal`, and (4)
  uses `sinks : List Sink` so the seeds' singular `sink` becomes `sinks = [ ... ]`. The exact field
  reconciliation is documented in Interfaces and Dependencies under IP-2.
  Date: 2026-06-24

- Decision: The `validate` CLI prints the parsed `AgentDecl` via its derived `Show` instance and a
  human "OK"/error line, exiting 0 on success and non-zero on any load error.
  Rationale: the spec's worked transcript (`docs/initial-spec.md`, "The loader" section) shows a
  pretty-printed record followed by `OK: 1 agent parsed.`; a `Show`-derived render plus a one-line
  summary matches that, is trivially testable, and needs no pretty-printing library.
  Date: 2026-06-24


## Outcomes & Retrospective

Summarize outcomes, gaps, and lessons learned at major milestones or at completion.
Compare the result against the original purpose.

**Outcome (2026-06-24): EP-1 complete; all three milestones built and verified.** The five
observable behaviors in Purpose / Big Picture all hold from a fresh dev shell:

1. `cabal build all` is green and idempotent (`Up to date` on the second run), warning-clean, against
   the coherent kioku + kikan + handan + shikumi + kafka-effectful + dhall pin-set.
2. `just create-database` lands the `kioku_*` read-model tables and `shikigami_fired` in the `kiroku`
   schema, with **no** `agent_runs` table; re-run is a no-op.
3. `validate agents/heartbeat.dhall` prints the typed `AgentDecl` and `OK: 1 agent parsed.` (exit 0).
4. `validate agents/broken.dhall` prints Dhall's precise "Expression doesn't match annotation"
   (`behavior` vs `behaviour`) and exits 1 — a structured error, not a crash.
5. `validate agents/triage-note.dhall` additionally validates the `SKILL.md` front-matter; a corrupted
   `name:` yields `SkillNameMismatch` and exit 1.

**Deliverables for downstream plans:** `Shikigami.Api.Agent` (IP-1 wire types), `Shikigami.Api.Activity`
(IP-6 envelope), `schema/Agent.dhall` (IP-2 canonical C5 superset), `Shikigami.Agent.Loader`,
`Shikigami.Agent.Skill`, `Shikigami.Memory.Scope` (IP-3), the `shikigami_fired` migration and
`Shikigami.Migrations`/`TestSupport`, and the GitHub+Hackage `cabal.project` pin-set (IP-8) every
sibling plan inherits.

**Deviations from the plan as written (all recorded in the Decision Log / Surprises):** (a) dependency
pins moved from local-path/corpus to **GitHub git stanzas + Hackage `dhall`** at the user's request —
this also made `cabal build all` lighter (handan/kafka-effectful/baikai are fetched for the solve but
not built until EP-2/EP-4). (b) Two IP-8 paths were corrected (`handan-core`; `kafka-effectful` at repo
root). (c) The plan's `Loader`/`Skill`/`Validate` code sketches (which left `checkFields = undefined`,
a `fromString` placeholder, and `toString = id`) were completed into compiling implementations.

**Gaps / forward notes:** the test-support sublibrary `withShikigamiMigratedDatabase` is built but no
`tasty`/`hspec` test calls it yet (the plan flagged this as an optional CI-style check); EP-2+ can add
the test. kioku ships additional read-model tables (`kioku_personas`, `kioku_scenes`,
`kioku_consolidation_decisions`) beyond the three the plan named — harmless, present because they are
part of `kiokuMigrations`.


## Context and Orientation

Read this section fully before running anything. It assumes you have never seen any of these
repositories and explains every term and file path you will touch.

### What this repository is right now

You are working inside `/Users/shinzui/Keikaku/bokuno/shikigami`. As of this plan it is a
**greenfield Haskell project**: there is **zero Haskell source**, only documentation, Dhall seed
declarations, and a Nix/dev-shell scaffold that was generated by a tool called `seihou`. Concretely,
running `ls -la` in the repo root shows (among others):

- `docs/initial-spec.md` — the full architecture spec for the shikigami runtime (read it for
  background; the load-bearing parts are summarized in this plan).
- `docs/masterplans/1-shikigami-declared-agent-runtime-bootstrap.md` — the MasterPlan that
  decomposes the runtime into six ExecPlans (EP-1 … EP-6). This plan *is* EP-1.
- `docs/plans/2-...md` … `docs/plans/6-...md` — the sibling ExecPlans (referenced only by path).
- `agents/detectors/{schema.dhall,stalled-intention.dhall,at-risk-customer.dhall,README.md}` — seed
  agent declarations authored *before* the runtime, against a local placeholder schema. You read
  these to design the canonical schema; you do **not** edit them (EP-6 re-points them).
- `flake.nix`, `nix/haskell.nix`, `nix/treefmt.nix`, `nix/pre-commit.nix`, `process-compose.yaml`,
  `fourmolu.yaml`, `.envrc` (and `.seihou/`) — the dev-shell scaffold, **already committed by
  seihou**. Do not overwrite these. `nix/haskell.nix` already exports the PostgreSQL environment
  (`PGHOST`, `PGDATA`, `PGDATABASE=shikigami`, `PG_CONNECTION_STRING`) in its `shellHook`.

There is **no** `cabal.project`, no `Justfile`, and no `*.cabal` file yet. You create those.

### The dev shell and how to enter it

All Haskell and database commands run inside a Nix dev shell that pins GHC 9.12.4, cabal, HLS, and a
PostgreSQL toolchain, and exports the `PG*` environment variables. Enter it one of two ways:

```bash
cd /Users/shinzui/Keikaku/bokuno/shikigami
direnv allow          # if you use direnv; reads .envrc which does `use flake` then eval "$shellHook"
# or, equivalently:
nix develop           # drops you into the same shell
```

Inside the shell, `echo $PGDATABASE` prints `shikigami` and `echo $PGHOST` prints a path like
`/Users/shinzui/Keikaku/bokuno/shikigami/db`. The database runs as a local socket-only PostgreSQL
under that directory (started by `process-compose` or by `just create-database` after `pg_ctl`).

### The sibling repositories you depend on

These are read-only inputs located as sibling directories. You never edit them; you depend on them.

- `/Users/shinzui/Keikaku/bokuno/kizashi` — an existing Haskell project on the same event-sourcing
  stack. It is the **scaffold template**: four packages (`kizashi-api`, `kizashi-core`,
  `kizashi-cli`, `kizashi-migrations`), a `Justfile` with `create-database`/`migrate`/`new-migration`
  recipes, and a `cabal.project`. You copy its *structure*, renaming `kizashi`→`shikigami`.
- `/Users/shinzui/Keikaku/bokuno/kioku` — **kioku** (記憶, "memory"), a reusable event-sourced
  memory/session library, already built. Four packages (`kioku-api`, `kioku-core`, `kioku-cli`,
  `kioku-migrations`). You depend on `kioku-api` and `kioku-core` (for the scope types) and on
  `kioku-migrations` (for the migration composition). You import only kioku's top-level modules and
  `kioku-api` types — **never** `Kioku.*.Domain.*` internals.
- `/Users/shinzui/Keikaku/bokuno/handan` (package `handan`, contains `Handan.Runtime`/`Handan.Task`),
  `/Users/shinzui/Keikaku/bokuno/shikumi` (packages `shikumi`, `shikumi-trace`),
  `/Users/shinzui/Keikaku/bokuno/baikai` (packages `baikai`, `baikai-claude`, `baikai-effectful`),
  `/Users/shinzui/Keikaku/bokuno/kafka-effectful` (package `kafka-effectful`) — the substrate the
  *later* plans use (behavior runner, stream consumer). EP-1 does not call these, but it **pins** them
  in `cabal.project` so the whole project resolves once (IP-8). Pinning them now avoids a later
  pin-set churn that would force a full rebuild.
- `/Users/shinzui/Keikaku/hub/haskell/dhall-haskell-project/dhall-haskell/dhall` — the Haskell
  `dhall` library (a third-party corpus checkout). EP-1's loader uses it. You pin its package
  directory by local path.

You can confirm any path with `mori registry show <name> --full` (e.g.
`mori registry show kafka-effectful --full` prints `Path: /Users/shinzui/Keikaku/bokuno/kafka-effectful`).

### Terms of art (defined in plain language)

- **Declared agent.** A typed Dhall record `{ name, behavior, trigger, sinks }`. `name` is a stable
  text id; `behavior` is what the agent does; `trigger` is when it runs; `sinks` are what it
  produces. EP-1 turns this Dhall value into a Haskell value and validates it.
- **Dhall.** A small, typed, terminating configuration language. The Haskell `dhall` library reads a
  `.dhall` file, type-checks it, normalizes it, and *marshals* it into a Haskell value via a
  `Decoder`. We use the `FromDhall` type class and its generic default so our records and unions
  decode automatically.
- **C5 (the agent-definition schema contract).** The frozen contract that says an agent *is*
  `{ name, behavior, trigger, sinks }` with a behavior union and a producer sink set. EP-1 owns the
  canonical Dhall expression of it at `schema/Agent.dhall`.
- **Activity Envelope (contract C1).** The canonical nine-field event shape every activity on the
  shared `activity.v1` stream takes: `activity_id` (a UUIDv7 string), `occurred_at` (an RFC3339
  timestamp), `source` (e.g. `"shinzui/shikigami"`), `actor` (`{ kind, id, session? }`), `subject`
  (`{ type, id }`), `verb` (a past-tense dotted string like `"digest.produced"`), `payload`
  (free-form JSON), `context_refs` (a list of `{ scheme, ref }` back-references), and
  `idempotency_key`. EP-1 *defines* the Haskell record + JSON instances; later plans build and decode
  it. An agent's own output carries `actor.kind = "agent"`.
- **kioku Session / Memory / MemoryScope.** A **Session** is an event-sourced record of one agent
  run; a **Memory** is a durable learning; both are scoped by a **MemoryScope**, which is either
  `ScopeGlobal (Namespace ns)` or `ScopeEntity (Namespace ns) (ScopeKind k) ref`. EP-1 only needs the
  scope type (to write the `Shikigami.Memory.Scope` helper) and the migration library (to land the
  tables); the *use* of sessions and memories is EP-2.
- **codd / migrations.** kioku and the kikan framework ship their schema as timestamped `.sql` files
  embedded into a binary by Template Haskell (`embedDir`) and applied by the `codd` tool, which
  records applied migrations by their leading UTC timestamp and skips already-applied ones.
  shikigami's migration binary composes kioku's migration list with its own.
- **Suppression table `shikigami_fired`.** A table keyed `(detector, subject_type, subject_id,
  window_key)` that records that a detector already raised a signal for a given condition, so a
  still-true condition does not re-fire on every tick. EP-1 creates it; EP-4/EP-5 use it.
- **Skill.** A directory named `<skill-name>/` containing at minimum a `SKILL.md` file (YAML
  front-matter + a Markdown instruction body). The front-matter has a REQUIRED `name` (1–64 chars,
  lowercase alphanumeric + hyphens, must equal the directory name) and a REQUIRED `description`. A
  skill-agent's behavior points at such a directory. EP-1's `validate` checks the directory exists and
  the front-matter is well-formed.

### What you must NOT do (the boundary)

EP-1 does **not** create the behavior runner (`Shikigami.Behavior.*`), the sink dispatcher
(`Shikigami.Sink.*`), the trigger evaluators (`Shikigami.Trigger.*`), the worker, the Kafka consumer,
the kawa stub, or the kioku session/memory *use*. It creates exactly: the buildable four-package
project, the wire types, the `ActivityEnvelope`, `schema/Agent.dhall`, the loader, the `validate`
CLI subcommand, the `Shikigami.Memory.Scope` helper, and the migration composition (kioku + the
`shikigami_fired` table). If a step tempts you to wire a real trigger, sink, or behavior, stop — that
belongs to a sibling plan.


## Plan of Work

The work is three milestones. Each leaves the tree building (`cabal build all` exits 0) and is
independently verifiable. M1 stands up the buildable, pinned four-package project. M2 lands the
migration composition (kioku's tables + `shikigami_fired`) and the scope helper, verified by
`just create-database`. M3 delivers the canonical schema, the wire types, the loader, and the
`validate` CLI, verified by running `validate` on good and bad manifests.

### Milestone M1 — four-package project scaffolds and `cabal build all` exits 0

**Scope and result.** At the end of M1, `/Users/shinzui/Keikaku/bokuno/shikigami` has a
`cabal.project`, a `Justfile`, and the four packages `shikigami-api`, `shikigami-core`,
`shikigami-cli`, `shikigami-migrations`, each with a `.cabal` file and at least one placeholder
module, and `cabal build all` exits 0 with the kioku + kikan + handan/shikumi/baikai/kafka-effectful/
dhall pin-set resolving. There is no agent logic yet; the goal is a green build with a coherent
dependency solve.

**What already exists (do not recreate).** `flake.nix`, `nix/haskell.nix`, `nix/treefmt.nix`,
`nix/pre-commit.nix`, `process-compose.yaml`, `fourmolu.yaml`, `.envrc`, and `.seihou/` are present
(seihou-generated, committed at `5063e00`). Confirm with `ls -la` and `git log --oneline`. Leave them
untouched. In particular `nix/haskell.nix`'s `shellHook` already sets `PGDATABASE=shikigami` and
`PG_CONNECTION_STRING`, so you do **not** edit it for the database name.

**Files created in M1.**

`cabal.project` — list the four shikigami package directories and the dependency packages by **local
path**, then paste kioku's pin block byte-identically. The exact contents are in Concrete Steps,
Step 1.1; the pin block to copy is in Interfaces and Dependencies under IP-8.

`Justfile` — copy `/Users/shinzui/Keikaku/bokuno/kizashi/Justfile` and replace every `kizashi`
token with `shikigami` (notably `cabal run kizashi-migrate` → `cabal run shikigami-migrate` and
`touch kizashi-migrations/kizashi-migrations.cabal` → `touch
shikigami-migrations/shikigami-migrations.cabal`). The `CODD_SCHEMAS=kiroku` line stays exactly as is
(kioku's read-model tables live in the `kiroku` schema).

`shikigami-api/shikigami-api.cabal` — a `cabal-version: 3.0` file with a `common` stanza enabling the
IP-9 extensions and warnings, and a `library` stanza doing `import: common` that exposes
`Shikigami.Prelude` (M1) and, after M3, `Shikigami.Api.Agent` and `Shikigami.Api.Activity`. Dependency
set: `aeson, base, containers, dhall, generic-lens, lens, text, time, uuid`. (`dhall` is here because
the `FromDhall` instances live alongside the wire types in M3; adding it now keeps the cabal file
stable across milestones.)

`shikigami-api/src/Shikigami/Prelude.hs` — the project prelude, modeled on kioku's
(`/Users/shinzui/Keikaku/bokuno/kioku/kioku-api/src/Kioku/Prelude.hs`). It re-exports the common
aeson/lens/text/time surface and `eventAesonOptions`, and **must not** re-export
`Data.Generics.Labels` (IP-9 — that orphan instance collides with the keiki DSL's label overloading
used downstream). Use `{-# LANGUAGE PackageImports #-}` exactly as kioku's prelude does.

`shikigami-core/shikigami-core.cabal` — `import: common`; depends on `shikigami-api`, `kioku-api`,
`kioku-core`, `dhall`, plus `base, text, containers, aeson, directory, filepath, yaml`. (`yaml` is for
parsing `SKILL.md` front-matter in M3; `directory`/`filepath` for checking the skill path; `dhall` for
the loader.) M1 exposes only a placeholder; M3 adds `Shikigami.Agent.Loader` and
`Shikigami.Agent.Skill`; M2 adds `Shikigami.Memory.Scope`.

`shikigami-cli/shikigami-cli.cabal` — `import: common`; a `library` exposing `Shikigami.Cli` (+
`Shikigami.Cli.Commands.Validate` in M3) and an `executable shikigami` whose `app/Main.hs` calls
`Shikigami.Cli.main`. Depends on `shikigami-core`, `shikigami-api`, `optparse-applicative`, `text`,
`base`.

`shikigami-migrations/shikigami-migrations.cabal` — modeled on
`/Users/shinzui/Keikaku/bokuno/kioku/kioku-migrations/kioku-migrations.cabal`: a `library` exposing
`Shikigami.Migrations`, an `executable shikigami-migrate` (`app/Main.hs`), and a **public** sublibrary
`test-support` exposing `Shikigami.Migrations.TestSupport`. Depends on `kioku-migrations` (for
`kiokuMigrations`), `codd`, `file-embed`, `bytestring`, `streaming`, `text`, `time`, plus
`ephemeral-pg`, `attoparsec`, `containers`, `aeson` for the test-support sublibrary.

Placeholder modules for M1 (replaced/extended in later milestones): each package needs one exposed
module so it builds. `shikigami-api` exposes `Shikigami.Prelude`. For `shikigami-core` add a trivial
`Shikigami.Core` module (`module Shikigami.Core where {}` is not legal; use an empty export list with
a version constant — see Concrete Steps). For `shikigami-cli`, the `Shikigami.Cli` module can be a
stub `main = putStrLn "shikigami"` until M3. `shikigami-migrations` gets its real `Shikigami.Migrations`
in M2; in M1 it may be a stub that re-exports `kiokuMigrations`.

**Acceptance for M1.** From the dev shell at the repo root, `cabal build all` exits 0. Running
`cabal build all` twice in a row, the second run reports `Up to date`. The dependency solve picks the
kioku pin-set (you can confirm `cabal build all -v1` mentions the local kioku/handan/shikumi/baikai
paths). No package fails to resolve.

### Milestone M2 — `shikigami-migrations` composes kioku's migrations; `shikigami_fired` exists

**Scope and result.** At the end of M2, `shikigami-migrations` composes `kiokuMigrations <>
shikigamiOwnMigrations` (see the Decision Log on why this is *not* the four-term chain), `just
create-database` applies them to a fresh database, and the kioku tables plus `shikigami_fired` are
present. `Shikigami.Memory.Scope` exists in `shikigami-core` with `agentScope` and `sharedScope`.

**Files created in M2.**

`shikigami-migrations/src/Shikigami/Migrations.hs` — the migration composition. It imports
`Kioku.Migrations (kiokuMigrations)` and embeds shikigami's own `sql-migrations/` directory via
Template Haskell `embedDir`, then composes the two. The exact code is in Concrete Steps, Step 2.1; the
critical point is that `kiokuMigrations` *already* includes the kiroku and keiro framework migrations,
so shikigami must **not** prepend them again.

`shikigami-migrations/sql-migrations/<timestamp>-shikigami-fired.sql` — the `shikigami_fired`
suppression-table DDL, copied verbatim from `agents/detectors/README.md` (the canonical source). The
file name's leading UTC timestamp (format `YYYY-MM-DD-HH-MM-SS`) is how codd orders it; generate it
with `just new-migration shikigami-fired` (after the Justfile exists) or by hand. The DDL pins
`search_path` to the `kiroku` schema (the kizashi convention) before the `CREATE TABLE`. There is
**no** `agent_runs` table.

`shikigami-migrations/app/Main.hs` — the codd executable, modeled on
`/Users/shinzui/Keikaku/bokuno/kioku/kioku-migrations/app/Main.hs`: read `getCoddSettings`, call a
`runShikigamiMigrationsNoCheck` that applies the composed list.

`shikigami-migrations/test-support/Shikigami/Migrations/TestSupport.hs` — modeled on
`/Users/shinzui/Keikaku/bokuno/kioku/kioku-migrations/test-support/Kioku/Migrations/TestSupport.hs`:
`withShikigamiMigratedDatabase :: (Text -> IO a) -> IO a` spins up an ephemeral PostgreSQL via
`ephemeral-pg`, applies the composed migrations via codd (no schema check), and runs the action with
the connection string. The `namespacesToCheck` includes `kiroku` and `public`.

`shikigami-core/src/Shikigami/Memory/Scope.hs` — the IP-3 scope helper:
`shikigamiNamespace :: Namespace`, `agentScope :: Text -> MemoryScope` (=
`ScopeEntity (Namespace "shikigami") (ScopeKind "agent") <agentName>`), and `sharedScope :: MemoryScope`
(= `ScopeGlobal (Namespace "shikigami")`). Add it to `shikigami-core.cabal` `exposed-modules`.

**Acceptance for M2.** `cabal build all` exits 0. `just create-database` exits 0. Then
`psql -h "$PGHOST" -d "$PGDATABASE" -c '\dt kiroku.kioku_*'` lists `kioku_memories`, `kioku_sessions`,
`kioku_turns`, and `psql -h "$PGHOST" -d "$PGDATABASE" -c '\dt kiroku.shikigami_fired'` shows the
`shikigami_fired` table. `psql ... -c '\dt kiroku.agent_runs'` shows **no** such table (proving the
no-`agent_runs` decision). Re-running `just create-database` is a no-op (codd skips applied
migrations).

### Milestone M3 — `schema/Agent.dhall`, wire types, loader, and `validate` CLI

**Scope and result.** At the end of M3, `schema/Agent.dhall` exists as the canonical C5 superset; the
`shikigami-api` package defines the wire types (`AgentDecl`, `Behavior`, `Trigger`, `StreamMatch`,
`Sink`) and the nine-field `ActivityEnvelope`, with `FromDhall` decoders and `aeson` instances;
`Shikigami.Agent.Loader.loadAgent :: FilePath -> IO (Either LoadError AgentDecl)` parses a manifest;
and `cabal run shikigami -- validate <file>` parses + pretty-prints a manifest (exit 0) or prints a
typed error (exit non-zero). For a skill-agent it additionally validates the `SKILL.md` front-matter.

**Files created in M3.**

`schema/Agent.dhall` — the canonical schema. Its exact text is in Concrete Steps, Step 3.1, and its
design rationale (the superset reconciliation) is in Interfaces and Dependencies under IP-2. It
exports a record `{ Trigger, Behavior, Sink, StreamMatch, SignalType, Priority, Agent }` so manifests
can write `let A = ../schema/Agent.dhall in A.Agent::{ ... }`.

`shikigami-api/src/Shikigami/Api/Agent.hs` — the wire types and their decoders/instances. The Haskell
records mirror the Dhall unions field-for-field so the generic `FromDhall` default works with a small
`InterpretOptions` tweak (the Dhall constructor names map to the Haskell constructor names). It derives
`Show`, `Eq`, `Generic`, `FromDhall`, `ToJSON`, `FromJSON`. Exact shapes are in Interfaces and
Dependencies under IP-1.

`shikigami-api/src/Shikigami/Api/Activity.hs` — the nine-field `ActivityEnvelope` plus its nested
`Actor`, `Subject`, and `ContextRef` records, with `aeson` `FromJSON`/`ToJSON` instances using
snake_case field names (so `activity_id`, `occurred_at`, `context_refs`, `idempotency_key` round-trip).
Exact shape under IP-6.

`shikigami-core/src/Shikigami/Agent/Loader.hs` — `loadAgent :: FilePath -> IO (Either LoadError
AgentDecl)` and `data LoadError`. It calls Dhall's `inputFile auto path` inside a `try` that catches
Dhall's exception type and wraps it in `LoadError`. Exact shape under "shikigami-core".

`shikigami-core/src/Shikigami/Agent/Skill.hs` — `validateSkill :: FilePath -> IO (Either SkillError
())` and `data SkillError`. It checks the directory exists, reads `<dir>/SKILL.md`, splits off the YAML
front-matter (between the leading `---` and the next `---`), parses it with `yaml`, and checks `name`
equals the directory's base name and `description` is present and non-empty.

`shikigami-cli/src/Shikigami/Cli/Commands/Validate.hs`, `shikigami-cli/src/Shikigami/Cli.hs`,
`shikigami-cli/app/Main.hs` — the `validate` subcommand wired into an `optparse-applicative` parser.
`runValidate :: FilePath -> IO ()` calls `loadAgent`, and on success prints the `Show`-rendered
`AgentDecl` then `OK: 1 agent parsed.` (exit 0); for a skill-agent it then runs `validateSkill` on the
declared `path` and prints the skill check result. On any `LoadError` or `SkillError` it prints the
typed error to `stderr` and calls `exitFailure`.

Sample manifests + a sample skill (so `validate` has something to validate):

- `agents/heartbeat.dhall` — a program-agent (`behavior = ShikumiProgram`), schedule trigger, one
  `KawaDigest` sink.
- `agents/triage-note.dhall` — a skill-agent (`behavior = Skill { path = "agents/skills/triage-note" }`),
  stream trigger, one `KizashiSignal` sink.
- `agents/skills/triage-note/SKILL.md` — a valid skill with front-matter `name: triage-note` and a
  `description`.
- `agents/broken.dhall` — a deliberately malformed manifest (e.g. a misspelled field) used to
  demonstrate the typed-error path. (This file is for the validation demo; EP-6's real detectors are
  separate.)

**Acceptance for M3.** `cabal build all` exits 0. `cabal run shikigami -- validate
agents/heartbeat.dhall` prints the parsed record and `OK: 1 agent parsed.` and exits 0. `cabal run
shikigami -- validate agents/broken.dhall` prints a typed `LoadError` to stderr and exits non-zero.
`cabal run shikigami -- validate agents/triage-note.dhall` parses the manifest, then reports the
`SKILL.md` check passes; corrupting the skill's `name` and re-running reports the skill check fails and
exits non-zero. The full transcripts are in Concrete Steps and Validation and Acceptance.


## Concrete Steps

Run all commands from inside `/Users/shinzui/Keikaku/bokuno/shikigami` in the Nix dev shell
(`direnv allow` or `nix develop`). The shell exports `PGHOST`, `PGDATABASE=shikigami`, and
`PG_CONNECTION_STRING`. The sibling repos `kioku`, `handan`, `shikumi`, `baikai`, `kafka-effectful`
and the `dhall` corpus must be checked out at the paths named in Context and Orientation (confirm any
with `mori registry show <name> --full`).

### Step 0 — Inspect what already exists

```bash
cd /Users/shinzui/Keikaku/bokuno/shikigami
ls -la
git log --oneline -5
ls -la nix/
```

You should see `flake.nix`, `nix/haskell.nix`, `nix/treefmt.nix`, `nix/pre-commit.nix`,
`process-compose.yaml`, `fourmolu.yaml`, `.envrc`, `.seihou/`, `agents/`, and `docs/`, but **no**
`cabal.project`, `Justfile`, or `*.cabal`. Do not overwrite the existing files.

### Step 1 — M1: project skeleton and pin-set

**Step 1.1 — `cabal.project`.** Create `/Users/shinzui/Keikaku/bokuno/shikigami/cabal.project`. Start
from this header, then append kioku's pin block. The fastest way to get the pin block byte-identical:

```bash
# Print kioku's source-repository-package block + trailing package/allow-newer lines.
sed -n '/^with-compiler/,$p' /Users/shinzui/Keikaku/bokuno/kioku/cabal.project
```

Author `cabal.project` as:

```text
packages:
  shikigami-api
  shikigami-core
  shikigami-cli
  shikigami-migrations
  /Users/shinzui/Keikaku/bokuno/kioku/kioku-api
  /Users/shinzui/Keikaku/bokuno/kioku/kioku-core
  /Users/shinzui/Keikaku/bokuno/kioku/kioku-cli
  /Users/shinzui/Keikaku/bokuno/kioku/kioku-migrations
  /Users/shinzui/Keikaku/bokuno/handan/handan
  /Users/shinzui/Keikaku/bokuno/shikumi/shikumi
  /Users/shinzui/Keikaku/bokuno/shikumi/shikumi-trace
  /Users/shinzui/Keikaku/bokuno/baikai/baikai
  /Users/shinzui/Keikaku/bokuno/baikai/baikai-claude
  /Users/shinzui/Keikaku/bokuno/baikai/baikai-effectful
  /Users/shinzui/Keikaku/bokuno/kafka-effectful/kafka-effectful
  /Users/shinzui/Keikaku/hub/haskell/dhall-haskell-project/dhall-haskell/dhall

with-compiler: ghc-9.12.4

-- ↓↓↓ Everything below this line is copied BYTE-IDENTICALLY from
--    /Users/shinzui/Keikaku/bokuno/kioku/cabal.project (its source-repository-package
--    stanzas + package/allow-newer footer). Do not retype; paste it. See IP-8.
```

Then paste the kioku pin block reproduced under IP-8 below (the `source-repository-package` stanzas
for keiki, keiro, kiroku, shibuya-core, pgmq-hs, baikai, shibuya-pgmq-adapter, hasql-migration,
ephemeral-pg, codd, hasql-notifications, and the `package codd { tests: False }` / `package blake3` /
`package postgresql-libpq` / `allow-newer: haxl:time` footer). Note that kioku's pin block *also*
lists `../shikumi/shikumi` and `../shikumi/shikumi-trace` and a `baikai` git stanza — because you are
pinning baikai and shikumi by **local path** in the `packages:` block above, **omit** kioku's git
`baikai` stanza when pasting (a path package and a git stanza for the same package conflict). Keep the
keiki/keiro/kiroku/shibuya/pgmq/codd/ephemeral-pg/hasql stanzas. The resolved, correct full file is
shown under IP-8; prefer copying that.

**Step 1.2 — `Justfile`.** Copy and rename:

```bash
cp /Users/shinzui/Keikaku/bokuno/kizashi/Justfile ./Justfile
sed -i '' 's/kizashi/shikigami/g' ./Justfile   # macOS sed; on Linux use: sed -i 's/kizashi/shikigami/g'
```

Confirm the `migrate` recipe now does `touch shikigami-migrations/shikigami-migrations.cabal` and
`cabal run shikigami-migrate`, and that `CODD_SCHEMAS=kiroku` is unchanged.

**Step 1.3 — the four `.cabal` files and placeholder modules.** Create each package directory and its
`.cabal`. The `shikigami-api.cabal` `common` stanza (reused by all packages via `import: common`):

```text
common common
  default-language:   GHC2024
  default-extensions:
    BlockArguments
    DeriveAnyClass
    DuplicateRecordFields
    MultilineStrings
    OverloadedLabels
    OverloadedStrings
  ghc-options:
    -Wall -Wcompat -Widentities -Wincomplete-record-updates
    -Wincomplete-uni-patterns -Wpartial-fields -Wredundant-constraints
```

`shikigami-api/shikigami-api.cabal`:

```text
cabal-version: 3.0
name:          shikigami-api
version:       0.1.0.0
synopsis:      Shikigami declared-agent wire types (client-safe)
build-type:    Simple

common common
  default-language:   GHC2024
  default-extensions:
    BlockArguments
    DeriveAnyClass
    DuplicateRecordFields
    MultilineStrings
    OverloadedLabels
    OverloadedStrings
  ghc-options:
    -Wall -Wcompat -Widentities -Wincomplete-record-updates
    -Wincomplete-uni-patterns -Wpartial-fields -Wredundant-constraints

library
  import:          common
  hs-source-dirs:  src
  exposed-modules:
    Shikigami.Prelude
    -- added in M3:
    -- Shikigami.Api.Agent
    -- Shikigami.Api.Activity
  build-depends:
    , aeson         >=2.2
    , base          >=4.21 && <5
    , containers    >=0.6
    , dhall         >=1.42
    , generic-lens  >=2.2
    , lens          >=5.2
    , text          >=2.1
    , time          >=1.12
    , uuid          >=1.3
```

`shikigami-api/src/Shikigami/Prelude.hs` — copy kioku's prelude verbatim and rename the module:

```haskell
{-# LANGUAGE PackageImports #-}

-- | The project-wide prelude. Do not re-export Data.Generics.Labels here:
-- generic-lens #label syntax collides with the keiki builder DSL.
module Shikigami.Prelude
  ( module X,
    module Control.Lens,
    eventAesonOptions,
  )
where

import "aeson" Data.Aeson as X
  ( FromJSON, Options (..), SumEncoding (..), ToJSON, camelTo2, defaultOptions,
    fromJSON, genericParseJSON, genericToEncoding, genericToJSON, parseJSON,
    toEncoding, toJSON )
import "base" Control.Applicative as X ((<|>))
import "base" Control.Monad as X (forM, forM_, guard, unless, void, when)
import "base" Control.Monad.IO.Class as X (MonadIO, liftIO)
import "base" Data.Maybe as X (fromMaybe, isJust, isNothing, mapMaybe)
import "base" Data.Proxy as X (Proxy (..))
import "base" GHC.Generics as X (Generic)
import "lens" Control.Lens
import "text" Data.Text as X (Text)
import "time" Data.Time as X (UTCTime, getCurrentTime)

-- | Standard event/command JSON options: sums as {"type": "...", "data": {...}}.
eventAesonOptions :: Options
eventAesonOptions =
  defaultOptions
    { sumEncoding = TaggedObject "type" "data",
      constructorTagModifier = camelTo2 '_',
      tagSingleConstructors = True
    }
```

`shikigami-core/shikigami-core.cabal` (M1 form; `exposed-modules` grows in M2/M3):

```text
cabal-version: 3.0
name:          shikigami-core
version:       0.1.0.0
synopsis:      Shikigami runtime core (loader, scope helper)
build-type:    Simple

common common
  default-language:   GHC2024
  default-extensions:
    BlockArguments
    DeriveAnyClass
    DuplicateRecordFields
    MultilineStrings
    OverloadedLabels
    OverloadedStrings
  ghc-options:
    -Wall -Wcompat -Widentities -Wincomplete-record-updates
    -Wincomplete-uni-patterns -Wpartial-fields -Wredundant-constraints

library
  import:          common
  hs-source-dirs:  src
  exposed-modules:
    Shikigami.Core
    -- added in M2: Shikigami.Memory.Scope
    -- added in M3: Shikigami.Agent.Loader, Shikigami.Agent.Skill
  build-depends:
    , aeson           >=2.2
    , base            >=4.21 && <5
    , containers      >=0.6
    , dhall           >=1.42
    , directory       >=1.3
    , filepath        >=1.4
    , kioku-api
    , kioku-core
    , shikigami-api
    , text            >=2.1
    , yaml            >=0.11
```

`shikigami-core/src/Shikigami/Core.hs` — a non-empty placeholder so the package builds in M1:

```haskell
module Shikigami.Core (shikigamiCoreVersion) where

-- | A trivial placeholder so shikigami-core has an exposed module in M1.
-- M2 adds Shikigami.Memory.Scope; M3 adds the loader and skill validator.
shikigamiCoreVersion :: String
shikigamiCoreVersion = "0.1.0.0"
```

`shikigami-cli/shikigami-cli.cabal`:

```text
cabal-version: 3.0
name:          shikigami-cli
version:       0.1.0.0
synopsis:      The `shikigami` command-line tool
build-type:    Simple

common common
  default-language:   GHC2024
  default-extensions:
    BlockArguments
    DeriveAnyClass
    DuplicateRecordFields
    MultilineStrings
    OverloadedLabels
    OverloadedStrings
  ghc-options:
    -Wall -Wcompat -Widentities -Wincomplete-record-updates
    -Wincomplete-uni-patterns -Wpartial-fields -Wredundant-constraints

library
  import:          common
  hs-source-dirs:  src
  exposed-modules:
    Shikigami.Cli
    -- added in M3: Shikigami.Cli.Commands.Validate
  build-depends:
    , base                 >=4.21 && <5
    , optparse-applicative >=0.18
    , shikigami-api
    , shikigami-core
    , text                 >=2.1

executable shikigami
  import:         common
  main-is:        Main.hs
  hs-source-dirs: app
  ghc-options:    -threaded -rtsopts -with-rtsopts=-N
  build-depends:
    , base
    , shikigami-cli
```

`shikigami-cli/src/Shikigami/Cli.hs` (M1 stub; replaced in M3):

```haskell
module Shikigami.Cli (main) where

main :: IO ()
main = putStrLn "shikigami: no subcommands yet (M1 scaffold)"
```

`shikigami-cli/app/Main.hs`:

```haskell
module Main (main) where

import Shikigami.Cli qualified as Cli

main :: IO ()
main = Cli.main
```

`shikigami-migrations/shikigami-migrations.cabal` — modeled on kioku's:

```text
cabal-version:      3.0
name:               shikigami-migrations
version:            0.1.0.0
synopsis:           Schema migrations for shikigami (composes kioku + shikigami_fired)
build-type:         Simple
extra-source-files: sql-migrations/*.sql

common common
  default-language:   GHC2024
  default-extensions:
    BlockArguments
    DeriveAnyClass
    DuplicateRecordFields
    MultilineStrings
    OverloadedLabels
    OverloadedStrings

library
  import:          common
  hs-source-dirs:  src
  exposed-modules: Shikigami.Migrations
  build-depends:
    , base             >=4.18   && <5
    , bytestring       >=0.11   && <0.13
    , codd             >=0.1.8  && <0.2
    , file-embed       >=0.0.15 && <0.0.17
    , kioku-migrations
    , streaming        >=0.2    && <0.3
    , text             >=2.0    && <2.2
    , time             >=1.12   && <1.15

executable shikigami-migrate
  import:         common
  main-is:        Main.hs
  hs-source-dirs: app
  ghc-options:    -threaded -rtsopts -with-rtsopts=-N
  build-depends:
    , base
    , codd
    , shikigami-migrations
    , time  >=1.12 && <1.15

library test-support
  import:          common
  visibility:      public
  hs-source-dirs:  test-support
  exposed-modules: Shikigami.Migrations.TestSupport
  build-depends:
    , aeson                >=2.1   && <2.3
    , attoparsec
    , base                 >=4.18  && <5
    , codd                 >=0.1.8 && <0.2
    , containers           >=0.6   && <0.8
    , ephemeral-pg         >=0.2   && <0.3
    , shikigami-migrations
    , text                 >=2.0   && <2.2
    , time                 >=1.12  && <1.15
```

For M1 only, give `shikigami-migrations` a minimal `src/Shikigami/Migrations.hs` that re-exports
`kiokuMigrations` so the package compiles before you write the real composition in M2:

```haskell
module Shikigami.Migrations (shikigamiMigrationsStub) where

import Kioku.Migrations (kiokuMigrations)
import Codd.Parsing (AddedSqlMigration, EnvVars)

-- | M1 placeholder. M2 replaces this with the real composed migration set
-- (kiokuMigrations <> shikigamiOwnMigrations) and the codd runner functions.
shikigamiMigrationsStub :: (MonadFail m, EnvVars m) => m [AddedSqlMigration m]
shikigamiMigrationsStub = kiokuMigrations
```

(In M2 you replace this file wholesale; the M1 stub exists only so `cabal build all` is green at the
M1 checkpoint. You may skip the stub and go straight to the M2 module if you build M1 and M2 together.)

**Step 1.4 — build.**

```bash
cd /Users/shinzui/Keikaku/bokuno/shikigami
direnv allow            # or nix develop
cabal build all
cabal build all         # second run, to confirm "Up to date"
```

Expected tail of the first run (versions and ordering may vary):

```text
...
Building library for shikigami-api-0.1.0.0..
Building library for shikigami-core-0.1.0.0..
Building library for shikigami-migrations-0.1.0.0..
Building executable 'shikigami' for shikigami-cli-0.1.0.0..
```

Expected second run:

```text
Up to date
```

This closes M1.

### Step 2 — M2: migration composition, suppression table, scope helper

**Step 2.1 — `Shikigami.Migrations`.** Replace `shikigami-migrations/src/Shikigami/Migrations.hs`
with the real composition (modeled on kioku's `Kioku.Migrations`):

```haskell
{-# LANGUAGE ScopedTypeVariables #-}
{-# LANGUAGE TemplateHaskell #-}

module Shikigami.Migrations
  ( shikigamiOwnMigrations,
    shikigamiMigrations,
    runShikigamiMigrations,
    runShikigamiMigrationsNoCheck,
  )
where

import Codd (ApplyResult (SchemasNotVerified), CoddSettings, VerifySchemas, applyMigrations, applyMigrationsNoCheck)
import Codd.Logging (runCoddLogger)
import Codd.Parsing (AddedSqlMigration, EnvVars, PureStream (..), parseAddedSqlMigration)
import Data.ByteString (ByteString)
import Data.FileEmbed (embedDir)
import Data.List (sortOn)
import Data.Text.Encoding qualified as TE
import Data.Time (DiffTime)
import Kioku.Migrations (kiokuMigrations)
import Streaming.Prelude qualified as Streaming

-- | Parse shikigami's OWN embedded SQL files (currently just shikigami_fired).
shikigamiOwnMigrations :: (MonadFail m, EnvVars m) => m [AddedSqlMigration m]
shikigamiOwnMigrations =
  traverse parseEmbeddedMigration embeddedFiles
  where
    parseEmbeddedMigration :: forall m. (MonadFail m, EnvVars m) => (FilePath, ByteString) -> m (AddedSqlMigration m)
    parseEmbeddedMigration (name, bytes) = do
      let stream :: PureStream m
          stream = PureStream $ Streaming.yield (TE.decodeUtf8 bytes)
      result <- parseAddedSqlMigration name stream
      case result of
        Left err -> fail ("Invalid shikigami migration " <> name <> ": " <> err)
        Right migration -> pure migration

-- | The full shikigami migration set. IMPORTANT: kiokuMigrations ALREADY composes
-- kirokuMigrations <> keiroFrameworkMigrations <> kiokuOwnMigrations (see
-- /Users/shinzui/Keikaku/bokuno/kioku/kioku-migrations/src/Kioku/Migrations.hs), so we
-- must NOT prepend kiroku/keiro again or codd will reject the duplicate timestamps.
shikigamiMigrations :: (MonadFail m, EnvVars m) => m [AddedSqlMigration m]
shikigamiMigrations = do
  kioku <- kiokuMigrations
  own <- shikigamiOwnMigrations
  pure (kioku <> own)

runShikigamiMigrations :: CoddSettings -> DiffTime -> VerifySchemas -> IO ApplyResult
runShikigamiMigrations settings connectTimeout verifySchemas =
  runCoddLogger do
    migrations <- shikigamiMigrations
    applyMigrations settings (Just migrations) connectTimeout verifySchemas

runShikigamiMigrationsNoCheck :: CoddSettings -> DiffTime -> IO ApplyResult
runShikigamiMigrationsNoCheck settings connectTimeout =
  runCoddLogger do
    migrations <- shikigamiMigrations
    applyMigrationsNoCheck settings (Just migrations) connectTimeout (const (pure SchemasNotVerified))

embeddedFiles :: [(FilePath, ByteString)]
embeddedFiles = sortOn fst $(embedDir "sql-migrations")
```

**Step 2.2 — the suppression-table SQL.** Create the migration file (the leading timestamp is how codd
orders it):

```bash
# If the Justfile is in place you can scaffold the file:
just new-migration shikigami-fired
# else create it by hand: shikigami-migrations/sql-migrations/0001-shikigami-fired.sql
```

Its body (the DDL is copied verbatim from `agents/detectors/README.md`; the `search_path` line follows
the kizashi convention so the unqualified `CREATE TABLE` lands in the `kiroku` schema):

```sql
-- codd: in-txn

-- Migration: shikigami-fired
-- shikigami stores agent RUNS as kioku Sessions (kioku_sessions), so there is NO
-- bespoke agent_runs table. The only shikigami-owned table is the detector
-- suppression table below, keyed (detector, subject, window) so a still-true
-- condition does not re-raise a signal on every evaluation tick.
SET search_path TO kiroku, pg_catalog;

CREATE TABLE IF NOT EXISTS shikigami_fired (
  detector     TEXT        NOT NULL,
  subject_type TEXT        NOT NULL,
  subject_id   TEXT        NOT NULL,
  window_key   TEXT        NOT NULL,
  signal_id    TEXT        NOT NULL,
  fired_at     TIMESTAMPTZ NOT NULL DEFAULT now(),
  PRIMARY KEY (detector, subject_type, subject_id, window_key)
);
```

**Step 2.3 — the migrate executable.** `shikigami-migrations/app/Main.hs`:

```haskell
module Main (main) where

import Codd.Environment (getCoddSettings)
import Data.Time (secondsToDiffTime)
import Shikigami.Migrations (runShikigamiMigrationsNoCheck)

main :: IO ()
main = do
  settings <- getCoddSettings
  _ <- runShikigamiMigrationsNoCheck settings (secondsToDiffTime 5)
  pure ()
```

**Step 2.4 — the test-support sublibrary.**
`shikigami-migrations/test-support/Shikigami/Migrations/TestSupport.hs` (modeled on kioku's):

```haskell
module Shikigami.Migrations.TestSupport
  ( withShikigamiMigratedDatabase,
  )
where

import Codd (CoddSettings (..))
import Codd.Parsing (connStringParser)
import Codd.Representations.Types (DbRep (..))
import Codd.Types (ConnectionString, SchemaAlgo (..), SchemaSelection (..), SqlSchema (..), TxnIsolationLvl (..), singleTryPolicy)
import Data.Aeson (Value (Null))
import Data.Attoparsec.Text (endOfInput, parseOnly)
import Data.Map qualified as Map
import Data.Text (Text)
import Data.Time (secondsToDiffTime)
import EphemeralPg qualified as Pg
import Shikigami.Migrations (runShikigamiMigrationsNoCheck)

withShikigamiMigratedDatabase :: (Text -> IO a) -> IO a
withShikigamiMigratedDatabase action = do
  result <- Pg.withCached $ \db -> do
    let connStr = Pg.connectionString db
    _ <- runShikigamiMigrationsNoCheck (testCoddSettings connStr) (secondsToDiffTime 5)
    action connStr
  case result of
    Left err -> error ("Failed to start ephemeral PostgreSQL: " <> show err)
    Right value -> pure value

testCoddSettings :: Text -> CoddSettings
testCoddSettings connStr =
  CoddSettings
    { migsConnString = parseConnString connStr,
      sqlMigrations = [],
      onDiskReps = Right (DbRep Null Map.empty Map.empty),
      namespacesToCheck = IncludeSchemas [SqlSchema "kiroku", SqlSchema "public"],
      extraRolesToCheck = [],
      retryPolicy = singleTryPolicy,
      txnIsolationLvl = DbDefault,
      schemaAlgoOpts = SchemaAlgo False False False
    }

parseConnString :: Text -> ConnectionString
parseConnString connStr =
  case parseOnly (connStringParser <* endOfInput) connStr of
    Left err -> error ("Could not parse ephemeral PostgreSQL connection string for codd: " <> err)
    Right parsed -> parsed
```

**Step 2.5 — the scope helper.** `shikigami-core/src/Shikigami/Memory/Scope.hs`:

```haskell
module Shikigami.Memory.Scope
  ( shikigamiNamespace,
    agentScope,
    sharedScope,
  )
where

import Data.Text (Text)
import Kioku.Api.Scope (MemoryScope (..), Namespace (..), ScopeKind (..))

-- | The shikigami namespace used for every shikigami-owned memory/session.
shikigamiNamespace :: Namespace
shikigamiNamespace = Namespace "shikigami"

-- | Per-agent memory scope: everything THIS agent learned across its own runs.
-- Keyed by the agent's stable declared name (not a run id) so it is stable.
agentScope :: Text -> MemoryScope
agentScope agentName = ScopeEntity shikigamiNamespace (ScopeKind "agent") agentName

-- | Cross-agent shared learnings any shikigami agent may consult.
sharedScope :: MemoryScope
sharedScope = ScopeGlobal shikigamiNamespace
```

Add `Shikigami.Memory.Scope` to `shikigami-core.cabal` `exposed-modules`.

**Step 2.6 — build and migrate.**

```bash
cabal build all
just create-database
psql -h "$PGHOST" -d "$PGDATABASE" -c '\dt kiroku.kioku_*'
psql -h "$PGHOST" -d "$PGDATABASE" -c '\dt kiroku.shikigami_fired'
psql -h "$PGHOST" -d "$PGDATABASE" -c '\dt kiroku.agent_runs'
```

Expected `\dt kiroku.kioku_*` (closes the kioku half of M2):

```text
            List of relations
 Schema |      Name      | Type  | Owner
--------+----------------+-------+-------
 kiroku | kioku_memories | table | ...
 kiroku | kioku_sessions | table | ...
 kiroku | kioku_turns    | table | ...
```

Expected `\dt kiroku.shikigami_fired`:

```text
              List of relations
 Schema |      Name       | Type  | Owner
--------+-----------------+-------+-------
 kiroku | shikigami_fired | table | ...
```

Expected `\dt kiroku.agent_runs` (proving the no-`agent_runs` decision):

```text
Did not find any relation named "kiroku.agent_runs".
```

This closes M2.

### Step 3 — M3: schema, wire types, loader, validate CLI

**Step 3.1 — `schema/Agent.dhall`.** Create `/Users/shinzui/Keikaku/bokuno/shikigami/schema/Agent.dhall`:

```dhall
-- schema/Agent.dhall — the canonical C5 agent-definition schema (EP-1, IP-2).
-- This is the SUPERSET reconciling the spec's illustrative schema (docs/initial-spec.md)
-- and the seed detector schema (agents/detectors/schema.dhall). EP-6 re-points the seeds
-- at this file as a mechanical rename (singular `sink` -> `sinks = [ ... ]`; Observe ->
-- Stream; Deterministic kept; RaiseSignal -> KizashiSignal).

let SignalType =
      < Notification | Alert | Reminder | TaskCandidate | DigestItem | AgentRequest >

let Priority = < Low | Normal | High | Urgent >

let RecipientFrom = < SubjectOwner | AreaOwner | Actor >

-- C3's three trigger classes, named to match the spec's C5 vocabulary.
let StreamMatch =
      { verb : Optional Text
      , source : Optional Text
      , subjectType : Optional Text
      , verbs : List Text          -- the seeds' multi-verb match (empty = any verb)
      }

let Trigger =
      < Schedule : { cron : Text }
      | Stream : { match : StreamMatch }
      | Event : { eventType : Text }
      >

-- The behavior union covers all three arms the seeds and the spec need.
let Behavior =
      < Deterministic :
          { rule : Text, params : List { mapKey : Text, mapValue : Text } }
      | ShikumiProgram :
          { task : Text
          , preferEnrichment : Bool
          , grounding : Optional Text
          , enabledBy : Optional Text
          }
      | Skill : { path : Text }
      >

-- The producer sink set. KizashiSignal carries the seeds' rich RaiseSignal fields.
let Sink =
      < KawaDigest : { subjectType : Text, verb : Text }
      | KizashiSignal :
          { source : Text
          , signalType : SignalType
          , priority : Priority
          , importance : Natural
          , recipientFrom : RecipientFrom
          , defaultRecipient : Optional Text
          , intentTemplate : Text
          , extraContextTags : List Text
          }
      | ReiAction : { intentionId : Text, note : Text }
      | DanwaConversation : { topic : Text }
      >

let Agent =
      { Type =
          { name : Text
          , description : Text
          , trigger : Trigger
          , behavior : Behavior
          , sinks : List Sink
          }
      , default = { description = "", sinks = [] : List Sink }
      }

in  { SignalType
    , Priority
    , RecipientFrom
    , StreamMatch
    , Trigger
    , Behavior
    , Sink
    , Agent
    }
```

**Step 3.2 — the wire types.** `shikigami-api/src/Shikigami/Api/Agent.hs`. The Haskell records mirror
the Dhall unions field-for-field; the generic `FromDhall` default decodes them, and a small
`InterpretOptions` is unnecessary because the constructor and field names already match the Dhall
schema. (If a name needs adjusting, override `autoWith` with `genericAutoWith` plus an
`InterpretOptions { constructorModifier, fieldModifier }`; the default identity modifiers work here.)

```haskell
{-# LANGUAGE DeriveAnyClass #-}
{-# LANGUAGE DeriveGeneric #-}

module Shikigami.Api.Agent
  ( AgentDecl (..),
    Behavior (..),
    Trigger (..),
    StreamMatch (..),
    Sink (..),
    SignalType (..),
    Priority (..),
    RecipientFrom (..),
  )
where

import Data.Map.Strict (Map)
import Dhall (FromDhall)
import GHC.Generics (Generic)
import Shikigami.Prelude

data SignalType
  = Notification | Alert | Reminder | TaskCandidate | DigestItem | AgentRequest
  deriving stock (Eq, Show, Generic)
  deriving anyclass (FromDhall, ToJSON, FromJSON)

data Priority = Low | Normal | High | Urgent
  deriving stock (Eq, Show, Generic)
  deriving anyclass (FromDhall, ToJSON, FromJSON)

data RecipientFrom = SubjectOwner | AreaOwner | Actor
  deriving stock (Eq, Show, Generic)
  deriving anyclass (FromDhall, ToJSON, FromJSON)

data StreamMatch = StreamMatch
  { verb :: !(Maybe Text),
    source :: !(Maybe Text),
    subjectType :: !(Maybe Text),
    verbs :: ![Text]
  }
  deriving stock (Eq, Show, Generic)
  deriving anyclass (FromDhall, ToJSON, FromJSON)

data Trigger
  = Schedule {cron :: !Text}
  | Stream {match :: !StreamMatch}
  | Event {eventType :: !Text}
  deriving stock (Eq, Show, Generic)
  deriving anyclass (FromDhall, ToJSON, FromJSON)

data Behavior
  = Deterministic {rule :: !Text, params :: !(Map Text Text)}
  | ShikumiProgram
      { task :: !Text,
        preferEnrichment :: !Bool,
        grounding :: !(Maybe Text),
        enabledBy :: !(Maybe Text)
      }
  | Skill {path :: !Text}
  deriving stock (Eq, Show, Generic)
  deriving anyclass (FromDhall, ToJSON, FromJSON)

data Sink
  = KawaDigest {subjectType :: !Text, verb :: !Text}
  | KizashiSignal
      { source :: !Text,
        signalType :: !SignalType,
        priority :: !Priority,
        importance :: !Natural,
        recipientFrom :: !RecipientFrom,
        defaultRecipient :: !(Maybe Text),
        intentTemplate :: !Text,
        extraContextTags :: ![Text]
      }
  | ReiAction {intentionId :: !Text, note :: !Text}
  | DanwaConversation {topic :: !Text}
  deriving stock (Eq, Show, Generic)
  deriving anyclass (FromDhall, ToJSON, FromJSON)

data AgentDecl = AgentDecl
  { name :: !Text,
    description :: !Text,
    trigger :: !Trigger,
    behavior :: !Behavior,
    sinks :: ![Sink]
  }
  deriving stock (Eq, Show, Generic)
  deriving anyclass (FromDhall, ToJSON, FromJSON)
```

Notes for the implementer: `Natural` comes from `Numeric.Natural` (in `base`); add the import. The
Dhall `params : List { mapKey : Text, mapValue : Text }` decodes into a `Map Text Text` because
`dhall`'s `FromDhall (Map k v)` expects exactly that `mapKey`/`mapValue` shape — this is why the
schema uses `toMap`/that record shape. `aeson`'s default generic encoding is acceptable here since the
worker only needs round-trip for its own use; if you prefer the tagged `eventAesonOptions` encoding,
write explicit `instance ToJSON`/`FromJSON` using `genericToJSON eventAesonOptions` — but the derived
anyclass instances are sufficient for EP-1's acceptance (the `validate` output uses `Show`, not JSON).
After writing this module, uncomment `Shikigami.Api.Agent` in `shikigami-api.cabal` and add `dhall`,
`containers` to its `build-depends` (already listed).

**Step 3.3 — the activity envelope.** `shikigami-api/src/Shikigami/Api/Activity.hs` (IP-6):

```haskell
module Shikigami.Api.Activity
  ( ActivityEnvelope (..),
    Actor (..),
    Subject (..),
    ContextRef (..),
  )
where

import Data.Aeson (FromJSON (..), ToJSON (..), Value, genericParseJSON, genericToJSON)
import GHC.Generics (Generic)
import Shikigami.Prelude

-- aeson options that snake_case field names so the C1 wire keys round-trip.
activityOptions :: Options
activityOptions = defaultOptions {fieldLabelModifier = camelTo2 '_'}

data Actor = Actor
  { kind :: !Text,           -- "human" | "agent" | "service"
    id :: !Text,
    session :: !(Maybe Text)
  }
  deriving stock (Eq, Show, Generic)

instance ToJSON Actor where toJSON = genericToJSON activityOptions
instance FromJSON Actor where parseJSON = genericParseJSON activityOptions

data Subject = Subject {subjectType :: !Text, subjectId :: !Text}
  deriving stock (Eq, Show, Generic)

-- subjectType -> "type", subjectId -> "id" require a custom modifier:
subjectOptions :: Options
subjectOptions =
  defaultOptions
    { fieldLabelModifier = \f -> case f of
        "subjectType" -> "type"
        "subjectId" -> "id"
        other -> other
    }

instance ToJSON Subject where toJSON = genericToJSON subjectOptions
instance FromJSON Subject where parseJSON = genericParseJSON subjectOptions

data ContextRef = ContextRef {scheme :: !Text, ref :: !Text}
  deriving stock (Eq, Show, Generic)
  deriving anyclass (ToJSON, FromJSON)

data ActivityEnvelope = ActivityEnvelope
  { activityId :: !Text,            -- UUIDv7 string
    occurredAt :: !Text,            -- RFC3339 timestamp
    source :: !Text,                -- "shinzui/shikigami"
    actor :: !Actor,
    subject :: !Subject,
    verb :: !Text,                  -- past-tense dotted string
    payload :: !Value,              -- free-form JSON body
    contextRefs :: ![ContextRef],
    idempotencyKey :: !Text
  }
  deriving stock (Eq, Show, Generic)

instance ToJSON ActivityEnvelope where toJSON = genericToJSON activityOptions
instance FromJSON ActivityEnvelope where parseJSON = genericParseJSON activityOptions
```

Add `Shikigami.Api.Activity` to `shikigami-api.cabal` `exposed-modules`.

**Step 3.4 — the loader.** `shikigami-core/src/Shikigami/Agent/Loader.hs`:

```haskell
module Shikigami.Agent.Loader
  ( LoadError (..),
    loadAgent,
  )
where

import Control.Exception (SomeException, try)
import Dhall (auto, inputFile)
import Shikigami.Api.Agent (AgentDecl)
import Shikigami.Prelude

-- | A typed loader error. The Text carries Dhall's own (already very precise)
-- type-error / parse-error message.
newtype LoadError = LoadError Text
  deriving stock (Eq, Show)

-- | Parse and type-check a Dhall agent manifest into an AgentDecl. Returns Left
-- with a typed error if the file does not exist, fails to parse, or does not
-- type-check against the AgentDecl shape.
loadAgent :: FilePath -> IO (Either LoadError AgentDecl)
loadAgent path = do
  result <- try (inputFile auto path) :: IO (Either SomeException AgentDecl)
  pure $ case result of
    Left err -> Left (LoadError (show err & fromString))
    Right decl -> Right decl
  where
    fromString = id @Text . Data.Text.pack
```

Implementer note: `inputFile :: FromDhall a => Decoder a -> FilePath -> IO a` and `auto :: FromDhall a
=> Decoder a` come from `Dhall`. The `try` catches Dhall's `SomeException` (which covers
`InvalidDecoder`, `ExtractErrors`, import failures, and type errors); `show err` yields Dhall's
human-readable message. Replace the `fromString`/`& fromString` sketch with a clean
`Data.Text.pack (show err)` and `import Data.Text qualified as Text` — the sketch above is only to show
the shape; the final code should be `Left (LoadError (Text.pack (show err)))`.

**Step 3.5 — the skill validator.** `shikigami-core/src/Shikigami/Agent/Skill.hs`:

```haskell
module Shikigami.Agent.Skill
  ( SkillError (..),
    validateSkill,
  )
where

import Data.Text qualified as Text
import Data.Yaml qualified as Yaml
import System.Directory (doesDirectoryExist, doesFileExist)
import System.FilePath (takeBaseName, (</>))
import Shikigami.Prelude

data SkillError
  = SkillDirMissing FilePath
  | SkillMdMissing FilePath
  | SkillFrontMatterMissing FilePath
  | SkillFrontMatterInvalid Text
  | SkillNameMismatch {expected :: !Text, found :: !Text}
  | SkillDescriptionMissing
  deriving stock (Eq, Show)

-- | Validate a skill directory the way `skills-ref validate` does: the directory
-- exists, SKILL.md exists, its YAML front-matter parses, `name` equals the
-- directory base name, and `description` is present and non-empty.
validateSkill :: FilePath -> IO (Either SkillError ())
validateSkill dir = do
  dirOk <- doesDirectoryExist dir
  if not dirOk
    then pure (Left (SkillDirMissing dir))
    else do
      let mdPath = dir </> "SKILL.md"
      mdOk <- doesFileExist mdPath
      if not mdOk
        then pure (Left (SkillMdMissing mdPath))
        else do
          body <- Text.pack <$> readFile mdPath
          pure (validateFrontMatter (takeBaseName dir) body)

-- | Split off the YAML front-matter (between the leading "---" and the next
-- "---"), parse it, and check name + description.
validateFrontMatter :: String -> Text -> Either SkillError ()
validateFrontMatter dirBase body =
  case frontMatter body of
    Nothing -> Left (SkillFrontMatterMissing "SKILL.md")
    Just yamlText ->
      case Yaml.decodeEither' (Text.encodeUtf8 yamlText) of
        Left err -> Left (SkillFrontMatterInvalid (Text.pack (show err)))
        Right (fm :: Yaml.Value) -> checkFields dirBase fm
  where
    frontMatter t =
      case Text.lines t of
        ("---" : rest) ->
          let (fm, _) = break (== "---") rest
           in Just (Text.unlines fm)
        _ -> Nothing
    -- checkFields extracts `name`/`description` from the parsed YAML Value and
    -- compares name to dirBase; left as an exercise using Data.Aeson lenses or
    -- Yaml.parseEither. Returns SkillNameMismatch / SkillDescriptionMissing as
    -- appropriate, or Right ().
    checkFields = undefined  -- implement with aeson key lookups (see note)
```

Implementer note: complete `checkFields` by treating the parsed `Yaml.Value` (which is an `aeson`
`Value`) as an object and reading `name`/`description` keys with `Data.Aeson.KeyMap`/`parseMaybe`.
Compare `name` (as `Text`) to `Text.pack dirBase`; return `SkillNameMismatch` on inequality, and
`SkillDescriptionMissing` if `description` is absent or empty; otherwise `Right ()`. Add `readFile`
via `System.IO`'s default (or use `Data.Text.IO.readFile` for `Text` directly and drop the
`Text.pack`). Add `Text.encodeUtf8` from `Data.Text.Encoding`. This module needs `yaml`, `directory`,
`filepath`, `aeson`, `text` (all already in `shikigami-core.cabal`). Add `Shikigami.Agent.Loader` and
`Shikigami.Agent.Skill` to `shikigami-core.cabal` `exposed-modules`.

**Step 3.6 — the CLI.** `shikigami-cli/src/Shikigami/Cli/Commands/Validate.hs`:

```haskell
module Shikigami.Cli.Commands.Validate
  ( runValidate,
  )
where

import Shikigami.Agent.Loader (LoadError (..), loadAgent)
import Shikigami.Agent.Skill (validateSkill)
import Shikigami.Api.Agent (AgentDecl (..), Behavior (..))
import System.Exit (exitFailure)
import System.IO (hPutStrLn, stderr)

runValidate :: FilePath -> IO ()
runValidate path = do
  result <- loadAgent path
  case result of
    Left (LoadError msg) -> do
      hPutStrLn stderr ("validate: load error in " <> path <> ":\n" <> show msg)
      exitFailure
    Right decl -> do
      print decl                      -- the Show-rendered manifest
      case behavior decl of
        Skill {path = skillDir} -> do
          skillResult <- validateSkill (toString skillDir)
          case skillResult of
            Left err -> do
              hPutStrLn stderr ("validate: skill error: " <> show err)
              exitFailure
            Right () -> putStrLn ("OK: 1 agent parsed (skill " <> toString skillDir <> " valid).")
        _ -> putStrLn "OK: 1 agent parsed."
  where
    toString = id  -- replace with Data.Text.unpack on the Text field
```

`shikigami-cli/src/Shikigami/Cli.hs` (replaces the M1 stub):

```haskell
module Shikigami.Cli (main) where

import Options.Applicative
import Shikigami.Cli.Commands.Validate (runValidate)

newtype Command = Validate FilePath

main :: IO ()
main = run =<< execParser opts
  where
    opts = info (parser <**> helper) (fullDesc <> progDesc "shikigami declared-agent runtime")

parser :: Parser Command
parser =
  subparser
    ( command "validate"
        (info (Validate <$> argument str (metavar "FILE"))
              (progDesc "Parse and validate an agent manifest (.dhall)"))
    )

run :: Command -> IO ()
run (Validate file) = runValidate file
```

Add `Shikigami.Cli.Commands.Validate` to `shikigami-cli.cabal` `exposed-modules`.

**Step 3.7 — sample manifests and a skill.** Create:

`agents/heartbeat.dhall`:

```dhall
let A = ../schema/Agent.dhall
in  A.Agent::{
    , name = "heartbeat"
    , behavior =
        A.Behavior.ShikumiProgram
          { task = "noop-summary"
          , preferEnrichment = False
          , grounding = None Text
          , enabledBy = None Text
          }
    , trigger = A.Trigger.Schedule { cron = "* * * * *" }
    , sinks = [ A.Sink.KawaDigest { subjectType = "heartbeat", verb = "heartbeat.tick" } ]
    }
```

`agents/triage-note.dhall`:

```dhall
let A = ../schema/Agent.dhall
in  A.Agent::{
    , name = "triage-note"
    , behavior = A.Behavior.Skill { path = "agents/skills/triage-note" }
    , trigger =
        A.Trigger.Stream
          { match =
              { verb = Some "ticket.received"
              , source = None Text
              , subjectType = Some "ticket"
              , verbs = [] : List Text
              }
          }
    , sinks =
        [ A.Sink.KizashiSignal
            { source = "shinzui/shikigami"
            , signalType = A.SignalType.TaskCandidate
            , priority = A.Priority.Normal
            , importance = 45
            , recipientFrom = A.RecipientFrom.SubjectOwner
            , defaultRecipient = Some "person:nadeem"
            , intentTemplate = "triage this ticket"
            , extraContextTags = [ "verb:ticket.received", "subject:ticket" ]
            }
        ]
    }
```

`agents/skills/triage-note/SKILL.md`:

```text
---
name: triage-note
description: Read a support ticket and draft a one-line triage note for the owner.
---

# Triage Note

Read the ticket text in the trigger payload and produce a concise triage note.
```

`agents/broken.dhall` (deliberately malformed — references a field that does not exist):

```dhall
let A = ../schema/Agent.dhall
in  A.Agent::{
    , name = "broken"
    , behaviour = A.Behavior.Skill { path = "agents/skills/triage-note" }   -- typo: behaviour vs behavior
    , trigger = A.Trigger.Schedule { cron = "* * * * *" }
    }
```

**Step 3.8 — build and run validate.**

```bash
cabal build all
cabal run shikigami -- validate agents/heartbeat.dhall
```

Expected (closes the success path of M3):

```text
AgentDecl {name = "heartbeat", description = "", trigger = Schedule {cron = "* * * * *"}, behavior = ShikumiProgram {task = "noop-summary", preferEnrichment = False, grounding = Nothing, enabledBy = Nothing}, sinks = [KawaDigest {subjectType = "heartbeat", verb = "heartbeat.tick"}]}
OK: 1 agent parsed.
```

Skill-agent path:

```bash
cabal run shikigami -- validate agents/triage-note.dhall
```

Expected:

```text
AgentDecl {name = "triage-note", ... behavior = Skill {path = "agents/skills/triage-note"}, ...}
OK: 1 agent parsed (skill agents/skills/triage-note valid).
```

Malformed path (note the non-zero exit):

```bash
cabal run shikigami -- validate agents/broken.dhall ; echo "exit=$?"
```

Expected (the exact Dhall message will be longer; the key facts are the error and `exit=1`):

```text
validate: load error in agents/broken.dhall:
"... Expression: A.Agent::{ ... } ... extra/missing field `behaviour` ... "
exit=1
```

Skill-front-matter-failure path: temporarily edit `agents/skills/triage-note/SKILL.md`'s `name:` to
`name: wrong`, re-run `validate agents/triage-note.dhall`, and confirm it prints a
`SkillNameMismatch` error and exits non-zero; then restore the file. This closes M3.


## Validation and Acceptance

Acceptance is behavioral: each item is a command a human runs and an output they compare. All
commands run from `/Users/shinzui/Keikaku/bokuno/shikigami` in the Nix dev shell.

1. **M1 — the project builds (observable green build).** `cabal build all` exits 0; a second
   `cabal build all` reports `Up to date`. This proves the kioku + kikan + handan/shikumi/baikai/
   kafka-effectful/dhall pin-set resolves into one coherent package set. If it fails to resolve, the
   pin block diverged from kioku's — see Idempotence and Recovery.

2. **M2 — migrations compose and apply (observable schema).** `just create-database` exits 0;
   `psql -h "$PGHOST" -d "$PGDATABASE" -c '\dt kiroku.kioku_*'` lists `kioku_memories`,
   `kioku_sessions`, `kioku_turns`; `psql ... -c '\dt kiroku.shikigami_fired'` shows the table;
   `psql ... -c '\dt kiroku.agent_runs'` reports "Did not find any relation" (the no-`agent_runs`
   proof). Re-running `just create-database` is a no-op (codd skips applied migrations). A fast
   CI-style check of the composition is the test-support sublibrary: a tiny `tasty`/`hspec` test that
   calls `Shikigami.Migrations.TestSupport.withShikigamiMigratedDatabase (\_ -> ...)` and asserts the
   action runs without `relation "kioku_sessions" does not exist`, proving the composition stays wired
   on an ephemeral database with no external Postgres.

3. **M3 — `validate` parses a good manifest (observable success).** `cabal run shikigami -- validate
   agents/heartbeat.dhall` prints the `Show`-rendered `AgentDecl` and `OK: 1 agent parsed.`, exiting
   0. This is the headline user-visible behavior: you authored an agent in Dhall and the tool
   confirmed it is valid and typed.

4. **M3 — `validate` rejects a malformed manifest (observable typed error).** `cabal run shikigami --
   validate agents/broken.dhall ; echo "exit=$?"` prints a typed `LoadError` (Dhall's precise type/
   parse message) to stderr and `exit=1`. The program does not crash with an unhandled exception; it
   reports a structured error and a non-zero status.

5. **M3 — `validate` checks a skill-agent's `SKILL.md` (observable skill validation).** `cabal run
   shikigami -- validate agents/triage-note.dhall` parses the manifest *and* reports the skill
   directory + front-matter are valid (`OK: 1 agent parsed (skill ... valid).`). Corrupting the
   skill's `name:` to not match the directory makes the same command print a `SkillNameMismatch` and
   exit non-zero; restoring it returns to success. This proves the skill-specific validation path
   beyond mere Dhall parsing.

The change is effective beyond compilation because steps 3–5 exercise the loader and the skill
validator against real `.dhall` and `.md` files and demonstrate distinct success/failure behaviors.


## Idempotence and Recovery

- **Scaffold copies (Step 1).** Re-running the `cp`/`sed` for the `Justfile` overwrites it with
  identical content; safe to repeat. Authoring `cabal.project` and the `.cabal` files is idempotent
  (overwrite with the same content). Do **not** overwrite the seihou-managed `flake.nix`/`nix/*`/
  `process-compose.yaml`/`fourmolu.yaml`/`.envrc`.
- **Migrations (Step 2).** All kioku/kikan DDL is `CREATE ... IF NOT EXISTS` and the `shikigami_fired`
  DDL is too; codd records applied migrations by their leading timestamp and skips already-applied
  ones, so `just create-database` and `just migrate` are safe to re-run. If you add a `.sql` file
  after a prior `migrate`, the Justfile `migrate` recipe `touch`es
  `shikigami-migrations/shikigami-migrations.cabal` to force the `embedDir` splice to re-bake — without
  that touch a newly added migration is silently not embedded.
- **The double-apply trap.** If `just create-database` fails with a codd error about a duplicate or
  already-applied migration timestamp, the cause is the four-term migration chain (re-adding
  `kirokuMigrations`/`keiroFrameworkMigrations` on top of `kiokuMigrations`, which already includes
  them). Fix `Shikigami.Migrations.shikigamiMigrations` to be `kiokuMigrations <>
  shikigamiOwnMigrations` (see the Decision Log). To recover a half-migrated database, recreate it:
  `dropdb -h "$PGHOST" "$PGDATABASE" 2>/dev/null; just create-database`.
- **`relation "kioku_..." does not exist`.** Means a database was opened that did not apply kioku's
  migrations, or the pool's `search_path` is not `kiroku`. Re-run `just create-database`; kioku's
  read-model tables live in the `kiroku` schema and the migrate recipe sets `CODD_SCHEMAS=kiroku`.
- **Dependency-resolution conflict (Step 1 build).** Almost always means the pin block in
  `shikigami/cabal.project` diverged from kioku's. Make the `source-repository-package` stanzas
  byte-identical to `/Users/shinzui/Keikaku/bokuno/kioku/cabal.project` (in particular the kiroku tag
  must be `4312aa8c...`, not kizashi's `322096c8...`). Do **not** delete inplace `.conf`
  registrations to "fix" it — that re-solves into two incompatible hasql builds and forces a long
  clean rebuild (a known kikan-stack gotcha).
- **`validate` on a missing file.** `loadAgent` catches the IO/Dhall exception and returns
  `Left (LoadError ...)`, so `validate` prints a typed error and exits non-zero rather than crashing;
  re-running after creating the file succeeds.
- **Skill validation false-failure.** If `validate` reports `SkillDirMissing` for a path that exists,
  remember the skill `path` in the manifest is relative to the current working directory; run
  `validate` from the repo root (where `agents/skills/triage-note` resolves) or use an absolute path.


## Interfaces and Dependencies

This section names the exact types/functions/files that must exist at the end of each milestone and
restates the binding integration contracts (IP-1 … IP-9 from the MasterPlan,
`docs/masterplans/1-shikigami-declared-agent-runtime-bootstrap.md`). Sibling ExecPlans are referenced
only by path: `docs/plans/2-behavior-runner-and-kioku-session-and-memory-integration.md` (EP-2),
`docs/plans/3-sink-dispatcher-permission-gate-and-kawa-stub.md` (EP-3),
`docs/plans/4-trigger-evaluators-and-the-activity-v1-stream-consumer.md` (EP-4),
`docs/plans/5-the-supervised-worker-and-run-orchestration.md` (EP-5),
`docs/plans/6-end-to-end-living-loop-proof-and-detector-conformance.md` (EP-6).

### Libraries depended on (and why)

- `dhall` (the Haskell Dhall library, pinned by local path at
  `/Users/shinzui/Keikaku/hub/haskell/dhall-haskell-project/dhall-haskell/dhall`). Used by the loader.
  The load-bearing API (verified against its source `dhall/src/Dhall.hs` and
  `dhall/src/Dhall/Marshal/Decode.hs`): `input :: Decoder a -> Text -> IO a`,
  `inputFile :: Decoder a -> FilePath -> IO a`, `auto :: FromDhall a => Decoder a`, the class
  `FromDhall a where autoWith :: InputNormalizer -> Decoder a` (default `autoWith _ = genericAuto`),
  `genericAuto`/`genericAutoWith`, and the combinators `record`/`field`/`union`/`constructor` for any
  hand-written decoder. A Haskell record with a `Generic` instance and `deriving anyclass FromDhall`
  decodes from a Dhall record whose field names match; a Haskell sum type with matching constructor
  names decodes from a Dhall union. If a name must differ, override `autoWith = genericAutoWith
  InterpretOptions{ fieldModifier, constructorModifier }`. EP-1's wire types are designed so the
  identity modifiers suffice.
- `kioku-api` (local path `/Users/shinzui/Keikaku/bokuno/kioku/kioku-api`). Used for
  `Kioku.Api.Scope (Namespace (..), ScopeKind (..), MemoryScope (..))` — the scope helper maps into
  these (verified against `kioku-api/src/Kioku/Api/Scope.hs`:
  `data MemoryScope = ScopeGlobal Namespace | ScopeEntity Namespace ScopeKind Text`).
- `kioku-core` (local path). Pinned for the coherent solve; EP-1 itself does not call it (EP-2 uses
  `Kioku.Session`/`Kioku.Memory`/`Kioku.Recall`/`Kioku.App`). Listed in `shikigami-core` deps for the
  scope-helper package to share kioku's package set.
- `kioku-migrations` (local path). Used for `Kioku.Migrations (kiokuMigrations)`
  (verified `kioku-migrations/src/Kioku/Migrations.hs`:
  `kiokuMigrations :: (MonadFail m, EnvVars m) => m [AddedSqlMigration m]`, already = `kirokuMigrations
  <> keiroFrameworkMigrations <> kiokuOwnMigrations`).
- `codd`, `file-embed`, `streaming`, `bytestring`, `time`, `text` — the migration package, mirroring
  kioku-migrations.
- `ephemeral-pg`, `attoparsec`, `containers`, `aeson` — the test-support sublibrary.
- `yaml`, `directory`, `filepath` — the skill validator (`shikigami-core`).
- `optparse-applicative` — the CLI parser (`shikigami-cli`).
- `handan` (`/Users/shinzui/Keikaku/bokuno/handan/handan`), `shikumi` + `shikumi-trace`
  (`/Users/shinzui/Keikaku/bokuno/shikumi/...`), `baikai` + `baikai-claude` + `baikai-effectful`
  (`/Users/shinzui/Keikaku/bokuno/baikai/...`), `kafka-effectful`
  (`/Users/shinzui/Keikaku/bokuno/kafka-effectful/kafka-effectful`) — pinned in `cabal.project` now
  (IP-8) so later plans add no new pins. EP-1 does not import them.

### Module/function signatures by milestone

**End of M1.** A buildable four-package project: `Shikigami.Prelude` (no `Data.Generics.Labels`
re-export), `Shikigami.Core.shikigamiCoreVersion :: String`, `Shikigami.Cli.main :: IO ()` (stub),
`executable shikigami`, `executable shikigami-migrate`, and a `cabal.project` pinning the IP-8 set.

**End of M2.**

- `Shikigami.Migrations`: `shikigamiOwnMigrations :: (MonadFail m, EnvVars m) => m [AddedSqlMigration
  m]`, `shikigamiMigrations :: (MonadFail m, EnvVars m) => m [AddedSqlMigration m]` (= `kiokuMigrations
  <> shikigamiOwnMigrations`), `runShikigamiMigrations :: CoddSettings -> DiffTime -> VerifySchemas ->
  IO ApplyResult`, `runShikigamiMigrationsNoCheck :: CoddSettings -> DiffTime -> IO ApplyResult`.
- `Shikigami.Migrations.TestSupport`: `withShikigamiMigratedDatabase :: (Text -> IO a) -> IO a`.
- `Shikigami.Memory.Scope`: `shikigamiNamespace :: Namespace`, `agentScope :: Text -> MemoryScope`,
  `sharedScope :: MemoryScope`.
- The `shikigami_fired` table exists in the `kiroku` schema; no `agent_runs` table exists.

**End of M3.**

- `Shikigami.Api.Agent`: `data AgentDecl`, `data Behavior`, `data Trigger`, `data StreamMatch`,
  `data Sink`, `data SignalType`, `data Priority`, `data RecipientFrom` — all `deriving stock (Eq,
  Show, Generic)` and `deriving anyclass (FromDhall, ToJSON, FromJSON)`.
- `Shikigami.Api.Activity`: `data ActivityEnvelope` (nine C1 fields), `data Actor`, `data Subject`,
  `data ContextRef`, with `aeson` instances using snake_case keys.
- `Shikigami.Agent.Loader`: `data LoadError`, `loadAgent :: FilePath -> IO (Either LoadError
  AgentDecl)`.
- `Shikigami.Agent.Skill`: `data SkillError`, `validateSkill :: FilePath -> IO (Either SkillError ())`.
- `Shikigami.Cli.Commands.Validate.runValidate :: FilePath -> IO ()`; `Shikigami.Cli.main :: IO ()`
  with the `validate` subcommand.
- `schema/Agent.dhall` exporting `{ SignalType, Priority, RecipientFrom, StreamMatch, Trigger,
  Behavior, Sink, Agent }`.

### IP-1 — `shikigami-api` wire types (contract C5). EP-1 OWNS these.

The client-safe wire types live in `Shikigami.Api.Agent` with **no** `hasql`/`effectful`/`kiroku`
dependency, so the worker (EP-5) and CLI share them. The shapes are exactly the records in Step 3.2:
`AgentDecl { name, description, trigger, behavior, sinks }`; `Behavior = Deterministic {..} |
ShikumiProgram {..} | Skill {..}`; `Trigger = Schedule {..} | Stream {..} | Event {..}`; `StreamMatch
{ verb, source, subjectType, verbs }`; `Sink = KawaDigest {..} | KizashiSignal {..} | ReiAction {..} |
DanwaConversation {..}`. EP-2/EP-3/EP-4/EP-5 import these; none redefine them. Any field a Phase-2 plan
needs that is not present is added here in `shikigami-api` by amending this deliverable and recording
it in the MasterPlan's Integration Points. (Note EP-1 adds two fields beyond the spec's illustrative
shape: `AgentDecl.description` and the `ShikumiProgram` enrichment/grounding/enabledBy fields and the
`Deterministic` arm, all required to express the seed detectors — see IP-2.)

### IP-2 — `schema/Agent.dhall` (contract C5) + seed reconciliation. EP-1 OWNS it; EP-6 re-points seeds.

The canonical schema (Step 3.1) is the **superset** of the spec's illustrative schema and the seed
schema at `agents/detectors/schema.dhall`. The exact reconciliation (so EP-6's re-point is mechanical):

- **Behavior.** Spec: `< ShikumiProgram { task } | Skill { path } >`. Seeds: `< Deterministic { rule,
  params } | Program { program, preferEnrichment, grounding, enabledBy } | Skill { dir } >`. Canonical:
  `< Deterministic { rule, params } | ShikumiProgram { task, preferEnrichment, grounding, enabledBy } |
  Skill { path } >`. EP-6 maps the seeds' `Program` → `ShikumiProgram` (rename `program` → `task`),
  `Deterministic` → `Deterministic` (unchanged), and `Skill { dir }` → `Skill { path }` (rename
  `dir` → `path`).
- **Trigger.** Spec: `< Schedule | Stream { match } | Event >`. Seeds: `< Observe { topic, subjectType,
  verbs } | Schedule { cron } | Addressed { inbox } >`. Canonical: `< Schedule { cron } | Stream {
  match : StreamMatch } | Event { eventType } >` with `StreamMatch { verb, source, subjectType, verbs }`.
  EP-6 maps `Observe { topic, subjectType, verbs }` → `Stream { match = { verb = None Text, source =
  None Text, subjectType, verbs } }` (the seeds' `topic` is always `"activity.v1"`, the single contract
  topic, so it is implicit and dropped), and `Addressed { inbox }` → `Event { eventType = inbox }`.
- **Sink.** Spec: `< KawaDigest | KizashiSignal { signalType, priority } | ReiAction { note } |
  DanwaConversation >`. Seeds: `< RaiseSignal { source, signalType, priority, importance, recipientFrom,
  defaultRecipient, intentTemplate, extraContextTags } | RecordReiAction { command } >`. Canonical:
  folds the seeds' rich `RaiseSignal` fields into `KizashiSignal` (so `KizashiSignal` carries `source,
  signalType, priority, importance, recipientFrom, defaultRecipient, intentTemplate, extraContextTags`),
  keeps `KawaDigest`, makes `ReiAction { intentionId, note }` (the spec notes the real `ReiAction`
  carries the target intention id), and keeps `DanwaConversation { topic }`. EP-6 maps the seeds'
  `RaiseSignal {..}` → `KizashiSignal {..}` (field-for-field, same names) wrapped in `sinks = [ ... ]`,
  and `RecordReiAction { command }` → `ReiAction { intentionId = ..., note = command }`.
- **Cardinality.** Spec uses `sinks : List Sink`; the seeds use a singular `sink`. Canonical uses
  `sinks : List Sink`; EP-6 wraps each seed's singular `sink = X` as `sinks = [ X ]`.
- **`SignalType`/`Priority`/`RecipientFrom`.** Carried verbatim from the seed schema (so the seeds'
  `SignalType.Reminder`, `Priority.Normal`, `RecipientFrom.SubjectOwner` resolve unchanged after the
  import swap).

Because the canonical schema is a strict superset along every axis the seeds use, EP-6's task is the
mechanical rename above (and swapping `let Schema = ./schema.dhall` for `let A = ../../schema/Agent.dhall`),
not a redesign — which is exactly what IP-2 requires.

### IP-3 — kioku migration composition + `Shikigami.Memory.Scope` + `shikigami_fired`. EP-1 establishes.

`shikigami-migrations.shikigamiMigrations = kiokuMigrations <> shikigamiOwnMigrations` (the
double-apply-avoiding composition; see Decision Log). kioku's read-model tables (`kioku_memories`,
`kioku_sessions`, `kioku_turns`) live in the `kiroku` schema. shikigami's own migration creates only
`shikigami_fired` (DDL from `agents/detectors/README.md`) — **no `agent_runs`**. `Shikigami.Memory.Scope`
(in `shikigami-core`) maps an agent name to `ScopeEntity (Namespace "shikigami") (ScopeKind "agent")
<agentName>` and exposes `ScopeGlobal (Namespace "shikigami")`. EP-2 uses kioku's public API
(`Kioku.Session.start/complete/failSession/recordTurn`, `Kioku.Memory.record`,
`Kioku.Recall.getActiveByScope`, `Kioku.App.runAppIO/AppEnv/noopTracer`, the `kioku-api` types) for the
session/memory *use*; EP-1 only establishes the migration set and the scope helper.

### IP-6 — the Activity Envelope (contract C1). EP-1 DEFINES it.

`Shikigami.Api.Activity.ActivityEnvelope` is the nine-field record (Step 3.3) with `aeson`
`FromJSON`/`ToJSON` using snake_case keys so `activity_id`, `occurred_at`, `context_refs`,
`idempotency_key`, and the nested `actor {kind,id,session?}` / `subject {type,id}` / `context_refs
[{scheme,ref}]` round-trip. EP-3's `KawaDigest` sink **builds** it (with `actor.kind="agent"`,
`source="shinzui/shikigami"`, minting the UUIDv7 `activity_id`); EP-4's stream consumer **decodes** it
and runs the `matchesStream` predicate (excluding `actor.kind="agent"` by default). EP-1 only defines
the type and instances.

### IP-8 — the `cabal.project` pin-set. EP-1 OWNS it.

> **SUPERSEDED (2026-06-24).** Per the user's "use hackage and github, not corpus" directive, the
> co-developed shinzui deps are now pinned by **GitHub `source-repository-package` git stanzas** and
> `dhall` from **Hackage**, *not* by local path. The actual, authoritative pin-set is the on-disk
> `/Users/shinzui/Keikaku/bokuno/shikigami/cabal.project` (see the Decision Log entry "Pin the
> co-developed shinzui dependencies by GitHub … and dhall from Hackage" for the exact commits:
> kioku `608fbc9`, handan `d25fac3`, shikumi `36496de`, kafka-effectful `f34a43c`, baikai `a219ace`
> via kioku's kikan block, dhall from Hackage). The kikan git block is still copied byte-identically
> from kioku's `cabal.project`. The local-path block reproduced below is retained only as the historical
> record of the original (superseded) plan and the byte-identical kikan stanzas it documents.

The (now-superseded) local-path pin block was copied byte-identically from
`/Users/shinzui/Keikaku/bokuno/kioku/cabal.project` (its `source-repository-package` stanzas + footer),
with kioku's local-path `../shikumi/...` lines and its git `baikai` stanza removed. The resulting full
`cabal.project` was:

```text
packages:
  shikigami-api
  shikigami-core
  shikigami-cli
  shikigami-migrations
  /Users/shinzui/Keikaku/bokuno/kioku/kioku-api
  /Users/shinzui/Keikaku/bokuno/kioku/kioku-core
  /Users/shinzui/Keikaku/bokuno/kioku/kioku-cli
  /Users/shinzui/Keikaku/bokuno/kioku/kioku-migrations
  /Users/shinzui/Keikaku/bokuno/handan/handan
  /Users/shinzui/Keikaku/bokuno/shikumi/shikumi
  /Users/shinzui/Keikaku/bokuno/shikumi/shikumi-trace
  /Users/shinzui/Keikaku/bokuno/baikai/baikai
  /Users/shinzui/Keikaku/bokuno/baikai/baikai-claude
  /Users/shinzui/Keikaku/bokuno/baikai/baikai-effectful
  /Users/shinzui/Keikaku/bokuno/kafka-effectful/kafka-effectful
  /Users/shinzui/Keikaku/hub/haskell/dhall-haskell-project/dhall-haskell/dhall

with-compiler: ghc-9.12.4

source-repository-package
  type: git
  location: https://github.com/shinzui/keiki.git
  tag: bc987f46393b604c335f034385b4c3c1ad118074

source-repository-package
  type: git
  location: https://github.com/shinzui/keiki.git
  tag: bc987f46393b604c335f034385b4c3c1ad118074
  subdir: keiki-codec-json

source-repository-package
  type: git
  location: https://github.com/shinzui/keiro.git
  tag: f1d67a01b7457387a4861e7268d1c521ef82287d
  subdir: keiro

source-repository-package
  type: git
  location: https://github.com/shinzui/keiro.git
  tag: f1d67a01b7457387a4861e7268d1c521ef82287d
  subdir: keiro-core

source-repository-package
  type: git
  location: https://github.com/shinzui/keiro.git
  tag: f1d67a01b7457387a4861e7268d1c521ef82287d
  subdir: keiro-migrations

source-repository-package
  type: git
  location: https://github.com/shinzui/keiro.git
  tag: f1d67a01b7457387a4861e7268d1c521ef82287d
  subdir: keiro-pgmq

source-repository-package
  type: git
  location: https://github.com/shinzui/kiroku.git
  tag: 4312aa8cc3e4f6ab0d19fc8bb12d0dd9f8cc164a
  subdir: kiroku-store

source-repository-package
  type: git
  location: https://github.com/shinzui/kiroku.git
  tag: 4312aa8cc3e4f6ab0d19fc8bb12d0dd9f8cc164a
  subdir: kiroku-store-migrations

source-repository-package
  type: git
  location: https://github.com/shinzui/kiroku.git
  tag: 4312aa8cc3e4f6ab0d19fc8bb12d0dd9f8cc164a
  subdir: kiroku-test-support

source-repository-package
  type: git
  location: https://github.com/shinzui/kiroku.git
  tag: 4312aa8cc3e4f6ab0d19fc8bb12d0dd9f8cc164a
  subdir: shibuya-kiroku-adapter

source-repository-package
  type: git
  location: https://github.com/shinzui/shibuya.git
  tag: 3f276ee190e563fddb0bc81e01d62a96a1b31715
  subdir: shibuya-core

source-repository-package
  type: git
  location: https://github.com/shinzui/pgmq-hs.git
  tag: 973c1076f469448818de5d2044a483296be2c02e
  subdir: pgmq-core pgmq-hasql pgmq-effectful pgmq-migration

source-repository-package
  type: git
  location: https://github.com/shinzui/shibuya-pgmq-adapter.git
  tag: 71a7b82223449d84c395b64e480c9cfe4ff274f1
  subdir: shibuya-pgmq-adapter

source-repository-package
  type: git
  location: https://github.com/shinzui/hasql-migration
  tag: 4aaff6c0919d1fe8e1c248c3ce4ce05775c59c8c

source-repository-package
  type: git
  location: https://github.com/shinzui/ephemeral-pg.git
  tag: 304c160f25570ea5e225baf5024778c93f434b56

source-repository-package
  type: git
  location: https://github.com/shinzui/codd-project.git
  tag: d176b3088f23ef2218c7a1f31835e8ee0c0601aa
  subdir: codd

source-repository-package
  type: git
  location: https://github.com/shinzui/hasql-project.git
  tag: 2bc7ace5db942d87962990bba0b2323ec4c67770
  subdir: hasql-notifications

package codd
  tests: False
  benchmarks: False

package blake3
  flags: -avx512 -avx2 -sse41 -sse2
  ghc-options: -optc-DBLAKE3_USE_NEON=0

package postgresql-libpq
  flags: +use-pkg-config

allow-newer:
  haxl:time
```

**Release path (forward note).** Once kioku, handan, shikumi, baikai, and kafka-effectful are tagged,
the local-path `packages:` lines for those repos may be replaced by `source-repository-package` git
stanzas (e.g. one stanza `location: https://github.com/shinzui/kioku.git`, `tag: <kioku-EP-1-commit>`,
`subdir: kioku-api kioku-core kioku-cli kioku-migrations`), and the `dhall` local path by its Hackage
constraint. The kikan pin block stays byte-identical to kioku's regardless. Every other ExecPlan
inherits this `cabal.project` unchanged.

### IP-9 — coding conventions (haskell-jitsurei). Honored by every Haskell file here.

All Haskell across shikigami follows the binding conventions in
`/Users/shinzui/Keikaku/bokuno/haskell-jitsurei/` (browse with `mori registry docs haskell-jitsurei`):
GHC 9.12.4 + `GHC2024`; a `common common` cabal stanza enabling `DeriveAnyClass`,
`DuplicateRecordFields`, `OverloadedLabels`, `OverloadedStrings`, `MultilineStrings`, with every
library/exe/test stanza doing `import: common`; postpositive `qualified` imports (`import Data.Text
qualified as Text`, never `import qualified`); a `Shikigami.Prelude` that does **not** re-export
`Data.Generics.Labels` (the orphan `IsLabel` instance collides with the keiki DSL's `#label`
overloading); strict `!` fields, no field prefixes, explicit `deriving stock`/`anyclass`/`newtype`
strategies, lens operators over record-update syntax; and `eventAesonOptions` for event JSON. The
greenfield shikigami project adopts these from its first commit by mirroring the kioku/kizashi
structure. `cli/agents/claude-cli-pitfalls.md` applies if/when a later plan spawns `claude` (not in
EP-1).


## Revision Note

2026-06-24 — Initial authoring of EP-1. Filled all sections from the binding sources: the ExecPlan
spec (`.claude/skills/exec-plan/PLANS.md`), the shikigami spec (`docs/initial-spec.md`), the
MasterPlan (`docs/masterplans/1-shikigami-declared-agent-runtime-bootstrap.md`, IP-1/IP-2/IP-3/IP-6/
IP-8/IP-9), the seed detectors (`agents/detectors/*`), and the read-on-disk dependency sources: kioku
(`cabal.project`, `kioku-migrations/src/Kioku/Migrations.hs`, `kioku-api/src/Kioku/Api/Scope.hs`, the
prior-art plan `docs/plans/6-shikigami-memory-integration-with-kioku.md`), kizashi (`cabal.project`,
`Justfile`), and the Haskell `dhall` library (`Dhall.hs`, `Dhall/Marshal/Decode.hs`). Key load-bearing
discovery recorded in the Decision Log and Surprises: `kiokuMigrations` already composes
`kirokuMigrations <> keiroFrameworkMigrations <> kiokuOwnMigrations`, so the correct shikigami
composition is `kiokuMigrations <> shikigamiOwnMigrations` (the four-term chain the MasterPlan and the
kioku-side prior-art plan wrote would double-apply the framework migrations and fail codd). Designed
`schema/Agent.dhall` as the strict superset reconciling the spec and the seed detectors so EP-6's
re-point is a mechanical rename (IP-2). Pinned kioku/handan/shikumi/baikai/kafka-effectful/dhall by
local path with kioku's kikan pin block byte-identical (IP-8). Why these choices: EP-1 is the hard root
whose artifacts every sibling plan imports, so correctness of the migration composition, the wire-type
shapes, and the pin-set is more important than breadth — the plan deliberately stops at `validate` and
defers all runtime behavior to EP-2…EP-6.
