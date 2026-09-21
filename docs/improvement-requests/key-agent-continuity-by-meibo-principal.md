---
type: Improvement Request
title: Key durable agent continuity and outbound attribution by Meibo principal
description: >-
  Make the immutable Meibo agent principal the durable key for memory, grants,
  run lineage, and outbound authorship while preserving name-based history
  through an explicit migration and compatibility boundary.
timestamp: "2026-08-10T13:20:17Z"
generated:
  by: process:codex
  at: "2026-09-21T18:03:06Z"
requestId: IR-9
status: completed
completedAt: "2026-08-26T18:01:06Z"
resolution: Completed by mori://shinzui/shikigami/plans/54-key-durable-agent-state-by-meibo-principal with migration, replay, and rename evidence.
origin: mori://shinzui/kikan
reviews:
  - kind: model
    reviewer: process:codex
    reviewed_at: "2026-09-21T18:03:06Z"
    document_timestamp: "2026-09-21T18:03:06Z"
    scope: catalog-metadata
    outcome: approved
    context: Audited lifecycle status and plan coverage against the current plans, master plans, Git history, and repository tree; did not re-review the request's design.
    provider: openai
    model: gpt-5.6-sol
    effort: high
---

# Improvement Request: Key Durable Agent Continuity and Outbound Attribution by Meibo Principal

## Status

**Completed.** Plan 54 delivered principal-keyed run identity, Kioku continuity, grant ownership,
sink attribution, legacy alias migration, replay compatibility, and rename evidence on 2026-08-26.

## Context

A permanent agent must survive changes to presentation metadata. Meibo supplies an immutable
`agent_…` principal id, a stable handle, a mutable display name and profile, lifecycle, role
assignments, and ownership. Shikigami currently uses its declaration `name` in several roles at
once: addressed routing, Kioku memory scope, grant lookup, logs, and sink payload attribution.

Writing the resolved principal id into `Kioku.Session.StartSessionData.agentId`, as IR-1 already
requests, makes a session directory-joinable but does not preserve all durable state through a
rename. The current lifecycle plan explicitly retains `agentScope` keyed by declaration name. A
renamed declaration can therefore open a new recall namespace while the prior memories remain
under the old name. The same ambiguity can appear wherever a sink or audit record emits only the
declaration name.

The identity rule must be singular: names and handles locate an agent, while the Meibo principal id
identifies it.

## Requested Change

1. **Resolve identity once at admission.** Resolve the declared principal through the Meibo-backed
   directory before accepting a run and journal the immutable principal id with the run request.
   Every resumed workflow and delegated child consumes that recorded identity rather than resolving
   mutable display metadata again.
2. **Key durable state by principal.** Use the principal id for Kioku agent memory scopes, session
   lineage, permission/grant subjects, run audit records, and other durable per-agent namespaces.
   Kioku's existing text-valued scope and agent fields may be reused; do not add a Kioku schema
   change unless the migration proves that its generic scope contract is insufficient.
3. **Migrate name-keyed history explicitly.** Provide an idempotent reconciliation command or
   migration that maps each legacy declaration name to exactly one Meibo principal, moves or aliases
   existing recall scope without duplicating memories, and reports missing or ambiguous mappings.
   Ambiguous history is never silently assigned.
4. **Attribute outbound work.** Carry the principal id on Shikigami-produced Danwa messages and on
   other agent-authored integration events or sink payloads that have an actor/author field. A
   handle or display name may accompany it as presentation data but cannot replace it.
5. **Preserve address compatibility.** A stable Meibo handle may continue to resolve an addressed
   run. Changing the display name never changes routing. Changing a handle requires an explicit
   alias/reconciliation path and does not mint a new principal or memory namespace.
6. **Fail closed when identity is required.** In directory-enabled operation, an unknown,
   deactivated, or ambiguous principal cannot start a run or emit an attributed message. Preserve
   the explicit directory-disabled compatibility mode from IR-1 for local development only.

## Acceptance

1. Register one agent principal, run it, record memories and grants, and publish a Danwa message.
   The session, memory scope, grant subject, run lineage, and message author all contain the same
   `agent_…` principal id.
2. Change the Meibo display name and restart Shikigami. Addressing through the stable handle still
   reaches the agent, prior memories are recalled, existing grants still apply, and old and new
   messages resolve to the same directory profile.
3. Exercise an explicit handle/declaration rename. The migration retains one principal-keyed memory
   history and reports the alias; it creates no second identity or duplicate memory.
4. A legacy name that maps to zero or multiple principals is reported and left untouched until an
   operator resolves it.
5. Workflow replay and delegated child runs reuse the principal recorded at admission even if the
   directory profile changes during execution.
6. Existing directory-disabled development fixtures remain usable and are visibly marked as
   compatibility identity rather than Meibo-verified execution.

## Non-goals

This request does not render Meibo profiles in Danwa, define the platform architect's behavior, or
change Meibo lifecycle semantics. Danwa profile resolution belongs to its owner request; the concrete
architect composition belongs to the system repository. It also does not make a display name an
authorization subject.

## Dependencies

- `mori://shinzui/shikigami/okf/improvement-requests/concepts/IR-1` for directory lifecycle and
  declaration reconciliation.
- `mori://shinzui/meibo` for principal ids, handles, lifecycle, profiles, and ownership.
- `mori://shinzui/danwa/okf/improvement-requests/concepts/IR-2` for principal-backed message
  authorship and directory lookup.
- `mori://shinzui/kikan/okf/use-cases/concepts/UC-11` for the end-to-end rename and attribution
  contract.
