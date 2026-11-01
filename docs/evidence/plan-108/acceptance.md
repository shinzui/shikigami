# Plan 108 acceptance evidence

Implementation is in progress. Five decoder boundaries and one policy scalar have
focused acceptance below. No complete milestone or exhaustive semantic compliance
is accepted yet. The frozen domain guide remains deferred.

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
