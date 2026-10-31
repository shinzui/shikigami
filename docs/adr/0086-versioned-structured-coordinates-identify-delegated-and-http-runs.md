# 0086. Versioned structured coordinates identify delegated and HTTP runs

Date: 2026-10-31

Status: accepted

## Context

The identity census reproduced two collisions in currently admitted inputs.
Delegating to agent `a:b` with key `c` and to agent `a` with key `b:c`
produced one child identity under the same parent. An actual admitted preflight
batch returned one identity for both children. HTTP agent/key pairs
`a:http:b`/`c` and `a`/`b:http:c` produced one full run key. The real PostgreSQL
regression failed when the second independent acceptance hit the unique run-key
constraint. Agent names and caller keys permit these separators.

The HTTP ledger recovered the caller's key by dropping a textual prefix from the
full run key. That couples acceptance facts to an ambiguous internal rendering.
The client is deliberately an API-only leaf and must retain that dependency
boundary when using a checked request key.

## Decision

Encode each coordinate in a distinct field of a versioned JSON object before
commitment. `delegatedWorkflowIdV2` commits parent, target agent and stable key
under `shikigami.delegation-child/2`, then uses the existing UUIDv5 named workflow
identity protocol. Session assignment children call the same derivation through
`assignmentChildWorkflowIdV2`. The AgentRun and ContinuingWorker native child declarations name their new
versions. Governance, preflight, root-wide atomic reservation and public Keiro
spawn ownership remain unchanged.

HTTP full run keys use `http-run-v2:` plus the commitment of agent and caller key
under `shikigami.http-run/2`. The existing run-job workflow-id adapter consumes
this opaque full key. Retain the original caller key explicitly in acceptance;
never recover it by slicing the full key. Refuse mismatched job/key coordinates
before touching the queue or ledger. Per-agent deduplication across callers,
original attribution/time, conflict behavior and send/receipt atomicity remain.

Private RequestKey owns the existing HTTP rule: 1..200 characters without
control characters, preserving whitespace and Unicode. API decoding, CLI option
reading, ledger parameters and row decoding retain it. Its string codec keeps
valid request/response bytes. There is no Generic, Num or IsString construction.
The public API reexports its checked reader and renderer; the leaf client keeps
its API-only package dependency. SQL and response encoders render explicitly.

This supersedes the flat HTTP key encoding in ADR-48 and versions the child-id
encoding used by ADR-23. These are technical runtime/locator identities using
their established UUIDv5/commitment protocols; they are not TypeID-v7 allocations.
The remaining allocated-entity identity review stays open.

## Alternatives rejected

Restricting names or keys would remove valid input and leave the encoding
fragile. A fresh random child id would destroy replay deduplication. Selecting
one child after the collision would lose admitted work. Keeping the old prefix
reader would prevent a separate structured internal key and explicit caller key.
Adding a core dependency to the leaf client would break its package boundary.

## Consequences

Under ADR-27's confirmed unused-service baseline, new derived identities change
intentionally. There is no old-identity fallback or populated cross-build replay
claim. Retain the native breaking findings for both declared child derivations
and establish the reviewed current baseline. Subsequent deployed evolution follows
the normal patch/versioning rules.

The before probes and real failed regressions are retained. Regression controls
require two distinct admitted child identities, two independent HTTP ledger rows
and sends, stable retries for each, original caller-key bytes, and atomic refusal
of substituted coordinates. The complete scalar census and packaged/runtime
qualification remain open.

## References

[ADR-23](0023-delegation-is-governed-at-the-child-spawn-boundary.md),
[ADR-48](0048-http-run-acceptance-and-queue-send-commit-as-one-fact.md),
[ADR-27](0027-the-first-release-establishes-one-clean-durable-baseline.md),
[workflow versioning](../workflow-versioning.md),
[ExecPlan 107](../plans/107-adopt-current-haskell-and-service-architecture-practices.md),
[the domain scalar standard](mori://shinzui/keiro-runtime-patterns/docs/architecture-domain-newtypes-and-typeids),
and [the public child API](mori://shinzui/keiro/packages/keiro).
