# 0028. A router catalog is a bounded snapshot of declared authority

Date: 2026-08-23

Status: accepted


## Context

A router behavior needs enough information to choose a specialist, but the model-facing input must
not become a second authorization system. An inbound event can name arbitrary agents, the manifest
directory can contain undeclared specialists or several decoded declarations claiming one name,
and a failed manifest has no trustworthy decoded identity. Treating any of those inputs as candidate
authority would bypass the router's declared delegation allow-list.

Lifecycle is also a moving boundary. `DirectoryHandle` atomically publishes complete views, but a
background refresh can land between two reads. Resolving each candidate through a separate live
lookup could therefore produce one catalog assembled from multiple generations. Refresh time and a
source diagnostic are not policy contents and should not make an otherwise identical catalog look
new.


## Decision

**A router catalog contains exactly the router's validated `delegates`, in declaration order,
resolved against one immutable declaration report and one immutable lifecycle snapshot.**

Catalog construction groups successfully decoded declarations by exact agent name. No match is a
`missing-declaration` exclusion and multiple matches are a `duplicate-declaration` exclusion; file
order never chooses between competing declarations. Failed manifest entries contribute only an
unassociated count. Their paths and diagnostics remain in the canonical load report and operator
logs, and no filename is interpreted as an agent identity.

One `readDirectorySnapshot` call captures disabled, configured-valid, or configured-unavailable
state before candidates are resolved. The private directory handle owns source attribution, so a
router caller cannot relabel the shipped file source as a live Meibo client. Disabled mode renders
as `local-enabled`; configured file mode renders as `directory-file`. Enabled candidates join by an
explicit principal id when declared and otherwise by the normalized declaration name. Active is
available; paused, deactivated, unknown, and unavailable states remain distinct exclusions. A
disabled declaration is excluded before lifecycle lookup.

A resolved catalog entry exposes only the candidate name, optional description, expertise metadata,
and typed availability. It does not expose behavior instructions, payload or changed-document bodies,
credentials, tool configuration, capability overlays, sanctioned profiles, sinks, source paths, or
full loader diagnostics.

Both the directory snapshot and candidate catalog receive deterministic UUIDv5 versions over
explicit, length-prefixed semantic projections. The directory version includes source kind, state,
normalized principals, and lifecycle values but excludes `loadedAt` and refresh errors. The catalog
version includes router name, lifecycle source and snapshot version, ordered model-facing entries,
and the unassociated load-failure count. UUIDv5 supplies stable identity rather than a security
digest. The durable routing workflow journals the complete catalog before evaluating a decision.


## Alternatives rejected

**Accept candidates from the inbound payload or every loaded manifest.** This lets an untrusted
event or an unrelated deployment file expand delegation authority beyond `delegates`.

**Silently drop unavailable candidates.** A later no-match would be indistinguishable from a router
that considered every declared specialist, hiding lifecycle and declaration failures from replay and
operators.

**Choose the first duplicate declaration by filename order.** Deterministic traversal is not
authority. Selecting one silently makes deployment naming decide which specialist runs.

**Infer a failed manifest's agent name from its path.** Filenames are not part of the declaration
contract, so this would fabricate an identity after decoding failed.

**Consult the mutable directory once per candidate.** Every individual answer would be complete,
but the combined catalog could still mix refresh generations.

**Version timestamps or source errors.** Reloading identical policy or retaining a last-known-valid
view after an outage would mint a new identity without changing the routing choices.


## Consequences

The router model sees a bounded, replayable statement of exactly which declared specialists were
available and why others were excluded. Missing and duplicate declarations fail closed without
copying untrusted metadata, while disabled deployments and configured lifecycle failures remain
honestly distinguishable.

Catalog reconstruction is pure after the two snapshots are captured. Equal semantic inputs produce
equal JSON and versions; metadata, lifecycle, source, ordering, or load-failure-count changes produce
a different catalog version. A future live Meibo client may implement the same directory snapshot
contract, but it must provide truthful `meibo-client` attribution and preserve complete-snapshot
publication.


## References

* [`docs/masterplans/8-declarative-router-agents.md`](../masterplans/8-declarative-router-agents.md)
  — coordinates declaration, catalog, and durable routing ownership.
* [`docs/plans/41-resolve-lifecycle-aware-router-candidate-catalogs.md`](../plans/41-resolve-lifecycle-aware-router-candidate-catalogs.md)
  — implementation and acceptance evidence.
* [ADR 0023](0023-delegation-is-governed-at-the-child-spawn-boundary.md) — the delegation allow-list
  and child-spawn authority boundary.
* [ADR 0024](0024-a-configured-principal-directory-fails-closed-to-its-last-valid-snapshot.md) — the
  atomic last-known-valid lifecycle policy this catalog snapshots.
