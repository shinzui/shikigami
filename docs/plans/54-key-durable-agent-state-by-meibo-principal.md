---
id: 54
slug: key-durable-agent-state-by-meibo-principal
title: "Key durable agent state by Meibo principal"
kind: exec-plan
created_at: 2026-08-19T04:20:16Z
intention: "intention_01m0c3z1v8evbv3qpv0dncc05e"
master_plan: "docs/masterplans/4-identity-and-trust-grants-outbound-auth-and-agent-lifecycle-control.md"
---

# Key durable agent state by Meibo principal

This ExecPlan is a living document. The sections Progress, Surprises & Discoveries,
Decision Log, and Outcomes & Retrospective must be kept up to date as work proceeds.
If durable project context changes, update or create ADRs in docs/adr/ in the same change.


## Purpose / Big Picture

Today an agent in Shikigami *is* the name written in its Dhall declaration file. That one string
does five different jobs at once: it addresses the agent, it names the memory bucket the agent
recalls from, it is the subject of the database row that grants the agent permission to talk to
the outside world, it appears in logs, and it is what a downstream system sees as the author of
anything the agent produced. Rename the declaration and the agent silently becomes a different
agent — it recalls nothing, because its memories are filed under the old string.

After this plan, an agent is identified by an immutable **Meibo principal id** — a value that
looks like `agent_01jf2m0c3z1v8evbv3qpv0dncc`, minted once by the organizational directory and
never reused. The declaration name and the Meibo handle become ways to *find* an agent; the
principal id is what the agent *is*. Everything durable is filed under the principal: memory
scopes, session lineage, permission grants, run records, and the author field on outbound
messages.

What someone can do afterwards that they cannot do now: **rename an agent and have it stay the
same agent.** Concretely — register an agent in Meibo, run it so it records some memories, change
its display name in Meibo, restart Shikigami, run it again, and watch it recall everything it
learned under the old name. That is the acceptance demonstration, and Milestone 6 walks through
it command by command.

This plan implements the improvement request at
`docs/improvement-requests/key-agent-continuity-by-meibo-principal.md` (`IR-9`). Read that file
first; its numbered requirements govern this plan and each milestone below names which one it
discharges.

There is a second, quieter payoff. Shikigami currently writes memory through a set of Kioku
functions that Kioku has marked deprecated, because it has no real principal to supply. Once
principals exist, the write path moves to Kioku's supported surface and about twenty-four
deprecation warnings disappear. That is not the reason to do this work, but it is why this plan —
and not some later cleanup — is where that debt is paid.


## Progress

Use a checklist to summarize granular steps. Every stopping point must be documented here,
even if it requires splitting a partially completed task into two ("done" vs. "remaining").
This section must always reflect the actual current state of the work.

- [ ] M0 (gate): `docs/plans/23-agent-lifecycle-control-with-meibo-principals.md` has landed, so
      `Shikigami.Directory` exists and can resolve a declaration name to a Meibo principal.
- [ ] M0 (gate): Meibo is pinnable from `cabal.project`. It has no Hackage release and no git
      tags as of 2026-08-19, so this is a `source-repository-package` commit pin.
- [ ] M1: `Shikigami.Agent.Principal` — the principal newtype, its Kioku conversions, and the
      admission-time resolution seam. Unit tests.
- [ ] M1: `RunJob` carries a resolved `principalId`; resumed workflows and delegated children
      reuse the journaled value rather than re-resolving.
- [ ] M2: `Shikigami.Memory.Scope.agentScope` and `Shikigami.Memory.Access` re-keyed on the
      principal.
- [ ] M2: the Kioku write path moved from the deprecated wrappers to the `*WithContext` surface;
      `cabal build all` emits no `-Wdeprecations` warnings from `Kioku.Session` or `Kioku.Memory`.
- [ ] M3: `shikigami.sink_grants` keyed by `principal_id`; grant lookup and the permission gate
      resolve by principal.
- [ ] M4: outbound attribution — the principal id travels on Danwa messages and on every sink
      payload with an author or actor field.
- [ ] M5: `shikigami-migrate reconcile-principals` — the idempotent legacy-history migration, with
      an ambiguity report that refuses to guess.
- [ ] M6: fail-closed behavior when identity is required; the directory-disabled development mode
      preserved and visibly marked.
- [ ] M6: the rename demonstration captured as a transcript in this plan; `cabal test all` green.


## Surprises & Discoveries

Document unexpected behaviors, bugs, optimizations, or insights discovered during
implementation. Provide concise evidence.

**A Meibo principal id is directly usable as a Kioku principal reference, with no encoding.**
This is worth knowing before Milestone 2, because the obvious worry is that two identifier
systems will need a mapping table. They do not. Kioku's `mkPrincipalRef`
(`kioku-api/src/Kioku/Api/Access/Internal.hs`) rejects exactly two characters, `:` and `#`, and
Kioku's scope encoding additionally reserves `%` and `/`. Meibo renders a principal through
`principalIdText` (`meibo-api/src/Meibo/Api/Id.hs`) as a KindID — a lowercase kind prefix, an
underscore, and base32 — for example `agent_01jf2m0c3z1v8evbv3qpv0dncc`. None of the four
reserved characters can appear. So a principal id passes into both `mkPrincipalRef` and
`ScopeEntity` verbatim.

**Meibo has no release to depend on.** Checked 2026-08-19: `meibo-core`, `meibo-client`, and
`meibo-api` are absent from Hackage, and the repository at
`mori://shinzui/meibo` carries no git tags at all. It is real, actively developed Haskell — the
client surface at `meibo-client/src/Meibo/Client.hs` already exports `principalByHandle`,
`getPrincipal`, `searchPrincipals`, `pausePrincipal`, and `reactivatePrincipal` — but consuming
it means a commit pin. `docs/dependency-cohort.md` permits exactly this: a
`source-repository-package` stanza is admissible for a package with no Hackage release, provided
the stanza carries a comment saying which case it is and when it retires.

(Further entries to be added during implementation.)


## Decision Log

Record every decision made while working on the plan.

- Decision: Scope this plan to *re-keying durable state*, and leave the directory itself to
  plan 23.
  Rationale: `IR-9` is explicitly a companion to `IR-1`
  (`docs/improvement-requests/consult-meibo-agent-lifecycle.md`), and `IR-1` already has an
  implementing plan — `docs/plans/23-agent-lifecycle-control-with-meibo-principals.md` — whose
  Milestone 1 builds the cached Meibo view and whose Milestone 4 makes Kioku sessions record
  principal ids. Rebuilding any of that here would produce two directory caches. This plan
  therefore *consumes* `Shikigami.Directory` and changes what the rest of the system files things
  under.
  Date: 2026-08-19

- Decision: Do not preserve the existing name-keyed data in place; migrate it explicitly and
  allow the migration to refuse.
  Rationale: `IR-9` requirement 3 asks for an idempotent reconciliation that "moves or aliases
  existing recall scope without duplicating memories, and reports missing or ambiguous mappings",
  and states that "ambiguous history is never silently assigned". A migration that guessed would
  merge two agents' memories on a name collision, which is unrecoverable in an append-only event
  store. Milestone 5 therefore builds a command that reports and exits non-zero rather than
  resolving ambiguity itself.
  Date: 2026-08-19

- Decision: Change `RunJob`'s wire shape rather than carrying the principal beside it.
  Rationale: `RunJob` (`shikigami-core/src/Shikigami/Agent/RunJob.hs`) is the value enqueued into
  PGMQ and journaled by the durable workflow, and `IR-9` requirement 1 wants the principal
  journaled *with the run request* so that a resumed workflow reuses it. A side channel would not
  survive replay. `docs/architecture/implementation-order.md` records that Shikigami has no users,
  no in-flight workflows, and no external wire consumers, so no compatibility shim is owed for the
  shape change.
  Date: 2026-08-19

- Decision: Pay off the Kioku deprecation debt inside this plan rather than as separate work.
  Rationale: Kioku's supported write surface (`startWithContext`, `recordWithContext`, and
  siblings) requires a `MemoryAccessContext`, and minting one requires a real principal reference.
  Until this plan there is no such principal, which is why
  `shikigami-core/src/Shikigami/Memory/Access.hs` currently mints a self-asserted reference and the
  call sites use the deprecated wrappers. The moment Milestone 1 lands, the blocker is gone and
  the migration is a mechanical follow-on in the same files. Splitting it would mean touching every
  call site twice.
  Date: 2026-08-19


## Outcomes & Retrospective

Summarize outcomes, gaps, and lessons learned at major milestones or at completion.
Compare the result against the original purpose. Before marking the plan complete,
distill durable project context from the Decision Log, Surprises & Discoveries, and
this section into docs/adr/. Keep task-local execution details here.

(To be filled during and after implementation.)


## Context and Orientation

### What this repository is

Shikigami is a Haskell service that runs *declared agents*. An agent is described by a Dhall file
under `agents/` — a plain-text configuration file naming what triggers the agent, what behavior it
runs, and which *sinks* (outbound integrations such as a chat message or a webhook) it may use.
The runtime loads those declarations, waits for triggers, runs the declared behavior, records what
happened, and dispatches to sinks.

The repository is a Cabal multi-package project with six packages:
`shikigami-core` (domain logic and workflows), `shikigami-api` (public HTTP contract types),
`shikigami-client`, `shikigami-server`, `shikigami-workers` (the long-running processes), and
`shikigami-migrations` (database schema evolution).

**Every build and test command must run inside the Nix development shell.** A bare `cabal build`
compiles and then fails at link time with `ld: library not found for -lrdkafka`. The shell is
entered per-command with `nix develop -c <command>` from the repository root.

### The five jobs the agent name currently does

Search the tree for the declaration name and you find it acting as an identity in five places.
All five are what this plan changes.

The first is the **memory scope**. `shikigami-core/src/Shikigami/Memory/Scope.hs` defines

```haskell
agentScope :: Text -> MemoryScope
agentScope agentName = ScopeEntity shikigamiNamespace (ScopeKind "agent") agentName
```

A *memory scope* is Kioku's name for a bucket of remembered facts. `ScopeEntity` takes a
namespace, a kind, and an entity identifier; today the entity identifier is the declaration name,
so every memory an agent records and every memory it recalls is filed under that string. There are
twenty references to `agentScope` across `shikigami-core`.

The second is the **recorded actor**. `shikigami-core/src/Shikigami/Memory/Access.hs` answers two
questions Kioku asks of every write: which memory space it belongs to, and who acted. It currently
answers the second with a principal reference this service mints for itself,
`shikigami.agent.<name>`, because there is no directory to ask. Its own documentation names this
plan as the point at which that changes.

The third is the **grant subject**. The table `shikigami.sink_grants`, created by
`shikigami-migrations/sql-migrations/2026-08-06-04-02-23-sink-grants.sql`, has primary key
`(agent_name, sink_kind)`. It already carries a nullable `principal_id TEXT` column, added in
anticipation of this work. `shikigami-core/src/Shikigami/Sink/GrantStore.hs` looks grants up by
`agent_name`.

The fourth is the **run request**. `shikigami-core/src/Shikigami/Agent/RunJob.hs` defines the
value enqueued for execution:

```haskell
data RunJob = RunJob
  { agentName :: !Text,
    triggerKind :: !TriggerKind,
    occurredAt :: !UTCTime,
    triggerPayload :: !Value,
    idempotencyKey :: !Text,
    parentSessionId :: !(Maybe Text),
    parentRunWorkflowId :: !(Maybe Text),
    delegationDepth :: !(Maybe Int)
  }
```

The fifth is **outbound authorship**. `shikigami-core/src/Shikigami/Sink/Danwa.hs` posts an
agent's output into a conversation, and `shikigami-core/src/Shikigami/Integration/Danwa.hs`
models the inbound message with an `author :: !Text` field.

### What Meibo is

Meibo (名簿, "roster") is the platform's organizational directory, ratified by the architecture
repository as contract C14. It holds every *principal* — a person, agent, team, role, service,
connector, or organization — with an immutable id, a mutable display name and profile, a stable
`@handle`, an owner, and a lifecycle of `active`, `paused`, or `deactivated`. For agents, `paused`
is the portfolio-wide kill switch.

The canonical project reference is `mori://shinzui/meibo`. Its principal id type lives at
`meibo-api/src/Meibo/Api/Id.hs` and renders through `principalIdText`; its HTTP client is
`meibo-client/src/Meibo/Client.hs`, which exports `principalByHandle` and `getPrincipal` among
others. **Meibo has no Hackage release and no git tags as of 2026-08-19**, so consuming it means a
`source-repository-package` commit pin in `cabal.project`.

### What plan 23 delivers, and why this plan waits for it

`docs/plans/23-agent-lifecycle-control-with-meibo-principals.md` implements the companion request
`IR-1`. Its Milestone 1 builds `Shikigami.Directory` — a locally cached view of Meibo, refreshed in
the background so that no request blocks on the directory. Its Milestone 3 adds the lifecycle kill
switch. Its Milestone 4 joins declarations to principals and records principal ids on Kioku
sessions.

That join is the thing this plan cannot do without: it is what turns a declaration name into an
`agent_…` id. This plan does not rebuild it. Milestone 0 is a gate that simply checks it exists.

### Relevant Architecture Decision Records

**This repository has no `docs/adr/` directory as of 2026-08-19.** There is therefore no local ADR
corpus to consult or cite, and the skill's profiled-OKF workflow does not apply here. Two upstream
decisions do govern the work and are cited by canonical handle rather than summarized second-hand:

- Kioku's record on attribution, `historical-attribution-is-marked-never-invented`, in
  `mori://shinzui/kioku`. It settles that Kioku's `KnownPrincipal` asserts a principal was
  *vouched for*, not that a *directory* did the vouching, and that the two remaining constructors
  — `LegacyPrincipal` and `UnattributedPrincipal` — describe history only and must never be
  written forward. This is why Milestone 2 supplies a real principal rather than reaching for a
  weaker marker.
- Kioku's record on memory-space partitioning, `the-aggregate-enforces-the-partition`, in the same
  project. It is the reason every Kioku write carries a memory space and every read takes one.

If durable decisions come out of this plan — and the identity rule "names locate, principals
identify" is a strong candidate — create `docs/adr/` and record them there during the distillation
pass described in Outcomes & Retrospective. Follow the skill's `ADR.md`: because no bundle exists
yet, establish a plain filesystem convention rather than inventing OKF frontmatter as an
incidental edit.

### The identity rule, stated once

Everything below follows from one sentence, taken from `IR-9`: **names and handles locate an
agent; the Meibo principal id identifies it.** When you are unsure whether some field should hold
a name or a principal, ask whether the field is used to *find* the agent (name or handle) or to
*remember something about* it (principal).


## Plan of Work

The work divides into seven milestones. Milestone 0 is a gate that writes no code. Milestones 1
through 4 re-key the live system, in dependency order: first the identity exists and travels with
the run, then memory, then grants, then outbound attribution. Milestone 5 migrates the data
already on disk. Milestone 6 makes the system fail closed and demonstrates the whole thing
end to end.


### Milestone 0 — Confirm the gate

This milestone produces no code. It exists because starting the rest without it wastes a full
implementation cycle.

Two conditions must hold. First,
`docs/plans/23-agent-lifecycle-control-with-meibo-principals.md` must be complete, so that a module
named `Shikigami.Directory` exists in `shikigami-core` and can answer "what principal does this
declaration name resolve to?" Check its Progress section, then confirm the module is present:

```bash
cd /Users/shinzui/Keikaku/bokuno/shikigami
ls shikigami-core/src/Shikigami/Directory.hs
```

Second, Meibo must be reachable as a dependency. Because it has no release, this means selecting a
commit and confirming that commit builds against the pinned cohort. If plan 23 already added the
pin, this is satisfied; read `cabal.project` and confirm a `source-repository-package` stanza
naming `https://github.com/shinzui/meibo.git`.

If either condition fails, stop and record the blocker in Surprises & Discoveries. Do not
implement against a stub directory; a stub would let every later milestone pass its tests while
the system as a whole cannot resolve an identity.


### Milestone 1 — The principal exists and travels with the run

At the end of this milestone a resolved principal id is a first-class value in the codebase, it is
attached to a run at the moment the run is admitted, and it survives workflow replay.

Create `shikigami-core/src/Shikigami/Agent/Principal.hs`. It defines a newtype over the rendered
principal text and the conversions into Kioku's two identifier types. Keeping this in one module
means the "is a Meibo principal id safe as a Kioku reference?" question is answered once:

```haskell
-- | An agent's immutable Meibo principal id, as rendered by @principalIdText@.
newtype AgentPrincipal = AgentPrincipal Text
  deriving stock (Eq, Ord, Show)

-- | The Kioku principal reference for this agent.
principalRefFor :: AgentPrincipal -> PrincipalRef

-- | The Kioku memory scope entity identifier for this agent.
principalScopeText :: AgentPrincipal -> Text
```

`principalRefFor` calls Kioku's `mkPrincipalRef`. That function returns `Either Text PrincipalRef`
and rejects the characters `:` and `#`. A Meibo principal id contains neither — see the first entry
in Surprises & Discoveries — so the `Left` branch is unreachable. Do not paper over it with a
partial pattern match: raise a clear error naming the offending value, so that if Meibo's id format
ever changes the failure names its cause.

Then thread the principal through admission. Add a field to `RunJob` in
`shikigami-core/src/Shikigami/Agent/RunJob.hs`:

```haskell
    principalId :: !AgentPrincipal,
```

`RunJob` derives `ToJSON` and `FromJSON` generically and is enqueued into PGMQ, so this changes the
enqueued JSON. That is intentional and safe: no in-flight work and no external consumer exists.
Give `AgentPrincipal` the matching `ToJSON`/`FromJSON` instances so the derivation still works.

Resolution happens exactly once, where the job is created, not where it is executed. The enqueue
path is `shikigami-core/src/Shikigami/Trigger/Enqueue.hs`; the three trigger sources that reach it
are `Shikigami/Trigger/Schedule.hs`, `Shikigami/Trigger/Stream.hs`, and the event consumer. Each
resolves the declaration name through `Shikigami.Directory` and fails the admission if resolution
fails — see Milestone 6 for exactly how it fails.

The execution path must then *read* the journaled value rather than resolving again.
`shikigami-core/src/Shikigami/Agent/Workflow.hs` is where a run executes; it currently derives
everything from `agentDeclName decl`. Wherever the principal is needed, take it from the `RunJob`.
This is the requirement that makes replay correct: a workflow that resumes after Meibo has changed
must behave as it did when admitted.

Delegated child runs, created in `shikigami-core/src/Shikigami/Agent/Delegate.hs`, resolve the
*child's* principal at the point of delegation and journal it on the child's `RunJob` the same way.

Acceptance for this milestone is a unit test asserting that a `RunJob` round-trips through JSON
with its principal intact, and a test that a resumed workflow uses the journaled principal even when
the directory is changed underneath it.


### Milestone 2 — Memory is keyed by principal

At the end of this milestone, everything Kioku stores for an agent is filed under the principal,
and Shikigami no longer calls any deprecated Kioku function.

Change `shikigami-core/src/Shikigami/Memory/Scope.hs` so `agentScope` takes an `AgentPrincipal`
instead of a `Text`:

```haskell
agentScope :: AgentPrincipal -> MemoryScope
agentScope principal =
  ScopeEntity shikigamiNamespace (ScopeKind "agent") (principalScopeText principal)
```

Leave `shikigamiNamespace` and `sharedScope` alone; the namespace is not per-agent and the shared
scope is deliberately cross-agent. The compiler will now find all twenty call sites. Each one
currently passes an agent name and must be given the run's principal instead — which is available,
because Milestone 1 put it on `RunJob`.

Then change `shikigami-core/src/Shikigami/Memory/Access.hs`. Its `agentActor` currently mints a
self-asserted reference from the agent name. It becomes:

```haskell
agentActor :: AgentPrincipal -> RecordedPrincipal
agentActor = KnownPrincipal . principalRefFor
```

Delete the local minting helper and the `shikigami.agent.` prefix along with it. Rewrite the module
haddock: it currently explains at length why Shikigami mints its own reference *because it has no
directory*, and that premise no longer holds. Explain instead that the reference comes from Meibo,
and that this is the state the module was always documented as heading toward.

Now retire the deprecation debt. Shikigami calls `Session.start`, `Session.complete`,
`Session.failSession`, `Session.recordTurn`, `Memory.record`, and `Recall.legacyRecall` — all
deprecated, all restricted to Kioku's legacy memory space. Their supported replacements take a
`MemoryAccessContext` as an additional first argument: `startWithContext`, `completeWithContext`,
`failSessionWithContext`, `recordTurnWithContext`, `recordWithContext`, and `recall` with a
`RecallQuery`.

A context is minted with `assumeAuthorizedMemoryContext`, which takes a memory space and a
`MemoryActor`. Extend `Shikigami.Memory.Access` with a per-agent context:

```haskell
agentWriteContext :: AgentPrincipal -> MemoryAccessContext
agentWriteContext principal =
  assumeAuthorizedMemoryContext shikigamiMemorySpace (MemoryActor (principalRefFor principal))
```

One rule governs every call site, and getting it wrong produces a runtime refusal rather than a
compile error: **the `actorPrincipal` on the command record must equal the context's actor.** Kioku
checks this in `underContext` and returns `SessionActorMismatch` when it differs. Since both now
come from the same `AgentPrincipal`, they agree by construction — but do not be tempted to build a
context from one agent and a command from another when handling delegation.

The existing read context, `shikigamiReadContext`, uses a service principal. Reads do not persist an
actor, so this may stay as it is; note in the module why the read and write paths differ.

Acceptance: `nix develop -c cabal build all --enable-tests` completes with no `-Wdeprecations`
warning naming `Kioku.Session`, `Kioku.Memory`, or `Kioku.Recall`. Verify with:

```bash
cd /Users/shinzui/Keikaku/bokuno/shikigami
nix develop -c cabal build all --enable-tests 2>&1 | grep -A3 'Wdeprecations' | grep -i kioku
```

Expected output is empty.


### Milestone 3 — Grants are keyed by principal

At the end of this milestone a permission grant belongs to a principal, so renaming an agent does
not silently revoke its ability to reach the outside world.

Add a migration under `shikigami-migrations/sql-migrations/`, named with a UTC timestamp prefix
matching the existing convention (`YYYY-MM-DD-HH-MM-SS-<slug>.sql`). It makes `principal_id` the
key of `shikigami.sink_grants`: backfill it, make it `NOT NULL`, and move the primary key from
`(agent_name, sink_kind)` to `(principal_id, sink_kind)`. Keep `agent_name` as a nullable
presentation column — an operator reading the table wants to see a name — and say so in a comment,
because a future reader will otherwise assume it is dead and drop it.

The backfill cannot invent a mapping. Rows whose name resolves to no principal, or to more than
one, must be left alone and reported; Milestone 5 owns that logic, so this migration should either
run after a reconciliation has populated `principal_id`, or refuse to make the column `NOT NULL`
while any row is unmapped. Prefer the second: a migration that fails loudly on unmapped data is
better than one that silently drops permissions.

Then update `shikigami-core/src/Shikigami/Sink/GrantStore.hs`: `lookupGrant` takes an
`AgentPrincipal`, the SQL selects on `principal_id`, and the keyset pagination in the listing
functions orders by `(principal_id, sink_kind)`. The permission gate in
`shikigami-core/src/Shikigami/Sink/Permission.hs` follows.

Acceptance: an integration test against a real Postgres that grants a sink to a principal, renames
the agent's `agent_name` column value, and shows the grant still resolves.


### Milestone 4 — Outbound work is attributed to the principal

At the end of this milestone, anything Shikigami emits that has an author or actor field carries
the principal id, and a name may accompany it only as presentation.

`shikigami-core/src/Shikigami/Sink/Danwa.hs` posts into a conversation. Carry the principal on the
message it sends. `shikigami-core/src/Shikigami/Integration/Danwa.hs` models the inbound
`AddressedMessage` with an `author :: !Text`; where Shikigami produces rather than consumes, the
authored value becomes the principal id.

Apply the same rule to the other sink handlers under `shikigami-core/src/Shikigami/Sink/` —
`ReiAction.hs`, `KizashiClient.hs`, `KawaClient.hs` — wherever the payload names who acted.

`IR-9` is explicit that a handle or display name "may accompany it as presentation data but cannot
replace it". So where a payload has room for both, send both, with the principal as the
identifying field.

Note the boundary: making Danwa *render* a Meibo profile is not this plan's work, and `IR-9` lists
it as a non-goal. This milestone only ensures the identifying value is present in what Shikigami
sends.

Acceptance: a test asserting that a dispatched Danwa sink payload contains the run's principal id.


### Milestone 5 — Migrate the history already on disk

At the end of this milestone there is a command that maps existing name-keyed data onto principals,
can be run repeatedly without harm, and refuses to guess.

Add a subcommand to the migration executable at `shikigami-migrations/`, invoked as
`shikigami-migrate reconcile-principals`. For every distinct agent name appearing in Kioku memory
scopes and in `shikigami.sink_grants`, it resolves the name through the directory and then does one
of three things. If exactly one principal matches, it rewrites the scope entity and the grant
subject to that principal. If no principal matches, it reports the name and leaves it untouched. If
more than one matches, it reports the ambiguity and leaves it untouched.

Two properties matter more than the mechanism. **Idempotence**: running it twice must be
indistinguishable from running it once, which means the rewrite is conditional on the row still
being name-keyed. **Non-duplication**: `IR-9` requires moving or aliasing recall scope "without
duplicating memories", so the operation rewrites the scope of existing rows rather than recording
new memories under the new scope. Recording copies would double every recall result.

The command exits non-zero when anything was reported, so that an operator running it in a
deployment script notices. Print a summary that names counts and then each unresolved case, for
example:

```text
reconcile-principals: 7 agents, 5 mapped, 1 unmapped, 1 ambiguous
  unmapped   retention-agent        (no Meibo principal for handle @retention-agent)
  ambiguous  triage                 (agent_01jf2… , agent_01jg7…)
exit status 1
```

Acceptance: a test that seeds memories under two name-keyed scopes, one resolvable and one
ambiguous, runs the command twice, and asserts that the resolvable one moved exactly once and the
ambiguous one is untouched and reported both times.


### Milestone 6 — Fail closed, keep the development mode, and demonstrate the rename

At the end of this milestone the system refuses to act on an unidentifiable agent, local
development still works without a directory, and the plan's headline claim is demonstrated.

`IR-9` requirement 6 states that in directory-enabled operation, an unknown, deactivated, or
ambiguous principal cannot start a run or emit an attributed message. Implement that at the
admission point built in Milestone 1: resolution failure means the run is not enqueued, and the
refusal is recorded as an attributable outcome rather than logged and dropped. Plan 23 establishes
the pattern for a recorded skip; follow it rather than inventing a second one.

Requirement 6 also preserves the directory-disabled mode from `IR-1` for local development. Keep
it, and make it visible: a run admitted without a directory must be marked as compatibility
identity rather than Meibo-verified, so that nobody mistakes a development transcript for evidence
of verified execution.

Then capture the demonstration. This is the observable outcome the whole plan exists for, and the
transcript belongs in the Concrete Steps section of this file once it has been run.


## Concrete Steps

This section is filled in as the work proceeds; the commands below are the ones every milestone
relies on, and the demonstration at the end is Milestone 6's acceptance.

All commands run from the repository root:

```bash
cd /Users/shinzui/Keikaku/bokuno/shikigami
```

Start the development database. The repository ships a Postgres cluster under `db/`, and the
justfile has no recipe to start it:

```bash
nix develop -c pg_ctl -D db/db -l db/postgres.log -o "-k $PWD/db -h \"\"" start
```

Expected output ends with `server started`. Stop it later with
`nix develop -c pg_ctl -D db/db stop`.

Apply migrations and confirm none are pending:

```bash
nix develop -c just migrate
nix develop -c just migrate-status
```

The status command ends with `pending=0`.

Build and test:

```bash
nix develop -c cabal build all --enable-tests
nix develop -c cabal test all
```

All seven suites must report `PASS`.

The rename demonstration, to be run and transcribed at Milestone 6:

1. Register an agent principal in Meibo and give it the handle its declaration joins by.
2. Run the agent so it records at least one memory, and note the principal id in the session.
3. Change the agent's *display name* in Meibo. Do not change the handle.
4. Restart the Shikigami workers.
5. Address the agent through its handle and run it again.
6. Observe that the run recalls the memory recorded in step 2, that the grant from step 2 still
   applies, and that both the old and the new run resolve to the same principal.

Paste the actual transcript here when it has been produced. A plan claiming this works without the
transcript is a plan claiming something it has not shown.


## Validation and Acceptance

The plan is accepted when the six acceptance criteria in `IR-9` hold. Each is phrased below as
something a person can observe, with the milestone that delivers it.

A single agent's session, memory scope, grant subject, run lineage, and outbound message author
all contain the same `agent_…` principal id (Milestones 1 through 4). Verify by running one agent
end to end and inspecting the Kioku session row, the memory scope of what it recorded, its row in
`shikigami.sink_grants`, and the payload it sent.

Changing a Meibo display name and restarting Shikigami leaves addressing, recall, and grants
working (Milestone 6's demonstration). This is the headline claim; it is verified by the transcript,
not by a unit test.

An explicit rename retains one principal-keyed history and reports the alias, creating no second
identity and no duplicate memory (Milestone 5). Verify by counting memories before and after
reconciliation; the counts must match.

A legacy name mapping to zero or multiple principals is reported and left untouched (Milestone 5).
Verify with the seeded ambiguity test, and by running the command twice.

Workflow replay and delegated children reuse the principal recorded at admission even if the
directory changes mid-execution (Milestone 1). Verify with the replay test.

Directory-disabled development fixtures remain usable and are visibly marked as compatibility
identity (Milestone 6).

Two repository-level checks apply throughout. `nix develop -c cabal test all` must be green, and
`nix develop -c cabal build all --enable-tests` must emit no `-Wdeprecations` warning naming a
Kioku module — the second is Milestone 2's specific acceptance and is easy to regress.


## Idempotence and Recovery

The build and test commands are safe to repeat.

The reconciliation command of Milestone 5 is idempotent by construction: it rewrites only rows that
are still name-keyed, so a second run finds nothing to do and reports the same unresolved cases.
This is a property to test, not merely to intend.

The database migration of Milestone 3 is the one genuinely risky step, because it moves a primary
key and can drop permissions if the backfill is incomplete. It must refuse rather than proceed when
any row is unmapped. Before running it against any database that matters, take a backup:

```bash
nix develop -c pg_dump -Fc shikigami > /tmp/shikigami-before-principal-rekey.dump
```

Restore with `pg_restore` if the migration is rolled back. For the development cluster this is
optional — the repository's own guidance in `docs/architecture/implementation-order.md` records
that Shikigami has no users and that recreating the database is an acceptable recovery — but the
habit is worth keeping, and the moment real data exists the `cohort-migrate` skill governs instead
of `just migrate`.

If Milestone 1's `RunJob` shape change is deployed while jobs are already queued, those jobs will
fail to decode. Drain the queue before deploying, or accept the loss; there is no compatibility
obligation, but there is a surprise if nobody expects it.


## Interfaces and Dependencies

### New in this repository

`shikigami-core/src/Shikigami/Agent/Principal.hs` must exist at the end of Milestone 1, exporting:

```haskell
newtype AgentPrincipal = AgentPrincipal Text
principalRefFor    :: AgentPrincipal -> Kioku.Api.Access.PrincipalRef
principalScopeText :: AgentPrincipal -> Text
```

with `ToJSON` and `FromJSON` instances, so that `RunJob`'s generic derivation continues to work.

`shikigami-core/src/Shikigami/Memory/Access.hs` must export, at the end of Milestone 2:

```haskell
agentActor        :: AgentPrincipal -> Kioku.Api.Access.RecordedPrincipal
agentWriteContext :: AgentPrincipal -> Kioku.Api.Access.MemoryAccessContext
```

`shikigami-core/src/Shikigami/Memory/Scope.hs` must export
`agentScope :: AgentPrincipal -> Kioku.Api.Scope.MemoryScope`.

### Consumed from plan 23

`Shikigami.Directory` — the cached Meibo view. This plan needs one operation from it: resolve a
declaration name or handle to a principal, with the three outcomes *exactly one*, *none*, and
*several* distinguishable. If plan 23's module does not distinguish them, extend it there rather
than re-deriving the distinction here.

### Upstream libraries

From `mori://shinzui/kioku`, pinned in `cabal.project` at `0.4.1.0`:

- `Kioku.Api.Access` — `PrincipalRef`, `mkPrincipalRef`, `MemoryActor`, `RecordedPrincipal`,
  `MemoryAccessContext`, `assumeAuthorizedMemoryContext`. Note that `mkPrincipalRef` returns
  `Either Text PrincipalRef` and reserves the characters `:` and `#`.
- `Kioku.Api.Scope` — `MemoryScope`, `ScopeEntity`, `ScopeKind`, `Namespace`.
- `Kioku.Session` and `Kioku.Memory` — the `*WithContext` write functions that replace the
  deprecated wrappers, and the `underContext` actor check that makes a mismatched pair fail at
  runtime with `SessionActorMismatch`.

From `mori://shinzui/meibo`, which has **no Hackage release and no git tags** and must therefore be
pinned by commit:

- `Meibo.Api.Id` — `PrincipalId`, `principalIdText`, `PrincipalKind`.
- `Meibo.Client` — `principalByHandle`, `getPrincipal`, `searchPrincipals`.

When adding the pin, follow the rule in `docs/dependency-cohort.md`: a `source-repository-package`
stanza is admissible only for a package with no Hackage release or a fork deliberately carried, and
each stanza carries a comment saying which case it is and when it retires. Meibo's retires when it
publishes.

### Related plans in this repository

- `docs/plans/23-agent-lifecycle-control-with-meibo-principals.md` — the prerequisite.
- `docs/plans/30-operator-cli-inspect-runs-agents-dead-letters-and-cancel.md` — owns
  `shikigami agents list`, which should show principals once they exist.
- `docs/plans/33-agent-schema-evolution-identity-memory-policy-and-enablement.md` — owns the
  declaration's `identity` block, which is where a declaration names the handle it joins by.
- `docs/architecture/implementation-order.md` — the cross-plan ordering, and the record that
  Shikigami has no users, which is why this plan owes no wire or data compatibility.
