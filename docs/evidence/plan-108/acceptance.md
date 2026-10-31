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
