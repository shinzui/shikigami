# Plan 108 acceptance evidence

Implementation is in progress. M1 semantic coverage is complete; M2 remediation
and M3 final acceptance remain open. The dated checkpoints below preserve their
original counts and source identities. The frozen domain guide remains deferred.

The starting revision is `914ec061f637aab50adbe480eff691406671b8c4` on arm64
macOS with GHC 9.12.4. The frozen guide was read at its recorded revision through
Mori; its SHA-256 is
`c9bb6e61d42c1345f23529b211f66d7485200aa2bfda41ef9966e8a13970a844`, matching
the coverage row. Its canonical authority is
`mori://shinzui/keiro-runtime-patterns/docs/architecture-domain-newtypes-and-typeids`.

The initial coherent build passed:

```bash
nix develop --no-write-lock-file -c cabal build all --enable-tests -j1
```

The schema-2 census refresh passed on that build: 322 library/application modules,
913 declarations in those modules, and fourteen executable entrypoints. The
migration entrypoint adds one declaration. Enumerating declaration `$self` keys
and constructor members gives 3,988 audit keys (914 declarations and 3,074 members).
These are coverage counts, not semantic verdicts.

```bash
nix develop --no-write-lock-file -c python3 tools/domain/census.py --output docs/evidence/keiro-0.22/domain-declarations.json
python3 -m unittest discover -s tools/domain -p 'test_*.py' -v
```

All 24 tooling tests pass. They exercise positive record, shared selector,
positional, newtype, alias, nullary, GADT and entrypoint shapes, and reject missing,
extra, duplicate, pending, stale, omitted-source/member and unresolved-violation
mutations. Both library and executable interfaces participate in freshness checks.
GHC's embedded `src_hash` must equal the source byte fingerprint before a census
record is emitted; interface timestamps are insufficient because GHC/Cabal may
retain a byte-identical interface after source files are touched. SHA-256 binds
the emitted census to the exact source, interface and tool bytes.

The current refreshed census adds `ProcessPolicyFormat`: 322 modules, 914 module
declarations, fourteen executable entrypoints and one entrypoint declaration.
There are 3,989 declaration/member keys. Source/compiler fingerprints and
source/interface/tool hashes match the current checkout-local build.

The initial semantic classification records 248 keys in `Decision.Contract`,
`Workspace.ProcessPolicy`, `StateRevision`, `Objective.Store` and the explicitly
reviewed Agent/AgentRun/API/problem HTTP declarations and one-off capability
errors/workspace tool boundaries: 196 compliant entries,
20 constraint/route/media-type exclusions, and 32 explicit violations. HTTP views
were traced to `agentView`, `accepted`, `statusView`, `requestView` and `requestRun`;
their internal source owners retain independent audit obligations. A structural
composition verdict does not certify its nested members. The other 3,741 keys
are unreviewed and absent from the classification, rather than assigned invented
compliance or exemption. Consequently the classification checker exits 1 with
`missing 3741 classification keys`, including with `--require-resolved`. M1 and
M2 remain incomplete.

The first runtime batch is bound by `batch-source.json`: it lists the SHA-256 of
all 21 changed implementation, fixture and test files against source parent
`5987612`. That source snapshot, rather than an unstated clean-tree revision,
identifies the tested candidate. No dependency bounds or cohort changed.

Process-profile reads now return an owning refusal for unreadable retained JSON
and invalid existing profile invariants, condemning the transaction. Missing rows
remain absence and genuine SQL failures retain their store result. Tests first
reserve/read valid complete profiles, then inject malformed JSON, invalid Unix
group identity or an unsupported policy format. Ignoring refusal after a tentative
workspace freeze rolls back that freeze; the unresolved file effect and reserved
identity remain. Restoring valid metadata recovers the same identity.

Objective statements retain typed decoder results inside their transaction.
Corrupt snapshots, command and creation receipts, checkpoint intents and worker
result metadata return `ObjectiveConflict` without a new native event or negative
command receipt. Actual SQL failure returns `ObjectiveUnavailable`; missing
receipts remain `Right Nothing`. A left join preserves present result rows with
unreadable payload references. Complete assignment-result payload envelopes decode
before source validation; their keys, digest, assignment and disposition must
match the retained source before judging caller evidence. A type-correct changed
body also refuses without a negative receipt. Repair permits the original
command/creation outcome to recover. Existing public writers, checkpoint convergence, authority and crash
recovery controls also pass. The Objective public API owns its transaction and
uses an abort exception; it does not expose a composable caller-owned transaction
reader. The explicit ignored-refusal/earlier-write PostgreSQL control in this
batch exercises ProcessProfileStore, not an invented Objective transaction API.

`ProcessPolicyFormat` admits only `ProcessPolicyV1`. Complete valid policy and
profile controls prove byte equality with the old numeric-format representation
and preserve `processPolicyIdentity`. Complete policy/profile inputs with format
0, 2, 1.5, a string, Boolean or null refuse. Compiler clients accept the public
enum and field type, then reject numeric, coercion, routing-format and Generic
bypasses. Other policy values remain unresolved violations.

Commands on the current macOS/GHC 9.12.4 batch:

```bash
nix develop --no-write-lock-file -c cabal build all --enable-tests -j1
nix develop --no-write-lock-file -c cabal test shikigami-core-test shikigami-core-postgres-test -j1 --test-show-details=direct --test-option=--num-threads=1 --test-option=-p --test-option='/workspace retained process policies/||/workspace process profile store/||/ObjectiveStore/'
nix develop --no-write-lock-file -c cabal test shikigami-workers-test -j1 --test-show-details=direct --test-option=--num-threads=1 --test-option=-p --test-option='/workspace retained process profiles/||/workspace coupled provisioning/||/workspace concrete transfer owner/'
nix develop --no-write-lock-file -c just domain-value-types
nix develop --no-write-lock-file -c just keiro-upgrade-audit
python3 -m unittest discover -s tools/domain -p 'test_*.py' -v
python3 tools/style/check_haskell.py
git diff --check
```

The build passes, including the adapted Linux prototype client. Focused suites
pass 8 pure policy cases, 31 serial core PostgreSQL cases (25 Objective and six
profile cases), and 19 worker profile/provisioning/transfer cases. No database
cases are skipped. All 213 revision-boundary and 64 opaque-boundary compiler
checks pass, with positive public clients before the relevant negative probes.
The upgrade inventory audit preserves all 124 frozen sources and 93 release
items, and its 21 mutation tests pass. The 24 domain-tool tests, Haskell style
check and whitespace check pass.

This is focused batch evidence, not M3's final full suites. No workflow body,
generated domain specification, migration SQL or HTTP representation changed.
The policy commitment is unchanged. No new Linux runtime qualification is
claimed for the adapted prototype. Remaining work includes complete semantic
classification, the 32 currently recorded scalar/construction violations, remaining decoder
owners and final-candidate behavioral acceptance. The dependency-native workflow
generation API was verified as `Int`; it must not be described as an opaque ID.

[ADR-107](../../adr/0107-profile-and-objective-corruption-refuses-within-the-owning-transaction.md)
records the accepted owner boundary. FRIC-36 in `docs/friction-log/` records the
compiler gate's per-probe Cabal startup/buffered progress cost and remains logged
for completion-time triage.

A second, separate scope-construction batch is bound by `scope-source.json`
against parent `013a578`. The one-off `WorkspaceScope` already represents the
canonical Git-root locator; it now hides its constructor/root field and exposes
no `Generic` instance. Its single representation is a newtype; `workspaceRoot`
renders a resolved root. The existing
15 worktree discovery, containment, tool dispatch and resource-bound cases pass.
`nix develop --no-write-lock-file -c python3 tests/types/workspace-scope.py`
passes a positive public resolver/renderer client followed by four constructor,
coercion, record-update and Generic refusal clients. The gate builds the agent
library and runs these probes as well as the existing 277 compiler checks, whose
evidence is unchanged by this agent-only abstraction correction. This resolves
the two scope-construction entries from the initial 34 violations; 32 remain.
The filesystem still rechecks mutable paths and symlinks at use. There is no new
serialized format or identity. [ADR-80](../../adr/0080-opaque-checked-values-do-not-expose-generic-construction.md)
records this additional evidence.

The same batch extends the reader's existing unsupported-syntax test to type
families and operator aliases. Both forms now fail with their source path;
ordinary `type instance` adapters and role annotations remain deliberate
non-declaration forms. The 24 tooling tests still pass, and the census is
refreshed with the changed reader hash after the successful coherent build.

A third batch implements the cleanup-owner read boundary and is bound by
`cleanup-source.json` against parent `d5063c1`. `inspectCleanupTx` and
`listWorkspacesTx` now return an owning `Either WorkspaceError`; malformed JSON
condemns the transaction and returns `WorkspaceBindingConflict`, while missing
cleanup rows remain `Right Nothing` and SQL failures stay store failures.
Inspection reapplies the existing preparation invariants (binding digest, user
range and target spelling), and completion inspects retained intent before
changing its completion bit. Maintenance maps corruption to `CleanupRefused`
before another deletion or listing publication. Historical absent ownership and
valid plan bytes are unchanged.

The terminal workflow fixture persists a complete plan through public cleanup,
interrupts after files deletion, reads it back and replays preparation. Mutations
then cover JSON null, negative user identity, invalid target and wrong binding
digest. Inspection/preparation/completion all refuse, ignored inspection refuses
and rolls back an earlier control update, maintenance refuses and scratch stays
present. Restoring the exact original plan completes cleanup and retains that
same plan. Core PostgreSQL controls cover absence, SQL failure and rollback of a
tentative freeze after listing a corrupted complete binding beside a valid member;
repair restores both entries. [ADR-107](../../adr/0107-profile-and-objective-corruption-refuses-within-the-owning-transaction.md)
records this owner boundary. The terminal eligibility SQL and the other workspace
stores retain their separate audit obligations.

The refreshed classification has 263 reviewed keys, 37 explicit violations and
3,726 unreviewed keys out of 3,989. The 15 new reviews include five violations:
cleanup binding digest, two filesystem targets, Unix user identity and maintenance
storage root. Decoder remediation does not certify these primitive domain fields.
The exhaustive coverage and resolved gates must still refuse completion. The
frozen guide remains deferred, and M1/M2/M3 remain open.

Cleanup batch validation on arm64 macOS/GHC 9.12.4 succeeded:

```bash
nix develop --no-write-lock-file -c cabal build all --enable-tests -j1
nix develop --no-write-lock-file -c cabal test shikigami-core-postgres-test shikigami-workers-test --enable-tests -j1 --test-show-details=direct --test-option=--num-threads=1 --test-option=-p --test-option='/workspace transfer store/||/workspace governed parent and child/'
python3 -m unittest discover -s tools/domain -p 'test_*.py'
python3 tools/style/check_haskell.py
git diff --check
```

The selected suites report 7 core PostgreSQL and 14 worker cases passing; the
core fixture supplies disposable PostgreSQL rather than a developer database.
All 24 domain-tool tests pass. The successful full build precedes census refresh.
This is focused M2 batch evidence, not final M3 suite acceptance. No workflow
body, generated identity, migration SQL, dependency bound or HTTP wire format
changed. No additional Linux runtime qualification is claimed.

Census refresh reports 322 modules, 914 declarations and 14 role entrypoints;
independent freshness validation enumerates 3,989 keys with matching current
source, compiled-source fingerprints, interface and tool hashes. Both checker
modes fail at `missing 3726 classification keys` as expected for this incomplete
audit. Neither failure is reported as milestone acceptance.

`nix develop --no-write-lock-file -c just keiro-upgrade-audit` also passes with
21 mutation tests, preserving the frozen inventory and its existing deferral.

A fourth batch implements Directory skip and Sink delivery retained-row checks;
`directory-sink-source.json` binds its four implementation/test files against
parent `bacd466`. These owners store scalar columns rather than JSON. Their
existing `Either Text` pool APIs now execute the same checked transaction readers
as composable clients. Malformed names, run keys or closed statuses return fixed
owner-specific refusals and condemn the transaction. SQL failures retain the
existing store diagnostic; missing rows remain `Right Nothing` or an empty list.
Wire formats, enum spellings, identity domains and public pool signatures remain
unchanged.

The Directory test persists two complete public skips, then mutates one agent
name, run key or stage. Every malformed member refuses the entire list; ignored
refusal rolls back public writes both before and after the read. Repair restores
both original members. An empty reported principal remains admissible diagnostic
evidence under the existing contract; this batch introduces no principal
validation. The indexed drain lookup constrains every parsed field by checked
query parameters and has positive/missing/SQL-failure controls, rather than an
invented corrupt-matching-row case.

The Sink test creates a pending receipt through the workflow and publishes a real
Kawa effect before corrupting its delivered status. Lookup refuses, ignored
refusal rolls back both earlier and later receipt writes, and the publisher
returns `PublishFailed` without another HTTP call or replacement receipt.
Repairing only the status restores the exact original receipt, downstream detail
and send guard. Missing receipts and renamed tables distinguish absence and SQL
failure. Existing Danwa sub-receipt recovery, lifecycle, authorization, receipt
gap and send-suppression cases remain passing.

```bash
nix develop --no-write-lock-file -c cabal test shikigami-core-postgres-test -j1 --test-show-details=direct --test-option=--num-threads=1 --test-option=-p --test-option='/directory store/||/SinkDelivery/'
```

All 24 selected cases pass (four Directory and twenty SinkDelivery). This uses
the suite-owned disposable PostgreSQL fixture with serial execution; no database
cases are skipped. The 24 domain-tool mutation tests, Haskell style check,
whitespace check and upgrade inventory audit with 21 mutation tests also pass.
[ADR-107](../../adr/0107-profile-and-objective-corruption-refuses-within-the-owning-transaction.md)
records this extension of the owner boundary.

The review adds 29 declaration/member classifications: nine explicit unresolved
scalar/identity violations, three exclusions and seventeen compliant entries.
There are now 292 reviewed keys (223 compliant, 23 not applicable, 46 violations)
and 3,697 unreviewed keys. Receipt keys, message/run identity, agent name, ordinal,
sink kind and overloaded downstream detail remain distinct remediation work;
Directory reported-principal/context values also remain explicit violations.
None are exempted merely because they are persisted. M1, M2 and M3 remain open.
No workflow body, generated domain specification, migration, dependency bound or
HTTP representation changed in this batch.

The full `cabal build all --enable-tests -j1` passes on the formatted source,
followed by census refresh: 322 modules, 914 declarations and fourteen role
entrypoints, retaining 3,989 audit keys. Independent `expected_keys` validation
passes current source, compiled-source fingerprints, interfaces and tool hashes.
The classification census hash and the two reviewed source hashes are refreshed;
unrelated semantic verdicts are unchanged. Both checker modes still exit 1 with
`missing 3697 classification keys`. This is intentional refusal of incomplete
audit coverage, not milestone acceptance or final M3 suite evidence.

The next implementation checkpoint is bound by `ledger-workspace-source.json`
against parent `9ab8713`. It includes the ledger and workspace owner changes,
worker/HTTP adapters, public compiler probes, fixture adaptations and the test
suite's direct dependency on the already-used relay-pagination package. No
package bound, dependency version, migration or workflow body changes.

The HTTP acceptance ledger now preserves typed row-decoding results inside its
owning transactions. A complete retained row with an invalid agent/request/run
key or unknown disposition refuses; ignored reads roll back earlier and later
writes. Replay after repair returns the original queued winner. Lists validate
the extra pagination probe before trimming and cursor construction, so corrupt
probe metadata cannot disappear behind a valid returned edge. Reconciliation
rereads the retained request before observing the DLQ. SQL failures remain store
unavailability; absence remains absence. `RunDisposition` has only `RunAccepted`
and `RunDeadLettered`; its SQL/HTTP renderer preserves the exact historical
strings. Public compiler controls accept both constructors and the renderer,
then reject Text, representation coercion, delivery-status substitution and
Generic construction. All 68 opaque-value compiler controls pass.

The ledger, worker-status and HTTP groups pass 6, 10 and 9 cases respectively:

```bash
nix develop --no-write-lock-file -c cabal test shikigami-core-postgres-test shikigami-workers-test shikigami-server-test --enable-tests -j1 --test-show-details=direct --test-option=--num-threads=1 --test-option=-p --test-option='/HTTP acceptance ledger/||/run status composition/||/agent-run HTTP/'
nix develop --no-write-lock-file -c python3 tests/types/opaque-values.py
```

Workspace binding, control, retained file receipt, registered-file and transfer
readers now return `Either WorkspaceError` and condemn malformed owned metadata.
Worker adapters preserve that refusal before provisioning, cleanup, independent
file recovery or transfer. Binding reads reuse the allocator's request/path
predicate and check the identity column and historical origin locator. Transfer
inspection reapplies the existing intent/fence checks. Registered-file lookup
uses left joins and owning consistency checks, retaining a malformed registration
or missing related fact as refusal rather than omission. Existing locator bytes,
allocated identities, private receipts and completed effects remain unchanged.

New core controls persist complete bindings/transfers through public writers,
then corrupt JSON, locator association, control ownership, intent/proof or a
retained successor admission. Inspection and admission refuse, ignored reads
roll back control changes, and exact repair recovers the original binding,
current owner and fence. A genuine SQL failure remains a store failure. The
worker file fixture performs a real accepted edit, loses its acknowledgement,
then mutates its complete registration or an existing generation/path invariant.
The effect remains unresolved, reads refuse, tentative freeze rolls back and
neither files nor modification time change. Repair acknowledges the original
actual without another edit.

A complete binding with a corrupted assignment coordinate used to disappear
behind JSON-based discovery and permit a follow-up's fresh-copy fallback. Both
follow-up and successor discovery now reconstruct exact historical provider
locators from relational session/message coordinates before owned decoding. The
real host fixture proves corruption refuses, no second workspace appears, and
repair recovers the original accepted bytes. Current-owner lookup similarly
decodes admissions before filtering owner and epoch; corruption cannot become
cleanup fallback. SQL terminal-eligibility and prior-assignment settlement
predicates remain separate semantic audit work.

An intermediate broad workspace pass reports 161 worker cases passing. After the
locator and retained-invariant refinements, the focused candidate passes nine
core PostgreSQL cases and 27 worker transfer/file cases:

```bash
nix develop --no-write-lock-file -c cabal test shikigami-core-postgres-test shikigami-workers-test --enable-tests -j1 --test-show-details=direct --test-option=--num-threads=1 --test-option=-p --test-option='/workspace/'
nix develop --no-write-lock-file -c cabal test shikigami-core-postgres-test shikigami-workers-test --enable-tests -j1 --test-show-details=direct --test-option=--num-threads=1 --test-option=-p --test-option='/workspace transfer store/||/workspace concrete transfer owner/||/workspace real file provider/'
```

All database cases use disposable suite fixtures, with no skipped database
acceptance. These are macOS metadata/file/IPC results. Prototype clients have
been adapted for compilation; this checkpoint claims no additional native Linux
containment or cross-build recovery qualification.

Semantic review also adds 112 closed nullary declarations, eighteen explicit
constraint/native/callback aliases and the ledger/control/child records. A
closed-enum verdict certifies only the declared alternatives; it does not certify
surrounding state transitions or permissions. Structural aliases do not certify
nested record members. There are 454 reviewed keys and 51 explicit violations;
no remaining record or scalar is exempted as persistence. The 24 domain-tool
mutation tests pass. M1/M2/M3 remain open, and the frozen guide stays deferred.

The formatted full build passes, including the adapted prototype clients. Census
refresh reports 322 modules, 915 module declarations and fourteen role
entrypoints, with 3,990 total declaration/member keys. Fresh source/compiler
fingerprints, interfaces and tools independently enumerate that exact set.
Only the four substantively rereviewed workspace owner hashes are refreshed;
other classifications retain their matching source identities. The frozen
inventory audit and all 21 upgrade-tool mutation tests still pass.

The same review reads 29 existing checked-value implementations, adding 58
source-supported declaration/payload entries for their exact parser ranges,
private construction, scoped counters and actual technical-locator lifetimes.
No new syntax restriction or entity allocation is inferred for these values.
The total is now 512 reviewed keys (436 compliant, 25 not applicable, 51 explicit
violations), leaving 3,478 unreviewed keys. Both coverage checker modes still
refuse the incomplete audit. Hash freshness and focused runtime checks do not
substitute for the remaining semantic review or M3 acceptance.

The next source snapshot is `workspace-settlement-source.json`, against parent
`e512f9d`. Cleanup eligibility and workspace transfer now inspect complete typed
execution, message, result, session, file/Git effect and process metadata before
using terminal/settlement decisions. An unreadable receipt cannot become zero
pending work, and persisted settlement flags must agree with validated receipts.
The existing execution codec still owns the historical absent-pending-count rule.

Child mapping, workspace listing and live-session attribution are decoded before
filtering by values held only inside JSON. No unreadable child mapping can become
standalone absence, no unreadable storage root can hide a listing member, and no
unreadable session root can permit deletion. With no independent relational
attribution index, these queries conservatively refuse unreadable attribution
anywhere in the scan. Their accumulators are bounded, but query work can cover
all remaining metadata. This is an explicit availability/scan-cost tradeoff,
recorded in ADR-107; no performance qualification or schema migration is claimed.
The valid listing control checks twenty-then-two keyset pages, exact membership,
no duplication and exclusion of a foreign storage root.

Real governed-workflow controls corrupt complete terminal execution state (null,
missing required snapshot, negative pending count), a settled file receipt, and
a live session binding. Ignored refusals roll back an earlier freeze; cleanup
leaves files/scratch and creates no cleanup plan. Exact repair restores the
original eligibility; repairing a live session still refuses cleanup. Real
follow-up admission refuses corrupt prior message/result fields without a fresh
allocation, then reuses original accepted bytes after repair. Child-attribution
controls likewise refuse and roll back, then recover the original mapping.

The formatted candidate passes all 22 selected core PostgreSQL cases and all 162
worker workspace cases on arm64 macOS/GHC 9.12.4, with serial disposable database
fixtures and no skipped cases:

```bash
nix develop --no-write-lock-file -c cabal test shikigami-core-postgres-test shikigami-workers-test --enable-tests -j1 --test-show-details=direct --test-option=--num-threads=1 --test-option=-p --test-option='/workspace/'
```

The 24 domain-tool mutation tests, Haskell conventions and whitespace checks also
pass. No Agent/Flow workflow body, durable identity formula, generated domain,
HTTP representation, migration or dependency changes. This remains a semantic
audit checkpoint; exhaustive classification and final M3 acceptance stay open.

The coherent full `cabal build all --enable-tests -j1` passes, followed by
census refresh: 322 modules, 915 module declarations, fourteen entrypoints and
3,990 total keys. Independent source/interface/tool freshness validation passes.
Only the five substantively rereviewed owner source hashes are renewed; the
512 classifications and 51 unresolved scalar violations are unchanged. Both
classification checker modes still reject the 3,478 missing keys.

The decision-coordinate candidate is bound by
`decision-coordinates-source.json`, against parent `af76f1b`.
`DecisionSlotLabel` enforces the existing ASCII slot grammar;
`DecisionPreparationId` preserves the original canonical commitment under
`shikigami.prepared-decision/1` through preparation, outcome and actual-call
reports. `DecisionGeneration` preserves the former nonnegative Natural JSON
domain, including numbers above host Int range. The runtime still supplies Int;
no new ceiling or entity allocation is inferred. All three constructors are
private and non-Generic.

The preparation now retains native Keiro `WorkflowId`. Its explicit codec
adapter preserves the historical Text representation, including compatibility
coordinates and omitted optional policy. Complete valid preparation/outcome
controls round-trip and retain exact bytes, then reject substituted labels,
digests, negative or fractional generations. The fixed commitment vector keeps
the original domain and canonical hash input. Native identity syntax is not
narrowed by this adapter. Malformed labels and unproducible commitments were not
produced by the admitted runtime; this is not another first-release identity
reset. ADR-41 records this representation of the existing preparation contract.

The formatted candidate passes 37 unit cases (contracts, model admission and
runner) and 26 PostgreSQL cases (actual-attempt evidence and durable typed
workflows), with serial disposable databases and no skipped cases:

```bash
nix develop --no-write-lock-file -c cabal test shikigami-core-test shikigami-core-postgres-test --enable-tests -j1 --test-show-details=direct --test-option=--num-threads=1 --test-option=-p --test-option='/typed decision contracts/||/decision model admission/||/governed decision runner/||/durable decision evidence/||/durable typed decisions/'
nix develop --no-write-lock-file -c python3 tests/types/opaque-values.py
```

All 81 public compiler controls pass. A public-client positive control accepts
the factories and native WorkflowId projection before constructor, Text/Natural
coercion, unrelated digest/counter substitution and Generic bypass probes refuse.
The workflow cases cover interrupted preparation/result recovery, committed
result reuse, pinned pending implementation/derivation, provider call counts,
permission intersection and evidence failure. Their passing results do not
certify the native workflow declaration gate or unreviewed evidence-reader
rollback boundaries. The 24 domain-tool mutation tests pass.

The coherent full build passes. Refreshed census and independent freshness checks
report 322 modules, 918 module declarations, fourteen entrypoints and 3,996 keys.
Semantic review renews the changed Contract/Flow owner entries, resolves six
recorded decision-coordinate violations and adds their six declaration/payload
entries. A source review adds 177 typed composition entries and six entries for
the existing FullCommit and Natural-backed duration/concurrency values. These
composition verdicts cover preservation of named members and sum/product shapes;
they do not certify nested scalar invariants, identity lifetimes or surrounding
authorization transitions. The measurement codec tests are existing source
references, not a claim that unchanged groups were rerun in this checkpoint.

The same review records 23 explicit unresolved owned-profile findings: distinct
resource units, permission axes, signer/retention/correlation keys, computed
profile/payload commitments and the supported attestation schema. The profile
limits are consumed directly in compliance and provider execution as well as
converted by SelectionStore; they have no blanket boundary-DTO exemption.
No signing algorithm, registry, numeric ceiling or digest scheme is invented.

There are now 726 reviewed keys (633 compliant, 25 not applicable, 68 explicit
violations) and 3,270 missing keys. Both classifier modes still reject incomplete
coverage. All M1/M2/M3 milestones remain open and the frozen guide stays deferred.
The declaration gate must run after the implementation commit because its
scaffold step requires a clean committed Haskell layer; its result will be
recorded separately before the next implementation batch.

The native `just keiro-gate af76f1b` passes on committed candidate `400cdc0`,
including ten language-6 workspace members, unchanged scaffold output and
successful generated conformance. Exact native reports are retained in
`decision-coordinates-keiro-diff.json` (no findings, no breaking change) and
`decision-coordinates-replay-impact.json` (`replay-neutral`), with command and
candidate identity in `decision-coordinates-keiro-gate.json`. No patch or
first-release exception is needed: journal step shape, labels and admitted
result meaning are unchanged, and the complete codec/provider controls qualify
the opaque representation separately.

Committing and running the gate rebuilds the Git-version-bearing dependency
closure, which changes local interface fingerprints without changing audited
source. A final coherent build/census refresh follows the gate before renewing
the classification's census hash; no semantic verdict is renewed solely by
copying interface hashes.

The post-gate full build and census refresh pass. Source/interface/tool freshness
independently enumerates the same 3,996 keys; all 726 semantic source identities
still match, so only the census hash is renewed. Generated conformance reports
156 passing checks. The upgrade inventory audit and its 21 mutation tests pass,
retaining all 124 frozen sources and 93 release items.

The next owner candidate is `decision-evidence-source.json`, against parent
`2711a19`. Decision evidence readers now retain complete SQL terminal envelopes
and typed invocation metadata until their owning transaction validates them.
SQL JSON status extraction no longer hides a malformed envelope as unresolved
absence. Correlation remains native `CallCorrelationId`; invocation/run columns,
input commitment, model, pinned profile and facts/provider-column associations
are checked. Decision facts retain the existing unknown-lineage convention.
Historical profile data is checked for integrity without reapplying lifecycle.
Original raw invocation/provider JSON remains the output representation after
validation; no unsupported provider decoder or new entity identity is introduced.

Twenty-three corruption cases start from two complete public attempts, a valid
sibling and a successfully finalized report, then mutate a terminal, model,
correlation, input commitment, invocation or pinned profile. Reports, pages,
finalization, factual acknowledgement and fresh admission refuse. Ignoring
composable read refusals rolls back both earlier and later tentative cache
writes. Bad earlier spending also rolls back a tentatively inserted distinct
invocation. Exact repair recovers the original report, receipt IDs, timestamps,
provider JSON and idempotent acknowledgement. No stale cached report is used to
hide corrupt source metadata. Missing-run and genuine SQL-failure controls keep
separate outcomes. Failed/unknown terminals without provider evidence remain
valid uncertainty, not corruption or zero spending.

A real Handan/provider check stops the durable workflow after preparing the
second decision, removes a required field from the retained first invocation,
and probes the actual pending program runner. The owner refuses before another
provider request or expectation can be admitted. After exact repair, the same
pending workflow resumes under its original preparation and retains its first
actual call and invocation bytes. This probe occurs before the journaled result
step; it does not claim automatic recovery from an already committed failure
outcome.

The formatted candidate passes 62 core PostgreSQL cases (decision owners,
workflows and workspace transfer) plus 22 worker transfer/cleanup cases. An
additional valid failed/unknown-terminal control then passes with the full
35-case decision-evidence and 17-case workflow groups (52 PostgreSQL cases):

```bash
nix develop --no-write-lock-file -c cabal test shikigami-core-postgres-test shikigami-workers-test --enable-tests -j1 --test-show-details=direct --test-option=--num-threads=1 --test-option=-p --test-option='/durable decision evidence/||/durable typed decisions/||/workspace transfer store/||/workspace governed parent and child/||/workspace concrete transfer owner/'
nix develop --no-write-lock-file -c cabal test shikigami-core-postgres-test --enable-tests -j1 --test-show-details=direct --test-option=--num-threads=1 --test-option=-p --test-option='/durable decision evidence/||/durable typed decisions/'
nix develop --no-write-lock-file -c python3 tests/types/opaque-values.py
```

All 82 public compiler controls pass, including the native correlation projection
positive control and refusal to flatten it to Text implicitly. The 24 domain-tool
mutation tests, Haskell conventions and whitespace checks pass. Database cases
use serial suite-owned disposable fixtures with none skipped.

The same candidate forces Boolean and bounded-list fold payloads for workspace,
session-root and child attribution scans. A strict outer Either alone does not
force its payload. Existing paging, corruption, rollback, cleanup and transfer
controls pass; this bounds only the Haskell accumulator, with no full-query or
native containment performance claim. No Agent/Flow body, workflow label,
durable identity formula, migration, dependency or valid wire representation
changes. Full build, declaration refresh and semantic source reconciliation
follow the implementation commit; exhaustive M1/M2/M3 acceptance remains open.

The full build passes on committed source `92fdf2e`. Census refresh and independent
freshness checks report 322 modules, 922 module declarations, fourteen entrypoints
and 4,022 keys. The four substantively reviewed owner source hashes are renewed.
The classification adds 33 entries for the private checked invocation/input
commitment, concrete SQL/terminal transfer adapters, native call correlation,
ephemeral store handle and exact output/cache fields. Each adapter identifies
its producer, typed conversion and consumer; no persisted domain record receives
a blanket DTO exemption.

There are 759 reviewed keys: 664 compliant, 27 not applicable and 68 explicit
violations, leaving 3,263 missing keys. Report format/completeness are derived
output/cache values; no report decoder, cached fallback or domain authorization
consumes those primitive summaries. Typed calls and validated source metadata
remain the authority. This is a concrete producer/consumer boundary, not a
correction based only on representation or missing platform tests.

The complete classifier still refuses missing coverage in both modes. These
focused results qualify the named macOS read boundaries and do not close M1,
M2, M3, the remaining policy scalars or native Linux/cross-build qualification.


## Scoped profile quantities and permissions

The source candidate is bound by `profile-policy-source.json`, relative to parent
`84c3f2b`, on arm64 macOS with GHC 9.12.4. Profile resource limits now retain
independent units in private checked `Ceiling scope amount` values. Each policy
permission retains its own scope and encodes as the existing boolean. Key names,
algorithm names and provider correlation-field keys retain their exact Text bytes
behind separate nominal scopes; signing remains unimplemented.

Negative ceilings, including retention days, now refuse when a complete profile
is decoded. Six resource quantities and retention retain their Int ranges; cost
remains unbounded Integer. Zero and absent limits stay distinct. This deliberately
narrows previously unchecked invalid metadata; no journal, profile commitment or
pinned content is rewritten, and invalid historical policy is not claimed to
resume. The runtime retry seam adds one in Integer before applying the native
cap, fixing the maximum-Int overflow that previously disabled retries.

```bash
nix develop --no-write-lock-file -c cabal test shikigami-core-test -j1 --test-show-details=direct --test-option=-p --test-option='/attestation contracts/||/governed decision runner/||/ExecutionSelection/||/a pinned profile/'
nix develop --no-write-lock-file -c cabal test shikigami-core-postgres-test -j1 --test-show-details=direct --test-option=--num-threads=1 --test-option=-p --test-option='/profile resolution/||/durable decision evidence/||/run evidence/||/durable typed decisions/||/ExecutionSelectionWorkflow/||/profile/'
nix develop --no-write-lock-file -c python3 tests/types/opaque-values.py
python3 tools/style/check_haskell.py
git diff --check
```

All 77 selected unit cases, 131 selected PostgreSQL cases and 92 public compiler
controls pass. The unit cases include valid complete profiles before each
single-field negative mutation, host-Int overflow refusal, unbounded cost,
zero/unlimited distinction, opaque-name preservation, the unchanged pinned
profile/payload bytes and the maximum-Int actual provider retry. The PostgreSQL
cases include negative pinned call/duration/retention values through the existing
multi-call corruption fixture: public owner reads refuse, ignored refusals roll
back earlier/later writes, tentative invocation insertion rolls back, and exact
repair recovers original identities and report bytes. Existing decision workflows,
profile resolution, execution selection and compliance cases remain passing.
Compiler controls start from compiling public factories and reject constructor,
raw/scoped coercion, unit/permission substitution and Generic bypasses.

No workflow source, label, identity formula, migration, dependency or valid HTTP
representation changes in this batch. The existing native gate reports remain
historical applicable evidence. The next coherent full build/census refresh must
reconcile source-bound classification before using these results as audit
coverage. M1/M2/M3 remain open.


The coherent full `cabal build all --enable-tests -j1` and schema-2 census pass
on `80f36e6`, with 323 modules, 925 module declarations, fourteen executable
entrypoints and 4,027 audit keys. The source snapshot hashes match. Semantic
rereview of all seven changed existing owner modules preserves their applicable
entries, resolves 17 explicit policy violations and classifies the five new
private scalar keys. Classification now covers 764 entries: 686 compliant,
27 not applicable and 51 violations. All 3,263 unreviewed keys remain missing;
both checker modes correctly refuse completion. No blanket exemption or hash-only
renewal was applied. All 24 domain-tool mutation tests and the 124-source/93-item
upgrade inventory audit with its 21 mutation controls pass. Frozen source hashes,
release identities and the deferred guide disposition remain unchanged.


## Canonical attestation commitments and supported schema

`attestation-commitments-source.json` binds the arm64 macOS/GHC 9.12.4 source
candidate to parent `5ed80e8`. Profile and payload commitments are private,
non-Generic values with checked SHA-256 parsers, renderers and unchanged
canonical producers. The supported schema is closed at the existing
`shikigami.agent-run-attestation/1` literal. Unknown versions and malformed
commitment strings refuse complete-document decoding; retained bytes are not
normalized or rewritten. This narrows invalid/unsupported admission without
using a first-release exception or claiming unsupported historical replay.

```bash
nix develop --no-write-lock-file -c cabal test shikigami-core-test -j1 --test-show-details=direct --test-option=-p --test-option='/attestation contracts/||/a pinned profile/'
nix develop --no-write-lock-file -c cabal test shikigami-core-postgres-test -j1 --test-show-details=direct --test-option=--num-threads=1 --test-option=-p --test-option='/profile resolution/||/durable decision evidence/||/run evidence/||/durable typed decisions/||/ExecutionSelectionWorkflow/||/profile/'
nix develop --no-write-lock-file -c python3 tests/types/opaque-values.py
python3 tools/style/check_haskell.py
git diff --check
```

All 50 unit, 133 PostgreSQL and 103 public compiler controls pass. The complete
profile reference, payload and envelope first round-trip validly, then reject a
single malformed commitment or unsupported schema member. The original pinned
canonical payload bytes and digest remain unchanged. Public-client factories
compile before constructor, raw/cross-domain coercion and Generic bypasses are
rejected. The SQL profile test starts with a valid resolved profile, injects a
malformed stored digest, checks the explicit owner diagnostic and unchanged
complete row, then proves exact repair recovers the original row/profile.
Missing-row behavior remains distinct; an actual missing SQL relation produces
query context rather than a decoder diagnostic. That read-only store retains
its existing IO-exception seam. Decision-evidence composable reads instead
condemn the transaction for an invalid pinned reference, preserving all earlier
rollback and original-row recovery assertions.

Profile content hashing moved behind its private type; the envelope facade uses
that same computation. Its input and canonical encoder are unchanged. Syntax
checks do not confer trust, establish reference/content binding on their own,
or implement signing. No workflow source, durable identity formula, migration,
dependency or valid HTTP representation changes. A coherent full build and
census reconciliation follow this source checkpoint; all milestones stay open.

Review of `Attestation.Resolve` also found that a well-formed candidate with a
matching hash can disagree with its reference's profile id/version or the
requested lookup coordinates. That ownership gap remains explicit pending its
own construction/owner batch; digest syntax tests do not certify it.


The full `cabal build all --enable-tests -j1` succeeds on `5a63443`; the refreshed
census has 323 modules, 925 module declarations, fourteen entrypoints and 4,026
keys. All snapshot/source/compiler/interface/tool identities are fresh. Semantic
rereview of Profile, Envelope, Resolve and Provider.Call renews only their
reviewed entries, resolves the six old commitment/schema findings, and migrates
the two private digest representation keys. SchemaVersion's former primitive
member disappears because the supported vocabulary is now closed. The profile
lookup function wrapper is explicitly excluded as an ephemeral injected handle.
ResolvedProfile's whole-binding entry is corrected to an explicit violation for
the newly found coordinate mismatch, rather than retaining its earlier
composition-only verdict.

Classification contains 764 entries: 690 compliant, 28 not applicable and 46
violations, with 3,262 missing keys. Both checker modes correctly refuse those
missing keys; no milestone is complete. The unchanged frozen 124-source/93-item
upgrade inventory and all 21 mutation controls pass. Earlier 24 domain-tool tests
remain applicable because neither the checker nor census tools changed. The guide
stays deferred and its frozen hashes/release identities are preserved.


## Checked profile snapshots and exact lookup ownership

`profile-snapshot-source.json` binds this source candidate to parent `4af3303`
on arm64 macOS/GHC 9.12.4. `ResolvedProfile` is private and non-Generic. Its
factory computes a reference from complete content; its refining constructor
and complete JSON decoder check id, version and content commitment together.
`ResolvedProfileView` is the explicit read/JSON transfer record. Copying or
modifying a view cannot construct an admitted snapshot without that check.
The old required `profile`/`ref` object shape is retained byte for byte.
Historical withdrawn/expired facts decode without reapplying live admission.

SQL lookup checks the retained body's identity against its relational row;
lookup also checks every returned candidate against the requested name and
optional revision. `ProfileStore` returns an explicit existing policy refusal
or complete checked candidates. Malformed/incorrectly attributed metadata
raises `ProfileMetadataRefusal`, separate from native SQL exceptions and missing
rows. The five serialized `ProfileResolutionError` alternatives stay unchanged;
no new policy-failure outcome is introduced into an existing journal step.
The SQL reader still returns the existing MutableProfile outcome for a changed
content commitment. Repair permits the same read to recover; this does not claim
automatic recovery after a separately committed permanent outcome.

```bash
nix develop --no-write-lock-file -c cabal test shikigami-core-test -j1 --test-show-details=direct --test-option=-p --test-option='/attestation contracts/||/governed decision runner/||/ExecutionSelection/||/a pinned profile/||/decision model admission/'
nix develop --no-write-lock-file -c cabal test shikigami-core-postgres-test -j1 --test-show-details=direct --test-option=--num-threads=1 --test-option=-p --test-option='/profile resolution/||/durable decision evidence/||/run evidence/||/durable typed decisions/||/ExecutionSelectionWorkflow/||/profile/'
nix develop --no-write-lock-file -c python3 tests/types/opaque-values.py
python3 tools/style/check_haskell.py
git diff --check
```

All 91 unit, 139 PostgreSQL and 106 compiler controls pass. Positive complete
snapshot encoding matches the historical object shape. Changed references,
including well-formed canonical hashes, fail construction/complete decoding.
A Generic inspection view remains usable while constructor, coercion and
Generic promotion bypasses fail after public positive controls.

Four fresh database corruption controls recompute the claimed commitment over
foreign names, foreign revisions, incomplete bodies and negative ceilings. This
rules out a hash mismatch as the sole refusal cause. Tests preserve the complete
corrupt row, restore exactly the original body/hash and recover the original
snapshot and complete row. A two-version control proves a valid first candidate
cannot hide a malformed second one, through both direct store lookup and the
resolver. Injected callback candidates also cannot substitute a different name
or requested revision. Existing missing, SQL failure, mutable content, expiry,
withdrawal, ambiguous lookup, decision/workflow/selection/compliance and coupled
rollback cases remain passing.

Normal SQL writes already reject foreign identity under migration 0004's
`sanctioned_execution_profiles_content_identity` check. The relevant corruption
controls first assert that rejection and unchanged original rows, then remove
only the example database's guard to inject retained corruption. Production
migrations and constraints are unchanged. This qualifies the reader under that
injected loss; it does not claim ordinary writes can bypass the existing guard.
The direct read-only store mutates no domain state; composable decision and
execution consumers retain their owning transactional refusal checks.

No label, child identity, hash input or valid journal payload changes. Agent
workflow/conversation imports and the pure refusal-rendering projection change
to the private snapshot API, so native evolution qualification against
`4af3303` is still required before this checkpoint is accepted. Coherent full
build/census reconciliation follows it. All milestones remain open.


The native `just keiro-gate 4af3303` passes on `e7aa4ae`. Retained reports are
`profile-snapshot-keiro-diff.json` (no findings),
`profile-snapshot-replay-impact.json` (`replay-neutral`) and
`profile-snapshot-keiro-gate.json` (command/candidate/base/platform and limits).
All ten members remain declared at language 6 and all 156 generated conformance
checks pass. These native reports do not certify invalid-metadata admission;
that narrower decoder domain and complete valid-byte controls are qualified
separately above, without a first-release waiver.

The subsequent full `cabal build all --enable-tests -j1` and schema-2 census
pass on `e7aa4ae`: 323 modules, 928 module declarations, fourteen entrypoints and
4,034 keys. All source/snapshot/compiler/interface/tool identities match. The
semantic rereview covers all eleven changed owner modules. The former public
snapshot fields move to the explicit transfer view; the private wrapper seals
their binding. The ownership violation is resolved and the new wrapper/view/data
refusal keys are classified, with no blanket persistence exemption or hash-only
renewal. Classification now covers 772 keys: 699 compliant, 28 not applicable,
45 violations and 3,262 missing. Both checker modes correctly refuse missing
coverage. The 124-source/93-item frozen upgrade inventory and 21 mutation controls
pass; the earlier unchanged-tool 24-case result remains applicable. M1/M2/M3 and
the guide disposition remain open/deferred.


## Native acceptance identities and checked payload commitments

`ledger-values-source.json` binds the arm64 macOS/GHC 9.12.4 candidate to parent
`754ae61`. The acceptance record now retains native Keiro WorkflowId and PGMQ
MessageId, a private checked PayloadFingerprint and nominal CallerAttribution.
SQL, Relay cursor, HTTP, CLI and logging adapters unwrap at their transport
seams. No workflow/request identity formula, native allocation or valid wire
value changes; caller text is captured exactly, with no invented local grammar.

Before compiling the edited ledger, the retained pre-change compiled producer
was queried directly:

```bash
nix develop --no-write-lock-file -c cabal exec -- ghc -ignore-dot-ghci -package shikigami-core -e 'import qualified Shikigami.AgentRun.Ledger as Ledger' -e 'import qualified Data.Aeson as A' -e 'print (Ledger.payloadFingerprint A.Null, Ledger.payloadFingerprint (A.object []))'
```

The outputs were `148bdfa9-7596-5319-a197-ead64880df40` for null and
`417e0a20-e3f9-59fc-8d1f-f51ab83a4318` for the empty object. Those literal bytes
are pinned in AgentRunValueSpec. The new fingerprint parser requires canonical
lowercase UUIDv5 with the RFC 4122 variant, matching the unchanged URL-namespace
producer over encoded payload bytes. It allocates no entity and is not converted
to TypeID. Existing malformed/unproducible stored strings now refuse; they are
not normalized or overwritten. No first-release compatibility waiver is used.

```bash
nix develop --no-write-lock-file -c cabal test shikigami-core-test -j1 --test-show-details=direct --test-option=-p --test-option='/acceptance ledger values/'
nix develop --no-write-lock-file -c cabal test shikigami-core-postgres-test shikigami-workers-test shikigami-server-test -j1 --test-show-details=direct --test-option=--num-threads=1 --test-option=-p --test-option='/HTTP acceptance ledger/||/run status composition/||/agent-run HTTP/'
nix develop --no-write-lock-file -c python3 tests/types/opaque-values.py
python3 tools/style/check_haskell.py
git diff --check
```

All 3 value tests, 6 core PostgreSQL acceptance cases, 10 worker status cases,
9 HTTP cases and 115 compiler controls pass. The selected consumers were first
listed (25 nonzero cases across the three suites). Native queue identity is
compared to the actual PGMQ message witness, and workflow identity to the
unchanged runJobWorkflowId producer. Existing HTTP pinned id, status, cursor,
URL, replay, conflict and attribution behavior remains passing.

The complete public acceptance corruption fixture now also injects an empty
fingerprint, another UUID version and a non-RFC variant. Direct/by-id reads,
full pages and discarded page probes, disposition reconciliation and duplicate
acceptance refuse. Ignored composed refusals roll back earlier/later writes;
tentative duplicate sends do not increase the original queue length. Exact
repair recovers the original request, caller, timestamp, run key and native
message id. Public factories/native projections compile before constructor,
UUID/Text coercion, Generic bypass and implicit native-id flattening controls.

No workflow body, label, durable identity formula, migration, dependency or valid
HTTP representation changes, so no new native workflow/migration/HTTP-representation
gate is required beyond the actual HTTP behavioral suite. Coherent full build
and census reconciliation follow this source checkpoint; all milestones stay
open. The prior native profile gate remains retained as applicable evidence.


The full `cabal build all --enable-tests -j1` and refreshed schema-2 census pass
on `f556e24`: 323 modules, 930 module declarations, fourteen entrypoints and
4,038 keys. Snapshot/source/compiler/interface/tool identities match. Semantic
rereview covers Ledger, Status, the HTTP handler and operator Runs adapter.
The four explicit ledger findings are resolved, and the new fingerprint and
attribution declaration/representation keys are classified. Classification now
has 776 entries: 707 compliant, 28 not applicable and 41 violations, with all
3,262 missing keys still explicit through checker refusal. Both checker modes
correctly fail incomplete coverage. The frozen 124-source/93-item inventory and
21 mutation controls pass; unchanged-tool 24-case evidence remains applicable.
The guide and all milestones remain open/deferred.

FRIC-37 records the repeated closure build caused by embedded Git metadata at
required source checkpoints. Source is committed before the final coherent build
and the census follows all Cabal gates; a later evidence-only commit does not
claim a new executable test candidate. This preserves freshness while avoiding
avoidable repeated builds. Friction remains to be triaged at plan completion.


## Reported directory claims and advisory refusal context

`directory-claims-source.json` binds this arm64 macOS/GHC 9.12.4 candidate to
parent `2d832dc`. RunSkip retains a private nominal ReportedPrincipalClaim,
distinct from admitted principal identity. The total capture/renderer and
newtype JSON codec preserve every reported byte, including malformed and empty
claims that explain refusal. Producers wrap at the scheduler, stream/event
admission and queue-drain evidence boundary; SQL and logging keep their old text.
No directory admission, identity namespace, key derivation or valid wire value
changes, and no first-release exception is used.

Source review corrects RunSkip.detail's old domain-value violation to an
incidental diagnostic exclusion. Scheduler supplies `schedule`; Consumer's
prepareTrigger supplies `stream`/`event`; drain recording renders the already
chosen RunRouteKind. Directory.Store persists/reads the advisory text and
worker reporting logs it. AgentRun.Status classifies a skip from its presence
and reason, without selecting a route from detail. SQL deduplication uses the
typed stage/run key. This is a specific producer/consumer explanation, not a
persistence exemption; principal claims and the other domain coordinates retain
their independent obligations.

```bash
nix develop --no-write-lock-file -c cabal test shikigami-core-test -j1 --test-show-details=direct --test-option=-p --test-option='/reported directory claims/'
nix develop --no-write-lock-file -c cabal test shikigami-core-postgres-test shikigami-workers-test -j1 --test-show-details=direct --test-option=--num-threads=1 --test-option=-p --test-option='/directory store/||/Scheduler/||/StreamInbox/||/run status composition/'
nix develop --no-write-lock-file -c python3 tests/types/opaque-values.py
python3 tools/style/check_haskell.py
git diff --check
```

The value control, all 4 core PostgreSQL directory cases, all 34 selected worker
cases and 118 public compiler controls pass. The consumers were first listed
(38 nonzero cases). Complete SQL round trips still preserve the intentionally
invalid legacy claim and empty principal text. Corrupt stage/name/key metadata
still refuses complete lists and drain reads, rolls back ignored earlier/later
writes and recovers the exact original rows. Scheduler, inbox and drain behavior
and atomic skip publication remain passing. Public claim capture compiles before
constructor, coercion and Generic bypass controls.

The private LoadState remains its previously reviewed explicit outbound SQL
transfer record, from loadStateRows to upsertLoadStateStatement; no domain
permission is inferred from that DTO. No workflow body, durable identity,
migration, dependency or valid HTTP representation changes. The full build and
fresh census pass on `4983d4c`: 323 modules, 931 declarations and 4,040 keys.
The reviewed classifications total 778 (710 compliant, 29 excluded, 39 known
violations); both modes correctly refuse 3,262 missing keys. All milestones and
the deferred guide disposition stay open.

## Receipt locators and retained transport vocabulary

`sink-locators-source.json` binds the source candidate to parent `1c66762` on
arm64 macOS/GHC 9.12.4. ReceiptKey and SinkMessageId are distinct private,
non-Generic coordinates. Keiro IntegrationEvent explicitly defines messageId as
opaque application text. Capture preserves existing producer bytes, including
workflow-owned UUIDv5 OutboxId derivation and legacy step-shaped message ids.
Parent receipt keys remain the exact message id; substep keys append `#` and the
existing substep. No new entity or identity namespace is allocated.

DeliveryReceipt retains the existing SinkKind enum through SQL. Unknown retained
kind labels join unsupported status labels at the existing typed read refusal;
lookup condemns the owning transaction, including callers that ignore the value.
The complete corruption control prevents another actual HTTP send, rolls back
earlier/later receipt writes, preserves the original row and recovers the same
send guard after exact repair. Missing rows and real SQL errors remain distinct.

The five SinkIntent unit cases pass, including opaque-coordinate byte controls,
the pinned complete intent wire fixture and integration-event identity. All 20
SinkDelivery PostgreSQL cases pass, including ChannelEgress, authorization,
conversation adoption/retry, receipt gaps and unknown terminal reconciliation.

```bash
nix develop --no-write-lock-file -c cabal test shikigami-core-test -j1 --test-show-details=direct --test-option=-p --test-option='/SinkIntent/'
nix develop --no-write-lock-file -c cabal test shikigami-core-postgres-test -j1 --test-show-details=direct --test-option=--num-threads=1 --test-option=-p --test-option='/SinkDelivery/'
nix develop --no-write-lock-file -c python3 tests/types/opaque-values.py
python3 tools/style/check_haskell.py
git diff --check
```

No workflow body, migration, dependency or valid wire representation changes.
ADR-22 records the coordinate meaning. Source tracing corrects the old runId
finding: current agent, conversation and flow producers render their Kioku
SessionId there, independently of the workflow-owned outbox message id. This
correction leaves the primitive reference violation explicit. Receipt detail,
agent and ordinal findings remain open for their own producer/consumer review.
All 123 public compiler controls pass: public factories compile before generic,
coercion and cross-coordinate substitution refusals. The coherent full build and fresh census on `21379a2`
reconcile all three findings and the four private coordinate keys. All plan
milestones remain open.

## Explicit workspace admission freeze

`workspace-freeze-source.json` binds the source candidate to `281a4e8` on arm64
macOS/GHC 9.12.4. WorkspaceControl.frozen retains closed FreezeState rather than
an interchangeable Bool. Its codec preserves exact false/true bytes; other JSON
kinds refuse. SQL remains the existing boolean column/projection. Conditional
owner and transfer checks compare AdmissionOpen/AdmissionFrozen; the independent
supervisor projects the same cancellation observation at its boolean boundary.
The factual read/recovery gates and existing effect settlement remain separate.

The exact selected tests were listed first: 9 core unit, 17 core PostgreSQL and
79 worker cases. All 105 pass serially, including tentative freeze/ignored-read
rollback, owner transfer, successor/follow-up admission, cleanup, frozen write
refusal, process cancellation, independent recovery and historical file/Git
receipts. These are macOS database/instrumented provider controls, not new Linux
containment or supervisor qualification. Three focused public compiler controls
pass: both states compile, while Bool substitution and coercion fail. Those two
negative controls are also added to the final opaque-value suite; the prior
123-control sink result remains identified separately.

```bash
nix develop --no-write-lock-file -c cabal test shikigami-core-test shikigami-core-postgres-test shikigami-workers-test -j1 --test-show-details=direct --test-option=--num-threads=1 --test-option=-p --test-option='/workspace retained process policies/||/workspace transfer store/||/workspace process profile store/||/workspace governed parent and child/||/workspace process registrations/||/workspace Git registrations/||/workspace real file provider/||/workspace accepted process supervisor/'
python3 tools/style/check_haskell.py
git diff --check
```

Style and whitespace checks pass. ADR-63 records the admission/factual recovery
separation. No core Agent/Flow workflow body, migration, dependency, identity
formula or valid wire representation changes. The coherent full build and fresh
census on `21379a2` pass: 323 modules, 934 declarations and 4,045 keys. Freeze
and the three receipt-coordinate/kind findings are resolved; all five new scalar
keys are classified. All milestones and the guide disposition remain open.


## Review of the remaining sink declaration surface

Source/consumer review adds the 55 previously missing declaration/member keys in
Sink.Intent, Sink.Types and Sink.Permission. The 32 compliant entries cover
explicitly named composition, native time and process handles, header adapters
and behavior-content transfer. They do not certify nested payloads or grant
lifetime. Six exclusions identify diagnostic text after an outcome is chosen.
Seventeen explicit violations cover agent/session references, ordinals,
recipient/conversation/activity identities, sub-receipt function signatures and
the downstream/enqueued reference payloads. These were previously unreviewed;
recording them does not undo the four independently remediated fields.

The Danwa source checkout now has nominal ids, whereas this repository's actual
build pins `mori://shinzui/danwa` revision
`301bc1b381fb1baa253b9ba5fce5735e6d0a8ca9`. Reading that exact revision's
`danwa-api/src/Danwa/Conversation/Api.hs`,
`danwa-api/src/Danwa/Message/Api.hs` and client captures establishes Text ids in
the used API (symbol artifact URI pending). No dependency change or inferred
current-checkout API is used. Existing transport text must remain externally
owned at this boundary during the next representation-preserving batch.

The source-bound classification totals 838 keys: 751 compliant, 35 excluded and
52 explicit violations. Both normal and require-resolved modes correctly fail
only at 3,207 missing keys after source/build/tool/entry validation. The frozen
124-source/93-item inventory and 21 mutation controls pass; the unchanged-tool
24-case result remains applicable. M1/M2/M3 and the guide deferral remain open.

## Native sink sessions, checked ordinals and receipt ownership

`sink-coordinates-source.json` binds the arm64 macOS/GHC 9.12.4 source candidate
to `82cf413`. Enqueue APIs, flow/attention environments, SinkIntent, SinkContext
and receipts now retain the existing AgentName and Kioku SessionId. The actual
agent, conversation, flow and practice-review producers pass their admitted
native values. There is no new allocation, TypeID prefix, identity derivation,
clock admission or legacy inference. SinkOrdinal is private/non-Generic with
number JSON and the exact existing 0..2147483647 receipt int4 range. Incidental
producer Int indices refine once before intent construction. SQL cannot silently
narrow an oversized value.

Kioku parsing, native KindID UUIDv7 version/variant validation and canonical
rendering are separate checks. Prefix confusion, malformed labels, UUIDv4,
wrong variant, negative/overflow/fractional ordinals and empty agent names refuse
at complete queued decode or retained row decode. The native library's
clock-dependent check is not applied to historical identity. The test component
explicitly exposes the existing mmzk-typeid dependency to construct invalid
native UUID witnesses; no runtime version, pin or bound changes.

`sink-session-wire-before.json` was captured from the pre-change compiled
producer on source `21379a2` (the executable source is unchanged on parent
`82cf413`). Its exact encoder bytes, excluding the output newline, hash to
`1f80c8357889bce0c377aaaabbf19bb66b286709c214c4a1c3054d3383575c5b`.
The current complete intent golden matches them exactly. Earlier fixture-only
`run_1`/`run-1` labels were not native sessions and are now negative decoder data;
the golden uses the already admitted native session fixture. Source-event
idempotency keys and outbox recipes retain their original valid native bytes.
This is not a first-release identity reset or an opaque-history compatibility
claim for malformed coordinates.

Publication, conversation substep adoption and terminal reconciliation use
lookupDeliveryFor/Tx with a ReceiptContext from the fully decoded queued intent.
All five coordinates must match: message id, session, agent, ordinal and kind.
Malformed rows retain the existing corruption refusal. Well-formed foreign
rows remain queryable as facts but cannot supply delivery proof for this intent;
the owning query refuses and condemns its composed transaction. No row is
replaced or transformed into absence. C11/C13, lifecycle and current authority
retain their separate responsibilities.

The owning PostgreSQL control injects five malformed and five well-formed
foreign coordinate cases, with the original row retained. It proves rollback of
earlier/later writes despite an ignored refusal, no extra actual HTTP send and
recovery of the same send guard after exact repair. The normal ordinal SQL
constraint first rejects a negative update and preserves the row; only the
cloned fixture then removes its ordinal/status guards for corruption injection.
Production migrations/constraints are unchanged. Complete bad queued JSON is
also passed to the actual publisher as an altered fixture event: it refuses
before HTTP and preserves the original receipt, without editing Keiro tables.

The existing selected groups were listed first. The final source passes 77 core
unit and 47 core PostgreSQL cases, including the new UUID-domain case, wire
compatibility, honest dispatch, Kanmon, FlowLifecycle, practice-review attention
and all 20 SinkDelivery cases. All 130 compiler controls pass (their public API
is unchanged by the final native UUID validation body). Public native factories
compile before raw numeric/Generic/constructor/substitution bypasses refuse.
Style and whitespace checks pass.

```bash
nix develop --no-write-lock-file -c cabal test shikigami-core-test shikigami-core-postgres-test -j1 --test-show-details=direct --test-option=--num-threads=1 --test-option=-p --test-option='/SinkIntent/||/wire compatibility/||/sink honesty/||/Kanmon client/||/SinkDelivery/||/FlowLifecycle/||/practice review orchestration/||/agent conversation/'
nix develop --no-write-lock-file -c python3 tests/types/opaque-values.py
python3 tools/style/check_haskell.py
git diff --check
```

ADR-22 records the native coordinate and owning-read constraints. No workflow
step/label/order, valid journal result, identity recipe or migration changes. The
native gate passes on `abb2cf0` against `82cf413`, with no findings, a replay-
neutral verdict and all 156 conformance checks. Exact reports are retained in
`sink-coordinates-keiro-gate.json`, `sink-coordinates-keiro-diff.json` and
`sink-coordinates-replay-impact.json`.

The coherent full build and fresh census pass on `abb2cf0`: 324 modules, 936
declarations and 4,053 keys. All eight agent/session/ordinal findings are resolved;
the eight new ordinal/context keys and all 18 source environment keys are
classified after producer/consumer review. The classification totals 864 keys
(785 compliant, 35 excluded, 44 known violations). Both modes correctly refuse
3,189 missing keys after source/build/tool/entry validation. The frozen 124-source/
93-item inventory and 21 mutation checks pass; the earlier unchanged-tool 24-case
result remains applicable. All milestones and the guide deferral remain open.

## M1 inventory-first execution and process boundaries

Execution now completes the remaining semantic inventory before another M2 source
refactor. Progress separates verified M1a infrastructure from unfinished M1b
coverage, without marking M1 as a whole accepted or changing its requirements.
The 24 positive/mutation infrastructure tests pass again on the unchanged tools.

This source/consumer review adds 192 keys across 20 source modules: 164 compliant,
12 excluded and 16 findings. It covers foreground vendor adapters, API caller
attribution, client/listener/native telemetry/handler wiring, operator agent/run
reports, hermetic stub controls, worker supervision/configuration and the trigger
consumer. Each entry records its actual producer/consumer and authority. Immediate
native-library/explicit wire transfers are distinguished from policy thresholds,
allow-lists, receipt keys and identity-bearing callbacks; persisted status alone
is never an exemption. Named component entries preserve composition without
certifying nested fields or permission lifetime.

The findings include raw workflow status callback identity, the CLI inspector's
missing native UUIDv7 check, the Kanmon stub's actual allow-list/idempotency map,
resume bounds/overflow and scalar roles, liveness/worker policy durations,
reported scheduler principal claims and flattened native DLQ/inbox references.
The CLI parser finding has a public compiled counterexample retained in
`native-session-parser-probe.json`: native parseId accepts the v4 and wrong-variant
session examples, while the checked sink refiner rejects them. Source review
establishes sessionStep uses only parseId. No live CLI corruption or remediation
is claimed by that probe.

The current source-bound classification has 1,056 of 4,053 keys: 949 compliant,
47 excluded and 60 findings. Both checker modes correctly refuse 2,997 remaining
keys across 151 source modules after validating all existing source/build/tool
hashes and evidence paths. The executable candidate/census remains `abb2cf0`;
this pass changes documentation only and does not repeat a full Cabal build or
claim new runtime qualification. M1b, M2, M3 and the guide deferral remain open.


The subsequent inventory-only review completes worker coverage and adds core
workspace and agent contracts. The classification now covers 1,681/4,053 keys
(41%): 1,379 compliant, 89 excluded and 213 findings. The checker accepts entry
schemas, evidence paths and unchanged source/build/tool hashes before refusing
2,372 missing keys across 113 modules. This is inventory progress, not M1
acceptance or a runtime qualification claim. Kernel boot/inode anchors, reviewed
rule selection, retained provisioning phases, repository/path/commitment domains,
activity routing/deduplication and raw turn references remain explicit findings.
Exact payload content, native handles, refusal diagnostics and real outgoing status
reports are classified according to their actual consumers.


## M1 accepted: complete source-bound semantic inventory (2026-11-01)

The complete coherent census remains the successful `abb2cf0` GHC 9.12.4 arm64
macOS build: 324 library modules, 936 declarations, fourteen role entrypoints and
4,053 declaration/member keys. Classification now covers every key: 3,190
compliant, 288 not applicable and 575 explicit violations. There are zero missing,
extra or pending entries. Each entry names its actual source/consumer authority,
boundary, invariant, rationale and evidence. Typed composition does not certify
nested scalar or live authorization invariants; retained records are not exempt
merely because they are stored.

The final primitive-member review records five further findings (registered task
selection, compliance verdict, two finite confidence fields and an untyped route
proposal). It also makes native replay-content metadata, unused declaration
metadata, outgoing SQL/report projections and diagnostic observations explicit.
The query report decoder parses its top-level identity/phase/verdict/reasons; it
is not claimed to re-admit all raw evidence report JSON.

Executed on this unchanged source/interface snapshot:

```bash
python3 -m unittest discover -s tools/domain -p 'test_*.py'
python3 tools/domain/check_classification.py --classification docs/evidence/plan-108/domain-classification.json --census docs/evidence/keiro-0.22/domain-declarations.json
python3 tools/domain/check_classification.py --classification docs/evidence/plan-108/domain-classification.json --census docs/evidence/keiro-0.22/domain-declarations.json --require-resolved
git diff --check
```

Results: all 24 infrastructure tests pass. Normal checker passes with 4,053
classified keys and fresh source/build/tool hashes. Resolved-only checker fails
with exactly `unresolved violations: 575`, as required while M2 remains open.
Whitespace check passes. This documentation-only milestone needs no source
rebuild and claims no new runtime or Linux qualification. M2 remediation and M3
final acceptance/guide disposition remain unfinished.


## M2 closed numeric format source candidate

The source candidate replaces 23 execution/attempt/harness/replay-result,
compliance-fact and worker-session numeric format fields with nominally scoped
`FormatVersion` values. The only constructor is `V1`; arithmetic and Generic
bypasses are absent, and JSON remains exactly number `1`. ReplayContext retains
its separate supported 1/2 protocol. Existing complete wire fixtures and current
identity/commitment recipes remain unchanged. ADR-90 records the owner boundary;
ADR-75 and the module policy name the concrete shared format-value owner.

The focused unit selection passes 28 cases, including three new format controls.
Complete job/policy objects are first successfully decoded, then only their
format field is replaced by unsupported, fractional, huge or nonnumeric values.
The public compiler suite passes all 135 controls, including a positive typed
owner-field API, integer rejection, cross-scope identity/coercion rejection and
Generic admission rejection.

Two new disposable PostgreSQL cases first read a complete valid execution/session
state, inject four malformed format values, assert CorruptReplay or
SessionBindingConflict, ignore an owning transactional refusal between earlier
and later tentative writes, and prove both writes roll back. Actual operation/
message admission refuses without a lifecycle transition. Exact original JSON
repair recovers the original state without replacement work. Both initial cases
pass; the subsequent 150-case owner selection includes them and passes in 70.59s.
That selection covers execution/transcript/selection workflows, worker session
store/capability/handoff, Objective, workspace transfer and run evidence.

Commands use the existing suite-owned ephemeral PostgreSQL fixture, arm64 macOS
and GHC 9.12.4:

```bash
nix develop --no-write-lock-file -c cabal test shikigami-core-test -j1 --test-show-details=direct --test-option=-p --test-option='/closed format versions/||/execution revision and operation positions/||/ExecutionPolicy/'
nix develop --no-write-lock-file -c python3 tests/types/opaque-values.py
nix develop --no-write-lock-file -c cabal test shikigami-core-postgres-test -j1 --test-show-details=direct --test-option=--num-threads=1 --test-option=-p --test-option='/ExecutionTranscript/||/ExecutionSelectionWorkflow/||/WorkerSession/||/WorkerSessionStore/||/WorkerSessionCapability/||/WorkerSessionHandoff/||/ObjectiveStore/||/workspace transfer store/||/RunEvidence/'
python3 tools/style/check_haskell.py
python3 -m unittest discover -s tools/style
git diff --check
```

The source bytes are retained in `closed-formats-source.json`; all 51 hashes
match. The native gate passes on `80f8f22` against `5628432`: no findings,
replay-neutral verdict and 156 conformance checks. Exact reports are retained in
`closed-formats-keiro-diff.json`, `closed-formats-replay-impact.json` and
`closed-formats-keiro-gate.json`. The full build found two further prototype
fixture consumers; their explicit V1 updates are committed in `0d93ca6`, without
changing runtime workflow source.

The full workspace build and fresh census pass on `0d93ca6`: 325 modules, 937
declarations, fourteen entrypoints and 4,054 keys. Classification resolves all 23
format findings, adds the closed scoped type and rebinds reviewed entries to the
current source hashes. Totals: 3,214 compliant, 288 excluded and 552 violations,
with zero missing/pending keys. The normal checker passes; resolved-only mode
correctly fails with exactly 552 violations. All 24 infrastructure tests, 13 style
tests and 14 upgrade-inventory mutation tests pass. The existing 124 frozen
sources and 93 release items remain intact. M2/M3 and the guide remain open.
This snapshot adds no Linux runtime qualification.


## M2 resume restart policy source candidate

ResumeRetry is now private and admitted by mkResumeRetry before a loop can run.
Initial/maximum backoffs have separate nominal microsecond scopes; the failure
ceiling and healthy-run window have independent private types. Admission rejects
negative delays/windows, a nonpositive failure ceiling and initial above maximum.
Explicit zero delay and zero healthy window remain valid. The production default
retains one-second initial, thirty-second cap, five failures and sixty-second
healthy reset. Capped doubling now uses Integer before converting the bounded
result back to Int. This prevents overflow from producing a negative sleep.

The seven selected restart-policy cases pass, including actual requested sleeps
at maxBound Int, the failure ceiling, healthy-run resets and the immediate policy.
Four public compiler controls pass after the factory/default positive control: the
constructor, Generic and representation-coercion bypasses refuse. The standard
Justfile domain-value-types target now builds the worker library and runs this
control. Haskell style and whitespace checks pass. Source hashes are retained in
`resume-policy-source.json`; full build/census reconciliation is pending before
the five findings are marked resolved.

```bash
nix develop --no-write-lock-file -c cabal test shikigami-workers-test -j1 --test-show-details=direct --test-option=-p --test-option='/resume restart policy/'
nix develop --no-write-lock-file -c python3 tests/types/resume-policy.py
python3 tools/style/check_haskell.py
git diff --check
```

This process-local runtime policy changes no core Agent/Flow workflow body,
serialized record, native DSL declaration or identity recipe. The existing native
workflow gate evidence therefore remains applicable. There is no new retained
decoder owner or PostgreSQL schema to qualify for this batch.


The full workspace build and fresh census pass on resume source commit `be89d58`:
325 modules, 940 declarations, fourteen entrypoints and 4,060 keys. The five
ResumeRetry findings are resolved; all six keys of its three private scalar types
are classified. Current totals are 3,225 compliant, 288 excluded and 547 explicit
violations, with zero missing or pending entries. Normal coverage/freshness and
all 24 infrastructure tests pass; resolved-only mode correctly refuses exactly
547 findings. The unchanged upgrade inventory passes its 124-source/93-item check.
All five source/test/tool/ADR hashes in `resume-policy-source.json` match. Earlier
closed-format native and behavioral evidence remains applicable; no new core
workflow body, serialization or retained decoder boundary changed in this batch.


## Run inspection and scope review (2026-11-01)

The six-file source change retains native WorkflowId through the public server
callback and core status functions. HTTP/CLI text is converted at the adapter;
response bytes are unchanged. The CLI reuses `Sink.Coordinate.parseSinkSession`
to refuse a native v4 or wrong-variant session in retained inspection metadata.
No new helper module, parser grammar or gate is introduced; the core status
session decoder and all unrelated behavior remain unchanged.

`run-identity-source.json` binds the changed source and probe bytes. The focused
command from the repository root passes all 27 selected cases (8/10/9):

```bash
nix develop --no-write-lock-file -c cabal test shikigami-core-test shikigami-workers-test shikigami-server-test -j1 --test-show-details=direct --test-option=-p --test-option='/SinkIntent/||/run status composition/||/agent-run HTTP/'
nix develop --no-write-lock-file -c cabal test shikigami-core-test -j1 --test-show-details=direct --test-option=-p --test-option='/attestation contracts/'
```

The second command passes all 48 attestation cases. Existing fixtures deliberately
preserve documentary labels such as `sha256:decl`, `sha256:diff` and `sha256:result`.
Fourteen existing dedicated newtypes (28 declaration/payload keys) have no
additional syntax contract; public construction/Generic alone is not a violation
for those opaque labels. Source-supported correction preserves their exact codec,
while computed ProfileDigest/PayloadDigest retain their actual checked invariant.

`run-identity-probe.json` retains the public positive client, Text and SessionId
substitution refusals and the expression executing the actual private CLI
`sessionStep`. All four controls pass. This is compiler/pure-decoder evidence,
not a live CLI/database test. Coherent full build/census reconciliation is pending.


The complete workspace build and census refresh pass on `760ca05`: 325 modules,
940 declarations, 14 entrypoints and 4,060 keys. Source/interface/tool freshness
and all 24 checker tests pass. Both source findings are resolved. Four further
source-supported corrections retain the existing CredentialRef and EvidenceCursor
newtypes: the first labels a typed credential failure, while the second passes an
opaque reader-issued cursor back unchanged under bounded pagination/repetition
checks. Neither defines an extra grammar to enforce. No runtime change is made
for these corrections. The authorization-envelope description is also corrected
to its actual version 2; its primitive-field finding remains open.

Current totals: 3,259 compliant, 288 exclusions, 513 violations, zero missing or
pending entries. Resolved-only mode correctly exits 1 with `unresolved violations:
513`. The frozen guide remains deferred and M2/M3 remain open. This refresh makes
no new runtime, PostgreSQL, identity-migration or Linux qualification claim.


## Native listener owners and boundary review (2026-11-01)

Source candidate `b355dfa` retains Keiro WorkflowName/WorkflowId in SessionListener
through generation lookup, awakeable owner comparison and journal notification.
Only the retained JSON codec renders/parses text, with the original accepted
spellings. No token, authority, generation, identity recipe, label or step changes.
`listener-source.json` binds all seven source/test/ADR paths and records the exact
JSON captured from the old compiled encoder. Its golden includes a historical
owner spelling, proving this is a nominal representation change without a new
grammar. The existing owner checks remain responsible for binding the token.

Commands from the repository root on arm64 macOS/GHC 9.12.4:

```bash
nix develop --no-write-lock-file -c cabal test shikigami-core-postgres-test -j1 --test-show-details=direct --test-option=--num-threads=1 --test-option=-p --test-option='/WorkerSessionCapability/||/WorkerSessionStore/' --test-option=--list-tests
nix develop --no-write-lock-file -c cabal test shikigami-core-postgres-test -j1 --test-show-details=direct --test-option=--num-threads=1 --test-option=-p --test-option='/WorkerSessionCapability/||/WorkerSessionStore/'
nix develop --no-write-lock-file -c python3 tests/types/opaque-values.py
nix develop --no-write-lock-file -c just keiro-gate 92ce39a
```

The selected groups contain and pass 12 capability and 18 store cases (30 total),
including the old wire golden, notification journal-conflict rollback, rotated
listener refusal and existing ignored-read rollback/repair. All 137 existing-plus-
extended public compiler controls pass. Positive native listener field clients
compile before the new Text-substitution refusals. The workflow gate passes with
no findings, replay-neutral verdict and 156 generated conformance checks. Reports:
`listener-keiro-diff.json`, `listener-replay-impact.json`, `listener-keiro-gate.json`.
There is no new gate infrastructure, parser helper module, first-release waiver,
dependency change or Linux qualification.

Source/consumer review also corrects 18 existing findings without runtime edits.
Twelve endpoint fields in App.Config/Sink.Config are explicitly client-adapter
representations: the native HTTP Request/BaseUrl/ClientEnv owns URL admission
before IO. Five Kafka connection/subscription settings reach native BrokerAddress,
TopicName and ConsumerGroupId in Trigger.Consumer/Trigger.Publish. Importing the
Kafka FFI stack into core configuration or adding application URL wrappers would
not improve a domain-side concept at those explicit adapter seams. The remaining
configured Kikan callerId is only an audit-log label, separate from verified
principal and OAuth client identity. This is the frozen guide's explicit adapter/
incidental allowance, not an exemption based solely on configuration or storage.
Actual recipients, routing guards, authenticated HTTP callers and other policy
values remain separately classified. Coherent build/census reconciliation follows.


The complete workspace build and fresh census pass on `b355dfa`: 325 modules,
940 declarations, 14 entrypoints and 4,060 keys. Both listener fields are resolved,
and the source-traced boundary corrections are included. Coverage/freshness and
all 24 checker tests pass with 3,278 compliant, 289 exclusions and 493 remaining
findings. Resolved-only mode correctly refuses those 493 findings. M2/M3 and the
frozen guide remain open; this is not final exhaustive acceptance.


## Broad acceptance checkpoint (2026-11-01)

Runtime source is unchanged from `d1b4b93`; this checkpoint changes documentation,
friction evidence and build-bound inventory only. On arm64 macOS/GHC 9.12.4,
the six runtime unit suites pass 1,070 cases: core 618, API 31, client 9,
server 95, agent 37 and workers 280. Core domain conformance passes with 143
`PASS` lines and zero `FAIL` lines. All 466 core PostgreSQL cases pass using
the disposable migrated fixture, with one test thread. These results qualify
the existing runtime; they do not resolve the 493 nominal-value findings.

The initial combined unit run failed 13 worker Git-provider cases under parallel
load. Its first failure passes alone in 2.00 seconds; the entire 280-case worker
suite then passes serially in 181.11 seconds. FRIC-38 records this test-tooling
constraint. The accepted invocation retains the five-second executor deadline:

```bash
nix develop --no-write-lock-file -c cabal test shikigami-core-test shikigami-api-test shikigami-client-test shikigami-server-test shikigami-agent-test shikigami-workers-test shikigami-core-domain-test -j1 --test-show-details=direct
nix develop --no-write-lock-file -c cabal test shikigami-workers-test shikigami-client-test shikigami-server-test -j1 --test-show-details=direct --test-option=--num-threads=1
nix develop --no-write-lock-file -c cabal test shikigami-core-postgres-test -j1 --test-show-details=direct --test-option=--num-threads=1
```

The first command reached core, domain, API, agent and workers before stopping on
the worker failures; the second supplies the passing serial worker, client and
server results. A simultaneous first PostgreSQL build collided on an App.Version
object rename; its later complete run passes. Future builds should run sequentially.
All 24 classification infrastructure tests, 14 upgrade-audit mutation tests, the
frozen upgrade audit and Haskell style checks pass. Existing public compiler and
native workflow evidence remains applicable because no runtime source changed;
this checkpoint does not claim a new compiler or workflow-gate run.

The coverage document now states the completed 4,060-key classification rather
than the obsolete unclassified 322-module worklist. All 493 findings retain their
violation dispositions, and exhaustive remediation and final guide compliance
remain open. No wrappers, new runtime abstractions, migrations or dependencies
are added at this checkpoint.

The complete `cabal build all --enable-tests -j1` and census refresh also pass
on this candidate: 325 modules, 940 declarations and 14 role entrypoints.
All source path/hash pairs are unchanged from the previous census; only compiled
artifact bindings are refreshed. Normal classification acceptance passes all
4,060 keys with fresh source/build/tool hashes. Resolved-only acceptance exits 1
with `unresolved violations: 493`, as required. No disposition is relaxed.


## Batched Objective and inspection values (2026-11-01)

The source candidate addresses all 28 Objective and 19 inspection-setting
findings together. Objective retains native ExecutionId and WorkflowId; private
nominal wrappers separate caller/operator identities, foreign references and
computed commitment roles. Explicit boolean domains preserve the old JSON bools.
Inspection uses scoped nominal quantities and credentials, typed host/port/origin
values and explicit mutation policy. Renderers lower only at existing library,
SQL and codec adapters. No Num/IsString/Generic escape hatch or dependency is added.

The old compiled CreationOrigin encoder supplied three exact goldens, including
`legacy:owner`; all retain identical bytes. The four computed Objective digest
recipes keep their original domains and inputs. Malformed retained receipt JSON
commitments and relational fingerprints refuse owning reads and retries without
advancing events or creating replacement objectives, and recover the original
receipts after exact repair. Invalid historical values are not rewritten.

On arm64 macOS/GHC 9.12.4 the candidate passes 621 core unit cases, 95 server
cases (including real inspection HTTP/socket admission and bounds), 27 Objective
PostgreSQL cases and 177 public compiler controls. The compiler suite includes
raw/coercion/Generic refusal, separate inspection token/quantity scopes, distinct
Objective caller/operator and commitment roles, and distinct boolean domains.

```bash
nix develop --no-write-lock-file -c cabal test shikigami-core-test shikigami-core-postgres-test -j1 --test-show-details=direct --test-option=--num-threads=1 --test-option=-p --test-option='/Objectives/||/ObjectiveStore/||/AppConfig/'
nix develop --no-write-lock-file -c cabal test shikigami-core-test shikigami-server-test -j1 --test-show-details=direct --test-option=--num-threads=1
nix develop --no-write-lock-file -c python3 tests/types/opaque-values.py
```

The first filter selected 12 Objective unit and 27 PostgreSQL cases; AppConfig
is covered by the complete 621-case core run. The library/inspection/worker build
passes. A coherent full build and source/interface census reconciliation remains
necessary before renewing inventory freshness; this is a tested source candidate,
not final exhaustive acceptance. No workflow body, identity recipe, schema, HTTP
wire representation or Linux qualification is changed by this batch.


## Batched attestation values (2026-11-01)

The next source candidate addresses all 25 remaining attestation findings.
Provider model coordinates, requested aliases, run correlation, session identities
and deterministic step names reuse existing types. Private nominal wrappers
retain exact native attempt/token/cost quantities; relationship knowledge, cost
certainty, correlation-field vocabulary and the compliance decision become
explicit domains. Native provider attempts are Natural counters with a default
of one; zero is representable by the producer API, so capture preserves it
rather than inventing a stricter rule. No Num/Integral/IsString/Generic bypass is
added. Actual accounting explicitly extracts quantities for its existing sums.

Envelope signing-key references reuse their policy coordinate. Opaque signature,
Merkle, review-class, review-scope and pull-request labels have separate nominal
types with unchanged exact-string codecs. Review scope labels are signed claims,
not filesystem access capabilities: normalizing them through RelativePath would
change preexisting signed bytes. Actual content access retains its existing
checked Repository.RelativePath boundary. The existing canonical payload bytes
and pinned digest remain unchanged. A complete payload with a real native
UUIDv7 session round-trips; wrong prefixes, former synthetic labels and wrong
UUID versions refuse. Invalid historical session labels are not rewritten.

The candidate passes 51 attestation contract cases and 85 PostgreSQL cases on
arm64 macOS/GHC 9.12.4. The latter include live-versus-decoded compliance parity,
unknown usage/accounting, retry/fallback completeness, native projections and
restart recovery. Two new complete-facts corruption controls inject an unknown
correlation field or empty model alias; owner reads refuse, ignored reads condemn
earlier/later tentative writes, the pending provider is not called, and exact
repair restores original calls and reports.

```bash
nix develop --no-write-lock-file -c cabal test shikigami-core-test shikigami-core-postgres-test -j1 --test-show-details=direct --test-option=--num-threads=1 --test-option=-p --test-option='/attestation contracts/||/run evidence/||/decision evidence/||/execution selection/'
```

Both batched source candidates require one coherent full build and census
reconciliation. Their source changes do not alter workflow bodies, step order,
identity recipes, valid journal bytes, SQL schema or the selected macOS scope.

The extended public compiler suite also passes all 197 controls, including
native attestation session/step access, opaque quantity/label coercion and Generic
refusal, independent evidence states, and cross-role verdict substitution.


Both source batches reconcile on `1e7f619`: the complete workspace build and
fresh census pass with 325 modules, 974 declarations and 14 entrypoints. Manual
source/member reconciliation resolves their 72 findings and reviews all 59 new
nominal/closed-vocabulary keys. Coverage/freshness and all 24 checker tests pass:
4,119 keys, 3,409 compliant, 289 exclusions and 421 remaining violations, with
zero missing or pending entries. Resolved-only acceptance remains a failing
completion gate; no existing finding is waived as debt.

The native gate against `843cae0` passes with no findings, replay-neutral verdict
and 156 conformance controls. Reports are `batched-values-keiro-diff.json`,
`batched-values-replay-impact.json` and `batched-values-keiro-gate.json`. The
source candidate's ordinary type/codec changes do not alter workflow bodies,
steps or identity recipes; this native result does not certify malformed old
metadata or Linux runtime behavior. ADR-6 records preservation of signed labels,
and ADR-105 records the native evidence-coordinate/measurement extension.


The complete already-built core unit executable also passes all 624 cases on
this coherent source candidate (5.77 seconds), from the core package directory:

```bash
nix develop .. --no-write-lock-file -c ../dist-newstyle/build/aarch64-osx/ghc-9.12.4/shikigami-core-0.1.0.0/t/shikigami-core-test/build/shikigami-core-test/shikigami-core-test --num-threads=1
```

The frozen upgrade audit and final whitespace check pass. Existing 95-case
server and 27-case Objective PostgreSQL evidence remains applicable to its
unchanged source batch; the new attestation owner group passes 85 cases.
M2/M3 and final guide compliance remain open with 421 findings.


The next combined source candidate is bound by `declaration-values-source.json`
against `b57cbd8`. It carries native workflow identities through execution and
workspace admissions, distinguishes one-off capability runs, and retains scoped
nominal declaration/activity/directory claims. Profiles reuse their native
coordinates; actor/context/enablement vocabulary is closed; signal importance
and context references use the existing bounds. Cron declarations remain claims
until the existing scheduler parser produces an admitted schedule, preserving
its strict/lenient diagnostics. Synthetic activity references retain their
original trigger keys. Existing valid wire spellings, identity recipes and
workflow step shapes remain intact.

The formatted full workspace build passes, including the Linux prototype
compilation target. Runtime suites pass: core 626, API 31, client 9, server 95,
agent 37 and workers 280; all six diagram controls also pass. Worker tests run
serially from the worker package directory (200.52 seconds). Server tests need
the built `shikigami` executable on PATH, as declared by their Cabal build-tool
dependency; running that binary without this path caused fourteen harness
failures, all resolved with the correct tool environment (95 passed, 19.15
seconds). All 28 focused public compiler controls pass after positive native
getters/factories, including role substitution and private construction refusals.

A previous 472-case core PostgreSQL pass (134.05 seconds) covers the native
workflow and declaration candidate before the final cron-claim separation.
Final coherent PostgreSQL and full compiler/classification acceptance remains
required in M3. No Linux runtime qualification is claimed by prototype compilation.
The ledger remains at its identified older census; no remaining finding is
waived and the guide remains deferred.


The native gate on declaration commit `6f0260d` against `b57cbd8` passes with
zero findings, replay-neutral impact, and all 156 conformance controls. Its
reports are `declaration-keiro-diff.json`, `declaration-keiro-replay-impact.json`,
and `declaration-keiro-gate.json`.

The workspace scalar batch is bound to `6f0260d` by
`workspace-values-source.json`. Workspace references, repository/object/path
roles, content/binding/instruction/process commitments, command arguments and
environment entries retain nominal types through their owners and callers.
Private numeric units preserve existing process, RPC, Unix identity, status and
output bounds. Named settlement/output/provision/file-policy/Git-mode states
preserve their existing wire spellings. Complete profile, receipt, path and
binding validation remains at the existing owners; no universal digest grammar,
identity normalization, workflow step, hash salt or allocation recipe is added.

The formatted full workspace build passes, including the Linux prototype target.
The core unit executable passes all 626 tests; the PostgreSQL executable passes
all 472 cases (129.85 seconds), including the final declaration cron claim and
workspace changes; all 280 serial worker cases pass (184.17 seconds). Worker and
PostgreSQL tests run from their package directories in the Nix development
shell. Fifteen focused workspace compiler controls pass, including positive
ports followed by role/representation coercion, unchecked constructor/arithmetic,
string-literal, unit substitution and boolean substitution refusals. Nine new
controls are retained in `tests/types/revision-domains.py`; the focused run also
includes existing workspace entity controls. Formatter, style and whitespace
checks pass. Prototype compilation supplies no new Linux runtime qualification.
The old ledger is still identified as historical; final M3 acceptance requires
the remaining applicable findings and the combined fresh inventory to close.


The native gate for workspace source commit `ad22a18` against `6f0260d` also
passes: zero findings, replay-neutral impact and all 156 conformance controls.
The retained reports are `workspace-keiro-diff.json`,
`workspace-keiro-replay-impact.json` and `workspace-keiro-gate.json`.


Runtime values and remaining deterministic identity encapsulation (2026-11-01):
private duration roles keep exact numeric JSON and explicit clock/SDK lowering;
configured bounds retain the existing 1..86400-second policy. Remaining approval
waits retain zero for immediate expiration. Heartbeat tolerances keep their
separate exact role and existing zero/negative semantics. Manifest strictness,
agent inclusion and default-model requirements use named choices with their old
boolean configuration codecs. Review, catalog and delegation-budget decoders
require the original canonical UUIDv5 domains; producers keep their exact salts,
inputs and byte recipes. Repository identities remain exact foreign claims with
private representation and read-only access. Routing retains native Kioku session
identity. Dead letters retain queue/inbox alternatives, and flow memory/sink/
worker labels plus delegation keys keep distinct roles and the same prefixed
journal names and derived identities. Memory priority keeps the native integer
rank in a distinct wrapper, without inventing a new ranking range.

The complete workspace build passes, including the Linux prototype fixture.
Executed acceptance passes 629 core unit, 472 PostgreSQL (140.57 seconds), 280
serial worker (190.82 seconds), 95 server, 37 agent, 31 API and nine client cases,
plus domain conformance and six diagram controls. The core checks include malformed
and wrong-domain identity refusal and exact subsecond/expired duration behavior;
existing PostgreSQL controls retain approval, delegation, flow memory, routing,
execution, rollback and repair evidence. The source snapshot is
`runtime-values-source.json`. The 234-case compiler collection passes 232 controls and exposes two stale
generation expectations from the earlier execution batch; both corrected
controls pass separately. Final M3 will run the current complete script.
Style and whitespace checks pass. The native gate on `4ac29de` against
`ad22a18` passes with zero findings, replay-neutral impact and all 156
conformance controls; the exact reports are retained as
`runtime-values-keiro-{diff,replay-impact,gate}.json`.
The current classification remains the historical `1e7f619` snapshot and this
batch does not mark M2/M3 complete or certify unresolved findings.


## Final domain implementation and batched acceptance (2026-11-01)

The final source batch keeps sink/authentication/conversation claims nominal,
retains native grant and alias identities, checks model confidence in both JSON
and native model decoding, and wraps existing process-policy and integration
validators behind private newtypes. Explicit Input records are unadmitted
proposals; admitted values expose read-only fields and no Generic construction.
No identifier is reallocated and no workflow step, identity recipe, valid wire
encoding or dependency bound changes.

The complete workspace build passes, including the Linux prototype (compilation
only). The production candidate passes all 95 server, 37 agent, 31 API and nine
client tests, domain conformance, and six diagram checks. The broad core,
PostgreSQL and serial worker runs pass 631/632, 471/472 and 279/280 respectively.
Their three failures were invalid *fixture constructions*: two attempted to admit
an intermediate profile with unequal user/group identities; the other attempted
to construct an admitted confidence of 2.0 rather than send malformed model JSON.
All three fixtures were corrected in one batch, rebuilt together, and each
original failing test passes (0.07, 0.39 and 0.67 seconds). The production source
is identical across the broad and corrected-fixture runs; no failed case is
excluded or treated as compliant without its actual passing rerun.

All 253 current revision compiler controls pass, including 15 new private-policy
constructor/coercion/Generic controls. Style, whitespace and all 24 independent
classification controls pass. The compiled census candidate has 331 modules,
1,049 declarations, 14 role entrypoints and 4,253 keys. Semantic reconciliation
resolves 385 surviving findings, independently reviews 175 added keys and 41
removed/moved keys (36 former findings); resolved-only checking passes with zero
violations. Source and interface hashes are fresh. The final persisted census,
workflow compatibility reports, remaining compiler controls and guide disposition
are recorded below when accepted; this paragraph alone does not complete M3.


The remaining public compiler gates also pass: 269 opaque-value controls, five
workspace-scope controls and four resume-policy controls. The two stale positive
signatures in the opaque-value fixture now reflect the already admitted Natural
call ordinal and native/scoped instruction-bundle inputs. No production API was
weakened to satisfy these controls. Total current compiler controls: 531.
