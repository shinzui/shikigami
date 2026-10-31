# Plan 108 acceptance evidence

Implementation is in progress. Two decoder boundaries and one policy scalar have
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
errors/workspace tool boundaries: 194 compliant entries,
20 constraint/route/media-type exclusions, and 34 explicit violations. HTTP views
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
classification, the 34 currently recorded scalar/construction violations, remaining decoder
owners and final-candidate behavioral acceptance. The dependency-native workflow
generation API was verified as `Int`; it must not be described as an opaque ID.

[ADR-107](../../adr/0107-profile-and-objective-corruption-refuses-within-the-owning-transaction.md)
records the accepted owner boundary. FRIC-36 in `docs/friction-log/` records the
compiler gate's per-probe Cabal startup/buffered progress cost and remains logged
for completion-time triage.
