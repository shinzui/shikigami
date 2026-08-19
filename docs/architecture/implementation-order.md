# Shikigami implementation order

Reviewed **2026-08-19**, superseding the 2026-08-18 review. Goal of this revision: record that
plan 39 is complete, re-read the order now that Stage B's widest unblocker has landed, and
record a portfolio-wide finding the plan-39 work surfaced — **19 open plans cite file paths that
plan 36 deleted**, which is latent rework nobody had counted.

The 2026-08-18 revision's three standing facts still hold, with one addition.

**Shikigami has no users.** No database's history needs preserving, no workflow instance is in
flight across a deploy, and no wire payload has an external consumer. Every "preserve this
byte-for-byte", "import the old ledger", "survive the upgrade" obligation written into these plans
is therefore *not* v1 work. It is deferrable to the first plan that lands after real traffic
exists. This deletes a large amount of scheduled effort — see [Compatibility work that v1 does not
owe](#compatibility-work-that-v1-does-not-owe).

**The cohort is current and has no exclusions.** This is new as of 2026-08-18 and it is the
single biggest change since the last review. Every co-developed package sits at its newest Hackage
release with no `allow-newer` between any two of them. The previous two revisions were both
organised around dependency drift; this one is not.

**Three upstream gates closed at once, and they were not independent.** Plan 53 landing took
`shibuya-core 0.9` and `baikai 0.5` with it, which released plan 17 and plans 48/51/52
simultaneously. The portfolio has more startable work today than at any previous review.

**New 2026-08-19 — a plan's citations rot faster than its reasoning.** Plan 39's implementation
found that plan 24, written 2026-07-08, had 21 of its 59 `file:line` citations pointing at
deleted packages or drifted line numbers, while every argument in it remained sound. The cause
is two landed plans, not neglect: plan 36 split the tree into six packages and deleted
`shikigami-cli`, and plan 53 moved keiro from 0.4.0.1 to 0.13.0.0. Both are mechanical to detect
and cheap to fix; neither is visible from reading a plan. See
[Citation rot](#citation-rot-19-open-plans).

Where this document and a MasterPlan registry disagree about a plan's *status*, the registry wins.
Where they disagree about *order*, this document is the cross-MasterPlan reading and is newer.
`docs/architecture/implementation-order.html` renders the 2026-08-05 state and is **stale** as of
this revision.


## The open set

55 ExecPlans across 10 MasterPlans. **17 are complete**; 38 have open work.

Complete: 1, 2, 3, 4, 5, 6, 7, 9, 10, 11, 15, 21, 36, **39**, 47, 53, **55**.

Plan 55 was created and implemented on 2026-08-19, registered as F4 under MasterPlan 2. See
[the seventh package](#the-seventh-package-plan-55).

Open with a small remainder (5 plans, ~1 session each):

| Plan | Remainder |
|---|---|
| 8 | Build/test run after the Danwa bridge removal, plus one manual verification against a live Danwa worker. Substantively done. |
| 13 | Live Anthropic smoke transcript. Never performed — no credential was available. Now a precondition of plan 52's positive conformance case. |
| 16 | One optional live observation of the outbox retrying a real sink. Not a gate on anything. |
| 37 | M3: `shikigami-migrate` still uses codd's `CODD_*` contract instead of Settei. Blocked by a Cabal package cycle. Reassigned to plan 38. |
| 38 | M4: the same `shikigami-migrate` Settei unification, plus `just migrate` still passing `DATABASE_URL`. |

Open and substantial (33 plans): 12, 14, 17, 18, 19, 20, 22, 23, 24, 25, 26, 27, 28 (10 of 14
items), 29, 30, 31, 32, 33, 34, 35, 40, 41, 42, 43, 44, 45, 46, 48, 49, 50, 51, 52, 54.


## The cohort, as pinned

Verified 2026-08-18 against Hackage and against `cabal.project` at commit `9991032`. The matrix,
tag commits, and evidence live in `docs/dependency-cohort.md`, which is the contract; this table
is the summary.

| Package | Pinned | Latest released | Current? |
|---|---|---|---|
| `keiki`, `keiki-codec-json` | 0.9.0.0 | 0.9.0.0 | ✅ |
| `keiro`, `-core`, `-migrations` | 0.13.0.0 | 0.13.0.0 | ✅ |
| `kioku-*` | 0.4.1.0 | 0.4.1.0 | ✅ |
| `shikumi` (+ family) | 0.3.0.2 | 0.3.0.2 | ✅ |
| `baikai`, `baikai-claude` | 0.5.0.0 | 0.5.0.0 | ✅ |
| `pgmq-*` | 0.5.0.0 | 0.5.0.0 | ✅ |
| `shibuya-core` | 0.9.0.0 | 0.9.0.0 | ✅ |
| `shibuya-pgmq-adapter` | 0.14.0.0 | 0.14.0.0 | ✅ |
| `kiroku-store` / `-migrations` | 0.8.0.0 / 0.4.0.0 | same | ✅ |
| `shibuya-kiroku-adapter` | 0.5.1.1 | 0.5.1.1 | ✅ |
| `pg-migrate`, `settei`, `servant-health` | 1.1.0.0 / 0.2.0.0 / 0.1.0.0 | unchanged | ✅ |

`keiro-dsl` **is** pinned as of 2026-08-19, at `0.13.0.0`, by plan 39's Milestone 0. It is the
one cohort row that is not a library this service links against: it is the build-time
specification toolchain, so it is declared as `extra-packages: keiro-dsl` in `cabal.project`
rather than as a `build-depends` of any component. A `constraints:` row alone would not have
worked — nothing links it, so nothing would pull it in and `cabal run keiro-dsl` would have no
target.

**Two things the last revision predicted, and how they actually resolved.** The 2026-08-10 review
named two upstream releases as gating five plans, and asked for both to be requested. Neither
request was ever filed and both were satisfied anyway, by different releases than the ones
predicted:

- `keiro 0.12` was expected to lift the `shibuya-core <0.9` cap. **`keiro 0.13.0.0` did**, on
  2026-08-17. The 0.12 request is moot.
- A `kioku` admitting `baikai ^>=0.5` was expected to unblock plans 48, 51, and 52.
  **`kioku 0.4.1.0` delivered it**, on 2026-08-18.

The lesson worth carrying is narrow but real: this document twice scheduled around a *specific*
predicted release number. Both times the predicted version was wrong and the underlying gate
cleared anyway. Track the bound, not the version that will lift it.


## What upstream now ships that plans were scheduled to invent

Unchanged in substance from the 2026-08-10 reading, except that all three are now **pinned and
usable rather than gated**. This remains the largest rework saving in the portfolio.

**`baikai 0.5.0.0` ships `Baikai.Evidence`** — `ModelCallEvidence`, `evidenceSchemaVersion`,
`Observed`, `EndpointIdentity`, `CallStatus`, `EvidenceStrength`, and the canonical hashing core:
`canonicalEncode` (sorted keys, normalised numbers, a hand-written string escaper specifically so
an aeson upgrade cannot invalidate a recorded digest), `commitmentDigest`, and
`configurationDigest` over an allow-list `configurationProjection`. `Options` gains an `evidence`
field. This is, almost line for line, what MasterPlan 10 assigned to **plan 51** (real call
evidence, previously stubbed behind a deterministic reader seam) and **plan 52** (canonical
attestation encoding and hashing). Plans 51 and 52 must bind to these types rather than define
parallel ones. Plan 51 can retire its stub now.

**`baikai 0.5.0.0` also ships `Baikai.Agent` and a `baikai-agent` package** — `AgentRunRequest`
(required `workingDir`), `AgentRunResult`, the `AgentCapability` profile
(`read-only` / `edit-workspace` / `full-access`), `AgentSafety`, `AgentOutputMode`,
`AgentCommand`'s renderer/runner boundary, the `AgentRenderError` / `AgentRunFailure` taxonomies,
and the operator policy ceiling (`AgentCeiling`, `applyAgentCeiling`, which reports every violation
rather than silently clamping). That is the vocabulary **plan 48** was written to invent from
scratch. Plan 48 becomes a *consumer* of `Baikai.Agent`, which likely more than halves it.

**`shibuya-core 0.9.0.0` ships application-defined dead-letter codes** — `DeadLetterReason` gains
`ApplicationFailure DeadLetterCode Text`, with opaque validated codes, total adapter-facing
projections, a canonical renderer, and a stable `shibuya.dead_letter.reason.code` span attribute.
**Plan 17** owns Shikigami's failure taxonomy and imports `DeadLetterReason (..)` at
`shikigami-workers/src/Shikigami/Agent/RunJob/Worker.hs:35`. The 2026-08-10 review called starting
plan 17 early "the largest avoidable rework in the portfolio" — inventing a private code taxonomy
and renderer, then deleting both. **That risk is now gone**; 0.9 is pinned, and plan 17 is the
safest it will ever be to implement.


## What plan 39 delivered, and what it changes for everyone else

Landed 2026-08-19 across seven commits. `domain/shikigami.keiro-workspace` and its two members —
`shikigami-agent-run.keiro` and `shikigami-conversation.keiro` — are the checked source of truth
for Shikigami's durable workflow identities; `just keiro-gate` is the pre-merge gate; and both
workflow names now come from the specification rather than from Haskell literals, so
`Agent/Workflow/Name.hs` and `Agent/Conversation.hs` read them from generated modules and a
rename is `BREAKING [WorkflowStableNameChanged]`.

**Its census is the part that changes other plans, and it is mostly negative.** Shikigami has
**no aggregate, no read model, no projection, no router, and no process manager**. The single
`runCommandWithSqlEvents` call in the repository targets *kioku's* session stream, and
`Shikigami.Flow.Lifecycle.AtRiskCustomer` is a Keiki transducer that renders a Mermaid diagram
rather than an event source. The evidence is in
`docs/architecture/shikigami-domain-inventory.md`, which is now the reference for what the
specification does and does not cover.

Four consequences reach scheduled work:

- **Plan 51 introduces Shikigami's first aggregate**, and therefore turns on most of keiro-dsl's
  checked surface: `behavior-obligations` stops reporting `required: 0`, the warning table
  becomes reachable (which is why `--deny-warnings` passes today with nothing to justify),
  golden payloads acquire an owner, and `WorkspaceDuplicateDeclaration` gets a declaration to
  refuse. It should also add its own workspace member.
- **Plan 27's premise was wrong and is corrected in that plan.** Its Decision Log said "Plan 39's
  generated module owns the `SinkIntent` structural wire type and codec". There is no such
  module: an unconsumed `mapped structural` declaration generates a shape, a binding, and
  conformance assertions but **no codec**, so declaring it would certify a JSON policy nothing
  executes. Plan 27's Milestone 1 is now ordinary Haskell consolidation.
- **A workflow label is a wire word** — `[A-Za-z0-9][A-Za-z0-9_-]*`. Six of Shikigami's journaled
  label families carry a colon and a runtime-computed suffix and are therefore undeclarable:
  the approval awaits and their `:notify` steps (plan 14), `emit-signal:<ordinal>` (plan 16), and
  every per-message conversation label (plan 26). Plans 14, 16, and 26 carry reconciliation notes
  saying so. Note that plan 24's M3 makes `emit-signal` *stable* without making it *declarable* —
  `emit-signal:alert` still has a colon.
- **Four surfaces are deliberately undeclared** because declaring them would certify a codec the
  runtime does not execute: the `shikigami_run_jobs` queue, the Kafka inbox, the Danwa contract,
  and the sink outbox. That rule is now
  [ADR 0001](../adr/0001-declare-only-what-the-runtime-executes.md), and it binds every plan that
  later wants to declare one of them — each move is a wire change with its own commit, decision,
  and fixture, not a documentation change.

Two repository-level facts also came out of it. Generated keiro-dsl output is excluded from
`treefmt` ([ADR 0002](../adr/0002-generated-code-is-not-formatted.md)), because fourmolu and
cabal-fmt rewrite it and that breaks the firewall and scaffold determinism together. And
`docs/adr/` now exists, plain Markdown, no OKF bundle — the repository had no ADR corpus before.


## The seventh package: plan 55

Added 2026-08-19, and it corrects a plan this document has been treating as finished.

Plan 36 deleted `shikigami-cli` on 2026-07-30 as an umbrella dispatcher. That was right on the
architecture: the package depended on `shikigami-api`, `shikigami-core`, `shikigami-server`, and
`shikigami-workers` at once, so a single binary linked the HTTP server, the Kafka consumers, the
OTel exporter, and the worker loops. What plan 36 did not know is that the package also carried a
**product intent** — a one-off agent runner for consumers who are *not* running the Kikan
platform, which Kikan itself does not use, and which is what makes Shikigami versatile to
simpler consumers. That intent appears nowhere in plan 36, in `docs/architecture/packages.md`, in
any MasterPlan, or in `docs/improvement-requests/`. Because it was never written down, the
package read as pure architecture and was removed as such.

The capability survived and got expensive. `shikigami-run-behavior` and `shikigami-agent-run`
now live in `shikigami-workers`, whose library links `hw-kafka-client`, `kafka-effectful`,
`pgmq-effectful`, `shibuya-pgmq-adapter`, `hs-opentelemetry-sdk`,
`hs-opentelemetry-exporter-otlp`, `baikai-trace-otel`, and `async` — and every executable there
is `build-depends: base, optparse-applicative, shikigami-workers`, so all of it links into all
of them. `shikigami-run-behavior` is documented in `packages.md` as running "with deterministic
stubs (no database, no key)" and links `librdkafka`.

**Neither command is actually coupled to the platform.** `Workers/Command/RunBehavior.hs`
imports only `shikigami-core`; `AgentRun.hs` adds only kioku/kiroku, which it needs. The
coupling is `Shikigami.Workers.Command`, one composition module importing the two light commands
alongside the scheduler, worker, and Kafka subscription. That is the same umbrella shape plan 36
deleted — moved down one level, from between packages to inside one, where it stopped being
visible. `Shikigami.PackageArchitectureSpec` cannot see it either: it checks which *siblings* a
library declares, not what an *executable* drags in.

**Implemented 2026-08-19.** `shikigami-agent` exists, depends only on `shikigami-core`, and owns
`shikigami-run-behavior` and `shikigami-agent-run`; `cabal build shikigami-agent --dry-run`
names none of the eight platform packages. `RoleInfo`/`runRole` moved to `Shikigami.App.Role` in
core so both packages share one configuration-resolution order.
`Shikigami.PackageArchitectureSpec` now expects seven packages, applies the light-package
forbidden list to `shikigami-agent`, and adds the rule that **every executable links only its
own package's library** — the check that would have caught the original regression, since the
old sibling-edge rule could not see coupling inside a package. All three assertions were
mutation-tested. `docs/architecture/packages.md` gains a "Two ways to use Shikigami" section
stating the one-off mode as a constraint, and
[ADR 0003](../adr/0003-a-seventh-package-keeps-one-off-agent-runs-light.md) is the durable
record. It is a deliberate divergence from the fleet's "exactly six cabal packages" standard
(`mori://shinzui/keiro-runtime-patterns/docs/architecture-service-packages`), recorded as such:
the standard's objection is to edges *between* existing packages, and this adds a lighter leaf
under core.

**Sequencing: plan 55 landed before plan 48**, and plan 48 is revised to match. Plan 48's Purpose says its `shikigami-run` command
"never dispatches the declaration's sinks, never starts a trigger, and never opens Kioku or
PostgreSQL", and then assigns its executable to "the post-plan-36 workers package" — which would
ship a binary linking PGMQ and Kafka to prove it does not use them. Plan 55 gives it an honest
home. Plan 48 remains unregistered under any MasterPlan; that is still open.

**A general lesson worth carrying.** Plan 36's reasoning was sound and its outcome removed a
capability, because the capability's rationale lived in someone's head rather than in the
repository. An architecture document that lists what each package *is* does not, by itself,
protect what a package is *for*. Plan 55's Milestone 3 writes the use case into `packages.md` as
a requirement for that reason.


## Citation rot: 19 open plans

Found 2026-08-19 while implementing plan 24, and measured across the corpus afterwards.

**32 of 54 plans cite `shikigami-cli`, `shikigami-cli.cabal`, or
`shikigami-core/src/Shikigami/Worker.hs` — a package and a module that plan 36 deleted.** Of
those, **19 are plans with open work**: 8, 12, 13, 14, 16, 17, 18, 19, 20, 22, 23, 26, 27, 28,
29, 30, 31, 40, 48. Separately, **7 plans carry line-numbered `keiro/src/...` citations** that
all predate keiro 0.13: 14, 19, 24 (fixed), 25, 26, 28, 53.

The corrected destinations are mechanical:

| Retired | Current |
|---|---|
| `shikigami-cli/src/Shikigami/Cli/Commands/*.hs` | `shikigami-server/src/Shikigami/Server/Command/*.hs` for `validate` / `render-lifecycle` / `grants`; the worker, scheduler, consumer, and run-behavior entry points are executables in `shikigami-workers` |
| `shikigami-core/src/Shikigami/Worker.hs` (resume loop) | `shikigami-workers/src/Shikigami/Agent/Workflow/Resume.hs` |
| `shikigami-core/src/Shikigami/Worker.hs` (run-job ack) | `shikigami-workers/src/Shikigami/Agent/RunJob/Worker.hs` |
| `shikigami-cli.cabal` | `shikigami-server/shikigami-server.cabal` or `shikigami-workers/shikigami-workers.cabal` |

**This is not a reason to reschedule anything.** In plan 24 the arguments, milestones, and
acceptance criteria all survived; only the pointers were wrong. But a novice following an
unfixed plan opens a missing file at nearly every step, which is exactly what the
self-containment rule exists to prevent. So the standing instruction is: **audit a plan's
citations immediately before implementing it, not as a batch.** Resolving every
`` `path:line` `` against the working tree and against the pinned keiro tag takes a few minutes
and is the cheapest possible pre-flight. Plan 24's was done this way and is recorded in its
Decision Log.


## Drift each plan must still absorb

- **Resolved by plan 53 — `keiki 0.9`'s sealed `InCtor`.** The four hand-built values in
  `AtRiskCustomer.hs` now use `mkInCtorVia`, with `Generic` on `AtRiskCustomerCommand`.
  `unavailableInCtor` was rejected deliberately: it carries no trusted structural evidence and
  would have degraded `validateTransducer` to `UnverifiedOpaque`. Any *new* keiki state machine
  must make the same choice; the reasoning is in `docs/dependency-cohort.md`.
- **New, and it reaches several later plans — `kioku 0.4` made memory spaces and principals
  mandatory.** Every session/memory command record carries `memorySpaceId` and `actorPrincipal`;
  every read takes a leading `MemorySpaceId`. Shikigami answers both in one module,
  `shikigami-core/src/Shikigami/Memory/Access.hs`, with `legacyMemorySpaceId` and a
  `KnownPrincipal` over a self-asserted `shikigami.agent.<name>` ref. **Plans 23, 34, 50, and 51 should treat
  that module as the seam they change, not as settled.** It is also the retirement point for
  IR-9 (`key-agent-continuity-by-meibo-principal`), planned as
  `docs/plans/54-key-durable-agent-state-by-meibo-principal.md` — when agents resolve to real Meibo
  principals, `agentActor` takes its ref from Meibo instead of minting one.
- **Related debt with an announced expiry.** Shikigami calls kioku's deprecated legacy write
  surface (`Session.start`, `complete`, `failSession`, `recordTurn`, `Memory.record`,
  `Recall.legacyRecall`) — about 24 `-Wdeprecations` warnings. The `*WithContext` replacements
  require a real `PrincipalRef` *and* a context, which is a larger change than the value swap
  already made. Kioku confirmed on 2026-08-18 that **no removal is scheduled** — no plan, no
  version in the pragmas, and ADR-8 gates deletion on every dependent Mori report compiling
  against `RecallTarget`. So this is unforced debt, and **plan 54 owns clearing it** as part of
  moving the write path to `*WithContext`.
- **`keiro-dsl` Language 5 — discharged.** The 2026-08-10 review told plan 39 to pin
  `--min-language 4`; the 2026-08-18 review reversed that. Plan 39 landed on 2026-08-19 authored
  onto Language 5, and `just keiro-inspect` asserts every member reports `"languageSupport":
  "stable"` at effective version 5. Nothing further is owed here. A future language move is one
  change across the whole workspace, never per member: composition compares versions before
  merging and refuses a disagreement with `WorkspaceLanguageVersionMismatch`.
- **New — `baikai 0.5` added `ApiProvider.describeThinking`.** A strict field, so every
  implementor gets a compile error. `Shikigami.Behavior.StubProvider` is the only `ApiProvider` in
  the tree and now reports `ThinkingModeUnsupported` honestly. Any plan that adds a second provider
  must implement it by calling the same function that builds its request translation — baikai's own
  guidance — because two descriptions of one mapping diverge silently.
- **New — `keiro 0.13` corrected kiroku migration `0010`'s payload, changing its checksum.** A
  database that applied `0010` under `kiroku-store-migrations` 0.3.2.x must have its ledger row
  re-baselined once or every `up`/`verify` fails with `MigrationChecksumMismatch`. Shikigami was on
  0.3.0.0 and applied `0010` fresh, so **no shikigami database is affected** — recorded here
  because any *other* database that sees this cohort might be.
- **New — `keiro 0.13` publishes a Seihou blueprint, `blueprints/keiro-upgrade/`.** One
  agent-guided edge per version window, run with `seihou agent migrate keiro-upgrade`, entailing
  `kiroku-upgrade` so a Keiro-only consumer still crosses Kiroku's edge exactly once. Future keiro
  upgrades should go through it rather than being hand-derived the way plan 53 was.
- **`pgmq 0.5` narrows `parseQueueName` to `[a-z0-9_]{1,47}`.** `shikigami_run_jobs`
  (`shikigami-core/src/Shikigami/Trigger/Enqueue.hs:29`) conforms. No action. ✅
- **`kioku`'s projection-schema relocation is applied**, not pending. Migrations `0011`
  (memory-space partition and backfill) and `0012` (`kiroku.kioku_memories` → `kioku.memories`)
  are in the composed plan and applied on the dev cluster.
- **`keiro` still has not shipped `PublishRejected`.** Re-verified at `keiro-0.13.0.0`:
  `PublishOutcome` in `Keiro.Outbox` is still `PublishSucceeded | PublishFailed` only, and keiro
  plan `mori://shinzui/keiro/plans/165-add-terminal-outbox-publication-rejection-outcomes` remains
  unimplemented. **Plan 19 M1 remains blocked**; M2–M4 are not.
- **Plan 12's upstream contracts are still absent.** Re-verified at `baikai-0.5.0.0` and
  `shikumi-0.3.0.2`: neither ships MCP *source*. Both now carry MCP *plans* — baikai MasterPlan 6
  with plans 30–32, shikumi plan 30 — so the status improved from "proposed IR" to "planned
  upstream", but nothing is consumable. Plan 12 M1–M2 startable; M3–M5 not.


## Plans that must be updated before implementation

**Discharged since 2026-08-10:** plan 53 was implemented and its Revision Notes record what was
actually taken (keiro 0.13 and kioku 0.4.1.0, not the keiro 0.11 / kioku 0.3 it was re-baselined
onto on 2026-08-10). Its title and filename still say "0.11"; that is deliberate, because
`mori://` references to plan 53 are durable.

| Plan | Required update |
|---|---|
| 39 | ✅ **Implemented 2026-08-19.** No longer a plan needing an update; see [what it delivered](#what-plan-39-delivered-and-what-it-changes-for-everyone-else). |
| 24 | ✅ **Discharged 2026-08-19.** Citations refreshed against the working tree and keiro 0.13 (21 of 59 were wrong), two quoted keiro signatures corrected, the `enqueueSinkIntentStep` sketch brought up to its current arity, and the "workflow names are Haskell constants" claim replaced — plan 39 moved both into the specification. It also gained the plan-39 reconciliation section. **Ready to implement as written.** |
| every open plan | **New standing requirement.** Audit `file:line` citations immediately before implementing, per [Citation rot](#citation-rot-19-open-plans). 19 open plans cite deleted paths. |
| 48 | ✅ **Discharged 2026-08-19.** Its `shikigami-run` executable is re-pointed at `shikigami-agent`, and it gained a reconciliation section covering the enforced package boundary and the shared `Shikigami.App.Role.runRole`. Registration under a MasterPlan is still open. |
| 17 | Gate cleared. Re-author against `shibuya-core 0.9`'s `ApplicationFailure DeadLetterCode Text`, the total reason projections, the canonical renderer, and the `shibuya.dead_letter.reason.code` span attribute. Delete any privately defined code taxonomy or renderer. Its M0 checklist item can be closed. |
| 48 | Gate cleared. Rewrite as a consumer of `Baikai.Agent` / `baikai-agent`: `AgentRunRequest`, `AgentCapability`, `AgentSafety`, `AgentCommand`, `AgentCeiling`/`applyAgentCeiling`. Drop the invented vocabulary. |
| 49 | Cite `Baikai.Evidence`'s `evidenceSchemaVersion` and digest split (`commitmentDigest` binds a record to a request; `configurationDigest` compares across runs). Do not define a second canonical encoder. |
| 51 | Gate cleared. Replace the stubbed deterministic evidence seam with real `ModelCallEvidence` via `Options.evidence`. Its "baikai IR-3 pending" and "kioku admitting baikai 0.5" notes are both discharged. |
| 52 | Gate cleared for evidence. Bind the canonical attestation encoding to `canonicalEncode` and `commitmentDigest` instead of freezing a bespoke one. Kikan IR-6 still ratifies the *envelope*, not the *encoder*. |
| 23 | **New requirement.** Note that it is now a hard dependency of plan 54 (`IR-9`), which consumes its declaration-to-principal join. Plan 23 supplies the directory; plan 54 re-keys durable state and retires the kioku deprecation debt. |
| 34, 50, 51 | **New requirement.** Each records or reads memory-scoped facts; each must go through `Shikigami.Memory.Access` rather than naming `legacyMemorySpaceId` directly. |
| 12 | Re-verify its three upstream contracts before scheduling M3–M5; all three still absent as of 2026-08-18, though baikai and shikumi now have plans. Keep M1–M2 startable. |
| 19 | M1 stays upstream-gated; re-verified against keiro 0.13. M2–M4 unaffected. |
| 27, 25, 26 | Strike the byte-for-byte wire-preservation and in-flight-survival obligations (see next section); keep the machinery, drop the compatibility proofs. Verified 2026-08-19: plans 24 and 27 have already absorbed this; 25 and 26 still carry the plan-39 reconciliation section only. |
| 27 | **New requirement.** Its Decision Log entry "Plan 39's generated module owns the `SinkIntent` structural wire type and codec" is corrected in place; M1 is a Haskell consolidation, not a regeneration. Already applied 2026-08-19. |
| 33, 43 | Re-point at post-plan-36 package placement. Domain types are `shikigami-core/src/Shikigami/Agent/{RunJob,Decl}.hs`; `shikigami-api` holds only `OpenApi.hs` and `Problem.hs`. Plan 33's note extends the substitution to plans 12, 32, 35, and 40. |
| every MasterPlan-3 child | Still outstanding. Their Context sections name pre-split paths; MasterPlan 3 records the corrected file map. |
| all | Refresh any Context section quoting a pinned version, module path, or upstream gate. Most were written 2026-07-30 and the cohort has moved twice since. |


## Compatibility work that v1 does not owe

Because nothing consumes Shikigami yet, the following scheduled work is **not** v1 scope. Each
should be struck from its plan with a note that it returns when the first real consumer exists.

- **Codd-ledger import** (plan 38 M3) — already cancelled 2026-08-05, for exactly this reason.
- **Byte-for-byte `SinkIntent` wire preservation** across plan 27's consolidation. Consolidate
  freely; assert the shape you want, not the shape you had. Note the separate 2026-08-19 finding:
  the specification cannot own that shape yet either, because no declared node consumes it — so
  plan 27's consolidation is plain Haskell, and `WireCompatSpec` stays the guard until it lands.
- **In-flight workflow survival across a deploy** — plans 24, 25, 26. The `activePatches` /
  `WorkflowRunOptions` machinery is still worth building, because plan 39's checked topology gate
  and every later journaled value depend on the discipline existing. But "an in-flight conversation
  must survive this deploy" is not a v1 acceptance criterion. Build the mechanism; skip the proofs.
- **Replay and queue codec compatibility fixtures** (plan 47's pattern, inherited by plan 53). Old
  wire data does not exist.
- **Database remediation on upstream schema moves.** Still not owed — but worth recording that the
  forward path was exercised rather than avoided: plan 53 applied 16 migrations, including kioku's
  `0011` partition backfill and `0012` schema relocation, cleanly on the dev cluster (57 applied, 0
  pending, tests green). So "recreate the database" remains the cheap option, not the only one. A
  database that ever *does* hold real data is the `cohort-migrate` skill's job, never `just migrate`.
- **Additive-only journaled-value versioning discipline** as a hard constraint on plans 17, 19, 23,
  35 and 50. Prefer the right shape now over an additive shape that costs a later cleanup.

Everything else in those plans stands.


## The order

Stages are entry rules, not a schedule. Work inside a stage is parallel unless stated otherwise.


### Stage A — Re-baseline the cohort · ✅ complete 2026-08-18

Retired. Delivered by commit `9991032`.

- **A1 · Plan 53** ✅ — landed against a larger cohort than scoped: keiro 0.13, keiki 0.9,
  kioku 0.4.1.0, kiroku-store 0.8, shibuya-core 0.9, shibuya-pgmq-adapter 0.14, pgmq 0.5,
  baikai 0.5, shikumi 0.3.0.2. Code fallout was wider than predicted — kioku 0.4's mandatory
  memory spaces reached five files, which its changelog did not document.
- **A2 · `docs/dependency-cohort.md`** ✅ — rewritten as the August matrix with tag commits, the
  source cost, the deprecation debt, and the migration consequence.
- **A3 · The two upstream requests** ✅ discharged without being filed; see
  [the cohort section](#the-cohort-as-pinned). One request remains worth filing and is *not* a
  gate: kioku 0.4.0.0's changelog omits the mandatory memory-space and principal fields entirely.

### Stage B — Foundation · mostly discharged; the remainder is parallel with Stage C

Plan 21 was listed here through the 2026-08-18 revision and is **complete** — it has been in the
complete list since that revision, and the entry bullet was stale. Plan 39 is complete as of
2026-08-19.

- **Plan 39** ✅ **complete 2026-08-19.** The checked keiro DSL and evolution gate, on Language 5.
  It was the widest unblocker in the portfolio and it released 24, 25, 26, 27, 35, 50, and 51 —
  which is what opens Stage C.
- **Plan 18** — atomic offsets, inbox, and enqueue in one boundary. No upstream gate.
- **Plan 43** — practice-review contracts. Contract-only, no dependencies.
- **Plan 55** ✅ **complete 2026-08-19.** The seventh package for one-off agent runs. It
  unblocked plan 48, which now targets `shikigami-agent`.
- **Plan 49** — attestation vocabulary, citing `Baikai.Evidence`. Contract-only. Worth landing
  early: nine plans (12, 14, 22, 28, 33, 35, 39, 43, 44, 48) are each about to name an agent
  version, a repository revision, a correlation id, a review id, or a tool-catalog digest, and
  landing the vocabulary first turns nine future reconciliations into nine citations.
- **Plan 28 M2–M4** — metrics and tracing. M1 landed 2026-08-05. M3's HTTP trace propagation waits
  for plan 22's `postJSONWithHeaders`; M2 and M4 do not.
- **Cleanup batch** — plans 8, 16, and 37 M3 / 38 M4 (one Cabal package cycle to break, shared by
  the last two). Cheap, and 38's remainder is the only thing plan 31 waits on.
- **Plan 13's live smoke** — needs a credential, not engineering time. A precondition of plan 52's
  positive conformance case, so unblock it now rather than at stage F.

### Stage C — Core semantics · **the current entry stage**, opened by plan 39

- **Plan 17** — ✅ *gate cleared.* `shibuya-core 0.9` is pinned. Previously the highest-rework-risk
  plan in the portfolio; now the safest time it will ever be to implement. The contingency advice
  about isolating a private taxonomy behind one module is obsolete — do not do it.
- **Plan 24** — versioning discipline. After 39 ✅. Build the mechanism; skip the in-flight proofs.
  **This is the recommended next plan:** it is the first node on the longer of the two critical
  paths, both its hard dependencies are complete, and its citations were refreshed on 2026-08-19
  so it needs no pre-implementation update. It is also the first change that *exercises* plan
  39's gate rather than installing it — `AgentRun.patches` is `[]` in the committed conformance
  expectations, and this plan declares the first patch id.
- **Plan 50** — fail-closed profile resolution and run pinning. After 39 ✅ + 49. It adds a
  journaled workflow step, which is precisely what 39 governs — declaring it is two lines in
  `domain/shikigami-agent-run.keiro`, and `resolve-profile` is already a valid wire word. Route
  memory access through `Shikigami.Memory.Access`. **Plan 49 is the thing to land first if you
  want the attestation pole moving in parallel with 24**; it is contract-only and unblocks
  50 → 51 → 52.
- **Plan 19 M2–M4** — sink delivery truth. After 16 ✅ and 28 M1 ✅. **M1 stays blocked** on keiro
  `PublishRejected`, re-verified absent at 0.13.
- **Plan 12 M1–M2** — the `mcpServers` declaration and its validation. M3–M5 stay upstream-gated.
- **Plan 29 (local half)** — health and liveness. The worker probe waits on Shibuya IR-1;
  **re-checked against `shibuya-core 0.9` and it is not addressed** — 0.9's only feature is the
  dead-letter code vocabulary. Treat the probe as still gated.

### Stage D — Shared seams · after C

- **Plan 20** — explicit trigger routing and catch-up policy. After 17 + 18. Releases 30 and 33.
- **Plan 22** — outbound authentication. After 19 (terminal delivery taxonomy) and preferably after
  13 ✅ / 16 ✅. Sole owner of `HttpEnv`, `TokenSource`, `postJSONWithHeaders`; releases 14, 28 M3,
  32, 52.
- **Plans 25, 26** — replay-safe flow memory, conversation lifecycle. After 24 + 39.
- **Plans 30, 33** — operator CLI, agent schema evolution. Both after 20's `AgentLoadReport`.
- **Plan 51** — run evidence and compliance roll-up. After 49 + 50 + 39. Its real-evidence
  milestone is **no longer upstream-gated**; bind to `Baikai.Evidence` and retire the stub.

### Stage E — Feature completion · after D

- **Plan 23** — agent lifecycle with Meibo principals. After 30 + 33, preferably 21. **Now also
  establishes** the directory and the declaration-to-principal join that **plan 54** then consumes.
- **Plan 54** — key durable agent state by Meibo principal (`IR-9`). Strictly after 23. Re-keys
  memory scopes, grant subjects, run lineage, and outbound authorship onto the principal, and
  retires the kioku deprecation debt by moving writes to `*WithContext`.
- **Plan 27** — consolidate sink intent and run lifecycle. After 19 + 24 + 28. Consolidate freely.
- **Plan 14** — approval and human-in-the-loop. After 17 + 22.
- **Plan 32** — channel egress through Kanmon. After 19 + 22, preferably 21 + 27.
- **Plan 34** — memory lifecycle. Distillation and retention can start earlier; the shared-scope
  milestone waits for 33. Kioku IR-2 (indexed sessions, bounded reads) gates part of it.
- **Plan 35** — delegation as a declared capability. After 24 + 33 + 39.
- **Plan 48** — repository agent harness on `Baikai.Agent`. **No longer upstream-gated**; it could
  move earlier than stage E now that its vocabulary exists, subject to its own dependencies.
- **Plan 52** — signed attestation read API. After 51 + 22 + 44. Kikan IR-6 still ratifies the
  envelope.

### Stage F — Closure · last

- **Plans 40 → 41 → 42** (strictly serial) — router declaration, catalog, replay-safe execution.
  After 33; 42 additionally after 35.
- **Plans 44, 45 → 46** — practice-review evidence and memory, then orchestration. After 43; 44
  needs Kikan IR-5; 45 needs 25.
- **Plan 31** — deployable stack. Genuinely last: it documents the configuration surfaces that
  plans 13, 22, 29, and 32 own, and publishing it earlier means publishing placeholders.


## Critical path to v1

```
53 ✅ → 39 ✅ → 24 → 25/26/27/35 → 42
               ↘ 49 → 50 → 51 → 52
17 ✅gate → 20 → 30/33 → 23, 40→41→42
18 ───────↗
19 M2–M4 → 22 → 14, 32, 28 M3, 52
                                  → 31
```

The long pole is **24 → 35 → 42** on the feature side and **49 → 50 → 51 → 52** on the
attestation side. Both used to start at plan 39; with 39 complete, the feature pole starts at
**plan 24** (startable now, no update needed) and the attestation pole at **plan 49**
(contract-only, no dependencies). They are independent and can run in parallel. **Nothing on the
critical path waits on another repository** except plan 19 M1 (keiro `PublishRejected`), which is
not a long-pole item.

If a v1 cut smaller than "all 38 plans" becomes attractive, the natural line is **after stage D**:
that yields a service with a real provider, honest sinks, correct delivery semantics, checked
durable topology, authenticated egress, operator CLI, health, and observability. Stage E adds
platform features and stage F adds two whole initiatives (router agents, practice reviews) plus
packaging. Cutting there would defer MasterPlans 8, 9, and 10 rather than shipping them
half-built.


## Upstream gates, current status

| Gate | Blocks | Status 2026-08-18 |
|---|---|---|
| Kioku IR-1 | plan 47 | ✅ Closed. |
| kioku 0.3.0.0 | plan 53 M0 | ✅ Closed; superseded by kioku 0.4.1.0. |
| Baikai IR-3 | plans 51, 52 | ✅ **Closed.** `Baikai.Evidence` shipped in baikai 0.5.0.0 and baikai 0.5.0.0 is now pinned. |
| keiro 0.12 | plan 17; improved 19, 29 | ✅ **Moot.** `keiro 0.13.0.0` lifted the `shibuya-core <0.9` cap instead; 0.9.0.0 is pinned. |
| kioku admitting `baikai ^>=0.5` | plans 48, 51, 52 | ✅ **Closed 2026-08-18** by `kioku 0.4.1.0`. Never filed as a request. |
| Keiro IR-3 / keiro plan 165 | plan 19 M1 | ❌ Re-verified at keiro 0.13: `PublishOutcome` is still `PublishSucceeded \| PublishFailed`. Plan 165 unimplemented. |
| Kioku IR-2 | plans 26, 34 | ❌ Proposed. |
| Shibuya IR-1 | plan 29's worker probe | ❌ Re-checked against `shibuya-core 0.9`: **not addressed.** 0.9 ships only the dead-letter code vocabulary. |
| Baikai IR-2 | plan 12 M3–M5 | ❌ No `Baikai.Mcp.*` source in baikai 0.5. Now planned upstream (baikai MasterPlan 6, plans 30–32). |
| Shikumi IR-1 | plan 12 | ❌ No MCP adapter in shikumi 0.3.0.2. Now planned upstream (shikumi plan 30). |
| Kikan-En IR-3 | plan 12 | ❌ Proposed. |
| Kikan IR-5 | plans 44, 46, 52 | ❌ Proposed. |
| Kikan IR-6 | plan 52 | ❌ Proposed. Scope shrinks: it ratifies the envelope, not the encoder. |
| Shikigami IR-9 | plans 34, 50, 51 | ⏳ Real but **not urgent**, and now planned: `docs/plans/54-key-durable-agent-state-by-meibo-principal.md` (after plan 23). Until it lands, `Shikigami.Memory.Access` mints self-asserted refs and the kioku deprecation debt stands. Kioku confirmed 2026-08-18 that no wrapper removal is scheduled. |

The pattern to keep using where a contract is pending: define a reader or source record of function
fields, satisfy it with a stub plus fixtures in tests, and let the live client replace the stub.
Plan 44 does this for the content plane; plan 51 did it for call evidence — and plan 51 can now
retire its stub.

**One request worth filing outward.** kioku 0.4.0.0's changelog documents only the projection-schema
relocation and says nothing about making `memorySpaceId` / `actorPrincipal` mandatory across its
command and query API. That undocumented break was the largest single cost in plan 53 and was found
by compiling, not by reading release notes. It gates nothing, but the next consumer deserves better.


## Coverage gaps

Carried forward from the 2026-08-05 audit; none has closed.

**Three inbound requests have no plan.** Of the requests in `docs/improvement-requests/`, IR-2
(authorized cross-cluster diagnostic tools), IR-5 (governed agent evolution), and IR-6 (A2A
cross-runtime interoperability) appear in no MasterPlan or ExecPlan. IR-5 is the consequential one —
declaration revision, behavior artifact identity, run pinning, baseline-to-candidate relation,
rollout policy — and plan 33 covers only `identity`, `memory`, and `enabled`. Plan 49's
`AgentVersionRef` / `AgentArtifactSet` are deliberately shaped so a governed-evolution plan extends
them additively. IR-6's upstream counterpart
`mori://shinzui/kikan/okf/improvement-requests/concepts/IR-4` is `accepted`, which makes an
unplanned request here the most awkward of the three. **These three need a decision before v1 is
declared feature-complete** — either plans, or an explicit post-v1 deferral.

**IR-9 now has a plan.** `docs/plans/54-key-durable-agent-state-by-meibo-principal.md`, registered
as EP-4 under MasterPlan 4, closes what was a coverage gap through 2026-08-18. It hard-depends on
plan 23 — plan 23 implements `IR-1` and builds the Meibo-backed directory, and `IR-1` deliberately
leaves Kioku memory scopes keyed by declaration name, which is precisely the gap `IR-9` closes.

The deadline scare that made this look urgent is resolved. The working assumption on 2026-08-18
was that kioku's deprecated write wrappers were about to be removed, forcing principal resolution
ahead of schedule. Kioku confirmed the opposite: no removal is planned, the pragmas name no
version, and ADR-8 gates deletion on every dependent Mori report compiling against `RecallTarget`,
which is not close — kioku also found a **second consumer, `rei`**, still on kioku 0.1.0.0 and
missing from Mori's dependent list entirely. A correction was applied in the meantime:
`Shikigami.Memory.Access` records `KnownPrincipal` over a self-asserted ref rather than
`LegacyPrincipal`, because the latter is decode-side only and falsely asserted that new events
predate memory spaces.

So plan 54 inherits plan 23's stage-E position rather than needing to be pulled forward. It also
owns retiring the ~24 kioku `-Wdeprecations` warnings, since the `*WithContext` surface needs the
principals plan 54 supplies.

**Five plans belong to no MasterPlan.** Plans 7, 9, 10, 11 (complete) and plan 48 (open,
unregistered). Register 48 under MasterPlan 7 or as its own initiative now that it is being
rewritten on `Baikai.Agent` — and note that plan 55 gives it a package home first, so the two
should be registered together. Plan 55 itself is registered as F4 under MasterPlan 2, because it
corrects F1's output.

**A capability was deleted because its purpose was undocumented.** Recorded here as a coverage
gap in its own right: `shikigami-cli` served consumers not running the Kikan platform, and that
requirement existed in no plan, MasterPlan, improvement request, or architecture document. It is
worth asking which *other* capabilities are held only by intent. The three unplanned inbound
requests above are the known unknowns; this was an unknown one.

**Stale package placement — measured 2026-08-19 and wider than this entry said.** It is not just
plans 43 and 33 and the MasterPlan-3 children: **19 plans with open work** cite `shikigami-cli` or
`shikigami-core/src/Shikigami/Worker.hs`, neither of which exists. The full list, the corrected
destinations, and the standing instruction are in [Citation rot](#citation-rot-19-open-plans).
MasterPlan 3 still holds the corrected map for its own children.


## Revision note (2026-08-19)

Plan 39 is complete, which moves the entry stage from B to C and re-points both critical paths.
The feature pole now starts at **plan 24** and the attestation pole at **plan 49**; they are
independent. Plan 24 is the recommended next plan, and unlike most of the corpus it needs no
pre-implementation update — its citations were refreshed the same day.

Two sections are new. [What plan 39 delivered](#what-plan-39-delivered-and-what-it-changes-for-everyone-else)
records the census that reshaped it: Shikigami has no aggregate, no read model, no projection, no
router, and no process manager, so the specification declares two durable workflows and nothing
else, and four surfaces are deliberately undeclared because declaring them would certify a codec
the runtime does not execute. That rule is now ADR 0001. Plans 14, 16, 26, 27, and 51 each
acquired obligations from it, and plan 27's premise was wrong and is corrected in that plan.

[Citation rot](#citation-rot-19-open-plans) is the finding this document did not have before.
Implementing plan 24 required fixing 21 of its 59 `file:line` citations, none of which its author
got wrong — plan 36 deleted `shikigami-cli` and plan 53 moved keiro's line numbers underneath
them. Measured across the corpus, 32 of 54 plans cite a deleted path and 19 of those are open.
The standing instruction is to audit citations immediately before implementing a plan rather than
batching the fix, because the corpus will rot again the next time a package moves.

Smaller corrections: `keiro-dsl` is now pinned at `0.13.0.0` via `extra-packages`, where the
cohort table said it was not pinned; the Stage B bullet for plan 21 was stale (21 has been
complete since the 2026-08-18 revision); the Language-5 advice is discharged rather than
outstanding; and the coverage-gap entry on stale package placement now carries a measured number
instead of naming two plans.

**Addendum (2026-08-19).** Plan 55 created, registered as MasterPlan 2's F4, and **implemented**
the same day; the open set is 55 plans, 17 complete. See
[the seventh package](#the-seventh-package-plan-55) for why plan 36's deletion of
`shikigami-cli` needed correcting, and the coverage-gap note on capabilities held only by
intent. The recommended next plan is unchanged: **plan 24** on the feature pole, **plan 49** on
the attestation pole.
