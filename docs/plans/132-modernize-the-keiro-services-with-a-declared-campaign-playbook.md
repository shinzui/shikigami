---
id: 132
slug: modernize-the-keiro-services-with-a-declared-campaign-playbook
title: "Modernize the keiro services with a declared campaign playbook"
kind: exec-plan
created_at: 2026-11-15T13:43:17Z
intention: "intention_01m7fq4tf3ejrt0tjxvsy8ejdt"
master_plan: "docs/masterplans/22-rebuild-shikigami-as-a-kernel-where-use-cases-are-declared-not-coded.md"
provenance:
  created_by:
    model: "claude-opus-5-5"
    harness: "claude-code"
    at: 2026-11-15T13:43:17Z
  revisions:
    - model: "claude-opus-5-5"
      harness: "claude-code"
      at: 2026-11-15T13:58:31Z
      mode: "other"
      note: "Drafted plan body under MasterPlan 22"
    - model: "claude-opus-5-5"
      harness: "claude-code"
      at: 2026-11-15T14:15:42Z
      mode: "discuss"
      note: "Applied user decisions of 2026-11-15 (repos, in-place placement, disposable databases, stalled-intention)"
    - model: "claude-fable-5-2"
      harness: "claude-code"
      at: 2026-11-15T14:47:54Z
      mode: "update"
      note: "MasterPlan 22 review cascade: EP-8 ports, payload and step-output items, durable Tool steps, drain rule and EP-11 baseline gate"
    - model: "claude-opus-5-5"
      harness: "claude-code"
      at: 2026-11-16T00:26:35Z
      mode: "implement"
      note: "M1 accepted: campaign declared, kanmon readiness in place; M2 waits on operator decisions"
    - model: "claude-opus-5-5"
      harness: "claude-code"
      at: 2026-11-18T02:50:27Z
      mode: "implement"
      note: "M3 accepted on koyomi: R8 readiness, per-edge selection, independent just check green; FRIC-100 to FRIC-115"
---

# Modernize the keiro services with a declared campaign playbook

This ExecPlan is a living document. The sections Progress, Surprises & Discoveries,
Decision Log, and Outcomes & Retrospective must be kept up to date as work proceeds.
If durable project context changes, update or create ADRs in docs/adr/ in the same change.
Record friction met while implementing in the friction-log bundle as it occurs (see FRICTION.md).


## Purpose / Big Picture

The operator owns about ten Haskell services built on keiro, the event-sourcing framework and
durable workflow engine at `mori://shinzui/keiro`. Most of them resolve keiro 0.22 while keiro
is at 0.25.0.0. Several also have a stale Mori registration, outdated plan skills, or no `mina`
intention parent. Modernizing one service by hand takes days of agent babysitting: run a
blueprint, notice it needed a configured build first, fix it, run the next one, write a plan,
execute it, and forget the lesson before the next repository.

After this plan, the operator starts one Shikigami playbook per repository, or per batch of
repositories, on their own Mac. A playbook is a Dhall-declared sequence of steps that
Shikigami runs durably: it survives a worker restart and pauses at human approval gates. For
each repository the playbook checks and fixes readiness (`mina`, Mori, Seihou plan skills and
a configured build). It selects the applicable Seihou blueprints from a catalog the operator
maintains. A blueprint is an agent-guided recipe published by a library; it is run with
`seihou agent run` or, for per-version upgrade edges, `seihou agent migrate`. The playbook
then writes a MasterPlan in the target repository with the `master-plan` skill and asks for
approval. It runs that MasterPlan's ExecPlans through coding-agent steps, runs the
repository's own build and tests, and records what it learned. Finally it proposes an
improvement to the playbook as a Git change. The next repository runs the improved playbook.

The user-visible proof is real repositories with new commits, Seihou receipts in
`.seihou/manifest.json`, a checked-in MasterPlan, passing builds and recorded learnings. The
second repository must visibly benefit from a lesson learned on the first. The campaign is
also the architectural acceptance test of MasterPlan 22
(`docs/masterplans/22-rebuild-shikigami-as-a-kernel-where-use-cases-are-declared-not-coded.md`):
it ships as declarations with no change to `shikigami-core`.


## Progress

- [x] Milestone 1 (2026-11-15): the repository list is confirmed with the user, the campaign declarations
  validate, and the pilot repository passes readiness through a real playbook run that
  stops after the readiness approval. The run is drained to a terminal state before any
  later shape change lands.
  Evidence: `agents/campaigns/keiro-modernization/` (declaration, `tools.dhall`,
  `repos.dhall` with the seven confirmed repositories, `playbook.dhall`) and
  `agents/skills/campaign-readiness`. `shikigami validate` parsed the declaration and
  `shikigami-local playbook validate` printed the step tree. ADR-27 recheck: no tags, no
  users, only this session's pilot journals (all terminal), and MasterPlan 22 does not record
  the end of the exception. kanmon was confirmed once with `InPlace` placement. Run
  `5738fce0-4f63-5308-8db3-9380d1b2d5d5` probed R1–R7 and its readiness agent committed
  `152c616` on kanmon's current branch (`mori schema upgrade` and `mori register` rewrote
  `mori.dhall`; a new `AGENTS.md`; `nix develop -c cabal build all --dry-run` wrote
  `dist-newstyle/cache/plan.json`). After approval the run completed. `mori status --json`
  now shows the schema `current` and the project registered, and `mina config show` resolves
  `root: /Users/shinzui/Keikaku/bokuno/kanmon`. Runs `1db7e350-…` and `e6227c3d-…`
  (after `seihou manifest upgrade` was declared) upgraded `.seihou/manifest.json` from schema 3
  to 15 (`bec8597`). R4 and R7 stay open: `seihou update exec-plan` needs an interactive
  resolution of the operator's own `.gitignore` edits, which the agent correctly refused to
  `--force`. Every run is terminal.
- [x] Milestone 2 (superseded on 2026-11-18 by Milestone 3): a full pilot run on the pilot repository, with the operator approving every
  gate. It ends with the work committed on kanmon's current branch, blueprint receipts, an
  executed MasterPlan, a green build, one recorded learning and one approved playbook
  change.
  - (2026-11-16) Stopped on the operator's decision and finished by hand. Kizashi run
    `c4341273-0d66-516c-a51b-b840d26be160` approved readiness, a selection of three blueprints
    and the MasterPlan (`8e74bc1`), then applied `fix-nix-haskell-flake-customizations`
    (`30191f5`, implemented in `b7669c2`) and keiro-upgrade 0.22→0.24 (`be9b920`). It stopped
    at 0.24 because the installed keiro-upgrade was 0.13.0, which has no 0.24→0.25 edge. By
    hand: `seihou upgrade keiro-upgrade` (0.14.0), installing the two Shibuya blueprints that
    edge entails, the 0.25 bounds and fallout, receipts and the 0033 migration (kizashi
    `75b4308`, `All 234 tests passed`). The run is parked at a durable wake and is not
    resumed (FRIC-80). migrate-keiro-stack (kizashi plan 49: six packages, Settei and a
    disposable-database proof) is not started.
  - (2026-11-16) The campaign's tail was validated instead with
    `agents/playbooks/build-repair.dhall` on a scratch Cabal package, in minutes rather than
    hours. Run `042ad7a9-…` probed a failing build, repaired it (one-file commit), passed the
    final build, reported the failing tests probe (`FAIL label of a negative price`) in the
    close approval without stopping, and reflected three learnings. Run `741c7724-…` was told to
    change nothing: its final build failed and the run ended `stopped`, with the step labelled
    `failed`. A later run's `fix-build` prompt quoted the earlier run's three learnings. This
    exposed and fixed FRIC-78 (a coding agent refused a checkout path over 128 characters) and
    FRIC-79 (learnings were never recalled across runs).
  - (2026-11-18) Superseded, by the user's decision. The pilot's purpose was a full run with
    every gate approved and the playbook improved from what it learned. Milestone 3's koyomi
    run `aa2b77a1-…` delivered that on the slimmed playbook. The kizashi run stays parked and
    is not resumed. migrate-keiro-stack moves to the batches (Milestone 4).
- [x] Milestone 3: a run on the second repository uses the improved playbook, and its
  transcript shows the repository-1 learning applied: a step skipped, reordered or given
  better instructions.
  - Evidence, 2026-11-17. Koyomi run `aa2b77a1-04e7-5384-8398-07b7e33947e0` approved all four
    gates (readiness, selection, MasterPlan, close) with the user, and took koyomi from keiro
    0.22 to 0.25 in commits `02f933f` to `1fe7bb7` on its master. The repository-1 learning
    shows in the transcript three ways:
    - The new `seihou outdated` probe and readiness check R8 ran before any planning and
      reported keiro-upgrade 0.14.1 current. The operator had upgraded it first, which is
      what the kizashi pilot lacked.
    - `migrate-keiro-stack` was skipped as deferred.
    - The upgrade ran one release edge at a time.
  - Koyomi's MasterPlan 2 and ExecPlan 9 record `just check` exit 0 on each committed edge. An
    independent `nix develop -c just check` on `1fe7bb7` exits 0, with 33 suites passing and
    no formatting change.
  - The first M3 run (`17f5c2fb-…`) stopped at its apply step on the 64 KiB prompt limit
    (FRIC-112). That led to the per-edge decision above.
  - The run ended `stopped` at `reflect`, because Reflect quotes the whole test output
    (FRIC-115). It therefore recorded no learning.
  - The playbook's bare `cabal test all` probe exited 1 on setup alone (FRIC-114).
  - Taking the run to its first gate on this machine took four launches (FRIC-100 to
    FRIC-105). Per-edge overhead is in FRIC-113.
- [x] DX pass before the batches (2026-11-18, user-approved): the costliest local-run friction
  of M3 is fixed in Shikigami and in the playbook. FRIC-100 and FRIC-101: `shikigami-agent-run`
  checks the vendor CLI, `shikigami-agent-launch`, `shikigami-local` and the Baikai ceiling
  before a local run's first step and refuses with the fix (`Shikigami.Agent.Preflight`);
  `shikigami-local doctor --agent … --workspace …` runs the same checks and the grant check.
  FRIC-105: the foreground driver no longer gives up after eight child rounds, so the first
  pass delivers an approval ask and prints `Run <ID> waits for approval`; local asks wait a
  day (`trust.local_operator.approval_deadline_seconds`). FRIC-104: a playbook output says
  `stoppedBy: environment` when the stopping step could not be attempted, and the run records
  no learning for it. FRIC-113 to FRIC-115: see the Decision Log.
  - Evidence: on a shell without the helpers on PATH, `shikigami-agent-run` on the campaign
    declaration exits 1 before any step, naming both missing helpers and their fixes; doctor
    reports the ceiling refusal with an empty `XDG_CONFIG_HOME`. The PlaybookSpec case "a stop
    names whether the machine or the work stopped it" covers the stop cause.
- [x] Grants before the batches (2026-11-18, user-approved): FRIC-102 and FRIC-103.
  - `shikigami-local grant <declaration> --in <repository> [--placement in-place|separate-worktree]`
    confirms the campaign on a repository without starting a run. It shows the same request,
    records `authority.granted`, and refuses unless input and output are both a terminal.
  - A run now works under its grant's placement. A confirmation's placement is the one the
    operator chose, and an approvals-file grant's is the file's entry (ADR-124, amended).
  - The unattended refusal, the run's prompt and `doctor --workspace` each name the `grant`
    command with the declaration and the repository.
  - Before a batch, run the `grant` command for each repository with `--placement in-place` in
    a terminal. The campaign can then start with `--no-confirm`.
  - Evidence:
    - Without a terminal, `grant` refuses and names the reason.
    - An existing grant prints `already granted … separate worktree`.
    - `doctor --agent agents/campaigns/keiro-modernization/keiro-modernization.dhall
      --workspace mori://shinzui/keiei` prints the exact `grant` command.
    - LocalOperatorSpec covers a placement that replaces an earlier confirmation, the prompt
      showing the placement and the refusal naming the command. LocalHostSpec covers
      "a run works under the placement its grant holds, not the repository entry's".
- [ ] Milestone 4: the remaining confirmed repositories are modernized in batches, each batch
  using the playbook as improved by the previous one. The commits that introduced the
  campaign contain no `shikigami-core/` path, and EP-5's fitness check passes. This milestone
  may finish after EP-11's baseline gate; EP-11 depends only on Milestone 3.


## Surprises & Discoveries

- Observation: kanmon does not depend on keiro. keiro appears only in the description text of
  `kanmon-api.cabal` and `kanmon-core.cabal`; no `build-depends`, `cabal.project` or Nix input
  names it, and kanmon's plans record a deliberate decision not to depend on keiro. Its
  `mori.dhall` still lists `shinzui/keiro`. Modernizing kanmon "to the current keiro stack"
  would therefore add keiro, not upgrade it, which changes what the pilot proves.
  Evidence: the readiness reports of runs `5738fce0-…` and `e6227c3d-…`.
- Observation: The plan-skill update (R4) needs a human: `seihou update exec-plan` reports the
  operator's `.gitignore` as modified by the user and refuses to continue without an
  interactive terminal or `--force`. R7 (the friction log) depends on R4's newer exec-plan
  skill.
  Evidence: `seihou update exec-plan --dry-run --json` → `unresolved_conflicts … .gitignore`.
- Observation: The first readiness run stopped at its `mori status --json` probe, which exits 1
  for a stale schema; EP-4 gained the `Probe` step. A scratch `XDG_CONFIG_HOME` used for these
  runs hid the operator's seihou install cache from the agent (an artifact of this session's
  harness, fixed by linking `~/.config/seihou`).

These came from read-only research on 2026-11-15, before implementation.

- Observation: Seihou keeps only the most recent `seihou agent run` receipt. Running several
  runnable blueprints therefore overwrites the earlier receipts. Migration receipts
  (`seihou agent migrate`) form an append-only list and are not affected.
  Evidence: `seihou-core/src/Seihou/Core/Types.hs:619` in `mori://shinzui/seihou` declares
  `blueprint :: !(Maybe AppliedBlueprint)`, while `blueprintMigrations` is a list. The
  manifests of kawa, rei and mori each hold exactly one `blueprint` record.
- Observation: `seihou agent --debug run` writes a receipt even though it only previews.
  Evidence: `blueprints/domain-scalar-identity-decoder-audit/README.md` in
  `mori://shinzui/keiro`.
- Observation: `keiro-upgrade` infers `--to` by reading `dist-newstyle/cache/plan.json`, and
  its first run cannot infer `--from` because no receipt exists yet. Five candidate
  repositories have no configured build plan, so the probe would fail there.
  Evidence: the `versionProbe` field in `blueprints/keiro-upgrade/blueprint.dhall`. Running
  that probe over the candidates returns nothing for kanmon, meibo, notion-hub,
  keiro-runtime-jitsurei and keiro-runtime-kenshou.
- Observation: a stale Mori registration hides real dependencies. `mori registry dependents
  shinzui/keiro` omits koyomi, although koyomi's four packages depend on keiro. Its
  registration is stale.
  Evidence: `mori registry show shinzui/koyomi --full` reports `Registration: stale`.


- Observation: the campaign took longer than doing the work by hand. Most of the time went
  into Shikigami and Seihou defects found on the way (the output limit, IR-23, BUG-5, FRIC-78,
  FRIC-79), into four runs, three of them drained after a playbook change (the drain rule makes each
  change a fresh run), and into operator gates at every stage that each waited for a person. Applying one blueprint took
  three coding agents (apply, implement, fix-build) plus two builds.
  Evidence: runs `1a947d4f…`, `2e5d2432…`, `91dda5f5…` and `c4341273…`; kizashi `8b92d3e..be9b920`.
- Observation: the campaign rendered guidance from the installed blueprint, not the latest one.
  keiro-upgrade 0.13.0 has no 0.24→0.25 edge, and 0.14.0's edge entails two Shibuya blueprints
  that were not installed. `seihou outdated` lists only installed blueprints, so the missing
  ones surfaced at render time.
  Evidence: `seihou agent --debug migrate keiro-upgrade --from=0.24.0.0 --to=0.25.0.0` →
  `entails blueprint 'shibuya-pgmq-adapter-upgrade', which is not installed`.
- Observation: applying `nix-haskell-flake` 0.40.0 in kizashi brought a managed `fourmolu.yaml`
  (2-space, trailing commas) into a tree formatted with fourmolu's defaults, so the pre-commit
  hook restyles every file a later change touches.
  Evidence: kizashi `30191f5` adds `fourmolu.yaml`; `75b4308` restyles four modules.

## Decision Log

- Decision: Milestone 2 is superseded by Milestone 3 and is not run again.
  Rationale: the user decided this on 2026-11-18. The kizashi pilot was stopped and finished by
  hand on 2026-11-16. The koyomi run (M3) then showed the full gated campaign with a
  repository-1 learning applied, which is what M2 was to establish. Re-running the pilot would
  only repeat it.
  Date: 2026-11-18

- Decision: A migrate blueprint runs one release edge at a time. The select step emits one
  entry per edge, read from `seihou agent --debug`'s edge headers; edges entailed by an
  edge run with it. The MasterPlan step gives a blueprint's edges one shared ExecPlan with a
  milestone per edge, and the implement step fixes only the current edge's fallout.
  Rationale: koyomi's first M3 run (`17f5c2fb-41ac-54d1-bc05-77e34ee791d0`) passed readiness,
  selection and MasterPlan, each approved by the user. Its apply step was then refused because
  the 0.22 to 0.25 guidance rendered 122 KB, above the 64 KiB coding-agent prompt limit
  (FRIC-112). Seihou's per-edge guidance already tells the agent to work only on the current
  edge, and each keiro edge renders below the limit. A new run replaces the stopped one; the
  MasterPlan skill's step 0 reuses koyomi's MasterPlan 2 and ExecPlan 9.
  Date: 2026-11-17

- Decision: The second-repository run (M3) on koyomi uses a slimmed playbook. Readiness gains
  R8: a `seihou outdated` probe and a check that the migration blueprints are current, which
  the operator fixes with `seihou upgrade <name>` before approving readiness. The catalog
  gains `shibuya-kiroku-adapter-upgrade` and `shibuya-pgmq-adapter-upgrade`, which keiro
  0.25 requires when a build depends on those adapters; without them in the catalog, the
  campaign's tool grant refused them. `migrate-keiro-stack` is deferred to the batches (M4).
  Rationale: the user chose this on 2026-11-17 to unblock EP-11 M2 without loosening its
  dependency on M3. The kizashi pilot stopped because the installed keiro-upgrade (0.13.0)
  had no 0.24 to 0.25 edge, and the two Shibuya blueprints had to be applied by hand. On
  2026-11-17, koyomi's `seihou outdated` again shows keiro-upgrade 0.14.0 installed and
  0.14.1 available. Moving that check to readiness is the repository-1 learning that M3
  must show applied. migrate-keiro-stack took most of the pilot's time, and the
  build-repair fixture already covers the playbook's tail.
  Date: 2026-11-17

- Decision: Stop gating kizashi through the campaign. Finish keiro 0.25 by hand, and validate
  the playbook tail with a small fixture bundle (`agents/playbooks/build-repair.dhall`) rather
  than the rest of the kizashi run.
  Rationale: the user observed on 2026-11-16 that the campaign was taking longer than the
  work by hand. What remained untested in Shikigami (repair of a broken build, a failed final
  build, a failing tests probe, Reflect at the end, learnings across runs) needs only a
  minutes-long run on a fixture, and that run found two defects the kizashi run had not
  reached.
  Date: 2026-11-16

- Decision: The campaign covers seven repositories, confirmed by the user on 2026-11-15:
  kanmon, kizashi, koyomi, danwa, keiei, meibo (`meibo-project/meibo`) and jinmyaku
  (`jinmyaku-project/jinmyaku`). The order is: kanmon as the pilot, kizashi second, then batch
  A (koyomi, keiei, danwa) and batch B (meibo, jinmyaku). kawa, notion-hub, kotei, rei and the
  two keiro-runtime repositories are out of scope.
  Rationale: The user named these seven. kanmon is the smallest at 4.2k lines, and its
  readiness gaps exercise every readiness check: plan skills 0.5.0, no `.claude/skills`, no
  build plan and a stale Mori registration. kizashi is close in shape to kanmon, so it is a
  fair test of whether kanmon's learnings carry over. meibo pins keiro 0.16.0.0 and jinmyaku
  is the largest at 50.5k lines with no `mina.kdl`, so both run last, with the most refined
  playbook.
  Date: 2026-11-15
- Decision: Each repository, or each batch in Milestone 4, is a separate playbook run. The
  playbook does not loop over all seven repositories in a single run.
  Rationale: MasterPlan 22 states that a proposed playbook change is never applied to a
  running playbook. Learnings can therefore only reach the next repository through a new run.
  Date: 2026-11-15
- Decision: Blueprints run as declared `Tool` steps that call `seihou agent run|migrate
  --batch`. They are not re-implemented as `CodingAgent` prompts.
  Each blueprint step is a playbook `Tool` step on EP-3 M4's durable tool host: it may mutate
  the repository, it runs under a deadline of hours on EP-2's restart-safe attempt machinery,
  and an `Uncertain` outcome goes to an approval instead of a rerun.
  Rationale: Seihou owns receipts, entailed edges, not-applicable outcomes and version-window
  inference. Re-rendering a blueprint's prompt inside a coding-agent step would lose all of
  them, and the `--debug` route also writes a misleading receipt. The cost is that Seihou
  starts its own Claude Code session, whose tool limits come from the blueprint's
  `allowedTools` rather than from Shikigami. Under `LocalOperator` that is the operator's own
  authority, and it is acceptable.
  Date: 2026-11-15
- Decision: The playbook records evidence for runnable blueprints itself. Each runnable
  blueprint ends in its own commit with a `Blueprint: <name>@<version>` trailer, and the
  campaign files an improvement request against Seihou for multi-blueprint run receipts.
  Rationale: Seihou overwrites earlier run receipts (see Surprises).
  Date: 2026-11-15
- Decision: Campaign work commits directly to each target repository's current branch. The
  operator chooses `InPlace` placement for all seven repositories, using EP-1's
  `WorkspacePlacement`. Under EP-1's confirm-once grant the operator does not hand-write an
  approvals entry per repository: the first interactive run shows the repository, the
  placement and the declared tools, and the operator confirms once. Placement stays the
  operator's choice and is never taken from the declaration. No worktree and no campaign
  branch are created. The readiness probe
  records the starting commit, and `git reset --hard <start>` is the undo.
  Rationale: The user said on 2026-11-15 that these projects need no branches, because
  nobody else is working in them. Approval gates remain the review boundary. The recorded
  starting commit replaces the branch as the undo point.
  Date: 2026-11-15
- Decision: `migrate-keiro-stack` runs with `database.policy=disposable`.
  Rationale: The user said on 2026-11-15 that these services are not in use yet, so their
  local databases need not be preserved.
  Date: 2026-11-15
- Decision: The campaign adds no Haskell and no test under `shikigami-core/`. It validates
  its declarations with `shikigami validate`, and with `dhall type` for files that are not
  agent declarations.
  Rationale: the architectural acceptance test forbids `shikigami-core` changes, and the test
  suites that load agent files live in that package. A kernel gap is recorded against the
  owning child plan instead (see Validation and Acceptance).
  Date: 2026-11-15
- Decision: The campaign does not end the ADR-27 pre-release exception. Its runs are pilot
  runs under MasterPlan 22's drain rule: every campaign run reaches a terminal state before a
  change to a workflow or declaration shape lands. The exception ends at EP-11's baseline gate
  (`docs/plans/136-freeze-the-v1-api-baseline-with-a-surface-inventory-and-compatibility-checks.md`).
  This supersedes the first draft, which recorded the end of the exception before the first
  durable run.
  Rationale: The user decided on 2026-11-15 that the v1 baseline freezes at an explicit gate.
  EP-5 and EP-6 still change the `AgentRun` body and the declaration codec after the campaign
  starts. The campaign's durable results are the commits, receipts, MasterPlans and learnings
  it leaves in the target repositories and in Kioku, so a terminal run whose journal a later
  build cannot read loses nothing the operator needs.
  Date: 2026-11-15
- Decision: The campaign is written in EP-4's actual playbook format, not the schema the first
  draft imagined. One playbook run takes its repositories from the trigger payload. Skills are
  attached to coding-agent steps. Structured results travel as named output fields. An early
  stop is a run parameter tested by one condition. The playbook change is proposed by EP-4's
  own proposal step at the end of the run, not by a campaign step.
  Rationale: MasterPlan 22's review of 2026-11-15 found that the first sketch used step
  shapes, an item source and outcome fields that EP-4 and EP-2 do not define. EP-4 confirmed
  each need and now owns it.
  Date: 2026-11-15
- Decision: Learnings are recorded under EP-4's playbook scope for the bundle's `main` name,
  `keiro-modernization`.
  Rationale: EP-4 owns the memory convention. The first draft's key
  `playbook:keiro-modernization` named the same scope in a spelling EP-4 does not use.
  Date: 2026-11-15


- Decision (M1): The campaign uses EP-4's landed format. The payload's `repos` is a list of
  Mori identities (`FromPayload` yields strings), and the coding agent's workspace is
  `{{repo}}`. Probes are `Probe` steps; the readiness prompt quotes them through
  `{{steps.ID.output}}`. EP-4 has no conditions, so Milestone 1's bundle ends at the readiness
  approval and the `modernize` playbook joins in Milestone 2 (where declining an approval ends
  the run). Blueprint selection is a coding-agent step returning JSON for `FromStep`, because
  EP-4 has no Skill step. The two kernel gaps found here (`{{steps.ID.output}}` and `Probe`)
  were filled in EP-4's interpreter; `shikigami-core`'s manifest-walk test learned to skip a
  campaign directory's non-declaration files. The campaign files themselves add no Haskell.
  Rationale: The plan says to record mismatches against the owning plan; both gaps were
  small and belong to EP-4, and the campaign's own files stay declarations.
  Date: 2026-11-15

- Decision (after M1): kizashi replaces kanmon as the pilot, and koyomi becomes the second
  repository; kanmon keeps its readiness commits and leaves the campaign. Seihou update
  conflicts with the operator's own edits are reported and left for the operator to resolve
  interactively; the campaign never passes `--force`.
  Rationale: The user decided on 2026-11-15, after the readiness run showed kanmon has no keiro
  dependency (the pilot would add keiro rather than upgrade it) and that the plan-skill update
  stops on the operator's `.gitignore` edits.
  Date: 2026-11-15

- Decision (M2): A Shikigami coding agent applies each blueprint. The run renders the
  blueprint's guidance with `seihou agent --debug <kind> <blueprint> …`, quotes it to a coding
  agent with the `campaign-apply-blueprint` skill under the campaign's declared tools, and that
  agent records migration receipts with `seihou agent migrate … --mark-applied`. For a
  runnable blueprint the record written by `--debug run` stands as its receipt. Selections gain
  a `target` (`--to=…`), because Seihou cannot infer the target before the dependency is
  bumped, and kiroku-upgrade is not selected beside keiro-upgrade, which entails it.
  Rationale: The user chose this on 2026-11-16, after `seihou agent run
  fix-nix-haskell-flake-customizations --batch` in kizashi was refused ten commands by the
  blueprint's own allowedTools and left a half-applied tree (reverted; the patch is kept
  outside the repository). The gap is filed upstream as
  `mori://shinzui/seihou/okf/improvement-requests/concepts/IR-23`. This supersedes the earlier
  decision that blueprints run as `seihou agent run|migrate --batch` tool steps.
  Date: 2026-11-16

- Decision (before M4): each migration edge is one coding agent (`apply`) that applies the
  guidance, fixes the edge's fallout, records it in the ExecPlan and finishes with
  `nix develop -c just check`; the per-edge `implement`, `build` and `fix-build` steps and the
  `execute-plan` build steps are gone. The `tests` probe runs `nix develop -c just check`, and
  readiness check R9 (with a `just --summary` probe) makes sure every repository has a `check`
  recipe that runs its full suite, adding one over the existing test recipes when it is
  missing. Reflect quotes `{{steps.tests.summary}}` instead of the whole test output.
  Rationale: FRIC-113 (two cold agents and a redundant build per edge), FRIC-114 (bare
  `cabal test all` cannot start suites the repository's scripts provide) and FRIC-115 (the full
  test output exceeded the 64 KiB prompt limit). Of the six confirmed repositories only koyomi
  had a `check` recipe on 2026-11-18 (kizashi and keiei have `test`), so R9 makes the probe
  portable instead of hard-coding a per-repository command.
  Date: 2026-11-18

## Outcomes & Retrospective

(To be filled during and after implementation.)


## Context and Orientation

**The kernel pieces this plan consumes.** None exist yet; they are delivered by sibling
plans of MasterPlan 22. Recheck every shape quoted here against the landed code before
Milestone 1.

- EP-1
  (`docs/plans/126-run-declared-agents-on-the-operator-s-own-machine-through-a-local-operator-trust-tier.md`)
  adds `data TrustTier = LocalOperator | Contained | MultiTenant`. Under `LocalOperator`,
  actions run on this Mac with the operator's own credentials. The operator grants authority
  by confirming a declaration once; the answer is stored against the declaration's digest,
  and worker runs use only stored grants. Its `WorkspacePlacement` lets the operator choose
  `InPlace` for a repository, which works directly on the checkout's current branch.
- EP-2
  (`docs/plans/127-run-claude-code-and-codex-as-durable-harness-workers-inside-agent-runs.md`)
  adds the `CodingAgent` behavior arm and the durable coding-agent step. A step runs Claude
  Code or Codex on a prompt in a workspace with a deadline, with skill directories attached.
  Its closed outcome is shown under Plan of Work.
- EP-3
  (`docs/plans/128-let-agents-declare-cli-tools-and-mcp-servers-with-authority-attached-to-the-declaration.md`)
  adds the declared `tools` field. Only CLI tools the agent declares can be called, each
  within its declared argument patterns, and undeclared calls are refused. Its fourth
  milestone runs a declared tool as a durable step (`runDeclaredTool`): the call may mutate,
  may run for hours, and ends `Uncertain` after a restart rather than running twice.
- EP-4
  (`docs/plans/129-execute-dhall-declared-playbooks-with-fan-out-approval-gates-and-learning-capture.md`)
  adds the `Playbook` behavior arm and `schema/Playbook.dhall`. A playbook *bundle* is a file
  with a `main` playbook name and a list of playbooks. Each playbook is a list of steps
  `P.Step::{ name, action, applies, onFailure }`. The `Action` union has `CodingAgent`,
  `Approval`, `RunPlaybook` (nested), `ForEach` over an item source, `Reflect`, `Skill` and
  `Tool`. Item sources are `Literal`, `FromPayload` (an array in the run's trigger payload)
  and `FromStep` (an array in an earlier step's JSON output). Text fields are templates with
  holes such as `{{item.repo}}`, `{{run.mode}}`, `{{steps.select.summary}}` and
  `{{steps.masterplan.field.plans}}`. `Reflect` writes Kioku memories (Kioku is the memory
  store at `mori://shinzui/kioku`) under the playbook's scope, and at the end of a run EP-4
  proposes playbook changes as a Git branch for approval.
- EP-8
  (`docs/plans/133-give-the-kernel-its-own-action-record-output-approval-and-trigger-contracts-with-local-adapters.md`)
  gives the kernel its own action record, the `Manual` trigger, the `local.report` output and
  the `local.inbox` approval channel. The campaign's approvals arrive in that inbox, and
  `shikigami-local ledger` shows every tool call and decision of a run.
- EP-5
  (`docs/plans/130-move-the-extension-boundary-out-of-shikigami-core-with-flow-packs-and-an-architecture-fitness-check.md`)
  defines where out-of-core declarations live and adds the fitness check.

**Today's declaration surface.** Agents are Dhall files typed by `schema/Agent.dhall`, such as
`agents/triage-note.dhall`. Skills are directories holding `SKILL.md`; this repository
ships `agents/skills/exec-plan` and `agents/skills/master-plan`. `shikigami validate <FILE>`
decodes a manifest without a database. `shikigami enqueue-run <AGENT> --payload <JSON>`
queues a run for `shikigami-worker`, and `shikigami resolve-approval <TOKEN> --approve|--reject`
resolves an approval gate (`docs/user/cli.md`). EP-4 adds the commands the campaign uses
instead: `shikigami playbook validate|start|show|approve`. The worker needs the PostgreSQL
database created by `just create-database`.

**The tools the campaign drives.** `mina` (`mori://shinzui/mina`) is the planning CLI.
`mina ci --json "<title>"` creates a Rei intention under the `rei.create.default-parent`
set in the repository's `mina.kdl`, and the plan skills record that intention in plan
frontmatter. `mina config show` prints the resolved configuration. Mori
(`mori://shinzui/mori`) is the project registry. `mori status --json` reports whether the
`mori.dhall` schema is current and whether the registration is current. `mori schema
upgrade` and `mori register` fix those two. Seihou (`mori://shinzui/seihou`) applies modules
and blueprints and records them in `.seihou/manifest.json`; `seihou status` prints that
record. Its migration semantics come from
`mori://shinzui/seihou/masterplans/10-blueprint-migration-fan-out-across-a-library-cohort`
and the guide `docs/user/blueprint-migrations.md` in `mori://shinzui/seihou`. Each crossed
edge leaves a receipt with outcome `applied` or `not-applicable`. A not-applicable edge is
planned again on the next run. Entailed edges of other blueprints, such as `kiroku-upgrade`
under `keiro-upgrade`, are crossed once and must be installed. `--mark-applied` asserts work
done by hand.

**Candidate repositories.** These were found with `mori registry dependents shinzui/keiro`
and a scan of the `.cabal` files under `/Users/shinzui/Keikaku/bokuno`. The keiro version is
the one the build plan resolves. The paths are local:

```text
repo (path under /Users/shinzui/Keikaku/bokuno)  keiro  Haskell lines  gaps found
kawa                     0.22   10.8k  no AGENTS.md, no friction log, mori stale
kanmon                   ?       4.2k  plan skills 0.5.0, no .claude/skills, no build plan, mori stale
kizashi                  0.22   32.0k  no AGENTS.md, mori schema stale
koyomi                   0.22   24.3k  mori registration stale (hides keiro dependency)
danwa                    0.22   18.4k  migrate-keiro-stack 0.1.0 receipt (current 0.2.0)
keiei                    0.22   35.9k  mori registration stale
meibo-project/meibo      ?      19.5k  no build plan; cabal.project pins keiro 0.16.0.0
jinmyaku-project/jinmyaku 0.22  50.5k  no mina.kdl
notion-hub               ?      21.8k  plan skills 0.13.0, no .claude/skills, no build plan
kotei                    0.23  453k    largest; nearly current
rei-project/rei          0.24  443k    exemplar repository; nearly current
keiro-runtime-jitsurei   ?       —     example application; no mina.kdl
keiro-runtime-kenshou    ?       —     benchmark harness; mori stale
```

Excluded unless the user says otherwise: `shikigami` itself, since the campaign host must not
modernize its own core; `mori-project/mori`, a tool; `kioku`, a library; `kikan-project/kikan-en`,
which has no keiro dependency; and `tan/chapter-service-v2` and `tan/notification-hub`,
work repositories that appear as keiro dependents.

**The readiness checklist.** It is derived from the two best-maintained repositories,
`mori-project/mori` and `rei-project/rei`, which have every marker. Each item can be checked
from a file or a command, and each has a fix:

```text
R1 clean tree        git status --porcelain is empty            fix: stop; operator decides
R2 mina configured   mina.kdl has rei.create.default-parent     fix: add block, intention from user
R3 mori current      mori status --json: schema and registration current
                                                              fix: mori schema upgrade; mori register
R4 plan skills       .seihou/manifest.json exec-plan and master-plan at agent-seihou 0.14.0,
                     linked under .claude/skills               fix: seihou update / link-skill module
R5 agent guide       AGENTS.md present                         fix: coding agent drafts from repo
R6 build plan        dist-newstyle/cache/plan.json present     fix: nix develop -c cabal build all --dry-run
R7 friction log      docs/friction-log/profile.dhall present   fix: okf profile init (FRICTION.md)
```

Profile-governed ADRs, keiro-dsl `domain/` specifications with `just keiro-gate`, and the
OKF bundle upgrades are modernization work, not readiness. They come from blueprints, as
described below.

**The blueprint catalog.** The catalog lists the blueprints that exist today, in the order the
playbook applies them. That order puts the toolchain first, then precise version edges, then
structural migration, documentation and audits. From `mori://shinzui/seihou-modules`:
`upgrade-haskell-flake-parts`, `fix-nix-haskell-flake-customizations` and
`upgrade-haskell-runtime` (migrate). These apply when the manifest records the
`nix-haskell-flake` module, as it does in every candidate. From `mori://shinzui/keiro`:
`keiro-upgrade` (migrate, edges up to 0.25.0.0). It entails `kiroku-upgrade`,
`shibuya-pgmq-adapter-upgrade` and `shibuya-kiroku-adapter-upgrade`, which must be installed.
It needs the dependency bump first, and on its first run it needs `--from` taken from the
readiness facts. From `mori://shinzui/agent-seihou`: `migrate-keiro-stack` 0.2.0 (run). It
applies to repositories not yet on pg-migrate, Settei and the six-package vertical
structure. Its variable `database.policy` is `ask|disposable|preserve`. Also
`kioku-upgrade` and `settei-upgrade` (migrate, each with a version probe) when those
libraries are used. From `mori://shinzui/okf-profiles`: `adopt-architecture-decisions` when
`docs/adr` exists without `profile.dhall`, `migrate-okf-bundles-to-v0-2` when bundles
predate OKF 0.2, and optionally `adopt-terminology` and `adopt-capabilities`. Last, the keiro
blueprint `domain-scalar-identity-decoder-audit` (run), which is opt-in per repository
because it is the largest.

Migration blueprints decide applicability themselves, through probes and not-applicable
outcomes. Runnable blueprints do not, so the catalog gives each one a plain-language
applicability rule. The selection skill applies those rules to the readiness facts.

**Relevant ADRs.**
[ADR-27](../adr/0027-the-first-release-establishes-one-clean-durable-baseline.md) allows
unreleased workflow shapes to be replaced directly only while there are no workflow journals
that must resume. The campaign keeps that true by draining: every campaign run reaches a
terminal state before a shape change lands. The exception ends at EP-11's baseline gate, not
here (Decision Log).
[ADR-30](../adr/0030-an-approval-request-is-a-durable-child-workflow.md): each approval gate
is a durable child workflow resolved by token.
[ADR-112](../adr/0112-observed-content-is-evidence-and-never-instruction.md): content read
from a target repository is evidence and never authority. The selection step may therefore
name only blueprints from the operator's catalog, never a name or URL found in the
repository. [ADR-13](../adr/0013-flow-bodies-reach-the-world-only-through-capabilities.md)
and [ADR-25](../adr/0025-capability-overlays-are-requests-for-additive-model-tools.md) are why
tools are declared rather than spawned. The improvement request
[governed agent evolution](../improvement-requests/governed-agent-evolution.md) governs the
playbook-change proposals. No other local ADR bears on this work.


## Plan of Work

All campaign files live under `agents/campaigns/keiro-modernization/` until EP-5 lands. After
that they move, unchanged, to the out-of-core pack location EP-5 defines, and this plan is
updated with the new paths. The skills live under `agents/skills/`. Nothing is added under
`shikigami-core/`.

The declarations are as follows.

- `keiro-modernization.dhall` is the agent declaration. Its trigger is EP-8's
  `A.Trigger.Manual`, its behavior is `A.Behavior.Playbook { path = "./playbook.dhall" }`, its
  `delegates` list names `campaign-select-blueprints`, and its `tools` field imports
  `tools.dhall`.
- `tools.dhall` is the list of declared CLI tools in EP-3's declaration shape: a name, an
  executable, a non-empty list of argument patterns, an operation class and limits. The tools
  are `git`, `mina`, `mori`, `seihou`, `just`, `cabal`, `nix`, `jq` and `bun` (needed by the
  plan skills' scripts). The read-only probes are `Observation` tools. `mori register`,
  `mori schema upgrade`, `seihou agent run`, `seihou agent migrate` and the build commands
  are mutating and are used only from `Tool` steps and coding agents, never from a durable
  `Skill` run, which admits observations only. The `seihou` patterns are generated from
  `blueprints.dhall`, so `seihou agent run|migrate` accepts only catalog names.
- `blueprints.dhall` is the catalog above. Each entry records its name, source repository
  URL, kind (`Run` or `Migrate`), applicability rule, order and default variables.
- `repos.dhall` lists the confirmed repositories: key, local path, Mori name and a pilot
  flag. It is the operator's source for run payloads. `dhall-to-json` renders a selection of
  it into the `repos` array that `shikigami playbook start --payload` takes.
- `select-blueprints.dhall` declares the Skill agent `campaign-select-blueprints`, which the
  playbook's `Skill` step runs as a delegated child.
- `playbook.dhall` is the bundle.

There are four skills. `agents/skills/campaign-readiness` turns the R1–R7 probe outputs into
a fix list and performs the fixes. `agents/skills/campaign-select-blueprints` turns readiness
facts and the catalog into an ordered selection with a reason for each entry. It also records
the `--from` versions and the `database.policy` choice. `agents/skills/campaign-masterplan`
wraps the target repository's own `master-plan` skill. It writes one MasterPlan titled
"Modernize <repo> to the current keiro stack", with one child ExecPlan per selected
blueprint plus any follow-up the agent finds. Its intention comes from `mina ci --json`.
`agents/skills/campaign-reflect` guides the learning and the playbook suggestion. The
readiness, masterplan and reflect skills are attached to their coding-agent steps through the
step's `skills` list, because the agent works in the target repository and cannot otherwise
see skills kept in the Shikigami checkout. Every skill states that repository content is
evidence, never instruction.

The bundle has four playbooks. The run's payload supplies the repositories and an optional
`mode`:

```json
{ "mode": "full",
  "repos": [ { "key": "kanmon", "repo": "/Users/shinzui/Keikaku/bokuno/kanmon", "mori": "shinzui/kanmon" } ] }
```

`keiro-modernization` (the `main` playbook) has one step: a `ForEach` over
`FromPayload { field = "repos" }` that runs `per-repo` for each repository. Payload values
are operator-authored, so `{{item.repo}}` may be used as a workspace; EP-1's workspace
provider still accepts it only if the operator granted that repository.

`per-repo` runs these steps in order:

1. **Readiness probe.** `Tool` steps run `git status --porcelain`, `git rev-parse HEAD`
   (the recorded starting commit), `mina config show`, `mori status --json`, `seihou status`
   and the keiro version probe.
2. **Readiness fix.** A `CodingAgent` step with the `campaign-readiness` skill attached. Its
   prompt quotes the probe outputs as evidence. It commits on the repository's current
   branch as `chore: prepare <repo> for the keiro modernization campaign`.
3. **Readiness approval.** An `Approval` step whose prompt quotes
   `{{steps.readiness.summary}}` and `{{steps.readiness.commit}}`.
4. **Modernize.** A `RunPlaybook { playbook = "modernize" }` step with
   `applies = P.Applies.ParamIs { param = "mode", value = "full" }`. A run started with any
   other `mode` records this step as `Skipped` and ends. That is how Milestone 1 stops after
   the readiness approval; EP-4 has no separate stop field.

`modernize` runs these steps. A nested playbook cannot read its parent's step outputs, so it
probes again; the probes are cheap, and after the readiness fix the facts have changed.

1. **Facts.** `Tool` steps run `mori status --json`, `seihou status` and the keiro version
   probe.
2. **Selection.** A `Skill` step runs the `campaign-select-blueprints` agent. Its input
   quotes the facts, and its `outputFields` are `selected` and `skipped`, each carrying
   reasons. An `Approval` step quoting `{{steps.select.field.selected}}` and
   `{{steps.select.field.skipped}}` follows.
3. **MasterPlan.** A `CodingAgent` step with the `campaign-masterplan` skill attached. Its
   `outputFields` is `plans`: an array of objects with string fields `key`, `path`, `kind`
   (`run`, `migrate`, `migrate-from` or `none`), `blueprint` and `from`. An `Approval` step
   on the MasterPlan follows.
4. **Plan execution.** A `ForEach` over
   `FromStep { step = "masterplan", at = "plans", key = "key" }` runs `execute-plan` for each
   plan.
5. **Final validation.** A `Tool` step runs the build and tests on the current branch, then
   an `Approval` step closes the repository and quotes the commit range from the recorded
   starting commit.
6. **Reflect.** A `Reflect` step with the `campaign-reflect` guidance in its prompt. It
   records learnings under the playbook scope `keiro-modernization` and may suggest a
   playbook change. At the end of the run EP-4's proposal step turns the suggestions into a
   branch `shikigami/playbook-proposal/<run-id>` in the Shikigami checkout, changing only the
   bundle and its attached skills. The operator approves by merging.

`execute-plan` runs once per plan. Its item variables come from step output, so they are
observed: they are quoted in prompts and checked by the declared argument patterns in tool
calls. The repository path still comes from the enclosing item, because an inner item
inherits the outer item's variables.

1. **Blueprint.** One `Tool` step per kind, each guarded by
   `P.Applies.VarIs { var = "kind", value = … }`, runs
   `seihou agent run <blueprint> --batch`, `seihou agent migrate <blueprint> --batch` or the
   same with `--from <from>`. Each has `deadlineMinutes = 240` and `onFailure = Continue`. A
   plan of kind `none` skips all three. The blueprint name is an observed value, and the
   generated `seihou` patterns admit only catalog names, so the name cannot widen authority.
2. **Implement.** A `CodingAgent` step implements the rest of the ExecPlan with the target
   repository's `exec-plan` skill: fallout fixes, Progress updates and a commit with the
   `ExecPlan:` trailer and, for a runnable blueprint, the `Blueprint: <name>@<version>`
   trailer.
3. **Build.** A `Tool` step runs the repository's build and tests with
   `onFailure = Continue`.
4. **Fix once.** A `CodingAgent` step and a second build `Tool` step, both with
   `applies = P.Applies.StepWas { step = "build", outcome = P.Outcome.Failed }`.
5. **Escalate.** An `Approval` step with
   `applies = P.Applies.StepWas { step = "rebuild", outcome = P.Outcome.Failed }` asks the
   operator. Rejecting it fails the plan item.

A coding-agent or tool outcome of `Uncertain` always goes to an approval and is never retried
automatically, because the edits are not transactional. EP-4's interpreter does this for
both step kinds; the campaign adds nothing. A timed-out step is `Failed`.

A sketch of the bundle follows. It uses EP-4's format; adjust names to its landed schema. Do
not add fields to the kernel to match this sketch; record a mismatch as a gap instead.

```dhall
-- agents/campaigns/keiro-modernization/playbook.dhall (schema owned by EP-4)
let P = ../../../schema/Playbook.dhall
let coder =
      \(skill : Text) -> \(minutes : Natural) -> \(prompt : Text) ->
        P.Action.CodingAgent P.CodingAgentStep::{
        , provider = P.Provider.ClaudeCode, workspace = "{{item.repo}}"
        , deadlineMinutes = minutes, prompt, skills = [ skill ] }
let tool =
      \(name : Text) -> \(args : List Text) -> \(minutes : Natural) ->
        P.Action.Tool { tool = name, args, workspace = "{{item.repo}}"
                      , deadlineMinutes = minutes, outputFields = [] : List Text }
let gate = \(prompt : Text) -> P.Action.Approval { prompt, deadlineHours = 72 }
in  { main = "keiro-modernization"
    , playbooks =
      [ { name = "keiro-modernization", description = "Modernize the keiro services named in the payload"
        , steps = [ P.Step::{ name = "repos", action = P.Action.ForEach
            { items = P.ItemSource.FromPayload { field = "repos" }, playbook = "per-repo" } } ] }
      , { name = "per-repo", description = "Readiness, then modernization, for one repository"
        , steps =
          [ P.Step::{ name = "probe-mori", action = tool "mori" [ "status", "--json" ] 5 }
          , P.Step::{ name = "readiness", action =
              coder "../../skills/campaign-readiness" 30
                "Make {{item.key}} ready for the campaign. Mori status: {{steps.probe-mori.summary}}" }
          , P.Step::{ name = "readiness-review", action =
              gate "Accept readiness commit {{steps.readiness.commit}} for {{item.key}}? {{steps.readiness.summary}}" }
          , P.Step::{ name = "modernize", action = P.Action.RunPlaybook { playbook = "modernize" }
                    , applies = P.Applies.ParamIs { param = "mode", value = "full" } }
          ] }
      , { name = "modernize", description = "Select blueprints, plan, execute, validate, reflect"
        , steps = ./modernize-steps.dhall P }
      , { name = "execute-plan", description = "One child ExecPlan"
        , steps = ./execute-plan-steps.dhall P }
      ] }
```

The Haskell this plan relies on is owned by EP-2, EP-3 and EP-4. Nothing here writes it. The
campaign's control flow depends on EP-2's outcome shape, which EP-4's interpreter maps to a
step outcome:

```haskell
-- Shikigami.CodingAgent.Types (EP-2); consumed through EP-4's interpreter
data CodingAgentOutcome
  = Completed !CompletedRun | Failed !FailureReason | TimedOut !PartialRun | Uncertain !UncertainRun
data CompletedRun = CompletedRun
  {exit :: !AgentExitCode, changes :: !ChangeSummary, result :: !ResultCommit,
   finalMessage :: !BoundedText, evidence :: !EvidenceSummary}
data ResultCommit = Unchanged !GitObject | Committed !GitObject
```

`finalMessage` is what a step's summary and named output fields are read from. EP-3 M4's
`runDeclaredTool` returns a comparable closed outcome for a tool step (exit code and bounded
output, refused, timed out, or uncertain); use the shape EP-3 landed.

**Milestone 1: inventory and readiness on the pilot.**

1. Show the user the candidate table and record the confirmed list and order in
   `repos.dhall` and in the Decision Log. The confirmed order (Decision Log, 2026-11-15) is: pilot kanmon; second kizashi; then batch
   A (koyomi, keiei, danwa) and batch B (meibo, jinmyaku).
2. Write the declarations and the readiness and selection skills, and validate them.
3. Recheck ADR-27's facts: no users, no journals that must resume, no stored payloads, no
   external consumers, and confirm that MasterPlan 22's Decision Log does not yet record the
   end of the exception. Record the result here. The campaign does not end the exception; it
   follows the drain rule (see Concrete Steps).
4. Grant the campaign its authority through EP-1's confirm-once flow, choosing `InPlace` for
   kanmon, and run the earliest interaction check (Validation and Acceptance).
5. Run the playbook on kanmon with `"mode": "readiness-only"` in the payload, which stops
   after the readiness approval.

Acceptance: kanmon's `mori status --json` shows both schema and registration current, and
`mina config show` resolves kanmon's root and parent. A readiness commit exists on kanmon's
current branch, and `shikigami playbook show <RUN>` shows the approval resolved, the
`modernize` step `Skipped` and the run terminal.

**Milestone 2: full pilot on kanmon.** Add the masterplan and reflect skills, then run every
step with the operator watching and approving each gate. Every kernel gap found is recorded
as described under Validation and Acceptance. A blocking gap pauses the milestone; it is
never patched into `shikigami-core`. If a gap's fix changes a workflow or declaration shape,
the paused run is first drained: rejected at its pending approval and restarted on the new
build, relying on the idempotence rules below. The result is kanmon modernized on its current
branch, with blueprint receipts, a MasterPlan, and a merged playbook-proposal branch carrying
the first learning.

**Milestone 3: learning applied on kizashi.** Run the improved playbook on kizashi. Then
compare the selection reasons and step transcripts with kanmon's. At least one difference must
trace to a kanmon learning, for example the configured-build fix running before the version
probe.

**Milestone 4: fan-out.** Run batches A and B. Each batch is one run whose payload lists
the batch's repositories, and the playbook is reflected and improved between batches. If
EP-11's baseline gate has passed by then, later playbook and kernel changes follow
`docs/workflow-versioning.md` with `patch`, and the drain rule no longer applies. If batch A
shows full runs are too slow, jinmyaku, the largest remaining repository, may carry
`"scope": "keiro-upgrade-only"` in its payload item. The selection step's input quotes
`{{item.scope}}`, and the selection skill then limits it to readiness and `keiro-upgrade`.


## Concrete Steps

Inventory, from `/Users/shinzui/Keikaku/bokuno/shikigami`:

```bash
mori registry dependents shinzui/keiro --packages
mori registry freshness --stale-only
for d in kanmon kizashi koyomi danwa keiei meibo-project/meibo jinmyaku-project/jinmyaku; do (cd ../$d && mori status --json | jq -c '{schema:."schema"."mori.dhall".status, reg:.registry.registered}'); done
```

Validate the declarations. Expect exit 0 and a pretty-printed declaration:

```bash
shikigami validate agents/campaigns/keiro-modernization/keiro-modernization.dhall
dhall type --file agents/campaigns/keiro-modernization/blueprints.dhall > /dev/null
dhall type --file agents/campaigns/keiro-modernization/repos.dhall > /dev/null
```

The campaign does not end the pre-release exception; EP-11 does. Until EP-11's gate, follow
the drain rule. Before pulling or building a Shikigami change that alters a workflow or
declaration shape, check that no campaign run is unfinished:

```bash
shikigami playbook show <RUN>        # every started run must be terminal
```

A run paused at an approval is finished by approving through to the end or by rejecting the
approval. A terminal run from before a shape change may become unreadable by `playbook show`.
That is accepted: its results are the commits, receipts, MasterPlan and learnings in the
target repository and in Kioku. If MasterPlan 22's Decision Log records that the exception
has ended, stop using this rule and follow `docs/workflow-versioning.md`.

Grant authority once, then run the campaign on kanmon. Use the worker, grant and playbook
commands that EP-1, EP-2 and EP-4 document for `LocalOperator`; the spellings below are
EP-4's:

```bash
just create-database
shikigami-worker --agents agents/campaigns/keiro-modernization &
echo $! > /private/tmp/shikigami-worker.pid
payload=$(jq -nc '{mode:"readiness-only", repos:[{key:"kanmon", repo:"/Users/shinzui/Keikaku/bokuno/kanmon", mori:"shinzui/kanmon"}]}')
shikigami playbook start keiro-modernization --key kanmon-readiness-1 --payload "$payload"
shikigami playbook show <RUN>
shikigami playbook approve <RUN>
```

The first interactive start shows what the declaration asks for (the repository with
`InPlace` placement, the declared tools and their argument patterns) and asks once. The
worker then runs on the stored grant. If EP-1 landed the grant as a separate command, run
that first. For the full pilot, start a new run with `"mode": "full"` and a new `--key`.

Stop the worker with `kill $(cat /private/tmp/shikigami-worker.pid)`, never by process name.

Inspect the results in the target repository:

```bash
cd /Users/shinzui/Keikaku/bokuno/kanmon
git log --oneline <start>..HEAD   # <start> is the commit the readiness probe recorded
jq -c '.blueprintMigrations[] | {name, from, to, outcome: .outcome.status}' .seihou/manifest.json
git log --format='%h %(trailers:key=Blueprint,valueonly)' <start>..HEAD | grep .
ls docs/masterplans
shikigami-local ledger --run <RUN>   # every tool call and decision of the run (EP-8's action record)
```

The expected shape after Milestone 2 looks like this:

```text
{"name":"kiroku-upgrade","from":"0.12.0.0","to":"0.13.0.0","outcome":"applied"}
{"name":"keiro-upgrade","from":"0.22.0.0","to":"0.23.0.0","outcome":"applied"}
{"name":"keiro-upgrade","from":"0.24.0.0","to":"0.25.0.0","outcome":"not-applicable"}
```

A not-applicable edge must carry a reason that the operator accepted at an approval gate.


## Validation and Acceptance

Required for each repository: the repository's own build and tests pass on its current
branch after the campaign's commits. The commands are `nix develop -c cabal build all` and
`nix develop -c cabal test all`, or the repository's `just` recipe that its AGENTS.md names.
`mori status` shows the registration as current, and the resolved keiro version is 0.25.0.0
unless an approved selection deferred `keiro-upgrade`. A MasterPlan exists under
`docs/masterplans/` whose child plans are marked Complete or carry an approved deferral.
Every `seihou agent migrate` edge has a receipt, and every runnable blueprint has a commit
with a `Blueprint:` trailer.

Required for the campaign: at least one Kioku learning is recorded under the playbook scope
`keiro-modernization`. At least one playbook change is merged through approval
before Milestone 3, and the Milestone 3 transcript cites it. There must be no
`shikigami-core` change. From the Shikigami checkout, this command must print nothing:

```bash
git log --format=%H --grep='ExecPlan: docs/plans/132-' | xargs -n1 git diff-tree --no-commit-id --name-only -r | grep '^shikigami-core/'
```

EP-5's fitness check must also pass with the command EP-5 documents.

A gap that would need a kernel change is recorded in the owning child plan's Surprises &
Discoveries, with a one-line pointer in this plan's Surprises, and also as a friction entry
via `record-friction.ts`. The owners are EP-1 for the tier, workspace, placement or grant;
EP-2 for coding-agent steps and attached skills; EP-3 for tool declarations, argument
patterns and the durable tool step; EP-4 for step kinds, item sources, output fields,
conditions, approval prompts and `Reflect`; and EP-8 for the action record, the `Manual`
trigger and the `local.inbox` approval channel. Until the baseline a plan may change only a
surface it owns, so the campaign never edits another plan's schema to make a step fit. A gap in Seihou, Mori
or `mina` becomes an improvement request in that repository, referenced by its `mori://`
URI. The multi-blueprint receipt gap is filed this way in `mori://shinzui/seihou`; its
artifact-level URI will be known once the request is allocated.

The earliest interaction check runs in Milestone 1, before any skill work. It is a one-step
playbook that runs the declared `mori status --json` tool on kanmon and refuses an undeclared
`gh` call. In EP-4's format that is a bundle with one playbook and one `Tool` step,
`mori status --json`, started with a payload naming kanmon; the refusal is shown by a second
bundle whose step names the undeclared tool `gh`, which fails with EP-3's refusal and appears
in `shikigami-local ledger`. It proves that EP-3 and EP-4 compose. If it fails, stop and
record the gap.

Out of scope: Linux or Apple-container qualification, and the `Contained` and
`MultiTenant` tiers.


## Idempotence and Recovery

Rerunning a playbook on the same repository is safe. Readiness probes are read-only, and fixes
check before acting. `seihou agent migrate` skips edges that already have an applied receipt
and replans not-applicable edges. EP-4's journal also skips completed steps after a worker
restart. A run that was drained by rejecting an approval is repeated as a new run with a new
`--key`; it converges because readiness fixes check before acting and applied migration
edges are skipped. A runnable blueprint has no skip, so the selection skill treats a `Blueprint:`
trailer already in the range from the recorded starting commit as done.

To abandon one repository's attempt, reject the pending approval and stop the run. Then run
`git -C <repo> reset --hard <start>` with the starting commit the readiness probe recorded.
The campaign commits directly to the current branch, so this reset is the undo. Nobody else
works in these repositories, so no other work is lost.
`mori register` and `mina ci` change state outside the repository: a registry row and a Rei
intention. Both are additive and are left in place. `migrate-keiro-stack` runs with
`database.policy=disposable`, because these services hold no data worth keeping (Decision
Log, 2026-11-15). Do not delete the Shikigami database to reset a campaign while one of its
runs is unfinished, because that run's journal is its only record of progress. Once every
run is terminal the database holds nothing the campaign still needs before the baseline: the
results live in the target repositories and the learnings in Kioku. After EP-11 ends the
exception, never delete it.


## Interfaces and Dependencies

Hard prerequisites: EP-3 and EP-4 must be Complete. EP-1, EP-2 and EP-8's first two
milestones come with them transitively. This plan consumes `TrustTier = LocalOperator`,
EP-1's confirm-once grant and `InPlace` workspace placement, the `CodingAgent` step, its
outcome and its attached skills from EP-2, and the declared `tools` field, argument patterns
and the durable tool step (`runDeclaredTool`, EP-3 M4) from EP-3. From EP-4 it consumes the
`Playbook` arm and bundle format, the step kinds `Tool`, `Skill`, `CodingAgent`, `Approval`,
`RunPlaybook`, `ForEach` and `Reflect`, the item sources `FromPayload` and `FromStep`, run
parameters with `Applies.ParamIs`, named output fields, `OnFailure.Continue`, inherited item
variables, the playbook-scoped memory key and the `shikigami playbook` commands. From EP-8 it
consumes `Trigger.Manual`, the `local.inbox` approval channel and the action record. EP-4
confirmed each campaign need on 2026-11-15 (MasterPlan 22 review); none is left for this plan
to invent. EP-11
(`docs/plans/136-freeze-the-v1-api-baseline-with-a-surface-inventory-and-compatibility-checks.md`)
depends on this plan's Milestone 3, because the baseline must not freeze before the
declaration surface has carried a real job on a second repository. Milestone 4 may finish
after the baseline. The soft prerequisite is EP-5's pack location. The external
tools are `seihou` 0.16.0.0 or later, `mori`, `mina`, `nix`, `cabal`, `just`, `jq` and
`bun`, plus the blueprints installed with `seihou install` from `mori://shinzui/keiro`,
`mori://shinzui/kiroku`, `mori://shinzui/shibuya-pgmq-adapter`, `mori://shinzui/agent-seihou`,
`mori://shinzui/seihou-modules` and `mori://shinzui/okf-profiles`.

Resolved with the user on 2026-11-15: the seven repositories and their order, direct commits
with no campaign branch, and `database.policy=disposable`. The user also confirmed that runnable blueprints may start their own Claude Code sessions
through Seihou (`seihou agent --batch`). No question remains open.

Revision note (2026-11-15): MasterPlan 22's review rewrote the declarations, steps and sketch
to EP-4's actual playbook format and EP-2's real outcome, moved blueprints onto EP-3 M4's
durable tool step, replaced hand-written approvals with EP-1's confirm-once grant, and
replaced "this plan ends the pre-release exception" with the drain rule and EP-11's gate.
