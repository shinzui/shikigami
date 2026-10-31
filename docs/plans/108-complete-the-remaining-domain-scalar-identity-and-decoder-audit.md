---
id: 108
slug: complete-the-remaining-domain-scalar-identity-and-decoder-audit
title: "Complete the remaining domain scalar identity and decoder audit"
kind: exec-plan
created_at: 2026-10-31T18:18:49Z
intention: "intention_01m61agcfzek98hqzkb0kxcfmg"
provenance:
  created_by:
    model: "gpt-6.1-sol"
    harness: "codex-cli"
    at: 2026-10-31T18:18:49Z
  reviews:
    - model: "gpt-6-astra"
      harness: "codex-cli"
      at: 2026-10-31T19:06:03Z
      verdict: "changes-requested"
      note: "Define the exhaustive classification artifact and freshness checks, executable behavioral acceptance with disposable PostgreSQL, and direct authority/source navigation."
  revisions:
    - model: "gpt-6-astra"
      harness: "codex-cli"
      at: 2026-10-31T19:16:14Z
      mode: "update"
      note: "Address review: define classification schema and coverage/freshness gates, runnable isolated PostgreSQL and compiler acceptance, milestone completion criteria, and direct ADR links."
    - model: "gpt-6.1-sol"
      harness: "codex-cli"
      at: 2026-10-31T19:29:51Z
      mode: "implement"
      note: "Implement declaration/member coverage tooling and audit the remaining domain owners."
---

# Complete the remaining domain scalar identity and decoder audit


## Purpose / Big Picture


Complete the exhaustive domain review separated from the tested Keiro 0.22 upgrade
when the user requested bounded macOS completion after twelve hours. This is a
standalone follow-up, not another child or release gate of MasterPlan 16. No
remaining finding is certified compliant by that scope decision. The result should
prevent accidental substitution of values with different domain meanings and make
corrupt retained data produce an explicit refusal without committing partial work.
Compiler rejection tests and real PostgreSQL corruption/recovery tests demonstrate
these outcomes; a complete, source-bound classification demonstrates audit coverage.

## Progress


- [ ] M1: Deliver a complete declaration/field classification and coverage checker; every entry has an authority and disposition, and known violations remain explicit.
- [ ] M2: Resolve applicable scalar/identity/decoder findings in cohesive concept batches and verify actual refusal, rollback and recovery behavior.
- [ ] M3: Accept the refreshed classification with zero unresolved violations, passing final behavioral evidence, and an updated guide disposition.

Implementation is under way. The schema-2 census and coverage/freshness checker
pass 24 positive/mutation tests against a successful GHC 9.12.4 macOS build.
There are 3,988 declaration/member keys, including the migration entrypoint's
`Command`. Semantic classification and remediation remain unfinished; see
[the current evidence](../evidence/plan-108/acceptance.md).

## Surprises & Discoveries


The original upgrade expanded into many individual domain-value waves. Repeated
full macOS/serial PostgreSQL checks dominated elapsed time. The accepted code
already has broad nominal/value/transaction improvements; the remaining
322-module/913-declaration worklist is explicitly unclassified.

2026-10-31: GHC/Cabal can retain byte-identical interfaces whose modification
times predate touched source files. The census now compares the interface's
embedded source fingerprint with actual source bytes, in addition to binding
source/interface/tool bytes with SHA-256. Executable interfaces are checked too.

## Decision Log


2026-10-31: Preserve residual scope here while the upgrade closes on its tested
macOS profile. Batch independent fixes by concept, use focused tests during
implementation and one full acceptance pass per milestone. Do not mint an ID,
wrap a native opaque type or invent a validation rule before reading its actual
producer, lifetime and authority.

2026-10-31: Separate classification completeness from remediation completion.
M1 may record known violations but no unclassified entries; M3 requires zero
unresolved violations and fresh source/build evidence. Use the existing isolated
PostgreSQL suite fixture and focused owner tests during M2, followed by one full
behavioral pass for the final candidate, rather than repeating full suites for
classification-only or documentation-only milestones.

## Outcomes & Retrospective


No implementation acceptance. The prior work is in
[plan107](107-adopt-current-haskell-and-service-architecture-practices.md) and
[the adoption evidence](../evidence/keiro-0.22/haskell-service-adoption.md).

## Context and Orientation


Work from the repository root. Read the frozen guide
`mori://shinzui/keiro-runtime-patterns/docs/architecture-domain-newtypes-and-typeids`
and its exact source/hash row in `docs/architecture/keiro-0.22-coverage.json`.
`docs/evidence/keiro-0.22/domain-declarations.json` contains compiled declarations,
source/interface hashes and fourteen role entrypoints; it is a worklist, not a
semantic audit. Refresh it after an actual coherent build.

The frozen guide requires distinct nominal types (types the compiler cannot
interchange) for key domain values, checked construction for invariants, allocated
TypeIDs for service-owned entities, and explicit authorities for external IDs and
locators. A locator finds an entity; it is not automatically the entity's identity.
A DTO is a record used only to transfer a boundary representation. Persistence
alone does not make a record a DTO. Preserve wire bytes for representation-only
changes and qualify any changed admitted identity domain separately.

[ADR-73](../adr/0073-objective-identity-is-allocated-and-creation-receipts-own-deduplication.md)
separates allocated entity identity from the receipt that deduplicates creation.
[ADR-90](../adr/0090-execution-and-session-json-corruption-is-a-transactional-domain-refusal.md),
[ADR-98](../adr/0098-resource-row-decoding-refuses-corruption-inside-the-transaction.md),
and [ADR-99](../adr/0099-assignment-call-readers-preserve-corruption-and-transaction-ownership.md)
require corrupt owned JSON to return the owner's refusal inside the transaction,
while condemning that transaction so even a caller ignoring the refusal cannot
commit earlier writes. SQL/connection failures remain distinct store failures;
missing rows remain absence, and malformed list members cannot be omitted.
[ADR-100](../adr/0100-git-intent-decoding-preserves-unresolved-publication-and-origin.md)
and [ADR-101](../adr/0101-process-intent-decoding-preserves-launch-and-receipt-uncertainty.md)
retain unresolved effects rather than treating unreadable intent as permission to
retry. [ADR-106](../adr/0106-the-keiro-upgrade-closes-on-a-bounded-macos-profile.md)
owns this plan's deferral and macOS scope. These decisions guide this audit without
certifying the remaining owners.

[ADR-27](../adr/0027-the-first-release-establishes-one-clean-durable-baseline.md)'s
unused first-release exception must not be assumed for this standalone work;
[workflow versioning](../workflow-versioning.md) governs workflow and durable
identity changes. Preserve actual authorization, accounting, protected bodies
and same-build recovery. Discover further relevant ADRs by their filenames and
headings under `docs/adr/`; `docs/adr/README.md` describes their conventions.

Remaining concrete work starts in
`shikigami-core/src/Shikigami/Decision/Contract.hs` and
`shikigami-core/src/Shikigami/Flow/Decision.hs` for preparation/slot/native
generation values. Use the census source paths to locate profile/attestation
identity, signing and policy values; worker/session identity lifetime; workspace
paths, native identities and scalars; review material/evidence values; and tool
binding/policy values. The census, not this illustrative list, defines coverage.
Review identity lifetimes and actual runtime types before selecting TypeID or a
technical/external locator representation. Native opaque IDs remain native.

Remaining SQL JSON owners are
`shikigami-core/src/Shikigami/Workspace/Store.hs`,
`shikigami-core/src/Shikigami/Workspace/CleanupStore.hs`,
`shikigami-core/src/Shikigami/Workspace/TransferStore.hs`,
`shikigami-core/src/Shikigami/Workspace/ProcessProfileStore.hs`,
`shikigami-core/src/Shikigami/Objective/Store.hs`,
`shikigami-core/src/Shikigami/Directory/Store.hs`,
`shikigami-core/src/Shikigami/AgentRun/Ledger.hs`, and
`shikigami-core/src/Shikigami/Sink/Delivery.hs`. ResourcesStore, SelectionStore, Execution.Store, WorkerSession.Store,
GitStore and ProcessStore already retain typed row refusal in their accepted
scope. Distinguish actual technical-key pagination refinement from owned JSON
corruption. Do not replace whole-transaction rollback with an uncondemned Left.

## Plan of Work


### M1: Make coverage inspectable


Create `docs/evidence/plan-108/domain-classification.json` and
`docs/evidence/plan-108/acceptance.md`. The JSON document has `schemaVersion: 1`,
`censusSha256`, the frozen guide's `source`, `sourceRevision`, `sourcePath` and
`sourceSha256`, and an `entries` array. Each entry has `sourcePath`, `module`,
`declaration`, `member`, `sourceSha256`, `classification`, `disposition`,
`invariant`, `authority`, `boundaryOwner`, `rationale`, and `evidence`.
`evidence` is an array of repository-relative file paths plus test names or source
symbols; cross-repository authorities use canonical Mori URIs. Explain genuinely
absent authorities/boundaries rather than using an unexplained empty value.

The unique key is `(sourcePath, module, declaration, member)`. Use member `$self`
for each declaration, including aliases and nullary types; alias entries review
the alias target. Also enumerate every constructor argument: use
`Constructor.fieldName` for record fields and `Constructor.#1`, `Constructor.#2`,
and so on for positional fields, including newtype payloads. Shared selectors
still have an entry for each constructor. Enumerate declarations in all fourteen
role entrypoints using their source module name (usually `Main`) and source path;
currently `shikigami-migrations/app/Main.hs` declares `Command`. Empty entrypoints
remain represented by the census and participate in freshness checks.

Allowed classifications are `domain-value`, `owned-identity`, `external-identity`,
`runtime-opaque`, `locator`, `boundary-dto`, `incidental`, and `structural` (a sum,
container, or type-level declaration whose members are reviewed separately).
Dispositions are `compliant`, `violation`, `not-applicable`, and `pending`.
A classification is not an exemption: explain why a primitive belongs only to an
adapter or incidental calculation, name its producer/consumer, and identify the
conversion into the domain. No blanket persistence exemption is allowed.

Add `tools/domain/check_classification.py` with `--classification`, `--census`,
and `--require-resolved` options. Extend `tools/domain/census.py` to expose
structured constructor/member keys and source-parsed entrypoint declarations so
the checker derives the expected set independently of the classification file.
Keep compiler-rendered declarations and hashes; bump the census schema version
when its shape changes. Unsupported declaration syntax must fail with its source
path instead of silently omitting members. Test record, positional, newtype,
alias, nullary, shared-selector and entrypoint shapes in
`tools/domain/test_classification.py`.

The checker rejects duplicate, missing and extra keys; pending dispositions;
missing rationale/evidence; a mismatched census hash; and source/interface/tool
hash drift against checkout-local build artifacts. Re-enumerate the current source
set using the census discovery rules to reject omitted new modules or entrypoints.
Check entrypoint hashes too.
It never reads dependency build directories. Without `--require-resolved`, known
violations are allowed and counted; with it, any violation fails. Mutation tests
must show deletion, duplication, stale hashes, an omitted positional member, an
omitted entrypoint declaration and unresolved violations fail in the appropriate
mode. Mechanical coverage is not semantic approval: manually review the declared
invariant and authority for each entry. M1 ends when all entries are classified,
the checker and its tests pass, and the acceptance note records totals and the
remaining violation count. The historic 322/913/14 counts are a starting point,
not constants that forbid newly added or removed declarations.

### M2: Resolve violations by concept


Resolve actual violations in cohesive concept batches. Private nominal scopes
may preserve distinct meanings; genuine foreign/native boundary values retain
their actual representation. Trace each producer, lifetime, and consumer before
choosing TypeID or any new invariant. Use Mori for dependency source lookup and
verify authoritative releases before changing bounds; no dependency upgrade is
required by this plan.

For each changed decoder owner, first persist and successfully read a complete
valid value through the public path, then inject malformed metadata in its fresh
test database. Assert an owning refusal, unchanged unresolved effects/holds, and
rollback of an earlier tentative write in the same transaction even if the caller
ignores the returned refusal. Where readers return lists, prove a malformed member
cannot disappear behind a valid member. Retain missing-row and genuine SQL-failure
controls. Repeated/concurrent allocation must recover the same retained winner;
a recovery retry must not create a replacement effect for unreadable intent.

Put these controls in the owning suites under
`shikigami-core/test-postgres/Shikigami/`, starting with
`WorkspaceTransferSpec.hs`, `ObjectiveStoreSpec.hs`, `DirectoryStoreSpec.hs`,
`AgentRun/LedgerSpec.hs`, and `SinkDeliverySpec.hs`. Add owner-specific test modules
and register them in `shikigami-core/test-postgres/Main.hs` and
`shikigami-core/shikigami-core.cabal` where existing suites lack the boundary.
Use `shikigami-core/test/` for positive/negative complete-codec cases and
`tests/types/opaque-values.py` and `tests/types/revision-domains.py` for compiler
checks. A public-client positive control must compile before testing constructor,
coercion, scope and Generic bypass refusal. Invalid-input tests must start from a
valid complete value, so unrelated missing fields cannot explain their success.
Preserve exact old wire encodings for semantic-preserving changes; apply the
workflow policy and retain native reports for durable changes.

Record each resolved entry's concrete tests and evidence in the classification
and `docs/evidence/plan-108/acceptance.md`. M2 ends when the refreshed checker with
`--require-resolved` passes, all changed-owner behavioral/compiler checks pass,
and every violation has a demonstrated fix or a source-supported correction to
its classification. Unexecuted platform behavior cannot support such a correction.

### M3: Accept the final candidate


Rebuild, refresh the census, reconcile added/removed keys and review every changed
source's classifications again. Run the final behavioral suites below once on the
coherent candidate, retaining command, revision/dirty-diff identity, platform,
compiler, selected test counts, results and limitations in the acceptance note.
Only then change the domain guide row and its deferred census clause in
`docs/architecture/keiro-0.22-coverage.json`, linking the new evidence. Preserve all
124 frozen source identities/hashes and earlier evidence. Run the existing upgrade
audit to detect inventory regressions; it checks inventory and evidence links,
not semantic classification. Review its output wording if it still claims one
follow-up after this deferral is resolved. Distill new durable decisions into the
relevant ADRs, retaining ADR-106 as the historical scope decision.

## Concrete Steps


Run from the repository root on arm64 macOS in the declared GHC 9.12.4 development
shell. Resolve the frozen guide with Mori; if the artifact URI is not yet indexed,
resolve `mori://shinzui/keiro-runtime-patterns` and use the coverage row's
project-relative `sourcePath`. Compare its SHA-256 with that row. If the checkout
has moved, read that path at `sourceRevision` using `git show` in the resolved
repository; do not replace the frozen denominator with today's guide.

```bash
mori registry docs shinzui/keiro-runtime-patterns
mori path mori://shinzui/keiro-runtime-patterns
nix develop --no-write-lock-file -c cabal build all --enable-tests -j1
nix develop --no-write-lock-file -c python3 tools/domain/census.py --output docs/evidence/keiro-0.22/domain-declarations.json
```

The build must succeed before census refresh. The census must use the same GHC
and local build root; it prints module/declaration/entrypoint counts. The following
commands become runnable when M1 creates the checker, tests and classification:

```bash
python3 -m unittest discover -s tools/domain -p 'test_*.py' -v
python3 tools/domain/check_classification.py --classification docs/evidence/plan-108/domain-classification.json --census docs/evidence/keiro-0.22/domain-declarations.json
```

Use the existing suite-owned fixture, not a developer database. The entrypoint
`shikigami-core/test-postgres/Main.hs` calls `withShikigamiMigratedSuite` from
`shikigami-migrations/test-support/Shikigami/Migrations/TestSupport.hs`. It starts
an ephemeral PostgreSQL server, applies Kiroku/Keiro/Kioku/PGMQ/Shikigami migrations
once, and `withShikigamiFreshDatabase` clones a fresh database per example,
reconciles read models, and cleans up afterwards. The dependency owner is
`mori://shinzui/keiro/packages/keiro-test-support`. PostgreSQL 18 tools come from
the development shell. No manually created database or supplied production
connection string is needed. Fixture startup or migration failure is a failure,
not permission to skip. Close all test connections inside the fixture callback.

For a focused M2 batch, this existing set exercises four remaining decoder owners;
replace the literal alternatives with the owning groups for other batches. Inspect
selected names with `--list-tests` first and record a nonzero count from the actual
run. The filter is Tasty's literal expression syntax, not a regular expression.

```bash
nix develop --no-write-lock-file -c cabal test shikigami-core-postgres-test -j1 --test-show-details=direct --test-option=--num-threads=1 --test-option=-p --test-option='/workspace transfer store/||/ObjectiveStore/||/directory store/||/SinkDelivery/' --test-option=--list-tests
nix develop --no-write-lock-file -c cabal test shikigami-core-postgres-test -j1 --test-show-details=direct --test-option=--num-threads=1 --test-option=-p --test-option='/workspace transfer store/||/ObjectiveStore/||/directory store/||/SinkDelivery/'
nix develop --no-write-lock-file -c just domain-value-types
```

M3's final pass runs all core PostgreSQL cases serially, the six runtime package unit
suites, compiler checks, and the domain conformance suite. Expect Tasty suites to
report passing tests with nonzero counts; skipped database cases do not count.
The domain suite prints `PASS` lines and a RunEvidence report, and must exit zero.
It verifies declared contracts, not exhaustive semantic coverage.

```bash
nix develop --no-write-lock-file -c cabal test shikigami-core-test shikigami-api-test shikigami-client-test shikigami-server-test shikigami-agent-test shikigami-workers-test shikigami-core-domain-test -j1 --test-show-details=direct
nix develop --no-write-lock-file -c cabal test shikigami-core-postgres-test -j1 --test-show-details=direct --test-option=--num-threads=1
nix develop --no-write-lock-file -c just domain-value-types
python3 tools/domain/check_classification.py --classification docs/evidence/plan-108/domain-classification.json --census docs/evidence/keiro-0.22/domain-declarations.json --require-resolved
nix develop --no-write-lock-file -c just keiro-upgrade-audit
python3 tools/style/check_haskell.py
git diff --check
```

For changes to workflow bodies, durable identities or `domain/`, also run
`nix develop --no-write-lock-file -c just keiro-gate <base-commit>` with the actual
pre-batch commit recorded in the acceptance note and follow the workflow policy
for any breaking findings. If migration SQL changes, run
`nix develop --no-write-lock-file -c cabal test shikigami-migrations-test shikigami-migrations-smoke -j1 --test-show-details=direct`.
If HTTP representations change, run `nix develop --no-write-lock-file -c just hurl`.
These conditional checks are required when their surface changes. Preserve
applicable evidence across documentation-only edits; repeat tests only when code,
failures or unresolved concerns invalidate it. macOS remains the selected platform.

## Validation and Acceptance


M1 requires exact key coverage with no pending entries and passing checker mutation
tests; it explicitly permits counted violations. M2 requires zero unresolved
violations and executed positive/negative controls for changed owners. M3 requires
fresh source/interface/tool/census hashes, a semantic rereview of changed entries,
the final suites and applicable conditional gates, and the updated frozen guide
row with evidence links. A passing compiler or inventory validator alone cannot
meet these conditions. Refreshing hashes alone does not renew semantic evidence.

Every applicable violation must be fixed with behavioral or compiler evidence.
No blanket persistence exemption, invented source authority, zero-test selection
or unexecuted platform profile is called compliant. Preserve explicit follow-up
attribution until these conditions hold. The acceptance note must distinguish
current results from historical upgrade evidence and name any remaining work;
remaining applicable violations prevent completion.

## Idempotence and Recovery


Use task-owned disposable fixtures. Never delete developer databases or drop
live protected data to make a gate pass. Repeated allocation/admission returns
its retained winner; unreadable intent cannot become absence or a replacement
effect. Keep generated code generator-owned and preserve accepted native reports.
Write census/classification updates atomically or to a temporary sibling file,
validate, then replace the intended artifact. On an interrupted batch, rebuild
before refreshing the census; retain unresolved entries and previous acceptance
evidence instead of carrying their verdicts onto changed hashes. Do not manually
sweep the shared ephemeral PostgreSQL cache or stop another task's server.

## Interfaces and Dependencies


The implemented Keiro 0.22 baseline and its code/evidence are prerequisites.
This plan does not change its dependency cohort or public operational scope by
default. Use the seven existing package/concept boundaries and the current
workflow rules. Any newly required runtime/platform profile needs its own actual
qualification; compilation alone cannot prove containment.

## Revision Notes


2026-10-31: Applied the review findings by defining the classification schema and
coverage/freshness checker, separating M1 discovery from M3 resolution, specifying
isolated PostgreSQL and compiler acceptance commands, and linking the governing
ADRs directly. This revises the implementation instructions, not its completion
status or the accepted upgrade scope.
