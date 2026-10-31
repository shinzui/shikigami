# 0079. Worker admission limits and instruction text refine at construction

Date: 2026-10-30

Status: accepted

## Context

Continuing-session admission retained interchangeable Int values for maximum
sessions, maximum assignments and mailbox capacity. Instruction text remained
Text whose nonblank invariant was rechecked at store admission. Record validators
could reject bad inputs but did not prevent hand-constructed invalid values or
accidental substitution between these concepts.

The admitted coordination/session records and retained instructions are domain
values. Their JSON representation does not make them boundary DTOs.

## Decision

WorkerSession.Input owns private MaximumSessions (1..128), MaximumAssignments
(1..1000) and MailboxLimit (1..128) types. Carry them through CoordinationScope,
SessionAdmission and openSessionWithLimit. Constructors/JSON parsers check bounds
once. Native SQL COUNT observations and incidental list lengths convert explicitly
when comparing with those limits. No Num, Integral, IsString or Generic instance
recreates unchecked construction.

Use private InstructionText for retained Instruction and WorkerInstruction text.
Its parser preserves the exact text, rejects blank input using the established
strip predicate, and refuses UTF-8 content larger than the existing one-MiB
payload ceiling. Show is a fixed protected marker. The full encoded payload still
has its independent existing size check: text fitting the scalar limit does not
imply that the enclosing payload fits.

Keep numeric limit JSON and string instruction JSON unchanged for valid inputs.
Do not trim, truncate or clamp. Keep the owning admission's format, delegation,
root, identity, lineage, authority and coupled transaction checks. This change
adds no workflow step or journal shape and changes no DSL declaration or identity
derivation. Instruction text still reaches delegated work through its existing
JSON input field.

## Alternatives rejected

Sharing one unscoped capacity wrapper permits assignment/mailbox substitution.
Keeping primitives behind a record validator allows invalid hand construction.
Clamping a limit widens or conceals policy. Trimming instruction text changes the
protected payload and its digest. Removing the full-payload bound would overlook
other fields and JSON encoding overhead.

## Consequences

Invalid values fail at construction/decode before domain admission. Existing valid
scope fingerprints, payload digests and technical session/assignment identity
inputs retain their representation. Exact Unicode command bytes and numeric
limit controls precede invalid-bound checks; compiler clients prove nominal
separation and constructor abstraction. Existing mailbox/assignment exhaustion,
concurrent admission, lost receipts, handoff and workspace succession continue to
exercise their actual owners. Final Linux/profile qualification and the complete
scalar/identity census remain separate work.

## References

[ADR-27](0027-the-first-release-establishes-one-clean-durable-baseline.md),
[ADR-74](0074-domain-state-revisions-keep-their-scope-at-application-boundaries.md),
[ExecPlan 107](../plans/107-adopt-current-haskell-and-service-architecture-practices.md),
and [the domain scalar standard](mori://shinzui/keiro-runtime-patterns/docs/architecture-domain-newtypes-and-typeids).
