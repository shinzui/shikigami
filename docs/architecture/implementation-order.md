# Shikigami implementation order

Reviewed **2026-08-10**, superseding the 2026-08-05 review. Goal of this revision: a single
dependency-aware order for implementing **every open ExecPlan** and cutting the **first release**.

Two standing facts shape everything below.

**Shikigami has no users.** No database's history needs preserving, no workflow instance is in
flight across a deploy, and no wire payload has an external consumer. Every "preserve this
byte-for-byte", "import the old ledger", "survive the upgrade" obligation written into these plans
is therefore *not* v1 work. It is deferrable to the first plan that lands after real traffic
exists. This deletes a large amount of scheduled effort — see [Compatibility work that v1 does not
owe](#compatibility-work-that-v1-does-not-owe).

**The dependency ecosystem moved substantially between 2026-07-30 and today.** Most plans were
authored against the July cohort and name APIs that have since been superseded. Two upstream
releases now contain, already built, machinery that three plans were scheduled to hand-roll.
Re-baselining the cohort is therefore the first thing to do, not the last — see
[Ecosystem drift](#ecosystem-drift-and-what-it-changes).

Where this document and a MasterPlan registry disagree about a plan's *status*, the registry wins.
Where they disagree about *order*, this document is the cross-MasterPlan reading and is newer.
`docs/architecture/implementation-order.html` renders the 2026-08-05 state and is **stale** as of
this revision.


## The open set

53 ExecPlans across 10 MasterPlans. **14 are complete**; 39 have open work.

Complete: 1, 2, 3, 4, 5, 6, 7, 9, 10, 11, 15, 21, 36, 47.

Open with a small remainder (5 plans, ~1 session each):

| Plan | Remainder |
|---|---|
| 8 | Build/test run after the Danwa bridge removal, plus one manual verification against a live Danwa worker. Substantively done. |
| 13 | Live Anthropic smoke transcript. Never performed — no credential was available. Now a precondition of plan 52's positive conformance case. |
| 16 | One optional live observation of the outbox retrying a real sink. Not a gate on anything. |
| 37 | M3: `shikigami-migrate` still uses codd's `CODD_*` contract instead of Settei. Blocked by a Cabal package cycle. Reassigned to plan 38. |
| 38 | M4: the same `shikigami-migrate` Settei unification, plus `just migrate` still passing `DATABASE_URL`. |

Open and substantial (34 plans): 12, 14, 17, 18, 19, 20, 22, 23, 24, 25, 26, 27, 28 (10 of 14
items), 29, 30, 31, 32, 33, 34, 35, 39, 40, 41, 42, 43, 44, 45, 46, 48, 49, 50, 51, 52, 53.


## Ecosystem drift, and what it changes

Every co-developed package below is released on Hackage (verified 2026-08-10). "Pinned" is what
`cabal.project` selects today.

| Package | Pinned | Latest released | Admissible now? |
|---|---|---|---|
| `keiki`, `keiki-codec-json` | 0.4.0.0 | **0.9.0.0** | ✅ yes |
| `keiro`, `-core`, `-migrations`, `-dsl` | 0.4.0.1 | **0.11.0.0** | ✅ yes |
| `kioku-*` | 0.2.0.0 | **0.3.0.0** | ✅ yes |
| `shikumi` (+ family) | 0.3.0.1 | **0.3.0.2** | ✅ yes |
| `pgmq-*` | 0.4.0.1 | **0.5.0.0** | ✅ yes |
| `shibuya-pgmq-adapter` | 0.12.0.0 | 0.14.0.0 | ⚠️ **0.13.0.0** only |
| `shibuya-core` | 0.8.0.1 | 0.9.0.0 | ❌ capped by keiro 0.11 |
| `kiroku-store` | 0.3.1.0 | 0.4.0.0 | ❌ capped by keiro 0.11 |
| `shibuya-kiroku-adapter` | 0.4.0.0 | 0.4.0.1 | ❌ follows `kiroku-store` |
| `baikai`, `baikai-claude` | 0.4.1.0 / 0.4.0.1 | 0.5.0.0 | ❌ capped by kioku 0.3 |
| `pg-migrate`, `settei`, `servant-health` | 1.1.0.0 / 0.2.0.0 / 0.1.0.0 | unchanged | ✅ |

**The plan-53 gate cleared five days ago and nobody noticed.** `kioku 0.3.0.0` was published
2026-08-05 and declares `keiki ^>=0.9.0.0`, `keiro ^>=0.11.0.0`, `keiro-core ^>=0.11.0.0`. That
was the *single* condition plan 53's M0 was waiting on. Plan 53 is startable today, and since
plan 39 waits on plan 53, and plan 39 gates plans 24, 25, 26, 27, 35, 50, and 51, this is the
highest-leverage unblock in the portfolio.

**Exactly two upstream releases gate the rest of the catch-up.** They are worth requesting now
because they sit on the critical path of five plans:

1. **`keiro 0.12`** — already staged in keiro's `Unreleased` section, which requires
   `kiroku-store >=0.4 && <0.5`. Publishing it lifts the `shibuya-core <0.9` and
   `kiroku-store <0.4` caps, which in turn unlocks `shibuya-core 0.9.0.0`,
   `shibuya-pgmq-adapter 0.14.0.0`, `kiroku-store 0.4.0.0`, and `shibuya-kiroku-adapter 0.4.0.1`.
   → gates **plan 17**, and improves plans 19, 29.
2. **A `kioku` release admitting `baikai ^>=0.5`** — `kioku-core 0.3.0.0` pins `baikai ^>=0.4.1.0`,
   which excludes 0.5. → gates the good version of **plans 48, 51, 52**.

### Two upstream releases already contain work three plans scheduled to invent

This is where the rework savings are, and it is the main reason to re-baseline before implementing.

**`baikai 0.5.0.0` ships `Baikai.Evidence`** — `ModelCallEvidence`, `evidenceSchemaVersion`,
`Observed`, `EndpointIdentity`, `CallStatus`, `EvidenceStrength`, and, critically, the canonical
hashing core: `canonicalEncode` (sorted keys, normalised numbers, a hand-written string escaper
specifically so an aeson upgrade cannot invalidate a recorded digest), `commitmentDigest`, and
`configurationDigest` over an allow-list `configurationProjection`. `Options` gains an `evidence`
field. This is, almost line for line, what MasterPlan 10 assigned to **plan 51** (real call
evidence, previously stubbed behind a deterministic reader seam pending "baikai IR-3") and to
**plan 52** (canonical attestation encoding and hashing). Baikai IR-3 is delivered. Plans 51 and 52
should bind to these types rather than define parallel ones.

**`baikai 0.5.0.0` also ships `Baikai.Agent` and a `baikai-agent` package** — `AgentRunRequest`
(required `workingDir`), `AgentRunResult`, the `AgentCapability` profile
(`read-only` / `edit-workspace` / `full-access`), `AgentSafety`, `AgentOutputMode`,
`AgentCommand`'s renderer/runner boundary, the `AgentRenderError` / `AgentRunFailure` taxonomies,
and the operator policy ceiling (`AgentCeiling`, `applyAgentCeiling`, which reports every violation
rather than silently clamping). That is the vocabulary **plan 48** (portable one-off repository
agent harness) was written to invent from scratch. Plan 48 should be rewritten as a *consumer* of
`Baikai.Agent`, which likely more than halves it.

**`shibuya-core 0.9.0.0` ships application-defined dead-letter codes** — `DeadLetterReason` gains
`ApplicationFailure DeadLetterCode Text`, with opaque validated codes, total adapter-facing
projections, a canonical renderer, and a stable `shibuya.dead_letter.reason.code` span attribute.
**Plan 17** owns Shikigami's failure taxonomy and imports `DeadLetterReason (..)` at
`shikigami-workers/src/Shikigami/Agent/RunJob/Worker.hs:35`. Implementing plan 17 against
`shibuya-core 0.8` means inventing a private code taxonomy and a private renderer and then
deleting both. **This is the largest avoidable rework in the portfolio, and it is new since
2026-08-05.** Plan 17 should wait for `keiro 0.12` → `shibuya-core 0.9`.

### Other drift each plan must absorb

- **`keiki 0.9` seals `InCtor` / `WireCtor` construction.** `mkInCtor`/`mkWireCtor` are deprecated;
  manual behavior needs `unavailableInCtor`/`unavailableWireCtor`, trusted evidence needs the
  Generic or TH producers. Shikigami hand-builds `InCtor` in
  `shikigami-core/src/Shikigami/Flow/Lifecycle/AtRiskCustomer.hs:112-130`. Small, mechanical, and
  the only keiki-0.9 fallout in the tree. Keiki 0.9 also rewrote inversion-ambiguity analysis, so
  `mkEventStreamOrThrow` can now fail at runtime rather than compile time — exercise the startup
  path.
- **`keiro 0.5 → 0.11` is almost entirely `keiro-dsl`.** The runtime surface Shikigami actually
  calls — durable workflows, awakeables, child workflows, timers, the transactional outbox, the
  idempotent inbox — is essentially unchanged. Plan 53 says this itself and it is correct.
- **`keiro-dsl 0.11` is what plan 39 actually needs.** Released language 4, `check --min-language N`
  as a floor, `--deny-warnings` / `--deny CODE`, machine-readable `check --report-out`, and
  resolution of every internally decidable process, router, projection, publisher, queue, pgmq
  source-key, read-model, and timer-ID surface. Adopting the DSL against 0.4 and re-adopting
  against 0.11 is doing plan 39 twice. **Note:** keiro's `Unreleased` carries a *candidate*
  language 5 (projection catalogs, rebuild groups). Plan 39 should pin `--min-language 4` and
  explicitly not chase language 5 — it is amended in place until publication.
- **`pgmq 0.5` narrows `parseQueueName` to `[a-z0-9_]{1,47}`.** `shikigami_run_jobs`
  (`shikigami-core/src/Shikigami/Trigger/Enqueue.hs:29`) already conforms. No action.
- **`kioku` `Unreleased` relocates its seven projections out of the `kiroku` schema into a
  dedicated `kioku` schema** (`kiroku.kioku_memories` → `kioku.memories`, etc., migration 0012),
  and advances read-model identities to memory v3 / session v5 / turn v3 so a binary on the wrong
  side fails closed. Because Shikigami has no data, this is a free upgrade whenever it publishes —
  take it, do not plan an outage for it.
- **`keiro` still has not shipped `PublishRejected`.** `PublishOutcome` in `Keiro.Outbox` is still
  `PublishSucceeded | PublishFailed` only, and keiro's implementing plan
  `mori://shinzui/keiro/plans/165-add-terminal-outbox-publication-rejection-outcomes` has zero of
  four milestones done. **Plan 19 M1 remains blocked**; M2–M4 are not.
- **Plan 12's upstream contracts are still absent.** There is no `Baikai.Mcp.*` module in baikai
  0.5 and no MCP adapter in the shikumi package set (`shikumi-tools` has none). Baikai IR-2 and
  Shikumi IR-1 are unmet; Kikan-En IR-3 (per-action agent authorization) likewise. Plan 12 M1–M2
  are startable; M3–M5 are not.

### Every plan that must be updated before it is implemented

**Status: all fifteen were updated on 2026-08-10.** Each carries a dated revision note recording
what changed and why, so the table below is now a record of what was done rather than a backlog.
Two of the updates corrected outright errors rather than staleness, and are worth knowing about
before implementing either plan: plan 53 asserted that shikigami never constructs a keiki `InCtor`
directly, which is false and means the build will stop where the plan says it will not; and plan
33 sent an implementer to `shikigami-api/src/Shikigami/Api/Agent.hs`, a module plan 36 deleted,
in a package the worker is forbidden to depend on.

| Plan | Required update |
|---|---|
| 53 | Rescope: record that M0 cleared on 2026-08-05 via `kioku 0.3.0.0`. State explicitly which packages the cohort does **not** take and why (`shibuya-core 0.9`, `kiroku-store 0.4`, `baikai 0.5` are bound-excluded by keiro 0.11 / kioku 0.3). Delete the replay- and queue-codec compatibility milestones — no data exists. Add the `AtRiskCustomer.hs` sealed-ctor fix and the `pgmq 0.5` + `shibuya-pgmq-adapter 0.13` step. |
| 39 | Re-author against `keiro-dsl 0.11` language 4. Adopt `check --min-language 4`, `--deny-warnings`, `--deny CODE`, and `check --report-out` as the CI gate. Explicitly exclude candidate language 5. |
| 17 | Re-author against `shibuya-core 0.9`'s `ApplicationFailure DeadLetterCode Text`, the total reason projections, the canonical renderer, and the `shibuya.dead_letter.reason.code` span attribute. Delete any privately defined code taxonomy or renderer. |
| 48 | Rewrite as a consumer of `Baikai.Agent` / `baikai-agent`: `AgentRunRequest`, `AgentCapability`, `AgentSafety`, `AgentCommand`, `AgentCeiling`/`applyAgentCeiling`. Drop the invented vocabulary. |
| 49 | Cite `Baikai.Evidence`'s `evidenceSchemaVersion` and digest split (`commitmentDigest` binds a record to a request; `configurationDigest` compares across runs). Do not define a second canonical encoder. |
| 51 | Replace the stubbed deterministic evidence seam with real `ModelCallEvidence` via `Options.evidence`. Retarget its "baikai IR-3 pending" note — IR-3 is delivered; the gate is now a kioku release admitting `baikai ^>=0.5`. |
| 52 | Bind the canonical attestation encoding to `canonicalEncode` and `commitmentDigest` instead of freezing a bespoke one. Kikan IR-6 still ratifies the *envelope*; it no longer needs to ratify the *encoder*. |
| 12 | Re-verify its three upstream contracts before scheduling M3–M5; all three are still absent as of 2026-08-10. Keep M1–M2 (schema + validation) startable. |
| 19 | Split M1 out as upstream-gated. Confirm keiro plan 165's status before scheduling it. |
| 27, 24, 25, 26 | Strike the byte-for-byte wire-preservation and in-flight-survival obligations (see next section); keep the machinery, drop the compatibility proofs. |
| 33, 43 | Re-point at post-plan-36 package placement. Domain types are `shikigami-core/src/Shikigami/Agent/{RunJob,Decl}.hs`; `shikigami-api` is the public HTTP contract package and now holds only `OpenApi.hs` and `Problem.hs`. Plan 33's note extends the substitution to plans 12, 32, 35, and 40, which inherit its additive-field pattern. |
| every MasterPlan-3 child | Still outstanding. Their Context sections name pre-split paths; MasterPlan 3 records the corrected file map in one place. Re-point each before implementation. |
| all | Refresh any Context section that quotes a pinned version, a module path, or an upstream gate. Most were written 2026-07-30. |


## Compatibility work that v1 does not owe

Because nothing consumes Shikigami yet, the following scheduled work is **not** v1 scope. Each
should be struck from its plan with a note that it returns when the first real consumer exists.

- **Codd-ledger import** (plan 38 M3) — already cancelled 2026-08-05, for exactly this reason.
- **Byte-for-byte `SinkIntent` wire preservation** across plan 27's consolidation. Consolidate
  freely; assert the shape you want, not the shape you had.
- **In-flight workflow survival across a deploy** — plans 24, 25, 26. The `activePatches` /
  `WorkflowRunOptions` machinery is still worth building, because plan 39's checked topology gate
  and every later journaled value depend on the discipline existing. But "an in-flight conversation
  must survive this deploy" is not a v1 acceptance criterion, and the patch-guard branches it
  implies can be deferred. Build the mechanism; skip the proofs.
- **Replay and queue codec compatibility fixtures** (plan 47's pattern, inherited by plan 53). Old
  wire data does not exist.
- **Database remediation on upstream schema moves** — the kioku `kioku`-schema relocation, and
  anything the `cohort-migrate` skill would cover. Recreate the database.
- **Additive-only journaled-value versioning discipline** as a hard constraint on plans 17, 19, 23,
  35 and 50. Prefer the right shape now over an additive shape that costs a later cleanup.

Everything else in those plans stands.


## The order

Stages are entry rules, not a schedule. Work inside a stage is parallel unless stated otherwise.


### Stage A — Re-baseline the cohort · start immediately, alone

Nothing else should be implemented until A1 lands. Every plan below it compiles against the cohort,
and implementing against the July pins means rebasing that work through five keiro majors.

- **A1 · Plan 53**, rescoped per the table above. Take `keiro`/`-core`/`-migrations`/`-dsl` 0.11.0.0,
  `keiki` + `keiki-codec-json` 0.9.0.0, `kioku-*` 0.3.0.0, `shikumi` 0.3.0.2, and — verified
  compatible with keiro 0.11's `shibuya-core <0.9` cap — `pgmq-*` 0.5.0.0 with
  `shibuya-pgmq-adapter` 0.13.0.0. Expected code fallout is confined to the sealed-ctor fix in
  `AtRiskCustomer.hs` and the startup path for `mkEventStreamOrThrow`.
- **A2 · Rewrite `docs/dependency-cohort.md`** as the August matrix, and record the two bound-derived
  exclusions (`shibuya-core 0.9`, `kiroku-store 0.4`, `baikai 0.5`) as *pending on named upstream
  releases* rather than as oversights.
- **A3 · File the two upstream requests now**, in parallel with A1, because they gate stage C:
  publish `keiro 0.12` (its `Unreleased` section is already written), and a `kioku` release
  admitting `baikai ^>=0.5`.

### Stage B — Foundation · after A1, all parallel

- **Plan 39** — the checked keiro DSL and evolution gate, against language 4. *The widest unblocker
  in the portfolio:* gates 24, 25, 26, 27, 35, 50, 51. Start it the day A1 lands.
- **Plan 18** — atomic offsets, inbox, and enqueue in one boundary. Independent of everything in
  stage C; nothing about it changes under `shibuya-core 0.9`.
- **Plan 21** — database-backed sink permission grants. No upstream gate.
- **Plan 43** — practice-review contracts. Contract-only, no dependencies.
- **Plan 49** — attestation vocabulary, updated to cite `Baikai.Evidence`. Contract-only. Worth
  landing early for the same reason as before: nine plans (12, 14, 22, 28, 33, 35, 39, 43, 44, 48)
  are each about to name an agent version, a repository revision, a correlation id, a review id, or
  a tool-catalog digest, and landing the vocabulary first turns nine future reconciliations into
  nine citations.
- **Plan 28 M2–M4** — metrics and tracing. M1 landed 2026-08-05. M3's HTTP trace propagation waits
  for plan 22's `postJSONWithHeaders`; M2 and M4 do not.
- **Cleanup batch** — plans 8, 16, and 37 M3 / 38 M4 (one Cabal package cycle to break, shared by
  the last two). Cheap, and 38's remainder is the only thing plan 31 waits on.
- **Plan 13's live smoke** — needs a credential, not engineering time. It is a precondition of plan
  52's positive conformance case, so unblock it now rather than at stage F.

### Stage C — Core semantics · after B, and after A3's releases where noted

- **Plan 17** — ⏳ *hold for `keiro 0.12` → `shibuya-core 0.9`.* Highest rework risk if started early.
  If A3 slips more than a couple of weeks, implement it against 0.8 with the code taxonomy isolated
  behind one module so the 0.9 swap is mechanical.
- **Plan 24** — versioning discipline. After 39. Build the mechanism; skip the in-flight proofs.
- **Plan 50** — fail-closed profile resolution and run pinning. After 39 + 49. It adds a journaled
  workflow step, which is precisely what 39 governs.
- **Plan 19 M2–M4** — sink delivery truth. After 16 ✅ and 28 M1 ✅. **M1 stays blocked** on keiro
  `PublishRejected`.
- **Plan 12 M1–M2** — the `mcpServers` declaration and its validation. M3–M5 stay upstream-gated.
- **Plan 29 (local half)** — health and liveness. The worker probe waits on Shibuya IR-1, which
  `shibuya-core 0.9` may partly address; re-check when A3 lands.

### Stage D — Shared seams · after C

- **Plan 20** — explicit trigger routing and catch-up policy. After 17 + 18. Releases 30 and 33.
- **Plan 22** — outbound authentication. After 19 (terminal delivery taxonomy) and preferably after
  13 ✅ / 16 ✅. Sole owner of `HttpEnv`, `TokenSource`, `postJSONWithHeaders`; releases 14, 28 M3,
  32, 52.
- **Plans 25, 26** — replay-safe flow memory, conversation lifecycle. After 24 + 39.
- **Plans 30, 33** — operator CLI, agent schema evolution. Both after 20's `AgentLoadReport`.
- **Plan 51** — run evidence and compliance roll-up. After 49 + 50 + 39. Its real-evidence
  milestone additionally wants A3's kioku release for `baikai 0.5`.

### Stage E — Feature completion · after D

- **Plan 23** — agent lifecycle with Meibo principals. After 30 + 33, preferably 21.
- **Plan 27** — consolidate sink intent and run lifecycle. After 19 + 24 + 28. Consolidate freely.
- **Plan 14** — approval and human-in-the-loop. After 17 + 22.
- **Plan 32** — channel egress through Kanmon. After 19 + 22, preferably 21 + 27.
- **Plan 34** — memory lifecycle. Distillation and retention can start earlier; the shared-scope
  milestone waits for 33. Kioku IR-2 (indexed sessions, bounded reads) gates part of it.
- **Plan 35** — delegation as a declared capability. After 24 + 33 + 39.
- **Plan 48** — repository agent harness, rewritten on `Baikai.Agent`. Needs A3's kioku release.
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
A1 (53) → 39 → 24 → 25/26/27/35 → 42
                 ↘ 50 → 51 → 52
17 waits on keiro 0.12 → 20 → 30/33 → 23, 40→41→42
18 ────────────────────↗
19 M2–M4 → 22 → 14, 32, 28 M3, 52
                                    → 31
```

The long pole is **A1 → 39 → 24 → 35 → 42** on the feature side and **A1 → 39 → 50 → 51 → 52** on
the attestation side. Both start at plan 53, which is startable today. Nothing else on the critical
path waits on another repository except plan 17 (keiro 0.12) and plan 19 M1 (keiro
`PublishRejected`).

If a v1 cut smaller than "all 39 plans" becomes attractive, the natural line is **after stage D**:
that yields a service with a real provider, honest sinks, correct delivery semantics, checked
durable topology, authenticated egress, operator CLI, health, and observability. Stage E adds
platform features and stage F adds two whole initiatives (router agents, practice reviews) plus
packaging. Cutting there would defer MasterPlans 8, 9, and 10 rather than shipping them
half-built.


## Upstream gates, current status

| Gate | Blocks | Status 2026-08-10 |
|---|---|---|
| Kioku IR-1 | plan 47 | ✅ Closed. |
| **kioku 0.3.0.0** | **plan 53 M0** | ✅ **Closed 2026-08-05 — the unblock this revision exists to report.** |
| **Baikai IR-3** | plans 51, 52 | ✅ **Delivered as `Baikai.Evidence` in baikai 0.5.0.0.** Now gated only on a kioku release admitting it. |
| keiro 0.12 | plan 17; improves 19, 29 | 🔜 Staged in keiro's `Unreleased`. Request it. |
| kioku admitting `baikai ^>=0.5` | plans 48, 51, 52 | ⏳ Not started. Request it. |
| Keiro IR-3 / keiro plan 165 | plan 19 M1 | ❌ 0 of 4 milestones; `PublishRejected` is in no keiro source. |
| Kioku IR-2 | plans 26, 34 | ❌ Proposed. |
| Shibuya IR-1 | plan 29's worker probe | ❌ Proposed. Re-check against `shibuya-core 0.9`. |
| Baikai IR-2 | plan 12 M3–M5 | ❌ No `Baikai.Mcp.*` in baikai 0.5. |
| Shikumi IR-1 | plan 12 | ❌ No MCP adapter in the shikumi package set. |
| Kikan-En IR-3 | plan 12 | ❌ Proposed. |
| Kikan IR-5 | plans 44, 46, 52 | ❌ Proposed. |
| Kikan IR-6 | plan 52 | ❌ Proposed. Scope shrinks: it ratifies the envelope, not the encoder. |

The pattern to keep using where a contract is pending: define a reader or source record of function
fields, satisfy it with a stub plus fixtures in tests, and let the live client replace the stub.
Plan 44 does this for the content plane; plan 51 does it for call evidence — and plan 51 can now
retire its stub.


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

**Five plans belong to no MasterPlan.** Plans 7, 9, 10, 11 (complete) and plan 48 (open,
unregistered). Register 48 under MasterPlan 7 or as its own initiative when it is rewritten on
`Baikai.Agent`.

**Stale package placement.** Plans 43 and 33, and every MasterPlan-3 child's Context section, name
pre-split paths. Re-point each before implementation; MasterPlan 3 holds the corrected map.
