---
id: 4
slug: identity-and-trust-grants-outbound-auth-and-agent-lifecycle-control
title: "Identity and Trust: Grants, Outbound Auth, and Agent Lifecycle Control"
kind: master-plan
created_at: 2026-07-08T20:13:36Z
intention: "intention_01kx1typzbe9dtqnk49t6d5q5w"
---

# Identity and Trust: Grants, Outbound Auth, and Agent Lifecycle Control

This MasterPlan is a living document. The sections Progress, Surprises & Discoveries,
Decision Log, and Outcomes & Retrospective must be kept up to date as work proceeds.


## Vision & Scope

Shikigami runs declared agents (Dhall manifests in `agents/`) whose outputs flow to other services through permission-gated sinks — kawa digests, kizashi signals, rei actions, danwa conversations. The architecture spec (`docs/initial-spec.md`, contract C11, lines 645-657 and 889-900) says identity and trust bound every one of those flows: each sink dispatch passes an explicit per-agent grant, outbound calls carry shomei-issued credentials, and agents are directory principals with a lifecycle. Today essentially none of that exists. The permission gate is a five-agent allow-list compiled into the binary (`shikigami-core/src/Shikigami/Sink/Permission.hs:53-71`); outbound HTTP sends no credentials at all and builds a fresh connection manager per request (`shikigami-core/src/Shikigami/Sink/Http.hs:31-51`); agent identity is an unverified name string; a broken manifest is skipped silently; and the only way to stop a deployed agent is deleting its file and restarting every process.

After this initiative: an operator grants or revokes an agent's access to any sink kind at runtime with `shikigami grants grant|revoke` against a Postgres grant table, effective on the next dispatch with no rebuild; every sink client sends `Authorization: Bearer <token>` from per-sink configured credentials (static today, shomei service tokens later behind the same `TokenSource` interface), through a shared connection manager with explicit timeouts, with secrets that cannot appear in logs or serialized state; and every agent joins a directory principal (`agent_…` id) whose `paused` lifecycle is a portfolio-wide kill switch — pausing stops trigger fires and sink dispatch within one cache refresh, skips are durably recorded, manifest load failures become queryable state, and kioku sessions attribute runs to principal ids.

In scope: the grant table + CLI, the authenticated HTTP layer + token-enforcing stub-kawa, and the shikigami side of the meibo lifecycle consult (built against a stub directory source, since meibo ships no consumable packages yet — verified 2026-07-08). Explicitly out of scope: shomei's scoped service-token issuance (IR-2 belongs to the shomei repo; we only design the consuming seam), meibo itself and its `meibo.v1` topic, the shikigami HTTP API, the kikan-en `checkAction` swap, cost capture on sessions (all excluded by the improvement request `docs/improvement-requests/consult-meibo-agent-lifecycle.md`), the channel-egress sink (owned by `docs/plans/32-channel-egress-sink-through-kanmon.md`, which consumes this initiative's artifacts), and TLS for outbound HTTP (no real HTTPS endpoint exists yet; noted as follow-up).


## Decomposition Strategy

The initiative decomposes along the three independent trust questions the runtime must answer, each with its own artifact, failure semantics, and verification story:

1. May this agent use this sink? — authorization state (a database table, a CLI, a fail-closed gate). Verifiable alone: grant/revoke at runtime and watch dispatch outcomes flip.
2. Can shikigami prove itself to the service it calls? — outbound credentials (an HTTP layer, token configuration, a token-enforcing stub). Verifiable alone: stub-kawa returns 401 without the token and 200 with it.
3. Does this agent exist and is it allowed to run at all? — identity and lifecycle (a directory view, a kill switch, recorded load state, principal attribution). Verifiable alone: pause in the stub directory and watch fires stop.

Alternatives considered and rejected: one monolithic "identity plan" (it would span three unrelated failure-semantics decisions — fail-closed grants, fail-closed missing tokens, fail-open lifecycle — and more than ten files across unrelated modules; exactly the unwieldy-single-ExecPlan indicator in the MasterPlan spec); splitting the lifecycle work into "kill switch" and "principal join" plans (rejected because both consume the same `DirectoryHandle` machinery and the same migration, and neither is meaningfully demonstrable without the other's tables); folding the grant table into the meibo plan because both concern "who is the agent" (rejected: grants must ship and be testable while agent identity is still an unverified name — the nullable `principal_id` column is the deliberate seam between them).

Boundaries minimize coupling but not to zero: plans 21, 22, and 23 all thread a new field through the same dependency records (`WorkerEnv` → `AgentRunDeps` → `SinkContext`, plus `SinkEnv`); that shared touchpoint is documented under Integration Points rather than forced into one plan, because the fields are independent values with independent semantics.


## Exec-Plan Registry

| # | Title | Path | Hard Deps | Soft Deps | Status |
|---|-------|------|-----------|-----------|--------|
| EP-1 | Database-backed sink permission grants | docs/plans/21-database-backed-sink-permission-grants.md | None | None | Not Started |
| EP-2 | Outbound authentication for sink clients | docs/plans/22-outbound-authentication-for-sink-clients.md | None | cross-MP: plans 13, 16 (MasterPlan 2) | Not Started |
| EP-3 | Agent lifecycle control with meibo principals | docs/plans/23-agent-lifecycle-control-with-meibo-principals.md | cross-MP: plans 30 (MasterPlan 6), 33 (MasterPlan 7) | EP-1; cross-MP: plan 20 (MasterPlan 3) | Not Started |

Status values: Not Started, In Progress, Complete, Cancelled.
Hard Deps and Soft Deps reference other rows by their # prefix (e.g., EP-1, EP-3).


## Dependency Graph

EP-1 (grants) and EP-2 (outbound auth) are independent inside this MasterPlan and can proceed in parallel: EP-1 changes what the permission gate consults (a table instead of a compiled map), EP-2 changes what the sink clients send (headers, manager, timeouts). EP-2 has soft cross-MasterPlan ordering on plans 13 and 16: plan 13 defines the typed environment resolver, and plan 16 settles the sink-client/request shapes that authentication wraps. They touch different functions — the gate call sites versus the HTTP/client functions — and meet only in the record constructors listed under Integration Points, which is a textual-merge concern, not a semantic one.

EP-3 soft-depends on EP-1. The dependency is soft because only the `agents sync` grant backfill consumes EP-1's nullable `principal_id` column. EP-3 has two cross-MasterPlan hard dependencies. Plan 30 must first establish the `agents` operator command group, which EP-3 extends with principal/lifecycle columns and `sync`; plan 33 must first define the optional `identity.principal` declaration, which EP-3 treats as authoritative instead of shipping a temporary name-only join. Plan 20 is a soft/transitive ordering preference: it defines the shared load-report seam consumed by both hard dependencies.

Therefore EP-1 and EP-2 may start immediately, while EP-3 starts after plans 30 and 33. At portfolio level the preferred chain is plan 13/16 → plan 22 → plans 14/28/32 for outbound HTTP, and plan 20 → plans 30/33 → plan 23 for agent loading, inspection, and lifecycle. This is the MasterPlan-4 slice of the canonical MP-2 through MP-7 waves recorded in MasterPlan 2.


## Integration Points

1. The dependency-record threading path (`Shikigami.Worker.WorkerEnv` at `shikigami-core/src/Shikigami/Worker.hs:55-63` → `Shikigami.Agent.Workflow.AgentRunDeps` at `Workflow.hs:79-89` → `Shikigami.Sink.Types.SinkContext` at `Types.hs:29-38`, plus `Shikigami.Flow.Capability.SinkEnv` and `Shikigami.Agent.Conversation.ConversationEnv`). Involved: EP-1 (adds `grants :: GrantSource`), EP-2 (adds `sinkHttp :: SinkHttp`), EP-3 (adds `directory :: DirectoryHandle`). Whichever plan lands first establishes the pattern (a strict field on each record, populated once at CLI boot inside `withStore`); later plans add their field in the same style. Conflicts are constructor-record merges only; every construction site is found by the compiler.

2. `shikigami.sink_grants.principal_id` (nullable TEXT column). Defined by EP-1's migration; consumed by EP-3's `shikigami agents sync`, which backfills it from the directory join. EP-1 must not constrain it (no FK, no NOT NULL); EP-3 must not alter the table.

3. The `shikigami` Postgres schema. Both EP-1 and EP-3 migrations begin `CREATE SCHEMA IF NOT EXISTS shikigami;` so they apply cleanly in either order. Both must schema-qualify all runtime SQL (the kiroku-store pool's `search_path` is `kiroku`). The test-support schema list already includes `shikigami` (`shikigami-migrations/test-support/Shikigami/Migrations/TestSupport.hs:17`), so neither plan touches test support.

4. `SinkKind` / `sinkKindText` strings (`shikigami-core/src/Shikigami/Sink/Permission.hs:25-49`). EP-1 freezes the five strings — including the reserved `ChannelEgress` (Permission.hs:30) — as the `sink_kind` CHECK constraint. External consumer: `docs/plans/32-channel-egress-sink-through-kanmon.md` (MasterPlan 7) adds the channel-egress sink variant and expects to `grants grant <agent> ChannelEgress` with no schema change, and must route its kanmon client through EP-2's `HttpEnv`/`TokenSource` layer rather than raw http-client.

5. Secret-configuration idiom. EP-2 reads per-sink tokens from `SHIKIGAMI_{KAWA,KIZASHI,DANWA}_TOKEN` env vars in the CLI command modules (the existing `PG_CONNECTION_STRING` pattern). External integration: `docs/plans/13-wire-a-real-model-provider-into-behavior-runs.md` (MasterPlan 2) defines the typed resolver and loud redacted description first; EP-2 follows it.

6. Manifest-load failure surfacing. Plan 20 owns the canonical `Shikigami.Agent.Loader.loadAgentsReport` and loud/strict loading behavior. Plan 30 consumes that report for `agents list`; plan 33 adds enabled-agent selection; EP-3 consumes the same report to persist `shikigami.agent_load_state` and extends the existing command with principal/lifecycle state and `sync`. EP-3 does not consolidate or reimplement the loader.

7. `SinkOutcome` (`shikigami-core/src/Shikigami/Sink/Types.hs:42-48`) and the outbox publisher's outcome mapping (`Workflow.hs:581-583`). EP-1 relies on the existing `DeniedOutcome` semantics (recorded, non-crashing, non-retrying); EP-3 adds a `SkippedLifecycle` constructor with identical publisher treatment. If EP-1 is in flight when EP-3 lands, both touch the same `case` arms — coordinate the merge.

8. The declared-identity field. `docs/plans/33-agent-schema-evolution-identity-memory-policy-and-enablement.md` (MasterPlan 7) defines `identity : Optional { principal : Text }` before EP-3 begins. EP-3 resolves a declared `identity.principal` directly and falls back to name-based directory lookup only when the optional field is absent, preserving compatibility with existing manifests without a later rewrite.

9. Authenticated HTTP request layer. EP-2 is the sole owner of `HttpEnv`, `TokenSource`, and `postJSONWithHeaders`. Plan 14 uses it for approval notifications, plan 28 uses it for `traceparent`, and plan 32 extends `SinkCredentials`/`SinkHttp` with kanmon rather than introducing another header helper or serializable token field.


## Progress

- [ ] EP-1 M1: `shikigami.sink_grants` migration written, applied, seeded with the five compiled-in defaults.
- [ ] EP-1 M2: `GrantSource` seam; all four gate sites (Workflow.hs:423/493, SinkOutbox.hs:101, Sink.hs:42) read it; worker boots `DbGrants`.
- [ ] EP-1 M3: `shikigami grants list|grant|revoke` CLI.
- [ ] EP-1 M4: real-Postgres tests incl. revocation between enqueue and publish; `cabal test all` green.
- [ ] EP-2 M1: shared manager + timeouts; auth-aware `postJSON`; kawa/kizashi clients rewired.
- [ ] EP-2 M2: `SHIKIGAMI_*_TOKEN` credential config threaded boot → dispatch; redacted logging.
- [ ] EP-2 M3: authenticated danwa client path (boot-time `ClientEnv`, token-injecting manager).
- [ ] EP-2 M4: `stub-kawa --require-token` + header/401/redaction tests.
- [ ] EP-2 M5: shomei `TokenSource` seam documented; static implementation shipped.
- [ ] EP-3 M1: `Shikigami.Directory` cached view + file stub source + unit tests.
- [ ] EP-3 M2: `agent_load_state`/`run_skips` migrations; persist plan 20's load report; `broken.dhall` visible.
- [ ] EP-3 M3: lifecycle kill switch at all trigger/drain/sink sites; fail-open; recorded skips; tests.
- [ ] EP-3 M4: principal attribution on sessions; `agents list|sync`; `sink_grants.principal_id` backfill.
- [ ] Initiative: end-to-end demo — pause a granted, authenticated agent; unpause; revoke; re-grant — all without restarts.


## Surprises & Discoveries

- Meibo is registered in mori (`shinzui/meibo`, path `/Users/shinzui/Keikaku/bokuno/meibo-project/meibo`) but ships zero packages — only docs and agent manifests. EP-3 is therefore stub-first against a file-backed `DirectorySource`; the improvement request anticipated exactly this. (2026-07-08)
- Shomei already models capability scopes (`AuthClaims.scopes`, `shomei-core/src/Shomei/Domain/Claims.hs:38-52`) and can sign tokens (`shomei-jwt/src/Shomei/Jwt/Sign.hs:125`), but its only issuance path hardcodes `scopes = Set.empty` (`shomei-core/src/Shomei/Workflow/Session.hs:52`) — confirming the spec's IR-2 gap and the static-token-first decision in EP-2. (2026-07-08)
- The permission gate already runs twice per sink (enqueue time and publish time), and the sink-intent machinery is duplicated between `Shikigami.Agent.Workflow` and `Shikigami.Flow.SinkOutbox` (a `docs/plans/27-…` consolidation target) — so EP-1 threads through four sites, not one, and EP-3 mirrors the same four. (2026-07-08)
- `danwa-client`'s `runDanwa` allocates a fresh unauthenticated `Manager` per call (`/Users/shinzui/Keikaku/bokuno/danwa/danwa-client/src/Danwa/Client.hs:99-103`), so EP-2 must bypass it with a shikigami-owned `ClientEnv` instead of merely adding a header. (2026-07-08)


## Decision Log

- Decision: Decompose into exactly three plans along the three trust questions (authorization state / outbound credentials / identity & lifecycle), with EP-1 ∥ EP-2, EP-3 soft-depending on EP-1, and EP-3 hard-depending cross-MasterPlan on plans 30 and 33.
  Rationale: Each question has distinct failure semantics (fail-closed / fail-closed / fail-open), a distinct artifact, and an independent demonstration; the cross-MasterPlan edges ensure lifecycle work extends the existing operator command and consumes the declared principal field instead of creating temporary alternatives.
  Date: 2026-07-22

- Decision: The seam between EP-1 and EP-3 is a nullable `principal_id` column on `shikigami.sink_grants`, created by EP-1, populated by EP-3, constrained by neither.
  Rationale: Grants must be operable while `AgentIdentity` is still an unverified name (Permission.hs:35); re-keying to verified principals later must not require a schema migration. Matches the spec's Open Question 6 (`docs/initial-spec.md:947-948`).
  Date: 2026-07-08

- Decision: Divergent failure semantics across the three gates are deliberate and recorded here as initiative policy: grant lookups fail closed (deny on DB error), missing/failed token fetches fail closed (no anonymous fallback on an authenticated sink), lifecycle consults fail open (last-known view; unknown agents allowed).
  Rationale: The first two guard trust boundaries (C11, IR-2); the third is an operational switch whose outage must not silence the fleet (C14 change rule, quoted in the improvement request).
  Date: 2026-07-08

- Decision: Adopt existing sibling-plan boundaries rather than duplicating: plan 20 owns loud manifest-failure logging (EP-3 adds durable state on top of its shared load report), plan 13 defines the secret-config idiom that EP-2 follows, plan 32 consumes EP-1's `ChannelEgress` kind and EP-2's HTTP layer, and plan 27 later consolidates the duplicated sink-intent machinery that EP-1/EP-3 thread through.
  Rationale: Prevents the two silent-conflict classes the MasterPlan spec warns about — duplicate work and incompatible shared-interface assumptions — by naming the owner of each shared artifact now.
  Date: 2026-07-08

- Decision: Author all three plans against verified code as of commit `0c164b7` (file:line citations throughout); build/test commands are `cabal build all` / `cabal test all` under `nix develop`, migrations via `just new-migration` / `just migrate` only.
  Rationale: Self-containment for a novice implementer; the Justfile's embed-touch hack (Justfile:20-27) makes hand-created migration files a known footgun.
  Date: 2026-07-08
- Decision: Plan 22 owns the sole authenticated, header-capable HTTP layer and follows
  plan 13's configuration convention; plans 14, 28, and 32 consume or extend it.
  Rationale: the previous child plans proposed incompatible header helpers and one raw
  approval path. Central ownership keeps tokens redacted and out of serialized sink
  configs while allowing auth, tracing, and kanmon headers to compose.
  Date: 2026-07-22
- Decision: Loader and agent-command ownership follows plan 20 → plans 30/33 → plan
  23. Plan 20 reports loads, plan 33 filters enabled agents, plan 30 owns the operator
  command, and plan 23 persists/annotates the result.
  Rationale: four plans previously described independent directory walks or command
  creation. A single chain prevents duplicate helpers and CLI parser conflicts.
  Date: 2026-07-22


## Outcomes & Retrospective

(To be filled during and after implementation. Compare against the Vision: runtime-managed grants, authenticated outbound calls, and a working lifecycle kill switch with principal attribution — demonstrated end to end by the final Progress item.)


## Revision Notes

- 2026-07-08: Cross-plan consistency pass after initial authoring — added Integration Point 8 (the declared-identity field seam with MasterPlan 7's plan 33) and the matching touchpoint in plan 23. This initial revision allowed either landing order; the 2026-07-22 revision below supersedes that ordering and places plan 33 first to avoid a later identity-lookup rewrite.
- 2026-07-22: Portfolio-order revision — made plans 30 and 33 prerequisites of plan
  23, assigned the loader chain to plan 20 → plans 30/33 → plan 23, and made plan 22
  the shared HTTP owner consumed by plans 14, 28, and 32. This removes duplicate loader,
  CLI, and HTTP implementations from the MP-2 through MP-7 execution path.
