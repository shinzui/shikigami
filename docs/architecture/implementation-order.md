# Shikigami implementation order

Reviewed **2026-08-18**, superseding the 2026-08-10 review. Goal of this revision: record that
Stage A is complete, and re-read the order now that the cohort is fully current.

Three standing facts shape everything below.

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

Where this document and a MasterPlan registry disagree about a plan's *status*, the registry wins.
Where they disagree about *order*, this document is the cross-MasterPlan reading and is newer.
`docs/architecture/implementation-order.html` renders the 2026-08-05 state and is **stale** as of
this revision.


## The open set

53 ExecPlans across 10 MasterPlans. **15 are complete**; 38 have open work.

Complete: 1, 2, 3, 4, 5, 6, 7, 9, 10, 11, 15, 21, 36, 47, **53**.

Open with a small remainder (5 plans, ~1 session each):

| Plan | Remainder |
|---|---|
| 8 | Build/test run after the Danwa bridge removal, plus one manual verification against a live Danwa worker. Substantively done. |
| 13 | Live Anthropic smoke transcript. Never performed — no credential was available. Now a precondition of plan 52's positive conformance case. |
| 16 | One optional live observation of the outbox retrying a real sink. Not a gate on anything. |
| 37 | M3: `shikigami-migrate` still uses codd's `CODD_*` contract instead of Settei. Blocked by a Cabal package cycle. Reassigned to plan 38. |
| 38 | M4: the same `shikigami-migrate` Settei unification, plus `just migrate` still passing `DATABASE_URL`. |

Open and substantial (33 plans): 12, 14, 17, 18, 19, 20, 22, 23, 24, 25, 26, 27, 28 (10 of 14
items), 29, 30, 31, 32, 33, 34, 35, 39, 40, 41, 42, 43, 44, 45, 46, 48, 49, 50, 51, 52.


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

`keiro-dsl` is **not** pinned, because nothing in the repository depends on it yet. Adding it is
plan 39's own work, not something plan 53 did.

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
  IR-9 (`key-agent-continuity-by-meibo-principal`) — when agents resolve to real Meibo principals,
  `agentActor` takes its ref from Meibo instead of minting one, and no call site moves.
- **Related debt with an announced expiry.** Shikigami calls kioku's deprecated legacy write
  surface (`Session.start`, `complete`, `failSession`, `recordTurn`, `Memory.record`,
  `Recall.legacyRecall`) — about 24 `-Wdeprecations` warnings. The `*WithContext` replacements
  require a real `PrincipalRef` *and* a context, which is a larger change than the value swap
  already made. Kioku confirmed on 2026-08-18 that **no removal is scheduled** — no plan, no
  version in the pragmas, and ADR-8 gates deletion on every dependent Mori report compiling
  against `RecallTarget`. So this is unforced debt, best cleared alongside plan 23 / IR-9 when the
  write path moves to `*WithContext` anyway.
- **`keiro-dsl` is now at Language 5, which reverses this document's previous advice.** The
  2026-08-10 review told plan 39 to pin `--min-language 4` and explicitly not chase candidate
  language 5. keiro 0.13 **publishes Language 5 as the sole stable and default authoring
  contract**; Language 4 remains published and byte-compatible under explicit compatibility
  ownership, so existing Language-4 services may retain `--min-language 4`. Shikigami has no
  Language-4 specification to preserve, so plan 39 should author onto **Language 5** directly.
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
| 39 | **Re-baseline from keiro-dsl 0.11 to 0.13.** Author onto **Language 5**, not Language 4 — 0.13 publishes 5 as the sole stable default and this document's previous "pin `--min-language 4`, exclude 5" advice is superseded. Re-derive the `--deny CODE` list against 0.13's diagnostic set. Add the `keiro-dsl` dependency, which the repository does not yet have. |
| 17 | Gate cleared. Re-author against `shibuya-core 0.9`'s `ApplicationFailure DeadLetterCode Text`, the total reason projections, the canonical renderer, and the `shibuya.dead_letter.reason.code` span attribute. Delete any privately defined code taxonomy or renderer. Its M0 checklist item can be closed. |
| 48 | Gate cleared. Rewrite as a consumer of `Baikai.Agent` / `baikai-agent`: `AgentRunRequest`, `AgentCapability`, `AgentSafety`, `AgentCommand`, `AgentCeiling`/`applyAgentCeiling`. Drop the invented vocabulary. |
| 49 | Cite `Baikai.Evidence`'s `evidenceSchemaVersion` and digest split (`commitmentDigest` binds a record to a request; `configurationDigest` compares across runs). Do not define a second canonical encoder. |
| 51 | Gate cleared. Replace the stubbed deterministic evidence seam with real `ModelCallEvidence` via `Options.evidence`. Its "baikai IR-3 pending" and "kioku admitting baikai 0.5" notes are both discharged. |
| 52 | Gate cleared for evidence. Bind the canonical attestation encoding to `canonicalEncode` and `commitmentDigest` instead of freezing a bespoke one. Kikan IR-6 still ratifies the *envelope*, not the *encoder*. |
| 23 | **New requirement.** Name `Shikigami.Memory.Access` as the module it changes, and fold in retiring kioku's deprecated write surface — both are the same IR-9 work and doing them apart means touching the call sites twice. |
| 34, 50, 51 | **New requirement.** Each records or reads memory-scoped facts; each must go through `Shikigami.Memory.Access` rather than naming `legacyMemorySpaceId` directly. |
| 12 | Re-verify its three upstream contracts before scheduling M3–M5; all three still absent as of 2026-08-18, though baikai and shikumi now have plans. Keep M1–M2 startable. |
| 19 | M1 stays upstream-gated; re-verified against keiro 0.13. M2–M4 unaffected. |
| 27, 24, 25, 26 | Strike the byte-for-byte wire-preservation and in-flight-survival obligations (see next section); keep the machinery, drop the compatibility proofs. |
| 33, 43 | Re-point at post-plan-36 package placement. Domain types are `shikigami-core/src/Shikigami/Agent/{RunJob,Decl}.hs`; `shikigami-api` holds only `OpenApi.hs` and `Problem.hs`. Plan 33's note extends the substitution to plans 12, 32, 35, and 40. |
| every MasterPlan-3 child | Still outstanding. Their Context sections name pre-split paths; MasterPlan 3 records the corrected file map. |
| all | Refresh any Context section quoting a pinned version, module path, or upstream gate. Most were written 2026-07-30 and the cohort has moved twice since. |


## Compatibility work that v1 does not owe

Because nothing consumes Shikigami yet, the following scheduled work is **not** v1 scope. Each
should be struck from its plan with a note that it returns when the first real consumer exists.

- **Codd-ledger import** (plan 38 M3) — already cancelled 2026-08-05, for exactly this reason.
- **Byte-for-byte `SinkIntent` wire preservation** across plan 27's consolidation. Consolidate
  freely; assert the shape you want, not the shape you had.
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

### Stage B — Foundation · **the current entry stage**, all parallel

- **Plan 39** — the checked keiro DSL and evolution gate, now against **Language 5**. *The widest
  unblocker in the portfolio:* gates 24, 25, 26, 27, 35, 50, 51, and sits on both critical-path
  long poles. **This is the recommended next plan.** Re-baseline it onto keiro-dsl 0.13 as its
  first act.
- **Plan 18** — atomic offsets, inbox, and enqueue in one boundary. No upstream gate.
- **Plan 21** — database-backed sink permission grants. No upstream gate.
- **Plan 43** — practice-review contracts. Contract-only, no dependencies.
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

### Stage C — Core semantics · after B

- **Plan 17** — ✅ *gate cleared.* `shibuya-core 0.9` is pinned. Previously the highest-rework-risk
  plan in the portfolio; now the safest time it will ever be to implement. The contingency advice
  about isolating a private taxonomy behind one module is obsolete — do not do it.
- **Plan 24** — versioning discipline. After 39. Build the mechanism; skip the in-flight proofs.
- **Plan 50** — fail-closed profile resolution and run pinning. After 39 + 49. It adds a journaled
  workflow step, which is precisely what 39 governs. Route memory access through
  `Shikigami.Memory.Access`.
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
  owns** repointing `Shikigami.Memory.Access` at Meibo-resolved refs and moving the write path to
  kioku's `*WithContext` surface, which retires the deprecation debt; see IR-9.
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
53 ✅ → 39 → 24 → 25/26/27/35 → 42
            ↘ 50 → 51 → 52
17 ✅gate → 20 → 30/33 → 23, 40→41→42
18 ───────↗
19 M2–M4 → 22 → 14, 32, 28 M3, 52
                                  → 31
```

The long pole is **39 → 24 → 35 → 42** on the feature side and **39 → 50 → 51 → 52** on the
attestation side. Both now start at plan 39, which is startable today. **Nothing on the critical
path waits on another repository any more** except plan 19 M1 (keiro `PublishRejected`), which is
not a long-pole item. That is a material change: the previous two revisions both had an
upstream release on the critical path.

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
| Shikigami IR-9 | plans 23, 34, 50, 51 | ⏳ Real but **not urgent**. Until agents resolve to Meibo principals, `Shikigami.Memory.Access` mints its own self-asserted refs and the kioku deprecation debt stands. Kioku confirmed 2026-08-18 that no wrapper removal is scheduled. |

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

**IR-9 has no plan of its own, though the deadline scare it caused has been resolved.** It is
nominally covered by plan 23 in stage E. On 2026-08-18 it looked urgent — the working assumption
was that kioku's deprecated wrappers were about to be removed, which would have forced principal
resolution ahead of schedule. Kioku confirmed the opposite: no removal is planned, the pragmas
name no version, and ADR-8 gates deletion on every dependent Mori report compiling against
`RecallTarget`, which is not close to satisfied — kioku also found a **second consumer, `rei`**,
still on kioku 0.1.0.0 and missing from Mori's dependent list entirely.

What did come out of that exchange is a correction already applied: `Shikigami.Memory.Access` now
records `KnownPrincipal` over a self-asserted ref rather than `LegacyPrincipal`, because the
latter is decode-side only and asserted falsely that new events predate memory spaces. So IR-9 is
back to being tidy rather than urgent — but it still has no plan of its own, and stage E is a long
way out for something that owns both principal resolution and the `*WithContext` migration.

**Five plans belong to no MasterPlan.** Plans 7, 9, 10, 11 (complete) and plan 48 (open,
unregistered). Register 48 under MasterPlan 7 or as its own initiative now that it is being
rewritten on `Baikai.Agent`.

**Stale package placement.** Plans 43 and 33, and every MasterPlan-3 child's Context section, name
pre-split paths. Re-point each before implementation; MasterPlan 3 holds the corrected map.
